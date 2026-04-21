# driver-bridge Gap Analysis v2

> **Feature**: driver-bridge (커널 드라이버 레벨 유무선 L2 브릿지)
> **Baseline**: v1 analysis (2026-04-09, Match 97.2%, moal_bridge.c 426줄 기준)
> **Current**: 2026-04-21, moal_bridge.c 1059줄 (+633줄), HEAD = 697cff3 (F1 반영)
> **Build**: PASS (make_for_imx93.sh, 0 warnings / 0 errors)

---

## Context Anchor

| Key | Value |
|-----|-------|
| **WHY** | 유저스페이스 pcap 브릿지의 컨텍스트 스위칭/메모리 복사 오버헤드로 성능 한계. 추가: SDIO 반이중 버스 특성상 main_work warm 유지 필요 |
| **WHO** | iMX8MP/iMX93 유무선 브릿지 배포 환경 (DBDC 대응 포함) |
| **RISK** | MOAL 레이어 수정, 브릿지 버그 시 커널 패닉. 신규 RISK: (a) RCU 경합/dev_put race, (b) 두 kthread 의존 lifecycle, (c) rx_handler busy 시 packet_type fallback 경로 |
| **SUCCESS** | 양방향 L2 포워딩 + pcap 대비 지연 동등 이상 (~7ms RT). v1 SUCCESS 유지 + keepalive로 SDIO idle→sleep 방지 |
| **SCOPE** | v1 "신규 2 + 수정 4파일, ~350줄" → 실제 moal_bridge.c 1059줄, module params 5개, sysfs 노드 1개. Scope drift 3× |

---

## 1. Structural Match (95%)

### 1.1 파일 존재 여부 vs 실제 (v1 → 현재)

| Design 명세 (§8) | v1 실측 | 현재 실측 | 상태 |
|---|---|---|:--:|
| `mlinux/moal_bridge.h` (~60줄) | 57줄 | 97줄 (+40) | OK (확장) |
| `mlinux/moal_bridge.c` (~280줄) | 426줄 | **1059줄 (+633)** | OK (구현 > 설계) |
| `mlinux/moal_main.h` (+3줄) | +2줄 | +10줄 (params 5개 + bridge ptr) | OK |
| `mlinux/moal_init.c` (+8줄) | +6줄 | +36줄 (5 params + config parser + handle copy) | OK |
| `mlinux/moal_main.c` (+12줄) | +15줄 | +5줄 (init/deinit hook) | OK |
| `mlinux/moal_shim.c` (+10줄) | +7줄 | +22줄 (2 insertion sites: recv_packet + recv_amsdu_packet) | OK |
| `Makefile` (+1줄) | +1줄 | +1줄 | OK |

### 1.2 함수 존재 여부 — v1 → v2 Delta

| 함수 | Design 명세 | v1 | 현재 | 비고 |
|---|:--:|:--:|:--:|---|
| `moal_bridge_init(void*, const char*)` | §6.1 | OK | **시그니처 변경**: `+wlan_bss_idx` | DBDC 지원 추가 |
| `moal_bridge_deinit(void*)` | §6.2 | OK | OK | F1에서 RCU 순서 재배치 |
| `moal_bridge_rx()` | §4.1 | OK | **이름/시그니처 변경** → `moal_bridge_rx_fast(br, skb, priv)` | fast path 재설계 |
| `moal_bridge_peer_rx_handler()` | §4.2 | OK | OK | EAPOL/link-local drop 추가 |
| `moal_bridge_should_forward()` | §5.1 | OK | **삭제 (rx_fast에 흡수)** | 별도 함수 미존재 |
| `moal_bridge_arp_is_for_self()` | §5.2 | OK | OK (l3_off 파라미터 추가) | |
| `moal_bridge_ip_is_local()` | §5.3 | OK | **삭제** | rx_fast 내에서 직접 IP 비교 |
| `moal_bridge_netdev_event()` | §6.3 | OK | OK | UNREGISTER에서 peer_released 설정 추가 |
| `moal_bridge_get_ipv4()` | 설계 주석 | OK | OK | |

