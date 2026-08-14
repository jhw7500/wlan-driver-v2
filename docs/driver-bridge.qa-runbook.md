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

## T-15 — DBDC 런타임 브릿지 인터페이스 전환

이 절은 **실장비 전용**이다. `bridge_runtime_switch=1`로 로드된 활성 브릿지와, 서로 다른
두 MOAL STA가 모두 operator에 의해 미리 association되어 있어야 한다. QA 스크립트는 링크를
생성·UP·association하지 않으며 트래픽도 시작하지 않는다. 아래 절차와 양방향 트래픽을 실제로
수행하기 전에는 target-board validation 또는 lossless switching을 통과했다고 기록하지 않는다.

```bash
unload
# 선택된 초기 owner 블록에는 bridge_mode=1, 어느 matched 블록 하나에는
# bridge_runtime_switch=1을 둔다. conf를 수정할 수 없으면 기존
# bridge_runtime_switch=1 insmod 인자를 대신 사용할 수 있다.
load mod_para=cts/wifi_mod_para.conf
test "$(cat /sys/module/moal/parameters/bridge_runtime_switch)" = 1

# 기존 보드 절차(wpa_supplicant/제품 network manager)로 두 STA를 먼저 association한다.
# 다음 두 출력 모두 "Connected to ..."여야 한다.
iw dev mlan0 link
iw dev mlan1 link
cat /sys/module/moal/parameters/bridge_iface
```

전환 중에는 wired-side와 WLAN-side 시험 호스트에서 반대편을 향한 iperf3/ping을 동시에 실행해
**양방향 트래픽이 stress loop 전체 시간 동안 계속 흐르게 한다**. 각 트래픽 로그와 프로세스
PID를 보존한다. 인터페이스를 구성하는 명령은 보드별 운영 절차에서 수행하고 QA 스크립트에는
추가하지 않는다.

전후 상태, bridge thread, 모듈 reference count를 별도 파일로 캡처한다.

```bash
SNAP=/tmp/bridge-switch
capture_switch_state() {
  label="$1"
  {
    date
    iw dev mlan0 link
    iw dev mlan1 link
    ip -details -s link show mlan0
    ip -details -s link show mlan1
    cat /sys/module/moal/parameters/bridge_iface
    cat /sys/kernel/moal_bridge/stats
    grep '^moal ' /proc/modules || true
    ps -eLo pid,tid,comm,cls,rtprio,stat | grep -E 'moal_br_(w2p|p2w)' || true
  } | tee "$SNAP.$label.log"
}

capture_kmemleak() {
  label="$1"
  if [ -r /sys/kernel/debug/kmemleak ] && [ -w /sys/kernel/debug/kmemleak ]; then
    echo scan > /sys/kernel/debug/kmemleak
    sleep 5
    cat /sys/kernel/debug/kmemleak > "$SNAP.kmemleak.$label"
  else
    echo "UNAVAILABLE: /sys/kernel/debug/kmemleak" |
      tee "$SNAP.kmemleak.$label.unavailable"
  fi
}

capture_switch_state before
capture_kmemleak before

# 양방향 traffic가 실행 중인 별도 terminal/host를 확인한 다음 수행한다.
set -o pipefail
qa_rc=0
FROM_IF=mlan0 TO_IF=mlan1 SWITCH_LOOPS=1000 QA_CASE=stress \
  QA_EVIDENCE_DIR=/tmp/bridge-switch-qa-evidence \
  ./scripts/tests/bridge_runtime_switch_qa.sh 2>&1 |
  tee /tmp/bridge-switch-qa.log || qa_rc=$?

after_label="$([ "$qa_rc" -eq 0 ] && echo after || echo after-failure)"
capture_switch_state "$after_label"
capture_kmemleak "$after_label"
dmesg > /tmp/bridge-switch-dmesg.log
diff -u "$SNAP.before.log" "$SNAP.$after_label.log" > "$SNAP.state.diff" || true
if [ -f "$SNAP.kmemleak.before" ] && [ -f "$SNAP.kmemleak.$after_label" ]; then
  diff -u "$SNAP.kmemleak.before" "$SNAP.kmemleak.$after_label" \
    > "$SNAP.kmemleak.diff" || true
fi
[ "$qa_rc" -eq 0 ] || {
  echo "FAIL: runtime bridge QA failed; after snapshots are failure evidence" >&2
  exit "$qa_rc"
}
```

