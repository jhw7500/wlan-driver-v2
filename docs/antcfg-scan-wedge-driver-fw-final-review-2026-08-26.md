# `antcfg` scan-return Tx/ACK wedge — Driver/F/W 최종 검토

- 작성일: 2026-08-26 KST
- 대상: i.MX93 / 88Q9098 / `mlan`·`moal`
- 제품 조합: ported driver `543.p18` + F/W `17.92.1.p149.115`
- driver 비교 기준:
  - main `505.p14`: `1ba9fd42b40c8f76b207ec391eec77c171cdcc12`
  - ported `543.p18`: `26400d66cc56e9af0096273b5d25d31d3e001fa6`
- 문서 상태: **FINAL — 시험 정본과 driver source 검토 통합**

이 문서는 테스트 세션의 종합 정본과 driver source 분석을 합쳐, 확인된 사실,
합리적 추론, 미확정 범위 및 driver/F/W별 조치를 하나의 전달 문서로 고정한다.
기존 동결 instrumentation patch/KO는 수정하지 않는다.

정본 입력:

```text
/home/jhw/ai/opencode/projects/wlan-package/.worktrees/wpa-roam-scan-policy/artifacts/CONSOLIDATED_TEST_SUMMARY_20260826.md
SHA-256 de6b6b90618f6c0a4778bb29b4ee3fc374c53357477934d6433a6453ebaa31bd
```

## 1. 최종 판정

### 1.1 현상과 회귀 경계

반복 외부 scan 뒤 Tx data path가 지속적으로 실패하는 현상은 현재 증거 범위에서
다음 조합과 강하게 연관된다.

```text
physical Tx/Rx = 1-path/1-path
host advertised Tx/Rx NSS = 1SS/1SS
F/W = p149.115
off-channel scan 완료
```

동일 main/505.p14 driver, module parameter, calibration, AP, association 및 scan
조건에서 F/W만 교체한 결과 공개 release 경계는 다음과 같다.

```text
p149.88 = good: 60/60 NOT_REPRODUCED
p149.115 = bad: scan 10 REPRODUCED
```

p149.115 실패 때도 association, BSSID, home frequency, beacon RX 및 host queue는
유지됐고 scan request/result도 완료됐다. 반면 F/W가 반환한 ACK failure와 failed
counter가 급증하고 outbound ping이 중단됐다.

### 1.2 책임 경계

| 영역 | 최종 판정 | 신뢰도 |
|---|---|---:|
| userspace → ioctl → RF_ANTENNA HostCmd 인자 전달 | 정상 확인 | 높음 |
| main antcfg 커스터마이징의 ported 반영 | 핵심 동작 유지, userspace 조회 ABI만 적응됨 | 높음 |
| association/scan completion 및 host queue | 장애 중 정상 상태 | 높음 |
| 공개 F/W release 회귀 분류 | p149.88 good → p149.115 bad | 높음 |
| 정확한 F/W 내부 결함 | scan-return Tx/RF/ACK 복구 경로 우선, 세부 지점 미확정 | 중간 |
| 신규 production driver 수정 필요성 | **직접 근거 없음** | 높음 |

최종 조치 문구는 다음과 같다.

> **추가 driver 수정 근거 없음. p149.88 → p149.115의 F/W-dependent
> scan-return Tx/ACK 회귀로 외부 F/W 팀에 전달한다.**

이는 통제 A/B에 따른 release regression 분류다. F/W 내부 단독 결함의 정확한
register/state 또는 AP와의 ACK 상호작용까지 확정했다는 뜻은 아니다.

### 1.3 제품 결정

p149.115를 유지해야 하는 현재 제품에서는 physical RF 2-path를 유지하고 host Rx
NSS intent만 1SS로 제한하는 다음 우회를 유지한다.

```bash
mlanutl mlan0 mcstiercfg ht 7 vht 7 he both 7
mlanutl mlan0 antcfg 0x0303 0x0101
```

검증된 실효 상태:

```text
physical Tx/Rx = 0x0303/0x0303
host user_htstream = 0x2121
advertised/observed Rx NSS = 1
HT/VHT/HE MCS = 7 이하
```

