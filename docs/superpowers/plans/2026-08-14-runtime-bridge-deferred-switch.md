# Runtime Bridge Deferred Interface Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept a runtime bridge request for a registered but inactive MOAL STA, keep the current bridge forwarding, and automatically apply the request when the target becomes operational.

**Architecture:** Split structural target validation from operational link readiness, then layer a single module-wide pending request over the existing singleton bridge transaction. Store only an interface name, generation, and state behind a spinlock; netdev events schedule a module-lifetime worker, and the worker re-resolves all handle/netdev identities under `AddRemoveCardSem` before invoking the existing rollback-capable switch.

**Tech Stack:** Linux kernel C, NXP MOAL/MLAN fullmac driver, module parameters/sysfs, netdevice notifier, workqueue, Bash target QA, structural mutation gates.

## Global Constraints

- `bridge_runtime_deferred=0` is the default and must preserve current `ENETDOWN`/`ENOLINK` behavior.
- Applications write only `/sys/module/moal/parameters/bridge_iface`; `bridge_pending_iface` is read-only status.
- A pending request retains the current active owner and has no timeout.
- A new valid inactive target replaces pending; writing the active name cancels pending.
- Deferred mode relaxes only `netif_running`, `media_connected`, and carrier checks.
- Registered/present MOAL STA identity, handle readiness, reset/reload/removal, active-owner, and peer lifetime checks remain fail-closed.
- Pending state may not retain raw `moal_handle`, `moal_private`, or `net_device` pointers.
- Netdev notifier context may only schedule/cancel state; it may not run bridge teardown/init.
- No periodic polling or delayed retry loop is allowed.
- The mlan1 same-MAC/multi-BSSID return-path defect is not part of this change.
- Preserve unrelated worktree modifications and stage only task-owned files.
- Run no cross-build until code freeze; then run i.MX93 once and final i.MX8 once.

## File Structure

- Modify `mlinux/moal_init.c`: module/config parameter parsing plus active and pending sysfs callbacks.
- Modify `mlinux/moal_bridge.c`: readiness split, pending state machine, event worker, switch integration, stats, cleanup.
- Modify `mlinux/moal_bridge.h`: public pending getter/cleanup declarations used outside `moal_bridge.c`.
- Modify `mlinux/moal_main.c`: close runtime admission and drain pending work before module teardown takes `AddRemoveCardSem`.
- Modify `scripts/tests/bridge_static_checks.sh`: structural and negative-mutation gates for parser, pointer lifetime, worker, generation, notifier, and cleanup order.
- Modify `scripts/tests/bridge_runtime_switch_qa.sh`: target cases for default-off rejection, waiting, automatic completion, replacement/cancellation, and cleanup.
- Modify `docs/MOAL-Module-Parameters.md`: parameter and sysfs contract.
- Modify `docs/runtime-bridge-interface-switch.design.md`: extend the runtime transaction with deferred semantics without weakening the synchronous default.
- Modify `docs/driver-bridge.qa-runbook.md`: board setup, commands, evidence, and pass criteria.

---

### Task 1: Add the Default-Off Deferred Policy Parameter

**Files:**
- Modify: `mlinux/moal_init.c:90-105,680-700,910-940,1750-1770,3265-3285`
- Modify: `scripts/tests/bridge_static_checks.sh:160-200,425-490`
- Modify: `docs/MOAL-Module-Parameters.md:215-320`

**Interfaces:**
- Consumes: existing global enable-only pattern for `bridge_runtime_switch`.
- Produces: global `int bridge_runtime_deferred`, readable with `READ_ONCE()`, accepted from insmod and successfully parsed `mod_para` blocks.

- [ ] **Step 1: Add a failing structural test for the parameter contract**

Add a sibling to `check_runtime_switch_conf_contract` that requires local parse staging, strict 0/1 validation, end-of-block enable-only commit, effective/configured logging, and a `0444` module parameter:

```bash
check_runtime_deferred_conf_contract() {
  local parser="$1"
  printf '%s\n' "$parser" | awk '
    /int bridge_runtime_deferred_cfg = 0/ { cfg=NR }
    /int bridge_runtime_deferred_present = 0/ { present=NR }
    /strncmp\(line, "bridge_runtime_deferred"/ { key=NR }
    /out_data != 0 && out_data != 1/ && key { range=NR }
    /bridge_runtime_deferred_cfg = out_data/ { save=NR }
    /bridge_runtime_deferred_present = 1/ { mark=NR }
    /^[[:space:]]*if \(end\)[[:space:]]*\{/ { commit=NR }
    /WRITE_ONCE\(bridge_runtime_deferred, 1\)/ { enable=NR }
    /bridge_runtime_deferred = %d \(conf=%d\)/ { log=NR }
    END { exit !(cfg && present && key && range && save && mark && commit &&
                 enable && log && cfg < key && present < key && key < range &&
                 range < save && save <= mark && mark < commit && commit < enable &&
                 enable < log) }
  ' || return 1
  grep -q 'module_param(bridge_runtime_deferred, int, 0444)' "$INIT_C"
}
```

Add two negative fixtures: replace the 0/1 predicate with `out_data < 0`, and remove `WRITE_ONCE(bridge_runtime_deferred, 1)`. Both mutated parser blocks must be rejected.

- [ ] **Step 2: Run the static gate and confirm the new check fails**

Run:

```bash
rtk bash -n scripts/tests/bridge_static_checks.sh
rtk ./scripts/tests/bridge_static_checks.sh
```

Expected: Bash syntax passes; static checks stop at `runtime-switch: deferred conf contract missing`.

- [ ] **Step 3: Implement strict staged parsing and the module parameter**

Follow the existing global policy pattern without adding a per-handle field:

```c
int bridge_runtime_deferred;

/* parse_cfg_read_block locals */
int bridge_runtime_deferred_cfg = 0;
int bridge_runtime_deferred_present = 0;

} else if (strncmp(line, "bridge_runtime_deferred",
                   strlen("bridge_runtime_deferred")) == 0) {
    if (parse_line_read_int(line, &out_data) != MLAN_STATUS_SUCCESS)
        goto err;
    if (out_data != 0 && out_data != 1) {
        PRINTM(MERROR, "bridge_runtime_deferred must be 0 or 1\n");
        goto err;
    }
    bridge_runtime_deferred_cfg = out_data;
    bridge_runtime_deferred_present = 1;
}
```

Commit only after the closing `}` was parsed successfully:

```c
if (bridge_runtime_deferred_cfg)
    WRITE_ONCE(bridge_runtime_deferred, 1);
if (bridge_runtime_deferred_present)
    PRINTM(MMSG, "bridge_runtime_deferred = %d (conf=%d)\n",
           READ_ONCE(bridge_runtime_deferred),
           bridge_runtime_deferred_cfg);
```

Register it read-only after load:

```c
module_param(bridge_runtime_deferred, int, 0444);
MODULE_PARM_DESC(
    bridge_runtime_deferred,
    "Defer a runtime bridge request until a registered MOAL STA becomes operational: 0=off(default), 1=on; a matched mod_para block may also enable it");
```

- [ ] **Step 4: Document default, aggregation, and dependency**

Add a parameter-table row and examples showing that `bridge_runtime_switch=1` is still required:

```ini
bridge_runtime_switch=1
bridge_runtime_deferred=1
```

State explicitly that a config value `0` cannot undo an enable from another selected DBDC block or explicit insmod argument.

- [ ] **Step 5: Run focused gates**

Run:

```bash
rtk bash -n scripts/tests/bridge_static_checks.sh
rtk ./scripts/tests/bridge_static_checks.sh
rtk git diff --check -- mlinux/moal_init.c scripts/tests/bridge_static_checks.sh docs/MOAL-Module-Parameters.md
```

Expected: both deferred parser mutations are rejected, all static checks pass, and diff-check is clean.

- [ ] **Step 6: Commit only Task 1 files**

```bash
rtk git add mlinux/moal_init.c scripts/tests/bridge_static_checks.sh docs/MOAL-Module-Parameters.md
rtk git commit -m "feat(moal): add deferred bridge switch policy"
```

---

### Task 2: Separate Structural Target Identity from Link Readiness

**Files:**
- Modify: `mlinux/moal_bridge.c:1610-1655,2300-2340,2380-2420`
- Modify: `scripts/tests/bridge_static_checks.sh:200-280,425-530`

