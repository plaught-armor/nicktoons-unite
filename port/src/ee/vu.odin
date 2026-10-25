// Vector units: register files, memories, and VU0 macro mode (COP2
// instructions issued by the EE).
//
// VU floats are IEEE singles without infinities or NaNs, clamped like the
// FPU. MAC/status flags are not tracked yet.
package ee

import "core:fmt"
import "core:math"
import "core:os"

Vf :: struct #raw_union {
	q: u128,
	f: [4]f32,
	u: [4]u32,
	i: [4]i32,
}

Vu :: struct {
	vf:     [32]Vf,
	vi:     [16]u16,
	acc:    Vf,
	q, p:   f32,
	i:      f32,
	r:      u32,
	clip:   u32,
	status: u32,
	mac:    u32,
	fbrst:  u32,
	tpc:    u32,
	cmsar:  u32,
	mem:    []u8,
	micro:  []u8,
}

vu0, vu1: Vu
@(private)
vu0_mem, vu0_micro: [4 << 10]u8
@(private)
vu1_mem, vu1_micro: [16 << 10]u8

vu_init :: proc() {
	vu0.mem, vu0.micro = vu0_mem[:], vu0_micro[:]
	vu1.mem, vu1.micro = vu1_mem[:], vu1_micro[:]
	for v in ([]^Vu{&vu0, &vu1}) {
		v.vf[0].f = {0, 0, 0, 1}
	}
	vif_init()
	vu1_options()
}

// EE mapping of VU memories: 0x11000000 micro0, 0x11004000 mem0,
// 0x11008000 micro1, 0x1100c000 mem1.
vu_mem_addr :: proc(a: u32) -> rawptr {
	if a < 0x11000000 || a >= 0x11010000 {return nil}
	o := a & 0x3fff
	switch (a >> 14) & 3 {
	case 0: if o < 4 << 10 {return &vu0_micro[o]}
	case 1: if o < 4 << 10 {return &vu0_mem[o]}
	case 2:
		vu1_micro_gen += 1
		return &vu1_micro[o]
	case 3: return &vu1_mem[o]
	}
	return nil
}

vu0_set_vf :: proc(n: u8, v: u128) {
	if n != 0 {vu0.vf[n].q = v}
}

vu0_ctrl_read :: proc(n: u8) -> u32 {
	switch n {
	case 0 ..< 16: return u32(vu0.vi[n])
	case 16: return vu0.status
	case 17: return vu0.mac
	case 18: return vu0.clip
	case 20: return vu0.r
	case 21: return transmute(u32)vu0.i
	case 22: return transmute(u32)vu0.q
	case 26: return vu0.tpc
	case 27: return vu0.cmsar
	case 28: return vu0.fbrst
	case 29: return 0 // VPU-STAT: both VUs idle
	case 31: return vu1.cmsar
	}
	return 0
}

vu0_ctrl_write :: proc(n: u8, v: u32) {
	switch n {
	case 1 ..< 16: vu0.vi[n] = u16(v)
	case 16: vu0.status = v
	case 18: vu0.clip = v
	case 20: vu0.r = v & 0x7fffff
	case 21: vu0.i = transmute(f32)v
	case 22: vu0.q = transmute(f32)v
	case 27: vu0.cmsar = v
	case 28: vu0.fbrst = v
	case 31: vu1_start(v)
	}
}

@(private)
vclamp :: #force_inline proc(x: f32) -> f32 {return fclamp(x)}

// VU0 macro instruction (COP2 with CO set).
vu0_macro :: proc(w: u32) {
	vu_op(&vu0, w)
}

