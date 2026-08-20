# mwifiex 0396cfb→2e481212 Clean Port 최종 코드 검토

## 판정 범위와 최종 상태

이 문서의 최종 **source/test validation HEAD**는
`3b9c8f8d7a06552bce3d94aa8b7967be04eb5f18`이다. 이 문서를 갱신하는 후속
documentation commit은 source/test 파일을 바꾸지 않으므로 코드 판정 기준은 계속
`3b9c8f8`이다.

최종 판정은 **host/source validated, architecture WATCH, target-runtime open**이다.
초기 독립 검토가 BLOCK으로 분류한 source-proven USB submit-after-kill 결함과 후속
scoped re-review가 찾은 두 source residual은 수정되었다. 따라서 source BLOCK은
해소되었지만 USB/bridge lifecycle과 firmware/board별 정책은 target에서만 판정할 수
있으므로 architecture 상태는 CLEAR가 아니라 **WATCH**다. 후속 residual 수정 뒤
별도의 독립 reviewer가 `APPROVE`를 발행한 것은 아니며, 이 문서는 그런 승인을
주장하지 않는다.

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

`cc7f79d`는 local parent `ce179fcc`와 exact upstream tip `2e481212`를 부모로
갖는 non-fast-forward merge다. clean-port first-parent 범위의 integration merge는
정확히 하나이며, upstream base와 tip 모두 최종 HEAD의 ancestor다. 이 topology는
release snapshot을 다시 cherry-pick하지 않고 양쪽 history를 보존한다.

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

이 chronology는 fresh controller verification을 기록하지만, post-residual 독립
`APPROVE`로 승격하지 않는다. 최종 architecture 결론은 **WATCH, not BLOCK**이다.

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

### bridge, PCIe/SDIO 및 policy WATCH

`mlinux/moal_bridge.c`는 build object이며 runtime switch, pending identity,
RX/TX fast path, init/deinit, owner suspend/resume 및 reset cleanup이 하나의 lifecycle을
이룬다. keep-power suspend가 `netif_device_detach()`를 사용하므로 bridge readiness는
running/carrier/registration뿐 아니라 `netif_device_present()`도 요구한다.

PCIe FLR/AER, SDIO in-band/reset 및 generic firmware recovery는 participating
handle을 재구성한 뒤 bridge owner를 복구한다. destructive recovery 실패는 terminal
state지만 cold add-card의 bridge init 실패는 WLAN을 계속 허용한다. source에서 두
정책을 하나로 합쳐야 한다는 target contract는 없으므로 그 차이를 보존했다. 이는
BLOCK이 아니라 명시적 architecture WATCH다.

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
3. adversarial bridge static/mutation suite;
4. mirrored `mlan_ioctl.h` byte comparison.

fresh final run은 exit 0이며 최소 다음 결과를 포함했다.

```text
upstream_port_invariants=PASS
antcfg_cli_qa=PASS
upstream_port_final_checks=PASS
```

bridge suite의 quiet-`grep` nondeterminism은 source assertion 실패가 아니라
`set -o pipefail`에서 early-exit `grep`가 producer에 SIGPIPE를 주던 harness
결함이었다. `1dd14bf`는 fixed/extended quiet predicates를, `3b9c8f8`은 남은
plain quiet predicates와 binary `strings` symbol check를 deterministic input
형태로 바꿨다. assertions/mutations와 full-consuming awk/tr pipelines는 바꾸지
않았다. 최종 반복 결과는 direct bridge suite **20/20**, aggregate
`upstream-port-check` **3/3** 연속 성공이다.

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

## Fresh final validation evidence

### External modules

clean external-module build는
`/lib/modules/6.8.0-111-generic/build`, `ARCH=x86_64`에서 exit 0이었다.

