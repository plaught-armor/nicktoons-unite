// Static recompiler: Emotion Engine (R5900) machine code -> Odin source.
//
// Usage:
//   recomp stats <SLUS_212.84>            opcode histogram of .text
//   recomp gen   <SLUS_212.84> <out_dir>  write the recompiled game code
package recomp

import "core:fmt"
import "core:os"
import "core:slice"
import "../../port/src/r5900"

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: recomp stats <elf> | recomp gen <elf> <out_dir>")
		os.exit(2)
	}
	img, ok := load_elf(os.args[2])
	if !ok {
		fmt.eprintln("cannot load", os.args[2])
		os.exit(1)
	}
	switch os.args[1] {
	case "stats":
		stats(&img)
	case "funcs":
		prog := build_program(&img)
		n, computed := 0, 0
		for f in prog.funcs {
			n += len(f.insns)
			if f.computed {computed += 1}
		}
		fmt.printfln("%d functions, %d instructions, %d with computed jr, %d refs, %d jal targets",
			len(prog.funcs), n, computed, len(prog.refs), len(prog.calls))
	case "syscalls":
		text := find_section(&img, ".text")
		for a := text.addr + 4; a < text.addr + text.size; a += 4 {
			w, _ := word(&img, a)
			if w & 0xfc00003f != 0x0c {continue}
			p, _ := word(&img, a - 4)
			if p >> 16 == 0x2403 {fmt.printfln("%08x syscall %d", a, i16(p))} else {fmt.printfln("%08x syscall ? %08x", a, p)}
		}
	case "gen":
		if len(os.args) < 4 {
			fmt.eprintln("usage: recomp gen <elf> <out_dir>")
			os.exit(2)
		}
		if !gen(build_program(&img), os.args[3]) {os.exit(1)}
		if !gen_vu(&img, os.args[3]) {os.exit(1)}
	case:
		fmt.eprintln("unknown mode", os.args[1])
		os.exit(2)
	}
}

stats :: proc(img: ^Image) {
	text := find_section(img, ".text")
	counts: [r5900.Op]int
	for a := text.addr; a < text.addr + text.size; a += 4 {
		w, _ := word(img, a)
		counts[r5900.decode(a, w).op] += 1
	}
	Row :: struct {op: r5900.Op, n: int}
	rows: [dynamic]Row
	for n, op in counts {
		if n > 0 {append(&rows, Row{op, n})}
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {return a.n > b.n})
	for r in rows {
		fmt.printfln("%8d %v", r.n, r.op)
	}
}