// One operation in COP2 layout. Macro instructions, micro-mode upper
// words and micro-mode lower words with opcode 0x40 share this encoding:
// fn 0x00-0x2f and special 0x00-0x2f are upper ops, fn 0x30-0x3b and
// special 0x30-0x7f lower ops.
vu_op :: proc(v: ^Vu, w: u32) {
	dest := (w >> 21) & 15 // x = 8, y = 4, z = 2, w = 1
	ft := (w >> 16) & 31
	fs := (w >> 11) & 31
	fd := (w >> 6) & 31
	fn := w & 63
	bc := w & 3

	// Write lanes selected by dest and set the MAC flags from them.
	put :: proc(v: ^Vu, n: u32, dest: u32, r: [4]f32) {
		dst := n == 0 ? nil : &v.vf[n]
		vu_put_flags(v, dst, dest, r)
	}
	put_acc :: proc(v: ^Vu, dest: u32, r: [4]f32) {
		vu_put_flags(v, &v.acc, dest, r)
	}
	// Write lanes without touching flags (ITOF, ABS, MFP).
	put_raw :: proc(v: ^Vu, n: u32, dest: u32, r: [4]f32) {
		if n == 0 {return}
		for k in 0 ..< 4 {
			if dest & (8 >> u32(k)) != 0 {v.vf[n].f[k] = vclamp(r[k])}
		}
	}
	s := v.vf[fs].f
	t := v.vf[ft].f
	splat :: proc(x: f32) -> [4]f32 {return {x, x, x, x}}

	if fn < 0x3c {
		switch fn {
		case 0x00 ..= 0x03: put(v, fd, dest, s + splat(t[bc]))
		case 0x04 ..= 0x07: put(v, fd, dest, s - splat(t[bc]))
		case 0x08 ..= 0x0b: put(v, fd, dest, v.acc.f + s * splat(t[bc]))
		case 0x0c ..= 0x0f: put(v, fd, dest, v.acc.f - s * splat(t[bc]))
		case 0x10 ..= 0x13: put(v, fd, dest, vmax(s, splat(t[bc])))
		case 0x14 ..= 0x17: put(v, fd, dest, vmin(s, splat(t[bc])))
		case 0x18 ..= 0x1b: put(v, fd, dest, s * splat(t[bc]))
		case 0x1c: put(v, fd, dest, s * splat(v.q))
		case 0x1d: put(v, fd, dest, vmax(s, splat(v.i)))
		case 0x1e: put(v, fd, dest, s * splat(v.i))
		case 0x1f: put(v, fd, dest, vmin(s, splat(v.i)))
		case 0x20: put(v, fd, dest, s + splat(v.q))
		case 0x21: put(v, fd, dest, v.acc.f + s * splat(v.q))
		case 0x22: put(v, fd, dest, s + splat(v.i))
		case 0x23: put(v, fd, dest, v.acc.f + s * splat(v.i))
		case 0x24: put(v, fd, dest, s - splat(v.q))
		case 0x25: put(v, fd, dest, v.acc.f - s * splat(v.q))
		case 0x26: put(v, fd, dest, s - splat(v.i))
		case 0x27: put(v, fd, dest, v.acc.f - s * splat(v.i))
		case 0x28: put(v, fd, dest, s + t)
		case 0x29: put(v, fd, dest, v.acc.f + s * t)
		case 0x2a: put(v, fd, dest, s * t)
		case 0x2b: put(v, fd, dest, vmax(s, t))
		case 0x2c: put(v, fd, dest, s - t)
		case 0x2d: put(v, fd, dest, v.acc.f - s * t)
		case 0x2e: // VOPMSUB: fd.xyz = acc - fs.yzx * ft.zxy
			r := v.acc.f - [4]f32{s.y * t.z, s.z * t.x, s.x * t.y, 0}
			put(v, fd, 0xe, r)
		case 0x2f: put(v, fd, dest, vmin(s, t))
		case 0x30: if fd != 0 {v.vi[fd & 15] = v.vi[fs & 15] + v.vi[ft & 15]}
		case 0x31: if fd != 0 {v.vi[fd & 15] = v.vi[fs & 15] - v.vi[ft & 15]}
		case 0x32: // VIADDI: imm5 in the fd field
			imm := u16(i16(i8(u8(fd) << 3) >> 3))
			if ft != 0 {v.vi[ft & 15] = v.vi[fs & 15] + imm}
		case 0x34: if fd != 0 {v.vi[fd & 15] = v.vi[fs & 15] & v.vi[ft & 15]}
		case 0x35: if fd != 0 {v.vi[fd & 15] = v.vi[fs & 15] | v.vi[ft & 15]}
		case 0x38: vu0_call_micro(((w >> 6) & 0x7fff) * 8)
		case 0x39: vu0_call_micro(u32(v.cmsar) * 8)
		case:
			fatal("vu%d: unknown op %08x", v == &vu1 ? 1 : 0, w)
		}
		return
	}

	fsf := (w >> 21) & 3
	ftf := (w >> 23) & 3
	is := fs & 15
	it := ft & 15
	switch ((w >> 4) & 0x7c) | (w & 3) {
	case 0x00 ..= 0x03: put_acc(v, dest, s + splat(t[bc]))
	case 0x04 ..= 0x07: put_acc(v, dest, s - splat(t[bc]))
	case 0x08 ..= 0x0b: put_acc(v, dest, v.acc.f + s * splat(t[bc]))
	case 0x0c ..= 0x0f: put_acc(v, dest, v.acc.f - s * splat(t[bc]))
	case 0x10 ..= 0x13: // ITOF0/4/12/15
		@(static, rodata) itof_scale := [4]f32{1, 1.0 / 16, 1.0 / 4096, 1.0 / 32768}
		scale := itof_scale[w & 3]
		r: [4]f32
		for k in 0 ..< 4 {r[k] = f32(v.vf[fs].i[k]) * scale}
		put_raw(v, ft, dest, r)
	case 0x14 ..= 0x17: // FTOI0/4/12/15
		@(static, rodata) ftoi_scale := [4]f32{1, 16, 4096, 32768}
		scale := ftoi_scale[w & 3]
		if ft != 0 {
			for k in 0 ..< 4 {
				if dest & (8 >> u32(k)) != 0 {v.vf[ft].i[k] = cvt_w(s[k] * scale)}
			}
		}
	case 0x18 ..= 0x1b: put_acc(v, dest, s * splat(t[bc]))
	case 0x1c: put_acc(v, dest, s * splat(v.q))
	case 0x1d: put_raw(v, ft, dest, {abs(s.x), abs(s.y), abs(s.z), abs(s.w)})
	case 0x1e: put_acc(v, dest, s * splat(v.i))
	case 0x1f: // VCLIP
		lim := abs(t.w)
		f: u32 = 0
		for k in 0 ..< 3 {
			if s[k] > lim {f |= 1 << (2 * u32(k))}
			if s[k] < -lim {f |= 2 << (2 * u32(k))}
		}
		v.clip = ((v.clip << 6) | f) & 0xffffff
	case 0x20: put_acc(v, dest, s + splat(v.q))
	case 0x21: put_acc(v, dest, v.acc.f + s * splat(v.q))
	case 0x22: put_acc(v, dest, s + splat(v.i))
	case 0x23: put_acc(v, dest, v.acc.f + s * splat(v.i))
	case 0x24: put_acc(v, dest, s - splat(v.q))
	case 0x25: put_acc(v, dest, v.acc.f - s * splat(v.q))
	case 0x26: put_acc(v, dest, s - splat(v.i))
	case 0x27: put_acc(v, dest, v.acc.f - s * splat(v.i))
	case 0x28: put_acc(v, dest, s + t)
	case 0x29: put_acc(v, dest, v.acc.f + s * t)
	case 0x2a: put_acc(v, dest, s * t)
	case 0x2c: put_acc(v, dest, s - t)
	case 0x2d: put_acc(v, dest, v.acc.f - s * t)
	case 0x2e: put_acc(v, 0xe, {s.y * t.z, s.z * t.x, s.x * t.y, 0}) // VOPMULA
	case 0x2f: // VNOP
	case 0x30: // VMOVE
		if ft != 0 {
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = v.vf[fs].u[k]}}
		}
	case 0x31: // VMR32: rotate fs one lane: ft.x = fs.y, y = z, z = w, w = x
		r := v.vf[fs].u
		r = {r[1], r[2], r[3], r[0]}
		if ft != 0 {
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = r[k]}}
		}
	case 0x34, 0x36: // VLQI, VLQD
		if w & 3 == 2 {v.vi[is] -= 1}
		q := vu_mem_q(v, v.vi[is])
		if ft != 0 {
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = q[k]}}
		}
		if w & 3 == 0 && is != 0 {v.vi[is] += 1}
		v.vi[0] = 0
	case 0x35, 0x37: // VSQI, VSQD: store fs to [it]
		if w & 3 == 3 {v.vi[it] -= 1}
		q := vu_mem_q(v, v.vi[it])
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {q[k] = v.vf[fs].u[k]}}
		if w & 3 == 1 && it != 0 {v.vi[it] += 1}
		v.vi[0] = 0
	case 0x38: // VDIV
		vu_div_flags(v, s[fsf], t[ftf])
		v.q = fdiv(s[fsf], t[ftf])
	case 0x39: // VSQRT
		vu_div_flags(v, 1, t[ftf] < 0 ? 0 : 1)
		v.q = math.sqrt(abs(t[ftf]))
	case 0x3a: // VRSQRT
		vu_div_flags(v, s[fsf], t[ftf])
		v.q = frsqrt(s[fsf], t[ftf])
	case 0x3b: // VWAITQ
	case 0x3c: if it != 0 {v.vi[it] = u16(v.vf[fs].u[fsf])} // VMTIR
	case 0x3d: // VMFIR
		if ft != 0 {
			x := u32(i32(i16(v.vi[is])))
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = x}}
		}
	case 0x3e: // VILWR
		q := vu_mem_q(v, v.vi[is])
		if it != 0 {
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vi[it] = u16(q[k])}}
		}
	case 0x3f: // VISWR
		q := vu_mem_q(v, v.vi[is])
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {q[k] = u32(v.vi[it])}}
	case 0x40: // VRNEXT
		x := v.r
		x = ((x << 1) | (((x >> 4) ~ (x >> 22)) & 1)) & 0x7fffff
		v.r = x
		vu_put_r(v, ft, dest)
	case 0x41: vu_put_r(v, ft, dest) // VRGET
	case 0x42: v.r = v.vf[fs].u[fsf] & 0x7fffff // VRINIT
	case 0x43: v.r = (v.r ~ v.vf[fs].u[fsf]) & 0x7fffff // VRXOR
	// Micro mode only from here on.
	case 0x64: put_raw(v, ft, dest, splat(v.p)) // MFP
	case 0x68: if it != 0 {v.vi[it] = u16(vifs[1].top)} // XTOP
	case 0x69: if it != 0 {v.vi[it] = u16(vifs[1].itop)} // XITOP
	case 0x6c: vu1_xgkick(v.vi[is]) // XGKICK
	case 0x70: v.p = vclamp(s.x * s.x + s.y * s.y + s.z * s.z) // ESADD
	case 0x71: v.p = fdiv(1, s.x * s.x + s.y * s.y + s.z * s.z) // ERSADD
	case 0x72: v.p = math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z) // ELENG
	case 0x73: v.p = frsqrt(1, s.x * s.x + s.y * s.y + s.z * s.z) // ERLENG
	case 0x74: v.p = math.atan(fdiv(s.y, s.x)) // EATANxy
	case 0x75: v.p = math.atan(fdiv(s.z, s.x)) // EATANxz
	case 0x76: v.p = vclamp(s.x + s.y + s.z + s.w) // ESUM
	case 0x78: v.p = math.sqrt(abs(s[fsf])) // ESQRT
	case 0x79: v.p = frsqrt(1, s[fsf]) // ERSQRT
	case 0x7a: v.p = fdiv(1, s[fsf]) // ERCPR
	case 0x7b: // WAITP
	case 0x7c: v.p = math.sin(s[fsf]) // ESIN
	case 0x7d: v.p = math.atan(s[fsf]) // EATAN
	case 0x7e: v.p = vclamp(math.exp(-s[fsf])) // EEXP
	case:
		fatal("vu%d: unknown op %08x", v == &vu1 ? 1 : 0, w)
	}
}

