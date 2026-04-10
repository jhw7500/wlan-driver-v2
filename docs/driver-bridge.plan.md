# driver-bridge Planning Document

> **Summary**: wlan-bridge의 유저스페이스 pcap 기반 L2 브릿지를 wlan-driver-v2 MOAL 레이어에 커널 레벨로 이식하여 성능 개선
>
> **Project**: wlan-driver-v2 (NXP 88Q9098 WLAN Driver)
> **Target**: iMX8MP / iMX93
> **Author**: jhw
> **Date**: 2026-04-08
> **Status**: Draft

---

## Executive Summary

| Perspective | Content |
|-------------|---------|
| **Problem** | 유저스페이스 pcap 브릿지(wbridge)는 패킷당 커널-유저-커널 컨텍스트 스위칭 2회, 메모리 복사, 시스템 콜 오버헤드로 고부하/저지연 요구에 한계 |
| **Solution** | wlan-driver-v2의 MOAL 레이어(moal_shim.c)에 브릿지 로직을 삽입하여 RX 경로에서 직접 peer 인터페이스로 skb 포워딩 |
| **Function/UX Effect** | `bridge_mode=1 bridge_peer=eth0` 모듈 파라미터로 로드 시 자동 브릿지 동작. wbridge 프로세스 불필요 |
| **Core Value** | 패킷 포워딩 경로에서 유저스페이스 오버헤드 완전 제거. 지연시간 감소, CPU 사용량 절감, 처리량 향상 |

---

## Context Anchor

| Key | Value |
|-----|-------|
| **WHY** | 유저스페이스 pcap 브릿지의 컨텍스트 스위칭/메모리 복사 오버헤드로 성능 한계 |
| **WHO** | iMX8MP/iMX93 유무선 브릿지 배포 환경 |
| **RISK** | MOAL 레이어 수정으로 드라이버 안정성 영향 가능. 브릿지 버그 시 커널 패닉 위험 |
| **SUCCESS** | 브릿지 모드 로드 후 ETH↔WLAN 양방향 L2 포워딩 동작, 기존 wbridge 대비 지연시간 감소 확인 |
| **SCOPE** | MOAL 레이어 4~5파일 수정, ~400줄 추가. 커널 모듈 파라미터 2개 추가 |

---

## 1. Overview

### 1.1 Purpose

`wlan-bridge/wbridge`의 pcap 기반 유저스페이스 L2 브릿지 로직을 `wlan-driver-v2`의 MOAL(MAC to OS Abstraction Layer)에 커널 레벨로 이식한다. 패킷 포워딩 경로에서 유저스페이스를 완전히 제거하여 지연시간과 CPU 사용량을 줄인다.

### 1.2 Background

현재 유무선 브릿지 아키텍처:

```
[NIC RX] → Kernel → pcap mmap ring → Userspace(wbridge) → pcap_inject → Kernel → [NIC TX]
                     ↑ context switch                      ↑ context switch
```

목표 아키텍처:

```
[NIC RX] → Kernel(MOAL bridge_rx_handler) → dev_queue_xmit(peer_dev) → [NIC TX]
           ↑ 커널 내부에서 직접 포워딩, 유저스페이스 진입 없음
```

**기존 wbridge 성능 병목**:
- pcap_dispatch/pcap_inject 시스템 콜 (패킷 배치당 2회)
- 커널↔유저스페이스 컨텍스트 스위칭 (배치당 2회)
- pcap mmap ring → 유저 버퍼 메모리 접근
- SCHED_FIFO + mlockall + CPU affinity로 최적화해도 커널 레벨 대비 한계

**드라이버 내 기존 브릿지 기능**:
- UAP 모드의 intra-BSS 브릿지(`mlan_uap_txrx.c:617-700`) — 같은 AP에 연결된 STA 간 포워딩
- 본 기능은 **inter-interface** 브릿지 — WLAN과 ETH 인터페이스 간 L2 포워딩

### 1.3 Related Documents

