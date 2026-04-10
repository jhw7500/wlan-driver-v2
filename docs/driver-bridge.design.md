# driver-bridge Design Document

> **Summary**: wlan-driver-v2 MOAL 레이어에 커널 레벨 L2 브릿지 구현 — Option C (Pragmatic Balance)
>
> **Project**: wlan-driver-v2 (NXP 88Q9098 WLAN Driver)
> **Target**: iMX8MP / iMX93
> **Author**: jhw
> **Date**: 2026-04-09
> **Status**: Draft
> **Architecture**: Option C — Pragmatic Balance (moal_bridge.c/h 분리 + rx_handler)

---

## Context Anchor

| Key | Value |
|-----|-------|
| **WHY** | 유저스페이스 pcap 브릿지의 컨텍스트 스위칭/메모리 복사 오버헤드로 성능 한계 |
| **WHO** | iMX8MP/iMX93 유무선 브릿지 배포 환경 |
| **RISK** | MOAL 레이어 수정으로 드라이버 안정성 영향 가능. 브릿지 버그 시 커널 패닉 위험 |
| **SUCCESS** | 브릿지 모드 로드 후 ETH↔WLAN 양방향 L2 포워딩 동작, 기존 wbridge 대비 지연시간 감소 확인 |
| **SCOPE** | MOAL 레이어 신규 2파일 + 수정 4파일, ~350줄 추가 |

---

## 1. Overview

### 1.1 선택된 아키텍처: Option C — Pragmatic Balance

**핵심 원칙**:
- 브릿지 로직을 `moal_bridge.c/h`로 분리하여 기존 드라이버 코드 오염 최소화
- ETH→WLAN 방향은 커널 표준 API `netdev_rx_handler_register()` 사용
- WLAN→ETH 방향은 `moal_recv_packet()`에 1줄 분기만 추가
- 과도한 추상화 없이 실용적으로 구현

### 1.2 아키텍처 다이어그램

```
┌─────────────────────────────────────────────────────────────┐
│ Kernel                                                      │
│                                                             │
│  ┌──────────┐                            ┌──────────────┐  │
│  │  eth0    │                            │  moal (wlan0) │  │
│  │  driver  │                            │  driver       │  │
│  └────┬─────┘                            └──────┬───────┘  │
│       │                                         │           │
│       │  rx_handler                             │           │
│       │  (registered by moal_bridge)            │           │
│       ▼                                         ▼           │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              moal_bridge.c                           │  │
│  │                                                      │  │
│  │  moal_bridge_peer_rx_handler()                       │  │
│  │    ETH RX → should_forward? → wlan dev_queue_xmit   │  │
│  │                                                      │  │
│  │  moal_bridge_rx()                                    │  │
│  │    WLAN RX → should_forward? → eth dev_queue_xmit   │  │
│  │                                                      │  │
│  │  moal_bridge_should_forward()                        │  │
│  │    MAC/IP/ARP/VLAN filter (from wbridge filter.c)    │  │
│  └──────────────────────────────────────────────────────┘  │
│       │                                         │           │
│       ▼ (self-destined only)                    ▼           │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Kernel Network Stack                     │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Data Structures

### 2.1 브릿지 컨텍스트 (`moal_bridge.h`)

```c
#ifndef _MOAL_BRIDGE_H_
#define _MOAL_BRIDGE_H_

#include <linux/netdevice.h>
#include <linux/if_ether.h>
#include <linux/if_vlan.h>
#include <linux/ip.h>
#include <linux/if_arp.h>
#include <linux/atomic.h>

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
	atomic_t active;             /**< 1 = bridge forwarding active */

	/** Filter context — populated from wlan_dev/peer_dev at init */
	u8 wlan_mac[ETH_ALEN];
	u8 peer_mac[ETH_ALEN];
	__be32 wlan_ipv4;            /**< wlan IPv4 (network order) */
	__be32 peer_ipv4;            /**< peer IPv4 (network order) */

	/** Per-direction stats */
	struct moal_bridge_stats wlan_to_peer;  /**< WLAN→ETH */
	struct moal_bridge_stats peer_to_wlan;  /**< ETH→WLAN */

	/** Notifier for peer netdev events (DOWN/UNREGISTER) */
	struct notifier_block netdev_nb;

	/** Back-pointer to moal_handle */
	void *handle;
};

