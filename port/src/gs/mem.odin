// Software GS: 4 MiB local memory with the hardware's page/block/column
// swizzles, host-to-local and local-to-local transfers, and the CLUT.
//
// Swizzle tables are from PCSX2 (pcsx2/GS/GSTables.cpp). Z formats use the
// colour layouts with the block number XORed by 24.
package gs

import "../ee"

PSMCT32 :: 0x00
PSMCT24 :: 0x01
PSMCT16 :: 0x02
PSMCT16S :: 0x0a
PSMT8 :: 0x13
PSMT4 :: 0x14
PSMT8H :: 0x1b
PSMT4HL :: 0x24
PSMT4HH :: 0x2c
PSMZ32 :: 0x30
PSMZ24 :: 0x31
PSMZ16 :: 0x32
PSMZ16S :: 0x3a

VRAM_WORDS :: 1 << 20

vram: [VRAM_WORDS]u32

@(private, rodata)
block32 := [4][8]u32 {
	{0, 1, 4, 5, 16, 17, 20, 21},
	{2, 3, 6, 7, 18, 19, 22, 23},
	{8, 9, 12, 13, 24, 25, 28, 29},
	{10, 11, 14, 15, 26, 27, 30, 31},
}

@(private, rodata)
block16 := [8][4]u32 {
	{0, 2, 8, 10},
	{1, 3, 9, 11},
	{4, 6, 12, 14},
	{5, 7, 13, 15},
	{16, 18, 24, 26},
	{17, 19, 25, 27},
	{20, 22, 28, 30},
	{21, 23, 29, 31},
}

@(private, rodata)
block16s := [8][4]u32 {
	{0, 2, 16, 18},
	{1, 3, 17, 19},
	{8, 10, 24, 26},
	{9, 11, 25, 27},
	{4, 6, 20, 22},
	{5, 7, 21, 23},
	{12, 14, 28, 30},
	{13, 15, 29, 31},
}

@(private, rodata)
col32 := [8][8]u32 {
	{0, 1, 4, 5, 8, 9, 12, 13},
	{2, 3, 6, 7, 10, 11, 14, 15},
	{16, 17, 20, 21, 24, 25, 28, 29},
	{18, 19, 22, 23, 26, 27, 30, 31},
	{32, 33, 36, 37, 40, 41, 44, 45},
	{34, 35, 38, 39, 42, 43, 46, 47},
	{48, 49, 52, 53, 56, 57, 60, 61},
	{50, 51, 54, 55, 58, 59, 62, 63},
}

@(private, rodata)
col16 := [8][16]u32 {
	{0, 2, 8, 10, 16, 18, 24, 26, 1, 3, 9, 11, 17, 19, 25, 27},
	{4, 6, 12, 14, 20, 22, 28, 30, 5, 7, 13, 15, 21, 23, 29, 31},
	{32, 34, 40, 42, 48, 50, 56, 58, 33, 35, 41, 43, 49, 51, 57, 59},
	{36, 38, 44, 46, 52, 54, 60, 62, 37, 39, 45, 47, 53, 55, 61, 63},
	{64, 66, 72, 74, 80, 82, 88, 90, 65, 67, 73, 75, 81, 83, 89, 91},
	{68, 70, 76, 78, 84, 86, 92, 94, 69, 71, 77, 79, 85, 87, 93, 95},
	{96, 98, 104, 106, 112, 114, 120, 122, 97, 99, 105, 107, 113, 115, 121, 123},
	{100, 102, 108, 110, 116, 118, 124, 126, 101, 103, 109, 111, 117, 119, 125, 127},
}

