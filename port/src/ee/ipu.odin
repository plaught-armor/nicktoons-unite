// Image Processing Unit: the MPEG-2 macroblock decoder, fed by DMA
// channel 4 (toIPU) and drained by channel 3 (fromIPU). Results follow
// PCSX2's IPU bit for bit.
//
// Commands run on their own coroutine so the decoder reads straight-line:
// when it needs input the in FIFO lacks, or the out FIFO is full, it
// switches back to whoever poked the IPU, and resumes at the next register
// access, FIFO access or DMA kick.
package ee

import "base:intrinsics"
import "core:fmt"
import "ps:core"

@(private)
Ipu_Mb8 :: struct {
	y:      [16][16]u8,
	cb, cr: [8][8]u8,
}

@(private)
Ipu_Mb16 :: struct {
	y:      [16][16]i16,
	cb, cr: [8][8]i16,
}

@(private)
Ipu :: struct {
	ctrl:     u32, // IPU_CTRL without IFC, OFC and CBP
	cmd:      u32, // last command word written
	data:     u32, // IPU_CMD result
	top:      u32,
	busy:     bool, // a command is running (CTRL BUSY)
	cmd_busy: bool, // FDEC/VDEC result pending (CMD BUSY)
	top_busy: bool,

	// Bit buffer: up to three quadwords from the in FIFO; bp bits of the
	// first are consumed, fp quadwords are valid.
	buf:      [3]u128,
	bp, fp:   u32,

	in_fifo:  [8]u128,
	out_fifo: [8]u128,
	in_r, in_n, out_r, out_n: u32,
	ch4_end:  bool, // the toIPU chain ends once QWC drains

	th0, th1: i32,
	iq, niq:  [64]u8,
	vqclut:   [16]u16,

	// Decoder state, set up by each command.
	mpeg1, ivf, alt, qst, fpfd: bool,
	idp, coding: u32,
	qs:       i32,
	dc_pred:  [3]i32,
	modes:    u32,
	cbp:      u32,

	block:    [64]i16,
	mb8:      Ipu_Mb8,
	mb16:     Ipu_Mb16,
	rgb32:    [256]u32,
	rgb16:    [256]u16,
	indx4:    [128]u8,

	co, caller: ^core.Coroutine,
}

@(private)
ipu: Ipu

@(private) IPU_CTRL_ECD :: 1 << 14
@(private) IPU_CTRL_SCD :: 1 << 15
@(private) IPU_CTRL_RST :: 1 << 30
@(private) IPU_CTRL_BUSY :: 1 << 31

// ------------------------------------------------------------ registers

// Read the 64-bit IPU register at offset o (0x2000..0x2030).
ipu_read :: proc(o: u32) -> u64 {
	ipu_pump()
	switch o & 0x30 {
	case 0x00:
		if c := ipu.cmd >> 28; c != 3 && c != 4 {
			if v, ok := ipu_try_peek32(); ok {ipu.data = v}
		}
		return u64(ipu.data) | (ipu.cmd_busy ? 1 << 63 : 0)
	case 0x10:
		return u64(ipu.ctrl | ipu.in_n | ipu.out_n << 4 | ipu.cbp << 8)
	case 0x20:
		return u64(ipu.bp & 0x7f | ipu.in_n << 8 | ipu.fp << 16)
	}
	return u64(ipu.top) | (ipu.top_busy ? 1 << 63 : 0)
}

ipu_write :: proc(o: u32, v: u32) {
	switch o & 0x30 {
	case 0x00: ipu_cmd_write(v)
	case 0x10:
		ipu.ctrl = (v & 0x47f30000) | (ipu.ctrl & 0x8000ffff)
		if (ipu.ctrl >> 16) & 3 == 3 {ipu.ctrl = ipu.ctrl &~ 0x30000 | 0x10000}
		if v & IPU_CTRL_RST != 0 {ipu_reset()}
	}
}

@(private)
ipu_reset :: proc() {
	if ipu.co != nil && ipu.busy {
		core.co_kill(ipu.co)
		ipu.co = nil
	}
	ipu.in_r, ipu.in_n, ipu.out_r, ipu.out_n = 0, 0, 0, 0
	ipu.bp, ipu.fp = 0, 0
	ipu.cbp = 0
	ipu.th0, ipu.th1 = 0, 0
	ipu.ctrl &= 0x7f33f00
	ipu.top, ipu.cmd, ipu.data = 0, 0, 0
	ipu.busy, ipu.cmd_busy, ipu.top_busy = false, false, false
	intc_raise(INTC_IPU)
}

@(private)
ipu_cmd_write :: proc(v: u32) {
	if k.debug == 2 {fmt.eprintfln("ipu: cmd %08x", v)}
	ipu.ctrl &~= IPU_CTRL_ECD | IPU_CTRL_SCD
	ipu.cmd = v
	switch v >> 28 {
	case 0: // BCLR
		ipu.in_r, ipu.in_n = 0, 0
		ipu.fp = 0
		ipu.bp = v & 0x7f
		intc_raise(INTC_IPU)
		return
	case 9: // SETTH
		ipu.th0 = i32(v & 0x1ff)
		ipu.th1 = i32((v >> 16) & 0x1ff)
		intc_raise(INTC_IPU)
		return
	case 1, 2: // IDEC, BDEC
		ipu.top_busy = true
	case 3, 4: // VDEC, FDEC
		ipu.top_busy = true
		ipu.cmd_busy = true
	}
	ipu.busy = true
	ipu.ctrl |= IPU_CTRL_BUSY
	ipu_pump()
}

