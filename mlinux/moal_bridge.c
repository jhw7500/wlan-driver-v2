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

/*
 * ---------- Async Forward Tasklet ----------
 */

/**
 * moal_bridge_fwd_tasklet - 비동기 패킷 포워딩
 * RX 핫패스에서 clone → 큐 적재만 하고, 실제 dev_queue_xmit는 여기서.
 * moal_recv_packet 컨텍스트를 블로킹하지 않음 (wbridge 스레드와 유사 효과).
 */
static void moal_bridge_fwd_tasklet(unsigned long data)
{
	struct moal_bridge *br = (struct moal_bridge *)data;
	struct sk_buff *skb;

	while ((skb = skb_dequeue(&br->fwd_queue)) != NULL)
		dev_queue_xmit(skb);
}

/** DBDC guard: only one bridge instance allowed globally */
static atomic_t bridge_instance_active = ATOMIC_INIT(0);

/** bridge_debug: runtime-changeable via /sys/module/moal/parameters/bridge_debug */
extern int bridge_debug;
#define BR_DBG(fmt, ...) do { \
	if (bridge_debug) \
		printk(KERN_INFO "bridge: " fmt, ##__VA_ARGS__); \
} while (0)

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
					struct sk_buff *skb)
{
	struct arphdr *arp;
	unsigned char *arp_ptr;
	__be32 target_ip;

	if (!pskb_may_pull(skb, sizeof(struct arphdr) + 20))
		return false;

	arp = (struct arphdr *)skb->data;
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

/* IP 필터 제거: 브릿지 구조에서 wlan_ipv4 = 클라이언트 응답 IP이므로
 * IP 기반 필터링 시 정상 트래픽도 차단됨. wbridge도 enable_ip_filter=0 기본. */

/**
 * moal_bridge_should_forward - 패킷을 peer로 포워딩할지 판정
 * Design Ref: §5.1 — wbridge filter.c::filter_should_drop() 역논리
 *
 * @note eth_type_trans()가 이미 호출된 상태이므로:
 *       - skb->protocol = EtherType (network order)
 *       - skb->data는 ETH_HLEN 이후 (L3 payload)
 *       - eth_hdr(skb)로 이더넷 헤더 접근 가능 (skb->mac_header 설정됨)
 *
 * Return: true=포워딩, false=커널 스택으로 전달
 */
static bool moal_bridge_should_forward(struct moal_bridge *br,
				       struct sk_buff *skb)
{
	struct ethhdr *eth = eth_hdr(skb);
	__be16 proto = skb->protocol;

	/* WiFi 미연결 시 포워딩 차단 — wbridge는 연결 후 수동 실행하여 이 문제 없었음.
	 * 커널 브릿지는 드라이버 로드 시 즉시 활성화되므로 연결 전 TX 간섭 방지 필요 */
	if (!((moal_private *)br->wlan_priv)->media_connected) {
		BR_DBG("not connected (media_connected=%d)\n",
		       ((moal_private *)br->wlan_priv)->media_connected);
		return false;
	}

	/* EAPOL(802.1X) / WAPI: 인증 패킷은 절대 포워딩하지 않음
	 * — 포워딩 시 WPA 핸드셰이크 실패 ("protocol 888e is buggy" 발생) */
	if (proto == htons(ETH_P_PAE))
		return false;

	/* VLAN 802.1Q: 내부 프로토콜 추출 (skb 데이터는 수정하지 않음)
	 * Design Ref: §5.1 — VLAN 태그 투명 처리 */
	if (proto == htons(ETH_P_8021Q)) {
		if (skb->len < sizeof(struct vlan_hdr))
			return false;
		proto = vlan_eth_hdr(skb)->h_vlan_encapsulated_proto;
	}

	/* 멀티캐스트/브로드캐스트 */
	if (is_multicast_ether_addr(eth->h_dest)) {
		/* ARP for bridge IP → 커널이 응답해야 함 */
		if (proto == htons(ETH_P_ARP) &&
		    moal_bridge_arp_is_for_self(br, skb))
			return false;
		/* 나머지 멀티캐스트/브로드캐스트 → 포워딩 */
		return true;
	}

	/* 유니캐스트: 자기(wlan) MAC 대상 → 커널 스택으로 (브릿지 관리 트래픽)
	 * 단, MAC/IP 필터는 최소한만 적용 (wbridge도 기본 OFF)
	 * IP 필터 제거: 브릿지 구조에서 wlan_ipv4 = 클라이언트 응답 IP이므로
	 * IP 필터 시 정상 트래픽도 차단됨 */
	if (ether_addr_equal(eth->h_dest, br->wlan_dev->dev_addr))
		return false;

