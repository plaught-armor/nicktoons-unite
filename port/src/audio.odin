// Host audio: a queued SDL device fed by the FMOD and SPU2 voice mixers once per
// vblank. NT_WAV=<file> also records the mix, for headless checks; the file
// is valid at every second, since a timed-out run never exits cleanly.
package main

import "core:fmt"
import "core:os"
import sdl "vendor:sdl2"
import "ee"

@(private = "file")
dev: sdl.AudioDeviceID
@(private = "file")
wav: ^os.File
@(private = "file")
wav_bytes: u32
@(private = "file")
wav_frames: int

AUDIO_FRAME :: ee.MIX_RATE / 60 // stereo frames per vblank
@(private = "file")
QUEUE_LOW :: AUDIO_FRAME * 3 // keep about 50 ms queued
@(private = "file")
QUEUE_HIGH :: AUDIO_FRAME * 6

audio_init :: proc(headless: bool) {
	if path, ok := os.lookup_env("NT_WAV", context.temp_allocator); ok {
		f, err := os.create(path)
		if err == nil {wav = f; wav_header()}
	}
	if headless {return} // unpaced: a device queue would drop the mix
	want := sdl.AudioSpec {
		freq     = ee.MIX_RATE,
		format   = sdl.AUDIO_S16SYS,
		channels = 2,
		samples  = 1024,
	}
	dev = sdl.OpenAudioDevice(nil, false, &want, nil, {})
	if dev == 0 {
		fmt.eprintln("audio:", sdl.GetError())
		return
	}
	sdl.PauseAudioDevice(dev, false)
}

// Mix exactly one vblank: the game polls voice positions, so how far the
// voices advance must not depend on the host. The device queue is kept
// between QUEUE_LOW and QUEUE_HIGH by padding with silence or dropping the
// frame instead.
audio_frame :: proc() {
	buf := make([]i16, AUDIO_FRAME * 2, context.temp_allocator)
	t := ee.prof_start()
	ee.fmod_mix(buf)
	ee.spu_mix(buf)
	ee.prof_end(.MIX, t)
	if dev != 0 {
		queued := int(sdl.GetQueuedAudioSize(dev)) / 4
		if queued < QUEUE_LOW {
			pad := make([]i16, (QUEUE_LOW - queued) * 2, context.temp_allocator)
			sdl.QueueAudio(dev, raw_data(pad), u32(len(pad) * 2))
		}
		if queued < QUEUE_HIGH {sdl.QueueAudio(dev, raw_data(buf), u32(len(buf) * 2))}
	}
	if wav != nil {
		os.write_at(wav, ([^]u8)(raw_data(buf))[:len(buf) * 2], i64(44 + wav_bytes))
		wav_bytes += u32(len(buf) * 2)
		wav_frames += 1
		if wav_frames % 60 == 0 {wav_header()}
	}
}

@(private = "file")
wav_header :: proc() {
	hdr := [11]u32 {
		0x46464952, // "RIFF"
		36 + wav_bytes,
		0x45564157, // "WAVE"
		0x20746d66, // "fmt "
		16,
		1 | 2 << 16, // PCM, stereo
		ee.MIX_RATE,
		ee.MIX_RATE * 4,
		4 | 16 << 16, // block align, bits per sample
		0x61746164, // "data"
		wav_bytes,
	}
	os.write_at(wav, ([^]u8)(&hdr)[:44], 0)
}
