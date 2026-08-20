# mwifiex upstream 0396 final-fix report

Date: 2026-08-20  
Checkout: `/tmp/wlan-driver-v2-port-0396-clean-20260820`  
Required starting HEAD: `760908e4d570c41ae520ad9c401bc7b4c54e85d6`  
Validated fix commit: `fdba08f1df564c452a3242e65e23e9587487c91e`

## Result

All source-proven final-review findings were fixed and committed without
rewriting the existing merge/build/documentation history. The external module
and bundled `mlanutl` build successfully, and the repeatable invariant,
argument-serialization, bridge-static, mirrored-header, conflict-marker, and
diff checks pass.

This work is source/build/static-test validation only. It does not claim USB,
PCIe, SDIO, suspend/resume, firmware-recovery, AP/STA, or bridge behavior on
target hardware.

## Investigation method and RED evidence

The production changes were preceded by call/state tracing and focused failing
checks. No subagents were used.

### Baseline build and warning attribution

The unmodified required HEAD was clean and exactly matched
`760908e4d570c41ae520ad9c401bc7b4c54e85d6`. A clean baseline external build
succeeded but exposed these source warnings:

- `woal_rx_acct_max` had no previous prototype;
- `mgmt_log_printf` had a 1,120-byte frame, over the 1,024-byte limit;
- `woal_do_flr` was defined but unused;
- `woal_do_sdiommc_flr` was defined but unused.

The compiler-invocation banner was also present at baseline and remains as an
environment warning, quoted under Final validation.

### Initial invariant RED

Before production edits, `scripts/tests/upstream_port_invariants.py` was added
and run as:

```text
rtk scripts/tests/upstream_port_invariants.py
```

It exited 1 for the intended missing invariants. The focused output included:

```text
FAIL: USB card lacks the submit/stop serialization lock
FAIL: USB teardown does not close the submit gate before the kill barrier
FAIL: the final USB kill/drain is not ordered before MLAN unregister
FAIL: mgmt_log_printf still places the 1,024-byte line buffer on the stack
FAIL: management proc entries remain readable by unprivileged users
FAIL: production RXDROP printk markers remain enabled
FAIL: woal_rx_acct_max lacks a shared prototype
FAIL: unused PCIe FLR wrapper remains
FAIL: unused SDIO FLR wrapper remains
FAIL: bridge readiness ignores netif_device_detach during keep-power suspend
FAIL: management-event consumer reads prefix bytes before validating length
FAIL: antcfgnss does not reject unsupported non-2x2 response layouts
FAIL: Kconfig permits a driver selection that omits required proc/debug objects
FAIL: Makefile lacks a repeatable upstream-port QA gate
```

After tracing the kernel antenna parser, an exact-form invariant was added and
failed before that parser was edited:

```text
FAIL: kernel antcfg parser does not reject the invalid three-word form
```

### `antcfg` CLI RED

`scripts/tests/antcfg_cli_qa.sh` builds the real bundled binary and uses an
`LD_PRELOAD` ioctl capture shim to validate the serialized command buffer. Its
pre-fix run rejected the upstream four-word SET form:

```text
rtk scripts/tests/antcfg_cli_qa.sh
FAIL: valid antcfg form rejected: 1 2 3 4
```

The test also requires zero, one, and two words to reach ioctl unchanged and
requires three and five words to fail before ioctl while printing the exact
supported forms.

### USB submit/kill and firmware-reload trace

Source search found exactly two asynchronous USB submission sites:
`woal_usb_submit_rx_urb()` and `woal_write_data_async()`. Both checked removal
or suspension before preparing the URB, but neither serialized its final check
and `usb_submit_urb()` with `woal_usb_unlink_urb()` closing/draining the URBs.
Thus a submitter could pass the flag check, teardown could finish
`usb_kill_urb()`, and the submitter could then publish a new URB. Generic card
removal also reached `mlan_unregister()` before the later free-time unlink.

The legitimate reopen paths were traced as well. Driver-mode rebuild already
paired `woal_drv_mode_quiesce_bus()` with `woal_drv_mode_resume_bus()`, and PM
resume had an RX resubmission sequence. Generic USB firmware reload exposed an
additional bounded inconsistency: `woal_pre_reset()` killed URBs and set
`is_suspended`, while `woal_post_reset()` attempted the normal warm-reset IOCTL
without reopening RX/TX. A focused invariant was added before editing that
flow:

```text
rtk scripts/tests/upstream_port_invariants.py
FAIL: USB firmware reload does not reopen RX/TX before its warm-reset IOCTL
FAIL: terminal firmware-reload failure does not re-close reopened USB gates
```

### `CONFIG_PROC_FS` trace

