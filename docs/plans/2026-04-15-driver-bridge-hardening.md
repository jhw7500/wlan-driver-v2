# Driver Bridge Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Harden the driver-level WLAN↔ETH bridge so queue growth is bounded, keepalive configuration is internally consistent, hot-path forwarding stats reflect real handoff outcomes, and the remaining init-path correctness leak is removed.

**Architecture:** Keep the current bridge shape in `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c`, but make four targeted changes instead of rewriting it: unify keepalive config ownership, cap both bridge skb queues, normalize `dev_queue_xmit()` result handling in the real transmit workers, and close the remaining `bridge_instance_active` early-return leak. Then update the bridge analysis/report docs so they stop overstating readiness and explicitly point to runtime validation.

**Tech Stack:** Linux kernel C, MOAL driver code, `sk_buff` queues, workqueue/kthread paths, `dev_queue_xmit()`, `net_xmit_eval()`, shell-based static checks, cross-build via `/home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh`.

---

## File Structure

- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c`
  - Keepalive timer source-of-truth, queue bounding, worker-side xmit accounting, init-path guard cleanup.
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.h`
  - Bridge queue limit constants and, if needed, minimal stat-field expansion.
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_init.c`
  - Config-file parse and `handle->params` assignment for keepalive, including explicit `0=off` behavior.
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_main.h`
  - Keepalive config presence flag in `moal_mod_para` if required to distinguish “unset” from explicit `0`.
- Create: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
  - Cheap regression checks for the exact issues found in review.
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.analysis.md`
  - Remove the misleading “0 critical gaps / 97.2% PASS” framing or qualify it correctly.
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.report.md`
  - Reframe readiness around pending runtime validation and the hardening work.

---

### Task 1: Unify keepalive configuration and make `0=off` actually work

**Files:**
- Create: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_main.h:2738-2745`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_init.c:910-917`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_init.c:1834-1851`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_init.c:3156-3157`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c:18-21`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c:36-48`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c:673-685`

- [ ] **Step 1: Write the failing static regression check**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/jhw/ai/opencode/projects/wlan-driver-v2"
BRIDGE_C="$ROOT/mlinux/moal_bridge.c"
INIT_C="$ROOT/mlinux/moal_init.c"
MAIN_H="$ROOT/mlinux/moal_main.h"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -q 'bridge_keepalive_ms_present' "$MAIN_H" || fail "keepalive presence flag missing from moal_mod_para"
grep -q 'if (params->bridge_keepalive_ms_present)' "$INIT_C" || fail "explicit keepalive override guard missing"
grep -q 'handle->params.bridge_keepalive_ms' "$BRIDGE_C" || fail "bridge code is not using handle params"
grep -q 'interval = ns_to_ktime((u64)bridge_keepalive_ms \* NSEC_PER_MSEC);' "$BRIDGE_C" && fail "timer callback still reads global bridge_keepalive_ms"

printf 'PASS: keepalive config path is internally consistent\n'
```

