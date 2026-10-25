// Primitive assembly, rasterisation and the per-pixel pipeline: texture
// mapping, fog, alpha test, destination alpha test, depth test, blending
// and masked frame/depth writes.
package gs

import "core:math"
import "../ee"

Vertex :: struct {
	x, y:    f32, // pixels, window-relative
	z:       f64,
	c:       [4]f32, // r, g, b, a
	s, t, q: f32,
	u, v:    f32, // texels (FST = 1)
	fog:     f32,
}

// Headless runs with no screenshot due skip rasterisation; uploads,
// registers and FINISH/SIGNAL still happen.
skip_draw: bool

@(private)
cur: Vertex // attributes from RGBAQ/ST/UV/FOG awaiting a vertex kick
@(private)
queue: [3]Vertex
@(private)
nq: int

@(private)
Tex :: struct {
	tbp, tbw, psm:      u32,
	w, h:               u32,
	tcc:                bool,
	tfx:                u32,
	cpsm, csa:          u32,
	bilinear:           bool,
	wms, wmt:           u32,
	minu, maxu:         u32,
	minv, maxv:         u32,
	ta0, ta1:           u32,
	aem:                bool,
	// Mipmapping, from TEX1 and MIPTBP1/2: level n's base and width.
	lcm:                bool, // LOD is K alone
	mxl, mmin, l:       u32,
	k:                  i32, // 1/16ths
	mtbp, mtbw:         [7]u32,
}

// Drawing state for one primitive, decoded from PRIM and its context.
@(private)
Ctx :: struct {
	iip, tme, fge, abe, fst: bool,
	fbp, fbw, fpsm, fbmsk:   u32,
	zbp, zpsm:               u32,
	zmsk:                    bool,
	sx0, sx1, sy0, sy1:      i32,
	ate:                     bool,
	atst, aref, afail:       u32,
	date, datm:              bool,
	zte:                     bool,
	ztst:                    u32,
	a, b, c, d, fix:         u32,
	pabe, fba, colclamp:     bool,
	fogcol:                  [3]i32,
	tex:                     Tex,
}

// Every GS register write lands here after ee.gs_write stores it.
write :: proc(reg: u8, v: u64) {
	switch reg {
	case ee.GS_PRIM: nq = 0
	case ee.GS_RGBAQ:
		cur.c = {f32(v & 0xff), f32((v >> 8) & 0xff), f32((v >> 16) & 0xff), f32((v >> 24) & 0xff)}
		cur.q = transmute(f32)u32(v >> 32)
	case ee.GS_ST:
		cur.s = transmute(f32)u32(v)
		cur.t = transmute(f32)u32(v >> 32)
	case ee.GS_UV:
		cur.u = f32(v & 0x3fff) / 16
		cur.v = f32((v >> 16) & 0x3fff) / 16
	case ee.GS_FOG: cur.fog = f32(v >> 56)
	case ee.GS_XYZF2, ee.GS_XYZF3:
		cur.fog = f32(v >> 56)
		vertex(v, f64((v >> 32) & 0xffffff), reg == ee.GS_XYZF2)
	case ee.GS_XYZ2, ee.GS_XYZ3:
		vertex(v, f64(v >> 32), reg == ee.GS_XYZ2)
	case 0x06, 0x07: clut_load(v) // TEX0_1/2
	case 0x16, 0x17: // TEX2_1/2: PSM and CLUT fields of TEX0
		MASK :: u64(0x3f) << 20 | 0xffff_ffe0_0000_0000
		t := &ee.gs.regs[reg - 0x10]
		t^ = (t^ &~ MASK) | (v & MASK)
		clut_load(t^)
	case ee.GS_TRXDIR: xfer_start(u32(v))
	}
}

@(private)
prim_attrs :: proc() -> u64 {
	prim := ee.gs.regs[ee.GS_PRIM]
	if ee.gs.regs[0x1a] & 1 == 0 {prim = (prim & 7) | (ee.gs.regs[0x1b] &~ 7)} // PRMODECONT
	return prim
}