// Run the IPU until it blocks or finishes, moving FIFO data to and from DMA.
ipu_pump :: proc() {
	ipu_ch3_drain()
	ipu_in_refill()
	if ipu.busy && core.co_current != ipu.co {
		if ipu.co == nil {ipu.co = core.co_create(ipu_entry, nil)}
		ipu.caller = core.co_current
		t := prof_start()
		core.co_switch(ipu.co)
		prof_end(.IPU, t)
	}
}

// Block the running command until the IPU is pumped again.
@(private)
ipu_wait :: proc() {
	core.co_switch(ipu.caller)
}

@(private)
ipu_entry :: proc(_: rawptr) {
	for {
		ipu_exec()
		ipu.busy, ipu.cmd_busy, ipu.top_busy = false, false, false
		ipu.ctrl &~= IPU_CTRL_BUSY
		intc_raise(INTC_IPU)
		core.co_switch(ipu.caller)
	}
}

@(private)
ipu_exec :: proc() {
	v := ipu.cmd
	switch v >> 28 {
	case 1: // IDEC
		ipu_advance(v & 0x3f)
		ipu_idec(v)
	case 2: // BDEC
		ipu_advance(v & 0x3f)
		ipu_bdec(v)
	case 3: // VDEC
		ipu_advance(v & 0x3f)
		ipu_vdec(v)
	case 4: // FDEC
		ipu_advance(v & 0x3f)
		ipu.data = ipu_peek(32)
		ipu.top = ipu.data
	case 5: // SETIQ
		ipu_advance(v & 0x3f)
		m := (v >> 27) & 1 != 0 ? &ipu.niq : &ipu.iq
		ipu_get_bytes(m[:])
	case 6: // SETVQ
		ipu_get_bytes(([^]u8)(&ipu.vqclut)[:32])
	case 7: // CSC
		ofm, dte := (v >> 27) & 1 != 0, (v >> 26) & 1 != 0
		for _ in 0 ..< v & 0x7ff {
			ipu_get_bytes(([^]u8)(&ipu.mb8)[:size_of(ipu.mb8)])
			ipu_csc(false)
			if ofm {
				ipu_dither(dte)
				ipu_out(&ipu.rgb16, 32)
			} else {
				ipu_out(&ipu.rgb32, 64)
			}
		}
	case 8: // PACK
		ofm, dte := (v >> 27) & 1 != 0, (v >> 26) & 1 != 0
		for _ in 0 ..< v & 0x7ff {
			ipu_get_bytes(([^]u8)(&ipu.rgb32)[:size_of(ipu.rgb32)])
			ipu_dither(dte)
			if ofm {
				ipu_out(&ipu.rgb16, 32)
			} else {
				ipu_vq()
				ipu_out(&ipu.indx4, 8)
			}
		}
	case:
		fmt.eprintfln("ipu: unknown command %08x", v)
	}
}

// ------------------------------------------------------------ FIFOs and DMA

// Pop the out FIFO (0x10007000).
ipu_fifo_read :: proc() -> u128 {
	ipu_pump()
	if ipu.out_n == 0 {return 0}
	v := ipu.out_fifo[ipu.out_r]
	ipu.out_r = (ipu.out_r + 1) & 7
	ipu.out_n -= 1
	ipu_pump()
	return v
}

// Push the in FIFO (0x10007010).
ipu_fifo_write :: proc(v: u128) {
	if ipu.in_n < 8 {
		ipu.in_fifo[(ipu.in_r + ipu.in_n) & 7] = v
		ipu.in_n += 1
	}
	ipu_pump()
}

ipu_dma_start :: proc(ch: u32) {
	chcr := dma_reg(ch, 0)^
	qwc := dma_reg(ch, 0x20)^ & 0xffff
	if ch == DMA_FROM_IPU {
		if qwc == 0 {dma_finish(ch); return}
		ipu_pump()
		return
	}
	if (chcr >> 2) & 3 != 1 { // normal
		ipu.ch4_end = true
		if qwc == 0 {dma_finish(ch); return}
	} else {
		id := (chcr >> 28) & 7
		ipu.ch4_end = qwc != 0 && (id == 0 || id == 7 || (chcr & 0x80 != 0 && chcr & 0x80000000 != 0))
	}
	ipu_pump()
}

