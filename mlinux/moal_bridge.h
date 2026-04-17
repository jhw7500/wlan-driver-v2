/** @file moal_bridge.h
 *
 * @brief L2 bridge between WLAN and peer (eth) interface
 *
 * Design Ref: §2 — Data Structures, Option C (Pragmatic Balance)
 *
 * Copyright 2026
 */

#ifndef _MOAL_BRIDGE_H_
#define _MOAL_BRIDGE_H_

#include <linux/netdevice.h>
#include <linux/if_ether.h>
#include <linux/if_vlan.h>
#include <linux/ip.h>
#include <linux/if_arp.h>
#include <linux/atomic.h>
#include <linux/inetdevice.h>
#include <linux/workqueue.h>
#include <linux/kthread.h>
#include <linux/wait.h>
#include <linux/hrtimer.h>

#define MOAL_BR_W2P_QUEUE_MAX 512
#define MOAL_BR_P2W_QUEUE_MAX 512

/** Bridge statistics per direction */
struct moal_bridge_stats {
	atomic_long_t fwd_packets;   /**< Successfully forwarded */
	atomic_long_t fwd_bytes;     /**< Forwarded bytes */
	atomic_long_t dropped;       /**< Filtered/dropped */
	atomic_long_t errors;        /**< Forward failures */
};

/** Bridge context — one per moal_handle */
struct moal_bridge {
	struct net_device *wlan_dev;  /**< wlan netdev (owned by moal) */
	struct net_device *peer_dev;  /**< peer netdev (eth0, dev_hold'd) */
	void *wlan_priv;             /**< moal_private* for media_connected check */
	atomic_t active;             /**< 1 = bridge forwarding active */

	/** Filter context — populated from wlan_dev/peer_dev at init */
	u8 wlan_mac[ETH_ALEN];
	u8 peer_mac[ETH_ALEN];
	__be32 wlan_ipv4;            /**< wlan IPv4 (network order) */
	__be32 peer_ipv4;            /**< peer IPv4 (network order) */

	/** Per-direction stats */
	struct moal_bridge_stats wlan_to_peer;  /**< WLAN→ETH */
	struct moal_bridge_stats peer_to_wlan;  /**< ETH→WLAN */

	/** w2p (WLAN→ETH) */
	struct sk_buff_head w2p_queue;
	struct task_struct *w2p_thread;
	wait_queue_head_t w2p_wait;

	/** p2w (ETH→WLAN): 전용 kthread — SDIO TX 지연을 w2p와 격리 */
	struct sk_buff_head p2w_queue;
	struct task_struct *p2w_thread;
	wait_queue_head_t p2w_wait;

	/** ETH→WLAN capture method:
	 *  0 = rx_handler (preferred, via netdev_rx_handler_register)
	 *  1 = packet_type (fallback, via dev_add_pack — when rx_handler busy)
	 */
	int use_packet_type;
	struct packet_type peer_pt;  /**< packet_type for fallback mode */

	/** Notifier for peer netdev events (DOWN/UNREGISTER) */
	struct notifier_block netdev_nb;
	/** Notifier for IPv4 address changes (DHCP 완료 감지) */
	struct notifier_block inet_nb;

	/** Keepalive timer: 주기적으로 드라이버 main_work를 깨워서
	 *  SDIO 처리 루프를 warm 유지 (pcap RT polling 효과 재현) */
	struct hrtimer keepalive_timer;

	/** Back-pointer to moal_handle */
	void *handle;
};

/* API — implemented in moal_bridge.c */
int moal_bridge_init(void *handle, const char *peer_name, int wlan_bss_idx);
void moal_bridge_deinit(void *handle);
int moal_bridge_rx(struct moal_bridge *br, struct sk_buff *skb);
int moal_bridge_rx_fast(struct moal_bridge *br, struct sk_buff *skb, void *priv);

#endif /* _MOAL_BRIDGE_H_ */
