// The SIF link to the IOP, emulated at the sifcmd packet level.
//
// There is no IOP processor: DMA the EE sends to the IOP lands in an 8 MB
// buffer, command packets addressed to the IOP's command buffer are handled
// here, and replies are written into the EE's receive buffer followed by a
// SIF0 DMAC interrupt, exactly as the real IOP's sifcmd would deliver them.
// RPC servers (loadfile, file I/O, CD, pad, ...) are implemented in Odin.
package ee

import "core:fmt"
import "core:os"
import "core:strings"
import "ps:core"

IOP_RAM_SIZE :: 8 << 20
IOP_CMDBUF :: 0x0001f000 // where the IOP receives command packets
IOP_SERVERS :: 0x00100000 // fake server descriptors and receive buffers

SIF_CMD_CHANGE_SADDR :: 0x80000000
SIF_CMD_SET_SREG :: 0x80000001
SIF_CMD_INIT_CMD :: 0x80000002
SIF_CMD_RESET :: 0x80000003
SIF_CMD_RPC_END :: 0x80000008
SIF_CMD_RPC_BIND :: 0x80000009
SIF_CMD_RPC_CALL :: 0x8000000a
SIF_CMD_RPC_RDATA :: 0x8000000c

SIF_STAT_SIFINIT :: 0x10000
SIF_STAT_CMDINIT :: 0x20000
SIF_STAT_BOOTEND :: 0x40000

iop_ram: []u8

// Host directory holding the disc's files; `cdrom0:\X;1` opens disc_dir/X.
disc_dir := "."

// An RPC server: gets the function number and the request in the server's
// buffer, writes its reply into the same buffer.
Rpc_Server :: proc(fno: u32, buf: []u8, send_size: u32) -> (ok: bool)

@(private)
sif: struct {
	mscom, smcom, msflg, smflg, ctrl, bd6: u32,
	sreg:      [32]u32,
	ee_buf:    u32, // EE receive buffer for replies
	replies:   [dynamic][]u8,
	servers:   map[u32]Rpc_Server,
	bound:     map[u32]u32, // sid -> fake server descriptor address
	next_dma:  i32,
}

sif_init :: proc() {
	iop_ram = core.snap_area(IOP_RAM_SIZE)
	sif.smflg = SIF_STAT_SIFINIT | SIF_STAT_CMDINIT | SIF_STAT_BOOTEND
	sif.sreg[0] = IOP_CMDBUF // SIF_SYSREG_SUBADDR
	sif.next_dma = 1
	pad_init()
	sif.servers[0x80000006] = loadfile_server
	sif.servers[0x80000001] = fileio_server
	sif.servers[0x80000592] = cdvd_init_server
	sif.servers[0x80000593] = cdvd_scmd_server
	sif.servers[0x8000059a] = cdvd_ready_server
	sif.servers[0x8000059c] = cdvd_ready_server
	sif.servers[0x80000003] = iop_heap_server
	sif.servers[0x80000400] = mcserv_server
	sif.servers[0x80000100] = padman_server
	sif.servers[0x80000101] = padman_server
	sif.servers[0x80000900] = mtap_server
	sif.servers[0x80000701] = sdr_server
}

iop_u32 :: #force_inline proc(a: u32) -> ^u32 {
	return (^u32)(&iop_ram[a & (IOP_RAM_SIZE - 4)])
}

sif_reg_read :: proc(o: u32) -> u32 {
	switch o &~ 0xf {
	case 0xf200: return sif.mscom
	case 0xf210: return sif.smcom
	case 0xf220: return sif.msflg
	case 0xf230: return sif.smflg
	case 0xf240: return sif.ctrl
	case 0xf260: return sif.bd6
	}
	return 0
}

