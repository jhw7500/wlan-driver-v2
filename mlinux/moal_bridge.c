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

/** DBDC guard: only one bridge instance allowed globally */
static atomic_t bridge_instance_active = ATOMIC_INIT(0);

/** bridge_debug: runtime-changeable via /sys/module/moal/parameters/bridge_debug */
extern int bridge_debug;
/** bridge_keepalive_ms: module param default copied into handle->params at init */
extern int bridge_keepalive_ms;
#define BR_DBG(fmt, ...) do { \
	if (bridge_debug) \
		printk(KERN_INFO "bridge: " fmt, ##__VA_ARGS__); \
} while (0)

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
	int keepalive_ms;

	if (atomic_read(&br->active) && handle->workqueue)
		queue_work(handle->workqueue, &handle->main_work);

	keepalive_ms = handle->params.bridge_keepalive_ms;
	if (keepalive_ms <= 0)
		return HRTIMER_NORESTART;

	interval = ns_to_ktime((u64)keepalive_ms * NSEC_PER_MSEC);
	hrtimer_forward_now(timer, interval);
	return HRTIMER_RESTART;
}

/*
 * ---------- w2p Thread (WLAN→ETH, dedicated kthread) ----------
 */

static int moal_bridge_w2p_thread_fn(void *data)
{
	struct moal_bridge *br = data;
	struct sk_buff *skb;
	unsigned int len;
	int err;
	int cnt;

	sched_set_fifo(current);

	while (!kthread_should_stop()) {
		wait_event_interruptible(br->w2p_wait,
			!skb_queue_empty(&br->w2p_queue) ||
			kthread_should_stop());

		if (kthread_should_stop())
			break;

		cnt = 0;
		while ((skb = skb_dequeue(&br->w2p_queue)) != NULL) {
			atomic_dec(&br->w2p_qlen);
			len = skb->len;
			err = dev_queue_xmit(skb);
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

	/* pcap과 동일: SCHED_FIFO:50으로 wake-up 즉시 실행.
	 * 이전 실패(local_bh_disable + 양방향 kthread) 조건 해소:
	 * - p2w 전용 (w2p 블로킹 없음)
	 * - 외부 local_bh_disable 없음 (dev_queue_xmit 내부만 단발성) */
	sched_set_fifo(current);

	while (!kthread_should_stop()) {
		wait_event_interruptible(br->p2w_wait,
			!skb_queue_empty(&br->p2w_queue) ||
			kthread_should_stop());

		if (kthread_should_stop())
			break;

		cnt = 0;
		while ((skb = skb_dequeue(&br->p2w_queue)) != NULL) {
			atomic_dec(&br->p2w_qlen);
			len = skb->len;
			err = dev_queue_xmit(skb);
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

	/* wlan IP만 보호 (peer IP는 MAC 스푸핑 환경에서 불필요) */
	return (br->wlan_ipv4 && target_ip == br->wlan_ipv4);
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

	if (proto == htons(ETH_P_ARP) &&
	    moal_bridge_arp_is_for_self(br, skb, l3_off)) {
		BR_DBG("w2p SELF-ARP skip clone\n");
		return 0;
	}

	/* STA 모드: 모든 수신 패킷의 dst MAC = WLAN MAC (AP→STA 프레임 특성)
	 * → MAC 기반 자기/포워딩 구분 불가. IP로 판정:
	 *   - self IPv4 unicast: 스택만 처리 (return 0)
	 *   - non-self IPv4 unicast: 원본 consume (return 1, 스택 배달 생략)
	 *   - 나머지 (mcast, non-IPv4, iph pull 실패): clone + 스택 배달 (return 0) */
	if (proto == htons(ETH_P_IP) &&
	    !is_multicast_ether_addr(eth->h_dest)) {
		__be32 wlan_ip = READ_ONCE(br->wlan_ipv4);

		if (wlan_ip &&
		    pskb_may_pull(skb, l3_off + sizeof(struct iphdr))) {
			struct iphdr *iph = (struct iphdr *)(skb->data + l3_off);

			if (iph->daddr == wlan_ip) {
				BR_DBG("w2p SELF-IP skip clone dip=%pI4\n",
				       &iph->daddr);
				return 0;
			}
			/* Non-self unicast IPv4 → consume original (no clone, no stack) */
			if (atomic_inc_return(&br->w2p_qlen) >
			    MOAL_BR_W2P_QUEUE_MAX) {
				atomic_dec(&br->w2p_qlen);
				atomic_long_inc(&br->wlan_to_peer.dropped);
				kfree_skb(skb);
				return 1; /* consumed: dropped without stack deliver */
			}
			skb->dev = br->peer_dev;
			skb_queue_tail(&br->w2p_queue, skb);
			wake_up(&br->w2p_wait);
			return 1; /* consumed: forwarded, skip stack deliver */
		}
		/* wlan_ip == 0 or iph pull failed → fall through to clone+pass */
	}

	/* Multicast/Broadcast, 비IPv4 유니캐스트, 또는 iph pull 실패 →
	 * clone + 원본 스택 배달 */
	{
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
			skb_queue_tail(&br->w2p_queue, skb2);
			wake_up(&br->w2p_wait);
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

	/* media_connected check (READ_ONCE — disconnect race 방어) */
	if (!READ_ONCE(((moal_private *)br->wlan_priv)->media_connected))
		return RX_HANDLER_PASS;

	/* EAPOL: never forward */
	if (skb->protocol == htons(ETH_P_PAE))
		return RX_HANDLER_PASS;

	/* 유니캐스트: peer(eth0) 자기 MAC → clone 불필요, 커널 스택만 처리
	 * (init에서 캐시된 br->peer_mac 사용 — peer_dev->dev_addr pointer chase 제거) */
	if (!is_multicast_ether_addr(eth->h_dest) &&
	    ether_addr_equal(eth->h_dest, br->peer_mac))
		return RX_HANDLER_PASS;

	/* 비자기 유니캐스트: 로컬 스택이 소비할 수 없는 트래픽이므로
	 * clone 없이 원본을 p2w 큐에 넘기고 CONSUMED로 반환.
	 * skb_clone/스택 deliver 두 비용을 모두 제거. */
	if (!is_multicast_ether_addr(eth->h_dest)) {
		if (atomic_inc_return(&br->p2w_qlen) > MOAL_BR_P2W_QUEUE_MAX) {
			atomic_dec(&br->p2w_qlen);
			atomic_long_inc(&br->peer_to_wlan.dropped);
			kfree_skb(skb);
			*pskb = NULL;
			return RX_HANDLER_CONSUMED;
		}
		skb->dev = br->wlan_dev;
		skb_push(skb, ETH_HLEN);
		skb_queue_tail(&br->p2w_queue, skb);
		wake_up(&br->p2w_wait);
		*pskb = NULL;
		return RX_HANDLER_CONSUMED;
	}

	/* Multicast/Broadcast: 로컬 스택도 봐야 하므로 clone + PASS.
	 * SDIO 반이중 버스 특성으로 softirq에서 직접 dev_queue_xmit(wlan) 시
	 * SDIO TX가 RX를 블로킹하여 reply 지연 발생 (36ms avg).
	 * 전용 p2w kthread로 w2p와 격리 + 즉시 wake-up. */
	{
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
		if (skb2) {
			if (atomic_inc_return(&br->p2w_qlen) >
			    MOAL_BR_P2W_QUEUE_MAX) {
				atomic_dec(&br->p2w_qlen);
				atomic_long_inc(&br->peer_to_wlan.dropped);
				dev_kfree_skb_any(skb2);
				return RX_HANDLER_PASS;
			}
			skb2->dev = br->wlan_dev;
			skb_push(skb2, ETH_HLEN);
			skb_queue_tail(&br->p2w_queue, skb2);
			wake_up(&br->p2w_wait);
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

	/* media_connected + EAPOL check (READ_ONCE — disconnect race 방어) */
	if (!READ_ONCE(((moal_private *)br->wlan_priv)->media_connected) ||
	    skb->protocol == htons(ETH_P_PAE)) {
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

	if (atomic_inc_return(&br->p2w_qlen) > MOAL_BR_P2W_QUEUE_MAX) {
		atomic_dec(&br->p2w_qlen);
		atomic_long_inc(&br->peer_to_wlan.dropped);
		dev_kfree_skb_any(skb);
		return 0;
	}
	skb->dev = br->wlan_dev;
	skb_push(skb, ETH_HLEN);
	skb_queue_tail(&br->p2w_queue, skb);
	wake_up(&br->p2w_wait);

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
 */
static int moal_bridge_inetaddr_event(struct notifier_block *nb,
				      unsigned long event, void *ptr)
{
	struct in_ifaddr *ifa = (struct in_ifaddr *)ptr;
	struct net_device *dev;
	struct moal_bridge *br = container_of(nb, struct moal_bridge, inet_nb);

	/* Defensive: some notifier paths may deliver a partially-constructed ifa */
	if (!ifa || !ifa->ifa_dev || !ifa->ifa_dev->dev)
		return NOTIFY_DONE;
	dev = ifa->ifa_dev->dev;

	if (dev == br->wlan_dev) {
		WRITE_ONCE(br->wlan_ipv4, ifa->ifa_local);
		PRINTM(MMSG, "bridge: wlan IPv4 updated = %pI4\n",
		       &br->wlan_ipv4);
	} else if (dev == br->peer_dev) {
		WRITE_ONCE(br->peer_ipv4, ifa->ifa_local);
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
		if (!br->peer_released) {
			if (br->use_packet_type)
				dev_remove_pack(&br->peer_pt);
			else
				netdev_rx_handler_unregister(br->peer_dev);
			dev_set_promiscuity(br->peer_dev, -1);
			dev_put(br->peer_dev);
			br->peer_released = 1;
		}
		break;
	}
	return NOTIFY_DONE;
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

	/* 7. keepalive timer 시작 (드라이버 main_work warm 유지) */
	if (handle->params.bridge_keepalive_ms > 0) {
		ktime_t interval = ns_to_ktime(
			(u64)handle->params.bridge_keepalive_ms * NSEC_PER_MSEC);
		hrtimer_init(&br->keepalive_timer, CLOCK_MONOTONIC,
			     HRTIMER_MODE_REL);
		br->keepalive_timer.function = moal_bridge_keepalive;
		hrtimer_start(&br->keepalive_timer, interval,
			      HRTIMER_MODE_REL);
		PRINTM(MMSG, "bridge:   keepalive  = %dms\n",
		       handle->params.bridge_keepalive_ms);
	} else {
		PRINTM(MMSG, "bridge:   keepalive  = off\n");
	}

	/* 8. 활성화 — rcu_assign_pointer publishes br before readers may observe it */
	rcu_assign_pointer(handle->bridge, br);
	atomic_set(&br->active, 1);

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

	/* 1. 포워딩 비활성화 + keepalive timer 중지 */
	atomic_set(&br->active, 0);
	if (br->keepalive_timer.function)
		hrtimer_cancel(&br->keepalive_timer);

	/* 2. notifier 해제 */
	unregister_inetaddr_notifier(&br->inet_nb);
	unregister_netdevice_notifier(&br->netdev_nb);

	/* 3. ETH→WLAN 경로 해제 + promiscuous 해제 (RTNL 하에서).
	 *    peer_released=1이면 NETDEV_UNREGISTER 경로에서 이미 정리됨. */
	if (!br->peer_released) {
		rtnl_lock();
		if (br->use_packet_type)
			dev_remove_pack(&br->peer_pt);
		else
			netdev_rx_handler_unregister(br->peer_dev);
		dev_set_promiscuity(br->peer_dev, -1);
		rtnl_unlock();
	}

	/* 4. 진행 중인 패킷 완료 대기 */
	synchronize_net();

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

	/* 6. 통계 출력 */
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

	/* 7. peer 참조 반환 + 메모리 해제.
	 *    rcu_assign_pointer + synchronize_rcu: readers holding an old br
	 *    pointer must drain before kfree. */
	rcu_assign_pointer(handle->bridge, NULL);
	synchronize_rcu();
	if (!br->peer_released)
		dev_put(br->peer_dev);
	kfree(br);

	/* 8. DBDC guard 해제 */
	atomic_set(&bridge_instance_active, 0);
}
