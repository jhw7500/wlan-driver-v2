#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
BRIDGE_C="$ROOT/mlinux/moal_bridge.c"
INIT_C="$ROOT/mlinux/moal_init.c"
MAIN_H="$ROOT/mlinux/moal_main.h"
MAIN_C="$ROOT/mlinux/moal_main.c"
PCIE_C="$ROOT/mlinux/moal_pcie.c"
SDIO_C="$ROOT/mlinux/moal_sdio_mmc.c"
SHIM_C="$ROOT/mlinux/moal_shim.c"
QA_SCRIPT="$ROOT/scripts/tests/bridge_runtime_switch_qa.sh"
PARAM_DOC="$ROOT/docs/MOAL-Module-Parameters.md"
QA_RUNBOOK="$ROOT/docs/driver-bridge.qa-runbook.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

extract_c_function() {
  extract_c_block "$(cat "$2")" "$1"
}

extract_switch_block() {
  extract_c_function '^int moal_bridge_switch_iface' "$1"
}

# Extract the matching braced region for a start regex. Scan braces in source
# order so a line such as "} else {" closes the first branch before opening
# the next; unlike a sed range, nested blocks do not truncate the result.
extract_c_block() {
  START_PATTERN="$2" awk '
    BEGIN { start=ENVIRON["START_PATTERN"] }
    !in_block && $0 ~ start { in_block=1 }
    in_block {
      print
      scan=$0
      if (!saw_open) {
        open_at=index(scan, "{")
        if (!open_at)
          next
        scan=substr(scan, open_at)
      }
      for (i=1; i <= length(scan); i++) {
        token=substr(scan, i, 1)
        if (token == "{") {
          depth++
          saw_open=1
        } else if (token == "}" && saw_open) {
          depth--
          if (depth == 0)
            exit
        }
      }
    }
    END { exit !(in_block && saw_open && depth == 0) }
  ' <<< "$1"
}

# Return exactly the statement controlled by a guard, accepting both the
# repository's current unbraced style and a semantics-equivalent braced form.
extract_guarded_control() {
  local guard_line

  guard_line="$(grep -Em1 "$2" <<< "$1")" || return 1
  if [[ "$guard_line" == *"{"* ]]; then
    extract_c_block "$1" "$2"
    return
  fi

  START_PATTERN="$2" awk '
    BEGIN { start=ENVIRON["START_PATTERN"] }
    !found && $0 ~ start {
      found=1
      print
      next
    }
    found {
      print
      if (/;/) {
        saw_statement=1
        exit
      }
    }
    END { exit !(found && saw_statement) }
  ' <<< "$1"
}

check_no_direct_return_while_locked() {
  printf '%s\n' "$1" | awk '
    /mutex_lock\(&bridge_lifecycle_lock\)/ { acquired=1; next }
    /mutex_unlock\(&bridge_lifecycle_lock\)/ { acquired=0 }
    acquired && /^[[:space:]]*return[[:space:]]/ { bad=1 }
    END { exit bad }
  '
}

check_switch_success_contract() {
  local success_block guarded_control old_mode_clear_count

  success_block="$(extract_c_block "$1" \
    '^[[:space:]]*if \(!ret\) \{')" || return 1
  guarded_control="$(extract_guarded_control "$success_block" \
    '^[[:space:]]*if \(old\.old_owner != target\.handle\)')" || return 1
  printf '%s\n' "$guarded_control" | \
    grep -Fq 'old.old_owner->params.bridge_mode = 0' || return 1
  if printf '%s\n' "$guarded_control" | \
      grep -Fq 'target.handle->params.bridge_mode = 1'; then
    return 1
  fi
  old_mode_clear_count="$(printf '%s\n' "$success_block" | \
    grep -Fc 'old.old_owner->params.bridge_mode = 0' || true)"
  [ "$old_mode_clear_count" -eq 1 ] || return 1
  printf '%s\n' "$success_block" | \
    grep -Fq 'target.handle->params.bridge_mode = 1' || return 1
  printf '%s\n' "$success_block" | \
    grep -Fq 'bridge_owner = target.handle' || return 1
  printf '%s\n' "$success_block" | \
    grep -Fq 'atomic_long_inc(&bridge_switch_ok)' || return 1
}