// Store the dest lanes of `r` into `dst` (nil discards, as for VF00) and
// set MAC Z/S bits for them; status takes the OR plus sticky copies.
@(private)
vu_put_flags :: proc(v: ^Vu, dst: ^Vf, dest: u32, r: [4]f32) {
	// Branchless: every lane is computed, then masked by dest.
	mac: u32 = 0
	x: [4]f32
	for k in 0 ..< 4 {
		x[k] = vclamp(r[k])
		u := transmute(u32)x[k]
		bit := u32(8) >> u32(k)
		mac |= u32(u << 1 == 0) * bit | (u >> 31) * (bit << 4)
	}
	mac &= dest | dest << 4
	if dst != nil {
		for k in 0 ..< 4 {
			if dest & (8 >> u32(k)) != 0 {dst.f[k] = x[k]}
		}
	}
	v.mac = mac
	st: u32 = 0
	if mac & 0x0f != 0 {st |= 1}
	if mac & 0xf0 != 0 {st |= 2}
	v.status = (v.status &~ 0xf) | st | st << 6
}

// Status I/D bits for DIV-family ops: 0/0 is invalid, x/0 divide by zero.
@(private)
vu_div_flags :: proc(v: ^Vu, a, b: f32) {
	f: u32 = 0
	if b == 0 {f = a == 0 ? 0x10 : 0x20}
	v.status = (v.status &~ 0x30) | f | f << 6
}

