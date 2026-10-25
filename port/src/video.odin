// Host window: presents the GS read circuit each vblank and paces the game
// to 60 Hz.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import sdl "vendor:sdl2"
import "ee"
import "gs"
import "ps:core"

@(private = "file")
win: ^sdl.Window
@(private = "file")
ren: ^sdl.Renderer
@(private = "file")
tex: ^sdl.Texture
@(private = "file")
hw: bool // the Vulkan GS draws and presents
@(private = "file")
last: time.Tick
@(private = "file")
frame: int
@(private = "file")
shots: [dynamic]int // NT_SHOT=<frame>,...: write shot_<frame>.ppm at each, ascending
@(private = "file")
next_shot: int // index into shots
@(private = "file")
SHOT_WARMUP :: 10 // frames drawn before a headless shot, to fill both buffers
// NT_PRESS=Start@600,Cross@900: scripted taps, held for PRESS_FRAMES, so a
// headless run can get past the title screen. A ":n" suffix (Start@900:2)
// presses on player n instead of player 1, a "+n" suffix (Left@900+120)
// holds for n frames (core.input_script_load).
@(private = "file")
PRESS_FRAMES :: 6

video_init :: proc() {
	// Map Switch-style pads by position (south face button = cross), not label.
	sdl.SetHint(sdl.HINT_GAMECONTROLLER_USE_BUTTON_LABELS, "0")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_PS4_RUMBLE, "1")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_PS5_RUMBLE, "1")
	// NT_HEADLESS=1: no window, no 60 Hz pacing, no controllers.
	core.headless_init()
	stats = os.get_env("NT_STATS", context.temp_allocator) == "1"
	if !core.dump_init() {os.exit(1)}
	if v, ok := os.lookup_env("NT_SNAPTEST", context.temp_allocator); ok {
		a, _, b := strings.partition(v, ",")
		snaptest = {strconv.parse_int(a) or_else 0, strconv.parse_int(b) or_else 0}
	}
	if v, ok := os.lookup_env("NT_RBTEST", context.temp_allocator); ok {
		for f, i in strings.split(v, ",", context.temp_allocator) {
			if i < len(rbtest) {rbtest[i] = strconv.parse_int(f) or_else 0}
		}
	}
	// The frame count drives NT_PRESS and NT_SHOT, so it rewinds with the game.
	core.snap_add(&frame)
	core.snap_add(&next_shot)
	// Headless runs take input from NT_PRESS only, so they replay exactly.
	subsystems := sdl.InitFlags{.VIDEO, .AUDIO, .GAMECONTROLLER}
	if core.headless {subsystems -= {.GAMECONTROLLER}}
	if sdl.Init(subsystems) != 0 {
		fmt.eprintln("sdl:", sdl.GetError())
		os.exit(1)
	}
	// NT_SW=1: the software GS and SDL's renderer; otherwise the Vulkan GS
	// at NT_SCALE times the native resolution (default 1 headless, 3 in a
	// window).
	hw = os.get_env("NT_SW", context.temp_allocator) != "1"
	scale := core.headless ? 1 : 3
	if v, ok := strconv.parse_int(os.get_env("NT_SCALE", context.temp_allocator)); ok && v >= 1 && v <= 8 {scale = v}
	flags := sdl.WindowFlags{.RESIZABLE}
	if hw && !core.headless {flags += {.VULKAN}}
	win = sdl.CreateWindow("Nicktoons Unite!", sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED,
		gs.DISP_W * 2, 480 * 2, flags)
	if hw {
		gs.hw_init(core.headless ? nil : win, u32(scale))
	} else {
		ren = sdl.CreateRenderer(win, -1, {.ACCELERATED})
		tex = sdl.CreateTexture(ren, .ABGR8888, .STREAMING, gs.DISP_W, gs.DISP_H)
	}
	gs.snap_regions(core.snap_add_bytes)
	if hw {append(&core.snap_hooks, core.Snap_Hook{gs.hw_snap_save, gs.hw_snap_load})}
	// Also loads community mappings for pads SDL does not know
	// (gamecontrollerdb.txt).
	core.input_init(false)
	core.input_bind_standard()
	core.input_bind_keys_standard()
	if v, ok := strconv.parse_int(os.get_env("NT_PLAYERS", context.temp_allocator)); ok {
		forced_players = clamp(v, 1, ee.MAX_PLAYERS)
		for i in 0 ..< forced_players {ee.pads[i].connected = true}
	}
	ee.gs.write = gs.write
	ee.gs.transfer = gs.transfer
	ee.vblank_hook = video_frame
	audio_init(core.headless)
	last = time.tick_now()
	if v, ok := os.lookup_env("NT_SHOT", context.temp_allocator); ok {
		for item in strings.split(v, ",", context.temp_allocator) {
			if f, ok2 := strconv.parse_int(item); ok2 && f > 0 {append(&shots, f)}
		}
		slice.sort(shots[:])
	}
	shot_skip_update()
	_ = core.input_script_load(PRESS_FRAMES)
}

