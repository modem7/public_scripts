#!/bin/bash
set -e

### Colour Vars ###
cecho(){
    RED="\033[0;31m"
    GREEN="\033[0;32m"
    YELLOW="\033[1;33m"
    # ... ADD MORE COLORS
    NC="\033[0m" # No Color
    # ZSH
    # printf "${(P)1}${2} ${NC}\n"
    # Bash
    printf "${!1}${2} ${NC}\n"
}

### Usage ###

### Requirements ###
## Needs cloud-utils package to install "growpart"

REQUIRED_PKG="cloud-utils"
PKG_OK=$(dpkg --get-selections $REQUIRED_PKG 2>&1 | grep -v 'install$' | awk '{ print $6 }')
cecho "YELLOW" "Checking for $REQUIRED_PKG"
if [ "$REQUIRED_PKG" = "$PKG_OK" ]; then
  cecho "RED" "$REQUIRED_PKG not installed. Please run apt-get install $REQUIRED_PKG to continue."
  exit 1
else
  cecho "GREEN" "$REQUIRED_PKG installed. Continuing."
fi

if [[ $# -eq 0 ]] ; then
    echo 'Please tell me the device to resize as the first parameter, like /dev/sda'
    cecho "YELLOW" "Usage: ./size.sh <device> <partition number>"
    cecho "YELLOW" "E.G.: ./size.sh /dev/sda 1"
    exit 1
fi


if [[ $# -eq 1 ]] ; then
    echo 'Please tell me the partition number to resize as the second parameter, like 1 in case you mean /dev/sda1 or 4, if you mean /dev/sda2'
    cecho "YELLOW" "Usage: ./size.sh <device> <partition number>"
    cecho "YELLOW" "E.G.: ./size.sh /dev/sda 1"
    exit 1
fi

if [[ $# -eq 2 ]] ; then
    cecho "RED" '### Sandbox mode ### - Use 'apply' as the 3rd parameter to apply the changes'
    cecho "YELLOW" "Usage: ./size.sh <device> <partition number> apply"
    cecho "YELLOW" "E.G.: ./size.sh /dev/sda 1 apply"
fi

### Script Start ###

DEVICE=$1
PARTNR=$2
APPLY=$3

fdisk -l $DEVICE$PARTNR >> /dev/null 2>&1 || (echo "could not find device $DEVICE$PARTNR - please check the name" && exit 1)

CURRENTSIZEB=`fdisk -l $DEVICE$PARTNR | grep "Disk $DEVICE$PARTNR" | cut -d' ' -f5`
CURRENTSIZE=`expr $CURRENTSIZEB / 1024 / 1024`
# So get the disk-informations of our device in question printf %s\\n 'unit MB print list' | parted | grep "Disk /dev/sda we use printf %s\\n 'unit MB print list' to ensure the units are displayed as MB, since otherwise it will vary by disk size ( MB,># then use the 3rd column of the output (disk size) cut -d' ' -f3 (divided by space)
# and finally cut off the unit 'MB' with blanc using tr -d MB
MAXSIZEMB=`printf %s\\n 'unit MB print list' | parted 2> /dev/null | grep "Disk ${DEVICE}" | cut -d' ' -f3 | tr -d MB`

#clear
cecho "GREEN" "[ok] Will resize from ${CURRENTSIZE}MB to ${MAXSIZEMB}MB "

if [[ "$APPLY" == "apply" ]] ; then
  echo "[ok] applying resize operation.."

echo "Growing Partition"
growpart $DEVICE $PARTNR

echo "Resizing Partition"
resize2fs -f $DEVICE$PARTNR

  echo "[done]"
else
  echo "[WARNING]!: Sandbox mode, I did not size!. Use 'apply' as the 3rd parameter to apply the changes"
fi