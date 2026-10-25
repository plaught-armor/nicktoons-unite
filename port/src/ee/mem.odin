// EE address space: 32MB main RAM with its uncached mirrors, the 16KB
// scratchpad, VU memory, and the hardware registers (hw.odin).
//
// RAM accesses below 32MB take the inlined fast path; everything else goes
// through `slow_addr` or the register handlers.
package ee

import "base:intrinsics"
import "ps:core"

RAM_SIZE :: 32 << 20
SPR_BASE :: 0x70000000
SPR_SIZE :: 16 << 10

ram: []u8
spr: [SPR_SIZE]u8

// Base of `ram` and the bound below which an address is plain RAM, for the
// fast path each recompiled file inlines (FAST_HELPERS in tools/recomp). The
// bound is 0 while NT_WATCH is active so every access reaches the watch check
// here.
ram_base: [^]u8
fast_lim: u32

mem_init :: proc() {
	ram = core.snap_area(RAM_SIZE)
	ram_base = raw_data(ram)
	fast_lim = RAM_SIZE
}

// Host pointer for a guest address that is plain memory, or nil for a
// register.
slow_addr :: proc(a: u32) -> rawptr {
	switch a >> 28 {
	case 0x0, 0x2, 0x3, 0x8, 0xa:
		p := a & 0x0fffffff
		if p < RAM_SIZE {return &ram[p]}
	case 0x7:
		if a - SPR_BASE < SPR_SIZE {return &spr[a - SPR_BASE]}
	case 0x1:
		return vu_mem_addr(a)
	}
	return nil
}

@(private)
load :: #force_inline proc(a: u32, $T: typeid) -> T {
	if a < RAM_SIZE {
		return intrinsics.unaligned_load((^T)(&ram[a]))
	}
	if p := slow_addr(a); p != nil {
		return intrinsics.unaligned_load((^T)(p))
	}
	return T(hw_read(a, size_of(T)))
}

@(private)
store :: #force_inline proc(a: u32, v: $T) {
	if (a & 0x0fffffff) - watch_lo < watch_len {trace_store(a, u128(v))}
	if a < RAM_SIZE {
		intrinsics.unaligned_store((^T)(&ram[a]), v)
		return
	}
	if p := slow_addr(a); p != nil {
		intrinsics.unaligned_store((^T)(p), v)
		return
	}
	hw_write(a, u64(v), size_of(T))
}

rd8 :: #force_inline proc(a: u32) -> u8 {return load(a, u8)}
rd16 :: #force_inline proc(a: u32) -> u16 {return load(a, u16)}
rd32 :: #force_inline proc(a: u32) -> u32 {return load(a, u32)}
rd64 :: #force_inline proc(a: u32) -> u64 {return load(a, u64)}
wr8 :: #force_inline proc(a: u32, v: u8) {store(a, v)}
wr16 :: #force_inline proc(a: u32, v: u16) {store(a, v)}
wr32 :: #force_inline proc(a: u32, v: u32) {store(a, v)}
wr64 :: #force_inline proc(a: u32, v: u64) {store(a, v)}

rd128 :: proc(a: u32) -> u128 {
	a := a &~ 15
	if a < RAM_SIZE {return (^u128)(&ram[a])^}
	if p := slow_addr(a); p != nil {return intrinsics.unaligned_load((^u128)(p))}
	return hw_read128(a)
}

wr128 :: proc(a: u32, v: u128) {
	a := a &~ 15
	if watch_len != 0 && (a & 0x0fffffff) + 16 > watch_lo && (a & 0x0fffffff) < watch_lo + watch_len {trace_store(a, v)}
	if a < RAM_SIZE {
		(^u128)(&ram[a])^ = v
		return
	}
	if p := slow_addr(a); p != nil {
		intrinsics.unaligned_store((^u128)(p), v)
		return
	}
	hw_write128(a, v)
}

// Host slice over guest RAM, for kernel and DMA code.
ram_slice :: proc(a: u32, n: u32, loc := #caller_location) -> []u8 {
	p := a & 0x0fffffff
	if a >> 28 == 7 {
		return spr[a - SPR_BASE:][:n]
	}
	if p + n > RAM_SIZE {fatal("ram_slice %08x+%x out of range (%v)", a, n, loc)}
	return ram[p:][:n]
}

read_cstring :: proc(a: u32) -> string {
	if a == 0 {return ""}
	p := a & 0x0fffffff
	n := p
	for n < RAM_SIZE && ram[n] != 0 {n += 1}
	return string(ram[p:n])
}

// ------------------------------------------------- unaligned loads/stores

LWL :: proc(a: u32, rt: u64) -> u64 {
	s := a & 3
	m := rd32(a &~ 3)
	return sx32((u32(rt) & (0x00ffffff >> (s * 8))) | (m << (24 - s * 8)))
}

LWR :: proc(a: u32, rt: u64) -> u64 {
	s := a & 3
	m := rd32(a &~ 3)
	if s == 0 {return sx32(m)}
	v := (u32(rt) & (0xffffffff << (32 - s * 8))) | (m >> (s * 8))
	return (rt & 0xffffffff_00000000) | u64(v)
}

SWL :: proc(a: u32, rt: u64) {
	s := a & 3
	m := rd32(a &~ 3)
	mask := s == 3 ? 0 : u32(0xffffff00) << (s * 8)
	wr32(a &~ 3, (m & mask) | (u32(rt) >> (24 - s * 8)))
}

SWR :: proc(a: u32, rt: u64) {
	s := a & 3
	m := rd32(a &~ 3)
	mask := s == 0 ? 0 : u32(0xffffffff) >> (32 - s * 8)
	wr32(a &~ 3, (m & mask) | (u32(rt) << (s * 8)))
}

LDL :: proc(a: u32, rt: u64) -> u64 {
	s := u64(a & 7)
	m := rd64(a &~ 7)
	return (rt & (0x00ffffff_ffffffff >> (s * 8))) | (m << (56 - s * 8))
}

LDR :: proc(a: u32, rt: u64) -> u64 {
	s := u64(a & 7)
	m := rd64(a &~ 7)
	mask := s == 0 ? 0 : u64(0xffffffff_ffffffff) << (64 - s * 8)
	return (rt & mask) | (m >> (s * 8))
}

SDL :: proc(a: u32, rt: u64) {
	s := u64(a & 7)
	m := rd64(a &~ 7)
	mask := s == 7 ? 0 : u64(0xffffffff_ffffff00) << (s * 8)
	wr64(a &~ 7, (m & mask) | (rt >> (56 - s * 8)))
}

SDR :: proc(a: u32, rt: u64) {
	s := u64(a & 7)
	m := rd64(a &~ 7)
	mask := s == 0 ? 0 : u64(0xffffffff_ffffffff) >> (64 - s * 8)
	wr64(a &~ 7, (m & mask) | (rt << (s * 8)))
}

// Emulated state, saved and restored by snapshots (snap.odin).
@(private)
mem_snap :: proc() {
	core.snap_add(&spr)
}
