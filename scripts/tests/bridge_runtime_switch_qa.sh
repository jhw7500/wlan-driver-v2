#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

PARAM_DIR=/sys/module/moal/parameters
IFACE_PARAM="$PARAM_DIR/bridge_iface"
GATE_PARAM="$PARAM_DIR/bridge_runtime_switch"
FAULT_PARAM="$PARAM_DIR/bridge_switch_fault_mask"
STATS=/sys/kernel/moal_bridge/stats
QA_CASE="${QA_CASE:-stress}"
FROM_IF="${FROM_IF:-mlan0}"
TO_IF="${TO_IF:-mlan1}"
PEER_IF="${PEER_IF:-eth0}"
REJECT_TARGET="${REJECT_TARGET:-does-not-exist}"
EXPECTED_ERRNO="${EXPECTED_ERRNO:-19}"
SWITCH_LOOPS="${SWITCH_LOOPS:-100}"
MAX_SWITCH_LOOPS=100000
INTERACTION_TIMEOUT="${INTERACTION_TIMEOUT:-120}"
QA_EVIDENCE_DIR="${QA_EVIDENCE_DIR:-/tmp/bridge-runtime-switch-qa.$(date +%Y%m%d-%H%M%S).$$}"
DMESG_STREAM="$QA_EVIDENCE_DIR/dmesg-follow.log"
DMESG_STREAM_PID=
INITIAL_BINDING=
PEER_TOUCHED=0
PEER_WAS_UP=0
TO_TOUCHED=0
TO_WAS_ADMIN_UP=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

read_binding() {
  if [ -r "$IFACE_PARAM" ]; then
    tr -d '\r\n' < "$IFACE_PARAM"
  else
    printf 'unavailable'
  fi
}

capture_state() {
  local label="$1"

  {
    printf 'label=%s\n' "$label"
    date -Ins 2>/dev/null || date
    printf 'qa_case=%s initial_binding=%s current_binding=%s\n' \
      "$QA_CASE" "${INITIAL_BINDING:-unknown}" "$(read_binding)"
    [ -r "$GATE_PARAM" ] && printf 'gate=%s\n' "$(tr -d '\r\n' < "$GATE_PARAM")"
    [ -r "$FAULT_PARAM" ] && printf 'fault_mask=%s\n' "$(tr -d '\r\n' < "$FAULT_PARAM")"
    [ -r "$STATS" ] && cat "$STATS"
    for iface in "$FROM_IF" "$TO_IF" "$PEER_IF"; do
      ip -details -s link show "$iface" 2>&1 || true
      iw dev "$iface" link 2>&1 || true
    done
    grep '^moal ' /proc/modules 2>/dev/null || true
    ps -eLo pid,tid,comm,cls,rtprio,stat 2>/dev/null |
      grep -E 'moal_br_(w2p|p2w)' || true
  } > "$QA_EVIDENCE_DIR/state.$label.log" 2>&1
}

admin_up() {
  ip link show dev "$1" 2>/dev/null | grep -Eq '<[^>]*\bUP\b[^>]*>'
}

require_admin_up() {
  admin_up "$1" || fail "$1 must be administratively UP"
}

require_admin_down() {
  admin_up "$1" && fail "$1 must be administratively DOWN"
}

bridge_thread_count() {
  ps -eLo comm= 2>/dev/null | grep -Ec '^moal_br_(w2p|p2w)$' || true
}

binding_ready() {
  local iface="$1" link_state

  admin_up "$iface" || return 1
  link_state="$(iw dev "$iface" link 2>&1)" || return 1
  printf '%s\n' "$link_state" | grep -q '^Connected to '
}

require_unassociated_admin_up() {
  local iface="$1" link_state

  require_admin_up "$iface"
  link_state="$(iw dev "$iface" link 2>&1)" ||
    fail "cannot query $iface association: $link_state"
  printf '%s\n' "$link_state" | grep -q '^Not connected\.' ||
    fail "$iface must be administratively UP and unassociated"
}

write_sysfs_attempt() {
  local payload="$1"

  python3 - "$IFACE_PARAM" "$payload" <<'PYWRITE'
import errno
import os
import sys

path, payload = sys.argv[1], sys.argv[2].encode()
try:
    fd = os.open(path, os.O_WRONLY)
    try:
        os.write(fd, payload)
    finally:
        os.close(fd)
except OSError as exc:
    print(f"write_result=errno errno={exc.errno} name={errno.errorcode.get(exc.errno, 'UNKNOWN')}")
    raise SystemExit(exc.errno or 1)
print("write_result=ok errno=0")
PYWRITE
}

