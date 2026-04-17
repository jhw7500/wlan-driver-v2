# driver-bridge Completion Report

> **Feature**: driver-bridge (커널 드라이버 레벨 유무선 L2 브릿지)
> **Project**: wlan-driver-v2 (NXP 88Q9098 WLAN Driver)
> **Target**: iMX93 (SDIO)
> **Date**: 2026-04-09
> **PDCA Duration**: 2026-04-08 ~ 2026-04-09 (2일)
> **Match Rate**: 97.2%

---

## Executive Summary

### 1.1 Project Overview

| Item | Value |
|------|-------|
| Feature | pcap 기반 유저스페이스 브릿지를 커널 드라이버 레벨로 이식 |
| Start Date | 2026-04-08 |
| End Date | 2026-04-09 |
| Duration | 2일 |
| PDCA Iterations | 0 (첫 Check에서 97.2% 달성) |

### 1.2 Results Summary

| Metric | Value |
|--------|-------|
| Match Rate | 97.2% |
| FR 충족 | 9/10 (Must 전체, Should 1건 미구현) |
| Gap (Critical) | 0건 |
| 신규 파일 | 2개 (moal_bridge.c 426줄, moal_bridge.h 57줄) |
| 수정 파일 | 5개 (moal_main.h, moal_init.c, moal_main.c, moal_shim.c, Makefile) |
| 총 추가 코드 | ~519줄 |
| 빌드 | PASS (make_for_imx93.sh, 에러/경고 0) |

### 1.3 Value Delivered

| Perspective | Content |
|-------------|---------|
| **Problem** | 유저스페이스 pcap 브릿지의 패킷당 컨텍스트 스위칭 2회 + 시스템 콜 오버헤드 |
| **Solution** | MOAL 레이어에 moal_bridge.c/h 분리 구현, netdev_rx_handler 기반 양방향 L2 포워딩 |
| **Function/UX Effect** | `insmod moal.ko bridge_mode=1 bridge_peer=eth0` 한 줄로 브릿지 동작. wbridge 프로세스 불필요 |
| **Core Value** | 패킷 포워딩 경로에서 유저스페이스 완전 제거. 커널 내부 skb 직접 포워딩 |

---

## 2. Key Decisions & Outcomes

| # | Decision | Source | Followed | Outcome |
|---|----------|--------|:--------:|---------|
| 1 | Option C (Pragmatic Balance) 아키텍처 | Plan/Design | OK | moal_bridge.c/h 분리로 기존 드라이버 오염 최소화 달성 |
| 2 | ETH→WLAN: netdev_rx_handler_register | Design §4.2 | OK | 커널 표준 API 사용, bridge/macvlan과 동일 메커니즘 |
| 3 | WLAN→ETH: moal_recv_packet 1줄 분기 | Design §4.1 | OK | moal_shim.c에 unlikely() 분기 5줄 삽입 |
| 4 | 멀티캐스트: skb_clone 양쪽 전달 | Design §7.3 | OK | peer 포워딩 + 커널 스택 동시 전달 구현 |
| 5 | 모듈 파라미터 제어 | Plan FR-01,02 | OK | bridge_mode, bridge_peer (static→non-static 수정) |
| 6 | 6단계 해제 순서 | Design §7.4 | OK | active=0→notifier→rx_handler→sync_net→dev_put→kfree |

---

## 3. Success Criteria Final Status

| SC | Criteria | Status | Evidence |
|----|----------|:------:|----------|
| SC-01 | 양방향 L2 포워딩 | PEND | moal_bridge_rx() + peer_rx_handler() 구현 완료. 타겟 실기 테스트 필요 |
| SC-02 | 자기 IP ssh 접속 | PEND | should_forward(): MAC/IP/ARP 필터 구현 완료. 타겟 실기 테스트 필요 |
| SC-03 | VLAN 투명 전달 | PEND | should_forward(): ETH_P_8021Q 파싱 구현 완료. 타겟 실기 테스트 필요 |
| SC-04 | bridge_mode=0 동일 동작 | OK | handle->bridge=NULL, 분기 미진입. 빌드 성공 확인 |
| SC-05 | CPU 사용량 감소 | PEND | 유저스페이스 제거 → 이론적 개선. iperf3 비교 필요 |
| SC-06 | rmmod 정상 언로드 | PEND | 6단계 해제 순서 구현. 반복 insmod/rmmod 테스트 필요 |

**Overall: code integrated, but runtime validation and hardening still required before production use**

- Static integration is present
- Runtime verification is still pending on target hardware
- Hardening items remain for queue bounds, keepalive behavior, xmit accounting, and init-failure cleanup

---

## 4. Implementation Summary

### 4.1 파일별 변경