- [ ] **Step 2: Run the static check to verify it fails on the current tree**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
FAIL: keepalive presence flag missing from moal_mod_para
```

- [ ] **Step 3: Add an explicit presence flag to `moal_mod_para`**

Update `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_main.h` to:

```c
	/** Bridge keepalive timer interval (ms), 0=off */
	int bridge_keepalive_ms;
	/** 1 when config file explicitly sets bridge_keepalive_ms */
	int bridge_keepalive_ms_present;
} moal_mod_para;
```

- [ ] **Step 4: Parse and copy keepalive through one path only**

Update `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_init.c` in two places.

First, in the config parser block:

```c
		} else if (strncmp(line, "bridge_keepalive_ms",
				   strlen("bridge_keepalive_ms")) == 0) {
			if (parse_line_read_int(line, &out_data) !=
			    MLAN_STATUS_SUCCESS)
				goto err;
			params->bridge_keepalive_ms = out_data;
			params->bridge_keepalive_ms_present = 1;
			PRINTM(MMSG, "bridge_keepalive_ms = %d\n",
			       params->bridge_keepalive_ms);
```

Then, in the handle-parameter copy block:

```c
	handle->params.bridge_keepalive_ms = bridge_keepalive_ms;
	handle->params.bridge_keepalive_ms_present = 0;
	if (params) {
		if (params->bridge_mode)
			handle->params.bridge_mode = params->bridge_mode;
		if (params->bridge_peer[0])
			strncpy(handle->params.bridge_peer,
				params->bridge_peer,
				sizeof(handle->params.bridge_peer) - 1);
		if (params->bridge_wlan_idx)
			handle->params.bridge_wlan_idx =
				params->bridge_wlan_idx;
		if (params->bridge_keepalive_ms_present) {
			handle->params.bridge_keepalive_ms =
				params->bridge_keepalive_ms;
			handle->params.bridge_keepalive_ms_present = 1;
		}
	}
```

- [ ] **Step 5: Remove the timer callback’s global keepalive read**

Update `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` to:

```c
/** bridge_debug: runtime-changeable via /sys/module/moal/parameters/bridge_debug */
extern int bridge_debug;

static enum hrtimer_restart moal_bridge_keepalive(struct hrtimer *timer)
{
	struct moal_bridge *br = container_of(timer, struct moal_bridge,
					      keepalive_timer);
	moal_handle *handle = (moal_handle *)br->handle;
	ktime_t interval;

	if (atomic_read(&br->active) && handle->workqueue)
		queue_work(handle->workqueue, &handle->main_work);

	interval = ns_to_ktime((u64)handle->params.bridge_keepalive_ms *
			      NSEC_PER_MSEC);
	hrtimer_forward_now(timer, interval);
	return HRTIMER_RESTART;
}
```

- [ ] **Step 6: Re-run the static check and confirm it passes**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
PASS: keepalive config path is internally consistent
```

- [ ] **Step 7: Build the driver after the keepalive fix**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected:

```text
Build completes and regenerates moal.ko / mlan.ko without compile errors
```

- [ ] **Step 8: Commit**

```bash
git add \
  /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh \
  /home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_main.h \
  /home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_init.c \
  /home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c
git commit -m "fix: unify bridge keepalive configuration"
```

---

### Task 2: Bound bridge queues and make overflow behavior intentional

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.h:25-31`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.h:50-58`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c:302-310`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c:427-435`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c:473-478`

- [ ] **Step 1: Extend the static check so queue limits are required**

Append these checks to `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`:

```bash
grep -q 'MOAL_BR_W2P_QUEUE_MAX' "$ROOT/mlinux/moal_bridge.h" || fail "w2p queue max missing"
grep -q 'MOAL_BR_P2W_QUEUE_MAX' "$ROOT/mlinux/moal_bridge.h" || fail "p2w queue max missing"
grep -q 'skb_queue_len_lockless(&br->w2p_queue)' "$BRIDGE_C" || fail "w2p queue length guard missing"
grep -q 'skb_queue_len_lockless(&br->p2w_queue)' "$BRIDGE_C" || fail "p2w queue length guard missing"
```

- [ ] **Step 2: Run the static check and verify it fails before the queue changes**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
FAIL: w2p queue max missing
```

- [ ] **Step 3: Add explicit queue limits in the bridge header**

Update `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.h` to:

```c
#define MOAL_BR_W2P_QUEUE_MAX 256
#define MOAL_BR_P2W_QUEUE_MAX 256

struct moal_bridge_stats {
	atomic_long_t fwd_packets;
	atomic_long_t fwd_bytes;
	atomic_long_t dropped;
	atomic_long_t errors;
};
```

- [ ] **Step 4: Guard the WLAN→ETH enqueue path**

Replace the enqueue block in `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` with:

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
			queue_work(br->w2p_wq, &br->w2p_work);
		}
	}
```

- [ ] **Step 5: Guard both ETH→WLAN enqueue paths**

Update both p2w enqueue sites in `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` to:

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

and:

```c
	if (skb_queue_len_lockless(&br->p2w_queue) >=
	    MOAL_BR_P2W_QUEUE_MAX) {
		atomic_long_inc(&br->peer_to_wlan.dropped);
		dev_kfree_skb_any(skb);
		return 0;
	}
	skb->dev = br->wlan_dev;
	skb_push(skb, ETH_HLEN);
	skb_queue_tail(&br->p2w_queue, skb);
	wake_up(&br->p2w_wait);