reference/leak 증거는 최소한 `/proc/modules`의 moal reference count, 두 netdev의 전후 존재/통계,
`moal_br_w2p`/`moal_br_p2w` thread가 각 snapshot에 정확히 한 쌍인지 포함한다. target kernel이
`CONFIG_DEBUG_KMEMLEAK`를 제공하면 위 `capture_kmemleak` 결과도 전후로 보존한다. 제공하지 않으면 그 정확한 경로
부재를 보고하고 leak 검증을 통과했다고 표시하지 않는다.

성공 판정에는 스크립트 PASS, 최종 `bridge_iface=mlan0`(effective owner), 예상 `switch_ok` 증가,
`switch_fail`/rollback counter 불변, 양방향 트래픽 결과, kernel warning 없음, thread/reference/leak
전후 검토가 모두 필요하다. `active=0`은 peer suspend 중에도 owner가 남아 있을 수 있으므로
`bridge_iface=none`과 동의어가 아니다. 전환은 synchronous이지만 teardown/init 사이에 짧은 패킷 중단 또는
손실이 가능하므로 무손실을 성공 기준으로 가정하지 않는다.

스크립트는 `dmesg --follow-new`를 시험 시작 전에 실행하여 긴 loop 중 ring rotation과 무관하게
새 kernel message를 evidence 디렉터리에 스트리밍한다. 스트리머를 시작할 수 없으면 시험은
fail-closed 한다. EXIT trap은 원래 종료 코드를 먼저 보존하고 `set +e`로 전환한 뒤, 실패 당시
state/full dmesg를 복구보다 먼저 저장한다. 자동 warning 판정은 unrelated historical warning을
오탐하지 않도록 follow-new stream만 사용하며 full snapshots는 수동 증거로 보존한다. 현재
binding이 stats상 `active=1`, `peer_released=0`이고 현재/원래 STA가
UP/associated인 경우에만 원래 binding을 best-effort 복구하고 복구 후 state를 다시 저장한다.
cleanup 실패는 성공을 실패로 승격하지만 원래 실패/시그널 종료 코드는 가리지 않는다.
`SWITCH_LOOPS`는 leading zero 없는 canonical decimal `1..100000`만 허용한다.

### T-15a — 파라미터화된 negative/concurrency/reset matrix

아래 각 행은 **서로 독립된 target 실행**이다. 필요한 module reload와 링크 상태를 행마다 먼저
준비하고 `QA_EVIDENCE_DIR`를 서로 다른 경로로 지정한다. 이 문서는 실행 결과를 주장하지 않는다.
`reject`는 실제 target 이름과 예상 Linux errno 번호를 operator가 지정하므로 non-MOAL과 MOAL
non-STA를 구분할 수 있다.

| 케이스 | 사전 조건 / 실행 예 |
|---|---|
| gate off | active load-time bridge, `bridge_runtime_switch=0`; `QA_CASE=gate-off` (`EOPNOTSUPP`) |
| no active bridge | `bridge_mode=0 bridge_runtime_switch=1`; `QA_CASE=no-active` (`ENODEV`) |
| malformed | active bridge/gate 1; `QA_CASE=malformed` (space, slash, overlong: `EINVAL`) |
| nonexistent | `QA_CASE=reject REJECT_TARGET=does-not-exist EXPECTED_ERRNO=19` |
| non-MOAL | `QA_CASE=reject REJECT_TARGET=eth0 EXPECTED_ERRNO=19` |
| MOAL non-STA | `QA_CASE=reject REJECT_TARGET=uap0 EXPECTED_ERRNO=22` (실제 non-STA 이름 사용) |
| target down | target를 admin-down으로 준비; `QA_CASE=target-down TO_IF=mlan1` (`ENETDOWN`) |
| disconnected | target는 UP이나 association 없음; `QA_CASE=target-disconnected TO_IF=mlan1` (`ENOLINK`) |
| same target | active target 준비; `QA_CASE=same-target`; `switch_ok` 불변 확인 |
| concurrent writers | 두 STA associated; `QA_CASE=concurrent SWITCH_LOOPS=1000`; real start barrier, release 직후 양 writer liveness, iteration evidence 및 terminal binding 확인. kernel-level syscall overlap은 trace로만 확정 가능. |
| peer down/up | active bridge; `QA_CASE=peer-cycle PEER_IF=eth0`; `active=0 -> 1`, old peer DOWN write의 `ENETDOWN`, `switch_ok` 불변 확인 |
| reset interaction | board-approved reset command를 `RESET_CMD`에 넣고 `QA_CASE=reset-interaction`; syscall-attempt marker 직후 writer liveness와 exact old owner/`active=1`/2 threads/module-loaded terminal state 확인 |
| unload interaction | board-approved unload command를 `UNLOAD_CMD`에 넣고 `QA_CASE=unload-interaction`; syscall-attempt marker 직후 writer liveness, node/module/thread absence 확인 |

