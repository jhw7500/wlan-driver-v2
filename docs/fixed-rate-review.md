# 특정 MCS / legacy bitrate 고정 방법 검토 (로밍·재연결 포함)

작성 2026-09-11 · 대상 wlan-driver-v2 `ported`(6aba61c) + wlan-package 배포본 · 실기 cts-wlan(iMX93, mlan0, FW GET 기준)

## 1. 결론 요약

- 고정 rate 의 **유일한 FW 프리미티브는 `CMD_TX_RATE_CFG(0x00d6)` 의 TxRateScope 비트맵**이다. 비트 1개면 고정, 여러 개면 FW rate adaptation 이 그 안에서 고른다(AN13297 §10.4.38). `mlanutl txratecfg`(단일 고정), `ratebitmapcfg`/`ratemaxcfg`(로컬 추가, 범위), cfg80211 `set_bitrate_mask`(`iw set bitrates`) 가 전부 이 명령 하나로 수렴한다.
- **TX(STA→AP) 단방향**이다. DL(AP→STA) rate 는 기존 방식(mcstiercfg/antcfgnss = 광고 capability)으로만 상한을 줄 수 있고, 특정 MCS 로 DL 을 고정하려면 AP 쪽 설정이 필요하다. **HT Rx MCS 비트마스크 실험(§11)으로 실측: AP 의존(Realtek 11n AP 는 상한만, HE AP 는 무시), VHT/HE 는 tier 라 불가 → STA 측 DL 고정은 제품 보장 불가.** legacy DL 고정은 현 드라이버로는 불가하고(band 고정 테이블, `mlan/mlan_cfp.c:2465`) 드라이버 필터를 넣어도 AP basic rate 까지만 좁혀진다(§10.1).
- **실측: 고정 rate 는 link 가 끊기는 순간 FW 가 지운다.** `wpa_cli disconnect` 직후, `ip link down` 직후 FW GET 이 이미 Auto 이고, reassociate / disconnect+reconnect / roam / ifdown-up 어느 경로든 새 association 뒤에는 Auto 다. `ratemaxcfg` 비트맵도 같다. 드라이버는 어느 경로에서도 재전송하지 않는다.
- **실측: HT/VHT/HE 고정 상태에서 supplicant 주도 reassociate/roam 을 하면 첫 association 시도가 드라이버에서 실패한다** (`Previously set fixed data rate 0x.. is not compatible with the network`, `mlan/mlan_join.c:327-347`). 그 결과 `wpa_cli reassociate` 는 다른 BSS 로 붙었고 `wpa_cli roam <BSS>` 는 roam 자체가 실패했다. 제품 로밍(wifi_roam.py 의 `wpa_cli roam`)과 직접 충돌한다.
- **실측: 연결 전(disconnected) SET 은 FW 가 받지만 그 뒤 association 이 무한 실패한다**(같은 게이트, 실패가 명령 생성 단계라 host 플래그가 리셋되지 않음). 부팅 전 적용 패턴(mcstiercfg 방식)을 그대로 쓰면 5GHz 접속 불가가 된다. `txratecfg 0xff` 로만 회복.
- **실측: 5GHz 에서 CCK 11M 고정 → FW 가 "최소 지원 rate" 1Mbps DSSS 로 송신, 100% 손실.** band 검증 없는 legacy 고정은 링크를 죽인다.
- 따라서 "로밍·재연결을 넘어 유지되는 고정 rate" 는 **(1) association 완료 후 매번 재적용 + (2) 드라이버 게이트 수정** 없이는 성립하지 않는다. 권고는 §8.

## 2. 기존 방식과의 층위 차이

| | 기존 제한 (mcstiercfg / antcfgnss) | 고정 (txratecfg 계열) |
|---|---|---|
| 작용점 | (Re)Assoc Req 의 HT/VHT/HE cap IE (광고) | FW TxRateScope (rate 선택기) |
| 방향 | 양방향 (AP 가 광고를 보고 DL 도 제한) | TX 만 |
| 적용 시점 | 연결 전 SET, association 마다 광고에 실림 → 로밍 후 자동 유지 | 연결 상태에서 SET, link 해제 시 FW 가 소거 → 로밍 후 소실 |
| 표현력 | 상한(tier)·NSS 만. 단일 MCS·legacy 불가 | 단일 MCS/legacy rate, BW/GI/STBC(rate_setting) |
| rate adaptation | 상한 안에서 FW 가 계속 조정 | 비트 1개면 initial rate 고정. 재전송 rate drop 은 FW 정의(v17 에서 user rate drop 폐지) |

## 3. 후보 메커니즘

| 메커니즘 | 경로 | 할 수 있는 것 | 제약 (코드 근거) |
|---|---|---|---|
| `mlanutl <if> txratecfg <fmt> <idx> [nss] [rate_setting] [auto_null]` | `mapp/mlanutl/mlanutl.c:3895` → `mlinux/moal_eth_ioctl.c:2235` → `MLAN_OID_RATE_CFG`/`MLAN_RATE_INDEX` → `mlan/mlan_misc.c:5350` → `mlan/mlan_cmdevt.c:5243` | LG idx 0-11(1/2/5.5/11/6/9/12/18/24/36/48/54), HT MCS0-15/32, VHT/HE MCS+NSS, `0xff`=auto | 5번째 인자 `0` 이면 rate_setting 이 0xffff 로 덮임(`:2357`,`:2478-2480`). 포맷별 마스크가 `:2371-2372` 에서 무조건 덮여 죽은 코드. 5GHz 에서 DSSS/CCK 검증 없음 |
| `mlanutl <if> ratemaxcfg [he N] [vht N] [ht N] [lg Mbps]` / `ratebitmapcfg <26 words>` | 로컬 추가. `mlinux/moal_eth_ioctl.c:2544` → `MLAN_RATE_BITMAP` → `mlan/mlan_misc.c:5132` | 상한/임의 부분집합. 비트 1개만 남기면 고정과 동일 | 검증 없이 비트맵을 FW 로 그대로 전달(`:5155-5160`). 실측상 link 해제 시 FW 가 기본 비트맵으로 복귀 |
| cfg80211 `iw dev <if> set bitrates ...` | `mlinux/moal_sta_cfg80211.c:472` → `woal_cfg80211_set_bitrate_mask` `mlinux/moal_cfg80211.c:2627` | legacy + HT MCS0-15 마스크 | 연결 상태 필수(`:2645`). **VHT/HE 마스크를 처리하지 않고 0 으로 보냄**(`:2671-2699`) → HE 링크에서 사용 불가. rate_setting 미지원 |
| WEXT priv `txratecfg` / `iwconfig rate` | `mlinux/moal_priv.c:2389`, `mlinux/moal_wext.c:1292` | 구형 경로 | 유일하게 `priv->rate_index` 를 기록하나(`moal_priv.c:2440`) 재적용 스레드가 LG 포맷으로 잘못 재전송(`mlinux/moal_main.c:11567-11597`). 사용 안 함 |
| 모듈 파라미터 | 없음 (`docs/MOAL-Module-Parameters.md:210-212`) | — | — |

