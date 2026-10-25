// GS local memory on the GPU: the addressing of ../mem.odin over a buffer
// holding one 4 MiB copy of local memory per subsample (scale^2 layers).
// Layer (sx, sy) is the image sampled at offset (sx, sy) / scale inside each
// GS pixel; layer 0 is the native-resolution image.
#extension GL_EXT_buffer_reference : require

// coherent: fragments of overlapping primitives may run on different compute
// units, and pixel interlock only orders them; without it a read can hit a
// stale line in the reading unit's cache.
layout(buffer_reference, std430, buffer_reference_align = 4) coherent buffer Words {
	uint w[];
};

#include "tables.glsl"

#define PSMCT32 0x00u
#define PSMCT24 0x01u
#define PSMCT16 0x02u
#define PSMCT16S 0x0au
#define PSMT8 0x13u
#define PSMT4 0x14u
#define PSMT8H 0x1bu
#define PSMT4HL 0x24u
#define PSMT4HH 0x2cu
#define PSMZ32 0x30u
#define PSMZ24 0x31u
#define PSMZ16 0x32u
#define PSMZ16S 0x3au

#define VRAM_WORDS (1u << 20)

Words VR; // local memory, all layers
uint LB;  // word offset of the current layer

bool is_z(uint psm) { return (psm & 0x30u) == 0x30u; }

uint addr32(uint psm, uint bp, uint bw, uint x, uint y) {
	uint b = block32[((y >> 3) & 3u) * 8u + ((x >> 3) & 7u)];
	if (is_z(psm)) b ^= 24u;
	uint blk = bp + ((y >> 5) * bw + (x >> 6)) * 32u + b;
	return ((blk << 6) + col32[(y & 7u) * 8u + (x & 7u)]) & (VRAM_WORDS - 1u);
}

uint addr16(uint psm, uint bp, uint bw, uint x, uint y) {
	uint i = ((y >> 3) & 7u) * 4u + ((x >> 4) & 3u);
	uint b = (psm == PSMCT16S || psm == PSMZ16S) ? block16s[i] : block16[i];
	if (is_z(psm)) b ^= 24u;
	uint blk = bp + ((y >> 6) * bw + (x >> 6)) * 32u + b;
	return ((blk << 7) + col16[(y & 7u) * 16u + (x & 15u)]) & (2u * VRAM_WORDS - 1u);
}

uint addr8(uint bp, uint bw, uint x, uint y) {
	uint blk = bp + ((y >> 6) * (bw >> 1) + (x >> 7)) * 32u + block32[((y >> 4) & 3u) * 8u + ((x >> 4) & 7u)];
	return ((blk << 8) + col8[(y & 15u) * 16u + (x & 15u)]) & (4u * VRAM_WORDS - 1u);
}

uint addr4(uint bp, uint bw, uint x, uint y) {
	uint blk = bp + ((y >> 7) * (bw >> 1) + (x >> 7)) * 32u + block16[((y >> 4) & 7u) * 4u + ((x >> 5) & 3u)];
	return ((blk << 9) + col4[(y & 15u) * 32u + (x & 31u)]) & (8u * VRAM_WORDS - 1u);
}

uint word(uint i) { return VR.w[LB + i]; }

uint read_raw(uint psm, uint bp, uint bw, uint x, uint y) {
	switch (psm) {
	case PSMCT32: case PSMZ32: return word(addr32(psm, bp, bw, x, y));
	case PSMCT24: case PSMZ24: return word(addr32(psm, bp, bw, x, y)) & 0xffffffu;
	case PSMCT16: case PSMCT16S: case PSMZ16: case PSMZ16S: {
		uint a = addr16(psm, bp, bw, x, y);
		return (word(a >> 1) >> ((a & 1u) * 16u)) & 0xffffu;
	}
	case PSMT8: {
		uint a = addr8(bp, bw, x, y);
		return (word(a >> 2) >> ((a & 3u) * 8u)) & 0xffu;
	}
	case PSMT4: {
		uint n = addr4(bp, bw, x, y);
		return (word(n >> 3) >> ((n & 7u) * 4u)) & 15u;
	}
	case PSMT8H: return word(addr32(PSMCT32, bp, bw, x, y)) >> 24;
	case PSMT4HL: return (word(addr32(PSMCT32, bp, bw, x, y)) >> 24) & 15u;
	case PSMT4HH: return word(addr32(PSMCT32, bp, bw, x, y)) >> 28;
	}
	return 0u;
}

// Store `v` in the bits `m` of word i. Neighbouring pixels of a sub-word
// format share words, and different fragments run concurrently, so partial
// stores are atomic.
void store_bits(uint i, uint m, uint v) {
	atomicAnd(VR.w[LB + i], ~m);
	atomicOr(VR.w[LB + i], v & m);
}

void write_raw(uint psm, uint bp, uint bw, uint x, uint y, uint v) {
	switch (psm) {
	case PSMCT32: case PSMZ32: VR.w[LB + addr32(psm, bp, bw, x, y)] = v; break;
	case PSMCT24: case PSMZ24: store_bits(addr32(psm, bp, bw, x, y), 0xffffffu, v); break;
	case PSMCT16: case PSMCT16S: case PSMZ16: case PSMZ16S: {
		uint a = addr16(psm, bp, bw, x, y);
		uint sh = (a & 1u) * 16u;
		store_bits(a >> 1, 0xffffu << sh, v << sh);
		break;
	}
	case PSMT8: {
		uint a = addr8(bp, bw, x, y);
		uint sh = (a & 3u) * 8u;
		store_bits(a >> 2, 0xffu << sh, v << sh);
		break;
	}
	case PSMT4: {
		uint n = addr4(bp, bw, x, y);
		uint sh = (n & 7u) * 4u;
		store_bits(n >> 3, 15u << sh, v << sh);
		break;
	}
	case PSMT8H: store_bits(addr32(PSMCT32, bp, bw, x, y), 0xff000000u, v << 24); break;
	case PSMT4HL: store_bits(addr32(PSMCT32, bp, bw, x, y), 0x0f000000u, v << 24); break;
	case PSMT4HH: store_bits(addr32(PSMCT32, bp, bw, x, y), 0xf0000000u, v << 28); break;
	}
}
