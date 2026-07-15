# moal mlan0 RX jitter — driver-v2 작업 준비 (앵커 검증 · Q1~Q5 · 착수점)

> **목적**: `moal-mlan0-rx-jitter-investigation.md`(wlan-package 인계)를 이 리포(wlan-driver-v2) 코드에 대고 **검증**하고, 실제 driver 수정에 바로 착수할 수 있게 **앵커 보정 + Q1~Q5 코드 답변 + 방향 A/B/C/D 착수점(ready patch 포함)** 을 정리한 실행 문서.
> **작성일**: 2026-07-15 · **선행 자료**: `moal-mlan0-rx-jitter-investigation.md`(증상/격리), `moal-mlan0-rx-drop-investigation.md`(RX 경로 공유)
> **검증 방식**: 8-agent workflow(앵커 3클러스터 + Q1~Q5)로 현재 트리 전수 대조.
> **동반 스크립트**: `moal-mlan0-rx-jitter.legtrace.bt`(bpftrace), `moal-mlan0-rx-jitter.legtrace.sh`(ftrace) — leg 특정용, 보드 실행.

---

## 0. TL;DR — 준비 완료 상태

- **인계 문서의 코드 앵커는 사실상 모두 유효**. 드리프트 2건만 보정 필요(§2): `moal_bridge_rx_fast` 정의 **392→515**, `apply_sched`는 이제 **param-driven**(고정 50 아님).
- **결정적 신규 발견(문서에 없음)**: SDIO에서 **NAPI와 rx_work는 상호 배타적**(`moal_main.c:13393` `!EXT_NAPI` 가드). 즉 방향 **B(threaded NAPI)와 C(rx_work RT)는 동시 적용 불가 — 택1**. 문서는 둘을 독립 레버로 취급했으나 실제론 하나의 스위치(napi on/off)가 가른다.
- **기본 config 상태(iMX93)**: `napi=0`(NAPI off) → RX deliver는 **`MOAL_RX_WORK_QUEUE` 워크큐**(멀티코어 auto-enable), RT 없음, RPS off. 즉 **현재 deliver leg = 비-RT kworker**.
- **⚑ 보드 실측으로 갱신됨(§8, 2026-07-15)**: pull IRQ(`irq/97-mmc2`)이 **이미 SCHED_FIFO:50** → **방향 A는 이미 적용 상태(레버 아님)**. deliver(MOAL 워크큐)만 **CFS** → **방향 C가 유일한 RT 레버**. 단 DUT 커널은 **kprobes/ftrace/tracefs 전무** → `legtrace.{bt,sh}` 실행 불가, leg 특정은 **in-driver 계측**(§8-C) 또는 커널 재빌드로만 가능.

---

## 1. 검증된 RX 경로 (현재 트리 라인)

```
[mlan0 RX] SDIO card IRQ
  └─ woal_sdio_interrupt            mlinux/moal_sdio_mmc.c:279   (in-band sdio_claim_irq 등록 @1600)
       ├─ mlan_interrupt            :313
       └─ mlan_main_process         :326  ── 동기 호출, 같은 IRQ/kthread 컨텍스트
            └─ SDIO 분기            mlan/mlan_shim.c:1209-1214
                 ├─ ops.process_int_status(=wlan_process_sdio_int_status)  mlan/mlan_sdio.c:2727   ← ① PULL
                 │    ├─ wlan_sdio_card_to_host          :2799  (cmd/event)
                 │    └─ wlan_sdio_card_to_host_mp_aggr  :2954  (bulk data)   ← 실제 card→host 읽기
                 └─ mlan_queue_rx_work                   mlan_shim.c:1214     ← 읽기 "후" deliver 예약
                      └─ DRV_DEFER_RX_WORK / woal_queue_rx_task
                         moal_shim.c:2874 / moal_main.c:6551
                          ├─ EXT_NAPI:  napi_schedule(&handle->napi_rx)        ← ② DELIVER (ksoftirqd)
                          │     └─ woal_netdev_poll_rx  moal_main.c:12387 → mlan_rx_process
                          └─ else(SDIO): queue_work(rx_workqueue, rx_work)     ← ② DELIVER (kworker)
                                └─ woal_rx_work_queue  moal_main.c:12640 → mlan_rx_process
```