check_bridge_iface_set_contract() {
  local setter="$1" gate_control null_control bound_control edge_control
  local name_control

  gate_control="$(extract_guarded_control "$setter" \
    '^[[:space:]]*if \(!READ_ONCE\(bridge_runtime_switch\)\)')" || return 1
  printf '%s\n' "$gate_control" | grep -Fq 'return -EOPNOTSUPP' || return 1
  null_control="$(extract_guarded_control "$setter" \
    '^[[:space:]]*if \(!val\)')" || return 1
  printf '%s\n' "$null_control" | grep -Fq 'return -EINVAL' || return 1
  printf '%s\n' "$setter" | \
    grep -Fq "val[len] != '\\r' && val[len] != '\\n'" || return 1
  bound_control="$(extract_guarded_control "$setter" \
    '^[[:space:]]*if \(len >= sizeof\(ifname\) - 1\)')" || return 1
  printf '%s\n' "$bound_control" | grep -Fq 'return -EINVAL' || return 1
  printf '%s\n' "$setter" | \
    grep -Fq "while (val[end] == '\\r' || val[end] == '\\n')" || return 1
  edge_control="$(extract_guarded_control "$setter" \
    '^[[:space:]]*if \(!len \|\| val\[end\]\)')" || return 1
  printf '%s\n' "$edge_control" | grep -Fq 'return -EINVAL' || return 1
  name_control="$(extract_guarded_control "$setter" \
    '^[[:space:]]*if \(!dev_valid_name\(ifname\)\)')" || return 1
  printf '%s\n' "$name_control" | grep -Fq 'return -EINVAL' || return 1
  printf '%s\n' "$setter" | \
    grep -Fq 'return moal_bridge_switch_iface(ifname);' || return 1
  printf '%s\n' "$setter" | awk '
    /if \(!READ_ONCE\(bridge_runtime_switch\)\)/ { gate=NR }
    /if \(!val\)/ { null_check=NR }
    /while \(val\[len\]/ { scan=NR }
    /if \(len >= sizeof\(ifname\) - 1\)/ { bound=NR }
    /end = len/ { end_snapshot=NR }
    /while \(val\[end\]/ { newline_trim=NR }
    /if \(!len \|\| val\[end\]\)/ { edge_reject=NR }
    /memcpy\(ifname, val, len\)/ { copy=NR }
    /if \(!dev_valid_name\(ifname\)\)/ { name_check=NR }
    /return moal_bridge_switch_iface\(ifname\)/ { switch_call=NR }
    END { exit !(gate && null_check && scan && bound && end_snapshot &&
                 newline_trim && edge_reject && copy && name_check && switch_call &&
                 gate < null_check && null_check < scan && scan <= bound &&
                 bound < end_snapshot && end_snapshot < newline_trim &&
                 newline_trim < edge_reject && edge_reject < copy &&
                 copy < name_check && name_check < switch_call) }
  '
}

check_stats_rcu_lifetime_contract() {
  local stats="$1" sysfs_deinit="$2" lifecycle_deinit="$3" remove_card="$4"

  printf '%s\n' "$stats" | awk '
    /rcu_read_lock\(\)/ { lock=NR }
    /rcu_dereference\(moal_bridge_for_sysfs\)/ { deref=NR }
    /handle = .*br->handle/ { handle=NR }
    /ret = scnprintf/ { format=NR }
    /rcu_read_unlock\(\)/ { unlock=NR }
    END { exit !(lock && deref && handle && format && unlock &&
                 lock < deref && deref < handle && handle < format &&
                 format < unlock) }
  ' || return 1
  printf '%s\n' "$stats" | grep -Fq 'return scnprintf' && return 1
  [ "$(printf '%s\n' "$stats" | grep -c 'rcu_read_unlock()' || true)" -eq 1 ] || \
    return 1
  printf '%s\n' "$stats" | awk '
    /rcu_read_lock\(\)/ { acquired=1; next }
    /rcu_read_unlock\(\)/ { acquired=0 }
    acquired && /^[[:space:]]*return[[:space:]]/ { bad=1 }
    /goto out_rcu/ { shared_exit=1 }
    /^out_rcu:/ { label=1 }
    END { exit (bad || !shared_exit || !label || acquired) }
  ' || return 1
  printf '%s\n' "$sysfs_deinit" | awk '
    /rcu_assign_pointer\(moal_bridge_for_sysfs, NULL\)/ { clear=NR }
    /synchronize_rcu\(\)/ { drain=NR }
    /sysfs_remove_file/ { remove=NR }
    END { exit !(clear && drain && remove && clear < drain && drain < remove) }
  ' || return 1
  printf '%s\n' "$lifecycle_deinit" | awk '
    /moal_bridge_sysfs_deinit\(\)/ { drain=NR }
    /kfree\(br\)/ { free=NR }
    END { exit !(drain && free && drain < free) }
  ' || return 1
  printf '%s\n' "$remove_card" | awk '
    /moal_bridge_deinit\(handle\)/ { bridge_deinit=NR }
    /woal_free_moal_handle\(handle\)/ { handle_free=NR }
    END { exit !(bridge_deinit && handle_free && bridge_deinit < handle_free) }
  '
}

check_bridge_name_snapshot_contract() {
  printf '%s\n' "$1" | awk '
    /peer = dev_get_by_name/ { peer_ref=NR }
    /br->peer_dev = peer/ { peer_assign=NR }
    /br->wlan_dev = / { wlan_assign=NR }
    /strncpy\(br->wlan_name, br->wlan_dev->name/ { iface_copy=NR }
    /br->wlan_name\[sizeof\(br->wlan_name\) - 1\] = '\''\\0'\'';/ { iface_nul=NR }
    /strncpy\(br->peer_name, br->peer_dev->name/ { peer_copy=NR }
    /br->peer_name\[sizeof\(br->peer_name\) - 1\] = '\''\\0'\'';/ { peer_nul=NR }
    /register_netdevice_notifier/ { notifier=NR }
    END { exit !(peer_ref && peer_assign && wlan_assign && iface_copy &&
                 iface_nul && peer_copy && peer_nul && notifier &&
                 peer_ref < peer_assign && peer_ref < wlan_assign &&
                 peer_assign < iface_copy && wlan_assign < iface_copy &&
                 iface_copy < iface_nul && iface_nul < peer_copy &&
                 peer_copy < peer_nul && peer_nul < notifier) }
  '
}

check_no_post_release_peer_name_deref() {
  local notifier="$1" lifecycle_deinit="$2"

  printf '%s\n' "$notifier" | awk '
    /dev_put\(br->peer_dev\)/ { released=1; next }
    released && /br->peer_dev->name/ { bad=1 }
    END { exit bad }
  ' || return 1
  ! grep -Fq 'br->peer_dev->name' <<< "$lifecycle_deinit"
}

check_reset_teardown_order() {
  printf '%s\n' "$1" | awk '
    /MOAL_ACQ_SEMAPHORE_BLOCK\(&AddRemoveCardSem\)/ { card_lock=NR }
    /moal_bridge_deinit\(handle\)/ {
      deinit_count++
      if (!first_deinit) first_deinit=NR
      last_deinit=NR
    }
    /woal_remove_interface\(handle,/ && !remove { remove=NR }
    /woal_free_moal_handle\(handle\)/ && !free_handle { free_handle=NR }
    END { exit !(card_lock && first_deinit && remove &&
                 card_lock < first_deinit && first_deinit < remove &&
                 (!free_handle || (deinit_count >= 2 &&
                  remove < last_deinit && last_deinit < free_handle))) }
  '
}

check_post_reset_bridge_contract() {
  local post_reset="$1" rebuild add_loop add_failure mode_block
  local acquire_failure_control acquire_failure_tail

  rebuild="$(extract_c_block "$post_reset" \
    '^[[:space:]]*if \(!handle->wifi_hal_flag\) \{')" || return 1
  add_loop="$(extract_c_block "$rebuild" \
    '^[[:space:]]*for \(intf_num = 0; intf_num < handle->drv_mode.intf_num;')" || \
    return 1
  add_failure="$(extract_c_block "$add_loop" \
    '^[[:space:]]*if \(!woal_add_interface\(handle, handle->priv_num,')" || \
    return 1
  mode_block="$(extract_c_block "$rebuild" \
    '^[[:space:]]*if \(handle->params.bridge_mode\) \{')" || return 1
  acquire_failure_control="$(extract_guarded_control "$rebuild" \
    '^[[:space:]]*if \(MOAL_ACQ_SEMAPHORE_BLOCK\(&AddRemoveCardSem\)\)')" || \
    return 1
  printf '%s\n' "$acquire_failure_control" | \
    grep -Eq '^[[:space:]]*goto card_sem_acquire_failed;' || return 1
  acquire_failure_tail="$(printf '%s\n' "$post_reset" | awk '
    /^card_sem_acquire_failed:/ { in_tail=1 }
    in_tail { print }
    END { exit !in_tail }
  ')" || return 1
  printf '%s\n' "$acquire_failure_tail" | \
    grep -Eq '^out:$' || return 1
  printf '%s\n' "$acquire_failure_tail" | \
    grep -Eq '(^|[^[:alnum:]_])(handle|priv)([^[:alnum:]_]|$)' && return 1
  printf '%s\n' "$acquire_failure_tail" | \
    grep -Fq 'MOAL_REL_SEMAPHORE(&AddRemoveCardSem)' && return 1

  [ "$(printf '%s\n' "$post_reset" | \
    grep -Fc 'MOAL_ACQ_SEMAPHORE_BLOCK(&AddRemoveCardSem)' || true)" -eq 1 ] || \
    return 1
  [ "$(printf '%s\n' "$rebuild" | \
    grep -Fc 'MOAL_ACQ_SEMAPHORE_BLOCK(&AddRemoveCardSem)' || true)" -eq 1 ] || \
    return 1
  [ "$(printf '%s\n' "$post_reset" | \
    grep -Fc 'MOAL_REL_SEMAPHORE(&AddRemoveCardSem)' || true)" -eq 1 ] || \
    return 1
  [ "$(printf '%s\n' "$post_reset" | \
    grep -Fc 'moal_bridge_init(handle,' || true)" -eq 1 ] || return 1
  printf '%s\n' "$post_reset" | \
    grep -Eq '^[[:space:]]*bool card_sem_held = false;' || return 1
  printf '%s\n' "$post_reset" | awk '
    /MOAL_ACQ_SEMAPHORE_BLOCK\(&AddRemoveCardSem\)/ { acquire=NR }
    /card_sem_held = true/ { held=NR }
    /moal_bridge_deinit\(handle\)/ { deinit=NR }
    /woal_remove_interface\(handle,/ && !remove { remove=NR }
    /woal_add_interface\(handle,/ { add=NR }
    /if \(handle->params.bridge_mode\)/ { mode=NR }
    /moal_bridge_init\(handle,/ { init=NR }
    /^done:/ { done=NR }
    /if \(card_sem_held\)/ { release_guard=NR }
    /MOAL_REL_SEMAPHORE\(&AddRemoveCardSem\)/ { release=NR }
    /^card_sem_acquire_failed:/ { acquire_failed=NR }
    /^out:/ { out=NR }
    /^[[:space:]]*return;/ { final_return=NR }
    END { exit !(acquire && held && deinit && remove && add && mode && init &&
                 done && release_guard && release && acquire_failed && out &&
                 final_return &&
                 acquire < held && held < deinit && deinit < remove &&
                 remove < add && add < mode && mode < init && init < done &&
                 done < release_guard && release_guard < release &&
                 release < acquire_failed && acquire_failed < out &&
                 out < final_return) }
  ' || return 1
  printf '%s\n' "$post_reset" | awk '
    /card_sem_held = true/ { held=1; next }
    /^done:/ { done=1 }
    held && !done && /^[[:space:]]*goto[[:space:]]/ &&
      !/^[[:space:]]*goto done;/ { bad=1 }
    held && !done && /^[[:space:]]*return/ { bad=1 }
    /MOAL_REL_SEMAPHORE\(&AddRemoveCardSem\)/ { released=1; next }
    released && /handle->/ { bad=1 }
    END { exit bad }
  ' || return 1
  printf '%s\n' "$add_loop" | grep -Fq 'moal_bridge_init(handle,' && return 1
  printf '%s\n' "$add_failure" | grep -Eq '^[[:space:]]*goto done;' || \
    return 1
  printf '%s\n' "$add_failure" | grep -Fq 'moal_bridge_init(handle,' && return 1
  [ "$(printf '%s\n' "$mode_block" | \
    grep -Fc 'moal_bridge_init(handle,' || true)" -eq 1 ] || return 1
  extract_guarded_control "$post_reset" \
    '^[[:space:]]*if \(card_sem_held\)' | \
    grep -Fq 'MOAL_REL_SEMAPHORE(&AddRemoveCardSem)' || return 1
}

check_sdio_flr_sem_exit_contract() {
  local sdio_flr="$1" null_adapter

  null_adapter="$(extract_c_block "$sdio_flr" \
    '^[[:space:]]*if \(!\(handle->pmlan_adapter\)\) \{')" || return 1
  printf '%s\n' "$null_adapter" | grep -Eq '^[[:space:]]*goto exit;' || \
    return 1
  printf '%s\n' "$null_adapter" | \
    grep -Eq '^[[:space:]]*return[[:space:]]' && return 1
  printf '%s\n' "$sdio_flr" | awk '
    /MOAL_ACQ_SEMAPHORE_BLOCK\(&AddRemoveCardSem\)/ { acquire=NR }
    /if \(!\(handle->pmlan_adapter\)\)/ { null_adapter=NR }
    /^exit:/ { common_exit=NR }
    /MOAL_REL_SEMAPHORE\(&AddRemoveCardSem\)/ && !release { release=NR }
    END { exit !(acquire && null_adapter && common_exit && release &&
                 acquire < null_adapter && null_adapter < common_exit &&
                 common_exit < release) }
  '
}

grep -q 'bridge_keepalive_ms_present' "$MAIN_H" || fail "keepalive presence flag missing from moal_mod_para"
grep -q 'if (params->bridge_keepalive_ms_present)' "$INIT_C" || fail "explicit keepalive override guard missing"
KEEPALIVE_BLOCK="$(grep -n -A80 -m1 'static enum hrtimer_restart moal_bridge_keepalive' "$BRIDGE_C")"

printf '%s\n' "$KEEPALIVE_BLOCK" | \
  grep -Eq '=\s*handle->params\.bridge_keepalive_ms\b' || \
  fail "timer callback is not reading handle->params.bridge_keepalive_ms"

printf '%s\n' "$KEEPALIVE_BLOCK" | \
  grep -Eq '(^|[^[:alnum:]_>.-])bridge_keepalive_ms([^[:alnum:]_]|$)' && \
  fail "timer callback reads global bridge_keepalive_ms"

grep -q 'MOAL_BR_W2P_QUEUE_MAX' "$ROOT/mlinux/moal_bridge.h" || fail "w2p queue max missing"
grep -q 'MOAL_BR_P2W_QUEUE_MAX' "$ROOT/mlinux/moal_bridge.h" || fail "p2w queue max missing"

# -A170: peer_ipv4 가드 확장(2026-06-10)으로 rx_fast 본문이 길어짐 (bridge_debug 블록 +137줄)
W2P_FAST_BLOCK="$(grep -n -A170 -m1 '^int moal_bridge_rx_fast' "$BRIDGE_C")"
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -q 'atomic_inc_return(&br->w2p_qlen)' || \
  fail "w2p queue length guard missing (rx_fast)"
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -q 'MOAL_BR_W2P_QUEUE_MAX' || \
  fail "w2p queue max not used in guard (rx_fast)"
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -q 'moal_bridge_arp_is_for_self(br, skb, l3_off)' || \
  fail "w2p fast path missing ARP self skip"
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -q 'l3_off = VLAN_ETH_HLEN' || \
  fail "w2p fast path missing VLAN-aware L3 offset"
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -Eq 'iph = \(struct iphdr \*\)\(skb->data \+ l3_off\);|iph = \(struct iphdr \*\)\(skb->data \+ l3_off\)' || \
  fail "w2p fast path still uses fixed L3 offset"

# 창 크기: local hairpin(SELF-ARP REPLY inject) 분기 추가로 함수가 길어져
# 200 → 260 확장 (docstring 773 → clone path 978 = 205줄, 여유 포함)
P2W_RX_HANDLER_BLOCK="$(grep -n -A260 -m1 'moal_bridge_peer_rx_handler' "$BRIDGE_C")"
printf '%s\n' "$P2W_RX_HANDLER_BLOCK" | \
  grep -Eq 'struct sk_buff \*skb2\s*=\s*skb_clone\b' || \
  fail "p2w rx_handler clone path missing"
printf '%s\n' "$P2W_RX_HANDLER_BLOCK" | \
  grep -q 'atomic_inc_return(&br->p2w_qlen)' || \
  fail "p2w queue length guard missing (rx_handler)"
printf '%s\n' "$P2W_RX_HANDLER_BLOCK" | \
  grep -q 'MOAL_BR_P2W_QUEUE_MAX' || \
  fail "p2w queue max not used in guard (rx_handler)"
printf '%s\n' "$P2W_RX_HANDLER_BLOCK" | \
  grep -Eq 'dev_kfree_skb_any\(skb2\)' || \
  fail "p2w rx_handler overflow drop missing"
printf '%s\n' "$P2W_RX_HANDLER_BLOCK" | \
  grep -Eq 'return\s+RX_HANDLER_PASS\s*;' || \
  fail "p2w rx_handler overflow return missing"

# 창 크기: hairpin pt inject 분기(+20줄) 여유 포함 160 → 220
P2W_PACKET_TYPE_BLOCK="$(grep -n -A220 -m1 'moal_bridge_peer_pt_func' "$BRIDGE_C")"
printf '%s\n' "$P2W_PACKET_TYPE_BLOCK" | \
  grep -q 'atomic_inc_return(&br->p2w_qlen)' || \
  fail "p2w queue length guard missing (packet_type)"
printf '%s\n' "$P2W_PACKET_TYPE_BLOCK" | \
  grep -q 'MOAL_BR_P2W_QUEUE_MAX' || \
  fail "p2w queue max not used in guard (packet_type)"
printf '%s\n' "$P2W_PACKET_TYPE_BLOCK" | \
  grep -Eq 'dev_kfree_skb_any\(skb\)' || \
  fail "p2w packet_type overflow drop missing"
printf '%s\n' "$P2W_PACKET_TYPE_BLOCK" | \
  grep -Eq 'return\s+0\s*;' || \
  fail "p2w packet_type overflow return missing"

grep -q 'net_xmit_eval(err)' "$BRIDGE_C" || fail "net_xmit_eval usage missing"
grep -Eq 'atomic_long_add\([^,]+,\s*&br->wlan_to_peer\.fwd_bytes\);' "$BRIDGE_C" || \
  fail "w2p byte accounting missing"
grep -Eq 'atomic_long_add\([^,]+,\s*&br->peer_to_wlan\.fwd_bytes\);' "$BRIDGE_C" || \
  fail "p2w byte accounting missing"

# --- v3 D3: legacy moal_bridge_rx / moal_bridge_should_forward removed ---
grep -Eq '^int moal_bridge_rx\(' "$BRIDGE_C" && \
  fail "legacy moal_bridge_rx must be removed"
grep -q 'moal_bridge_should_forward' "$BRIDGE_C" && \
  fail "legacy moal_bridge_should_forward must be removed"
grep -q 'int moal_bridge_rx(' "$ROOT/mlinux/moal_bridge.h" && \
  fail "moal_bridge_rx decl must be removed from header"

grep -q 'bridge: wlan BSS\[%d\] not ready' "$BRIDGE_C" || fail "wlan BSS guard site missing"
grep -q 'atomic_set(&bridge_instance_active, 0);' "$BRIDGE_C" || fail "bridge instance guard reset missing"

# --- runtime-switch Task 2: serialized bridge lifecycle ownership ---
grep -q 'DEFINE_MUTEX(bridge_lifecycle_lock)' "$BRIDGE_C" || fail "runtime-switch: lifecycle mutex missing"
grep -q 'static moal_handle \*bridge_owner' "$BRIDGE_C" || fail "runtime-switch: owner missing"
grep -q '^static int __moal_bridge_init_locked' "$BRIDGE_C" || fail "runtime-switch: locked init missing"
grep -q '^static void __moal_bridge_deinit_locked' "$BRIDGE_C" || fail "runtime-switch: locked deinit missing"
INIT_WRAP="$(grep -n -A20 -m1 '^int moal_bridge_init' "$BRIDGE_C")"
DEINIT_WRAP="$(grep -n -A20 -m1 '^void moal_bridge_deinit' "$BRIDGE_C")"
printf '%s\n' "$INIT_WRAP" | grep -q 'mutex_lock(&bridge_lifecycle_lock)' || fail "runtime-switch: init unlocked"
printf '%s\n' "$DEINIT_WRAP" | grep -q 'mutex_lock(&bridge_lifecycle_lock)' || fail "runtime-switch: deinit unlocked"

# --- runtime-switch Task 3: synchronous rebind transaction ---
grep -q 'moal_bridge_switch_iface' "$ROOT/mlinux/moal_bridge.h" || fail "runtime-switch: switch declaration missing"
grep -q 'moal_bridge_get_iface' "$ROOT/mlinux/moal_bridge.h" || fail "runtime-switch: getter declaration missing"
SWITCH_BLOCK="$(extract_switch_block "$BRIDGE_C")"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'MOAL_ACQ_SEMAPHORE_BLOCK(&AddRemoveCardSem)' || fail "runtime-switch: card semaphore missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'mutex_lock(&bridge_lifecycle_lock)' || fail "runtime-switch: lifecycle lock missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q '__moal_bridge_deinit_locked' || fail "runtime-switch: full deinit missing"
[ "$(printf '%s\n' "$SWITCH_BLOCK" | grep -c '__moal_bridge_init_locked' || true)" -ge 2 ] || fail "runtime-switch: target init and rollback required"
printf '%s\n' "$SWITCH_BLOCK" | grep -q -- '-EIO' || fail "runtime-switch: rollback failure EIO missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q '^.*out_unlock:' || fail "runtime-switch: shared unlock path missing"
[ "$(printf '%s\n' "$SWITCH_BLOCK" | grep -c 'mutex_unlock(&bridge_lifecycle_lock)' || true)" -eq 1 ] || fail "runtime-switch: lifecycle mutex must have one shared release"
[ "$(printf '%s\n' "$SWITCH_BLOCK" | grep -c 'MOAL_REL_SEMAPHORE(&AddRemoveCardSem)' || true)" -eq 1 ] || fail "runtime-switch: card semaphore must have one shared release"
printf '%s\n' "$SWITCH_BLOCK" | awk '
  /MOAL_ACQ_SEMAPHORE_BLOCK/ { card_lock=NR }
  /mutex_lock\(&bridge_lifecycle_lock\)/ { lifecycle_lock=NR }
  /mutex_unlock\(&bridge_lifecycle_lock\)/ { lifecycle_unlock=NR }
  /MOAL_REL_SEMAPHORE/ { card_unlock=NR }
  END { exit !(card_lock && lifecycle_lock && lifecycle_unlock && card_unlock &&
               card_lock < lifecycle_lock && lifecycle_lock < lifecycle_unlock &&
               lifecycle_unlock < card_unlock) }
' || fail "runtime-switch: lock acquire/release order is not card -> lifecycle -> lifecycle -> card"
printf '%s\n' "$SWITCH_BLOCK" | awk '
  /if \(READ_ONCE\(bridge_runtime_switch\) != 1\)/ { gate=NR }
  /return -EOPNOTSUPP;/ { gate_return=NR }
  /MOAL_ACQ_SEMAPHORE_BLOCK/ { card_lock=NR }
  END { exit !(gate && gate_return && card_lock &&
               gate < gate_return && gate_return < card_lock) }
' || fail "runtime-switch: exact opt-in rejection must precede lock acquisition"
check_no_direct_return_while_locked "$SWITCH_BLOCK" || \
  fail "runtime-switch: direct return bypasses shared releases"

NEGATIVE_SOURCE="$(mktemp)"
trap 'rm -f "$NEGATIVE_SOURCE"' EXIT
awk '
  /^int moal_bridge_switch_iface/ { in_switch=1 }
  { print }
  in_switch && /mutex_lock\(&bridge_lifecycle_lock\)/ && !injected {
    print "\treturn -EINVAL;"
    injected=1
  }
  END { exit !injected }
' "$BRIDGE_C" > "$NEGATIVE_SOURCE"
NEGATIVE_SWITCH_BLOCK="$(extract_switch_block "$NEGATIVE_SOURCE")"
if check_no_direct_return_while_locked "$NEGATIVE_SWITCH_BLOCK"; then
  fail "runtime-switch: direct-return negative fixture was accepted"
fi
rm -f "$NEGATIVE_SOURCE"
trap - EXIT
printf 'PASS: runtime-switch direct-return negative fixture rejected\n'
printf '%s\n' "$SWITCH_BLOCK" | awk '
  /moal_bridge_find_target/ { find=NR }
  /__moal_bridge_deinit_locked/ && !deinit { deinit=NR }
  END { exit !(find && deinit && find < deinit) }
' || fail "runtime-switch: target validation must precede teardown"
printf '%s\n' "$SWITCH_BLOCK" | awk '
  /target\.dev == bridge_owner->bridge->wlan_dev/ { same=NR }
  /__moal_bridge_deinit_locked/ && !deinit { deinit=NR }
  END { exit !(same && deinit && same < deinit) }
' || fail "runtime-switch: same-target no-op must precede teardown"
SAME_TARGET_BLOCK="$(extract_c_block "$SWITCH_BLOCK" '^[[:space:]]*if \(target\.dev == bridge_owner->bridge->wlan_dev\) \{')"
printf '%s\n' "$SAME_TARGET_BLOCK" | grep -Fq 'ret = 0' || fail "runtime-switch: same-target branch must succeed"
printf '%s\n' "$SAME_TARGET_BLOCK" | grep -Fq 'goto out_unlock' || fail "runtime-switch: same-target branch must use shared releases"
printf '%s\n' "$SAME_TARGET_BLOCK" | grep -Fq '__moal_bridge_deinit_locked' && fail "runtime-switch: same-target branch must not tear down"
printf '%s\n' "$SWITCH_BLOCK" | awk '
  /target_keepalive_idle_ms =/ { target_snapshot=NR }
  /__moal_bridge_deinit_locked/ && !deinit { deinit=NR }
  END { exit !(target_snapshot && deinit && target_snapshot < deinit) }
' || fail "runtime-switch: old/target snapshots must complete before teardown"
printf '%s\n' "$SWITCH_BLOCK" | awk '
  /__moal_bridge_deinit_locked/ && !deinit { deinit=NR }
  /bridge_owner = NULL/ && !owner_clear { owner_clear=NR }
  /target\.handle->params\.bridge_mode = 1/ && !target_policy { target_policy=NR }
  /ret = __moal_bridge_init_locked/ && !target_init { target_init=NR }
  END { exit !(deinit && owner_clear && target_policy && target_init &&
               deinit < owner_clear && owner_clear < target_policy &&
               target_policy < target_init) }
' || fail "runtime-switch: teardown/owner-clear/target-bind order is invalid"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'target_bridge_peer' || fail "runtime-switch: target peer snapshot missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'target_keepalive_ms' || fail "runtime-switch: target keepalive snapshot missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'target_keepalive_idle_ms' || fail "runtime-switch: target idle keepalive snapshot missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'target.handle->params.bridge_mode = target_mode' || fail "runtime-switch: target mode restoration missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'target.handle->params.bridge_wlan_idx = target_wlan_idx' || fail "runtime-switch: target index restoration missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'strncpy(target.handle->params.bridge_peer, target_bridge_peer' || fail "runtime-switch: target peer restoration missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'target.handle->params.bridge_keepalive_ms = target_keepalive_ms' || fail "runtime-switch: target keepalive restoration missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'target.handle->params.bridge_keepalive_idle_ms = target_keepalive_idle_ms' || fail "runtime-switch: target idle keepalive restoration missing"
printf '%s\n' "$SWITCH_BLOCK" | awk '
  /ret = __moal_bridge_init_locked/ && !target_init { target_init=NR }
  /target_ret = ret/ { target_error=NR }
  /target\.handle->params\.bridge_mode = target_mode/ { mode=NR }
  /target\.handle->params\.bridge_wlan_idx = target_wlan_idx/ { bss_idx=NR }
  /strncpy\(target\.handle->params\.bridge_peer, target_bridge_peer/ { peer=NR }
  /target\.handle->params\.bridge_keepalive_ms = target_keepalive_ms/ { keepalive=NR }
  /target\.handle->params\.bridge_keepalive_idle_ms = target_keepalive_idle_ms/ { idle=NR }
  /rollback_ret = __moal_bridge_init_locked/ { rollback_init=NR }
  END { exit !(target_init && target_error && mode && bss_idx && peer &&
               keepalive && idle && rollback_init && target_init < target_error &&
               target_error < mode && target_error < bss_idx && target_error < peer &&
               target_error < keepalive && target_error < idle &&
               mode < rollback_init && bss_idx < rollback_init &&
               peer < rollback_init && keepalive < rollback_init && idle < rollback_init) }
' || fail "runtime-switch: target parameters must be restored before rollback init"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'bridge_owner = NULL' || fail "runtime-switch: owner clear missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'bridge_owner = target.handle' || fail "runtime-switch: target owner publish missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'bridge_owner = old.old_owner' || fail "runtime-switch: rollback owner restore missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'if (old.old_owner != target.handle)' || fail "runtime-switch: same-handle mode preservation missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'old.old_owner->params.bridge_mode = 0' || fail "runtime-switch: old mode disable missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'target.handle->params.bridge_mode = 0' || fail "runtime-switch: rollback-failure target disable missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'br->wlan_dev = target' && fail "runtime-switch: direct wlan pointer hot-swap forbidden"

check_switch_success_contract "$SWITCH_BLOCK" || \
  fail "runtime-switch: target success branch contract missing"

# Mutation pair: ordinary braces around the alias guard must remain valid,
# while moving old-mode clear outside that guard must be rejected.
POSITIVE_BRACED_SWITCH="$(printf '%s\n' "$SWITCH_BLOCK" | awk '
  /if \(old\.old_owner != target\.handle\)/ {
    print $0 " {"
    bracing=1
    next
  }
  bracing && /old\.old_owner->params\.bridge_mode = 0/ {
    print
    print "\t\t}"
    bracing=0
    braced=1
    next
  }
  { print }
  END { exit !braced }
')"
check_switch_success_contract "$POSITIVE_BRACED_SWITCH" || \
  fail "runtime-switch: equivalent braced-guard positive fixture was rejected"
printf 'PASS: runtime-switch equivalent braced-guard positive fixture accepted\n'

NEGATIVE_ALIAS_SWITCH="$(printf '%s\n' "$SWITCH_BLOCK" | awk '
  /if \(old\.old_owner != target\.handle\)/ {
    print
    swapping=1
    next
  }
  swapping && /old\.old_owner->params\.bridge_mode = 0/ {
    print "\t\ttarget.handle->params.bridge_mode = 1;"
    next
  }
  swapping && /target\.handle->params\.bridge_mode = 1/ {
    print "\t\told.old_owner->params.bridge_mode = 0;"
    swapping=0
    swapped=1
    next
  }
  { print }
  END { exit !swapped }
')"
if check_switch_success_contract "$NEGATIVE_ALIAS_SWITCH"; then
  fail "runtime-switch: unconditional old-mode-clear negative fixture was accepted"
fi
printf 'PASS: runtime-switch unconditional old-mode-clear negative fixture rejected\n'

ROLLBACK_OK_BLOCK="$(extract_c_block "$SWITCH_BLOCK" '^[[:space:]]*if \(!rollback_ret\) \{')"
printf '%s\n' "$ROLLBACK_OK_BLOCK" | grep -Fq 'old.old_owner->params.bridge_mode = old.old_mode' || fail "runtime-switch: old mode restore must be in rollback-success branch"
printf '%s\n' "$ROLLBACK_OK_BLOCK" | grep -Fq 'bridge_owner = old.old_owner' || fail "runtime-switch: old owner restore must be in rollback-success branch"
printf '%s\n' "$ROLLBACK_OK_BLOCK" | grep -Fq 'atomic_long_inc(&bridge_switch_fail)' || fail "runtime-switch: switch_fail must count rollback success"
printf '%s\n' "$ROLLBACK_OK_BLOCK" | grep -Fq 'atomic_long_inc(&bridge_rollback_ok)' || fail "runtime-switch: rollback_ok must be in rollback-success branch"
printf '%s\n' "$ROLLBACK_OK_BLOCK" | grep -Fq 'ret = target_ret' || fail "runtime-switch: rollback success must preserve target errno"

ROLLBACK_FAIL_BLOCK="$(extract_c_block "$SWITCH_BLOCK" '^[[:space:]]*} else \{')"
printf '%s\n' "$ROLLBACK_FAIL_BLOCK" | grep -Fq 'old.old_owner->params.bridge_mode = 0' || fail "runtime-switch: old mode disable must be in rollback-failure branch"
printf '%s\n' "$ROLLBACK_FAIL_BLOCK" | grep -Fq 'target.handle->params.bridge_mode = 0' || fail "runtime-switch: target mode disable must be in rollback-failure branch"
printf '%s\n' "$ROLLBACK_FAIL_BLOCK" | grep -Fq 'bridge_owner = NULL' || fail "runtime-switch: owner clear must be in rollback-failure branch"
printf '%s\n' "$ROLLBACK_FAIL_BLOCK" | grep -Fq 'atomic_long_inc(&bridge_switch_fail)' || fail "runtime-switch: switch_fail must count rollback failure"
printf '%s\n' "$ROLLBACK_FAIL_BLOCK" | grep -Fq 'atomic_long_inc(&bridge_rollback_fail)' || fail "runtime-switch: rollback_fail must be in rollback-failure branch"
printf '%s\n' "$ROLLBACK_FAIL_BLOCK" | grep -Fq 'ret = -EIO' || fail "runtime-switch: rollback failure must return EIO"

GETTER_BLOCK="$(extract_c_function '^int moal_bridge_get_iface' "$BRIDGE_C")"
printf '%s\n' "$GETTER_BLOCK" | grep -Pzq 'ret = scnprintf\(buf, len, "%s\\n",\s*br && atomic_read\(&br->active\) \? br->wlan_name : "none"\);' || fail "runtime-switch: getter must report effective active state from stable name"

# --- runtime-switch Task 4: opt-in synchronous sysfs contract ---
grep -q 'int bridge_runtime_switch;' "$INIT_C" || fail "runtime-switch: gate missing"
grep -q 'module_param(bridge_runtime_switch, int, 0444)' "$INIT_C" || fail "runtime-switch: gate permissions wrong"
grep -q 'module_param_cb(bridge_iface, &bridge_iface_ops, NULL, 0644)' "$INIT_C" || fail "runtime-switch: callback parameter missing"
grep -q 'module_param(bridge_iface, charp' "$INIT_C" && fail "runtime-switch: charp forbidden"

SETTER_BLOCK="$(extract_c_function '^static int bridge_iface_set' "$INIT_C")"
GETTER_PARAM_BLOCK="$(extract_c_function '^static int bridge_iface_get' "$INIT_C")"
PARAM_OPS_BLOCK="$(extract_c_block "$(cat "$INIT_C")" \
  '^static const struct kernel_param_ops bridge_iface_ops')"
check_bridge_iface_set_contract "$SETTER_BLOCK" || \
  fail "runtime-switch: setter-local strict parse/synchronous contract missing"
printf '%s\n' "$GETTER_PARAM_BLOCK" | \
  grep -Fq 'return moal_bridge_get_iface(buf, PAGE_SIZE);' || \
  fail "runtime-switch: getter callback is not effective-state based"
printf '%s\n' "$PARAM_OPS_BLOCK" | grep -Fq '.set = bridge_iface_set' || \
  fail "runtime-switch: callback ops setter binding missing"
printf '%s\n' "$PARAM_OPS_BLOCK" | grep -Fq '.get = bridge_iface_get' || \
  fail "runtime-switch: callback ops getter binding missing"

# Focused mutation fixtures prove the callback-local checks reject the edge
# cases that unscoped greps used to miss, without attempting to emulate C.
SETTER_NO_TRAILING_REJECT="$(printf '%s\n' "$SETTER_BLOCK" |
  sed 's/if (!len || val\[end\])/if (!len)/')"
if check_bridge_iface_set_contract "$SETTER_NO_TRAILING_REJECT"; then
  fail "runtime-switch: trailing-data rejection negative fixture was accepted"
fi
printf 'PASS: runtime-switch trailing-data rejection negative fixture rejected\n'

SETTER_NO_BOUND="$(printf '%s\n' "$SETTER_BLOCK" |
  sed 's/len >= sizeof(ifname) - 1/len > sizeof(ifname) - 1/')"
if check_bridge_iface_set_contract "$SETTER_NO_BOUND"; then
  fail "runtime-switch: overlong-name negative fixture was accepted"
fi
printf 'PASS: runtime-switch overlong-name negative fixture rejected\n'

SETTER_ASYNC="$(printf '%s\n' "$SETTER_BLOCK" |
  sed 's/return moal_bridge_switch_iface(ifname);/moal_bridge_switch_iface(ifname); return 0;/')"
if check_bridge_iface_set_contract "$SETTER_ASYNC"; then
  fail "runtime-switch: asynchronous-setter negative fixture was accepted"
fi
printf 'PASS: runtime-switch asynchronous-setter negative fixture rejected\n'

# --- runtime-switch Task 5: observability and target QA ---
STATS_SHOW_BLOCK="$(extract_c_function '^static ssize_t stats_show' "$BRIDGE_C")"
SYSFS_DEINIT_BLOCK="$(extract_c_function '^static void moal_bridge_sysfs_deinit' "$BRIDGE_C")"
LIFECYCLE_DEINIT_BLOCK="$(extract_c_function '^static void __moal_bridge_deinit_locked' "$BRIDGE_C")"
REMOVE_CARD_BLOCK="$(extract_c_function '^mlan_status woal_remove_card' "$MAIN_C")"
grep -Fq 'static struct moal_bridge __rcu *moal_bridge_for_sysfs' "$BRIDGE_C" || \
  fail "runtime-switch: stats bridge pointer is not RCU annotated"
check_stats_rcu_lifetime_contract "$STATS_SHOW_BLOCK" "$SYSFS_DEINIT_BLOCK" \
  "$LIFECYCLE_DEINIT_BLOCK" "$REMOVE_CARD_BLOCK" || \
  fail "runtime-switch: stats RCU lifetime/drain-before-free contract missing"
RCU_DEINIT_NO_DRAIN="$(printf '%s\n' "$SYSFS_DEINIT_BLOCK" |
  sed 's/synchronize_rcu();/\/\* removed drain \*\//')"
if check_stats_rcu_lifetime_contract "$STATS_SHOW_BLOCK" "$RCU_DEINIT_NO_DRAIN" \
    "$LIFECYCLE_DEINIT_BLOCK" "$REMOVE_CARD_BLOCK"; then
  fail "runtime-switch: undrained stats lifetime negative fixture was accepted"
fi
printf 'PASS: runtime-switch undrained stats lifetime negative fixture rejected\n'
STATS_EARLY_RETURN="$(printf '%s\n' "$STATS_SHOW_BLOCK" |
  sed '0,/goto out_rcu;/s//return ret;/')"
if check_stats_rcu_lifetime_contract "$STATS_EARLY_RETURN" "$SYSFS_DEINIT_BLOCK" \
    "$LIFECYCLE_DEINIT_BLOCK" "$REMOVE_CARD_BLOCK"; then
  fail "runtime-switch: stats early-return negative fixture was accepted"
fi
printf 'PASS: runtime-switch stats early-return negative fixture rejected\n'
REMOVE_CARD_FREE_FIRST="$(printf '%s\n' "$REMOVE_CARD_BLOCK" | awk '
  /moal_bridge_deinit\(handle\)/ { saved=$0; next }
  /woal_free_moal_handle\(handle\)/ { print; print saved; moved=1; next }
  { print }
  END { exit !moved }
')"
if check_stats_rcu_lifetime_contract "$STATS_SHOW_BLOCK" "$SYSFS_DEINIT_BLOCK" \
    "$LIFECYCLE_DEINIT_BLOCK" "$REMOVE_CARD_FREE_FIRST"; then
  fail "runtime-switch: handle-free-before-bridge-deinit negative fixture was accepted"
fi
printf 'PASS: runtime-switch handle-free ordering negative fixture rejected\n'
printf '%s\n' "$STATS_SHOW_BLOCK" | \
  grep -q 'switch_ok=%ld switch_fail=%ld rollback_ok=%ld rollback_fail=%ld' || \
  fail "runtime-switch: outcome stats missing"
printf '%s\n' "$STATS_SHOW_BLOCK" | grep -q 'iface=%s peer=%s' || \
  fail "runtime-switch: iface stats missing"
printf '%s\n' "$STATS_SHOW_BLOCK" | \
  grep -Fq 'br->wlan_name' || \
  fail "runtime-switch: stats cached iface name missing"
printf '%s\n' "$STATS_SHOW_BLOCK" | \
  grep -Fq 'br->peer_name' || \
  fail "runtime-switch: stats cached peer name missing"
BRIDGE_INIT_BLOCK="$(extract_c_function '^static int __moal_bridge_init_locked' "$BRIDGE_C")"
check_bridge_name_snapshot_contract "$BRIDGE_INIT_BLOCK" || \
  fail "runtime-switch: per-bridge name mapping/termination/publication order invalid"
BRIDGE_INIT_SWAPPED_NAMES="$(printf '%s\n' "$BRIDGE_INIT_BLOCK" |
  sed -e 's/br->wlan_dev->name/br->swap_dev->name/' \
      -e 's/br->peer_dev->name/br->wlan_dev->name/' \
      -e 's/br->swap_dev->name/br->peer_dev->name/')"
if check_bridge_name_snapshot_contract "$BRIDGE_INIT_SWAPPED_NAMES"; then
  fail "runtime-switch: swapped per-bridge-name negative fixture was accepted"
fi
printf 'PASS: runtime-switch swapped per-bridge-name negative fixture rejected\n'
BRIDGE_INIT_NO_PEER_NUL="$(printf '%s\n' "$BRIDGE_INIT_BLOCK" |
  sed "s/br->peer_name\[sizeof(br->peer_name) - 1\] = '\\\\0';/\/\* missing peer terminator \*\//")"
if check_bridge_name_snapshot_contract "$BRIDGE_INIT_NO_PEER_NUL"; then
  fail "runtime-switch: unterminated peer-name negative fixture was accepted"
fi
printf 'PASS: runtime-switch unterminated peer-name negative fixture rejected\n'
NETDEV_EVENT_BLOCK="$(extract_c_function '^static int moal_bridge_netdev_event' "$BRIDGE_C")"
check_no_post_release_peer_name_deref "$NETDEV_EVENT_BLOCK" \
  "$LIFECYCLE_DEINIT_BLOCK" || \
  fail "runtime-switch: peer_dev name dereferenced after peer reference release"
POST_RELEASE_NAME_DEREF="$(printf '%s\n' "$LIFECYCLE_DEINIT_BLOCK" | awk '
  { print }
  /\/\* 7\. 통계 출력 \*\// && !injected {
    print "\tPRINTM(MMSG, \"%s\\n\", br->peer_dev->name);"
    injected=1
  }
  END { exit !injected }
 ')"
if check_no_post_release_peer_name_deref "$NETDEV_EVENT_BLOCK" \
    "$POST_RELEASE_NAME_DEREF"; then
  fail "runtime-switch: post-release peer-name negative fixture was accepted"
fi
printf 'PASS: runtime-switch post-release peer-name negative fixture rejected\n'

# Every reset path that destroys WLAN interfaces owns AddRemoveCardSem before
# entering the bridge lifecycle lock. The direct post-reset rebuild acquires it
# itself and keeps it through teardown, every add, and the optional re-init.
PCIE_FLR_BLOCK="$(extract_c_function '^static mlan_status woal_do_flr' "$PCIE_C")"
SDIO_FLR_BLOCK="$(extract_c_function '^static mlan_status woal_do_sdiommc_flr' "$SDIO_C")"
DRV_MODE_BLOCK="$(extract_c_function '^mlan_status woal_switch_drv_mode' "$MAIN_C")"
POST_RESET_BLOCK="$(extract_c_function '^static void woal_post_reset' "$MAIN_C")"
for reset_contract in "$PCIE_FLR_BLOCK" "$SDIO_FLR_BLOCK" "$DRV_MODE_BLOCK"; do
  check_reset_teardown_order "$reset_contract" || \
    fail "runtime-switch: reset path removes interfaces before bridge teardown"
done
check_post_reset_bridge_contract "$POST_RESET_BLOCK" || \
  fail "runtime-switch: post-reset bridge teardown/recreate ordering invalid"
check_sdio_flr_sem_exit_contract "$SDIO_FLR_BLOCK" || \
  fail "runtime-switch: SDIO FLR null-adapter path leaks card semaphore"

PCIE_FLR_NO_DEINIT="$(printf '%s\n' "$PCIE_FLR_BLOCK" |
  sed 's/moal_bridge_deinit(handle);/\/\* missing bridge teardown \*\//')"
if check_reset_teardown_order "$PCIE_FLR_NO_DEINIT"; then
  fail "runtime-switch: PCIe FLR missing-deinit negative fixture was accepted"
fi
printf 'PASS: runtime-switch PCIe FLR missing-deinit negative fixture rejected\n'

SDIO_FLR_LATE_DEINIT="$(printf '%s\n' "$SDIO_FLR_BLOCK" | awk '
  /moal_bridge_deinit\(handle\)/ { saved=$0; next }
  /woal_remove_interface\(handle,/ { print; print saved; moved=1; next }
  { print }
  END { exit !moved }
')"
if check_reset_teardown_order "$SDIO_FLR_LATE_DEINIT"; then
  fail "runtime-switch: SDIO FLR late-deinit negative fixture was accepted"
fi
printf 'PASS: runtime-switch SDIO FLR late-deinit negative fixture rejected\n'

POST_RESET_NO_REINIT="$(printf '%s\n' "$POST_RESET_BLOCK" |
  sed 's/moal_bridge_init(handle,/missing_bridge_init(handle,/')"
if check_post_reset_bridge_contract "$POST_RESET_NO_REINIT"; then
  fail "runtime-switch: post-reset missing-reinit negative fixture was accepted"
fi
printf 'PASS: runtime-switch post-reset missing-reinit negative fixture rejected\n'

POST_RESET_NO_ACQUIRE="$(printf '%s\n' "$POST_RESET_BLOCK" |
  sed 's/MOAL_ACQ_SEMAPHORE_BLOCK(&AddRemoveCardSem)/missing_card_sem_acquire()/')"
