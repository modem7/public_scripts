#!/bin/bash

# Script for creating Ansible user for managing VM's.

# Check if script is running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Install pwgen
echo "==> Installing pwgen..."
apt-get install -y pwgen

# Variables
ansusr="ansible"
anspwd=$(pwgen -N 1 -s 64)
ansssh="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFv+XL86DUoq1o4EEC24uYecv4nU76XcmTeOO1rin9gx ansible"

# Create Ansible User
echo "==> Creating user..."
useradd -r -m ${ansusr} -s /bin/bash

# Change password
echo "==> Changing user password..."
chpasswd <<<"${ansusr}:${anspwd}"

# Lock password
echo "==> Locking password..."
passwd -l ${ansusr} > /dev/null

# Add to sudoers
echo "==> Adding account to sudoers..."
echo "${ansusr} ALL=(root) NOPASSWD:ALL" | tee /etc/sudoers.d/${ansusr} > /dev/null

# Add ssh key
echo "==> Adding SSH key..."
mkdir -p /home/${ansusr}/.ssh/
echo "${ansssh}" | tee /home/${ansusr}/.ssh/authorized_keys > /dev/null

# Change permissions and folder ownership
echo "==> Fixing permissions and groups..."
chown -R ${ansusr}:${ansusr} /home/${ansusr}/.ssh/
chmod 0440 /etc/sudoers.d/${ansusr}
chmod 700 /home/${ansusr}/.ssh
chmod 644 /home/${ansusr}/.ssh/authorized_keys