/** @file moal_bridge.c
 *
 * @brief L2 bridge between WLAN and peer (eth) interface
 *
 * Design Ref: §4-6 — Packet Flow, Filter Logic, Lifecycle
 * Plan SC: SC-01 (양방향 포워딩), SC-02 (자기 IP 처리), SC-03 (VLAN)
 *
 * Copyright 2026
 */

#include "moal_main.h"
#include "moal_bridge.h"
#include <linux/ktime.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/freezer.h>

/** DBDC guard: only one bridge instance allowed globally */
static atomic_t bridge_instance_active = ATOMIC_INIT(0);

/** bridge_debug: runtime-changeable via /sys/module/moal/parameters/bridge_debug */
extern int bridge_debug;
extern int bridge_consume_link_local;
/** bridge_keepalive_ms: module param default copied into handle->params at init */
extern int bridge_keepalive_ms;
#define BR_DBG(fmt, ...) do { \
	if (bridge_debug) \
		printk(KERN_INFO "bridge: " fmt, ##__VA_ARGS__); \
} while (0)

/* Forward declarations for helpers used by the w2p/p2w kthreads before
 * their definitions appear later in the file. */
static inline bool moal_bridge_dev_ready(const struct net_device *dev);

/*
 * ---------- Keepalive Timer ----------
 *
 * wifi-wbridge(pcap)가 빠른 이유: 지속적 eth0→mlan0 TX가 드라이버의
 * main_work(SDIO TX/RX 처리 루프)를 항상 active 상태로 유지.
 * 커널 브릿지의 비동기 포워딩은 미세한 gap이 있어 main_work가 sleep.
 * handle->params.bridge_keepalive_ms 주기 hrtimer로 main_work를 깨움.
 * 0=off, 1+=interval ms. config 파일의 값(있으면)을 우선 적용하고,
 * 그렇지 않으면 모듈 파라미터 기본값을 init 시 handle->params로 복사.
 */

static enum hrtimer_restart moal_bridge_keepalive(struct hrtimer *timer)
{
	struct moal_bridge *br = container_of(timer, struct moal_bridge,
				      keepalive_timer);
	moal_handle *handle = (moal_handle *)br->handle;
	ktime_t interval;
	int keepalive_ms, idle_ms;

	if (atomic_read(&br->active) && handle->workqueue)
		queue_work(handle->workqueue, &handle->main_work);

	keepalive_ms = handle->params.bridge_keepalive_ms;
	if (keepalive_ms <= 0)
		return HRTIMER_NORESTART;

	interval = ns_to_ktime((u64)keepalive_ms * NSEC_PER_MSEC);

	/* Adaptive mode: after idle_ms of no forwarded traffic, self-disarm so
	 * a truly idle link burns zero wakeups. Producers re-arm on the next
	 * packet via moal_bridge_ka_kick(). idle_ms<=0 keeps the legacy
	 * free-running behaviour (timer never stops on its own). */
	idle_ms = handle->params.bridge_keepalive_idle_ms;
	if (idle_ms > 0) {
		s64 cutoff_us = (s64)idle_ms * 1000;
		s64 idle_us = ktime_to_us(
			ktime_sub(ktime_get(), READ_ONCE(br->ka_last_fwd)));

		if (idle_us >= cutoff_us) {
			/* Tentatively disarm, then re-check: a producer may have
			 * forwarded a packet between our idle read and here. */
			atomic_set(&br->ka_armed, 0);
			/* Full barrier: order the clear before the re-read,
			 * pairing with the producer's WRITE_ONCE(ka_last_fwd)
			 * (which its cmpxchg orders before the arm). Without it
			 * the load could float above the clear and miss a
			 * concurrent arm. */
			smp_mb();
			idle_us = ktime_to_us(ktime_sub(
				ktime_get(), READ_ONCE(br->ka_last_fwd)));
			if (idle_us < cutoff_us) {
				/* A producer forwarded during our disarm window.
				 * Reclaim so exactly one party re-arms:
				 *   win  -> no producer has started the timer (it
				 *           is not enqueued); we own it: forward the
				 *           expiry and RESTART.
				 *   lose -> a producer won cmpxchg(0->1) and will
				 *           call hrtimer_start (its next step), so it
				 *           owns the re-arm at the correct expiry:
				 *           return NORESTART. NORESTART does NOT drop
				 *           the producer's (possibly concurrent)
				 *           enqueue — __run_hrtimer only re-enqueues
				 *           on RESTART, it never removes — and
				 *           armed==1 here always has a producer
				 *           arming, so the timer is never stranded.
				 *           (A bare RESTART would instead risk
				 *           re-enqueuing at the stale past expiry ->
				 *           one spurious immediate fire.) */
				if (atomic_cmpxchg(&br->ka_armed, 0, 1) == 0)
					hrtimer_forward_now(timer, interval);
				else
					return HRTIMER_NORESTART;
				return HRTIMER_RESTART;
			}
			/* Confirmed idle: ka_armed left 0 — the next forwarded
			 * packet re-arms via moal_bridge_ka_kick(). */
			return HRTIMER_NORESTART;
		}
	}

	hrtimer_forward_now(timer, interval);
	return HRTIMER_RESTART;
}

/*
 * moal_bridge_ka_kick - arm the adaptive keepalive on forwarded traffic.
 *
 * Called from the rx/forward enqueue paths (rx_handler / rx_fast in softirq,
 * packet_type fallback). Publishes the last-forward timestamp BEFORE the
 * cmpxchg so the timer's disarm path (clear ka_armed -> re-read timestamp)
 * can never stop the timer while traffic is live, then starts the timer if it
 * was disarmed. No-op outside adaptive mode (keepalive_ms>0 && idle_ms>0); in
 * legacy mode the timer free-runs and never needs re-arming.
 */
static inline void moal_bridge_ka_kick(struct moal_bridge *br)
{
	moal_handle *handle = (moal_handle *)br->handle;
	int keepalive_ms = handle->params.bridge_keepalive_ms;

	if (keepalive_ms <= 0 || handle->params.bridge_keepalive_idle_ms <= 0)
		return;

	/* Publish the timestamp BEFORE arming. In Linux, atomic_cmpxchg is fully
	 * ordered (x86 LOCK; arm64 casal / ldxr-stlxr), so the ka_last_fwd store
	 * is globally visible before any CPU observes ka_armed==1 — the timer's
	 * disarm re-read (after its own smp_mb) therefore cannot miss it. Do NOT
	 * weaken this cmpxchg to a bare atomic_set(). */
	WRITE_ONCE(br->ka_last_fwd, ktime_get());
	/* Steady-state fast path: once armed, skip the bus-locked cmpxchg via a
	 * plain atomic_read — saves a locked op on every packet of a burst. The
	 * short-circuit only triggers when armed==1 (timer running, no disarm
	 * pending); the correctness-critical disarm window always has armed==0
	 * (timer just cleared it), so the producer still takes the fully-ordered
	 * cmpxchg there and the ka_last_fwd publish stays correctly ordered. */
	if (atomic_read(&br->ka_armed) == 0 &&
	    atomic_cmpxchg(&br->ka_armed, 0, 1) == 0) {
		ktime_t interval =
			ns_to_ktime((u64)keepalive_ms * NSEC_PER_MSEC);
		hrtimer_start(&br->keepalive_timer, interval, HRTIMER_MODE_REL);
	}
}

/*
 * Apply the scheduling policy for the bridge w2p/p2w kthreads.
 *
 * Bridge threads are latency-critical (pcap-equivalent SCHED_FIFO:50 is
 * the original target), so unlike moal_main.c's main_work/rx_work paths
 * this helper ignores SCHED_NORMAL/BATCH/IDLE requests from
 * wq_sched_policy and collapses them to the bridge's FIFO default.
 *
 * Honored combinations:
 *   - wq_sched_policy == SCHED_FIFO or SCHED_RR, with prio in [1, 99]
 *     → apply exactly via sched_setscheduler / sched_setattr_nocheck
 *   - anything else (including the (0, 0) unset default)
 *     → fall back to sched_set_fifo(current)
 *
 * Kernel version brackets match the existing moal_main.c pattern so the
 * bridge behaves identically across the supported kernels. Kernel
 * versions 5.8.19..5.13.19 fall back to sched_set_fifo because the
 * sched_attr / sched_setattr_nocheck API was still unstable there.
 */
static void moal_bridge_apply_sched(moal_handle *handle)
{
	int policy = handle->params.wq_sched_policy;
	int prio = handle->params.wq_sched_prio;
	bool honor = (policy == SCHED_FIFO || policy == SCHED_RR) &&
		     prio >= 1 && prio <= 99;

	if (!honor) {
		sched_set_fifo(current);
		return;
	}

#if LINUX_VERSION_CODE > KERNEL_VERSION(2, 6, 10) &&                           \
	LINUX_VERSION_CODE <= KERNEL_VERSION(5, 8, 18)
	{
		struct sched_param sp;
		int ret;

		sp.sched_priority = prio;
		ret = sched_setscheduler(current, policy, &sp);
		if (ret)
			pr_warn_once("bridge: sched_setscheduler(policy=%d, prio=%d) failed: %d — thread may run at default priority\n",
				     policy, prio, ret);
	}
#elif LINUX_VERSION_CODE > KERNEL_VERSION(5, 13, 19)
	{
		/* Zero-init: __sched_setscheduler rejects unsupported sched_flags
		 * bits, so the fields not set below must not carry stack garbage. */
		struct sched_attr attr = {};
		int ret;

		attr.sched_policy = policy;
		attr.sched_nice = DEF_NICE;
		attr.sched_priority = prio;
		ret = sched_setattr_nocheck(current, &attr);
		if (ret)
			pr_warn_once("bridge: sched_setattr_nocheck(policy=%d, prio=%d) failed: %d — thread may run at default priority\n",
				     policy, prio, ret);
	}
#else
	sched_set_fifo(current);
#endif
}

/*
 * ---------- w2p Thread (WLAN→ETH, dedicated kthread) ----------
 */

/* ---------- In-driver one-way dwell instrumentation (bridge_debug) ----------
 *
 * Carries the producer-entry timestamp through the per-direction queue in
 * skb->cb so the drain kthread can measure the full in-driver dwell
 * (producer entry -> dev_queue_xmit submit, queue wait included) per
 * direction. This yields direction-split (W2P vs P2W) latency that an RTT
 * ping cannot isolate. Armed only while bridge_debug != 0; otherwise the
 * stamp is 0 and accounting is skipped (zero-overhead in production).
 */
struct moal_br_skb_cb {
	ktime_t enq_ts;
};

