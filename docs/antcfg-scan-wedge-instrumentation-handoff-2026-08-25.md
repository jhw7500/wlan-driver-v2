# antcfg + scan Tx wedge 최소 계측 모듈 전달 가이드

날짜: 2026-08-25  
대상: i.MX93 / ported driver `543.p18` / 88Q9098  
목적: `antcfg 0x101` 상태에서 scan 이후 발생하는 Tx/ACK 실패 지점을
host queue, MLAN/SDIO, FW counter, TxPD/rate/NSS, RF/channel 경계별로 구분한다.

## 1. 범위와 주의사항

- 이 패치는 **원인 수정 패치가 아니라 최소 계측 패치**다. antenna 설정값,
  scan 정책, Tx descriptor, rate/NSS 선택 또는 queue wake 판단을 변경하지 않는다.
- 추가 로그와 동기 FW/MLAN 조회는 기존 `drvdbg`의 `MCMND` bit(`0x10`)로
  opt-in된다. `MCMND`가 꺼져 있으면 scan 경계의 추가 FW/MLAN 조회와 delayed
  snapshot은 실행되지 않는다.
- scan 완료 뒤 `TXPD_DIAG`는 다음 STA TxPD **최대 8개**만 기록한다. payload는
  기록하지 않는다.
- 기존 보드 결과(scan 5, scan 32 재현 및 반대 비대칭 60/60 통과)는
  계측 모듈 적용 전 결과다. 이후 같은 계측 모듈로 positive control이 scan 4에서
  재현되고 Rx-NSS-only 대조군이 60+10회 통과하여, 계측 자체가 재현을 막지 않는
  것은 확인됐다. 상세는
  `docs/antcfg-scan-wedge-instrumented-ab-results-2026-08-25.md`를 참조한다.
- `FW_TX_STATUS_DIAG`는 firmware Tx-status를 요청한 packet(주로 management)에만
  해당한다. 모든 ping/data packet의 ACK 결과가 아니다. data ACK 실패 판단의
  주 지표는 `FW_TX_COUNTER_DIAG`의 `ack_failure_delta`다.

## 2. 활성화와 로그 수집

먼저 현재 mask를 읽고 기존 bit를 보존한 채 `0x10`을 OR한다.

```bash
mlanutl mlan0 drvdbg

# 예: 기존 값이 0x00080207인 경우
mlanutl mlan0 drvdbg 0x00080217

dmesg -w | grep -E \
  'ANTCFG_DIAG|ASSOC_NSS_DIAG|SCAN_WEDGE_DIAG|FW_TX_COUNTER_DIAG|TX_RATE_DIAG|RF_CHANNEL_DIAG|TXPD_DIAG|FW_TX_STATUS_DIAG'
```

시험 종료 후에는 `drvdbg`를 저장해 둔 원래 값으로 복구한다. marker의 `id`가
같은 행을 한 scan으로 묶는다. MLAN의 `TXPD_DIAG scan_seq`는 별도 단조 증가
번호이므로 MOAL `id`와 숫자가 같을 필요는 없다.

권장 원본 수집:

```bash
dmesg -c >/tmp/dmesg-before-antcfg-scan.log
dmesg -w >/tmp/antcfg-scan-instrumented-dmesg.log
```

필터된 로그뿐 아니라 전체 dmesg도 함께 보관해야 scan timeout, disconnect,
SDIO/FW fault 같은 인접 event를 확인할 수 있다.

## 3. scan phase 의미

| `phase` | 시점 | 조회 범위 |
|---|---|---|
| `PRE_SCAN` | `woal_do_scan()` 호출 직전 | MOAL + MLAN debug + FW stats/rate/antcfg. per-scan counter baseline 설정 |
| `START` | scan 요청이 성공적으로 제출된 직후 | MOAL host 상태만. 진행 중인 scan에 동기 IOCTL을 추가하지 않음 |
| `FW_COMPLETE` | MLAN `DRV_SCAN_REPORT` callback 경계 | MOAL host 상태만. event callback에서 MLAN 재진입하지 않음 |
| `CFG80211_DONE` | cfg80211에 scan 완료를 알리기 직전 | MOAL + MLAN + FW stats/rate/antcfg + FW current channel |
| `POST_SCAN_1S` | 완료 약 1초 뒤 | 위 전체 조회 재실행. 정상 traffic 복귀 뒤 counter/rate/RF 상태 확인 |

