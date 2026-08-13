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

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

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

[ "$(id -u)" -eq 0 ] || fail "run as root"
command -v ip >/dev/null 2>&1 || fail "ip command missing"
command -v iw >/dev/null 2>&1 || fail "iw command missing"
command -v seq >/dev/null 2>&1 || fail "seq command missing"
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
  ''|*[!0-9]*) fail "SWITCH_LOOPS must be a positive integer" ;;
esac
[ "$SWITCH_LOOPS" -gt 0 ] || fail "SWITCH_LOOPS must be a positive integer"
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

printf '%s\n' "$TO_IF" > "$IFACE_PARAM"
[ "$(tr -d '\r\n' < "$IFACE_PARAM")" = "$TO_IF" ] || fail "forward switch failed"
printf '%s\n' "$FROM_IF" > "$IFACE_PARAM"
[ "$(tr -d '\r\n' < "$IFACE_PARAM")" = "$FROM_IF" ] || fail "reverse switch failed"
for _ in $(seq 1 "$SWITCH_LOOPS"); do
  printf '%s\n' "$TO_IF" > "$IFACE_PARAM"
  [ "$(tr -d '\r\n' < "$IFACE_PARAM")" = "$TO_IF" ] || fail "forward stress switch failed"
  printf '%s\n' "$FROM_IF" > "$IFACE_PARAM"
  [ "$(tr -d '\r\n' < "$IFACE_PARAM")" = "$FROM_IF" ] || fail "reverse stress switch failed"
done

cat "$STATS"
switch_ok_after="$(stats_counter switch_ok)" || fail "switch_ok stat missing after test"
switch_fail_after="$(stats_counter switch_fail)" || fail "switch_fail stat missing after test"
rollback_ok_after="$(stats_counter rollback_ok)" || fail "rollback_ok stat missing after test"
rollback_fail_after="$(stats_counter rollback_fail)" || fail "rollback_fail stat missing after test"
expected_ok_delta=$((2 * (SWITCH_LOOPS + 1)))
[ $((switch_ok_after - switch_ok_before)) -eq "$expected_ok_delta" ] ||
  fail "switch_ok delta mismatch: expected $expected_ok_delta"
[ "$switch_fail_after" -eq "$switch_fail_before" ] || fail "switch_fail increased"
[ "$rollback_ok_after" -eq "$rollback_ok_before" ] || fail "rollback_ok increased"
[ "$rollback_fail_after" -eq "$rollback_fail_before" ] || fail "rollback_fail increased"

if ! dmesg_tail="$(dmesg | tail -200)"; then
  fail "unable to read dmesg"
fi
if printf '%s\n' "$dmesg_tail" |
    grep -E 'BUG:|WARNING:|use-after-free|lockdep'; then
  fail "kernel warning detected"
fi
printf 'PASS: %s bidirectional switch cycles\n' "$SWITCH_LOOPS"
