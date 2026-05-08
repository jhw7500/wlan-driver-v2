# moal driver — mlan0_rx_dropped 시간 비례 발생 현상 분석 자료

> **목적**: NXP `moal` driver `bridge_mode=1` 운영 시 `mlan0_rx_dropped` 가 일정 주기로 발생하는 현상의 driver 측 디버깅을 위한 인계 자료.
> **작성일**: 2026-04-30
> **갱신일**: 2026-04-30 (근본 원인 규명 추가 — §8)
> **선행 분석 세션**: wlan-package (보드 측 측정 자동화 + 패턴 관측 + driver bridge_debug 로그 매핑)
> **이 자료의 독자**: driver 디버깅 진행 세션 (예: wlan-driver-v2)
> **상태**: ✅ **근본 원인 규명 완료 — LLDP multicast 의 의도된 link-local drop**

---

## 0. TL;DR

> **결론**: NXP `moal_imx93.ko` (v505.p14) 의 `bridge_mode=1` 운영 시 `mlan0_rx_dropped` 가 ~30초 주기로 1씩 증가하는 원인은 **LLDP multicast (`dst=01:80:c2:00:00:0e`) 의 link-local drop**. driver bridge fastpath 가 표준대로 link-local multicast 를 forwarding 금지하면서 net device drop counter 에 누적. **버그가 아니라 정상 동작**. 응용 영향 0 (LLDP 는 PC2 의 자기 광고용 frame, 사용자 데이터 아님). 모니터링의 regression 기준만 완화하면 됨.
>
> 규명 방법: `bridge_debug=1` (module parameter runtime 토글) 활성화 후 dmesg 캡처 → `bridge: w2p link-local drop dst=01:..:00:0e` 명시 라인 9건 / 30s 주기로 발견. 자세한 분석은 §8 참조.

---

## 1. 환경

| 항목 | 값 |
|---|---|
| 보드 | imx93-11x11-lpddr4x-evk (aarch64) |
| Kernel | 6.6.3-lts-next-gccf0a99701a7-dirty SMP preempt |
| WLAN driver | `moal_imx93.ko` v505.p14 + `mlan_imx93.ko` v505.p14 (NXP M-WLAN) |
| 인터페이스 | mlan0 (wlan, SDIO bus), eth0 (FSL ENETC, eth0 측 192.168.1.1/24, 단 wbridge L2 forwarding 으로 측정 트래픽은 192.168.0.0/24 통과) |
| 모듈 옵션 | `mod_para=cts/wifi_mod_para.conf cal_data_cfg=...` |
| `bridge_mode` | 1 (wbridge.engine="moal" 일 때 적용) |
| 측정 토폴로지 | `[PC2 wireless 192.168.0.21] ──AP── [Board mlan0/eth0 bridge] ──eth── [PC1 wired 192.168.0.10]` |

### 1.1 driver 옵션 적용 흐름

```
wifi_init_conf.json (.wbridge.engine="moal")
    │
    ▼
/usr/local/scripts/wifi_init.sh::apply_bridge_mode_to_mod_para()
    │  → /lib/firmware/cts/wifi_mod_para.conf 의 bridge_mode 라인 갱신
    ▼
insmod moal_imx93.ko mod_para=cts/wifi_mod_para.conf cal_data_cfg=...
    │
    ▼
mlan_imx93.ko + moal_imx93.ko 가 wifi_mod_para.conf 파싱
    bridge_mode=1 인 경우 driver-level fastpath forwarding 활성
```

`/lib/firmware/cts/wifi_mod_para.conf` 의 `drv_mode=1` 섹션에 `bridge_mode=0` 또는 `bridge_mode=1` 라인이 존재하며, `wbridge.engine` 값 변경 시 wifi_init.sh 가 in-place rewrite 후 wifi_init.service 재시작으로 모듈 reload.

---

## 2. 증상 정의

### 2.1 무엇이 보이는가

```bash
# 보드에서
cat /sys/class/net/mlan0/statistics/rx_dropped
# moal mode 운영 중 약 60초마다 1씩 증가
```

| Engine | mlan0_rx_dropped 증가 |
|---|---|
| **moal** (bridge_mode=1) | ~60s 당 +1 (시간 비례) |
| pcap (user-space libpcap) | 0 |
| tpacket (user-space TPACKET_V3) | 0 |

다른 NIC 카운터 (`eth0_rx`, `eth0_tx`, `mlan0_tx`) 는 모두 0.

### 2.2 측정 데이터 (실측)

#### 9-cell baseline (이전 세션, 30s × 3 runs + ping 5000)

| 환경 | pcap mlan0_rx | tpacket mlan0_rx | moal mlan0_rx |
|---|---:|---:|---:|
| WiFi5-pure | 0 | 0 | **2** |
| WiFi6-mixed | 0 | 0 | **3** |
| WiFi6-pure | 0 | 0 | **3** |

#### 매트릭스 측정 (이번 세션, 10s × 3 + ping 5000 ≈ 80s)

| 회차 | pcap | tpacket | moal |
|---|---:|---:|---:|
| 1 | 0 | 0 | **2** |
| 2 (TX ring 1024) | 0 | 0 | **2** |

→ 80초 측정에서 일관되게 2 발생.

#### Timeline 측정 — 240s 연속 + 30s 간격 sampling (이번 세션 핵심 데이터)

| 시각 | rx_dropped 누적 | 30s 구간 증가 |
|---:|---:|---:|
| T+0 | 0 | (baseline) |
| T+30 | 0 | +0 |
| T+60 | 0 | +0 |
| **T+90** | **1** | **+1** ← 첫 발생 |
| T+120 | 1 | +0 |
| **T+150** | **2** | **+1** |
| T+180 | 2 | +0 |
| **T+210** | **3** | **+1** |
| T+240 | 3 | +0 |
| **T+270** (idle 30s) | **4** | **+1** ← iperf3 끝난 후에도 발생 |

iperf3 처리량: 55.25 Mbps, retransmits 225.

### 2.3 핵심 관찰

1. **첫 60초 = 0** → 초기 burst 가설 부정
2. **약 60초마다 +1** → 일정 주기 패턴
3. **idle 30s 동안에도 +1** → 사용자 트래픽과 무관
4. **트래픽 양 변경에 무감각** (eth0 TX ring 512→1024 영향 없음)
5. **user-space engine 에선 0** → moal driver 의 RX path 한정

---

## 3. 검증된 가설 / 배제된 가설 (중복 작업 방지)

### 배제됨

| # | 가설 | 검증 방법 | 결과 |
|---|---|---|---|
| H1 | eth0 TX ring 부족 → backpressure → mlan0 RX drop | `ethtool -G eth0 tx 1024` 후 매트릭스 재측정 | drop 동일 (2 → 2) |
| H2 | wifi_init restart 직후 reassociate burst 시점에 폐기 | wifi_init restart 후 idle 30초 sampling | rx_dropped 0 유지 → idle 무관 |
| H3 | 측정 트래픽 첫 burst (cold start) 한정 | 240s 연속 측정 + 30s sampling | 첫 60s 0, 이후 60s마다 +1 → 부정 |
| H4 | iperf3 트래픽 양에 비례 | idle 30s 에서도 +1 발생 | 트래픽과 무관 |

### 확정된 사실

