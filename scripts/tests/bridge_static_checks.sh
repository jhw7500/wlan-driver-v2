#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
BRIDGE_C="$ROOT/mlinux/moal_bridge.c"
INIT_C="$ROOT/mlinux/moal_init.c"
MAIN_H="$ROOT/mlinux/moal_main.h"
SHIM_C="$ROOT/mlinux/moal_shim.c"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
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

W2P_FAST_BLOCK="$(grep -n -A120 -m1 '^int moal_bridge_rx_fast' "$BRIDGE_C")"
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

P2W_RX_HANDLER_BLOCK="$(grep -n -A200 -m1 'moal_bridge_peer_rx_handler' "$BRIDGE_C")"
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

P2W_PACKET_TYPE_BLOCK="$(grep -n -A160 -m1 'moal_bridge_peer_pt_func' "$BRIDGE_C")"
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

DEINIT_BLOCK="$(grep -n -A90 -m1 'void moal_bridge_deinit' "$BRIDGE_C")"
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
W2P_FAST_BLOCK2="$(grep -n -A140 -m1 '^int moal_bridge_rx_fast' "$BRIDGE_C")"
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
# Scope every lookup to lines AFTER moal_bridge_deinit() starts — otherwise
# init()'s rollback cleanup (stops a partially-created kthread on error) would
# shadow the deinit occurrence and the ordering check would be nonsensical.
DEINIT_START=$(grep -n '^void moal_bridge_deinit' "$BRIDGE_C" | head -1 | cut -d: -f1)
[ -n "$DEINIT_START" ] || fail "F1: moal_bridge_deinit() not found"
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

printf 'PASS: keepalive, bounded queues, worker accounting, F1 RCU drain ordering + atomic peer_released enforced\n'