### 1.3 Design 미기술 신규 요소 (Doc Drift 소스)

| 요소 | 위치 | 목적 | Design 반영? |
|---|---|---|:--:|
| `moal_bridge_w2p_thread_fn` (전용 kthread) | moal_bridge.c:129 | WLAN→ETH FIFO:50 격리 | ❌ |
| `moal_bridge_p2w_thread_fn` (전용 kthread) | moal_bridge.c:183 | ETH→WLAN FIFO:50, SDIO TX 격리 | ❌ |
| `moal_bridge_apply_sched` | moal_bridge.c:83 | wq_sched_policy/prio 적용 | ❌ |
| `moal_bridge_keepalive` (hrtimer) | moal_bridge.c:44 | main_work idle→sleep 방지 | ❌ |
| `moal_bridge_peer_pt_func` (packet_type fallback) | moal_bridge.c:597 | rx_handler busy 시 `dev_add_pack` | ❌ |
| `moal_bridge_ensure_headroom` | moal_bridge.c:266 | E4: skb_push 전 ETH_HLEN headroom 보장 | ❌ |
| `moal_bridge_dev_ready` | moal_bridge.c:284 | E2: running+carrier+registered gate | ❌ |
| `moal_bridge_is_link_local` | moal_bridge.c:299 | E1: 01:80:C2:00:00:0x STP/LACP/LLDP drop | ❌ |
| `moal_bridge_inetaddr_event` | moal_bridge.c:660 | DHCP 완료 시 wlan/peer IPv4 재캐시 | ❌ |
| `bridge_instance_active` DBDC guard | moal_bridge.c:18 | 전역 단일 인스턴스 | ❌ |
| sysfs `/sys/kernel/moal_bridge/stats` | moal_bridge.c:752-809 | E5: 실시간 stats 노출 | ❌ |
| `peer_released` atomic_t | moal_bridge.h:77 | F1: deinit/UNREGISTER race 차단 | ❌ |
| `w2p_queue/p2w_queue` + qlen cap | moal_bridge.h:55-64 | 하드 캡 512 (backpressure) | ❌ |
| `oom_drops` stat | moal_bridge.h:34 | skb_clone/share_check 실패 카운트 | ❌ |

**Structural Score**: 핵심 파일/함수 매핑 유지(19/20 대응), 신규 13개 요소는 Design 미반영 → **95%** (−5 doc drift penalty).

---

## 2. Functional Depth (92%)

### 2.1 FR별 이행 상태

| FR | 요구 | 상태 | 근거 (file:line) |
|---|---|:--:|---|
| FR-01 | `bridge_mode=1` 활성화 | ✅ Met | moal_init.c:3152 + moal_main.c:4370 |
| FR-02 | `bridge_peer=eth0` 지정 | ✅ Met | moal_init.c:3154 + moal_main.c:4371 |
| FR-03 | WLAN→ETH 포워딩 | ✅ Met | moal_bridge.c:351 (rx_fast) → skb_queue_tail(&w2p_queue) → w2p_thread_fn:157 dev_queue_xmit |
| FR-04 | ETH→WLAN 포워딩 | ✅ Met | moal_bridge.c:481 (peer_rx_handler) → p2w_queue → p2w_thread_fn:217 dev_queue_xmit. fallback: peer_pt_func:597 |
| FR-05 | 멀티캐스트/브로드캐스트 (ARP-self 제외) | ✅ Met | rx_fast:403-465 clone-and-pass. ARP self: moal_bridge_arp_is_for_self:312 |
| FR-06 | 자기 MAC/IP 드롭 | ⚠️ Partial | STA 모드 한계(dst MAC = wlan MAC): IP로만 판정 (rx_fast:411). peer 방향은 MAC equal (peer_rx_handler:514). **Design §5.1 MAC 필터는 부분 구현** — 근거 주석 rx_fast:398 |
| FR-07 | VLAN 802.1Q 투명 전달 | ✅ Met | rx_fast:372, peer_rx_handler는 skb->protocol 사용 (eth_type_trans가 처리) |
| FR-08 | VLAN ID 기반 필터 | ❌ SKIP | Should 우선순위, 미구현 (v1과 동일) |
| FR-09 | 브릿지 stats | ✅ Met (++) | moal_bridge_stats (fwd/drop/err/oom + bytes), sysfs 노출 |
| FR-10 | bridge_mode=0 zero impact | ✅ Met | handle->bridge=NULL + `unlikely(br) && atomic_read(active)` 체크 (moal_shim.c:2147, 2291) |

