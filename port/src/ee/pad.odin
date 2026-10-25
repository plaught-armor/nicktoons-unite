// HLE padman (new libpad, sid 0x80000100) and mtapman (libmtap, sid
// 0x80000900). Open hands over a 256-byte DMA area in EE RAM: two 128-byte
// pad_data frames, of which libpad reads the one with the higher frame
// counter. pad_update rewrites both every vblank.
//
// Player 1 is port 0 slot 0. With more than one player a multitap sits in
// port 0 and players 2..4 are its slots 1..3, which the game sees once it
// has opened the tap (mtap port 2).
package ee

import "core:fmt"

// Host input in PS2 wire order: buttons are the active-high form of pad
// data bytes 2..3 (byte 2 in the low half), axes are rx, ry, lx, ly.
Pad_Button :: enum u16 {
	Select, L3, R3, Start, Up, Right, Down, Left,
	L2, R2, L1, R1, Triangle, Circle, Cross, Square,
}

MAX_PLAYERS :: 4

Pad :: struct {
	connected: bool, // set by the host; player 1 always is
	buttons:   bit_set[Pad_Button; u16],
	axes:      [4]u8,
	// Motor levels the game asked for (SetActDirect): small is on/off,
	// large an 8-bit speed. The host drives rumble from these.
	small:     u8,
	large:     u8,
}

pads: [MAX_PLAYERS]Pad

@(private = "file")
pad_area: [2][4]u32 // per port and slot; 0 = closed

// Actuator align per player (SetActAlign): which actuator each byte of a
// SetActDirect drives, 0xff for none.
@(private = "file")
act_align: [MAX_PLAYERS][6]u8

@(private = "file")
mtap: struct {
	status: u32, // EE address of the 128-byte connection table (fno 6)
	open:   [4]bool, // libmtap ports; 2 and 3 are the taps in pad ports 0 and 1
}

PAD_STATE_STABLE :: 6
PAD_MODE_DUALSHOCK :: 0x73 // id 7, 3 halfwords of data

// pad_data field offsets, as read by the game's libpad (0x3e2358 picks the
// frame, 0x3e2528 GetState, 0x3e27e0 InfoMode).
@(private = "file") PD_DATA :: 0x00
@(private = "file") PD_ACT_DATA :: 0x30 // 4 bytes per actuator: func, sub, size, current
@(private = "file") PD_MODE_TABLE :: 0x50
@(private = "file") PD_FRAME :: 0x58
@(private = "file") PD_LENGTH :: 0x60
@(private = "file") PD_MODE_CONFIG :: 0x64
@(private = "file") PD_MODE_CUR_ID :: 0x65
@(private = "file") PD_MODEL :: 0x66
@(private = "file") PD_READY :: 0x67
@(private = "file") PD_NR_MODES :: 0x68
@(private = "file") PD_MODE_CUR_OFFS :: 0x69
@(private = "file") PD_NR_ACTS :: 0x6a // the game keeps room for 6
@(private = "file") PD_NR_ACT_COMB :: 0x6b
@(private = "file") PD_STATE :: 0x70 // u8
@(private = "file") PD_REQ_STATE :: 0x71 // u8, 2 = busy
@(private = "file") PD_OK :: 0x72 // u8, 1 once mode info is valid

// Pressure bytes 8..19 in order: right, left, up, down, triangle, circle,
// cross, square, L1, R1, L2, R2.
@(private = "file")
PRESSURE := [12]Pad_Button{.Right, .Left, .Up, .Down, .Triangle, .Circle, .Cross, .Square, .L1, .R1, .L2, .R2}

@(private = "file")
pad_frame: u32

pad_init :: proc() {
	for &p in pads {p.axes = {0x80, 0x80, 0x80, 0x80}}
	pads[0].connected = true
	for &a in act_align {a = 0xff}
}

// The multitap is plugged in while more than one player is.
@(private = "file")
tap_present :: proc() -> bool {
	for p in pads[1:] {if p.connected {return true}}
	return false
}

// Player on a port and slot, or -1 for an empty socket.
@(private = "file")
pad_player :: proc(port, slot: u32) -> int {
	if port != 0 {return -1}
	if slot == 0 {return 0}
	if !tap_present() || !mtap.open[2] || !pads[slot].connected {return -1}
	return int(slot)
}

// Writes the current host input into every open pad area, and the
// multitap connection table.
pad_update :: proc() {
	pad_frame += 1
	for port in u32(0) ..< 2 {
		for slot in u32(0) ..< 4 {
			addr := pad_area[port][slot]
			if addr == 0 {continue}
			player := pad_player(port, slot)
			for half in u32(0) ..< 2 {
				pad_fill(ram_slice(addr + half * 128, 128), pad_frame * 2 + half, player)
			}
		}
	}
	if mtap.status != 0 {
		t := ([^]u32)(raw_data(ram_slice(mtap.status, 128)))
		t[0] = 1 // table valid
		t[6] = 1 if tap_present() else 0 // tap in pad port 0
		t[7] = 0 // pad port 1
	}
}