`POST_SCAN_1S` 전에 새 scan이 시작되어 `id`가 바뀌거나 driver teardown/fault가
발생하면 stale pointer/scan 혼합을 막기 위해 해당 delayed snapshot은 생략된다.

## 4. marker별 의미

### 4.1 `ANTCFG_DIAG request`

Host의 SET 처리 직후, HostCmd 생성 전 상태다.

| 필드 | 의미 |
|---|---|
| `tx`, `rx` | validation/bit mask 적용 후 요청된 2G/5G physical antenna mask |
| `tx6g`, `rx6g` | 6 GHz 요청 mask |
| `user_htstream=A->B` | 요청 mask에서 계산한 advertised NSS intent의 변경 전/후 값 |

88Q9098의 `0x303`은 2G/5G A+B, `0x101`은 2G/5G A path다.
`user_htstream` nibble은 `[3:0]=2G Rx`, `[7:4]=2G Tx`,
`[11:8]=5G Rx`, `[15:12]=5G Tx` NSS다.

### 4.2 `ANTCFG_DIAG hostcmd`

firmware에 실제 serialize된 RF_ANTENNA HostCmd다.

| 필드 | 의미 |
|---|---|
| `action` | general action: `0x0=GET`, `0x1=SET` |
| `tx_action`, `rx_action` | `0x1=SET_RX`, `0x2=SET_TX`, `0x3=SET_BOTH`, `0x4=GET_RX`, `0x8=GET_TX`, `0xc=GET_BOTH` 조합 |
| `tx`, `rx`, `tx6g`, `rx6g` | wire에 들어간 mask. userspace 인자와 비교 |
| `size` | HostCmd 전체 크기. ABI/serialization 비교용 |
| `user_htstream` | HostCmd 생성 당시 host advertised NSS intent |

### 4.3 `ANTCFG_DIAG response`

firmware RF_ANTENNA 응답을 처리한 결과다.

| 필드 | 의미 |
|---|---|
| `tx`, `rx`, `tx6g`, `rx6g` | firmware가 응답한 physical mask |
| `user_htstream=A->B` | 응답 처리 전/후 host NSS intent |

예를 들어 SET 요청 Rx=`0x101`인데 response/GET Rx=`0x303`이면 firmware 경계에서
physical mask가 정상화된 것이다. `user_htstream=0x2121`이 유지되면 physical
antenna와 association에 광고할 NSS가 분리된 상태다.

### 4.4 `ASSOC_NSS_DIAG vht|he`

association request에 넣기 직전의 최종 advertised capability다.

| 필드 | 의미 |
|---|---|
| `band` | association 대상 band bitmask |
| `user_htstream` | capability builder 입력인 host NSS intent |
| `rx_nss`, `tx_nss` | 최종 MCS map에서 실제 지원으로 광고되는 stream 수 |
| `limit_rx_nss`, `limit_tx_nss` | HE builder가 `user_htstream`에서 읽은 제한값 |
| `rx_mcs_map`, `tx_mcs_map` | VHT 최종 16-bit per-NSS MCS map |
| `rx_mcs_80`, `tx_mcs_80` | HE 80 MHz 최종 32-bit per-NSS MCS map |
| `bw_80p80` | 80+80 사용 여부. `1`이면 코드 정책상 1SS 강제가 개입할 수 있음 |

### 4.5 `SCAN_WEDGE_DIAG` — MOAL host 행

모든 phase에서 첫 번째로 기록된다. FW query가 지연되더라도 이 행은 남는다.

