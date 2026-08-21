#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	printf '%s\n' 'recorded make calls:' >&2
	cat "$TMP/make.log" >&2
	exit 1
}

mkdir -p "$TMP/project/scripts" "$TMP/sdk" "$TMP/fake-bin"
cp "$ROOT/make_for_imx93.sh" "$TMP/project/make_for_imx93.sh"
cat >"$TMP/project/scripts/obj_cache_swap.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/project/scripts/obj_cache_swap.sh"
: >"$TMP/sdk/environment-setup-armv8a-poky-linux"
: >"$TMP/make.log"
cat >"$TMP/fake-bin/make" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MAKE_LOG"
EOF
chmod +x "$TMP/fake-bin/make"

(
	cd "$TMP/project"
	MAKE_LOG="$TMP/make.log" \
		PATH="$TMP/fake-bin:$PATH" \
		SDK_LOC="$TMP/sdk" \
		SDK_NAME=armv8a-poky-linux \
		KERNELDIR="$TMP/kernel" \
		SKIP_STATIC_CHECK=1 \
		bash ./make_for_imx93.sh
)

find_call() {
	local expected="$1"
	awk -v expected="$expected" '
		$0 == expected { print NR; found=1; exit }
		END { exit !found }
	' "$TMP/make.log"
}

mlanutl_clean="$(find_call '-C mapp/mlanutl clean')" ||
	fail 'default i.MX93 build did not clean stale mlanutl objects'
mlanevent_clean="$(find_call '-C mapp/mlanevent clean')" ||
	fail 'default i.MX93 build did not clean stale mlanevent objects'
target_build="$(find_call 'MOD_SUFFIX=_imx93 build')" ||
	fail 'default i.MX93 build did not invoke the target build'

if ((mlanutl_clean >= target_build || mlanevent_clean >= target_build)); then
	fail 'userspace clean must precede the target cross-build'
fi

printf 'make_for_imx93_qa=PASS\n'
