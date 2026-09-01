# antcfg / NSS 제어 가이드 (88Q9098)

mlan WLAN 드라이버에서 공간 스트림 수(NSS / MIMO)를 제어하고 검증하는 방법 정리.
대상 칩: **88Q9098** (STREAM_2X2, per-band antenna bitmap 계열).

## TL;DR

- **광고 NSS 제어 입력**의 정식 경로는 `antcfgnss` SET이다(2026-08-31, 이슈 #41 /
  PR #42). `antcfg`는 물리 RF chain 전용으로 회귀한다 — SET 시 광고 intent
  (`user_htstream`)까지 파생 갱신하는 겸용 해석은 과도기 호환으로만 유지되며
  forward-compatible 보장이 없다.
- 상태는 3층으로 구분한다: **물리 mask**(`antcfg` GET) / **광고 intent**(`antcfgnss`
  GET, `user_htstream`) / **실효 NSS**(연결 후 `iw dev <if> link`·`getdatarate`).
  세 층은 서로 다른 상태이며 일치할 의무가 없다 — 아래 "상태 3층 계약" 참조.
- `mcstiercfg`는 **MCS tier만** 제한 — VHT/HE의 NSS는 보존(`update_supported_nss_map`이 NOT_SUPPORTED 비트 유지). NSS 제어 도구가 아님.
- 예외: `mcstiercfg ht 7`은 HT cap을 1x1로 광고 → 펌웨어가 device-wide 1-SS로 해석해 HE/VHT TX NSS까지 1로 떨어지는 **부작용**이 있음(아래 "펌웨어 NSS 선택 조건" 참고). 의도된 NSS 제어 수단이 아니며, TX NSS 제한의 공식 경로는 `antcfgnss`의 TX 니블이다(실측 근거는 아래 antcfgnss 절).

## antcfg 사용법

```bash
mlanutl mlan0 antcfg              # GET (현재 Tx/Rx path)
mlanutl mlan0 antcfg <tx>         # SET — tx 값만 주면 Rx도 동일
mlanutl mlan0 antcfg <tx> <rx>    # SET — Tx/Rx 분리
```

인자 개수 해석: 3=GET, 4=tx만(Rx=tx), 5=tx/rx 분리
(`mapp/mlanutl/mlanutl.c:20777` `process_set_get_tx_rx_ant`,
 `mlinux/moal_eth_ioctl.c:13905` `woal_priv_set_get_tx_rx_ant`)

### 9098 비트맵 (per-band)

값은 밴드별 path 비트맵. LOW byte = 2G, HIGH byte = 5G:

| 비트 | 의미 |
|------|------|
| Bit 0 | 2G Path A |
| Bit 1 | 2G Path B |
| Bit 8 | 5G Path A |
| Bit 9 | 5G Path B |

path 1개 = 1 stream(NSS=1), path 2개(A+B) = 2 stream(NSS=2).

| 값 | 2G | 5G | 결과 |
|------|------|------|------|
| `0x303` | A+B | A+B | 양 대역 2x2 (NSS=2) |
| `0x101` | A | A | 양 대역 1x1 (NSS=1) |
| `0x301` | A+B | A | 2G 2x2 / 5G 1x1 |
| `0x103` | A | A+B | 2G 1x1 / 5G 2x2 |

### NSS 제어 명령 (과도기 — 구계약)

> 광고 NSS만 바꾸려면 `antcfgnss`를 사용한다(아래 절). `antcfg` SET은 광고 intent와
> 무관하게 **물리 mask가 RF_ANTENNA HostCmd로 FW까지 전달**되므로, 광고 제한 목적으로
> 쓰는 것은 과도기 호환 용법이다.

```bash
# 양 대역 1x1을 요청하고 advertised NSS도 1로 제한
mlanutl mlan0 antcfg 0x101

# NSS=2 복귀
mlanutl mlan0 antcfg 0x303

# advertised Tx 1SS / Rx 2SS를 요청
mlanutl mlan0 antcfg 0x101 0x303
```

이 브랜치와 함께 빌드한 `mlanutl`의 GET 출력 예 (9098 = 2-word 응답, 6G 줄은
IW624/AW693처럼 6G mask가 있는 카드에서만 출력):
```
Mode of Tx path is 0x303
Mode of Rx path is 0x303
NSS limit (antcfg): 2G rx=1 tx=2, 5G rx=1 tx=2  [user_htstream=0x2121]
```

## 물리 antenna와 advertised NSS의 분리

`antcfg 0x303 0x101`의 SET이 성공한 뒤 GET이 아래처럼 보이는 것은 이
드라이버에서 표현 가능한 상태다.

| 상태 | 예 | 의미 |
|------|----|------|
| firmware physical antenna GET | Tx=`0x303`, Rx=`0x303` | firmware가 현재 사용하는/보고하는 RF path |
| host `user_htstream` | `0x2121` | association capability에 적용할 양 대역 Tx 2SS/Rx 1SS 제한 |

`user_htstream`은 각 nibble에 NSS를 저장한다.

| bits | 의미 | `0x2121` |
|------|------|----------|
| `[3:0]` | 2G Rx NSS | 1 |
| `[7:4]` | 2G Tx NSS | 2 |
| `[11:8]` | 5G Rx NSS | 1 |
| `[15:12]` | 5G Tx NSS | 2 |

SET 경로는 요청 mask의 bit 수로 `user_htstream`을 갱신하고, VHT/HE
association capability builder는 이 값을 사용해 최종 MCS map/NSS를 제한한다.
반면 GET 응답은 firmware의 물리 mask를 반환하며 host intent를 덮어쓰지 않는다.
따라서 **SET exit code 0은 요청이 ioctl/HostCmd 경로에 접수됐다는 뜻이지, 이후
physical GET이 요청값과 같다는 보장은 아니다.**

이 분리는 현재 포트의 코드에서 의도적으로 유지하는 host 정책이다. 다만 firmware가
비대칭 physical Rx 요청을 `0x303`으로 정상화하는 이유 자체는 firmware 규격/로그로
별도 확인해야 한다.

### `0x0303/0x0101` 정상화의 계약 판정 (2026-08-31 확정, 이슈 #35/#41)

`antcfg 0x0303 0x0101` 후 "물리 Rx `0x0303` 유지 + intent Rx 1SS"가 되는 결과는 FW
정상화에 의존하는 **비보장 동작**으로 판정한다 — 의도된 계약으로 선언하지 않는다.
FW가 마스크를 존중하는 순간 물리 1-path가 실제 적용되며(#34의 cofactor가 그 사례),
forward-compatible 보장이 없다. 대응은 정상화 의존의 제거다:

- 광고 제한은 `antcfgnss`로 직접 기록한다 — RF_ANTENNA HostCmd 미발행.
- 부팅 경로는 `antcfg`를 아예 적용하지 않는 방향으로 이관한다(물리는 FW 기본 2x2,
  wlan-package#220). `antcfg 0x0303 0x0303`(순수 물리·대칭) + `antcfgnss 0x2121`
  조합이 기존 부팅 구성(`antcfg 0x0303 0x0101`)과 런타임 완전 동등함은 실기로
  실증됐다(이슈 #41 코멘트, 2026-08-31).
- **과도기 운용 주의**: 활성 연결 중 `antcfg` SET은 FW가 거부(cmd 0x20, exit 255)해도
  host intent(`user_htstream`)는 요청값으로 갱신되는 결합 부작용이 있다(#41 실측).
  연결 중 `antcfg` SET 금지.

### 2026-08-25 수정 전 드라이버 재현 결과의 현재 해석

아래 장비 시험은 **모두 이번 instrumentation이 들어가기 전 드라이버**에서 수행됐다.
따라서 계측 모듈의 동작 또는 장애 수정 여부를 검증한 결과가 아니다.

- 이전 firmware + main driver 조합은 동일 조건에서 재현되지 않았다.
- 현재 조합의 Tx/Rx=`0x101`은 scan 5에서 재현됐다.
- Tx=`0x101`, Rx=`0x303`은 4-channel scan 60/60회(330초) 완료했고
  `tx failed`는 0→2였으며 연결/BSSID를 유지했다(`NOT_REPRODUCED`).
- Tx=`0x303`, Rx=`0x101` 요청은 SET exit 0이었지만 physical GET이
  Tx/Rx=`0x303`으로 돌아왔다. host intent는 `user_htstream=0x2121`이지만 시험
  controller의 유효 조건을 만족하지 못해 scan은 실행하지 않았다.
- 동일 조건의 Tx/Rx=`0x101` positive control을 다시 실행했을 때 scan 32에서
  재현됐다. 장애 상태에서도 carrier와 모든 netdev queue는 started였고 qdisc
  backlog, MOAL/MLAN pending, `scan_processing`은 0이었다. 반면
  `dot11FailedCount=68,654`, `dot11ACKFailureCount=686,553`까지 증가했으며 beacon
  수신과 association은 유지됐다.

따라서 Tx 1SS 단독은 충분조건이 아니며, 아직 **Rx 제한 자체**와 **Tx/Rx 동시
1SS 상호작용**을 구분하지 못했다. 또한 scan 32 결과는 host queue wake보다
scan 복귀 후 FW/MAC/RF Tx-chain, channel context, TxPD/rate/NSS와 ACK 실패 경로를
먼저 확인해야 함을 보여준다. 이번 작업은 이 구분에 필요한 ABI/계측만 추가하며
antenna 설정 처리 자체는 변경하지 않는다.

## 상태 3층 계약 — 어느 GET이 정본인가

| 층 | 정의 | 정본 GET | 저장 위치 |
|---|---|---|---|
| 물리 antenna mask | FW가 실제 사용/보고하는 RF path | `antcfg` (word 0/1) | firmware |
| 광고 NSS intent | 다음 (re)assoc capability에 적용할 host 제한 | `antcfgnss` | `pmadapter->user_htstream` |
| 실효 NSS | 현재 연결에서 실제 협상·사용 중인 NSS | `iw dev <if> link`(rate 라인), `getdatarate` | 링크 상태 |

- 세 층은 서로 다른 상태이고 일치할 의무가 없다. SET exit 0은 "요청이 ioctl/HostCmd
  경로에 접수됨"이지 세 층의 일치 보장이 아니다.
- **실효 TX NSS = min(TX 니블, RX 니블)** — 2026-08-31 실기 A/B 4칸 매트릭스 실측
  (SD9098 p149.115 + 4SS AP, 이슈 #41 코멘트). intent TX2/RX1이 실효 TX1이 되는 것이
  특징. 메커니즘(FW 내부 대칭화 vs AP의 OpMode 해석)은 미규명(추정)이며, 타 AP 교차
  확인 전에는 일반화하지 않는다(#41 잔여 항목).
- assoc 요청 IE의 광고 map 바이트 실측은 HostMlme 특성상 host 측 mgmt dump로는 잡히지
  않아 OTA 스니퍼가 필요하다(#41 잔여 항목).

## mlanutl ABI 호환성

`antcfg` GET 응답의 word 수와 word 2/3 의미가 브랜치별로 다르다.

| driver ABI | `antcfg` GET payload | NSS 조회 |
|------------|----------------------|----------|
| main/505 extended | `tx, rx, user_htstream, reserved(=0)` — STREAM_2X2면 항상 4 word | `antcfg` word 2 |
| ported/543 split (6G 카드) | `tx, rx, tx_6g, rx_6g` — IW624/AW693에서 양 6G mask ≠ 0일 때만 4 word | 별도 `antcfgnss` (GET/SET) |
| ported/543 split (9098 등) | `tx, rx` 2 word | 별도 `antcfgnss` (GET/SET) |
| 1x1 (양 브랜치 공통) | 3 word — main의 word 2는 `current_antenna` | 없음 (`antcfgnss`는 -EOPNOTSUPP) |

이 저장소의 `mlanutl`은 **응답 word 3으로 ABI를 판별**한다(c846289 — 종전 probe
ioctl 방식 5bf792a를 대체). 근거: 16-byte ported 응답은 항상 word 3 ≠ 0이고 main은
word 3을 reserved 0으로 유지하므로 두 ABI는 word 3만으로 정확히 갈린다
(`mapp/mlanutl/mlanutl.c:21040-21070`).

word 3 판별이 보장하는 것(이슈 #35 수용 기준):

- **fail-open 제거**: probe의 일시 오류(-EFAULT/-ENOMEM)가 판별을 바꿔 6G mask를
  NSS로 날조 출력하던 경로가 없다 — 오류가 판별에 영향을 주지 못한다.
- **오라우팅 제거**: main 드라이버에 ported 전용 명령을 보내지 않는다
  (`antcfgnss`가 main의 `PRIV_CMD_ANT_CFG`에 prefix 매치되던 문제).
- **관측성**: 안테나 줄을 먼저 출력한 뒤 NSS를 묻는다 — 드라이버가 느리거나 wedge여도
  물리 상태는 관측된다(scan wedge 조사의 주 관측 도구).
- **QA 게이트**: `antcfg_cli_qa` + `upstream_port_invariants`가 양 ABI layout·응답
  길이·인자 보존을 커버하며, 판별 로직을 되돌리면(5bf792a 및 5bf792a^ 양방향) 실제로
  실패함을 확인했다(2026-08-28).

남는 위험은 **구버전 main 방식 `mlanutl` 바이너리를 ported/543 드라이버와 혼용**하는
경우다. 구 바이너리에는 word 3 판별이 없어 exit 0으로 성공하면서 NSS를 조용히
누락하거나 6G word를 오해석할 수 있다. 따라서 제품에는 드라이버와 같은 빌드 산출물인
`bin_wlan/mlanutl_imx93`을 함께 배포한다(wlan-package PR #205: imx93 payload를
c846289로 갱신, 실기 verify 게이트 통과 2026-08-28).

## antcfg/association/scan 장애 계측

추가 계측은 `MCMND`(`0x10`) bit로 gate되어 기본 동작에는 로그/추가 조회 비용이
없다. 기존 `drvdbg` mask의 다른 bit를 보존하면서 `0x10`을 OR한다. 예를 들어 기본
mask가 `0x00080207`이면 다음처럼 사용한다.

```bash
mlanutl mlan0 drvdbg 0x00080217
dmesg -w | grep -E 'ANTCFG_DIAG|ASSOC_NSS_DIAG|SCAN_WEDGE_DIAG'
```

수집되는 marker:

- `ANTCFG_DIAG request`: ioctl SET의 Tx/Rx/6G mask와 SET 전후 `user_htstream`
- `ANTCFG_DIAG hostcmd`: firmware로 serialize한 RF_ANTENNA action/mask/size
- `ANTCFG_DIAG response`: firmware 응답 mask와 응답 처리 전후 `user_htstream`
- `ASSOC_NSS_DIAG vht|he`: association 직전 최종 advertised Tx/Rx NSS와 MCS map
- `SCAN_WEDGE_DIAG`: 같은 `id`로 `PRE_SCAN`, `START`, `FW_COMPLETE`,
  `CFG80211_DONE`, `POST_SCAN_1S`을 연결하고
  home/FW channel, carrier/queue stop, MOAL/MLAN pending queue, power-save/tx-lock/wake,
  scan state를 기록
- `FW_TX_COUNTER_DIAG`: FW의 failed/ACK failure/retry/Tx frame과 PRE 대비 delta
- `TX_RATE_DIAG`: 실제 Tx/Rx format, rate, MCS, NSS, BW, GI
- `RF_CHANNEL_DIAG`: cached/home/FW channel, physical Tx/Rx mask, `user_htstream`
- `TXPD_DIAG`: scan 완료 뒤 firmware로 넘길 다음 STA TxPD 최대 8개
- `FW_TX_STATUS_DIAG`: TX_STATUS를 요청한 packet에 한정된 FW status event 집계

`FW_COMPLETE`는 MLAN event callback 재진입을 피하기 위해 MOAL snapshot만 남긴다.
`START`도 scan 중 동기 IOCTL을 피하기 위해 MOAL snapshot만 남긴다. 전체 MLAN/FW
조회는 `PRE_SCAN`, workqueue상의 `CFG80211_DONE`, 그리고 약 1초 뒤
`POST_SCAN_1S`에서 수행한다. 그러므로 이
상세 계측은 재현 시험 중에만 켜고 시험 후 원래 `drvdbg` mask로 복구한다.

전체 marker/상태값 표와 수집 절차는
`docs/antcfg-scan-wedge-instrumentation-handoff-2026-08-25.md`를 따른다.

## 펌웨어 NSS 선택 조건 (`mcstiercfg ht 7` 부작용)

실측: `mcstiercfg ht 7 vht 7 he 7` → HE TX NSS=1,
`mcstiercfg vht 7 he 7`(ht 제외) → HE TX NSS=2.

조건은 두 층으로 나뉜다:

1. **트리거 (드라이버 소스 추적 가능)** — `mcstiercfg ht 7` = `htstreamcfg 0x11` →
   `usr_dev_mcs_support=0x11`. association HT Supported MCS Set IE가
   MCS 0~7만(1 spatial stream byte)으로 빌드됨
   (`mlan/mlan_11n.c:1502-1518` `wlan_fill_ht_cap_tlv`, `:1582-1598`
   `wlan_fill_ht_cap_ie` — `rx_mcs_supp=GET_RXMCSSUPP=1`).
   AP/펌웨어가 STA를 "1-SS 장비"로 인지.

2. **펌웨어 반응 (소스 없음, 실측·추론)** — 드라이버 소스에는 HE를 NSS=1로
   만드는 코드가 없음:
   - VHT/HE cap IE는 `usr_dev_mcs_support`를 참조하지 않음
     (`mlan_11ac.c`/`mlan_11ax.c`에 등장 0회)
   - auto-rate bitmap은 HT 설정과 무관하게 VHT NSS1+2 / HE NSS1+2를 무조건 채움
     (`mlan/mlan_misc.c:5142-5152`)

   → NSS=1 전이는 **펌웨어 rate-adaptation 내부** 동작. RF chain은 단일 물리
   자원이라, 펌웨어가 HT cap의 Tx-NSS(=1)를 라디오 전체의 1-SS 신호로 해석해
   HT/VHT/HE TX rate 선택에 동일 적용하는 것으로 추정.

**결론**: 광고 NSS를 의도적으로 제어하려면 `mcstiercfg ht 7`의 간접 부작용에 기대지
말고 `antcfgnss`를 사용할 것 — 물리 chain 제한이 실제로 필요할 때만 `antcfg`.
이관의 실측 근거: `antcfgnss 0x2121` 상태에서는 ht tier를 15로 올려도 실효 TX NSS1이
유지된다(2026-08-31 실기 A/B, 단일 AP — TX NSS1 보장에 관해 ht7 부작용은 중복
방어였음이 확인됨. 이슈 #41 코멘트).

## 주의점

- **HW capability 한계**: 1x1 칩(`FEATURE_CTRL_STREAM_2X2` 미설정)에서는 `0x303`을
  줘도 2 stream 불가. 9098 MAC1은 2x2, AW693 MAC2는 1x1뿐 → 그 칩은
  `mod_para.conf` 사용 권장 (`README:107`).
- **부팅 고정**: 로밍/재연결에도 안 풀리게 하려면 런타임 mlanutl 대신
  모듈 파라미터 / `mod_para.conf`의 `antcfg=`로 설정.
- **SAD 계열 칩**: 의미가 다름 (`m=0|1|2|0xFFFF`, `0xFFFF`=diversity,
  2번째 인자=evaluate time). 9098은 위 path-bitmap 포맷.
- **검증**: 설정 후 `mlanutl mlan0 txratecfg`(NSS 필드) 또는 `iw dev mlan0 link`로 확인.

## 관련 파일

- `mapp/mlanutl/mlanutl.c` `process_set_get_tx_rx_ant`, `get_user_htstream`
- `mlinux/moal_eth_ioctl.c` `woal_priv_set_get_tx_rx_ant`, `woal_priv_get_antcfg_nss`
- `mlan/mlan_misc.c` `wlan_radio_ioctl_ant_cfg` (host intent 계산)
- `mlan/mlan_cmdevt.c` `wlan_cmd_802_11_rf_antenna`,
  `wlan_ret_802_11_rf_antenna` (HostCmd 요청/응답)
- `mlan/mlan_11ac.c`, `mlan/mlan_11ax.c` (association NSS/MCS map)
- `mlinux/moal_main.c` `woal_scan_diag_snapshot` (scan/TX queue snapshot)
- `mlan/mlan_11n.c` HT Supported MCS Set 빌더 (NSS 광고 결정)
- `mapp/mlanutl/mlanutl.c` `update_supported_nss_map` (mcstiercfg NSS 보존)
- `README:106-108`, `README:576-633` (antcfg 칩별 비트맵 포맷)

## 관련 문서

- 이슈 #35 (물리/광고 계약·mlanutl ABI — 본 문서의 "상태 3층 계약"/"계약 판정"/"ABI
  호환성" 절이 답), #41 (antcfgnss 신설·실측), #34 (물리 1-path scan wedge),
  #13 (mcstiercfg TX 적응 질문 — 코드레벨 답변으로 종결)
- wlan-package#220 (부팅 경로 이관: antcfg 미적용 + antcfgnss 게이트)
- Notion KB: [mlanutl mcstiercfg / rate 설정 종합](https://app.notion.com/p/3678a230a04e81cd95b0cb871c336a0e)
- Notion: [NXP moal dev_cap_mask 인터페이스별 제어](https://app.notion.com/p/3668a230a04e815e8f65d8caf9475ed2)

## antcfgnss SET — 광고 NSS 전용 설정 경로 (2026-08-31, 이슈 #41)

광고 NSS intent(`user_htstream`)를 물리 안테나 설정과 분리해 직접 기록하는 host 전용
경로. `MLAN_OID_ANT_NSS_CFG`(0x00030006) → `wlan_radio_ioctl_ant_nss_cfg()`(mlan_misc.c)로
처리되며 **RF_ANTENNA HostCmd를 발행하지 않는다** — 물리 antenna 상태는 불변이고,
FW의 마스크 정상화 동작(위 "물리 antenna와 advertised NSS의 분리" 절의 비보장 계약)에
의존하지 않는다.

```
mlanutl mlan0 antcfgnss            # GET (기존과 동일, MLAN_OID_ANT_CFG 경유)
mlanutl mlan0 antcfgnss 0x2121    # SET: 5Gtx=2 5Grx=1 2Gtx=2 2Grx=1 (0x 접두 필수)
```

- 니블 배치는 `user_htstream`과 동일: `[3:0]` 2G Rx, `[7:4]` 2G Tx, `[11:8]` 5G Rx,
  `[15:12]` 5G Tx.
- SET 검증: **지원 밴드의 니블은 1..하드웨어 상한만 허용, 0 거부**(`hw_dev_mcs_support`
  기반, 파워온 init과 동일 계산; AW693 MAC2는 2G 1x1로 축소). 니블 0은 하드웨어 상한이
  0인(밴드 미지원) 자리에만 허용 — 11n HT 빌더에는 0 가드가 없어 광고 0 스트림이
  HT MCS set을 통째로 비우는 결함을 막기 위함이다. 위반 시 `MLAN_ERROR_INVALID_PARAMETER`.
  값은 0x 접두 필수(진수 혼동·파싱 fail-open 방지), 대상 카드(9098/9097/AW693/IW624)
  외에는 SET 거부.
- 활성 연결 중에도 SET 가능(RF_ANTENNA의 연결 중 거부 제약 없음). 단 광고 반영은
  다음 (re)association부터다.
- **순서 제약**: 이후의 `antcfg <mask>` SET과 FW reload(`wlan_handle_antcfg`)는 안테나
  마스크로부터 `user_htstream`을 재계산해 이 intent를 **덮어쓴다**. 적용 순서는 항상
  antcfg(물리) → antcfgnss(광고).
- 이관 계획(이슈 #41 → wlan-package#220): 광고 NSS 입력의 정식 경로를 이 명령으로
  옮기고, `antcfg`는 순수 물리(RF chain) 용도로 회귀한다. 부팅 경로는 `antcfg`를
  적용하지 않는다(물리는 FW 기본 2x2). TX NSS 제한도 `mcstiercfg ht 7` 부작용 대신
  이 경로의 TX 니블을 쓴다.
- 선행 검증 완료(2026-08-31 실기 A/B, 이슈 #41 코멘트): TX 니블 단독 실효(ht7 없이
  intent TX1 → 실효 TX NSS1)와 방향 독립(TX1/RX2 → 실측 TX1·RX2) 성립, 전 칸에서
  **실효 TX NSS = min(TX 니블, RX 니블)** 규칙 실측(단일 AP — 교차 확인 잔여).
  reassociate 후 지속성, 음성 입력 3종 거부도 확인. assoc req IE의 스니퍼 실측은
  잔여(OTA 스니퍼 필요).
