#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
MLANUTL="$ROOT/mapp/mlanutl/mlanutl"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

# mlanutl's flat object directory does not encode the compiler architecture.
# A preceding target build may therefore leave aarch64 objects that host QA
# cannot execute; establish a host-clean fixture before compiling the CLI.
make -C "$ROOT/mapp/mlanutl" clean >/dev/null
make -C "$ROOT/mapp/mlanutl" mlanutl >/dev/null

cat >"$TMP/ioctl_capture.c" <<'EOF'
#define _GNU_SOURCE
#include <stdarg.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <net/if.h>

struct eth_priv_cmd {
	unsigned char *buf;
	int used_len;
	int total_len;
};

static int reply_words(struct eth_priv_cmd *cmd, const int *words,
		       size_t word_count)
{
	size_t len = word_count * sizeof(*words);

	if (len > (size_t)cmd->total_len)
		return -1;
	memcpy(cmd->buf, words, len);
	cmd->used_len = (int)len;
	return 0;
}

int ioctl(int fd, unsigned long request, ...)
{
	struct eth_priv_cmd *cmd;
	struct ifreq *ifr;
	const char *abi;
	const char *capture;
	char request_buf[128];
	va_list args;
	FILE *fp;

	(void)fd;
	(void)request;
	va_start(args, request);
	ifr = va_arg(args, struct ifreq *);
	va_end(args);
	cmd = (struct eth_priv_cmd *)ifr->ifr_data;
	capture = getenv("MLANUTL_IOCTL_CAPTURE");
	if (!cmd || !cmd->buf || !capture)
		return -1;
	strncpy(request_buf, (const char *)cmd->buf, sizeof(request_buf) - 1);
	request_buf[sizeof(request_buf) - 1] = '\0';
	fp = fopen(capture, "a");
	if (!fp)
		return -1;
	fprintf(fp, "%s\n", request_buf);
	fclose(fp);

	abi = getenv("MLANUTL_ANTCFG_ABI");
	if (!abi) {
		cmd->used_len = 0;
		return 0;
	}

	if (strcmp(request_buf, "MRVL_CMDantcfg") == 0) {
		if (strcmp(abi, "main") == 0) {
			const int words[] = {0x303, 0x303, 0x2121, 0};
			return reply_words(cmd, words, 4);
		}
		if (strcmp(abi, "ported") == 0) {
			const int words[] = {0x303, 0x303, 1, 2};
			return reply_words(cmd, words, 4);
		}
		if (strcmp(abi, "legacy") == 0) {
			const int words[] = {0x303, 0x303};
			return reply_words(cmd, words, 2);
		}
		if (strcmp(abi, "1x1") == 0) {
			const int words[] = {0xffff, 10, 1};
			return reply_words(cmd, words, 3);
		}
	}

	if (strcmp(request_buf, "MRVL_CMDantcfgnss") == 0) {
		if (strcmp(abi, "ported") == 0) {
			const int words[] = {0x2121};
			return reply_words(cmd, words, 1);
		}
		errno = EOPNOTSUPP;
		return -1;
	}

	cmd->used_len = 0;
	return 0;
}
EOF

${CC:-cc} -shared -fPIC -Wall -Wextra -Werror \
	-o "$TMP/ioctl_capture.so" "$TMP/ioctl_capture.c"

run_valid() {
	local expected="$1"
	shift
	: >"$TMP/capture"
	MLANUTL_IOCTL_CAPTURE="$TMP/capture" \
		LD_PRELOAD="$TMP/ioctl_capture.so" \
		"$MLANUTL" mlan0 antcfg "$@" >"$TMP/stdout" 2>"$TMP/stderr" ||
		fail "valid antcfg form rejected: $*"
	[[ "$(head -n 1 "$TMP/capture")" == "$expected" ]] ||
		fail "serialized '$*' as '$(head -n 1 "$TMP/capture")', expected '$expected'"
}

