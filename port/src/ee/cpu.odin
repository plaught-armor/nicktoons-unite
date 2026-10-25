// Emotion Engine CPU state and the call dispatcher shared by recompiled code.
//
// Recompiled functions are Odin procs that read and write `cpu` directly.
// MIPS calls become host calls; `call` finds the proc for an address
// through a table indexed by word offset into .text.
package ee

import "core:fmt"
import "core:os"

// A general-purpose register: 128 bits on the R5900. Non-MMI instructions
// only touch the low doubleword.
Gpr :: struct #raw_union {
	q:  u128,
	d:  [2]u64,
	sd: [2]i64,
	w:  [4]u32,
	sw: [4]i32,
	h:  [8]u16,
	sh: [8]i16,
	b:  [16]u8,
	sb: [16]i8,
	// SIMD views for MMI instructions the recompiler emits inline
	vw: #simd[4]u32,
	vh: #simd[8]i16,
	vuh: #simd[8]u16,
	vb: #simd[16]u8,
}

Fpr :: struct #raw_union {
	f: f32,
	u: u32,
	i: i32,
}

Cpu :: struct {
	r:      [32]Gpr,
	hi, lo: Gpr, // d[1] are HI1/LO1 of the second multiply pipe
	sa:     u32, // shift amount for QFSRV, in bits
	f:      [32]Fpr,
	acc:    Fpr,
	fcr31:  u32,
	cop0:   [32]u32,
	cycles: u64,
}

cpu: Cpu
next_event: u64

FCR31_C :: 0x800000

sx32 :: #force_inline proc "contextless" (v: u32) -> u64 {
	return u64(i64(i32(v)))
}

// ---------------------------------------------------------------- dispatch

Func_Proc :: #type proc()

TEXT_LO :: 0x00100000
TEXT_HI :: 0x00400000

@(private)
fn_table: [(TEXT_HI - TEXT_LO) / 4]Func_Proc

@(private)
reported: map[u32]bool

register :: proc(addr: u32, fn: Func_Proc) {
	fn_table[(addr - TEXT_LO) >> 2] = fn
}

lookup :: proc(addr: u32) -> Func_Proc {
	if addr < TEXT_LO || addr >= TEXT_HI || addr & 3 != 0 {
		return nil
	}
	return fn_table[(addr - TEXT_LO) >> 2]
}

call :: proc(addr: u32) {
	if fn := lookup(addr); fn != nil {
		fn()
		return
	}
	if hle_call(addr) {
		return
	}
	fatal("call to unknown function %08x (ra %08x)", addr, u32(cpu.r[31].d[0]))
}

// A jump inside a function to an address that is no label of it. Discovery
// splits a function after a mid-body `jr $ra`, so switch cases past it land
// in what was recompiled as another function: continue there as a tail call
// (the guest stack frame is shared, and its `jr $ra` returns for us).
jump_unknown :: proc(fn, pc: u32) {
	if f := lookup(pc); f != nil {
		f()
		return
	}
	fatal("function %08x: jump to %08x which is not a label", fn, pc)
}

bad_insn :: proc(pc, w: u32) {
	fatal("invalid instruction %08x at %08x", w, pc)
}

brk :: proc(pc, w: u32) {
	fatal("break %d at %08x", (w >> 6) & 0xfffff, pc)
}

fatal :: proc(format: string, args: ..any) -> ! {
	fmt.eprint("ee: ")
	fmt.eprintfln(format, ..args)
	dump_regs()
	os.exit(1)
}

GPR_NAMES := [32]string {
	"zero", "at", "v0", "v1", "a0", "a1", "a2", "a3", "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7",
	"s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "t8", "t9", "k0", "k1", "gp", "sp", "fp", "ra",
}

dump_regs :: proc() {
	for n in 0 ..< 32 {
		fmt.eprintf("%4s %016x%s", GPR_NAMES[n], cpu.r[n].d[0], n % 4 == 3 ? "\n" : "  ")
	}
	fmt.eprintfln("  hi %016x    lo %016x  cycles %d", cpu.hi.d[0], cpu.lo.d[0], cpu.cycles)
}

// Emulated state, saved and restored by snapshots (snap.odin).
@(private)
cpu_snap :: proc() {
	snap_add(&cpu)
	snap_add(&next_event)
	snap_add(&reported)
}
