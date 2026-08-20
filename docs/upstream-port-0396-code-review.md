# mwifiex 0396cfb→2e481212 Clean Port 코드 검토 및 잔여 위험

## 판정 범위와 근거

이 문서는 `/tmp/wlan-driver-v2-port-0396-clean-20260820`에서 Task 6가
검토한 결과이다. 검토 시작 HEAD는
`e48323b9219cf09d125de761aa073129e1174b3d`이고, 이 문서만 후속으로
추가한다. 따라서 아래의 코드 판정은 문서 커밋 전 HEAD를 기준으로 한다.

| 항목 | 고정 값 |
|---|---|
| local integration parent | `main` = `ce179fcc8a82f4ce41e70ffadc65c966a7a1565d` |
| upstream base | `0396cfb38ad73a3d587cd0f8c139b47801e70891` |
| upstream tip | `upstream/lf-6.18.20_2.0.0` = `2e481212d262758cbd4d0fc7ea95a2ad5f704bc3` |
| upstream 범위 | `0396cfb38ad73a3d587cd0f8c139b47801e70891..2e481212d262758cbd4d0fc7ea95a2ad5f704bc3`, 40 commits |
| clean merge | `cc7f79de3c58073eb0780d4dd56c1cffe56ee161` |
| build-goal repair | `e48323b9219cf09d125de761aa073129e1174b3d` |

통합은 `cc7f79d`의 non-fast-forward merge 하나로 수행되었다. 첫 번째 부모는
`ce179fcc8a82f4ce41e70ffadc65c966a7a1565d`, 두 번째 부모는 정확한 upstream
`2e481212d262758cbd4d0fc7ea95a2ad5f704bc3`이다. 따라서 release snapshot을
다시 cherry-pick하지 않고 양쪽 history를 보존한다. `git merge-base --is-ancestor
2e481212d262758cbd4d0fc7ea95a2ad5f704bc3 HEAD`의 exit 0이 이 topology를
확인한다.

오래된 `port/upstream-61820-0396`의 `7a56d1f`는 통합 입력으로 거부했다. 해당
branch는 vendor replay가 39회, 11회, 34회 누적되어 p8의 `d5dfe540` UAP
channel-switch helper를 중복 문맥에 재적용하고 p18의 `b8c868b7` SNMP/AGCS/
channel-switch block을 손상시켰다. 직접 증거는 `moal_eth_ioctl.c`의 이중 AGCS
function set, `mlan_uap_ioctl.c`의 중복 `wlan_uap_chan_switch_cnt_cfg`, 그리고
`moal_proc.c`의 preprocessor depth `0 -> -2 -> -4`이다. 즉, `7a56d1f`의 파일을
통째로 택하는 것은 compile failure 또는 잘못된 firmware command를 재도입하는
고위험 선택이며, forensic evidence로만 보존한다.

## Upstream coverage

감사는 stable patch-id, range-diff pairing, final file/tree identity, 및 두
손상 commit에 대한 function-level residual diff를 함께 사용했다.

- **exact-equivalent 25개:** `58368fe6`, `3383eb3e`, `0ea4f2ff`, `bc7387bf`,
  `2da89e4c`, `91d2e896`, `038a3079`, `7d13b9dc`, `f97f966e`, `60f40a22`,
  `cd6b82e5`, `166182fd`, `fe5016be`, `87d7b501`, `7b05b576`, `eadd45ba`,
  `b08958dc`, `e9b6c82a`, `dd4c01c5`, `da884137`, `07da5c79`, `94f77173`,
  `031aa9bb`, `6c8ee594`, `c29c64d` (build-hygiene prefix).
- **rewritten-equivalent 10개:** `e207c169`, `32e32105`, `eecc5871`,
  `1e8b968f`, `a2501625`, `6818dd8c`, `65b03488`, `371a047a`, `e753dc75`,
  `8cc07f8` (build-hygiene prefix). 이들은 release snapshot 재작성 때문에
  patch-id가 아닌 range-diff로 짝지었다.
