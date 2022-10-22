#!/bin/bash

DRIVER_NAME="ixgbe"
DRIVER_VERSION="5.13.4"
DRIVER_FILE="${DRIVER_NAME}-${DRIVER_VERSION}.tar.gz"
LOCATION="/tmp/${DRIVER_NAME}/"
LINK="https://downloadmirror.intel.com/682680/ixgbe-${DRIVER_VERSION}.tar.gz"

mkdir -p ${LOCATION}
wget ${LINK} -O "${LOCATION}${DRIVER_FILE}"
tar xzf "${LOCATION}${DRIVER_FILE}" -C ${LOCATION}

apt-get --yes --force-yes --fix-missing install build-essential linux-headers-$(uname -r) 

rm /usr/src/linux
ln -s /usr/src/linux-headers-$(uname -r) /usr/src/linux
mkdir -p /usr/src/linux/include/linux

cd "${LOCATION}/${DRIVER_NAME}-${DRIVER_VERSION}/src/"
make install
update-initramfs -k all -u