- 현재 유저스페이스 브릿지: `/home/jhw/ai/opencode/projects/wlan-package/wlan-bridge/wbridge/`
- 드라이버 소스: `/home/jhw/ai/opencode/projects/wlan-driver-v2/`
- 드라이버 RX 경로 핵심: `mlinux/moal_shim.c` — `moal_recv_packet()`
- 드라이버 TX 경로 핵심: `mlinux/moal_main.c` — `woal_hard_start_xmit()`
- 기존 intra-BSS 브릿지: `mlan/mlan_uap_txrx.c` — `wlan_process_uap_rx_packet()`

---

## 2. Scope

### 2.1 In Scope

- [ ] `bridge_mode` 모듈 파라미터 추가 (0=off, 1=on, 기본 0)
- [ ] `bridge_peer` 모듈 파라미터 추가 (peer 인터페이스명, 기본 "eth0")
- [ ] MOAL 브릿지 초기화/해제 — peer netdev 참조 관리
- [ ] RX 브릿지 핸들러 — `moal_recv_packet()`에서 브릿지 대상 패킷 판별 및 peer로 포워딩
- [ ] TX 역방향 수신 — peer 인터페이스에서 wlan으로 포워딩하는 rx_handler 등록
- [ ] 패킷 필터링 — MAC/IP/ARP 필터 로직 (wbridge filter.c 이식)
- [ ] VLAN 802.1Q 인식 — VLAN 태그 파싱 및 투명 전달
- [ ] 통계 카운터 — 브릿지 포워딩/드롭/에러 카운터 (`/proc` 또는 `ethtool -S`)
- [ ] 기존 wbridge 기능 동등성 검증

### 2.2 Out of Scope

- MLAN 레이어 수정 (MOAL만 수정)
- 유저스페이스 wbridge 바이너리 제거/수정 (병행 운용 가능)
- 펌웨어 변경
- STP(Spanning Tree Protocol) 지원
- 멀티 peer 인터페이스 브릿지 (1:1 브릿지만)
- setup-irq-affinity.sh 등 시스템 최적화 스크립트 (드라이버 브릿지와 독립)
- Makefile/빌드 스크립트 변경

---

## 3. Requirements

### 3.1 Functional Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-01 | `bridge_mode=1` 모듈 파라미터로 브릿지 활성화 | Must |
| FR-02 | `bridge_peer=eth0` 으로 peer 인터페이스 지정 | Must |
| FR-03 | WLAN→ETH 방향: wlan RX 패킷을 eth TX로 포워딩 | Must |
| FR-04 | ETH→WLAN 방향: eth RX 패킷을 wlan TX로 포워딩 | Must |
| FR-05 | 멀티캐스트/브로드캐스트 패킷 포워딩 (ARP for bridge IP 제외) | Must |
| FR-06 | 유니캐스트 패킷: 자기 MAC/IP 대상 패킷은 드롭 (커널 스택으로 전달) | Must |
| FR-07 | VLAN 802.1Q 태그 인식 및 투명 전달 | Must |
| FR-08 | VLAN ID 기반 필터링 (선택적) | Should |
| FR-09 | 브릿지 통계 카운터 (rx/tx/dropped/errors per direction) | Should |
| FR-10 | `bridge_mode=0` 시 기존 드라이버 동작과 완전 동일 (zero impact) | Must |

### 3.2 Non-Functional Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| NFR-01 | 기존 wbridge 대비 패킷 포워딩 지연시간 감소 | Must |
| NFR-02 | 기존 wbridge 대비 CPU 사용량 감소 | Must |
| NFR-03 | bridge_mode=0 시 성능 페널티 0 (if 분기 1개 수준) | Must |
| NFR-04 | 커널 패닉/메모리 누수 없음 | Must |
| NFR-05 | 드라이버 rmmod 시 브릿지 자원 완전 해제 | Must |
| NFR-06 | peer 인터페이스 down/up 시 graceful 처리 | Should |

### 3.3 Success Criteria

