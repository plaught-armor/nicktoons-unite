// Nicktoons Unite! native port: loads the game's ELF into emulated EE memory
// and runs the recompiled code against the HLE kernel and hardware.
package main

import "core:fmt"
import "core:path/filepath"
import "core:os"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import iop "ps:ps2/iop"
import mem "ps:ps2/mem"
import "rec"

ELF_PATH :: "../disc/SLUS_212.84"

le32 :: proc(b: []u8, o: int) -> u32 {
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}

le16 :: proc(b: []u8, o: int) -> u32 {
	return u32(b[o]) | u32(b[o + 1]) << 8
}

// Copy each PT_LOAD segment into RAM and return the entry point.
load_elf :: proc(path: string) -> u32 {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read %s", path)
		os.exit(1)
	}
	if len(data) < 52 || le32(data, 0) != 0x464c457f {
		fmt.eprintfln("%s is not an ELF file", path)
		os.exit(1)
	}
	phoff := int(le32(data, 28))
	phentsize := int(le16(data, 42))
	phnum := int(le16(data, 44))
	for i in 0 ..< phnum {
		p := phoff + i * phentsize
		if le32(data, p) != 1 {continue} // PT_LOAD
		off, vaddr := int(le32(data, p + 4)), le32(data, p + 8)
		filesz, memsz := le32(data, p + 16), le32(data, p + 20)
		dst := mem.ram_slice(vaddr, memsz)
		copy(dst, data[off:][:filesz])
		for &b in dst[filesz:] {b = 0}
	}
	return le32(data, 24)
}

main :: proc() {
	path := len(os.args) > 1 ? os.args[1] : ELF_PATH
	iop.disc_dir = filepath.dir(path)
	ps2.init()
	video_init()
	rec.register_all()
	entry := load_elf(path)
	cpu.state.r[29].d[0] = mem.RAM_SIZE - 16
	ps2.run(entry)
}