```

- [ ] **Step 6: Re-run the static check and build**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh && \
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected:

```text
PASS: keepalive config path is internally consistent
Build completes and regenerates moal.ko / mlan.ko without compile errors
```

- [ ] **Step 7: Commit**

```bash
git add \
  /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh \
  /home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.h \
  /home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c
git commit -m "fix: bound bridge skb queues"
```

---

### Task 3: Count successful handoff, not just enqueue intent

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c:55-73`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c:82-113`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c:302-310`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c:427-435`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c:473-478`

- [ ] **Step 1: Extend the static check so worker-side accounting is required**

Append these checks to `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`:

```bash
grep -q 'net_xmit_eval(err)' "$BRIDGE_C" || fail "net_xmit_eval usage missing"
grep -q 'atomic_long_add(skb->len, &br->wlan_to_peer.fwd_bytes);' "$BRIDGE_C" || fail "w2p byte accounting missing"
grep -q 'atomic_long_add(skb->len, &br->peer_to_wlan.fwd_bytes);' "$BRIDGE_C" || fail "p2w byte accounting missing"
```

- [ ] **Step 2: Run the static check and verify it fails before the worker rewrite**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
FAIL: net_xmit_eval usage missing
```

- [ ] **Step 3: Remove enqueue-time forward counters from the hot path**

Delete these lines from `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c`:

```c
atomic_long_inc(&br->wlan_to_peer.fwd_packets);
atomic_long_inc(&br->peer_to_wlan.fwd_packets);
```

Keep the drop/error counters, but move forward byte/packet accounting to the actual transmit workers.

- [ ] **Step 4: Normalize `dev_queue_xmit()` results in the workers**

Update `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` worker loops to:

```c
	int err;

	while ((skb = skb_dequeue(&br->w2p_queue)) != NULL) {
		err = dev_queue_xmit(skb);
		if (net_xmit_eval(err)) {
			atomic_long_inc(&br->wlan_to_peer.errors);
		} else {
			atomic_long_inc(&br->wlan_to_peer.fwd_packets);
			atomic_long_add(skb->len, &br->wlan_to_peer.fwd_bytes);
		}
		cnt++;
	}
```

and:

```c
	int err;

	while ((skb = skb_dequeue(&br->p2w_queue)) != NULL) {
		err = dev_queue_xmit(skb);
		if (net_xmit_eval(err)) {
			atomic_long_inc(&br->peer_to_wlan.errors);
		} else {
			atomic_long_inc(&br->peer_to_wlan.fwd_packets);
			atomic_long_add(skb->len, &br->peer_to_wlan.fwd_bytes);
		}
		cnt++;
	}
```

- [ ] **Step 5: Re-run the static check and the cross-build**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh && \
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected:

```text
PASS: keepalive config path is internally consistent
Build completes and regenerates moal.ko / mlan.ko without compile errors
```

- [ ] **Step 6: Commit**

```bash
git add \
  /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh \
  /home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c
git commit -m "fix: account bridge handoff outcomes in workers"
```

---

### Task 4: Close the remaining init correctness leak and update runtime-facing docs

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c:582-587`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.analysis.md:147-170`
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.report.md:60-71`

- [ ] **Step 1: Add a static check for the remaining early-return leak**

Append this check to `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`:

```bash
grep -q 'bridge: wlan BSS\[%d\] not ready' "$BRIDGE_C" || fail "wlan BSS guard site missing"
grep -q 'atomic_set(&bridge_instance_active, 0);' "$BRIDGE_C" || fail "bridge instance guard reset missing"
```

- [ ] **Step 2: Run the static check and verify the current tree still fails for this case**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh
```

Expected:

```text
FAIL: bridge instance guard reset missing
```

- [ ] **Step 3: Fix the invalid-BSS early return**

Update `/home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c` to:

```c
	if (wlan_bss_idx < 0 || wlan_bss_idx >= MLAN_MAX_BSS_NUM ||
	    !handle->priv[wlan_bss_idx] ||
	    !handle->priv[wlan_bss_idx]->netdev) {
		PRINTM(MERROR, "bridge: wlan BSS[%d] not ready\n", wlan_bss_idx);
		atomic_set(&bridge_instance_active, 0);
		return -ENODEV;
	}
