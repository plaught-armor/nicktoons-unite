// Read-circuit output: turns the displayed frame buffer into an RGBA8888
// image for the host window.
package gs

import "core:fmt"
import "../ee"

DISP_W :: 640
DISP_H :: 512

screen: [DISP_W * DISP_H]u32
@(private)
disp_logged: u64

// Copy the active read circuit into `screen`; returns the visible size.
scanout :: proc() -> (w, h: int) {
	pmode := ee.gs_priv(0x00)
	circ: u32 = pmode & 1 != 0 ? 0 : 1
	if pmode & 3 == 0 {
		if hw_on {hw_frame(0, 0, 0, 0, 0, 0, 0)}
		return 0, 0
	}
	dispfb := ee.gs_priv(0x70 + circ * 0x20)
	display := ee.gs_priv(0x80 + circ * 0x20)
	fbp := u32(dispfb & 0x1ff) * 32
	fbw := u32(dispfb >> 9) & 0x3f
	psm := u32(dispfb >> 15) & 0x1f
	dbx := u32(dispfb >> 32) & 0x7ff
	dby := u32(dispfb >> 43) & 0x7ff
	magh := u32(display >> 23) & 0xf
	magv := u32(display >> 27) & 3
	dw := u32(display >> 32) & 0xfff
	dh := u32(display >> 44) & 0x7ff
	w = int((dw + 1) / (magh + 1))
	h = int((dh + 1) / (magv + 1))
	key := (dispfb &~ 0x1ff) ~ display << 1 ~ pmode << 7 // ignore page flips
	if key != disp_logged {
		disp_logged = key
		fmt.eprintfln("gs: display c%d fbp %x fbw %d psm %x at %d,%d size %dx%d (mag %d,%d)",
			circ + 1, fbp, fbw, psm, dbx, dby, w, h, magh, magv)
	}
	w, h = min(w, DISP_W), min(h, DISP_H)
	if hw_on {
		hw_frame(psm, fbp, fbw, dbx, dby, w, h)
		return
	}
	if skip_draw {return} // headless, no shot due: the size is enough
	for y in 0 ..< h {
		row := screen[y * DISP_W:]
		for x in 0 ..< w {
			c := read_raw(psm, fbp, fbw, dbx + u32(x), dby + u32(y))
			if psm == PSMCT16 || psm == PSMCT16S {
				c = (c & 0x1f) << 3 | (c & 0x3e0) << 6 | (c & 0x7c00) << 9
			}
			row[x] = c | 0xff000000
		}
	}
	return
}

// Debug: write the texture TEX0_1 currently names, as raw indices (8/4-bit)
// or colours, to a PPM.
dump_tex :: proc(path: string) -> []u8 {
	t0 := ee.gs.regs[0x06]
	tbp, tbw, psm := u32(t0) & 0x3fff, u32(t0 >> 14) & 0x3f, u32(t0 >> 20) & 0x3f
	w, h := u32(1) << (u32(t0 >> 26) & 0xf), u32(1) << (u32(t0 >> 30) & 0xf)
	fmt.eprintfln("gs: dump tex tbp %x tbw %d psm %x %dx%d", tbp, tbw, psm, w, h)
	buf := make([dynamic]u8, context.temp_allocator)
	append(&buf, fmt.tprintf("P6\n%d %d\n255\n", w, h))
	for y in 0 ..< h {
		for x in 0 ..< w {
			c := read_raw(psm, tbp, tbw, x, y)
			if psm_bits(psm) <= 8 {c = c * 0x010101}
			append(&buf, u8(c), u8(c >> 8), u8(c >> 16))
		}
	}
	return buf[:]
}
