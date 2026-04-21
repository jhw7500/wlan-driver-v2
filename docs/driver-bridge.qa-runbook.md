# driver-bridge QA Runbook (iMX93)

> **Scope**: bridge v2 실장비 검증 시나리오. 타겟: iMX93 SDIO 보드.
> **Prereq**: `make_for_imx93.sh` 빌드 성공, `bin_wlan/moal_imx93.ko` 타겟 복사 완료.
> **실행 환경**: 타겟에 SSH 가능, eth0/mlan0/uap0 인터페이스 존재, iperf3 설치.

정적 검증은 호스트에서 `scripts/tests/bridge_static_checks.sh` 로 먼저 통과해야 함 (F1 RCU drain ordering + atomic peer_released 포함).

---

## 환경 변수 (타겟에서 export)

```bash
export MOAL_KO=/lib/modules/$(uname -r)/extra/moal_imx93.ko    # 또는 직접 경로
export PEER_IF=eth0
export WLAN_IF=mlan0
export WAN_HOST=192.168.1.100   # iperf3 서버 쪽 호스트 IP (LAN)
export WLAN_HOST=192.168.1.50   # 무선으로 연결된 클라이언트 IP
export LOG=/tmp/bridge_qa.log
: > "$LOG"
```

공통 유틸:
```bash
load() { insmod "$MOAL_KO" "$@"; sleep 2; }
unload() { rmmod moal 2>/dev/null; rmmod mlan 2>/dev/null; sleep 1; }
dmesg_tail() { dmesg | tail -n "${1:-20}"; }
panic_check() { dmesg | grep -Ei 'kernel panic|BUG:|WARN|general protection|null pointer' || true; }
```

---

## T-02 / T-08: 기본 로드/언로드 스모크

```bash
unload
load bridge_mode=1 bridge_peer=$PEER_IF bridge_debug=1
dmesg_tail 10 | grep -q "bridge: .* <-> .* deactivated\|bridge: .* bridge activated" \
  && echo "T-02 OK" | tee -a "$LOG" \
  || echo "T-02 FAIL" | tee -a "$LOG"

unload
lsmod | grep -q '^moal' && echo "T-08 FAIL (still loaded)" | tee -a "$LOG" \
                       || echo "T-08 OK"   | tee -a "$LOG"
```

---

## T-03 / T-04: 양방향 ping (1 min)

```bash
load bridge_mode=1 bridge_peer=$PEER_IF
# 유선 호스트에서 무선 클라이언트 ping (p2w)
ping -c 60 $WLAN_HOST | tee -a "$LOG" | tail -3

# 무선 클라이언트에서 유선 호스트 ping (w2p) — 타겟에서 직접
ping -c 60 -I $WLAN_IF $WAN_HOST 2>/dev/null | tee -a "$LOG" | tail -3
unload
```

성공 기준: 손실률 < 1%, avg latency < 20ms.

---

## T-09 — 100회 insmod/rmmod 스트레스 (F1 ordering 회귀 감시)

```bash
for i in $(seq 1 100); do
  load bridge_mode=1 bridge_peer=$PEER_IF || { echo "FAIL load@$i"; break; }
  sleep 0.3
  unload || { echo "FAIL unload@$i"; break; }
  if [ $((i % 10)) -eq 0 ]; then echo "iter=$i OK"; fi
done
panic_check | tee -a "$LOG"
```

**실패 시그널**: `BUG:`, `kernel panic`, `use-after-free`, `RCU stall`, `scheduling while atomic`.

---

## T-10 — peer DOWN/UP graceful

```bash
load bridge_mode=1 bridge_peer=$PEER_IF
ip link set $PEER_IF down; sleep 1
dmesg | tail -5 | grep -q "peer '$PEER_IF' went down" && echo "DOWN ok" | tee -a "$LOG"
ip link set $PEER_IF up; sleep 2
dmesg | tail -5 | grep -q "peer '$PEER_IF' came up" && echo "UP ok" | tee -a "$LOG"
# IPv4 재캐시 확인
cat /sys/kernel/moal_bridge/stats | tee -a "$LOG"
unload
```