@(private, rodata)
col8 := [16][16]u32 {
	{0, 4, 16, 20, 32, 36, 48, 52, 2, 6, 18, 22, 34, 38, 50, 54},
	{8, 12, 24, 28, 40, 44, 56, 60, 10, 14, 26, 30, 42, 46, 58, 62},
	{33, 37, 49, 53, 1, 5, 17, 21, 35, 39, 51, 55, 3, 7, 19, 23},
	{41, 45, 57, 61, 9, 13, 25, 29, 43, 47, 59, 63, 11, 15, 27, 31},
	{96, 100, 112, 116, 64, 68, 80, 84, 98, 102, 114, 118, 66, 70, 82, 86},
	{104, 108, 120, 124, 72, 76, 88, 92, 106, 110, 122, 126, 74, 78, 90, 94},
	{65, 69, 81, 85, 97, 101, 113, 117, 67, 71, 83, 87, 99, 103, 115, 119},
	{73, 77, 89, 93, 105, 109, 121, 125, 75, 79, 91, 95, 107, 111, 123, 127},
	{128, 132, 144, 148, 160, 164, 176, 180, 130, 134, 146, 150, 162, 166, 178, 182},
	{136, 140, 152, 156, 168, 172, 184, 188, 138, 142, 154, 158, 170, 174, 186, 190},
	{161, 165, 177, 181, 129, 133, 145, 149, 163, 167, 179, 183, 131, 135, 147, 151},
	{169, 173, 185, 189, 137, 141, 153, 157, 171, 175, 187, 191, 139, 143, 155, 159},
	{224, 228, 240, 244, 192, 196, 208, 212, 226, 230, 242, 246, 194, 198, 210, 214},
	{232, 236, 248, 252, 200, 204, 216, 220, 234, 238, 250, 254, 202, 206, 218, 222},
	{193, 197, 209, 213, 225, 229, 241, 245, 195, 199, 211, 215, 227, 231, 243, 247},
	{201, 205, 217, 221, 233, 237, 249, 253, 203, 207, 219, 223, 235, 239, 251, 255},
}

@(private, rodata)
col4 := [16][32]u32 {
	{0, 8, 32, 40, 64, 72, 96, 104, 2, 10, 34, 42, 66, 74, 98, 106, 4, 12, 36, 44, 68, 76, 100, 108, 6, 14, 38, 46, 70, 78, 102, 110},
	{16, 24, 48, 56, 80, 88, 112, 120, 18, 26, 50, 58, 82, 90, 114, 122, 20, 28, 52, 60, 84, 92, 116, 124, 22, 30, 54, 62, 86, 94, 118, 126},
	{65, 73, 97, 105, 1, 9, 33, 41, 67, 75, 99, 107, 3, 11, 35, 43, 69, 77, 101, 109, 5, 13, 37, 45, 71, 79, 103, 111, 7, 15, 39, 47},
	{81, 89, 113, 121, 17, 25, 49, 57, 83, 91, 115, 123, 19, 27, 51, 59, 85, 93, 117, 125, 21, 29, 53, 61, 87, 95, 119, 127, 23, 31, 55, 63},
	{192, 200, 224, 232, 128, 136, 160, 168, 194, 202, 226, 234, 130, 138, 162, 170, 196, 204, 228, 236, 132, 140, 164, 172, 198, 206, 230, 238, 134, 142, 166, 174},
	{208, 216, 240, 248, 144, 152, 176, 184, 210, 218, 242, 250, 146, 154, 178, 186, 212, 220, 244, 252, 148, 156, 180, 188, 214, 222, 246, 254, 150, 158, 182, 190},
	{129, 137, 161, 169, 193, 201, 225, 233, 131, 139, 163, 171, 195, 203, 227, 235, 133, 141, 165, 173, 197, 205, 229, 237, 135, 143, 167, 175, 199, 207, 231, 239},
	{145, 153, 177, 185, 209, 217, 241, 249, 147, 155, 179, 187, 211, 219, 243, 251, 149, 157, 181, 189, 213, 221, 245, 253, 151, 159, 183, 191, 215, 223, 247, 255},
	{256, 264, 288, 296, 320, 328, 352, 360, 258, 266, 290, 298, 322, 330, 354, 362, 260, 268, 292, 300, 324, 332, 356, 364, 262, 270, 294, 302, 326, 334, 358, 366},
	{272, 280, 304, 312, 336, 344, 368, 376, 274, 282, 306, 314, 338, 346, 370, 378, 276, 284, 308, 316, 340, 348, 372, 380, 278, 286, 310, 318, 342, 350, 374, 382},
	{321, 329, 353, 361, 257, 265, 289, 297, 323, 331, 355, 363, 259, 267, 291, 299, 325, 333, 357, 365, 261, 269, 293, 301, 327, 335, 359, 367, 263, 271, 295, 303},
	{337, 345, 369, 377, 273, 281, 305, 313, 339, 347, 371, 379, 275, 283, 307, 315, 341, 349, 373, 381, 277, 285, 309, 317, 343, 351, 375, 383, 279, 287, 311, 319},
	{448, 456, 480, 488, 384, 392, 416, 424, 450, 458, 482, 490, 386, 394, 418, 426, 452, 460, 484, 492, 388, 396, 420, 428, 454, 462, 486, 494, 390, 398, 422, 430},
	{464, 472, 496, 504, 400, 408, 432, 440, 466, 474, 498, 506, 402, 410, 434, 442, 468, 476, 500, 508, 404, 412, 436, 444, 470, 478, 502, 510, 406, 414, 438, 446},
	{385, 393, 417, 425, 449, 457, 481, 489, 387, 395, 419, 427, 451, 459, 483, 491, 389, 397, 421, 429, 453, 461, 485, 493, 391, 399, 423, 431, 455, 463, 487, 495},
	{401, 409, 433, 441, 465, 473, 497, 505, 403, 411, 435, 443, 467, 475, 499, 507, 405, 413, 437, 445, 469, 477, 501, 509, 407, 415, 439, 447, 471, 479, 503, 511},
}