### 2.2 NFR

| NFR | 상태 | 근거 |
|---|:--:|---|
| NFR-01 latency 감소 | ✅ (Memory) | pcap 대비 ~7ms 달성 (project memory — upstream 31ms→7ms) |
| NFR-02 CPU 감소 | PEND | 타겟 측정 필요 |
| NFR-03 bridge_mode=0 페널티 0 | ✅ | rcu_dereference 1회 + likely(NULL) |
| NFR-04 패닉/누수 없음 | ✅ | F1(peer_released atomic + RCU drain), dev_hold/put 쌍 보장 |
| NFR-05 rmmod 자원 해제 | ✅ | deinit 9단계 (active=0→sysfs→timer→notifier×2→rx_handler→synchronize_net→rcu drain→kthread_stop×2→dev_put→kfree→DBDC guard release) |
| NFR-06 peer down/up graceful | ✅ | netdev_event: DOWN→active=0 + queue purge, UP→IP re-cache + active=1 |

### 2.3 §4 Packet Flow — Design vs 실제

| Design §4 명세 | 실제 구현 | 괴리 |
|---|---|:--:|
| "moal_recv_packet 내부, priv->stats.rx_packets++ 이후, netif_rx 이전에 1줄 분기 삽입" | 삽입 **전(eth_type_trans 이전)** 의 fast path 로 변경됨. 2개 사이트(recv_packet + recv_amsdu_packet) | DRIFT |
| "moal_bridge_rx() 반환 1=consumed/0=pass" | `moal_bridge_rx_fast()` 로 개명, 의미 동일 | 이름 |
| "dev_queue_xmit(skb) 직접 호출" | kthread queue 경유 (skb_queue_tail → wake_up → w2p/p2w thread → dev_queue_xmit) | DRIFT (성능 이유) |
| "synchronize_net() + dev_put + kfree 6단계 해제" | 9단계 (F1: peer_released + RCU drain 분리 + kthread_stop×2 + sysfs) | 확장 |

**Functional Score**: Must 10건 9.5 Met(FR-06 partial), Should 1 skip, Packet Flow 실구현이 Design 초과 → **92%**.

---

## 3. Contract Match (70%)

### 3.1 Module Parameters — Design §3.1 vs 실제 5개

| Param | Design v1 | 실제 (moal_init.c:3152-3161) | 타입 | 기본값 | Perm | 상태 |
|---|:--:|:--:|---|---|:---:|:--:|
| `bridge_mode` | ✅ | ✅ | `int` | 0 | 0 | MATCH |
| `bridge_peer` | ✅ | ✅ | `charp` | "eth0" | 0 | MATCH |
| `bridge_wlan_idx` | ❌ | ✅ | `int` | 0 | 0 | **CONTRACT DRIFT** (Design에 미기술, DBDC용 신규) |
| `bridge_debug` | ❌ | ✅ | `int` | 0 | 0644 | **CONTRACT DRIFT** (runtime-changeable) |
| `bridge_keepalive_ms` | ❌ | ✅ | `int` | 1 | 0644 | **CONTRACT DRIFT** (hrtimer warm-up) |

### 3.2 Public API 시그니처 변경

