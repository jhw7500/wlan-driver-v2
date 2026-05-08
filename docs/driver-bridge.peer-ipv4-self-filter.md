# Bridge: peer_ipv4 self-IP filter limitation (latent)

> **Status**: latent finding — 현재 운영 use case에선 발현 안 됨, 미래 보강 후보로 보존
> **Discovered**: 2026-05-08 (IP 부여 정책 검토 세션)
> **Affects**: `mlinux/moal_bridge.c` `moal_bridge_rx_fast()` self-IP 필터
> **Risk if surfaces**: 무선쪽 장비에서 박스 `eth0` IP로의 직접 IPv4 통신 불가

---

## 1. Background

브릿지 박스의 IP 부여 정책 검토 중 발견. 현재 운영 구성 (VLAN 미사용 flat L2):

| 노드 | IP/Mask | 용도 |
|---|---|---|
| 박스 `eth0` | 192.168.0.200/24 | OHT 측 wire 직통 |
| 박스 `mlan0` | 192.168.1.100/24 | 무선 mgmt 채널 |
| OHT (유선) | 192.168.0.10/24 | 박스 뒤 유선 클라이언트 |
| 무선 서버 | 192.168.0.99/24 | OHT 데이터 통신 상대 |
| 무선 AP | 192.168.0.12/24 | — |
| 무선 모니터링 | 192.168.1.200/24 | 박스 mgmt 운영자 |

**동작 OK 시나리오 (3가지)**:
1. OHT(.0.10) ↔ 박스 `eth0`(.0.200) 1:1 직통
2. OHT(.0.10) ↔ 무선 서버(.0.99) — bridge transit
3. 무선 모니터링(.1.200) ↔ `mlan0`(.1.100) — 무선 mgmt

**미동작 시나리오 (운영상 불필요)**:
- 무선 서버(.0.99) → 박스 `eth0`(.0.200) 직접 ping

이 미동작이 단순 정책 의도인지 잠재 버그인지 분석.

---

## 2. 환경 가정

```
[모니터링 .1.200] ──┐
[AP .0.12]   ──────┼─ flat L2 (no VLAN)
[OHT .0.10]  ←wire─[box eth0=.0.200, mlan0=.1.100]
[무선 서버 .0.99] ──┘
```

같은 L2 broadcast domain 위에 두 IP 서브넷(.0.x, .1.x)이 공존. WGB(Workgroup Bridge) 또는 4-addr 모드로 OHT MAC이 air 전송 시 보존됨.

---

## 3. 현상

무선 서버(.0.99)에서 박스 `eth0` IP `.0.200`으로 ping:

```
ARP: 일부 응답 (mlan0가 ARP flux로 자기 MAC을 .0.200 매핑으로 광고)
ICMP echo request: 박스 stack에 도달하지 않음
ICMP echo reply: 없음
→ ping 100% loss
```

비교군: OHT(.0.10)에서 동일 dst `.0.200`으로 ping은 정상 (eth0 NIC으로 직접 진입, rx_fast 미경유).

---

## 4. 코드 분석

`mlinux/moal_bridge.c` `moal_bridge_rx_fast()` self-IP 필터 (line 422~):

```c
if (proto == htons(ETH_P_IP) && !is_multicast_ether_addr(eth->h_dest)) {
    __be32 wlan_ip = READ_ONCE(br->wlan_ipv4);

    if (wlan_ip && pskb_may_pull(skb, l3_off + sizeof(struct iphdr))) {
        struct iphdr *iph = (struct iphdr *)(skb->data + l3_off);

        if (iph->daddr == wlan_ip) {
            BR_DBG("w2p SELF-IP skip clone dip=%pI4\n", &iph->daddr);
            return 0;  // self-IP → 스택만 처리, eth0 forward skip
        }
        /* Non-self unicast IPv4 → consume original (no clone, no stack) */
        ...
        skb_queue_tail(&br->w2p_queue, skb);
        return 1;  // forwarded, skip stack deliver
    }
}
```

**문제**: self-IP 판정에 `wlan_ipv4`(=mlan0의 IP)만 사용. `eth0`의 IP(`peer_ipv4`)는 `moal_bridge_inetaddr_event()` (line 686~) 에서 추적은 되지만 필터에 활용 안 됨.

