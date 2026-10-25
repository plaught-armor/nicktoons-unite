// High-level emulation of the EE kernel: syscalls, threads, semaphores,
// interrupt handlers, alarms and the event schedule that drives vblank.
//
// Each kernel thread runs on its own coroutine; switching threads saves the
// CPU registers into the thread and loads the next one's. Interrupt
// handlers are guest functions called from `run_events` on a kernel stack
// below the program (the real kernel owns 0x00000000-0x0007ffff too).
package ee

import "core:fmt"
import "core:os"
import "ps:core"

EE_CLOCK :: 294_912_000
CYCLES_PER_FRAME :: EE_CLOCK * 1001 / 60000 // NTSC 59.94 Hz
CYCLES_PER_LINE :: CYCLES_PER_FRAME / 262

INTR_STACK_TOP :: 0x00080000

// The syscall table lives in kernel memory, where programs find it by
// searching for handlers they installed. Built-in entries hold fake kernel
// addresses; anything below 0x80000000 is a program-installed handler.
SYSCALL_TABLE :: 0x00010000

Thread_Status :: enum u32 {
	Run      = 1,
	Ready    = 2,
	Wait     = 4,
	Suspend  = 8,
	Wait_Suspend = 12,
	Dormant  = 16,
}

Wait_Kind :: enum u32 {None, Sleep, Sema}

Thread :: struct {
	id:         i32,
	status:     Thread_Status,
	entry:      u32,
	stack:      u32,
	stack_size: u32,
	gp:         u32,
	init_prio:  i32,
	prio:       i32,
	attr, option: u32,
	wait:       Wait_Kind,
	wait_id:    i32,
	wait_result: i32,
	wakeups:    i32,
	seq:        u64, // order of becoming ready, for FIFO within a priority
	regs:       Cpu,
	co:         ^core.Coroutine,
}

Sema :: struct {
	id:      i32,
	count:   i32,
	max:     i32,
	init:    i32,
	attr:    u32,
	option:  u32,
	waiters: i32,
}

Handler :: struct {
	id:      i32,
	cause:   u32,
	fn, arg: u32,
	gp:      u32,
	enabled: bool,
}

Alarm :: struct {
	id:       i32,
	deadline: u64,
	time:     u32,
	fn, arg:  u32,
	gp:       u32,
}

@(private)
k: struct {
	threads:      [256]^Thread,
	thread_end:   int, // past the highest thread id ever used; loops stop here
	current:      ^Thread,
	semas:        [256]^Sema,
	intc:         [dynamic]Handler,
	dmac:         [dynamic]Handler,
	alarms:       [dynamic]Alarm,
	next_handler: i32,
	next_alarm:   i32,
	seq:          u64,
	in_interrupt: bool,
	heap_end:     u32,
	osd_config:   u32, // English, 4:3, no spdif
	debug:        int, // NT_DEBUG=1: dump threads every two seconds; 2: also trace syscalls; 3: trace GS register writes
	vblank_start: u64, // next vblank start
	vblank_end:   u64,
	frame:        u64,
}

KE_OK :: 0
KE_ERROR :: -1
KE_RELEASE_WAIT :: -418
KE_UNKNOWN_SEMID :: -408
KE_SEMA_ZERO :: -419

kernel_init :: proc() {
	t := new(Thread)
	t.id = 1
	t.status = .Run // its coroutine is made by run
	k.threads[1] = t
	k.thread_end = 2
	k.current = t
	k.next_handler = 1
	k.osd_config = 1 << 16
	switch os.get_env("NT_DEBUG", context.temp_allocator) {
	case "": k.debug = 0
	case "2": k.debug = 2
	case "3": k.debug = 3
	case: k.debug = 1
	}
	trace_init()
	k.next_alarm = 1
	// Libraries test IE to tell thread context from interrupt context.
	cpu.cop0[12] = STATUS_USER
	for n in u32(0) ..< 256 {wr32(SYSCALL_TABLE + n * 4, 0x80001000 + n * 8)}
	k.vblank_start = CYCLES_PER_FRAME - 22 * CYCLES_PER_LINE
	k.vblank_end = CYCLES_PER_FRAME
	update_next_event()
}

// ------------------------------------------------------------- syscalls