	/* 그 외 → 포워딩 */
	return true;
}

/*
 * ---------- WLAN → ETH Forwarding ----------
 */

/**
 * moal_bridge_rx - WLAN RX 패킷을 peer(eth)로 포워딩
 * Design Ref: §4.1 — WLAN→ETH 방향
 *
 * @param br   Bridge context
 * @param skb  Received packet (eth_type_trans already called by moal_recv_packet)
 *
 * @return 1 if skb consumed (forwarded or freed), 0 if caller should deliver to stack
 *
 * Plan SC: SC-01 (WLAN→ETH 포워딩), SC-02 (자기 IP는 커널 스택으로)
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

	if (!br || !skb)
		return 0;

	eth = (struct ethhdr *)skb->data;
	proto = eth->h_proto;

	/* media_connected check */
	if (!((moal_private *)br->wlan_priv)->media_connected)
		return 0;

	/* EAPOL: never forward */
	if (proto == htons(ETH_P_PAE))
		return 0;

	/* VLAN: extract inner proto */
	if (proto == htons(ETH_P_8021Q)) {
		if (skb->len < VLAN_ETH_HLEN)
			return 0;
		proto = ((struct vlan_hdr *)(skb->data + ETH_HLEN))->
			h_vlan_encapsulated_proto;
	}

	/* clone→비동기 forward + 원본→커널.
	 * 모든 패킷에 대해 clone+tasklet: 안정적이고 검증된 방식. */
	{
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
		if (skb2) {
			skb2->dev = br->peer_dev;
			skb_queue_tail(&br->fwd_queue, skb2);
			tasklet_schedule(&br->fwd_tasklet);
			atomic_long_inc(&br->wlan_to_peer.fwd_packets);
		}
	}
	return 0; /* 원본은 커널 스택으로 */
}

/**
 * moal_bridge_rx - WLAN RX legacy path (after eth_type_trans, kept for reference)
 */
