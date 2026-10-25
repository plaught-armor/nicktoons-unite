// DMA into the VIFs and the GIF. Transfers run to completion when the
// channel is started: the source chain is walked, the words are fed to the
// VIF or GIF, and the channel is marked finished.
package ee

import "core:fmt"
import "base:intrinsics"
import "ps:core"

// ------------------------------------------------------------- DMA source

// Bytes a source-chain or normal transfer delivers, including the upper
// half of each tag when TTE is set (VIF channels).
@(private)
dma_gather :: proc(ch: u32, out: ^[dynamic]u8) {
	chcr := dma_reg(ch, 0x00)
	madr := dma_reg(ch, 0x10)
	qwc := dma_reg(ch, 0x20)
	tadr := dma_reg(ch, 0x30)
	asr := [2]^u32{dma_reg(ch, 0x40), dma_reg(ch, 0x50)}

	data :: proc(out: ^[dynamic]u8, addr, qwc: u32) {
		if qwc >= 1024 && k.debug == 2 {fmt.eprintfln("dma: data %08x qwc %x", addr, qwc)}
		if qwc != 0 {append(out, ..ram_slice(dma_addr(addr), qwc * 16))}
	}

	if (chcr^ >> 2) & 3 != 1 { // normal (or interleave, treated as normal)
		data(out, madr^, qwc^ & 0xffff)
		madr^ += (qwc^ & 0xffff) * 16
		qwc^ = 0
		return
	}
	// A transfer started with QWC set first drains MADR.
	if qwc^ & 0xffff != 0 {
		data(out, madr^, qwc^ & 0xffff)
		qwc^ = 0
	}
	tte := chcr^ & 0x40 != 0
	tie := chcr^ & 0x80 != 0
	for _ in 0 ..< 1 << 20 {
		t := tadr^
		lo := rd64(dma_addr(t))
		hi := rd64(dma_addr(t + 8))
		n := u32(lo & 0xffff)
		id := (lo >> 28) & 7
		addr := u32(lo >> 32) & 0xfffffff0
		chcr^ = (chcr^ & 0xffff) | u32(lo >> 16) << 16
		if tte {
			for i in 0 ..< 8 {append(out, u8(hi >> (8 * u32(i))))}
		}
		done := false
		switch id {
		case 0: // refe
			data(out, addr, n)
			done = true
		case 1: // cnt
			data(out, t + 16, n)
			tadr^ = t + 16 + n * 16
		case 2: // next
			data(out, t + 16, n)
			tadr^ = addr
		case 3, 4: // ref, refs
			data(out, addr, n)
			tadr^ = t + 16
		case 5: // call
			data(out, t + 16, n)
			sp := (chcr^ >> 4) & 3
			if sp < 2 {
				asr[sp]^ = t + 16 + n * 16
				chcr^ = (chcr^ &~ 0x30) | (sp + 1) << 4
			}
			tadr^ = addr
		case 6: // ret
			data(out, t + 16, n)
			sp := (chcr^ >> 4) & 3
			if sp == 0 {
				done = true
			} else {
				sp -= 1
				tadr^ = asr[sp]^
				chcr^ = (chcr^ &~ 0x30) | sp << 4
			}
		case 7: // end
			data(out, t + 16, n)
			done = true
		}
		if done || (tie && lo & 0x80000000 != 0) {return}
	}
	fmt.eprintfln("dma: ch %d chain did not end", ch)
}

// DMA addresses with bit 31 set refer to scratchpad.
@(private)
dma_addr :: #force_inline proc(a: u32) -> u32 {
	return a & 0x80000000 != 0 ? SPR_BASE | (a & (SPR_SIZE - 1)) : a & 0x0fffffff
}

// ------------------------------------------------------------ scratchpad

// fromSPR, normal mode: QWC quadwords from SADR in scratchpad to MADR.
@(private)
dma_from_spr :: proc() {
	madr := dma_reg(DMA_FROM_SPR, 0x10)
	qwc := dma_reg(DMA_FROM_SPR, 0x20)
	sadr := dma_reg(DMA_FROM_SPR, 0x80)
	if (dma_reg(DMA_FROM_SPR, 0)^ >> 2) & 3 != 0 {
		fmt.eprintln("dma: fromSPR chain mode unsupported")
	}
	n := qwc^ & 0xffff
	if k.debug >= 2 {fmt.eprintfln("dma: fromSPR %04x -> %08x qwc %d", sadr^, madr^, n)}
	for _ in 0 ..< n {
		s := sadr^ & (SPR_SIZE - 16)
		intrinsics.unaligned_store((^u128)(&ram_slice(dma_addr(madr^), 16)[0]), intrinsics.unaligned_load((^u128)(&spr[s])))
		madr^ += 16
		sadr^ = (sadr^ + 16) & (SPR_SIZE - 16)
	}
	qwc^ = 0
}

