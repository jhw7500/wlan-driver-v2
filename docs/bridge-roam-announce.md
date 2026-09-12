# Bridge Roam Announce 운영 및 검증 가이드

> **목적**: 투명 L2 브리지 제품에서 로밍 직후 클론 MAC의 새 위치를 상단 유선
> 스위치가 즉시 재학습하도록 드라이버가 Layer-2 Update 프레임을 발사한다.
>
> **대상**: `bridge_mode=1`인 MOAL STA 브리지
>
> **상태**: 구현·병합·단일 AP rig 메커니즘 A/B 완료, 듀얼 AP end-to-end 갭
> 소멸 검증은 미완료
>
> **관련 이슈/PR**: [wlan-driver-v2#47](https://github.com/jhw7500/wlan-driver-v2/issues/47),
> [wlan-driver-v2#48](https://github.com/jhw7500/wlan-driver-v2/pull/48)
>
> **최종 갱신**: 2026-09-09

---

## 1. 문제와 범위

무선 전용 제품에서는 로밍 이벤트 직후 장치 자기 IP로 GARP를 보내 STA MAC을
재공지할 수 있다. 그러나 MAC 클론 투명 브리지에서는 유선망이 재학습해야 하는
주소가 STA 고유 MAC이 아니라 **클론된 유선 클라이언트 MAC**이다. 장치 자기 IP를
사용하는 GARP만으로는 이 MAC을 재공지할 수 없다.

`bridge_roam_announce`는 IP를 사용하지 않는다. 로밍/링크업 완료 시 현재 WLAN
`dev_addr`를 소스 MAC으로 하는 802.2 LLC XID 브로드캐스트를 공중으로 보내, 새 AP
뒤의 유선 스위치가 프레임의 source address를 보고 FDB를 갱신하게 한다.

초기 분석의 "STA 자기 GARP가 약 4초 뒤 발생해 회복을 일으켰다"는 설명은 pcap
전수 재검증 후 철회됐다. 해당 프레임은 제3장치의 who-has에 대한 유니캐스트 ARP
응답이었다. 다만 **로밍한 MAC이 유선에 다시 나타날 때 통신이 회복된다**는 핵심
관측과 L2 재공지 필요성은 유지된다.

---

## 2. 동작 구조

```text
association/reassociation 성공
        |
        +-- MLAN_EVENT_ID_DRV_CONNECTED
        |      media_connected = MTRUE
        |      -> moal_bridge_announce_link_up()
        |
        +-- MLAN_EVENT_ID_FW_PORT_RELEASE
               보안망 키 설치 후 데이터 포트 개방
               -> moal_bridge_announce_link_up() 재호출

moal_bridge_announce_link_up()
        |
        +-- bridge_roam_announce != 0
        +-- bridge instance active
        +-- event BSS == bridge-owned BSS
        +-- WLAN netdev ready
        |
        -> clone-MAC sourced LLC XID frame
        -> p2w_queue
        -> dedicated p2w kthread
        -> dev_queue_xmit(wlan_dev)
```

`DRV_CONNECTED`와 `FW_PORT_RELEASE`의 이중 호출은 의도된 동작이다. 보안망에서 첫
프레임이 키 설치 전에 유실될 수 있어 포트가 열린 뒤 다시 발사한다. 환경에 따라
링크업 한 번에 카운터가 두 번 증가할 수 있다. UAP의
`MLAN_EVENT_ID_UAP_FW_BSS_ACTIVE`는 STA 로밍이 아니므로 훅하지 않는다.

### 2.1 발사 프레임

| 필드 | 값 |
|---|---|
| Destination MAC | `ff:ff:ff:ff:ff:ff` |
| Source MAC | 현재 `wlan_dev->dev_addr`(클론 MAC) |
| 802.3 length | `0x0006` |
| LLC XID payload | `00 01 af 81 01 00` |
| Ethernet frame size | 60 bytes, zero padding |
| IP/ARP 정보 | 사용하지 않음 |

프레임은 hostapd의 Layer-2 Update와 같은 형식이다. 어떤 호스트 IP도 필요하지
않고 ARP 캐시도 변경하지 않는다.

---

## 3. 설정

### 3.1 기본값과 범위

| 항목 | 값 |
|---|---|
| 파라미터 | `bridge_roam_announce` |
| 타입 | `int` |
| 기본값 | `0`(off) |
| sysfs permission | `0644` |
| 런타임 변경 | 가능 |
| `wifi_mod_para.conf` 직접 파싱 | 지원하지 않음 |
| 적용 범위 | 모듈 전역 정책, 실제 발화는 bridge-owned BSS로 제한 |

이 파라미터는 카드 블록별 설정인 `wifi_mod_para.conf`에서 직접 파싱하지 않는다.
제품 패키지가 설정을 제공하는 경우 최종적으로 MOAL 모듈 인자 또는 sysfs 값으로
전달해야 한다.

### 3.2 모듈 로드 시 활성화

```bash
insmod moal.ko ... bridge_mode=1 bridge_roam_announce=1
```

실제 제품의 모듈 파일명과 기존 필수 인자는 배포 환경을 따른다.

### 3.3 런타임 확인·변경

```bash
cat /sys/module/moal/parameters/bridge_roam_announce
echo 1 > /sys/module/moal/parameters/bridge_roam_announce
cat /sys/module/moal/parameters/bridge_roam_announce
```

마지막 출력이 `1`이어야 한다. 값을 `1`로 바꾸는 행위 자체는 프레임을 발사하지
않는다. 그 뒤 `DRV_CONNECTED` 또는 `FW_PORT_RELEASE` 이벤트가 발생해야 한다.

런타임 비활성화:

```bash
echo 0 > /sys/module/moal/parameters/bridge_roam_announce
```

---

## 4. 관측 방법

### 4.1 sysfs 카운터: 권장 1차 확인

```bash
grep -E '^(active=|announce |iface=)' /sys/kernel/moal_bridge/stats
```

정상 예:

```text
active=1 peer_released=0
announce on=1 tx=3
iface=mlan0 peer=eth0 pending_iface=none pending_state=none
```

| 필드 | 의미 |
|---|---|
| `active=1` | 드라이버 브리지 인스턴스 활성 |
| `announce on=1` | 런타임 announce 게이트 활성 |
| `announce tx=N` | announce 프레임의 p2w 큐 인큐 성공 누계 |

`announce tx`는 **실제 공중 송신 완료 카운터가 아니라 인큐 성공 카운터**다. 로밍
전후에 값이 증가하면 훅과 프레임 생성은 실행된 것이다. 최종 송신은 §4.3 캡처로
확인한다.

### 4.2 커널 로그

announce 전용 로그는 `bridge_debug=1`일 때만 출력된다.

```bash
echo 1 > /sys/module/moal/parameters/bridge_debug
dmesg -w | grep -E 'bridge: (announce link-up|p2w_thread)'
```

로밍/재연결 시 기대 로그:

```text
bridge: announce link-up src=90:2c:fb:00:f0:88
bridge: p2w_thread cpu=1 1 pkts
```

첫 번째 줄은 announce 프레임의 생성과 인큐를 직접 나타낸다. 두 번째 줄은 p2w
worker가 해당 시점의 큐 batch를 처리했다는 뜻이며 announce 전용 로그는 아니다.

`bridge_debug=1`은 다른 브리지 패킷별 로그와 지연 계측도 활성화해 로그가 크게
증가할 수 있다. 짧은 진단 구간에서만 사용하고 종료 후 끈다.

```bash
echo 0 > /sys/module/moal/parameters/bridge_debug
```

브리지 해제 시에는 MMSG 로그가 허용된 환경에서 누계가 다음과 같이 출력된다.

```text
bridge: announce tx=N
```

### 4.3 실제 WLAN TX 프레임

```bash
tcpdump -i mlan0 -Q out -e -xx 'ether[12:2] = 6'
```

`-Q out`을 지원하지 않는 tcpdump에서는 다음처럼 실행하고 방향을 별도로 판독한다.

```bash
tcpdump -i mlan0 -e -xx 'ether[12:2] = 6'
```

기대 바이트 배열:

```text
ffff ffff ffff <clone-mac-6-bytes> 0006 0001 af81 0100 ...
```

다음 세 조건을 모두 확인한다.

1. destination이 broadcast다.
2. source가 현재 클론 MAC과 일치한다.
3. `0006 0001 af81 0100`이 연속해서 나타난다.

---

## 5. 권장 A/B 검증

### 5.1 사전 상태

```bash
cat /sys/module/moal/parameters/bridge_roam_announce
grep -E '^(active=|announce |iface=|p2w )' /sys/kernel/moal_bridge/stats
ip link show mlan0
```

`active=1`, 올바른 `iface`/`peer`, 연결된 STA 상태를 확인한다.

### 5.2 OFF 기준선

```bash
echo 0 > /sys/module/moal/parameters/bridge_roam_announce
grep '^announce ' /sys/kernel/moal_bridge/stats
```

로밍 또는 재연결을 수행한다. `announce tx`가 증가하지 않고 대상 XID 프레임도
캡처되지 않아야 한다.

### 5.3 ON 동작

```bash
echo 1 > /sys/module/moal/parameters/bridge_roam_announce
echo 1 > /sys/module/moal/parameters/bridge_debug
grep '^announce ' /sys/kernel/moal_bridge/stats
```

별도 터미널에서 §4.2 로그와 §4.3 tcpdump를 실행한 뒤 정상 로밍을 유도한다.
수동 로밍을 지원하는 구성에서는 다음 형식을 사용할 수 있다.

```bash
wpa_cli -i mlan0 roam <TARGET_BSSID>
```

로밍 후 확인:

```bash
grep -E '^(announce |p2w )' /sys/kernel/moal_bridge/stats
```

`announce tx` 증가, `announce link-up` 로그, 대상 XID 프레임 캡처를 대조한다.

### 5.4 OFF 회귀

```bash
echo 0 > /sys/module/moal/parameters/bridge_roam_announce
echo 0 > /sys/module/moal/parameters/bridge_debug
```

다시 로밍했을 때 `announce tx`가 동결되고 대상 프레임이 사라지는지 확인한다.

### 5.5 end-to-end 검증

연속 ping fail 해결 여부는 클론된 유선 클라이언트를 실제 종단으로 사용해야 한다.
`mlan0` 자체 IP를 ping하면 브리지 경로를 통과하지 않으므로 검증으로 인정할 수 없다.

권장 조건:

1. L2 Update를 자체 발사하지 않는 제어 가능한 AP 2대를 같은 유선 세그먼트에 둔다.
2. 유선 peer에 클론 MAC 대상의 정적 neighbor를 설정해 rescue ARP 영향을 막는다.
3. 클론된 유선 클라이언트의 자발적 상향 트래픽을 멈춘다.
4. 외부 peer에서 해당 유선 클라이언트로 하향 전용 연속 ping을 보낸다.
5. announce OFF/ON 각각에서 반복 로밍하고 손실 구간, XID 프레임, 스위치 FDB를 대조한다.

---

## 6. 결과 해석과 트러블슈팅

| 관측 | 해석 / 다음 확인 |
|---|---|
| 파라미터 sysfs 파일 없음 | 구버전 또는 해당 기능이 없는 `moal` 모듈 확인 |
| `announce on=0` | 기능 비활성; 모듈 인자 또는 sysfs 값을 확인 |
| stats 파일 없음 | 브리지 미초기화, `bridge_mode`, 모듈 로드 상태 확인 |
| `active=0` | peer/WLAN down 또는 브리지 suspend 상태 확인 |
| `on=1`인데 `tx` 불변 | 연결 이벤트 미발생, bridge-owned BSS 불일치, WLAN readiness 확인 |
| `tx` 증가, debug 로그 없음 | `bridge_debug=0`인지 확인 |
| `tx` 증가, 실제 프레임 없음 | `p2w drop/err`, WLAN 상태, 큐 처리 및 tcpdump 방향 확인 |
| 프레임 존재, ping 갭 지속 | AP 측 상향 포워딩 지연 또는 다른 FDB 경로를 별도 판별 |

`p2w fwd/drop/err`는 announce 전용 카운터가 아니라 전체 peer-to-WLAN 경로의 누계다.
따라서 `announce tx`와 같은 시점의 변화량, 커널 로그, 프레임 캡처를 함께 본다.

---

## 7. 현재 검증 상태

| 항목 | 상태 |
|---|---|
| 빌드 및 정적 검사 | 완료 |
| 기본값 OFF 확인 | 완료 |
| 런타임 OFF -> ON -> OFF 토글 | 완료 |
| ON 재결합 시 `announce tx` 증가 | 완료 |
| 60B LLC XID 바이트 및 source clone MAC 캡처 | 완료 |
| ON 상태 live roam 부작용 확인 | 완료 |
| 듀얼 AP에서 원래 2~5초 ping 갭 소멸 A/B | 미완료 |

메커니즘 검증과 문제 종결 검증을 구분한다. 현재 증거는 드라이버가 의도한 프레임을
생성·송신한다는 것까지 확인한다. 원래 환경의 연속 ping fail이 사라지는지는 듀얼 AP
제품 토폴로지에서 별도로 검증해야 한다.

---

## 8. 코드와 근거

| 항목 | 위치 |
|---|---|
| module parameter 선언/설명 | `mlinux/moal_init.c:119`, `mlinux/moal_init.c:3993-3994` |
| DRV_CONNECTED 훅 | `mlinux/moal_shim.c:3938`, `mlinux/moal_shim.c:4005` |
| FW_PORT_RELEASE 훅 | `mlinux/moal_shim.c:4386`, `mlinux/moal_shim.c:4398` |
| announce 구현 | `mlinux/moal_bridge.c:1092-1173` |
| debug 로그 | `mlinux/moal_bridge.c:1170` |
| sysfs stats | `mlinux/moal_bridge.c:1857`, `mlinux/moal_bridge.c:1894-1895` |
| deinit 누계 로그 | `mlinux/moal_bridge.c:2423-2424` |
| 구현 커밋 | `2f442df`, `ebe3c22`, `f8a998a` |
| 병합 커밋 | `e89ba5f` |

추가 근거:

- [Issue #47: 로밍 후 클론-MAC 유선 재학습 갭](https://github.com/jhw7500/wlan-driver-v2/issues/47)
- [PR #48: 로밍 링크업 시 클론 MAC L2 announce](https://github.com/jhw7500/wlan-driver-v2/pull/48)
- [PR #48 보드 프레임 A/B 결과](https://github.com/jhw7500/wlan-driver-v2/pull/48#issuecomment-5491202372)
- [원인 분석 고객 회신 아티팩트](https://claude.ai/code/artifact/233a14fe-4775-4823-a49a-8e2479f152f8)

