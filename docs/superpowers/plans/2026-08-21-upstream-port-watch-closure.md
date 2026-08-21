# Upstream Port Runtime WATCH Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable the i.MX93 SD9098 OOB interrupt path safely, exercise its teardown and power-management lifecycle on target, and leave every unavailable WATCH item explicitly classified.

**Architecture:** Add an i.MX-only DT-compatible fallback in the existing OOB IRQ lookup, protected by mutation-tested source invariants. Qualify the resulting module through a rollback-guarded target sequence: OOB bring-up, ten live shared-IRQ reloads, `s2idle`/`deep` resume, and thirty-minute traffic, then restore the production runtime setting to in-band.

**Tech Stack:** Linux kernel C, Python 3 source invariants, Bash/systemd target orchestration, NXP SD9098 SDIO DBDC, i.MX93 Linux 6.6.3 Yocto SDK.

**Spec:** `docs/superpowers/specs/2026-08-21-upstream-port-watch-closure-design.md`

## Global Constraints

- Continue work only in `/tmp/wlan-driver-v2-port-0396-clean-20260820` on `port/upstream-61820-0396-clean`; do not modify the dirty primary checkout.
- Prefix every controller-side shell command with `rtk`.
- Preserve `nxp,wifi-oob-int` as the preferred binding; use `nxp,wifi-wake-host` only as fallback.
- Do not replace the target DTB, add a production fault hook, force-reset the SDIO card, or overwrite packaged `/lib/modules/.../updates` files.
- Target changes require a timestamped backup, an immediate-failure rollback path, and a 90-minute ultimate rollback timer.
- Do not commit target logs containing SSID, BSSID, MAC addresses, private IP addresses, or local network details.
- Restore the target runtime configuration to `intmode=0` after qualification unless the user explicitly changes that decision.
- Keep PR #27 Draft and do not claim USB, PCIe, or terminal all-hardware-failure runtime coverage.

---

## UltraQA Scenario Matrix

| ID | Scenario | Expected signal |
|---|---|---|
| SRC-001 | Preferred DT binding removed | Mutation is rejected by `upstream_port_invariants.py` |
| SRC-002 | Board fallback removed | Mutation is rejected |
| SRC-003 | Zero IRQ mapping accepted | Mutation is rejected |
| SRC-004 | DT node reference release removed | Mutation is rejected |
| E2E-001 | Initial SD9098 DBDC OOB load | Services and DBDC recover; `nxp_oob_sdio_irq` appears |
| E2E-002 | OOB WLAN traffic | Shared IRQ count advances and ping passes |
| E2E-003 | Idle shared-line storm | IRQ rate stays below 10,000/s |
| E2E-004 | Ten traffic-active service reloads | Every cycle reconnects, re-registers OOB, and has clean logs |
| E2E-005 | OOB `s2idle` suspend/resume | RTC wake, reconnect, OOB action, ping, clean logs |
| E2E-006 | OOB `deep` suspend/resume | Same signals as E2E-005 |
| E2E-007 | Thirty-minute OOB traffic | Loss <=0.5%, no service loss, storm, or kernel signature |
| SAFE-001 | Command prints success but exits nonzero | Exit status wins; rollback runs |
| SAFE-002 | Service or suspend command hangs | 120/180-second bounds stop the phase |
| SAFE-003 | Interrupted/partial target run | Persistent timer restores modules and config |
| STATE-001 | Stale packaged module tree | Active loader/hash is proved; vendor files remain unchanged |
| ENV-001 | USB runtime | `BLOCKED_BY_HARDWARE`, with no fabricated pass |
| ENV-002 | PCIe/FLR runtime | `BLOCKED_BY_HARDWARE`, with no fabricated pass |
| ENV-003 | CCCR disable + function disable + reset all fail | `BLOCKED_BY_PLATFORM`; mutation plus live teardown is only substitute |
| N/A-001 | Prompt injection/malformed user text | Not applicable: no text/prompt execution surface is added |

### Task 1: Add the OOB binding invariant and implementation

**Files:**
- Modify: `scripts/tests/upstream_port_invariants.py:104-225,757-1068`
- Modify: `mlinux/moal_sdio_mmc.c:741-760`