is_z :: #force_inline proc(psm: u32) -> bool {return psm & 0x30 == 0x30}

// Word index of a 32-bit pixel; `bp` in 256-byte blocks, `bw` in 64 pixels.
addr32 :: #force_inline proc(psm, bp, bw, x, y: u32) -> u32 {
	b := block32[(y >> 3) & 3][(x >> 3) & 7]
	if is_z(psm) {b ~= 24}
	blk := bp + ((y >> 5) * bw + (x >> 6)) * 32 + b
	return ((blk << 6) + col32[y & 7][x & 7]) & (VRAM_WORDS - 1)
}

// Halfword index of a 16-bit pixel.
addr16 :: #force_inline proc(psm, bp, bw, x, y: u32) -> u32 {
	b := psm == PSMCT16S || psm == PSMZ16S ? block16s[(y >> 3) & 7][(x >> 4) & 3] : block16[(y >> 3) & 7][(x >> 4) & 3]
	if is_z(psm) {b ~= 24}
	blk := bp + ((y >> 6) * bw + (x >> 6)) * 32 + b
	return ((blk << 7) + col16[y & 7][x & 15]) & (2 * VRAM_WORDS - 1)
}

// Byte index of an 8-bit pixel.
addr8 :: #force_inline proc(bp, bw, x, y: u32) -> u32 {
	blk := bp + ((y >> 6) * (bw >> 1) + (x >> 7)) * 32 + block32[(y >> 4) & 3][(x >> 4) & 7]
	return ((blk << 8) + col8[y & 15][x & 15]) & (4 * VRAM_WORDS - 1)
}

// Nibble index of a 4-bit pixel.
addr4 :: #force_inline proc(bp, bw, x, y: u32) -> u32 {
	blk := bp + ((y >> 7) * (bw >> 1) + (x >> 7)) * 32 + block16[(y >> 4) & 7][(x >> 5) & 3]
	return ((blk << 9) + col4[y & 15][x & 31]) & (8 * VRAM_WORDS - 1)
}

vram16 :: #force_inline proc() -> [^]u16 {return ([^]u16)(&vram[0])}
vram8 :: #force_inline proc() -> [^]u8 {return ([^]u8)(&vram[0])}

