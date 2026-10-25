// EE hardware registers: timers, DMAC, INTC, SIF registers and the GS
// privileged registers. Unhandled registers read back what was written.
package ee

import "core:fmt"
import "ps:core"

INTC_GS :: 0
INTC_SBUS :: 1
INTC_VBLANK_START :: 2
INTC_VBLANK_END :: 3
INTC_IPU :: 8
INTC_TIMER0 :: 9

DMA_VIF0 :: 0
DMA_VIF1 :: 1
DMA_GIF :: 2
DMA_FROM_IPU :: 3
DMA_TO_IPU :: 4
DMA_SIF0 :: 5
DMA_SIF1 :: 6
DMA_SIF2 :: 7
DMA_FROM_SPR :: 8
DMA_TO_SPR :: 9

// Base of each DMA channel's registers.
DMA_BASE := [10]u32{0x8000, 0x9000, 0xa000, 0xb000, 0xb400, 0xc000, 0xc400, 0xc800, 0xd000, 0xd400}

@(private)
hwregs: [0x10000]u8 // 0x10000000..0x1000ffff
@(private)
gsregs: [0x2000]u8 // 0x12000000..0x12001fff

intc_stat, intc_mask: u32
// Raised but not yet delivered to kernel handlers. Kept apart from
// INTC_STAT, which only software clears: libraries poll it for VBLANK
// with interrupts enabled.
intc_pending: u32
dmac_stat: u32 // D_STAT: low half status, high half mask
gs_csr: u32
gs_imr: u32 = 0x7f00

@(private)
hw_reg :: #force_inline proc(o: u32) -> ^u32 {
	return (^u32)(&hwregs[o & 0xfffc])
}

dma_reg :: proc(ch, off: u32) -> ^u32 {
	return hw_reg(DMA_BASE[ch] + off)
}

hw_read :: proc(a: u32, size: int) -> u64 {
	a := a & 0x1fffffff
	switch {
	case a >= 0x10000000 && a < 0x10010000:
		o := a & 0xffff
		switch o &~ 3 {
		case 0x0000, 0x0800, 0x1000, 0x1800:
			return u64(timer_count(o >> 11))
		case 0x2000 ..= 0x203c:
			if o & 8 != 0 {return 0}
			v := ipu_read(o) >> ((u64(o) & 7) * 8)
			return size == 8 ? v : v & ((u64(1) << (u64(size) * 8)) - 1)
		case 0xb000, 0xb020, 0xb400, 0xb420: // fromIPU/toIPU CHCR, QWC
			ipu_pump()
		case 0xe010:
			ipu_pump()
			return u64(dmac_stat)
		case 0xf000: return u64(intc_stat)
		case 0xf010: return u64(intc_mask)
		case 0xf200 ..= 0xf260: return u64(sif_reg_read(o))
		}
		v := (^u64)(&hwregs[o &~ 7])^ >> ((u64(o) & 7) * 8)
		return size == 8 ? v : v & ((u64(1) << (u64(size) * 8)) - 1)
	case a >= 0x12000000 && a < 0x12002000:
		o := a & 0x1fff
		switch o &~ 7 {
		case 0x1000: return u64(gs_csr) | 0x551b0000 // revision/id bits
		case 0x1010: return u64(gs_imr)
		}
		return (^u64)(&gsregs[o &~ 7])^
	}
	unmapped(a, "read")
	return 0
}

hw_write :: proc(a: u32, v: u64, size: int) {
	a := a & 0x1fffffff
	switch {
	case a >= 0x10000000 && a < 0x10010000:
		o := a & 0xffff
		w := u32(v)
		switch o &~ 3 {
		case 0xe010:
			dmac_stat &~= w & 0xffff
			dmac_stat ~= w & 0xffff0000
			return
		case 0xf000:
			intc_stat &~= w
			intc_pending &~= w
			return
		case 0xf010:
			intc_mask ~= w
			return
		case 0x2000 ..= 0x203c:
			if o & 0xf == 0 {ipu_write(o, w)}
			return
		case 0xf180: // SIO TX: kernel debug output
			fmt.eprintf("%c", u8(w))
			return
		case 0xf200 ..= 0xf260:
			sif_reg_write(o, w)
			return
		}
		switch size {
		case 1: hwregs[o] = u8(v)
		case 2: (^u16)(&hwregs[o])^ = u16(v)
		case 4: (^u32)(&hwregs[o])^ = w
		case 8: (^u64)(&hwregs[o])^ = v
		}
		// A write to a channel's CHCR with STR set starts it.
		for base, ch in DMA_BASE {
			if o == base && w & 0x100 != 0 {
				dma_start(u32(ch))
			}
		}
		return
	case a >= 0x12000000 && a < 0x12002000:
		o := a & 0x1fff
		switch o &~ 7 {
		case 0x1000:
			gs_csr &~= u32(v) & 0x1f // write 1 clears interrupt bits
			return
		case 0x1010:
			gs_imr = u32(v)
			return
		}
		(^u64)(&gsregs[o &~ 7])^ = v
		return
	}
	unmapped(a, "write")
}

