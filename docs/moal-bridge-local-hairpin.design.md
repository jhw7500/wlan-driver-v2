# moal 브릿지 로컬 hairpin 진행 계획

> 2026-07-17 작성. 목표: **박스↔유선 peer(OHT) IP 통신을 OHT IP 인지 없이(peer_route/ip_discovery 없이) 성립**시키는 드라이버 레벨 로컬 hairpin.
> 관련: `docs/bridge-eth0-ip-topology.md`, `docs/driver-bridge.design.md`, `mlinux/moal_bridge.c`

## 1. 배경 — 실측으로 확정된 전제 (2026-07-16, 실기 3대)

| # | 확정 사실 | 증거 |
|---|---|---|
| 1 | host route(`<OHT>/32 dev eth0`) 없으면 **OHT↔박스 IP 통신은 방향 불문 전멸** | routeless 확정 상태에서 OHT발신 100% loss. 커널은 응답 생성(OutEchoReps +10)했으나 main 라우트(mlan0)로 향해 neigh FAILED로 소멸 |
| 2 | **iif rule/table 100은 로컬 생성 응답을 조향하지 않음** (인바운드 rp_filter 검증용) | 동일 실험. wifi_init.sh "peer initiated는 iif 룰로 OK" 주석은 로컬 종단 트래픽에 대해 사실 아님 |
| 3 | **현장 AP(jhw_wlan_)는 intra-BSS 반사를 안 함** → 공중 hairpin 우회 불가 | 박스 who-has 3회 송출, 반사·응답 0건 (tcpdump) |
| 4 | ip_discovery는 부팅 race에 취약 | 2026-07-16 장애: mlan0 IP 적용 전 sweep → 잘못된 대역 → host route 미등록 |

∴ IP-무관 해법은 L2(MAC) 판정 기반 드라이버 로컬 hairpin이 유일. 핵심 통찰: **클론 MAC은 시스템이 이미 아는 값**(클론 대상 그 자체)이고, **로컬발 TX에서 dst==자기(클론) MAC인 유니캐스트는 정의상 유선 peer행**이다 — 무선망에 그 MAC을 가진 다른 장치가 없고, AP가 해줄 수 있는 것도 되반사뿐(그마저 이 AP는 안 함).

## 2. 요구사항 / 비요구사항

**요구:**
- R1. BD발신·OHT발신 양방향 박스↔OHT IP 통신, OHT IP 무지·AP 무의존.
- R2. mlan0-IP 토폴로지의 기존 3조건(OHT↔박스 / OHT↔무선 e2e / 무선↔박스) 무회귀.
- R3. 토글 가능(param), 기본 off로 출하 위험 0에서 시작.
- R4. hairpin off 시 기존 동작(공중 hairpin 코드 포함) 완전 보존.

**비요구 (이번 범위 밖):**
- pcap(wbridge) 엔진 지원 — tap 구조상 TX 가로채기 불가. 투트랙 비대칭으로 문서화만.
- eth0-IP 토폴로지 변경, 무선→eth0-IP 미지원 해제.
- ip_discovery/peer_route 제거 — 공존 유지(§6 매트릭스), 최종 구성 전환은 검증 후 별도 결정.

## 3. 설계 — 3개 메커니즘

### A. TX 유니캐스트 divert (핵심)
`woal_hard_start_xmit`(moal_main.c:5514 `.ndo_start_xmit`) 초입:

```
bridge active && dev == br->wlan_dev && local_hairpin
  && !is_multicast_ether_addr(eth->h_dest)
  && ether_addr_equal(eth->h_dest, dev->dev_addr)   /* == 클론 MAC */
→ skb->dev = br->peer_dev; moal_bridge_stamp_enq(); w2p_queue 인큐; wake; NETDEV_TX_OK
```

- 기존 w2p 워커 재사용: 큐 계약 일치 확인됨 — 워커는 `skb->dev`가 peer_dev로 설정된, data가 ETH 헤더를 가리키는 skb를 `dev_queue_xmit()`으로 송신 (moal_bridge.c:304). ndo_start_xmit 시점의 skb도 data=ETH 헤더 → 무변환 인큐 가능.
- 큐 cap(`MOAL_BR_W2P_QUEUE_MAX` 512)·drop 정책·teardown drain 모두 기존 것 상속.
- SDIO를 아예 안 타므로 성능·발열에 순이득.