| 필드 | 의미 |
|---|---|
| `id` | cfg80211 scan 상관관계 번호 |
| `ts_ns` | kernel monotonic timestamp(ns) |
| `home_chan` | scan 제출 전 연결/home channel |
| `carrier` | netdev carrier: `1=up`, `0=down` |
| `queue_stopped` | 기본 netdev Tx queue: `1=stopped`, `0=started` |
| `moal_tx_pending` | MOAL에서 MLAN/FW 완료를 기다리는 Tx 수 |
| `wmm_tx_pending=a/b/c/d` | MOAL 내부 WMM queue별 pending atomics |
| `tx_q_len` | MOAL skb Tx queue 길이 |
| `tx_status_q` | explicit Tx-status 완료를 기다리는 entry 수 |
| `scan_pending` | scan block/pending flag |
| `scan_request` | cfg80211 scan request 소유 여부(`0/1`) |
| `host_tx_packets/bytes` | netdev 누적 Tx 제출 통계 |
| `host_tx_errors/dropped` | host 누적 Tx error/drop 통계 |
| `fw_tx_status_*` | 모듈 load 이후 수신한 explicit FW Tx-status 누적값 |

### 4.6 `SCAN_WEDGE_DIAG` — MLAN/SDIO 행

`PRE_SCAN`, `CFG80211_DONE`, `POST_SCAN_1S`에서 조회에 성공하면 출력된다.

| 필드 | 의미 |
|---|---|
| `mlan_status` | debug-info 조회 상태. `0=SUCCESS`; 그 외 값이면 뒤 필드를 유효 상태로 단정하지 않음 |
| `query_us` | 해당 동기 조회 지연시간(µs) |
| `mlan_wmm=BK/BE/VI/VO` | MLAN WMM access-category queue 수 |
| `tx_pkts_queued`, `bypass` | MLAN 누적/현재 queued 및 bypass packet 수 |
| `data_sent`, `data_sent_cnt` | host-to-card data 전송 상태와 누적 횟수 |
| `cmd_sent`, `pending_cmd` | FW command 진행 상태/command id |
| `ps_state` | `0=AWAKE`, `1=PRE_SLEEP`, `2=SLEEP_CFM`, `3=SLEEP` |
| `tx_lock` | MLAN Tx lock: `1=locked`, `0=unlocked` |
| `wake_req`, `wake_tries`, `wake_timeout` | card wake 요청/시도/timeout 상태 및 누적값 |
| `scan_processing` | MLAN scan 처리 중 여부/상태. 완료 뒤 정상 기대값은 `0` |
| `scan_state` | 아래 bitmask 표 참조 |
| `h2c_tx_fail` | host-to-card Tx 전송 실패 누적값 |
| `pkt_dropped` | MLAN packet drop 누적값 |
| `cmd_timeout` | FW command timeout 누적값 |
| `sdio_wr_bitmap` | firmware가 제공한 SDIO write-port bitmap |
| `curr_wr_port` | 현재 SDIO write port |
| `no_ports` | write port 부재 누적 횟수 |
| `invalid_update` | invalid SDIO port update 누적 횟수 |
| `last_int`, `irq` | 마지막 interrupt status와 누적 IRQ 수 |

`scan_state` bits:

| bit | 값 | 의미 |
|---|---:|---|
| 0 | `0x001` | scan start |
| 1 | `0x002` | ext scan |
| 2 | `0x004` | enhanced ext scan |
| 3 | `0x008` | ext scan cancel |
| 4 | `0x010` | command-response용으로 정의됐으나 현재 505/543 source에서 set되지 않음 |
| 5 | `0x020` | command-response용으로 정의됐으나 현재 505/543 source에서 set되지 않음 |
| 6 | `0x040` | command-response용으로 정의됐으나 현재 505/543 source에서 set되지 않음 |
| 7 | `0x080` | ext scan result |
| 8 | `0x100` | last ext scan result |
| 9 | `0x200` | ext scan status event |
| 10 | `0x400` | scan complete |

