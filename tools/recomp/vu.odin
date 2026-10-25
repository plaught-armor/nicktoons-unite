// `gen` also writes rec/vu1: the VU1 microprograms of .vutext compiled to
// Odin.
//
// .vutext holds whole programs, each a run of VIF MPG chunks loading
// consecutive micro memory from address 0. A program becomes one proc with
// a switch case per instruction pair, so it can be entered at any pair:
// straight-line pairs fall through, a branch inlines its delay slot and
// re-dispatches. Pairs keep the interpreter's semantics (port/src/ee/vu.odin):
// the common ops are specialized, the rest call back into ee. Whatever does
// not fit (a branch or E bit in a delay slot, code running past the program)
// returns to the interpreter at that pair.
//
// MAC flags are computed only where a later FMAND/FMEQ/FMOR or an exit can
// see them. Status flags are never computed: no program reads them (no
// FSEQ/FSAND/FSOR/FSSET), and the EE cannot read VU1 status.
package recomp

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

@(private = "file")
MASK :: 0x3ff8

@(private = "file")
Branch :: enum u8 {None, Uncond, Cond, Reg}

@(private = "file")
Pair :: struct {
	lw, uw:     u32,
	ibit, ebit: bool,
	branch:     Branch,
	mode:       Mode,
	mac_rd:     bool, // reads MAC before writing it
	mac_wr:     bool, // the upper op sets MAC
	mac_live:   bool, // MAC after this pair can be read
}

// How a pair's halves are ordered against the interpreter's vu_pair.
@(private = "file")
Mode :: enum u8 {
	Serial, // upper then lower: neither sees the other's writes
	Lower_First, // the lower reads flags the upper writes, and writes only VI
	Slow, // ee.vu1_pair
}

@(private = "file")
Prog :: struct {
	words: [dynamic]u32, // lw, uw from micro address 0
}

@(private = "file")
find_programs :: proc(img: ^Image) -> (progs: [dynamic]Prog, ok: bool) {
	sec := find_section(img, ".vutext")
	if sec == nil {return progs, true}
	n := sec.size / 4
	w := ([^]u32)(raw_data(sec.data))[:n]
	end: u32 = 0
	for i: u32 = 0; i < n; {
		code := w[i]
		if (code >> 24) & 0x7f != 0x4a {
			i += 1
			continue
		}
		num := (code >> 16) & 0xff
		if num == 0 {num = 256}
		addr := (code & 0xffff) * 8
		if i + 1 + num * 2 > n {
			fmt.eprintfln("vu: MPG at %08x runs past .vutext", sec.addr + i * 4)
			return progs, false
		}
		if addr == 0 {
			append(&progs, Prog{})
			end = 0
		}
		if len(progs) == 0 || addr != end {
			fmt.eprintfln("vu: MPG at %08x loads %04x, expected %04x", sec.addr + i * 4, addr, end)
			return progs, false
		}
		append(&progs[len(progs) - 1].words, ..w[i + 1:][:num * 2])
		end = addr + num * 8
		i += 1 + num * 2
	}
	return progs, true
}

@(private = "file")
upper_writes_mac :: proc(uw: u32) -> bool {
	if uw & 63 < 0x3c {return true}
	switch ((uw >> 4) & 0x7c) | (uw & 3) {
	case 0x10 ..= 0x17, 0x1d, 0x1f, 0x2f: return false // ITOF, FTOI, ABS, CLIP, NOP
	}
	return true
}

// The VF register the upper op writes (0 for ACC-only or none), as
// vu_upper_dest.
@(private = "file")
upper_dest :: proc(uw: u32) -> u32 {
	if uw & 63 < 0x3c {return (uw >> 6) & 31}
	switch ((uw >> 4) & 0x7c) | (uw & 3) {
	case 0x10 ..= 0x17, 0x1d: return (uw >> 16) & 31
	}
	return 0
}