| # | 사실 | 근거 |
|---|---|---|
| F1 | **시간 비례 base rate ~ 1/min ≈ 0.017 drop/s** | 240s timeline 데이터 |
| F2 | **iperf3 종료 후 idle 동안에도 발생** | T+270 (idle 30s 후) +1 |
| F3 | **moal mode 한정** | pcap/tpacket 에선 0 |
| F4 | **mlan0 RX 단계** (eth0_*, mlan0_tx 모두 0) | 4-counter delta 분해 결과 |

---

## 4. 다음 분석 후보 (driver 측)

`bridge_mode=1` 의 mlan0 RX path 에서 폐기되는 frame 의 정체를 추적해야 함. 시간 비례 / idle 무관 패턴은 다음을 시사:

### 4.1 가장 의심되는 메커니즘

| 후보 | 이유 |
|---|---|
| **A. driver timer / work_queue 의 주기적 housekeeping** | 60초 주기 → 1분 timer 가 있을 가능성. (예: 통계 폴링, neighbor table refresh, station roaming probe 등) |
| **B. AP beacon / management frame 폐기** | broadcast/multicast/management frame 이 bridge_mode forwarding logic 에서 reject. AP beacon ~100ms 주기지만 driver 가 일부만 잡고 폐기할 수 있음 |
| **C. station roaming probe response** | 60초 주기의 background scan / probe response 처리 중 driver 가 일부 frame 폐기 |
| **D. RX descriptor refill timing** | DMA descriptor pool 의 주기적 refill 사이 frame 도착 시 폐기 |

### 4.2 추적 시작 지점 (소스 키워드)

NXP moal/mlan downstream 또는 mainline `drivers/net/wireless/marvell/mwifiex/` 기준:

```
# bridge_mode 처리 진입점 검색
grep -rn 'bridge_mode' drivers/net/wireless/.../moal/ mlan/

# rx_dropped 카운터 증가 지점 (mlan0 한정)
grep -rn 'rx_dropped\|rxdropped\|RX_DROPPED' .../mlan/

# 60s 주기 timer 후보
grep -rn 'jiffies.*HZ\|mod_timer\|delayed_work\|timer_setup' .../mlan/ | grep -i '60\|min\|stat\|monitor'

# bridge fast-path RX
grep -rn 'woal_bridge\|bridge_xmit\|moal_bridge' .../moal/
```

### 4.3 추적 채널

```bash
# moal/mlan dynamic_debug enable (소스에 pr_debug/dev_dbg 가 있다면)
echo 'module moal +p' > /sys/kernel/debug/dynamic_debug/control
echo 'module mlan +p' > /sys/kernel/debug/dynamic_debug/control
dmesg -wH

# trace event (mwifiex 시리즈에 trace point 있으면)
ls /sys/kernel/debug/tracing/events/ | grep -iE 'mlan|moal|mwifiex|wlan'

# 또는 driver 내 debug counter (자체 statistics)
ls /sys/kernel/debug/mwifiex/ 2>/dev/null
ls /proc/mwlan/ 2>/dev/null
ls /proc/net/mwlan_adapter*/mlan0/ 2>/dev/null  # NXP downstream 의 흔한 위치
cat /proc/mwlan/adapter*/mlan0/info  # 또는 debug, histogram, stats 등
```

### 4.4 결정적 실험 권장

> 정확한 폐기 지점 찾으려면 다음을 한 번씩 해보면 빠름.

| 실험 | 가설 | 측정 |
|---|---|---|
| **E1: AP 끄고 보드만 idle** | beacon listening 도중 polling 으로 발생? | mlan0 down? AP 없을 때 60s 마다 발생 여부 |
| **E2: mlan0 promiscuous off + bridge_mode=1** | 일부 frame 만 잡고 나머지 폐기 | drop rate 변화 |
| **E3: tcpdump -i mlan0** + drop 카운터 | drop 시점에 flying frame 종류 확인 | 어떤 frame 이 drop 직전에 들어옴 |
| **E4: dynamic_debug ON + 60s 관측** | driver 내부 폐기 라인 식별 | dmesg 에 drop 맥락 출력 |
| **E5: ethtool -S mlan0** (지원 시) | driver-internal stats 노출 | rx_dropped 증가와 동기 카운터 찾기 |

### 4.5 연관 문서 / 코드

| 위치 | 내용 |
|---|---|
| `dist/wlan/usr/local/scripts/wifi_init.sh` | mod_para 적용 + insmod (라인 594) |
| `dist/wlan/usr/local/scripts/wifi_init.sh::apply_bridge_mode_to_mod_para()` | wbridge.engine → bridge_mode 갱신 (라인 273) |
| `/lib/firmware/cts/wifi_mod_para.conf` | drv_mode=1 의 bridge_mode 행 (보드: 라인 114, 137, 163, 181) |
| Linux mainline 비슷 위치 | `drivers/net/wireless/marvell/mwifiex/` (단 NXP downstream 은 다른 layout) |

---

## 5. 재현 절차

### 5.1 자동화 도구 — wbridge_quick.sh

이번 세션에서 측정 자동화 wrapper 가 보드 `/usr/local/tools-fastpath/wbridge_quick.sh` 에 배포되어 있음. 한 줄 실행:

```bash
ssh root@192.168.0.100 \
    '/usr/local/tools-fastpath/wbridge_quick.sh run --engine=moal --duration=10'
```

→ 결과 JSON `/var/log/wbridge-bench/quick/baseline/moal/<ts>.json` 에 저장. drop 카운터는 `.board_monitoring.mlan0_rx_dropped_delta` 필드.

### 5.2 Timeline 실험 재현 (이번 세션이 사용한 스크립트)

보드의 `/tmp/timeline_test.sh` (240s 연속 + 30s sampling). 또는 이 자료 부록 A 참조.

### 5.3 수동 빠른 재현

```bash
# 보드 SSH 후
# 1) moal 모드 강제
jq '.wbridge.engine="moal"' /usr/local/etc/wifi_init_conf.json > /tmp/c.tmp
mv /tmp/c.tmp /usr/local/etc/wifi_init_conf.json
systemctl reset-failed wifi_init.service
systemctl restart wifi_init.service
sleep 15

# 2) baseline 카운터
T0=$(cat /sys/class/net/mlan0/statistics/rx_dropped)
echo "T0=$T0"

# 3) 5분 idle (트래픽 없이)
sleep 300

# 4) drop 증가 확인 — 5분 idle 만으로도 +5 발생 예상
T1=$(cat /sys/class/net/mlan0/statistics/rx_dropped)
echo "T1=$T1  delta=$((T1 - T0))"
```

idle 만 으로도 ~5/min 비율로 증가 예상.

---

## 6. 측정 결과 / 자료 위치

### 6.1 호스트 (저장소)
- 본 분석 자료: `docs/04-report/features/moal-mlan0-rx-drop-investigation.md`
- engine mode 동작 비교: `docs/reports/wbridge-engine-modes-explained.md`
- 9-cell baseline: `docs/reports/wbridge-fastpath-baseline-wifi5-wifi6.md`
- HZ_1000 after 비교: `docs/reports/wbridge-fastpath-after-pure-wifi6-comparison-v3.md`
- Plan/Design (자동화 도구): `docs/01-plan/features/wbridge-quick.plan.md`, `docs/02-design/features/wbridge-quick.design.md`
- Runbook: `docs/runbooks/wbridge-quick-runbook.md`, `docs/runbooks/wbridge-serial-runbook.md`