// Move one quadword from the toIPU channel, following its tag chain.
@(private)
ipu_ch4_pull :: proc() -> (v: u128, ok: bool) {
	chcr := dma_reg(DMA_TO_IPU, 0x00)
	madr := dma_reg(DMA_TO_IPU, 0x10)
	qwc := dma_reg(DMA_TO_IPU, 0x20)
	tadr := dma_reg(DMA_TO_IPU, 0x30)
	asr := [2]^u32{dma_reg(DMA_TO_IPU, 0x40), dma_reg(DMA_TO_IPU, 0x50)}
	if chcr^ & 0x100 == 0 {return}
	for _ in 0 ..< 256 {
		if qwc^ & 0xffff != 0 {
			v = rd128(dma_addr(madr^))
			madr^ += 16
			qwc^ = (qwc^ & 0xffff) - 1
			if qwc^ == 0 && ipu.ch4_end {dma_finish(DMA_TO_IPU)}
			return v, true
		}
		if (chcr^ >> 2) & 3 != 1 || ipu.ch4_end {
			dma_finish(DMA_TO_IPU)
			return
		}
		t := tadr^
		lo := rd64(dma_addr(t))
		n := u32(lo & 0xffff)
		addr := u32(lo >> 32) & 0xfffffff0
		chcr^ = (chcr^ & 0xffff) | u32(lo >> 16) << 16
		qwc^ = n
		switch (lo >> 28) & 7 {
		case 0: // refe
			madr^ = addr
			tadr^ = t + 16
			ipu.ch4_end = true
		case 1: // cnt
			madr^ = t + 16
			tadr^ = t + 16 + n * 16
		case 2: // next
			madr^ = t + 16
			tadr^ = addr
		case 3, 4: // ref, refs
			madr^ = addr
			tadr^ = t + 16
		case 5: // call
			madr^ = t + 16
			sp := (chcr^ >> 4) & 3
			if sp < 2 {
				asr[sp]^ = t + 16 + n * 16
				chcr^ = (chcr^ &~ 0x30) | (sp + 1) << 4
			}
			tadr^ = addr
		case 6: // ret
			madr^ = t + 16
			sp := (chcr^ >> 4) & 3
			if sp == 0 {
				ipu.ch4_end = true
			} else {
				sp -= 1
				tadr^ = asr[sp]^
				chcr^ = (chcr^ &~ 0x30) | sp << 4
			}
		case 7: // end
			madr^ = t + 16
			ipu.ch4_end = true
		}
		if chcr^ & 0x80 != 0 && lo & 0x80000000 != 0 {ipu.ch4_end = true}
	}
	fmt.eprintln("ipu: toIPU chain did not end")
	dma_finish(DMA_TO_IPU)
	return
}

@(private)
ipu_in_refill :: proc() {
	for ipu.in_n < 8 {
		v := ipu_ch4_pull() or_break
		ipu.in_fifo[(ipu.in_r + ipu.in_n) & 7] = v
		ipu.in_n += 1
	}
}

@(private)
ipu_ch3_drain :: proc() {
	chcr := dma_reg(DMA_FROM_IPU, 0x00)
	madr := dma_reg(DMA_FROM_IPU, 0x10)
	qwc := dma_reg(DMA_FROM_IPU, 0x20)
	for ipu.out_n > 0 && chcr^ & 0x100 != 0 && qwc^ & 0xffff != 0 {
		wr128(dma_addr(madr^), ipu.out_fifo[ipu.out_r])
		ipu.out_r = (ipu.out_r + 1) & 7
		ipu.out_n -= 1
		madr^ += 16
		qwc^ = (qwc^ & 0xffff) - 1
		if qwc^ == 0 {dma_finish(DMA_FROM_IPU)}
	}
}

// With the out FIFO empty, store up to n quadwords from src straight to
// the fromIPU channel's destination, as draining them one by one would.
// Returns how many were stored.
@(private)
ipu_ch3_direct :: proc(src: [^]u8, n: int) -> int {
	chcr := dma_reg(DMA_FROM_IPU, 0x00)
	madr := dma_reg(DMA_FROM_IPU, 0x10)
	qwc := dma_reg(DMA_FROM_IPU, 0x20)
	if chcr^ & 0x100 == 0 || watch_len != 0 {return 0}
	k := min(n, int(qwc^ & 0xffff))
	a := dma_addr(madr^)
	if k == 0 || a < RAM_SIZE && int(a) + k * 16 > RAM_SIZE || a >= RAM_SIZE && int(a - SPR_BASE) + k * 16 > SPR_SIZE {return 0}
	dst := a < RAM_SIZE ? &ram[a] : &spr[a - SPR_BASE]
	intrinsics.mem_copy_non_overlapping(dst, src, k * 16)
	madr^ += u32(k) * 16
	qwc^ = (qwc^ & 0xffff) - u32(k)
	if qwc^ == 0 {dma_finish(DMA_FROM_IPU)}
	return k
}

// Queue qwc quadwords from p for the fromIPU channel.
@(private)
ipu_out :: proc(p: rawptr, qwc: int) {
	b := ([^]u8)(p)
	for i := 0; i < qwc; i += 1 {
		if ipu.out_n == 0 {
			if n := ipu_ch3_direct(b[i * 16:], qwc - i); n > 0 {
				i += n - 1
				continue
			}
		}
		for ipu.out_n == 8 {
			ipu_ch3_drain()
			if ipu.out_n == 8 {ipu_wait()}
		}
		ipu.out_fifo[(ipu.out_r + ipu.out_n) & 7] = intrinsics.unaligned_load((^u128)(&b[i * 16]))
		ipu.out_n += 1
		ipu_ch3_drain()
	}
}

// ------------------------------------------------------------ bit reader

@(private)
ipu_in_pop :: proc() -> (v: u128, ok: bool) {
	if ipu.in_n == 0 {ipu_in_refill()}
	if ipu.in_n == 0 {return}
	v = ipu.in_fifo[ipu.in_r]
	ipu.in_r = (ipu.in_r + 1) & 7
	ipu.in_n -= 1
	return v, true
}

// Load quadwords until `bits` bits past BP are buffered; false if the
// input runs dry first.
@(private)
ipu_fill :: proc(bits: u32) -> bool {
	for ipu.fp * 128 < ipu.bp + bits {
		ipu.buf[ipu.fp] = ipu_in_pop() or_return
		ipu.fp += 1
	}
	return true
}

@(private)
ipu_need :: #force_inline proc(bits: u32) {
	if ipu.fp * 128 >= ipu.bp + bits {return}
	ipu_need_slow(bits)
}

@(private)
ipu_need_slow :: proc(bits: u32) {
	for !ipu_fill(bits) {ipu_wait()}
}

