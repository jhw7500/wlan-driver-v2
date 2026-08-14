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

check_ready_switch_contract() {
  local setter="$1" switch="$2"

  printf '%s\n' "$setter" | awk '
    /READ_ONCE\(bridge_runtime_control_ready\)/ { ready=NR }
    /READ_ONCE\(bridge_runtime_switch\)/ { gate=NR }
    /moal_bridge_switch_iface\(ifname\)/ { call=NR }
    END { exit !(ready && gate && call && ready < gate && gate < call) }
  ' || return 1
  printf '%s\n' "$switch" | awk '
    /READ_ONCE\(bridge_runtime_control_ready\)/ {
      ready_count++
      if (ready_count == 1) pre=NR
      if (ready_count == 2) post=NR
    }
    /MOAL_ACQ_SEMAPHORE_BLOCK\(&AddRemoveCardSem\)/ { lock=NR }
    /mutex_lock\(&bridge_lifecycle_lock\)/ { lifecycle=NR }
    END { exit !(pre && lock && post && lifecycle &&
                 pre < lock && lock < post && post < lifecycle) }
  '
}

check_runtime_switch_conf_contract() {
  local parser="$1"

  printf '%s\n' "$parser" | awk '
    /int bridge_runtime_switch_cfg = 0/ { cfg_decl=NR }
    /int bridge_runtime_switch_present = 0/ { present_decl=NR }
    /strncmp\(line, "bridge_runtime_switch"/ { key=NR }
    /parse_line_read_int\(line, &out_data\)/ && key && !parse { parse=NR }
    /out_data != 0 && out_data != 1/ { range=NR }
    /bridge_runtime_switch_cfg = out_data/ { save=NR }
    /bridge_runtime_switch_present = 1/ { mark=NR }
    /^[[:space:]]*if \(end\)[[:space:]]*\{/ { commit=NR }
    /if \(bridge_runtime_switch_cfg\)/ { enable=NR }
    /WRITE_ONCE\(bridge_runtime_switch, 1\)/ { write=NR }
    /if \(bridge_runtime_switch_present\)/ { log_gate=NR }
    /bridge_runtime_switch = %d \(conf=%d\)/ { log_line=NR }
    END {
      exit !(cfg_decl && present_decl && key && parse && range && save && mark &&
             commit && enable && write && log_gate && log_line &&
             cfg_decl < key && present_decl < key && key < parse &&
             parse < range && range < save && save <= mark && mark < commit &&
             commit < enable && enable < write && write < log_gate &&
             log_gate < log_line)
    }
  ' || return 1

  ! grep -Eq 'WRITE_ONCE\(bridge_runtime_switch,[[:space:]]*(0|out_data|bridge_runtime_switch_cfg)\)' <<< "$parser"
}

check_cleanup_transaction() {
  printf '%s\n' "$1" | awk '
    /WRITE_ONCE\(bridge_runtime_control_ready, 0\)/ { clear=NR }
	/WRITE_ONCE\(driver_exit_in_progress, 1\)/ { exit_gate=NR }
	/flush_workqueue\(register_workqueue\)/ && !register_drain { register_drain=NR }
	/flush_workqueue\(hang_workqueue\)/ && !hang_drain { hang_drain=NR }
	/woal_quiesce_reset_work\(m_handle\[index\]\)/ { reset_drain=NR }
    /down\(&AddRemoveCardSem\)/ { lock=NR }
	lock && /for \(index = 0; index < MAX_MLAN_ADAPTER; index\+\+\)/ {
      loops++
      if (loops == 2) second_pass=NR
    }
    loops == 1 && /moal_bridge_deinit\(handle\)/ { deinit=NR }
    loops == 1 && /woal_flush_workqueue\(handle\)/ { flush=NR }
    /woal_shutdown_fw/ && !shutdown { shutdown=NR }
    /MOAL_REL_SEMAPHORE\(&AddRemoveCardSem\)/ { unlock=NR }
	END { exit !(clear && exit_gate && register_drain && hang_drain && reset_drain &&
		 lock && deinit && flush && second_pass && shutdown &&
                 unlock && clear < lock && lock < deinit && deinit < flush &&
		 exit_gate < register_drain && register_drain < hang_drain &&
		 hang_drain < reset_drain && reset_drain < lock &&
		 flush < second_pass && second_pass < shutdown && shutdown < unlock) }
  '
}

check_terminal_switch_contract() {
  printf '%s\n' "$1" | awk '
    /ret = __moal_bridge_init_locked/ && !target_init { target_init=NR }
    /ret = moal_bridge_validate_binding_locked/ && !validate { validate=NR }
    validate && /__moal_bridge_deinit_locked\(target.handle\)/ && !target_deinit {
      target_deinit=NR
    }
    /^[[:space:]]*rollback:/ { rollback=NR }
    /bridge_owner = target.handle/ { owner=NR }
    /atomic_long_inc\(&bridge_switch_ok\)/ { success=NR }
	/rollback_ret = __moal_bridge_init_locked/ { rollback_init=NR }
	/rollback_ret = moal_bridge_validate_binding_locked/ { rollback_validate=NR }
	rollback_validate && /__moal_bridge_deinit_locked\(old.old_owner\)/ {
	  rollback_deinit=NR
	}
	/bridge_owner = old.old_owner/ { rollback_owner=NR }
    END { exit !(target_init && validate && target_deinit && rollback && owner &&
		 success && rollback_init && rollback_validate && rollback_deinit &&
		 rollback_owner && target_init < validate && validate < target_deinit &&
                 target_deinit < rollback && validate < owner && owner < success &&
                 rollback < rollback_init && rollback_init < rollback_validate &&
                 rollback_validate < rollback_deinit && rollback_deinit < rollback_owner) }
  ' || return 1
  printf '%s\n' "$1" | awk '
    /rtnl_lock\(\)/ && !target_lock { target_lock=NR }
    /^[[:space:]]*ret = moal_bridge_validate_binding_locked/ && !target_validate { target_validate=NR }
    /rtnl_unlock\(\)/ && target_validate && !target_unlock { target_unlock=NR }
    /rtnl_lock\(\)/ && target_unlock && !rollback_lock { rollback_lock=NR }
    /rollback_ret = moal_bridge_validate_binding_locked/ { rollback_validate=NR }
    /rtnl_unlock\(\)/ && rollback_validate && !rollback_unlock { rollback_unlock=NR }
    /bridge_owner = old.old_owner/ { rollback_owner=NR }
    END { exit !(target_lock && target_validate && target_unlock && rollback_lock &&
                 rollback_validate && rollback_unlock && rollback_owner &&
                 target_lock < target_validate && target_validate < target_unlock &&
                 target_unlock < rollback_lock && rollback_lock < rollback_validate &&
                 rollback_validate < rollback_unlock && rollback_unlock < rollback_owner) }
  '
}

check_fault_hook_compile_guard() {
  local source="$1"

  printf '%s\n' "$source" | awk '
    /^#ifdef BRIDGE_SWITCH_FAULT_INJECT/ { guarded=1; seen_guard=1; next }
    /^#endif/ && guarded { guarded=0; next }
    /int fault_mask = 0;/ { variable=1; if (!guarded) bad=1 }
    /xchg\(&bridge_switch_fault_mask, 0\)/ { consume=1; if (!guarded) bad=1 }
    /if \(fault_mask & BIT\(0\)\)/ { target=1; if (!guarded) bad=1 }
    /if \(fault_mask & BIT\(1\)\)/ { rollback=1; if (!guarded) bad=1 }
    END { exit !(seen_guard && variable && consume && target && rollback && !bad) }
  '
}

check_standard_artifact_fault_absence() {
  local artifact found=0
  shopt -s nullglob
  for artifact in "$ROOT"/moal.ko "$ROOT"/bin_wlan/*.ko; do
    [ -f "$artifact" ] || continue
    found=1
    if strings "$artifact" | grep -Fq 'bridge_switch_fault_mask'; then
      fail "runtime-switch: standard artifact exposes fault symbol: $artifact"
    fi
    printf 'PASS: runtime-switch standard artifact has no fault symbol: %s (freshness not established)\n' "$artifact"
  done
  shopt -u nullglob
  [ "$found" -eq 1 ] || printf 'INFO: runtime-switch no host standard artifact available for fault-symbol absence check\n'
}

check_peer_identity_contract() {
	local switch="$1" init="$2" flat

  printf '%s\n' "$switch" | awk '
    /dev_hold\(old.peer_dev\)/ { hold=NR }
    /__moal_bridge_deinit_locked\(old.old_owner\)/ && !deinit { deinit=NR }
    /^out_peer:/ { shared=NR }
    /dev_put\(old.peer_dev\)/ { put=NR; puts++ }
    END { exit !(hold && deinit && shared && put && puts == 1 &&
                 hold < deinit && deinit < shared && shared < put) }
  ' || return 1
	[ "$(grep -Fc 'old.peer_dev' <<< "$switch" || true)" -ge 6 ] || return 1
	grep -Fq 'dev_get_by_name' <<< "$switch" && return 1
	flat="$(printf '%s\n' "$switch" | tr '\n' ' ' |
	  sed 's/[[:space:]][[:space:]]*/ /g')"
	grep -Fq \
	  'target.handle, old.peer, old.peer_dev, target.bss_index' <<< "$flat" || return 1
	grep -Fq \
	  'old.old_owner, old.peer, old.peer_dev, old.old_bss_index' <<< "$flat" || return 1
	grep -Fq 'struct net_device *peer_identity' <<< "$init" || return 1
	grep -Fq 'peer_identity->reg_state == NETREG_REGISTERED' <<< "$init" || return 1
	grep -Fq 'dev_hold(peer)' <<< "$init" || return 1
}

# The final RTNL identity check must complete before the bridge pointer is RCU
# published; operational readiness then gates the active publication.  Treat
# these as separate publication steps: a load-time owner can exist inactive,
# but active forwarding cannot be advertised before final device/media checks.
check_init_readiness_publication_contract() {
  local init="$1"

  printf '%s\n' "$init" | awk '
    /register_inetaddr_notifier/ { inet_notifier=NR }
    inet_notifier && /rtnl_lock\(\)/ && !final_rtnl { final_rtnl=NR }
    final_rtnl && /atomic_read\(&br->peer_released\)/ && !peer_released { peer_released=NR }
    final_rtnl && /br->peer_dev->reg_state != NETREG_REGISTERED/ { peer_reg=NR }
    final_rtnl && /br->wlan_dev->reg_state != NETREG_REGISTERED/ { wlan_reg=NR }
    final_rtnl && /!netif_device_present\(br->peer_dev\)/ { peer_present=NR }
    final_rtnl && /!netif_device_present\(br->wlan_dev\)/ { wlan_present=NR }
    /rcu_assign_pointer\(handle->bridge, br\)/ { rcu_publish=NR }
    /atomic_set\(&br->published, 1\)/ { published=NR }
    /if \(moal_bridge_dev_ready\(br->peer_dev\)/ { operational=NR }
    operational && /moal_bridge_dev_ready\(br->wlan_dev\)/ { wlan_ready=NR }
    operational && /media_connected/ { associated=NR }
    /atomic_set\(&br->active, netif_running\(br->peer_dev\) \? 1 : 0\)/ { active=NR }
    /rtnl_unlock\(\)/ && active && !final_unlock { final_unlock=NR }
    END {
      exit !(final_rtnl && peer_released && peer_reg && wlan_reg &&
             peer_present && wlan_present && rcu_publish && published &&
             operational && wlan_ready && associated && active && final_unlock &&
             final_rtnl < peer_released && peer_released < rcu_publish &&
             peer_reg < rcu_publish && wlan_reg < rcu_publish &&
             peer_present < rcu_publish && wlan_present < rcu_publish &&
             rcu_publish < published && published < operational &&
             operational < wlan_ready && wlan_ready < associated &&
             associated < active && active < final_unlock)
    }
  '
}

check_name_sync_contract() {
  local notifier="$1" init="$2" getter="$3" stats="$4"

  printf '%s\n' "$notifier" | grep -Fq 'NETDEV_CHANGENAME' || return 1
  printf '%s\n' "$notifier" | grep -Fq 'dev == br->wlan_dev' || return 1
  printf '%s\n' "$notifier" | grep -Fq 'dev != br->peer_dev' || return 1
  printf '%s\n' "$notifier" | grep -Fq 'spin_lock_irqsave(&br->name_lock' || return 1
  printf '%s\n' "$init" | awk '
	/ret = register_netdevice_notifier/ { notifier=NR }
    notifier && /rtnl_lock\(\)/ && !rtnl { rtnl=NR }
    /strncpy\(br->wlan_name, br->wlan_dev->name/ { wlan=NR }
    /strncpy\(br->peer_name, br->peer_dev->name/ { peer=NR }
    END { exit !(notifier && rtnl && wlan && peer &&
                 notifier < rtnl && rtnl < wlan && wlan < peer) }
  ' || return 1
  printf '%s\n' "$getter" | grep -Fq 'spin_lock_irqsave(&br->name_lock' || return 1
  printf '%s\n' "$stats" | grep -Fq 'spin_lock_irqsave(&br->name_lock' || return 1
}

check_fw_sem_ownership() {
  local dpc="$1" init_fw="$2"

  printf '%s\n' "$dpc" | awk '
    /if \(!READ_ONCE\(handle->fw_init_card_sem_owned\)\)/ { guard=NR }
    /MOAL_REL_SEMAPHORE\(&AddRemoveCardSem\)/ { release=NR }
    END { exit !(guard && release && guard < release) }
  ' || return 1
  printf '%s\n' "$init_fw" | awk '
    /if \(!READ_ONCE\(handle->fw_init_card_sem_owned\)\)/ { guard=NR }
    /MOAL_REL_SEMAPHORE\(&AddRemoveCardSem\)/ { release=NR }
    END { exit !(guard && release && guard < release) }
  ' || return 1
  for caller in "$DRV_MODE_BLOCK" "$PCIE_FLR_BLOCK" "$SDIO_FLR_BLOCK"; do
    printf '%s\n' "$caller" | awk '
      /WRITE_ONCE\(handle->fw_init_card_sem_owned, MTRUE\)/ { own=NR }
      /woal_init_fw\(handle\)/ { init=NR }
      /WRITE_ONCE\(handle->fw_init_card_sem_owned, MFALSE\)/ && init { clear=NR }
      END { exit !(own && init && clear && own < init && init < clear) }
    ' || return 1
  done
}

check_qa_cleanup_contract() {
  printf '%s\n' "$1" | awk '
    /original_status=\$\?/ { status=NR }
    /trap - EXIT/ { untrap=NR }
    /set \+e/ { no_errexit=NR }
    /capture_state "final-before-restore"/ { before=NR }
    /current_binding=/ { current=NR }
    /current_binding.*!= none/ { active=NR }
    /binding_ready "\$INITIAL_BINDING"/ { ready=NR }
    /> "\$IFACE_PARAM"/ { restore=NR }
    /capture_state "final-after-restore"/ { after=NR }
    /kill "\$DMESG_STREAM_PID"/ { stop=NR }
    /wait "\$DMESG_STREAM_PID"/ { wait=NR }
    /exit "\$final_status"/ { exit_line=NR }
    END { exit !(status == 2 && untrap && no_errexit && before && current &&
                 active && ready && restore && after && stop && wait && exit_line &&
                 status < untrap && untrap < no_errexit && no_errexit < before &&
                 before < current && current < active && active < ready &&
                 ready < restore && restore < after && after < stop &&
                 stop < wait && wait < exit_line) }
  '
}

# Fast-path excerpts are shared by the legacy packet/RCU checks below. Keep
# their windows explicit so a later function growth cannot silently turn a
# missing declaration into an unbound-variable false gate.
KEEPALIVE_BLOCK="$(grep -n -A80 -m1 'static enum hrtimer_restart moal_bridge_keepalive' "$BRIDGE_C")"
W2P_FAST_BLOCK="$(grep -n -A170 -m1 '^int moal_bridge_rx_fast' "$BRIDGE_C")"
P2W_RX_HANDLER_BLOCK="$(grep -n -A260 -m1 'moal_bridge_peer_rx_handler' "$BRIDGE_C")"
P2W_PACKET_TYPE_BLOCK="$(grep -n -A220 -m1 'moal_bridge_peer_pt_func' "$BRIDGE_C")"

# Extract scoped subjects once. Every subsequent source-order and mutation check
# uses these exact functions rather than a whole-file token match.
SETTER_BLOCK="$(extract_c_function '^static int bridge_iface_set' "$INIT_C")"
# parse_cfg_read_block compares against the literal string "}"; the generic
# brace scanner intentionally does not parse C strings, so use the function's
# column-zero closing brace as the boundary for this one large parser.
CONF_PARSER_BLOCK="$(sed -n '/^static mlan_status parse_cfg_read_block/,/^}/p' "$INIT_C")"
INIT_MODULE_BLOCK="$(extract_c_function '^static int woal_init_module' "$MAIN_C")"
CLEANUP_MODULE_BLOCK="$(extract_c_function '^static void woal_cleanup_module' "$MAIN_C")"
REQUEST_RELOAD_BLOCK="$(extract_c_function '^int woal_request_fw_reload' "$MAIN_C")"
PRE_RESET_BLOCK="$(extract_c_function '^static void woal_pre_reset' "$MAIN_C")"
POST_RESET_BLOCK="$(extract_c_function '^static int woal_post_reset' "$MAIN_C")"
MAIN_WORK_BLOCK="$(extract_c_function '^t_void woal_main_work_queue' "$MAIN_C")"
FW_DPC_BLOCK="$(extract_c_function '^static mlan_status woal_request_fw_dpc' "$MAIN_C")"
INIT_FW_BLOCK="$(extract_c_function '^mlan_status woal_init_fw' "$MAIN_C")"
DRV_MODE_BLOCK="$(extract_c_function '^mlan_status woal_switch_drv_mode' "$MAIN_C")"
SWITCH_BLOCK="$(extract_switch_block "$BRIDGE_C")"
VALIDATE_BLOCK="$(extract_c_function '^static int moal_bridge_validate_binding_locked' "$BRIDGE_C")"
BRIDGE_INIT_BLOCK="$(extract_c_function '^static int __moal_bridge_init_locked' "$BRIDGE_C")"
LIFECYCLE_DEINIT_BLOCK="$(extract_c_function '^static void __moal_bridge_deinit_locked' "$BRIDGE_C")"
NETDEV_EVENT_BLOCK="$(extract_c_function '^static int moal_bridge_netdev_event' "$BRIDGE_C")"
GETTER_BLOCK="$(extract_c_function '^int moal_bridge_get_iface' "$BRIDGE_C")"
STATS_SHOW_BLOCK="$(extract_c_function '^static ssize_t stats_show' "$BRIDGE_C")"
SYSFS_DEINIT_BLOCK="$(extract_c_function '^static void moal_bridge_sysfs_deinit' "$BRIDGE_C")"
STATS_CLEANUP_BLOCK="$(extract_c_function '^void moal_bridge_stats_cleanup' "$BRIDGE_C")"
SUSPEND_OWNER_BLOCK="$(extract_c_function '^static int __moal_bridge_suspend_owner' "$BRIDGE_C")"
REMOVE_CARD_BLOCK="$(extract_c_function '^mlan_status woal_remove_card' "$MAIN_C")"
PCIE_FLR_BLOCK="$(extract_c_function '^static mlan_status __woal_do_flr' "$PCIE_C")"
PCIE_PREP_BLOCK="$(extract_c_function '^static void woal_pcie_reset_prepare' "$PCIE_C")"
PCIE_DONE_BLOCK="$(extract_c_function '^static void woal_pcie_reset_done' "$PCIE_C")"
PCIE_NOTIFY_BLOCK="$(extract_c_function '^static void woal_pcie_reset_notify' "$PCIE_C")"
PCIE_WORK_BLOCK="$(extract_c_function '^static void woal_pcie_work\(struct work_struct \*work\)$' "$PCIE_C")"
SDIO_FLR_BLOCK="$(extract_c_function '^static mlan_status __woal_do_sdiommc_flr' "$SDIO_C")"
SDIO_WORK_BLOCK="$(extract_c_function '^static void woal_sdiommc_work\(struct work_struct \*work\)$' "$SDIO_C")"
SDIO_REMOVE_BLOCK="$(extract_c_function '^void woal_sdio_remove\(struct sdio_func \*func\)$' "$SDIO_C")"
QA_CLEANUP_BLOCK="$(extract_c_function '^cleanup\(\)' "$QA_SCRIPT")"

# Invoke all defined strong structural helpers; their focused mutations below
# make these source-order checks regression gates rather than dead declarations.
check_standard_artifact_fault_absence
check_fault_hook_compile_guard "$SWITCH_BLOCK" ||
  fail "runtime-switch: every fault declaration and injected branch must be inside BRIDGE_SWITCH_FAULT_INJECT"
check_runtime_switch_conf_contract "$CONF_PARSER_BLOCK" ||
  fail "runtime-switch: conf parser must validate and monotonically enable the global gate"

CONF_PARSER_NO_ENABLE="$(printf '%s\n' "$CONF_PARSER_BLOCK" |
  sed 's|WRITE_ONCE(bridge_runtime_switch, 1);|/* missing global gate enable */|')"
if check_runtime_switch_conf_contract "$CONF_PARSER_NO_ENABLE"; then
  fail "runtime-switch: missing conf gate-enable mutation accepted"
fi
printf 'PASS: runtime-switch conf gate-enable mutation rejected\n'

CONF_PARSER_NO_RANGE="$(printf '%s\n' "$CONF_PARSER_BLOCK" |
  sed 's/out_data != 0 && out_data != 1/out_data < 0/')"
if check_runtime_switch_conf_contract "$CONF_PARSER_NO_RANGE"; then
  fail "runtime-switch: invalid conf range-check mutation accepted"
fi
printf 'PASS: runtime-switch conf range-check mutation rejected\n'

grep -Fq '✓(전역 enable-only)' "$PARAM_DOC" ||
  fail "runtime-switch: parameter docs missing conf enable-only contract"
grep -Fq 'bridge_runtime_switch = %d (conf=%d)' "$INIT_C" ||
  fail "runtime-switch: conf parser missing effective/configured diagnostic"

# A: module-argument parsing cannot reach an uninitialized semaphore, and exit
# closes the post-wait race before destructive teardown.
grep -q '^int bridge_runtime_control_ready;' "$INIT_C" || \
  fail "runtime-switch: runtime-control readiness flag missing"
check_ready_switch_contract "$SETTER_BLOCK" "$SWITCH_BLOCK" || \
  fail "runtime-switch: readiness pre/post semaphore contract missing"
printf '%s\n' "$INIT_MODULE_BLOCK" | awk '
  /MOAL_INIT_SEMAPHORE\(&AddRemoveCardSem\)/ { sem=NR }
  /moal_bridge_stats_init\(\)/ { stats=NR }
  /WRITE_ONCE\(bridge_runtime_control_ready, 1\)/ { ready=NR }
  END { exit !(sem && stats && ready && sem < stats && stats < ready) }
' || fail "runtime-switch: readiness published before required module state"
check_cleanup_transaction "$CLEANUP_MODULE_BLOCK" || \
  fail "runtime-switch: unload does not drain every owner before first shutdown"

SETTER_NO_READY="$(printf '%s\n' "$SETTER_BLOCK" |
  sed 's/if (!READ_ONCE(bridge_runtime_control_ready))/if (0)/')"
if check_ready_switch_contract "$SETTER_NO_READY" "$SWITCH_BLOCK"; then
  fail "runtime-switch: missing pre-init setter readiness fixture accepted"
fi
printf 'PASS: runtime-switch pre-init readiness mutation rejected\n'
SWITCH_ONE_READY="$(printf '%s\n' "$SWITCH_BLOCK" | awk '
  /READ_ONCE\(bridge_runtime_control_ready\)/ { n++ }
  n == 2 { sub(/READ_ONCE\(bridge_runtime_control_ready\)/, "0") }
  { print }
')"
if check_ready_switch_contract "$SETTER_BLOCK" "$SWITCH_ONE_READY"; then
  fail "runtime-switch: missing post-wait readiness fixture accepted"
fi
printf 'PASS: runtime-switch post-wait readiness mutation rejected\n'

# B/E/F: reload/reset/unload own complete effective-state transitions; firmware
# init never releases a semaphore retained by a destructive caller.
printf '%s\n' "$PRE_RESET_BLOCK" | awk '
  /moal_bridge_deinit\(handle\)/ { deinit=NR }
  /woal_flush_workqueue\(handle\)/ && !flush { flush=NR }
  END { exit !(deinit && flush && deinit < flush) }
' || fail "runtime-switch: pre-reset bridge is not drained before workqueue"
printf '%s\n' "$REQUEST_RELOAD_BLOCK" | awk '
  /mode != FW_RELOAD_NO_EMULATION/ { mode_check=NR }
  /MOAL_ACQ_SEMAPHORE_BLOCK\(&AddRemoveCardSem\)/ { lock=NR }
  /moal_bridge_suspend_owner\(\)/ { suspend=NR }
  /woal_pre_reset\(handle\)/ { pre=NR }
  /woal_post_reset\(handle\)/ { post=NR }
  /moal_bridge_resume_owner\(\)/ { resume=NR }
  /wifi_status = WIFI_STATUS_OK/ { ok=NR }
  /MOAL_REL_SEMAPHORE\(&AddRemoveCardSem\)/ { unlock=NR }
  END { exit !(mode_check && lock && suspend && pre && post && resume && ok &&
               unlock && mode_check < lock && lock < suspend && suspend < pre &&
               pre < post && post < resume && resume < ok && ok < unlock) }
' || fail "runtime-switch: generic reload is not a complete serialized transaction"
printf '%s\n' "$REQUEST_RELOAD_BLOCK" | awk '
  /MOAL_ACQ_SEMAPHORE_BLOCK\(&AddRemoveCardSem\)/ { lock=NR }
  /m_handle\[index\] == phandle/ { member=NR }
  /handle = \(moal_handle \*\)phandle->pref_mac/ { companion=NR }
  /moal_bridge_suspend_owner\(\)/ { suspend=NR }
  /destructive_started = true/ { destructive=NR }
  END { exit !(lock && member && suspend && destructive &&
               lock < member && member < suspend && suspend < destructive &&
               (!companion || lock < companion)) }
' || fail "runtime-switch: reload handle/pair is not validated under card lock"
printf '%s\n' "$REQUEST_RELOAD_BLOCK" | grep -Fq 'WIFI_STATUS_FW_RECOVERY_FAIL' || \
  fail "runtime-switch: reload failure status missing"
printf '%s\n' "$POST_RESET_BLOCK" | grep -Fq 'return ret;' || \
  fail "runtime-switch: post-reset status not propagated"
printf '%s\n' "$POST_RESET_BLOCK" | grep -Eq 'MOAL_ACQ_SEMAPHORE|down\(&AddRemoveCardSem\)|MOAL_REL_SEMAPHORE' && \
  fail "runtime-switch: post-reset recursively owns card semaphore"
printf '%s\n' "$MAIN_WORK_BLOCK" | grep -Eq 'fw_reload|fw_reseting' && \
  fail "runtime-switch: unsafe blanket main_work reset guard added"
printf '%s\n' "$MAIN_WORK_BLOCK" | grep -Fq 'handle->surprise_removed == MTRUE' || \
  fail "runtime-switch: main_work removal guard missing"
check_fw_sem_ownership "$FW_DPC_BLOCK" "$INIT_FW_BLOCK" || \
  fail "runtime-switch: synchronous firmware-init semaphore ownership ambiguous"
for flr in "$PCIE_FLR_BLOCK" "$SDIO_FLR_BLOCK"; do
  printf '%s\n' "$flr" | grep -Fq 'down(&AddRemoveCardSem)' || \
    fail "runtime-switch: destructive FLR lock is interruptible/missing"
  printf '%s\n' "$flr" | grep -Fq 'status = MLAN_STATUS_FAILURE' || \
    fail "runtime-switch: FLR failure propagation missing"
done
printf '%s\n' "$DRV_MODE_BLOCK" | grep -Fq 'mlan_status status = MLAN_STATUS_FAILURE' || \
  fail "runtime-switch: driver-mode defaults to false success"
printf '%s\n' "$DRV_MODE_BLOCK" | grep -c 'status = MLAN_STATUS_FAILURE' |
  awk '$1 >= 3 { ok=1 } END { exit !ok }' ||
  fail "runtime-switch: driver-mode init failures can return stale success"
printf '%s\n' "$DRV_MODE_BLOCK" | grep -Fq 'moal_bridge_suspend_owner_for(handle)' || \
  fail "runtime-switch: driver-mode does not snapshot only its effective owner"
for outer in "$PCIE_DONE_BLOCK" "$PCIE_NOTIFY_BLOCK" "$PCIE_WORK_BLOCK" "$SDIO_WORK_BLOCK"; do
  printf '%s\n' "$outer" | grep -Fq 'WIFI_STATUS_FW_RECOVERY_FAIL' || \
    fail "runtime-switch: reset outer path lacks recovery-failure terminal state"
	printf '%s\n' "$outer" | grep -Fq 'moal_bridge_resume_owner()' || \
    fail "runtime-switch: reset outer path does not restore owner after participants"
	printf '%s\n' "$outer" | awk '
	  /down\(&AddRemoveCardSem\)/ { lock=NR }
	  /moal_bridge_resume_owner\(\)/ { resume=NR }
	  /MOAL_REL_SEMAPHORE\(&AddRemoveCardSem\)/ { unlock=NR }
	  END { exit !(lock && resume && unlock && lock < resume && resume < unlock) }
	' || fail "runtime-switch: reset outer path does not pin pair lifetime"
done
printf '%s\n' "$PCIE_PREP_BLOCK" | grep -Fq 'fw_reset_prepare_failed' || \
  fail "runtime-switch: void PCIe prepare failure is not carried to post"
printf '%s\n' "$PCIE_WORK_BLOCK" | grep -Fq 'card->work_flags = MFALSE' || \
  fail "runtime-switch: PCIe reset work flag not cleared on terminal path"
printf '%s\n' "$SDIO_WORK_BLOCK" | grep -Fq 'card->work_flags = MFALSE' || \
  fail "runtime-switch: SDIO reset work flag not cleared on terminal path"
printf '%s\n' "$SDIO_REMOVE_BLOCK" | awk '
  /cancel_work_sync\(&card->reset_work\)/ { cancel=NR }
  /woal_remove_card\(card\)/ { remove=NR }
  /kfree\(card\)/ { free=NR }
  END { exit !(cancel && remove && free && cancel < remove && remove < free) }
' || fail "runtime-switch: SDIO reset work can outlive card removal"

DPC_NO_OWNER_GUARD="$(printf '%s\n' "$FW_DPC_BLOCK" |
  sed 's/if (!READ_ONCE(handle->fw_init_card_sem_owned))/if (1)/')"
if check_fw_sem_ownership "$DPC_NO_OWNER_GUARD" "$INIT_FW_BLOCK"; then
  fail "runtime-switch: firmware DPC double-release mutation accepted"
fi
printf 'PASS: runtime-switch firmware semaphore mutation rejected\n'
CLEANUP_LATE_DEINIT="$(printf '%s\n' "$CLEANUP_MODULE_BLOCK" | awk '
  /moal_bridge_deinit\(handle\)/ && !saved { saved=$0; next }
  /woal_shutdown_fw/ && saved && !moved { print; print saved; moved=1; next }
  { print }
  END { exit !moved }
')"
if check_cleanup_transaction "$CLEANUP_LATE_DEINIT"; then
  fail "runtime-switch: unload shutdown-before-deinit mutation accepted"
fi
printf 'PASS: runtime-switch unload ordering mutation rejected\n'

# C/D: exact identity is pinned before teardown; target and rollback are each
# terminally revalidated before an owner/counter can be published.
for token in 'surprise_removed' 'fw_reseting' 'fw_reload' 'driver_status' \
             'HardwareStatusReady' 'NETREG_REGISTERED' \
             'netif_device_present' 'moal_bridge_dev_ready' \
             'media_connected' 'peer_released'; do
  printf '%s\n' "$VALIDATE_BLOCK" | grep -Fq "$token" || \
    fail "runtime-switch: terminal validator missing $token"
done
check_terminal_switch_contract "$SWITCH_BLOCK" || \
  fail "runtime-switch: target validation/deinit/rollback/success order invalid"
check_peer_identity_contract "$SWITCH_BLOCK" "$BRIDGE_INIT_BLOCK" || \
  fail "runtime-switch: peer identity/ref lifetime contract missing"
printf '%s\n' "$SWITCH_BLOCK" | awk '
  /!atomic_read\(&br->active\)/ { active=NR }
  /!netif_device_present\(br->peer_dev\)/ { present=NR }
  /!moal_bridge_dev_ready\(br->peer_dev\)/ { ready=NR }
  /dev_hold\(old.peer_dev\)/ { hold=NR }
  /__moal_bridge_deinit_locked\(old.old_owner\)/ && !deinit { deinit=NR }
  END { exit !(active && present && ready && hold && deinit &&
               active < hold && present < hold && ready < hold && hold < deinit) }
' || fail "runtime-switch: unhealthy old peer can reach destructive switch"
check_name_sync_contract "$NETDEV_EVENT_BLOCK" "$BRIDGE_INIT_BLOCK" \
  "$GETTER_BLOCK" "$STATS_SHOW_BLOCK" || \
  fail "runtime-switch: rename-safe synchronized display names missing"
check_init_readiness_publication_contract "$BRIDGE_INIT_BLOCK" ||
  fail "runtime-switch: final readiness/publication ordering invalid"
printf '%s\n' "$BRIDGE_INIT_BLOCK" | awk '
	/ret = register_netdevice_notifier/ { notifier=NR }
  /atomic_read\(&br->peer_released\)/ && notifier && !released { released=NR }
  /br->peer_dev->reg_state != NETREG_REGISTERED/ { peer_reg=NR }
  /br->wlan_dev->reg_state != NETREG_REGISTERED/ { wlan_reg=NR }
  /rcu_assign_pointer\(handle->bridge, br\)/ { publish=NR }
	/atomic_set\(&br->active, netif_running\(br->peer_dev\) \? 1 : 0\)/ { active=NR }
	/rtnl_unlock\(\)/ && active && !unlock { unlock=NR }
  /^err_netdev_notifier:/ { unwind=NR }
  END { exit !(notifier && released && peer_reg && wlan_reg && publish && active &&
               unlock && unwind && notifier < released && released < publish &&
               publish < active && active < unlock && unlock < unwind) }
' || fail "runtime-switch: init can publish after peer/WLAN unregister"
printf '%s\n' "$SWITCH_BLOCK" | grep -Eq 'params\.bridge_(mode|peer|wlan_idx|keepalive)' && \
  fail "runtime-switch: effective switch mutates configured bridge policy"
printf '%s\n' "$LIFECYCLE_DEINIT_BLOCK" | grep -Fq 'bridge_effective_wlan_idx = -1' || \
  fail "runtime-switch: effective BSS is not cleared on deinit"
printf '%s\n' "$SUSPEND_OWNER_BLOCK" | grep -Fq 'dev_hold(bridge_suspended_owner.peer_dev)' || \
  fail "runtime-switch: reset snapshot does not pin exact peer identity"
printf '%s\n' "$REMOVE_CARD_BLOCK" | awk '
  /moal_bridge_forget_handle\(handle\)/ { forget=NR }
  /woal_remove_interface\(handle,/ && !remove { remove=NR }
  /woal_free_moal_handle\(handle\)/ { free=NR }
  END { exit !(forget && remove && free && forget < remove && remove < free) }
' || fail "runtime-switch: remove does not invalidate effective/suspended owner before free"
printf '%s\n' "$REMOVE_CARD_BLOCK" | grep -Fq 'bridge_runtime_switch' && \
  fail "runtime-switch: destruction safety was incorrectly gated off"
grep -Fq 'bridge_runtime_switch' "$SHIM_C" && \
  fail "runtime-switch: opt-in gate leaked into normal forwarding"

SWITCH_NO_VALIDATE="$(printf '%s\n' "$SWITCH_BLOCK" |
  sed '0,/ret = moal_bridge_validate_binding_locked/s//ret = 0 \/\* missing terminal validation \*\//')"
if check_terminal_switch_contract "$SWITCH_NO_VALIDATE"; then
  fail "runtime-switch: missing terminal validation mutation accepted"
fi
printf 'PASS: runtime-switch terminal validation mutation rejected\n'
SWITCH_NO_TARGET_DEINIT="$(printf '%s\n' "$SWITCH_BLOCK" |
  sed 's/__moal_bridge_deinit_locked(target.handle);/\/\* missing target deinit \*\//')"
