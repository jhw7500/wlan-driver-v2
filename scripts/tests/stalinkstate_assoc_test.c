/* SPDX-License-Identifier: GPL-2.0 */
/* Exercise the association classifier with the IE bodies of (Re)AssocResp. */
#include <assert.h>
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
	if (failures)
		return 1;
	printf("PASS: request TLV capture and %zu association classifications\n", NELEMENTS(cases));
	return 0;
}
