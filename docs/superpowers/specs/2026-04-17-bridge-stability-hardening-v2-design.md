# Bridge Stability Hardening v2 — Design

**Date:** 2026-04-17
**Status:** Spec (pending implementation plan via superpowers:writing-plans)
**Scope target:** `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.{c,h}` and the bridge static-check script
**Predecessors:** `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/plans/2026-04-15-driver-bridge-hardening.md` (v1, already landed)

---

## 1. Goal

Eliminate the remaining safety-critical defects in the driver-level WLAN↔ETH bridge and apply two low-risk hot-path trims, in a single cross-build + target validation cycle, without regressing the current keepalive-based latency baseline (upstream/downstream ≈ 7 ms).

The nine items below together close these failure modes:

- peer `NETDEV_UNREGISTER` leaving handlers and a stale device reference behind
- bridge skb queues growing past their nominal caps under concurrent enqueues
- out-of-bounds reads on non-linear skbs in the fast forwarding path
- stale skbs replayed after a peer DOWN/UP cycle
- `skb_clone(GFP_ATOMIC)` failures being silently dropped with no observability
- DBDC double-init reporting success instead of `-EBUSY`
- `packet_type` fallback mutating a shared skb without `skb_share_check`

Plus two hot-path trims that measurably remove work without changing externally observable behavior:

- removing `ktime_get()` from the fast path when `bridge_debug=0`
- avoiding `skb_clone` and stack re-delivery for non-self unicast traffic on the ETH→WLAN rx_handler path

## 2. Architecture Principles

1. **Keep the existing shape.** Per-direction kthreads (`w2p`, `p2w`), `rx_handler` preferred + `packet_type` fallback on the peer netdev, always-fire keepalive hrtimer, `atomic_t active` flag. No new threads, no new wait primitives, no queue replacement.
2. **Minimal patches.** Each item is an independent 5–20 LOC change. No adjacent refactoring, no drive-by comments, no opportunistic renames.
3. **No performance-path changes without measurement.** Any proposal that requires empirical validation (batch xmit, CPU affinity, kfifo) is deferred to the backlog — not in this spec.
4. **Honor previously-rejected experiments.** Activity-gated keepalive, queue cap changes past the current 512, and `skb_clone` elimination are all forbidden (see `project_bridge_status.md` — "실측으로 기각된 최적화").

## 3. Out-of-Scope (explicit)

- Activity-gated keepalive (reverted, increased ping latency)
- Queue cap tuning past 512 (no measurable effect)
- `skb_clone` removal on the WLAN→ETH path (STA-mode caller contract requires clone-always)
- Batch xmit / `xmit_more` / CPU affinity for the kthreads (measurement-gated)
- kfifo/llist rings, inline-direct xmit, NAPI polling (architecture changes)
- per-cpu / `u64_stats_t` counters, sysfs/ethtool exposure (visibility work, hot-path impact not yet evaluated)
- IPv6 self-filter symmetry (pending IPv6 deployment plan)
- Throughput/iperf3 long runs, NOHZ interaction audits, multi-BSS bridging

## 4. File Structure

Modify:
- `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` — most items
- `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.h` — struct fields (B2, B5) and optional flag (B1)

Create:
- `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh` — extend the v1 script with nine new guards (grep-based regression gates, matching the v1 hardening plan style)

Update (at the end of the cycle):
- `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.report.md` — append runtime validation record

## 5. Items

Each item is independent. Recommended order: **B5 → B6 → B1 → B4 → B2 → B3 → B7 → A1 → A2**. `B5` introduces `oom_drops`, which `B7` reuses.

### B1. `NETDEV_UNREGISTER` handler/ref release

- **Symptom.** `moal_bridge_netdev_event` currently only clears `br->active` on UNREGISTER. `rx_handler`/`packet_type`/promiscuity stay registered on the vanished netdev; `dev_put` is deferred to `moal_bridge_deinit`. Risk: use-after-free against `br->peer_dev` and dangling handler registrations.
- **Change.** In the UNREGISTER branch, unregister the handler in use (`netdev_rx_handler_unregister` or `dev_remove_pack`), call `dev_set_promiscuity(peer, -1)` under RTNL, then `dev_put(peer)` and set a new flag `br->peer_released = 1`. `moal_bridge_deinit` skips those steps when the flag is set (double-unregister guard).
- **Files.** `mlinux/moal_bridge.{c,h}`

