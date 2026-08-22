# mwifiex 0396cfb→2e481212 Clean Port 최종 코드 검토

## 판정 범위와 최종 상태

이 문서의 최종 **fixed source/test qualification HEAD**는
`e1c9f49bb6ec8ffd0dc9703909ff4ef823a76436`이다. `f11420820bc73196eee837a9896f120b86364b57`의
최종 후보를 타겟에 한 번 더 적용해 원인을 수집한 결과, `c4644eee070c3a735e83037fdefdfbaf3d74ea8e`가
SDIO transport binding `nxp,wifi-oob-int`와 suspend-only wake binding
`nxp,wifi-wake-host`를 fallback으로 합친 것이 잘못임을 확인했다. `e1c9f49`는 해당
alias를 제거하고 transport lookup이 단 하나의 명시적 binding만 허용하도록 mutation
invariant를 강화한다.

최종 판정은 **host/source validated; candidate activation FAIL at the invalid binding
alias; corrected target transport OOB NOT_APPLICABLE /
BLOCKED_BY_HARDWARE_CAPABILITY; architecture WATCH for the generic OOB
implementation; target OOB traffic qualification NOT_APPLICABLE /
BLOCKED_BY_HARDWARE_CAPABILITY; cleanup COMPLETE/ACCEPTED**다. 수정 diff의 독립 2-lane review는
code `APPROVE`, architecture `CLEAR`이며 Critical/Important finding은 0건이다. terminal
hardware all-fail shared-line `WATCH`는 별도 source chronology로 유지한다. Draft PR #27은
Draft로 유지하고 merge-ready 판정을 하지 않는다. 이전 i.MX93 in-band reload PASS는
아래에 명시한 과거 slice에만 적용되며 OOB, PM 또는 장시간 traffic runtime PASS가 아니다.

| 항목 | 고정 값 |
|---|---|
| local integration parent | `ce179fcc8a82f4ce41e70ffadc65c966a7a1565d` |
| upstream base | `0396cfb38ad73a3d587cd0f8c139b47801e70891` |
| upstream tip | `2e481212d262758cbd4d0fc7ea95a2ad5f704bc3` (`upstream/lf-6.18.20_2.0.0`) |
| upstream 범위 | `0396cfb..2e481212`, 40 commits |
| clean integration merge | `cc7f79de3c58073eb0780d4dd56c1cffe56ee161` |
| external-build repair | `e48323b9219cf09d125de761aa073129e1174b3d` |
| pre-final-review evidence HEAD | `760908e4d570c41ae520ad9c401bc7b4c54e85d6` |
| primary final-review fixes | `fdba08f1df564c452a3242e65e23e9587487c91e` |
| scoped residual fixes | `e1fe289ee2d926f61a6384f47505fdb09bcb0466` |
| deterministic QA fixes | `1dd14bf30093d2232d1a506385ff7d89d7d04b49`, `3b9c8f8d7a06552bce3d94aa8b7967be04eb5f18` |
| latest main reconciliation | `45f593ef8a51f2c9591cb024d956ce602a89c4f9` (includes `origin/main` `1ba9fd42b40c8f76b207ec391eec77c171cdcc12`) |
| reconciliation review fixes | `609749f07d00c49b4659b8cc55e13ff287a8da1a` |
| automated-review residual fixes | `1e2e4a337d52d1e53e2149b5fa7e30c19ac0e984` |
| OTP delimiter follow-up | `1499c4c7f6a0fa8b3edd195f9e1c8d55b98e1216` |
| i.MX93 userspace cross-build isolation | `4a5fe74c4f838371852bca8936d7267c45ea8518` |
| SDIO module-exit command-response fix | `50cbe67295d2fe8e7b91b7a714849cc427add724` |
| SDIO OOB lifecycle hardening | `812a65b7ee832e242f80e35847ed9777800ab4ae` |
| SDIO OOB transactional source transitions | `80dc84841046dd2b0d0919f1a3083ea57ce2cfe2` |
| SDIO OOB owner-preservation intermediate | `f67dd21a833f79357d9010b6164a5ef370b5b06b` |
| terminal OOB software-detach | `e526b8bb2f580a45b46e589337a0923214e9bf2b` |
| SD9098 cross-function callback barrier | `734f75bf02a3e5ac4c84a696d8a873ed11247ce3` |
| invalid OOB/wake binding alias | `c4644eee070c3a735e83037fdefdfbaf3d74ea8e` (target failure source; reverted semantically) |
| final APF/Android/SAE review fixes | `f11420820bc73196eee837a9896f120b86364b57` (second target-staged candidate source) |
| transport/wake binding separation | `e1c9f49bb6ec8ffd0dc9703909ff4ef823a76436` (host/source validated; not target-staged) |
| final evidence documentation | follow-up docs commit; no artifact content change |

`cc7f79d`는 local parent `ce179fcc`와 exact upstream tip `2e481212`를 부모로
갖는 non-fast-forward merge다. clean-port first-parent 범위의 upstream integration
merge는 정확히 하나이고, latest-main reconciliation merge까지 포함한 first-parent
merge는 둘이다. upstream base/tip과 `origin/main` 모두 최종 source HEAD의 ancestor다.
이 topology는 release snapshot을 다시 cherry-pick하지 않고 양쪽 history를 보존한다.

## OOB WATCH qualification closure

### Source, tests, and candidate identity

`c4644eee`의 기존 RED/GREEN은 preferred/fallback lookup 자체를 고정했지만 두 binding의
서로 다른 의미를 검증하지 못했다. exact upstream `0396cfb`는
`woal_request_gpio()`에서 `nxp,wifi-oob-int`만 사용하고,
`woal_regist_oob_wakeup_irq()`에서 `nxp,wifi-wake-host`를 별도로 사용한다. 타겟도
in-band baseline에서 후자 action 두 개만 등록하고 transport action은 등록하지 않는다.

`e1c9f49` 수정에서는 production C를 바꾸기 전에 새 invariant가 실제로
`FAIL: SDIO transport IRQ lookup aliases the suspend-only wake binding`과 exit `1`을
기록했다. fallback 제거 뒤 GREEN을 확인했다. 독립 review가 임의의 다른 binding alias도
허용할 수 있음을 지적해 M3 mutation을 추가했고, 먼저
`FAIL: M3 SDIO transport invariant accepts an unreviewed binding alias`를 확인한 뒤 lookup
count를 정확히 하나로 제한해 GREEN을 확인했다. aggregate final checks, checkpatch
0 errors/0 warnings와 exact i.MX93 build도 통과했다.

### Target-staged OOB attempt (source `c4644eee070c3a735e83037fdefdfbaf3d74ea8e`; inactive and unqualified)

Task 2의 exact i.MX93 candidate는 다음과 같다. 이 identity는 과거 build/staging
증적이며 active install 또는 hardware qualification을 의미하지 않는다.

| artifact | bytes | SHA-256 | vermagic / version |
|---|---:|---|---|
| `bin_wlan/mlan_imx93.ko` | 992,720 | `0c0347b6ef08ae0d605655b62e70121440d0f0961277d25f5eb27fe4b595b396` | — |
| `bin_wlan/moal_imx93.ko` | 1,978,832 | `ea0ec9ad1d53fd98433ff549752be671181443e7fc52de11ac4236410afaa328` | `6.6.3-lts-next-gccf0a99701a7-dirty SMP preempt mod_unload modversions aarch64`; `543.p18` |
| `bin_wlan/mlanutl_imx93` | 400,968 | `127912311df9397df9104cf8fe96f4501ecc1edf9df67007d54af6f95c2ae4a3` | — |
| `bin_wlan/mlanevent_imx93` | 68,144 | `3523a73a544627d3ceae7f3c7ed57cdf19df8a04882b0d0ea14c69bde95dbd05` | — |

`make_for_imx93.sh`는 exit `0`이지만 warning-free가 아니다. 정확히 세 개의 known
`mlanutl` warning이 남는다.

1. `mlanutl.c:5833:25`: unchecked `fgets`의 `-Wunused-result` warning.
2. `bits/string_fortified.h:29:10`: `send_dot11_packet` / `process_dot11_txrx`에서
   inlined된 `__builtin_memcpy` offset `[0, 5]` 대 bounds `[0, 0]`의
   `-Warray-bounds` warning.