**Interfaces:**
- Consumes: `c_function()`, `c_code()`, and `ordered()` from the existing invariant harness.
- Produces: `sdio_oob_gpio_mapping_is_compatible(body: str) -> bool` and an i.MX OOB IRQ lookup that returns `0`, `-ENODEV`, or `-ENXIO`.

- [ ] **Step 1: Start UltraQA state and capture the clean baseline**

Run:

```bash
rtk omx state write --input '{"mode":"ultraqa","active":true,"current_phase":"planning","iteration":1,"started_at":"2026-08-21","scenario_matrix":"docs/superpowers/plans/2026-08-21-upstream-port-watch-closure.md"}' --json
rtk git status --porcelain=v1 -uall
rtk git rev-parse HEAD
```

Expected: only the committed plan/spec are present and the worktree is clean.

- [ ] **Step 2: Add the failing source invariant**

Extract the function near the other SDIO functions:

```python
sdio_request_gpio = c_function(sdio_c, "static int woal_request_gpio")
```

Add this helper near the SDIO lifecycle helpers:

```python
def sdio_oob_gpio_mapping_is_compatible(body: str) -> bool:
    code = c_code(body)
    return (
        ordered(
            code,
            'of_find_compatible_node(NULL, NULL, "nxp,wifi-oob-int")',
            "if (!node)",
            'of_find_compatible_node(NULL, NULL, "nxp,wifi-wake-host")',
            "if (!node)",
            "return -ENODEV",
            "irq = irq_of_parse_and_map(node, 0)",
            "of_node_put(node)",
            "if (!irq)",
            "return -ENXIO",
            "card->oob_irq = irq",
            "return 0",
        )
        and code.count('"nxp,wifi-oob-int"') == 1
        and code.count('"nxp,wifi-wake-host"') == 1
    )
```

Add the positive assertion and four mutations:

```python
require(
    sdio_oob_gpio_mapping_is_compatible(sdio_request_gpio),
    "SDIO OOB GPIO lookup lacks preferred/fallback mapping hygiene",
)

for old, new, label in (
    ('node = of_find_compatible_node(NULL, NULL, "nxp,wifi-oob-int");',
     "node = NULL;", "preferred binding"),
    ('node = of_find_compatible_node(NULL, NULL, "nxp,wifi-wake-host");',
     "node = NULL;", "board fallback"),
    ("if (!irq)\n\t\treturn -ENXIO;", "", "zero IRQ rejection"),
    ("of_node_put(node);", "", "DT node release"),
):
    mutation = sdio_request_gpio.replace(old, new, 1)
    require(
        not sdio_oob_gpio_mapping_is_compatible(mutation),
        f"SDIO OOB GPIO invariant accepts missing {label}",
    )
```

- [ ] **Step 3: Run the invariant and prove RED**

Run:

```bash
rtk python3 scripts/tests/upstream_port_invariants.py
```

Expected: nonzero exit with `SDIO OOB GPIO lookup lacks preferred/fallback mapping hygiene` because `734f75b` has no board fallback or mapping cleanup.

- [ ] **Step 4: Implement the minimal i.MX fallback**

Replace the i.MX body of `woal_request_gpio()` with:

```c
#if defined(IMX_SUPPORT)
	struct device_node *node;
	int irq;

	node = of_find_compatible_node(NULL, NULL, "nxp,wifi-oob-int");
	if (!node)
		node = of_find_compatible_node(NULL, NULL, "nxp,wifi-wake-host");
	if (!node)
		return -ENODEV;
	irq = irq_of_parse_and_map(node, 0);
	of_node_put(node);
	if (!irq)
		return -ENXIO;
	card->oob_irq = irq;
	PRINTM(MMSG, "SDIO OOB IRQ: %d\n", card->oob_irq);
	return 0;
#else
```

Do not change the non-i.MX return path or `IRQF_TRIGGER_LOW | IRQF_SHARED` registration.

- [ ] **Step 5: Run GREEN and the complete mutation suite**

Run:

```bash
rtk python3 scripts/tests/upstream_port_invariants.py
rtk ./scripts/tests/upstream_port_final_checks.sh
```

Expected: both exit 0 with `upstream_port_invariants=PASS` and `upstream_port_final_checks=PASS`.

