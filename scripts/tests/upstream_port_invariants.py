#!/usr/bin/env python3
"""Source-level lifecycle/ABI invariants for the mwifiex 0396 port."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
failures: list[str] = []


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def c_function(source: str, signature: str) -> str:
    search_from = 0
    while True:
        start = source.find(signature, search_from)
        if start < 0:
            return ""
        brace = source.find("{", start)
        semicolon = source.find(";", start)
        if brace >= 0 and (semicolon < 0 or brace < semicolon):
            break
        search_from = semicolon + 1
    depth = 0
    for pos in range(brace, len(source)):
        if source[pos] == "{":
            depth += 1
        elif source[pos] == "}":
            depth -= 1
            if depth == 0:
                return source[start : pos + 1]
    return ""


def ordered(body: str, *needles: str) -> bool:
    pos = -1
    for needle in needles:
        pos = body.find(needle, pos + 1)
        if pos < 0:
            return False
    return True


usb_h = read("mlinux/moal_usb.h")
usb_c = read("mlinux/moal_usb.c")
main_c = read("mlinux/moal_main.c")
main_h = read("mlinux/moal_main.h")
proc_c = read("mlinux/moal_proc.c")
shim_c = read("mlinux/moal_shim.c")
bridge_c = read("mlinux/moal_bridge.c")
eth_ioctl_c = read("mlinux/moal_eth_ioctl.c")
pcie_c = read("mlinux/moal_pcie.c")
sdio_c = read("mlinux/moal_sdio_mmc.c")
mlan_misc_c = read("mlan/mlan_misc.c")
mlan_decl = read("mlan/mlan_decl.h")
moal_decl = read("mlinux/mlan_decl.h")
makefile = read("Makefile")
kconfig = read("Kconfig")

require("spinlock_t urb_submit_lock;" in usb_h,
        "USB card lacks the submit/stop serialization lock")
require(re.search(r"\b(?:bool|BOOLEAN)\s+urb_stopping;", usb_h) is not None,
        "USB card lacks a serialized stopping state")

rx_submit = c_function(usb_c, "static mlan_status woal_usb_submit_rx_urb")
tx_submit = c_function(usb_c, "mlan_status woal_write_data_async")
unlink = c_function(usb_c, "static void woal_usb_unlink_urb")
resubmit = c_function(usb_c, "mlan_status woal_resubmit_urbs")
remove_card = c_function(main_c, "mlan_status woal_remove_card")
free_handle = c_function(main_c, "void woal_free_moal_handle")
post_reset = c_function(main_c, "static int woal_post_reset")
fw_reload = c_function(main_c, "static int woal_request_fw_reload_internal")
switch_drv_mode_locked = c_function(
    main_c, "mlan_status woal_switch_drv_mode_locked"
)
switch_drv_mode_internal = c_function(
    main_c, "static mlan_status woal_switch_drv_mode_internal"
)
fw_reload_from_proc = c_function(
    main_c, "int woal_request_fw_reload_from_proc"
)
deferred_pcie_reset = c_function(
    main_c, "static void woal_deferred_pcie_reset"
)
hang_worker = c_function(main_c, "static void woal_hang_work_queue")
process_hang = c_function(main_c, "void woal_process_hang")
deferred_pcie_pending = c_function(
    main_c, "bool woal_deferred_pcie_reset_pending"
)
fw_reload_from_hang = c_function(
    main_c, "static int woal_request_fw_reload_from_hang"
)
queue_deferred_pcie_reset = c_function(
    main_c, "static int woal_queue_deferred_pcie_reset"
)
invalidate_deferred_pcie_reset = c_function(
    main_c, "bool woal_invalidate_deferred_pcie_reset"
)
replace_fwdump_fname = c_function(
    main_c, "void woal_replace_fwdump_fname"
)
replace_active_fwdump_fname = c_function(
    main_c, "static void woal_replace_active_fwdump_fname"
)
dup_fwdump_fname = c_function(
    main_c, "static char *woal_dup_fwdump_fname"
)
deferred_pcie_target_trylock = c_function(
    main_c, "static bool woal_deferred_pcie_target_trylock"
)
pcie_remove = c_function(pcie_c, "static void woal_pcie_remove")
add_card = c_function(main_c, "moal_handle *woal_add_card")
reset_intf = c_function(main_c, "mlan_status woal_reset_intf")
config_write = c_function(proc_c, "static ssize_t woal_config_write")
config_cmd_match = c_function(proc_c, "static bool woal_config_cmd_match")
file_fwdump_start = main_c.rfind("t_void woal_store_firmware_dump")
file_fwdump_store = (
    c_function(main_c[file_fwdump_start:], "t_void woal_store_firmware_dump")
    if file_fwdump_start >= 0 else ""
)
print_fwdump = c_function(main_c, "t_void woal_print_firmware_dump")

for path, source in (("mlinux/moal_main.c", main_c),
                     ("mlinux/moal_proc.c", proc_c)):
    require(re.search(r"^(?:<<<<<<<|=======|>>>>>>>)", source,
                      re.MULTILINE) is None,
            f"{path} retains an unresolved merge marker")

require("gated = handle->surprise_removed || handle->driver_status;" in
        reset_intf,
        "interface reset does not distinguish gated teardown from healthy IOCTL failure")
monitor_start = reset_intf.find("if (handle->mon_if)")
monitor_end = reset_intf.find("handle->mon_if = NULL;", monitor_start)
monitor_cleanup = reset_intf[monitor_start:monitor_end]
require(monitor_start >= 0 and monitor_end >= 0 and
        ordered(monitor_cleanup, "woal_set_net_monitor(",
                "netif_device_detach(", "unregister_netdev("),
        "monitor reset no longer cleans up the radiotap netdev after stop failure")
require("goto done" not in monitor_cleanup,
        "monitor stop failure can still bypass mandatory radiotap netdev cleanup")
for operation in ("woal_cancel_scan(", "woal_get_bss_info(",
                  "woal_cancel_hs("):
    operation_pos = reset_intf.find(operation)
    failure_tail = reset_intf[operation_pos:operation_pos + 700]
    require(operation_pos >= 0 and
            ordered(failure_tail, operation, "if (!gated)", "goto done;"),
            f"{operation[:-1]} failure does not continue teardown only on the gated path")
disconnect_positions = [match.start() for match in
                        re.finditer(r"\bwoal_disconnect\(", reset_intf)]
require(len(disconnect_positions) == 2,
        "interface reset no longer has both single/all-interface disconnect paths")
for index, operation_pos in enumerate(disconnect_positions, start=1):
    failure_tail = reset_intf[operation_pos:operation_pos + 700]
    require(ordered(failure_tail, "woal_disconnect(", "if (!gated)",
                    "goto done;"),
            f"disconnect path {index} can abort gated teardown")
require(ordered(reset_intf, "memset(&bss_info, 0, sizeof(bss_info));",
                "woal_get_bss_info(", "if (bss_info.is_hs_configured)"),
        "gated interface reset can consume uninitialized BSS information")

require(ordered(post_reset, "handle->driver_status = MFALSE;",
                "handle->hardware_status = HardwareStatusReady;",
                "moal_bridge_pending_invalidate_handle(handle)"),
        "post-reset rebuild starts before the IOCTL/hardware gates are reopened")
require(ordered(free_handle, "if (handle->is_tp_acnt_timer_set)",
                "woal_cancel_timer(&handle->tp_acnt.timer)",
                "handle->is_tp_acnt_timer_set = MFALSE", "kfree(handle)"),
        "terminal handle free does not synchronously stop TP accounting")

require(ordered(config_write,
                "READ_ONCE(handle->surprise_removed) || handle->fw_reseting",
                "ret = -EBUSY;", "goto done;", "done:",
                "MOAL_REL_SEMAPHORE(&AddRemoveCardSem)", "MODULE_PUT;"),
        "firmware-reset rejection leaks the config writer's module reference")
require(ordered(config_write, "if (!count || count > PAGE_SIZE)",
                "databuf = kzalloc(count + 1, flag);",
                "databuf[count] = '\\0';"),
        "config writes are not bounded and NUL terminated before parsing")
copy_failure = re.search(
    r"if\s*\(copy_from_user\(databuf, buf, count\)\)\s*\{"
    r"(?P<body>.*?)\n\t\}",
    config_write,
    re.DOTALL,
)
require(copy_failure is not None and
        "return -EFAULT;" in copy_failure.group("body"),
        "config user-copy fault is not reported as -EFAULT")
require(ordered(config_write, "copy_from_user(databuf, buf, count)",
                "MOAL_ACQ_SEMAPHORE_NOBLOCK(&AddRemoveCardSem)",
                "handle->fw_reseting", "!handle->driver_init",
                "woal_deferred_pcie_reset_pending(handle)",
                "woal_switch_drv_mode_locked(handle, config_data)",
                "woal_request_fw_reload_from_proc(handle, config_data)",
                "MOAL_REL_SEMAPHORE(&AddRemoveCardSem)"),
        "config writes can wait behind or race card teardown")
require("struct mutex fwdump_fname_lock;" in main_h and
        "char *fwdump_active_fname;" in main_h and
        "static char *fwdump_fname;" not in main_c and
        ordered(add_card, "handle = kzalloc(sizeof(moal_handle)",
                "mutex_init(&handle->fwdump_fname_lock)",
                "m_handle[index] = handle") and
        ordered(replace_fwdump_fname,
                "mutex_lock(&handle->fwdump_fname_lock)",
                "old_fname = handle->fwdump_fname",
                "handle->fwdump_fname = new_fname",
                "mutex_unlock(&handle->fwdump_fname_lock)",
                "kfree(old_fname)") and
        ordered(replace_active_fwdump_fname,
                "mutex_lock(&handle->fwdump_fname_lock)",
                "old_fname = handle->fwdump_active_fname",
                "handle->fwdump_active_fname = new_fname",
                "mutex_unlock(&handle->fwdump_fname_lock)",
                "kfree(old_fname)") and
        ordered(dup_fwdump_fname,
                "mutex_lock(&handle->fwdump_fname_lock)",
                "handle->fwdump_active_fname",
                "handle->fwdump_fname", "kstrdup(",
                "mutex_unlock(&handle->fwdump_fname_lock)") and
        "woal_replace_fwdump_fname(handle, new_fwdump_fname)" in
        config_write and
        ordered(file_fwdump_store,
                "seqnum = woal_le16_to_cpu(",
                "type = woal_le16_to_cpu(", "if (seqnum == 1)",
                "woal_replace_active_fwdump_fname(phandle, NULL)",
                "woal_dup_fwdump_fname(phandle, false, flag)",
                "filp_open(dump_fname",
                "woal_replace_active_fwdump_fname(phandle, dump_fname)",
                "woal_dup_fwdump_fname(phandle, true, flag)",
                "if (type == DUMP_TYPE_ENDE)",
                "woal_replace_active_fwdump_fname(phandle, NULL)") and
        ordered(free_handle, "woal_replace_fwdump_fname(handle, NULL)",
                "woal_replace_active_fwdump_fname(handle, NULL)"),
        "firmware-dump pathname lifetime or per-handle dump identity is not serialized")
require(re.search(r"#ifndef DUMP_TO_PROC\s+static char \*"
                  r"woal_dup_fwdump_fname", main_c) is not None,
        "DUMP_TO_PROC builds retain an unused file-path snapshot helper")
require("snapshot = ERR_PTR(-ENOMEM)" in dup_fwdump_fname and
        ordered(file_fwdump_store,
                "woal_dup_fwdump_fname(phandle, false, flag)",
                "if (IS_ERR(dump_fname))", "if (!dump_fname)") and
        ordered(file_fwdump_store,
                "woal_dup_fwdump_fname(phandle, true, flag)",
                "if (IS_ERR(dump_fname))"),
        "firmware-dump pathname snapshot OOM is confused with an unset path")
require("ssize_t read_ret" in print_fwdump and
        ordered(print_fwdump, "pfile_fwdump = filp_open(",
                "if (IS_ERR(pfile_fwdump))", "PTR_ERR(pfile_fwdump)",
                "goto done;", "read_ret =") and
        "read_ret = vfs_read(" in print_fwdump and
        "read_ret = kernel_read(" in print_fwdump and
        ordered(print_fwdump, "if (read_ret <= 0)",
                "filp_close(pfile_fwdump, NULL)", "done:",
                "moal_vfree(phandle, pbuf)"),
        "firmware-dump console read can dereference an ERR_PTR file")
require('count >= strlen("fwdump_file=")' in config_write and
        ordered(config_write, '"fwdump_file="',
                "while (fwdump_name_len &&",
                "fwdump_name[fwdump_name_len - 1] == '\\n'",
                "fwdump_name[fwdump_name_len - 1] == '\\r'",
                "if (!fwdump_name_len ||",
                "memchr(fwdump_name, '\\0', fwdump_name_len)",
                "new_fwdump_fname = kzalloc(fwdump_name_len + 1, flag)",
                "memcpy(new_fwdump_fname, fwdump_name, fwdump_name_len)",
                "woal_replace_fwdump_fname(handle, new_fwdump_fname)"),
        "firmware-dump pathname parsing does not trim line endings, reject malformed input, or keep it bounded and NUL terminated")
require(switch_drv_mode_locked and
        "MOAL_ACQ_SEMAPHORE_BLOCK(&AddRemoveCardSem)" not in
        switch_drv_mode_locked,
        "proc driver-mode switching recursively acquires the card semaphore")
require(ordered(switch_drv_mode_internal, "handle->fw_reseting",
                "handle->driver_status", "goto exit;"),
        "driver-mode switching lacks a post-ownership terminal gate")
require(ordered(fw_reload, "READ_ONCE(phandle->surprise_removed)",
                "phandle->fw_reseting", "phandle->driver_status",
                "goto done;"),
        "generic firmware reload lacks a post-ownership terminal gate")
require(ordered(fw_reload_from_proc,
                "woal_request_fw_reload_internal(phandle, mode, MTRUE, MTRUE)"),
        "proc firmware reload does not preserve caller-owned card serialization")
require(ordered(deferred_pcie_reset, "wait_for_completion(&reset->published)",
                "cancelled = reset->cancelled", "if (cancelled)",
                "device_trylock(&reset->peer_pdev->dev)",
                "woal_deferred_pcie_target_trylock(reset->pdev)",
                "cancelled = reset->cancelled",
                "reset->pdev->driver != reset->driver",
                "pci_reset_function_locked(reset->pdev)",
                "woal_deferred_pcie_target_unlock(reset->pdev)",
                "device_unlock(&reset->peer_pdev->dev)",
                "list_del_init(&reset->pending)",
                "pci_dev_put(reset->peer_pdev)",
                "pci_dev_put(reset->pdev)", "kfree(reset)"),
        "proc-triggered PCIe FLR is not deferred beyond proc callback rundown")
require("WOAL_PCIE_RESET_LOCK_RETRIES" in main_c and
        ordered(deferred_pcie_reset,
                "for (lock_attempt = 0;",
                "cancelled = reset->cancelled", "if (cancelled)",
                "device_trylock(&reset->peer_pdev->dev)",
                "woal_deferred_pcie_target_trylock(reset->pdev)",
                "if (peer_locked)",
                "device_unlock(&reset->peer_pdev->dev)",
                "usleep_range(", "if (!target_locked)",
                "ret = -EAGAIN"),
        "transient PCIe device-lock contention terminates recovery without a bounded retry")
require("struct pci_driver *driver;" in main_c and
        "bool cancelled;" in main_c and
        all(needle in invalidate_deferred_pcie_reset for needle in
            ("pending->pdev == pdev", "pending->key_pdev == pdev",
             "pending->peer_pdev == pdev", "pending->cancelled = true",
             "wifi_status = WIFI_STATUS_FW_RECOVERY_FAIL")) and
        ordered(pcie_remove, "card->reset_stopping = true",
                "woal_invalidate_deferred_pcie_reset(dev)",
                "cancel_work_sync(&card->reset_work)",
                "woal_remove_card(card)",
                "woal_invalidate_deferred_pcie_reset(dev)",
                "woal_pcie_cleanup(card)") and
        "pci_dev_trylock(pdev)" in deferred_pcie_target_trylock and
        "pci_cfg_access_trylock(pdev)" in deferred_pcie_target_trylock and
        "device_trylock(&pdev->dev)" in deferred_pcie_target_trylock,
        "deferred PCIe FLR can survive unbind or reset a replacement binding")
require(ordered(queue_deferred_pcie_reset,
                "reset->driver = pdev->driver", "if (!reset->driver)",
                "list_for_each_entry(pending",
                "return -EBUSY;", "list_add_tail(&reset->pending",
                "queue_work(hang_workqueue, &reset->work)",
                "woal_send_auto_recovery_start_event(event_handle)",
                "spin_lock_irqsave(&deferred_pcie_reset_lock",
                "if (!reset->cancelled)",
                "wifi_status = WIFI_STATUS_FW_RELOAD",
                "spin_unlock_irqrestore(&deferred_pcie_reset_lock",
                "complete(&reset->published)"),
        "queued PCIe FLR lacks a canonical DBDC pending gate")
stale_error = deferred_pcie_reset.find("if (ret)")
stale_cleanup = deferred_pcie_reset.find(
    "spin_lock_irqsave(&deferred_pcie_reset_lock", stale_error
)
require(stale_error >= 0 and stale_cleanup > stale_error and
        ordered(deferred_pcie_reset[stale_error:],
                "spin_lock_irqsave(&deferred_pcie_reset_lock",
                "if (reset->cancelled)", "stale = true",
                "if (!stale)",
                "wifi_status = WIFI_STATUS_FW_RECOVERY_FAIL",
                "spin_unlock_irqrestore(&deferred_pcie_reset_lock") and
        "if (!stale)" not in
        deferred_pcie_reset[stale_error:stale_cleanup],
        "cancelled deferred FLR can overwrite a successful replacement binding")
require("if (!(defer_pcie_reset && mode == FW_RELOAD_PCIE_RESET))" in
        fw_reload,
        "rejected deferred PCIe FLR can publish a false recovery-start event")
legacy_flr_guard = fw_reload.find(
    "#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 13, 0)"
)
legacy_flr_reject = fw_reload.find("return -EOPNOTSUPP;", legacy_flr_guard)
recovery_start = fw_reload.find("woal_send_auto_recovery_start_event(handle)")
require(legacy_flr_guard >= 0 and legacy_flr_reject > legacy_flr_guard and
        recovery_start > legacy_flr_reject,
        "PCIe mode-4 can reset without locked reset callbacks on old kernels")
require('alloc_ordered_workqueue("MOAL_HANG_WORK_QUEUE"' in main_c,
        "deferred PCIe FLR workqueue is not explicitly ordered")
auto_reload = hang_worker[hang_worker.find("if (auto_fw_reload)"):]
auto_handoff = auto_reload.find("woal_request_fw_reload_from_hang(")
auto_release = auto_reload.find("MOAL_REL_SEMAPHORE(&AddRemoveCardSem)")
require(ordered(hang_worker, "woal_deferred_pcie_reset_pending(handle)",
                "woal_clean_up(handle)",
                "woal_request_fw_reload_from_hang(") and
        auto_handoff >= 0 and auto_release > auto_handoff and
        "woal_request_fw_reload_deferred(" not in auto_reload and
        ordered(fw_reload_from_hang,
                "woal_request_fw_reload_internal(phandle, mode, MTRUE, MTRUE)"),
        "automatic recovery can dereference an unpinned handle or bypass "
        "canonical deferred-reset admission")
require(ordered(auto_reload, "if (ret)",
                "woal_deferred_pcie_reset_pending(handle)",
                "if (!recovery_owned)", "moal_bridge_deinit(handle)",
                "wifi_status = WIFI_STATUS_FW_RECOVERY_FAIL",
                "handle->driver_status = MTRUE",
                "handle->hardware_status = HardwareStatusNotReady",
                "handle->fw_reseting = MTRUE",
                "woal_send_auto_recovery_failure_event(handle)",
                "if (ref_handle)",
                "MOAL_REL_SEMAPHORE(&AddRemoveCardSem)"),
        "automatic handoff failure can leave a cleaned adapter non-terminal")
require(ordered(process_hang, "woal_deferred_pcie_reset_pending(handle)",
                "reset_handle = handle") and
        all(needle in deferred_pcie_pending for needle in
            ("pending->pdev == pdev", "pending->key_pdev == pdev",
             "pending->peer_pdev == pdev")),
        "hang publication can queue behind an already accepted DBDC FLR")
deferred_call = fw_reload.find("ret = woal_queue_deferred_pcie_reset(")
deferred_return = fw_reload.find("return ret;", deferred_call)
require(deferred_call >= 0 and deferred_return > deferred_call and
        "wifi_status = previous_wifi_status;" not in
        fw_reload[deferred_call:deferred_return],
        "deferred admission failure can overwrite active recovery status")
for keyword in ("soft_reset", "drv_mode", "rf_test_mode", "antcfg"):
    delimited_parser = re.search(
        rf'if\s*\(\s*count\s*>\s*strlen\("{keyword}"\)\s*&&\s*'
        rf'!strncmp\(databuf,\s*"{keyword}",\s*strlen\("{keyword}"\)\)\s*'
        rf'&&\s*databuf\[strlen\("{keyword}"\)\]\s*==\s*\'=\'\s*\)',
        config_write,
    )
    require(delimited_parser is not None,
            f"exact or malformed {keyword} write can advance beyond its value buffer")
for keyword in ("tx_antenna", "rx_antenna", "radio_mode", "channel",
                "band", "bw"):
    guarded_parser = re.search(
        rf'if\s*\(\s*count\s*>\s*strlen\("{keyword}"\)\s*&&\s*'
        rf'!strncmp\(databuf,\s*"{keyword}",\s*strlen\("{keyword}"\)\)\s*'
        rf'&&\s*databuf\[strlen\("{keyword}"\)\]\s*==\s*\'=\'\s*\)',
        config_write,
    )
    require(guarded_parser is not None,
            f"config parser accepts a malformed {keyword} delimiter")
require(re.search(
            r'!strncmp\(databuf,\s*"otp_mac_addr_rd_wr=",\s*'
            r'strlen\("otp_mac_addr_rd_wr="\)\)',
            config_write) is not None,
        "OTP MAC config parser does not compare the complete command delimiter")
require(config_cmd_match and
        ordered(config_cmd_match, "count >= cmd_len",
                "!strncmp(databuf, cmd, cmd_len)", "count == cmd_len") and
        "databuf[cmd_len] == '\\n'" in config_cmd_match and
        all(f'woal_config_cmd_match(databuf, count, "{keyword}")' in
            config_write for keyword in
            ("debug_dump", "fw_reload", "get_and_reset_per")),
        "bare config commands accept the wrong command content or trailing garbage")
require("proc_create_data(STATUS_PROC, 0444" in proc_c,
        "wifi_status proc entry is still writable")
require("proc_create_data(config_proc_dir, 0644" in proc_c,
        "config proc owner-write/read ABI changed unexpectedly")

for bus, source, signature in (
        ("PCIe", pcie_c, "static mlan_status __woal_do_flr"),
        ("SDIO", sdio_c, "static mlan_status __woal_do_sdiommc_flr")):
    flr = c_function(source, signature)
    require(ordered(flr, "(void)woal_reset_intf(", "woal_clean_up(handle)"),
            f"{bus} FLR still aborts before cleanup when reset IOCTLs are gated")

for name, body in (("RX", rx_submit), ("TX", tx_submit)):
    require(ordered(body, "spin_lock_irqsave(&cardp->urb_submit_lock",
                    "urb_stopping", "usb_submit_urb(",
                    "spin_unlock_irqrestore(&cardp->urb_submit_lock"),
            f"USB {name} submit is not rechecked/submitted under the stop lock")
require(ordered(unlink, "spin_lock_irqsave(&cardp->urb_submit_lock",
                "urb_stopping", "spin_unlock_irqrestore",
                "usb_kill_urb("),
        "USB teardown does not close the submit gate before the kill barrier")
require(ordered(resubmit, "spin_lock_irqsave(&cardp->urb_submit_lock",
                "urb_stopping", "spin_unlock_irqrestore",
                "woal_usb_submit_rx_data_urbs"),
        "USB resubmit does not reopen the serialized gate before RX submission")
require(ordered(remove_card, "mlan_shutdown_fw(", "woal_kill_urbs(handle)",
                "mlan_unregister("),
        "the final USB kill/drain is not ordered before MLAN unregister")
require(ordered(post_reset, "handle->fw_reload = MFALSE",
                "woal_resubmit_urbs(handle)",
                "MLAN_OID_MISC_WARM_RESET"),
        "USB firmware reload does not reopen RX/TX before its warm-reset IOCTL")
reload_failure = fw_reload[fw_reload.rfind("\ndone:") :]
require("woal_kill_urbs(handle)" in reload_failure and
        "woal_kill_urbs(ref_handle)" in reload_failure,
        "terminal firmware-reload failure does not re-close reopened USB gates")

require("char line[MGMT_DUMP_LINE_MAX]" not in proc_c,
        "mgmt_log_printf still places the 1,024-byte line buffer on the stack")
require(re.search(r"char\s+\*line_buf;", main_h) is not None,
        "management rings lack ring-owned formatting storage")
mgmt_printf = c_function(proc_c, "void mgmt_log_printf")
require("ring->line_buf" in mgmt_printf,
        "mgmt_log_printf does not use ring-owned formatting storage")
require("MGMT_LOG_PROC, 0644" not in proc_c and
        "MGMT_DUMP_PROC, 0644" not in proc_c,
        "management proc entries remain readable by unprivileged users")

require("[DBG-RXDROP]" not in bridge_c and "[DBG-RXDROP]" not in shim_c,
        "production RXDROP printk markers remain enabled")
require("void woal_rx_acct_max(atomic_long_t *max, long us);" in main_h,
        "woal_rx_acct_max lacks a shared prototype")
require("bool woal_deferred_pcie_reset_pending(moal_handle *handle);" in
        main_h,
        "config writers cannot observe an accepted deferred PCIe FLR")
require("extern void woal_rx_acct_max" not in sdio_c,
        "SDIO retains a file-local extern for woal_rx_acct_max")
require(re.search(r"static mlan_status woal_do_flr\s*\(", pcie_c) is None,
        "unused PCIe FLR wrapper remains")
require(re.search(r"static mlan_status woal_do_sdiommc_flr\s*\(", sdio_c) is None,
        "unused SDIO FLR wrapper remains")

ready = c_function(bridge_c, "static inline bool moal_bridge_dev_ready")
require("netif_device_present(dev)" in ready,
        "bridge readiness ignores netif_device_detach during keep-power suspend")

for name, decl in (("MLAN", mlan_decl), ("MOAL mirror", moal_decl)):
    require("mlan_mgmt_event_metadata" in decl and
            "MLAN_MGMT_EVENT_PAYLOAD_OFFSET" in decl,
            f"{name} declaration lacks the typed management-event prefix")
require("mlan_mgmt_event_metadata" in mlan_misc_c and
        "MLAN_MGMT_EVENT_PAYLOAD_OFFSET" in mlan_misc_c,
        "management-event producer still relies on implicit event_id sizing")
mgmt_producer = c_function(
    mlan_misc_c, "mlan_status wlan_process_802dot11_mgmt_pkt")
mgmt_payload_bound = re.search(
    r"payload_len\s*>\s*\(\s*MAX_EVENT_SIZE\s*-\s*"
    r"sizeof\(mlan_event\)\s*-\s*MLAN_MGMT_EVENT_PAYLOAD_OFFSET\s*\)",
    mgmt_producer,
)
require(mgmt_payload_bound is not None and
        mgmt_payload_bound.start() < mgmt_producer.find("moal_malloc("),
        "management-event producer does not reserve prefix bytes at its upper boundary")
mgmt_case = shim_c[shim_c.find("case MLAN_EVENT_ID_DRV_MGMT_FRAME:") :]
mgmt_case = mgmt_case[: mgmt_case.find("\n\tcase ", 1)]
require(ordered(mgmt_case, "event_len < MLAN_MGMT_EVENT_PAYLOAD_OFFSET",
                "metadata = ", "rx_snr = metadata->snr"),
        "management-event consumer reads prefix bytes before validating length")

antcfg_nss = c_function(eth_ioctl_c, "static int woal_priv_get_antcfg_nss")
antcfg = c_function(eth_ioctl_c, "static int woal_priv_set_get_tx_rx_ant")
require(ordered(antcfg, "user_data_len != 1", "user_data_len != 2",
                "user_data_len != 4", "FEATURE_CTRL_STREAM_2X2"),
        "kernel antcfg parser does not reject the invalid three-word form")
non_2x2_four_word_reject = re.search(
    r"if\s*\(\s*user_data_len\s*==\s*4\s*&&\s*"
    r"!\(priv->phandle->feature_control\s*&\s*FEATURE_CTRL_STREAM_2X2\)\s*\)"
    r"\s*\{.*?ret\s*=\s*-EOPNOTSUPP\s*;.*?goto\s+done\s*;",
    antcfg,
    re.DOTALL,
)
require(non_2x2_four_word_reject is not None and
        non_2x2_four_word_reject.start() <
        antcfg.find("radio->param.ant_cfg_1x1.antenna = data[0]"),
        "non-2x2 antcfg does not reject the unsupported four-word layout")
require(ordered(
            antcfg,
            "if (priv->phandle->feature_control & FEATURE_CTRL_STREAM_2X2)",
            "radio->param.ant_cfg.tx_antenna = data[0]",
            "if (user_data_len == 2)",
            "radio->param.ant_cfg.rx_antenna = data[1]",
            "if (user_data_len == 4)",
            "radio->param.ant_cfg.tx_antenna_6g = data[2]",
            "radio->param.ant_cfg.rx_antenna_6g = data[3]",
            "radio->param.ant_cfg_1x1.antenna = data[0]",
            "if (user_data_len == 2)",
            "radio->param.ant_cfg_1x1.evaluate_time"),
        "antcfg layout paths no longer preserve 2x2 one/two/four and 1x1 one/two forms")
require(ordered(antcfg_nss, "FEATURE_CTRL_STREAM_2X2", "-EOPNOTSUPP",
                "woal_request_ioctl("),
        "antcfgnss does not reject unsupported non-2x2 response layouts")

require(re.search(r"depends on .*\bPROC_FS\b", kconfig) is not None,
        "Kconfig permits a driver selection that omits required proc/debug objects")
require("upstream-port-check:" in makefile and
        "upstream_port_final_checks.sh" in makefile,
        "Makefile lacks a repeatable upstream-port QA gate")
require((ROOT / "mlan/mlan_ioctl.h").read_bytes() ==
        (ROOT / "mlinux/mlan_ioctl.h").read_bytes(),
        "mirrored mlan_ioctl.h files are not byte-identical")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)
print("upstream_port_invariants=PASS")