3. `bits/string_fortified.h:95:10`: `process_cwmode`에서 inlined된
   `__builtin___strncpy_chk` offset `[4096, 4103]` 대 bounds `[0, 4096]`의
   `-Warray-bounds` warning.

Task 7 exact-tree 재검증에서도 `upstream_port_final_checks.sh`와
`make_for_imx93.sh`는 각각 exit `0`이었고 build warning은 같은 세 건뿐이었다.
`build pristine`은 호출하지 않았고 이 결과를 pristine/warning-free라고 부르지 않는다.

### Second target-staged OOB attempt (source `f11420820bc73196eee837a9896f120b86364b57`; inactive and failed activation)

최종 host-review 수정까지 포함한 두 번째 후보는 다음 identity로 stage/install되었다.

| artifact | bytes | SHA-256 | vermagic / version |
|---|---:|---|---|
| `bin_wlan/mlan_imx93.ko` | 992,720 | `0c0347b6ef08ae0d605655b62e70121440d0f0961277d25f5eb27fe4b595b396` | `543.p18` |
| `bin_wlan/moal_imx93.ko` | 1,978,536 | `f7155dc139c6a4f976d08815596937ddb8083b8856037bf7b58a29371ba81af3` | exact target aarch64 vermagic; `543.p18` |
| `bin_wlan/mlanutl_imx93` | 400,968 | `127912311df9397df9104cf8fe96f4501ecc1edf9df67007d54af6f95c2ae4a3` | ARM aarch64 executable |
| `bin_wlan/mlanevent_imx93` | 68,144 | `3523a73a544627d3ceae7f3c7ed57cdf19df8a04882b0d0ea14c69bde95dbd05` | ARM aarch64 executable |

이 후보는 activation health gate를 통과하지 못했으며 현재 active target artifact가 아니다.

### Rollout, root cause, and runtime matrix

Task 3은 fresh backup과 immutable stage를 만들고 exact candidate manifest를 검증한
뒤 baseline-only rollback rehearsal을 exit `0`으로 완료했다. rehearsal은 두 module
version `543.p18`, 4/4 service, 2/2 SDIO function, in-band configuration, backup equality
5/5와 rollback completion을 확인했다. named 90-minute rollback timer도 arm/prove했다.

첫 `c4644eee` attempt는 transport lookup이 target의 wake-only node를 fallback으로
선택한 뒤 OOB IRQ를 매핑했으나 `SDIO_GPIO_INT_CONFIG [0x88]`가 timeout됐다. 당시
production checker가 netdev 부재를 `fw_crash`로 분류해 기존 reboot policy가 reboot을
승인했다.

두 번째 `f114208` attempt에서는 승인된 범위로 checker와 firmware watcher를 먼저
중지하고 rollback timer를 arm했다. 같은 OOB IRQ mapping 직후 같은 command가 두 번
timeout됐고 `Firmware Init Failed`/`woal_add_card failed`가 이어졌다. 첫
`wifi_init.service`는 status 75로 실패해 emergency condition에서 제외됐으며 activation
trap이 baseline rollback을 시작했다. 그러나 실패한 카드 상태는 module/config 복원만으로
회복되지 않았고 baseline restart도 firmware init 실패 후 status 1을 반환했다. 그 결과
`wifi_init.service`의 기존 `OnFailure=wlan_emergency_reboot.service`가 reboot을 승인했다.
이는 감시 서비스 오판이 아니라 동일 transport-command failure 뒤의 정상 복구 정책이다.

지속 snapshot journal과 reboot state는 두 attempt에서 같은 command timeout을 증명한다.
exact upstream은 transport와 wake binding을 별도로 유지하고 target에는
`nxp,wifi-oob-int`가 없으므로, `c4644eee` fallback은 플랫폼 적응이 아니라 잘못된 의미
alias였다. corrected source는 해당 binding이 없는 target에서 IRQ 등록 전에 `-ENODEV`로
fail-fast한다. target wall-clock은 controller chronology와 어긋나므로 event marker,
uptime 및 boot ID를 함께 사용했다.

### 88W9098 target OOB capability closure

이 타겟은 driver 명칭으로 SD9098 DBDC이지만 silicon은 88W9098이다. NXP TechSupport는
88W9098 M.2의 `SDIO_WAKE#`가 wake-only이며 이 칩에는 별도 OOB interrupt/event GPIO가
없다고 명시한다:
https://community.nxp.com/t5/Wi-Fi-Bluetooth-802-15-4/M2-JODY-W377-88W9098-OOB-interrupt/m-p/2351813/highlight/true.
범용 driver README의 `intmode=1` 및 `gpiopin=0`/GPIO-21 설명은 해당 출력을 지원하는
다른 hardware를 위한 기능이며 이 타겟의 capability 증거가 아니다:
https://github.com/nxp-imx/mwifiex.

exact BSP source commit은 `ccf0a99701a701fb48a04e31ffe3f9d585a8374a`이고, local build
DTB와 boot partition DTB의 동일 SHA-256은
`9a491ab1155f69a56bdfb931aa8dbae5f2a3ad2dfbef7087005fd02baa093d39`다. 이 exact DTB에는
`GPIO3_IO26`의 `nxp,wifi-wake-host`만 있고 독립 transport-event line은 없다.

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

**Classification:** `NOT_APPLICABLE / BLOCKED_BY_HARDWARE_CAPABILITY`. Operationally,
the target deployment must retain `intmode=0`. `nxp,wifi-wake-host` must not be
aliased or relabeled as `nxp,wifi-oob-int`. No BSP/DT patch, target mutation, or
additional OOB maintenance window is authorized. Generic upstream OOB transport
code remains retained for hardware that supplies a supported transport-event line.
이 capability closure에는 production C 변경과 target 변경이 없다.

| runtime slice | execution | classification / evidence boundary |
|---|---|---|
| Candidate activation | **FAIL** | 두 attempt 모두 `SDIO_GPIO_INT_CONFIG` timeout 뒤 firmware init 실패 |
| Initial OOB/DBDC health | **NOT APPLICABLE** | `BLOCKED_BY_HARDWARE_CAPABILITY` |
| Initial OOB action count | **HISTORICAL PARTIAL ONLY** | invalid-alias IRQ mapping message만 있었고 qualification 증거가 아님 |
| Traffic IRQ delta | **NOT APPLICABLE** | `BLOCKED_BY_HARDWARE_CAPABILITY` |
| Idle IRQ-storm sample | **NOT APPLICABLE** | `BLOCKED_BY_HARDWARE_CAPABILITY` |
| Traffic-active teardown/reload | **NOT APPLICABLE — historical 0/10** | `BLOCKED_BY_HARDWARE_CAPABILITY` |
| `s2idle` | **NOT APPLICABLE** | `BLOCKED_BY_HARDWARE_CAPABILITY` |
| `deep` | **NOT APPLICABLE** | `BLOCKED_BY_HARDWARE_CAPABILITY` |
| 30-minute OOB ping | **NOT APPLICABLE** | `BLOCKED_BY_HARDWARE_CAPABILITY` |
| OOB iperf | **NOT APPLICABLE** | `BLOCKED_BY_HARDWARE_CAPABILITY`; environment/server reachability는 probe하지 않음 |
| Terminal all-hardware-cleanup-fails path | target **NOT APPLICABLE** | generic implementation은 별도 `BLOCKED_BY_PLATFORM`; static mutations는 physical-source quiescence 증명이 아님 |
| USB runtime | **NOT EXECUTED** | `BLOCKED_BY_HARDWARE` |
| PCIe runtime/FLR | **NOT EXECUTED** | `BLOCKED_BY_HARDWARE` |

따라서 target OOB s2idle/deep와 30-minute ping/iperf는 PASS/FAIL 또는 retry 대기 상태가
아니다. 명시적 closure summary는 **target OOB traffic qualification NOT_APPLICABLE /
BLOCKED_BY_HARDWARE_CAPABILITY; cleanup COMPLETE/ACCEPTED**다.

### Restored baseline and cleanup proof

최종 target은 c464/f114 candidate가 아니라 pre-qualification in-band `543.p18` backup이다.
active module 두 개, utility 두 개와 parameter file의 다섯 artifact가 backup과 exact
match하고, OOB/`intmode`는 absent이며, required services와 SDIO functions는 healthy다.
DBDC netdev와 STA association도 복구됐다. Candidate와 `wifi_mod_para.oob`, manifests,
backup/stage/rollback evidence는 retained하지만 candidate는 inactive/unqualified 상태다.

