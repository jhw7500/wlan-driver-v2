#!/bin/bash
# Build and run the monitor-mode radiotap path natively (#125): the production
# wlan_rxpdinfo_to_radiotapinfo() object plus verbatim line ranges of the moal
# radiotap encoder, checked against the RxPD and radiotap field definitions.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${SOURCE_ROOT:-"$HERE/../.."}
ROOT=$(cd "$ROOT" && pwd)
OUT=$(mktemp -d) || exit 1
trap 'rm -rf "$OUT"' EXIT

# moal_shim.c / moal_main.h need the kernel, so copy exact line ranges located
# by content anchors (each start anchor must occur exactly once).
cut_range() {
	local f=$1 sa=$2 ea=$3 extra=$4 out=$5 s n e
	n=$(grep -cF -- "$sa" "$f" || true)
	[ "$n" = 1 ] || { echo "ANCHOR '$sa' occurs $n times in $f" >&2; exit 3; }
	s=$(grep -nF -- "$sa" "$f" | cut -d: -f1)
	e=$(awk -v s="$s" -v a="$ea" 'NR>=s && index($0,a) {print NR; exit}' "$f")
	[ -n "$e" ] || { echo "END ANCHOR '$ea' not found after $f:$s" >&2; exit 3; }
	e=$((e + extra))
	{ echo "/* extracted verbatim: $(basename "$f"):$s-$e */"; sed -n "${s},${e}p" "$f"; } > "$out"
}

MS=$ROOT/mlinux/moal_shim.c
MH=$ROOT/mlinux/moal_main.h
GEN=$OUT/gen
mkdir -p "$GEN"
cut_range "$MH" '/** mcs_field.known */' '/** radiotap_body.flags */' -2 "$GEN/moal_rt_defs.inc"
cut_range "$MS" 't_u8 ru_signal[16][9] =' 't_u8 ru_signal_52[9] =' 0 "$GEN/moal_ru_tables.inc"
cut_range "$MS" 'ldpc = (rt_info.rate_info.rate_info & 0x20) >>' 'nss = rt_info.rate_info.nss_index;' 0 "$GEN/moal_field_decode.inc"
cut_range "$MS" '/** MCS: bit number 19 */' '/** VHT: bit number 21, Required Alignment is 2' -1 "$GEN/moal_ht_block.inc"
cut_range "$MS" '/** HE: bit number 23, Required Alignment is 2' 'radiotap_len += sizeof(struct he_field);' 1 "$GEN/moal_he_block.inc"

CFLAGS="-std=gnu11 -O0 -g -ffunction-sections -fdata-sections -DSTA_SUPPORT -DUAP_SUPPORT -DSD9098 -DPCIE9098 -I$ROOT/mlan"
PROD_WARNINGS="-Wno-pointer-to-int-cast -Wno-address-of-packed-member"
TEST_WARNINGS="-Wall -Werror -Wno-unused-variable -Wno-unused-but-set-variable"

for f in mlan_sta_rx mlan_cfp mlan_wmm; do
	cc $CFLAGS $PROD_WARNINGS -c "$ROOT/mlan/$f.c" -o "$OUT/$f.o"
done
cc $CFLAGS -I"$GEN" $TEST_WARNINGS -c "$HERE/radiotap_he_gi_host_test.c" \
	-o "$OUT/radiotap_he_gi_host_test.o"
cc -Wl,--gc-sections -o "$OUT/radiotap_he_gi_host_test" \
	"$OUT/radiotap_he_gi_host_test.o" "$OUT/mlan_sta_rx.o" \
	"$OUT/mlan_cfp.o" "$OUT/mlan_wmm.o"

"$OUT/radiotap_he_gi_host_test"
