# WLAN 드라이버 conf 파일 카탈로그 & 심층분석 진입점

> 목적: `mlanutl` 명령이나 모듈 파라미터(`wifi_mod_para.conf`)로 **해결되지 않는 기능**을 찾을 때,
> 어떤 `.conf`가 그 기능을 담고 있는지 → 어떤 host command(CmdCode)로 펌웨어에 전달되는지 →
> 드라이버/펌웨어 코드의 어디를 추적해야 하는지를 한 곳에 모은 참조 문서.
>
> 작성 근거: 리포지토리 내 `.conf` 59개 고유 파일 전수 조사(2026-06-17 기준).

---

## 0. 개요

| 디렉토리 | 개수 | 소비 도구 | 비고 |
|---|---|---|---|
| `mapp/mlanconfig/config/` | 49 | `mlanconfig` / `mlanutl ... hostcmd` | 원본(소스) |
| `bin_wlan/config/` | 49 | (동일) | **배포용 동일 복사본** — 내용 동일 |
| `mapp/uaputl/config/` | 8 | `uaputl` | 소프트AP(uAP) 전용 |
| `mapp/wifidirectutl/config/` | 2 | `wifidirectutl` | WiFi Direct / Display |

→ **고유 파일 59개** (`bin_wlan`은 `mlanconfig`의 사본이므로 중복 제외).

### 호출 방법 3패턴
```sh
# (1) hostcmd 방식 — CmdCode를 가진 conf. 블록명으로 개별 호출
mlanconfig mlanX hostcmd <file>.conf <block_name>
mlanutl   mlanX hostcmd <file>.conf <block_name>   # 동일 host command를 mlanutl로도

# (2) mlanconfig/mlanutl 전용 서브커맨드 — "구조형" conf (CmdCode 파일에 없음)
mlanconfig mlanX <feature> <file>.conf             # 예: tdls, twt, ftm, mef, cwmode 등

# (3) uaputl / wifidirectutl 전용
uaputl       [sys_config|...] <file>.conf
wifidirectutl mlanX <file>.conf <block_name>
```

---

## 1. CmdCode 인덱스 (심층분석 1차 진입점)

`.conf`에 `CmdCode=0x....`가 박혀 있는 파일은 **raw host command** 방식이다.
이 CmdCode가 코드 추적의 핵심 키 → `mlan/mlan_fw.h`의 `HostCmd_CMD_*` 정의에서 시작한다.

| CmdCode | 의미(추정/확인) | conf 파일 |
|---|---|---|
| `0x008b` | **CMD_DBGS_CFG** (디버그 서브시스템; SUBID로 기능 분기) | `debug.conf`, `debug_ci_mode.conf`, `small_debug.conf`, `twt_Ap.conf` |
| `0x008c` | (small_debug 보조) | `small_debug.conf` |
| `0x008f` | PAD/OR 레지스터 CFG | `pad_cfg.conf` |
| `0x0060` | TPC Request (802.11h 출력제어) | `requesttpc.conf` |
| `0x0075` | Subscribe Events (RSSI/SNR 임계 이벤트) | `subevent.conf` |
| `0x0078` | Crypto 엔진 테스트 | `crypto_test.conf` |
| `0x0082` | Auto TX (주기 송신) | `auto_tx.conf`, `null_tx.conf` |
| `0x0086` | 메모리/레지스터 read·write | `mem.conf` |
| `0x00d6` | TX Rate Config | `txrate_cfg.conf`, `txrate_cfg_custom.conf` |
| `0x00e0` | Robust BT Coexistence | `robust_btc.conf` |
| `0x00e9` | 11n 20/40 Coex | `11n_2040coex.conf` |
| `0x00fb` | TX Power Limit Table | `txpwrlimit_cfg.conf`, `txpwrlimit_cfg_8997.conf` |
| `0x006b` / `0x006c` | Background Scan (set/query) | `bg_scan.conf`, `bg_scan_wifidirect.conf` |
| `0x010a` | Packet Coalescing | `pkt_coalescing.conf` |
| `0x012d` | SMC 단독연결 설정 | `smc.conf` |
| `0x0130` | ED MAC Control (Energy Detect) | `ed_mac_ctrl_V2_8897/8997/909x.conf` |
| `0x026d` | RU TX Power Limit (11ax) | `rutxpower_limit.conf` |
| `0x026f` | Band Steering | `band_steer_cfg.conf` |

> **0x008b(CMD_DBGS_CFG) 특이점**: 단일 CmdCode 아래 **SUBID(2바이트)로 33개 서브기능**을 분기한다.
> thermal_mgmt(SUBID 0x113)가 대표 예. 상세는 §3-K 및 별도 분석 참조.

### "구조형" conf (CmdCode가 파일에 없음)
도구(mlanconfig/mlanutl/uaputl)가 conf를 파싱해 **내부적으로 적절한 host command를 구성**한다.
이 경우 진입점은 CmdCode가 아니라 **도구의 서브커맨드 핸들러**다.

