// Multiply/divide and FPU helpers called from recompiled code.
package ee

import "core:math"

// R5900 MULT/MULTU also write the low word of the product to rd.
// `unit` 1 is the second pipe (MULT1), writing HI1/LO1.
mult :: proc(rd: u8, a, b: u32, unit: int) {
	p := i64(i32(a)) * i64(i32(b))
	cpu.lo.d[unit] = sx32(u32(p))
	cpu.hi.d[unit] = sx32(u32(p >> 32))
	if rd != 0 {cpu.r[rd].d[0] = cpu.lo.d[unit]}
}

multu :: proc(rd: u8, a, b: u32, unit: int) {
	p := u64(a) * u64(b)
	cpu.lo.d[unit] = sx32(u32(p))
	cpu.hi.d[unit] = sx32(u32(p >> 32))
	if rd != 0 {cpu.r[rd].d[0] = cpu.lo.d[unit]}
}

madd :: proc(rd: u8, a, b: u32, unit: int, signed: bool) {
	acc := (cpu.hi.d[unit] << 32) | (cpu.lo.d[unit] & 0xffffffff)
	p := signed ? u64(i64(i32(a)) * i64(i32(b))) : u64(a) * u64(b)
	s := acc + p
	cpu.lo.d[unit] = sx32(u32(s))
	cpu.hi.d[unit] = sx32(u32(s >> 32))
	if rd != 0 {cpu.r[rd].d[0] = cpu.lo.d[unit]}
}

div :: proc(a, b: u32, unit: int) {
	n, d := i32(a), i32(b)
	switch {
	case d == 0:
		cpu.lo.d[unit] = n < 0 ? 1 : ~u64(0)
		cpu.hi.d[unit] = sx32(a)
	case n == min(i32) && d == -1:
		cpu.lo.d[unit] = sx32(0x80000000)
		cpu.hi.d[unit] = 0
	case:
		cpu.lo.d[unit] = sx32(u32(n / d))
		cpu.hi.d[unit] = sx32(u32(n % d))
	}
}

divu :: proc(a, b: u32, unit: int) {
	if b == 0 {
		cpu.lo.d[unit] = ~u64(0)
		cpu.hi.d[unit] = sx32(a)
		return
	}
	cpu.lo.d[unit] = sx32(a / b)
	cpu.hi.d[unit] = sx32(a % b)
}

// The EE FPU has no infinities, NaNs or denormals: overflow saturates to
// the largest magnitude and denormals flush to zero.
fclamp :: #force_inline proc(x: f32) -> f32 {
	u := transmute(u32)x
	switch u & 0x7f800000 {
	case 0x7f800000: return transmute(f32)((u & 0x80000000) | 0x7f7fffff)
	case 0:          return transmute(f32)(u & 0x80000000)
	}
	return x
}

fdiv :: proc(a, b: f32) -> f32 {
	if transmute(u32)b & 0x7f800000 == 0 {
		sign := (transmute(u32)a ~ transmute(u32)b) & 0x80000000
		return transmute(f32)(sign | 0x7f7fffff)
	}
	return fclamp(a / b)
}

fsqrt :: proc(x: f32) -> f32 {
	return math.sqrt(abs(x))
}

frsqrt :: proc(a, b: f32) -> f32 {
	s := math.sqrt(abs(b))
	if transmute(u32)s & 0x7f800000 == 0 {
		return transmute(f32)((transmute(u32)a & 0x80000000) | 0x7f7fffff)
	}
	return fclamp(a / s)
}

fcond :: #force_inline proc(t: bool) {
	if t {cpu.fcr31 |= FCR31_C} else {cpu.fcr31 &~= FCR31_C}
}

cvt_w :: proc(x: f32) -> i32 {
	u := transmute(u32)x
	if u & 0x7f800000 >= 0x4f000000 { // |x| >= 2^31
		return u & 0x80000000 != 0 ? min(i32) : max(i32)
	}
	return i32(x)
}
