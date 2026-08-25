#!/bin/bash

# ----------------------------------------------------------------------------
# Static checks (bridge v2~v7 규칙) — 빌드 전 선제 검증.
# 타겟 배포로 이어지는 워크플로우에서 "빌드가 성공" 자체가 의미있는 게이트
# 이므로, 여기서 구조 규칙 위반을 잡아 cross-compile 낭비 및 배포 회귀
# 차단.
# 우회:  SKIP_STATIC_CHECK=1 ./make_for_imx93.sh
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATIC_CHECK="$SCRIPT_DIR/scripts/tests/bridge_static_checks.sh"
if [ -z "$SKIP_STATIC_CHECK" ] && [ -f "$STATIC_CHECK" ]; then
    echo "make_for_imx93.sh: running static checks..."
    if ! bash "$STATIC_CHECK"; then
        echo "make_for_imx93.sh: static checks FAILED — aborting build" >&2
        echo "  강제 우회 (권장 안 함): SKIP_STATIC_CHECK=1 $0" >&2
        exit 1
    fi
fi

[ "$SDK_LOC" ] || SDK_LOC=/shared/fsl-imx-wayland/6.6-nanbield
#[ "$SDK_NAME" ] || SDK_NAME=cortexa53-crypto-poky-linux
[ "$SDK_NAME" ] || SDK_NAME=armv8a-poky-linux

[ ! -e ${SDK_LOC}/environment-setup-${SDK_NAME} ] && {
    echo "Sorry, please verify: ${SDK_LOC}/environment-setup-${SDK_NAME}"
    exit 1
}

. ${SDK_LOC}/environment-setup-${SDK_NAME}

#export KERNELDIR ?= /opt/sda/mini-6.6.3/imx-6.6.3-1.0.0-build/build-wayland/tmp/work/imx8mmevk-poky-linux/linux-imx/6.6.3+git/linux-imx-6.6.3+git
#export CROSS_COMPILE?=/shared/fsl-imx-xwayland/6.6-nanbield/sysroots/x86_64-pokysdk-linux/usr/bin/aarch64-poky-linux/aarch64-poky-linux-
#export KERNELDIR=${KERNELDIR:-/opt/sda/imx93/imx-6.6.3-1.0.0-build/build_fsl-imx-wayland/tmp/work/imx93_11x11_lpddr4x_evk-poky-linux/linux-imx/6.6.3+git/build}
export KERNELDIR=${KERNELDIR:-/opt/sda/imx93/imx-6.6.3-1.0.0-build/build_fsl-imx-wayland/tmp/work/imx93_11x11_lpddr4x_evk-poky-linux/linux-imx/6.6.3+git/linux-imx-6.6.3+git}
export CROSS_COMPILE=${CROSS_COMPILE:-${SDK_LOC}/sysroots/x86_64-pokysdk-linux/usr/bin/aarch64-poky-linux/aarch64-poky-linux-}

SYSROOT=${SDK_LOC}/sysroots/${SDK_NAME}
PKG_CONFIG_SYSROOT_DIR=${SYSROOT}
PKG_CONFIG_PATH=${SYSROOT}/usr/lib/pkgconfig

#SYSROOT_COMPONENT=/opt/desktop/build-desktop/tmp/sysroots-components/cortexa53-crypto
#export GLIBS="-I${SYSROOT_COMPONENT}/glib-2.0/usr/include/glib-2.0 -I${SYSROOT_COMPONENT}/glib-2.0/usr/lib/glib-2.0/include"

MOD_SUFFIX=${MOD_SUFFIX:-_imx93}

MLANUTL_CFLAGS="-DSTA_SUPPORT -DUAP_SUPPORT -DWIFI_DIRECT_SUPPORT -DMFG_CMD_SUPPORT -DTDLS_SUPPORT -DMULTI_CHAN_SUPPORT -DDFS_TESTING_SUPPORT -DREASSOCIATION"
# mlanevent 는 이벤트 수신 전용(netlink read-only)이라 드라이버 기능 플래그가 거의 불필요.
# WIFI_DIRECT_SUPPORT 만 P2P 이벤트 파싱 블록을 켠다.
MLANEVENT_CFLAGS="-DWIFI_DIRECT_SUPPORT"

