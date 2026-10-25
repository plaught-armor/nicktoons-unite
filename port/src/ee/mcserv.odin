// HLE mcserv (sid 0x80000400, old MCSERV function numbers). Each memory card
// port is a host directory, memcard0/ and memcard1/ in the working directory
// (or in $NT_MC, so scripted runs can start from a blank card), holding the
// card's save directories and files as plain host files.
//
// Listings must not depend on the host: entries are sorted by name and carry
// one fixed timestamp, so runs (and netplay peers) see identical cards.
package ee

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

MC_PORTS :: 2

// Results, as libmc reports them.
MC_OK :: 0
MC_NO_ENTRY :: -4
MC_DENIED :: -5
MC_NOT_EMPTY :: -6

// Open flags.
MC_RDONLY :: 0x0001
MC_WRONLY :: 0x0002
MC_RDWR :: 0x0003
MC_CREATE_DIR :: 0x0040
MC_CREAT :: 0x0200
MC_TRUNC :: 0x0400

// Entry attributes: 0x8000 exists, 0x0400 always set, 0x0080 closed,
// 0x0020 directory, 0x0010 file, 0x0007 read/write/execute.
MC_ATTR_DIR :: 0x8427
MC_ATTR_FILE :: 0x8497
MC_ATTR_RENAME :: 0x0010 // SetFileInfo: take the name from the entry

// sceMcTblGetDir: two 8-byte times, size, attributes, reserved, name[32].
MC_ENTRY_SIZE :: 64

@(private = "file")
Mc_File :: struct {
	f:   ^os.File,
	pos: i64,
}

@(private = "file")
mc: struct {
	cwd:     [MC_PORTS]string, // "" is the root, else "/DIR"
	known:   [MC_PORTS]bool, // GetInfo reported the card once already
	files:   [dynamic]Mc_File, // handle = index
	dir:     [dynamic][MC_ENTRY_SIZE]u8, // pending GetDir results
	dir_pos: int,
}

// Request layouts. Path commands: {port, slot, flags, max entries, table
// address, name[0x400]}. File commands: {handle, ?, ?, size, offset,
// origin, buffer, param, data[16]}.
@(private = "file") MC_NAME :: 0x14
@(private = "file") MC_DATA :: 0x20

@(private)
mcserv_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	r: i32
	switch fno {
	case 0x01: r = mc_get_info(w)
	case 0x02: r = mc_open(w[0], w[2], mc_name(buf))
	case 0x03: r = mc_close(w[0])
	case 0x04: r = mc_seek(w[0], i32(w[4]), w[5])
	case 0x05: r = mc_read(w[0], w[3], w[6], w[7])
	case 0x06: r = mc_write(w[0], w[3], w[6], buf[MC_DATA:][:min(w[5], 16)])
	case 0x0a: r = MC_OK // Flush: writes go straight to the host file
	case 0x0c: r = mc_chdir(w[0], w[4], mc_name(buf))
	case 0x0d: r = mc_get_dir(w[0], w[2], w[3], w[4], mc_name(buf))
	case 0x0e: r = mc_set_file_info(w[0], w[2], w[4], mc_name(buf))
	case 0x0f: r = mc_delete(w[0], mc_name(buf))
	case 0x10, 0x11: r = MC_OK // Format, Unformat
	case 0x12: r = mc_get_ent_space(w[0], mc_name(buf))
	case 0x14: r = MC_OK // ChangeThreadPriority
	case 0xfe, 0x70: // Init {result, mcserv version, mcman version}
		w[0], w[1], w[2] = 0, 0x20a, 0x20e
		return true
	case:
		return false
	}
	if k.debug >= 1 {fmt.eprintfln("mc: fno %02x -> %d", fno, r)}
	w[0] = u32(r)
	return true
}

@(private = "file")
mc_name :: proc(buf: []u8) -> string {
	return strings.clone(string(cstring(raw_data(buf[MC_NAME:]))), context.temp_allocator)
}

@(private = "file")
mc_port_ok :: proc(port: u32) -> bool {return port < MC_PORTS}

// A guest path normalized against the port's current directory: "" for
// the root, else "/A/B". "." and ".." never climb out of the card.
@(private = "file")
mc_guest_path :: proc(port: u32, name: string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	full := name if strings.has_prefix(name, "/") else strings.concatenate({mc.cwd[port], "/", name}, context.temp_allocator)
	rest := full
	for part in strings.split_iterator(&rest, "/") {
		switch part {
		case "", ".":
		case "..": if len(parts) > 0 {pop(&parts)}
		case: append(&parts, part)
		}
	}
	if len(parts) == 0 {return ""}
	return strings.concatenate({"/", strings.join(parts[:], "/", context.temp_allocator)}, context.temp_allocator)
}

@(private = "file")
mc_host_path :: proc(port: u32, name: string) -> string {
	return mc_card_path(port, mc_guest_path(port, name))
}

