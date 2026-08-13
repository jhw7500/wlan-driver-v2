#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

PARAM_DIR=/sys/module/moal/parameters
IFACE_PARAM="$PARAM_DIR/bridge_iface"
GATE_PARAM="$PARAM_DIR/bridge_runtime_switch"
STATS=/sys/kernel/moal_bridge/stats
FROM_IF="${FROM_IF:-mlan0}"
TO_IF="${TO_IF:-mlan1}"
SWITCH_LOOPS="${SWITCH_LOOPS:-100}"
MAX_SWITCH_LOOPS=100000
DMESG_DELTA_LOG="${DMESG_DELTA_LOG:-/tmp/bridge-runtime-switch-dmesg-delta.log}"
DMESG_BASELINE=
DMESG_AFTER=
DMESG_DELTA=

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  local path

  for path in "$DMESG_BASELINE" "$DMESG_AFTER" "$DMESG_DELTA"; do
    [ -z "$path" ] || rm -f -- "$path"
  done
}

trap cleanup EXIT

stats_counter() {
  awk -v key="$1" '
    {
      for (i = 1; i <= NF; i++) {
        split($i, field, "=")
        if (field[1] == key) {
          print field[2]
          found = 1
          exit
        }
      }
    }
    END { exit !found }
  ' "$STATS"
}

require_associated() {
  local iface="$1" link_state

  if ! link_state="$(iw dev "$iface" link 2>&1)"; then
    fail "cannot query $iface association: $link_state"
  fi
  printf '%s\n' "$link_state" | grep -q '^Connected to ' ||
    fail "$iface is not associated; operator must associate both links"
}

switch_iface() {
  local direction="$1" target="$2" iteration="$3" effective

  if ! printf '%s\n' "$target" > "$IFACE_PARAM"; then
    fail "$direction switch write failed: iteration=$iteration target=$target"
  fi
  if ! effective="$(tr -d '\r\n' < "$IFACE_PARAM")"; then
    fail "$direction switch read failed: iteration=$iteration target=$target"
  fi
  [ "$effective" = "$target" ] ||
    fail "$direction switch mismatch: iteration=$iteration target=$target effective=$effective"
}

[ "$(id -u)" -eq 0 ] || fail "run as root"
command -v ip >/dev/null 2>&1 || fail "ip command missing"
command -v iw >/dev/null 2>&1 || fail "iw command missing"
for command_name in cmp cp dmesg head mktemp tail tr wc; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name command missing"
done
[ -e "$IFACE_PARAM" ] || fail "missing $IFACE_PARAM"
[ -r "$IFACE_PARAM" ] || fail "$IFACE_PARAM is not readable"
[ -w "$IFACE_PARAM" ] || fail "$IFACE_PARAM is not writable"
[ -e "$GATE_PARAM" ] || fail "missing $GATE_PARAM"
[ -r "$GATE_PARAM" ] || fail "$GATE_PARAM is not readable"
[ "$(tr -d '\r\n' < "$GATE_PARAM")" = 1 ] ||
  fail "reload with bridge_runtime_switch=1"
[ -r "$STATS" ] || fail "missing or unreadable $STATS"
[ "$FROM_IF" != "$TO_IF" ] || fail "FROM_IF and TO_IF must differ"
case "$SWITCH_LOOPS" in
  ''|0|0*|*[!0-9]*)
    fail "SWITCH_LOOPS must use canonical decimal in range 1..$MAX_SWITCH_LOOPS"
    ;;
esac
[ "${#SWITCH_LOOPS}" -le 6 ] ||
  fail "SWITCH_LOOPS exceeds upper bound $MAX_SWITCH_LOOPS"
