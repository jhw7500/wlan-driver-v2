#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# Execute production functions with host-only kernel boundaries.
review_host_regressions() {
python3 - "$ROOT" "${1:-all}" <<'PY_REVIEW'
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
selected = sys.argv[2]

def function(path, name):
    source = (root / path).read_text()
    match = re.search(r"(?m)^(?:static )?(?:int|void|t_void|mlan_status|wifi_rtt_config\s*\*)\s*" + name + r"\([^;]*?\)\s*\{", source)
    if not match:
        raise RuntimeError("production function not found: " + name)
    masked = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
                    lambda m: " " * len(m.group()), source, flags=re.S)
    depth = 0
    for end in range(source.index("{", match.start()), len(source)):
        if masked[end] == "{": depth += 1
        if masked[end] == "}":
            depth -= 1
            if not depth: return source[match.start():end + 1] + "\n"
    raise RuntimeError("unterminated production function: " + name)

common = r'''#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mlan.h"
#include "mlan_util.h"
#include "mlan_join.h"
#include "mlan_fw.h"
#include "mlan_main.h"
#undef ENTER
#undef LEAVE
#undef PRINTM
#undef memset
#undef memcpy
#undef memcmp
#define ENTER() ((void)0)
#define LEAVE() ((void)0)
#define PRINTM(...) ((void)0)
#define KERNEL_VERSION(a,b,c) (((a)<<16)|((b)<<8)|(c))
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define IS_ERR(p) ((uintptr_t)(p) >= (uintptr_t)-4095)
#define IS_ERR_OR_NULL(p) (!(p) || IS_ERR(p))
#define PTR_ERR(p) ((long)(p))
#define ERR_PTR(e) ((void *)(intptr_t)(e))
static int failures, checks;
static void check(int ok,const char *name) {
    checks++; if (!ok) { fprintf(stderr,"FAIL review-host: %s\n",name); failures++; }
}
'''

thermal = r'''
typedef struct { void *thermal_priv; } moal_handle;
struct thermal_zone_device { void *devdata; bool active; };
struct woal_thermal_priv { struct thermal_zone_device *tz_dev; moal_handle *handle; };
static int live_zones,live_allocations,alloc_fail,register_fail,registrations;
static struct thermal_zone_device zones[32];
static int woal_thermal_zone_ops;
static int woal_thermal_trips[2];
#define WOAL_THERMAL_NUM_TRIPS 2
#define GFP_KERNEL 0
static void *kzalloc(size_t size,int flags) {
    if (alloc_fail) return NULL;
    void *p=calloc(1,size); if (p) live_allocations++; return p;
}
static void kfree(void *p) { if (p) { live_allocations--; free(p); } }
static struct thermal_zone_device *register_zone(void *data) {
    if (register_fail) return ERR_PTR(-EIO);
    assert(registrations<32);
    struct thermal_zone_device *tz=&zones[registrations++];
    tz->active=true; tz->devdata=data; live_zones++; return tz;
}
#if LINUX_VERSION_CODE < KERNEL_VERSION(6,0,0)
static struct thermal_zone_device *thermal_zone_device_register(const char *name,
    int count,int mask,void *data,void *ops,void *params,int passive,int poll) { return register_zone(data); }
#elif LINUX_VERSION_CODE < KERNEL_VERSION(6,12,0)
static struct thermal_zone_device *thermal_zone_device_register_with_trips(const char *name,
    void *trips,int count,int mask,void *data,void *ops,void *params,int passive,int poll) { return register_zone(data); }
#else
static struct thermal_zone_device *thermal_zone_device_register_with_trips(const char *name,
    void *trips,int count,void *data,void *ops,void *params,int passive,int poll) { return register_zone(data); }
#endif
static void thermal_zone_device_unregister(struct thermal_zone_device *tz) {
    assert(tz->active); tz->active=false; tz->devdata=NULL; live_zones--;
}
'''
thermal += function("mlinux/moal_thermal.c","woal_thermal_register")
thermal += function("mlinux/moal_thermal.c","woal_thermal_unregister")
thermal += r'''
int main(void) {
    moal_handle h={0};
    check(!woal_thermal_register(&h),"initial thermal registration succeeds");
    void *owner=h.thermal_priv;
    for (int bus=0;bus<2;bus++) for (int reset=0;reset<4;reset++) {
        check(!woal_thermal_register(&h),"FLR reinitialization succeeds");
        check(h.thermal_priv==owner && live_zones==1 && live_allocations==1,
              "repeated PCIe/SDIO reinitialization keeps one thermal owner");
    }
    alloc_fail=1;
    check(!woal_thermal_register(&h) && h.thermal_priv==owner,"existing zone survives allocation pressure");
    alloc_fail=0; woal_thermal_unregister(&h);
    check(!h.thermal_priv && !live_zones && !live_allocations,"removal leaves no zone or private allocation");
    woal_thermal_unregister(&h);
    check(!live_zones && !live_allocations,"repeated removal is harmless");
    alloc_fail=1;
    check(woal_thermal_register(&h)==-ENOMEM && !h.thermal_priv,"allocation failure publishes no owner");
    alloc_fail=0; register_fail=1;
    check(woal_thermal_register(&h)==-EIO && !h.thermal_priv && !live_allocations,"API failure unwinds allocation");
    register_fail=0;
    check(!woal_thermal_register(&h) && live_zones==1,"registration retries after failure");
    woal_thermal_unregister(&h);
    check(!live_zones && !live_allocations,"retried registration drains on removal");
    printf("thermal checks=%d failures=%d\n",checks,failures); return failures?1:0;
}
'''

dfs = r'''
#define UAP_CFG80211 1
#define CFG80211_VERSION_CODE KERNEL_VERSION(6,6,3)
#define IS_UAP_CFG80211(v) ((v)!=0)
typedef struct { struct { int cfg80211_wext; } params; } moal_handle;
typedef struct { moal_handle *phandle; } moal_private;
struct net_device { moal_private *priv; }; struct ifreq { void *ifr_data; };
'''
header=(root/"mlinux/moal_uap.h").read_text()
dfs += header[header.index("typedef struct _skip_cac_para"):header.index("} skip_cac_para;")+len("} skip_cac_para;")]
dfs += r'''
static unsigned gets,sets,updates,bad;
static t_u8 channels[8],expected[8]; static int user_copy_error;
static void *netdev_priv(struct net_device *d) { return d->priv; }
static int copy_from_user(void *dst,const void *src,size_t size) {
    if (user_copy_error) return 1;
    memcpy(dst,src,size); return 0;
}
static int woal_11h_chan_dfs_state(moal_private *p,int action,mlan_ds_11h_chan_dfs_state *s) {
    if (action==MLAN_ACT_GET) { if (gets<8) channels[gets]=s->channel; gets++; s->dfs_state=DFS_USABLE; }
    else { unsigned i=sets++; if (i>=8 || s->channel!=expected[i] || s->dfs_state!=DFS_AVAILABLE) bad++; }
    return 0;
}
static void woal_update_channel_dfs_state(t_u8 channel,t_u8 state) {
    unsigned i=updates++; if (i>=8 || channel!=expected[i] || state!=DFS_AVAILABLE) bad++;
}
'''
dfs += function("mlinux/moal_uap.c","woal_uap_get_dfs_chan")
dfs += function("mlinux/moal_uap.c","woal_uap_skip_cac")
dfs += r'''
int main(void) {
    moal_handle h={.params={.cfg80211_wext=1}}; moal_private p={&h};
    struct net_device dev={&p}; skip_cac_para param={0}; struct ifreq req={&param};
    const t_u8 groups[2][8]={{36,40,44,48,52,56,60,64},{100,104,108,112,116,120,124,128}};
    param.skip_cac=1; param.bw=CHAN_BW_160MHZ;
    for (unsigned group=0;group<2;group++) for (unsigned primary=0;primary<8;primary++) {
        memcpy(expected,groups[group],8); param.channel=groups[group][primary];
        gets=sets=updates=bad=0; memset(channels,0,sizeof(channels));
        check(!woal_uap_skip_cac(&dev,&req),"160 MHz skip-CAC caller succeeds");
        check(gets==8 && sets==8 && updates==8 && !bad && !memcmp(channels,expected,8),
              "both 160 MHz groups process all eight channel states");
    }
    req.ifr_data=NULL;
    check(woal_uap_skip_cac(&dev,&req)==-EFAULT,"NULL user pointer rejected");
    req.ifr_data=&param; user_copy_error=1;
    check(woal_uap_skip_cac(&dev,&req)==-EFAULT,"user-copy failure rejected");
    printf("dfs checks=%d failures=%d\n",checks,failures); return failures?1:0;
}
'''

sensor = function("mlan/mlan_cmdevt.c","wlan_ret_get_sensor_temp")
sensor += r'''
int main(void) {
    mlan_private priv={0}; HostCmd_DS_COMMAND resp={0};
    mlan_ds_misc_cfg cfg; mlan_ioctl_req req={0}; req.pbuf=(t_u8 *)&cfg;
    const t_s32 values[5]={42,-7,18,29,60};
    resp.params.temp_sensor.cau_temperature=wlan_cpu_to_le32(values[0]);
    for (int i=0;i<4;i++) resp.params.temp_sensor.rfu_temperature[i/2][i%2]=wlan_cpu_to_le32(values[i+1]);
    for (unsigned count=1;count<=5;count++) {
        memset(&cfg,0xa5,sizeof(cfg)); resp.size=S_DS_GEN+count*4;
        check(wlan_ret_get_sensor_temp(&priv,&resp,&req)==MLAN_STATUS_SUCCESS,"CAU-only through full responses accepted");
        check(cfg.param.sensor_temp.cau_temperature==values[0],"CAU converted");
        for (unsigned i=0;i<4;i++) check(cfg.param.sensor_temp.rfu_temperature[i/2][i%2]==(i+1<count?values[i+1]:0),
              "only declared RFU values copied and absent values cleared");
    }
    for (unsigned size=0;size<S_DS_GEN+20;size++) {
        if (size>=S_DS_GEN+4 && (size-S_DS_GEN)%4==0) continue;
        memset(&cfg,0xa5,sizeof(cfg)); mlan_ds_sensor_temp before=cfg.param.sensor_temp;
        resp.size=size; req.status_code=0;
        check(wlan_ret_get_sensor_temp(&priv,&resp,&req)==MLAN_STATUS_FAILURE,"short header, missing CAU or partial element rejected");
        check(req.status_code==MLAN_ERROR_FW_CMDRESP && !memcmp(&before,&cfg.param.sensor_temp,sizeof(before)),
              "malformed response reports error without partial publication");
    }
    resp.size=S_DS_GEN+4;
    check(wlan_ret_get_sensor_temp(&priv,&resp,NULL)==MLAN_STATUS_SUCCESS,"valid ownerless response");
    resp.size=S_DS_GEN+3;
    check(wlan_ret_get_sensor_temp(&priv,&resp,NULL)==MLAN_STATUS_FAILURE,"malformed ownerless response rejected");
    printf("sensor checks=%d failures=%d\n",checks,failures); return failures?1:0;
}
'''

keep = r'''
typedef struct { int keep_connect; unsigned bss_index; } moal_private;
static mlan_status woal_atoi(int *out,char *s) { *out=(int)strtol(s,NULL,10); return MLAN_STATUS_SUCCESS; }
static int woal_atox(char *s) { return (int)strtol(s,NULL,16); }
'''
keep += function("mlinux/moal_eth_ioctl.c","parse_arguments")
keep += function("mlinux/moal_eth_ioctl.c","woal_priv_keep_connect")
keep += r'''
int main(void) {
    moal_private p={.keep_connect=1};
    const char *invalid[]={"","2","-1","0 1"};
    for (unsigned i=0;i<ARRAY_SIZE(invalid);i++) {
        char input[16]; strcpy(input,invalid[i]);
        check(woal_priv_keep_connect(&p,(t_u8 *)input,strlen(input))==-EINVAL,"invalid KEEP_CONNECT arguments return EINVAL");
        check(p.keep_connect==1,"invalid KEEP_CONNECT preserves previous state");
    }
    char off[]="0",on[]="1";
    check(!woal_priv_keep_connect(&p,(t_u8 *)off,1) && !p.keep_connect,"valid disable succeeds");
    check(!woal_priv_keep_connect(&p,(t_u8 *)on,1) && p.keep_connect,"valid enable succeeds");
    printf("keep-connect checks=%d failures=%d\n",checks,failures); return failures?1:0;
}
'''

gpio = r'''
struct device_node { int unused; }; struct gpio_desc { int unused; };
typedef struct { void *ind_rst_gpiod; } moal_handle;
static struct device_node node; static struct gpio_desc descriptor;
static int node_missing,invalid_gpio,descriptor_null,acquire_fail,direction_fail;
static int owned,put_count,bad_puts,node_puts;
#define GPIOD_OUT_HIGH 1
static struct device_node *of_find_compatible_node(void *a,void *b,const char *name) { return node_missing?NULL:&node; }
static void of_node_put(struct device_node *n) { node_puts++; }
static void *of_fwnode_handle(struct device_node *n) { return n; }
static struct gpio_desc *fwnode_gpiod_get_index(void *n,const char *name,int i,int flags,const char *label) {
    if (acquire_fail) return ERR_PTR(-EBUSY);
    owned++; return &descriptor;
}
static int of_get_named_gpio(struct device_node *n,const char *name,int i) { return invalid_gpio?-EINVAL:17; }
static int gpio_is_valid(int n) { return n>=0; }
static struct gpio_desc *gpio_to_desc(int n) { return descriptor_null?NULL:&descriptor; }
static int gpio_request(int n,const char *name) { if (acquire_fail) return -EBUSY; owned++; return 0; }
static int gpiod_direction_output(struct gpio_desc *d,int value) { return (!d || direction_fail)?-EIO:0; }
static void gpiod_put(struct gpio_desc *d) { if (owned!=1 || d!=&descriptor) bad_puts++; else owned--; put_count++; }
'''
gpio += function("mlinux/moal_main.c","woal_regist_ind_rst_gpio")
gpio += function("mlinux/moal_main.c","woal_unregist_ind_rst_gpio")
gpio += r'''
int main(void) {
    moal_handle h={0}; direction_fail=1;
    woal_regist_ind_rst_gpio(&h);
    check(!h.ind_rst_gpiod && !owned,"direction failure keeps OOB disabled and releases ownership");
    check(put_count==1 && !bad_puts && node_puts==1,"failed setup releases exactly its acquired descriptor");
    direction_fail=0; put_count=node_puts=bad_puts=owned=0; h.ind_rst_gpiod=NULL;
    acquire_fail=1; woal_regist_ind_rst_gpio(&h);
    check(!h.ind_rst_gpiod && !owned && !put_count && node_puts==1,"acquisition failure retains in-band reset path");
    acquire_fail=0; node_missing=1; node_puts=0; woal_regist_ind_rst_gpio(&h);
    check(!h.ind_rst_gpiod && !owned && !node_puts,"missing DT node keeps OOB disabled");
    node_missing=0;
#if LINUX_VERSION_CODE < KERNEL_VERSION(7,1,0)
    invalid_gpio=1; woal_regist_ind_rst_gpio(&h);
    check(!h.ind_rst_gpiod && !owned,"invalid legacy GPIO rejected"); invalid_gpio=0;
    descriptor_null=1; woal_regist_ind_rst_gpio(&h);
    check(!h.ind_rst_gpiod && !owned,"NULL legacy descriptor rejected"); descriptor_null=0;
#endif
    put_count=bad_puts=0; woal_regist_ind_rst_gpio(&h);
    check(h.ind_rst_gpiod==&descriptor && owned==1,"successful setup publishes an owned output descriptor");
    woal_unregist_ind_rst_gpio(&h);
    check(!h.ind_rst_gpiod && !owned && put_count==1 && !bad_puts,"removal releases descriptor once");
    woal_unregist_ind_rst_gpio(&h);
    check(put_count==1 && !bad_puts,"repeated removal does not release again");
    printf("gpio checks=%d failures=%d\n",checks,failures); return failures?1:0;
}
'''

# rtt-recovery: hang/reset clean-up must not wait forever behind rtt_mutex.
def masked(text):
    return re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', lambda m: " " * len(m.group()), text, flags=re.S)

def ordered(path, name, *tokens):
    body, index = masked(function(path, name)), 0
    for token in tokens:
        index = body.find(token, index)
        if index < 0: raise RuntimeError("%s: %r missing or out of order" % (name, token))
        index += len(token)

