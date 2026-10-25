#version 460
// The GS per-pixel pipeline of ../draw.odin `pixel`, run on local memory
// in the fragment's layer: texture mapping, fog, alpha test, destination
// alpha test, depth test, blending and masked frame/depth writes. Pixel
// interlock orders the read-modify-write of each pixel by primitive.
#extension GL_ARB_fragment_shader_interlock : require
#include "common.glsl"
#include "draw.glsl"

layout(pixel_interlock_ordered) in;

layout(location = 0) noperspective in vec4 i_col;
layout(location = 1) noperspective in vec3 i_stq;
layout(location = 2) noperspective in float i_fog;
layout(location = 3) noperspective in float i_z;
layout(location = 4) flat in uint i_zi;
layout(location = 5) flat in uint i_state;

State S;
uint TBP, TBW; // the mipmap level being sampled

uint wrap_coord(int i, uint mode, uint size, uint lo, uint hi) {
	switch (mode) {
	case 0u: return uint(i) & (size - 1u);
	case 1u: return uint(clamp(i, 0, int(size) - 1));
	case 2u: return uint(clamp(i, int(lo), int(hi)));
	}
	return (uint(i) & lo) | hi; // region repeat: MINU is the mask, MAXU the fix
}

uint expand16(uint c) {
	uint rgb = (c & 0x1fu) << 3 | (c & 0x3e0u) << 6 | (c & 0x7c00u) << 9;
	uint a = 0u;
	bool aem = (S.flags & F_AEM) != 0u;
	if ((c & 0x8000u) != 0u) {
		a = S.ta >> 8;
	} else if (!aem || (c & 0x7fffu) != 0u) {
		a = S.ta & 0xffu;
	}
	return rgb | a << 24;
}

// Texel as RGBA8888 (R in the low byte).
uint fetch(uint x, uint y) {
	uint raw = read_raw(S.tpsm, TBP, TBW, x, y);
	switch (S.tpsm) {
	case PSMCT32: return raw;
	case PSMCT24: {
		uint a = ((S.flags & F_AEM) != 0u && raw == 0u) ? 0u : (S.ta & 0xffu);
		return raw | a << 24;
	}
	case PSMCT16: case PSMCT16S: return expand16(raw);
	}
	uint e = pc.cluts.w[S.clut + ((S.csa * 16u + raw) & 511u)];
	if (S.cpsm == PSMCT32) return e;
	return expand16(e & 0xffffu);
}

ivec4 unpack(uint c) {
	return ivec4(int(c & 0xffu), int((c >> 8) & 0xffu), int((c >> 16) & 0xffu), int(c >> 24));
}

// A sample of level n at level-0 texel coordinates, nearest or bilinear.
ivec4 sample_level(uint n, float u, float v, bool bilinear) {
	TBP = S.tbp;
	TBW = S.tbw;
	if (n > 0u) {
		TBP = S.mtb[n - 1u] & 0xffffu;
		TBW = S.mtb[n - 1u] >> 16;
	}
	u /= float(1u << n);
	v /= float(1u << n);
	uint w = max(S.tw >> n, 1u), h = max(S.th >> n, 1u);
	uint wms = S.wrap & 3u, wmt = (S.wrap >> 2) & 3u;
	uint minu = S.umm & 0xffffu, maxu = S.umm >> 16;
	uint minv = S.vmm & 0xffffu, maxv = S.vmm >> 16;
	if (wms == 2u) { minu >>= n; maxu >>= n; }
	if (wmt == 2u) { minv >>= n; maxv >>= n; }
	if (!bilinear) {
		uint x = wrap_coord(int(floor(u)), wms, w, minu, maxu);
		uint y = wrap_coord(int(floor(v)), wmt, h, minv, maxv);
		return unpack(fetch(x, y));
	}
	u -= 0.5;
	v -= 0.5;
	float fu = floor(u), fv = floor(v);
	int iu = int(fu), iv = int(fv);
	int au = int((u - fu) * 256.0), av = int((v - fv) * 256.0);
	uint x0 = wrap_coord(iu, wms, w, minu, maxu);
	uint x1 = wrap_coord(iu + 1, wms, w, minu, maxu);
	uint y0 = wrap_coord(iv, wmt, h, minv, maxv);
	uint y1 = wrap_coord(iv + 1, wmt, h, minv, maxv);
	ivec4 c00 = unpack(fetch(x0, y0)), c10 = unpack(fetch(x1, y0));
	ivec4 c01 = unpack(fetch(x0, y1)), c11 = unpack(fetch(x1, y1));
	ivec4 top = c00 + ((c10 - c00) * au) / 256;
	ivec4 bot = c01 + ((c11 - c01) * au) / 256;
	return top + ((bot - top) * av) / 256;
}