---

## T-11 (v2) — DBDC `bridge_wlan_idx` 전환

```bash
# BSS 0 (기본)
load bridge_mode=1 bridge_peer=$PEER_IF bridge_wlan_idx=0
cat /sys/kernel/moal_bridge/stats | grep -q 'active=1' && echo "wlan_idx=0 OK" | tee -a "$LOG"
unload

# BSS 1 (DBDC)
load bridge_mode=1 bridge_peer=$PEER_IF bridge_wlan_idx=1
cat /sys/kernel/moal_bridge/stats 2>/dev/null | tee -a "$LOG"
# BSS 1 미구성인 경우 -EBUSY/-ENODEV 예상 — dmesg 로그 확인
dmesg | tail -5
unload
```

---

## T-13 (v2) — sysfs stats 실시간 갱신

```bash
load bridge_mode=1 bridge_peer=$PEER_IF bridge_keepalive_ms=1
# 양방향 traffic 시작 (background iperf3)
iperf3 -c $WLAN_HOST -t 30 -i 5 &
IPERF=$!
for i in 1 2 3 4 5 6; do
  echo "--- sample $i ---"
  cat /sys/kernel/moal_bridge/stats
  sleep 5
done
wait $IPERF 2>/dev/null
unload
```

**기대**: `fwd_packets`/`fwd_bytes` 가 매 샘플마다 증가. `errors=0`, `oom=0`.

---

## T-14 (v2) — keepalive 효과 (latency p99)

```bash
# keepalive off
load bridge_mode=1 bridge_peer=$PEER_IF bridge_keepalive_ms=0
ping -c 1000 -i 0.01 -q $WAN_HOST | tee /tmp/ping_off.txt | tail -3
unload

# keepalive on (1ms)
load bridge_mode=1 bridge_peer=$PEER_IF bridge_keepalive_ms=1
ping -c 1000 -i 0.01 -q $WAN_HOST | tee /tmp/ping_on.txt  | tail -3
unload
```

**기대**: p99 latency 가 `keepalive_ms=1` 에서 유의미하게 낮음 (SDIO idle→sleep 우회). pcap 수준(~7ms RTT) 재현.

---

## S-01 — 24시간 iperf3 연속 부하

```bash
load bridge_mode=1 bridge_peer=$PEER_IF bridge_keepalive_ms=1
nohup iperf3 -c $WLAN_HOST -t 86400 -i 60 > /tmp/iperf3_24h.log 2>&1 &
IPERF=$!
# 1분 간격 snapshot
while kill -0 $IPERF 2>/dev/null; do
  { date; cat /sys/kernel/moal_bridge/stats; } >> /tmp/bridge_stats_24h.log
  sleep 60
done
panic_check | tee -a "$LOG"
unload
```

**성공 기준**: 24h 무중단, `dropped`/`errors`/`oom` 전량 0, panic 없음.

---

## S-02 — UDP flood

```bash
load bridge_mode=1 bridge_peer=$PEER_IF bridge_keepalive_ms=1
iperf3 -u -c $WLAN_HOST -b 0 -t 600 -i 30 | tee /tmp/udp_flood.log | tail
cat /sys/kernel/moal_bridge/stats
unload
```

**기대**: queue cap 512 에 도달 시 `dropped` 증가는 가능, **`errors=0` / panic 없음** 이 핵심.

---

## S-05 (v2) — RCU 회귀: traffic 중 rmmod

```bash
load bridge_mode=1 bridge_peer=$PEER_IF
iperf3 -c $WLAN_HOST -u -b 50M -t 60 &
IPERF=$!
sleep 5
# traffic 진행 중 언로드 시도
rmmod moal
wait $IPERF 2>/dev/null
panic_check | tee -a "$LOG"
unload 2>/dev/null
```