syscall :: proc(pc: u32) {
	c := &cpu
	n := i32(i16(c.r[3].d[0]))
	a0 := u32(c.r[4].d[0])
	a1 := u32(c.r[5].d[0])
	a2 := u32(c.r[6].d[0])
	a3 := u32(c.r[7].d[0])
	t0 := u32(c.r[8].d[0])
	ret: i64 = 0
	if trace_sys_on {trace_syscall(n)}
	if k.debug == 2 {
		fmt.eprintfln("syscall %x(%08x, %08x, %08x, %08x) thread %d pc %08x ra %08x", n, a0, a1, a2, a3, k.current.id, pc, u32(c.r[31].d[0]))
	}
	// Syscalls the program installed itself (SetSyscall, or a direct write
	// to the table) run its own code.
	if fn := rd32(SYSCALL_TABLE + u32(abs(n) & 0xff) * 4); fn < 0x80000000 {
		call(fn)
		return
	}
	switch abs(n) {
	case 0x02: // SetGsCrt(interlace, mode, field)
		fmt.eprintfln("kernel: SetGsCrt(%d, %d, %d)", a0, a1, a2)
	case 0x04: // Exit
		fatal("program exited with %d", i32(a0))
	case 0x10: ret = add_handler(&k.intc, a0, a1, a3)
	case 0x11: ret = remove_handler(&k.intc, a0, i32(a1))
	case 0x12: ret = add_handler(&k.dmac, a0, a1, a3)
	case 0x13: ret = remove_handler(&k.dmac, a0, i32(a1))
	case 0x14, 0x1a: // EnableIntc
		if intc_mask & (1 << a0) == 0 {intc_mask |= 1 << a0; ret = 1}
	case 0x15, 0x1b: // DisableIntc
		if intc_mask & (1 << a0) != 0 {intc_mask &~= 1 << a0; ret = 1}
	case 0x16, 0x1c: // EnableDmac
		if dmac_stat & (0x10000 << a0) == 0 {dmac_stat |= 0x10000 << a0; ret = 1}
	case 0x17, 0x1d: // DisableDmac
		if dmac_stat & (0x10000 << a0) != 0 {dmac_stat &~= 0x10000 << a0; ret = 1}
	// 0xfc-0xff: SetAlarm, ReleaseAlarm, iSetAlarm, iReleaseAlarm as
	// re-exported by Sony's kernel patch (this game's libkernel wrappers at
	// 0x33d4a0/0x33d4b0 use 0xfc/0xfd; the i-variants arrive negated).
	case 0x18, 0x1e, 0xfc, 0xfe: ret = set_alarm(a0, a1, a2)
	case 0x19, 0x1f, 0xfd, 0xff: ret = release_alarm(i32(a0))
	case 0x20: ret = create_thread(a0)
	case 0x21: ret = delete_thread(i32(a0))
	case 0x22: ret = start_thread(i32(a0), a1)
	case 0x23: exit_thread()
	case 0x24: exit_thread()
	case 0x25, 0x26: ret = terminate_thread(i32(a0))
	case 0x27, 0x28: // Disable/EnableDispatchThread
	case 0x29, 0x2a: ret = change_priority(i32(a0), i32(a1))
	case 0x2b, 0x2c: ret = rotate_ready_queue(i32(a0))
	case 0x2d, 0x2e: ret = release_wait(i32(a0))
	case 0x2f: ret = i64(k.current.id)
	case 0x30, 0x31: ret = refer_thread(i32(a0), a1)
	case 0x32: ret = sleep_thread()
	case 0x33, 0x34: ret = wakeup_thread(i32(a0))
	case 0x35, 0x36: // CancelWakeupThread
		if t := thread(i32(a0)); t != nil {ret = i64(t.wakeups); t.wakeups = 0}
	case 0x37, 0x38: ret = suspend_thread(i32(a0))
	case 0x39, 0x3a: ret = resume_thread(i32(a0))
	case 0x3c: ret = i64(setup_thread(a0, a1, a2, a3))
	case 0x3d: // SetupHeap(start, size)
		k.heap_end = a1 == 0xffffffff ? u32(c.r[29].d[0]) - 0x10000 : a0 + a1
		ret = i64(k.heap_end)
	case 0x3e: ret = i64(k.heap_end) // EndOfHeap
	case 0x40: ret = create_sema(a0)
	case 0x41: ret = delete_sema(i32(a0))
	case 0x42, 0x43: ret = signal_sema(i32(a0))
	case 0x44: ret = wait_sema(i32(a0))
	case 0x45, 0x46: ret = poll_sema(i32(a0))
	case 0x47, 0x48: ret = refer_sema(i32(a0), a1)
	case 0x4a: k.osd_config = rd32(a0) // SetOsdConfigParam(*param)
	case 0x4b: wr32(a0, k.osd_config) // GetOsdConfigParam(*param)
	case 0x5c ..= 0x5f: // Enable/Disable Intc/Dmac handler(cid, id)
		list := abs(n) <= 0x5d ? &k.intc : &k.dmac
		for &h in list {if h.id == i32(a0) || h.id == i32(a1) {h.enabled = abs(n) & 1 == 0}}
	case 0x5b: ret = i64(rd32(SYSCALL_TABLE + (a0 & 0xff) * 4)) // GetEntryAddress
	case 0x63, 0x67: ret = i64(cpu.cop0[a0 & 31]) // GetCop0, iGetCop0
	case 0x64, 0x68: // FlushCache
	case 0x6b: // SifStopDma: transfers complete instantly
	case 0x70: ret = i64(gs_imr) // GsGetIMR
	case 0x71: // GsPutIMR
		ret = i64(gs_imr)
		gs_imr = a0
	case 0x73: // SetVSyncFlag
	case 0x74: // SetSyscall(index, fn)
		wr32(SYSCALL_TABLE + (a0 & 0xff) * 4, a1)
	case 0x76: ret = sif_dma_stat(i32(a0))
	case 0x77: ret = i64(sif_set_dma(a0, a1))
	case 0x78: // SifSetDChain
	case 0x79: sif_reg_set(a0, a1)
	case 0x7a: ret = i64(sif_reg_get(a0))
	case 0x7c: ret = -1 // Deci2Call: no debugger attached
	case 0x7e: ret = 0 // MachineType
	case 0x7f: ret = RAM_SIZE // GetMemorySize
	case:
		fmt.eprintfln("kernel: unhandled syscall %d (a0 %08x a1 %08x) at %08x ra %08x",
			n, a0, a1, pc, u32(c.r[31].d[0]))
	}
	_ = t0
	c.r[2].d[0] = u64(ret)
}