sif_reg_write :: proc(o: u32, v: u32) {
	switch o &~ 0xf {
	case 0xf200: sif.mscom = v
	case 0xf210: sif.smcom = v
	case 0xf220: sif.msflg |= v
	case 0xf230: // EE writes clear bits; the HLE IOP stays booted
	case 0xf240: sif.ctrl = v
	case 0xf260: sif.bd6 = v
	}
}

// SifSetReg / SifGetReg: 1-4 are the hardware registers, 0x80000000+ the
// software registers sifcmd keeps.
sif_reg_set :: proc(reg, v: u32) {
	switch reg {
	case 1: sif.mscom = v
	case 2: sif.smcom = v
	case 3: sif.msflg |= v
	case 4:
	case 0x80000000: // SUBADDR: cleared on IOP reset, but the HLE IOP's
		// command buffer never moves
	case:
		if reg & 0x80000000 != 0 {sif.sreg[reg & 31] = v}
	}
}

sif_reg_get :: proc(reg: u32) -> u32 {
	switch reg {
	case 1: return sif.mscom
	case 2: return sif.smcom
	case 3: return sif.msflg
	case 4: return sif.smflg
	}
	if reg & 0x80000000 != 0 {return sif.sreg[reg & 31]}
	return 0
}

sif_dma_stat :: proc(id: i32) -> i64 {
	return -1 // every transfer completes immediately
}

// SifSetDma(list, count): copy each {src, dest, size, attr} to IOP memory and
// act on command packets.
sif_set_dma :: proc(list, count: u32) -> u32 {
	for n in 0 ..< count {
		e := list + n * 16
		src, dest, size := rd32(e), rd32(e + 4), rd32(e + 8)
		d := dest & (IOP_RAM_SIZE - 1)
		size = min(size, IOP_RAM_SIZE - d)
		copy(iop_ram[d:][:size], ram_slice(src, size))
		if k.debug == 2 {fmt.eprintfln("sif: dma %08x -> %08x size %x (%d/%d)", src, dest, size, n, count)}
		if d == IOP_CMDBUF {sif_command(d)}
	}
	id := sif.next_dma
	sif.next_dma = sif.next_dma % 0xffff + 1
	return u32(id)
}

// Queue a packet for the EE: header {psize | dsize << 8, dest, cid, opt}.
@(private)
sif_reply :: proc(cid: u32, opt: u32, payload: []u32) {
	p := make([]u8, 16 + 4 * len(payload))
	w := ([^]u32)(raw_data(p))
	w[0] = u32(len(p))
	w[2] = cid
	w[3] = opt
	for v, i in payload {w[4 + i] = v}
	append(&sif.replies, p)
	if !k.in_interrupt {next_event = cpu.cycles}
}

// Move the next queued reply into the EE buffer once the EE has consumed
// the previous one. Called while delivering interrupts.
sif_pump :: proc() {
	if len(sif.replies) == 0 || sif.ee_buf == 0 || dmac_stat & (1 << DMA_SIF0) != 0 {return}
	p := sif.replies[0]
	ordered_remove(&sif.replies, 0)
	copy(ram_slice(sif.ee_buf, u32(len(p))), p)
	delete(p)
	dmac_stat |= 1 << DMA_SIF0
}