if check_post_reset_bridge_contract "$POST_RESET_NO_ACQUIRE"; then
  fail "runtime-switch: post-reset missing-acquire negative fixture was accepted"
fi
printf 'PASS: runtime-switch post-reset missing-acquire negative fixture rejected\n'

POST_RESET_NO_RELEASE="$(printf '%s\n' "$POST_RESET_BLOCK" |
  sed 's/MOAL_REL_SEMAPHORE(&AddRemoveCardSem)/missing_card_sem_release()/')"
if check_post_reset_bridge_contract "$POST_RESET_NO_RELEASE"; then
  fail "runtime-switch: post-reset missing-release negative fixture was accepted"
fi
printf 'PASS: runtime-switch post-reset missing-release negative fixture rejected\n'

POST_RESET_FAILED_ACQUIRE_TO_CLEANUP="$(printf '%s\n' "$POST_RESET_BLOCK" | awk '
  /MOAL_ACQ_SEMAPHORE_BLOCK\(&AddRemoveCardSem\)/ { in_acquire=1 }
  in_acquire && /goto card_sem_acquire_failed;/ && !mutated {
    sub(/goto card_sem_acquire_failed;/, "goto done;")
    mutated=1
  }
  { print }
  END { exit !mutated }
')"
if check_post_reset_bridge_contract "$POST_RESET_FAILED_ACQUIRE_TO_CLEANUP"; then
  fail "runtime-switch: post-reset failed-acquire cleanup mutation was accepted"