@(private = "file")
classify :: proc(lw, uw: u32) -> Pair {
	p := Pair{lw = lw, uw = uw, ibit = uw & (1 << 31) != 0, ebit = uw & (1 << 30) != 0}
	p.mac_wr = upper_writes_mac(uw)
	if p.ibit {return p}
	switch lw >> 25 {
	case 0x20, 0x21: p.branch = .Uncond
	case 0x24, 0x25: p.branch = .Reg
	case 0x28, 0x29, 0x2c ..= 0x2f: p.branch = .Cond
	}
	// As vu_pair_info, plus flag readers that can run first.
	ud := upper_dest(uw)
	ft, fs := (lw >> 16) & 31, (lw >> 11) & 31
	touches := ud != 0 && (ft == ud || fs == ud)
	p.mode = .Slow
	switch lw >> 25 {
	case 0x00: if ud == 0 || ft != ud {p.mode = .Serial}
	case 0x01: if ud == 0 || fs != ud {p.mode = .Serial}
	case 0x04, 0x05, 0x08, 0x09, 0x20, 0x21, 0x24, 0x25, 0x28, 0x29, 0x2c ..= 0x2f:
		p.mode = .Serial
	case 0x11: // FCSET: unless CLIP also writes the clip flags
		if uw & 0x7ff != 0x1ff {p.mode = .Serial}
	case 0x10, 0x12, 0x13, 0x1c, 0x18, 0x1a, 0x1b: // FCEQ/FCAND/FCOR/FCGET, FMEQ/FMAND/FMOR
		p.mode = .Lower_First
		p.mac_rd = lw >> 25 >= 0x18 && lw >> 25 <= 0x1b
	case 0x40:
		if lw & 63 < 0x3c {
			p.mode = .Serial
			break
		}
		switch ((lw >> 4) & 0x7c) | (lw & 3) {
		case 0x38 ..= 0x3a: if !touches {p.mode = .Serial} // only status (dead) is shared
		case 0x3b, 0x3e, 0x3f, 0x68, 0x69, 0x6c, 0x7b: p.mode = .Serial
		case: if !touches {p.mode = .Serial}
		}
	}
	if p.mode == .Slow {p.mac_rd = true} // vu_pair merges against the old flags
	return p
}

// Backward dataflow: MAC after pair n is live when a successor reads it
// before setting it, or control can leave compiled code.
@(private = "file")
mac_liveness :: proc(pairs: []Pair) {
	n := len(pairs)
	live_in := make([]bool, n, context.temp_allocator)
	at :: proc(live_in: []bool, pc: int) -> bool {
		i := pc / 8
		return i >= len(live_in) ? true : live_in[i]
	}
	for changed := true; changed; {
		changed = false
		for i := n - 1; i >= 0; i -= 1 {
			p := &pairs[i]
			out := at(live_in, (i + 1) * 8)
			if i > 0 && !pairs[i - 1].ibit { // a delay slot also goes to the target
				prev := pairs[i - 1]
				switch prev.branch {
				case .None:
				case .Reg: out = true
				case .Uncond, .Cond: out ||= at(live_in, int(branch_target(prev.lw, u32(i - 1) * 8)))
				}
				if prev.ebit {out = true}
			}
			if p.ebit && i + 1 < n {pairs[i + 1].mac_live = true}
			out ||= p.mac_live
			inn := p.mac_rd || (!p.mac_wr && out)
			if out != p.mac_live || inn != live_in[i] {changed = true}
			p.mac_live, live_in[i] = out, inn
		}
	}
}

@(private = "file")
branch_target :: proc(lw, pc: u32) -> u32 {
	imm11 := i32(i16(u16(lw & 0x7ff) << 5) >> 5)
	return (pc + 8 + u32(imm11) * 8) & MASK
}

@(private = "file")
lanes :: proc(dest: u32) -> [4]bool {
	return {dest & 8 != 0, dest & 4 != 0, dest & 2 != 0, dest & 1 != 0}
}