**Interfaces:**
- Consumes: `struct moal_bridge_target` and existing switch lock order.
- Produces: `moal_bridge_find_target()` for structural identity and `moal_bridge_target_link_status()` for operational readiness; default mode composes both and remains behaviorally unchanged.

- [ ] **Step 1: Add a failing readiness-split structural test**

Extract both helpers and require the resolver to retain STA/handle/registered/present checks while the readiness helper owns the exact ordered results:

```c
static int moal_bridge_target_link_status(
    const struct moal_bridge_target *target)
{
    if (!netif_running(target->dev))
        return -ENETDOWN;
    if (READ_ONCE(target->priv->media_connected) != MTRUE)
        return -ENOLINK;
    if (!netif_carrier_ok(target->dev))
        return -ENETDOWN;
    return 0;
}
```

The static gate must reject these mutations independently: moving `media_connected` back into the structural resolver, dropping `NETREG_REGISTERED`, and swapping carrier before media so disconnected admin-UP targets report the wrong errno.

- [ ] **Step 2: Run the static test and observe failure**

```bash
rtk bash -n scripts/tests/bridge_static_checks.sh
rtk ./scripts/tests/bridge_static_checks.sh
```

Expected: failure at the new readiness-split contract because the helper does not exist.

- [ ] **Step 3: Refactor without enabling deferred behavior**

Keep `moal_bridge_find_target()` responsible for:

```c
priv->bss_type == MLAN_BSS_TYPE_STA
handle->hardware_status == HardwareStatusReady
!handle->surprise_removed
!handle->fw_reseting
!handle->fw_reload
!handle->driver_status
priv->netdev->reg_state == NETREG_REGISTERED
netif_device_present(priv->netdev)
handle->priv[j] == priv
```

After a successful structural lookup, call `moal_bridge_target_link_status()` in the public switch before any teardown. Reuse the same helper in `moal_bridge_validate_binding_locked()` after its pointer/owner checks. Do not alter switch counters, no-op behavior, peer pinning, target init, validation, or rollback.

- [ ] **Step 4: Run the existing default contract gates**

```bash
rtk ./scripts/tests/bridge_static_checks.sh
rtk bash -n scripts/tests/bridge_runtime_switch_qa.sh
rtk git diff --check -- mlinux/moal_bridge.c scripts/tests/bridge_static_checks.sh
```

Expected: all old switch/rollback mutations and all new readiness mutations pass.

- [ ] **Step 5: Commit the behavior-preserving refactor**

```bash
rtk git add mlinux/moal_bridge.c scripts/tests/bridge_static_checks.sh
rtk git commit -m "refactor(moal): split bridge identity and link readiness"
```

---

### Task 3: Implement the Single Pending Request and Event Worker

**Files:**
- Modify: `mlinux/moal_bridge.c:15-70,1310-1385,1430-1530,2260-2530`
- Modify: `mlinux/moal_bridge.h:125-160`
- Modify: `mlinux/moal_init.c:3000-3050,3270-3300`
- Modify: `mlinux/moal_main.c:15275-15310`
- Modify: `scripts/tests/bridge_static_checks.sh:90-320,420-700`

**Interfaces:**
- Consumes: `bridge_runtime_deferred`, `moal_bridge_target_link_status()`, existing `moal_bridge_switch_iface()` transaction.
- Produces: `moal_bridge_get_pending_iface(char *, size_t)`, `moal_bridge_pending_start(void)`, `moal_bridge_pending_cleanup(void)`, read-only `bridge_pending_iface`, and automatic event-triggered completion.

- [ ] **Step 1: Add failing pending-lifetime and worker gates**

Add structural checks that require all of the following and provide one negative mutation for each numbered invariant:

1. Pending storage contains only `char ifname[IFNAMSIZ]`, `unsigned long generation`, and enum state; reject any `moal_handle *`, `moal_private *`, or `struct net_device *` field.
2. `NETDEV_UP`, `NETDEV_CHANGE`, and `NETDEV_CHANGENAME` only call a non-sleeping pending-event scheduler; reject direct calls to switch/init/deinit from notifier scope.
3. Worker obtains `AddRemoveCardSem`, rechecks `bridge_runtime_control_ready`, then takes `bridge_lifecycle_lock` before target resolution.
4. Pending clear after a worker attempt compares both interface name and generation.
5. Init enables notifier admission before readiness publication; cleanup clears readiness, disables admission under `bridge_pending_lock`, and then calls `cancel_work_sync(&bridge_pending_work)` before `down(&AddRemoveCardSem)`.
6. The active getter still calls `moal_bridge_get_iface`; the pending getter calls only `moal_bridge_get_pending_iface`.