**핵심**: ① PULL(card→host 실제 읽기)은 **`woal_sdio_interrupt`→`mlan_main_process` 동기 체인**에서 끝난다. `mlan_queue_rx_work`(:1214)는 **이미 읽은** RX를 ② DELIVER로 넘길 뿐. 인계 문서의 "pull은 IRQ 컨텍스트에서 끝, NAPI/rx_work는 deliver만 게이팅" 구조 **정확히 확인됨**.

> 부가(Q2): `woal_sdio_interrupt`는 하위 전송에서 `sdio_claim_host()`(sleeping mutex)를 잡으므로 **진짜 atomic hardirq일 수 없음** — sleepable/thread 컨텍스트(ksdioirqd 또는 호스트 threaded-IRQ)에서 돈다. 이게 방향 A(chrt)가 원리상 가능한 이유.

---

## 2. 앵커 드리프트 보정표

| 인계 문서 앵커 | 현재 라인 | 상태 | 비고 |
|---|---|---|---|
| `moal_sdio_mmc.c:326` mlan_main_process | **:326** | ✅ exact | woal_sdio_interrupt @279 |
| `mlan_shim.c:1209-1214` process_int_status→queue_rx_work | **:1212/:1214** | ✅ exact | |
| `mlan_sdio.c:2727` wlan_process_sdio_int_status | **:2727** | ✅ exact | c2h @2799, mp_aggr @2954 |
| `moal_shim.c:2874-2894` DEFER_RX_WORK 분기 | **:2874** | ✅ exact | napi @2877 / queue_work @2892 |
| `moal_main.c:6551-6557` woal_queue_rx_task | **:6551** | ✅ exact | |
| `moal_main.c:12387-12417` woal_netdev_poll_rx | **:12387** | ✅ exact | mlan_rx_process @12405 |
| `moal_main.c:13497-13508` NAPI init | **:13497** | ✅ exact | napi_enable @13507 |
| `moal_main.c:13399-13404` rx_workqueue alloc | **:13402** | ⚠ shifted | :13399는 <2.6.14 레거시명, alloc_workqueue는 :13402. 플래그 `WQ_HIGHPRI\|WQ_MEM_RECLAIM\|WQ_UNBOUND, 1` |
| `moal_main.c:2790-2795` EXT_NAPI 강제 | **:2790** | ✅ exact | rx_work=MTRUE, napi=MTRUE |
| `moal_main.c:13051` threaded(OOB) | **:13051** | ✅ exact | wifi_oob_wakeup, RX 무관 확인 |
| `moal_shim.c:2159` rx_fast (AMSDU) | **:2159** | ✅ exact | |
| `moal_shim.c:2310` rx_fast (single) | **:2310** | ✅ exact | |
| **`moal_bridge.c:392` moal_bridge_rx_fast 정의** | **:515** | ⚠ **shifted ~123줄** | 문서 ~392 stale, 정의는 515 |
| **`moal_bridge.c:176-216` apply_sched (FIFO:50)** | **:176-216** | ⚠ **semantics_changed** | FIFO 사용은 맞으나 **50 고정 아님 → `wq_sched_policy/prio` param 구동**(FIFO/RR & prio∈[1,99]만 honor, 아니면 `sched_set_fifo` fallback). "50"은 주석의 역사적 목표값 |

`dev_set_threaded` 전 트리 grep = **0 hit** → threaded NAPI 미사용 확인(문서 주장 유지). 방향 B는 신규 코드 필요.

---

## 3. Q1~Q5 코드 답변 (근거 라인 포함)

### Q1 — 어느 leg가 ~90ms인가 (코드만으론 불가, 보드 필요)
- 코드 근거상 **90ms는 DMA 지속시간이 아니라 스케줄링/wakeup 지연 시그니처**(card→host DMA·C-state exit는 90ms에 한참 못 미침).
- 특정 절차: 동반 스크립트 `legtrace.bt`(1순위) / `legtrace.sh`(대체). §5 참조. **이게 A vs B/C를 가르는 결정 게이트.**