// -------------------------------------------------------------- threads

thread :: proc(id: i32) -> ^Thread {
	if id == 0 {return k.current}
	if id < 0 || id >= len(k.threads) {return nil}
	return k.threads[id]
}

setup_thread :: proc(gp, stack, size, args: u32) -> u32 {
	cpu.r[28].d[0] = sx32(gp)
	top := stack == 0xffffffff ? RAM_SIZE : stack + size
	t := k.current
	t.gp, t.stack, t.stack_size = gp, top - size, size
	return top - 16
}

create_thread :: proc(param: u32) -> i64 {
	id := -1
	for n in 2 ..< len(k.threads) {
		if k.threads[n] == nil {id = n; break}
	}
	if id < 0 {return KE_ERROR}
	t := new(Thread)
	t.id = i32(id)
	t.status = .Dormant
	t.entry = rd32(param + 4)
	t.stack = rd32(param + 8)
	t.stack_size = rd32(param + 12)
	t.gp = rd32(param + 16)
	t.init_prio = i32(rd32(param + 20))
	t.prio = t.init_prio
	t.attr = rd32(param + 28)
	t.option = rd32(param + 32)
	k.threads[id] = t
	k.thread_end = max(k.thread_end, id + 1)
	return i64(id)
}

delete_thread :: proc(id: i32) -> i64 {
	t := thread(id)
	if t == nil || t == k.current || t.status != .Dormant {return KE_ERROR}
	k.threads[id] = nil
	if t.co != nil {core.co_kill(t.co)}
	free(t)
	return KE_OK
}

// Body of every created thread's coroutine: run the entry, then park
// dormant until started again.
@(private)
thread_main :: proc(arg: rawptr) {
	t := (^Thread)(arg)
	for {
		call(t.entry)
		t.status = .Dormant
		reschedule()
	}
}