if check_terminal_switch_contract "$SWITCH_NO_TARGET_DEINIT"; then
  fail "runtime-switch: validation-failure target-deinit mutation accepted"
fi
printf 'PASS: runtime-switch validation-failure deinit mutation rejected\n'
ROLLBACK_OWNER_EARLY="$(printf '%s\n' "$SWITCH_BLOCK" | awk '
  /rollback_ret = moal_bridge_validate_binding_locked/ && !moved {
    print "		bridge_owner = old.old_owner; /* invalid early publication */"
    moved=1
  }
  /bridge_owner = old.old_owner/ && moved { next }
  { print }
  END { exit !moved }
')"
if check_terminal_switch_contract "$ROLLBACK_OWNER_EARLY"; then
  fail "runtime-switch: rollback owner-before-validation mutation accepted"
fi
printf 'PASS: runtime-switch rollback owner ordering mutation rejected\n'
ROLLBACK_NO_RTNL="$(printf '%s\n' "$SWITCH_BLOCK" | awk '
  /rtnl_lock\(\)/ { locks++; if (locks == 3) next }
  /rtnl_unlock\(\)/ { unlocks++; if (unlocks == 3) next }
  { print }
')"
if check_terminal_switch_contract "$ROLLBACK_NO_RTNL"; then
  fail "runtime-switch: rollback RTNL bracket removal mutation accepted"
