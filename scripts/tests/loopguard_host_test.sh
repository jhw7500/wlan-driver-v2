#!/bin/bash
# Build and run the host unit test for mlinux/moal_bridge_loopguard.h (#117).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d) || exit 1
trap 'rm -rf "$OUT"' EXIT
cc -std=gnu11 -Wall -Wextra -Werror -O2 -o "$OUT/loopguard_host_test" "$HERE/loopguard_host_test.c" || { echo "loopguard host test: BUILD FAILED"; exit 2; }
"$OUT/loopguard_host_test"