- **old branch에서 replay-corrupted/non-equivalent 2개:** `d5dfe540`와
  `b8c868b7`. clean merge에서는 둘 다 정확한 upstream commit의 ancestor이며,
  최종 고위험-definition audit는 UAP channel-track/AGCS/channel-switch helper를
  각각 하나씩만 확인했다.
- **scope-adjacent 3개:** merge, README-only, SBOM-only commit은 direct/build
  hygiene 37개 밖이지만, clean merge의 ancestry/tree에 포함된다. 이들은 core
  function port의 대체 근거가 아니라 40-commit scope 보존의 근거다.

## 최종 HEAD에 남긴 코드 수준의 조정

### UAP/AGCS와 ioctl ABI

`mlan_uap_ioctl.c`의 final audit는 `HostCmd_CMD_802_11_SNMP_MIB` +
`ChanTrackParam_i` + `mib->param.chan_track`, `HostCmd_CMD_APCMD_AGCS_CFG` +
`misc->param.agcs_cfg`, `HostCmd_CMD_APCMD_CHAN_SWITCH_CNT_CFG` +
`misc->param.ecsa_cfg`의 한 정의씩을 확인했다. `mlinux/moal_eth_ioctl.c`에는
AGCS function set 하나만 남긴다. 이것이 old replay의 duplicate/redefinition 및
wrong-command 위험을 제거한 부분이다.

`mlan/mlan_ioctl.h:1551-1559`와 byte-identical mirror
`mlinux/mlan_ioctl.h:1551-1559`는 upstream의 6 GHz `tx_antenna_6g`/
`rx_antenna_6g` 뒤에 local `user_htstream`을 저장한다. 그러나 userspace ABI의
`antcfg` 응답은 upstream의 Tx/Rx/6 GHz Tx/6 GHz Rx 의미를 그대로 둔다.
`mlan/mlan_cmdevt.c:8560`의 `wlan_ret_802_11_rf_antenna()`는 SET 응답에서만
`user_htstream`을 갱신해 GET이 NSS intent를 되쓰지 못하게 하고, `user_htstream`은
응답 struct에 채운다. `mlinux/moal_eth_ioctl.c:15481`의
`woal_priv_get_antcfg_nss()`와 `mlinux/moal_eth_ioctl.h:241`의 `antcfgnss`는
정확히 한 `t_u32`을 GET-only로 반환하며, dispatcher는 `antcfg`보다 먼저
매칭한다. `mapp/mlanutl/mlanutl.c`는 plain `antcfg`의 upstream field를 표시한 뒤
별도 NSS query를 수행한다.

### VHT NSS, HE power, ratebitmap

`mlan/mlan_11ac.c:175`의 `wlan_11ac_ioctl_vhtcfg()`는 저장된 VHT map을
`user_htstream`에서 다시 clamp하지 않는다. 실제 association IE의 clamp는
`wlan_fill_vht_cap_tlv()`/`wlan_cmd_append_11ac_tlv()`에 남아 있으므로, advertised
NSS 정책은 유지하면서 `vhtcfg` SET/GET round-trip만 안정화한다.

HE power는 `mlan/mlan_sta_ioctl.c:1777`의
`wlan_power_ioctl_set_power_ext()`가 `MLAN_RATE_FORMAT_HE`를
`MOD_CLASS_HE`로 encode하고, `mlan/mlan_sta_cmdresp.c:1014`의
`wlan_ret_tx_power_cfg()`가 HE response를 decode한다. 같은 response에는
firmware `mode`가 보존되고, host lower bound는 0으로 정규화한다.
`mlinux/moal_eth_ioctl.c:7295`의 `woal_priv_txpowercfg()`는 selector 9–14를
HE 20/40/80 MHz 및 NSS 1/2로 매핑한다.

