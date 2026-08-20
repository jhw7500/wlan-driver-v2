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
DEFERRED_SPEC="$ROOT/docs/superpowers/specs/2026-08-14-runtime-bridge-deferred-switch-design.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

extract_c_function() {
  extract_c_block "$(cat "$2")" "$1"
}

extract_switch_block() {
  extract_c_function '^static int moal_bridge_switch_iface_request' "$1" ||
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

check_pending_storage_contract() {
  local pending="$1"

  printf '%s\n' "$pending" | awk '
    /struct moal_bridge_pending_request/ { decl=NR }
    decl && NR > decl && /;/ && $0 !~ /^[[:space:]]*};/ { total_fields++ }
    /char ifname\[IFNAMSIZ\]/ { ifname=NR; fields++ }
    /unsigned long generation/ { generation=NR; fields++ }
    /enum moal_bridge_pending_state state/ { state=NR; fields++ }
    /moal_handle[[:space:]]*\*|moal_private[[:space:]]*\*|struct net_device[[:space:]]*\*/ {
      pointer=NR
    }
    END { exit !(decl && ifname && generation && state && fields == 3 &&
                 total_fields == 3 &&
                 !pointer && decl < ifname && ifname < generation &&
                 generation < state) }
  '
}

check_pending_notifier_contract() {
  local notifier="$1" scheduler="$2" module_callback="$3"

  printf '%s\n' "$notifier" | awk '
    /event == NETDEV_UP/ && !up { up=NR }
    /event == NETDEV_CHANGE/ && !change { change=NR }
    /moal_bridge_pending_schedule_event\(event, dev,/ { schedule=NR }
    /dev != br->peer_dev && dev != br->wlan_dev/ { filter=NR }
    /moal_bridge_switch_iface|__moal_bridge_init_locked|__moal_bridge_deinit_locked|mutex_lock|rtnl_lock|down\(&AddRemoveCardSem\)/ {
      direct=NR
    }
    END { exit !(up && change && schedule && filter &&
                 !direct && up <= schedule && change <= schedule &&
                 schedule < filter) }
  ' || return 1

  printf '%s\n' "$module_callback" | awk '
    /event == NETDEV_CHANGENAME/ && !rename { rename=NR }
    /event == NETDEV_UNREGISTER/ && !unregister { unregister=NR }
    /moal_bridge_pending_schedule_event\(event, dev,/ { schedule=NR }
    /moal_bridge_switch_iface|__moal_bridge_init_locked|__moal_bridge_deinit_locked|mutex_lock|rtnl_lock|down\(&AddRemoveCardSem\)/ {
      direct=NR
    }
    END { exit !(rename && unregister && schedule && !direct &&
                 rename <= schedule && unregister <= schedule) }
  ' || return 1

  printf '%s\n' "$scheduler" | awk '
    /spin_lock_irqsave\(&bridge_pending_lock/ { lock=NR }
    /bridge_pending_events_enabled/ && lock { admission=NR }
    /READ_ONCE\(bridge_runtime_deferred\)/ { deferred=NR }
    /bridge_pending.state == MOAL_BR_PENDING_WAITING/ { pending=NR }
    /schedule_work\(&bridge_pending_work\)/ { schedule=NR }
    /spin_unlock_irqrestore\(&bridge_pending_lock/ { unlock=NR }
    END { exit !(lock && admission && deferred && pending && schedule && unlock &&
                 lock < admission && admission <= deferred && deferred <= pending &&
                 pending < schedule && schedule < unlock) }
  '
}

check_pending_worker_contract() {
  local worker="$1" request="$2"

  printf '%s\n' "$worker" | awk '
    /moal_bridge_pending_snapshot\(ifname/ { snapshot=NR }
    /moal_bridge_switch_iface_request\(ifname, false, generation\)/ { request=NR }
    END { exit !(snapshot && request && snapshot < request) }
  ' || return 1

  printf '%s\n' "$request" | awk '
    /MOAL_ACQ_SEMAPHORE_BLOCK\(&AddRemoveCardSem\)/ { card=NR }
    /READ_ONCE\(bridge_runtime_control_ready\)/ {
      ready_count++
      if (ready_count == 2) ready=NR
    }
    /mutex_lock\(&bridge_lifecycle_lock\)/ { lifecycle=NR }
    /moal_bridge_find_target\(ifname, &target\)/ { resolve=NR }
    END { exit !(card && ready && lifecycle && resolve &&
                 card < ready && ready < lifecycle && lifecycle < resolve) }
  '
}

check_pending_generation_clear_contract() {
  local worker="$1" clear="$2"

  printf '%s\n' "$worker" |
    grep -Fq 'moal_bridge_pending_clear_if(ifname, generation)' || return 1
  printf '%s\n' "$clear" | awk '
    /spin_lock_irqsave\(&bridge_pending_lock/ { lock=NR }
    /strcmp\(bridge_pending.ifname, ifname\)/ { ifname=NR }
    /bridge_pending.generation == generation/ { generation=NR }
    /bridge_pending.state = MOAL_BR_PENDING_NONE/ { clear=NR }
    /bridge_pending.generation\+\+/ { advance=NR }
    /spin_unlock_irqrestore\(&bridge_pending_lock/ { unlock=NR }
    END { exit !(lock && ifname && generation && clear && advance && unlock &&
                 lock < ifname && ifname <= generation && generation < clear &&
                 clear <= advance && advance < unlock) }
  '
}

check_pending_admission_cleanup_contract() {
  local init="$1" cleanup_module="$2" start="$3" cleanup="$4"

  printf '%s\n' "$init" | awk '
    /moal_bridge_pending_start\(\)/ { start=NR }
    /WRITE_ONCE\(bridge_runtime_control_ready, 1\)/ { ready=NR }
    END { exit !(start && ready && start < ready) }
  ' || return 1
  printf '%s\n' "$cleanup_module" | awk '
    /WRITE_ONCE\(bridge_runtime_control_ready, 0\)/ { ready=NR }
    /moal_bridge_pending_cleanup\(\)/ { cleanup=NR }
    /down\(&AddRemoveCardSem\)/ { card=NR }
    END { exit !(ready && cleanup && card && ready < cleanup && cleanup < card) }
  ' || return 1
  printf '%s\n' "$start" | awk '
    /spin_lock_irqsave\(&bridge_pending_lock/ { lock=NR }
    /bridge_pending_events_enabled = true/ { enable=NR }
    /spin_unlock_irqrestore\(&bridge_pending_lock/ { unlock=NR }
    END { exit !(lock && enable && unlock && lock < enable && enable < unlock) }
  ' || return 1
  printf '%s\n' "$cleanup" | awk '
    /spin_lock_irqsave\(&bridge_pending_lock/ { lock=NR }
    /bridge_pending_events_enabled = false/ { disable=NR }
    /bridge_pending.state = MOAL_BR_PENDING_NONE/ { clear=NR }
    /bridge_pending.generation\+\+/ { advance=NR }
    /spin_unlock_irqrestore\(&bridge_pending_lock/ { unlock=NR }
    /cancel_work_sync\(&bridge_pending_work\)/ { cancel=NR }
    END { exit !(lock && disable && clear && advance && unlock && cancel &&
                 lock < disable && disable <= clear && clear <= advance &&
                 advance < unlock && unlock < cancel) }
  '
}

check_bridge_getter_separation_contract() {
  local active="$1" pending="$2"

  printf '%s\n' "$active" |
    grep -Fq 'return moal_bridge_get_iface(buf, PAGE_SIZE);' || return 1
  if printf '%s\n' "$active" | grep -Fq 'moal_bridge_get_pending_iface'; then
    return 1
  fi
  printf '%s\n' "$pending" |
    grep -Fq 'return moal_bridge_get_pending_iface(buf, PAGE_SIZE);' || return 1
  if printf '%s\n' "$pending" | grep -Fq 'moal_bridge_get_iface(buf, PAGE_SIZE)'; then
    return 1
  fi
  return 0
}

check_pending_admission_kick_contract() {
  local setter="$1"

  printf '%s\n' "$setter" | awk '
    /spin_lock_irqsave\(&bridge_pending_lock/ { lock=NR }
    /bridge_pending.state = MOAL_BR_PENDING_WAITING/ { waiting=NR }
    /bridge_pending_event_during_switch = false/ { reset=NR }
    /schedule_work\(&bridge_pending_work\)/ { kick=NR }
    /spin_unlock_irqrestore\(&bridge_pending_lock/ { unlock=NR }
    END { exit !(lock && waiting && reset && kick && unlock &&
                 lock < waiting && waiting <= reset && reset < kick &&
                 kick < unlock) }
  '
}

check_pending_switch_event_contract() {
  local begin="$1" scheduler="$2" restore="$3" init="$4" notifier="$5" flat

  printf '%s\n' "$begin" | awk '
    /spin_lock_irqsave\(&bridge_pending_lock/ { lock=NR }
    /bridge_pending.state == MOAL_BR_PENDING_WAITING/ { waiting=NR }
    /bridge_pending.state = MOAL_BR_PENDING_SWITCHING/ { switching=NR }
    /bridge_pending_event_during_switch = false/ { reset=NR }
    /spin_unlock_irqrestore\(&bridge_pending_lock/ { unlock=NR }
    END { exit !(lock && waiting && switching && reset && unlock &&
                 lock < waiting && waiting < switching && switching <= reset &&
                 reset < unlock) }
  ' || return 1
  printf '%s\n' "$scheduler" | awk '
    /!notifier_published/ { replay=NR }
    /bridge_pending.state == MOAL_BR_PENDING_SWITCHING/ { switching=NR }
    /bridge_pending_event_during_switch = true/ { remember=NR }
    END { exit !(replay && switching && remember && replay < switching &&
                 switching < remember) }
  ' || return 1
  printf '%s\n' "$restore" | awk '
    /spin_lock_irqsave\(&bridge_pending_lock/ { lock=NR }
    /bridge_pending.state == MOAL_BR_PENDING_SWITCHING/ { switching=NR }
    /bridge_pending.state = MOAL_BR_PENDING_WAITING/ { waiting=NR }
    /bridge_pending_event_during_switch/ && !dirty { dirty=NR }
    /schedule_work\(&bridge_pending_work\)/ { kick=NR }
    /bridge_pending_event_during_switch = false/ { clear=NR }
    /spin_unlock_irqrestore\(&bridge_pending_lock/ { unlock=NR }
    END { exit !(lock && switching && waiting && dirty && kick && clear && unlock &&
                 lock < switching && switching < waiting && waiting <= dirty &&
                 dirty < kick && kick <= clear && clear < unlock) }
  ' || return 1
  printf '%s\n' "$init" | awk '
    /ret = register_netdevice_notifier/ { notifier=NR }
    /atomic_set\(&br->published, 1\)/ { published=NR }
    END { exit !(notifier && published && notifier < published) }
  ' || return 1
  flat="$(printf '%s\n' "$notifier" | tr '\n' ' ' |
    sed 's/[[:space:]][[:space:]]*/ /g')"
  grep -Fq \
    'moal_bridge_pending_schedule_event(event, dev, atomic_read(&br->published))' \
    <<< "$flat"
}

check_same_target_compat_contract() {
  local request="$1" flat

  printf '%s\n' "$request" | awk '
    /bool same_target = false/ { decl=NR }
    /same_target = !strcmp\(br->wlan_dev->name, ifname\)/ { sample=NR }
    /same_target && !expected_generation/ { cancel_guard=NR }
    /pending_state != MOAL_BR_PENDING_NONE/ && cancel_guard && !pending { pending=NR }
    /moal_bridge_pending_clear_if\(pending_ifname/ && cancel_guard && !clear { clear=NR }
    /ret = moal_bridge_find_target\(ifname, &target\)/ { resolve=NR }
    /target.handle != bridge_owner/ { identity=NR }
    /dev_hold\(old.peer_dev\)/ { peer=NR }
    /ret = moal_bridge_target_link_status\(&target\)/ { readiness=NR }
    /if \(same_target\)/ && readiness { late_noop=NR }
    END { exit !(decl && sample && cancel_guard && pending && clear && resolve &&
                 identity && peer && readiness && late_noop && decl < sample &&
                 sample <= cancel_guard && cancel_guard <= pending &&
                 pending <= clear && clear < resolve && resolve < identity &&
                 identity < peer && peer <= readiness && readiness < late_noop) }
  ' || return 1
  flat="$(printf '%s\n' "$request" | tr '\n' ' ' |
    sed 's/[[:space:]][[:space:]]*/ /g')"
  grep -Fq     'if ((ret == -ENETDOWN || ret == -ENOLINK) && !same_target && allow_defer'     <<< "$flat"
}

check_pending_identity_invalidation_contract() {
  local notifier="$1" scheduler="$2" request="$3" flat

  printf '%s\n' "$notifier" | awk '
    /moal_bridge_pending_schedule_event\(event, dev,/ { schedule=NR }
    /dev != br->peer_dev && dev != br->wlan_dev/ { filter=NR }
    END { exit !(schedule && filter && schedule < filter) }
  ' || return 1
  printf '%s\n' "$scheduler" | awk '
    /!dev \|\| dev_net\(dev\) != &init_net/ { netns=NR }
    /event == NETDEV_CHANGENAME \|\| event == NETDEV_UNREGISTER/ { events=NR }
    /spin_lock_irqsave\(&bridge_pending_lock/ && !lock { lock=NR }
    /strncpy\(cancelled_ifname, bridge_pending.ifname/ { name=NR }
    /cancelled_generation = bridge_pending.generation/ { generation=NR }
    /pending_state = bridge_pending.state/ { state=NR }
    /spin_unlock_irqrestore\(&bridge_pending_lock/ && state && !snapshot_unlock {
      snapshot_unlock=NR
    }
    /event == NETDEV_UNREGISTER &&/ { unregister=NR }
    /strcmp\(cancelled_ifname, dev->name\)/ { identity=NR }
    /__dev_get_by_name\(&init_net, cancelled_ifname\)/ { lookup=NR }
    /moal_bridge_pending_clear_if\(cancelled_ifname/ { clear=NR }
    END { exit !(netns && events && lock && name && generation && state &&
                 snapshot_unlock && unregister && identity && lookup && clear &&
                 netns < events && events < lock && lock < name &&
                 name <= generation && generation <= state &&
                 state < snapshot_unlock && snapshot_unlock < lookup &&
                 unregister < identity && identity <= lookup && lookup < clear) }
  ' || return 1
  flat="$(printf '%s\n' "$scheduler" | tr '\n' ' ' |
    sed 's/[[:space:]][[:space:]]*/ /g')"
  grep -Fq 'event == NETDEV_CHANGENAME && __dev_get_by_name(&init_net, cancelled_ifname)' \
    <<< "$flat" || return 1
  printf '%s\n' "$request" | awk '
    /rtnl_lock\(\)/ && !rtnl { rtnl=NR }
    /moal_bridge_pending_matches\(ifname, expected_generation\)/ {
      matches++
      if (matches == 2) recheck=NR
    }
    /ret = moal_bridge_find_target\(ifname, &target\)/ { resolve=NR }
    END { exit !(rtnl && recheck && resolve && rtnl < recheck &&
                 recheck < resolve) }
  '
}

check_pending_handle_invalidation_contract() {
  local invalidate="$1" drv_mode="$2" post_reset="$3" pcie_flr="$4" sdio_flr="$5"

  printf '%s\n' "$invalidate" | awk '
    /mutex_lock\(&bridge_lifecycle_lock\)/ { lifecycle=NR }
    /moal_bridge_pending_snapshot\(pending_ifname/ { snapshot=NR }
    /rtnl_lock\(\)/ { rtnl=NR }
    /handle->priv\[i\]->netdev->name/ { identity=NR }
    /moal_bridge_pending_clear_if\(pending_ifname/ { clear=NR }
    /rtnl_unlock\(\)/ { rtnl_unlock=NR }
    /mutex_unlock\(&bridge_lifecycle_lock\)/ { lifecycle_unlock=NR }
    END { exit !(lifecycle && snapshot && rtnl && identity && clear &&
                 rtnl_unlock && lifecycle_unlock && lifecycle < snapshot &&
                 snapshot < rtnl && rtnl < identity && identity < clear &&
                 clear < rtnl_unlock && rtnl_unlock < lifecycle_unlock) }
  ' || return 1
  printf '%s\n' "$drv_mode" | awk '
    /moal_bridge_pending_invalidate_handle\(handle\)/ { invalidate=NR }
    /woal_remove_interface\(handle, i\)/ { remove=NR }
    END { exit !(invalidate && remove && invalidate < remove) }
  ' || return 1
  printf '%s\n' "$post_reset" | awk '
    /if \(!handle->wifi_hal_flag\)/ { destructive=NR }
    /moal_bridge_pending_invalidate_handle\(handle\)/ { invalidate=NR }
    /woal_remove_interface\(handle, intf_num\)/ { remove=NR }
    END { exit !(destructive && invalidate && remove &&
                 destructive < invalidate && invalidate < remove) }
  ' || return 1
  printf '%s\n' "$pcie_flr" | awk '
    /moal_bridge_pending_invalidate_handle\(handle\)/ { invalidate=NR }
    /woal_remove_virtual_interface\(handle\)/ { virtual=NR }
    /woal_remove_interface\(handle, i\)/ { remove=NR }
    END { exit !(invalidate && virtual && remove && invalidate < virtual &&
                 virtual < remove) }
  ' || return 1
  printf '%s\n' "$sdio_flr" | awk '
    /moal_bridge_pending_invalidate_handle\(handle\)/ { invalidate=NR }
    /woal_remove_virtual_interface\(handle\)/ { virtual=NR }
    /woal_remove_interface\(handle, i\)/ { remove=NR }
    END { exit !(invalidate && virtual && remove && invalidate < virtual &&
                 virtual < remove) }
  '
}

check_pending_module_notifier_contract() {
  local nb_block="$1" callback="$2" start="$3" cleanup="$4" suspend="$5"

  printf '%s\n' "$nb_block" | awk '
    /static struct notifier_block bridge_pending_nb/ { block=NR }
    /\.notifier_call = moal_bridge_pending_netdev_event/ { wire=NR }
    END { exit !(block && wire && block < wire) }
  ' || return 1
  printf '%s\n' "$callback" | awk '
    /event == NETDEV_CHANGENAME/ { rename=NR }
    /event == NETDEV_UNREGISTER/ { unregister=NR }
    /moal_bridge_pending_schedule_event\(event, dev, true\)/ { deliver=NR }
    END { exit !(rename && unregister && deliver &&
                 rename <= unregister && unregister < deliver) }
  ' || return 1
  printf '%s\n' "$start" | awk '
    /if \(register_netdevice_notifier\(&bridge_pending_nb\)\) \{/ { register=NR }
    /^[[:space:]]*return;/ && register && !bail { bail=NR }
    /bridge_pending_nb_registered = true/ { mark=NR }
    /bridge_pending_events_enabled = true/ { enable=NR }
    END { exit !(register && bail && mark && enable && register < bail &&
                 bail < mark && mark < enable) }
  ' || return 1
  printf '%s\n' "$cleanup" | awk '
    /bridge_pending_events_enabled = false/ { disable=NR }
    /unregister_netdevice_notifier\(&bridge_pending_nb\)/ { unregister=NR }
    /cancel_work_sync\(&bridge_pending_work\)/ { drain=NR }
    END { exit !(disable && unregister && drain && disable < unregister &&
                 unregister < drain) }
  ' || return 1
  if printf '%s\n' "$suspend" |
      grep -Eq 'bridge_pending_nb|bridge_pending_events_enabled'; then
    return 1
  fi
  return 0
}

# The bridge hardening turned the unsupported-chipset FLR early exit into a
# hard failure while suspend/resume/reset callers began treating any FLR
# failure as terminal, so a non-allowlist PCIe part (e.g. PCIE8997) would
# brick ordinary suspend.  Pin the historical no-op success for chipsets
# outside the FLR allowlist, before any semaphore or teardown work.
check_pcie_flr_unsupported_noop_contract() {
  local flr="$1"

  printf '%s\n' "$flr" | awk '
    /!IS_PCIE9098\(handle->card_type\)\) \{/ { gate=NR }
    gate && !ret && /return MLAN_STATUS_(SUCCESS|FAILURE);/ {
      ret=NR
      failure=($0 ~ /MLAN_STATUS_FAILURE/)
    }
    /down\(&AddRemoveCardSem\)/ && !sem { sem=NR }
    END { exit !(gate && ret && sem && gate < ret && ret < sem &&
                 !failure) }
  '
}

# The hardening rework moved every surprise_removed/is_suspended clear into
# the FLR perform-init resume gate, which a non-allowlist chipset's no-op
# early exit skips entirely.  The base driver cleared both flags at caller
# level in resume, reset_done/reset_notify, and the in-band reset work, so
# each post-FLR success arm must republish through the idempotent
# woal_pcie_resume_gate() or unsupported parts finish the cycle with a dead
# WLAN until reload.
check_pcie_flr_republish_contract() {
  local resume="$1" done_blk="$2" notify="$3" work="$4" flat

  printf '%s\n' "$resume" | awk '
    /woal_do_flr_locked\(handle, false, false\)/ { flr=NR }
    flr && !gate && NR > flr && /woal_pcie_resume_gate\(handle\)/ {
      gate=NR
    }
    /moal_bridge_resume_owner\(\)/ && !bridge { bridge=NR }
    END { exit !(flr && gate && bridge && flr < gate && gate < bridge) }
  ' || return 1
  flat="$(printf '%s\n' "$done_blk" | tr '\n' ' ' |
    sed 's/[[:space:]][[:space:]]*/ /g')"
  grep -Fq 'woal_do_flr_locked(handle, false, true) && MLAN_STATUS_SUCCESS == woal_pcie_resume_gate(handle))' \
    <<< "$flat" || return 1
  grep -Fq 'woal_do_flr_locked(ref_handle, false, true) && MLAN_STATUS_SUCCESS == woal_pcie_resume_gate(ref_handle))' \
    <<< "$flat" || return 1
  flat="$(printf '%s\n' "$notify" | tr '\n' ' ' |
    sed 's/[[:space:]][[:space:]]*/ /g')"
  grep -Fq 'woal_do_flr_locked(handle, prepare, true) && MLAN_STATUS_SUCCESS == woal_pcie_resume_gate(handle))' \
    <<< "$flat" || return 1
  grep -Fq 'woal_do_flr_locked(ref_handle, prepare, true) && MLAN_STATUS_SUCCESS == woal_pcie_resume_gate(ref_handle))' \
    <<< "$flat" || return 1
  flat="$(printf '%s\n' "$work" | tr '\n' ' ' |
    sed 's/[[:space:]][[:space:]]*/ /g')"
  grep -Fq 'woal_do_flr_locked(handle, false, true) && MLAN_STATUS_SUCCESS == woal_pcie_resume_gate(handle))' \
    <<< "$flat" || return 1
  grep -Fq 'woal_do_flr_locked(ref_handle, false, true) && MLAN_STATUS_SUCCESS == woal_pcie_resume_gate(ref_handle))' \
    <<< "$flat"
}

# The kernel synthesizes NETDEV_UNREGISTER (and GOING_DOWN/DOWN) for every
# registered device to a notifier being unregistered.  The instance notifier
# is unregistered on every bridge deinit, so it must never feed identity
# events to the pending protocol or a retained request is spuriously
# cancelled at each owner suspension and switch-transaction teardown.
check_single_source_identity_contract() {
  local notifier="$1" flat count

  flat="$(printf '%s\n' "$notifier" | tr '\n' ' ' |
    sed 's/[[:space:]][[:space:]]*/ /g')"
  grep -Fq \
    'if (event == NETDEV_UP || event == NETDEV_CHANGE) moal_bridge_pending_schedule_event(event, dev, atomic_read(&br->published));' \
    <<< "$flat" || return 1
  count="$(printf '%s\n' "$notifier" |
    grep -c 'moal_bridge_pending_schedule_event(')"
  [ "$count" -eq 1 ]
}

check_pending_terminal_cancel_contract() {
  local cancel="$1" request="$2" drv_mode="$3" reload="$4" forget="$5"
  local discard="$6" resume="$7"

  printf '%s\n' "$cancel" | awk '
    /spin_lock_irqsave\(&bridge_pending_lock/ { lock=NR }
    /bridge_pending.state != MOAL_BR_PENDING_NONE/ { pending=NR }
    /bridge_pending.state = MOAL_BR_PENDING_NONE/ { clear=NR }
    /bridge_pending.ifname\[0\]/ { name=NR }
    /bridge_pending.generation\+\+/ { advance=NR }
    /spin_unlock_irqrestore\(&bridge_pending_lock/ { unlock=NR }
    END { exit !(lock && pending && clear && name && advance && unlock &&
                 lock < pending && pending < clear && clear <= name &&
                 name <= advance && advance < unlock) }
  ' || return 1
  printf '%s\n' "$request" | awk '
    /bridge_owner = NULL/ { owner_null=NR }
    /moal_bridge_pending_cancel_all\("runtime switch rollback failure"\)/ {
      cancel=NR
    }
    END { exit !(owner_null && cancel && owner_null < cancel) }
  ' || return 1
  printf '%s\n' "$drv_mode" | awk '
    /if \(destructive\)/ { destructive=NR }
    /if \(bridge_suspended\)/ { suspended=NR }
    /moal_bridge_discard_suspended_owner\(\)/ { discard=NR }
    /WIFI_STATUS_FW_RECOVERY_FAIL/ { terminal=NR }
    /moal_bridge_pending_cancel_all\("driver-mode terminal failure"\)/ {
      unrelated_clear=NR
    }
    END { exit !(destructive && suspended && discard && terminal &&
                 !unrelated_clear && suspended <= discard &&
                 destructive < terminal) }
  ' || return 1
  printf '%s\n' "$reload" | awk '
    /if \(destructive_started\)/ { destructive=NR }
    /moal_bridge_pending_cancel_all\("firmware reload terminal failure"\)/ {
      cancel=NR
    }
    /WIFI_STATUS_FW_RECOVERY_FAIL/ { terminal=NR }
    END { exit !(destructive && cancel && terminal &&
                 destructive < cancel && cancel < terminal) }
  ' || return 1
  printf '%s\n' "$forget" | awk '
    /owner_will_be_lost/ { owner_lost=NR }
    /moal_bridge_pending_cancel_all\("bridge owner removed"\)/ { cancel=NR }
    END { exit !(owner_lost && cancel && owner_lost < cancel) }
  ' || return 1
  printf '%s\n' "$discard" | awk '
    /if \(!bridge_suspended_owner.valid\)/ { valid=NR }
    /return;/ && valid && !valid_return { valid_return=NR }
    /moal_bridge_pending_cancel_all\("suspended owner discarded"\)/ { cancel=NR }
    /memset\(&bridge_suspended_owner/ { discard=NR }
    END { exit !(valid && valid_return && cancel && discard &&
                 valid < valid_return && valid_return < cancel &&
                 cancel < discard) }
  ' || return 1
  printf '%s\n' "$resume" | awk '
    /if \(!ret\)/ { success=NR }
    /bridge_owner = saved.handle/ { owner=NR }
    /else/ && owner { failure=NR }
    /moal_bridge_pending_cancel_all\("suspended owner resume failure"\)/ {
      cancel=NR
    }
    END { exit !(success && owner && failure && cancel &&
                 success < owner && owner < failure && failure < cancel) }
  '
}

check_worker_rejection_log_contract() {
  local logger="$1" request="$2"

  printf '%s\n' "$logger" | awk '
    /if \(expected_generation\)/ { guard=NR }
    /return;/ && guard { quiet=NR }
    /PRINTM\(MERROR/ { error=NR }
    END { exit !(guard && quiet && error && guard < quiet && quiet < error) }
  ' || return 1
  ! grep -Eq 'PRINTM\(MERROR,[[:space:]]*"bridge: runtime switch (rejected|interrupted)'     <<< "$request" || return 1
  [ "$(grep -Fc 'moal_bridge_log_request_rejection(' <<< "$request")" -ge 4 ]
}

check_bridge_bool_parser_contract() {
  local helper="$1" parser="$2" flat

  printf '%s\n' "$helper" | awk '
    /key_len = strlen\(key\)/ { key_len=NR }
    /line\[key_len\] != '\''='\''/ { delimiter=NR }
    /line\[key_len \+ 1\] != '\''0'\''/ { zero=NR }
    /line\[key_len \+ 1\] != '\''1'\''/ { one=NR }
    /line\[key_len \+ 2\]/ { terminal=NR }
    /\*out_data = line\[key_len \+ 1\] - '\''0'\''/ { store=NR }
    END { exit !(key_len && delimiter && zero && one && terminal && store &&
                 key_len < delimiter && delimiter <= zero && zero <= one &&
                 one <= terminal && terminal < store) }
  ' || return 1
  flat="$(printf '%s\n' "$parser" | tr '\n' ' ' |
    sed 's/[[:space:]][[:space:]]*/ /g')"
  grep -Fq 'strncmp(line, "bridge_runtime_switch=", strlen("bridge_runtime_switch=")) == 0'     <<< "$flat" || return 1
  grep -Fq 'strncmp(line, "bridge_runtime_deferred=", strlen("bridge_runtime_deferred=")) == 0'     <<< "$flat" || return 1
  [ "$(grep -Fo 'parse_line_read_bridge_bool(' <<< "$parser" | wc -l)" -eq 2 ]
}

check_bridge_bool_fixture_contract() {
  local value

  for value in 0 1; do
    case "bridge_runtime_deferred=$value" in
      bridge_runtime_deferred=0|bridge_runtime_deferred=1) ;;
      *) return 1 ;;
    esac
  done
  for value in 'bridge_runtime_deferred_extra=1'                'bridge_runtime_deferred='                'bridge_runtime_deferred=-'                'bridge_runtime_deferred=01'                'bridge_runtime_deferred=1x'; do
    case "$value" in
      bridge_runtime_deferred=0|bridge_runtime_deferred=1) return 1 ;;
    esac
  done
}

check_runtime_switch_conf_contract() {
  local parser="$1"

  printf '%s\n' "$parser" | awk '
    /int bridge_runtime_switch_cfg = 0/ { cfg_decl=NR }
    /int bridge_runtime_switch_present = 0/ { present_decl=NR }
    /strncmp\(line, "bridge_runtime_switch="/ { key=NR }
    /parse_line_read_bridge_bool\(/ && key && !parse { parse=NR }
    /out_data != 0 && out_data != 1/ && key && !range { range=NR }
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

check_runtime_deferred_conf_contract() {
  local parser="$1"
  printf '%s\n' "$parser" | awk '
    /int bridge_runtime_deferred_cfg = 0/ { cfg=NR }
    /int bridge_runtime_deferred_present = 0/ { present=NR }
    /strncmp\(line, "bridge_runtime_deferred="/ { key=NR }
    /out_data != 0 && out_data != 1/ && key { range=NR }
    /bridge_runtime_deferred_cfg = out_data/ { save=NR }
    /bridge_runtime_deferred_present = 1/ { mark=NR }
    /^[[:space:]]*if \(end\)[[:space:]]*\{/ { commit=NR }
    /WRITE_ONCE\(bridge_runtime_deferred, 1\)/ { enable=NR }
    /bridge_runtime_deferred = %d \(conf=%d\)/ { log_line=NR }
    END { exit !(cfg && present && key && range && save && mark && commit &&
                 enable && log_line && cfg < key && present < key && key < range &&
                 range < save && save <= mark && mark < commit && commit < enable &&
                 enable < log_line) }
  ' || return 1
  grep -q 'module_param_cb(bridge_runtime_deferred, &bridge_runtime_deferred_ops' "$INIT_C"
}

check_runtime_deferred_param_contract() {
  check_runtime_deferred_param_contract_from_source "$(cat "$INIT_C")"
}

check_runtime_deferred_param_contract_from_source() {
  local init_source="$1"

  printf '%s\n' "$init_source" | awk '
    /static int bridge_runtime_deferred_set\(const char \*val,/ { set_decl=NR }
    /int value = 0/ { value_decl=NR }
    /kstrtoint\(val, 0, &value\)/ { parse=NR }
    /value != 0 && value != 1/ { range=NR }
    /return -EINVAL/ && range && !reject { reject=NR }
    /\*\(int \*\)kp->arg = value/ { store=NR }
    /static const struct kernel_param_ops bridge_runtime_deferred_ops/ { ops=NR }
    /\.set = bridge_runtime_deferred_set/ { set_op=NR }
    /\.get = param_get_int/ { get_op=NR }
    /module_param_cb\(bridge_runtime_deferred, &bridge_runtime_deferred_ops,/ { register=NR }
    /&bridge_runtime_deferred, 0444\)/ { mode=NR }
    /module_param_cb\(bridge_runtime_deferred, &bridge_runtime_deferred_ops, NULL, 0444\)/ { bad_register=NR }
    END { exit !(set_decl && value_decl && parse && range && reject && store &&
                 ops && set_op && get_op && register && mode && !bad_register &&
                 set_decl < value_decl && value_decl < parse && parse < range &&
                 range < reject && reject < store && store < ops && ops < set_op &&
                 set_op < get_op && get_op < register && register < mode) }
  '
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

check_target_readiness_split_contract() {
  local resolver="$1" readiness="$2" switch="$3" validator="$4"

  printf '%s\n' "$resolver" | awk '
    /priv->bss_type != MLAN_BSS_TYPE_STA/ { sta=NR }
    /handle->surprise_removed/ { removed=NR }
    /handle->fw_reseting/ { resetting=NR }
    /handle->fw_reload/ { reload=NR }
    /handle->driver_status/ { driver=NR }
    /handle->hardware_status != HardwareStatusReady/ { hardware=NR }
    /priv->netdev->reg_state != NETREG_REGISTERED/ { registered=NR }
    /netif_device_present\(priv->netdev\)/ { present=NR }
    /handle->priv\[j\] == priv/ { owner=NR }
    /netif_running\(priv->netdev\)|media_connected|netif_carrier_ok/ { readiness_in_resolver=1 }
    END { exit !(sta && removed && resetting && reload && driver && hardware &&
                 registered && present && owner && !readiness_in_resolver) }
  ' || return 1

  printf '%s\n' "$readiness" | awk '
    /if \(!netif_running\(target->dev\)\)/ { running=NR }
    running && /return -ENETDOWN/ && !running_ret { running_ret=NR }
    /if \(READ_ONCE\(target->priv->media_connected\) != MTRUE\)/ { media=NR }
    media && /return -ENOLINK/ && !media_ret { media_ret=NR }
    /if \(!netif_carrier_ok\(target->dev\)\)/ { carrier=NR }
    carrier && /return -ENETDOWN/ && !carrier_ret { carrier_ret=NR }
    /return 0/ { success=NR }
    END { exit !(running && running_ret && media && media_ret && carrier &&
                 carrier_ret && success && running < running_ret &&
                 running_ret < media && media < media_ret && media_ret < carrier &&
                 carrier < carrier_ret && carrier_ret < success) }
  ' || return 1

  printf '%s\n' "$switch" | awk '
    /ret = moal_bridge_find_target\(ifname, &target\)/ { find=NR }
    /ret = moal_bridge_target_link_status\(&target\)/ { readiness=NR }
    /__moal_bridge_deinit_locked\(old.old_owner\)/ && !teardown { teardown=NR }
    END { exit !(find && readiness && teardown && find < readiness &&
                 readiness < teardown) }
  ' || return 1

  printf '%s\n' "$validator" | awk '
    /target->priv->netdev != target->dev/ { pointer=NR }
    /bridge_owner \|\| !target->handle->bridge/ { owner=NR }
    /ret = moal_bridge_target_link_status\(target\)/ { readiness=NR }
    END { exit !(pointer && owner && readiness && pointer < owner &&
                 owner < readiness) }
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

check_deferred_qa_contract() {
  local qa="$1" off waiting cancel cleanup capture assertions

  for token in \
    'DEFERRED_PARAM="$PARAM_DIR/bridge_runtime_deferred"' \
    'PENDING_PARAM="$PARAM_DIR/bridge_pending_iface"' \
    'DEFERRED_TIMEOUT="${DEFERRED_TIMEOUT:-30}"' \
    'deferred-off) run_deferred_off ;;' \
    'deferred-wait) run_deferred_wait ;;' \
    'deferred-cancel) run_deferred_cancel ;;'; do
    grep -Fq "$token" <<< "$qa" || return 1
  done

  off="$(extract_c_block "$qa" '^run_deferred_off\(\)')" || return 1
  waiting="$(extract_c_block "$qa" '^run_deferred_wait\(\)')" || return 1
  cancel="$(extract_c_block "$qa" '^run_deferred_cancel\(\)')" || return 1
  cleanup="$(extract_c_block "$qa" '^cleanup\(\)')" || return 1
  capture="$(extract_c_block "$qa" '^capture_state\(\)')" || return 1
  assertions="$(extract_c_block "$qa" '^require_waiting_unchanged\(\)')" || return 1

  printf '%s\n' "$off" | awk '
    /require_gate 1/ { gate=NR }
    /require_deferred_gate 0/ { deferred=NR }
    /ip link set dev "\$TO_IF" down/ { down=NR }
    /run_prevalidation_reject "\$TO_IF" 100/ { reject=NR }
    END { exit !(gate && deferred && down && reject &&
                 gate < deferred && deferred < down && down < reject) }
  ' || return 1
  printf '%s\n' "$capture" | awk '
    /DEFERRED_PARAM/ { deferred=NR }
    /read_pending/ { pending=NR }
    END { exit !(deferred && pending) }
  ' || return 1
  printf '%s\n' "$waiting" | awk '
    /require_gate 1/ { gate=NR }
    /require_deferred_gate 1/ { deferred=NR }
    /require_associated "\$FROM_IF"/ { source=NR }
    /ip link set dev "\$TO_IF" down/ { down=NR }
    /require_admin_down "\$TO_IF"/ { admin_down=NR }
    /snapshot_outcomes/ { snapshot=NR }
    /> "\$IFACE_PARAM"/ { write=NR }
    /require_waiting_unchanged "\$FROM_IF" "\$TO_IF"/ { waiting=NR }
    /ip link set dev "\$TO_IF" up/ { up=NR }
    /wait_for_deferred_completion "\$TO_IF"/ { complete=NR }
    /SWITCH_OK_BEFORE \+ 1/ { success=NR }
    END { exit !(gate && deferred && source && down && admin_down && snapshot &&
                 write && waiting && up && complete && success &&
                 gate < deferred && deferred < source && source < down &&
                 down < snapshot && snapshot < write && write < waiting &&
                 waiting < up && up < complete && complete < success) }
  ' || return 1
  printf '%s\n' "$cancel" | awk '
    /ip link set dev "\$TO_IF" down/ { down=NR }
    /snapshot_outcomes/ { snapshot=NR }
    /> "\$IFACE_PARAM"/ { writes++ }
    /require_waiting_unchanged "\$FROM_IF" "\$TO_IF"/ { waiting=NR }
    /pending_is_empty/ { cleared=NR }
    /assert_all_outcomes_unchanged/ { counters=NR }
    END { exit !(down && snapshot && writes >= 2 && waiting && cleared && counters &&
                 down < snapshot && snapshot < waiting && waiting < cleared &&
                 cleared < counters) }
  ' || return 1
  printf '%s\n' "$assertions" | awk '
    /read_binding/ { binding=NR }
    /stats_value active/ { active=NR }
    /read_pending/ { pending=NR }
    /stats_value pending_iface/ { pending_stats=NR }
    /stats_value pending_state/ { state_stats=NR }
    /assert_all_outcomes_unchanged/ { counters=NR }
    END { exit !(binding && active && pending && pending_stats && state_stats &&
                 counters && binding < active && active < pending &&
                 pending < pending_stats && pending_stats <= state_stats &&
                 state_stats < counters) }
  ' || return 1
  printf '%s\n' "$cleanup" | awk '
    /if ! pending_is_empty/ && !pending_check { pending_check=NR }
    /pending_binding=.*read_binding/ && !pending_owner { pending_owner=NR }
    /> "\$IFACE_PARAM"/ && pending_owner && !cancel { cancel=NR }
    /current_binding=.*read_binding/ && !restore { restore=NR }
    END { exit !(pending_check && pending_owner && cancel && restore &&
                 pending_check < pending_owner && pending_owner < cancel && cancel < restore) }
  '
}

check_deferred_docs_contract() {
  local doc

  for doc in "$PARAM_DOC" "$QA_RUNBOOK"; do
    grep -Fq 'bridge_runtime_deferred' "$doc" || return 1
    grep -Fq 'bridge_pending_iface' "$doc" || return 1
  done
  for token in 'one-write' 'no timeout' 'cancel' 'replace' 'worker' \
               'NETDEV_UP' 'NETDEV_CHANGE' 'NETDEV_UNREGISTER' \
               'NETDEV_CHANGENAME' 'same-MAC' 'multi-BSSID' 'data-plane' \
               'identity-preserving reset' 'destructive netdev recreation' \
               'terminal reset failure'; do
    grep -Fq "$token" "$ROOT/docs/runtime-bridge-interface-switch.design.md" || return 1
  done
  for token in 'QA_CASE=deferred-off' 'QA_CASE=deferred-wait' \
               'QA_CASE=deferred-cancel' 'link-ready' 'end-to-end' \
               'name-reuse' 'unregister' 'unrelated rename' 'cross-netns' \
               'destructive-reset-success' 'destructive-reset-failure' \
               'third registered STA' 'NOT RUN/UNSUPPORTED'; do
    grep -Fq "$token" "$QA_RUNBOOK" || return 1
  done
}

check_deferred_pending_wire_contract() {
  local qa="$1" empty stats

  empty="$(extract_c_block "$qa" '^pending_is_empty\(\)')" || return 1
  stats="$(extract_c_block "$qa" '^stats_pending_is_none\(\)')" || return 1
  printf '%s\n' "$empty" | grep -Fq '[ -z "$pending" ]' || return 1
  printf '%s\n' "$empty" | grep -Fq '"$pending" = none' && return 1
  printf '%s\n' "$stats" | grep -Fq 'stats_value pending_iface' || return 1
  printf '%s\n' "$stats" | grep -Fq 'stats_value pending_state' || return 1
  printf '%s\n' "$stats" | grep -Fq '= none' || return 1
  grep -Fq 'pending_is_empty && stats_pending_is_none' <<< "$qa"
}

check_pending_source_wire_contract() {
  local getter="$1" stats="$2"

  grep -Fq 'if (state == MOAL_BR_PENDING_NONE)' <<< "$getter" || return 1
  grep -Fq 'return scnprintf(buf, len, "\n");' <<< "$getter" || return 1
  ! grep -Fq 'return scnprintf(buf, len, "none\n");' <<< "$getter" || return 1
  grep -Fq 'if (pending_state == MOAL_BR_PENDING_NONE)' <<< "$stats" || return 1
  grep -Fq 'strncpy(pending_name, "none", sizeof(pending_name));' \
    <<< "$stats" || return 1
  grep -Fq 'pending_iface=%s pending_state=%s' <<< "$stats"
}

check_same_target_qa_contract() {
  local qa="$1" same

  same="$(extract_c_block "$qa" '^run_same_target\(\)')" || return 1
  printf '%s\n' "$same" | awk '
    /require_gate 1/ { gate=NR }
    /require_deferred_gate 0/ { deferred=NR }
    /pending_is_empty/ && !pending { pending=NR }
    /stats_pending_is_none/ && !stats { stats=NR }
    /bridge_binding_healthy "\$original"/ && !healthy { healthy=NR }
    /snapshot_outcomes/ { snapshot=NR }
    /switch_iface "\$original"/ { write=NR }
    END { exit !(gate && deferred && pending && stats && healthy && snapshot &&
                 write && gate < deferred && deferred < pending &&
                 pending <= stats && stats < healthy && healthy < snapshot &&
                 snapshot < write) }
  '
}

check_deferred_replace_qa_contract() {
  local qa="$1" replace

  grep -Fq 'REPLACE_IF="${REPLACE_IF:-}"' <<< "$qa" || return 1
  grep -Fq 'deferred-replace) run_deferred_replace ;;' <<< "$qa" || return 1
  replace="$(extract_c_block "$qa" '^run_deferred_replace\(\)')" || return 1
  printf '%s\n' "$replace" | awk '
    /require_gate 1/ { gate=NR }
    /require_deferred_gate 1/ { deferred=NR }
    /"\$REPLACE_IF" != "\$FROM_IF"/ { from_distinct=NR }
    /"\$REPLACE_IF" != "\$TO_IF"/ { to_distinct=NR }
    /"\$REPLACE_IF" != "\$PEER_IF"/ { peer_distinct=NR }
    /ip link set dev "\$TO_IF" down/ { to_down=NR }
    /ip link set dev "\$REPLACE_IF" down/ { replace_down=NR }
    /printf .*"\$TO_IF" > "\$IFACE_PARAM"/ { first_write=NR }
    /require_waiting_unchanged "\$FROM_IF" "\$TO_IF"/ { first_wait=NR }
    /printf .*"\$REPLACE_IF" > "\$IFACE_PARAM"/ { replace_write=NR }
    /require_waiting_unchanged "\$FROM_IF" "\$REPLACE_IF"/ && !replaced { replaced=NR }
    /wait_for_ready_without_switch "\$TO_IF" "\$FROM_IF" "\$REPLACE_IF"/ { old_ready=NR }
    /wait_for_deferred_completion "\$REPLACE_IF"/ { complete=NR }
    /SWITCH_OK_BEFORE \+ 1/ { once=NR }
    END { exit !(gate && deferred && from_distinct && to_distinct && peer_distinct && to_down &&
                 replace_down && first_write && first_wait && replace_write &&
                 replaced && old_ready && complete && once && gate < deferred &&
                 deferred < from_distinct && from_distinct <= to_distinct &&
                 to_distinct < peer_distinct && peer_distinct < to_down && to_down < replace_down &&
                 replace_down < first_write && first_write < first_wait &&
                 first_wait < replace_write && replace_write < replaced &&
                 replaced < old_ready && old_ready < complete && complete < once) }
  '
}

check_deferred_reset_qa_contract() {
  local qa="$1" success failure

  grep -Fq 'destructive-reset-success) run_destructive_reset_success ;;' \
    <<< "$qa" || return 1
  grep -Fq 'destructive-reset-failure) run_destructive_reset_failure ;;' \
    <<< "$qa" || return 1
  success="$(extract_c_block "$qa" '^run_destructive_reset_success\(\)')" || return 1
  failure="$(extract_c_block "$qa" '^run_destructive_reset_failure\(\)')" || return 1
  printf '%s\n' "$success" | awk '
    /require_deferred_gate 1/ { deferred=NR }
    /ip link set dev "\$TO_IF" down/ { down=NR }
    /printf .*"\$TO_IF" > "\$IFACE_PARAM"/ { request=NR }
    /require_waiting_unchanged "\$FROM_IF" "\$TO_IF"/ { waiting=NR }
    /bash -c "\$command_value"/ { command=NR }
    /pending_is_empty/ { empty=NR }
    /stats_pending_is_none/ { stats=NR }
    /wait_for_ready_without_cleared_switch "\$TO_IF" "\$FROM_IF"/ { reuse=NR }
    END { exit !(deferred && down && request && waiting && command && empty &&
                 stats && reuse && deferred < down && down < request &&
                 request < waiting && waiting < command && command < empty &&
                 empty <= stats && stats < reuse) }
  ' || return 1
  printf '%s\n' "$failure" | awk '
    /require_deferred_gate 1/ { deferred=NR }
    /printf .*"\$TO_IF" > "\$IFACE_PARAM"/ { request=NR }
    /require_waiting_unchanged "\$FROM_IF" "\$TO_IF"/ { waiting=NR }
    /bash -c "\$command_value"/ { command=NR }
    /read_binding.*none/ { owner=NR }
    /pending_is_empty/ { empty=NR }
    /stats_pending_is_none/ { stats=NR }
    END { exit !(deferred && request && waiting && command && owner && empty &&
                 stats && deferred < request && request < waiting &&
                 waiting < command && command < owner && owner < empty &&
                 empty <= stats) }
  '
}

check_strict_disconnected_qa_contract() {
  local qa="$1"

  printf '%s\n' "$qa" | awk '
    /target-disconnected\)/ { start=NR }
    start && /require_gate 1/ { gate=NR }
    start && /require_deferred_gate 0/ { deferred=NR }
    start && /require_unassociated_admin_up "\$TO_IF"/ { disconnected=NR }
    start && /run_prevalidation_reject "\$TO_IF" 67/ { reject=NR; exit }
    END { exit !(start && gate && deferred && disconnected && reject &&
                 start < gate && gate < deferred && deferred < disconnected &&
                 disconnected < reject) }
  ' || return 1
  local peer
  peer="$(extract_c_block "$qa" '^run_peer_cycle\(\)')" || return 1
  printf '%s\n' "$peer" | awk '
    /require_gate 1/ { gate=NR }
    /require_deferred_gate 0/ { deferred=NR }
    /ip link set dev "\$PEER_IF" down/ { down=NR }
    /write_expect_errno "\$original" 100/ { same=NR }
    END { exit !(gate && deferred && down && same && gate < deferred &&
                 deferred < down && down < same) }
  '
}

check_deferred_cleanup_restore_contract() {
  printf '%s\n' "$1" | awk '
    /binding_restore_verified=0/ { init=NR }
    /INITIAL_BINDING.*> "\$IFACE_PARAM"/ && !restore { restore=NR }
    /restored_binding=.*read_binding/ && restore && !reread { reread=NR }
    /"\$restored_binding" = "\$INITIAL_BINDING"/ && reread && !exact { exact=NR }
    /pending_is_empty/ && exact && !pending { pending=NR }
    /stats_pending_is_none/ && exact && !stats { stats=NR }
    /bridge_binding_healthy "\$INITIAL_BINDING"/ && exact && !healthy { healthy=NR }
    /binding_restore_verified=1/ && healthy && !verified { verified=NR }
    /if \[ "\$binding_restore_verified" -eq 1 \]/ && verified && !admin_gate { admin_gate=NR }
    /owner_before_target_restore=.*read_binding/ && admin_gate && !owner_read { owner_read=NR }
    /"\$owner_before_target_restore" = "\$TO_IF"/ && owner_read && !owner_guard { owner_guard=NR }
    /ip link set dev "\$TO_IF" down/ && owner_guard && !target_down { target_down=NR }
    /owner_before_replace_restore=.*read_binding/ && target_down && !replace_read { replace_read=NR }
    /"\$owner_before_replace_restore" = "\$REPLACE_IF"/ && replace_read && !replace_guard { replace_guard=NR }
    /ip link set dev "\$REPLACE_IF" down/ && replace_guard && !replace_down { replace_down=NR }
    END { exit !(init && restore && reread && exact && pending && stats && healthy &&
                 verified && admin_gate && owner_read && owner_guard && target_down &&
                 replace_read && replace_guard && replace_down &&
                 init < restore && restore < reread && reread < exact &&
                 exact <= pending && pending <= stats && stats <= healthy && healthy < verified &&
                 verified < admin_gate && admin_gate < owner_read &&
                 owner_read < owner_guard && owner_guard < target_down &&
                 target_down < replace_read && replace_read < replace_guard &&
                 replace_guard < replace_down) }
  '
}

check_deferred_docs_completion_contract() {
  local design="$ROOT/docs/runtime-bridge-interface-switch.design.md"
  local plan="$ROOT/docs/superpowers/plans/2026-08-14-runtime-bridge-deferred-switch.md"
  local doc

  for doc in "$PARAM_DOC" "$design" "$QA_RUNBOOK" "$plan" "$DEFERRED_SPEC"; do
    check_deferred_doc_terms "$(cat "$doc")" || return 1
  done
  ! grep -Fq 'write는 비동기 요청을 예약하는 동작이 아니다' "$PARAM_DOC" || return 1
  ! grep -Fq 'pending name or `none`' "$design" || return 1
  ! grep -Fq 'pending target 이름(없으면 `none`)' "$PARAM_DOC" || return 1
  ! grep -Fq '전환은 synchronous이지만' "$QA_RUNBOOK" || return 1
  ! grep -Fq 'A request for a disconnected or administratively down target becomes' \
    "$DEFERRED_SPEC" || return 1
  check_deferred_spec_scope_contract "$(cat "$DEFERRED_SPEC")"
}

check_deferred_doc_terms() {
  local doc="$1"

  grep -Fq 'strict ready completion' <<< "$doc" || return 1
  grep -Fq 'deferred acceptance' <<< "$doc" || return 1
  grep -Fq 'empty line' <<< "$doc" || return 1
  grep -Fq 'pending_iface=none' <<< "$doc"
}

check_terminal_failure_doc_contract() {
  local doc="$1" section

  section="$(printf '%s\n' "$doc" | awk '
    /^\*\*destructive-reset-failure \(board-command case\)\*\*/ { capture=1 }
    capture { print }
    capture && /^```bash$/ { exit }
  ')" || return 1
  grep -Fq '`bridge_iface=none`' <<< "$section" || return 1
  grep -Fq '`bridge_pending_iface` getter는 empty line' <<< "$section" || return 1
  grep -Fq '`pending_iface=none pending_state=none`' <<< "$section"
}

check_deferred_spec_scope_contract() {
  local spec="$1"

  grep -Fq 'With `bridge_runtime_deferred=1`' <<< "$spec" || return 1
  grep -Fq 'default-off mode retains rejection' <<< "$spec" || return 1
  grep -Fq 'link-not-ready target replaces' <<< "$spec" || return 1
  ! grep -Fq 'A request for a disconnected or administratively down target becomes' \
    <<< "$spec"
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
ACTIVE_PARAM_GETTER_BLOCK="$(extract_c_function '^static int bridge_iface_get' "$INIT_C")"
PENDING_PARAM_GETTER_BLOCK="$(extract_c_function '^static int bridge_pending_iface_get' "$INIT_C" || true)"
# parse_cfg_read_block compares against the literal string "}"; the generic
# brace scanner intentionally does not parse C strings, so use the function's
# column-zero closing brace as the boundary for this one large parser.
CONF_PARSER_BLOCK="$(sed -n '/^static mlan_status parse_cfg_read_block/,/^}/p' "$INIT_C")"
PARSE_BRIDGE_BOOL_BLOCK="$(extract_c_function '^static mlan_status parse_line_read_bridge_bool' "$INIT_C" || true)"
INIT_MODULE_BLOCK="$(extract_c_function '^static int woal_init_module' "$MAIN_C")"
CLEANUP_MODULE_BLOCK="$(extract_c_function '^static void woal_cleanup_module' "$MAIN_C")"
REQUEST_RELOAD_BLOCK="$(extract_c_function '^int woal_request_fw_reload' "$MAIN_C")"
PRE_RESET_BLOCK="$(extract_c_function '^static void woal_pre_reset' "$MAIN_C")"
POST_RESET_BLOCK="$(extract_c_function '^static int woal_post_reset' "$MAIN_C")"
MAIN_WORK_BLOCK="$(extract_c_function '^t_void woal_main_work_queue' "$MAIN_C")"
FW_DPC_BLOCK="$(extract_c_function '^static mlan_status woal_request_fw_dpc' "$MAIN_C")"
INIT_FW_BLOCK="$(extract_c_function '^mlan_status woal_init_fw' "$MAIN_C")"
DRV_MODE_BLOCK="$(extract_c_function '^mlan_status woal_switch_drv_mode' "$MAIN_C")"
FIND_TARGET_BLOCK="$(extract_c_function '^static int moal_bridge_find_target' "$BRIDGE_C")"
LINK_STATUS_BLOCK="$(extract_c_function '^static int moal_bridge_target_link_status' "$BRIDGE_C" || true)"
SWITCH_BLOCK="$(extract_switch_block "$BRIDGE_C")"
PENDING_REQUEST_BLOCK="$(extract_c_block "$(cat "$BRIDGE_C")" '^struct moal_bridge_pending_request' || true)"
PENDING_SET_BLOCK="$(extract_c_function '^static unsigned long moal_bridge_pending_set' "$BRIDGE_C" || true)"
PENDING_SCHEDULER_BLOCK="$(extract_c_function '^static void moal_bridge_pending_schedule_event' "$BRIDGE_C" || true)"
PENDING_BEGIN_BLOCK="$(extract_c_function '^static bool moal_bridge_pending_begin_attempt' "$BRIDGE_C" || true)"
PENDING_RESTORE_BLOCK="$(extract_c_function '^static bool moal_bridge_pending_restore_waiting' "$BRIDGE_C" || true)"
PENDING_WORKER_BLOCK="$(extract_c_function '^static void moal_bridge_pending_work_fn\(struct work_struct \*work\)$' "$BRIDGE_C" || true)"
PENDING_CLEAR_BLOCK="$(extract_c_function '^static bool moal_bridge_pending_clear_if' "$BRIDGE_C" || true)"
PENDING_START_BLOCK="$(extract_c_function '^void moal_bridge_pending_start' "$BRIDGE_C" || true)"
PENDING_CLEANUP_BLOCK="$(extract_c_function '^void moal_bridge_pending_cleanup' "$BRIDGE_C" || true)"
PENDING_INVALIDATE_HANDLE_BLOCK="$(extract_c_function '^void moal_bridge_pending_invalidate_handle' "$BRIDGE_C" || true)"
PENDING_MODULE_NOTIFIER_BLOCK="$(extract_c_function '^static int moal_bridge_pending_netdev_event' "$BRIDGE_C" || true)"
PENDING_MODULE_NB_BLOCK="$(extract_c_block "$(cat "$BRIDGE_C")" '^static struct notifier_block bridge_pending_nb' || true)"
PENDING_CANCEL_ALL_BLOCK="$(extract_c_function '^void moal_bridge_pending_cancel_all' "$BRIDGE_C" || true)"
PENDING_GETTER_BLOCK="$(extract_c_function '^int moal_bridge_get_pending_iface' "$BRIDGE_C" || true)"
REQUEST_REJECTION_LOG_BLOCK="$(extract_c_function '^static void moal_bridge_log_request_rejection' "$BRIDGE_C" || true)"
FORGET_HANDLE_BLOCK="$(extract_c_function '^void moal_bridge_forget_handle' "$BRIDGE_C" || true)"
DISCARD_SUSPENDED_BLOCK="$(extract_c_function '^static void __moal_bridge_discard_suspended_owner' "$BRIDGE_C" || true)"
RESUME_SUSPENDED_BLOCK="$(extract_c_function '^static int __moal_bridge_resume_owner' "$BRIDGE_C" || true)"
VALIDATE_BLOCK="$(extract_c_function '^static int moal_bridge_validate_binding_locked' "$BRIDGE_C")"
BRIDGE_INIT_BLOCK="$(extract_c_function '^static int __moal_bridge_init_locked' "$BRIDGE_C")"
LIFECYCLE_DEINIT_BLOCK="$(extract_c_function '^static void __moal_bridge_deinit_locked' "$BRIDGE_C")"
NETDEV_EVENT_BLOCK="$(extract_c_function '^static int moal_bridge_netdev_event' "$BRIDGE_C")"
GETTER_BLOCK="$(extract_c_function '^int moal_bridge_get_iface' "$BRIDGE_C")"
STATS_SHOW_BLOCK="$(extract_c_function '^static ssize_t stats_show' "$BRIDGE_C")"
SYSFS_DEINIT_BLOCK="$(extract_c_function '^static void moal_bridge_sysfs_deinit' "$BRIDGE_C")"
STATS_CLEANUP_BLOCK="$(extract_c_function '^void moal_bridge_stats_cleanup' "$BRIDGE_C")"
SUSPEND_OWNER_BLOCK="$(extract_c_function '^static int __moal_bridge_suspend_owner' "$BRIDGE_C")"
SUSPEND_SCOPE_BLOCK="$SUSPEND_OWNER_BLOCK
$LIFECYCLE_DEINIT_BLOCK"
REMOVE_CARD_BLOCK="$(extract_c_function '^mlan_status woal_remove_card' "$MAIN_C")"
PCIE_FLR_BLOCK="$(extract_c_function '^static mlan_status __woal_do_flr' "$PCIE_C")"
PCIE_PREP_BLOCK="$(extract_c_function '^static void woal_pcie_reset_prepare' "$PCIE_C")"
PCIE_DONE_BLOCK="$(extract_c_function '^static void woal_pcie_reset_done' "$PCIE_C")"
PCIE_NOTIFY_BLOCK="$(extract_c_function '^static void woal_pcie_reset_notify' "$PCIE_C")"
PCIE_WORK_BLOCK="$(extract_c_function '^static void woal_pcie_work\(struct work_struct \*work\)$' "$PCIE_C")"
PCIE_RESUME_BLOCK="$(extract_c_function '^static int woal_pcie_resume\(struct pci_dev \*pdev\)$' "$PCIE_C" || true)"
SDIO_FLR_BLOCK="$(extract_c_function '^static mlan_status __woal_do_sdiommc_flr' "$SDIO_C")"
SDIO_WORK_BLOCK="$(extract_c_function '^static void woal_sdiommc_work\(struct work_struct \*work\)$' "$SDIO_C")"
SDIO_REMOVE_BLOCK="$(extract_c_function '^void woal_sdio_remove\(struct sdio_func \*func\)$' "$SDIO_C")"
QA_CLEANUP_BLOCK="$(extract_c_function '^cleanup\(\)' "$QA_SCRIPT")"

# Invoke all defined strong structural helpers; their focused mutations below
# make these source-order checks regression gates rather than dead declarations.
check_pending_storage_contract "$PENDING_REQUEST_BLOCK" ||
  fail "runtime-switch: pointer-free single pending request state missing"
PENDING_WITH_POINTER="$(printf '%s\n' "$PENDING_REQUEST_BLOCK" |
  sed '/enum moal_bridge_pending_state state;/a\	struct net_device *target_dev;')"
if check_pending_storage_contract "$PENDING_WITH_POINTER"; then
  fail "runtime-switch: retained pending target pointer mutation accepted"
fi
printf 'PASS: runtime-switch pending pointer-lifetime mutation rejected\n'

check_pending_notifier_contract "$NETDEV_EVENT_BLOCK" "$PENDING_SCHEDULER_BLOCK" \
  "$PENDING_MODULE_NOTIFIER_BLOCK" ||
  fail "runtime-switch: notifier does not use the non-sleeping pending scheduler"
NOTIFIER_DIRECT_SWITCH="$(printf '%s\n' "$NETDEV_EVENT_BLOCK" | awk '
  /moal_bridge_pending_schedule_event\(event, dev,/ {
    print "\t\tmoal_bridge_switch_iface(dev->name);"
    getline
    next
  }
  { print }
')"
if check_pending_notifier_contract "$NOTIFIER_DIRECT_SWITCH" \
    "$PENDING_SCHEDULER_BLOCK" "$PENDING_MODULE_NOTIFIER_BLOCK"; then
  fail "runtime-switch: direct notifier switch mutation accepted"
fi
printf 'PASS: runtime-switch notifier-context mutation rejected\n'
MODULE_NOTIFIER_DIRECT_SWITCH="$(printf '%s\n' "$PENDING_MODULE_NOTIFIER_BLOCK" | awk '
  /moal_bridge_pending_schedule_event\(event, dev,/ {
    print "\t\tmoal_bridge_switch_iface(dev->name);"
    next
  }
  { print }
')"
if check_pending_notifier_contract "$NETDEV_EVENT_BLOCK" \
    "$PENDING_SCHEDULER_BLOCK" "$MODULE_NOTIFIER_DIRECT_SWITCH"; then
  fail "runtime-switch: direct module-notifier switch mutation accepted"
fi
printf 'PASS: runtime-switch module notifier-context mutation rejected\n'

check_pending_worker_contract "$PENDING_WORKER_BLOCK" "$SWITCH_BLOCK" ||
  fail "runtime-switch: pending worker card/readiness/lifecycle order missing"
PENDING_REQUEST_NO_RECHECK="$(printf '%s\n' "$SWITCH_BLOCK" | awk '
  /READ_ONCE\(bridge_runtime_control_ready\)/ { n++ }
  n == 2 { sub(/READ_ONCE\(bridge_runtime_control_ready\)/, "1") }
  { print }
')"
if check_pending_worker_contract "$PENDING_WORKER_BLOCK" "$PENDING_REQUEST_NO_RECHECK"; then
  fail "runtime-switch: pending worker readiness-recheck mutation accepted"
fi
printf 'PASS: runtime-switch pending worker ordering mutation rejected\n'

check_pending_generation_clear_contract "$PENDING_WORKER_BLOCK" "$PENDING_CLEAR_BLOCK" ||
  fail "runtime-switch: pending completion lacks name/generation compare-and-clear"
PENDING_CLEAR_NO_GENERATION="$(printf '%s\n' "$PENDING_CLEAR_BLOCK" |
  sed 's/bridge_pending.generation == generation/true/')"
if check_pending_generation_clear_contract "$PENDING_WORKER_BLOCK" "$PENDING_CLEAR_NO_GENERATION"; then
  fail "runtime-switch: pending clear without generation mutation accepted"
fi
printf 'PASS: runtime-switch pending generation mutation rejected\n'

check_pending_admission_cleanup_contract "$INIT_MODULE_BLOCK" "$CLEANUP_MODULE_BLOCK" \
  "$PENDING_START_BLOCK" "$PENDING_CLEANUP_BLOCK" ||
  fail "runtime-switch: pending admission/cleanup handshake missing"
CLEANUP_NO_PENDING_DRAIN="$(printf '%s\n' "$CLEANUP_MODULE_BLOCK" |
  sed 's/moal_bridge_pending_cleanup();/\/\* missing pending drain \*\//')"
if check_pending_admission_cleanup_contract "$INIT_MODULE_BLOCK" \
    "$CLEANUP_NO_PENDING_DRAIN" "$PENDING_START_BLOCK" "$PENDING_CLEANUP_BLOCK"; then
  fail "runtime-switch: missing pending cleanup mutation accepted"
fi
printf 'PASS: runtime-switch pending cleanup mutation rejected\n'

check_bridge_getter_separation_contract "$ACTIVE_PARAM_GETTER_BLOCK" \
  "$PENDING_PARAM_GETTER_BLOCK" ||
  fail "runtime-switch: active and pending getter separation missing"
PENDING_GETTER_RETURNS_ACTIVE="$(printf '%s\n' "$PENDING_PARAM_GETTER_BLOCK" |
  sed 's/moal_bridge_get_pending_iface/moal_bridge_get_iface/')"
if check_bridge_getter_separation_contract "$ACTIVE_PARAM_GETTER_BLOCK" \
    "$PENDING_GETTER_RETURNS_ACTIVE"; then
  fail "runtime-switch: pending getter reporting active interface mutation accepted"
fi
printf 'PASS: runtime-switch active/pending getter mutation rejected\n'

check_pending_admission_kick_contract "$PENDING_SET_BLOCK" ||
  fail "runtime-switch: pending admission lacks a locked one-shot worker kick"
PENDING_SET_NO_KICK="$(printf '%s\n' "$PENDING_SET_BLOCK" |
  sed 's/schedule_work(&bridge_pending_work);/\/\* missing admission kick \*\//')"
if check_pending_admission_kick_contract "$PENDING_SET_NO_KICK"; then
  fail "runtime-switch: lost admission-edge mutation accepted"
fi
printf 'PASS: runtime-switch pending admission-edge mutation rejected\n'

check_pending_switch_event_contract "$PENDING_BEGIN_BLOCK" \
  "$PENDING_SCHEDULER_BLOCK" "$PENDING_RESTORE_BLOCK" "$BRIDGE_INIT_BLOCK" \
  "$NETDEV_EVENT_BLOCK" ||
  fail "runtime-switch: switching-event coalescing/replay suppression missing"
PENDING_SCHEDULER_NO_REMEMBER="$(printf '%s\n' "$PENDING_SCHEDULER_BLOCK" |
  sed 's/bridge_pending_event_during_switch = true;/\/\* lost switching edge \*\//')"
if check_pending_switch_event_contract "$PENDING_BEGIN_BLOCK" \
    "$PENDING_SCHEDULER_NO_REMEMBER" "$PENDING_RESTORE_BLOCK" \
    "$BRIDGE_INIT_BLOCK" "$NETDEV_EVENT_BLOCK"; then
  fail "runtime-switch: lost switching-edge mutation accepted"
fi
printf 'PASS: runtime-switch pending switching-edge mutation rejected\n'
PENDING_RESTORE_NO_KICK="$(printf '%s\n' "$PENDING_RESTORE_BLOCK" |
  sed 's/schedule_work(&bridge_pending_work);/\/\* missing coalesced retry \*\//')"
if check_pending_switch_event_contract "$PENDING_BEGIN_BLOCK" \
    "$PENDING_SCHEDULER_BLOCK" "$PENDING_RESTORE_NO_KICK" \
    "$BRIDGE_INIT_BLOCK" "$NETDEV_EVENT_BLOCK"; then
  fail "runtime-switch: switching-to-waiting lost-edge mutation accepted"
fi
printf 'PASS: runtime-switch pending restore-kick mutation rejected\n'
NOTIFIER_REPLAY_ALWAYS_PUBLISHED="$(printf '%s\n' "$NETDEV_EVENT_BLOCK" |
  sed 's/atomic_read(&br->published)/true/')"
if check_pending_switch_event_contract "$PENDING_BEGIN_BLOCK" \
    "$PENDING_SCHEDULER_BLOCK" "$PENDING_RESTORE_BLOCK" "$BRIDGE_INIT_BLOCK" \
    "$NOTIFIER_REPLAY_ALWAYS_PUBLISHED"; then
  fail "runtime-switch: rollback notifier replay mutation accepted"
fi
printf 'PASS: runtime-switch rollback notifier-replay mutation rejected\n'

check_same_target_compat_contract "$SWITCH_BLOCK" ||
  fail "runtime-switch: strict same-target validation/cancellation split missing"
SWITCH_SAME_TARGET_UNCONDITIONAL="$(printf '%s\n' "$SWITCH_BLOCK" |
  sed 's/same_target && !expected_generation/same_target/')"
if check_same_target_compat_contract "$SWITCH_SAME_TARGET_UNCONDITIONAL"; then
  fail "runtime-switch: unconditional early same-target no-op mutation accepted"
fi
printf 'PASS: runtime-switch strict same-target mutation rejected\n'
SWITCH_SAME_TARGET_DEFERRED="$(printf '%s\n' "$SWITCH_BLOCK" |
  sed 's/!same_target/true/')"
if check_same_target_compat_contract "$SWITCH_SAME_TARGET_DEFERRED"; then
  fail "runtime-switch: unhealthy active-name deferred mutation accepted"
fi
printf 'PASS: runtime-switch active-name defer mutation rejected\n'

check_pending_identity_invalidation_contract "$NETDEV_EVENT_BLOCK" \
  "$PENDING_SCHEDULER_BLOCK" "$SWITCH_BLOCK" ||
  fail "runtime-switch: rename/unregister does not synchronously invalidate pending identity"
PENDING_SCHEDULER_NO_RENAME_CANCEL="$(printf '%s\n' "$PENDING_SCHEDULER_BLOCK" |
  sed 's/event == NETDEV_CHANGENAME/event == NETDEV_CHANGE/')"
if check_pending_identity_invalidation_contract "$NETDEV_EVENT_BLOCK" \
    "$PENDING_SCHEDULER_NO_RENAME_CANCEL" "$SWITCH_BLOCK"; then
  fail "runtime-switch: rename/name-reuse cancellation mutation accepted"
fi
printf 'PASS: runtime-switch rename/name-reuse mutation rejected\n'
SWITCH_NO_RTNL_GENERATION_RECHECK="$(printf '%s\n' "$SWITCH_BLOCK" | awk '
  /moal_bridge_pending_matches\(ifname, expected_generation\)/ {
    matches++
    if (matches == 2) {
      sub(/moal_bridge_pending_matches\(ifname, expected_generation\)/, "true")
    }
  }
  { print }
')"
if check_pending_identity_invalidation_contract "$NETDEV_EVENT_BLOCK" \
    "$PENDING_SCHEDULER_BLOCK" "$SWITCH_NO_RTNL_GENERATION_RECHECK"; then
  fail "runtime-switch: name-reuse generation-recheck mutation accepted"
fi
printf 'PASS: runtime-switch name-reuse generation-recheck mutation rejected\n'
PENDING_SCHEDULER_NO_NETNS="$(printf '%s\n' "$PENDING_SCHEDULER_BLOCK" |
  sed 's/!dev || dev_net(dev) != &init_net/!dev/')"
if check_pending_identity_invalidation_contract "$NETDEV_EVENT_BLOCK" \
    "$PENDING_SCHEDULER_NO_NETNS" "$SWITCH_BLOCK"; then
  fail "runtime-switch: cross-netns pending cancellation mutation accepted"
fi
printf 'PASS: runtime-switch cross-netns event mutation rejected\n'
PENDING_SCHEDULER_BLIND_RENAME="$(printf '%s\n' "$PENDING_SCHEDULER_BLOCK" |
  sed 's/__dev_get_by_name(&init_net, cancelled_ifname)/false/')"
if check_pending_identity_invalidation_contract "$NETDEV_EVENT_BLOCK" \
    "$PENDING_SCHEDULER_BLIND_RENAME" "$SWITCH_BLOCK"; then
  fail "runtime-switch: unrelated rename cancellation mutation accepted"
fi
printf 'PASS: runtime-switch unrelated rename mutation rejected\n'
PENDING_SCHEDULER_LOOKUP_UNDER_LOCK="$(printf '%s\n' "$PENDING_SCHEDULER_BLOCK" | awk '
  /spin_unlock_irqrestore\(&bridge_pending_lock, flags\)/ {
    unlocks++
    if (unlocks == 2 && !saved) {
      saved=$0
      next
    }
  }
  /__dev_get_by_name\(&init_net, cancelled_ifname\)/ && saved && !moved {
    print
    print saved
    moved=1
    next
  }
  { print }
  END { exit !moved }
')"
if check_pending_identity_invalidation_contract "$NETDEV_EVENT_BLOCK" \
    "$PENDING_SCHEDULER_LOOKUP_UNDER_LOCK" "$SWITCH_BLOCK"; then
  fail "runtime-switch: pending-name lookup-under-spinlock mutation accepted"
fi
printf 'PASS: runtime-switch notifier lookup lock mutation rejected\n'

check_pending_handle_invalidation_contract "$PENDING_INVALIDATE_HANDLE_BLOCK" \
  "$DRV_MODE_BLOCK" "$POST_RESET_BLOCK" "$PCIE_FLR_BLOCK" "$SDIO_FLR_BLOCK" ||
  fail "runtime-switch: destructive interface recreation does not invalidate pending identity"
DRV_MODE_NO_PENDING_INVALIDATE="$(printf '%s\n' "$DRV_MODE_BLOCK" |
  sed 's/moal_bridge_pending_invalidate_handle(handle);/\/\* missing pending identity invalidation *\//')"
if check_pending_handle_invalidation_contract "$PENDING_INVALIDATE_HANDLE_BLOCK" \
    "$DRV_MODE_NO_PENDING_INVALIDATE" "$POST_RESET_BLOCK" \
    "$PCIE_FLR_BLOCK" "$SDIO_FLR_BLOCK"; then
  fail "runtime-switch: driver-mode recreation invalidation mutation accepted"
fi
printf 'PASS: runtime-switch driver-mode identity mutation rejected\n'
POST_RESET_NO_PENDING_INVALIDATE="$(printf '%s\n' "$POST_RESET_BLOCK" |
  sed 's/moal_bridge_pending_invalidate_handle(handle);/\/\* missing pending identity invalidation *\//')"
if check_pending_handle_invalidation_contract "$PENDING_INVALIDATE_HANDLE_BLOCK" \
    "$DRV_MODE_BLOCK" "$POST_RESET_NO_PENDING_INVALIDATE" \
    "$PCIE_FLR_BLOCK" "$SDIO_FLR_BLOCK"; then
  fail "runtime-switch: post-reset recreation invalidation mutation accepted"
fi
printf 'PASS: runtime-switch post-reset identity mutation rejected\n'
PCIE_FLR_NO_PENDING_INVALIDATE="$(printf '%s\n' "$PCIE_FLR_BLOCK" |
  sed 's/moal_bridge_pending_invalidate_handle(handle);/\/\* missing pending identity invalidation *\//')"
if check_pending_handle_invalidation_contract "$PENDING_INVALIDATE_HANDLE_BLOCK" \
    "$DRV_MODE_BLOCK" "$POST_RESET_BLOCK" "$PCIE_FLR_NO_PENDING_INVALIDATE" \
    "$SDIO_FLR_BLOCK"; then
  fail "runtime-switch: PCIe FLR recreation invalidation mutation accepted"
fi
printf 'PASS: runtime-switch PCIe FLR identity mutation rejected\n'
SDIO_FLR_NO_PENDING_INVALIDATE="$(printf '%s\n' "$SDIO_FLR_BLOCK" |
  sed 's/moal_bridge_pending_invalidate_handle(handle);/\/\* missing pending identity invalidation *\//')"
if check_pending_handle_invalidation_contract "$PENDING_INVALIDATE_HANDLE_BLOCK" \
    "$DRV_MODE_BLOCK" "$POST_RESET_BLOCK" "$PCIE_FLR_BLOCK" \
    "$SDIO_FLR_NO_PENDING_INVALIDATE"; then
  fail "runtime-switch: SDIO FLR recreation invalidation mutation accepted"
fi
printf 'PASS: runtime-switch SDIO FLR identity mutation rejected\n'

check_pending_module_notifier_contract "$PENDING_MODULE_NB_BLOCK" \
  "$PENDING_MODULE_NOTIFIER_BLOCK" "$PENDING_START_BLOCK" \
  "$PENDING_CLEANUP_BLOCK" "$SUSPEND_SCOPE_BLOCK" ||
  fail "runtime-switch: module-lifetime pending identity notifier missing"
START_ENABLE_WITHOUT_REGISTER="$(printf '%s\n' "$PENDING_START_BLOCK" |
  sed 's/if (register_netdevice_notifier(&bridge_pending_nb))/if (0)/')"
if check_pending_module_notifier_contract "$PENDING_MODULE_NB_BLOCK" \
    "$PENDING_MODULE_NOTIFIER_BLOCK" "$START_ENABLE_WITHOUT_REGISTER" \
    "$PENDING_CLEANUP_BLOCK" "$SUSPEND_SCOPE_BLOCK"; then
  fail "runtime-switch: admission-without-identity-notifier mutation accepted"
fi
printf 'PASS: runtime-switch module notifier registration mutation rejected\n'
START_FAIL_OPEN_GUARD="$(printf '%s\n' "$PENDING_START_BLOCK" |
  sed 's/if (register_netdevice_notifier(&bridge_pending_nb))/if (!register_netdevice_notifier(\&bridge_pending_nb))/')"
if check_pending_module_notifier_contract "$PENDING_MODULE_NB_BLOCK" \
    "$PENDING_MODULE_NOTIFIER_BLOCK" "$START_FAIL_OPEN_GUARD" \
    "$PENDING_CLEANUP_BLOCK" "$SUSPEND_SCOPE_BLOCK"; then
  fail "runtime-switch: fail-open registration guard mutation accepted"
fi
printf 'PASS: runtime-switch fail-open registration mutation rejected\n'
CLEANUP_NO_NOTIFIER_UNREGISTER="$(printf '%s\n' "$PENDING_CLEANUP_BLOCK" |
  sed 's/unregister_netdevice_notifier(&bridge_pending_nb);/\/\* leaked module notifier *\//')"
if check_pending_module_notifier_contract "$PENDING_MODULE_NB_BLOCK" \
    "$PENDING_MODULE_NOTIFIER_BLOCK" "$PENDING_START_BLOCK" \
    "$CLEANUP_NO_NOTIFIER_UNREGISTER" "$SUSPEND_SCOPE_BLOCK"; then
  fail "runtime-switch: module notifier unload-leak mutation accepted"
fi
printf 'PASS: runtime-switch module notifier unload mutation rejected\n'
MODULE_NOTIFIER_NO_UNREGISTER_EVENT="$(printf '%s\n' "$PENDING_MODULE_NOTIFIER_BLOCK" |
  sed 's/event == NETDEV_UNREGISTER/0/')"
if check_pending_module_notifier_contract "$PENDING_MODULE_NB_BLOCK" \
    "$MODULE_NOTIFIER_NO_UNREGISTER_EVENT" "$PENDING_START_BLOCK" \
    "$PENDING_CLEANUP_BLOCK" "$SUSPEND_SCOPE_BLOCK"; then
  fail "runtime-switch: module notifier unregister-event mutation accepted"
fi
printf 'PASS: runtime-switch module notifier identity-event mutation rejected\n'
SUSPEND_DISABLES_IDENTITY_DELIVERY="$(printf '%s\n' "$SUSPEND_SCOPE_BLOCK" |
  sed 's/__moal_bridge_deinit_locked(bridge_owner);/unregister_netdevice_notifier(\&bridge_pending_nb);\n\t__moal_bridge_deinit_locked(bridge_owner);/')"
if check_pending_module_notifier_contract "$PENDING_MODULE_NB_BLOCK" \
    "$PENDING_MODULE_NOTIFIER_BLOCK" "$PENDING_START_BLOCK" \
    "$PENDING_CLEANUP_BLOCK" "$SUSPEND_DISABLES_IDENTITY_DELIVERY"; then
  fail "runtime-switch: suspension identity-delivery-loss mutation accepted"
fi
printf 'PASS: runtime-switch suspension identity-delivery mutation rejected\n'

check_single_source_identity_contract "$NETDEV_EVENT_BLOCK" ||
  fail "runtime-switch: instance notifier must deliver readiness edges only"
NOTIFIER_FORWARDS_SYNTH_UNREGISTER="$(printf '%s\n' "$NETDEV_EVENT_BLOCK" |
  sed 's/event == NETDEV_CHANGE)$/event == NETDEV_CHANGE || event == NETDEV_UNREGISTER)/')"
if check_single_source_identity_contract "$NOTIFIER_FORWARDS_SYNTH_UNREGISTER"; then
  fail "runtime-switch: synthesized-unregister forwarding mutation accepted"
fi
printf 'PASS: runtime-switch synthesized-unregister forwarding mutation rejected\n'
CLEANUP_UNREGISTER_AFTER_DRAIN="$(printf '%s\n' "$PENDING_CLEANUP_BLOCK" | awk '
  /if \(bridge_pending_nb_registered\) \{/ { hold=1 }
  hold { buf=buf $0 "\n"; if ($0 ~ /^\t\}$/) hold=0; next }
  { print }
  /cancel_work_sync\(&bridge_pending_work\);/ { printf "%s", buf }
')"
if check_pending_module_notifier_contract "$PENDING_MODULE_NB_BLOCK" \
    "$PENDING_MODULE_NOTIFIER_BLOCK" "$PENDING_START_BLOCK" \
    "$CLEANUP_UNREGISTER_AFTER_DRAIN" "$SUSPEND_SCOPE_BLOCK"; then
  fail "runtime-switch: unregister-after-drain replay-window mutation accepted"
fi
printf 'PASS: runtime-switch cleanup replay-window mutation rejected\n'

check_pcie_flr_unsupported_noop_contract "$PCIE_FLR_BLOCK" ||
  fail "runtime-switch: unsupported PCIe chipset FLR must stay a no-op success"
PCIE_FLR_UNSUPPORTED_FATAL="$(printf '%s\n' "$PCIE_FLR_BLOCK" | awk '
  /!IS_PCIE9098\(handle->card_type\)\) \{/ { gate=1 }
  gate && !done && /return MLAN_STATUS_SUCCESS;/ {
    sub(/MLAN_STATUS_SUCCESS/, "MLAN_STATUS_FAILURE")
    done=1
  }
  { print }
')"
if check_pcie_flr_unsupported_noop_contract "$PCIE_FLR_UNSUPPORTED_FATAL"; then
  fail "runtime-switch: unsupported-chipset fatal FLR mutation accepted"
fi
printf 'PASS: runtime-switch unsupported-chipset FLR mutation rejected\n'

check_pcie_flr_republish_contract "$PCIE_RESUME_BLOCK" "$PCIE_DONE_BLOCK" \
  "$PCIE_NOTIFY_BLOCK" "$PCIE_WORK_BLOCK" ||
  fail "runtime-switch: no-op FLR paths do not republish producer gates"
PCIE_RESUME_NO_REPUBLISH="$(printf '%s\n' "$PCIE_RESUME_BLOCK" | awk '
  /woal_do_flr_locked\(handle, false, false\)/ { flr=1 }
  flr && !cut && /woal_pcie_resume_gate\(handle\)/ {
    sub(/woal_pcie_resume_gate\(handle\)/, "MLAN_STATUS_SUCCESS")
    cut=1
  }
  { print }
')"
if check_pcie_flr_republish_contract "$PCIE_RESUME_NO_REPUBLISH" \
    "$PCIE_DONE_BLOCK" "$PCIE_NOTIFY_BLOCK" "$PCIE_WORK_BLOCK"; then
  fail "runtime-switch: resume republication-loss mutation accepted"
fi
printf 'PASS: runtime-switch resume republication mutation rejected\n'
PCIE_DONE_NO_REPUBLISH="$(printf '%s\n' "$PCIE_DONE_BLOCK" | awk '
  !cut && /MLAN_STATUS_SUCCESS == woal_pcie_resume_gate\(handle\)\)/ {
    sub(/MLAN_STATUS_SUCCESS == woal_pcie_resume_gate\(handle\)\)/,
        "MLAN_STATUS_SUCCESS)")
    cut=1
  }
  { print }
')"
if check_pcie_flr_republish_contract "$PCIE_RESUME_BLOCK" \
    "$PCIE_DONE_NO_REPUBLISH" "$PCIE_NOTIFY_BLOCK" "$PCIE_WORK_BLOCK"; then
  fail "runtime-switch: reset-done republication-loss mutation accepted"
fi
printf 'PASS: runtime-switch reset-done republication mutation rejected\n'

check_pending_terminal_cancel_contract "$PENDING_CANCEL_ALL_BLOCK" "$SWITCH_BLOCK" \
  "$DRV_MODE_BLOCK" "$REQUEST_RELOAD_BLOCK" "$FORGET_HANDLE_BLOCK" \
  "$DISCARD_SUSPENDED_BLOCK" "$RESUME_SUSPENDED_BLOCK" ||
  fail "runtime-switch: terminal no-owner paths do not clear pending"
SWITCH_NO_TERMINAL_PENDING_CLEAR="$(printf '%s\n' "$SWITCH_BLOCK" |
  sed 's/moal_bridge_pending_cancel_all("runtime switch rollback failure");/\/\* stale pending *\//')"
if check_pending_terminal_cancel_contract "$PENDING_CANCEL_ALL_BLOCK" \
    "$SWITCH_NO_TERMINAL_PENDING_CLEAR" "$DRV_MODE_BLOCK" \
    "$REQUEST_RELOAD_BLOCK" "$FORGET_HANDLE_BLOCK" "$DISCARD_SUSPENDED_BLOCK" \
    "$RESUME_SUSPENDED_BLOCK"; then
  fail "runtime-switch: rollback-failure pending mutation accepted"
fi
printf 'PASS: runtime-switch rollback-failure pending mutation rejected\n'
DRV_MODE_UNRELATED_TERMINAL_CLEAR="$(printf '%s\n' "$DRV_MODE_BLOCK" |
  sed '/^[[:space:]]*if (destructive) {/a\
\t\tmoal_bridge_pending_cancel_all("driver-mode terminal failure");')"
if check_pending_terminal_cancel_contract "$PENDING_CANCEL_ALL_BLOCK" "$SWITCH_BLOCK" \
    "$DRV_MODE_UNRELATED_TERMINAL_CLEAR" "$REQUEST_RELOAD_BLOCK" \
    "$FORGET_HANDLE_BLOCK" "$DISCARD_SUSPENDED_BLOCK" \
    "$RESUME_SUSPENDED_BLOCK"; then
  fail "runtime-switch: unrelated driver-mode pending-clear mutation accepted"
fi
printf 'PASS: runtime-switch unrelated driver-mode pending-clear mutation rejected\n'
RELOAD_NO_TERMINAL_PENDING_CLEAR="$(printf '%s\n' "$REQUEST_RELOAD_BLOCK" |
  sed 's/moal_bridge_pending_cancel_all("firmware reload terminal failure");/\/\* stale pending *\//')"
if check_pending_terminal_cancel_contract "$PENDING_CANCEL_ALL_BLOCK" "$SWITCH_BLOCK" \
    "$DRV_MODE_BLOCK" "$RELOAD_NO_TERMINAL_PENDING_CLEAR" "$FORGET_HANDLE_BLOCK" \
    "$DISCARD_SUSPENDED_BLOCK" "$RESUME_SUSPENDED_BLOCK"; then
  fail "runtime-switch: reload terminal pending mutation accepted"
fi
printf 'PASS: runtime-switch reload terminal pending mutation rejected\n'
DISCARD_NO_TERMINAL_PENDING_CLEAR="$(printf '%s\n' "$DISCARD_SUSPENDED_BLOCK" |
  sed 's/moal_bridge_pending_cancel_all("suspended owner discarded");/\/\* stale pending *\//')"
if check_pending_terminal_cancel_contract "$PENDING_CANCEL_ALL_BLOCK" "$SWITCH_BLOCK" \
    "$DRV_MODE_BLOCK" "$REQUEST_RELOAD_BLOCK" "$FORGET_HANDLE_BLOCK" \
    "$DISCARD_NO_TERMINAL_PENDING_CLEAR" "$RESUME_SUSPENDED_BLOCK"; then
  fail "runtime-switch: suspended-owner terminal pending mutation accepted"
fi
printf 'PASS: runtime-switch suspended-owner terminal pending mutation rejected\n'
DISCARD_WITHOUT_VALID_OWNER="$(printf '%s\n' "$DISCARD_SUSPENDED_BLOCK" |
  sed 's/if (!bridge_suspended_owner.valid)/if (false)/')"
if check_pending_terminal_cancel_contract "$PENDING_CANCEL_ALL_BLOCK" "$SWITCH_BLOCK" \
    "$DRV_MODE_BLOCK" "$REQUEST_RELOAD_BLOCK" "$FORGET_HANDLE_BLOCK" \
    "$DISCARD_WITHOUT_VALID_OWNER" "$RESUME_SUSPENDED_BLOCK"; then
  fail "runtime-switch: suspended-owner validity-guard mutation accepted"
fi
printf 'PASS: runtime-switch suspended-owner validity mutation rejected\n'
RESUME_NO_TERMINAL_PENDING_CLEAR="$(printf '%s\n' "$RESUME_SUSPENDED_BLOCK" |
  sed 's/moal_bridge_pending_cancel_all("suspended owner resume failure");/\/\* stale pending *\//')"
if check_pending_terminal_cancel_contract "$PENDING_CANCEL_ALL_BLOCK" "$SWITCH_BLOCK" \
    "$DRV_MODE_BLOCK" "$REQUEST_RELOAD_BLOCK" "$FORGET_HANDLE_BLOCK" \
    "$DISCARD_SUSPENDED_BLOCK" "$RESUME_NO_TERMINAL_PENDING_CLEAR"; then
  fail "runtime-switch: suspended-owner resume-failure mutation accepted"
fi
printf 'PASS: runtime-switch suspended-owner resume-failure mutation rejected\n'

check_worker_rejection_log_contract "$REQUEST_REJECTION_LOG_BLOCK" "$SWITCH_BLOCK" ||
  fail "runtime-switch: generation-backed worker rejection logs at MERROR"
WORKER_LOGGER_NO_GUARD="$(printf '%s\n' "$REQUEST_REJECTION_LOG_BLOCK" |
  sed 's/if (expected_generation)/if (false)/')"
if check_worker_rejection_log_contract "$WORKER_LOGGER_NO_GUARD" "$SWITCH_BLOCK"; then
  fail "runtime-switch: worker transient MERROR mutation accepted"
fi
printf 'PASS: runtime-switch worker transient-log mutation rejected\n'

check_bridge_bool_parser_contract "$PARSE_BRIDGE_BOOL_BLOCK" "$CONF_PARSER_BLOCK" ||
  fail "runtime-switch: mod_para runtime boolean parser is not lexically strict"
check_bridge_bool_fixture_contract ||
  fail "runtime-switch: malformed deferred mod_para fixtures accepted"
BRIDGE_BOOL_NO_TERMINAL="$(printf '%s\n' "$PARSE_BRIDGE_BOOL_BLOCK" |
  sed 's/line\[key_len + 2\]/line[key_len + 1]/')"
if check_bridge_bool_parser_contract "$BRIDGE_BOOL_NO_TERMINAL" "$CONF_PARSER_BLOCK"; then
  fail "runtime-switch: malformed multi-character boolean mutation accepted"
fi
printf 'PASS: runtime-switch mod_para lexical mutation rejected\n'
CONF_PARSER_PREFIX_KEY="$(printf '%s\n' "$CONF_PARSER_BLOCK" |
  sed 's/bridge_runtime_deferred=/bridge_runtime_deferred/')"
if check_bridge_bool_parser_contract "$PARSE_BRIDGE_BOOL_BLOCK" "$CONF_PARSER_PREFIX_KEY"; then
  fail "runtime-switch: deferred prefix-key mutation accepted"
fi
printf 'PASS: runtime-switch deferred prefix-key mutation rejected\n'

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

check_runtime_deferred_conf_contract "$CONF_PARSER_BLOCK" ||
  fail "runtime-switch: deferred conf contract missing"

CONF_PARSER_DEFERRED_NO_ENABLE="$(printf '%s\n' "$CONF_PARSER_BLOCK" |
  sed 's|WRITE_ONCE(bridge_runtime_deferred, 1);|/* missing deferred global gate enable */|')"
if check_runtime_deferred_conf_contract "$CONF_PARSER_DEFERRED_NO_ENABLE"; then
  fail "runtime-switch: missing deferred conf gate-enable mutation accepted"
fi
printf 'PASS: runtime-switch deferred conf gate-enable mutation rejected\n'

CONF_PARSER_DEFERRED_NO_RANGE="$(printf '%s\n' "$CONF_PARSER_BLOCK" |
  sed 's/out_data != 0 && out_data != 1/out_data < 0/')"
if check_runtime_deferred_conf_contract "$CONF_PARSER_DEFERRED_NO_RANGE"; then
  fail "runtime-switch: deferred conf range-check mutation accepted"
fi
printf 'PASS: runtime-switch deferred conf range-check mutation rejected\n'

check_runtime_deferred_param_contract ||
  fail "runtime-switch: deferred module parameter validator missing"

DEFERRED_PARAM_NO_RANGE="$(sed 's/value != 0 && value != 1/value < 0/' "$INIT_C")"
if check_runtime_deferred_param_contract_from_source "$DEFERRED_PARAM_NO_RANGE"; then
  fail "runtime-switch: deferred module parameter range mutation accepted"
fi
printf 'PASS: runtime-switch deferred module parameter range mutation rejected\n'

DEFERRED_PARAM_NO_CALLBACK="$(sed \
  's/module_param_cb(bridge_runtime_deferred, &bridge_runtime_deferred_ops,/\/\* missing strict callback *\//' \
  "$INIT_C")"
if check_runtime_deferred_param_contract_from_source "$DEFERRED_PARAM_NO_CALLBACK"; then
  fail "runtime-switch: deferred permissive module parameter mutation accepted"
fi
printf 'PASS: runtime-switch deferred permissive module parameter mutation rejected\n'

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
             'netif_device_present' 'moal_bridge_dev_ready' 'peer_released'; do
  printf '%s\n' "$VALIDATE_BLOCK" | grep -Fq "$token" || \
    fail "runtime-switch: terminal validator missing $token"
done
check_target_readiness_split_contract "$FIND_TARGET_BLOCK" "$LINK_STATUS_BLOCK" \
  "$SWITCH_BLOCK" "$VALIDATE_BLOCK" || \
  fail "runtime-switch: structural identity and link readiness are not split"

FIND_TARGET_WITH_MEDIA="$(printf '%s\n' "$FIND_TARGET_BLOCK" | awk '
  /target->handle = handle/ && !injected {
    print "\t\t\tif (READ_ONCE(priv->media_connected) != MTRUE)"
    print "\t\t\t\treturn -ENOLINK;"
    injected=1
  }
  { print }
  END { exit !injected }
')"
if check_target_readiness_split_contract "$FIND_TARGET_WITH_MEDIA" "$LINK_STATUS_BLOCK" \
    "$SWITCH_BLOCK" "$VALIDATE_BLOCK"; then
  fail "runtime-switch: structural resolver accepted media-connected readiness mutation"
fi
printf 'PASS: runtime-switch structural media readiness mutation rejected\n'

FIND_TARGET_NO_REGISTERED="$(printf '%s\n' "$FIND_TARGET_BLOCK" |
  sed 's/NETREG_REGISTERED/NETREG_UNREGISTERING/')"
if check_target_readiness_split_contract "$FIND_TARGET_NO_REGISTERED" "$LINK_STATUS_BLOCK" \
    "$SWITCH_BLOCK" "$VALIDATE_BLOCK"; then
  fail "runtime-switch: structural resolver accepted missing registered-state mutation"
fi
printf 'PASS: runtime-switch structural registered-state mutation rejected\n'

LINK_STATUS_CARRIER_FIRST="$(printf '%s\n' "$LINK_STATUS_BLOCK" | awk '
  /if \(READ_ONCE\(target->priv->media_connected\) != MTRUE\)/ && !media {
    media=$0
    getline
    media=media "\n" $0
    next
  }
  /if \(!netif_carrier_ok\(target->dev\)\)/ && !carrier {
    carrier=$0
    getline
    carrier=carrier "\n" $0
    print carrier
    print media
    moved=1
    next
  }
  { print }
  END { exit !(media && carrier && moved) }
')"
if check_target_readiness_split_contract "$FIND_TARGET_BLOCK" "$LINK_STATUS_CARRIER_FIRST" \
    "$SWITCH_BLOCK" "$VALIDATE_BLOCK"; then
  fail "runtime-switch: readiness helper accepted carrier-before-media mutation"
fi
printf 'PASS: runtime-switch readiness ordering mutation rejected\n'
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
check_deferred_qa_contract "$(cat "$QA_SCRIPT")" || \
  fail "runtime-switch: deferred QA case/setup/cleanup contract missing"
check_deferred_pending_wire_contract "$(cat "$QA_SCRIPT")" || \
  fail "runtime-switch: pending getter empty-line/stats-none QA distinction missing"
check_pending_source_wire_contract "$PENDING_GETTER_BLOCK" "$STATS_SHOW_BLOCK" || \
  fail "runtime-switch: pending getter/stats source wire distinction missing"
check_strict_disconnected_qa_contract "$(cat "$QA_SCRIPT")" || \
  fail "runtime-switch: strict disconnected/same-target QA gate missing"
check_same_target_qa_contract "$(cat "$QA_SCRIPT")" || \
  fail "runtime-switch: strict same-target QA preconditions missing"
check_deferred_replace_qa_contract "$(cat "$QA_SCRIPT")" || \
  fail "runtime-switch: third-STA deferred replacement QA contract missing"
check_deferred_reset_qa_contract "$(cat "$QA_SCRIPT")" || \
  fail "runtime-switch: destructive reset pending-identity QA contract missing"
check_deferred_cleanup_restore_contract "$QA_CLEANUP_BLOCK" || \
  fail "runtime-switch: deferred cleanup lacks fail-closed post-restore proof"
check_deferred_docs_completion_contract || \
  fail "runtime-switch: deferred API documentation claims request acceptance is completion"
check_terminal_failure_doc_contract "$(cat "$QA_RUNBOOK")" || \
  fail "runtime-switch: terminal-failure active/pending getter documentation is swapped"
check_deferred_docs_contract || \
  fail "runtime-switch: deferred operator documentation contract missing"
for qa_case in stress same-target concurrent peer-cycle deferred-replace \
               destructive-reset-success destructive-reset-failure \
               gate-off no-active malformed reject target-down target-disconnected fault-target fault-double \
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
  /!strcmp\(br->wlan_dev->name, ifname\)/ { same=NR }
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
                'QA_CASE=destructive-reset-success' \
                'QA_CASE=destructive-reset-failure' \
                'QA_CASE=reset-interaction' 'QA_CASE=unload-interaction'; do
  grep -Fq "$evidence" "$QA_RUNBOOK" || \
    fail "runtime-switch: runbook matrix missing $evidence"
done

QA_RESTORE_BEFORE_CAPTURE="$(printf '%s\n' "$QA_CLEANUP_BLOCK" | awk '
  /capture_state "final-before-restore"/ { saved=$0; next }
  /INITIAL_BINDING.*> "\$IFACE_PARAM"/ && saved && !moved {
    print; print saved; moved=1; next
  }
  { print }
  END { exit !moved }
')"
if check_qa_cleanup_contract "$QA_RESTORE_BEFORE_CAPTURE"; then
  fail "runtime-switch: QA restore-before-evidence mutation accepted"
fi
printf 'PASS: runtime-switch QA evidence ordering mutation rejected\n'
QA_CLEANUP_NO_OWNER_PROOF="$(printf '%s\n' "$QA_CLEANUP_BLOCK" |
  sed 's/\[ "$restored_binding" = "$INITIAL_BINDING" \]/true/')"
if check_deferred_cleanup_restore_contract "$QA_CLEANUP_NO_OWNER_PROOF"; then
  fail "runtime-switch: cleanup missing restored-owner proof mutation accepted"
fi
printf 'PASS: runtime-switch QA restored-owner mutation rejected\n'
QA_CLEANUP_NO_HEALTH_PROOF="$(printf '%s\n' "$QA_CLEANUP_BLOCK" |
  sed 's/bridge_binding_healthy "$INITIAL_BINDING"/true/')"
if check_deferred_cleanup_restore_contract "$QA_CLEANUP_NO_HEALTH_PROOF"; then
  fail "runtime-switch: cleanup missing restored-health proof mutation accepted"
fi
printf 'PASS: runtime-switch QA restored-health mutation rejected\n'
QA_CLEANUP_TARGET_DOWN_EARLY="$(printf '%s\n' "$QA_CLEANUP_BLOCK" | awk '
  /restored_binding=.*read_binding/ && !moved {
    print "        ip link set dev \"$TO_IF\" down"
    moved=1
  }
  /ip link set dev "\$TO_IF" down/ { next }
  { print }
  END { exit !moved }
')"
if check_deferred_cleanup_restore_contract "$QA_CLEANUP_TARGET_DOWN_EARLY"; then
  fail "runtime-switch: cleanup target-down-before-verification mutation accepted"
fi
printf 'PASS: runtime-switch QA target-admin ordering mutation rejected\n'
QA_CLEANUP_NO_REPLACE_OWNER_GUARD="$(printf '%s\n' "$QA_CLEANUP_BLOCK" |
  sed 's/\[ "$owner_before_replace_restore" = "$REPLACE_IF" \]/false/')"
if check_deferred_cleanup_restore_contract "$QA_CLEANUP_NO_REPLACE_OWNER_GUARD"; then
  fail "runtime-switch: cleanup replacement-owner guard mutation accepted"
fi
printf 'PASS: runtime-switch QA replacement-owner guard mutation rejected\n'
STRICT_DISCONNECTED_NO_GATE="$(sed '/target-disconnected)/,/run_prevalidation_reject "\$TO_IF" 67/ {
  /require_deferred_gate 0/d
}' "$QA_SCRIPT")"
if check_strict_disconnected_qa_contract "$STRICT_DISCONNECTED_NO_GATE"; then
  fail "runtime-switch: disconnected strict-policy mutation accepted"
fi
printf 'PASS: runtime-switch strict-disconnected QA mutation rejected\n'
PENDING_EMPTY_ACCEPTS_NONE="$(sed '/^pending_is_empty()/,/^}/ {
  s/\[ -z "\$pending" \]/[ -z "$pending" ] || [ "$pending" = none ]/
}' "$QA_SCRIPT")"
if check_deferred_pending_wire_contract "$PENDING_EMPTY_ACCEPTS_NONE"; then
  fail "runtime-switch: pending getter literal-none mutation accepted"
fi
printf 'PASS: runtime-switch pending wire-format QA mutation rejected\n'
PENDING_GETTER_LITERAL_NONE="$(printf '%s\n' "$PENDING_GETTER_BLOCK" |
  sed 's/return scnprintf(buf, len, "\\n");/return scnprintf(buf, len, "none\\n");/')"
if check_pending_source_wire_contract "$PENDING_GETTER_LITERAL_NONE" "$STATS_SHOW_BLOCK"; then
  fail "runtime-switch: pending getter source literal-none mutation accepted"
fi
printf 'PASS: runtime-switch pending getter source mutation rejected\n'
STATS_PENDING_EMPTY="$(printf '%s\n' "$STATS_SHOW_BLOCK" |
  sed 's/strncpy(pending_name, "none", sizeof(pending_name));/pending_name[0] = '\''\\0'\'';/')"
if check_pending_source_wire_contract "$PENDING_GETTER_BLOCK" "$STATS_PENDING_EMPTY"; then
  fail "runtime-switch: pending stats source empty-sentinel mutation accepted"
fi
printf 'PASS: runtime-switch pending stats source mutation rejected\n'
WAITING_NO_STATS="$(sed '/^require_waiting_unchanged()/,/^}/ {
  /stats_value pending_iface/d
  /stats_value pending_state/d
}' "$QA_SCRIPT")"
if check_deferred_qa_contract "$WAITING_NO_STATS"; then
  fail "runtime-switch: waiting stats identity/state mutation accepted"
fi
printf 'PASS: runtime-switch waiting stats mutation rejected\n'
SAME_TARGET_NO_DEFERRED_GATE="$(sed '/^run_same_target()/,/^}/ {
  /require_deferred_gate 0/d
}' "$QA_SCRIPT")"
if check_same_target_qa_contract "$SAME_TARGET_NO_DEFERRED_GATE"; then
  fail "runtime-switch: same-target non-strict QA mutation accepted"
fi
printf 'PASS: runtime-switch same-target strict-gate mutation rejected\n'
SAME_TARGET_NO_PENDING_PROOF="$(sed '/^run_same_target()/,/^}/ {
  /pending_is_empty/d
  /stats_pending_is_none/d
}' "$QA_SCRIPT")"
if check_same_target_qa_contract "$SAME_TARGET_NO_PENDING_PROOF"; then
  fail "runtime-switch: same-target pending-cancellation QA mutation accepted"
fi
printf 'PASS: runtime-switch same-target no-pending mutation rejected\n'
DEFERRED_REPLACE_NO_DISTINCT="$(sed '/^run_deferred_replace()/,/^}/ {
  /"\$REPLACE_IF" != "\$TO_IF"/d
}' "$QA_SCRIPT")"
if check_deferred_replace_qa_contract "$DEFERRED_REPLACE_NO_DISTINCT"; then
  fail "runtime-switch: non-distinct replacement target mutation accepted"
fi
printf 'PASS: runtime-switch replacement distinct-target mutation rejected\n'
DEFERRED_REPLACE_NO_STALE_PROOF="$(sed '/^run_deferred_replace()/,/^}/ {
  /wait_for_ready_without_switch "\$TO_IF" "\$FROM_IF" "\$REPLACE_IF"/d
}' "$QA_SCRIPT")"
if check_deferred_replace_qa_contract "$DEFERRED_REPLACE_NO_STALE_PROOF"; then
  fail "runtime-switch: replacement stale-target readiness mutation accepted"
fi
printf 'PASS: runtime-switch replacement stale-generation mutation rejected\n'
RESET_SUCCESS_NO_REUSE_PROOF="$(sed '/^run_destructive_reset_success()/,/^}/ {
  /wait_for_ready_without_cleared_switch "\$TO_IF" "\$FROM_IF"/d
}' "$QA_SCRIPT")"
if check_deferred_reset_qa_contract "$RESET_SUCCESS_NO_REUSE_PROOF"; then
  fail "runtime-switch: destructive reset name-reuse QA mutation accepted"
fi
printf 'PASS: runtime-switch destructive-reset reuse mutation rejected\n'
RESET_FAILURE_NO_PENDING_PROOF="$(sed '/^run_destructive_reset_failure()/,/^}/ {
  /pending_is_empty/d
  /stats_pending_is_none/d
}' "$QA_SCRIPT")"
if check_deferred_reset_qa_contract "$RESET_FAILURE_NO_PENDING_PROOF"; then
  fail "runtime-switch: terminal reset pending QA mutation accepted"
fi
printf 'PASS: runtime-switch terminal-reset pending mutation rejected\n'
QA_CLEANUP_NO_STATS_PROOF="$(printf '%s\n' "$QA_CLEANUP_BLOCK" |
  sed 's/stats_pending_is_none/true/g')"
if check_deferred_cleanup_restore_contract "$QA_CLEANUP_NO_STATS_PROOF"; then
  fail "runtime-switch: cleanup missing restored pending-stats proof mutation accepted"
fi
printf 'PASS: runtime-switch QA restored pending-stats mutation rejected\n'
DOC_NO_EMPTY_GETTER="$(sed 's/empty line/literal none/g' \
  "$ROOT/docs/runtime-bridge-interface-switch.design.md")"
if check_deferred_doc_terms "$DOC_NO_EMPTY_GETTER"; then
  fail "runtime-switch: pending getter documentation mutation accepted"
fi
printf 'PASS: runtime-switch pending getter documentation mutation rejected\n'
RUNBOOK_TERMINAL_GETTERS_SWAPPED="$(sed '
  /^\*\*destructive-reset-failure (board-command case)\*\*/,/^```bash$/ {
    s/`bridge_iface=none`이고,/`bridge_iface` getter는 empty line이고,/
    s/`bridge_pending_iface` getter는 empty line/`bridge_pending_iface=none`/
  }
' "$QA_RUNBOOK")"
if check_terminal_failure_doc_contract "$RUNBOOK_TERMINAL_GETTERS_SWAPPED"; then
  fail "runtime-switch: terminal-failure getter-swap documentation mutation accepted"
fi
printf 'PASS: runtime-switch terminal-failure getter-swap mutation rejected\n'
SPEC_UNSCOPED_DEFERRED="$(sed 's/With `bridge_runtime_deferred=1`/Without an explicit policy qualifier/' \
  "$DEFERRED_SPEC")"
if check_deferred_spec_scope_contract "$SPEC_UNSCOPED_DEFERRED"; then
  fail "runtime-switch: unscoped deferred-spec mutation accepted"
fi
printf 'PASS: runtime-switch deferred spec scope mutation rejected\n'

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
grep -q 'vlan_get_protocol(skb) == htons(ETH_P_PAE)' \
  <<< "$P2W_RX_HANDLER_BLOCK3" || \
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

# Structural lookup intentionally excludes operational link state. The
# dedicated readiness helper preserves running -> association -> carrier errno
# precedence for a structurally valid target.
for token in 'm_handle\[' MLAN_BSS_TYPE_STA NETREG_REGISTERED \
             netif_device_present HardwareStatusReady fw_reseting \
             surprise_removed fw_reload driver_status; do
  printf '%s\n' "$FIND_TARGET_BLOCK" | grep -q "$token" || \
    fail "runtime-switch: structural target resolver missing $token"
done
for token in netif_running media_connected netif_carrier_ok; do
  printf '%s\n' "$LINK_STATUS_BLOCK" | grep -q "$token" || \
    fail "runtime-switch: target link readiness helper missing $token"
done

printf 'PASS: keepalive, bounded queues, worker accounting, F1 RCU drain ordering + atomic peer_released + hairpin smoke enforced\n'
