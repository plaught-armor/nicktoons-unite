// SPU2 voices behind sdrdrv, Sony's libsd RPC server (libsdr on the EE).
//
// The game drives raw voices through it only for movie sound: two voices of
// core 0 play stereo SPU ADPCM from looping rings in sound RAM, which the
// game refills by polling each voice's playback address (NAX). So this
// models what that needs: sound RAM, voice transfers, ADPCM playback with
// the block loop flags, pitch, volume and key on/off. Envelopes are taken as
// instant attack with a held sustain, and key off as an instant release.
//
// Voices advance by the samples spu_mix renders, the same clock the FMOD
// voices run on.
package ee

import "core:fmt"
import "ps:core"

SPU_RAM_SIZE :: 2 << 20

@(private = "file")
Spu_Voice :: struct {
	on:         bool,
	ssa, lsa:   u32, // byte addresses in sound RAM
	nax:        u32, // the block playing
	flags:      u8, // its loop flags
	pcm:        [28]i16, // its samples
	idx:        u32, // the sample playing in it
	frac:       u32, // 4.12, as PITCH
	prev:       i32, // the sample before idx, for interpolation
	hist:       [2]i32, // ADPCM predictor history
	pitch:      u32,
	voll, volr: i32,
}

@(private = "file")
spu: struct {
	ram:   []u8,
	voice: [2][24]Spu_Voice,
}

// libsd parameter and address ids; the low bits name core and voice.
@(private = "file")
SD_VP_VOLL :: 0x0000
@(private = "file")
SD_VP_VOLR :: 0x0100
@(private = "file")
SD_VP_PITCH :: 0x0200
@(private = "file")
SD_S_KON :: 0x1500
@(private = "file")
SD_S_KOFF :: 0x1600
@(private = "file")
SD_VA_SSA :: 0x2040
@(private = "file")
SD_VA_LSAX :: 0x2140
@(private = "file")
SD_VA_NAX :: 0x2240

@(private = "file")
spu_voice :: proc(id: u32) -> ^Spu_Voice {
	return &spu.voice[id & 1][min((id >> 1) & 31, 23)]
}

// Decode the block at v.nax, taking its loop start flag.
@(private = "file")
spu_block :: proc(v: ^Spu_Voice) {
	F := [5][2]i32{{0, 0}, {60, 0}, {115, -52}, {98, -55}, {122, -60}}
	b := spu.ram[v.nax & (SPU_RAM_SIZE - 16):][:16]
	shift := u32(b[0] & 15)
	f := min(int(b[0] >> 4), 4)
	v.flags = b[1]
	if v.flags & 4 != 0 {v.lsa = v.nax}
	for n in 0 ..< 28 {
		nib := (b[2 + n / 2] >> (u32(n & 1) * 4)) & 15
		s := i32(i16(u16(nib) << 12)) >> shift
		s += (v.hist[0] * F[f][0] + v.hist[1] * F[f][1] + 32) >> 6
		s = clamp(s, -32768, 32767)
		v.hist[1], v.hist[0] = v.hist[0], s
		v.pcm[n] = i16(s)
	}
}

@(private = "file")
spu_key_on :: proc(v: ^Spu_Voice) {
	v.on = true
	v.nax, v.lsa = v.ssa, v.ssa
	v.idx, v.frac, v.prev, v.hist = 0, 0, 0, {}
	spu_block(v)
}

// One sample of a playing voice, then advance it by its pitch.
@(private = "file")
spu_sample :: proc(v: ^Spu_Voice) -> i32 {
	cur := i32(v.pcm[v.idx])
	s := v.prev + (cur - v.prev) * i32(v.frac) / 0x1000
	v.frac += v.pitch
	for v.frac >= 0x1000 && v.on {
		v.frac -= 0x1000
		v.prev = i32(v.pcm[v.idx])
		v.idx += 1
		if v.idx < 28 {continue}
		v.idx = 0
		switch {
		case v.flags & 1 == 0: v.nax += 16
		case v.flags & 2 != 0: v.nax = v.lsa
		case: // end without repeat: the voice stops
			v.on = false
			return s
		}
		spu_block(v)
	}
	return s
}