## 4. 실기 실측 (2026-09-11 01:58–02:04, cts-wlan mlan0)

환경: BSS_A `00:80:4c:c7:7d:dd` 5180MHz(HT AP), BSS_B `04:ba:d6:ec:0b:08` 5220MHz(HE AP), 같은 SSID `jhw_wlan_`. 제품 구성 그대로(mcstiercfg ht15/vht7/he both 7, antcfgnss 0x1111, wifi_roam.py 가동). 각 단계는 FW GET(`txratecfg`), UL 트래픽(ping 60×1400B) 후 `getdatarate` TX, `iw station dump`, dmesg 로 판정. 원본 로그 `.omc/research/fixrate_run{1,2,3}.log`, 스크립트 `fixrate_test{,2,3}.sh`.

### 4.1 고정 → 재연결 경로별 유지 여부 (run1)

| 단계 | 조작 | FW GET | 실측 TX | 비고 |
|---|---|---|---|---|
| S0 | 기준 (auto, BSS_A) | Auto | HT MCS4 39M | |
| S1 | `txratecfg 1 3` | HT MCS3 | **HT MCS3 26M** | 즉시 반영 |
| S2 | `wpa_cli reassociate` | **Auto** | HE MCS7 (BSS_B 로 이동) | dmesg `fixed data rate 0x34 not compatible` → 첫 시도 실패 후 다른 BSS |
| S3 | disconnect → reconnect | Auto | HE MCS7 | |
| S4 | `roam BSS_B` | Auto | HE MCS7 | |
| S5 | `txratecfg 3 2 1` (BSS_B) | HE MCS2 NSS1 | **HE MCS2 108M** | 즉시 반영 |
| S6 | `roam BSS_A` | **Auto** | HE MCS7, **BSS_B 잔류** | dmesg `0xd8 not compatible` → **roam 실패** |
| S7 | `txratecfg 0 4` | LG idx4 | **LG 6M** | |
| S8 | `wpa_cli reassociate` | **Auto** | HE MCS7 | dmesg 없음(6M 은 BSS rate set 에 있음) → **게이트 없이도 FW 가 소거** |
| S9 | `ip link down/up` | Auto | HE MCS7 | (S8 에서 이미 Auto) |
| S10 | `txratecfg 0 3` (CCK 11M, 5GHz) | LG idx3 | **LG 1M, ping 100% 손실** | 교집합 없음 → FW 최소 rate = 1Mbps DSSS |
| S11 | `wpa_cli reassociate` | Auto | HE MCS7 | dmesg `0x2 not compatible` |
| S12 | `txratecfg 0xff` | Auto | HE MCS7 | 복원 |

### 4.2 소거 시점 특정 (run2)

| 단계 | 조작 | FW GET | 판정 |
|---|---|---|---|
| E1 | HT MCS3 고정 → `wpa_cli disconnect` → **DISCONNECTED 상태에서 GET** | **Auto** | link 해제 시점에 FW 가 소거 |
| E1b | reconnect | Auto, HT MCS5(auto) | dmesg 없음 (deauth 경로가 host 플래그도 리셋) |
| E2 | HT MCS3 고정 → `ip link set down` → **DOWN 상태 GET** | **Auto** | 동일 |
| E3 | HT MCS3 고정 → `wpa_cli roam <현재 bssid>` | Auto (BSS_B 로 이동) | dmesg 없음 |

### 4.3 범위 상한·연결 전 SET (run3)

| 단계 | 조작 | 결과 |
|---|---|---|
| E4 | `ratemaxcfg ht 4` → TX HT MCS4 43M 확인 → `wpa_cli reassociate` | GET `HT MCS 0~15 / VHT NSS1 0x03FF` 로 **FW 기본 복귀** (비트맵도 소거) |
| E5 | disconnect → **DISCONNECTED 상태에서 `txratecfg 1 3`** (exit 0, GET=HT MCS3) → reconnect | **30초+ SCANNING, 접속 불가.** dmesg `fixed data rate 0x2 not compatible` 반복. `txratecfg 0xff` 후에야 재접속(그 사이 ping 100% 손실 83초) |

### 4.4 실측이 확정한 것 / 못 한 것

확정: 즉시 반영(HT/HE/LG), link 해제 시 FW 소거, 모든 재연결 경로에서 소실, 드라이버 게이트로 인한 첫 시도 실패(reassociate·roam), 5GHz CCK 고정 시 1Mbps 붕괴, 연결 전 SET 시 접속 불가.
미확정: 게이트가 없다면 연결 전 SET 이 association 을 넘어 유지되는지(E5 가 게이트에서 막혀 관측 불가), 고정 rate 재전송이 실제로 rate drop 되는지(스니퍼 필요), 2.4GHz(mlan1, 비활성)에서의 legacy 게이트 통과 여부, `auto_null_fixrate_enable`(5번째 인자) FW 의미.

## 5. 라이프사이클 코드 근거