// The 64 stream bits at BP, left-aligned.
@(private)
ipu_window :: #force_inline proc() -> u64 {
	p := ([^]u8)(&ipu.buf)[ipu.bp >> 3:]
	w := intrinsics.byte_swap(intrinsics.unaligned_load((^u64)(p)))
	return w << (ipu.bp & 7)
}

@(private)
ipu_peek :: proc(bits: u32) -> u32 {
	ipu_need(bits)
	return u32(ipu_window() >> (64 - bits))
}

@(private)
ipu_speek :: proc(bits: u32) -> i32 {
	ipu_need(bits)
	return i32(ipu_window() >> 32) >> (32 - bits)
}

// Peek 32 bits outside a command, without blocking.
@(private)
ipu_try_peek32 :: proc() -> (u32, bool) {
	if !ipu_fill(32) {return 0, false}
	return u32(ipu_window() >> 32), true
}

@(private)
ipu_wrap :: #force_inline proc() {
	if ipu.bp >= 128 && ipu.fp > 0 {
		ipu.bp -= 128
		ipu.buf[0] = ipu.buf[1]
		ipu.buf[1] = ipu.buf[2]
		ipu.fp -= 1
	}
}

@(private)
ipu_advance :: proc(bits: u32) {
	ipu_need(bits)
	ipu.bp += bits
	ipu_wrap()
}

@(private)
ipu_getbits :: proc(bits: u32) -> u32 {
	ipu_need(bits)
	v := u32(ipu_window() >> (64 - bits))
	ipu.bp += bits
	ipu_wrap()
	return v
}

@(private)
ipu_align :: proc() {
	ipu.bp = (ipu.bp + 7) &~ 7
	ipu_wrap()
}

@(private)
ipu_get_bytes :: proc(dst: []u8) {
	i := 0
	for i < len(dst) {
		if ipu.bp & 7 != 0 {
			dst[i] = u8(ipu_getbits(8))
			i += 1
			continue
		}
		ipu_need(8)
		n := min(int(ipu.fp * 16 - ipu.bp / 8), len(dst) - i)
		copy(dst[i:][:n], ([^]u8)(&ipu.buf)[ipu.bp / 8:][:n])
		i += n
		ipu.bp += u32(n) * 8
		for ipu.bp >= 128 && ipu.fp > 0 {ipu_wrap()}
	}
}

// ------------------------------------------------------------ VLC decoding

@(private)
ipu_setup :: proc() {
	c := ipu.ctrl
	ipu.coding = 1
	ipu.mpeg1 = (c >> 23) & 1 != 0
	ipu.qst = (c >> 22) & 1 != 0
	ipu.ivf = (c >> 21) & 1 != 0
	ipu.alt = (c >> 20) & 1 != 0
	ipu.idp = (c >> 16) & 3
}

@(private)
ipu_dc_reset :: proc() {
	ipu.dc_pred = i32(128) << ipu.idp
}

@(private)
ipu_mb_modes :: proc() -> u32 {
	switch ipu.coding {
	case 1: // I
		m := ipu_peek(2)
		if m == 0 {return 0}
		t := MB_I[m >> 1]
		ipu_advance(u32(t.len))
		modes := u32(u8(t.val))
		if !ipu.fpfd {modes |= ipu_getbits(1) * MB_INTERLACED}
		return modes
	case 2: // P
		m := ipu_peek(6)
		if m == 0 {return 0}
		t := MB_P[m >> 1]
		ipu_advance(u32(t.len))
		modes := u32(u8(t.val))
		if ipu.fpfd {
			if modes & MB_FWD != 0 {modes |= MC_FRAME}
		} else {
			if modes & MB_FWD != 0 {modes |= ipu_getbits(2) * 64}
			if modes & (MB_INTRA | MB_PATTERN) != 0 {modes |= ipu_getbits(1) * MB_INTERLACED}
		}
		return modes
	case 3: // B
		m := ipu_peek(6)
		if m == 0 {return 0}
		t := MB_B[m]
		ipu_advance(u32(t.len))
		modes := u32(u8(t.val))
		if ipu.fpfd {
			modes |= MC_FRAME
		} else if modes & MB_INTRA != 0 {
			modes |= ipu_getbits(1) * MB_INTERLACED
		} else {
			modes |= ipu_getbits(2) * 64
			if modes & (MB_INTRA | MB_PATTERN) != 0 {modes |= ipu_getbits(1) * MB_INTERLACED}
		}
		return modes | u32(t.len) << 16
	case 4: // D
		if ipu_getbits(1) == 0 {return 0}
		return MB_INTRA | 1 << 16
	}
	return 0
}

@(private)
ipu_mba_increment :: proc() -> u32 {
	code := ipu_peek(16)
	t: Ipu_Vlc
	switch {
	case code >= 4096: t = MBA_5[ipu_peek(5) - 2]
	case code >= 768:  t = MBA_11[ipu_peek(11) - 24]
	case:
		switch ipu_peek(11) {
		case 8: // macroblock_escape
			ipu_advance(11)
			return 0xb0023
		case 15: // macroblock_stuffing (MPEG-1 only)
			if ipu.mpeg1 {
				ipu_advance(11)
				return 0xb0022
			}
		}
		return 0
	}
	ipu_advance(u32(t.len))
	return u32(t.val + 1) | u32(t.len) << 16
}