// Emit the upper op. `mac` is whether its MAC result is live.
@(private = "file")
emit_upper :: proc(sb: ^strings.Builder, uw: u32, mac: bool) {
	dest := (uw >> 21) & 15
	ft, fs, fd := (uw >> 16) & 31, (uw >> 11) & 31, (uw >> 6) & 31
	fn := uw & 63
	bc := uw & 3
	Op :: enum {Add, Sub, Madd, Msub, Max, Mini, Mul}
	OPS := [Op]string {
		.Add  = "s + %s",
		.Sub  = "s - %s",
		.Madd = "v.acc.f + s * %s",
		.Msub = "v.acc.f - s * %s",
		.Max  = "vmax(s, %s)",
		.Mini = "vmin(s, %s)",
		.Mul  = "s * %s",
	}
	BC := [4]string{"sp(t.x)", "sp(t.y)", "sp(t.z)", "sp(t.w)"}
	// Write r to fd (or ACC), with MAC when live.
	arith :: proc(sb: ^strings.Builder, expr: string, dst: string, dest, fs, ft: u32, mac: bool) {
		if dst == "" && !mac {return}
		fmt.sbprintf(sb, "\t\t\t{{s := vf[%d].f; ", fs)
		if strings.contains(expr, "t") {fmt.sbprintf(sb, "t := vf[%d].f; ", ft)}
		fmt.sbprintf(sb, "x := clamp4(%s); ", expr)
		if mac {fmt.sbprintf(sb, "v.mac = mac4(x, 0x%x); ", dest)}
		store(sb, dst, dest)
		fmt.sbprintln(sb, "}")
	}
	vfd := fd == 0 ? "" : fmt.tprintf("vf[%d]", fd)
	if fn < 0x3c {
		op: Op
		b: string
		switch fn {
		case 0x00 ..= 0x1b:
			op = Op(fn >> 2)
			b = BC[bc]
		case 0x1c: op, b = .Mul, "sp(v.q)"
		case 0x1d: op, b = .Max, "sp(v.i)"
		case 0x1e: op, b = .Mul, "sp(v.i)"
		case 0x1f: op, b = .Mini, "sp(v.i)"
		case 0x20: op, b = .Add, "sp(v.q)"
		case 0x21: op, b = .Madd, "sp(v.q)"
		case 0x22: op, b = .Add, "sp(v.i)"
		case 0x23: op, b = .Madd, "sp(v.i)"
		case 0x24: op, b = .Sub, "sp(v.q)"
		case 0x25: op, b = .Msub, "sp(v.q)"
		case 0x26: op, b = .Sub, "sp(v.i)"
		case 0x27: op, b = .Msub, "sp(v.i)"
		case 0x28: op, b = .Add, "t"
		case 0x29: op, b = .Madd, "t"
		case 0x2a: op, b = .Mul, "t"
		case 0x2b: op, b = .Max, "t"
		case 0x2c: op, b = .Sub, "t"
		case 0x2d: op, b = .Msub, "t"
		case 0x2e: // OPMSUB
			arith(sb, "v.acc.f - [4]f32{s.y * t.z, s.z * t.x, s.x * t.y, 0}", vfd, 0xe, fs, ft, mac)
			return
		case 0x2f: op, b = .Mini, "t"
		case:
			fmt.sbprintfln(sb, "\t\t\tee.vu1_upper(0x%08x)", uw)
			return
		}
		arith(sb, fmt.tprintf(OPS[op], b), vfd, dest, fs, ft, mac)
		return
	}
	sp := ((uw >> 4) & 0x7c) | (uw & 3)
	acc :: "v.acc"
	op: Op
	b: string
	switch sp {
	case 0x00 ..= 0x0f:
		op = Op(sp >> 2)
		b = BC[bc]
	case 0x10 ..= 0x13: // ITOF
		if ft == 0 {return}
		SCALE := [4]string{"1", "1.0 / 16", "1.0 / 4096", "1.0 / 32768"}
		fmt.sbprintf(sb, "\t\t\t{{s := vf[%d].i; x := clamp4([4]f32{{f32(s.x), f32(s.y), f32(s.z), f32(s.w)}} * sp(%s)); ",
			fs, SCALE[bc])
		store(sb, fmt.tprintf("vf[%d]", ft), dest)
		fmt.sbprintln(sb, "}")
		return
	case 0x14 ..= 0x17: // FTOI
		if ft == 0 || dest == 0 {return}
		SCALE := [4]string{"1", "16", "4096", "32768"}
		fmt.sbprintf(sb, "\t\t\t{{s := vf[%d].f; ", fs)
		for on, k in lanes(dest) {
			if on {fmt.sbprintf(sb, "vf[%d].i[%d] = cvt_w(s[%d] * %s); ", ft, k, k, SCALE[bc])}
		}
		fmt.sbprintln(sb, "}")
		return
	case 0x18 ..= 0x1b: op, b = .Mul, BC[bc]
	case 0x1c: op, b = .Mul, "sp(v.q)"
	case 0x1d: // ABS
		if ft == 0 {return}
		fmt.sbprintf(sb, "\t\t\t{{s := vf[%d].f; x := clamp4([4]f32{{abs(s.x), abs(s.y), abs(s.z), abs(s.w)}}); ", fs)
		store(sb, fmt.tprintf("vf[%d]", ft), dest)
		fmt.sbprintln(sb, "}")
		return
	case 0x1e: op, b = .Mul, "sp(v.i)"
	case 0x1f: // CLIP
		fmt.sbprintfln(sb, "\t\t\tclip(v, vf[%d].f, vf[%d].f)", fs, ft)
		return
	case 0x20: op, b = .Add, "sp(v.q)"
	case 0x21: op, b = .Madd, "sp(v.q)"
	case 0x22: op, b = .Add, "sp(v.i)"
	case 0x23: op, b = .Madd, "sp(v.i)"
	case 0x24: op, b = .Sub, "sp(v.q)"
	case 0x25: op, b = .Msub, "sp(v.q)"
	case 0x26: op, b = .Sub, "sp(v.i)"
	case 0x27: op, b = .Msub, "sp(v.i)"
	case 0x28: op, b = .Add, "t"
	case 0x29: op, b = .Madd, "t"
	case 0x2a: op, b = .Mul, "t"
	case 0x2c: op, b = .Sub, "t"
	case 0x2d: op, b = .Msub, "t"
	case 0x2e: // OPMULA
		arith(sb, "[4]f32{s.y * t.z, s.z * t.x, s.x * t.y, 0}", acc, 0xe, fs, ft, mac)
		return
	case 0x2f: return // NOP
	case:
		fmt.sbprintfln(sb, "\t\t\tee.vu1_upper(0x%08x)", uw)
		return
	}
	arith(sb, fmt.tprintf(OPS[op], b), acc, dest, fs, ft, mac)
}