@(private)
vu_put_r :: proc(v: ^Vu, ft, dest: u32) {
	x := 0x3f800000 | v.r
	if ft != 0 {
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = x}}
	}
}

// Quadword `n` of a VU data memory (wrapping like the hardware).
vu_mem_q :: proc(v: ^Vu, n: u16) -> ^[4]u32 {
	o := (u32(n) * 16) % u32(len(v.mem))
	return (^[4]u32)(&v.mem[o])
}

@(private)
vmax :: proc(a, b: [4]f32) -> [4]f32 {return {max(a.x, b.x), max(a.y, b.y), max(a.z, b.z), max(a.w, b.w)}}
@(private)
vmin :: proc(a, b: [4]f32) -> [4]f32 {return {min(a.x, b.x), min(a.y, b.y), min(a.z, b.z), min(a.w, b.w)}}

// ------------------------------------------------------------ micro mode

VU_STEP_LIMIT :: 1 << 24

@(private)
vu1_overrun: bool

// How compiled microcode stopped: at the E bit's end, or by handing the
// pair at the returned pc to the interpreter.
Vu1_Exit :: enum u8 {End, Leave}

// A VU1 microprogram compiled ahead of time (rec/vu1). `run` executes from
// a pair address below len(code)*4; taken branches count against budget.
Vu1_Run :: #type proc(pc: u32, budget: ^int) -> (u32, Vu1_Exit)