/* skb->cb is exclusively owned by the bridge between moal_bridge_stamp_enq()
 * (consume/enqueue point) and the drain kthread's read just before
 * dev_queue_xmit(). The forwarded skb sits on the bridge's private w2p/p2w
 * queue during that window, so no other layer (shim cb memset, qdisc, egress
 * driver cb use) intersects until after enq_ts is copied to a local. */
#define MOAL_BR_SKB_CB(skb) ((struct moal_br_skb_cb *)(skb)->cb)

static inline void moal_bridge_stamp_enq(struct sk_buff *skb)
{
	MOAL_BR_SKB_CB(skb)->enq_ts =
		READ_ONCE(bridge_debug) ? ktime_get() : 0;
}

static void moal_bridge_account_dwell(struct moal_bridge_stats *st,
				      ktime_t enq_ts)
{
	long us, old;

	if (!enq_ts)
		return;
	us = (long)ktime_to_us(ktime_sub(ktime_get(), enq_ts));
	if (us < 0)
		us = 0;
	atomic_long_inc(&st->dwell_cnt);
	atomic_long_add(us, &st->dwell_sum_us);
	old = atomic_long_read(&st->dwell_max_us);
	while (us > old) {
		long prev = atomic_long_cmpxchg(&st->dwell_max_us, old, us);

		if (prev == old)
			break;
		old = prev;
	}
}

static int moal_bridge_w2p_thread_fn(void *data)
{
	struct moal_bridge *br = data;
	struct sk_buff *skb;
	unsigned int len;
	int err;
	int cnt;
	ktime_t enq_ts;

	moal_bridge_apply_sched((moal_handle *)br->handle);
	/* F2: join freezer so PM suspend halts this kthread cleanly instead of
	 * blocking on SDIO I/O during system sleep. wait_event_freezable will
	 * handle the freezer_do_not_count/freezer_count transitions. */
	set_freezable();

	while (!kthread_should_stop()) {
		wait_event_freezable(br->w2p_wait,
			!skb_queue_empty(&br->w2p_queue) ||
			kthread_should_stop());

		if (kthread_should_stop())
			break;

		cnt = 0;
		while ((skb = skb_dequeue(&br->w2p_queue)) != NULL) {
			atomic_dec(&br->w2p_qlen);
			if (unlikely(!moal_bridge_dev_ready(br->peer_dev))) {
				atomic_long_inc(&br->wlan_to_peer.dropped);
				dev_kfree_skb_any(skb);
				cnt++;
				continue;
			}
			len = skb->len;
			enq_ts = MOAL_BR_SKB_CB(skb)->enq_ts;
			err = dev_queue_xmit(skb);
			if (unlikely(enq_ts))
				moal_bridge_account_dwell(&br->wlan_to_peer, enq_ts);
			if (net_xmit_eval(err)) {
				atomic_long_inc(&br->wlan_to_peer.errors);
			} else {
				atomic_long_inc(&br->wlan_to_peer.fwd_packets);
				atomic_long_add(len, &br->wlan_to_peer.fwd_bytes);
			}
			cnt++;
		}

		if (bridge_debug && cnt > 0) {
			printk(KERN_INFO "bridge: w2p_thread cpu=%d %d pkts\n",
			       smp_processor_id(), cnt);
		}
	}

	return 0;
}

/*
 * ---------- p2w Thread (ETH→WLAN, dedicated kthread) ----------
 *
 * pcap은 방향별 SCHED_FIFO 전용 스레드로 5.5ms 달성.
 * workqueue 공유 시 w2p work 실행 중 p2w 대기 + CFS 스케줄링 지연 → 31ms.
 * 전용 kthread로 분리하여 양방향 블로킹 제거 + wake-up 즉시 처리.
 */
static int moal_bridge_p2w_thread_fn(void *data)
{
	struct moal_bridge *br = data;
	struct sk_buff *skb;
	unsigned int len;
	int err;
	int cnt;
	ktime_t enq_ts;

	/* pcap과 동일: SCHED_FIFO:50으로 wake-up 즉시 실행.
	 * 이전 실패(local_bh_disable + 양방향 kthread) 조건 해소:
	 * - p2w 전용 (w2p 블로킹 없음)
	 * - 외부 local_bh_disable 없음 (dev_queue_xmit 내부만 단발성).
	 * 정책/우선순위는 wq_sched_policy/wq_sched_prio로 튜닝 가능;
	 * 기본값(0, 0) 또는 SCHED_FIFO/RR 외 값은 SCHED_FIFO로 폴백. */
	moal_bridge_apply_sched((moal_handle *)br->handle);
	/* F2: freezer join — same rationale as w2p_thread_fn. */
	set_freezable();

	while (!kthread_should_stop()) {
		wait_event_freezable(br->p2w_wait,
			!skb_queue_empty(&br->p2w_queue) ||
			kthread_should_stop());

		if (kthread_should_stop())
			break;

		cnt = 0;
		while ((skb = skb_dequeue(&br->p2w_queue)) != NULL) {
			atomic_dec(&br->p2w_qlen);
			if (unlikely(!moal_bridge_dev_ready(br->wlan_dev))) {
				atomic_long_inc(&br->peer_to_wlan.dropped);
				dev_kfree_skb_any(skb);
				cnt++;
				continue;
			}
			len = skb->len;
			enq_ts = MOAL_BR_SKB_CB(skb)->enq_ts;
			err = dev_queue_xmit(skb);
			if (unlikely(enq_ts))
				moal_bridge_account_dwell(&br->peer_to_wlan, enq_ts);
			if (net_xmit_eval(err)) {
				atomic_long_inc(&br->peer_to_wlan.errors);
			} else {
				atomic_long_inc(&br->peer_to_wlan.fwd_packets);
				atomic_long_add(len, &br->peer_to_wlan.fwd_bytes);
			}
			cnt++;
		}

		if (bridge_debug && cnt > 0) {
			printk(KERN_INFO "bridge: p2w_thread cpu=%d %d pkts\n",
			       smp_processor_id(), cnt);
		}
	}
	return 0;
}

/*
 * ---------- Helper: get IPv4 address from netdev ----------
 */

/** Design Ref: §6.1 — IPv4 주소 캐시 */
static __be32 moal_bridge_get_ipv4(struct net_device *dev)
{
	struct in_device *in_dev;
	__be32 addr = 0;

	rcu_read_lock();
	in_dev = __in_dev_get_rcu(dev);
	if (in_dev && in_dev->ifa_list)
		addr = in_dev->ifa_list->ifa_local;
	rcu_read_unlock();
	return addr;
}

/*
 * ---------- Filter Logic (from wbridge filter.c) ----------
 */

/**
 * moal_bridge_ensure_headroom - guarantee ETH_HLEN headroom for skb_push
 * The p2w forwarding path calls skb_push(skb, ETH_HLEN) after
 * eth_type_trans stripped the Ethernet header. Normally headroom is
 * sufficient, but fragmented / reallocated skbs from the peer side may
 * arrive with < ETH_HLEN headroom; skb_push would then underflow data.
 * Reallocate headroom (frees old skb, returns new) and bump oom_drops
 * if the atomic alloc fails.
 */
static inline struct sk_buff *moal_bridge_ensure_headroom(struct sk_buff *skb)
{
	struct sk_buff *nskb;

	if (likely(skb_headroom(skb) >= ETH_HLEN))
		return skb;
	nskb = skb_realloc_headroom(skb, ETH_HLEN);
	kfree_skb(skb);
	return nskb;
}

/**
 * moal_bridge_dev_ready - egress netdev is usable for forwarding
 * Combines admin-up (netif_running), link-up (netif_carrier_ok), and
 * still-registered (reg_state == NETREG_REGISTERED) checks into one gate.
 * Used at enqueue and again before dev_queue_xmit to avoid xmit'ing into
 * a device that went down between queue and drain.
 */
static inline bool moal_bridge_dev_ready(const struct net_device *dev)
{
	/* reg_state is an enum; READ_ONCE's __native_word check rejects it.
	 * Lifecycle changes are RTNL-serialized, so a plain read is fine. */
	if (!dev || !netif_running(dev) || !netif_carrier_ok(dev))
		return false;
	return dev->reg_state == NETREG_REGISTERED;
}

/**
 * moal_bridge_is_link_local - IEEE 802.1D bridge group address (link-local)
 * Destination MACs in 01:80:C2:00:00:00 .. 01:80:C2:00:00:0F must never be
 * forwarded across bridges (STP BPDU, LACP, 802.1X, LLDP, etc.). Forwarding
 * them between two L2 segments can form a topology loop or confuse STP.
 */
static inline bool moal_bridge_is_link_local(const u8 *dst)
{
	return dst[0] == 0x01 && dst[1] == 0x80 && dst[2] == 0xc2 &&
	       dst[3] == 0x00 && dst[4] == 0x00 && (dst[5] & 0xf0) == 0x00;
}

/**
 * moal_bridge_arp_is_for_self - ARP target IP가 자기 IP인지 확인
 * Design Ref: §5.2 — wbridge filter.c::filter_arp_is_for_bridge() 이식
 *
 * @note skb->data는 eth_type_trans 이후이므로 ETH_HLEN이 이미 pull됨.
 *       따라서 L2 payload는 skb->data부터 시작.
 */
static bool moal_bridge_arp_is_for_self(struct moal_bridge *br,
					struct sk_buff *skb,
					unsigned int l3_off)
{
	struct arphdr *arp;
	unsigned char *arp_ptr;
	__be32 target_ip;
	__be32 wlan_ip, peer_ip;

	if (!pskb_may_pull(skb, l3_off + sizeof(struct arphdr) + 20))
		return false;

	arp = (struct arphdr *)(skb->data + l3_off);
	if (arp->ar_hrd != htons(ARPHRD_ETHER) ||
	    arp->ar_pro != htons(ETH_P_IP) ||
	    arp->ar_hln != ETH_ALEN ||
	    arp->ar_pln != 4)
		return false;

	/* target IP offset: sender_mac(6) + sender_ip(4) + target_mac(6) = 16 */
	arp_ptr = (unsigned char *)(arp + 1);
	memcpy(&target_ip, arp_ptr + 16, 4);

	/* 박스 소유 IP는 wlan(mlan0)·peer(eth0) 양쪽 모두 보호.
	 * eth0-IP 토폴로지(IP를 eth0에 두는 배치) 정식 지원 — wbridge
	 * filter.c::filter_arp_is_for_bridge() 가 interfaces[] 전체를 검사하는
	 * 것과 동등. 한계(설계 파리티): 인터페이스당 캐시 1개라 eth0 가 다중
	 * IP(peer_route /32 미러 + 관리 IP)면 마지막 inetaddr 이벤트의 주소만
	 * 보호된다. */
	wlan_ip = READ_ONCE(br->wlan_ipv4);
	peer_ip = READ_ONCE(br->peer_ipv4);
	return (wlan_ip && target_ip == wlan_ip) ||
	       (peer_ip && target_ip == peer_ip);
}