- [ ] **Step 6: Check source style and commit**

Run:

```bash
rtk python3 -m py_compile scripts/tests/upstream_port_invariants.py
rtk git diff -- mlinux/moal_sdio_mmc.c > /tmp/mwifiex-oob-binding.patch
rtk /opt/sda/imx93/imx-6.6.3-1.0.0-build/build_fsl-imx-wayland/tmp/work-shared/imx93-11x11-lpddr4x-evk/kernel-source/scripts/checkpatch.pl --no-tree --strict --show-types --ignore FILE_PATH_CHANGES /tmp/mwifiex-oob-binding.patch
rtk rm -f /tmp/mwifiex-oob-binding.patch
rtk git diff --check
rtk git diff -- mlinux/moal_sdio_mmc.c scripts/tests/upstream_port_invariants.py
rtk git add mlinux/moal_sdio_mmc.c scripts/tests/upstream_port_invariants.py
rtk git commit -m "fix: support i.MX93 OOB wake binding"
```

### Task 2: Rebuild and verify the candidate artifacts

**Files:**
- Generated, not committed: `bin_wlan/mlan_imx93.ko`, `bin_wlan/moal_imx93.ko`, `bin_wlan/mlanutl_imx93`, `bin_wlan/mlanevent_imx93`

**Interfaces:**
- Consumes: the committed Task 1 source.
- Produces: four i.MX93 candidate artifacts, exact hashes, sizes, and vermagic for target staging.

- [ ] **Step 1: Run the full host baseline**

```bash
rtk ./scripts/tests/upstream_port_final_checks.sh
rtk ./make_for_imx93.sh
```

Expected: both exit 0. Record the three known `mlanutl` warnings separately; do not call the build warning-free.

- [ ] **Step 2: Record artifact identity**

```bash
rtk sha256sum bin_wlan/mlan_imx93.ko bin_wlan/moal_imx93.ko bin_wlan/mlanutl_imx93 bin_wlan/mlanevent_imx93
rtk stat -c '%n %s' bin_wlan/mlan_imx93.ko bin_wlan/moal_imx93.ko bin_wlan/mlanutl_imx93 bin_wlan/mlanevent_imx93
rtk modinfo -F vermagic bin_wlan/moal_imx93.ko
rtk modinfo -F version bin_wlan/moal_imx93.ko
```

Expected: version `543.p18` and target-compatible `6.6.3-lts-next-... aarch64` vermagic.

- [ ] **Step 3: Verify repository hygiene**

```bash
rtk git status --porcelain=v1 -uall
rtk git diff --check 45f593e..HEAD
rtk git merge-base --is-ancestor 0396cfb38ad73a3d587cd0f8c139b47801e70891 HEAD
rtk git merge-base --is-ancestor 2e481212d262758cbd4d0fc7ea95a2ad5f704bc3 HEAD
```

Expected: generated artifacts do not create tracked changes; all checks exit 0.

### Task 3: Stage rollback-protected target deployment

**Files:**
- Target backup: runtime `$BACKUP` recorded in `/run/mwifiex-oob-watch.env`
- Target evidence: runtime `$STAGE` recorded in `/run/mwifiex-oob-watch.env`
- Temporary target state: `/run/mwifiex-oob-watch.env`

**Interfaces:**
- Consumes: Task 2 artifacts and controller environment `TARGET`.
- Produces: immutable backup/stage directories and an armed rollback timer.

- [ ] **Step 1: Require explicit controller environment without printing secrets**

```bash
rtk env TARGET="${TARGET:?export TARGET to the wired-management SSH endpoint}" true
rtk env WLAN_PEER="${WLAN_PEER:?export WLAN_PEER to the validated WLAN peer}" true
rtk python3 -c 'import ipaddress, os; ipaddress.ip_address(os.environ["WLAN_PEER"])'
```

- [ ] **Step 2: Reconfirm the untouched target baseline**

```bash
rtk ssh "$TARGET" 'set -eu; test "$(cat /sys/module/mlan/version)" = 543.p18; test "$(cat /sys/module/moal/version)" = 543.p18; systemctl is-active --quiet wifi_init wpa_supplicant@mlan0 wifi_bridge@mlan0 wifi_logger_temp; test -e /sys/bus/sdio/devices/mmc2:0001:1; test -e /sys/bus/sdio/devices/mmc2:0001:2; ! grep -q nxp_oob_sdio_irq /proc/interrupts'
```

