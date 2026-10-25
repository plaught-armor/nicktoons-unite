// FMOD 3.73 for PS2, high-level: FMOD.IRX is replaced by Odin.
//
// The EE library talks to FMOD.IRX over user SIF command channels rather
// than RPC: 0x60-byte packets {header, size, op, wait, channel, data...},
// optionally preceded by a DMA of bulk data into IOP memory. The IOP answers
// a waiting command on the same cid with op -1, the result at +0x20 and 0x30
// bytes of extra info at +0x28. Some packets go the other way: after each
// FSOUND_Update the IOP sends op 0x1b, which the EE waits for before it
// sends the next update, and a non-blocking FMUSIC_LoadSongEx completes with
// op 0x89 per sample and op 0x88 for the song.
//
// Samples live here as decoded PCM; the EE sees opaque handles. Voices are
// driven by the channel block each FSOUND_Update DMAs over, and fmod_mix
// renders them for the host.
package ee

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

FMOD_HEAP_START :: 0x00400000
FMOD_HEAP_END :: IOP_RAM_SIZE
MIX_RATE :: 48000

@(private = "file")
Block :: struct {
	addr, size: u32,
}

// FMOD's IOP memory pool (ops 0x7d/0x7e): first fit over the top of IOP RAM.
@(private = "file")
heap: [dynamic]Block // used blocks, sorted by address

@(private = "file")
heap_alloc :: proc(size: u32) -> u32 {
	size := (size + 63) &~ 63
	at := u32(FMOD_HEAP_START)
	for b, i in heap {
		if b.addr - at >= size {
			inject_at(&heap, i, Block{at, size})
			return at
		}
		at = b.addr + b.size
	}
	if FMOD_HEAP_END - at < size {return 0}
	append(&heap, Block{at, size})
	return at
}

@(private = "file")
heap_free :: proc(addr: u32) {
	for b, i in heap {
		if b.addr == addr {ordered_remove(&heap, i); return}
	}
}

@(private = "file")
heap_used :: proc() -> (n: u32) {
	for b in heap {n += b.size}
	return
}

// FSOUND_* mode bits.
FSOUND_LOOP_OFF :: 0x1
FSOUND_LOOP_NORMAL :: 0x2
FSOUND_LOOP_BIDI :: 0x4
FSOUND_LOADMEMORY :: 0x8000
FSOUND_VAG :: 0x800000
FSOUND_NONBLOCKING :: 0x1000000

Sample :: struct {
	name:       string,
	pcm:        []i16, // interleaved; nil for a stream subsound not loaded
	frames:     u32,
	channels:   int,
	mode:       u32,
	freq:       i32,
	vol, pan:   u8,
	pri:        u16,
	loop_start: u32,
	loop_end:   u32, // inclusive
}

// A bank loaded with FMUSIC_LoadSongEx: an FSB whose samples get handles.
@(private = "file")
Song :: struct {
	samples: []u32, // sample handles
}

// FSOUND_Stream_Open of an FSB: each subsound is a sample handle, decoded
// when it is played, so only one of a bank of long tracks is in memory.
@(private = "file")
Stream :: struct {
	ee:      u32, // the EE's FSOUND_STREAM
	name:    string, // file, or "" for LOADMEMORY at mem
	mem:     u32,
	mode:    u32,
	offset:  u32, // bank position in the file
	subs:    []Fsb_Entry,
	handles: []u32, // per subsound
	sub:     int, // current subsound
	channel: int, // voice playing it, or -1
}

// Handles the EE sees are a slot index tagged with the table they index;
// 0 means failure.
@(private = "file")
SAMPLE_TAG :: 0x5a000000
@(private = "file")
SONG_TAG :: 0x5b000000
@(private = "file")
STREAM_TAG :: 0x5c000000
@(private = "file")
samples: [dynamic]^Sample
@(private = "file")
songs: [dynamic]^Song
@(private = "file")
streams: [dynamic]^Stream

