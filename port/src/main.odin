// Nicktoons Unite! native port: loads the game's ELF into emulated EE memory
// and runs the recompiled code against the HLE kernel and hardware.
package main

import "core:fmt"
import "core:path/filepath"
import "core:os"
import "ps:core"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import iop "ps:ps2/iop"
import mem "ps:ps2/mem"
import "rec"

ELF_PATH :: "../disc/SLUS_212.84"

// Read the ELF at path and copy its PT_LOAD segments into RAM. Exits on a
// file that cannot be read or is not a loadable ELF. Returns the entry point.
load_elf :: proc(path: string) -> u32 {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read %s: %v", path, err)
		os.exit(1)
	}
	defer delete(data)
	entry, ok := mem.load_elf(data)
	if !ok {
		fmt.eprintfln("%s is not a loadable ELF file", path)
		os.exit(1)
	}
	return entry
}

main :: proc() {
	path := len(os.args) > 1 ? os.args[1] : ELF_PATH
	iop.disc_dir = filepath.dir(path)
	ps2.init()
	video_init()
	rec.register_all()
	// Machine code from the same recompile (tools/recomp.tsv native_arch and
	// native_out) in place of the Odin functions. A file that cannot be used
	// stops the run, so a test never passes on the Odin code by mistake;
	// NT_NATIVE=0 keeps the Odin functions.
	if path := core.env("NATIVE_FILE"); path != "" && core.env("NATIVE") != "0" {
		if !ps2.load_native(path) {os.exit(1)}
	}
	entry := load_elf(path)
	cpu.state.r[29].d[0] = mem.RAM_SIZE - 16
	ps2.run(entry)
}
