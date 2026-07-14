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