- SET 응답에서 host 상태: `pmpriv->bitmap_rates[]` 갱신, `is_data_rate_auto = wlan_is_rate_auto()`(비트맵에 0 이 아닌 word 가 2개 이상이면 auto, `mlan/mlan_cfp.c:2389`), 고정이면 `TX_RATE_QUERY` 로 `data_rate`(Mbps×2) 산출 — `mlan/mlan_cmdevt.c:5471`, `:4632-4637`.
- association 명령 생성 시 게이트: `!is_data_rate_auto` 이면 `data_rate` 가 AP∩STA legacy rate set 에 있어야 하고 없으면 `wlan_cmd_802_11_associate` 자체를 중단 — `mlan/mlan_join.c:327-347`, `:1177-1181`. HT/VHT/HE 의 `data_rate`(예 26M→0x34, 108M→0xd8)는 legacy rate 옥텟과 절대 일치하지 않으므로 **비 legacy 고정 = 항상 실패**. 명령 생성 단계 실패라 assoc-failure 응답 경로의 `wlan_reset_connect_state` 가 돌지 않아 플래그가 남는다(E5 무한 실패의 원인).
- deauth/링크 손실 이벤트에서만 host 플래그 리셋(`is_data_rate_auto=MTRUE, data_rate=0`), `bitmap_rates[]` 는 그대로, FW 로는 아무 명령도 안 보냄 — `mlan/mlan_sta_event.c:501-503`.
- supplicant 로밍/재연결 경로(`woal_cfg80211_connect`/`associate`, `woal_start_roaming`)에 `MLAN_OID_RATE_CFG` 재전송 없음 — `mlinux/moal_sta_cfg80211.c` 전체에 해당 OID 없음. roam offload/fw_roaming 도 이 트리에 없음.
- 유일한 재적용 지점은 `REASSOCIATION` 빌드의 드라이버 자동 재연결 스레드(`mlinux/moal_main.c:11567-11597`)이며 WEXT 경로에서만 채워지는 `priv->rate_index` 를 보고, 포맷/NSS 를 0(LG)으로 재전송하므로 `mlanutl txratecfg` 에는 무효.
- legacy 고정(`bitmap_rates[0]/[1]`)이면 A-MPDU/A-MSDU 비활성 — `mlan/mlan_11n.h:258`, `:332-334`.
- README 주석(`docs/README_MLAN:1589-1602`)의 "association 후에만 설정 가능 / 끊기면 auto 로 리셋" 은 실측과 일치하나 주체는 드라이버가 아니라 FW 다.
- 스펙: TxRateScope ∩ BSS 지원 rate ∩ HW 만 선택, 교집합이 없으면 최소 지원 rate, SET 은 association 전에도 가능 — AN13297 §10.4.38(p.337-338).

## 6. 로밍·재연결 결론

1. 로밍·재연결 후 고정 rate 는 예외 없이 사라진다(FW 소거). "한 번 설정하면 유지" 는 불가능하고, **association 완료 이벤트마다 host 가 다시 SET** 해야 한다.
2. 재적용만으로는 부족하다. 고정 상태에서 다음 로밍이 오면 **첫 association 시도가 드라이버에서 실패**하므로 wifi_roam.py 의 roam 판정("OK + fresh association proof")이 실패하고, `wifi connect`(`reassociate`) 는 BSS 를 바꿀 수 있다. 로밍 직전에 `txratecfg 0xff` 를 호출하거나 드라이버 게이트를 고쳐야 한다.
3. FW 주도 link 손실(beacon loss 등) 후 supplicant 자동 재연결은 deauth 이벤트가 host 플래그를 리셋하므로 게이트를 안 탄다(E1/E2). 문제는 supplicant 가 연결 상태에서 바로 새 assoc 을 거는 경로(reassociate/roam)다.
4. 연결 전 SET(부팅 적용 패턴)은 금지다(E5).

## 7. 함정 목록

- `txratecfg <fmt> <idx> <nss> <rate_setting> 0` → rate_setting 무시(0xffff). 4개 인자 또는 5번째 `1`.
- `rate_setting` 포맷별 마스크가 `moal_eth_ioctl.c:2371-2372` 에서 `~0x0C00` 하나로 덮임(BW/GI 비트 자체는 통과).
- 5GHz 에서 DSSS/CCK(idx 0-3) 고정 → 1Mbps DSSS 송신, 통신 불가. legacy 는 band 별 허용 집합(5GHz = OFDM idx 4-11) 검증 필수.
- HE AP 에서 HT MCS 고정은 동작하고(S1), HT AP 로 roam 하면 소거되므로 "포맷 불일치 AP 로 로밍" 케이스는 실질적으로 발생하지 않는다.
- `iw set bitrates` 로 VHT/HE 를 건드리면 해당 비트맵이 0 으로 전송된다(FW 반응 미검증, 사용 금지).
- `ratemaxcfg reset` 이 쓰는 비트맵(HT 0~7, VHT NSS1 0x01FF)은 association 직후 FW 기본(HT 0~15, VHT NSS1 0x03FF)과 다르다. "reset = FW 기본" 이 아니다.
- 실측 부수 관측: mlan0 live `rate_adapt_cfg` 가 40/65 iv=10 으로 conf(70/90)와 다르다(이번 작업 범위 밖, 별도 확인 필요).

## 8. 권고안

### A. 드라이버 수정 (권장, 선행)

