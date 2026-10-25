#!/bin/sh
# Compile the GS shaders to the SPIR-V that ../hw.odin embeds.
set -e
cd "$(dirname "$0")"
for f in prim.vert prim.frag upload.comp copy.comp scanout.comp clut.comp; do
	glslc -O --target-env=vulkan1.3 "$f" -o "$f.spv"
done
