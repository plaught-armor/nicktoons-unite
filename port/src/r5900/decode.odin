// R5900 (Emotion Engine) instruction decoding.
package r5900

Op :: enum u16 {
	INVALID,
	// SPECIAL
	SLL, SRL, SRA, SLLV, SRLV, SRAV, JR, JALR, MOVZ, MOVN, SYSCALL, BREAK, SYNC,
	MFHI, MTHI, MFLO, MTLO, DSLLV, DSRLV, DSRAV, MULT, MULTU, DIV, DIVU,
	ADD, ADDU, SUB, SUBU, AND, OR, XOR, NOR, MFSA, MTSA, SLT, SLTU,
	DADD, DADDU, DSUB, DSUBU, TGE, TGEU, TLT, TLTU, TEQ, TNE,
	DSLL, DSRL, DSRA, DSLL32, DSRL32, DSRA32,
	// REGIMM
	BLTZ, BGEZ, BLTZL, BGEZL, BLTZAL, BGEZAL, BLTZALL, BGEZALL, TRAPI, MTSAB, MTSAH,
	// primary
	J, JAL, BEQ, BNE, BLEZ, BGTZ, ADDI, ADDIU, SLTI, SLTIU, ANDI, ORI, XORI, LUI,
	BEQL, BNEL, BLEZL, BGTZL, DADDI, DADDIU, LDL, LDR, LQ, SQ,
	LB, LH, LWL, LW, LBU, LHU, LWR, LWU, SB, SH, SWL, SW, SDL, SDR, SWR, CACHE,
	LWC1, PREF, LQC2, LD, SWC1, SQC2, SD,
	// MMI
	MADD, MADDU, PLZCW, MFHI1, MTHI1, MFLO1, MTLO1, MULT1, MULTU1, DIV1, DIVU1,
	MADD1, MADDU1, PMFHL, PMTHL, PSLLH, PSRLH, PSRAH, PSLLW, PSRLW, PSRAW,
	// MMI0
	PADDW, PSUBW, PCGTW, PMAXW, PADDH, PSUBH, PCGTH, PMAXH, PADDB, PSUBB, PCGTB,
	PADDSW, PSUBSW, PEXTLW, PPACW, PADDSH, PSUBSH, PEXTLH, PPACH, PADDSB, PSUBSB,
	PEXTLB, PPACB, PEXT5, PPAC5,
	// MMI1
	PABSW, PCEQW, PMINW, PADSBH, PABSH, PCEQH, PMINH, PCEQB, PADDUW, PSUBUW, PEXTUW,
	PADDUH, PSUBUH, PEXTUH, PADDUB, PSUBUB, PEXTUB, QFSRV,
	// MMI2
	PMADDW, PSLLVW, PSRLVW, PMSUBW, PMFHI, PMFLO, PINTH, PMULTW, PDIVW, PCPYLD,
	PMADDH, PHMADH, PAND, PXOR, PMSUBH, PHMSBH, PEXEH, PREVH, PMULTH, PDIVBW, PEXEW, PROT3W,
	// MMI3
	PMADDUW, PSRAVW, PMTHI, PMTLO, PINTEH, PMULTUW, PDIVUW, PCPYUD, POR, PNOR, PEXCH, PCPYH, PEXCW,
	// COP0
	MFC0, MTC0, BC0F, BC0T, BC0FL, BC0TL, TLBR, TLBWI, TLBWR, TLBP, ERET, EI, DI,
	// COP1
	MFC1, CFC1, MTC1, CTC1, BC1F, BC1T, BC1FL, BC1TL,
	ADD_S, SUB_S, MUL_S, DIV_S, SQRT_S, ABS_S, MOV_S, NEG_S, RSQRT_S,
	ADDA_S, SUBA_S, MULA_S, MADD_S, MSUB_S, MADDA_S, MSUBA_S, CVT_W_S, MAX_S, MIN_S,
	C_F_S, C_EQ_S, C_LT_S, C_LE_S, CVT_S_W,
	// COP2 transfers; VU0 macro instructions are VU0 (decoded by the VU tables)
	QMFC2, CFC2, QMTC2, CTC2, BC2F, BC2T, BC2FL, BC2TL, VU0,
}