def optional(path, name):
    try: return function(path, name)
    except RuntimeError: return ""

# The recovery threads below model these production sequences; fail on drift.
ordered("mlinux/moal_main.c", "woal_hang_work_queue", "down(&AddRemoveCardSem);",
        "woal_clean_up(handle);", "MOAL_REL_SEMAPHORE(&AddRemoveCardSem);")
ordered("mlinux/moal_sdio_mmc.c", "__woal_do_sdiommc_flr", "down(&AddRemoveCardSem);",
        "handle->surprise_removed = MTRUE;", "woal_reset_intf(priv, MOAL_IOCTL_WAIT, MTRUE);",
        "woal_clean_up(handle);", "mlan_shutdown_fw(handle->pmlan_adapter);",
        "MOAL_REL_SEMAPHORE(&AddRemoveCardSem);")
ordered("mlinux/moal_main.c", "woal_main_work_queue", "if (handle->surprise_removed == MTRUE) {",
        "return;", "mlan_main_process(handle->pmlan_adapter);")
ordered("mlan/mlan_shim.c", "mlan_ioctl", "if (pioctl_req == MNULL) {", "pmadapter->pending_clean = MTRUE;")
ordered("mlan/mlan_shim.c", "mlan_main_process", "if (pmadapter->pending_clean) {",
        "wlan_cancel_all_pending_cmd(pmadapter, MFALSE);", "wlan_free_txrx(pmadapter);")
ordered("mlan/mlan_shim.c", "mlan_shutdown_fw", "wlan_cancel_all_pending_cmd(pmadapter, MTRUE);")
dbg_dump = masked((root / "mlinux/moal_shim.c").read_text())
dbg_dump = dbg_dump[dbg_dump.index("case MLAN_EVENT_ID_DRV_DBG_DUMP:"):]
dbg_dump = dbg_dump[:dbg_dump.index("break;")]
if not 0 <= dbg_dump.find("driver_status = MTRUE;") < dbg_dump.find("woal_process_hang("):
    raise RuntimeError("DRV_DBG_DUMP no longer publishes driver_status before hang work")
# #if/#else branches open braces twice, so cut at the column-0 closing brace.
clean_up = (root / "mlinux/moal_main.c").read_text()
clean_up = clean_up[clean_up.index("\nvoid woal_clean_up(moal_handle *handle)\n{"):]
clean_up = masked(clean_up[:clean_up.index("\n}\n") + 3])
blocking = [t for t in ("mutex_lock", "woal_request_ioctl", "MOAL_IOCTL_WAIT", "wait_event", "down(") if t in clean_up]
if blocking or clean_up.count("mlan_ioctl(") != 1:
    raise RuntimeError("woal_clean_up gained unmodelled blocking or MLAN calls: %s" % blocking)
clean_steps = (("woal_rtt_quiesce(handle, NULL);", "woal_rtt_quiesce(handle, NULL);"),
               ("woal_stop_queue(priv->netdev);", "model_stop_queues(handle);"),
               ("mlan_ioctl(handle->pmlan_adapter, NULL);", "model_pending_clean(handle);"))
clean_found = sorted((m.start(), step) for token, step in clean_steps
                     for m in re.finditer(re.escape(token), clean_up))
for _, step in clean_steps:
    if sum(1 for _, found in clean_found if found == step) != 1:
        raise RuntimeError("woal_clean_up recovery sequence changed: " + step)
clean_model = ("/* Generated from the woal_clean_up() call order. */\n"
               "static void model_clean_up(moal_handle *handle)\n{\n" +
               "".join("\t%s\n" % step for _, step in clean_found) + "}\n")
rtt_header = (root / "mlinux/moal_main.h").read_text()
rtt_fields_start = rtt_header.index("\tstruct mutex rtt_mutex;")
rtt_fields = rtt_header[rtt_fields_start:rtt_header.index("\t/** Driver workqueue */", rtt_fields_start)]
rtt_recovery = r'''#include <pthread.h>
#include <semaphore.h>
#include <signal.h>
#include <stddef.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "mlan_ioctl.h"
#define CFG80211_VERSION_CODE LINUX_VERSION_CODE
#define STA_CFG80211 1
#ifndef ETH_ALEN
#define ETH_ALEN 6
#endif
#define MOAL_IOCTL_WAIT 1
#define MOAL_IOCTL_WAIT_TIMEOUT 2
#define GFP_KERNEL 0
#define READ_ONCE(x) __atomic_load_n(&(x), __ATOMIC_SEQ_CST)
#define WRITE_ONCE(x, v) __atomic_store_n(&(x), (v), __ATOMIC_SEQ_CST)
#define container_of(p, t, m) ((t *)((char *)(p) - offsetof(t, m)))
#define moal_memcpy_ext(h, d, s, n, cap) ((void)(h), assert((n) <= (cap)), memcpy(d, s, n))
#define woal_get_wiphy_priv(w) ((w)->handle)
#define woal_get_netdev_priv(n) ((n)->priv)
typedef unsigned char BOOLEAN;
typedef pthread_mutex_t spinlock_t;
typedef int wait_queue_head_t;
struct mutex { pthread_mutex_t native; };
struct work_struct { int unused; };
typedef struct _moal_private moal_private;
struct net_device { moal_private *priv; };
struct wiphy { struct _moal_handle *handle; };
struct wireless_dev { struct net_device *netdev; struct wiphy *wiphy; };
struct ieee80211_channel { unsigned int center_freq; };
struct cfg80211_pmsr_request_peer {
    t_u8 addr[ETH_ALEN];
    struct { struct ieee80211_channel *chan; } chandef;
    struct { int request_lci, request_civicloc, non_trigger_based, trigger_based; } ftm;
};
struct cfg80211_pmsr_request { int n_peers; struct cfg80211_pmsr_request_peer peers[1]; };
struct _moal_handle {
''' + rtt_fields + r'''    moal_private *priv[2];
    int priv_num;
    void *pmlan_adapter;
    int surprise_removed, driver_status, fw_reseting;
};
typedef struct _moal_handle moal_handle;
struct _moal_private {
    moal_handle *phandle;
    t_u8 bss_index;
    BOOLEAN rtt_admission_closed;
    struct net_device *netdev;
    struct wireless_dev *wdev;
    struct cfg80211_pmsr_request *pmsr_request;
};
#define mutex_lock(m) assert(!pthread_mutex_lock(&(m)->native))
#define mutex_unlock(m) assert(!pthread_mutex_unlock(&(m)->native))
#define spin_lock_irqsave(l, f) do { (f) = 0; assert(!pthread_mutex_lock(l)); } while (0)
#define spin_unlock_irqrestore(l, f) do { (void)(f); assert(!pthread_mutex_unlock(l)); } while (0)
enum { CMD_POWER, CMD_CFG, CMD_START, CMD_STOP, CMD_OTHER, CMD_KINDS };
struct host_wait { int condition; mlan_status status; } __attribute__((aligned(8)));
static pthread_mutex_t fw_lock = PTHREAD_MUTEX_INITIALIZER, alloc_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t ftm_lock = PTHREAD_MUTEX_INITIALIZER, work_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t fw_cond = PTHREAD_COND_INITIALIZER, ftm_cond = PTHREAD_COND_INITIALIZER;
static pthread_cond_t work_cond = PTHREAD_COND_INITIALIZER;
static sem_t AddRemoveCardSem;
static int fw_answers[CMD_KINDS], fw_seen[CMD_KINDS], pending_count, live_reqs, late_frees;
static int fast_failures, worker_running, pending_clean, queues_stopped, txrx_frees, txrx_early;
static mlan_ioctl_req *pending[16];
static void *req_table[32];
static void deadline_ms(struct timespec *t, long ms)
{
    assert(!clock_gettime(CLOCK_REALTIME, t));
    t->tv_sec += ms / 1000;
    t->tv_nsec += (ms % 1000) * 1000000L;
    if (t->tv_nsec >= 1000000000L) { t->tv_sec++; t->tv_nsec -= 1000000000L; }
}
/* RTT result waits: FTM_SESSION_TIMEOUT_MS (10 s) scaled to 50 ms. */
static long host_wait_done(int ok) { assert(!pthread_mutex_unlock(&ftm_lock)); return ok; }
#define msecs_to_jiffies(ms) ((ms) / 200)
#define wait_event_interruptible_timeout(q, condition, timeout) ({ \
    struct timespec wait_deadline; \
    (void)(q); \
    deadline_ms(&wait_deadline, (timeout)); \
    assert(!pthread_mutex_lock(&ftm_lock)); \
    while (!(condition) && pthread_cond_timedwait(&ftm_cond, &ftm_lock, &wait_deadline) != ETIMEDOUT) {} \
    host_wait_done(!!(condition)); })
#define wake_up_interruptible(q) do { (void)(q); assert(!pthread_mutex_lock(&ftm_lock)); \
    assert(!pthread_cond_broadcast(&ftm_cond)); assert(!pthread_mutex_unlock(&ftm_lock)); } while (0)
/* ioctl buffers are tracked so a lost or doubly-freed request is visible. */
static mlan_ioctl_req *woal_alloc_mlan_ioctl_req(int size)
{
    mlan_ioctl_req *req = calloc(1, sizeof(*req) + sizeof(struct host_wait) + size);
    int i = 0;
    assert(req);
    req->reserved_1 = (t_ptr)(req + 1);
    req->pbuf = (t_u8 *)(req + 1) + sizeof(struct host_wait);
    req->buf_len = size;
    assert(!pthread_mutex_lock(&alloc_lock));
    while (req_table[i]) assert(++i < 32);
    req_table[i] = req; live_reqs++;
    assert(!pthread_mutex_unlock(&alloc_lock));
    return req;
}
static void host_kfree(void *p)
{
    assert(!pthread_mutex_lock(&alloc_lock));
    for (int i = 0; p && i < 32; i++)
        if (req_table[i] == p) { req_table[i] = NULL; live_reqs--; }
    assert(!pthread_mutex_unlock(&alloc_lock));
    free(p);
}
#define kzalloc(n, g) calloc(1, (n))
#define kfree(p) host_kfree(p)
static int classify(mlan_ioctl_req *req)
{
    mlan_ds_misc_cfg *misc = (mlan_ds_misc_cfg *)req->pbuf;
    if (req->req_id == MLAN_IOCTL_POWER_CFG) return CMD_POWER;
    if (req->req_id != MLAN_IOCTL_MISC_CFG) return CMD_OTHER;
    if (misc->sub_command == MLAN_OID_MISC_FTM_SESSION_CFG) return CMD_CFG;
    if (misc->sub_command != MLAN_OID_MISC_FTM_SESSION_CTRL) return CMD_OTHER;
    return misc->param.ftm_session_ctrl.action == FTM_SESSION_CTRL_ACTION_STOP ? CMD_STOP : CMD_START;
}
/* moal_ioctl_complete(): wake a live waiter, or free a request it abandoned. */
static void host_complete(mlan_ioctl_req *req, mlan_status status)
{
    struct host_wait *wait = (struct host_wait *)req->reserved_1;
    for (int i = 0; i < pending_count; i++)
        if (pending[i] == req) { pending[i] = pending[--pending_count]; break; }
    req->status_code = MLAN_ERROR_CMD_CANCEL;
    if (wait) { wait->condition = 1; wait->status = status; assert(!pthread_cond_broadcast(&fw_cond)); }
    else { late_frees++; kfree(req); }
}
/* Production fail-fast gate; a firmware that never answers leaves the
 * request queued: WAIT sleeps without bound, WAIT_TIMEOUT for 200 ms. */
static mlan_status woal_request_ioctl(moal_private *priv, mlan_ioctl_req *req, t_u8 wait_option)
{
    moal_handle *handle = priv->phandle;
    struct host_wait *wait = (struct host_wait *)req->reserved_1;
    t_u32 sub_command = *(t_u32 *)req->pbuf;
    struct timespec deadline;
    mlan_status status;
    int kind = classify(req);
    if (sub_command != MLAN_OID_GET_DEBUG_INFO && sub_command != MLAN_OID_MISC_WARM_RESET &&
        (READ_ONCE(handle->surprise_removed) || READ_ONCE(handle->driver_status))) {
        __atomic_add_fetch(&fast_failures, 1, __ATOMIC_SEQ_CST);
        return MLAN_STATUS_FAILURE;
    }
    req->bss_index = priv->bss_index;
    assert(!pthread_mutex_lock(&fw_lock));
    fw_seen[kind]++;
    if (fw_answers[kind]) {
        if (kind == CMD_POWER) ((mlan_ds_power_cfg *)req->pbuf)->param.power_cfg.power_level = 17;
        assert(!pthread_mutex_unlock(&fw_lock));
        return MLAN_STATUS_SUCCESS;
    }
    assert(wait_option == MOAL_IOCTL_WAIT || wait_option == MOAL_IOCTL_WAIT_TIMEOUT);
    assert(pending_count < 16);
    pending[pending_count++] = req;
    wait->condition = 0;
    assert(!pthread_cond_broadcast(&fw_cond));
    deadline_ms(&deadline, 200);
    while (!wait->condition) {
        if (wait_option == MOAL_IOCTL_WAIT) assert(!pthread_cond_wait(&fw_cond, &fw_lock));
        else if (pthread_cond_timedwait(&fw_cond, &fw_lock, &deadline) == ETIMEDOUT) break;
    }
    if (wait->condition) status = wait->status;
    else { req->reserved_1 = 0; status = MLAN_STATUS_PENDING; }
    assert(!pthread_mutex_unlock(&fw_lock));
    return status;
}
/* mlan_ioctl(adapter, NULL) only sets pending_clean (checked above). */
mlan_status mlan_ioctl(t_void *padapter, pmlan_ioctl_req pioctl_req)
{
    assert(padapter && !pioctl_req);
    pending_clean = 1;
    return MLAN_STATUS_SUCCESS;
}
static void model_cancel_all(void)
{
    assert(!pthread_mutex_lock(&fw_lock));
    while (pending_count) host_complete(pending[pending_count - 1], MLAN_STATUS_FAILURE);
    assert(!pthread_mutex_unlock(&fw_lock));
}
/* woal_main_work_queue() is inert after surprise_removed; otherwise
 * mlan_main_process() cancels every command and frees txrx. */
static void model_main_work(moal_handle *handle)
{
    if (READ_ONCE(handle->surprise_removed) || !pending_clean) return;
    model_cancel_all();
    if (!queues_stopped) txrx_early = 1;
    txrx_frees++;
    pending_clean = 0;
}
static void model_stop_queues(moal_handle *handle) { (void)handle; queues_stopped = 1; }
static void model_pending_clean(moal_handle *handle) { mlan_ioctl(handle->pmlan_adapter, NULL); model_main_work(handle); }
static bool cancel_work_sync(struct work_struct *work)
{
    (void)work;
    assert(!pthread_mutex_lock(&work_lock));
    while (worker_running) assert(!pthread_cond_wait(&work_cond, &work_lock));
    assert(!pthread_mutex_unlock(&work_lock));
    return false;
}
static moal_private *woal_get_priv(moal_handle *handle, int role) { (void)role; return handle->priv[0]; }
static int ieee80211_frequency_to_channel(unsigned int freq) { return freq == 2412 ? 1 : 36; }
static t_u8 woal_freq_to_chanband(t_u32 freq) { (void)freq; return 0; }
static t_u8 woal_freq_to_chanband_pmsr(t_u32 freq) { (void)freq; return 0; }
static t_u16 woal_get_ftm_session_action(moal_private *p, t_u8 *mac) { (void)p; (void)mac; return FTM_SESSION_UNASSOCIATED; }
static t_u16 woal_get_ftm_session_action_pmsr(moal_private *p, const t_u8 *mac) { (void)p; (void)mac; return FTM_SESSION_UNASSOCIATED; }
static t_u8 get_channel_spacing_from_rtt_config(int preamble, int bw) { (void)preamble; (void)bw; return 0; }
static int woal_ftm_session_cfg_ntb_ranging(moal_private *p, wifi_rtt_config_v3 *c) { (void)p; (void)c; return -EOPNOTSUPP; }
static mlan_status woal_cfg80211_event_rtt_result(moal_private *p, t_u8 *d, int n) { (void)p; (void)d; (void)n; return MLAN_STATUS_SUCCESS; }
static mlan_status woal_cfg80211_event_rtt_result_v3(moal_private *p, t_u8 *d, int n) { (void)p; (void)d; (void)n; return MLAN_STATUS_SUCCESS; }
/* PMSR SESSION_CFG is answered; only START/STOP use the modelled firmware. */
static int woal_ftm_session_cfg_pmsr(moal_private *p, struct cfg80211_pmsr_request_peer *peer) { (void)p; (void)peer; return 0; }
static int woal_ftm_az_session_cfg_pmsr(moal_private *p, struct cfg80211_pmsr_request_peer *peer) { (void)p; (void)peer; return -EOPNOTSUPP; }
static int woal_ftm_az_session_ctrl_pmsr(moal_private *p, const t_u8 *mac, t_u32 freq, t_u16 action) { (void)p; (void)mac; (void)freq; (void)action; return -EOPNOTSUPP; }
'''
rtt_recovery += "\n".join(function("mlinux/moal_cfg80211_util.c", n) for n in (
    "woal_rtt_config_at", "woal_rtt_release", "woal_ftm_session_cfg", "woal_ftm_session_ctrl",
    "woal_rtt_work_handler", "woal_rtt_quiesce", "woal_ftm_session_ctrl_pmsr", "woal_cfg80211_start_pmsr"))
