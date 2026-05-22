#!/bin/bash
# ----------------------------------------------------------------------------
# obj_cache_swap.sh <target>
#
# 한 소스 트리(M=$(PWD) 빌드)에서 imx93 / imx8 커널모듈 오브젝트를
# 타겟별로 분리 보관한다. 타겟 전환 시 .o/.ko/.*.cmd 가 서로 덮어써져
# 매번 전량 재빌드되던 문제를 막는다.
#
# 동작:
#   - 현재 트리에 있는 산출물이 "직전 타겟" 것이면 .build-cache/<직전>/ 로 stash
#   - 요청 타겟 캐시(.build-cache/<요청>/)가 있으면 트리로 restore
#   - 소스가 안 바뀌었으면 kbuild 가 .cmd 일치를 보고 재컴파일을 건너뜀
#
# 마커: .build-cache/.current = 지금 트리에 올라와 있는 타겟 이름
# 캐시/마커는 .gitignore 처리(.build-cache/).
# ----------------------------------------------------------------------------
set -u

TARGET="${1:?usage: obj_cache_swap.sh <target>}"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

CACHE=".build-cache"
MARKER="$CACHE/.current"
mkdir -p "$CACHE"

# 커널모듈 빌드 산출물만 대상. mapp(유저스페이스)/bin_wlan(최종 복사본)/.git/.build-cache 는 제외.
find_artifacts() {
	find . \
		-path ./.build-cache -prune -o \
		-path ./.git -prune -o \
		-path ./mapp -prune -o \
		-path ./bin_wlan -prune -o \
		-type f \( \
			-name '*.o' -o -name '*.ko' -o -name '*.mod' \
			-o -name '*.mod.c' -o -name '.*.cmd' \
			-o -name 'modules.order' -o -name 'Module.symvers' \
		\) -print
}

stash() { # $1: 캐시에 넣을 타겟 이름
	local d="$CACHE/$1"
	rm -rf "$d"
	mkdir -p "$d"
	find_artifacts | while IFS= read -r f; do
		mkdir -p "$d/$(dirname "$f")"
		mv -f "$f" "$d/$f"
	done
	[ -d .tmp_versions ] && mv -f .tmp_versions "$d/"
	return 0
}

restore() { # $1: 트리로 되돌릴 타겟 이름
	local d="$CACHE/$1"
	[ -d "$d" ] || return 0
	(cd "$d" && find . -type f -print) | while IFS= read -r f; do
		mkdir -p "$(dirname "$f")"
		mv -f "$d/$f" "$f"
	done
	[ -d "$d/.tmp_versions" ] && mv -f "$d/.tmp_versions" .
	return 0
}

# 트리에 올라온 현재 타겟 판별: 마커 우선, 없으면 컴파일 .o.cmd 의
# KERNELDIR 시그니처로 추정(부트스트랩 1회용). 컴파일 커맨드에는 커널 헤더
# 경로가 박히므로 링크 커맨드만 잡히는 일이 없도록 전체 .o.cmd 를 스캔한다.
current_target() {
	if [ -f "$MARKER" ]; then
		cat "$MARKER"
		return 0
	fi
	if grep -rqls --include='.*.o.cmd' \
		--exclude-dir=.build-cache --exclude-dir=.git --exclude-dir=mapp \
		'imx93_11x11' . 2>/dev/null; then
		echo imx93
	elif grep -rqls --include='.*.o.cmd' \
		--exclude-dir=.build-cache --exclude-dir=.git --exclude-dir=mapp \
		'imx8mmevk' . 2>/dev/null; then
		echo imx8
	fi
	return 0
}

CURRENT="$(current_target)"

if [ "$CURRENT" = "$TARGET" ]; then
	echo "obj-cache: '$TARGET' 오브젝트가 이미 트리에 있음 — 증분 빌드"
	echo "$TARGET" > "$MARKER"
	exit 0
fi

if [ -n "$CURRENT" ]; then
	echo "obj-cache: '$CURRENT' 오브젝트 보관 -> $CACHE/$CURRENT"
	stash "$CURRENT"
fi

if [ -d "$CACHE/$TARGET" ]; then
	echo "obj-cache: '$TARGET' 오브젝트 복원 <- $CACHE/$TARGET (증분 빌드)"
	restore "$TARGET"
else
	echo "obj-cache: '$TARGET' 캐시 없음 — 최초 전량 빌드"
fi

echo "$TARGET" > "$MARKER"
exit 0