| 파일 | 유형 | 줄수 | 역할 |
|------|------|------|------|
| `mlinux/moal_bridge.h` | 신규 | 57 | 데이터 구조 (moal_bridge, moal_bridge_stats) + API 선언 |
| `mlinux/moal_bridge.c` | 신규 | 426 | 필터/포워딩/rx_handler/notifier/init/deinit 전체 |
| `mlinux/moal_main.h` | 수정 | +2 | struct _moal_handle에 bridge 포인터 |
| `mlinux/moal_init.c` | 수정 | +6 | bridge_mode, bridge_peer 변수 + module_param |
| `mlinux/moal_main.c` | 수정 | +15 | include + bridge_init/deinit 호출 |
| `mlinux/moal_shim.c` | 수정 | +7 | include + bridge forward 분기 |
| `Makefile` | 수정 | +1 | moal_bridge.o 빌드 |
| **합계** | | **~519** | |

### 4.2 구현된 함수 (9개)

| 함수 | 줄 | 역할 |
|------|-----|------|
| `moal_bridge_get_ipv4()` | 19 | netdev에서 IPv4 주소 추출 |
| `moal_bridge_arp_is_for_self()` | 43 | ARP target IP가 자기 IP인지 판별 |
| `moal_bridge_ip_is_local()` | 71 | IPv4 dest가 자기 IP인지 판별 |
| `moal_bridge_should_forward()` | 99 | 패킷 필터 종합 판정 (MAC/IP/ARP/VLAN) |
| `moal_bridge_rx()` | 152 | WLAN→ETH 포워딩 (멀티캐스트 clone 포함) |
| `moal_bridge_peer_rx_handler()` | 211 | ETH→WLAN rx_handler 콜백 |
| `moal_bridge_netdev_event()` | 267 | peer down/up/unregister notifier |
| `moal_bridge_init()` | 310 | 초기화: peer 참조, rx_handler/notifier 등록 |
| `moal_bridge_deinit()` | 388 | 해제: 6단계 순서대로 자원 정리 |

### 4.3 아키텍처

```
┌─────────────────────────────────────────────────┐
│ Kernel                                          │
│                                                 │
│  eth0 ◄──rx_handler──► moal_bridge.c ◄──► wlan0 │
│   │                        │                │   │
│   ▼ (self only)            │                ▼   │
│          Kernel Network Stack                   │
└─────────────────────────────────────────────────┘

WLAN→ETH: moal_recv_packet() → moal_bridge_rx() → dev_queue_xmit(eth0)
ETH→WLAN: eth0 rx_handler → peer_rx_handler() → dev_queue_xmit(wlan0)
```

---

## 5. Gap Analysis Summary

| Axis | Score |
|------|-------|
| Structural | 100% |
| Functional | 93% |
| Contract | 100% |
| **Overall** | **97.2%** |

| Gap | Severity | Status |
|-----|----------|--------|
| FR-08 VLAN ID 필터링 미구현 | Low (Should) | ACCEPTED |
| static→non-static 변경 | Info | JUSTIFIED (빌드 에러 수정) |

---

## 6. Build Verification

```
Build: make_for_imx93.sh
Target: iMX93 (SDIO, Linux 6.6.3, NXP BSP)
Result: PASS (에러 0, 경고 0)
Output:
  - mlan.ko  (899,456 bytes)
  - moal.ko  (1,654,952 bytes)
```

---

## 7. Deployment Guide

### 7.1 타겟 전송

```bash
scp moal.ko mlan.ko root@<target>:/lib/modules/
```

### 7.2 테스트 절차

```bash
# 1. 기존 동작 확인 (SC-04)
insmod mlan.ko
insmod moal.ko
# Wi-Fi 연결 확인 후 rmmod

# 2. 브릿지 모드 (SC-01)
insmod mlan.ko
insmod moal.ko bridge_mode=1 bridge_peer=eth0
# dmesg에서 "bridge: ... activated" 확인

# 3. 양방향 ping 테스트 (SC-01)
# 유선 호스트에서: ping <무선 클라이언트 IP>
# 무선 클라이언트에서: ping <유선 호스트 IP>

# 4. 자기 IP 접근 (SC-02)
ssh root@<브릿지 IP>

# 5. 성능 비교 (SC-05)
iperf3 -s  # 한쪽에서
iperf3 -c <peer> -t 60  # 다른쪽에서
mpstat 1 60  # CPU 모니터링

# 6. rmmod 테스트 (SC-06)
rmmod moal && rmmod mlan  # 정상 언로드 확인
```

---

## 8. Local Validation Status

### 8.1 Verified in this workspace