// One per EE channel slot in the update block.
@(private = "file")
Voice :: struct {
	sample:   ^Sample,
	pos:      u64, // 32.32 frames
	freq:     i32,
	vol:      u8,
	pan:      u8,
	loop:     u32, // FSOUND_LOOP_* override, 0 for the sample's
	playing:  bool,
	paused:   bool,
	muted:    bool,
}

MAX_VOICES :: 64

@(private = "file")
voices: [MAX_VOICES]Voice
@(private = "file")
num_voices: int
@(private = "file")
sfx_volume: i32 = 255

@(private = "file")
fmod_log :: proc(op: u32, wait: u32, p: [^]u32) {
	if k.debug < 1 {return}
	@(static) count: map[u32]int
	count[op] += 1
	if count[op] > 6 {return}
	fmt.eprintfln("fmod: op %x wait %d  %08x %08x %08x %08x %08x %08x %08x", op, wait,
		p[0], p[1], p[2], p[3], p[4], p[5], p[6])
}

@(private)
fmod_command :: proc(cid, opt, a: u32) {
	FMOD_INIT :: 0xfffffffe
	FMOD_VERSION :: 0x03730004 // FMOD 3.73.04; the EE library checks it
	op, wait := iop_u32(a + 0x14)^, iop_u32(a + 0x18)^
	p := ([^]u32)(&iop_ram[a + 0x20]) // payload
	fmod_log(op, wait, p)
	reply: [20]u32 // packet bytes 0x10..0x60
	info := reply[6:] // 0x30 bytes at +0x28
	result: u32
	switch op {
	case 0xfffffffd: result = 0x36ef0 // IOP-side structure size; only stored
	case FMOD_INIT: result = FMOD_VERSION
	case 0x00: // Init {rate, max software channels, flags, hardware channels, ...}
		num_voices = min(int(p[1] + p[3]), MAX_VOICES)
		result = 1
	case 0x01: // Close
		for st in streams {if st != nil {stream_destroy(st)}}
		clear(&streams)
		voices = {}
		for s in samples {if s != nil {sample_destroy(s)}}
		clear(&samples)
		clear(&songs)
	case 0x02: // speaker mode
	case 0x03: sfx_volume = clamp(i32(p[0]), 0, 255)
	case 0x08: result = 0 // memory stats
	case 0x09: result = sample_load(p[0], p[1], p[2], p[3], p[4])
	case 0x0b: sample_free(p[0])
	case 0x0f: // Sample_SetMode(sample, mode): the loop mode; no reply
		if s := sample_get(p[0]); s != nil {
			if loop := p[1] & 7; loop != 0 {s.mode = s.mode &~ 7 | loop}
		}
	case 0x14: // Sample_GetName(handle)
		if s := sample_get(p[0]); s != nil {
			copy(([^]u8)(raw_data(info))[:0x2f], s.name)
			result = 1
		}
	case 0x1b: fmod_update(cid, opt, p)
	case 0x1c: result = stream_open(cid, opt, p)
	case 0x1e: result = stream_play(p)
	case 0x1f: // Stream_Stop
		if st := stream_get(p[0]); st != nil {
			stream_stop(st)
			result = 1
		}
	case 0x20: // Stream_Close
		if st := stream_get(p[0]); st != nil {
			stream_destroy(st)
			streams[p[0] &~ 0xff000000] = nil
			result = 1
		}
	case 0x25: result = 1 // stream buffer size
	case 0x29: // Stream_GetTime, ms
		if st := stream_get(p[0]); st != nil && st.channel >= 0 {
			s := voices[st.channel].sample
			if s != nil && s.freq > 0 {result = u32((voices[st.channel].pos >> 32) * 1000 / u64(s.freq))}
		}
	case 0x3c: result = 1 // stream sync points: unused
	case 0x3d: result = song_load(cid, opt, p)
	case 0x3e: song_free(p[0]); result = 1
	case 0x60: result = FMOD_HEAP_END - FMOD_HEAP_START
	case 0x61: result = FMOD_HEAP_END - FMOD_HEAP_START - heap_used()
	case 0x63: result = 1 // lock the DMA channel
	case 0x64: result = 1 // EE -> IOP transfer: the DMA already landed
	case 0x7d, 0x7f: result = heap_alloc(p[0])
	case 0x7e: heap_free(p[0])
	case 0x53: // Stream_GetSample(stream, subsound)
		if st := stream_get(p[0]); st != nil && int(p[1]) < len(st.handles) {result = st.handles[p[1]]}
	case 0x68: // Stream_SetSubStream(stream, index); completes with op 0x86
		if st := stream_get(p[0]); st != nil && int(p[1]) < len(st.subs) {
			stream_select(st, int(p[1]))
			status := stream_status(st, st.ee, p[0], 0)
			send_later(cid, opt, 0x86, status[:])
			result = 1
		}
	case 0x76: // Stream_SetMode(stream, mode): the loop mode
		if st := stream_get(p[0]); st != nil {
			if loop := p[1] & 7; loop != 0 {
				for e in st.subs {e.sample.mode = e.sample.mode &~ 7 | loop}
			}
			result = 1
		}
	case 0x80: result = 0
	case 0x85: // stream info: info[5..10] land at EE stream +0x14..+0x28
		// {open state, sample handle, mode, bytes, ms, subsounds}
		if st := stream_get(p[0]); st != nil {
			pkt := stream_status(st, st.ee, p[0], 0)
			info[5], info[6], info[7] = 0, pkt[6], pkt[3]
			info[8], info[9], info[10] = pkt[4], pkt[5], u32(len(st.subs))
			result = 1
		}
	case 0x8d: // SetPaused(FSOUND_ALL, paused byte)
		paused := ([^]u8)(p)[0] != 0
		for &v in voices {v.paused = paused}
		result = 1
	case 0x84: // sample info
		if s := sample_get(p[0]); s != nil {
			sample_info(s, info)
			result = 1
		}
	case 0x87: // song info {open state, type, ..., sample count}
		if s := song_get(p[0]); s != nil {
			info[6] = u32(len(s.samples))
			result = 1
		}
	case:
		@(static) seen: map[u32]bool
		if !seen[op] {
			seen[op] = true
			fmt.eprintfln("fmod: unhandled op %x (wait %d)", op, wait)
		}
	}
	if op != FMOD_INIT && wait == 0 {return}
	reply[1] = 0xffffffff
	reply[4] = result
	sif_reply(cid, opt, reply[:])
}

