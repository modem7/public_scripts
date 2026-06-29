#!/bin/bash
# =============================================================================
# Proxmox Ubuntu Cloud-Init Template Creator
# =============================================================================
# Creates a cloud-init ready Ubuntu VM template on Proxmox VE.
# Supports ZFS (raw), LVM-thin (raw), and directory (qcow2) storage backends.
#
# Usage:
#   ./create-ubuntu-cloud-template.sh [OPTIONS]
#
# Run with --help to see all available options and examples.
#
# Quick start:
#   First run  — answer the prompts; save a named profile at the end.
#   Repeat run — ./create-ubuntu-cloud-template.sh --config <profile>.conf
#   Automated  — ./create-ubuntu-cloud-template.sh --config <profile>.conf \
#                  --unattended --vmid <id> [--template] [--force-overwrite \
#                  --i-know-what-i-am-doing]
#
# VM ID selection:
#   --auto-vmid alone        — finds the next free ID from 100 upwards.
#   --vmid <id> --auto-vmid  — tries <id> first; if taken, increments from
#                              there. Use this to control which range your
#                              templates live in (e.g. --vmid 52000 --auto-vmid
#                              keeps templates in the 52000+ range).
#   --vmid <id> alone        — uses exactly <id>; fails if already taken.
# =============================================================================

set -euo pipefail

# =============================================================================
# Script location — config files are stored alongside the script
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# =============================================================================
# Defaults — overridden by config file or interactive prompts
# =============================================================================
WORK_DIR="/tmp"
PROFILE_NAME=""
PROFILE_PATH=""

# Cloud-init
CLOUD_USER_DEFAULT="ubuntu"
CLOUD_PASSWORD_DEFAULT="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"

# Locale / keyboard
LOCAL_LANG="en_GB.UTF-8"
SET_X11="yes"
X11_LAYOUT="gb"
X11_MODEL="pc105"
TZ="Europe/London"

# VM hardware
VMID_DEFAULT="52000"
CORES="2"
MEM="2048"
BALLOON="768"
BIOS="ovmf"
MACHINE="q35"
DISK_SIZE="15G"
OS_TYPE="l26"
NET_BRIDGE="vmbr1"
VLAN=""
AGENT_ENABLE="1"
FSTRIM="1"

# CPU type
# "host" passes through the host CPU directly — best performance and the
# right choice for most homelabs where all nodes share the same CPU generation.
# Change to "kvm64" if you need live migration across nodes with different CPUs.
CPU_TYPE="host"

# Storage
DISK_STOR_DEFAULT="local"

# Packages installed inside the image via virt-customize
VIRT_PKGS="qemu-guest-agent,cloud-utils,cloud-guest-utils"
EXTRA_VIRT_PKGS=""

# SSH public key injected into the template via cloud-init.
#
# WARNING: Do NOT paste your SSH public key here as a hardcoded default.
# Anyone who clones or copies this script inherits your key and gains SSH
# access to every VM built from this template. Leave this empty — the script
# will prompt you at runtime and save the key in your named .conf profile.
SSH_KEY=""

# VM tags
TAG="template"

# Required host packages
# - libguestfs-tools: provides virt-customize for image modification
# - wget:             image/checksum downloads and GitHub key fetching
# - python3:          used to set VM description without shell newline mangling
REQUIRED_PKGS=("libguestfs-tools" "wget" "python3")

# =============================================================================
# Colour helpers
# =============================================================================
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
header()  { echo -e "\n${BOLD}=== $* ===${RESET}"; }

# =============================================================================
# Argument parsing
# =============================================================================
CONFIG_FILE=""
UNATTENDED="no"          # "yes" = skip all prompts when --config is loaded
VMID_FLAG=""             # set via --vmid to bypass the VMID prompt entirely
AUTO_VMID="no"           # "yes" = auto-increment VMID on conflict instead of dying
FORCE_OVERWRITE="no"     # "yes" = destroy existing template VM and replace it
I_KNOW="no"              # "yes" = skip overwrite countdown in unattended mode

# CLI flags that must survive config sourcing — stored separately and applied after
_CLI_CONVERT_TO_TEMPLATE=""
_CLI_TEMPL_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --name)
            _CLI_TEMPL_NAME="$2"
            shift 2
            ;;
        --vmid)
            VMID_FLAG="$2"
            shift 2
            ;;
        --auto-vmid)
            AUTO_VMID="yes"
            shift
            ;;
        --unattended)
            UNATTENDED="yes"
            shift
            ;;
        --force-overwrite)
            FORCE_OVERWRITE="yes"
            shift
            ;;
        --i-know-what-i-am-doing)
            I_KNOW="yes"
            shift
            ;;
        --template)
            _CLI_CONVERT_TO_TEMPLATE="yes"
            shift
            ;;
        --no-template)
            _CLI_CONVERT_TO_TEMPLATE="no"
            shift
            ;;
        --help|-h)
            echo "Usage: $SCRIPT_NAME [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --config <file>              Load a previously saved profile config file."
            echo "                               Paths are relative to the script directory unless absolute."
            echo "  --name <name>                Set the VM template name directly, skipping the prompt."
            echo "  --vmid <id>                  Set the VM ID directly, skipping the prompt."
            echo "                               Fails if the ID is already taken (use --auto-vmid"
            echo "                               to increment automatically instead)."
            echo "  --auto-vmid                  Automatically find the next free VM ID."
            echo "                               Without --vmid: starts from 100 upwards."
            echo "                               With --vmid <id>: tries <id> first, then"
            echo "                               increments from there if taken."
            echo "                               Recommended: always pair with --vmid to control"
            echo "                               which ID range your templates live in."
            echo "                               e.g. --vmid 52000 --auto-vmid keeps templates"
            echo "                               in the 52000+ range rather than starting at 100."
            echo "  --unattended                 Skip all interactive prompts. Requires --config."
            echo "                               Password is auto-generated and shown at the end."
            echo "                               Snippet search is skipped unless SNIPPETS_STOR is"
            echo "                               already set in the config file."
            echo "  --force-overwrite            Destroy an existing Proxmox template with the same"
            echo "                               VM ID and replace it. CLI-only flag — cannot be set"
            echo "                               in a config file. Only works on templates (template: 1);"
            echo "                               refuses to destroy running or non-template VMs."
            echo "  --i-know-what-i-am-doing     Skip the overwrite countdown/confirmation when"
            echo "                               combined with --force-overwrite and --unattended."
            echo "                               Requires both flags to be present."
            echo "  --template                   Automatically convert the VM to a Proxmox template at the end."
            echo "  --no-template                Leave the VM as a regular VM (for further customisation)."
            echo "                               If neither flag is given, you will be asked interactively"
            echo "                               (or the value from the config file will be used)."
            echo ""
            echo "Examples:"
            echo "  ./$SCRIPT_NAME"
            echo "  ./$SCRIPT_NAME --config noble-webserver.conf"
            echo "  ./$SCRIPT_NAME --config noble-webserver.conf --name ubuntu-noble-webserver"
            echo "  ./$SCRIPT_NAME --config noble-webserver.conf --vmid 52001"
            echo "  ./$SCRIPT_NAME --config noble-webserver.conf --auto-vmid"
            echo "    (next free ID from 100)"
            echo "  ./$SCRIPT_NAME --config noble-webserver.conf --vmid 52000 --auto-vmid"
            echo "    (next free ID from 52000 — keeps templates in your chosen range)"
            echo "  ./$SCRIPT_NAME --config noble-webserver.conf --vmid 52001 --force-overwrite"
            echo "  ./$SCRIPT_NAME --config noble-webserver.conf --unattended --vmid 52000 --auto-vmid --template"
            echo "  ./$SCRIPT_NAME --config noble-webserver.conf --unattended --vmid 52001 --name ubuntu-noble-webserver --force-overwrite --i-know-what-i-am-doing --template"
            exit 0
            ;;
        *)
            die "Unknown argument: $1. Use --help for usage."
            ;;
    esac