| ID | Criteria | Verification |
|----|----------|-------------|
| SC-01 | `insmod moal.ko bridge_mode=1 bridge_peer=eth0` 로드 후 ETH↔WLAN 양방향 L2 포워딩 동작 | ping 테스트 (유선→무선 / 무선→유선) |
| SC-02 | 브릿지 IP로의 ARP/ICMP는 커널 스택으로 정상 전달 | 브릿지 자체 IP로 ssh 접속 가능 |
| SC-03 | VLAN 태그된 패킷이 변형 없이 투명 전달 | VLAN 태그 유무 패킷 모두 테스트 |
| SC-04 | bridge_mode=0 시 기존 드라이버와 동일 동작 | 기존 Wi-Fi 연결/throughput 테스트 |
| SC-05 | wbridge 대비 CPU 사용량 감소 확인 | iperf3 부하 중 top/mpstat 비교 |
| SC-06 | rmmod moal 시 정상 언로드 (refcount 0, 자원 해제) | 반복 insmod/rmmod 테스트 |

---

## 4. Architecture

### 4.1 현재 아키텍처 (유저스페이스 wbridge)

```
┌─────────────────────────────────────────────────────────┐
│ Userspace                                               │
│  ┌─────────────────────────────────────────────────┐   │
│  │ wbridge process (pcap-based)                     │   │
│  │  Thread0: eth0 RX → parse → filter → wlan0 TX   │   │
│  │  Thread1: wlan0 RX → parse → filter → eth0 TX   │   │
│  └─────────────────────────────────────────────────┘   │
│       ↑ pcap_dispatch          pcap_inject ↓            │
├───────┼────────────────────────────────────┼────────────┤
│ Kernel                                                  │
│  ┌──────────┐                      ┌──────────┐       │
│  │ eth0 drv │                      │ moal drv │       │
│  └──────────┘                      └──────────┘       │
└─────────────────────────────────────────────────────────┘
```

**병목**: 패킷마다 커널→유저→커널 2회 전환, 시스템 콜 오버헤드

### 4.2 목표 아키텍처 (커널 드라이버 브릿지)

```
┌─────────────────────────────────────────────────────────┐
│ Kernel                                                  │
│                                                         │
│  ┌──────────┐    bridge_rx_handler()   ┌──────────┐   │
│  │ eth0 drv │ ◄──────────────────────► │ moal drv │   │
│  └──────────┘    (skb direct fwd)      └──────────┘   │
│       │                                      │         │
│       ▼ (self-destined only)                 ▼         │
│  ┌──────────────────────────────────────────────┐     │
│  │            Kernel Network Stack               │     │
│  └──────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────┘
```

**개선**: 유저스페이스 진입 없이 커널 내부에서 skb 직접 포워딩

### 4.3 데이터 플로우

#### WLAN → ETH 방향 (moal_recv_packet 수정)

```
88Q9098 FW → mlan_rx_process → wlan_handle_rx_packet
    → moal_recv_packet()
        ├── [bridge_mode OFF] → netif_rx(skb)  (기존 경로)
        └── [bridge_mode ON]
            ├── bridge_should_forward(skb)?
            │   ├── YES → skb->dev = peer_dev
            │   │         dev_queue_xmit(skb)  → ETH TX
            │   └── NO  → netif_rx(skb)  (커널 스택으로)
```

#### ETH → WLAN 방향 (netdev_rx_handler 등록)

```
eth0 NIC → eth0 driver RX
    → netif_receive_skb()
        → bridge_peer_rx_handler()  (rx_handler로 등록)
            ├── bridge_should_forward(skb)?
            │   ├── YES → skb->dev = wlan_dev
            │   │         woal_hard_start_xmit(skb)  → WLAN TX
            │   └── NO  → RX_HANDLER_PASS  (커널 스택으로)
```

---

## 5. Technical Design

### 5.1 모듈 파라미터

```c
/* moal_main.c 또는 신규 moal_bridge.c */
static int bridge_mode = 0;
module_param(bridge_mode, int, 0644);
MODULE_PARM_DESC(bridge_mode, "L2 bridge mode: 0=off(default), 1=on");

static char *bridge_peer = "eth0";
module_param(bridge_peer, charp, 0644);
MODULE_PARM_DESC(bridge_peer, "Bridge peer interface name (default: eth0)");
```

### 5.2 핵심 데이터 구조

