# main/505 vs ported/543 RF_ANTENNA HostCmd 및 scan 순서 비교

날짜: 2026-08-25  
분석 방식: 보드 실행이 아닌 두 branch의 committed source 정적 비교  
대상:

- `main`: `1ba9fd42b40c8f76b207ec391eec77c171cdcc12`, `505.p14`
- `ported`: `26400d66cc56e9af0096273b5d25d31d3e001fa6`, `543.p18`

현재 worktree의 미커밋 instrumentation 변경은 비교에서 제외하고
`git show main:<path>`와 `git show ported:<path>`를 사용했다.

## 1. 결론 요약

1. `RF_ANTENNA` command ID와 기존 2G/5G 필드 offset은 동일하다.
   ported/543은 구조체 끝에 6 GHz Tx/Rx byte 두 개를 추가하여 2x2 command
   전체 크기만 `16 -> 18` byte로 바뀐다.
2. 따라서 `antcfg 0x303 0x101`의 Rx가 GET에서 `0x303`으로 보이는 현상은
   byte offset 이동, endian 오류 또는 두 번째 인자 유실로 설명되지 않는다.
   `0x101`은 두 branch 모두 같은 offset과 byte로 firmware에 전달된다.
3. `user_htstream`은 `RF_ANTENNA` HostCmd wire 필드가 아니다. host가 SET
   response를 바탕으로 계산해 association capability에 사용하는 별도 상태다.
   그러므로 physical GET=`0x303/0x303`, host intent=`0x2121`인 분리 상태는
   구조적으로 가능하다.
4. legacy/default-ext/enhanced-ext scan의 MLAN command/event 순서는 main/505와
   ported/543에서 동일하다. normal 2G/5G scan에서 가장 큰 completion 차이는
   ported/543이 최종 cfg80211 report를 workqueue로 한 번 defer한다는 점이다.
5. 두 branch 모두 scan 완료 시 host가 명시적인 home-channel restore command를
   보내지 않는다. 마지막 FW response/event가 도착할 때 firmware가 이미 연결
   channel과 정상 Tx context를 복구했다고 가정한다.
6. static compatibility 확인이 필요한 지점은 9098 firmware가 ported/543의
   18-byte `RF_ANTENNA` command를 공식적으로 지원하는지 여부다. source만으로
   firmware ABI 지원 범위를 확정할 수 없다.

## 2. RF_ANTENNA wire ABI

Command ID는 두 branch 모두 `HostCmd_CMD_802_11_RF_ANTENNA = 0x0020`이고,
HostCmd generic header는 packed 8 byte다.

### 2.1 byte layout

| Offset | 크기 | main/505 | ported/543 |
|---:|---:|---|---|
| `0x00` | 2 | command=`0x0020` | 동일 |
| `0x02` | 2 | size=`0x0010` | size=`0x0012` |
| `0x04` | 2 | runtime sequence | 동일 |
| `0x06` | 2 | result=`0` on request | 동일 |
| `0x08` | 2 | `action_tx` | 동일 |
| `0x0a` | 2 | `tx_antenna_mode` | 동일 |
| `0x0c` | 2 | `action_rx` | 동일 |
| `0x0e` | 2 | `rx_antenna_mode` | 동일 |
| `0x10` | 1 | 없음 | `tx_antenna_mode_6g` |
| `0x11` | 1 | 없음 | `rx_antenna_mode_6g` |

Action 값 역시 동일하다.

- SET: Tx=`0x0002`, Rx=`0x0001`
- GET: Tx=`0x0008`, Rx=`0x0004`

2x2 command payload는 main/505에서 8 byte, ported/543에서 10 byte다.
1x1 전용 payload는 두 branch 모두 8 byte이므로 전체 크기도 16 byte로 같다.

### 2.2 `antcfg 0x303 0x101` SET request

`ss ss`는 runtime sequence number다. Target이 9098 2x2이고 6 GHz 인자를
주지 않은 경우, MOAL request는 `kzalloc()`로 생성되므로 ported의 마지막 두
6 GHz byte는 `00 00`이다.

```text
main/505, total 16 bytes
20 00 10 00 ss ss 00 00  02 00 03 03 01 00 01 01

ported/543, total 18 bytes
20 00 12 00 ss ss 00 00  02 00 03 03 01 00 01 01 00 00
```

즉 Rx=`0x0101`은 두 경우 모두 offset `0x0e`에서 `01 01`로 serialize된다.

참고로 1x1 positive control은 다음과 같다.

```text
main/505
20 00 10 00 ss ss 00 00  02 00 01 01 01 00 01 01

ported/543
20 00 12 00 ss ss 00 00  02 00 01 01 01 00 01 01 00 00
```

### 2.3 GET request

Command buffer는 준비 전에 zero-fill되며 GET builder는 action만 채운다.