done

# Resolve config file path relative to script dir if not absolute
if [[ -n "$CONFIG_FILE" && "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="$SCRIPT_DIR/$CONFIG_FILE"
fi

# Load config file if provided
if [[ -n "$CONFIG_FILE" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "Config file not found: $CONFIG_FILE"
    fi
    info "Loading config from: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# --unattended requires --config
if [[ "$UNATTENDED" == "yes" && -z "$CONFIG_FILE" ]]; then
    die "--unattended requires --config <file>. There are no saved values to run from."
fi

# --i-know-what-i-am-doing only makes sense alongside both --force-overwrite and --unattended
if [[ "$I_KNOW" == "yes" && ( "$FORCE_OVERWRITE" != "yes" || "$UNATTENDED" != "yes" ) ]]; then
    die "--i-know-what-i-am-doing requires both --force-overwrite and --unattended."
fi

# --auto-vmid and --force-overwrite are mutually exclusive
if [[ "$AUTO_VMID" == "yes" && "$FORCE_OVERWRITE" == "yes" ]]; then
    die "--auto-vmid and --force-overwrite are mutually exclusive. Choose one conflict resolution strategy."
fi

# Apply CLI flag overrides — these must win over anything in the config file
CONVERT_TO_TEMPLATE="${_CLI_CONVERT_TO_TEMPLATE:-${CONVERT_TO_TEMPLATE:-}}"
[[ -n "$_CLI_TEMPL_NAME" ]] && TEMPL_NAME="$_CLI_TEMPL_NAME"
[[ -n "$VMID_FLAG"       ]] && VMID="$VMID_FLAG"

# =============================================================================
# Traps — CTRL+C and unexpected errors
# =============================================================================
# VMID_CREATED tracks whether qm create has run so the error handler knows
# whether there is a VM to clean up.
VMID_CREATED=""

error_handler() {
    local exit_code=$?
    local line=$1
    echo ""
    error "Script failed at line $line (exit code $exit_code)."
    _destroy_partial_vm
    cleanup
    exit "$exit_code"
}

ctrl_c() {
    echo ""
    warn "Interrupted by user."
    _destroy_partial_vm
    cleanup
    exit 1
}

_destroy_partial_vm() {
    if [[ -n "${VMID_CREATED:-}" ]] && qm list | awk 'NR>1 {print $1}' | grep -q "^${VMID_CREATED}$"; then
        warn "Destroying partially configured VM ${VMID_CREATED}..."
        qm destroy "$VMID_CREATED" --destroy-unreferenced-disks 1 --purge 1 2>/dev/null || true
        warn "VM ${VMID_CREATED} destroyed."
    fi
}

trap ctrl_c INT
trap 'error_handler $LINENO' ERR

# =============================================================================
# Preflight: must be on a Proxmox host
# =============================================================================
proxmox_check() {
    header "System Check"
    if ! pveversion &>/dev/null; then
        die "This script must be run on a Proxmox VE host."
    fi
    success "Proxmox VE detected."
}

# =============================================================================
# Preflight: required packages
# =============================================================================
install_packages() {
    header "Package Check"
    local missing=()
    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        success "All required packages are installed."
        return
    fi

    warn "Missing packages: ${missing[*]}"
    if [[ "$UNATTENDED" == "yes" ]]; then
        info "Unattended mode — installing automatically."
    else
        read -rp "Install them now? (Y/n): " choice
        choice="${choice:-Y}"
        [[ ! "$choice" =~ ^[Yy]$ ]] && die "Required packages not installed. Aborting."
    fi
    apt-get update -qq
    apt-get install -y "${missing[@]}"
    success "Packages installed: ${missing[*]}"
}

# =============================================================================
# Ubuntu version selection — fetched dynamically from cloud-images.ubuntu.com
# =============================================================================
select_ubuntu_version() {
    header "Ubuntu Version Selection"

    # If already set via config, skip interactive selection
    if [[ -n "${DISTRO_VER:-}" ]]; then
        info "Using distro from config: $DISTRO_VER"
        _set_distro_vars "$DISTRO_VER"
        return
    fi

    info "Fetching available Ubuntu Cloud Image versions..."

    # Scrape directory listing for codename directories that have a current/ image
    local available_versions=()
    available_versions=$(
        wget -qO- "https://cloud-images.ubuntu.com/" \
        | grep -oP 'href="\K[a-z]+(?=/")' \
        | while read -r codename; do
            local url="https://cloud-images.ubuntu.com/${codename}/current/${codename}-server-cloudimg-amd64.img"
            if wget -q --spider "$url" 2>/dev/null; then
                echo "$codename"
            fi
        done
    )

    if [[ -z "$available_versions" ]]; then
        die "Could not fetch Ubuntu versions from cloud-images.ubuntu.com. Check your internet connection."
    fi

    mapfile -t version_list <<< "$available_versions"

    echo ""
    echo "Available Ubuntu versions:"
    local i=1
    for v in "${version_list[@]}"; do
        echo "  $i) $v"
        ((i++))
    done
    echo ""

    local selected=""
    while [[ -z "$selected" ]]; do
        read -rp "Select a version (number or codename): " choice
        # Allow numeric or direct codename entry
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#version_list[@]} )); then
            selected="${version_list[$((choice-1))]}"
        else
            for v in "${version_list[@]}"; do
                if [[ "$v" == "$choice" ]]; then
                    selected="$v"
                    break
                fi
            done
        fi
        [[ -z "$selected" ]] && warn "Invalid selection. Try again."
    done

    _set_distro_vars "$selected"
}

_set_distro_vars() {
    local codename="$1"
    DISTRO_VER="$codename"
    DISK_IMAGE="${DISTRO_VER}-server-cloudimg-amd64.img"
    IMAGE_URL="https://cloud-images.ubuntu.com/${DISTRO_VER}/current/${DISK_IMAGE}"
    CHECKSUM_URL="https://cloud-images.ubuntu.com/${DISTRO_VER}/current/SHA256SUMS"
    TEMPL_NAME_DEFAULT="ubuntu-${DISTRO_VER}-cloud-template"
    OS_NAME="Ubuntu $(echo "$DISTRO_VER" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"
    success "Selected: $OS_NAME"
}

# Maps a pvesm storage type string to STORAGE_FORMAT and STORAGE_BACKEND globals
_resolve_storage_type() {
    local stor_type="$1"
    case "$stor_type" in
        zfspool)          STORAGE_FORMAT="raw";   STORAGE_BACKEND="zfs" ;;
        lvmthin|lvm)      STORAGE_FORMAT="raw";   STORAGE_BACKEND="lvm" ;;
        dir|nfs|cifs|btrfs) STORAGE_FORMAT="qcow2"; STORAGE_BACKEND="dir" ;;
        *)
            warn "Unknown storage type '$stor_type'. Defaulting to qcow2."
            STORAGE_FORMAT="qcow2"; STORAGE_BACKEND="dir" ;;
    esac
}