// toSPR: the source chain or normal block into scratchpad at SADR.
@(private)
dma_to_spr :: proc() {
	sadr := dma_reg(DMA_TO_SPR, 0x80)
	if (dma_reg(DMA_TO_SPR, 0)^ >> 2) & 3 != 1 { // normal: copy straight from MADR
		madr := dma_reg(DMA_TO_SPR, 0x10)
		qwc := dma_reg(DMA_TO_SPR, 0x20)
		n := (qwc^ & 0xffff) * 16
		if k.debug >= 2 {fmt.eprintfln("dma: toSPR %08x -> %04x bytes %d", madr^, sadr^, n)}
		if n != 0 {spr_write(sadr, ram_slice(dma_addr(madr^), n))}
		madr^ += n
		qwc^ = 0
		return
	}
	buf := make([dynamic]u8, context.temp_allocator)
	dma_gather(DMA_TO_SPR, &buf)
	if k.debug >= 2 {fmt.eprintfln("dma: toSPR %08x -> %04x bytes %d", dma_reg(DMA_TO_SPR, 0x10)^, sadr^, len(buf))}
	spr_write(sadr, buf[:])
}

// Copy whole quadwords of src to scratchpad at sadr^, wrapping at its end.
@(private)
spr_write :: proc(sadr: ^u32, src: []u8) {
	for i := 0; i + 16 <= len(src); {
		s := sadr^ & (SPR_SIZE - 16)
		n := min(len(src) - i, SPR_SIZE - int(s)) &~ 15
		copy(spr[s:][:n], src[i:][:n])
		i += n
		sadr^ = (sadr^ + u32(n)) & (SPR_SIZE - 16)
	}
}

// ------------------------------------------------------------------- GIF

@(private)
Gif_Path :: struct {
	nloop:  u32, // loops left in the current packet; 0 = expecting a tag
	flg:    u32,
	nreg:   u32,
	regs:   u64,
	reg:    u32, // register index within the loop
}

@(private)
gif_paths: [3]Gif_Path

// Feed qwords to a GIF path (0-2 for PATH1-3).
gif_feed :: proc(path: int, data: []u8) {
	t := prof_start()
	defer prof_end(.GIF, t)
	p := &gif_paths[path]
	q := ([^]u64)(raw_data(data))
	n := len(data) / 16
	for i := 0; i < n; i += 1 {
		lo, hi := q[2 * i], q[2 * i + 1]
		if p.nloop == 0 {
			p.nloop = u32(lo & 0x7fff)
			p.flg = u32(lo >> 58) & 3
			p.nreg = u32(lo >> 60)
			if p.nreg == 0 {p.nreg = 16}
			p.regs = hi
			p.reg = 0
			if lo & (1 << 46) != 0 && p.flg == 0 {gs_write(GS_PRIM, (lo >> 47) & 0x7ff)}
			continue
		}
		switch p.flg {
		case 0: // PACKED
			gif_packed(u8(p.regs >> (4 * p.reg)) & 0xf, lo, hi)
			gif_next_reg(p)
		case 1: // REGLIST: two registers per qword
			for v in ([2]u64{lo, hi}) {
				if p.nloop == 0 {break}
				r := u8(p.regs >> (4 * p.reg)) & 0xf
				if r != 0xe && r != 0xf {gs_write(r, v)}
				gif_next_reg(p)
			}
		case: // IMAGE
			cnt := min(int(p.nloop), n - i)
			gs_image(data[16 * i:][:16 * cnt])
			p.nloop -= u32(cnt)
			i += cnt - 1
		}
	}
}

@(private)
gif_next_reg :: #force_inline proc(p: ^Gif_Path) {
	p.reg += 1
	if p.reg == p.nreg {
		p.reg = 0
		p.nloop -= 1
	}
}