packaged `/lib/modules`의 `mlan.ko`와 `moal.ko`는 inactive vendor `437.p3` copy로
그대로 남았다. cleanup 전후 SHA-256은 각각
`7902e908bc3ea1482f2f4a8d21ae88b7e3d920994feb947ce87304e41f6da1d2`와
`db57ffa6ce14ac8cb589b8b7bf61db83a7f68c97436d5ba1e3efb41896b1eff8`로 동일했고,
qualification은 이 packaged tree를 쓰거나 덮어쓰지 않았다.

두 번째 reboot으로 volatile env, maintenance marker와 transient timer는 사라졌고 active
timer count는 0이다. reboot 뒤 fresh baseline gate는 artifact equality 5/5, required
service 6/6 active, SDIO function 2/2, DBDC netdev/STA, OOB action 0, `intmode=1` line 0을
확인했다. packaged vendor copies도 변경되지 않았다. backup/stage 증적은 retained했다.

## 최종 review chronology

1. clean merge와 build-goal repair 뒤의 초기 독립 code review는 변경을 요청했다.
   가장 중요한 BLOCK은 USB submit과 kill barrier 사이의 race였고, 별도 architecture
   검토는 cold-start/recovery bridge policy 및 PM/transport lifecycle을 WATCH로
   유지했다.
2. `fdba08f`가 USB serialization/final drain, `antcfg`, management logging/proc,
   management metadata, warning 및 반복 가능한 invariant/QA gate 등 원래 review
   findings를 수정했다.
3. scoped re-review는 원 findings의 source 수정은 확인했지만 두 residual을 새로
   찾았다. management event 최대 길이가 4-byte prefix를 예약하지 않았고, non-2x2
   `antcfg`가 four-word SET의 세 값을 무시하면서 성공했다.
4. `e1fe289`가 두 residual과 exact boundary/layout assertions를 수정했다. 이후 fresh
   controller source/build verification은 통과했다.
5. controller 반복 실행이 `set -o pipefail` + quiet `grep`의 producer SIGPIPE로 인한
   nondeterministic false failure를 발견했다. `1dd14bf`와 `3b9c8f8`은 assertion이나
   mutation을 약화하지 않고 unsafe predicate를 deterministic here-string/process-
   substitution 형태로 바꾼 test-only commits다.
6. `cd6448e`가 내부 SDD report를 잘못 force-track했고 `fb4b288`이 다시 untrack했다.
   이 두 commit은 tracked internal-report 경로에 대해 net-zero이며 production/source
   semantics를 바꾸지 않는다.
7. `45f593e`가 최신 `origin/main`을 clean-port branch에 merge했다. 이어진 reconciliation
   review는 config proc writer가 teardown과 공유하는 handle lifetime, hang worker의
   cleanup-to-reload handoff, 비동기 PCIe mode-4 FLR의 DBDC 중복 admission 및
   remove/rebind 경쟁을 집중 검토했다.
8. `609749f`가 `AddRemoveCardSem` 기반 lifetime transaction, ordered hang handoff,
   canonical DBDC pending gate, 참조 보유된 PCI device work item, remove-time
   invalidation, kernel-version별 locked FLR, terminal failure publication과 stale-status
   직렬화를 구현했다. 새 invariant는 각 race의 admission/order/status 조건을
   고정한다.
9. 원격 자동 리뷰 뒤의 fresh source audit는 config proc writer와 firmware-dump event
   reader가 pathname allocation을 공유하던 수명 결함, 일부 명령 delimiter의 prefix
   오인, PCI device-lock의 transient contention 및 console dump의 `ERR_PTR` read를
   확인했다. 첫 pathname mutex 설계는 module-global active path가 adapter 간 dump를
   섞고 custom path에서 dump lifecycle을 우회하여 architecture review에서 BLOCK됐다.
10. `1e2e4a3`은 configured/active pathname을 handle별로 분리하고 seq1부터 ENDE까지
    immutable active snapshot을 유지한다. Snapshot OOM은 unset과 구분하고 file open과
    signed read 오류를 dereference 전에 처리한다. Proc path는 CR/LF를 trim하고 empty와
    embedded NUL을 거절하며, bare command는 exact content와 exact/LF boundary를 모두
    검사한다. PCI peer/target lock은 cancellation을 매회 재검사하는 bounded retry를
    사용한다. 강화된 invariant의 RED/GREEN 뒤 final code reviewer는 `APPROVE`, final
    architecture reviewer는 `CLEAR`를 발행했다.
11. 후속 OpenCode 요약의 delimiter 지적을 기계적으로 재감사했다. `mlinux/*.c,h`의
    literal/`strlen(literal)` `strncmp()` 315쌍 중 실제 mismatch는
    `otp_mac_addr_rd_wr=` 한 건이었다. 먼저 exact delimiter invariant가 기존 코드에서
    실패하는 RED를 확인하고, 길이 literal 오타를 고친 뒤 GREEN을 확인했다.
    `1499c4c` 이후 같은 감사의 mismatch는 0이고 targeted code review는 `APPROVE`,
    architecture re-review는 `CLEAR`다.
12. 실제 `make_for_imx93.sh` 검증은 이전 host QA의 x86-64 `mlanutl` object/binary를
    flat `mapp/mlanutl` build directory에서 재사용해 aarch64 `objcopy`가 거절하는
    문제를 재현했다. `4a5fe74c`는 기본 target build 전에 `mlanutl`과 `mlanevent`를
    clean하고, host `antcfg` QA도 반대 방향의 stale aarch64 object를 먼저 제거한다.
    fake toolchain으로 실제 script call order를 실행하는 regression test는 수정 전
    RED와 수정 후 GREEN을 보였고 scoped code review는 `APPROVE`다.
13. i.MX93 target에서 기존 local teardown hardening이 module exit 초기에 올리는
    `driver_exit_in_progress`/`reset_stopping`을 SDIO command-response IRQ gate로도
    사용하여 `FUNC_SHUTDOWN [0xaa]`가 매번 timeout되는 것을 재현했다. 외부
    `wifi_logger_temp`를 멈추면 `DS_GET_SENSOR_TEMP [0x227]` timeout만 사라져 두
    원인을 분리했다. 먼저 shutdown 전 producer gate와 IRQ gate의 결합을 거절하는
    invariant가 기존 코드에서 RED임을 확인했다. `50cbe67`은 recovery producer gate와
    transport gate를 분리하고 실제 SDIO remove에서만 `drv_mode_quiesced`를 올린다.
    수정 뒤 invariant/final checks, exact i.MX93 build와 target의 연속 reload가
    GREEN/PASS였다.
14. 후속 SDIO/OOB 동시성 검토는 두 결함을 BLOCK으로 분류했다. 첫째,
    `queue_work()==false` fallback이 hard-IRQ 문맥에서 `enable_irq()`를 호출했다.
    둘째, CCCR function interrupt disable이 실패해도 callback/source 상태를 지우고
    IRQ action과 workqueue를 해제했다. 각 결함을 먼저 source mutation으로 RED
    재현했다. `812a65b`는 coalesced token 반환을 같은 ordered workqueue의 별도
    process-context work로 넘기고, callback clear를 CCCR write 성공 뒤로 이동한다.
    unregister 실패 시 action/queue를 유지하며 terminal release는 해당 SDIO function
    전체 disable이 성공한 뒤에만 action teardown을 재시도한다. final checks,
    checkpatch 0/0, exact i.MX93 build와 target의 logger-active
    `50cbe67→812a65b→812a65b` reload는 PASS였다.
15. `80dc848`은 source-enable write가 오류를 반환해도 실제 device에 도달했을 수 있는
    ambiguous claim에서 callback/action/WQ를 보존하고 host unlock 뒤 terminal cleanup을
    수행한다. driver-mode quiesce의 function-source disable 실패 시 같은 device가 계속
    current라면 transport gate를 다시 열어 live level source가 닫힌 gate 뒤에서 storm하지
    않게 했다. mutation/final checks와 exact i.MX93 build는 PASS였다.
16. 첫 후속안 `f67dd21`은 cleanup 실패 owner를 partial handle로 quarantine했지만,
    독립 검토가 최종 retry 실패의 owner free, Android 초기화 비대칭, block-size 후속 실패를
    BLOCK/HIGH로 판정했다. `e526b8b`은 quarantine/PENDING overload를 제거하고 fallible
    block-size 설정을 IRQ 노출 앞으로 옮겼다. 모든 hardware cleanup이 실패하는 terminal
    경로는 registration gate, IRQ synchronize, local WQ flush, token balance 뒤 action과 WQ를
    강제 software-detach하여 module text/card/handle UAF보다 hardware liveness를 우선한다.