if [ "$1" = "mlanutl" ]; then
    shift
    mkdir -p bin_wlan
    make -C mapp/mlanutl INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} clean
    make -C mapp/mlanutl INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} "ccflags-y=${MLANUTL_CFLAGS}" $@
elif [ "$1" = "mlanevent" ]; then
    shift
    mkdir -p bin_wlan
    make -C mapp/mlanevent INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} clean
    make -C mapp/mlanevent INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} "ccflags-y=${MLANEVENT_CFLAGS}" $@
elif [ "$1" = "all" ]; then
    shift
    mkdir -p bin_wlan
    "$SCRIPT_DIR/scripts/obj_cache_swap.sh" imx93
    PKG_CONFIG_SYSROOT_DIR=${PKG_CONFIG_SYSROOT_DIR} \
        PKG_CONFIG_DIR= \
        make MOD_SUFFIX=${MOD_SUFFIX} $@
    make -C mapp/mlanutl INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} clean
    make -C mapp/mlanutl INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} "ccflags-y=${MLANUTL_CFLAGS}"
    make -C mapp/mlanevent INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} clean
    make -C mapp/mlanevent INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} "ccflags-y=${MLANEVENT_CFLAGS}"
else
    "$SCRIPT_DIR/scripts/obj_cache_swap.sh" imx93
    PKG_CONFIG_SYSROOT_DIR=${PKG_CONFIG_SYSROOT_DIR} \
        PKG_CONFIG_DIR= \
        make MOD_SUFFIX=${MOD_SUFFIX} ${@:-build}
fi

# --- clangd: compile_commands.json 자동 갱신 ---------------------------------
# 빌드가 남긴 .cmd 파일만 파싱한다 (컴파일 없음, ~0.05초).
# 호스트 종속 경로를 담으므로 .gitignore 대상 — 각자 빌드할 때 생성된다.
# clangd 가 GCC 전용 플래그를 읽으려면 저장소의 .clangd 파일도 함께 필요하다.
_cc_rc=$?
_cc_dir="$SCRIPT_DIR"
_cc_kdir="$KERNELDIR"

# clean 류가 인자에 하나라도 섞이면 건너뛴다 ("clean all" 처럼 혼합돼도 안전하게).
_cc_skip=0
for _cc_a in "$@"; do
    case "$_cc_a" in clean|distclean|mrproper|realclean) _cc_skip=1 ;; esac
done

# 생성기 위치: O= 빌드 dir 은 source/ 심볼릭 링크로, in-tree 는 직접 scripts/ 로
# 잡힌다. 어느 쪽도 아니면 CC_GEN 으로 지정한다.
_cc_gen="${CC_GEN:-}"
if [ -z "$_cc_gen" ]; then
    for _cc_c in "$_cc_kdir/source/scripts/clang-tools/gen_compile_commands.py" \
                 "$_cc_kdir/scripts/clang-tools/gen_compile_commands.py"; do
        if [ -f "$_cc_c" ]; then _cc_gen="$_cc_c"; break; fi
    done
fi

if [ "$_cc_rc" -eq 0 ] && [ "$_cc_skip" -eq 0 ]; then
    if [ -z "$_cc_kdir" ]; then
        echo "compile_commands.json 건너뜀 — 커널 빌드 디렉터리가 비었다" >&2
    elif [ -z "$_cc_gen" ]; then
        echo "compile_commands.json 건너뜀 — gen_compile_commands.py 를 찾지 못했다 (CC_GEN 으로 지정 가능)" >&2
    else
        _cc_tmp="$_cc_dir/.compile_commands.json.tmp"
        if python3 "$_cc_gen" -d "$_cc_kdir" -o "$_cc_tmp" "$SCRIPT_DIR" 2>/dev/null \
           && grep -q '"file"' "$_cc_tmp" 2>/dev/null; then
            mv -f "$_cc_tmp" "$_cc_dir/compile_commands.json"
            echo "compile_commands.json 갱신됨 (clangd)"
        else
            rm -f "$_cc_tmp"
            echo "compile_commands.json 갱신 실패 — 빌드 자체는 정상" >&2
        fi
    fi
fi

# source 로 부르면 exit 가 호출한 셸을 죽인다. 실행일 때만 exit 한다.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return "$_cc_rc"
fi
exit "$_cc_rc"
