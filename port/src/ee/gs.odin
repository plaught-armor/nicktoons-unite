// GS register state, fed by the GIF. A renderer hooks in through gs.write
// and gs.transfer; without one only the side effects the EE can observe
// (CSR SIGNAL/FINISH, interrupts) are emulated.
package ee

import "core:fmt"

GS_PRIM :: 0x00
GS_RGBAQ :: 0x01
GS_ST :: 0x02
GS_UV :: 0x03
GS_XYZF2 :: 0x04
GS_XYZ2 :: 0x05
GS_FOG :: 0x0a
GS_XYZF3 :: 0x0c
GS_XYZ3 :: 0x0d
GS_TRXDIR :: 0x53
GS_HWREG :: 0x54
GS_SIGNAL :: 0x60
GS_FINISH :: 0x61
GS_LABEL :: 0x62

GS_CSR_SIGNAL :: 0x1
GS_CSR_FINISH :: 0x2

gs: struct {
	regs:    [0x64]u64,
	q:       f32, // from the last ST, latched into RGBAQ
	siglbl:  u64,
	// Renderer entry points: every register write, after it is stored, and
	// host-to-local transfer data.
	write:    proc(reg: u8, v: u64),
	transfer: proc(data: []u8),
}

// Write a GS general register (GIF A+D, REGLIST, or decoded PACKED data).
gs_write :: proc(reg: u8, v: u64) {
	if reg >= len(gs.regs) {return}
	if k.debug == 3 {fmt.eprintfln("gs: %02x = %016x", reg, v)}
	gs.regs[reg] = v
	if gs.write != nil {gs.write(reg, v)}
	switch reg {
	case GS_SIGNAL: // ID/IDMSK into SIGLBLID low word
		m := v >> 32
		gs.siglbl = (gs.siglbl &~ m) | (v & m & 0xffffffff)
		gs_raise(GS_CSR_SIGNAL, 0x100)
	case GS_FINISH:
		gs_raise(GS_CSR_FINISH, 0x200)
	case GS_LABEL:
		m := (v >> 32) << 32
		gs.siglbl = (gs.siglbl &~ m) | ((v << 32) & m)
	}
}

// Set a CSR event bit and interrupt the EE unless IMR masks it.
@(private)
gs_raise :: proc(bit: u32, imr_mask: u32) {
	gs_csr |= bit
	if k.debug == 2 {fmt.eprintfln("gs: raise %x imr %x", bit, gs_imr)}
	if gs_imr & imr_mask == 0 {
		intc_raise(INTC_GS)
	}
}

// IMAGE-mode GIF data, bound for local memory through HWREG.
gs_image :: proc(data: []u8) {
	if gs.transfer != nil {gs.transfer(data)}
}

// Privileged GS register (PMODE, DISPFBn, DISPLAYn, ...) by byte offset.
gs_priv :: proc(off: u32) -> u64 {
	return (^u64)(&gsregs[off &~ 7])^
}

// Emulated state, saved and restored by snapshots (snap.odin).
@(private)
gs_snap :: proc() {
	snap_add(&gs)
}