### Q2 — i.MX93 SDIO가 threaded(ksdioirqd) vs NOTHREAD? (드라이버로는 불가, 보드 필요)
- **드라이버는 결정하지 않는다.** 기본 in-band `sdio_claim_irq(func, woal_sdio_interrupt)`(`moal_sdio_mmc.c:1600`)만 등록. `intmode` 기본 0(=INT_MODE_SDIO, `moal_init.c:53`)이라 EXT_INTMODE clear.
- `MMC_CAP2_SDIO_IRQ_NOTHREAD`/`host->caps2`는 드라이버 전역 grep **0 hit** → **호스트 컨트롤러(sdhci-esdhc-imx)+sdhci core+DTS 소관**. sdhci core는 보통 NOTHREAD를 set → **ksdioirqd가 없고 `irq/<N>-mmcX` threaded-IRQ가 pull을 서비싱**할 가능성이 큼.
- `intmode=1`(OOB)이면 pull이 드라이버 소유 `SDIO_OOB_IRQ_WORKQ` kworker에서 돎 → **chrt로 깔끔히 못 잡음**(방향 A 부적용).
- **보드 확인**: `cat /sys/module/moal/parameters/intmode` → `ps -eLo pid,cls,rtprio,comm | grep -E 'ksdioirqd|irq/.*mmc'` → 그 대상이 A의 chrt 타깃.

### Q3 — pcap keep-warm 기전 (분석)
- 최유력 (a): pcap의 RT 드레이너가 **CPU를 deep-idle에서 빼고 cpufreq를 올려둔** 상태 → SDIO IRQ 발생 시 pull thread(ksdioirqd/irq-mmc)의 **wakeup→run 지연이 붕괴**. (드레이너는 소켓 큐를 비울 뿐 SDIO를 직접 읽지 않음.)
- (b) "잦은 SDIO 읽기로 pull cadence 유지" = **코드상 거짓**(card→host는 카드 IRQ가 트리거, userspace 읽기와 무관).
- (c) RT 선점 = 실질적으로 (a)로 환원(실제 pull/deliver는 CFS).
- **함의**: 방향 A(pull thread RT)는 **90ms가 스케줄링 지연일 때만** pcap 이점을 재현. DMA 지속시간이면 무효 → Q1 먼저.

### Q4 — RX 서비싱을 SCHED_FIFO로 만드는 파라미터? (코드 확답: 현재는 안 닿음)
- `wq_sched_policy`/`wq_sched_prio`(기본 0/SCHED_NORMAL, `moal_init.c:255-257`, `module_param` :3150) 존재. 적용처는 **3곳뿐**: `woal_main_work_queue`(main, :12984-13005), `woal_tx_work_handler`(tx, :12905-12928), `moal_bridge_apply_sched`(bridge w2p/p2w).
- **`woal_rx_work_queue`(:12640, RX deliver)에는 적용 코드 자체가 없음** → RX deliver는 기본 CFS. **방향 C = 여기에 apply 블록 추가**(§4-C ready patch).

### Q5 — RX 관련 모듈 파라미터 인벤토리 & 기본값 (엔진 독립)
| param | 기본 | 의미 | 엔진 독립 |
|---|---|---|---|
| `rx_work` | 0=auto | auto=멀티코어면 rx_workqueue enable. deliver 예약만, pull 무관 | ✅ load-time |
| `napi`(EXT_NAPI) | 0=off | 1→deliver를 napi_schedule로. **rx_workqueue와 배타** | ✅ |
| `wq_sched_policy` | 0=NORMAL | main/tx/bridge kthread 정책(1=FIFO,2=RR,…) | ✅ |
| `wq_sched_prio` | 0 | 위와 페어(FIFO/RR일 때 유효) | ✅ |
| `rps` | 0=off | RX CPU 스티어링 비트마스크(runtime 0660) | ✅ |
- **모두 driver load-time param → wbridge 엔진(pcap/tpacket/moal) 선택과 무관.**
- iMX93 기본 net RX 경로: **pull=IRQ 컨텍스트(불변) → deliver=rx_workqueue(멀티코어 auto), NAPI 없음, RT 없음, RPS 없음.**
- `wq_sched_policy`≠0이면 bridge_mode 시 w2p/p2w kthread까지 추가로 닿음(그 외 결합 없음).

---

## 4. 방향별 착수점 (config-first, 위→아래 cheapest-first)