interaction_expected_errno() {
  case "$1" in
    4|16|19|108) return 0 ;; # EINTR, EBUSY, ENODEV, ESHUTDOWN
    *) return 1 ;;
  esac
}

dmesg_stream_alive() {
  [ -n "$DMESG_STREAM_PID" ] && kill -0 "$DMESG_STREAM_PID" 2>/dev/null
}

bridge_binding_healthy() {
  local iface="$1"

  [ -r "$STATS" ] || return 1
  grep -Eq '^active=1 peer_released=0( |$)' "$STATS" || return 1
  binding_ready "$iface" || return 1
  ip link show dev "$PEER_IF" 2>/dev/null | grep -q 'state UP'
}

cleanup() {
  original_status=$?
  trap - EXIT
  set +e
  final_status=$original_status
  cleanup_failed=0

  capture_state "final-before-restore"
  dmesg > "$QA_EVIDENCE_DIR/dmesg.final-before-restore.log" 2>&1 || cleanup_failed=1

  if ! dmesg_stream_alive; then
    printf 'dmesg follower exited before QA cleanup\n' \
      >> "$QA_EVIDENCE_DIR/restore.log"
    cleanup_failed=1
  fi

  # A failed QA run may exit after arming the one-shot hook but before the
  # switch write consumes it.  Disarm before any best-effort binding restore.
  if [ -w "$FAULT_PARAM" ]; then
    printf '0\n' > "$FAULT_PARAM" 2>> "$QA_EVIDENCE_DIR/restore.log" ||
      cleanup_failed=1
  fi

  if [ "$PEER_TOUCHED" -eq 1 ] && [ "$PEER_WAS_UP" -eq 1 ]; then
    ip link set dev "$PEER_IF" up >> "$QA_EVIDENCE_DIR/restore.log" 2>&1 || cleanup_failed=1
  fi
  if [ "$TO_TOUCHED" -eq 1 ]; then
    if [ "$TO_WAS_ADMIN_UP" -eq 1 ]; then
      ip link set dev "$TO_IF" up >> "$QA_EVIDENCE_DIR/restore.log" 2>&1 || cleanup_failed=1
    else
      ip link set dev "$TO_IF" down >> "$QA_EVIDENCE_DIR/restore.log" 2>&1 || cleanup_failed=1
    fi
  fi

  current_binding="$(read_binding)"
  if [ -n "$INITIAL_BINDING" ] && [ "$INITIAL_BINDING" != none ] &&
     [ "$INITIAL_BINDING" != unavailable ] &&
     [ "$current_binding" != none ] && [ "$current_binding" != unavailable ] &&
     [ "$current_binding" != "$INITIAL_BINDING" ] &&
     [ -w "$IFACE_PARAM" ] && bridge_binding_healthy "$current_binding" &&
     binding_ready "$INITIAL_BINDING"; then
    printf '%s\n' "$INITIAL_BINDING" > "$IFACE_PARAM" 2>> "$QA_EVIDENCE_DIR/restore.log" ||
      cleanup_failed=1
  fi

  capture_state "final-after-restore"
  dmesg > "$QA_EVIDENCE_DIR/dmesg.final-after-restore.log" 2>&1 || cleanup_failed=1

  if [ -n "$DMESG_STREAM_PID" ]; then
    kill "$DMESG_STREAM_PID" 2>/dev/null || true
    wait "$DMESG_STREAM_PID" 2>/dev/null || true
  fi
  # Scan only the follow-new stream.  The full before/after snapshots are
  # retained as operator evidence, but may contain unrelated historical boot
  # warnings and therefore are not a valid pass/fail delta.
  if [ -f "$DMESG_STREAM" ] &&
       grep -Ei 'BUG:|WARNING:|use-after-free|KASAN:|lockdep|Oops:|panic|general protection|UBSAN:|KFENCE:|refcount|hung task' \
		     "$DMESG_STREAM" \
	       > "$QA_EVIDENCE_DIR/kernel-warning.matches"; then
    printf 'FAIL: kernel warning detected in follow-new kernel log\n' >&2
    cleanup_failed=1
  fi
  if [ "$final_status" -eq 0 ] && [ "$cleanup_failed" -ne 0 ]; then
	printf 'FAIL: QA cleanup/evidence/restore failed\n' >&2
    final_status=1
  fi
  if [ "$final_status" -eq 0 ]; then
    printf 'PASS: QA_CASE=%s\n' "$QA_CASE"
  fi
  printf 'QA evidence: %s\n' "$QA_EVIDENCE_DIR"
  exit "$final_status"
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

  link_state="$(iw dev "$iface" link 2>&1)" ||
    fail "cannot query $iface association: $link_state"
  printf '%s\n' "$link_state" | grep -q '^Connected to ' ||
    fail "$iface is not associated; operator must prepare it"
}

