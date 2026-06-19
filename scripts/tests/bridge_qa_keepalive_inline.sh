#!/bin/bash
# ----------------------------------------------------------------------------
# 실기 QA — adaptive keepalive (bridge_keepalive_idle_ms) 검증.
#
# 대상 (기본 OFF, 기존 free-running 동작 보존):
#   bridge_keepalive_idle_ms > 0 → keepalive hrtimer가 idle_ms 무트래픽 후
#   자가 정지(HRTIMER_NORESTART), eth/wlan 인터럽트(rx_handler/rx_fast/pt_func)가
#   패킷마다 moal_bridge_ka_kick()으로 재arm → 진짜 idle 시 wakeup 0회.
#   (※ bridge_keepalive_idle_ms 는 load 시 적용 — 변경하려면 모듈 reload.)
#
# 실행 위치: 타겟(iMX93)에서 실행. p2w 방향 측정은 유선 WAN 호스트 필요(안내만).
#
# 안전: 기본은 비파괴(스모크 + idle A/B)만. 파괴/부하(traffic 중 rmmod,
#       100x insmod/rmmod)는 RUN_STRESS=1 ./bridge_qa_keepalive_inline.sh
# ----------------------------------------------------------------------------
set -u

# ---- 환경 (필요시 export 로 덮어쓰기) --------------------------------------
MOAL_KO="${MOAL_KO:-/lib/modules/$(uname -r)/extra/moal_imx93.ko}"
MLAN_KO="${MLAN_KO:-/lib/modules/$(uname -r)/extra/mlan_imx93.ko}"
PEER_IF="${PEER_IF:-eth0}"
WLAN_IF="${WLAN_IF:-mlan0}"
WAN_HOST="${WAN_HOST:-192.168.1.100}"     # 유선측 호스트
KA_IDLE_MS="${KA_IDLE_MS:-20}"            # 적응형 idle 컷오프
LOG="${LOG:-/tmp/bridge_qa_keepalive.log}"
RUN_STRESS="${RUN_STRESS:-0}"
: > "$LOG"
# 실패 누적기. set -e 는 의도적 실패(미로드 시 rmmod 등)가 많아 조기 종료를
# 유발하므로 미사용 — 대신 실질 실패만 RC=1 로 모아 마지막에 exit $RC (CI 비0 종료).
RC=0
LAST_DELTA=0

say()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
hr()   { echo "----------------------------------------------------------------" | tee -a "$LOG"; }
load() {
  insmod "$MLAN_KO" 2>/dev/null
  if ! insmod "$MOAL_KO" "$@"; then
    say "!! insmod MOAL_KO failed (args: $*) — 후속 검사 신뢰 불가"
    RC=1
    return 1
  fi
  sleep 2
}
unload(){ rmmod moal 2>/dev/null; rmmod mlan 2>/dev/null; sleep 1; }
params(){ for p in bridge_keepalive_ms bridge_keepalive_idle_ms bridge_mode; do
            v=$(cat /sys/module/moal/parameters/$p 2>/dev/null); echo "    $p=$v"; done | tee -a "$LOG"; }
# 실제 커널 oops/warn 마커만 매칭 (bare 'WARN' 은 드라이버 MWARN 로그까지 잡아 false-positive)
panic_check(){ if dmesg | grep -Eq 'kernel panic|BUG:|WARNING:|WARN_ON|general protection|[Nn]ull pointer deref|use-after-free|KASAN'; then \
                 say "!! PANIC/BUG SIGNATURE FOUND"; RC=1; else say "panic_check: clean"; fi; }
# 누적 타이머 IRQ 카운트 (빈 결과는 0 으로 안전 대체)
timer_irq_total(){
  local s
  s=$(grep -iE 'arch_timer|Local timer' /proc/interrupts \
        | awk '{for(i=2;i<=NF;i++)if($i ~ /^[0-9]+$/)s+=$i}END{print s}')
  echo "${s:-0}"
}

say "MOAL_KO=$MOAL_KO  PEER=$PEER_IF  WLAN=$WLAN_IF  KA_IDLE_MS=$KA_IDLE_MS  RUN_STRESS=$RUN_STRESS"
hr

# ===========================================================================
# T-A  스모크: legacy vs adaptive 로드/언로드 + 파라미터/패닉 확인
# ===========================================================================
say "T-A1  legacy (idle=0) — 기존 free-running 동작"
unload; load bridge_mode=1 bridge_peer=$PEER_IF bridge_debug=1
dmesg | tail -15 | grep -iE "keepalive|Activated" | tee -a "$LOG"
params; panic_check; unload

say "T-A2  adaptive (idle=$KA_IDLE_MS)"
unload; load bridge_mode=1 bridge_peer=$PEER_IF bridge_debug=1 bridge_keepalive_idle_ms=$KA_IDLE_MS
dmesg | tail -15 | grep -iE "keepalive.*adaptive|Activated" | tee -a "$LOG"
params; panic_check; unload
hr