`mlinux/moal_eth_ioctl.c:2535`의 `woal_setget_priv_ratebitmapcfg()`는
`MAX_BITMAP_RATES_SIZE` 26개 (DSSS, OFDM, HT 8, VHT 8, HE 8)를 GET/SET하며,
`mlinux/moal_eth_ioctl.h:78`의 `ratebitmapcfg`와 Android private-command dispatch
(`moal_eth_ioctl.c:22698`)가 kernel/userspace 쌍을 완성한다.

### management metadata/logging

`mlan/mlan_misc.c:3398`의 `wlan_process_802dot11_mgmt_pkt()`는 event prefix를
`[band, channel, snr, nf]`로 네 byte에 기록하고, management payload는 그 뒤에
둔다. `mlinux/moal_shim.c:3840`의 `moal_recv_event()`는 SNR/NF를 먼저 읽은 뒤
upstream band/channel frequency 계산, addr4 removal, host-MLME/cfg80211 delivery를
유지한다. `mlinux/moal_proc.c:83`의 `mgmt_log_printf()`와
`:133`의 `mgmt_dump_append_ies()`가 ring/dump stack을 제공하며,
`moal_cfg80211.c:2856`, `:2924`, `:3495` 및
`moal_sta_cfg80211.c:3202`, `:4060`, `:6148`, `:7034`, `:7100`가
registration 및 TX logging을 완전한 stack으로 연결한다. 활성 raw JHW
진단은 모두 `#ifdef JHW_TEST`에 있다.

### bridge lifecycle/recovery와 transports

`mlinux/moal_bridge.c`는 parked source가 아니라 `Makefile:551`의
`mlinux/moal_bridge.o`로 build된다. `moal_bridge_rx_fast()` (`:811`),
`moal_bridge_tx_hairpin()` (`:995`), `moal_bridge_init()` (`:2353`),
`moal_bridge_deinit()` (`:2373`), owner suspend/resume (`:2455-2522`), pending
switch cleanup (`:2692-2710`), `moal_bridge_switch_iface()` (`:3043`)가 한
lifecycle을 이룬다. `moal_main.c:15886`의 `woal_switch_drv_mode()`,
`:16176`/`:16241`의 reset pre/post hooks, `:16471`의
`woal_request_fw_reload()`와 그 호출자는 bridge ownership을 recovery ordering에
맞춘다. PCIe에서는 `moal_pcie.c:1163`/`:1257` reset callbacks, SDIO에서는
`moal_sdio_mmc.c:3390`, `:3554`, `:3813` reset/FLR paths가 이 policy를 따른다.

USB는 `moal_usb.c:611`의 `woal_usb_unlink_urb()`에서 pending counter 대신
`usb_kill_urb()` completion barrier를 사용하고, `:1184` disconnect에서
`woal_kill_urbs()`와 `woal_cancel_hang_work()`를 removal 전에 수행한다.
`woal_resubmit_urbs()` (`:1244`)는 `mlan_status`를 반환하여 partial RX submit을
실패로 만들고 cleanup하며, header `moal_usb.h:279`도 같은 prototype이다.
suspend 또는 removal이면 `woal_write_data_async()`가 producer를 차단한다.

### build default goal

`Makefile:118`은 direct invocation에서만 `.DEFAULT_GOAL := default`를
선택한다. 이는 `bridge-fault-guard-check`가 implicit goal이 되어 `.ko`가 전혀
생기지 않던 문제를 고치되, Kbuild submake에 존재하지 않는 `default` goal을
전파하지 않는다. `Makefile:122`의 static bridge audit 및 default-off
`CONFIG_BRIDGE_SWITCH_FAULT_INJECT`/`CONFIG_JHW_TEST`는 QA 기능을 production
build와 분리한다.

## Side-effect matrix

