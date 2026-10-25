// Host window: presents the GS read circuit each vblank and paces the game
// to 60 Hz.
package main

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import sdl "vendor:sdl2"
import "ee"
import "gs"

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
@(private = "file")
headless: bool // NT_HEADLESS=1: no window, no 60 Hz pacing
@(private = "file")
Press :: struct {
	frame:  int,
	hold:   int,
	btn:    ee.Pad_Button,
	player: int,
}
// NT_PRESS=Start@600,Cross@900: scripted taps, held for PRESS_FRAMES, so a
// headless run can get past the title screen. A ":n" suffix (Start@900:2)
// presses on player n instead of player 1, a "+n" suffix (Left@900+120)
// holds for n frames.
@(private = "file")
presses: [dynamic]Press
@(private = "file")
PRESS_FRAMES :: 6

video_init :: proc() {
	// Map Switch-style pads by position (south face button = cross), not label.
	sdl.SetHint(sdl.HINT_GAMECONTROLLER_USE_BUTTON_LABELS, "0")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_PS4_RUMBLE, "1")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_PS5_RUMBLE, "1")
	headless = os.get_env("NT_HEADLESS", context.temp_allocator) == "1"
	stats = os.get_env("NT_STATS", context.temp_allocator) == "1"
	hash_frames = os.get_env("NT_HASH", context.temp_allocator) == "1"
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
	ee.snap_add(&frame)
	ee.snap_add(&next_shot)
	// Headless runs take input from NT_PRESS only, so they replay exactly.
	subsystems := sdl.InitFlags{.VIDEO, .AUDIO, .GAMECONTROLLER}
	if headless {
		sdl.SetHint("SDL_VIDEODRIVER", "offscreen")
		subsystems -= {.GAMECONTROLLER}
	}
	if sdl.Init(subsystems) != 0 {
		fmt.eprintln("sdl:", sdl.GetError())
		os.exit(1)
	}
	// NT_SW=1: the software GS and SDL's renderer; otherwise the Vulkan GS
	// at NT_SCALE times the native resolution (default 1 headless, 3 in a
	// window).
	hw = os.get_env("NT_SW", context.temp_allocator) != "1"
	scale := headless ? 1 : 3
	if v, ok := strconv.parse_int(os.get_env("NT_SCALE", context.temp_allocator)); ok && v >= 1 && v <= 8 {scale = v}
	flags := sdl.WindowFlags{.RESIZABLE}
	if hw && !headless {flags += {.VULKAN}}
	win = sdl.CreateWindow("Nicktoons Unite!", sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED,
		gs.DISP_W * 2, 480 * 2, flags)
	if hw {
		gs.hw_init(headless ? nil : win, u32(scale))
	} else {
		ren = sdl.CreateRenderer(win, -1, {.ACCELERATED})
		tex = sdl.CreateTexture(ren, .ABGR8888, .STREAMING, gs.DISP_W, gs.DISP_H)
	}
	gs.snap_regions(ee.snap_add_bytes)
	if hw {append(&ee.snap_hooks, ee.Snap_Hook{gs.hw_snap_save, gs.hw_snap_load})}
	// Community mappings for pads SDL does not know (gamecontrollerdb.txt).
	if v, ok := strconv.parse_int(os.get_env("NT_PLAYERS", context.temp_allocator)); ok {
		forced_players = clamp(v, 1, ee.MAX_PLAYERS)
		for i in 0 ..< forced_players {ee.pads[i].connected = true}
	}
	if os.exists("gamecontrollerdb.txt") {
		_ = sdl.GameControllerAddMappingsFromFile("gamecontrollerdb.txt")
	}
	ee.gs.write = gs.write
	ee.gs.transfer = gs.transfer
	ee.vblank_hook = video_frame
	audio_init(headless)
	last = time.tick_now()
	if v, ok := os.lookup_env("NT_SHOT", context.temp_allocator); ok {
		for item in strings.split(v, ",", context.temp_allocator) {
			if f, ok2 := strconv.parse_int(item); ok2 && f > 0 {append(&shots, f)}
		}
		slice.sort(shots[:])
	}
	shot_skip_update()
	if v, ok := os.lookup_env("NT_PRESS", context.temp_allocator); ok {
		for item in strings.split(v, ",", context.temp_allocator) {
			name, _, rest := strings.partition(item, "@")
			timing, colon, who := strings.partition(rest, ":")
			at, plus, dur := strings.partition(timing, "+")
			btn, bok := reflect.enum_from_name(ee.Pad_Button, name)
			f, fok := strconv.parse_int(at)
			player, pok := 1, true
			if colon != "" {player, pok = strconv.parse_int(who)}
			hold, hok := PRESS_FRAMES, true
			if plus != "" {hold, hok = strconv.parse_int(dur)}
			if !bok || !fok || !pok || !hok || hold < 1 || player < 1 || player > ee.MAX_PLAYERS {
				fmt.eprintfln("NT_PRESS: bad entry \"%s\"", item)
				continue
			}
			append(&presses, Press{f, hold, btn, player - 1})
		}
	}
}

