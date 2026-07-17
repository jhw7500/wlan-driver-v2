# Bridge eth0-IP 토폴로지 지원 + 투트랙(pcap/moal) 운영 기준

> 2026-06-10. moal_bridge peer_ipv4 가드 확장과 함께 작성.
> 관련 코드: `mlinux/moal_bridge.c` (moal 가드), wlan-package `wlan-bridge/wbridge/filter.c` (pcap 가드),
> wlan-package `dist/wlan/usr/local/scripts/wifi_init.sh` (sysctl 정책 / `arp_ignore_always` 토글).

## 0. 용어

| 용어 | 의미 |
|---|---|
| BD (박스) | 브릿지 장치 자체 (moal/wbridge가 동작하는 보드). 본 문서의 "박스 IP" = BD 소유 IP |
| MAC_E | BD eth0 포트의 고유 MAC (Ethernet) |
| MAC_C | 클론 MAC (Clone) — 유선 클라이언트의 MAC이자 mlan0이 클론해 쓰는 MAC. 두 장치가 공유하므로 MAC으로 자기/포워딩 구분 불가 → 모든 가드가 IP 판정 |
| W2P / P2W | WLAN→Peer(eth0) / Peer(eth0)→WLAN 포워딩 방향 |

## 1. 토폴로지 정의

| | mlan0-IP (배포 기본) | eth0-IP (정식 지원 추가) |
|---|---|---|
| mlan0 | 공유 서브넷 IP (예: 192.168.0.100/24), 클론 MAC | 무IP 또는 타서브넷 IP |
| eth0 | 무IP 또는 관리 IP (예: 192.168.1.1/24) | 공유 서브넷 IP (예: 192.168.0.100/24) |
| 유선 클라이언트 | 192.168.0.x — MAC을 mlan0이 클론 | 동일 |

MAC-clone 공통 제약: mlan0 MAC == 유선 클라이언트 MAC이므로 MAC만으로 "박스 자신"과
"유선 클라이언트"를 구분할 수 없다. 자기/포워딩 판정은 L3(IP)로 한다.

## 2. 공통 위협: 이중 ARP 응답 레이스

박스 소유 IP에 대한 who-has가 브릿지를 거쳐 공중으로 유출되면, AP 반사를 거쳐
mlan0 커널 스택이 weak host model로 **클론 MAC(MAC_C)** 응답을 한 번 더 보낸다.
정상 응답(MAC_E)과 레이스 → 클라이언트 ARP 캐시가 MAC_E/MAC_C 사이를 오가며
간헐 단절. 차단 지점은 "**요청의 유출**"이며, 두 엔진이 각자의 위치에서 막는다.

## 3. 엔진별 보호 메커니즘 (투트랙 동등성)

| 보호 항목 | pcap (wbridge) | moal (driver bridge) |
|---|---|---|
| self-ARP 요청 유출 차단 | `filter_arp_is_for_bridge` — broadcast 분기에서 드롭 | SELF-ARP REQUEST 가드 (`ar_op==REQUEST`만) |
| ARP REPLY hairpin 보존 | unicast ARP는 필터 비대상 → 포워딩 유지 | REQUEST-only 억제 → REPLY 포워딩 유지 |
| self-IP unicast 유출 차단 | `filter_ip_is_local` (ETH_P_IP만) | W2P/P2W SELF-IP 가드 |
| 보호 IP 범위 | `interfaces[]` — eth0·mlan 양쪽 | `wlan_ipv4` + `peer_ipv4` 양쪽 |
| 활성 조건 | 런처 `--ip-filter` (wifi_bridge.sh가 항상 부여) | bridge_mode=1이면 항상 |

moal 가드는 wbridge filter.c 의미론을 의도적으로 이식한 것 (Design Ref §5.2).

## 4. 트랙 간 비대칭 (운영 시 인지 필요)

1. **stale 클론-MAC 캐시 회복**: moal은 `pkt_type` OTHERHOST→HOST 정정으로 즉시
   로컬 배달. pcap은 tap이라 커널 배달에 개입 불가 → 클라이언트가 broadcast
   재ARP로 MAC_E를 재학습할 때까지(수 초) 일시 블랙홀. 자가 회복되지만 체감 차이 존재.
2. **IP 캐시 갱신**: moal은 inetaddr notifier(주소 삭제 시 잔여 주소 재조회 포함).
   wbridge는 **시작 시 1회**(getifaddrs) — 기동 후 IP 변경(DHCP 재할당, peer_route
   토글에 따른 /32 미러 추가/제거)은 **브릿지 서비스 재시작 전까지 미반영**.
   IP/토글 변경 시 wbridge 재시작을 운영 절차에 포함할 것.
3. **다중 IP 시 보호 대상**: 두 엔진 모두 인터페이스당 캐시 1개. 선택 규칙이 다름
   (wbridge=시작 시 열거 마지막, moal=마지막 주소 이벤트). 둘 다 박스 소유 IP라
   안전하나 서로 다른 IP를 보호할 수 있음.
4. **tpacket 엔진은 지원 범위 밖**: 필터 미통합 + 런치 플래그 없음. 투트랙은
   pcap+moal에 한정한다.
5. **로컬 hairpin(`bridge_local_hairpin`)은 moal 전용**: 로컬발 TX(dst==클론 MAC)
   divert + ARP tee/inject로 BD↔유선peer 통신을 peer IP 인지(peer_route/
   ip_discovery) 없이 성립시킨다 (2026-07-17 실기 검증, AP intra-BSS 무반사
   환경의 유일 해법). pcap은 tap이라 TX 가로채기가 구조적으로 불가 — pcap
   트랙에서 BD↔유선peer가 필요하면 peer_route+ip_discovery를 유지해야 한다.
   상세: `docs/moal-bridge-local-hairpin.design.md`.