@(private)
vertex :: proc(xyz: u64, z: f64, kick: bool) {
	prim := prim_attrs()
	ctx := u32(prim >> 9) & 1
	off := ee.gs.regs[0x18 + ctx]
	v := cur
	v.x = (f32(xyz & 0xffff) - f32(off & 0xffff)) / 16
	v.y = (f32((xyz >> 16) & 0xffff) - f32((off >> 32) & 0xffff)) / 16
	v.z = z
	queue[nq] = v
	nq += 1
	kind := prim & 7
	@(static, rodata) need := [8]int{1, 2, 2, 3, 3, 3, 2, 1}
	if nq < need[kind] {return}
	if kick && kind != 7 {draw(kind, prim)}
	switch kind {
	case 2: // line strip
		queue[0] = queue[1]
		nq = 1
	case 4: // triangle strip
		queue[0], queue[1] = queue[1], queue[2]
		nq = 2
	case 5: // triangle fan
		queue[1] = queue[2]
		nq = 2
	case:
		nq = 0
	}
}

@(private)
decode_ctx :: proc(prim: u64) -> (c: Ctx) {
	r := &ee.gs.regs
	n := u32(prim >> 9) & 1
	c.iip = prim & (1 << 3) != 0
	c.tme = prim & (1 << 4) != 0
	c.fge = prim & (1 << 5) != 0
	c.abe = prim & (1 << 6) != 0
	c.fst = prim & (1 << 8) != 0

	frame := r[0x4c + n]
	c.fbp = u32(frame & 0x1ff) * 32
	c.fbw = u32(frame >> 16) & 0x3f
	c.fpsm = u32(frame >> 24) & 0x3f
	c.fbmsk = u32(frame >> 32)
	zbuf := r[0x4e + n]
	c.zbp = u32(zbuf & 0x1ff) * 32
	c.zpsm = (u32(zbuf >> 24) & 0xf) | 0x30
	c.zmsk = zbuf & (1 << 32) != 0
	sc := r[0x40 + n]
	c.sx0, c.sx1 = i32(sc & 0x7ff), i32((sc >> 16) & 0x7ff)
	c.sy0, c.sy1 = i32((sc >> 32) & 0x7ff), i32((sc >> 48) & 0x7ff)
	test := r[0x47 + n]
	c.ate = test & 1 != 0
	c.atst = u32(test >> 1) & 7
	c.aref = u32(test >> 4) & 0xff
	c.afail = u32(test >> 12) & 3
	c.date = test & (1 << 14) != 0
	c.datm = test & (1 << 15) != 0
	c.zte = test & (1 << 16) != 0
	c.ztst = u32(test >> 17) & 3
	al := r[0x42 + n]
	c.a, c.b, c.c, c.d = u32(al) & 3, u32(al >> 2) & 3, u32(al >> 4) & 3, u32(al >> 6) & 3
	c.fix = u32(al >> 32) & 0xff
	c.pabe = r[0x49] & 1 != 0
	c.fba = r[0x4a + n] & 1 != 0
	c.colclamp = r[0x46] & 1 != 0
	fc := r[0x3d]
	c.fogcol = {i32(fc & 0xff), i32((fc >> 8) & 0xff), i32((fc >> 16) & 0xff)}

	if c.tme {
		t0 := r[0x06 + n]
		t1 := r[0x14 + n]
		cl := r[0x08 + n]
		ta := r[0x3b]
		mip := [2]u64{r[0x34 + n], r[0x36 + n]}
		c.tex = {
			tbp      = u32(t0) & 0x3fff,
			tbw      = u32(t0 >> 14) & 0x3f,
			psm      = u32(t0 >> 20) & 0x3f,
			w        = 1 << min(u32(t0 >> 26) & 0xf, 10),
			h        = 1 << min(u32(t0 >> 30) & 0xf, 10),
			tcc      = t0 & (1 << 34) != 0,
			tfx      = u32(t0 >> 35) & 3,
			cpsm     = u32(t0 >> 51) & 0xf,
			csa      = u32(t0 >> 56) & 0x1f,
			bilinear = t1 & (1 << 5) != 0,
			wms      = u32(cl) & 3,
			wmt      = u32(cl >> 2) & 3,
			minu     = u32(cl >> 4) & 0x3ff,
			maxu     = u32(cl >> 14) & 0x3ff,
			minv     = u32(cl >> 24) & 0x3ff,
			maxv     = u32(cl >> 34) & 0x3ff,
			ta0      = u32(ta) & 0xff,
			ta1      = u32(ta >> 32) & 0xff,
			aem      = ta & (1 << 15) != 0,
			lcm      = t1 & 1 != 0,
			mxl      = min(u32(t1 >> 2) & 7, 6),
			mmin     = u32(t1 >> 6) & 7,
			l        = u32(t1 >> 19) & 3,
			k        = i32(u32(t1 >> 32) << 20) >> 20,
		}
		c.tex.mtbp[0], c.tex.mtbw[0] = c.tex.tbp, c.tex.tbw
		for i in u32(1) ..= 6 {
			m := mip[(i - 1) / 3] >> (((i - 1) % 3) * 20)
			c.tex.mtbp[i], c.tex.mtbw[i] = u32(m) & 0x3fff, u32(m >> 14) & 0x3f
		}
	}
	return
}