// Add the voices to interleaved stereo at MIX_RATE, the SPU2 output rate.
spu_mix :: proc(out: []i16) {
	for &core in spu.voice {
		for &v in core {
			if !v.on {continue}
			for n := 0; n < len(out); n += 2 {
				if !v.on {break}
				s := spu_sample(&v)
				out[n] = i16(clamp(i32(out[n]) + s * v.voll >> 14, -32768, 32767))
				out[n + 1] = i16(clamp(i32(out[n + 1]) + s * v.volr >> 14, -32768, 32767))
			}
		}
	}
}

// A volume register: fixed volumes are 15-bit signed; sweeps (bit 15) are
// taken at full scale.
@(private = "file")
spu_volume :: proc(r: u32) -> i32 {
	if r & 0x8000 != 0 {return 0x3fff}
	return i32(i16(u16(r << 1))) >> 1
}

// sdrdrv: {?, args...} in, the result in the first word out.
@(private)
sdr_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	r: u32 = 0
	switch fno {
	case 0x8000: // sceSdInit
		if spu.ram == nil {spu.ram = make([]u8, SPU_RAM_SIZE)}
		for &core in spu.voice {for &v in core {v = {}}}
	case 0x8010: // sceSdSetParam {id, value}
		v := spu_voice(w[1])
		switch w[1] & 0xff00 {
		case SD_VP_VOLL: v.voll = spu_volume(w[2])
		case SD_VP_VOLR: v.volr = spu_volume(w[2])
		case SD_VP_PITCH: v.pitch = min(w[2] & 0xffff, 0x3fff)
		}
	case 0x8030: // sceSdSetSwitch {id, voice mask}
		core := &spu.voice[w[1] & 1]
		for i in 0 ..< 24 {
			if w[2] & (1 << u32(i)) == 0 {continue}
			switch w[1] & 0xff00 {
			case SD_S_KON: spu_key_on(&core[i])
			case SD_S_KOFF: core[i].on = false
			}
		}
	case 0x8050: // sceSdSetAddr {id, address}
		v := spu_voice(w[1])
		switch w[1] & 0xff00 {
		case SD_VA_SSA & 0xff00: v.ssa = w[2] & (SPU_RAM_SIZE - 16)
		case SD_VA_LSAX & 0xff00: v.lsa = w[2] & (SPU_RAM_SIZE - 16)
		}
	case 0x8060: // sceSdGetAddr {id}
		v := spu_voice(w[1])
		switch w[1] & 0xff00 {
		case SD_VA_SSA & 0xff00: r = v.ssa
		case SD_VA_LSAX & 0xff00: r = v.lsa
		case SD_VA_NAX & 0xff00: r = v.nax
		}
	case 0x80d0: // sceSdVoiceTrans {channel, mode, IOP address, SPU address, size}
		if spu.ram == nil {spu.ram = make([]u8, SPU_RAM_SIZE)}
		src, dst, size := w[3] & (IOP_RAM_SIZE - 1), w[4] & (SPU_RAM_SIZE - 1), w[5]
		size = min(size, IOP_RAM_SIZE - src, SPU_RAM_SIZE - dst)
		if w[2] & 1 == 0 {
			copy(spu.ram[dst:][:size], iop_ram[src:][:size])
		} else {
			copy(iop_ram[src:][:size], spu.ram[dst:][:size])
		}
		r = size
	case 0x80f0: // sceSdVoiceTransStatus {channel, flag}: always complete
		r = 1
	case:
		if k.debug >= 1 {fmt.eprintfln("sdr: unhandled fno %x", fno)}
	}
	for &b in buf[:64] {b = 0}
	w[0] = r
	return true
}

// Emulated state, saved and restored by snapshots (snap.odin).
@(private)
spu_snap :: proc() {
	core.snap_add(&spu)
}