fi
printf 'PASS: runtime-switch rollback RTNL mutation rejected\n'
SWITCH_LATE_HOLD="$(printf '%s\n' "$SWITCH_BLOCK" | awk '
  /dev_hold\(old.peer_dev\)/ { saved=$0; next }
  /__moal_bridge_deinit_locked\(old.old_owner\)/ && saved && !moved {
    print
    print saved
    moved=1
    next
  }
  { print }
  END { exit !moved }
')"
if check_peer_identity_contract "$SWITCH_LATE_HOLD" "$BRIDGE_INIT_BLOCK"; then
  fail "runtime-switch: peer pin-after-teardown mutation accepted"
fi
printf 'PASS: runtime-switch peer identity ordering mutation rejected\n'
INIT_PUBLISH_BEFORE_READY="$(printf '%s\n' "$BRIDGE_INIT_BLOCK" | awk '
  /rcu_assign_pointer\(handle->bridge, br\)/ && !saved { saved=$0; next }
  /atomic_set\(&br->active, netif_running\(br->peer_dev\) \? 1 : 0\)/ && saved && !moved {
    print
    print saved
    moved=1
    next
  }
  { print }
  END { exit !moved }
')"
if check_init_readiness_publication_contract "$INIT_PUBLISH_BEFORE_READY"; then
  fail "runtime-switch: readiness-before-publication mutation accepted"