SWITCH_LOOPS=$((10#$SWITCH_LOOPS))
[ "$SWITCH_LOOPS" -le "$MAX_SWITCH_LOOPS" ] ||
  fail "SWITCH_LOOPS exceeds upper bound $MAX_SWITCH_LOOPS"
ip link show "$FROM_IF" >/dev/null 2>&1 || fail "$FROM_IF missing"
ip link show "$TO_IF" >/dev/null 2>&1 || fail "$TO_IF missing"
require_associated "$FROM_IF"
require_associated "$TO_IF"
[ "$(tr -d '\r\n' < "$IFACE_PARAM")" = "$FROM_IF" ] ||
  fail "active bridge is not $FROM_IF; operator must prepare the initial binding"

switch_ok_before="$(stats_counter switch_ok)" || fail "switch_ok stat missing"
switch_fail_before="$(stats_counter switch_fail)" || fail "switch_fail stat missing"
rollback_ok_before="$(stats_counter rollback_ok)" || fail "rollback_ok stat missing"
rollback_fail_before="$(stats_counter rollback_fail)" || fail "rollback_fail stat missing"

DMESG_BASELINE="$(mktemp)" || fail "cannot create dmesg baseline file"
DMESG_AFTER="$(mktemp)" || fail "cannot create dmesg after file"
DMESG_DELTA="$(mktemp)" || fail "cannot create dmesg delta file"
if ! dmesg > "$DMESG_BASELINE"; then
  fail "unable to capture dmesg baseline"
fi
dmesg_baseline_lines="$(wc -l < "$DMESG_BASELINE")" ||
  fail "unable to count dmesg baseline"

switch_iface forward "$TO_IF" 0
switch_iface reverse "$FROM_IF" 0
for ((iteration = 1; iteration <= SWITCH_LOOPS; iteration++)); do
  switch_iface forward "$TO_IF" "$iteration"
  switch_iface reverse "$FROM_IF" "$iteration"
done

cat "$STATS"
switch_ok_after="$(stats_counter switch_ok)" || fail "switch_ok stat missing after test"
switch_fail_after="$(stats_counter switch_fail)" || fail "switch_fail stat missing after test"
rollback_ok_after="$(stats_counter rollback_ok)" || fail "rollback_ok stat missing after test"
rollback_fail_after="$(stats_counter rollback_fail)" || fail "rollback_fail stat missing after test"
expected_ok_delta=$((2 * (SWITCH_LOOPS + 1)))
actual_ok_delta=$((switch_ok_after - switch_ok_before))
[ "$actual_ok_delta" -eq "$expected_ok_delta" ] ||
  fail "switch_ok delta mismatch: expected=$expected_ok_delta actual=$actual_ok_delta"
[ "$switch_fail_after" -eq "$switch_fail_before" ] || fail "switch_fail increased"
[ "$rollback_ok_after" -eq "$rollback_ok_before" ] || fail "rollback_ok increased"
[ "$rollback_fail_after" -eq "$rollback_fail_before" ] || fail "rollback_fail increased"

if ! dmesg > "$DMESG_AFTER"; then
  fail "unable to capture dmesg after switching"
fi
dmesg_after_lines="$(wc -l < "$DMESG_AFTER")" ||
  fail "unable to count dmesg after switching"
[ "$dmesg_after_lines" -ge "$dmesg_baseline_lines" ] ||
  fail "dmesg buffer rotated or was cleared; warning delta is unverifiable"
if ! head -n "$dmesg_baseline_lines" "$DMESG_AFTER" |
    cmp -s "$DMESG_BASELINE" -; then
  fail "dmesg buffer rotated or was cleared; warning delta is unverifiable"
fi
tail -n "+$((dmesg_baseline_lines + 1))" "$DMESG_AFTER" > "$DMESG_DELTA" ||
  fail "unable to extract dmesg delta"
cp "$DMESG_DELTA" "$DMESG_DELTA_LOG" ||
  fail "unable to preserve dmesg delta at $DMESG_DELTA_LOG"
printf '%s\n' "--- dmesg delta: $DMESG_DELTA_LOG ---"
cat "$DMESG_DELTA"
if grep -E 'BUG:|WARNING:|use-after-free|lockdep' "$DMESG_DELTA"; then
  fail "kernel warning detected"
fi
printf 'PASS: %s bidirectional switch cycles\n' "$SWITCH_LOOPS"