이 조합은 cold boot, reassociate, package migration, 60-scan gate, Mode A 악조건 및
장시간 로밍 시험에서 wedge가 재현되지 않았다. 다만 이 안정성 판정은 아래에 명시한
exact driver/F/W/utility/package에 한정한다.

## 2. 시험 증거

### 2.1 Driver/F/W 조합

| Driver | F/W | 조건 | 결과 |
|---|---|---|---|
| 505.p14 | p149.81 | `antcfg 0x0101` | active 60회, passive 30회, 다채널 30회 미재현 |
| 505.p14 | p149.84 | `antcfg 0x0101`, 4채널 | 60/60 미재현 |
| 505.p14 | p149.88 | `antcfg 0x0101`, 4채널 | 60/60 미재현 |
| 505.p14 | p149.115 | `antcfg 0x0101`, 4채널 | scan 7 또는 정본 bisect scan 10에서 재현 |
| 543.p18 | p149.115 | `antcfg 0x0101` | scan 4, 5, 27, 32 등에서 반복 재현 |

재현 횟수는 4~32회로 변동한다. 따라서 5~10회 통과는 안정성 근거로 사용하지 않고
60-scan을 최소 bounded gate로 사용한다. p149.88의 60/60 통과 역시 임의의 장시간
동안 절대 발생하지 않는다는 수학적 증명은 아니다.

정본 bisect:

```text
/home/jhw/ai/opencode/projects/wlan-package/.worktrees/wpa-roam-scan-policy/artifacts/fw-bisect-505-antcfg-only-20260826/FW_BISECT_RESULT_20260826.md
SHA-256 939a04ca6c240c60df2e24e1eabaa1de31a5cf6e2653dabceac10dd64909f8e8
```

p149.115 정본 archive:

```text
/home/jhw/ai/opencode/projects/wlan-package/.worktrees/wpa-roam-scan-policy/artifacts/fw-bisect-505-antcfg-only-20260826/runs/main505-p149115-antcfg-only-run1/main505-p149115-antcfg-only-run1.tar.gz
SHA-256 b927c072dfd0efd24fcd4a505877d3ebda919e2ecfbaa039afc7b3e1bf2dd5e0
```

### 2.2 장애 서명

p149.115 재현 시 공통 상태:

- `wpa_state=COMPLETED`, 동일 SSID/BSSID/frequency 유지
- disconnect/authentication error/FW reset/CMD timeout 없음
- external scan request/result 정상 완료
- carrier on, netdev queue started
- qdisc/MOAL/MLAN/WMM pending 0
- `scan_processing=0`
- F/W current channel은 home channel로 복귀
- beacon 수신 지속
- `dot11ACKFailureCount`가 먼저 급증
- `dot11FailedCount`와 station `tx failed`가 뒤이어 급증
- outbound ping 실패

505.p14+p149.115 정본 run의 delta는 다음과 같다.

| 지표 | delta |
|---|---:|
| standard failed | 2,422 |
| ACK failure | 24,221 |
| retry | 1 |
| external scan/result | 10/10 |

ACK failure/failed 비율은 약 10:1이다. 이는 이전 543.p18 계측에서 관찰한
frame당 ACK 실패 10회 뒤 discard 서명과 일치한다. `retry`가 1인 것은 이 값들이
서로 다른 F/W GET_LOG counter이므로 반증이 아니다.

### 2.3 변수 분리

| 조건 | 판정 |
|---|---|
| `wifi_init` 프로세스 자체 | 필요조건 아님 |
| bridge/checker/logger/networkctl/sysctl | 필요조건 아님 |
| 제품 module argument 또는 `ext_scan=2` 단독 | 충분조건 아님 |
| `iw scan` 대 `wpa_cli TYPE=ONLY` | 둘 다 문제 조건에서 재현; requester 우회 불가 |
| Tx 1-path/Rx 2-path | 60/60 미재현; Tx 제한 단독은 충분조건 아님 |
| physical 2-path + host Rx NSS1 | 60+10회 및 제품 장시간 시험 미재현 |
| physical Tx/Rx 동시 1-path | p149.115에서 반복 재현한 강한 cofactor |

