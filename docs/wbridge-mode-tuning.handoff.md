# wbridge 모드 튜닝 — 다른 세션 인계 spec (4건)

> 분석 컨텍스트: `docs/wbridge-mode-impact.md`
> Notion KB: https://www.notion.so/35e8a230a04e8153b751eeb00ae3cbba
> 작성일: 2026-05-12 / branch: feature/driver-bridge
> 대상 보드: iMX8MM (PCIe wifi), iMX93 (SDIO wifi), NXP 88W9098

## 0. 작업 목적

`setup-irq-affinity.sh`, `wifi_bridge.sh` 모드별 튜닝 4건을 적용. 코드 레벨 분석 근거는 `wbridge-mode-impact.md` 6절 운용 권고와 정합. moal kernel bridge 경로(`engine=moal`) 우선 운용 시나리오.

## 1. 작업 대상 파일

| 파일 | 절대 경로 | 변경 라인 |
|---|---|---|
| setup-irq-affinity.sh | `/home/jhw/ai/opencode/projects/wlan-package/dist/wlan/usr/local/wlan-bridge/scripts/setup-irq-affinity.sh` | 128-197 (모드 case), 323-337 (ethtool 호출), 391-418 (env 출력) |
| wifi_bridge.sh | `/home/jhw/ai/opencode/projects/wlan-package/dist/wlan/usr/local/scripts/wifi_bridge.sh` | 340-356 (apply.json) |

## 2. 변경 항목 4건

### 2.1 변경 #1 — GRO normal/eco/thermal: on → off

**파일**: `setup-irq-affinity.sh`

**before** (mode case 3개):
```bash
    thermal)
        MODE_DESC="발열 최소화"
        RX_USECS=150; TX_USECS=150; RX_FRAMES=10
        GRO=on;       GSO=off;      TSO=off
        ...
    eco)
        MODE_DESC="저전력 (온도 저감)"
        RX_USECS=100; TX_USECS=100; RX_FRAMES=6
        GRO=on;       GSO=off;      TSO=off
        ...
    normal)
        MODE_DESC="균형 (일반)"
        RX_USECS=50;  TX_USECS=50;  RX_FRAMES=4
        GRO=on;       GSO=off;      TSO=off
        ...
```

**after**:
```bash
    thermal)
        ...
        GRO=off;      GSO=off;      TSO=off
    eco)
        ...
        GRO=off;      GSO=off;      TSO=off
    normal)
        ...
        GRO=off;      GSO=off;      TSO=off
```

**근거**:
- mlan0은 `ndo_set_features` 미등록 (`mlinux/moal_main.c:5510`) → GRO 토글 EOPNOTSUPP → mlan0 측 효과 0.
- eth0(FEC) 측: GRO off로 RX softirq segment 머지 비활성 → 작은 패킷 head latency ↓, bridge 포워딩에서 머지/재분할 비용 회피.
- latency 모드는 이미 GRO off → 4모드 일관화.

**위험**: 낮음. 1Gbps TCP throughput 5~15% ↓ 가능. ping/control 위주 운용에 정합.

**검증**:
```bash
# 적용 후
ethtool -k eth0 | grep generic-receive-offload
# 기대: "generic-receive-offload: off"

# 영향 측정 (베이스라인 대비)
iperf3 -c <peer> -t 30           # TCP throughput
iperf3 -c <peer> -u -b 100M -t 30 # UDP
ping -i 0.001 -c 5000 <peer>     # latency
```

**rollback**: 3개 case의 `GRO=off` → `GRO=on`.

---

### 2.2 변경 #2 — tpacket POLL_TIMEOUT eco/thermal auto

**파일**: `setup-irq-affinity.sh`

