#!/bin/bash
#cp ../moal.ko ../../wlan-package/dist/wlan/opt/wlan/driver/moal_.ko
#cp ../mlan.ko ../../wlan-package/dist/wlan/opt/wlan/driver/mlan_.ko
PJTDIR="/home/jhw/ai/opencode/projects"
cp $PJTDIR/wlan-driver-v2/bin_wlan/*.ko $PJTDIR/wlan-package/dist/wlan/opt/wlan/driver/
cp $PJTDIR/wlan-driver-v2/bin_wlan/mlanutl_imx8 $PJTDIR/wlan-package/dist/wlan/opt/wlan/bin/
cp $PJTDIR/wlan-driver-v2/bin_wlan/mlanutl_imx93 $PJTDIR/wlan-package/dist/wlan/opt/wlan/bin/
cp $PJTDIR/wlan-driver-v2/bin_wlan/mlanevent_imx8 $PJTDIR/wlan-package/dist/wlan/opt/wlan/bin/
cp $PJTDIR/wlan-driver-v2/bin_wlan/mlanevent_imx93 $PJTDIR/wlan-package/dist/wlan/opt/wlan/bin/
# docs → 배포본 bin 디렉토리 (NXP README_* 들과 동일 위치)
cp $PJTDIR/wlan-driver-v2/docs/README_MLAN $PJTDIR/wlan-package/dist/wlan/opt/wlan/bin/
