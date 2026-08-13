# Runtime MOAL Bridge Interface Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in synchronous sysfs control that rebinds an active MOAL L2 bridge between connected STA interfaces such as `mlan0` and `mlan1`, with rollback and no driver reload.

**Architecture:** Resolve the requested netdev to its DBDC `(moal_handle, bss_index, moal_private)` tuple, serialize lifecycle changes behind `AddRemoveCardSem` and a bridge mutex, and reuse complete bridge deinit/init rather than hot-swapping pointers. A guarded `module_param_cb()` makes successful application `write()` the linearization point for a completed switch.

**Tech Stack:** Linux kernel C, NXP MOAL/MLAN, sysfs module parameters, RCU/network synchronization, kthreads/hrtimer/netdev notifiers, Bash static and target QA scripts.

## Global Constraints

- Work from `wlan-driver-v2/main`, never the legacy sibling repository.
- Create an isolated worktree with `superpowers:using-git-worktrees` before execution; the current checkout contains unrelated user changes.
- `bridge_runtime_switch` defaults to `0`, permission `0444`, and is a global `insmod` option—not a `wifi_mod_para.conf` key.
- `bridge_iface` uses `module_param_cb()` with permission `0644`, never `charp` storage.
- A write is synchronous and never enables a bridge when none is active.
- Only registered, present, running, associated MOAL STA interfaces are valid targets.
- Same-interface writes succeed without teardown; validation failures leave the bridge untouched.
- Post-teardown failure rolls back; rollback failure returns `-EIO` and leaves the bridge inactive.
- Preserve existing RCU/network drains, thread/timer teardown, notifier removal, queue purge, peer references, DBDC guard, and packet-type fallback.
- Switching may briefly drop packets and does not guarantee TCP continuity.
- Prefix shell commands with `rtk`.

---

## File Structure

- `mlinux/moal_bridge.c`: resolver, lifecycle lock/owner, transaction, rollback, counters.
- `mlinux/moal_bridge.h`: public switch/get declarations.
- `mlinux/moal_init.c`: opt-in gate and custom synchronous sysfs callbacks.
- `scripts/tests/bridge_static_checks.sh`: textual invariants and regression gate.
- `scripts/tests/bridge_runtime_switch_qa.sh`: target-board functional/stress QA.
- `docs/MOAL-Module-Parameters.md`: application contract and errors.
- `docs/driver-bridge.qa-runbook.md`: target preparation and evidence.

---

### Task 1: Resolve and Validate a DBDC STA Target

**Files:**
- Modify: `mlinux/moal_bridge.c:18-33, before the lifecycle section around 1450`
- Modify: `scripts/tests/bridge_static_checks.sh:before final PASS`

**Interfaces:**
- Consumes: `m_handle[]`, each handle's `priv[]`, netdev and association state.
- Produces: private `struct moal_bridge_target` and `moal_bridge_find_target()`.

- [ ] **Step 1: Add the failing static contract**

Append before the final `PASS`:

```bash
TARGET_BLOCK="$(grep -n -A100 -m1 '^static int moal_bridge_find_target' "$BRIDGE_C")"
for token in 'm_handle\[' MLAN_BSS_TYPE_STA NETREG_REGISTERED \
             netif_device_present netif_running media_connected \
             HardwareStatusReady fw_reseting surprise_removed; do
  printf '%s\n' "$TARGET_BLOCK" | grep -q "$token" || \
    fail "runtime-switch: target validator missing $token"
done
```

- [ ] **Step 2: Prove the check fails**

```bash
rtk bash scripts/tests/bridge_static_checks.sh
```

Expected: FAIL because `moal_bridge_find_target` is absent.

- [ ] **Step 3: Implement the private tuple and resolver**