rtt_recovery += optional("mlinux/moal_ioctl.c", "woal_set_get_tx_power_wait")
rtt_recovery += function("mlinux/moal_ioctl.c", "woal_set_get_tx_power")
rtt_recovery += function("mlinux/moal_sta_cfg80211.c", "woal_cfg80211_get_tx_power")
rtt_recovery += clean_model + r'''
static moal_handle H;
static moal_private P;
static struct net_device N;
static struct wireless_dev D;
static struct wiphy W;
static struct ieee80211_channel C = { 2412 };
static struct cfg80211_pmsr_request R;
static int adapter, power_ret, power_dbm, pmsr_ret;
static const char *scenario;
static int expect(int ok, const char *what)
{
    char text[192];
    snprintf(text, sizeof(text), "rtt-recovery %s: %s", scenario, what);
    check(ok, text);
    return ok;
}
static void fixture(int power, int cfg, int start, int stop)
{
    P.phandle = &H; P.netdev = &N; P.wdev = &D; N.priv = &P; D.netdev = &N; D.wiphy = &W; W.handle = &H;
    H.priv[0] = &P; H.priv_num = 1; H.pmlan_adapter = &adapter;
    assert(!pthread_mutex_init(&H.rtt_result_lock, NULL));
    assert(!pthread_mutex_init(&H.rtt_mutex.native, NULL));
    assert(!pthread_mutex_init(&H.rtt_quiesce_mutex.native, NULL));
    H.rtt_initialized = MTRUE; H.rtt_fw_supported = MTRUE; H.rtt_current_index = -1;
    assert(!sem_init(&AddRemoveCardSem, 0, 1));
    fw_answers[CMD_POWER] = power; fw_answers[CMD_CFG] = cfg;
    fw_answers[CMD_START] = start; fw_answers[CMD_STOP] = stop;
}
static void seed_vendor(void)
{
    wifi_rtt_config *cfg = &H.rtt_params.rtt_config[0];
    cfg->addr[0] = 2; cfg->addr[5] = 1; cfg->type = RTT_TYPE_2_SIDED_11MC;
    cfg->preamble = WIFI_RTT_PREAMBLE_LEGACY; cfg->bw = WIFI_RTT_BW_20; cfg->channel.center_freq = 2412;
    H.rtt_params.rtt_config_num = 1; H.rtt_total_ap_count = 1; H.rtt_owner = RTT_OWNER_VENDOR;
    H.rtt_priv = &P; H.rtt_version = 1; H.rtt_target_state[0] = RTT_TARGET_PENDING;
    H.rtt_result_buf_len = 1; worker_running = 1;
}
static void *power_thread(void *arg)
{
    (void)arg; power_dbm = 99;
    power_ret = woal_cfg80211_get_tx_power(&W, &D, &power_dbm);
    return NULL;
}
static void *worker_thread(void *arg)
{
    (void)arg;
    woal_rtt_work_handler(&H.rtt_work);
    assert(!pthread_mutex_lock(&work_lock));
    worker_running = 0;
    assert(!pthread_cond_broadcast(&work_cond) && !pthread_mutex_unlock(&work_lock));
    return NULL;
}
static void *pmsr_thread(void *arg) { (void)arg; pmsr_ret = woal_cfg80211_start_pmsr(&W, &D, &R); return NULL; }
/* woal_hang_work_queue(): down(AddRemoveCardSem) -> woal_clean_up() -> up. */
static void *hang_thread(void *arg)
{
    (void)arg;
    assert(!sem_wait(&AddRemoveCardSem));
    model_clean_up(&H);
    assert(!sem_post(&AddRemoveCardSem));
    return NULL;
}
/* __woal_do_sdiommc_flr(prepare): surprise_removed precedes clean-up, then
 * mlan_shutdown_fw() cancels every remaining command. */
static void *reset_thread(void *arg)
{
    mlan_ioctl_req *req;
    (void)arg;
    assert(!sem_wait(&AddRemoveCardSem));
    WRITE_ONCE(H.fw_reseting, 1);
    WRITE_ONCE(H.surprise_removed, 1);
    req = woal_alloc_mlan_ioctl_req(sizeof(mlan_ds_bss)); /* woal_reset_intf() */
    req->req_id = MLAN_IOCTL_BSS;
    ((mlan_ds_bss *)req->pbuf)->sub_command = MLAN_OID_BSS_STOP;
    if (woal_request_ioctl(&P, req, MOAL_IOCTL_WAIT) != MLAN_STATUS_PENDING) kfree(req);
    model_clean_up(&H);
    model_cancel_all();
    assert(!sem_post(&AddRemoveCardSem));
    return NULL;
}
static int started(pthread_t *thread, void *(*fn)(void *)) { return !pthread_create(thread, NULL, fn, NULL); }
static int joined(pthread_t thread)
{
    struct timespec deadline;
    deadline_ms(&deadline, 3000);
    return !pthread_timedjoin_np(thread, NULL, &deadline);
}
static int waiting(void)
{
    struct timespec deadline;
    int ok;
    deadline_ms(&deadline, 1000);
    assert(!pthread_mutex_lock(&fw_lock));
    while (!pending_count && pthread_cond_timedwait(&fw_cond, &fw_lock, &deadline) != ETIMEDOUT) {}
    ok = pending_count == 1;
    assert(!pthread_mutex_unlock(&fw_lock));
    return ok;
}
static int drained(void)
{
    int ok;
    assert(!pthread_mutex_lock(&alloc_lock)); ok = !live_reqs; assert(!pthread_mutex_unlock(&alloc_lock));
    assert(!pthread_mutex_lock(&fw_lock)); ok = ok && !pending_count; assert(!pthread_mutex_unlock(&fw_lock));
    return ok;
}
/* One recovery under a 3 s watchdog: a stuck run is reported, never awaited. */
static int recover(void *(*fn)(void *))
{
    pthread_t thread;
    int value = -1;
    if (!expect(started(&thread, fn) && joined(thread), "recovery completes within the 3 s watchdog"))
        return 0;
    assert(!sem_getvalue(&AddRemoveCardSem, &value));
    return expect(value == 1, "recovery releases AddRemoveCardSem");
}
/* S0: an answering firmware completes both waiters and both recoveries. */
static int positive_control(void)
{
    pthread_t thread;
    fixture(1, 1, 1, 1);
    if (!expect(started(&thread, power_thread) && joined(thread), "answered TX-power query returns"))
        return failures;
    expect(!power_ret && power_dbm == 17 && fw_seen[CMD_POWER] == 1, "answered TX-power query reports firmware power");
    seed_vendor();
    if (!expect(started(&thread, worker_thread) && joined(thread), "answered RTT worker finishes"))
        return failures;
    expect(fw_seen[CMD_CFG] == 1 && fw_seen[CMD_START] == 1 && fw_seen[CMD_STOP] == 1 &&
           H.rtt_owner == RTT_OWNER_IDLE && !H.ftm_session_in_progress, "answered RTT session stops and releases");
    WRITE_ONCE(H.driver_status, 1);
    if (recover(hang_thread) && recover(reset_thread))
        expect(fast_failures == 1 && txrx_frees == 1 && !txrx_early && drained(),
               "idle recoveries leave no request and free txrx only after queues stop");
    return failures;
}
/* S1-S4: the firmware never answers the waiter's ioctl; recover anyway. */
static int stalled(int reset, int rtt)
{
    pthread_t waiter;
    int stalled_kind = !rtt ? CMD_POWER : reset ? CMD_START : CMD_CFG;
    fixture(0, stalled_kind == CMD_START, 0, 0);
    if (rtt) seed_vendor();
    if (!expect(started(&waiter, rtt ? worker_thread : power_thread) && waiting(),
                "waiter blocks in an ioctl the firmware never answers"))
        return failures;
    if (!reset) WRITE_ONCE(H.driver_status, 1); /* MLAN_EVENT_ID_DRV_DBG_DUMP */
    if (!recover(reset ? reset_thread : hang_thread) ||
        !expect(joined(waiter), "stalled waiter returns"))
        return failures;
    if (rtt)
        expect(!worker_running && H.rtt_owner == RTT_OWNER_IDLE && !H.ftm_session_in_progress,
               "RTT worker drains and its session is released");
    else
        expect(power_ret && power_dbm == 99, "TX-power query fails without inventing a value");
    expect(fw_seen[stalled_kind] == 1 && fast_failures >= reset &&
           fw_seen[CMD_POWER] + fw_seen[CMD_CFG] + fw_seen[CMD_START] + fw_seen[CMD_STOP] + fw_seen[CMD_OTHER] ==
           1 + (stalled_kind == CMD_START), "no command reaches firmware after the stalled one");
    expect(drained(), "every stalled request is completed and freed");
    expect(!txrx_early && txrx_frees == !reset, "txrx is freed only by the final hang-path clean");
    return failures;
}
/* S5-S8: START may have started ranging; only a confirmed STOP clears busy. */
static int start_timeout(int pmsr, int stop_answers)
{
    pthread_t thread;
    fixture(1, 1, 0, stop_answers);
    if (pmsr) {
        R.n_peers = 1; R.peers[0].addr[0] = 2; R.peers[0].addr[5] = 3; R.peers[0].chandef.chan = &C;
    } else {
        seed_vendor();
    }
    if (!expect(started(&thread, pmsr ? pmsr_thread : worker_thread) && joined(thread),
                "START that firmware never answers returns"))
        return failures;
    expect(fw_seen[CMD_START] == 1 && fw_seen[CMD_STOP] == 1, "timed-out START is followed by one STOP");
    if (pmsr) expect(pmsr_ret == -ETIMEDOUT && !P.pmsr_request, "PMSR start reports the timeout and drops the request");
    if (stop_answers)
        expect(!H.ftm_session_in_progress && H.rtt_owner == RTT_OWNER_IDLE, "confirmed STOP clears and releases the session");
    else
        expect(H.ftm_session_in_progress && H.rtt_owner == (pmsr ? RTT_OWNER_PMSR : RTT_OWNER_VENDOR),
               "unconfirmed STOP keeps the possibly-started session busy");
    if (!expect(started(&thread, power_thread) && joined(thread), "TX-power query returns"))
        return failures;
    if (stop_answers)
        expect(!power_ret && power_dbm == 17 && fw_seen[CMD_POWER] == 1, "TX power is queried after a confirmed STOP");
    else
        expect(power_ret == -EBUSY && power_dbm == 99 && !fw_seen[CMD_POWER],
               "busy session returns -EBUSY and no POWER_CFG reaches firmware");
    WRITE_ONCE(H.driver_status, 1);
    if (recover(hang_thread))
        expect(H.rtt_owner == RTT_OWNER_IDLE && !H.ftm_session_in_progress && drained() &&
               late_frees == 2 - stop_answers, "recovery releases the session and frees timed-out requests late");
    return failures;
}
static int s1(void) { return stalled(0, 0); }
static int s2(void) { return stalled(0, 1); }
static int s3(void) { return stalled(1, 0); }
static int s4(void) { return stalled(1, 1); }
static int s5(void) { return start_timeout(0, 0); }
static int s6(void) { return start_timeout(0, 1); }
static int s7(void) { return start_timeout(1, 0); }
static int s8(void) { return start_timeout(1, 1); }
static const struct { const char *name; int (*run)(void); } scenarios[] = {
    {"S0 positive-control", positive_control},
    {"S1 hang+get_tx_power", s1},
    {"S2 hang+rtt-worker(SESSION_CFG)", s2},
    {"S3 sdio-reset+get_tx_power", s3},
    {"S4 sdio-reset+rtt-worker(START)", s4},
    {"S5 vendor-START-timeout+STOP-unanswered", s5},
    {"S6 vendor-START-timeout+STOP-confirmed", s6},
    {"S7 pmsr-START-timeout+STOP-unanswered", s7},
    {"S8 pmsr-START-timeout+STOP-confirmed", s8},
};
/* Scenarios run in parallel child processes, so a stuck one cannot stall
 * the others; each child also dies by SIGALRM after 6 s at the latest. */
int main(void)
{
    enum { COUNT = sizeof(scenarios) / sizeof(scenarios[0]) };
    pid_t pid[COUNT];
    int i, status, failed = 0;
    fflush(NULL);
    for (i = 0; i < COUNT; i++) {
        pid[i] = fork();
        assert(pid[i] >= 0);
        if (!pid[i]) {
            alarm(6);
            scenario = scenarios[i].name;
            status = scenarios[i].run();
            fflush(NULL);
            _exit(status ? 1 : 0);
        }
    }
    for (i = 0; i < COUNT; i++) {
        assert(waitpid(pid[i], &status, 0) == pid[i]);
        if (WIFEXITED(status) && !WEXITSTATUS(status)) {
            printf("rtt-recovery %s: PASS\n", scenarios[i].name);
            continue;
        }
        failed++;
        if (WIFSIGNALED(status))
            printf("rtt-recovery %s: FAIL (signal %d)\n", scenarios[i].name, WTERMSIG(status));
        else
            printf("rtt-recovery %s: FAIL\n", scenarios[i].name);
    }
    printf("rtt-recovery scenarios=%d failures=%d\n", COUNT, failed);
    return failed ? 1 : 0;
}
'''