// An IOP -> EE packet with up to 0x40 bytes of payload at +0x20.
@(private = "file")
send :: proc(cid, opt, op: u32, payload: []u32) {
	pkt: [20]u32
	pkt[0] = 0x60
	pkt[1] = op
	copy(pkt[4:], payload)
	sif_reply(cid, opt, pkt[:])
}

// Packets that complete an asynchronous request. They go out on the next
// vblank: the EE marks the request pending only after its command is sent,
// so an instant answer would be overwritten.
@(private = "file")
Pending :: struct {
	cid, opt, op: u32,
	payload:      [16]u32,
	n:            int,
}
@(private = "file")
pending: [dynamic]Pending

@(private = "file")
send_later :: proc(cid, opt, op: u32, payload: []u32) {
	p := Pending{cid = cid, opt = opt, op = op, n = len(payload)}
	copy(p.payload[:], payload)
	append(&pending, p)
}

fmod_vblank :: proc() {
	for &p in pending {send(p.cid, p.opt, p.op, p.payload[:p.n])}
	clear(&pending)
}

@(private = "file")
sample_get :: proc(h: u32) -> ^Sample {
	i := int(h &~ 0xff000000)
	if h & 0xff000000 != SAMPLE_TAG || i >= len(samples) {return nil}
	return samples[i]
}

@(private = "file")
song_get :: proc(h: u32) -> ^Song {
	i := int(h &~ 0xff000000)
	if h & 0xff000000 != SONG_TAG || i >= len(songs) {return nil}
	return songs[i]
}