**before**:
```bash
    thermal)
        ...
        WB_TPACKET_RETIRE_TOV=10
        WB_TPACKET_BLOCK_SIZE=65536
        WB_TPACKET_BLOCK_NR=128
        WB_TPACKET_POLL_TIMEOUT_MS=10
    eco)
        ...
        WB_TPACKET_RETIRE_TOV=5
        WB_TPACKET_BLOCK_SIZE=32768
        WB_TPACKET_BLOCK_NR=64
        WB_TPACKET_POLL_TIMEOUT_MS=3
```

**after**:
```bash
    thermal)
        ...
        WB_TPACKET_POLL_TIMEOUT_MS=0   # 0 = retire_tov * 3 자동
    eco)
        ...
        WB_TPACKET_POLL_TIMEOUT_MS=0   # 0 = retire_tov * 3 자동
```

(주석: 동일 위치 latency=1, normal=1은 변경 없음. RETIRE_TOV/BLOCK_SIZE/BLOCK_NR 변경 없음.)

**근거**:
- `wbridge-tpacket.c:86-88` 주석에 "WBRIDGE_TPACKET_POLL_TIMEOUT_MS (ms, 0 = retire_tov * 3 자동)" 명시.
- 현재 eco는 POLL(3) < RETIRE(5) → retire 전 wake → 빈 손 wake → CPU 낭비 (eco의 "온도 저감" 의도와 모순).
- 현재 thermal POLL(10) = RETIRE(10) → 동등 타이밍 wake → 미세하게 빈 wake 빈번.
- auto는 retire×3으로 block 1~3개 채워질 시간 보장 → wake당 다중 패킷 처리.

**위험**: 낮음. eco/thermal은 latency보다 CPU 절약 우선이므로 정합. moal engine에서는 무관.

**검증**:
```bash
# wbridge env 확인 (engine=tpacket인 경우만 의미)
cat /run/wbridge.env | grep TPACKET_POLL_TIMEOUT_MS
# eco/thermal: 0

# CPU% 측정 (engine=tpacket로 전환 후)
mpstat -P ALL 1 30
# 기대: eco/thermal CPU% 변경 전보다 낮음
```

**부수 변경**: `setup-irq-affinity.sh:163-179` eco case 주석 "저전력 모드 (온도 저감 + 레이턴시 유지)" → "저전력 모드 (온도 저감 우선, 레이턴시 약간 양보)"로 정정 검토.

**rollback**: POLL_TIMEOUT_MS=3 (eco), 10 (thermal) 복원.

---

### 2.3 변경 #3 — latency RT_PRIORITY 80 → 70

**파일**: `setup-irq-affinity.sh`

**before**:
```bash
    latency)
        ...
        WB_RT_PRIORITY=80
```

**after**:
```bash
    latency)
        ...
        WB_RT_PRIORITY=70
```

**근거**:
- 80은 일반 SCHED_FIFO IRQ thread(보통 50) + critical RT(85+) 사이. wbridge가 IRQ thread를 preempt할 수 있음 → SDIO IRQ 처리 지연 → 자기 자신 bottleneck 가능.
- 70도 같은 영역이지만 critical RT와 안전 거리.

**위험**: 중. 80→70은 폭이 작아 효과 측정값이 noise floor 아래일 가능성.

**개선 옵션 (이번 변경 외, 검토 권고)**:
- 더 안전: 50 미만(예: 45~49)으로 내려 일반 IRQ thread에 양보. 단 wbridge userspace의 RT 보장이 약해짐.
- 보드별 RT 분포 확인:
  ```bash
  ps -eLo pid,cls,rtprio,comm | grep -E 'FF|RR' | sort -k3 -n
  uname -v | grep -i preempt    # PREEMPT_RT 여부
  ```
- PREEMPT_RT 커널이면 ksoftirqd/irq threads가 50± → 70은 여전히 위험. 변경 후 ping flood + iperf 동시 부하 시 latency tail 증가 모니터링.

