// Rollback: a record of each of the last RB_FRAMES frames, cheap enough to
// take at every vblank, and a rewind to any of them (the base for rollback
// netplay). Same rules as save states (snap.odin): records live in this
// process, are taken and restored on the host main thread, and the GS hooks
// keep GPU-side copies (one per ring slot).
//
// Large memory (snap_area memory and the emulator heap) is tracked by the
// kernel: it is registered with userfaultfd in asynchronous write-protect
// mode, so the first write to a protected page just unprotects it (no
// signal, no handler thread), and PAGEMAP_SCAN lists the pages written since
// the last scan and protects them again in one call. Kernel writes (read()
// into guest memory) are tracked too. A shadow copy holds that memory as of
// the last commit:
// - a commit appends the shadow's contents of each written page to the
//   frame's undo log, then copies the page into the shadow;
// - a rewind puts the pages written since the last commit back from the
//   shadow, then applies undo logs newest first to both.
// The small regions and live stacks are copied whole into every record.
package ee

import "base:intrinsics"
import "core:sys/linux"
import "core:time"

RB_FRAMES :: 8

// Set with snap_op = .Rewind; 1 is the frame of the last commit.
rb_back: int

// Ids for the GS hooks, apart from save-state ids.
@(private)
RB_HOOK_ID :: 1 << 20

@(private)
PAGE :: 4096

@(private)
Rb_Area :: struct {
	mem, shadow: []u8,
}

@(private)
Rb_Page :: struct {
	area, off: u32,
}

@(private)
Rb_Record :: struct {
	frame: u64, // k.frame when committed
	small: [dynamic]u8, // regions, then live stacks
	pages: [dynamic]Rb_Page, // written during this frame, with ...
	undo:  [dynamic]u8, // ... their contents as of the previous commit
}

@(private)
Rb_Commit :: struct {
	rec:  ^Rb_Record,
	area: u32,
	log:  bool,
}

@(private)
rb: struct {
	on:      bool,
	uffd:    linux.Fd,
	pagemap: linux.Fd,
	areas:   [dynamic]Rb_Area,
	records: [RB_FRAMES]Rb_Record,
	head:    int, // newest record
	count:   int, // records held
	scan:    [512]Pm_Region,
	stats:   Rb_Stats,
}

// Host time spent in commits, for measuring.
Rb_Stats :: struct {
	commits, pages: int,
	small:          int, // bytes copied whole per commit
	total, worst:   time.Duration,
}

rb_stats :: proc() -> Rb_Stats {
	return rb.stats
}

// Frames that can be rewound to now (rb_back < rb_frames()).
rb_frames :: proc() -> int {
	return rb.count
}

// linux/userfaultfd.h, linux/fs.h
@(private)
Uffd_Range :: struct {
	start, len: u64,
}
@(private)
UFFD_USER_MODE_ONLY :: 1
@(private)
UFFD_FEATURE_WP_UNPOPULATED :: 1 << 13
@(private)
UFFD_FEATURE_WP_ASYNC :: 1 << 15
@(private)
UFFDIO_API :: 0xC018AA3F
@(private)
UFFDIO_REGISTER :: 0xC020AA00
@(private)
UFFDIO_REGISTER_MODE_WP :: 2
@(private)
UFFDIO_WRITEPROTECT :: 0xC018AA06
@(private)
UFFDIO_WRITEPROTECT_MODE_WP :: 1
@(private)
PAGEMAP_SCAN :: 0xC0606610
@(private)
PM_SCAN_WP_MATCHING :: 1 << 0
@(private)
PM_SCAN_CHECK_WPASYNC :: 1 << 1
@(private)
PAGE_IS_WRITTEN :: 1 << 1
@(private)
PAGE_IS_PRESENT :: 1 << 3
@(private)
Pm_Scan_Arg :: struct {
	size, flags, start, end, walk_end, vec, vec_len, max_pages: u64,
	category_inverted, category_mask, category_anyof_mask, return_mask: u64,
}
@(private)
Pm_Region :: struct {
	start, end, categories: u64,
}

@(private)
rb_ioctl :: proc(fd: linux.Fd, req: uintptr, arg: rawptr) -> int {
	return int(intrinsics.syscall(linux.SYS_ioctl, uintptr(fd), req, uintptr(arg)))
}