**패킷 trace** (.0.99 → .0.200):
1. `.0.99` ARP "Who has .0.200?" 무선 측 broadcast → mlan0 RX → mcast 분기 → 스택에 ARP 도달
2. `arp_ignore=0` 기본값 → mlan0가 자기 MAC으로 응답 (ARP flux)
3. `.0.99`가 ICMP echo 송신 (dst MAC=mlan0 MAC, dst IP=.0.200) → mlan0 RX
4. rx_fast IPv4 unicast 분기 → `iph->daddr(.0.200) != wlan_ip(.1.100)` → "non-self consume"
5. eth0로 forward → OHT가 drop
6. **박스 stack은 echo request를 받지 못함 → echo reply 없음**

---

## 5. 탐색 중 사이드 발견 (별개 이슈)

### 5.1 박스 default route 위치
- 외부망 사용 안 하는 환경에선 default route가 사실상 unused — 모든 통신이 connected route로 처리됨
- 잘못된 default(eth0 방향)가 잡혀도 OHT 외 발신 시도 시 즉시 fail로 발견됨
- **결론**: 이 환경에선 운영상 무관

### 5.2 mlan0 /23 prefix 변경 검토
- mlan0를 /23으로 확장해도 eth0의 /24 connected route가 더 구체적이라 라우팅 우선 → 박스→무선쪽 `.0.x` 직통 못 풀림
- 효용 있는 건 `/32` specific route뿐 (예: `ip route add 192.168.0.99/32 dev mlan0`)
- **결론**: /23 변경은 가치 없음

---

## 6. 해결 방안 (적용 시)

### 6.1 코드 패치 — rx_fast self-IP 필터에 peer_ipv4 추가

```c
if (proto == htons(ETH_P_IP) && !is_multicast_ether_addr(eth->h_dest)) {
    __be32 wlan_ip = READ_ONCE(br->wlan_ipv4);
    __be32 peer_ip = READ_ONCE(br->peer_ipv4);   // 추가

    if ((wlan_ip || peer_ip) &&
        pskb_may_pull(skb, l3_off + sizeof(struct iphdr))) {
        struct iphdr *iph = (struct iphdr *)(skb->data + l3_off);

        if ((wlan_ip && iph->daddr == wlan_ip) ||
            (peer_ip && iph->daddr == peer_ip)) {
            BR_DBG("w2p SELF-IP skip clone dip=%pI4\n", &iph->daddr);
            return 0;
        }
        /* Non-self unicast IPv4 → consume original */
        ...
```

`br->peer_ipv4`는 이미 inetaddr 핸들러가 `eth0` IP를 추적 중. 활용만 안 됐을 뿐. 추가 자료구조 변경 불필요.

### 6.2 라우팅 보정 — 양방향 통신을 위해 필수

코드 패치만으로는 RX 단방향만 풀림. 박스 → `.0.99` reply는 eth0 connected route(/24)를 타고 OHT 방향으로 나가서 fail.

```bash
ip route add 192.168.0.99/32 dev mlan0 src 192.168.0.200
```

- `/32`가 `/24`보다 구체적 → reply만 mlan0 경유로 라우팅
- `src=.0.200`으로 응답 IP 일관성 유지

다른 무선쪽 `.0.x` 장비도 직접 통신하려면 각 장비별 `/32` 추가, 또는 다음 중 택1:
- proxy ARP + policy routing
- 박스에 secondary IP `.0.x`를 mlan0에 부여 (라우팅 비결정성 주의)
- 서브넷 재설계

---

## 7. 사이드 이펙트 분석

### 코드 패치 영향

| 항목 | 변화 |
|---|---|
| 무선쪽 → eth0 IP 트래픽 | **stack 도달** (이전: forward되어 OHT가 drop) |
| 무선쪽 → mlan0 IP 트래픽 | 영향 없음 |
| OHT → eth0 IP 트래픽 | 영향 없음 (eth0 NIC 직접 진입, rx_fast 미경유) |
| 무선쪽 broadcast/multicast | 영향 없음 (별도 mcast 분기) |
| `eth0` IP 변경/삭제 | inetaddr 핸들러가 자동 갱신 (기존 추적 로직 재사용) |

