# antcfg + scan Tx wedge 계측 드라이버 A/B 결과

날짜: 2026-08-25  
대상: i.MX93 / ported driver `543.p18` / 88Q9098  
상태: 시험 요약 반영 완료, 원본 전체 marker log 대조는 후속

## 1. 결과 요약

| 조건 | Physical Tx/Rx | Host `user_htstream` | 결과 |
|---|---|---|---|
| B: symmetric 1x1 positive control | `0x101/0x101` | `0x1111` | scan 4 재현 |
| A: Rx-NSS-only | 요청 `0x303/0x101`, 실측 `0x303/0x303` | `0x2121` | 60/60 미재현 |
| A marker 보충 | `0x303/0x303` | `0x2121` | 추가 10/10 미재현 |
| 기존 반대 비대칭 | `0x101/0x303` | Tx 1SS/Rx 2SS intent | 60/60 미재현 |

계측 빌드는 B에서 기존 장애를 재현했으므로, 현재 evidence 범위에서
instrumentation이 timing을 바꿔 장애를 숨겼다고 볼 근거는 없다.

## 2. B positive control

- scan 4에서 장애 발생
- `tx failed`: `0 -> 1 -> 36 -> 3206`
- 최종 ping 실패
- `wpa_state=COMPLETED`, BSSID와 주파수 유지
- FW `ack_failure_delta`: 최대 약 6090
- beacon 수신 계속 증가
- carrier/netdev queue/host pending/scan 상태 정상
- FW RF channel은 연결 채널로 정상 복귀
- physical Tx/Rx=`0x101/0x101`과 `user_htstream=0x1111` 유지

이 패턴은 host queue stop이나 association loss가 아니라, scan 완료 뒤 FW/MAC/PHY/RF
송신 또는 ACK 경로가 선택적으로 실패하는 경계와 일치한다. RX beacon/control path와
association state는 계속 살아 있다.

## 3. A Rx-NSS-only control

- 본시험 60회와 marker 보충 10회 모두 scan 완료
- `tx failed`: 60회 종료 시 5, 추가 10회 종료 시 6
- 최종 ping 3/3 성공
- `wpa_state=COMPLETED`, BSSID와 5180 MHz 유지
- 장애 판정 임계값 `delta >= 1000` 미도달
- physical Rx는 firmware가 `0x303`으로 유지/정상화했지만 host Rx NSS intent는
  1SS인 `user_htstream=0x2121` 유지

따라서 **host advertised Rx NSS=1만으로는 장애가 발생하지 않는다.** physical
antenna와 advertised NSS가 분리된 상태 자체도 충분조건이 아니다.

## 4. 현재까지 배제되거나 약해진 가설

| 가설 | 판정 | 근거 |
|---|---|---|
| mlanutl 두 번째 인자 유실 | 배제 | ioctl/HostCmd marker에서 요청값 전달 확인 |
| main antcfg 커스터마이징 누락 | 원인으로 약함 | SET-only/per-direction guard와 VHT/HE clamp가 ported에 존재하고 runtime marker도 intent 유지 확인 |
| host advertised Rx NSS=1 단독 | 충분조건 아님 | A 70회 미재현 |
| host advertised Tx NSS=1 단독 | 충분조건 아님 | 기존 반대 비대칭 60회 미재현 |
| netdev queue wake/pending 고착 | 배제에 가까움 | 장애 중 queue started, host/MLAN pending 0 |
| association loss/roam | 배제 | COMPLETED, BSSID/주파수 유지 |
| home-channel 미복귀 | 현재 관측에서는 배제 | B 장애에서도 FW channel 정상 복귀 |

## 5. 지지되는 조건과 해석 한계

현재 시험 행렬에서 재현된 유일한 조건은 다음 조합이다.

```text
physical Tx=1 path
physical Rx=1 path
host advertised Tx/Rx NSS=1
scan completion
```

따라서 현상은 **physical Tx/Rx가 실제로 동시에 1-path인 상태에서 scan을 수행하는
조건**과 강하게 연관된다. 특히 A와 기존 반대 비대칭 결과를 함께 보면 Tx 1SS 또는
Rx 1SS 어느 한 방향만의 제한은 충분조건이 아니다.

다만 현재 데이터만으로 아래 둘은 아직 분리되지 않는다.