start_thread :: proc(id: i32, arg: u32) -> i64 {
	t := thread(id)
	if t == nil || t.status != .Dormant {return KE_ERROR}
	t.regs = {}
	t.regs.r[4].d[0] = sx32(arg)
	t.regs.r[28].d[0] = sx32(t.gp)
	t.regs.r[29].d[0] = sx32(t.stack + t.stack_size - 16)
	t.regs.fcr31 = cpu.fcr31
	t.regs.cop0 = cpu.cop0
	t.regs.cop0[12] = STATUS_USER
	t.prio = t.init_prio
	t.wakeups = 0
	if t.co == nil {t.co = core.co_create(thread_main, t)}
	make_ready(t)
	reschedule()
	return KE_OK
}

exit_thread :: proc() {
	t := k.current
	t.status = .Dormant
	if t.id == 1 {fatal("main thread exited")}
	reschedule()
	// Restarted: run the entry again on a fresh frame of thread_main.
	fatal("exited thread %d resumed", t.id)
}

terminate_thread :: proc(id: i32) -> i64 {
	t := thread(id)
	if t == nil || t == k.current {return KE_ERROR}
	unwait(t)
	t.status = .Dormant
	// The coroutine is parked inside a syscall; drop it so a restart begins anew.
	if t.co != nil {core.co_kill(t.co); t.co = nil}
	return KE_OK
}

change_priority :: proc(id: i32, prio: i32) -> i64 {
	t := thread(id)
	if t == nil {return KE_ERROR}
	old := t.prio
	t.prio = prio
	reschedule()
	return i64(old)
}

rotate_ready_queue :: proc(prio: i32) -> i64 {
	if k.current.prio == prio {
		k.seq += 1
		k.current.seq = k.seq
	}
	for t in k.threads[:k.thread_end] {
		if t != nil && t != k.current && t.prio == prio && t.status == .Ready {
			reschedule()
			break
		}
	}
	return KE_OK
}

refer_thread :: proc(id: i32, info: u32) -> i64 {
	t := thread(id)
	if t == nil {return KE_ERROR}
	if info != 0 {
		wr32(info + 0, u32(t.status))
		wr32(info + 4, t.entry)
		wr32(info + 8, t.stack)
		wr32(info + 12, t.stack_size)
		wr32(info + 16, t.gp)
		wr32(info + 20, u32(t.init_prio))
		wr32(info + 24, u32(t.prio))
		wr32(info + 28, t.attr)
		wr32(info + 32, t.option)
		wr32(info + 36, u32(t.wait))
		wr32(info + 40, u32(t.wait_id))
		wr32(info + 44, u32(t.wakeups))
	}
	return i64(t.status)
}

sleep_thread :: proc() -> i64 {
	t := k.current
	if t.wakeups > 0 {
		t.wakeups -= 1
		return KE_OK
	}
	block(t, .Sleep, 0)
	return i64(t.wait_result)
}

wakeup_thread :: proc(id: i32) -> i64 {
	t := thread(id)
	if t == nil || t == k.current && !k.in_interrupt {return KE_ERROR}
	if t.wait == .Sleep {
		wake(t, KE_OK)
		reschedule()
	} else {
		t.wakeups += 1
	}
	return KE_OK
}

suspend_thread :: proc(id: i32) -> i64 {
	t := thread(id)
	if t == nil {return KE_ERROR}
	#partial switch t.status {
	case .Wait:  t.status = .Wait_Suspend
	case .Ready, .Run: t.status = .Suspend
	}
	reschedule()
	return KE_OK
}

resume_thread :: proc(id: i32) -> i64 {
	t := thread(id)
	if t == nil {return KE_ERROR}
	#partial switch t.status {
	case .Wait_Suspend: t.status = .Wait
	case .Suspend: make_ready(t); reschedule()
	}
	return KE_OK
}

release_wait :: proc(id: i32) -> i64 {
	t := thread(id)
	if t == nil || t.wait == .None {return KE_ERROR}
	unwait(t)
	wake(t, KE_RELEASE_WAIT)
	reschedule()
	return KE_OK
}

make_ready :: proc(t: ^Thread) {
	t.status = .Ready
	k.seq += 1
	t.seq = k.seq
}

// Put the current thread to sleep on something and run others until woken.
block :: proc(t: ^Thread, kind: Wait_Kind, id: i32) {
	t.status = .Wait
	t.wait = kind
	t.wait_id = id
	reschedule()
}

