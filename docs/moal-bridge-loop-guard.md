# moal 브릿지 루프 가드 (`bridge_loop_guard`, #117)

> 2026-11-02 작성. 관련: `docs/driver-bridge.design.md`, `docs/MOAL-Module-Parameters.md` §11.12,
> `mlinux/moal_bridge_loopguard.h`, `mlinux/moal_bridge.c`, 이슈 jhw7500/wlan-driver-v2#117,
> 유저스페이스 엔진 쪽 jhw7500/wlan-bridge#76, 발단 jhw7500/wlan-package#376.

## 1. 기전

브리지 보드 두 대의 peer(eth0)가 같은 유선 스위치에 있고 두 STA가 같은 ESS에 붙으면
유선과 무선 사이 경로가 둘이 된다. AP는 멀티캐스트(SSDP, ICMPv6 등)를 STA별 유니캐스트로
바꿔 보내므로, A의 w2p가 이를 peer로 내보내고 스위치가 B의 peer로 넘기면 B의 p2w가 공중으로
올리고 AP가 다시 A에게 내려 보낸다. 한 프레임이 A의 w2p와 B의 p2w만 번갈아 지나며 돈다.
2026-10-24 두 보드 재현에서 eth0당 60초에 약 10만 프레임, 한 바퀴 약 1.4 ms였다(wlan-package #376).

브리지에는 STP, 출발지 학습, 중복 억제가 없었다. MAC 기반 규칙은 쓸 수 없다.
- 드라이버는 클론 모드를 모른다(`dev_addr`만 있음).
- STA 모드 WLAN RX의 `h_dest`는 항상 자기 MAC이라 "dst가 자기 MAC이면 버림"은 w2p 유니캐스트 전체를 버리는 것과 같다.
- "w2p에서 본 src가 p2w에 다시 나타나면 버림"은 한 프레임이 한 보드의 두 방향을 모두 지나지 않으므로 이 고리를 끊지 못한다.

## 2. 규칙

방향(w2p, p2w)별 테이블 `u64 slot[512]`(4 KiB)에 최근 L2 유니캐스트의 해시를 기억한다.

- 키: `jhash(L2 헤더부터 min(선형 길이, 128) 바이트, seed ^ 프레임 길이)`. 슬롯 인덱스는 그 해시를 한 번 더 섞은 값의 하위 9비트.
- 슬롯: `tag:32 | tick:24 | cnt:8`. tick은 첫 관측 시점의 jiffies 하위 24비트, 창은 첫 관측부터 고정 50 ms.
- 스위프: 마지막 스위프 뒤 2^23 tick(HZ=1000 에서 약 2.3 h, 24비트 tick 주기의 절반)이 지나면 다음 관측에서 테이블을 통째로 비운다. 슬롯이 한 주기 넘게 살아남아 다음 주기의 같은 자리(k×4.66 h ± 50 ms)에 온 같은 키 프레임을 창 안으로 오인하는 리산을 막는다(PR #118 Codex 지적). 스위프 시각은 전체 폭 jiffies 로 따로 기억한다.
- 같은 tag가 창 안에 다시 오면 cnt를 올린다. cnt 2 = 감지(dup, 포워딩 유지), cnt ≥ 3 = 폐기(drop).
- 창이 지났거나 다른 tag가 같은 슬롯에 오면 새로 시작한다(충돌은 한 프레임을 놓칠 뿐 오폐기를 만들지 않는다).
- 그룹 주소(브로드캐스트·멀티캐스트)는 판정하지 않는다.
- 락 없음: `READ_ONCE`/`WRITE_ONCE`. 두 방향은 테이블이 따로라 경합이 없고, 같은 방향의 경합은 적게 셀 뿐이다.

판정 지점(`mlinux/moal_bridge.c` `moal_bridge_loop_repeat`):
- w2p 소비 경로(비자기 IPv4 유니캐스트): 큐 길이 증가 전. 폐기 시 `kfree_skb`, `wlan_to_peer.dropped`+1.
- w2p clone 경로(비IPv4 유니캐스트 등): 폐기 시 peer로 복제하지 않고 원본은 그대로 스택에 배달.
- p2w rx_handler(비자기 유니캐스트)와 packet_type 폴백: 큐 길이 증가 전. 폐기 시 `peer_to_wlan.dropped`+1.
- `tx_hairpin`·roam announce·그룹 주소 분기는 건드리지 않는다.

## 3. 제어와 관측

- 모듈 파라미터 `bridge_loop_guard`(int, 0644, 기본 1). 런타임 `/sys/module/moal/parameters/bridge_loop_guard`로 0/1. 0이면 판정 자체를 건너뛴다(테이블 갱신 없음).
- `/sys/kernel/moal_bridge/stats`: `loop on=<0|1> w2p_dup=<N> w2p_drop=<N> p2w_dup=<N> p2w_drop=<N>`. drop은 방향별 `drop=`에도 합산.
- `bridge_debug=1`이면 폐기마다 `bridge: <w2p|p2w> LOOP drop dst= src= proto= len=` 로그.

## 4. 한계

- 그룹 주소로 도는 고리는 막지 못한다(이번 재현의 고리는 유니캐스트였다).
- 첫 통과는 막지 못하므로 스위치가 클론 호스트 MAC을 다른 포트에 학습하는 FDB 오염은 남는다. 클론 모드에서 관리 접속 유지는 이 가드만으로 보장되지 않는다.
- 키는 앞 128 B + 길이다. 128 B 뒤에서만 달라지는 같은 길이의 유니캐스트(예: 뒤쪽에 순번·상태 필드가 있는 고정 길이 payload)는 같은 키로 판정된다.
- 같은 키의 유니캐스트를 25 ms 미만 주기로 계속 보내는 정상 스트림은 창이 첫 관측에 고정되므로 50 ms 창마다 K−1(=2)개만 통과하고 나머지는 버려진다(슬롯 시뮬레이션, HZ=1000: 4 ms 주기 250개 중 210개 폐기, 10 ms 주기 100개 중 66개 폐기). 2026-10-24 캡처 재생에서 고리 외 흐름 중 걸린 것은 ARP Reply 연타(고리 부산물로 추정) 하나였고, 산업용 1:1 트래픽 표본은 아직 없다. iperf3 종료 때 상대 STA 가 큐에 남은 세그먼트마다 보내는 동일 TCP RST 폭주도 여기에 걸리지만 연결 종료에는 영향이 없었다(§5.2).
- 프레임 재귀 간격이 창/(K−1) = 25 ms 를 넘는 고리는 끊지 못한다. 세 번째 관측이 첫 관측의 50 ms 창을 벗어나면 슬롯이 pass·dup 만 반복한다(시뮬레이션: 26 ms·30 ms 재귀에서 1 s 동안 폐기 0). 매체 혼잡이나 AP 버퍼링으로 바퀴 시간이 늘어난 고리가 여기에 해당한다. §6 의 재등장 간격 통계(p99 17.5 ms)는 단일 재등장 분포라 이 조건과 같은 양이 아니다.
- 새 프레임은 K−1(=2)번 돈 뒤에 버려진다. 재생 측정에서 첫 폐기까지 중앙값 13~26 ms. 테이블 스위프(약 2.3 h 마다 1회)에 걸친 고리는 K−1개를 한 번 더 통과시킨다.

## 5. 검증

1. 호스트: `bash scripts/tests/loopguard_host_test.sh`(슬롯 로직 7 단언), `bash scripts/tests/bridge_static_checks.sh`.
2. 1:1 클론 회귀(보드 1대, 유선 클라이언트 1대): 같은 .ko에서 `bridge_loop_guard` 0/1만 바꿔 ping p99(`ping -c 1000 -i 0.01`), iperf3 TCP/UDP, DHCP·ARP·ND·브로드캐스트 동작을 비교한다. 정상 트래픽에서 `w2p_drop`·`p2w_drop`은 늘지 않아야 한다. 양성 대조: 같은 UDP 페이로드를 10 ms 주기로 보내면 폐기가 생기고 100 ms 주기면 0이어야 한다.
   2026-11-02 측정(유선 클라이언트 → 보드 → AP → 상대 STA, guard 1 / 0): TCP up 21.7 / 19.7 Mbps, TCP down 14.0 / 14.4 Mbps, UDP 20 Mbps 손실 0 % / 0 %, ping 1000회 avg 2.13 / 1.89 ms·손실 0. 차이는 무선 구간 변동 범위다. guard=1 에서 늘어난 `w2p_drop` 은 iperf3 종료 때 상대 STA 가 큐에 남은 세그먼트마다 보내는 동일 TCP RST(54 B, IP id 0) 폭주 억제였다(eth0 캡처 전수 대조에서 50 ms 안 반복 키는 RST 한 종류, `dmesg -w` LOOP drop 줄 전부 `len=54`). 재현할 때 `bridge_debug=1` 은 p2w 프레임마다 로그를 찍어 링 버퍼를 덮으므로 LOOP drop 줄은 `dmesg -w` 로 스트리밍해 받아야 한다.
3. 두 보드 재현(같은 스위치·같은 ESS): guard 0에서 폭주를 재현한 뒤 guard 1로 바꾸면 수 초 안에 eth0 고리 흐름이 사라지고 `*_drop`이 소량 증가해야 한다. 한쪽 보드만 켠 경우도 확인한다.

## 6. 설계 입력 (2026-11-02)

wlan-package #376 재현 캡처(두 보드 eth0, 60 s) 재생: 같은 키의 재등장 간격 p50 4.0 ms, p99 17.5 ms, 50 ms 이내 99.8%. 고정 창 50 ms·K=3에서 반복 키 b1 16/21, b2 17/18 차단, 첫 폐기까지 중앙값 13.5~25.9 ms. 나머지 키는 재등장 간격이 길어(최대 약 4.9 s) 고리 흐름이 아니다.
