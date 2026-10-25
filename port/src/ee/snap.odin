// Save states: a copy of all emulated state, taken at a vblank and restored
// in place within the same process (the base for rollback netplay).
//
// State holds host pointers (coroutine stacks full of return addresses,
// heap objects, containers), so a snapshot is only valid in the process
// that took it, and nothing it points at may move or be freed for good:
// - globals are copied where they are (the regions each file registers
//   with snap_add);
// - large memory (EE and IOP RAM) is mapped page-aligned by snap_area, so
//   rollback (rollback.odin) can track its writes;
// - every heap allocation the emulator makes goes to one reserved region
//   managed by a buddy allocator (emu_allocator, the context allocator for
//   init and for every coroutine), copied block by block with its headers,
//   so restoring it also restores the allocator;
// - coroutine stacks come from a pool that is never unmapped
//   (coroutine_linux.odin), copied from each saved stack pointer up.
// Host state (window, Vulkan objects, audio queue, open files) is left
// alone; the GS registers hooks for its GPU-side memory.
//
// Snapshots are taken off the game's stacks: at a vblank with an operation
// requested, the running coroutine yields to the host main thread (run),
// which does the copy and resumes whichever coroutine the state it now holds
// was running.
package ee

import "base:runtime"
import "core:mem"
import "core:sys/linux"

Snapshot :: struct {
	id:    int, // names this snapshot's GPU-side copies
	frame: u64, // k.frame when taken
	data:  [dynamic]u8,
}

Snap_Op :: enum {
	None,
	Save,
	Load,
	Commit, // rollback: record this frame
	Rewind, // rollback: go back rb_back frames
}

// Set by the host during a vblank (vblank_hook): the operation done before
// the game continues.
snap_op: Snap_Op
snap_target: ^Snapshot

// Called for GPU-side state after the CPU copy is saved and before it is
// loaded.
snap_hooks: [dynamic]Snap_Hook

Snap_Hook :: struct {
	save, load: proc(id: int),
}

@(private)
snap_regions: [dynamic][]u8

// Memory from snap_area.
@(private)
snap_areas: [dynamic][]u8

// The coroutine to resume after a snapshot operation; part of the state.
@(private)
snap_resume: ^Coroutine

// About 19 MiB is in use in a 4-player level. Rollback scans the whole
// region for written pages every frame, at a cost that grows with its size.
@(private)
EMU_HEAP :: 1 << 27

@(private)
emu_heap: mem.Buddy_Allocator
@(private)
emu_heap_mem: []u8

host_allocator: runtime.Allocator

// Register a global as emulated state.
snap_add :: proc(p: ^$T) {
	append(&snap_regions, mem.ptr_to_bytes(p))
}

snap_add_bytes :: proc(b: []u8) {
	append(&snap_regions, b)
}

// Map `n` bytes (a multiple of the page size) of zeroed emulated memory.
@(private)
snap_area :: proc(n: int) -> []u8 {
	base, err := linux.mmap(0, uint(n), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS, .NORESERVE})
	assert(err == .NONE, "snapshot area")
	b := ([^]u8)(base)[:n]
	append(&snap_areas, b)
	return b
}

@(private)
snap_init :: proc() {
	host_allocator = context.allocator
	base, err := linux.mmap(0, EMU_HEAP, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS, .NORESERVE})
	assert(err == .NONE, "emulator heap")
	emu_heap_mem = ([^]u8)(base)[:EMU_HEAP]
	mem.buddy_allocator_init(&emu_heap, emu_heap_mem, 64) // maps want cache-line alignment
	snap_add(&snap_resume)
}

emu_allocator :: proc() -> runtime.Allocator {
	return mem.buddy_allocator(&emu_heap)
}

// Set up the machine; what it allocates is emulated state.
init :: proc() {
	snap_init()
	co_pool_snap()
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
	context.allocator = emu_allocator()
	mem_init()
	vu_init()
	sif_init()
	kernel_init()
}

// Host main thread: run the game from `entry` on thread 1's coroutine,
// serving snapshot requests. Never returns.
run :: proc(entry: u32) -> ! {
	t := k.threads[1]
	t.co = co_create(proc(arg: rawptr) {
		call(u32(uintptr(arg)))
		fatal("entry returned")
	}, rawptr(uintptr(entry)), emu_allocator())
	snap_resume = t.co
	context.allocator = host_allocator // for snapshot buffers
	for {
		co_switch(snap_resume)
		switch snap_op {
		case .None:
		case .Save: snap_save(snap_target)
		case .Load: snap_load(snap_target)
		case .Commit: rb_commit()
		case .Rewind: rb_rewind(rb_back)
		}
		snap_op = .None
	}
}

// From run_events, after vblank_hook asked for an operation.
@(private)
snap_yield :: proc() {
	snap_resume = co_current
	co_switch(&co_main_thread)
}

@(private)
take :: proc(d: []u8, pos: ^int, n: int) -> []u8 {
	b := d[pos^:][:n]
	pos^ += n
	return b
}

@(private)
snap_save :: proc(s: ^Snapshot) {
	clear(&s.data)
	s.frame = k.frame
	put_regions(&s.data)
	for a in snap_areas {append(&s.data, ..a)}
	// Heap blocks in address order: whole used blocks, free ones' headers.
	h := &emu_heap
	for b := h.head; b < h.tail; b = mem.buddy_block_next(b) {
		n := b.is_free ? size_of(mem.Buddy_Block) : int(b.size)
		append(&s.data, ..([^]u8)(b)[:n])
	}
	put_stacks(&s.data)
	for h in snap_hooks {h.save(s.id)}
}

@(private)
snap_load :: proc(s: ^Snapshot) {
	pos := 0
	take_regions(s.data[:], &pos)
	for a in snap_areas {copy(a, take(s.data[:], &pos, len(a)))}
	h := &emu_heap
	for b := h.head; b < h.tail; b = mem.buddy_block_next(b) {
		hdr := take(s.data[:], &pos, size_of(mem.Buddy_Block))
		copy(([^]u8)(b)[:len(hdr)], hdr)
		if !b.is_free {copy(([^]u8)(b)[len(hdr):b.size], take(s.data[:], &pos, int(b.size) - len(hdr)))}
	}
	take_stacks(s.data[:], &pos)
	assert(pos == len(s.data), "snapshot: size mismatch")
	for h in snap_hooks {h.load(s.id)}
}

@(private)
put_regions :: proc(d: ^[dynamic]u8) {
	for r in snap_regions {append(d, ..r)}
}

@(private)
take_regions :: proc(d: []u8, pos: ^int) {
	for r in snap_regions {copy(r, take(d, pos, len(r)))}
}

// Live stacks, from the saved pointer to the top.
@(private)
put_stacks :: proc(d: ^[dynamic]u8) {
	for co in co_stack_owner {
		if co == nil {continue}
		top := uintptr(co.ctx.stack) + CO_STACK
		append(d, ..([^]u8)(co.ctx.sp)[:top - uintptr(co.ctx.sp)])
	}
}

// After take_regions: co_stack_owner is a region, so these are the saved
// owners.
@(private)
take_stacks :: proc(d: []u8, pos: ^int) {
	for co in co_stack_owner {
		if co == nil {continue}
		n := int(uintptr(co.ctx.stack) + CO_STACK - uintptr(co.ctx.sp))
		copy(([^]u8)(co.ctx.sp)[:n], take(d, pos, n))
	}
}