fi
printf 'PASS: runtime-switch readiness-before-publication mutation rejected\n'
SWITCH_NO_PEER_PUT="$(printf '%s\n' "$SWITCH_BLOCK" | sed 's/dev_put(old.peer_dev);/\/\* missing peer ref unwind \*\//')"
if check_peer_identity_contract "$SWITCH_NO_PEER_PUT" "$BRIDGE_INIT_BLOCK"; then
  fail "runtime-switch: peer ref-unwind mutation accepted"
fi
printf 'PASS: runtime-switch peer ref-unwind mutation rejected\n'
INIT_NAMES_BEFORE_NOTIFIER="$(printf '%s\n' "$BRIDGE_INIT_BLOCK" | awk '
	/ret = register_netdevice_notifier/ && !saved { saved=$0; next }
  /strncpy\(br->peer_name, br->peer_dev->name/ && saved && !moved {
    print saved
    print
    moved=1
    next
  }
  { print }
  END { exit !moved }
')"
if check_name_sync_contract "$NETDEV_EVENT_BLOCK" "$INIT_NAMES_BEFORE_NOTIFIER" \
    "$GETTER_BLOCK" "$STATS_SHOW_BLOCK"; then
  fail "runtime-switch: rename missed-window mutation accepted"
fi
printf 'PASS: runtime-switch rename-window mutation rejected\n'

# G: inactive counters persist for module life; QA covers every target-only
# matrix entry and its EXIT path captures failure evidence before safe restore.
printf '%s\n' "$STATS_SHOW_BLOCK" | grep -Fq 'bridge: inactive' || \
  fail "runtime-switch: inactive stats state missing"
printf '%s\n' "$STATS_SHOW_BLOCK" | grep -Fq 'iface=none peer=none' || \
  fail "runtime-switch: inactive identity stats missing"
for counter in bridge_switch_ok bridge_switch_fail bridge_rollback_ok bridge_rollback_fail; do
  printf '%s\n' "$STATS_SHOW_BLOCK" | grep -Fq "atomic_long_read(&$counter)" || \
    fail "runtime-switch: stats does not read $counter while module lives"
  grep -Fq "atomic_long_set(&$counter" "$BRIDGE_C" && \
    fail "runtime-switch: persistent counter $counter is reset"
done
printf '%s\n' "$SYSFS_DEINIT_BLOCK" | awk '
  /rcu_assign_pointer\(moal_bridge_for_sysfs, NULL\)/ { clear=NR }
  /synchronize_rcu\(\)/ { drain=NR }
  END { exit !(clear && drain && clear < drain) }
' || fail "runtime-switch: inactive stats RCU pointer is not drained"
printf '%s\n' "$SYSFS_DEINIT_BLOCK" | grep -Fq 'sysfs_remove_file' && \
  fail "runtime-switch: per-instance deinit removes module-lifetime stats"
printf '%s\n' "$STATS_CLEANUP_BLOCK" | grep -Fq 'sysfs_remove_file' || \
  fail "runtime-switch: module cleanup does not remove stats"
printf '%s\n' "$STATS_SHOW_BLOCK" | awk '
  /rcu_read_lock\(\)/ { lock=NR }
  /rcu_dereference\(moal_bridge_for_sysfs\)/ { deref=NR }
  /rcu_read_unlock\(\)/ { unlock=NR }
  END { exit !(lock && deref && unlock && lock < deref && deref < unlock) }
' || fail "runtime-switch: stats bridge/handle RCU lifetime missing"
check_qa_cleanup_contract "$QA_CLEANUP_BLOCK" || \
  fail "runtime-switch: QA cleanup status/evidence/restore ordering invalid"
for qa_case in stress same-target concurrent peer-cycle gate-off no-active malformed \
               reject target-down target-disconnected fault-target fault-double \
               reset-interaction unload-interaction; do
  grep -Fq "$qa_case" "$QA_SCRIPT" || \
    fail "runtime-switch: QA case $qa_case missing"
done
grep -Fq 'dmesg --follow-new' "$QA_SCRIPT" || \
  fail "runtime-switch: QA does not stream kernel logs"
grep -Fq 'write_expect_errno' "$QA_SCRIPT" || \
  fail "runtime-switch: QA negative cases do not assert write errno"
test -x "$QA_SCRIPT" || fail "runtime-switch: QA script is not executable"
grep -q '^CONFIG_BRIDGE_SWITCH_FAULT_INJECT=n' "$ROOT/Makefile" || \
  fail "runtime-switch: production fault injection default is not off"
grep -q '^ifeq ($(CONFIG_BRIDGE_SWITCH_FAULT_INJECT),y)' "$ROOT/Makefile" || \
  fail "runtime-switch: fault macro is not confined to explicit QA build"
grep -Fq '#ifdef BRIDGE_SWITCH_FAULT_INJECT' "$INIT_C" || \
  fail "runtime-switch: fault parameter is compiled into production"
printf '%s\n' "$SWITCH_BLOCK" | grep -Fq '#ifdef BRIDGE_SWITCH_FAULT_INJECT' || \
  fail "runtime-switch: fault behavior is compiled into production"
grep -q 'module_param(bridge_switch_fault_mask, int, 0600)' "$INIT_C" || \
  fail "runtime-switch: QA fault mask is not root-only"
printf '%s\n' "$SWITCH_BLOCK" | awk '
  /target\.dev == bridge_owner->bridge->wlan_dev/ { same=NR }
  /fault_mask = xchg\(&bridge_switch_fault_mask, 0\)/ { consume=NR }
  /__moal_bridge_deinit_locked\(old.old_owner\)/ && !deinit { deinit=NR }
  END { exit !(same && consume && deinit && same < consume && consume < deinit) }
' || fail "runtime-switch: fault mask is not one-shot at destructive boundary"
for errno in EOPNOTSUPP ENODEV EINVAL ENETDOWN ENOLINK EBUSY EAGAIN ESHUTDOWN EINTR EIO; do
  grep -Fq "\`$errno\`" "$PARAM_DOC" || \
    fail "runtime-switch: parameter docs missing $errno"
done
for evidence in 'QA_CASE=gate-off' 'QA_CASE=no-active' 'QA_CASE=malformed' \
                'QA_CASE=concurrent' 'QA_CASE=peer-cycle' \
                'QA_CASE=fault-target' 'QA_CASE=fault-double' \
                'QA_CASE=reset-interaction' 'QA_CASE=unload-interaction'; do
  grep -Fq "$evidence" "$QA_RUNBOOK" || \
    fail "runtime-switch: runbook matrix missing $evidence"
done

QA_RESTORE_BEFORE_CAPTURE="$(printf '%s\n' "$QA_CLEANUP_BLOCK" | awk '
  /capture_state "final-before-restore"/ { saved=$0; next }
  /> "\$IFACE_PARAM"/ && saved && !moved { print; print saved; moved=1; next }
  { print }
  END { exit !moved }
')"
if check_qa_cleanup_contract "$QA_RESTORE_BEFORE_CAPTURE"; then
  fail "runtime-switch: QA restore-before-evidence mutation accepted"
fi
printf 'PASS: runtime-switch QA evidence ordering mutation rejected\n'

# Existing strict parser and shared-release contracts remain in force.
check_bridge_iface_set_contract "$SETTER_BLOCK" || \
  fail "runtime-switch: strict parser/synchronous setter contract missing"
check_no_direct_return_while_locked "$SWITCH_BLOCK" || \
  fail "runtime-switch: direct return bypasses lifecycle release"
printf '%s\n' "$SWITCH_BLOCK" | awk '
  /MOAL_ACQ_SEMAPHORE_BLOCK/ { card_lock=NR }
  /mutex_lock\(&bridge_lifecycle_lock\)/ { lifecycle_lock=NR }
  /mutex_unlock\(&bridge_lifecycle_lock\)/ { lifecycle_unlock=NR }
  /MOAL_REL_SEMAPHORE/ { card_unlock=NR }
  END { exit !(card_lock && lifecycle_lock && lifecycle_unlock && card_unlock &&
               card_lock < lifecycle_lock && lifecycle_lock < lifecycle_unlock &&
               lifecycle_unlock < card_unlock) }
' || fail "runtime-switch: card/lifecycle release order invalid"

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

UNREG_BLOCK="$(grep -n -A55 -m1 'case NETDEV_UNREGISTER:' "$BRIDGE_C")"
printf '%s\n' "$UNREG_BLOCK" | \
  grep -Eq 'netdev_rx_handler_unregister\(br->peer_dev\)|dev_remove_pack\(&br->peer_pt\)' || \
  fail "NETDEV_UNREGISTER branch must unregister handler"
printf '%s\n' "$UNREG_BLOCK" | grep -q 'dev_set_promiscuity(br->peer_dev, -1)' || \
  fail "NETDEV_UNREGISTER branch must drop promisc"
printf '%s\n' "$UNREG_BLOCK" | grep -q 'dev_put(br->peer_dev)' || \
  fail "NETDEV_UNREGISTER branch must dev_put peer"
printf '%s\n' "$UNREG_BLOCK" | grep -q 'atomic_set(&br->peer_released, 1)' || \
  fail "NETDEV_UNREGISTER branch must atomic_set peer_released = 1 (F1)"
printf '%s\n' "$UNREG_BLOCK" | awk '
  /atomic_set\(&br->peer_released, 1\)/ { released=NR }
  /synchronize_net\(\)/ { drain=NR }
  /kthread_stop\(br->w2p_thread\)/ { w2p=NR }
  /kthread_stop\(br->p2w_thread\)/ { p2w=NR }
  /dev_put\(br->peer_dev\)/ { put=NR }
  END { exit !(released && drain && w2p && p2w && put &&
               released < drain && drain < w2p && w2p < p2w && p2w < put) }
' || fail "NETDEV_UNREGISTER must drain workers before peer ref release"

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

# --- v2 B4: NETDEV_DOWN drains with per-SKB qlen accounting ---
DOWN_BLOCK="$(grep -n -A24 -m1 'case NETDEV_DOWN:' "$BRIDGE_C")"
printf '%s\n' "$DOWN_BLOCK" | grep -q 'skb_dequeue(&br->w2p_queue)' || \
  fail "NETDEV_DOWN must drain w2p_queue"
printf '%s\n' "$DOWN_BLOCK" | grep -q 'skb_dequeue(&br->p2w_queue)' || \
  fail "NETDEV_DOWN must drain p2w_queue"
printf '%s\n' "$DOWN_BLOCK" | grep -q 'atomic_dec(&br->w2p_qlen)' || \
  fail "NETDEV_DOWN must account w2p drain"
printf '%s\n' "$DOWN_BLOCK" | grep -q 'atomic_dec(&br->p2w_qlen)' || \
  fail "NETDEV_DOWN must account p2w drain"
printf '%s\n' "$DOWN_BLOCK" | grep -q 'atomic_set(&br->.*_qlen, 0)' && \
  fail "NETDEV_DOWN must not race queue accounting with blind reset"

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
# The target checker deliberately checks admin/running before association and
# carrier after association so its errno precedence is ENETDOWN (device down)
# before ENOLINK (admin-UP but unassociated). Assert the concrete source
# predicates, not an obsolete broad-helper token.
for token in 'm_handle\[' MLAN_BSS_TYPE_STA NETREG_REGISTERED \
             netif_device_present netif_running media_connected netif_carrier_ok \
             HardwareStatusReady fw_reseting surprise_removed; do
  printf '%s\n' "$TARGET_BLOCK" | grep -q "$token" || \
    fail "runtime-switch: target validator missing $token"
done

printf 'PASS: keepalive, bounded queues, worker accounting, F1 RCU drain ordering + atomic peer_released + hairpin smoke enforced\n'