rate_units = r'''
/* The 500-kbit/s stub results match the production wrapper values pinned
 * by scripts/tests/rate_query_units_host_test.c; the kbit/s results only
 * need to differ from them so a call site using the raw converter fails. */
static t_u32 converter_kbps, converter_abi;
static t_u8 seen_index, seen_info;
t_u32 wlan_index_to_data_rate(pmlan_adapter pmadapter, t_u8 index, t_u8 rate_info,
                              t_u8 ext_rate_info, t_bool is_eht)
{ seen_index=index; seen_info=rate_info; return converter_kbps; }
t_u32 wlan_index_to_data_rate_500kbps(pmlan_adapter pmadapter, t_u8 index, t_u8 rate_info,
                                      t_u8 ext_rate_info, t_bool is_eht)
{ seen_index=index; seen_info=rate_info; return converter_abi; }
sta_node *wlan_get_station_entry(mlan_private *priv,t_u8 *mac) { abort(); }
sta_node *wlan_add_station_entry(mlan_private *priv,t_u8 *mac) { abort(); }
t_void wlan_delete_station_entry(mlan_private *priv,t_u8 *mac) { abort(); }
t_void wlan_delete_station_list(pmlan_private priv) { abort(); }
t_u8 wlan_is_station_list_empty(mlan_private *priv) { abort(); }
t_void wlan_hold_tdls_packets(pmlan_private priv,t_u8 *mac) { abort(); }
t_void wlan_restore_tdls_packets(pmlan_private priv,t_u8 *mac,tdlsStatus_e status) { abort(); }
void wlan_11n_cleanup_txbastream_tbl(mlan_private *priv,t_u8 *ra) { abort(); }
void wlan_cleanup_reorder_tbl(mlan_private *priv,t_u8 *ta) { abort(); }
static void wlan_set_tdls_powermode(pmlan_private pmpriv,t_u8 powermode) { abort(); }
static t_void *host_memcpy_ext(t_void *h,t_void *d,const t_void *s,t_u32 n,t_u32 size)
{ return memcpy(d,s,n<size?n:size); }
#define memset(adapter,s,c,len) memset((s),(c),(len))
'''
rate_units += function("mlan/mlan_sta_rx.c","wlan_rxpdinfo_to_radiotapinfo")
rate_units += function("mlan/mlan_sta_cmdresp.c","wlan_ret_tdls_config")
rate_units += r'''
#undef memset
static mlan_adapter adapter;
static mlan_private priv;
static void radiotap(t_u8 rate,t_u8 info,t_u32 kbps,t_u32 abi,const char *name) {
    RxPD pd; radiotap_info rt;
    memset(&pd,0,sizeof(pd)); memset(&rt,0xa5,sizeof(rt));
    pd.rx_rate=rate; pd.rate_info=info;
    converter_kbps=kbps; converter_abi=abi; seen_index=seen_info=0xff;
    wlan_rxpdinfo_to_radiotapinfo(&priv,&pd,&rt);
    check(rt.rate_info.bitrate==abi,name);
    check(seen_index==rate && seen_info==info,"radiotap forwards the RxPD rate fields");
}
static void tdls(t_u8 rate,t_u8 info,t_u32 kbps,t_u32 abi,t_u16 mbps,const char *name) {
    static HostCmd_DS_COMMAND resp; mlan_ds_misc_cfg misc; mlan_ioctl_req req;
    memset(&resp,0,sizeof(resp)); memset(&misc,0,sizeof(misc)); memset(&req,0,sizeof(req));
    req.pbuf=(t_u8 *)&misc;
    HostCmd_DS_TDLS_CONFIG *cfg=&resp.params.tdls_config_data;
    tdls_all_config *all=(tdls_all_config *)cfg->tdls_info.tdls_data;
    tdls_each_link_status *link=all->u.tdls_link_status_resp.link_stats;
    cfg->tdls_info.tdls_action=wlan_cpu_to_le16(WLAN_TDLS_LINK_STATUS);
    all->u.tdls_link_status_resp.active_links=1;
    link->u.rate_info.tx_data_rate=rate; link->u.rate_info.tx_rate_htinfo=info;
    resp.size=S_DS_GEN+sizeof(*cfg);
    converter_kbps=kbps; converter_abi=abi; seen_index=seen_info=0xff;
    check(wlan_ret_tdls_config(&priv,&resp,&req)==MLAN_STATUS_SUCCESS,"TDLS link status response accepted");
    check(link->u.final_data_rate==mbps,name);
    check(seen_index==rate && seen_info==info,"TDLS forwards the link rate fields");
}
int main(void) {
    adapter.callbacks.moal_memcpy_ext=host_memcpy_ext; priv.adapter=&adapter;
    radiotap(12,MLAN_RATE_FORMAT_LG,54000,108,"radiotap legacy 54 Mbps reports Rate 108");
    radiotap(0x1b,MLAN_RATE_FORMAT_HE|0x08,1202100,2404,"radiotap HE80 NSS2 MCS11 bitrate uses 500-kbit/s units");
    radiotap(MLAN_RATE_BITMAP_MCS0,MLAN_RATE_FORMAT_HT|0x10,13,13,"radiotap HT MCS32 SGI keeps ABI value 13");
    tdls(7,MLAN_RATE_FORMAT_HT|0x10,72215,144,72,"TDLS HT20 MCS7 SGI reports 72 Mbps");
    tdls(MLAN_RATE_BITMAP_MCS0,MLAN_RATE_FORMAT_HT|0x10,13,13,6,"TDLS HT MCS32 SGI reports 6 Mbps");
    tdls(0x1b,MLAN_RATE_FORMAT_HE|0x08,1202100,2404,1202,"TDLS HE80 NSS2 MCS11 reports 1202 Mbps");
    printf("rate-units checks=%d failures=%d\n",checks,failures); return failures?1:0;
}
'''

groups={"thermal":(thermal,[(5,4),(6,6),(6,12),(7,1)]),"dfs":(dfs,[(6,6)]),
        "sensor":(sensor,[(6,6)]),"keep-connect":(keep,[(6,6)]),"gpio":(gpio,[(6,6),(7,1)]),
        "rtt-recovery":(rtt_recovery,[(6,6)]),"rate-units":(rate_units,[(6,6)])}
if selected != "all" and selected not in groups: raise SystemExit("unknown review host group: "+selected)
failed=0
with tempfile.TemporaryDirectory(prefix="moal-review-host-") as scratch:
    for name,(body,versions) in groups.items():
        if selected not in ("all",name): continue
        source=Path(scratch)/(name+".c"); binary=Path(scratch)/name; source.write_text(common+body)
        for major,minor in versions:
            flags=["cc","-std=gnu11","-O1","-g","-Wall","-Wextra","-Werror",
                   "-Wno-unused-parameter","-Wno-unused-function","-Wno-unused-variable",
                   "-Wno-unused-but-set-variable","-Wno-pointer-sign","-Wno-sign-compare",
                   "-DLINUX_VERSION_CODE="+str((major<<16)|(minor<<8)),
                   "-DSTA_SUPPORT","-DUAP_SUPPORT","-DSD9098","-DPCIE9098","-I"+str(root/"mlan")]
            if name=="dfs": flags += ["-fsanitize=address,undefined","-fno-sanitize-recover=all","-fno-pie","-no-pie"]
            if name=="rtt-recovery": flags += ["-pthread","-D_GNU_SOURCE","-DMLAN_64BIT"]
            subprocess.run(flags+[str(source),"-o",str(binary)],check=True)
            result=subprocess.run([str(binary)],capture_output=True,timeout=10)
            print("review-host %s kernel-branches %d.%d: %s"%(name,major,minor,result.stdout.decode().strip()),flush=True)
            if result.returncode:
                failed+=1; sys.stderr.buffer.write(result.stderr)
if failed: raise SystemExit(1)
print("review_host_regressions=PASS")
PY_REVIEW
}

string_host_regressions() {
python3 - "$ROOT" <<'PY_STRING'
from pathlib import Path
import subprocess
import sys
import tempfile

header = (Path(sys.argv[1]) / "mlinux/moal_main.h").read_text()
start = header.index("/** moal_strncpy")
compat = header[start:header.index("\n#endif", start) + len("\n#endif")]
prelude = r'''#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#define KERNEL_VERSION(a,b,c) (((a)<<16)|((b)<<8)|(c))
/* Kernel strscpy's capacity/return contract, when selected by production. */
static inline ssize_t strscpy(char *dst,const char *src,size_t capacity) {
    size_t i=0;
    if(!capacity)return -E2BIG;
    while(i+1<capacity && src[i]){dst[i]=src[i];i++;}
    dst[i]=0;return src[i]?-E2BIG:(ssize_t)i;
}
'''
tests = r'''static int failures,checks;
static void check(int ok,const char *name) {
    checks++;if(!ok){fprintf(stderr,"FAIL counted-copy: %s\n",name);failures++;}
}
static uintptr_t copy_counted(char *dst,const char *src,size_t count) {
    return (uintptr_t)moal_strncpy(dst,src,count);
}
int main(void) {
    char country[4]={'?','?','?','!'},type[3]={'?','?','!'};
    char iface[7],mac[19],offset[8],short_value[7],fixed[4],zero[2]={'x','y'},empty[5];
    const char slice[3]={'a','b','c'};
    uintptr_t returned=copy_counted(country,"KR",2);
    country[2]=0;check(!strcmp(country,"KR") && country[3]=='!',"two-byte country plus caller terminator");
    check(returned==(uintptr_t)country,"returns destination pointer");
    copy_counted(type,"2,",1);type[1]=0;
    check(type[0]=='2' && type[2]=='!',"one-byte register type");
    memset(iface,'!',sizeof(iface));copy_counted(iface,"mlan0:",5);iface[5]=0;
    check(!strcmp(iface,"mlan0") && iface[6]=='!',"counted interface substring");
    memset(mac,'!',sizeof(mac));copy_counted(mac,"02:11:22:33:44:55",17);mac[17]=0;
    check(!strcmp(mac,"02:11:22:33:44:55") && mac[18]=='!',"complete MAC substring");
    memset(offset,'!',sizeof(offset));copy_counted(offset,"0x1234,",6);offset[6]=0;
    check(!strcmp(offset,"0x1234") && offset[7]=='!',"register offset substring");
    memset(short_value,'!',sizeof(short_value));copy_counted(short_value,"x",5);
    check(!memcmp(short_value,"x\0\0\0\0",5) && short_value[5]=='!',"pads short source through count");
    memset(fixed,'!',sizeof(fixed));copy_counted(fixed,slice,sizeof(slice));
    check(!memcmp(fixed,"abc",3) && fixed[3]=='!',"non-NUL source retains every counted byte");
    returned=copy_counted(zero,"ignored",0);
    check(zero[0]=='x' && zero[1]=='y' && returned==(uintptr_t)zero,"zero count preserves bytes and return");
    memset(empty,'!',sizeof(empty));copy_counted(empty,"",4);
    check(!memcmp(empty,"\0\0\0\0",4) && empty[4]=='!',"empty source pads without overrun");
    printf("counted-copy checks=%d failures=%d\n",checks,failures);return failures?1:0;
}
'''
failures = 0
with tempfile.TemporaryDirectory(prefix="moal-counted-copy-") as scratch:
    source = Path(scratch) / "regression.c"
    binary = Path(scratch) / "regression"
    source.write_text(prelude + compat + "\n" + tests)
    for major, minor in [(6, 6), (7, 1), (7, 2), (7, 3)]:
        code = (major << 16) | (minor << 8)
        subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                        "-DLINUX_VERSION_CODE=" + str(code), str(source), "-o", str(binary)], check=True)
        result = subprocess.run([str(binary)], capture_output=True, timeout=10)
        print("string-host kernel-branches %d.%d: %s" % (major, minor, result.stdout.decode().strip()), flush=True)
        if result.returncode:
            failures += 1
            sys.stderr.buffer.write(result.stderr)
if failures:
    raise SystemExit(1)
print("string_host_regressions=PASS")
PY_STRING
}

# Link production MLAN conversion and selected MOAL paths with host-only doubles.
# The fixture never opens sockets, accesses a device, or builds a kernel/SDK.
rtt_host_regressions() {
python3 - "$ROOT" <<'PY_RTT'
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
util = (root / "mlinux/moal_cfg80211_util.c").read_text()
sta = (root / "mlinux/moal_sta_cfg80211.c").read_text()
sdio = (root / "mlinux/moal_sdio_mmc.c").read_text()
ioctl = (root / "mlinux/moal_ioctl.c").read_text()
main = (root / "mlinux/moal_main.c").read_text()
header = (root / "mlinux/moal_main.h").read_text()
vendor_header = (root / "mlinux/moal_cfg80211_util.h").read_text()
feature_defines = "\n".join(re.findall(r"^#define WLAN_FEATURE_[^\n]*", vendor_header.replace("\\\n", " "), re.M))
cap_init = main[main.index("\t/* RTT Cabability */"):main.index("\thandle->is_edmac_enabled = MFALSE;")]
pmsr_cap_start = sta.index("#if CFG80211_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\nstatic const struct cfg80211_pmsr_capabilities")
pmsr_cap_end = sta.index("#endif /* KERNEL_VERSION(4, 20, 0) */", pmsr_cap_start)
pmsr_caps = sta[pmsr_cap_start:pmsr_cap_end] + "#endif\n"
pmsr_init_start = sta.index("\t/* Set PMSR capabilities")
pmsr_init_end = sta.index("#endif /* KERNEL_VERSION(4, 20, 0) */", pmsr_init_start)
pmsr_init = sta[pmsr_init_start:pmsr_init_end] + "#endif\n"

def function(source, name):
    match = re.search(r"(?m)^(?:static )?(?:int|void|mlan_status|wifi_rtt_config\s*\*)\s*" + name + r"\([^;]*?\)\s*\{", source)
    if not match:
        raise RuntimeError("production function not found: " + name)
    masked = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
                    lambda m: " " * len(m.group()), source, flags=re.S)
    start = source.index("{", match.start())
    depth = 0
    for end in range(start, len(source)):
        if masked[end] == "{": depth += 1
        if masked[end] == "}":
            depth -= 1
            if not depth: return source[match.start():end + 1] + "\n"
    raise RuntimeError("unterminated production function: " + name)