Use source-order checks rather than file-wide token presence. Example cleanup mutation:

```bash
CLEANUP_NO_PENDING_DRAIN="$(printf '%s\n' "$CLEANUP_MODULE_BLOCK" |
  sed 's/moal_bridge_pending_cleanup();/\/\* missing pending drain \*\//')"
if check_cleanup_transaction "$CLEANUP_NO_PENDING_DRAIN"; then
  fail "runtime-switch: missing pending cleanup mutation accepted"
fi
```

- [ ] **Step 2: Run the static gate and verify it fails before production edits**

```bash
rtk bash -n scripts/tests/bridge_static_checks.sh
rtk ./scripts/tests/bridge_static_checks.sh
```

Expected: first pending-state invariant fails.

- [ ] **Step 3: Add pointer-free pending state and snapshot helpers**

Define state at module scope in `moal_bridge.c`:

```c
enum moal_bridge_pending_state {
    MOAL_BR_PENDING_NONE,
    MOAL_BR_PENDING_WAITING,
    MOAL_BR_PENDING_SWITCHING,
};

struct moal_bridge_pending_request {
    char ifname[IFNAMSIZ];
    unsigned long generation;
    enum moal_bridge_pending_state state;
};

static DEFINE_SPINLOCK(bridge_pending_lock);
static struct moal_bridge_pending_request bridge_pending;
static bool bridge_pending_events_enabled;
static void moal_bridge_pending_work_fn(struct work_struct *work);
static DECLARE_WORK(bridge_pending_work, moal_bridge_pending_work_fn);
```

Implement helpers that each acquire `bridge_pending_lock` internally:

```c
static unsigned long moal_bridge_pending_set(const char *ifname);
static bool moal_bridge_pending_matches(const char *ifname,
                                        unsigned long generation);
static bool moal_bridge_pending_clear_if(const char *ifname,
                                         unsigned long generation);
static void moal_bridge_pending_snapshot(char *ifname, size_t len,
                                         unsigned long *generation,
                                         enum moal_bridge_pending_state *state);
static void moal_bridge_pending_schedule_event(unsigned long event);
```

Increment generation on set, replacement, cancellation, and unregister cancellation so queued stale work cannot match a newer request. Do not hold this spinlock while printing, resolving targets, acquiring RTNL, or switching.

- [ ] **Step 4: Integrate deferred admission into the existing transaction**

Refactor the public entry into a common internal request function while preserving the current public signature:

```c
static int moal_bridge_switch_iface_request(const char *ifname,
                                             bool allow_defer,
                                             unsigned long expected_generation);

int moal_bridge_switch_iface(const char *ifname)
{
    return moal_bridge_switch_iface_request(ifname, true, 0);
}
```

Under the existing `AddRemoveCardSem -> bridge_lifecycle_lock` order:

- structurally resolve the target;
- detect a current-active-name write before operational checks;
- in deferred mode, use that write to clear pending and return a successful no-op;
- validate/pin the current peer before accepting a new pending request;
- if link status is `-ENETDOWN` or `-ENOLINK` and `allow_defer` plus `bridge_runtime_deferred==1`, set pending, keep `bridge_owner` unchanged, release the peer reference, and return success;
- otherwise preserve the current synchronous error or transactional switch;
- clear pending after a successful immediate switch only if it has not been replaced by another generation.

Do not increment `switch_ok`, `switch_fail`, or rollback counters when merely registering, replacing, cancelling, or rechecking a waiting request.

- [ ] **Step 5: Implement event scheduling and worker completion**

Before the notifier's existing `dev != peer && dev != wlan` early return, pass relevant events to the non-sleeping scheduler:

```c
if (event == NETDEV_UP || event == NETDEV_CHANGE ||
    event == NETDEV_CHANGENAME || event == NETDEV_UNREGISTER)
    moal_bridge_pending_schedule_event(event);
```

