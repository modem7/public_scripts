#!/bin/bash

# Proxmox Ubuntu template create script.
# This script is designed to be run on the Proxmox host.

# Required script packages
REQUIRED_PKG=("libguestfs-tools" "wget")

### Constants
GEN_PASS=$(date +%s | sha256sum | base64 | head -c 16 ; echo) # Random password generation
WORK_DIR="/tmp"

### Defaults
CLOUD_PASSWORD_DEFAULT=$GEN_PASS # Password for cloud-init
CLOUD_USER_DEFAULT="root" # User for cloud-init
LOCAL_LANG="en_GB.UTF-8"
SET_X11="yes" # "yes" or "no" required
VIRT_PKGS="qemu-guest-agent,cloud-utils,cloud-guest-utils"
VMID_DEFAULT="52000" # VM ID
X11_LAYOUT="gb"
X11_MODEL="pc105"

### VM variables
AGENT_ENABLE="1" # Change to 0 if you don't want the guest agent
BALLOON="768" # Minimum balooning size
BIOS="ovmf" # Choose between ovmf or seabios
CORES="2"
DISK_SIZE="15G"
DISK_STOR="proxmox" # Name of disk storage within Proxmox
FSTRIM="1"
MACHINE="q35" # Type of machine. Q35 or i440fx
MEM="2048" # Max RAM
NET_BRIDGE="vmbr1" # Network bridge name

OS_TYPE="l26" # OS type (Linux 6x - 2.6 Kernel)
# SSH Keys. Unset the variable if you don't want to use this. Use the public key. One per line.
SSH_KEY=$(cat << 'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOFLnUCnFyoONBwVMs1Gj4EqERx+Pc81dyhF6IuF26WM proxvms
EOF
)
TZ="Europe/London"
VLAN="50" # Set if you have VLAN requirements
ZFS="true" # Set to true if you have a ZFS datastore

# Notes variable
NOTES=$(cat << 'EOF'
When modifying this template, make sure you run this at the end

apt-get clean \
&& apt -y autoremove --purge \
&& apt -y clean \
&& apt -y autoclean \
&& cloud-init clean \
&& echo -n > /etc/machine-id \
&& echo -n > /var/lib/dbus/machine-id \
&& sync \
&& history -c \
&& history -w \
&& fstrim -av \
&& shutdown now
EOF
)

### Functions

# CTRL+C/INT catch
ctrl_c() {
    echo "User pressed Ctrl + C. Exiting script..."
    cleanup
    exit 1
}

proxmox_check() {
# Check if the script is running on a Proxmox system
echo "### System Check ###"
if pveversion &>/dev/null; then
    echo "This is a Proxmox system. Proceeding."
else
    echo "This script is intended to run only on Proxmox. Exiting."
    exit 1
fi
}

# Check if prerequisite package is installed.
package_installed() {
    for pkg in "${REQUIRED_PKG[@]}"; do
        dpkg -l | grep -q "^ii  $pkg "
        if [ $? -ne 0 ]; then
            return 1
        fi
    done
    return 0
}

install_package() {
    echo "### Package Installation ###"

    # Check if the packages are already installed.
    if package_installed; then
        echo "The required packages are already installed."
    else
        # Prompt the user for installation confirmation with "Y" as the default choice.
        read -rp "Do you want to install the required packages '${REQUIRED_PKG[*]}'? (Y/n): " user_choice
        user_choice=${user_choice:-Y}

        if [[ "$user_choice" == "N" || "$user_choice" == "n" ]]; then
            echo "Package installation aborted."
            exit 0
        elif [[ "$user_choice" == "Y" || "$user_choice" == "y" ]]; then
            # Install the required packages using apt-get with -y flag for automatic "yes" to prompts.
            sudo apt-get update
            sudo apt-get install -y "${REQUIRED_PKG[@]}"

            # Check the exit status of apt-get to see if the installation was successful.
            if [ $? -eq 0 ]; then
                echo "Required packages '${REQUIRED_PKG[*]}' are installed successfully."
            else
                echo "Installation of required packages '${REQUIRED_PKG[*]}' failed."
                exit 1
            fi
        else
            echo "Invalid choice. Aborting package installation."
            exit 1
        fi
    fi
}