```c
/* moal_bridge.h */
struct moal_bridge {
    struct net_device *peer_dev;     /* peer 인터페이스 (eth0) */
    struct net_device *wlan_dev;     /* wlan 인터페이스 */
    atomic_t enabled;                /* 브릿지 활성화 상태 */

    /* 필터 설정 (wbridge filter.c에서 이식) */
    uint8_t self_mac[ETH_ALEN];     /* wlan MAC */
    uint8_t peer_mac[ETH_ALEN];     /* eth MAC */
    uint32_t self_ipv4;             /* wlan IPv4 */
    uint32_t peer_ipv4;             /* eth IPv4 */

    /* 통계 */
    struct {
        atomic_long_t rx_packets;    /* peer에서 수신 */
        atomic_long_t tx_packets;    /* peer로 포워딩 */
        atomic_long_t dropped;       /* 필터링된 패킷 */
        atomic_long_t errors;        /* 포워딩 실패 */
    } stats;
};
```

### 5.3 핵심 함수

| 함수 | 위치 | 역할 |
|------|------|------|
| `moal_bridge_init()` | moal_bridge.c | peer_dev 참조 획득, rx_handler 등록 |
| `moal_bridge_deinit()` | moal_bridge.c | rx_handler 해제, peer_dev 참조 반환 |
| `moal_bridge_should_forward()` | moal_bridge.c | 패킷 필터 판정 (MAC/IP/ARP/VLAN) |
| `moal_bridge_forward_to_peer()` | moal_bridge.c | WLAN→ETH skb 포워딩 |
| `moal_bridge_peer_rx_handler()` | moal_bridge.c | ETH→WLAN rx_handler 콜백 |

### 5.4 수정 대상 파일

| 파일 | 변경 내용 | 예상 줄수 |
|------|-----------|-----------|
| `mlinux/moal_bridge.c` (신규) | 브릿지 코어 로직 (init/deinit/filter/forward) | ~250줄 |
| `mlinux/moal_bridge.h` (신규) | 브릿지 데이터 구조/인터페이스 | ~50줄 |
| `mlinux/moal_main.c` | 모듈 파라미터 추가, init/cleanup에서 bridge init/deinit 호출 | ~30줄 |
| `mlinux/moal_main.h` | moal_handle에 bridge 포인터 추가 | ~5줄 |
| `mlinux/moal_shim.c` | moal_recv_packet()에 bridge forward 분기 추가 | ~15줄 |
| `Makefile` | moal_bridge.o 빌드 추가 | ~3줄 |
| **합계** | | **~353줄** |

---

## 6. Risk Analysis

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| bridge_should_forward 버그로 자기 패킷 드롭 → 통신 단절 | Critical | Medium | 기존 wbridge filter.c 로직 검증 완료된 것을 이식. bridge_mode=0 폴백 |
| peer_dev 참조 누수로 eth0 rmmod 불가 | High | Low | dev_hold/dev_put 쌍 보장. netdev notifier로 peer down 감지 |
| skb 소유권 혼란으로 double free / use-after-free | Critical | Medium | 포워딩 시 skb_clone() 사용 여부 명확히 결정. RCU 보호 |
| 브릿지 루프 (패킷이 양쪽으로 무한 순환) | Critical | Low | pcap_setdirection(PCAP_D_IN) 대응: skb->dev 체크로 자기가 보낸 패킷 재수신 방지 |
| bridge_mode=0 시에도 성능 저하 | Medium | Low | if 분기 1개(atomic_read) 수준으로 최소화. unlikely() 매크로 |
| VLAN 태그 파싱 오류 | Medium | Low | wbridge packet.c의 검증된 VLAN 파싱 로직 이식 |

---

## 7. Implementation Plan

### Phase 1: 기반 구조 (moal_bridge.c/h 생성)

1. `moal_bridge.h` — 데이터 구조 정의
2. `moal_bridge.c` — init/deinit 스켈레톤
3. `moal_main.c` — 모듈 파라미터 추가 (`bridge_mode`, `bridge_peer`)
4. `moal_main.h` — `moal_handle`에 `struct moal_bridge *bridge` 추가
5. `Makefile` — `moal_bridge.o` 빌드 추가
6. 검증: `bridge_mode=0`으로 로드 시 기존 동작 동일