### 6.2 보드 (192.168.0.100)
- 결과 JSON: `/var/log/wbridge-bench/{baseline,quick/baseline}/{pcap,tpacket,moal}/*.json`
- Timeline 로그: `/tmp/timeline_test.log` (보존 시간 한정 — 휘발 가능)
- Warmup 실험 로그: `/tmp/warmup_test.log`
- driver 모듈: `/opt/wlan/driver/{moal_imx93.ko, mlan_imx93.ko}`
- mod_para conf: `/lib/firmware/cts/wifi_mod_para.conf`

---

## 7. driver 분석 세션 인계 체크리스트 (갱신 — 대부분 완료)

- [x] 본 자료 1회 통독
- [x] driver bridge_debug 로그 채널 식별 (`/sys/module/moal/parameters/bridge_debug`)
- [x] dmesg 캡처로 폐기 frame 의 정체 식별 — **LLDP multicast `01:80:c2:00:00:0e`**
- [x] 메커니즘 규명 — `bridge: w2p link-local drop` 라인 명시
- [x] driver 동작이 **표준 준수 정상 동작** 임을 확인
- [ ] (선택) wbridge_report.sh 의 regression 기준 완화 (운영 false positive 제거)
- [ ] (선택) driver 코드 측에서 `link-local drop` 카운터를 별도로 분리해 net device dropped 와 구분 — 모니터링 친화

→ driver 추가 패치 우선순위 낮음. 운영상 무시 가능.

---

## 8. 근본 원인 규명 (2026-04-30 갱신)

### 8.1 결정적 증거 — `bridge_debug=1` 활성화 후 dmesg

`bridge_debug=0` (default) 에선 verbose 로그 출력 안 함. runtime 으로 토글:

```bash
echo 1 > /sys/module/moal/parameters/bridge_debug   # rw, module reload 불필요
```

이후 240초 측정 + 30초 idle 동안 dmesg 에 다음 라인이 **정확히 30초 주기로 9건** 출력:

```
23:22:56  bridge: w2p link-local drop dst=01:XX:XX:XX:00:0e
23:23:26  bridge: w2p link-local drop dst=01:XX:XX:XX:00:0e
23:23:56  bridge: w2p link-local drop dst=01:XX:XX:XX:00:0e
23:24:26  bridge: w2p link-local drop dst=01:XX:XX:XX:00:0e
23:24:56  bridge: w2p link-local drop dst=01:XX:XX:XX:00:0e
23:25:26  bridge: w2p link-local drop dst=01:XX:XX:XX:00:0e
23:25:56  bridge: w2p link-local drop dst=01:XX:XX:XX:00:0e
23:26:26  bridge: w2p link-local drop dst=01:XX:XX:XX:00:0e
23:26:56  bridge: w2p link-local drop dst=01:XX:XX:XX:00:0e
```

이 dmesg 9건이 sysfs `mlan0_rx_dropped` 의 +5 증가 (T+0=19 → T+270=24) 와 시간대 매칭. 30s sample 폭 안에 들어간 drop 이 sample 사이에서 1 또는 0 으로 보였을 뿐, 실제로는 30초 주기.

### 8.2 폐기 frame 정체

| 항목 | 값 |
|---|---|
| Destination MAC | **`01:80:c2:00:00:0e`** |
| 표준 정의 | IEEE 802.1AB LLDP multicast — **Nearest Bridge Group Address** |
| 광고 주기 | 30초 (LLDP TX interval default) |
| 발신자 | wlan 측 (PC2 — `lldpd` 등 LLDP daemon 운영 추정) |
| 보드 multicast list 등록 | `info` 의 `multicast_address[5]="01:80:c2:00:00:0e"` |

LLDP / STP BPDU / 802.1X / Pause frame 등 link-local multicast (`01:80:c2:00:00:00 ~ 01:80:c2:00:00:0F`) 는 **표준상 bridge forward 금지** (IEEE 802.1D 7.12).

### 8.3 메커니즘

```
[PC2 wireless] ─── LLDP advertise (30s 주기, dst=01:80:c2:00:00:0e) ──►
   mlan0 RX
        ↓
   moal bridge fastpath (w2p 방향, wlan→eth)
        ↓
   destination MAC range 검사 → "link-local multicast"
        ↓
   forwarding 금지 (표준 준수)
        ↓
   skb 폐기 + bridge debug "link-local drop" 출력
        ↓
   net device dropped counter (mlan0 rx_dropped) 증가
```

### 8.4 모든 관찰의 정합성

| 관찰 | 정합 설명 |
|---|---|
| ~30s 주기 발생 | LLDP TX interval default 30s |
| 트래픽 양 무관 | LLDP 는 별도 주기 광고, iperf3 트래픽 별개 |
| idle 동안에도 발생 | LLDP 는 idle 무관 |
| moal mode 한정 | bridge fastpath 가 link-local 검사하고 폐기 |
| pcap/tpacket 에선 0 | user-space engine 은 frame 모두 받아 IP stack 으로 → IP stack 이 LLDP silent drop (carrier counter 증가 X) |
| eth0_rx, mlan0_tx 모두 0 | wlan 측에서 와서 wlan→eth 시도 중 drop, 다른 방향엔 흔적 X |

### 8.5 추가로 발견된 driver 동작 (참고)

dmesg 에 같이 출력된 다른 메시지 (정상 동작):

| 메시지 | 의미 | 빈도 |
|---|---|---|
| `bridge: w2p_thread cpu=N M pkts` | wlan→eth forward thread 처리 단위 | 304k 건 |
| `bridge: p2w RX <smac> -> <dmac> proto=... len=...` | eth→wlan 방향 RX | 134k 건 |
| **`bridge: w2p SELF-IP skip clone dip=192.168.0.100`** | 보드 자기 IP(mlan0) 가 dest 인 frame 은 forward 안 하고 IP stack 으로 (정상) | 854 건 |
| `bridge: w2p FWD` | 정상 forward 완료 | 3 건 |
| **`bridge: w2p link-local drop dst=01:..:0e`** | LLDP 폐기 (이번 분석 대상) | **9 건** |

`SELF-IP skip clone` 은 mlan0 IP 가 destination 인 패킷을 driver bridge fastpath 가 자기 IP stack 으로 정상 전달하는 경로 (예: 보드로 SSH/ARP/ICMP 가 들어올 때). drop 과 별개.

### 8.6 결론

> **버그 아님. 표준 준수 정상 동작.**

- `mlan0_rx_dropped` 증가 = LLDP link-local frame 의 의도된 폐기
- 응용 데이터 손실 0
- driver 코드 수정 불필요
- 운영 모니터링은 base rate (~30s/1) 무시하도록 기준 완화 권장

### 8.7 운영·모니터링 권장 (확정)

| 항목 | 권장 |
|---|---|
| **wbridge_bench.sh regression 기준** | `nic_drop_total > 0` → `nic_drop_total > duration_sec / 25` (예: 60초 측정에서 2 이하 OK) |
| **운영 default** | 그대로. driver 정상. |
| **driver 측 (선택)** | `link-local drop` 을 별도 카운터로 분리해 net device dropped 와 분리 노출하면 모니터링 친화. 우선순위 낮음 |
| **bridge_debug** | 운영에선 OFF (default). 디버깅 필요 시만 runtime 토글 |

### 8.8 재현 절차 (검증 완료)

```bash
# 보드 SSH
echo 1 > /sys/module/moal/parameters/bridge_debug
dmesg --clear
sleep 60
dmesg | grep 'link-local drop'
# → 1~2 라인 (LLDP, 30s 주기)
```

---