아직 user-space 명령으로 physical Rx 1-path 단독 셀을 만들 수 없으므로 physical
Rx 제한 단독 효과와 physical/host symmetric 1x1 상호작용은 분리되지 않았다.

### 2.4 증거 정제

최종 결론에서는 다음 잘못된 run을 제외했다.

- `modinfo -n`만 보고 loaded module을 505.p14로 오인한 437.p3 run
- 다른 505 binary 또는 다른 `mod_para`로 association에 실패한 run
- F/W basename 불일치로 module load 전에 중단된 p149.88 run1
- `wifi_init`만 중지하고 `wifi_checker`가 남았던 준비 오류

정본 bisect는 실제 loaded module/proc identity/SHA-256과 동일 AP/BSSID/설정을
확인한 run만 사용한다.

## 3. Driver source 검토

### 3.1 `antcfg` HostCmd 계약

두 driver의 `RF_ANTENNA` command ID는 `0x0020`이고 기존 2G/5G Tx/Rx field
offset은 동일하다.

| Offset | main/505 | ported/543 |
|---:|---|---|
| `0x08` | `action_tx` | 동일 |
| `0x0a` | `tx_antenna_mode` | 동일 |
| `0x0c` | `action_rx` | 동일 |
| `0x0e` | `rx_antenna_mode` | 동일 |
| `0x10..0x11` | 없음 | 6 GHz Tx/Rx byte 추가 |

`antcfg 0x0303 0x0101`의 Rx 값은 양 branch 모두 offset `0x0e`에 `01 01`로
serialize된다. ported의 총 command size가 16→18 byte로 늘었지만 기존 16-byte
prefix는 같다. 따라서 다음 가설은 배제된다.

- mlanutl 두 번째 인자 유실
- Rx field offset 이동
- endian/serialization 오류로 Tx/Rx 대칭화

소스 기준점:

- main: `mlan/mlan_fw.h:5284-5293`, `mlan/mlan_cmdevt.c:7744-7817`
- ported: `mlan/mlan_fw.h:5491-5504`, `mlan/mlan_cmdevt.c:8483-8558`
- 상세 비교: `docs/main505-ported543-rf-hostcmd-scan-sequence-comparison-2026-08-25.md`

ported의 18-byte RF_ANTENNA command를 p149.115가 공식 지원하는지는 공개 driver
source만으로 보장할 수 없다. 다만 같은 main/505의 16-byte command에서도
p149.115가 재현되고 p149.88은 통과하므로, 18-byte ported ABI는 이번 회귀의
필요조건이 아니다.

### 3.2 Physical antenna와 host NSS intent

`user_htstream`은 RF_ANTENNA wire field가 아니라 SET response를 바탕으로 host가
유지하는 association capability 입력이다.

```text
physical GET Tx/Rx = 0x0303/0x0303
host user_htstream = 0x2121
```

위 두 값은 동시에 존재할 수 있다. GET-only physical response는 host intent를
덮어쓰지 않는다. 따라서 SET exit 0은 요청이 HostCmd 경계에 접수됐음을 뜻하지만
physical GET이 요청값 그대로 유지됨을 보장하지 않는다.

main antcfg/NSS 커스터마이징의 핵심 동작은 ported에도 남아 있다.

- Tx/Rx SET guard가 방향별로 분리됨
- SET response에서만 방향별 `user_htstream` 갱신
- VHT stored MCS map round-trip 보존
- VHT/HE association capability 생성 시 `user_htstream` NSS clamp 적용

그러므로 scan wedge를 “main 커스터마이징 미포팅”으로 귀속할 source 근거는 없다.

### 3.3 mlanutl ABI

| Driver | `antcfg` GET의 4-word 의미 | host NSS 조회 |
|---|---|---|
| main/505 | Tx, Rx, `user_htstream`, reserved | `antcfg` word 2 |
| ported/543 | Tx, Rx, Tx-6G, Rx-6G | 별도 GET-only `antcfgnss` |

main 방식 mlanutl과 ported driver를 섞으면 SET은 정상 전달되면서 NSS 표시만 조용히
누락될 수 있다. 제품에는 driver와 함께 검증·lock된 `mlanutl_imx93`을 배포해야 한다.
이 호환 문제는 관측 문제지만 p149.115 scan wedge의 원인은 아니다.