| artifact | bytes | SHA-256 | vermagic |
|---|---:|---|---|
| `mlan.ko` | 1,969,752 | `516d4cf1dee073f190d5341f5d26326796bceb76a5ebe2fb8602d99adb0827e0` | `6.8.0-111-generic SMP preempt mod_unload modversions` |
| `moal.ko` | 3,161,160 | `5099d6d27e069cceec7328af3040427d748864cb11d8577b2a7afc1901ac247f` | `6.8.0-111-generic SMP preempt mod_unload modversions` |

이 hash/size/vermagic는 fresh controller artifact evidence이며 module load 또는
target traffic pass를 뜻하지 않는다.

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
- clean-port first-parent merge count: `1` (`cc7f79d`);
- exact conflict-marker match count: `0`;
- fix range `760908e..3b9c8f8`의 `git diff --check`: exit 0;
- documentation commit을 포함한 `760908e..HEAD`도 post-commit check로 확인한다.

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
| bridge | compiled lifecycle, pending identity, owner suspend/resume, detached-device readiness | cold-start fail-open 대 destructive recovery terminal policy | runtime switch, DBDC, peer delete/recreate, recovery, traffic |
| PCIe/SDIO | reset/FLR producer gates와 owner restoration | reset concurrent with PM/unload | PCIe FLR/AER/in-band 및 SDIO/OOB reset stress |
| management/proc | typed/bounded event, consumer length gates, heap ring scratch, mode 0600 | unload/read와 frame-volume/privacy | host-MLME/P2P delivery, wrap/clear, concurrent proc read/unload |
| antenna/NSS | exact forms, layout-aware four-word rejection, GET-only NSS command | firmware/association convergence | 2.4/5/6 GHz, 1x1/2x2, repeated GET, roam/reboot |
| UAP/AGCS | single exact upstream command helpers | firmware selector behavior | channel-track, AGCS, channel-switch count command trace |
| VHT/HE/rate | stored-map round-trip, HE encode/decode, 26-word bitmap | firmware persistence/power-table variance | association IE, HE groups 0–14, reconnect persistence |
| build/QA | clean module/userspace builds and deterministic static gate | target toolchain/load environment | deployed module load, symbols, traffic |

## `mapp/` ownership boundary

`mapp/` 전체는 core driver와 별도의 product userspace overlay다. 이 review가
code-level로 reconciled하고 실제 build/serialization evidence를 가진 범위는
`mapp/mlanutl`의 `antcfg`/`antcfgnss`, 6 GHz fields, `ratebitmapcfg`, HE power
decoding 및 standalone STA/UAP build다.

그 밖의 `mapp/` tools, configs, documents는 tree에 존재하거나 bundled build에
포함된다는 이유만으로 검증되었다고 보지 않는다. 해당 product tool마다 별도 owner,
ABI review 및 target execution evidence가 필요하다.

## Target-only exit gates

다음 항목은 모두 **미통과 또는 미실행 target gate**이며 이 문서는 hardware pass를
주장하지 않는다.

1. USB disconnect/unplug, unload, suspend traffic, resubmit failure, firmware
   reload/mode rebuild, pending counters, KASAN/lockdep.
2. PCIe FLR/AER/in-band reset을 bridge active 및 suspend/unload 경쟁과 함께 실행.
3. SDIO/OOB reset/FLR 및 bridge owner restore.
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
11. bridge runtime switch, DBDC, peer delete/recreate, cold-start/recovery
    policy, sustained traffic, KASAN/lockdep.

## 최종 결론

clean port는 exact upstream ancestry를 보존하고 old replay corruption을 재도입하지
않았다. 원 code-review BLOCK과 scoped source residual은 수정되었고, clean module/
userspace build와 deterministic static QA가 fresh evidence로 남아 있다. 그러나
transport teardown, firmware command semantics, association/RF policy 및 bridge
ownership은 target firmware/board/topology가 필요하다.

따라서 최종 상태는 **source/test validation complete at `3b9c8f8`, architecture
WATCH, target-runtime gates open**이다. 독립 post-residual APPROVE나 hardware pass로
해석하지 않는다.
