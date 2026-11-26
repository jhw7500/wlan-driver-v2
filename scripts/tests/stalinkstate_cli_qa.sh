#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SOURCE_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
QA_TMP="$(mktemp -d "${TMPDIR:-/tmp}/stalinkstate-cli-qa.XXXXXX")"
trap 'rm -rf -- "$QA_TMP"' EXIT

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

python3 - "$ROOT/mlinux/moal_eth_ioctl.h" \
	"$ROOT/mlinux/moal_eth_ioctl.c" <<'PY'
import re
import sys
from pathlib import Path

target = "stalinkstate"
commands = re.findall(
    r'^#define\s+(PRIV_CMD_\w+)\s+"([^"]+)"',
    Path(sys.argv[1]).read_text(),
    re.MULTILINE,
)
source = Path(sys.argv[2]).read_text()
android_literals = re.findall(
    r'(?:strnicmp|strncmp|strcasecmp|strcmp)\s*\(\s*buf(?:\s*\+[^,]+)?'
    r'\s*,\s*"([^"]+)"',
    source,
)
registered = commands + [("Android literal", value) for value in android_literals]
overlaps = [
    (name, value)
    for name, value in registered
    if value.lower() != target
    and (value.lower().startswith(target) or target.startswith(value.lower()))
]
if overlaps:
    raise SystemExit(f"stalinkstate private-command prefix overlap: {overlaps}")
PY

read -r -a QA_CC <<<"${CC:-cc}"
FLAGS=(-O2 -D_FORTIFY_SOURCE=2 -DSTA_SUPPORT -DUAP_SUPPORT -Wall
	-Wno-stringop-truncation -I"$ROOT/mapp/mlanutl" -I"$ROOT/mlan")
"${QA_CC[@]}" "${FLAGS[@]}" \
	"$ROOT/mapp/mlanutl/mlanutl.c" "$ROOT/mapp/mlanutl/mlanwls.c" \
	-lrt -o "$QA_TMP/mlanutl"

"${QA_CC[@]}" -shared -fPIC -Wall -Wextra -Werror \
	-x c -o "$QA_TMP/ioctl_fixture.so" - <<'EOF'
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

int ioctl(int fd, unsigned long request, ...)
{
	struct eth_priv_cmd *cmd;
	struct ifreq *ifr;
	const char *capture;
	const char *mode;
	va_list args;
	FILE *fp;

	(void)fd;
	(void)request;
	va_start(args, request);
	ifr = va_arg(args, struct ifreq *);
	va_end(args);
	cmd = (struct eth_priv_cmd *)ifr->ifr_data;
	if (!cmd || !cmd->buf) {
		errno = EFAULT;
		return -1;
	}

	capture = getenv("MLANUTL_IOCTL_CAPTURE");
	if (capture) {
		fp = fopen(capture, "a");
		if (!fp)
			return -1;
		fprintf(fp, "%s\n", cmd->buf);
		fclose(fp);
	}

	mode = getenv("MLANUTL_STALINKSTATE_MODE");
	if (!mode) {
		errno = EINVAL;
		return -1;
	}
	if (strcmp(mode, "ioctl_error") == 0) {
		errno = EIO;
		return -1;
	}
	if (strcmp(mode, "retry") == 0) {
		static int retry_count;

		if (!retry_count++) {
			errno = EAGAIN;
			return -1;
		}
		mode = "disconnected";
	}
	if (strcmp(mode, "zero") == 0) {
		cmd->used_len = 0;
		return 0;
	}
	if (strcmp(mode, "oversize") == 0) {
		cmd->used_len = cmd->total_len + 1;
		return 0;
	}
	if (strcmp(mode, "no_nul") == 0) {
		memcpy(cmd->buf, "bad!", 4);
		cmd->used_len = 4;
		return 0;
	}
	if (strcmp(mode, "embedded_nul") == 0) {
		static const unsigned char reply[] = {'o', 'k', 0, 'x', 'x', 0};
		memcpy(cmd->buf, reply, sizeof(reply));
		cmd->used_len = sizeof(reply);
		return 0;
	}
	if (strcmp(mode, "connected") == 0) {
		static const char reply[] =
			"association.state=connected\n"
			"association.standard=ax\n"
			"association.band=5\n"
			"association.bssid=00:11:22:33:44:55\n"
			"association.connected_sec=42\n"
			"current.channel=149\n"
			"current.width=80\n"
			"current.opermode_bw=2\n"
			"current.opermode_nss=2\n"
			"current.tx_format=he\n"
			"current.tx_bw=80\n"
			"current.rx_format=he\n"
			"current.rx_bw=80\n";
		memcpy(cmd->buf, reply, sizeof(reply));
		cmd->used_len = sizeof(reply);
		return 0;
	}
	if (strcmp(mode, "disconnected") == 0) {
		static const char reply[] =
			"association.state=disconnected\n"
			"current.channel=unavailable\n";
		memcpy(cmd->buf, reply, sizeof(reply));
		cmd->used_len = sizeof(reply);
		return 0;
	}

	errno = EINVAL;
	return -1;
}
EOF