wake :: proc(t: ^Thread, result: i32) {
	t.wait = .None
	t.wait_result = result
	if t.status == .Wait_Suspend {
		t.status = .Suspend
	} else {
		make_ready(t)
	}
}

// Drop a thread from whatever it waits on.
unwait :: proc(t: ^Thread) {
	if t.wait == .Sema {
		if s := sema(t.wait_id); s != nil {s.waiters -= 1}
	}
}

@(private)
pick_thread :: proc() -> ^Thread {
	best: ^Thread
	for t in k.threads[:k.thread_end] {
		if t == nil || (t.status != .Ready && t.status != .Run) {continue}
		if best == nil || t.prio < best.prio || (t.prio == best.prio && t.seq < best.seq) {
			best = t
		}
	}
	return best
}

// Switch to the highest-priority runnable thread, idling (advancing time to
// the next event) while none is runnable.
// Status as the kernel starts a thread: user mode, COP0/1 usable, EIE and
// IE set, EXL clear.
STATUS_USER :: 0x70030c13 &~ 0x2

reschedule :: proc() {
	if k.in_interrupt {return}
	for {
		next := pick_thread()
		if next != nil {
			if next != k.current {switch_to(next)}
			return
		}
		idle()
	}
}

@(private)
switch_to :: proc(next: ^Thread) {
	cur := k.current
	cur.regs = cpu
	if cur.status == .Run {cur.status = .Ready}
	k.current = next
	next.status = .Run
	cycles := cpu.cycles
	cpu = next.regs
	cpu.cycles = cycles
	core.co_switch(next.co)
}

// Guest cycles skipped while every thread waits, for NT_STATS.
idle_cycles: u64

@(private)
idle :: proc() {
	if next_event == max(u64) {fatal("deadlock: every thread waits and no event is pending")}
	if cpu.cycles < next_event {
		idle_cycles += next_event - cpu.cycles
		cpu.cycles = next_event
	}
	// The kernel idles with interrupts enabled, whatever the status of the
	// thread that blocked last.
	status := cpu.cop0[12]
	cpu.cop0[12] = STATUS_USER
	run_events()
	cpu.cop0[12] = status
}

// ----------------------------------------------------------- semaphores

sema :: proc(id: i32) -> ^Sema {
	if id <= 0 || id >= len(k.semas) {return nil}
	return k.semas[id]
}

create_sema :: proc(param: u32) -> i64 {
	for n in 1 ..< len(k.semas) {
		if k.semas[n] != nil {continue}
		s := new(Sema)
		s.id = i32(n)
		s.max = i32(rd32(param + 4))
		s.init = i32(rd32(param + 8))
		s.count = s.init
		s.attr = rd32(param + 16)
		s.option = rd32(param + 20)
		k.semas[n] = s
		return i64(n)
	}
	return KE_ERROR
}

delete_sema :: proc(id: i32) -> i64 {
	s := sema(id)
	if s == nil {return KE_UNKNOWN_SEMID}
	for t in k.threads[:k.thread_end] {
		if t != nil && t.wait == .Sema && t.wait_id == id {wake(t, KE_ERROR)}
	}
	k.semas[id] = nil
	free(s)
	reschedule()
	return i64(id)
}

signal_sema :: proc(id: i32) -> i64 {
	s := sema(id)
	if s == nil {return KE_UNKNOWN_SEMID}
	if s.waiters > 0 {
		// Wake the waiter that has waited longest among the highest priority.
		best: ^Thread
		for t in k.threads[:k.thread_end] {
			if t == nil || t.wait != .Sema || t.wait_id != id {continue}
			if best == nil || t.prio < best.prio || (t.prio == best.prio && t.seq < best.seq) {best = t}
		}
		s.waiters -= 1
		wake(best, id)
		reschedule()
	} else if s.count < s.max || s.max == 0 {
		s.count += 1
	}
	return i64(id)
}

wait_sema :: proc(id: i32) -> i64 {
	s := sema(id)
	if s == nil {return KE_UNKNOWN_SEMID}
	if s.count > 0 {
		s.count -= 1
		return i64(id)
	}
	s.waiters += 1
	t := k.current
	k.seq += 1
	t.seq = k.seq
	block(t, .Sema, id)
	return i64(t.wait_result)
}

