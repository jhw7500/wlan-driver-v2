/* Host regression test for MLAN_OID_MISC_CFP_INFO power-table rows.
 *
 * This links the production wlan_get_cfpinfo().  The response buffer starts
 * filled with 0xA5 so a channel without a matching firmware power-table row
 * cannot pass by inheriting a zeroed caller buffer.
 */
#include <stdio.h>
#include <string.h>

#include "mlan.h"
#include "mlan_util.h"
#include "mlan_join.h"
#include "mlan_fw.h"
#include "mlan_main.h"

static int failures, checks;

static void check(int ok, const char *name, unsigned channel)
{
	checks++;
	if (!ok) {
		printf("FAIL cfpinfo: %s (channel %u)\n", name, channel);
		failures++;
	}
}

mlan_status wlan_11h_ioctl_nop_channel_list(pmlan_adapter pmadapter,
					    pmlan_ioctl_req pioctl_req)
{
	(void)pmadapter;
	(void)pioctl_req;
	return MLAN_STATUS_SUCCESS;
}

static t_void *host_memcpy_ext(t_void *handle, t_void *dst, const t_void *src,
			       t_u32 len, t_u32 size)
{
	(void)handle;
	return __builtin_memcpy(dst, src, len < size ? len : size);
}

static t_void *host_memset(t_void *handle, t_void *dst, t_u8 value, t_u32 len)
{
	(void)handle;
	return __builtin_memset(dst, (int)value, len);
}

static int listed(const t_u8 *channels, unsigned count, unsigned channel)
{
	unsigned i;

	for (i = 0; i < count; i++)
		if (channels[i] == channel)
			return 1;
	return 0;
}

static void check_rows(const t_u8 *rows, const chan_freq_power_t *cfp,
		       t_u32 count, t_u8 cols, const t_u8 *channels,
		       unsigned channel_count, t_u8 power, int *hit, int *miss)
{
	t_u32 i, j;

	for (i = 0; i < count; i++) {
		const t_u8 *row = rows + i * cols;
		unsigned channel = (unsigned)cfp[i].channel;
		int found = listed(channels, channel_count, channel);

		check(row[0] == (t_u8)channel, "row starts with its channel",
		      channel);
		for (j = 1; j < cols; j++)
			check(row[j] == (found ? power : 0),
			      found ? "matched row copies firmware power" :
				      "unmatched row reports zero power",
			      channel);
		if (found)
			(*hit)++;
		else
			(*miss)++;
	}
}

int main(void)
{
	static mlan_adapter adapter;
	static t_u8 out[8192];
	static const t_u8 bg_channels[] = {1, 2, 3, 4, 5, 6, 7,
					   8, 9, 10, 11, 12, 13};
	static const t_u8 a_channels[] = {36, 40, 44, 48};
	static t_u8 bg_table[sizeof(bg_channels) * 3];
	static t_u8 a_table[sizeof(a_channels) * 3];
	mlan_ioctl_req req;
	mlan_cfpinfo c;
	const chan_freq_power_t *cfp_bg, *cfp_a;
	const t_u8 *rows;
	int bg_hit = 0, bg_miss = 0, a_hit = 0, a_miss = 0;
	unsigned i;

	for (i = 0; i < sizeof(bg_channels); i++) {
		bg_table[i * 3] = bg_channels[i];
		bg_table[i * 3 + 1] = 0x11;
		bg_table[i * 3 + 2] = 0x11;
	}
	for (i = 0; i < sizeof(a_channels); i++) {
		a_table[i * 3] = a_channels[i];
		a_table[i * 3 + 1] = 0x22;
		a_table[i * 3 + 2] = 0x22;
	}
	__builtin_memset(&adapter, 0, sizeof(adapter));
	adapter.callbacks.moal_memcpy_ext = host_memcpy_ext;
	adapter.callbacks.moal_memset = host_memset;
	adapter.fw_bands = BAND_B | BAND_G | BAND_A;
	adapter.region_code = 0xFF;
	adapter.tx_power_table_bg = bg_table;
	adapter.tx_power_table_bg_rows = sizeof(bg_channels);
	adapter.tx_power_table_bg_cols = 3;
	adapter.tx_power_table_bg_size = sizeof(bg_table);
	adapter.tx_power_table_a = a_table;
	adapter.tx_power_table_a_rows = sizeof(a_channels);
	adapter.tx_power_table_a_cols = 3;
	adapter.tx_power_table_a_size = sizeof(a_table);

	__builtin_memset(out, 0xA5, sizeof(out));
	__builtin_memset(&req, 0, sizeof(req));
	req.pbuf = out;
	req.buf_len = sizeof(out);
	req.action = MLAN_ACT_GET;
	if (wlan_get_cfpinfo(&adapter, &req) != MLAN_STATUS_SUCCESS) {
		printf("FAIL cfpinfo: production call failed\n");
		return 1;
	}
	__builtin_memcpy(&c, out, sizeof(c));
	cfp_bg = (const chan_freq_power_t *)(out + sizeof(c));
	cfp_a = cfp_bg + c.rows_2g;
	rows = (const t_u8 *)(cfp_a + c.rows_5g);
	check_rows(rows, cfp_bg, c.rows_2g, c.cols_2g, bg_channels,
		   sizeof(bg_channels), 0x11, &bg_hit, &bg_miss);
	check_rows(rows + c.rows_2g * c.cols_2g, cfp_a, c.rows_5g, c.cols_5g,
		   a_channels, sizeof(a_channels), 0x22, &a_hit, &a_miss);
	check(bg_hit > 0 && bg_miss > 0,
	      "2.4 GHz exercises matched and unmatched rows", 0);
	check(a_hit > 0 && a_miss > 0,
	      "5 GHz exercises matched and unmatched rows", 0);
	printf("cfpinfo 2g rows=%u matched=%d unmatched=%d, 5g rows=%u "
	       "matched=%d unmatched=%d, checks=%d failures=%d\n",
	       (unsigned)c.rows_2g, bg_hit, bg_miss, (unsigned)c.rows_5g,
	       a_hit, a_miss, checks, failures);
	return failures ? 1 : 0;
}