/*
 * ---------- WLAN → ETH Forwarding ----------
 */

/**
 * moal_bridge_rx_fast - WLAN RX fast path (before eth_type_trans)
 *
 * Called from moal_recv_packet BEFORE eth_type_trans/EAPOL/stats processing.
 * skb->data = ETH header (L2), no skb_push needed for dev_queue_xmit.
 * This eliminates ~10 processing steps for bridged packets.
 *
 * @return 1 if consumed, 0 if caller should continue normal processing
 */
int moal_bridge_rx_fast(struct moal_bridge *br, struct sk_buff *skb, void *priv)
{
	struct ethhdr *eth;
	__be16 proto;
	unsigned int l3_off = ETH_HLEN;
	ktime_t t_start = 0;

	if (!br || !skb)
		return 0;

	/* Defensive early-out — NOT load-bearing for keepalive teardown safety
	 * (that is guaranteed by the synchronize_rcu drain + step-5b cancel in
	 * deinit). It mirrors the active check in the rx_handler / packet_type
	 * paths so all three ingress paths behave identically once deinit clears
	 * active, and skips needless ka_kick()/forwarding work during teardown.
	 * Safe to keep; removing it loses that consistency, not correctness. */
	if (!atomic_read(&br->active))
		return 0;

	if (bridge_debug)
		t_start = ktime_get();

	eth = (struct ethhdr *)skb->data;
	proto = eth->h_proto;

	/* media_connected check (READ_ONCE — disconnect race 방어) */
	if (!READ_ONCE(((moal_private *)br->wlan_priv)->media_connected))
		return 0;

	/* VLAN: extract inner proto (head must be linear through VLAN tag) */
	if (proto == htons(ETH_P_8021Q)) {
		if (!pskb_may_pull(skb, VLAN_ETH_HLEN))
			return 0;
		proto = ((struct vlan_hdr *)(skb->data + ETH_HLEN))->
			h_vlan_encapsulated_proto;
		l3_off = VLAN_ETH_HLEN;
	}

	/* EAPOL (raw or VLAN-tagged): never forward */
	if (proto == htons(ETH_P_PAE))
		return 0;

	/* IEEE 802.1D bridge group (link-local): never forward — STP/LACP/LLDP */
	if (moal_bridge_is_link_local(eth->h_dest)) {
		atomic_long_inc(&br->wlan_to_peer.dropped);
		/* [DBG-RXDROP] dst MAC + proto + len + consume toggle 상태 dump.
		 * ratelimited (default ~10 msg/5s) — LLDP 30s 주기는 모두 잡힘. */
		pr_info_ratelimited("[DBG-RXDROP] w2p link-local dst=%pM proto=0x%04x len=%u consume=%d\n",
				    eth->h_dest, ntohs(proto), skb->len,
				    bridge_consume_link_local);
		BR_DBG("w2p link-local drop dst=" MACSTR "\n",
		       MAC2STR(eth->h_dest));
		if (bridge_consume_link_local) {
			/* driver 내 명시적 폐기: kernel stack 으로 안 보내므로
			 * dev->rx_nohandler 자동 증가 path 차단 → mlan0_rx_dropped 0 */
			kfree_skb(skb);
			return 1;
		}
		return 0;
	}

	if (proto == htons(ETH_P_ARP) &&
	    moal_bridge_arp_is_for_self(br, skb, l3_off)) {
		BR_DBG("w2p SELF-ARP skip clone\n");
		return 0;
	}

	/* STA 모드: 모든 수신 패킷의 dst MAC = WLAN MAC (AP→STA 프레임 특성)
	 * → MAC 기반 자기/포워딩 구분 불가. IP로 판정:
	 *   - 박스 소유(wlan 또는 peer) IPv4 unicast: 스택만 처리 (return 0)
	 *   - non-self IPv4 unicast (wlan_ipv4 보유 시): consume (return 1)
	 *   - 나머지 (mcast, non-IPv4, wlan_ipv4==0 의 non-self, pull 실패):
	 *     clone + 스택 배달 (return 0)
	 * peer(eth0) IP 를 self 로 취급하는 목적은 "유선 누출 차단" — 공중발
	 * eth0-IP 패킷을 유선으로 흘리지 않는다 (wbridge filter_ip_is_local
	 * 파리티). 스택 배달까지는 하지만 무선→eth0-IP e2e 통신은 응답
	 * 라우팅(유선으로 misroute) + mlan rp_filter 제약으로 미지원 —
	 * eth0-IP 토폴로지의 지원 대상은 유선(P2W) 측 통신이다.
	 * non-self consume fast path 는 wlan_ipv4 보유 시에만: wlan_ipv4==0
	 * 과도기(assoc 후 주소 적용 전)나 브릿지 인터페이스가 DHCP 취득 중인
	 * 변형(mlan1 DHCP=yes)에서 unicast DHCPOFFER/ACK 등 스택행 트래픽이
	 * 유선으로 새는 것을 막고 tcpdump 가시성을 보존한다 (기존 동작 유지). */
	if (proto == htons(ETH_P_IP) &&
	    !is_multicast_ether_addr(eth->h_dest)) {
		__be32 wlan_ip = READ_ONCE(br->wlan_ipv4);
		__be32 peer_ip = READ_ONCE(br->peer_ipv4);

		if ((wlan_ip || peer_ip) &&
		    pskb_may_pull(skb, l3_off + sizeof(struct iphdr))) {
			struct iphdr *iph = (struct iphdr *)(skb->data + l3_off);

			if ((wlan_ip && iph->daddr == wlan_ip) ||
			    (peer_ip && iph->daddr == peer_ip)) {
				BR_DBG("w2p SELF-IP skip clone dip=%pI4\n",
				       &iph->daddr);
				return 0;
			}
			if (wlan_ip) {
				/* Non-self unicast IPv4 → consume original
				 * (no clone, no stack) */
				if (unlikely(!moal_bridge_dev_ready(
					    br->peer_dev))) {
					atomic_long_inc(
						&br->wlan_to_peer.dropped);
					kfree_skb(skb);
					return 1;
				}
				if (atomic_inc_return(&br->w2p_qlen) >
				    MOAL_BR_W2P_QUEUE_MAX) {
					atomic_dec(&br->w2p_qlen);
					atomic_long_inc(
						&br->wlan_to_peer.dropped);
					kfree_skb(skb);
					return 1; /* consumed: dropped */
				}
				skb->dev = br->peer_dev;
				moal_bridge_stamp_enq(skb);
				skb_queue_tail(&br->w2p_queue, skb);
				wake_up(&br->w2p_wait);
				moal_bridge_ka_kick(br);
				return 1; /* consumed: forwarded */
			}
			/* wlan_ipv4==0: non-self 는 기존 clone+pass 경로로 */
		}
		/* 박스 IP 캐시 모두 0 or iph pull failed → fall through to clone+pass */
	}

	/* Multicast/Broadcast, 비IPv4 유니캐스트, 또는 iph pull 실패 →
	 * clone + 원본 스택 배달 */
	if (unlikely(!moal_bridge_dev_ready(br->peer_dev))) {
		atomic_long_inc(&br->wlan_to_peer.dropped);
	} else {
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
		if (skb2) {
			if (atomic_inc_return(&br->w2p_qlen) >
			    MOAL_BR_W2P_QUEUE_MAX) {
				atomic_dec(&br->w2p_qlen);
				atomic_long_inc(&br->wlan_to_peer.dropped);
				dev_kfree_skb_any(skb2);
				return 0;
			}
			skb2->dev = br->peer_dev;
			moal_bridge_stamp_enq(skb2);
			skb_queue_tail(&br->w2p_queue, skb2);
			wake_up(&br->w2p_wait);
			moal_bridge_ka_kick(br);
		} else {
			atomic_long_inc(&br->wlan_to_peer.oom_drops);
		}
	}
	if (bridge_debug) {
		s64 dt_us = ktime_to_us(ktime_sub(ktime_get(), t_start));
		BR_DBG("w2p FWD cpu=%d %lldus qlen=%d proto=0x%04x len=%d\n",
		       smp_processor_id(), dt_us,
		       skb_queue_len(&br->w2p_queue),
		       ntohs(proto), skb->len);
	}
	return 0; /* 원본은 커널 스택으로 */
}

/*
 * ---------- Local hairpin: WLAN TX-side divert (bridge_local_hairpin=1) ----------
 *
 * 목적: BD(박스)↔유선 peer IP 통신을 peer IP 인지(peer_route host route /
 * ip_discovery) 없이 성립시킨다. 2026-07-16 실기 확정 근거:
 *   - host route 부재 시 BD발 응답은 main 라우트(wlan)로 향해 neigh 미해소로
 *     전멸 (iif rule/table 100 은 로컬 생성 응답을 조향하지 않음)
 *   - 현장 AP 는 intra-BSS 반사를 안 함 → 공중 hairpin 경로 부재
 *
 * 판정 안전성: MAC-clone 제약(수신 방향 MAC 판정 불가)은 수신 이야기고,
 * "로컬발 TX 에서 dst MAC == 자기(클론) MAC 인 유니캐스트"는 정의상 유선
 * peer 행이다 — 무선망에 이 MAC 을 가진 다른 장치가 없고, AP 가 할 수 있는
 * 것도 되반사뿐이다. 송신 방향의 이 지점만은 MAC 판정이 안전하다.
 */

/**
 * moal_bridge_tx_hairpin - 로컬발 TX 프레임을 유선 peer 로 로컬 hairpin
 *
 * woal_hard_start_xmit 초입에서 호출. caller 가 rcu_read_lock 보유,
 * bridge active + dev == wlan_dev 확인 후 진입.
 *
 * @return 1 = consumed (w2p divert 또는 정책 drop — caller 는 TX 완료 처리)
 *         0 = 통상 TX 계속 (ARP tee 는 clone 후 원본을 공중으로 보냄)
 */