/* API */
int moal_bridge_init(void *handle, const char *peer_name);
void moal_bridge_deinit(void *handle);
int moal_bridge_rx(struct moal_bridge *br, struct sk_buff *skb);

#endif /* _MOAL_BRIDGE_H_ */
```

### 2.2 moal_handle 확장

```c
/* moal_main.h — struct _moal_handle 에 추가 */
struct _moal_handle {
    /* ... 기존 필드 ... */

    /** L2 bridge context (NULL when bridge_mode=0) */
    struct moal_bridge *bridge;
};
```

---

## 3. Module Parameters

### 3.1 파라미터 정의

기존 드라이버 패턴(`moal_init.c`)을 따라 정의:

```c
/* moal_init.c — 기존 module_param 블록 뒤에 추가 */
static int bridge_mode = 0;
module_param(bridge_mode, int, 0);
MODULE_PARM_DESC(bridge_mode,
    "L2 bridge mode: 0=off(default), 1=on");

static char *bridge_peer = "eth0";
module_param(bridge_peer, charp, 0);
MODULE_PARM_DESC(bridge_peer,
    "Bridge peer interface name (default: eth0)");
```

**참고**: 기존 드라이버의 모듈 파라미터 퍼미션은 `0` (로드 시에만 설정). `net_rx` 등 기존 파라미터와 동일한 패턴.

### 3.2 사용 예시

```bash
# 브릿지 활성화
insmod moal.ko bridge_mode=1 bridge_peer=eth0

# 브릿지 비활성화 (기존 동작)
insmod moal.ko
# 또는
insmod moal.ko bridge_mode=0
```

---

## 4. Packet Flow — Detailed

### 4.1 WLAN→ETH 방향

**위치**: `moal_shim.c::moal_recv_packet()` — 기존 `netif_rx()`/`netif_receive_skb()` 호출 직전

```
moal_recv_packet()
  │
  ├── (기존 처리: skb 준비, EAPOL 검사, 필터링, stats 등)
  │
  ├── [NEW] if (handle->bridge && atomic_read(&handle->bridge->active))
  │         └── ret = moal_bridge_rx(handle->bridge, skb)
  │             ├── should_forward(skb)?
  │             │   ├── YES → skb->dev = peer_dev
  │             │   │         dev_queue_xmit(skb) → goto done
  │             │   └── NO  → return 0 (fallthrough to netif_rx)
  │
  └── (기존 경로: netif_rx / netif_receive_skb)
```

**삽입 지점**: `moal_shim.c:2507` — `priv->stats.rx_packets++` 이후, `netif_rx(skb)` 이전

**핵심 원칙**:
- `eth_type_trans()` 호출 이후 삽입 (skb->protocol 설정 완료 상태)
- `woal_filter_packet()` 이후 삽입 (드라이버 자체 필터링 완료)
- `priv->stats` 업데이트 이후 (wlan RX 통계는 정상 집계)
- skb 소유권: `moal_bridge_rx()`가 1을 반환하면 skb 소유권 이전됨 (caller는 free하지 않음)

### 4.2 ETH→WLAN 방향

**메커니즘**: `netdev_rx_handler_register()`로 peer_dev(eth0)에 rx_handler 등록

```
eth0 NIC RX
  │
  ├── eth0 driver → napi_gro_receive / netif_receive_skb
  │
  ├── __netif_receive_skb_core()
  │     └── rx_handler (moal_bridge_peer_rx_handler)
  │         ├── should_forward(skb)?
  │         │   ├── YES → skb->dev = wlan_dev
  │         │   │         dev_queue_xmit(skb)
  │         │   │         return RX_HANDLER_CONSUMED
  │         │   └── NO  → return RX_HANDLER_PASS
  │
  └── (커널 스택으로 정상 전달)
```

**rx_handler 반환값**:
- `RX_HANDLER_CONSUMED`: 패킷을 브릿지가 처리함. 커널 스택으로 가지 않음
- `RX_HANDLER_PASS`: 패킷을 브릿지가 무시. 커널 스택으로 정상 전달

**dev_queue_xmit vs woal_hard_start_xmit**:
- `dev_queue_xmit(skb)`를 사용 — 커널 qdisc를 거쳐 `ndo_start_xmit`(`woal_hard_start_xmit`) 호출
- 직접 `woal_hard_start_xmit()` 호출은 qdisc bypass + 잠금 문제 위험 → 사용하지 않음

### 4.3 루프 방지

```
패킷 루프 시나리오:
  eth0 RX → bridge → wlan0 TX → FW → wlan0 RX → bridge → eth0 TX → eth0 RX → ...