### 3.4 `mcstiercfg`와 association advertisement

현재 source의 `mcstiercfg` 의미는 다음과 같다.

- `he both 7`의 `both`는 **Tx/Rx 방향이 아니라 2.4 GHz+5 GHz band selector**다.
- HE/VHT Tx와 Rx MCS map은 각각 모두 갱신한다.
- `update_supported_nss_map()`은 이미 NOT_SUPPORTED인 NSS entry를 보존하므로
  VHT/HE supported NSS 개수를 새로 1SS로 clamp하지 않는다.
- `ht 7`은 HT stream mode를 1x1/MCS 0~7로 설정한다. 이것이 F/W rate selection에
  간접 영향을 줄 수 있으나 VHT/HE Rx NSS1을 명시적으로 강제하는 수단은 아니다.

소스 기준점:

- `mapp/mlanutl/mlanutl.c:25200` `parse_he_band()`
- `mapp/mlanutl/mlanutl.c:25229` `update_supported_nss_map()`
- `mapp/mlanutl/mlanutl.c:25744-25890` `process_mcstiercfg()`
- association builder: `mlan/mlan_11ac.c`, `mlan/mlan_11ax.c`

runtime A/B에서 `mcstiercfg` 단독은 HE Tx NSS1/Rx NSS2였고,
`antcfg 0x0303 0x0101`을 추가했을 때 Tx/Rx 모두 NSS1로 관찰됐다. 따라서 Rx NSS1은
antcfg-derived host Rx intent의 직접 효과로 판단한다. 관찰된 Tx NSS1만으로
`mcstiercfg`가 HE Tx NSS를 공식 제한한다고 일반화하지 않는다.

### 3.5 Scan HostCmd와 완료 계약

main/505에서 연결 scan은 다음 source 경계를 사용한다.

- scan command 선택/queue: `mlan/mlan_scan.c:1091-1103`
- `HostCmd_CMD_802_11_SCAN_EXT(0x0107)` 구성: `mlan/mlan_scan.c:5055-5100`
- result/status event ABI: `mlan/mlan_fw.h:4167-4227`
- enhanced terminal status 처리: `mlan/mlan_scan.c:6995-7140`

`ext_scan=2`와 `ENHANCE_EXT_SCAN_ENABLE` capability 조건에서는 enhanced external
scan이 선택된다. p149.88과 p149.115 archive의 driver-visible capability는
동일했다.

```text
p149.88:  fw_cap_info=0xc87cefab / 0x487cefab
p149.115: fw_cap_info=0xc87cefab / 0x487cefab
```

p149.115 onset의 `scan_state=1925(0x785)`는 host가 scan start, enhanced type,
result/last result, status 및 complete bit를 모두 기록했음을 뜻한다.

- state bit 정의: `main@1ba9fd42:mlan/mlan_decl.h:768-778`
- event `0x58`: `EVENT_EXT_SCAN_REPORT`
- event `0x7f`: `EVENT_EXT_SCAN_STATUS_REPORT`

이는 F/W 내부 RF 복구가 정상이라는 증거가 아니라 **host가 terminal event까지 받고
정상 completion bookkeeping을 끝냈다는 증거**다.

status event에는 scan status와 optional TLV만 있고 다음 정보가 없다.

- 최초 HostCmd sequence와 연결할 scan cookie
- PM/null frame의 origin/subtype/PM bit/sequence
- home-channel RF/BB/PLL 및 chain restore 상태
- rate-control context
- 마지막 frame의 상세 ACK 결과

driver는 terminal event가 도착하면 F/W가 연결 채널과 usable Tx context를 이미
복구했다고 신뢰한다. 따라서 driver-visible 암묵적 사후조건은 다음과 같다.

> terminal scan status를 보고하기 전에 associated BSS의 후속 host Tx가 가능한
> RF/channel/rate/ACK context까지 복구되어야 한다.

p149.115는 host-visible completion은 만족하지만 이 사후조건을 위반했을 가능성이
가장 높다.

### 3.6 Tx/ACK counter의 출처와 한계