// Store the dest lanes of x into dst ("" discards).
@(private = "file")
store :: proc(sb: ^strings.Builder, dst: string, dest: u32) {
	if dst == "" {return}
	if dest == 15 {
		fmt.sbprintf(sb, "%s.f = x", dst)
		return
	}
	for on, k in lanes(dest) {
		if on {fmt.sbprintf(sb, "%s.f[%d] = x[%d]; ", dst, k, k)}
	}
}

// Emit a non-branch lower op.
@(private = "file")
emit_lower :: proc(sb: ^strings.Builder, lw, pc: u32) {
	dest := (lw >> 21) & 15
	ft, fs, fd := (lw >> 16) & 31, (lw >> 11) & 31, (lw >> 6) & 31
	it, is := ft & 15, fs & 15
	imm11 := u16(i16(u16(lw & 0x7ff) << 5) >> 5)
	imm15 := u16(((lw >> 10) & 0x7800) | (lw & 0x7ff))
	imm24 := lw & 0xffffff
	L := lanes(dest)
	copy_lanes :: proc(sb: ^strings.Builder, L: [4]bool, dst, src: string) {
		for on, k in L {
			if on {fmt.sbprintf(sb, "%s[%d] = %s[%d]; ", dst, k, src, k)}
		}
	}
	slow :: proc(sb: ^strings.Builder, lw, pc: u32) {
		fmt.sbprintfln(sb, "\t\t\tee.vu1_lower(0x%08x, 0x%04x)", lw, pc)
	}
	switch lw >> 25 {
	case 0x00: // LQ
		if ft == 0 || dest == 0 {return}
		fmt.sbprintf(sb, "\t\t\t{{q := mq(v, vi[%d] + 0x%x); ", is, imm11)
		copy_lanes(sb, L, fmt.tprintf("vf[%d].u", ft), "q")
		fmt.sbprintln(sb, "}")
	case 0x01: // SQ
		if dest == 0 {return}
		fmt.sbprintf(sb, "\t\t\t{{q := mq(v, vi[%d] + 0x%x); ", it, imm11)
		copy_lanes(sb, L, "q", fmt.tprintf("vf[%d].u", fs))
		fmt.sbprintln(sb, "}")
	case 0x04: // ILW: the last dest lane wins
		if it == 0 || dest == 0 {return}
		k := 3
		for !L[k] {k -= 1}
		fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16(mq(v, vi[%d] + 0x%x)[%d])", it, is, imm11, k)
	case 0x05: // ISW
		if dest == 0 {return}
		fmt.sbprintf(sb, "\t\t\t{{q := mq(v, vi[%d] + 0x%x); x := u32(vi[%d]); ", is, imm11, it)
		for on, k in L {
			if on {fmt.sbprintf(sb, "q[%d] = x; ", k)}
		}
		fmt.sbprintln(sb, "}")
	case 0x08: if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] + 0x%x", it, is, imm15)} // IADDIU
	case 0x09: if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] - 0x%x", it, is, imm15)} // ISUBIU
	case 0x10: fmt.sbprintfln(sb, "\t\t\tvi[1] = u16(v.clip & 0xffffff == 0x%x)", imm24) // FCEQ
	case 0x11: fmt.sbprintfln(sb, "\t\t\tv.clip = 0x%x", imm24) // FCSET
	case 0x12: fmt.sbprintfln(sb, "\t\t\tvi[1] = u16(v.clip & 0x%x != 0)", imm24) // FCAND
	case 0x13: fmt.sbprintfln(sb, "\t\t\tvi[1] = u16((v.clip | 0x%x) & 0xffffff == 0xffffff)", imm24) // FCOR
	case 0x18: if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16(v.mac & 0xffff == u32(vi[%d]))", it, is)} // FMEQ
	case 0x1a: if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16(v.mac) & vi[%d]", it, is)} // FMAND
	case 0x1b: if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16((v.mac | u32(vi[%d])) & 0xffff == 0xffff)", it, is)} // FMOR
	case 0x1c: if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16(v.clip & 0xfff)", it)} // FCGET
	case 0x40:
		if lw & 63 < 0x3c {
			switch lw & 63 {
			case 0x30: if fd != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] + vi[%d]", fd & 15, fs & 15, ft & 15)}
			case 0x31: if fd != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] - vi[%d]", fd & 15, fs & 15, ft & 15)}
			case 0x32: // IADDI: imm5 in the fd field
				imm := u16(i16(i8(u8(fd) << 3) >> 3))
				if ft != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] + 0x%x", ft & 15, fs & 15, imm)}
			case 0x34: if fd != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] & vi[%d]", fd & 15, fs & 15, ft & 15)}
			case 0x35: if fd != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] | vi[%d]", fd & 15, fs & 15, ft & 15)}
			case: slow(sb, lw, pc)
			}
			return
		}
		switch ((lw >> 4) & 0x7c) | (lw & 3) {
		case 0x30: // MOVE
			if ft == 0 || dest == 0 {return}
			fmt.sbprintf(sb, "\t\t\t{{r := vf[%d].u; ", fs)
			copy_lanes(sb, L, fmt.tprintf("vf[%d].u", ft), "r")
			fmt.sbprintln(sb, "}")
		case 0x31: // MR32
			if ft == 0 || dest == 0 {return}
			fmt.sbprintf(sb, "\t\t\t{{r := vf[%d].u; ", fs)
			for on, k in L {
				if on {fmt.sbprintf(sb, "vf[%d].u[%d] = r[%d]; ", ft, k, (k + 1) & 3)}
			}
			fmt.sbprintln(sb, "}")
		case 0x34, 0x36: // LQI, LQD
			fmt.sbprint(sb, "\t\t\t{")
			if lw & 3 == 2 {fmt.sbprintf(sb, "vi[%d] -= 1; ", is)}
			if ft != 0 && dest != 0 {
				fmt.sbprintf(sb, "q := mq(v, vi[%d]); ", is)
				copy_lanes(sb, L, fmt.tprintf("vf[%d].u", ft), "q")
			}
			if lw & 3 == 0 && is != 0 {fmt.sbprintf(sb, "vi[%d] += 1; ", is)}
			fmt.sbprintln(sb, "vi[0] = 0}")
		case 0x35, 0x37: // SQI, SQD
			fmt.sbprint(sb, "\t\t\t{")
			if lw & 3 == 3 {fmt.sbprintf(sb, "vi[%d] -= 1; ", it)}
			if dest != 0 {
				fmt.sbprintf(sb, "q := mq(v, vi[%d]); ", it)
				copy_lanes(sb, L, "q", fmt.tprintf("vf[%d].u", fs))
			}
			if lw & 3 == 1 && it != 0 {fmt.sbprintf(sb, "vi[%d] += 1; ", it)}
			fmt.sbprintln(sb, "vi[0] = 0}")
		case 0x38: // DIV
			fmt.sbprintfln(sb, "\t\t\tv.q = fdiv(vf[%d].f[%d], vf[%d].f[%d])", fs, (lw >> 21) & 3, ft, (lw >> 23) & 3)
		case 0x39: // SQRT
			fmt.sbprintfln(sb, "\t\t\tv.q = math.sqrt(abs(vf[%d].f[%d]))", ft, (lw >> 23) & 3)
		case 0x3a: // RSQRT
			fmt.sbprintfln(sb, "\t\t\tv.q = frsqrt(vf[%d].f[%d], vf[%d].f[%d])", fs, (lw >> 21) & 3, ft, (lw >> 23) & 3)
		case 0x3b, 0x7b: // WAITQ, WAITP
		case 0x3c: // MTIR
			if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16(vf[%d].u[%d])", it, fs, (lw >> 21) & 3)}
		case 0x3d: // MFIR
			if ft == 0 || dest == 0 {return}
			fmt.sbprintf(sb, "\t\t\t{{x := u32(i32(i16(vi[%d]))); ", is)
			for on, k in L {
				if on {fmt.sbprintf(sb, "vf[%d].u[%d] = x; ", ft, k)}
			}
			fmt.sbprintln(sb, "}")
		case 0x6c: fmt.sbprintfln(sb, "\t\t\tee.vu1_xgkick(vi[%d])", is) // XGKICK
		case: slow(sb, lw, pc)
		}
	case: slow(sb, lw, pc)
	}
}

