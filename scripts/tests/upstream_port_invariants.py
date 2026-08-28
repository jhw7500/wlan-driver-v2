#!/usr/bin/env python3
"""Source-level lifecycle/ABI invariants for the mwifiex 0396 port."""

import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
failures: list[str] = []
REVIEW_FOCUS = os.environ.get("UPSTREAM_PORT_FOCUS", "")


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def review_require(finding: str, condition: bool, message: str) -> None:
    if not REVIEW_FOCUS or REVIEW_FOCUS == finding:
        require(condition, message)


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


_C_NONCODE = re.compile(
    r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*.*?\*/',
    re.DOTALL,
)


def c_code(source: str) -> str:
    """Remove comments and literals before checking live C expressions."""
    return _C_NONCODE.sub("", source)


def if_condition_before(body: str, marker: str) -> str:
    """Return the final balanced if-condition which directly guards marker."""
    code = c_code(body)
    marker_pos = code.find(marker)
    if marker_pos < 0:
        return ""
    matches = list(re.finditer(r"\bif\s*\(", code[:marker_pos]))
    if not matches:
        return ""
    open_paren = code.find("(", matches[-1].start())
    depth = 0
    for pos in range(open_paren, marker_pos):
        if code[pos] == "(":
            depth += 1
        elif code[pos] == ")":
            depth -= 1
            if depth == 0:
                return code[open_paren + 1:pos]
    return ""


def replace_nth(source: str, old: str, new: str, occurrence: int) -> str:
    start = -1
    for _ in range(occurrence + 1):
        start = source.find(old, start + 1)
        if start < 0:
            return source
    return source[:start] + new + source[start + len(old):]


usb_h = read("mlinux/moal_usb.h")
usb_c = read("mlinux/moal_usb.c")
main_c = read("mlinux/moal_main.c")
main_h = read("mlinux/moal_main.h")
proc_c = read("mlinux/moal_proc.c")
shim_c = read("mlinux/moal_shim.c")
bridge_c = read("mlinux/moal_bridge.c")
eth_ioctl_c = read("mlinux/moal_eth_ioctl.c")
sta_cfg80211_c = read("mlinux/moal_sta_cfg80211.c")
cfg80211_util_c = read("mlinux/moal_cfg80211_util.c")
cfg80211_util_h = read("mlinux/moal_cfg80211_util.h")
pcie_c = read("mlinux/moal_pcie.c")
sdio_h = read("mlinux/moal_sdio.h")
sdio_c = read("mlinux/moal_sdio_mmc.c")
sdio_request_gpio = c_function(sdio_c, "static int woal_request_gpio")
mlan_misc_c = read("mlan/mlan_misc.c")
mlan_cmdevt_c = read("mlan/mlan_cmdevt.c")
mlan_11ac_c = read("mlan/mlan_11ac.c")
mlan_11ax_c = read("mlan/mlan_11ax.c")
mlan_sta_tx_c = read("mlan/mlan_sta_tx.c")
mlan_main_internal_h = read("mlan/mlan_main.h")
mlan_decl = read("mlan/mlan_decl.h")
moal_decl = read("mlinux/mlan_decl.h")
makefile = read("Makefile")
kconfig = read("Kconfig")
port_review_doc = read("docs/upstream-port-0396-code-review.md")
watch_design_doc = read(
    "docs/superpowers/specs/2026-08-21-upstream-port-watch-closure-design.md"
)

apf_set_filter = c_function(
    cfg80211_util_c, "static int woal_cfg80211_subcmd_set_packet_filter"
)
apf_init_ctx = c_function(cfg80211_util_c, "static struct woal_apf_ctx *woal_apf_init_ctx")
apf_free_ctx = c_function(cfg80211_util_c, "static void woal_apf_free_ctx")
apf_v6_exec = c_function(cfg80211_util_c, "static int apf_v6_exec")
apf_run = c_function(cfg80211_util_c, "static int apf_run")
apf_filter_packet = c_function(cfg80211_util_c, "int woal_filter_packet")
apf_icmpv6_csum = c_function(cfg80211_util_c, "apf_icmpv6_csum")
apf_ping_echo = c_function(
    cfg80211_util_c, "static inline bool woal_is_ping_echo"
)
passphrase_ioctl = c_function(
    eth_ioctl_c, "static int woal_setget_priv_passphrase"
)
ssu_store_start = main_c.rfind("t_void woal_store_ssu_dump")
ssu_store = c_function(
    main_c[ssu_store_start:], "t_void woal_store_ssu_dump"
)
ssu_read = c_function(proc_c, "static int woal_ssu_dump_read")
proc_exit = c_function(proc_c, "void woal_proc_exit")
add_card = c_function(main_c, "moal_handle *woal_add_card")


def ssu_dump_access_is_serialized(
    store_body: str,
    read_body: str,
    exit_body: str,
    header: str,
    init_body: str,
) -> bool:
    """Require every shared SSU buffer access under one handle mutex."""
    if "struct mutex ssu_dump_lock;" not in header:
        return False
    if "mutex_init(&handle->ssu_dump_lock);" not in init_body:
        return False

    for body, owner in (
        (store_body, "phandle"),
        (read_body, "handle"),
        (exit_body, "handle"),
    ):
        code = re.sub(r"\s+", "", c_code(body))
        lock = f"mutex_lock(&{owner}->ssu_dump_lock);"
        unlock = f"mutex_unlock(&{owner}->ssu_dump_lock);"
        lock_pos = code.find(lock)
        unlock_pos = code.find(unlock)
        accesses = [
            match.start()
            for match in re.finditer(
                rf"{owner}->ssu_dump_(?:buf|len)", code
            )
        ]
        if (
            code.count(lock) != 1
            or code.count(unlock) != 1
            or not accesses
            or lock_pos < 0
            or unlock_pos <= lock_pos
            or min(accesses) < lock_pos
            or max(accesses) > unlock_pos
            or "return" in code[lock_pos:unlock_pos]
        ):
            return False

    read_code = re.sub(r"\s+", "", c_code(read_body))
    resize_start = read_code.find(
        "if(sfp->size<((handle->ssu_dump_len*9)/4)){"
    )
    format_start = read_code.find(
        "tmpbuf=(t_u32*)handle->ssu_dump_buf;"
    )
    if resize_start < 0 or format_start <= resize_start:
        return False
    resize_path = read_code[resize_start:format_start]
    if (
        "sfp->count=sfp->size;" not in resize_path
        or "gotounlock;" not in resize_path
        or "moal_vfree(" in resize_path
        or "handle->ssu_dump_buf=NULL;" in resize_path
        or "handle->ssu_dump_len=0;" in resize_path
    ):
        return False
    return ordered(
        read_code[format_start:],
        "tmpbuf=(t_u32*)handle->ssu_dump_buf;",
        "for(i=0;i<handle->ssu_dump_len/4;i++){",
        "sfp->count=((handle->ssu_dump_len*9)/4);",
        "moal_vfree(handle,handle->ssu_dump_buf);",
        "handle->ssu_dump_buf=NULL;",
        "handle->ssu_dump_len=0;",
        "unlock:",
        "mutex_unlock(&handle->ssu_dump_lock);",
    )


review_require(
    "P1_SSU",
    ssu_dump_access_is_serialized(
        ssu_store, ssu_read, proc_exit, main_h, add_card
    ),
    "P1 SSU dump producer/read/teardown do not share one ownership mutex",
)
ssu_store_without_lock = ssu_store.replace(
    "mutex_lock(&phandle->ssu_dump_lock);", "", 1
)
review_require(
    "P1_SSU",
    not ssu_dump_access_is_serialized(
        ssu_store_without_lock, ssu_read, proc_exit, main_h, add_card
    ),
    "P1 SSU invariant accepts an unlocked producer",
)
ssu_read_after_unlock = ssu_read.replace(
    "mutex_unlock(&handle->ssu_dump_lock);",
    "mutex_unlock(&handle->ssu_dump_lock);\n"
    "\thandle->ssu_dump_len = 0;",
    1,
)
review_require(
    "P1_SSU",
    not ssu_dump_access_is_serialized(
        ssu_store, ssu_read_after_unlock, proc_exit, main_h, add_card
    ),
    "P1 SSU invariant accepts a reader access after unlock",
)
ssu_exit_without_lock = proc_exit.replace(
    "mutex_lock(&handle->ssu_dump_lock);", "", 1
)
review_require(
    "P1_SSU",
    not ssu_dump_access_is_serialized(
        ssu_store, ssu_read, ssu_exit_without_lock, main_h, add_card
    ),
    "P1 SSU invariant accepts unlocked teardown",
)
ssu_read_without_resize_signal = ssu_read.replace(
    "sfp->count = sfp->size;", "", 1
)
review_require(
    "P1_SSU",
    not ssu_dump_access_is_serialized(
        ssu_store,
        ssu_read_without_resize_signal,
        proc_exit,
        main_h,
        add_card,
    ),
    "P1 SSU invariant accepts a missing seq_file resize signal",
)
ssu_read_consumes_on_resize = ssu_read.replace(
    "sfp->count = sfp->size;",
    "moal_vfree(handle, handle->ssu_dump_buf);\n"
    "\t\tsfp->count = sfp->size;",
    1,
)
review_require(
    "P1_SSU",
    not ssu_dump_access_is_serialized(
        ssu_store,
        ssu_read_consumes_on_resize,
        proc_exit,
        main_h,
        add_card,
    ),
    "P1 SSU invariant accepts dump consumption on seq_file resize",
)
ssu_read_free_before_format = ssu_read.replace(
    "moal_vfree(handle, handle->ssu_dump_buf);", "", 1
).replace(
    "tmpbuf = (t_u32 *)handle->ssu_dump_buf;",
    "moal_vfree(handle, handle->ssu_dump_buf);\n"
    "\ttmpbuf = (t_u32 *)handle->ssu_dump_buf;",
    1,
)
review_require(
    "P1_SSU",
    not ssu_dump_access_is_serialized(
        ssu_store,
        ssu_read_free_before_format,
        proc_exit,
        main_h,
        add_card,
    ),
    "P1 SSU invariant accepts freeing the dump before formatting",
)