**검증**:
```bash
# wbridge 프로세스 priority 확인 (engine=pcap/tpacket)
ps -eLo pid,cls,rtprio,comm | grep wifi-wbridge
# 기대: rtprio=70

# IRQ thread starvation 측정
ping -i 0.001 -c 10000 <peer> &
iperf3 -c <peer> -u -b 500M -t 30 &
mpstat -P ALL 1 30
# 기대: %soft + %irq가 한 CPU에서 saturate되지 않음
```

**rollback**: WB_RT_PRIORITY=80.

---

### 2.4 변경 #4 — /run/wbridge.apply.json에 ethtool 지원여부 기록

**파일**: `setup-irq-affinity.sh` + `wifi_bridge.sh`

#### 2.4.1 setup-irq-affinity.sh

`Interrupt Coalescing` 블록(line 323-337)을 결과 캡쳐 형태로 변경:

**before**:
```bash
if command -v ethtool &> /dev/null; then
    for IF in $ETH_IF $WLAN_IF; do
        if [ $RX_USECS -eq 0 ]; then
            ethtool -C $IF rx-usecs 0 rx-frames 1 2>/dev/null && \
                log_info "  $IF → 즉시 처리 (rx-usecs=0, rx-frames=1)" || \
                log_warn "  $IF coalescing 미지원"
        else
            ethtool -C $IF rx-usecs $RX_USECS tx-usecs $TX_USECS rx-frames $RX_FRAMES 2>/dev/null && \
                log_info "  $IF → 병합 (rx-usecs=$RX_USECS, rx-frames=$RX_FRAMES)" || \
                log_warn "  $IF coalescing 미지원"
        fi
    done
fi
```

**after** (결과 변수 캡쳐 추가):
```bash
ETHTOOL_COALESCE_ETH="unknown"
ETHTOOL_COALESCE_WLAN="unknown"
if command -v ethtool &> /dev/null; then
    for IF in $ETH_IF $WLAN_IF; do
        if [ $RX_USECS -eq 0 ]; then
            if ethtool -C $IF rx-usecs 0 rx-frames 1 2>/dev/null; then
                log_info "  $IF → 즉시 처리 (rx-usecs=0, rx-frames=1)"
                _result="supported"
            else
                log_warn "  $IF coalescing 미지원"
                _result="unsupported"
            fi
        else
            if ethtool -C $IF rx-usecs $RX_USECS tx-usecs $TX_USECS rx-frames $RX_FRAMES 2>/dev/null; then
                log_info "  $IF → 병합 (rx-usecs=$RX_USECS, rx-frames=$RX_FRAMES)"
                _result="supported"
            else
                log_warn "  $IF coalescing 미지원"
                _result="unsupported"
            fi
        fi
        if [ "$IF" = "$ETH_IF" ]; then
            ETHTOOL_COALESCE_ETH="$_result"
        else
            ETHTOOL_COALESCE_WLAN="$_result"
        fi
    done
else
    ETHTOOL_COALESCE_ETH="no_ethtool"
    ETHTOOL_COALESCE_WLAN="no_ethtool"
fi
```

ring buffer 블록(line 309-321)도 동일 패턴으로 `ETHTOOL_RING_ETH`/`ETHTOOL_RING_WLAN` 캡쳐.

offload(GRO/GSO/TSO) 블록(line 341-350)도 `ETHTOOL_OFFLOAD_ETH`/`ETHTOOL_OFFLOAD_WLAN` 캡쳐.

`/run/wbridge.env` 출력 블록(line 393-418)에 6개 변수 추가:
```bash
# ethtool 지원여부 (운용 가시성)
WBRIDGE_ETHTOOL_COALESCE_ETH=$ETHTOOL_COALESCE_ETH
WBRIDGE_ETHTOOL_COALESCE_WLAN=$ETHTOOL_COALESCE_WLAN
WBRIDGE_ETHTOOL_RING_ETH=$ETHTOOL_RING_ETH
WBRIDGE_ETHTOOL_RING_WLAN=$ETHTOOL_RING_WLAN
WBRIDGE_ETHTOOL_OFFLOAD_ETH=$ETHTOOL_OFFLOAD_ETH
WBRIDGE_ETHTOOL_OFFLOAD_WLAN=$ETHTOOL_OFFLOAD_WLAN
```

