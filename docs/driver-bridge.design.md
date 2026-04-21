# driver-bridge Design Document

> **Summary**: wlan-driver-v2 MOAL 레이어에 커널 레벨 L2 브릿지 구현 — Option C (Pragmatic Balance)
>
> **Project**: wlan-driver-v2 (NXP 88Q9098 WLAN Driver)
> **Target**: iMX8MP / iMX93
> **Author**: jhw
> **Date v1**: 2026-04-09
> **Date v2**: 2026-04-21
> **Status**: Draft v2 — post-hardening (E1~E5, D1~D7, A1~A2, F1)
> **Architecture**: Option C — Pragmatic Balance + **kthread 양방향 FIFO** + RCU (v2)

---

## Revision History

| Rev | Date | Summary |
|:---:|------|---------|
| v1 | 2026-04-09 | 초안. moal_bridge.c 426줄, params 2개, rx_handler + 직접 `dev_queue_xmit` 모델. 첫 analysis Match 97.2% 달성 |
| v2 | 2026-04-21 | hardening 시리즈 14건(E1~E5, D1~D7, A1~A2, F1) 문서 반영. 양방향 kthread FIFO + keepalive hrtimer + sysfs stats + DBDC guard + RCU + atomic `peer_released` + packet_type fallback. moal_bridge.c 1059줄, params 5개. 목표: v2 analysis 95%+ 복구 |

---

## Context Anchor

| Key | Value |
|-----|-------|
| **WHY** | 유저스페이스 pcap 브릿지의 컨텍스트 스위칭/메모리 복사 오버헤드로 성능 한계. SDIO 반이중 버스 특성상 main_work warm 유지 필요 |
| **WHO** | iMX8MP/iMX93 유무선 브릿지 배포 환경 (DBDC 대응) |
| **RISK** | MOAL 레이어 수정으로 드라이버 안정성 영향 가능. v2 신규 RISK: (a) RCU 경합/dev_put race, (b) 양방향 kthread lifecycle, (c) rx_handler busy 시 packet_type fallback 경로, (d) peer_released race (F1 해결) |
| **SUCCESS** | ETH↔WLAN 양방향 L2 포워딩 동작. 지연 ~7ms (pcap 수준), rmmod 안전, peer down/up graceful |
| **SCOPE** | 신규 2파일 + 수정 5파일. moal_bridge.c **1059줄**, 모듈 파라미터 **5개**, sysfs 노드 1개 |

---

## 1. Overview

### 1.1 선택된 아키텍처: Option C — Pragmatic Balance

**핵심 원칙**:
- 브릿지 로직을 `moal_bridge.c/h`로 분리하여 기존 드라이버 코드 오염 최소화
- ETH→WLAN: 커널 표준 `netdev_rx_handler_register()` (주) + `dev_add_pack()` (fallback)
- WLAN→ETH: `moal_shim.c`의 RX 경로 2곳(일반 + A-MSDU)에 fast path 분기 **삽입 (eth_type_trans 이전)**
- **양방향 전용 kthread** (v2): `skb_queue_tail` → `wake_up_interruptible` → kthread가 배수하여 `dev_queue_xmit` — softirq/NAPI 컨텍스트에서 블로킹 `dev_queue_xmit`을 피하고 SCHED_FIFO로 우선순위 격리
- **keepalive hrtimer** (v2): 주기적으로 드라이버 `main_work`를 깨워 SDIO idle→sleep 전환 방지 (pcap 폴링 효과 재현)
- **DBDC 단일 인스턴스 guard** — 전역 `atomic_t bridge_instance_active`

### 1.2 아키텍처 다이어그램 (v2)