```text
main/505
20 00 10 00 ss ss 00 00  08 00 00 00 04 00 00 00

ported/543
20 00 12 00 ss ss 00 00  08 00 00 00 04 00 00 00 00 00
```

FW response에서도 2G/5G Tx/Rx 필드 offset은 동일하다. ported parser가
추가로 읽는 것은 끝의 두 6 GHz byte뿐이다.

### 2.4 해석

- ported가 FW에 보내는 `size=18`은 main의 `size=16`과 다른 실제 wire ABI다.
- 하지만 기존 16 byte prefix는 완전히 동일하므로 Rx-only 요청이 Tx/Rx 대칭
  값으로 바뀌는 현상을 host-side field shift로 설명할 수 없다.
- FW가 SET response에서 Rx=`0x101`을 반환해 host `user_htstream=0x2121`을
  만들고, 이후 GET에서는 physical Rx=`0x303`을 반환할 수 있다.
- 현재 instrumentation의 `ANTCFG_DIAG hostcmd`와 `ANTCFG_DIAG response`에서
  각각 `size`, request bytes에 대응하는 필드, FW response 값을 확인할 수 있다.

관련 source:

- main: `mlan/mlan_fw.h:5284-5293`, `mlan/mlan_cmdevt.c:7744-7817`
- ported: `mlan/mlan_fw.h:5491-5504`, `mlan/mlan_cmdevt.c:8483-8558`
- zero-fill: main `mlinux/moal_main.c:9741-9763`, ported
  `mlinux/moal_main.c:10866-10889`

## 3. scan 시작 공통 경로

cfg80211 scan은 두 branch 모두 다음 순서로 들어간다.

```text
iw/nl80211
  -> woal_cfg80211_scan()
  -> woal_do_scan()
  -> woal_request_userscan()
  -> wlan_scan_ioctl(MLAN_OID_SCAN_USER_CONFIG)
  -> wlan_scan_networks()
  -> wlan_scan_setup_scan_config()
  -> wlan_scan_channel_list()
  -> one or more HostCmd nodes in scan_pending_q
  -> first node moved to cmd_pending_q
  -> scan_processing=1, scan_state=SCAN_START
  -> host_to_card()
```

Scan config의 `ext` 값은 두 branch에서 동일하게 해석된다.

- `1`: legacy scan (`HostCmd 0x0006`)
- `2`: default extended scan (`HostCmd 0x0107`, type 0)
- `3`: enhanced extended scan (`HostCmd 0x0107`, type 1)

Enhanced mode는 FW capability `ENHANCE_EXT_SCAN_ENABLE`도 필요하다. 정확한
runtime 경로는 module/init config만으로 추정하지 말고 HostCmd type과 event
순서로 판정해야 한다.

## 4. 경로별 command/event 순서

### 4.1 legacy scan

```text
DNLD_CMD SCAN [0x0006]
  -> FW CMD_RESP [0x8006], response body에 scan results 포함
  -> wlan_ret_802_11_scan()
     -> scan_pending_q가 있으면 다음 0x0006 실행
     -> 없으면 scan_processing=0, IOCTL complete
  -> MLAN_EVENT_ID_DRV_SCAN_REPORT
  -> cfg80211 result inform + cfg80211_scan_done()
```

별도의 FW scan-complete event는 없다. command response가 결과와 batch 완료
경계다.

### 4.2 default extended scan, type 0

HostCmd 구조체 주석에 type 0은 **ext scan report event 뒤에 command response가
오는 방식**으로 정의돼 있다.

```text
DNLD_CMD SCAN_EXT [0x0107, type=0]
  -> EVENT_EXT_SCAN_REPORT [0x0058, more_event=1] ...
  -> EVENT_EXT_SCAN_REPORT [0x0058, more_event=0]
     -> scan_pending_q가 있으면 다음 scan node를 cmd_pending_q로 이동
     -> 없으면 scan_processing=0, SCAN_COMPLETE, IOCTL complete
        -> MLAN_EVENT_ID_DRV_SCAN_REPORT
  -> FW CMD_RESP [0x8107]
     -> wlan_ret_802_11_scan_ext(), optional channel stats 처리
```

따라서 마지막 report event만으로 host scan completion이 발생할 수 있다.
driver에는 그 직후 별도 home-channel restore 또는 restore 확인 handshake가 없다.

### 4.3 enhanced extended scan, type 1

Type 1은 command response가 report event보다 먼저 온다.