```

- [ ] **Step 4: Update the docs so they stop overstating readiness**

Update `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.analysis.md` to replace the current conclusion block with:

```md
**Static implementation coverage is high, but runtime readiness is still pending.**

- Build verification passed via `/home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh`
- Queue backpressure, keepalive consistency, and hot-path accounting require explicit hardening before calling the bridge production-ready
- SC-01, SC-02, SC-03, SC-05, and SC-06 still require target validation
```

Update `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.report.md` to replace the “Overall: 1/6 확인” section with:

```md
**Overall: code integrated, but runtime validation and hardening still required before production use**

- Static integration is present
- Runtime verification is still pending on target hardware
- Hardening items remain for queue bounds, keepalive behavior, xmit accounting, and init-failure cleanup
```

- [ ] **Step 5: Build and run the static check again**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh && \
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh
```

Expected:

```text
PASS: keepalive config path is internally consistent
Build completes and regenerates moal.ko / mlan.ko without compile errors
```

- [ ] **Step 6: Commit**

```bash
git add \
  /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh \
  /home/jhw/ai/opencode/projects/wlan-driver-v2/mlinux/moal_bridge.c \
  /home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.analysis.md \
  /home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.report.md
git commit -m "fix: align bridge readiness docs with hardening state"
```

---

### Task 5: Run target validation against the actual user-facing bridge flow

**Files:**
- Modify: `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.report.md`

- [ ] **Step 1: Copy rebuilt modules to the package output**

Run:

```bash
bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/update_package.sh
```

Expected:

```text
All rebuilt .ko files are copied into ../../wlan-package/dist/wlan/opt/wlan/driver/
```

- [ ] **Step 2: Validate bridge load with keepalive disabled on target hardware**

Run on the target board:

```bash
insmod /lib/modules/mlan.ko
insmod /lib/modules/moal.ko bridge_mode=1 bridge_peer=eth0 bridge_keepalive_ms=0
dmesg | grep 'bridge:'
```

Expected:

```text
bridge:   keepalive  = off
bridge: === Activated ===
```

- [ ] **Step 3: Validate bidirectional forwarding and self-IP access**

Run on the target board and peers:

```bash
ping -c 5 <wired-peer-ip>
ping -c 5 <wireless-peer-ip>
ssh root@<bridge-ip>
```

Expected:

```text
Both ping directions succeed and SSH to the bridge IP still works
```

- [ ] **Step 4: Validate throughput and unload behavior**

Run:

```bash
iperf3 -s
iperf3 -c <peer-ip> -t 60
mpstat 1 60
rmmod moal && rmmod mlan
```

Expected:

```text
Throughput remains stable for 60s and both modules unload cleanly
```

- [ ] **Step 5: Record the actual runtime result in the report**

Append this template to `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.report.md` and replace the placeholders with actual results:

```md
## Runtime Validation

- Build command: `/home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh`
- Module load: `bridge_mode=1 bridge_peer=eth0 bridge_keepalive_ms=0`
- Bidirectional ping: PASS/FAIL
- SSH to bridge IP: PASS/FAIL
- iperf3 60s: <measured result>
- rmmod loop: PASS/FAIL
```

- [ ] **Step 6: Commit**

```bash
git add /home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.report.md
git commit -m "docs: record bridge runtime validation"
```

---

## Self-Review

- **Spec coverage:** The plan covers all four issues from the latest review: keepalive consistency, queue backpressure, hot-path accounting, and the remaining init guard leak. It also adds the missing runtime validation/documentation closure.
- **Placeholder scan:** No `TODO`, `TBD`, or “add validation” placeholders remain. Each task contains concrete code or exact commands.
- **Type consistency:** The plan uses `handle->params.bridge_keepalive_ms` consistently as the keepalive source and keeps all file paths absolute.