def apf_install_is_lock_safe(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    parse = code.find("nla_for_each_attr(")
    allocation = code.find("apf_bin=km")
    packet_lock = code.find(
        "spin_lock_irqsave(&pkt_filter->lock,pkt_filter_flags);"
    )
    ctx_lock = code.find("spin_lock_irqsave(&ctx->lock,ctx_flags);")
    if min(parse, allocation, packet_lock, ctx_lock) < 0:
        return False
    return (
        parse < allocation < packet_lock < ctx_lock
        and "GFP_KERNEL" not in code[packet_lock:]
        and ordered(
            code[packet_lock:],
            "spin_lock_irqsave(&pkt_filter->lock,pkt_filter_flags);",
            "spin_lock_irqsave(&ctx->lock,ctx_flags);",
            "memcpy(pkt_filter->packet_filter_program,apf_bin,apf_len);",
            "memcpy(ctx->ram,apf_bin,apf_len);",
            "ctx->gen++;",
            "spin_unlock_irqrestore(&ctx->lock,ctx_flags);",
            "spin_unlock_irqrestore(&pkt_filter->lock,pkt_filter_flags);",
        )
        and code.count("kfree(apf_bin);") == 1
        and code.rfind("kfree(apf_bin);") > code.rfind("done:")
    )


review_require(
    "C1",
    apf_install_is_lock_safe(apf_set_filter),
    "C1 APF install parses/allocates under a spinlock or corrupts nested IRQ flags",
)
c1_same_flags = apf_set_filter.replace("ctx_flags", "pkt_filter_flags")
review_require(
    "C1",
    not apf_install_is_lock_safe(c1_same_flags),
    "C1 APF install invariant accepts reused nested IRQ flags",
)
c1_sleeping_allocation = apf_set_filter.replace(
    "spin_lock_irqsave(&pkt_filter->lock, pkt_filter_flags);",
    "spin_lock_irqsave(&pkt_filter->lock, pkt_filter_flags);\n"
    "\tapf_bin = kmalloc(apf_len, GFP_KERNEL);",
    1,
)
review_require(
    "C1",
    not apf_install_is_lock_safe(c1_sleeping_allocation),
    "C1 APF install invariant accepts a sleeping allocation under spinlock",
)


def apf_tail_bounds_are_overflow_safe(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    passdrop = code[code.find("casePASSDROP_OPCODE:"):code.find("caseLDB_OPCODE:")]
    jmp = code[code.find("caseJMP_OPCODE:"):code.find("caseJEQ_OPCODE:")]
    data_words = code[code.find("caseLDDW_OPCODE:"):code.find("default:", code.find("caseLDDW_OPCODE:"))]
    return (
        min(len(passdrop), len(jmp), len(data_words)) > 0
        and ordered(
            passdrop,
            "if(imm){",
            "V6_ASSERT_RET(imm<=c->ram_len/sizeof(*counter));",
            "counter[-(t_s32)imm]++;",
        )
        and ordered(
            jmp,
            "V6_ASSERT_RET(c->ram_len/sizeof(*counter)>=2);",
            "counter[-1]=0x12345678;",
            "counter[-2]+=1;",
        )
        and "k<=c->ram_len/sizeof(*ctr)" in data_words
        and "imm<=c->ram_len/sizeof(*counter)" in data_words
        and "4u*imm" not in code
        and "4u*k" not in code
    )


review_require(
    "C2",
    apf_tail_bounds_are_overflow_safe(apf_v6_exec),
    "C2 APF tail-counter bounds can wrap or omit fixed-tail minimum RAM",
)
c2_wrapped_passdrop = re.sub(
    r"imm\s*<=\s*c->ram_len\s*/\s*sizeof\(\*counter\)",
    "sizeof(*counter) * imm <= c->ram_len",
    apf_v6_exec,
    count=1,
)
review_require(
    "C2",
    not apf_tail_bounds_are_overflow_safe(c2_wrapped_passdrop),
    "C2 APF counter invariant accepts a multiplication-wrap mutation",
)
c2_fixed_tail_unguarded = re.sub(
    r"V6_ASSERT_RET\(c->ram_len\s*/\s*sizeof\(\*counter\)\s*>=\s*2\s*\);",
    "",
    apf_v6_exec,
    count=1,
)
review_require(
    "C2",
    not apf_tail_bounds_are_overflow_safe(c2_fixed_tail_unguarded),
    "C2 APF counter invariant accepts unguarded fixed tail writes",
)


def apf_packet_scratch_is_private(
    body: str, ctx_header: str, init_body: str, free_body: str
) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    header_code = c_code(ctx_header)
    lifecycle = c_code(init_body + free_body)
    first_ctx_lock = code.find("spin_lock_irqsave(&ctx->lock,flags_ctx);")
    first_ctx_unlock = code.find(
        "spin_unlock_irqrestore(&ctx->lock,flags_ctx);", first_ctx_lock
    )
    run = code.find("v6r=apf_run(")
    second_ctx_lock = code.find(
        "spin_lock_irqsave(&ctx->lock,flags_ctx);", first_ctx_lock + 1
    )
    second_ctx_unlock = code.find(
        "spin_unlock_irqrestore(&ctx->lock,flags_ctx);", second_ctx_lock
    )
    cleanup = code.rfind("done:")
    return (
        "tmp_ram" not in header_code
        and "shim_buf" not in header_code
        and "tmp_ram" not in lifecycle
        and "shim_buf" not in lifecycle
        and "tmp=kmalloc(ram_len,GFP_ATOMIC);" in code
        and "shim_buf=kmalloc(shim_len,GFP_ATOMIC);" in code
        and "tmp=ctx->" not in code
        and "shim_buf=ctx->" not in code
        and min(first_ctx_lock, first_ctx_unlock, run,
                second_ctx_lock, second_ctx_unlock, cleanup) >= 0
        and first_ctx_lock < first_ctx_unlock < run
        and run < second_ctx_lock < second_ctx_unlock < cleanup
        and "apf_run(" not in code[first_ctx_lock:first_ctx_unlock]
        and "apf_run(" not in code[second_ctx_lock:second_ctx_unlock]
        and "spin_lock" not in re.sub(r"\s+", "", c_code(apf_v6_exec))
        and code.count("kfree(tmp);") == 1
        and code.count("kfree(shim_buf);") == 1
        and code.find("kfree(tmp);", cleanup) > cleanup
        and code.find("kfree(shim_buf);", cleanup) > cleanup
    )


review_require(
    "I1",
    apf_packet_scratch_is_private(
        apf_filter_packet, cfg80211_util_h, apf_init_ctx, apf_free_ctx
    ),
    "I1 APF packet execution shares mutable scratch or spans execution with a spinlock",
)
i1_shared_ram = apf_filter_packet.replace(
    "tmp = kmalloc(ram_len, GFP_ATOMIC);", "tmp = ctx->tmp_ram;", 1
)
review_require(
    "I1",
    not apf_packet_scratch_is_private(
        i1_shared_ram, cfg80211_util_h, apf_init_ctx, apf_free_ctx
    ),
    "I1 APF scratch invariant accepts shared context RAM",
)
i1_tmp_cleanup_removed = apf_filter_packet.replace("kfree(tmp);", "", 1)
review_require(
    "I1",
    not apf_packet_scratch_is_private(
        i1_tmp_cleanup_removed, cfg80211_util_h, apf_init_ctx, apf_free_ctx
    ),
    "I1 APF scratch invariant accepts a missing per-packet cleanup",
)


def apf_tx_cleanup_has_final_owner(run_body: str, exec_body: str) -> bool:
    run_code = re.sub(r"\s+", "", c_code(run_body))
    exec_code = re.sub(r"\s+", "", c_code(exec_body))
    allocate = exec_code.find("c->tx_buf=kmalloc(")
    exception_after_allocate = exec_code.find(
        "returnAPF_V6_EXCEPTION;", allocate
    )
    transmit_free = exec_code.rfind("kfree(c->tx_buf);")
    transmit_null = exec_code.find("c->tx_buf=NULL;", transmit_free)
    return (
        allocate >= 0
        and exception_after_allocate > allocate
        and transmit_free > allocate
        and transmit_null > transmit_free
        and ordered(
            run_code,
            "result=apf_v6_exec(&c);",
            "kfree(c.tx_buf);",
            "returnresult;",
        )
        and run_code.count("kfree(c.tx_buf);") == 1
        and "returnapf_v6_exec(&c);" not in run_code
    )


review_require(
    "I2",
    apf_tx_cleanup_has_final_owner(apf_run, apf_v6_exec),
    "I2 APF TX buffer lacks one final cleanup owner after executor returns",
)
i2_final_cleanup_removed = apf_run.replace("kfree(c.tx_buf);", "", 1)
review_require(
    "I2",
    not apf_tx_cleanup_has_final_owner(i2_final_cleanup_removed, apf_v6_exec),
    "I2 APF TX cleanup invariant accepts allocate-then-exception leakage",
)
i2_transmit_null_removed = replace_nth(
    apf_v6_exec, "c->tx_buf = NULL;", "", 0
)
review_require(
    "I2",
    not apf_tx_cleanup_has_final_owner(apf_run, i2_transmit_null_removed),
    "I2 APF TX cleanup invariant accepts a TRANSMIT double-free mutation",
)


def apf_icmpv6_checksum_is_bounded(helper_body: str, exec_body: str) -> bool:
    helper = re.sub(r"\s+", "", c_code(helper_body))
    executor = re.sub(r"\s+", "", c_code(exec_body))
    checksum_call = executor.find(
        "csum_valid=apf_icmpv6_csum(c->tx_buf,tx_len,&csum);"
    )
    transmit = executor.find("dev_queue_xmit(")
    return (
        ordered(
            helper,
            "if(!pkt||!csum)",
            "if(len<ETH_HLEN+40)",
            "ip6=pkt+ETH_HLEN;",
            "plen=(ip6[4]<<8)|ip6[5];",
            "if(plen<8||plen>len-(ETH_HLEN+40))",
            "icmp=ip6+40;",
            "*csum=(u16)(~sum);",
            "returntrue;",
        )
        and checksum_call >= 0
        and transmit > checksum_call
        and "V6_ASSERT_RET(csum_valid);" in executor[checksum_call:transmit]
    )


review_require(
    "I3",
    apf_icmpv6_checksum_is_bounded(apf_icmpv6_csum, apf_v6_exec),
    "I3 APF ICMPv6 checksum trusts malformed advertised payload length",
)
i3_payload_bound_removed = re.sub(
    r"plen\s*>\s*len\s*-\s*\(ETH_HLEN\s*\+\s*40\)",
    "false",
    apf_icmpv6_csum,
    count=1,
)
review_require(
    "I3",
    not apf_icmpv6_checksum_is_bounded(i3_payload_bound_removed, apf_v6_exec),
    "I3 APF checksum invariant accepts oversized IPv6 payload mutation",
)
i3_icmp_minimum_removed = re.sub(
    r"plen\s*<\s*8\s*\|\|", "", apf_icmpv6_csum, count=1
)
review_require(
    "I3",
    not apf_icmpv6_checksum_is_bounded(i3_icmp_minimum_removed, apf_v6_exec),
    "I3 APF checksum invariant accepts undersized ICMPv6 payload mutation",
)


def apf_ping_echo_type_reads_are_bounded(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    l3_guard = code.find("if(len<41)returnfalse;")
    l3_read = code.find("icmp6_type=data[40];")
    l2_guard = code.find("if(len<off+41)returnfalse;")
    l2_read = code.find("icmp6_type=data[off+40];")
    return (
        min(l3_guard, l3_read, l2_guard, l2_read) >= 0
        and l3_guard < l3_read < l2_guard < l2_read
        and code.count("if(len<41)returnfalse;") == 1
        and code.count("if(len<off+41)returnfalse;") == 1
    )


review_require(
    "I3",
    apf_ping_echo_type_reads_are_bounded(apf_ping_echo),
    "I3 APF ping accounting reads an absent ICMPv6 type byte",
)
i3_ping_l3_bound_weakened = apf_ping_echo.replace("len < 41", "len < 40", 1)
review_require(
    "I3",
    not apf_ping_echo_type_reads_are_bounded(i3_ping_l3_bound_weakened),
    "I3 APF ping invariant accepts a header-only L3 IPv6 packet",
)
i3_ping_l3_return_removed = re.sub(
    r"if\s*\(len\s*<\s*41\)\s*return\s+false\s*;",
    "if (len < 41) {}",
    apf_ping_echo,
    count=1,
)
review_require(
    "I3",
    not apf_ping_echo_type_reads_are_bounded(i3_ping_l3_return_removed),
    "I3 APF ping invariant accepts a non-terminating L3 length guard",
)
i3_ping_l2_bound_weakened = apf_ping_echo.replace(
    "len < off + 41", "len < off + 40", 1
)
review_require(
    "I3",
    not apf_ping_echo_type_reads_are_bounded(i3_ping_l2_bound_weakened),
    "I3 APF ping invariant accepts a header-only Ethernet IPv6 packet",
)
i3_ping_l2_return_removed = re.sub(
    r"if\s*\(len\s*<\s*off\s*\+\s*41\)\s*return\s+false\s*;",
    "if (len < off + 41) {}",
    apf_ping_echo,
    count=1,
)
review_require(
    "I3",
    not apf_ping_echo_type_reads_are_bounded(i3_ping_l2_return_removed),
    "I3 APF ping invariant accepts a non-terminating Ethernet length guard",
)


def android_makefile_uses_normalized_truth(source: str) -> bool:
    code = re.sub(r"(?m)#.*$", "", source)
    code = re.sub(r"\s+", "", code)
    normalized = (
        "ANDROID_BUILD_ENABLED:=$(if$(filter1yes,$(strip$(ANDROID_BUILD))),yes,no)"
    )
    predicate = "ifeq($(ANDROID_BUILD_ENABLED),yes)"
    return (
        normalized in code
        and code.count(predicate) == 2
        and "ifeq($(ANDROID_BUILD)," not in code
        and code.find(normalized) < code.find(predicate)
    )


def android_make_values(value: str) -> dict[str, str]:
    wrapper = f"""include {ROOT / 'Makefile'}
.PHONY: print-android-qa
print-android-qa:
\t@echo enabled=$(ANDROID_BUILD_ENABLED)
\t@echo xdp=$(CONFIG_XDP_SUPPORT)
\t@echo android=$(filter -DANDROID,$(KERNEL_CFLAGS))
\t@echo sdk=$(filter -DANDROID_SDK_VERSION=34,$(ccflags-y))
\t@echo xdpflag=$(filter -DXDP_SUPPORT,$(ccflags-y))
"""
    result = subprocess.run(
        [
            "make", "-s", "-f", "-", "print-android-qa",
            f"ANDROID_BUILD={value}", "ANDROID_SDK_VERSION=34",
            "CONFIG_PCIEAW693=y", "KERNELRELEASE=qa",
        ],
        cwd=ROOT,
        input=wrapper,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        return {"error": result.stderr.strip() or f"make exit {result.returncode}"}
    return dict(line.split("=", 1) for line in result.stdout.splitlines())


def android_make_matrix_is_compatible() -> bool:
    yes = android_make_values("yes")
    one = android_make_values("1")
    no = android_make_values("no")
    return (
        yes == one
        and yes == {
            "enabled": "yes",
            "xdp": "n",
            "android": "-DANDROID",
            "sdk": "-DANDROID_SDK_VERSION=34",
            "xdpflag": "",
        }
        and no == {
            "enabled": "no",
            "xdp": "y",
            "android": "",
            "sdk": "",
            "xdpflag": "-DXDP_SUPPORT",
        }
    )


review_require(
    "I4",
    android_makefile_uses_normalized_truth(makefile),
    "I4 Makefile does not use one normalized Android truth predicate",
)
review_require(
    "I4",
    android_make_matrix_is_compatible(),
    "I4 Android yes/1 flags or PCIEAW693 XDP override differ",
)
i4_direct_predicate = makefile.replace(
    "ifeq ($(ANDROID_BUILD_ENABLED),yes)", "ifeq ($(ANDROID_BUILD),yes)", 1
)
review_require(
    "I4",
    not android_makefile_uses_normalized_truth(i4_direct_predicate),
    "I4 Android invariant accepts a direct truth-value predicate",
)


def sae_password_snapshot_is_bounded(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    set_snapshot = code.find("sae_password_len=strlen(end);")
    ioctl = code.find("status=woal_request_ioctl(")
    get_guard = code.find(
        "if(req->action==MLAN_ACT_GET&&"
        "sec->param.passphrase.psk_type==MLAN_PSK_SAE_PASSWORD)"
    )
    response_reset = code.find("memset(respbuf,0,respbuflen);")
    get_snapshot = code[get_guard:response_reset]
    response = code[response_reset:]
    return (
        min(set_snapshot, ioctl, get_guard, response_reset) >= 0
        and set_snapshot < ioctl < get_guard < response_reset
        and ordered(
            code[set_snapshot:ioctl],
            "sae_password_len=strlen(end);",
            "moal_memcpy_ext(priv->phandle,sae_password,end,sae_password_len,sizeof(sae_password)-1);",
            "sae_password[sae_password_len]=;",
        )
        and "sae_password_len=MIN(sec->param.passphrase.psk.sae_password.sae_password_len,MLAN_MAX_SAE_PASSWORD_LENGTH);" in get_snapshot
        and ordered(
            get_snapshot,
            "moal_memcpy_ext(",
            "sae_password,",
            "sec->param.passphrase.psk.sae_password.sae_password,",
            "sae_password_len,",
            "sizeof(sae_password)-1);",
            "sae_password[sae_password_len]=;",
        )
        and "scnprintf(respbuf+len,respbuflen-len," in response
        and "sae_password" in response
    )


review_require(
    "I5",
    sae_password_snapshot_is_bounded(passphrase_ioctl),
    "I5 SAE SET/GET response does not snapshot bounded post-validation data",
)
i5_set_terminator_removed = passphrase_ioctl.replace(
    "sae_password[sae_password_len] = '\\0';", "", 1
)
review_require(
    "I5",
    not sae_password_snapshot_is_bounded(i5_set_terminator_removed),
    "I5 SAE invariant accepts an unterminated SET snapshot",
)
i5_get_clamp_removed = re.sub(
    r"MIN\(\s*sec->param\.passphrase\.psk\.sae_password\.sae_password_len\s*,"
    r"\s*MLAN_MAX_SAE_PASSWORD_LENGTH\s*\)",
    "sec->param.passphrase.psk.sae_password.sae_password_len",
    passphrase_ioctl,
    count=1,
)
review_require(
    "I5",
    not sae_password_snapshot_is_bounded(i5_get_clamp_removed),
    "I5 SAE invariant accepts an unclamped GET response length",
)


def artifact_evidence_is_unambiguously_scoped(review: str, design: str) -> bool:
    candidate_source = "f11420820bc73196eee837a9896f120b86364b57"
    corrected_source = "e1c9f49bb6ec8ffd0dc9703909ff4ef823a76436"
    candidate_heading = re.search(
        r"^### Second target-staged i\.MX93 cross-build "
        r"\(source `([0-9a-f]{40})`; failed activation, now inactive\)$",
        review,
        re.MULTILINE,
    )
    corrected_heading = re.search(
        r"^### Corrected transport-binding i\.MX93 cross-build "
        r"\(source `([0-9a-f]{40})`; host-only\)$",
        review,
        re.MULTILINE,
    )
    c464_heading = (
        "### Target-staged OOB attempt "
        "(source `c4644eee070c3a735e83037fdefdfbaf3d74ea8e`; "
        "inactive and unqualified)"
    )
    historical_heading = (
        "### Historical target evidence "
        "(source `734f75bf02a3e5ac4c84a696d8a873ed11247ce3`)"
    )
    if not candidate_heading or not corrected_heading:
        return False
    candidate_start = candidate_heading.end()
    candidate_end = review.find("\n### ", candidate_start)
    corrected_start = corrected_heading.end()
    corrected_end = review.find("\n### ", corrected_start)
    if candidate_end < 0 or corrected_end < 0:
        return False
    candidate_section = review[candidate_start:candidate_end]
    corrected_section = review[corrected_start:corrected_end]
    candidate_commit = candidate_heading.group(1)
    corrected_commit = corrected_heading.group(1)
    vermagic = (
        "6.6.3-lts-next-gccf0a99701a7-dirty SMP preempt mod_unload "
        "modversions aarch64"
    )
    candidate_rows = [
        "| `bin_wlan/mlan_imx93.ko` | 992,720 | "
        "`0c0347b6ef08ae0d605655b62e70121440d0f0961277d25f5eb27fe4b595b396` "
        f"| `{vermagic}`; `543.p18` |",
        "| `bin_wlan/moal_imx93.ko` | 1,978,536 | "
        "`f7155dc139c6a4f976d08815596937ddb8083b8856037bf7b58a29371ba81af3` "
        f"| `{vermagic}`; `543.p18` |",
        "| `bin_wlan/mlanutl_imx93` | 400,968 | "
        "`127912311df9397df9104cf8fe96f4501ecc1edf9df67007d54af6f95c2ae4a3` "
        "| ARM aarch64 executable; version not embedded as a module field |",
        "| `bin_wlan/mlanevent_imx93` | 68,144 | "
        "`3523a73a544627d3ceae7f3c7ed57cdf19df8a04882b0d0ea14c69bde95dbd05` "
        "| ARM aarch64 executable; version not embedded as a module field |",
    ]
    corrected_rows = [
        "| `bin_wlan/mlan_imx93.ko` | 992,720 | "
        "`0c0347b6ef08ae0d605655b62e70121440d0f0961277d25f5eb27fe4b595b396` "
        f"| `{vermagic}`; `543.p18` |",
        "| `bin_wlan/moal_imx93.ko` | 1,978,448 | "
        "`482de059b6c1ee2c9c8145c326efbecd8341a5bc0ef5eebde905908a0dc5f498` "
        f"| `{vermagic}`; `543.p18` |",
        "| `bin_wlan/mlanutl_imx93` | 400,968 | "
        "`127912311df9397df9104cf8fe96f4501ecc1edf9df67007d54af6f95c2ae4a3` "
        "| ARM aarch64 executable |",
        "| `bin_wlan/mlanevent_imx93` | 68,144 | "
        "`3523a73a544627d3ceae7f3c7ed57cdf19df8a04882b0d0ea14c69bde95dbd05` "
        "| ARM aarch64 executable |",
    ]
    candidate_actual = [
        line for line in candidate_section.splitlines()
        if line.startswith("| `bin_wlan/")
    ]
    corrected_actual = [
        line for line in corrected_section.splitlines()
        if line.startswith("| `bin_wlan/")
    ]
    return (
        candidate_commit == candidate_source
        and corrected_commit == corrected_source
        and candidate_actual == candidate_rows
        and corrected_actual == corrected_rows
        and c464_heading in review
        and historical_heading in review
        and f"final reviewed candidate source `{candidate_commit}`" in design
        and f"corrected source `{corrected_commit}`" in design
        and "c464 target-staged OOB attempt source "
            "`c4644eee070c3a735e83037fdefdfbaf3d74ea8e`" in design
        and "historical 734f75b evidence source "
            "`734f75bf02a3e5ac4c84a696d8a873ed11247ce3`" in design
        and "OOB runtime remains `0/10` cycles" in design
        and "BLOCKED_BY_HARDWARE_CAPABILITY" in design
        and "pre-qualification in-band `543.p18` backup" in design
    )


def replace_after(text: str, marker: str, old: str, new: str) -> str:
    marker_pos = text.find(marker)
    if marker_pos < 0:
        return text
    old_pos = text.find(old, marker_pos)
    if old_pos < 0:
        return text
    return text[:old_pos] + new + text[old_pos + len(old):]


review_require(
    "M2",
    artifact_evidence_is_unambiguously_scoped(port_review_doc, watch_design_doc),
    "M2 artifact identities are not separated into exact candidate/corrected/c464/734f75b scopes",
)
m2_stale_final_hash = port_review_doc.replace(
    "f7155dc139c6a4f976d08815596937ddb8083b8856037bf7b58a29371ba81af3",
    "ea0ec9ad1d53fd98433ff549752be671181443e7fc52de11ac4236410afaa328",
)
review_require(
    "M2",
    not artifact_evidence_is_unambiguously_scoped(
        m2_stale_final_hash, watch_design_doc
    ),
    "M2 artifact invariant accepts the c464 moal hash as candidate evidence",
)
m2_stale_corrected_hash = port_review_doc.replace(
    "482de059b6c1ee2c9c8145c326efbecd8341a5bc0ef5eebde905908a0dc5f498",
    "f7155dc139c6a4f976d08815596937ddb8083b8856037bf7b58a29371ba81af3",
)
review_require(
    "M2",
    not artifact_evidence_is_unambiguously_scoped(
        m2_stale_corrected_hash, watch_design_doc
    ),
    "M2 artifact invariant accepts the failed candidate hash as corrected evidence",
)
m2_qualified_c464 = port_review_doc.replace(
    "; inactive and unqualified)", "; target-qualified)", 1
)
review_require(
    "M2",
    not artifact_evidence_is_unambiguously_scoped(
        m2_qualified_c464, watch_design_doc
    ),
    "M2 artifact invariant accepts a target-qualified c464 label",
)

m2_corrected_heading = (
    "### Corrected transport-binding i.MX93 cross-build "
    "(source `e1c9f49bb6ec8ffd0dc9703909ff4ef823a76436`; host-only)"
)
m2_swapped_rows = replace_after(
    port_review_doc, m2_corrected_heading,
    "`bin_wlan/mlan_imx93.ko`", "`bin_wlan/__artifact_swap__.ko`",
)
m2_swapped_rows = replace_after(
    m2_swapped_rows, m2_corrected_heading,
    "`bin_wlan/moal_imx93.ko`", "`bin_wlan/mlan_imx93.ko`",
)
m2_swapped_rows = replace_after(
    m2_swapped_rows, m2_corrected_heading,
    "`bin_wlan/__artifact_swap__.ko`", "`bin_wlan/moal_imx93.ko`",
)
review_require(
    "M2",
    not artifact_evidence_is_unambiguously_scoped(
        m2_swapped_rows, watch_design_doc
    ),
    "M2 artifact invariant accepts swapped corrected module rows",
)
m2_missing_vermagic = replace_after(
    port_review_doc, m2_corrected_heading,
    "`6.6.3-lts-next-gccf0a99701a7-dirty SMP preempt mod_unload "
    "modversions aarch64`; `543.p18`",
    "`543.p18`",
)
review_require(
    "M2",
    not artifact_evidence_is_unambiguously_scoped(
        m2_missing_vermagic, watch_design_doc
    ),
    "M2 artifact invariant accepts missing corrected vermagic",
)


def qualification_outcome_is_scoped(review: str, design: str) -> bool:
    review_norm = " ".join(review.split())
    design_norm = " ".join(design.split())
    combined = review_norm + " " + design_norm
    required = all(
        phrase in review_norm
        for phrase in (
            "첫 `c4644eee` attempt는",
            "두 번째 `f114208` attempt에서는",
            "| Candidate activation | **FAIL** | 두 attempt 모두 "
            "`SDIO_GPIO_INT_CONFIG` timeout 뒤 firmware init 실패 |",
            "reboot 뒤 fresh baseline gate는 artifact equality 5/5, "
            "required service 6/6 active, SDIO function 2/2, DBDC netdev/STA, "
            "OOB action 0, `intmode=1` line 0",
            "active timer count는 0이다",
            "c464/f114 OOB qualification cleanup 직후 target은 "
            "pre-qualification in-band `543.p18` backup이었다",
            "historical source `734f75bf02a3e5ac4c84a696d8a873ed11247ce3`인 "
            "과거 target slice",
            "corrected transport-binding source `e1c9f49`는 당시 target에 "
            "stage하지 않았다",
            "corrected `e1c9f49` artifact는 target에 전송하지 않았다",
            "historical `734f75b` i.MX93 SD9098 load/version/ping PASS; "
            "corrected `e1c9f49`는 host-only",
            "historical `734f75b` i.MX93 SDIO in-band reload만 bounded slice에서 통과",
            "candidate activation FAIL at the invalid binding alias; corrected "
            "target transport OOB NOT_APPLICABLE / "
            "BLOCKED_BY_HARDWARE_CAPABILITY",
            "invalid-alias candidate activation FAIL, corrected target transport "
            "OOB NOT_APPLICABLE / BLOCKED_BY_HARDWARE_CAPABILITY",
        )
    ) and all(
        phrase in design_norm
        for phrase in (
            "Candidate activation failed before the runtime health gate",
            "| Candidate activation | FAIL — repeated transport configuration "
            "timeout and firmware init failure |",
            "final matching active timer count is zero",
            "corrected source `e1c9f49bb6ec8ffd0dc9703909ff4ef823a76436`",
            "**Status:** Executed — invalid binding alias corrected; 88W9098 "
            "target transport OOB is NOT_APPLICABLE and "
            "BLOCKED_BY_HARDWARE_CAPABILITY.",
            "The corrected target transport OOB is not a retryable runtime "
            "prerequisite",
        )
    )
    forbidden = (
        r"(?:corrected(?: current source)?\s+)?`?e1c9f49`?"
        r"[^|.;]{0,120}\b(?:runtime|load/version/ping)\b"
        r"[^|.;]{0,80}\bPASS\b",
        r"\bcorrected\b[^|.;]{0,180}\bPASS\b",
        r"\be1c9f49[0-9a-f]*\b[^|.;]{0,180}\bPASS\b",
        r"\bcurrent (?:HEAD|source)\b[^|.;]{0,180}\bPASS\b",
        r"corrected current source\s+`?e1c9f49`?",
        r"최종 target은 c464/f114 candidate가 아니라 pre-qualification",
        r"(?:matching )?active[- ]timer count(?:는| is)? "
        r"(?:[1-9][0-9]*|nonzero)",
        r"Candidate activation(?:\s*\|)?\s*\*{0,2}PASS\*{0,2}",
        r"corrected(?: target transport)? OOB(?: runtime)?\s+"
        r"\*{0,2}PASS\*{0,2}",
        r"artifact equality (?!5/5\b)[0-9]+/[0-9]+",
        # The restored OOB baseline had six required services; the later
        # in-band-only validation has five and is independently pinned by M11.
        r"required service (?!(?:6/6|5/5)\b)[0-9]+/[0-9]+",
        r"SDIO function (?!2/2\b)[0-9]+/[0-9]+",
    )
    return required and not any(
        re.search(pattern, combined, re.IGNORECASE) for pattern in forbidden
    )


review_require(
    "M4",
    qualification_outcome_is_scoped(port_review_doc, watch_design_doc),
    "M4 OOB failure, cleanup, or historical runtime scope is ambiguous",
)
m4_candidate_pass = port_review_doc.replace(
    "| Candidate activation | **FAIL** |",
    "| Candidate activation | **PASS** |",
    1,
)
review_require(
    "M4",
    not qualification_outcome_is_scoped(m4_candidate_pass, watch_design_doc),
    "M4 outcome invariant accepts a false candidate activation PASS",
)
m4_bad_equality = port_review_doc.replace(
    "reboot 뒤 fresh baseline gate는 artifact equality 5/5",
    "reboot 뒤 fresh baseline gate는 artifact equality 0/5",
    1,
)
review_require(
    "M4",
    not qualification_outcome_is_scoped(m4_bad_equality, watch_design_doc),
    "M4 outcome invariant accepts failed artifact restoration",
)
m4_bad_timer_count = re.sub(
    r"active\s+timer count는 0",
    "active timer count는 9",
    port_review_doc,
    count=1,
)
review_require(
    "M4",
    not qualification_outcome_is_scoped(m4_bad_timer_count, watch_design_doc),
    "M4 outcome invariant accepts residual active target timers",
)
m4_current_head_pass = port_review_doc.replace(
    "historical source `734f75bf02a3e5ac4c84a696d8a873ed11247ce3`인 "
    "과거 target slice",
    "current HEAD target slice",
    1,
)
review_require(
    "M4",
    not qualification_outcome_is_scoped(m4_current_head_pass, watch_design_doc),
    "M4 outcome invariant assigns historical runtime PASS to current source",
)
m4_stale_corrected_label = re.sub(
    r"corrected transport-binding source `e1c9f49`는 당시 target에\s+"
    r"stage하지 않았다",
    "corrected current source `e1c9f49`는 target에 stage하지 않았다",
    port_review_doc,
    count=1,
)
review_require(
    "M4",
    not qualification_outcome_is_scoped(
        m4_stale_corrected_label, watch_design_doc
    ),
    "M4 outcome invariant accepts a stale corrected-current-source label",
)
m4_additive_current_pass = (
    port_review_doc + "\ncorrected e1c9f49 runtime PASS\n"
)
review_require(
    "M4",
    not qualification_outcome_is_scoped(
        m4_additive_current_pass, watch_design_doc
    ),
    "M4 outcome invariant accepts an additive corrected-source runtime PASS",
)
m4_additive_timer = port_review_doc + "\nactive timer count는 9\n"
review_require(
    "M4",
    not qualification_outcome_is_scoped(m4_additive_timer, watch_design_doc),
    "M4 outcome invariant accepts an additive nonzero timer claim",
)
m4_corrected_runtime_pass = port_review_doc.replace(
    "corrected target transport OOB NOT_APPLICABLE /\n"
    "BLOCKED_BY_HARDWARE_CAPABILITY",
    "corrected target transport OOB PASS",
    1,
)
review_require(
    "M4",
    not qualification_outcome_is_scoped(
        m4_corrected_runtime_pass, watch_design_doc
    ),
    "M4 outcome invariant accepts corrected target runtime PASS",
)
m4_design_runtime_pass = watch_design_doc.replace(
    "88W9098 target transport\nOOB is NOT_APPLICABLE and "
    "BLOCKED_BY_HARDWARE_CAPABILITY.",
    "88W9098 corrected target transport OOB runtime PASS.",
    1,
)
review_require(
    "M4",
    not qualification_outcome_is_scoped(
        port_review_doc, m4_design_runtime_pass
    ),
    "M4 outcome invariant accepts a design-level corrected runtime PASS",
)
m4_additive_sdio_reload_pass = (
    port_review_doc + "\ncorrected e1c9f49 target SDIO reload PASS\n"
)
review_require(
    "M4",
    not qualification_outcome_is_scoped(
        m4_additive_sdio_reload_pass, watch_design_doc
    ),
    "M4 outcome invariant accepts additive corrected SDIO reload PASS",
)
m4_matrix_sdio_reload_pass = port_review_doc.replace(
    "historical `734f75b` i.MX93 SDIO in-band reload만 bounded slice에서 통과",
    "corrected e1c9f49 target SDIO reload PASS",
    1,
)
review_require(
    "M4",
    not qualification_outcome_is_scoped(
        m4_matrix_sdio_reload_pass, watch_design_doc
    ),
    "M4 outcome invariant accepts corrected SDIO reload PASS in the matrix",
)
m4_additive_current_head_pass = (
    port_review_doc + "\ncurrent HEAD target SDIO reload PASS\n"
)
review_require(
    "M4",
    not qualification_outcome_is_scoped(
        m4_additive_current_head_pass, watch_design_doc
    ),
    "M4 outcome invariant accepts additive current-HEAD target PASS",
)
m4_additive_full_hash_pass = (
    port_review_doc
    + "\ne1c9f49bb6ec8ffd0dc9703909ff4ef823a76436 target SDIO reload PASS\n"
)
review_require(
    "M4",
    not qualification_outcome_is_scoped(
        m4_additive_full_hash_pass, watch_design_doc
    ),
    "M4 outcome invariant accepts full-hash corrected target PASS",
)


def current_target_evidence_is_exactly_scoped(review: str) -> bool:
    source = "2717980aaba17f2acd831a9da4b1fcaa2c4dc597"
    headings = list(re.finditer(
        r"^### Current i\.MX93 SDIO in-band target evidence "
        r"\(source `([0-9a-f]{40})`; active validation deployment\)$",
        review,
        re.MULTILINE,
    ))
    if len(headings) != 1 or headings[0].group(1) != source:
        return False
    heading = headings[0]
    section_start = heading.end()
    section_end = review.find("\n### ", section_start)
    if section_end < 0:
        return False
    section = review[section_start:section_end]
    # This evidence block is immutable: semantic checks below explain its
    # contract, while the digest rejects every additive contradictory claim.
    expected_section_digest = (
        "a9c38fc6103bb0084a282117fec9deb46510c370f72d6ab0ebb3e40175b986dc"
    )
    section_digest = hashlib.sha256(section.encode("utf-8")).hexdigest()
    artifact_rows = [
        line for line in section.splitlines()
        if line.startswith("| `bin_wlan/")
    ]
    expected_rows = [
        "| `bin_wlan/mlan_imx93.ko` | 992,720 | "
        "`0c0347b6ef08ae0d605655b62e70121440d0f0961277d25f5eb27fe4b595b396` "
        "| `543.p18`; `69CD10BAA7F3A642C954443` |",
        "| `bin_wlan/moal_imx93.ko` | 1,978,760 | "
        "`5ba9690a2488cd4cf8ee4549a78f7de4643d2cc0d504c3b70faf4cac7e640c50` "
        "| `543.p18`; `E14FF2EA56EE8DA9F44DC18` |",
        "| `bin_wlan/mlanutl_imx93` | 400,968 | "
        "`127912311df9397df9104cf8fe96f4501ecc1edf9df67007d54af6f95c2ae4a3` "
        "| ARM aarch64 executable |",
        "| `bin_wlan/mlanevent_imx93` | 68,144 | "
        "`3523a73a544627d3ceae7f3c7ed57cdf19df8a04882b0d0ea14c69bde95dbd05` "
        "| ARM aarch64 executable |",
    ]
    expected_hashes = [
        "0c0347b6ef08ae0d605655b62e70121440d0f0961277d25f5eb27fe4b595b396",
        "5ba9690a2488cd4cf8ee4549a78f7de4643d2cc0d504c3b70faf4cac7e640c50",
        "127912311df9397df9104cf8fe96f4501ecc1edf9df67007d54af6f95c2ae4a3",
        "3523a73a544627d3ceae7f3c7ed57cdf19df8a04882b0d0ea14c69bde95dbd05",
    ]
    expected_identity_tokens = [
        source,
        "69cd10baa7f3a642c954443",
        "e14ff2ea56ee8da9f44dc18",
    ]
    expected_artifact_mentions = [
        "bin_wlan/mlan_imx93.ko",
        "bin_wlan/moal_imx93.ko",
        "bin_wlan/mlanutl_imx93",
        "bin_wlan/mlanevent_imx93",
    ]
    source_ids = [
        match.lower()
        for match in re.findall(
            r"(?<![0-9a-f])([0-9a-f]{40})(?![0-9a-f])",
            section,
            re.IGNORECASE,
        )
    ]
    artifact_hashes = [
        match.lower()
        for match in re.findall(
            r"(?<![0-9a-f])([0-9a-f]{64})(?![0-9a-f])",
            section,
            re.IGNORECASE,
        )
    ]
    identity_tokens = [
        match.lower()
        for match in re.findall(
            r"(?<![0-9a-f])([0-9a-f]{7,63})(?![0-9a-f])",
            section,
            re.IGNORECASE,
        )
    ]
    artifact_mentions = re.findall(r"`(bin_wlan/[^`]+)`", section)
    required = all(
        phrase in section
        for phrase in (
            "exact source `2717980aaba17f2acd831a9da4b1fcaa2c4dc597`에만 귀속된다",
            "old `505.p14`→new `543.p18` 전환에서는 기존 module teardown의 "
            "`FUNC_SHUTDOWN [0xaa]` timeout이 1건",
            "candidate `543.p18`→`543.p18` reload는 5/5",
            "candidate `FUNC_SHUTDOWN` timeout 0건, sensor timeout 0건, "
            "kernel health signature 0건",
            "candidate traffic은 45/45 ICMP, 0% loss",
            "required service 5/5 active",
            "SDIO function 2/2 version query",
            "`mlan0 UP/connected`, `mlan1 present/DOWN`",
            "rollback timer inactive, board holder/reservation 0/0",
            "`/opt/wlan` validation deployment이며 package release가 아니다",
            "`/lib/modules`에는 write하지 않았다",
            "`/lib/modules/.../updates`와 package-generated manifest는 갱신하지 않았다",
            "USB/PCIe runtime은 `OUT_OF_SCOPE / NOT_REQUIRED`로 실행하지 않았다",
            "OOB, suspend/resume 또는 long-traffic PASS를 뜻하지 않는다",
        )
    )
    scope_disclaimer = (
        "OOB, suspend/resume 또는 long-traffic PASS를 뜻하지 않는다"
    )
    claims = section.replace(scope_disclaimer, "")
    forbidden = (
        r"\bcandidate(?:/kernel)?\b[^\n.]{0,160}"
        r"\b(?:timeout|error signatures?|kernel health signature)\b"
        r"[^\n.0-9]{0,24}(?:nonzero|[1-9][0-9]*)",
        r"\b(?:sensor timeout|kernel health signature|kernel error signatures?)"
        r"\b[^\n.0-9]{0,24}(?:nonzero|[1-9][0-9]*)",
        r"\bcandidate\b[^\n.]{0,100}reload(?:는|은)?\s*"
        r"(?!5/5\b)[0-9]+/[0-9]+",
        r"\bcandidate traffic(?:은|는)?\s*(?!45/45\b)[0-9]+/[0-9]+",
        r"(?<![0-9])(?:[1-9][0-9]*(?:\.[0-9]+)?)%\s*loss\b",
        r"\brequired service\s+(?!5/5\b)[0-9]+/[0-9]+",
        r"\bSDIO function\s+(?!2/2\b)[0-9]+/[0-9]+",
        r"\brollback timer\b[^\n.]{0,40}\bactive\b",
        r"\bboard holder/reservation\s+(?!0/0\b)[0-9]+/[0-9]+",
        r"\bmlan0\b[^`,\n.]{0,60}\b(?:DOWN|disconnected)\b",
        r"\bmlan1\b[^`,\n.]{0,60}\b(?:UP|connected)\b",
        r"/lib/modules[^\n]{0,100}(?:\b(?:updated|modified|written)\b|"
        r"(?:write|갱신|수정)했다)",
        r"package-generated manifest[^\n.]{0,80}"
        r"(?:\b(?:updated|modified|written)\b|(?:write|갱신|수정)했다)",
        r"\bOOB\b[^\n.]{0,80}\bPASS\b",
        r"\b(?:PM|suspend/resume|long-traffic)\b[^\n.]{0,80}\bPASS\b",
        r"\b(?:USB|PCIe)\b[^\n.]{0,80}\bPASS\b",
        r"\bpackage(?:\s+release)?\b[^\n.]{0,80}"
        r"\b(?:complete|completed|PASS)\b",
    )
    return (
        artifact_rows == expected_rows
        and section_digest == expected_section_digest
        and source_ids == [source]
        and artifact_hashes == expected_hashes
        and identity_tokens == expected_identity_tokens
        and artifact_mentions == expected_artifact_mentions
        and required
        and not any(
            re.search(pattern, claims, re.IGNORECASE) for pattern in forbidden
        )
    )


review_require(
    "M11",
    current_target_evidence_is_exactly_scoped(port_review_doc),
    "M11 current 2717980 target evidence is missing, stale, or over-scoped",
)
m11_stale_source = port_review_doc.replace(
    "source `2717980aaba17f2acd831a9da4b1fcaa2c4dc597`; active validation deployment",
    "source `e1c9f49bb6ec8ffd0dc9703909ff4ef823a76436`; active validation deployment",
    1,
)
review_require(
    "M11",
    not current_target_evidence_is_exactly_scoped(m11_stale_source),
    "M11 target invariant accepts evidence assigned to the wrong source",
)
m11_stale_hash = port_review_doc.replace(
    "5ba9690a2488cd4cf8ee4549a78f7de4643d2cc0d504c3b70faf4cac7e640c50",
    "569a0cb30a4b08689def8405fd84122ac36f7f924c8fe7d59948b25cda16d7f5",
    1,
)
review_require(
    "M11",
    not current_target_evidence_is_exactly_scoped(m11_stale_hash),
    "M11 target invariant accepts the historical moal artifact hash",
)
m11_candidate_timeout = port_review_doc.replace(
    "candidate `FUNC_SHUTDOWN` timeout 0건",
    "candidate `FUNC_SHUTDOWN` timeout 1건",
    1,
)
review_require(
    "M11",
    not current_target_evidence_is_exactly_scoped(m11_candidate_timeout),
    "M11 target invariant accepts a candidate teardown timeout",
)
m11_false_oob = port_review_doc.replace(
    "OOB, suspend/resume 또는 long-traffic PASS를 뜻하지 않는다",
    "OOB runtime PASS",
    1,
)
review_require(
    "M11",
    not current_target_evidence_is_exactly_scoped(m11_false_oob),
    "M11 target invariant promotes in-band evidence to OOB PASS",
)


def add_current_target_claim(review: str, claim: str) -> str:
    next_heading = "\n### Userspace와 mirrored headers"
    return review.replace(
        next_heading,
        f"\n{claim}\n{next_heading}",
        1,
    )


m11_additive_candidate_timeout = add_current_target_claim(
    port_review_doc, "candidate FUNC_SHUTDOWN timeout 1건"
)
review_require(
    "M11",
    not current_target_evidence_is_exactly_scoped(
        m11_additive_candidate_timeout
    ),
    "M11 target invariant accepts an additive candidate timeout",
)
m11_additive_kernel_error = add_current_target_claim(
    port_review_doc, "candidate/kernel error signatures 1건"
)
review_require(
    "M11",
    not current_target_evidence_is_exactly_scoped(m11_additive_kernel_error),
    "M11 target invariant accepts additive candidate/kernel errors",
)
m11_additive_kernel_health = add_current_target_claim(
    port_review_doc, "kernel health signature 1건"
)
review_require(
    "M11",
    not current_target_evidence_is_exactly_scoped(m11_additive_kernel_health),
    "M11 target invariant accepts an additive kernel health signature",
)
m11_additive_sensor_timeout = add_current_target_claim(
    port_review_doc, "sensor timeout 1건"
)
review_require(
    "M11",
    not current_target_evidence_is_exactly_scoped(m11_additive_sensor_timeout),
    "M11 target invariant accepts an additive sensor timeout",
)
m11_additive_stale_source = add_current_target_claim(
    port_review_doc,
    "current evidence source `e1c9f49bb6ec8ffd0dc9703909ff4ef823a76436`",
)
review_require(
    "M11",
    not current_target_evidence_is_exactly_scoped(m11_additive_stale_source),
    "M11 target invariant accepts an additive stale source",
)
m11_additive_stale_hash = add_current_target_claim(
    port_review_doc,
    "active moal SHA-256 "
    "`569a0cb30a4b08689def8405fd84122ac36f7f924c8fe7d59948b25cda16d7f5`",
)
review_require(
    "M11",
    not current_target_evidence_is_exactly_scoped(m11_additive_stale_hash),
    "M11 target invariant accepts an additive stale artifact hash",
)
for m11_state_label, m11_state_claim in (
    ("abbreviated stale source", "current evidence source `e1c9f49`"),
    ("abbreviated stale hash", "active moal SHA-256 `569a0cb3`"),
    ("candidate reload shortfall", "candidate reload 4/5"),
    ("candidate traffic shortfall", "candidate traffic 44/45"),
    ("candidate packet loss", "candidate traffic 45/45 ICMP, 2% loss"),
    ("stale active version", "active candidate version 505.p14"),
    ("stale moal size", "active moal bytes 1,978,536"),
    ("required-service shortfall", "required service 4/5 active"),
    ("SDIO-function shortfall", "SDIO function 1/2 version query"),
    ("active rollback", "rollback timer active"),
    ("armed rollback", "rollback timer armed"),
    ("occupied board", "board holder/reservation 1/0"),
    ("mlan0 regression", "mlan0 DOWN/disconnected"),
    ("mlan1 scope expansion", "mlan1 UP/connected"),
    ("module-tree update", "/lib/modules/.../updates updated"),
    ("manifest update", "package-generated manifest updated"),
):
    review_require(
        "M11",
        not current_target_evidence_is_exactly_scoped(
            add_current_target_claim(port_review_doc, m11_state_claim)
        ),
        f"M11 target invariant accepts additive {m11_state_label}",
    )
for m11_scope_label, m11_scope_claim in (
    ("OOB", "OOB PASS"),
    ("target OOB", "target OOB traffic qualification PASS"),
    ("PM", "PM PASS"),
    ("long-traffic", "long-traffic PASS"),
    ("USB", "USB runtime PASS"),
    ("PCIe", "PCIe runtime PASS"),
    ("USB hardware", "USB hardware qualification PASS"),
    ("PCIe hardware", "PCIe hardware qualification PASS"),
    ("package", "package release complete"),
    ("package qualification", "package release qualification PASS"),
):
    review_require(
        "M11",
        not current_target_evidence_is_exactly_scoped(
            add_current_target_claim(port_review_doc, m11_scope_claim)
        ),
        f"M11 target invariant accepts additive {m11_scope_label} promotion",
    )
m11_duplicate_heading = (
    port_review_doc
    + "\n### Current i.MX93 SDIO in-band target evidence "
    "(source `2717980aaba17f2acd831a9da4b1fcaa2c4dc597`; "
    "active validation deployment)\n"
)
review_require(
    "M11",
    not current_target_evidence_is_exactly_scoped(m11_duplicate_heading),
    "M11 target invariant accepts a duplicate current-evidence heading",
)


OOB_CAPABILITY_CLOSURE_BASE = "22d184bd08b5aff441f45d6784416c6fa10c8a37"
OOB_CAPABILITY_CLOSURE_COMMIT = "1f9d15b15a1b7001e71b2271e3168fefe39de86b"
OOB_CAPABILITY_CLOSURE_PATHS = frozenset(
    {
        "docs/superpowers/specs/2026-08-21-upstream-port-watch-closure-design.md",
        "docs/upstream-port-0396-code-review.md",
        "scripts/tests/upstream_port_invariants.py",
    }
)
OOB_TARGET_POLICY_BLOCK = (
    "#### Authoritative target policy (`OOB_TARGET_POLICY_V1`)",
    "",
    "| policy key | value |",
    "|---|---|",
    "| `chip` | `88W9098` |",
    "| `transport_oob` | `NOT_APPLICABLE` |",
    "| `block_reason` | `BLOCKED_BY_HARDWARE_CAPABILITY` |",
    "| `runtime_intmode` | `0` |",
    "| `wake_binding_reuse` | `FORBIDDEN` |",
    "| `bsp_dtb_mutation` | `FORBIDDEN` |",
    "| `target_mutation` | `FORBIDDEN` |",
    "| `target_oob_retry` | `FORBIDDEN` |",
    "| `new_maintenance_window` | `FORBIDDEN` |",
    "| `generic_upstream_oob` | `RETAIN` |",
    "| `production_c_change` | `NONE` |",
    "",
    "This `OOB_TARGET_POLICY_V1` table is the sole normative target policy;",
    "conflicting prose is invalid and cannot authorize a target action.",
    "",
)
PRODUCT_SCOPE_POLICY_BLOCK = (
    "### Authoritative product scope (`PRODUCT_SCOPE_POLICY_V1`)",
    "",
    "| policy key | value |",
    "|---|---|",
    "| `product_target` | `i.MX93 + 88W9098 SDIO in-band` |",
    "| `usb_runtime_validation` | `OUT_OF_SCOPE / NOT_REQUIRED` |",
    "| `pcie_runtime_validation` | `OUT_OF_SCOPE / NOT_REQUIRED` |",
    "| `pr_review_state` | `READY_FOR_REVIEW` |",
    "| `merge_authorization` | `SEPARATE_EXPLICIT_DECISION_REQUIRED` |",
    "",
    "This `PRODUCT_SCOPE_POLICY_V1` table is the sole normative product-scope and",
    "integration-state policy; conflicting prose cannot authorize merge or restore",
    "USB/PCIe as blockers.",
    "",
)


def oob_capability_closure_changed_paths() -> tuple[str, ...] | None:
    result = subprocess.run(
        [
            "git",
            "diff",
            "--name-only",
            "--no-renames",
            OOB_CAPABILITY_CLOSURE_BASE,
            OOB_CAPABILITY_CLOSURE_COMMIT,
            "--",
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return tuple(line for line in result.stdout.splitlines() if line)


def oob_capability_closure_is_docs_and_test_only(
    changed_paths: tuple[str, ...] | None,
) -> bool:
    return (
        changed_paths is not None
        and set(changed_paths) == OOB_CAPABILITY_CLOSURE_PATHS
    )


def target_oob_policy_block_is_exact(document: str) -> bool:
    lines = document.splitlines()
    heading = OOB_TARGET_POLICY_BLOCK[0]
    positions = [pos for pos, line in enumerate(lines) if line == heading]
    if len(positions) != 1:
        return False
    start = positions[0]
    stop = start + len(OOB_TARGET_POLICY_BLOCK)
    return tuple(lines[start:stop]) == OOB_TARGET_POLICY_BLOCK


def product_scope_policy_block_is_exact(document: str) -> bool:
    lines = document.splitlines()
    heading = PRODUCT_SCOPE_POLICY_BLOCK[0]
    positions = [pos for pos, line in enumerate(lines) if line == heading]
    if len(positions) != 1:
        return False
    start = positions[0]
    stop = start + len(PRODUCT_SCOPE_POLICY_BLOCK)
    return tuple(lines[start:stop]) == PRODUCT_SCOPE_POLICY_BLOCK


def target_oob_hardware_capability_is_scoped(review: str, design: str) -> bool:
    review_norm = " ".join(review.split())
    design_norm = " ".join(design.split())
    combined = review + "\n" + design
    support_url = (
        "https://community.nxp.com/t5/Wi-Fi-Bluetooth-802-15-4/"
        "M2-JODY-W377-88W9098-OOB-interrupt/m-p/2351813/highlight/true"
    )
    dtb_hash = (
        "9a491ab1155f69a56bdfb931aa8dbae5f2a3ad2dfbef7087005fd02baa093d39"
    )
    required_review = (
        "88W9098 target OOB capability closure",
        "NOT_APPLICABLE / BLOCKED_BY_HARDWARE_CAPABILITY",
        "target deployment must retain `intmode=0`",
        "`nxp,wifi-wake-host` must not be aliased or relabeled as "
        "`nxp,wifi-oob-int`",
        "No BSP/DT patch, target mutation, or additional OOB maintenance "
        "window is authorized",
        "Generic upstream OOB transport code remains retained for hardware "
        "that supplies a supported transport-event line",
        "이 capability closure에는 production C 변경과 target 변경이 없다.",
        "ccf0a99701a701fb48a04e31ffe3f9d585a8374a",
        dtb_hash,
        support_url,
    )
    required_design = (
        "88W9098 target transport OOB is NOT_APPLICABLE and "
        "BLOCKED_BY_HARDWARE_CAPABILITY",
        "The target deployment must retain `intmode=0`",
        "Never alias or relabel `nxp,wifi-wake-host` as "
        "`nxp,wifi-oob-int`",
        "Do not patch/deploy the BSP or DTB and do not schedule another "
        "target OOB maintenance window",
        "Keep the generic upstream OOB transport implementation for other "
        "hardware with a supported transport-event line",
        "This closure adds no production C change and no target mutation.",
        "GPIO3_IO26",
        dtb_hash,
        support_url,
    )
    action_prefix = r"(?:^|[\n.;])\s*(?:[-*+>]\s+|\d+[.)]\s+)?"
    forbidden = (
        r"\btarget\s+OOB\s+is\s+"
        r"BLOCKED_BY_(?:PLATFORM_)?PREREQUISITE\b",
        r"\btarget\s+OOB\s+is\s+(?:a\s+)?retryable\b",
        r"\b(?:88W9098\s+)?target deployment must "
        r"(?:use|enable|set|retain)\s+`?intmode=1`?",
        action_prefix
        + r"(?=[^\n]*(?:88W9098|target))(?=[^\n]*`?intmode=1`?)"
        r"(?:Use|Enable|Set|Switch)\b[^\n]*",
        action_prefix
        + r"Alias\s+`nxp,wifi-wake-host`\s+as\s+"
        r"`nxp,wifi-oob-int`",
        action_prefix
        + r"(?:Patch|Modify|Update|Deploy)(?:\s+and\s+deploy)?\s+"
        r"(?:the\s+)?"
        r"(?:BSP/DTB|BSP|DTB)\b",
        action_prefix
        + r"(?:Retry|Rerun|Resume|Reopen)\b[^\n]*\btarget\s+OOB\b",
        action_prefix
        + r"Schedule\s+another\s+target\s+OOB\s+"
        r"maintenance\s+window\b",
        action_prefix
        + r"(?:Remove|Drop|Delete|Disable)\s+(?:the\s+)?generic\s+"
        r"(?:upstream\s+)?"
        r"OOB\s+(?:transport\s+implementation|support)\b",
    )
    required = (
        target_oob_policy_block_is_exact(review)
        and target_oob_policy_block_is_exact(design)
        and all(phrase in review_norm for phrase in required_review)
        and all(phrase in design_norm for phrase in required_design)
    )
    return required and not any(
        re.search(pattern, combined, re.IGNORECASE) for pattern in forbidden
    )


review_require(
    "M5",
    target_oob_hardware_capability_is_scoped(
        port_review_doc, watch_design_doc
    ),
    "M5 88W9098 target OOB hardware-capability closure is incomplete",
)
oob_capability_changed_paths = oob_capability_closure_changed_paths()
review_require(
    "M5",
    oob_capability_closure_is_docs_and_test_only(
        oob_capability_changed_paths
    ),
    "M5 capability closure changes files outside the approved docs/test scope",
)
m5_production_c_path = tuple(oob_capability_changed_paths or ()) + (
    "mlinux/moal_sdio_mmc.c",
)
review_require(
    "M5",
    not oob_capability_closure_is_docs_and_test_only(m5_production_c_path),
    "M5 capability closure scope accepts a production C change",
)
m5_platform_prerequisite = re.sub(
    r"NOT_APPLICABLE\s*/\s*BLOCKED_BY_HARDWARE_CAPABILITY",
    "BLOCKED_BY_PLATFORM_PREREQUISITE",
    port_review_doc,
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        m5_platform_prerequisite, watch_design_doc
    ),
    "M5 capability invariant accepts a retryable platform prerequisite",
)
m5_enable_oob = port_review_doc.replace(
    "target deployment must retain `intmode=0`",
    "target deployment must use `intmode=1`",
    1,
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        m5_enable_oob, watch_design_doc
    ),
    "M5 capability invariant accepts intmode=1 on the 88W9098 target",
)
m5_alias_wake_node = watch_design_doc.replace(
    "Never alias or relabel `nxp,wifi-wake-host` as `nxp,wifi-oob-int`",
    "Alias `nxp,wifi-wake-host` as `nxp,wifi-oob-int`",
    1,
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_alias_wake_node
    ),
    "M5 capability invariant accepts reuse of the wake-only binding",
)
m5_remove_generic_oob = watch_design_doc.replace(
    "Keep the generic upstream OOB transport implementation for other hardware\n"
    "with a supported transport-event line",
    "Remove the generic upstream OOB transport implementation",
    1,
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_remove_generic_oob
    ),
    "M5 capability invariant accepts removal of generic upstream OOB support",
)
m5_additive_prerequisite = (
    port_review_doc
    + "\nTarget OOB is BLOCKED_BY_PLATFORM_PREREQUISITE and should be retried.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        m5_additive_prerequisite, watch_design_doc
    ),
    "M5 capability invariant accepts an additive retryable prerequisite",
)
m5_additive_intmode = (
    port_review_doc
    + "\nThe 88W9098 target deployment must use `intmode=1`.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        m5_additive_intmode, watch_design_doc
    ),
    "M5 capability invariant accepts an additive intmode=1 instruction",
)
m5_additive_alias = (
    watch_design_doc
    + "\nAlias `nxp,wifi-wake-host` as `nxp,wifi-oob-int`.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_additive_alias
    ),
    "M5 capability invariant accepts an additive wake-node alias",
)
m5_additive_bsp_mutation = (
    watch_design_doc
    + "\nPatch and deploy the BSP/DTB and mutate the target for OOB.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_additive_bsp_mutation
    ),
    "M5 capability invariant accepts additive BSP/target mutation",
)
m5_additive_window = (
    watch_design_doc + "\nSchedule another target OOB maintenance window.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_additive_window
    ),
    "M5 capability invariant accepts an additive target OOB window",
)
m5_additive_remove_generic = (
    watch_design_doc + "\nRemove generic upstream OOB support.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_additive_remove_generic
    ),
    "M5 capability invariant accepts additive generic OOB removal",
)
m5_missing_no_c_change_claim = port_review_doc.replace(
    "이 capability closure에는 production C 변경과 target 변경이 없다.",
    "",
    1,
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        m5_missing_no_c_change_claim, watch_design_doc
    ),
    "M5 capability invariant accepts a missing production-C scope claim",
)
m5_bullet_alias = (
    watch_design_doc
    + "\n- Alias `nxp,wifi-wake-host` as `nxp,wifi-oob-int`.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_bullet_alias
    ),
    "M5 capability invariant accepts a bullet-form wake-node alias",
)
m5_bullet_bsp = (
    watch_design_doc
    + "\n- Patch and deploy the BSP/DTB and mutate the target for OOB.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_bullet_bsp
    ),
    "M5 capability invariant accepts bullet-form BSP/target mutation",
)
m5_bullet_window = (
    watch_design_doc + "\n- Schedule another target OOB maintenance window.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_bullet_window
    ),
    "M5 capability invariant accepts a bullet-form target OOB window",
)
m5_bullet_remove_generic = (
    watch_design_doc + "\n- Remove generic upstream OOB support.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_bullet_remove_generic
    ),
    "M5 capability invariant accepts bullet-form generic OOB removal",
)
m5_safe_negation = (
    port_review_doc
    + "\nTarget OOB is not BLOCKED_BY_PLATFORM_PREREQUISITE.\n"
)
review_require(
    "M5",
    target_oob_hardware_capability_is_scoped(
        m5_safe_negation, watch_design_doc
    ),
    "M5 capability invariant rejects a safe prerequisite negation",
)
m5_policy_intmode_one = port_review_doc.replace(
    "| `runtime_intmode` | `0` |",
    "| `runtime_intmode` | `1` |",
    1,
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        m5_policy_intmode_one, watch_design_doc
    ),
    "M5 capability invariant accepts intmode=1 in the normative policy",
)
m5_policy_retry_allowed = watch_design_doc.replace(
    "| `target_oob_retry` | `FORBIDDEN` |",
    "| `target_oob_retry` | `ALLOWED` |",
    1,
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_policy_retry_allowed
    ),
    "M5 capability invariant accepts retry in the normative policy",
)
m5_duplicate_policy = (
    watch_design_doc + "\n" + "\n".join(OOB_TARGET_POLICY_BLOCK) + "\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_duplicate_policy
    ),
    "M5 capability invariant accepts duplicate normative policy blocks",
)
m5_rephrased_intmode = (
    watch_design_doc + "\n- Enable `intmode=1` on the 88W9098 target.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_rephrased_intmode
    ),
    "M5 capability invariant accepts a rephrased intmode=1 instruction",
)
m5_rephrased_retry = (
    watch_design_doc + "\n- Retry target OOB after adding a board line.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_rephrased_retry
    ),
    "M5 capability invariant accepts a rephrased target OOB retry",
)
m5_rephrased_bsp = (
    watch_design_doc + "\n- Modify the BSP for target OOB transport.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_rephrased_bsp
    ),
    "M5 capability invariant accepts a rephrased BSP mutation",
)
m5_rephrased_remove_generic = (
    watch_design_doc + "\n- Drop generic upstream OOB support.\n"
)
review_require(
    "M5",
    not target_oob_hardware_capability_is_scoped(
        port_review_doc, m5_rephrased_remove_generic
    ),
    "M5 capability invariant accepts rephrased generic OOB removal",
)