1. physical symmetric 1x1 자체가 충분조건인지
2. physical symmetric 1x1과 host advertised symmetric 1x1/rate context의 상호작용인지

또한 B 한 행만 positive이므로 이를 일반적인 필요조건으로 확정하지 않는다. 현재
FW가 physical `Tx=2/Rx=1` 비대칭을 만들지 못하게 하므로 physical Rx 1-path 단독의
효과도 직접 시험하지 못했다.

## 6. 현재 failure boundary

관측된 정상 경계:

- userspace/HostCmd antcfg 전달
- association 유지와 beacon RX
- host/netdev/MLAN queue와 pending
- scan completion state
- 연결 RF channel 복귀
- physical antenna 및 `user_htstream` 유지

관측된 실패 경계:

- FW `dot11ACKFailureCount` 급증
- 뒤이어 `dot11FailedCount`와 netdev `tx failed` 급증
- outbound ping 소실

따라서 다음 우선순위는 다음과 같다.

1. scan 복귀 직후 FW Tx-chain/RF state
2. FW rate adaptation의 Tx NSS/MCS/BW context
3. host가 만든 TxPD의 cached rate/NSS 및 `tx_control*`
4. FW 내부 Tx completion/status와 ACK 판정

## 7. 다음 최소 분석 입력

새 수정 전에 B의 실패 scan 4와 A의 정상 scan 하나를 동일 phase로 맞춰 다음 원본
marker를 대조한다.

- `PRE_SCAN`, `CFG80211_DONE`, `POST_SCAN_1S`의 `TX_RATE_DIAG`
- scan report 직후 8개의 `TXPD_DIAG`
- 같은 scan id의 `FW_TX_COUNTER_DIAG` 전체 행
- `RF_CHANNEL_DIAG`
- `FW_TX_STATUS_DIAG`가 존재하면 해당 행

판독 기준:

- B에서 post-scan `tx_nss`, MCS/BW 또는 TxPD `tx_control*`만 A/PRE와 달라지면
  rate/descriptor context 가설을 우선한다.
- rate/TxPD와 channel이 정상인데 ACK failure만 폭증하면 host descriptor보다 FW
  Tx-chain/RF/ACK-state 복구를 우선한다.
- `h2c_tx_fail`, `no_ports`, `dwDatErr`, `sdma_stuck`가 함께 증가하지 않으면 SDIO
  전송 경계의 우선순위를 낮춘다.

## 8. 다음 runtime 분리 시험

원본 marker 비교와 병행해 동작 패치 없이 B의 scan channel set만 한 변수씩 바꾼다.

| 시험 | B 상태에서 scan 범위 | 구분 목적 |
|---|---|---|
| E | 연결/home channel 5180 MHz만 | channel 이탈 없이 scan completion 자체가 trigger인지 확인 |
| F | 5 GHz off-channel 하나만 | same-band channel leave/return 경로 확인 |
| G | 2.4 GHz off-band channel 하나만 | band 전환 뒤 Tx-chain/RF context 복귀 확인 |

- E도 재현되면 단순 home-channel 복귀보다 scan completion 시점의 Tx context/RF
  re-enable을 우선한다.
- E는 통과하고 F만 재현되면 same-band off-channel restore를 우선한다.
- F는 통과하고 G에서 재현되면 cross-band RF/chain restore를 우선한다.
- 각 시험은 기존 임계값과 ping 조건을 그대로 사용하고 한 run에서 channel set 외의
  scan interval/dwell/traffic 조건을 바꾸지 않는다.

## 9. host/physical 분리 시험 후보

원본 marker 대조로 rate/descriptor 차이가 확인되지 않을 때만 test-only host override를
사용해 다음 두 셀을 한 번에 하나씩 추가한다.

| 후보 | Physical | Host intent | 구분 목적 |
|---|---|---|---|
| C | `1x1` | `2x2` | physical symmetric 1x1 단독 효과 |
| D | `2x2` | `1x1` | advertised symmetric 1x1 단독 효과 |

이 override는 production 수정안이 아니라 원인 분리용이어야 하며, RF HostCmd를 다시
보내지 않고 host intent만 바꾸거나 그 반대로 physical만 바꾸는 방식으로 한 변수를
고정해야 한다. 현재 단계에서는 원본 marker 비교 전 이 실험이나 동작 수정 패치를
먼저 적용하지 않는다.