| Subsystem | 파일/함수 | old failure mode | clean-port policy | residual risk/severity | 정확한 target validation |
|---|---|---|---|---|---|
| UAP SNMP/AGCS | `mlan_uap_ioctl.c`, `wlan_uap_chan_track_cfg()`, `wlan_uap_agcs_cfg()`, `wlan_uap_chan_switch_cnt_cfg()`; `moal_eth_ioctl.c` | duplicate definition, undeclared `misc`, wrong AGCS command | upstream 세 helper semantics 하나만 유지 | firmware command/selector 실기기 미확인 — High | channel-track GET/SET, AGCS GET/SET, channel-switch count 및 firmware command trace |
| management/proc | `mlan_misc.c:3398`, `moal_shim.c:3840`, `moal_proc.c:83`, cfg80211 call sites | unmatched `#endif`, absent ring fields/macros, read/unload race | ring, proc init/exit, registration, dump consumer를 atomic stack으로 유지 | concurrent unload/read — High | `CONFIG_PROC_FS` matrix, ring wrap/clear, host-MLME/P2P mask, concurrent unload/read |
| USB URB | `moal_usb.c:611,1184,1244`; `moal_usb.h:279` | callback after pending=0, UAF/leak/RX stall, declaration mismatch | kill barrier + cancel hang work + status-returning resubmit를 함께 유지 | unplug/suspend race — High | unplug/unload, suspend traffic, resubmit fault, pending counters, KASAN |
| bridge | `moal_bridge.c`, `moal_bridge.h`, `moal_main.c`, `moal_shim.c` | object/hooks 누락으로 silent feature loss 또는 partial-field build failure | object, params, RX/TX, PM/reset, init/exit를 단일 stack으로 유지 | runtime ownership/locking — High | runtime switch, DBDC, delete, traffic, KASAN, lockdep |
| PCIe/SDIO recovery | `moal_pcie.c:1163,1257`; `moal_sdio_mmc.c:3390,3554,3813` | bridge owner restore/serialization 누락 | upstream ordering 위에 bridge suspend/resume wrapper 유지 | destructive reset concurrent with unload — High | PCIe FLR/AER/in-band reset 및 SDIO reset을 suspend/unload와 동시 실행 |
| ratebitmap | `moal_eth_ioctl.c:2535,22698`; `mlanutl.c` | utility command와 kernel dispatcher 분리, GET/SET mismatch | 26-word private-command pair 유지 | firmware rate persistence — Medium | 26-word GET/SET, HT/VHT/HE `ratemax`, reconnect persistence |
| VHT NSS/antcfg | `mlan_11ac.c:175`; `mlan_cmdevt.c:8560`; mirrored headers; `antcfgnss` | GET가 NSS intent를 덮거나 upstream 6 GHz ABI slot 충돌 | `antcfg` upstream ABI + separate `antcfgnss`, SET-only intent update | association/reboot convergence — High | 2.4/5/6 GHz `antcfg` SET/GET, repeated GET, `vhtcfg` round-trip, assoc IE, roam/reboot |
| HE Tx power | `mlan_sta_ioctl.c:1777`; `mlan_sta_cmdresp.c:1014`; `moal_eth_ioctl.c:7295` | groups 9–14 reject 또는 asymmetric SET/GET | selector, encoding, response, utility decoding을 함께 유지 | firmware power-table variance — High | groups 0–14, HE 20/40/80, NSS1/2, low-dBm, reconnect |
| management diagnostics | `moal_cfg80211.c`, `moal_sta_cfg80211.c`, `moal_proc.c` | missing metadata/log stack 또는 production log noise | upstream delivery를 유지하고 local log/dump는 `net_rx`/`mgmt_hex_dump`로 gate | volume/PII-like frame exposure — Medium | management dump wrap, production `drvdbg`/ioctl log-volume 확인 |
| build metadata | `Makefile:118,122,551` | static QA만 실행되어 modules 미생성; unconditional default goal의 Kbuild leakage | top-level-only default goal과 compiled bridge object | target toolchain variance — Low | direct out-of-tree build 및 deployed module load |