// An empty socket keeps its frame counter running with state 0
// (disconnected), so a pad pulled out mid-game reads as gone.
@(private = "file")
pad_fill :: proc(p: []u8, frame: u32, player: int) {
	w32 :: proc(p: []u8, o: int, v: u32) {(^u32)(&p[o])^ = v}
	w16 :: proc(p: []u8, o: int, v: u16) {(^u16)(&p[o])^ = v}
	if player < 0 {
		for &b in p {b = 0}
		w32(p, PD_FRAME, frame)
		return
	}
	pad := &pads[player]
	d := p[PD_DATA:][:32]
	d[0] = 0
	d[1] = PAD_MODE_DUALSHOCK
	w16(d, 2, ~transmute(u16)pad.buttons)
	copy(d[4:8], pad.axes[:])
	for b, i in PRESSURE {d[8 + i] = 0xff if b in pad.buttons else 0}
	// DualShock 2 motors: small (on/off) and large (8-bit speed).
	copy(p[PD_ACT_DATA:][:8], []u8{1, 0, 0, 1, 1, 1, 1, 10})
	w16(p, PD_MODE_TABLE + 0, 4)
	w16(p, PD_MODE_TABLE + 2, 7)
	w32(p, PD_FRAME, frame)
	w32(p, PD_LENGTH, 20)
	p[PD_MODE_CONFIG] = 2 // 1 = no mode info yet, 2+ = modes and actuators known
	p[PD_MODE_CUR_ID] = PAD_MODE_DUALSHOCK
	p[PD_MODEL] = 3 // DualShock 2
	p[PD_READY] = 1
	p[PD_NR_MODES] = 2
	p[PD_MODE_CUR_OFFS] = 1
	p[PD_NR_ACTS] = 2
	p[PD_NR_ACT_COMB] = 0
	p[PD_STATE] = PAD_STATE_STABLE
	p[PD_REQ_STATE] = 0
	p[PD_OK] = 1
}

// padman: the command is the first word of the request, the result goes in
// the fourth word of the reply.
@(private)
padman_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	cmd := w[0]
	switch cmd {
	case 0x00000001, 0x80000100: // Open {cmd, port, slot, ?, pad data}
		if k.debug >= 1 {fmt.eprintfln("pad: open port %d slot %d data %08x", w[1], w[2], w[4])}
		if w[1] < 2 && w[2] < 4 {
			pad_area[w[1]][w[2]] = w[4]
			pad_update()
		}
		w[3] = 1
	case 0x0e, 0x8000010d: // Close {cmd, port, slot}
		if w[1] < 2 && w[2] < 4 {pad_area[w[1]][w[2]] = 0}
		w[3] = 1
	case 0x80000105, 0x10: // SetMainMode (old protocol), Init
		w[3] = 1
	// SetMainMode {cmd, port, slot, mode, lock}: the pad stays a DualShock in
	// analog mode either way. libpad marks the request busy until the next
	// pad_update clears reqState.
	case 0x06: w[5] = 1
	case 0x07, 0x08: // SetActDirect, SetActAlign {cmd, port, slot, u8[6]}
		w[5] = 1
		player := pad_player(w[1], w[2]) if w[1] < 2 && w[2] < 4 else -1
		if player < 0 {break}
		b := buf[12:18]
		if cmd == 0x08 {
			copy(act_align[player][:], b)
			break
		}
		pad := &pads[player]
		pad.small, pad.large = 0, 0
		for a, i in act_align[player] {
			switch a {
			case 0: pad.small = b[i]
			case 1: pad.large = b[i]
			}
		}
	case 0x12: w[3] = 0x400 // GetModuleVersion
	case:
		fmt.eprintfln("pad: unhandled command %08x", cmd)
		w[3] = 0
	}
	return true
}

// mtapman: arguments and results are words of the 128-byte buffer.
@(private)
mtap_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	switch fno {
	case 1, 2: // PortOpen, PortClose {port} -> w[1]
		if w[0] < 4 {mtap.open[w[0]] = fno == 1}
		w[1] = 1
	case 5: w[0] = 0x310 // version; libmtap wants 0x31x
	case 6: // connection table address {_, addr}
		mtap.status = w[1]
		pad_update()
		w[0] = 1
	case:
		fmt.eprintfln("mtap: unhandled fno %d", fno)
		w[0] = 0
	}
	return true
}

// Emulated state, saved and restored by snapshots (snap.odin).
@(private)
pad_snap :: proc() {
	snap_add(&pad_area)
	snap_add(&act_align)
	snap_add(&mtap)
	snap_add(&pad_frame)
}