17. 재검토는 SD9098 sibling OOB worker가 모든 function callback을 MMC host 아래 dispatch하는
    cross-action 경계를 추가로 발견했다. `734f75b`은 local drain 뒤 같은 MMC host를 claim하여
    handler와 drvdata를 함께 끊고 host release 뒤 action/WQ를 해제한다. reset도 block-size를
    확인한 뒤에만 OOB/in-band IRQ를 재등록한다. 각 장벽은 RED/GREEN mutation으로 고정했고,
    final checks와 변경 object를 실제 재컴파일한 i.MX93 build는 PASS였다. 최종 두 독립 lane은
    code `APPROVE`, architecture `WATCH`를 발행했다. WATCH는 모든 hardware disable/reset이
    실패한 terminal 경우 물리 level-low source가 남을 수 있는 availability 위험이다.
18. `c4644eee`는 target DT에 transport binding이 없다는 사실을 driver-side fallback으로
    우회하려 했으나, upstream이 분리한 wake-only binding을 continuous SDIO transport IRQ로
    재사용했다. 첫 target attempt는 OOB IRQ mapping 뒤 `SDIO_GPIO_INT_CONFIG` timeout과
    checker-triggered reboot으로 끝났다. 당시 미확보했던 previous-boot journal을 persistent
    snapshot에서 복원해 candidate failure가 reboot보다 먼저였음을 확인했다.
19. `f114208` candidate를 checker/watcher 정지 및 자동 rollback timer 아래 다시 적용해 같은
    command timeout과 firmware init failure를 재현했다. rollback은 baseline file을 복원했지만
    card가 warm module reload로 회복되지 않아 baseline `wifi_init`도 실패했고 기존
    `OnFailure` policy가 reboot을 승인했다. reboot 뒤 baseline equality와 service/DBDC/STA
    health는 모두 복구됐다. 동일 실패가 두 번 반복됐으므로 추가 target retry는 중단했다.
20. `e1c9f49`는 wake binding fallback을 제거하고 transport lookup을 한 binding으로 제한한다.
    semantic-alias RED/GREEN과 arbitrary-alias M3 RED/GREEN, aggregate final checks, exact
    i.MX93 build 및 checkpatch 0/0을 확인했다. 독립 review 결과는 code `APPROVE`,
    architecture `CLEAR`, Critical/Important 0건이다. corrected artifact는 target에 다시
    stage하지 않았다.

이 chronology의 source/architecture 판정은 current tree의 fresh review에 근거한다.
검증한 SDIO reload slice 밖의 target firmware/hardware stress는 별도이며 계속
**WATCH/open**이다.

## Upstream coverage와 손상 branch 배제

감사는 stable patch-id, range-diff pairing, final tree/function identity 및 고위험
definition audit를 함께 사용했다.

- **exact-equivalent 25개:** `58368fe6`, `3383eb3e`, `0ea4f2ff`, `bc7387bf`,
  `2da89e4c`, `91d2e896`, `038a3079`, `7d13b9dc`, `f97f966e`, `60f40a22`,
  `cd6b82e5`, `166182fd`, `fe5016be`, `87d7b501`, `7b05b576`, `eadd45ba`,
  `b08958dc`, `e9b6c82a`, `dd4c01c5`, `da884137`, `07da5c79`, `94f77173`,
  `031aa9bb`, `6c8ee594`, `c29c64d`.
- **rewritten-equivalent 10개:** `e207c169`, `32e32105`, `eecc5871`,
  `1e8b968f`, `a2501625`, `6818dd8c`, `65b03488`, `371a047a`, `e753dc75`,
  `8cc07f8`.
- **old branch replay-corrupted 2개:** `d5dfe540`, `b8c868b7`. clean merge는 exact
  upstream definitions를 한 번씩만 포함한다.
- merge/README/SBOM 3개는 direct build-hygiene 범위 밖이지만 40-commit ancestry에
  포함된다.

오래된 `port/upstream-61820-0396`의 `7a56d1f`는 vendor replay가 중복 누적되어
UAP channel-switch, SNMP/AGCS 및 preprocessor structure를 손상시켰으므로 통합
입력으로 사용하지 않았다. clean tree의 focused audit는 UAP channel-track, AGCS,
channel-switch 및 관련 dispatcher 정의가 각각 하나임을 확인했다.

## 최종 source 상태

### USB submit/kill, reopen 및 firmware reload

`usb_card_rec`은 `urb_submit_lock`과 `urb_stopping`을 보유한다. RX/TX submit은
fast rejection 뒤 shared lock 아래에서 stop/removal/suspend를 다시 확인하고
`usb_submit_urb(..., GFP_ATOMIC)`를 실행한다. teardown은 같은 lock 아래에서 gate를
닫은 뒤 모든 `usb_kill_urb()` completion barrier를 수행하므로 submit은 barrier
앞에 완료되어 drain되거나 gate에서 거절된다.

`woal_remove_card()`의 final USB kill/drain은 `mlan_unregister()`보다 앞선다.
`woal_resubmit_urbs()`는 live device에서만 gate를 열고 complete RX set 복구에
실패하면 다시 닫는다. PM resume, driver-mode rebuild 및 generic firmware reload는
이 controlled reopen을 사용한다. firmware reload는 download 뒤 warm-reset IOCTL
전에 URB를 복구하고, primary/companion 후속 실패 시 열린 gate를 다시 닫고 terminal
recovery state를 게시한다.

이 source ordering은 원래 BLOCK을 해소하지만 target race를 대신하지 않는다.
unplug/unload, suspend traffic, resubmit fault, firmware reload/mode rebuild,
pending counters와 KASAN/lockdep은 계속 target gate다. cold-start bridge failure와
destructive recovery failure의 서로 다른 정책도 lifecycle WATCH로 남는다.

### `antcfg`, `antcfgnss` 및 NSS ABI

bundled `mlanutl`과 kernel parser가 허용하는 `antcfg` form은 정확히 다음과 같다.

- GET: 인자 없음;
- SET: one word, two words, 또는 four words;
- three/five word는 userspace/kernel boundary에서 거절;
- non-2x2 layout은 four-word SET을 `-EOPNOTSUPP`로 거절;
- 1x1은 one/two, 2x2는 one/two/four form을 유지.

four-word 2x2 응답은 upstream Tx/Rx/6 GHz Tx/6 GHz Rx slot을 유지한다.
`user_htstream`은 그 뒤의 local field이고 SET response에서만 host NSS intent를
갱신한다. `antcfgnss`는 별도 GET-only command이며 non-2x2에서는 union의 잘못된
member를 읽지 않고 `-EOPNOTSUPP`를 반환한다.

### management event, ring 및 proc

공유 `mlan_mgmt_event_metadata`는 `[band_config, channel, snr, nf]`의 typed
four-byte prefix이고 payload offset은 4로 유지된다. producer는
`MAX_EVENT_SIZE - sizeof(mlan_event) - MLAN_MGMT_EVENT_PAYLOAD_OFFSET`를 최대
payload bound로 사용하여 flexible `event_buf[]`의 prefix 공간을 예약한다.
consumer는 metadata를 읽기 전에 최소 4 byte를 확인하고 addr4 removal/
`memmove()` 전에 추가 frame 길이를 확인한다.

management log와 dump ring은 각자 1,024-byte heap scratch를 소유한다. formatting과
ring write는 ring lock으로 직렬화되고, 과거 caller의 768-byte IE scratch 위에
1,024-byte local frame을 중첩하지 않는다. `mgmt_log`와 `mgmt_dump` proc entry는
모든 proc API branch에서 mode `0600`이다. driver Kconfig는 실제 proc/debug coupling에
맞춰 `PROC_FS`에 명시적으로 의존한다. active production `[DBG-RXDROP]` print는
제거되었고 drop counters/default-off debug policy는 유지된다.