def approved_product_scope_is_ready(review: str, design: str) -> bool:
    review_norm = " ".join(review.split())
    design_norm = " ".join(design.split())
    combined = review_norm + " " + design_norm
    required_review = (
        "## Approved product qualification scope",
        "Required product target: `i.MX93 + 88W9098 SDIO in-band`.",
        "USB runtime validation: `OUT_OF_SCOPE / NOT_REQUIRED`.",
        "PCIe runtime/FLR validation: `OUT_OF_SCOPE / NOT_REQUIRED`.",
        "USB/PCIe runtime validation is not a Ready-for-review or merge blocker.",
        "PR #27 is Ready for review under this approved product scope.",
        "Merge remains a separate explicit decision.",
        "| USB runtime | **OUT OF SCOPE** | "
        "`OUT_OF_SCOPE / NOT_REQUIRED` |",
        "| PCIe runtime/FLR | **OUT OF SCOPE** | "
        "`OUT_OF_SCOPE / NOT_REQUIRED` |",
    )
    required_design = (
        "## Approved product scope and PR disposition",
        "The approved product qualification scope is "
        "`i.MX93 + 88W9098 SDIO in-band`.",
        "USB and PCIe runtime validation are `OUT_OF_SCOPE / NOT_REQUIRED`",
        "their absence is not a Ready-for-review or merge blocker",
        "PR #27 may transition to Ready for review.",
        "Merge remains a separate explicit decision.",
        "| USB runtime | `OUT_OF_SCOPE / NOT_REQUIRED` |",
        "| PCIe runtime/FLR | `OUT_OF_SCOPE / NOT_REQUIRED` |",
    )
    forbidden = (
        r"\| USB runtime \|[^\n|]*\| `BLOCKED_BY_HARDWARE` \|",
        r"\| PCIe runtime/FLR \|[^\n|]*\| `BLOCKED_BY_HARDWARE` \|",
        r"\| USB runtime \| `BLOCKED_BY_HARDWARE` \|",
        r"\| PCIe runtime/FLR \| `BLOCKED_BY_HARDWARE` \|",
        r"\bUSB/PCIe runtime validation is required before (?:Ready|merge)\b",
        r"\bUSB runtime validation is (?:a )?(?:Ready-for-review|merge) blocker\b",
        r"\bPCIe runtime validation is (?:a )?(?:Ready-for-review|merge) blocker\b",
        r"\bPR #27 must remain Draft\b",
        r"\bPR #27 is (?:approved|authorized) to merge(?: now)?\b",
        r"\bReady status automatically authorizes merge\b",
        r"\bmerge remains separately authorized\b",
        r"Draft PR #27은 Draft로 (?:유지|남아야)",
        r"merge-ready 판정을 하지 않는다",
    )
    required = (
        product_scope_policy_block_is_exact(review)
        and product_scope_policy_block_is_exact(design)
        and all(phrase in review_norm for phrase in required_review)
        and all(phrase in design_norm for phrase in required_design)
    )
    return required and not any(
        re.search(pattern, combined, re.IGNORECASE) for pattern in forbidden
    )