@(private)
draw :: proc(kind, prim: u64) {
	if skip_draw {return}
	c := decode_ctx(prim)
	if c.zte && c.ztst == 0 {return} // NEVER
	if hw_on {
		hw_draw(&c, kind)
		return
	}
	switch kind {
	case 0: draw_point(&c, &queue[0])
	case 1, 2: draw_line(&c, &queue[0], &queue[1])
	case 3, 4, 5: draw_tri(&c, &queue[0], &queue[1], &queue[2])
	case 6: draw_sprite(&c, &queue[0], &queue[1])
	}
}

// ------------------------------------------------------------ rasteriser

@(private)
draw_point :: proc(c: ^Ctx, v: ^Vertex) {
	x, y := i32(math.floor(v.x)), i32(math.floor(v.y))
	if x < c.sx0 || x > c.sx1 || y < c.sy0 || y > c.sy1 {return}
	u, tv, lod := tex_coord(c, v.s, v.t, v.q, v.u, v.v)
	pixel(c, x, y, v.z, v.c, u, tv, lod, v.fog)
}

@(private)
draw_line :: proc(c: ^Ctx, a, b: ^Vertex) {
	dx, dy := b.x - a.x, b.y - a.y
	n := int(max(abs(dx), abs(dy)))
	for i in 0 ..< n {
		f := f32(i) / f32(n)
		v := lerp_vertex(a, b, f)
		if !c.iip {v.c = b.c}
		x, y := i32(math.floor(v.x)), i32(math.floor(v.y))
		if x < c.sx0 || x > c.sx1 || y < c.sy0 || y > c.sy1 {continue}
		u, tv, lod := tex_coord(c, v.s, v.t, v.q, v.u, v.v)
		pixel(c, x, y, v.z, v.c, u, tv, lod, v.fog)
	}
}

@(private)
lerp_vertex :: proc(a, b: ^Vertex, f: f32) -> (v: Vertex) {
	v.x = a.x + (b.x - a.x) * f
	v.y = a.y + (b.y - a.y) * f
	v.z = a.z + (b.z - a.z) * f64(f)
	v.c = a.c + (b.c - a.c) * f
	v.s = a.s + (b.s - a.s) * f
	v.t = a.t + (b.t - a.t) * f
	v.q = a.q + (b.q - a.q) * f
	v.u = a.u + (b.u - a.u) * f
	v.v = a.v + (b.v - a.v) * f
	v.fog = a.fog + (b.fog - a.fog) * f
	return
}