config proc parser는 `soft_reset`, `drv_mode`, `rf_test_mode`, `antcfg`와 RF command
keyword 및 `otp_mac_addr_rd_wr` 뒤에 실제 `=` delimiter가 존재하는지 길이와 함께
확인한다. `debug_dump`,
bare `fw_reload`, `get_and_reset_per`는 command content가 정확히 일치하고 입력이
exact length 또는 단일 LF일 때만 동작한다. `copy_from_user()` 실패는 `-EFAULT`로
반환하고 TP accounting timer는 최종 handle free 전에 취소된다.

config proc mode `0644`는 기존 read ABI를 유지하기 위해 의도적으로 보존했다. 일반
procfs root 소유권에서 owner만 write 가능하고 group/other는 read-only이므로
world-writable 권한이 아니다. 민감한 management log/dump entry의 `0600` 정책과도
구분한다.

`fwdump_file=` pathname은 proc input의 CR/LF를 제거하고 empty value와 embedded NUL을
거절한 뒤 NUL-terminated allocation으로 교체한다. Configured pathname과 seq1부터
ENDE까지 고정되는 active pathname은 `moal_handle`별 mutex 아래에서 교체/snapshot된다.
따라서 proc writer와 event reader의 UAF 및 두 adapter 사이 pathname 혼선이 없다.
Snapshot OOM은 unset path와 구분되며 file open의 `ERR_PTR`와 signed read 실패는
VFS read/close 전에 분기한다. 정상 ENDE의 console print는 별도 heap snapshot을
사용하여 pathname mutex 밖에서 수행한다.

file-dump의 synchronous VFS I/O와 `FWDUMP_VIA_PRINT`의 whole-dump allocation은 이번
수명 수정 이전부터 존재한 실행 모델이다. 대체 build는 해당 경로의 컴파일만
검증하며, 실제 dump latency와 memory pressure는 target/performance WATCH로 남긴다.

### Proc/reload transaction과 deferred PCIe FLR

`woal_config_write()`는 nonblocking `AddRemoveCardSem` 획득에 성공한 writer만 전체
handle-lifetime transaction으로 admission한다. admission 뒤 global slot identity,
module exit, surprise removal, firmware reset, driver-init 및 pending PCIe reset을 다시
검사한다. driver-mode와 firmware-reload 내부 helper는 caller가 semaphore를 이미
소유한 경우를 명시적으로 전달하여 중첩 획득 없이 동일 lifetime을 유지한다.

hang worker도 semaphore 아래에서 published handle identity를 재검증하고 cleanup부터
automatic SDIO/PCIe recovery handoff까지 소유권을 유지한다. handoff 실패 시 이미
canonical deferred recovery가 transaction을 소유하지 않는 한 primary/companion을
NotReady/terminal recovery-fail 상태로 게시한다. proc mode-4 FLR가 이미 pending이면
hang cleanup은 같은 adapter를 먼저 파괴하지 않는다.

mode-4 PCIe FLR는 ordered workqueue에서 비동기로 실행한다. work item은 raw
`moal_handle`/card pointer 대신 target/key/peer `pci_dev` references와 expected
`pci_driver`를 보유한다. canonical primary `key_pdev`가 DBDC primary/companion proc
node의 중복 FLR를 차단한다. worker는 publication completion 뒤 cancellation을
확인하고 peer device lock 다음 target의 full PCI lock을 최대 20회 bounded retry로
획득한다. 각 실패는 획득한 peer lock을 해제하고 1~2ms sleep하며, 매 시도 전과 두
lock 획득 뒤 cancellation을 다시 검사한다. 이후 driver binding과
`pci_get_drvdata()`를 다시 검증하고
`pci_reset_function_locked()`를 호출한다.

retry의 설정된 sleep budget은 스케줄러 지연을 제외하고 최대 약 40ms이며 소진 시
terminal `-EAGAIN`을 게시한다. 이는 device-lock cycle을 피하기 위한 bounded 정책이고,
ordered recovery queue의 contention/latency 및 재시도 성공률은 target WATCH다.

Linux 5.14 이상은 `pci_dev_trylock()`/`pci_dev_unlock()`을 사용하고, 4.13~5.13은
core와 같은 config-access-then-device lock composition을 사용한다. 4.13 미만은
mode-4를 event/status publication 전에 `-EOPNOTSUPP`로 거절한다. PCI remove는 reset
gate 직후와 card removal 뒤에 pending target/key/peer를 모두 invalidate한다.
invalidation은 실패 상태를 먼저 게시하고 worker의 최종 status write도 같은 pending
lock 아래에서 cancellation을 재검사하므로 성공한 rebind 상태를 stale worker가
덮어쓰지 않는다.

### SDIO module-exit command-response 수명

`woal_cleanup_module()`은 module exit를 게시하고 hang/reset work producer를
`AddRemoveCardSem` 획득 전에 drain한다. 이 ordering은 reset worker와 semaphore의
deadlock을 막기 위해 필요하지만, 그 producer-stop 상태는 뒤이어 전송하는 disconnect,
deep-sleep 및 `MLAN_FUNC_SHUTDOWN` IOCTL의 SDIO 응답까지 막아서는 안 된다.

따라서 SDIO transport는 다음처럼 분리했다.

- `driver_exit_in_progress`와 `reset_stopping`은 새 hang/reset/recovery work의 admission을
  중단한다.
- in-band IRQ와 OOB GPIO/work는 module-exit producer gate만으로 반환하지 않고,
  `drv_mode_quiesced`가 닫힐 때까지 command response를 MLAN에 전달한다.
- 실제 `woal_sdio_remove()`는 `reset_lock` 아래에서 먼저
  `drv_mode_quiesced=true`와 `reset_stopping=true`를 게시하고 reset work를 취소한다.
  이어 `surprise_removed`를 게시한 뒤 MMC host claim/release barrier로 이미 진입한
  callback을 기다린다.
- OOB 경로도 같은 transport gate를 확인하므로 remove 또는 driver-mode quiesce 뒤
  새 work를 queue/re-enable하지 않는다. 이미 queue된 work는 gate를 다시 확인하고,
  unregister helper가 IRQ disable과 workqueue flush를 수행한다.

source invariant는 cleanup의 producer gate가 shutdown보다 앞설 때 in-band/OOB
command-response path가 같은 gate를 소비하면 실패한다. 별도 invariant는 SDIO remove가
transport gate를 닫고 reset work 취소와 host barrier를 순서대로 수행하는지 검사한다.
실제 target은 in-band IRQ 구성이고 OOB/driver-mode 경쟁은 아직 target WATCH다.

### bridge, PCIe/SDIO 및 target policy

`mlinux/moal_bridge.c`는 build object이며 runtime switch, pending identity,
RX/TX fast path, init/deinit, owner suspend/resume 및 reset cleanup이 하나의 lifecycle을
이룬다. keep-power suspend가 `netif_device_detach()`를 사용하므로 bridge readiness는
running/carrier/registration뿐 아니라 `netif_device_present()`도 요구한다.

PCIe FLR/AER, SDIO in-band/reset 및 generic firmware recovery는 participating
handle을 재구성한 뒤 bridge owner를 복구한다. destructive recovery 실패는 terminal
state지만 cold add-card의 bridge init 실패는 WLAN을 계속 허용한다. source에서 두
정책을 하나로 합쳐야 한다는 target contract는 없으므로 그 차이를 보존했다. 이는
source architecture BLOCK이 아니며, 실제 board/firmware에서 확인할 target WATCH다.

### UAP/AGCS, VHT/HE, ratebitmap 및 build defaults

- UAP SNMP channel-track, AGCS와 channel-switch-count helper는 정확한 upstream
  command/selector를 한 정의씩 유지한다.
- VHT map round-trip은 저장된 map을 보존하고 association IE path의 NSS clamp는
  유지한다.
- HE power SET/GET은 HE 20/40/80 MHz 및 NSS1/2 selector를 encode/decode하고
  firmware mode와 host lower-bound policy를 보존한다.
- `ratebitmapcfg`는 DSSS/OFDM/HT/VHT/HE를 포함한 26-word GET/SET pair를 유지한다.
- top-level direct make에서만 external-module default goal을 선택하고 Kbuild
  submake에는 존재하지 않는 goal을 전파하지 않는다.

## QA gate와 warning 상태

`make upstream-port-check`는 다음을 반복 가능한 한 gate로 묶는다.

1. `scripts/tests/upstream_port_invariants.py` lifecycle/ABI/boundary assertions;
2. real bundled CLI와 ioctl capture shim을 사용한 `antcfg_cli_qa.sh`;
3. default i.MX93 build의 userspace-clean ordering을 실행하는 `make_for_imx93_qa.sh`;
4. adversarial bridge static/mutation suite;
5. mirrored `mlan_ioctl.h` byte comparison.

