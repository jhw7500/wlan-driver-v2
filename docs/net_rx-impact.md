# `net_rx` 모듈 파라미터가 무선통신 / 브릿지 통신에 미치는 영향

`net_rx`가 mlan/moal 드라이버에서 실제로 무엇을 제어하는지, 그리고 그 효과가 무선(STA/AP RX 경로)과 L2 브릿지 경로에서 각각 어떻게 나타나는지 코드 레벨로 정리.

대상: NXP 88W9098 (iMX8MM PCIe / iMX93 SDIO), moal L2 bridge 엔진.

## 0. 핵심 결론

1. **`net_rx`는 두 축으로 오버로드되어 있다** — 하위 2비트(`& 0x3`)는 RX 스택 전달 방식 + RX mgmt 로깅 레벨, 비트2(`& 0x4`)는 TX mgmt 로깅. default = 1.
2. **RX 전달 방식(bit0)은 값 ≥1이면 항상 `netif_receive_skb` 경로로 고정** — backlog(`netdev_max_backlog`/RPS) 우회. 값 ≥2/≥3은 전달방식은 그대로 두고 로깅·mask 잠금만 추가.
3. **`net_rx>=2`는 순수 로깅이 아니라 실제 펌웨어 mgmt indication mask를 강제 잠금** — wpa_supplicant의 subtype mask 변경을 무시하므로 무선 제어 경로에 개입한다.
4. **L2 브릿지 forwarding 트래픽은 `net_rx`와 사실상 무관** — 브릿지 fast path가 `eth_type_trans`/`net_rx` 분기보다 앞에서 패킷을 소비(`continue`)하기 때문.

---

## 1. 값 체계

| 값 | RX 전달 방식 | RX mgmt 로깅 | mgmt mask 잠금 | TX mgmt 로깅 |
|---|---|---|---|---|
| 0 | `netif_rx_ni()` (backlog 경유) | — | — | — |
| 1 (default) | `netif_receive_skb()` (backlog 우회) | — | — | — |
| 2 | =1 | roaming 프레임만 | `MGMT_LOG_MASK_ROAMING` lock | — |
| 3 | =1 | 전체 프레임 | `MGMT_LOG_MASK_ALL` lock | — |
| +4 (6, 7) | 하위 2비트 그대로 | 상동 | 상동 | `& 0x4` → TX 로깅 on |

`mlinux/moal_init.c:3189-3192` MODULE_PARM_DESC:
```
0: netif_rx_ni; 1: netif_receive_skb; 2: 1+roaming RX log; 3: 1+all RX log;
+4: TX log (e.g. 6=roaming RX+TX, 7=all RX+TX)
```

- 파라미터 정의: `mlinux/moal_init.c:90` `static int net_rx = 1;`
- per-adapter 오버라이드: `wifi_init_conf.json` → `moal_init.c:892-897` (`net_rx = <val>`)
- 저장 위치: `handle->params.net_rx` (`moal_main.h:2657`)
- **모듈 리로드해야 반영** (permission 0, runtime write 불가).

---

## 2. 무선통신에 미치는 영향

### 2.1 RX latency 특성 — bit0 (STA/AP 공통 RX 업로드 경로)

`mlinux/moal_shim.c:2171-2186` (A-MSDU deaggr 경로), `:2576-2591` (일반 recv 경로) — 동일 분기:
```c
if (in_interrupt())                          netif_rx(frame);   // net_rx 무관
else if (rx_pending > MAX_RX_PENDING_THRHLD) netif_rx(frame);   // net_rx 무관
else if (net_rx >= 1) { local_bh_disable(); netif_receive_skb(frame); local_bh_enable(); }
else                  netif_rx_ni(frame);   // (5.17+ 에선 netif_rx)
```