@(private)
sif_command :: proc(a: u32) {
	cid := iop_u32(a + 8)^
	if k.debug == 2 {fmt.eprintfln("sif: cmd %08x opt %x a0 %08x ee_buf %08x", cid, iop_u32(a + 12)^, iop_u32(a + 16)^, sif.ee_buf)}
	opt := iop_u32(a + 12)^
	arg :: proc(a: u32, n: u32) -> u32 {return iop_u32(a + 16 + 4 * n)^}
	switch cid {
	case SIF_CMD_CHANGE_SADDR:
		sif.ee_buf = arg(a, 0)
	case SIF_CMD_SET_SREG:
		sif.sreg[arg(a, 0) & 31] = arg(a, 1)
	case SIF_CMD_INIT_CMD:
		if opt == 0 {
			sif_reply(SIF_CMD_INIT_CMD, 1, {})
			sif.sreg[2] = 1 // SIF_SYSREG_RPCINIT
		}
		// sceSifInitRpc then spins on the EE-side software register
		// SIF_SREG_RPCINIT (0), which the IOP sets with a SET_SREG packet.
		sif_reply(SIF_CMD_SET_SREG, 0, {0, 1})
	case SIF_CMD_RESET:
		path := cstring(&iop_ram[a + 24])
		fmt.eprintfln("sif: IOP reset \"%s\"", path)
		clear(&sif.bound)
		sif.ee_buf = 0
		clear(&sif.replies)
	case SIF_CMD_RPC_BIND:
		rec_id, pkt, rpc_id, client, sid := arg(a, 0), arg(a, 1), arg(a, 2), arg(a, 3), arg(a, 4)
		sd, ok := sif.bound[sid]
		if !ok {
			sd = IOP_SERVERS + u32(len(sif.bound)) * 0x10000
			sif.bound[sid] = sd
			if sid not_in sif.servers {fmt.eprintfln("sif: bind to unimplemented server %08x", sid)}
		}
		iop_u32(sd)^ = sid
		sif_reply(SIF_CMD_RPC_END, 0, {rec_id, pkt, rpc_id, client, SIF_CMD_RPC_BIND, sd, sd + 0x100, sd + 0x100})
	case SIF_CMD_RPC_CALL:
		rec_id, pkt, rpc_id, client := arg(a, 0), arg(a, 1), arg(a, 2), arg(a, 3)
		fno, send_size, receive, recv_size, server := arg(a, 4), arg(a, 5), arg(a, 6), arg(a, 7), arg(a, 9)
		sid := iop_u32(server)^
		buf := iop_ram[(server + 0x100) & (IOP_RAM_SIZE - 1):][:0xff00]
		handler, ok := sif.servers[sid]
		if !ok || !handler(fno, buf, send_size) {
			fmt.eprintfln("sif: unhandled rpc %08x fno %d send %d recv %d", sid, fno, send_size, recv_size)
		}
		if receive != 0 && recv_size != 0 {
			copy(ram_slice(receive, recv_size), buf[:min(recv_size, u32(len(buf)))])
		}
		sif_reply(SIF_CMD_RPC_END, 0, {rec_id, pkt, rpc_id, client, SIF_CMD_RPC_CALL, server, 0, 0})
	case SIF_CMD_RPC_RDATA:
		rec_id, pkt, rpc_id, client := arg(a, 0), arg(a, 1), arg(a, 2), arg(a, 3)
		src, dest, size := arg(a, 4), arg(a, 5), arg(a, 6)
		s := src & (IOP_RAM_SIZE - 1)
		copy(ram_slice(dest, size), iop_ram[s:][:min(size, IOP_RAM_SIZE - s)])
		sif_reply(SIF_CMD_RPC_END, 0, {rec_id, pkt, rpc_id, client, SIF_CMD_RPC_RDATA, 0, 0, 0})
	case:
		if cid & 0x80000000 == 0 {
			fmod_command(cid, opt, a)
		} else {
			fmt.eprintfln("sif: unhandled command %08x", cid)
		}
	}
}

// ------------------------------------------------------------- servers

// loadfile: modules are native here, so loading one only reports success.
@(private)
loadfile_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	switch fno {
	case 0: // LoadModule {result, modres, path[252], args[252]}
		fmt.eprintfln("sif: load module \"%s\"", cstring(&buf[8]))
		w[0] = 2
		w[1] = 0
		return true
	case 255: // version handshake: the EE library checks for "3000"
		copy(buf, "3000")
		return true
	}
	return false
}