// Emit a whole pair, without its branch.
@(private = "file")
emit_pair :: proc(sb: ^strings.Builder, p: Pair, pc: u32) {
	if p.ibit {
		fmt.sbprintfln(sb, "\t\t\tv.i = transmute(f32)u32(0x%08x)", p.lw)
		emit_upper(sb, p.uw, p.mac_live)
		return
	}
	switch p.mode {
	case .Serial:
		emit_upper(sb, p.uw, p.mac_live)
		if p.branch == .None {emit_lower(sb, p.lw, pc)}
	case .Lower_First:
		emit_lower(sb, p.lw, pc)
		emit_upper(sb, p.uw, p.mac_live)
	case .Slow:
		fmt.sbprintfln(sb, "\t\t\tee.vu1_pair(0x%08x, 0x%08x, 0x%04x)", p.uw, p.lw, pc)
	}
}

// Emit a branch's condition into `tk` and its target into `tg`, plus the
// link register.
@(private = "file")
emit_branch :: proc(sb: ^strings.Builder, lw, pc: u32) {
	it, is := (lw >> 16) & 15, (lw >> 11) & 15
	switch lw >> 25 {
	case 0x20, 0x21, 0x24, 0x25: fmt.sbprintln(sb, "\t\t\ttk := true")
	case 0x28: fmt.sbprintfln(sb, "\t\t\ttk := vi[%d] == vi[%d]", it, is)
	case 0x29: fmt.sbprintfln(sb, "\t\t\ttk := vi[%d] != vi[%d]", it, is)
	case 0x2c: fmt.sbprintfln(sb, "\t\t\ttk := i16(vi[%d]) < 0", is)
	case 0x2d: fmt.sbprintfln(sb, "\t\t\ttk := i16(vi[%d]) > 0", is)
	case 0x2e: fmt.sbprintfln(sb, "\t\t\ttk := i16(vi[%d]) <= 0", is)
	case 0x2f: fmt.sbprintfln(sb, "\t\t\ttk := i16(vi[%d]) >= 0", is)
	}
	switch lw >> 25 {
	case 0x24, 0x25: fmt.sbprintfln(sb, "\t\t\ttg := u32(vi[%d]) * 8 & 0x%x", is, MASK)
	case: fmt.sbprintfln(sb, "\t\t\ttg: u32 = 0x%04x", branch_target(lw, pc))
	}
	if (lw >> 25 == 0x21 || lw >> 25 == 0x25) && it != 0 {
		fmt.sbprintfln(sb, "\t\t\tvi[%d] = 0x%x", it, u16((pc + 16) / 8))
	}
}