# =============================================================================
# Storage: list available Proxmox storages, let user pick, auto-detect type
# =============================================================================
select_storage() {
    header "Storage Selection"
    echo "  This is where your VM template will be stored on Proxmox."
    echo ""

    if [[ -n "${DISK_STOR:-}" ]]; then
        info "Using storage from config: $DISK_STOR"
        local stored_type
        stored_type=$(pvesm status | awk -v s="$DISK_STOR" '$1==s {print $2}')
        if [[ -z "$stored_type" ]]; then
            warn "Configured storage '$DISK_STOR' not found or inactive — falling back to selection."
            DISK_STOR=""
        else
            _resolve_storage_type "$stored_type"
            success "Template will be stored on: $DISK_STOR ($stored_type / $STORAGE_FORMAT)"
            return
        fi
    fi

    info "Scanning active Proxmox storage pools..."
    echo ""

    local storages=() types=()
    while IFS= read -r line; do
        local name type status
        name=$(awk '{print $1}' <<< "$line")
        type=$(awk '{print $2}' <<< "$line")
        status=$(awk '{print $3}' <<< "$line")
        [[ "$name" == "Name" || "$status" != "active" ]] && continue
        storages+=("$name")
        types+=("$type")
    done < <(pvesm status)

    [[ ${#storages[@]} -eq 0 ]] && die "No active storage pools found."

    local i=1
    for idx in "${!storages[@]}"; do
        printf "  %d) %-20s %s\n" "$i" "${storages[$idx]}" "${types[$idx]}"
        ((i++))
    done
    echo ""

    local default_num=1
    for idx in "${!storages[@]}"; do
        if [[ "${storages[$idx]}" == "$DISK_STOR_DEFAULT" ]]; then
            default_num=$((idx + 1))
            break
        fi
    done

    local selected_stor="" selected_type=""
    while [[ -z "$selected_stor" ]]; do
        read -rp "Select storage pool [${default_num}]: " choice
        choice="${choice:-$default_num}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#storages[@]} )); then
            selected_stor="${storages[$((choice-1))]}"
            selected_type="${types[$((choice-1))]}"
        else
            warn "Invalid selection. Enter a number between 1 and ${#storages[@]}."
        fi
    done

    DISK_STOR="$selected_stor"
    _resolve_storage_type "$selected_type"
    success "Template will be stored on: $DISK_STOR ($selected_type / $STORAGE_FORMAT)"
}

# =============================================================================
# VM ID helpers
# =============================================================================
vmid_exists() {
    qm list | awk 'NR>1 {print $1}' | grep -q "^${1}$"
}

# Returns 0 (true) if the VMID exists AND has template:1 in its config
vmid_is_template() {
    local id="$1"
    grep -q "^template:" /etc/pve/nodes/*/qemu-server/${id}.conf 2>/dev/null
}

# Returns 0 (true) if the VMID exists AND the VM is currently running
vmid_is_running() {
    local id="$1"
    qm status "$id" 2>/dev/null | grep -q "^status: running"
}

# Pull the VM name from Proxmox config for display in warnings
vmid_name() {
    local id="$1"
    grep "^name:" /etc/pve/nodes/*/qemu-server/${id}.conf 2>/dev/null \
        | head -1 | awk '{print $2}'
}

# Find the next free VMID at or above a given starting point
next_free_vmid() {
    local id="$1"
    while vmid_exists "$id"; do
        ((id++))
    done
    echo "$id"
}

# Destroy an existing template VM — called only when --force-overwrite is set
# and all safety checks have passed.
destroy_existing_template() {
    local id="$1"
    local name
    name="$(vmid_name "$id")"

    echo ""
    warn "OVERWRITE REQUESTED"
    warn "This will permanently destroy VM $id ('${name}') and all its disks."
    warn "This action cannot be undone."
    echo ""

    if [[ "$UNATTENDED" == "yes" && "$I_KNOW" == "yes" ]]; then
        warn "Unattended overwrite confirmed via --i-know-what-i-am-doing. Destroying in 5 seconds..."
        for i in 5 4 3 2 1; do
            printf "\r  Destroying in %s... " "$i"
            sleep 1
        done
        printf "\r  Destroying now.          \n"
    elif [[ "$UNATTENDED" == "yes" ]]; then
        # Should never reach here due to earlier validation, but be safe
        die "Unattended overwrite requires --i-know-what-i-am-doing."
    else
        echo "  VM ID:   $id"
        echo "  VM name: ${name}"
        echo ""
        read -rp "  Type the VM name to confirm destruction: " confirm
        if [[ "$confirm" != "$name" ]]; then
            die "Name did not match. Aborting overwrite."
        fi
        warn "Destroying VM $id in 5 seconds — press Ctrl+C to abort."
        for i in 5 4 3 2 1; do
            printf "\r  Destroying in %s... " "$i"
            sleep 1
        done
        printf "\r  Destroying now.          \n"
    fi

    echo ""
    qm destroy "$id" --destroy-unreferenced-disks 1 --purge 1
    success "VM $id destroyed."
}

get_valid_vmid() {
    # --auto-vmid with no explicit --vmid: always find next free from 100
    if [[ "$AUTO_VMID" == "yes" && -z "$VMID_FLAG" ]]; then
        VMID="$(next_free_vmid "100")"
        info "Auto-selected next free VM ID: $VMID"
        return
    fi

    # Set VMID from flag, config default, or interactive prompt
    if [[ -z "${VMID:-}" ]]; then
        if [[ "$UNATTENDED" == "yes" ]]; then
            VMID="$VMID_DEFAULT"
        else
            read -rp "Enter VM ID [${VMID_DEFAULT}]: " input
            VMID="${input:-$VMID_DEFAULT}"
        fi
    fi

    # Handle conflict
    if vmid_exists "$VMID"; then

        # --force-overwrite path
        if [[ "$FORCE_OVERWRITE" == "yes" ]]; then
            if vmid_is_running "$VMID"; then
                die "VM $VMID is currently running. Stop it before overwriting."
            fi
            if ! vmid_is_template "$VMID"; then
                local name
                name="$(vmid_name "$VMID")"
                die "VM $VMID ('${name}') is not a Proxmox template (template: 1 not set). --force-overwrite only works on templates to prevent accidental destruction of regular VMs."
            fi
            destroy_existing_template "$VMID"
            return
        fi

        # --auto-vmid with explicit --vmid: increment from the requested ID
        if [[ "$AUTO_VMID" == "yes" ]]; then
            local original_vmid="$VMID"
            VMID="$(next_free_vmid "$VMID")"
            warn "VM ID $original_vmid already exists. Next free ID from there: $VMID"
            return
        fi

        # Unattended with no resolution strategy — die clearly
        if [[ "$UNATTENDED" == "yes" ]]; then
            die "VM ID $VMID already exists. Re-run with one of:
  --vmid <id>          to specify a different ID
  --auto-vmid          to automatically use the next free ID
  --force-overwrite    to destroy the existing template and replace it (templates only)"
        fi

        # Interactive — keep prompting
        while vmid_exists "$VMID"; do
            warn "VM ID $VMID already exists."
            read -rp "Enter a different VM ID: " VMID
        done
    fi

    success "VM ID: $VMID"
}

# =============================================================================
# SSH key selection helper
# =============================================================================
# Offers four methods:
#   1. Paste a public key directly
#   2. Provide a path to a .pub file
#   3. Pick from keys found in ~/.ssh/ on this Proxmox host
#   4. Fetch from GitHub by username
#   5. Skip (no SSH key)
# If a key was loaded from a config file, user can keep, replace, or clear it.
#
# Note: GitHub strips comments server-side — keys fetched from github.com/<user>.keys
# arrive without a comment field regardless of how they were uploaded. All methods
# therefore prompt for a comment if one is not already present.
# =============================================================================

# Checks whether a key string has a comment (3rd field). If not, prompts the
# user to add one. Returns the key string (with comment appended if provided).
_ensure_key_comment() {
    local key="$1"
    local field_count
    field_count=$(awk '{print NF}' <<< "$key")
    if (( field_count >= 3 )); then
        echo "$key"
        return
    fi
    # Redirect UI to stderr — this function is called inside $() so stdout
    # is captured into SSH_KEY; any echo to stdout other than the key itself
    # would corrupt the value.
    echo "" >&2
    info "This key has no comment — Proxmox will show it as blank in the UI." >&2
    read -rp "  Add a comment (e.g. hostname or key purpose, leave blank to skip): " comment
    if [[ -n "$comment" ]]; then
        echo "$key $comment"
    else
        echo "$key"
    fi
}

_prompt_ssh_key() {
    echo ""
    header "SSH Key"

    # If a key is already set (e.g. from a loaded config), show it and offer options
    if [[ -n "${SSH_KEY:-}" ]]; then
        echo "  A key is already set (from config):"
        echo "  ${SSH_KEY:0:72}..."
        echo ""
        echo "  1) Keep this key"
        echo "  2) Replace it"
        echo "  3) Clear it (no SSH key)"
        echo ""
        read -rp "Choice [1]: " choice
        choice="${choice:-1}"
        case "$choice" in
            1) return ;;
            3) SSH_KEY=""; info "SSH key cleared."; return ;;
            2) ;;   # fall through to selection below
            *) warn "Invalid choice, keeping existing key."; return ;;
        esac
    fi

    echo "  How would you like to provide an SSH public key?"
    echo ""
    echo "  1) Paste the public key now"
    echo "  2) Enter a path to a .pub file"
    echo "  3) Choose from keys in ~/.ssh/ on this host"
    echo "  4) Fetch from GitHub (by username)"
    echo "  5) Skip — no SSH key"
    echo ""
    read -rp "Choice [1]: " method
    method="${method:-1}"

    case "$method" in
        1)
            read -rp "Paste your public key: " input
            if [[ -z "$input" ]]; then
                warn "No key entered. SSH key will not be set."
                SSH_KEY=""
            else
                SSH_KEY="$(_ensure_key_comment "$input")"
                success "Key accepted."
            fi
            ;;
        2)
            read -rp "Path to .pub file: " pub_path
            pub_path="${pub_path/#\~/$HOME}"   # expand ~ manually
            if [[ ! -f "$pub_path" ]]; then
                warn "File not found: $pub_path — SSH key will not be set."
                SSH_KEY=""
            else
                SSH_KEY="$(_ensure_key_comment "$(cat "$pub_path")")"
                success "Key loaded from: $pub_path"
            fi
            ;;
        3)
            local pub_files=()
            mapfile -t pub_files < <(find "$HOME/.ssh" -maxdepth 1 -name "*.pub" 2>/dev/null | sort)
            if [[ ${#pub_files[@]} -eq 0 ]]; then
                warn "No .pub files found in $HOME/.ssh/ — SSH key will not be set."
                SSH_KEY=""
                return
            fi
            echo ""
            echo "  Available keys:"
            local i=1
            for f in "${pub_files[@]}"; do
                printf "  %d) %s\n" "$i" "$f"
                ((i++))
            done
            echo ""
            read -rp "Select key (number): " sel
            if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#pub_files[@]} )); then
                SSH_KEY="$(_ensure_key_comment "$(cat "${pub_files[$((sel-1))]}")")"
                success "Key loaded: ${pub_files[$((sel-1))]}"
            else
                warn "Invalid selection — SSH key will not be set."
                SSH_KEY=""
            fi
            ;;
        4)
            read -rp "GitHub username: " gh_user
            if [[ -z "$gh_user" ]]; then
                warn "No username entered — SSH key will not be set."
                SSH_KEY=""
            else
                info "Fetching keys from github.com/${gh_user}..."
                local gh_keys
                gh_keys=$(wget -qO- "https://github.com/${gh_user}.keys" 2>/dev/null || true)
                if [[ -z "$gh_keys" ]]; then
                    warn "No public keys found for GitHub user '${gh_user}'."
                    warn "SSH key will not be set — double-check the username."
                    SSH_KEY=""
                else
                    # GitHub strips comments — store the raw key and prompt for comment
                    SSH_KEY="$(_ensure_key_comment "$gh_keys")"
                    success "GitHub key set for user: $gh_user"
                fi
            fi
            ;;
        5)
            SSH_KEY=""
            info "No SSH key will be set. You can add one manually after cloning."
            ;;
        *)
            warn "Invalid choice — SSH key will not be set."
            SSH_KEY=""
            ;;
    esac
}

