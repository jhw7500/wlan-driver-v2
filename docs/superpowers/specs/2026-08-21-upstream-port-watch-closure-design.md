# Upstream Port Runtime WATCH Closure Design

**Status:** Executed — invalid binding alias corrected; 88W9098 target transport
OOB is NOT_APPLICABLE and BLOCKED_BY_HARDWARE_CAPABILITY.

## Objective

Close every safely executable runtime WATCH item left by the NXP mwifiex
`0396cfb..2e481212` port, while preserving the validated in-band SD9098
baseline and making unsupported or unsafe scenarios explicit rather than
claiming unearned coverage.

The source baseline for this qualification is `734f75b`; the documentation
HEAD at design time is `5f8d10a` on
`port/upstream-61820-0396-clean`.

The first execution advanced the source/test qualification HEAD to
`c4644eee070c3a735e83037fdefdfbaf3d74ea8e`; later investigation and correction
advanced it to `e1c9f49bb6ec8ffd0dc9703909ff4ef823a76436`. Independent source and
architecture reviews have returned. Push, Draft PR update, and merge decisions
remain controller-owned follow-up work.

## Final review evidence scopes

- final reviewed candidate source `f11420820bc73196eee837a9896f120b86364b57`:
  rebuilt on the controller with the i.MX93 SDK after the APF/Android/SAE final
  fixes, then staged and transiently installed in the second bounded attempt;
  activation failed and the candidate is inactive.
- c464 target-staged OOB attempt source `c4644eee070c3a735e83037fdefdfbaf3d74ea8e`:
  retained as the source that introduced the invalid wake-binding fallback and
  as inactive failed-attempt evidence.
- corrected source `e1c9f49bb6ec8ffd0dc9703909ff4ef823a76436`:
  keeps transport and suspend-wake bindings distinct; host/source validated and
  never staged on the target.
- historical 734f75b evidence source `734f75bf02a3e5ac4c84a696d8a873ed11247ce3`:
  limited to the previously executed bounded in-band reload/STA slice.

No target access occurred during the original final-review fix wave. A subsequent
bounded second attempt did access the target, reproduced the same transport
configuration timeout, restored the in-band `543.p18` backup, and rebooted through
the existing `wifi_init` failure policy. OOB runtime remains `0/10` cycles and
suspend/traffic-dependent OOB slices are not applicable to this target because the
88W9098 does not provide a transport-event OOB output.

## Fixed pre-execution target facts

- Target: i.MX93, with SSH carried by the wired `eth0` management path.
- Wi-Fi transport: 88W9098 silicon exposed by the driver as SD9098 DBDC, SDIO
  functions `02df:914d` and `02df:914e`.
- Validated module source: `/opt/wlan/driver/*_imx93.ko`, loaded directly by
  `/usr/local/scripts/wifi_init.sh` with `insmod`.
- Validated active version before this work: `mlan=543.p18`, `moal=543.p18`.
- Current runtime mode: in-band SDIO interrupts (`intmode=0`). No
  `nxp_oob_sdio_irq` action is registered.
- Shared OOB line: IRQ 102, level-low, currently owned by two
  `wifi_oob_wakeup` actions.
- Driver lookup: `woal_request_gpio()` searches only for
  `nxp,wifi-oob-int`.
- Board DT: the matching hardware node is compatible with
  `nxp,wifi-wake-host`; no `nxp,wifi-oob-int` compatible exists.
- Exact BSP source commit:
  `ccf0a99701a701fb48a04e31ffe3f9d585a8374a`. The locally built and deployed
  board DTB both have SHA-256
  `9a491ab1155f69a56bdfb931aa8dbae5f2a3ad2dfbef7087005fd02baa093d39`;
  its only WLAN-related external interrupt is the wake-only `GPIO3_IO26` node.
- Power management: `freeze` and `mem` are available; `s2idle` and `deep`
  are selectable; RTC wakealarm is enabled and writable.
- Runtime exclusions: no enumerated PCIe or USB WLAN device and
  `CONFIG_FAULT_INJECTION` is disabled.
- `/lib/modules/.../updates/{mlan,moal}.ko` remain vendor `437.p3` copies and
  are not the files loaded by `wifi_init.service`.

## Corrected approach

Do not alias `nxp,wifi-wake-host` to the SDIO transport IRQ. Exact upstream
`0396cfb` uses `nxp,wifi-oob-int` in `woal_request_gpio()` and separately uses
`nxp,wifi-wake-host` in `woal_regist_oob_wakeup_irq()`. The former is a
continuously active transport action/workqueue; the latter is registered disabled
and enabled only as a system-wakeup source during suspend.