주의: `wlan_ret_802_11_scan_ext()`는 response 시점에도 download 시점과 같은
type bit(bit 1/2/3)를 OR한다. 따라서 bit 4/5/6으로 command response 도착 여부를
판정하면 안 된다. response 순서는 `CMD_RESP ... SCAN_EXT [0x107]` 로그와
`FW_COMPLETE`/`CFG80211_DONE` timestamp를 함께 사용한다.

### 4.7 `FW_TX_COUNTER_DIAG`

FW getlog counter의 절대값과 동일 scan `PRE_SCAN` 대비 delta다.

| 필드 | 의미 |
|---|---|
| `status` | getlog 조회 상태. `0=SUCCESS`; 비정상이면 counter 값 해석 금지 |
| `query_us` | FW stats 조회 지연시간(µs) |
| `failed(_delta)` | dot11 failed Tx 절대값과 scan별 증가량 |
| `ack_failure(_delta)` | dot11 ACK failure 절대값과 scan별 증가량 |
| `retry(_delta)`, `multi_retry(_delta)` | retry 및 multiple-retry 증가량 |
| `tx_frame(_delta)` | Tx frame 증가량 |
| `rts_failure` | RTS failure 절대값 |
| `bcn_rcv(_delta)`, `bcn_miss` | beacon 수신 증가량과 miss 절대값 |
| `qos_*[0..7]` | TID별 failed/ACK failure/retry 누적값 |
| `failed_amsdu`, `amsdu_ack_failure` | AMSDU 실패/ACK 실패 누적값 |
| `tx_ampdu`, `tx_mpdus_ampdu` | AMPDU/포함 MPDU Tx 누적값 |
| `tx_watchdog` | FW Tx watchdog recovery 누적값 |
| `dwDatErr`, `sdma_stuck` | data ownership/SDMA stuck 관련 FW 누적값 |
| `tx_airtime_us(_delta)` | Tx airtime 절대값과 scan별 증가량 |
| `tx_pwr_method`, `dpd_done`, `temp` | FW Tx power method, DPD 완료 상태, SoC 온도 raw 값 |
| `chan_switch_state/num` | FW channel-switch 상태와 channel number |
| `alloc` | 실패 행에서 stats buffer 확보 여부(`0/1`) |

TID/AMPDU/watchdog/power 상세 행은 firmware가 extended getlog를 지원할 때만 나온다.
counter가 reset/wrap되어 POST 절대값이 PRE보다 작아진 경우 unsigned delta는 유효하지
않으므로 절대값과 함께 판단한다.

### 4.8 `TX_RATE_DIAG`

FW rate query가 보고한 현재 Tx/Rx rate context다.

| 필드 | 의미 |
|---|---|
| `status`, `query_us` | query 결과(`0=SUCCESS`)와 지연시간 |
| `tx_format`, `rx_format` | `0=Legacy`, `1=HT`, `2=VHT`, `3=HE`, `255=AUTO` |
| `tx_rate`, `rx_rate` | driver의 raw current data-rate 값. format/MCS/BW/GI와 함께 비교 |
| `tx_mcs`, `rx_mcs` | MCS index |
| `tx_nss`, `rx_nss` | 사람이 읽는 실제 stream 수 |
| `*_nss_encoded` | FW/driver raw NSS encoding. VHT/HE에서는 `0=1SS`, `1=2SS` |
| `tx_bw`, `rx_bw` | `0=20 MHz`, `1=40 MHz`, `2=80 MHz`, `3=160 MHz` |
| `tx_gi`, `rx_gi` | HT/VHT: `0=long`, `1=short`; HE: `0..3` HE-LTF/GI encoding |

### 4.9 `RF_CHANNEL_DIAG`

host cache, firmware current channel과 antenna/NSS intent를 한 행에서 비교한다.