fields = header[header.index("\tstruct mutex rtt_mutex;"):header.index("\t/** Driver workqueue */")]
prelude = r'''#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "mlan.h"
#include "mlan_ioctl.h"
#define KERNEL_VERSION(a,b,c) (((a)<<16)|((b)<<8)|(c))
#ifndef CFG80211_VERSION_CODE
#define CFG80211_VERSION_CODE KERNEL_VERSION(6,6,3)
#endif
#define STA_SUPPORT 1
#define STA_CFG80211 1
#define LINUX_VERSION_CODE CFG80211_VERSION_CODE
#define ENTER() ((void)0)
#define LEAVE() ((void)0)
#define PRINTM(...) ((void)0)
#define DBG_HEXDUMP(...) ((void)0)
#define unlikely(v) (v)
#define moal_strncpy(d,s,n) strncpy(d,s,n)
#define eth_hw_addr_set(n,a) memcpy((n)->dev_addr,(a),ETH_ALEN)
#define GFP_KERNEL 0
#define GFP_ATOMIC 0
#define MOAL_IOCTL_WAIT 1
#define MOAL_IOCTL_WAIT_TIMEOUT 2
#define MOAL_NO_WAIT 0
#define ETH_ALEN 6
#define MIN(a,b) ((a)<(b)?(a):(b))
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,v) ((x)=(v))
#define BIT(n) (1UL<<(n))
#define MOAL_ASSERT(x) assert(x)
#define __ATTRIB_ALIGN__
typedef unsigned char BOOLEAN;
typedef pthread_mutex_t spinlock_t;
typedef int wait_queue_head_t;
typedef int64_t s64;
/* Linux reserves current as a task-pointer macro, including on ARM64. */
struct task_struct;
static struct task_struct *get_current(void) { return NULL; }
#define current get_current()
struct mutex { pthread_mutex_t native; };
struct work_struct { int unused; };
struct workqueue_struct { int unused; };
struct _moal_handle;
typedef struct _moal_private moal_private;
struct net_device { moal_private *priv;t_u8 dev_addr[ETH_ALEN]; };
struct wiphy { struct _moal_handle *handle;const struct cfg80211_pmsr_capabilities *pmsr_capa;int responder; };
struct wireless_dev { struct net_device *netdev; struct wiphy *wiphy; };
struct _moal_handle {
'''
post_fields = r'''    moal_private *priv[MLAN_MAX_BSS_NUM];
    int priv_num;
    struct { int cfg80211_wext; } params;
    int partial_io_enable, shutdown_hs_in_process, surprise_removed, fw_reseting, driver_status;
    int hs_activate_wait_q, hs_activate_wait_q_woken, hs_activated;
    struct workqueue_struct *evt_workqueue;
    __typeof__(((mlan_fw_info *)0)->fw_ver) fw_release_number;
    char fw_ver_milestone[10],fw_ver_buildtype[10],fw_ver_data[30];
    t_u16 fw_hotfix_version,fw_bands;
    t_u8 fw_ecsa_enable,cmd_tx_data,sec_rgpower,fw_getlog_enable;
    int wifi_hal_flag;
    struct wiphy *wiphy;
};
typedef struct _moal_handle moal_handle;
struct _moal_private {
    moal_handle *phandle;
    BOOLEAN rtt_admission_closed;
    struct net_device *netdev;
    struct wireless_dev *wdev;
    int sched_scanning, bg_scan_start, bg_scan_reported;
    unsigned long bg_scan_reqid;
    int keep_connect, media_connected;
    t_u8 current_addr[ETH_ALEN];
#if CFG80211_VERSION_CODE >= KERNEL_VERSION(4,20,0)
    struct cfg80211_pmsr_request *pmsr_request;
#endif
};
#define mutex_init(m) assert(!pthread_mutex_init(&(m)->native,NULL))
#define mutex_lock(m) assert(!pthread_mutex_lock(&(m)->native))
#define mutex_unlock(m) assert(!pthread_mutex_unlock(&(m)->native))
#define spin_lock_irqsave(l,f) do { (f)=0; assert(!pthread_mutex_lock(l)); } while(0)
#define spin_unlock_irqrestore(l,f) do { (void)(f); assert(!pthread_mutex_unlock(l)); } while(0)
#define wake_up_interruptible(q) ((void)(q))
#define msecs_to_jiffies(v) (v)
static long host_wait(moal_handle *handle,int condition);
#define wait_event_interruptible_timeout(q,condition,timeout) ((void)(q),(void)(timeout),host_wait(handle,condition))
static int fail_next_alloc;
static void *host_zalloc(size_t size) { if(fail_next_alloc){fail_next_alloc=0;return NULL;}return calloc(1,size); }
#define kzalloc(n,g) host_zalloc(n)
#define kfree(p) free(p)
#define moal_memcpy_ext(h,d,s,n,cap) ((void)(h),assert((n)<=(cap)),memcpy(d,s,n))
#define woal_get_netdev_priv(d) ((d)->priv)
#define woal_get_wiphy_priv(w) ((w)->handle)
static wifi_rtt_config_params_t input_v1;
static wifi_rtt_config_params_v3_t input_v3;
static int queue_accept=1, queue_count, power_queries, ioctl_status;
static struct workqueue_struct host_queue;
static int auto_result=1,stop_failure,cfg_fail_peer=-1,start_fail_peer=-1;
static int started[32],start_count,stop_count,event_count,event_peers,event_version,cancel_calls;
static int wait_hook,hook_error,timeout_count,report_count,complete_count;
static s64 reported_distance,reported_rtt;
static mlan_fw_info input_fw_info;
static int fw_info_status=MLAN_STATUS_SUCCESS,fw_info_queries,cfg_count,responder_commands;
mlan_status woal_request_get_fw_info(moal_private *priv,t_u8 wait_option,mlan_fw_info *fw_info);
static void init_capabilities(moal_handle *handle);
void host_convert_ftm(t_u32 tof,wifi_rtt_result_v3 *result);
static struct cfg80211_pmsr_request *finished_request;
void woal_rtt_ap_result_received(moal_private *priv,t_u8 *data,int len);
static void emit_result(moal_private *priv,int peer);
static int woal_parse_rtt_range_request(moal_handle *h,const void *d,int n,wifi_rtt_config_params_t *p) { (void)h;(void)d;(void)n; *p=input_v1;return 0; }
static int woal_parse_rtt_range_request_v3(moal_handle *h,const void *d,int n,wifi_rtt_config_params_v3_t *p) { (void)h;(void)d;(void)n;*p=input_v3;return 0; }
#define woal_dump_rtt_params(p) ((void)(p))
#define woal_dump_rtt_params_v3(p) ((void)(p))
static bool queue_work(struct workqueue_struct *q,struct work_struct *w) { (void)q;(void)w;queue_count++;return queue_accept; }
static int woal_get_ftm_session_action(moal_private *p,t_u8 *a) { (void)p;(void)a;return 1; }
static int ieee80211_frequency_to_channel(unsigned int f) { (void)f;return 1; }
static int woal_freq_to_chanband(unsigned int f) { (void)f;return 0; }
static int fail_next_ioctl_alloc;
static mlan_ioctl_req *woal_alloc_mlan_ioctl_req(size_t n) {
    if(fail_next_ioctl_alloc){fail_next_ioctl_alloc=0;return NULL;}
    mlan_ioctl_req *r=calloc(1,sizeof(*r)+n);assert(r);r->pbuf=(t_u8 *)(r+1);return r;
}
static int woal_request_ioctl(moal_private *p,mlan_ioctl_req *r,int w);
static moal_private *woal_get_priv(moal_handle *h,int role) { (void)role;for(int i=0;i<h->priv_num;i++)if(h->priv[i])return h->priv[i];return NULL; }
static int woal_set_get_tx_power_wait(moal_private *p,int a,mlan_power_cfg_t *cfg,int w) { (void)p;(void)a;assert(w==MOAL_IOCTL_WAIT_TIMEOUT);power_queries++;cfg->power_level=17;return MLAN_STATUS_SUCCESS; }
struct device { int unused; };
typedef struct { moal_handle *handle; } sdio_mmc_card;
struct sdio_func { sdio_mmc_card *card; };
static struct sdio_func test_func;
#define dev_to_sdio_func(d) ((void)(d),&test_func)
#define sdio_get_drvdata(f) ((f)->card)
#define EXT_PARTIAL_IO 1
#define EXT_SHUTDOWN_HS 2
#define moal_extflg_isset(h,f) ((void)(h),(f)==EXT_PARTIAL_IO)
#define netif_device_detach(d) ((void)(d))
#define woal_cancel_scan(p,w) ((void)(p),(void)(w))
#define IS_STA_CFG80211(v) (v)
static int stopped_scans;
#define woal_stop_bg_scan(p,w) ((void)(p),(void)(w),stopped_scans++)
#define cfg80211_sched_scan_stopped(...) ((void)0)
#define woal_get_pm_info(p,i) ((void)(p),(i)->is_suspend_allowed=MTRUE,MLAN_STATUS_SUCCESS)
#define woal_sched_timeout(t) ((void)(t))
#define woal_enable_hs(p) ((void)(p))
#define woal_shutdown_fw(p,w) ((void)(p),(void)(w))
#define woal_disconnect(p,w,a,r) ((void)(p),(void)(w),(void)(a),(void)(r),0)
#define DEF_DEAUTH_REASON_CODE 3
#define HS_ACTIVE_TIMEOUT 1
static void init_fixture(moal_handle *h,moal_private *p,struct wiphy *w,struct wireless_dev *d,struct net_device *n) {
    memset(h,0,sizeof(*h));memset(p,0,sizeof(*p));memset(w,0,sizeof(*w));
    p->phandle=h;p->netdev=n;p->wdev=d;n->priv=p;d->netdev=n;d->wiphy=w;w->handle=h;h->wiphy=w;
    h->priv_num=1;h->priv[0]=p;h->params.cfg80211_wext=1;
    assert(!pthread_mutex_init(&h->rtt_result_lock,NULL));
    mutex_init(&h->rtt_mutex);mutex_init(&h->rtt_quiesce_mutex);h->rtt_initialized=MTRUE;h->rtt_current_index=-1;h->evt_workqueue=&host_queue;
    init_capabilities(h);
    memset(&input_fw_info,0,sizeof(input_fw_info));input_fw_info.rtt_support=1;fw_info_status=MLAN_STATUS_SUCCESS;
    assert(woal_request_get_fw_info(p,MOAL_IOCTL_WAIT,NULL)==MLAN_STATUS_SUCCESS);fw_info_queries=0;
    cfg_count=responder_commands=0;
    queue_accept=1;queue_count=0;power_queries=0;ioctl_status=MLAN_STATUS_SUCCESS;
    memset(&input_v1,0,sizeof(input_v1));memset(&input_v3,0,sizeof(input_v3));
    auto_result=1;stop_failure=0;cfg_fail_peer=-1;start_fail_peer=-1;
    start_count=stop_count=event_count=event_peers=event_version=cancel_calls=0;
    wait_hook=hook_error=timeout_count=report_count=complete_count=0;finished_request=NULL;
}
'''
extra = r'''struct nlattr { int len; void *data; };
enum { ATTR_RTT_TARGET_NUM=2,ATTR_RTT_TARGET_ADDR=4,ATTR_RTT_MAX=17 };
enum { ATTR_FEATURE_SET=2,ATTR_RTT_CAPA=8,ATTR_RTT_CAPA_V3=18,VENDOR_REPLY_OVERHEAD=16 };
struct sk_buff { unsigned char data[256];size_t len; };
static struct sk_buff reply_skb;
static int reply_alloc_fail;
static struct sk_buff *cfg80211_vendor_cmd_alloc_reply_skb(struct wiphy *w,size_t len) {
    (void)w;assert(len<=sizeof(reply_skb.data));memset(&reply_skb,0,sizeof(reply_skb));return reply_alloc_fail?NULL:&reply_skb;
}
static size_t nla_total_size(size_t n) { return n+4; }
static int nla_put(struct sk_buff *s,int attr,size_t n,const void *data) {
    (void)attr;assert(n<=sizeof(s->data));memcpy(s->data,data,n);s->len=n;return 0;
}
static int nla_put_u32(struct sk_buff *s,int attr,t_u32 v) { return nla_put(s,attr,sizeof(v),&v); }
static int cfg80211_vendor_cmd_reply(struct sk_buff *s) { assert(s==&reply_skb);return 0; }
static void kfree_skb(struct sk_buff *s) { assert(s==&reply_skb); }
struct cancel_input { t_u8 count; t_u8 peers[MAX_RTT_CONFIG_NUM][ETH_ALEN]; };
static int nla_parse(struct nlattr **tb,int max,const void *data,int len,const void *policy,...) {
    static struct nlattr count,peers;const struct cancel_input *input=data;
    (void)len;(void)policy;memset(tb,0,(max+1)*sizeof(*tb));
    count=(struct nlattr){1,(void *)&input->count};peers=(struct nlattr){input->count*ETH_ALEN,(void *)input->peers};
    tb[ATTR_RTT_TARGET_NUM]=&count;tb[ATTR_RTT_TARGET_ADDR]=&peers;return 0;
}
#define nla_get_u8(a) (*(t_u8 *)(a)->data)
#define nla_len(a) ((a)->len)
#define nla_data(a) ((a)->data)
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
static pthread_mutex_t drain_gate=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t drain_condition=PTHREAD_COND_INITIALIZER;
static int pause_cancel,drain_paused,release_drain,global_entered,global_done;
static bool cancel_work_sync(struct work_struct *work) {
    (void)work;assert(!pthread_mutex_lock(&drain_gate));cancel_calls++;
    if(pause_cancel) {
        pause_cancel=0;drain_paused=1;assert(!pthread_cond_broadcast(&drain_condition));
        while(!release_drain)assert(!pthread_cond_wait(&drain_condition,&drain_gate));
    }
    assert(!pthread_mutex_unlock(&drain_gate));return true;
}
static int woal_ftm_session_cfg(moal_private *priv,wifi_rtt_config *cfg) { (void)priv;cfg_count++;return cfg->addr[5]==cfg_fail_peer?-EFAULT:0; }
static int woal_ftm_session_cfg_ntb_ranging(moal_private *priv,wifi_rtt_config_v3 *cfg) { return woal_ftm_session_cfg(priv,&cfg->rtt_config); }
static int record_event(moal_private *priv,t_u8 *data,int len,int version) {
    (void)priv;assert(len>=1 && data[0]==1);event_count++;event_version=version;event_peers=0;
    for(int pos=1;pos<len;) { wifi_rtt_result_element e;assert(pos+(int)sizeof(e)<=len);memcpy(&e,data+pos,sizeof(e));assert(e.len>0);pos+=sizeof(e)+e.len;assert(pos<=len);event_peers++; }
    return MLAN_STATUS_SUCCESS;
}
static mlan_status woal_cfg80211_event_rtt_result(moal_private *priv,t_u8 *data,int len) { return record_event(priv,data,len,1); }
static mlan_status woal_cfg80211_event_rtt_result_v3(moal_private *priv,t_u8 *data,int len) { return record_event(priv,data,len,3); }
struct ieee80211_channel { unsigned int center_freq; };
struct cfg80211_pmsr_request_peer {
    t_u8 addr[ETH_ALEN];struct { struct ieee80211_channel *chan; } chandef;
    struct { int request_lci,request_civicloc;
#if CFG80211_VERSION_CODE >= KERNEL_VERSION(5,10,0)
        int non_trigger_based,trigger_based;
#endif
    } ftm;
};
struct cfg80211_pmsr_request { int n_peers;struct cfg80211_pmsr_request_peer peers[1]; };
enum { NL80211_PREAMBLE_LEGACY,NL80211_PREAMBLE_HT,NL80211_PREAMBLE_VHT,NL80211_PREAMBLE_HE };
enum { NL80211_CHAN_WIDTH_20_NOHT,NL80211_CHAN_WIDTH_20,NL80211_CHAN_WIDTH_40,NL80211_CHAN_WIDTH_80 };
enum { NL80211_EXT_FEATURE_ENABLE_FTM_RESPONDER };
struct cfg80211_pmsr_capabilities {
    int max_peers,report_ap_tsf,randomize_mac_addr;
    struct { int supported,asap,non_asap,request_lci,request_civicloc;
#if CFG80211_VERSION_CODE >= KERNEL_VERSION(5,10,0)
        int trigger_based,non_trigger_based;
#endif
        unsigned int preambles,bandwidths;int max_bursts_exponent,max_ftms_per_burst;
    } ftm;
};
static void wiphy_ext_feature_set(struct wiphy *w,int feature) { (void)feature;w->responder=1; }
struct cfg80211_pmsr_result {
    t_u8 addr[ETH_ALEN];int type,status;
    struct { s64 rtt_avg,dist_avg;int num_ftmr_attempts,num_ftmr_successes;
             int rtt_avg_valid,dist_avg_valid,num_ftmr_attempts_valid,num_ftmr_successes_valid; } ftm;
};
#define NL80211_PMSR_TYPE_FTM 1
#define NL80211_PMSR_STATUS_SUCCESS 0
#define NL80211_PMSR_STATUS_FAILURE 1
static void cfg80211_pmsr_report(struct wireless_dev *w,struct cfg80211_pmsr_request *req,struct cfg80211_pmsr_result *result,int gfp) {
    (void)w;(void)gfp;assert(req && req!=finished_request);report_count++;reported_distance=result->ftm.dist_avg;
    reported_rtt=result->ftm.rtt_avg;
    assert(result->ftm.rtt_avg_valid && result->ftm.dist_avg_valid && result->ftm.num_ftmr_successes==4);
}
static void cfg80211_pmsr_complete(struct wireless_dev *w,struct cfg80211_pmsr_request *req,int gfp) {
    (void)w;(void)gfp;assert(req && req!=finished_request);complete_count++;finished_request=req;
}
static int woal_get_ftm_session_action_pmsr(moal_private *p,const t_u8 *addr) { (void)p;(void)addr;return 1; }
static int woal_freq_to_chanband_pmsr(unsigned int freq) { (void)freq;return 0; }
static int woal_ftm_session_cfg_pmsr(moal_private *p,struct cfg80211_pmsr_request_peer *peer) { (void)p;cfg_count++;return peer->addr[5]==cfg_fail_peer?-EFAULT:0; }
static int woal_ftm_az_session_cfg_pmsr(moal_private *p,struct cfg80211_pmsr_request_peer *peer) { return woal_ftm_session_cfg_pmsr(p,peer); }
static int woal_request_ioctl(moal_private *p,mlan_ioctl_req *r,int wait) {
    if(r->req_id==MLAN_IOCTL_GET_INFO) {
        mlan_ds_get_info *info=(mlan_ds_get_info *)r->pbuf;assert(info->sub_command==MLAN_OID_GET_FW_INFO);
        info->param.fw_info=input_fw_info;fw_info_queries++;return fw_info_status;
    }
    if(((mlan_ds_misc_cfg *)r->pbuf)->sub_command==MLAN_OID_MISC_RTT_RESPONDER_CFG) {
        responder_commands++;return MLAN_STATUS_SUCCESS;
    }
    mlan_ds_misc_cfg *misc=(mlan_ds_misc_cfg *)r->pbuf;mlan_ftm_session_ctrl *ctrl=&misc->param.ftm_session_ctrl;
    int peer=ctrl->peer_mac[5];(void)wait;if(ioctl_status!=MLAN_STATUS_SUCCESS)return ioctl_status;
    if(ctrl->action==FTM_SESSION_CTRL_ACTION_STOP) { stop_count++;return stop_failure?MLAN_STATUS_FAILURE:MLAN_STATUS_SUCCESS; }
    started[start_count++]=peer;
    if(peer==start_fail_peer)return MLAN_STATUS_FAILURE;
    if(auto_result)emit_result(p,peer);
    return MLAN_STATUS_SUCCESS;
}
'''
test_helpers = r'''static int check(int ok,const char *message);
/* Literal expectations follow the current one-way-ps MLAN contract and the
 * cfg80211 millimetre ABI, not the expressions being tested. Firmware units
 * still require independent device/vendor qualification. */
static const struct tof_case { t_u32 tof; t_s64 rtt; int mm; } tof_cases[] = {
    {0,0,0}, {1,2,0}, {3,6,0}, {4,8,1}, {10,20,3},
    {3333,6666,999}, {10000,20000,3000},
    {4294967295U,8589934590LL,1288490188}
};
static void emit_ftm_measurement(moal_private *priv,const wifi_rtt_result_v3 *result) {
    t_u8 data[1+sizeof(wifi_rtt_result_element)+sizeof(*result)]={0};
    wifi_rtt_result_element elem={0};elem.len=sizeof(*result);
    memcpy(data+1,&elem,sizeof(elem));memcpy(data+1+sizeof(elem),result,sizeof(*result));
    woal_rtt_ap_result_received(priv,data,sizeof(data));
}
static int perform_cancel(struct wiphy *w,struct wireless_dev *d,int a,int b) {
    struct cancel_input input={0};input.count=b?2:1;input.peers[0][0]=2;input.peers[0][5]=a;
    if(b){input.peers[1][0]=2;input.peers[1][5]=b;}
    return woal_cfg80211_subcmd_rtt_range_cancel(w,d,&input,sizeof(input));
}
static void emit_result(moal_private *priv,int peer) {
    t_u8 data[1+sizeof(wifi_rtt_result_element)+sizeof(wifi_rtt_result_v3)]={0};
    wifi_rtt_result_element elem={0};wifi_rtt_result_v3 result={0};elem.len=sizeof(result);
    result.rtt_result_v2.rtt_result.addr[0]=2;result.rtt_result_v2.rtt_result.addr[5]=peer;
    result.rtt_result_v2.rtt_result.rtt=123;result.rtt_result_v2.rtt_result.distance_mm=25;
    result.rtt_result_v2.rtt_result.success_number=4;
    memcpy(data+1,&elem,sizeof(elem));memcpy(data+1+sizeof(elem),&result,sizeof(result));
    woal_rtt_ap_result_received(priv,data,sizeof(data));
}
static long host_wait(moal_handle *h,int condition) {
    if(condition)return 1;
    int hook=wait_hook;wait_hook=0;
    if(hook) {
        assert(!pthread_mutex_trylock(&h->rtt_mutex.native));mutex_unlock(&h->rtt_mutex);
        moal_private *p=h->rtt_priv;
        if(hook==1 || hook==2 || hook==3) {
            int err=perform_cancel(p->wdev->wiphy,p->wdev,hook==2?2:1,0);
            hook_error+=check(err==(hook==3?-EFAULT:0),"active/pending cancellation return value");
            if(hook==3)hook_error+=check(h->ftm_session_in_progress && h->rtt_target_state[0]==RTT_TARGET_ACTIVE,"failed STOP retains active peer");
            if(hook==2){auto_result=1;emit_result(p,1);}
            if(hook==1)auto_result=1;
        } else if(hook==4) {
            emit_result(p,9);
            hook_error+=check(!h->ftm_result_wait_q_woken && !h->rtt_completed_ap_count,"unrelated event neither counts nor wakes");
            emit_result(p,1);emit_result(p,1);auto_result=1;
            hook_error+=check(h->rtt_completed_ap_count==1,"duplicate event ignored");
        }
    }
    if(!h->ftm_result_wait_q_woken)timeout_count++;
    return h->ftm_result_wait_q_woken?1:0;
}
static void seed_targets(int version,int count) {
    (void)version;
    input_v1.rtt_config_num=count;input_v3.rtt_config_num=count;
    for(int i=0;i<count;i++) {
        wifi_rtt_config *cfg=&input_v1.rtt_config[i];cfg->addr[0]=2;cfg->addr[5]=i+1;
        cfg->type=RTT_TYPE_2_SIDED_11MC;cfg->channel.center_freq=5180;cfg->bw=WIFI_RTT_BW_80;cfg->preamble=WIFI_RTT_PREAMBLE_VHT;
        input_v3.rtt_config_v3[i].rtt_config=*cfg;input_v3.rtt_config_v3[i].ntb_max_measurement_time=987654;
    }
}
static int submit_targets(struct wiphy *w,struct wireless_dev *d,int version,int count) {
    seed_targets(version,count);
    return version==3?woal_cfg80211_subcmd_rtt_range_request_v3(w,d,&input_v3,sizeof(input_v3)):
                       woal_cfg80211_subcmd_rtt_range_request(w,d,&input_v1,sizeof(input_v1));
}
'''
concurrency_helpers = r'''struct concurrent_request {
    struct wiphy *w;struct wireless_dev *d;pthread_barrier_t *barrier;int version,result;
};
static void *submit_concurrently(void *argument) {
    struct concurrent_request *c=argument;int rv=pthread_barrier_wait(c->barrier);assert(rv==0 || rv==PTHREAD_BARRIER_SERIAL_THREAD);
    c->result=c->version==3?woal_cfg80211_subcmd_rtt_range_request_v3(c->w,c->d,&input_v3,sizeof(input_v3)):
                          woal_cfg80211_subcmd_rtt_range_request(c->w,c->d,&input_v1,sizeof(input_v1));
    return NULL;
}
'''
drain_helpers = r'''struct quiesce_request { moal_handle *handle;moal_private *owner; };
static void *quiesce_concurrently(void *argument) {
    struct quiesce_request *q=argument;
    if(!q->owner) {
        assert(!pthread_mutex_lock(&drain_gate));global_entered=1;
        assert(!pthread_cond_broadcast(&drain_condition));assert(!pthread_mutex_unlock(&drain_gate));
    }
    woal_rtt_quiesce(q->handle,q->owner);
    if(!q->owner) {
        assert(!pthread_mutex_lock(&drain_gate));global_done=1;
        assert(!pthread_cond_broadcast(&drain_condition));assert(!pthread_mutex_unlock(&drain_gate));
    }
    return NULL;
}
'''
tests = r'''static int check(int ok,const char *message) { if(!ok)fprintf(stderr,"FAIL %s\n",message);return !ok; }
int main(int argc,char **argv) {
    moal_handle h;moal_private p;struct wiphy w;struct wireless_dev d;struct net_device n;
    int fail=0;assert(argc==2);init_fixture(&h,&p,&w,&d,&n);
    if(!strcmp(argv[1],"reset-wiphy-capabilities")) {
        fail+=check(!woal_rtt_wiphy_changed(&h) || CFG80211_VERSION_CODE>=KERNEL_VERSION(4,20,0),"old kernels do not inspect PMSR capability");
#if CFG80211_VERSION_CODE >= KERNEL_VERSION(4,20,0)
        for(int old=0;old<2;old++)for(int fresh=0;fresh<2;fresh++) {
            w.pmsr_capa=old?&nxp_pmsr_capa:NULL;input_fw_info.rtt_support=fresh;
            assert(woal_request_get_fw_info(&p,MOAL_IOCTL_WAIT,NULL)==MLAN_STATUS_SUCCESS);
            fail+=check(woal_rtt_wiphy_changed(&h)==(old!=fresh),"capability change requires wiphy rebuild in either direction");
        }
        h.wiphy=NULL;fail+=check(!woal_rtt_wiphy_changed(&h),"absent wiphy needs no extra teardown");
#endif
    } else if(!strcmp(argv[1],"capability-supported") || !strcmp(argv[1],"capability-unsupported") || !strcmp(argv[1],"capability-query-failed")) {
        int supported=!strcmp(argv[1],"capability-supported");input_fw_info.rtt_support=supported;
        if(!strcmp(argv[1],"capability-query-failed"))fw_info_status=MLAN_STATUS_FAILURE;
        int ret=woal_cfg80211_subcmd_get_supp_feature_set(&w,&d,NULL,0);t_u32 features=0;
        if(fw_info_status==MLAN_STATUS_SUCCESS) {
            memcpy(&features,reply_skb.data,sizeof(features));
            fail+=check(!ret && !!(features&WLAN_FEATURE_D2AP_RTT)==supported,"D2AP feature follows firmware RTT bit");
        } else fail+=check(ret==-EFAULT,"failed FW-info query propagates error");
        int queries=fw_info_queries;
        fail+=check(!woal_cfg80211_subcmd_rtt_get_capa(&w,&d,NULL,0),"v1 capability query succeeds");
        wifi_rtt_capabilities v1;assert(reply_skb.len==sizeof(v1));memcpy(&v1,reply_skb.data,sizeof(v1));
        fail+=check(v1.rtt_ftm_supported==supported,"legacy capability follows firmware RTT bit");
        fail+=check(!v1.rtt_one_sided_supported && !v1.responder_supported && !v1.lci_support && !v1.lcr_support,"unqualified optional modes stay unadvertised");
        fail+=check(v1.preamble_support==(supported?7:0) && v1.bw_support==(supported?28:0),"legacy preambles and bandwidths gated together");
        fail+=check(!woal_cfg80211_subcmd_rtt_get_capa_v3(&w,&d,NULL,0),"v3 capability query succeeds");
        wifi_rtt_capabilities_v3 v3;assert(reply_skb.len==sizeof(v3));memcpy(&v3,reply_skb.data,sizeof(v3));
        fail+=check(!memcmp(&v3.rtt_capab,&v1,sizeof(v1)),"v3 preserves qualified legacy capability");
        fail+=check(!v3.az_preamble_support && !v3.az_bw_support && !v3.ntb_initiator_supported && !v3.ntb_responder_supported,"11az/NTB remain unadvertised without firmware evidence");
        fail+=check(queries==fw_info_queries,"capability queries do not refresh firmware MAC state");
    } else if(!strcmp(argv[1],"capability-allocation-failed")) {
        reply_alloc_fail=1;
        fail+=check(woal_cfg80211_subcmd_rtt_get_capa(&w,&d,NULL,0)==-ENOMEM,"v1 capability allocation failure returns ENOMEM");
        fail+=check(woal_cfg80211_subcmd_rtt_get_capa_v3(&w,&d,NULL,0)==-ENOMEM,"v3 capability allocation failure returns ENOMEM");
    } else if(!strcmp(argv[1],"unsupported-fw-v1") || !strcmp(argv[1],"unsupported-fw-v3") || !strcmp(argv[1],"withdrawn-fw-worker")) {
        int version=!strcmp(argv[1],"unsupported-fw-v3")?3:1;
        if(!strcmp(argv[1],"withdrawn-fw-worker"))fail+=check(!submit_targets(&w,&d,version,1),"supported firmware accepts queued RTT");
        input_fw_info.rtt_support=0;assert(woal_request_get_fw_info(&p,MOAL_IOCTL_WAIT,NULL)==MLAN_STATUS_SUCCESS);
        if(!strcmp(argv[1],"withdrawn-fw-worker"))woal_rtt_work_handler(&h.rtt_work);
        else fail+=check(submit_targets(&w,&d,version,1)==-EOPNOTSUPP && !queue_count,"unsupported firmware never queues RTT");
        fail+=check(h.rtt_owner==RTT_OWNER_IDLE && !cfg_count && !start_count,"unsupported firmware owns no session and receives no configuration or START");
    } else if(!strcmp(argv[1],"fw-info-allocation-failed")) {
        fail_next_ioctl_alloc=1;
        fail+=check(woal_request_get_fw_info(&p,MOAL_IOCTL_WAIT,NULL)==MLAN_STATUS_FAILURE,"FW-info allocation failure returns safely");
        fail+=check(submit_targets(&w,&d,1,1)==-EOPNOTSUPP && !queue_count,"failed FW-info allocation invalidates cached support");
    } else if(!strcmp(argv[1],"invalid-enums-v1") || !strcmp(argv[1],"invalid-enums-v3")) {
        int version=!strcmp(argv[1],"invalid-enums-v3")?3:1;
        for(int option=0;option<6;option++) {
            seed_targets(version,1);wifi_rtt_config *cfg=version==3?&input_v3.rtt_config_v3[0].rtt_config:&input_v1.rtt_config[0];
            if(option==0)cfg->preamble=0;
            if(option==1)cfg->preamble=WIFI_RTT_PREAMBLE_LEGACY|WIFI_RTT_PREAMBLE_HT;
            if(option==2)cfg->bw=0;
            if(option==3)cfg->bw=WIFI_RTT_BW_20|WIFI_RTT_BW_40;
            if(option==4)cfg->preamble=WIFI_RTT_PREAMBLE_HT;
            if(option==5){cfg->preamble=WIFI_RTT_PREAMBLE_LEGACY;cfg->bw=WIFI_RTT_BW_40;}
            int ret=version==3?woal_cfg80211_subcmd_rtt_range_request_v3(&w,&d,&input_v3,sizeof(input_v3)):
                               woal_cfg80211_subcmd_rtt_range_request(&w,&d,&input_v1,sizeof(input_v1));
            fail+=check(ret==-EOPNOTSUPP && !queue_count && h.rtt_owner==RTT_OWNER_IDLE,"zero/combined enums or unsupported pairings cannot publish a session");
            if(h.rtt_owner!=RTT_OWNER_IDLE){woal_rtt_work_handler(&h.rtt_work);queue_count=0;}
        }
    } else if(!strcmp(argv[1],"supported-enums-v1") || !strcmp(argv[1],"supported-enums-v3")) {
        int version=!strcmp(argv[1],"supported-enums-v3")?3:1;
        for(int preamble=1;preamble<=4;preamble*=2)for(int bw=4;bw<=16;bw*=2) {
            if((preamble==1 && bw!=4) || (preamble==2 && bw==16))continue;
            seed_targets(version,1);wifi_rtt_config *cfg=version==3?&input_v3.rtt_config_v3[0].rtt_config:&input_v1.rtt_config[0];cfg->preamble=preamble;cfg->bw=bw;
            int ret=version==3?woal_cfg80211_subcmd_rtt_range_request_v3(&w,&d,&input_v3,sizeof(input_v3)):
                               woal_cfg80211_subcmd_rtt_range_request(&w,&d,&input_v1,sizeof(input_v1));
            fail+=check(!ret && h.rtt_owner==RTT_OWNER_VENDOR,"supported legacy/HT/VHT and bandwidth pairings admitted");
            woal_rtt_work_handler(&h.rtt_work);fail+=check(h.rtt_owner==RTT_OWNER_IDLE,"supported session completes");
        }
    } else if(!strcmp(argv[1],"unqueried-fw")) {
        init_capabilities(&h);
        fail+=check(submit_targets(&w,&d,1,1)==-EOPNOTSUPP && !queue_count,"unqueried firmware defaults to unsupported");
        fail+=check(!woal_cfg80211_subcmd_rtt_get_capa_v3(&w,&d,NULL,0),"unqueried firmware returns capability response");
        wifi_rtt_capabilities_v3 empty={0};
        fail+=check(reply_skb.len==sizeof(empty) && !memcmp(reply_skb.data,&empty,sizeof(empty)),"unqueried firmware exposes zero capability bytes");
    } else if(!strcmp(argv[1],"unsupported-options-v1") || !strcmp(argv[1],"unsupported-options-v3")) {
        int version=!strcmp(argv[1],"unsupported-options-v3")?3:1;
        for(int option=0;option<4;option++) {
            seed_targets(version,1);wifi_rtt_config *cfg=version==3?&input_v3.rtt_config_v3[0].rtt_config:&input_v1.rtt_config[0];
            cfg->preamble=option==0?WIFI_RTT_PREAMBLE_HE:WIFI_RTT_PREAMBLE_VHT;
            cfg->bw=option==1?BW_160_SUPPORT:WIFI_RTT_BW_80;cfg->LCI_request=option==2;cfg->LCR_request=option==3;
            int ret=version==3?woal_cfg80211_subcmd_rtt_range_request_v3(&w,&d,&input_v3,sizeof(input_v3)):
                               woal_cfg80211_subcmd_rtt_range_request(&w,&d,&input_v1,sizeof(input_v1));
            fail+=check(ret==-EOPNOTSUPP && !queue_count && h.rtt_owner==RTT_OWNER_IDLE,"unqualified HE/bandwidth/location options cannot publish a session");
        }
    } else if(!strcmp(argv[1],"unsupported-protocol-v1") || !strcmp(argv[1],"unsupported-protocol-v3")) {
        int version=!strcmp(argv[1],"unsupported-protocol-v3")?3:1;
        seed_targets(version,2);
        for(int type=RTT_TYPE_1_SIDED;type<=RTT_TYPE_2_SIDED_11AZ_NTB;type++) {
            if(type==RTT_TYPE_2_SIDED_11MC)continue;
            input_v1.rtt_config[1].type=type;input_v3.rtt_config_v3[1].rtt_config.type=type;
            int ret=version==3?woal_cfg80211_subcmd_rtt_range_request_v3(&w,&d,&input_v3,sizeof(input_v3)):
                               woal_cfg80211_subcmd_rtt_range_request(&w,&d,&input_v1,sizeof(input_v1));
            fail+=check(ret==-EOPNOTSUPP && !queue_count && h.rtt_owner==RTT_OWNER_IDLE,"mixed unsupported target rejected before publishing any target");
            if(h.rtt_owner!=RTT_OWNER_IDLE)woal_rtt_quiesce(&h,&p);
        }
    } else if(!strcmp(argv[1],"responder-unqualified") || !strcmp(argv[1],"responder-unsupported-fw")) {
        if(!strcmp(argv[1],"responder-unsupported-fw")) {
            input_fw_info.rtt_support=0;assert(woal_request_get_fw_info(&p,MOAL_IOCTL_WAIT,NULL)==MLAN_STATUS_SUCCESS);
        }
        mlan_rtt_responder responder={0};responder.action=RTT_SET_RESPONDER_ENABLE;
        fail+=check(woal_rtt_responder_cfg(&p,MOAL_IOCTL_WAIT,&responder)==MLAN_STATUS_FAILURE && !responder_commands,"unqualified responder cannot issue firmware enable");
        responder.action=RTT_SET_RESPONDER_DISABLE;
        fail+=check(woal_rtt_responder_cfg(&p,MOAL_IOCTL_WAIT,&responder)==MLAN_STATUS_SUCCESS && responder_commands==1,"responder cleanup remains available");
#if CFG80211_VERSION_CODE >= KERNEL_VERSION(4,20,0)
    } else if(!strcmp(argv[1],"pmsr-capability-supported") || !strcmp(argv[1],"pmsr-capability-unsupported")) {
        int supported=!strcmp(argv[1],"pmsr-capability-supported");input_fw_info.rtt_support=supported;
        init_pmsr_capabilities(&w,&input_fw_info);
        fail+=check(!!w.pmsr_capa==supported && !w.responder,"PMSR follows firmware RTT bit and does not claim responder");
        if(w.pmsr_capa) {
            const struct cfg80211_pmsr_capabilities *c=w.pmsr_capa;
            fail+=check(c->ftm.preambles==7 && !c->report_ap_tsf && !c->ftm.request_lci && !c->ftm.request_civicloc,"PMSR advertises only implemented legacy result fields");
#if CFG80211_VERSION_CODE >= KERNEL_VERSION(5,10,0)
            fail+=check(!c->ftm.trigger_based && !c->ftm.non_trigger_based,"PMSR does not claim unqualified TB/NTB");
#endif
        }
    } else if(!strcmp(argv[1],"pmsr-unsupported-fw") || !strcmp(argv[1],"pmsr-unsupported-optional") || !strcmp(argv[1],"pmsr-unsupported-az")) {
        struct ieee80211_channel channel={5180};struct cfg80211_pmsr_request req={0};req.n_peers=1;req.peers[0].chandef.chan=&channel;
        if(!strcmp(argv[1],"pmsr-unsupported-fw")) {
            input_fw_info.rtt_support=0;assert(woal_request_get_fw_info(&p,MOAL_IOCTL_WAIT,NULL)==MLAN_STATUS_SUCCESS);
        } else if(!strcmp(argv[1],"pmsr-unsupported-optional"))req.peers[0].ftm.request_lci=1;
#if CFG80211_VERSION_CODE >= KERNEL_VERSION(5,10,0)
        else req.peers[0].ftm.non_trigger_based=1;
#else
        else return 2;
#endif
        fail+=check(woal_cfg80211_start_pmsr(&w,&d,&req)==-EOPNOTSUPP,"unsupported PMSR request returns EOPNOTSUPP");
        fail+=check(h.rtt_owner==RTT_OWNER_IDLE && !p.pmsr_request && !cfg_count && !start_count,"unsupported PMSR cannot publish owner or issue firmware commands");
        if(!strcmp(argv[1],"pmsr-unsupported-optional")) {
            req.peers[0].ftm.request_lci=0;req.peers[0].ftm.request_civicloc=1;
            fail+=check(woal_cfg80211_start_pmsr(&w,&d,&req)==-EOPNOTSUPP && !cfg_count && !start_count,"unqualified civic-location request cannot reach firmware");
        }
#if CFG80211_VERSION_CODE >= KERNEL_VERSION(5,10,0)
        if(!strcmp(argv[1],"pmsr-unsupported-az")) {
            req.peers[0].ftm.non_trigger_based=0;req.peers[0].ftm.trigger_based=1;
            fail+=check(woal_cfg80211_start_pmsr(&w,&d,&req)==-EOPNOTSUPP && !cfg_count && !start_count,"unqualified TB request cannot reach firmware");
        }
#endif
#endif
    } else if(!strcmp(argv[1],"vendor-distance-units")) {
        for(size_t i=0;i<sizeof(tof_cases)/sizeof(tof_cases[0]);i++) {
            wifi_rtt_result_v3 converted={0};host_convert_ftm(tof_cases[i].tof,&converted);
            wifi_rtt_result *value=&converted.rtt_result_v2.rtt_result;
            fail+=check(value->rtt==tof_cases[i].rtt,"production MLAN converts ToF to RTT in ps");
            fail+=check(value->distance_mm==tof_cases[i].mm,"production vendor result is in mm, including u32 maximum");
        }
    } else if(!strcmp(argv[1],"v1-copy")) {
        for(int count=1;count<=MAX_RTT_CONFIG_NUM;count+=MAX_RTT_CONFIG_NUM-1) {
            seed_targets(1,count);input_v1.rtt_config[count-1].bw=WIFI_RTT_BW_80;
            fail+=check(!woal_cfg80211_subcmd_rtt_range_request(&w,&d,&input_v1,sizeof(input_v1)),"v1 request accepted");
            fail+=check(h.rtt_params.rtt_config[count-1].bw==WIFI_RTT_BW_80,"v1 last peer bandwidth preserved");
            assert(!pthread_mutex_destroy(&h.rtt_result_lock));assert(!pthread_mutex_destroy(&h.rtt_mutex.native));assert(!pthread_mutex_destroy(&h.rtt_quiesce_mutex.native));
            init_fixture(&h,&p,&w,&d,&n);
        }
    } else if(!strcmp(argv[1],"v3-copy")) {
        for(int count=1;count<=MAX_RTT_CONFIG_NUM;count+=MAX_RTT_CONFIG_NUM-1) {
            seed_targets(3,count);input_v3.rtt_config_v3[count-1].ntb_max_measurement_time=987654;
            fail+=check(!woal_cfg80211_subcmd_rtt_range_request_v3(&w,&d,&input_v3,sizeof(input_v3)),"v3 request accepted");
            fail+=check(h.rtt_params_v3.rtt_config_v3[count-1].ntb_max_measurement_time==987654,"v3 last peer NTB timing preserved");
            assert(!pthread_mutex_destroy(&h.rtt_result_lock));assert(!pthread_mutex_destroy(&h.rtt_mutex.native));assert(!pthread_mutex_destroy(&h.rtt_quiesce_mutex.native));
            init_fixture(&h,&p,&w,&d,&n);
        }
    } else if(!strcmp(argv[1],"failed-start")) {
        t_u8 peer[ETH_ALEN]={2};ioctl_status=MLAN_STATUS_FAILURE;
        fail+=check(woal_ftm_session_ctrl(&p,peer,5180,FTM_SESSION_CTRL_ACTION_START)<0,"failed START returns error");
        fail+=check(!h.ftm_session_in_progress,"failed START keeps FTM inactive");
    } else if(!strcmp(argv[1],"tx-power")) {
        int dbm=99;h.ftm_session_in_progress=MTRUE;
        fail+=check(woal_cfg80211_get_tx_power(&w,&d,&dbm)==-EBUSY,"active FTM returns busy for TX-power query");
        fail+=check(dbm==99 && !power_queries,"busy query preserves output without issuing firmware command");
        h.ftm_session_in_progress=MFALSE;
        fail+=check(!woal_cfg80211_get_tx_power(&w,&d,&dbm) && dbm==17 && power_queries==1,"idle query returns firmware power");
    } else if(!strcmp(argv[1],"sparse-shutdown")) {
        struct device dev={0};sdio_mmc_card card={&h};test_func.card=&card;
        h.priv_num=3;h.priv[0]=NULL;h.priv[2]=NULL;p.sched_scanning=1;h.priv[1]=&p;
        woal_sdio_shutdown(&dev);
        fail+=check(stopped_scans==1 && !p.sched_scanning,"partial-I/O skips removed slots and stops live scan");
    } else if(!strcmp(argv[1],"overlap")) {
        seed_targets(1,1);input_v1.rtt_config[0].bw=WIFI_RTT_BW_80;
        fail+=check(!woal_cfg80211_subcmd_rtt_range_request(&w,&d,&input_v1,sizeof(input_v1)),"initial request accepted");
        queue_accept=0;
        fail+=check(woal_cfg80211_subcmd_rtt_range_request_v3(&w,&d,&input_v3,sizeof(input_v3))==-EBUSY,"overlapping v3 request rejected");
        fail+=check(h.rtt_version==1 && h.rtt_params.rtt_config[0].bw==WIFI_RTT_BW_80 && queue_count==1,"active parameters and dispatch remain unchanged");
    } else if(!strcmp(argv[1],"partial-v1") || !strcmp(argv[1],"partial-v3")) {
        int version=!strcmp(argv[1],"partial-v3")?3:1;
        fail+=check(!submit_targets(&w,&d,version,3),"three-peer request accepted");
        fail+=check(!perform_cancel(&w,&d,2,0),"pending middle peer cancelled");
        fail+=check(!cancel_calls,"partial cancellation preserves shared work");
        woal_rtt_work_handler(&h.rtt_work);
        fail+=check(start_count==2 && started[0]==1 && started[1]==3,"uncancelled peers execute in order");
        fail+=check(event_count==1 && event_peers==2 && event_version==version,"one completion contains remaining peers");
        fail+=check(h.rtt_owner==RTT_OWNER_IDLE && !h.ftm_session_in_progress,"completed session releases ownership");
    } else if(!strcmp(argv[1],"active-cancel") || !strcmp(argv[1],"pending-during-wait")) {
        fail+=check(!submit_targets(&w,&d,3,3),"request accepted");auto_result=0;
        wait_hook=!strcmp(argv[1],"active-cancel")?1:2;woal_rtt_work_handler(&h.rtt_work);
        if(!strcmp(argv[1],"active-cancel"))fail+=check(stop_count==1 && start_count==3 && event_peers==2,"active cancellation stops only selected peer");
        else fail+=check(stop_count==0 && start_count==2 && started[1]==3 && event_peers==2,"cancelling pending peer leaves active peer untouched");
        fail+=check(!hook_error && event_count==1,"cancellation completes once without losing other work");
    } else if(!strcmp(argv[1],"cancel-errors")) {
        fail+=check(!submit_targets(&w,&d,3,3),"request accepted");
        fail+=check(perform_cancel(&w,&d,9,0)==-ENOENT,"unmatched cancellation returns error");
        fail+=check(!perform_cancel(&w,&d,2,2),"duplicate cancellation handled once");
        woal_rtt_work_handler(&h.rtt_work);
        fail+=check(start_count==2 && started[0]==1 && started[1]==3 && event_peers==2 && event_count==1,"unmatched/duplicate selection preserves other peers");
    } else if(!strcmp(argv[1],"cancel-all")) {
        fail+=check(!submit_targets(&w,&d,1,2),"request accepted");fail+=check(!perform_cancel(&w,&d,1,2),"all pending peers cancelled");
        woal_rtt_work_handler(&h.rtt_work);fail+=check(!start_count && event_count==1 && !event_peers && h.rtt_owner==RTT_OWNER_IDLE,"all-cancelled session completes with zero results");
    } else if(!strcmp(argv[1],"failed-stop") || !strcmp(argv[1],"timeout-stop-failed")) {
        fail+=check(!submit_targets(&w,&d,3,2),"request accepted");auto_result=0;stop_failure=1;
        if(!strcmp(argv[1],"failed-stop"))wait_hook=3;
        woal_rtt_work_handler(&h.rtt_work);
        fail+=check(!hook_error && start_count==1 && event_count==1 && !event_peers,"uncertain firmware prevents next peer");
        fail+=check(h.rtt_owner==RTT_OWNER_VENDOR && h.ftm_session_in_progress,"failed STOP retains busy ownership");
        fail+=check(submit_targets(&w,&d,1,1)==-EBUSY,"new request rejected while firmware state uncertain");
        emit_result(&p,9);fail+=check(h.rtt_owner==RTT_OWNER_VENDOR,"unrelated late result cannot release busy");
        emit_result(&p,1);fail+=check(h.rtt_owner==RTT_OWNER_IDLE && !h.ftm_session_in_progress && event_count==1,"matching late completion releases busy without duplicate report");
    } else if(!strcmp(argv[1],"timeout-stop")) {
        fail+=check(!submit_targets(&w,&d,1,2),"request accepted");auto_result=0;woal_rtt_work_handler(&h.rtt_work);
        fail+=check(start_count==2 && stop_count==2 && timeout_count==2 && event_count==1 && !event_peers,"timeout stops each firmware session before advancing");
        fail+=check(h.rtt_owner==RTT_OWNER_IDLE && !h.ftm_session_in_progress,"timeouts release confirmed-idle session");
    } else if(!strcmp(argv[1],"early-results") || !strcmp(argv[1],"event-filter")) {
        fail+=check(!submit_targets(&w,&d,3,2),"request accepted");
        if(!strcmp(argv[1],"event-filter")){auto_result=0;wait_hook=4;}
        woal_rtt_work_handler(&h.rtt_work);
        fail+=check(!hook_error && !stop_count && !timeout_count && event_count==1 && event_peers==2,"early/unrelated/duplicate results preserve wake and completion");
    } else if(!strcmp(argv[1],"config-failure") || !strcmp(argv[1],"start-failure-worker")) {
        fail+=check(!submit_targets(&w,&d,3,3),"request accepted");
        if(!strcmp(argv[1],"config-failure"))cfg_fail_peer=3;else start_fail_peer=3;
        woal_rtt_work_handler(&h.rtt_work);
        fail+=check(event_count==1 && event_peers==2 && h.rtt_owner==RTT_OWNER_IDLE && !h.ftm_session_in_progress,"last-peer failure completes earlier results once");
    } else if(!strcmp(argv[1],"worker-allocation-failure")) {
        fail+=check(!submit_targets(&w,&d,1,1),"request accepted");fail_next_alloc=1;
        woal_rtt_work_handler(&h.rtt_work);
        fail+=check(!start_count && event_count==1 && !event_peers && h.rtt_owner==RTT_OWNER_IDLE,"worker allocation failure completes without starting firmware");
    } else if(!strcmp(argv[1],"queue-failure")) {
        queue_accept=0;fail+=check(submit_targets(&w,&d,1,1)==-EBUSY,"queue failure returned to caller");
        fail+=check(h.rtt_owner==RTT_OWNER_IDLE && h.rtt_priv==NULL,"queue failure releases unpublished work");
#if CFG80211_VERSION_CODE >= KERNEL_VERSION(4,20,0)
    } else if(!strcmp(argv[1],"pmsr-distance-units")) {
        struct ieee80211_channel channel={5180};struct cfg80211_pmsr_request req={0};
        req.n_peers=1;req.peers[0].addr[0]=2;req.peers[0].addr[5]=1;req.peers[0].chandef.chan=&channel;
        auto_result=0;
        for(size_t i=0;i<sizeof(tof_cases)/sizeof(tof_cases[0]);i++) {
            wifi_rtt_result_v3 converted={0};host_convert_ftm(tof_cases[i].tof,&converted);
            finished_request=NULL;
            fail+=check(!woal_cfg80211_start_pmsr(&w,&d,&req),"known-value PMSR request accepted");
            emit_ftm_measurement(&p,&converted);woal_rtt_pmsr_work_handler(&h.rtt_pmsr_work);
            fail+=check(reported_rtt==tof_cases[i].rtt,"production PMSR retains RTT in ps");
            fail+=check(reported_distance==tof_cases[i].mm,"production PMSR reports millimetres without a fixed-point scale");
            fail+=check(report_count==(int)i+1 && complete_count==(int)i+1,"one report and completion for each known input");
        }
    } else if(!strncmp(argv[1],"pmsr-",5)) {
        struct ieee80211_channel channel={5180};struct cfg80211_pmsr_request req={0},wrong={0};
        req.n_peers=1;req.peers[0].addr[0]=2;req.peers[0].addr[5]=1;req.peers[0].chandef.chan=&channel;
        if(!strcmp(argv[1],"pmsr-overlap")) {
            fail+=check(!submit_targets(&w,&d,1,1),"vendor accepted");
            fail+=check(woal_cfg80211_start_pmsr(&w,&d,&req)==-EBUSY && p.pmsr_request==NULL && h.rtt_version==1,"PMSR cannot replace vendor owner");
        } else {
            auto_result=strcmp(argv[1],"pmsr-vendor-overlap")!=0 && strcmp(argv[1],"pmsr-failed-abort")!=0;
            if(!strcmp(argv[1],"pmsr-failed-start"))start_fail_peer=1;
            int ret=woal_cfg80211_start_pmsr(&w,&d,&req);
            if(!strcmp(argv[1],"pmsr-failed-start")) {
                fail+=check(ret<0 && p.pmsr_request==NULL && h.rtt_owner==RTT_OWNER_IDLE && !h.ftm_session_in_progress,"failed PMSR START withdraws ownership");
            } else {
                fail+=check(!ret,"PMSR request accepted");
                fail+=check(submit_targets(&w,&d,3,1)==-EBUSY,"vendor cannot replace PMSR owner");
                if(!strcmp(argv[1],"pmsr-report")) {
                    woal_rtt_pmsr_work_handler(&h.rtt_pmsr_work);woal_cfg80211_abort_pmsr(&w,&d,&req);
                    fail+=check(report_count==1 && complete_count==1 && reported_distance==25 && reported_rtt==123 && !stop_count,"deferred PMSR reports mm once and completed abort is no-op");
                } else {
                    woal_cfg80211_abort_pmsr(&w,&d,&wrong);
                    fail+=check(p.pmsr_request==&req,"unmatched abort does not detach live request");
                    if(!strcmp(argv[1],"pmsr-failed-abort") || !strcmp(argv[1],"pmsr-completed-abort"))stop_failure=1;
                    woal_cfg80211_abort_pmsr(&w,&d,&req);woal_rtt_pmsr_work_handler(&h.rtt_pmsr_work);
                    fail+=check(!report_count && !complete_count && p.pmsr_request==NULL,"aborted PMSR never reports detached request");
                    if(!strcmp(argv[1],"pmsr-failed-abort")) {
                        fail+=check(h.rtt_owner==RTT_OWNER_PMSR && h.ftm_session_in_progress,"failed abort keeps firmware busy");
                        emit_result(&p,1);
                    }
                }
                fail+=check(h.rtt_owner==RTT_OWNER_IDLE && !h.ftm_session_in_progress,"PMSR terminal transition releases ownership");
            }
        }
#endif
    } else if(!strcmp(argv[1],"quiesce") || !strcmp(argv[1],"interface-quiesce")) {
        fail+=check(!submit_targets(&w,&d,1,2),"request accepted");
        woal_rtt_quiesce(&h,!strcmp(argv[1],"interface-quiesce")?&p:NULL);
        fail+=check(cancel_calls==2 && h.rtt_owner==RTT_OWNER_IDLE && h.rtt_priv==NULL,"quiesce drains both work items and detaches owner");
        if(!strcmp(argv[1],"quiesce"))fail+=check(submit_targets(&w,&d,1,1)==-ENODEV,"global teardown closes admission");
        else {
            moal_private other={0};struct wireless_dev od={0};struct net_device on={0};
            fail+=check(submit_targets(&w,&d,1,1)==-ENODEV,"departing interface stays fenced after drain");
            other.phandle=&h;other.netdev=&on;other.wdev=&od;on.priv=&other;od.netdev=&on;od.wiphy=&w;
            fail+=check(!submit_targets(&w,&od,1,1),"interface-only teardown leaves another interface usable");
        }
    } else if(!strcmp(argv[1],"concurrent-request")) {
        pthread_barrier_t barrier;pthread_t threads[2];seed_targets(3,1);assert(!pthread_barrier_init(&barrier,NULL,2));
        struct concurrent_request c[2]={{&w,&d,&barrier,1,123},{&w,&d,&barrier,3,123}};
        for(int i=0;i<2;i++)assert(!pthread_create(&threads[i],NULL,submit_concurrently,&c[i]));
        for(int i=0;i<2;i++)assert(!pthread_join(threads[i],NULL));
        fail+=check((!c[0].result && c[1].result==-EBUSY) || (!c[1].result && c[0].result==-EBUSY),"exactly one simultaneous request owns RTT");
        fail+=check(queue_count==1 && h.rtt_version==(!c[0].result?1:3),"only winning request publishes and queues");
        woal_rtt_work_handler(&h.rtt_work);fail+=check(event_count==1 && event_peers==1,"concurrent publication finishes once");
        assert(!pthread_barrier_destroy(&barrier));
    } else if(!strcmp(argv[1],"concurrent-quiesce")) {
        pthread_t threads[2];struct quiesce_request q[2]={{&h,&p},{&h,NULL}};
        fail+=check(!submit_targets(&w,&d,1,1),"request accepted");pause_cancel=1;
        assert(!pthread_create(&threads[0],NULL,quiesce_concurrently,&q[0]));
        assert(!pthread_mutex_lock(&drain_gate));
        while(!drain_paused)assert(!pthread_cond_wait(&drain_condition,&drain_gate));
        assert(!pthread_mutex_unlock(&drain_gate));
        assert(!pthread_create(&threads[1],NULL,quiesce_concurrently,&q[1]));
        assert(!pthread_mutex_lock(&drain_gate));
        while(!global_entered)assert(!pthread_cond_wait(&drain_condition,&drain_gate));
        struct timespec until;assert(!clock_gettime(CLOCK_REALTIME,&until));until.tv_nsec+=100000000;
        if(until.tv_nsec>=1000000000){until.tv_sec++;until.tv_nsec-=1000000000;}
        while(!global_done) { int rv=pthread_cond_timedwait(&drain_condition,&drain_gate,&until);if(rv==ETIMEDOUT)break;assert(!rv); }
        fail+=check(!global_done,"global drain waits for owned interface drain");
        release_drain=1;assert(!pthread_cond_broadcast(&drain_condition));assert(!pthread_mutex_unlock(&drain_gate));
        for(int i=0;i<2;i++)assert(!pthread_join(threads[i],NULL));
        moal_private other={0};struct wireless_dev od={0};struct net_device on={0};
        other.phandle=&h;other.netdev=&on;other.wdev=&od;on.priv=&other;od.netdev=&on;od.wiphy=&w;
        fail+=check(submit_targets(&w,&od,1,1)==-ENODEV && h.rtt_terminating,"overlapping drains cannot reopen global teardown");
    } else if(!strcmp(argv[1],"idle-interface-quiesce") || !strcmp(argv[1],"closed-owner-quiesce")) {
        if(!strcmp(argv[1],"closed-owner-quiesce"))woal_rtt_quiesce(&h,NULL);
        woal_rtt_quiesce(&h,&p);fail+=check(submit_targets(&w,&d,1,1)==-ENODEV,"idle departing owner cannot enter RTT");
        moal_private other={0};struct wireless_dev od={0};struct net_device on={0};
        other.phandle=&h;other.netdev=&on;other.wdev=&od;on.priv=&other;od.netdev=&on;od.wiphy=&w;
        int ret=submit_targets(&w,&od,1,1);
        fail+=check(ret==(!strcmp(argv[1],"closed-owner-quiesce")?-ENODEV:0),"owner drain preserves persistent global admission state");
    } else if(!strcmp(argv[1],"warm-reopen")) {
        woal_rtt_quiesce(&h,NULL);woal_rtt_reopen(&h);
        fail+=check(!submit_targets(&w,&d,1,1),"successful reset reopens vendor RTT");woal_rtt_work_handler(&h.rtt_work);
        int dbm=99;fail+=check(!woal_cfg80211_get_tx_power(&w,&d,&dbm) && dbm==17,"successful reset restores TX-power query");
#if CFG80211_VERSION_CODE >= KERNEL_VERSION(4,20,0)
        struct ieee80211_channel channel={5180};struct cfg80211_pmsr_request req={0};req.n_peers=1;
        req.peers[0].addr[0]=2;req.peers[0].addr[5]=1;req.peers[0].chandef.chan=&channel;
        fail+=check(!woal_cfg80211_start_pmsr(&w,&d,&req) && start_count==2,"successful reset reopens real 11mc PMSR START");
        woal_rtt_pmsr_work_handler(&h.rtt_pmsr_work);fail+=check(complete_count==1 && h.rtt_owner==RTT_OWNER_IDLE,"reopened PMSR completes");
#endif
    } else return 2;
    if(!fail)printf("PASS rtt-host: %s\n",argv[1]);
    return fail?1:0;
}
'''
ftm_adapter = r'''#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include "mlan.h"
#include "mlan_util.h"
#include "mlan_join.h"
#include "mlan_fw.h"
#include "mlan_main.h"
static void *host_memset(void *handle,void *data,t_u8 value,t_u32 count) {
    (void)handle;return __builtin_memset(data,value,count);
}
static void *host_memcpy_ext(void *handle,void *dest,const void *src,t_u32 count,t_u32 capacity) {
    (void)handle;assert(count<=capacity);return __builtin_memcpy(dest,src,count);
}
void host_convert_ftm(t_u32 tof,wifi_rtt_result_v3 *result) {
    static mlan_adapter adapter;
    mlan_private priv={0};Event_WLS_FTM_t input={0};
    size_t payload=1+sizeof(wifi_rtt_result_element)+sizeof(*result);
    mlan_event *output=calloc(1,sizeof(*output)+payload);assert(output);
    adapter.callbacks.moal_memset=host_memset;adapter.callbacks.moal_memcpy_ext=host_memcpy_ext;
    priv.adapter=&adapter;input.u.ftm_complete.avg_tof=wlan_cpu_to_le32(tof);
    input.u.ftm_complete.mac[0]=2;input.u.ftm_complete.mac[5]=1;
    input.u.ftm_complete.protocol_num_measurements=4;
    assert(wlan_convert_to_wifi_rtt_result_v3(&priv,&input,sizeof(input),output,0)==MLAN_STATUS_SUCCESS);
    assert(output->event_len==payload && output->event_buf[0]==1);
    __builtin_memcpy(result,output->event_buf+1+sizeof(wifi_rtt_result_element),sizeof(*result));
    free(output);
}
'''
functions = function(util,"woal_rtt_get_capabilities")
functions += "\n".join(function(util,n) for n in (
    "woal_cfg80211_subcmd_get_supp_feature_set","woal_cfg80211_subcmd_rtt_get_capa","woal_cfg80211_subcmd_rtt_get_capa_v3",
    "woal_ftm_session_ctrl","woal_rtt_config_at","woal_rtt_release","woal_rtt_queue_request",
    "woal_rtt_work_handler","woal_cfg80211_subcmd_rtt_range_request",
    "woal_cfg80211_subcmd_rtt_range_request_v3","woal_cfg80211_subcmd_rtt_range_cancel",
    "woal_rtt_ap_result_received","woal_rtt_pmsr_work_handler","woal_rtt_quiesce","woal_rtt_reopen"))