run_invalid() {
	: >"$TMP/capture"
	if MLANUTL_IOCTL_CAPTURE="$TMP/capture" \
		LD_PRELOAD="$TMP/ioctl_capture.so" \
		"$MLANUTL" mlan0 antcfg "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then
		fail "invalid antcfg form accepted: $*"
	fi
	[[ ! -s "$TMP/capture" ]] || fail "invalid antcfg form reached ioctl: $*"
	grep -Fq \
		'usage: mlanutl <interface> antcfg [<tx> | <tx> <rx> | <tx> <rx> <tx_6g> <rx_6g>]' \
		"$TMP/stdout" || fail "invalid antcfg form did not print the supported forms"
}

run_get_abi() {
	local abi="$1"

	: >"$TMP/capture"
	MLANUTL_IOCTL_CAPTURE="$TMP/capture" \
		MLANUTL_ANTCFG_ABI="$abi" \
		LD_PRELOAD="$TMP/ioctl_capture.so" \
		"$MLANUTL" mlan0 antcfg >"$TMP/$abi.stdout" \
		2>"$TMP/$abi.stderr" || fail "$abi antcfg GET failed"
}

run_valid 'MRVL_CMDantcfg'
run_valid 'MRVL_CMDantcfg1' 1
run_valid 'MRVL_CMDantcfg1 2' 1 2
run_valid 'MRVL_CMDantcfg1 2 3 4' 1 2 3 4
run_invalid 1 2 3
run_invalid 1 2 3 4 5

run_get_abi main
grep -Fq 'Mode of Tx path is 0x303' "$TMP/main.stdout" ||
	fail 'main ABI did not print Tx antenna mode'
grep -Fq 'Mode of Rx path is 0x303' "$TMP/main.stdout" ||
	fail 'main ABI did not print Rx antenna mode'
grep -Fq 'NSS limit (antcfg): 2G rx=1 tx=2, 5G rx=1 tx=2  [user_htstream=0x2121]' \
	"$TMP/main.stdout" || fail 'main ABI did not decode word 2 as user_htstream'
if grep -Fq 'for 6G' "$TMP/main.stdout"; then
	fail 'main ABI NSS/reserved words were misreported as 6 GHz antenna modes'
fi

run_get_abi ported
grep -Fq 'Mode of Tx path for 6G is 0x1' "$TMP/ported.stdout" ||
	fail 'ported ABI did not print 6 GHz Tx antenna mode'
grep -Fq 'Mode of Rx path for 6G is 0x2' "$TMP/ported.stdout" ||
	fail 'ported ABI did not print 6 GHz Rx antenna mode'
grep -Fq 'NSS limit (antcfg): 2G rx=1 tx=2, 5G rx=1 tx=2  [user_htstream=0x2121]' \
	"$TMP/ported.stdout" || fail 'ported ABI did not read split antcfgnss'

run_get_abi legacy
grep -Fq 'Mode of Tx path is 0x303' "$TMP/legacy.stdout" ||
	fail 'legacy ABI did not print Tx antenna mode'
grep -Fq 'Mode of Rx path is 0x303' "$TMP/legacy.stdout" ||
	fail 'legacy ABI did not print Rx antenna mode'
if grep -Fq 'NSS limit' "$TMP/legacy.stdout"; then
	fail 'legacy ABI fabricated an NSS value'
fi

run_get_abi 1x1
grep -Fq 'Mode of Tx/Rx path is 0xffff' "$TMP/1x1.stdout" ||
	fail '1x1 ABI lost its three-word antenna rendering'
grep -Fq 'Evaluate time = 10' "$TMP/1x1.stdout" ||
	fail '1x1 ABI did not print evaluate time'
grep -Fq 'Current antenna is 1' "$TMP/1x1.stdout" ||
	fail '1x1 ABI did not print current antenna'

printf 'antcfg_cli_qa=PASS\n'