require_gate() {
  local expected="$1" actual

  actual="$(tr -d '\r\n' < "$GATE_PARAM")"
  [ "$actual" = "$expected" ] || fail "gate=$actual, expected $expected"
}

write_expect_errno() {
  local payload="$1" expected="$2"

  python3 - "$IFACE_PARAM" "$payload" "$expected" <<'PY'
import errno
import os
import sys

path, payload, expected = sys.argv[1], sys.argv[2].encode(), int(sys.argv[3])
fd = os.open(path, os.O_WRONLY)
try:
    try:
        os.write(fd, payload)
    except OSError as exc:
        if exc.errno != expected:
            raise SystemExit(
                f"write errno mismatch: expected={expected}({errno.errorcode.get(expected)}) "
                f"actual={exc.errno}({errno.errorcode.get(exc.errno)})")
    else:
        raise SystemExit(f"write unexpectedly succeeded; expected errno {expected}")
finally:
    os.close(fd)
PY
}

switch_iface() {
  local target="$1" effective

  printf '%s\n' "$target" > "$IFACE_PARAM" || fail "switch to $target failed"
  effective="$(read_binding)"
  [ "$effective" = "$target" ] ||
    fail "switch mismatch: target=$target effective=$effective"
}

validate_loop_count() {
  case "$SWITCH_LOOPS" in
    ''|0|0*|*[!0-9]*)
      fail "SWITCH_LOOPS must be canonical decimal 1..$MAX_SWITCH_LOOPS"
      ;;
  esac
  [ "${#SWITCH_LOOPS}" -le 6 ] || fail "SWITCH_LOOPS too large"
  SWITCH_LOOPS=$((10#$SWITCH_LOOPS))
  [ "$SWITCH_LOOPS" -le "$MAX_SWITCH_LOOPS" ] || fail "SWITCH_LOOPS too large"
}

snapshot_outcomes() {
  SWITCH_OK_BEFORE="$(stats_counter switch_ok)" || fail "switch_ok missing"
  SWITCH_FAIL_BEFORE="$(stats_counter switch_fail)" || fail "switch_fail missing"
  ROLLBACK_OK_BEFORE="$(stats_counter rollback_ok)" || fail "rollback_ok missing"
  ROLLBACK_FAIL_BEFORE="$(stats_counter rollback_fail)" || fail "rollback_fail missing"
}

assert_no_failure_outcome() {
  [ "$(stats_counter switch_fail)" -eq "$SWITCH_FAIL_BEFORE" ] || fail "switch_fail increased"
  [ "$(stats_counter rollback_ok)" -eq "$ROLLBACK_OK_BEFORE" ] || fail "rollback_ok increased"
  [ "$(stats_counter rollback_fail)" -eq "$ROLLBACK_FAIL_BEFORE" ] || fail "rollback_fail increased"
}

assert_all_outcomes_unchanged() {
  [ "$(stats_counter switch_ok)" -eq "$SWITCH_OK_BEFORE" ] || fail "switch_ok changed"
  assert_no_failure_outcome
}

run_prevalidation_reject() {
  local payload="$1" expected="$2" binding_before active_before

  binding_before="$(read_binding)"
  active_before="$(grep -Eo 'active=[01]' "$STATS" | head -1 || true)"
  snapshot_outcomes
  write_expect_errno "$payload" "$expected"
  [ "$(read_binding)" = "$binding_before" ] || fail "rejection changed binding"
  [ "$(grep -Eo 'active=[01]' "$STATS" | head -1 || true)" = "$active_before" ] ||
    fail "rejection changed active state"
  assert_all_outcomes_unchanged
}

wait_for_active() {
  local wanted="$1" attempt

  for ((attempt = 0; attempt < 100; attempt++)); do
    grep -q "active=$wanted" "$STATS" && return 0
    sleep 0.1
  done
  return 1
}

run_stress() {
  local iteration expected actual

  require_gate 1
  validate_loop_count
  require_associated "$FROM_IF"
  require_associated "$TO_IF"
  [ "$(read_binding)" = "$FROM_IF" ] || fail "initial binding must be $FROM_IF"
  snapshot_outcomes
  for ((iteration = 0; iteration < SWITCH_LOOPS; iteration++)); do
    switch_iface "$TO_IF"
    switch_iface "$FROM_IF"
  done
  expected=$((2 * SWITCH_LOOPS))
  actual=$(($(stats_counter switch_ok) - SWITCH_OK_BEFORE))
  [ "$actual" -eq "$expected" ] || fail "switch_ok delta: expected=$expected actual=$actual"
  assert_no_failure_outcome
}

run_same_target() {
  require_gate 1
  grep -q 'active=1' "$STATS" || fail "same-target requires an active bridge"
  snapshot_outcomes
  switch_iface "$(read_binding)"
  grep -q 'active=1' "$STATS" || fail "same-target changed active state"
  assert_all_outcomes_unchanged
}

run_concurrent() {
  local writer_a writer_b effective switch_delta
  local barrier="$QA_EVIDENCE_DIR/concurrent-release"
  local ready_a="$QA_EVIDENCE_DIR/concurrent-a.ready"
  local ready_b="$QA_EVIDENCE_DIR/concurrent-b.ready"
  local started_a="$QA_EVIDENCE_DIR/concurrent-a.started"
  local started_b="$QA_EVIDENCE_DIR/concurrent-b.started"
  local complete_a="$QA_EVIDENCE_DIR/concurrent-a.complete"
  local complete_b="$QA_EVIDENCE_DIR/concurrent-b.complete"
  local iteration

  require_gate 1
  validate_loop_count
  require_associated "$FROM_IF"
  require_associated "$TO_IF"
  snapshot_outcomes
  rm -f -- "$barrier" "$ready_a" "$ready_b" "$started_a" "$started_b" \
    "$complete_a" "$complete_b"

  concurrent_writer() {
    local name="$1" first="$2" second="$3" ready="$4" started="$5" complete="$6"
    local i
    : > "$ready"
    while [ ! -e "$barrier" ]; do sleep 0.001; done
    : > "$started"
    while [ ! -e "$started_a" ] || [ ! -e "$started_b" ]; do sleep 0.001; done
    # Both writers crossed the same release barrier before either syscall loop.
    for ((i = 0; i < SWITCH_LOOPS; i++)); do
      write_sysfs_attempt "$first" || exit $?
      write_sysfs_attempt "$second" || exit $?
    done
    : > "$complete"
    printf 'writer=%s iterations=%s writes=%s\n' "$name" "$SWITCH_LOOPS" "$((2 * SWITCH_LOOPS))"
  }

  concurrent_writer a "$TO_IF" "$FROM_IF" "$ready_a" "$started_a" "$complete_a" \
    > "$QA_EVIDENCE_DIR/writer-a.log" 2>&1 &
  writer_a=$!
  concurrent_writer b "$FROM_IF" "$TO_IF" "$ready_b" "$started_b" "$complete_b" \
    > "$QA_EVIDENCE_DIR/writer-b.log" 2>&1 &
  writer_b=$!

  for ((iteration = 0; iteration < 500; iteration++)); do
    [ -e "$ready_a" ] && [ -e "$ready_b" ] && break
    kill -0 "$writer_a" 2>/dev/null && kill -0 "$writer_b" 2>/dev/null || break
    sleep 0.01
  done
  [ -e "$ready_a" ] && [ -e "$ready_b" ] || fail "concurrent writers did not both reach start barrier"
  kill -0 "$writer_a" 2>/dev/null || fail "writer A died before concurrent release"
  kill -0 "$writer_b" 2>/dev/null || fail "writer B died before concurrent release"
  : > "$barrier"
  for ((iteration = 0; iteration < 500; iteration++)); do
    [ -e "$started_a" ] && [ -e "$started_b" ] && break
    kill -0 "$writer_a" 2>/dev/null && kill -0 "$writer_b" 2>/dev/null || break
    sleep 0.01
  done
  [ -e "$started_a" ] && [ -e "$started_b" ] || fail "concurrent writers did not both enter syscall loop"
  kill -0 "$writer_a" 2>/dev/null || fail "writer A was not live at concurrent-loop evidence point"
  kill -0 "$writer_b" 2>/dev/null || fail "writer B was not live at concurrent-loop evidence point"

  wait "$writer_a" || fail "concurrent writer A failed"
  wait "$writer_b" || fail "concurrent writer B failed"
  [ -e "$complete_a" ] && [ -e "$complete_b" ] || fail "concurrent writer completion evidence missing"
  effective="$(read_binding)"
  [ "$effective" = "$FROM_IF" ] || [ "$effective" = "$TO_IF" ] ||
    fail "invalid concurrent terminal binding: $effective"
  switch_delta=$(( $(stats_counter switch_ok) - SWITCH_OK_BEFORE ))
  [ "$switch_delta" -gt 0 ] || fail "concurrent writers completed no real switch"
  assert_no_failure_outcome
  printf 'barrier=passed both_writers_live=1 terminal_binding=%s switch_ok_delta=%s\n' \
    "$effective" "$switch_delta" > "$QA_EVIDENCE_DIR/concurrent-summary.log"
  # This demonstrates coordinated user-space attempts and liveness, not kernel
  # scheduler overlap; syscall overlap remains a target/kernel-trace assertion.
}

run_peer_cycle() {
  local original

  require_gate 1
  require_associated "$FROM_IF"
  require_associated "$TO_IF"
  original="$(read_binding)"
  [ "$original" = "$FROM_IF" ] || fail "peer-cycle must start bound to $FROM_IF"
  bridge_binding_healthy "$original" || fail "peer-cycle requires a healthy current bridge"
  snapshot_outcomes
  PEER_TOUCHED=1
  ip link show dev "$PEER_IF" | grep -q 'state UP' && PEER_WAS_UP=1
  [ "$PEER_WAS_UP" -eq 1 ] || fail "$PEER_IF must initially be up"
  ip link set dev "$PEER_IF" down
  wait_for_active 0 || fail "bridge did not suspend after peer down"
  write_expect_errno "$original" 100
  write_expect_errno "$TO_IF" 100
  [ "$(read_binding)" = "$original" ] || fail "peer-down rejection changed binding"
  assert_all_outcomes_unchanged
  ip link set dev "$PEER_IF" up
  wait_for_active 1 || fail "bridge did not resume after peer up"
  [ "$(stats_counter switch_ok)" -eq "$SWITCH_OK_BEFORE" ] ||
    fail "peer cycle changed switch_ok"
  assert_no_failure_outcome
  PEER_TOUCHED=0
}

run_fault_target() {
  local switch_ok_after_failure

  require_gate 1
  [ -w "$FAULT_PARAM" ] || fail "QA-only fault build/parameter is unavailable"
  require_associated "$FROM_IF"
  require_associated "$TO_IF"
  [ "$(read_binding)" = "$FROM_IF" ] || fail "fault-target must start bound to $FROM_IF"
  bridge_binding_healthy "$FROM_IF" || fail "fault-target requires a healthy current bridge"
  snapshot_outcomes
  printf '1\n' > "$FAULT_PARAM"
  write_expect_errno "$TO_IF" 12
  [ "$(read_binding)" = "$FROM_IF" ] || fail "rollback did not restore $FROM_IF"
  [ "$(stats_counter switch_ok)" -eq "$SWITCH_OK_BEFORE" ] || fail "switch_ok changed on injected failure"
  [ "$(stats_counter switch_fail)" -eq $((SWITCH_FAIL_BEFORE + 1)) ] || fail "switch_fail delta"
  [ "$(stats_counter rollback_ok)" -eq $((ROLLBACK_OK_BEFORE + 1)) ] || fail "rollback_ok delta"
  [ "$(stats_counter rollback_fail)" -eq "$ROLLBACK_FAIL_BEFORE" ] || fail "rollback_fail changed"
  [ "$(tr -d '\r\n' < "$FAULT_PARAM")" = 0 ] || fail "fault mask was not consumed"
  bridge_binding_healthy "$FROM_IF" || fail "rollback restored an unhealthy bridge"
  [ "$(ps -eLo comm= | grep -Ec '^moal_br_(w2p|p2w)$' || true)" -eq 2 ] ||
    fail "rollback left missing or duplicate bridge threads"
  switch_ok_after_failure="$(stats_counter switch_ok)"
  [ "$switch_ok_after_failure" -eq "$SWITCH_OK_BEFORE" ] ||
    fail "injected target failure changed switch_ok before recovery"
  switch_iface "$TO_IF"
  switch_iface "$FROM_IF"
  [ "$(stats_counter switch_ok)" -eq $((SWITCH_OK_BEFORE + 2)) ] ||
    fail "normal recovery did not complete exactly two switches"
  [ "$(stats_counter switch_fail)" -eq $((SWITCH_FAIL_BEFORE + 1)) ] || fail "recovery changed switch_fail"
  [ "$(stats_counter rollback_ok)" -eq $((ROLLBACK_OK_BEFORE + 1)) ] || fail "recovery changed rollback_ok"
  [ "$(stats_counter rollback_fail)" -eq "$ROLLBACK_FAIL_BEFORE" ] || fail "recovery changed rollback_fail"
}

run_fault_double() {
  require_gate 1
  [ -w "$FAULT_PARAM" ] || fail "QA-only fault build/parameter is unavailable"
  require_associated "$FROM_IF"
  require_associated "$TO_IF"
  [ "$(read_binding)" = "$FROM_IF" ] || fail "fault-double must start bound to $FROM_IF"
  bridge_binding_healthy "$FROM_IF" || fail "fault-double requires a healthy current bridge"
  snapshot_outcomes
  printf '3\n' > "$FAULT_PARAM"
  write_expect_errno "$TO_IF" 5
  [ "$(read_binding)" = none ] || fail "double failure must leave no effective owner"
  [ "$(stats_counter switch_ok)" -eq "$SWITCH_OK_BEFORE" ] || fail "switch_ok changed"
  [ "$(stats_counter switch_fail)" -eq $((SWITCH_FAIL_BEFORE + 1)) ] || fail "switch_fail delta"
  [ "$(stats_counter rollback_ok)" -eq "$ROLLBACK_OK_BEFORE" ] || fail "rollback_ok changed"
  [ "$(stats_counter rollback_fail)" -eq $((ROLLBACK_FAIL_BEFORE + 1)) ] || fail "rollback_fail delta"
  [ "$(tr -d '\r\n' < "$FAULT_PARAM")" = 0 ] || fail "fault mask was not consumed"
  grep -q '^bridge: inactive$' "$STATS" || fail "double failure stats are not inactive"
  [ "$(ps -eLo comm= | grep -Ec '^moal_br_(w2p|p2w)$' || true)" -eq 0 ] ||
    fail "double failure left bridge threads"
}

run_interaction() {
  local command_var="$1" command_value writer_pid writer_rc command_rc iteration
  local marker="$QA_EVIDENCE_DIR/interaction-writer-started"
  local attempt="$QA_EVIDENCE_DIR/interaction-syscall-attempt"
  local command_started="$QA_EVIDENCE_DIR/interaction-command-started"
  local command_done="$QA_EVIDENCE_DIR/interaction-command-done"

  require_gate 1
  validate_loop_count
  require_associated "$FROM_IF"
  require_associated "$TO_IF"
  [ "$(read_binding)" = "$FROM_IF" ] || fail "interaction must start bound to $FROM_IF"
  bridge_binding_healthy "$FROM_IF" || fail "interaction requires a healthy exact old binding"
  command_value="${!command_var:-}"
  [ -n "$command_value" ] || fail "$command_var must contain the board-approved command"
  rm -f -- "$marker" "$attempt" "$command_started" "$command_done"
  (
    local rc=0
    for ((iteration = 0; iteration < SWITCH_LOOPS; iteration++)); do
      [ "$iteration" -eq 0 ] && : > "$marker"
      # This marker is emitted immediately before write(2), then the destructive
      # command is launched while the writer is verified live. It is the closest
      # shell-level boundary; kernel tracing is required to prove in-kernel overlap.
      [ "$iteration" -eq 0 ] && : > "$attempt"
      write_sysfs_attempt "$TO_IF" || rc=$?
      if [ "$rc" -ne 0 ]; then
        printf 'writer_errno=%s phase=to iteration=%s\n' "$rc" "$iteration"
        [ -e "$command_started" ] && interaction_expected_errno "$rc" && exit 75
        exit "$rc"
      fi
      write_sysfs_attempt "$FROM_IF" || rc=$?
      if [ "$rc" -ne 0 ]; then
        printf 'writer_errno=%s phase=from iteration=%s\n' "$rc" "$iteration"
        [ -e "$command_started" ] && interaction_expected_errno "$rc" && exit 75
        exit "$rc"
      fi
      [ -e "$command_done" ] && exit 0
    done
    [ -e "$command_done" ] && exit 0
    exit 70
  ) > "$QA_EVIDENCE_DIR/interaction-writer.log" 2>&1 &
  writer_pid=$!

  for ((iteration = 0; iteration < 500; iteration++)); do
    [ -e "$marker" ] && break
    kill -0 "$writer_pid" 2>/dev/null || break
    sleep 0.01
  done
  [ -e "$marker" ] || fail "interaction writer did not start"
  for ((iteration = 0; iteration < 500; iteration++)); do
    [ -e "$attempt" ] && break
    kill -0 "$writer_pid" 2>/dev/null || break
    sleep 0.001
  done
  [ -e "$attempt" ] || fail "interaction writer did not reach syscall-attempt boundary"
  kill -0 "$writer_pid" 2>/dev/null || fail "interaction writer is not live immediately before destructive command"
  : > "$command_started"

  set +e
  timeout "$INTERACTION_TIMEOUT" bash -c "$command_value"     > "$QA_EVIDENCE_DIR/interaction-command.log" 2>&1
  command_rc=$?
  : > "$command_done"
  timeout "$INTERACTION_TIMEOUT" bash -c     'while kill -0 "$1" 2>/dev/null; do sleep 0.1; done' _ "$writer_pid"
  writer_rc=$?
  if [ "$writer_rc" -eq 0 ]; then
    wait "$writer_pid"; writer_rc=$?
  else
    kill "$writer_pid" 2>/dev/null || true
    wait "$writer_pid" 2>/dev/null || true
  fi
  set -e
  printf 'command_rc=%d writer_rc=%d command_timeout=%s writer_timeout=%s syscall_overlap=target-manual\n'     "$command_rc" "$writer_rc" "$([ "$command_rc" -eq 124 ] && echo yes || echo no)"     "$([ "$writer_rc" -eq 124 ] && echo yes || echo no)" > "$QA_EVIDENCE_DIR/interaction-status.log"
  [ "$command_rc" -ne 124 ] || fail "$command_var timed out"
  [ "$command_rc" -eq 0 ] || fail "$command_var failed (rc=$command_rc)"
  [ "$writer_rc" -ne 124 ] || fail "interaction writer hung after command completion"
  [ "$writer_rc" -ne 70 ] || fail "interaction writer exhausted SWITCH_LOOPS before command completion"
  [ "$writer_rc" -ne 4 ] || fail "interaction writer interrupted by signal (EINTR)"
  if [ "$QA_CASE" = reset-interaction ]; then
    [ "$writer_rc" -eq 0 ] || [ "$writer_rc" -eq 75 ] ||
      fail "reset interaction writer failed unexpectedly (rc=$writer_rc)"
  else
    [ "$writer_rc" -eq 0 ] || [ "$writer_rc" -eq 75 ] ||
      fail "unload interaction writer failed unexpectedly (rc=$writer_rc)"
  fi

  if [ "$QA_CASE" = reset-interaction ]; then
    for ((iteration = 0; iteration < INTERACTION_TIMEOUT * 10; iteration++)); do
      [ -r "$STATS" ] && grep -Eq '^active=1( |$)' "$STATS" && break
      sleep 0.1
    done
    [ -r "$STATS" ] || fail "reset removed module stats unexpectedly"
    [ "$(read_binding)" = "$FROM_IF" ] || fail "reset did not restore exact suspended owner $FROM_IF"
    grep -Eq '^active=1( |$)' "$STATS" || fail "reset left bridge inactive"
    [ "$(bridge_thread_count)" -eq 2 ] || fail "reset left missing or duplicate bridge threads"
    grep -q '^moal ' /proc/modules || fail "reset unexpectedly removed moal module"
    printf 'terminal_owner=%s active=1 bridge_threads=2 module=loaded status_phase=target-manual\n'       "$FROM_IF" > "$QA_EVIDENCE_DIR/reset-terminal.log"
  else
    [ ! -e "$IFACE_PARAM" ] || fail "unload left bridge_iface published"
    [ ! -e "$STATS" ] || fail "unload left bridge stats published"
    ! grep -q '^moal ' /proc/modules || fail "unload left moal module loaded"
    [ "$(bridge_thread_count)" -eq 0 ] || fail "unload left bridge threads"
    printf 'terminal_owner=absent bridge_threads=0 module=unloaded status_phase=target-manual\n'       > "$QA_EVIDENCE_DIR/unload-terminal.log"
  fi
}

[ "$(id -u)" -eq 0 ] || fail "run as root"
for command_name in awk dmesg grep ip iw python3 ps timeout tr; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name command missing"
done
mkdir -p -- "$QA_EVIDENCE_DIR" || fail "cannot create $QA_EVIDENCE_DIR"
trap cleanup EXIT

if command -v stdbuf >/dev/null 2>&1; then
  stdbuf -oL -eL dmesg --follow-new > "$DMESG_STREAM" 2>&1 &
else
  dmesg --follow-new > "$DMESG_STREAM" 2>&1 &
fi
DMESG_STREAM_PID=$!
sleep 0.2
kill -0 "$DMESG_STREAM_PID" 2>/dev/null || fail "dmesg --follow-new is unavailable"

[ -r "$GATE_PARAM" ] || fail "missing $GATE_PARAM"
[ -r "$STATS" ] || fail "missing $STATS"
INITIAL_BINDING="$(read_binding)"
capture_state before

case "$QA_CASE" in
  stress) run_stress ;;
  same-target) run_same_target ;;
  concurrent) run_concurrent ;;
  peer-cycle) run_peer_cycle ;;
  gate-off)
    require_gate 0
    run_prevalidation_reject "$TO_IF" 95
    ;;
  no-active)
    require_gate 1
    [ "$(read_binding)" = none ] || fail "bridge must be inactive"
    run_prevalidation_reject "$TO_IF" 19
    ;;
  malformed)
    require_gate 1
    run_prevalidation_reject $'bad name\n' 22
    run_prevalidation_reject $'bad/name\n' 22
    run_prevalidation_reject 'interface-name-that-is-too-long' 22
    ;;
  reject)
    require_gate 1
    run_prevalidation_reject "$REJECT_TARGET" "$EXPECTED_ERRNO"
    ;;
  target-down)
    require_gate 1
    [ "$(read_binding)" = "$FROM_IF" ] || fail "target-down must start bound to $FROM_IF"
    bridge_binding_healthy "$FROM_IF" || fail "target-down requires a healthy current bridge"
    ip link show dev "$TO_IF" >/dev/null 2>&1 || fail "target-down target is missing"
    admin_up "$TO_IF" && TO_WAS_ADMIN_UP=1
    TO_TOUCHED=1
    ip link set dev "$TO_IF" down
    require_admin_down "$TO_IF"
    capture_state target-down-admin-down
    run_prevalidation_reject "$TO_IF" 100
    ;;
  target-disconnected)
    require_gate 1
    [ "$(read_binding)" = "$FROM_IF" ] || fail "target-disconnected must start bound to $FROM_IF"
    bridge_binding_healthy "$FROM_IF" || fail "target-disconnected requires a healthy current bridge"
    ip link show dev "$TO_IF" >/dev/null 2>&1 || fail "target-disconnected target is missing"
    admin_up "$TO_IF" && TO_WAS_ADMIN_UP=1
    TO_TOUCHED=1
    ip link set dev "$TO_IF" up
    require_unassociated_admin_up "$TO_IF"
    capture_state target-disconnected-admin-up-unassociated
    run_prevalidation_reject "$TO_IF" 67
    ;;
  fault-target) run_fault_target ;;
  fault-double) run_fault_double ;;
  reset-interaction) run_interaction RESET_CMD ;;
  unload-interaction) run_interaction UNLOAD_CMD ;;
  *) fail "unknown QA_CASE=$QA_CASE" ;;
esac

capture_state after-case
dmesg_stream_alive || fail "dmesg follower exited during QA case"