video_frame :: proc() {
	// Nothing outlives a frame in the temp arena; without this it grows
	// with every DMA transfer gathered into it.
	free_all(context.temp_allocator)
	ev: sdl.Event
	for sdl.PollEvent(&ev) {
		if ev.type == .QUIT {os.exit(0)}
		// Hotplug; also fires at startup for pads already plugged in.
		core.input_event(ev)
	}
	input_poll()
	audio_frame()
	w, h := gs.scanout()
	if w > 0 && h > 0 {
		if !core.headless && !hw {
			sdl.UpdateTexture(tex, nil, &gs.screen, gs.DISP_W * 4)
			src := sdl.Rect{0, 0, i32(w), i32(h)}
			sdl.RenderClear(ren)
			sdl.RenderCopy(ren, tex, &src, nil)
			sdl.RenderPresent(ren)
		}
		frame += 1
		for next_shot < len(shots) && frame >= shots[next_shot] {
			if frame == shots[next_shot] {
				name := fmt.tprintf("shot_%d.ppm", frame)
				if hw {
					px, sw, sh := gs.hw_screen()
					write_ppm(name, px, sw, sw, sh)
				} else {
					write_ppm(name, gs.screen[:], gs.DISP_W, w, h)
				}
				fmt.eprintfln("shot: frame %d", frame)
			}
			next_shot += 1
			// A headless run with shots is done once the last one is taken.
			if core.headless && next_shot == len(shots) && (snaptest[1] == 0 || snaptest_loaded) {os.exit(0)}
		}
		shot_skip_update()
		snaptest_frame()
		if rbtest[1] > 0 {rbtest_frame()}
		if stats && frame % STATS_FRAMES == 0 {print_stats()}
		// NT_DUMP=<dir>: the guest clock and EE and IOP memory per presented
		// frame (with NT_DUMP_HASH=1, their hashes in <dir>/hashes.tsv, so two
		// runs can be diffed for the first frame they diverge).
		if core.dump_due(u64(frame)) {
			cyc := ee.cpu.cycles
			core.dump_put("cyc", "bin", u64(frame), ([^]u8)(&cyc)[:size_of(cyc)])
			core.dump_put("ram", "bin", u64(frame), ee.ram)
			core.dump_put("iop", "bin", u64(frame), ee.iop_ram)
		}
	}
	if core.headless {return}
	FRAME :: time.Second / 60
	el := time.tick_since(last)
	if el < FRAME {time.sleep(FRAME - el)}
	last = time.tick_now()
}

// NT_STATS=1: every STATS_FRAMES presented frames, host frame rate and the
// share of guest time the kernel skipped with every thread waiting.
@(private = "file")
stats: bool
@(private = "file")
STATS_FRAMES :: 300

@(private = "file")
print_stats :: proc() {
	@(static) t0: time.Tick
	@(static) cyc0, idle0, tsc0: u64
	@(static) prof0: [ee.Prof]u64
	now := time.tick_now()
	tsc := ee.prof_start()
	if t0 != {} {
		secs := time.duration_seconds(time.tick_diff(t0, now))
		cyc, idl := ee.cpu.cycles - cyc0, ee.idle_cycles - idle0
		fmt.eprintf("stats: frame %d  %.1f fps  idle %.0f%%", frame,
			f64(STATS_FRAMES) / secs, 100 * f64(idl) / f64(max(cyc, 1)))
		for p in ee.Prof {
			fmt.eprintf("  %v %.0f%%", p, 100 * f64(ee.prof[p] - prof0[p]) / f64(max(tsc - tsc0, 1)))
		}
		fmt.eprintln()
	}
	t0, cyc0, idle0, tsc0, prof0 = now, ee.cpu.cycles, ee.idle_cycles, tsc, ee.prof
}