Expected: exit 0 and no target mutation.

- [ ] **Step 3: Create target backup and stage directories**

Generate the runtime tag from the Task 1 source commit and controller time, then pass it to the target. The backup must include both deployed modules, both utilities, and the dereferenced active parameter file. The stage must include the new four artifacts and `SHA256SUMS`.

```bash
rtk ssh "$TARGET" 'set -eu; umask 077; RUN_TAG=$(date -u +%Y%m%dT%H%M%SZ); BACKUP=/opt/wlan/backup/oob-watch-$RUN_TAG; STAGE=/opt/wlan/staging/oob-watch-$RUN_TAG; mkdir -p "$BACKUP" "$STAGE"; cp -a /opt/wlan/driver/mlan_imx93.ko /opt/wlan/driver/moal_imx93.ko /opt/wlan/bin/mlanutl_imx93 /opt/wlan/bin/mlanevent_imx93 "$BACKUP"/; cp -L --preserve=mode,timestamps /usr/lib/firmware/cts/wifi_mod_para.conf "$BACKUP"/wifi_mod_para.conf; printf "RUN_TAG=%s\nBACKUP=%s\nSTAGE=%s\n" "$RUN_TAG" "$BACKUP" "$STAGE" >/run/mwifiex-oob-watch.env; cat /run/mwifiex-oob-watch.env'
rtk ssh "$TARGET" "printf 'WLAN_PEER=%s\n' '$WLAN_PEER' >>/run/mwifiex-oob-watch.env"
rtk git rev-parse HEAD > /tmp/mwifiex-oob-SOURCE_HEAD
rtk scp bin_wlan/mlan_imx93.ko bin_wlan/moal_imx93.ko bin_wlan/mlanutl_imx93 bin_wlan/mlanevent_imx93 /tmp/mwifiex-oob-SOURCE_HEAD "$TARGET:/tmp/"
rtk ssh "$TARGET" '. /run/mwifiex-oob-watch.env; install -m 0644 /tmp/mlan_imx93.ko /tmp/moal_imx93.ko "$STAGE"/; install -m 0755 /tmp/mlanutl_imx93 /tmp/mlanevent_imx93 "$STAGE"/; install -m 0600 /tmp/mwifiex-oob-SOURCE_HEAD "$STAGE/SOURCE_HEAD"; sha256sum "$STAGE"/* >"$STAGE/SHA256SUMS"; rm -f /tmp/mlan_imx93.ko /tmp/moal_imx93.ko /tmp/mlanutl_imx93 /tmp/mlanevent_imx93 /tmp/mwifiex-oob-SOURCE_HEAD'
rtk rm -f /tmp/mwifiex-oob-SOURCE_HEAD
```

- [ ] **Step 4: Install and syntax-check the rollback script**

Create `$STAGE/rollback.sh` with this body:

```bash
#!/bin/bash
set -Eeuo pipefail
. /run/mwifiex-oob-watch.env
exec >>"$STAGE/rollback.log" 2>&1
printf 'rollback begin %s\n' "$(date -Iseconds)"
install -m 0644 "$BACKUP/mlan_imx93.ko" /opt/wlan/driver/mlan_imx93.ko
install -m 0644 "$BACKUP/moal_imx93.ko" /opt/wlan/driver/moal_imx93.ko
install -m 0755 "$BACKUP/mlanutl_imx93" /opt/wlan/bin/mlanutl_imx93
install -m 0755 "$BACKUP/mlanevent_imx93" /opt/wlan/bin/mlanevent_imx93
install -m 0644 "$BACKUP/wifi_mod_para.conf" /usr/lib/firmware/cts/wifi_mod_para.conf
sync
systemctl restart wifi_init.service
printf 'rollback complete %s\n' "$(date -Iseconds)"
```

Run `rtk ssh "$TARGET" '. /run/mwifiex-oob-watch.env; chmod 0700 "$STAGE/rollback.sh"; bash -n "$STAGE/rollback.sh"'` and require exit 0.

