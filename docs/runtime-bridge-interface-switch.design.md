# Runtime MOAL Bridge Interface Switch Design

**Date:** 2026-08-13  
**Repository:** `wlan-driver-v2`  
**Target branch:** `main`  
**Status:** Approved design; implementation pending

## 1. Objective

Allow an application to switch an already-active in-driver MOAL L2 bridge
between connected STA interfaces such as `mlan0` and `mlan1` without unloading
`moal.ko` or reloading firmware.

The application contract is a synchronous sysfs write:

```sh
echo mlan1 > /sys/module/moal/parameters/bridge_iface
```

When the write returns success, forwarding is active on the requested WLAN
interface. On failure, the write returns a negative errno and the previous
bridge is restored whenever rollback succeeds.

## 2. Compatibility Requirements

Existing behavior is the primary invariant.

1. `bridge_runtime_switch` defaults to `0`.
2. When it is `0`, bridge initialization, forwarding, parameters, and teardown
   behave exactly as they do before this feature.
3. Writing `bridge_iface` never enables a disabled bridge. If no bridge is
   active, the operation fails.
4. The target must already exist as a registered STA netdev and be operational
   and associated. A disconnected target is rejected before the current bridge
   is disturbed.
5. Existing load-time parameters `bridge_mode`, `bridge_peer`, and
   `bridge_wlan_idx` retain their meanings.
6. Existing runtime parameters (`bridge_debug`, keepalive controls,
   `bridge_local_hairpin`, and diagnostic controls) retain their behavior.

## 3. User-Facing Interface

### 3.1 Opt-in gate

Add a load-time option:

```text
bridge_runtime_switch=0|1
```

- Type: integer/boolean.
- Default: `0`.
- Sysfs permission: `0444`; changing the feature gate itself requires module
  reload.
- It is a global module option supplied alongside `mod_para`, for example
  `insmod moal.ko mod_para=... bridge_runtime_switch=1`. It is deliberately not
  a per-radio `wifi_mod_para.conf` key because one global bridge instance moves
  between radio handles.

The gate is intentionally load-time-only. This prevents an application from
changing lifecycle policy accidentally on a deployed system and makes legacy
behavior the unconditional default.

### 3.2 Synchronous target parameter

Add a custom module parameter:

```text
/sys/module/moal/parameters/bridge_iface
```

- Implemented with `module_param_cb()`, not `charp`.
- Permission: `0644` when compiled with runtime switching support.
- Read returns the active bridge WLAN netdev name followed by a newline, for
  example `mlan0`.
- Read returns `none` when there is no active bridge.
- Write accepts one interface name, with the sysfs trailing newline removed.
- Names must fit `IFNAMSIZ` and resolve to a MOAL STA netdev.
- Writing the already-active interface is a successful no-op.
- The setter does not merely store text; it performs and completes the switch
  before returning.

Example application flow:

```c
fd = open("/sys/module/moal/parameters/bridge_iface", O_WRONLY);
if (fd < 0)
        /* feature unavailable or permissions failure */;

if (write(fd, "mlan1\n", 6) < 0)
        /* inspect errno; the old bridge should still be active */;
/* success: bridge is now active on mlan1 */
```

No ioctl, netlink message, helper process, or polling protocol is required.

## 4. Architecture

### 4.1 Rebind, not pointer hot-swap

The switch reuses the bridge lifecycle. It must not modify only
`br->wlan_dev` or `br->wlan_priv`, because the bridge context also owns cached
MAC/IP data, two forwarding queues, two kthreads, a keepalive timer, notifier
registrations, peer capture state, RCU-visible pointers, and a sysfs statistics
pointer.

The implementation performs:

```text
old bridge deinit -> RCU/net drain -> new bridge init
```

This creates a short forwarding interruption but preserves the existing safety
properties of `moal_bridge_deinit()`.

### 4.2 Global lifecycle state

Add bridge lifecycle state in `mlinux/moal_bridge.c`:

```c
static DEFINE_MUTEX(bridge_lifecycle_lock);
static moal_handle *bridge_owner;
```

The existing `bridge_instance_active` single-instance guard remains. The owner
identifies which DBDC `moal_handle` currently publishes `handle->bridge`.