Kind :: enum u8 {
	Alu,
	Branch, // conditional, delay slot
	Jump, // j
	Call, // jal
	Jr,
	Jalr,
	Bad,
	Sys, // syscall / break / eret
}

Insn :: struct {
	pc, w:          u32,
	op:             Op,
	kind:           Kind,
	likely:         bool, // branch-likely: delay slot runs only when taken
	link:           bool, // branch-and-link
	rs, rt, rd, sa: u8,
	fn:             u8,
	imm:            u16,
	target:         u32,
}

sx16 :: #force_inline proc(v: u16) -> i32 {return i32(i16(v))}

decode :: proc(pc, w: u32) -> (i: Insn) {
	i.pc, i.w = pc, w
	i.rs = u8((w >> 21) & 31)
	i.rt = u8((w >> 16) & 31)
	i.rd = u8((w >> 11) & 31)
	i.sa = u8((w >> 6) & 31)
	i.fn = u8(w & 63)
	i.imm = u16(w)
	btarget := u32(i32(pc + 4) + sx16(i.imm) * 4)
	branch :: proc(i: ^Insn, op: Op, t: u32, likely := false, link := false) {
		i.op, i.kind, i.target, i.likely, i.link = op, .Branch, t, likely, link
	}

	switch w >> 26 {
	case 0:
		SPECIAL := [64]Op {
			0 = .SLL, 2 = .SRL, 3 = .SRA, 4 = .SLLV, 6 = .SRLV, 7 = .SRAV, 8 = .JR, 9 = .JALR,
			10 = .MOVZ, 11 = .MOVN, 12 = .SYSCALL, 13 = .BREAK, 15 = .SYNC,
			16 = .MFHI, 17 = .MTHI, 18 = .MFLO, 19 = .MTLO, 20 = .DSLLV, 22 = .DSRLV, 23 = .DSRAV,
			24 = .MULT, 25 = .MULTU, 26 = .DIV, 27 = .DIVU,
			32 = .ADD, 33 = .ADDU, 34 = .SUB, 35 = .SUBU, 36 = .AND, 37 = .OR, 38 = .XOR, 39 = .NOR,
			40 = .MFSA, 41 = .MTSA, 42 = .SLT, 43 = .SLTU, 44 = .DADD, 45 = .DADDU, 46 = .DSUB, 47 = .DSUBU,
			48 = .TGE, 49 = .TGEU, 50 = .TLT, 51 = .TLTU, 52 = .TEQ, 54 = .TNE,
			56 = .DSLL, 58 = .DSRL, 59 = .DSRA, 60 = .DSLL32, 62 = .DSRL32, 63 = .DSRA32,
		}
		i.op = SPECIAL[i.fn]
		#partial switch i.op {
		case .JR:      i.kind = .Jr
		case .JALR:    i.kind = .Jalr
		case .SYSCALL, .BREAK: i.kind = .Sys
		}
	case 1:
		switch i.rt {
		case 0:  branch(&i, .BLTZ, btarget)
		case 1:  branch(&i, .BGEZ, btarget)
		case 2:  branch(&i, .BLTZL, btarget, likely = true)
		case 3:  branch(&i, .BGEZL, btarget, likely = true)
		case 8 ..= 14: i.op = .TRAPI
		case 16: branch(&i, .BLTZAL, btarget, link = true)
		case 17: branch(&i, .BGEZAL, btarget, link = true)
		case 18: branch(&i, .BLTZALL, btarget, likely = true, link = true)
		case 19: branch(&i, .BGEZALL, btarget, likely = true, link = true)
		case 24: i.op = .MTSAB
		case 25: i.op = .MTSAH
		}
	case 2:
		i.op, i.kind = .J, .Jump
		i.target = ((pc + 4) & 0xf0000000) | ((w & 0x3ffffff) << 2)
	case 3:
		i.op, i.kind = .JAL, .Call
		i.target = ((pc + 4) & 0xf0000000) | ((w & 0x3ffffff) << 2)
	case 4:  branch(&i, .BEQ, btarget)
	case 5:  branch(&i, .BNE, btarget)
	case 6:  branch(&i, .BLEZ, btarget)
	case 7:  branch(&i, .BGTZ, btarget)
	case 8:  i.op = .ADDI
	case 9:  i.op = .ADDIU
	case 10: i.op = .SLTI
	case 11: i.op = .SLTIU
	case 12: i.op = .ANDI
	case 13: i.op = .ORI
	case 14: i.op = .XORI
	case 15: i.op = .LUI
	case 16: decode_cop0(&i, btarget)
	case 17: decode_cop1(&i, btarget)
	case 18: decode_cop2(&i, btarget)
	case 20: branch(&i, .BEQL, btarget, likely = true)
	case 21: branch(&i, .BNEL, btarget, likely = true)
	case 22: branch(&i, .BLEZL, btarget, likely = true)
	case 23: branch(&i, .BGTZL, btarget, likely = true)
	case 24: i.op = .DADDI
	case 25: i.op = .DADDIU
	case 26: i.op = .LDL
	case 27: i.op = .LDR
	case 28: decode_mmi(&i)
	case 30: i.op = .LQ
	case 31: i.op = .SQ
	case 32: i.op = .LB
	case 33: i.op = .LH
	case 34: i.op = .LWL
	case 35: i.op = .LW
	case 36: i.op = .LBU
	case 37: i.op = .LHU
	case 38: i.op = .LWR
	case 39: i.op = .LWU
	case 40: i.op = .SB
	case 41: i.op = .SH
	case 42: i.op = .SWL
	case 43: i.op = .SW
	case 44: i.op = .SDL
	case 45: i.op = .SDR
	case 46: i.op = .SWR
	case 47: i.op = .CACHE
	case 49: i.op = .LWC1
	case 51: i.op = .PREF
	case 54: i.op = .LQC2
	case 55: i.op = .LD
	case 57: i.op = .SWC1
	case 62: i.op = .SQC2
	case 63: i.op = .SD
	}
	if i.op == .INVALID {
		i.kind = .Bad
	}
	return
}