대상: `11axcfg`, `arpfilter`, `autodfs`, `cal_data`, `csi`, `cwmode`, `ftm`, `hal_phy_cfg`,
`host_tdls`, `init_cfg`, `mef`, `mef_mdns`, `mef_ws_discovery`, `mgmt_frame`, `mgmtfilter`,
`or_data`, `ssu`, `tdls`, `trigger_frame_cfg`, `tspecs`, `twt`, `tx_ctrl`, `wifi_mod_para`,
모든 `uaputl/*`, 모든 `wifidirectutl/*`.

---

## 2. 카테고리 분류 (전체 59개)

### A. 무선 표준 / PHY 모드 (11ax·11n, 대역폭)
| 파일 | 기능 | CmdCode |
|---|---|---|
| `11axcfg.conf` | 11ax(HE) 기능 파라미터 | 구조형 |
| `11n_2040coex.conf` | 11n 20/40MHz 공존 | 0x00e9 |
| `trigger_frame_cfg.conf` | 11ax UL-MU Trigger Frame | 구조형 |
| `twt.conf` / `twt_Ap.conf` | Target Wake Time (STA / AP) | 구조형 / 0x008b |
| `tx_ctrl.conf` | TX 제어(자동 대역폭 등) | 구조형 |
| `cwmode.conf` | Continuous-Wave / RF 시험 모드 | 구조형 |

### B. 전송률(Rate) / 출력(Power) 제어
| 파일 | 기능 | CmdCode |
|---|---|---|
| `txrate_cfg.conf` / `txrate_cfg_custom.conf` | TX rate / 커스텀 rate 테이블 | 0x00d6 |
| `txpwrlimit_cfg.conf` / `txpwrlimit_cfg_8997.conf` | 지역별 TX power limit 테이블 | 0x00fb |
| `rutxpower_limit.conf` | 11ax RU 출력 한계 | 0x026d |
| `requesttpc.conf` | TPC 요청(802.11h) | 0x0060 |
| `auto_tx.conf` / `null_tx.conf` | 주기 자동 TX / QoS Null keepalive | 0x0082 |
| `mgmt_frame.conf` | Raw 관리프레임 송신 | 구조형 |

### C. 스캔 / 로밍 / 밴드 스티어링
| 파일 | 기능 | CmdCode |
|---|---|---|
| `bg_scan.conf` / `bg_scan_wifidirect.conf` | 백그라운드 스캔 | 0x006b/0x006c |
| `band_steer_cfg.conf` | 밴드 스티어링(2.4↔5G) | 0x026f |
| `subevent.conf` | Subscribe Events(RSSI/SNR 임계 → 로밍 트리거) | 0x0075 |

### D. 절전 / 호스트 오프로드 / Wake-on-WLAN
| 파일 | 기능 | CmdCode |
|---|---|---|
| `mef.conf` | Memory Efficient Filter(WoWLAN 패턴) | 구조형 |
| `mef_mdns.conf` / `mef_ws_discovery.conf` | MEF mDNS / WS-Discovery 오프로드 | 구조형 |
| `arpfilter.conf` | ARP 오프로드/필터 | 구조형 |
| `mgmtfilter.conf` | 호스트 깨우는 관리프레임 필터 | 구조형 |
| `pkt_coalescing.conf` | 패킷 coalescing | 0x010a |
| `pad_cfg.conf` | Sleep/Power-down 패드 레지스터 | 0x008f |

### E. QoS / 트래픽
| 파일 | 기능 | CmdCode |
|---|---|---|
| `tspecs.conf` | TSPEC(WMM admission control) | 구조형 |

### F. 측정 / 위치 / 스펙트럼 (진단성)
| 파일 | 기능 | CmdCode |
|---|---|---|
| `ftm.conf` | Fine Timing Measurement(802.11mc 측위) | 구조형 |
| `csi.conf` | Channel State Information 캡처 필터 | 구조형 |
| `ssu.conf` | Spectral(FFT) 샘플링 | 구조형 |

### G. 규제 / DFS / 지역 (Regulatory)
| 파일 | 기능 | 도구 |
|---|---|---|
| `autodfs.conf` | Auto DFS | mlanconfig |
| `80211d_country_ie.conf` / `80211d_domain.conf` | 802.11d 국가 IE / 규제 도메인 | uaputl |

### H. 공존(Coexistence) / Energy Detect
| 파일 | 기능 | CmdCode |
|---|---|---|
| `robust_btc.conf` | Robust BT Coexistence | 0x00e0 |
| `ed_mac_ctrl_V2_8897/8997/909x.conf` | Energy Detect MAC 제어(칩별) | 0x0130 |
| `uapcoex.conf` | uAP/BT 공존 | 구조형(uaputl) |

### I. 직접연결: TDLS / P2P / Display
| 파일 | 기능 | 도구 |
|---|---|---|
| `tdls.conf` / `host_tdls.conf` | TDLS / 호스트 기반 TDLS | mlanconfig |
| `tdls_ext_cap.conf` | TDLS 확장 capability | uaputl |
| `wifidirect.conf` | WiFi Direct(P2P) | wifidirectutl |
| `wifidisplay.conf` | WiFi Display / Miracast | wifidirectutl |
| `uaputl_wifidirect.conf` | uAP+WFD | uaputl |