review_require(
    "M6",
    approved_product_scope_is_ready(port_review_doc, watch_design_doc),
    "M6 approved i.MX93/88W9098 product scope is not Ready-for-review",
)
m6_usb_required = port_review_doc.replace(
    "USB runtime validation: `OUT_OF_SCOPE / NOT_REQUIRED`.",
    "USB runtime validation: `REQUIRED`.",
    1,
)
review_require(
    "M6",
    not approved_product_scope_is_ready(m6_usb_required, watch_design_doc),
    "M6 scope invariant accepts required USB runtime validation",
)
m6_pcie_required = port_review_doc.replace(
    "PCIe runtime/FLR validation: `OUT_OF_SCOPE / NOT_REQUIRED`.",
    "PCIe runtime/FLR validation: `REQUIRED`.",
    1,
)
review_require(
    "M6",
    not approved_product_scope_is_ready(m6_pcie_required, watch_design_doc),
    "M6 scope invariant accepts required PCIe runtime validation",
)
m6_draft_only = watch_design_doc.replace(
    "PR #27 may transition to Ready for review.",
    "PR #27 must remain Draft.",
    1,
)
review_require(
    "M6",
    not approved_product_scope_is_ready(port_review_doc, m6_draft_only),
    "M6 scope invariant accepts a Draft-only disposition",
)
m6_additive_blocker = (
    port_review_doc
    + "\nUSB/PCIe runtime validation is required before merge.\n"
)
review_require(
    "M6",
    not approved_product_scope_is_ready(m6_additive_blocker, watch_design_doc),
    "M6 scope invariant accepts an additive USB/PCIe merge blocker",
)
m6_design_usb_blocked = watch_design_doc.replace(
    "| USB runtime | `OUT_OF_SCOPE / NOT_REQUIRED` |",
    "| USB runtime | `BLOCKED_BY_HARDWARE` |",
    1,
)
review_require(
    "M6",
    not approved_product_scope_is_ready(
        port_review_doc, m6_design_usb_blocked
    ),
    "M6 scope invariant accepts blocked USB in the design matrix",
)
m6_design_pcie_blocked = watch_design_doc.replace(
    "| PCIe runtime/FLR | `OUT_OF_SCOPE / NOT_REQUIRED` |",
    "| PCIe runtime/FLR | `BLOCKED_BY_HARDWARE` |",
    1,
)
review_require(
    "M6",
    not approved_product_scope_is_ready(
        port_review_doc, m6_design_pcie_blocked
    ),
    "M6 scope invariant accepts blocked PCIe in the design matrix",
)
m6_additive_merge_approved = (
    port_review_doc + "\nPR #27 is approved to merge now.\n"
)
review_require(
    "M6",
    not approved_product_scope_is_ready(
        m6_additive_merge_approved, watch_design_doc
    ),
    "M6 scope invariant accepts additive merge approval",
)
m6_additive_ready_auto_merge = (
    watch_design_doc + "\nReady status automatically authorizes merge.\n"
)
review_require(
    "M6",
    not approved_product_scope_is_ready(
        port_review_doc, m6_additive_ready_auto_merge
    ),
    "M6 scope invariant accepts automatic merge authorization",
)
m6_additive_usb_blocker = (
    port_review_doc + "\nUSB runtime validation is a merge blocker.\n"
)
review_require(
    "M6",
    not approved_product_scope_is_ready(
        m6_additive_usb_blocker, watch_design_doc
    ),
    "M6 scope invariant accepts an individual USB blocker",
)
m6_additive_pcie_blocker = (
    port_review_doc + "\nPCIe runtime validation is a Ready-for-review blocker.\n"
)
review_require(
    "M6",
    not approved_product_scope_is_ready(
        m6_additive_pcie_blocker, watch_design_doc
    ),
    "M6 scope invariant accepts an individual PCIe blocker",
)
m6_policy_auto_merge = port_review_doc.replace(
    "| `merge_authorization` | `SEPARATE_EXPLICIT_DECISION_REQUIRED` |",
    "| `merge_authorization` | `AUTOMATIC` |",
    1,
)
review_require(
    "M6",
    not approved_product_scope_is_ready(
        m6_policy_auto_merge, watch_design_doc
    ),
    "M6 scope invariant accepts automatic merge in the normative policy",
)
m6_policy_draft = watch_design_doc.replace(
    "| `pr_review_state` | `READY_FOR_REVIEW` |",
    "| `pr_review_state` | `DRAFT` |",
    1,
)
review_require(
    "M6",
    not approved_product_scope_is_ready(port_review_doc, m6_policy_draft),
    "M6 scope invariant accepts Draft in the normative policy",
)
m6_duplicate_policy = (
    watch_design_doc
    + "\n"
    + "\n".join(PRODUCT_SCOPE_POLICY_BLOCK)
    + "\n"
)
review_require(
    "M6",
    not approved_product_scope_is_ready(
        port_review_doc, m6_duplicate_policy
    ),
    "M6 scope invariant accepts duplicate product-scope policy blocks",
)

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
cleanup_module = c_function(main_c, "static void woal_cleanup_module")
sdio_interrupt = c_function(
    sdio_c, "static void woal_sdio_interrupt"
)
sdio_oob_work = c_function(
    sdio_c, "static void woal_sdio_oob_irq_work"
)
sdio_oob_release_token = c_function(
    sdio_c, "static void woal_sdio_oob_irq_release"
)
sdio_oob_release_work = c_function(
    sdio_c, "static void woal_sdio_oob_irq_release_work"
)
sdio_oob_interrupt = c_function(sdio_c, "static irqreturn_t oob_sdio_irq")
sdio_oob_unregister = c_function(
    sdio_c, "static int oob_sdio_irq_unregister"
)
sdio_oob_force_detach = c_function(
    sdio_c, "static void woal_sdio_force_detach_irq"
)
sdio_oob_register = c_function(
    sdio_c, "static int oob_sdio_irq_register"
)
sdio_func_intr_disable = c_function(
    sdio_c, "static int sdio_func_intr_disable"
)
sdio_release_irq = c_function(sdio_c, "static int woal_sdio_release_irq")
sdio_claim_irq = c_function(sdio_c, "static int woal_sdio_claim_irq")
sdio_register_dev = c_function(
    sdio_c, "static mlan_status woal_sdiommc_register_dev"
)
sdio_unregister_dev = c_function(
    sdio_c, "static void woal_sdiommc_unregister_dev"
)
sdio_drv_mode_quiesce = c_function(
    sdio_c, "mlan_status woal_sdio_drv_mode_quiesce"
)
sdio_drv_mode_resume = c_function(
    sdio_c, "mlan_status woal_sdio_drv_mode_resume"
)
sdio_remove = c_function(sdio_c, "void woal_sdio_remove")
sdio_reset_hw = c_function(sdio_c, "void woal_sdio_reset_hw")
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