// fileio: the EE library sends {sema, result ptr, result size, args...} and
// waits on `sema`. The IOP writes a reply {sema, command, result ptr, result
// size, result, extra...} to the EE buffer it was given at init, then sends
// command 0x80000011, whose EE handler copies the result and signals `sema`.
FILEIO_REPLY :: 0x80000011
ENOENT :: 2
EBADF :: 9

@(private)
fileio: struct {
	reply_buf: u32,
	files:     [dynamic]Iop_File, // fd = index; nil handle is a free slot
}

@(private)
Iop_File :: struct {
	f:   ^os.File,
	pos: i64,
	size: i64,
}

@(private)
fileio_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	if fno == 255 { // init: {reply buffer, second buffer} -> {version, slots}
		fileio.reply_buf = w[0]
		copy(buf, "3000")
		w[1] = 0 // one reply buffer
		return true
	}
	result: i32
	extra: [3]u32 // READ: unaligned head/tail sizes (zero: data goes straight to RAM)
	switch fno {
	case 0: // OPEN {hdr, flags, mode, name[0x400], slot}
		result = fileio_open(string(cstring(&buf[0x14])), w[3])
	case 1: // CLOSE {hdr, fd, slot}
		if f := fileio_file(w[3]); f != nil {
			f^ = {} // the host file stays open: see disc_open
		} else {result = -EBADF}
	case 2: // READ {hdr, fd, buffer, size, slot}
		f := fileio_file(w[3])
		if f == nil {result = -EBADF; break}
		n := i64(min(w[5], u32(max(f.size - f.pos, 0))))
		got, _ := os.read_at(f.f, ram_slice(w[4], u32(n)), f.pos)
		f.pos += i64(got)
		result = i32(got)
	case 3: // WRITE {hdr, fd, buffer, size, unaligned size, data...}: read-only disc
		result = -EBADF
	case 4: // SEEK {hdr, fd, offset, whence, slot}
		f := fileio_file(w[3])
		if f == nil {result = -EBADF; break}
		base := [3]i64{0, f.pos, f.size}
		if w[5] > 2 {result = -22; break}
		f.pos = clamp(base[w[5]] + i64(i32(w[4])), 0, f.size)
		result = i32(f.pos)
	case:
		return false
	}
	if k.debug == 2 {fmt.eprintfln("fileio: fno %d fd %d -> %d", fno, i32(w[3]), result)}
	if fileio.reply_buf != 0 {
		r := ([^]u32)(raw_data(ram_slice(fileio.reply_buf, 0x20)))
		r[0], r[1], r[2], r[3] = w[0], fno, w[1], w[2]
		r[4] = u32(result)
		r[5], r[6], r[7] = extra[0], extra[1], extra[2]
	}
	sif_reply(FILEIO_REPLY, 0, {})
	w[0] = 1 // accepted; zero makes the EE library return EAGAIN
	return true
}

@(private)
fileio_file :: proc(fd: u32) -> ^Iop_File {
	if int(fd) >= len(fileio.files) || fileio.files[fd].f == nil {return nil}
	return &fileio.files[fd]
}

// Disc files stay open for the life of the process, one handle per path: a
// snapshot may hold a handle the game closed after it was taken.
@(private)
disc_files: map[string]^os.File

@(private)
disc_open :: proc(path: string) -> (f: ^os.File, err: os.Error) {
	context.allocator = core.host_allocator
	if cached, ok := disc_files[path]; ok {return cached, nil}
	f = os.open(path) or_return
	disc_files[strings.clone(path)] = f
	return f, nil
}

@(private)
fileio_open :: proc(name: string, flags: u32) -> i32 {
	path, ok := host_path(name)
	if !ok || flags & 3 != 1 { // O_RDONLY is 1 in the IOP's ioman
		fmt.eprintfln("fileio: open \"%s\" flags %x failed", name, flags)
		return -ENOENT
	}
	f, err := disc_open(path)
	if err != nil {
		fmt.eprintfln("fileio: open \"%s\" (%s) failed", name, path)
		return -ENOENT
	}
	size, _ := os.file_size(f)
	if k.debug >= 1 {fmt.eprintfln("fileio: open \"%s\" -> %s (%d bytes)", name, path, size)}
	for &e, i in fileio.files {
		if e.f == nil {
			e = {f, 0, size}
			return i32(i)
		}
	}
	append(&fileio.files, Iop_File{f, 0, size})
	return i32(len(fileio.files) - 1)
}

