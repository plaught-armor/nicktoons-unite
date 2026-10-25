// Save states and rollback (ps:core snap.odin, rollback_linux.odin): every
// file registers its emulated globals with core.snap_add from its X_snap
// proc, called here before anything is allocated; EE and IOP RAM come from
// core.snap_area; everything allocated during init and on every coroutine
// comes from core.emu_allocator. New emulated globals must be registered or
// save states and rollback desync.
package ee

import "ps:core"

// About 19 MiB is in use in a 4-player level. Rollback scans the whole
// heap for written pages every frame, at a cost that grows with its size.
@(private)
EMU_HEAP :: 1 << 27

// Set up the machine; what it allocates is emulated state.
init :: proc() {
	core.snap_init(EMU_HEAP)
	mem_snap()
	cpu_snap()
	dma_snap()
	hw_snap()
	kernel_snap()
	gs_snap()
	ipu_snap()
	fmod_snap()
	vu_snap()
	sif_snap()
	mcserv_snap()
	pad_snap()
	spu_snap()
	context.allocator = core.emu_allocator()
	core.co_allocator = core.emu_allocator()
	mem_init()
	vu_init()
	sif_init()
	kernel_init()
}

// Host main thread: run the game from `entry` on thread 1's coroutine,
// serving snapshot requests. Never returns.
run :: proc(entry: u32) -> ! {
	t := k.threads[1]
	t.co = core.co_create(proc(arg: rawptr) {
		call(u32(uintptr(arg)))
		fatal("entry returned")
	}, rawptr(uintptr(entry)), core.emu_allocator())
	core.snap_run(t.co)
}