- Static bridge checks: PASS
  - Command: `bash /home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
- Cross-build: PASS
  - Command: `bash /home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh`
- Package copy helper: PASS when executed from `scripts/`
  - Command: `bash update_package.sh`
  - Note: running `scripts/update_package.sh` from repo root fails because the script uses relative paths assuming `scripts/` as cwd.

### 8.2 Not verifiable in this workspace

- Target module load: `insmod mlan.ko`, `insmod moal.ko bridge_mode=1 bridge_peer=eth0 bridge_keepalive_ms=0`
- Bidirectional ping validation (SC-01)
- SSH to bridge IP (SC-02)
- iperf3/mpstat runtime validation (SC-05)
- `rmmod moal && rmmod mlan` unload validation on target (SC-06)

### 8.3 Current blocker

The current environment has source, build toolchain, and package output paths, but no live target board session. Runtime bridge validation still requires real hardware with the built modules loaded.

---

## 9. Lessons Learned

| # | Lesson | Category |
|---|--------|----------|
| 1 | 커널 모듈의 static 변수는 다른 .c 파일에서 extern 접근 불가 — 빌드 시 modpost 에러 발생 | Build |
| 2 | 3-module 세션 분할(기반→필터→양방향)이 효과적 — 각 세션에서 독립 검증 가능 | Process |
| 3 | 커널 드라이버 코드는 로컬 clang 진단이 오탐 — 크로스 빌드로만 검증 가능 | Tooling |
| 4 | wbridge filter.c의 검증된 로직을 커널 API로 이식하면 안정성 확보 용이 | Reuse |

---

## Runtime Validation (v2 hardening — 2026-04-17)

- Build: `/home/jhw/ai/opencode/projects/wlan-driver-v2/make_for_imx93.sh` (exit 0)
- Deploy: `ssh root@192.168.0.101 'bash /home/root/rsync_driver.sh'`
- Apply: `systemctl restart wifi_init` (re-runs `/usr/local/scripts/wifi_init.sh` which performs rmmod → insmod)

### Evidence captured from target `cantops` (iMX93, 192.168.0.101)

| Check | Source | Result |
| --- | --- | --- |
| Bridge activates on boot with always-fire keepalive | dmesg `[9.42]` — `bridge: keepalive = 1ms` + `=== Activated ===` | PASS |
| B1 — peer `NETDEV_UNREGISTER` handles release inline | dmesg `[94.49]` — `peer 'eth0' unregistered, disabling` followed immediately by `mlan0 <-> eth0 deactivated` (no UAF, no crash, no deferred unregister) | PASS |
| B4 — peer `NETDEV_DOWN` suspends forwarding without stale drops | Forwarded 147 (w2p) / 170 (p2w) packets across a full stop cycle, `drop=0 err=0` on both directions | PASS |
| B5 — `oom_drops` visible in deinit stats dump | dmesg `bridge: w2p fwd=147 drop=0 err=0 oom=0` / `bridge: p2w fwd=170 drop=0 err=0 oom=0` | PASS (field present, value 0 expected under no memory pressure) |
| Host → target WLAN ping smoke test | 100 pkts, 0% loss, min/avg/max/mdev = 2.4 / 15 / 111 / 25 ms (WiFi channel jitter, no regression) | PASS (no drops) |
| Bridge re-activates cleanly after each `wifi_init` restart | Three full re-init cycles observed in dmesg, each with complete `=== Activated ===` banner and matching `peer_ipv4` / `wlan_ipv4` updates via inetaddr notifier | PASS |

### Items covered by static check only (runtime reproduction skipped)

- **B2** (atomic qlen race hard cap) — bug only observable under concurrent enqueue overload; static check enforces the `atomic_inc_return`/`atomic_dec` pair and forbids `skb_queue_len_lockless` in `moal_bridge.c`.
- **B3** (`pskb_may_pull` guards) — non-linear skb on the RX fast path is rare in the steady state; static check enforces both guard sites.
- **B6** (DBDC double-init `-EBUSY`) — reproduction requires driving a second `bridge_mode=1` init on a different handle, which the current target toolchain doesn't expose as a simple command. Static check enforces the `-EBUSY` return and `MERROR` log level.
- **B7** (packet_type fallback `skb_share_check`) — `rx_handler` registered without preemption, so the fallback path is inactive on this target. Static check enforces `skb_share_check(skb, GFP_ATOMIC)` + `oom_drops` accounting inside `moal_bridge_peer_pt_func`.
- **A1** / **A2** — gated / returned path; no distinctive dmesg marker, but both `bridge_static_checks.sh` PASS and driver functions correctly under the captured load.

### Notes

- Performance baseline comparison (v1's 7 ms upstream target) not re-measured: the host-to-target direct ping traverses the "self-IP skip clone" path in `moal_bridge_rx_fast`, not the bridge forwarding path, so latency variance here reflects the WiFi channel rather than the bridge optimizations themselves. A proper bridge-through regression test would need a wireless peer pinging a host on the wired side; the captured `w2p fwd=147` / `p2w fwd=170` with `drop=0 err=0` is the strongest signal available in this session.