| 필드 | 의미 |
|---|---|
| `bss_status`, `ant_status`, `fw_chan_status` | 각 query 결과. `0=SUCCESS`인 부분만 유효 |
| `*_query_us` | 각 query 지연시간(µs) |
| `cached_chan`, `cached_band` | BSS info의 연결 channel과 band bitmask |
| `media_connected`, `radio_on` | 연결/라디오 상태(`0/1`) |
| `priv_chan`, `conn_chan` | MOAL private/cache의 현재/연결 channel |
| `fw_chan` | firmware가 보고한 현재 primary channel |
| `fw_band` | `0=2.4 GHz`, `1=5 GHz`, `2=6 GHz` |
| `fw_bw` | FW bitfield: `0=20 MHz`, `2=40 MHz`, `3=80 MHz` |
| `fw_offset` | `0=none`, `1=above`, `3=below` |
| `fw_center` | FW center channel |
| `physical_tx/rx`, `physical_tx6g/rx6g` | FW RF_ANTENNA GET이 반환한 physical mask |
| `user_htstream` | association capability에 적용되는 host NSS intent |

`cached_band`는 bitmask이며 일반 값은 `B=0x1`, `G=0x2`, `A=0x4`,
`GN=0x8`, `AN=0x10`, `GAC=0x20`, `AAC=0x40`, `GAX=0x100`,
`AAX=0x200`, `6G=0x400`이다.

### 4.10 `TXPD_DIAG arm` / `TXPD_DIAG`

MLAN이 FW scan report를 수신하면 `budget=8`을 arm하고 그 뒤 생성되는 STA TxPD를
최대 8개 기록한다.

| 필드 | 의미 |
|---|---|
| `scan_seq` | MLAN-side scan 완료 sequence |
| `sample` | 해당 sequence의 TxPD 번호 `1..8` |
| `bss` | MLAN BSS index |
| `len`, `priority` | packet length와 WMM/user priority |
| `mbuf_flags` | MLAN buffer flags raw bitmask |
| `txpd_flags` | FW TxPD flags. 주요 값: bit4 TDLS, bit5 explicit Tx-status 요청, bit7 EasyMesh |
| `pkt_type` | TxPD packet type. 주요 값: `0x5=802.11`, `0xe5=mgmt`, `0xe6=AMSDU`, `0xe7=BAR` |
| `delay_2ms` | driver queue 체류시간, 단위 2 ms |
| `tx_control`, `tx_control_1` | firmware로 전달되는 raw Tx control words |
| `cached_rate`, `tx_rate_info`, `ext_rate_info` | descriptor 생성 당시 cached rate context |
| `nss` | cached rate에서 계산한 NSS. 알 수 없으면 `0` |
| `user_htstream` | descriptor 생성 당시 advertised NSS intent |
| `channel`, `band` | 연결 BSS의 cached channel/band |
| `media_connected` | MLAN association 상태(`0/1`) |
| `ps_state`, `tx_lock` | 위 MLAN 상태값과 동일 |

`mbuf_flags`의 주요 bit는 bit0=requeued, bit1=MOAL Tx buffer, bit3=bridge,
bit8=TDLS, bit9=TCP ACK, bit10=explicit Tx-status, bit12=null packet,
bit14=host Tx control이다.

### 4.11 `FW_TX_STATUS_DIAG`

firmware explicit Tx-status event를 packet token과 scan `id`에 연결한다.

| 필드 | 의미 |
|---|---|
| `packet_type`, `token` | status를 요청한 packet type과 token id |
| `status` / `reason` | `0/success`, `1/failure`, `2/watchdog`, 그 외 `unknown` |
| `success/failure/watchdog/unknown` | 모듈 load 이후 누적 event 수 |

## 5. 공통 상태값

MOAL/MLAN query의 signed `status`는 build enum 기준으로 `0=SUCCESS`, `-1=FAILURE`,
`1=PENDING`, `2=RESOURCE`다. 이 계측은 wait 방식으로 조회하므로 정상 완료 기대값은
`0`이다. **status가 0이 아니면 같은 query에서 얻은 payload의 0 값을 정상 상태로
해석하지 않는다.**

모든 `*_delta`는 같은 `id`의 성공한 `PRE_SCAN`을 기준으로 한다. 서로 다른 `id`의
행을 빼지 않는다.