예:

```bash
QA_CASE=reject REJECT_TARGET=eth0 EXPECTED_ERRNO=19 \
  QA_EVIDENCE_DIR=/tmp/bridge-qa.non-moal \
  ./scripts/tests/bridge_runtime_switch_qa.sh

QA_CASE=reset-interaction RESET_CMD='mlanutl mlan0 hostcmd fw_reload.conf' \
  SWITCH_LOOPS=100 QA_EVIDENCE_DIR=/tmp/bridge-qa.reset \
  ./scripts/tests/bridge_runtime_switch_qa.sh

QA_CASE=unload-interaction UNLOAD_CMD='modprobe -r moal' \
  SWITCH_LOOPS=100 QA_EVIDENCE_DIR=/tmp/bridge-qa.unload \
  ./scripts/tests/bridge_runtime_switch_qa.sh
```

reset/unload 동안 writer가 받은 `EBUSY`, `ENODEV`, `ESHUTDOWN`, 또는 signal interruption은 로그에
보존한다. Kernel 내부 `-ERESTARTSYS`는 일반적인 sysfs `write(2)` 사용자에게 `EINTR`로 보일 수
있으므로 둘을 서로 다른 driver 결과로 오판하지 않는다. 스크립트는 command timeout/nonzero, writer timeout/signal/expected errno 분류,
writer hang/조기 실패, terminal owner/active/thread/module 불변식, follow-new warning을 검사한다.
marker는 shell에서 가능한 syscall-attempt 직전 경계일 뿐 실제 in-kernel overlap 증거가 아니다.
`WIFI_STATUS_OK`가 실패 뒤 오게시되지 않았는지와 structured suspend/restore log의 정확한 phase
상관관계는 별도 target log/trace 검토 항목이며, 이 스크립트가 자동 증명하거나 PASS로 주장하지 않는다.

### T-15b — QA-only target/rollback fault injection

표준 산출물은 `CONFIG_BRIDGE_SWITCH_FAULT_INJECT=n`이다. static gate는 parameter, mask variable,
`xchg()` 및 두 injected branch가 모두 compile guard 안에 있는지와 host standard artifact의 symbol 부재를
검사한다. guard failure 또는 stale artifact provenance는 source acceptance를 막거나 unverified로 기록한다.
격리된 QA 산출물만 다음처럼 빌드한다. 이 산출물을 production에 배포하지 않는다.

```bash
make CONFIG_BRIDGE_SWITCH_FAULT_INJECT=y
# 평소와 같은 보드별 packaging/load 후 두 STA를 associate한다.
QA_CASE=fault-target QA_EVIDENCE_DIR=/tmp/bridge-qa.fault-target \
  ./scripts/tests/bridge_runtime_switch_qa.sh
QA_CASE=fault-double QA_EVIDENCE_DIR=/tmp/bridge-qa.fault-double \
  ./scripts/tests/bridge_runtime_switch_qa.sh
```

QA-only root-writable `bridge_switch_fault_mask`는 validation/same-target 검사 뒤, teardown 직전에
`xchg(..., 0)`으로 한 번만 소비된다. bit 0은 target init `ENOMEM`, bit 1은 rollback init
`ENOMEM`을 합성한다. `fault-target`은 원 owner 복구, `switch_fail+1`, `rollback_ok+1`, 다음 정상
전환 성공을 확인한다. `fault-double`은 `EIO`, effective owner `none`, inactive stats의
`rollback_fail+1`을 확인한다. double failure 뒤에는 active owner가 없어 runtime write로 복구할
수 없으므로 module reload로 configured policy를 다시 적용한다.

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
