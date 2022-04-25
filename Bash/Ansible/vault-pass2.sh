#!/bin/bash

set -e

BW_VAULT_NAME_ID="ansible_vault_password"
BW_SESSION="$(bw unlock --raw)"
echo "$(bw get password ${BW_VAULT_NAME_ID} --session ${BW_SESSION} --raw)"