@(private)
ipu_dc_diff :: proc(chroma: bool) -> i32 {
	t: Ipu_Vlc
	if !chroma {
		code := ipu_peek(5)
		t = code < 31 ? DC_LUM0[code] : DC_LUM1[ipu_peek(9) - 0x1f0]
	} else {
		code := ipu_peek(5)
		t = code < 31 ? DC_CHROM0[code] : DC_CHROM1[ipu_peek(10) - 0x3e0]
	}
	ipu_advance(u32(t.len))
	size := u32(t.val)
	if size == 0 {return 0}
	d := i32(ipu_getbits(size))
	if d & (1 << (size - 1)) == 0 {d -= (1 << size) - 1}
	return d
}

// DCT codes of 5 to 12 significant bits below the short tables.
@(private)
ipu_dct_long :: #force_inline proc(code: u32) -> Ipu_Dct {
	switch {
	case code >= 256: return DCT_LONG[0][(code >> 4) - 16]
	case code >= 128: return DCT_LONG[1][(code >> 3) - 16]
	case code >= 64:  return DCT_LONG[2][(code >> 2) - 16]
	case code >= 32:  return DCT_LONG[3][(code >> 1) - 16]
	}
	return DCT_LONG[4][code - 16]
}

// Coefficient position in the block layout the IDCT reads.
@(private)
ipu_scan :: #force_inline proc(i: i32) -> u32 {
	j := u32(ipu.alt ? SCAN_ALT[i] : SCAN_NORM[i])
	return ((j & 0x36) >> 1) | ((j & 0x09) << 2)
}

@(private)
ipu_saturate :: #force_inline proc(v: i32) -> i32 {
	return u32(v + 2048) > 4095 ? (v >> 31) ~ 2047 : v
}

@(private)
ipu_intra_block :: proc() {
	tab_a := ipu.ivf && !ipu.mpeg1
	qs := ipu.qs
	for i: i32 = 1;; i += 1 {
		code := ipu_peek(16)
		t: Ipu_Dct
		switch {
		case code >= 16384 && !tab_a: t = DCT_NEXT[(code >> 12) - 4]
		case code >= 1024:            t = tab_a ? DCT_TAB0A[(code >> 8) - 4] : DCT_TAB0[(code >> 8) - 4]
		case code >= 512:             t = tab_a ? DCT_TAB1A[(code >> 6) - 8] : DCT_TAB1[(code >> 6) - 8]
		case code >= 16:              t = ipu_dct_long(code)
		case: return
		}
		ipu_advance(u32(t.len))
		if t.run == 64 {return} // end of block
		i += t.run == 65 ? i32(ipu_getbits(6)) : i32(t.run)
		if i >= 64 {return}
		q := i32(ipu.iq[i])
		val: i32
		if t.run == 65 { // escape
			if !ipu.mpeg1 {
				val = (ipu_speek(12) * qs * q) >> 4
				ipu_advance(12)
			} else {
				val = ipu_speek(8)
				ipu_advance(8)
				if val & 0x7f == 0 {val = i32(ipu_getbits(8)) + 2 * val}
				val = (val * qs * q) >> 4
				val = (val + ~(val >> 31)) | 1
			}
		} else {
			val = (i32(t.level) * qs * q) >> 4
			if ipu.mpeg1 {val = (val - 1) | 1}
			s := ipu_speek(1)
			val = (val ~ s) - s
			ipu_advance(1)
		}
		ipu.block[ipu_scan(i)] = i16(ipu_saturate(val))
	}
}

@(private)
ipu_non_intra_block :: proc() {
	qs := ipu.qs
	for i: i32 = 0;; i += 1 {
		code := ipu_peek(16)
		t: Ipu_Dct
		switch {
		case code >= 16384: t = i == 0 ? DCT_FIRST[(code >> 12) - 4] : DCT_NEXT[(code >> 12) - 4]
		case code >= 1024:  t = DCT_TAB0[(code >> 8) - 4]
		case code >= 512:   t = DCT_TAB1[(code >> 6) - 8]
		case code >= 16:    t = ipu_dct_long(code)
		case: return
		}
		ipu_advance(u32(t.len))
		if t.run == 64 {return}
		i += t.run == 65 ? i32(ipu_getbits(6)) : i32(t.run)
		if i >= 64 {return}
		q := i32(ipu.niq[i])
		val: i32
		if t.run == 65 {
			if !ipu.mpeg1 {
				val = ((2 * (ipu_speek(12) + ipu_speek(1)) + 1) * qs * q) >> 5
				ipu_advance(12)
			} else {
				val = ipu_speek(8)
				ipu_advance(8)
				if val & 0x7f == 0 {val = i32(ipu_getbits(8)) + 2 * val}
				val = ((2 * (val + (val >> 31)) + 1) * qs * q) / 32
				val = (val + ~(val >> 31)) | 1
			}
		} else {
			s := ipu_speek(1)
			val = ((2 * i32(t.level) + 1) * qs * q) >> 5
			val = (val ~ s) - s
			ipu_advance(1)
		}
		ipu.block[ipu_scan(i)] = i16(ipu_saturate(val))
	}
}

// ------------------------------------------------------------ IDCT

@(private) IDCT_W1 :: 2841 // 2048*sqrt(2)*cos(1*pi/16)
@(private) IDCT_W2 :: 2676
@(private) IDCT_W3 :: 2408
@(private) IDCT_W5 :: 1609
@(private) IDCT_W6 :: 1108
@(private) IDCT_W7 :: 565

@(private)
idct_bf :: #force_inline proc(w0, w1, d0, d1: i32) -> (t0, t1: i32) {
	tmp := w0 * (d0 + d1)
	return tmp + (w1 - w0) * d1, tmp - (w1 + w0) * d0
}