fresh final run은 exit 0이며 최소 다음 결과를 포함했다.

```text
upstream_port_invariants=PASS
antcfg_cli_qa=PASS
make_for_imx93_qa=PASS
upstream_port_final_checks=PASS
```

bridge suite의 quiet-`grep` nondeterminism은 source assertion 실패가 아니라
`set -o pipefail`에서 early-exit `grep`가 producer에 SIGPIPE를 주던 harness
결함이었다. `1dd14bf`는 fixed/extended quiet predicates를, `3b9c8f8`은 남은
plain quiet predicates와 binary `strings` symbol check를 deterministic input
형태로 바꿨다. assertions/mutations와 full-consuming awk/tr pipelines는 바꾸지
않았다. `734f75b`의 fresh aggregate run도 bridge mutation suite 전체를 포함해 exit
0이었고 `upstream_port_final_checks=PASS`로 종료했다.

초기 build warning 중 다음 source warning은 모두 수정되었다.

- `woal_rx_acct_max` missing prototype;
- 1,120-byte `mgmt_log_printf` frame;
- unused PCIe `woal_do_flr` wrapper;
- unused SDIO `woal_do_sdiommc_flr` wrapper.

최종 build를 **warning-free**라고 부르지 않는다. 같은 GCC 12.3.0이라도 kernel은
`x86_64-linux-gnu-gcc-12`, 현재 build는 `gcc-12` 이름으로 실행되어 다음 warning이
남는다.

```text
warning: the compiler differs from the one used to build the kernel
  The kernel was built by: x86_64-linux-gnu-gcc-12 (Ubuntu 12.3.0-1ubuntu1~22.04.3) 12.3.0
  You are using:           gcc-12 (Ubuntu 12.3.0-1ubuntu1~22.04.3) 12.3.0
```

host에 `vmlinux`가 없어 두 module의 BTF generation도 skip된다. 이는 compiler
warning은 아니지만 BTF evidence가 없다는 환경 한계다.

`83c121f..1e2e4a3` follow-up production diff에 대한 kernel
`checkpatch.pl --no-signoff` 결과는 **0 errors, 2 warnings**다. 두 건은 새 bounded
retry가 기존 4.13 compatibility branch 안에 들어가면서 보고되는
`LINUX_VERSION_CODE`/`CONSTANT_COMPARISON` warning pair다. 전체 reconciliation
뒤의 OTP production-only range `9a7bf31..1499c4c`은 **0 errors, 0 warnings,
8 lines checked**다. 전체 reconciliation production range
`45f593e..1499c4c`은 **0 errors, 21 warnings**이며, 이 중 14건은
4.13/5.14 호환 전처리 pair, 7건은 기존에 널리 사용되는 field identifier
`fw_reseting`의 spelling warning이다. 호환 kernel range와 기존 field 이름을
유지하기 위해 남겼다.

SDIO lifecycle production/test diff `50cbe67..812a65b`의 kernel
`checkpatch.pl --no-tree --no-signoff` 결과는 **0 errors, 0 warnings, 922 lines
checked**다.

후속 terminal-lifetime diff `80dc848..734f75b`의 같은 checkpatch 결과는
**0 errors, 4 warnings, 506 lines checked**다. 네 warning은 multi-kernel compatibility를
위해 추가된 두 `LINUX_VERSION_CODE > KERNEL_VERSION(4, 11, 0)` 분기에서 발생한
`LINUX_VERSION_CODE`/`CONSTANT_COMPARISON` pair다. 최종 callback-barrier follow-up
`e526b8b..734f75b`만 검사하면 **0 errors, 0 warnings, 135 lines checked**다.

## Fresh final validation evidence

### Second target-staged i.MX93 cross-build (source `f11420820bc73196eee837a9896f120b86364b57`; failed activation, now inactive)

final-review fix를 포함한 immutable source commit에서 exact `./make_for_imx93.sh`를
host/controller에서 실행했고 exit `0`을 기록했다. 다음 네 artifact는 이후 target에
stage/install되어 bounded activation을 시도했지만 firmware init gate에서 실패했고,
reboot 뒤 baseline으로 복구됐다.

| artifact | bytes | SHA-256 | vermagic / version |
|---|---:|---|---|
| `bin_wlan/mlan_imx93.ko` | 992,720 | `0c0347b6ef08ae0d605655b62e70121440d0f0961277d25f5eb27fe4b595b396` | `6.6.3-lts-next-gccf0a99701a7-dirty SMP preempt mod_unload modversions aarch64`; `543.p18` |
| `bin_wlan/moal_imx93.ko` | 1,978,536 | `f7155dc139c6a4f976d08815596937ddb8083b8856037bf7b58a29371ba81af3` | `6.6.3-lts-next-gccf0a99701a7-dirty SMP preempt mod_unload modversions aarch64`; `543.p18` |
| `bin_wlan/mlanutl_imx93` | 400,968 | `127912311df9397df9104cf8fe96f4501ecc1edf9df67007d54af6f95c2ae4a3` | ARM aarch64 executable; version not embedded as a module field |
| `bin_wlan/mlanevent_imx93` | 68,144 | `3523a73a544627d3ceae7f3c7ed57cdf19df8a04882b0d0ea14c69bde95dbd05` | ARM aarch64 executable; version not embedded as a module field |

두 module은 ARM aarch64 relocatable ELF이고 두 userspace artifact는 ARM aarch64
executable이다. build에는 기존 `mlanutl` warning 3건(unchecked `fgets`, fortified
`memcpy` bounds, fortified `strncpy` bounds)이 남았으며 warning-free로 표현하지
않는다. host에 `vmlinux`가 없어 BTF generation은 skip되었다.

### Corrected transport-binding i.MX93 cross-build (source `e1c9f49bb6ec8ffd0dc9703909ff4ef823a76436`; host-only)

잘못된 wake-binding alias를 제거한 exact source에서 `./make_for_imx93.sh`를 다시 실행해
exit `0`을 기록했다. 이 artifact는 fail-fast source/build evidence이며 target에는
stage/install/load하지 않았다.

| artifact | bytes | SHA-256 | vermagic / version |
|---|---:|---|---|
| `bin_wlan/mlan_imx93.ko` | 992,720 | `0c0347b6ef08ae0d605655b62e70121440d0f0961277d25f5eb27fe4b595b396` | `6.6.3-lts-next-gccf0a99701a7-dirty SMP preempt mod_unload modversions aarch64`; `543.p18` |
| `bin_wlan/moal_imx93.ko` | 1,978,448 | `482de059b6c1ee2c9c8145c326efbecd8341a5bc0ef5eebde905908a0dc5f498` | `6.6.3-lts-next-gccf0a99701a7-dirty SMP preempt mod_unload modversions aarch64`; `543.p18` |
| `bin_wlan/mlanutl_imx93` | 400,968 | `127912311df9397df9104cf8fe96f4501ecc1edf9df67007d54af6f95c2ae4a3` | ARM aarch64 executable |
| `bin_wlan/mlanevent_imx93` | 68,144 | `3523a73a544627d3ceae7f3c7ed57cdf19df8a04882b0d0ea14c69bde95dbd05` | ARM aarch64 executable |

production/test diff checkpatch 결과는 0 errors, 0 warnings, 97 lines checked다. build에는
동일한 known `mlanutl` warning 3건이 남는다.

### Historical controller external-module build (source `3b9c8f8d7a06552bce3d94aa8b7967be04eb5f18`; host-only)

clean external-module build는
`/lib/modules/6.8.0-111-generic/build`, `ARCH=x86_64`에서 exit 0이었다.
기본 `DUMP_TO_PROC` build에서 제외되는 file-dump와 console-read 경로도
`CONFIG_DUMP_TO_PROC=n EXTRA_CFLAGS=-DFWDUMP_VIA_PRINT` clean build로 별도 실행하여
exit 0을 확인했다. `.moal_main.o.cmd`에는 `-DFWDUMP_VIA_PRINT`가 있고
`-DDUMP_TO_PROC`가 없음을 확인했다. 이어진 기본 clean build의 같은 command file에는
반대로 `-DDUMP_TO_PROC`만 있음을 확인했다.