hw_read128 :: proc(a: u32) -> u128 {
	if a & 0x1ffffff0 == 0x10007000 {return ipu_fifo_read()}
	return u128(hw_read(a, 8)) | u128(hw_read(a + 8, 8)) << 64
}

hw_write128 :: proc(a: u32, v: u128) {
	a := a & 0x1fffffff
	switch a &~ 0xf {
	case 0x10004000, 0x10005000, 0x10006000, 0x10007010:
		fifo_write(a, v)
		return
	}
	hw_write(a, u64(v), 8)
	hw_write(a + 8, u64(v >> 64), 8)
}

@(private)
unmapped_seen: map[u32]bool

@(private)
unmapped :: proc(a: u32, what: string) {
	if !unmapped_seen[a] {
		unmapped_seen[a] = true
		fmt.eprintfln("ee: unmapped %s at %08x", what, a)
	}
}

// Raise an INTC interrupt.
intc_raise :: proc(n: u32) {
	intc_stat |= 1 << n
	intc_pending |= 1 << n
	if !k.in_interrupt {next_event = cpu.cycles}
}

// Mark a DMA channel finished and raise its DMAC interrupt.
dma_finish :: proc(ch: u32) {
	chcr := dma_reg(ch, 0)
	chcr^ &~= 0x100
	dmac_stat |= 1 << ch
	if !k.in_interrupt {next_event = cpu.cycles}
}

timer_count :: proc(n: u32) -> u32 {
	mode := hw_reg(0x800 * n + 0x10)^
	div: u64
	switch mode & 3 {
	case 0: div = 2
	case 1: div = 32
	case 2: div = 512
	case 3: div = CYCLES_PER_FRAME / 262 // hblank
	}
	return u32((cpu.cycles / div) & 0xffff)
}

// Start a DMA transfer. Channels without an implementation complete at once.
dma_start :: proc(ch: u32) {
	if k.debug == 2 {fmt.eprintfln("dma: start ch %d chcr %08x tadr %08x", ch, dma_reg(ch, 0)^, dma_reg(ch, 0x30)^)}
	switch ch {
	case DMA_VIF0, DMA_VIF1: dma_vif(ch)
	case DMA_GIF:            dma_gif()
	case DMA_FROM_SPR:       dma_from_spr()
	case DMA_TO_SPR:         dma_to_spr()
	case DMA_FROM_IPU, DMA_TO_IPU:
		ipu_dma_start(ch) // finishes as the IPU moves data
		return
	}
	dma_finish(ch)
}

// Direct FIFO writes: VIF0, VIF1, GIF (PATH3), IPU in.
fifo_write :: proc(a: u32, v: u128) {
	v := v
	b := ([^]u8)(&v)[:16]
	switch (a >> 12) & 0xf {
	case 4: vif_feed(&vifs[0], b)
	case 5: vif_feed(&vifs[1], b)
	case 6: gif_feed(2, b)
	case 7: ipu_fifo_write(v)
	}
}

// Emulated state, saved and restored by snapshots (snap.odin).
@(private)
hw_snap :: proc() {
	core.snap_add(&hwregs)
	core.snap_add(&gsregs)
	core.snap_add(&intc_stat)
	core.snap_add(&intc_mask)
	core.snap_add(&intc_pending)
	core.snap_add(&dmac_stat)
	core.snap_add(&gs_csr)
	core.snap_add(&gs_imr)
	core.snap_add(&unmapped_seen)
}