### B. TX ARP broadcast tee
같은 hook에서 로컬발 **ARP REQUEST broadcast**를 `skb_clone`으로 w2p_queue에 tee, 원본은 공중으로 계속(무선 피어 ARP 유지).

- 대상 IP로 유선/무선 peer를 구분할 수 없으므로(그게 이 과제의 정의) 전량 tee. OHT는 자기 IP 아닌 who-has를 무시 — 무해, 발생률 극저.
- 이로써 박스의 `who-has <OHT IP>`가 유선으로 직접 OHT에 도달.

### C. P2W ARP REPLY 주입 (공중 hairpin 대체)
기존 rx_handler의 SELF-ARP 분기(moal_bridge.c:744-776) 확장: `ARP REPLY && target_ip == wlan_ipv4` (기존 `moal_bridge_arp_is_for_self` 재사용, op만 REPLY)일 때:

```
skb->dev = br->wlan_dev; skb->pkt_type = PACKET_HOST; netif_rx(skb); RX_HANDLER_CONSUMED
```

- `arp_process`는 수신 dev로만 pending neigh를 조회하므로(net/ipv4/arp.c) **mlan0로 주입해야** (ip, dev=mlan0) neigh가 풀림 — 기존 공중 hairpin(comment :753-757)이 하던 일을 AP 없이 수행.
- hairpin off면 기존 경로(공중 포워딩) 그대로 — AP 반사가 되는 현장과의 호환 유지.
- 주입 skb는 mlan0 RX에서 rx_fast를 타지 않음(rx_fast는 moal_recv_packet 내부 호출, netif_rx 경로 아님) → 재귀/루프 없음.

### 판정 안전성
- A의 오판 불가 논거: STA 모드에서 로컬발 dst==자기MAC 유니캐스트가 공중으로 가야 할 시나리오 부재(수신자가 자기 자신뿐). MAC-clone 환경에서 그 MAC의 유일한 타 소유자 = 유선 peer.
- C의 오판 불가 논거: target_ip==박스 소유 IP인 REPLY는 박스의 pending ARP에 대한 응답뿐. eth0에서 들어왔으므로 응답자는 유선측.

### 파라미터
- `bridge_local_hairpin` (int 0|1, 기본 0): module_param + mod_para.conf 파싱(moal_init.c:93-100, :902- 패턴 답습) + runtime `/sys/module/.../parameters/` 허용(0644, bridge_debug와 동일 취급 검토 — A/B 실험 편의).
- wlan-package: `wbridge.moal.local_hairpin` JSON 키 → insmod 인자 플러밍 (별도 repo PR, moal.debug 키 패턴).

## 4. 단계별 계획

### Phase 0 — 계약 검증 (0.5d)
- [ ] TX hook 위치 확정: `woal_hard_start_xmit` 초입에서 eth 헤더 접근 안전성(리니어 여부), NETDEV_TX_OK 반환 계약, mon 경로(:5253)와의 무간섭.
- [ ] skb->cb 소유권: TX 경유 skb에 `moal_bridge_stamp_enq()`(cb 사용) 안전한지 — qdisc 이전이므로 안전 추정, 확인.
- [ ] netif_rx 주입: softirq(rx_handler) 컨텍스트에서 호출 안전성, pkt_type/protocol/csum 필드 처리.
- [ ] GSO/CHECKSUM_PARTIAL skb가 w2p 워커의 dev_queue_xmit로 eth0에 나갈 때 오프로드 처리 확인(코드 리딩 + Phase 1 iperf로 실증).
- [ ] **브랜치 base 결정**: rx-jitter 브랜치(현 checkout, moal_bridge.c 계측 포함) 머지 전이면 충돌 관리 방안 확정.
- 산출: 본 문서에 확정 설계 노트 추가.

### Phase 1 — 메커니즘 A + 인프라 (1d)
- [ ] A 구현 + `bridge_local_hairpin` param + 통계 카운터(`hairpin_tx_fwd/tee/inject/dropped` — 기존 moal_bridge_stats 패턴) + BR_DBG 로그.
- [ ] 빌드: `make_for_imx93.sh` (iMX93 필수 경로).
- [ ] 실기(중간 검증, host route 있는 상태): hairpin on → BD→OHT 트래픽이 SDIO 대신 w2p 경유하는지 카운터로 확인, RTT 비교(기대: 기존 0.38ms 동급), iperf BD→OHT(GSO 실증).