@(private)
gif_packed :: proc(r: u8, lo, hi: u64) {
	switch r {
	case GS_PRIM:
		gs_write(GS_PRIM, lo & 0x7ff)
	case GS_RGBAQ:
		q := u64(transmute(u32)gs.q)
		gs_write(GS_RGBAQ, lo & 0xff | (lo >> 24) & 0xff00 | (hi & 0xff) << 16 | (hi >> 8) & 0xff000000 | q << 32)
	case GS_ST:
		gs.q = transmute(f32)u32(hi)
		gs_write(GS_ST, lo)
	case GS_UV:
		gs_write(GS_UV, lo & 0x3fff | (lo >> 16) & 0x3fff0000)
	case GS_XYZF2:
		v := lo & 0xffff | (lo >> 16) & 0xffff0000 | ((hi >> 4) & 0xffffff) << 32 | ((hi >> 36) & 0xff) << 56
		gs_write(hi & (1 << 47) != 0 ? GS_XYZF3 : GS_XYZF2, v)
	case GS_XYZ2:
		v := lo & 0xffff | (lo >> 16) & 0xffff0000 | (hi & 0xffffffff) << 32
		gs_write(hi & (1 << 47) != 0 ? GS_XYZ3 : GS_XYZ2, v)
	case GS_FOG:
		gs_write(GS_FOG, ((hi >> 36) & 0xff) << 56)
	case 0xe: // A+D
		gs_write(u8(hi), lo)
	case 0xf: // NOP
	case:
		gs_write(r, lo)
	}
}

// ------------------------------------------------------------------- VIF

@(private)
Vif :: struct {
	id:          int,
	vu:          ^Vu,
	cl, wl:      u32,
	mode, mask:  u32,
	row, col:    [4]u32,
	base, ofst:  u32,
	tops, top:   u32,
	itops, itop: u32,
	dbf:         bool,
	pending:     [dynamic]u8, // a command split across transfers
}

@(private)
vifs: [2]Vif

vif_init :: proc() {
	vifs[0] = {id = 0, vu = &vu0, cl = 1, wl = 1}
	vifs[1] = {id = 1, vu = &vu1, cl = 1, wl = 1}
}

@(private)
vif_warned: map[u32]bool

// Feed a transfer's words to a VIF; an incomplete trailing command waits
// for the next transfer.
vif_feed :: proc(v: ^Vif, data: []u8) {
	t := prof_start()
	defer prof_end(.VIF, t)
	buf := data
	if len(v.pending) != 0 {
		append(&v.pending, ..data)
		buf = v.pending[:]
	}
	used := vif_run(v, ([^]u32)(raw_data(buf))[:len(buf) / 4])
	rest := buf[used * 4:]
	if len(v.pending) != 0 {
		remove_range(&v.pending, 0, used * 4)
	} else {
		append(&v.pending, ..rest)
	}
}

// Execute VIF codes; returns the words consumed.
@(private)
vif_run :: proc(v: ^Vif, w: []u32) -> int {
	i := 0
	for i < len(w) {
		code := w[i]
		cmd := (code >> 24) & 0x7f
		imm := code & 0xffff
		num := (code >> 16) & 0xff
		need := 1
		switch {
		case cmd == 0x20: need = 2
		case cmd == 0x30 || cmd == 0x31: need = 5
		case cmd == 0x4a: need = 1 + 2 * int(num == 0 ? 256 : num)
		case cmd == 0x50 || cmd == 0x51: need = 1 + 4 * int(imm == 0 ? 0x10000 : imm)
		case cmd >= 0x60: need = 1 + vif_unpack_words(v, cmd, num)
		}
		if i + need > len(w) {return i}
		arg := w[i + 1:][:need - 1]
		switch cmd {
		case 0x00: // NOP
		case 0x01: // STCYCL
			v.cl, v.wl = imm & 0xff, imm >> 8
		case 0x02: // OFFSET
			v.ofst = imm & 0x3ff
			v.dbf = false
			v.tops = v.base
		case 0x03: v.base = imm & 0x3ff
		case 0x04: v.itops = imm & 0x3ff
		case 0x05: v.mode = imm & 3
		case 0x06, 0x07: // MSKPATH3, MARK
		case 0x10, 0x11, 0x13: // FLUSHE/FLUSH/FLUSHA: the VU runs synchronously
		case 0x14, 0x15: vif_mscal(v, imm * 8)
		case 0x17: vif_mscal(v, v.vu.tpc)
		case 0x20: v.mask = arg[0]
		case 0x30: v.row = {arg[0], arg[1], arg[2], arg[3]}
		case 0x31: v.col = {arg[0], arg[1], arg[2], arg[3]}
		case 0x4a: // MPG
			dst := (imm * 8) % u32(len(v.vu.micro))
			src := ([^]u8)(&arg[0])[:len(arg) * 4]
			for b, j in src {v.vu.micro[(dst + u32(j)) % u32(len(v.vu.micro))] = b}
			if v.vu == &vu1 {vu1_micro_gen += 1}
		case 0x50, 0x51: // DIRECT, DIRECTHL
			gif_feed(1, ([^]u8)(&arg[0])[:len(arg) * 4])
		case 0x60 ..= 0x7f:
			vif_unpack(v, cmd, imm, num, arg)
		case:
			if !vif_warned[cmd] {
				vif_warned[cmd] = true
				fmt.eprintfln("vif%d: unknown code %08x", v.id, code)
			}
		}
		i += need
	}
	return i
}