@(private = "file")
stream_get :: proc(h: u32) -> ^Stream {
	i := int(h &~ 0xff000000)
	if h & 0xff000000 != STREAM_TAG || i >= len(streams) {return nil}
	return streams[i]
}

// The info block the EE caches per sample (IOP op 0x84). info[0] is not
// written: the async packets carry the handle there.
@(private = "file")
sample_info :: proc(s: ^Sample, info: []u32) {
	b := ([^]u8)(raw_data(info))
	info[1] = u32(s.freq)
	b[8], b[9] = s.vol, s.pan
	b[0xa] = u8(s.channels)
	b[0xb] = 0xff // max playbacks, signed: unlimited; 0 makes every PlaySoundEx fail
	(^u16)(&b[0x12])^ = s.pri
	info[5] = s.mode
	info[6] = s.frames
	info[7] = s.loop_start
	info[8] = s.loop_end
}

@(private = "file")
sample_add :: proc(s: ^Sample, index: u32 = 0xffffffff) -> u32 {
	slot := int(index)
	if index == 0xffffffff { // FSOUND_FREE
		slot = len(samples)
		for x, i in samples {if x == nil {slot = i; break}}
	}
	if slot >= len(samples) {resize(&samples, slot + 1)}
	if samples[slot] != nil {sample_destroy(samples[slot])}
	samples[slot] = s
	return u32(slot) | SAMPLE_TAG
}

@(private = "file")
sample_destroy :: proc(s: ^Sample) {
	for &v in voices {if v.sample == s {v = {}}}
	delete(s.pcm)
	delete(s.name)
	free(s)
}

@(private = "file")
sample_free :: proc(h: u32) {
	if s := sample_get(h); s != nil {
		sample_destroy(s)
		samples[h &~ 0xff000000] = nil
	}
}

// IOP memory, or the file named by an IOP string, at offset/length.
@(private = "file")
source_data :: proc(src, mode, offset, length: u32) -> ([]u8, bool) {
	if mode & FSOUND_LOADMEMORY != 0 {
		s := src & (IOP_RAM_SIZE - 1)
		return iop_ram[s:][:min(length, IOP_RAM_SIZE - s)], true
	}
	return file_data(iop_string(src), offset, length)
}

@(private = "file")
iop_string :: proc(a: u32) -> string {
	return string(cstring(&iop_ram[a & (IOP_RAM_SIZE - 1)]))
}

@(private = "file")
file_data :: proc(name: string, offset, length: u32) -> ([]u8, bool) {
	path, ok := host_path(name)
	if !ok {
		fmt.eprintfln("fmod: \"%s\" not found", name)
		return nil, false
	}
	f, err := os.open(path)
	if err != nil {return nil, false}
	defer os.close(f)
	n := i64(length)
	if n == 0 {
		size, _ := os.file_size(f)
		n = size - i64(offset)
	}
	buf := make([]u8, n, context.temp_allocator)
	got, _ := os.read_at(f, buf, i64(offset))
	return buf[:got], true
}

// FSOUND_Sample_Load(index, name or IOP address, mode, offset, length).
@(private = "file")
sample_load :: proc(index, src, mode, offset, length: u32) -> u32 {
	data, ok := source_data(src, mode, offset, length)
	if !ok {return 0}
	smp := fsb_load(data)
	defer delete(smp)
	if len(smp) == 0 {
		fmt.eprintfln("fmod: sample load: bad data at %x size %x", src, length)
		return 0
	}
	for s in smp[1:] {sample_destroy(s)}
	return sample_add(smp[0], index)
}

