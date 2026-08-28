# main antcfg 커스터마이징의 ported 반영 감사

날짜: 2026-08-25  
비교 기준: `main@1ba9fd42` (505.p14 계열), `origin/ported@26400d66` (543.p18 계열)

## 결론

main PR #20의 antcfg/NSS 커스터마이징이 ported에서 통째로 빠진 것은 아니다.
PR #20의 8개 커밋은 모두 `origin/ported`의 조상이며, 핵심 MLAN 동작도 현재
ported 소스에 남아 있다.

다만 **userspace 응답 ABI는 동일하게 유지되지 않았다.** main은 2x2
`antcfg` GET의 네 word를 `Tx, Rx, user_htstream, reserved`로 사용하지만,
ported는 upstream 543의 네 word인 `Tx, Rx, Tx-6G, Rx-6G`를 보존하고
`user_htstream`을 별도 GET-only private command `antcfgnss`로 분리했다.

따라서 제품에 설치된 main 방식 `/usr/local/bin/mlanutl`을 ported 드라이버와
섞으면 SET 인자는 정상 전달되지만, host advertised NSS는 출력에서 조용히
누락될 수 있다. 이것은 실제 호환성 문제지만, `antcfg 0x303 0x101`의 두 번째
인자가 드라이버에 전달되지 않는 문제는 아니다.

## Git 계보

- main PR #20 merge: `09bc420`
- ported upstream 0396 merge: `cc7f79d`
- latest main reconciliation merge: `45f593e`
- ported 검토 보완: `fdba08f`, `e1fe289`
- `git merge-base main origin/ported`는 main HEAD인 `1ba9fd42`다.
- 아래 8개 PR #20 커밋 모두 `git branch --contains`에서 `main`과 `ported`에
  포함된다.

## PR #20 커밋별 반영 상태

| 커밋 | main 커스터마이징 | `origin/ported` 상태 |
|---|---|---|
| `64ab528` | vhtcfg 저장 MCS map에서 antcfg clamp 제거 | 유지. association IE 생성 시 clamp는 계속 적용 |
| `2e71a9f` | GET 응답이 `user_htstream`을 덮지 않도록 SET 응답만 갱신 | 유지 |
| `f5baa7a` | `user_htstream`을 MLAN/MOAL/mlanutl에 노출 | 핵심 필드·출력 유지, 단 ABI는 `antcfgnss`로 적응 |
| `1cc8db6` | 1x1 antcfg 응답을 3-word로 고정 | 유지 |
| `0e5bb4d` | Tx/Rx SET guard를 방향별로 분리 | 유지 |
| `f7b2b31` | HT NSS 제한을 2G/5G 모두 표시 | 유지 |
| `1a07d11` | `user_htstream`의 physical/advertised 의미 문서화 | 유지 |
| `fa1e088` | 실제 copy 길이보다 큰 antcfg 응답 길이를 보고하지 않음 | 유지 |

핵심 생존 근거는 `origin/ported`의 다음 함수에서 직접 확인된다.

- `mlan/mlan_cmdevt.c:wlan_ret_802_11_rf_antenna()`
  - `ant_tx_set`, `ant_rx_set`
  - SET 응답에서만 방향별 `user_htstream` 갱신
- `mlan/mlan_11ac.c:wlan_11ac_ioctl_vhtcfg()`
  - 저장된 VHT MCS map의 round-trip 보존
- `mlan/mlan_11ac.c:wlan_cmd_append_11ac_tlv()` 및
  `mlan/mlan_11ax.c:wlan_cmd_append_11ax_tlv()`
  - association capability에는 `user_htstream` NSS 제한 적용
- `mlan/mlan_ioctl.h:mlan_ds_ant_cfg`
  - upstream 6 GHz 필드 뒤에 `user_htstream` 유지

## ABI가 달라진 이유와 영향

### main/505

- `antcfg` 2x2 GET 16 bytes:
  `Tx, Rx, user_htstream, reserved`
- main mlanutl은 word 2를 `user_htstream`으로 해석한다.