#### 2.4.2 wifi_bridge.sh

`write_apply_snapshot` 함수(line 341-356)에 6개 필드 추가:
```bash
write_apply_snapshot() {
cat > "$APPLY_SNAPSHOT" <<EOF
{
  "engine": "${WBRIDGE_ENGINE}",
  "optimize_enabled": "${USE_OPTIMIZATION}",
  "udp_optimization": "${UDP_OPT_RESULT}",
  "irq_optimization": "${IRQ_OPT_RESULT}",
  "mode_requested": "${WBRIDGE_MODE_REQUESTED}",
  "mode_effective": "${WBRIDGE_PROFILE_EFFECTIVE}",
  "thermal_state": "${WBRIDGE_THERMAL_STATE}",
  "mode_force": "${WBRIDGE_MODE_FORCE}",
  "link_guard": "${LINK_GUARD}",
  "ethtool_coalesce_eth": "${WBRIDGE_ETHTOOL_COALESCE_ETH:-unknown}",
  "ethtool_coalesce_wlan": "${WBRIDGE_ETHTOOL_COALESCE_WLAN:-unknown}",
  "ethtool_ring_eth": "${WBRIDGE_ETHTOOL_RING_ETH:-unknown}",
  "ethtool_ring_wlan": "${WBRIDGE_ETHTOOL_RING_WLAN:-unknown}",
  "ethtool_offload_eth": "${WBRIDGE_ETHTOOL_OFFLOAD_ETH:-unknown}",
  "ethtool_offload_wlan": "${WBRIDGE_ETHTOOL_OFFLOAD_WLAN:-unknown}",
  "updated_at": "$(date +%s)"
}
EOF
...
```

env source(line 313)에 새 변수 6개 추가:
```bash
export WBRIDGE_ETHTOOL_COALESCE_ETH WBRIDGE_ETHTOOL_COALESCE_WLAN \
       WBRIDGE_ETHTOOL_RING_ETH WBRIDGE_ETHTOOL_RING_WLAN \
       WBRIDGE_ETHTOOL_OFFLOAD_ETH WBRIDGE_ETHTOOL_OFFLOAD_WLAN 2>/dev/null || true
```

**근거**:
- mlan0은 `mlinux/moal_main.c:5510` `woal_netdev_ops`에 ethtool_ops 미등록 — 운용 시 "미지원" warn이 반복적으로 찍혀 혼란 유발. apply.json에 명시하면 헬스체크/디버깅 시 즉시 확인.
- 6필드 구조: ETH/WLAN × coalesce/ring/offload 매트릭스 가시화.

**위험**:
- apply.json 스키마 변경. **사전 소비처 확인 필수**:
  ```bash
  grep -rn "wbridge.apply.json\|apply_snapshot\|APPLY_SNAPSHOT" \
      /home/jhw/ai/opencode/projects/wlan-package/ \
      /home/jhw/ai/opencode/projects/wlan-driver-v2/
  ```
  reader가 strict JSON schema validation 사용 시 추가 필드로 깨질 수 있음. 발견된 reader 전체에서 추가 필드를 무시하는지 확인 후 진행.

**검증**:
```bash
# 적용 후 (브릿지 시작 후)
cat /run/wbridge.apply.json | jq .
# 기대: ethtool_coalesce_wlan: "unsupported", ethtool_coalesce_eth: "supported"

# 셸로 직접 검증
ethtool -c eth0  > /dev/null 2>&1 && echo eth_ok    || echo eth_fail
ethtool -c mlan0 > /dev/null 2>&1 && echo wlan_ok   || echo wlan_fail
# 기대: eth_ok / wlan_fail (코드레벨 확정)
```

