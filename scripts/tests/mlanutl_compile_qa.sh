#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SOURCE_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
QA_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mlanutl-compile-qa.XXXXXX")"
trap 'rm -rf -- "$QA_TMP"' EXIT

# Compile only. No utility command, socket or device ioctl is executed.
read -r -a QA_CC <<<"${CC:-cc}"
FLAGS=(-O2 -D_FORTIFY_SOURCE=2 -DSTA_SUPPORT -DUAP_SUPPORT -Wall
       -Wno-stringop-truncation -Werror=unused-result -Werror=array-bounds
       -I"$ROOT/mapp/mlanutl" -I"$ROOT/mlan")
for name in mlanutl mlanwls; do
    "${QA_CC[@]}" "${FLAGS[@]}" -c "$ROOT/mapp/mlanutl/$name.c" \
        -o "$QA_TMP/$name.o"
done

printf 'mlanutl_compile_qa=PASS\n'