```
┌─────────────────────────────────────────────────────────────────────┐
│ Kernel                                                              │
│                                                                     │
│  ┌──────────┐                                ┌──────────────────┐   │
│  │  eth0    │                                │  moal (wlan0)    │   │
│  │  driver  │                                │  driver + SDIO   │   │
│  └────┬─────┘                                └─────────┬────────┘   │
│       │                                                │            │
│       │ rx_handler (주) / packet_type (fallback)       │ RX         │
│       ▼                                                ▼            │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                        moal_bridge.c                         │   │
│  │                                                              │   │
│  │  ETH RX ─► peer_rx_handler  ─filter─► p2w_queue (cap 512) ── │   │
│  │                                            │                 │   │
│  │                                            ▼                 │   │
│  │  WLAN RX ─► rx_fast  ─filter─► w2p_queue (cap 512) ──       │   │
│  │                                     │                        │   │
│  │             ┌───────────────────────┴──────────────┐         │   │
│  │             │                                      │         │   │
│  │             ▼                                      ▼         │   │
│  │   ┌─────────────────────┐           ┌────────────────────┐   │   │
│  │   │ w2p_thread (SCHED_ │           │ p2w_thread (SCHED_ │   │   │
│  │   │ FIFO, wake_up 기반)│           │ FIFO, wake_up 기반)│   │   │
│  │   │ → dev_queue_xmit    │           │ → dev_queue_xmit    │   │   │
│  │   │   (peer_dev)       │           │   (wlan_dev)       │   │   │
│  │   └──────────┬──────────┘           └──────────┬──────────┘   │   │
│  │              │                                 │              │   │
│  │   keepalive hrtimer → queue_work(main_work)   RCU: handle->bridge │
│  │   sysfs /sys/kernel/moal_bridge/stats                          │   │
│  │   inetaddr notifier (IPv4 재캐시) / netdev notifier (DOWN/UP)  │   │
│  └──────────────────────────────────────────────────────────────┘   │
│       │                                                │            │
│       ▼ (self-destined / pass-through)                 ▼            │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                   Kernel Network Stack                       │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Data Structures

### 2.1 브릿지 컨텍스트 (`moal_bridge.h`)

현재 헤더(97줄) 기준. v1에서 `oom_drops`, `wlan_priv`, w2p/p2w 전용 kthread, packet_type fallback, `peer_released` (F1 atomic), inet/hrtimer 추가.

```c
#include <linux/netdevice.h>
#include <linux/if_ether.h>
#include <linux/if_vlan.h>
#include <linux/ip.h>
#include <linux/if_arp.h>
#include <linux/atomic.h>
#include <linux/inetdevice.h>     /* v2: inet notifier */
#include <linux/workqueue.h>
#include <linux/kthread.h>        /* v2: 전용 kthread */
#include <linux/wait.h>
#include <linux/hrtimer.h>        /* v2: keepalive */

#define MOAL_BR_W2P_QUEUE_MAX 512 /* v2: hard cap */
#define MOAL_BR_P2W_QUEUE_MAX 512

struct moal_bridge_stats {
    atomic_long_t fwd_packets;   /* forwarded */
    atomic_long_t fwd_bytes;     /* v2: bytes */
    atomic_long_t dropped;       /* filtered */
    atomic_long_t errors;        /* xmit errors */
    atomic_long_t oom_drops;     /* v2: clone/share_check OOM */
};

struct moal_bridge {
    struct net_device *wlan_dev;
    struct net_device *peer_dev;   /* dev_hold'd */
    void *wlan_priv;              /* v2: moal_private* (media_connected 체크용) */
    atomic_t active;              /* 1 = forwarding on */

    /* Filter context */
    u8 wlan_mac[ETH_ALEN];
    u8 peer_mac[ETH_ALEN];        /* v2 D4: cached (dev_addr pointer chase 제거) */
    __be32 wlan_ipv4;             /* WRITE_ONCE/READ_ONCE (v2 D5) */
    __be32 peer_ipv4;

    struct moal_bridge_stats wlan_to_peer;
    struct moal_bridge_stats peer_to_wlan;

    /* v2: w2p (WLAN→ETH) 전용 kthread */
    struct sk_buff_head    w2p_queue;
    atomic_t               w2p_qlen;
    struct task_struct    *w2p_thread;
    wait_queue_head_t      w2p_wait;

    /* v2: p2w (ETH→WLAN) 전용 kthread — SDIO TX 지연을 w2p와 격리 */
    struct sk_buff_head    p2w_queue;
    atomic_t               p2w_qlen;
    struct task_struct    *p2w_thread;
    wait_queue_head_t      p2w_wait;

    /* v2: ETH→WLAN 수신 방식 선택 */
    int                use_packet_type;  /* 0=rx_handler, 1=dev_add_pack fallback */
    struct packet_type peer_pt;

    /* v2 F1: peer handler/ref가 NETDEV_UNREGISTER에서 이미 해제됨 표시 */
    atomic_t peer_released;

    struct notifier_block netdev_nb;
    struct notifier_block inet_nb;       /* v2: DHCP 완료 감지 */
    struct hrtimer        keepalive_timer;/* v2: main_work warm */

    void *handle;                /* moal_handle* */
};

