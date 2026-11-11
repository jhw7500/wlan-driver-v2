#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# Compile selected production MOAL paths with host-only kernel/firmware doubles.
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
header = (root / "mlinux/moal_main.h").read_text()

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
#define ENTER() ((void)0)
#define LEAVE() ((void)0)
#define PRINTM(...) ((void)0)
#define GFP_KERNEL 0
#define GFP_ATOMIC 0
#define MOAL_IOCTL_WAIT 1
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
struct net_device { moal_private *priv; };
struct wiphy { struct _moal_handle *handle; };
struct wireless_dev { struct net_device *netdev; struct wiphy *wiphy; };
struct _moal_handle {
'''
post_fields = r'''    moal_private *priv[MLAN_MAX_BSS_NUM];
    int priv_num;
    struct { int cfg80211_wext; } params;
    int partial_io_enable, shutdown_hs_in_process, surprise_removed, fw_reseting, driver_status;
    int hs_activate_wait_q, hs_activate_wait_q_woken, hs_activated;
    struct workqueue_struct *evt_workqueue;
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
static s64 reported_distance;
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
static mlan_ioctl_req *woal_alloc_mlan_ioctl_req(size_t n) { mlan_ioctl_req *r=calloc(1,sizeof(*r)+n);assert(r);r->pbuf=(t_u8 *)(r+1);return r; }
static int woal_request_ioctl(moal_private *p,mlan_ioctl_req *r,int w);
static moal_private *woal_get_priv(moal_handle *h,int role) { (void)role;for(int i=0;i<h->priv_num;i++)if(h->priv[i])return h->priv[i];return NULL; }
static int woal_set_get_tx_power(moal_private *p,int a,mlan_power_cfg_t *cfg) { (void)p;(void)a;power_queries++;cfg->power_level=17;return MLAN_STATUS_SUCCESS; }
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
    memset(h,0,sizeof(*h));memset(p,0,sizeof(*p));
    p->phandle=h;p->netdev=n;p->wdev=d;n->priv=p;d->netdev=n;d->wiphy=w;w->handle=h;
    h->priv_num=1;h->priv[0]=p;h->params.cfg80211_wext=1;
    assert(!pthread_mutex_init(&h->rtt_result_lock,NULL));
    mutex_init(&h->rtt_mutex);mutex_init(&h->rtt_quiesce_mutex);h->rtt_initialized=MTRUE;h->rtt_current_index=-1;h->evt_workqueue=&host_queue;
    queue_accept=1;queue_count=0;power_queries=0;ioctl_status=MLAN_STATUS_SUCCESS;
    memset(&input_v1,0,sizeof(input_v1));memset(&input_v3,0,sizeof(input_v3));
    auto_result=1;stop_failure=0;cfg_fail_peer=-1;start_fail_peer=-1;
    start_count=stop_count=event_count=event_peers=event_version=cancel_calls=0;
    wait_hook=hook_error=timeout_count=report_count=complete_count=0;finished_request=NULL;
}
'''
extra = r'''struct nlattr { int len; void *data; };
enum { ATTR_RTT_TARGET_NUM=2,ATTR_RTT_TARGET_ADDR=4,ATTR_RTT_MAX=17 };
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
static int woal_ftm_session_cfg(moal_private *priv,wifi_rtt_config *cfg) { (void)priv;return cfg->addr[5]==cfg_fail_peer?-EFAULT:0; }
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
#if CFG80211_VERSION_CODE >= KERNEL_VERSION(5,10,0)
    struct { int non_trigger_based,trigger_based; } ftm;