// Map an IOP device path ("cdrom0:\DIR\FILE.EXT;1") to a file under
// disc_dir, matching each component case-insensitively as ISO9660 does.
@(private)
host_path :: proc(name: string) -> (string, bool) {
	rest := name
	if i := strings.index_byte(rest, ':'); i >= 0 {rest = rest[i + 1:]}
	if i := strings.index_byte(rest, ';'); i >= 0 {rest = rest[:i]}
	rest, _ = strings.replace_all(rest, "\\", "/", context.temp_allocator)
	dir := disc_dir
	for part in strings.split_iterator(&rest, "/") {
		if part == "" || part == "." {continue}
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {return "", false}
		found := false
		for e in entries {
			if strings.equal_fold(e.name, part) {
				dir = strings.clone(e.fullpath, context.temp_allocator)
				found = true
				break
			}
		}
		if !found {return "", false}
	}
	return dir, dir != disc_dir
}

// Replies are modelled on what Play!'s HLE modules return.

// Answers every call with zeros: "no device" or "nothing to do".
@(private)
zero_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	if k.debug >= 1 {fmt.eprintfln("sif: stub rpc fno %d send %d", fno, send_size)}
	for &b in buf[:64] {b = 0}
	return true
}

// IOP heap (sceSifAllocIopHeap, sceSifFreeIopHeap): a bump allocator over
// IOP RAM no HLE module uses. Frees are ignored.
IOP_HEAP_START :: 0x00040000
IOP_HEAP_END :: IOP_SERVERS

@(private = "file")
iop_heap_top: u32 = IOP_HEAP_START

@(private)
iop_heap_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	switch fno {
	case 1: // alloc {size} -> address, 0 when full
		size := (w[0] + 0xff) &~ 0xff
		if iop_heap_top + size > IOP_HEAP_END {
			w[0] = 0
		} else {
			w[0] = iop_heap_top
			iop_heap_top += size
		}
		if k.debug >= 1 {fmt.eprintfln("sif: iop heap alloc %x -> %x", size, w[0])}
	case 2: // free {address} -> 0
		w[0] = 0
	case:
		return false
	}
	return true
}

// cdvdfsv init: {result, cdvdfsv version, cdvdman version, 0xff}.
@(private)
cdvd_init_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	if fno != 0 {return false}
	w[0], w[1], w[2], w[3] = 1, 0, 0, 0xff
	return true
}

// cdvdfsv S-commands. Everything succeeds; the disc is a ready PS2 DVD.
@(private)
cdvd_scmd_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	switch fno {
	case 0x01: // ReadClock {result, clock[8]}
		w[0], w[1], w[2] = 1, 0, 0
	case 0x03: w[0] = 0x14 // GetDiskType: PS2 DVD
	case 0x04: w[0] = 0 // GetError
	case 0x05: w[0], w[1] = 1, 0 // TrayReq {result, tray check}
	case 0x0c: w[0] = 0x0a // Status: paused
	case 0x16, 0x22: w[0] = 1 // Break, MMode
	case: return false
	}
	return true
}

// cdvdfsv DiskReady: 2 is ready.
@(private)
cdvd_ready_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	if fno != 0 {return false}
	(^u32)(raw_data(buf))^ = 2
	return true
}

// Emulated state, saved and restored by snapshots (snap.odin).
@(private)
sif_snap :: proc() {
	core.snap_add(&sif)
	core.snap_add(&fileio)
	core.snap_add(&iop_heap_top)
}