// FMUSIC_LoadSongEx {EE song, name or IOP address, offset, length, mode,
// sample list, list size}. A non-blocking load reports back with packets.
@(private = "file")
song_load :: proc(cid, opt: u32, p: [^]u32) -> u32 {
	ee_song, mode := p[0], p[4]
	h: u32
	song: ^Song
	if data, ok := source_data(p[1], mode, p[2], p[3]); ok {
		smp := fsb_load(data)
		defer delete(smp)
		if len(smp) > 0 {
			song = new(Song)
			song.samples = make([]u32, len(smp))
			for s, i in smp {song.samples[i] = sample_add(s)}
			slot := len(songs)
			for x, i in songs {if x == nil {slot = i; break}}
			if slot == len(songs) {append(&songs, song)} else {songs[slot] = song}
			h = u32(slot) | SONG_TAG
			if k.debug >= 1 {fmt.eprintfln("fmod: song %x: %d samples", h, len(smp))}
		}
	}
	if mode & FSOUND_NONBLOCKING == 0 {return h}
	if song != nil {
		for sh, i in song.samples {
			pkt: [11]u32
			sample_info(sample_get(sh), pkt[2:])
			pkt[0], pkt[1], pkt[2] = ee_song, u32(i), sh
			send_later(cid, opt, 0x89, pkt[:])
		}
	}
	// {EE song, IOP song, open state (0 ready, -1 error), ...}
	state: u32 = song != nil ? 0 : 0xffffffff
	n := u32(song != nil ? len(song.samples) : 0)
	send_later(cid, opt, 0x88, {ee_song, h, state, 0, 0, 0, 0, 0, n})
	return h
}

@(private = "file")
song_free :: proc(h: u32) {
	s := song_get(h)
	if s == nil {return}
	for sh in s.samples {sample_free(sh)}
	delete(s.samples)
	free(s)
	songs[h &~ 0xff000000] = nil
}

@(private = "file")
stream_read :: proc(st: ^Stream, offset, length: u32) -> ([]u8, bool) {
	if st.name == "" {
		s := (st.mem + offset) & (IOP_RAM_SIZE - 1)
		return iop_ram[s:][:min(length, IOP_RAM_SIZE - s)], true
	}
	return file_data(st.name, st.offset + offset, length)
}

// FSOUND_Stream_Open {EE stream, name or IOP address, mode, offset, length}.
// A non-blocking open answers op 0x1c with the handle, then op 0x86 when
// it is ready; the EE waits on its open state for the second.
@(private = "file")
stream_open :: proc(cid, opt: u32, p: [^]u32) -> u32 {
	ee_stream, src, mode := p[0], p[1], p[2]
	st := new(Stream)
	st.ee, st.mode, st.offset, st.channel = ee_stream, mode, p[3], -1
	if mode & FSOUND_LOADMEMORY != 0 {st.mem = src} else {st.name = strings.clone(iop_string(src))}
	h: u32
	if head, ok := stream_read(st, 0, 24); ok {
		if size := fsb_header_size(head); size > 0 {
			if hdr, ok2 := stream_read(st, 0, u32(size)); ok2 {
				entries := fsb_parse(hdr)
				st.subs = entries[:]
				st.handles = make([]u32, len(entries))
				for e, i in entries {st.handles[i] = sample_add(e.sample)}
			}
		}
	}
	if len(st.subs) > 0 {
		slot := len(streams)
		for x, i in streams {if x == nil {slot = i; break}}
		if slot == len(streams) {append(&streams, st)} else {streams[slot] = st}
		h = u32(slot) | STREAM_TAG
		if k.debug >= 1 {fmt.eprintfln("fmod: stream %x \"%s\": %d subsounds", h, st.name, len(st.subs))}
	} else {
		fmt.eprintfln("fmod: stream open failed: \"%s\" at %x", st.name, st.offset)
		stream_destroy(st)
		st = nil
	}
	if mode & FSOUND_NONBLOCKING != 0 {send_later(cid, opt, 0x1c, {ee_stream, h})}
	state: i16 = st != nil ? 0 : -1
	status := stream_status(st, ee_stream, h, state)
	send_later(cid, opt, 0x86, status[:])
	return h
}