// The host path of a normalized guest path.
@(private = "file")
mc_card_path :: proc(port: u32, guest: string) -> string {
	root := os.get_env("NT_MC", context.temp_allocator)
	return fmt.tprintf("%s/memcard%d%s", root if root != "" else ".", port, guest)
}

// GetInfo {?, port, slot, want formatted, want free, want type, ?, result
// address}: the card is always a formatted 8 MB PS2 card.
@(private = "file")
mc_get_info :: proc(w: [^]u32) -> i32 {
	port := w[1]
	if !mc_port_ok(port) {return -1}
	_ = os.make_directory_all(mc_host_path(port, "/"))
	out := ([^]u32)(raw_data(ram_slice(w[7], 0x94)))
	if w[5] != 0 {out[0] = 2} // PS2 card
	if w[4] != 0 {out[1] = 0x2000} // free clusters of 1 KB
	if w[3] != 0 {out[0x24] = 1} // formatted
	// 0: same card as last call, -1: new formatted card.
	known := mc.known[port]
	mc.known[port] = true
	return 0 if known else -1
}

@(private = "file")
mc_open :: proc(port, flags: u32, name: string) -> i32 {
	if !mc_port_ok(port) {return -1}
	path := mc_host_path(port, name)
	if flags == MC_CREATE_DIR {
		if os.exists(path) {return MC_NO_ENTRY}
		return MC_OK if os.make_directory(path) == nil else -1
	}
	if !os.exists(path) && flags & MC_CREAT == 0 {return MC_NO_ENTRY}
	if os.is_dir(path) {return MC_DENIED}
	ff := os.File_Flags{.Read}
	if flags & 3 != MC_RDONLY {ff += {.Write}}
	if flags & MC_CREAT != 0 {ff += {.Create, .Write}}
	if flags & MC_TRUNC != 0 {ff += {.Trunc, .Write}}
	// Host handles are never closed (see mc_close).
	f, err := os.open(path, ff, os.Permissions_Default_File)
	if err != nil {return MC_NO_ENTRY}
	if k.debug >= 1 {fmt.eprintfln("mc: open \"%s\" flags %x -> %s", name, flags, path)}
	for &e, i in mc.files {
		if e.f == nil {
			e = {f, 0}
			return i32(i)
		}
	}
	append(&mc.files, Mc_File{f, 0})
	return i32(len(mc.files) - 1)
}

@(private = "file")
mc_file :: proc(h: u32) -> ^Mc_File {
	if int(h) >= len(mc.files) || mc.files[h].f == nil {return nil}
	return &mc.files[h]
}

@(private = "file")
mc_close :: proc(h: u32) -> i32 {
	f := mc_file(h)
	if f == nil {return -1}
	// The host file stays open: a snapshot may hold the handle. Writes go
	// straight to the file, so nothing is lost; cards open few files.
	f^ = {}
	return MC_OK
}

@(private = "file")
mc_seek :: proc(h: u32, off: i32, origin: u32) -> i32 {
	f := mc_file(h)
	if f == nil {return -1}
	switch origin {
	case 0: f.pos = i64(off)
	case 1: f.pos += i64(off)
	case 2:
		size, _ := os.file_size(f.f)
		f.pos = size + i64(off)
	}
	f.pos = max(f.pos, 0)
	return i32(f.pos)
}

// Read {handle, ?, ?, size, ?, ?, buffer, param}. The real server sends the
// unaligned head and tail through the param block; here the whole read
// lands in the buffer and the param block says nothing is left over.
@(private = "file")
mc_read :: proc(h, size, dst, param: u32) -> i32 {
	f := mc_file(h)
	if f == nil {return MC_DENIED}
	if param != 0 {
		p := ([^]u32)(raw_data(ram_slice(param, 8)))
		p[0], p[1] = 0, 0
	}
	n, _ := os.read_at(f.f, ram_slice(dst, size), f.pos)
	f.pos += i64(n)
	return i32(n)
}

// Write {handle, ?, ?, size, ?, head size, buffer, ?, head[16]}: the
// unaligned head bytes travel in the request, the rest is read from EE RAM.
@(private = "file")
mc_write :: proc(h, size, src: u32, head: []u8) -> i32 {
	f := mc_file(h)
	if f == nil {return MC_DENIED}
	n0, _ := os.write_at(f.f, head, f.pos)
	f.pos += i64(n0)
	n1, _ := os.write_at(f.f, ram_slice(src, size), f.pos)
	f.pos += i64(n1)
	return i32(n0 + n1)
}

// ChDir {port, slot, ?, ?, old dir address, new dir}: reports the current
// directory, then changes to an existing one.
@(private = "file")
mc_chdir :: proc(port, out: u32, name: string) -> i32 {
	if !mc_port_ok(port) {return -1}
	if out != 0 {
		cur := mc.cwd[port] if mc.cwd[port] != "" else "/"
		dst := ram_slice(out, 1024)
		n := copy(dst[:len(dst) - 1], cur)
		dst[n] = 0
	}
	guest := mc_guest_path(port, name)
	if !os.is_dir(mc_host_path(port, name)) {return MC_NO_ENTRY}
	delete(mc.cwd[port])
	mc.cwd[port] = strings.clone(guest)
	return MC_OK
}