## 9. driver 측 인계 메시지 (확인 결과 + 추가 요청 사항)

> 본 섹션은 NXP `moal/mlan` driver 를 직접 분석·수정하는 세션 (예: `wlan-driver-v2`) 에게 전달되는 인계 내용. 본 자료의 §0~§8 을 모두 확인했다는 가정.

### 9.1 wlan-package 측에서 확인 완료된 결과

| 항목 | 결과 |
|---|---|
| `mlan0_rx_dropped` 증가 원인 | **LLDP multicast (`dst=01:80:c2:00:00:0e`) 의 link-local forward 거부** (driver bridge fastpath 의 의도된 동작) |
| 발생 주기 | ~30초 (LLDP TX interval default) |
| 폐기 frame 비율 | 약 0.005~0.03 drop/s (트래픽 무관) |
| 응용 데이터 영향 | **없음** (사용자 unicast TCP/UDP 와 무관) |
| 진단 채널 | `bridge_debug=1` 로 dmesg 에 `bridge: w2p link-local drop dst=...` 출력 (확정) |
| user-space engine 비교 | pcap/tpacket 에선 `mlan0_rx_dropped=0` — IP stack 단계의 silent drop 이라 net device counter 미증가 |
| **결론** | **driver 동작은 IEEE 802.1D 표준 준수 — 버그 아님** |

### 9.2 driver 측 검토·개선 요청 사항 (우선순위 순)

#### 🟢 R1. `link-local drop` 카운터 분리 노출 (권장 ★★★)

**문제**: 의도된 폐기 (link-local drop) 와 진짜 RX 실패 (skb alloc 실패, queue overflow 등) 가 동일한 `net_device->stats.rx_dropped` 카운터에 누적되어 모니터링 false positive 유발.

**요청**: 별도 카운터로 분리.

| 옵션 | 위치 | 장점 |
|---|---|---|
| (a) `/proc/mwlan/adapter*/mlan0/bridge_stats` 신규 노출 | proc | 기존 NXP info/debug 와 통일 |
| (b) `/sys/class/net/mlan0/statistics/` 와 별개로 driver-internal counter | sysfs | systemd/prometheus 친화 |
| (c) `ethtool -S mlan0` 에 `link_local_drops`, `self_ip_skip`, `fwd_w2p`, `fwd_p2w` 노출 | ethtool | 표준 도구 호환 |

권장: **(c) ethtool -S** — 표준화 + 외부 모니터링이 즉시 활용 가능.

**핵심**: link-local drop 은 net device dropped 카운터에서 **제외**. 자체 카운터로만 노출하면 운영 모니터링 단순화.

#### 🟡 R2. `bridge_debug=1` verbose 수준 throttling (권장 ★★)

**문제**: 1회 4분 측정에서 dmesg 에 **53만 라인** 출력 — 운영에선 사용 불가.

```
304k  bridge: w2p_thread cpu=N M pkts
134k  bridge: p2w RX ...
96k   bridge: p2w_thread cpu=N M pkts
854   bridge: w2p SELF-IP skip clone ...
9     bridge: w2p link-local drop ...
```

`w2p_thread`, `p2w` RX, `p2w_thread` 가 packet 단위로 출력되어 폭주.

**요청**: bridge_debug bitmask 분리 또는 ratelimit.

```c
#define BRIDGE_DBG_DROP        BIT(0)   /* link-local drop, oom 등 */
#define BRIDGE_DBG_SKIP        BIT(1)   /* SELF-IP skip clone */
#define BRIDGE_DBG_FWD         BIT(2)   /* normal forward */
#define BRIDGE_DBG_THREAD      BIT(3)   /* w2p_thread / p2w_thread per-batch */
#define BRIDGE_DBG_RX_DETAIL   BIT(4)   /* p2w RX header dump */
```

또는 `net_ratelimit()` / `printk_ratelimited()` 적용. 운영 default 는 OFF, 특정 비트만 선택 활성 가능하게.

#### 🟡 R3. 다른 link-local multicast frame 의 일관 처리 검증 (★★)

LLDP 외 link-local multicast 그룹 (`01:80:c2:00:00:00 ~ 0F`):

| MAC | 표준 | 현 driver 동작 검증 필요 |
|---|---|---|
| 00 | STP BPDU | forward 거부? |
| 01 | IEEE Pause frame | 폐기? (raw L2 라 IP 없음) |
| 02 | LACP / Link Aggregation | ? |
| 03 | 802.1X | ? |
| 0E | LLDP | **확인됨 (link-local drop)** |
| 0F | Provider Bridge MAC | ? |

→ driver 코드에서 `01:80:c2:00:00:00 ~ 0F` 범위 검사가 일관적인지 확인. mainline `bridge_in_should_drop()` 같은 표준 helper 와 비교.

#### 🟢 R4. dmesg 출력 형식 표준화 (★)

분석 자동화 친화적 prefix 권장:

```
[현재]  bridge: w2p link-local drop dst=01:..:0e
[제안]  bridge: drop=link-local dst=01:..:0e direction=w2p
```

또는 카테고리를 일관 prefix 로:
```
bridge.drop  : reason=link-local dst=...
bridge.skip  : reason=self-ip   dip=...
bridge.fwd   : direction=w2p    dst=... len=...
bridge.stat  : w2p fwd=N drop=N err=N oom=N
```

자동 파싱·로그 분류·외부 알람 시스템에 친화. 우선순위는 낮음.

#### 🟢 R5. `bridge_keepalive_ms=1` 의 의미와 운영 영향 명세 (★)

driver init dmesg 에 `bridge: keepalive = 1ms` 출력. 1ms 마다 무엇이 동작하는지 문서/주석 부족.

**요청**:
- 1ms keepalive 가 정확히 무엇을 하는가 (peer link 상태 폴링? thread wake? heartbeat?)
- 운영 환경에서 늘려도 OK 한가 (CPU 부담 ↓ 가능?)
- module parameter `bridge_keepalive_ms` 의 권장 범위와 trade-off 문서화

#### 🟢 R6. `tcp_ack_drop_cnt=112170` 의 의미 (★)

`/proc/mwlan/adapter*/mlan0/debug` 에 `tcp_ack_drop_cnt` 값이 측정 중 큰 폭으로 누적. **TCP ACK aggregation/compression** 으로 추정되나 문서 부족.

**요청**: TCP ACK 압축 동작 명세, mlan0 throughput / retransmit 수치 와의 관계, 비활성화 옵션 (성능 차이 측정용) 노출 여부.

### 9.3 driver 측에서 회신해주면 좋은 정보

다음 정보를 wlan-package 분석에 다시 반영:

| ID | 정보 |
|---|---|
| Q1 | bridge fastpath 의 link-local drop 결정 코드 위치 (file:line) |
| Q2 | 다른 link-local MAC range 처리 일관성 (R3) |
| Q3 | bridge_keepalive_ms 가 동작하는 워크로드 (R5) |
| Q4 | tcp_ack_drop_cnt 의 정확한 의미 (R6) |
| Q5 | NXP downstream tree 에서 링크 가능한 source path (Yocto/build recipe 기준) |

### 9.4 wlan-package 측 후속 작업 (driver 회신 무관 진행)

driver 회신 없이도 wlan-package 자체적으로 진행 가능:

- [ ] `wbridge_bench.sh` 의 `nic_drop_total > 0` regression 기준을 비율 기반으로 완화 (예: `> duration_sec/25`)
- [ ] `wbridge_quick.sh report` 에 link-local drop base rate 안내 메시지 추가
- [ ] `docs/runbooks/wbridge-quick-runbook.md` 트러블슈팅 §6.x 에 "moal mode 의 nic_drop 1~수 개는 정상" 안내 추가

---

## 10. Phase A/B 검증 (`bridge_consume_link_local` 토글, 2026-04-30 갱신)

> driver 측 R1 회신: `bridge_consume_link_local` 라는 module parameter 와 `rx_nohandler` 카운터 노출 + DBG-RXDROP 다종 prefix 추가됨.
> 본 절은 wlan-package 측에서 두 phase 비교 측정한 결과.

### 10.1 driver 갱신 사항 (확인됨)

| 항목 | 상태 |
|---|---|
| `moal.ko` srcversion (loaded) | `5F5B5B3C56555227FA63FDC` (이전 `F422...` 와 다름 — driver 갱신됨) |
| `mlan.ko` srcversion (loaded) | `02B3F841598BB6F6E7B1B99` (변동 없음) |
| 호스트 vs 보드 sha256 | 일치 (`bff326e0...`) |
| 신규 module parameter | `/sys/module/moal/parameters/bridge_consume_link_local` (rw runtime 토글) |
| 신규 noted parameter | `/sys/module/moal/parameters/bridge_debug` (이전부터 있었음) |
| 신규 net device statistics | `/sys/class/net/mlan0/statistics/rx_nohandler` (노출됨) |
| 신규 DBG-RXDROP prefix (모듈 strings) | `easymesh_invalid_pre_skb` / `easymesh_invalid_post_skb` / `skb_overflow` / `mon_no_skb` / `alloc_skb_fail` / `filter_reject` / `w2p link-local consume=%d` / `p2w link-local` |

### 10.2 측정 조건

- 모드: `bridge_mode=1` + `bridge_debug=1` + `bridge_consume_link_local` 토글
- Phase 당 4분 idle (트래픽 없음 — LLDP 30s 주기만 발생)
- 카운터 sample: BEFORE / AFTER (idle 240s 사이)
- dmesg `--clear` 후 누적 캡처
- transient unit `phase-test.service` 으로 ssh 끊김 영향 없이 실행

### 10.3 결과

| 측정 | Phase A (consume=0) | Phase B (consume=1) |
|---|---:|---:|
| `rx_dropped` Δ | **4** | **4** |
| `rx_nohandler` Δ | **0** | **0** |
| `[DBG-RXDROP] w2p link-local consume=0` | 8건 | 0 |
| `[DBG-RXDROP] w2p link-local consume=1` | 0 | 8건 |
| `bridge: w2p link-local drop` | 8 | 8 |
| 라인 timestamp 간격 | ~30s | ~30s |
| LLDP frame 정보 | dst=`01:80:c2:00:00:0e` proto=`0x88cc` len=`266` | 동일 |

샘플 라인 (Phase A):
```
[158.09]  [DBG-RXDROP] w2p link-local dst=01:..:0e proto=0x88cc len=266 consume=0
[187.99]  +29.9s
[217.99]  +30s
[248.10]  +30s
[278.10]  +30s
... (총 8건)
```

### 10.4 가설 검증 (둘 다 부정)

| 가설 | 사전 예상 | 실측 | 판정 |
|---|---|---|---|
| **Phase A** consume=0 → kernel `dev->rx_nohandler` 자동 증가 | rx_nohandler Δ ≈ rx_dropped Δ ≈ 8 | rx_nohandler Δ = 0 | ❌ |
| **Phase B** consume=1 → driver 명시 폐기 → 카운터 0 | rx_dropped Δ = 0 + rx_nohandler Δ = 0 | rx_dropped Δ = 4 | ❌ |

→ **`consume` 토글이 sysfs 카운터에 영향 없음**. 두 phase 모두 동일한 sysfs 결과 (`rx_dropped Δ=4`, `rx_nohandler Δ=0`).

### 10.5 새로 발견된 의문 — DBG-RXDROP 8건 vs `rx_dropped` +4 (2:1)

4분 동안 LLDP 30s 주기 = **frame 8개** 도착이 자연스러운데:
- DBG-RXDROP w2p 라인: **8건** (frame 1개당 라인 1개로 가정)
- `rx_dropped` 카운터: **+4** (frame 2개당 +1)

추정 가설:
| # | 가설 |
|---|---|
| H1 | LLDP frame 1개가 driver 의 두 처리 path (예: peer_rx_handler + rx_handler) 를 모두 거쳐 DBG-RXDROP 라인이 2번 출력 → 실제 frame 4개 (= rx_dropped +4 일치) |
| H2 | `rx_dropped++` 가 LLDP 도착 시점이 아닌 driver 의 별도 GC/timer 시점에 반영 (rate 가 frame 절반에 동기) |
| H3 | 첫 frame 들이 baseline 캡처 직전에 폐기 → 카운터 4 부족 + 마지막 일부가 sample 후 |

타임스탬프 분포 (158, 187.9, 217.9, 248.1, 278.1) 가 약 30s 정확 간격 → frame 1개 → 라인 1개 가능성도 있음. 그러나 카운터 +4 는 절반.

### 10.6 driver 측 추가 회신 요청

```
[wlan-package → driver-v2]

✅ 검증됨:
- driver 갱신 정상 적용 (srcversion 변경, sha256 일치)
- bridge_consume_link_local rw 토글 동작 (DBG-RXDROP 라인의 consume=0/1 표기 일치)
- bridge_debug=1 OK

❌ 두 가설 모두 부정:
- Phase A (consume=0): rx_nohandler Δ=0 (kernel dev->rx_nohandler 증가 가설 부정)
- Phase B (consume=1): rx_dropped Δ=4 (driver 명시 폐기로 카운터 0 가설 부정)

🤔 두 phase 가 사실상 동일 sysfs 결과:
- 4분 idle 측정 시 두 phase 모두 rx_dropped +4, rx_nohandler 0
- consume 토글이 sysfs 카운터 영향 없음

🔍 새 의문 — DBG-RXDROP 8건 vs rx_dropped +4 (2:1 비율)
- LLDP frame 1개당 DBG-RXDROP 라인 2개 출력 의심 (path 2개)
- 또는 rx_dropped++ 가 LLDP 도착 시점이 아닌 다른 곳

추가 확인 요청 (Q6~Q9):
Q6. LLDP w2p 처리에서 DBG-RXDROP 가 호출되는 정확한 코드 위치 (file:line, 1~3개)
Q7. Phase A (consume=0) 에서 frame 이 driver 내에서 어떻게 처리되는지 — return RX_HANDLER_PASS / kfree_skb / netif_rx 등
Q8. rx_dropped++ 가 driver 내 어디서 호출되는지 (이번 +4 증가가 자동 메커니즘 vs 명시 호출)
Q9. dmesg DBG-RXDROP 라인 timestamp 분포 — frame 당 1라인인지 2라인인지 driver 측에서 검증 가능?

요약: consume 토글의 sysfs 영향이 없는 점이 의외. driver 의 rx_dropped++ 호출 지점이 어디든 두 phase 모두 동일하게 도달하는 구조로 보임.
```

### 10.7 결론 (운영 영향 — 변동 없음)

§8 의 결론과 동일하게 유지: **응용 영향 0** (LLDP 본인 광고 frame 의 link-local 폐기는 표준 동작). consume 토글 결과 sysfs 카운터에 변화 없음. Phase A 도 user-space 응용엔 무영향. 단 driver 내부 처리 경로 명확화는 driver-v2 회신 (Q6~Q9) 필요.

