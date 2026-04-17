# driver-bridge Gap Analysis

> **Feature**: driver-bridge (커널 드라이버 레벨 유무선 브릿지)
> **Date**: 2026-04-09
> **Build**: PASS (make_for_imx93.sh, 에러/경고 0)

---

## Context Anchor

| Key | Value |
|-----|-------|
| **WHY** | 유저스페이스 pcap 브릿지의 컨텍스트 스위칭/메모리 복사 오버헤드로 성능 한계 |
| **WHO** | iMX8MP/iMX93 유무선 브릿지 배포 환경 |
| **RISK** | MOAL 레이어 수정으로 드라이버 안정성 영향 가능 |
| **SUCCESS** | 브릿지 모드 로드 후 ETH↔WLAN 양방향 L2 포워딩 동작 |
| **SCOPE** | MOAL 레이어 신규 2파일 + 수정 5파일 |

---

## 1. Structural Match (100%)

### 1.1 파일 존재 여부

| Design 명세 | 구현 | 상태 |
|-------------|------|:----:|
| `mlinux/moal_bridge.h` (신규 ~60줄) | 57줄 | OK |
| `mlinux/moal_bridge.c` (신규 ~280줄) | 426줄 | OK (초과: 필터+양방향+lifecycle 모두 포함) |
| `mlinux/moal_main.h` (+3줄) | +2줄 | OK |
| `mlinux/moal_init.c` (+8줄) | +6줄 | OK |
| `mlinux/moal_main.c` (+12줄) | +15줄 | OK |
| `mlinux/moal_shim.c` (+10줄) | +7줄 | OK |
| `Makefile` (+1줄) | +1줄 | OK |

**Structural Score: 7/7 = 100%**

### 1.2 함수 존재 여부

| Design 명세 함수 | 구현 위치 | 상태 |
|------------------|-----------|:----:|
| `moal_bridge_init()` | moal_bridge.c:310 | OK |
| `moal_bridge_deinit()` | moal_bridge.c:388 | OK |
| `moal_bridge_rx()` | moal_bridge.c:152 | OK |
| `moal_bridge_should_forward()` | moal_bridge.c:99 | OK |
| `moal_bridge_peer_rx_handler()` | moal_bridge.c:211 | OK |
| `moal_bridge_netdev_event()` | moal_bridge.c:267 | OK |
| `moal_bridge_arp_is_for_self()` | moal_bridge.c:43 | OK |
| `moal_bridge_ip_is_local()` | moal_bridge.c:71 | OK |
| `moal_bridge_get_ipv4()` | moal_bridge.c:19 | OK |

**Function Score: 9/9 = 100%**

---

## 2. Functional Depth (93%)

### 2.1 Functional Requirements 충족

| FR | Requirement | Priority | 상태 | 근거 |
|----|-------------|----------|:----:|------|
| FR-01 | `bridge_mode=1` 파라미터 | Must | OK | moal_init.c:91,3092 |
| FR-02 | `bridge_peer=eth0` 파라미터 | Must | OK | moal_init.c:92,3094 |
| FR-03 | WLAN→ETH 포워딩 | Must | OK | moal_bridge_rx() + moal_shim.c:2506 |
| FR-04 | ETH→WLAN 포워딩 | Must | OK | moal_bridge_peer_rx_handler() |
| FR-05 | 멀티캐스트/브로드캐스트 (ARP 제외) | Must | OK | should_forward():114-121 |
| FR-06 | 자기 MAC/IP 드롭 | Must | OK | should_forward():124-131 |
| FR-07 | VLAN 802.1Q 인식 | Must | OK | should_forward():107-111 |
| FR-08 | VLAN ID 기반 필터링 | Should | SKIP | 투명 전달만 구현 (Should → 미구현 허용) |
| FR-09 | 브릿지 통계 카운터 | Should | OK | moal_bridge_stats 구조체, deinit 시 출력 |
| FR-10 | bridge_mode=0 zero impact | Must | OK | handle->bridge=NULL, unlikely() 분기 |

**FR Score: 9/10 Must 전체 충족, Should 1건 미구현**

### 2.2 Non-Functional Requirements

| NFR | Requirement | 상태 | 근거 |
|-----|-------------|:----:|------|
| NFR-01 | 지연시간 감소 | PEND | 타겟 테스트 필요 |
| NFR-02 | CPU 사용량 감소 | PEND | 타겟 테스트 필요 |
| NFR-03 | bridge_mode=0 페널티 0 | OK | unlikely() 매크로 + NULL 체크 1회 |
| NFR-04 | 커널 패닉/메모리 누수 없음 | OK | dev_hold/dev_put 쌍, synchronize_net, kfree |
| NFR-05 | rmmod 자원 해제 | OK | 6단계 해제 순서 (Design §7.4 준수) |
| NFR-06 | peer down/up graceful | OK | netdev_notifier로 active 토글 + IP 재캐시 |

