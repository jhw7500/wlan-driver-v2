/* Monitor-mode radiotap HE GI / format / BW and LDPC (#125).
 *
 * mlan side: production wlan_rxpdinfo_to_radiotapinfo() from mlan_sta_rx.c,
 * linked as an object built from the source tree.
 * moal side: verbatim line ranges of moal_recv_packet_to_mon_if() and the
 * radiotap definitions of moal_main.h (extracted by
 * radiotap_he_gi_host_test.sh), compiled inside a host function with only
 * kernel-type stubs.
 *
 * Expected values come from primary sources, not from the code under test:
 *  - RxPD rate_info: mlan_fw.h "[Bit 6] LDPC ... [Bit4, Bit7] AX Guard
 *    interval"; mlan_cfp.c "BIT7:BIT4 0:0= 0.8us, 0:1= 0.8us, 1:0=1.6us,
 *    1:1=3.2us"; moal_sta_cfg80211.c woal_he_gi_to_nl80211_he_gi().
 *  - radiotap HE: linux include/net/ieee80211_radiotap.h DATA5_GI (0x0030)
 *    0=0.8 1=1.6 2=3.2, DATA1_FORMAT 0=SU 1=EXT_SU 2=MU 3=TRIG,
 *    DATA5 BW 0..3 = 20/40/80/160, DATA3 0x1000 = DCM, 0x2000 = Coding (LDPC).
 *  - moal writes "he->data3 |= (dcm << 12)" unconditionally, so every HE case
 *    checks data3 bits 12-15: a GI code leaking out of mix_rate_info.dcm
 *    bits 1-2 (missing "& 0x1" mask) shows up as Coding/LDPC-extra bits.
 */
#include <stdio.h>
#include <string.h>

#include "mlan.h"
#include "mlan_util.h"
#include "mlan_join.h"
#include "mlan_fw.h"
#include "mlan_main.h"

/* ---- kernel-type stubs for the extracted moal code ---- */
#define __packed __attribute__((packed))
#define cpu_to_le16(x) (x)
#define cpu_to_le32(x) (x)
#define IEEE80211_RADIOTAP_MCS 19
#define IEEE80211_RADIOTAP_HE 23
struct rt_hdr_stub {
	t_u8 it_version;
	t_u8 it_pad;
	t_u16 it_len;
	t_u32 it_present;
};
#include "moal_rt_defs.inc"
#include "moal_ru_tables.inc"

static int failures;
static int checks;

#define EXPECT(actual, expected, name)                                        \
	do {                                                                   \
		unsigned v_ = (unsigned)(actual), e_ = (unsigned)(expected);   \
		checks++;                                                      \
		if (v_ == e_)                                                  \
			printf("PASS %s = %u\n", name, v_);                     \
		else {                                                         \
			printf("FAIL %s = %u, expected %u\n", name, v_, e_);    \
			failures++;                                            \
		}                                                              \
	} while (0)

struct moal_out {
	struct mcs_field mcs;
	struct he_field he;
	t_u8 format, preamble_type, gi, bw, ldpc;
};

/* Body of moal_recv_packet_to_mon_if() restricted to the extracted ranges. */
static void moal_decode(radiotap_info rt_info, struct moal_out *o)
{
	t_u8 format = 0, preamble_type = 0, mcs = 0, nss = 0, bw = 0, gi = 0;
	t_u8 ldpc = 0, dcm = 0;
	t_u32 he_sig1 = 0, he_sig2 = 0, usr_idx = 0, out = 0, tone = 0;
	t_u8 buf[64];
	t_u8 *radiotap_pos;
	t_u32 radiotap_len;
	struct rt_hdr_stub hdr = {0}, *rth_hdr = &hdr;

	(void)out; (void)tone; (void)usr_idx; (void)he_sig1; (void)he_sig2;
#include "moal_field_decode.inc"
	o->format = format;
	o->preamble_type = preamble_type;
	o->gi = gi;
	o->bw = bw;
	o->ldpc = ldpc;

	__builtin_memset(buf, 0, sizeof(buf));
	radiotap_pos = buf;
	radiotap_len = 0;
#include "moal_ht_block.inc"
	__builtin_memcpy(&o->mcs, buf, sizeof(o->mcs));

	__builtin_memset(buf, 0, sizeof(buf));
	radiotap_pos = buf;
	radiotap_len = 0;
#include "moal_he_block.inc"
	__builtin_memcpy(&o->he, buf, sizeof(o->he));
	(void)radiotap_len; (void)mcs; (void)nss; (void)dcm;
}

/* ---- mlan callbacks ---- */
static t_void *cb_memset(t_void *h, t_void *p, t_u8 c, t_u32 n)
{
	(void)h;
	return __builtin_memset(p, c, n);
}
static t_void *cb_memcpy_ext(t_void *h, t_void *d, const t_void *s, t_u32 n,
			     t_u32 ds)
{
	(void)h;
	return __builtin_memcpy(d, s, n < ds ? n : ds);
}

static mlan_adapter adapter;
static mlan_private priv;