int moal_bridge_tx_hairpin(struct moal_bridge *br, struct sk_buff *skb)
{
	struct ethhdr *eth;

	/* 스택발 프레임은 ETH 헤더가 항상 선형이지만 방어적으로 보장
	 * (pskb_may_pull 은 필요 시 head 를 선형화 — headlen 비교보다 안전) */
	if (unlikely(!pskb_may_pull(skb, ETH_HLEN)))
		return 0;
	eth = (struct ethhdr *)skb->data;

	/* A. 유니캐스트 divert: dst == 자기(클론) MAC → 공중 대신 w2p.
	 * 클론 MAC 은 br 캐시가 아닌 현재 dev_addr 로 비교 (재클론 대응).
	 * 큐 계약은 rx_fast consume 경로와 동일: skb->dev=peer_dev,
	 * data=ETH 헤더 상태로 인큐 → w2p kthread 가 dev_queue_xmit.
	 * GSO/CHECKSUM_PARTIAL 은 peer 쪽 validate_xmit_skb 가 처리. */
	if (!is_multicast_ether_addr(eth->h_dest)) {
		if (!ether_addr_equal(eth->h_dest, br->wlan_dev->dev_addr))
			return 0;
		if (unlikely(!moal_bridge_dev_ready(br->peer_dev))) {
			atomic_long_inc(&br->wlan_to_peer.dropped);
			dev_kfree_skb_any(skb);
			return 1;
		}
		if (atomic_inc_return(&br->w2p_qlen) > MOAL_BR_W2P_QUEUE_MAX) {
			atomic_dec(&br->w2p_qlen);
			atomic_long_inc(&br->wlan_to_peer.dropped);
			dev_kfree_skb_any(skb);
			return 1;
		}
		skb->dev = br->peer_dev;
		moal_bridge_stamp_enq(skb);
		atomic_long_inc(&br->hairpin_tx_fwd);
		BR_DBG("tx hairpin divert len=%d\n", skb->len);
		skb_queue_tail(&br->w2p_queue, skb);
		wake_up(&br->w2p_wait);
		return 1;
	}

	/* B. 로컬발 broadcast ARP tee: 박스의 who-has 가 유선 peer 에 직접
	 * 도달하도록 clone 을 w2p 로 보내고, 원본은 공중으로 계속(무선 피어
	 * ARP 유지). 대상 IP 로 유선/무선을 구분하지 않는 것이 의도 — peer
	 * IP 무지가 이 기능의 전제이고, 무관한 who-has 는 peer 가 무시한다
	 * (발생률 수 pps 미만). REPLY 유니캐스트는 A 가 커버한다. */
	if (eth->h_proto == htons(ETH_P_ARP) &&
	    is_broadcast_ether_addr(eth->h_dest) &&
	    moal_bridge_dev_ready(br->peer_dev)) {
		struct sk_buff *skb2;

		/* 플릿 안전 경고(부팅당 1회): hairpin 활성인데 wlan iface 의
		 * 실효 arp_ignore(max(all,dev))가 0 이면 wlan-package 의
		 * weak-host 봉인이 미적용된 상태 — 무선발 who-has <eth0-IP> 에
		 * 클론 MAC 으로 응답해 플릿(공통 관리IP+플랫 L2)에서 중복
		 * IP/DAI 제재를 부를 수 있다. 배포 커플링을 운영자가 인지하도록
		 * dmesg 로 알린다 (PR #10 리뷰 HIGH). ARP tee 경로에서만 검사
		 * — BD→peer 통신은 ARP 로 시작하므로 조기 발화하며 데이터
		 * 핫패스(A) 비용은 0. */
		{
			struct in_device *in_dev;

			rcu_read_lock();
			in_dev = __in_dev_get_rcu(br->wlan_dev);
			if (in_dev && !IN_DEV_ARP_IGNORE(in_dev) &&
			    !atomic_cmpxchg(&br->hairpin_seal_warned, 0, 1))
				PRINTM(MMSG,
				       "bridge: hairpin active but %s effective arp_ignore==0 — weak-host ARP open (fleet DAI risk); apply wlan-package per-interface seal\n",
				       br->wlan_dev->name);
			rcu_read_unlock();
		}
		/* skb_copy(사유 데이터 복사): clone 은 데이터를 공유하므로 아래
		 * src MAC 재작성이 공중으로 나갈 원본까지 오염시킨다. ARP 는
		 * 수십 바이트라 copy 비용 무시 가능. */
		skb2 = skb_copy(skb, GFP_ATOMIC);
		if (!skb2) {
			atomic_long_inc(&br->wlan_to_peer.oom_drops);
			return 0;
		}
		if (atomic_inc_return(&br->w2p_qlen) > MOAL_BR_W2P_QUEUE_MAX) {
			atomic_dec(&br->w2p_qlen);
			atomic_long_inc(&br->wlan_to_peer.dropped);
			dev_kfree_skb_any(skb2);
			return 0;
		}
		/* ethernet src 를 peer(eth0) MAC 으로 재작성: 클론 MAC 그대로면
		 * peer 입장에서 "src==자기 MAC" 프레임이라 스택/스위치
		 * anti-spoof drop 위험 (PR #10 리뷰 HIGH — Design §10 대비
		 * 설계의 선반영). ARP payload 의 SHA 는 클론 MAC 유지 — peer
		 * 응답이 dst=클론 MAC 으로 돌아와야 P2W REPLY inject 가 동작. */
		ether_addr_copy(((struct ethhdr *)skb2->data)->h_source,
				br->peer_dev->dev_addr);
		skb2->dev = br->peer_dev;
		moal_bridge_stamp_enq(skb2);
		atomic_long_inc(&br->hairpin_arp_tee);
		BR_DBG("tx hairpin ARP tee\n");
		skb_queue_tail(&br->w2p_queue, skb2);
		wake_up(&br->w2p_wait);
	}
	return 0;
}

/*
 * ---------- ETH → WLAN Forwarding (rx_handler) ----------
 */

/**
 * moal_bridge_peer_rx_handler - peer(eth0) RX 패킷을 WLAN으로 포워딩
 * Design Ref: §4.2 — ETH→WLAN 방향
 *
 * netdev_rx_handler_register()로 peer_dev에 등록되는 콜백.
 * __netif_receive_skb_core()에서 호출됨 (softirq context).
 *
 * Plan SC: SC-01 (ETH→WLAN 포워딩)
 */