@(private = "file")
emit_program :: proc(sb: ^strings.Builder, n: int, words: []u32) {
	pairs := make([]Pair, len(words) / 2, context.temp_allocator)
	for &p, i in pairs {p = classify(words[2 * i], words[2 * i + 1])}
	mac_liveness(pairs)
	end := u32(len(pairs) * 8)

	fmt.sbprintfln(sb, "run_%d :: proc(pc: u32, budget: ^int) -> (u32, ee.Vu1_Exit) {{", n)
	fmt.sbprintln(sb, "\tv := &ee.vu1")
	fmt.sbprintln(sb, "\tvf, vi := &v.vf, &v.vi")
	fmt.sbprintln(sb, "\t_, _ = vf, vi")
	fmt.sbprintln(sb, "\tpc := pc")
	fmt.sbprintln(sb, "\tfor {")
	fmt.sbprintln(sb, "\t\tswitch pc {")
	plain :: proc(p: Pair) -> bool {return !p.ebit && (p.ibit || p.branch == .None)}
	for p, i in pairs {
		pc := u32(i) * 8
		next := i + 1 < len(pairs) ? pairs[i + 1] : Pair{}
		fmt.sbprintfln(sb, "\t\tcase 0x%04x:", pc)
		branch := !p.ibit && p.branch != .None
		switch {
		case branch && (p.ebit || i + 1 >= len(pairs) || !plain(next)),
		     !branch && p.ebit && (i + 1 >= len(pairs) || !plain(next)):
			fmt.sbprintfln(sb, "\t\t\treturn 0x%04x, .Leave", pc)
		case branch:
			emit_pair(sb, p, pc)
			emit_branch(sb, p.lw, pc)
			emit_pair(sb, next, pc + 8)
			fmt.sbprintln(sb, "\t\t\tif tk {")
			fmt.sbprintln(sb, "\t\t\t\tbudget^ -= 1")
			fmt.sbprintln(sb, "\t\t\t\tif budget^ <= 0 {return tg, .Leave}")
			fmt.sbprintln(sb, "\t\t\t\tpc = tg")
			fmt.sbprintln(sb, "\t\t\t} else {")
			fmt.sbprintfln(sb, "\t\t\t\tpc = 0x%04x", (pc + 16) & MASK)
			fmt.sbprintln(sb, "\t\t\t}")
			fmt.sbprintln(sb, "\t\t\tcontinue")
		case p.ebit:
			emit_pair(sb, p, pc)
			emit_pair(sb, next, pc + 8)
			fmt.sbprintfln(sb, "\t\t\treturn 0x%04x, .End", (pc + 16) & MASK)
		case:
			emit_pair(sb, p, pc)
			if pc + 8 < end {
				fmt.sbprintln(sb, "\t\t\tfallthrough")
			} else {
				fmt.sbprintfln(sb, "\t\t\treturn 0x%04x, .Leave", (pc + 8) & MASK)
			}
		}
	}
	fmt.sbprintln(sb, "\t\tcase:")
	fmt.sbprintln(sb, "\t\t\treturn pc, .Leave")
	fmt.sbprintln(sb, "\t\t}")
	fmt.sbprintln(sb, "\t}")
	fmt.sbprintln(sb, "}\n")
}