video_frame :: proc() {
	// Nothing outlives a frame in the temp arena; without this it grows
	// with every DMA transfer gathered into it.
	free_all(context.temp_allocator)
	ev: sdl.Event
	for sdl.PollEvent(&ev) {
		#partial switch ev.type {
		case .QUIT: os.exit(0)
		case .CONTROLLERDEVICEADDED:
			// Also fires at startup for pads already plugged in.
			controller_add(ev.cdevice.which)
		case .CONTROLLERDEVICEREMOVED:
			controller_remove(sdl.JoystickID(ev.cdevice.which))
		}
	}
	input_poll()
	audio_frame()
	w, h := gs.scanout()
	if w > 0 && h > 0 {
		if !headless && !hw {
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
			if headless && next_shot == len(shots) && (snaptest[1] == 0 || snaptest_loaded) {os.exit(0)}
		}
		shot_skip_update()
		snaptest_frame()
		if rbtest[1] > 0 {rbtest_frame()}
		if stats && frame % STATS_FRAMES == 0 {print_stats()}
		if hash_frames {
			fmt.eprintfln("hash: frame %d  cyc %d  ram %16x  iop %16x", frame, ee.cpu.cycles,
				xxhash.XXH3_64_default(ee.ram), xxhash.XXH3_64_default(ee.iop_ram))
		}
	}
	if headless {return}
	FRAME :: time.Second / 60
	el := time.tick_since(last)
	if el < FRAME {time.sleep(FRAME - el)}
	last = time.tick_now()
}

// NT_STATS=1: every STATS_FRAMES presented frames, host frame rate and the
// share of guest time the kernel skipped with every thread waiting.
@(private = "file")
stats: bool
// NT_HASH=1: per presented frame, the guest clock and hashes of EE and IOP
// memory, so two runs can be diffed for the first frame they diverge.
@(private = "file")
hash_frames: bool
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
// NT_HASH, every frame hashes the same both times.
@(private = "file")
snaptest: [2]int
@(private = "file")
snaptest_loaded: bool
@(private = "file")
snaptest_snap: ee.Snapshot
@(private = "file")
snaptest_t: time.Tick

@(private = "file")
snaptest_frame :: proc() {
	if snaptest_t != {} {
		fmt.eprintfln("snap: %v took %.2f ms, %d MiB", snaptest_loaded ? "load" : "save",
			time.duration_milliseconds(time.tick_since(snaptest_t)), len(snaptest_snap.data) >> 20)
		snaptest_t = {}
	}
	op: ee.Snap_Op
	if frame == snaptest[0] && !snaptest_loaded {op = .Save}
	if frame == snaptest[1] && !snaptest_loaded {op = .Load; snaptest_loaded = true}
	if op != .None {
		ee.snap_op, ee.snap_target = op, &snaptest_snap
		snaptest_t = time.tick_now()
	}
}

// NT_RBTEST=<start>,<every>,<back>: from presented frame <start>, commit a
// rollback record every frame, and every <every> frames rewind <back>
// frames (once per frame reached). The resimulated frames must match a
// plain run: with NT_HASH, the set of hash lines is the same.
@(private = "file")
rbtest: [3]int
@(private = "file")
rbtest_done: int // host side: the last frame rewound from

@(private = "file")
rbtest_frame :: proc() {
	if frame < rbtest[0] {return}
	ee.snap_op = .Commit
	if frame > rbtest_done && (frame - rbtest[0]) % rbtest[1] == 0 && ee.rb_frames() > rbtest[2] {
		rbtest_done = frame
		ee.snap_op, ee.rb_back = .Rewind, rbtest[2]
	}
	if frame % 600 == 0 {
		st := ee.rb_stats()
		fmt.eprintfln("rb: %d commits, avg %.3f ms (%.1f pages, %d KiB whole), worst %.3f ms", st.commits,
			time.duration_milliseconds(st.total) / f64(max(st.commits, 1)), f64(st.pages) / f64(max(st.commits, 1)),
			st.small >> 10, time.duration_milliseconds(st.worst))
	}
}

// Headless runs skip rasterizing until shortly before the next shot.
@(private = "file")
shot_skip_update :: proc() {
	gs.skip_draw = headless && (next_shot >= len(shots) || frame < shots[next_shot] - SHOT_WARMUP)
}

// One controller per player; a player keeps their slot until the pad is
// unplugged, and a new pad takes the lowest free slot. The keyboard and
// NT_PRESS always feed player 1.
@(private = "file")
controllers: [ee.MAX_PLAYERS]^sdl.GameController

