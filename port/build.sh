#!/bin/sh
# Build the port.
#
#   port/build.sh [release|debug]
#
# release (default): optimized, no bounds checks -> port/nicktoons_nbc, the
#   binary tests/baseline.sh runs; port/nicktoons links to it.
# debug: optimized with bounds checks and debug info (gdb, perf) ->
#   port/nicktoons-debug. Unoptimized (-o:none) builds run the generated
#   code too slowly to play, so debug keeps -o:speed.
#
# PS_RECOMP overrides the ps-recomp checkout; port/src/rec must already be
# generated (see tools/recomp.tsv).
set -e
cd "$(dirname "$0")"
PS_RECOMP=${PS_RECOMP:-../ps-recomp}
COMMON="-collection:ps=$PS_RECOMP -define:ENV_PREFIX=NT_ -use-separate-modules -o:speed -thread-count:4"

case ${1:-release} in
release)
	nice -n 19 odin build src -out:nicktoons_nbc.new $COMMON -no-bounds-check
	mv nicktoons_nbc.new nicktoons_nbc
	ln -sfn nicktoons_nbc nicktoons
	echo "built port/nicktoons_nbc (port/nicktoons links to it)"
	;;
debug)
	nice -n 19 odin build src -out:nicktoons-debug.new $COMMON -debug
	mv nicktoons-debug.new nicktoons-debug
	echo "built port/nicktoons-debug"
	;;
*)
	echo "usage: $0 [release|debug]" >&2
	exit 2
	;;
esac