// Texel-space coordinates from STQ or UV, and the level of detail.
@(private)
tex_coord :: #force_inline proc(c: ^Ctx, s, t, q, u, v: f32) -> (f32, f32, i32) {
	if !c.tme {return 0, 0, 0}
	if c.fst {return u, v, tex_lod(&c.tex, 1)}
	lod := tex_lod(&c.tex, q)
	if q == 0 {return s * f32(c.tex.w), t * f32(c.tex.h), lod}
	return s / q * f32(c.tex.w), t / q * f32(c.tex.h), lod
}

// LOD = log2(1/|Q|) * 2^L + K in 1/2^23ths, the log taken as the float's
// exponent plus its mantissa read linearly: integer arithmetic, so the
// GPU's shaders/prim.frag `tex_lod` gets the same levels. UV primitives
// take Q as 1.
@(private)
tex_lod :: #force_inline proc(t: ^Tex, q: f32) -> i32 {
	x: i32
	if !t.lcm {
		x = clamp(127 << 23 - i32(transmute(u32)abs(q)), -16 << 23, 16 << 23) << t.l
	}
	return x + t.k << 19
}

@(private)
draw_sprite :: proc(c: ^Ctx, a, b: ^Vertex) {
	x0, x1 := min(a.x, b.x), max(a.x, b.x)
	y0, y1 := min(a.y, b.y), max(a.y, b.y)
	if x1 <= x0 || y1 <= y0 {return}
	// Attributes run from a to b; flip if b is the left/top corner.
	ua, ub := a.u, b.u
	va, vb := a.v, b.v
	sa, sb := a.s, b.s
	ta, tb := a.t, b.t
	if a.x > b.x {ua, ub, sa, sb = ub, ua, sb, sa}
	if a.y > b.y {va, vb, ta, tb = vb, va, tb, ta}
	px0 := max(i32(math.ceil(x0)), c.sx0)
	px1 := min(i32(math.ceil(x1)) - 1, c.sx1)
	py0 := max(i32(math.ceil(y0)), c.sy0)
	py1 := min(i32(math.ceil(y1)) - 1, c.sy1)
	for y in py0 ..= py1 {
		fy := (f32(y) - y0) / (y1 - y0)
		vv := va + (vb - va) * fy
		tt := ta + (tb - ta) * fy
		for x in px0 ..= px1 {
			fx := (f32(x) - x0) / (x1 - x0)
			u, v, lod := tex_coord(c, sa + (sb - sa) * fx, tt, b.q, ua + (ub - ua) * fx, vv)
			pixel(c, x, y, b.z, b.c, u, v, lod, b.fog)
		}
	}
}