// Write out_dir/vu1/code.odin (package vu1).
gen_vu :: proc(img: ^Image, out_dir: string) -> bool {
	progs, ok := find_programs(img)
	if !ok {return false}
	sb := strings.builder_make()
	fmt.sbprintln(&sb, "// Generated by tools/recomp from SLUS_212.84. Do not edit.")
	fmt.sbprintln(&sb, "package vu1\n")
	fmt.sbprintln(&sb, "import \"core:math\"")
	fmt.sbprintln(&sb, "import \"core:simd\"")
	fmt.sbprintln(&sb, "import ee \"../../ee\"\n")
	fmt.sbprintln(&sb, VU_HELPERS)
	fmt.sbprintln(&sb, "register :: proc() {")
	for _, n in progs {
		fmt.sbprintfln(&sb, "\tee.vu1_register(code_%d[:], run_%d)", n, n)
	}
	fmt.sbprintln(&sb, "}\n")
	pairs := 0
	for p, n in progs {
		fmt.sbprintfln(&sb, "@(rodata)\ncode_%d := [%d]u32{{", n, len(p.words))
		for w, i in p.words {
			fmt.sbprintf(&sb, i % 8 == 0 ? "\t0x%08x," : " 0x%08x,", w)
			if i % 8 == 7 || i == len(p.words) - 1 {fmt.sbprintln(&sb)}
		}
		fmt.sbprintln(&sb, "}\n")
		emit_program(&sb, n, p.words[:])
		pairs += len(p.words) / 2
		free_all(context.temp_allocator)
	}
	dir, _ := filepath.join({out_dir, "vu1"})
	os.make_directory(dir)
	path, _ := filepath.join({dir, "code.odin"})
	if err := os.write_entire_file(path, sb.buf[:]); err != nil {
		fmt.eprintln("cannot write", path, err)
		return false
	}
	fmt.printfln("%d VU1 programs, %d pairs -> %s", len(progs), pairs, path)
	return true
}