fi
printf 'PASS: runtime-switch post-reset failed-acquire cleanup mutation rejected\n'

POST_RESET_ACQUIRE_FAILURE_HANDLE_TOUCH="$(printf '%s\n' "$POST_RESET_BLOCK" | awk '
  /^card_sem_acquire_failed:/ && !injected {
    print
    print "\thandle->fw_reload = MFALSE;"
    injected=1
    next
  }
  { print }
  END { exit !injected }
')"
if check_post_reset_bridge_contract "$POST_RESET_ACQUIRE_FAILURE_HANDLE_TOUCH"; then
  fail "runtime-switch: post-reset acquire-failure handle touch was accepted"
fi
printf 'PASS: runtime-switch post-reset acquire-failure handle-touch mutation rejected\n'

POST_RESET_DUPLICATE_INIT="$(printf '%s\n' "$POST_RESET_BLOCK" | awk '
  /if \(moal_bridge_init\(handle,/ && !injected {
    print "\t\t\tmoal_bridge_init(handle, handle->params.bridge_peer,"
    print "\t\t\t\t\t handle->params.bridge_wlan_idx);"
    injected=1
  }
  { print }
  END { exit !injected }
')"
if check_post_reset_bridge_contract "$POST_RESET_DUPLICATE_INIT"; then
  fail "runtime-switch: post-reset duplicate-init negative fixture was accepted"
fi
printf 'PASS: runtime-switch post-reset duplicate-init negative fixture rejected\n'

POST_RESET_PREMATURE_INIT="$(printf '%s\n' "$POST_RESET_BLOCK" |
  sed 's/moal_bridge_init(handle,/deferred_bridge_init(handle,/' | awk '
    /if \(!woal_add_interface\(handle, handle->priv_num,/ && !injected {
      print "\t\t\tmoal_bridge_init(handle, handle->params.bridge_peer,"
      print "\t\t\t\t\t handle->params.bridge_wlan_idx);"
      injected=1
    }
    { print }
    END { exit !injected }
  ')"
if check_post_reset_bridge_contract "$POST_RESET_PREMATURE_INIT"; then
  fail "runtime-switch: post-reset premature-init negative fixture was accepted"
fi
printf 'PASS: runtime-switch post-reset premature-init negative fixture rejected\n'

POST_RESET_ADD_FAILURE_FALLTHROUGH="$(printf '%s\n' "$POST_RESET_BLOCK" | awk '
  /if \(!woal_add_interface\(handle, handle->priv_num,/ { in_failure=1 }
  in_failure && /goto done;/ && !mutated {
    sub(/goto done;/, "continue;")
    mutated=1
  }
  { print }
  END { exit !mutated }
')"
if check_post_reset_bridge_contract "$POST_RESET_ADD_FAILURE_FALLTHROUGH"; then
  fail "runtime-switch: post-reset add-failure fallthrough fixture was accepted"
fi
printf 'PASS: runtime-switch post-reset add-failure fallthrough fixture rejected\n'

SDIO_FLR_NULL_ADAPTER_RETURN="$(printf '%s\n' "$SDIO_FLR_BLOCK" | awk '
  /if \(!\(handle->pmlan_adapter\)\)/ { in_null_adapter=1 }
  in_null_adapter && /goto exit;/ && !mutated {
    sub(/goto exit;/, "return status;")
    mutated=1
  }
  { print }
  END { exit !mutated }
')"
if check_sdio_flr_sem_exit_contract "$SDIO_FLR_NULL_ADAPTER_RETURN"; then
  fail "runtime-switch: SDIO FLR null-adapter return leak fixture was accepted"
fi
printf 'PASS: runtime-switch SDIO FLR null-adapter return leak fixture rejected\n'
for counter in bridge_switch_ok bridge_switch_fail bridge_rollback_ok \
               bridge_rollback_fail; do
  printf '%s\n' "$STATS_SHOW_BLOCK" | \
    grep -Fq "atomic_long_read(&$counter)" || \
    fail "runtime-switch: stats does not atomically read $counter"
  grep -Fq "atomic_long_set(&$counter" "$BRIDGE_C" && \
    fail "runtime-switch: persistent counter $counter is reset"
done
test -x "$QA_SCRIPT" || \
  fail "runtime-switch: executable QA script missing"
grep -Fq '[ "$(id -u)" -eq 0 ]' "$QA_SCRIPT" || \
  fail "runtime-switch: QA root preflight missing"
grep -Fq '[ -e "$IFACE_PARAM" ]' "$QA_SCRIPT" || \
  fail "runtime-switch: QA interface parameter preflight missing"
grep -Fq '[ -e "$GATE_PARAM" ]' "$QA_SCRIPT" || \
  fail "runtime-switch: QA gate preflight missing"
grep -Fq 'ip link show "$FROM_IF"' "$QA_SCRIPT" || \
  fail "runtime-switch: QA FROM_IF preflight missing"
grep -Fq 'ip link show "$TO_IF"' "$QA_SCRIPT" || \
  fail "runtime-switch: QA TO_IF preflight missing"
grep -Fq 'require_associated "$FROM_IF"' "$QA_SCRIPT" || \
  fail "runtime-switch: QA FROM_IF association preflight missing"
grep -Fq 'require_associated "$TO_IF"' "$QA_SCRIPT" || \
  fail "runtime-switch: QA TO_IF association preflight missing"
grep -Eq 'ip[[:space:]]+link[[:space:]]+set|iw[[:space:]].*[[:space:]]connect|wpa_cli|nmcli' "$QA_SCRIPT" && \
  fail "runtime-switch: QA script must not configure or associate links"
grep -Fq 'cat "$STATS"' "$QA_SCRIPT" || \
  fail "runtime-switch: QA stats capture missing"
QA_SWITCH_HELPER="$(extract_c_function '^switch_iface\(\)' "$QA_SCRIPT")" || \
  fail "runtime-switch: QA contextual switch helper missing"
printf '%s\n' "$QA_SWITCH_HELPER" | \
  grep -Fq 'if ! printf' || \
  fail "runtime-switch: QA writes are not contextually guarded"
[ "$(grep -Fc '> "$IFACE_PARAM"' "$QA_SCRIPT" || true)" -eq 1 ] || \
  fail "runtime-switch: every QA sysfs write must use switch_iface"
printf '%s\n' "$QA_SWITCH_HELPER" | grep -Fq 'iteration=$iteration' || \
  fail "runtime-switch: QA write failure omits iteration context"
grep -Fq 'MAX_SWITCH_LOOPS=' "$QA_SCRIPT" || \
  fail "runtime-switch: QA loop upper bound missing"
grep -Fq '10#$SWITCH_LOOPS' "$QA_SCRIPT" || \
  fail "runtime-switch: QA loop count is not canonicalized as decimal"
grep -Fq 'SWITCH_LOOPS must use canonical decimal' "$QA_SCRIPT" || \
  fail "runtime-switch: QA canonical decimal rejection missing"
grep -Fq 'dmesg > "$DMESG_BASELINE"' "$QA_SCRIPT" || \
  fail "runtime-switch: QA dmesg baseline missing"
grep -Fq 'head -n "$dmesg_baseline_lines" "$DMESG_AFTER"' "$QA_SCRIPT" || \
  fail "runtime-switch: QA dmesg prefix/rotation validation missing"
grep -Fq 'tail -n "+$((dmesg_baseline_lines + 1))"' "$QA_SCRIPT" || \
  fail "runtime-switch: QA full dmesg delta extraction missing"
grep -Fq "grep -E 'BUG:|WARNING:|use-after-free|lockdep'" "$QA_SCRIPT" || \
  fail "runtime-switch: QA kernel-warning check missing"
grep -Fq 'tail -200' "$QA_SCRIPT" && \
  fail "runtime-switch: QA warning scan is still tail-limited"

grep -Fq '`bridge_runtime_switch` | int | 0444' "$PARAM_DOC" || \
  fail "runtime-switch: parameter docs missing 0444 gate semantics"
grep -Fq '`bridge_iface` | custom string | 0644' "$PARAM_DOC" || \
  fail "runtime-switch: parameter docs missing 0644 callback semantics"
for errno in EOPNOTSUPP ENODEV EINVAL ENETDOWN ENOLINK EBUSY EIO; do
  grep -Fq "\`$errno\`" "$PARAM_DOC" || \
    fail "runtime-switch: parameter docs missing $errno"
done
grep -Fq 'FROM_IF=mlan0 TO_IF=mlan1 SWITCH_LOOPS=1000' "$QA_RUNBOOK" || \
  fail "runtime-switch: runbook stress command missing"
grep -Fq 'iw dev mlan0 link' "$QA_RUNBOOK" || \
  fail "runtime-switch: runbook mlan0 association check missing"
grep -Fq 'iw dev mlan1 link' "$QA_RUNBOOK" || \
  fail "runtime-switch: runbook mlan1 association check missing"
T15_RUNBOOK_BLOCK="$(awk '
  /^## T-15 / { in_section=1 }
  in_section && /^---$/ { exit }
  in_section { print }
' "$QA_RUNBOOK")"
grep -Fq 'set -o pipefail' <<< "$T15_RUNBOOK_BLOCK" || \
  fail "runtime-switch: runbook QA pipeline does not preserve failure"
grep -Fq '2>&1 | tee /tmp/bridge-switch-qa.log' <<< "$T15_RUNBOOK_BLOCK" || \
  fail "runtime-switch: runbook QA pipeline does not capture stderr"
grep -Fq 'exit 1' <<< "$T15_RUNBOOK_BLOCK" || \
  fail "runtime-switch: runbook does not stop after QA failure"
printf '%s\n' "$T15_RUNBOOK_BLOCK" | awk '
  /set -o pipefail/ { pipefail=NR }
  /if ! FROM_IF=/ { guarded=NR }
  /bridge_runtime_switch_qa\.sh 2>&1 \| tee/ { pipeline=NR }
  /exit 1/ { stop=NR }
  /^fi$/ && stop && !closed { closed=NR }
  /capture_switch_state after/ { after=NR }
  END { exit !(pipefail && guarded && pipeline && stop && closed && after &&
               pipefail < guarded && guarded < pipeline && pipeline < stop &&
               stop < closed && closed < after) }
' || fail "runtime-switch: runbook failure guard must precede after-snapshots"

# --- v2 B5: oom_drops counter ---
grep -Eq 'atomic_long_t\s+oom_drops' "$ROOT/mlinux/moal_bridge.h" || \
  fail "oom_drops field missing from struct moal_bridge_stats"

OOM_INC_COUNT="$(grep -c 'atomic_long_inc(&.*oom_drops)' "$BRIDGE_C" || true)"
if [ "$OOM_INC_COUNT" -lt 3 ]; then
  fail "oom_drops increment sites < 3 in moal_bridge.c (got $OOM_INC_COUNT)"
fi

grep -q 'oom=%ld' "$BRIDGE_C" || fail "deinit stats dump missing oom=%ld field"

# --- v2 B6: DBDC double-init returns -EBUSY ---
DBDC_BLOCK="$(grep -n -A6 -m1 'atomic_cmpxchg(&bridge_instance_active, 0, 1) != 0' "$BRIDGE_C")"
printf '%s\n' "$DBDC_BLOCK" | grep -q 'return -EBUSY;' || \
  fail "DBDC double-init guard must return -EBUSY"
printf '%s\n' "$DBDC_BLOCK" | grep -q 'MERROR' || \
  fail "DBDC double-init log level must be MERROR"

# --- v2 B1: NETDEV_UNREGISTER handler/ref release ---
grep -Eq 'atomic_t\s+peer_released' "$ROOT/mlinux/moal_bridge.h" || \
  fail "peer_released must be atomic_t (F1) in struct moal_bridge"

UNREG_BLOCK="$(grep -n -A20 -m1 'case NETDEV_UNREGISTER:' "$BRIDGE_C")"
printf '%s\n' "$UNREG_BLOCK" | \
  grep -Eq 'netdev_rx_handler_unregister\(br->peer_dev\)|dev_remove_pack\(&br->peer_pt\)' || \
  fail "NETDEV_UNREGISTER branch must unregister handler"
printf '%s\n' "$UNREG_BLOCK" | grep -q 'dev_set_promiscuity(br->peer_dev, -1)' || \
  fail "NETDEV_UNREGISTER branch must drop promisc"
printf '%s\n' "$UNREG_BLOCK" | grep -q 'dev_put(br->peer_dev)' || \
  fail "NETDEV_UNREGISTER branch must dev_put peer"
printf '%s\n' "$UNREG_BLOCK" | grep -q 'atomic_set(&br->peer_released, 1)' || \
  fail "NETDEV_UNREGISTER branch must atomic_set peer_released = 1 (F1)"

DEINIT_BLOCK="$(grep -n -A90 -m1 'void __moal_bridge_deinit_locked' "$BRIDGE_C")"
printf '%s\n' "$DEINIT_BLOCK" | grep -q 'if (!atomic_read(&br->peer_released))' || \
  fail "deinit must use atomic_read(&peer_released) for gate check (F1)"

# --- v2 B2: atomic qlen hard cap ---
grep -Eq 'atomic_t\s+w2p_qlen' "$ROOT/mlinux/moal_bridge.h" || \
  fail "w2p_qlen atomic missing from struct moal_bridge"
grep -Eq 'atomic_t\s+p2w_qlen' "$ROOT/mlinux/moal_bridge.h" || \
  fail "p2w_qlen atomic missing from struct moal_bridge"

grep -Eq 'atomic_inc_return\(&br->w2p_qlen\)' "$BRIDGE_C" || \
  fail "w2p enqueue guard not using atomic_inc_return"
grep -Eq 'atomic_inc_return\(&br->p2w_qlen\)' "$BRIDGE_C" || \
  fail "p2w enqueue guard not using atomic_inc_return"
grep -Eq 'atomic_dec\(&br->w2p_qlen\)' "$BRIDGE_C" || \
  fail "w2p dequeue not decrementing qlen"
grep -Eq 'atomic_dec\(&br->p2w_qlen\)' "$BRIDGE_C" || \
  fail "p2w dequeue not decrementing qlen"

grep -q 'skb_queue_len_lockless' "$BRIDGE_C" && \
  fail "skb_queue_len_lockless must be fully replaced by atomic qlen"

# --- v2 B4: NETDEV_DOWN purges both queues ---
DOWN_BLOCK="$(grep -n -A8 -m1 'case NETDEV_DOWN:' "$BRIDGE_C")"
printf '%s\n' "$DOWN_BLOCK" | grep -q 'skb_queue_purge(&br->w2p_queue)' || \
  fail "NETDEV_DOWN must purge w2p_queue"
printf '%s\n' "$DOWN_BLOCK" | grep -q 'skb_queue_purge(&br->p2w_queue)' || \
  fail "NETDEV_DOWN must purge p2w_queue"
printf '%s\n' "$DOWN_BLOCK" | grep -q 'atomic_set(&br->w2p_qlen, 0)' || \
  fail "NETDEV_DOWN must reset w2p_qlen"
printf '%s\n' "$DOWN_BLOCK" | grep -q 'atomic_set(&br->p2w_qlen, 0)' || \
  fail "NETDEV_DOWN must reset p2w_qlen"

# --- v2 B3: pskb_may_pull guards in rx_fast ---
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -Eq 'pskb_may_pull\(skb,\s*VLAN_ETH_HLEN\)' || \
  fail "rx_fast missing VLAN header pull guard"
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -Eq 'pskb_may_pull\(skb,\s*l3_off \+ sizeof\(struct iphdr\)\)' || \
  fail "rx_fast missing IPv4 header pull guard"

# --- v2 B7: packet_type fallback skb_share_check ---
printf '%s\n' "$P2W_PACKET_TYPE_BLOCK" | \
  grep -Eq 'skb\s*=\s*skb_share_check\(skb,\s*GFP_ATOMIC\)' || \
  fail "packet_type fallback must unshare via skb_share_check"
printf '%s\n' "$P2W_PACKET_TYPE_BLOCK" | \
  grep -q 'atomic_long_inc(&br->peer_to_wlan.oom_drops)' || \
  fail "packet_type fallback must count share_check OOM as oom_drops"

# --- v2 A1: ktime_get gated by bridge_debug in rx_fast ---
printf '%s\n' "$W2P_FAST_BLOCK" | \
  awk '/ktime_get\(\)/ {found=NR} END {if (found) print found}' | \
  grep -q '.' || fail "ktime_get expected inside rx_fast"
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -Eq 'if \(bridge_debug\)[[:space:]]*\{' || \
  fail "rx_fast timing block must be inside 'if (bridge_debug)'"

# --- v2 A2: non-self unicast consumed without clone ---
printf '%s\n' "$P2W_RX_HANDLER_BLOCK" | \
  grep -Eq 'return[[:space:]]+RX_HANDLER_CONSUMED' || \
  fail "rx_handler must return RX_HANDLER_CONSUMED for non-self unicast"
printf '%s\n' "$P2W_RX_HANDLER_BLOCK" | \
  grep -q '\*pskb = NULL;' || \
  fail "rx_handler must null pskb before returning CONSUMED"

# --- v3 D1: RCU protection on handle->bridge ---
grep -q 'rcu_assign_pointer(handle->bridge, br)' "$BRIDGE_C" || \
  fail "bridge init must rcu_assign_pointer(handle->bridge, br)"
grep -q 'rcu_assign_pointer(handle->bridge, NULL)' "$BRIDGE_C" || \
  fail "bridge deinit must rcu_assign_pointer NULL"
grep -q 'synchronize_rcu()' "$BRIDGE_C" || \
  fail "bridge deinit must synchronize_rcu before kfree"
grep -q 'rcu_dereference(handle->bridge)' "$SHIM_C" || \
  fail "moal_shim must rcu_dereference(handle->bridge) on RX fast path"
grep -cE 'handle->bridge(->|\s*\))' "$SHIM_C" | awk '$1 > 0 {
  if ($1 > 2) { print "FAIL: lingering handle->bridge direct deref in shim (" $1 ")"; exit 1 }
}'

# --- v3 D2: A-MSDU subframe honors rx_fast CONSUMED return ---
W2P_FAST_BLOCK2="$(grep -n -A170 -m1 '^int moal_bridge_rx_fast' "$BRIDGE_C")"
printf '%s\n' "$W2P_FAST_BLOCK2" | \
  grep -Eq 'return[[:space:]]+1;\s*/\*.*consumed' || \
  fail "rx_fast must return 1 for consumed (non-self unicast)"

# v6 IA-M10: cached pattern 'if (br_amsdu_active && moal_bridge_rx_fast(...)) continue;'
# 가 2줄로 나뉘어 있으므로 multiline 모드(-Pz)로 검사. legacy br_consumed 패턴도 대체 허용.
if grep -Pzoq 'if \(br_amsdu_active[\s\S]{0,60}moal_bridge_rx_fast' "$SHIM_C" 2>/dev/null; then
  :
elif grep -Eq 'if \(consumed\)[[:space:]]*\{?.*continue;' "$SHIM_C"; then
  :
elif grep -Eq 'if \(br_consumed\)' "$SHIM_C"; then
  :
else
  fail "A-MSDU loop must honor rx_fast consumed return (br_amsdu_active cache or legacy br_consumed)"
fi

# --- v3 D4: use cached peer_mac in rx_handler ---
P2W_RX_HANDLER_BLOCK2="$(grep -n -A200 -m1 'moal_bridge_peer_rx_handler' "$BRIDGE_C")"
printf '%s\n' "$P2W_RX_HANDLER_BLOCK2" | \
  grep -q 'br->peer_dev->dev_addr' && \
  fail "rx_handler must use cached br->peer_mac, not br->peer_dev->dev_addr"
printf '%s\n' "$P2W_RX_HANDLER_BLOCK2" | \
  grep -q 'br->peer_mac' || \
  fail "rx_handler must reference cached br->peer_mac"

# --- v3 D5: READ_ONCE / WRITE_ONCE on shared hot-path fields ---
grep -q 'READ_ONCE(br->wlan_ipv4)' "$BRIDGE_C" || \
  fail "wlan_ipv4 hot-path read must use READ_ONCE"
grep -q 'WRITE_ONCE(br->wlan_ipv4' "$BRIDGE_C" || \
  fail "wlan_ipv4 write in inetaddr notifier must use WRITE_ONCE"
grep -q 'WRITE_ONCE(br->peer_ipv4' "$BRIDGE_C" || \
  fail "peer_ipv4 write in inetaddr notifier must use WRITE_ONCE"
grep -q 'READ_ONCE(((moal_private \*)br->wlan_priv)->media_connected)' "$BRIDGE_C" || \
  fail "media_connected hot-path read must use READ_ONCE"

# --- v3 D6: NULL guard in inetaddr notifier ---
INET_BLOCK="$(grep -n -A25 -m1 'moal_bridge_inetaddr_event' "$BRIDGE_C")"
printf '%s\n' "$INET_BLOCK" | \
  grep -Eq 'if \(!ifa \|\| !ifa->ifa_dev' || \
  fail "inetaddr notifier must guard against NULL ifa/ifa_dev"

# --- v3 D7: EAPOL check must catch VLAN-tagged EAPOL (after VLAN unwrap) ---
printf '%s\n' "$W2P_FAST_BLOCK" | \
  awk '/l3_off = VLAN_ETH_HLEN/ {seen_vlan=1} seen_vlan && /ETH_P_PAE/ {found=1} END {exit !found}' || \
  fail "rx_fast must check EAPOL after VLAN unwrap (not before)"

# --- v4 E1: 802.1D bridge group (link-local) never forwarded ---
grep -q 'moal_bridge_is_link_local' "$BRIDGE_C" || \
  fail "802.1D link-local filter helper (moal_bridge_is_link_local) missing"
grep -q 'IEEE 802.1D' "$BRIDGE_C" || \
  fail "IEEE 802.1D bridge group drop comment missing from moal_bridge.c"
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -q 'moal_bridge_is_link_local' || \
  fail "rx_fast must drop 802.1D link-local frames"
printf '%s\n' "$P2W_RX_HANDLER_BLOCK2" | \
  grep -q 'moal_bridge_is_link_local' || \
  fail "peer_rx_handler must drop 802.1D link-local frames"

# --- v4 E2: carrier/registration readiness checks ---
grep -q 'moal_bridge_dev_ready' "$BRIDGE_C" || \
  fail "carrier/reg readiness helper (moal_bridge_dev_ready) missing"
DEV_READY_COUNT=$(grep -c 'moal_bridge_dev_ready' "$BRIDGE_C" || true)
if [ "$DEV_READY_COUNT" -lt 5 ]; then
  fail "moal_bridge_dev_ready should be used at helper + 3 enqueue + 2 xmit sites (got $DEV_READY_COUNT)"
fi
grep -q 'netif_carrier_ok' "$BRIDGE_C" || \
  fail "dev_ready helper must use netif_carrier_ok"
grep -q 'NETREG_REGISTERED' "$BRIDGE_C" || \
  fail "dev_ready helper must gate on NETREG_REGISTERED"

# --- v4 E3: sched_setscheduler / setattr failures surface via pr_warn_once ---
SCHED_BLOCK="$(grep -n -A40 -m1 'moal_bridge_apply_sched' "$BRIDGE_C")"
printf '%s\n' "$SCHED_BLOCK" | grep -q 'pr_warn_once' || \
  fail "moal_bridge_apply_sched must pr_warn_once on scheduler API failure"

# --- v4 E4: skb headroom guard before skb_push(ETH_HLEN) ---
grep -q 'moal_bridge_ensure_headroom' "$BRIDGE_C" || \
  fail "headroom helper (moal_bridge_ensure_headroom) missing"
grep -q 'skb_realloc_headroom' "$BRIDGE_C" || \
  fail "helper must use skb_realloc_headroom on headroom underflow"
HEADROOM_COUNT=$(grep -c 'moal_bridge_ensure_headroom' "$BRIDGE_C" || true)
if [ "$HEADROOM_COUNT" -lt 4 ]; then
  fail "moal_bridge_ensure_headroom should guard all 3 skb_push sites (got $HEADROOM_COUNT, need ≥4 = helper + 3 uses)"
fi

# --- v4 E5: /sys/kernel/moal_bridge/stats read-only sysfs node ---
grep -q 'kobject_create_and_add' "$BRIDGE_C" || \
  fail "sysfs stats node must use kobject_create_and_add"
grep -q '__ATTR_RO(stats)' "$BRIDGE_C" || \
  fail "sysfs stats must be read-only (__ATTR_RO)"
grep -q 'moal_bridge_sysfs_init' "$BRIDGE_C" || \
  fail "sysfs init helper missing"
grep -q 'moal_bridge_sysfs_deinit' "$BRIDGE_C" || \
  fail "sysfs deinit helper missing"
grep -Eq 'moal_bridge_sysfs_init\(' "$BRIDGE_C" | head -1 >/dev/null && \
grep -q 'moal_bridge_sysfs_init(br)' "$BRIDGE_C" || \
  fail "moal_bridge_init must call sysfs_init"
grep -q 'moal_bridge_sysfs_deinit()' "$BRIDGE_C" || \
  fail "moal_bridge_deinit must call sysfs_deinit"

# --- v5 F1: atomic peer_released + RCU drain before kthread_stop ---
# Enforce deinit order: rcu_assign_pointer(handle->bridge, NULL) + synchronize_rcu()
# must appear BEFORE kthread_stop(br->w2p/p2w_thread). This closes the race
# where a RCU reader still holding the old br pointer could skb_queue_tail
# into a queue whose kthread has already been stopped.
# Scope every lookup to lines AFTER __moal_bridge_deinit_locked() starts — otherwise
# init()'s rollback cleanup (stops a partially-created kthread on error) would
# shadow the deinit occurrence and the ordering check would be nonsensical.
DEINIT_START=$(grep -n '^static void __moal_bridge_deinit_locked' "$BRIDGE_C" | head -1 | cut -d: -f1)
[ -n "$DEINIT_START" ] || fail "F1: __moal_bridge_deinit_locked() not found"
RCU_NULL_LINE=$(awk -v s="$DEINIT_START" 'NR > s && /rcu_assign_pointer\(handle->bridge, NULL\)/ { print NR; exit }' "$BRIDGE_C")
SYNC_RCU_LINE=$(awk -v s="$DEINIT_START" 'NR > s && /^[[:space:]]*synchronize_rcu\(\);/ { print NR; exit }' "$BRIDGE_C")
KTHREAD_W2P_LINE=$(awk -v s="$DEINIT_START" 'NR > s && /kthread_stop\(br->w2p_thread\)/ { print NR; exit }' "$BRIDGE_C")
KTHREAD_P2W_LINE=$(awk -v s="$DEINIT_START" 'NR > s && /kthread_stop\(br->p2w_thread\)/ { print NR; exit }' "$BRIDGE_C")
if [ -z "$RCU_NULL_LINE" ] || [ -z "$SYNC_RCU_LINE" ] || \
   [ -z "$KTHREAD_W2P_LINE" ] || [ -z "$KTHREAD_P2W_LINE" ]; then
  fail "F1: required deinit statements missing (rcu_assign NULL / synchronize_rcu / kthread_stop w2p+p2w)"
fi
if [ "$RCU_NULL_LINE" -ge "$KTHREAD_W2P_LINE" ] || \
   [ "$RCU_NULL_LINE" -ge "$KTHREAD_P2W_LINE" ]; then
  fail "F1: rcu_assign_pointer(handle->bridge, NULL) must appear BEFORE kthread_stop (rcu=$RCU_NULL_LINE w2p=$KTHREAD_W2P_LINE p2w=$KTHREAD_P2W_LINE)"
fi
if [ "$SYNC_RCU_LINE" -le "$RCU_NULL_LINE" ] || \
   [ "$SYNC_RCU_LINE" -ge "$KTHREAD_W2P_LINE" ]; then
  fail "F1: synchronize_rcu() must sit between rcu_assign_pointer(NULL) and kthread_stop (rcu=$RCU_NULL_LINE sync=$SYNC_RCU_LINE w2p=$KTHREAD_W2P_LINE)"
fi

# --- v6 F2: kthread freezer join + wait_event_freezable ---
# PM suspend 시 w2p/p2w kthread 가 SDIO IO를 물고 멈추지 않도록 freezer 등록.
grep -q '#include <linux/freezer.h>' "$BRIDGE_C" || \
  fail "F2: moal_bridge.c must #include <linux/freezer.h>"
FREEZABLE_COUNT=$(grep -c 'set_freezable();' "$BRIDGE_C" || true)
if [ "$FREEZABLE_COUNT" -lt 2 ]; then
  fail "F2: set_freezable() expected in both w2p_thread_fn and p2w_thread_fn (got $FREEZABLE_COUNT)"
fi
WAIT_FREEZE_COUNT=$(grep -c 'wait_event_freezable' "$BRIDGE_C" || true)
if [ "$WAIT_FREEZE_COUNT" -lt 2 ]; then
  fail "F2: wait_event_freezable expected in both kthreads (got $WAIT_FREEZE_COUNT)"
fi
grep -q 'wait_event_interruptible(br->w2p_wait' "$BRIDGE_C" && \
  fail "F2: w2p_thread_fn still uses wait_event_interruptible (should be _freezable)"
grep -q 'wait_event_interruptible(br->p2w_wait' "$BRIDGE_C" && \
  fail "F2: p2w_thread_fn still uses wait_event_interruptible (should be _freezable)"

# --- v6 D8: peer_rx_handler uses VLAN-aware EAPOL detection ---
P2W_RX_HANDLER_BLOCK3="$(grep -n -A200 -m1 'moal_bridge_peer_rx_handler' "$BRIDGE_C")"
printf '%s\n' "$P2W_RX_HANDLER_BLOCK3" | \
  grep -q 'vlan_get_protocol(skb) == htons(ETH_P_PAE)' || \
  fail "D8: peer_rx_handler must use vlan_get_protocol for EAPOL detection (symmetry with rx_fast D7)"

# --- v6 IA-M10: A-MSDU loop caches bridge pointer outside the subframe loop ---
grep -q 'br_amsdu_active' "$SHIM_C" || \
  fail "IA-M10: A-MSDU loop must hoist bridge pointer into br_amsdu cache"
# rcu_read_lock must appear BEFORE 'while (skb != frame)' in recv_amsdu_packet
AMSDU_FUNC_START=$(grep -n '^mlan_status moal_recv_amsdu_packet' "$SHIM_C" | head -1 | cut -d: -f1)
if [ -n "$AMSDU_FUNC_START" ]; then
  AMSDU_RCU_LOCK=$(awk -v s="$AMSDU_FUNC_START" 'NR > s && /rcu_read_lock\(\);/ { print NR; exit }' "$SHIM_C")
  AMSDU_WHILE=$(awk -v s="$AMSDU_FUNC_START" 'NR > s && /while \(skb != frame\)/ { print NR; exit }' "$SHIM_C")
  if [ -z "$AMSDU_RCU_LOCK" ] || [ -z "$AMSDU_WHILE" ]; then
    fail "IA-M10: could not locate rcu_read_lock or while-loop in moal_recv_amsdu_packet"
  fi
  if [ "$AMSDU_RCU_LOCK" -ge "$AMSDU_WHILE" ]; then
    fail "IA-M10: rcu_read_lock must precede A-MSDU 'while (skb != frame)' (rcu=$AMSDU_RCU_LOCK while=$AMSDU_WHILE)"
  fi
fi

# --- v7: RCU read-side lock/unlock balance (file-level) ---
# 같은 파일 내 rcu_read_lock() 개수와 rcu_read_unlock() 개수가 일치해야 함.
# 2026-04-21 IA-M10 hotfix(32a9129) 가 해결한 회귀(unlock 누락 → WiFi 로드 hang)
# 같은 부류를 커밋 전 catch 하기 위한 규칙.
check_rcu_balance() {
  local file="$1"
  local lock_cnt unlock_cnt
  # Match only statement-form "\s* rcu_read_lock();" at line start.
  # 주석 내부의 rcu_read_lock() 언급( " * ... rcu_read_lock() ...") 은
  # 제외되어 false-positive 방지.
  lock_cnt=$(grep -cE '^[[:space:]]*rcu_read_lock\(\);' "$file" || true)
  unlock_cnt=$(grep -cE '^[[:space:]]*rcu_read_unlock\(\);' "$file" || true)
  if [ "$lock_cnt" -ne "$unlock_cnt" ]; then
    fail "RCU balance: $file rcu_read_lock=$lock_cnt rcu_read_unlock=$unlock_cnt — unbalanced"
  fi
}
check_rcu_balance "$BRIDGE_C"
check_rcu_balance "$SHIM_C"

# Forbid plain br->peer_released access outside atomic_read / atomic_set wrappers
# (sysfs PRINTM uses atomic_read, UNREG uses atomic_set, deinit uses atomic_read).
PLAIN_PEER_RELEASED=$(grep -n 'br->peer_released' "$BRIDGE_C" \
  | grep -Ev 'atomic_read\(&br->peer_released\)|atomic_set\(&br->peer_released,' \
  || true)
if [ -n "$PLAIN_PEER_RELEASED" ]; then
  printf 'F1: plain br->peer_released access (must wrap atomic):\n%s\n' "$PLAIN_PEER_RELEASED" >&2
  exit 1
fi

# --- local hairpin (PR #10) 핵심 경로 스모크 단언 ---
grep -q '^int moal_bridge_tx_hairpin' "$BRIDGE_C" || \
  fail "hairpin: tx divert 함수 누락"
grep -q 'hairpin_tx_fwd' "$BRIDGE_C" && grep -q 'hairpin_arp_tee' "$BRIDGE_C" && \
  grep -q 'hairpin_arp_inject' "$BRIDGE_C" || \
  fail "hairpin: 카운터 3종 누락"
grep -q 'READ_ONCE(bridge_local_hairpin)' "$BRIDGE_C" || \
  fail "hairpin: READ_ONCE 핫패스 게이트 누락"
grep -q 'ether_addr_copy(((struct ethhdr \*)skb2->data)->h_source' "$BRIDGE_C" || \
  fail "hairpin: tee src-MAC 재작성 누락 (anti-spoof 가드)"
P2W_PT_INJECT="$(printf '%s\n' "$P2W_PACKET_TYPE_BLOCK" | grep -c 'netif_rx(skb)')"
[ "${P2W_PT_INJECT:-0}" -ge 1 ] || fail "hairpin: pt_func REPLY inject 분기 누락"

TARGET_BLOCK="$(grep -n -A100 -m1 '^static int moal_bridge_find_target' "$BRIDGE_C")"
for token in 'm_handle\[' MLAN_BSS_TYPE_STA NETREG_REGISTERED \
             netif_device_present netif_running media_connected \
             HardwareStatusReady fw_reseting surprise_removed; do
  printf '%s\n' "$TARGET_BLOCK" | grep -q "$token" || \
    fail "runtime-switch: target validator missing $token"
done

printf 'PASS: keepalive, bounded queues, worker accounting, F1 RCU drain ordering + atomic peer_released + hairpin smoke enforced\n'