`moal_bridge_pending_schedule_event()` acquires `bridge_pending_lock`, checks
`bridge_pending_events_enabled`, `bridge_runtime_deferred`, and non-empty pending
state, then calls `schedule_work()` before releasing the lock. It must not use a
readiness check followed by an unlocked `schedule_work()`: teardown could clear
readiness and finish `cancel_work_sync()` between those operations.

The worker snapshots name/generation, calls the common request with `allow_defer=false`, and classifies the result:

- ready and switch success: clear matching generation;
- `-ENETDOWN`, `-ENOLINK`, reset/reload `-EBUSY`, or temporarily absent active owner: restore matching state to waiting;
- structurally missing/wrong target after unregister/rename: clear matching generation and log permanent cancellation;
- target transaction failure with a healthy rollback: retain waiting for a later link event and log errno;
- terminal rollback failure: clear pending because no old owner remains.

Queue one additional kick after successful bridge init/resume publication so a pending request retained across a temporary reset does not require an unrelated future carrier event.

- [ ] **Step 6: Add active/pending read separation and stats**

Declare in `moal_bridge.h`:

```c
int moal_bridge_get_pending_iface(char *buf, size_t len);
void moal_bridge_pending_start(void);
void moal_bridge_pending_cleanup(void);
```

Add a getter-only module parameter in `moal_init.c`:

```c
static int bridge_pending_iface_get(char *buf, const struct kernel_param *kp)
{
    (void)kp;
    return moal_bridge_get_pending_iface(buf, PAGE_SIZE);
}

static const struct kernel_param_ops bridge_pending_iface_ops = {
    .get = bridge_pending_iface_get,
};

module_param_cb(bridge_pending_iface, &bridge_pending_iface_ops, NULL, 0444);
```

Snapshot pending state under its spinlock in `stats_show()` before formatting both active and inactive output. Emit exactly:

```text
iface=mlan1 peer=eth0 pending_iface=mlan0 pending_state=waiting
```

Use `none` for no pending interface and state. Do not take a sleeping mutex inside the existing RCU read-side section.

- [ ] **Step 7: Drain pending work at teardown**

Implement an admission handshake:

```c
void moal_bridge_pending_start(void)
{
    unsigned long flags;

    spin_lock_irqsave(&bridge_pending_lock, flags);
    bridge_pending_events_enabled = true;
    spin_unlock_irqrestore(&bridge_pending_lock, flags);
}

void moal_bridge_pending_cleanup(void)
{
    unsigned long flags;

    spin_lock_irqsave(&bridge_pending_lock, flags);
    bridge_pending_events_enabled = false;
    /* clear state and advance generation */
    spin_unlock_irqrestore(&bridge_pending_lock, flags);
    cancel_work_sync(&bridge_pending_work);
}
```

Call `moal_bridge_pending_start()` immediately before publishing
`bridge_runtime_control_ready=1`. Call cleanup in `woal_cleanup_module()`
immediately after:

```c
WRITE_ONCE(bridge_runtime_control_ready, 0);
```

and before any `down(&AddRemoveCardSem)`. Because the notifier schedules while
holding the same lock used to disable admission, every pre-disable enqueue is
visible to the following `cancel_work_sync()` and every post-disable notifier is
rejected. Ensure `moal_bridge_forget_handle()` or the unregister-triggered worker
permanently cancels a request naming a disappearing target before its name can
be reused.

- [ ] **Step 8: Run source, mutation, syntax, and diff gates**

```bash
rtk bash -n scripts/tests/bridge_static_checks.sh
rtk bash -n scripts/tests/bridge_runtime_switch_qa.sh
rtk ./scripts/tests/bridge_static_checks.sh
rtk git diff --check -- mlinux/moal_bridge.c mlinux/moal_bridge.h mlinux/moal_init.c mlinux/moal_main.c scripts/tests/bridge_static_checks.sh
```

Expected: every new negative mutation is rejected, all pre-existing runtime/reset/rollback gates pass, and both Bash scripts are syntactically valid.

- [ ] **Step 9: Commit the runtime state machine**

```bash
rtk git add mlinux/moal_bridge.c mlinux/moal_bridge.h mlinux/moal_init.c mlinux/moal_main.c scripts/tests/bridge_static_checks.sh
rtk git commit -m "feat(moal): defer bridge switch until link readiness"
```

---