/* Public API (v2 시그니처) */
int  moal_bridge_init(void *handle, const char *peer_name, int wlan_bss_idx);
void moal_bridge_deinit(void *handle);
int  moal_bridge_rx_fast(struct moal_bridge *br, struct sk_buff *skb, void *priv);
```

### 2.2 moal_handle 확장

```c
/* moal_main.h — struct _moal_handle 에 추가 */
struct moal_bridge *bridge;   /* RCU-protected (D1). bridge_mode=0 시 NULL */
```

### 2.3 전역 상태

```c
/* moal_bridge.c */
static atomic_t bridge_instance_active = ATOMIC_INIT(0);  /* DBDC 단일 인스턴스 guard */
static struct kobject *moal_bridge_kobj;                  /* /sys/kernel/moal_bridge */
static struct moal_bridge *moal_bridge_for_sysfs;         /* sysfs show 콜백 포인터 */
```

---

## 3. Module Parameters

### 3.1 파라미터 정의 (5개, moal_init.c)

| Param | Type | 기본값 | Perm | Runtime | 설명 |
|-------|:----:|:-----:|:----:|:-------:|------|
| `bridge_mode` | int | 0 | 0000 | No | 0=off, 1=on. 로드 시 고정 |
| `bridge_peer` | charp | `"eth0"` | 0000 | No | peer 인터페이스명. 로드 시 고정 |
| `bridge_wlan_idx` | int | 0 | 0000 | No | DBDC 복수 BSS 중 브릿지 대상 BSS index (v2) |
| `bridge_debug` | int | 0 | 0644 | **Yes** | 디버그 printk + ktime 측정. runtime 변경 가능 (v2 A1) |
| `bridge_keepalive_ms` | int | 1 | 0644 | **Yes** | keepalive hrtimer 주기. 0=disable. runtime 변경 가능 (v2) |

`bridge_debug`와 `bridge_keepalive_ms`는 **runtime-tunable**이며, sysfs `/sys/module/moal/parameters/` 경유 `echo N > bridge_debug` 로 즉시 반영.

### 3.2 Config File Override (`wifi_init_conf.json`)

모듈 파라미터 기본값은 `moal_init.c` 의 config file parser로 override 가능:

| Config Key | 대응 파라미터 |
|------------|---------------|
| `bridge_mode` | `bridge_mode` |
| `bridge_peer` | `bridge_peer` |
| `bridge_wlan_idx` | `bridge_wlan_idx` |
| `bridge_keepalive_ms` | `bridge_keepalive_ms` |

실제 config 경로: `/usr/local/etc/wifi_init_conf.json` (디폴트 `/opt/wlan/config/wifi_init_conf.json` 백업).

### 3.3 사용 예시

```bash
# 브릿지 활성화 (최소)
insmod moal.ko bridge_mode=1 bridge_peer=eth0

# DBDC 중 BSS 1 대상 + 디버그 출력
insmod moal.ko bridge_mode=1 bridge_peer=eth0 bridge_wlan_idx=1 bridge_debug=1

# Runtime 디버그 토글
echo 1 | sudo tee /sys/module/moal/parameters/bridge_debug
echo 2 | sudo tee /sys/module/moal/parameters/bridge_keepalive_ms

# 실시간 stats
cat /sys/kernel/moal_bridge/stats
```

---

## 4. Packet Flow — Detailed (v2)

### 4.1 WLAN→ETH (w2p) 방향

**삽입 지점**: `moal_shim.c` — v1의 `netif_rx` 직전이 아닌, **eth_type_trans 이전 fast path**. 2개 사이트 존재:
- `moal_recv_packet()` (일반 RX 경로, 2146라인 근처)
- `moal_recv_amsdu_packet()` (A-MSDU 서브프레임 경로, 2290라인 근처, v2 D2)

```c
/* moal_shim.c — 양 site 공통 패턴 */
rcu_read_lock();
br = rcu_dereference(handle->bridge);           /* v2 D1: RCU */
if (unlikely(br) && atomic_read(&br->active)) {
    if (moal_bridge_rx_fast(br, skb, priv))    /* 1 = consumed */
        { rcu_read_unlock(); goto done; }
}
rcu_read_unlock();
/* 기존 경로: eth_type_trans + netif_rx */
```

**moal_bridge_rx_fast()** 요약:
```
1. 길이/VLAN 검사 + pskb_may_pull (v2 B3)
2. link-local 01:80:C2:00:00:0x drop (v2 E1)
3. VLAN-tagged EAPOL drop (v2 D7)
4. IPv4 self-dst → 0 반환 (커널로) — STA 모드: MAC 필터는 사실상 무효 (I-1 참고)
5. ARP self-target → 0 반환
6. multicast: skb_clone + p2w 전달, 원본은 0 (커널로도 전달)
7. non-self unicast: atomic_inc_return 큐 cap 체크 → skb_queue_tail(&w2p_queue)
   + wake_up_interruptible(&w2p_wait) → 1 반환 (consumed)
```

**w2p_thread_fn()** 요약:
```
while (!kthread_should_stop()):
    wait_event_interruptible(w2p_wait, queue_non_empty || should_stop)
    while ((skb = skb_dequeue(&w2p_queue))):
        atomic_dec(&w2p_qlen)
        if (!moal_bridge_dev_ready(peer_dev))   /* v2 E2 */
            { kfree_skb(skb); errors++; continue; }
        skb->dev = peer_dev
        dev_queue_xmit(skb)   /* consume 성공, fwd++ */
