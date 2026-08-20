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
post_reset = c_function(main_c, "static int woal_post_reset")
fw_reload = c_function(main_c, "int woal_request_fw_reload")

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