// libmpeg2's integer IDCT, on coefficients placed by ipu_scan.
@(private)
ipu_idct :: proc(b: ^[64]i16) {
	for i in 0 ..< 8 {
		r := b[i * 8:][:8]
		if r[1] | r[2] | r[3] | r[4] | r[5] | r[6] | r[7] == 0 {
			v := i16(u16(i32(r[0]) << 3))
			for &x in r {x = v}
			continue
		}
		d0 := (i32(r[0]) << 11) + 128
		d2 := i32(r[2]) << 11
		t0, t1 := d0 + d2, d0 - d2
		t2, t3 := idct_bf(IDCT_W6, IDCT_W2, i32(r[3]), i32(r[1]))
		a0, a1, a2, a3 := t0 + t2, t1 + t3, t1 - t3, t0 - t2
		t0, t1 = idct_bf(IDCT_W7, IDCT_W1, i32(r[7]), i32(r[4]))
		t2, t3 = idct_bf(IDCT_W3, IDCT_W5, i32(r[5]), i32(r[6]))
		b0, b3 := t0 + t2, t1 + t3
		t0 -= t2
		t1 -= t3
		b1 := ((t0 + t1) * 181) >> 8
		b2 := ((t0 - t1) * 181) >> 8
		r[0] = i16((a0 + b0) >> 8)
		r[1] = i16((a1 + b1) >> 8)
		r[2] = i16((a2 + b2) >> 8)
		r[3] = i16((a3 + b3) >> 8)
		r[4] = i16((a3 - b3) >> 8)
		r[5] = i16((a2 - b2) >> 8)
		r[6] = i16((a1 - b1) >> 8)
		r[7] = i16((a0 - b0) >> 8)
	}
	for i in 0 ..< 8 {
		c := b[i:]
		d0 := (i32(c[0]) << 11) + 65536
		d2 := i32(c[16]) << 11
		t0, t1 := d0 + d2, d0 - d2
		t2, t3 := idct_bf(IDCT_W6, IDCT_W2, i32(c[24]), i32(c[8]))
		a0, a1, a2, a3 := t0 + t2, t1 + t3, t1 - t3, t0 - t2
		t0, t1 = idct_bf(IDCT_W7, IDCT_W1, i32(c[56]), i32(c[32]))
		t2, t3 = idct_bf(IDCT_W3, IDCT_W5, i32(c[40]), i32(c[48]))
		b0, b3 := t0 + t2, t1 + t3
		t0 = (t0 - t2) >> 8
		t1 = (t1 - t3) >> 8
		b1 := (t0 + t1) * 181
		b2 := (t0 - t1) * 181
		c[0] = i16((a0 + b0) >> 17)
		c[8] = i16((a1 + b1) >> 17)
		c[16] = i16((a2 + b2) >> 17)
		c[24] = i16((a3 + b3) >> 17)
		c[32] = i16((a3 - b3) >> 17)
		c[40] = i16((a2 - b2) >> 17)
		c[48] = i16((a1 - b1) >> 17)
		c[56] = i16((a0 - b0) >> 17)
	}
}

// Decode an intra block of component cc into 8-bit pixels at dest.
@(private)
ipu_intra_dct :: proc(cc: int, dest: [^]u8, stride: int) {
	ipu.dc_pred[cc] += ipu_dc_diff(cc != 0)
	ipu.block[0] = i16(ipu.dc_pred[cc] << (3 - ipu.idp))
	ipu_intra_block()
	ipu_idct(&ipu.block)
	for y in 0 ..< 8 {
		for x in 0 ..< 8 {dest[y * stride + x] = u8(clamp(ipu.block[y * 8 + x], 0, 255))}
	}
	ipu.block = {}
}

// Decode a non-intra block into 16-bit differences at dest.
@(private)
ipu_non_intra_dct :: proc(dest: [^]i16, stride: int) {
	ipu_non_intra_block()
	ipu_idct(&ipu.block)
	for y in 0 ..< 8 {
		for x in 0 ..< 8 {dest[y * stride + x] = ipu.block[y * 8 + x]}
	}
	ipu.block = {}
}

// ------------------------------------------------------------ commands

// Offset of the lower luma blocks and the luma row stride, in pixels.
@(private)
ipu_dct_layout :: proc() -> (offset, stride: int) {
	return ipu.modes & MB_INTERLACED != 0 ? 16 : 128, ipu.modes & MB_INTERLACED != 0 ? 32 : 16
}

// After a macroblock run: stop at a start code, then latch TOP.
@(private)
ipu_tail :: proc() {
	if ipu_peek(8) == 0 {
		ipu_align()
		for {
			sc := ipu_peek(24)
			if sc != 0 {
				ipu.ctrl |= sc == 1 ? IPU_CTRL_SCD : IPU_CTRL_ECD
				break
			}
			ipu_advance(8)
		}
	}
	ipu.top = ipu_peek(32)
}

