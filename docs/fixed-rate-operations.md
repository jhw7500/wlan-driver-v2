# 특정 MCS / legacy bitrate 고정·제한 — 검토 요약과 운영안

2026-09-11 · wlan-driver-v2 ported + wlan-package 배포본 · cts-wlan(iMX93, 88Q9098 FW p149.115) 실측. 상세 근거는 `docs/fixed-rate-review.md`.

## 1. 가능 범위

| 목표 | 가능 | 수단 | 로밍·재연결 유지 | 조건 |
|---|---|---|---|---|
| TX 특정 MCS 고정 (HT/VHT/HE) | 가능 | `ratebitmapcfg` 2-word(목표 MCS + OFDM 6M) 또는 `txratecfg` | 매 연결 재적용(`on_connect.commands`) | 광고 tier·NSS 안(제품: MCS0~7, NSS1) |
| TX 특정 legacy rate 고정 | 가능 | `txratecfg 0 <idx>` | 매 연결 재적용 | 5GHz OFDM(6~54M)만, 링크 유지 가능한 값 |
| 양방향 세대 상한 (a/n/ac/ax) | 가능 | `radio.mode`(`bandcfg`) | 훅 없이 유지 | 모드 변경 시 disconnect |
| RX NSS·tier 상한 | 가능 | `antcfgnss`, `mcstiercfg` | 유지 | VHT/HE 최저 tier = 0~7 |
| RX HT MCS 단위 상한 | AP 의존 | HT Rx MCS 비트마스크(실험 드라이버) | 유지 | Realtek 11n AP 존중, HE AP 무시 |
| RX 특정 MCS 고정 | 불가 | — | — | AP 설정 필요 |
| RX 특정 legacy rate 고정 | 불가 | — | — | basic rate 제거 불가, AP RA 선택 |

## 2. 실측 근거 요약

| 실험 | 관측 | 의미 |
|---|---|---|
| `txratecfg 1 3` / `3 2 1` / `0 4` | TX HT MCS3 / HE MCS2 / LG 6M 즉시 | 고정은 모든 포맷에서 동작 |
| disconnect·ifdown 직후 FW GET | Auto | FW가 link 해제 시 소거 → 재적용 필요 |
| HT/HE 단일 고정 중 reassociate/roam | 게이트 dmesg, 첫 시도 실패·roam 실패 | `mlan_join.c:327` 게이트 |
| 2-word scope {6M, MCS n} 후 roam·reassoc 6회 | 전부 성공, TX=목표 MCS | 드라이버 수정 없이 로밍 안전 |
| 연결 전 SET | 83초 접속 불가 | 부팅 전 적용 금지 |
| 5GHz CCK / VHT MCS8 / HE MCS9·11 / NSS2 고정 | 1Mbps, 손실 100% | 교집합 공집합 → 검증기 필수 |
| legacy 54M 고정 | 손실 100% (auto RA는 48M) | 링크 유지 가능성 검증 |
| HT Rx 마스크 {MCS3-5} on Realtek AP | DL MCS5, UL MCS5 | 협조 AP는 집합 최고 MCS 상한 |
| HT Rx 마스크 {MCS3} 단독 | DL legacy 6M 폴백 | 단일 RX 고정 불성립 |
| HT Rx 마스크 on HE AP(HT-only) | DL MCS7(무시) | AP 의존 |
| legacy-only(`bandcfg 0x7`) on HT/VHT/HE AP | DL 54M, UL 36~48M, roam 유지; 중부하 DL 24~48M | 상한이지 고정 아님, 훅 불필요 |
| legacy-only + OFDM 6M on HE AP | UL 6M, DL 54M | "TX 6M + RX ≤54M" 성립 |

## 3. 운영안

### A. 세대 상한 (TX·RX, 훅 불필요)
1. `wifi <n> mode a|n|ac|ax` → 2. `wifi <n> radio-apply`(disconnect→bandcfg→reconnect, 롤백 내장) → 3. `mlanutl mlanX bandcfg`, `iw dev mlanX station dump`로 확인.
- 마스크 a=0x7, n=0x1F, ac=0x5F, ax=0x35F, 2.4GHz legacy g=0x3. AP 세대 무관, 재연결·로밍 유지. 그 안의 rate는 RA(TX=STA FW, RX=AP). AP가 HT/VHT 필수면 legacy-only 거부 가능.