// Op 0x86: {EE stream, IOP stream, open state | subsounds << 16, mode,
// bytes, ms, then the current subsound's sample handle and info}. The EE
// keeps the mode at stream +0x1c and tests FSOUND_NONBLOCKING there.
@(private = "file")
stream_status :: proc(st: ^Stream, ee_stream, h: u32, state: i16) -> (pkt: [15]u32) {
	pkt[0], pkt[1] = ee_stream, h
	pkt[2] = u32(u16(state))
	if st == nil {return}
	pkt[2] |= u32(len(st.subs)) << 16
	e := st.subs[st.sub]
	s := e.sample
	pkt[3], pkt[4] = st.mode, e.bytes
	if s.freq > 0 {pkt[5] = u32(u64(s.frames) * 1000 / u64(s.freq))}
	sample_info(s, pkt[6:])
	pkt[6] = st.handles[st.sub]
	return
}

@(private = "file")
stream_stop :: proc(st: ^Stream) {
	if st.channel >= 0 && voices[st.channel].sample == st.subs[st.sub].sample {voices[st.channel] = {}}
	st.channel = -1
}

@(private = "file")
stream_select :: proc(st: ^Stream, sub: int) {
	if sub == st.sub {return}
	stream_stop(st)
	old := st.subs[st.sub].sample
	delete(old.pcm)
	old.pcm = nil
	st.sub = sub
}

@(private = "file")
stream_destroy :: proc(st: ^Stream) {
	stream_stop(st)
	for h in st.handles {sample_free(h)}
	delete(st.handles)
	delete(st.subs)
	delete(st.name)
	free(st)
}

// FSOUND_Stream_PlayEx {stream, DSP unit, paused byte, channel bytes}: the EE
// has picked the channel(s); a stereo stream plays on the first.
@(private = "file")
stream_play :: proc(p: [^]u32) -> u32 {
	st := stream_get(p[0])
	b := ([^]u8)(p)
	ch := int(b[9])
	if st == nil || ch >= num_voices {return 0xffffffff}
	e := st.subs[st.sub]
	s := e.sample
	if s.pcm == nil {
		raw, ok := stream_read(st, e.offset, e.bytes)
		if !ok {return 0xffffffff}
		sample_decode(s, raw)
	}
	voices[ch] = {
		sample  = s,
		freq    = s.freq,
		vol     = s.vol,
		pan     = s.pan,
		playing = true,
		paused  = b[8] != 0,
	}
	st.channel = ch
	if k.debug >= 1 {
		fmt.eprintfln("fmod: stream sub %d on ch %d: %d frames @%d Hz x%d mode %x", st.sub, ch, s.frames, s.freq, s.channels, s.mode)
	}
	return u32(ch)
}

// An FSB3 bank: header, sample headers, then the sample data back to back.
@(private = "file")
Fsb_Entry :: struct {
	sample: ^Sample, // header fields; no PCM yet
	offset: u32, // data position in the bank
	bytes:  u32,
}

@(private = "file")
rd32 :: proc(b: []u8, o: int) -> u32 {return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24}
@(private = "file")
rd16 :: proc(b: []u8, o: int) -> u16 {return u16(b[o]) | u16(b[o + 1]) << 8}

// Bytes before the sample data, from the first 24; 0 if not an FSB3.
@(private = "file")
fsb_header_size :: proc(data: []u8) -> int {
	if len(data) < 24 || string(data[:4]) != "FSB3" {return 0}
	return 24 + int(rd32(data, 8))
}

