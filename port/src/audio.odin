// Host audio (ps:core audio.odin): the FMOD and SPU2 voice mixers fill one
// vblank of sound, which core queues on the SDL device. NT_WAV=<file> also
// records the mix, for headless checks; core keeps the file valid at every
// second, since a timed-out run never exits cleanly.
package main

import "core:os"
import "ps:core"
import cpu "ps:ps2/cpu"
import iop "ps:ps2/iop"

AUDIO_FRAME :: iop.MIX_RATE / 60 // stereo frames per vblank
@(private = "file")
LATENCY_MS :: 50

audio_init :: proc(headless: bool) {
	wav, _ := os.lookup_env("NT_WAV", context.temp_allocator)
	// Headless runs are unpaced: a device queue would drop the mix.
	core.audio_init(iop.MIX_RATE, wav, !headless)
	if !headless {core.audio_apply(LATENCY_MS)}
}

// Mix exactly one vblank: the game polls voice positions, so how far the
// voices advance must not depend on the host. Core pads or drops on the
// device side instead. A netplay rerun mixes without pushing.
audio_frame :: proc(push: bool) {
	buf := make([][2]i16, AUDIO_FRAME, context.temp_allocator)
	t := cpu.prof_start()
	iop.fmod_mix(([^]i16)(raw_data(buf))[:AUDIO_FRAME * 2])
	iop.spu_mix(([^]i16)(raw_data(buf))[:AUDIO_FRAME * 2])
	cpu.prof_end(.MIX, t)
	if push {core.audio_push(buf)}
}