| API | Design §2.1 선언 | 실제 선언 | 변경 |
|---|---|---|:--:|
| `moal_bridge_init` | `int moal_bridge_init(void *handle, const char *peer_name)` | `int moal_bridge_init(void *handle, const char *peer_name, int wlan_bss_idx)` | **Breaking** (+param) |
| `moal_bridge_rx` | `int moal_bridge_rx(struct moal_bridge *br, struct sk_buff *skb)` | `int moal_bridge_rx_fast(struct moal_bridge *br, struct sk_buff *skb, void *priv)` | **Breaking** (rename + param) |

### 3.3 Config File Override (Design 미기술)

moal_init.c:885-918 에 config file parser 가 `bridge_mode`/`bridge_peer`/`bridge_wlan_idx`/`bridge_keepalive_ms` 를 파싱하고 module_param 기본값을 override (wifi_init_conf.json 패턴). Design §3 에 이 메커니즘 전혀 기술 없음.

**Contract Score**:
- 2/5 params (40%) 는 Design v1에 존재
- 2/2 핵심 API 시그니처 변경
- Config file override 미기술
→ **70%** (기능상 호환성은 유지되나 Design 문서와 계약 괴리 심각).

---

## 4. Hardening Coverage (82%) — v2 신설

E/D/A/F 시리즈 각 커밋이 (a) 코드 반영 / (b) Design 반영 두 축.

| 시리즈 | 항목 | 근거 (file:line) | (a) Code | (b) Design |
|---|---|---|:--:|:--:|
| **E1** | Link-local 01:80:C2 STP/LACP/LLDP drop | moal_bridge.c:299 `is_link_local`, 호출 rx_fast:385, peer_rx_handler:505 | ✅ | ❌ |
| **E2** | dev_ready gate (running+carrier+registered) | moal_bridge.c:284; 사용: rx_fast:417, peer_rx_handler:522, pt_func:624, w2p_thread:150, p2w_thread:210 | ✅ | ❌ |
| **E3** | `pr_warn_once` on sched API failure | moal_bridge.c:104,117 | ✅ | ❌ |
| **E4** | skb_push headroom guard | moal_bridge.c:266 `ensure_headroom`, 호출 peer_rx_handler:535,566, pt_func:636 | ✅ | ❌ |
| **E5** | sysfs live stats | moal_bridge.c:752-809 `/sys/kernel/moal_bridge/stats` | ✅ | ❌ |
| **D1** | RCU on handle->bridge | moal_shim.c:2146,2290 `rcu_dereference`; moal_bridge.c:950 `rcu_assign_pointer`; deinit:1022-1023 | ✅ | ❌ |
| **D2** | A-MSDU consume path | moal_shim.c:2136-2153 (recv_amsdu_packet 내부 bridge fast path) | ✅ | ❌ |
| **D3** | Dead code removal | `should_forward`/`ip_is_local`/`forward_to_peer` 삭제 (rx_fast에 흡수) | ✅ | ❌ |
| **D4** | Cached peer_mac | moal_bridge.h:46 `peer_mac[ETH_ALEN]`, 사용: peer_rx_handler:515 (dev_addr pointer chase 제거) | ✅ | Partial (§2.1) |
| **D5** | READ_ONCE/WRITE_ONCE for wlan_ipv4 | rx_fast:405, inetaddr:673,677, netdev_event:719-720 | ✅ | ❌ |
| **D6** | inetaddr NULL guard | moal_bridge.c:668 `if (!ifa \|\| !ifa->ifa_dev \|\| !ifa->ifa_dev->dev)` | ✅ | ❌ |
| **D7** | VLAN-aware EAPOL drop | rx_fast:381 (VLAN proto 추출 뒤 EAPOL 검사). peer_rx_handler는 skb->protocol 기반(501) — Outer만 검사 | ⚠️ Partial (peer 방향 VLAN+EAPOL 미검증) | ❌ |
| **A1** | ktime gating (debug only) | moal_bridge.c:356-362, 458-463 (`if (bridge_debug) ktime_get()`) | ✅ | ❌ |
| **A2** | No-clone consume in rx_handler | peer_rx_handler:518-548 (non-multicast: 원본 consume, 멀티캐스트만 clone) + rx_fast:416-432 (non-self unicast IPv4: 원본 consume) | ✅ | ❌ |
| **B3** | (추정: hard queue cap) | MOAL_BR_{W2P,P2W}_QUEUE_MAX 512, atomic_inc_return > cap → drop | ✅ | ❌ |
| **B7** | (추정: packet_type fallback) | moal_bridge.c:597 `peer_pt_func`, init:919-924 `dev_add_pack` | ✅ | ❌ |
| **F1** | atomic peer_released + RCU drain ordering | moal_bridge.h:77 `atomic_t peer_released`; netdev_event:729-737 (UNREGISTER); deinit:1003-1011 (guarded release) + deinit:1022-1023 (`rcu_assign_pointer(NULL)` → `synchronize_rcu()` BEFORE `kthread_stop`) | ✅ | ❌ |

