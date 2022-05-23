#!/bin/bash
############################################################################
# This script simply formats a block device and mounts it to the data
# directory in a very safe manner by checking that the block device is
# completely empty
#
############################################################################
set -eu

if [ $# -ne 2 ]
then
	echo "";
	echo "    Usage: ./${0} <block_device> <mount_directory>";
	echo;
	echo "    Example: ./${0} /dev/vdb /data";
	echo;
	echo "    To figure out the block devices on the machine use lsblk command";
	echo "";
	exit 1;
fi

set -x
BLOCK_DEVICE_PATH="${1}"
MOUNT_TO_DIR="${2}"

## SAFETY CHECK ###########################################################
# Check if ${BLOCK_DEVICE_PATH} is mounted, if yes, then exit
if [[ $(/bin/mount | grep -q "${BLOCK_DEVICE_PATH}") ]]; then
  echo "BLOCK DEVICE ${BLOCK_DEVICE_PATH} ALREADY MOUNTED"
  exit 1;
fi

## SAFETY CHECK ###########################################################
if [[ $(/sbin/blkid ${BLOCK_DEVICE_PATH}) ]]; then
  echo "BLOCK DEVICE ALREADY INITIALIZED, WILL NOT PROCEED WITH SCRIPT";
  exit 1;
fi

## CREATE PARTITION TABLE AND CREATE PARTITION
parted --script ${BLOCK_DEVICE_PATH} mklabel gpt
parted --script ${BLOCK_DEVICE_PATH} unit s
parted --script -a optimal ${BLOCK_DEVICE_PATH} mkpart primary ext4 0% 100%

## NEEDED FOR lsblk TO REFRESH
echo "Sleeping 5 seconds"
sleep 5;

## PARTITIONNAME WITHOUT '/dev' 
PARTITION_NAME=`lsblk -l ${BLOCK_DEVICE_PATH} | tail -1 | awk '{print $1}'`

## SAFETY CHECK ###########################################################
if [[ ${#PARTITION_NAME} -ne 4 ]]; then
  echo "EXITING SINCE [$PARTITION_NAME] DOES NOT CONTAIN 4 CHARACTERS";
  exit 1;
fi;

## Format it as ext4
mkfs.ext4 -m 2 "/dev/$PARTITION_NAME"

## Create a mount directory at /data if does not exist
mkdir -p "${MOUNT_TO_DIR}"


# Mount it in /etc/fstab
UUID_STRING=`blkid -o export /dev/$PARTITION_NAME | grep "^UUID"`
FSTABCOM=`sudo lshw -class disk -businfo | grep $BLOCK_DEVICE_PATH | awk '{$2=$3=$4=""; print $0}'`
echo -e "\n###$FSTABCOM" >> /etc/fstab
echo -e "$UUID_STRING ${MOUNT_TO_DIR} ext4 defaults,nofail 0 0" >> /etc/fstab

# Run mount -a
mount -a

# TO UNDO WHAT THE SCRIPT HAS DONE
# PLEASE DO NOT COMMENT THIS OUT, ONLY SERVES FOR DOCUMENTATION
# USE ONLY WHEN YOU ARE SURE WHAT YOU ARE DOING
# umount /dev/vdb1
# wipefs -a /dev/sdf1
# parted /dev/sdf rm 1
# wipefs -a /dev/sdf