- [ ] **Step 5: Rehearse rollback while the target still has the baseline artifacts**

Run the rollback script once before candidate installation. Wait for the same in-band baseline assertions from Step 2, verify `rollback complete` in `$STAGE/rollback.log`, and require the active module/config hashes to match `$BACKUP`. This proves the recovery command path without first creating a failed candidate state.

- [ ] **Step 6: Arm the 90-minute ultimate rollback timer**

```bash
rtk ssh "$TARGET" '. /run/mwifiex-oob-watch.env; systemd-run --unit="mwifiex-oob-watch-rollback-$RUN_TAG" --on-active=90m --timer-property=AccuracySec=1s /bin/bash "$STAGE/rollback.sh"; systemctl is-active --quiet "mwifiex-oob-watch-rollback-$RUN_TAG.timer"'
```

Expected: timer active. Any later phase failure immediately runs `rollback.sh` before stopping.

### Task 4: Execute OOB bring-up and ten live teardown cycles

**Files:**
- Target evidence: `$STAGE/oob-runtime.log`, `$STAGE/oob-dmesg.log`, `$STAGE/oob-journal.log`

**Interfaces:**
- Consumes: armed rollback, staged modules, `WLAN_PEER`.
- Produces: E2E-001 through E2E-004 results.

- [ ] **Step 1: Install candidate modules and enable both SD9098 OOB blocks**

On target, install the staged artifacts, then transform the active parameter file through a temporary file: insert exactly one `intmode=1` immediately after each `SD9098_0`/`SD9098_1` header and discard any previous `intmode=` inside those blocks. Verify exactly two resulting lines before replacing the active file.

```bash
. /run/mwifiex-oob-watch.env
install -m 0644 "$STAGE/mlan_imx93.ko" /opt/wlan/driver/mlan_imx93.ko
install -m 0644 "$STAGE/moal_imx93.ko" /opt/wlan/driver/moal_imx93.ko
install -m 0755 "$STAGE/mlanutl_imx93" /opt/wlan/bin/mlanutl_imx93
install -m 0755 "$STAGE/mlanevent_imx93" /opt/wlan/bin/mlanevent_imx93
awk '
/^SD9098_[01][[:space:]]*=/ {
    target = 1
    print
    print "\tintmode=1"
    next
}
target && /^[[:space:]]*intmode=/ { next }
{ print }
target && /^}/ { target = 0 }
' /usr/lib/firmware/cts/wifi_mod_para.conf >"$STAGE/wifi_mod_para.oob"
test "$(grep -c "^[[:space:]]*intmode=1$" "$STAGE/wifi_mod_para.oob")" -eq 2
install -m 0644 "$STAGE/wifi_mod_para.oob" /usr/lib/firmware/cts/wifi_mod_para.conf
sync
```

Mark `MWIFIEX_OOB_WATCH_BEGIN` in `/dev/kmsg`, restart `wifi_init.service`, and bound reconnection to 120 seconds.

- [ ] **Step 2: Assert OOB and DBDC state**

Require:

```bash
test "$(cat /sys/module/mlan/version)" = 543.p18
test "$(cat /sys/module/moal/version)" = 543.p18
systemctl is-active --quiet wifi_init wpa_supplicant@mlan0 wifi_bridge@mlan0 wifi_logger_temp
test -e /sys/bus/sdio/devices/mmc2:0001:1
test -e /sys/bus/sdio/devices/mmc2:0001:2
ip link show mlan0
ip link show mlan1
iw dev mlan0 link | grep -q '^Connected'
grep -q nxp_oob_sdio_irq /proc/interrupts
grep -q nxp_oob_sdio_irq /sys/kernel/irq/102/actions
```

Use exit status plus state assertions; success-looking log text alone does not pass SAFE-001.

- [ ] **Step 3: Prove traffic IRQ activity and no idle storm**

Sum numeric CPU columns for IRQ 102 before and after a 20-packet WLAN ping. Require a positive traffic delta. Then sample an idle ten-second delta and require it below 100,000 total interrupts, equivalent to the 10,000/s design limit.

- [ ] **Step 4: Run ten traffic-active restart cycles**

For cycle 1 through 10:

1. start a bounded WLAN ping in the background;
2. restart `wifi_init.service` under a 120-second timeout;
3. wait up to 120 seconds for both versions, four services, DBDC interfaces, STA connection, and OOB action;
4. run a fresh 20-packet ping;
5. scan dmesg after `MWIFIEX_OOB_WATCH_BEGIN` for timeout, BUG, WARNING, Oops, Call Trace, KASAN, lockdep, UAF, or general-protection signatures;
6. record IRQ total and action list.

Any failed assertion runs `$STAGE/rollback.sh` immediately and stops the plan.

- [ ] **Step 5: Capture private target evidence without committing it**

```bash
rtk ssh "$TARGET" '. /run/mwifiex-oob-watch.env; dmesg | awk '\''/MWIFIEX_OOB_WATCH_BEGIN/ {capture=1} capture'\'' >"$STAGE/oob-dmesg.log"; journalctl -u wifi_init.service -n 800 --no-pager >"$STAGE/oob-journal.log"; sha256sum "$STAGE"/* >"$STAGE/evidence-SHA256SUMS"'
```

### Task 5: Execute OOB suspend/resume qualification

**Files:**
- Target evidence: `$STAGE/oob-pm.log`

**Interfaces:**
- Consumes: healthy OOB target and RTC wakealarm.
- Produces: E2E-005 and E2E-006 results.

- [ ] **Step 1: Record and validate power prerequisites**

Record the selected mode from brackets in `/sys/power/mem_sleep`. Require `s2idle`, `deep`, writable RTC wakealarm, and `enabled` RTC wakeup. Require `/sys/kernel/irq/102/wakeup` to report enabled after OOB registration.

- [ ] **Step 2: Run bounded `s2idle`**

Set `/sys/power/mem_sleep` to `s2idle`, mark the kernel log, and run:

```bash
timeout 180 rtcwake -m mem -s 20
```

After return, apply the same 120-second service/STA/OOB wait, 20-packet ping, IRQ-advance assertion, and kernel signature scan.

- [ ] **Step 3: Run bounded `deep`**

Repeat Step 2 with `deep`. If SSH does not return within 180 seconds, stop further target work and report the RTC/platform recovery failure; do not claim rollback executed while the board remained suspended.

- [ ] **Step 4: Restore the original `mem_sleep` selection**

Write the recorded original selection back and verify it is selected in brackets. Capture dmesg and journal evidence under `$STAGE`.

### Task 6: Run long traffic and restore the in-band production setting

**Files:**
- Target evidence: `$STAGE/oob-long-ping.log`, `$STAGE/oob-iperf.log`, `$STAGE/final-health.log`

**Interfaces:**
- Consumes: healthy post-resume OOB target.
- Produces: E2E-007 result and a healthy `intmode=0` final target.

- [ ] **Step 1: Run thirty-minute bounded ping**

```bash
timeout 2100 ping -I mlan0 -i 1 -c 1800 -W 2 "$WLAN_PEER"
```

Require command exit 0, parse `packet loss` numerically, and require loss <=0.5%. During the run, sample the four services and IRQ rate every 60 seconds; any service loss or >=10,000/s idle IRQ rate fails.

- [ ] **Step 2: Probe iperf3 without turning absence into failure**

Run a two-second connection probe. If reachable, run bounded 30-second forward and reverse tests. If not reachable, record `BLOCKED_BY_ENVIRONMENT` and continue; do not classify server absence as driver failure.

- [ ] **Step 3: Restore only the original parameter file and keep the qualified candidate modules**

Restore `$BACKUP/wifi_mod_para.conf`, restart `wifi_init.service`, and require the normal in-band health gate. Verify `nxp_oob_sdio_irq` is absent, module hashes still match Task 2, and active versions remain `543.p18`.

- [ ] **Step 4: Verify packaged vendor files were untouched**

Record version/hash for `/lib/modules/$(uname -r)/updates/{mlan,moal}.ko`. Require they still identify as vendor `437.p3`; document that they are inactive and intentionally unchanged.

- [ ] **Step 5: Cancel rollback and clean transient state**

Only after all preceding assertions pass:

```bash
rtk ssh "$TARGET" '. /run/mwifiex-oob-watch.env; systemctl stop "mwifiex-oob-watch-rollback-$RUN_TAG.timer"; systemctl reset-failed "mwifiex-oob-watch-rollback-$RUN_TAG.service" 2>/dev/null || true; systemctl is-active "mwifiex-oob-watch-rollback-$RUN_TAG.timer" 2>/dev/null | grep -q inactive; rm -f /run/mwifiex-oob-watch.env'
```

Retain the timestamped backup and stage evidence; remove only temporary `/tmp` transfer files and transient state.

### Task 7: Document evidence, review, and update Draft PR #27

**Files:**
- Modify: `docs/upstream-port-0396-code-review.md`
- Modify: `docs/superpowers/specs/2026-08-21-upstream-port-watch-closure-design.md`

**Interfaces:**
- Consumes: sanitized results and exact hashes from Tasks 1-6.
- Produces: final host/target evidence, blocked classifications, review verdict, and updated Draft PR.

- [ ] **Step 1: Write the sanitized result**

Update the review document with:

- new source/test commit and final documentation commit;
- RED-to-GREEN invariant evidence;
- artifact hashes, sizes, and vermagic;
- OOB action count, IRQ rate, ten reload outcomes, suspend/resume outcomes, long-ping statistics, and rollback status;
- `BLOCKED_BY_HARDWARE` for USB and PCIe;
- `BLOCKED_BY_PLATFORM` for terminal all-hardware-failure injection;
- inactive vendor module-tree mismatch;
- explicit statement that target was restored to in-band mode.

Change the design status to `Executed` only if target cleanup and baseline restoration are proved.

- [ ] **Step 2: Run privacy and consistency scans**

```bash
rtk grep -nE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}|192\.168\.|(SSID|BSSID|password|psk)[[:space:]]*[:=]' docs/upstream-port-0396-code-review.md docs/superpowers/specs/2026-08-21-upstream-port-watch-closure-design.md
rtk grep -nE '[T]BD|[T]ODO|fully merge-ready|all runtime.*PASS|USB runtime.*PASS|PCIe.*PASS' docs/upstream-port-0396-code-review.md docs/superpowers/specs/2026-08-21-upstream-port-watch-closure-design.md
rtk git diff --check
```

Expected: no private values, no placeholders, and no overclaim. Descriptive words such as `SSID` in a privacy rule may remain only when they do not contain actual values.

- [ ] **Step 3: Re-run final verification on the exact tree**

```bash
rtk ./scripts/tests/upstream_port_final_checks.sh
rtk ./make_for_imx93.sh
rtk git diff --check 45f593e..HEAD
rtk git status --short
```

Expected: tests/build exit 0 and only intentional documentation changes remain.

- [ ] **Step 4: Request two independent final reviews**

Review lane A must inspect `mlinux/moal_sdio_mmc.c` and the invariant diff for DT reference/IRQ mapping correctness. Review lane B must assess shared-line behavior, DBDC teardown evidence, suspend/resume evidence, and residual physical-source liveness. Combine `APPROVE`/`WATCH` deterministically; do not hide a WATCH behind successful target slices.

- [ ] **Step 5: Commit documentation and push**

```bash
rtk git add docs/upstream-port-0396-code-review.md docs/superpowers/specs/2026-08-21-upstream-port-watch-closure-design.md
rtk git commit -m "docs: record OOB WATCH qualification"
rtk git push origin port/upstream-61820-0396-clean
rtk git ls-remote origin refs/heads/port/upstream-61820-0396-clean
```

- [ ] **Step 6: Update PR body/comment and inspect checks**

Update PR #27 with exact final hashes and the sanitized UltraQA matrix. Keep it Draft. State external review infrastructure failures separately from source findings. Verify `OPEN`, `isDraft=true`, remote HEAD equality, and every check state.

- [ ] **Step 7: Close UltraQA state and report**

```bash
rtk omx state write --input '{"mode":"ultraqa","active":false,"current_phase":"complete","completed_at":"2026-08-21"}' --json
rtk omx state clear --input '{"mode":"ultraqa"}' --json
```

Report using the UltraQA structure: goal, scenario matrix, commands/exits, failures, fixes, cleanup, residual risks, and evidence paths.