@(private)
ipu_idec :: proc(v: u32) {
	ipu_setup()
	ipu.qs = i32((v >> 16) & 0x1f)
	ipu.fpfd = (v >> 24) & 1 == 0
	sgn, dte, ofm := (v >> 25) & 1 != 0, (v >> 26) & 1 != 0, (v >> 27) & 1 != 0
	ipu_dc_reset()
	ipu.top = 0
	ipu.ctrl &~= IPU_CTRL_ECD
	ipu_need(32)
	slice: for {
		ipu.modes = ipu_mb_modes()
		if ipu.modes & MB_QUANT != 0 {
			code := ipu_getbits(5)
			ipu.qs = ipu.qst ? NON_LINEAR_QSCALE[code] : i32(code) << 1
		}
		ipu.cbp = 0x3f
		ipu.mb8 = {}
		off, stride := ipu_dct_layout()
		y := ([^]u8)(&ipu.mb8.y)
		ipu_intra_dct(0, y, stride)
		ipu_intra_dct(0, y[8:], stride)
		ipu_intra_dct(0, y[off:], stride)
		ipu_intra_dct(0, y[off + 8:], stride)
		ipu_intra_dct(1, ([^]u8)(&ipu.mb8.cb), 8)
		ipu_intra_dct(2, ([^]u8)(&ipu.mb8.cr), 8)
		ipu_csc(sgn)
		if ofm {
			ipu_dither(dte)
			ipu_out(&ipu.rgb16, 32)
		} else {
			ipu_out(&ipu.rgb32, 64)
		}

		// Macroblock address increment of the next macroblock.
		mba: i32
		t: Ipu_Vlc
		for {
			code := ipu_peek(16)
			if code >= 0x1000 {
				t = MBA_5[ipu_peek(5) - 2]
				break
			} else if code >= 0x300 {
				t = MBA_11[ipu_peek(11) - 24]
				break
			}
			switch ipu_peek(11) {
			case 8: // macroblock_escape
				mba += 33
				ipu_advance(11)
			case 15: // macroblock_stuffing
				ipu_advance(11)
			case: // end of slice
				break slice
			}
		}
		ipu_advance(u32(t.len))
		mba += i32(t.val)
		if mba != 0 {ipu_dc_reset()}
		ipu_need(16)
	}
	ipu.ctrl &~= IPU_CTRL_SCD
	ipu_tail()
}

@(private)
ipu_bdec :: proc(v: u32) {
	ipu_setup()
	qsc := (v >> 16) & 0x1f
	ipu.qs = ipu.qst ? NON_LINEAR_QSCALE[qsc] : i32(qsc) << 1
	ipu.modes = (v >> 25) & 1 != 0 ? MB_INTERLACED : 0
	ipu.modes |= (v >> 27) & 1 != 0 ? MB_INTRA : MB_PATTERN
	if (v >> 26) & 1 != 0 {ipu_dc_reset()}
	ipu.ctrl &~= IPU_CTRL_ECD
	ipu.top = 0
	ipu.mb8 = {}
	ipu.mb16 = {}
	ipu_need(32)
	off, stride := ipu_dct_layout()
	if ipu.modes & MB_INTRA != 0 {
		ipu.cbp = 0x3f
		y := ([^]u8)(&ipu.mb8.y)
		ipu_intra_dct(0, y, stride)
		ipu_intra_dct(0, y[8:], stride)
		ipu_intra_dct(0, y[off:], stride)
		ipu_intra_dct(0, y[off + 8:], stride)
		ipu_intra_dct(1, ([^]u8)(&ipu.mb8.cb), 8)
		ipu_intra_dct(2, ([^]u8)(&ipu.mb8.cr), 8)
		s := ([^]u8)(&ipu.mb8)
		d := ([^]i16)(&ipu.mb16)
		for i in 0 ..< size_of(ipu.mb8) {d[i] = i16(s[i])}
	} else {
		code := ipu_peek(16)
		t := code >= 0x2000 ? CBP_7[ipu_peek(7) - 16] : CBP_9[ipu_peek(9)]
		ipu_advance(u32(t.len))
		ipu.cbp = u32(u8(t.val))
		y := ([^]i16)(&ipu.mb16.y)
		if ipu.cbp & 0x20 != 0 {ipu_non_intra_dct(y, stride)}
		if ipu.cbp & 0x10 != 0 {ipu_non_intra_dct(y[8:], stride)}
		if ipu.cbp & 0x08 != 0 {ipu_non_intra_dct(y[off:], stride)}
		if ipu.cbp & 0x04 != 0 {ipu_non_intra_dct(y[off + 8:], stride)}
		if ipu.cbp & 0x02 != 0 {ipu_non_intra_dct(([^]i16)(&ipu.mb16.cb), 8)}
		if ipu.cbp & 0x01 != 0 {ipu_non_intra_dct(([^]i16)(&ipu.mb16.cr), 8)}
	}
	ipu.ctrl &~= IPU_CTRL_SCD
	ipu_out(&ipu.mb16, 48)
	ipu_tail()
}

@(private)
ipu_vdec :: proc(v: u32) {
	ipu_need(32)
	switch (v >> 26) & 3 {
	case 0: // macroblock address increment
		ipu.mpeg1 = (ipu.ctrl >> 23) & 1 != 0
		ipu.data = ipu_mba_increment()
	case 1: // macroblock type
		ipu.fpfd = true
		pct := (ipu.ctrl >> 24) & 7
		ipu.coding = pct > 0 ? pct : 1
		ipu.data = ipu_mb_modes()
	case 2: // motion code
		if ipu_peek(16) & 0x8000 != 0 {
			ipu_advance(1)
			ipu.data = 0x10000
		} else {
			code := ipu_peek(16)
			t := (code & 0xf000 != 0 || code & 0xfc00 == 0x0c00) ? MV_4[ipu_peek(4)] : MV_10[ipu_peek(10)]
			delta := i32(t.val) + 1
			ipu_advance(u32(t.len))
			s := ipu_speek(1)
			ipu_advance(1)
			ipu.data = u32(((delta ~ s) - s) | i32(t.len) << 16)
		}
	case 3: // dual-prime vector
		t := DMV_2[ipu_peek(2)]
		ipu_advance(u32(t.len))
		ipu.data = u32(i32(t.val) | i32(t.len) << 16)
	}
	if ipu.data == 0 {ipu.ctrl |= IPU_CTRL_ECD} else {ipu.ctrl &~= IPU_CTRL_ECD}
	ipu.top = ipu_peek(32)
}