// Last rumble sent per player, re-sent before SDL's duration runs out.
@(private = "file")
rumble: [ee.MAX_PLAYERS]struct {
	small, large: u8,
	at:           u64,
}
@(private = "file")
RUMBLE_MS :: 1000

@(private = "file")
controller_add :: proc(device: i32) {
	id := sdl.JoystickGetDeviceInstanceID(device)
	for c in controllers {
		if c != nil && sdl.JoystickInstanceID(sdl.GameControllerGetJoystick(c)) == id {return}
	}
	for &c, i in controllers {
		if c != nil {continue}
		c = sdl.GameControllerOpen(device)
		if c == nil {return}
		sdl.GameControllerSetPlayerIndex(c, i32(i)) // player LEDs where the pad has them
		rumble[i] = {}
		ee.pads[i].connected = true
		fmt.eprintfln("input: player %d: %s", i + 1, sdl.GameControllerName(c))
		return
	}
	fmt.eprintln("input: ignoring controller, all players taken:", sdl.GameControllerNameForIndex(device))
}

@(private = "file")
controller_remove :: proc(id: sdl.JoystickID) {
	for &c, i in controllers {
		if c == nil || sdl.JoystickInstanceID(sdl.GameControllerGetJoystick(c)) != id {continue}
		sdl.GameControllerClose(c)
		c = nil
		ee.pads[i].connected = i == 0 || i < forced_players
		ee.pads[i].buttons = {}
		ee.pads[i].axes = {0x80, 0x80, 0x80, 0x80}
		fmt.eprintfln("input: player %d unplugged", i + 1)
	}
}

// NT_PLAYERS=n: players 1..n count as plugged in without a controller, so
// headless runs can exercise the multitap.
@(private = "file")
forced_players: int

// Keyboard: arrows, Z cross, X circle, A square, S triangle, Return start,
// right shift select, Q/W L1/R1, 1/2 L2/R2. A game controller adds to that.
@(private = "file")
KEYS := [?]struct {
	key: sdl.Scancode,
	btn: ee.Pad_Button,
}{
	{.UP, .Up}, {.DOWN, .Down}, {.LEFT, .Left}, {.RIGHT, .Right},
	{.Z, .Cross}, {.X, .Circle}, {.A, .Square}, {.S, .Triangle},
	{.RETURN, .Start}, {.RSHIFT, .Select}, {.Q, .L1}, {.W, .R1}, {.NUM1, .L2}, {.NUM2, .R2},
}

@(private = "file")
BUTTONS := [?]struct {
	b:   sdl.GameControllerButton,
	btn: ee.Pad_Button,
}{
	{.DPAD_UP, .Up}, {.DPAD_DOWN, .Down}, {.DPAD_LEFT, .Left}, {.DPAD_RIGHT, .Right},
	{.A, .Cross}, {.B, .Circle}, {.X, .Square}, {.Y, .Triangle},
	{.START, .Start}, {.BACK, .Select}, {.LEFTSHOULDER, .L1}, {.RIGHTSHOULDER, .R1},
	{.LEFTSTICK, .L3}, {.RIGHTSTICK, .R3},
}

@(private = "file")
input_poll :: proc() {
	keys := sdl.GetKeyboardState(nil)
	now := u64(sdl.GetTicks())
	for c, i in controllers {
		pad := &ee.pads[i]
		set: bit_set[ee.Pad_Button; u16]
		axes := [4]u8{0x80, 0x80, 0x80, 0x80}
		if i == 0 {
			for k in KEYS {if keys[k.key] != 0 {set += {k.btn}}}
		}
		if c != nil {
			for b in BUTTONS {if sdl.GameControllerGetButton(c, b.b) != 0 {set += {b.btn}}}
			if sdl.GameControllerGetAxis(c, .TRIGGERLEFT) > 16384 {set += {.L2}}
			if sdl.GameControllerGetAxis(c, .TRIGGERRIGHT) > 16384 {set += {.R2}}
			STICKS := [4]sdl.GameControllerAxis{.RIGHTX, .RIGHTY, .LEFTX, .LEFTY}
			for a, j in STICKS {
				axes[j] = u8((i32(sdl.GameControllerGetAxis(c, a)) + 32768) >> 8)
			}
			// Large motor: low-frequency rumble at the game's speed; small
			// motor: high-frequency, on or off.
			r := &rumble[i]
			on := pad.small != 0 || pad.large != 0
			if pad.small != r.small || pad.large != r.large || (on && now - r.at > RUMBLE_MS / 2) {
				r.small, r.large, r.at = pad.small, pad.large, now
				_ = sdl.GameControllerRumble(c, u16(pad.large) * 257, 0xffff if pad.small != 0 else 0, RUMBLE_MS)
			}
		}
		for p in presses {
			if p.player == i && frame >= p.frame && frame < p.frame + p.hold {set += {p.btn}}
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
		pad.buttons = set
		pad.axes = axes
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