select_ubuntu_version() {
    declare -A camel_to_lower

    camel_to_lower["Jammy"]="jammy"
    camel_to_lower["Focal"]="focal"
    camel_to_lower["Mantic"]="mantic"
    camel_to_lower["Lunar"]="lunar"
    camel_to_lower["Noble"]="noble"

    echo "Choose an Ubuntu version:"
    
    select version in "${!camel_to_lower[@]}"; do
        if [ -n "$version" ]; then
            selected_version="${camel_to_lower["$version"]}"
            break
        else
            echo "Invalid choice. Please select a valid option."
        fi
    done

    if [ -n "$selected_version" ]; then
        DISTRO_VER="$selected_version"
        DISK_IMAGE="$DISTRO_VER-server-cloudimg-amd64.img"
        IMAGE_URL="https://cloud-images.ubuntu.com/$DISTRO_VER/current/$DISK_IMAGE"
        TEMPL_NAME_DEFAULT=$(echo "ubuntu-$DISTRO_VER-cloud-master" | sed -r 's/(^|_)([a-z])/\U\2/g')
        OS_NAME="Ubuntu $DISTRO_VER" # Name of VM
        OS_NAME="$(echo "$OS_NAME" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2));}1')"
        echo "Selected Ubuntu version: $version"
    else
        echo "Invalid choice, exiting."
        return
    fi
}

# DISK_IMAGE="jammy-server-cloudimg-amd64.img"
# IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/$DISK_IMAGE"


# Check if VM ID exists
vmidexist() {
    local vmid="$1"
    # Check if the VM ID exists in the list
    if qm list | awk '{print $1}' | grep -q "^$vmid$"; then
        return 0 # VM exists
    else
        return 1 # VM does not exist
    fi
}

# Function to get a valid VM ID from the user
get_valid_vmid() {
    local vmid_input
    read -p "Enter a VM ID (default: $VMID_DEFAULT): " vmid_input
    VMID="${vmid_input:-$VMID_DEFAULT}"

    while vmidexist "$VMID"; do
        echo "VM with ID $VMID exists."
        read -p "Enter a new VM ID: " VMID
    done
}

# Define user variables
user_var() {
    # Prompt for user-defined variables
    read -p "Enter a VM Template Name [$TEMPL_NAME_DEFAULT]: " TEMPL_NAME
    TEMPL_NAME=${TEMPL_NAME:-$TEMPL_NAME_DEFAULT}

    read -p "Enter a Cloud-Init Username for $OS_NAME [$CLOUD_USER_DEFAULT]: " CLOUD_USER
    CLOUD_USER=${CLOUD_USER:-$CLOUD_USER_DEFAULT}

    read -p "Enter a Cloud-Init Password for $OS_NAME [$CLOUD_PASSWORD_DEFAULT]: " CLOUD_PASSWORD
    CLOUD_PASSWORD=${CLOUD_PASSWORD:-$CLOUD_PASSWORD_DEFAULT}

    # Optionally, set default values for VMID if needed
    # VMID=${VMID:-$VMID_DEFAULT}

    # Optionally, set default values for OS_NAME and VMID if needed
    # OS_NAME=${OS_NAME:-$OS_NAME_DEFAULT}
    # VMID=${VMID:-$VMID_DEFAULT}
}

# Remove temporary files
cleanup() {
    # Display a message indicating temporary file deletion is starting.
    echo "### Deleting temporary files ###"

    # Check if the file "99_pve.cfg" exists and remove it if it does.
    if [ -f "/tmp/99_pve.cfg" ]; then
        rm -v /tmp/99_pve.cfg
    fi

    if [ -f "$DISK_IMAGE" ]; then
        # Prompt the user for their choice of whether to delete the image
        read -rp "Do you want to delete the image at '$DISK_IMAGE'? (Y/n): " user_choice
        user_choice=${user_choice:-Y}

        if [[ "$user_choice" == "Y" || "$user_choice" == "y" ]]; then
            # Remove the disk image and display a message.
            rm -v "$DISK_IMAGE"
            echo "Image deleted: $DISK_IMAGE"
        else
            # Display a message indicating the image was not deleted.
            echo "Image not deleted: $DISK_IMAGE"
        fi
    else
        # Display a message indicating that the image does not exist.
        echo "Image not found: $DISK_IMAGE"
    fi
}


# Create and move to working directory
create_work_dir() {
echo "### Creating working directory in $WORK_DIR ###"
mkdir -p $WORK_DIR
cd $WORK_DIR || exit
}

# Download the disk image if it doesn't exist or if it was modified upsteam
download_image() {
    echo "### Downloading $DISK_IMAGE ###"
    wget -N -nv --show-progress "$IMAGE_URL"
}