| artifact | bytes | SHA-256 | vermagic |
|---|---:|---|---|
| `mlan.ko` | 1,969,752 | `516d4cf1dee073f190d5341f5d26326796bceb76a5ebe2fb8602d99adb0827e0` | `6.8.0-111-generic SMP preempt mod_unload modversions` |
| `moal.ko` | 3,181,464 | `9bbd983fdcc172c28ddb939d96c9b3b82f1ca3f6fe8132b43365106f4c01f68b` | `6.8.0-111-generic SMP preempt mod_unload modversions` |

이 hash/size/vermagic는 fresh controller artifact evidence이며 module load 또는
target traffic pass를 뜻하지 않는다.

### Historical target evidence (source `734f75bf02a3e5ac4c84a696d8a873ed11247ce3`)

이 섹션의 artifact와 runtime 결과는 exact source `734f75bf02a3e5ac4c84a696d8a873ed11247ce3`에
한정된 과거 in-band evidence이다. Yocto SDK
`/shared/fsl-imx-wayland/6.6-nanbield`와 다음 i.MX93 kernel tree에서 기본 경로를
실행했다.

```text
/opt/sda/imx93/imx-6.6.3-1.0.0-build/build_fsl-imx-wayland/tmp/work/imx93_11x11_lpddr4x_evk-poky-linux/linux-imx/6.6.3+git/linux-imx-6.6.3+git
```

```text
rtk ./make_for_imx93.sh  # exit 0
```

host CLI QA가 x86-64 objects를 남긴 직후에도 script가 두 userspace tree를 clean하고
다음 산출물을 aarch64로 다시 생성했다.

| artifact | bytes | SHA-256 |
|---|---:|---|
| `bin_wlan/mlan_imx93.ko` | 992,720 | `0c0347b6ef08ae0d605655b62e70121440d0f0961277d25f5eb27fe4b595b396` |
| `bin_wlan/moal_imx93.ko` | 1,978,680 | `569a0cb30a4b08689def8405fd84122ac36f7f924c8fe7d59948b25cda16d7f5` |
| `bin_wlan/mlanutl_imx93` | 400,968 | `127912311df9397df9104cf8fe96f4501ecc1edf9df67007d54af6f95c2ae4a3` |
| `bin_wlan/mlanevent_imx93` | 68,144 | `3523a73a544627d3ceae7f3c7ed57cdf19df8a04882b0d0ea14c69bde95dbd05` |

두 module은 ARM aarch64 relocatable ELF이고 `moal_imx93.ko` vermagic은
`6.6.3-lts-next-gccf0a99701a7-dirty SMP preempt mod_unload modversions aarch64`다.
userspace binary 둘도 ARM aarch64 ELF다. cross `mlanutl` compile에는 기존 코드의
`fgets` return-value 1건과 fortified `memcpy`/`strncpy` array-bound 2건, 총 3개
warning이 남으므로 이 target build를 warning-free라고 부르지 않는다. 이 증적은
cross-build 성공이지 module load나 hardware runtime pass가 아니다.

#### Bounded i.MX93 SD9098 in-band runtime

controller 기준 2026-08-21에 private wired-management path로 검증했다. target clock은
2026-08-17로 어긋나 있으므로 evidence 파일의 wall-clock보다 marker와 module hash를
판정 기준으로 사용했다. target은 NXP i.MX93 11x11 EVK, aarch64,
`6.6.3-lts-next-gccf0a99701a7-dirty`이고, SSH return route는 WLAN이 아닌 `eth0`였다.
따라서 reload 중 mlan0 연결 손실이 controller control path를 숨기지 않았다.

SD9098은 같은 MMC card의 function 1/2로 probe되었다. `mlan0`은 설정상 활성 STA,
`mlan1`은 설정상 비활성 companion이므로 검증 상태는 `mlan0 UP/connected`,
`mlan1 present/DOWN`이다. firmware는 `cts/sd9098_wlan_v1.bin`, runtime version은
`17.92.1.p149.115 ... MM6X17543.p18 ... FP92`였다.

배포 전에는 기존 `/opt/wlan` 네 artifact와 설정/상태를 별도 보존했다. original
baseline backup과 이번 수정 직전 543.p18 backup을 모두 남겼고, 각 reload에는
systemd transient rollback timer를 먼저 걸었다. 해당 이전 slice의 성공 판정 뒤 timer는 모두 중지했으며
그 slice 종료 시 target file/module 상태는 다음과 같았다.

| 항목 | 결과 |
|---|---|
| loaded `mlan`/`moal` version | `543.p18` / `543.p18` |
| active `mlan_imx93.ko` SHA-256 | `0c0347b6ef08ae0d605655b62e70121440d0f0961277d25f5eb27fe4b595b396` |
| active `moal_imx93.ko` SHA-256 | `569a0cb30a4b08689def8405fd84122ac36f7f924c8fe7d59948b25cda16d7f5` |
| module vermagic | exact target `6.6.3-lts-next-gccf0a99701a7-dirty ... aarch64` |
| services | `wifi_init`, `wpa_supplicant@mlan0`, `wifi_bridge@mlan0`, `wifi_logger_temp` active |
| rollback timer | inactive; persistent backups present |

최종 `734f75b` 배포에서는 검증된 `812a65b`에서 새 후보로 한 번 전환하고, 이어서
새 후보를 자기 자신으로 한 번 더 reload했다. 두 cycle 모두 실제 서비스 상태처럼
`wifi_logger_temp`를 active로 유지했다. old-to-new는 20초, new-to-new는 19초에 service
restart와 STA reconnect가 완료되었다. 첫 marker 이후 dmesg에서
`FUNC_SHUTDOWN [0xaa]` timeout, `DS_GET_SENSOR_TEMP [0x227]` timeout, `BUG`, `WARNING`,
`Oops`, `Call Trace`, `KASAN`, `lockdep`, `use-after-free`, `general protection fault`
match는 모두 0이었다.

두 interface의 `mlanutl ... version`은 exit 0으로 같은 FP92/543.p18 version을
반환했다. target-test ping과 별도 stabilized final-health ping은 모두 20/20, 0% loss였고
마지막 평균은 1.820ms였다.
최종 mlan0은
SSID 연결과 `LOWER_UP`, mlan1은 의도한 disabled/DOWN 상태를 유지했다.

해당 이전 slice의 backup과 raw target evidence는 private target storage에
보존했고 repository에는 추가하지 않았다. 이 historical state는 위 OOB closure의
restored-backup 최종 상태와 runtime classification으로 supersede된다.

이 결과가 증명하는 범위는 SDIO in-band unload/reload, DBDC enumeration, STA reconnect,
version CLI와 짧은 ICMP smoke다. OOB interrupt mode, suspend/resume, SDIO reset/FLR,
장시간 traffic, uAP/RF/management stress는 실행하지 않았으므로 PASS에 포함하지 않는다.
active module configuration은 `intmode`를 지정하지 않아 default `intmode=0`이고,
`/proc/interrupts`에는 board wake용 `wifi_oob_wakeup`만 있으며 driver action
`nxp_oob_sdio_irq`는 없었다. 따라서 `734f75b`의 OOB token/failure 경로는 compile/static
검증만 있으며 이 target run으로 runtime 증명되지 않는다.

### Userspace와 mirrored headers

```text
rtk make -C mapp/mlanutl clean  # exit 0
rtk make -C mapp/mlanutl        # exit 0
```

fresh `mlanutl` build는 compiler warning 없이 완료되었지만 device ioctl은 host에서
실행하지 않았다.

| mirrored pair | SHA-256 (양쪽 동일) |
|---|---|
| `mlan/mlan_ioctl.h`, `mlinux/mlan_ioctl.h` | `1017200d01782ca52ae497c9a73341a1602e9c54d2c7afcd2811bf88cc946cfb` |
| `mlan/mlan_decl.h`, `mlinux/mlan_decl.h` | `7966a2839838078ef363b79d75482a9a064b8f814f979913f81a38da916110c8` |

### Topology, markers 및 whitespace

- exact upstream tip/base ancestry: exit 0;
- latest `origin/main` ancestry: exit 0;
- clean-port first-parent merge count: `2` (upstream integration `cc7f79d`, latest-main reconciliation `45f593e`);
- exact conflict-marker match count: `0`;
- reconciliation/source range `45f593e..734f75b`의 `git diff --check`: exit 0;
- documentation commit을 포함한 `45f593e..HEAD`도 post-commit check로 확인한다.