## Upstream-tip residual delta classification

검토 명령은 `git diff --name-status
2e481212d262758cbd4d0fc7ea95a2ad5f704bc3..HEAD -- Makefile mlan mlinux mapp`와
각 hunk의 code-path/read-only symbol check였다. 아래에서 **intentional local
overlay**는 binding spec 또는 Task 1–5 audit와 hunk/definition check가 모두
있는 경우만 사용했다. unreviewed difference를 intentional이라고 부르지 않았다.
모든 core driver delta는 defect로 분류된 항목 없이 검토되었으나, target-only
runtime result는 아직 없다.

| 파일 | 분류 | hunk별 근거/판정 |
|---|---|---|
| `Makefile` | intentional local overlay | bridge object/QA, guarded diagnostics, module suffix/apps, 그리고 top-level-only default goal (`:118`) |
| `mlan/mlan_11ac.c` | intentional local overlay | `wlan_11ac_ioctl_vhtcfg()` stored-map round-trip; assoc IE clamp는 유지 |
| `mlan/mlan_11ax.c` | intentional local overlay | `wlan_cmd_append_11ax_tlv()` HE capability diagnostic label/level |
| `mlan/mlan_cmdevt.c` | intentional local overlay | `wlan_ret_802_11_rf_antenna()` SET-only NSS update 및 response field |
| `mlan/mlan_ioctl.h` | intentional local overlay | 6 GHz fields 뒤 `user_htstream`, power `mode`; mirror와 byte-identical |
| `mlan/mlan_misc.c` | intentional local overlay | management prefix의 `snr`/`nf` byte 2/3 |
| `mlan/mlan_sta_cmdresp.c` | intentional local overlay | HE decode, power `mode`, host min-power policy |
| `mlan/mlan_sta_ioctl.c` | intentional local overlay | command-buffer clear 및 HE power encode |
| `mlinux/mlan_ioctl.h` | intentional local overlay | `mlan/mlan_ioctl.h`의 required byte-identical mirror |
| `mlinux/moal_bridge.c` | intentional local overlay | complete runtime bridge implementation: lifecycle, pending switch, RX/TX, PM/reset |
| `mlinux/moal_bridge.h` | intentional local overlay | bridge lifecycle/fast-path public interface; source consumer checks 있음 |
| `mlinux/moal_cfg80211.c` | intentional local overlay | management-mask override와 TX ring/dump logging; upstream registration path 유지 |
| `mlinux/moal_eth_ioctl.c` | intentional local overlay | AGCS single set, `ratebitmapcfg`, HE selector 9–14, `antcfgnss`, bounded replies |
| `mlinux/moal_eth_ioctl.h` | intentional local overlay | `ratebitmapcfg`/`antcfgnss` command constants |
| `mlinux/moal_init.c` | intentional local overlay | bridge/mgmt config parsing, module params, runtime interface parameter |
| `mlinux/moal_ioctl.c` | intentional local overlay | management registration state needed by logging stack |
| `mlinux/moal_main.c` | intentional local overlay | bridge init/exit, RX/TX paths, firmware reload and pre/post reset ownership |
| `mlinux/moal_main.h` | intentional local overlay | bridge/ring/recovery fields and declarations consumed by complete implementations |
| `mlinux/moal_pcie.c` | intentional local overlay | FLR/AER/reset callbacks plus bridge-aware suspend/resume and producer gates |
| `mlinux/moal_pcie.h` | intentional local overlay | PCIe service-card reset state/declarations matching implementation |
| `mlinux/moal_priv.c` | intentional local overlay | `JHW_TEST`-guarded management passthrough trace only |
| `mlinux/moal_proc.c` | intentional local overlay | management ring/dump implementation and proc lifecycle; balanced preprocessor audit |
| `mlinux/moal_sdio.h` | intentional local overlay | SDIO recovery state fields consumed by reset/reload paths |
| `mlinux/moal_sdio_mmc.c` | intentional local overlay | OOB, reset/FLR locking, bridge owner restoration integration |
| `mlinux/moal_shim.c` | intentional local overlay | bridge RX ordering plus management event metadata/log/frequency delivery |
| `mlinux/moal_sta_cfg80211.c` | intentional local overlay | host-MLME TX auth/assoc/scan/deauth/disassoc logging |
| `mlinux/moal_usb.c` | intentional local overlay | kill barrier, disconnect cleanup, status resubmit, suspend producer gate |
| `mlinux/moal_usb.h` | intentional local overlay | `woal_resubmit_urbs()` return type matches definition/caller |