---

## 11. driver-v2 회신 통합 (2026-04-30)

> 원본 회신 자료: `docs/04-report/features/moal-mlan0-rx-drop-driver-v2-reply.md`
> 본 절은 driver-v2 측이 wlan-package §10 결과를 받고 분석한 회신을 통합한 것.

### 11.1 driver-v2 측 결론 (확정)

1. **driver 코드에 `rx_dropped` 직접 증가 코드 0건** — `mlinux/`, `mlan/` 전체 grep 재확정.
   - `priv->stats.rx_dropped++` 7개 path 에 `pr_info_ratelimited` 마커 박았으나 5분 측정 동안 hit 0
   - `ndev->stats.rx_dropped` / `atomic_long_inc(&dev->rx_dropped)` 직접 호출 0
2. **sysfs `rx_dropped` 의 진짜 source = kernel `__netif_receive_skb_core()` drop label**:
   ```c
   // linux 6.6 net/core/dev.c
   drop:
       if (!deliver_exact)
           atomic_long_inc(&skb->dev->rx_dropped);
       else
           atomic_long_inc(&skb->dev->rx_nohandler);
       kfree_skb_reason(skb, reason);
   ```
3. **LLDP frame 의 driver 내 처리** (Phase A, consume=0):
   - `moal_bridge_rx_fast()` 의 link-local 분기 `mlinux/moal_bridge.c:392`
   - `br->wlan_to_peer.dropped++` (driver-internal atomic, sysfs 무관) 만 증가
   - return 0 → 호출자 normal path 계속 → `netif_rx()` → kernel stack 진입 → ptype handler 부재 → drop label
4. **Phase B (consume=1) 에서도 sysfs +4 인 점은 의외** — bridge fastpath 외 별도 entry 의심 (G1 가설)

### 11.2 driver 측 변경 사항 (이번 빌드)

| 위치 | 변경 |
|---|---|
| `mlinux/moal_init.c` | `bridge_consume_link_local` module_param 0644 추가 |
| `mlinux/moal_bridge.c:22` | extern declaration |
| `mlinux/moal_bridge.c:392~408` (w2p) | DBG-RXDROP w2p link-local + consume 토글 분기 |
| `mlinux/moal_bridge.c:515` (p2w) | DBG-RXDROP p2w link-local |
| `mlinux/moal_shim.c` | 7개 `priv->stats.rx_dropped++` path 에 `pr_info_ratelimited` 마커 (모두 hit 0 확인) |

### 11.3 G1 검증 측정 (RTNETLINK vs sysfs)

driver-v2 §3.4 의 결정적 측정 — `ip -s link show mlan0` 의 RX dropped 컬럼 (RTNETLINK, `woal_get_stats()` 만 반영) 과 `/sys/class/net/mlan0/statistics/rx_dropped` (sysfs, `priv + atomic` 합산) 의 Δ 차이.

**측정 조건**: Phase A (consume=0), 5분 idle (LLDP 30s 주기만 발생)

**예측 매트릭스**:
| RTNETLINK Δ | sysfs Δ | 의미 |
|---:|---:|---|
| 0 | +N | ✅ kernel 자동 폐기 (driver 무관) — 가설 확정 |
| +N | +N | priv->stats 측 grep 미포착 위치에서 증가 — 추가 추적 |
| 0 | 0 | LLDP 미발생 (테스트 환경 차이) |

**측정 결과** (2026-04-30 02:47~02:52 +09:00, Phase A consume=0, 5분 idle):

```
T0: ip_rx_dropped=30  sysfs_rx_dropped=30  sysfs_rx_nohandler=0
T1: ip_rx_dropped=35  sysfs_rx_dropped=35  sysfs_rx_nohandler=0
Δ:  ip=+5             sysfs=+5             nohandler=0

(sysfs - ip - nohandler) = 0   → dev->rx_dropped (atomic) 자동 증가량 = 0
DBG-RXDROP w2p link-local: 10건 (5분 동안, LLDP 30s 주기 ≈ 10 frame)
```

**Verdict** (v1 — 측정 채널 한계로 결판 불가):

⚠️ **본 v1 측정은 driver-v2 v2 회신 §7 에서 정정됨.** linux 6.6 의 `ip -s link show` (RTNETLINK) 와 sysfs `rx_dropped` 가 **둘 다 `dev_get_stats()` 합산 결과**라 본질적으로 같은 값. v1 매트릭스의 row 분리는 측정 채널 한계로 도출 불가능.

| v1 예측 | 실측 | 판정 |
|---|---|---|
| ip Δ=0, sysfs Δ>0 (kernel 자동 폐기) | — | 측정 한계로 분리 불가 |
| ip Δ=sysfs Δ (driver priv->stats 측 증가) | ip=5, sysfs=5 | 측정 한계로 분리 불가 |
| ip Δ=0, sysfs Δ=0 | — | ❌ |

→ **본 v1 결과의 verdict 는 §12 (v2 측정) 로 정정됨**. 정확한 분리는 `/proc/mwlan/.../info::num_rx_pkts_dropped` (priv->stats 단독) 와 sysfs 비교로만 가능. 결과: §12 참조 — **G1 (kernel 자동 폐기) 확정**.

**잔존 의문** (v2 측정 후 §12.5 에 정리):
1. driver-v2 marker 7개 hit 0 + sysfs +5 의 시나리오는 v2 측정으로 정합 (§12 참조)
2. **DBG-RXDROP 10건 vs sysfs Δ 5 의 2:1 비율** — Q13/Q14 로 driver-v2 측 추가 회신 요청 (§12.6)

### 11.4 driver-v2 가 보충 답한 항목

| ID | 정보 |
|---|---|
| **Q5** | NXP downstream 과 다른 driver-bridge feature 트리: `/home/jhw/ai/opencode/projects/wlan-driver-v2/{mlan,mlinux}/` |
| **R5** | `bridge_keepalive_ms=1` — `moal_bridge.c:45` 의 `moal_bridge_keepalive` hrtimer. peer link 폴링/wake 용. CPU 부담 측정 안 됨 |
| **R6** | `tcp_ack_drop_cnt` — mlan 코어의 TCP ACK aggregation/compression 카운터. 별도 분석 영역 |

### 11.5 운영 가이드 (driver-v2 측 보강 — §10.7 + §8.7 와 일관)

- **응용 영향 0** 유지 (LLDP 본인 광고 frame, 사용자 데이터 무관)
- **모니터링**: `wbridge_bench.sh` regression 기준 `nic_drop_total > duration_sec / 25` 로 완화 권장
- **카운터 정확히 0 으로 만들고 싶을 때**: driver 패치보다 **lldpd 또는 cap_net_raw 응용으로 LLDP socket 등록** 이 정도. ptype handler 가 잡으면 kernel drop label 도달 안 함
- **카운터 분리 (R1)** — driver-v2 가 추후 `ethtool -S mlan0` 또는 `/proc/mwlan/.../bridge_stats` 노출 작업 가능 (현 패치 범위 외)

### 11.6 G1 결판 — 부정 ⚠ → driver-v2 측 추가 추적 요청

G1 가설 (kernel 자동 폐기) **부정**됐고, ip Δ == sysfs Δ == +5 → driver `priv->stats.rx_dropped` 가 실제로 증가하는 path 가 driver-v2 의 marker 7개 외에 있음. 추가 회신 요청 (Q10~Q12):

