/* SPDX-License-Identifier: GPL-2.0 */
/* Exercise the association classifier with the IE bodies of (Re)AssocResp. */
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include "mlan.h"
#include "mlan_join.h"
#include "mlan_util.h"
#include "mlan_fw.h"
#include "mlan_main.h"

static const t_u8 requested_rates[] = {2, 11, 12, 108};
static const t_u8 dsss[] = {SUPPORTED_RATES, 2, 0x82, 11};
static const t_u8 ofdm[] = {SUPPORTED_RATES, 1, 0x82,
			    EXTENDED_SUPPORTED_RATES, 1, 0x8c};
static const t_u8 other_ofdm[] = {SUPPORTED_RATES, 2, 0x82, 0x98};

/* All three capability IEs, including the minimum HE MCS/NSS set. */
static const t_u8 modern[28 + 14 + 24] = {
	HT_CAPABILITY, 26, [28] = VHT_CAPABILITY, 12,
	[42] = EXTENSION, 22, HE_CAPABILITY,
};

struct example {
	const char *name;
	t_u16 band;
	t_u8 request_modes;
	const t_u8 *ies;
	t_u16 ies_len;
	t_u8 standard;
};

static void *host_copy(void *ctx, void *to, const void *from, t_u32 bytes,
		       t_u32 capacity)
{
	assert(bytes <= capacity);
	return __builtin_memcpy(to, from, bytes);
}

static void *host_set(void *ctx, void *to, t_u8 c, t_u32 bytes)
{
	return __builtin_memset(to, c, bytes);
}

static t_u16 host_read_u16(const void *src)
{
	t_u16 value;
	__builtin_memcpy(&value, src, sizeof(value));
	return value;
}

static t_u32 fake_now_sec;
static t_u32 fake_now_usec;
static int runtime_failures;
static int runtime_checks;

#define EXPECT_EQ(actual, expected, label)                                    \
	do {                                                                   \
		long actual_ = (long)(actual);                                  \
		long expected_ = (long)(expected);                              \
		runtime_checks++;                                                \
		if (actual_ != expected_) {                                     \
			fprintf(stderr, "%s: got %ld, expected %ld\n", label,     \
				actual_, expected_);                                \
			runtime_failures++;                                       \
		}                                                              \
	} while (0)

static mlan_status host_get_time(t_void *ctx, t_u32 *sec, t_u32 *usec)
{
	(void)ctx;
	*sec = fake_now_sec;
	*usec = fake_now_usec;
	return MLAN_STATUS_SUCCESS;
}

static mlan_status host_lock(t_void *ctx, t_void *lock)
{
	(void)ctx;
	(void)lock;
	return MLAN_STATUS_SUCCESS;
}

static mlan_status host_unlock(t_void *ctx, t_void *lock)
{
	(void)ctx;
	(void)lock;
	return MLAN_STATUS_SUCCESS;
}

#include "mlan_snapshot_getter.inc"

static void expect_elapsed(t_u32 start_sec, t_u32 start_usec, t_u32 now_sec,
			   t_u32 now_usec, t_u32 expected, const char *label)
{
	mlan_adapter adapter = {0};
	mlan_private priv = {0};
	mlan_ds_get_info info = {0};
	mlan_ioctl_req request = {0};

	adapter.priv[0] = &priv;
	adapter.callbacks.moal_memset = host_set;
	adapter.callbacks.moal_memcpy_ext = host_copy;
	adapter.callbacks.moal_get_system_time = host_get_time;
	adapter.callbacks.moal_spin_lock = host_lock;
	adapter.callbacks.moal_spin_unlock = host_unlock;
	priv.link_snapshot_valid = MTRUE;
	priv.media_connected = MTRUE;
	priv.bss_mode = MLAN_BSS_MODE_INFRA;
	priv.link_connected_at_sec = start_sec;
	priv.link_connected_at_usec = start_usec;
	request.action = MLAN_ACT_GET;
	request.buf_len = sizeof(info);
	request.pbuf = (t_u8 *)&info;
	fake_now_sec = now_sec;
	fake_now_usec = now_usec;
	EXPECT_EQ(wlan_get_info_link_snapshot(&adapter, &request),
		  MLAN_STATUS_SUCCESS, "snapshot getter status");
	EXPECT_EQ(info.param.link_snapshot.connected_sec, expected, label);
}

/* Minimal kernel-side facade consumed by the extracted MOAL handler. */
typedef struct {
	t_u8 bss_type;
	t_u8 bss_role;
} moal_private;