### Task 4: Add Target QA and Complete Operator Documentation

**Files:**
- Modify: `scripts/tests/bridge_runtime_switch_qa.sh:1-90,220-620`
- Modify: `scripts/tests/bridge_static_checks.sh:420-700`
- Modify: `docs/MOAL-Module-Parameters.md:215-370`
- Modify: `docs/runtime-bridge-interface-switch.design.md:45-90,245-285,330-405`
- Modify: `docs/driver-bridge.qa-runbook.md:231-410`

**Interfaces:**
- Consumes: `bridge_runtime_deferred`, `bridge_pending_iface`, pending stats fields and logs.
- Produces: reproducible target evidence for strict default, waiting, automatic switch, cancellation, and destructive interaction.

- [ ] **Step 1: Add failing static checks for QA case coverage**

Require the QA script to define and dispatch these exact cases:

```text
deferred-off
deferred-wait
deferred-cancel
```

Require reads of both parameter paths and assertions that a waiting request leaves `bridge_iface`, `active=1`, and all switch/rollback counters unchanged.

- [ ] **Step 2: Run syntax/static gates and confirm the coverage check fails**

```bash
rtk bash -n scripts/tests/bridge_runtime_switch_qa.sh
rtk ./scripts/tests/bridge_static_checks.sh
```

Expected: syntax passes; static check reports missing deferred QA cases.

- [ ] **Step 3: Extend QA setup, capture, and cleanup**

Add:

```bash
DEFERRED_PARAM="$PARAM_DIR/bridge_runtime_deferred"
PENDING_PARAM="$PARAM_DIR/bridge_pending_iface"
DEFERRED_TIMEOUT="${DEFERRED_TIMEOUT:-30}"
```

Capture both values in every state artifact. Cleanup must cancel a surviving pending request by writing the current active interface before attempting binding restoration, then verify `bridge_pending_iface` is `none` or empty. Retain the existing fail-closed dmesg follower and one-shot fault disarm behavior.

- [ ] **Step 4: Implement the default-off and waiting cases**

`deferred-off`:

```bash
require_gate 1
test "$(tr -d '\r\n' < "$DEFERRED_PARAM")" = 0 || fail "deferred gate must be 0"
ip link set dev "$TO_IF" down
run_prevalidation_reject "$TO_IF" 100
```

`deferred-wait` must:

1. require deferred gate `1`, active `FROM_IF`, healthy peer, and associated `FROM_IF`;
2. set `TO_IF` administratively down and prove it is not ready;
3. snapshot binding and switch/rollback counters;
4. write `TO_IF` and require success;
5. require active binding still equals `FROM_IF`, `active=1`, pending equals `TO_IF`, and all outcome counters are unchanged;
6. bring `TO_IF` up and wait up to `DEFERRED_TIMEOUT` for association, active binding `TO_IF`, and empty pending;
7. require `switch_ok` increased exactly once with no failure/rollback delta.

- [ ] **Step 5: Implement cancellation and replacement evidence**

`deferred-cancel` registers down `TO_IF`, writes current `FROM_IF`, and requires pending to clear with no owner/counter change. Where only two STA interfaces exist, document replacement as a concurrent-writer/manual extension rather than inventing a nonexistent third target.

Add a runbook-only unregister/name-reuse case because target unregister may remove the module or require a board-specific bus command. Its pass criteria are: pending clears, no later switch occurs after a same-name netdev appears, current owner remains valid, and no kernel warning appears.

- [ ] **Step 6: Update the design and parameter docs**

Document:

- default-off synchronous compatibility;
- one-write application API;
- active versus pending getter semantics;
- no timeout and cancel/replace rules;
- worker/event/error classification;
- target-ready does not mean end-to-end AP traffic is proven;
- separate status from the same-MAC/multi-BSSID mlan1 investigation.

- [ ] **Step 7: Run host QA gates**

```bash
rtk bash -n scripts/tests/bridge_runtime_switch_qa.sh
rtk bash -n scripts/tests/bridge_static_checks.sh
rtk ./scripts/tests/bridge_static_checks.sh
rtk git diff --check -- scripts/tests/bridge_runtime_switch_qa.sh scripts/tests/bridge_static_checks.sh docs/MOAL-Module-Parameters.md docs/runtime-bridge-interface-switch.design.md docs/driver-bridge.qa-runbook.md
```