// NT_SNAPTEST=<save>,<load>: save state at presented frame <save>, load it
// once at frame <load>. The replayed frames must match the first pass: with
// NT_DUMP_HASH, every frame hashes the same both times.
@(private = "file")
snaptest: [2]int
@(private = "file")
snaptest_loaded: bool
@(private = "file")
snaptest_snap: core.Snapshot
@(private = "file")
snaptest_t: time.Tick

@(private = "file")
snaptest_frame :: proc() {
	if snaptest_t != {} {
		fmt.eprintfln("snap: %v took %.2f ms, %d MiB", snaptest_loaded ? "load" : "save",
			time.duration_milliseconds(time.tick_since(snaptest_t)), len(snaptest_snap.data) >> 20)
		snaptest_t = {}
	}
	op: core.Snap_Op
	if frame == snaptest[0] && !snaptest_loaded {op = .Save}
	if frame == snaptest[1] && !snaptest_loaded {op = .Load; snaptest_loaded = true}
	if op != .None {
		core.snap_op, core.snap_target = op, &snaptest_snap
		snaptest_t = time.tick_now()
	}
}

// NT_RBTEST=<start>,<every>,<back>: from presented frame <start>, commit a
// rollback record every frame, and every <every> frames rewind <back>
// frames (once per frame reached). The resimulated frames must match a
// plain run: with NT_DUMP_HASH, the set of hash lines is the same.
@(private = "file")
rbtest: [3]int
@(private = "file")
rbtest_done: int // host side: the last frame rewound from

@(private = "file")
rbtest_frame :: proc() {
	if frame < rbtest[0] {return}
	core.snap_op = .Commit
	if frame > rbtest_done && (frame - rbtest[0]) % rbtest[1] == 0 && core.rb_frames() > rbtest[2] {
		rbtest_done = frame
		core.snap_op, core.rb_back = .Rewind, rbtest[2]
	}
	if frame % 600 == 0 {
		st := core.rb_stats()
		fmt.eprintfln("rb: %d commits, avg %.3f ms (%.1f pages, %d KiB whole), worst %.3f ms", st.commits,
			time.duration_milliseconds(st.total) / f64(max(st.commits, 1)), f64(st.pages) / f64(max(st.commits, 1)),
			st.small >> 10, time.duration_milliseconds(st.worst))
	}
}

// Headless runs skip rasterizing until shortly before the next shot.
@(private = "file")
shot_skip_update :: proc() {
	gs.skip_draw = core.headless && (next_shot >= len(shots) || frame < shots[next_shot] - SHOT_WARMUP)
}

// NT_PLAYERS=n: players 1..n count as plugged in without a controller, so
// headless runs can exercise the multitap.
@(private = "file")
forced_players: int

// Controllers, keyboard and NT_PRESS (core input.odin) to the emulated pads:
// a controller per player, keeping its slot until unplugged; the keyboard
// feeds player 1. Motors follow the game's SetActDirect levels.
@(private = "file")
input_poll :: proc() {
	ps := core.input_poll(u64(frame))
	for &pad, i in ee.pads {
		p := ps[i]
		set := p.buttons
		axes: [4]u8
		for f, j in ([4]f32{p.right.x, p.right.y, p.left.x, p.left.y}) {
			axes[j] = u8((i32(math.round(f * 32767)) + 32768) >> 8)
		}
		// The game walks with the left stick only, so d-pad presses (from
		// the keyboard and NT_PRESS too) push it unless the stick is held.
		if abs(i32(axes[2]) - 0x80) < 0x40 {
			if .Left in set {axes[2] = 0x00}
			if .Right in set {axes[2] = 0xff}
		}
		if abs(i32(axes[3]) - 0x80) < 0x40 {
			if .Up in set {axes[3] = 0x00}
			if .Down in set {axes[3] = 0xff}
		}
		pad.connected = p.connected || i < forced_players
		pad.buttons = set
		pad.axes = axes
		core.input_rumble(i, pad.small != 0, pad.large)
	}
}

@(private = "file")
write_ppm :: proc(path: string, px: []u32, stride, w, h: int) {
	buf := make([dynamic]u8, context.temp_allocator)
	append(&buf, fmt.tprintf("P6\n%d %d\n255\n", w, h))
	for y in 0 ..< h {
		for x in 0 ..< w {
			c := px[y * stride + x]
			append(&buf, u8(c), u8(c >> 8), u8(c >> 16))
		}
	}
	_ = os.write_entire_file(path, buf[:])
	fmt.eprintln("video: wrote", path)
}