@(private)
Vu1_Program :: struct {
	code: []u32,
	run:  Vu1_Run,
}

@(private)
vu1_programs: [dynamic]Vu1_Program
@(private)
vu1_resident: ^Vu1_Program // the compiled program micro memory holds
// Bumped on every write path into VU1 micro memory; vu1_resident is
// rechecked when it moves.
vu1_micro_gen: u32 = 1
@(private)
vu1_resident_gen: u32

vu1_register :: proc(code: []u32, run: Vu1_Run) {
	append(&vu1_programs, Vu1_Program{code, run})
}

// The longest registered program that micro memory starts with.
@(private)
vu1_find_resident :: proc() {
	vu1_resident_gen = vu1_micro_gen
	vu1_resident = nil
	if vu1_nocomp {return}
	micro := ([^]u32)(&vu1_micro[0])[:len(vu1_micro) / 4]
	for &p in vu1_programs {
		if len(p.code) > len(micro) {continue}
		if vu1_resident != nil && len(p.code) <= len(vu1_resident.code) {continue}
		if slice_equal(micro[:len(p.code)], p.code) {vu1_resident = &p}
	}
}

@(private)
slice_equal :: proc(a, b: []u32) -> bool {
	for x, i in a {if x != b[i] {return false}}
	return true
}

@(private)
vu1_nocomp, vu1_check: bool

// NT_VUNOCOMP=1 runs everything in the interpreter; NT_VUCHECK=1 runs
// every microprogram both ways and reports differences.
vu1_options :: proc() {
	vu1_nocomp = os.get_env("NT_VUNOCOMP", context.temp_allocator) != ""
	vu1_check = os.get_env("NT_VUCHECK", context.temp_allocator) != ""
	vu1_resident_gen = 0
}

// Run a VU1 microprogram to its E bit. The VU runs synchronously with the
// EE, without pipeline timing: results are visible to the next pair.
vu1_start :: proc(addr: u32) {
	t := prof_start()
	defer prof_end(.VU1, t)
	if vu1_resident_gen != vu1_micro_gen {vu1_find_resident()}
	if vu1_check && vu1_resident != nil {
		vu1_compare(addr)
		return
	}
	vu1_exec(addr, vu1_resident)
}

@(private)
vu1_exec :: proc(addr: u32, prog: ^Vu1_Program) {
	v := &vu1
	mask := u32(len(v.micro) - 1) &~ 7
	pc := addr & mask
	size := prog == nil ? 0 : u32(len(prog.code) * 4)
	budget := VU_STEP_LIMIT
	for budget > 0 {
		if pc < size {
			exit: Vu1_Exit
			pc, exit = prog.run(pc, &budget)
			if exit == .End {
				v.tpc = pc
				return
			}
			if budget <= 0 {break}
		}
		ended: bool
		pc, ended = vu1_interp(pc, size, &budget)
		if ended {
			v.tpc = pc
			return
		}
	}
	if !vu1_overrun {
		vu1_overrun = true
		fmt.eprintfln("vu1: microprogram at %04x ran %d steps without ending", addr, VU_STEP_LIMIT)
	}
	v.tpc = pc
}