### Phase 2: WLAN→ETH 포워딩

1. `moal_bridge_should_forward()` — wbridge filter.c 로직 이식
   - 멀티캐스트/브로드캐스트 처리
   - 자기 MAC/IP 판별
   - ARP for bridge IP 판별
   - VLAN 태그 파싱
2. `moal_bridge_forward_to_peer()` — skb를 peer_dev로 포워딩
3. `moal_shim.c::moal_recv_packet()` — bridge forward 분기 삽입
4. 검증: wlan에서 수신한 패킷이 eth0으로 나가는지 확인

### Phase 3: ETH→WLAN 포워딩

1. `moal_bridge_peer_rx_handler()` — `netdev_rx_handler_register()` 콜백
2. `moal_bridge_init()` — peer_dev에 rx_handler 등록
3. `moal_bridge_deinit()` — rx_handler 해제
4. 검증: eth0에서 수신한 패킷이 wlan으로 나가는지 확인

### Phase 4: 안정성/자원 관리

1. netdev notifier — peer 인터페이스 down/unregister 감지
2. dev_hold/dev_put 참조 카운트 관리
3. rmmod 시 정리 순서 검증
4. 반복 insmod/rmmod 스트레스 테스트

### Phase 5: 통계 및 검증

1. 브릿지 통계 카운터 구현
2. 기존 wbridge 대비 성능 비교 (iperf3 + CPU 사용량)
3. 엣지 케이스 테스트 (VLAN, 대용량 패킷, 브로드캐스트 스톰)

---

## 8. Testing Strategy

### 8.1 기능 테스트

| Test | Method |
|------|--------|
| 기본 포워딩 | ETH↔WLAN 양방향 ping |
| 자기 IP 접근 | 브릿지 자체 IP로 ssh |
| ARP 처리 | 브릿지 IP의 ARP reply 정상 |
| VLAN 투명 전달 | VLAN 태그 패킷 양방향 포워딩 |
| bridge_mode=0 | 기존 Wi-Fi 연결/동작 동일 |

### 8.2 안정성 테스트

| Test | Method |
|------|--------|
| 장시간 운용 | iperf3 24시간 연속 테스트 |
| insmod/rmmod 반복 | 100회 반복 로드/언로드 |
| peer down/up | eth0 ifdown/ifup 중 동작 |
| 고부하 | iperf3 UDP flood 중 안정성 |

### 8.3 성능 테스트

| Metric | Tool | 비교 대상 |
|--------|------|-----------|
| Throughput | iperf3 TCP/UDP | wbridge vs driver-bridge |
| Latency | ping RTT | wbridge vs driver-bridge |
| CPU Usage | mpstat / top | wbridge vs driver-bridge |
| Packet Loss | iperf3 UDP | 고부하 시 손실률 비교 |

---

## 9. Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| wlan-driver-v2 소스 | Available | `/home/jhw/ai/opencode/projects/wlan-driver-v2/` |
| wlan-bridge 소스 (참조) | Available | `/home/jhw/ai/opencode/projects/wlan-package/wlan-bridge/wbridge/` |
| iMX8MP 타겟 보드 | Required | 실제 테스트용 |
| Linux 커널 헤더 | Required | 크로스 컴파일용 (NXP BSP) |

---

## 10. Glossary

| Term | Definition |
|------|-----------|
| MOAL | MAC to OS Abstraction Layer — 리눅스 커널과 MLAN 사이 어댑터 레이어 |
| MLAN | MAC LAN — 하드웨어 독립적 WiFi 프로토콜 처리 레이어 |
| rx_handler | 커널 netdev의 수신 핸들러 — `netdev_rx_handler_register()`로 등록 |
| skb | sk_buff — 리눅스 커널 네트워크 패킷 버퍼 |
| peer_dev | 브릿지 상대방 네트워크 인터페이스 (eth0) |
| pcap | Packet Capture — 유저스페이스 패킷 캡처 라이브러리 |
| intra-BSS | 같은 AP에 연결된 무선 스테이션 간 통신 |
| inter-interface | 서로 다른 네트워크 인터페이스 간 통신 |