**rollback**: apply.json 6필드 제거, /run/wbridge.env 6변수 제거, setup-irq-affinity.sh ethtool 블록을 변경 전 형태로 복원.

---

## 3. 빌드/배포 흐름

setup-irq-affinity.sh와 wifi_bridge.sh는 `wlan-package/dist/wlan/usr/local/...` 트리에 있음 → wlan-package 빌드 산출물. 변경 후:

```bash
# 1. wlan-package 패키징 (필요 시)
cd /home/jhw/ai/opencode/projects/wlan-package
# 빌드 방법은 wlan-package/README 참조

# 2. 타겟 보드 배포
scp /home/jhw/ai/opencode/projects/wlan-package/dist/wlan/usr/local/wlan-bridge/scripts/setup-irq-affinity.sh \
    root@<target>:/usr/local/wlan-bridge/scripts/
scp /home/jhw/ai/opencode/projects/wlan-package/dist/wlan/usr/local/scripts/wifi_bridge.sh \
    root@<target>:/usr/local/scripts/

# 3. 실행 권한 확인
ssh root@<target> 'ls -l /usr/local/wlan-bridge/scripts/setup-irq-affinity.sh /usr/local/scripts/wifi_bridge.sh'
# +x 비트 보존 필수 (CLAUDE.md 룰: 스크립트 수정 후 권한 확인)

# 4. 서비스 재시작
ssh root@<target> 'systemctl restart wifi_bridge@mlan0.service'
ssh root@<target> 'journalctl -u wifi_bridge@mlan0 -n 100'
```

## 4. 통합 검증 절차

```bash
# 1. 현재 모드 확인
cat /run/wbridge.effective.json | jq .
cat /run/wbridge.apply.json | jq .
cat /run/wbridge.env

# 2. ethtool 상태 (변경 #1 + #4 검증)
ethtool -k eth0 | grep -E 'generic-receive|generic-segmentation|tcp-segmentation'
# 기대: 모든 모드에서 generic-receive-offload: off

# 3. RT priority (변경 #3, engine=pcap/tpacket인 경우)
ps -eLo pid,cls,rtprio,comm | grep -E 'wifi-wbridge'
# 기대: latency 모드에서 rtprio=70

# 4. TPACKET POLL (변경 #2, engine=tpacket인 경우)
grep TPACKET_POLL_TIMEOUT_MS /run/wbridge.env
# 기대: eco/thermal=0, latency/normal=1

# 5. 모드 전환 테스트
for MODE in latency normal eco thermal; do
    # wifi_init_conf.json의 .wbridge.optimize.mode 변경 후 재시작 또는
    WBRIDGE_MODE=$MODE WBRIDGE_MODE_FORCE=1 systemctl restart wifi_bridge@mlan0
    sleep 5
    cat /run/wbridge.apply.json | jq -r '.mode_effective, .ethtool_coalesce_wlan'
done

# 6. 회귀 측정 (각 모드에서)
ping -i 0.001 -c 10000 <peer> | tail -3
iperf3 -c <peer> -t 30
iperf3 -c <peer> -u -b 500M -t 30
```

## 5. 회귀 모니터링 — 절대 회귀하면 안 되는 메트릭

`docs/wbridge-mode-impact.md`와 `project_bridge_status` memory 기반:

| 메트릭 | 기준값 | 측정 |
|---|---|---|
| moal bridge upstream ping RTT | ~7ms (pcap 수준 근접) | `ping -i 0.001` 평균 |
| moal bridge downstream ping RTT | ~7ms | 동상 (역방향) |
| SDIO main_work warm 유지 | `bridge_keepalive_ms=1` 동작 확인 | `cat /sys/module/moal/parameters/bridge_keepalive_ms` |

회귀 발생 시 우선 의심 변경:
- 변경 #1 (GRO off): eth0 측 throughput 회귀 가능 — 정합적 trade-off.
- 변경 #3 (RT 80→70): IRQ thread starvation 발생 시 latency 회귀 — 즉시 rollback 검토.