- `net_rx>=1`: per-CPU backlog(`input_pkt_queue`)를 **우회**하고 stack에 즉시 push → RX latency ↓. 대신 `netdev_max_backlog`, RPS의 backlog 분산 효과가 약해진다.
- `net_rx=0`: backlog 경유 → RPS cross-CPU 분산·backlog 깊이가 의미를 가짐. 처리 CPU 오프로드 유리하나 큐잉 latency 추가.
- **override 우선순위**: `in_interrupt()`(hard IRQ 컨텍스트 처리) 또는 `rx_pending > MAX_RX_PENDING_THRHLD`이면 값과 무관하게 항상 `netif_rx()`. 즉 폭주 상황에선 net_rx 설정이 무시된다.

### 2.2 펌웨어 mgmt indication mask 강제 잠금 — net_rx≥2 (실제 제어 경로 개입)

값이 2 이상이면 로그를 남기기 위해 host로 올라오는 mgmt frame 집합 자체를 강제한다. 이는 관찰이 아니라 **펌웨어 RX mgmt 등록을 바꾸는 동작**이다.

- `mlinux/moal_cfg80211.c:2595-2611` `woal_mgmt_frame_register()`:
  wpa_supplicant의 frame 등록 요청을 무시하고 `net_rx&0x3==3 ? MGMT_LOG_MASK_ALL : MGMT_LOG_MASK_ROAMING`로 `woal_reg_rx_mgmt_ind(MLAN_ACT_SET)` 강제 후 early return.
- `mlinux/moal_cfg80211.c:2690-2703` `woal_cfg80211_update_mgmt_frame_registrations()`: 동일하게 supplicant 변경 무시하고 mask lock.
- `mlinux/moal_shim.c:3177-3193` (연결 완료 이벤트): 재접속/roaming 시에도 동일 mask 재적용.

영향:
- `net_rx=2`(ROAMING): auth/assoc/deauth/action 등 roaming 관련 mgmt만 host로. 데이터 통신 영향은 미미.
- `net_rx=3`(ALL): beacon/probe req/resp까지 **전부 host 업로드** → CPU·이벤트 처리 부하 급증, supplicant의 mgmt 수신 동작에 side effect 가능. 상시 운용 비권장(디버깅 한정).

### 2.3 mgmt frame 로깅 (관찰 전용, 데이터 경로 무영향)

- RX: `mlinux/moal_shim.c:4505-4561` `MLAN_EVENT_ID_DRV_MGMT_FRAME`. `net_rx&0x3==2`면 noisy(probe req=4/resp=5/beacon=8) skip, `==3`이면 전체. SA/DA/RSSI/NF/SNR/Retry/Seq를 `mgmt_log` 링버퍼에 기록.
- TX: `mlinux/moal_cfg80211.c:3240-3274` (mgmt tx), `mlinux/moal_sta_cfg80211.c:2829, 3421, 5300, 6186, 6252` (auth/assoc/deauth 등 송신 시점). `net_rx & 0x4`에서만 동작.
- `mgmt_hex_dump` 파라미터와 조합 시 full IE hex dump까지 (`net_rx>=2` RX 및/또는 `net_rx&0x4` TX 필요).
- 출력: `/proc/mwlan/adapter*/mgmt_log`, `mgmt_dump` (`mlinux/moal_proc.c:1799`).
- 부하: 링버퍼 write I/O만. 패킷 forwarding 데이터 경로엔 개입하지 않음.

---

## 3. 브릿지 통신에 미치는 영향 — 거의 없음

핵심: **L2 브릿지 fast path가 `net_rx` 분기보다 앞에 위치**하여, 브릿지로 forwarding되는 패킷은 `net_rx`의 전달 방식 선택에 도달하기 전에 소비된다.

`mlinux/moal_shim.c:2158-2186` (A-MSDU deaggr 서브프레임 경로):
```c
/* L2 bridge fast path (A-MSDU sub-frame, before eth_type_trans). */
if (br_amsdu_active && moal_bridge_rx_fast(br_amsdu, frame, priv))
    continue;                          // ★ net_rx 분기 도달 전 소비

frame->protocol = eth_type_trans(frame, netdev);
...
else if (net_rx >= 1) { ... netif_receive_skb ... }   // 브릿지 트래픽은 여기 안 옴
```

