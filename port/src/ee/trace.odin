// Runtime probes, configured from the environment so a debugging session
// needs no rebuild:
//   NT_TRACE=3a0110,3a01b0   log entry to these recompiled functions
//   NT_TRACE_SYS=43,44       log these syscalls (interrupt variants too)
//   NT_WATCH=883580[:len]    log guest stores into [addr, addr+len) (len 4)
//   NT_TRACE_FRAMES=lo-hi    only during these kernel frames (default all)
// Each line carries a0..a3, ra, thread, frame, cycle and the code addresses
// found on the guest stack, which approximates the call chain.
package ee

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// Host time per subsystem in TSC ticks, inclusive of nested work (VIF runs
// VU1 microprograms, which kick GIF packets). NT_STATS prints the shares.
Prof :: enum {VU1, VIF, GIF, IPU, MIX}
prof: [Prof]u64

prof_start :: #force_inline proc() -> u64 {return u64(intrinsics.read_cycle_counter())}
prof_end :: #force_inline proc(p: Prof, t: u64) {prof[p] += u64(intrinsics.read_cycle_counter()) - t}

trace_on: bool // any NT_TRACE function; checked at every recompiled entry
@(private = "file")
trace_fns: map[u32]bool
trace_sys_on: bool
@(private = "file")
trace_sys: map[i32]bool
@(private = "file")
trace_lo, trace_hi: u64 = 0, max(u64)
watch_lo, watch_len: u32 // watch_len 0: no watch

trace_init :: proc() {
	if v, ok := os.lookup_env("NT_TRACE", context.temp_allocator); ok {
		for s in strings.split(v, ",", context.temp_allocator) {
			if a, ok2 := strconv.parse_u64_of_base(strings.trim_space(s), 16); ok2 {trace_fns[u32(a)] = true}
		}
		trace_on = len(trace_fns) > 0
	}
	if v, ok := os.lookup_env("NT_TRACE_SYS", context.temp_allocator); ok {
		for s in strings.split(v, ",", context.temp_allocator) {
			if n, ok2 := strconv.parse_u64_of_base(strings.trim_space(s), 16); ok2 {trace_sys[i32(n)] = true}
		}
		trace_sys_on = len(trace_sys) > 0
	}
	if v, ok := os.lookup_env("NT_WATCH", context.temp_allocator); ok {
		parts := strings.split(v, ":", context.temp_allocator)
		if a, ok2 := strconv.parse_u64_of_base(parts[0], 16); ok2 {
			watch_lo, watch_len = u32(a) & 0x0fffffff, 4
			if len(parts) > 1 {
				if n, ok3 := strconv.parse_u64_of_base(parts[1], 16); ok3 {watch_len = u32(n)}
			}
			fast_lim = 0
		}
	}
	if v, ok := os.lookup_env("NT_TRACE_FRAMES", context.temp_allocator); ok {
		parts := strings.split(v, "-", context.temp_allocator)
		trace_lo, _ = strconv.parse_u64(parts[0])
		if len(parts) > 1 {trace_hi, _ = strconv.parse_u64(parts[1])}
	}
}

trace_call :: proc(addr: u32) {
	if !trace_fns[addr] || k.frame < trace_lo || k.frame > trace_hi {return}
	fmt.eprintf("trace f_%08x a0 %x a1 %x a2 %x a3 %x", addr,
		u32(cpu.r[4].d[0]), u32(cpu.r[5].d[0]), u32(cpu.r[6].d[0]), u32(cpu.r[7].d[0]))
	trace_tail()
}

trace_syscall :: proc(n: i32) {
	if !trace_sys[abs(n)] || k.frame < trace_lo || k.frame > trace_hi {return}
	fmt.eprintf("syscall %x a0 %x a1 %x a2 %x a3 %x", n,
		u32(cpu.r[4].d[0]), u32(cpu.r[5].d[0]), u32(cpu.r[6].d[0]), u32(cpu.r[7].d[0]))
	trace_tail()
}

@(private)
trace_store :: proc(a: u32, v: u128) {
	if k.frame < trace_lo || k.frame > trace_hi {return}
	fmt.eprintf("watch %08x = %x", a, v)
	trace_tail()
}

@(private = "file")
trace_tail :: proc() {
	cur := k.current != nil ? k.current.id : -1
	fmt.eprintf(" ra %x thread %d frame %d cyc %d stack", u32(cpu.r[31].d[0]), cur, k.frame, cpu.cycles)
	sp := u32(cpu.r[29].d[0]) & (RAM_SIZE - 1) &~ 3
	for o: u32 = 0; o < 0x200 && sp + o < RAM_SIZE; o += 4 {
		w := (^u32)(&ram[sp + o])^
		if w >= TEXT_LO && w < TEXT_HI && w & 3 == 0 {fmt.eprintf(" %x", w)}
	}
	fmt.eprintln()
}
