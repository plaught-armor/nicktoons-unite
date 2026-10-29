// Nicktoons Unite! native port: loads the game's ELF into emulated EE memory
// and runs the recompiled code against the HLE kernel and hardware.
package main

import "core:fmt"
import "core:path/filepath"
import "core:os"
import "ps:core"
import "ps:ps2"
import host "ps:ps2/host"
import cpu "ps:ps2/cpu"
import iop "ps:ps2/iop"
import mem "ps:ps2/mem"
import "rec"

// Relative to the directory of the executable, so the game starts from any
// working directory.
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
	path: string
	if len(os.args) > 1 {
		path = os.args[1]
	} else {
		dir, err := os.get_executable_directory(context.allocator)
		if err != nil {
			fmt.eprintfln("cannot find the executable directory: %v", err)
			os.exit(1)
		}
		path, err = filepath.join({dir, ELF_PATH})
		if err != nil {
			fmt.eprintfln("cannot build the disc path: %v", err)
			os.exit(1)
		}
	}
	iop.disc_dir = filepath.dir(path)
	ps2.init()
	if !host.platform_init("Nicktoons Unite!") {os.exit(1)}
	host.pad_hook = dpad_stick
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

// The game walks with the left stick only, so d-pad presses (from the
// keyboard and NT_PRESS too) push it unless the stick is held.
dpad_stick :: proc(p: ^core.Net_Input) {
	if abs(i32(p.axes[2]) - 0x80) < 0x40 {
		if .Left in p.buttons {p.axes[2] = 0x00}
		if .Right in p.buttons {p.axes[2] = 0xff}
	}
	if abs(i32(p.axes[3]) - 0x80) < 0x40 {
		if .Up in p.buttons {p.axes[3] = 0x00}
		if .Down in p.buttons {p.axes[3] = 0xff}
	}
}
