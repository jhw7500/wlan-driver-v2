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
grep -Eq 'int\s+peer_released' "$ROOT/mlinux/moal_bridge.h" || \
  fail "peer_released flag missing from struct moal_bridge"

UNREG_BLOCK="$(grep -n -A20 -m1 'case NETDEV_UNREGISTER:' "$BRIDGE_C")"
printf '%s\n' "$UNREG_BLOCK" | \
  grep -Eq 'netdev_rx_handler_unregister\(br->peer_dev\)|dev_remove_pack\(&br->peer_pt\)' || \
  fail "NETDEV_UNREGISTER branch must unregister handler"
printf '%s\n' "$UNREG_BLOCK" | grep -q 'dev_set_promiscuity(br->peer_dev, -1)' || \
  fail "NETDEV_UNREGISTER branch must drop promisc"
printf '%s\n' "$UNREG_BLOCK" | grep -q 'dev_put(br->peer_dev)' || \
  fail "NETDEV_UNREGISTER branch must dev_put peer"
printf '%s\n' "$UNREG_BLOCK" | grep -q 'br->peer_released = 1' || \
  fail "NETDEV_UNREGISTER branch must set peer_released"

DEINIT_BLOCK="$(grep -n -A90 -m1 'void moal_bridge_deinit' "$BRIDGE_C")"
printf '%s\n' "$DEINIT_BLOCK" | grep -q 'if (!br->peer_released)' || \
  fail "deinit must skip handler/ref release when peer already released"

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

grep -Eq 'if \(consumed\)[[:space:]]*\{?.*continue;' "$SHIM_C" || \
grep -Eq 'if \(br_consumed\)' "$SHIM_C" || \
  fail "A-MSDU loop must honor rx_fast consumed return"

# --- v3 D4: use cached peer_mac in rx_handler ---
P2W_RX_HANDLER_BLOCK2="$(grep -n -A200 -m1 'moal_bridge_peer_rx_handler' "$BRIDGE_C")"
printf '%s\n' "$P2W_RX_HANDLER_BLOCK2" | \
  grep -q 'br->peer_dev->dev_addr' && \
  fail "rx_handler must use cached br->peer_mac, not br->peer_dev->dev_addr"
printf '%s\n' "$P2W_RX_HANDLER_BLOCK2" | \
  grep -q 'br->peer_mac' || \
  fail "rx_handler must reference cached br->peer_mac"

printf 'PASS: keepalive config, bounded bridge queues, and worker accounting are enforced\n'