// Stored value of a pixel: the full word for 32-bit formats, 24 bits for
// 24-bit ones, the halfword for 16-bit ones and the index for 8/4-bit ones.
read_raw :: proc(psm, bp, bw, x, y: u32) -> u32 {
	switch psm {
	case PSMCT32, PSMZ32: return vram[addr32(psm, bp, bw, x, y)]
	case PSMCT24, PSMZ24: return vram[addr32(psm, bp, bw, x, y)] & 0xffffff
	case PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: return u32(vram16()[addr16(psm, bp, bw, x, y)])
	case PSMT8: return u32(vram8()[addr8(bp, bw, x, y)])
	case PSMT4:
		n := addr4(bp, bw, x, y)
		return u32(vram8()[n >> 1] >> ((n & 1) * 4)) & 15
	case PSMT8H: return vram[addr32(PSMCT32, bp, bw, x, y)] >> 24
	case PSMT4HL: return (vram[addr32(PSMCT32, bp, bw, x, y)] >> 24) & 15
	case PSMT4HH: return vram[addr32(PSMCT32, bp, bw, x, y)] >> 28
	}
	return 0
}

write_raw :: #force_inline proc(psm, bp, bw, x, y, v: u32) {
	switch psm {
	case PSMCT32, PSMZ32: vram[addr32(psm, bp, bw, x, y)] = v
	case PSMCT24, PSMZ24:
		p := &vram[addr32(psm, bp, bw, x, y)]
		p^ = (p^ & 0xff000000) | (v & 0xffffff)
	case PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: vram16()[addr16(psm, bp, bw, x, y)] = u16(v)
	case PSMT8: vram8()[addr8(bp, bw, x, y)] = u8(v)
	case PSMT4:
		n := addr4(bp, bw, x, y)
		b := &vram8()[n >> 1]
		sh := u8(n & 1) * 4
		b^ = (b^ &~ (15 << sh)) | (u8(v & 15) << sh)
	case PSMT8H:
		p := &vram[addr32(PSMCT32, bp, bw, x, y)]
		p^ = (p^ & 0x00ffffff) | (v << 24)
	case PSMT4HL:
		p := &vram[addr32(PSMCT32, bp, bw, x, y)]
		p^ = (p^ & 0xf0ffffff) | ((v & 15) << 24)
	case PSMT4HH:
		p := &vram[addr32(PSMCT32, bp, bw, x, y)]
		p^ = (p^ & 0x0fffffff) | ((v & 15) << 28)
	}
}

// Bits per pixel of a transfer format.
psm_bits :: proc(psm: u32) -> u32 {
	switch psm {
	case PSMCT32, PSMZ32: return 32
	case PSMCT24, PSMZ24: return 24
	case PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: return 16
	case PSMT8, PSMT8H: return 8
	}
	return 4
}

// ------------------------------------------------------------- transfers

@(private)
xfer: struct {
	active:       bool,
	bp, bw, psm:  u32,
	x0, y0, w, h: u32,
	x, y:         u32,
	bits:         u64, // leftover bits of a pixel split across packets
	nbits:        u32,
}

// TRXDIR write: start a host-to-local transfer or run a local copy.
@(private)
xfer_start :: proc(dir: u32) {
	blt := ee.gs.regs[0x50]
	pos := ee.gs.regs[0x51]
	reg := ee.gs.regs[0x52]
	switch dir & 3 {
	case 0:
		xfer = {
			active = true,
			bp     = u32(blt >> 32) & 0x3fff,
			bw     = u32(blt >> 48) & 0x3f,
			psm    = u32(blt >> 56) & 0x3f,
			x0     = u32(pos >> 32) & 0x7ff,
			y0     = u32(pos >> 48) & 0x7ff,
			w      = u32(reg) & 0xfff,
			h      = u32(reg >> 32) & 0xfff,
		}
		if xfer.w == 0 || xfer.h == 0 {xfer.active = false}
	case 2:
		sbp, sbw, spsm := u32(blt) & 0x3fff, u32(blt >> 16) & 0x3f, u32(blt >> 24) & 0x3f
		dbp, dbw, dpsm := u32(blt >> 32) & 0x3fff, u32(blt >> 48) & 0x3f, u32(blt >> 56) & 0x3f
		sx, sy := u32(pos) & 0x7ff, u32(pos >> 16) & 0x7ff
		dx, dy := u32(pos >> 32) & 0x7ff, u32(pos >> 48) & 0x7ff
		w, h := u32(reg) & 0xfff, u32(reg >> 32) & 0xfff
		if hw_on {
			hw_copy(sbp, sbw, spsm, dbp, dbw, dpsm, sx, sy, dx, dy, w, h)
			return
		}
		for y in 0 ..< h {
			for x in 0 ..< w {
				v := read_raw(spsm, sbp, sbw, (sx + x) & 2047, (sy + y) & 2047)
				write_raw(dpsm, dbp, dbw, (dx + x) & 2047, (dy + y) & 2047, v)
			}
		}
	case:
		xfer.active = false
	}
}

