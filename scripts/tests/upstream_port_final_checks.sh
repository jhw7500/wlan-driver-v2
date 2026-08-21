#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

python3 "$SCRIPT_DIR/upstream_port_invariants.py"
bash "$SCRIPT_DIR/antcfg_cli_qa.sh"
bash "$SCRIPT_DIR/make_for_imx93_qa.sh"
bash "$SCRIPT_DIR/bridge_static_checks.sh"
cmp -s "$ROOT/mlan/mlan_ioctl.h" "$ROOT/mlinux/mlan_ioctl.h"

printf 'upstream_port_final_checks=PASS\n'
