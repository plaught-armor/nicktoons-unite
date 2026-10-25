// Shared by the primitive shaders: vertex and drawing-state layouts (Hw_Vert
// and Hw_State in ../hw.odin) and the push constants.

struct Vert {
	float x, y, zf; // window-relative GS pixels; z as a float for interpolation
	uint zi;        // z exactly, used when the primitive's z is constant
	vec4 c;         // r, g, b, a in 0..255
	float s, t, q;  // STQ, or U, V (texels) when FST
	float fog;
	uint state;     // Hw_State index; bit 31: constant z
	uint pad0, pad1, pad2;
};

struct State {
	uint fbp, fbw, fpsm, fbmsk;
	uint zbp, zpsm, flags;
	uint sx0, sx1, sy0, sy1;
	uint atst, aref, afail, ztst;
	uint blend; // A | B << 2 | C << 4 | D << 6
	uint fix, fogcol;
	uint tbp, tbw, tpsm, tw, th, tfx, cpsm, csa;
	uint wrap;  // WMS | WMT << 2
	uint umm, vmm; // MINU | MAXU << 16, MINV | MAXV << 16
	uint ta;    // TA0 | TA1 << 8
	uint clut;  // word offset of this primitive's CLUT copy
	uint mip;   // LCM | MXL << 1 | MMIN << 4 | L << 7 | K << 16
	uint mtb[6]; // levels 1..6: TBP | TBW << 16
	uint pad0, pad1;
};

#define F_TME (1u << 0)
#define F_FGE (1u << 1)
#define F_ABE (1u << 2)
#define F_FST (1u << 3)
#define F_ATE (1u << 4)
#define F_DATE (1u << 5)
#define F_DATM (1u << 6)
#define F_ZTE (1u << 7)
#define F_ZMSK (1u << 8)
#define F_PABE (1u << 9)
#define F_FBA (1u << 10)
#define F_COLCLAMP (1u << 11)
#define F_TCC (1u << 12)
#define F_BILINEAR (1u << 13)
#define F_AEM (1u << 14)

layout(buffer_reference, std430, buffer_reference_align = 16) buffer Verts {
	Vert v[];
};
layout(buffer_reference, std430, buffer_reference_align = 4) buffer States {
	State s[];
};

layout(push_constant) uniform PC {
	Words vram;
	States states;
	Words cluts;
	Verts verts;
	uint scale;
} pc;