// IMAGE data for the active host-to-local transfer. The GPU renderer keeps
// local memory on the GPU alone, so only the position advances here.
transfer :: proc(data: []u8) {
	if !xfer.active {return}
	if !hw_on {
		transfer_cpu(data)
		return
	}
	// The pixels this data completes, after any bits left over from the
	// last packet: whole 32-bit pixels straight from the data, others
	// unpacked one word each.
	t := &xfer
	bpp := psm_bits(t.psm)
	start := t.y * t.w + t.x
	n := u32(min((u64(t.nbits) + u64(len(data)) * 8) / u64(bpp), u64(t.w * t.h - start)))
	rest := data
	if bpp == 32 && t.nbits == 0 {
		hw_upload(t.psm, t.bp, t.bw, t.x0, t.y0, t.w, start, ([^]u32)(raw_data(data))[:n])
		rest = data[n * 4:]
	} else if n > 0 {
		px := make([]u32, n, context.temp_allocator)
		k: u32 = 0
		unpack: for b, i in data {
			t.bits |= u64(b) << t.nbits
			t.nbits += 8
			for t.nbits >= bpp {
				px[k] = u32(t.bits & ((u64(1) << bpp) - 1))
				t.bits >>= bpp
				t.nbits -= bpp
				k += 1
				if k == n {
					rest = data[i + 1:]
					break unpack
				}
			}
		}
		if k < n {rest = nil}
		hw_upload(t.psm, t.bp, t.bw, t.x0, t.y0, t.w, start, px)
	}
	end := start + n
	if end == t.w * t.h {
		t.active = false
		return
	}
	t.x, t.y = end % t.w, end / t.w
	for b in rest {
		t.bits |= u64(b) << t.nbits
		t.nbits += 8
	}
}

@(private)
transfer_cpu :: proc(data: []u8) {
	bpp := psm_bits(xfer.psm)
	// A pixel split across calls goes through the bit queue; whole pixels
	// take the fast loops.
	i := 0
	for ; i < len(data) && xfer.nbits != 0; i += 1 {transfer_byte(data[i], bpp)}
	if !xfer.active {return}
	body := data[i:][:(len(data) - i) * 8 / int(bpp) * int(bpp) / 8]
	if bpp == 32 {
		transfer32(([^]u32)(raw_data(body))[:len(body) / 4])
	} else {
		transfer_px(body, bpp)
	}
	for b in data[i + len(body):] {transfer_byte(b, bpp)}
}

@(private)
transfer_byte :: proc(b: u8, bpp: u32) {
	if !xfer.active {return}
	xfer.bits |= u64(b) << xfer.nbits
	xfer.nbits += 8
	for xfer.nbits >= bpp {
		v := u32(xfer.bits & ((u64(1) << bpp) - 1))
		xfer.bits >>= bpp
		xfer.nbits -= bpp
		write_raw(xfer.psm, xfer.bp, xfer.bw, (xfer.x0 + xfer.x) & 2047, (xfer.y0 + xfer.y) & 2047, v)
		xfer.x += 1
		if xfer.x == xfer.w {
			xfer.x = 0
			xfer.y += 1
			if xfer.y == xfer.h {
				xfer.active = false
				return
			}
		}
	}
}