### A — `ksdioirqd`(또는 `irq/<N>-mmcX`)를 SCHED_FIFO로 · **코드 0, 보드 config**
- **전제**: Q1이 "pull 스케줄링 지연" 판정 + Q2에서 chrt 대상 스레드 존재.
- 절차(보드):
  ```sh
  cat /sys/module/moal/parameters/intmode          # 0 in-band(가능) / 1 OOB(부적용)
  ps -eLo pid,cls,rtprio,comm | grep -E 'ksdioirqd|irq/.*mmc'
  chrt -f -p 50 <PID>                               # 대상 pull thread를 FIFO
  # deliver도 의심되면: (non-NAPI) chrt -f -p 45 $(pgrep -f MOAL_RX_WORK)
  #                    (NAPI)     chrt -f -p 45 $(pgrep ksoftirqd)   # 주의: ksoftirqd 전역 영향
  ```
- **리스크 낮음**. 단 지속화(재부팅 후 유지)는 udev/rc/systemd로. **이 리포 변경 아님**(운영 config).

### C — rx_work 워커를 `wq_sched_*`로 RT화 · **코드(작음), 저리스크** ★deliver leg 대응 1순위
현재 `woal_rx_work_queue`에 없는 sched 적용을, 이미 검증된 main_work 블록을 그대로 복사해 추가. **NAPI off(기본) SDIO 경로에만 유효.**

- 대상: `mlinux/moal_main.c:12640 woal_rx_work_queue`
- (1) 지역변수: `wifi_timeval end_timeval;`(:12644) 아래에 삽입
  ```c
  #if LINUX_VERSION_CODE > KERNEL_VERSION(2, 6, 10) &&                           \
      LINUX_VERSION_CODE <= KERNEL_VERSION(5, 8, 18)
      struct sched_param sp;
  #elif LINUX_VERSION_CODE > KERNEL_VERSION(5, 13, 19)
      struct sched_attr attr;
  #endif
  ```
- (2) apply 블록: `woal_get_monotonic_time(&start_timeval);`(:12659) **직전**에 삽입 (main_work :12984-13005 verbatim, 로그 문자열만 교체)
  ```c
  if ((handle->params.wq_sched_prio != current->rt_priority) ||
      (handle->params.wq_sched_policy != current->policy)) {
  #if LINUX_VERSION_CODE > KERNEL_VERSION(2, 6, 10) &&                           \
      LINUX_VERSION_CODE <= KERNEL_VERSION(5, 8, 18)
      PRINTM(MMSG, "Set rx work queue priority %d and scheduling policy %d\n",
             handle->params.wq_sched_prio, handle->params.wq_sched_policy);
      sp.sched_priority = handle->params.wq_sched_prio;
      sched_setscheduler(current, handle->params.wq_sched_policy, &sp);
  #elif LINUX_VERSION_CODE > KERNEL_VERSION(5, 13, 19)
      PRINTM(MMSG, "Set rx work queue priority %d and scheduling policy %d\n",
             handle->params.wq_sched_prio, handle->params.wq_sched_policy);
      attr.sched_policy = handle->params.wq_sched_policy;
      attr.sched_nice = DEF_NICE;
      attr.sched_priority = handle->params.wq_sched_prio;
      sched_setattr_nocheck(current, &attr);
  #endif
  }
  ```
- 효과: `wq_sched_policy=1 wq_sched_prio=50` 한 번으로 **main_work(pull이 워크큐로 돌 때)+rx_work(deliver)** 동시 RT화. idempotency 가드라 워커당 1회만 발동.
- **주의**: (i) rx_workqueue는 `!EXT_NAPI`에서만 생성(:13393) → NAPI on이면 무효. (ii) IRQ 컨텍스트 pull(ksdioirqd) 자체는 `wq_sched_*` 밖 → C는 deliver만 올림. (iii) 선택적 리팩터: 3곳(main/tx/rx) 중복 블록을 `woal_apply_wq_sched(handle)` 헬퍼로 추출 가능(최소 패치는 위 verbatim).

### B — EXT_NAPI + threaded NAPI + napi kthread RT · **코드(중), deliver 전용** (C와 택1)
NAPI를 켜고(napi=1) threaded로 만들어 **전용 kthread**를 RT화. dummy netdev라 외부 chrt 타깃이 애매하니(빈 이름) **in-driver로 `napi_rx.thread`를 직접 RT** 하는 게 견고.