for name, body in (
    ("module cleanup", cleanup_module),
    ("SDIO interrupt", sdio_interrupt),
    ("SDIO OOB disable-token release", sdio_oob_release_token),
    ("SDIO OOB deferred disable-token release", sdio_oob_release_work),
    ("SDIO OOB work", sdio_oob_work),
    ("SDIO OOB interrupt", sdio_oob_interrupt),
    ("SDIO OOB register", sdio_oob_register),
    ("SDIO OOB unregister", sdio_oob_unregister),
    ("SDIO OOB forced detach", sdio_oob_force_detach),
    ("SDIO function interrupt disable", sdio_func_intr_disable),
    ("SDIO OOB release", sdio_release_irq),
    ("SDIO OOB claim", sdio_claim_irq),
    ("SDIO device register", sdio_register_dev),
    ("SDIO device unregister", sdio_unregister_dev),
    ("SDIO driver-mode quiesce", sdio_drv_mode_quiesce),
    ("SDIO driver-mode resume", sdio_drv_mode_resume),
    ("SDIO remove", sdio_remove),
    ("SDIO hardware reset", sdio_reset_hw),
):
    require(bool(body), f"cannot extract {name} for lifecycle validation")

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


def sdio_irq_restores_main_state(body: str) -> bool:
    code = c_code(body)
    admitted = code.find("handle->main_state = MOAL_RECV_INT;")
    completed = code.rfind(
        "WRITE_ONCE(handle->main_state, MOAL_END_MAIN_PROCESS);"
    )
    return (admitted >= 0 and completed > admitted and
            re.search(r"\breturn\s*;", code[admitted:completed]) is None)