// Whole 24/16/8/4-bit pixels, low nibble first for 4-bit.
@(private)
transfer_px :: proc(data: []u8, bpp: u32) #no_bounds_check {
	psm, bp, bw := xfer.psm, xfer.bp, xfer.bw
	for i in 0 ..< len(data) * 8 / int(bpp) {
		v: u32
		switch bpp {
		case 24: v = u32(data[3 * i]) | u32(data[3 * i + 1]) << 8 | u32(data[3 * i + 2]) << 16
		case 16: v = u32(data[2 * i]) | u32(data[2 * i + 1]) << 8
		case 8:  v = u32(data[i])
		case:    v = u32(data[i >> 1] >> (u8(i & 1) * 4)) & 15
		}
		write_raw(psm, bp, bw, (xfer.x0 + xfer.x) & 2047, (xfer.y0 + xfer.y) & 2047, v)
		xfer.x += 1
		if xfer.x == xfer.w {
			xfer.x = 0
			xfer.y += 1
			if xfer.y == xfer.h {
				xfer.active = false
				return
			}
		}
	}
}

// Whole 32-bit pixels: the FMV and texture upload path.
@(private)
transfer32 :: proc(words: []u32) #no_bounds_check {
	psm, bp, bw := xfer.psm, xfer.bp, xfer.bw
	for i := 0; i < len(words); {
		x, y := (xfer.x0 + xfer.x) & 2047, (xfer.y0 + xfer.y) & 2047
		if x & 7 == 0 && xfer.x + 8 <= xfer.w && i + 8 <= len(words) {
			// Eight pixels across one block row: one address, then the
			// column table.
			row := &col32[y & 7]
			base := addr32(psm, bp, bw, x, y) - row[0]
			for k in 0 ..< 8 {vram[base + row[k]] = words[i + k]}
			i += 8
			xfer.x += 8
		} else {
			vram[addr32(psm, bp, bw, x, y)] = words[i]
			i += 1
			xfer.x += 1
		}
		if xfer.x == xfer.w {
			xfer.x = 0
			xfer.y += 1
			if xfer.y == xfer.h {
				xfer.active = false
				return
			}
		}
	}
}

// ------------------------------------------------------------------ CLUT

// Raw CLUT entries: 32-bit colours, or 16-bit ones in the low half.
@(private)
clut: [512]u32
@(private)
cbp0, cbp1: u32

// TEX0/TEX2 write: load the CLUT when CLD asks for it.
@(private)
clut_load :: proc(tex0: u64) {
	cbp := u32(tex0 >> 37) & 0x3fff
	switch (tex0 >> 61) & 7 {
	case 0: return
	case 2: cbp0 = cbp
	case 3: cbp1 = cbp
	case 4:
		if cbp == cbp0 {return}
		cbp0 = cbp
	case 5:
		if cbp == cbp1 {return}
		cbp1 = cbp
	case 6, 7: return
	}
	psm := u32(tex0 >> 20) & 0x3f
	cpsm := u32(tex0 >> 51) & 0xf
	csm2 := tex0 & (1 << 55) != 0
	csa := u32(tex0 >> 56) & 0x1f
	n: u32 = (psm == PSMT8 || psm == PSMT8H) ? 256 : 16
	base := csa * 16
	tc := ee.gs.regs[0x1c] // TEXCLUT: CBW, COU, COV
	cbw, cou, cov := u32(tc) & 0x3f, u32(tc >> 6) & 0x3f, u32(tc >> 12) & 0x3ff
	if hw_on {
		hw_clut(cpsm, cbp, cbw, cou, cov, csm2, n, base)
		return
	}
	if csm2 {
		for i in 0 ..< n {
			clut[(base + i) & 511] = read_raw(cpsm, cbp, cbw, cou * 16 + i, cov)
		}
		return
	}
	for i in 0 ..< n {
		x, y: u32
		if n == 256 {
			p := (i & 0xe7) | ((i & 0x08) << 1) | ((i & 0x10) >> 1)
			x, y = p & 15, p >> 4
		} else {
			x, y = i & 7, i >> 3
		}
		clut[(base + i) & 511] = read_raw(cpsm, cbp, 1, x, y)
	}
}