`mapp/`는 core driver가 아닌 bundled userspace surface이다. upstream-tip diff에서
전체 utility tree는 local product overlay로 관찰되며, Task 6가 직접 code-level로
reconciled한 부분은 `mapp/mlanutl/Makefile`의 standalone
`STA_SUPPORT`/`UAP_SUPPORT` default와 `mapp/mlanutl/mlanutl.c`의 `antcfgnss`,
6 GHz `antcfg`, `ratebitmapcfg`, HE power decoding이다. utility build evidence는
아래 표에 한정한다.

## 검증 증거 (두 선행 report의 정확한 재현 명령)

아래는 Task 1–5 report에 기록된 실제 실행 결과이며, 이 Task는 full module build를
다시 실행하지 않았다.

| 명령 | exit | 증거 | 한계 |
|---|---:|---|---|
| `rtk make -C mapp/mlanutl clean` | 0 | utility output 제거 | host-only |
| `rtk make -C mapp/mlanutl` | 0 | `mlanutl.c`/`mlanwls.c`를 `-DSTA_SUPPORT -DUAP_SUPPORT`로 link | device ioctl 미실행 |
| `rtk bash scripts/tests/bridge_static_checks.sh` | 0 | mutation, keepalive, bounded queue, worker accounting, RCU drain, peer release, hairpin smoke | static test only |
| `rtk make bridge-fault-guard-check` | 0 | complete static bridge suite | loaded module/traffic 없음 |
| `rtk bash scripts/tests/bridge_runtime_switch_qa.sh` | 1 | `FAIL: run as root`로 driver/network state 전에 중단 | target runtime pass 아님 |
| `rtk bash scripts/tests/bridge_qa_keepalive_inline.sh` | 1 | target `.ko`, `mlan0`, permitted `dmesg` 부재 | target runtime pass 아님 |
| `rtk make clean KERNELDIR=/lib/modules/6.8.0-111-generic/build ARCH=x86_64` | 0 | final build 전/후 generated output clean | Linux 6.8 headers host만 사용 |
| `rtk make -j4 KERNELDIR=/lib/modules/6.8.0-111-generic/build ARCH=x86_64` | 0 | `MODPOST`, `LD .../mlan.ko`, `LD .../moal.ko` | hardware load/traffic 미검증 |
+| \`rtk sh -lc "stat -c '%n %s bytes' mlan.ko moal.ko; sha256sum mlan.ko moal.ko"\` | 0 | \`mlan.ko\` 1,969,752 bytes / \`moal.ko\` 3,161,744 bytes와 report의 SHA-256 | clean 후 artifact 제거 |
| \`rtk sh -lc "grep -R -n '^<<<<<<<\\|^=======\\|^>>>>>>>' -- Makefile mlan mlinux"\` | 1 | marker 없음; no-match가 기대 exit | source inspection only |
| \`rtk git diff --check\` | 0 | Task 5 당시 working diff whitespace error 없음 | upstream-tip 전체 diff check와 다른 scope |
| \`rtk sh -lc "cmp -s mlan/mlan_ioctl.h mlinux/mlan_ioctl.h"\` | 0 | mirrored ioctl headers byte-identical | ABI runtime interoperability 미검증 |
| focused duplicate-definition audit | 0 | management case 및 USB/reload helper 각각 하나 | semantic firmware execution 미검증 |
| \`rtk git merge-base --is-ancestor 2e481212d262758cbd4d0fc7ea95a2ad5f704bc3 HEAD\` | 0 | exact upstream tip ancestor | runtime correctness 증명 아님 |
| \`rtk git rev-list --parents -n 1 cc7f79de3c58073eb0780d4dd56c1cffe56ee161\` | 0 | local/upstream two-parent merge | 후속 document commit은 single parent |

Task 6의 required review 명령 중 \`git diff --name-status
2e481212d262758cbd4d0fc7ea95a2ad5f704bc3..HEAD -- Makefile mlan mlinux mapp\`는
위 residual table의 28 core files와 bundled utility surface를 제공했다.
\`git diff --check 2e481212d262758cbd4d0fc7ea95a2ad5f704bc3..HEAD\`는 exit 2이다.
이는 upstream-tip과 local product tree의 전 범위를 비교하므로 추가된 binary
\`docs/AN13297.pdf\`와 기존 docs/config/utility whitespace가 보고되기 때문이다.
이 결과를 core code whitespace pass라고 해석하지 않았다. Task 1–4 staged audit의
별도 결과는 embedded upstream patch \`mlinux/iw610_sdio_over_spi_linux.patch\`의
patch-context six \`space before tab\`만으로 default check exit 2였고,
\`git -c core.whitespace=-space-before-tab diff --cached --check\`는 exit 0이었다.
그 context byte를 바꾸면 embedded patch 자체가 변하므로 수정하지 않았다.

Task 5 host build는 기존 warning도 남긴다: \`woal_rx_acct_max\` missing prototype,
1,120-byte \`mgmt_log_printf\` frame, unused PCIe/SDIO FLR helpers. warning을 숨기거나
변경하지 않았다. BTF는 host에 \`vmlinux\`가 없어 skipped되었지만 \`mlan.ko\`와
\`moal.ko\` link는 성공했다.

## target-only exit gates

다음은 **모두 미통과가 아니라 미실행/미판정 target gate**다. 이 문서는 hardware
test가 통과했다고 주장하지 않는다.

1. USB: disconnect/unplug, unload, URB resubmit failure, suspend 중 traffic,
   KASAN 및 pending counter.
2. PCIe: FLR, AER, in-band reset을 bridge active 상태와 suspend/unload 경쟁에서 실행.
3. SDIO: OOB 포함 reset/FLR 및 bridge owner restore.
4. suspend/resume: USB/PCIe/SDIO 각각의 traffic 및 bridge pending switch와 결합.
5. STA/uAP: association, roaming, uAP start/stop, host-MLME/P2P management masks.
6. UAP/AGCS: channel-track GET/SET, AGCS GET/SET, channel-switch count와 firmware trace.
7. antenna: 2.4/5/6 GHz \`antcfg\` SET/GET, repeated GET, bundled \`antcfgnss\` display.
8. VHT/HE: \`vhtcfg\` round-trip/assoc IE, HE power groups 0–14, 20/40/80 MHz, NSS 1/2,
   low-dBm 및 reconnect.
9. ratebitmap: 26-word GET/SET, HT/VHT/HE \`ratemax\`, reconnect persistence.
10. management dump: ring wrap/clear, hex-dump, log volume, concurrent proc read/unload.
11. bridge: runtime interface switching, DBDC, peer delete/recreate, recovery, traffic,
    KASAN/lockdep.

### 최종 risk 결론

compile/link 및 static audit는 clean port가 old replay corruption을 다시 포함하지
않는다는 강한 host evidence다. 그러나 transport teardown, firmware command semantics,
association, RF policy, 그리고 bridge ownership은 target firmware/board/topology가
필요하다. release 판정은 위 target-only gates의 실기기 evidence가 추가될 때까지
**host-validated with target-runtime risk**로 유지한다.
