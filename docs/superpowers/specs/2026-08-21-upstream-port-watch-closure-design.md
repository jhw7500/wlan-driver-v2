# Upstream Port Runtime WATCH Closure Design

**Status:** Approved for execution by the user's 2026-08-21 “진행” direction.

## Objective

Close every safely executable runtime WATCH item left by the NXP mwifiex
`0396cfb..2e481212` port, while preserving the validated in-band SD9098
baseline and making unsupported or unsafe scenarios explicit rather than
claiming unearned coverage.

The source baseline for this qualification is `734f75b`; the documentation
HEAD at design time is `5f8d10a` on
`port/upstream-61820-0396-clean`.

## Fixed target facts

- Target: i.MX93, with SSH carried by the wired `eth0` management path.
- Wi-Fi transport: SD9098 DBDC, SDIO functions `02df:914d` and `02df:914e`.
- Validated module source: `/opt/wlan/driver/*_imx93.ko`, loaded directly by
  `/usr/local/scripts/wifi_init.sh` with `insmod`.
- Validated active version before this work: `mlan=543.p18`, `moal=543.p18`.
- Current runtime mode: in-band SDIO interrupts. No `nxp_oob_sdio_irq` action
  is registered.
- Shared OOB line: IRQ 102, level-low, currently owned by two
  `wifi_oob_wakeup` actions.
- Driver lookup: `woal_request_gpio()` searches only for
  `nxp,wifi-oob-int`.
- Board DT: the matching hardware node is compatible with
  `nxp,wifi-wake-host`; no `nxp,wifi-oob-int` compatible exists.
- Power management: `freeze` and `mem` are available; `s2idle` and `deep`
  are selectable; RTC wakealarm is enabled and writable.
- Runtime exclusions: no enumerated PCIe or USB WLAN device and
  `CONFIG_FAULT_INJECTION` is disabled.
- `/lib/modules/.../updates/{mlan,moal}.ko` remain vendor `437.p3` copies and
  are not the files loaded by `wifi_init.service`.

## Selected approach

Use a driver-side compatible fallback, not an ad-hoc DTB replacement.
`woal_request_gpio()` will continue to prefer the existing
`nxp,wifi-oob-int` binding and will fall back to the board's
`nxp,wifi-wake-host` node only on i.MX. The function will reject a zero IRQ
mapping and release the device-tree node reference after parsing.

This approach is selected because it:

1. preserves compatibility with boards already using the driver's original
   binding;
2. enables the currently deployed board without replacing its DTB or
   rebooting it;
3. remains self-contained in the driver and is testable by source invariants;
4. fails safely with `devm_request_irq()` if the existing wake handlers do
   not permit another shared action.

Rejected alternatives:

- **Modify and deploy the target DTB:** wider blast radius, requires reboot,
  and couples this driver port to an image artifact outside this repository.
- **Static-only closure:** cannot validate the OOB action/WQ lifecycle that
  motivated the final SDIO changes.
- **Add a production fault-injection module parameter:** expands the shipped
  attack/failure surface solely for testing and can deliberately wedge the
  SDIO function or shared level-low line.

## Source and test changes

### OOB binding compatibility

Modify `mlinux/moal_sdio_mmc.c` so that `woal_request_gpio()`:

1. looks up `nxp,wifi-oob-int` first;
2. looks up `nxp,wifi-wake-host` only when the first lookup fails;
3. returns `-ENODEV` when neither node exists;
4. calls `irq_of_parse_and_map(node, 0)` and rejects IRQ 0 with `-ENXIO`;
5. calls `of_node_put(node)` on every post-lookup exit;
6. retains the existing shared, level-low `devm_request_irq()` behavior.

Extend `scripts/tests/upstream_port_invariants.py` with positive and mutation
checks proving lookup preference, fallback availability, zero-map rejection,
and node-reference release. The test must fail against `734f75b` before the
implementation and pass afterward.

### Durable runtime evidence

Record the exact test sequence and results in
`docs/upstream-port-0396-code-review.md`. Target logs may remain under a
private target staging directory but must not be committed when they contain
SSID, BSSID, MAC address, or local network details.

## Target rollout architecture

### Backup and automatic rollback

Before changing either modules or the active firmware parameter file:

- copy the four currently deployed artifacts and
  `/usr/lib/firmware/cts/wifi_mod_para.conf` into a timestamped backup;
- stage the new artifacts and SHA-256 manifest under a new immutable
  `/opt/wlan/staging/` directory;
- install a transient systemd rollback unit/timer with a 90-minute ultimate
  deadline;
- make rollback restore both modules and the parameter file, restart
  `wifi_init.service`, and leave an append-only log;
