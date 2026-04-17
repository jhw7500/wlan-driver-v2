#!/bin/bash
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

if [ "$1" = "mlanutl" ]; then
    shift
    make -C mapp/mlanutl INSTALLDIR=../../ MOD_SUFFIX=${MOD_SUFFIX} clean
    make -C mapp/mlanutl INSTALLDIR=../../ MOD_SUFFIX=${MOD_SUFFIX} "ccflags-y=${MLANUTL_CFLAGS}" $@
elif [ "$1" = "all" ]; then
    shift
    PKG_CONFIG_SYSROOT_DIR=${PKG_CONFIG_SYSROOT_DIR} \
        PKG_CONFIG_DIR= \
        make MOD_SUFFIX=${MOD_SUFFIX} $@
    make -C mapp/mlanutl INSTALLDIR=../../ MOD_SUFFIX=${MOD_SUFFIX} clean
    make -C mapp/mlanutl INSTALLDIR=../../ MOD_SUFFIX=${MOD_SUFFIX}
else
    PKG_CONFIG_SYSROOT_DIR=${PKG_CONFIG_SYSROOT_DIR} \
        PKG_CONFIG_DIR= \
        make MOD_SUFFIX=${MOD_SUFFIX} ${@:-build}
fi
