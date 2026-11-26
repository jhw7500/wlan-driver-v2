#!/bin/bash
# Link the same association classifier that processes firmware responses.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

cc -std=gnu11 -ffunction-sections -fdata-sections -Wl,--gc-sections \
	-Wno-address-of-packed-member -Wno-pointer-to-int-cast \
	-DDEBUG_LEVEL1 -DSTA_SUPPORT -DUAP_SUPPORT -DSD9098 -DPCIE9098 -I"$root/mlan" \
	"$here/stalinkstate_assoc_test.c" "$root/mlan/mlan_join.c" -o "$out/test"
"$out/test"