### B2. Queue enqueue race → atomic counter hard cap

- **Symptom.** Between `skb_queue_len_lockless(&q)` and `skb_queue_tail(&q, ...)` another CPU can enqueue, so the effective cap is exceeded by up to the number of concurrent enqueuers. The `p2w` queue is especially exposed — it has two enqueue sites (`rx_handler` and `packet_type` fallback) that can fire from different CPUs.
- **Change.** Add `atomic_t w2p_qlen` and `atomic_t p2w_qlen` to `struct moal_bridge`, initialized to `0`. Enqueue path: `if (atomic_inc_return(&qlen) > MOAL_BR_*_QUEUE_MAX) { atomic_dec(&qlen); drop; }` before `skb_queue_tail`. Worker dequeue path: `atomic_dec(&qlen)` after each successful `skb_dequeue`. Remove `skb_queue_len_lockless` usages.
- **Files.** `mlinux/moal_bridge.{c,h}` (three enqueue sites, two worker loops)

### B3. `pskb_may_pull` guards in the fast path

- **Symptom.** `moal_bridge_rx_fast` reads the VLAN inner proto from `skb->data + ETH_HLEN` and `iph->daddr` from `skb->data + l3_off` without pulling. A non-linear skb can fault or return garbage for those reads.
- **Change.** Before each read, call `pskb_may_pull(skb, VLAN_ETH_HLEN)` (VLAN branch) and `pskb_may_pull(skb, l3_off + sizeof(struct iphdr))` (IPv4 branch). Pull failure → fall through to the forwarding path without the self-IP short-circuit (safe default: clone and enqueue).
- **Files.** `mlinux/moal_bridge.c` (`moal_bridge_rx_fast`)

### B4. `NETDEV_DOWN` purges both queues

- **Symptom.** On peer DOWN, `active=0` alone leaves the queues holding skbs that target the now-down peer. On peer UP (or peer replacement), those stale skbs get transmitted against a different link state, and in the worst case against a stale `net_device` pointer.
- **Change.** In the DOWN branch, after `atomic_set(&br->active, 0)`: `skb_queue_purge(&br->w2p_queue); skb_queue_purge(&br->p2w_queue);` and reset the B2 counters (`atomic_set(&br->w2p_qlen, 0)`, same for `p2w`).
- **Files.** `mlinux/moal_bridge.c` (`moal_bridge_netdev_event`)

### B5. `skb_clone` failure → `oom_drops` counter

- **Symptom.** Three sites call `skb_clone(skb, GFP_ATOMIC)` and silently skip forwarding when the allocation fails. No counter, no log, no way to detect memory pressure via `rmmod` stats.
- **Change.** Add `atomic_long_t oom_drops` to `struct moal_bridge_stats`. Every `skb_clone` NULL branch increments the corresponding direction's `oom_drops`. `moal_bridge_deinit`'s stats dump gains an `oom=%ld` field on both w2p and p2w lines.
- **Files.** `mlinux/moal_bridge.{c,h}`

### B6. DBDC double-init returns `-EBUSY`

- **Symptom.** `atomic_cmpxchg(&bridge_instance_active, 0, 1) != 0` currently logs at `MMSG` and returns `0`. The caller sees success despite no bridge being wired up.
- **Change.** Log at `MERROR` and `return -EBUSY;` from that branch. No other behavior change.
- **Files.** `mlinux/moal_bridge.c` (`moal_bridge_init` entry guard)

### B7. `packet_type` fallback `skb_share_check`