1. **게이트 범위 축소**: `wlan_get_common_rates` 의 fixed-rate 검사를 `IS_BG_RATE`(legacy 고정)일 때만 수행하고, 그때도 실패 대신 auto 로 되돌리며 경고만 남기는 쪽이 로밍 친화적이다. HT/VHT/HE 고정에서는 검사를 건너뛴다.
2. **association 완료 후 재적용**: `mlanutl txratecfg` SET 값을 moal priv 에 온전히 보관(format/index/nss/rate_setting)하고 STA connect/roam 완료(`MLAN_EVENT_ID_DRV_CONNECTED` 처리 지점)마다 `MLAN_OID_RATE_CFG` 를 재전송. 기존 `rate_index` 재적용 스레드는 이 구조로 대체. `0xff` 면 보관값 삭제.
3. **legacy band 검증**: SET 시 현재 BSS band(또는 연결 전이면 거부)에서 허용되지 않는 DSSS/CCK 를 `-EINVAL` 로 거부.
4. 위생: 5번째 인자 트랩·마스크 덮어쓰기 수정.
5. 검증: run1~3 스크립트를 회귀로 재실행 — 기대값은 S2/S4/S6/S8/S9 에서 GET 이 고정값 유지, dmesg 게이트 메시지 0건, roam 성공, E5 접속 성공.

### B. wlan-package 통합 (A 이후)

- `wifi_init_conf.json` `mlanN.fixed_rate {enabled, format, index, nss, rate_setting}` 를 기존 knob 패턴(`wifi_fw_config_lib.sh` validator/apply, 스키마 `x-apply-timing: "connected"`, `gen_config_defaults.py`)으로 추가하되 **부팅 전 적용은 하지 않는다**(E5). 적용은 `wifi_event.sh` 의 catch-up/`connected to`/`roamed to` 세 지점에서 SET → GET 대조. 드라이버 A-2 가 들어가면 이 재적용은 이중 방어가 된다.
- `wifi <if> fixrate` 서브커맨드: 연결 상태에서만 live SET + JSON 저장, band 검증은 라이브러리 validator 로 공유.
- 운영 문구: "TX 전용, 재전송 rate drop 은 FW 정의, DL 은 mcstiercfg/antcfgnss 로만 제한" 을 guide/webui handoff 에 명시.

### C. 드라이버 수정 없이 임시 운용할 경우

- 연결 상태에서만 SET, 로밍/`wifi connect` 직전에 반드시 `txratecfg 0xff`, 재연결 후 wifi_event 재적용. wifi_roam.py 의 roam 전 훅이 필요해 결합도가 높고, `reassociate` 경로가 여럿(`wifi.sh:809/3007/3585`, `wifi_checker.sh:292`)이라 누락 위험이 크다. 시험용 이상으로는 비권장.

### D. DL 방향이 필요하면

- STA 에서는 광고 상한(mcstiercfg/antcfgnss)이 한계. 단일 MCS 고정은 AP 설정(벤더별 fixed rate)으로만 가능. legacy DL 고정은 STA Supported Rates IE 필터링(드라이버 변경, basic rate 포함 필수)이라는 별도 설계가 필요하고 본 검토 범위 밖.

## 9. 명령 요약

```
mlanutl mlan0 txratecfg                 # GET (FW 질의)
mlanutl mlan0 txratecfg 1 3             # HT MCS3
mlanutl mlan0 txratecfg 3 2 1           # HE MCS2 NSS1
mlanutl mlan0 txratecfg 0 4             # OFDM 6M (5GHz 허용 idx 4-11)
mlanutl mlan0 txratecfg 3 5 1 0x2282    # rate_setting 포함 (4개 인자, 5번째 0 금지)
mlanutl mlan0 txratecfg 0xff            # auto
mlanutl mlan0 ratemaxcfg ht 4           # 범위 상한 (association 마다 FW 기본 복귀)
mlanutl mlan0 getdatarate               # 적용 확인 (트래픽 후)
```

## 10. 추가 질의 (2026-09-11 2차)

### 10.1 RX(DL) 고정 — mcstiercfg 같은 광고 방식이 되는가

DL rate 는 AP 의 rate control 이 고르고, STA 가 손댈 수 있는 것은 AP 가 보는 후보 집합(광고 IE)뿐이다. IE 형식이 포맷마다 달라 가능 범위가 갈린다.

| 포맷 | 광고 IE 의 표현력 | 드라이버 현재 구현 | 단일 rate 고정 |
|---|---|---|---|
| HT (11n) | Rx MCS bitmask 77비트 — 임의 부분집합 표현 가능 | `wlan_fill_ht_cap_tlv` `mlan/mlan_11n.c:1521-1527` 가 스트림 수만큼 `0xff` 로 memset(연속 0~8n-1). 비트 단위 마스크 없음 | **드라이버 수정으로 가능성 있음**: memset 뒤에 사용자 마스크 AND(예 MCS3 만 → `0x08`). AP 가 sparse mask 를 존중하는지는 AP 구현 의존(802.11n 은 MCS0-7 필수) → OTA 검증 필수 |
| VHT / HE | NSS 별 2비트 "최대 MCS" tier(VHT 0-7/0-8/0-9, HE 0-7/0-9/0-11) | mcstiercfg 가 그대로 노출 | **불가**. 최저 tier 가 0-7 이라 상한 7 이 한계. 제품 HE 링크에서 DL 단일 MCS 고정은 AP 설정으로만 |
| Legacy | Supported Rates IE — 부분집합 가능하나 **AP basic rate 전부 포함 필수**(빠지면 assoc 거절 status 18) | `wlan_get_supported_rates` `mlan/mlan_cfp.c:2465` band 고정 테이블 ∩ AP rates(`mlan/mlan_join.c:371-403`). 사용자 필터 없음 | **부분 가능**: legacy-only association(패키지 `radio.mode` → `bandcfg`, `wifi.sh:788`) + 드라이버에 "basic ∪ 선택 rate" 필터 추가. DL 은 basic rates 와 선택 rate 사이에서 AP 가 고름 — basic set 이 그 rate 하나가 아니면 진짜 고정은 아님 |

- HT cap TLV 는 host 가 ASSOCIATE 명령에 실어 보낸다(AN13297 §6.8.1 요청 테이블 "HT capabilities", `mlan/mlan_11n.c:2558`). #41 OTA 에서 스트림 clamp 가 그대로 전파된 것으로 보아 FW 가 덮어쓰지는 않는 것으로 보이나 sparse 비트마스크는 미검증.
- 어떤 방식이든 AP 의 재전송/관리 프레임은 legacy 로 내려오므로 "RX 단일 rate" 는 데이터 프레임의 1차 전송에 한정된다.
- 11ax OMI(`DOT11AX_CMDID_TXOMI 0x105`, AN13297)는 Rx NSS·BW 를 AP 에 동적으로 알리는 수단이지 MCS 는 아니다.