@(private)
draw_tri :: proc(c: ^Ctx, v0, v1, v2: ^Vertex) {
	a, b, d := v0, v1, v2
	area := f64(b.x - a.x) * f64(d.y - a.y) - f64(b.y - a.y) * f64(d.x - a.x)
	if area == 0 {return}
	if area < 0 {
		b, d = d, b
		area = -area
	}
	minx := max(i32(math.ceil(min(a.x, b.x, d.x))), c.sx0)
	maxx := min(i32(math.floor(max(a.x, b.x, d.x))), c.sx1)
	miny := max(i32(math.ceil(min(a.y, b.y, d.y))), c.sy0)
	maxy := min(i32(math.floor(max(a.y, b.y, d.y))), c.sy1)
	if minx > maxx || miny > maxy {return}

	// Edge e(p) = (q.x - p0.x)(p.y - p0.y) - (q.y - p0.y)(p.x - p0.x), positive
	// inside. Pixels on an edge belong to it only for top or left edges.
	Edge :: struct {dx, dy, w: f64, bias: bool}
	mk :: proc(p, q: ^Vertex, x, y: f64) -> Edge {
		dx, dy := f64(q.x - p.x), f64(q.y - p.y)
		w := dx * (y - f64(p.y)) - dy * (x - f64(p.x))
		top_left := dy < 0 || (dy == 0 && dx > 0)
		return {dx, dy, w, top_left}
	}
	fx, fy := f64(minx), f64(miny)
	e0 := mk(b, d, fx, fy) // weight of a
	e1 := mk(d, a, fx, fy) // weight of b
	e2 := mk(a, b, fx, fy) // weight of d
	inv := 1 / area
	flat := a.c
	if !c.iip {flat = v2.c}
	for y in miny ..= maxy {
		w0, w1, w2 := e0.w, e1.w, e2.w
		for x in minx ..= maxx {
			defer {w0 -= e0.dy; w1 -= e1.dy; w2 -= e2.dy}
			if w0 < 0 || w1 < 0 || w2 < 0 {continue}
			if (w0 == 0 && !e0.bias) || (w1 == 0 && !e1.bias) || (w2 == 0 && !e2.bias) {continue}
			l0, l1, l2 := w0 * inv, w1 * inv, w2 * inv
			f0, f1, f2 := f32(l0), f32(l1), f32(l2)
			z := a.z * l0 + b.z * l1 + d.z * l2
			col := flat
			if c.iip {col = a.c * f0 + b.c * f1 + d.c * f2}
			u, v: f32
			lod: i32
			if c.tme {
				u, v, lod = tex_coord(c,
					a.s * f0 + b.s * f1 + d.s * f2,
					a.t * f0 + b.t * f1 + d.t * f2,
					a.q * f0 + b.q * f1 + d.q * f2,
					a.u * f0 + b.u * f1 + d.u * f2,
					a.v * f0 + b.v * f1 + d.v * f2)
			}
			fog := a.fog * f0 + b.fog * f1 + d.fog * f2
			pixel(c, x, y, z, col, u, v, lod, fog)
		}
		e0.w += e0.dx
		e1.w += e1.dx
		e2.w += e2.dx
	}
}

// --------------------------------------------------------------- texture

@(private)
wrap :: #force_inline proc(i: i32, mode, size, lo, hi: u32) -> u32 {
	switch mode {
	case 0: return u32(i) & (size - 1)
	case 1: return u32(clamp(i, 0, i32(size) - 1))
	case 2: return u32(clamp(i, i32(lo), i32(hi)))
	}
	return (u32(i) & lo) | hi // region repeat: MINU is the mask, MAXU the fix
}

// Texel as RGBA8888 (R in the low byte).
@(private)
fetch :: proc(t: ^Tex, n, x, y: u32) -> u32 {
	raw := read_raw(t.psm, t.mtbp[n], t.mtbw[n], x, y)
	switch t.psm {
	case PSMCT32: return raw
	case PSMCT24:
		a := t.aem && raw == 0 ? 0 : t.ta0
		return raw | a << 24
	case PSMCT16, PSMCT16S: return expand16(t, raw)
	}
	e := clut[(t.csa * 16 + raw) & 511]
	if t.cpsm == PSMCT32 {return e}
	return expand16(t, e & 0xffff)
}

@(private)
expand16 :: #force_inline proc(t: ^Tex, c: u32) -> u32 {
	rgb := (c & 0x1f) << 3 | (c & 0x3e0) << 6 | (c & 0x7c00) << 9
	a: u32
	if c & 0x8000 != 0 {
		a = t.ta1
	} else if !t.aem || c & 0x7fff != 0 {
		a = t.ta0
	}
	return rgb | a << 24
}