```c
struct moal_bridge_target {
	moal_handle *handle;
	moal_private *priv;
	struct net_device *dev;
	int bss_index;
};

/* Caller holds AddRemoveCardSem. */
static int moal_bridge_find_target(const char *ifname,
				   struct moal_bridge_target *target)
{
	moal_handle *handle;
	moal_private *priv;
	int i, j;

	if (!ifname || !ifname[0] || !target)
		return -EINVAL;
	for (i = 0; i < MAX_MLAN_ADAPTER; i++) {
		handle = m_handle[i];
		if (!handle)
			continue;
		for (j = 0; j < MIN(handle->priv_num, MLAN_MAX_BSS_NUM); j++) {
			priv = handle->priv[j];
			if (!priv || !priv->netdev ||
			    strcmp(priv->netdev->name, ifname))
				continue;
			if (priv->bss_type != MLAN_BSS_TYPE_STA)
				return -EINVAL;
			if (handle->surprise_removed || handle->fw_reseting ||
			    handle->hardware_status != HardwareStatusReady)
				return -EBUSY;
			if (priv->netdev->reg_state != NETREG_REGISTERED ||
			    !netif_device_present(priv->netdev) ||
			    !netif_running(priv->netdev))
				return -ENETDOWN;
			if (READ_ONCE(priv->media_connected) != MTRUE)
				return -ENOLINK;
			target->handle = handle;
			target->priv = priv;
			target->dev = priv->netdev;
			target->bss_index = j;
			return 0;
		}
	}
	return -ENODEV;
}
```

- [ ] **Step 4: Verify and commit**

```bash
rtk bash scripts/tests/bridge_static_checks.sh
rtk ./make_for_imx93.sh
rtk git add mlinux/moal_bridge.c scripts/tests/bridge_static_checks.sh
rtk proxy git commit -m "feat(moal): validate runtime bridge switch targets"
```

Expected: static PASS and i.MX93 build success.

---

### Task 2: Serialize the Existing Bridge Lifecycle

**Files:**
- Modify: `mlinux/moal_bridge.c:18-25, 1460-1745`
- Modify: `scripts/tests/bridge_static_checks.sh`

**Interfaces:**
- Consumes: unchanged callers `moal_bridge_init()` and `moal_bridge_deinit()`.
- Produces: private locked helpers and `bridge_owner` used by Task 3.

- [ ] **Step 1: Add failing lifecycle checks**

```bash
grep -q 'DEFINE_MUTEX(bridge_lifecycle_lock)' "$BRIDGE_C" || fail "runtime-switch: lifecycle mutex missing"
grep -q 'static moal_handle \*bridge_owner' "$BRIDGE_C" || fail "runtime-switch: owner missing"
grep -q '^static int __moal_bridge_init_locked' "$BRIDGE_C" || fail "runtime-switch: locked init missing"
grep -q '^static void __moal_bridge_deinit_locked' "$BRIDGE_C" || fail "runtime-switch: locked deinit missing"
INIT_WRAP="$(grep -n -A20 -m1 '^int moal_bridge_init' "$BRIDGE_C")"
DEINIT_WRAP="$(grep -n -A20 -m1 '^void moal_bridge_deinit' "$BRIDGE_C")"
printf '%s\n' "$INIT_WRAP" | grep -q 'mutex_lock(&bridge_lifecycle_lock)' || fail "runtime-switch: init unlocked"
printf '%s\n' "$DEINIT_WRAP" | grep -q 'mutex_lock(&bridge_lifecycle_lock)' || fail "runtime-switch: deinit unlocked"
```

- [ ] **Step 2: Prove failure**

```bash
rtk bash scripts/tests/bridge_static_checks.sh
```

Expected: FAIL at missing lifecycle mutex.

- [ ] **Step 3: Refactor bodies without changing teardown order**

Add:

```c
static DEFINE_MUTEX(bridge_lifecycle_lock);
static moal_handle *bridge_owner;
```

Move the existing bodies to:

```c
static int __moal_bridge_init_locked(moal_handle *handle,
				     const char *peer_name, int wlan_bss_idx);
static void __moal_bridge_deinit_locked(moal_handle *handle);
```

Fix the current deinit null ordering by validating `handle` before reading `handle->bridge`. Keep `bridge_instance_active` set/reset inside these helpers.

- [ ] **Step 4: Add lock-owning public wrappers**

```c
int moal_bridge_init(void *phandle, const char *peer_name, int wlan_bss_idx)
{
	moal_handle *handle = phandle;
	int ret;

	if (!handle)
		return -EINVAL;
	mutex_lock(&bridge_lifecycle_lock);
	ret = __moal_bridge_init_locked(handle, peer_name, wlan_bss_idx);
	if (!ret)
		bridge_owner = handle;
	mutex_unlock(&bridge_lifecycle_lock);
	return ret;
}

void moal_bridge_deinit(void *phandle)
{
	moal_handle *handle = phandle;

	if (!handle)
		return;
	mutex_lock(&bridge_lifecycle_lock);
	if (bridge_owner == handle) {
		__moal_bridge_deinit_locked(handle);
		bridge_owner = NULL;
	}
	mutex_unlock(&bridge_lifecycle_lock);
}
```

