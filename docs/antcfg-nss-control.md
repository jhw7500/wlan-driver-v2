# antcfg / NSS 제어 가이드 (88Q9098)

mlan WLAN 드라이버에서 공간 스트림 수(NSS / MIMO)를 제어하는 방법 정리.
대상 칩: **88Q9098** (STREAM_2X2, per-band antenna bitmap 계열).

## TL;DR

- **NSS를 물리적으로 통일**(HT/VHT/HE 동시) → `antcfg` (RF chain 직접 제어, 정공법)
- `mcstiercfg`는 **MCS tier만** 제한 — VHT/HE의 NSS는 보존(`update_supported_nss_map`이 NOT_SUPPORTED 비트 유지). NSS 제어 도구가 아님.
- 예외: `mcstiercfg ht 7`은 HT cap을 1x1로 광고 → 펌웨어가 device-wide 1-SS로 해석해 HE/VHT TX NSS까지 1로 떨어지는 **부작용**이 있음(아래 "펌웨어 NSS 선택 조건" 참고). 의도된 NSS 제어 수단은 아님.

## antcfg 사용법

```bash
mlanutl mlan0 antcfg              # GET (현재 Tx/Rx path)
mlanutl mlan0 antcfg <tx>         # SET — tx 값만 주면 Rx도 동일
mlanutl mlan0 antcfg <tx> <rx>    # SET — Tx/Rx 분리
```

인자 개수 해석: 3=GET, 4=tx만(Rx=tx), 5=tx/rx 분리
(`mapp/mlanutl/mlanutl.c:20777` `process_set_get_tx_rx_ant`,
 `mlinux/moal_eth_ioctl.c:13905` `woal_priv_set_get_tx_rx_ant`)

### 9098 비트맵 (per-band)

값은 밴드별 path 비트맵. LOW byte = 2G, HIGH byte = 5G:

| 비트 | 의미 |
|------|------|
| Bit 0 | 2G Path A |
| Bit 1 | 2G Path B |
| Bit 8 | 5G Path A |
| Bit 9 | 5G Path B |

path 1개 = 1 stream(NSS=1), path 2개(A+B) = 2 stream(NSS=2).

| 값 | 2G | 5G | 결과 |
|------|------|------|------|
| `0x303` | A+B | A+B | 양 대역 2x2 (NSS=2) |
| `0x101` | A | A | 양 대역 1x1 (NSS=1) |
| `0x301` | A+B | A | 2G 2x2 / 5G 1x1 |
| `0x103` | A | A+B | 2G 1x1 / 5G 2x2 |

### NSS 제어 명령

```bash
# NSS=1 강제 (양 대역, RF chain 1개) — HT/VHT/HE 전부 1 stream
mlanutl mlan0 antcfg 0x101

# NSS=2 복귀
mlanutl mlan0 antcfg 0x303

# Tx 1개 / Rx 2개
mlanutl mlan0 antcfg 0x101 0x303
```

GET 출력:
```
Mode of Tx path is 0x303
Mode of Rx path is 0x303
```

## 펌웨어 NSS 선택 조건 (`mcstiercfg ht 7` 부작용)

실측: `mcstiercfg ht 7 vht 7 he 7` → HE TX NSS=1,
`mcstiercfg vht 7 he 7`(ht 제외) → HE TX NSS=2.

조건은 두 층으로 나뉜다:

1. **트리거 (드라이버 소스 추적 가능)** — `mcstiercfg ht 7` = `htstreamcfg 0x11` →
   `usr_dev_mcs_support=0x11`. association HT Supported MCS Set IE가
   MCS 0~7만(1 spatial stream byte)으로 빌드됨
   (`mlan/mlan_11n.c:1184-1189`, `rx_mcs_supp=GET_RXMCSSUPP=1`).
   AP/펌웨어가 STA를 "1-SS 장비"로 인지.

2. **펌웨어 반응 (소스 없음, 실측·추론)** — 드라이버 소스에는 HE를 NSS=1로
   만드는 코드가 없음:
   - VHT/HE cap IE는 `usr_dev_mcs_support`를 참조하지 않음
     (`mlan_11ac.c`/`mlan_11ax.c`에 등장 0회)
   - auto-rate bitmap은 HT 설정과 무관하게 VHT NSS1+2 / HE NSS1+2를 무조건 채움
     (`mlan/mlan_misc.c:5142-5152`)

   → NSS=1 전이는 **펌웨어 rate-adaptation 내부** 동작. RF chain은 단일 물리
   자원이라, 펌웨어가 HT cap의 Tx-NSS(=1)를 라디오 전체의 1-SS 신호로 해석해
   HT/VHT/HE TX rate 선택에 동일 적용하는 것으로 추정.

**결론**: NSS를 의도적으로 제어하려면 `mcstiercfg ht 7`의 간접 부작용에 기대지 말고
`antcfg`로 RF chain을 직접 설정할 것.

## 주의점

- **HW capability 한계**: 1x1 칩(`FEATURE_CTRL_STREAM_2X2` 미설정)에서는 `0x303`을
  줘도 2 stream 불가. 9098 MAC1은 2x2, AW693 MAC2는 1x1뿐 → 그 칩은
  `mod_para.conf` 사용 권장 (`README:107`).
- **부팅 고정**: 로밍/재연결에도 안 풀리게 하려면 런타임 mlanutl 대신
  모듈 파라미터 / `mod_para.conf`의 `antcfg=`로 설정.
- **SAD 계열 칩**: 의미가 다름 (`m=0|1|2|0xFFFF`, `0xFFFF`=diversity,
  2번째 인자=evaluate time). 9098은 위 path-bitmap 포맷.
- **검증**: 설정 후 `mlanutl mlan0 txratecfg`(NSS 필드) 또는 `iw dev mlan0 link`로 확인.

## 관련 파일

- `mapp/mlanutl/mlanutl.c:20777` `process_set_get_tx_rx_ant` (antcfg 핸들러)
- `mlinux/moal_eth_ioctl.c:13905` `woal_priv_set_get_tx_rx_ant` (커널, `MLAN_OID_ANT_CFG`)
- `mlan/mlan_ioctl.h:1454` `mlan_ds_ant_cfg` (tx_antenna/rx_antenna)
- `mlan/mlan_11n.c:1184` HT Supported MCS Set 빌더 (NSS 광고 결정)
- `mapp/mlanutl/mlanutl.c:24995` `update_supported_nss_map` (mcstiercfg NSS 보존)
- `README:106-108`, `README:576-633` (antcfg 칩별 비트맵 포맷)

## 관련 문서

- Notion KB: [mlanutl mcstiercfg / rate 설정 종합](https://app.notion.com/p/3678a230a04e81cd95b0cb871c336a0e)
- Notion: [NXP moal dev_cap_mask 인터페이스별 제어](https://app.notion.com/p/3668a230a04e815e8f65d8caf9475ed2)

<!-- codex connectivity smoke: 확인용 일회성 PR — 머지하지 않는다 -->
