# NXP mwifiex 0396cfb Upstream Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a buildable merge-based port of NXP mwifiex upstream commit range `0396cfb..2e48121` while retaining intentional local driver behavior.

**Architecture:** Merge the exact upstream tip once into local `main`, resolve conflicts by subsystem, and verify the remaining upstream delta as an intentional local overlay. The contaminated replay branch remains untouched for comparison.

**Tech Stack:** Linux kernel C, Kbuild/Make, Git three-way merge, shell QA, `mlanutl`.

**Spec:** `docs/superpowers/specs/2026-08-20-mwifiex-upstream-0396-port-design.md`

## Global Constraints

- Local parent is `ce179fcc8a82f4ce41e70ffadc65c966a7a1565d`.
- Upstream target is `2e481212d262758cbd4d0fc7ea95a2ad5f704bc3`.
- Preserve the original and contaminated port branches; do not reset or delete them.
- Keep upstream `antcfg` four-word ABI and expose local NSS through `antcfgnss`.
- Hardware-only validation remains explicitly unverified until run on target equipment.

---

### Task 1: Resolve build metadata and establish merge invariants

**Files:**
- Modify: `.gitignore`
- Modify: `Makefile`

**Interfaces:**
- Consumes: local bridge QA/build flags and upstream release/chip configuration.
- Produces: a conflict-free Kbuild configuration that compiles `mlinux/moal_bridge.o`.

- [ ] **Step 1: Union ignore rules without duplicate entries or conflict markers**

Retain local cache/test exclusions and all upstream object/dependency exclusions.

- [ ] **Step 2: Resolve Makefile policy**

Use upstream release `543.p18`, current chipset defaults, Android/kernel
compatibility, and removal of hard-coded local SDK paths. Retain
`CONFIG_JHW_TEST`, `CONFIG_BRIDGE_SWITCH_FAULT_INJECT`, its guarded
`ccflags-y`, `bridge-fault-guard-check`, `MOD_SUFFIX`, and
`mlinux/moal_bridge.o`.

- [ ] **Step 3: Verify metadata resolution**

Run:
```bash
git diff --check
grep -R -n '^<<<<<<<\|^=======\|^>>>>>>>' .gitignore Makefile
grep -n 'moal_bridge.o\|CONFIG_BRIDGE_SWITCH_FAULT_INJECT' Makefile
```

Expected: no conflict markers; bridge object and guarded flag are present.

### Task 2: Reconcile MLAN antenna and management-event interfaces

**Files:**
- Modify: `mlan/mlan_cmdevt.c`
- Modify: `mlan/mlan_ioctl.h`
- Modify: `mlinux/mlan_ioctl.h`
- Modify: `mlan/mlan_misc.c`

**Interfaces:**
- Produces: `mlan_ds_ant_cfg` with `tx_antenna_6g`,
  `rx_antenna_6g`, and `user_htstream`.
- Produces: management-event bytes `[band, channel, snr, nf]`.

- [ ] **Step 1: Extend the mirrored antenna structure**

Keep upstream 6 GHz fields and append local `t_u32 user_htstream` in both
header copies.

- [ ] **Step 2: Populate every antenna response field**

In `wlan_ret_802_11_rf_antenna()`, assign Tx/Rx, 6 GHz Tx/Rx, and
`user_htstream` together.

- [ ] **Step 3: Combine management metadata**

In `wlan_process_802dot11_mgmt_pkt()`, set event bytes 0/1 from upstream
band/channel and bytes 2/3 from the local SNR/noise-floor values before copying
the payload at `sizeof(event_id)`.

- [ ] **Step 4: Verify mirrored interfaces**

Run:
```bash
cmp -s mlan/mlan_ioctl.h mlinux/mlan_ioctl.h
grep -R -n '^<<<<<<<\|^=======\|^>>>>>>>' mlan mlinux/mlan_ioctl.h
```

Expected: `cmp` exits 0 and no markers remain in this task's files.

### Task 3: Preserve upstream antcfg ABI and local NSS reporting

**Files:**
- Modify: `mlinux/moal_eth_ioctl.h`
- Modify: `mlinux/moal_eth_ioctl.c`
- Modify: `mapp/mlanutl/mlanutl.c`

**Interfaces:**
- Produces: private command `antcfgnss` returning one `t_u32`.
- Consumes: `mlan_ds_ant_cfg.user_htstream` from Task 2.

- [ ] **Step 1: Add the private command constant and handler**

Implement a GET-only `antcfgnss` path that issues `MLAN_OID_ANT_CFG`,
copies `user_htstream` into the response, bounds the copy by
`respbuflen`, and returns four bytes.

- [ ] **Step 2: Restore upstream antcfg output**

Keep `antcfg` response words as Tx, Rx, 6 GHz Tx, and 6 GHz Rx, including
upstream variable response length behavior.