poll_sema :: proc(id: i32) -> i64 {
	s := sema(id)
	if s == nil {return KE_UNKNOWN_SEMID}
	if s.count > 0 {
		s.count -= 1
		return i64(id)
	}
	return KE_SEMA_ZERO
}

refer_sema :: proc(id: i32, info: u32) -> i64 {
	s := sema(id)
	if s == nil {return KE_UNKNOWN_SEMID}
	if info != 0 {
		wr32(info + 0, u32(s.count))
		wr32(info + 4, u32(s.max))
		wr32(info + 8, u32(s.init))
		wr32(info + 12, u32(s.waiters))
		wr32(info + 16, s.attr)
		wr32(info + 20, s.option)
	}
	return i64(id)
}

// --------------------------------------------- interrupts and the clock

add_handler :: proc(list: ^[dynamic]Handler, cause, fn, arg: u32) -> i64 {
	id := k.next_handler
	k.next_handler += 1
	append(list, Handler{id = id, cause = cause, fn = fn, arg = arg, gp = u32(cpu.r[28].d[0]), enabled = true})
	return i64(id)
}

remove_handler :: proc(list: ^[dynamic]Handler, cause: u32, id: i32) -> i64 {
	for h, n in list {
		if h.id == id {
			ordered_remove(list, n)
			return KE_OK
		}
	}
	return KE_ERROR
}

set_alarm :: proc(time, fn, arg: u32) -> i64 {
	id := k.next_alarm
	k.next_alarm += 1
	append(&k.alarms, Alarm{
		id = id, deadline = cpu.cycles + u64(time) * CYCLES_PER_LINE, time = time,
		fn = fn, arg = arg, gp = u32(cpu.r[28].d[0]),
	})
	update_next_event()
	return i64(id)
}

release_alarm :: proc(id: i32) -> i64 {
	for a, n in k.alarms {
		if a.id == id {
			ordered_remove(&k.alarms, n)
			update_next_event()
			return KE_OK
		}
	}
	return KE_ERROR
}

// Call a guest interrupt handler with the interrupted state preserved.
call_handler :: proc(fn, gp, a0, a1, a2: u32) -> u32 {
	saved := cpu
	cpu.r[4].d[0] = sx32(a0)
	cpu.r[5].d[0] = sx32(a1)
	cpu.r[6].d[0] = sx32(a2)
	cpu.r[28].d[0] = sx32(gp)
	cpu.r[29].d[0] = INTR_STACK_TOP - 16
	cpu.r[31].d[0] = 0
	call(fn)
	ret := u32(cpu.r[2].d[0])
	cycles := cpu.cycles
	cpu = saved
	cpu.cycles = cycles
	return ret
}

update_next_event :: proc() {
	n := min(k.vblank_start, k.vblank_end)
	for a in k.alarms {n = min(n, a.deadline)}
	next_event = n
}

// Process due events and deliver pending interrupts. Called by recompiled
// code whenever `cpu.cycles` reaches `next_event`.
run_events :: proc() {
	if k.in_interrupt {return}
	k.in_interrupt = true
	next_event = max(u64) // handlers run without re-entering

	now := cpu.cycles
	if now >= k.vblank_start {
		k.vblank_start += CYCLES_PER_FRAME
		k.frame += 1
		gs_csr |= 0x8 // VSINT
		gs_csr ~= 0x2000 // FIELD
		intc_raise(INTC_VBLANK_START)
		if gs_imr & 0x800 == 0 {intc_raise(INTC_GS)}
		// Snapshots hold the state as of here, before the host's input for
		// the frame, so a loaded one replays with whatever input the host
		// gives it next.
		if core.snap_op != .None {core.snap_yield()}
		{
			context.allocator = core.host_allocator
			vblank_hook()
		}
		pad_update()
		fmod_vblank()
		if k.debug != 0 && k.frame % 120 == 0 {dump_threads()}
	}
	if now >= k.vblank_end {
		k.vblank_end += CYCLES_PER_FRAME
		intc_raise(INTC_VBLANK_END)
	}
	for n := 0; n < len(k.alarms); {
		a := k.alarms[n]
		if now >= a.deadline {
			ordered_remove(&k.alarms, n)
			call_handler(a.fn, a.gp, u32(a.id), a.time, a.arg)
		} else {
			n += 1
		}
	}
	deliver_interrupts()

	k.in_interrupt = false
	update_next_event()
	// A handler may have readied a thread that outranks the current one.
	if t := pick_thread(); t != nil && t != k.current && t.prio < k.current.prio {
		reschedule()
	}
}