### B. TX 특정 rate 고정 (매 연결 재적용)
1. `/usr/local/etc/wifi_init_conf.json` `mlanN.on_connect.commands[]`에 명령 추가(권한 644 이하, 인터페이스명 리터럴) → 2. `wifi_event@mlanN` 재시작 → 3. `ratebitmapcfg` GET + 트래픽 후 `getdatarate` 확인.

```
# HT/VHT/HE MCS3 + OFDM 6M 바닥 (AP 종류 무관, 로밍 게이트 없음)
mlanutl mlan0 ratebitmapcfg 0 0x1 0x8 0 0 0 0 0 0 0 0x8 0 0 0 0 0 0 0 0x8 0 0 0 0 0 0 0
# legacy 단일 고정 (게이트 없음, 5GHz idx 4~11)
mlanutl mlan0 txratecfg 0 4
# 해제
mlanutl mlan0 txratecfg 0xff
```

검증기(SET 전 거부): MCS ≤ 광고 tier, NSS ≤ 광고 NSS / legacy는 band 허용 집합(5GHz OFDM) / 링크 유지 가능한 값 / 연결 상태에서만 / HT·VHT·HE 단일 MCS는 2-word scope(2-word에서 `txratecfg` GET은 Auto로 표시).

재적용 이유: deauth 계열 재연결은 FW가 scope 소거, 성공 roam은 부분 보존해도 TX가 안 따름. 현 배포 로밍은 host 주도라 `connected to`로 표면화 → `on_connect` 실행. FT/FW roam offload 채택 시에만 `roamed to`에 한 줄 추가. 트레이드오프: 2-word는 손실 시 6M 바닥으로 하강 가능, RA 안전망 없는 고정은 RSSI 저하 시 단절 위험.

### C. 조합 예 — TX 6M 고정 + RX 54M 상한
`radio.mode a` + `on_connect`에 `txratecfg 0 4`. HE AP 실측 UL 6M ×50, DL 54M ×50. TCP ACK도 6M이라 DL 실효 처리량은 상한보다 훨씬 낮다.

### D. RX 특정 값이 필요하면
STA 수단 없음 → AP fixed-rate 설정을 요구사항으로. STA 보장 범위 = 세대 상한·NSS·tier(VHT/HE 0~7). HT MCS 단위 상한은 협조 AP에서만(실험 패치 `.omc/research/htmcsmask-experimental.patch`, 제품 반영 보류).

## 4. 하지 말아야 할 것
- 부팅 스크립트에서 연결 전 rate SET.
- 5GHz CCK 고정, 광고 tier·NSS 초과 MCS 고정.
- HT/VHT/HE 단일 bit `txratecfg`를 로밍 환경에 그대로 적용.
- `iw set bitrates`로 VHT/HE 마스크 지정.
- `txratecfg <fmt> <idx> <nss> <rate_setting> 0` (5번째 인자 0 → rate_setting 무시).

## 5. 결정·후속
- 결정: DL 특정 값 고정 = AP 측 요구사항으로 확정할지.
- 결정: TX 고정을 wlan-package 기능(`fixed_rate` knob: 검증기 + on_connect + wifi.sh + 문서)으로 올릴지, on_connect 한 줄 운영 설정으로 둘지.
- 보류: 드라이버 수정안(게이트 legacy 한정 + connect 완료 재적용). 위생 수정 2건(5번째 인자 트랩, rate_setting 마스크 덮어쓰기)은 별도.
- 미확인: OTA HT cap 바이트, 2.4GHz, mac80211 AP 반응, `basic_rate_set`(TLV 0x21a) 의미.
- 부수: mlan0 live `rate_adapt_cfg` 40/65 ≠ conf 70/90 (미추적).

원본 로그 `.omc/research/{fixrate,htmask,ratebitmap,legacy}_*.log`. Notion KB: "mlanutl mcstiercfg / rate 설정 종합"(3678a230), "SD9098 rate 관측 수단 지도"(3cd8a230). 보드는 원본 드라이버·ax·auto로 복원됨.
