#!/bin/bash

# KVM UUID Recreator
# Use this for new VM's or templates that require a unique machine ID.

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

UUID=$(dmidecode -s system-uuid | tr -d '-')
if grep -q "$UUID" /etc/machine-id; then
    echo "UUID matches"
else
    echo "UUID does not match. Recreating."
    echo -n > /etc/machine-id && echo -n > /var/lib/dbus/machine-id && systemd-machine-id-setup
fi