Do not acquire `AddRemoveCardSem` in these wrappers; load/remove callers already own it.

- [ ] **Step 5: Verify and commit**

```bash
rtk bash scripts/tests/bridge_static_checks.sh
rtk ./make_for_imx93.sh
rtk git add mlinux/moal_bridge.c scripts/tests/bridge_static_checks.sh
rtk proxy git commit -m "refactor(moal): serialize bridge lifecycle ownership"
```

---

### Task 3: Implement Synchronous Rebind and Rollback

**Files:**
- Modify: `mlinux/moal_bridge.h:113-122`
- Modify: `mlinux/moal_bridge.c:after lifecycle wrappers`
- Modify: `mlinux/moal_init.c:near existing bridge globals`
- Modify: `scripts/tests/bridge_static_checks.sh`

**Interfaces:**
- Consumes: resolver and locked lifecycle helpers.
- Produces: `moal_bridge_switch_iface()` and `moal_bridge_get_iface()`.

- [ ] **Step 1: Add failing API/transaction checks**

```bash
grep -q 'moal_bridge_switch_iface' "$ROOT/mlinux/moal_bridge.h" || fail "runtime-switch: switch declaration missing"
grep -q 'moal_bridge_get_iface' "$ROOT/mlinux/moal_bridge.h" || fail "runtime-switch: getter declaration missing"
SWITCH_BLOCK="$(grep -n -A240 -m1 '^int moal_bridge_switch_iface' "$BRIDGE_C")"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'MOAL_ACQ_SEMAPHORE_BLOCK(&AddRemoveCardSem)' || fail "runtime-switch: card semaphore missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q 'mutex_lock(&bridge_lifecycle_lock)' || fail "runtime-switch: lifecycle lock missing"
printf '%s\n' "$SWITCH_BLOCK" | grep -q '__moal_bridge_deinit_locked' || fail "runtime-switch: full deinit missing"
[ "$(printf '%s\n' "$SWITCH_BLOCK" | grep -c '__moal_bridge_init_locked' || true)" -ge 2 ] || fail "runtime-switch: target init and rollback required"
printf '%s\n' "$SWITCH_BLOCK" | grep -q -- '-EIO' || fail "runtime-switch: rollback failure EIO missing"
```

- [ ] **Step 2: Prove failure**

```bash
rtk bash scripts/tests/bridge_static_checks.sh
```

Expected: FAIL at missing declaration.

- [ ] **Step 3: Declare the public APIs and snapshot state**

In `moal_bridge.h`:

```c
int moal_bridge_switch_iface(const char *ifname);
int moal_bridge_get_iface(char *buf, size_t len);
```

In `moal_bridge.c`:

```c
struct moal_bridge_switch_snapshot {
	moal_handle *old_owner;
	int old_bss_index;
	char old_iface[IFNAMSIZ];
	char peer[IFNAMSIZ];
	int old_mode;
	int keepalive_ms;
	int keepalive_idle_ms;
};

static atomic_long_t bridge_switch_ok = ATOMIC_LONG_INIT(0);
static atomic_long_t bridge_switch_fail = ATOMIC_LONG_INIT(0);
static atomic_long_t bridge_rollback_ok = ATOMIC_LONG_INIT(0);
static atomic_long_t bridge_rollback_fail = ATOMIC_LONG_INIT(0);
```

Add `int bridge_runtime_switch;` beside the existing bridge globals in
`mlinux/moal_init.c`, and add `extern int bridge_runtime_switch;` beside the
other bridge externs in `mlinux/moal_bridge.c`. Task 4 exposes this already
defined, default-zero variable as a module parameter.

Also preserve target handle's original `bridge_mode`, `bridge_wlan_idx`, `bridge_peer`, and keepalive values in function-local variables.

- [ ] **Step 4: Implement the effective-state getter**

```c
int moal_bridge_get_iface(char *buf, size_t len)
{
	struct moal_bridge *br;
	int ret;

	if (!buf || !len)
		return -EINVAL;
	mutex_lock(&bridge_lifecycle_lock);
	br = bridge_owner ? bridge_owner->bridge : NULL;
	ret = scnprintf(buf, len, "%s\n",
			br && atomic_read(&br->active) ? br->wlan_dev->name : "none");
	mutex_unlock(&bridge_lifecycle_lock);
	return ret;
}
```