# =============================================================================
# cloud-init snippets / user-data (optional)
# =============================================================================
# Proxmox can attach a user-data YAML snippet to a VM so cloud-init applies
# it on first boot of every clone. This is optional — if the chosen storage
# has a 'snippets' content type, we offer to create a minimal user-data file.
#
# The snippet enables password auth (off by default in Ubuntu cloud images)
# and configures a few sensible first-boot defaults. Users can edit it freely
# before cloning.
# =============================================================================
SNIPPETS_ENABLED="no"
SNIPPETS_STOR=""
SNIPPETS_FILE=""

_prompt_snippets() {
    # In unattended mode: only proceed if SNIPPETS_STOR is already set in config.
    # Skip the search entirely if not — the user made that choice when they built
    # the profile.
    if [[ "$UNATTENDED" == "yes" ]]; then
        if [[ -n "${SNIPPETS_STOR:-}" ]]; then
            info "Unattended mode — using snippet storage from config: $SNIPPETS_STOR"
            SNIPPETS_ENABLED="yes"
            SNIPPETS_FILE="${TEMPL_NAME}-user-data.yaml"
        else
            info "Unattended mode — no snippet storage configured, skipping."
        fi
        return
    fi

    echo ""
    header "cloud-init User-Data Snippet (optional)"

    # Find storages that have 'snippets' content type enabled
    info "Searching for snippet-capable storage pools..."
    local snippet_stores=()
    while IFS= read -r line; do
        local name
        name=$(awk '{print $1}' <<< "$line")
        [[ "$name" == "Name" ]] && continue
        # pvesm status doesn't show content; use pvesm list to check
        if pvesm list "$name" --content snippets &>/dev/null 2>&1; then
            snippet_stores+=("$name")
        fi
    done < <(pvesm status)

    if [[ ${#snippet_stores[@]} -eq 0 ]]; then
        info "No storage pools with 'snippets' content type found."
        info "To use this feature, enable 'Snippets' on a storage pool in the Proxmox UI."
        return
    fi

    echo "  A cloud-init user-data snippet can be attached to this template."
    echo "  Every VM cloned from it will automatically receive these settings"
    echo "  on first boot — useful for package updates, SSH hardening, etc."
    echo ""
    echo "  The generated snippet will:"
    echo "    - Enable password authentication over SSH (disabled by default"
    echo "      in Ubuntu cloud images — important if you don't set an SSH key)"
    echo "    - Run apt-get upgrade on first boot"
    echo "    - Set the hostname from the VM name"
    echo ""
    read -rp "Create a user-data snippet? (y/N): " choice
    choice="${choice:-N}"
    [[ ! "$choice" =~ ^[Yy]$ ]] && return

    # If only one snippet store, use it; otherwise ask
    if [[ ${#snippet_stores[@]} -eq 1 ]]; then
        SNIPPETS_STOR="${snippet_stores[0]}"
        info "Using snippets storage: $SNIPPETS_STOR"
    else
        echo ""
        echo "  Available snippet-capable storages:"
        local i=1
        for s in "${snippet_stores[@]}"; do
            echo "  $i) $s"
            ((i++))
        done
        read -rp "Select storage (number): " sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#snippet_stores[@]} )); then
            SNIPPETS_STOR="${snippet_stores[$((sel-1))]}"
        else
            warn "Invalid selection — skipping snippet creation."
            return
        fi
    fi

    SNIPPETS_ENABLED="yes"
    SNIPPETS_FILE="${TEMPL_NAME}-user-data.yaml"
}

apply_snippets() {
    [[ "$SNIPPETS_ENABLED" != "yes" ]] && return

    header "cloud-init User-Data Snippet"

    # Resolve the filesystem path for this storage
    local stor_path
    stor_path=$(pvesm path "${SNIPPETS_STOR}:snippets" 2>/dev/null \
                || pvesm status | awk -v s="$SNIPPETS_STOR" '$1==s {print $NF}')

    # Fallback: read path from pvesm config
    if [[ -z "$stor_path" || ! -d "$stor_path" ]]; then
        stor_path=$(grep -A5 "^${SNIPPETS_STOR}:" /etc/pve/storage.cfg \
                    | grep 'path' | awk '{print $2}')
        stor_path="${stor_path}/snippets"
    fi

    if [[ -z "$stor_path" || ! -d "$stor_path" ]]; then
        warn "Could not resolve snippets directory for '$SNIPPETS_STOR'. Skipping."
        SNIPPETS_ENABLED="no"
        return
    fi

    local snippet_path="${stor_path}/${SNIPPETS_FILE}"

    cat > "$snippet_path" <<EOF
#cloud-config
# cloud-init user-data snippet for: ${TEMPL_NAME}
# Generated by ${SCRIPT_NAME} on $(date '+%Y-%m-%d %H:%M')
#
# This file is applied on first boot of every VM cloned from this template.
# Edit it before cloning to customise first-boot behaviour.
# Reference: https://cloudinit.readthedocs.io/en/latest/reference/examples.html

# Allow SSH password authentication.
# Set to 'false' if you are using SSH keys exclusively (recommended).
ssh_pwauth: true

# Update package list and upgrade all packages on first boot.
package_update: true
package_upgrade: true

# Install additional packages on first boot (add to the list as needed).
# packages:
#   - curl
#   - git
#   - vim

# Set the hostname from the VM/instance name provided by the datasource.
preserve_hostname: false

# Grow the root partition/filesystem to fill the disk automatically.
# (cloud-utils-growpart handles this; included in VIRT_PKGS above.)
growpart:
  mode: auto
  devices: ["/"]

# Final message logged to /var/log/cloud-init-output.log on completion.
final_message: |
  Cloud-init finished for ${TEMPL_NAME}.
  Up \$UPTIME seconds. Version: \$VERSION. Datasource: \$DATASOURCE.
EOF

    success "Snippet written to: $snippet_path"

    # Attach the snippet to the VM as user-data
    qm set "$VMID" --cicustom "user=${SNIPPETS_STOR}:snippets/${SNIPPETS_FILE}"
    success "Snippet attached to VM $VMID as user-data."
    info "Edit the snippet at any time before cloning:"
    info "  $snippet_path"
}

# =============================================================================
# User-facing prompts for remaining variables
# =============================================================================
user_prompts() {
    # In unattended mode all values come from the config file.
    # Password is always auto-generated (never saved to config).
    if [[ "$UNATTENDED" == "yes" ]]; then
        TEMPL_NAME="${TEMPL_NAME:-$TEMPL_NAME_DEFAULT}"
        CLOUD_USER="${CLOUD_USER_DEFAULT}"
        CLOUD_PASSWORD="${CLOUD_PASSWORD_DEFAULT}"
        EXTRA_VIRT_PKGS="${EXTRA_VIRT_PKGS:-}"
        info "Unattended mode — using all values from config."
        info "Cloud-Init password will be auto-generated and shown at the end."
        return
    fi

    header "Template Configuration"

    # Template name — use --name flag value if already set
    if [[ -z "${TEMPL_NAME:-}" ]]; then
        read -rp "Template name [${TEMPL_NAME_DEFAULT}]: " input
        TEMPL_NAME="${input:-$TEMPL_NAME_DEFAULT}"
    else
        info "Using template name from --name flag: $TEMPL_NAME"
    fi

    # Cloud-init user
    read -rp "Cloud-Init username [${CLOUD_USER_DEFAULT}]: " input
    CLOUD_USER="${input:-$CLOUD_USER_DEFAULT}"

    # Cloud-init password
    read -rp "Cloud-Init password [auto-generated]: " input
    CLOUD_PASSWORD="${input:-$CLOUD_PASSWORD_DEFAULT}"
    if [[ "$input" == "$CLOUD_PASSWORD_DEFAULT" || -z "$input" ]]; then
        info "Using generated password: $CLOUD_PASSWORD"
    fi

    # SSH key
    _prompt_ssh_key

    # Extra packages
    echo ""
    read -rp "Extra packages to install (comma-separated, blank for none) [${EXTRA_VIRT_PKGS:-none}]: " input
    EXTRA_VIRT_PKGS="${input:-$EXTRA_VIRT_PKGS}"

    # VLAN
    echo ""
    read -rp "VLAN tag (leave blank for none) [${VLAN:-}]: " input
    VLAN="${input:-$VLAN}"

    # Disk size — user enters a number, G is appended automatically
    echo ""
    local disk_default_num="${DISK_SIZE//[^0-9]/}"   # strip any existing unit
    echo "Disk size in GB (numbers only — 'G' will be added automatically):"
    read -rp "Disk size in GB [${disk_default_num}]: " input
    input="${input//[^0-9]/}"                         # strip any unit the user typed anyway
    input="${input:-$disk_default_num}"
    DISK_SIZE="${input}G"
    info "Disk size set to: $DISK_SIZE"

    # Tags
    echo ""
    echo "VM tags are used to organise and filter VMs in the Proxmox UI."
    echo "Separate multiple tags with semicolons (e.g. template;ubuntu;noble)."
    read -rp "Tags [${TAG}]: " input
    TAG="${input:-$TAG}"

    # CPU type — numbered list to prevent typos
    echo ""
    local cpu_options=("host" "kvm64" "x86-64-v2-AES" "x86-64-v3")
    local cpu_descriptions=(
        "Recommended — exposes host CPU directly, best performance. Use unless you need live migration across different CPU generations."
        "Safer for mixed-CPU clusters — lower performance but broadly compatible."
        "Broader feature set than kvm64, still widely compatible with modern hardware."
        "Good balance of features for modern homogeneous environments."
    )
    echo "CPU type:"
    local default_cpu_num=1
    for idx in "${!cpu_options[@]}"; do
        local marker=""
        [[ "${cpu_options[$idx]}" == "$CPU_TYPE" ]] && marker=" (current)" && default_cpu_num=$((idx+1))
        printf "  %d) %-18s %s\n" "$((idx+1))" "${cpu_options[$idx]}${marker}" "${cpu_descriptions[$idx]}"
    done
    echo ""
    read -rp "Select CPU type [${default_cpu_num}]: " input
    input="${input:-$default_cpu_num}"
    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#cpu_options[@]} )); then
        CPU_TYPE="${cpu_options[$((input-1))]}"
    else
        warn "Invalid selection, keeping: $CPU_TYPE"
    fi
    info "CPU type set to: $CPU_TYPE"

    # cloud-init snippets / user-data
    _prompt_snippets
}

# =============================================================================
# Image download with SHA256 verification
# =============================================================================
# Strategy: keep a pristine untouched copy of the downloaded image alongside
# the working copy. virt-customize operates on the working copy only, so the
# pristine copy's checksum remains valid for upstream comparison on future runs.
#
# Flow:
#   1. No pristine copy exists → download, verify SHA256, save as pristine,
#      copy to working image.
#   2. Pristine exists, checksum matches upstream → copy pristine to working
#      image (fast, no download needed).
#   3. Pristine exists, checksum mismatches → Ubuntu has published a new image;
#      prompt user to re-download or continue with the existing pristine.
# =============================================================================
download_image() {
    header "Image Download"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || die "Cannot cd to $WORK_DIR"

    local image_path="$WORK_DIR/$DISK_IMAGE"
    local pristine_path="$WORK_DIR/${DISK_IMAGE}.pristine"

    info "Fetching SHA256SUMS from upstream..."
    local checksum_file="$WORK_DIR/SHA256SUMS_${DISTRO_VER}"
    wget -qO "$checksum_file" "$CHECKSUM_URL" \
        || die "Failed to download SHA256SUMS from $CHECKSUM_URL"

    local expected_checksum
    expected_checksum=$(grep "$DISK_IMAGE" "$checksum_file" | awk '{print $1}')
    [[ -z "$expected_checksum" ]] \
        && die "Could not find checksum for $DISK_IMAGE in SHA256SUMS."

    if [[ -f "$pristine_path" ]]; then
        info "Pristine image found. Verifying against upstream checksum..."
        local pristine_checksum
        pristine_checksum=$(sha256sum "$pristine_path" | awk '{print $1}')

        if [[ "$pristine_checksum" == "$expected_checksum" ]]; then
            success "Pristine image is current. Copying to working image..."
            cp "$pristine_path" "$image_path"
            success "Working image ready."
            return
        else
            warn "Pristine image checksum differs from upstream."
            warn "Ubuntu has likely published a newer version of $DISK_IMAGE."
            echo ""
            echo "  1) Re-download the new image from Ubuntu (recommended)"
            echo "  2) Continue with the existing pristine image as-is"
            echo ""
            read -rp "Choice [1]: " redownload_choice
            redownload_choice="${redownload_choice:-1}"
            if [[ "$redownload_choice" == "1" ]]; then
                info "Removing old pristine image..."
                rm -f "$pristine_path"
                # Fall through to fresh download below
            else
                warn "Using existing pristine image. Note it may be outdated."
                cp "$pristine_path" "$image_path"
                return
            fi
        fi
    fi

    info "Downloading $DISK_IMAGE..."
    wget -nv --show-progress -O "$pristine_path" "$IMAGE_URL" \
        || { rm -f "$pristine_path"; die "Image download failed."; }

    info "Verifying downloaded image..."
    local actual_checksum
    actual_checksum=$(sha256sum "$pristine_path" | awk '{print $1}')
    if [[ "$actual_checksum" != "$expected_checksum" ]]; then
        rm -f "$pristine_path"
        die "Checksum verification failed! Expected: $expected_checksum | Got: $actual_checksum"
    fi
    success "Image verified: $DISK_IMAGE"

    info "Copying pristine image to working copy..."
    cp "$pristine_path" "$image_path"
    success "Working image ready."
}

# =============================================================================
# Single consolidated virt-customize call
# =============================================================================
customize_image() {
    header "Image Customisation"
    local image_path="$WORK_DIR/$DISK_IMAGE"
    local vc_args=()

    vc_args+=(-a "$image_path")

    # Timezone
    if [[ -n "${TZ:-}" ]]; then
        vc_args+=(--timezone "$TZ")
    fi

    # Locale and X11 keyboard (firstboot so localectl is available)
    if [[ "${SET_X11:-}" == "yes" ]]; then
        vc_args+=(
            --firstboot-command "localectl set-locale LANG=${LOCAL_LANG}"
            --firstboot-command "localectl set-x11-keymap ${X11_LAYOUT} ${X11_MODEL}"
        )
    fi

    # Packages: update + core + optional extras
    local all_pkgs="$VIRT_PKGS"
    if [[ -n "${EXTRA_VIRT_PKGS:-}" ]]; then
        all_pkgs="${all_pkgs},${EXTRA_VIRT_PKGS}"
    fi
    vc_args+=(--update --install "$all_pkgs")

    info "Running virt-customize (this may take a few minutes)..."
    virt-customize "${vc_args[@]}" || die "virt-customize failed."
    success "Image customised."
}

# =============================================================================
# Proxmox cloud-init datasource config
# =============================================================================
inject_cloud_init_config() {
    header "Cloud-Init Datasource Config"
    local cfg="$WORK_DIR/99_pve.cfg"
    cat > "$cfg" <<'EOF'
# Managed by create-ubuntu-cloud-template.sh
# To update, run: dpkg-reconfigure cloud-init
datasource_list: [ NoCloud, ConfigDrive ]
EOF
    virt-customize -a "$WORK_DIR/$DISK_IMAGE" \
        --upload "${cfg}:/etc/cloud/cloud.cfg.d/"
    success "Datasource config injected."
}

# =============================================================================
# VM creation
# =============================================================================
create_vm() {
    header "VM Creation"
    local net_opts="virtio,bridge=${NET_BRIDGE}"
    [[ -n "${VLAN:-}" ]] && net_opts+=",tag=${VLAN}"

    info "Creating VM $VMID ($TEMPL_NAME)..."
    qm create "$VMID" \
        --name       "$TEMPL_NAME" \
        --memory     "$MEM" \
        --balloon    "$BALLOON" \
        --cores      "$CORES" \
        --cpu        "$CPU_TYPE" \
        --bios       "$BIOS" \
        --machine    "$MACHINE" \
        --ostype     "$OS_TYPE" \
        --agent      "enabled=${AGENT_ENABLE},fstrim_cloned_disks=${FSTRIM}" \
        --net0       "$net_opts" \
        --tags       "$TAG" \
        --rng0       "source=/dev/urandom" \
        --boot       "c" \
        --bootdisk   "scsi0" \
        --tablet     "0" \
        --ipconfig0  "ip=dhcp" \
        --ciuser     "$CLOUD_USER" \
        --cipassword "$CLOUD_PASSWORD" \
        --ciupgrade  "0"
    # Mark VM as created — error handler will destroy it if anything fails from here
    VMID_CREATED="$VMID"

    info "Importing disk (format: $STORAGE_FORMAT, backend: $STORAGE_BACKEND)..."
    if [[ "$STORAGE_FORMAT" == "raw" ]]; then
        qm importdisk "$VMID" "$WORK_DIR/$DISK_IMAGE" "$DISK_STOR"
    else
        qm importdisk "$VMID" "$WORK_DIR/$DISK_IMAGE" "$DISK_STOR" -format qcow2
    fi

    # Disk reference format differs only for dir-backed storage
    local disk_ref
    if [[ "$STORAGE_BACKEND" == "dir" ]]; then
        disk_ref="${DISK_STOR}:${VMID}/vm-${VMID}-disk-0.qcow2"
    else
        disk_ref="${DISK_STOR}:vm-${VMID}-disk-0"
    fi

    # EFI disk format option differs only for dir-backed storage
    local efi_fmt=""
    [[ "$STORAGE_BACKEND" == "dir" ]] && efi_fmt=",format=qcow2"

    # ZFS manages its own caching (ARC); adding a host-level cache layer causes
    # double-buffering and can corrupt data on power loss. Use the Proxmox
    # "Default (no cache)" value (cache=none) for ZFS, write-through elsewhere.
    local disk_cache="writethrough"
    [[ "$STORAGE_BACKEND" == "zfs" ]] && disk_cache="none"

    qm set "$VMID" \
        --scsihw  "virtio-scsi-single" \
        --scsi0   "${disk_ref},cache=${disk_cache},discard=on,iothread=1,ssd=1" \
        --scsi1   "${DISK_STOR}:cloudinit" \
        --efidisk0 "${DISK_STOR}:0,efitype=4m${efi_fmt},ms-cert=2023k,pre-enrolled-keys=1,size=1M"

    qm cloudinit update "$VMID"

    # qm set --description mangles newlines when passed through shell expansion.
    # Write directly via python3 which handles multiline strings cleanly.
    python3 - "$VMID" <<PYEOF
import subprocess, sys
vmid = sys.argv[1]
desc = """\
**OS:** ${OS_NAME}

**Template created:** $(date '+%Y-%m-%d %H:%M')

**Storage:** ${DISK_STOR} (${STORAGE_BACKEND}/${STORAGE_FORMAT})

**CPU type:** ${CPU_TYPE}

**Cloud-Init user:** ${CLOUD_USER}

---

### Notes

> **SSH password authentication is DISABLED** by default in Ubuntu cloud images.
> If you are not using an SSH key, enable it in the cloud-init user-data snippet,
> or add this to \`/etc/ssh/sshd_config\` after first boot:
> \`PasswordAuthentication yes\`

> **Automatic package upgrades on first boot are disabled** (\`ciupgrade=0\`).
> Run upgrades manually or via your config management tool after cloning.

---

### Before re-templating this VM, run inside it:

\`\`\`
apt-get clean
&& apt -y autoremove --purge
&& apt -y autoclean
&& cloud-init clean
&& echo -n > /etc/machine-id
&& echo -n > /var/lib/dbus/machine-id
&& sync
&& history -c
&& history -w
&& fstrim -av
&& shutdown now
\`\`\`
"""
subprocess.run(["qm", "set", vmid, "--description", desc], check=True)
PYEOF
    success "VM $VMID created."
}

# =============================================================================
# SSH key
# =============================================================================
# qm set --sshkeys expects a real file path (one key per line, OpenSSH format).
# GitHub keys are now fetched and comment-checked during _prompt_ssh_key, so
# by this point SSH_KEY is always a literal key string regardless of source.
# =============================================================================
apply_ssh_key() {
    [[ -z "${SSH_KEY:-}" ]] && return
    header "SSH Key"

    local key="${SSH_KEY}"

    # Handle legacy config entries where SSH_KEY was saved as "github.com/<user>"
    # instead of the actual fetched key string. Fetch the real key on the fly.
    if [[ "$key" == github.com/* ]]; then
        local gh_user="${key#github.com/}"
        info "Config contains a GitHub reference — fetching key for user: $gh_user"
        key=$(wget -qO- "https://github.com/${gh_user}.keys" 2>/dev/null | tr -d '\r\n' || true)
        if [[ -z "$key" ]]; then
            die "Could not fetch SSH key from github.com/${gh_user}.keys — check the username and your internet connection."
        fi
        # Update SSH_KEY so write_config saves the literal key going forward
        SSH_KEY="$key"
        info "Key fetched. Profile will be updated with the literal key on next save."
    fi

    qm set "$VMID" --sshkey <(echo "${key}")
    success "SSH key applied."
}

# =============================================================================
# Disk resize
# =============================================================================
resize_disk() {
    header "Disk Resize"
    qm resize "$VMID" scsi0 "$DISK_SIZE"
    success "Disk resized to $DISK_SIZE."
}

# =============================================================================
# Convert to template (optional)
# =============================================================================
# Behaviour priority:
#   1. --convert-to-template / --no-convert-to-template CLI flag
#   2. CONVERT_TO_TEMPLATE value from loaded config file
#   3. Interactive prompt (default: no, to encourage customisation first)
# =============================================================================
maybe_convert_to_template() {
    header "Convert to Proxmox Template"

    local do_convert="${CONVERT_TO_TEMPLATE:-}"

    # In unattended mode with no explicit flag, default to no conversion
    if [[ "$UNATTENDED" == "yes" && -z "$do_convert" ]]; then
        do_convert="no"
        info "Unattended mode — skipping template conversion. Run 'qm template $VMID' when ready."
    fi

    if [[ -z "$do_convert" ]]; then
        echo "  Converting to a template locks the VM and makes it read-only."
        echo "  Skip this step if you want to boot the VM first and customise it"
        echo "  (with Ansible, manual config, etc.) before templating."
        echo ""
        read -rp "Convert VM $VMID to a Proxmox template now? (y/N): " choice
        choice="${choice:-N}"
        [[ "$choice" =~ ^[Yy]$ ]] && do_convert="yes" || do_convert="no"
    fi

    if [[ "$do_convert" == "yes" ]]; then
        qm template "$VMID"
        success "VM $VMID converted to template."
    else
        info "Skipping template conversion — VM $VMID left as a regular VM."
        info "To convert later, run:  qm template $VMID"
    fi
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    header "Cleanup"
    local cfg="$WORK_DIR/99_pve.cfg"
    local checksum_file="$WORK_DIR/SHA256SUMS_${DISTRO_VER:-unknown}"

    [[ -f "$cfg" ]]           && rm -vf "$cfg"
    [[ -f "$checksum_file" ]] && rm -vf "$checksum_file"
    # Clean up any leftover notes temp files
    rm -f /tmp/proxmox-notes-*.txt 2>/dev/null || true

    # Working image (virt-customised) — always remove, it's single-use
    local image_path="$WORK_DIR/${DISK_IMAGE:-}"
    if [[ -n "${DISK_IMAGE:-}" && -f "$image_path" ]]; then
        info "Removing working image (already imported into Proxmox)..."
        rm -vf "$image_path"
    fi

    # Pristine image — offer to keep for future runs (saves re-downloading)
    local pristine_path="$WORK_DIR/${DISK_IMAGE:-}.pristine"
    if [[ -n "${DISK_IMAGE:-}" && -f "$pristine_path" ]]; then
        if [[ "$UNATTENDED" == "yes" ]]; then
            info "Unattended mode — keeping pristine image for future runs."
        else
            echo ""
            echo "  The pristine (unmodified) image is kept at:"
            echo "  $pristine_path"
            echo "  Keeping it avoids re-downloading on future runs (~$(du -sh "$pristine_path" | cut -f1))."
            read -rp "  Delete the pristine image? (y/N): " choice
            choice="${choice:-N}"
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                rm -vf "$pristine_path"
                success "Pristine image deleted."
            else
                info "Pristine image kept for future runs."
            fi
        fi
    fi
}

# =============================================================================
# Config profile — name capture and file write are separate so the file can
# be written immediately after the user confirms, before any work begins.
# =============================================================================

# Step 1 — ask for a profile name right after the user presses Y.
# Sets PROFILE_NAME and PROFILE_PATH; empty means the user declined.
prompt_config_name() {
    echo ""
    info "Your answers can be saved as a reusable profile now, before the run begins."
    info "If something goes wrong mid-run you can restart with: ./${SCRIPT_NAME} --config <profile>.conf"
    echo ""
    read -rp "Save a profile? Enter a name (e.g. noble-webserver) or leave blank to skip: " profile_name
    profile_name="${profile_name// /-}"   # replace spaces with hyphens

    if [[ -z "$profile_name" ]]; then
        info "No profile will be saved."
        PROFILE_NAME=""
        PROFILE_PATH=""
        return
    fi

    PROFILE_NAME="$profile_name"
    PROFILE_PATH="${SCRIPT_DIR}/${PROFILE_NAME}.conf"

    # Warn if a file with that name already exists
    if [[ -f "$PROFILE_PATH" ]]; then
        warn "A profile already exists at: $PROFILE_PATH"
        read -rp "Overwrite it? (y/N): " ow
        ow="${ow:-N}"
        if [[ ! "$ow" =~ ^[Yy]$ ]]; then
            info "Profile not saved."
            PROFILE_NAME=""
            PROFILE_PATH=""
            return
        fi
    fi

    write_config
}

# Step 2 — write the config file. Called immediately after prompt_config_name
# and again at the end of a successful run to update CONVERT_TO_TEMPLATE if
# the user answered that interactively.
write_config() {
    [[ -z "${PROFILE_PATH:-}" ]] && return

    cat > "$PROFILE_PATH" <<EOF
# Profile: ${PROFILE_NAME}
# Generated by ${SCRIPT_NAME} on $(date '+%Y-%m-%d %H:%M')
# Usage: ./${SCRIPT_NAME} --config ${PROFILE_NAME}.conf
#
# Note: VMID is intentionally not saved — it is always assigned interactively
# or defaulted to VMID_DEFAULT to avoid clashes on subsequent runs.

# Ubuntu version
DISTRO_VER="${DISTRO_VER}"

# Storage
DISK_STOR="${DISK_STOR}"
# STORAGE_FORMAT and STORAGE_BACKEND are auto-detected at runtime; do not set here.

# VM hardware
VMID_DEFAULT="${VMID_DEFAULT}"
CORES="${CORES}"
MEM="${MEM}"
BALLOON="${BALLOON}"
BIOS="${BIOS}"
MACHINE="${MACHINE}"
CPU_TYPE="${CPU_TYPE}"
DISK_SIZE="${DISK_SIZE}"
OS_TYPE="${OS_TYPE}"
NET_BRIDGE="${NET_BRIDGE}"
VLAN="${VLAN}"
AGENT_ENABLE="${AGENT_ENABLE}"
FSTRIM="${FSTRIM}"

# cloud-init snippets
# SNIPPETS_ENABLED is re-evaluated at runtime based on storage capabilities.
# Set SNIPPETS_STOR to pre-select a snippets storage, or leave empty to be prompted.
SNIPPETS_STOR="${SNIPPETS_STOR:-}"

# Template identity
TEMPL_NAME_DEFAULT="${TEMPL_NAME}"
TAG="${TAG}"

# Cloud-Init
CLOUD_USER_DEFAULT="${CLOUD_USER}"
# CLOUD_PASSWORD_DEFAULT is intentionally not saved for security.

# SSH key
# Unlike the script defaults, it IS safe to store your key here — this .conf
# file is personal to you and not part of the shared script. It will not be
# committed to any repo unless you explicitly add it.
# This can be a full public key string, or a GitHub URL (github.com/<username>).
SSH_KEY="${SSH_KEY:-}"

# Packages
VIRT_PKGS="${VIRT_PKGS}"
EXTRA_VIRT_PKGS="${EXTRA_VIRT_PKGS:-}"

# Template conversion
# Set to "yes" to always convert, "no" to always skip, or leave empty to be asked each run.
# Can also be controlled per-run with --template or --no-template CLI flags.
CONVERT_TO_TEMPLATE="${CONVERT_TO_TEMPLATE:-}"

# Locale
LOCAL_LANG="${LOCAL_LANG}"
SET_X11="${SET_X11}"
X11_LAYOUT="${X11_LAYOUT}"
X11_MODEL="${X11_MODEL}"
TZ="${TZ}"
EOF

    success "Profile saved: $PROFILE_PATH"
}

# =============================================================================
# Summary before proceeding
# =============================================================================
print_summary() {
    header "Summary — Review Before Proceeding"
    echo ""

    local ssh_display
    if [[ -n "${SSH_KEY:-}" ]]; then
        ssh_display="(set) ${SSH_KEY:0:40}..."
    else
        ssh_display="(none)"
    fi

    local extra_display="${EXTRA_VIRT_PKGS:-(none)}"

    local templ_str
    case "${CONVERT_TO_TEMPLATE:-}" in
        yes) templ_str="Yes (--template)" ;;
        no)  templ_str="No  (--no-template)" ;;
        *)   templ_str="Ask me at the end" ;;
    esac

    printf "  %-24s %s\n" "OS:"                   "$OS_NAME"
    printf "  %-24s %s\n" "VM ID:"                "$VMID"
    printf "  %-24s %s\n" "Template name:"        "$TEMPL_NAME"
    local cache_display="writethrough"
    [[ "$STORAGE_BACKEND" == "zfs" ]] && cache_display="none (ZFS default)"
    printf "  %-24s %s\n" "Storage:"              "$DISK_STOR ($STORAGE_BACKEND / $STORAGE_FORMAT, cache=$cache_display)"
    printf "  %-24s %s\n" "Disk size:"            "$DISK_SIZE"
    printf "  %-24s %s\n" "CPUs / RAM:"           "$CORES cores / ${MEM}MB (balloon: ${BALLOON}MB)"
    printf "  %-24s %s\n" "BIOS / Machine:"       "$BIOS / $MACHINE"
    printf "  %-24s %s\n" "CPU type:"             "$CPU_TYPE"
    printf "  %-24s %s\n" "Tags:"                 "$TAG"
    printf "  %-24s %s\n" "Network:"              "$NET_BRIDGE${VLAN:+ VLAN $VLAN}"
    printf "  %-24s %s\n" "Cloud-Init user:"      "$CLOUD_USER"
    printf "  %-24s %s\n" "SSH key:"              "$ssh_display"
    printf "  %-24s %s\n" "Extra packages:"       "$extra_display"
    printf "  %-24s %s\n" "Timezone:"             "$TZ"
    printf "  %-24s %s\n" "Convert to template:"  "$templ_str"
    echo ""

    if [[ "$UNATTENDED" == "yes" ]]; then
        warn "Running in unattended mode. Starting in 5 seconds — press Ctrl+C to abort."
        for i in 5 4 3 2 1; do
            printf "\r  Starting in %s... " "$i"
            sleep 1
        done
        printf "\r  Starting now.          \n"
        echo ""
        # Config already exists (loaded via --config), no need to prompt for a name
        return
    fi

    local proceed
    read -rp "Proceed? (Y/n): " proceed
    proceed="${proceed:-Y}"
    if [[ "$proceed" =~ ^[Nn]$ ]]; then
        info "Aborted by user."
        exit 0
    fi

    # Save the profile immediately — before any work begins — so answers are
    # preserved if the run fails partway through.
    prompt_config_name
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${BOLD}Proxmox Ubuntu Cloud-Init Template Creator${RESET}"
    echo "=========================================="

    proxmox_check
    install_packages
    select_ubuntu_version
    select_storage
    get_valid_vmid
    user_prompts
    print_summary
    download_image
    customize_image
    inject_cloud_init_config
    create_vm
    apply_ssh_key
    apply_snippets
    resize_disk
    maybe_convert_to_template
    cleanup

    # Re-write the profile if one was saved, to capture the CONVERT_TO_TEMPLATE
    # answer if it was given interactively rather than via a CLI flag.
    if [[ -n "${PROFILE_PATH:-}" ]]; then
        write_config
        info "Profile updated: $PROFILE_PATH"
        info "Re-use with: ./${SCRIPT_NAME} --config ${PROFILE_NAME}.conf"
    fi

    echo ""
    if [[ "${CONVERT_TO_TEMPLATE:-no}" == "yes" ]]; then
        success "Template '$TEMPL_NAME' (ID: $VMID) is ready to clone."
    else
        success "VM '$TEMPL_NAME' (ID: $VMID) is ready. Boot it, customise, then run: qm template $VMID"
    fi

    if [[ "$UNATTENDED" == "yes" ]]; then
        echo ""
        warn "Cloud-Init password (auto-generated — change this after first login):"
        echo "  User:     $CLOUD_USER"
        echo "  Password: $CLOUD_PASSWORD"
        echo ""
        info "To change the password in Proxmox: qm set $VMID --cipassword '<newpassword>' && qm cloudinit update $VMID"
    fi

    # Disarm the error handler — run completed successfully
    VMID_CREATED=""
}

main "$@"