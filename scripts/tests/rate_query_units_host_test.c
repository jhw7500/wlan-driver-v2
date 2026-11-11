/* Host regression test for the rate-query ABI unit boundary.
 *
 * This links the production command-response handler, rate-index converter,
 * and WMM rate calculators.  Expected values are literal 500-kbit/s ABI
 * units; they are intentionally not derived from the implementation under
 * test.
 */
#include <stdio.h>
#include <string.h>

#include "mlan.h"
#include "mlan_util.h"
#include "mlan_join.h"
#include "mlan_fw.h"
#include "mlan_main.h"

#define ZERO(object) __builtin_memset(&(object), 0, sizeof(object))

static int failures;

#define EXPECT_U32(actual, expected, name)                                    \
	do {                                                                   \
		t_u32 value_ = (actual);                                        \
		if (value_ == (t_u32)(expected))                                \
			printf("PASS rate-query: %s = %u\n", name, value_);      \
		else {                                                         \
			printf("FAIL rate-query: %s = %u, expected %u\n", name, \
			       value_, (t_u32)(expected));                         \
			failures++;                                               \
		}                                                              \
	} while (0)

static void run_query(mlan_private *priv, HostCmd_DS_COMMAND *resp,
		      mlan_ds_rate *rate, mlan_ioctl_req *ioctl,
		      t_u8 tx_rate, t_u8 tx_info, t_u8 tx_ext)
{
	__builtin_memset(resp, 0, sizeof(*resp));
	resp->params.tx_rate.tx_rate = tx_rate;
	resp->params.tx_rate.tx_rate_info = tx_info;
	resp->params.tx_rate.ext_tx_rate_info = tx_ext;
	ioctl->pbuf = (t_u8 *)rate;
	wlan_ret_802_11_tx_rate_query(priv, resp, ioctl);
}

static void test_raw_calculators(mlan_adapter *adapter)
{
	EXPECT_U32(wlan_index_to_data_rate(adapter, 7, MLAN_RATE_FORMAT_HT,
					   0, MFALSE),
		   65000, "raw HT20 MCS7 LGI remains kbit/s");
	EXPECT_U32(wlan_index_to_data_rate(adapter, 7,
					   MLAN_RATE_FORMAT_HT | 0x10, 0,
					   MFALSE),
		   72215, "raw HT20 MCS7 SGI remains kbit/s");
	EXPECT_U32(wlan_index_to_data_rate(adapter, 6,
					   MLAN_RATE_FORMAT_HT | 0x10, 0,
					   MFALSE),
		   64993, "raw HT20 MCS6 SGI remains kbit/s");
	EXPECT_U32(wlan_index_to_data_rate(adapter, 0,
					   MLAN_RATE_FORMAT_VHT | 0x08, 0,
					   MFALSE),
		   29300, "raw VHT80 NSS1 MCS0 LGI remains kbit/s");
	EXPECT_U32(wlan_index_to_data_rate(adapter, MLAN_RATE_BITMAP_MCS0,
					   MLAN_RATE_FORMAT_HT, 0,
					   MFALSE),
		   12, "raw HT MCS32 LGI retains legacy representation");
	EXPECT_U32(wlan_index_to_data_rate(adapter, MLAN_RATE_BITMAP_MCS0,
					   MLAN_RATE_FORMAT_HT | 0x10, 0,
					   MFALSE),
		   13, "raw HT MCS32 SGI retains legacy representation");
	EXPECT_U32(wlan_index_to_data_rate(adapter, 5, MLAN_RATE_FORMAT_LG, 0,
					   MFALSE),
		   6000, "raw legacy OFDM6 remains kbit/s");
}