### 10.2 로밍·재연결 유지 — 스크립트 훅 외의 방법

- **`txrate_cfg.conf` 는 별도 설정 파일이 아니다.** `mlanutl <if> hostcmd txrate_cfg.conf txrate_cfg_set_*` 로 같은 `0x00d6` 명령(TxRateScope 0x0153 + TxRateDrop 0x0151)을 raw 로 보내는 예제 묶음이다(`mapp/mlanconfig/config/txrate_cfg.conf`, README_MLAN:3011-3019). 패키지의 `/usr/lib/firmware/cts/config/txrate_cfg.conf` 는 stock 사본이며 어떤 스크립트도 적용하지 않는다. FW 상태가 동일하므로 link 해제 시 소거도 동일하다. 같은 파일의 `basic_rate_set`(TLV 0x21a BasicRateSupport)은 드라이버 헤더에 정의가 없고 의미 미확인.
- FW 소거는 드라이버와 무관하게 일어난다: `HostCmd_CMD_TX_RATE_CFG` 발행 지점은 ioctl 핸들러(`mlan/mlan_misc.c:5114-5487`)와 init GET(`mlan/mlan_sta_cmd.c:4330`)뿐이고 disconnect 경로에는 없다. AN13297 에 유지 플래그는 없다(`auto_null_fixrate_enable` 의 ACT_SPC_AUTO_* 는 v17 문서에 미기재).
- `init_hostcmd_cfg`/`init_cfg` 모듈 파라미터(현재 미사용)는 드라이버 init 1회 적용이라 첫 association 을 게이트가 막고(E5), 이후 link 해제에서 소거된다. 해결책이 아니다.
- 따라서 선택지는 두 가지뿐: (a) 사용자 공간 재적용(wifi_event.sh), (b) **드라이버 내부 재적용** — connect/roam 완료 이벤트에서 보관값 재전송. 벤더도 `REASSOCIATION` 스레드에서 같은 의도를 구현했으나(`mlinux/moal_main.c:11567-11597`) WEXT `rate_index` 전용·LG 포맷 오전송이라 txratecfg 에 무효. (b) 를 게이트 축소와 함께 넣는 것이 "훅 없는" 유일한 경로다.

## 11. RX(DL) 고정 실기 실험 — HT Rx MCS 비트마스크 (2026-09-11, 실험 드라이버)

### 11.1 실험 드라이버
- 패치: `.omc/research/htmcsmask-experimental.patch` (245줄, 미커밋·작업 트리에서는 되돌림). 내용: `mlan_private.usr_ht_rx_mcs_mask`(기본 0xFFFF) 추가, `wlan_fill_ht_cap_tlv`/`wlan_fill_ht_cap_ie` 의 memset 뒤에 `supported_mcs_set[0..1] &= mask`, `MLAN_OID_11N_CFG_HT_MCS_MASK`(0x000C0010) + moal `htmcsmask` private 명령 + `mlanutl <if> htmcsmask [0xMASK]`. uAP 경로는 별도 빌더라 무영향.
- 빌드: 보드 커널(6.6.3-lts-next-gccf0a99701a7-dirty, 6/24)과 현재 Yocto 트리(1c0b4db17dce, 9/10 재빌드) 사이가 dts 4커밋·config 동일이라, `include/generated/utsrelease.h` 만 보드 문자열로 바꾼 overlay KERNELDIR(`mk_overlay.sh`)로 빌드해 vermagic 을 맞췄다. `make_for_imx93.sh` 기본 KERNELDIR(`.../6.6.3+git/linux-imx-6.6.3+git`)은 9/10 이후 존재하지 않는다.
- 보드 배포: `/opt/wlan/driver/*_imx93.ko`, `/opt/wlan/bin/mlanutl_imx93` 교체+리부팅(백업 `.bak-htmask-20260907`, 보드 시계 기준). 실험 후 원본(manifest 해시)으로 복원·리부팅. 산출물 사본 `.omc/research/*.htmcsmask-exp`, 로그 `htmask_run{1..5}.log`.

### 11.2 HT AP (Realtek 00:80:4c:c7:7d:dd, 5180MHz, HT 20MHz) — DL 은 보드→AP(192.168.0.1) ping 응답을 `iw station dump` rx bitrate 로 100회 샘플

| htmcsmask | 광고 HT Rx set | 실측 DL | 실측 UL |
|---|---|---|---|
| 0xffff | MCS0-15(→1x1 clamp 로 0-7) | HT MCS7 72.2M (100/100) | MCS4~7 (RA) |
| 0x0001 | MCS0 | **legacy 6M** | legacy 18M |
| 0x0003 | MCS0-1 | HT MCS1 13M | legacy 18M |
| 0x0008 | MCS3 | **legacy 6M** | **MCS3 고정** |
| 0x000f | MCS0-3 | HT MCS3 26M | MCS3 |
| 0x0010 | MCS4 | **legacy 6M** | **MCS4 고정** |
| 0x0020 | MCS5 | **legacy 6M** | **MCS5 고정** |
| 0x0038 | MCS3-5 | HT MCS5 52M | MCS5 |
| 0x0040 | MCS6 | **legacy 6M** | **MCS6 고정** |
| 0x0080 | MCS7 | HT MCS7 | MCS7 |
| 0x0088 | MCS3,7 | HT MCS7 | MCS7 |
| 0x00f8 | MCS3-7 | HT MCS7 | MCS5 (RA) |