static void run(t_u8 rx_rate, t_u8 rate_info, t_u32 rx_info,
		radiotap_info *rt, struct moal_out *o)
{
	RxPD rxpd;

	__builtin_memset(&rxpd, 0, sizeof(rxpd));
	rxpd.rx_rate = rx_rate;
	rxpd.rate_info = rate_info;
	rxpd.rx_info = rx_info;
	wlan_rxpdinfo_to_radiotapinfo(&priv, &rxpd, rt);
	moal_decode(*rt, o);
}

#define HE 0x3
#define HT 0x1
#define BW80 (2 << 2)
#define GI_B4 0x10
#define GI_B7 0x80
#define LDPC_B6 0x40
#define PRE(p) ((t_u32)(p) << 14)

static const char *gi_us[] = {"0.8", "1.6", "3.2", "rsvd"};

static void he_case(const char *tag, t_u8 gi_code, t_u8 pre, t_u8 ldpc,
		    t_u8 dcm, t_u8 exp_rt_gi, int exp_fmt, t_u8 exp_bw)
{
	radiotap_info rt;
	struct moal_out o;
	char n[160];
	t_u8 ri = HE | BW80 | ((gi_code & 1) ? GI_B4 : 0) |
		  ((gi_code & 2) ? GI_B7 : 0) | (ldpc ? LDPC_B6 : 0);

	run(0x07, ri, PRE(pre) | (dcm ? RXPD_DCM_MASK : 0), &rt, &o);
	printf("-- %s: RxPD rate_info=0x%02x preamble=%u (GI code %u = %s us)"
	       " -> mix rate_info=0x%02x\n",
	       tag, ri, pre, gi_code,
	       gi_code < 2 ? "0.8" : gi_us[gi_code - 1],
	       rt.rate_info.rate_info);
	snprintf(n, sizeof(n), "%s radiotap HE data5 GI (%s us expected)",
		 tag, gi_us[exp_rt_gi]);
	EXPECT((o.he.data5 >> 4) & 3, exp_rt_gi, n);
	if (exp_fmt >= 0) { /* MU flag needs he_sig1 (extra header) */
		snprintf(n, sizeof(n), "%s radiotap HE data1 format", tag);
		EXPECT(o.he.data1 & 3, exp_fmt, n);
	}
	snprintf(n, sizeof(n), "%s radiotap HE data5 BW/RU", tag);
	EXPECT(o.he.data5 & 0xF, exp_bw, n);
	snprintf(n, sizeof(n),
		 "%s radiotap HE data3 bits 12-15 (DCM 0x1, Coding/LDPC 0x2)",
		 tag);
	EXPECT((o.he.data3 >> 12) & 0xF, (ldpc ? 2 : 0) | (dcm ? 1 : 0), n);
}

static void ht_case(const char *tag, t_u8 sgi, t_u8 ldpc, t_u8 exp_flags)
{
	radiotap_info rt;
	struct moal_out o;
	char n[160];
	t_u8 ri = HT | (sgi ? GI_B4 : 0) | (ldpc ? LDPC_B6 : 0);

	run(7, ri, 0, &rt, &o);
	printf("-- %s: RxPD rate_info=0x%02x -> mix rate_info=0x%02x\n", tag, ri,
	       rt.rate_info.rate_info);
	snprintf(n, sizeof(n), "%s radiotap MCS index", tag);
	EXPECT(o.mcs.mcs, 7, n);
	snprintf(n, sizeof(n), "%s radiotap MCS flags (GI 0x04, FEC 0x10)", tag);
	EXPECT(o.mcs.flags & 0x17, exp_flags, n);
}

int main(void)
{
	radiotap_info rt;
	struct moal_out o;

	__builtin_memset(&adapter, 0, sizeof(adapter));
	__builtin_memset(&priv, 0, sizeof(priv));
	adapter.callbacks.moal_memset = cb_memset;
	adapter.callbacks.moal_memcpy_ext = cb_memcpy_ext;
	priv.adapter = &adapter;

	/* positive controls: inputs whose correct radiotap output is known */
	he_case("PC HE-SU 80 GI0", 0, 0, 0, 0, 0, 0, 2);
	ht_case("PC HT20 MCS7 SGI", 1, 0, 0x04);
	run(12, 0, 0, &rt, &o);
	EXPECT(rt.rate_info.bitrate, 108, "PC legacy 54 Mbps radiotap Rate");

	/* candidate 1 */
	he_case("HE-SU 80 GI1", 1, 0, 0, 0, 0, 0, 2);
	he_case("HE-SU 80 GI2", 2, 0, 0, 0, 1, 0, 2);
	he_case("HE-SU 80 GI3", 3, 0, 0, 0, 2, 0, 2);
	he_case("HE-MU 80 GI0", 0, 2, 0, 0, 0, -1, 2);
	he_case("HE-MU 80 GI2", 2, 2, 0, 0, 1, -1, 2);
	/* DCM shares mix_rate_info.dcm with the HE GI code (bit 0 vs bits 1-2) */
	he_case("HE-SU 80 GI3 DCM", 3, 0, 0, 1, 2, 0, 2);
	/* same function: RxPD bit 6 LDPC */
	he_case("HE-SU 80 GI0 LDPC", 0, 0, 1, 0, 0, 0, 2);
	ht_case("HT20 MCS7 LGI LDPC", 0, 1, 0x10);

	printf("radiotap host test: %d check(s), %d failure(s)\n", checks,
	       failures);
	return failures ? 1 : 0;
}