@(private)
vif_mscal :: proc(v: ^Vif, addr: u32) {
	v.itop = v.itops
	if v.id == 1 {
		v.top = v.tops
		v.dbf = !v.dbf
		v.tops = v.base + (v.dbf ? v.ofst : 0)
		vu1_start(addr)
	} else {
		vu0_call_micro(addr)
	}
}

// Source vectors an UNPACK reads for `num` writes under the cycle setting.
@(private)
vif_unpack_srcs :: proc(v: ^Vif, num: u32) -> u32 {
	num := num == 0 ? 256 : num
	if v.wl <= v.cl {return num}
	return num / v.wl * v.cl + min(num % v.wl, v.cl)
}

@(private)
vif_unpack_bits :: proc(cmd: u32) -> u32 {
	vn, vl := (cmd >> 2) & 3, cmd & 3
	if vl == 3 {return 16} // V4-5
	return (32 >> vl) * (vn + 1)
}

@(private)
vif_unpack_words :: proc(v: ^Vif, cmd, num: u32) -> int {
	return int((vif_unpack_srcs(v, num) * vif_unpack_bits(cmd) + 31) / 32)
}

@(private)
vif_unpack :: proc(v: ^Vif, cmd, imm, num: u32, src: []u32) {
	vn, vl := (cmd >> 2) & 3, cmd & 3
	masked := cmd & 0x10 != 0
	unsigned := imm & 0x4000 != 0
	qwords := u32(len(v.vu.mem) / 16)
	addr := imm & 0x3ff
	if v.id == 1 && imm & 0x8000 != 0 {addr += v.tops}
	num := num == 0 ? 256 : num
	bits := vif_unpack_bits(cmd)
	bytes := ([^]u8)(raw_data(src))
	elem := u32(32) >> vl
	sidx: u32 = 0 // source vector index
	cyc: u32 = 0
	for _ in 0 ..< num {
		dst := (^[4]u32)(&v.vu.mem[(addr % qwords) * 16])
		filling := v.wl > v.cl && cyc >= v.cl
		val: [4]u32
		if !filling {
			bit := sidx * bits
			if vl == 3 {
				h := u32((^u16)(&bytes[bit / 8])^)
				val = {(h & 0x1f) << 3, ((h >> 5) & 0x1f) << 3, ((h >> 10) & 0x1f) << 3, (h >> 15) << 7}
			} else {
				for c in 0 ..= vn {
					off := (bit + c * elem) / 8
					switch vl {
					case 0: val[c] = (^u32)(&bytes[off])^
					case 1:
						h := (^u16)(&bytes[off])^
						val[c] = unsigned ? u32(h) : u32(i32(i16(h)))
					case 2:
						b := bytes[off]
						val[c] = unsigned ? u32(b) : u32(i32(i8(b)))
					}
				}
				switch vn {
				case 0: val = {val[0], val[0], val[0], val[0]}
				case 1: val = {val[0], val[1], val[0], val[1]}
				}
			}
			sidx += 1
		}
		mc := min(cyc, 3)
		for c in 0 ..< 4 {
			sel: u32 = masked ? (v.mask >> (mc * 8 + u32(c) * 2)) & 3 : 0
			if filling && sel == 0 {sel = 1}
			switch sel {
			case 0:
				x := val[c]
				switch v.mode {
				case 1: x += v.row[c]
				case 2:
					x += v.row[c]
					v.row[c] = x
				}
				dst[c] = x
			case 1: dst[c] = v.row[c]
			case 2: dst[c] = v.col[mc]
			}
		}
		addr += 1
		cyc += 1
		if v.wl <= v.cl {
			if cyc == v.wl {
				addr += v.cl - v.wl
				cyc = 0
			}
		} else if cyc == v.wl {
			cyc = 0
		}
	}
}

// ------------------------------------------------------------- channels

@(private)
dma_buf: [dynamic]u8

dma_vif :: proc(ch: u32) {
	clear(&dma_buf)
	dma_gather(ch, &dma_buf)
	vif_feed(&vifs[ch], dma_buf[:])
}

dma_gif :: proc() {
	clear(&dma_buf)
	dma_gather(DMA_GIF, &dma_buf)
	gif_feed(2, dma_buf[:])
}

// Emulated state, saved and restored by snapshots (snap.odin).
@(private)
dma_snap :: proc() {
	core.snap_add(&gif_paths)
	core.snap_add(&vifs)
	core.snap_add(&vif_warned)
	core.snap_add(&dma_buf)
}
