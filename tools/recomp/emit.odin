// Odin code generation.
//
// Each function becomes `f_XXXXXXXX :: proc()` working on `ee.cpu` (`c`).
// Control flow inside it is a `for { switch pc { ... } }` state machine
// whose cases are basic-block labels; straight-line code falls through.
// `jal` to a function in the same package is a direct host call, otherwise
// `ee.call(addr)` dispatches through the runtime's table. `jr $ra` is a host
// return. Hot instructions are inlined; the rest call the runtime
// interpreter (`ee.exec`), which owns their semantics.
package recomp

import "core:fmt"
import "core:slice"
import "core:strings"
import "../../port/src/r5900"

// EE cycles charged per instruction (the EE runs at 294.912 MHz).
CYCLES_PER_INSN :: 1

Emitter :: struct {
	sb:       strings.Builder,
	prog:     ^Program,
	pkg_of:   ^map[u32]int, // function entry -> package index
	pkg:      int,
}

hexu :: proc(v: u32) -> string {
	return fmt.tprintf("0x%08x", v)
}

R64 :: proc(n: u8) -> string {
	return n == 0 ? "u64(0)" : fmt.tprintf("c.r[%d].d[0]", n)
}

R32 :: proc(n: u8) -> string {
	return n == 0 ? "u32(0)" : fmt.tprintf("u32(c.r[%d].d[0])", n)
}

S64 :: proc(n: u8) -> string {
	return n == 0 ? "i64(0)" : fmt.tprintf("i64(c.r[%d].d[0])", n)
}

set64 :: proc(out: ^[dynamic]string, n: u8, expr: string) {
	if n != 0 {append(out, fmt.tprintf("c.r[%d].d[0] = %s", n, expr))}
}

set32 :: proc(out: ^[dynamic]string, n: u8, expr: string) {
	if n != 0 {append(out, fmt.tprintf("c.r[%d].d[0] = sx32(%s)", n, expr))}
}

addr_expr :: proc(i: r5900.Insn) -> string {
	off := r5900.sx16(i.imm)
	if i.rs == 0 {return hexu(u32(off))}
	if off == 0 {return R32(i.rs)}
	return fmt.tprintf("%s %s 0x%x", R32(i.rs), off > 0 ? "+" : "-", abs(off))
}

F :: proc(n: u8) -> string {return fmt.tprintf("c.f[%d].f", n)}