방지책:
  1. WLAN→ETH: moal_bridge_rx()에서 포워딩한 패킷은 WLAN RX에서 이미 소비됨 (netif_rx 미호출)
  2. ETH→WLAN: rx_handler에서 포워딩한 패킷은 RX_HANDLER_CONSUMED (eth 커널스택 미전달)
  3. 추가 안전장치: 자기가 TX한 패킷이 RX로 돌아오는 경우 dst MAC = self → should_forward = NO
```

---

## 5. Filter Logic

### 5.1 should_forward 판정 로직

wbridge `filter.c`의 검증된 로직을 커널 API로 이식:

```c
/**
 * moal_bridge_should_forward - 패킷을 peer로 포워딩할지 판정
 * @br: bridge context
 * @skb: 수신된 패킷 (eth_type_trans 완료 상태)
 * @from_wlan: true=WLAN에서 수신, false=ETH에서 수신
 *
 * Return: true=포워딩, false=커널 스택으로 전달
 *
 * Design Ref: wbridge filter.c::filter_should_drop() 역논리
 */
static bool moal_bridge_should_forward(struct moal_bridge *br,
                                       struct sk_buff *skb,
                                       bool from_wlan)
{
    struct ethhdr *eth = eth_hdr(skb);
    __be16 proto;

    /* 1. EtherType 추출 (VLAN 태그 투명 처리) */
    proto = eth->h_proto;
    if (proto == htons(ETH_P_8021Q)) {
        /* VLAN: 내부 프로토콜 추출 (skb 데이터는 수정하지 않음) */
        if (skb->len < VLAN_ETH_HLEN)
            return false;
        struct vlan_hdr *vhdr = (struct vlan_hdr *)(skb->data +
                                                     ETH_HLEN);
        proto = vhdr->h_vlan_encapsulated_proto;
    }

    /* 2. 멀티캐스트/브로드캐스트 */
    if (is_multicast_ether_addr(eth->h_dest)) {
        /* ARP for bridge IP → 커널이 응답해야 함 */
        if (proto == htons(ETH_P_ARP) &&
            moal_bridge_arp_is_for_self(br, skb))
            return false;
        /* 나머지 멀티캐스트/브로드캐스트 → 포워딩 */
        return true;
    }

    /* 3. 유니캐스트: 자기/peer MAC 대상 → 커널 스택으로 */
    if (ether_addr_equal(eth->h_dest, br->wlan_mac) ||
        ether_addr_equal(eth->h_dest, br->peer_mac))
        return false;

    /* 4. 유니캐스트: 자기 IP 대상 → 커널 스택으로 */
    if (proto == htons(ETH_P_IP) &&
        moal_bridge_ip_is_local(br, skb))
        return false;

    /* 5. 그 외 → 포워딩 */
    return true;
}
```

### 5.2 ARP 판정

```c
/**
 * moal_bridge_arp_is_for_self - ARP target IP가 자기 IP인지 확인
 * Design Ref: wbridge filter.c::filter_arp_is_for_bridge()
 */
static bool moal_bridge_arp_is_for_self(struct moal_bridge *br,
                                         struct sk_buff *skb)
{
    struct arphdr *arp;
    unsigned char *arp_ptr;
    __be32 target_ip;

    if (skb->len < ETH_HLEN + sizeof(struct arphdr) + 20)
        return false;

    arp = (struct arphdr *)(skb->data + ETH_HLEN);
    if (arp->ar_hrd != htons(ARPHRD_ETHER) ||
        arp->ar_pro != htons(ETH_P_IP) ||
        arp->ar_hln != ETH_ALEN ||
        arp->ar_pln != 4)
        return false;

    /* target IP: offset = arphdr(8) + sender_mac(6) + sender_ip(4)
     *            + target_mac(6) = 24 */
    arp_ptr = (unsigned char *)(arp + 1);
    memcpy(&target_ip, arp_ptr + 16, 4);