Expected: syntax, static mutations, documentation contract, and diff-check pass. Record that target QA is not executed on the build host.

- [ ] **Step 8: Commit QA and documentation**

```bash
rtk git add scripts/tests/bridge_runtime_switch_qa.sh scripts/tests/bridge_static_checks.sh docs/MOAL-Module-Parameters.md docs/runtime-bridge-interface-switch.design.md docs/driver-bridge.qa-runbook.md
rtk git commit -m "test(moal): cover deferred bridge switching"
```

---

### Task 5: Review, Freeze, Build Once per Target, and Report

**Files:**
- Review: every file changed by Tasks 1-4
- Create: `.superpowers/sdd/runtime-bridge-interface-switch.implementation-plan/deferred-switch-validation.md`

**Interfaces:**
- Consumes: complete deferred feature and QA contracts.
- Produces: code-freeze verdict, host gate evidence, one i.MX93 build, one final i.MX8 build, and explicit target-runtime caveats.

- [ ] **Step 1: Run the complete host gate before review**

```bash
rtk bash -n scripts/tests/bridge_runtime_switch_qa.sh
rtk bash -n scripts/tests/bridge_static_checks.sh
rtk ./scripts/tests/bridge_static_checks.sh
rtk git diff --check
rtk git status --short
```

Expected: all gates pass; status lists only intentional feature changes plus the pre-existing unrelated local files.

- [ ] **Step 2: Perform a focused code review before code freeze**

Review these invariants line-by-line:

- lock order is always `AddRemoveCardSem -> bridge_lifecycle_lock -> bridge_pending_lock`;
- notifier never waits, resolves, or switches;
- worker never retains a pointer across semaphore/lifecycle release;
- target init/terminal validation and rollback are unchanged for immediate switching;
- stale generation cannot clear a replacement;
- module exit closes scheduling before `cancel_work_sync` and does not hold `AddRemoveCardSem` while cancelling;
- stats do not sleep under RCU;
- same-target cancellation cannot deactivate the current bridge.

If any invariant fails, return to the owning task, add a negative mutation or QA assertion, fix it, and repeat Steps 1-2 before building.

- [ ] **Step 3: Freeze code and run the single i.MX93 build**

After review reports no blocking issue:

```bash
rtk ./make_for_imx93.sh
```

Expected: exit 0 and `bin_wlan/moal_imx93.ko` is produced. Do not rerun merely for intermediate edits; any post-build production edit invalidates freeze and requires explicit user approval before another build.

- [ ] **Step 4: Run the final single i.MX8 build**

```bash
rtk ./make_for_imx8.sh
```

Expected: exit 0 and the i.MX8 MOAL module is produced. Record compiler warnings separately and distinguish pre-existing warnings from new ones.

- [ ] **Step 5: Record target QA commands without claiming execution**

```bash
QA_CASE=deferred-off FROM_IF=mlan0 TO_IF=mlan1 \
  ./scripts/tests/bridge_runtime_switch_qa.sh
QA_CASE=deferred-wait FROM_IF=mlan0 TO_IF=mlan1 DEFERRED_TIMEOUT=30 \
  ./scripts/tests/bridge_runtime_switch_qa.sh
QA_CASE=deferred-cancel FROM_IF=mlan0 TO_IF=mlan1 \
  ./scripts/tests/bridge_runtime_switch_qa.sh
```

The report must mark these as `NOT RUN` until target artifacts are returned. Required target evidence includes active/pending getters, stats before/waiting/after, switch counter deltas, full follow-new dmesg, association state, and absence of KASAN/lockdep/UAF/hung-task signatures.

- [ ] **Step 6: Write the validation report and final commit**

Write exact command results, commit IDs, artifact paths, warnings, unexecuted target cases, and the separate unresolved mlan1 data-plane diagnosis to:

```text
.superpowers/sdd/runtime-bridge-interface-switch.implementation-plan/deferred-switch-validation.md
```

Then commit only the report if that directory is tracked; otherwise leave it as a local evidence artifact and report its path. Verify the final diff one more time:

```bash
rtk git diff --check b3f04b2..HEAD
rtk git status --short
```

Expected: no whitespace errors and no unrelated local modification included in feature commits.