- 대상: `mlinux/moal_main.c:13507 napi_enable(&handle->napi_rx);` **직후**
  ```c
      napi_enable(&handle->napi_rx);
  #if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)
      /* RX deliver leg를 전용 kthread로 돌려 SCHED_FIFO 고정 (pcap 등가 RT 서비싱).
       * dummy netdev라 sysfs /threaded 노브·외부 chrt 타깃이 없으므로 in-driver로 승격. */
      if (!dev_set_threaded(&handle->napi_dev, true) && handle->napi_rx.thread)
          sched_set_fifo(handle->napi_rx.thread);
  #endif
  ```
- 근거: `sched_set_fifo`는 이미 `moal_bridge.c:184`에서 사용(가용). threaded NAPI의 `napi_struct.thread`는 5.12+ 필드(트리 타깃 6.6.x OK).
- **빌드 전 확인(보드 커널 헤더)**: ① `napi_struct.thread` 필드 존재, ② `dev_set_threaded` 시그니처/반환(0=성공), ③ dummy netdev에서 `dev_set_threaded`가 napi_enable **후** 호출로 kthread를 실제 생성하는지(순서 이슈면 netif_napi_add 직후로 이동). 안 되면 fallback: 외부 `chrt`로 `napi/<id>` 스레드 타깃.
- **주의**: napi=1이면 rx_workqueue 미생성 → **C와 동시 불가**. B는 pull leg 무관(deliver만).

### D — 전용 SCHED_FIFO RX 서비싱 kthread · **코드(큼), 최후 카드**
- A/B/C로 부족할 때. `moal_bridge_apply_sched`(:176-216) FIFO 패턴 재사용해 pcap RT 드레이너를 드라이버 내부에 재현(IRQ-wait 또는 busy-poll). 설계에 따라 ①/② 모두 커버 가능하나 기아·복잡도 리스크 높음.

---

## 5. leg 특정 절차 (실행 게이트)

1. 대상 스레드 파악: `ps -eLo pid,cls,rtprio,comm | grep -E 'ksdioirqd|irq/.*mmc|MOAL_RX|ksoftirqd'`, `cat /sys/module/moal/parameters/{intmode,napi}`
2. peer flood: `ping -D -i 0.1 -c 300 <DUT_IP>` (-D 타임스탬프로 RTT 스파이크↔트레이스 정렬)
3. DUT에서 트레이스:
   - 1순위 `bpftrace docs/moal-mlan0-rx-jitter.legtrace.bt` (ksdioirqd comm은 실제 mmc 인덱스로 수정)
   - 대체 `sh docs/moal-mlan0-rx-jitter.legtrace.sh start` … flood … `stop` → `/tmp/rx-fg.txt`
4. 판정: **~90ms 꼬리를 가진 히스토그램/갭이 leg를 지목**
   - `@c2h_*_dma_us` 꼬리 → PULL DMA/버스(방향 A·B·C 모두 무효, HW/버스 이슈)
   - `@rqlat_pull_us` / `@pull_total_us` 꼬리 → **PULL 스케줄링 → 방향 A**
   - `@deliver_napi_us` / `@deliver_wq_us` 꼬리 → **DELIVER 스케줄링 → 방향 C(기본) 또는 B(napi 채택 시)**

**A/B 하니스(합격 기준)**: OHT(`192.168.214.6`)→`ping -c40 -i0.2 -W2 192.168.0.21`, cts(`0.100`)→`ping ... 192.168.0.11`. 지표 `>10ms개수/max/mdev`, **목표 pcap 패리티(0/40, max<8ms)**. config/모듈 변경은 재부팅.

---

## 6. 미결 / 보드 확인 요망

| ID | 항목 | 게이트 |
|---|---|---|
| Q1 | ~90ms가 pull vs deliver 중 어디 | §5 legtrace — **모든 방향 선택의 선행 게이트** |
| Q2 | intmode 실제값 + ksdioirqd 존재 여부(vs irq/N-mmcX vs OOB kworker) | 방향 A 적용성/타깃 결정 |
| B-1 | 커널 헤더: `napi_struct.thread`, `dev_set_threaded` 시그니처, dummy netdev 생성 순서 | 방향 B 패치 빌드 |
| A-2 | ksdioirqd-RT 후 잔여 꼬리 시 cpuidle/PM-QoS(`cpu_dma_latency`) 영향 | (인계 문서상 deep-idle은 이 보드서 반증됨 — 후순위) |

---

## 7. 착수 즉시 실행 순서 (요약)