decode_cop0 :: proc(i: ^Insn, btarget: u32) {
	switch i.rs {
	case 0: i.op = .MFC0
	case 4: i.op = .MTC0
	case 8:
		i.kind, i.target = .Branch, btarget
		switch i.rt {
		case 0: i.op = .BC0F
		case 1: i.op = .BC0T
		case 2: i.op, i.likely = .BC0FL, true
		case 3: i.op, i.likely = .BC0TL, true
		}
	case 16:
		switch i.fn {
		case 1:  i.op = .TLBR
		case 2:  i.op = .TLBWI
		case 6:  i.op = .TLBWR
		case 8:  i.op = .TLBP
		case 24: i.op, i.kind = .ERET, .Sys
		case 56: i.op = .EI
		case 57: i.op = .DI
		}
	}
}

decode_cop1 :: proc(i: ^Insn, btarget: u32) {
	switch i.rs {
	case 0: i.op = .MFC1
	case 2: i.op = .CFC1
	case 4: i.op = .MTC1
	case 6: i.op = .CTC1
	case 8:
		i.kind, i.target = .Branch, btarget
		switch i.rt {
		case 0: i.op = .BC1F
		case 1: i.op = .BC1T
		case 2: i.op, i.likely = .BC1FL, true
		case 3: i.op, i.likely = .BC1TL, true
		}
	case 16:
		S := [64]Op {
			0 = .ADD_S, 1 = .SUB_S, 2 = .MUL_S, 3 = .DIV_S, 4 = .SQRT_S, 5 = .ABS_S, 6 = .MOV_S, 7 = .NEG_S,
			22 = .RSQRT_S, 24 = .ADDA_S, 25 = .SUBA_S, 26 = .MULA_S, 28 = .MADD_S, 29 = .MSUB_S,
			30 = .MADDA_S, 31 = .MSUBA_S, 36 = .CVT_W_S, 40 = .MAX_S, 41 = .MIN_S,
			48 = .C_F_S, 50 = .C_EQ_S, 52 = .C_LT_S, 54 = .C_LE_S,
		}
		i.op = S[i.fn]
	case 20:
		if i.fn == 32 {i.op = .CVT_S_W}
	}
}

