#!/bin/sh
# moal mlan0 RX ~90ms jitter — leg attribution via ftrace function_graph.
# Fallback for boards without bpftrace. Shows WHICH thread ran each stage
# (funcgraph-proc) and absolute time (funcgraph-abstime) so you can measure the
# cross-thread gap between the pull enqueue and the deliver dispatch.
#
# Usage (on the DUT):
#   sh docs/moal-mlan0-rx-jitter.legtrace.sh start   # then peer runs: ping -D -i 0.1 <DUT>
#   ... let ~30s of flood run ...
#   sh docs/moal-mlan0-rx-jitter.legtrace.sh stop    # writes /tmp/rx-fg.txt
#
# Read /tmp/rx-fg.txt:
#   * DURATION on wlan_sdio_card_to_host_mp_aggr / wlan_process_sdio_int_status
#       ~= 90ms                        -> PULL DMA jitter (leg 1, bus). RT won't help.
#   * pull funcs fast (tens of us) but ABSTIME gap between mlan_queue_rx_work
#       (proc=ksdioirqd/irq-mmc) and the next woal_netdev_poll_rx / woal_rx_work_queue
#       (proc=ksoftirqd/kworker) ~= 90ms -> DELIVER queue->run jitter (leg 2).
#   * OOB mode only: gap between oob_sdio_irq and woal_sdio_oob_irq_work
#       ~= 90ms                        -> worker dispatch latency before pull (leg 1 sched).
#
# Tip: to capture ONLY the slow outliers, uncomment the tracing_thresh line
#      (records only function_graph calls slower than 50ms).

set -e
TR=/sys/kernel/tracing
[ -d "$TR" ] || TR=/sys/kernel/debug/tracing
[ -d "$TR" ] || { echo "tracefs not found"; exit 1; }

FUNCS="woal_sdio_interrupt mlan_interrupt mlan_main_process \
wlan_process_sdio_int_status wlan_sdio_card_to_host wlan_sdio_card_to_host_mp_aggr \
mlan_queue_rx_work woal_queue_rx_task woal_netdev_poll_rx woal_rx_work_queue mlan_rx_process \
oob_sdio_irq woal_sdio_oob_irq_work"

case "$1" in
start)
	echo 0 > "$TR/tracing_on"
	: > "$TR/trace"
	echo 20000 > "$TR/buffer_size_kb"
	echo function_graph > "$TR/current_tracer"
	echo funcgraph-abstime > "$TR/trace_options"
	echo funcgraph-proc    > "$TR/trace_options"
	: > "$TR/set_ftrace_filter"
	for f in $FUNCS; do echo "$f" >> "$TR/set_ftrace_filter" 2>/dev/null || true; done
	# correlate with ICMP arrival in the same buffer:
	echo 1 > "$TR/events/net/netif_receive_skb/enable" 2>/dev/null || true
	# echo 50000 > "$TR/tracing_thresh"   # us; keep only >50ms calls (isolate the 90ms tail)
	echo 1 > "$TR/tracing_on"
	echo "tracing started. Run the ping flood now, then: $0 stop"
	;;
stop)
	echo 0 > "$TR/tracing_on"
	cp "$TR/trace" /tmp/rx-fg.txt
	echo 0 > "$TR/tracing_thresh" 2>/dev/null || true
	echo nop > "$TR/current_tracer"
	: > "$TR/set_ftrace_filter"
	echo 0 > "$TR/events/net/netif_receive_skb/enable" 2>/dev/null || true
	echo "wrote /tmp/rx-fg.txt  (grep for the slow DURATION rows / abstime gaps)"
	;;
*)
	echo "usage: $0 {start|stop}"; exit 1;;
esac
