# Bridge Stability Hardening v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the nine stability/performance items defined in `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/superpowers/specs/2026-04-17-bridge-stability-hardening-v2-design.md` as a single cross-build + runtime validation cycle, one commit per item.

**Architecture:** Keep the existing bridge shape (per-direction kthreads, rx_handler preferred with packet_type fallback, always-fire keepalive hrtimer). Each task makes a targeted patch ≤20 LOC, guarded by a new or updated grep check in `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`. TDD loop per task: add failing guard → verify FAIL → patch code → verify PASS → cross-build → commit.

**Tech Stack:** Linux kernel C (moal out-of-tree module), `sk_buff` queues, `atomic_t`, `hrtimer`, rx_handler/packet_type notifier APIs, Bash grep regression checks, iMX93 cross-build via `/home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh`, target deploy via `ssh root@192.168.0.101 'bash /home/root/rsync_driver.sh'` + reboot.

**Execution order (adjusted from spec §5 so that B2 precedes B4, avoiding a two-step patch on the NETDEV_DOWN branch):**
B5 → B6 → B1 → B2 → B4 → B3 → B7 → A1 → A2 → target runtime validation.

---

## File Structure

- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.h`
  - Add `oom_drops` field to `struct moal_bridge_stats` (B5)
  - Add `atomic_t w2p_qlen` / `atomic_t p2w_qlen` to `struct moal_bridge` (B2)
  - Add `int peer_released` to `struct moal_bridge` (B1)
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c`
  - B5 clone-failure oom counters (3 sites) + deinit stat dump
  - B6 `atomic_cmpxchg` guard returns `-EBUSY`
  - B1 `NETDEV_UNREGISTER` handler/ref release + deinit flag-aware skip
  - B2 atomic qlen hard cap (3 enqueue sites, 2 dequeue sites, init, DOWN branch)
  - B4 `NETDEV_DOWN` purge (w2p + p2w queues, reset qlen)
  - B3 `pskb_may_pull` guards in `moal_bridge_rx_fast`
  - B7 `skb_share_check` in `moal_bridge_peer_pt_func` + comment fix
  - A1 `ktime_get()` gating in `moal_bridge_rx_fast`
  - A2 `RX_HANDLER_CONSUMED` path for non-self unicast in `moal_bridge_peer_rx_handler`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
  - One guard block per item; B2 replaces the existing `skb_queue_len_lockless` requirements with `atomic_inc_return` / `atomic_dec` on the new qlen fields
- Modify (final task only): `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.report.md`
  - Append the v2 runtime validation record

---

## Prerequisites (one-time check, no commit)

- [ ] **Confirm static-check script exists and currently passes**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
PASS: keepalive config, bounded bridge queues, and worker accounting are enforced
```

If FAIL here, stop — v1 hardening state is broken and must be restored before starting v2.

- [ ] **Confirm baseline cross-build succeeds**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected: `moal.ko`/`mlan.ko` rebuild with no errors.

---

## Task 1 (B5): Add `oom_drops` counter for `skb_clone` failures

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.h:28-34`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (three clone sites + deinit stats dump)

- [ ] **Step 1: Append guard block for B5 to the static-check script**

Insert immediately above the final `printf 'PASS: ...` line in `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`:

```bash
# --- v2 B5: oom_drops counter ---
grep -Eq 'atomic_long_t\s+oom_drops' "$ROOT/mlinux/moal_bridge.h" || \
  fail "oom_drops field missing from struct moal_bridge_stats"

OOM_INC_COUNT="$(grep -c 'atomic_long_inc(&.*oom_drops)' "$BRIDGE_C" || true)"
if [ "$OOM_INC_COUNT" -lt 3 ]; then
  fail "oom_drops increment sites < 3 in moal_bridge.c (got $OOM_INC_COUNT)"
fi

grep -q 'oom=%ld' "$BRIDGE_C" || fail "deinit stats dump missing oom=%ld field"
```

- [ ] **Step 2: Run the script and verify B5 guard fails**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
FAIL: oom_drops field missing from struct moal_bridge_stats
```

- [ ] **Step 3: Add `oom_drops` field to the stats struct**

Edit `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.h` — change the `struct moal_bridge_stats` definition from:

```c
struct moal_bridge_stats {
	atomic_long_t fwd_packets;   /**< Successfully forwarded */
	atomic_long_t fwd_bytes;     /**< Forwarded bytes */
	atomic_long_t dropped;       /**< Filtered/dropped */
	atomic_long_t errors;        /**< Forward failures */
};
```

to:

```c
struct moal_bridge_stats {
	atomic_long_t fwd_packets;   /**< Successfully forwarded */
	atomic_long_t fwd_bytes;     /**< Forwarded bytes */
	atomic_long_t dropped;       /**< Filtered/dropped */
	atomic_long_t errors;        /**< Forward failures */
	atomic_long_t oom_drops;     /**< skb_clone/skb_share_check OOM drops */
};
```

- [ ] **Step 4: Count `oom_drops` on the `moal_bridge_rx_fast` clone failure**

Edit `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` inside `moal_bridge_rx_fast`. Change the clone block from:

```c
	{
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
		if (skb2) {
			if (skb_queue_len_lockless(&br->w2p_queue) >=
			    MOAL_BR_W2P_QUEUE_MAX) {
				atomic_long_inc(&br->wlan_to_peer.dropped);
				dev_kfree_skb_any(skb2);
				return 0;
			}
			skb2->dev = br->peer_dev;
			skb_queue_tail(&br->w2p_queue, skb2);
			wake_up(&br->w2p_wait);
		}
	}
