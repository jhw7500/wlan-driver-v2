#!/bin/bash
# monitor_interrupts.sh - mmc2(WLAN SDIO) + eth0 인터럽트 모니터링
#
# 사용법: ./monitor_interrupts.sh [간격(초)]
#   기본: 1초 간격, Ctrl+C로 종료
#
# iMX93 eth0 IRQ 구분:
#   eth0_data (GICv3 216) - RX/TX 데이터 처리
#   eth0_err  (GICv3 215) - 에러/이벤트

INTERVAL="${1:-1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

NUM_CPUS=$(head -1 /proc/interrupts | wc -w)

# 이름 매칭되는 N번째 라인의 CPU 합산 (1-based)
get_irq_nth() {
    local name="$1"
    local nth="$2"
    grep -w "$name" /proc/interrupts 2>/dev/null | sed -n "${nth}p" | awk -v ncpu="$NUM_CPUS" '{
        sum = 0
        for (i = 2; i <= ncpu + 1; i++) sum += $i
        print sum
    }'
}

get_irq_total() {
    local name="$1"
    grep -w "$name" /proc/interrupts 2>/dev/null | awk -v ncpu="$NUM_CPUS" '{
        for (i = 2; i <= ncpu + 1; i++) sum += $i
    } END { print sum+0 }'
}

# eth0 라인 수 확인
ETH0_LINES=$(grep -cw "eth0" /proc/interrupts 2>/dev/null || echo 0)

# 초기 스냅샷
START_MMC2=$(get_irq_total "mmc2")
if [ "$ETH0_LINES" -ge 2 ]; then
    START_ETH0_DATA=$(get_irq_nth "eth0" 1)
    START_ETH0_ERR=$(get_irq_nth "eth0" 2)
else
    START_ETH0_DATA=$(get_irq_total "eth0")
    START_ETH0_ERR=0
fi
PREV_MMC2=$START_MMC2
PREV_ETH0_DATA=${START_ETH0_DATA:-0}
PREV_ETH0_ERR=${START_ETH0_ERR:-0}
START_TIME=$(date +%s)

if [ -z "$START_MMC2" ] || [ "$START_MMC2" = "0" ] && ! grep -qw "mmc2" /proc/interrupts 2>/dev/null; then
    echo "mmc2 인터럽트를 찾을 수 없습니다"
    exit 1
fi

echo -e "${BOLD}=== 인터럽트 모니터 (간격: ${INTERVAL}s) ===${RESET}"
echo -e "mmc2 시작값: ${START_MMC2}"
if [ "$ETH0_LINES" -ge 2 ]; then
    echo -e "eth0_data 시작값: ${START_ETH0_DATA}, eth0_err 시작값: ${START_ETH0_ERR}"
else
    echo -e "eth0 시작값: ${START_ETH0_DATA:-N/A}"
fi
echo ""

# 헤더
if [ "$ETH0_LINES" -ge 2 ]; then
    printf "${BOLD}%-10s │ %10s %7s %7s │ %10s %7s %7s │ %10s %7s${RESET}\n" \
        "시간" "mmc2" "d/s" "avg/s" "eth0_data" "d/s" "avg/s" "eth0_err" "d/s"
    echo "────────────┼──────────────────────────────┼──────────────────────────────┼────────────────────"
else
    printf "${BOLD}%-10s │ %10s %7s %7s │ %10s %7s %7s${RESET}\n" \
        "시간" "mmc2" "d/s" "avg/s" "eth0" "d/s" "avg/s"
    echo "────────────┼──────────────────────────────┼──────────────────────────────"
fi

while true; do
    sleep "$INTERVAL"

    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    TIMESTAMP=$(date '+%H:%M:%S')

    CUR_MMC2=$(get_irq_total "mmc2")
    if [ "$ETH0_LINES" -ge 2 ]; then
        CUR_ETH0_DATA=$(get_irq_nth "eth0" 1)
        CUR_ETH0_ERR=$(get_irq_nth "eth0" 2)
    else
        CUR_ETH0_DATA=$(get_irq_total "eth0")
        CUR_ETH0_ERR=0
    fi

    # delta
    D_MMC2=$((CUR_MMC2 - PREV_MMC2))
    D_ETH0_DATA=$((${CUR_ETH0_DATA:-0} - PREV_ETH0_DATA))
    D_ETH0_ERR=$((${CUR_ETH0_ERR:-0} - PREV_ETH0_ERR))

    # 평균 (시작 대비)
    T_MMC2=$((CUR_MMC2 - START_MMC2))
    T_ETH0_DATA=$((${CUR_ETH0_DATA:-0} - ${START_ETH0_DATA:-0}))

    if [ "$ELAPSED" -gt 0 ]; then
        AVG_MMC2=$((T_MMC2 / ELAPSED))
        AVG_ETH0_DATA=$((T_ETH0_DATA / ELAPSED))
    else
        AVG_MMC2=0
        AVG_ETH0_DATA=0
    fi

    # 에러 강조
    ERR_COLOR=""
    ERR_RESET=""
    if [ "$D_ETH0_ERR" -gt 0 ]; then
        ERR_COLOR="$RED"
        ERR_RESET="$RESET"
    fi

    # 출력
    if [ "$ETH0_LINES" -ge 2 ]; then
        printf "%-10s │ %10d ${YELLOW}%+6d${RESET} %7d │ %10d %+6d %7d │ ${ERR_COLOR}%10d %+6d${ERR_RESET}\n" \
            "$TIMESTAMP" "$CUR_MMC2" "$D_MMC2" "$AVG_MMC2" \
            "${CUR_ETH0_DATA:-0}" "$D_ETH0_DATA" "$AVG_ETH0_DATA" \
            "${CUR_ETH0_ERR:-0}" "$D_ETH0_ERR"
    else
        printf "%-10s │ %10d ${YELLOW}%+6d${RESET} %7d │ %10d %+6d %7d\n" \
            "$TIMESTAMP" "$CUR_MMC2" "$D_MMC2" "$AVG_MMC2" \
            "${CUR_ETH0_DATA:-0}" "$D_ETH0_DATA" "$AVG_ETH0_DATA"
    fi

    PREV_MMC2=$CUR_MMC2
    PREV_ETH0_DATA=${CUR_ETH0_DATA:-0}
    PREV_ETH0_ERR=${CUR_ETH0_ERR:-0}
done