static rx_handler_result_t
moal_bridge_peer_rx_handler(struct sk_buff **pskb)
{
	struct sk_buff *skb = *pskb;
	struct moal_bridge *br = rcu_dereference(skb->dev->rx_handler_data);
	struct ethhdr *eth;

	if (!br || !atomic_read(&br->active))
		return RX_HANDLER_PASS;

	eth = eth_hdr(skb);
	BR_DBG("p2w RX " MACSTR " -> " MACSTR " proto=0x%04x len=%d\n",
	       MAC2STR(eth->h_source), MAC2STR(eth->h_dest),
	       ntohs(skb->protocol), skb->len);

	/* NOTE: media_connected 게이트는 아래 "공중 포워딩" 직전으로 이동됨
	 * (G2 게이트 재배치) — SELF-ARP/SELF-IP 정정·inject 는 로컬 배달이라
	 * 무선 상태와 무관하게 동작해야 한다. */

	/* EAPOL: never forward. D8: VLAN-aware to match rx_fast(D7) policy —
	 * vlan_get_protocol unwraps outer 802.1Q/AD tag (hwaccel or in-band)
	 * so a VLAN-tagged EAPOL from peer_dev is also caught and passed to
	 * the kernel stack instead of being bridged to wlan. */
	if (vlan_get_protocol(skb) == htons(ETH_P_PAE))
		return RX_HANDLER_PASS;

	/* IEEE 802.1D bridge group (link-local): never forward — STP/LACP/LLDP */
	if (moal_bridge_is_link_local(eth->h_dest)) {
		atomic_long_inc(&br->peer_to_wlan.dropped);
		/* [DBG-RXDROP] dst MAC + proto + len dump (p2w 방향). */
		pr_info_ratelimited("[DBG-RXDROP] p2w link-local dst=%pM proto=0x%04x len=%u\n",
				    eth->h_dest, ntohs(skb->protocol),
				    skb->len);
		BR_DBG("p2w link-local drop dst=" MACSTR "\n",
		       MAC2STR(eth->h_dest));
		return RX_HANDLER_PASS;
	}

	/* 유니캐스트: peer(eth0) 자기 MAC → clone 불필요, 커널 스택만 처리
	 * (init에서 캐시된 br->peer_mac 사용 — peer_dev->dev_addr pointer chase 제거) */
	if (!is_multicast_ether_addr(eth->h_dest) &&
	    ether_addr_equal(eth->h_dest, br->peer_mac))
		return RX_HANDLER_PASS;

	/* ---- 자기(mlan0) 앞 트래픽: 장치 내부에서 로컬 처리 ----
	 *
	 * MAC-cloning bridge 에서는 mlan0(STA) MAC == eth0 유선 클라이언트 MAC
	 * 이므로 MAC 으로는 "박스 자신(mlan0)" 과 "유선 클라이언트" 를 구분할 수
	 * 없다. W2P 경로(rx_fast)의 SELF-IP/SELF-ARP 필터와 동일하게 L3 로
	 * 판정한다.
	 *
	 * skb->data 는 eth_type_trans 이후라 L3 시작점. in-band 802.1Q 태그가
	 * 남아있으면 VLAN_HLEN 만큼 뒤가 L3 (hwaccel 태그는 이미 분리됨).
	 * wlan_ipv4==0(mlan0 IP 미할당)이면 모든 검사 불발 → 기존 포워딩으로
	 * graceful fall-through (완전 투명 브릿지 동작 유지). */

	/* SELF-ARP REQUEST: target IP == 박스 소유 IP(mlan0 또는 eth0)인 ARP
	 * "요청" → 스택만 처리, 공중 포워딩 금지. 공중으로 포워딩하면 AP
	 * 반사를 거쳐 mlan0 스택이 클론 MAC(MAC_C)으로 한 번 더 응답(weak
	 * host model — 타깃 IP 가 eth0 소유여도 응답) → 정상 응답(MAC_E)과
	 * 이중 응답 레이스가 생겨 클라이언트 ARP 캐시가 MAC_E/MAC_C 사이를
	 * 오가며 간헐 단절된다. 레이스의 근원은 "요청"의 공중 유출이므로
	 * REQUEST 만 억제한다. (eth0-IP 토폴로지 정식 지원 — peer_ipv4 는
	 * arp_is_for_self 공유 판정에 포함됨)
	 *
	 * ARP "REPLY"(tip==mlan0 IP — 예: 박스가 mlan0 라우트로 보낸 who-has
	 * 에 대한 유선 클라이언트의 응답)는 억제하지 않는다: pending neigh 가
	 * (ip, dev=mlan0) 키로 만들어진 경우 arp_process 는 수신 dev 로만
	 * 조회하므로(net/ipv4/arp.c) eth0 로 PASS 해봐야 해소되지 않고,
	 * 기존 공중 hairpin(AP 반사 → mlan0 수신)이 유일한 해소 경로다.
	 * → REPLY 는 아래 비자기 유니캐스트 경로로 fall-through (기존 동작). */
	if (vlan_get_protocol(skb) == htons(ETH_P_ARP)) {
		unsigned int arp_off =
			(skb->protocol == htons(ETH_P_8021Q)) ? VLAN_HLEN : 0;

		/* arp_is_for_self == true 면 arphdr 까지 pull 보장됨 */
		if (moal_bridge_arp_is_for_self(br, skb, arp_off)) {
			struct arphdr *arp =
				(struct arphdr *)(skb->data + arp_off);

			if (arp->ar_op == htons(ARPOP_REQUEST)) {
				/* unicast re-ARP 가 클론 MAC 앞으로 오면 eth0
				 * 기준 OTHERHOST 마킹 상태 — arp_rcv 는
				 * OTHERHOST 를 폐기하므로 HOST 로 정정
				 * (broadcast ARP 는 PACKET_BROADCAST 그대로 둠) */
				if (skb->pkt_type == PACKET_OTHERHOST)
					skb->pkt_type = PACKET_HOST;
				BR_DBG("p2w SELF-ARP-REQ pass (no air fwd)\n");
				return RX_HANDLER_PASS;
			}

			/* C. local hairpin: REPLY(tip==자기 IP)를 공중 hairpin
			 * (위 REPLY fall-through 주석) 대신 wlan RX 로 직접
			 * 주입 → arp_process 가 (sip, dev=wlan) pending neigh
			 * 를 AP 반사 없이 해소. 주입 skb 는 수신 프레임 형태
			 * (data=L3, mac_header/protocol 유지) 그대로이므로
			 * dev/pkt_type 만 바꾼다. netif_rx 는 backlog 경유라
			 * 재귀 없음, wlan_dev 에는 rx_handler 미등록.
			 * untagged 만 — 태그드는 기존 공중 경로 유지. */
			if (READ_ONCE(bridge_local_hairpin) &&
			    /* untagged only — tagged 는 공중 경로 fallback */
			    skb->protocol == htons(ETH_P_ARP) &&
			    arp->ar_op == htons(ARPOP_REPLY)) {
				skb->dev = br->wlan_dev;
				skb->pkt_type = PACKET_HOST;
				atomic_long_inc(&br->hairpin_arp_inject);
				BR_DBG("p2w hairpin ARP-REPLY inject\n");
				/* 소유권 이전(netif_rx) 전에 caller 포인터 무효화
				 * — 커널 레퍼런스(vlan/bridge) 관례 */
				*pskb = NULL;
				netif_rx(skb);
				return RX_HANDLER_CONSUMED;
			}
			/* hairpin off/태그드 REPLY: 기존 공중 hairpin 경로로
			 * fall-through (비자기 유니캐스트 consume) */
		}
	}

	/* 위 SELF-ARP 검사의 pskb_may_pull 이 head 를 재할당했을 수 있으므로
	 * 아래 eth->h_dest 사용 전에 재취득 (mac_header offset 은 유지됨) */
	eth = eth_hdr(skb);

	/* SELF-IP unicast: dst IP == 박스 소유 IP(mlan0 또는 eth0) → 로컬
	 * 스택이 처리. 포워딩하면 자기에게 갈 패킷이 WiFi 로 hairpin 송출된다.
	 *
	 * pkt_type 정정 필수: dst MAC 이 클론 MAC(=mlan0 MAC)이면
	 * eth_type_trans 가 eth0 기준 PACKET_OTHERHOST 로 마킹했고,
	 * ip_rcv 는 OTHERHOST 를 무조건 폐기한다 (net/ipv4/ip_input.c).
	 * daddr == 자기 IP 가 확인된 패킷이므로 HOST 로 정정해야
	 * RX_HANDLER_PASS 가 실제 로컬 배달로 이어진다.
	 * (peer_ip 매치는 eth0 가 직접 소유한 IP 라 rp_filter strict 에서도
	 *  reverse path == eth0 으로 통과 — wlan_ip 매치만 loose 필요) */
	if (!is_multicast_ether_addr(eth->h_dest) &&
	    vlan_get_protocol(skb) == htons(ETH_P_IP)) {
		__be32 wlan_ip = READ_ONCE(br->wlan_ipv4);
		__be32 peer_ip = READ_ONCE(br->peer_ipv4);
		unsigned int l3_off =
			(skb->protocol == htons(ETH_P_8021Q)) ? VLAN_HLEN : 0;

		if ((wlan_ip || peer_ip) &&
		    pskb_may_pull(skb, l3_off + sizeof(struct iphdr))) {
			struct iphdr *iph =
				(struct iphdr *)(skb->data + l3_off);

			if ((wlan_ip && iph->daddr == wlan_ip) ||
			    (peer_ip && iph->daddr == peer_ip)) {
				if (skb->pkt_type == PACKET_OTHERHOST)
					skb->pkt_type = PACKET_HOST;
				BR_DBG("p2w SELF-IP pass dip=%pI4\n",
				       &iph->daddr);
				return RX_HANDLER_PASS;
			}
		}
	}

	/* media_connected 게이트 (READ_ONCE — disconnect race 방어): 본래
	 * 목적인 "공중 포워딩"(아래 consume/clone→p2w 큐) 직전에 배치 (G2
	 * 게이트 재배치, PR #10 후속). 위의 SELF-ARP/SELF-IP 정정과 REPLY
	 * inject 는 로컬 배달·주입이라 무선 down 중에도 동작해야 유선→BD
	 * 제어 채널이 생존한다 (dst=클론MAC 프레임의 OTHERHOST 폐기 방지 —
	 * DFK 무선단절 시 유선 VHL 요구). */
	if (!READ_ONCE(((moal_private *)br->wlan_priv)->media_connected))
		return RX_HANDLER_PASS;

	/* 위 SELF 검사들의 pskb_may_pull 이 head 를 재할당했을 수 있으므로
	 * eth 포인터 재취득 (mac_header offset 은 pull 시에도 유지됨) */
	eth = eth_hdr(skb);

	/* 비자기 유니캐스트: 로컬 스택이 소비할 수 없는 트래픽이므로
	 * clone 없이 원본을 p2w 큐에 넘기고 CONSUMED로 반환.
	 * skb_clone/스택 deliver 두 비용을 모두 제거. */
	if (!is_multicast_ether_addr(eth->h_dest)) {
		if (unlikely(!moal_bridge_dev_ready(br->wlan_dev))) {
			atomic_long_inc(&br->peer_to_wlan.dropped);
			kfree_skb(skb);
			*pskb = NULL;
			return RX_HANDLER_CONSUMED;
		}
		if (atomic_inc_return(&br->p2w_qlen) > MOAL_BR_P2W_QUEUE_MAX) {
			atomic_dec(&br->p2w_qlen);
			atomic_long_inc(&br->peer_to_wlan.dropped);
			kfree_skb(skb);
			*pskb = NULL;
			return RX_HANDLER_CONSUMED;
		}
		skb = moal_bridge_ensure_headroom(skb);
		if (!skb) {
			atomic_dec(&br->p2w_qlen);
			atomic_long_inc(&br->peer_to_wlan.oom_drops);
			*pskb = NULL;
			return RX_HANDLER_CONSUMED;
		}
		skb->dev = br->wlan_dev;
		skb_push(skb, ETH_HLEN);
		moal_bridge_stamp_enq(skb);
		skb_queue_tail(&br->p2w_queue, skb);
		wake_up(&br->p2w_wait);
		moal_bridge_ka_kick(br);
		*pskb = NULL;
		return RX_HANDLER_CONSUMED;
	}

	/* Multicast/Broadcast: 로컬 스택도 봐야 하므로 clone + PASS.
	 * SDIO 반이중 버스 특성으로 softirq에서 직접 dev_queue_xmit(wlan) 시
	 * SDIO TX가 RX를 블로킹하여 reply 지연 발생 (36ms avg).
	 * 전용 p2w kthread로 w2p와 격리 + 즉시 wake-up. */
	if (unlikely(!moal_bridge_dev_ready(br->wlan_dev))) {
		atomic_long_inc(&br->peer_to_wlan.dropped);
	} else {
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
		if (skb2) {
			if (atomic_inc_return(&br->p2w_qlen) >
			    MOAL_BR_P2W_QUEUE_MAX) {
				atomic_dec(&br->p2w_qlen);
				atomic_long_inc(&br->peer_to_wlan.dropped);
				dev_kfree_skb_any(skb2);
				return RX_HANDLER_PASS;
			}
			skb2 = moal_bridge_ensure_headroom(skb2);
			if (!skb2) {
				atomic_dec(&br->p2w_qlen);
				atomic_long_inc(&br->peer_to_wlan.oom_drops);
				return RX_HANDLER_PASS;
			}
			skb2->dev = br->wlan_dev;
			skb_push(skb2, ETH_HLEN);
			moal_bridge_stamp_enq(skb2);
			skb_queue_tail(&br->p2w_queue, skb2);
			wake_up(&br->p2w_wait);
			moal_bridge_ka_kick(br);
		} else {
			atomic_long_inc(&br->peer_to_wlan.oom_drops);
		}
	}
	return RX_HANDLER_PASS;
}

/*
 * ---------- ETH → WLAN Forwarding (packet_type fallback) ----------
 */

/**
 * moal_bridge_peer_pt_handler - dev_add_pack 기반 ETH→WLAN 포워딩
 *
 * rx_handler가 이미 등록된 경우(Linux bridge 등) fallback으로 사용.
 * AF_PACKET과 동일 레벨에서 동작하여 rx_handler와 충돌 없음.
 *
 * @note packet_type 핸들러는 eth_type_trans() 이후 호출됨.
 *       skb->data = L3 payload, eth_hdr(skb) = Ethernet header.
 *       반환값: 0 = skb를 소비하지 않음 (커널이 계속 처리)
 */
static int moal_bridge_peer_pt_func(struct sk_buff *skb,
				    struct net_device *dev,
				    struct packet_type *pt,
				    struct net_device *orig_dev)
{
	struct moal_bridge *br = container_of(pt, struct moal_bridge, peer_pt);

	if (!br || !atomic_read(&br->active) || dev != br->peer_dev) {
		kfree_skb(skb);
		return 0;
	}

	/* EAPOL check — media_connected 게이트는 공중 포워딩 직전으로 이동
	 * (G2 게이트 재배치, rx_handler 와 동일 근거) */
	if (skb->protocol == htons(ETH_P_PAE)) {
		kfree_skb(skb);
		return 0;
	}

