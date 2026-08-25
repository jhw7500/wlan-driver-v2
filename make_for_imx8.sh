#!/bin/bash
# source 로 부르면 exit 가 호출한 셸을 죽인다. 실행이면 exit, source 면 return 한다.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then _mfi_end='return'; else _mfi_end='exit'; fi
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ "$SDK_LOC" ] || SDK_LOC=/shared/fsl-imx-xwayland/6.6-nanbield
#[ "$SDK_NAME" ] || SDK_NAME=cortexa53-crypto-poky-linux
[ "$SDK_NAME" ] || SDK_NAME=armv8a-poky-linux

[ ! -e ${SDK_LOC}/environment-setup-${SDK_NAME} ] && {
    echo "Sorry, please verify: ${SDK_LOC}/environment-setup-${SDK_NAME}"
    "$_mfi_end" 1
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
        _cc_build_rc=$?   # clangd: 드라이버 빌드 상태 (뒤따르는 mapp 빌드에 가려지지 않게)
    make -C mapp/mlanutl INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} clean
    make -C mapp/mlanutl INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX}
    make -C mapp/mlanevent INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} clean
    make -C mapp/mlanevent INSTALLDIR=bin_wlan MOD_SUFFIX=${MOD_SUFFIX} "ccflags-y=${MLANEVENT_CFLAGS}"
else
    "$SCRIPT_DIR/scripts/obj_cache_swap.sh" imx8
    PKG_CONFIG_SYSROOT_DIR=${PKG_CONFIG_SYSROOT_DIR} \
        PKG_CONFIG_DIR= \
        make MOD_SUFFIX=${MOD_SUFFIX} ${@:-build}
        _cc_build_rc=$?   # clangd: 드라이버 빌드 상태 (뒤따르는 mapp 빌드에 가려지지 않게)
fi

# --- clangd: compile_commands.json 자동 갱신 ---------------------------------
# 빌드가 남긴 .cmd 파일만 파싱한다 (컴파일 없음, ~0.05초).
# 호스트 종속 경로를 담으므로 .gitignore 대상 — 각자 빌드할 때 생성된다.
# clangd 가 GCC 전용 플래그를 읽으려면 저장소의 .clangd 파일도 함께 필요하다.
_cc_rc=$?
# 드라이버 빌드 상태를 _cc_build_rc 에 기록하면서 $? 가 그 대입문 결과(항상 0)로
# 덮였을 수 있다. 드라이버 빌드가 실패했으면 그 코드를 종료 코드로 삼는다.
# (뒤따르는 mapp 빌드가 성공해도 빌드 실패가 0 으로 보고되지 않게 한다)
if [ -n "${_cc_build_rc-}" ] && [ "$_cc_build_rc" -ne 0 ]; then
    _cc_rc="$_cc_build_rc"
fi
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

if [ "${_cc_build_rc-1}" -eq 0 ] && [ "$_cc_skip" -eq 0 ]; then
    if [ -z "$_cc_kdir" ]; then
        echo "compile_commands.json 건너뜀 — 커널 빌드 디렉터리가 비었다" >&2
        [ -e "$_cc_dir/compile_commands.json" ] && echo "  기존 DB 는 직전 성공 빌드 기준이라 낡았을 수 있다." >&2
    elif [ -z "$_cc_gen" ]; then
        echo "compile_commands.json 건너뜀 — gen_compile_commands.py 를 찾지 못했다 (CC_GEN 으로 지정 가능)" >&2
        [ -e "$_cc_dir/compile_commands.json" ] && echo "  기존 DB 는 직전 성공 빌드 기준이라 낡았을 수 있다." >&2
    else
        # 고정 이름은 동시 실행 시 서로 덮어쓴다. mktemp 로 고유하게 만든다.
        _cc_tmp="$(mktemp "$_cc_dir/.compile_commands.json.XXXXXX" 2>/dev/null)" || _cc_tmp=""
        if [ -n "$_cc_tmp" ] \
           && python3 "$_cc_gen" -d "$_cc_kdir" -o "$_cc_tmp" "$SCRIPT_DIR" 2>/dev/null \
           && grep -q '"file"' "$_cc_tmp" 2>/dev/null \
           && mv -f "$_cc_tmp" "$_cc_dir/compile_commands.json"; then
            echo "compile_commands.json 갱신됨 (clangd)"
        else
            rm -f "$_cc_tmp"
            echo "compile_commands.json 갱신 실패 — 빌드 자체는 정상" >&2
    [ -e "$_cc_dir/compile_commands.json" ] && echo "  기존 DB 는 직전 성공 빌드 기준이라 낡았을 수 있다." >&2
        fi
    fi
fi

"$_mfi_end" "$_cc_rc"