- [ ] **Step 5: Implement the transaction in exact order**

`moal_bridge_switch_iface()` must:

1. Return `-EOPNOTSUPP` unless `READ_ONCE(bridge_runtime_switch)` is one.
2. Acquire `AddRemoveCardSem`; return `-ERESTARTSYS` if interrupted.
3. Acquire `bridge_lifecycle_lock`.
4. Reject absent/inactive `bridge_owner->bridge` with `-ENODEV`.
5. Call `moal_bridge_find_target()` before teardown.
6. Return success if `target.dev == bridge_owner->bridge->wlan_dev`.
7. Copy old owner, old BSS index, peer name, and keepalive values before freeing `br`.
8. Save all target effective bridge parameters.
9. Call `__moal_bridge_deinit_locked(old_owner)` and clear `bridge_owner`.
10. Copy old peer/keepalive policy into target parameters, set target mode/index, and call `__moal_bridge_init_locked(target.handle, old.peer, target.bss_index)`.
11. On success set old mode zero only when `old_owner != target.handle`, keep
    the new owner's mode at one, publish target owner, increment
    `bridge_switch_ok`, and return zero.
12. On failure restore target parameters and call `__moal_bridge_init_locked(old_owner, old.peer, old_bss_index)`.
13. If rollback succeeds, restore old mode/owner, increment `bridge_switch_fail` and `bridge_rollback_ok`, and return the target-init errno.
14. If rollback fails, set both modes zero, clear owner, increment `bridge_switch_fail` and `bridge_rollback_fail`, and return `-EIO`.
15. Release lifecycle mutex then `AddRemoveCardSem` on every acquired path.

Use the repository-compatible fixed-buffer pattern for every saved name:

```c
strncpy(dst, src, sizeof(dst) - 1);
dst[sizeof(dst) - 1] = '\0';
```

Add one `MMSG` request/success log and one `MERROR` terminal failure log; do not log per packet.

- [ ] **Step 6: Verify release paths and build**

```bash
rtk bash scripts/tests/bridge_static_checks.sh
rtk ./make_for_imx93.sh
rtk rg -n 'out_unlock|mutex_unlock\(&bridge_lifecycle_lock\)|MOAL_REL_SEMAPHORE' mlinux/moal_bridge.c
```

Expected: all post-acquisition paths reach both releases.

- [ ] **Step 7: Commit**

```bash
rtk git add mlinux/moal_bridge.c mlinux/moal_bridge.h mlinux/moal_init.c scripts/tests/bridge_static_checks.sh
rtk proxy git commit -m "feat(moal): rebind active bridge across DBDC STA interfaces"
```

---

### Task 4: Expose the Opt-in Application Sysfs Contract

**Files:**
- Modify: `mlinux/moal_init.c:23-30, 3190-3220`
- Modify: `scripts/tests/bridge_static_checks.sh`

**Interfaces:**
- Consumes: Task 3 switch/get APIs.
- Produces: `bridge_runtime_switch` and `bridge_iface` module sysfs files.

- [ ] **Step 1: Add failing parameter checks**

```bash
grep -q 'int bridge_runtime_switch;' "$INIT_C" || fail "runtime-switch: gate missing"
grep -q 'module_param(bridge_runtime_switch, int, 0444)' "$INIT_C" || fail "runtime-switch: gate permissions wrong"
grep -q 'module_param_cb(bridge_iface, &bridge_iface_ops, NULL, 0644)' "$INIT_C" || fail "runtime-switch: callback parameter missing"
grep -q 'moal_bridge_switch_iface(ifname)' "$INIT_C" || fail "runtime-switch: setter is not synchronous"
grep -q 'moal_bridge_get_iface(buf, PAGE_SIZE)' "$INIT_C" || fail "runtime-switch: getter is not effective-state based"
grep -q 'module_param(bridge_iface, charp' "$INIT_C" && fail "runtime-switch: charp forbidden"
```

- [ ] **Step 2: Prove failure**

```bash
rtk bash scripts/tests/bridge_static_checks.sh
```

- [ ] **Step 3: Add strict callbacks for the existing default-zero gate**