Edge case: `peer_ip == 0` (eth0에 IP 없음) → `if (peer_ip && iph->daddr == peer_ip)` 가드로 처리. 0.0.0.0 매치 방지.

### 라우팅 보정 영향
- 박스 → `.0.99`: mlan0 경유 (의도)
- 박스 → 다른 `.0.x`: eth0 connected route 유지 (영향 없음)
- OHT → `.0.99` (브릿지 transit): 영향 없음 (브릿지 코드 경유, 박스 routing 안 거침)

---

## 8. 테스트 절차 (적용 시)

### 사전
```bash
# 박스 모듈 정보 확인
modinfo moal | grep -E 'filename|version'
ip addr show
ip route show
```

> SSH 세션은 mlan0(.1.100) 경유로 유지. eth0 경유 SSH는 본 한계 때문에 애초에 안 됨.

### 1단계: 코드 패치 적용
`mlinux/moal_bridge.c` `moal_bridge_rx_fast()` 의 IPv4 unicast 분기에 §6.1 패치 적용. 백업 권장:

```bash
cp mlinux/moal_bridge.c mlinux/moal_bridge.c.bak
# 패치 적용 후
diff -u mlinux/moal_bridge.c.bak mlinux/moal_bridge.c
```

### 2단계: 빌드 + 적재
```bash
./make_for_imx93.sh    # 빌드 방식 메모리 참조: feedback_build.md
# 박스에 모듈 업로드 후
sudo rmmod moal
sudo insmod /path/to/moal_imx93.ko
dmesg | tail -50       # 정상 init 확인
```

> ⚠️ rmmod 시 STA association 일시 단절. mlan0 SSH 끊겼다가 association 재수립 후 재접속.

### 3단계: 라우팅 추가
```bash
ip route add 192.168.0.99/32 dev mlan0 src 192.168.0.200
ip route show 192.168.0.99    # /32 우선 적용 확인
```

### 4단계: 정방향 검증
```bash
# 무선 서버(.0.99)에서
ping -c 5 192.168.0.200
# → 정상 응답 (이전: 100% loss)

# 박스에서 ICMP 카운터
nstat -az | grep -E 'IcmpInEchos|IcmpOutEchoReps'
# → IcmpInEchos +5, IcmpOutEchoReps +5 둘 다 증가
```

### 5단계: 회귀 검증
```bash
# OHT에서       — eth0 직통, 영향 없음
ping -c 3 192.168.0.200
# OHT에서       — bridge transit, 영향 없음
ping -c 3 192.168.0.99
# 모니터링에서  — mlan0 직통, 영향 없음
ping -c 3 192.168.1.100
```

전부 정상 응답이면 사이드 이펙트 없음 검증 완료.

### 롤백
```bash
ip route del 192.168.0.99/32
sudo rmmod moal && sudo insmod /path/to/moal_imx93.ko.bak
```

---

## 9. 권장 (2026-05-08 시점)

**적용하지 않음.** 현재 운영 use case 3가지가 정상이고, 무선쪽에서 박스 `eth0` IP로의 접근은 운영상 의도적으로 차단되어도 무방.

본 문서는 **미래에 다음 상황이 발생할 때 참조**:
- 무선쪽 mgmt 도구가 박스의 `eth0` IP를 직접 폴링해야 할 필요 발생
- 브릿지 설계 의도가 "어느 IF로든 박스 자체에 도달 가능"으로 변경
- 같은 패턴의 한계가 다른 형태(IPv6 self-IP 등)로 표면화

---

## 10. 참고 자료

- `mlinux/moal_bridge.c` line 379–485: `moal_bridge_rx_fast()` 전체
- `mlinux/moal_bridge.c` line 500–607: `moal_bridge_peer_rx_handler()` (eth0 측)
- `mlinux/moal_bridge.c` line 686–709: `moal_bridge_inetaddr_event()` — `peer_ipv4` 추적 코드
- `docs/driver-bridge.design.md` §4–6: 브릿지 패킷 흐름 설계
- `docs/driver-bridge.qa-runbook.md`: 실장비 QA 시나리오
- 메모리: `project_bridge_status.md` (브릿지 최적화 현황), `feedback_build.md` (빌드 방법)

---

*Source session: 2026-05-08 IP plan review (`feature/driver-bridge` branch). Latent finding archived for future reference.*