- [ ] **Step 3: Update the bundled utility**

Make `get_user_htstream()` query `antcfgnss`. Plain `antcfg` displays
the upstream antenna fields and performs the separate NSS query to retain the
local diagnostic line.

- [ ] **Step 4: Build the utility**

Run:
```bash
make -C mapp/mlanutl clean
make -C mapp/mlanutl
```

Expected: both commands exit 0.

### Task 4: Reconcile MOAL bridge, recovery, and cfg80211 conflicts

**Files:**
- Modify: `mlinux/moal_init.c`
- Modify: `mlinux/moal_main.c`
- Modify: `mlinux/moal_main.h`
- Modify: `mlinux/moal_pcie.c`
- Modify: `mlinux/moal_sdio_mmc.c`
- Modify: `mlinux/moal_shim.c`
- Modify: `mlinux/moal_sta_cfg80211.c`

**Interfaces:**
- Consumes: upstream 6.18.20 bus/recovery APIs.
- Produces: reachable local bridge lifecycle, data-path, and reset hooks.

- [ ] **Step 1: Resolve declarations and module parameters**

Keep upstream fields/API additions and local bridge parameters, statistics
types, management-log rings, and fault-injection declarations without duplicate
members.

- [ ] **Step 2: Resolve lifecycle and data-path hooks**

Retain bridge init/deinit, TX hairpin, RX fast path, pending-work lifecycle,
and module init/exit calls at their upstream-equivalent lifecycle points.

- [ ] **Step 3: Resolve PCIe and SDIO recovery**

Preserve upstream reset ordering and error handling. Wrap each successful
reset with local bridge suspend/resume, and use local discard/deinit paths only
on terminal failure.

- [ ] **Step 4: Resolve management/cfg80211 handling**

Process a single `MLAN_EVENT_ID_DRV_MGMT_FRAME` case using the combined
four-byte metadata, then retain upstream frequency/channel delivery and local
management dump logging.

- [ ] **Step 5: Run bridge QA**

Run:
```bash
bash scripts/tests/bridge_static_checks.sh
bash scripts/tests/bridge_runtime_switch_qa.sh
bash scripts/tests/bridge_qa_keepalive_inline.sh
```

Expected: each script exits 0.

### Task 5: Remove replay artifacts and compile the integrated driver

**Files:**
- Modify as failures require: only files already in Tasks 1–4.

**Interfaces:**
- Produces: conflict-free kernel modules `mlan.ko` and `moal.ko`.

- [ ] **Step 1: Scan structural replay artifacts**

Run:
```bash
grep -R -n '^<<<<<<<\|^=======\|^>>>>>>>' -- Makefile mlan mlinux
git diff --check
```

Expected: no markers and no whitespace errors.

- [ ] **Step 2: Build against installed headers**

Run:
```bash
make clean KERNELDIR=/lib/modules/6.8.0-111-generic/build ARCH=x86_64
make -j4 KERNELDIR=/lib/modules/6.8.0-111-generic/build ARCH=x86_64
```

Expected: exit 0 and both kernel modules are produced. Compiler-version text
that identifies the same GCC 12 version is informational.

- [ ] **Step 3: Verify upstream ancestry**

Run:
```bash
git merge-base --is-ancestor 2e481212d262758cbd4d0fc7ea95a2ad5f704bc3 HEAD
git rev-list --parents -n 1 HEAD
```

Expected: first command exits 0; merge commit has local and upstream parents.

### Task 6: Review residual deltas and publish the risk matrix

**Files:**
- Create: `docs/upstream-port-0396-code-review.md`

**Interfaces:**
- Produces: commit mapping, intentional divergence table, risk severity,
  symptoms, merge policy, and target validation commands.

- [ ] **Step 1: Classify final upstream divergence**

Run:
```bash
git diff --name-status 2e481212d262758cbd4d0fc7ea95a2ad5f704bc3..HEAD -- Makefile mlan mlinux mapp
git diff --check 2e481212d262758cbd4d0fc7ea95a2ad5f704bc3..HEAD
```

Record every remaining driver-core file as intentional local behavior,
generated/build metadata, or defect.

- [ ] **Step 2: Record validation evidence**

Include exact commands and exit status for build, utility build, bridge QA,
header mirror check, ancestry check, and structural scans.

- [ ] **Step 3: Record target-only gates**

List USB disconnect/resubmit, PCIe FLR/recovery, SDIO reset, suspend/resume,
STA/uAP association, `antcfg` 2.4/5/6 GHz, VHT/HE NSS, management dump, and
runtime bridge switching as hardware-required tests.

- [ ] **Step 4: Final branch review**

Review `main..HEAD` and the final upstream delta. Do not report completion
until Critical/Important findings are resolved or explicitly ruled with cost.