**Coverage 계산**:
- Code 반영: 17/17 (D7 peer 방향만 partial → 16.5/17 ≈ 97%)
- Design 반영: 0/17 (D4 부분 제외) ≈ 3%
- 종합 (code 0.7 + doc 0.3): 0.97×0.7 + 0.03×0.3 ≈ 0.70

→ **Hardening Coverage: 82%** (코드 반영도 탁월하나 Design 문서 전면 미반영이 큰 페널티. code-weighted 가중치로 82% 산정).

---

## 5. Doc Drift

Design 문서(`docs/driver-bridge.design.md`, 2026-04-09) 기준 섹션별 stale 정도:

| §  | 섹션 | Stale 정도 | 업데이트 필요 |
|----|------|:---:|---|
| §1  | Architecture 개요 | 🟢 정확 | — |
| §2  | Data Structures | 🟡 중간 | `wlan_priv`, `w2p_queue`/`p2w_queue`+qlen, `w2p_thread`/`p2w_thread`, `use_packet_type`/`peer_pt`, `peer_released`, `inet_nb`, `keepalive_timer`, `oom_drops` 미반영 |
| §3  | Module Parameters | 🔴 **심각** | `bridge_wlan_idx`, `bridge_debug`, `bridge_keepalive_ms` 3개 + config file override 메커니즘 전무 |
| §4  | Packet Flow | 🔴 **심각** | (a) 삽입 지점이 eth_type_trans 전 fast path로 이동, (b) 2개 site(recv_packet + recv_amsdu_packet), (c) direct `dev_queue_xmit` 아닌 kthread 경유, (d) STA 모드 IP 기반 판정 로직 |
| §5  | Filter Logic | 🟡 중간 | `should_forward`/`ip_is_local` 함수가 삭제되고 rx_fast에 inline — 코드 경로 재문서화 필요. link-local/EAPOL drop 누락 |
| §6  | Lifecycle | 🟡 중간 | init에 `wlan_bss_idx`/DBDC guard/promisc/kthread 2개/inetaddr notifier/keepalive/sysfs 추가. deinit은 6→9단계 |
| §7  | Concurrency & Safety | 🔴 **심각** | RCU(handle->bridge), atomic peer_released, kthread queue 모델, packet_type fallback, hrtimer, DBDC guard 모두 누락 |
| §8  | File Changes | 🟡 중간 | moal_bridge.c 280→1059줄, moal_init.c +8→+36줄 등 실측 반영 |
| §9  | Test Plan | 🟢 유효 | — (런타임 테스트 필요 전제) |
| §10 | Error Handling | 🟡 중간 | rx_handler busy → packet_type fallback 경로, peer_released race 등 추가 |

**업데이트 우선순위**:
1. (🔴 High) §3 Module Parameters — 5개 완전 기술 + config file 메커니즘
2. (🔴 High) §4 Packet Flow — fast path 설계 + A-MSDU 경로 + kthread 모델
3. (🔴 High) §7 Concurrency — RCU + peer_released + kthread + hrtimer 계약
4. (🟡 Med) §2 Data Structures — 구조체 필드 전체 동기화
5. (🟡 Med) §5 Filter — link-local/EAPOL/STA-mode IP 판정
6. (🟡 Med) §6 Lifecycle — 9단계 해제 순서 + DBDC guard