	/* media down 비ARP 조기 드롭 (PR #11 리뷰): 아래 media 게이트에서
	 * 어차피 폐기될 트래픽이 skb_share_check 의 clone 할당/해제를 타지
	 * 않도록 선별. 무선 down 중 media 무관 처리가 필요한 것은 ARP
	 * (SELF-ARP suppress / REPLY inject)뿐이다. */
	if (!READ_ONCE(((moal_private *)br->wlan_priv)->media_connected) &&
	    vlan_get_protocol(skb) != htons(ETH_P_ARP)) {
		kfree_skb(skb);
		return 0;
	}

	/* packet_type handlers receive a refcount-shared skb, not a clone;
	 * unshare before mutating skb->data via skb_push(). */
	skb = skb_share_check(skb, GFP_ATOMIC);
	if (!skb) {
		atomic_long_inc(&br->peer_to_wlan.oom_drops);
		return 0;
	}

	/* SELF-ARP REQUEST (target IP == 박스 소유 IP 인 ARP "요청"): 공중
	 * 포워딩 금지 — 단, 스택 원본이 실제로 처리되는 경우(broadcast/host)에만.
	 * (peer_ipv4 도 arp_is_for_self 공유 판정에 포함 — eth0-IP 토폴로지)
	 * - REQUEST 한정: REPLY(tip==mlan0 IP)는 mlan0 pending neigh 해소의
	 *   유일 경로인 공중 hairpin 을 유지해야 한다 (rx_handler 가드와 동일
	 *   근거).
	 * - dst MAC 이 클론 MAC 인 unicast(OTHERHOST)는 arp_rcv 가 원본을
	 *   처리 없이 소비하므로(net/ipv4/arp.c) 공중 hairpin 이 유일한 배달
	 *   경로 — 기존 포워딩 유지. pt 모드는 rx_handler 와 달리 스택 원본의
	 *   pkt_type 을 정정할 수 없다(copy 만 받음).
	 * broadcast REQUEST 억제만으로 이중 ARP 응답(MAC_C) 레이스의 근원은
	 * 차단된다. (pt 모드의 SELF-IP unicast 도 동일 이유로 hairpin 유지.) */
	if (skb->pkt_type != PACKET_OTHERHOST &&
	    vlan_get_protocol(skb) == htons(ETH_P_ARP)) {
		unsigned int arp_off =
			(skb->protocol == htons(ETH_P_8021Q)) ? VLAN_HLEN : 0;

		if (moal_bridge_arp_is_for_self(br, skb, arp_off) &&
		    ((struct arphdr *)(skb->data + arp_off))->ar_op ==
			    htons(ARPOP_REQUEST)) {
			BR_DBG("p2w(pt) SELF-ARP-REQ no air fwd\n");
			kfree_skb(skb);
			return 0;
		}
	}

	/* C(pt). local hairpin: OTHERHOST unicast ARP REPLY(tip==자기 IP)는
	 * 스택 원본을 arp_rcv 가 처리 없이 소비하므로(위 주석), 공중 hairpin
	 * 대신 이 copy 를 wlan RX 로 주입해 pending neigh 를 AP 반사 없이
	 * 해소한다. rx_handler 모드의 inject 분기와 동등. untagged 만. */
	if (READ_ONCE(bridge_local_hairpin) &&
	    skb->pkt_type == PACKET_OTHERHOST &&
	    skb->protocol == htons(ETH_P_ARP)) {
		if (moal_bridge_arp_is_for_self(br, skb, 0) &&
		    ((struct arphdr *)skb->data)->ar_op == htons(ARPOP_REPLY)) {
			skb->dev = br->wlan_dev;
			skb->pkt_type = PACKET_HOST;
			atomic_long_inc(&br->hairpin_arp_inject);
			BR_DBG("p2w(pt) hairpin ARP-REPLY inject\n");
			netif_rx(skb);
			return 0;
		}
	}

	/* media_connected 게이트: 공중 포워딩 직전 (G2 게이트 재배치 —
	 * 위 SELF-ARP suppress·inject 는 무선 상태와 무관하게 동작) */
	if (!READ_ONCE(((moal_private *)br->wlan_priv)->media_connected)) {
		kfree_skb(skb);
		return 0;
	}

	if (unlikely(!moal_bridge_dev_ready(br->wlan_dev))) {
		atomic_long_inc(&br->peer_to_wlan.dropped);
		dev_kfree_skb_any(skb);
		return 0;
	}

	if (atomic_inc_return(&br->p2w_qlen) > MOAL_BR_P2W_QUEUE_MAX) {
		atomic_dec(&br->p2w_qlen);
		atomic_long_inc(&br->peer_to_wlan.dropped);
		dev_kfree_skb_any(skb);
		return 0;
	}
	skb = moal_bridge_ensure_headroom(skb);
	if (!skb) {
		atomic_dec(&br->p2w_qlen);
		atomic_long_inc(&br->peer_to_wlan.oom_drops);
		return 0;
	}
	skb->dev = br->wlan_dev;
	skb_push(skb, ETH_HLEN);
	moal_bridge_stamp_enq(skb);
	skb_queue_tail(&br->p2w_queue, skb);
	wake_up(&br->p2w_wait);
	moal_bridge_ka_kick(br);

	return 0;
}

/*
 * ---------- Inet Address Notifier (IP 변경 감지) ----------
 */

/**
 * moal_bridge_inetaddr_event - wlan/peer IPv4 주소 변경 감지
 *
 * DHCP 완료 시 wlan_ipv4를 재캐시하여 자기 IP 필터 정상 동작 보장.
 * 브릿지 init 시점에 wlan_ipv4=0.0.0.0 문제 해결.
 *
 * event 분기 필수: NETDEV_DOWN 은 "삭제되는 주소"의 ifa 로 호출되므로
 * (net/ipv4/devinet.c::__inet_del_ifa) 그 ifa_local 을 캐시하면 박스가
 * 더 이상 소유하지 않는 IP 가 self 로 남는다 (예: eth0 mgmt IP 교체
 * add→del 순서). DOWN 이면 장치에 남아있는 주소를 재조회한다.
 */
static int moal_bridge_inetaddr_event(struct notifier_block *nb,
				      unsigned long event, void *ptr)
{
	struct in_ifaddr *ifa = (struct in_ifaddr *)ptr;
	struct net_device *dev;
	struct moal_bridge *br = container_of(nb, struct moal_bridge, inet_nb);
	__be32 new_ip;

	/* Defensive: some notifier paths may deliver a partially-constructed ifa */
	if (!ifa || !ifa->ifa_dev || !ifa->ifa_dev->dev)
		return NOTIFY_DONE;
	dev = ifa->ifa_dev->dev;

	if (dev != br->wlan_dev && dev != br->peer_dev)
		return NOTIFY_DONE;

	/* if/else 사용 (switch-case 금지): bridge_static_checks.sh 의 B4 규칙이
	 * 파일에서 처음 나오는 DOWN case 레이블을 netdev notifier 의 queue
	 * purge 블록으로 가정하므로, 여기에 case 레이블(주석 포함)이 먼저
	 * 등장하면 오탐된다. */
	if (event == NETDEV_UP) {
		new_ip = ifa->ifa_local;
	} else if (event == NETDEV_DOWN) {
		/* 삭제 통지 시점에는 ifa 가 이미 리스트에서 분리됨 —
		 * 남은 첫 주소(없으면 0)를 재조회 */
		new_ip = moal_bridge_get_ipv4(dev);
	} else {
		return NOTIFY_DONE;
	}

	if (dev == br->wlan_dev) {
		WRITE_ONCE(br->wlan_ipv4, new_ip);
		PRINTM(MMSG, "bridge: wlan IPv4 updated = %pI4\n",
		       &br->wlan_ipv4);
	} else {
		WRITE_ONCE(br->peer_ipv4, new_ip);
		PRINTM(MMSG, "bridge: peer IPv4 updated = %pI4\n",
		       &br->peer_ipv4);
	}

	return NOTIFY_DONE;
}

/*
 * ---------- Netdev Notifier ----------
 */

/**
 * moal_bridge_netdev_event - peer 인터페이스 상태 변화 감지
 * Design Ref: §6.3 — peer down/up/unregister 처리
 *
 * Plan SC: SC-06 (rmmod 안전), NFR-06 (peer down/up graceful)
 */
static int moal_bridge_netdev_event(struct notifier_block *nb,
				    unsigned long event, void *ptr)
{
	struct net_device *dev = netdev_notifier_info_to_dev(ptr);
	struct moal_bridge *br = container_of(nb, struct moal_bridge,
					      netdev_nb);

	if (dev != br->peer_dev)
		return NOTIFY_DONE;

	switch (event) {
	case NETDEV_DOWN:
		PRINTM(MMSG, "bridge: peer '%s' went down, suspending\n",
		       dev->name);
		atomic_set(&br->active, 0);
		skb_queue_purge(&br->w2p_queue);
		skb_queue_purge(&br->p2w_queue);
		atomic_set(&br->w2p_qlen, 0);
		atomic_set(&br->p2w_qlen, 0);
		break;
	case NETDEV_UP:
		PRINTM(MMSG, "bridge: peer '%s' came up, resuming\n",
		       dev->name);
		/* IPv4 재캐시 (DHCP로 IP 변경 가능) */
		WRITE_ONCE(br->peer_ipv4, moal_bridge_get_ipv4(br->peer_dev));
		WRITE_ONCE(br->wlan_ipv4, moal_bridge_get_ipv4(br->wlan_dev));
		atomic_set(&br->active, 1);
		break;
	case NETDEV_UNREGISTER:
		PRINTM(MMSG, "bridge: peer '%s' unregistered, disabling\n",
		       dev->name);
		atomic_set(&br->active, 0);
		/* Called with RTNL held by the netdev notifier chain, so
		 * handler unregister / dev_set_promiscuity are safe here. */
		if (!atomic_read(&br->peer_released)) {
			if (br->use_packet_type)
				dev_remove_pack(&br->peer_pt);
			else
				netdev_rx_handler_unregister(br->peer_dev);
			dev_set_promiscuity(br->peer_dev, -1);
			dev_put(br->peer_dev);
			atomic_set(&br->peer_released, 1);
		}
		break;
	}
	return NOTIFY_DONE;
}

/*
 * ---------- Sysfs stats node ----------
 *
 * /sys/kernel/moal_bridge/stats — read-only live counters. Hot path is
 * not affected (no writers from the show handler). Single-instance:
 * DBDC guard limits the driver to one active bridge at a time, so a
 * global kobject + static bridge pointer is enough.
 */

static struct kobject *moal_bridge_kobj;
static struct moal_bridge *moal_bridge_for_sysfs;

