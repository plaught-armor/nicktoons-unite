# Nicktoons Unite! native port

A native Linux port of *Nicktoons Unite!* (PS2, NTSC-U, SLUS-212.84), built
with [ps-recomp](https://github.com/plaught-armor/ps-recomp). The game's EE
code is recompiled ahead of time into Odin (and optionally x86-64 machine
code) and runs against ps-recomp's HLE kernel, IOP, GS and SPU2.

This repository holds no game code or data. You need your own copy of the
game disc; the build turns its executable into the port's code on your
machine.

## Requirements

- Linux on x86-64 (the only tested platform)
- Odin `dev-2026-10` (84bc3fc21)
- SDL2
- Vulkan 1.3 GPU and driver (the GS renderer; `NT_SW=1` uses the software
  renderer instead)
- `7z` (p7zip) to unpack the disc image

## Setup

Clone with the submodule, which pins the ps-recomp version this port is
tested against:

```sh
git clone --recursive https://github.com/plaught-armor/nicktoons-unite.git
cd nicktoons-unite
# or, in an existing clone:
git submodule update --init
```

Unpack your disc image into `disc/` at the repository root:

```sh
7z x "/path/to/Nicktoons Unite!.iso" -odisc
```

`disc/` must then hold `SLUS_212.84`, `DATA.ISO`, `DUMMY.DAT`, `MODULES/`
and `SYSTEM.CNF`.

## Building

From the repository root:

```sh
# 1. Build the recompiler.
(cd ps-recomp && odin build recomp -collection:ps=. -out:../recomp-bin -o:speed)

# 2. Recompile the game's executable. Writes port/src/rec/ (Odin) and
#    port/native_x64.bin (x86-64 machine code).
./recomp-bin tools/recomp.tsv

# 3. Build the port: port/nicktoons.
port/build.sh
```

Step 2 generates code from your disc. `port/src/rec/` and
`port/native_x64.bin` are a translation of the game's executable: they are
ignored by git and must never be committed or shared. Run step 2 again after
updating the ps-recomp submodule.

`port/build.sh debug` builds `port/nicktoons-debug` with bounds checks and
debug info.

## Running

```sh
NT_NATIVE_FILE=port/native_x64.bin ./port/nicktoons
```

The port finds `disc/` relative to its own location, so it starts from any
directory; a path to `SLUS_212.84` as the first argument overrides that.
`NT_NATIVE_FILE` is relative to the working directory, so from elsewhere
give its full path. It runs the x86-64 code from step 2 in place of the Odin
functions and is the faster way to play; without it the Odin code runs.
Memory card saves go to `memcard0/` and `memcard1/` in the working directory.

Settings are environment variables:

| Variable | Effect |
|---|---|
| `NT_NATIVE_FILE` | x86-64 code file to run (see above) |
| `NT_SCALE` | GS render scale, 1 to 8 |
| `NT_SW=1` | software GS renderer |
| `NT_PLAYERS` | number of connected pads, 1 to 4 (multitap) |
| `NT_STATS=1` | print frame and audio timing |
| `NT_NET_PEER` | `host:port` of the other player for netplay |
| `NT_NET_BIND` | local netplay address, default `0.0.0.0:7000` |
| `NT_NET_PLAYER` | this side's player number, 1 or 2 |
| `NT_NET_DELAY` | netplay input delay in frames, default 2 |

Controllers go through SDL2; a `gamecontrollerdb.txt` in the working
directory adds mappings for pads SDL does not know.

## Known issues

- Only Linux is tested.
- Netplay uses rollback, which needs Linux 6.7 or newer; local play does not.
- Netplay is 2 players; local play supports 4 through the multitap.
- Reverb ignores the delay and feedback settings.
- Voices in the movie sound driver (sdrdrv) play without reverb.
- The hardware and software GS renderers differ slightly in some 3D gameplay
  frames.
- There is no settings menu; everything is set by environment variables.

## License

GPL-3.0; see `LICENSE`. *Nicktoons Unite!* and its content belong to their
respective owners; this project is not affiliated with them.