```

### 4.2 ETH→WLAN (p2w) 방향

**주 경로**: `netdev_rx_handler_register()` 로 peer_dev(eth0)에 등록한 `moal_bridge_peer_rx_handler()`.

**Fallback** (v2 B7): rx_handler 등록 실패 시(다른 사용자가 먼저 등록) `dev_add_pack()` + ETH_P_ALL `packet_type` 등록 → `moal_bridge_peer_pt_func()`. packet_type handler는 kernel이 각 리스너에게 clone skb를 deliver하므로 소비 semantics가 다름 — 자기 copy만 `kfree_skb`.

```c
/* moal_bridge.c::moal_bridge_peer_rx_handler — 요약 */
skb = skb_share_check(skb, GFP_ATOMIC);
if (!atomic_read(&br->active)) return RX_HANDLER_PASS;
if (is_link_local(skb)) { kfree_skb(skb); return RX_HANDLER_CONSUMED; }  /* E1 */
if (skb->protocol == htons(ETH_P_PAE)) { kfree_skb(skb); ... }          /* EAPOL */
if (!moal_bridge_dev_ready(wlan_dev)) { kfree_skb(skb); ... }           /* E2 */
skb = moal_bridge_ensure_headroom(skb);                                  /* E4 */
if (!skb) return RX_HANDLER_CONSUMED;
skb_push(skb, ETH_HLEN);   /* eth_type_trans가 pull한 헤더 복원 */
/* ether_addr_equal(peer_mac, ...) 등 self-MAC 필터 (D4) */
/* is_multicast: clone → p2w_queue + 원본은 RX_HANDLER_PASS */
/* non-self unicast: atomic_inc_return cap 체크 → skb_queue_tail(&p2w_queue) +
   wake_up_interruptible(&p2w_wait) → RX_HANDLER_CONSUMED (A2: no-clone) */
```

**p2w_thread_fn()** 는 w2p와 구조 동일 (target: wlan_dev).

### 4.3 루프 방지

```
시나리오 1: eth0 RX → bridge → wlan TX → FW echo → wlan RX → bridge → eth0 TX → ...
방지책:
  - WLAN→ETH: rx_fast가 소비한 skb는 eth_type_trans/netif_rx 미호출
  - ETH→WLAN: peer_rx_handler가 RX_HANDLER_CONSUMED 반환 시 eth 커널스택 미전달
  - self-MAC 필터 (peer 방향): ether_addr_equal(h_dest, wlan_mac) → RX_HANDLER_PASS
  - self-IP 필터 (wlan 방향): iph->daddr == wlan_ipv4 → 0 반환
```

---

## 5. Filter Logic (v2 확장)

### 5.1 판정 순서 (peer_rx_handler 기준)

1. **skb_share_check** — shared면 unshared copy 획득
2. **active 체크** — `atomic_read(&br->active)` 0이면 PASS
3. **link-local drop** (v2 E1) — `is_link_local(h_dest)` 01:80:C2:00:00:00~0F (STP/LACP/LLDP)
4. **EAPOL pass-through** — `ETH_P_PAE`는 상위 stack에 전달 (+ VLAN-tagged EAPOL: v2 D7은 WLAN 방향 rx_fast에서 처리; peer 방향은 outer only)
5. **dev_ready gate** (v2 E2) — `running && carrier_ok && NETREG_REGISTERED` 아니면 drop
6. **headroom guard** (v2 E4) — `skb_headroom >= ETH_HLEN` 아니면 `skb_realloc_headroom` 또는 drop (oom++)
7. **self-MAC** — `ether_addr_equal(h_dest, peer_mac)` 이면 PASS (자기향 unicast)
8. **broadcast/multicast** — `is_multicast_ether_addr` → clone-and-pass (원본 PASS, clone은 queue로)
9. **non-self unicast** — queue로 enqueue (A2: no-clone consume)

### 5.2 STA 모드 MAC 필터 한계 (I-1)

STA 모드에서 WLAN RX의 `h_dest`는 **항상 자기 WLAN MAC** (FW가 이미 필터링). 따라서 v1이 명시한 `ether_addr_equal(h_dest, br->wlan_mac)` 1차 필터는 practical하게 모든 패킷에 매치 → 의미 없음. 실제 판정은 **IP 기반** (`iph->daddr == br->wlan_ipv4` 등)으로 수행된다. AP/UAP 모드에서는 MAC 필터가 유효.

### 5.3 ARP 판정

`moal_bridge_arp_is_for_self(br, skb, l3_off)` — `l3_off = ETH_HLEN` 또는 `VLAN_ETH_HLEN`. ARP `target_ip`가 `br->wlan_ipv4` 이면 true (커널 응답용). peer_ipv4는 포함하지 않음 (의도적 — peer는 eth 드라이버가 응답).

### 5.4 IPv4 self/local 판정

`rx_fast`에 inline. v1의 별도 `moal_bridge_ip_is_local()` / `should_forward()` 함수는 **삭제됨 (v2 D3)** — fast path 호출 비용 감소. inline 로직:

```c
if (proto == htons(ETH_P_IP) && skb_headlen_ok) {
    iph = (struct iphdr *)(skb->data + l3_off);
    if (iph->daddr == READ_ONCE(br->wlan_ipv4))
        return 0;   /* self → 커널 스택 */
    if (ipv4_is_multicast(iph->daddr))
        /* multicast path */
}
```

---

## 6. Lifecycle Management (v2)

### 6.1 초기화 (`moal_bridge_init`)

**호출 시점**: `moal_main.c::woal_init_sw()` 말미 (wlan netdev 등록 완료 후). 시그니처에 `wlan_bss_idx` 추가 (v2 DBDC).

```
1. DBDC guard: atomic_cmpxchg(&bridge_instance_active, 0, 1) != 0 → -EBUSY
2. peer = dev_get_by_name(&init_net, peer_name)  → dev_hold 포함
3. br = kzalloc(sizeof *br, GFP_KERNEL)
4. 필드 초기화: wlan_dev = handle->priv[wlan_bss_idx]->netdev
              wlan_priv = handle->priv[wlan_bss_idx]
              peer_dev = peer
              MAC/IPv4 캐시
              skb_queue_head_init + init_waitqueue_head × 2
              atomic_set(&active, 0)
              atomic_set(&peer_released, 0)   /* F1 */