#define CMD_NXP "MRVL_CMD"
#define PRIV_CMD_STA_LINK_STATE "stalinkstate"
#define MOAL_IOCTL_WAIT 1
#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))

static mlan_link_snapshot scripted_snapshots[2];
static unsigned int snapshot_calls;
static unsigned int channel_queries;
static unsigned int opermode_queries;
static unsigned int rate_queries;

static int woal_get_link_snapshot(moal_private *priv,
				  mlan_link_snapshot *snapshot)
{
	unsigned int index = snapshot_calls < 2 ? snapshot_calls : 1;
	(void)priv;
	*snapshot = scripted_snapshots[index];
	snapshot_calls++;
	return 0;
}

static mlan_status woal_get_sta_channel(moal_private *priv, t_u8 wait,
					chan_band_info *channel)
{
	(void)priv;
	(void)wait;
	channel_queries++;
	channel->channel = 36;
	return MLAN_STATUS_SUCCESS;
}

static int woal_get_opermode(moal_private *priv,
			     mlan_ds_11ac_opermode_cfg *opermode)
{
	(void)priv;
	opermode_queries++;
	opermode->bw = 3;
	opermode->nss = 2;
	return 0;
}

static int woal_get_priv_datarate(moal_private *priv, t_u8 *data,
				  t_u32 data_len)
{
	(void)priv;
	rate_queries++;
	__builtin_memset(data, 0, data_len);
	return sizeof(mlan_data_rate);
}

#include "woal_link_standard_name.inc"
#include "woal_rate_format_name.inc"
#include "woal_rate_width_name.inc"
#include "woal_channel_width_name.inc"
#include "woal_link_band_name.inc"
#include "woal_get_priv_sta_link_state.inc"

static void reset_moal_script(t_u8 first_connected, t_u32 first_generation,
			      t_u8 final_connected, t_u32 final_generation)
{
	__builtin_memset(scripted_snapshots, 0, sizeof(scripted_snapshots));
	scripted_snapshots[0].connected = first_connected;
	scripted_snapshots[0].generation = first_generation;
	scripted_snapshots[1].connected = final_connected;
	scripted_snapshots[1].generation = final_generation;
	snapshot_calls = 0;
	channel_queries = 0;
	opermode_queries = 0;
	rate_queries = 0;
}

static void test_runtime_regressions(void)
{
	moal_private priv = {MLAN_BSS_TYPE_STA, MLAN_BSS_ROLE_STA};
	t_u8 response[512] = CMD_NXP PRIV_CMD_STA_LINK_STATE;
	int ret;

	expect_elapsed(10, 950000, 11, 50000, 0,
		       "sub-second boundary elapsed");
	expect_elapsed(10, 950000, 11, 950000, 1,
		       "one-second boundary elapsed");
	expect_elapsed(10, 100000, 10, 999999, 0, "same-second elapsed");
	expect_elapsed(0xffffffffU, 900000, 0, 100000, 0,
		       "unsigned seconds wrap elapsed");

	reset_moal_script(MFALSE, 7, MTRUE, 8);
	ret = woal_get_priv_sta_link_state(&priv, response, sizeof(response));
	EXPECT_EQ(ret, -EAGAIN, "disconnected-to-connected race");
	EXPECT_EQ(channel_queries, 0, "race channel queries");
	EXPECT_EQ(opermode_queries, 0, "race opermode queries");
	EXPECT_EQ(rate_queries, 0, "race rate queries");

	__builtin_strcpy((char *)response, CMD_NXP PRIV_CMD_STA_LINK_STATE);
	reset_moal_script(MTRUE, 11, MTRUE, 12);
	ret = woal_get_priv_sta_link_state(&priv, response, sizeof(response));
	EXPECT_EQ(ret, -EAGAIN, "connected generation change");
	EXPECT_EQ(channel_queries, 1, "generation change channel queries");
	EXPECT_EQ(opermode_queries, 1, "generation change opermode queries");
	EXPECT_EQ(rate_queries, 1, "generation change rate queries");

	__builtin_strcpy((char *)response, CMD_NXP PRIV_CMD_STA_LINK_STATE);
	reset_moal_script(MFALSE, 9, MFALSE, 9);
	ret = woal_get_priv_sta_link_state(&priv, response, sizeof(response));
	EXPECT_EQ(ret > 0, 1, "stable disconnected reply");
	EXPECT_EQ(snapshot_calls, 2, "stable disconnected snapshot reads");
	EXPECT_EQ(channel_queries, 0, "disconnected channel queries");
	EXPECT_EQ(opermode_queries, 0, "disconnected opermode queries");
	EXPECT_EQ(rate_queries, 0, "disconnected rate queries");
}