### ported/543

- upstream antcfg 네 word 의미:
  `Tx, Rx, Tx-6G, Rx-6G`
- 88W9098에서는 보통 physical `Tx, Rx` 8 bytes만 반환한다.
- host NSS는 hidden GET-only `antcfgnss`에서 4 bytes로 별도 반환한다.
- bundled ported mlanutl의 `antcfg`는 내부에서 `antcfgnss`를 추가 조회해 두
  상태를 함께 표시한다.

이 분리는 우발 누락이 아니라 `cc7f79d` merge resolution에서 도입됐고,
`docs/upstream-port-0396-code-review.md`의 “antcfg, antcfgnss 및 NSS ABI”에
명시돼 있다. 이후 `fdba08f`와 `e1fe289`에서 지원 인자 형태와 1x1/2x2
layout 검증도 추가됐다.

## 관측 현상에 대한 판정

### `antcfg 0x303 0x101` SET exit 0, 즉시 physical GET `0x303/0x303`

이 결과만으로 main 커스터마이징 누락이라고 판단할 수 없다.

1. ioctl capture에서 두 SET 인자가 정확히 전달됐다.
2. SET 응답이 요청값 `Rx=0x101`을 echo했다면 host `user_htstream`은
   `0x2121`로 갱신된다.
3. 이후 GET에서 firmware가 physical `Rx=0x303`을 보고해도 GET-only 응답은
   host `user_htstream`을 덮지 않는다.
4. main 방식 mlanutl은 ported의 `antcfgnss`를 조회하지 못하므로 이 분리 상태를
   표시하지 못한다.

따라서 이 결과는 **물리 antenna와 advertised NSS의 분리 또는 FW 정상화**와
일치한다. SET response 자체가 이미 `Rx=0x303`이었는지는 계측 로그로 구분해야
한다. 이 경우에는 SET 응답 처리로 host NSS도 2SS가 될 수 있다.

### scan 후 Tx/ACK failure 급증

ported 소스에 SET-only guard, 방향별 guard, VHT 저장-map 보존 및 VHT/HE
association NSS clamp가 모두 있으므로, 현재 Git 증거만으로 scan wedge를
“main antcfg 커스터마이징 미포팅”에 귀속할 근거는 없다.

다만 잘못 짝지은 mlanutl 때문에 실제 `user_htstream`을 보지 못한 상태에서
테스트한 것은 사실이므로, 다음 계측값을 먼저 확정해야 한다.

- SET HostCmd request/response의 Tx/Rx action과 mask
- SET 전후 `user_htstream`
- 바로 뒤 GET 후 `user_htstream` 유지 여부
- association 직전 VHT/HE advertised Tx/Rx NSS
- scan 완료 후 physical antenna/channel/rate/Tx descriptor 상태

## 현재 호환 보완 상태

현재 작업트리의 mlanutl은 먼저 ported의 `antcfgnss` capability를 probe해 다음
두 16-byte ABI를 자동 구분하도록 보완돼 있다.

- main: word 2를 `user_htstream`으로 해석
- ported: word 2/3을 6 GHz antenna로 해석하고 `antcfgnss` 결과를 NSS로 표시

2026-08-25 로컬 검증:

```text
antcfg_cli_qa=PASS
upstream_port_invariants=PASS
```

## 관련 Notion 기록

- [wlan-driver-v2 — antcfg NSS 제한이 부팅·mcs_tier와 공존하도록 수정 (PR #20)](https://app.notion.com/p/3c08a230a04e814b9697f51cece2e0db)
- [NXP mlan NSS 제한 3경로 + 펌웨어·GET 함정](https://app.notion.com/p/3c08a230a04e812ba44ee839aa0b0cdb)

첫 기록은 GET이 `user_htstream`을 덮던 문제, VHT 저장값 clamp, driver/mlanutl
동시 갱신 필요성을 설명한다. 두 번째 기록은 physical antenna GET과 host
advertised NSS가 서로 다를 수 있고, association IE가 `user_htstream`을 따른다는
점을 명시한다.