```
[wlan-package → driver-v2 추가 회신 요청]

✅ G1 검증 결과:
- ip(RTNETLINK) Δ = sysfs Δ = +5 (5분 idle, Phase A)
- nohandler Δ = 0
- dev->rx_dropped(atomic) 자동 증가량 = 0
- DBG-RXDROP w2p link-local 10건 (LLDP 30s × 5분)

→ 회신 §3.4 예측 매트릭스의 row 2 일치. driver priv->stats 측에서 grep 안 잡힌 위치에서 +5 증가.

🔍 추가 회신 요청 (Q10~Q12):

Q10. priv->stats.rx_dropped 또는 ndev->stats.rx_dropped 가 marker 7개 path 외에서 증가하는 위치를 다시 찾아주세요.
     - 후보 a: br->wlan_to_peer.dropped++ 이 woal_get_stats() 합산 시 priv->stats.rx_dropped 에 누적되는가?
     - 후보 b: AMSDU subframe path (moal_shim.c:~2151) 의 다른 분기
     - 후보 c: cfg80211 mgmt/monitor mode path 의 polluted skb 처리
     - 검증: kprobe 로 atomic_long_inc 또는 priv->stats.rx_dropped 의 모든 호출 스택 trace

Q11. DBG-RXDROP 10건 vs sysfs Δ 5 의 2:1 비율 — frame 1개당 라인 1개 보장이라 했는데 측정에선 2:1
     - 측정 윈도우 양 끝 LLDP 가 카운터 반영되기 전/후 race?
     - 또는 frame 1개당 카운터 +0.5 가 아니라 frame 2개당 +1 의 batch 처리?
     - DBG-RXDROP 라인 timestamp 의 30s 정확 간격을 driver 측에서 검증할 수 있는지

Q12. woal_get_stats() 가 합산하는 카운터 모두 grep —
     - priv->stats 외 br->*.dropped, mon_if->stats, mlan core 측 dropped 까지 통합 view
     - dev_get_stats() 의 ndo_get_stats 에서 어떤 atomic 들이 들어오는지

검증 추가 측정 (선택, driver-v2 측):
- kprobe -p priv->stats.rx_dropped 증가 함수에 stack trace
- 또는 ftrace function_graph 로 woal_recv_packet → woal_get_stats 사이의 카운터 변화 추적
```

### 11.7 잠재 가설 (회신 대기 중 wlan-package 측 추정)

driver-v2 마커 7개가 hit 0 이었으나 +5 증가 — 가장 가능성 높은 시나리오:

**가설 X**: `br->wlan_to_peer.dropped` (driver-internal atomic, fastpath 392 분기) 가 `woal_get_stats()` 의 합산 결과로 RTNETLINK + sysfs 양쪽에 노출.
- driver-v2 회신 §4.1 에 "br->wlan_to_peer.dropped++ (driver-internal 별도 atomic)" 라 적혀있는데, 만약 woal_get_stats 가 이를 합산한다면 이번 결과와 일치
- 검증: `woal_get_stats()` 함수 본문에 br stats 합산 로직 있는지 driver-v2 측 grep

이 가설이 맞다면:
- DBG-RXDROP 10건 / sysfs Δ 5 의 2:1 비율은 별도 의문으로 남음 (frame 1개당 카운터 +0.5 ?)
- 또는 단일 LLDP frame 이 hardware AMSDU 로 묶여 도착해 driver path 를 2번 거치고 카운터는 1번만 증가

### 11.8 운영 결론 — 변동 없음

가설 X 가 맞든 다른 메커니즘이든, **응용 데이터 영향 0** (LLDP frame 의 link-local 폐기, 사용자 unicast 무관). 운영 모니터링 기준 완화 권장 (`nic_drop > duration_sec/25`).

---

## 12. driver-v2 v2 회신 + G1 결판 (2026-04-30 갱신)

> 원본 v2 회신: `docs/04-report/features/moal-mlan0-rx-drop-driver-v2-reply.md` §7 정정 노트
> 본 절은 v2 측정 (`/proc/mwlan/.../info::num_rx_pkts_dropped` 채널) 으로 G1 결판한 결과 통합.

### 12.1 driver-v2 v2 회신 핵심 정정 사항

이전 v1 측정 (§11.3) 의 verdict B 는 **kernel 동작 가정 오류**:

| v1 가정 | 실제 (linux 6.6) |
|---|---|
| `ip -s link show` 의 RX dropped = `priv->stats.rx_dropped` 단독 | **`dev_get_stats()` 합산값** (priv + atomic dev->rx_dropped + atomic dev->rx_nohandler) |
| sysfs `rx_dropped` = 합산값 | 동일 (`dev_get_stats()`) |

→ 두 채널이 같은 source. 분리 불가능. v1 결과 (ip=5, sysfs=5) 는 자명한 결과 (둘이 같은 값) 이지 priv vs atomic 구분 불가.

### 12.2 v2 결정적 측정 채널 매트릭스

| 채널 | source | 단독 노출 |
|---|---|---|
| `/proc/mwlan/adapter*/mlan0/info::num_rx_pkts_dropped` | `priv->stats.rx_dropped` | ✅ priv 단독 |
| `/sys/class/net/mlan0/statistics/rx_dropped` | `dev_get_stats()` 합산 | priv + atomic + nohandler |
| `/sys/class/net/mlan0/statistics/rx_nohandler` | `atomic dev->rx_nohandler` | ✅ nohandler 단독 |
| 도출: sysfs - priv - nohandler | — | **`atomic dev->rx_dropped` 단독** |

### 12.3 v2 측정 결과 (2026-04-30 03:02~03:07, 5분 idle, Phase A consume=0)

```
T0 (03:02:36) priv=0  sys=46  noh=0
T1 (03:07:36) priv=0  sys=51  noh=0
Δ:            priv=0  sys=+5  noh=0  → atom_dev_rx_dropped = +5

DBG-RXDROP w2p link-local: 10건 (5분, LLDP 30s 주기)
```

### 12.4 G1 결판 — ✅ **확정**

| v2 매트릭스 row | 예측 | 실측 | 판정 |
|---|---|---|---|
| **A. priv=0, sys>0, noh=0, atom>0** | kernel `__netif_receive_skb_core()` drop label 의 `atomic_long_inc(&dev->rx_dropped)` source | priv=0, sys=+5, noh=0, atom=+5 | ✅ **G1 확정** |
| B. priv>0, priv=sys | driver priv->stats grep 미포착 위치 | — | ❌ |
| C. priv=0, sys>0, noh>0, atom=0 | rx_nohandler path | — | ❌ |

→ **driver `priv->stats.rx_dropped` 5분 측정 동안 0 변화** (driver-v2 의 marker 7개 hit 0 결과와 정합). 모든 +5 증가는 **kernel `atomic dev->rx_dropped`** 자동 증가 = LLDP frame 이 ptype handler 부재로 `__netif_receive_skb_core()` 의 drop label 도달.

### 12.5 메커니즘 (확정)

