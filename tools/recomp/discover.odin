// Function discovery for an ELF without symbols.
//
// Entries come from `jal` targets, the first instruction after each
// `jr $ra` and its delay slot, and code addresses found in data or built
// with `lui`+`addiu`/`ori` that begin with a stack-frame prologue. Every
// code address found in data is also a label inside its function, which
// covers switch jump tables.
package recomp

import "core:slice"
import "../../port/src/r5900"

Func :: struct {
	entry:      u32,
	start, end: u32, // address range whose instructions belong to it
	insns:      map[u32]r5900.Insn,
	labels:     map[u32]bool,
	delay:      map[u32]bool, // delay-slot pcs
	exits:      map[u32]bool, // branch/jump targets outside [start, end)
	computed:   bool, // has a `jr` through a register other than $ra
}

Program :: struct {
	img:          ^Image,
	text_lo:      u32,
	text_hi:      u32,
	refs:         map[u32]bool, // code addresses referenced from data or lui pairs
	calls:        map[u32]bool, // jal targets
	funcs:        [dynamic]^Func,
	by_entry:     map[u32]^Func,
}

in_text :: #force_inline proc(p: ^Program, a: u32) -> bool {
	return a >= p.text_lo && a < p.text_hi && a & 3 == 0
}

is_prologue :: proc(w: u32) -> bool {
	// addiu $sp, $sp, -n  (also daddiu)
	return (w >> 16 == 0x27bd || w >> 16 == 0x67bd) && w & 0x8000 != 0
}

collect_refs :: proc(p: ^Program) {
	img := p.img
	for s in img.sections {
		if s.data == nil || s.addr >= 0x01000000 {
			continue
		}
		// Data words pointing into .text (from every section: code also holds literal pools).
		if s.flags & SHF_EXEC == 0 {
			for o := u32(0); o + 4 <= s.size; o += 4 {
				v, _ := word(img, s.addr + o)
				if in_text(p, v) {p.refs[v] = true}
			}
		}
	}
	// lui/addiu and lui/ori pairs in code.
	upper: [32]u32
	known: [32]bool
	for a := p.text_lo; a < p.text_hi; a += 4 {
		w, _ := word(img, a)
		op := w >> 26
		rs := (w >> 21) & 31
		rt := (w >> 16) & 31
		switch op {
		case 0x0f:
			upper[rt] = (w & 0xffff) << 16
			known[rt] = true
		case 0x09, 0x19, 0x0d:
			if known[rs] {
				lo := op == 0x0d ? w & 0xffff : u32(r5900.sx16(u16(w)))
				v := upper[rs] + lo
				if in_text(p, v) {p.refs[v] = true}
			}
		case 0x03:
			t := ((a + 4) & 0xf0000000) | ((w & 0x3ffffff) << 2)
			if in_text(p, t) {p.calls[t] = true}
		}
		// A jump or branch ends the straight-line run that lui values flow through.
		if op == 2 || op == 3 || (op == 0 && (w & 63 == 8 || w & 63 == 9)) {
			known = {}
		}
	}
}

// First non-nop after each `jr $ra` + delay slot.
return_boundaries :: proc(p: ^Program, out: ^map[u32]bool) {
	for q := p.text_lo; q + 8 < p.text_hi; q += 4 {
		w, _ := word(p.img, q)
		if w != 0x03e00008 {continue}
		a := q + 8
		for a < p.text_hi {
			v, _ := word(p.img, a)
			if v != 0 {break}
			a += 4
		}
		if a < p.text_hi {out[a] = true}
	}
}

// Referenced addresses that begin with a prologue (allowing a few lui/load
// words before it, as BOF4's game code had).
pointer_entries :: proc(p: ^Program, out: ^map[u32]bool) {
	for r in p.refs {
		for k in u32(0) ..< 4 {
			w, ok := word(p.img, r + 4 * k)
			if !ok {break}
			if is_prologue(w) {
				out[r] = true
				break
			}
			// Only lui and loads/moves may precede the prologue.
			op := w >> 26
			if !(op == 0x0f || op == 0x23 || op == 0x37 || op == 0x09 || (op == 0 && w & 63 == 0x2d)) {
				break
			}
		}
	}
}

