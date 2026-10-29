#!/bin/sh
# Regression baselines for the ps-recomp move (PLAN.md phase 0).
#
#   tests/baseline.sh record [game|std|snap|all]   write reference outputs to tests/ref/
#   tests/baseline.sh check  [game|std|snap|all]   compare a fresh run against tests/ref/
#
# game: one 22000-frame headless run of the GAME press script. Per-frame guest
#       clock and EE/IOP RAM hashes (NT_DUMP_HASH=1, hashes.tsv) must match
#       ref/hashes.tsv, and the frame-21400 shot
#       must match ref/c_a.ppm (the GAME_OK shot, default GPU GS at scale 1).
# std:  shots at 900 and 2050. GPU GS and software GS (NT_SW=1) must be
#       bit-identical, and both must match ref/std_*.ppm. Only menus: 3D gameplay
#       frames still differ slightly between hw and sw.
# snap: save at 20000, load at 28300 (NT_SNAPTEST); shots 20001, 20002, 28400
#       must match a plain run. Self-contained, no reference files.
#
# References and run output are game-derived and gitignored (tests/ref/, tests/out/).
# Uses port/nicktoons_nbc (override with NT_BIN); build it first with
# port/build.sh.
# Native mode: set NT_NATIVE_FILE to the native_out file from tools/recomp.tsv.
# Every run then loads it, and a run whose log lacks "native: N functions
# from" fails.
# record refuses to overwrite an existing reference unless FORCE=1.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${NT_BIN:-$ROOT/port/nicktoons_nbc}
REF=$ROOT/tests/ref
OUT=$ROOT/tests/out

P="Start@600,Start@900,Start@1200,Start@1500,Cross@2100,Start@2450,Cross@2650,Cross@2850,Cross@3050,Cross@3350,Cross@3650,Cross@3950,Cross@4250,Cross@4550,Cross@4850,Cross@5150,Cross@5450"
P_STD="Start@600,Start@900,Start@1200,Start@1500,Cross@2100"
P_SNAP="$P,Up@21500+400,Square@22400,Cross@22600,Cross@27500,Cross@27700,Cross@27900,Cross@28100"

mode=${1:-}
what=${2:-all}
case $mode in record|check) ;; *) echo "usage: $0 record|check [game|std|snap|all]" >&2; exit 2 ;; esac
[ -x "$BIN" ] || { echo "missing $BIN" >&2; exit 2; }

mkdir -p "$REF" "$OUT"
# The binary reads ../disc, so every run directory sits beside a disc symlink.
[ -e "$OUT/disc" ] || ln -s "$ROOT/disc" "$OUT/disc"

fail=0

if [ -n "${NT_NATIVE_FILE:-}" ]; then
	NT_NATIVE_FILE=$(cd "$(dirname "$NT_NATIVE_FILE")" && pwd)/$(basename "$NT_NATIVE_FILE")
	[ -r "$NT_NATIVE_FILE" ] || { echo "missing $NT_NATIVE_FILE" >&2; exit 2; }
	export NT_NATIVE_FILE
fi

# run NAME ENV...: fresh run dir and empty memcard dir, headless, cwd = run dir.
run() {
	name=$1; shift
	dir=$OUT/$name
	rm -rf "$dir"
	mkdir -p "$dir/mc"
	echo "run $name" >&2
	# NT_HEADLESS also ignores every real controller, which would merge with NT_PRESS input.
	(cd "$dir" && env NT_MC="$dir/mc" NT_HEADLESS=1 "$@" "$BIN" > run.log 2>&1)
	if [ -n "${NT_NATIVE_FILE:-}" ] && ! grep -Eq '^native: [0-9]+ functions from' "$dir/run.log"; then
		echo "FAIL $name: native code not loaded"
		fail=$((fail + 1))
	fi
}

# same A B LABEL: byte compare, report, count failures.
same() {
	if cmp -s "$1" "$2"; then
		echo "ok   $3"
	else
		echo "FAIL $3 ($1 vs $2)"
		fail=$((fail + 1))
	fi
}

# keep SRC DST: record a reference.
keep() {
	if [ -e "$2" ] && [ "${FORCE:-0}" != 1 ]; then
		echo "keep $2 exists; FORCE=1 to overwrite" >&2
		fail=$((fail + 1))
		return
	fi
	cp "$1" "$2"
	echo "rec  $2"
}

game() {
	run game NT_DUMP="$OUT/game" NT_DUMP_HASH=1 NT_SHOT=21400,22000 NT_PRESS="$P"
	if [ "$mode" = record ]; then
		keep "$OUT/game/hashes.tsv" "$REF/hashes.tsv"
		keep "$OUT/game/shot_21400.ppm" "$REF/c_a.ppm"
	else
		same "$OUT/game/hashes.tsv" "$REF/hashes.tsv" "game hashes"
		same "$OUT/game/shot_21400.ppm" "$REF/c_a.ppm" "GAME_OK shot 21400"
	fi
}

std() {
	run std_hw NT_SHOT=900,2050 NT_PRESS="$P_STD"
	run std_sw NT_SW=1 NT_SHOT=900,2050 NT_PRESS="$P_STD"
	for f in 900 2050; do
		same "$OUT/std_hw/shot_$f.ppm" "$OUT/std_sw/shot_$f.ppm" "STD hw == sw $f"
		if [ "$mode" = record ]; then
			keep "$OUT/std_hw/shot_$f.ppm" "$REF/std_$f.ppm"
		else
			same "$OUT/std_hw/shot_$f.ppm" "$REF/std_$f.ppm" "STD shot $f"
		fi
	done
}

snap() {
	run snap_plain NT_SHOT=20001,20002,28400 NT_PRESS="$P_SNAP"
	run snap_load NT_SNAPTEST=20000,28300 NT_SHOT=20001,20002,28400 NT_PRESS="$P_SNAP"
	for f in 20001 20002 28400; do
		same "$OUT/snap_plain/shot_$f.ppm" "$OUT/snap_load/shot_$f.ppm" "snapshot $f"
	done
}

case $what in
	game) game ;;
	std) std ;;
	snap) snap ;;
	all) game; std; snap ;;
	*) echo "unknown test $what" >&2; exit 2 ;;
esac

[ "$fail" = 0 ] || { echo "$fail failed"; exit 1; }
echo "all ok"
