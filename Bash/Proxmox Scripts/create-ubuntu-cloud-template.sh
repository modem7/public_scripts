#!/bin/bash
# =============================================================================
#  Proxmox Ubuntu Cloud-Init Template Creator
# =============================================================================
#
#  WHAT IT DOES
#    Builds a ready-to-clone Ubuntu VM template on a Proxmox VE host.
#    1. Downloads the official Ubuntu cloud image (SHA256 verified).
#    2. Bakes in the qemu-guest-agent plus any extra packages you choose.
#    3. Creates the VM, attaches the disk + cloud-init drive.
#    4. Optionally converts it to a template.
#
#  REQUIREMENTS
#    - Run as root on a Proxmox VE host.
#    - Internet access (cloud-images.ubuntu.com, optionally github.com).
#    - Missing host packages are offered for install automatically.
#
#  QUICK START
#    First run    ./create-ubuntu-cloud-template.sh
#                 Answer the prompts. Save a profile when asked.
#
#    Re-run       ./create-ubuntu-cloud-template.sh --config <profile>.conf
#
#    Automated    ./create-ubuntu-cloud-template.sh --config <profile>.conf \
#                     --unattended --vmid 52000 --auto-vmid --template
#
#    All options  ./create-ubuntu-cloud-template.sh --help
#
#  VM ID CHEAT SHEET
#    --vmid 52001               Use exactly 52001. Stop if taken.
#    --auto-vmid                Next free ID, starting at 100.
#    --vmid 52000 --auto-vmid   Next free ID, starting at 52000.
#                               (Keeps templates in their own range.)
#
#  FILES IT CREATES
#    <script dir>/<profile>.conf    Your saved answers (only if you say so).
#    $WORK_DIR/*.img.pristine       Cached download. Skips re-downloading.
#    <storage>/snippets/*.yaml      Optional cloud-init vendor-data snippet.
#
#  SAFETY
#    - Never destroys anything unless you pass --force-overwrite.
#    - Even then: templates only, never running VMs or normal VMs.
#    - If the script fails midway, the half-built VM is removed.
#
#  Supported storage: ZFS, LVM/LVM-thin, Ceph RBD, BTRFS (raw)
#                     Directory, NFS, CIFS (qcow2)
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# =============================================================================
#  DEFAULTS
#  Edit these to change the starting values. A loaded profile overrides them.
# =============================================================================

# Where images are downloaded and customised.
# /var/tmp survives reboots, so the cached image is reused next run.
# Override for one run with:  WORK_DIR=/some/path ./create-ubuntu-cloud-template.sh
WORK_DIR="${WORK_DIR:-/var/tmp/ubuntu-cloud-template}"

# --- Cloud-init login ---
CLOUD_USER_DEFAULT="ubuntu"
# 16 random alphanumeric chars. Never saved to a profile.
_pw="$(head -c 48 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9')"
CLOUD_PASSWORD_DEFAULT="${_pw:0:16}"
unset _pw

# --- Locale / keyboard (applied on first boot) ---
LOCAL_LANG="en_GB.UTF-8"
SET_X11="yes"            # "no" skips both locale and keymap
X11_LAYOUT="gb"
X11_MODEL="pc105"
TZ="Europe/London"

# --- VM hardware ---
VMID_DEFAULT="52000"
CORES="2"
MEM="2048"               # MB
BALLOON="768"            # MB, minimum RAM when ballooning
BIOS="ovmf"              # UEFI
MACHINE="q35"
DISK_SIZE="15G"
OS_TYPE="l26"            # Linux 2.6+ kernel
NET_BRIDGE="vmbr1"
VLAN=""                  # blank = untagged
AGENT_ENABLE="1"
FSTRIM="1"               # trim disk after cloning

# Upgrade packages on a clone's first boot? 1 = yes, 0 = no.
# Same as "Upgrade packages" in the Proxmox Cloud-Init tab (can be changed there per VM).
CI_UPGRADE="0"

# CPU type
#   host   Best performance. Right for most homelabs (same CPU on every node).
#   kvm64  Use for live migration between nodes with different CPUs.
CPU_TYPE="host"

# --- Storage ---
DISK_STOR_DEFAULT="local-lvm"

# --- Packages baked into the image ---
#   qemu-guest-agent   lets Proxmox see the IP, shut down cleanly, trim disks
#   cloud-init         already in Ubuntu cloud images; listed as a safeguard
#   cloud-utils,
#   cloud-guest-utils  growpart, used by cloud-init to grow the root disk
VIRT_PKGS="qemu-guest-agent,cloud-init,cloud-utils,cloud-guest-utils"
EXTRA_VIRT_PKGS=""

# --- SSH public key ---
# !! Do NOT hardcode your key here. !!
# Anyone who copies this script would get SSH access to your VMs.
# Leave blank. The script asks at runtime and saves it in your .conf profile.
SSH_KEY=""

# --- Proxmox tags (semicolon separated) ---
TAG="template"

# --- Host packages the script needs ---
#   libguestfs-tools  virt-customize (edits the image offline)
#   wget              downloads
REQUIRED_PKGS=("libguestfs-tools" "wget")

# =============================================================================
#  OUTPUT HELPERS
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

# Visible countdown so Ctrl+C is always an option.
# Usage: _countdown "Starting"
_countdown() {
    local verb="$1" i
    for i in 5 4 3 2 1; do
        printf "\r  %s in %s... " "$verb" "$i"
        sleep 1
    done
    printf "\r  %s now.          \n" "$verb"
}

# Ask for a number between 1 and max. Re-asks until valid.
# Usage: _read_index "Prompt" <max> [default]   -> result in $PICK
_read_index() {
    local prompt="$1" max="$2" def="${3:-}" ans
    while true; do
        read -rp "${prompt}${def:+ [$def]}: " ans
        ans="${ans:-$def}"
        # 10# = base 10, so "08" isn't read as (invalid) octal.
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( 10#$ans >= 1 && 10#$ans <= max )); then
            PICK=$((10#$ans))
            return
        fi
        warn "Enter a number from 1 to $max."
    done
}

# Proxmox VM names must be DNS-style: letters, digits, '-' and '.'.
# (No underscores or spaces.) Checked early, so a bad name can't fail
# 'qm create' after a long download or after an old template is destroyed.
_valid_vm_name() {
    local label='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
    [[ ${#1} -le 63 && "$1" =~ ^(${label}\.)*${label}$ ]]
}

# Proxmox tags: letters, digits, '_', '-', '+', '.'. Separated by ';'.
_valid_tags() {
    local -a tags
    local t
    IFS=';, ' read -ra tags <<< "$1"
    for t in "${tags[@]}"; do
        [[ "$t" =~ ^[A-Za-z0-9_][A-Za-z0-9_+.-]*$ ]] || return 1
    done
}

# Wrap a value in double quotes, escaped, so it is safe to 'source' back in.
_conf_val() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\$/\\\$}"
    s="${s//\`/\\\`}"
    printf '"%s"' "$s"
}

# =============================================================================
#  ARGUMENTS
# =============================================================================
CONFIG_FILE=""
UNATTENDED="no"          # yes = no prompts (needs --config)
VMID_FLAG=""             # from --vmid
AUTO_VMID="no"           # yes = pick next free ID on conflict
FORCE_OVERWRITE="no"     # yes = replace existing template with same ID
I_KNOW="no"              # yes = skip overwrite confirmation (unattended)

# These CLI values must beat anything in the profile, so hold them aside.
_CLI_CONVERT_TO_TEMPLATE=""
_CLI_TEMPL_NAME=""

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

PROFILE
  --config <file>     Load a saved profile (.conf).
                      Relative paths are looked up next to this script.
  --name <name>       Set the template name. Skips that prompt.

VM ID
  --vmid <id>         Use exactly this ID. Stops if it is already taken.
  --auto-vmid         Find a free ID automatically.
                        With --vmid:    start at that ID, count upwards.
                        Without --vmid: start at 100.
                      Tip: --vmid 52000 --auto-vmid keeps templates together.

TEMPLATE
  --template          Convert to a Proxmox template at the end.
  --no-template       Leave it as a normal VM so you can customise it first.
                      Neither flag: use the profile value, or ask.

AUTOMATION
  --unattended        No prompts. Requires --config.
                      The password is generated and shown at the end.
                      Snippets are only used if SNIPPETS_STOR is in the profile.

DANGER ZONE (deletes data)
  --force-overwrite   Destroy an existing template with the same ID, then rebuild.
                      Templates only. Refuses running VMs and normal VMs.
                      Command line only. Ignored if set in a profile.
  --i-know-what-i-am-doing
                      Skip the overwrite confirmation.
                      Requires --force-overwrite AND --unattended.

  -h, --help          Show this help.

EXAMPLES
  Interactive first run:
    ./$SCRIPT_NAME

  Re-run a saved profile:
    ./$SCRIPT_NAME --config noble-webserver.conf

  Pick the ID yourself:
    ./$SCRIPT_NAME --config noble-webserver.conf --vmid 52001

  Next free ID from 52000:
    ./$SCRIPT_NAME --config noble-webserver.conf --vmid 52000 --auto-vmid

  Fully automated (cron-friendly):
    ./$SCRIPT_NAME --config noble-webserver.conf --unattended \\
        --vmid 52000 --auto-vmid --template

  Rebuild an existing template in place, no questions:
    ./$SCRIPT_NAME --config noble-webserver.conf --unattended --vmid 52001 \\
        --force-overwrite --i-know-what-i-am-doing --template
EOF
}

# Fails clearly if a flag that needs a value is missing one.
_need_arg() {
    [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 needs a value. Use --help for usage."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)        _need_arg "$@"; CONFIG_FILE="$2"; shift 2 ;;
        --name)          _need_arg "$@"; _CLI_TEMPL_NAME="$2"; shift 2 ;;
        --vmid)          _need_arg "$@"; VMID_FLAG="$2"; shift 2 ;;
        --auto-vmid)     AUTO_VMID="yes"; shift ;;
        --unattended)    UNATTENDED="yes"; shift ;;
        --force-overwrite) FORCE_OVERWRITE="yes"; shift ;;
        --i-know-what-i-am-doing) I_KNOW="yes"; shift ;;
        --template)      _CLI_CONVERT_TO_TEMPLATE="yes"; shift ;;
        --no-template)   _CLI_CONVERT_TO_TEMPLATE="no"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "Unknown argument: $1. Use --help for usage." ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Run this script as root."