// Interpret from pc for at least one pair, until the program ends or
// control is back below `size` (compiled code) with no branch or end
// pending.
@(private)
vu1_interp :: proc(pc: u32, size: u32, budget: ^int) -> (u32, bool) {
	v := &vu1
	mask := u32(len(v.micro) - 1) &~ 7
	pc := pc
	jumping, ending := false, false
	target: u32
	for budget^ > 0 {
		budget^ -= 1
		lw := (^u32)(&v.micro[pc])^
		uw := (^u32)(&v.micro[pc + 4])^
		next := (pc + 8) & mask
		info := &vu1_pairs[pc >> 3]
		if info.uw != uw || info.lw != lw || !info.valid {
			info^ = vu_pair_info(uw, lw)
		}
		taken: bool
		dst: u32
		if info.serial {
			vu_op(v, uw)
			taken, dst = vu_lower(v, lw, pc)
		} else {
			taken, dst = vu_pair(v, uw, lw, pc)
		}
		if jumping { // that was the delay slot
			next = target & mask
			jumping = false
		}
		if taken {
			jumping = true
			target = dst
		}
		if ending {return next, true}
		if uw & (1 << 30) != 0 {ending = true}
		pc = next
		if !jumping && !ending && pc < size {break}
	}
	return pc, false
}

// NT_VUCHECK: run the interpreter, then the compiled code from the same
// state with XGKICK muted, and compare. Status is not compared (compiled
// code never computes it). The interpreter's results are kept.
@(private)
vu1_compare :: proc(addr: u32) {
	@(static) mem0, mem1: [len(vu1_mem)]u8
	@(static) reported: int
	v0 := vu1
	mem0 = vu1_mem
	vu1_kick_hash = 0
	vu1_exec(addr, nil)
	v1, kick1 := vu1, vu1_kick_hash
	mem1 = vu1_mem
	vu1 = v0
	vu1_mem = mem0
	vu1_kick_hash, vu1_kick_mute = 0, true
	vu1_exec(addr, vu1_resident)
	vu1_kick_mute = false
	v2, kick2 := vu1, vu1_kick_hash
	vf_bad := false
	for k in 0 ..< 32 {vf_bad ||= v1.vf[k].q != v2.vf[k].q}
	prog := -1
	for &p, k in vu1_programs {if &p == vu1_resident {prog = k}}
	bad := kick1 != kick2 || vu1_mem != mem1 || vf_bad || v1.vi != v2.vi ||
		v1.acc.q != v2.acc.q || v1.q != v2.q || v1.p != v2.p || v1.i != v2.i ||
		v1.r != v2.r || v1.clip != v2.clip || v1.mac != v2.mac || v1.tpc != v2.tpc
	if bad && reported < 20 {
		reported += 1
		fmt.eprintfln("vucheck: program %d entry %04x differs: kick %v vf %v vi %v acc %v q %v p %v i %v clip %v mac %v (%04x/%04x) tpc %v mem %v",
			prog, addr, kick1 != kick2, vf_bad, v1.vi != v2.vi,
			v1.acc.q != v2.acc.q, v1.q != v2.q, v1.p != v2.p, v1.i != v2.i, v1.clip != v2.clip,
			v1.mac != v2.mac, v1.mac, v2.mac, v1.tpc != v2.tpc, vu1_mem != mem1)
		for k in 0 ..< 32 {
			if v1.vf[k].q != v2.vf[k].q {fmt.eprintfln("  vf%d %v / %v", k, v1.vf[k].f, v2.vf[k].f)}
		}
		for k in 0 ..< 16 {
			if v1.vi[k] != v2.vi[k] {fmt.eprintfln("  vi%d %04x / %04x", k, v1.vi[k], v2.vi[k])}
		}
	}
	vu1 = v1
	vu1_mem = mem1
}

// Public entry points for compiled microcode.
vu1_upper :: proc(uw: u32) {vu_op(&vu1, uw)}
vu1_lower :: proc(lw, pc: u32) {vu_lower(&vu1, lw, pc)}
vu1_pair :: proc(uw, lw, pc: u32) {vu_pair(&vu1, uw, lw, pc)}

// What decoding a pair tells the interpreter, cached per micro address and
// tagged with the words so uploads need no invalidation.
@(private)
Vu_Pair_Info :: struct {
	uw, lw: u32,
	valid:  bool,
	serial: bool, // running upper then lower gives the same result as vu_pair
}

@(private)
vu1_pairs: [len(vu1_micro) / 8]Vu_Pair_Info

