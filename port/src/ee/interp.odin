// Interpreter for the instructions the recompiler leaves to the runtime:
// MMI (128-bit multimedia), COP0, FPU control, COP2 transfers and VU0 macro
// mode, SA register moves and traps.
package ee

import "../r5900"

@(private)
sat16 :: #force_inline proc(v: i32) -> u16 {return u16(i16(clamp(v, -0x8000, 0x7fff)))}
@(private)
sat8 :: #force_inline proc(v: i32) -> u8 {return u8(i8(clamp(v, -0x80, 0x7f)))}
@(private)
sat32 :: #force_inline proc(v: i64) -> u32 {return u32(i32(clamp(v, i64(min(i32)), i64(max(i32)))))}

exec :: proc(pc, w: u32) {
	exec_insn(r5900.decode(pc, w))
}

// Generated code passes the instruction already decoded.
exec_insn :: proc(i: r5900.Insn) #no_bounds_check {
	pc, w := i.pc, i.w
	c := &cpu
	s := c.r[i.rs]
	t := c.r[i.rt]
	d: Gpr
	write_rd := true
	switch i.op {
	case .MFSA: d.d[0] = u64(c.sa)
	case .MTSA: c.sa = u32(s.d[0]) & 127; write_rd = false
	case .MTSAB: c.sa = ((u32(s.d[0]) ~ u32(i.imm)) & 15) * 8; write_rd = false
	case .MTSAH: c.sa = ((u32(s.d[0]) ~ u32(i.imm)) & 7) * 16; write_rd = false
	case .TGE, .TGEU, .TLT, .TLTU, .TEQ, .TNE, .TRAPI:
		trap := false
		#partial switch i.op {
		case .TGE:  trap = s.sd[0] >= t.sd[0]
		case .TGEU: trap = s.d[0] >= t.d[0]
		case .TLT:  trap = s.sd[0] < t.sd[0]
		case .TLTU: trap = s.d[0] < t.d[0]
		case .TEQ:  trap = s.d[0] == t.d[0]
		case .TNE:  trap = s.d[0] != t.d[0]
		case .TRAPI:
			v := i64(r5900.sx16(i.imm))
			switch i.rt {
			case 8:  trap = s.sd[0] >= v
			case 9:  trap = s.d[0] >= u64(v)
			case 10: trap = s.sd[0] < v
			case 11: trap = s.d[0] < u64(v)
			case 12: trap = s.sd[0] == v
			case 14: trap = s.sd[0] != v
			}
		}
		if trap {fatal("trap at %08x", pc)}
		return
	case .MADD:   madd(i.rd, u32(s.d[0]), u32(t.d[0]), 0, true); return
	case .MADDU:  madd(i.rd, u32(s.d[0]), u32(t.d[0]), 0, false); return
	case .MADD1:  madd(i.rd, u32(s.d[0]), u32(t.d[0]), 1, true); return
	case .MADDU1: madd(i.rd, u32(s.d[0]), u32(t.d[0]), 1, false); return
	case .MTHI1: c.hi.d[1] = s.d[0]; return
	case .MTLO1: c.lo.d[1] = s.d[0]; return
	case .PLZCW:
		for k in 0 ..< 2 {
			v := s.w[k]
			if v & 0x80000000 != 0 {v = ~v}
			d.w[k] = v == 0 ? 31 : u32(intrinsics_clz(v)) - 1
		}
	case .PMFHL:
		lo, hi := c.lo, c.hi
		switch i.sa {
		case 0: d.w = {lo.w[0], hi.w[0], lo.w[2], hi.w[2]}
		case 1: d.w = {lo.w[1], hi.w[1], lo.w[3], hi.w[3]}
		case 2:
			d.d[0] = sx32(sat32(i64(u64(hi.w[0]) << 32 | u64(lo.w[0]))))
			d.d[1] = sx32(sat32(i64(u64(hi.w[2]) << 32 | u64(lo.w[2]))))
		case 3: d.h = {lo.h[0], lo.h[2], hi.h[0], hi.h[2], lo.h[4], lo.h[6], hi.h[4], hi.h[6]}
		case 4:
			d.h = {sat16(lo.sw[0]), sat16(lo.sw[1]), sat16(hi.sw[0]), sat16(hi.sw[1]),
			       sat16(lo.sw[2]), sat16(lo.sw[3]), sat16(hi.sw[2]), sat16(hi.sw[3])}
		}
	case .PMTHL:
		c.lo.w[0], c.hi.w[0], c.lo.w[2], c.hi.w[2] = s.w[0], s.w[1], s.w[2], s.w[3]
		return
	case .PSLLH: for k in 0 ..< 8 {d.h[k] = t.h[k] << (i.sa & 15)}
	case .PSRLH: for k in 0 ..< 8 {d.h[k] = t.h[k] >> (i.sa & 15)}
	case .PSRAH: for k in 0 ..< 8 {d.sh[k] = t.sh[k] >> (i.sa & 15)}
	case .PSLLW: for k in 0 ..< 4 {d.w[k] = t.w[k] << i.sa}
	case .PSRLW: for k in 0 ..< 4 {d.w[k] = t.w[k] >> i.sa}
	case .PSRAW: for k in 0 ..< 4 {d.sw[k] = t.sw[k] >> i.sa}
	// MMI0
	case .PADDW: for k in 0 ..< 4 {d.w[k] = s.w[k] + t.w[k]}
	case .PSUBW: for k in 0 ..< 4 {d.w[k] = s.w[k] - t.w[k]}
	case .PCGTW: for k in 0 ..< 4 {d.w[k] = s.sw[k] > t.sw[k] ? ~u32(0) : 0}
	case .PMAXW: for k in 0 ..< 4 {d.sw[k] = max(s.sw[k], t.sw[k])}
	case .PADDH: for k in 0 ..< 8 {d.h[k] = s.h[k] + t.h[k]}
	case .PSUBH: for k in 0 ..< 8 {d.h[k] = s.h[k] - t.h[k]}
	case .PCGTH: for k in 0 ..< 8 {d.h[k] = s.sh[k] > t.sh[k] ? ~u16(0) : 0}
	case .PMAXH: for k in 0 ..< 8 {d.sh[k] = max(s.sh[k], t.sh[k])}
	case .PADDB: for k in 0 ..< 16 {d.b[k] = s.b[k] + t.b[k]}
	case .PSUBB: for k in 0 ..< 16 {d.b[k] = s.b[k] - t.b[k]}
	case .PCGTB: for k in 0 ..< 16 {d.b[k] = s.sb[k] > t.sb[k] ? 0xff : 0}
	case .PADDSW: for k in 0 ..< 4 {d.w[k] = sat32(i64(s.sw[k]) + i64(t.sw[k]))}
	case .PSUBSW: for k in 0 ..< 4 {d.w[k] = sat32(i64(s.sw[k]) - i64(t.sw[k]))}
	case .PEXTLW: d.w = {t.w[0], s.w[0], t.w[1], s.w[1]}
	case .PPACW:  d.w = {t.w[0], t.w[2], s.w[0], s.w[2]}
	case .PADDSH: for k in 0 ..< 8 {d.h[k] = sat16(i32(s.sh[k]) + i32(t.sh[k]))}
	case .PSUBSH: for k in 0 ..< 8 {d.h[k] = sat16(i32(s.sh[k]) - i32(t.sh[k]))}
	case .PEXTLH: d.h = {t.h[0], s.h[0], t.h[1], s.h[1], t.h[2], s.h[2], t.h[3], s.h[3]}
	case .PPACH:  d.h = {t.h[0], t.h[2], t.h[4], t.h[6], s.h[0], s.h[2], s.h[4], s.h[6]}
	case .PADDSB: for k in 0 ..< 16 {d.b[k] = sat8(i32(s.sb[k]) + i32(t.sb[k]))}
	case .PSUBSB: for k in 0 ..< 16 {d.b[k] = sat8(i32(s.sb[k]) - i32(t.sb[k]))}
	case .PEXTLB: for k in 0 ..< 8 {d.b[2 * k], d.b[2 * k + 1] = t.b[k], s.b[k]}
	case .PPACB:  for k in 0 ..< 8 {d.b[k], d.b[k + 8] = t.b[2 * k], s.b[2 * k]}
	case .PEXT5:
		for k in 0 ..< 4 {
			x := t.w[k]
			d.w[k] = (x & 0x1f) << 3 | ((x >> 5) & 0x1f) << 11 | ((x >> 10) & 0x1f) << 19 | ((x >> 15) & 1) << 31
		}
	case .PPAC5:
		for k in 0 ..< 4 {
			x := t.w[k]
			d.w[k] = (x >> 3) & 0x1f | ((x >> 11) & 0x1f) << 5 | ((x >> 19) & 0x1f) << 10 | ((x >> 31) & 1) << 15
		}
	// MMI1
	case .PABSW: for k in 0 ..< 4 {d.w[k] = t.sw[k] == min(i32) ? 0x7fffffff : u32(abs(t.sw[k]))}
	case .PCEQW: for k in 0 ..< 4 {d.w[k] = s.w[k] == t.w[k] ? ~u32(0) : 0}
	case .PMINW: for k in 0 ..< 4 {d.sw[k] = min(s.sw[k], t.sw[k])}
	case .PADSBH:
		for k in 0 ..< 4 {d.h[k] = s.h[k] - t.h[k]}
		for k in 4 ..< 8 {d.h[k] = s.h[k] + t.h[k]}
	case .PABSH: for k in 0 ..< 8 {d.h[k] = t.sh[k] == min(i16) ? 0x7fff : u16(abs(t.sh[k]))}
	case .PCEQH: for k in 0 ..< 8 {d.h[k] = s.h[k] == t.h[k] ? ~u16(0) : 0}
	case .PMINH: for k in 0 ..< 8 {d.sh[k] = min(s.sh[k], t.sh[k])}
	case .PCEQB: for k in 0 ..< 16 {d.b[k] = s.b[k] == t.b[k] ? 0xff : 0}
	case .PADDUW: for k in 0 ..< 4 {d.w[k] = u32(min(u64(s.w[k]) + u64(t.w[k]), 0xffffffff))}
	case .PSUBUW: for k in 0 ..< 4 {d.w[k] = s.w[k] > t.w[k] ? s.w[k] - t.w[k] : 0}
	case .PEXTUW: d.w = {t.w[2], s.w[2], t.w[3], s.w[3]}
	case .PADDUH: for k in 0 ..< 8 {d.h[k] = u16(min(u32(s.h[k]) + u32(t.h[k]), 0xffff))}
	case .PSUBUH: for k in 0 ..< 8 {d.h[k] = s.h[k] > t.h[k] ? s.h[k] - t.h[k] : 0}
	case .PEXTUH: d.h = {t.h[4], s.h[4], t.h[5], s.h[5], t.h[6], s.h[6], t.h[7], s.h[7]}
	case .PADDUB: for k in 0 ..< 16 {d.b[k] = u8(min(u32(s.b[k]) + u32(t.b[k]), 0xff))}
	case .PSUBUB: for k in 0 ..< 16 {d.b[k] = s.b[k] > t.b[k] ? s.b[k] - t.b[k] : 0}
	case .PEXTUB: for k in 0 ..< 8 {d.b[2 * k], d.b[2 * k + 1] = t.b[k + 8], s.b[k + 8]}
	case .QFSRV:
		if c.sa == 0 {
			d.q = t.q
		} else {
			d.q = (t.q >> c.sa) | (s.q << (128 - c.sa))
		}
	// MMI2
	case .PMADDW, .PMSUBW, .PMULTW, .PMADDUW, .PMULTUW:
		for k in 0 ..< 2 {
			p: i64
			if i.op == .PMADDUW || i.op == .PMULTUW {
				p = i64(u64(s.w[2 * k]) * u64(t.w[2 * k]))
			} else {
				p = i64(s.sw[2 * k]) * i64(t.sw[2 * k])
			}
			acc := i64(u64(c.hi.w[2 * k]) << 32 | u64(c.lo.w[2 * k]))
			#partial switch i.op {
			case .PMADDW, .PMADDUW: p = acc + p
			case .PMSUBW:           p = acc - p
			}
			c.lo.d[k] = sx32(u32(p))
			c.hi.d[k] = sx32(u32(u64(p) >> 32))
			d.sd[k] = p
		}
	case .PSLLVW: for k in 0 ..< 2 {d.d[k] = sx32(t.w[2 * k] << (s.w[2 * k] & 31))}
	case .PSRLVW: for k in 0 ..< 2 {d.d[k] = sx32(t.w[2 * k] >> (s.w[2 * k] & 31))}
	case .PSRAVW: for k in 0 ..< 2 {d.d[k] = sx32(u32(t.sw[2 * k] >> (s.w[2 * k] & 31)))}
	case .PMFHI: d = c.hi
	case .PMFLO: d = c.lo
	case .PINTH:  d.h = {t.h[0], s.h[4], t.h[1], s.h[5], t.h[2], s.h[6], t.h[3], s.h[7]}
	case .PDIVW, .PDIVUW:
		for k in 0 ..< 2 {
			div_fn := i.op == .PDIVW ? div : divu
			div_fn(s.w[2 * k], t.w[2 * k], k)
		}
		return
	case .PCPYLD: d.d = {t.d[0], s.d[0]}
	case .PMADDH, .PMSUBH, .PMULTH:
		// products land in LO/HI words in the order lo0 lo1 hi0 hi1 lo2 lo3 hi2 hi3
		for k in 0 ..< 8 {
			p := i32(s.sh[k]) * i32(t.sh[k])
			dst := (k & 2) != 0 ? &c.hi : &c.lo
			lane := (k & 1) | ((k >> 1) & 2)
			#partial switch i.op {
			case .PMADDH: dst.sw[lane] += p
			case .PMSUBH: dst.sw[lane] -= p
			case:         dst.sw[lane] = p
			}
		}
		d.w = {c.lo.w[0], c.hi.w[0], c.lo.w[2], c.hi.w[2]}
	case .PHMADH, .PHMSBH:
		for k in 0 ..< 4 {
			a := i32(s.sh[2 * k + 1]) * i32(t.sh[2 * k + 1])
			b := i32(s.sh[2 * k]) * i32(t.sh[2 * k])
			v := i.op == .PHMADH ? a + b : a - b
			dst := (k & 1) != 0 ? &c.hi : &c.lo
			dst.sw[(k >> 1) * 2] = v
			dst.sw[(k >> 1) * 2 + 1] = a
		}
		d.w = {c.lo.w[0], c.hi.w[0], c.lo.w[2], c.hi.w[2]}
	case .PAND: d.q = s.q & t.q
	case .PXOR: d.q = s.q ~ t.q
	case .PEXEH: d.h = {t.h[2], t.h[1], t.h[0], t.h[3], t.h[6], t.h[5], t.h[4], t.h[7]}
	case .PREVH: d.h = {t.h[3], t.h[2], t.h[1], t.h[0], t.h[7], t.h[6], t.h[5], t.h[4]}
	case .PDIVBW:
		dv := i32(t.sh[0])
		for k in 0 ..< 4 {
			n := s.sw[k]
			switch {
			case dv == 0:
				c.lo.sw[k] = n < 0 ? 1 : -1
				c.hi.sw[k] = n
			case n == min(i32) && dv == -1:
				c.lo.sw[k] = min(i32)
				c.hi.sw[k] = 0
			case:
				c.lo.sw[k] = n / dv
				c.hi.sw[k] = n % dv
			}
		}
		return
	case .PEXEW:  d.w = {t.w[2], t.w[1], t.w[0], t.w[3]}
	case .PROT3W: d.w = {t.w[1], t.w[2], t.w[0], t.w[3]}
	// MMI3
	case .PMTHI: c.hi = s; return
	case .PMTLO: c.lo = s; return
	case .PINTEH: d.h = {t.h[0], s.h[0], t.h[2], s.h[2], t.h[4], s.h[4], t.h[6], s.h[6]}
	case .PCPYUD: d.d = {s.d[1], t.d[1]}
	case .POR:  d.q = s.q | t.q
	case .PNOR: d.q = ~(s.q | t.q)
	case .PEXCH: d.h = {t.h[0], t.h[2], t.h[1], t.h[3], t.h[4], t.h[6], t.h[5], t.h[7]}
	case .PCPYH:
		for k in 0 ..< 4 {d.h[k] = t.h[0]}
		for k in 4 ..< 8 {d.h[k] = t.h[4]}
	case .PEXCW: d.w = {t.w[0], t.w[2], t.w[1], t.w[3]}
	// COP0
	case .MFC0:
		v := c.cop0[i.rd]
		switch i.rd {
		case 9:  v = u32(c.cycles)
		case 15: v = 0x2e20 // PRId
		}
		if i.rt != 0 {c.r[i.rt].d[0] = sx32(v)}
		return
	case .MTC0: c.cop0[i.rd] = u32(t.d[0]); return
	case .EI: ei(); return
	case .DI: c.cop0[12] &~= 0x10000; return
	case .TLBR, .TLBWI, .TLBWR, .TLBP: return
	case .ERET: // the caller returns; just leave the exception level
		if cpu.cop0[12] & 4 != 0 {cpu.cop0[12] &~= 4} else {cpu.cop0[12] &~= 2}
	// FPU control and square roots
	case .CFC1:
		v: u32 = i.rd == 0 ? 0x2e30 : c.fcr31
		if i.rt != 0 {c.r[i.rt].d[0] = sx32(v)}
		return
	case .CTC1:
		if i.rd == 31 {c.fcr31 = u32(t.d[0])}
		return
	case .SQRT_S:  c.f[i.sa].f = fsqrt(c.f[i.rt].f); return
	case .RSQRT_S: c.f[i.sa].f = frsqrt(c.f[i.rd].f, c.f[i.rt].f); return
	// COP2
	case .QMFC2: if i.rt != 0 {c.r[i.rt].q = vu0.vf[i.rd].q}; return
	case .QMTC2: vu0_set_vf(i.rd, t.q); return
	case .CFC2:  if i.rt != 0 {c.r[i.rt].d[0] = sx32(vu0_ctrl_read(i.rd))}; return
	case .CTC2:  vu0_ctrl_write(i.rd, u32(t.d[0])); return
	case .VU0:   vu0_macro(w); return
	case .INVALID, .SLL, .SRL, .SRA, .SLLV, .SRLV, .SRAV, .JR, .JALR, .MOVZ, .MOVN, .SYSCALL, .BREAK, .SYNC,
	     .MFHI, .MTHI, .MFLO, .MTLO, .DSLLV, .DSRLV, .DSRAV, .MULT, .MULTU, .DIV, .DIVU,
	     .ADD, .ADDU, .SUB, .SUBU, .AND, .OR, .XOR, .NOR, .SLT, .SLTU,
	     .DADD, .DADDU, .DSUB, .DSUBU, .DSLL, .DSRL, .DSRA, .DSLL32, .DSRL32, .DSRA32,
	     .BLTZ, .BGEZ, .BLTZL, .BGEZL, .BLTZAL, .BGEZAL, .BLTZALL, .BGEZALL,
	     .J, .JAL, .BEQ, .BNE, .BLEZ, .BGTZ, .ADDI, .ADDIU, .SLTI, .SLTIU, .ANDI, .ORI, .XORI, .LUI,
	     .BEQL, .BNEL, .BLEZL, .BGTZL, .DADDI, .DADDIU, .LDL, .LDR, .LQ, .SQ,
	     .LB, .LH, .LWL, .LW, .LBU, .LHU, .LWR, .LWU, .SB, .SH, .SWL, .SW, .SDL, .SDR, .SWR, .CACHE,
	     .LWC1, .PREF, .LQC2, .LD, .SWC1, .SQC2, .SD,
	     .MFHI1, .MFLO1, .MULT1, .MULTU1, .DIV1, .DIVU1,
	     .BC0F, .BC0T, .BC0FL, .BC0TL, .MFC1, .MTC1, .BC1F, .BC1T, .BC1FL, .BC1TL,
	     .ADD_S, .SUB_S, .MUL_S, .DIV_S, .ABS_S, .MOV_S, .NEG_S,
	     .ADDA_S, .SUBA_S, .MULA_S, .MADD_S, .MSUB_S, .MADDA_S, .MSUBA_S, .CVT_W_S, .MAX_S, .MIN_S,
	     .C_F_S, .C_EQ_S, .C_LT_S, .C_LE_S, .CVT_S_W, .BC2F, .BC2T, .BC2FL, .BC2TL:
		fatal("exec: %v at %08x is handled by the recompiler", i.op, pc)
	}
	if write_rd && i.rd != 0 {c.r[i.rd] = d}
}

// Condition line of a COP0/COP2 branch: CPCOND0 (DMA idle) and VU0 busy
// are both false here.
bc_cond :: proc(w: u32) -> bool {
	switch (w >> 26) & 3 {
	case 0: return (w >> 16) & 1 == 1 // bc0t: DMA done
	}
	return (w >> 16) & 1 == 0 // bc2f: VU0 not running
}

@(private)
intrinsics_clz :: #force_inline proc(v: u32) -> u32 {
	n: u32 = 0
	for x := v; x & 0x80000000 == 0 && n < 32; x <<= 1 {n += 1}
	return n
}