// Inline versions of the interpreter's helpers (ee/vu.odin, ee/alu.odin): a
// call into ee is never inlined across modules.
VU_HELPERS :: `sp :: #force_inline proc "contextless" (x: f32) -> [4]f32 {return {x, x, x, x}}

// fclamp on all four lanes: infinities and NaNs become the largest
// finite value, denormals zero, keeping the sign.
clamp4 :: #force_inline proc "contextless" (r: [4]f32) -> [4]f32 {
	u := transmute(#simd[4]u32)r
	e := u & 0x7f800000
	sign := u & 0x80000000
	u = simd.select(simd.lanes_eq(e, 0), sign, u)
	u = simd.select(simd.lanes_eq(e, 0x7f800000), sign | 0x7f7fffff, u)
	return transmute([4]f32)u
}

fclamp :: #force_inline proc "contextless" (x: f32) -> f32 {
	u := transmute(u32)x
	switch u & 0x7f800000 {
	case 0x7f800000: return transmute(f32)((u & 0x80000000) | 0x7f7fffff)
	case 0:          return transmute(f32)(u & 0x80000000)
	}
	return x
}

fdiv :: #force_inline proc "contextless" (a, b: f32) -> f32 {
	if transmute(u32)b & 0x7f800000 == 0 {
		sign := (transmute(u32)a ~ transmute(u32)b) & 0x80000000
		return transmute(f32)(sign | 0x7f7fffff)
	}
	return fclamp(a / b)
}

frsqrt :: #force_inline proc "contextless" (a, b: f32) -> f32 {
	s := math.sqrt(abs(b))
	if transmute(u32)s & 0x7f800000 == 0 {
		return transmute(f32)((transmute(u32)a & 0x80000000) | 0x7f7fffff)
	}
	return fclamp(a / s)
}

cvt_w :: #force_inline proc "contextless" (x: f32) -> i32 {
	u := transmute(u32)x
	if u & 0x7f800000 >= 0x4f000000 {
		return u & 0x80000000 != 0 ? min(i32) : max(i32)
	}
	return i32(x)
}

vmax :: #force_inline proc "contextless" (a, b: [4]f32) -> [4]f32 {return {max(a.x, b.x), max(a.y, b.y), max(a.z, b.z), max(a.w, b.w)}}
vmin :: #force_inline proc "contextless" (a, b: [4]f32) -> [4]f32 {return {min(a.x, b.x), min(a.y, b.y), min(a.z, b.z), min(a.w, b.w)}}

// Quadword n of VU1 data memory (16 KiB), wrapping.
mq :: #force_inline proc "contextless" (v: ^ee.Vu, n: u16) -> ^[4]u32 {
	return (^[4]u32)(&v.mem[(u32(n) & 1023) * 16])
}

// MAC Z/S bits of the dest lanes of x.
mac4 :: #force_inline proc "contextless" (x: [4]f32, dest: u32) -> u32 {
	mac: u32 = 0
	for k in 0 ..< 4 {
		u := transmute(u32)x[k]
		bit := u32(8) >> u32(k)
		mac |= u32(u << 1 == 0) * bit | (u >> 31) * (bit << 4)
	}
	return mac & (dest | dest << 4)
}

clip :: #force_inline proc "contextless" (v: ^ee.Vu, s, t: [4]f32) {
	lim := abs(t.w)
	f: u32 = 0
	for k in 0 ..< 3 {
		if s[k] > lim {f |= 1 << (2 * u32(k))}
		if s[k] < -lim {f |= 2 << (2 * u32(k))}
	}
	v.clip = ((v.clip << 6) | f) & 0xffffff
}
`