require(
    sdio_irq_restores_main_state(sdio_interrupt),
    "SDIO IRQ can return after admission without restoring main_state",
)
missing_irq_epilogue = sdio_interrupt.replace(
    "WRITE_ONCE(handle->main_state, MOAL_END_MAIN_PROCESS);", "", 1
)
require(
    not sdio_irq_restores_main_state(missing_irq_epilogue),
    "SDIO main_state invariant accepts a missing completion epilogue",
)
direct_suspended_return = sdio_interrupt.replace(
    "goto irq_done;", "return;", 1
)
require(
    not sdio_irq_restores_main_state(direct_suspended_return),
    "SDIO main_state invariant accepts a direct post-admission return",
)
require(
    "READ_ONCE(card->handle->main_state)" in c_code(sdio_remove),
    "SDIO remove polls main_state without an explicit concurrent snapshot",
)

cleanup_code = c_code(cleanup_module)
exit_gate_precedes_shutdown = ordered(
    cleanup_code,
    "WRITE_ONCE(driver_exit_in_progress, 1)",
    "woal_shutdown_fw(",
)
reset_gate_precedes_shutdown = ordered(
    cleanup_code,
    "woal_quiesce_reset_work(m_handle[index])",
    "woal_shutdown_fw(",
)
require(
    exit_gate_precedes_shutdown and reset_gate_precedes_shutdown,
    "cannot establish module-exit gate ordering before firmware shutdown",
)
missing_sdio_irq_definition = sdio_c.replace(
    "static void woal_sdio_interrupt", "static void removed_sdio_interrupt", 1
)
require(
    not c_function(
        missing_sdio_irq_definition, "static void woal_sdio_interrupt"
    ),
    "SDIO lifecycle extraction mutation still finds a removed IRQ definition",
)


def sdio_irq_has_transport_gate(body: str) -> bool:
    condition = if_condition_before(
        body, "spin_unlock_bh(&card->reset_lock);"
    )
    return ("!handle" in condition and
            "card->drv_mode_quiesced" in condition)


def sdio_oob_top_has_transport_gate(body: str) -> bool:
    condition = if_condition_before(body, "disable_irq_nosync(card->oob_irq)")
    return ("!READ_ONCE(card->drv_mode_quiesced)" in condition and
            "READ_ONCE(card->irq_registered)" in condition and
            "cmpxchg(&card->oob_irq_disable_owned" in condition)


def sdio_oob_work_has_stage_gates(body: str) -> bool:
    code = c_code(body)
    initial_end = code.find("mmc_card = transport_enabled")
    loop_start = code.find("for (i = 0")
    loop_end = code.find("func = NULL", loop_start)
    if min(initial_end, loop_start, loop_end) < 0:
        return False
    stages = (
        code[:initial_end],
        code[loop_start:loop_end],
    )
    return all("card->drv_mode_quiesced" in stage for stage in stages)


def sdio_oob_work_releases_disable_token(body: str) -> bool:
    code = c_code(body)
    container = code.find("card = container_of(")
    release = code.rfind("woal_sdio_oob_irq_release(card);")
    return (container >= 0 and release > container and
            re.search(r"\breturn\s*;", code[container:release]) is None)