static void test_command_capture(void)
{
	/* Request has HT + HE. The nested VHT is the AP's scan data. */
	static const t_u8 tlvs[] = {
		1, 0, 2, 0, 2, 12,
		45, 0, 26, 0,
		[36] = 0x66, 0x02, 16, 0, 191, 0, 12, 0,
		[56] = 255, 0, 22, 0, 35,
		[81] = 0,
	};
	static mlan_adapter adapter;
	static HostCmd_DS_COMMAND command;
	static BSSDescriptor_t ap;
	cmd_ctrl_node node = {0};
	t_u8 *body = (t_u8 *)(&command.params.associate + 1);

	adapter.callbacks.moal_memcpy_ext = host_copy;
	adapter.callbacks.moal_memset = host_set;
	adapter.callbacks.moal_unaligned_access.moal_read_u16 = host_read_u16;
	ap.bss_band = BAND_A;
	node.pdata_buf = &ap;
	command.params.associate.peer_sta_addr[5] = 0x42;
	command.size = wlan_cpu_to_le16(S_DS_GEN +
		sizeof(command.params.associate) + sizeof(tlvs));
	__builtin_memcpy(body, tlvs, sizeof(tlvs));
	wlan_capture_assoc_link_attempt(&adapter, &node, &command);
	assert(node.link_attempt_modes == (MLAN_LINK_MODE_HT | MLAN_LINK_MODE_HE));
	assert(node.link_attempt_band == BAND_A && node.link_attempt_bssid[5] == 0x42);
	assert(node.link_attempt_rates_len == 2 && node.link_attempt_rates[1] == 12);

	/* The same command node can then carry a different legacy association. */
	command.size = wlan_cpu_to_le16(S_DS_GEN + sizeof(command.params.associate) + 6);
	command.params.associate.peer_sta_addr[5] = 0x43;
	ap.bss_band = BAND_G;
	wlan_capture_assoc_link_attempt(&adapter, &node, &command);
	assert(node.link_attempt_modes == 0 && node.link_attempt_rates_len == 2);
	assert(node.link_attempt_band == BAND_G && node.link_attempt_bssid[5] == 0x43);
}

int main(void)
{
	const t_u8 all = MLAN_LINK_MODE_HT | MLAN_LINK_MODE_VHT |
			 MLAN_LINK_MODE_HE;
	const struct example cases[] = {
		{"5 GHz legacy", BAND_A, 0, ofdm, sizeof(ofdm), MLAN_LINK_A},
		{"2.4 GHz DSSS", BAND_G, 0, dsss, sizeof(dsss), MLAN_LINK_B},
		{"common OFDM basic rate", BAND_G, 0, ofdm, sizeof(ofdm),
		 MLAN_LINK_G},
		{"no common OFDM rate", BAND_G, 0, other_ofdm,
		 sizeof(other_ofdm), MLAN_LINK_B},
		{"request limited to HT", BAND_G, MLAN_LINK_MODE_HT,
		 modern, sizeof(modern), MLAN_LINK_N},
		{"response limited to VHT", BAND_A, all, modern, 42,
		 MLAN_LINK_AC},
		{"HE on both sides", BAND_A, all, modern, sizeof(modern),
		 MLAN_LINK_AX},
		{"HE in request only", BAND_A, all, modern, 28, MLAN_LINK_N},
		{"HE in response only", BAND_A, 0, modern, sizeof(modern),
		 MLAN_LINK_A},
		{"no response evidence on 2.4 GHz", BAND_G, all, NULL, 0,
		 MLAN_LINK_UNKNOWN},
		{"incomplete association IE", BAND_A, all, modern,
		 sizeof(modern) - 1, MLAN_LINK_UNKNOWN},
		{"6 GHz outside reporting scope", BAND_6G, all, modern,
		 sizeof(modern), MLAN_LINK_UNKNOWN},
	};
	unsigned int i;
	int failures = 0;

	test_command_capture();
	test_runtime_regressions();
	for (i = 0; i < NELEMENTS(cases); i++) {
		const struct example *c = &cases[i];
		t_u8 actual = wlan_classify_link_standard(c->request_modes,
				requested_rates, sizeof(requested_rates),
				c->band, c->ies, c->ies_len);

		if (actual != c->standard) {
			fprintf(stderr, "%s: got %u, expected %u\n",
				c->name, actual, c->standard);
			failures++;
		}
	}
	if (failures || runtime_failures)
		return 1;
	printf("PASS: request TLV capture, %zu classifications, %d runtime checks\n",
	       NELEMENTS(cases), runtime_checks);
	return 0;
}