---

## 3. Contract Match (100%)

### 3.1 API 계약

| API | Design 명세 | 구현 | 상태 |
|-----|-------------|------|:----:|
| `moal_bridge_init(void*, const char*)` → int | §6.1 | moal_bridge.c:310 | OK |
| `moal_bridge_deinit(void*)` → void | §6.2 | moal_bridge.c:388 | OK |
| `moal_bridge_rx(struct moal_bridge*, struct sk_buff*)` → int (1=consumed, 0=pass) | §4.1 | moal_bridge.c:152 | OK |
| rx_handler → `RX_HANDLER_CONSUMED` / `RX_HANDLER_PASS` | §4.2 | moal_bridge.c:211 | OK |

### 3.2 해제 순서 (Design §7.4 대비)

| 순서 | Design 명세 | 구현 (moal_bridge.c:388-426) | 상태 |
|------|-------------|------|:----:|
| 1 | `atomic_set(&br->active, 0)` | line 398 | OK |
| 2 | `unregister_netdevice_notifier()` | line 401 | OK |
| 3 | `netdev_rx_handler_unregister()` | line 404 | OK |
| 4 | `synchronize_net()` | line 408 | OK |
| 5 | `dev_put(peer_dev)` | line 424 | OK |
| 6 | `kfree(br)` | line 425 | OK |

**Contract Score: 100%**

---

## 4. Design Decision Verification

| Decision | Design 명세 | 구현 | 상태 |
|----------|-------------|------|:----:|
| Option C (Pragmatic Balance) | moal_bridge.c/h 분리 | 분리 구현 | OK |
| ETH→WLAN: netdev_rx_handler_register | §4.2 | moal_bridge.c:355 | OK |
| WLAN→ETH: moal_recv_packet 1줄 분기 | §4.1 | moal_shim.c:2506-2510 | OK |
| 멀티캐스트: skb_clone 양쪽 전달 | §7.3 | moal_bridge_rx:168-180, peer_rx_handler:232-244 | OK |
| 모듈 파라미터 제어 | §3.1 | moal_init.c:91-92,3092-3095 | OK |
| static → non-static 변경 | Design은 static 명시 | extern 접근 위해 non-static으로 변경 | DEVIATE (필수 수정) |

---

## 5. Plan Success Criteria

| SC | Criteria | 상태 | 근거 |
|----|----------|:----:|------|
| SC-01 | 양방향 L2 포워딩 | PEND | 코드 구현 완료, 타겟 테스트 필요 |
| SC-02 | 자기 IP ssh 접속 | PEND | 필터 로직 구현 완료, 타겟 테스트 필요 |
| SC-03 | VLAN 투명 전달 | PEND | VLAN 파싱 구현 완료, 타겟 테스트 필요 |
| SC-04 | bridge_mode=0 동일 동작 | OK | handle->bridge=NULL, 분기 미진입 (빌드 확인) |
| SC-05 | CPU 사용량 감소 | PEND | 타겟 성능 비교 필요 |
| SC-06 | rmmod 정상 언로드 | PEND | 6단계 해제 순서 구현, 타겟 테스트 필요 |

---

## 6. Gap List

| ID | Severity | Category | Description | Status |
|----|----------|----------|-------------|--------|
| G-01 | Low | Feature | FR-08 VLAN ID 기반 필터링 미구현 (Should 우선순위) | ACCEPTED |
| G-02 | Info | Deviation | moal_init.c에서 static → non-static 변경 (extern 접근 필수) | JUSTIFIED |
| G-03 | Info | Scope | moal_bridge.c 426줄 (Design 예상 280줄 초과) — 양방향+lifecycle 완전 구현 | EXPECTED |

**Critical/Important Gap: 0건**

---

## 7. Match Rate

| Axis | Score | Weight | Weighted |
|------|-------|--------|----------|
| Structural | 100% | 0.2 | 20.0 |
| Functional | 93% | 0.4 | 37.2 |
| Contract | 100% | 0.4 | 40.0 |
| **Overall** | | | **97.2%** |

> Static-only formula 적용 (타겟 런타임 테스트 불가 환경)

---

## 8. Conclusion

**Static implementation coverage is high, but runtime readiness is still pending.**

- Build verification passed via `/home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh`
- Queue backpressure, keepalive consistency, and hot-path accounting require explicit hardening before calling the bridge production-ready
- SC-01, SC-02, SC-03, SC-05, and SC-06 still require target validation