- 이 AP 는 광고 set 을 **"집합 내 최고 MCS 를 상한으로"** 존중한다(0x0038→5, 0x000f→3, 0x0003→1). 그러나 **단일 MCS 집합은 MCS7 외에는 legacy 6M 로 폴백**한다(0/3/4/5/6 단독). 따라서 DL "단일 MCS 고정" 은 이 AP 에서도 성립하지 않고, "MCS n 상한 + 하위 폴백" 까지만 된다.
- **부수 발견: 같은 마스크가 UL(STA TX)도 제한한다.** FW 가 자기 광고 set 과 AP set 의 교집합을 TX rate scope 로 쓰는 것으로 보이며, 단일 MCS 마스크에서 UL 이 그 MCS 로 고정됐다(0x0008→MCS3, 0x0010→MCS4, 0x0040→MCS6). 광고 기반이라 **reassociate 를 넘어 유지된다** — txratecfg 와 달리 로밍 게이트 문제도 없다. 단 HT 링크 한정이고, DL 은 AP 폴백(6M)을 감수해야 한다.
- 0xffff 복원 후 DL/UL 이 MCS7 로 돌아와 가역성 확인.

### 11.3 HE AP (04:ba:d6:ec:0b:08, 5220MHz)

| 조건 | 광고 | 실측 DL | 실측 UL |
|---|---|---|---|
| HE 링크(80MHz), mask 0x0038 | HE map 0-7 (HT set 은 무관) | HE-MCS7 360.3M | HE-MCS7 |
| **HT-only** (disconnect→`bandcfg 0x1F`→reconnect, 40MHz), mask 0x0038 | HT MCS3-5 | **HT MCS7 135M — 마스크 무시** | MCS5 |
| HT-only, mask 0x0088 | HT MCS3,7 | HT MCS7 | MCS7 |
| 복원 (`bandcfg 0x35f`, 0xffff) | — | HE-MCS7 | HE-MCS7 |

- HE 링크에서는 HT 마스크가 당연히 무의미하고(VHT/HE map 은 tier), HT-only 로 내려도 **이 AP 는 STA 의 HT Rx MCS set 을 DL rate 선택에 반영하지 않는다**(스트림 수만 반영). UL 은 여전히 마스크를 따랐다(FW 측).

### 11.4 결론 (질문 1: RX 고정)

1. **STA 광고로 DL 을 특정 MCS 에 고정하는 것은 제품 보장이 불가능하다.** 드라이버는 sparse HT Rx MCS set 을 낼 수 있고 FW 도 그대로 내보내지만(AP 반응 변화·UL 변화로 확인, OTA 캡처는 미실시), 그것을 DL rate 선택에 쓰는지는 AP 구현 의존이다: Realtek 11n AP 는 "최고 MCS 상한" 으로만, HE AP(04:ba:d6)는 무시. VHT/HE 링크는 IE 형식상 0-7 tier 아래로 못 내려간다.
2. STA 가 보장할 수 있는 DL 제어는 **NSS(antcfgnss)** 와 **tier 상한(mcstiercfg, VHT/HE 최저 0-7)** 뿐이며, 협조적인 11n AP 에서만 HT 상한(HT 마스크)이 추가로 먹는다. 특정 MCS 고정·legacy rate 고정은 **AP 측 설정**이 필요하다 — 이것이 제품 제약이다.
3. HT 마스크는 DL 목적으로는 불충분하지만, **UL HT MCS 를 로밍 무관하게 고정/상한하는 수단**으로는 유효하다(txratecfg 의 소거·게이트 문제 없음). HT 링크 전용이라 제품 HE 링크에는 해당 없음.
4. 미확인: 마스크 적용 시 OTA (Re)Assoc Req 의 실제 HT cap 바이트(스니퍼 미실시), 2.4GHz AP, 다른 벤더 AP(예: mac80211/hostapd 기반은 minstrel_ht 가 rx_mask 비트를 그대로 쓰므로 존중할 가능성이 큼 — 미검증).

## 12. 포함 구조와 legacy-only association 실측 (2026-09-11, 원본 드라이버, Realtek HT AP)

- 상위 association(HE/HT) 안에서도 하위 format rate 는 TX 후보에 항상 포함된다: HE AP 에 HE 로 붙은 채 `txratecfg 0 4` → TX 6M(S7), HT AP 에서 `0 4/8/9` → 6/24/36M 모두 손실 0%.
- **legacy-only association**(disconnect → `bandcfg 0x7`(B|G|A) → reconnect): DL 이 legacy 54M(60/60, AP RA 선택), UL auto 48M. 같은 상태에서 `txratecfg 0 4` → UL 6M 고정, DL 은 54M 그대로 → TX/RX 는 독립이며 **RX 는 legacy-only 까지만 만들 수 있고 특정 rate 는 AP 가 고른다.** 복원(`bandcfg 0x35f`) 후 HT MCS7 복귀.
- **고정 rate 는 RA 안전망을 없앤다**: `txratecfg 0 11`(54M) 고정 시 1400B ping 100% 손실·64B 20~80% 손실이 2회 재현(tx failed 29→52), 36/24/6M 은 손실 0%. auto RA 는 같은 링크에서 48M 을 골랐다. legacy 고정값은 링크에서 유지 가능한지 검증 후 써야 한다. 로그 `.omc/research/legacy_run1.log`.

## 13. 드라이버 수정 없는 경로 — `ratebitmapcfg` 2-word scope + wifi_event 훅 (2026-09-11 실측, 원본 드라이버)

원리: 드라이버 게이트는 `bitmap_rates[]` 에 0 이 아닌 word 가 **1개**일 때만(`wlan_is_rate_auto`) 발동한다. 목표 MCS word 에 legacy 바닥 word(OFDM 6M) 하나를 더 넣으면 드라이버는 auto 로 보고 FW 는 scope 안에서 상위 rate(목표 MCS)를 고른다. `ratebitmapcfg` 는 배포 드라이버에 이미 있는 로컬 명령이다.

