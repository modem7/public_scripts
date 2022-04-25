#!/bin/bash

##Disk align-check
## Usage:
## Run as root
## Change DEVICE to disk you wish to check.

DEVICE=/dev/sda && for i in `sudo parted $DEVICE print | grep -oE "^[[:blank:]]*[0-9]+"`; do   sudo parted $DEVICE align-check opt "$i"; done