Refactor lifecycle functions into locked internals plus public wrappers:

```c
static int __moal_bridge_init_locked(...);
static void __moal_bridge_deinit_locked(...);

int moal_bridge_init(...);       /* takes bridge_lifecycle_lock */
void moal_bridge_deinit(...);    /* takes bridge_lifecycle_lock */
int moal_bridge_switch_iface(const char *ifname);
int moal_bridge_get_iface(char *buf, size_t len);
```

`moal_bridge_switch_iface()` takes the lifecycle mutex once and calls the
locked internal helpers, avoiding recursive mutex acquisition.

### 4.3 DBDC target discovery

`mlan0` and `mlan1` are separate radio instances/handles in the deployed 9098
DBDC configuration. Target discovery therefore scans `m_handle[]`, and then
each handle's `priv[]`, to resolve an interface name to:

```text
(target_handle, target_bss_index, target_priv, target_netdev)
```

The target must satisfy all of the following before teardown begins:

- exact netdev name match;
- `bss_type == MLAN_BSS_TYPE_STA`;
- `netdev->reg_state == NETREG_REGISTERED`;
- `netif_device_present(netdev)`;
- `netif_running(netdev)`;
- `target_priv->media_connected == MTRUE`;
- target is not being removed or reset.

The scan and lifecycle transition must be serialized against card add/remove.
The lock order is:

```text
AddRemoveCardSem -> bridge_lifecycle_lock -> RTNL (inside init/deinit)
```

Normal driver load/unload paths already owning `AddRemoveCardSem` call the
public bridge init/deinit wrappers but do not reacquire that semaphore. The
runtime switch entry acquires `AddRemoveCardSem` before the lifecycle mutex.
No path may take these locks in reverse order.

## 5. Synchronous Switch Transaction

The setter calls `moal_bridge_switch_iface()` in process context.

1. Reject unless `bridge_runtime_switch == 1`.
2. Parse and validate the requested interface name.
3. Acquire `AddRemoveCardSem`, then `bridge_lifecycle_lock`.
4. Verify an active, healthy bridge and capture a rollback snapshot:
   - old owner handle;
   - old BSS index and WLAN name;
   - peer interface name;
   - effective bridge parameters that will be changed.
5. Resolve and fully validate the target tuple.
6. If the target equals the active WLAN, return success without teardown.
7. Deactivate and fully deinitialize the old bridge using the existing order:
   forwarding stop, timer/notifier/capture removal, `synchronize_net()`, RCU
   pointer clear and `synchronize_rcu()`, kthread stop, and queue purge.
8. Initialize a bridge on the target handle with the same peer interface and
   effective keepalive/hairpin/debug policy.
9. On success, update effective per-handle bridge ownership parameters:
   old owner `bridge_mode=0`; new owner `bridge_mode=1`; new owner's
   `bridge_wlan_idx` is the resolved BSS index. These are in-memory runtime
   values only; persistent configuration is not rewritten.
10. Release locks and return success.

The setter must not hold RTNL across the entire transaction. Existing lifecycle
helpers acquire RTNL only around operations that require it.

## 6. Rollback and Error Contract

Target validation occurs before teardown so common errors leave the active
bridge untouched.

| Condition | errno | Existing bridge |
|---|---:|---|
| Runtime switching disabled | `-EOPNOTSUPP` | unchanged |
| No active bridge | `-ENODEV` | none |
| Empty, oversized, or malformed name | `-EINVAL` | unchanged |
| Interface not found | `-ENODEV` | unchanged |
| Interface is not a MOAL STA | `-EINVAL` | unchanged |
| Target netdev not operational | `-ENETDOWN` | unchanged |
| Target STA not associated | `-ENOLINK` | unchanged |
| Driver/card reset or removal in progress | `-EBUSY` | unchanged |
| Requested interface already active | success | unchanged |
| New bridge initialization fails | original init errno | rollback attempted |

If new initialization fails after old teardown:

1. restore the old effective parameters;
2. reinitialize the old bridge from the rollback snapshot;
3. return the new-target initialization errno.

If rollback also fails, leave both `bridge_mode` effective states disabled,
clear the global owner, log both errors at `MERROR`, and return `-EIO`. This is
the only permitted failure mode where the previous bridge is not restored.
The application can distinguish it through errno and by reading
`bridge_iface`, which returns `none`.