5. w2p_thread = kthread_run(w2p_thread_fn, br, "moal_br_w2p")
   p2w_thread = kthread_run(p2w_thread_fn, br, "moal_br_p2w")
   moal_bridge_apply_sched(w2p/p2w, SCHED_FIFO, prio 50)
6. rtnl_lock():
     dev_set_promiscuity(peer, +1)
     ret = netdev_rx_handler_register(peer, moal_bridge_peer_rx_handler, br)
     if (ret) { use_packet_type = 1; fall through rtnl_unlock then dev_add_pack }
   rtnl_unlock()
7. register_netdevice_notifier(&netdev_nb)    /* peer DOWN/UP/UNREGISTER */
8. register_inetaddr_notifier(&inet_nb)       /* DHCP 완료 감지 (v2) */
9. hrtimer_init(&keepalive_timer, ...); hrtimer_start(...)  /* v2 */
10. moal_bridge_sysfs_init(br)                /* /sys/kernel/moal_bridge (v2 E5) */
11. rcu_assign_pointer(handle->bridge, br)    /* D1: publish */
12. atomic_set(&br->active, 1)
```

### 6.2 해제 (`moal_bridge_deinit`) — 9단계 (v2 F1)

**F1 핵심 변경**: `rcu_assign_pointer(NULL)` + `synchronize_rcu()` 를 `kthread_stop` **앞으로** 이동하여 "reader가 stopped kthread 큐에 skb enqueue" race를 구조적으로 차단.

```
1. atomic_set(&active, 0) + sysfs_deinit + hrtimer_cancel
2. unregister_inetaddr_notifier + unregister_netdevice_notifier
3. if (!atomic_read(&peer_released)) {              /* F1 atomic */
     rtnl_lock()
     use_packet_type ? dev_remove_pack(&peer_pt) : netdev_rx_handler_unregister(peer)
     dev_set_promiscuity(peer, -1)
     rtnl_unlock()
   }
4. synchronize_net()                    /* net path RCU reader drain */
5. rcu_assign_pointer(handle->bridge, NULL)          /* F1: before kthread_stop */
   synchronize_rcu()                                 /* F1: drain any remaining reader */