run_mode() {
	local mode="$1"
	local expected_status="$2"
	: >"$QA_TMP/capture"
	set +e
	MLANUTL_IOCTL_CAPTURE="$QA_TMP/capture" \
		MLANUTL_STALINKSTATE_MODE="$mode" \
		LD_PRELOAD="$QA_TMP/ioctl_fixture.so" \
		"$QA_TMP/mlanutl" mlan0 stalinkstate \
		>"$QA_TMP/$mode.stdout" 2>"$QA_TMP/$mode.stderr"
	local status=$?
	set -e
	[[ "$status" -eq "$expected_status" ]] ||
		fail "$mode returned $status, expected $expected_status"
	[[ "$(head -n 1 "$QA_TMP/capture")" == "MRVL_CMDstalinkstate" ]] ||
		fail "$mode did not serialize the exact private command"
}

run_mode connected 0
grep -Fxq 'association.standard=ax' "$QA_TMP/connected.stdout" ||
	fail 'connected response was not printed unchanged'
grep -Fxq 'current.rx_bw=80' "$QA_TMP/connected.stdout" ||
	fail 'connected response was truncated'

run_mode disconnected 0
grep -Fxq 'association.state=disconnected' "$QA_TMP/disconnected.stdout" ||
	fail 'disconnected state was not printed'

run_mode retry 0
[[ "$(wc -l <"$QA_TMP/capture")" -eq 2 ]] ||
	fail 'EAGAIN did not issue exactly one retry'
grep -Fxq 'association.state=disconnected' "$QA_TMP/retry.stdout" ||
	fail 'EAGAIN retry did not print the successful response'

for mode in zero oversize no_nul embedded_nul ioctl_error; do
	run_mode "$mode" 255
done
grep -Fq 'invalid stalinkstate response' "$QA_TMP/no_nul.stderr" ||
	fail 'unterminated response did not report an error'

: >"$QA_TMP/capture"
set +e
MLANUTL_IOCTL_CAPTURE="$QA_TMP/capture" \
	MLANUTL_STALINKSTATE_MODE=connected \
	LD_PRELOAD="$QA_TMP/ioctl_fixture.so" \
	"$QA_TMP/mlanutl" mlan0 stalinkstate unexpected \
	>"$QA_TMP/args.stdout" 2>"$QA_TMP/args.stderr"
status=$?
set -e
[[ "$status" -eq 255 ]] || fail "trailing argument returned $status"
[[ ! -s "$QA_TMP/capture" ]] || fail 'trailing argument reached ioctl'
grep -Fq 'Usage: mlanutl <interface> stalinkstate' "$QA_TMP/args.stderr" ||
	fail 'trailing argument did not print command usage'

printf 'stalinkstate_cli_qa=PASS\n'