    return (target_ip == br->wlan_ipv4 ||
            target_ip == br->peer_ipv4);
}
```

### 5.3 IP 판정

```c
/**
 * moal_bridge_ip_is_local - IPv4 destination이 자기 IP인지 확인
 * Design Ref: wbridge filter.c::filter_ip_is_local()
 */
static bool moal_bridge_ip_is_local(struct moal_bridge *br,
                                     struct sk_buff *skb)
{
    struct iphdr *iph;

    if (skb->len < ETH_HLEN + sizeof(struct iphdr))
        return false;

    iph = (struct iphdr *)(skb->data + ETH_HLEN);

    /* IPv4 멀티캐스트(224.0.0.0/4)는 로컬이 아님 */
    if (ipv4_is_multicast(iph->daddr))
        return false;

    return (iph->daddr == br->wlan_ipv4 ||
            iph->daddr == br->peer_ipv4);
}
```

---

## 6. Lifecycle Management

### 6.1 초기화 (`moal_bridge_init`)

**호출 시점**: `moal_main.c::woal_init_sw()` 또는 `woal_register_dev()` — wlan netdev 등록 완료 후

```c
int moal_bridge_init(void *phandle, const char *peer_name)
{
    moal_handle *handle = (moal_handle *)phandle;
    struct moal_bridge *br;
    struct net_device *peer;
    int ret;

    /* 1. peer netdev 검색 */
    peer = dev_get_by_name(&init_net, peer_name);
    if (!peer) {
        PRINTM(MERROR, "bridge: peer interface '%s' not found\n",
               peer_name);
        return -ENODEV;
    }
    /* dev_get_by_name()이 dev_hold() 해줌 */

    /* 2. bridge context 할당 */
    br = kzalloc(sizeof(*br), GFP_KERNEL);
    if (!br) {
        dev_put(peer);
        return -ENOMEM;
    }

    /* 3. 초기화 */
    br->peer_dev = peer;
    br->wlan_dev = handle->priv[0]->netdev;  /* 첫 번째 BSS */
    br->handle = handle;
    atomic_set(&br->active, 0);

    /* MAC 주소 캐시 */
    ether_addr_copy(br->wlan_mac, br->wlan_dev->dev_addr);
    ether_addr_copy(br->peer_mac, br->peer_dev->dev_addr);

    /* IPv4 주소 캐시 (inet_select_addr) */
    br->wlan_ipv4 = moal_bridge_get_ipv4(br->wlan_dev);
    br->peer_ipv4 = moal_bridge_get_ipv4(br->peer_dev);

    /* 4. ETH→WLAN rx_handler 등록 */
    rtnl_lock();
    ret = netdev_rx_handler_register(peer,
                                     moal_bridge_peer_rx_handler,
                                     br);
    rtnl_unlock();
    if (ret) {
        PRINTM(MERROR, "bridge: failed to register rx_handler "
               "on '%s' (err=%d)\n", peer_name, ret);
        dev_put(peer);
        kfree(br);
        return ret;
    }

    /* 5. netdev notifier 등록 (peer down/unregister 감지) */
    br->netdev_nb.notifier_call = moal_bridge_netdev_event;
    register_netdevice_notifier(&br->netdev_nb);

    /* 6. 활성화 */
    handle->bridge = br;
    atomic_set(&br->active, 1);

    PRINTM(MMSG, "bridge: %s <-> %s bridge activated\n",
           br->wlan_dev->name, br->peer_dev->name);
    return 0;
}
```

### 6.2 해제 (`moal_bridge_deinit`)

**호출 시점**: `moal_main.c::woal_free_moal_handle()` 또는 `woal_remove_card()` — 드라이버 언로드 시

```c
void moal_bridge_deinit(void *phandle)
{
    moal_handle *handle = (moal_handle *)phandle;
    struct moal_bridge *br = handle->bridge;

    if (!br)
        return;

    /* 1. 포워딩 비활성화 (새 패킷 차단) */
    atomic_set(&br->active, 0);

    /* 2. notifier 해제 */
    unregister_netdevice_notifier(&br->netdev_nb);

    /* 3. rx_handler 해제 */
    rtnl_lock();
    netdev_rx_handler_unregister(br->peer_dev);
    rtnl_unlock();

    /* 4. 진행 중인 패킷 완료 대기 */
    synchronize_net();

    /* 5. peer 참조 반환 */
    dev_put(br->peer_dev);

    /* 6. 통계 출력 */
    PRINTM(MMSG, "bridge: stats w2p fwd=%ld drop=%ld err=%ld\n",
           atomic_long_read(&br->wlan_to_peer.fwd_packets),
           atomic_long_read(&br->wlan_to_peer.dropped),
           atomic_long_read(&br->wlan_to_peer.errors));
    PRINTM(MMSG, "bridge: stats p2w fwd=%ld drop=%ld err=%ld\n",
           atomic_long_read(&br->peer_to_wlan.fwd_packets),
           atomic_long_read(&br->peer_to_wlan.dropped),
           atomic_long_read(&br->peer_to_wlan.errors));

    /* 7. 자원 해제 */
    handle->bridge = NULL;
    kfree(br);
}
```

### 6.3 Netdev Notifier (peer down/unregister 감지)

```c
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
        PRINTM(MMSG, "bridge: peer '%s' went down, "
               "suspending bridge\n", dev->name);
        atomic_set(&br->active, 0);
        break;
    case NETDEV_UP:
        PRINTM(MMSG, "bridge: peer '%s' came up, "
               "resuming bridge\n", dev->name);
        /* IPv4 재캐시 (DHCP로 IP 변경 가능) */
        br->peer_ipv4 = moal_bridge_get_ipv4(br->peer_dev);
        br->wlan_ipv4 = moal_bridge_get_ipv4(br->wlan_dev);
        atomic_set(&br->active, 1);
        break;
    case NETDEV_UNREGISTER:
        PRINTM(MMSG, "bridge: peer '%s' unregistered, "
               "disabling bridge\n", dev->name);
        atomic_set(&br->active, 0);
        break;
    }
    return NOTIFY_DONE;
}
```

---

## 7. Concurrency & Safety

### 7.1 동시성 모델

| 경로 | 컨텍스트 | 보호 |
|------|----------|------|
| WLAN→ETH (moal_bridge_rx) | softirq / workqueue | atomic_read(&br->active) 체크 |
| ETH→WLAN (peer_rx_handler) | softirq (NAPI) | atomic_read(&br->active) 체크 |
| bridge init/deinit | process context | rtnl_lock, synchronize_net |
| netdev notifier | process context | atomic_set(&br->active) |

### 7.2 skb 소유권 규칙

| 시나리오 | 소유권 | 설명 |
|----------|--------|------|
| WLAN→ETH 포워딩 성공 | `dev_queue_xmit()`가 소유 | caller는 skb를 touch하지 않음 |
| WLAN→ETH 포워딩 거부 | caller(moal_recv_packet)가 소유 | 기존 netif_rx 경로로 진행 |
| ETH→WLAN 포워딩 성공 | `dev_queue_xmit()`가 소유 | RX_HANDLER_CONSUMED 반환 |
| ETH→WLAN 포워딩 거부 | 커널 스택이 소유 | RX_HANDLER_PASS 반환 |
| 포워딩 실패 (dev_queue_xmit 에러) | 함수 내에서 kfree_skb | stats.errors 증가 |

### 7.3 멀티캐스트 패킷 처리

멀티캐스트/브로드캐스트 패킷은 peer로 포워딩 **하면서** 동시에 로컬 커널 스택에도 전달해야 함:

```c
/* 멀티캐스트: clone 후 양쪽에 전달 */
if (is_multicast_ether_addr(eth_hdr(skb)->h_dest) && should_forward) {
    struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
    if (skb2) {
        skb2->dev = peer_dev;
        dev_queue_xmit(skb2);   /* peer로 포워딩 */
        stats->fwd_packets++;
    }
    return 0;  /* 원본 skb는 커널 스택으로 (caller가 netif_rx) */
}
```

### 7.4 해제 순서 (rmmod 안전)

```
1. atomic_set(&br->active, 0)          — 새 패킷 차단
2. unregister_netdevice_notifier()      — 이벤트 수신 중지
3. netdev_rx_handler_unregister()       — ETH→WLAN 경로 해제
4. synchronize_net()                    — 진행 중인 softirq 완료 대기
5. dev_put(peer_dev)                    — peer 참조 반환
6. kfree(br)                           — 메모리 해제
```

---

## 8. File Changes

### 8.1 신규 파일

| 파일 | 목적 | 예상 줄수 |
|------|------|-----------|
| `mlinux/moal_bridge.h` | 데이터 구조, API 선언 | ~60줄 |
| `mlinux/moal_bridge.c` | 브릿지 코어 로직 전체 | ~280줄 |

### 8.2 수정 파일

| 파일 | 변경 내용 | 예상 줄수 |
|------|-----------|-----------|
| `mlinux/moal_main.h` | `struct _moal_handle`에 `struct moal_bridge *bridge` 추가 | +3줄 |
| `mlinux/moal_init.c` | `bridge_mode`, `bridge_peer` 모듈 파라미터 등록 | +8줄 |
| `mlinux/moal_main.c` | init에서 `moal_bridge_init()` 호출, cleanup에서 `moal_bridge_deinit()` 호출 | +12줄 |
| `mlinux/moal_shim.c` | `moal_recv_packet()`에 bridge forward 분기 1개 추가 | +10줄 |
| `Makefile` | `MOALOBJS += mlinux/moal_bridge.o` | +1줄 |

### 8.3 수정 상세

#### moal_main.h (moal_handle 확장)

```c
/* struct _moal_handle 내부, mgmt_log 필드 근처에 추가 */
/** L2 bridge context (NULL when bridge_mode=0) */
struct moal_bridge *bridge;
```

#### moal_init.c (모듈 파라미터)

```c
/* net_rx module_param 근처에 추가 */
static int bridge_mode;
module_param(bridge_mode, int, 0);
MODULE_PARM_DESC(bridge_mode, "L2 bridge: 0=off(default), 1=on");
static char *bridge_peer = "eth0";
module_param(bridge_peer, charp, 0);
MODULE_PARM_DESC(bridge_peer, "Bridge peer interface (default: eth0)");
```

#### moal_main.c (init/cleanup 호출)

```c
/* woal_init_sw() 또는 woal_register_dev() 말미에 추가 */
if (bridge_mode) {
    extern int bridge_mode;
    extern char *bridge_peer;
    ret = moal_bridge_init(handle, bridge_peer);
    if (ret)
        PRINTM(MERROR, "bridge init failed: %d\n", ret);
}