6. kthread_stop(w2p_thread) + skb_queue_purge(w2p_queue)
7. kthread_stop(p2w_thread) + skb_queue_purge(p2w_queue)
8. stats PRINTM + (!peer_released ? dev_put(peer)) + kfree(br)
9. atomic_set(&bridge_instance_active, 0)            /* DBDC guard release */
```

### 6.3 Netdev Notifier

| Event | 동작 |
|-------|------|
| `NETDEV_DOWN` | active=0, w2p/p2w queue purge, qlen 복원 |
| `NETDEV_UP` | wlan/peer IPv4 재캐시 (WRITE_ONCE), active=1 |
| `NETDEV_UNREGISTER` | active=0, handler/promisc/dev_put, `atomic_set(&peer_released, 1)` (F1) |

### 6.4 Inetaddr Notifier (v2)

`NETDEV_UP`/`NETDEV_DOWN`의 IP 이벤트 수신 — `ifa->ifa_dev->dev == br->wlan_dev || br->peer_dev` 이면 해당 IPv4 재캐시 (WRITE_ONCE). v2 D6: `ifa`/`ifa->ifa_dev`/`ifa->ifa_dev->dev` NULL guard 필수 (partial construction 시점 콜백 존재).

### 6.5 Keepalive Hrtimer (v2)

```c
static enum hrtimer_restart moal_bridge_keepalive(struct hrtimer *t)
{
    struct moal_handle *handle = container_of(t, ..., bridge->keepalive_timer)->handle;
    if (handle->workqueue) queue_work(handle->workqueue, &handle->main_work);
    hrtimer_forward_now(t, ms_to_ktime(READ_ONCE(bridge_keepalive_ms)));
    return HRTIMER_RESTART;
}
```

SDIO 호스트 컨트롤러가 `main_work` idle 시 sleep 전환하여 latency가 튀는 현상(31ms) 방지. 1ms 주기 wakeup으로 ~7ms RTT 유지 (pcap 수준).

---

## 7. Concurrency & Safety (v2)

### 7.1 동시성 매트릭스

| 자원 | Writer 컨텍스트 | Reader 컨텍스트 | 보호 수단 |
|------|------------------|------------------|-----------|
| `handle->bridge` (포인터) | init/deinit (process) | moal_shim.c RX (softirq/NAPI) | **RCU** (rcu_dereference / rcu_assign_pointer / synchronize_rcu) — v2 D1 |
| `br->active` | init/notifier (process) | RX 양방향 | atomic_t |
| `br->peer_released` | notifier UNREGISTER (RTNL) | deinit (process) + sysfs | **atomic_t** (v2 F1) |
| `br->w2p_qlen` / `p2w_qlen` | 모든 enqueuer + dequeuer | stats | atomic_t, inc_return 기반 cap |
| `w2p_queue` / `p2w_queue` skb | enqueuer + kthread | purge path | `skb_queue_*` (내부 스핀락) |
| `br->wlan_ipv4` / `peer_ipv4` | inetaddr notifier (process) | RX fast path | **WRITE_ONCE / READ_ONCE** (v2 D5) |
| `br->peer_mac` | init only | peer_rx_handler | init 후 불변 (D4) |
| `bridge_instance_active` (global) | init/deinit | init DBDC guard | atomic_t cmpxchg |
| rx_handler 등록/해제 | init/deinit/notifier | — | **RTNL** lock |
| `sysfs kobject` | init/deinit | stats_show | `READ_ONCE(moal_bridge_for_sysfs)` |

### 7.2 F1 Ordering Contract (중요)

deinit에서 **반드시 다음 순서**:

```
synchronize_net            (net path reader drain)
rcu_assign_pointer(NULL)    (publish withdrawal)
synchronize_rcu             (non-net path RCU reader drain)
kthread_stop(w2p/p2w)        (전용 thread 종료)
skb_queue_purge              (큐 잔여 skb 해제)
```

이 순서를 위배하면 reader가 포인터를 이미 잡은 상태에서 stopped kthread 큐에 skb를 밀어넣어 purge 후에도 남는 leak/race가 발생. F1 이전에는 active=0 + 최종 purge가 cover했으나, 순서를 정비함으로써 **설계적으로도 race window가 없음**을 보장.

회귀 방지: `scripts/tests/bridge_static_checks.sh` 에 다음 grep 규칙 추가 권장 — `rcu_assign_pointer.*bridge.*NULL` 이 `kthread_stop` 이전에 등장하는지.

### 7.3 skb 소유권 규칙

| 시나리오 | 소유권 | 설명 |
|----------|--------|------|
| rx_fast 반환 1 (non-self unicast) | `w2p_queue`가 인계 | caller(moal_shim.c)는 touch하지 않음 |
| rx_fast 반환 1 (multicast clone) | 원본은 caller, clone은 queue | 원본은 netif_rx로 |
| rx_fast 반환 0 | caller가 소유 | 기존 netif_rx 경로로 |
| peer_rx_handler RX_HANDLER_CONSUMED | `p2w_queue`가 인계 또는 kfree | kernel stack 미전달 |
| peer_rx_handler RX_HANDLER_PASS | kernel stack이 소유 | 정상 전달 |
| packet_type fallback | clone 사본만 자기가 관리 | `kfree_skb(skb); return 0` |
| kthread 큐 cap 초과 | kthread enqueuer가 `kfree_skb` + `dropped++` | atomic_inc_return > cap |
| dev_queue_xmit 실패 | 함수 내에서 이미 free | `errors++` |

### 7.4 Packet_type Fallback 주의점

rx_handler 실패 경로(B7):
- `dev_set_promiscuity(+1)` 은 이미 적용됨 — packet_type은 promisc 불필요하지만 유지
- `dev_add_pack`은 void return (실패 경로 없음)
- semantics 차이: packet_type handler는 kernel이 각 리스너에게 clone을 넘김 — 자기 copy만 해제

### 7.5 Preemption/Freezer 고려

- w2p/p2w kthread는 `wait_event_interruptible` 사용. signal은 오지 않지만 `kthread_stop`의 `TIF_NEED_RESCHED`로 깨어남
- **freezer 미등록** 상태 — 향후 PM suspend 시 SDIO 버스 블로킹 우려 (v2 Known Issue, QA 시나리오에 포함)

---

## 8. File Changes (실측)

### 8.1 신규 파일

| 파일 | 현재 라인수 | 설명 |
|------|:----------:|------|
| `mlinux/moal_bridge.h` | 97 | 데이터 구조 + API 선언 (v1 57 → v2 97, +40) |
| `mlinux/moal_bridge.c` | 1059 | 브릿지 코어 (v1 초안 ~280 → v1 실측 426 → v2 1059, +633) |

### 8.2 수정 파일

| 파일 | 델타 | 설명 |
|------|:----:|------|
| `mlinux/moal_main.h` | +10 | `struct moal_bridge *bridge` + params struct 5개 필드 |
| `mlinux/moal_init.c` | +36 | 5개 `module_param` + config file parser (wifi_init_conf.json) + handle 복사 |
| `mlinux/moal_main.c` | +5 | `moal_bridge_init(handle, peer, wlan_idx)` 호출 + `moal_bridge_deinit(handle)` |
| `mlinux/moal_shim.c` | +22 | `moal_recv_packet` + `moal_recv_amsdu_packet` (A-MSDU) 2곳 fast path 분기 |
| `Makefile` | +1 | `MOALOBJS += mlinux/moal_bridge.o` |

### 8.3 빌드 검증

- 도구: `make_for_imx93.sh` (Yocto fsl-imx-wayland 6.6-nanbield, armv8a-poky-linux, kernel 6.6.3)
- 결과: **0 warnings / 0 errors** (F1 커밋 697cff3 직후 재검증)
- 산출물: `bin_wlan/moal_imx93.ko`

---

## 9. Test Plan

### 9.1 단위 테스트 (타겟 보드)

| ID | 테스트 | 검증 방법 | SC |
|----|--------|-----------|-----|
| T-01 | bridge_mode=0 로드 | 기존 Wi-Fi 연결 정상 | SC-04 |
| T-02 | bridge_mode=1 로드 | dmesg "bridge activated" | — |
| T-03 | WLAN→ETH ping | 무선→유선 ping 정상 | SC-01 |
| T-04 | ETH→WLAN ping | 유선→무선 ping 정상 | SC-01 |
| T-05 | 자기 IP ssh | 브릿지 IP ssh 정상 | SC-02 |
| T-06 | ARP 정상 | 브릿지 IP ARP reply | SC-02 |
| T-07 | VLAN 투명 전달 | VLAN 양방향 포워딩 | SC-03 |
| T-08 | rmmod 정상 | `lsmod` 확인 | SC-06 |
| T-09 | rmmod 반복 | 100회 insmod/rmmod (F1 ordering 회귀 감시) | SC-06 |
| T-10 | peer down/up | eth0 down/up 시 자동 복구 | NFR-06 |
| T-11 (v2) | DBDC wlan_idx | `bridge_wlan_idx=1` 2차 BSS 브릿지 | — |
| T-12 (v2) | packet_type fallback | rx_handler 점유된 peer로 강제 fallback 검증 | — |
| T-13 (v2) | sysfs stats 갱신 | `watch -n1 cat /sys/kernel/moal_bridge/stats` | — |
| T-14 (v2) | keepalive 효과 | `bridge_keepalive_ms=0` vs `=1` latency 비교 | NFR-01 |

### 9.2 성능 테스트 (latency 중심, CPU 측정은 스코프 제외)

| ID | 테스트 | 도구 | SC |
|----|--------|------|-----|
| P-01 | TCP throughput | `iperf3 -t 60` | — |
| P-02 | UDP throughput | `iperf3 -u -b 100M` | — |
| P-03 | Latency 분포 | `ping -c 1000 -i 0.01 -q`, avg/mdev/max 분석 | NFR-01 |
| P-05 | wbridge 대비 | P-01~P-03 (throughput + latency) 비교 | SC-05 |

> **Note**: 이전 v2 초안에 있던 P-04 CPU 사용량 측정은 스코프에서 제외. 본 드라이버의 설계 목적은 *latency 감소*이며 CPU 사용량 증가(keepalive hrtimer 등)는 감수 대상.

### 9.3 안정성 테스트

| ID | 테스트 | 방법 |
|----|--------|------|
| S-01 | 장시간 | iperf3 TCP 24h |
| S-02 | UDP flood | `iperf3 -u -b 0` 10분 |
| S-03 | 브로드캐스트 스톰 | tcpreplay 브로드캐스트 대량 |
| S-04 | peer 미존재 | `bridge_peer=eth99` 에러 처리 |
| S-05 (v2) | RCU 회귀 | rmmod 중 RX traffic 유입 (race 감시) |
| S-06 (v2) | DBDC guard | `bridge_mode=1` 중복 로드 시 두 번째 -EBUSY |

### 9.4 Static Checks (v2)

`scripts/tests/bridge_static_checks.sh` — 코드 리뷰 보조:
- `rcu_assign_pointer.*bridge.*NULL` 이 `kthread_stop` 이전 등장 (F1 ordering)
- `peer_released` 접근이 모두 `atomic_read`/`atomic_set` (F1)
- `dev_hold`/`dev_put` 쌍 일치
- `WRITE_ONCE`/`READ_ONCE` 사용 hot-path 필드 커버리지

---

## 10. Error Handling

| 에러 | 처리 |
|------|------|
| peer 인터페이스 없음 | `-ENODEV` 반환, bridge 비활성, 드라이버 정상 로드 |
| DBDC guard 충돌 | `-EBUSY` 반환 (v2) |
| kthread 생성 실패 | `-ENOMEM`, 이미 만든 리소스 rollback |
| `rx_handler_register` 실패 | `dev_add_pack` fallback으로 전환 (v2 B7). `pr_warn` 출력 |
| `dev_set_promiscuity` 실패 | init 실패로 rollback |
| `sysfs_create_file` 실패 | non-fatal, PRINTM 출력 후 진행 (v2 E5) |
| `dev_queue_xmit` 실패 | `errors++`, skb는 xmit 내부에서 이미 free |
| `skb_clone` / `skb_share_check` 실패 | `oom_drops++` (v2) |
| kthread 큐 cap 초과 | `dropped++`, `kfree_skb` |
| peer DOWN | `atomic_set(active, 0)` + queue purge, 자동 중단 |
| peer UP | IPv4 재캐시, `atomic_set(active, 1)`, 자동 복구 |
| peer UNREGISTER | handler 해제 + `peer_released=1` (F1 atomic). deinit 시 2차 해제 skip |
| 메모리 할당 실패 | init 실패, bridge=NULL, 드라이버 정상 동작 |
| sched_setscheduler 실패 | `pr_warn_once` (v2 E3), SCHED_NORMAL로 계속 동작 |

---

## 11. Implementation Guide (History)

> v1 작성 당시의 구현 순서. 현재는 전체 구현 완료 상태이며, 후속 hardening은 §2~§7의 v2 변경 사항 참조.

### 11.1 구현 순서

| 순서 | 모듈 | 내용 | 의존성 |
|------|------|------|--------|
| 1 | moal_bridge.h | 데이터 구조 + API 선언 | 없음 |
| 2 | moal_bridge.c (스켈레톤) | init/deinit + 빈 bridge_rx | 1 |
| 3 | moal_main.h | bridge 포인터 추가 | 1 |
| 4 | moal_init.c | 모듈 파라미터 | 없음 |
| 5 | moal_main.c | init/cleanup 호출 | 2, 3, 4 |
| 6 | Makefile | moal_bridge.o 추가 | 없음 |
| 7 | **빌드 검증** | bridge_mode=0 기존 동작 확인 | 1-6 |
| 8 | moal_bridge.c (필터) | ARP/IP/VLAN 판정 | 2 |
| 9 | moal_bridge.c (WLAN→ETH) | bridge_rx + forward_to_peer | 8 |
| 10 | moal_shim.c | bridge forward 분기 삽입 | 9 |
| 11 | **WLAN→ETH 검증** | 단방향 포워딩 | 10 |
| 12 | moal_bridge.c (ETH→WLAN) | peer_rx_handler 등록 | 8 |
| 13 | **양방향 검증** | ping / iperf3 | 12 |
| 14 | moal_bridge.c (notifier) | netdev event | 12 |
| 15 | moal_bridge.c (stats) | 통계 출력 | 14 |
| 16 | **전체 검증** | 안정성 + 성능 | 15 |

### 11.2 Module Map

| Key | 모듈 | 파일 | 설명 |
|-----|------|------|------|
| module-1 | 기반구조 | moal_bridge.h, moal_main.h, moal_init.c, Makefile | 헤더+파라미터+빌드 |
| module-2 | 필터+WLAN→ETH | moal_bridge.c, moal_shim.c | 필터 + WLAN→ETH |
| module-3 | ETH→WLAN+안정성 | moal_bridge.c, moal_main.c | rx_handler + notifier + init/deinit |
| module-4 (v2) | hardening | moal_bridge.c | kthread FIFO + RCU + atomic peer_released + sysfs + keepalive + packet_type fallback |

### 11.3 Session Guide

| Session | Scope | 목표 | 예상 작업량 |
|---------|-------|------|------------|
| Session 1 | module-1 | 기반구조 + 빌드 확인 | ~80줄, 파일 5개 |
| Session 2 | module-2 | 필터 + WLAN→ETH 단방향 | ~200줄, 파일 2개 |
| Session 3 | module-3 | ETH→WLAN 양방향 + notifier | ~100줄, 파일 2개 |
| Session 4+ (v2) | module-4 | hardening 시리즈 (E1~E5, D1~D7, A1~A2, F1) — 완료 | ~550줄 누적 |