// Odin statements for a non-control-transfer instruction.
emit_op :: proc(i: r5900.Insn, out: ^[dynamic]string) {
	rs, rt, rd, sa := i.rs, i.rt, i.rd, i.sa
	imm := i.imm
	simm := r5900.sx16(imm)
	fs, ft, fd := rd, rt, sa // COP1 field names
	if emit_mmi(i, out) {return}
	switch i.op {
	case .SLL:
		if i.w == 0 {return} // nop
		set32(out, rd, fmt.tprintf("%s << %d", R32(rt), sa))
	case .SRL:  set32(out, rd, fmt.tprintf("%s >> %d", R32(rt), sa))
	case .SRA:  set32(out, rd, fmt.tprintf("u32(i32(%s) >> %d)", R32(rt), sa))
	case .SLLV: set32(out, rd, fmt.tprintf("%s << (%s & 31)", R32(rt), R32(rs)))
	case .SRLV: set32(out, rd, fmt.tprintf("%s >> (%s & 31)", R32(rt), R32(rs)))
	case .SRAV: set32(out, rd, fmt.tprintf("u32(i32(%s) >> (%s & 31))", R32(rt), R32(rs)))
	case .DSLLV: set64(out, rd, fmt.tprintf("%s << (%s & 63)", R64(rt), R32(rs)))
	case .DSRLV: set64(out, rd, fmt.tprintf("%s >> (%s & 63)", R64(rt), R32(rs)))
	case .DSRAV: set64(out, rd, fmt.tprintf("u64(%s >> (%s & 63))", S64(rt), R32(rs)))
	case .DSLL:   set64(out, rd, fmt.tprintf("%s << %d", R64(rt), sa))
	case .DSRL:   set64(out, rd, fmt.tprintf("%s >> %d", R64(rt), sa))
	case .DSRA:   set64(out, rd, fmt.tprintf("u64(%s >> %d)", S64(rt), sa))
	case .DSLL32: set64(out, rd, fmt.tprintf("%s << %d", R64(rt), sa + 32))
	case .DSRL32: set64(out, rd, fmt.tprintf("%s >> %d", R64(rt), sa + 32))
	case .DSRA32: set64(out, rd, fmt.tprintf("u64(%s >> %d)", S64(rt), sa + 32))
	case .MOVZ:
		if rd != 0 {append(out, fmt.tprintf("if %s == 0 {{c.r[%d].d[0] = %s}}", R64(rt), rd, R64(rs)))}
	case .MOVN:
		if rd != 0 {append(out, fmt.tprintf("if %s != 0 {{c.r[%d].d[0] = %s}}", R64(rt), rd, R64(rs)))}
	case .MFHI: set64(out, rd, "c.hi.d[0]")
	case .MFLO: set64(out, rd, "c.lo.d[0]")
	case .MTHI: append(out, fmt.tprintf("c.hi.d[0] = %s", R64(rs)))
	case .MTLO: append(out, fmt.tprintf("c.lo.d[0] = %s", R64(rs)))
	case .MFHI1: set64(out, rd, "c.hi.d[1]")
	case .MFLO1: set64(out, rd, "c.lo.d[1]")
	case .MULT:  append(out, fmt.tprintf("ee.mult(%d, %s, %s, 0)", rd, R32(rs), R32(rt)))
	case .MULTU: append(out, fmt.tprintf("ee.multu(%d, %s, %s, 0)", rd, R32(rs), R32(rt)))
	case .MULT1:  append(out, fmt.tprintf("ee.mult(%d, %s, %s, 1)", rd, R32(rs), R32(rt)))
	case .MULTU1: append(out, fmt.tprintf("ee.multu(%d, %s, %s, 1)", rd, R32(rs), R32(rt)))
	case .DIV:   append(out, fmt.tprintf("ee.div(%s, %s, 0)", R32(rs), R32(rt)))
	case .DIVU:  append(out, fmt.tprintf("ee.divu(%s, %s, 0)", R32(rs), R32(rt)))
	case .DIV1:  append(out, fmt.tprintf("ee.div(%s, %s, 1)", R32(rs), R32(rt)))
	case .DIVU1: append(out, fmt.tprintf("ee.divu(%s, %s, 1)", R32(rs), R32(rt)))
	case .ADD, .ADDU:
		if rt == 0 {set32(out, rd, R32(rs))} else if rs == 0 {set32(out, rd, R32(rt))} else {
			set32(out, rd, fmt.tprintf("%s + %s", R32(rs), R32(rt)))
		}
	case .SUB, .SUBU: set32(out, rd, fmt.tprintf("%s - %s", R32(rs), R32(rt)))
	case .DADD, .DADDU:
		if rt == 0 {set64(out, rd, R64(rs))} else if rs == 0 {set64(out, rd, R64(rt))} else {
			set64(out, rd, fmt.tprintf("%s + %s", R64(rs), R64(rt)))
		}
	case .DSUB, .DSUBU: set64(out, rd, fmt.tprintf("%s - %s", R64(rs), R64(rt)))
	case .AND: set64(out, rd, fmt.tprintf("%s & %s", R64(rs), R64(rt)))
	case .OR:
		if rt == 0 {set64(out, rd, R64(rs))} else if rs == 0 {set64(out, rd, R64(rt))} else {
			set64(out, rd, fmt.tprintf("%s | %s", R64(rs), R64(rt)))
		}
	case .XOR: set64(out, rd, fmt.tprintf("%s ~ %s", R64(rs), R64(rt)))
	case .NOR: set64(out, rd, fmt.tprintf("~(%s | %s)", R64(rs), R64(rt)))
	case .SLT:  set64(out, rd, fmt.tprintf("%s < %s ? 1 : 0", S64(rs), S64(rt)))
	case .SLTU: set64(out, rd, fmt.tprintf("%s < %s ? 1 : 0", R64(rs), R64(rt)))
	case .ADDI, .ADDIU:
		if rs == 0 {set64(out, rt, fmt.tprintf("0x%x", u64(i64(simm))))} else {
			set32(out, rt, fmt.tprintf("%s + %s", R32(rs), hexu(u32(simm))))
		}
	case .DADDI, .DADDIU:
		set64(out, rt, fmt.tprintf("%s + 0x%x", R64(rs), u64(i64(simm))))
	case .SLTI:  set64(out, rt, fmt.tprintf("%s < %d ? 1 : 0", S64(rs), simm))
	case .SLTIU: set64(out, rt, fmt.tprintf("%s < 0x%x ? 1 : 0", R64(rs), u64(i64(simm))))
	case .ANDI: set64(out, rt, fmt.tprintf("%s & 0x%x", R64(rs), imm))
	case .ORI:  set64(out, rt, rs == 0 ? fmt.tprintf("u64(0x%x)", imm) : fmt.tprintf("%s | 0x%x", R64(rs), imm))
	case .XORI: set64(out, rt, fmt.tprintf("%s ~ 0x%x", R64(rs), imm))
	case .LUI:  set64(out, rt, fmt.tprintf("0x%x", u64(i64(i32(u32(imm) << 16)))))
	case .LB:  set64(out, rt, fmt.tprintf("u64(i64(i8(rd8(%s))))", addr_expr(i)))
	case .LBU: set64(out, rt, fmt.tprintf("u64(rd8(%s))", addr_expr(i)))
	case .LH:  set64(out, rt, fmt.tprintf("u64(i64(i16(rd16(%s))))", addr_expr(i)))
	case .LHU: set64(out, rt, fmt.tprintf("u64(rd16(%s))", addr_expr(i)))
	case .LW:  set64(out, rt, fmt.tprintf("sx32(rd32(%s))", addr_expr(i)))
	case .LWU: set64(out, rt, fmt.tprintf("u64(rd32(%s))", addr_expr(i)))
	case .LD:  set64(out, rt, fmt.tprintf("rd64(%s)", addr_expr(i)))
	case .LQ:
		if rt != 0 {append(out, fmt.tprintf("c.r[%d].q = rd128(%s)", rt, addr_expr(i)))}
	case .SB: append(out, fmt.tprintf("wr8(%s, u8(%s))", addr_expr(i), R64(rt)))
	case .SH: append(out, fmt.tprintf("wr16(%s, u16(%s))", addr_expr(i), R64(rt)))
	case .SW: append(out, fmt.tprintf("wr32(%s, %s)", addr_expr(i), R32(rt)))
	case .SD: append(out, fmt.tprintf("wr64(%s, %s)", addr_expr(i), R64(rt)))
	case .SQ: append(out, fmt.tprintf("wr128(%s, %s)", addr_expr(i), rt == 0 ? "u128(0)" : fmt.tprintf("c.r[%d].q", rt)))
	case .LWC1: append(out, fmt.tprintf("c.f[%d].u = rd32(%s)", rt, addr_expr(i)))
	case .SWC1: append(out, fmt.tprintf("wr32(%s, c.f[%d].u)", addr_expr(i), rt))
	case .LQC2: append(out, fmt.tprintf("ee.vu0_set_vf(%d, rd128(%s))", rt, addr_expr(i)))
	case .SQC2: append(out, fmt.tprintf("wr128(%s, ee.vu0.vf[%d].q)", addr_expr(i), rt))
	case .LWL, .LWR, .LDL, .LDR:
		if rt != 0 {append(out, fmt.tprintf("c.r[%d].d[0] = ee.%v(%s, %s)", rt, i.op, addr_expr(i), R64(rt)))}
	case .SWL, .SWR, .SDL, .SDR:
		append(out, fmt.tprintf("ee.%v(%s, %s)", i.op, addr_expr(i), R64(rt)))
	case .SYNC, .CACHE, .PREF:
	case .MFC1: set64(out, rt, fmt.tprintf("sx32(c.f[%d].u)", fs))
	case .MTC1: append(out, fmt.tprintf("c.f[%d].u = %s", fs, R32(rt)))
	case .MOV_S: append(out, fmt.tprintf("c.f[%d] = c.f[%d]", fd, fs))
	case .NEG_S: append(out, fmt.tprintf("c.f[%d].u = c.f[%d].u ~ 0x80000000", fd, fs))
	case .ABS_S: append(out, fmt.tprintf("c.f[%d].u = c.f[%d].u & 0x7fffffff", fd, fs))
	case .ADD_S: append(out, fmt.tprintf("%s = fclamp(%s + %s)", F(fd), F(fs), F(ft)))
	case .SUB_S: append(out, fmt.tprintf("%s = fclamp(%s - %s)", F(fd), F(fs), F(ft)))
	case .MUL_S: append(out, fmt.tprintf("%s = fclamp(%s * %s)", F(fd), F(fs), F(ft)))
	case .DIV_S: append(out, fmt.tprintf("%s = ee.fdiv(%s, %s)", F(fd), F(fs), F(ft)))
	case .MADD_S: append(out, fmt.tprintf("%s = fclamp(c.acc.f + %s * %s)", F(fd), F(fs), F(ft)))
	case .MSUB_S: append(out, fmt.tprintf("%s = fclamp(c.acc.f - %s * %s)", F(fd), F(fs), F(ft)))
	case .MULA_S: append(out, fmt.tprintf("c.acc.f = fclamp(%s * %s)", F(fs), F(ft)))
	case .ADDA_S: append(out, fmt.tprintf("c.acc.f = fclamp(%s + %s)", F(fs), F(ft)))
	case .SUBA_S: append(out, fmt.tprintf("c.acc.f = fclamp(%s - %s)", F(fs), F(ft)))
	case .MADDA_S: append(out, fmt.tprintf("c.acc.f = fclamp(c.acc.f + %s * %s)", F(fs), F(ft)))
	case .MSUBA_S: append(out, fmt.tprintf("c.acc.f = fclamp(c.acc.f - %s * %s)", F(fs), F(ft)))
	case .MAX_S: append(out, fmt.tprintf("%s = max(%s, %s)", F(fd), F(fs), F(ft)))
	case .MIN_S: append(out, fmt.tprintf("%s = min(%s, %s)", F(fd), F(fs), F(ft)))
	case .C_F_S:  append(out, "c.fcr31 &= ~u32(0x800000)")
	case .C_EQ_S: append(out, fmt.tprintf("ee.fcond(%s == %s)", F(fs), F(ft)))
	case .C_LT_S: append(out, fmt.tprintf("ee.fcond(%s < %s)", F(fs), F(ft)))
	case .C_LE_S: append(out, fmt.tprintf("ee.fcond(%s <= %s)", F(fs), F(ft)))
	case .CVT_S_W: append(out, fmt.tprintf("%s = f32(c.f[%d].i)", F(fd), fs))
	case .CVT_W_S: append(out, fmt.tprintf("c.f[%d].i = ee.cvt_w(%s)", fd, F(fs)))
	case .INVALID:
		append(out, fmt.tprintf("ee.bad_insn(%s, %s)", hexu(i.pc), hexu(i.w)))
	case .SYSCALL:
		append(out, fmt.tprintf("ee.syscall(%s)", hexu(i.pc)))
	case .BREAK:
		append(out, fmt.tprintf("ee.brk(%s, %s)", hexu(i.pc), hexu(i.w)))
	case .J, .JAL, .JR, .JALR, .BEQ, .BNE, .BLEZ, .BGTZ, .BEQL, .BNEL, .BLEZL, .BGTZL,
	     .BLTZ, .BGEZ, .BLTZL, .BGEZL, .BLTZAL, .BGEZAL, .BLTZALL, .BGEZALL,
	     .BC0F, .BC0T, .BC0FL, .BC0TL, .BC1F, .BC1T, .BC1FL, .BC1TL, .BC2F, .BC2T, .BC2FL, .BC2TL:
		panic("control transfer in emit_op")
	case .MFSA, .MTSA, .TGE, .TGEU, .TLT, .TLTU, .TEQ, .TNE, .TRAPI, .MTSAB, .MTSAH,
	     .MADD, .MADDU, .PLZCW, .MTHI1, .MTLO1, .MADD1, .MADDU1, .PMFHL, .PMTHL,
	     .PSLLH, .PSRLH, .PSRAH, .PSLLW, .PSRLW, .PSRAW,
	     .PADDW, .PSUBW, .PCGTW, .PMAXW, .PADDH, .PSUBH, .PCGTH, .PMAXH, .PADDB, .PSUBB, .PCGTB,
	     .PADDSW, .PSUBSW, .PEXTLW, .PPACW, .PADDSH, .PSUBSH, .PEXTLH, .PPACH, .PADDSB, .PSUBSB,
	     .PEXTLB, .PPACB, .PEXT5, .PPAC5,
	     .PABSW, .PCEQW, .PMINW, .PADSBH, .PABSH, .PCEQH, .PMINH, .PCEQB, .PADDUW, .PSUBUW, .PEXTUW,
	     .PADDUH, .PSUBUH, .PEXTUH, .PADDUB, .PSUBUB, .PEXTUB, .QFSRV,
	     .PMADDW, .PSLLVW, .PSRLVW, .PMSUBW, .PMFHI, .PMFLO, .PINTH, .PMULTW, .PDIVW, .PCPYLD,
	     .PMADDH, .PHMADH, .PAND, .PXOR, .PMSUBH, .PHMSBH, .PEXEH, .PREVH, .PMULTH, .PDIVBW, .PEXEW, .PROT3W,
	     .PMADDUW, .PSRAVW, .PMTHI, .PMTLO, .PINTEH, .PMULTUW, .PDIVUW, .PCPYUD, .POR, .PNOR, .PEXCH, .PCPYH, .PEXCW,
	     .MFC0, .MTC0, .TLBR, .TLBWI, .TLBWR, .TLBP, .ERET, .EI, .DI,
	     .CFC1, .CTC1, .SQRT_S, .RSQRT_S,
	     .QMFC2, .CFC2, .QMTC2, .CTC2, .VU0:
		append(out, fmt.tprintf("ee.exec_insn({{pc = %s, w = %s, op = .%v, rs = %d, rt = %d, rd = %d, sa = %d, fn = %d, imm = %d}})",
			hexu(i.pc), hexu(i.w), i.op, i.rs, i.rt, i.rd, i.sa, i.fn, i.imm))
	}
}