- **Symptom.** `moal_bridge_peer_pt_func` treats the incoming skb as owned but a `packet_type` handler actually receives a refcount-shared skb, not a clone. `skb_push(skb, ETH_HLEN)` then mutates `skb->data` for other shared holders (tcpdump/AF_PACKET observers), producing malformed captures and, worst case, wrong proto parsing downstream. The existing comment claims "packet_type은 이미 clone을 받으므로" which is incorrect.
- **Change.** Before any mutation: `skb = skb_share_check(skb, GFP_ATOMIC); if (!skb) { atomic_long_inc(&br->peer_to_wlan.oom_drops); return 0; }`. Everything after this point sees an exclusively-owned skb. Correct the stale comment.
- **Files.** `mlinux/moal_bridge.c` (`moal_bridge_peer_pt_func`)

### A1. Fast path `ktime_get()` gating

- **Symptom.** `moal_bridge_rx_fast` unconditionally calls `ktime_get()` at entry and computes `dt_us = ktime_to_us(ktime_sub(...))` at exit, even when `bridge_debug == 0`. Trailing `BR_DBG(...)` is gated, but the clock reads are not.
- **Change.** Wrap the timing variables and both clock reads inside `if (bridge_debug) { ... }`. The `bridge_debug=0` baseline performs zero clock reads. No struct or API change.
- **Files.** `mlinux/moal_bridge.c` (`moal_bridge_rx_fast`)

### A2. `p2w` rx_handler: non-self unicast → `RX_HANDLER_CONSUMED`

- **Symptom.** Non-self unicast frames (`dst_mac != peer_dev->dev_addr`, not multicast) currently go through `skb_clone` + `skb_queue_tail` + `RX_HANDLER_PASS`. The original is delivered up the local stack only to be dropped there (no matching socket/route), wasting both the clone allocation and the stack walk.
- **Change.** When the frame is non-multicast and non-self-MAC, take ownership without cloning: enqueue the original skb (after `skb->dev = wlan_dev; skb_push(ETH_HLEN)`), set `*pskb = NULL`, and return `RX_HANDLER_CONSUMED`. Multicast and self-MAC paths keep the existing clone + PASS semantics so the local stack still sees those frames.
- **Files.** `mlinux/moal_bridge.c` (`moal_bridge_peer_rx_handler`)

## 6. Test Strategy

### 6.1 Static checks

Extend `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh` with one guard block per item. Each guard is a `grep` that must match after the patch is applied and fails loudly before.

| Item | Required pattern |
| --- | --- |
| B1 | `NETDEV_UNREGISTER:` case contains `netdev_rx_handler_unregister\|dev_remove_pack` and sets `peer_released` |
| B2 | `atomic_t .*qlen` declared in the struct, `atomic_inc_return(.*qlen)` + `atomic_dec(.*qlen)` pairs exist, `skb_queue_len_lockless` no longer present |
| B3 | `pskb_may_pull(.*VLAN_ETH_HLEN` and `pskb_may_pull(.*l3_off.*iphdr` both exist |
| B4 | `NETDEV_DOWN:` case contains both `skb_queue_purge(&br->w2p_queue)` and `skb_queue_purge(&br->p2w_queue)` |
| B5 | `oom_drops` field declared in `struct moal_bridge_stats` and at least three `atomic_long_inc(&.*oom_drops)` call sites |
| B6 | `atomic_cmpxchg` guard branch returns `-EBUSY` |
| B7 | `skb_share_check(skb, GFP_ATOMIC)` present inside `moal_bridge_peer_pt_func` |
| A1 | `ktime_get()` call(s) inside `moal_bridge_rx_fast` appear only after an `if (bridge_debug)` line |
| A2 | `moal_bridge_peer_rx_handler` contains `RX_HANDLER_CONSUMED` (not only `RX_HANDLER_PASS`) |

Per-task TDD loop:
1. Add the guard to `bridge_static_checks.sh`.
2. Run the script — expect FAIL for the new guard.
3. Apply the patch for this item.
4. Run the script — expect PASS.
5. Run `bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh` — expect `moal.ko`/`mlan.ko` rebuilt without warnings.
6. Commit.

### 6.2 Cross-build