## 6. 위험 매트릭스

| # | 코드 근거 강도 | 위험 | rollback 난이도 | 검증 가능성 |
|---|---|---|---|---|
| 1 GRO off 전 모드 | 강 | 낮음 (throughput trade-off) | 1줄 ×3 | iperf3 |
| 2 POLL=0 auto | 강 (tpacket.c:87 주석) | 낮음 | 1줄 ×2 | mpstat (tpacket engine 한정) |
| 3 RT_PRIO 80→70 | 중 (방향 정합, 폭 작음) | 중 (IRQ preempt 잔존 가능) | 1줄 ×1 | mpstat + latency tail |
| 4 apply.json ethtool flag | 강 | 낮음 (스키마 변경, reader 영향 가능) | 다중 위치 | jq + ethtool |

## 7. 작업 순서 권고

병렬 진행 가능하나 검증 격리를 위해 순차 권장:
1. **#4 먼저** — 가시성 확보. 이후 #1~#3 검증 시 apply.json에서 상태 직접 확인 가능.
2. **#1** — eth0 ethtool에 즉시 반영되므로 검증 빠름.
3. **#2** — engine=tpacket 시나리오만 영향. moal engine 운용이면 dead code (안전).
4. **#3 마지막** — RT priority는 보드별 영향이 가장 크고 측정도 어려움. 단독 변경 후 충분히 모니터링.

각 단계 후 위 4절 통합 검증 + 회귀 메트릭 측정 → 통과 시 다음 단계.

## 8. 의존 자료

- 코드 레벨 분석: `docs/wbridge-mode-impact.md` (특히 7절 코드 위치 인덱스)
- Notion KB: https://www.notion.so/35e8a230a04e8153b751eeb00ae3cbba
- 관련 Decision Log (Notion): `wlan-driver-v2 커널 L2 브릿지 성능 분석 및 아키텍처 결정`
- 관련 design doc: `docs/driver-bridge.design.md`, `docs/driver-bridge.qa-runbook.md`
- memory: `project_bridge_status.md` (upstream 31ms→7ms 결과 보존 의무), `feedback_sdio_warmup.md` (main_work warm)

## 9. 미해결 / 다른 세션이 결정해야 할 사항

1. **변경 #3의 폭**: 80→70 vs 80→50 미만 중 선택. 보드의 PREEMPT_RT 여부 및 기존 RT thread 분포 확인 후 결정.
2. **변경 #4의 스키마 형식**: flat 6필드 (위 spec) vs nested `"ethtool": {"coalesce": {"eth": ...}, ...}`. 기존 apply.json이 flat이므로 일관성으로 flat 권장하지만 reader 확인 후 결정.
3. **변경 #4의 ring/offload 포함 여부**: coalesce만 vs 셋 다. spec에는 셋 다 포함. 만약 사용자 요청이 coalesce만이면 ring/offload 부분은 별도 follow-up.
4. **변경 #2의 주석 정정**: eco case 주석 "레이턴시 유지" 라벨 변경 여부.
5. **commit/PR 분리 정책**: 4건 한 commit vs 분리. spec은 작업 순서대로 4 commit 권장 (rollback 용이성).

## 10. Definition of Done

- [ ] 4개 변경 모두 적용 및 빌드 통과
- [ ] 타겟 보드에서 4개 모드 모두 정상 시작 (`journalctl -u wifi_bridge@mlan0` 에러 없음)
- [ ] `/run/wbridge.apply.json` 6개 신규 필드 검증
- [ ] moal engine 시나리오에서 upstream RTT ≤ 10ms (회귀 없음)
- [ ] iperf3 TCP/UDP 측정값을 변경 전 baseline과 비교 기록
- [ ] 변경별 commit 메시지에 본 spec 파일 경로 참조
