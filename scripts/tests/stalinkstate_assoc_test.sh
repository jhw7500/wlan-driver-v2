#!/bin/bash
# Link the same association classifier that processes firmware responses.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

extract_function() {
	local source=$1 name=$2 target=$3 count
	count=$(grep -cE "^static .*\\b${name}\\(" "$source" || true)
	[ "$count" = 1 ] || { echo "$name: found $count definitions" >&2; exit 3; }
	awk -v name="$name" \
		'$0 ~ "^static .*" name "\\(" {copy=1} copy {print} copy && /^}$/ {exit}' \
		"$source" > "$target"
}

extract_function "$root/mlan/mlan_sta_ioctl.c" wlan_get_info_link_snapshot \
	"$out/mlan_snapshot_getter.inc"
for fn in woal_link_standard_name woal_rate_format_name \
	woal_rate_width_name woal_channel_width_name woal_link_band_name \
	woal_get_priv_sta_link_state; do
	extract_function "$root/mlinux/moal_eth_ioctl.c" "$fn" "$out/$fn.inc"
done

cc -std=gnu11 -ffunction-sections -fdata-sections -Wl,--gc-sections \
	-Wno-address-of-packed-member -Wno-pointer-to-int-cast \
	-Wno-pointer-sign -Wno-sign-compare -DDEBUG_LEVEL1 -DSTA_SUPPORT \
	-DUAP_SUPPORT -DSD9098 -DPCIE9098 -I"$root/mlan" -I"$out" \
	"$here/stalinkstate_assoc_test.c" "$root/mlan/mlan_join.c" -o "$out/test"
"$out/test"