// The texel colour at level-0 texel coordinates (u, v) and level of
// detail `lod`: LOD <= 0 magnifies level 0 with MMAG, otherwise MMIN picks
// the filter and how levels 0..MXL are used.
@(private)
sample :: proc(t: ^Tex, u, v: f32, lod: i32) -> [4]i32 {
	if lod <= 0 {return sample_level(t, 0, u, v, t.bilinear)}
	bil := t.mmin == 1 || t.mmin >= 4
	switch t.mmin {
	case 2, 4: // MIPMAP_NEAREST: the nearest level
		n := min(u32((lod + 1 << 22) >> 23), t.mxl)
		return sample_level(t, n, u, v, bil)
	case 3, 5: // MIPMAP_LINEAR: between the two nearest levels
		n := min(u32(lod >> 23), t.mxl)
		c := sample_level(t, n, u, v, bil)
		if n == t.mxl {return c}
		f := (lod >> 15) & 0xff
		return c + ((sample_level(t, n + 1, u, v, bil) - c) * f) / 256
	}
	return sample_level(t, 0, u, v, bil)
}

// A sample of level n, nearest or bilinear.
@(private)
sample_level :: proc(t: ^Tex, n: u32, u, v: f32, bilinear: bool) -> [4]i32 {
	u, v := u / f32(u32(1) << n), v / f32(u32(1) << n)
	w, h := max(t.w >> n, 1), max(t.h >> n, 1)
	minu, maxu, minv, maxv := t.minu, t.maxu, t.minv, t.maxv
	if t.wms == 2 {minu, maxu = minu >> n, maxu >> n}
	if t.wmt == 2 {minv, maxv = minv >> n, maxv >> n}
	if !bilinear {
		x := wrap(i32(math.floor(u)), t.wms, w, minu, maxu)
		y := wrap(i32(math.floor(v)), t.wmt, h, minv, maxv)
		return unpack(fetch(t, n, x, y))
	}
	u, v = u - 0.5, v - 0.5
	fu, fv := math.floor(u), math.floor(v)
	iu, iv := i32(fu), i32(fv)
	au, av := i32((u - fu) * 256), i32((v - fv) * 256)
	x0 := wrap(iu, t.wms, w, minu, maxu)
	x1 := wrap(iu + 1, t.wms, w, minu, maxu)
	y0 := wrap(iv, t.wmt, h, minv, maxv)
	y1 := wrap(iv + 1, t.wmt, h, minv, maxv)
	c00, c10 := unpack(fetch(t, n, x0, y0)), unpack(fetch(t, n, x1, y0))
	c01, c11 := unpack(fetch(t, n, x0, y1)), unpack(fetch(t, n, x1, y1))
	top := c00 + ((c10 - c00) * au) / 256
	bot := c01 + ((c11 - c01) * au) / 256
	return top + ((bot - top) * av) / 256
}

@(private)
unpack :: #force_inline proc(c: u32) -> [4]i32 {
	return {i32(c & 0xff), i32((c >> 8) & 0xff), i32((c >> 16) & 0xff), i32(c >> 24)}
}

// ---------------------------------------------------------------- pixels