static ssize_t stats_show(struct kobject *kobj, struct kobj_attribute *attr,
			  char *buf)
{
	struct moal_bridge *br = READ_ONCE(moal_bridge_for_sysfs);
	moal_handle *handle;
	long w2p_n, p2w_n, w2p_avg, p2w_avg;
	long rx_gap_n, rx_gap_avg;
	long rx_pull_n, rx_pull_avg, tx_write_n, tx_write_avg;

	if (!br)
		return scnprintf(buf, PAGE_SIZE, "bridge: inactive\n");
	handle = (moal_handle *)br->handle;

	/* In-driver one-way dwell (producer entry -> dev_queue_xmit submit),
	 * accumulated only while bridge_debug was on. avg = sum / cnt.
	 * cnt is read before sum without locking: a concurrent account_dwell
	 * can bump cnt before its paired sum add retires, so avg may be
	 * momentarily under-reported. Intentional for a debug sysfs file.
	 * '> 0' (not just truthy) also guards the LONG_MIN/-1 division trap
	 * should a counter ever wrap negative. */
	w2p_n = atomic_long_read(&br->wlan_to_peer.dwell_cnt);
	p2w_n = atomic_long_read(&br->peer_to_wlan.dwell_cnt);
	w2p_avg = w2p_n > 0 ?
		atomic_long_read(&br->wlan_to_peer.dwell_sum_us) / w2p_n : 0;
	p2w_avg = p2w_n > 0 ?
		atomic_long_read(&br->peer_to_wlan.dwell_sum_us) / p2w_n : 0;

	/* RX deliver-leg queue->run gap (handle-level, accumulated only while
	 * bridge_debug != 0). This is the moal-engine downstream jitter suspect;
	 * the pull leg runs in the mmc threaded-IRQ at SCHED_FIFO and is not
	 * measured here. gap_max is the headline number for leg attribution. */
	rx_gap_n = handle ? atomic_long_read(&handle->rx_gap_cnt) : 0;
	rx_gap_avg = rx_gap_n > 0 ?
		atomic_long_read(&handle->rx_gap_sum_us) / rx_gap_n : 0;

	/* SDIO bus legs: pull = woal_sdio_interrupt processing (RX read incl
	 * host-claim wait); tx_write = one sdio_claim_host+writesb. A large max
	 * here locates the RTT jitter the deliver leg (rx_gap) is not causing. */
	rx_pull_n = handle ? atomic_long_read(&handle->rx_pull_cnt) : 0;
	rx_pull_avg = rx_pull_n > 0 ?
		atomic_long_read(&handle->rx_pull_sum_us) / rx_pull_n : 0;
	tx_write_n = handle ? atomic_long_read(&handle->tx_write_cnt) : 0;
	tx_write_avg = tx_write_n > 0 ?
		atomic_long_read(&handle->tx_write_sum_us) / tx_write_n : 0;

	return scnprintf(buf, PAGE_SIZE,
			 "w2p fwd=%ld bytes=%ld drop=%ld err=%ld oom=%ld qlen=%d dwell_avg=%ldus dwell_max=%ldus n=%ld\n"
			 "p2w fwd=%ld bytes=%ld drop=%ld err=%ld oom=%ld qlen=%d dwell_avg=%ldus dwell_max=%ldus n=%ld\n"
			 "active=%d peer_released=%d\n"
			 "rx_deliver gap_avg=%ldus gap_max=%ldus n=%ld dur_max=%ldus\n"
			 "rx_pull avg=%ldus max=%ldus n=%ld\n"
			 "tx_write avg=%ldus max=%ldus n=%ld\n"
			 "hairpin on=%d tx_fwd=%ld arp_tee=%ld arp_inject=%ld\n",
			 atomic_long_read(&br->wlan_to_peer.fwd_packets),
			 atomic_long_read(&br->wlan_to_peer.fwd_bytes),
			 atomic_long_read(&br->wlan_to_peer.dropped),
			 atomic_long_read(&br->wlan_to_peer.errors),
			 atomic_long_read(&br->wlan_to_peer.oom_drops),
			 atomic_read(&br->w2p_qlen),
			 w2p_avg,
			 atomic_long_read(&br->wlan_to_peer.dwell_max_us),
			 w2p_n,
			 atomic_long_read(&br->peer_to_wlan.fwd_packets),
			 atomic_long_read(&br->peer_to_wlan.fwd_bytes),
			 atomic_long_read(&br->peer_to_wlan.dropped),
			 atomic_long_read(&br->peer_to_wlan.errors),
			 atomic_long_read(&br->peer_to_wlan.oom_drops),
			 atomic_read(&br->p2w_qlen),
			 p2w_avg,
			 atomic_long_read(&br->peer_to_wlan.dwell_max_us),
			 p2w_n,
			 atomic_read(&br->active),
			 atomic_read(&br->peer_released),
			 rx_gap_avg,
			 handle ? atomic_long_read(&handle->rx_gap_max_us) : 0,
			 rx_gap_n,
			 handle ? atomic_long_read(&handle->rx_dur_max_us) : 0,
			 rx_pull_avg,
			 handle ? atomic_long_read(&handle->rx_pull_max_us) : 0,
			 rx_pull_n,
			 tx_write_avg,
			 handle ? atomic_long_read(&handle->tx_write_max_us) : 0,
			 tx_write_n,
			 READ_ONCE(bridge_local_hairpin),
			 atomic_long_read(&br->hairpin_tx_fwd),
			 atomic_long_read(&br->hairpin_arp_tee),
			 atomic_long_read(&br->hairpin_arp_inject));
}

static struct kobj_attribute stats_attr = __ATTR_RO(stats);

static int moal_bridge_sysfs_init(struct moal_bridge *br)
{
	int ret;

	BUILD_BUG_ON(sizeof(struct moal_br_skb_cb) >
		     sizeof(((struct sk_buff *)0)->cb));
	/* dwell math uses 'long' + atomic_long; enforce LP64 (arm64 targets)
	 * so a future 32-bit port fails loud instead of silently truncating
	 * s64 ktime_to_us / overflowing the accumulators. */
	BUILD_BUG_ON(sizeof(long) < 8);

	moal_bridge_kobj = kobject_create_and_add("moal_bridge", kernel_kobj);
	if (!moal_bridge_kobj)
		return -ENOMEM;
	ret = sysfs_create_file(moal_bridge_kobj, &stats_attr.attr);
	if (ret) {
		kobject_put(moal_bridge_kobj);
		moal_bridge_kobj = NULL;
		return ret;
	}
	WRITE_ONCE(moal_bridge_for_sysfs, br);
	return 0;
}

static void moal_bridge_sysfs_deinit(void)
{
	WRITE_ONCE(moal_bridge_for_sysfs, NULL);
	if (moal_bridge_kobj) {
		sysfs_remove_file(moal_bridge_kobj, &stats_attr.attr);
		kobject_put(moal_bridge_kobj);
		moal_bridge_kobj = NULL;
	}
}

/*
 * ---------- Lifecycle ----------
 */

/**
 * @brief Initialize L2 bridge
 * Design Ref: §6.1 — peer_dev 참조, MAC/IP 캐시, rx_handler 등록
 *
 * Plan SC: SC-04 (bridge_mode=0 시 미호출), SC-06 (자원 관리)
 */