// A pair can run in sequence when the lower op neither reads nor writes the
// VF register the upper writes and leaves the flags alone: the upper writes
// nothing else the lower reads (VI, Q, P and R belong to the lower side).
@(private)
vu_pair_info :: proc(uw, lw: u32) -> Vu_Pair_Info {
	info := Vu_Pair_Info{uw = uw, lw = lw, valid = true}
	if uw & (1 << 31) != 0 {return info} // I bit: vu_pair's own path
	ud := vu_upper_dest(uw)
	ft, fs := (lw >> 16) & 31, (lw >> 11) & 31
	touches := ud != 0 && (ft == ud || fs == ud)
	switch lw >> 25 {
	case 0x00: info.serial = ud == 0 || ft != ud // LQ
	case 0x01: info.serial = ud == 0 || fs != ud // SQ
	case 0x04, 0x05, 0x08, 0x09, 0x20, 0x21, 0x24, 0x25, 0x28, 0x29, 0x2c ..= 0x2f:
		info.serial = true // VI, memory and branches
	case 0x40:
		if lw & 63 < 0x3c {
			info.serial = true // IADD family
			break
		}
		switch ((lw >> 4) & 0x7c) | (lw & 3) {
		case 0x38 ..= 0x3a: // DIV family sets status
		case 0x3b, 0x3e, 0x3f, 0x68, 0x69, 0x6c, 0x7b: info.serial = true
		case: info.serial = !touches
		}
	}
	return info
}

// Execute one upper/lower pair. Both halves read registers before either
// writes; when both write the same VF register the lower result wins.
@(private)
vu_pair :: proc(v: ^Vu, uw, lw, pc: u32) -> (taken: bool, target: u32) {
	if uw & (1 << 31) != 0 { // I bit: the lower word is a float for I
		v.i = transmute(f32)lw
		vu_op(v, uw)
		return
	}
	ud := vu_upper_dest(uw)
	saved := v.vf[ud]
	flags := [3]u32{v.mac, v.status, v.clip}
	vu_op(v, uw)
	result := v.vf[ud]
	uflags := [3]u32{v.mac, v.status, v.clip}
	v.vf[ud] = saved
	v.mac, v.status, v.clip = flags[0], flags[1], flags[2]
	taken, target = vu_lower(v, lw, pc)
	if v.vf[ud].q == saved.q {v.vf[ud] = result}
	if v.mac == flags[0] {v.mac = uflags[0]}
	if v.status == flags[1] {v.status = uflags[1]}
	if v.clip == flags[2] {v.clip = uflags[2]}
	return
}

// The VF register an upper op writes (0 for ACC-only or none).
@(private)
vu_upper_dest :: proc(w: u32) -> u32 {
	if w & 63 < 0x3c {return (w >> 6) & 31}
	switch ((w >> 4) & 0x7c) | (w & 3) {
	case 0x10 ..= 0x17, 0x1d: return (w >> 16) & 31
	}
	return 0
}

