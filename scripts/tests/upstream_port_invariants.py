#!/usr/bin/env python3
"""Source-level lifecycle/ABI invariants for the mwifiex 0396 port."""

from pathlib import Path
import os
import re
import subprocess
import sys


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
cfg80211_util_c = read("mlinux/moal_cfg80211_util.c")
cfg80211_util_h = read("mlinux/moal_cfg80211_util.h")
pcie_c = read("mlinux/moal_pcie.c")
sdio_h = read("mlinux/moal_sdio.h")
sdio_c = read("mlinux/moal_sdio_mmc.c")
sdio_request_gpio = c_function(sdio_c, "static int woal_request_gpio")
mlan_misc_c = read("mlan/mlan_misc.c")
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
passphrase_ioctl = c_function(
    eth_ioctl_c, "static int woal_setget_priv_passphrase"
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
        and "BLOCKED_BY_PREREQUISITE" in design
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
            "historical source `734f75bf02a3e5ac4c84a696d8a873ed11247ce3`인 "
            "과거 target slice",
            "corrected current source `e1c9f49`는 target에 stage하지 않았다",
            "corrected `e1c9f49` artifact는 target에 전송하지 않았다",
            "historical `734f75b` i.MX93 SD9098 load/version/ping PASS; "
            "corrected `e1c9f49`는 host-only",
            "historical `734f75b` i.MX93 SDIO in-band reload만 bounded slice에서 통과",
            "candidate activation FAIL at the invalid binding alias; corrected "
            "OOB runtime BLOCKED_BY_PLATFORM_PREREQUISITE because the target "
            "lacks `nxp,wifi-oob-int`",
            "invalid-alias candidate activation FAIL, corrected OOB runtime "
            "BLOCKED_BY_PLATFORM_PREREQUISITE",
        )
    ) and all(
        phrase in design_norm
        for phrase in (
            "Candidate activation failed before the runtime health gate",
            "| Candidate activation | FAIL — repeated transport configuration "
            "timeout and firmware init failure |",
            "final matching active timer count is zero",
            "corrected source `e1c9f49bb6ec8ffd0dc9703909ff4ef823a76436`",
            "**Status:** Executed — invalid binding alias corrected; target OOB "
            "blocked by missing transport binding.",
            "corrected OOB runtime remains blocked because the required "
            "transport binding is absent",
        )
    )
    forbidden = (
        r"(?:corrected(?: current source)?\s+)?`?e1c9f49`?"
        r"[^|.;]{0,120}\b(?:runtime|load/version/ping)\b"
        r"[^|.;]{0,80}\bPASS\b",
        r"\bcorrected\b[^|.;]{0,180}\bPASS\b",
        r"\be1c9f49[0-9a-f]*\b[^|.;]{0,180}\bPASS\b",
        r"\bcurrent (?:HEAD|source)\b[^|.;]{0,180}\bPASS\b",
        r"(?:matching )?active[- ]timer count(?:는| is)? "
        r"(?:[1-9][0-9]*|nonzero)",
        r"Candidate activation(?:\s*\|)?\s*\*{0,2}PASS\*{0,2}",
        r"corrected OOB runtime\s+\*{0,2}PASS\*{0,2}",
        r"artifact equality (?!5/5\b)[0-9]+/[0-9]+",
        r"required service (?!6/6\b)[0-9]+/[0-9]+",
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
    "corrected OOB runtime BLOCKED_BY_PLATFORM_PREREQUISITE",
    "corrected OOB runtime PASS",
)
review_require(
    "M4",
    not qualification_outcome_is_scoped(
        m4_corrected_runtime_pass, watch_design_doc
    ),
    "M4 outcome invariant accepts corrected target runtime PASS",
)
m4_design_runtime_pass = watch_design_doc.replace(
    "corrected OOB\nruntime remains blocked because the required transport "
    "binding is absent",
    "corrected OOB runtime PASS",
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