station `tx_failed`는 F/W GET_LOG response의 `failed` 값이다.

- `mlinux/moal_sta_cfg80211.c:4136-4154`
- `mlan/mlan_sta_ioctl.c:181-198`
- `mlan/mlan_sta_cmdresp.c:684-827`

따라서 p149.115의 ACK/failed 폭증은 host netdev queue retry bookkeeping이 아니라
F/W가 보고한 MAC 통계다.

반면 현재 explicit TX-status ABI는 packet type, token 및
`success/fail/watchdog`만 제공한다.

- `mlan/mlan_ioctl.h:489-505`
- `mlan/mlan_fw.h:1615-1642`

ACK reason, 실제 rate/MCS/NSS/BW, selected Tx chain, ACK-RX chain/RSSI는 host에서
확인할 수 없다. 기존 `FW_TX_STATUS_DIAG reason`은 이 coarse status의 문자열 변환일
뿐 실제 MAC/PHY reason code가 아니다.

### 3.7 QoS index 7 frame origin

543.p18 계측에서는 정상 scan excursion마다 QoS index 7 successful frame이 정확히
2개씩 증가했고, 실패 run의 ACK/failed가 거의 index 7에 집중됐다. 그러나 index 7
자체만으로 frame origin은 확정되지 않는다.

- host null path도 `WMM_HIGHEST_PRIORITY`를 사용한다:
  `mlan/mlan_sta_tx.c:231-330`
- F/W에도 full-power auto-null period가 설정된다:
  `mlan/mlan_cmdevt.c:5361-5366`, `mlan/mlan_sta_cmd.c:272-283`

가능한 origin은 FW scan PM enter/exit, FW auto-null, host null 또는 일반 host
priority-7 frame이다. p149.115 onset의 `ps_mode=0`, `pps_uapsd_mode=0`,
`sleep_pd=0`, `tx_lock_flag=0`은 host PS null 경로의 우선순위를 낮추지만 배제하지는
못한다.

main/505 matching mlanutl에서 q7 배열이 출력되지 않은 관측도 남아 있다.
source상 mlanutl은 `used_len == sizeof(struct eth_priv_get_log)`일 때만 배열을
출력하고 kernel은 `fw_getlog_enable`에 따라 길이를 선택한다.

- `mapp/mlanutl/mlanutl.c:2228-2273`
- `mlinux/moal_eth_ioctl.c:2667-2670`
- kernel proc 직접 출력: `mlinux/moal_debug.c:861-915,1487-1502`

이는 원인 결함이 아니라 관측 ABI gap 후보다. 추가 code 없이 먼저 runtime에서
`/proc/mwlan/adapter0/mlan0/log` 존재 여부와 q7 배열을 확인할 수 있다.

### 3.8 Driver 수정 판정

현재 다음 production 변경은 하지 않는다.

- scan 완료 후 강제 home-channel restore command
- netdev queue wake 강제 호출
- 자동 disconnect/reassociate recovery
- requester/cfg80211 scan 경로 변경
- antcfg physical mask 또는 `user_htstream` 정책 변경
- 기존 동결 instrumentation patch/KO 덮어쓰기

이 변경들은 관측된 host 상태와 맞지 않으며 F/W 회귀를 은폐하거나 별도 경합을 만들
수 있다. driver source에서 고칠 수 있는 명확한 동작 결함 증거는 현재 없다.

## 4. F/W 검토 및 외부 요청

### 4.1 공개 release 회귀

공개 `imx-firmware` 계보상 p149.88의 parent가 p149.84이고 p149.115의 parent가
p149.88이다. 두 release 사이의 중간 9098 SD F/W blob은 공개되지 않았다.

따라서 현재 가능한 최선의 범위는 다음이다.

```text
last known good: p149.88
first known bad: p149.115
```

정확한 변경 ID와 더 좁은 first-bad build는 외부 F/W 팀의 internal build/CL 없이는
확정할 수 없다.

### 4.2 우선 원인 후보

