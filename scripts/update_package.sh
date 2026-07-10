#!/bin/bash
#cp ../moal.ko ../../wlan-package/dist/wlan/opt/wlan/driver/moal_.ko
#cp ../mlan.ko ../../wlan-package/dist/wlan/opt/wlan/driver/mlan_.ko
PJTDIR="/home/jhw/ai/opencode/projects"
cp $PJTDIR/wlan-driver-v2/bin_wlan/*.ko $PJTDIR/wlan-package/dist/wlan/opt/wlan/driver/
cp $PJTDIR/wlan-driver-v2/bin_wlan/mlanutl_imx8 $PJTDIR/wlan-package/dist/wlan/opt/wlan/bin/
cp $PJTDIR/wlan-driver-v2/bin_wlan/mlanutl_imx93 $PJTDIR/wlan-package/dist/wlan/opt/wlan/bin/
