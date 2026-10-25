// Host audio (ps:core audio.odin): the FMOD and SPU2 voice mixers fill one
// vblank of sound, which core queues on the SDL device. NT_WAV=<file> also
// records the mix, for headless checks; core keeps the file valid at every
// second, since a timed-out run never exits cleanly.
package main

import "core:os"
import "ps:core"
import "ee"

AUDIO_FRAME :: ee.MIX_RATE / 60 // stereo frames per vblank
@(private = "file")
LATENCY_MS :: 50

audio_init :: proc(headless: bool) {
	wav, _ := os.lookup_env("NT_WAV", context.temp_allocator)
	// Headless runs are unpaced: a device queue would drop the mix.
	core.audio_init(ee.MIX_RATE, wav, !headless)
	if !headless {core.audio_apply(LATENCY_MS)}
}

// Mix exactly one vblank: the game polls voice positions, so how far the
// voices advance must not depend on the host. Core pads or drops on the
// device side instead.
audio_frame :: proc() {
	buf := make([][2]i16, AUDIO_FRAME, context.temp_allocator)
	t := ee.prof_start()
	ee.fmod_mix(([^]i16)(raw_data(buf))[:AUDIO_FRAME * 2])
	ee.spu_mix(([^]i16)(raw_data(buf))[:AUDIO_FRAME * 2])
	ee.prof_end(.MIX, t)
	core.audio_push(buf)
}