| 단계 | 조작 | TX 실측 | 게이트 dmesg | 비고 |
|---|---|---|---|---|
| R1 | HE AP, scope {OFDM6M, HE NSS1 MCS2} | HE-MCS2 108M, 손실 0% | — | `txratecfg` GET 은 Auto 로 표시됨(2 word) |
| R2 | 위 상태로 `wpa_cli roam` → HT AP | roam 성공 | 없음 | scope 가 {6M} 만 남음(HE word 는 새 BSS ∩ 로 탈락) → **재적용 전 TX 6M** |
| R3/R5 | HT AP, scope {6M, HT MCS3} 적용/재적용 | HT MCS3 28.9M, 0% | — | 훅 재적용 시뮬레이션 |
| R4 | 위 상태로 `reassociate` | 성공 | 없음 | scope FW 기본으로 소거 → 재적용 필요 |
| M1 | HE AP, scope {6M, HT3, VHT3, HE3} | HE-MCS3 144M, 0% | — | FW 가 링크 포맷에 맞는 word 를 선택 |
| M2 | roam → HT AP, 재적용 없이 | **LG 6M** | 없음 | GET 엔 HT word 잔존했으나 TX 는 6M — roam 후 보존을 신뢰하지 말 것 |
| M3 | roam → HE AP, 재적용 없이 | HE-MCS7(auto) | 없음 | 이번엔 scope 전부 소거 |
| M4/M5 | reassociate / disconnect+reconnect | auto | 없음 | 소거 |

결론: **훅만으로 가능하다.** 조건은 (1) `txratecfg` 단일 bit 대신 `ratebitmapcfg` 2-word 이상(목표 + legacy 바닥) — 게이트가 구조적으로 안 걸려 roam/reassoc 6회 전부 성공, (2) 모든 association 완료 시 재적용(wifi_event.sh catch-up·connected·roamed 3지점, SET 후 GET 대조) — deauth 계열은 소거, 성공 roam 은 부분 보존이어도 TX 가 따르지 않음(M2), (3) 연결 전 적용 금지, (4) 검증기: 5GHz 는 OFDM 바닥만, 목표 rate 지속 가능성(54M 손실 사례), 포맷 word 는 HT/VHT/HE 를 함께 넣어 AP 종류 무관하게 적용. 트레이드오프: 손실 시 FW 가 바닥(6M)으로 내려갈 수 있어 순수 단일 rate 는 아니다(legacy 단일 목표는 `txratecfg 0 idx` 로 게이트 없이 가능). 로그 `.omc/research/ratebitmap_{hook,multi}_run1.log`.

## 14. RX 를 legacy(최대 54M) 안에서만 동작시키기 — legacy-only association (2026-09-11 실측)

- `bandcfg 0x7`(B|G|A, HT/VHT/HE 미광고)로 붙이면 AP 는 DL 을 legacy 로만 보낸다. HT AP·HE AP 모두 DL 54M(50/50), UL 36~48M(auto). **roam(HT AP→HE AP→HT AP)·reassociate 를 넘어 유지**된다 — bandcfg 는 어댑터 설정이라 매 association 에 반영되고, FW 가 소거하는 TX rate scope 와는 층위가 다르다. 복원(`0x35f`) 후 HT MCS7 복귀.
- 패키지에는 이미 `radio.mode = a`(→ `wifi_init_mode_to_bandcfg_mask` 0x7, `wifi <n> mode a` + `radio-apply`, 부팅 적용)가 있어 드라이버·훅 추가 없이 쓸 수 있다. 적용은 disconnect 를 수반한다(모드 변경 경로).
- 한계: 양방향 모두 legacy 가 된다(TX 도 ≤54M). DL rate 는 AP RA 가 6~54M 중 고르며 STA 가 더 좁힐 수단이 없다(Supported Rates 필터 없음, basic rate 제거 불가). TX 는 `txratecfg 0 idx` 로 추가 고정 가능하나 54M 고정은 이 링크에서 손실 100%였다(§12). 로그 `.omc/research/legacy_roam_run1.log`.

### 14.1 VHT AP 검증 + "제한 vs 고정" (2026-09-11, `jhw_wlan` 58:86:94:d2:73:e8, 5200MHz VHT 20MHz)