Include `moal_bridge.h`. Reuse the `bridge_runtime_switch` definition added in
Task 3; do not add it to `moal_mod_para` or config parsing.

```c
static int bridge_iface_set(const char *val, const struct kernel_param *kp)
{
	char ifname[IFNAMSIZ];
	size_t len = 0, end;

	if (!READ_ONCE(bridge_runtime_switch))
		return -EOPNOTSUPP;
	if (!val)
		return -EINVAL;
	while (val[len] && val[len] != '\r' && val[len] != '\n') {
		if (len >= sizeof(ifname) - 1)
			return -EINVAL;
		len++;
	}
	end = len;
	while (val[end] == '\r' || val[end] == '\n')
		end++;
	if (!len || val[end])
		return -EINVAL;
	memcpy(ifname, val, len);
	ifname[len] = '\0';
	if (!dev_valid_name(ifname))
		return -EINVAL;
	return moal_bridge_switch_iface(ifname);
}

static int bridge_iface_get(char *buf, const struct kernel_param *kp)
{
	return moal_bridge_get_iface(buf, PAGE_SIZE);
}

static const struct kernel_param_ops bridge_iface_ops = {
	.set = bridge_iface_set,
	.get = bridge_iface_get,
};
```

- [ ] **Step 4: Register exact parameters**

```c
module_param(bridge_runtime_switch, int, 0444);
MODULE_PARM_DESC(bridge_runtime_switch,
	"Allow synchronous runtime switching of an active L2 bridge: 0=off(default), 1=on");
module_param_cb(bridge_iface, &bridge_iface_ops, NULL, 0644);
MODULE_PARM_DESC(bridge_iface,
	"Active bridge STA interface; write a connected MOAL STA name to switch synchronously");
```

- [ ] **Step 5: Verify and commit**

```bash
rtk bash scripts/tests/bridge_static_checks.sh
rtk ./make_for_imx93.sh
rtk git add mlinux/moal_init.c scripts/tests/bridge_static_checks.sh
rtk proxy git commit -m "feat(moal): expose synchronous bridge interface switch"
```

---

### Task 5: Add Observability, Target QA, Documentation, and Final Gates

**Files:**
- Modify: `mlinux/moal_bridge.c:1314-1415`
- Create: `scripts/tests/bridge_runtime_switch_qa.sh`
- Modify: `scripts/tests/bridge_static_checks.sh`
- Modify: `docs/MOAL-Module-Parameters.md:215-270`
- Modify: `docs/driver-bridge.qa-runbook.md`

**Interfaces:**
- Consumes: final counters and sysfs control.
- Produces: additive stats, reproducible target test, deployment docs.

- [ ] **Step 1: Add failing observability checks**

```bash
grep -q 'switch_ok=%ld switch_fail=%ld rollback_ok=%ld rollback_fail=%ld' "$BRIDGE_C" || fail "runtime-switch: outcome stats missing"
grep -q 'iface=%s peer=%s' "$BRIDGE_C" || fail "runtime-switch: iface stats missing"
test -x "$ROOT/scripts/tests/bridge_runtime_switch_qa.sh" || fail "runtime-switch: executable QA script missing"
```

Run `rtk bash scripts/tests/bridge_static_checks.sh`; expect FAIL.

- [ ] **Step 2: Extend stats additively**

Append without changing existing lines:

```text
iface=<wlan> peer=<peer>
switch_ok=<n> switch_fail=<n> rollback_ok=<n> rollback_fail=<n>
```

Use `atomic_long_read()` for global counters and do not reset them across rebinds.

- [ ] **Step 3: Create target QA script**