// Lane-parallel MMI instructions as inline SIMD expressions; the rest go to
// the interpreter. Operands are read into s and t first because rd may alias
// either.
emit_mmi :: proc(i: r5900.Insn, out: ^[dynamic]string) -> bool {
	bin :: proc(view, op: string) -> string {return fmt.tprintf("s.%s %s t.%s", view, op, view)}
	call :: proc(f, view: string) -> string {return fmt.tprintf("intrinsics.%s(s.%s, t.%s)", f, view, view)}
	splat :: proc(n: int, v: u8) -> string {
		sb := strings.builder_make(context.temp_allocator)
		for k in 0 ..< n {fmt.sbprintf(&sb, "%s%d", k == 0 ? "" : ", ", v)}
		return strings.to_string(sb)
	}
	// Indices into the 2n-lane concatenation of t then s.
	shuffle :: proc(view: string, idx: []int) -> string {
		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "intrinsics.simd_shuffle(t.%s, s.%s", view, view)
		for k in idx {fmt.sbprintf(&sb, ", %d", k)}
		fmt.sbprint(&sb, ")")
		return strings.to_string(sb)
	}
	interleave :: proc(n, base: int) -> []int {
		idx := make([]int, n, context.temp_allocator)
		for k in 0 ..< n / 2 {idx[2 * k], idx[2 * k + 1] = base + k, n + base + k}
		return idx
	}
	evens :: proc(n: int) -> []int {
		idx := make([]int, n, context.temp_allocator)
		for k in 0 ..< n {idx[k] = 2 * k}
		return idx
	}
	view, expr: string
	sh := i.sa & 15
	#partial switch i.op {
	case .MTSAB:
		append(out, fmt.tprintf("c.sa = ((%s ~ %d) & 15) * 8", R32(i.rs), u32(i.imm) & 15))
		return true
	case .MFC0:
		if i.rd == 15 {return false} // PRId stays in the interpreter
		src := i.rd == 9 ? "u32(c.cycles)" : fmt.tprintf("c.cop0[%d]", i.rd)
		if i.rt != 0 {append(out, fmt.tprintf("c.r[%d].d[0] = sx32(%s)", i.rt, src))}
		return true
	case .DI:
		append(out, "c.cop0[12] &~= 0x10000")
		return true
	case .EI:
		append(out, "ee.ei()")
		return true
	case .PADDW: view, expr = "vw", bin("vw", "+")
	case .PSUBW: view, expr = "vw", bin("vw", "-")
	case .PADDH: view, expr = "vh", bin("vh", "+")
	case .PSUBH: view, expr = "vh", bin("vh", "-")
	case .PADDB: view, expr = "vb", bin("vb", "+")
	case .PSUBB: view, expr = "vb", bin("vb", "-")
	case .PMAXH: view, expr = "vh", call("simd_max", "vh")
	case .PMINH: view, expr = "vh", call("simd_min", "vh")
	case .PCGTH: view, expr = "vuh", fmt.tprintf("transmute(#simd[8]u16)%s", call("simd_lanes_gt", "vh"))
	case .PCEQH: view, expr = "vuh", fmt.tprintf("transmute(#simd[8]u16)%s", call("simd_lanes_eq", "vh"))
	case .PSLLH: view, expr = "vuh", fmt.tprintf("intrinsics.simd_shl(t.vuh, #simd[8]u16{{%s}})", splat(8, sh))
	case .PSRLH: view, expr = "vuh", fmt.tprintf("intrinsics.simd_shr(t.vuh, #simd[8]u16{{%s}})", splat(8, sh))
	case .PSRAH: view, expr = "vh", fmt.tprintf("intrinsics.simd_shr(t.vh, #simd[8]u16{{%s}})", splat(8, sh))
	case .PAND:  view, expr = "q", bin("q", "&")
	case .POR:   view, expr = "q", bin("q", "|")
	case .PXOR:  view, expr = "q", bin("q", "~")
	case .PNOR:  view, expr = "q", "~(s.q | t.q)"
	case .PCPYLD: view, expr = "d", "{t.d[0], s.d[0]}"
	case .PCPYUD: view, expr = "d", "{s.d[1], t.d[1]}"
	case .PEXTLB: view, expr = "vb", shuffle("vb", interleave(16, 0))
	case .PEXTUB: view, expr = "vb", shuffle("vb", interleave(16, 8))
	case .PEXTLH: view, expr = "vuh", shuffle("vuh", interleave(8, 0))
	case .PEXTUH: view, expr = "vuh", shuffle("vuh", interleave(8, 4))
	case .PPACB:  view, expr = "vb", shuffle("vb", evens(16))
	case .PPACH:  view, expr = "vuh", shuffle("vuh", evens(8))
	case .QFSRV:  view, expr = "q", "c.sa == 0 ? t.q : (t.q >> c.sa) | (s.q << (128 - c.sa))"
	case: return false
	}
	if i.rd != 0 {
		append(out, fmt.tprintf("{{s, t := c.r[%d], c.r[%d]; c.r[%d].%s = %s}}", i.rs, i.rt, i.rd, view, expr))
	}
	return true
}