int moal_bridge_rx(struct moal_bridge *br, struct sk_buff *skb)
{
	struct ethhdr *eth;

	if (!br || !skb)
		return 0;

	eth = eth_hdr(skb);
	BR_DBG("w2p RX " MACSTR " -> " MACSTR " proto=0x%04x len=%d\n",
	       MAC2STR(eth->h_source), MAC2STR(eth->h_dest),
	       ntohs(skb->protocol), skb->len);

	if (!moal_bridge_should_forward(br, skb)) {
		atomic_long_inc(&br->wlan_to_peer.dropped);
		BR_DBG(" w2p drop " MACSTR " -> " MACSTR
		       " proto=0x%04x\n",
		       MAC2STR(eth->h_source), MAC2STR(eth->h_dest),
		       ntohs(skb->protocol));
		return 0; /* 커널 스택으로 전달 */
	}

	/* 멀티캐스트: clone 후 peer로 포워딩, 원본은 커널 스택으로
	 * Design Ref: §7.3 — 멀티캐스트 패킷 처리 */
	if (is_multicast_ether_addr(eth->h_dest)) {
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);

		if (skb2) {
			skb2->dev = br->peer_dev;
			skb_push(skb2, ETH_HLEN);
			dev_queue_xmit(skb2);
			atomic_long_inc(&br->wlan_to_peer.fwd_packets);
			atomic_long_add(skb->len, &br->wlan_to_peer.fwd_bytes);
			BR_DBG(" w2p mcast " MACSTR " -> "
			       MACSTR " len=%d\n",
			       MAC2STR(eth->h_source), MAC2STR(eth->h_dest),
			       skb->len);
		}
		return 0; /* 원본은 커널 스택으로 */
	}

	BR_DBG(" w2p fwd " MACSTR " -> " MACSTR
	       " proto=0x%04x len=%d\n",
	       MAC2STR(eth->h_source), MAC2STR(eth->h_dest),
	       ntohs(skb->protocol), skb->len);

	/* 유니캐스트: skb 소유권 이전하여 peer로 포워딩 */
	skb->dev = br->peer_dev;
	skb_push(skb, ETH_HLEN);

	if (dev_queue_xmit(skb) != NET_XMIT_SUCCESS) {
		atomic_long_inc(&br->wlan_to_peer.errors);
		PRINTM(MERROR, "bridge: w2p xmit failed\n");
	} else {
		atomic_long_inc(&br->wlan_to_peer.fwd_packets);
		atomic_long_add(skb->len, &br->wlan_to_peer.fwd_bytes);
	}

	return 1; /* skb consumed */
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

	/* media_connected check */
	if (!((moal_private *)br->wlan_priv)->media_connected)
		return RX_HANDLER_PASS;

	/* EAPOL: never forward */
	if (skb->protocol == htons(ETH_P_PAE))
		return RX_HANDLER_PASS;

	/* clone→비동기 forward + 원본→커널 */
	{
		struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
		if (skb2) {
			skb2->dev = br->wlan_dev;
			skb_push(skb2, ETH_HLEN);
			skb_queue_tail(&br->fwd_queue, skb2);
			tasklet_schedule(&br->fwd_tasklet);
			atomic_long_inc(&br->peer_to_wlan.fwd_packets);
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

	/* media_connected + EAPOL check */
	if (!((moal_private *)br->wlan_priv)->media_connected ||
	    skb->protocol == htons(ETH_P_PAE)) {
		kfree_skb(skb);
		return 0;
	}

	/* packet_type은 clone을 받으므로 비동기 forward */
	skb->dev = br->wlan_dev;
	skb_push(skb, ETH_HLEN);
	skb_queue_tail(&br->fwd_queue, skb);
	tasklet_schedule(&br->fwd_tasklet);
	atomic_long_inc(&br->peer_to_wlan.fwd_packets);

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
	struct net_device *dev = ifa->ifa_dev->dev;
	struct moal_bridge *br = container_of(nb, struct moal_bridge, inet_nb);

	if (dev == br->wlan_dev) {
		br->wlan_ipv4 = ifa->ifa_local;
		PRINTM(MMSG, "bridge: wlan IPv4 updated = %pI4\n",
		       &br->wlan_ipv4);
	} else if (dev == br->peer_dev) {
		br->peer_ipv4 = ifa->ifa_local;
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
		break;
	case NETDEV_UP:
		PRINTM(MMSG, "bridge: peer '%s' came up, resuming\n",
		       dev->name);
		/* IPv4 재캐시 (DHCP로 IP 변경 가능) */
		br->peer_ipv4 = moal_bridge_get_ipv4(br->peer_dev);
		br->wlan_ipv4 = moal_bridge_get_ipv4(br->wlan_dev);
		atomic_set(&br->active, 1);
		break;
	case NETDEV_UNREGISTER:
		PRINTM(MMSG, "bridge: peer '%s' unregistered, disabling\n",
		       dev->name);
		atomic_set(&br->active, 0);
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
		PRINTM(MMSG, "bridge: skipped (another instance already active)\n");
		return 0;
	}

	/* 1. wlan netdev 확인 — DBDC: bridge_wlan_idx로 BSS 선택 */
	if (wlan_bss_idx < 0 || wlan_bss_idx >= MLAN_MAX_BSS_NUM ||
	    !handle->priv[wlan_bss_idx] ||
	    !handle->priv[wlan_bss_idx]->netdev) {
		PRINTM(MERROR, "bridge: wlan BSS[%d] not ready\n", wlan_bss_idx);
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

	/* Async forward queue + tasklet 초기화 */
	skb_queue_head_init(&br->fwd_queue);
	tasklet_init(&br->fwd_tasklet, moal_bridge_fwd_tasklet,
		     (unsigned long)br);

	/* MAC 주소 캐시 */
	ether_addr_copy(br->wlan_mac, br->wlan_dev->dev_addr);
	ether_addr_copy(br->peer_mac, br->peer_dev->dev_addr);

	/* IPv4 주소 캐시 */
	br->wlan_ipv4 = moal_bridge_get_ipv4(br->wlan_dev);
	br->peer_ipv4 = moal_bridge_get_ipv4(br->peer_dev);

	/* 5a. peer(eth0) promiscuous 모드 활성화 — 클라이언트 패킷 수신 필수
	 * wbridge도 pcap_open(promisc=1)로 동일하게 활성화함 */
	dev_set_promiscuity(peer, 1);

	/* 5b. ETH→WLAN: rx_handler 시도, 실패 시 packet_type fallback */
	br->use_packet_type = 0;
	rtnl_lock();
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

	/* 7. 활성화 */
	handle->bridge = br;
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

	/* 1. 포워딩 비활성화 (새 패킷 차단) */
	atomic_set(&br->active, 0);

	/* 2. notifier 해제 */
	unregister_inetaddr_notifier(&br->inet_nb);
	unregister_netdevice_notifier(&br->netdev_nb);

	/* 3. ETH→WLAN 경로 해제 */
	if (br->use_packet_type) {
		dev_remove_pack(&br->peer_pt);
	} else {
		rtnl_lock();
		netdev_rx_handler_unregister(br->peer_dev);
		rtnl_unlock();
	}

	/* 4. tasklet 중지 + 큐 비우기 */
	tasklet_kill(&br->fwd_tasklet);
	skb_queue_purge(&br->fwd_queue);

	/* 5. 진행 중인 패킷 완료 대기 */
	synchronize_net();

	/* 5. 통계 출력 */
	PRINTM(MMSG, "bridge: %s <-> %s deactivated\n",
	       br->wlan_dev->name, br->peer_dev->name);
	PRINTM(MMSG, "bridge: w2p fwd=%ld drop=%ld err=%ld\n",
	       atomic_long_read(&br->wlan_to_peer.fwd_packets),
	       atomic_long_read(&br->wlan_to_peer.dropped),
	       atomic_long_read(&br->wlan_to_peer.errors));
	PRINTM(MMSG, "bridge: p2w fwd=%ld drop=%ld err=%ld\n",
	       atomic_long_read(&br->peer_to_wlan.fwd_packets),
	       atomic_long_read(&br->peer_to_wlan.dropped),
	       atomic_long_read(&br->peer_to_wlan.errors));

	/* 6. peer promiscuous 해제 */
	dev_set_promiscuity(br->peer_dev, -1);

	/* 7. peer 참조 반환 + 메모리 해제 */
	handle->bridge = NULL;
	dev_put(br->peer_dev);
	kfree(br);

	/* 7. DBDC guard 해제 */
	atomic_set(&bridge_instance_active, 0);
}