# ===========================================================================
# T-B  idle wakeup 절감 A/B — 무트래픽 30초 timer IRQ 증가량 비교
#      (eth/wlan 트래픽 끊은 상태에서 실행)
# ===========================================================================
measure_idle_timer(){  # $1=label
  local b a
  b=$(timer_irq_total)
  sleep 30
  a=$(timer_irq_total)
  LAST_DELTA=$((a-b))
  say "  [$1] 30s idle timer-IRQ delta = $LAST_DELTA"
}
say "T-B  idle wakeup A/B (무트래픽 30초)"
say "  (주의: timer-IRQ delta는 시스템 전체값 — busy 보드면 타 IRQ가 섞여 신호를 가릴 수 있음. 정밀 측정은 /proc/timer_list 의 bridge cpu_base hrtimer 권장)"
unload; load bridge_mode=1 bridge_peer=$PEER_IF bridge_keepalive_ms=1 bridge_keepalive_idle_ms=0
measure_idle_timer "idle=0 (free-running)"; FR=$LAST_DELTA
unload; load bridge_mode=1 bridge_peer=$PEER_IF bridge_keepalive_ms=1 bridge_keepalive_idle_ms=$KA_IDLE_MS
measure_idle_timer "idle=$KA_IDLE_MS (adaptive)"; AD=$LAST_DELTA
if [ "${AD:-0}" -lt "${FR:-0}" ]; then
  say "  T-B PASS: adaptive($AD) < free-running($FR) — idle wakeup 절감 확인"
else
  say "  T-B WARN: adaptive($AD) !< free-running($FR) — 절감 미확인 (timer-IRQ는 시스템 전체값이라 busy 보드서 노이즈 가능; RC 미반영)"
fi
unload
hr

# ===========================================================================
# T-C  활성 트래픽 중 latency 무회귀 확인 (adaptive 가 버스트 중엔 동일해야)
#      타겟 originate w2p ping
# ===========================================================================
say "T-C  active-traffic latency (adaptive, mlan→eth ping)"
load bridge_mode=1 bridge_peer=$PEER_IF bridge_keepalive_idle_ms=$KA_IDLE_MS
if ping -c1 -W1 -I "$WLAN_IF" "$WAN_HOST" >/dev/null 2>&1; then
  ping -c 50 -i 0.05 -I "$WLAN_IF" "$WAN_HOST" 2>/dev/null | tail -3 | tee -a "$LOG"
else
  say "  T-C SKIP: $WAN_HOST 가 $WLAN_IF 로 도달 불가"
fi
[ -r /sys/kernel/moal_bridge/stats ] && { say "bridge stats:"; cat /sys/kernel/moal_bridge/stats | tee -a "$LOG"; }
panic_check; unload
hr

# ===========================================================================
# T-D  (수동) cold-start 첫 패킷 latency — 유선 WAN 호스트에서
# ===========================================================================
cat <<EOF | tee -a "$LOG"
[T-D 수동] adaptive 가 idle 후 첫 패킷에 cold-start 1회 비용을 내는지 유선 WAN($WAN_HOST)에서:
  # idle=0 (free-running) vs idle=$KA_IDLE_MS (adaptive) 로 타겟 로드 후, WAN 호스트에서:
  ping -c 30 -i 2 <wireless_client>    # 2초 간격=매번 cold. max/avg 비교
  # 기대: adaptive 는 idle 동안 wakeup 0 (전력↓) 이지만 idle 후 첫 패킷 max 가
  #       free-running 대비 소폭↑(cold-start 1회). 버스트 중(T-C)은 동일.
EOF
hr

# ===========================================================================
# T-E  (파괴/부하) — RUN_STRESS=1
# ===========================================================================
if [ "$RUN_STRESS" = "1" ]; then
  say "T-E1  S-05: traffic 중 rmmod (adaptive) — UAF/hang 감시 (deinit 2차 cancel)"
  load bridge_mode=1 bridge_peer=$PEER_IF bridge_keepalive_idle_ms=$KA_IDLE_MS
  ping -f "$WAN_HOST" >/dev/null 2>&1 & PINGPID=$!
  sleep 3; rmmod moal 2>&1 | tee -a "$LOG"; kill "$PINGPID" 2>/dev/null
  rmmod mlan 2>/dev/null; sleep 1; panic_check

  say "T-E2  T-09: 50x insmod/rmmod 스트레스 (adaptive)"
  for i in $(seq 1 50); do
    load bridge_mode=1 bridge_peer=$PEER_IF bridge_keepalive_idle_ms=$KA_IDLE_MS
    unload
    [ $((i % 10)) -eq 0 ] && say "  ...$i/50"
  done
  panic_check
  lsmod | grep -q '^moal' && say "T-E2 FAIL (moal 잔존)" || say "T-E2 OK (clean unload)"
else
  say "T-E (stress) SKIPPED — RUN_STRESS=1 로 재실행"
fi
hr
say "QA 완료 (RC=$RC). 로그: $LOG"
exit $RC