// Micro-mode lower word. Returns a branch and its target byte address.
@(private)
vu_lower :: proc(v: ^Vu, w, pc: u32) -> (taken: bool, target: u32) {
	dest := (w >> 21) & 15
	ft, fs := (w >> 16) & 31, (w >> 11) & 31
	it, is := ft & 15, fs & 15
	imm11 := u16(i16(u16(w & 0x7ff) << 5) >> 5)
	imm12 := ((w >> 10) & 0x800) | (w & 0x7ff)
	imm15 := u16(((w >> 10) & 0x7800) | (w & 0x7ff))
	imm24 := w & 0xffffff
	vi := &v.vi
	branch := pc + 8 + u32(i32(i16(imm11))) * 8
	set_vi :: #force_inline proc(vi: ^[16]u16, n: u32, x: u16) {if n != 0 {vi[n] = x}}
	switch w >> 25 {
	case 0x00: // LQ
		q := vu_mem_q(v, vi[is] + imm11)
		if ft != 0 {
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = q[k]}}
		}
	case 0x01: // SQ
		q := vu_mem_q(v, vi[it] + imm11)
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {q[k] = v.vf[fs].u[k]}}
	case 0x04: // ILW
		q := vu_mem_q(v, vi[is] + imm11)
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {set_vi(vi, it, u16(q[k]))}}
	case 0x05: // ISW
		q := vu_mem_q(v, vi[is] + imm11)
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {q[k] = u32(vi[it])}}
	case 0x08: set_vi(vi, it, vi[is] + imm15) // IADDIU
	case 0x09: set_vi(vi, it, vi[is] - imm15) // ISUBIU
	case 0x10: vi[1] = u16(v.clip & 0xffffff == imm24) // FCEQ
	case 0x11: v.clip = imm24 // FCSET
	case 0x12: vi[1] = u16(v.clip & imm24 != 0) // FCAND
	case 0x13: vi[1] = u16((v.clip | imm24) & 0xffffff == 0xffffff) // FCOR
	case 0x14: set_vi(vi, it, u16(v.status & 0xfff == imm12)) // FSEQ
	case 0x15: v.status = (v.status & 0x3f) | (imm12 & 0xfc0) // FSSET
	case 0x16: set_vi(vi, it, u16(v.status & imm12)) // FSAND
	case 0x17: set_vi(vi, it, u16((v.status | imm12) & 0xfff == 0xfff)) // FSOR
	case 0x18: set_vi(vi, it, u16(v.mac & 0xffff == u32(vi[is]))) // FMEQ
	case 0x1a: set_vi(vi, it, u16(v.mac) & vi[is]) // FMAND
	case 0x1b: set_vi(vi, it, u16((v.mac | u32(vi[is])) & 0xffff == 0xffff)) // FMOR
	case 0x1c: set_vi(vi, it, u16(v.clip & 0xfff)) // FCGET
	case 0x20: return true, branch // B
	case 0x21: // BAL
		set_vi(vi, it, u16((pc + 16) / 8))
		return true, branch
	case 0x24: return true, u32(vi[is]) * 8 // JR
	case 0x25: // JALR
		t := u32(vi[is]) * 8
		set_vi(vi, it, u16((pc + 16) / 8))
		return true, t
	case 0x28: return vi[it] == vi[is], branch // IBEQ
	case 0x29: return vi[it] != vi[is], branch // IBNE
	case 0x2c: return i16(vi[is]) < 0, branch // IBLTZ
	case 0x2d: return i16(vi[is]) > 0, branch // IBGTZ
	case 0x2e: return i16(vi[is]) <= 0, branch // IBLEZ
	case 0x2f: return i16(vi[is]) >= 0, branch // IBGEZ
	case 0x40: vu_op(v, w)
	case:
		fatal("vu1: unknown lower op %08x at %04x", w, pc)
	}
	return
}

// XGKICK: send the GIF packet at quadword `addr` of VU1 memory down PATH1,
// following tags to the one with EOP.
@(private)
vu1_kick_hash: u64
@(private)
vu1_kick_mute: bool

vu1_xgkick :: proc(addr: u16) {
	@(static) buf: [dynamic]u8
	clear(&buf)
	qwords := u32(len(vu1_mem) / 16)
	a := u32(addr) % qwords
	for total: u32 = 0; total < qwords; {
		lo := (^u64)(&vu1_mem[a * 16])^
		nloop, nreg := u32(lo & 0x7fff), u32(lo >> 60)
		if nreg == 0 {nreg = 16}
		n: u32 = 1
		switch (lo >> 58) & 3 {
		case 0: n += nloop * nreg
		case 1: n += (nloop * nreg + 1) / 2
		case: n += nloop
		}
		for _ in 0 ..< n {
			append(&buf, ..vu1_mem[a * 16:][:16])
			a = (a + 1) % qwords
		}
		total += n
		if lo & 0x8000 != 0 {break}
	}
	if vu1_check {
		for b in buf {vu1_kick_hash = (vu1_kick_hash ~ u64(b)) * 0x100000001b3}
		if vu1_kick_mute {return}
	}
	gif_feed(1, buf[:])
}

vu0_call_micro :: proc(addr: u32) {
	fatal("vu0: microprogram call at %04x not implemented", addr)
}

// Emulated state, saved and restored by snapshots (snap.odin).
@(private)
vu_snap :: proc() {
	snap_add(&vu0)
	snap_add(&vu1)
	snap_add(&vu0_mem)
	snap_add(&vu0_micro)
	snap_add(&vu1_mem)
	snap_add(&vu1_micro)
	snap_add(&vu1_overrun)
	snap_add(&vu1_resident)
	snap_add(&vu1_micro_gen)
	snap_add(&vu1_resident_gen)
	snap_add(&vu1_pairs)
	snap_add(&vu1_kick_hash)
	snap_add(&vu1_kick_mute)
}