/* woal_free_moal_handle() 또는 woal_remove_card() 초반에 추가 */
moal_bridge_deinit(handle);
```

#### moal_shim.c (브릿지 분기)

```c
/* moal_recv_packet() 내부, priv->stats.rx_packets++ 이후,
   netif_rx(skb) 이전에 삽입 */
/* L2 bridge forward */
if (unlikely(handle->bridge) &&
    atomic_read(&handle->bridge->active) &&
    moal_bridge_rx(handle->bridge, skb)) {
    /* skb consumed by bridge */
    goto done;
}
```

#### Makefile

```makefile
# MOALOBJS 블록에 추가 (moal_init.o 다음)
MOALOBJS += mlinux/moal_bridge.o
```

---

## 9. Test Plan

### 9.1 단위 테스트 (타겟 보드)

| ID | 테스트 | 검증 방법 | SC |
|----|--------|-----------|-----|
| T-01 | bridge_mode=0 로드 | 기존 Wi-Fi 연결 정상 | SC-04 |
| T-02 | bridge_mode=1 로드 | dmesg에 "bridge activated" 출력 | — |
| T-03 | WLAN→ETH ping | 무선 클라이언트에서 유선 호스트 ping | SC-01 |
| T-04 | ETH→WLAN ping | 유선 호스트에서 무선 클라이언트 ping | SC-01 |
| T-05 | 자기 IP ssh | 브릿지 자체 IP로 ssh 접속 | SC-02 |
| T-06 | ARP 정상 동작 | 브릿지 IP의 ARP reply 정상 | SC-02 |
| T-07 | VLAN 투명 전달 | VLAN 태그 패킷 양방향 포워딩 | SC-03 |
| T-08 | rmmod 정상 | rmmod moal 후 lsmod 확인 | SC-06 |
| T-09 | rmmod 반복 | 50회 insmod/rmmod 반복 | SC-06 |
| T-10 | peer down/up | eth0 down→up 시 브릿지 복구 | NFR-06 |

### 9.2 성능 테스트

| ID | 테스트 | 측정 도구 | SC |
|----|--------|-----------|-----|
| P-01 | TCP throughput | iperf3 -t 60 | — |
| P-02 | UDP throughput | iperf3 -u -b 100M | — |
| P-03 | Latency | ping -c 1000 | — |
| P-04 | CPU 사용량 | mpstat 1 60 | SC-05 |
| P-05 | wbridge 대비 비교 | P-01~P-04 결과 비교 | SC-05 |

### 9.3 안정성 테스트

| ID | 테스트 | 방법 |
|----|--------|------|
| S-01 | 장시간 운용 | iperf3 TCP 8시간 연속 |
| S-02 | UDP flood | iperf3 -u -b 0 (최대 속도) 10분 |
| S-03 | 브로드캐스트 스톰 | tcpreplay로 브로드캐스트 패킷 대량 송출 |
| S-04 | peer 존재하지 않는 상태 | bridge_peer=eth99로 로드 → 에러 처리 |

---

## 10. Error Handling

| 에러 상황 | 처리 |
|-----------|------|
| peer 인터페이스 없음 | `moal_bridge_init()` 실패 → `PRINTM(MERROR)`, bridge=NULL, 드라이버 정상 로드 |
| rx_handler 등록 실패 (이미 등록됨) | init 실패 → 에러 로그, bridge 비활성 |
| dev_queue_xmit 실패 | stats.errors++, skb는 kfree_skb |
| skb_clone 실패 (멀티캐스트) | 포워딩 스킵, 로컬 전달만 수행 |
| peer DOWN 이벤트 | atomic_set(&active, 0), 자동 중단 |
| peer UP 이벤트 | IPv4 재캐시, atomic_set(&active, 1), 자동 복구 |
| 메모리 할당 실패 | init 실패 → bridge=NULL, 드라이버 정상 동작 |

---

## 11. Implementation Guide

### 11.1 구현 순서

| 순서 | 모듈 | 내용 | 의존성 |
|------|------|------|--------|
| 1 | moal_bridge.h | 데이터 구조 + API 선언 | 없음 |
| 2 | moal_bridge.c (스켈레톤) | init/deinit + 빈 bridge_rx | 1 |
| 3 | moal_main.h | bridge 포인터 추가 | 1 |
| 4 | moal_init.c | 모듈 파라미터 | 없음 |
| 5 | moal_main.c | init/cleanup 호출 | 2, 3, 4 |
| 6 | Makefile | moal_bridge.o 추가 | 없음 |
| 7 | **빌드 검증** | bridge_mode=0으로 기존 동작 확인 | 1-6 |
| 8 | moal_bridge.c (필터) | should_forward, ARP/IP/VLAN 판정 | 2 |
| 9 | moal_bridge.c (WLAN→ETH) | bridge_rx + forward_to_peer | 8 |
| 10 | moal_shim.c | bridge forward 분기 삽입 | 9 |
| 11 | **WLAN→ETH 검증** | 단방향 포워딩 테스트 | 10 |
| 12 | moal_bridge.c (ETH→WLAN) | peer_rx_handler + rx_handler 등록 | 8 |
| 13 | **양방향 검증** | ping / iperf3 양방향 | 12 |
| 14 | moal_bridge.c (notifier) | netdev event 처리 | 12 |
| 15 | moal_bridge.c (stats) | 통계 출력 (deinit 시 + dmesg) | 14 |
| 16 | **전체 검증** | 안정성 + 성능 테스트 | 15 |

### 11.2 Module Map

| Key | 모듈 | 파일 | 설명 |
|-----|------|------|------|
| module-1 | 기반구조 | moal_bridge.h, moal_main.h, moal_init.c, Makefile | 헤더+파라미터+빌드 |
| module-2 | 필터+WLAN→ETH | moal_bridge.c, moal_shim.c | 필터 로직 + WLAN→ETH 포워딩 |
| module-3 | ETH→WLAN+안정성 | moal_bridge.c, moal_main.c | rx_handler + notifier + init/deinit |

### 11.3 Session Guide

| Session | Scope | 목표 | 예상 작업량 |
|---------|-------|------|------------|
| Session 1 | module-1 | 기반구조 + 빌드 확인 (bridge_mode=0 정상 동작) | ~80줄, 파일 5개 |
| Session 2 | module-2 | 필터 로직 + WLAN→ETH 단방향 포워딩 | ~200줄, 파일 2개 |
| Session 3 | module-3 | ETH→WLAN 양방향 + notifier + 전체 검증 | ~100줄, 파일 2개 |