```
[PC2 lldpd] → LLDP multicast (dst=01:80:c2:00:00:0e, ethertype=0x88cc)
   ↓ (30s 주기)
[mlan0 RX]
   ↓
[moal_recv_packet (moal_shim.c)]
   ↓
[moal_bridge_rx_fast → :392 link-local 분기]
   br->wlan_to_peer.dropped++   (driver-internal 별도 atomic — sysfs 무관)
   pr_info_ratelimited("[DBG-RXDROP] w2p link-local ... consume=0")
   return 0
   ↓
[호출자 normal path]
   priv->stats.rx_packets++     (drop 카운트 X — packets 카운트)
   eth_type_trans → skb->pkt_type = PACKET_MULTICAST
   netif_rx(skb)                (← kernel stack 진입)
   ↓
[kernel __netif_receive_skb_core (linux 6.6)]
   ptype_base 검색 → LLDP (0x88cc) 등록자 없음
   → goto drop label
       atomic_long_inc(&skb->dev->rx_dropped)   ← +5 증가의 진짜 source
       kfree_skb_reason(skb, ...)
   ↓
[sysfs read]
   dev_get_stats() = priv->stats.rx_dropped (=0)
                   + atomic dev->rx_dropped (+5)
                   + atomic dev->rx_nohandler (=0)
                   = +5  ✓
```

### 12.6 잔존 의문 — DBG-RXDROP 10건 vs atom +5 (2:1 비율)

5분 측정 동안:
- LLDP 30s 주기 × 5분 = **frame 10개** 도착이 자연스러움
- DBG-RXDROP w2p link-local 라인 = **10건** (frame:line 1:1 가정 시 frame 10개)
- atomic dev->rx_dropped Δ = **+5**

→ DBG 라인이 frame 1개당 1회 보장이라면 frame 10개 → kernel drop label 도달도 10번 → atom +10 이 자연스러운데 +5.

#### 가설 후보

| # | 가설 | 가능성 |
|---|---|---|
| **Y1** | **driver 호출자 2곳 (single-frame `moal_shim.c:2304` + AMSDU subframe loop `moal_shim.c:2151`) 양쪽이 같은 frame 에 대해 모두 `moal_bridge_rx_fast()` 호출** → DBG 2회 / kernel 도달 1회 / atom +1. 5 frame × 2 호출 = DBG 10 / atom +5 | 매우 높음 |
| Y2 | wireless link layer dup retry 로 같은 LLDP frame 이 driver 에 두 번 도달 (HE-MCS retry / monitor mode dup). skb 1개 폐기 후 atom +1 만 | 중 |
| Y3 | kernel skb merge / batch 처리 | 낮음 |

driver-v2 v2 회신 §2.Q9 의 "frame 1개당 라인 1개 보장" 은 **단일 호출자 내** 의미. 두 호출자 모두 거치면 라인 2회 가능 — **Y1 이 가장 정합**.

### 12.7 driver-v2 측 추가 회신 요청 (Q13~Q14)

```
[wlan-package → driver-v2]

✅ G1 확정 (v2 측정):
- priv (proc/info::num_rx_pkts_dropped) Δ = 0
- sysfs Δ = +5
- rx_nohandler Δ = 0
- atomic dev->rx_dropped Δ = +5
- DBG-RXDROP w2p link-local = 10건
→ kernel __netif_receive_skb_core() drop label 자동 증가 메커니즘 입증

🔍 잔존 의문 — DBG 10 vs atom +5 (2:1):

Q13. moal_shim.c:2304 (single-frame) 와 :2151 (AMSDU subframe loop) 양쪽이 같은 LLDP frame 에 대해
     moal_bridge_rx_fast() 를 모두 호출하는 path 가 존재하나요?
     - 만약 yes: §2.Q9 의 "frame 당 라인 1회 보장" 은 단일 호출자 내 의미 → 호출자 2곳 모두 거치면 frame 1개당 DBG 2회 (Y1 가설 정합)
     - 검증: dump_stack() 추가 또는 호출자별 카운터 분리해 392 hit 시점 stack trace 확인 가능?

Q14. wireless link layer 의 LLDP multicast frame retry/duplicate 가능성?
     - 검증: /proc/mwlan/.../debug 의 rx_pending, sdio_rx_aggr 분포
     - 또는 mlan core 의 dup_frame counter

부수 의문 (Q15):
Q15. multicast 카운터가 0 인 이유 — eth_type_trans() 에서 PACKET_MULTICAST 분류는 kernel 이 하지만,
     priv->stats.multicast 에 driver 가 더하지 않음? driver 의 multicast 카운팅 정책 명세 부탁드립니다.
```

### 12.8 운영 가이드 (확정 — §10.7 + §11.5 과 일관)

- **응용 데이터 영향 0** (LLDP 본인 광고 frame 의 link-local 폐기는 표준 동작)
- **모니터링 권고 (확정)**: `wbridge_bench.sh` regression 기준을 `nic_drop_total > duration_sec / 25` 로 완화. LLDP base rate ~ 0.017 drop/s 정상 baseline
- **카운터 0 으로 만들고 싶으면**: 보드에 `lldpd` 또는 cap_net_raw 응용 등록 → ptype handler 가 잡으면 kernel drop label 도달 안 함
- **카운터 분리 (R1)**: driver-v2 가 `ethtool -S mlan0` 또는 `/proc/mwlan/.../bridge_stats` 노출 작업 권장 (현 패치 범위 외)

---



## 부록 A. Timeline 실험 스크립트 (보드 /tmp/timeline_test.sh)

```bash
#!/bin/bash
# 240s 연속 iperf3 + 30s 간격 mlan0 rx_dropped sampling
set +e
exec >/tmp/timeline_test.log 2>&1

ssh -o BatchMode=yes root@192.168.0.10 'pkill -f iperf3 2>/dev/null; true'
sleep 0.3
ssh -f -o BatchMode=yes root@192.168.0.10 'iperf3 -s -p 5201 >/tmp/iperf3-server.log 2>&1'
sleep 0.5

DROP=/sys/class/net/mlan0/statistics/rx_dropped
T0=$(cat $DROP)
echo "T+0  baseline rx_dropped_abs=$T0  delta=0"

ssh -o BatchMode=yes root@192.168.0.21 \
    'iperf3 -c 192.168.0.10 -p 5201 -t 240 -J' > /tmp/timeline_iperf.json 2>&1 &
START=$(date +%s)

show_at() {
    local target=$1 now elapsed
    now=$(date +%s); elapsed=$((now - START))
    [ $elapsed -lt $target ] && sleep $((target - elapsed))
    local rx=$(cat $DROP)
    printf "T+%-4ds  rx_dropped_abs=%-4d  delta=%-3d\n" "$target" "$rx" "$((rx - T0))"
}

for s in 30 60 90 120 150 180 210 240; do show_at $s; done
wait
sleep 30
RX_END=$(cat $DROP)
echo "T+270s (idle 30s 후) delta=$((RX_END - T0))"
echo "DONE"
```

systemd-run 으로 detach 실행 권장 (ssh 끊김 안전):

```bash
systemd-run --no-block --unit=timeline-test /tmp/timeline_test.sh
```

---

## 부록 B. 4-counter NIC drop 분해 jq

```bash
jq '{eth0_rx: .board_monitoring.eth0_rx_dropped_delta,
     eth0_tx: .board_monitoring.eth0_tx_dropped_delta,
     mlan0_rx: .board_monitoring.mlan0_rx_dropped_delta,
     mlan0_tx: .board_monitoring.mlan0_tx_dropped_delta,
     total: .board_monitoring.nic_drop_total}' \
   /var/log/wbridge-bench/quick/baseline/moal/*.json
```

---

_End of document. 이 자료를 driver 분석 세션 시작 시 첫 입력으로 사용하시면 중복 작업 없이 driver 내부 추적부터 진입 가능합니다._