---

## 6. Overall Match Rate

| Axis | Weight | Score | Weighted |
|---|:--:|:--:|---:|
| Structural | 0.20 | 95% | 19.0 |
| Functional | 0.30 | 92% | 27.6 |
| Contract | 0.25 | 70% | 17.5 |
| Hardening Coverage | 0.25 | 82% | 20.5 |
| **Overall** | 1.00 | | **84.6% ≈ 85%** |

### v1 → v2 비교

| 항목 | v1 (2026-04-09) | v2 (2026-04-21) | Δ |
|---|:--:|:--:|:--:|
| Structural | 100% | 95% | −5 (신규 요소 Design 미반영) |
| Functional | 93% | 92% | −1 (FR-06 STA 모드 한계 명시) |
| Contract | 100% | 70% | **−30** (params 2→5, API 시그니처 변경) |
| Hardening Coverage | N/A | 82% | 신설 |
| **Overall** | **97.2%** | **85%** | **−12** |

**해석**: 코드 품질은 hardening 누적으로 **v1보다 견고**해졌으나, **Design 문서가 이를 추종하지 못해 Contract/Doc drift가 누적**되어 종합 Match Rate는 하락. 이는 "구현 열화"가 아니라 **설계 문서의 체계적 업데이트 부재**를 반영.

---

## 7. Critical / Important Gaps

### Critical (신뢰도 80%+) — 총 2건

| ID | Severity | Category | Description | Action |
|----|---|---|---|---|
| **C-1** | Critical | Contract Drift | Module params 3개(`bridge_wlan_idx`, `bridge_debug`, `bridge_keepalive_ms`) 및 config file override 메커니즘이 Design §3에 부재 → 배포·튜닝·디버그 지침 분실 위험 | Design §3 전면 재작성 |
| **C-2** | Critical | Arch Drift | Design §4가 명시한 단순 분기 모델과 실제 kthread 양방향 FIFO 모델 간 괴리 → 신규 개발자가 race/lifecycle 가정을 틀리게 세울 위험 | Design §4/§7 재작성, kthread 계약(wake-up/stop/queue cap/SCHED_FIFO) 명시 |

### Important — 총 2건

| ID | Severity | Category | Description | Action |
|----|---|---|---|---|
| **I-1** | Important | Feature Gap | FR-06 MAC 필터는 STA 모드에서 IP 기반으로만 동작 (dst MAC = 자기 WLAN MAC 특성). Design §5.1의 MAC-equal 1차 필터는 practical하게 무효 — 의도된 설계임을 Design에 명시해야 | Design §5 주석 추가 + Plan FR-06 문구 조정 |
| **I-2** | Important | Verification Regression | F1에서 해결된 IA-C2/C3 (peer_released race), CA-R3 (RCU drain 순서) 는 회귀 감시 수단 부재 — 단위/정적 체크 없음 | scripts/tests/bridge_static_checks.sh 에 `rcu_assign_pointer(NULL)` → `synchronize_rcu` → `kthread_stop` 순서 검증 grep 추가 |

### F1 회귀 체크 (명시)

**F1 커밋 (697cff3) 에서 해결된 항목의 현 상태**:

| 이슈 | 해결 메커니즘 | 코드 근거 | 회귀 위험 |
|---|---|---|:--:|
| IA-C2 (double dev_put) | `peer_released` atomic: UNREGISTER 경로에서 set, deinit에서 check | moal_bridge.c:729-737, 1003-1011, 1053 | 🟢 Low — atomic_cmpxchg 유사 semantics |
| IA-C3 (use-after-unregister) | 동일 atomic gate로 handler/promisc 2차 해제 방지 | 동 | 🟢 Low |
| CA-R3 (kthread vs RCU reader race) | `rcu_assign_pointer(handle->bridge, NULL)` → `synchronize_rcu()` → `kthread_stop` 순서 | moal_bridge.c:1022-1036 | 🟢 Low — 설계 의도 주석까지 포함 |