```text
DNLD_CMD SCAN_EXT [0x0107, type=1]
  -> FW CMD_RESP [0x8107]
     -> 20초 command/scan timer 시작
  -> EVENT_EXT_SCAN_REPORT [0x0058] ...
  -> EVENT_EXT_SCAN_STATUS_REPORT [0x007f]
     -> pending scan node가 있으면 다음 node 실행
     -> 없으면 timer 정지, scan results 처리
        -> scan_processing=0, SCAN_COMPLETE, IOCTL complete
        -> enhanced-scan 동안 보류한 command를 cmd_pending_q로 복귀
        -> MLAN_EVENT_ID_DRV_SCAN_REPORT
  -> cfg80211 result inform + cfg80211_scan_done()
```

### 4.4 MLAN 이후 main/ported 차이

| 항목 | main/505 | ported/543 |
|---|---|---|
| `MLAN_EVENT_ID_DRV_SCAN_REPORT` 처리 | `moal_recv_event()` 안에서 BSS inform 및 `cfg80211_scan_done()` 직접 실행 | event object를 `evt_workqueue`에 넣고 worker에서 실행 |
| normal legacy/default/enhanced 순서 | 위와 동일 | 위와 동일 |
| enhanced final status의 보류 command 복귀 | 수행 | 수행 |
| `EXT_SCAN_CANCEL` command response의 보류 command 복귀 | 없음 | `wlan_move_cmd_to_cmd_pending_q()` 추가 |
| 6 GHz split/RNR phase | 없음 | 조건부 추가 |
| cfg80211 시작 전 pending scan 대응 | 즉시 `-EAGAIN` | 200 ms 한 번 기다린 뒤 `-EAGAIN` |
| connected scan gap | 요청값 사용 | total scan time 기반 `max_gap` 상한 추가 |

4채널 2G/5G 정상 scan이고 cancel/6 GHz 조건이 없다면 MLAN까지의 완료 순서는
동일하다. ported의 async workqueue는 cfg80211 notification 시점을 늦출 수 있지만,
FW current channel/Tx-chain 복구를 실행하거나 검증하지는 않는다.

관련 source:

- common queueing: main `mlan/mlan_scan.c:4289-4400`, ported
  `mlan/mlan_scan.c:5261-5376`
- legacy response: main `mlan/mlan_scan.c:4635-5018`, ported
  `mlan/mlan_scan.c:5695-6088`
- ext command/response: main `mlan/mlan_scan.c:5055-5178`, ported
  `mlan/mlan_scan.c:6126-6253`
- ext report/status event: main `mlan/mlan_scan.c:6870-7142`, ported
  `mlan/mlan_scan.c:8006-8297`
- main synchronous report: `mlinux/moal_shim.c:3213-3291`
- ported deferred report: `mlinux/moal_shim.c:4041-4089`,
  `mlinux/moal_main.c:14625-14654`

## 5. 현재 장애와 직접 연결되는 판정점

1. **default ext path인 경우** 마지막 `EVENT_EXT_SCAN_REPORT`가 host completion
   조건이다. 그 event 시점에 FW가 실제 home channel과 Tx context를 복구했는지
   확인해야 한다.
2. **enhanced path인 경우** `EVENT_EXT_SCAN_STATUS_REPORT`가 completion 조건이다.
   이 시점과 `CFG80211_DONE`, `POST_SCAN_1S` 사이의 channel/rate/NSS를 비교한다.
3. 두 branch 모두 명시적인 restore command가 없으므로 다음 결과가 결정적이다.
   - cache/connection channel과 `fw_chan` 불일치: FW channel-context 복귀 문제 우선
   - channel 일치, Tx NSS/rate 비정상: FW rate/descriptor/Tx-chain 문제 우선
   - channel/rate도 정상인데 ACK failure만 급증: FW Tx-status/RF path 문제 우선
4. ported의 18-byte RF command가 원인 후보인지 판단하려면 FW release별
   `RF_ANTENNA 0x0020` command size 지원 문서 또는 FW-side HostCmd trace가 필요하다.

## 6. `scan_state` 해석 주의사항

두 branch는 `SCAN_STATE_EXT_SCAN_CMDRESP`(bit 4),
`SCAN_STATE_EXT_SCAN_ENH_CMDRESP`(bit 5),
`SCAN_STATE_EXT_SCAN_CANCEL_CMDRESP`(bit 6)를 정의하지만, 현재 source에는 이
세 bit를 set하는 코드가 없다. `wlan_ret_802_11_scan_ext()`도 download 때와 같은
type bit(bit 1/2/3)를 다시 OR한다.

따라서 instrumentation의 `scan_state`에서 다음만 신뢰한다.

- bit 0: scan start
- bit 1/2/3: default/enhanced/cancel ext scan type이 관찰됨
- bit 7/8: ext result/last result event
- bit 9: enhanced status event
- bit 10: scan complete

Command response 도착 여부와 순서는 `CMD_RESP ... SCAN_EXT [0x107]` 로그 또는
별도 response marker로 확인해야 하며 bit 4/5/6으로 판정하면 안 된다.