## 5. 지원 범위 명세

- **유선 클라이언트 ↔ 박스 IP**: 두 토폴로지·두 엔진 모두 지원 (이 문서의 핵심 대상).
- **무선 ↔ 유선 e2e 브릿징**: 항상 지원 (순수 L2, IP 스택 무관).
- **무선 클라이언트 → 박스 eth0-IP (eth0-IP 토폴로지)**: **미지원**.
  드라이버 가드는 스택 배달까지 시도하지만, (a) mlan rp_filter strict의 martian drop,
  (b) 박스 응답이 라우팅상 유선으로 misroute — 두 제약이 엔진 무관하게 막는다.
  박스의 무선측 통신이 필요하면 mlan0-IP 토폴로지를 쓰거나 mlan0에 타서브넷 IP를 둘 것.
- **moal W2P consume fast path**: `wlan_ipv4` 보유 시에만 활성. 무IP/DHCP 과도기에는
  clone+pass로 동작해 스택행 트래픽(DHCPOFFER 등)과 tcpdump 가시성을 보존.

## 6. 권장 베이스라인 설정 (eth0-IP 토폴로지)

```json
// /usr/local/etc/wifi_init_conf.json > wbridge
"peer_route":        { "enabled": false },  // mlan0-IP 전용 기능 — eth0-IP에선 off
"arp_ignore_always": { "enabled": true }    // 엔진 공통 ARP 정책 (arp_ignore=1/arp_announce=2)
```

`arp_ignore_always=true` 근거: moal에는 중복 방어(무해), pcap에는 wbridge 필터가
막지 못하는 잔여 edge — **공중발** who-has(eth0-IP)에 대한 mlan0 스택의 weak-host
MAC_C 응답 — 를 커널 단에서 차단해 트랙 간 외부 동작을 균일화한다.

주의: **mlan0-IP 토폴로지에서는 반드시 false 유지** — peer_route=off(출하 기본/degraded
fallback)와 조합 시 eth0이 mlan0 IP를 미소유한 채 arp_ignore=1이 되어 유선→박스 ARP가
무응답이 된다 (eth0의 /32 ARP responder 미러는 peer_route=on에서만 부여됨).

## 7. 실기 검증 체크리스트 (엔진 교차 — pcap/moal 각 1회)

1. 유선 클라이언트에서 `ping <박스 공유서브넷 IP>` 지속 — 손실 0, 수 분 유지
2. 클라이언트에서 `ip neigh show <박스 IP>` — MAC_E로 안정 (MAC_C 플랩 없어야 함)
3. 박스에서 `tcpdump -ni mlan0 arp or host <박스 IP>` — 해당 ARP/트래픽 공중 유출 없음
   - 유출(실패) 신호: `who-has <박스IP> tell <유선클라IP>` 가 TX로 나감, 또는
     src=<유선클라IP> dst=<박스IP> 유니캐스트가 TX로 나감 (hairpin)
   - 정상(오탐 아님): mlan0-IP 토폴로지에서 박스 자신의 무선 트래픽/ARP(`tell <박스IP>`),
     그리고 `<유선클라IP> is-at MAC_C` 형태의 ARP REPLY (의도적으로 보존한 hairpin)
   - RX 쪽 e2e 트래픽이 일부 안 보이는 것은 정상 — W2P consume 이 AF_PACKET 이전에 동작.
     consume 활성 조건은 `wlan_ipv4 != 0` 이므로: 변형 A(mlan0 무IP)는 RX 양방향 보임,
     **변형 B(mlan0 타서브넷 IP)는 공중발 e2e 가 mlan0 RX 에 안 보이는 것이 사양**
     (성능 최적 경로). W2P 디버깅은 eth0 측 캡처로: `tcpdump -ni eth0 host <상대IP>`
     — 포워딩 사본이 eth0 TX 로 나가므로 양방향이 보인다
4. 무선↔유선 e2e iperf/ping — 기존 성능 회귀 없음
5. (moal) `dmesg | grep "SELF-IP\|SELF-ARP"` (bridge_debug=1) — 가드 경로 동작 확인
6. (pcap) `WBRIDGE_DEBUG=1` 시 `arp-filter:/ip-filter:` 로그 — 필터 동작 확인
7. 토폴로지 전환/IP 변경 후: pcap이면 브릿지 서비스 재시작 수행 확인 (§4-2)

## 8. 검증 이력

- **2026-06-11, moal 엔진, 변형 B 실기 합격** (eth0=192.168.0.100/24, mlan0=192.168.1.1/24
  관리 IP, 유선 클라 .21 / 무선 클라 .110): 체크리스트 1·2·3·4 통과 — 유선→.100 ping 정상,
  클라이언트 neigh = MAC_E 안정, mlan0 캡처에 .100 유출 0건, e2e 양방향 정상.
  srcversion `7870B17ECEA5E2B509194A7`. dmesg 로 inetaddr 캐시 갱신
  (`wlan_ipv4 0.0.0.0 → 192.168.1.1`, `peer_ipv4 = 192.168.0.100`) 동작 확인.
- pcap 엔진 교차 검증: 미실시 (투트랙 운영 전 권장, §7 동일 절차)