branch_cond :: proc(i: r5900.Insn) -> string {
	rs, rt := i.rs, i.rt
	#partial switch i.op {
	case .BEQ, .BEQL:
		if rs == rt {return "true"}
		return fmt.tprintf("%s == %s", R64(rs), R64(rt))
	case .BNE, .BNEL:     return fmt.tprintf("%s != %s", R64(rs), R64(rt))
	case .BLEZ, .BLEZL:   return fmt.tprintf("%s <= 0", S64(rs))
	case .BGTZ, .BGTZL:   return fmt.tprintf("%s > 0", S64(rs))
	case .BLTZ, .BLTZL, .BLTZAL, .BLTZALL: return fmt.tprintf("%s < 0", S64(rs))
	case .BGEZ, .BGEZL, .BGEZAL, .BGEZALL:
		if rs == 0 {return "true"}
		return fmt.tprintf("%s >= 0", S64(rs))
	case .BC1F, .BC1FL: return "c.fcr31 & 0x800000 == 0"
	case .BC1T, .BC1TL: return "c.fcr31 & 0x800000 != 0"
	}
	// COP0/COP2 condition lines
	return fmt.tprintf("ee.bc_cond(%s)", hexu(i.w))
}

// Labels other than the entry whose address the program takes: function
// pointers into code the discovery merged into a preceding function.
interior_entries :: proc(e: ^Emitter, f: ^Func) -> []u32 {
	out := make([dynamic]u32, context.temp_allocator)
	for l in f.labels {
		if l != f.entry && l in e.prog.refs {append(&out, l)}
	}
	sort_u32(out[:])
	return out[:]
}