// LOD = log2(1/|Q|) * 2^L + K in 1/2^23ths, as ../draw.odin `tex_lod`.
int tex_lod(float q) {
	int x = 0;
	if ((S.mip & 1u) == 0u) {
		x = clamp((127 << 23) - int(floatBitsToUint(abs(q))), -16 << 23, 16 << 23) << ((S.mip >> 7) & 3u);
	}
	return x + ((int(S.mip) >> 16) << 20 >> 20 << 19);
}

// As ../draw.odin `sample`.
ivec4 sample_tex(float u, float v, int lod) {
	if (lod <= 0) return sample_level(0u, u, v, (S.flags & F_BILINEAR) != 0u);
	uint mxl = (S.mip >> 1) & 7u, mmin = (S.mip >> 4) & 7u;
	bool bil = mmin == 1u || mmin >= 4u;
	if (mmin == 2u || mmin == 4u) {
		return sample_level(min(uint((lod + (1 << 22)) >> 23), mxl), u, v, bil);
	}
	if (mmin == 3u || mmin == 5u) {
		uint n = min(uint(lod >> 23), mxl);
		ivec4 c = sample_level(n, u, v, bil);
		if (n == mxl) return c;
		int f = (lod >> 15) & 0xff;
		return c + ((sample_level(n + 1u, u, v, bil) - c) * f) / 256;
	}
	return sample_level(0u, u, v, bil);
}

ivec3 blend_sel(uint n, ivec4 s, ivec4 d) {
	if (n == 0u) return s.rgb;
	if (n == 1u) return d.rgb;
	return ivec3(0);
}