// ------------------------------------------------------------ colour

// YCbCr macroblock (mb8) to RGBA32, with the SETTH alpha thresholds.
@(private)
ipu_csc :: proc(sgn: bool) #no_bounds_check {
	// Eight pixels of a row at a time; each chroma sample covers two.
	V :: #simd[8]i32
	U :: #simd[8]u32
	sra :: #force_inline proc(v: V, $N: u32) -> V {return intrinsics.simd_shr(v, U(N))}
	t0, t1 := V(ipu.th0), V(ipu.th1)
	for y in 0 ..< 16 {
		for h in 0 ..< 2 {
			yr := ipu.mb8.y[y][h * 8:]
			cbr, crr := ipu.mb8.cb[y >> 1][h * 4:], ipu.mb8.cr[y >> 1][h * 4:]
			yv := V{i32(yr[0]), i32(yr[1]), i32(yr[2]), i32(yr[3]), i32(yr[4]), i32(yr[5]), i32(yr[6]), i32(yr[7])}
			cb := V{i32(cbr[0]), i32(cbr[0]), i32(cbr[1]), i32(cbr[1]), i32(cbr[2]), i32(cbr[2]), i32(cbr[3]), i32(cbr[3])} - 128
			cr := V{i32(crr[0]), i32(crr[0]), i32(crr[1]), i32(crr[1]), i32(crr[2]), i32(crr[2]), i32(crr[3]), i32(crr[3])} - 128
			lum := sra(0x95 * intrinsics.simd_max(V(0), yv - 16), 6)
			r := intrinsics.simd_clamp(sra(lum + sra(0xcc * cr, 6) + 1, 1), V(0), V(255))
			g := intrinsics.simd_clamp(sra(lum + sra(-0x68 * cr, 6) + sra(-0x32 * cb, 6) + 1, 1), V(0), V(255))
			b := intrinsics.simd_clamp(sra(lum + sra(0x102 * cb, 6) + 1, 1), V(0), V(255))
			px := transmute(U)(r | intrinsics.simd_shl(g, U(8)) | intrinsics.simd_shl(b, U(16)))
			// Alpha 0x40 below TH1, else 0x80; below TH0 (when set) the
			// pixel is transparent black.
			below1 := intrinsics.simd_lanes_lt(r, t1) & intrinsics.simd_lanes_lt(g, t1) & intrinsics.simd_lanes_lt(b, t1)
			px |= intrinsics.simd_select(below1, U(0x40 << 24), U(0x80 << 24))
			if sgn {px ~= 0x808080}
			if ipu.th0 > 0 {
				below0 := intrinsics.simd_lanes_lt(r, t0) & intrinsics.simd_lanes_lt(g, t0) & intrinsics.simd_lanes_lt(b, t0)
				px = intrinsics.simd_select(below0, U(sgn ? 0x808080 : 0), px)
			}
			intrinsics.unaligned_store((^U)(&ipu.rgb32[y * 16 + h * 8]), px)
		}
	}
}

@(private)
IPU_DITHER := [4][4]i32{{-4, 0, -3, 1}, {2, -2, 3, -1}, {-3, 1, -4, 0}, {3, -1, 2, -2}}

// RGBA32 to RGBA16, optionally dithered.
@(private)
ipu_dither :: proc(dte: bool) {
	for i in 0 ..< 16 {
		for j in 0 ..< 16 {
			c := ipu.rgb32[i * 16 + j]
			r, g, b := i32(c & 0xff), i32((c >> 8) & 0xff), i32((c >> 16) & 0xff)
			if dte {
				d := IPU_DITHER[i & 3][j & 3]
				r, g, b = clamp(r + d, 0, 255), clamp(g + d, 0, 255), clamp(b + d, 0, 255)
			}
			a: u16 = c >> 24 == 0x40 ? 0x8000 : 0
			ipu.rgb16[i * 16 + j] = u16(r >> 3) | u16(g >> 3) << 5 | u16(b >> 3) << 10 | a
		}
	}
}

// RGBA16 to 4-bit indices into the SETVQ palette.
@(private)
ipu_vq :: proc() {
	closest :: proc(c: u16) -> u8 {
		best: u8
		min_d := max(i32)
		for k in 0 ..< 16 {
			e := ipu.vqclut[k]
			dr := i32(c & 31) - i32(e & 31)
			dg := i32((c >> 5) & 31) - i32((e >> 5) & 31)
			db := i32((c >> 10) & 31) - i32((e >> 10) & 31)
			d := dr * dr + dg * dg + db * db
			if d < min_d {best, min_d = u8(k), d}
		}
		return best
	}
	for i in 0 ..< 16 {
		for j in 0 ..< 8 {
			ipu.indx4[i * 8 + j] = closest(ipu.rgb16[i * 16 + 2 * j + 1]) << 4 | closest(ipu.rgb16[i * 16 + 2 * j])
		}
	}
}

// Emulated state, saved and restored by snapshots (snap.odin).
@(private)
ipu_snap :: proc() {
	core.snap_add(&ipu)
}