// Start tracking: protect the large memory and copy what is in it to the
// shadows. Fails (returns false) if the kernel lacks asynchronous
// write-protect (Linux 6.7+).
@(private)
rb_start :: proc() -> bool {
	fd := int(intrinsics.syscall(linux.SYS_userfaultfd, uintptr(transmute(i32)linux.Open_Flags{.CLOEXEC}) | UFFD_USER_MODE_ONLY))
	if fd < 0 {return false}
	rb.uffd = linux.Fd(fd)
	api := struct {
		api, features, ioctls: u64,
	}{0xAA, UFFD_FEATURE_WP_ASYNC | UFFD_FEATURE_WP_UNPOPULATED, 0}
	if rb_ioctl(rb.uffd, UFFDIO_API, &api) < 0 {return false}
	err: linux.Errno
	rb.pagemap, err = linux.open("/proc/self/pagemap", {})
	if err != .NONE {return false}
	mems := make([dynamic][]u8, context.temp_allocator)
	append(&mems, ..snap_areas[:])
	append(&mems, emu_heap_mem)
	for m in mems {
		r := Uffd_Range{u64(uintptr(raw_data(m))), u64(len(m))}
		// Huge pages would be split by the first protected write anyway.
		linux.madvise(raw_data(m), uint(len(m)), .NOHUGEPAGE)
		reg := struct {
			range:        Uffd_Range,
			mode, ioctls: u64,
		}{r, UFFDIO_REGISTER_MODE_WP, 0}
		if rb_ioctl(rb.uffd, UFFDIO_REGISTER, &reg) < 0 {return false}
		wp := struct {
			range: Uffd_Range,
			mode:  u64,
		}{r, UFFDIO_WRITEPROTECT_MODE_WP}
		if rb_ioctl(rb.uffd, UFFDIO_WRITEPROTECT, &wp) < 0 {return false}
		base, merr := linux.mmap(0, uint(len(m)), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS, .NORESERVE})
		assert(merr == .NONE, "rollback shadow")
		a := Rb_Area{m, ([^]u8)(base)[:len(m)]}
		// Pages never touched are zero in both.
		rb_scan(a, false, proc(a: Rb_Area, off: int, _: rawptr) {
			copy(a.shadow[off:][:PAGE], a.mem[off:][:PAGE])
		}, nil)
		append(&rb.areas, a)
	}
	rb.on = true
	return true
}

// Call `f` for each page of `a` written since the last scan (protecting it
// again), or with `written` false, for each page present.
@(private)
rb_scan :: proc(a: Rb_Area, written: bool, f: proc(a: Rb_Area, off: int, data: rawptr), data: rawptr) {
	base := u64(uintptr(raw_data(a.mem)))
	arg := Pm_Scan_Arg {
		size        = size_of(Pm_Scan_Arg),
		start       = base,
		end         = base + u64(len(a.mem)),
		vec         = u64(uintptr(&rb.scan)),
		vec_len     = len(rb.scan),
		return_mask = PAGE_IS_WRITTEN | PAGE_IS_PRESENT,
	}
	if written {
		arg.flags = PM_SCAN_WP_MATCHING | PM_SCAN_CHECK_WPASYNC
		arg.category_mask = PAGE_IS_WRITTEN
	} else {
		arg.category_mask = PAGE_IS_PRESENT
	}
	for arg.start < arg.end {
		n := rb_ioctl(rb.pagemap, PAGEMAP_SCAN, &arg)
		assert(n >= 0, "PAGEMAP_SCAN")
		for r in rb.scan[:n] {
			for p := r.start; p < r.end; p += PAGE {f(a, int(p - base), data)}
		}
		arg.start = arg.walk_end
	}
}

// Record the state at this vblank as the newest frame.
@(private)
rb_commit :: proc() {
	if !rb.on && !rb_start() {fatal("rollback: kernel lacks userfaultfd async write-protect")}
	t := time.tick_now()
	rb.head = (rb.head + 1) % RB_FRAMES
	rec := &rb.records[rb.head]
	rec.frame = k.frame
	clear(&rec.pages)
	clear(&rec.undo)
	// The oldest record's undo log is never applied, so the first commit
	// (taking every page written since rb_start) keeps none.
	for a, i in rb.areas {
		c := Rb_Commit{rec, u32(i), rb.count > 0}
		rb_scan(a, true, proc(a: Rb_Area, off: int, data: rawptr) {
			c := (^Rb_Commit)(data)
			if c.log {
				append(&c.rec.pages, Rb_Page{c.area, u32(off)})
				append(&c.rec.undo, ..a.shadow[off:][:PAGE])
			}
			copy(a.shadow[off:][:PAGE], a.mem[off:][:PAGE])
		}, &c)
	}
	clear(&rec.small)
	put_regions(&rec.small)
	put_stacks(&rec.small)
	rb.count = min(rb.count + 1, RB_FRAMES)
	for h in snap_hooks {h.save(RB_HOOK_ID + rb.head)}
	d := time.tick_since(t)
	rb.stats.commits += 1
	rb.stats.pages += len(rec.pages)
	rb.stats.small = len(rec.small)
	rb.stats.total += d
	rb.stats.worst = max(rb.stats.worst, d)
}

// Go back to the state `back` commits ago (1 = the last one).
@(private)
rb_rewind :: proc(back: int) {
	assert(back >= 1 && back <= rb.count, "rollback: frame not held")
	for a in rb.areas {
		rb_scan(a, true, proc(a: Rb_Area, off: int, _: rawptr) {
			copy(a.mem[off:][:PAGE], a.shadow[off:][:PAGE])
		}, nil)
	}
	for _ in 1 ..< back {
		rec := &rb.records[rb.head]
		for p, i in rec.pages {
			a := rb.areas[p.area]
			old := rec.undo[i * PAGE:][:PAGE]
			copy(a.mem[p.off:][:PAGE], old)
			copy(a.shadow[p.off:][:PAGE], old)
		}
		rb.head = (rb.head + RB_FRAMES - 1) % RB_FRAMES
		rb.count -= 1
	}
	// The pages just restored match the shadow again: protect them.
	for a in rb.areas {rb_scan(a, true, proc(a: Rb_Area, off: int, _: rawptr) {}, nil)}
	rec := &rb.records[rb.head]
	pos := 0
	take_regions(rec.small[:], &pos)
	take_stacks(rec.small[:], &pos)
	assert(pos == len(rec.small), "rollback: size mismatch")
	for h in snap_hooks {h.load(RB_HOOK_ID + rb.head)}
}
