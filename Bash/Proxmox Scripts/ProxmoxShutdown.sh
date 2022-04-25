#!/bin/bash

# get list of VMs on the node
VMIDs=$(/usr/sbin/qm list| awk '/[0-9]/ {print $1}')

# ask them to shutdown
for VM in $VMIDs
do
    /usr/sbin/qm shutdown $VM
done


#wait until they're done (and down)
for VM in $VMIDs
do
    while [[ $(/usr/sbin/qm status $VM) =~ running ]] ; do
        sleep 1
    done
done

## do the reboot
shutdown -r now