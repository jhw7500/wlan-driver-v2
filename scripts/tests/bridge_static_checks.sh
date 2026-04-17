#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
BRIDGE_C="$ROOT/mlinux/moal_bridge.c"
INIT_C="$ROOT/mlinux/moal_init.c"
MAIN_H="$ROOT/mlinux/moal_main.h"

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
  grep -q 'skb_queue_len_lockless(&br->w2p_queue)' || \
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
  grep -q 'skb_queue_len_lockless(&br->p2w_queue)' || \
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
  grep -q 'skb_queue_len_lockless(&br->p2w_queue)' || \
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

W2P_RX_BLOCK="$(grep -n -A240 -m1 '^int moal_bridge_rx\b' "$BRIDGE_C")"
printf '%s\n' "$W2P_RX_BLOCK" | \
  grep -q 'moal_bridge_should_forward(br, skb)' || \
  fail "legacy w2p path no longer delegates to shared filter logic"
printf '%s\n' "$W2P_RX_BLOCK" | \
  grep -q 'net_xmit_eval(err)' || \
  fail "moal_bridge_rx is missing net_xmit_eval(err)"

printf '%s\n' "$W2P_RX_BLOCK" | \
  grep -q 'NET_XMIT_SUCCESS' && \
  fail "moal_bridge_rx still compares NET_XMIT_SUCCESS"

printf '%s\n' "$W2P_RX_BLOCK" | \
  grep -q 'atomic_long_inc(&br->wlan_to_peer.fwd_packets)' && \
  fail "moal_bridge_rx still increments w2p fwd_packets"

printf '%s\n' "$W2P_RX_BLOCK" | \
  grep -Eq 'atomic_long_add\([^,]+,\s*&br->wlan_to_peer\.fwd_bytes\);' && \
  fail "moal_bridge_rx still increments w2p fwd_bytes"

W2P_RX_UNICAST_XMIT_TAIL="$(printf '%s\n' "$W2P_RX_BLOCK" | grep -n -A20 -m1 'dev_queue_xmit(skb)')"
printf '%s\n' "$W2P_RX_UNICAST_XMIT_TAIL" | \
  grep -q 'skb->' && \
  fail "moal_bridge_rx unicast path accesses skb after dev_queue_xmit(skb)"

W2P_RX_MCAST_BLOCK="$(printf '%s\n' "$W2P_RX_BLOCK" | awk '
  /if \(is_multicast_ether_addr/ { inside=1 }
  inside { print }
  inside && /return 0; \/\* 원본은 커널 스택으로 \*\// { exit }
 ')"
W2P_RX_MCAST_XMIT_TAIL="$(printf '%s\n' "$W2P_RX_MCAST_BLOCK" | grep -n -A20 -m1 'dev_queue_xmit(skb2)')"
printf '%s\n' "$W2P_RX_MCAST_XMIT_TAIL" | \
  grep -Eq 'skb->|skb2->' && \
  fail "moal_bridge_rx mcast path accesses skb/skb2 after dev_queue_xmit(skb2)"

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

printf 'PASS: keepalive config, bounded bridge queues, and worker accounting are enforced\n'