whole local integration range의 default check는 별개다.

```text
rtk proxy git diff --check ce179fcc8a82f4ce41e70ffadc65c966a7a1565d..HEAD
```

exit 2이며, 이유는 upstream이 포함한
`mlinux/iw610_sdio_over_spi_linux.patch`의 25, 26, 27, 30, 31, 32행에 있는
`space before tab` 여섯 건뿐이다. embedded patch context를 수정하지 않는다.

```text
rtk proxy git -c core.whitespace=-space-before-tab diff --check ce179fcc8a82f4ce41e70ffadc65c966a7a1565d..HEAD
```

해당 whitespace class만 비활성화하면 exit 0이다.

### Runtime scripts: non-evidence

fresh `bridge_runtime_switch_qa.sh`는 uid `1003`의 non-root 실행이어서 exit 1,
`FAIL: run as root`에서 device/network mutation 전에 중단했다. pass가 아니다.

keepalive target script는 `/lib/modules/$(uname -r)/extra/moal_imx93.ko`를 load할
수 없었고 `dmesg`도 읽을 수 없었다. controller가 non-evidence run으로 종료했으며
pass 또는 유효한 target result로 기록하지 않는다.

## Side-effect matrix

| subsystem | final source policy | residual WATCH | required target validation |
|---|---|---|---|
| USB URB | shared submit/stop lock, final pre-unregister drain, controlled reopen | unplug/suspend/reload interleaving | traffic 중 unplug/unload/suspend, resubmit fault, mode reload, KASAN/lockdep |
| bridge | compiled lifecycle, pending identity, owner suspend/resume, detached-device readiness, ordered recovery handoff | cold-start fail-open 대 destructive recovery terminal policy | runtime switch, DBDC, peer delete/recreate, recovery, traffic |
| PCIe/SDIO | canonical deferred-FLR gate, referenced devices, locked reset, remove invalidation, owner restoration, module-exit SDIO command-response lifetime, per-action OOB disable token, process-context coalescing release, transactional source teardown, terminal software-detach와 MMC-host callback barrier | reset concurrent with PM/unbind/rebind, ordered-queue lock contention/latency; generic terminal all-hardware-fail shared level-source liveness | historical `734f75b` i.MX93 SDIO in-band reload만 bounded slice에서 통과; PCIe FLR/AER와 실제 transport-event line을 지원하는 다른 hardware의 SDIO/OOB stress 필요 |
| management/proc | typed/bounded event, consumer length gates, heap ring scratch, mode 0600 diagnostics, root-owner-write config mode 0644, card-lifetime writer transaction, exact command/OTP delimiter boundaries, per-handle dump pathname snapshots | unload/read, frame-volume/privacy, synchronous dump I/O와 whole-dump allocation | host-MLME/P2P delivery, dump path failure, wrap/clear, concurrent proc read/unload |
| antenna/NSS | exact forms, layout-aware four-word rejection, GET-only NSS command | firmware/association convergence | 2.4/5/6 GHz, 1x1/2x2, repeated GET, roam/reboot |
| UAP/AGCS | single exact upstream command helpers | firmware selector behavior | channel-track, AGCS, channel-switch count command trace |
| VHT/HE/rate | stored-map round-trip, HE encode/decode, 26-word bitmap | firmware persistence/power-table variance | association IE, HE groups 0–14, reconnect persistence |
| build/QA | clean module/userspace builds, host/target app-object isolation, deterministic static gate, i.MX93 cross-build/load | board별 firmware/transport environment | historical `734f75b` i.MX93 SD9098 load/version/ping PASS; corrected `e1c9f49`는 host-only; 나머지 board/transport 필요 |

## `mapp/` ownership boundary

`mapp/` 전체는 core driver와 별도의 product userspace overlay다. 이 review가
code-level로 reconciled하고 실제 build/serialization evidence를 가진 범위는
`mapp/mlanutl`의 `antcfg`/`antcfgnss`, 6 GHz fields, `ratebitmapcfg`, HE power
decoding 및 standalone STA/UAP build다.

그 밖의 `mapp/` tools, configs, documents는 tree에 존재하거나 bundled build에
포함된다는 이유만으로 검증되었다고 보지 않는다. 해당 product tool마다 별도 owner,
ABI review 및 target execution evidence가 필요하다.

## 남은 runtime exit gates와 hardware exclusion

historical source `734f75bf02a3e5ac4c84a696d8a873ed11247ce3`인 과거 target slice에서 old-to-new/
new-to-new in-band module reload 2회, DBDC interface enumeration, STA reconnect,
version CLI와 짧은 traffic smoke가 통과했다. corrected current source `e1c9f49`는
target에 stage하지 않았다. 다음 항목은 여전히 미통과/미실행 gate 또는 명시적 hardware
exclusion이며 이 문서는 그 범위의 hardware pass를 주장하지 않는다.

1. USB disconnect/unplug, unload, suspend traffic, resubmit failure, firmware
   reload/mode rebuild, pending counters, KASAN/lockdep.
2. PCIe FLR/AER/in-band reset을 bridge active, suspend/unload 및 unbind/rebind 경쟁과
   함께 실행하고 stale worker가 새 binding/status를 바꾸지 않는지 확인.
3. SDIO OOB mode, reset/FLR, driver-mode rebuild 및 bridge owner restore는 실제
   transport-event line을 지원하는 다른 hardware의 generic implementation gate다.
   88W9098 target에는 `NOT_APPLICABLE / BLOCKED_BY_HARDWARE_CAPABILITY`이며 target gate가
   아니다. 일반 in-band module unload/reload command-response gate는 i.MX93에서 통과했다.
4. USB/PCIe/SDIO suspend/resume를 traffic과 pending bridge switch에 결합.
5. STA/uAP association, roaming, AP start/stop, host-MLME/P2P management masks.
6. UAP channel-track/AGCS/channel-switch-count GET/SET 및 firmware trace.
7. 1x1/2x2, 2.4/5/6 GHz `antcfg` SET/GET, `antcfgnss`, repeated GET,
   association/roam/reboot convergence.
8. VHT map round-trip/association IE 및 HE power groups 0–14,
   20/40/80 MHz, NSS1/2, low-dBm, reconnect.
9. 26-word ratebitmap GET/SET, HT/VHT/HE ratemax 및 persistence.
10. management event maximum boundary, frame delivery, ring wrap/clear,
    hex dump, log volume/privacy, concurrent proc read/unload.
11. bridge runtime switch, DBDC primary/companion 동시 mode-4 proc write, peer
    delete/recreate, cold-start/recovery policy, sustained traffic, KASAN/lockdep.

## 최종 결론

clean port는 exact upstream ancestry를 보존하고 old replay corruption을 재도입하지
않았다. 원 code-review BLOCK과 scoped source residual은 수정되었고, clean module/
userspace build와 deterministic static QA가 fresh evidence로 남아 있다. 그러나
transport teardown, firmware command semantics, association/RF policy 및 bridge
ownership은 target firmware/board/topology가 필요하다.

따라서 현재 상태는 **host/source validation complete at `e1c9f49`, invalid-alias
candidate activation FAIL, corrected target transport OOB NOT_APPLICABLE /
BLOCKED_BY_HARDWARE_CAPABILITY, architecture WATCH for the generic implementation,
target OOB traffic qualification NOT_APPLICABLE / BLOCKED_BY_HARDWARE_CAPABILITY,
cleanup COMPLETE/ACCEPTED**다. 이전 `734f75b` SD9098 in-band reload/STA smoke PASS는 historical
bounded slice로 유지되지만 c464/f114 attempt의 OOB, PM 또는 long-traffic PASS로
승격되지 않는다. terminal
all-hardware-failure item도 별도
`BLOCKED_BY_PLATFORM`이며 static/live substitute는 physical-source quiescence를 증명하지
않는다. USB와 PCIe는 `BLOCKED_BY_HARDWARE`다.

최종 target은 restored pre-qualification in-band `543.p18` backup이고 c464/f114
candidate는 inactive/unqualified다. corrected `e1c9f49` artifact는 target에 전송하지
않았다. 타겟은 `intmode=0`을 유지하며 OOB 재시도, wake-node alias, BSP/DTB 수정 또는
추가 maintenance window를 진행하지 않는다. 범용 OOB source는 실제 지원 hardware를
위해 보존한다. Draft PR #27은 Draft로 남아야 하며 merge-ready 판정을 하지 않는다.