// data holds at least fsb_header_size bytes.
@(private = "file")
fsb_parse :: proc(data: []u8) -> [dynamic]Fsb_Entry {
	out: [dynamic]Fsb_Entry
	size := fsb_header_size(data)
	if size == 0 || size > len(data) {return out}
	count := int(rd32(data, 4))
	hdrs := data[24:size]
	BASIC_HEADERS :: 2 // samples after the first have only the two lengths
	basic := rd32(data, 20) & BASIC_HEADERS != 0
	at := u32(size)
	first: []u8
	for i in 0 ..< count {
		frames, bytes: u32
		h: []u8
		name := ""
		if i > 0 && basic {
			if len(hdrs) < 8 {break}
			frames, bytes = rd32(hdrs, 0), rd32(hdrs, 4)
			h = first
			hdrs = hdrs[8:]
		} else {
			if len(hdrs) < 0x40 {break}
			h = hdrs
			name = string(cstring(raw_data(h[2:32])))
			frames, bytes = rd32(h, 32), rd32(h, 36)
			first = h
			hdrs = hdrs[min(int(rd16(h, 0)), len(hdrs)):]
		}
		s := new(Sample)
		s.name = strings.clone(name)
		s.frames = frames
		s.loop_start, s.loop_end = 0, frames - 1
		if i == 0 || !basic { // basic headers borrow the rest, but not the loop
			s.loop_start, s.loop_end = rd32(h, 40), rd32(h, 44)
		}
		s.mode, s.freq = rd32(h, 48), i32(rd32(h, 52))
		s.vol, s.pan, s.pri = u8(rd16(h, 56)), u8(rd16(h, 58)), rd16(h, 60)
		s.channels = max(int(rd16(h, 62)), 1)
		if s.mode & FSOUND_VAG == 0 {
			fmt.eprintfln("fmod: \"%s\": unsupported sample format %x", s.name, s.mode)
		}
		append(&out, Fsb_Entry{s, at, bytes})
		at += bytes
	}
	return out
}

@(private = "file")
sample_decode :: proc(s: ^Sample, raw: []u8) {
	delete(s.pcm)
	s.pcm = vag_decode(raw, int(s.frames), s.channels)
}

// A whole bank in memory, every sample decoded.
@(private = "file")
fsb_load :: proc(data: []u8) -> [dynamic]^Sample {
	out: [dynamic]^Sample
	entries := fsb_parse(data)
	defer delete(entries)
	for e in entries {
		end := min(int(e.offset + e.bytes), len(data))
		sample_decode(e.sample, data[min(int(e.offset), end):end])
		append(&out, e.sample)
	}
	return out
}

// PS-ADPCM: 16-byte blocks of 28 samples, channels interleaved per block.
vag_decode :: proc(src: []u8, frames: int, channels := 1) -> []i16 {
	F := [5][2]i32{{0, 0}, {60, 0}, {115, -52}, {98, -55}, {122, -60}}
	out := make([]i16, frames * channels)
	hist: [8][2]i32
	for blk in 0 ..< len(src) / 16 {
		b := src[blk * 16:][:16]
		c := blk % channels
		h := &hist[c & 7]
		shift := u32(b[0] & 15)
		f := min(int(b[0] >> 4), 4)
		for n in 0 ..< 28 {
			nib := (b[2 + n / 2] >> (u32(n & 1) * 4)) & 15
			v := i32(i16(u16(nib) << 12)) >> shift
			v += (h[0] * F[f][0] + h[1] * F[f][1] + 32) >> 6
			v = clamp(v, -32768, 32767)
			h[1], h[0] = h[0], v
			if i := blk / channels * 28 + n; i < frames {out[i * channels + c] = i16(v)}
		}
	}
	return out
}