static void test_get_data_rate(mlan_private *priv,
			       HostCmd_DS_COMMAND *resp,
			       mlan_ioctl_req *ioctl)
{
	mlan_ds_rate rate;

	ZERO(rate);
	rate.sub_command = MLAN_OID_GET_DATA_RATE;
	priv->rxpd_rate = MLAN_RATE_BITMAP_MCS0;
	priv->rxpd_rate_info = MLAN_RATE_FORMAT_HT | 0x10;
	run_query(priv, resp, &rate, ioctl, 7, MLAN_RATE_FORMAT_HT, 0);
	EXPECT_U32(rate.param.data_rate.tx_data_rate, 130,
		   "GET_DATA_RATE HT20 MCS7 LGI TX uses 500-kbit/s units");
	EXPECT_U32(rate.param.data_rate.rx_data_rate, 13,
		   "GET_DATA_RATE HT MCS32 SGI RX preserves 6.5 Mbps");
	EXPECT_U32(rate.param.data_rate.tx_mcs_index, 7,
		   "GET_DATA_RATE HT TX MCS metadata");

	ZERO(rate);
	rate.sub_command = MLAN_OID_GET_DATA_RATE;
	priv->rxpd_rate = 0;
	priv->rxpd_rate_info = MLAN_RATE_FORMAT_VHT | 0x08;
	run_query(priv, resp, &rate, ioctl, 6,
		  MLAN_RATE_FORMAT_HT | 0x10, 0);
	EXPECT_U32(rate.param.data_rate.tx_data_rate, 130,
		   "GET_DATA_RATE HT20 MCS6 SGI rounds to legacy table value");
	EXPECT_U32(rate.param.data_rate.rx_data_rate, 59,
		   "GET_DATA_RATE VHT80 NSS1 MCS0 rounds to legacy table value");

	ZERO(rate);
	rate.sub_command = MLAN_OID_GET_DATA_RATE;
	priv->rxpd_rate = MLAN_RATE_BITMAP_MCS0;
	priv->rxpd_rate_info = MLAN_RATE_FORMAT_HT;
	run_query(priv, resp, &rate, ioctl, MLAN_RATE_BITMAP_MCS0,
		  MLAN_RATE_FORMAT_HT | 0x10, 0);
	EXPECT_U32(rate.param.data_rate.tx_data_rate, 13,
		   "GET_DATA_RATE HT MCS32 SGI TX preserves 6.5 Mbps");
	EXPECT_U32(rate.param.data_rate.rx_data_rate, 12,
		   "GET_DATA_RATE HT MCS32 LGI RX preserves 6 Mbps");

	ZERO(rate);
	rate.sub_command = MLAN_OID_GET_DATA_RATE;
	priv->rxpd_rate = 0x19;
	priv->rxpd_rate_info = MLAN_RATE_FORMAT_VHT | 0x08;
	run_query(priv, resp, &rate, ioctl, 0x19,
		  MLAN_RATE_FORMAT_VHT | 0x08 | 0x10, 0);
	EXPECT_U32(rate.param.data_rate.tx_data_rate, 1733,
		   "GET_DATA_RATE VHT80 NSS2 MCS9 SGI TX quantizes ABI value");
	EXPECT_U32(rate.param.data_rate.rx_data_rate, 1560,
		   "GET_DATA_RATE VHT80 NSS2 MCS9 LGI RX uses ABI units");
	EXPECT_U32(rate.param.data_rate.tx_nss, 1,
		   "GET_DATA_RATE VHT TX zero-based NSS metadata");
	EXPECT_U32(rate.param.data_rate.rx_nss, 1,
		   "GET_DATA_RATE VHT RX zero-based NSS metadata");

	ZERO(rate);
	rate.sub_command = MLAN_OID_GET_DATA_RATE;
	priv->rxpd_rate = 0x1b;
	priv->rxpd_rate_info = MLAN_RATE_FORMAT_HE | 0x08 | 0x10 | 0x80;
	priv->rxpd_rx_info = 0;
	run_query(priv, resp, &rate, ioctl, 0x1b,
		  MLAN_RATE_FORMAT_HE | 0x08, 0);
	EXPECT_U32(rate.param.data_rate.tx_data_rate, 2404,
		   "GET_DATA_RATE HE80 NSS2 MCS11 GI0.8 quantizes ABI value");
	EXPECT_U32(rate.param.data_rate.rx_data_rate, 2270,
		   "GET_DATA_RATE HE80 NSS2 MCS11 extended GI quantizes ABI value");
	EXPECT_U32(rate.param.data_rate.tx_nss, 1,
		   "GET_DATA_RATE HE TX zero-based NSS metadata");
	EXPECT_U32(rate.param.data_rate.rx_nss, 1,
		   "GET_DATA_RATE HE RX zero-based NSS metadata");

	ZERO(rate);
	rate.sub_command = MLAN_OID_GET_DATA_RATE;
	priv->rxpd_rate = 12;
	priv->rxpd_rate_info = MLAN_RATE_FORMAT_LG;
	run_query(priv, resp, &rate, ioctl, 5, MLAN_RATE_FORMAT_LG, 0);
	EXPECT_U32(rate.param.data_rate.tx_data_rate, 4,
		   "GET_DATA_RATE legacy TX returns hole-adjusted table index");
	EXPECT_U32(rate.param.data_rate.rx_data_rate, 11,
		   "GET_DATA_RATE legacy RX returns hole-adjusted table index");
	EXPECT_U32(ioctl->data_read_written,
		   sizeof(mlan_data_rate) + MLAN_SUB_COMMAND_SIZE,
		   "GET_DATA_RATE reports the unchanged 48-byte ABI payload");
}

