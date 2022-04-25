#!/bin/bash
TELEPORT_PACKAGE=teleport-v6.0.3-linux-arm-bin.tar.gz
AUTH_SERVER=teleport.mv.corplite.com

function check_root_user() {
  if [ "$EUID" -ne 0 ]; then
    echo "This script requires sudo/root permissions"
    exit
  fi
}

function clean_teleport() {
  echo "Removing existing teleport install"
  rm -rf /var/lib/teleport
  rm /usr/local/bin/teleport
  rm /etc/teleport.yaml
  rm /tmp/"$TELEPORT_PACKAGE"
  rm -rf /tmp/teleport
}

function get_user_input() {
  echo "==============================="
  echo "Ensure you have run the following in the main teleport server to get the auth token and ca-pin."
  echo "sudo tctl tokens add --type=node"
  echo "==============================="

  echo "What is the name of this pi node?: "
  read -r NODE_NAME
  echo "Enter the auth token: "
  read -r AUTH_TOKEN
  echo "Enter ca-pin (eg.'sha256:2154125...'): "
  read -r CA_PIN

  echo ""
  echo "Node Name: $NODE_NAME"
  echo "Auth Token: $AUTH_TOKEN"
  echo "CA Pin: $CA_PIN"
  echo ""
  echo "This script will delete your existing teleport install?"
  echo "Are you sure these are you settings? (y\n)"

  read -r RESPONSE
  if [ "$RESPONSE" = "n" ] || [ "$RESPONSE" = "N" ]; then
    exit 0
  fi
}

function install_teleport() {
  echo "Installing teleport"
  cd /tmp || exit
  curl -O https://get.gravitational.com/"$TELEPORT_PACKAGE"
  tar -xzf "$TELEPORT_PACKAGE"
  cd teleport || exit
  sudo ./install
  cp "$PWD"/examples/systemd/teleport.service /etc/systemd/system/teleport.service
  cd /tmp || exit
  rm -rf teleport
  rm "$TELEPORT_PACKAGE"
}

function create_teleport_config() {
  echo "Creating Teleport Config in /etc/teleport.yaml"
  cat > /etc/teleport.yaml <<EOL
---
teleport:
  nodename: ${NODE_NAME}
  ca_pin: ${CA_PIN}
  auth_token: "${AUTH_TOKEN}"
  auth_servers:
  - "${AUTH_SERVER}:443"
auth_service:
  enabled: false
proxy_service:
  enabled: false
ssh_service:
  enabled: true
  labels:
    env: monkeyvision-prod
EOL
}

function systemd_start() {
  echo "Starting systemd teleport.service"
  sudo systemctl daemon-reload
  sudo systemctl enable teleport
  sudo systemctl restart teleport
}

function get_teleport_status() {
  echo "Checking teleport status"
  sleep 5
  sudo journalctl -u teleport | tail -n 100
}


echo "=== CORPLITE TELEPORT NODE INSTALLER ==="
check_root_user
clean_teleport
get_user_input
install_teleport
create_teleport_config
systemd_start
get_teleport_status