// FSOUND_Update {IOP block, EE level buffer, sequence}: the EE has DMA'd its
// channel block to IOP memory. Apply the dirty channels, then answer with
// op 0x1b after writing a byte per channel the EE reads as "is playing".
@(private = "file")
fmod_update :: proc(cid, opt: u32, p: [^]u32) {
	blk := p[0] & (IOP_RAM_SIZE - 1)
	CH :: 0xd0 // first channel; 0x70 bytes each
	for i in 0 ..< num_voices {
		c := iop_ram[blk + CH + u32(i) * 0x70:][:0x70]
		w := ([^]u32)(raw_data(c))
		flags, state := w[3], w[0x13]
		v := &voices[i]
		if k.debug >= 1 && flags & 3 != 0 {
			fmt.eprintfln("fmod: ch %d flags %x state %x sample %08x", i, flags, state, w[10])
		}
		if flags & 2 != 0 {v.playing = false} // stop
		if flags & 1 != 0 { // play {sample at +0x28}; paused when state bit 8
			if s := sample_get(w[10]); s != nil {
				v^ = {
					sample  = s,
					freq    = s.freq,
					vol     = s.vol,
					pan     = s.pan,
					playing = true,
					paused  = state & 0x100 != 0,
				}
			}
		}
		if flags & 0x0c != 0 {v.vol = c[0x38]} // 4 scaled by SFX volume, 8 absolute
		if flags & 0x10 != 0 {v.freq = i32(w[0x10])}
		if flags & 0x20 != 0 {v.pan = c[0x39]}
		if flags & 0x100 != 0 {v.paused = state & 0x10 != 0}
		if flags & 0x200 != 0 {v.muted = state & 0x02 != 0}
		if flags & 0x1000 != 0 {v.loop = w[0x11] & 7}
		if flags & 0x2000 != 0 && v.sample != nil && w[0x12] < v.sample.frames {
			v.pos = u64(w[0x12]) << 32
		}
	}
	levels := ram_slice(p[1], 0x100)
	for i in 0 ..< 0x100 {levels[i] = i < num_voices && voices[i].playing ? 1 : 0}
	send(cid, opt, 0x1b, {})
}

// Render interleaved stereo at MIX_RATE.
fmod_mix :: proc(out: []i16) {
	acc := make([]i32, len(out), context.temp_allocator)
	for &v in voices[:num_voices] {
		if !v.playing || v.paused || v.sample == nil {continue}
		s := v.sample
		pcm := s.pcm
		ch := u64(s.channels)
		if len(pcm) == 0 {v.playing = false; continue}
		loop := v.loop != 0 ? v.loop : s.mode & 7
		loops := loop & (FSOUND_LOOP_NORMAL | FSOUND_LOOP_BIDI) != 0
		end := u64(len(pcm)) / ch
		lstart := u64(s.loop_start)
		if loops {end = min(u64(s.loop_end) + 1, end)}
		if lstart >= end {lstart = 0}
		step := (u64(max(v.freq, 0)) << 32) / MIX_RATE
		vol := i32(v.vol)
		if v.muted {vol = 0}
		vol = vol * sfx_volume / 255
		// Constant power pan: 0 left, 128 centre, 255 right.
		a := f32(v.pan) / 255 * math.PI / 2
		lv := i32(math.cos(a) * 1.4142 * f32(vol))
		rv := i32(math.sin(a) * 1.4142 * f32(vol))
		for n := 0; n < len(out); n += 2 {
			i := v.pos >> 32
			if i >= end {
				if !loops {v.playing = false; break}
				v.pos -= (end - lstart) << 32
				i = v.pos >> 32
			}
			frac := i32((v.pos >> 16) & 0xffff)
			j := i + 1 < end ? i + 1 : (loops ? lstart : i)
			// The second channel of a stereo sample, or the mono one again.
			r := ch - 1
			l0, l1 := i32(pcm[i * ch]), i32(pcm[j * ch])
			r0, r1 := i32(pcm[i * ch + r]), i32(pcm[j * ch + r])
			acc[n] += (l0 + ((l1 - l0) * frac >> 16)) * lv >> 8
			acc[n + 1] += (r0 + ((r1 - r0) * frac >> 16)) * rv >> 8
			v.pos += step
		}
	}
	for x, i in acc {out[i] = i16(clamp(x, -32768, 32767))}
}

// Emulated state, saved and restored by snapshots (snap.odin).
@(private)
fmod_snap :: proc() {
	snap_add(&heap)
	snap_add(&samples)
	snap_add(&songs)
	snap_add(&streams)
	snap_add(&voices)
	snap_add(&num_voices)
	snap_add(&sfx_volume)
	snap_add(&pending)
}