#endif
};
struct cfg80211_pmsr_request { int n_peers;struct cfg80211_pmsr_request_peer peers[1]; };
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
    assert(result->ftm.rtt_avg==123 && result->ftm.num_ftmr_successes==4);
}
static void cfg80211_pmsr_complete(struct wireless_dev *w,struct cfg80211_pmsr_request *req,int gfp) {
    (void)w;(void)gfp;assert(req && req!=finished_request);complete_count++;finished_request=req;
}
static int woal_get_ftm_session_action_pmsr(moal_private *p,const t_u8 *addr) { (void)p;(void)addr;return 1; }
static int woal_freq_to_chanband_pmsr(unsigned int freq) { (void)freq;return 0; }
static int woal_ftm_session_cfg_pmsr(moal_private *p,struct cfg80211_pmsr_request_peer *peer) { (void)p;return peer->addr[5]==cfg_fail_peer?-EFAULT:0; }
static int woal_ftm_az_session_cfg_pmsr(moal_private *p,struct cfg80211_pmsr_request_peer *peer) { return woal_ftm_session_cfg_pmsr(p,peer); }
static int woal_request_ioctl(moal_private *p,mlan_ioctl_req *r,int wait) {
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
    input_v1.rtt_config_num=count;input_v3.rtt_config_num=count;
    for(int i=0;i<count;i++) {
        wifi_rtt_config *cfg=&input_v1.rtt_config[i];cfg->addr[0]=2;cfg->addr[5]=i+1;
        cfg->type=RTT_TYPE_2_SIDED_11MC;cfg->channel.center_freq=5180;cfg->bw=WIFI_RTT_BW_80;
        input_v3.rtt_config_v3[i].rtt_config=*cfg;input_v3.rtt_config_v3[i].ntb_max_measurement_time=987654;
        if(version==3)input_v3.rtt_config_v3[i].rtt_config.type=RTT_TYPE_2_SIDED_11AZ_NTB;
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
    if(!strcmp(argv[1],"v1-copy")) {
        for(int count=1;count<=MAX_RTT_CONFIG_NUM;count+=MAX_RTT_CONFIG_NUM-1) {
            input_v1.rtt_config_num=count;input_v1.rtt_config[count-1].bw=WIFI_RTT_BW_80;
            fail+=check(!woal_cfg80211_subcmd_rtt_range_request(&w,&d,&input_v1,sizeof(input_v1)),"v1 request accepted");
            fail+=check(h.rtt_params.rtt_config[count-1].bw==WIFI_RTT_BW_80,"v1 last peer bandwidth preserved");
            assert(!pthread_mutex_destroy(&h.rtt_result_lock));assert(!pthread_mutex_destroy(&h.rtt_mutex.native));assert(!pthread_mutex_destroy(&h.rtt_quiesce_mutex.native));
            init_fixture(&h,&p,&w,&d,&n);
        }
    } else if(!strcmp(argv[1],"v3-copy")) {
        for(int count=1;count<=MAX_RTT_CONFIG_NUM;count+=MAX_RTT_CONFIG_NUM-1) {
            input_v3.rtt_config_num=count;input_v3.rtt_config_v3[count-1].ntb_max_measurement_time=987654;
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
        input_v1.rtt_config_num=1;input_v1.rtt_config[0].bw=WIFI_RTT_BW_80;
        input_v3.rtt_config_num=1;
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
                    fail+=check(report_count==1 && complete_count==1 && reported_distance==6400 && !stop_count,"deferred PMSR reports once and completed abort is no-op");
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
functions = "\n".join(function(util,n) for n in (
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
with tempfile.TemporaryDirectory(prefix="moal-rtt-host-") as temp:
    source=Path(temp)/"regression.c";binary=Path(temp)/"regression"
    source.write_text(prelude+fields+post_fields+extra+functions+test_helpers+concurrency_helpers+drain_helpers+tests)
    cases = ("v1-copy","v3-copy","failed-start","tx-power","sparse-shutdown","overlap",
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
                        "-DCFG80211_VERSION_CODE="+str(code),"-I"+str(root/"mlan"),str(source),"-o",str(binary)],check=True)
        count = 0
        for case in cases:
            if case.startswith("pmsr-") and version < (4,20,0): continue
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

if [[ "${1:-}" == "--rtt-host-only" ]]; then
    rtt_host_regressions
    exit
fi

python3 "$SCRIPT_DIR/upstream_port_invariants.py"
bash "$SCRIPT_DIR/mlanutl_compile_qa.sh"
bash "$SCRIPT_DIR/antcfg_cli_qa.sh"
bash "$SCRIPT_DIR/make_for_imx93_qa.sh"
bash "$SCRIPT_DIR/bridge_static_checks.sh"
cmp -s "$ROOT/mlan/mlan_ioctl.h" "$ROOT/mlinux/mlan_ioctl.h"

rtt_host_regressions

printf 'upstream_port_final_checks=PASS\n'