## 6. 우선 판독 규칙

1. `carrier=1`, queue/pending이 0인데 `ack_failure_delta`와 `failed_delta`만 크게
   증가하면 host queue wake보다 FW/MAC/RF 송신 또는 ACK 경로를 우선한다.
2. `home_chan/cached_chan/conn_chan`과 `fw_chan`이 완료 뒤 다르면 scan channel
   context 복귀 문제를 우선한다.
3. channel은 일치하지만 `TXPD_DIAG`의 channel/rate/NSS 또는 `TX_RATE_DIAG`가
   PRE와 비정상적으로 달라지면 Tx descriptor/rate/NSS context를 우선한다.
4. `h2c_tx_fail`, `no_ports`, `invalid_update`, `sdma_stuck`, `dwDatErr`가 증가하면
   SDIO/ownership 전달 경계를 우선한다.
5. beacon은 계속 증가하고 ACK failure만 폭증하면 RX/control path는 살아 있고
   Tx ACK 경로가 선택적으로 실패하는 패턴이다.

이 로그만으로 firmware 내부 RF register 또는 실제 PA/antenna 신호를 직접 증명할
수는 없다. 해당 지점은 FW-side RF/channel/Tx-status trace와 함께 비교해야 한다.

## 7. 테스트 모듈 source/binary 동결

계측 A/B에 사용한 모듈과 그 소스 patch의 canonical artifact는 다음 디렉터리에
보관한다.

```text
/home/jhw/ai/opencode/projects/wlan-package/.worktrees/wpa-roam-scan-policy/artifacts/moal-instrumented-antcfg-scan-ab-20260825/config/antcfg_scan_wedge_diag_20260825_143732_KST_ported_543p18/
```

동결 식별값:

| 항목 | 값 |
|---|---|
| build base commit | `26400d66cc56e9af0096273b5d25d31d3e001fa6` |
| patch | `antcfg_scan_wedge_min_instrumentation.patch` |
| patch SHA-256 | `965ea7de2feac360972c8f108e686d9a92541db75f4c176804194c453ac3017f` |
| patch 크기 | 35,078 bytes / 830 lines |
| `mlan_imx93.ko` SHA-256 | `392537d37eea64bd7568d33ac732422a7fdd363f28d3eee92e1c4038e2b54326` |
| `moal_imx93.ko` SHA-256 | `67f9b679772e96a584d89091a2d694d35cbf4959abb5b9c0dbee73deb4174962` |
| vermagic | `6.6.3-lts-next-gccf0a99701a7-dirty SMP preempt mod_unload modversions aarch64` |

patch에는 KO 생성에 관여한 아래 10개 driver source만 포함한다.

```text
mlan/mlan_11ac.c
mlan/mlan_11ax.c
mlan/mlan_cmdevt.c
mlan/mlan_main.h
mlan/mlan_misc.c
mlan/mlan_sta_tx.c
mlinux/moal_main.c
mlinux/moal_main.h
mlinux/moal_shim.c
mlinux/moal_sta_cfg80211.c
```

`mlanutl`, 문서, QA script 변경은 이 patch에서 제외했다. 2026-08-26 재검증에서:

- artifact의 `sha256sum -c SHA256SUMS`: 6개 항목 모두 `OK`
- clean build base에 대한 `git apply --check`: 성공
- 현재 `ported@bb2c9f7`에서 위 10개 파일만 생성한 raw diff의 SHA-256도
  `965ea7de...3017f`로 artifact patch와 일치

따라서 이후 계측이나 동작 코드를 수정할 때는 기존 파일을 덮어쓰지 않고 새로운
patch/KO SHA 세트를 발급한다. artifact 내부 `BUILD_INFO.txt`의
`board_validation=NOT_RUN`은 전달 당시의 역사적 상태이므로 변경하지 않으며, 이후
보드 A/B 결과는 `docs/antcfg-scan-wedge-instrumented-ab-results-2026-08-25.md`에서
관리한다.