| 순위 | 후보 | 신뢰도 | 근거 |
|---:|---|---:|---|
| 1 | scan-return 뒤 F/W/MAC/RF Tx 또는 ACK-RX context 복구 실패 | 높음 | terminal scan/association/RX/host queue 정상, ACK/failed만 폭증 |
| 2 | physical 1x1에서 rate/NSS/chain 또는 Tx descriptor context 불일치 | 중간 | physical symmetric 1-path가 강한 cofactor이나 실제 selected chain은 미관측 |
| 3 | FW-generated PM/QoS/null frame의 마지막 복귀 frame 실패가 지속 상태를 유발 | 중간 | index 7 집중 및 scan당 정상 2-frame 패턴, subtype/origin은 미확정 |
| 4 | host queue/cfg80211/requester 결함 | 낮음 | 두 requester 재현, queue/pending/completion 정상 |

AP가 frame을 받지 못한 경우와 AP가 보낸 ACK를 STA가 놓친 경우는 현재 host/F/W
counter만으로 구분할 수 없다.

### 4.3 최소 F/W trace 지점

p149.88 good과 p149.115 bad에서 다음 항목만 동일 timestamp/cookie로 비교한다.

1. `HostCmd 0x0107` 수신
   - host command sequence, internal scan cookie
   - enhanced/default type
   - 전체 channel TLV, band, scan mode, dwell/gap
   - BSS/association ID와 scan 직전 physical chain/rate state
2. off-channel 진입/복귀 시 F/W-generated frame
   - origin enum: scan-PM-enter/exit, auto-null, host-TxPD
   - FC type/subtype, PM bit, QoS/TID, 802.11 sequence, RA/TA
3. 실제 송신 선택
   - rate/MCS/NSS/BW/GI, Tx power, selected Tx chain
4. Tx completion/ACK 판정
   - attempt/limit, MAC/PHY result code
   - ACK detector 결과, ACK RSSI, selected ACK-RX chain/AGC
5. home-channel 복구
   - primary/center channel, BW, RF/BB/PLL context
   - Tx/Rx chain enable/selection, rate-control context
6. 완료 순서
   - 마지막 PM-clear/control frame의 ACK 결과
   - `EVENT_EXT_SCAN_STATUS_REPORT(0x7f)` 발생 시각

외부 monitor/AP capture를 802.11 sequence로 결합하면 다음을 구분할 수 있다.

| 관측 | 우선 책임 경계 |
|---|---|
| AP가 MPDU를 수신하지 못함 | STA Tx/RF/chain |
| AP가 정상 MPDU를 받고 ACK를 보내지 않음 | AP 또는 MPDU validity/policy |
| AP가 ACK를 송신했지만 STA가 no-ACK 처리 | STA ACK-RX/turnaround/chain |

### 4.4 Internal bisect 요청

F/W 팀에는 p149.88~p149.115 사이 제공 가능한 build 목록과 관련 change ID를
요청한다. 숫자상 중간 build가 있다면 p149.101/102 부근부터 시작하되 실제 제공
목록을 기준으로 이분 탐색한다.

각 build에는 동일 main/505.p14, `antcfg 0x0101`, 동일 AP/BSSID, 4채널 scan,
5초 간격, 최대 60회 및 failure delta 1000 기준을 그대로 적용한다. driver 또는
requester를 동시에 바꾸지 않는다.

## 5. 최소 추가 host 관측

F/W trace를 받을 수 있으면 추가 driver patch가 필요하지 않다. F/W trace가 불가능한
경우에만 아래 순서를 사용한다.

### 5.1 무패치 우선

1. `/proc/mwlan/adapter0/mlan0/log` q7 배열 존재 여부 확인
2. 필요 시 `MCMD_D`(debug bit 17)로 SCAN_EXT HostCmd/response/event raw dump 한 run
   수집
3. AP/monitor capture와 host monotonic timestamp 정렬

`MCMD_D` raw dump는 로그량과 timing 영향을 줄 수 있으므로 회귀 gate 전체에 상시
적용하지 않는다. raw command가 없으면 p149.88/p149.115의 byte-identical scan
request는 고정 환경과 동일 driver 경로에서의 강한 추론이지 직접 증거는 아니다.

### 5.2 별도 계측 patch가 반드시 필요한 경우

기존 동결 patch를 변경하지 않고 새 patch/SHA 세트로 다음 단조 counter만 추가한다.