void main() {
	VR = pc.vram;
	uint sc = pc.scale;
	uvec2 hp = uvec2(gl_FragCoord.xy);
	LB = ((hp.y % sc) * sc + hp.x % sc) * VRAM_WORDS;
	uint px = hp.x / sc, py = hp.y / sc;
	S = pc.states.s[i_state & 0x7fffffffu];
	uint fl = S.flags;
	bool alive = px >= S.sx0 && px <= S.sx1 && py >= S.sy0 && py <= S.sy1;

	ivec4 src = ivec4(i_col);
	if (alive && (fl & F_TME) != 0u) {
		float u = i_stq.x, v = i_stq.y;
		int lod = tex_lod(1.0);
		if ((fl & F_FST) == 0u) {
			lod = tex_lod(i_stq.z);
			float q = i_stq.z == 0.0 ? 1.0 : i_stq.z;
			u = i_stq.x / q * float(S.tw);
			v = i_stq.y / q * float(S.th);
		}
		ivec4 t = sample_tex(u, v, lod);
		bool tcc = (fl & F_TCC) != 0u;
		switch (S.tfx) {
		case 0u: // MODULATE
			src.rgb = min((t.rgb * src.rgb) >> 7, ivec3(255));
			if (tcc) src.a = min((t.a * src.a) >> 7, 255);
			break;
		case 1u: // DECAL
			src.rgb = t.rgb;
			if (tcc) src.a = t.a;
			break;
		default: // HIGHLIGHT, HIGHLIGHT2
			src.rgb = min(((t.rgb * src.rgb) >> 7) + src.a, ivec3(255));
			if (tcc) src.a = S.tfx == 2u ? min(t.a + src.a, 255) : t.a;
			break;
		}
	}
	if ((fl & F_FGE) != 0u) {
		int f = int(i_fog);
		ivec3 fc = ivec3(int(S.fogcol & 0xffu), int((S.fogcol >> 8) & 0xffu), int((S.fogcol >> 16) & 0xffu));
		src.rgb = (f * src.rgb + (255 - f) * fc) >> 8;
	}

	bool write_fb = true, write_z = (fl & F_ZMSK) == 0u, write_alpha = true;
	if ((fl & F_ATE) != 0u) {
		uint a = uint(src.a);
		bool pass = false;
		switch (S.atst) {
		case 0u: pass = false; break;
		case 1u: pass = true; break;
		case 2u: pass = a < S.aref; break;
		case 3u: pass = a <= S.aref; break;
		case 4u: pass = a == S.aref; break;
		case 5u: pass = a >= S.aref; break;
		case 6u: pass = a > S.aref; break;
		case 7u: pass = a != S.aref; break;
		}
		if (!pass) {
			switch (S.afail) {
			case 0u: alive = false; break;
			case 1u: write_z = false; break;
			case 2u: write_fb = false; break;
			case 3u: write_z = false; write_alpha = false; break;
			}
		}
	}
	// The largest float below 2^32, so the conversion stays in range.
	uint z = (i_state & 0x80000000u) != 0u ? i_zi : uint(clamp(i_z, 0.0, 4294967040.0));

	beginInvocationInterlockARB();
	uint fpsm = S.fpsm;
	bool fb32 = fpsm == PSMCT32 || fpsm == PSMCT24 || fpsm == PSMZ32 || fpsm == PSMZ24;
	uint dst_raw = 0u;
	if (alive) {
		dst_raw = read_raw(fpsm, S.fbp, S.fbw, px, py);
		if ((fl & F_DATE) != 0u) {
			bool bit = fb32 ? (dst_raw & 0x80000000u) != 0u : (dst_raw & 0x8000u) != 0u;
			if (bit != ((fl & F_DATM) != 0u)) alive = false;
		}
	}
	bool zte = (fl & F_ZTE) != 0u;
	if (alive && zte) {
		uint zmax = 0xffffffffu;
		if (S.zpsm == PSMZ24) zmax = 0xffffffu;
		else if (S.zpsm == PSMZ16 || S.zpsm == PSMZ16S) zmax = 0xffffu;
		z = min(z, zmax);
		uint dz = read_raw(S.zpsm, S.zbp, S.fbw, px, py);
		if ((S.ztst == 2u && z < dz) || (S.ztst == 3u && z <= dz)) alive = false;
	}
	if (alive && write_z && zte) write_raw(S.zpsm, S.zbp, S.fbw, px, py, z);
	if (alive && write_fb) {
		ivec4 dst;
		if (fb32) {
			dst = unpack(dst_raw);
			if (fpsm == PSMCT24 || fpsm == PSMZ24) dst.a = 0x80;
		} else {
			dst = ivec4(int(dst_raw & 0x1fu) << 3, int((dst_raw >> 5) & 0x1fu) << 3,
				int((dst_raw >> 10) & 0x1fu) << 3, (dst_raw & 0x8000u) != 0u ? 0x80 : 0);
		}
		if ((fl & F_ABE) != 0u && !((fl & F_PABE) != 0u && src.a < 0x80)) {
			uint bl = S.blend;
			ivec3 ca = blend_sel(bl & 3u, src, dst);
			ivec3 cb = blend_sel((bl >> 2) & 3u, src, dst);
			ivec3 cd = blend_sel((bl >> 6) & 3u, src, dst);
			uint cs = (bl >> 4) & 3u;
			int alpha = cs == 0u ? src.a : cs == 1u ? dst.a : int(S.fix);
			src.rgb = (((ca - cb) * alpha) >> 7) + cd;
		}
		src.rgb = (fl & F_COLCLAMP) != 0u ? clamp(src.rgb, 0, 255) : (src.rgb & 0xff);
		if ((fl & F_FBA) != 0u) src.a |= 0x80;
		if (!write_alpha) src.a = dst.a;

		uint o, msk = S.fbmsk;
		if (fb32) {
			o = uint(src.r) | uint(src.g) << 8 | uint(src.b) << 16 | uint(src.a & 0xff) << 24;
		} else {
			o = uint(src.r >> 3) | uint(src.g >> 3) << 5 | uint(src.b >> 3) << 10 | ((src.a & 0x80) != 0 ? 0x8000u : 0u);
			dst_raw &= 0xffffu;
			msk = (msk >> 3) & 0x1fu | (msk >> 6) & 0x3e0u | (msk >> 9) & 0x7c00u | (msk >> 16) & 0x8000u;
		}
		write_raw(fpsm, S.fbp, S.fbw, px, py, (o & ~msk) | (dst_raw & msk));
	}
	endInvocationInterlockARB();
}