## 7. State and Observability

Extend `/sys/kernel/moal_bridge/stats` with non-breaking lines:

```text
iface=mlan1 peer=eth0
switch_ok=4 switch_fail=1 rollback_ok=1 rollback_fail=0
```

Existing lines and their meanings remain unchanged. Counters are global across
rebinds so operations can diagnose switching even though individual bridge
contexts are replaced.

Kernel messages should record one line for request and one terminal result:

```text
bridge: runtime switch requested mlan0 -> mlan1
bridge: runtime switch complete mlan0 -> mlan1
```

Failures include target, errno, and rollback result but no per-packet logging.

## 8. Files in Scope

- `mlinux/moal_bridge.h`
  - lifecycle switch/get APIs and any shared declarations.
- `mlinux/moal_bridge.c`
  - lifecycle mutex/owner, target discovery, transaction, rollback, counters,
    and lifecycle refactor.
- `mlinux/moal_init.c`
  - `bridge_runtime_switch`, custom `bridge_iface` parameter ops, configuration
    parsing, and effective parameter setup.
- `scripts/tests/bridge_static_checks.sh`
  - lock/lifecycle/control-path invariants.
- `docs/MOAL-Module-Parameters.md`
  - user-facing option, sysfs path, errno, and example.
- `docs/driver-bridge.qa-runbook.md`
  - target validation, switching, rollback, and stress procedures.

No application repository changes, firmware changes, packet format changes,
or persistent JSON rewriting are part of this driver change.

## 9. Validation

### 9.1 Static and build checks

- Existing `scripts/tests/bridge_static_checks.sh` passes.
- Add checks proving:
  - opt-in default is zero;
  - custom `module_param_cb` is used;
  - lifecycle operations are mutex-serialized;
  - switch uses full deinit/init, not direct WLAN pointer replacement;
  - rollback path exists;
  - RCU and network drain ordering remains intact.
- i.MX8 and i.MX93 driver builds pass using existing build gates.
- `git diff --check` passes.

### 9.2 Target-board functional matrix

1. Gate disabled: write returns `EOPNOTSUPP`; traffic remains on `mlan0`.
2. Bridge disabled: write returns `ENODEV`; bridge remains disabled.
3. Invalid/non-MOAL/non-STA target: rejected without traffic interruption.
4. Disconnected `mlan1`: `ENOLINK`; `mlan0` forwarding continues.
5. Same target: success no-op; counters and traffic continue.
6. Connected `mlan0 -> mlan1`: write blocks until complete, then bidirectional
   traffic uses `mlan1`.
7. Connected `mlan1 -> mlan0`: symmetric success.
8. Concurrent writers: serialized; each successful return corresponds to its
   requested final binding at its linearization point.
9. Repeated switching under bidirectional load: at least 1,000 cycles with no
   warning, lockdep report, leak, stuck kthread, queue corruption, or crash.
10. Peer down/up after a switch: existing suspend/resume behavior works on the
    newly bound WLAN.
11. Module unload after switching: no stale sysfs node, handler, timer, thread,
    or netdev reference.
12. Forced initialization failure: old bridge is restored; forced rollback
    failure produces `EIO`, `bridge_iface=none`, and explicit error logging.

### 9.3 Success criteria

- With `bridge_runtime_switch=0`, binary behavior is unchanged except for the
  inert read-only gate and documented control surface.
- With the gate enabled, a successful sysfs write means the requested connected
  STA is already forwarding in both directions.
- All validation failures before teardown leave the active bridge untouched.
- Any post-teardown failure restores the previous bridge unless rollback itself
  fails, which is explicit and observable.

## 10. Non-goals

- Seamless or lossless handover; a short forwarding gap is expected.
- Associating or configuring the target WLAN from the driver.
- Automatically choosing an interface based on RSSI or link quality.
- Enabling a bridge by writing `bridge_iface` when `bridge_mode=0`.
- Supporting multiple simultaneous bridge instances.
- Persisting the runtime selection across module reload or reboot.
- Guaranteeing preservation of upper-layer TCP sessions across different AP,
  subnet, MAC, or routing domains.