### J. 캘리브레이션 / RF / 하드웨어
| 파일 | 기능 | CmdCode |
|---|---|---|
| `cal_data.conf` | Calibration data 다운로드 | 구조형 |
| `sample_cal_data_bg_8688.conf` | 샘플 cal data | 구조형(uaputl) |
| `hal_phy_cfg.conf` | HAL PHY 파라미터(11b PSD mask 등) | 구조형 |
| `or_data.conf` | OTP/Region override raw 데이터 | 구조형 |
| `crypto_test.conf` | 암호 엔진 테스트 | 0x0078 |

### K. 메모리 / 레지스터 / 디버그
| 파일 | 기능 | CmdCode |
|---|---|---|
| `mem.conf` | 메모리/레지스터 read·write | 0x0086 |
| **`debug.conf`** | **0x008b 디버그·튜닝 서브커맨드 33종**(thermal_mgmt 포함) | 0x008b (+SUBID) |
| `small_debug.conf` | debug 축소 세트 | 0x008b/0x008c |
| `debug_ci_mode.conf` | CI 디버그 모드 | 0x008b |

### L. uAP / 초기화 / 드라이버 파라미터
| 파일 | 기능 | 도구 |
|---|---|---|
| `uaputl.conf` | uAP 메인 설정(SSID·채널·보안) | uaputl |
| `embedded_dhcp.conf` | 내장 DHCP 서버 | uaputl |
| `wifi_mod_para.conf` | 드라이버 모듈 로드 파라미터(칩별) | 모듈 로드 |
| `init_cfg.conf` | 초기화 설정 | mlanconfig |
| `smc.conf` | SMC 단독연결(SSID/Beacon/Scan) | 0x012d |

---

## 3. 심층분석 가이드 — "mlanutl/모듈 파라미터로 안 될 때"

### 3-1. 해결 경로 우선순위
1. **모듈 파라미터** (`wifi_mod_para.conf` / insmod 인자) — 부팅·로드 시점 고정 설정.
2. **mlanutl 서브커맨드** — 런타임 제어. 구현 목록: `mapp/mlanutl/mlanutl.c`의 `command_map[]`.
3. **conf + hostcmd** (이 문서) — mlanutl에 명령이 없을 때 raw host command로 우회.
   - `thermal_mgmt`이 정확히 이 경로의 선례: debug.conf 블록(0x008b/SUBID 0x113)을 mlanutl 코드로 하드코딩.

### 3-2. CmdCode → 코드 추적 순서
1. `mlan/mlan_fw.h` 에서 `0x....` CmdCode의 `HostCmd_CMD_*` 매크로/구조체 정의 확인.
2. `mlan/mlan_sta_cmd.c` (요청 빌드) / `mlan/mlan_sta_cmdresp.c` (응답 파싱)에서 처리 핸들러 확인.
3. host command 전달 경로: `mlinux/moal_eth_ioctl.c`의 hostcmd 처리(`MLAN_OID_MISC_HOST_CMD`).
4. 기존 mlanutl 대안 유무: `mapp/mlanutl/mlanutl.c` `command_map[]` grep.

### 3-3. 0x008b(CMD_DBGS_CFG) 서브기능을 다룰 때
- 파일에 `CmdCode=0x008b` 가 보이면 **SUBID(2바이트)** 가 실제 기능 식별자다.
- `debug.conf`의 SUBID 목록(0x101 UL-OFDMA, 0x113 THERMAL, 0x127 TXOP, 0x12a MAC RECOVERY 등)이 사실상
  "펌웨어 디버그 서브기능 카탈로그". 새 기능을 mlanutl로 코드화하려면 SUBID + 페이로드 레이아웃을 그대로 옮기면 된다.
- 페이로드 구조 확인: `mlanutl mlanX hostcmd debug.conf <block> --hex` 로 raw 응답 덤프(thermal_mgmt 구현이 `--hex/--raw` 지원).

### 3-4. 주의 — 시험/진단 전용 (양산 비권장)
`debug.conf`, `small_debug.conf`, `debug_ci_mode.conf`, `cwmode.conf`, `crypto_test.conf`,
`ssu.conf`, `mem.conf` 및 debug.conf 내 `cm3_debugMon_handle`(브레이크포인트+덤프),
`set_drop_rxampdu`(의도적 Rx 드롭), `trigger_timeout`(강제 타임아웃)은 **시스템을 의도적으로
망가뜨리는 진단용**. 운영 적용 금지.

---

## 4. 참고 문서
- `docs/AN13297.pdf` — NXP "Embedded Wi-Fi Subsystem API Spec v17" (호스트-펌웨어 인터페이스).
  CmdCode 의미 확인용. 단 **0x008b 하위 SUBID(예: 0x113 thermal_mgmt)는 미문서화** — `CMD_DBGS_CFG=0x008B`만 존재.
- `docs/README_MLAN` — mlanutl 명령 레퍼런스. `thermal`(온도 읽기)은 문서화, `thermal_mgmt`는 미문서화.
