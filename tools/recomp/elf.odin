package recomp

import "core:encoding/endian"
import "core:os"
import "core:strings"

Section :: struct {
	name:  string,
	addr:  u32,
	size:  u32,
	data:  []byte, // nil for NOBITS
	flags: u32,
}

Image :: struct {
	entry:    u32,
	sections: [dynamic]Section,
	// Flat view of every loaded byte, from lo to hi; NOBITS reads as zero.
	lo, hi:   u32,
	mem:      []byte,
}

SHF_ALLOC :: 2
SHF_EXEC :: 4
SHT_NOBITS :: 8

load_elf :: proc(path: string) -> (img: Image, ok: bool) {
	raw, err := os.read_entire_file(path, context.allocator)
	if err != nil || len(raw) < 52 || string(raw[:4]) != "\x7fELF" {
		return
	}
	u16le :: proc(b: []byte, o: int) -> u32 {v, _ := endian.get_u16(b[o:], .Little); return u32(v)}
	u32le :: proc(b: []byte, o: int) -> u32 {v, _ := endian.get_u32(b[o:], .Little); return v}

	img.entry = u32le(raw, 24)
	shoff := int(u32le(raw, 32))
	shentsize := int(u16le(raw, 46))
	shnum := int(u16le(raw, 48))
	shstrndx := int(u16le(raw, 50))
	str_off := int(u32le(raw, shoff + shstrndx * shentsize + 16))

	img.lo = 0xffffffff
	for i in 0 ..< shnum {
		h := shoff + i * shentsize
		name_off := int(u32le(raw, h))
		typ := u32le(raw, h + 4)
		flags := u32le(raw, h + 8)
		addr := u32le(raw, h + 12)
		off := int(u32le(raw, h + 16))
		size := u32le(raw, h + 20)
		if flags & SHF_ALLOC == 0 || size == 0 {
			continue
		}
		name := strings.clone_from_cstring(cstring(&raw[str_off + name_off]))
		s := Section{name = name, addr = addr, size = size, flags = flags}
		if typ != SHT_NOBITS {
			s.data = raw[off:off + int(size)]
		}
		append(&img.sections, s)
		// .vudata lives in VU memory space (0x01000000); keep it out of the flat view.
		if addr < 0x01000000 {
			img.lo = min(img.lo, addr)
			img.hi = max(img.hi, addr + size)
		}
	}
	img.mem = make([]byte, img.hi - img.lo)
	for s in img.sections {
		if s.data != nil && s.addr < 0x01000000 {
			copy(img.mem[s.addr - img.lo:], s.data)
		}
	}
	return img, true
}

find_section :: proc(img: ^Image, name: string) -> ^Section {
	for &s in img.sections {
		if s.name == name {
			return &s
		}
	}
	return nil
}

word :: proc(img: ^Image, addr: u32) -> (u32, bool) {
	if addr < img.lo || addr + 4 > img.hi || addr & 3 != 0 {
		return 0, false
	}
	v, _ := endian.get_u32(img.mem[addr - img.lo:], .Little)
	return v, true
}