// Glob match with "*" and "?", as mcman matches GetDir patterns.
@(private = "file")
mc_glob :: proc(pat, s: string) -> bool {
	if len(pat) == 0 {return len(s) == 0}
	switch pat[0] {
	case '*':
		for i in 0 ..= len(s) {
			if mc_glob(pat[1:], s[i:]) {return true}
		}
		return false
	case '?':
		return len(s) > 0 && mc_glob(pat[1:], s[1:])
	case:
		return len(s) > 0 && s[0] == pat[0] && mc_glob(pat[1:], s[1:])
	}
}

@(private = "file")
mc_entry :: proc(name: string, size: i64, is_dir: bool) -> (e: [MC_ENTRY_SIZE]u8) {
	// {?, sec, min, hour, day, month, year lo, year hi}: 2006-01-01 00:00:00.
	stamp := [8]u8{0, 0, 0, 0, 1, 1, u8(2006 & 0xff), u8(2006 >> 8)}
	copy(e[0:8], stamp[:])
	copy(e[8:16], stamp[:])
	(^u32)(&e[0x10])^ = u32(size)
	(^u16)(&e[0x14])^ = MC_ATTR_DIR if is_dir else MC_ATTR_FILE
	copy(e[0x20:0x3f], name)
	return
}

// GetDir {port, slot, flags, max entries, table, pattern}: flags 0 starts a
// search, anything else continues the last one.
@(private = "file")
mc_get_dir :: proc(port, flags, max_entries, table: u32, name: string) -> i32 {
	if !mc_port_ok(port) {return -1}
	if flags == 0 {
		clear(&mc.dir)
		mc.dir_pos = 0
		guest := mc_guest_path(port, name)
		slash := strings.last_index_byte(guest, '/')
		pat := guest[slash + 1:]
		dir := mc_card_path(port, guest[:max(slash, 0)])
		if !os.is_dir(dir) {return MC_NO_ENTRY}
		if slash > 0 {
			// Inside a save directory the listing starts with "." and "..".
			for n in ([]string{".", ".."}) {
				if mc_glob(pat, n) {append(&mc.dir, mc_entry(n, 0, true))}
			}
		}
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {return MC_NO_ENTRY}
		slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for fi in infos {
			if !mc_glob(pat, fi.name) {continue}
			append(&mc.dir, mc_entry(fi.name, fi.size, fi.type == .Directory))
		}
	}
	n := min(int(max_entries), len(mc.dir) - mc.dir_pos)
	if n > 0 {
		out := ram_slice(table, u32(n) * MC_ENTRY_SIZE)
		for i in 0 ..< n {
			copy(out[i * MC_ENTRY_SIZE:][:MC_ENTRY_SIZE], mc.dir[mc.dir_pos + i][:])
		}
		mc.dir_pos += n
	}
	if k.debug >= 1 {fmt.eprintfln("mc: getdir \"%s\" flags %d -> %d", name, flags, n)}
	return i32(max(n, 0))
}

// SetFileInfo {port, slot, flags, ?, entry, name}: only renames are kept;
// times and attributes come from the host file.
@(private = "file")
mc_set_file_info :: proc(port, flags, table: u32, name: string) -> i32 {
	if !mc_port_ok(port) {return -1}
	path := mc_host_path(port, name)
	if !os.exists(path) {return MC_NO_ENTRY}
	if flags & MC_ATTR_RENAME == 0 {return MC_OK}
	new_name := string(cstring(raw_data(ram_slice(table + 0x20, 0x20))))
	dir := path[:strings.last_index_byte(path, '/')]
	return MC_OK if os.rename(path, fmt.tprintf("%s/%s", dir, new_name)) == nil else MC_DENIED
}

@(private = "file")
mc_delete :: proc(port: u32, name: string) -> i32 {
	if !mc_port_ok(port) {return -1}
	path := mc_host_path(port, name)
	if !os.exists(path) {return MC_NO_ENTRY}
	if os.is_dir(path) {
		infos, _ := os.read_all_directory_by_path(path, context.temp_allocator)
		if len(infos) > 0 {return MC_NOT_EMPTY}
	}
	return MC_OK if os.remove(path) == nil else MC_DENIED
}

// GetEntSpace: free entries in a directory; a directory cluster holds plenty.
@(private = "file")
mc_get_ent_space :: proc(port: u32, name: string) -> i32 {
	if !mc_port_ok(port) {return -1}
	return 0xfe if os.is_dir(mc_host_path(port, name)) else MC_NO_ENTRY
}

// Emulated state, saved and restored by snapshots (snap.odin).
@(private)
mcserv_snap :: proc() {
	snap_add(&mc)
}
