# wbridge 모드 (latency / normal / eco / thermal) 드라이버 영향 분석

`wifi_bridge.sh` → `setup-irq-affinity.sh` → `optimize-for-udp.sh` 경로로 적용되는 모든 모드별 튜닝이 mlan/moal 드라이버에서 실제로 어떻게 동작하는지, 어디서 dead code 경로가 되는지 코드 레벨로 정리.

대상 보드: iMX8MM (PCIe wifi), iMX93 (SDIO wifi), NXP 88W9098.

## 0. 핵심 결론

1. **mlan0은 `ethtool_ops`도 `ndo_set_features`도 등록하지 않음** — `ethtool -G/-C/-K mlan0` 전부 미지원. 모드별 ring/coalesce/GRO 차이는 eth0(FEC)에만 적용.
2. **`engine=moal` (드라이버 kernel L2 브릿지)에서는 `WBRIDGE_*` 환경변수 전부 dead code** — `wifi_bridge.sh:461-469`가 wbridge userspace 바이너리를 실행하지 않고 `sleep 60` 루프로 대기.
3. **`bridge_keepalive_ms = 1` (디폴트) hrtimer**가 1ms마다 `main_work` 강제 wakeup → SDIO/PCIe 처리 루프 warm 유지. 이게 upstream 7ms 도달의 진짜 원인.
4. **`optimize-for-udp.sh`의 `iwconfig power off`가 moal bridge latency의 숨은 전제조건** — `EFFECTIVE_MODE=thermal`로 강등되면 통째 skip되어 PS auto-on 위험.
5. **mlan TX cap = `MAX_TX_PENDING = 800`** — `txqueuelen=10000`을 넘겨봐도 driver-level cap이 진짜 병목.

---

## 1. 인터페이스별 설정 적용 매트릭스

| 설정 | eth0 (FEC) | mlan0 (moal) | 비고 |
|---|---|---|---|
| IRQ smp_affinity | 적용 | 적용 (mmc2 / PCIe MSI 경유) | iMX93은 mmc2 IRQ, iMX8MM은 PCIe MSI |
| RPS rps_cpus | 적용 | 적용 | 단 mlan은 `net_rx>=1`이면 backlog 우회 |
| `ethtool -G` ring | 적용 | **미지원** | `dev->ethtool_ops == NULL` |
| `ethtool -C` coalesce | 적용 | **미지원** | 동상 |
| `ethtool -K gro/gso/tso` | 적용 | **미지원** | `ndo_set_features` 없음 |
| cpufreq governor (eco/thermal) | 전역 | 전역 | SDIO IRQ가 도는 CPU에 직접 영향 |
| cpuidle deep state (thermal) | 전역 | 전역 | keepalive hrtimer가 진입 차단 |
| `txqueuelen 10000` | 적용 | 적용되지만 `MAX_TX_PENDING=800`이 진짜 cap | |
| `wmem_max/rmem_max=16M` | — | — | wbridge userspace socket에서만 의미 |
| `udp_mem`, `udp_rmem_min` | — | — | UDP socket 소비자 보호용 |
| `netdev_max_backlog=10000` | 적용 | **거의 무효** | `net_rx>=1` 경로 우회 |
| `iwconfig power off` | — | **결정적** | moal SIOCSIWPOWER 핸들러 경유 |
| `WBRIDGE_DISPATCH_BUDGET` 등 | — | — | engine=pcap/tpacket일 때만 살아있음 |

---

## 2. setup-irq-affinity.sh — 모드별 차이의 진짜 영향

### 2.1 모드별 파라미터 요약

| Mode | RX_USECS / RX_FRAMES | GRO | WB DISPATCH / IMMEDIATE / TIMEOUT_MS / RT_PRIO | TPACKET BLOCK / NR / RETIRE / POLL | cpufreq | cpuidle |
|---|---|---|---|---|---|---|
| latency | 0 / 1 | off | 64 / 1 / 1 / 80 | 8K / 32 / 1 / 1ms | 변경 없음 | 변경 없음 |
| normal  | 50 / 4 | on | 64 / 1 / 1 / 50 | 16K / 64 / 1 / 1ms | 변경 없음 | 변경 없음 |
| eco     | 100 / 6 | on | 96 / 0 / 5 / 40 | 32K / 64 / 5 / 3ms | conservative (up=80,down=20) | 변경 없음 |
| thermal | 150 / 10 | on | 128 / 0 / 10 / 30 | 64K / 128 / 10 / 10ms | powersave | 모든 state enable |