**실패 시그널**: `kernel BUG at include/linux/rculist.h`, `list_add corruption`, `general protection fault`, `scheduling while atomic`.

---

## S-06 (v2) — DBDC 중복 로드 guard

```bash
load bridge_mode=1 bridge_peer=$PEER_IF
# 이미 로드된 상태 — 두 번째 insmod 는 ENOMEM/EBUSY 혹은 이미 로드됨 메시지
insmod "$MOAL_KO" bridge_mode=1 bridge_peer=$PEER_IF 2>&1 | tee -a "$LOG"
dmesg | tail -5 | grep -Ei 'EBUSY|already|ENOMEM' && echo "DBDC guard OK" | tee -a "$LOG"
unload
```

**기대**: 두 번째 로드는 거부 (modprobe 는 자체로 재진입 방지 / DBDC guard 는 재init 시점에 `-EBUSY`).

---

## S-04 — peer 미존재

```bash
unload
insmod "$MOAL_KO" bridge_mode=1 bridge_peer=eth99 2>&1
dmesg | tail -5
# 드라이버는 로드되되 bridge=NULL (비활성)
lsmod | grep -q '^moal' && echo "driver loaded without bridge" | tee -a "$LOG"
unload
```

---

## 종합 결과 기록

```bash
echo ""
echo "======== QA SUMMARY ========"
grep -E 'OK|FAIL' "$LOG" | sort | uniq -c
echo "---- panics/warnings ----"
panic_check
echo "---- dmesg (last 50) ----"
dmesg | tail -50
```

이 출력을 `docs/driver-bridge.qa-runtime.md` 부록으로 기록하거나, `/jhw:record` 로 Notion Knowledge Base 에 저장.

---

## Pass/Fail 판정 기준

| 시나리오 | Pass | Fail |
|----------|------|------|
| T-02/08 | "activated"/"deactivated" 로그 존재 | 로그 없음 / rmmod 후 잔존 |
| T-03/04 | ping 손실 < 1%, avg < 20ms | 손실 > 5% 또는 avg > 50ms |
| T-09 | 100회 완주 + panic 0 | 중도 실패 또는 panic 감지 |
| T-10 | DOWN/UP 로그 + IP 재캐시 | 로그 없음 / stats inactive |
| T-11 | wlan_idx=0 active=1 | active=0 또는 init 실패 |
| T-13 | fwd_packets 증가 + errors=0 | 증가 없음 또는 errors>0 |
| T-14 | keepalive_ms=1 p99 < off 값 | p99 동등 또는 악화 |
| S-01 | 24h, errors=0, panic=0 | 중단 / errors>0 |
| S-02 | errors=0, panic=0 | errors>0 또는 panic |
| S-05 | rmmod 완료 + panic=0 | hang 또는 panic |
| S-06 | 두 번째 insmod 거부 | 두 개 동시 active |

---

## Known Issues (현재 버전)

1. **kthread freezer 미등록** — PM suspend 중 kthread 가 freeze 되지 않아 SDIO bus blocking 우려. suspend-to-ram 시나리오가 스코프에 있다면 추가 검증 필요.
2. **D7 VLAN+EAPOL peer 방향 한계** — peer_rx_handler 는 outer proto 만 검사. QinQ(0x88A8) 또는 VLAN-tagged EAPOL 이 peer 방향에서 들어오는 환경은 unsupported.
3. **FR-08 VLAN-ID 기반 필터** — 미구현 (Should 우선순위).

---

## References

- Design v2: `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.design.md`
- Analysis v3: `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.analysis.v3.md`
- Report v2: `/home/jhw/ai/opencode/projects/wlan-driver-v2/docs/driver-bridge.report.v2.md`
- Static checks: `/home/jhw/ai/opencode/projects/wlan-driver-v2/scripts/tests/bridge_static_checks.sh`
