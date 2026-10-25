#version 460
// Primitive vertices, pulled from the frame's vertex ring. GS pixel p maps
// to host pixel centre p * scale + 0.5, so layer 0 samples the integer GS
// positions the hardware does.
#include "common.glsl"
#include "draw.glsl"

layout(location = 0) noperspective out vec4 o_col;
layout(location = 1) noperspective out vec3 o_stq;
layout(location = 2) noperspective out float o_fog;
layout(location = 3) noperspective out float o_z;
layout(location = 4) flat out uint o_zi;
layout(location = 5) flat out uint o_state;

void main() {
	Vert v = pc.verts.v[gl_VertexIndex];
	float s = float(pc.scale);
	vec2 h = vec2(v.x, v.y) * s + 0.5;
	gl_Position = vec4(h / (2048.0 * s) * 2.0 - 1.0, 0.0, 1.0);
	o_col = v.c;
	o_stq = vec3(v.s, v.t, v.q);
	o_fog = v.fog;
	o_z = v.zf;
	o_zi = v.zi;
	o_state = v.state;
}