### 2.2 mlan에서 ethtool은 NULL ops에 막힌다

`mlinux/moal_main.c:5510` `woal_netdev_ops`:
- `.ndo_set_features` / `.ndo_fix_features` 정의 없음
- `dev->ethtool_ops = ...` 등록 없음 (mlinux/*.c 전체)

→ 커널 `dev_ethtool()`이 `-EOPNOTSUPP` 반환 → 스크립트의 `|| log_warn` 분기로 떨어짐. **모드별 RX_USECS/RX_FRAMES/GRO/GSO/TSO 차이는 mlan0에서는 0**.

> 참고: `mlinux/moal_cfg80211.c`의 `woal_cfg80211_set_coalesce`는 cfg80211 WoWLAN packet coalescing(슬립 중 패킷 매칭)이지 ethtool RX coalescing이 아님. 두 개념이 다름.

### 2.3 SDIO IRQ 경로 (iMX93)

`mlinux/moal_sdio_mmc.c:279` `woal_sdio_interrupt`:
```c
woal_sdio_interrupt(func) {       // 실행 CPU = mmc2 IRQ affinity가 결정
    handle->main_state = MOAL_RECV_INT;
    mlan_interrupt(0, handle->pmlan_adapter);     // host_int_status 읽기
    handle->main_state = MOAL_START_MAIN_PROCESS;
    mlan_main_process(handle->pmlan_adapter);     // ★ hard IRQ 컨텍스트에서 처리
}
```

핵심:
- mlan0 net_device는 IRQ가 없다 — `/proc/interrupts`에 mlan0 없음. SDIO 인터럽트는 **mmc2 컨트롤러** 행으로 들어옴. `setup-irq-affinity.sh`의 `find_wlan_irq()`가 `mmc2`를 찾는 이유.
- `mlan_main_process`가 hard IRQ context에서 1차, workqueue `handle->main_work` (`mlinux/moal_main.c:12947 woal_main_work_queue`)에서 2차 실행. mlan 내부 `main_process_lock`이 직렬화.
- IRQ affinity = "SDIO 처리 CPU = CPU3 (4코어 보드 기준)". 그 CPU의 cpufreq/cpuidle 상태가 wake-up latency를 결정.

### 2.4 main_work warmup

`mlinux/moal_init.c:95` `int bridge_keepalive_ms = 1` (module_param default).

`mlinux/moal_bridge.c:46-65` `moal_bridge_keepalive` hrtimer:
- bridge active 동안 무조건 `queue_work(handle->workqueue, &handle->main_work)` 호출.
- 1ms 주기로 main_process를 강제 wakeup.
- workqueue는 `WQ_HIGHPRI` bound (driver-bridge.design.md "WQ_UNBOUND → bound" 변경).

**의미**: moal kernel bridge가 켜진 순간 setup-irq-affinity.sh의 모드별 차이는 mlan 측 latency에 거의 무의미. 1ms 주기 hrtimer가 latency를 평탄화함.

### 2.5 모드별 실측 효과 (moal engine 기준)

- **latency**: eth0 coalescing 0, IRQ CPU3 pin. cpufreq 손 안 댐 → 가장 fast wake. wbridge env는 dead code.
- **normal**: eth0 50µs/4프레임 coalescing. throughput과 latency 균형.
- **eco**: cpufreq=conservative(up=80, down=20) → ramp-up 느림 → burst 첫 부분 latency tail 가능. keepalive hrtimer는 여전히 1ms.
- **thermal**: cpufreq=powersave + cpuidle deep enable. **하지만 keepalive 1ms hrtimer가 deep idle 진입 차단** → 발열 저감 효과 제한적. 첫 패킷 wake-up latency ↑.

---

## 3. optimize-for-udp.sh — 모드 분기 없이 일괄 적용

### 3.1 항목별 영향 매트릭스

| # | 명령 | 영향 대상 | mlan0 적용? | moal bridge에서 의미 |
|---|---|---|---|---|
| 1 | `ip link set <IF> txqueuelen 10000` | qdisc TX queue 길이 | 적용되나 `MAX_TX_PENDING=800` cap이 우선 | burst drop 감소 |
| 2 | `wmem_max/default=16M`, `rmem_max/default=16M` | per-socket SO_*BUF 상한 | 무관 | wbridge userspace에서만 의미 |
| 2 | `netdev_max_backlog=10000` | per-CPU input_pkt_queue | **거의 무효** | `net_rx>=1` 경로 우회 |
| 3 | `iwconfig <wlan> power off` | moal SIOCSIWPOWER → PS_MODE_DISABLE | 결정적 | moal bridge latency의 전제조건 |
| 4 | `ethtool -G <IF> rx 4096 tx 4096` | net_device ring | **미지원** | mlan0 silent fail |
| 5 | `udp_mem`, `udp_rmem_min`, `udp_wmem_min` | UDP 전역 메모리 | 무관 | 다른 UDP 소비자 보호 |

### 3.2 txqueuelen vs MAX_TX_PENDING

`mlinux/moal_main.h:1010-1019`:
```c
#define MAX_TX_PENDING          800
#define MCLIENT_MAX_TX_PENDING  (128 * MAX_STA_COUNT)
#define MCLIENT_LOW_TX_PENDING  (MCLIENT_MAX_TX_PENDING * 3 / 4)
```

`mlinux/moal_main.c:8288`:
```c
if (atomic_read(&priv->phandle->tx_pending) >= MAX_TX_PENDING)
    /* netif_stop_queue() */
```

→ qdisc `txqueuelen=10000`이 깊어도 driver는 800에서 stop. throughput 상한 불변, burst loss 감소만.

### 3.3 netdev_max_backlog의 mlan dead 경로

`mlinux/moal_shim.c:2169-2181`:
```c
if (in_interrupt())                              netif_rx(frame);
else if (rx_pending > MAX_RX_PENDING_THRHLD)     netif_rx(frame);
else if (handle->params.net_rx >= 1)             { local_bh_disable(); netif_receive_skb(frame); local_bh_enable(); }
else                                             netif_rx_ni(frame);
```

- `net_rx>=1` 경로 → backlog 우회, stack에 즉시 push → `netdev_max_backlog` 무관.
- `netif_rx` 경로 → per-CPU `input_pkt_queue` 사용 → backlog 깊이 의미 있음.
- `driver-bridge.design.md`에 적힌 "netif_rx → netif_receive_skb (3곳) 변경"이 `net_rx>=1`을 활성화한 부분.

→ moal bridge RX는 backlog 거의 안 거치므로 `netdev_max_backlog=10000`은 효과 약함. eth0 RX(FEC NAPI) + RPS cross-CPU에서만 의미 있음.

### 3.4 iwconfig power off — 가장 결정적인 항목

`mlinux/moal_wext.c:3335`:
```c
[SIOCSIWPOWER - SIOCIWFIRST] = (iw_handler)woal_set_power,
```

`woal_set_power` (moal_wext.c:879) → 내부 `woal_set_get_power_mgmt` → mlan IOCTL → firmware `PS_MODE_DISABLE` (`mlinux/moal_cfg80211.c:1091-1092`).

**드라이버 동작**:
- PS ON: 802.11 power-save로 STA가 doze, SDIO bus deep power. SDIO IRQ wake overhead 큼 + main_work 깨워도 firmware 응답 지연.
- PS OFF: 칩 항상 awake, SDIO active. `bridge_keepalive_ms=1` hrtimer가 즉시 응답 → upstream 7ms 도달.

**함정**: `EFFECTIVE_MODE=thermal`이면 `wifi_bridge.sh:251-253`에서 optimize-for-udp.sh 통째 skip → PS off도 같이 빠짐 → supplicant/NM의 PS auto-on 가능 → moal bridge latency 회귀.

### 3.5 모드별 optimize-for-udp 적용

| EFFECTIVE_MODE | optimize-for-udp 실행? | iwconfig power off | sysctl/qlen |
|---|---|---|---|
| latency | 실행 | YES | YES |
| normal | 실행 | YES | YES |
| eco | 실행 | YES | YES |
| **thermal** | **SKIP** | **NO** ← 함정 | NO |
| `MODE_FORCE=1` + thermal | 실행 | YES | YES |

---

## 4. wifi_bridge.sh engine 분기

`wifi_bridge.sh:141-147, 359-369, 461-469`:

| Engine | 바이너리 | WBRIDGE_* env 소비 | 모드별 wbridge 튜닝 의미 |
|---|---|---|---|
| `pcap` (디폴트) | `/usr/local/bin/wifi-wbridge` (libpcap) | YES | DISPATCH_BUDGET, IMMEDIATE, TIMEOUT_MS, RT_PRIORITY, PCAP_BUFFER 살아있음 |
| `tpacket` | `/usr/local/bin/wifi-wbridge-tpacket` (AF_PACKET v3) | YES | TPACKET_BLOCK_SIZE/NR, RETIRE_TOV, POLL_TIMEOUT_MS, RT_PRIORITY 살아있음 |
| `moal` | (없음, `sleep 60` 루프) | NO | 전부 dead code |

`wifi_bridge.sh:149-156` thermal clamp:
```
EFFECTIVE_MODE = REQUESTED_MODE
if MODE_FORCE != 1:
    if THERMAL_STATE == "hot":   EFFECTIVE_MODE = "thermal"
    elif THERMAL_STATE == "warm" and REQUESTED == "latency": EFFECTIVE_MODE = "normal"
```

`wbridge-thermal-state.timer/service`가 칩 온도를 주기 갱신 → `WBRIDGE_THERMAL_STATE` 발행 → 자동 강등. `MODE_FORCE=1`로만 우회.

---

## 5. wifi_init_conf.json이 SSoT

`wifi_bridge.sh:16-48` `_load_wbridge_json_defaults`:
- `/usr/local/etc/wifi_init_conf.json`의 `.wbridge.optimize.mode`, `.engine`, `.thermal.mode_force` 등을 env로 export.
- systemd `/etc/default/wbridge` (EnvironmentFile)는 JSON 파싱 실패 시 fallback.

**함정**: 사용자가 `/etc/default/wbridge`만 수정하고 JSON을 안 건드리면 모드 변경이 안 먹는다.

---

## 6. 운용 권고

1. **moal engine + latency 운영**: `wifi_init_conf.json`에서 `optimize.mode=latency`, `thermal.mode_force=true`. 단 발열 보호장치가 없어지므로 외부 모니터링 필요.
2. **moal engine에서 thermal 모드 비추천**: cpufreq=powersave + cpuidle deep enable + keepalive 1ms hrtimer가 충돌. 발열 저감 효과 제한적이고 latency만 손해.
3. **`iwconfig power off`를 thermal에서도 보장**: optimize-for-udp.sh에서 PS off 부분을 분리 실행하거나, 별도 oneshot unit으로 보장.
4. **`IRQ_OPT_RESULT="applied"` 확인 의무**: `/run/wbridge.apply.json`의 `irq_optimization` 필드를 헬스체크 항목에 추가. setup-irq-affinity 실패 시 wbridge env가 무시되어 모드 차이가 사라짐.
5. **mlan0 대상 ethtool 호출은 정리 가능**: 항상 미지원 warn만 찍히므로 분기로 skip하면 로그 깨끗.
6. **txqueuelen 10000 효과 한계**: throughput 상한은 `MAX_TX_PENDING=800`이 결정. 진짜 throughput을 늘리려면 이 상수를 키워야 함 (단 SDIO/PCIe 대역폭과 firmware capability에 따라 unsafe).

---

## 7. 코드 위치 인덱스

### mlan/moal driver
- `mlinux/moal_main.h:1010-1019` — TX pending 상수 (`MAX_TX_PENDING=800`, `MCLIENT_*`)
- `mlinux/moal_main.c:5510` — `woal_netdev_ops` (ethtool_ops 등록 없음)
- `mlinux/moal_main.c:5690` — AP mode `dev->tx_queue_len = MCLIENT_MAX_TX_PENDING`
- `mlinux/moal_main.c:8288` — `MAX_TX_PENDING` 초과 시 queue stop
- `mlinux/moal_main.c:12947, 13018` — `woal_main_work_queue` → `mlan_main_process`
- `mlinux/moal_main.c:13349` — `MLAN_INIT_WORK(&handle->main_work, woal_main_work_queue)`
- `mlinux/moal_shim.c:2169-2181, 2574-2587` — STA mode RX 분기 (in_interrupt/backlog/net_rx)
- `mlinux/moal_sdio_mmc.c:279` — `woal_sdio_interrupt` (hard IRQ, mlan_main_process 호출)
- `mlinux/moal_sdio_mmc.c:1597` — `woal_sdio_claim_irq(card, woal_sdio_interrupt)`
- `mlinux/moal_bridge.c:46-65` — `moal_bridge_keepalive` hrtimer
- `mlinux/moal_bridge.c:55` — `queue_work(handle->workqueue, &handle->main_work)`
- `mlinux/moal_bridge.c:960-972` — keepalive timer 시작 분기
- `mlinux/moal_init.c:95` — `int bridge_keepalive_ms = 1`
- `mlinux/moal_init.c:3164-3165` — `module_param(bridge_keepalive_ms, ...)`
- `mlinux/moal_wext.c:879, 3335` — `SIOCSIWPOWER` → `woal_set_power`
- `mlinux/moal_cfg80211.c:1091-1092` — `PS_MODE_DISABLE` 패턴
- `mlinux/moal_priv.c:5452-5454` — PS mode 유효값(AUTO/POLL/NULL)

### wbridge userspace (engine=pcap/tpacket 시에만 의미)
- `wlan-bridge/wbridge/config.c:69-81` — wbridge-pcap env → cfg 필드 매핑
- `wlan-bridge/wbridge/wbridge-tpacket.c:644-656` — tpacket env → ring 파라미터

### 스크립트
- `setup-irq-affinity.sh:128-197` — 모드별 파라미터 정의
- `setup-irq-affinity.sh:232-240` — IRQ_AFFINITY pinned CPU 매핑
- `setup-irq-affinity.sh:250-266` — `find_wlan_irq()` (sdio 시 mmc2 검색)
- `setup-irq-affinity.sh:354-388` — cpufreq governor (eco/thermal) + cpuidle (thermal)
- `setup-irq-affinity.sh:391-418` — `/run/wbridge.env` 생성
- `optimize-for-udp.sh:18-19` — `TARGET_QLEN=10000`, `TARGET_BUF=16777216`
- `optimize-for-udp.sh:39-42` — `iwconfig <wlan> power off`
- `wifi_bridge.sh:141-147` — engine 분기
- `wifi_bridge.sh:149-156` — effective_mode clamp
- `wifi_bridge.sh:251-253` — thermal에서 optimize-for-udp skip
- `wifi_bridge.sh:267-279` — setup-irq-affinity 호출
- `wifi_bridge.sh:291-304` — `/run/wbridge.env` 로드 분기 (`IRQ_OPT_RESULT="applied"` 조건)
- `wifi_bridge.sh:461-469` — engine=moal 분기 (wbridge 바이너리 미실행)

---

## 8. 작성 컨텍스트

- 작성일: 2026-05-12
- branch: feature/driver-bridge
- 관련 commit: d877b00 (bridge peer_ipv4 self-IP filter), 69d1b43 (mlan0_rx_dropped triage), 90e5b1c (PDCA 문서 local-only)
- 관련 design doc: `driver-bridge.design.md`, `driver-bridge.qa-runbook.md`
- 관련 memory: `project_bridge_status.md` (upstream 31ms → 7ms), `feedback_sdio_warmup.md` (main_work idle→sleep), `feedback_conf_path.md` (wifi_init_conf.json 경로)