- 일반 recv 경로도 동일하게 fast path로 선처리됨 — 주석 `mlinux/moal_shim.c:2572` "L2 bridge: moved to fast path (before eth_type_trans)".
- 따라서 **브릿지 forwarding 트래픽의 latency/처리 특성은 `net_rx` 값과 무관**하다. `net_rx`는 브릿지가 소비하지 않고 로컬 mlan0 스택으로 올라가는 패킷(로컬 IP 향, self-IP filter 통과 제어 트래픽)에만 작용한다.
- `net_rx>=2`의 mgmt mask 잠금도 mgmt frame은 데이터 forwarding 대상이 아니므로 브릿지 데이터 경로와 무관.

이는 `docs/wbridge-mode-impact.md` §3.3의 결론("`net_rx>=1` 경로 → backlog 우회 … moal bridge RX는 backlog 거의 안 거침")과 정합.

---

## 4. 운용 권고

1. **일반 운용**: `net_rx=1` 유지. 브릿지 데이터 경로는 어차피 fast path라 영향 없고, 로컬 스택 향 트래픽만 backlog 우회로 latency 이득.
2. **roaming/auth 디버깅**: `net_rx=6`(=2+TX) 권장 — roaming mgmt RX/TX만 로깅해 noise 최소. beacon/probe 폭주 없음.
3. **`net_rx=3`/`7`(ALL)은 단기 디버깅 한정** — beacon/probe 전량 host 업로드로 CPU 부하·supplicant side effect 위험. 상시 금지.
4. **latency 튜닝 관점에서 `net_rx=0`은 비권장** — backlog 경유로 RX latency 증가. RPS cross-CPU 분산이 반드시 필요한 특수 케이스에만.
5. 브릿지 throughput/latency를 `net_rx`로 조정하려는 시도는 무의미 — 튜닝 지점은 `bridge_keepalive_ms` hrtimer, `MAX_TX_PENDING`, IRQ affinity (`docs/wbridge-mode-impact.md` 참조).

---

## 5. 코드 위치 인덱스

- `mlinux/moal_init.c:90` — `static int net_rx = 1` (default)
- `mlinux/moal_init.c:892-897` — `wifi_init_conf.json` per-adapter 파싱
- `mlinux/moal_init.c:1861-1863` — `handle->params.net_rx` 대입
- `mlinux/moal_init.c:3189-3196` — `module_param` + PARM_DESC (net_rx / mgmt_hex_dump)
- `mlinux/moal_main.h:2657` — `int net_rx;` (params 구조체)
- `mlinux/moal_main.h:4289` — mgmt 로깅 mask 정의(`MGMT_LOG_MASK_*`)
- `mlinux/moal_shim.c:2171-2186` — RX 전달 분기 (A-MSDU deaggr)
- `mlinux/moal_shim.c:2158-2163` — 브릿지 fast path (net_rx 분기 앞)
- `mlinux/moal_shim.c:2576-2591` — RX 전달 분기 (일반 recv)
- `mlinux/moal_shim.c:3177-3193` — 연결 완료 시 mgmt mask 재적용
- `mlinux/moal_shim.c:4505-4561` — RX mgmt frame 로깅
- `mlinux/moal_cfg80211.c:2595-2611` — `woal_mgmt_frame_register` mask 잠금
- `mlinux/moal_cfg80211.c:2690-2703` — `update_mgmt_frame_registrations` mask 잠금
- `mlinux/moal_cfg80211.c:3240-3274` — TX mgmt 로깅
- `mlinux/moal_sta_cfg80211.c:2829, 3421, 5300, 6186, 6252` — STA TX mgmt 로깅 지점
- `mlinux/moal_proc.c:52, 1799` — `mgmt_log` proc 엔트리

---

## 6. 작성 컨텍스트

- 작성일: 2026-07-22
- branch: `claude/net-rx-impact-analysis-v77hr5`
- 관련 문서: `docs/wbridge-mode-impact.md`(§3.3 backlog 우회), `docs/MOAL-Module-Parameters.md`