### Phase 2 — 메커니즘 B+C: ARP 완결 (1d)
- [ ] B(tee) + C(주입) 구현.
- [ ] 실기: **host route 삭제 + neigh flush 확정 상태**에서 BD발신 ping/TCP 성립 검증 — 어제까지 불가능했던 것이 성립하면 IP-무관 달성.
- [ ] 검증 방법론: 상태 변경과 트래픽 유발을 **반드시 순차 도구 호출**로 분리(2026-07-16 병렬 타이밍 아티팩트 교훈 — 상태 확정 출력 확인 후 다음 단계).

### Phase 3 — 통합 검증 + 최종 구성 + 정리 (1d)
- [ ] §5 매트릭스 전체 수행.
- [ ] 최종 목표 구성 실증: `peer_route=off + ip_discovery=false + arp_ignore_always=false + local_hairpin=1` 재부팅 포함 — OHT IP가 시스템 어디에도 없는 상태에서 3조건 성립.
- [ ] 킬러 데모: OHT IP 런타임 변경(.220→.221) 후 무설정 통신 지속.
- [ ] 회귀: 조건 2·3, iperf 상/하향, rx-jitter 계측(TX 경로 접점) 무회귀.
- [ ] 문서: driver-bridge.design.md 설계 절 추가, bridge-eth0-ip-topology.md §4 투트랙 비대칭 항목 추가, wifi_init.sh "peer initiated는 iif 룰로 OK" 주석 정정(wlan-package).
- [ ] wlan-package JSON 키 플러밍 PR + 본 repo PR.

## 5. 검증 매트릭스

| # | 구성 | 시나리오 | 기대 |
|---|---|---|---|
| V1 | hairpin=1, peer_route=on(현행) | OHT발신 ICMP/TCP | 정상(공존), host route 경로와 무충돌 |
| V2 | hairpin=1, host route 삭제 | OHT발신 ICMP/TCP | **정상** (어제 100% 실패 케이스) |
| V3 | hairpin=1, host route+neigh 삭제 | BD발신 ICMP/TCP | **정상** (ARP tee+주입 검증) |
| V4 | hairpin=1, peer_route=off+discovery=off, 재부팅 | 3조건 전체 | 전부 정상, dmesg에 discovery 미의존 확인 |
| V5 | V4 상태 | OHT IP .220→.221 변경 | 무설정 통신 지속 |
| V6 | hairpin=0 | 전 시나리오 | 기존 동작 완전 일치(회귀 0) |
| V7 | hairpin=1 | 무선 e2e iperf, rx-jitter legtrace | 무회귀 |
| V8 | hairpin=1, eth0 링크 down | BD발신 | 기존 drop 정책대로 graceful(dev_ready 가드) |

## 6. 리스크 / 엣지

| 리스크 | 대응 |
|---|---|
| TX hotpath 오버헤드 | off 시 분기 1개(READ_ONCE). on 시 비대상 프레임엔 MAC 비교 1회 |
| GSO/checksum skb → eth0 | dev_queue_xmit가 validate/segment 처리. Phase 1 iperf 실증 |
| ARP 전량 tee의 유선 노이즈 | who-has broadcast 수 pps 미만 — 무해. 카운터로 관측 |
| netif_rx 주입 프레임의 상위 스택 부작용 | ARP REPLY 한정+target_ip 검증. AF_PACKET엔 mlan0 수신으로 보임(tcpdump 의미 변화 — 문서화) |
| mlan1/다중 인스턴스 | `dev == br->wlan_dev` 비교로 인스턴스 격리(기존 패턴) |
| teardown race | 기존 w2p drain/synchronize 경로 재사용, active 가드 |
| rx-jitter 브랜치와 moal_bridge.c 충돌 | Phase 0에서 base 결정 |
| 비ARP broadcast(예: 앱 UDP broadcast) BD→OHT 미달 | 현행과 동일(악화 아님). 필요 시 전체 tee 옵션은 후속 — 오픈 퀘스천 |

## 7. 롤아웃 / 롤백

- 기본 off 출하 → 대상 현장(AP 무반사 + BD발신 요구)만 JSON으로 on → 실증 누적 후 mlan0-IP 토폴로지 기본값 전환 논의.
- 롤백 = param 0 (runtime 즉시 또는 mod_para.conf). 코드 제거 불요.

## 8. 오픈 퀘스천 → 결정 (2026-07-17 Phase 0)