decode_cop2 :: proc(i: ^Insn, btarget: u32) {
	switch i.rs {
	case 1: i.op = .QMFC2
	case 2: i.op = .CFC2
	case 5: i.op = .QMTC2
	case 6: i.op = .CTC2
	case 8:
		i.kind, i.target = .Branch, btarget
		switch i.rt {
		case 0: i.op = .BC2F
		case 1: i.op = .BC2T
		case 2: i.op, i.likely = .BC2FL, true
		case 3: i.op, i.likely = .BC2TL, true
		}
	case 16 ..= 31:
		i.op = .VU0
	}
}

decode_mmi :: proc(i: ^Insn) {
	switch i.fn {
	case 0:  i.op = .MADD
	case 1:  i.op = .MADDU
	case 4:  i.op = .PLZCW
	case 8:
		T := [32]Op {
			0 = .PADDW, 1 = .PSUBW, 2 = .PCGTW, 3 = .PMAXW, 4 = .PADDH, 5 = .PSUBH, 6 = .PCGTH, 7 = .PMAXH,
			8 = .PADDB, 9 = .PSUBB, 10 = .PCGTB, 16 = .PADDSW, 17 = .PSUBSW, 18 = .PEXTLW, 19 = .PPACW,
			20 = .PADDSH, 21 = .PSUBSH, 22 = .PEXTLH, 23 = .PPACH, 24 = .PADDSB, 25 = .PSUBSB,
			26 = .PEXTLB, 27 = .PPACB, 30 = .PEXT5, 31 = .PPAC5,
		}
		i.op = T[i.sa]
	case 9:
		T := [32]Op {
			0 = .PMADDW, 2 = .PSLLVW, 3 = .PSRLVW, 4 = .PMSUBW, 8 = .PMFHI, 9 = .PMFLO, 10 = .PINTH,
			12 = .PMULTW, 13 = .PDIVW, 14 = .PCPYLD, 16 = .PMADDH, 17 = .PHMADH, 18 = .PAND, 19 = .PXOR,
			20 = .PMSUBH, 21 = .PHMSBH, 26 = .PEXEH, 27 = .PREVH, 28 = .PMULTH, 29 = .PDIVBW,
			30 = .PEXEW, 31 = .PROT3W,
		}
		i.op = T[i.sa]
	case 16: i.op = .MFHI1
	case 17: i.op = .MTHI1
	case 18: i.op = .MFLO1
	case 19: i.op = .MTLO1
	case 24: i.op = .MULT1
	case 25: i.op = .MULTU1
	case 26: i.op = .DIV1
	case 27: i.op = .DIVU1
	case 32: i.op = .MADD1
	case 33: i.op = .MADDU1
	case 40:
		T := [32]Op {
			1 = .PABSW, 2 = .PCEQW, 3 = .PMINW, 4 = .PADSBH, 5 = .PABSH, 6 = .PCEQH, 7 = .PMINH,
			10 = .PCEQB, 16 = .PADDUW, 17 = .PSUBUW, 18 = .PEXTUW, 20 = .PADDUH, 21 = .PSUBUH,
			22 = .PEXTUH, 24 = .PADDUB, 25 = .PSUBUB, 26 = .PEXTUB, 27 = .QFSRV,
		}
		i.op = T[i.sa]
	case 41:
		T := [32]Op {
			0 = .PMADDUW, 3 = .PSRAVW, 8 = .PMTHI, 9 = .PMTLO, 10 = .PINTEH, 12 = .PMULTUW,
			13 = .PDIVUW, 14 = .PCPYUD, 18 = .POR, 19 = .PNOR, 26 = .PEXCH, 27 = .PCPYH, 30 = .PEXCW,
		}
		i.op = T[i.sa]
	case 48: i.op = .PMFHL
	case 49: i.op = .PMTHL
	case 52: i.op = .PSLLH
	case 54: i.op = .PSRLH
	case 55: i.op = .PSRAH
	case 60: i.op = .PSLLW
	case 62: i.op = .PSRLW
	case 63: i.op = .PSRAW
	}
}

has_delay :: #force_inline proc(i: Insn) -> bool {
	return i.kind == .Branch || i.kind == .Jump || i.kind == .Call || i.kind == .Jr || i.kind == .Jalr
}
