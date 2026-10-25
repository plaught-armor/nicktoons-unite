// Coroutine switching on Linux x86-64: a hand-written stack switch, on
// stacks mapped with the raw syscall.
//
// glibc's swapcontext also saves the signal mask with a syscall and the
// whole FP environment on every switch; neither is needed here. Odin can
// only assemble foreign code with nasm, so the switch ships as machine code
// (the listing beside CO_CODE) copied into an executable page on first use.
package ee

import "base:runtime"
import "core:sys/linux"

@(private)
Co_Context :: struct {
	sp:    rawptr, // saved stack pointer while suspended
	stack: rawptr,
}

// A suspended stack holds, from its saved pointer upward: MXCSR and the x87
// control word (8 bytes), r15, r14, r13, r12, rbx, rbp and the return
// address.
@(private, rodata)
CO_CODE := [?]u8 {
	// co_switch_stack(save: ^rawptr, sp: rawptr): suspend the running stack,
	// storing its pointer in save^, and resume the one suspended at sp.
	0x55,                   // push rbp
	0x53,                   // push rbx
	0x41, 0x54,             // push r12
	0x41, 0x55,             // push r13
	0x41, 0x56,             // push r14
	0x41, 0x57,             // push r15
	0x48, 0x83, 0xec, 0x08, // sub rsp, 8
	0x0f, 0xae, 0x1c, 0x24, // stmxcsr [rsp]
	0xd9, 0x7c, 0x24, 0x04, // fnstcw [rsp + 4]
	0x48, 0x89, 0x27,       // mov [rdi], rsp
	0x48, 0x89, 0xf4,       // mov rsp, rsi
	0x0f, 0xae, 0x14, 0x24, // ldmxcsr [rsp]
	0xd9, 0x6c, 0x24, 0x04, // fldcw [rsp + 4]
	0x48, 0x83, 0xc4, 0x08, // add rsp, 8
	0x41, 0x5f,             // pop r15
	0x41, 0x5e,             // pop r14
	0x41, 0x5d,             // pop r13
	0x41, 0x5c,             // pop r12
	0x5b,                   // pop rbx
	0x5d,                   // pop rbp
	0xc3,                   // ret
	// co_trampoline: a new stack's first resume lands here with the entry
	// procedure in rbx and its argument in r12. The entry never returns.
	0x4c, 0x89, 0xe7,       // mov rdi, r12
	0xff, 0xd3,             // call rbx
	0x0f, 0x0b,             // ud2
}
@(private)
CO_TRAMPOLINE :: 51

@(private)
co_switch_stack: proc "c" (save: ^rawptr, sp: rawptr)
@(private)
co_trampoline: rawptr

@(private)
co_load_code :: proc() {
	page, err := linux.mmap(0, 4096, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	assert(err == .NONE, "coroutine code page")
	copy(([^]u8)(page)[:len(CO_CODE)], CO_CODE[:])
	assert(linux.mprotect(page, 4096, {.READ, .EXEC}) == .NONE, "coroutine code page")
	co_switch_stack = auto_cast page
	co_trampoline = rawptr(uintptr(page) + CO_TRAMPOLINE)
}

@(private)
co_body :: proc "c" (co: ^Coroutine) {
	context = runtime.default_context()
	context.allocator = emu_allocator()
	co_run(co)
}

// Stacks are mapped on first use and never unmapped, so a snapshot's stack
// pointers stay valid; co_stack_owner (emulated state) says which are in use.
@(private)
CO_POOL :: 64
@(private)
co_stacks: [CO_POOL]rawptr
@(private)
co_stack_owner: [CO_POOL]^Coroutine

@(private)
co_pool_snap :: proc() {
	snap_add(&co_stack_owner)
}

// Give `co` its stack, laid out as co_switch_stack leaves a suspended one,
// returning into co_trampoline with co_body in rbx and `co` in r12.
@(private)
co_start :: proc(co: ^Coroutine) {
	if co_switch_stack == nil {co_load_code()}
	slot := -1
	for o, i in co_stack_owner {
		if o == nil {slot = i; break}
	}
	assert(slot >= 0, "coroutine stacks exhausted")
	if co_stacks[slot] == nil {
		stack, err := linux.mmap(0, CO_STACK, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
		assert(err == .NONE, "coroutine stack")
		co_stacks[slot] = stack
	}
	co_stack_owner[slot] = co
	stack := co_stacks[slot]
	co.ctx.stack = stack
	frame := ([^]uintptr)(uintptr(stack) + CO_STACK - 8 * size_of(uintptr))[:8]
	frame[0] = 0x037f << 32 | 0x1f80 // x87 control word, MXCSR: the defaults
	frame[1] = 0 // r15
	frame[2] = 0 // r14
	frame[3] = 0 // r13
	frame[4] = uintptr(co) // r12
	frame[5] = uintptr(rawptr(co_body)) // rbx
	frame[6] = 0 // rbp
	frame[7] = uintptr(co_trampoline)
	co.ctx.sp = &frame[0]
}

@(private)
co_swap :: proc(from, to: ^Coroutine) {
	co_switch_stack(&from.ctx.sp, to.ctx.sp)
}

@(private)
co_free :: proc(co: ^Coroutine) {
	for &o in co_stack_owner {
		if o == co {o = nil}
	}
}