- `wlan_ops_sta_process_txpd()`의 host TxPD priority별 제출 수
- `wlan_send_null_packet()`의 attempt/success 수
- `PRE_SCAN`과 terminal event 시점 snapshot

host q7/null delta가 0인데 F/W q7이 증가하면 FW-generated origin을 구분할 수 있다.
per-packet printk, recovery 동작 또는 scan 정책 변경은 추가하지 않는다.

## 6. 동결 instrumentation

계측 A/B에 사용한 source/binary 정본:

```text
/home/jhw/ai/opencode/projects/wlan-package/.worktrees/wpa-roam-scan-policy/artifacts/moal-instrumented-antcfg-scan-ab-20260825/config/antcfg_scan_wedge_diag_20260825_143732_KST_ported_543p18/
```

| 항목 | 값 |
|---|---|
| build base | `26400d66cc56e9af0096273b5d25d31d3e001fa6` |
| patch | `antcfg_scan_wedge_min_instrumentation.patch` |
| patch SHA-256 | `965ea7de2feac360972c8f108e686d9a92541db75f4c176804194c453ac3017f` |
| `mlan_imx93.ko` SHA-256 | `392537d37eea64bd7568d33ac732422a7fdd363f28d3eee92e1c4038e2b54326` |
| `moal_imx93.ko` SHA-256 | `67f9b679772e96a584d89091a2d694d35cbf4959abb5b9c0dbee73deb4174962` |

이 모듈은 positive control에서 장애를 재현했으므로 instrumentation이 timing을 바꿔
현상을 숨겼다는 근거는 없다. 원인 수정 모듈이 아니며 production package의 KO와도
구분한다.

## 7. 제품 release 범위

최종 release package:

```text
/home/jhw/ai/opencode/projects/wlan-package/.worktrees/wpa-roam-scan-policy/release/wlan.deb
SHA-256 a49a2b64da425e6873380ac50c5e5bb390a95e292a7c7825a34cd63115e0fbaf
```

lock된 component:

| component | SHA-256 |
|---|---|
| production `mlan_imx93.ko` | `c351a0d63f75d53f99ca0b74aba3911d79e9aaf1f4e269dac68cba9b06e4c46a` |
| production `moal_imx93.ko` | `87b9d0dc5b86c4a40560050f4e9c5a2c8662acc97bea6b516f0f094fcfc9b6a0` |
| `mlanutl_imx93` | `86ea019edd766b2c426026a4ffd86538af1f6ce85060e68cb02bbd8cc81d6f95` |
| p149.115 F/W | `7c3ef6e12d3cfc9bd638d1571ccf6ddd2e96e0ed179ec70664ccb1df0ba29e57` |

release review는 APPROVE/CLEAR이고 code/spec/security finding은 0건이다. 이는 현재
우회 설정을 포함한 exact package qualification이며 p149.115의 physical 1x1 회귀가
해소됐다는 뜻은 아니다.

F/W 변경 시 다음을 다시 확인한다.

- `antcfg 0x0303 0x0101` 뒤 physical 2x2 + `user_htstream=0x2121` 계약
- association 뒤 실제 HE/VHT Rx NSS1
- Tx NSS/MCS runtime sample
- physical 1x1 60-scan positive-control gate
- 제품 우회 조합 60-scan 및 roaming soak

## 8. 확인 사실 / 추론 / 미확정

### 8.1 직접 확인된 사실

1. 동일 505.p14에서 p149.88은 60/60 통과하고 p149.115는 scan 10에서 실패했다.
2. p149.115와 physical symmetric 1x1에서 scan-return Tx/ACK wedge가 반복 재현된다.
3. 505→543 driver 변경은 필요조건이 아니며 현상을 제거하지 않는다.
4. 장애 중 association/RX/host queue/scan completion/home channel은 유지된다.
5. `tx_failed`와 dot11 failed/ACK 값은 F/W GET_LOG에서 온다.
6. physical 2x2 + host Rx NSS1 우회는 현재 exact 제품 시험에서 안정적이다.

### 8.2 강한 추론

