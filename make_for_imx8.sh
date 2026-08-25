#!/bin/bash
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ "$SDK_LOC" ] || SDK_LOC=/shared/fsl-imx-xwayland/6.6-nanbield
#[ "$SDK_NAME" ] || SDK_NAME=cortexa53-crypto-poky-linux
[ "$SDK_NAME" ] || SDK_NAME=armv8a-poky-linux

[ ! -e ${SDK_LOC}/environment-setup-${SDK_NAME} ] && {
    echo "Sorry, please verify: ${SDK_LOC}/environment-setup-${SDK_NAME}"
    exit 1
}

. ${SDK_LOC}/environment-setup-${SDK_NAME}

export KERNELDIR=${KERNELDIR:-/opt/sda/mini-6.6.3/imx-6.6.3-1.0.0-build/build-wayland/tmp/work/imx8mmevk-poky-linux/linux-imx/6.6.3+git/linux-imx-6.6.3+git}
export CROSS_COMPILE=${CROSS_COMPILE:-/shared/fsl-imx-xwayland/6.6-nanbield/sysroots/x86_64-pokysdk-linux/usr/bin/aarch64-poky-linux/aarch64-poky-linux-}

SYSROOT=${SDK_LOC}/sysroots/${SDK_NAME}
PKG_CONFIG_SYSROOT_DIR=${SYSROOT}
PKG_CONFIG_PATH=${SYSROOT}/usr/lib/pkgconfig

#SYSROOT_COMPONENT=/opt/desktop/build-desktop/tmp/sysroots-components/cortexa53-crypto
#export GLIBS="-I${SYSROOT_COMPONENT}/glib-2.0/usr/include/glib-2.0 -I${SYSROOT_COMPONENT}/glib-2.0/usr/lib/glib-2.0/include"

MOD_SUFFIX=${MOD_SUFFIX:-_imx8}

MLANUTL_CFLAGS="-DSTA_SUPPORT -DUAP_SUPPORT -DWIFI_DIRECT_SUPPORT -DMFG_CMD_SUPPORT -DTDLS_SUPPORT -DMULTI_CHAN_SUPPORT -DDFS_TESTING_SUPPORT"
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
    "$SCRIPT_DIR/scripts/obj_cache_swap.sh" imx8
    PKG_CONFIG_SYSROOT_DIR=${PKG_CONFIG_SYSROOT_DIR} \
        PKG_CONFIG_DIR= \
        make MOD_SUFFIX=${MOD_SUFFIX} $@
    make -C mapp/mlanutl INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} clean
    make -C mapp/mlanutl INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX}
    make -C mapp/mlanevent INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} clean
    make -C mapp/mlanevent INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} "ccflags-y=${MLANEVENT_CFLAGS}"
else
    "$SCRIPT_DIR/scripts/obj_cache_swap.sh" imx8
    PKG_CONFIG_SYSROOT_DIR=${PKG_CONFIG_SYSROOT_DIR} \
        PKG_CONFIG_DIR= \
        make MOD_SUFFIX=${MOD_SUFFIX} ${@:-build}
fi

# --- clangd: compile_commands.json 자동 갱신 ---------------------------------
# 빌드가 남긴 .cmd 파일만 파싱한다 (컴파일 없음, ~0.05초).
# 호스트 종속 경로를 담으므로 .gitignore 대상 — 각자 빌드할 때 생성된다.
# clangd 가 GCC 전용 플래그를 읽으려면 저장소의 .clangd 파일도 함께 필요하다.
_cc_rc=$?
_cc_gen="$KERNELDIR/source/scripts/clang-tools/gen_compile_commands.py"
_cc_dir="$SCRIPT_DIR"
if [ "$_cc_rc" -eq 0 ] && [ -f "$_cc_gen" ] && ! printf '%s\n' "$@" | grep -qxE 'clean|distclean'; then
    _cc_tmp="$_cc_dir/.compile_commands.json.tmp"
    if python3 "$_cc_gen" -d "$KERNELDIR" -o "$_cc_tmp" "$SCRIPT_DIR" 2>/dev/null \
       && grep -q '"file"' "$_cc_tmp" 2>/dev/null; then
        mv -f "$_cc_tmp" "$_cc_dir/compile_commands.json"
        echo "compile_commands.json 갱신됨 (clangd)"
    else
        rm -f "$_cc_tmp"
        echo "compile_commands.json 갱신 실패 — 빌드 자체는 정상" >&2
    fi
fi
exit "$_cc_rc"