@(private)
pixel :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {
	px, py := u32(x), u32(y)
	src := [4]i32{i32(col.r), i32(col.g), i32(col.b), i32(col.a)}

	if c.tme {
		t := sample(&c.tex, u, v, lod)
		switch c.tex.tfx {
		case 0: // MODULATE
			for k in 0 ..< 3 {src[k] = min((t[k] * src[k]) >> 7, 255)}
			if c.tex.tcc {src.a = min((t.a * src.a) >> 7, 255)}
		case 1: // DECAL
			src.rgb = t.rgb
			if c.tex.tcc {src.a = t.a}
		case 2, 3: // HIGHLIGHT, HIGHLIGHT2
			for k in 0 ..< 3 {src[k] = min(((t[k] * src[k]) >> 7) + src.a, 255)}
			if c.tex.tcc {src.a = c.tex.tfx == 2 ? min(t.a + src.a, 255) : t.a}
		}
	}
	if c.fge {
		f := i32(fogf)
		for k in 0 ..< 3 {src[k] = (f * src[k] + (255 - f) * c.fogcol[k]) >> 8}
	}

	write_fb, write_z := true, !c.zmsk
	write_alpha := true
	if c.ate {
		a := u32(src.a)
		pass: bool
		switch c.atst {
		case 0: pass = false
		case 1: pass = true
		case 2: pass = a < c.aref
		case 3: pass = a <= c.aref
		case 4: pass = a == c.aref
		case 5: pass = a >= c.aref
		case 6: pass = a > c.aref
		case 7: pass = a != c.aref
		}
		if !pass {
			switch c.afail {
			case 0: return
			case 1: write_z = false
			case 2: write_fb = false
			case 3:
				write_z = false
				write_alpha = false
			}
		}
	}

	fb32 := c.fpsm == PSMCT32 || c.fpsm == PSMCT24 || c.fpsm == PSMZ32 || c.fpsm == PSMZ24
	dst_raw := read_raw(c.fpsm, c.fbp, c.fbw, px, py)
	if c.date {
		bit := fb32 ? dst_raw & 0x80000000 != 0 : dst_raw & 0x8000 != 0
		if bit != c.datm {return}
	}

	z := u32(min(zf, 4294967295.0))
	if c.zte {
		zmax: u32 = 0xffffffff
		switch c.zpsm {
		case PSMZ24: zmax = 0xffffff
		case PSMZ16, PSMZ16S: zmax = 0xffff
		}
		z = min(z, zmax)
		dz := read_raw(c.zpsm, c.zbp, c.fbw, px, py)
		switch c.ztst {
		case 2: if z < dz {return}
		case 3: if z <= dz {return}
		}
	}
	if write_z && c.zte {write_raw(c.zpsm, c.zbp, c.fbw, px, py, z)}
	if !write_fb {return}

	dst: [4]i32
	if fb32 {
		dst = unpack(dst_raw)
		if c.fpsm == PSMCT24 || c.fpsm == PSMZ24 {dst.a = 0x80}
	} else {
		dst = {i32(dst_raw & 0x1f) << 3, i32((dst_raw >> 5) & 0x1f) << 3, i32((dst_raw >> 10) & 0x1f) << 3, dst_raw & 0x8000 != 0 ? 0x80 : 0}
	}

	if c.abe && !(c.pabe && src.a < 0x80) {
		sel :: #force_inline proc(n: u32, s, d: [4]i32) -> [3]i32 {
			switch n {
			case 0: return s.rgb
			case 1: return d.rgb
			}
			return {}
		}
		ca := sel(c.a, src, dst)
		cb := sel(c.b, src, dst)
		cd := sel(c.d, src, dst)
		alpha: i32
		switch c.c {
		case 0: alpha = src.a
		case 1: alpha = dst.a
		case: alpha = i32(c.fix)
		}
		for k in 0 ..< 3 {src[k] = (((ca[k] - cb[k]) * alpha) >> 7) + cd[k]}
	}
	for k in 0 ..< 3 {
		src[k] = c.colclamp ? clamp(src[k], 0, 255) : src[k] & 0xff
	}
	if c.fba {src.a |= 0x80}
	if !write_alpha {src.a = dst.a}

	out: u32
	if fb32 {
		out = u32(src.r) | u32(src.g) << 8 | u32(src.b) << 16 | u32(src.a & 0xff) << 24
	} else {
		out = u32(src.r >> 3) | u32(src.g >> 3) << 5 | u32(src.b >> 3) << 10 | (src.a & 0x80 != 0 ? 0x8000 : 0)
		dst_raw &= 0xffff
	}
	msk := c.fbmsk
	if !fb32 {
		msk = (msk >> 3) & 0x1f | (msk >> 6) & 0x3e0 | (msk >> 9) & 0x7c00 | (msk >> 16) & 0x8000
	}
	write_raw(c.fpsm, c.fbp, c.fbw, px, py, (out &~ msk) | (dst_raw & msk))
}