def sdio_oob_top_defers_coalesced_release(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    return (
        ordered(
            code,
            "disable_irq_nosync(card->oob_irq)",
            "if(!queue_work(workqueue,&card->sdio_oob_irq_work))",
            "queue_work(workqueue,&card->sdio_oob_irq_release_work)",
        ) and
        "woal_sdio_oob_irq_release(card)" not in code
    )


def sdio_oob_release_work_balances_token(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    return ordered(
        code,
        "container_of(work,sdio_mmc_card,sdio_oob_irq_release_work)",
        "woal_sdio_oob_irq_release(card)",
    )


def sdio_oob_unregister_is_terminal(body: str) -> bool:
    code = c_code(body)
    return (
        ordered(
            code,
            "xchg(&card->irq_registered, MFALSE)",
            "synchronize_irq(card->oob_irq)",
            "flush_workqueue(workqueue)",
            "woal_sdio_oob_irq_release(card)",
            "sdio_claim_host(func)",
            "sdio_func_intr_disable(func)",
            "sdio_release_host(func)",
            "disable_irq_wake(card->oob_irq)",
            "devm_free_irq(",
        ) and
        "disable_irq(card->oob_irq)" not in code
    )


def sdio_func_disable_is_transactional(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    return ordered(
        code,
        "reg=sdio_f0_readb(func,SDIO_CCCR_IENx,&ret);",
        "if(ret)returnret;",
        "sdio_f0_writeb(func,reg,SDIO_CCCR_IENx,&ret);",
        "if(ret)returnret;",
        "func->irq_handler=NULL;",
        "return0;",
    )


def sdio_oob_unregister_preserves_failed_source(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    return ordered(
        code,
        "ret=sdio_func_intr_disable(func);",
        "sdio_release_host(func);",
        "if(ret){",
        "WRITE_ONCE(card->irq_registered,MTRUE);",
        "returnret;",
        "WRITE_ONCE(card->sdio_func_intr_enabled,MFALSE);",
        "devm_free_irq(",
    )


def sdio_oob_release_has_safe_fallback(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    return ordered(
        code,
        "ret=oob_sdio_irq_unregister(card);",
        "if(ret){",
        "sdio_claim_host(func);",
        "ret=sdio_disable_func(func);",
        "func->irq_handler=NULL;",
        "WRITE_ONCE(card->sdio_func_intr_enabled,MFALSE);",
        "sdio_release_host(func);",
        "ret=oob_sdio_irq_unregister(card);",
        "if(ret)returnret;",
        "destroy_workqueue(card->sdio_oob_irq_workqueue);",
    )


def sdio_oob_claim_retains_ambiguous_source(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    enable = code.find("ret=sdio_func_intr_enable(func,handler);")
    if enable < 0:
        return False
    tail = code[enable:]
    return (
        ordered(
            tail,
            "ret=sdio_func_intr_enable(func,handler);",
            "if(ret){",
            "func->irq_handler=handler;",
            "WRITE_ONCE(card->sdio_func_intr_enabled,MTRUE);",
            "returnret;",
            "WRITE_ONCE(card->sdio_func_intr_enabled,MTRUE);",
            "return0;",
        ) and
        "oob_sdio_irq_unregister(card)" not in tail and
        "destroy_workqueue(card->sdio_oob_irq_workqueue)" not in tail
    )


def sdio_oob_force_detach_drains_software_owners(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    return ordered(
        code,
        "WRITE_ONCE(card->sdio_func_intr_enabled,MFALSE);",
        "registered=xchg(&card->irq_registered,MFALSE)==MTRUE;",
        "synchronize_irq(card->oob_irq);",
        "flush_workqueue(workqueue);",
        "woal_sdio_oob_irq_release(card);",
        "sdio_claim_host(func);",
        "func->irq_handler=NULL;",
        "sdio_set_drvdata(func,NULL);",
        "sdio_release_host(func);",
        "devm_free_irq(&func->dev,card->oob_irq,card);",
        "WRITE_ONCE(card->sdio_oob_irq_workqueue,NULL);",
        "destroy_workqueue(workqueue);",
    )


def sdio_claim_error_is_released_after_host(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    claim = code.find("ret=woal_sdio_claim_irq(card,woal_sdio_interrupt);")
    if claim < 0:
        return False
    tail = code[claim:]
    return_markers = [
        (tail.find(marker), marker)
        for marker in ("returnMLAN_STATUS_FAILURE;", "return;")
        if tail.find(marker) >= 0
    ]
    if not return_markers:
        return False
    failure_return, marker = min(return_markers)
    tail = tail[:failure_return + len(marker)]
    error_check = tail.find("if(ret)")
    return (
        error_check >= 0 and
        "woal_sdio_f0_readb" not in tail[:error_check] and
        ordered(
            tail,
            "ret=woal_sdio_claim_irq(card,woal_sdio_interrupt);",
            "if(ret)",
            "sdio_release_host(func);",
            "woal_sdio_release_irq(card)",
        )
    )


def sdio_register_sets_block_size_before_irq(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    block_size = code.find(
        "ret=sdio_set_block_size(card->func,handle->sdio_blk_size);"
    )
    oob_claim = code.find(
        "ret=woal_sdio_claim_irq(card,woal_sdio_interrupt);"
    )
    inband_claim = code.find(
        "ret=sdio_claim_irq(func,woal_sdio_interrupt);"
    )
    return (
        block_size >= 0 and
        block_size < oob_claim and
        block_size < inband_claim and
        "gotorelease_irq;" not in code and
        "release_irq:" not in code
    )


def sdio_reset_sets_block_size_before_irq(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    enable = code.find("sdio_enable_func(func);")
    block_size = code.find(
        "ret=sdio_set_block_size(card->func,handle->sdio_blk_size);",
        enable,
    )
    oob_claim = code.find(
        "ret=woal_sdio_claim_irq(card,woal_sdio_interrupt);",
        enable,
    )
    inband_claim = code.find(
        "sdio_claim_irq(func,woal_sdio_interrupt);",
        enable,
    )
    if min(enable, block_size, oob_claim, inband_claim) < 0:
        return False
    setup = code[block_size:oob_claim]
    return (
        enable < block_size < oob_claim and
        block_size < inband_claim and
        ordered(
            setup,
            "ret=sdio_set_block_size(card->func,handle->sdio_blk_size);",
            "if(ret){",
            "sdio_release_host(func);",
            "return;",
        )
    )


def sdio_register_detaches_cleanup_failure(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    start = code.find("release_ret=woal_sdio_release_irq(card);")
    end = code.find("returnMLAN_STATUS_FAILURE;", start)
    if start < 0 or end < 0:
        return False
    cleanup = code[start:end + len("returnMLAN_STATUS_FAILURE;")]
    return (
        ordered(
            cleanup,
            "release_ret=woal_sdio_release_irq(card);",
            "if(release_ret){",
            "woal_sdio_force_detach_irq(card);",
            "handle->card=NULL;",
            "returnMLAN_STATUS_FAILURE;",
        ) and
        "returnMLAN_STATUS_PENDING;" not in cleanup and
        "sdio_set_drvdata(func,card);" not in cleanup
    )


def add_card_rejects_register_failure(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    return (
        ordered(
            code,
            "status=handle->ops.register_dev(handle);",
            "if(status!=MLAN_STATUS_SUCCESS)",
            "gotoerr_registerdev;",
        ) and
        "status==MLAN_STATUS_PENDING&&IS_SD(handle->card_type)" not in code and
        "QuarantineSDIOcard" not in code
    )


def sdio_unregister_detaches_after_terminal_retry(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    return ordered(
        code,
        "oob_ret=woal_sdio_release_irq(card);",
        "sdio_claim_host(card->func);",
        "disable_ret=sdio_disable_func(card->func);",
        "if(ext_intmode&&oob_ret&&!disable_ret){",
        "card->func->irq_handler=NULL;",
        "WRITE_ONCE(card->sdio_func_intr_enabled,MFALSE);",
        "sdio_release_host(card->func);",
        "oob_ret=woal_sdio_release_irq(card);",
        "if(oob_ret){",
        "woal_sdio_force_detach_irq(card);",
        "sdio_set_drvdata(card->func,NULL);",
        "card->handle=NULL;",
    )


def sdio_oob_quiesce_drains_token(body: str) -> bool:
    code = c_code(body)
    return ordered(
        code,
        "WRITE_ONCE(card->drv_mode_quiesced, true)",
        "synchronize_irq(card->oob_irq)",
        "flush_workqueue(workqueue)",
        "woal_sdio_oob_irq_release(card)",
        "sdio_claim_host(func)",
        "sdio_func_intr_disable(func)",
    )


def sdio_quiesce_reopens_failed_gate(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    return ordered(
        code,
        "sdio_func_intr_disable(func)",
        "sdio_release_host(func);",
        "if(ret){",
        "spin_lock_bh(&card->reset_lock);",
        "woal_sdio_drv_mode_can_resume(card,handle,func)",
        "WRITE_ONCE(card->drv_mode_quiesced,false);",
        "spin_unlock_bh(&card->reset_lock);",
        "returnMLAN_STATUS_FAILURE;",
    )


def sdio_source_flag_tracks_disable_result(body: str) -> bool:
    code = re.sub(r"\s+", "", c_code(body))
    return re.search(
        r"(?:ret|disable_ret)=sdio_func_intr_disable\(func\);"
        r"if\(!(?:ret|disable_ret)\)"
        r"WRITE_ONCE\(card->sdio_func_intr_enabled,MFALSE\);",
        code,
    ) is not None


def sdio_oob_resume_uses_drained_token(body: str) -> bool:
    return "enable_irq(card->oob_irq)" not in c_code(body)


def sdio_oob_gpio_mapping_is_transport_specific(body: str) -> bool:
    body = body.replace('"nxp,wifi-oob-int"', "NXP_WIFI_OOB_INT")
    code = c_code(body)
    return (
        ordered(
            code,
            "of_find_compatible_node(NULL, NULL, NXP_WIFI_OOB_INT)",
            "if (!node)",
            "return -ENODEV",
            "irq = irq_of_parse_and_map(node, 0)",
            "of_node_put(node)",
            "if (!irq)",
            "return -ENXIO",
            "card->oob_irq = irq",
            "return 0",
        )
        and code.count("NXP_WIFI_OOB_INT") == 1
        and code.count("of_find_compatible_node(") == 1
        and '"nxp,wifi-wake-host"' not in body
    )


require(
    sdio_oob_gpio_mapping_is_transport_specific(sdio_request_gpio),
    "SDIO transport IRQ lookup aliases the suspend-only wake binding",
)

for old, new, label in (
    ('node = of_find_compatible_node(NULL, NULL, "nxp,wifi-oob-int");',
     "node = NULL;", "preferred binding"),
    ("if (!irq)\n\t\treturn -ENXIO;", "", "zero IRQ rejection"),
    ("of_node_put(node);", "", "DT node release"),
):
    mutation = sdio_request_gpio.replace(old, new, 1)
    require(
        not sdio_oob_gpio_mapping_is_transport_specific(mutation),
        f"SDIO OOB GPIO invariant accepts missing {label}",
    )

wake_binding_alias = sdio_request_gpio.replace(
    'if (!node)\n\t\treturn -ENODEV;',
    'if (!node)\n\t\tnode = of_find_compatible_node(NULL, NULL, '
    '"nxp,wifi-wake-host");\n\tif (!node)\n\t\treturn -ENODEV;',
    1,
)
review_require(
    "M1",
    not sdio_oob_gpio_mapping_is_transport_specific(wake_binding_alias),
    "M1 SDIO transport invariant accepts the suspend-only wake binding",
)

unknown_binding_alias = sdio_request_gpio.replace(
    'if (!node)\n\t\treturn -ENODEV;',
    'if (!node)\n\t\tnode = of_find_compatible_node(NULL, NULL, '
    '"vendor,other-irq");\n\tif (!node)\n\t\treturn -ENODEV;',
    1,
)
review_require(
    "M3",
    not sdio_oob_gpio_mapping_is_transport_specific(unknown_binding_alias),
    "M3 SDIO transport invariant accepts an unreviewed binding alias",
)


require(
    sdio_irq_has_transport_gate(sdio_interrupt),
    "SDIO interrupt lacks the locked remove/driver-mode transport gate",
)
require(
    sdio_oob_top_has_transport_gate(sdio_oob_interrupt),
    "SDIO OOB top half lacks the live transport/registration gate",
)
require(
    sdio_oob_work_has_stage_gates(sdio_oob_work),
    "SDIO OOB work lacks an initial or per-function transport gate",
)
require(
    "int oob_irq_disable_owned;" in sdio_h,
    "SDIO OOB action lacks an explicit disable token",
)
require(
    "struct work_struct sdio_oob_irq_release_work;" in sdio_h,
    "SDIO OOB action lacks process-context disable-token release work",
)
require(
    ordered(
        c_code(sdio_oob_release_token),
        "cmpxchg(&card->oob_irq_disable_owned, MTRUE, MFALSE)",
        "enable_irq(card->oob_irq)",
    ),
    "SDIO OOB disable token is not atomically balanced",
)
require(
    sdio_oob_top_defers_coalesced_release(sdio_oob_interrupt),
    "SDIO OOB top half releases a coalesced token in hard-IRQ context",
)
require(
    sdio_oob_release_work_balances_token(sdio_oob_release_work),
    "SDIO OOB deferred release work does not balance the disable token",
)
require(
    "MLAN_INIT_WORK(&card->sdio_oob_irq_release_work," in
    c_code(sdio_claim_irq),
    "SDIO OOB deferred release work is not initialized before IRQ exposure",
)
require(
    sdio_oob_work_releases_disable_token(sdio_oob_work),
    "SDIO OOB work does not release its disable token on every exit",
)
require(
    sdio_oob_unregister_is_terminal(sdio_oob_unregister),
    "SDIO OOB unregister does not drain before source disable and action free",
)
require(
    sdio_func_disable_is_transactional(sdio_func_intr_disable),
    "SDIO function callback is cleared before CCCR source disable succeeds",
)
require(
    sdio_oob_unregister_preserves_failed_source(sdio_oob_unregister),
    "SDIO OOB unregister frees the action after source-disable failure",
)
require(
    ordered(
        c_code(sdio_release_irq),
        "oob_sdio_irq_unregister(card)",
        "destroy_workqueue(card->sdio_oob_irq_workqueue)",
    ),
    "SDIO OOB release destroys its workqueue before terminal unregister",
)
require(
    sdio_oob_release_has_safe_fallback(sdio_release_irq),
    "SDIO OOB release lacks a whole-function fallback before action teardown",
)
require(
    "IRQF_TRIGGER_LOW | IRQF_SHARED" in c_code(sdio_oob_register),
    "SDIO OOB action is not constrained to retriggerable level-low delivery",
)
require(
    ordered(
        re.sub(r"\s+", "", c_code(sdio_claim_irq)),
        "ret=oob_sdio_irq_register(card);",
        "ret=sdio_func_intr_enable(func,handler);",
        "WRITE_ONCE(card->sdio_func_intr_enabled,MTRUE);",
    ),
    "SDIO OOB claim exposes the function source before its IRQ action",
)
require(
    sdio_oob_claim_retains_ambiguous_source(sdio_claim_irq),
    "SDIO OOB claim frees an action after ambiguous source-enable failure",
)
require(
    sdio_oob_force_detach_drains_software_owners(sdio_oob_force_detach),
    "SDIO OOB forced detach can leave an IRQ action or workqueue owner live",
)
require(
    sdio_claim_error_is_released_after_host(sdio_register_dev),
    "SDIO register failure does not release an ambiguous OOB source after host unlock",
)
require(
    sdio_register_sets_block_size_before_irq(sdio_register_dev),
    "SDIO register exposes an IRQ action before block-size setup can fail",
)
require(
    sdio_register_detaches_cleanup_failure(sdio_register_dev),
    "SDIO register cleanup can retain action/WQ owners or quarantine status",
)
require(
    add_card_rejects_register_failure(add_card),
    "add-card overloads register pending as a partially initialized SDIO owner",
)
require(
    sdio_unregister_detaches_after_terminal_retry(sdio_unregister_dev),
    "SDIO unregister can free owners after terminal OOB retry failure",
)
require(
    sdio_claim_error_is_released_after_host(sdio_reset_hw),
    "SDIO reset failure does not release an ambiguous OOB source after host unlock",
)
require(
    sdio_reset_sets_block_size_before_irq(sdio_reset_hw),
    "SDIO reset exposes an IRQ action before block-size restore can fail",
)
require(
    ordered(
        re.sub(r"\s+", "", c_code(sdio_drv_mode_resume)),
        "ret=sdio_func_intr_enable(func,woal_sdio_interrupt);",
        "if(!ret)WRITE_ONCE(card->sdio_func_intr_enabled,MTRUE);",
    ),
    "SDIO resume publishes source state without an explicit concurrent write",
)
require(
    sdio_oob_quiesce_drains_token(sdio_drv_mode_quiesce),
    "SDIO driver-mode quiesce does not drain its OOB disable token",
)
require(
    sdio_source_flag_tracks_disable_result(sdio_drv_mode_quiesce),
    "SDIO quiesce clears source state after a failed CCCR disable",
)
require(
    sdio_quiesce_reopens_failed_gate(sdio_drv_mode_quiesce),
    "SDIO quiesce leaves a live level source behind a closed gate on failure",
)
require(
    sdio_source_flag_tracks_disable_result(sdio_drv_mode_resume),
    "SDIO resume rollback clears source state after a failed CCCR disable",
)
require(
    sdio_oob_resume_uses_drained_token(sdio_drv_mode_resume),
    "SDIO driver-mode resume compensates for an undrained OOB disable token",
)

irq_gate_removed = sdio_interrupt.replace(
    " || card->drv_mode_quiesced", "", 1
)
require(
    not sdio_irq_has_transport_gate(irq_gate_removed),
    "SDIO IRQ transport-gate invariant accepts a removed live gate",
)
oob_top_gate_removed = sdio_oob_interrupt.replace(
    "!READ_ONCE(card->drv_mode_quiesced) &&", "true &&", 1
)
require(
    not sdio_oob_top_has_transport_gate(oob_top_gate_removed),
    "SDIO OOB top-half invariant accepts a removed live gate",
)
oob_gate_expression = "transport_enabled = !card->drv_mode_quiesced"
require(
    sdio_oob_work.count(oob_gate_expression) == 2,
    "SDIO OOB work gate layout changed without updating stage mutations",
)
for occurrence in range(2):
    oob_stage_gate_removed = replace_nth(
        sdio_oob_work, oob_gate_expression, "transport_enabled = true",
        occurrence,
    )
    require(
        not sdio_oob_work_has_stage_gates(oob_stage_gate_removed),
        f"SDIO OOB work invariant accepts removed stage gate {occurrence + 1}",
    )
oob_token_acquire_removed = sdio_oob_interrupt.replace(
    "cmpxchg(&card->oob_irq_disable_owned, MFALSE, MTRUE) == MFALSE",
    "true",
    1,
)
require(
    not sdio_oob_top_has_transport_gate(oob_token_acquire_removed),
    "SDIO OOB top-half invariant accepts missing disable-token ownership",
)
oob_queue_fallback_removed = sdio_oob_interrupt.replace(
    "&card->sdio_oob_irq_release_work", "&card->sdio_oob_irq_work", 1
)
require(
    not sdio_oob_top_defers_coalesced_release(oob_queue_fallback_removed),
    "SDIO OOB top-half invariant accepts missing deferred coalescing release",
)
oob_token_release_removed = sdio_oob_work.replace(
    "woal_sdio_oob_irq_release(card);", "", 1
)
require(
    not sdio_oob_work_releases_disable_token(oob_token_release_removed),
    "SDIO OOB work invariant accepts a missing token-release epilogue",
)
for marker in (
    "synchronize_irq(card->oob_irq);",
    "flush_workqueue(workqueue);",
    "woal_sdio_oob_irq_release(card);",
):
    unregister_drain_removed = sdio_oob_unregister.replace(marker, "", 1)
    require(
        not sdio_oob_unregister_is_terminal(unregister_drain_removed),
        f"SDIO OOB unregister invariant accepts missing {marker[:-1]}",
    )
unregister_failure_return_removed = sdio_oob_unregister.replace(
    "return ret;", "", 1
)
require(
    not sdio_oob_unregister_preserves_failed_source(
        unregister_failure_return_removed
    ),
    "SDIO OOB unregister invariant accepts teardown after disable failure",
)
func_disable_early_clear = sdio_func_intr_disable.replace(
    "func->irq_handler = NULL;", "", 1
).replace(
    "reg = sdio_f0_readb(func, SDIO_CCCR_IENx, &ret);",
    "func->irq_handler = NULL;\n\treg = sdio_f0_readb(func, SDIO_CCCR_IENx, &ret);",
    1,
)
require(
    not sdio_func_disable_is_transactional(func_disable_early_clear),
    "SDIO source-disable invariant accepts an early callback clear",
)
oob_edge_trigger = sdio_oob_register.replace(
    "IRQF_TRIGGER_LOW", "IRQF_TRIGGER_RISING", 1
)
require(
    "IRQF_TRIGGER_LOW | IRQF_SHARED" not in c_code(oob_edge_trigger),
    "SDIO OOB trigger invariant accepts edge-triggered delivery",
)
claim_ambiguous_state_removed = sdio_claim_irq.replace(
    "func->irq_handler = handler;", "", 1
)
require(
    not sdio_oob_claim_retains_ambiguous_source(
        claim_ambiguous_state_removed
    ),
    "SDIO OOB claim invariant accepts missing ambiguous-source callback",
)
force_detach_action_removed = sdio_oob_force_detach.replace(
    "devm_free_irq(&func->dev, card->oob_irq, card);", "", 1
)
require(
    not sdio_oob_force_detach_drains_software_owners(
        force_detach_action_removed
    ),
    "SDIO forced-detach invariant accepts a retained IRQ action",
)
force_detach_host_barrier_removed = sdio_oob_force_detach.replace(
    "sdio_claim_host(func);", "", 1
)
require(
    not sdio_oob_force_detach_drains_software_owners(
        force_detach_host_barrier_removed
    ),
    "SDIO forced-detach invariant accepts an unlocked cross-function callback clear",
)
register_claim_cleanup_removed = sdio_register_dev.replace(
    "release_ret = woal_sdio_release_irq(card);", "release_ret = 0;", 1
)
require(
    not sdio_claim_error_is_released_after_host(
        register_claim_cleanup_removed
    ),
    "SDIO register invariant accepts missing ambiguous-source cleanup",
)
register_block_size_removed = sdio_register_dev.replace(
    "ret = sdio_set_block_size(card->func, handle->sdio_blk_size);", "", 1
)
require(
    not sdio_register_sets_block_size_before_irq(register_block_size_removed),
    "SDIO register invariant accepts missing pre-IRQ block-size setup",
)
register_force_detach_removed = sdio_register_dev.replace(
    "woal_sdio_force_detach_irq(card);", "", 1
)
require(
    not sdio_register_detaches_cleanup_failure(
        register_force_detach_removed
    ),
    "SDIO register invariant accepts a retained action after cleanup failure",
)
add_card_register_unwind_removed = add_card.replace(
    "goto err_registerdev;", "", 1
)
require(
    not add_card_rejects_register_failure(
        add_card_register_unwind_removed
    ),
    "add-card invariant accepts a register failure without normal unwind",
)
unregister_force_detach_removed = sdio_unregister_dev.replace(
    "woal_sdio_force_detach_irq(card);", "", 1
)
require(
    not sdio_unregister_detaches_after_terminal_retry(
        unregister_force_detach_removed
    ),
    "SDIO unregister invariant accepts owner free after retry failure",
)
reset_claim_cleanup_removed = sdio_reset_hw.replace(
    "(void)woal_sdio_release_irq(card);", "", 1
)
require(
    not sdio_claim_error_is_released_after_host(reset_claim_cleanup_removed),
    "SDIO reset invariant accepts missing ambiguous-source cleanup",
)
reset_block_size_removed = sdio_reset_hw.replace(
    "ret = sdio_set_block_size(card->func, handle->sdio_blk_size);", "", 1
)
require(
    not sdio_reset_sets_block_size_before_irq(reset_block_size_removed),
    "SDIO reset invariant accepts missing pre-IRQ block-size restore",
)
quiesce_token_drain_removed = sdio_drv_mode_quiesce.replace(
    "woal_sdio_oob_irq_release(card);", "", 1
)
require(
    not sdio_oob_quiesce_drains_token(quiesce_token_drain_removed),
    "SDIO quiesce invariant accepts a missing disable-token drain",
)
quiesce_failed_gate_reopen_removed = sdio_drv_mode_quiesce.replace(
    "WRITE_ONCE(card->drv_mode_quiesced, false);", "", 1
)
require(
    not sdio_quiesce_reopens_failed_gate(quiesce_failed_gate_reopen_removed),
    "SDIO quiesce invariant accepts a live source behind a closed gate",
)
quiesce_unconditional_source_clear = sdio_drv_mode_quiesce.replace(
    "if (!ret)\n\t\t\t\tWRITE_ONCE(card->sdio_func_intr_enabled, MFALSE);",
    "WRITE_ONCE(card->sdio_func_intr_enabled, MFALSE);",
    1,
)
require(
    not sdio_source_flag_tracks_disable_result(
        quiesce_unconditional_source_clear
    ),
    "SDIO source-state invariant accepts an unconditional quiesce clear",
)
resume_with_global_enable = sdio_drv_mode_resume.replace(
    "sdio_release_host(func);",
    "sdio_release_host(func);\n\tenable_irq(card->oob_irq);",
    1,
)
require(
    not sdio_oob_resume_uses_drained_token(resume_with_global_enable),
    "SDIO resume invariant accepts global IRQ compensation",
)
comment_only_irq_gate = irq_gate_removed.replace(
    "if (!handle)", "if (!handle /* card->drv_mode_quiesced */)", 1
)
require(
    not sdio_irq_has_transport_gate(comment_only_irq_gate),
    "SDIO IRQ transport-gate invariant accepts a comment-only gate",
)
require(
    not (
        (exit_gate_precedes_shutdown and
         "driver_exit_in_progress" in sdio_interrupt) or
        (reset_gate_precedes_shutdown and
         "reset_stopping" in sdio_interrupt)
    ),
    "SDIO command-response IRQ is gated before module-exit firmware shutdown",
)
require(
    all(
        not (
            (exit_gate_precedes_shutdown and
             "driver_exit_in_progress" in body) or
            (reset_gate_precedes_shutdown and
             "reset_stopping" in body)
        )
        for body in (sdio_oob_work, sdio_oob_interrupt)
    ),
    "SDIO OOB command-response path is gated before firmware shutdown",
)
require(
    ordered(
        sdio_remove,
        "spin_lock_bh(&card->reset_lock)",
        "WRITE_ONCE(card->drv_mode_quiesced, true)",
        "card->reset_stopping = true",
        "spin_unlock_bh(&card->reset_lock)",
        "cancel_work_sync(&card->reset_work)",
        "card->handle->surprise_removed = MTRUE",
        "sdio_claim_host(func)",
        "sdio_release_host(func)",
    ),
    "SDIO remove does not close and synchronize the transport IRQ gate",
)

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

radio_antcfg = c_function(mlan_misc_c,
                          "mlan_status wlan_radio_ioctl_ant_cfg")
rf_ant_cmd = c_function(mlan_cmdevt_c,
                        "mlan_status wlan_cmd_802_11_rf_antenna")
rf_ant_resp = c_function(mlan_cmdevt_c,
                         "mlan_status wlan_ret_802_11_rf_antenna")
vht_assoc_cap = c_function(mlan_11ac_c, "int wlan_cmd_append_11ac_tlv")
he_assoc_cap = c_function(mlan_11ax_c, "int wlan_cmd_append_11ax_tlv")
require("user_htstream_before" in radio_antcfg and
        "ANTCFG_DIAG request" in radio_antcfg and
        all(field in radio_antcfg for field in
            ("ant_cfg->tx_antenna", "ant_cfg->rx_antenna")),
        "antcfg host request lacks requested masks and user_htstream before/after evidence")
require("ANTCFG_DIAG hostcmd" in rf_ant_cmd and
        all(field in rf_ant_cmd for field in
            ("pantenna->action_tx", "pantenna->tx_antenna_mode",
             "pantenna->action_rx", "pantenna->rx_antenna_mode",
             "cmd->size")),
        "RF_ANTENNA HostCmd serialization lacks action/mask/size evidence")
require("user_htstream_before" in rf_ant_resp and
        "ANTCFG_DIAG response" in rf_ant_resp and
        "pmadapter->user_htstream" in rf_ant_resp,
        "RF_ANTENNA response lacks physical masks and user_htstream before/after evidence")
require("ASSOC_NSS_DIAG vht" in vht_assoc_cap and
        all(field in vht_assoc_cap for field in
            ("rx_nss", "tx_nss", "rx_mcs_map", "tx_mcs_map",
             "user_htstream")),
        "association VHT capability lacks final Tx/Rx NSS-map evidence")
require("ASSOC_NSS_DIAG he" in he_assoc_cap and
        all(field in he_assoc_cap for field in
            ("advertised_rx_nss", "advertised_tx_nss", "rx_mcs_80",
             "tx_mcs_80", "user_htstream")),
        "association HE capability lacks final Tx/Rx NSS-map evidence")

scan_snapshot = c_function(main_c, "void woal_scan_diag_snapshot")
cfg_scan = c_function(sta_cfg80211_c, "static int woal_cfg80211_scan")
scan_done = c_function(main_c,
                       "static void woal_send_cfg_bss_scan_result")
scan_post = c_function(main_c,
                       "static void woal_scan_diag_post_handler")
remove_interface = c_function(main_c, "void woal_remove_interface")
scan_rate_query = c_function(main_c,
                             "static mlan_status woal_scan_diag_get_data_rate")
scan_ant_query = c_function(main_c,
                            "static mlan_status woal_scan_diag_get_antcfg")
txpd_build = c_function(mlan_sta_tx_c,
                        "t_void *wlan_ops_sta_process_txpd")
mlan_recv_event = c_function(mlan_cmdevt_c,
                             "mlan_status wlan_recv_event")
scan_report_case = shim_c[shim_c.find(
    "case MLAN_EVENT_ID_DRV_SCAN_REPORT:") :]
scan_report_case = scan_report_case[:scan_report_case.find("\n\tcase ", 1)]
require("t_u32 scan_diag_id;" in main_h and
        "t_u8 scan_diag_home_chan;" in main_h,
        "MOAL handle lacks correlated scan diagnostic id/home-channel state")
require(ordered(scan_snapshot, "drvdbg & MCMND", "woal_get_debug_info(") and
        all(field in scan_snapshot for field in
            ("atomic_read(&handle->tx_pending)", "wmm_tx_pending",
             "netif_queue_stopped", "info->wmm_ac_bk", "info->wmm_ac_be",
             "info->wmm_ac_vi", "info->wmm_ac_vo", "info->ps_state",
             "info->tx_lock_flag", "info->pm_wakeup_card_req",
             "info->pm_wakeup_fw_try", "info->scan_processing",
             "info->scan_state", "woal_get_sta_channel(",
             "SCAN_WEDGE_DIAG")),
        "scan diagnostic snapshot lacks requested MOAL/MLAN queue, power, wake, or channel evidence")
require("mlan_debug_info info;" not in scan_snapshot and
        "kzalloc(sizeof(*info), GFP_KERNEL)" in scan_snapshot and
        "kfree(info);" in scan_snapshot,
        "scan diagnostic snapshot puts the large MLAN debug structure on the kernel stack")
require(all(field in scan_snapshot for field in
            ("woal_get_stats_info(", "FW_TX_COUNTER_DIAG",
             "failed_delta", "ack_failure_delta", "TX_RATE_DIAG",
             "RF_CHANNEL_DIAG", "num_tx_host_to_card_failure",
             "tx_stat_queue_size", "fw_tx_status_failure")) and
        "kzalloc(sizeof(*stats), GFP_KERNEL)" in scan_snapshot and
        "kfree(stats);" in scan_snapshot,
        "post-scan diagnostics lack FW ACK/failure counters, rate/NSS, RF/channel, or host completion evidence")
require("MLAN_OID_GET_DATA_RATE" in scan_rate_query and
        "MLAN_IOCTL_RATE" in scan_rate_query and
        "MLAN_OID_ANT_CFG" in scan_ant_query and
        "MLAN_IOCTL_RADIO_CFG" in scan_ant_query,
        "scan diagnostics do not query FW rate/NSS and physical antenna state")
require(ordered(cfg_scan, "scan_diag_id++", "scan_diag_home_chan",
                "scan_diag_stats_base_valid = MFALSE",
                'woal_scan_diag_snapshot(priv, "PRE_SCAN", MTRUE, MFALSE)',
                "woal_do_scan(",
                'woal_scan_diag_snapshot(priv, "START", MFALSE, MFALSE)') ,
        "cfg80211 scan does not capture a true pre-submit FW baseline and a non-blocking START boundary")
require(ordered(scan_report_case,
                'woal_scan_diag_snapshot(priv, "FW_COMPLETE", MFALSE,',
                "MFALSE);"),
        "FW scan-report boundary lacks a correlated diagnostic snapshot")
require(ordered(scan_done,
                'woal_scan_diag_snapshot(priv, "CFG80211_DONE", MTRUE, MTRUE)',
                "scan_diag_post_work",
                "woal_cfg80211_scan_done("),
        "cfg80211 completion lacks final and delayed post-scan Tx-path snapshots")
require("POST_SCAN_1S" in scan_post and
        "scan_diag_post_id" in scan_post and
        "scan_diag_post_work" in main_h,
        "one-second post-scan counter/rate/RF sampling is not lifecycle-owned by MOAL")
require(ordered(remove_interface, "scan_diag_post_priv",
                "cancel_delayed_work_sync(&handle->scan_diag_post_work)",
                "free_netdev(dev)") ,
        "interface teardown can free the delayed scan diagnostic private context")
require(all(field in mlan_main_internal_h for field in
            ("scan_diag_seq", "scan_diag_txpd_budget")) and
        all(field in mlan_recv_event for field in
            ("MLAN_EVENT_ID_DRV_SCAN_REPORT", "mlan_drvdbg & MCMND",
             "scan_diag_txpd_budget")) and
        all(field in txpd_build for field in
            ("TXPD_DIAG", "scan_diag_txpd_budget", "tx_control",
             "tx_control_1", "user_htstream", "tx_rate_info",
             "curr_bss_params.bss_descriptor.channel")),
        "bounded next-packet TxPD/rate/NSS evidence is not armed at FW scan completion")
require(all(field in main_h for field in
            ("fw_tx_status_success", "fw_tx_status_failure",
             "fw_tx_status_watchdog", "fw_tx_status_unknown")) and
        "FW_TX_STATUS_DIAG" in shim_c and
        all(field in shim_c for field in
            ("atomic_inc(&priv->phandle->fw_tx_status_success)",
             "atomic_inc(&priv->phandle->fw_tx_status_failure)",
             "atomic_inc(&priv->phandle->fw_tx_status_watchdog)")),
        "FW-reported explicit Tx status reasons are not counted and correlated")

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