1. 브랜치 base: **`feature/moal-rx-jitter-deliver-rt` 위에 `feature/moal-bridge-local-hairpin`** — 실기 배포 드라이버가 rx-jitter 빌드임을 srcversion으로 확인, 동일 baseline 유지가 A/B에 유리.
2. B의 tee 범위: **ARP broadcast만** (계획대로 최소). 비ARP broadcast BD→OHT 미달은 현행과 동일 — 필요 시 후속.
3. media_connected 정책: **현행 active 조건 준수** (TX hook은 bridge active만 확인 — media 무관이라 무선 down에도 wire-local은 동작 여지, 단 보증 대상 아님).
4. runtime param: **0644 허용** — V6 flip 검증에 실사용, A/B에 필수적.
5. (Phase 0 추가 확인) skb->cb: ndo_start_xmit 시점은 qdisc 이후라 bridge 소유 안전. GSO: mlan0이 GSO 미광고 → 스택이 MTU 분할 후 전달, hook에 super-frame 미도달(벌크 실측 avg 1342B/frame으로 확인).

## 9. 실측 결과 (2026-07-17, Phase 1~2 완료)

srcversion `C8C224797E1817FF6D36AD2`, 실기 3대 (박스 cts-wlan / OHT imx93 / 무선서버 pim-camera).

| 검증 | 결과 |
|---|---|
| V1 공존 (hairpin=1 + host route) | ✅ 무회귀, 카운터 0 (route 존재 시 divert 미개입 확인) |
| V2 routeless OHT발신 | ✅ ICMP 8/8 0.49ms + TCP — **전일 100% 실패 케이스 해결** |
| V3 routeless BD발신 | ✅ ICMP 8/8 0.47ms + TCP — **신규 능력** (종전 불가능) |
| 메커니즘 카운터 | ✅ tx_fwd=26 / arp_tee=2 / arp_inject=1, mlan0 neigh REACHABLE(주입 해소) |
| V6 flip 인과 | ✅ hairpin=0→100% loss, =1→0% loss (결정적) |
| 벌크 TCP 50MB (divert 경로) | ✅ 39,043 frames drop=0 err=0 oom=0. 11.3s vs 직행 9.2s (nc/dd endpoint 지배 구간) |
| V4 최종구성 재부팅 (`peer_route=off + ip_discovery=off + local_hairpin=1` insmod) | ✅ host route/32미러/iif rule 전부 0인 상태에서 3조건 전체 성립. hairpin이 insmod 인자로 로드(parmtype 게이트 통과) |
| V5 OHT IP 런타임 변경 (.220→.221) | ✅ 박스 무설정 양방향 즉시 통신 (BD발신 .221 5/5 0.46ms, arp tee/inject 카운터로 새 ARP 해소 확인) — ip_discovery(부팅 1회)로는 불가능한 시나리오 |
| V7 무선 e2e 회귀 | ✅ 무선↔box 3/3, 무선↔OHT 10/10 (일시 ARP 첫패킷 손실 1건은 재검에서 미재현) |

V4 관찰: peer_route=off에선 OHT의 박스 neigh가 MAC_C로 정착할 수 있음(박스 hairpin-tee who-has의 sha=mlan0 MAC에서 학습) — dst=MAC_C 프레임은 P2W SELF-IP 가드가 HOST 정정 배달하므로 기능 무영향(0.58ms 실측). MAC_E/MAC_C 어느 쪽이든 배달 경로 존재.

**최종 rig 상태**: `peer_route=on + ip_discovery=on + local_hairpin=1` — 기존 운영 구성에 hairpin을 보험으로 얹은 이중 방어 (discovery 실패/부팅 race 시에도 통신 유지). 출하 기본값 결정은 §7 롤아웃 정책대로 별도 논의.

정적 검사 게이트: 함수 성장으로 rx_handler(-A200)/pt(-A160) 창 초과 → 260/220으로 확장 (`scripts/tests/bridge_static_checks.sh`).
wlan-package 플러밍: `wbridge.moal.local_hairpin` JSON 키 + wifi_init.sh parmtype 게이트 추가 (템플릿 문서화 포함).

## 10. 공수 요약

계획 3.5~4d → **실제 Phase 0~2 약 0.5d에 완료** (실기 접근·기존 ssh 검증 방법론 재사용 효과). V4/V5는 진행 중.