```

to:

```c
	{
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
		if (skb2) {
			if (skb_queue_len_lockless(&br->w2p_queue) >=
			    MOAL_BR_W2P_QUEUE_MAX) {
				atomic_long_inc(&br->wlan_to_peer.dropped);
				dev_kfree_skb_any(skb2);
				return 0;
			}
			skb2->dev = br->peer_dev;
			skb_queue_tail(&br->w2p_queue, skb2);
			wake_up(&br->w2p_wait);
		} else {
			atomic_long_inc(&br->wlan_to_peer.oom_drops);
		}
	}
```

- [ ] **Step 5: Count `oom_drops` on the legacy `moal_bridge_rx` multicast clone failure**

In the same file, locate the multicast clone block in `moal_bridge_rx`:

```c
	if (is_multicast_ether_addr(eth->h_dest)) {
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
		int err;

		if (skb2) {
```

Add an `else` arm so the block reads:

```c
	if (is_multicast_ether_addr(eth->h_dest)) {
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
		int err;

		if (skb2) {
			/* ... unchanged body ... */
		} else {
			atomic_long_inc(&br->wlan_to_peer.oom_drops);
		}
		return 0; /* 원본은 커널 스택으로 */
	}
```

(Keep the existing body — xmit + err handling — inside the `if (skb2)` block as-is.)

- [ ] **Step 6: Count `oom_drops` on the `moal_bridge_peer_rx_handler` clone failure**

In the same file, locate the p2w clone block in `moal_bridge_peer_rx_handler`:

```c
	{
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
		if (skb2) {
			if (skb_queue_len_lockless(&br->p2w_queue) >=
			    MOAL_BR_P2W_QUEUE_MAX) {
				atomic_long_inc(&br->peer_to_wlan.dropped);
				dev_kfree_skb_any(skb2);
				return RX_HANDLER_PASS;
			}
			skb2->dev = br->wlan_dev;
			skb_push(skb2, ETH_HLEN);
			skb_queue_tail(&br->p2w_queue, skb2);
			wake_up(&br->p2w_wait);
		}
	}
```

Add the `else` arm:

```c
	{
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
		if (skb2) {
			if (skb_queue_len_lockless(&br->p2w_queue) >=
			    MOAL_BR_P2W_QUEUE_MAX) {
				atomic_long_inc(&br->peer_to_wlan.dropped);
				dev_kfree_skb_any(skb2);
				return RX_HANDLER_PASS;
			}
			skb2->dev = br->wlan_dev;
			skb_push(skb2, ETH_HLEN);
			skb_queue_tail(&br->p2w_queue, skb2);
			wake_up(&br->p2w_wait);
		} else {
			atomic_long_inc(&br->peer_to_wlan.oom_drops);
		}
	}
```

- [ ] **Step 7: Extend the deinit stats dump with `oom=%ld`**

In `moal_bridge_deinit`, change the two `PRINTM(MMSG, "bridge: w2p fwd=...` / `"bridge: p2w fwd=...` calls from:

```c
	PRINTM(MMSG, "bridge: w2p fwd=%ld drop=%ld err=%ld\n",
	       atomic_long_read(&br->wlan_to_peer.fwd_packets),
	       atomic_long_read(&br->wlan_to_peer.dropped),
	       atomic_long_read(&br->wlan_to_peer.errors));
	PRINTM(MMSG, "bridge: p2w fwd=%ld drop=%ld err=%ld\n",
	       atomic_long_read(&br->peer_to_wlan.fwd_packets),
	       atomic_long_read(&br->peer_to_wlan.dropped),
	       atomic_long_read(&br->peer_to_wlan.errors));
```

to:

```c
	PRINTM(MMSG, "bridge: w2p fwd=%ld drop=%ld err=%ld oom=%ld\n",
	       atomic_long_read(&br->wlan_to_peer.fwd_packets),
	       atomic_long_read(&br->wlan_to_peer.dropped),
	       atomic_long_read(&br->wlan_to_peer.errors),
	       atomic_long_read(&br->wlan_to_peer.oom_drops));
	PRINTM(MMSG, "bridge: p2w fwd=%ld drop=%ld err=%ld oom=%ld\n",
	       atomic_long_read(&br->peer_to_wlan.fwd_packets),
	       atomic_long_read(&br->peer_to_wlan.dropped),
	       atomic_long_read(&br->peer_to_wlan.errors),
	       atomic_long_read(&br->peer_to_wlan.oom_drops));
```

- [ ] **Step 8: Re-run the static check and cross-build**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh && \
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected:

```text
PASS: keepalive config, bounded bridge queues, and worker accounting are enforced
Build completes and regenerates moal.ko / mlan.ko without compile errors
```

- [ ] **Step 9: Commit**

```bash
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 add \
  scripts/tests/bridge_static_checks.sh \
  mlinux/moal_bridge.h \
  mlinux/moal_bridge.c
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 commit -m "bridge: count skb_clone oom drops (B5)"
```

---

## Task 2 (B6): DBDC double-init returns `-EBUSY`

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (`moal_bridge_init` DBDC guard branch)

- [ ] **Step 1: Append the B6 guard to the static-check script**

Insert above the final `printf 'PASS: ...`:

```bash
# --- v2 B6: DBDC double-init returns -EBUSY ---
DBDC_BLOCK="$(grep -n -A6 -m1 'atomic_cmpxchg(&bridge_instance_active, 0, 1) != 0' "$BRIDGE_C")"
printf '%s\n' "$DBDC_BLOCK" | grep -q 'return -EBUSY;' || \
  fail "DBDC double-init guard must return -EBUSY"
printf '%s\n' "$DBDC_BLOCK" | grep -q 'MERROR' || \
  fail "DBDC double-init log level must be MERROR"
```

- [ ] **Step 2: Run the script and verify B6 guard fails**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
FAIL: DBDC double-init guard must return -EBUSY
```

- [ ] **Step 3: Change the DBDC guard return and log level**

In `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (`moal_bridge_init`), change:

```c
	/* 0. DBDC guard: 이미 다른 handle에서 bridge 활성화됨 */
	if (atomic_cmpxchg(&bridge_instance_active, 0, 1) != 0) {
		PRINTM(MMSG, "bridge: skipped (another instance already active)\n");
		return 0;
	}
```

to:

```c
	/* 0. DBDC guard: 이미 다른 handle에서 bridge 활성화됨 */
	if (atomic_cmpxchg(&bridge_instance_active, 0, 1) != 0) {
		PRINTM(MERROR,
		       "bridge: init refused, another instance already active\n");
		return -EBUSY;
	}
```

- [ ] **Step 4: Re-run the static check and cross-build**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh && \
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 add \
  scripts/tests/bridge_static_checks.sh \
  mlinux/moal_bridge.c
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 commit -m "bridge: return -EBUSY on DBDC double-init (B6)"
```

---

## Task 3 (B1): `NETDEV_UNREGISTER` releases handlers and peer ref

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.h` (`struct moal_bridge`)
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (`moal_bridge_netdev_event`, `moal_bridge_deinit`)

- [ ] **Step 1: Append the B1 guard to the static-check script**

Insert above the final `printf 'PASS: ...`:

```bash
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
```

- [ ] **Step 2: Run the script and verify B1 guard fails**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
FAIL: peer_released flag missing from struct moal_bridge
```

- [ ] **Step 3: Add `peer_released` flag to `struct moal_bridge`**

In `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.h`, inside `struct moal_bridge`, immediately after the `use_packet_type` / `peer_pt` pair, add:

```c
	/** 1 when peer handler/ref already released via NETDEV_UNREGISTER */
	int peer_released;
```

- [ ] **Step 4: Release handler and ref inside the UNREGISTER branch**

In `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (`moal_bridge_netdev_event`), change:

```c
	case NETDEV_UNREGISTER:
		PRINTM(MMSG, "bridge: peer '%s' unregistered, disabling\n",
		       dev->name);
		atomic_set(&br->active, 0);
		break;
```

to:

```c
	case NETDEV_UNREGISTER:
		PRINTM(MMSG, "bridge: peer '%s' unregistered, disabling\n",
		       dev->name);
		atomic_set(&br->active, 0);
		/* Called with RTNL held by the netdev notifier chain, so
		 * handler unregister / dev_set_promiscuity are safe here. */
		if (!br->peer_released) {
			if (br->use_packet_type)
				dev_remove_pack(&br->peer_pt);
			else
				netdev_rx_handler_unregister(br->peer_dev);
			dev_set_promiscuity(br->peer_dev, -1);
			dev_put(br->peer_dev);
			br->peer_released = 1;
		}
		break;
```

- [ ] **Step 5: Make deinit skip already-released resources**

Still in `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c`, in `moal_bridge_deinit`, change:

```c
	/* 3. ETH→WLAN 경로 해제 + promiscuous 해제 (RTNL 하에서) */
	rtnl_lock();
	if (br->use_packet_type) {
		dev_remove_pack(&br->peer_pt);
	} else {
		netdev_rx_handler_unregister(br->peer_dev);
	}
	dev_set_promiscuity(br->peer_dev, -1);
	rtnl_unlock();
```

to:

```c
	/* 3. ETH→WLAN 경로 해제 + promiscuous 해제 (RTNL 하에서).
	 *    peer_released=1이면 NETDEV_UNREGISTER 경로에서 이미 정리됨. */
	if (!br->peer_released) {
		rtnl_lock();
		if (br->use_packet_type)
			dev_remove_pack(&br->peer_pt);
		else
			netdev_rx_handler_unregister(br->peer_dev);
		dev_set_promiscuity(br->peer_dev, -1);
		rtnl_unlock();
	}
```

Then, later in the same function, change:

```c
	/* 7. peer 참조 반환 + 메모리 해제 */
	handle->bridge = NULL;
	dev_put(br->peer_dev);
	kfree(br);
```

to:

```c
	/* 7. peer 참조 반환 + 메모리 해제 */
	handle->bridge = NULL;
	if (!br->peer_released)
		dev_put(br->peer_dev);
	kfree(br);
```

- [ ] **Step 6: Re-run the static check and cross-build**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh && \
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected: both PASS.

- [ ] **Step 7: Commit**

```bash
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 add \
  scripts/tests/bridge_static_checks.sh \
  mlinux/moal_bridge.h \
  mlinux/moal_bridge.c
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 commit -m "bridge: release peer handlers and ref on NETDEV_UNREGISTER (B1)"
```

---

## Task 4 (B2): Atomic `qlen` counters replace `skb_queue_len_lockless`

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.h` (`struct moal_bridge`)
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (init, two worker loops, three enqueue sites)

- [ ] **Step 1: Update the static-check script to require atomic qlen**

Remove the three existing `skb_queue_len_lockless(...)` requirements (lines that look like `grep -q 'skb_queue_len_lockless(&br->w2p_queue)' ... || fail "w2p queue length guard missing (rx_fast)"` and the two analogous p2w ones). Replace each with its atomic counterpart, and add a global "no skb_queue_len_lockless left" check.

At the bottom (above `printf 'PASS: ...`) append:

```bash
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
```

For the earlier in-script updates (inside the rx_fast, rx_handler, and packet_type blocks), change each existing line of the form:

```bash
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -q 'skb_queue_len_lockless(&br->w2p_queue)' || \
  fail "w2p queue length guard missing (rx_fast)"
```

to:

```bash
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -q 'atomic_inc_return(&br->w2p_qlen)' || \
  fail "w2p queue length guard missing (rx_fast)"
```

Repeat the same mechanical change (`skb_queue_len_lockless(&br->p2w_queue)` → `atomic_inc_return(&br->p2w_qlen)`) for the two p2w blocks.

- [ ] **Step 2: Run the script and verify the B2 guard fails**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
FAIL: w2p_qlen atomic missing from struct moal_bridge
```

- [ ] **Step 3: Add `w2p_qlen` / `p2w_qlen` to `struct moal_bridge`**

In `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.h`, add these two fields (placed next to the corresponding queue fields). Change the existing block:

```c
	/** w2p (WLAN→ETH) */
	struct sk_buff_head w2p_queue;
	struct task_struct *w2p_thread;
	wait_queue_head_t w2p_wait;

	/** p2w (ETH→WLAN): 전용 kthread — SDIO TX 지연을 w2p와 격리 */
	struct sk_buff_head p2w_queue;
	struct task_struct *p2w_thread;
	wait_queue_head_t p2w_wait;
```

to:

```c
	/** w2p (WLAN→ETH) */
	struct sk_buff_head w2p_queue;
	atomic_t w2p_qlen;             /**< hard cap counter for w2p_queue */
	struct task_struct *w2p_thread;
	wait_queue_head_t w2p_wait;

	/** p2w (ETH→WLAN): 전용 kthread — SDIO TX 지연을 w2p와 격리 */
	struct sk_buff_head p2w_queue;
	atomic_t p2w_qlen;             /**< hard cap counter for p2w_queue */
	struct task_struct *p2w_thread;
	wait_queue_head_t p2w_wait;
```

- [ ] **Step 4: Initialize the counters in `moal_bridge_init`**

In `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c`, immediately after each `skb_queue_head_init(&br->w2p_queue);` / `skb_queue_head_init(&br->p2w_queue);` call, add an `atomic_set(...)`:

```c
	skb_queue_head_init(&br->w2p_queue);
	atomic_set(&br->w2p_qlen, 0);
```

and:

```c
	skb_queue_head_init(&br->p2w_queue);
	atomic_set(&br->p2w_qlen, 0);
```

- [ ] **Step 5: Decrement the counters in the worker loops**

In the same file, inside `moal_bridge_w2p_thread_fn`, change:

```c
		while ((skb = skb_dequeue(&br->w2p_queue)) != NULL) {
			len = skb->len;
			err = dev_queue_xmit(skb);
```

to:

```c
		while ((skb = skb_dequeue(&br->w2p_queue)) != NULL) {
			atomic_dec(&br->w2p_qlen);
			len = skb->len;
			err = dev_queue_xmit(skb);
```

Apply the equivalent one-line addition (`atomic_dec(&br->p2w_qlen);` right after `skb_dequeue`) inside `moal_bridge_p2w_thread_fn`.

- [ ] **Step 6: Replace the three enqueue-site guards**

In `moal_bridge_rx_fast`, change:

```c
			if (skb_queue_len_lockless(&br->w2p_queue) >=
			    MOAL_BR_W2P_QUEUE_MAX) {
				atomic_long_inc(&br->wlan_to_peer.dropped);
				dev_kfree_skb_any(skb2);
				return 0;
			}
			skb2->dev = br->peer_dev;
			skb_queue_tail(&br->w2p_queue, skb2);
			wake_up(&br->w2p_wait);
```

to:

```c
			if (atomic_inc_return(&br->w2p_qlen) >
			    MOAL_BR_W2P_QUEUE_MAX) {
				atomic_dec(&br->w2p_qlen);
				atomic_long_inc(&br->wlan_to_peer.dropped);
				dev_kfree_skb_any(skb2);
				return 0;
			}
			skb2->dev = br->peer_dev;
			skb_queue_tail(&br->w2p_queue, skb2);
			wake_up(&br->w2p_wait);
```

In `moal_bridge_peer_rx_handler`, change:

```c
			if (skb_queue_len_lockless(&br->p2w_queue) >=
			    MOAL_BR_P2W_QUEUE_MAX) {
				atomic_long_inc(&br->peer_to_wlan.dropped);
				dev_kfree_skb_any(skb2);
				return RX_HANDLER_PASS;
			}
			skb2->dev = br->wlan_dev;
			skb_push(skb2, ETH_HLEN);
			skb_queue_tail(&br->p2w_queue, skb2);
			wake_up(&br->p2w_wait);
```

to:

```c
			if (atomic_inc_return(&br->p2w_qlen) >
			    MOAL_BR_P2W_QUEUE_MAX) {
				atomic_dec(&br->p2w_qlen);
				atomic_long_inc(&br->peer_to_wlan.dropped);
				dev_kfree_skb_any(skb2);
				return RX_HANDLER_PASS;
			}
			skb2->dev = br->wlan_dev;
			skb_push(skb2, ETH_HLEN);
			skb_queue_tail(&br->p2w_queue, skb2);
			wake_up(&br->p2w_wait);
```

In `moal_bridge_peer_pt_func`, change:

```c
	if (skb_queue_len_lockless(&br->p2w_queue) >= MOAL_BR_P2W_QUEUE_MAX) {
		atomic_long_inc(&br->peer_to_wlan.dropped);
		dev_kfree_skb_any(skb);
		return 0;
	}
	skb->dev = br->wlan_dev;
	skb_push(skb, ETH_HLEN);
	skb_queue_tail(&br->p2w_queue, skb);
	wake_up(&br->p2w_wait);
```

to:

```c
	if (atomic_inc_return(&br->p2w_qlen) > MOAL_BR_P2W_QUEUE_MAX) {
		atomic_dec(&br->p2w_qlen);
		atomic_long_inc(&br->peer_to_wlan.dropped);
		dev_kfree_skb_any(skb);
		return 0;
	}
	skb->dev = br->wlan_dev;
	skb_push(skb, ETH_HLEN);
	skb_queue_tail(&br->p2w_queue, skb);
	wake_up(&br->p2w_wait);
```

- [ ] **Step 7: Re-run the static check and cross-build**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh && \
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected: both PASS.

- [ ] **Step 8: Commit**

```bash
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 add \
  scripts/tests/bridge_static_checks.sh \
  mlinux/moal_bridge.h \
  mlinux/moal_bridge.c
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 commit -m "bridge: hard-cap forward queues with atomic counters (B2)"
```

---

## Task 5 (B4): `NETDEV_DOWN` purges both queues and resets counters

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (`moal_bridge_netdev_event` DOWN branch)

- [ ] **Step 1: Append the B4 guard to the static-check script**

```bash
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
```

- [ ] **Step 2: Run the script and verify the B4 guard fails**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
FAIL: NETDEV_DOWN must purge w2p_queue
```

- [ ] **Step 3: Purge queues and reset counters on DOWN**

In `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (`moal_bridge_netdev_event`), change:

```c
	case NETDEV_DOWN:
		PRINTM(MMSG, "bridge: peer '%s' went down, suspending\n",
		       dev->name);
		atomic_set(&br->active, 0);
		break;
```

to:

```c
	case NETDEV_DOWN:
		PRINTM(MMSG, "bridge: peer '%s' went down, suspending\n",
		       dev->name);
		atomic_set(&br->active, 0);
		skb_queue_purge(&br->w2p_queue);
		skb_queue_purge(&br->p2w_queue);
		atomic_set(&br->w2p_qlen, 0);
		atomic_set(&br->p2w_qlen, 0);
		break;
```

- [ ] **Step 4: Re-run the static check and cross-build**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh && \
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 add \
  scripts/tests/bridge_static_checks.sh \
  mlinux/moal_bridge.c
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 commit -m "bridge: purge queues and reset qlen on NETDEV_DOWN (B4)"
```

---

## Task 6 (B3): `pskb_may_pull` guards in `moal_bridge_rx_fast`

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (`moal_bridge_rx_fast`)

- [ ] **Step 1: Append the B3 guard to the static-check script**

```bash
# --- v2 B3: pskb_may_pull guards in rx_fast ---
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -Eq 'pskb_may_pull\(skb,\s*VLAN_ETH_HLEN\)' || \
  fail "rx_fast missing VLAN header pull guard"
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -Eq 'pskb_may_pull\(skb,\s*l3_off \+ sizeof\(struct iphdr\)\)' || \
  fail "rx_fast missing IPv4 header pull guard"
```

- [ ] **Step 2: Run the script and verify the B3 guard fails**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
FAIL: rx_fast missing VLAN header pull guard
```

- [ ] **Step 3: Add a pull guard before the VLAN inner-proto read**

In `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (`moal_bridge_rx_fast`), change the VLAN branch from:

```c
	/* VLAN: extract inner proto */
	if (proto == htons(ETH_P_8021Q)) {
		if (skb->len < VLAN_ETH_HLEN)
			return 0;
		proto = ((struct vlan_hdr *)(skb->data + ETH_HLEN))->
			h_vlan_encapsulated_proto;
		l3_off = VLAN_ETH_HLEN;
	}
```

to:

```c
	/* VLAN: extract inner proto (head must be linear through VLAN tag) */
	if (proto == htons(ETH_P_8021Q)) {
		if (!pskb_may_pull(skb, VLAN_ETH_HLEN))
			return 0;
		proto = ((struct vlan_hdr *)(skb->data + ETH_HLEN))->
			h_vlan_encapsulated_proto;
		l3_off = VLAN_ETH_HLEN;
	}
```

- [ ] **Step 4: Add a pull guard before the IPv4 `iph->daddr` read**

Still in `moal_bridge_rx_fast`, change:

```c
	if (proto == htons(ETH_P_IP) && br->wlan_ipv4) {
		struct iphdr *iph;

		if (skb->len >= l3_off + sizeof(struct iphdr)) {
			iph = (struct iphdr *)(skb->data + l3_off);
			if (iph->daddr == br->wlan_ipv4) {
				BR_DBG("w2p SELF-IP skip clone dip=%pI4\n",
				       &iph->daddr);
				return 0;
			}
		}
	}
```

to:

```c
	if (proto == htons(ETH_P_IP) && br->wlan_ipv4) {
		struct iphdr *iph;

		if (pskb_may_pull(skb, l3_off + sizeof(struct iphdr))) {
			iph = (struct iphdr *)(skb->data + l3_off);
			if (iph->daddr == br->wlan_ipv4) {
				BR_DBG("w2p SELF-IP skip clone dip=%pI4\n",
				       &iph->daddr);
				return 0;
			}
		}
	}
```

- [ ] **Step 5: Re-run the static check and cross-build**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh && \
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected: both PASS.

- [ ] **Step 6: Commit**

```bash
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 add \
  scripts/tests/bridge_static_checks.sh \
  mlinux/moal_bridge.c
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 commit -m "bridge: pskb_may_pull guards before L3 reads in rx_fast (B3)"
```

---

## Task 7 (B7): `skb_share_check` in `moal_bridge_peer_pt_func`

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (`moal_bridge_peer_pt_func`)

- [ ] **Step 1: Append the B7 guard to the static-check script**

```bash
# --- v2 B7: packet_type fallback skb_share_check ---
printf '%s\n' "$P2W_PACKET_TYPE_BLOCK" | \
  grep -Eq 'skb\s*=\s*skb_share_check\(skb,\s*GFP_ATOMIC\)' || \
  fail "packet_type fallback must unshare via skb_share_check"
printf '%s\n' "$P2W_PACKET_TYPE_BLOCK" | \
  grep -q 'atomic_long_inc(&br->peer_to_wlan.oom_drops)' || \
  fail "packet_type fallback must count share_check OOM as oom_drops"
```

- [ ] **Step 2: Run the script and verify the B7 guard fails**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
FAIL: packet_type fallback must unshare via skb_share_check
```

- [ ] **Step 3: Insert `skb_share_check` before any mutation**

In `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (`moal_bridge_peer_pt_func`), change the body from:

```c
	/* media_connected + EAPOL check */
	if (!((moal_private *)br->wlan_priv)->media_connected ||
	    skb->protocol == htons(ETH_P_PAE)) {
		kfree_skb(skb);
		return 0;
	}

	/* packet_type은 이미 clone을 받으므로 p2w kthread 전송 */
	if (atomic_inc_return(&br->p2w_qlen) > MOAL_BR_P2W_QUEUE_MAX) {
```

to:

```c
	/* media_connected + EAPOL check */
	if (!((moal_private *)br->wlan_priv)->media_connected ||
	    skb->protocol == htons(ETH_P_PAE)) {
		kfree_skb(skb);
		return 0;
	}

	/* packet_type handlers receive a refcount-shared skb, not a clone;
	 * unshare before mutating skb->data via skb_push(). */
	skb = skb_share_check(skb, GFP_ATOMIC);
	if (!skb) {
		atomic_long_inc(&br->peer_to_wlan.oom_drops);
		return 0;
	}

	if (atomic_inc_return(&br->p2w_qlen) > MOAL_BR_P2W_QUEUE_MAX) {
```

(Everything below the `atomic_inc_return` line is unchanged — `skb_share_check` returned an exclusively-owned skb at this point.)

- [ ] **Step 4: Re-run the static check and cross-build**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh && \
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 add \
  scripts/tests/bridge_static_checks.sh \
  mlinux/moal_bridge.c
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 commit -m "bridge: unshare skb in packet_type fallback (B7)"
```

---

## Task 8 (A1): Gate `ktime_get()` behind `bridge_debug` in rx_fast

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (`moal_bridge_rx_fast`)

- [ ] **Step 1: Append the A1 guard to the static-check script**

```bash
# --- v2 A1: ktime_get gated by bridge_debug in rx_fast ---
printf '%s\n' "$W2P_FAST_BLOCK" | \
  awk '/ktime_get\(\)/ {found=NR} END {if (found) print found}' | \
  grep -q '.' || fail "ktime_get expected inside rx_fast"
printf '%s\n' "$W2P_FAST_BLOCK" | \
  grep -Eq '^\s*if \(bridge_debug\)\s*\{' || \
  fail "rx_fast timing block must be inside 'if (bridge_debug)'"
```

- [ ] **Step 2: Run the script and verify the A1 guard fails**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
FAIL: rx_fast timing block must be inside 'if (bridge_debug)'
```

- [ ] **Step 3: Move clock reads inside the debug gate**

In `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c`, change the top of `moal_bridge_rx_fast` from:

```c
int moal_bridge_rx_fast(struct moal_bridge *br, struct sk_buff *skb, void *priv)
{
	struct ethhdr *eth;
	__be16 proto;
	unsigned int l3_off = ETH_HLEN;
	ktime_t t_start;
	s64 dt_us;

	if (!br || !skb)
		return 0;

	t_start = ktime_get();
	eth = (struct ethhdr *)skb->data;
	proto = eth->h_proto;
```

to:

```c
int moal_bridge_rx_fast(struct moal_bridge *br, struct sk_buff *skb, void *priv)
{
	struct ethhdr *eth;
	__be16 proto;
	unsigned int l3_off = ETH_HLEN;
	ktime_t t_start = 0;

	if (!br || !skb)
		return 0;

	if (bridge_debug)
		t_start = ktime_get();

	eth = (struct ethhdr *)skb->data;
	proto = eth->h_proto;
```

Then change the tail (trailing `BR_DBG` + `dt_us` computation) from:

```c
	dt_us = ktime_to_us(ktime_sub(ktime_get(), t_start));
	BR_DBG("w2p FWD cpu=%d %lldus qlen=%d proto=0x%04x len=%d\n",
	       smp_processor_id(), dt_us, skb_queue_len(&br->w2p_queue),
	       ntohs(proto), skb->len);
	return 0; /* 원본은 커널 스택으로 */
}
```

to:

```c
	if (bridge_debug) {
		s64 dt_us = ktime_to_us(ktime_sub(ktime_get(), t_start));
		BR_DBG("w2p FWD cpu=%d %lldus qlen=%d proto=0x%04x len=%d\n",
		       smp_processor_id(), dt_us,
		       skb_queue_len(&br->w2p_queue),
		       ntohs(proto), skb->len);
	}
	return 0; /* 원본은 커널 스택으로 */
}
```

- [ ] **Step 4: Re-run the static check and cross-build**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh && \
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 add \
  scripts/tests/bridge_static_checks.sh \
  mlinux/moal_bridge.c
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 commit -m "bridge: gate rx_fast ktime_get behind bridge_debug (A1)"
```

---

## Task 9 (A2): Non-self unicast → `RX_HANDLER_CONSUMED`

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (`moal_bridge_peer_rx_handler`)

- [ ] **Step 1: Append the A2 guard to the static-check script**

```bash
# --- v2 A2: non-self unicast consumed without clone ---
printf '%s\n' "$P2W_RX_HANDLER_BLOCK" | \
  grep -Eq 'return\s+RX_HANDLER_CONSUMED' || \
  fail "rx_handler must return RX_HANDLER_CONSUMED for non-self unicast"
printf '%s\n' "$P2W_RX_HANDLER_BLOCK" | \
  grep -q '\*pskb = NULL;' || \
  fail "rx_handler must null pskb before returning CONSUMED"
```

- [ ] **Step 2: Run the script and verify the A2 guard fails**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
FAIL: rx_handler must return RX_HANDLER_CONSUMED for non-self unicast
```

- [ ] **Step 3: Add the CONSUMED branch for non-self unicast**

In `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` (`moal_bridge_peer_rx_handler`), change:

```c
	/* 유니캐스트: peer(eth0) 자기 MAC → clone 불필요, 커널 스택만 처리 */
	if (!is_multicast_ether_addr(eth->h_dest) &&
	    ether_addr_equal(eth->h_dest, br->peer_dev->dev_addr))
		return RX_HANDLER_PASS;

	/* 포워딩 대상: clone→wlan 전용 kthread 전송 (process context 필수)
	 * SDIO 반이중 버스 특성으로 softirq에서 직접 dev_queue_xmit(wlan) 시
	 * SDIO TX가 RX를 블로킹하여 reply 지연 발생 (36ms avg).
	 * 전용 p2w kthread로 w2p와 격리 + 즉시 wake-up. */
	{
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
		if (skb2) {
			if (atomic_inc_return(&br->p2w_qlen) >
			    MOAL_BR_P2W_QUEUE_MAX) {
				atomic_dec(&br->p2w_qlen);
				atomic_long_inc(&br->peer_to_wlan.dropped);
				dev_kfree_skb_any(skb2);
				return RX_HANDLER_PASS;
			}
			skb2->dev = br->wlan_dev;
			skb_push(skb2, ETH_HLEN);
			skb_queue_tail(&br->p2w_queue, skb2);
			wake_up(&br->p2w_wait);
		} else {
			atomic_long_inc(&br->peer_to_wlan.oom_drops);
		}
	}
	return RX_HANDLER_PASS;
```

to:

```c
	/* 유니캐스트: peer(eth0) 자기 MAC → clone 불필요, 커널 스택만 처리 */
	if (!is_multicast_ether_addr(eth->h_dest) &&
	    ether_addr_equal(eth->h_dest, br->peer_dev->dev_addr))
		return RX_HANDLER_PASS;

	/* 비자기 유니캐스트: 로컬 스택이 소비할 수 없는 트래픽이므로
	 * clone 없이 원본을 p2w 큐에 넘기고 CONSUMED로 반환.
	 * skb_clone/스택 deliver 두 비용을 모두 제거. */
	if (!is_multicast_ether_addr(eth->h_dest)) {
		if (atomic_inc_return(&br->p2w_qlen) > MOAL_BR_P2W_QUEUE_MAX) {
			atomic_dec(&br->p2w_qlen);
			atomic_long_inc(&br->peer_to_wlan.dropped);
			kfree_skb(skb);
			*pskb = NULL;
			return RX_HANDLER_CONSUMED;
		}
		skb->dev = br->wlan_dev;
		skb_push(skb, ETH_HLEN);
		skb_queue_tail(&br->p2w_queue, skb);
		wake_up(&br->p2w_wait);
		*pskb = NULL;
		return RX_HANDLER_CONSUMED;
	}

	/* Multicast/Broadcast: 로컬 스택도 봐야 하므로 clone + PASS.
	 * SDIO 반이중 버스 특성으로 softirq에서 직접 dev_queue_xmit(wlan) 시
	 * SDIO TX가 RX를 블로킹하여 reply 지연 발생 (36ms avg).
	 * 전용 p2w kthread로 w2p와 격리 + 즉시 wake-up. */
	{
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
		if (skb2) {
			if (atomic_inc_return(&br->p2w_qlen) >
			    MOAL_BR_P2W_QUEUE_MAX) {
				atomic_dec(&br->p2w_qlen);
				atomic_long_inc(&br->peer_to_wlan.dropped);
				dev_kfree_skb_any(skb2);
				return RX_HANDLER_PASS;
			}
			skb2->dev = br->wlan_dev;
			skb_push(skb2, ETH_HLEN);
			skb_queue_tail(&br->p2w_queue, skb2);
			wake_up(&br->p2w_wait);
		} else {
			atomic_long_inc(&br->peer_to_wlan.oom_drops);
		}
	}
	return RX_HANDLER_PASS;
```

- [ ] **Step 4: Re-run the static check and cross-build**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh && \
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 add \
  scripts/tests/bridge_static_checks.sh \
  mlinux/moal_bridge.c
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 commit -m "bridge: consume non-self unicast without clone in rx_handler (A2)"
```

---

## Task 10: Target runtime validation + report

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.report.md`

- [ ] **Step 1: Build and deploy to target**

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
ssh root@192.168.0.101 'bash /home/root/rsync_driver.sh'
ssh root@192.168.0.101 'reboot'
```

Wait for the target to come back up (about 60s), then verify bridge activated:

```bash
ssh root@192.168.0.101 'dmesg | grep "bridge:"'
```

Expected to contain:

```text
bridge: === Activated ===
```

- [ ] **Step 2: Performance non-regression (A1/A2 baseline check)**

From a wired peer and from a wireless peer, run:

```bash
ping -c 100 <target-ip>
```

Expected: avg latency within the v1 baseline (upstream/downstream ≈ 7 ms). Record min/avg/max/mdev for both directions.

- [ ] **Step 3: `oom_drops` visibility (B5)**

On the target:

```bash
ssh root@192.168.0.101 'rmmod moal'
ssh root@192.168.0.101 'dmesg | tail -20 | grep "bridge:"'
```

Expected: last two `bridge:` lines contain the `oom=N` field:

```text
bridge: w2p fwd=... drop=... err=... oom=...
bridge: p2w fwd=... drop=... err=... oom=...
```

Then reload for subsequent tests:

```bash
ssh root@192.168.0.101 'insmod /lib/modules/$(uname -r)/extra/moal.ko bridge_mode=1 bridge_peer=eth0 bridge_keepalive_ms=1'
```

(Adjust the insmod path to whatever the rsync script installs on the target.)

- [ ] **Step 4: DBDC double-init `-EBUSY` (B6)**

Attempt a second bridge init on a different interface/handle, e.g. via reinit on the same module or by loading a second moal instance if the test harness supports it. Expected: caller sees `-EBUSY`, dmesg shows `MERROR ... init refused, another instance already active`.

If the setup only supports one handle, document the attempt as N/A and leave this step unverified at runtime (static check already gates the behavior).

- [ ] **Step 5: Peer lifecycle (B1 / B4)**

```bash
ssh root@192.168.0.101 'ip link set eth0 down'
sleep 2
ssh root@192.168.0.101 'ip link set eth0 up'
sleep 2
ssh root@192.168.0.101 'dmesg | tail -20 | grep "bridge:"'
```

Expected: dmesg shows `peer 'eth0' went down, suspending` then `peer 'eth0' came up, resuming`. `w2p fwd` and `p2w fwd` counters must not grow while down (sample before and after).

If possible, additionally force a peer `NETDEV_UNREGISTER` (e.g. `rmmod` the ethernet driver when the test harness allows). Expected: `peer '...' unregistered, disabling` in dmesg and `ip link show eth0` reports no PROMISC immediately (not only at `rmmod moal` time).

- [ ] **Step 6: Append the runtime validation record to the report**

Edit `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.report.md` and append a section matching the template below, filling in real numbers and PASS/FAIL:

```markdown
## Runtime Validation (v2 hardening — 2026-04-17)

- Build: `/home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh`
- Deploy: `ssh root@192.168.0.101 'bash /home/root/rsync_driver.sh'` + `reboot`
- Module load: `bridge_mode=1 bridge_peer=eth0 bridge_keepalive_ms=1`
- Performance (wired peer ↔ target):  ping avg=__ ms mdev=__
- Performance (wireless peer ↔ target): ping avg=__ ms mdev=__
- `oom_drops` visible in dmesg on rmmod: PASS/FAIL
- DBDC double-init returns -EBUSY with MERROR log: PASS / N/A
- NETDEV_DOWN suspends forwarding, no stale packets on UP: PASS/FAIL
- NETDEV_UNREGISTER releases promisc + handler immediately: PASS / N/A
- B7 packet_type fallback: verified via static check only (runtime reproduction not attempted)
```

- [ ] **Step 7: Commit the runtime validation record**

```bash
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 add docs/driver-bridge.report.md
git -C /home/jhw/ai/opencode/projects/wlan-driver-v2 commit -m "docs: record bridge v2 runtime validation"
```

---

## Self-Review

- **Spec coverage.** Tasks 1–9 implement spec §5 items B5, B6, B1, B2, B4, B3, B7, A1, A2 in that order, and Task 10 covers spec §6.3 (target runtime validation). No spec item is unreferenced.
- **Placeholder scan.** No `TODO`/`TBD` strings. Every code-emitting step contains the actual pre- and post-change C blocks. Static-check guards are full bash fragments, not prose descriptions. Runtime report template is inline, not "add later".
- **Type consistency.** `oom_drops` is declared as `atomic_long_t` in Task 1 Step 3 and incremented via `atomic_long_inc` everywhere it appears (Task 1 steps 4–6, Task 7 step 3, Task 9 step 3). `w2p_qlen` / `p2w_qlen` are declared as `atomic_t` in Task 4 Step 3 and accessed via `atomic_inc_return` / `atomic_dec` / `atomic_set` only (consistent across Tasks 4, 5, 7, 9). `peer_released` is declared as `int` in Task 3 Step 3 and read as a plain int everywhere it appears.
- **Ordering sanity.** B2 precedes B4 so Task 5 can reset atomic qlen in the DOWN branch without a dangling reference. B5 precedes B7 and A2 so later tasks reuse `oom_drops`. B1 precedes B2/B4 but only because it is independent; reordering relative to B2/B4 is safe.
- **Guard failure messages.** Each new static-check guard has a distinct `fail "..."` message, making first-failure diagnosis unambiguous when running the script mid-task.