1. **보드**: intmode/napi 확인 → `legtrace`로 leg 특정 (§5).
2. **pull 스케줄링**이면 → **방향 A** (`chrt` 대상 확정 후 A/B 하니스로 pcap 패리티 검증). 코드 변경 없음.
3. **deliver 스케줄링**이면 → **방향 C ready patch**(§4-C) 적용 → `make_for_imx93.sh` 빌드 → `insmod ... wq_sched_policy=1 wq_sched_prio=50` → 하니스 검증. (NAPI 채택 노선이면 대신 **B**.)
4. A/C(또는 B) 부족 시 → **A+C 병행**(pull+deliver 양쪽 RT) → 그래도 부족 시 **D**.
5. 결과는 `moal-mlan0-rx-jitter-investigation.md` §5 판정 기준으로 기록.

---

## 8. 보드 실측 결과 (2026-07-15) — 접근성 · Q2 확정 · 트레이싱 제약

실 DUT에 접속해 §3·§6의 미결을 상당수 확정. **§4·§5의 방향 우선순위가 실측으로 재정렬됨.**

### 8-0. 접근 경로 (재현 가능)
- `ssh-mcp` = **pim-camera-v016**(`192.168.214.4` 관리 / `eth1 192.168.0.21` = 데이터경로 "서버 0.21"). moal 미로드(=wifi DUT 아님).
- **wifi DUT = `cts-wlan`** = `root@192.168.0.100`. pim-camera의 eth1(0.21/24)과 **동일 서브넷** → **2-hop passwordless** 도달:
  ```
  (ssh-mcp)pim-camera:0.21  ──eth1──  ssh root@192.168.0.100 → cts-wlan
  ```
  ssh-mcp exec에서 `ssh -o BatchMode=yes root@192.168.0.100 '<cmd>'` 로 그대로 실행됨(키 인증, 무암호).
- DUT: `cts-wlan`, kernel **6.6.3-lts-next**(dirty), aarch64. moal(892928)+mlan(593920) 로드, `srcversion=AFFC67A300D3A67AAF3B62C`. mlan0 **5180MHz 연결 정상**(AP 00:80:4c:c7:7d:dd, SSID jhw_wlan_).

### 8-A. Q2 완전 확정 — pull은 이미 RT, 방향 A는 레버 아님
- wifi SDIO = **mmc2**(`428b0000.mmc`, SDIO func 1/2 = `mmc2:0001:1/2`). IRQ 97(GICv3 237).
- **pull IRQ 스레드 = `irq/97-mmc2`, 스케줄 클래스 `FF`(SCHED_FIFO) rtprio `50`.** (mmc0=`irq/19-mmc0`도 FIFO:50, wifi 아님.)
- 즉 호스트가 **`MMC_CAP2_SDIO_IRQ_NOTHREAD`**(ksdioirqd 없음) → SDIO 카드 IRQ = sdhci threaded-IRQ `irq/97-mmc2`에서 서비싱, **woal_sdio_interrupt→mlan_main_process(pull)이 여기서 FIFO:50로 실행됨**.
- **결론: 방향 A("pull thread를 RT로")는 이미 시스템 상태 = 추가 이득 없음.** (문서/§4-A의 chrt 전제는 이 보드에서 무의미.)

### 8-B. 남은 비-RT leg = deliver → 방향 C가 유일 레버
- ps 실측(현재 pcap 모드): `kworker/u5:*-MOAL_WORK_QUEUE`(main) = **TS(CFS)**, `kworker/R-MOAL_*`(rescuer). deliver 워커(MOAL_RX_WORK_QUEUE)도 동일 CFS 풀. `wq_sched_*` 기본 0이라 RT 아님(§Q4/Q5 확인과 일치).
- pcap 드레이너 `wifi-wbridge` = **FIFO:45**(pull IRQ:50 아래) — pcap 일관성의 실체가 "RT deliver".
- **∴ moal 등가 = deliver 워커를 RT화(방향 C).** 우선순위 가이드: **pull IRQ(50)보다 낮게, pcap과 동일 계열인 FIFO 45 권장**(`wq_sched_policy=1 wq_sched_prio=45`). ⚠ `wq_sched_*`는 main/bridge kthread에도 동시 적용 — 현재 bridge w2p/p2w는 `sched_set_fifo`=FIFO:50인데 prio=45로 내려감(honor 분기). 이 상호작용은 구현 시 측정으로 확정(50 유지가 필요하면 C를 rx_work 전용 상수로 분리).