functions += "\n#if CFG80211_VERSION_CODE >= KERNEL_VERSION(4,20,0)\n"
functions += "\n".join(function(util,n) for n in (
    "woal_ftm_session_ctrl_pmsr","woal_ftm_az_session_ctrl_pmsr",
    "woal_cfg80211_start_pmsr","woal_cfg80211_abort_pmsr"))
functions += "\n#endif\n"
functions += function(sta,"woal_cfg80211_get_tx_power") + function(sdio,"woal_sdio_shutdown")
functions += function(ioctl,"woal_request_get_fw_info") + function(ioctl,"woal_rtt_responder_cfg")
functions += function(main,"woal_rtt_wiphy_changed")
functions += "\nstatic void init_capabilities(moal_handle *handle) {\n" + cap_init + "}\n"
functions += pmsr_caps + "\nstatic void init_pmsr_capabilities(struct wiphy *wiphy,mlan_fw_info *fw_info) {\n" + pmsr_init + "}\n"
with tempfile.TemporaryDirectory(prefix="moal-rtt-host-") as temp:
    source=Path(temp)/"regression.c";binary=Path(temp)/"regression"
    adapter_source=Path(temp)/"ftm_adapter.c";adapter_object=Path(temp)/"ftm_adapter.o";mlan_object=Path(temp)/"mlan_cmdevt.o"
    adapter_source.write_text(ftm_adapter)
    cflags=["cc","-std=gnu11","-O1","-g","-ffunction-sections","-fdata-sections","-DSTA_SUPPORT","-DUAP_SUPPORT","-DSD9098","-DPCIE9098","-I"+str(root/"mlan")]
    subprocess.run(cflags+["-Wno-pointer-to-int-cast","-Wno-address-of-packed-member","-c",str(root/"mlan/mlan_cmdevt.c"),"-o",str(mlan_object)],check=True)
    subprocess.run(cflags+["-Wall","-Wextra","-Werror","-Wstrict-prototypes","-Wno-unused-parameter","-c",str(adapter_source),"-o",str(adapter_object)],check=True)
    source.write_text(prelude+fields+post_fields+feature_defines+"\n"+extra+functions+test_helpers+concurrency_helpers+drain_helpers+tests)
    cases = ("reset-wiphy-capabilities","capability-supported","capability-unsupported","capability-query-failed","capability-allocation-failed",
             "unsupported-fw-v1","unsupported-fw-v3","withdrawn-fw-worker","unqueried-fw","fw-info-allocation-failed",
             "invalid-enums-v1","invalid-enums-v3","supported-enums-v1","supported-enums-v3","unsupported-options-v1","unsupported-options-v3",
             "unsupported-protocol-v1","unsupported-protocol-v3",
             "responder-unqualified","responder-unsupported-fw","pmsr-capability-supported","pmsr-capability-unsupported",
             "pmsr-unsupported-fw","pmsr-unsupported-optional","pmsr-unsupported-az",
             "vendor-distance-units","pmsr-distance-units","v1-copy","v3-copy","failed-start","tx-power","sparse-shutdown","overlap",
             "partial-v1","partial-v3","active-cancel","pending-during-wait","cancel-errors","cancel-all",
             "failed-stop","timeout-stop-failed","timeout-stop","early-results","event-filter",
             "config-failure","start-failure-worker","worker-allocation-failure","queue-failure",
             "pmsr-overlap","pmsr-vendor-overlap","pmsr-report","pmsr-abort","pmsr-failed-start","pmsr-failed-abort","pmsr-completed-abort",
             "quiesce","interface-quiesce","concurrent-request","concurrent-quiesce","idle-interface-quiesce","closed-owner-quiesce","warm-reopen")
    failures = total = 0
    for label, version in (("3.14", (3,14,0)), ("4.19", (4,19,0)), ("5.4", (5,4,0)), ("6.6", (6,6,3))):
        code = (version[0]<<16)|(version[1]<<8)|version[2]
        subprocess.run(["cc","-std=gnu11","-O1","-g","-pthread","-Wall","-Wextra","-Werror",
                        "-Wstrict-prototypes","-Wno-unused-parameter","-Wno-unused-variable","-Wno-unused-function",
                        "-DCFG80211_VERSION_CODE="+str(code),"-I"+str(root/"mlan"),str(source),str(adapter_object),str(mlan_object),"-Wl,--gc-sections","-o",str(binary)],check=True)
        count = 0
        for case in cases:
            if case.startswith("pmsr-") and version < (4,20,0): continue
            if case == "pmsr-unsupported-az" and version < (5,10,0): continue
            result=subprocess.run([str(binary),case],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10)
            count+=1;total+=1
            if result.returncode:
                failures+=1
                sys.stdout.buffer.write(result.stdout);sys.stderr.buffer.write(result.stderr)
                print("FAIL rtt-host: kernel-branches %s %s (exit %d)"%(label,case,result.returncode),flush=True)
        print("rtt-host kernel-branches %s: %d scenarios"%(label,count),flush=True)
    if failures: raise SystemExit(1)
    print("rtt-host scenarios=%d failures=0"%total)
print("rtt_host_regressions=PASS")
PY_RTT
}

if [[ "${1:-}" == "--review-host-only" ]]; then
    review_host_regressions "${2:-all}"
    exit
fi

if [[ "${1:-}" == "--string-host-only" ]]; then
    string_host_regressions
    exit
fi

if [[ "${1:-}" == "--rtt-host-only" ]]; then
    rtt_host_regressions
    exit
fi

string_host_regressions
review_host_regressions
bash "$SCRIPT_DIR/rate_query_units_host_test.sh"
bash "$SCRIPT_DIR/cfpinfo_power_table_host_test.sh"
python3 "$SCRIPT_DIR/upstream_port_invariants.py"
bash "$SCRIPT_DIR/mlanutl_compile_qa.sh"
bash "$SCRIPT_DIR/antcfg_cli_qa.sh"
bash "$SCRIPT_DIR/make_for_imx93_qa.sh"
bash "$SCRIPT_DIR/bridge_static_checks.sh"
cmp -s "$ROOT/mlan/mlan_ioctl.h" "$ROOT/mlinux/mlan_ioctl.h"

rtt_host_regressions

printf 'upstream_port_final_checks=PASS\n'