1. 공개 release 회귀는 p149.88과 p149.115 사이 F/W 변경에 있다.
2. 최초 실패 경계는 host queue보다 아래의 F/W/MAC/RF Tx/ACK 복귀 경로다.
3. physical Tx/Rx 동시 1-path는 강한 cofactor다.
4. p149.115 terminal scan event 시점에 Tx/ACK 사용 가능 상태라는 암묵적 사후조건이
   충족되지 않았을 가능성이 높다.

### 8.3 미확정

1. p149.88→p149.115 internal F/W 변경 중 정확한 원인과 first-bad build
2. 문제 frame의 subtype, PM bit 및 FW/host origin
3. STA 송신 실패, AP no-ACK 및 STA ACK-RX miss 중 정확한 경계
4. selected rate/MCS/NSS/BW와 실제 Tx/ACK-RX chain
5. physical Rx 1-path 단독 영향
6. `antcfg 0x0303 0x0101`의 physical 2x2 유지가 향후 F/W에서도 보장되는 공식 ABI인지
7. 관찰된 HE Tx NSS1이 다른 F/W/AP에서도 유지되는지

## 9. 팀별 최종 조치

| 담당 | 조치 | 중단 조건/완료 조건 |
|---|---|---|
| Driver | production 동작 patch 보류, 기존 계측 정본 유지 | 새 source/trace가 host 결함을 직접 지목하기 전까지 수정하지 않음 |
| F/W | p149.88↔p149.115 internal bisect 및 최소 trace 제공 | first-bad build와 ACK/RF restore 실패 지점 식별 |
| Test | 동일 60-scan gate와 p149.88 control 유지 | F/W 후보가 physical 1x1 gate를 통과하고 failure signature 미발생 |
| Product | 현재 physical 2x2 + host Rx NSS1 우회 유지 | 수정 F/W에서 physical 1x1 회귀 해소 및 우회 계약 재검증 전까지 유지 |

## 10. 외부 F/W 전달 요약

```text
88Q9098 / i.MX93

Fixed host:
- main/505.p14 driver and identical module arguments/AP/association/scan
- antcfg 0x0101 before association
- 4-channel scan, 5-second interval, 60-scan gate

Result:
- p149.88: 60/60 PASS
- p149.115: scan 10 FAIL
- failed delta 2422, ACK failure delta 24221, final ping FAIL
- association/BSSID/frequency/beacon RX maintained
- host queues/pending/scan completion normal
- p149.88 and p149.115 expose identical fw_cap_info masks

Request:
1. Internal build/CL between p149.88 and p149.115
2. Trace scan PM/null frames and origin/subtype/PM/sequence
3. Trace selected MCS/NSS/BW/Tx chain and ACK-RX reason/chain
4. Trace home-channel RF/BB/rate-control restore before event 0x7f
5. State whether antcfg 0x0303/0x0101 -> physical 0x0303/0x0303 plus
   host Rx NSS1 is a supported forward-compatible contract
```

## 11. 근거 문서

- 시험 종합 정본:
  `/home/jhw/ai/opencode/projects/wlan-package/.worktrees/wpa-roam-scan-policy/artifacts/CONSOLIDATED_TEST_SUMMARY_20260826.md`
- F/W bisect:
  `/home/jhw/ai/opencode/projects/wlan-package/.worktrees/wpa-roam-scan-policy/artifacts/fw-bisect-505-antcfg-only-20260826/FW_BISECT_RESULT_20260826.md`
- release gate:
  `/home/jhw/ai/opencode/projects/wlan-package/.worktrees/wpa-roam-scan-policy/artifacts/final-release-gate-20260826/FINAL-RELEASE-REPORT.md`
- antcfg/NSS source contract: `docs/antcfg-nss-control.md`
- main/ported HostCmd·scan 비교:
  `docs/main505-ported543-rf-hostcmd-scan-sequence-comparison-2026-08-25.md`
- ported 반영 감사:
  `docs/main-antcfg-customization-ported-coverage-audit-2026-08-25.md`
- 계측 A/B 결과:
  `docs/antcfg-scan-wedge-instrumented-ab-results-2026-08-25.md`
- 동결 계측 전달서:
  `docs/antcfg-scan-wedge-instrumentation-handoff-2026-08-25.md`