int moal_bridge_init(void *phandle, const char *peer_name, int wlan_bss_idx)
{
	moal_handle *handle = (moal_handle *)phandle;
	struct moal_bridge *br;
	struct net_device *peer;
	int ret;

	PRINTM(MMSG, "bridge: init (peer=%s, wlan_bss=%d)\n",
	       peer_name, wlan_bss_idx);

	/* 0. DBDC guard: 이미 다른 handle에서 bridge 활성화됨 */
	if (atomic_cmpxchg(&bridge_instance_active, 0, 1) != 0) {
		PRINTM(MERROR,
		       "bridge: init refused, another instance already active\n");
		return -EBUSY;
	}

	/* 1. wlan netdev 확인 — DBDC: bridge_wlan_idx로 BSS 선택 */
	if (wlan_bss_idx < 0 || wlan_bss_idx >= MLAN_MAX_BSS_NUM ||
	    !handle->priv[wlan_bss_idx] ||
	    !handle->priv[wlan_bss_idx]->netdev) {
		PRINTM(MERROR, "bridge: wlan BSS[%d] not ready\n", wlan_bss_idx);
		atomic_set(&bridge_instance_active, 0);
		return -ENODEV;
	}

	/* 2. peer netdev 검색 — dev_get_by_name()이 dev_hold() 수행 */
	peer = dev_get_by_name(&init_net, peer_name);
	if (!peer) {
		PRINTM(MERROR, "bridge: peer '%s' not found\n", peer_name);
		atomic_set(&bridge_instance_active, 0);
		return -ENODEV;
	}

	/* 3. bridge context 할당 */
	br = kzalloc(sizeof(*br), GFP_KERNEL);
	if (!br) {
		dev_put(peer);
		atomic_set(&bridge_instance_active, 0);
		return -ENOMEM;
	}

	/* 4. 초기화 */
	br->peer_dev = peer;
	br->wlan_dev = handle->priv[wlan_bss_idx]->netdev;
	br->wlan_priv = handle->priv[wlan_bss_idx];
	br->handle = handle;
	atomic_set(&br->active, 0);

	skb_queue_head_init(&br->w2p_queue);
	atomic_set(&br->w2p_qlen, 0);
	init_waitqueue_head(&br->w2p_wait);
	br->w2p_thread = kthread_run(moal_bridge_w2p_thread_fn, br,
				     "moal_br_w2p");
	if (IS_ERR(br->w2p_thread)) {
		ret = PTR_ERR(br->w2p_thread);
		br->w2p_thread = NULL;
		dev_put(peer);
		kfree(br);
		atomic_set(&bridge_instance_active, 0);
		return ret;
	}

	/* p2w: 전용 kthread 초기화 (ETH→WLAN, SDIO TX 격리) */
	skb_queue_head_init(&br->p2w_queue);
	atomic_set(&br->p2w_qlen, 0);
	init_waitqueue_head(&br->p2w_wait);
	br->p2w_thread = kthread_run(moal_bridge_p2w_thread_fn, br,
				     "moal_br_p2w");
	if (IS_ERR(br->p2w_thread)) {
		ret = PTR_ERR(br->p2w_thread);
		br->p2w_thread = NULL;
		kthread_stop(br->w2p_thread);
		br->w2p_thread = NULL;
		dev_put(peer);
		kfree(br);
		atomic_set(&bridge_instance_active, 0);
		return ret;
	}

	/* MAC 주소 캐시 */
	ether_addr_copy(br->wlan_mac, br->wlan_dev->dev_addr);
	ether_addr_copy(br->peer_mac, br->peer_dev->dev_addr);

	/* IPv4 주소 캐시 */
	br->wlan_ipv4 = moal_bridge_get_ipv4(br->wlan_dev);
	br->peer_ipv4 = moal_bridge_get_ipv4(br->peer_dev);

	/* 5. RTNL 락 하에서 promiscuous + rx_handler 등록 (RTNL 필수)
	 * dev_set_promiscuity, netdev_rx_handler_register 모두 RTNL 보유 필요 */
	br->use_packet_type = 0;
	rtnl_lock();
	dev_set_promiscuity(peer, 1);
	ret = netdev_rx_handler_register(peer, moal_bridge_peer_rx_handler, br);
	rtnl_unlock();
	if (ret) {
		PRINTM(MMSG, "bridge: rx_handler busy on '%s' (err=%d), "
		       "using packet_type fallback\n", peer_name, ret);
		br->use_packet_type = 1;
		br->peer_pt.type = htons(ETH_P_ALL);
		br->peer_pt.func = moal_bridge_peer_pt_func;
		br->peer_pt.dev = peer;
		dev_add_pack(&br->peer_pt);
	}

	/* 6. netdev notifier 등록 */
	br->netdev_nb.notifier_call = moal_bridge_netdev_event;
	register_netdevice_notifier(&br->netdev_nb);

	/* 6b. inetaddr notifier 등록 (DHCP 완료 시 IP 재캐시) */
	br->inet_nb.notifier_call = moal_bridge_inetaddr_event;
	register_inetaddr_notifier(&br->inet_nb);

	/* 7. keepalive timer — keeps the SDIO main_work warm.
	 *    idle_ms<=0: free-running (legacy) — start now, never self-stops.
	 *    idle_ms>0 : adaptive — armed by the first forwarded packet
	 *                (moal_bridge_ka_kick) and self-stops after idle_ms of
	 *                no traffic, so a truly idle link costs zero wakeups. */
	if (handle->params.bridge_keepalive_ms > 0) {
		hrtimer_init(&br->keepalive_timer, CLOCK_MONOTONIC,
			     HRTIMER_MODE_REL);
		br->keepalive_timer.function = moal_bridge_keepalive;
		br->ka_last_fwd = ktime_get();
		if (handle->params.bridge_keepalive_idle_ms > 0) {
			atomic_set(&br->ka_armed, 0);
			PRINTM(MMSG,
			       "bridge:   keepalive  = %dms (adaptive, idle %dms)\n",
			       handle->params.bridge_keepalive_ms,
			       handle->params.bridge_keepalive_idle_ms);
			/* idle_ms < keepalive_ms → 타이머가 매 tick 마다
			 * idle_us < cutoff 로 판정되어 legacy 속도로 계속 돎
			 * (자가정지 안 됨) → 절감 무력화. 경고만, 동작은 유지. */
			if (handle->params.bridge_keepalive_idle_ms <
			    handle->params.bridge_keepalive_ms)
				PRINTM(MWARN,
				       "bridge: keepalive_idle_ms(%d) < keepalive_ms(%d) — timer re-arms every tick; power saving ineffective\n",
				       handle->params.bridge_keepalive_idle_ms,
				       handle->params.bridge_keepalive_ms);
		} else {
			ktime_t interval = ns_to_ktime(
				(u64)handle->params.bridge_keepalive_ms *
				NSEC_PER_MSEC);
			atomic_set(&br->ka_armed, 1);
			hrtimer_start(&br->keepalive_timer, interval,
				      HRTIMER_MODE_REL);
			PRINTM(MMSG, "bridge:   keepalive  = %dms\n",
			       handle->params.bridge_keepalive_ms);
		}
	} else {
		PRINTM(MMSG, "bridge:   keepalive  = off\n");
	}

	/* 8. 활성화 — rcu_assign_pointer publishes br before readers may observe it */
	rcu_assign_pointer(handle->bridge, br);
	atomic_set(&br->active, 1);

	/* 8b. sysfs stats node (best-effort; log but do not fail init) */
	if (moal_bridge_sysfs_init(br))
		PRINTM(MMSG, "bridge: sysfs stats node unavailable\n");

	PRINTM(MMSG, "bridge: === Configuration ===\n");
	PRINTM(MMSG, "bridge:   mode        = %d\n", 1);
	PRINTM(MMSG, "bridge:   wlan_bss    = %d (%s)\n",
	       wlan_bss_idx, br->wlan_dev->name);
	PRINTM(MMSG, "bridge:   peer        = %s\n", br->peer_dev->name);
	PRINTM(MMSG, "bridge:   wlan_mac    = " MACSTR "\n",
	       MAC2STR(br->wlan_mac));
	PRINTM(MMSG, "bridge:   peer_mac    = " MACSTR "\n",
	       MAC2STR(br->peer_mac));
	PRINTM(MMSG, "bridge:   wlan_ipv4   = %pI4\n", &br->wlan_ipv4);
	PRINTM(MMSG, "bridge:   peer_ipv4   = %pI4\n", &br->peer_ipv4);
	PRINTM(MMSG, "bridge:   eth2wlan   = %s\n",
	       br->use_packet_type ? "packet_type (fallback)" : "rx_handler");
	PRINTM(MMSG, "bridge:   promisc    = on (peer)\n");
	PRINTM(MMSG, "bridge: === Activated ===\n");

	return 0;
}

/**
 * @brief Deinitialize L2 bridge
 * Design Ref: §6.2 — 해제 순서: active=0 → notifier → rx_handler →
 *                     synchronize_net → dev_put → kfree
 *
 * Plan SC: SC-06 (rmmod 정상 언로드)
 */
void moal_bridge_deinit(void *phandle)
{
	moal_handle *handle = (moal_handle *)phandle;
	struct moal_bridge *br = handle->bridge;

	if (!handle || !br)
		return;

	/* 1. 포워딩 비활성화 + keepalive timer 중지 + sysfs 노드 제거 */
	atomic_set(&br->active, 0);
	moal_bridge_sysfs_deinit();
	if (br->keepalive_timer.function)
		hrtimer_cancel(&br->keepalive_timer);

	/* 2. notifier 해제 */
	unregister_inetaddr_notifier(&br->inet_nb);
	unregister_netdevice_notifier(&br->netdev_nb);

	/* 3. ETH→WLAN 경로 해제 + promiscuous 해제 (RTNL 하에서).
	 *    peer_released=1이면 NETDEV_UNREGISTER 경로에서 이미 정리됨. */
	if (!atomic_read(&br->peer_released)) {
		rtnl_lock();
		if (br->use_packet_type)
			dev_remove_pack(&br->peer_pt);
		else
			netdev_rx_handler_unregister(br->peer_dev);
		dev_set_promiscuity(br->peer_dev, -1);
		rtnl_unlock();
	}

	/* 4. 진행 중인 rx_handler / packet_type / moal_recv_packet reader 배수.
	 *    synchronize_net 은 net path 의 RCU reader 를 포함한다. */
	synchronize_net();

	/* 5. handle->bridge 공개 포인터를 먼저 NULL 로 치환하고 RCU drain.
	 *    이 시점 이후 어떤 RX 경로도 br 을 새로 잡을 수 없으므로,
	 *    kthread_stop 이후 reader 가 w2p/p2w 큐에 skb 를 밀어넣는
	 *    race 가 원천 차단된다. synchronize_net 이 네트 경로를 드레인한
	 *    뒤이지만, 이 단계를 kthread_stop 앞으로 당겨야 설계 의도가 명확. */
	rcu_assign_pointer(handle->bridge, NULL);
	synchronize_rcu();

	/* 5b. keepalive: in adaptive mode an in-flight producer may have
	 *     re-armed the timer (hrtimer_start) after the early cancel above.
	 *     All ka_kick producers are drained by now, each by its own path:
	 *       - rx_handler mode: netdev_rx_handler_unregister()+
	 *         synchronize_net() (step 3/4),
	 *       - packet_type mode: dev_remove_pack()+synchronize_net() — its
	 *         br comes from container_of(pt,...), NOT handle->bridge, so the
	 *         bridge-ptr NULL does not gate it,
	 *       - rx_fast (WLAN RX): bridge-ptr NULL + synchronize_rcu() above.
	 *     So no further ka_kick can arm the timer. The callback can still
	 *     keep ITSELF alive via HRTIMER_RESTART while ka_last_fwd is recent,
	 *     but active=0 (step 1) already makes its queue_work(main_work) a
	 *     no-op, and this second hrtimer_cancel terminates that self-RESTART
	 *     loop — so this cancel is final. No-op / safe in legacy and off modes. */
	if (br->keepalive_timer.function) {
		atomic_set(&br->ka_armed, 0);
		hrtimer_cancel(&br->keepalive_timer);
	}

	/* 6. 전용 kthread 종료 후 남은 큐 purge. */
	if (br->w2p_thread) {
		kthread_stop(br->w2p_thread);
		br->w2p_thread = NULL;
	}
	skb_queue_purge(&br->w2p_queue);

	if (br->p2w_thread) {
		kthread_stop(br->p2w_thread);
		br->p2w_thread = NULL;
	}
	skb_queue_purge(&br->p2w_queue);

	/* 7. 통계 출력 */
	PRINTM(MMSG, "bridge: %s <-> %s deactivated\n",
	       br->wlan_dev->name, br->peer_dev->name);
	PRINTM(MMSG, "bridge: w2p fwd=%ld drop=%ld err=%ld oom=%ld\n",
	       atomic_long_read(&br->wlan_to_peer.fwd_packets),
	       atomic_long_read(&br->wlan_to_peer.dropped),
	       atomic_long_read(&br->wlan_to_peer.errors),
	       atomic_long_read(&br->wlan_to_peer.oom_drops));
	PRINTM(MMSG, "bridge: p2w fwd=%ld drop=%ld err=%ld oom=%ld\n",
	       atomic_long_read(&br->peer_to_wlan.fwd_packets),
	       atomic_long_read(&br->peer_to_wlan.dropped),
	       atomic_long_read(&br->peer_to_wlan.errors),
	       atomic_long_read(&br->peer_to_wlan.oom_drops));
	PRINTM(MMSG, "bridge: hairpin tx_fwd=%ld arp_tee=%ld arp_inject=%ld\n",
	       atomic_long_read(&br->hairpin_tx_fwd),
	       atomic_long_read(&br->hairpin_arp_tee),
	       atomic_long_read(&br->hairpin_arp_inject));

	/* 8. peer 참조 반환 + 메모리 해제. */
	if (!atomic_read(&br->peer_released))
		dev_put(br->peer_dev);
	kfree(br);

	/* 9. DBDC guard 해제 */
	atomic_set(&bridge_instance_active, 0);
}