A forced pre-fix build with `CONFIG_PROC_FS=` did not fail only on the two
management-log calls. Modpost exposed the wider existing proc/debug coupling,
including management-log, debug-entry, histogram, root-proc, wifi-status, and
proc-removal symbols. Guarding only the newly reviewed calls would therefore
have advertised a configuration the rest of this driver does not support.
The compatible bounded choice is an explicit `PROC_FS` Kconfig dependency.

## Implemented fixes and source evidence

### 1. USB teardown serialization and lifecycle preservation

- Added `urb_submit_lock` and `urb_stopping` to `usb_card_rec`, initialized at
  probe.
- RX and TX keep a cheap fast rejection but perform the authoritative stop,
  removal, and suspension recheck plus `usb_submit_urb(..., GFP_ATOMIC)` under
  the shared lock.
- `woal_usb_unlink_urb()` closes the gate under that lock before every
  `usb_kill_urb()` completion barrier.
- `woal_resubmit_urbs()` reopens the gate only for a live device and re-closes
  it if restoring the complete RX set fails.
- USB PM resume and driver-mode rebuild use the shared resubmit helper.
- Generic USB firmware reload reopens URBs after firmware download and before
  the warm-reset IOCTL. A later primary/companion failure closes both gates
  before publishing terminal recovery state.
- `woal_remove_card()` performs the final USB kill/drain after firmware
  shutdown and before `mlan_unregister()`, so USB completions cannot retain a
  path to a freed MLAN adapter.

### 2. `antcfg` forms and `antcfgnss`

- Bundled `mlanutl` accepts only command `argc` 3/4/5/7: GET and one-, two-,
  or four-word SET.
- Usage now names those exact forms.
- The kernel SET parser accepts only one, two, or four parsed words; the
  formerly accepted three-word form now returns `-EINVAL`.
- `antcfg` and `antcfgnss` remain separate commands. `antcfgnss` remains
  GET-only and returns `-EOPNOTSUPP` before issuing an ioctl on non-2x2 layouts,
  rather than reading the incompatible union member. The upstream four-word
  2x2 `antcfg` response remains unchanged.

### 3. Management-log stack and proc exposure

- Each management ring now owns a 1,024-byte formatting scratch allocation.
  Formatting and ring insertion are serialized by the existing ring lock.
- The previous 1,024-byte `mgmt_log_printf()` local was removed; the caller's
  768-byte IE hex scratch is no longer compounded by another 1 KiB frame.
- The historical bounded/truncating per-line behavior remains 1,024 bytes.
- `mgmt_log` and `mgmt_dump` proc entries are mode `0600` on every supported
  proc API branch.

### 4. Production diagnostics and compiler warnings

- Removed active `[DBG-RXDROP]` ratelimited prints from bridge and receive
  paths, while preserving drop counters and existing default-off bridge debug
  behavior.
- Added the shared `woal_rx_acct_max()` declaration and removed the SDIO-local
  `extern`.
- Removed only the unused unlocked PCIe/SDIO FLR wrappers. The used locked
  transaction wrappers remain.
- No warning-suppression flags were added.

### 5. Management-event prefix

- Added mirrored `mlan_mgmt_event_metadata` declarations for the required
  `[band_config, channel, snr, nf]` four-byte prefix and
  `MLAN_MGMT_EVENT_PAYLOAD_OFFSET`.
- Producer and consumer now use the typed prefix and shared offset.
- The consumer validates the four-byte prefix before reading metadata and
  validates the additional address-removal length before `memmove()`.
- Payload offset and wire layout are unchanged.

### 6. Architecture WATCH decisions

- **Keep-power suspend:** PCIe and SDIO call `netif_device_detach()`, but bridge
  readiness previously tested only running/carrier/registration. Adding
  `netif_device_present()` is a source-proven, bus-neutral gate that prevents a
  detached WLAN netdev from being selected or transmitted through.
- **Cold start versus destructive recovery:** cold add-card bridge init logs an
  error and permits WLAN initialization to continue. PCIe/SDIO/generic reload
  paths suspend an existing effective owner and publish terminal recovery
  failure when restoration fails. These are observably different lifecycle
  policies, and no target contract proves they should be unified, so that
  behavior was retained rather than inventing target semantics.
- **Proc optionality:** `WLAN_VENDOR_NXP` now depends on `PROC_FS`; this matches
  the broad existing proc/debug coupling discovered by the forced build.
- **mapp ownership:** `docs/upstream-port-0396-code-review.md` now states that
  product tools outside the reviewed `mlanutl` boundary did not receive the
  same code-level upstream reconciliation.

### 7. Repeatable QA gate

`make upstream-port-check` now runs:

1. lifecycle/ABI invariants;
2. real-CLI `antcfg` serialization tests;
3. the existing adversarial bridge static/mutation suite;
4. byte comparison of `mlan/mlan_ioctl.h` and
   `mlinux/mlan_ioctl.h`.

During GREEN integration, bridge check D8 falsely failed under
`set -o pipefail`: `grep -q` exited after a match, causing the producer
`printf` to receive SIGPIPE. Replacing only that pipeline with a here-string
preserved the assertion and made its exit status deterministic.

## GREEN and final validation

### Focused GREEN

```text
rtk scripts/tests/upstream_port_invariants.py
upstream_port_invariants=PASS

rtk scripts/tests/antcfg_cli_qa.sh
antcfg_cli_qa=PASS

rtk make upstream-port-check
...
PASS: keepalive, bounded queues, worker accounting, F1 RCU drain ordering + atomic peer_released + hairpin smoke enforced
upstream_port_final_checks=PASS
```

All commands exited 0.

### Clean external-module build

```text
rtk make clean KERNELDIR=/lib/modules/6.8.0-111-generic/build ARCH=x86_64
rtk make -j4 KERNELDIR=/lib/modules/6.8.0-111-generic/build ARCH=x86_64
```

Exit: 0. `mlan.ko` and `moal.ko` were produced. The four baseline source
warnings are gone. The only compiler warning is exactly:

```text
warning: the compiler differs from the one used to build the kernel
  The kernel was built by: x86_64-linux-gnu-gcc-12 (Ubuntu 12.3.0-1ubuntu1~22.04.3) 12.3.0
  You are using:           gcc-12 (Ubuntu 12.3.0-1ubuntu1~22.04.3) 12.3.0
```

The build also emitted these non-compiler BTF notices:

```text
Skipping BTF generation for /tmp/wlan-driver-v2-port-0396-clean-20260820/mlan.ko due to unavailability of vmlinux
Skipping BTF generation for /tmp/wlan-driver-v2-port-0396-clean-20260820/moal.ko due to unavailability of vmlinux
```

### Clean bundled userspace build

```text
rtk make -C mapp/mlanutl clean
rtk make -C mapp/mlanutl
```

Exit: 0. No userspace compiler warnings were emitted.

### Header, conflict, and whitespace checks

```text
rtk sha256sum mlan/mlan_ioctl.h mlinux/mlan_ioctl.h
1017200d01782ca52ae497c9a73341a1602e9c54d2c7afcd2811bf88cc946cfb  mlan/mlan_ioctl.h
1017200d01782ca52ae497c9a73341a1602e9c54d2c7afcd2811bf88cc946cfb  mlinux/mlan_ioctl.h
```

The two edited `mlan_decl.h` mirrors also have identical SHA-256
`7966a2839838078ef363b79d75482a9a064b8f814f979913f81a38da916110c8`.
The exact conflict-marker scan produced zero bytes, and
`rtk git diff --check` plus `rtk git diff --cached --check` both exited 0.

## Files changed

- Lifecycle: `mlinux/moal_usb.[ch]`, `mlinux/moal_main.c`,
  `mlinux/moal_bridge.c`.
- ABI/commands: `mapp/mlanutl/mlanutl.c`, `mlinux/moal_eth_ioctl.c`,
  `mlan/mlan_decl.h`, `mlinux/mlan_decl.h`, `mlan/mlan_misc.c`,
  `mlinux/moal_shim.c`.
- Diagnostics/build hygiene: `mlinux/moal_proc.c`, `mlinux/moal_main.h`,
  `mlinux/moal_init.c`, `mlinux/moal_pcie.c`,
  `mlinux/moal_sdio_mmc.c`, `Kconfig`.
- QA/docs: `Makefile`, `scripts/tests/antcfg_cli_qa.sh`,
  `scripts/tests/upstream_port_invariants.py`,
  `scripts/tests/upstream_port_final_checks.sh`,
  `scripts/tests/bridge_static_checks.sh`,
  `docs/upstream-port-0396-code-review.md`.

## Residual concerns / required target gates

1. USB submit/kill interleavings, PM suspend/resume, generic firmware reload,
   and driver-mode rebuild require stress validation on each supported USB
   chipset.
2. PCIe and SDIO keep-power suspend/resume and FLR/in-band recovery require
   target validation, including bridge owner restoration and terminal-failure
   behavior.
3. AP/STA, DBDC primary/companion reload, management-frame delivery, and proc
   log access modes require runtime validation in the product image.
4. Cold-start bridge failure remains fail-open by deliberate source-policy
   preservation; a product requirement is needed before changing it.
5. The build environment lacks `vmlinux` for BTF generation and invokes
   `gcc-12` under a different name than the kernel build, although both report
   Ubuntu GCC 12.3.0.