The original driver-side fallback was invalidated by two reproducible target
attempts. Both mapped the wake line as transport and then timed out the first
`SDIO_GPIO_INT_CONFIG` command, preventing firmware initialization. The corrected
driver accepts only `nxp,wifi-oob-int`, releases the DT node reference, rejects a
zero mapping, and fails with `-ENODEV` before IRQ registration when that binding is
absent.

### 88W9098 hardware capability boundary

NXP TechSupport states that the 88W9098 M.2 `SDIO_WAKE#` output is wake-only and
that this chipset has no separate OOB interrupt/event GPIO:
https://community.nxp.com/t5/Wi-Fi-Bluetooth-802-15-4/M2-JODY-W377-88W9098-OOB-interrupt/m-p/2351813/highlight/true.
The generic mwifiex documentation still describes `intmode=1` and firmware
duplication of an SDIO interrupt to GPIO-21 for hardware that supports that path:
https://github.com/nxp-imx/mwifiex. That generic option is not evidence that the
88W9098 target exposes such a line.

#### Authoritative target policy (`OOB_TARGET_POLICY_V1`)

| policy key | value |
|---|---|
| `chip` | `88W9098` |
| `transport_oob` | `NOT_APPLICABLE` |
| `block_reason` | `BLOCKED_BY_HARDWARE_CAPABILITY` |
| `runtime_intmode` | `0` |
| `wake_binding_reuse` | `FORBIDDEN` |
| `bsp_dtb_mutation` | `FORBIDDEN` |
| `target_mutation` | `FORBIDDEN` |
| `target_oob_retry` | `FORBIDDEN` |
| `new_maintenance_window` | `FORBIDDEN` |
| `generic_upstream_oob` | `RETAIN` |
| `production_c_change` | `NONE` |

This `OOB_TARGET_POLICY_V1` table is the sole normative target policy;
conflicting prose is invalid and cannot authorize a target action.

**Disposition:** 88W9098 target transport OOB is NOT_APPLICABLE and
BLOCKED_BY_HARDWARE_CAPABILITY. The target deployment must retain `intmode=0`.
Never alias or relabel `nxp,wifi-wake-host` as `nxp,wifi-oob-int`. Do not
patch/deploy the BSP or DTB and do not schedule another target OOB maintenance
window. Keep the generic upstream OOB transport implementation for other hardware
with a supported transport-event line. This closure adds no production C change
and no target mutation.

## Source and test changes

### OOB binding separation

`e1c9f49` removes the `nxp,wifi-wake-host` fallback from
`mlinux/moal_sdio_mmc.c`. The invariant now requires exactly one
`of_find_compatible_node()` lookup in `woal_request_gpio()`, requires
`nxp,wifi-oob-int`, rejects the wake binding and arbitrary aliases, and preserves
zero-map rejection plus node-reference release. Both the semantic-alias mutation
and an arbitrary-alias review mutation recorded RED before GREEN.

### Durable runtime evidence

Record the exact test sequence and results in
`docs/upstream-port-0396-code-review.md`. Target logs may remain under a
private target staging directory but must not be committed when they contain
SSID, BSSID, MAC address, or local network details.

## Target disposition and generic OOB backlog

The earlier bounded rollout and rollback rehearsal remains historical evidence;
it is not authorization for another OOB activation. The restored target must stay
on the healthy in-band configuration with `intmode=0`. No module, parameter file,
BSP, DTB, timer, service, or target artifact is changed by this capability
closure.

Shared-IRQ teardown, suspend/resume, long-traffic, and physical-source-quiescence
stress remain generic implementation qualification work for a different supported
board that exposes a real transport-event line. The terminal case where CCCR
source disable, whole-function disable, and reset all fail remains
**BLOCKED_BY_PLATFORM** for dynamic proof; static mutations do not prove physical
source quiescence. It is not a deployment gate for this 88W9098 target.

## Executed coverage classification

Candidate activation failed before the runtime health gate. The first and second
attempts both timed out `SDIO_GPIO_INT_CONFIG` after the invalid wake binding was
mapped as transport. Platform reboot policy was a downstream recovery action, not
the initiating cause. Cleanup and baseline restoration are proved. The corrected
target transport OOB is not a retryable runtime prerequisite; it is not applicable
because the 88W9098 lacks the required hardware output.