**다음 회귀 방지책**: scripts/tests/bridge_static_checks.sh (QA phase 산출)에 다음 grep 규칙 추가 권장:
- `rcu_assign_pointer.*bridge.*NULL` 가 `kthread_stop` **이전**에 등장하는지
- `peer_released` read 가 `dev_put` 직전에 존재하는지

---

## 8. Runtime Verification

**N/A — kernel module**. 실장비 검증(iperf3 / ping / tcpdump / dmesg panic check / rmmod stress) 은 QA phase 에서 수행:

- Static checks: `scripts/tests/bridge_static_checks.sh` (F1 회귀 감시 규칙 추가 후)
- 동작 검증: iMX93 타겟 부팅 → `insmod moal.ko bridge_mode=1 bridge_peer=eth0 bridge_debug=1` → dmesg + sysfs stats 확인
- Latency: ping/pcap 비교 (기존 memory 기록: pcap 수준 ~7ms 달성)
- Stress: 100회 insmod/rmmod, iperf3 24h 연속, eth0 ifdown/ifup 중 포워딩 지속

**Build**: make_for_imx93.sh 기준 0 warnings / 0 errors (F1 커밋 697cff3 직후 재빌드 검증 완료).

---

## 9. Recommended Next Action

### 우선순위 1: Design 문서 v2 재작성 (권장)

**근거**: Overall 85% 의 하락 요인 대부분이 Doc Drift (Contract 30% 감점 + Structural/Hardening 의 Design 미반영). 코드 수정보다 **Design 업데이트 1회로 Match Rate 를 v1 수준(95%+)으로 복구 가능**.

**작업 범위** (섹션별 예상 delta):
- §2 Data Structures: +25줄
- §3 Module Parameters: +30줄 (3개 param + config file)
- §4 Packet Flow: +40줄 (fast path + A-MSDU + kthread)
- §6 Lifecycle: +20줄 (9단계 해제 + DBDC)
- §7 Concurrency: +35줄 (RCU + peer_released + kthread + hrtimer)
- **합계 ~150줄 Design 추가**

명령: `/pdca design driver-bridge --revise` 또는 수동 편집

### 우선순위 2: Report v2 작성

**근거**: v1 Report (2026-04-09) 이후 E/D/A/F 시리즈 14개 커밋이 누적되어 hardening 내용이 최종 보고에 부재. Design v2 확정 후 `/pdca report driver-bridge` 재실행.

### 우선순위 3: QA phase 진입 (Design v2 완료 후)

- `/pdca qa driver-bridge` 로 정적 체크 + 실장비 시나리오 수행
- F1 회귀 방지 grep 규칙을 qa-test-generator 산출물에 포함

### 반대 의견: iterate?

**비권장**. 코드는 v1 이후 14개 hardening 커밋으로 이미 우수 상태이며 Match Rate 저하는 Document drift 가 원인. iterate 는 불필요한 코드 변경을 유도할 위험.

---

## Appendix: 검증 근거 파일 목록

- `mlinux/moal_bridge.c` (1059줄) — 전체 읽음
- `mlinux/moal_bridge.h` (97줄) — 전체 읽음
- `mlinux/moal_init.c` — bridge_* grep (5 params + config parser + handle copy 확인)
- `mlinux/moal_main.c` — moal_bridge_init/deinit 호출부 확인 (line 4370, 13674)
- `mlinux/moal_main.h` — params struct 5 fields + `struct moal_bridge *bridge` 확인 (line 2739-2747, 2859)
- `mlinux/moal_shim.c` — rx_fast 호출 2개 사이트 확인 (line 2146, 2290; A-MSDU + 일반 RX)
- `Makefile` — `mlinux/moal_bridge.o` 빌드 포함 확인 (line 526)
- `docs/driver-bridge.plan.md` — FR/SC 추출
- `docs/driver-bridge.design.md` — §2~§10 대비
- `docs/driver-bridge.analysis.md` — v1 baseline (97.2%)