static void expect_rate_cfg(mlan_private *priv, HostCmd_DS_COMMAND *resp,
			    mlan_ioctl_req *ioctl, t_u8 index, t_u8 info,
			    t_u8 ext, t_u32 expected, const char *name)
{
	mlan_ds_rate rate;

	ZERO(rate);
	rate.sub_command = MLAN_OID_RATE_CFG;
	rate.param.rate_cfg.rate_type = MLAN_RATE_VALUE;
	run_query(priv, resp, &rate, ioctl, index, info, ext);
	EXPECT_U32(rate.param.rate_cfg.rate, expected, name);
}

static void test_rate_cfg_value(mlan_private *priv,
				HostCmd_DS_COMMAND *resp,
				mlan_ioctl_req *ioctl)
{
	expect_rate_cfg(priv, resp, ioctl, 7, MLAN_RATE_FORMAT_HT, 0, 130,
			"RATE_CFG value HT20 MCS7 uses 500-kbit/s units");
	expect_rate_cfg(priv, resp, ioctl, MLAN_RATE_BITMAP_MCS0,
			MLAN_RATE_FORMAT_HT | 0x10, 0, 13,
			"RATE_CFG value HT MCS32 SGI keeps half-Mbps precision");
	expect_rate_cfg(priv, resp, ioctl, 5, MLAN_RATE_FORMAT_LG, 0, 12,
			"RATE_CFG value legacy OFDM6 uses 500-kbit/s units");
	expect_rate_cfg(priv, resp, ioctl, 0x19,
			MLAN_RATE_FORMAT_VHT | 0x08 | 0x10, 0, 1733,
			"RATE_CFG value VHT80 NSS2 MCS9 SGI avoids truncation");
	expect_rate_cfg(priv, resp, ioctl, 0x1b,
			MLAN_RATE_FORMAT_HE | 0x08, 0, 2404,
			"RATE_CFG value HE80 NSS2 MCS11 preserves u32 result");
}

int main(void)
{
	mlan_adapter adapter;
	mlan_private priv;
	HostCmd_DS_COMMAND resp;
	mlan_ioctl_req ioctl;

	ZERO(adapter);
	ZERO(priv);
	ZERO(ioctl);
	priv.adapter = &adapter;
	priv.is_data_rate_auto = MTRUE;

	EXPECT_U32(sizeof(mlan_data_rate), 48, "mlan_data_rate ABI size");
	test_raw_calculators(&adapter);
	test_get_data_rate(&priv, &resp, &ioctl);
	test_rate_cfg_value(&priv, &resp, &ioctl);

	printf("rate-query host test: %d failure(s)\n", failures);
	return failures ? 1 : 0;
}