# Install qemu-guest-agent inside image
install_qemu_guest_agent() {
    if [ -n "${TZ+set}" ]; then
        echo "### Setting up TZ ###"
        virt-customize -a $DISK_IMAGE --timezone $TZ
    fi

    if [ $SET_X11 == 'yes' ]; then
        echo "### Setting up keyboard language and locale ###"
        virt-customize -a $DISK_IMAGE \
        --firstboot-command "localectl set-locale LANG=$LOCAL_LANG" \
        --firstboot-command "localectl set-x11-keymap $X11_LAYOUT $X11_MODEL"
    fi

    echo "### Updating system and installing packages ###"
    virt-customize -a $DISK_IMAGE --update --install $VIRT_PKGS
}

# Create Proxmox Cloud-init config
create_proxmox_cloud_init_config() {
    echo "### Creating Proxmox Cloud-init config ###"
    echo -n > $WORK_DIR/99_pve.cfg
    cat > $WORK_DIR/99_pve.cfg <<EOF
# to update this file, run dpkg-reconfigure cloud-init
datasource_list: [ NoCloud, ConfigDrive ]
EOF
}

# Copy Proxmox Cloud-init config to the image
copy_cloud_init_config_to_image() {
    echo "### Copying Proxmox Cloud-init config to image ###"
    virt-customize -a $DISK_IMAGE --upload $WORK_DIR/99_pve.cfg:/etc/cloud/cloud.cfg.d/
}

# Create the VM
create_vm() {
    echo "### Creating VM ###"
    qm create $VMID --name $TEMPL_NAME --memory $MEM --balloon $BALLOON --cores $CORES --bios $BIOS --machine $MACHINE --net0 virtio,bridge=${NET_BRIDGE}${VLAN:+,tag=$VLAN}
    qm set $VMID --agent enabled=$AGENT_ENABLE,fstrim_cloned_disks=$FSTRIM
    qm set $VMID --ostype $OS_TYPE
    if [ $ZFS == 'true' ]; then
        echo "### ZFS set to $ZFS ###"
        qm importdisk $VMID $WORK_DIR/$DISK_IMAGE $DISK_STOR
        qm set $VMID --scsihw virtio-scsi-single --scsi0 $DISK_STOR:vm-$VMID-disk-0,cache=writethrough,discard=on,iothread=1,ssd=1
        qm set $VMID --efidisk0 $DISK_STOR:0,efitype=4m,,pre-enrolled-keys=1,size=528K
    else
        echo "### ZFS set to $ZFS ####"
        qm importdisk $VMID $WORK_DIR/$DISK_IMAGE $DISK_STOR -format qcow2
        qm set $VMID --scsihw virtio-scsi-single --scsi0 $DISK_STOR:$VMID/vm-$VMID-disk-0.qcow2,cache=writethrough,discard=on,iothread=1,ssd=1
        qm set "$VM"
    fi
    qm set $VMID --scsi1 $DISK_STOR:cloudinit
    qm set $VMID --rng0 source=/dev/urandom
    qm set $VMID --ciuser $CLOUD_USER
    qm set $VMID --cipassword "$CLOUD_PASSWORD"
    qm set $VMID --boot c --bootdisk scsi0
    qm set $VMID --tablet 0
    qm set $VMID --ipconfig0 ip=dhcp
    qm cloudinit update $VMID
    qm set $VMID --description "$NOTES"
}

# Apply SSH Key if the value is set
apply_ssh() {
echo "### Applying SSH Key ###"
if [ -n "${SSH_KEY+set}" ]; then
    qm set $VMID --sshkey <(cat <<<"${SSH_KEY}")
fi
}

# Resize VM disk
vm_resize() {
echo "### Resizing VM disk ###"
qm resize $VMID scsi0 $DISK_SIZE
}

### Run script

# Check if the script is running under Proxmox
proxmox_check

# Trap CTRL+C
trap ctrl_c INT

# Install prerequisite packages
install_package

# Choose which flavour of Ubuntu to create
select_ubuntu_version

# Check if VM ID exists, and if it does, prompt for a new ID
get_valid_vmid

# Define user variables
user_var

# Create and move to working directory
create_work_dir

# Download the disk image if it doesn't exist or if it was modified upsteam
download_image

# Install qemu-guest-agent, set timezone and keyboard
install_qemu_guest_agent

# Create Proxmox Cloud-init config
create_proxmox_cloud_init_config

# Copy Proxmox Cloud-init config to the image
copy_cloud_init_config_to_image

# Create the VM
create_vm

# Apply SSH Key if the value is set
apply_ssh

# Resize VM disk
vm_resize

# Remove temporary files
cleanup
