#!/bin/bash

# Proxmox Ubuntu template create script.
# This script is designed to be run on the Proxmox host.

# Source
# https://www.yanboyang.com/clouldinit/
# and
# https://gist.github.com/chriswayg/43fbea910e024cbe608d7dcb12cb8466

# Prerequesites:
# Install "apt-get install libguestfs-tools".

# Check if libguestfs-tools is installed - exit if it isn't.
REQUIRED_PKG="libguestfs-tools"
PKG_OK=$(dpkg-query -W --showformat='${Status}\n' $REQUIRED_PKG|grep "install ok installed")
echo "Checking for $REQUIRED_PKG: $PKG_OK"
if [ "" = "$PKG_OK" ]; then
  echo "No $REQUIRED_PKG. Please run apt-get install $REQUIRED_PKG."
  exit
fi

# Image variables
SRC_VER="jammy"
SRC_URL="https://cloud-images.ubuntu.com/${SRC_VER}/current/${SRC_VER}-server-cloudimg-amd64.img"
SRC_IMG=${SRC_URL##*/}
IMG_NAME="${SRC_IMG/.img/.qcow2}"
WORK_DIR="/tmp"
DELETEIMG="yes" # Set to no if you don't want the image and qcow files to be deleted (useful in Dev)

# Download image
cd $WORK_DIR
wget -N $SRC_URL

# Copy downloaded img to qcow2 format
cp $SRC_IMG $IMG_NAME

# Image variables
OSNAME="Ubuntu 22.04"
TEMPL_NAME_DEFAULT="ubuntu2204-cloud-master"
read -p "Enter a VM Template Name [$TEMPL_NAME_DEFAULT]: " TEMPL_NAME
TEMPL_NAME=${TEMPL_NAME:-$TEMPL_NAME_DEFAULT}
VMID_DEFAULT="52000"
read -p "Enter a VM ID for $OSNAME [$VMID_DEFAULT]: " VMID
VMID=${VMID:-$VMID_DEFAULT}
CLOUD_USER_DEFAULT="root"
read -p "Enter a Cloud-Init Username for $OSNAME [$CLOUD_USER_DEFAULT]: " CLOUD_USER
CLOUD_USER=${CLOUD_USER:-$CLOUD_USER_DEFAULT}
GENPASS=$(date +%s | sha256sum | base64 | head -c 16 ; echo)
CLOUD_PASSWORD_DEFAULT=$GENPASS
read -p "Enter a Cloud-Init Password for $OSNAME [$CLOUD_PASSWORD_DEFAULT]: " CLOUD_PASSWORD
CLOUD_PASSWORD=${CLOUD_PASSWORD:-$CLOUD_PASSWORD_DEFAULT}
MEM="2048"
BALLOON="768"
DISK_SIZE="15G"
DISK_STOR="Proxmox"
NET_BRIDGE="vmbr1"
VLAN="50" # Set if you have VLAN requirements
QUEUES="2"
CORES="2"
OS_TYPE="l26"
AGENT_ENABLE="1" #change to 0 if you don't want the guest agent
FSTRIM="1"
BIOS="ovmf" # Choose between ovmf or seabios
MACHINE="q35"
VIRTPKG="qemu-guest-agent,cloud-utils,cloud-guest-utils"
TZ="Europe/London"
SSHKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOFLnUCnFyoONBwVMs1Gj4EqERx+Pc81dyhF6IuF26WM proxvms" #Unset if you don't want to use this. Use the public key.
SETX11="yes" # "yes" or "no" required
X11LAYOUT="gb"
X11MODEL="pc105"
LOCALLANG="en_GB.UTF-8"
## Create VM Notes
### Start of notes
mapfile -d '' NOTES << 'EOF'
When modifying this template, make sure you run this at the end

apt-get clean /\
&& apt -y autoremove --purge /\
&& apt -y clean /\
&& apt -y autoclean /\
&& cloud-init clean /\
&& echo -n > /etc/machine-id /\
&& echo -n > /var/lib/dbus/machine-id /\
&& sync /\
&& history -c /\
&& history -w /\
&& fstrim -av /\
&& shutdown now
EOF
### End of notes

# install qemu-guest-agent inside image
if [ -n "${TZ+set}" ]; then
  echo "### Setting up TZ ###"
  virt-customize -a $IMG_NAME --timezone $TZ
fi

if [ $SETX11 == 'yes' ]; then
  echo "### Setting up keyboard language and locale ###"
  virt-customize -a $IMG_NAME \
  --firstboot-command "localectl set-locale LANG=$LOCALLANG" \
  --firstboot-command "localectl set-x11-keymap $X11LAYOUT $X11MODEL"
fi

echo "### Updating system and Installing packages ###"
virt-customize -a $IMG_NAME --update --install $VIRTPKG

echo "### Creating Proxmox Cloud-init config ###"
echo -n > /tmp/99_pve.cfg
cat > /tmp/99_pve.cfg <<EOF
# to update this file, run dpkg-reconfigure cloud-init
datasource_list: [ NoCloud, ConfigDrive ]
EOF

echo "### Copying Proxmox Cloud-init config to image ###"
virt-customize -a $IMG_NAME --upload 99_pve.cfg:/etc/cloud/cloud.cfg.d/

# create VM
qm create $VMID --name $TEMPL_NAME --memory $MEM --balloon $BALLOON --cores $CORES --bios $BIOS --machine $MACHINE --net0 virtio,bridge=${NET_BRIDGE}${VLAN:+,tag=$VLAN}
qm set $VMID --agent enabled=$AGENT_ENABLE,fstrim_cloned_disks=$FSTRIM
qm set $VMID --ostype $OS_TYPE
qm importdisk $VMID $WORK_DIR/$IMG_NAME $DISK_STOR -format qcow2
qm set $VMID --scsihw virtio-scsi-single --scsi0 $DISK_STOR:$VMID/vm-$VMID-disk-0.qcow2,cache=writethrough,discard=on,iothread=1,ssd=1
qm set $VMID --scsi1 $DISK_STOR:cloudinit
qm set $VMID --efidisk0 $DISK_STOR:0,efitype=4m,,format=qcow2,pre-enrolled-keys=1,size=528K
qm set $VMID --rng0 source=/dev/urandom
qm set $VMID --ciuser $CLOUD_USER
qm set $VMID --cipassword $CLOUD_PASSWORD
qm set $VMID --boot c --bootdisk scsi0
qm set $VMID --tablet 0
qm set $VMID --ipconfig0 ip=dhcp
qm set $VMID --description "$NOTES"
# Apply SSH Key if the value is set
if [ -n "${SSHKEY+set}" ]; then
  tmpfile=$(mktemp /tmp/sshkey.XXX.pub)
  echo $SSHKEY > $tmpfile
  qm set $VMID --sshkey $tmpfile
  rm -v $tmpfile
fi
qm resize $VMID scsi0 $DISK_SIZE

# Delete original image file
#rm -v $WORK_DIR/$IMG_NAME
if [ $DELETEIMG == 'yes' ]; then
  rm -v $IMG_NAME
  rm -v $SRC_IMG
  rm -v /tmp/99_pve.cfg
else
  echo "Image not deleted"
fi