| WATCH item | Executed result |
|---|---|
| Candidate activation | FAIL — repeated transport configuration timeout and firmware init failure |
| OOB initial health and action count | `NOT_APPLICABLE / BLOCKED_BY_HARDWARE_CAPABILITY` |
| OOB traffic IRQ delta and idle storm | `NOT_APPLICABLE / BLOCKED_BY_HARDWARE_CAPABILITY` |
| OOB traffic-active reload/DBDC teardown | `NOT_APPLICABLE / BLOCKED_BY_HARDWARE_CAPABILITY`; historical attempt stopped at `0/10` cycles |
| OOB suspend/resume (`s2idle`, `deep`) | `NOT_APPLICABLE / BLOCKED_BY_HARDWARE_CAPABILITY` |
| Thirty-minute OOB ping and iperf | `NOT_APPLICABLE / BLOCKED_BY_HARDWARE_CAPABILITY`; peer/server environment was not probed |
| All-hardware-cleanup-fails physical IRQ liveness | generic implementation `BLOCKED_BY_PLATFORM`; not a target deployment gate |
| USB runtime | `BLOCKED_BY_HARDWARE` |
| PCIe runtime/FLR | `BLOCKED_BY_HARDWARE` |
| `/lib/modules` vendor copy mismatch | inactive `437.p3` copies unchanged; active runtime restored from the in-band `543.p18` backup |

## Execution outcome and cleanup

- `c4644eee` added a preferred/fallback lookup that incorrectly treated the
  suspend-only wake binding as a transport alias. Its original mutation suite
  tested lookup hygiene but not semantic separation.
- Task 2 produced exact staged artifacts and an exit-`0` i.MX93 build with exactly
  three known `mlanutl` warnings: unchecked `fgets`, fortified `memcpy` bounds,
  and fortified `strncpy` bounds.
- Task 3 backup, stage, manifest verification, baseline-only rollback rehearsal,
  and 90-minute rollback-timer proof succeeded.
- Persistent snapshot journals later proved that the first attempt mapped the OOB
  IRQ and timed out `SDIO_GPIO_INT_CONFIG` before `wifi_checker` requested reboot.
  A second attempt stopped both approved monitors first and reproduced the same
  command timeout. Baseline rollback began, but the card remained wedged across a
  warm module/config restore; `wifi_init` then failed and its existing OnFailure
  policy approved reboot.
- `e1c9f49` removed the invalid fallback and strengthened the invariant with
  semantic-alias and arbitrary-alias RED/GREEN mutations. Aggregate final checks,
  checkpatch 0/0 and exact i.MX93 build passed. Independent review returned code
  `APPROVE`, architecture `CLEAR`, with no Critical/Important findings.
- The terminal all-hardware-cleanup-fails path remains a separate
  `BLOCKED_BY_PLATFORM` item. The safe substitutes do not prove physical-source
  quiescence.
- Final target state is the restored pre-qualification in-band `543.p18` backup:
  all five active artifacts match backup, OOB/`intmode` are absent, and required
  services/functions are healthy. The c464/f114 candidates are inactive and
  unqualified. Packaged `/lib/modules` copies remain inactive, unchanged vendor
  `437.p3` artifacts.
- Reboot removed the volatile environment, marker and transient timer; final
  matching active timer count is zero. Backup/stage evidence is retained.

Explicit summary: **88W9098 target OOB traffic qualification NOT_APPLICABLE /
BLOCKED_BY_HARDWARE_CAPABILITY; cleanup COMPLETE/ACCEPTED.** Draft PR #27 must
remain Draft; this execution makes no merge-ready claim.

## Completion criteria and disposition

This qualification closes under the design stop/rollback path because:

1. the corrected semantic-boundary and arbitrary-alias invariants each follow a
   demonstrated RED-to-GREEN cycle;
2. local final checks and exact `make_for_imx93.sh` build pass;
3. repeated candidate activation failure is classified separately from the
   hardware-capability closure of corrected target OOB runtime slices;
4. the target is left healthy with the original in-band runtime setting;
5. reboot removed the second transient timer/environment and the final matching
   active-timer count is zero; backup/stage evidence is intentionally retained;
6. the local documentation commit is verified cleanly. Independent reviews have
   returned; push, Draft PR #27 update, and final OMX-state handling remain controller-owned; the
   PR must remain Draft and report every blocked residual without a merge-ready
   claim.