emit_func :: proc(e: ^Emitter, f: ^Func) {
	sb := &e.sb
	if len(interior_entries(e, f)) > 0 {
		// Enterable at several addresses: the body takes the start pc.
		fmt.sbprintfln(sb, "f_%08x :: proc() {{f_%08x_at(%s)}}\n", f.entry, f.entry, hexu(f.entry))
		fmt.sbprintfln(sb, "f_%08x_at :: proc(start: u32) {{", f.entry)
		fmt.sbprintln(sb, "\tc := &ee.cpu")
		fmt.sbprintfln(sb, "\tif ee.trace_on {{ee.trace_call(start)}}")
		fmt.sbprintln(sb, "\tif c.cycles >= ee.next_event {ee.run_events()}")
		fmt.sbprintln(sb, "\tpc := start")
	} else {
		fmt.sbprintfln(sb, "f_%08x :: proc() {{", f.entry)
		fmt.sbprintln(sb, "\tc := &ee.cpu")
		fmt.sbprintfln(sb, "\tif ee.trace_on {{ee.trace_call(%s)}}", hexu(f.entry))
		fmt.sbprintln(sb, "\tif c.cycles >= ee.next_event {ee.run_events()}")
		fmt.sbprintfln(sb, "\tpc: u32 = %s", hexu(f.entry))
	}
	fmt.sbprintln(sb, "\tfor {")
	fmt.sbprintln(sb, "\t\tswitch pc {")

	pcs := make([dynamic]u32, 0, len(f.insns), context.temp_allocator)
	for a in f.insns {append(&pcs, a)}
	sort_u32(pcs[:])

	body := make([dynamic]string, 0, 64, context.temp_allocator)
	open_case := false
	pending := 0

	flush :: proc(body: ^[dynamic]string, pending: ^int) {
		if pending^ > 0 {
			append(body, fmt.tprintf("c.cycles += %d", pending^ * CYCLES_PER_INSN))
			pending^ = 0
		}
	}
	close_case :: proc(sb: ^strings.Builder, body: ^[dynamic]string) {
		for s in body {
			fmt.sbprintfln(sb, "\t\t\t%s", s)
		}
		clear(body)
	}
	goto_stmts :: proc(e: ^Emitter, f: ^Func, src, t: u32, body: ^[dynamic]string) {
		if t >= f.start && t < f.end && t in f.labels {
			append(body, fmt.tprintf("pc = %s", hexu(t)))
			if t <= src {append(body, "if c.cycles >= ee.next_event {ee.run_events()}")}
			append(body, "continue")
			return
		}
		append(body, call_stmt(e, t))
		append(body, "return")
	}

	skip: map[u32]bool
	skip.allocator = context.temp_allocator
	for pc in pcs {
		i := f.insns[pc]
		if pc in skip {continue}
		if pc in f.labels {
			if open_case {
				flush(&body, &pending)
				append(&body, "fallthrough")
			}
			close_case(sb, &body)
			fmt.sbprintfln(sb, "\t\tcase %s:", hexu(pc))
			open_case = true
		} else if !open_case {
			continue // unreachable except as a delay slot
		}
		pending += 1

		if !r5900.has_delay(i) {
			emit_op(i, &body)
			if i.kind == .Bad || i.op == .ERET {
				flush(&body, &pending)
				append(&body, "return")
				open_case = false
			}
			continue
		}

		// control transfer with a delay slot
		d, has_d := f.insns[pc + 4]
		dstmts := make([dynamic]string, 0, 4, context.temp_allocator)
		if has_d {
			if r5900.has_delay(d) {
				fmt.eprintfln("warning %s: branch in delay slot at %s", hexu(f.entry), hexu(pc + 4))
			} else {
				emit_op(d, &dstmts)
				pending += 1
			}
		}
		skip[pc + 4] = true
		ret := pc + 8

		#partial switch i.kind {
		case .Branch:
			cond := branch_cond(i)
			append(&body, "{")
			append(&body, fmt.tprintf("t := %s", cond))
			if i.link {append(&body, fmt.tprintf("c.r[31].d[0] = %s", hexu(ret)))}
			if i.likely {
				// delay slot only when taken
				append(&body, "if t {")
				for s in dstmts {append(&body, fmt.tprintf("\t%s", s))}
				flush(&body, &pending)
				if i.link {
					append(&body, fmt.tprintf("\t%s", call_stmt(e, i.target)))
				} else {
					tmp := make([dynamic]string, 0, 4, context.temp_allocator)
					goto_stmts(e, f, pc, i.target, &tmp)
					for s in tmp {append(&body, fmt.tprintf("\t%s", s))}
				}
				append(&body, "}")
			} else {
				append(&body, ..dstmts[:])
				flush(&body, &pending)
				append(&body, "if t {")
				if i.link {
					append(&body, fmt.tprintf("\t%s", call_stmt(e, i.target)))
				} else {
					tmp := make([dynamic]string, 0, 4, context.temp_allocator)
					goto_stmts(e, f, pc, i.target, &tmp)
					for s in tmp {append(&body, fmt.tprintf("\t%s", s))}
				}
				append(&body, "}")
			}
			append(&body, "}")
			if cond == "true" && !i.link {open_case = false}
		case .Jump:
			append(&body, ..dstmts[:])
			flush(&body, &pending)
			goto_stmts(e, f, pc, i.target, &body)
			open_case = false
		case .Call:
			append(&body, fmt.tprintf("c.r[31].d[0] = %s", hexu(ret)))
			append(&body, ..dstmts[:])
			flush(&body, &pending)
			append(&body, call_stmt(e, i.target))
		case .Jalr:
			append(&body, "{")
			append(&body, fmt.tprintf("t := %s", R32(i.rs)))
			if i.rd != 0 {append(&body, fmt.tprintf("c.r[%d].d[0] = %s", i.rd, hexu(ret)))}
			append(&body, ..dstmts[:])
			flush(&body, &pending)
			append(&body, "ee.call(t)")
			append(&body, "}")
		case .Jr:
			if i.rs == 31 {
				append(&body, ..dstmts[:])
				flush(&body, &pending)
				append(&body, "return")
			} else {
				append(&body, "{")
				append(&body, fmt.tprintf("t := %s", R32(i.rs)))
				append(&body, ..dstmts[:])
				flush(&body, &pending)
				append(&body, "pc = t")
				append(&body, "if c.cycles >= ee.next_event {ee.run_events()}")
				append(&body, "continue")
				append(&body, "}")
			}
			open_case = false
		}

		if (pc + 4) in f.labels && (pc + 4) in f.insns {
			// The delay slot is itself a jump target: give it its own case.
			if open_case {
				flush(&body, &pending)
				append(&body, fmt.tprintf("pc = %s", hexu(pc + 8)))
				append(&body, "continue")
			}
			close_case(sb, &body)
			fmt.sbprintfln(sb, "\t\tcase %s:", hexu(pc + 4))
			emit_op(d, &body)
			pending += 1
			open_case = true
		}
	}
	if open_case {
		flush(&body, &pending)
		append(&body, call_stmt(e, f.end))
		append(&body, "return")
	}
	close_case(sb, &body)
	fmt.sbprintln(sb, "\t\tcase:")
	// Jump to an address that is not a label: the jr target table missed it.
	fmt.sbprintfln(sb, "\t\t\tee.jump_unknown(%s, pc)", hexu(f.entry))
	fmt.sbprintln(sb, "\t\t\treturn")
	fmt.sbprintln(sb, "\t\t}")
	fmt.sbprintln(sb, "\t}")
	fmt.sbprintln(sb, "}")
	fmt.sbprintln(sb, "")
}

call_stmt :: proc(e: ^Emitter, t: u32) -> string {
	if pkg, ok := e.pkg_of[t]; ok && pkg == e.pkg {
		return fmt.tprintf("f_%08x()", t)
	}
	return fmt.tprintf("ee.call(%s)", hexu(t))
}

sort_u32 :: proc(a: []u32) {
	// insertion is too slow for big functions; use the core sort
	slice.sort(a)
}
