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

int ioctl(int fd, unsigned long request, ...)
{
	struct eth_priv_cmd *cmd;
	struct ifreq *ifr;
	const char *capture;
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
	fp = fopen(capture, "a");
	if (!fp)
		return -1;
	fprintf(fp, "%s\n", cmd->buf);
	fclose(fp);
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

run_valid 'MRVL_CMDantcfg'
run_valid 'MRVL_CMDantcfg1' 1
run_valid 'MRVL_CMDantcfg1 2' 1 2
run_valid 'MRVL_CMDantcfg1 2 3 4' 1 2 3 4
run_invalid 1 2 3
run_invalid 1 2 3 4 5

printf 'antcfg_cli_qa=PASS\n'