- cancel the rollback timer only after the full selected target slice passes.

The deployed baseline after qualification will return to `intmode=0` unless
the user explicitly requests OOB as the production default.

### OOB enablement

Add `intmode=1` to both `SD9098_0` and `SD9098_1` blocks in the active
`wifi_mod_para.conf`. No `gpiopin` value is required on i.MX because the IRQ
is mapped from the DT node.

After restart, require all of the following:

- both module versions are `543.p18`;
- `wifi_init`, `wpa_supplicant@mlan0`, `wifi_bridge@mlan0`, and
  `wifi_logger_temp` are active;
- both SDIO functions and both network interfaces are present;
- the STA interface reconnects;
- IRQ 102 contains `nxp_oob_sdio_irq` action ownership in addition to the
  existing wake actions;
- OOB IRQ counts advance under WLAN traffic;
- the idle IRQ rate remains below 10,000 interrupts/second;
- no timeout, BUG, WARNING, Oops, Call Trace, KASAN, lockdep, UAF, or general
  protection signature appears after the test marker.

### Shared-IRQ and teardown stress

While OOB traffic is active, perform ten bounded `wifi_init.service` restart
cycles. Each cycle must reconnect within 120 seconds, restore both DBDC
interfaces, re-register OOB actions, pass a 20-packet WLAN ping, and show no
kernel-health signature. This exercises action removal, WQ draining, disable
token balancing, and sibling-function callback barriers while the shared
level-low line is live.

The terminal case where CCCR source disable, whole-function disable, and
reset all fail cannot be induced safely on this kernel. Its dynamic status
remains **BLOCKED_BY_PLATFORM**; the accepted substitute is the existing
mutation suite plus live-source teardown stress. No claim will convert that
substitute into proof of physical-source quiescence.

### Suspend and resume

Use `rtcwake` with a 20-second RTC alarm so loss of SSH cannot leave the target
indefinitely suspended. Run one `s2idle` cycle and one `deep` cycle while OOB
is enabled. After each resume, require service recovery, STA reconnection,
OOB action presence, advancing traffic IRQs, a 20-packet ping, and clean
kernel logs. Restore the original `/sys/power/mem_sleep` selection afterward.

### Long traffic

Run a 30-minute WLAN ping at one-second cadence with bounded per-packet
timeout. If an iperf3 server is reachable on the WLAN peer, add a bounded
bidirectional throughput probe; server absence is reported as
**BLOCKED_BY_ENVIRONMENT**, not a driver failure. Require zero service loss,
no kernel-health signature, no IRQ storm, and no more than 0.5% ping loss.

## Stop and rollback conditions

Rollback immediately when any of these occurs:

- module insertion or firmware initialization fails;
- STA/service recovery exceeds 120 seconds;
- SSH does not return within 180 seconds after RTC suspend;
- either SDIO function or expected interface disappears;
- OOB action registration is absent after an OOB-mode restart;
- idle OOB IRQ rate reaches 10,000 interrupts/second;
- ping loss exceeds 5% in a short gate or 0.5% in the 30-minute gate;
- any listed kernel-health signature appears.

Do not force-reset the card, overwrite the board DTB, replace packaged
`/lib/modules` files, or add fault hooks in order to make a blocked scenario
appear tested.

## Coverage classification

| WATCH item | Planned result |
|---|---|
| OOB registration, traffic, reload, DBDC teardown | Dynamic target PASS/FAIL |
| OOB suspend/resume (`s2idle`, `deep`) | Dynamic target PASS/FAIL |
| Thirty-minute SDIO/OOB traffic | Dynamic target PASS/FAIL |
| All-hardware-cleanup-fails physical IRQ liveness | BLOCKED_BY_PLATFORM plus safe substitute |
| USB runtime | BLOCKED_BY_HARDWARE |
| PCIe runtime/FLR | BLOCKED_BY_HARDWARE |
| `/lib/modules` vendor copy mismatch | Documented packaging WATCH; no ad-hoc overwrite |

## Completion criteria

This qualification is complete when:

1. the source invariant follows a demonstrated RED-to-GREEN cycle;
2. local final checks and exact `make_for_imx93.sh` build pass;
3. the OOB reload, shared-IRQ traffic, suspend/resume, and long-traffic slices
   either pass or stop through the defined rollback path;
4. the target is left healthy with the original in-band runtime setting;
5. generated target harnesses and timers are removed or intentionally retained
   as named evidence;
6. the worktree is clean, commits are pushed, and Draft PR #27 reports both
   positive evidence and every blocked residual without an unqualified
   merge-ready claim.