walk :: proc(p: ^Program, f: ^Func, start_pcs: []u32) {
	work := make([dynamic]u32, 0, 64, context.temp_allocator)
	append(&work, ..start_pcs)
	inside :: #force_inline proc(f: ^Func, a: u32) -> bool {return a >= f.start && a < f.end}
	for len(work) > 0 {
		pc := pop(&work)
		for inside(f, pc) && (pc not_in f.insns) {
			w, ok := word(p.img, pc)
			if !ok {break}
			i := r5900.decode(pc, w)
			f.insns[pc] = i
			if i.kind == .Bad {break}
			if r5900.has_delay(i) {
				d := pc + 4
				if inside(f, d) && d not_in f.insns {
					dw, _ := word(p.img, d)
					f.insns[d] = r5900.decode(d, dw)
				}
				f.delay[d] = true
				#partial switch i.kind {
				case .Branch:
					if inside(f, i.target) {
						f.labels[i.target] = true
						append(&work, i.target)
					} else {
						f.exits[i.target] = true
					}
					pc += 8
					continue
				case .Jump:
					if inside(f, i.target) {
						f.labels[i.target] = true
						append(&work, i.target)
					} else {
						f.exits[i.target] = true
					}
				case .Call, .Jalr:
					pc += 8
					continue
				case .Jr:
					if i.rs != 31 {f.computed = true}
				}
				break
			}
			if i.op == .ERET {break}
			pc += 4
		}
		if pc == f.end {
			f.exits[pc] = true // falls through into the next function
		}
	}
}

discover_func :: proc(p: ^Program, entry, start, end: u32) -> ^Func {
	f := new(Func)
	f.entry, f.start, f.end = entry, start, end
	f.labels[entry] = true
	pcs := make([dynamic]u32, 0, 16, context.temp_allocator)
	append(&pcs, entry)
	for r in p.refs {
		if r >= start && r < end && r != entry {
			f.labels[r] = true
			append(&pcs, r)
		}
	}
	walk(p, f, pcs[:])
	if f.computed && len(pcs) == 1 {
		// Indirect jump without known targets: decode everything and label it all.
		rest := make([dynamic]u32, 0, 64, context.temp_allocator)
		for a := start; a < end; a += 4 {
			if a not_in f.insns {append(&rest, a)}
		}
		walk(p, f, rest[:])
		for a in f.insns {
			if a not_in f.delay {f.labels[a] = true}
		}
	}
	// A delay slot that is also a label needs its successor labelled too.
	for d in f.delay {
		if d in f.labels {f.labels[d + 4] = true}
	}
	return f
}

build_program :: proc(img: ^Image) -> ^Program {
	p := new(Program)
	p.img = img
	text := find_section(img, ".text")
	p.text_lo, p.text_hi = text.addr, text.addr + text.size
	collect_refs(p)

	cand: map[u32]bool
	cand[img.entry] = true
	for c in p.calls {cand[c] = true}
	return_boundaries(p, &cand)
	pointer_entries(p, &cand)

	entries := make([dynamic]u32)
	for e in cand {append(&entries, e)}
	slice.sort(entries[:])

	// An entry that the preceding function branches into the middle of is
	// not a real start (unless something calls it with jal); drop it and retry.
	dropped: map[u32]bool
	funcs: [dynamic]^Func
	for {
		for f in funcs {free_func(f)}
		clear(&funcs)
		for e, n in entries {
			end := n + 1 < len(entries) ? entries[n + 1] : p.text_hi
			append(&funcs, discover_func(p, e, e, end))
		}
		inner := false
		for n in 0 ..< len(funcs) - 1 {
			nxt := funcs[n + 1]
			if nxt.entry in p.calls {continue}
			for t in funcs[n].exits {
				if t > nxt.entry && t < nxt.end {
					dropped[nxt.entry] = true
					inner = true
					break
				}
			}
		}
		if !inner {break}
		kept := make([dynamic]u32)
		for e in entries {if e not_in dropped {append(&kept, e)}}
		delete(entries)
		entries = kept
	}
	for f in funcs {p.by_entry[f.entry] = f}

	// Branch/jump targets outside any entry (shared tails, dropped entries)
	// get secondary functions covering their container, so loops back across
	// the target stay inside.
	work := make([dynamic]u32)
	for d in dropped {append(&work, d)}
	for f in funcs {for t in f.exits {append(&work, t)}}
	for len(work) > 0 {
		t := pop(&work)
		if t in p.by_entry || !in_text(p, t) {continue}
		n, _ := slice.binary_search(entries[:], t)
		// binary_search returns the insertion point when not found
		lo := n > 0 ? entries[n - 1] : p.text_lo
		hi := n < len(entries) ? entries[n] : p.text_hi
		g := discover_func(p, t, lo, hi)
		append(&funcs, g)
		p.by_entry[t] = g
		for x in g.exits {append(&work, x)}
	}
	slice.sort_by(funcs[:], proc(a, b: ^Func) -> bool {return a.entry < b.entry})
	p.funcs = funcs
	return p
}

free_func :: proc(f: ^Func) {
	delete(f.insns)
	delete(f.labels)
	delete(f.delay)
	delete(f.exits)
	free(f)
}