After every task: `bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh`. On failure, revert the task and redesign before continuing.

### 6.3 Target runtime (once, after all nine items land)

Build / deploy / apply:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
ssh root@192.168.0.101 'bash /home/root/rsync_driver.sh'
ssh root@192.168.0.101 'reboot'   # default; 'systemctl restart wifi_init' also acceptable
```

Validation checklist (record pass/fail and raw output in the report):

1. **Load/unload sanity.** `ssh root@192.168.0.101 'dmesg | grep "bridge:"'` shows `=== Activated ===`. `rmmod moal && rmmod mlan` unloads cleanly.
2. **Performance non-regression.** Bidirectional `ping -c 100` between the target and a wired peer and a wireless peer each — average latency within the current 7 ms baseline; no upward drift attributable to A1/A2.
3. **B5 visibility.** Dmesg stats at `rmmod` time include `oom=N` on both `w2p` and `p2w` lines (the counter does not need to be non-zero, only present).
4. **B6 DBDC guard.** Attempt a second bridge init on a different interface/handle; observe `-EBUSY` at the caller and a `MERROR` line in dmesg.
5. **B1/B4 peer lifecycle.**
    - `ip link set eth0 down; sleep 2; ip link set eth0 up` — w2p/p2w counters do not increment while DOWN; forwarding resumes after UP with no stale skbs (no one-off burst of out-of-date traffic).
    - Force a peer `NETDEV_UNREGISTER` (e.g. `rmmod` the peer's driver when feasible) — dmesg shows `peer '...' unregistered, disabling` *and* `ip link show eth0` no longer reports PROMISC immediately.
6. **B7 packet_type fallback.** Skipped at runtime (rx_handler preemption setup is not worth the reproduction overhead). Covered by the B7 static check only.

Results are appended to `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.report.md`.

## 7. Commit Plan

One commit per item, in the order listed in §5, each referencing the item tag (e.g. `bridge: add oom_drops counter on clone failure (B5)`). One final commit for the runtime validation record. `bridge_static_checks.sh` updates ride along with the item they guard.

## 8. Backlog (tracked separately)

Measurement-gated A:
- `p2w` batch xmit + `xmit_more`
- w2p/p2w kthread CPU affinity
- w2p workqueue vs. kthread decision (re-measure)

Architecture D:
- `sk_buff_head` → `kfifo`/`llist` lockless ring
- Inline direct xmit when queue is empty
- NAPI-style budgeted polling on p2w

Visibility C:
- `atomic_long_t` → `u64_stats_t` or per-cpu counters
- Split drop reasons (filter / overflow / oom / xmit_err)
- Read-only sysfs stats node

Other stability:
- IPv6 self-filter symmetry in `moal_bridge_rx_fast`
- `moal_bridge_inetaddr_event` NULL guard on `ifa->ifa_dev->dev`
- `skb_cow_head(skb, ETH_HLEN)` before `skb_push` as a headroom safety net
- `READ_ONCE(media_connected)` for explicit teardown-race annotation

Rejected (do not retry):
- Activity-gated keepalive (regressed ping latency)
- Queue cap beyond 512 (no measurable effect)
- `skb_clone` removal on the WLAN→ETH path (STA-mode caller contract)

## 9. Self-Review

- **Placeholder scan.** No `TODO`, `TBD`, or "add validation" placeholders. Every item has a concrete change description, file target, and static-check guard.
- **Internal consistency.** B5 introduces `oom_drops`; B7 reuses it. §5 and §6.1 both reference the same nine items in the same order. §3 and §8 both enumerate the rejected experiments; the lists match.
- **Scope.** Nine items, all touching the bridge module plus the static-check script. No caller-contract changes outside the bridge. The spec is a single implementation cycle.
- **Ambiguity.** A2 is explicit about which branch switches to `CONSUMED` (non-multicast, non-self-MAC) and which stays on `PASS` (multicast, self-MAC). B2 is explicit about the `atomic_inc_return` / `atomic_dec` protocol. B4 is explicit about purging both queues and resetting the atomic counters.