| 상태 | 부하 | DL 분포 | UL 분포 | retries/failed |
|---|---|---|---|---|
| auto (VHT) | light / heavy | VHT-MCS7 72.2M 48/50 · 71/75 | VHT-MCS6~7 | 491/0 · 8635/0 |
| legacy-only (`bandcfg 0x7`) | light | **54M 50/50** | 36M 33 · 48M 17 | 132/0 |
| legacy-only | heavy (ping -i 2ms 1472B) | **54M 61 · 24M 9 · 36M 3 · 48M 2** | 48M 39 · 36M 36 | 3192/**38** |
| legacy-only, reassociate 후 | light / heavy | 54M 48 · 48M 2 / 54M 75 | 36~48M | 122/0 · 3419/0 |
| 복원 (`0x35f`) | — | VHT-MCS7 | VHT-MCS6~7 | — |

- VHT(11ac) AP 에서도 legacy-only 가 그대로 적용되고 reassociate 를 넘어 유지된다.
- **54M 은 상한이지 고정이 아니다.** 부하가 커져 재전송이 늘자 AP 가 DL 을 24/36/48M 으로 내렸고(같은 구간 tx failed 38), UL 도 FW RA 가 36↔48M 을 오갔다. 즉 양방향 모두 6~54M 안에서 rate adaptation 이 동작한다.
- `wifi 0 connect <ssid>` 는 supplicant conf 의 ssid 를 영속 변경한다(`conf updated: ssid=...`). 시험 후 `wifi 0 connect jhw_wlan_` 로 원복. 로그 `.omc/research/legacy_vht_run1.log`.

## 15. VHT/HE TX 고정의 한계 — 광고 tier·NSS 안에서만 (2026-09-11 실측)

VHT AP `jhw_wlan`(58:86:94, 5200 VHT 20MHz)과 HE AP(04:ba:d6, 5220 80MHz), 제품 광고 = vht 7 / he both 7 / antcfgnss 0x1111(NSS1).

| 조작 | 결과 |
|---|---|
| `ratebitmapcfg {OFDM6M, VHT NSS1 MCS3}` | TX VHT-MCS3 28.9M, 손실 0% (2-word, 게이트 없음) |
| `txratecfg 2 3 1` (VHT MCS3 NSS1) | TX VHT-MCS3 26M, 0% |
| `txratecfg 2 8 1` (VHT MCS8 > tier 7) | **LG 1Mbps, 100% 손실** |
| `txratecfg 2 9 1` | mlanutl EFAULT (드라이버 거부), 직전 상태 유지 |
| `txratecfg 2 3 2` (NSS2 > 광고 NSS1) | **LG 1Mbps, 100% 손실** |
| `txratecfg 3 5 1` (HE MCS5 NSS1) | TX HE-MCS5 288M, 0% |
| `txratecfg 3 9 1` / `3 11 1` (HE MCS9/11 > tier 7) | **LG 1Mbps, 100% 손실** |
| `txratecfg 3 5 2` (HE NSS2 > 광고 NSS1) | **LG 1Mbps, 100% 손실** |

- VHT/HE TX 고정은 **광고(협상)된 tier·NSS 안**에서만 성립한다. 벗어나면 TxRateScope ∩ BSS ∩ HW 교집합이 비어 FW 가 "최소 지원 rate"(1Mbps DSSS)로 떨어지고(AN13297 §10.4.38) 5GHz 라 100% 손실이 된다. §4 의 CCK 케이스와 같은 메커니즘.
- 제품 구성(mcstiercfg he/vht 7, antcfgnss 0x1111)에서는 **VHT/HE MCS 0~7, NSS1 만 고정 가능**. MCS8~11 이나 NSS2 를 고정하려면 mcstiercfg tier·antcfgnss 를 먼저 올려야 한다(광고 변경 → 재연결 필요). `ratebitmapcfg` 는 HT 뿐 아니라 VHT/HE 에서도 TX 를 고정했다(HE MCS2/3, VHT MCS3).
- 검증기 요구사항: 고정값 ≤ 현재 광고 tier, NSS ≤ 광고 NSS, legacy 는 band 허용 집합. 위반 시 링크가 죽으므로 SET 전에 거부해야 한다. 로그 `.omc/research/vht_he_txfix_run1.log`.

### 15.1 Notion 기록과의 대조 (KB "mlanutl mcstiercfg / rate 설정 종합", 3678a230…)

- Notion(2026-05~08): "VHT MCS5 는 표준 tier(7/8/9) + **FW MCS7 floor** 로 ratemaxcfg 로는 도달 불가, txratecfg 로만 우회" / "HE 는 floor 없음(ratemaxcfg he 5 → TX HE MCS5)" / "RX 는 ratebitmapcfg 로 불가(TX 전용 명령)" / "ratemaxcfg 는 로밍 시 휘발 → `mlanX.on_connect.commands[]`(wifi_event.sh `run_on_connect`) 로 재적용이 정석".
- 오늘 실측: VHT AP 에서 `ratebitmapcfg {6M, VHT NSS1 MCS3}` → TX VHT-MCS3, `txratecfg 2 3 1` → VHT-MCS3 — **"VHT MCS7 floor" 는 이 FW(p149.115)·AP 조합에서 재현되지 않았다.** 남는 VHT/HE 한계는 광고 tier·NSS 천장(§15 표)이다. RX 불가·로밍 휘발·on_connect 재적용 정석은 Notion 과 일치.
- 따라서 "훅" 은 새 코드가 아니라 기존 `wifi_init_conf.json` `mlanN.on_connect.commands` 한 줄로 충분하다(권한 644 이하, 명령에 리터럴 인터페이스명). `roamed to` 케이스는 `run_on_connect` 미호출이나 현 배포 로밍은 host 주도라 `connected to` 로 표면화되어 무해(FT/FW roam offload 채택 시에만 1줄 추가 필요).

### 14.2 조합: legacy-only + TX 6M 고정 (HE AP, 2026-09-11)

| 상태 | DL (50샘플, light/heavy) | UL |
|---|---|---|
| legacy-only(`bandcfg 0x7`), auto | 54M ×50 / 54M ×50 | 36~54M RA |
| + `ratebitmapcfg 0 0x1 0…`(OFDM 6M만) | 54M ×50 / 54M ×50 | **6M ×50 / 6M ×50** |
| reassociate 후 | — | scope 소거(Auto), 게이트 없음 → on_connect 재적용 필요 |
| 재적용 후 | 54M ×50 | 6M ×50 |

- 의도대로 **TX 6M 고정 + RX ≤54M(AP RA)** 이 성립한다. legacy-only 는 무훅 유지, 6M 고정만 매 연결 재적용. 6M 단일 word 는 legacy 라 게이트를 안 탄다(AP rate set 에 6M 존재 전제). 로그 `.omc/research/legacy_tx6m_he_run1.log`.

### 11.1a 정정 (2026-09-12) — vermagic 문자열 불일치는 적재 차단 사유가 아니었다

보드 커널(`6.6.3-lts-next-gccf0a99701a7-dirty`)에 새 트리 빌드(`vermagic 6.6.3-lts-next-g1c0b4db17dce`) 모듈을 `insmod`(강제 옵션 없음)로 정상 적재·연결함을 실측했다(wlan-proc 0.6.6, srcversion 일치, 링크 정상). 이유: 보드 커널이 `CONFIG_MODVERSIONS=y` 라 `kernel/module/version.c:same_magic()`이 `__versions` 섹션이 있는 모듈에 대해 vermagic 의 **커널 릴리스 문자열 부분을 비교에서 제외**하고(첫 공백 이후의 SMP/preempt/mod_unload/modversions/aarch64 만 비교) 심볼 CRC 로 호환성을 판정한다. 따라서 §11.1 의 utsrelease overlay 는 불필요했고, "적재 불가" 예고는 오진이었다. 과거 "Invalid module format"(2018년 mlan.ko/moal.ko)은 CRC·ABI 자체가 다른 경우였다. 다른 커널 트리로 빌드한 모듈의 적재 가능 여부는 vermagic 문자열이 아니라 CRC(헤더·config 동일성)로 판단한다.
