# MOAL Driver Module Parameters

**88Q9098 | AW690 | AW590**

---

> **Release Notes — COMPANY CONFIDENTIAL**
> NXP Semiconductors | Wi-Fi-BT-9098 MOAL Driver
> **Edition**: `feature/driver-bridge` (v2) — NXP 순정 레퍼런스 + hwjo 추가/재정의 파라미터 포함
> **갱신**: 2026-05-22

> **범례**: ✅ v2 신규(hwjo) · ✏️ v2 변경(hwjo 재정의) · 그 외는 NXP 순정.
> §1~§10은 NXP 순정 레퍼런스(드라이버 베이스 기준). §11은 v2(`feature/driver-bridge`)에서
> 추가/재정의된 파라미터, §12 이후는 v2 동작 분석(설정 흐름·conf 블록·git 이력 등).

---

## Contents

- [1. 펌웨어 / 하드웨어](#1-펌웨어--하드웨어)
- [2. 인터페이스 구성](#2-인터페이스-구성)
- [3. 802.11 기능](#3-80211-기능)
- [4. 전력 관리](#4-전력-관리)
- [5. 성능 최적화](#5-성능-최적화)
- [6. cfg80211 / WEXT](#6-cfg80211--wext)
- [7. 구성 파일](#7-구성-파일)
- [8. 워크큐 / 스케줄링](#8-워크큐--스케줄링)
- [9. PCIe](#9-pcie)
- [10. 디버그 / 기타](#10-디버그--기타)
- [11. L2 브릿지 / 관리 로깅 (v2 추가)](#11-l2-브릿지--관리-로깅-v2-추가)
- [12. 설정 우선순위 & 수명주기](#12-설정-우선순위--수명주기)
- [13. conf 파일 블록 구조](#13-conf-파일-블록-구조)
- [14. 실제 wifi_mod_para.conf 블록 구성](#14-실제-wifi_mod_paraconf-블록-구성)
- [15. 부팅 시 블록 재작성 (wifi_init.sh)](#15-부팅-시-블록-재작성-wifi_initsh)
- [16. bridge_mode=0일 때 동작](#16-bridge_mode0일-때-동작)
- [17. bridge_consume_link_local 진단 결과](#17-bridge_consume_link_local-진단-결과)
- [18. 브릿지 로그 정보](#18-브릿지-로그-정보)
- [19. git 커밋 이력 (hwjo)](#19-git-커밋-이력-hwjo)
- [부록: 코드 참조 위치](#부록-코드-참조-위치)

---

## 1. 펌웨어 / 하드웨어

| 파라미터 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `fw_name` | charp | NULL | 사용할 펌웨어 파일 이름 |
| `hw_name` | charp | NULL | 하드웨어 이름 |
| `req_fw_nowait` | int | 0 | 0: `request_firmware` API 사용<br>1: `request_firmware_nowait` API 사용 |
| `fw_reload` | int | 0 | 0: fw_reload 비활성화<br>1: fw_reload 활성화 |
| `auto_fw_reload` | int | PCIE: `3`, 그 외: `1` | BIT0: auto fw_reload 활성화<br>BIT1(PCIE): 0=FLR, 1=in-band reset |
| `fw_serial` | int | 1 | 0: 병렬 FW 다운로드<br>1: 직렬 FW 다운로드 |
| `mac_addr` | charp | NULL | MAC 주소 설정 |
| `hw_test` | int | 0 | 0: 하드웨어 테스트 비활성화<br>1: 하드웨어 테스트 활성화 |
| `rf_test_mode` | int | 0 | 0: 일반 FW 다운로드<br>1: RF 테스트 모드 FW 다운로드 |
| `mfg_mode` | int | 0 | 0: 일반 FW 다운로드<br>1: MFG FW 다운로드 (`MFG_CMD_SUPPORT` 정의 시) |

---

## 2. 인터페이스 구성

| 파라미터 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `drv_mode` | int | `DRV_MODE_STA \| DRV_MODE_UAP` | Bit0: STA<br>Bit1: uAP<br>Bit2: WIFIDIRECT<br>Bit4: NAN<br>Bit6: MAC80211<br>Bit7: ZERO_DFS |
| `max_sta_bss` | int | 1 | STA 인터페이스 최대 개수 |
| `sta_name` | charp | NULL | STA 인터페이스 이름 |
| `max_uap_bss` | int | 1 | uAP 인터페이스 최대 개수 |
| `uap_name` | charp | NULL | uAP 인터페이스 이름 |
| `max_wfd_bss` | int | 1 | WIFIDIRECT 인터페이스 최대 개수 |
| `wfd_name` | charp | NULL | WIFIDIRECT 인터페이스 이름 |
| `max_vir_bss` | int | 0 | 가상 인터페이스 최대 개수 |
| `max_nan_bss` | int | 1 | NAN 인터페이스 최대 개수 |
| `nan_name` | charp | NULL | NAN 인터페이스 이름 |
| `uap_max_sta` | int | 0 | uAP/GO 최대 연결 스테이션 수 |
| `wacp_mode` | int | 0 | WACP 모드: 0=DEFAULT, 1=MODE_1, 2=MODE_2 |
| `uap_oper_ctrl` | uint | 0 | uAP 동작 제어<br>`0x20001`: channel 6에서 uAP 재시작 |

---

## 3. 802.11 기능

| 파라미터 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `auto_ds` | int | 0 | 0: MLAN 기본값<br>1: Auto Deep Sleep 활성화<br>2: Auto Deep Sleep 비활성화 |
| `ext_scan` | int | 0 | 0: MLAN 기본값<br>1: Extended Scan 활성화<br>2: Enhanced Extended Scan 활성화 |
| `tcpackenh` | int | 1 | TCP ACK Enhancement<br>0: 비활성화, 1: 활성화 |
| `ps_mode` | int | 0 | 0: MLAN 기본값<br>1: IEEE PS 모드 활성화<br>2: IEEE PS 모드 비활성화 |
| `p2a_scan` | int | 0 | DFS 채널 패시브→액티브 스캔<br>0: MLAN 기본값, 1: 활성화, 2: 비활성화 |
| `scan_chan_gap` | int | 0 | AP 연결 상태에서 스캔 채널 간 시간 간격 (ms, 최대 500) |
| `sched_scan` | int | 1 | 0: Scheduled Scan 비활성화<br>1: Scheduled Scan 활성화 |
| `max_tx_buf` | int | 0 | 최대 Tx 버퍼 크기: 2048 / 4096 / 8192 |
| `pm_keep_power` | int | 1 | 0: PM no power<br>1: PM keep power |
| `cfg_11d` | int | 0 | 0: MLAN 기본값<br>1: 802.11d 활성화<br>2: 802.11d 비활성화 |
| `napi` | int | 0 | 0: NAPI 비활성화<br>1: NAPI 활성화 |
| `dfs_offload` | int | 0 | 0: DFS offload 비활성화<br>1: DFS offload 활성화 |
| `cfg80211_drcs` | int | 0 | 0: DRCS 비활성화<br>1: DRCS 활성화 |
| `dmcs` | int | 0 | 0: 동적 다중 채널 비활성화<br>1: 활성화 |
| `roamoffload_in_hs` | int | 0 | 0: 항상 FW 로밍 활성화<br>1: Host suspend 시에만 FW 로밍 활성화 |
| `keep_previous_scan` | int | 1 | 0: 스캔 시작 전 이전 결과 삭제<br>1: 이전 스캔 결과 유지 |
| `auto_11ax` | int | 1 | 0: auto 11ax 비활성화<br>1: auto 11ax 활성화 |
| `dfs53cfg` | int | 0 | W53 DFS 설정<br>0: FW 기본값, 1: 신규 W53, 2: 구형 W53 |
| `chan_track` | int | 0 | 채널 추적 설정 (9098 전용)<br>0: 복원, 1: 설정 |
| `drcs_chantime_mode` | int | 0 | DRCS 채널 시간/모드 비트마스크<br>Bit[31:24]: CH0 채널 타임<br>Bit[23:16]: CH0 모드<br>Bit[15:8]: CH1 채널 타임<br>Bit[7:0]: CH1 모드 (0=PM1, 1=Null2Self) |
| `multi_dtim` | ushort | 0 | DTIM 간격 |
| `inact_tmo` | ushort | 0 | IEEE PS inactivity timeout 값 |

---

## 4. 전력 관리

| 파라미터 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `hs_wake_interval` | int | 400 | Host sleep 웨이크업 간격<br>(FW에서 가장 가까운 `dtim × beacon_period` 배수로 반올림) |
| `hs_mimo_switch` | int | 0 | Host sleep 중 동적 MIMO↔SISO 전환<br>0: 비활성화, 1: 활성화 |
| `low_power_mode_enable` | int | 0 | 0: 저전력 모드 비활성화<br>1: 저전력 모드 활성화 |
| `wakelock_timeout` | int | 3000 | Wakelock 타임아웃 (ms)<br>Android 커널 전용 (`ANDROID_KERNEL` 정의 시) |
| `gtk_rekey_offload` | int | 0 | 0: GTK rekey offload 비활성화<br>1: GTK rekey offload 활성화<br>2: suspend 모드에서만 활성화 |
| `disconnect_on_suspend` | int | 0 | 0: suspend 시 WiFi 유지<br>1: suspend 시 WiFi 연결 해제 |

---

## 5. 성능 최적화

| 파라미터 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `rps` | uint | 0 | RPS (Receive Packet Steering) CPU 설정<br>Bit0~Bit4: 특정 CPU 활성화, 0: RPS 비활성화 |
| `edmac_ctrl` | int | 0 | 0: EDMAC 비활성화<br>1: EDMAC 활성화 |
| `tx_skb_clone` | uint | 0 | 0: TX SKB 복제 비활성화<br>1: TX SKB 복제 활성화 |
| `pmqos` | uint | IMX: `1`, 그 외: `0` | 0: PM QoS 비활성화<br>1: PM QoS 활성화 (`IMX_SUPPORT` 정의 시 기본 1) |
| `mcs32` | uint | 1 | 0: MCS32 비활성화<br>1: MCS32 활성화 |
| `hs_auto_arp` | uint | 0 | 0: Host sleep auto ARP 비활성화<br>1: 활성화 |
| ✏️ `net_rx` | int | **1** | RX 전달 경로 + 관리 프레임 로깅 비트맵 (v2 재정의)<br>0: `netif_rx_ni`<br>1: `netif_receive_skb`<br>2: 1+roaming RX log<br>3: 1+all RX log<br>+4: TX log (예: 6=roaming RX+TX, 7=all RX+TX)<br>→ `/proc/mwlan/*/mgmt_log` 64KB ring. `mgmt_hex_dump` 의존(§11) |
| `amsdu_deaggr` | int | 0 | 0: 기본값<br>1: AMSDU deaggregation 시 버퍼 복사 회피 |
| `pmic` | int | 0 | 0: PMIC 설정 커맨드 미전송<br>1: 펌웨어로 PMIC 설정 커맨드 전송 |
| `antcfg` | int | 0 | 안테나 구성 (하드웨어 모델별 상이) |

> ✏️ `net_rx`: NXP 순정은 "0:netif_rx_ni / 1:netif_receive_skb"(기본 0)였으나, 베이스 업데이트로 기본값 1,
> hwjo가 비트맵으로 의미 확장(커밋 `5835c85`). 상세 §11.7.

---

## 6. cfg80211 / WEXT

| 파라미터 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `cfg80211_wext` | int | `STA_CFG80211_MASK \| UAP_CFG80211_MASK` | Bit0: STA WEXT<br>Bit1: UAP WEXT<br>Bit2: STA CFG80211<br>Bit3: UAP CFG80211 |
| `host_mlme` | int | 1 | 0: Host MLME 비활성화<br>1: Host MLME 활성화 (cfg80211 ≥ 3.8.0) |
| `disable_regd_by_driver` | int | 1 | 0: 드라이버 regulatory domain 설정 활성화<br>1: 드라이버 regulatory domain 설정 비활성화 |
| `reg_alpha2` | charp | NULL | 규제 도메인 alpha2 코드 (예: "US", "KR") |
| `country_ie_ignore` | int | 0 | 0: AP Country IE 따름, beacon hint 활성화<br>1: Country IE 무시, beacon hint 비활성화 |
| `beacon_hints` | int | 0 | 0: Beacon hints 활성화<br>1: Beacon hints 비활성화 |
| `mon_filter` | int | `0x27` | 모니터 모드 프레임 필터<br>Bit6: TX frames (control 제외)<br>Bit5: non-BSS beacons<br>Bit3: unicast non-promiscuous<br>Bit2: data frames<br>Bit1: control frames<br>Bit0: management frames |

---

## 7. 구성 파일

| 파라미터 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `mod_para` | charp | NULL | 모듈 파라미터 설정 파일 경로 (블록 구조 §13) |
| `dts_enable` | int | CONFIG_OF 정의 시: `1` | 0: DTS 비활성화<br>1: DTS 활성화 |
| `init_cfg` | charp | NULL | 초기화 설정 파일 경로 |
| `cal_data_cfg` | charp | NULL | 캘리브레이션 데이터 파일 경로 |
| `txpwrlimit_cfg` | charp | NULL | TX 전력 제한 설정 파일 경로 |
| `cntry_txpwr` | int | 0 | 0: 비활성화<br>1: 국가 txpower 테이블 설정<br>2: 국가 rgpower 테이블 설정 |
| `init_hostcmd_cfg` | charp | NULL | 초기화 hostcmd 파일 경로 |
| `band_steer_cfg` | charp | NULL | Band steering 설정 파일 경로 |
| `dpd_data_cfg` | charp | NULL | DPD (Digital Pre-Distortion) 데이터 파일 경로 |

---

## 8. 워크큐 / 스케줄링

| 파라미터 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `wq_sched_prio` | int | 0 | 워크큐 스케줄링 우선순위 |
| `wq_sched_policy` | int | 0 (`SCHED_NORMAL`) | 워크큐 스케줄링 정책<br>0: SCHED_NORMAL<br>1: SCHED_FIFO<br>2: SCHED_RR<br>3: SCHED_BATCH<br>5: SCHED_IDLE |
| `rx_work` | int | 0 | 0: 기본값<br>1: RX 워크큐 활성화<br>2: RX 워크큐 비활성화 |
| `reg_work` | int | 0 | 0: register 워크큐 비활성화<br>1: register 워크큐 활성화 |

> 참고: 브릿지 전용 kthread(w2p/p2w)의 스케줄 정책/우선순위도 `wq_sched_policy`/`wq_sched_prio`를
> 재사용. 미지정(0,0) 또는 SCHED_FIFO/RR 외 값은 SCHED_FIFO로 폴백 (§11, `moal_bridge.c`).

---

## 9. PCIe

> `PCIE` 컴파일 옵션 정의 시에만 유효한 파라미터입니다.

| 파라미터 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `pcie_int_mode` | int | 1 (`MSI`) | PCIe 인터럽트 모드<br>0: Legacy, 1: MSI, 2: MSI-X |
| `ring_size` | int | 0 (기본: 128) | ADMA DMA ring 크기<br>유효값: 32 / 64 / 128 / 256 / 512 |

---

## 10. 디버그 / 기타

| 파라미터 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `drvdbg` | uint | `DEFAULT_DEBUG_MASK` | 드라이버 디버그 레벨 마스크 (`DEBUG_LEVEL1` 정의 시에만). 비트: MMSG=bit0, MFATAL=bit1, MERROR=bit2 … (`mlan_decl.h`) |
| `plinkstats` | charp | NULL | 링크 통계 설정<br>0: 비활성화, 1: 활성화, 2: 리셋 |
| `dev_cap_mask` | uint | `0xffffffff` | 장치 기능 마스크 (n→0xfffcdfff, ac→0xfffcffff; §15) |
| `indication_gpio` | int | `0xff` | 웨이크업 표시 GPIO<br>High 4bit: 정상 웨이크업 레벨<br>Low 4bit: GPIO 핀 번호 |
| `indrstcfg` | int | `0xffffffff` | Independent reset 설정<br>High byte: GPIO 핀 번호<br>Low byte: IR 모드 |
| `fixed_beacon_buffer` | int | 0 | 0: 기본 버퍼 크기 할당<br>1: 최대 버퍼 크기 할당 |
| `GoAgeoutTime` | int | 0 | GO Age-out 타임 설정 (100ms 단위)<br>0: FW 기본값 사용 (`WIFI_DIRECT_SUPPORT` 정의 시) |
| `mac80211_rate_adapt` | int | 0 | 0: FW rate adaptation 사용<br>1: MAC80211 기반 rate adaptation 사용 |
| ✅ `mgmt_hex_dump` | int | 0 | 관리 프레임 IE byte-level hex 캡처 (v2 신규, §11.8) |

---

## 11. L2 브릿지 / 관리 로깅 (v2 추가)

`feature/driver-bridge` 브랜치에서 hwjo가 추가/재정의한 파라미터. 일반 `module_param`은
perm `0644`일 때만 sysfs 런타임 변경 가능하며, `bridge_iface`는 전용 callback으로 동작한다.

| 파라미터 | 타입 | perm | 기본값 | 런타임변경 | conf 파싱 | 도입 커밋 |
|---|---|---|---|---|---|---|
| ✅ `bridge_mode` | int | 0 | 0(off) | ✗ | ✓ | 35ec541 |
| ✅ `bridge_runtime_switch` | int | 0444 | 0(off) | ✗(로드 시에만) | ✓(전역 enable-only) | runtime-switch |
| ✅ `bridge_runtime_deferred` | int | 0444 | 0(off) | ✗(로드 시에만) | ✓(전역 enable-only) | runtime-bridge-deferred-switch |
| ✅ `bridge_iface` | custom string | 0644 | `none`(비활성) | ✓(활성 브릿지만) | ✗ | runtime-switch |
| ✅ `bridge_peer` | charp | 0 | eth0 | ✗ | ✓ | 35ec541 |
| ✅ `bridge_wlan_idx` | int | 0 | 0 | ✗ | ✓ | 35ec541 |
| ✅ `bridge_debug` | int | 0644 | 0 | ✓(sysfs) | ✗ | 35ec541 |
| ✅ `bridge_keepalive_ms` | int | 0644 | 1ms | ✓ | ✓(`_present`) | fe46fea |
| ✅ `bridge_consume_link_local` | int | 0644 | 0 | ✓ | ✗ | 69d1b43 |
| ✅ `bridge_local_hairpin` | int | 0644 | 0(off) | ✓(sysfs) | ✗ | 81a5805 |
| ✏️ `net_rx` | int | 0 | 1 | ✗ | ✓ | 의미확장 5835c85 |
| ✅ `mgmt_hex_dump` | int | 0 | 0(off) | ✗ | ✓(per-adapter) | 8d7c2d1 |

`bridge_local_hairpin`(로컬 hairpin): 로컬발 TX(dst==클론 MAC) 유선 divert + ARP tee/inject로
BD↔유선peer IP 통신을 peer IP 인지(peer_route/ip_discovery) 없이 성립시킴 — AP intra-BSS
무반사 환경의 유일 해법. wifi_init.sh가 JSON `wbridge.moal.local_hairpin`을 parmtype 게이트
후 insmod 인자로 전달. 설계·실측: `docs/moal-bridge-local-hairpin.design.md`.

### 11.1 `bridge_mode` — int, 기본 0(off), perm 0
커널 내 L2 브릿지(WLAN ↔ eth 직접 포워딩) 마스터 스위치. userspace pcap-wbridge 대체.
1이면 `moal_bridge_init()` 호출(`moal_main.c:4370`), 0이면 코드 경로 전체 미실행(`handle->bridge=NULL`).
perm 0이라 런타임 변경 불가(모듈 리로드 필요).

### 11.2 `bridge_peer` — charp, 기본 "eth0", perm 0
브릿지 상대편(유선) 인터페이스 이름. promiscuous + rx_handler 등록 대상. `IFNAMSIZ`로 잘림.
없으면 `bridge: peer 'xxx' not found`(MERROR), init 실패.

### 11.3 `bridge_wlan_idx` — int, 기본 0, perm 0
DBDC에서 브릿지에 묶을 WLAN BSS 인덱스(`handle->priv[idx]`). 브릿지는 전역 1 인스턴스만 허용(DBDC guard).
범위 밖/미준비 시 `bridge: wlan BSS[N] not ready`(MERROR).

### 11.4 `bridge_debug` — int, 기본 0(off), perm 0644
`BR_DBG` verbose 패킷 로그 토글(`moal_bridge.c:26`). `echo 1 > /sys/module/moal/parameters/bridge_debug`.
패킷별 latency(us) 로그(`w2p FWD ... %lldus`) 포함 — 31ms→7ms 최적화 측정 노브. conf 파싱 없음.

### 11.5 `bridge_keepalive_ms` — int, 기본 1(ms), perm 0644
SDIO 처리 루프(`main_work`)를 주기적으로 깨워 warm 유지하는 hrtimer 간격. `0`=off, `1+`=ms.
**유일하게 `_present` 플래그 보유**: 기본값 1 때문에 conf의 명시적 `=0`(off)이 무시되던 버그를
"설정 여부"로 판정하도록 수정(`06bc662`).

### 11.6 `bridge_consume_link_local` — int, 기본 0, perm 0644
link-local(STP/LACP/LLDP, `01:80:C2:00:00:0X`) 프레임을 드라이버에서 명시 폐기할지 결정하는
**진단 A/B 토글**(w2p 방향만). 결과는 §17.

### 11.7 `net_rx` — int, 기본 1 *(NXP 파라미터 재정의)*
§5 표 참조. 비트맵: 0/1=RX 전달, 2/3=roaming/all RX log, +4=TX log. `/proc/mwlan/*/mgmt_log` 64KB ring.
파라미터·기본값은 NXP, **의미 확장만 hwjo**(`5835c85`). `fe46fea`의 "restore net_rx"는 `moal_shim.c`의
net_rx=0 경로 + `rx_pending>50` backpressure 동작 복원(파라미터 정의 무관).

### 11.8 `mgmt_hex_dump` — int, 기본 0(off), perm 0
관리 프레임 IE byte-level hex 캡처(tag 255 ext_id 분리). `/proc/mwlan/adapter*/mgmt_dump` 256KB ring.
conf per-adapter 키 `mlanN.mgmt_hex_dump_enable`. 동작하려면 `net_rx>=2`(RX)·`net_rx&0x4`(TX) 필요.

### 11.9 런타임 브릿지 인터페이스 전환

`bridge_runtime_switch`는 전역 int, 기본값 0, perm `0444`인 **모듈 로드 시 opt-in**이다.
`insmod ... bridge_runtime_switch=1` 또는 선택된 `wifi_mod_para.conf` 블록의
`bridge_runtime_switch=1`로 활성화할 수 있다. 로드 후 sysfs로 값을 바꿀 수 없으며 값이 정확히
1일 때만 전환 write를 허용한다.

`mod_para`는 DBDC 어댑터 블록마다 파싱되지만 runtime switch gate는 단일 브릿지에 대한 모듈
전역 정책이다. 따라서 값은 **enable-only OR**로 합쳐진다. 명시적인 insmod 값이나 정상 파싱된
블록 중 하나라도 1이면 최종값은 1이며, 뒤에서 읽은 다른 블록의 0은 이미 활성화된 gate를 끄지
않는다. 모든 블록이 0이고 insmod 인자도 없을 때만 0이다. 0 또는 1 이외의 conf 값은 해당 블록을
invalid로 거절한다. 파싱 시 effective/conf 값을 함께 출력한다.

```text
SD9098_0 = {
    bridge_mode=1
    bridge_runtime_switch=1
}
SD9098_1 = {
    bridge_mode=0
    bridge_runtime_switch=0
}
```

위 설정에서 초기 owner는 mlan0이고 runtime gate는 전역으로 1이다. mlan1의
`bridge_runtime_switch=0`은 mlan1을 전환 대상으로 금지한다는 뜻이 아니다. 등록되어 있고
수명이 유효한 MOAL STA이면 아래 sysfs write의 구조적 target이 될 수 있다. strict mode 또는
이미 ready인 target은 operational/association 검증을 통과해야 완료되며, deferred mode의
not-ready target은 현재 owner를 유지한 채 요청만 수락한다.
`bridge_iface`는 perm `0644`인 custom string 파라미터다. read는 설정 문자열이 아니라 현재
effective owner가 binding한 현재 WLAN 이름(`none`이면 owner 없음)을 반환하고, write는 이미 존재하며
등록된 MOAL STA 인터페이스를 새 타겟으로 지정한다.
peer가 일시 DOWN이라 forwarding의 `active=0`이어도 **effective owner가 남아 있으면** 이름을
반환한다. 즉 `active`는 forwarding 상태이고 `bridge_iface`의 `none`은 owner가 없는 inactive
terminal state만 뜻한다. WLAN/peer rename은 notifier와 name lock으로 getter/stats에 반영되며,
전환 identity는 이름이 아닌 transaction 동안 참조된 exact netdev다.

```bash
insmod moal.ko mod_para=cts/wifi_mod_para.conf
cat /sys/module/moal/parameters/bridge_iface
echo mlan1 > /sys/module/moal/parameters/bridge_iface
```

conf를 변경할 수 없는 환경에서는 기존처럼
`insmod moal.ko mod_para=... bridge_runtime_switch=1`을 사용할 수 있다.

`bridge_runtime_deferred=0`이거나 target이 이미 ready인 경우의 **strict ready completion**은
전체 deinit → target init → target/peer 최종 readiness 검증과, 실패 시 rollback 검증이 끝난
뒤 반환하므로 성공은 최종 owner 전환을 뜻한다. 반면 not-ready target에 대한
**deferred acceptance**는 pending 요청 등록 성공일 뿐 forwarding 전환 완료가 아니다. 이 구분은
아래 11.10절의 active/pending getter로 확인한다. module argument parsing 시점의
`bridge_iface=...`는 runtime lock 준비 전이므로 의도적으로 `EAGAIN`으로 module load를 거절한다.
활성 stats 끝에는 `iface=<wlan> peer=<peer>`와
`switch_ok=<n> switch_fail=<n> rollback_ok=<n> rollback_fail=<n>`이 추가된다. 네 outcome
counter는 모듈 전역 누계라 rebind 중 재생성되는 bridge instance와 함께 reset되지 않으며,
모듈을 unload/reload할 때만 초기화된다. stats node는 module-lifetime이므로 owner가 없을 때도
`bridge: inactive`, `iface=none peer=none` 및 네 counter를 읽을 수 있다.

아래 readiness errno(`ENETDOWN`, `ENOLINK`)는 deferred=0의 strict validation 또는 deferred
worker가 실제 transaction을 시작할 때의 결과다. deferred=1 public write에서 structurally valid한
not-ready target은 이 errno 대신 deferred acceptance로 pending에 등록된다.

| errno | 의미 |
|---|---|
| `EOPNOTSUPP` | opt-in gate가 꺼져 있거나 정확히 1이 아님 |
| `ENODEV` | 활성 브릿지가 없거나 지정 인터페이스가 존재하지 않음 |
| `EINVAL` | 빈 값, 과도한 길이, 잘못된 이름/개행 형식 또는 non-STA 타겟 |
| `ENETDOWN` | 타겟 netdev가 admin-DOWN/등록 해제/존재하지 않음/운영 불가이거나, 현재 binding의 peer가 DOWN/사용 불가임 |
| `ENOLINK` | **admin-UP인** 타겟 STA가 unassociated임. QA는 admin-UP를 별도로 확인한 뒤 이 errno만 기대한다. |
| `EBUSY` | 타겟 어댑터가 reset/removal 중이거나 hardware ready가 아님 |
| `EAGAIN` | module-argument parsing 등 runtime control 초기화 전 |
| `ESHUTDOWN` | writer가 기다리는 동안 module shutdown이 시작됨 |
| `EINTR` | semaphore wait가 signal로 중단됨(kernel 내부 결과는 `-ERESTARTSYS`) |
| `EIO` | target init 또는 최종 readiness 검증 실패 뒤, 기존 브릿지 rollback init 또는 rollback 최종 검증도 실패함 |

이 선택은 설정 파일에 저장되지 않으며 모듈 reload 뒤 지속되지 않는다. 또한 이미 활성인
브릿지에만 적용되므로 `bridge_mode=0`인 브릿지를 켜는 수단이 아니다. 전환은 기존 datapath를
해제한 후 새 datapath를 만들기 때문에 짧은 패킷 중단 또는 손실이 가능하며 lossless 전환을
보장하지 않는다. 실장비 검증 절차는 `docs/driver-bridge.qa-runbook.md`의 런타임 전환 절을 따른다.

PCIe/SDIO FLR, driver-mode switch, 또는 netdev를 직접 재생성하는 post-reset은 인터페이스 제거
전에 활성 브릿지를 동기 해제한다. **identity-preserving reset**은 target netdev identity가
유지될 때만 pending을 보존한다. **destructive netdev recreation**은 old handle/priv/netdev 이름을
아직 pin한 상태에서 그 identity에 해당하는 pending generation을 동기 무효화한 뒤 interface를
제거한다. primary/companion rebuild 전체가 성공한 뒤에만 reset 전의 exact effective
owner/BSS/peer/keepalive snapshot을 한 번 복구한다. runtime switch는
`handle->params.bridge_*` configured policy를 변경하지 않으므로 이후 same-card fallback이나
module reload에 누출되지 않는다. destructive firmware 단계 이후 실패는 firmware rollback을
주장하지 않으며, **terminal reset failure**에서는 unfulfillable pending을 모두 지우고 configured
policy는 유지하되 effective owner는 `none`, recovery status는 failure로 끝난다. gate가 0이어도
netdev/firmware/handle free 전에 bridge를 drain하는 순서는 UAF 방지 수명주기 invariant라 항상
적용된다. 정상 forwarding과 runtime write gate 의미는 변하지 않는다.

격리된 target QA용 빌드에서만 `CONFIG_BRIDGE_SWITCH_FAULT_INJECT=y`를 명시하면 root-only perm
`0600`의 one-shot `bridge_switch_fault_mask`가 생긴다(bit0 target init, bit1 rollback init).
기본/production Makefile 값은 `n`이다. production source/artifact acceptance에는 parameter 선언,
mask 변수, `xchg()` 및 target/rollback injected branch가 모두
`#ifdef BRIDGE_SWITCH_FAULT_INJECT` 안에 있어야 한다; static gate가 이를 fail-closed로 검사한다.
host에 있는 standard `.ko`는 symbol 부재를 별도 검사하지만, fresh build provenance 없이는 그
artifact를 final-source build 증거로 승격하지 않는다. 자세한 matrix는
`docs/driver-bridge.qa-runbook.md` T-15a/T-15b를 따른다.

### 11.10 `bridge_runtime_deferred` — int, 기본 0(off), perm 0444

등록된 MOAL STA가 operational 상태가 될 때까지 runtime bridge 요청을 보류하는 전역 정책이다.
이 정책은 runtime 전환 허용 여부를 켜지 않으므로 `bridge_runtime_switch=1`이 여전히 필요하다.
두 값을 함께 지정하는 예시는 다음과 같다.

```ini
bridge_runtime_switch=1
bridge_runtime_deferred=1
```

`insmod ... bridge_runtime_switch=1 bridge_runtime_deferred=1` 또는 선택된 `wifi_mod_para.conf`
블록에서 각각 활성화할 수 있다. `mod_para`는 DBDC 블록마다 파싱되지만 두 값 모두 모듈 전역
enable-only 정책으로 합쳐진다. 따라서 다른 선택된 DBDC 블록이나 명시적인 insmod 인자에서
이미 `1`로 활성화된 값을, 어떤 블록의 `bridge_runtime_deferred=0`도 되돌릴 수 없다. 모든
입력이 0일 때만 최종값이 0이며, key는 정확한 `bridge_runtime_deferred=` delimiter를 사용하고
value는 정확히 한 글자 `0` 또는 `1`이어야 한다. exact key의 empty, sign-only, leading-zero,
suffix 값은 해당 블록을 거부한다. prefix가 연장된 다른 key는 이 정책 key로 선택되지 않는다.

`bridge_runtime_deferred=0`은 호환성 기본값이다. 이때 `bridge_iface`의 한 번의
one-write는 기존의 strict synchronous 동작을 유지한다. 즉 admin-DOWN target은
`ENETDOWN`, admin-UP이지만 association되지 않은 target은 `ENOLINK`로 즉시 실패하며,
현재 effective owner와 counter를 바꾸지 않는다.

`bridge_runtime_deferred=1`일 때만 위 두 link-readiness 실패가 **보류 요청**으로
전환된다. `bridge_iface`는 계속 active/effective owner만 반환하고,
읽기 전용 `/sys/module/moal/parameters/bridge_pending_iface`는 별도로 pending target
이름을 반환한다. 요청이 없을 때 이 getter의 wire value는 newline만 있는 **empty line**이다.
반대로 stats는 `pending_iface=none pending_state=none`을 사용한다. 따라서 application은 별도의 ioctl/netlink/polling
write protocol 없이 한 번의 one-write로 요청하고, 필요하면 두 getter를 읽어 owner와
pending을 구분한다. pending write의 성공은 아직 data-plane 전환 성공이 아니라 요청 수락이다.

보류 요청에는 no timeout이 없다. target이 `NETDEV_UP`/`NETDEV_CHANGE` 뒤 operational,
carrier, association 조건을 충족하면 worker가 자동으로 일반 switch transaction을 실행한다.
실제로 pending이 있을 때 현재 active interface 이름을 다시 쓰면 readiness와 무관하게 그
pending을 cancel한다. pending이 없으면 동일-name write도 기존 strict target/peer readiness
검증을 거친다. 다른 **link-not-ready** target을 쓰면 기존 pending을 replace하며, true
replacement에는 active와 기존 pending 양쪽과 다른 registered/present third STA가 필요하다.
ready target write는 replace가 아니라 immediate transaction을 수행한다. init_net의 `NETDEV_UNREGISTER` 또는
pending old name이 init_net에서 실제로 사라진 `NETDEV_CHANGENAME`만 해당 identity를 cancel한다.
unrelated device rename이나 cross-netns same-name event는 무시하며, 이름 재사용 전에 generation을
무효화하므로 같은 이름의 새 netdev가 이전 요청을 재사용하지 않는다. worker
실패는 readiness pre-validation error(대기 유지)와 terminal switch/rollback error(요청 소거)를
kernel log와 pending stats state로 구분한다.

stats의 `pending_iface=<name|none> pending_state=<waiting|switching|none>`도 함께
캡처한다. active `iface=`/`bridge_iface`와 pending getter는 동의어가 아니다. link-ready,
association 및 active owner 전환은 target-ready evidence일 뿐 `mlan1`을 통한 end-to-end
data-plane 성공을 증명하지 않는다. same-MAC/multi-BSSID 환경에서 mlan1 data-plane이
실패하는 현상은 runtime bridge policy와 별개로 추적·보고한다.

---

## 12. 설정 우선순위 & 수명주기

```
conf 블록(wifi_mod_para.conf)  >  insmod 인자  >  컴파일 기본값
```

```
전역 선언(moal_init.c) → module_param/MODULE_PARM_DESC
   → (선택) conf 파싱: parse_cfg_read_block() → moal_mod_para(임시)
   → woal_setup_module_param(): insmod/default 깔고 conf 값이 nonzero일 때만 override
   → handle->params.* 저장 → 소비처(moal_main.c / moal_bridge.c / moal_shim.c)
```

override 모델(`kzalloc` 0이 insmod 값 지우는 것 방지):
```c
handle->params.bridge_mode = bridge_mode;                  // insmod/default 먼저
if (params->bridge_mode) handle->params.bridge_mode = params->bridge_mode;  // conf override(nonzero만)
```
→ 이 "nonzero만 override" 한계가 `bridge_keepalive_ms`의 `_present` 버그(§11.5) 원인.

---

## 13. conf 파일 블록 구조

형식: `<card_type>[_<block_id>] = { key=value ... }`

- 블록 구분은 **netdev(mlan0/uap0)별이 아니라 "card_type + blk_id"별** (= 카드/라디오 인스턴스별).
- `parse_line_read_card_info()`가 헤더를 `=`로 자르고 `_`로 다시 나눠 앞=card_type, 뒤=blk_id.
- 매칭(`woal_init_module_param`): 각 `moal_handle`(물리 카드)가 자기 card_type 블록을 찾고,
  `woal_validate_cfg_id()`로 같은 card_type의 다른 handle이 점유한 blk_id면 skip → 다음 블록.
  매칭 없으면 `woal_cfg_fallback_process()`가 최저 blk_id 블록 사용.
- 블록 내부 같은 키 중복 시 **last-wins**(에러 없음).

| 구분 | 다르게 설정 가능? | 방법 |
|---|---|---|
| 카드/라디오 인스턴스별 | ✓ | `card_type_blkid={...}` 블록 분리 |
| 같은 handle 내 netdev별(mlan0 vs uap0) | ✗ | `handle->params` 공유 |
| 같은 카드 내 특정 BSS 타깃 | △ | `bridge_wlan_idx`로 지정(전역 1 브릿지) |

---

## 14. 실제 wifi_mod_para.conf 블록 구성

> 파일 두 벌: `bin_wlan/config/wifi_mod_para.conf`(NXP 순정, bridge 키 없음) vs
> 배포본 `wlan-package/.../usr/lib/firmware/cts/wifi_mod_para.conf`(**실제 사용**, bridge 키 있음).
> 드라이버는 `insmod ... mod_para=cts/wifi_mod_para.conf`로 후자를 읽음.

정적 블록 목록:
```
SD8997, SD8987, PCIE8997,         ← 레거시 단일 라디오 (bridge 키 없음)
PCIE9098_0, PCIE9098_1,           ← DBDC(PCIe)  ★ bridge_mode/bridge_debug 보유
SD9098_0,   SD9098_1,             ← DBDC(SDIO)  ★ bridge_mode/bridge_debug 보유
SDIW416, SD8801, SDIW612          ← 기타 칩
```

9098 DBDC 블록 정적 기본값(요지):
```
SD9098_0 = { drv_mode=1 ps_mode=2 auto_ds=2 host_mlme=1 sta_name=mlan napi=1
             net_rx=1  bridge_mode=0  bridge_debug=0  fw_name=cts/sd9098_wlan_v1.bin }
PCIE9098_0 = { ... pcie_int_mode=1 net_rx=1 bridge_mode=0 bridge_debug=0 ... }
```
→ bridge 파라미터는 **9098 DBDC 블록에만** 존재. 정적 상태에선 전부 `bridge_mode=0`.

---

## 15. 부팅 시 블록 재작성 (wifi_init.sh)

정적 값은 그대로 쓰이지 않고, 부팅 때 `wifi_init_conf.json`을 읽어 `apply_mod_para_from_json()`이
**활성 블록 키를 in-place 덮어씀**:

- **활성 블록 prefix**: `BUS_TYPE=sdio → SD9098`, 그 외 → `PCIE9098`
- **`_0` ← mlan0, `_1` ← mlan1** (DBDC 두 라디오 매핑)

| 블록 키 | JSON 소스 | 변환 |
|---|---|---|
| `net_rx` | `mlanN.net_rx` | 그대로(int) |
| `mgmt_hex_dump` | `mlanN.mgmt_hex_dump_enable` | bool→1/0 |
| `bridge_mode` | `wbridge.engine` + `wbridge.bridge_iface` | engine=moal일 때 bridge_iface 블록만 1, 아니면 둘 다 0 |
| `dev_cap_mask` | `mlanN.STANDARD`(없으면 global) | n→0xfffcdfff, ac→0xfffcffff, native max↑이면 라인 삭제 |
| `cal_data_cfg` | `mlanN.CAL_DATA_CFG` | 경로 set, 빈값/none → `none` |

→ "인터페이스별로 다르게"의 실제 구현체: `_0`/`_1` = mlan0/mlan1 = 별도 라디오(별도 handle)라 독립 설정 가능.

**현재 JSON 기준 산출(2026-05-22 배포본)**: `BUS_TYPE=sdio`, `wbridge.engine=pcap`(moal 아님),
`bridge_iface=mlan0`, net_rx 0/0, mgmt_hex_dump 0/0, STANDARD mlan0 ax / mlan1 ac.

| 블록(=인터페이스) | bridge_mode | net_rx | mgmt_hex_dump | dev_cap_mask |
|---|---|---|---|---|
| SD9098_0 (mlan0) | **0** | 0 | 0 | (삭제, ax=native max) |
| SD9098_1 (mlan1) | **0** | 0 | 0 | (삭제, ac=native max) |

→ **현재 in-driver 브릿지는 양쪽 OFF**(유저스페이스 pcap wbridge 사용). `engine`을 `moal`로 바꾸면
`bridge_iface`(mlan0) 블록만 `bridge_mode=1`.

---

## 16. bridge_mode=0일 때 동작

**동작상 무시됨**(파싱·저장은 됨). 게이트 2겹:
1. **init 게이트**(`moal_main.c:4370`): `if (handle->params.bridge_mode)` → 0이면 `moal_bridge_init()` 미호출 → `handle->bridge=NULL`.
2. **RX 핫패스 가드**(`moal_shim.c`): `br = rcu_dereference(handle->bridge)` NULL → `if (br)` false → `moal_bridge_rx_fast()` 미호출.

| 파라미터 | 유일 소비 위치 | off 시 |
|---|---|---|
| bridge_peer | moal_bridge_init 인자 | 무시 |
| bridge_wlan_idx | moal_bridge_init 내부(bridge.c:864) | 무시 |
| bridge_keepalive_ms | keepalive timer(bridge.c:57,961) | 무시 |
| bridge_debug | BR_DBG/bridge.c:173,235,369,477 | 무시 |
| bridge_consume_link_local | bridge.c:399,402 | 무시 |

- 다른 키는 저장·init 로그(`bridge_peer = eth0`)는 나오지만 읽는 코드가 안 돌아 효과 0.
- `0644` 노브는 off 상태에서 sysfs 쓰기 가능하나 no-op. `bridge_mode`는 perm 0이라 런타임으로 못 켬 → **리로드 전까지 영구 inert**.

---

## 17. bridge_consume_link_local 진단 결과

`bridge_mode=1` 운영 시 `mlan0_rx_dropped`가 ~30s 주기 증가 → 원인 규명용 토글.

- 결론: **LLDP multicast(`01:80:c2:00:00:0e`)의 의도된 link-local drop = IEEE 802.1D 표준 준수, 버그 아님.**
- 실측 Phase A/B: 토글이 sysfs 카운터에 **영향 없음**(양쪽 모두 `rx_dropped Δ=4, rx_nohandler Δ=0`).
- → "해결책"이 아니라 "원인 규명용 실험 도구"이며, 결과는 *이 경로가 원인이 아님*. 기본 0 유지.
- 상세: `moal-mlan0-rx-drop-investigation.md` §8~§10.

---

## 18. 브릿지 로그 정보

| 메커니즘 | 게이트 | 예 |
|---|---|---|
| `BR_DBG` (커스텀 printk) | `bridge_debug` | `w2p FWD cpu=.. %lldus qlen=.. proto=.. len=..` |
| `pr_info_ratelimited` `[DBG-RXDROP]` | 없음(상시·ratelimited) | `[DBG-RXDROP] w2p link-local dst=%pM proto=.. len=.. consume=%d` |
| `PRINTM(MMSG/MERROR)` | `drvdbg` 비트(MMSG=bit0, MERROR=bit2) | init Configuration 블록, IPv4/netdev 이벤트, deinit 통계 |
| sysfs 카운터 | — | `/sys/kernel/moal_bridge/stats` (w2p/p2w fwd/bytes/drop/err/oom/qlen, active, peer_released) |

---

## 19. git 커밋 이력 (hwjo)

| 커밋 | 날짜 | 내용 |
|---|---|---|
| `5835c85` | 2026-04-08 | net_rx 의미 확장(비트맵) + `/proc/mwlan/*/mgmt_log` 64KB ring |
| `35ec541` | 2026-04-10 | L2 브릿지 신규: `bridge_mode/bridge_peer/bridge_wlan_idx/bridge_debug` |
| `fe46fea` | 2026-04-15 | `bridge_keepalive_ms` 신규 + net_rx 동작 복원(shim) + A-MSDU bridge |
| `bd89ff7` | 2026-04-15 | bridge 4종 conf 파싱 + params 구조체 + 우선순위 복사 |
| `06bc662` | 2026-04-17 | keepalive `_present` 버그 수정(explicit off 존중) |
| `69d1b43` | 2026-05-08 | `bridge_consume_link_local` 신규(RXDROP 트리아지) |
| `8d7c2d1` | 2026-05-14 | `mgmt_hex_dump` 신규(`/proc/mwlan/adapter*/mgmt_dump` 256KB ring) |

---

## 사용 예시

```bash
# 모듈 로드 시 파라미터 지정
insmod moal.ko drv_mode=1 fw_name=mrvl/sd8997_uapsta.bin

# L2 브릿지 최소 기동
insmod moal.ko ... bridge_mode=1 bridge_peer=eth0

# 브릿지 디버깅 (런타임)
echo 1 > /sys/module/moal/parameters/bridge_debug

# modprobe 설정 파일 (/etc/modprobe.d/mrvl.conf)
options moal drv_mode=3 max_sta_bss=1 max_uap_bss=1 cfg80211_wext=0xf
```

---

## 부록: 코드 참조 위치

| 항목 | 위치 |
|---|---|
| 전역 선언 | `mlinux/moal_init.c:90-101` (net_rx=90, mgmt_hex_dump=92, bridge_* 94-101) |
| module_param/PARM_DESC | `mlinux/moal_init.c:3166-3185` |
| conf 블록 파싱 | `mlinux/moal_init.c:666-` (`parse_cfg_read_block`), bridge 키 905-932 |
| 블록→adapter 매칭 | `mlinux/moal_init.c:2835-2939` (`woal_init_module_param`) |
| setup/override 복사 | `mlinux/moal_init.c:1732-` (`woal_setup_module_param`), bridge 1854-1872 |
| params 구조체 | `mlinux/moal_main.h:2740-2748` (bridge_*), `mgmt_dump` ring |
| bridge init 게이트 | `mlinux/moal_main.c:4369-4374` |
| bridge deinit | `mlinux/moal_main.c:13673-` / `moal_bridge.c:1009-` |
| RX 핫패스 가드 | `mlinux/moal_shim.c:2085-2086, 2158-2159, 2307-2310` |
| BR_DBG 매크로 | `mlinux/moal_bridge.c:26-29` |
| sysfs stats | `mlinux/moal_bridge.c:781-808` |
| drvdbg 레벨 | `mlinux/mlan_decl.h:663-666` (MMSG/MFATAL/MERROR/MDATA) |
| 배포 conf | `wlan-package/.../usr/lib/firmware/cts/wifi_mod_para.conf` |
| 부팅 재작성 | `wlan-package/.../usr/local/scripts/wifi_init.sh` (`apply_mod_para_from_json`) |

---

*Release Notes — COMPANY CONFIDENTIAL*
*NXP Semiconductors | v2 edition (feature/driver-bridge)*