### 8-C. 트레이싱 하드 제약 → leg 특정은 in-driver 계측으로
- DUT 커널: **`# CONFIG_KPROBES is not set`**, `mount -t tracefs` **실패**("unknown filesystem type 'tracefs'"), `perf probe` 불가(kprobe_events 없음). → **bpftrace·ftrace function_graph·perf probe 전부 불가.** `perf`(6.6.3)는 PMU 샘플링만(거친 통계, per-packet leg-gap 측정 불가).
- `legtrace.{bt,sh}`는 **이 커널에선 미동작** — 커널을 CONFIG_KPROBES+KPROBE_EVENTS+FTRACE+FUNCTION_GRAPH_TRACER+TRACEFS로 재빌드해야 사용 가능(무겁다). 스크립트는 재빌드/타보드용으로 보존.
- **✅ 구현됨(2026-07-15): in-driver deliver-leg 계측** (bridge dwell과 동일 패턴, `bridge_debug` 게이트, 빌드 클린). deliver 갭이 핵심 지표.
  - **② handoff→deliver 갭**: rx_work enqueue 시각(`handle->rx_enqueue_ns`, `ktime_get_ns()`, not-pending→pending 전이에서만 기록) → `woal_rx_work_queue` 진입 시각 델타 = **deliver 큐→런 지연**. cnt/sum/max 누적(`rx_gap_*`). enqueue 캡처=`woal_queue_rx_task`(moal_main.c)+DEFER_RX_WORK(moal_shim.c), 계상=`woal_rx_work_queue`.
  - **deliver 처리시간**: `mlan_rx_process` 지속시간 max(`rx_dur_max_us`) — "늦게 실행(gap)" vs "실행이 김(duration)" 구분.
  - **① pull 지속**: 미구현(pull IRQ 이미 FIFO:50이라 후순위). deliver가 결백으로 판명되면 `woal_sdio_interrupt` 델타 추가.
  - **노출**: `/sys/kernel/moal_bridge/stats` (bridge sysfs kobject 확장, `moal_bridge.c:stats_show`) 마지막 줄 `rx_deliver gap_avg=..us gap_max=..us n=.. dur_max=..us`.
  - **판독**: 보드에서 `echo 1 > /sys/module/moal/parameters/bridge_debug` → 부하(ping flood) → `cat /sys/kernel/moal_bridge/stats`. **`gap_max` ~90ms → deliver 스케줄링 지연 확정(방향 C가 정답)**; `gap_max` 작고 `dur_max`도 작은데 jitter면 → pull leg(①계측 추가).
  - **⚠ 2단계 측정(순서 중요)**: 계측은 워커의 *현재 스케줄 상태*를 잴 뿐이고, 방향 C(RT-raise)가 같은 워커에 있으므로 순서가 결과를 가른다. **①baseline**: `wq_sched_policy=0`(기본, 워커 CFS)로 로드 → `gap_max` 측정(여기서 ~90ms가 나와야 deliver leg 확정). **②fix**: `wq_sched_policy=1 wq_sched_prio=45`로 로드(워커 FIFO:45) → `gap_max` 붕괴 확인. baseline을 fix보다 **먼저** 안 재면 이미 고쳐진 상태를 재게 됨. gap 샘플은 `RX_GAP_CEIL_US`(1s) 상한으로 bridge_debug 토글/유휴 아티팩트를 배제.
  - **배포**: `make_for_imx93.sh`(완료) → DUT로 `moal_imx93.ko` rsync(과거 세션: `root@192.168.0.101` `rsync_driver.sh`, IP 일치 확인 요망) → 리로드 시 리부팅(모듈이 bridge에 물림, `wlan_emergency_reboot`).

### 8-D. 운영 상태 · 재현 절차 주의
- **현재 engine=pcap**(`/usr/local/etc/wifi_init_conf.json` `"engine":"pcap"`) + 연결 정상. **moal jitter는 지금 재현 불가** — engine=moal 전환(백업 `wifi_init_conf.json.bak.moal` 복원) + **리부팅** + AP 재연결 필요.
- ⚠ **engine 전환·리부팅·드라이버 리로드는 동작 중인 보드를 순단**시키므로 **사용자 승인 후 실행**. 관리망(pim-camera 214.4/0.21)에서 하면 mlan0 순단과 무관하게 세션 유지 가능.