// EI: unmask interrupts, and deliver at once any left pending while masked.
ei :: proc() {
	cpu.cop0[12] |= 0x10000
	if intc_pending & intc_mask != 0 || dmac_stat & (dmac_stat >> 16) & 0x3ff != 0 || len(sif.replies) != 0 {
		next_event = cpu.cycles
	}
}

deliver_interrupts :: proc() {
	// Masked by DI: pending bits stay set in INTC_STAT/D_STAT, where code
	// polling with interrupts off (sceGsSyncV and friends) expects them.
	// EI re-arms delivery.
	if cpu.cop0[12] & 0x10001 != 0x10001 {return}
	for {
		sif_pump()
		pending := intc_pending & intc_mask
		dpending := dmac_stat & (dmac_stat >> 16) & 0x3ff
		if pending == 0 && dpending == 0 {return}
		for cause in u32(0) ..< 15 {
			if pending & (1 << cause) == 0 {continue}
			intc_pending &~= 1 << cause
	for h in k.intc {
				if h.cause == cause && h.enabled {
					if i32(call_handler(h.fn, h.gp, cause, h.arg, 0)) < 0 {break} // a negative return ends the chain
				}
			}
		}
		for ch in u32(0) ..< 10 {
			if dpending & (1 << ch) == 0 {continue}
			dmac_stat &~= 1 << ch
			for h in k.dmac {
				if h.cause == ch && h.enabled {
					if i32(call_handler(h.fn, h.gp, ch, h.arg, 0)) < 0 {break} // a negative return ends the chain
				}
			}
		}
	}
}

// Called on every vblank start, for the host side (present, input, pacing).
vblank_hook: proc() = proc() {}

hle_call :: proc(addr: u32) -> bool {
	return false
}

dump_threads :: proc() {
	fmt.eprintfln("--- frame %d, current thread %d", k.frame, k.current.id)
	for t in k.threads[:k.thread_end] {
		if t == nil {continue}
		regs := t == k.current ? cpu : t.regs
		fmt.eprintfln("thread %2d prio %3d %v wait %v/%d entry %08x ra %08x sp %08x",
			t.id, t.prio, t.status, t.wait, t.wait_id, t.entry, u32(regs.r[31].d[0]), u32(regs.r[29].d[0]))
		// Words on the stack that point into code: likely return addresses.
		sp := u32(regs.r[29].d[0]) & 0x0fffffff
		fmt.eprint("    stack:")
		for o: u32 = 0; o < 0x200 && sp + o + 4 <= RAM_SIZE; o += 4 {
			w := ram_slice(sp + o, 4)
			v := u32(w[0]) | u32(w[1]) << 8 | u32(w[2]) << 16 | u32(w[3]) << 24
			if v >= 0x100000 && v < 0x400000 && v & 3 == 0 {fmt.eprintf(" %x", v)}
		}
		fmt.eprintln()
	}
	for s in k.semas {
		if s == nil {continue}
		fmt.eprintf("sema %d %d/%d w%d  ", s.id, s.count, s.max, s.waiters)
	}
	fmt.eprintln()
	fmt.eprintfln("intc mask %x pend %x  dmac stat %08x  status %08x  gs csr %x imr %x  vif1 chcr %x gif chcr %x",
		intc_mask, intc_pending, dmac_stat, cpu.cop0[12], gs_csr, gs_imr, dma_reg(DMA_VIF1, 0)^, dma_reg(DMA_GIF, 0)^)
	for h in k.intc {fmt.eprintf("intc %d:%x%s ", h.cause, h.fn, h.enabled ? "" : "(off)")}
	for h in k.dmac {fmt.eprintf("dmac %d:%x%s ", h.cause, h.fn, h.enabled ? "" : "(off)")}
	fmt.eprintln()
}

// Emulated state, saved and restored by snapshots (snap.odin).
@(private)
kernel_snap :: proc() {
	core.snap_add(&k)
	core.snap_add(&idle_cycles)
}