Create executable `scripts/tests/bridge_runtime_switch_qa.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PARAM_DIR=/sys/module/moal/parameters
IFACE_PARAM="$PARAM_DIR/bridge_iface"
GATE_PARAM="$PARAM_DIR/bridge_runtime_switch"
STATS=/sys/kernel/moal_bridge/stats
FROM_IF="${FROM_IF:-mlan0}"
TO_IF="${TO_IF:-mlan1}"
SWITCH_LOOPS="${SWITCH_LOOPS:-100}"
fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || fail "run as root"
[ -e "$IFACE_PARAM" ] || fail "missing $IFACE_PARAM"
[ "$(cat "$GATE_PARAM")" = 1 ] || fail "reload with bridge_runtime_switch=1"
ip link show "$FROM_IF" >/dev/null 2>&1 || fail "$FROM_IF missing"
ip link show "$TO_IF" >/dev/null 2>&1 || fail "$TO_IF missing"
printf '%s\n' "$TO_IF" > "$IFACE_PARAM"
[ "$(tr -d '\r\n' < "$IFACE_PARAM")" = "$TO_IF" ] || fail "forward switch failed"
printf '%s\n' "$FROM_IF" > "$IFACE_PARAM"
[ "$(tr -d '\r\n' < "$IFACE_PARAM")" = "$FROM_IF" ] || fail "reverse switch failed"
for _ in $(seq 1 "$SWITCH_LOOPS"); do
  printf '%s\n' "$TO_IF" > "$IFACE_PARAM"
  printf '%s\n' "$FROM_IF" > "$IFACE_PARAM"
done
cat "$STATS"
dmesg | tail -200 | grep -E 'BUG:|WARNING:|use-after-free|lockdep' && fail "kernel warning detected"
printf 'PASS: %s bidirectional switch cycles\n' "$SWITCH_LOOPS"
```

The script does not configure or associate links; the operator prepares both.

- [ ] **Step 4: Document parameters and errno**

Document:

```text
bridge_runtime_switch int 0 0444 global load-time opt-in
bridge_iface custom string 0644 read effective target/write connected target
EOPNOTSUPP gate off; ENODEV inactive/absent; EINVAL malformed/non-STA;
ENETDOWN netdev down; ENOLINK disconnected; EBUSY reset/removal;
EIO target init and rollback both failed
```

Include:

```bash
insmod moal.ko mod_para=cts/wifi_mod_para.conf bridge_runtime_switch=1
cat /sys/module/moal/parameters/bridge_iface
echo mlan1 > /sys/module/moal/parameters/bridge_iface
```

State that selection is nonpersistent, cannot enable a disabled bridge, and may briefly interrupt packets.

- [ ] **Step 5: Extend target runbook**

```bash
iw dev mlan0 link
iw dev mlan1 link
cat /sys/module/moal/parameters/bridge_iface
FROM_IF=mlan0 TO_IF=mlan1 SWITCH_LOOPS=1000 \
  ./scripts/tests/bridge_runtime_switch_qa.sh | tee /tmp/bridge-switch-qa.log
```

Require bidirectional traffic during the stress loop and capture dmesg, stats, bridge threads, and before/after reference/leak evidence. Do not claim target validation until this actually runs with both links associated.

- [ ] **Step 6: Run full verification**

```bash
rtk chmod +x scripts/tests/bridge_runtime_switch_qa.sh
rtk bash -n scripts/tests/bridge_runtime_switch_qa.sh
rtk bash scripts/tests/bridge_static_checks.sh
rtk ./make_for_imx8.sh
rtk ./make_for_imx93.sh
rtk git diff --check
rtk git status --short
```

Expected: shell/static PASS, both builds complete, no whitespace errors, only intended files changed. If a toolchain is absent, record the exact missing path and do not mark that build passed.

- [ ] **Step 7: Manually review design invariants**

```bash
rtk rg -n 'bridge_runtime_switch|bridge_iface|moal_bridge_switch_iface|bridge_lifecycle_lock|bridge_owner|bridge_rollback' mlinux scripts/tests docs
rtk git diff main...HEAD -- mlinux/moal_bridge.c mlinux/moal_bridge.h mlinux/moal_init.c scripts/tests docs
```

Confirm target checks precede deinit, same-target is no-op, failed init rolls back, double failure clears modes/owner, unload still uses serialized wrappers, and gate zero leaves forwarding unchanged.

- [ ] **Step 8: Commit docs and QA**

```bash
rtk git add mlinux/moal_bridge.c scripts/tests/bridge_static_checks.sh \
  scripts/tests/bridge_runtime_switch_qa.sh docs/MOAL-Module-Parameters.md \
  docs/driver-bridge.qa-runbook.md
rtk proxy git commit -m "test(moal): validate runtime bridge interface switching"
```

- [ ] **Step 9: Prepare completion evidence**

```bash
rtk bash scripts/tests/bridge_static_checks.sh
rtk git log --oneline --decorate -6
rtk git status --short --branch
```

Report exact command outcomes, build artifacts, unrun target-only checks, commits, and residual risk. Never claim lossless switching or target-board success without evidence.