# --- Load the profile ---
if [[ -n "$CONFIG_FILE" ]]; then
    [[ "$CONFIG_FILE" != /* ]] && CONFIG_FILE="$SCRIPT_DIR/$CONFIG_FILE"
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
    info "Loading config from: $CONFIG_FILE"

    # Safety flags are CLI-only. Snapshot them so a profile can't change them.
    _safe_flags="$UNATTENDED|$AUTO_VMID|$FORCE_OVERWRITE|$I_KNOW|$VMID_FLAG|$CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    IFS='|' read -r UNATTENDED AUTO_VMID FORCE_OVERWRITE I_KNOW VMID_FLAG CONFIG_FILE <<< "$_safe_flags"
    unset _safe_flags
fi

# --- Flag sanity checks ---
[[ "$UNATTENDED" == "yes" && -z "$CONFIG_FILE" ]] \
    && die "--unattended requires --config <file>. There are no saved values to run from."

[[ "$I_KNOW" == "yes" && ( "$FORCE_OVERWRITE" != "yes" || "$UNATTENDED" != "yes" ) ]] \
    && die "--i-know-what-i-am-doing requires both --force-overwrite and --unattended."

[[ "$AUTO_VMID" == "yes" && "$FORCE_OVERWRITE" == "yes" ]] \
    && die "--auto-vmid and --force-overwrite are mutually exclusive. Choose one."

[[ -n "$VMID_FLAG" && ! "$VMID_FLAG" =~ ^[1-9][0-9]{2,8}$ ]] \
    && die "--vmid must be a number from 100 to 999999999."

[[ -n "$_CLI_TEMPL_NAME" ]] && ! _valid_vm_name "$_CLI_TEMPL_NAME" \
    && die "Invalid --name '$_CLI_TEMPL_NAME'. Use letters, digits, '-' and '.' only."

# CLI beats profile.
CONVERT_TO_TEMPLATE="${_CLI_CONVERT_TO_TEMPLATE:-${CONVERT_TO_TEMPLATE:-}}"
[[ -n "$_CLI_TEMPL_NAME" ]] && TEMPL_NAME="$_CLI_TEMPL_NAME"
[[ -n "$VMID_FLAG"       ]] && VMID="$VMID_FLAG"

# =============================================================================
#  FAILURE HANDLING
#  On any failure or Ctrl+C: remove the half-built VM and temp files.
#  The cached pristine image is kept so a retry is fast.
# =============================================================================
VMID_CREATED=""          # set once 'qm create' succeeds
WORK_STARTED="no"        # set once files are written to WORK_DIR
LAST_ERR_LINE=""
TEMPLATE_CONVERTED="no"
PASSWORD_GENERATED="no"

on_exit() {
    local rc=$?
    trap - EXIT ERR INT TERM
    (( rc == 0 )) && return 0

    [[ -n "$LAST_ERR_LINE" ]] && error "Command failed at line $LAST_ERR_LINE (exit code $rc)."
    _destroy_partial_vm
    [[ "$WORK_STARTED" == "yes" ]] && cleanup failed
    exit "$rc"
}

_destroy_partial_vm() {
    [[ -n "$VMID_CREATED" ]] || return 0
    vmid_exists "$VMID_CREATED" || return 0
    warn "Removing partially built VM ${VMID_CREATED}..."
    qm destroy "$VMID_CREATED" --destroy-unreferenced-disks 1 --purge 1 &>/dev/null || true
    warn "VM ${VMID_CREATED} removed."
}

trap 'LAST_ERR_LINE=$LINENO' ERR
trap on_exit EXIT
trap 'echo; warn "Interrupted."; exit 130' INT TERM

# =============================================================================
#  PREFLIGHT
# =============================================================================
proxmox_check() {
    header "System Check"
    command -v pveversion &>/dev/null && pveversion &>/dev/null \
        || die "This script must be run on a Proxmox VE host."
    success "Proxmox VE detected: $(pveversion | cut -d/ -f2)"
}

install_packages() {
    header "Package Check"
    local missing=() pkg
    for pkg in "${REQUIRED_PKGS[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed" \
            || missing+=("$pkg")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        success "All required packages are installed."
        return
    fi

    warn "Missing packages: ${missing[*]}"
    if [[ "$UNATTENDED" == "yes" ]]; then
        info "Unattended mode: installing automatically."
    else
        read -rp "Install them now? (Y/n): " choice
        [[ "${choice:-Y}" =~ ^[Yy]$ ]] || die "Required packages not installed. Aborting."
    fi
    apt-get update -qq
    apt-get install -y "${missing[@]}"
    success "Packages installed: ${missing[*]}"
}

# =============================================================================
#  UBUNTU VERSION
#  The list is read live from cloud-images.ubuntu.com, so new releases
#  appear without editing this script.
# =============================================================================
# Codename -> version number and support status, e.g.
#   RELEASE_VER[noble]="24.04 LTS"   RELEASE_STATUS[noble]=""
#   RELEASE_VER[focal]="20.04 LTS"   RELEASE_STATUS[focal]="end of life"
# Read from Ubuntu's release lists (the same ones do-release-upgrade uses).
# Optional: if they can't be fetched, only codenames are shown.
declare -A RELEASE_VER=() RELEASE_STATUS=()

_load_release_info() {
    local dist ver status
    while IFS='|' read -r dist ver status; do
        [[ -n "$dist" && -n "$ver" ]] || continue
        RELEASE_VER["$dist"]="$ver"
        RELEASE_STATUS["$dist"]="$status"
    done < <(
        {
            wget -qO- --timeout=10 "https://changelogs.ubuntu.com/meta-release" || true
            echo "Source: development"
            wget -qO- --timeout=10 "https://changelogs.ubuntu.com/meta-release-development" || true
        } | awk -v now="$(date +%Y%m)" '
            # Records are blank-line separated. First entry per codename wins,
            # and the released list is read before the development one.
            function flush() {
                if (dist != "" && ver != "" && !(dist in seen)) {
                    split(ver, p, ".")                  # 24.04.5 -> 24.04
                    status = dev ? "in development" : (sup == "0" ? "end of life" : "")
                    # Ubuntu lists old LTS releases as supported because of paid
                    # ESM. Free support lasts 5 years, to the end of May.
                    if (status == "" && lts && now > (2000 + p[1] + 5) * 100 + 5)
                        status = "Ubuntu Pro only"
                    print dist "|" p[1] "." p[2] (lts ? " LTS" : "") "|" status
                    seen[dist] = 1
                }
                dist = ""; ver = ""; sup = ""; lts = 0
            }
            /^Source: development/ { flush(); dev = 1; next }
            /^Dist: /      { dist = $2 }
            /^Version: /   { ver = $2; lts = ($3 == "LTS") }
            /^Supported: / { sup = $2 }
            /^[[:space:]]*$/ { flush() }
            END { flush() }'
    )
}

select_ubuntu_version() {
    header "Ubuntu Version Selection"

    _load_release_info

    if [[ -n "${DISTRO_VER:-}" ]]; then
        [[ "$DISTRO_VER" =~ ^[a-z]+$ ]] || die "Invalid DISTRO_VER in config: '$DISTRO_VER'"
        info "Using distro from config: $DISTRO_VER"
        _set_distro_vars "$DISTRO_VER"
        return
    fi

    info "Fetching available Ubuntu Cloud Image versions..."

    # Every codename folder is checked for a current amd64 image.
    # Checks run 8 at a time; doing them one by one is slow.
    local codenames=()
    mapfile -t codenames < <(
        wget -qO- "https://cloud-images.ubuntu.com/" \
        | grep -oP 'href="\K[a-z]+(?=/")' \
        | sort -u \
        | xargs -r -P 8 -n 1 sh -c \
            'wget -q --spider "https://cloud-images.ubuntu.com/$1/current/$1-server-cloudimg-amd64.img" && echo "$1"' _
    ) || true

    [[ ${#codenames[@]} -gt 0 ]] \
        || die "Could not fetch Ubuntu versions from cloud-images.ubuntu.com. Check your internet connection."

    # Oldest to newest by version number. Unknown versions go last.
    local version_list=() c
    mapfile -t version_list < <(
        for c in "${codenames[@]}"; do
            printf '%s %s\n' "${RELEASE_VER[$c]:-99.99}" "$c"
        done | sort -V | awk '{print $NF}'
    )

    echo ""
    echo "Available Ubuntu versions:"
    local i note
    for i in "${!version_list[@]}"; do
        c="${version_list[$i]}"
        note="${RELEASE_STATUS[$c]:-}"
        printf "  %d) %-10s %-10s %s\n" "$((i + 1))" "$c" "${RELEASE_VER[$c]:-}" "${note:+($note)}"
    done
    echo ""

    # Accepts a number or a codename.
    local selected="" choice v
    while [[ -z "$selected" ]]; do
        read -rp "Select a version (number or codename): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#version_list[@]} )); then
            selected="${version_list[$((10#$choice - 1))]}"
        else
            for v in "${version_list[@]}"; do
                [[ "$v" == "$choice" ]] && selected="$v" && break
            done
        fi
        [[ -z "$selected" ]] && warn "Invalid selection. Try again."
    done

    _set_distro_vars "$selected"
}

_set_distro_vars() {
    DISTRO_VER="$1"
    DISK_IMAGE="${DISTRO_VER}-server-cloudimg-amd64.img"
    IMAGE_URL="https://cloud-images.ubuntu.com/${DISTRO_VER}/current/${DISK_IMAGE}"
    CHECKSUM_URL="https://cloud-images.ubuntu.com/${DISTRO_VER}/current/SHA256SUMS"
    # Keep a template name loaded from a profile.
    TEMPL_NAME_DEFAULT="${TEMPL_NAME_DEFAULT:-ubuntu-${DISTRO_VER}-cloud-template}"
    # e.g. "Ubuntu 24.04 LTS (Noble)", or "Ubuntu Noble" if the version is unknown.
    local ver="${RELEASE_VER[$DISTRO_VER]:-}"
    OS_NAME="Ubuntu ${ver:+$ver (}${DISTRO_VER^}${ver:+)}"
    success "Selected: $OS_NAME"
    [[ "${RELEASE_STATUS[$DISTRO_VER]:-}" == "end of life" ]] \
        && warn "$OS_NAME is end of life and no longer gets security updates."
    [[ "${RELEASE_STATUS[$DISTRO_VER]:-}" == "Ubuntu Pro only" ]] \
        && warn "$OS_NAME only gets security updates with an Ubuntu Pro subscription."
    [[ "${RELEASE_STATUS[$DISTRO_VER]:-}" == "in development" ]] \
        && warn "$OS_NAME is a development release. Expect breakage."
    return 0
}

# =============================================================================
#  STORAGE
#  Only storages that can hold VM disks ('images' content) are offered.
#  The disk format is picked from the storage type:
#    Block storage (ZFS, LVM, Ceph, BTRFS) -> raw
#    File storage (dir, NFS, CIFS)          -> qcow2
# =============================================================================
_resolve_storage_type() {
    STORAGE_TYPE="$1"
    case "$STORAGE_TYPE" in
        zfspool|zfs|lvmthin|lvm|rbd|btrfs)
            STORAGE_FORMAT="raw" ;;
        dir|nfs|cifs|glusterfs)
            STORAGE_FORMAT="qcow2" ;;
        *)
            warn "Unknown storage type '$STORAGE_TYPE'. Letting Proxmox choose the format."
            STORAGE_FORMAT="" ;;
    esac
}

# Lists active storages that accept VM disks as "name type" lines.
# Plain iSCSI is left out: it only exposes existing LUNs and cannot create
# new disks. (Put LVM on top of the iSCSI LUN to use it here.)
_image_storages() {
    pvesm status --content images 2>/dev/null \
        | awk 'NR>1 && $3=="active" && $2!="iscsi" && $2!="iscsidirect" {print $1, $2}'
}

select_storage() {
    header "Storage Selection"
    echo "  This is where your VM template will be stored on Proxmox."
    echo ""

    local name type
    local storages=() types=()
    while read -r name type; do
        storages+=("$name")
        types+=("$type")
    done < <(_image_storages)

    [[ ${#storages[@]} -gt 0 ]] || die "No active storage pools that accept VM disks were found."

    # Profile value: use it if it is still valid.
    if [[ -n "${DISK_STOR:-}" ]]; then
        local idx
        for idx in "${!storages[@]}"; do
            if [[ "${storages[$idx]}" == "$DISK_STOR" ]]; then
                _resolve_storage_type "${types[$idx]}"
                success "Using storage from config: $DISK_STOR ($STORAGE_TYPE / ${STORAGE_FORMAT:-auto})"
                return
            fi
        done
        [[ "$UNATTENDED" == "yes" ]] \
            && die "Configured storage '$DISK_STOR' is missing, inactive or cannot hold VM disks."
        warn "Configured storage '$DISK_STOR' is missing, inactive or cannot hold VM disks."
        warn "Choose another below."
    fi

    local default_num=1 idx
    for idx in "${!storages[@]}"; do
        printf "  %d) %-20s %s\n" "$((idx + 1))" "${storages[$idx]}" "${types[$idx]}"
        [[ "${storages[$idx]}" == "$DISK_STOR_DEFAULT" ]] && default_num=$((idx + 1))
    done
    echo ""

    _read_index "Select storage pool" "${#storages[@]}" "$default_num"
    DISK_STOR="${storages[$((PICK - 1))]}"
    _resolve_storage_type "${types[$((PICK - 1))]}"
    success "Template will be stored on: $DISK_STOR ($STORAGE_TYPE / ${STORAGE_FORMAT:-auto})"
}

# =============================================================================
#  VM ID HELPERS
#  /etc/pve/.vmlist covers the whole cluster, VMs AND containers.
#  ('qm list' only shows VMs on this node, so it misses clashes.)
# =============================================================================
vmid_exists() {
    if [[ -r /etc/pve/.vmlist ]]; then
        grep -q "\"${1}\":" /etc/pve/.vmlist
    else
        qm status "$1" &>/dev/null
    fi
}

# Config path for a VM on THIS node. Overwrite only works on local VMs.
_local_vm_conf() { echo "/etc/pve/qemu-server/${1}.conf"; }

# True if the VM is a template. Reads only the main section, not snapshots.
vmid_is_template() {
    local conf
    conf="$(_local_vm_conf "$1")"
    [[ -f "$conf" ]] && sed '/^\[/q' "$conf" | grep -q '^template: 1'
}

vmid_is_running() {
    qm status "$1" 2>/dev/null | grep -q "^status: running"
}

# VM name, for warnings. Looks across all cluster nodes.
vmid_name() {
    sed -n 's/^name: //p' /etc/pve/nodes/*/qemu-server/"${1}".conf 2>/dev/null | head -1
}

next_free_vmid() {
    local id="$1"
    while vmid_exists "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

# --force-overwrite is split in two steps, so the old template survives
# if you cancel at the summary or the download/customise step fails:
#   1. _check_overwrite     early: safety checks + your confirmation
#   2. replace_old_template late:  re-check, countdown, destroy
OVERWRITE_VMID=""

# Dies unless the VM is a stopped template on this node.
_assert_overwritable() {
    local id="$1"
    [[ -f "$(_local_vm_conf "$id")" ]] \
        || die "ID $id belongs to a container or a VM on another node. --force-overwrite only replaces VM templates on this node."
    vmid_is_running "$id" \
        && die "VM $id is running. Stop it before overwriting."
    vmid_is_template "$id" \
        || die "VM $id ('$(vmid_name "$id")') is not a template. --force-overwrite only replaces templates, to protect normal VMs."
    return 0
}

_check_overwrite() {
    local id="$1" name
    _assert_overwritable "$id"
    name="$(vmid_name "$id")"

    echo ""
    warn "OVERWRITE REQUESTED"
    warn "VM $id ('${name}') and all its disks will be destroyed and rebuilt."
    warn "This happens after the new image is ready. It cannot be undone."
    echo ""

    if [[ "$UNATTENDED" == "yes" ]]; then
        # Earlier checks guarantee I_KNOW=yes here; re-check anyway.
        [[ "$I_KNOW" == "yes" ]] || die "Unattended overwrite requires --i-know-what-i-am-doing."
        info "Confirmed via --i-know-what-i-am-doing."
    else
        # Unnamed VMs are confirmed by ID, so an empty Enter can never match.
        local expected="${name:-$id}" what="name"
        [[ -z "$name" ]] && what="ID"
        echo "  VM ID:   $id"
        echo "  VM name: ${name:-(none)}"
        echo ""
        read -rp "  Type the VM ${what} to confirm destruction: " confirm
        [[ "$confirm" == "$expected" ]] || die "The ${what} did not match. Aborting overwrite."
    fi
    OVERWRITE_VMID="$id"
}

# Runs just before create_vm. The VM may have changed in the meantime,
# so every safety check runs again.
replace_old_template() {
    [[ -n "$OVERWRITE_VMID" ]] || return 0
    header "Replace Existing Template"

    if ! vmid_exists "$OVERWRITE_VMID"; then
        info "VM $OVERWRITE_VMID no longer exists. Nothing to destroy."
        return
    fi
    _assert_overwritable "$OVERWRITE_VMID"

    warn "Destroying VM $OVERWRITE_VMID. Press Ctrl+C to abort."
    _countdown "Destroying"
    qm destroy "$OVERWRITE_VMID" --destroy-unreferenced-disks 1 --purge 1
    success "VM $OVERWRITE_VMID destroyed."
}

get_valid_vmid() {
    # --auto-vmid alone: next free from 100.
    if [[ "$AUTO_VMID" == "yes" && -z "$VMID_FLAG" ]]; then
        VMID="$(next_free_vmid 100)"
        success "Auto-selected next free VM ID: $VMID"
        return
    fi

    # From --vmid, else the default, else ask.
    if [[ -z "${VMID:-}" ]]; then
        if [[ "$UNATTENDED" == "yes" ]]; then
            VMID="$VMID_DEFAULT"
        else
            read -rp "Enter VM ID [${VMID_DEFAULT}]: " input
            VMID="${input:-$VMID_DEFAULT}"
        fi
    fi

    # Interactive: keep asking until the ID is valid and free.
    # (Unattended conflicts are handled below and never loop.)
    while true; do
        if [[ ! "$VMID" =~ ^[1-9][0-9]{2,8}$ ]]; then
            [[ "$UNATTENDED" == "yes" ]] && die "Invalid VM ID: '$VMID'."
            warn "VM ID must be a number from 100 to 999999999."
        elif ! vmid_exists "$VMID"; then
            break
        elif [[ "$FORCE_OVERWRITE" == "yes" ]]; then
            # Confirm now; the actual destroy waits until the image is ready.
            _check_overwrite "$VMID"
            break
        elif [[ "$AUTO_VMID" == "yes" ]]; then
            local original="$VMID"
            VMID="$(next_free_vmid "$VMID")"
            warn "VM ID $original is taken. Using the next free ID: $VMID"
            break
        elif [[ "$UNATTENDED" == "yes" ]]; then
            die "VM ID $VMID already exists. Re-run with one of:
  --vmid <id>          a different ID
  --auto-vmid          the next free ID
  --force-overwrite    replace the existing template (templates only)"
        else
            warn "VM ID $VMID already exists."
        fi
        read -rp "Enter a different VM ID: " VMID
    done

    success "VM ID: $VMID"
}

# =============================================================================
#  SSH KEY
#  Ways to provide a key:
#    1. Paste it   2. Path to a .pub file   3. Pick from ~/.ssh/
#    4. Fetch from GitHub by username       5. Skip
#  Multiple keys (one per line) are supported.
#
#  Every key is checked with ssh-keygen. This stops a private key from
#  being saved to the profile or pushed into VMs by mistake.
#
#  GitHub removes key comments, so you are offered the chance to add one.
#  (Without a comment the key shows blank in the Proxmox UI.)
# =============================================================================

# Returns 0 if every non-blank line is a valid public key.
_valid_pubkeys() {
    local keys="$1" line
    [[ "$keys" == *"PRIVATE KEY"* ]] && return 1
    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if command -v ssh-keygen &>/dev/null; then
            ssh-keygen -l -f - <<< "$line" &>/dev/null || return 1
        else
            [[ "$line" =~ ^(ssh-|ecdsa-|sk-) ]] || return 1
        fi
    done <<< "$keys"
}

# Validates keys, adds a comment where missing, then sets SSH_KEY.
# Usage: _accept_ssh_key "<key text>" "<where it came from>"
_accept_ssh_key() {
    local keys="$1" source="$2" line comment="" needs_comment="no" out=""
    local -a fields

    # Drop blank lines and Windows line endings.
    keys="$(tr -d '\r' <<< "$keys" | sed '/^[[:space:]]*$/d')"

    if [[ -z "$keys" ]]; then
        warn "No key found. SSH key will not be set."
        SSH_KEY=""
        return
    fi
    if ! _valid_pubkeys "$keys"; then
        warn "That is not a valid SSH PUBLIC key. SSH key will not be set."
        [[ "$keys" == *"PRIVATE KEY"* ]] && warn "It looks like a PRIVATE key. Never share that one."
        SSH_KEY=""
        return
    fi

    while IFS= read -r line; do
        read -ra fields <<< "$line"
        (( ${#fields[@]} < 3 )) && needs_comment="yes"
    done <<< "$keys"

    if [[ "$needs_comment" == "yes" ]]; then
        echo ""
        info "Key has no comment. Proxmox would show it blank in the UI."
        read -rp "  Add a comment (e.g. hostname or purpose; blank to skip): " comment
    fi

    while IFS= read -r line; do
        read -ra fields <<< "$line"
        if (( ${#fields[@]} < 3 )) && [[ -n "$comment" ]]; then
            line="$line $comment"
        fi
        out+="${out:+$'\n'}$line"
    done <<< "$keys"

    SSH_KEY="$out"
    local count
    count="$(wc -l <<< "$SSH_KEY")"
    success "SSH key set from $source ($count key$([[ $count -gt 1 ]] && echo s))."
}

_prompt_ssh_key() {
    header "SSH Key"

    # Key already loaded from profile: keep, replace or clear.
    if [[ -n "${SSH_KEY:-}" ]]; then
        echo "  A key is already set (from config):"
        echo "  ${SSH_KEY:0:72}..."
        echo ""
        echo "  1) Keep this key"
        echo "  2) Replace it"
        echo "  3) Clear it (no SSH key)"
        echo ""
        _read_index "Choice" 3 1
        case "$PICK" in
            1) return ;;
            3) SSH_KEY=""; info "SSH key cleared."; return ;;
        esac
    fi

    echo "  How would you like to provide an SSH public key?"
    echo ""
    echo "  1) Paste the public key now"
    echo "  2) Enter a path to a .pub file"
    echo "  3) Choose from keys in ~/.ssh/ on this host"
    echo "  4) Fetch from GitHub (by username)"
    echo "  5) Skip: no SSH key"
    echo ""
    _read_index "Choice" 5 1

    case "$PICK" in
        1)
            read -rp "Paste your public key: " input
            _accept_ssh_key "$input" "pasted input"
            ;;
        2)
            read -rp "Path to .pub file: " pub_path
            pub_path="${pub_path/#\~/$HOME}"
            if [[ -f "$pub_path" ]]; then
                _accept_ssh_key "$(cat "$pub_path")" "$pub_path"
            else
                warn "File not found: $pub_path. SSH key will not be set."
                SSH_KEY=""
            fi
            ;;
        3)
            local pub_files=() i
            mapfile -t pub_files < <(find "$HOME/.ssh" -maxdepth 1 -name "*.pub" 2>/dev/null | sort)
            if [[ ${#pub_files[@]} -eq 0 ]]; then
                warn "No .pub files found in $HOME/.ssh/. SSH key will not be set."
                SSH_KEY=""
                return
            fi
            echo ""
            echo "  Available keys:"
            for i in "${!pub_files[@]}"; do
                printf "  %d) %s\n" "$((i + 1))" "${pub_files[$i]}"
            done
            echo ""
            _read_index "Select key" "${#pub_files[@]}"
            _accept_ssh_key "$(cat "${pub_files[$((PICK - 1))]}")" "${pub_files[$((PICK - 1))]}"
            ;;
        4)
            read -rp "GitHub username: " gh_user
            if [[ ! "$gh_user" =~ ^[A-Za-z0-9-]+$ ]]; then
                warn "Invalid GitHub username. SSH key will not be set."
                SSH_KEY=""
            else
                info "Fetching keys from github.com/${gh_user}..."
                _accept_ssh_key "$(wget -qO- "https://github.com/${gh_user}.keys" 2>/dev/null || true)" \
                    "GitHub user $gh_user"
            fi
            ;;
        5)
            SSH_KEY=""
            info "No SSH key will be set. You can add one to clones later."
            ;;
    esac
}

# =============================================================================
#  CLOUD-INIT SNIPPET (optional)
#  A small YAML file attached as cloud-init *vendor-data*.
#  Every clone runs it on first boot.
#
#  Why vendor-data and not user-data?
#    Custom user-data REPLACES what Proxmox generates, so clones would lose
#    the user, password, SSH keys and hostname set in the Cloud-Init tab.
#    Vendor-data is merged in, so those all keep working.
#
#  Needs a storage with the 'Snippets' content type enabled.
# =============================================================================
SNIPPETS_ENABLED="no"
SNIPPETS_STOR="${SNIPPETS_STOR:-}"
SNIPPETS_FILE=""

_snippet_storages() {
    pvesm status --content snippets 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}'
}

_prompt_snippets() {
    # Unattended: only use snippets if the profile names a storage.
    if [[ "$UNATTENDED" == "yes" ]]; then
        if [[ -n "$SNIPPETS_STOR" ]]; then
            info "Unattended mode: using snippet storage from config: $SNIPPETS_STOR"
            SNIPPETS_ENABLED="yes"
            SNIPPETS_FILE="${TEMPL_NAME}-vendor-data.yaml"
        else
            info "Unattended mode: no snippet storage configured, skipping."
        fi
        return
    fi

    header "Cloud-Init Snippet (optional)"

    local snippet_stores=()
    mapfile -t snippet_stores < <(_snippet_storages)

    if [[ ${#snippet_stores[@]} -eq 0 ]]; then
        info "No storage has the 'Snippets' content type enabled. Skipping."
        info "To use this: Datacenter > Storage > Edit > Content > tick 'Snippets'."
        return
    fi

    echo "  A snippet is a file for your own first-boot settings on every clone"
    echo "  (e.g. extra packages or commands). It starts with examples to edit."
    if [[ -z "${SSH_KEY:-}" ]]; then
        echo "  It will also allow SSH login with a password, because you set no"
        echo "  SSH key and Ubuntu cloud images only allow key login by default."
    fi
    echo ""
    echo "  Not needed for SSH keys, disk resizing or package upgrades:"
    echo "  Proxmox and cloud-init already handle those."
    echo ""
    read -rp "Create a snippet? (y/N): " choice
    if [[ ! "${choice:-N}" =~ ^[Yy]$ ]]; then
        # Forget any profile value too, so unattended runs respect this "no".
        SNIPPETS_STOR=""
        return
    fi

    if [[ ${#snippet_stores[@]} -eq 1 ]]; then
        SNIPPETS_STOR="${snippet_stores[0]}"
        info "Using snippets storage: $SNIPPETS_STOR"
    else
        echo ""
        echo "  Snippet-capable storages:"
        local i
        for i in "${!snippet_stores[@]}"; do
            echo "  $((i + 1))) ${snippet_stores[$i]}"
        done
        _read_index "Select storage" "${#snippet_stores[@]}" 1
        SNIPPETS_STOR="${snippet_stores[$((PICK - 1))]}"
    fi

    SNIPPETS_ENABLED="yes"
    SNIPPETS_FILE="${TEMPL_NAME}-vendor-data.yaml"
}

apply_snippets() {
    [[ "$SNIPPETS_ENABLED" == "yes" ]] || return 0
    header "Cloud-Init Snippet"

    local volid="${SNIPPETS_STOR}:snippets/${SNIPPETS_FILE}"
    local snippet_path
    snippet_path="$(pvesm path "$volid" 2>/dev/null)" || true

    if [[ -z "$snippet_path" ]]; then
        warn "Could not find the snippets folder for '$SNIPPETS_STOR'. Skipping."
        SNIPPETS_ENABLED="no"
        return
    fi
    mkdir -p "$(dirname "$snippet_path")"

    # Never overwrite a snippet the user may have edited.
    if [[ -f "$snippet_path" ]]; then
        info "Snippet already exists, keeping your version: $snippet_path"
        info "(Delete it and re-run to regenerate.)"
    else
        # Password login over SSH: only switched on when no SSH key was set.
        local pwauth="# ssh_pwauth: true"
        [[ -z "${SSH_KEY:-}" ]] && pwauth="ssh_pwauth: true"

        cat > "$snippet_path" <<EOF
#cloud-config
# Cloud-init VENDOR-DATA for: ${TEMPL_NAME}
# Generated by ${SCRIPT_NAME} on $(date '+%Y-%m-%d %H:%M')
#
# Runs on first boot of every clone.
# Merged with the Proxmox Cloud-Init tab (user, password, SSH keys, hostname).
# If both set the same thing, the Cloud-Init tab wins.
#
# Examples: https://cloudinit.readthedocs.io/en/latest/reference/examples.html

# Not needed here (Proxmox / cloud-init already do these):
#   - SSH keys: Cloud-Init tab.
#   - Package upgrades: Cloud-Init tab > "Upgrade packages".
#   - Growing the root disk: runs on every boot, so later resizes work too.

# SSH login with a password. Ubuntu cloud images allow key login only.
# On only if no SSH key was set when this file was made.
${pwauth}

# Extra packages on first boot. Uncomment and add as needed.
# packages:
#   - curl
#   - git
#   - vim

# Commands to run once, on first boot. Uncomment and add as needed.
# runcmd:
#   - echo "hello from first boot" > /root/first-boot.txt

# Logged to /var/log/cloud-init-output.log when done.
final_message: |
  Cloud-init finished for ${TEMPL_NAME}.
  Up \$UPTIME seconds. Version: \$VERSION. Datasource: \$DATASOURCE.
EOF
        success "Snippet written to: $snippet_path"
    fi

    qm set "$VMID" --cicustom "vendor=${volid}" >/dev/null
    success "Snippet attached to VM $VMID as vendor-data."
    info "Edit it at any time: $snippet_path"
}

# =============================================================================
#  REMAINING QUESTIONS
#  Tip: at any prompt showing [a value], press Enter to keep it.
# =============================================================================

# Reads a password twice, hidden. Blank = use the generated one.
_prompt_password() {
    local p1 p2
    while true; do
        read -rsp "Cloud-Init password [Enter = auto-generate]: " p1; echo
        if [[ -z "$p1" ]]; then
            CLOUD_PASSWORD="$CLOUD_PASSWORD_DEFAULT"
            PASSWORD_GENERATED="yes"
            info "Generated password: $CLOUD_PASSWORD  (also shown at the end)"
            return
        fi
        read -rsp "Confirm password: " p2; echo
        if [[ "$p1" == "$p2" ]]; then
            CLOUD_PASSWORD="$p1"
            return
        fi
        warn "Passwords did not match. Try again."
    done
}

user_prompts() {
    # Unattended: everything comes from the profile. Password is generated.
    if [[ "$UNATTENDED" == "yes" ]]; then
        TEMPL_NAME="${TEMPL_NAME:-$TEMPL_NAME_DEFAULT}"
        _valid_vm_name "$TEMPL_NAME" \
            || die "Invalid template name '$TEMPL_NAME'. Use letters, digits, '-' and '.' only."
        _valid_tags "$TAG" \
            || die "Invalid tags '$TAG'. Use letters, digits, '_', '-', '+', '.', separated by ';'."
        [[ "$CI_UPGRADE" =~ ^[01]$ ]] \
            || die "Invalid CI_UPGRADE '$CI_UPGRADE' in config. Use 1 (yes) or 0 (no)."
        CLOUD_USER="${CLOUD_USER_DEFAULT}"
        CLOUD_PASSWORD="${CLOUD_PASSWORD_DEFAULT}"
        PASSWORD_GENERATED="yes"
        info "Unattended mode: using all values from config."
        info "Cloud-Init password will be generated and shown at the end."
        _prompt_snippets
        return
    fi

    header "Template Configuration"
    echo "  Press Enter to accept the value in [brackets]."
    echo ""

    # --- Name ---
    if [[ -z "${TEMPL_NAME:-}" ]]; then
        while true; do
            read -rp "Template name [${TEMPL_NAME_DEFAULT}]: " input
            TEMPL_NAME="${input:-$TEMPL_NAME_DEFAULT}"
            _valid_vm_name "$TEMPL_NAME" && break
            warn "Use letters, digits, '-' and '.' only (no spaces or underscores)."
        done
    else
        _valid_vm_name "$TEMPL_NAME" \
            || die "Invalid --name '$TEMPL_NAME'. Use letters, digits, '-' and '.' only."
        info "Using template name from --name flag: $TEMPL_NAME"
    fi

    # --- Login ---
    read -rp "Cloud-Init username [${CLOUD_USER_DEFAULT}]: " input
    CLOUD_USER="${input:-$CLOUD_USER_DEFAULT}"
    _prompt_password

    _prompt_ssh_key

    # --- Packages ---
    echo ""
    echo "Extra packages, comma separated (e.g. curl,git). Enter '-' for none."
    read -rp "Extra packages [${EXTRA_VIRT_PKGS:-none}]: " input
    [[ "$input" == "-" ]] && EXTRA_VIRT_PKGS="" || EXTRA_VIRT_PKGS="${input:-$EXTRA_VIRT_PKGS}"
    EXTRA_VIRT_PKGS="${EXTRA_VIRT_PKGS// /}"

    # --- VLAN ---
    echo ""
    while true; do
        read -rp "VLAN tag, 1-4094 ('-' for none) [${VLAN:-none}]: " input
        [[ "$input" == "-" ]] && { VLAN=""; break; }
        input="${input:-$VLAN}"
        if [[ -z "$input" ]]; then
            VLAN=""
            break
        fi
        if [[ "$input" =~ ^[0-9]+$ ]] && (( 10#$input >= 1 && 10#$input <= 4094 )); then
            VLAN=$((10#$input))
            break
        fi
        warn "VLAN must be a number from 1 to 4094."
    done

    # --- Disk size ---
    echo ""
    local disk_default_num="${DISK_SIZE//[^0-9]/}"
    while true; do
        read -rp "Disk size in GB, numbers only [${disk_default_num}]: " input
        input="${input//[^0-9]/}"
        input="${input:-$disk_default_num}"
        [[ -n "$input" ]] && (( 10#$input >= 4 )) && break
        warn "Use at least 4 GB (the Ubuntu image itself is about 3.5 GB)."
    done
    DISK_SIZE="$((10#$input))G"
    info "Disk size set to: $DISK_SIZE"

    # --- Tags ---
    echo ""
    echo "Tags help filter VMs in the Proxmox UI. Separate with ';' (e.g. template;ubuntu)."
    while true; do
        read -rp "Tags [${TAG}]: " input
        input="${input:-$TAG}"
        if _valid_tags "$input"; then
            TAG="$input"
            break
        fi
        warn "Tags may use letters, digits, '_', '-', '+' and '.' only."
    done

    # --- CPU type ---
    echo ""
    local cpu_options=("host" "kvm64" "x86-64-v2-AES" "x86-64-v3")
    local cpu_descriptions=(
        "Fastest. Best for most homelabs."
        "Most compatible. For live migration between different CPUs."
        "Compatible with most modern CPUs, more features than kvm64."
        "Modern CPUs only (Haswell / Zen 1 or newer)."
    )
    echo "CPU type:"
    local default_cpu_num=1 idx marker
    for idx in "${!cpu_options[@]}"; do
        marker=""
        if [[ "${cpu_options[$idx]}" == "$CPU_TYPE" ]]; then
            marker=" *"
            default_cpu_num=$((idx + 1))
        fi
        printf "  %d) %-16s %s\n" "$((idx + 1))" "${cpu_options[$idx]}${marker}" "${cpu_descriptions[$idx]}"
    done
    echo "  (* = current)"
    echo ""
    _read_index "Select CPU type" "${#cpu_options[@]}" "$default_cpu_num"
    CPU_TYPE="${cpu_options[$((PICK - 1))]}"
    info "CPU type set to: $CPU_TYPE"

    # --- Package upgrades on first boot (Proxmox "Upgrade packages") ---
    echo ""
    echo "Upgrade all packages when a clone first boots?"
    echo "Slower first boot, but clones start fully patched."
    local up_def="N" up_hint="y/N"
    [[ "$CI_UPGRADE" == "1" ]] && up_def="Y" && up_hint="Y/n"
    read -rp "Upgrade packages on first boot? (${up_hint}): " input
    [[ "${input:-$up_def}" =~ ^[Yy]$ ]] && CI_UPGRADE="1" || CI_UPGRADE="0"
    info "Upgrade on first boot: $([[ "$CI_UPGRADE" == "1" ]] && echo yes || echo no)"

    _prompt_snippets
}

# =============================================================================
#  IMAGE DOWNLOAD (SHA256 verified)
#  Two copies are kept in WORK_DIR:
#    <image>.pristine  Exactly as downloaded. Cached between runs.
#    <image>           Working copy. Customised, imported, then deleted.
#
#  Each run:
#    No cache                  -> download, verify, cache it.
#    Cache matches upstream    -> reuse it. No download.
#    Cache differs (new image) -> re-download (or ask, if interactive).
# =============================================================================
download_image() {
    header "Image Download"
    mkdir -p "$WORK_DIR"
    WORK_STARTED="yes"

    local image_path="$WORK_DIR/$DISK_IMAGE"
    local pristine_path="$WORK_DIR/${DISK_IMAGE}.pristine"
    local checksum_file="$WORK_DIR/SHA256SUMS_${DISTRO_VER}"

    info "Fetching SHA256SUMS from upstream..."
    wget -qO "$checksum_file" "$CHECKSUM_URL" \
        || die "Failed to download SHA256SUMS from $CHECKSUM_URL"

    # Exact filename match. Lines look like: <hash> *<filename>
    local expected_checksum
    expected_checksum="$(awk -v f="$DISK_IMAGE" '$2==f || $2=="*"f {print $1; exit}' "$checksum_file")"
    [[ -n "$expected_checksum" ]] || die "Could not find checksum for $DISK_IMAGE in SHA256SUMS."

    if [[ -f "$pristine_path" ]]; then
        info "Cached image found. Verifying against upstream checksum..."
        if [[ "$(sha256sum "$pristine_path" | awk '{print $1}')" == "$expected_checksum" ]]; then
            success "Cached image is current. No download needed."
            _make_working_copy "$pristine_path" "$image_path"
            return
        fi

        warn "Cached image differs from upstream. Ubuntu has published a newer build."
        local redownload="1"
        if [[ "$UNATTENDED" == "yes" ]]; then
            info "Unattended mode: downloading the newer image."
        else
            echo ""
            echo "  1) Download the new image (recommended)"
            echo "  2) Keep using the cached image"
            echo ""
            _read_index "Choice" 2 1
            redownload="$PICK"
        fi

        if [[ "$redownload" == "2" ]]; then
            warn "Using the cached image. It may be out of date."
            _make_working_copy "$pristine_path" "$image_path"
            return
        fi
        rm -f "$pristine_path"
    fi

    info "Downloading $DISK_IMAGE..."
    wget -nv --show-progress -O "${pristine_path}.part" "$IMAGE_URL" \
        || { rm -f "${pristine_path}.part"; die "Image download failed."; }

    info "Verifying downloaded image..."
    local actual_checksum
    actual_checksum="$(sha256sum "${pristine_path}.part" | awk '{print $1}')"
    if [[ "$actual_checksum" != "$expected_checksum" ]]; then
        rm -f "${pristine_path}.part"
        die "Checksum verification failed!
  Expected: $expected_checksum
  Got:      $actual_checksum"
    fi
    mv "${pristine_path}.part" "$pristine_path"
    success "Image verified: $DISK_IMAGE"

    _make_working_copy "$pristine_path" "$image_path"
}

# Copy-on-write clone where the filesystem supports it (instant on ZFS/BTRFS/XFS).
_make_working_copy() {
    cp --reflink=auto "$1" "$2"
    success "Working image ready."
}

# =============================================================================
#  IMAGE CUSTOMISATION
#  One virt-customize call. Each call boots a small helper VM,
#  so doing everything at once saves time.
# =============================================================================
customize_image() {
    header "Image Customisation"
    local image_path="$WORK_DIR/$DISK_IMAGE"
    local ds_cfg="$WORK_DIR/99_pve.cfg"

    # Tell cloud-init to only look for Proxmox's datasources (faster boot).
    cat > "$ds_cfg" <<EOF
# Managed by ${SCRIPT_NAME}
# To update, run: dpkg-reconfigure cloud-init
datasource_list: [ NoCloud, ConfigDrive ]
EOF

    # Strip spaces: older profiles saved lists like "curl, git".
    local all_pkgs="$VIRT_PKGS${EXTRA_VIRT_PKGS:+,$EXTRA_VIRT_PKGS}"
    all_pkgs="${all_pkgs//[[:space:]]/}"
    local vc_args=(
        -a "$image_path"
        --update
        --install "$all_pkgs"
        --upload "${ds_cfg}:/etc/cloud/cloud.cfg.d/99_pve.cfg"
        # Installing packages can create a machine-id. Clones sharing one
        # get the same DHCP lease, so blank it; systemd makes a new one on boot.
        --run-command "truncate -s 0 /etc/machine-id"
    )

    [[ -n "${TZ:-}" ]] && vc_args+=(--timezone "$TZ")

    # First boot, because localectl needs a running system.
    if [[ "${SET_X11:-}" == "yes" ]]; then
        vc_args+=(
            --firstboot-command "localectl set-locale LANG=${LOCAL_LANG}"
            --firstboot-command "localectl set-x11-keymap ${X11_LAYOUT} ${X11_MODEL}"
        )
    fi

    info "Running virt-customize (this can take a few minutes)..."
    virt-customize "${vc_args[@]}" || die "virt-customize failed."
    success "Image customised."
}

# =============================================================================
#  VM CREATION
# =============================================================================
create_vm() {
    header "VM Creation"
    local net_opts="virtio,bridge=${NET_BRIDGE}${VLAN:+,tag=${VLAN}}"

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
        --tablet     "0" \
        --scsihw     "virtio-scsi-single" \
        --ipconfig0  "ip=dhcp" \
        --ciuser     "$CLOUD_USER" \
        --cipassword "$CLOUD_PASSWORD" \
        --ciupgrade  "$CI_UPGRADE"
    # From here on, a failure removes this VM automatically.
    VMID_CREATED="$VMID"

    # ZFS has its own cache (ARC). A host cache on top double-buffers,
    # so use cache=none there and writethrough elsewhere.
    local disk_cache="writethrough"
    [[ "$STORAGE_TYPE" == "zfspool" ]] && disk_cache="none"

    local fmt_opt=""
    [[ -n "$STORAGE_FORMAT" ]] && fmt_opt=",format=${STORAGE_FORMAT}"

    # import-from lets Proxmox name the disk itself, so there is no guessing
    # 'vm-<id>-disk-0' (which breaks if an old orphaned disk has that name).
    info "Importing disk (format: ${STORAGE_FORMAT:-auto})..."
    qm set "$VMID" \
        --scsi0    "${DISK_STOR}:0,import-from=${WORK_DIR}/${DISK_IMAGE}${fmt_opt},cache=${disk_cache},discard=on,iothread=1,ssd=1" \
        --scsi1    "${DISK_STOR}:cloudinit" \
        --efidisk0 "${DISK_STOR}:0,efitype=4m${fmt_opt},ms-cert=2023k,pre-enrolled-keys=1,size=1M" \
        --boot     "order=scsi0"

    success "VM $VMID created."
}

# Notes on the VM's Summary page in Proxmox.
# Runs after apply_snippets, so the snippet note matches what was attached.
set_vm_description() {
    qm set "$VMID" --description "$(_vm_description)" >/dev/null
}

_vm_description() {
    local upgrade_note="> **Package upgrades on first boot are off.**
> Turn on in Cloud-Init > Upgrade packages, or upgrade after cloning."
    [[ "$CI_UPGRADE" == "1" ]] && upgrade_note="> **Packages are upgraded on first boot.**
> Turn off in Cloud-Init > Upgrade packages."

    local snippet_note=""
    [[ "$SNIPPETS_ENABLED" == "yes" ]] && snippet_note="
> **First boot also runs the snippet** \`${SNIPPETS_STOR}:snippets/${SNIPPETS_FILE}\`$([[ -z "${SSH_KEY:-}" ]] && echo "
> (includes SSH password login).")"

    cat <<EOF
**OS:** ${OS_NAME}

**Template created:** $(date '+%Y-%m-%d %H:%M')

**Storage:** ${DISK_STOR} (${STORAGE_TYPE}/${STORAGE_FORMAT:-auto})

**CPU type:** ${CPU_TYPE}

**Cloud-Init user:** ${CLOUD_USER}

---

### Notes

> **SSH login:** use the SSH key from the Cloud-Init tab.
> Ubuntu cloud images allow key login only. For password login, enable
> \`ssh_pwauth\` in a cloud-init snippet, or set \`PasswordAuthentication yes\`
> in \`/etc/ssh/sshd_config\` after first boot.

${upgrade_note}
${snippet_note}

---

### Before re-templating this VM, run inside it:

\`\`\`
apt-get clean && \\
apt-get -y autoremove --purge && \\
cloud-init clean && \\
truncate -s 0 /etc/machine-id && \\
rm -f /var/lib/dbus/machine-id && \\
history -c && history -w && \\
fstrim -av && \\
shutdown now
\`\`\`
EOF
}

# =============================================================================
#  APPLY SSH KEY
# =============================================================================
apply_ssh_key() {
    [[ -n "${SSH_KEY:-}" ]] || return 0
    header "SSH Key"

    # SSH_KEY may be "github.com/<user>" instead of the key itself.
    # Fetch the current keys from GitHub on every run.
    if [[ "$SSH_KEY" == github.com/* ]]; then
        local gh_user="${SSH_KEY#github.com/}" keys
        info "Config has a GitHub reference. Fetching keys for: $gh_user"
        keys="$(wget -qO- "https://github.com/${gh_user}.keys" 2>/dev/null | tr -d '\r' || true)"
        _valid_pubkeys "$keys" && [[ -n "$keys" ]] \
            || die "Could not fetch valid keys from github.com/${gh_user}.keys."
        SSH_KEY="$keys"
    fi

    # qm wants a file, one key per line.
    qm set "$VMID" --sshkeys <(printf '%s\n' "$SSH_KEY") >/dev/null
    success "SSH key applied."
}

# =============================================================================
#  DISK RESIZE
# =============================================================================
resize_disk() {
    header "Disk Resize"
    qm resize "$VMID" scsi0 "$DISK_SIZE"
    success "Disk resized to $DISK_SIZE."
}

# =============================================================================
#  CONVERT TO TEMPLATE (optional)
#  Decided by, in order:
#    1. --template / --no-template
#    2. CONVERT_TO_TEMPLATE in the profile
#    3. Asking you (default: no, so you can customise first)
# =============================================================================
maybe_convert_to_template() {
    header "Convert to Proxmox Template"

    if [[ -z "${CONVERT_TO_TEMPLATE:-}" ]]; then
        if [[ "$UNATTENDED" == "yes" ]]; then
            CONVERT_TO_TEMPLATE="no"
        else
            echo "  A template is read-only and can only be cloned."
            echo "  Say no if you want to boot it and customise it first."
            echo ""
            read -rp "Convert VM $VMID to a template now? (y/N): " choice
            [[ "${choice:-N}" =~ ^[Yy]$ ]] && CONVERT_TO_TEMPLATE="yes" || CONVERT_TO_TEMPLATE="no"
        fi
    fi

    if [[ "$CONVERT_TO_TEMPLATE" == "yes" ]]; then
        qm template "$VMID"
        TEMPLATE_CONVERTED="yes"
        success "VM $VMID converted to template."
    else
        info "Left as a regular VM. To convert later:  qm template $VMID"
    fi
}

# =============================================================================
#  CLEANUP
#  Usage: cleanup           normal run; asks about the cached image
#         cleanup failed    after an error; keeps the cache, no questions
# =============================================================================
cleanup() {
    local mode="${1:-}"
    header "Cleanup"

    rm -f "$WORK_DIR/99_pve.cfg" "$WORK_DIR/SHA256SUMS_${DISTRO_VER:-unknown}"

    [[ -n "${DISK_IMAGE:-}" ]] || return 0

    # Working copy is single-use: always remove.
    rm -f "$WORK_DIR/$DISK_IMAGE" "$WORK_DIR/${DISK_IMAGE}.pristine.part"
    info "Temporary files removed."

    local pristine_path="$WORK_DIR/${DISK_IMAGE}.pristine"
    [[ -f "$pristine_path" ]] || return 0

    if [[ "$mode" == "failed" || "$UNATTENDED" == "yes" ]]; then
        info "Cached image kept for next time: $pristine_path"
        return
    fi

    echo ""
    echo "  Cached image: $pristine_path ($(du -sh "$pristine_path" | cut -f1))"
    echo "  Keeping it skips the download next time."
    read -rp "  Delete the cached image? (y/N): " choice
    if [[ "${choice:-N}" =~ ^[Yy]$ ]]; then
        rm -f "$pristine_path"
        success "Cached image deleted."
    else
        info "Cached image kept."
    fi
}

# =============================================================================
#  PROFILE (.conf)
#  Saved right after you confirm the summary, BEFORE any work starts.
#  So if the run fails, your answers are not lost.
#  It is saved again at the end to record the template yes/no answer.
# =============================================================================
PROFILE_NAME=""
PROFILE_PATH=""

prompt_config_name() {
    echo ""
    info "Save these answers as a profile to re-use them (or retry if this run fails)."
    read -rp "Profile name (e.g. noble-webserver, blank to skip): " profile_name
    profile_name="${profile_name// /-}"

    if [[ -z "$profile_name" ]]; then
        info "No profile will be saved."
        return
    fi
    if [[ ! "$profile_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "Use only letters, numbers, '.', '_' and '-'. Profile not saved."
        return
    fi

    local path="${SCRIPT_DIR}/${profile_name}.conf"
    if [[ -f "$path" ]]; then
        warn "A profile already exists at: $path"
        read -rp "Overwrite it? (y/N): " ow
        [[ "${ow:-N}" =~ ^[Yy]$ ]] || { info "Profile not saved."; return; }
    fi

    PROFILE_NAME="$profile_name"
    PROFILE_PATH="$path"
    write_config
}

write_config() {
    [[ -n "$PROFILE_PATH" ]] || return 0

    # umask: the profile may hold your SSH key, so keep it private to root.
    ( umask 077; cat > "$PROFILE_PATH" <<EOF
# =============================================================================
# Profile: ${PROFILE_NAME}
# Generated by ${SCRIPT_NAME} on $(date '+%Y-%m-%d %H:%M')
# Use it:  ./${SCRIPT_NAME} --config ${PROFILE_NAME}.conf
#
# Not saved on purpose:
#   - VM ID: chosen each run, to avoid clashes (use --vmid / --auto-vmid).
#   - Password: generated fresh each run, for security.
#   - Danger flags (--force-overwrite etc.): command line only.
# =============================================================================

# --- Ubuntu version (codename) ---
DISTRO_VER=$(_conf_val "$DISTRO_VER")

# --- Storage ---
# Disk format is detected from the storage type at runtime.
DISK_STOR=$(_conf_val "$DISK_STOR")

# --- VM hardware ---
VMID_DEFAULT=$(_conf_val "$VMID_DEFAULT")
CORES=$(_conf_val "$CORES")
MEM=$(_conf_val "$MEM")
BALLOON=$(_conf_val "$BALLOON")
BIOS=$(_conf_val "$BIOS")
MACHINE=$(_conf_val "$MACHINE")
CPU_TYPE=$(_conf_val "$CPU_TYPE")
DISK_SIZE=$(_conf_val "$DISK_SIZE")
OS_TYPE=$(_conf_val "$OS_TYPE")
NET_BRIDGE=$(_conf_val "$NET_BRIDGE")
VLAN=$(_conf_val "$VLAN")
AGENT_ENABLE=$(_conf_val "$AGENT_ENABLE")
FSTRIM=$(_conf_val "$FSTRIM")

# --- Upgrade packages on first boot? 1 = yes, 0 = no ---
CI_UPGRADE=$(_conf_val "$CI_UPGRADE")

# --- Cloud-init snippet ---
# Storage to write the snippet to. Empty = no snippet in unattended runs,
# and you are asked in interactive runs.
SNIPPETS_STOR=$(_conf_val "$SNIPPETS_STOR")

# --- Template identity ---
TEMPL_NAME_DEFAULT=$(_conf_val "$TEMPL_NAME")
TAG=$(_conf_val "$TAG")

# --- Cloud-init login ---
CLOUD_USER_DEFAULT=$(_conf_val "$CLOUD_USER")

# --- SSH key(s), one per line ---
# Safe to store here: this file is yours, not part of the shared script.
# Can also be "github.com/<username>" to fetch keys each run.
SSH_KEY=$(_conf_val "${SSH_KEY:-}")

# --- Packages (comma separated) ---
VIRT_PKGS=$(_conf_val "$VIRT_PKGS")
EXTRA_VIRT_PKGS=$(_conf_val "${EXTRA_VIRT_PKGS:-}")

# --- Convert to template at the end? ---
# "yes" = always, "no" = never, "" = ask each run.
# --template / --no-template override this.
CONVERT_TO_TEMPLATE=$(_conf_val "${CONVERT_TO_TEMPLATE:-}")

# --- Locale / keyboard ---
LOCAL_LANG=$(_conf_val "$LOCAL_LANG")
SET_X11=$(_conf_val "$SET_X11")
X11_LAYOUT=$(_conf_val "$X11_LAYOUT")
X11_MODEL=$(_conf_val "$X11_MODEL")
TZ=$(_conf_val "$TZ")
EOF
    )
    # umask only applies to new files; also fix profiles made by older versions.
    chmod 600 "$PROFILE_PATH"
    success "Profile saved: $PROFILE_PATH"
}

# =============================================================================
#  SUMMARY (last chance to cancel)
# =============================================================================
print_summary() {
    header "Summary: Review Before Proceeding"
    echo ""

    local ssh_display="(none)"
    [[ -n "${SSH_KEY:-}" ]] && ssh_display="(set) ${SSH_KEY:0:40}..."

    local templ_str
    case "${CONVERT_TO_TEMPLATE:-}" in
        yes) templ_str="Yes" ;;
        no)  templ_str="No" ;;
        *)   templ_str="Ask me at the end" ;;
    esac

    local cache_display="writethrough"
    [[ "$STORAGE_TYPE" == "zfspool" ]] && cache_display="none (ZFS)"

    local snippet_display="(none)"
    [[ "$SNIPPETS_ENABLED" == "yes" ]] && snippet_display="${SNIPPETS_STOR}:snippets/${SNIPPETS_FILE}"

    _row() { printf "  %-22s %s\n" "$1" "$2"; }
    _row "OS:"                  "$OS_NAME"
    _row "VM ID:"               "$VMID${OVERWRITE_VMID:+ (REPLACES the existing template)}"
    _row "Template name:"       "$TEMPL_NAME"
    _row "Storage:"             "$DISK_STOR ($STORAGE_TYPE / ${STORAGE_FORMAT:-auto}, cache=$cache_display)"
    _row "Disk size:"           "$DISK_SIZE"
    _row "CPUs / RAM:"          "$CORES cores / ${MEM}MB (balloon: ${BALLOON}MB)"
    _row "BIOS / Machine:"      "$BIOS / $MACHINE"
    _row "CPU type:"            "$CPU_TYPE"
    _row "Network:"             "$NET_BRIDGE${VLAN:+ (VLAN $VLAN)}"
    _row "Tags:"                "$TAG"
    _row "Cloud-Init user:"     "$CLOUD_USER"
    _row "SSH key:"             "$ssh_display"
    _row "Extra packages:"      "${EXTRA_VIRT_PKGS:-(none)}"
    _row "Snippet:"             "$snippet_display"
    _row "Timezone:"            "$TZ"
    _row "Upgrade on 1st boot:" "$([[ "$CI_UPGRADE" == "1" ]] && echo Yes || echo No)"
    _row "Convert to template:" "$templ_str"
    echo ""

    if [[ "$UNATTENDED" == "yes" ]]; then
        warn "Unattended mode. Press Ctrl+C to abort."
        _countdown "Starting"
        echo ""
        return
    fi

    read -rp "Proceed? (Y/n): " proceed
    if [[ "${proceed:-Y}" =~ ^[Nn]$ ]]; then
        info "Aborted by user."
        exit 0
    fi

    prompt_config_name
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    echo ""
    echo -e "${BOLD}Proxmox Ubuntu Cloud-Init Template Creator${RESET}"
    echo "=========================================="

    # 1. Checks and questions (nothing is changed yet)
    proxmox_check
    install_packages
    select_ubuntu_version
    select_storage
    get_valid_vmid
    user_prompts
    print_summary

    # 2. Build the image
    download_image
    customize_image

    # 3. Build the VM
    replace_old_template
    create_vm
    apply_ssh_key
    apply_snippets
    set_vm_description
    resize_disk
    maybe_convert_to_template

    # Build finished: from here on, nothing may remove the VM on exit.
    VMID_CREATED=""

    # 4. Tidy up
    cleanup

    if [[ -n "$PROFILE_PATH" ]]; then
        write_config
        info "Re-use with: ./${SCRIPT_NAME} --config ${PROFILE_NAME}.conf"
    fi

    # --- Done ---
    echo ""
    if [[ "$TEMPLATE_CONVERTED" == "yes" ]]; then
        success "Template '$TEMPL_NAME' (ID: $VMID) is ready to clone."
    else
        success "VM '$TEMPL_NAME' (ID: $VMID) is ready. Boot it, customise, then run: qm template $VMID"
    fi

    if [[ "$PASSWORD_GENERATED" == "yes" ]]; then
        echo ""
        warn "Login details (password was generated: save it now):"
        echo "  User:     $CLOUD_USER"
        echo "  Password: $CLOUD_PASSWORD"
        echo ""
        info "Change it later: qm set $VMID --cipassword '<new>' && qm cloudinit update $VMID"
    fi
}

main "$@"
