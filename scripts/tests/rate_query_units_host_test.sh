#!/bin/bash
# Build and run the production rate-query handler and rate calculators natively.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${SOURCE_ROOT:-"$HERE/../.."}
ROOT=$(cd "$ROOT" && pwd)
OUT=$(mktemp -d) || exit 1
trap 'rm -rf "$OUT"' EXIT

CFLAGS="-std=gnu11 -O0 -g -ffunction-sections -fdata-sections -DSTA_SUPPORT -DUAP_SUPPORT -DSD9098 -DPCIE9098 -I$ROOT/mlan"
PROD_WARNINGS="-Wno-pointer-to-int-cast -Wno-address-of-packed-member"
TEST_WARNINGS="-Wall -Wextra -Werror -Wno-unused-parameter"

cc $CFLAGS $PROD_WARNINGS -c "$ROOT/mlan/mlan_cmdevt.c" -o "$OUT/mlan_cmdevt.o"
cc $CFLAGS $PROD_WARNINGS -c "$ROOT/mlan/mlan_cfp.c" -o "$OUT/mlan_cfp.o"
cc $CFLAGS $PROD_WARNINGS -c "$ROOT/mlan/mlan_wmm.c" -o "$OUT/mlan_wmm.o"
cc $CFLAGS $TEST_WARNINGS -c "$HERE/rate_query_units_host_test.c" \
	-o "$OUT/rate_query_units_host_test.o"
cc -Wl,--gc-sections -o "$OUT/rate_query_units_host_test" \
	"$OUT/rate_query_units_host_test.o" "$OUT/mlan_cmdevt.o" \
	"$OUT/mlan_cfp.o" "$OUT/mlan_wmm.o"

"$OUT/rate_query_units_host_test"