---

---

## 9. 결론 (2026-07-15) — 근본원인 규명 + fix 실기 실증 ✅

실보드(cts-wlan, engine=moal, **napi ON**) in-driver 계측으로 leg 정량 특정 완료. **커널 트레이싱(kprobes/ftrace) 없이 순수 드라이버 계측으로 규명·해결.**

### 9-1. 근본 원인 (확정)
이 보드 moal은 **napi=ON**이라 RX deliver leg = `woal_netdev_poll_rx`가 **ksoftirqd(SCHED_OTHER/CFS)** 에서 실행된다. sparse/idle 트래픽에서 `napi_schedule` 후 **poll이 최대 ~80ms 늦게 디스패치**되는 것이 jitter의 정체. (Q5의 "napi 기본 0" 가정과 달리 실보드는 napi=1 — §8-A 참조.)

계측으로 각 leg 격리(동일 sparse bridged 부하 dev→OHT 0.220):

| leg | 계측 앵커 | baseline max | 판정 |
|---|---|---|---|
| **② deliver gap** (napi_schedule→poll) | `woal_netdev_poll_rx` | **79.9 ms** | **★범인** |
| ① pull (SDIO IRQ 처리) | `woal_sdio_interrupt` entry→exit | 1.4 ms | 결백 |
| TX write (SDIO write) | `woal_sdiommc_write_data_sync` | 0.5 ms | 결백 |
| deliver duration / bridge dwell | — | 0.09 / 0.2 ms | 결백 |

(주의: jitter는 intermittent — 창에 따라 이벤트를 놓치면 gap이 작게 나옴. 강한 재현 창에서 gap_max=79.9ms가 RTT max 82ms를 그대로 설명.)

### 9-2. 해결 = Direction B (실증)
`woal_netdev_poll_rx`가 도는 NAPI를 **전용 kthread로 threaded화 + RT 고정**:
- `napi_enable` 뒤 `wq_sched_policy`가 FIFO/RR이면 `dev_set_threaded(&handle->napi_dev, true)` + `sched_setattr_nocheck(handle->napi_rx.thread, {policy, prio})`. **dummy netdev라 sysfs `/threaded`·외부 chrt 타깃이 없어 in-driver로 승격**(문서가 우려한 "chrt targeting 곤란" 회피).
- 게이트: `wq_sched_policy=1 wq_sched_prio=45` (pull IRQ FIFO:50 아래). moal_init.c가 module_param 또는 conf로 수용.

**실측 (baseline → fix, 동일 부하):**

| 지표 | baseline (napi=ksoftirqd) | **fix (Direction B, napi=FIFO:45)** |
|---|---:|---:|
| deliver gap_max | 79,902 µs | **32 µs** (~2500×↓) |
| RTT max | 82 ms | **9.3 ms** (outlier 0) |

→ **RTT 82ms→9.3ms, pcap 패리티(~7ms) 근접.** `napi/-259`=FF:45, dmesg `Direction B: threaded NAPI RT policy 1 prio 45` 확인.

### 9-3. 남은 일 (프로덕션화)
- **wq_sched 정식 주입경로**: 실측 테스트는 `wifi_init.sh`에 moal insmod args(`wq_sched_policy=1 wq_sched_prio=45`) capability-gate 삽입(백업 `wifi_init.sh.bak.rxj`). conf 활성 SD9098 블록 없음 → insmod args 경로가 확실. 정식 배포 시 wifi_init_conf.json 노브화 또는 conf SD9098 블록 추가 검토.
- **부작용 주의**: `wq_sched_policy=1`은 main_work/tx_work/bridge kthread도 FIFO:45로 올림(deliver와 동일 계층). pull IRQ(50) 아래라 순서는 정상.
- **계측 상시성**: gap/pull/tx 계측은 `bridge_debug` 게이트(기본 off, 오버헤드 READ_ONCE 1회)라 상시 탑재 가능.

_조사 완결: 근본원인=NAPI deliver 디스패치 지연(ksoftirqd), 해결=Direction B(threaded NAPI RT). 커널 트레이싱 없이 in-driver 계측으로 규명·실증._
