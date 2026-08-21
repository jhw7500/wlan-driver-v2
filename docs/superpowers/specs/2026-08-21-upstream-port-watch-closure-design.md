# Upstream Port Runtime WATCH Closure Design

**Status:** Executed — blocked by platform policy.

## Objective

Close every safely executable runtime WATCH item left by the NXP mwifiex
`0396cfb..2e481212` port, while preserving the validated in-band SD9098
baseline and making unsupported or unsafe scenarios explicit rather than
claiming unearned coverage.

The source baseline for this qualification is `734f75b`; the documentation
HEAD at design time is `5f8d10a` on
`port/upstream-61820-0396-clean`.

Execution advanced the source/test qualification HEAD to
`c4644eee070c3a735e83037fdefdfbaf3d74ea8e`. The final documentation-only commit
uses subject `docs: record OOB WATCH qualification`; independent reviews, push,
Draft PR update, and merge decisions remain controller-owned follow-up work.

## Final review evidence scopes

- final fixed host build source `f11420820bc73196eee837a9896f120b86364b57`:
  rebuilt on the controller with the i.MX93 SDK after the APF/Android/SAE final
  fixes; it was never staged, installed, or loaded on the target.
- c464 target-staged OOB attempt source `c4644eee070c3a735e83037fdefdfbaf3d74ea8e`:
  retained as inactive and unqualified staging evidence only.
- historical 734f75b evidence source `734f75bf02a3e5ac4c84a696d8a873ed11247ce3`:
  limited to the previously executed bounded in-band reload/STA slice.

No target access occurred during the final-review fix wave. The active target
state therefore remains the restored pre-qualification in-band `543.p18` backup;
OOB runtime remains NOT EXECUTED — `0/10` cycles, and suspend/traffic-dependent
slices remain `BLOCKED_BY_PREREQUISITE`.

## Fixed pre-execution target facts

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

## Executed coverage classification

The selected target runtime did not pass or fail: production platform policy
stopped it at the initial restart before the health gate. Cleanup and baseline
restoration are proved, which permits the executed status without implying that
any selected OOB runtime slice passed.

| WATCH item | Executed result |
|---|---|
| OOB initial health and action count | NOT EXECUTED — Task 4 `BLOCKED_BY_PLATFORM` |
| OOB traffic IRQ delta and idle storm | NOT EXECUTED — healthy-OOB gate not reached |
| OOB traffic-active reload/DBDC teardown | NOT EXECUTED — `0/10` cycles |
| OOB suspend/resume (`s2idle`, `deep`) | NOT EXECUTED / `BLOCKED_BY_PREREQUISITE` |
| Thirty-minute OOB ping and iperf | NOT EXECUTED / `BLOCKED_BY_PREREQUISITE`; peer/server environment was not probed |
| All-hardware-cleanup-fails physical IRQ liveness | separate `BLOCKED_BY_PLATFORM`; static mutations and earlier live substitute do not prove physical-source quiescence |
| USB runtime | `BLOCKED_BY_HARDWARE` |
| PCIe runtime/FLR | `BLOCKED_BY_HARDWARE` |
| `/lib/modules` vendor copy mismatch | inactive `437.p3` copies unchanged; active runtime restored from the in-band `543.p18` backup |

## Execution outcome and cleanup

- `c4644eee` added preferred/fallback DT lookup plus mutation-tested node/IRQ and
  lifecycle hygiene. The new invariant recorded actual RED exit `1`, then GREEN
  exit `0`; the aggregate suite passed.
- Task 2 produced exact staged artifacts and an exit-`0` i.MX93 build with exactly
  three known `mlanutl` warnings: unchecked `fgets`, fortified `memcpy` bounds,
  and fortified `strncpy` bounds.
- Task 3 backup, stage, manifest verification, baseline-only rollback rehearsal,
  and 90-minute rollback-timer proof succeeded.
- At Task 4's canceled initial restart, production `wifi_checker` classified the
  intentional module-reload netdev gap as `fw_crash`; reboot policy approved a
  board reboot. The test script had no reboot action. Previous-boot kernel
  journal evidence was unavailable, so neither OOB success nor driver failure is
  inferred. Target wall-clock skew is distinct from controller chronology.
- The terminal all-hardware-cleanup-fails path remains a separate
  `BLOCKED_BY_PLATFORM` item. The safe substitutes do not prove physical-source
  quiescence.
- Final target state is the restored pre-qualification in-band `543.p18` backup:
  all five active artifacts match backup, OOB/`intmode` are absent, and required
  services/functions are healthy. The c464 candidate is retained staged-only,
  inactive, and unqualified. Packaged `/lib/modules` copies remain inactive,
  unchanged vendor `437.p3` artifacts.
- Both stage-owned rollback timers are stopped/inactive; final active and
  stage-associated timer counts are zero. `/run/mwifiex-oob-watch.env` is removed,
  while backup/stage evidence is retained.

Explicit summary: **traffic qualification BLOCKED_BY_PREREQUISITE; cleanup
COMPLETE/ACCEPTED.** Draft PR #27 must remain Draft; this execution makes no
merge-ready claim.

## Completion criteria and disposition

This qualification closes under the design stop/rollback path because:

1. the source invariant follows a demonstrated RED-to-GREEN cycle;
2. local final checks and exact `make_for_imx93.sh` build pass;
3. the OOB reload, shared-IRQ traffic, suspend/resume, and long-traffic slices
   stopped through the defined platform-policy and prerequisite classifications;
4. the target is left healthy with the original in-band runtime setting;
5. both stage-owned timers are stopped and inactive, the transient runtime
   environment is removed, and backup/stage evidence is intentionally retained;
6. the local documentation commit is verified cleanly. Push, independent reviews,
   Draft PR #27 update, and final OMX-state handling remain controller-owned; the
   PR must remain Draft and report every blocked residual without a merge-ready
   claim.
