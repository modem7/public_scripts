#!/bin/bash
# =============================================================================
#  Proxmox LXC Creator (Ubuntu / Debian)
# =============================================================================
#
#  Author:   Alex Lane (modem7) - https://github.com/modem7
#  Licence:  MIT - Copyright (c) 2026 Alex Lane
#            Free to use, change and share. Keep this notice.
#            Provided as-is, with no warranty. Full text:
#            https://github.com/modem7/public_scripts/blob/master/LICENSE
#  Repo:     https://github.com/modem7/public_scripts
#  Latest:   https://github.com/modem7/public_scripts/blob/master/Bash/Proxmox%20Scripts/LXC%20Template/create-lxc.sh
#  Issues:   https://github.com/modem7/public_scripts/issues
#  Support:  https://www.buymeacoffee.com/modem7
#
#  SPDX-License-Identifier: MIT
#
#  WHAT IT DOES
#    Builds an Ubuntu or Debian container (LXC) on a Proxmox VE host.
#    1. Downloads the official Proxmox container template (pveam).
#    2. Creates the container and starts it.
#    3. Sets it up from the host: updates, packages, locale, time zone,
#       plus any optional features you switch on in a profile.
#    4. Either leaves it running, ready to use, or cleans it and converts
#       it to a Proxmox template you can clone (--template).
#
#  OPTIONAL FEATURES (profile only)
#    Set these in a .conf profile. See "OPTIONAL FEATURES" below.
#    ANSIBLE_USER, ADMIN_USER, ROOT_SSH_KEY, ZSH_DOTFILES, POSTFIX_RELAY,
#    UNATTENDED_UPGRADES (+ UU_*), REMOVE_SNAPD, DISABLE_IPV6,
#    PIP_BREAK_SYSTEM_PACKAGES, SUDO_COREDUMP_FIX, KEYCTL.
#    All are off by default.
#
#    Hooks, to add your own changes without editing this script:
#    UPLOAD_FILES, PROVISION_SCRIPTS
#
#  REQUIREMENTS
#    - Run as root on a Proxmox VE host.
#    - Internet access for the host (template download) and the container
#      (packages). The container needs DHCP or a static IP that can reach
#      the internet while it is being built.
#
#  QUICK START
#    First run    ./create-lxc.sh
#                 Answer the prompts. Save a profile when asked.
#
#    Re-run       ./create-lxc.sh --config <profile>.conf
#
#    By hand      cp profile.conf.example my-lxc.conf    (then edit it)
#                 The optional features can only be set by editing a profile.
#
#    Automated    ./create-lxc.sh --config my-lxc.conf \
#                     --unattended --ctid 53000 --auto-ctid --template
#
#    All options  ./create-lxc.sh --help
#
#  CONTAINER ID CHEAT SHEET
#    --ctid 53001               Use exactly 53001. Stop if taken.
#    --auto-ctid                Next free ID, starting at 100.
#    --ctid 53000 --auto-ctid   Next free ID, starting at 53000.
#
#  LOGGING IN
#    root has no password. From the host:  pct enter <id>
#    Over SSH: set ROOT_SSH_KEY, ADMIN_USER or ANSIBLE_USER in a profile.
#
#  FILES IT CREATES
#    <script dir>/<profile>.conf    Your saved answers (only if you say so).
#                                   Private to root. The mail password is
#                                   never saved: add POSTFIX_PASS yourself.
#                                   Keep profiles out of git (the .gitignore
#                                   in this folder ignores *.conf).
#    <storage>/template/cache/      The downloaded Proxmox template, reused
#                                   on later runs.
#
#  TEMPLATES AND CLONES
#    A template has no SSH host keys and no machine-id. Each clone makes
#    its own on first boot (ct-identity.service, installed by this script).
#
#  SAFETY
#    - Never destroys anything unless you pass --force-overwrite.
#    - Even then: container templates only, never normal containers or VMs.
#    - If the script fails midway, the half-built container is removed
#      (keep it for debugging with --keep-on-failure).
#    - Passwords are read from your profile only and never written to the
#      Proxmox config, the container description or the terminal.
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# =============================================================================
#  DEFAULTS
#  Edit these to change the starting values. A loaded profile overrides them.
# =============================================================================

# --- Operating system ---
# "<distro>-<version>" as Proxmox names its templates, e.g. "ubuntu-24.04",
# "debian-13". Blank = choose from a menu.
OS_TEMPLATE=""

# --- Storage ---
ROOTFS_STOR=""           # container disk. Blank = ask (unattended: the only one)
ROOTFS_STOR_DEFAULT="local-lvm"
TEMPLATE_STOR=""         # where the downloaded template is kept. Blank = "local" if it can, else the first that can

# --- Container identity ---
CT_NAME=""               # hostname. Blank = <distro>-<version>-lxc[-template]
CTID_DEFAULT="53000"
TAG="lxc"                # Proxmox tags, separated by ';'

# --- Container resources ---
CORES="1"
MEM="1024"               # MB
SWAP="512"               # MB. 0 = no swap
DISK_SIZE="8G"
UNPRIVILEGED="1"         # 1 = unprivileged (safer). 0 = privileged
NESTING="1"              # needed by systemd in current Ubuntu/Debian, and by Docker
START_ON_BOOT="0"        # 1 = start with the host. Ignored for templates

# --- Network ---
NET_BRIDGE="vmbr0"       # must exist on this host
VLAN=""                  # blank = untagged
IP="dhcp"                # "dhcp" or a static address with prefix, e.g. 192.168.1.50/24
GATEWAY=""               # needed with a static IP
NAMESERVER=""            # blank = same as the host
SEARCHDOMAIN=""          # blank = same as the host

# --- Locale / time zone ---
LOCAL_LANG="en_GB.UTF-8"
TZ="Europe/London"       # "host" = same as this host. Blank = leave as the template ships it (UTC)

# --- Packages (comma separated) ---
BASE_PKGS="auto-apt-proxy,aptitude,curl,htop,plocate,needrestart,pwgen,sudo,unzip,wget"
EXTRA_PKGS=""
APT_UPGRADE="yes"        # yes = upgrade every package while building

# --- Convert to a template at the end? ---
# "yes" = always, "no" = never, blank = ask (--unattended: no).
CONVERT_TO_TEMPLATE=""

# =============================================================================
#  OPTIONAL FEATURES
#  Set these in a profile: there are no prompts for them. All default to
#  off, so a profile that sets none of them gets the stock template plus
#  updates, the packages above, the locale and the time zone.
# =============================================================================

# --- Users ---
# !! Do NOT hardcode keys or passwords in this script. !! Put them in a
# profile (.conf), which is private to root and ignored by git.
# Keys are public keys, one per line. No user gets a password: logins are
# by SSH key only.

# SSH key(s) for root. Blank = root can only be reached with 'pct enter'.
ROOT_SSH_KEY=""

# Service account for Ansible: system user, bash, passwordless sudo.
# Blank = don't create it.
ANSIBLE_USER=""
ANSIBLE_SSH_KEY=""

# Your own login: member of 'sudo', passwordless sudo. Blank = don't create.
ADMIN_USER=""
ADMIN_SSH_KEY=""

# --- Shell ---
# yes = install zsh + zsh-antigen, download DOTFILES_URLS into /etc/skel
#       (so every new user gets them), and give root and ADMIN_USER zsh.
#       ANSIBLE_USER keeps bash.
ZSH_DOTFILES="no"
DOTFILES_URLS=()         # raw file URLs, saved under their own file name

# --- Mail ---
# yes = install Postfix as a send-only relay through an authenticated
#       smarthost (e.g. Gmail with an app password). Mail is sent as
#       <hostname>@MAIL_DOMAIN.
POSTFIX_RELAY="no"
POSTFIX_RELAYHOST="[smtp.gmail.com]:587"
POSTFIX_USER=""
POSTFIX_PASS=""          # profile only. Never put it in this script
MAIL_DOMAIN=""           # e.g. example.com

# --- Automatic updates ---
# yes = install unattended-upgrades and switch on the daily run. The
#       distro's own security origins stay as shipped; the settings below
#       are added in /etc/apt/apt.conf.d/51unattended-upgrades.
UNATTENDED_UPGRADES="no"
UU_INCLUDE_UPDATES="yes"   # yes = also install from <release>-updates, not only security
UU_MAIL=""                 # address for reports (needs working mail, e.g. POSTFIX_RELAY). Blank = no mail
UU_AUTO_REBOOT="false"     # true = reboot by itself when an upgrade needs it
UU_REBOOT_TIME="06:00"     # HH:MM or "now"; only used with UU_AUTO_REBOOT="true"
# Extra repos to upgrade from, as Origins-Pattern entries. Use single
# quotes so ${distro_codename} reaches apt untouched, e.g.
#   UU_EXTRA_ORIGINS=( 'origin=Docker,archive=${distro_codename}' )
# Find the values with:  apt-cache policy
UU_EXTRA_ORIGINS=()

# --- System tweaks ---
# yes = uninstall snapd (if present) and pin it so apt never installs it.
REMOVE_SNAPD="no"
# yes = turn IPv6 off inside the container.
DISABLE_IPV6="no"
# yes = let pip install system-wide (/etc/pip.conf: break-system-packages).
PIP_BREAK_SYSTEM_PACKAGES="no"
# yes = add "set disable_coredump false" to /etc/sudo.conf. Only needed if
#       sudo prints "setrlimit(RLIMIT_CORE): Operation not permitted".
SUDO_COREDUMP_FIX="no"
# 1 = allow keyctl(). Docker inside an unprivileged container needs it.
KEYCTL="0"

# --- Hooks ---
# Your own changes, without editing this script. Relative paths are looked
# up next to the profile. Empty () = nothing to do.
#   UPLOAD_FILES       "local_path:/guest/path" pairs, copied in BEFORE the
#                      setup runs (so files for /etc/skel reach new users).
#   PROVISION_SCRIPTS  scripts run as root inside the container AFTER the
#                      setup, e.g. to install an app. The #! line is
#                      honoured; with none, /bin/sh runs it.
UPLOAD_FILES=()
PROVISION_SCRIPTS=()

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

_is_yes() { [[ "${1:-}" == "yes" ]]; }

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

# Ask for a whole number in a range. Re-asks until valid.
# Usage: _read_number "Prompt" <default> <min> <max>   -> result in $NUM
_read_number() {
    local prompt="$1" def="$2" min="$3" max="$4" ans
    [[ "$def" =~ ^[0-9]+$ ]] || def="$min"
    (( 10#$def < min )) && def="$min"
    (( 10#$def > max )) && def="$max"
    while true; do
        read -rp "${prompt} [$((10#$def))]: " ans
        ans="${ans:-$def}"
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( 10#$ans >= min && 10#$ans <= max )); then
            NUM=$((10#$ans))
            return
        fi
        warn "Enter a number from $min to $max."
    done
}

# Container hostnames must be DNS-style: letters, digits, '-' and '.'.
_valid_ct_name() {
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

_valid_vlan() {
    [[ -z "$1" ]] && return 0
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 4094 ))
}

_valid_ipv4() {
    local o
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        (( 10#$o <= 255 )) || return 1
    done
}

# "dhcp", or an IPv4 address with a prefix length (192.168.1.50/24).
_valid_ip_setting() {
    [[ "$1" == "dhcp" ]] && return 0
    [[ "$1" == */* ]] || return 1
    local prefix="${1##*/}"
    _valid_ipv4 "${1%/*}" && [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && (( 10#$prefix >= 1 && 10#$prefix <= 32 ))
}

# Linux login name, without dots (it is also used as a sudoers file name).
_valid_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$1" != "root" ]]
}

# True if every non-blank line is a real public key (and there is one).
# ssh-keygen rejects private keys and typos.
_valid_pubkeys() {
    local line n=0
    while IFS= read -r line; do
        [[ -z "${line// /}" ]] && continue
        ssh-keygen -l -f /dev/stdin <<< "$line" &>/dev/null || return 1
        n=$((n + 1))
    done <<< "$1"
    (( n > 0 ))
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

# Same, for a whole array: prints ( "a" "b" ).
# Usage: _conf_arr <array name>
_conf_arr() {
    local -n _arr="$1"
    local v out="("
    for v in "${_arr[@]}"; do out+=" $(_conf_val "$v")"; done
    printf '%s )' "$out"
}

# =============================================================================
#  ARGUMENTS
# =============================================================================
CONFIG_FILE=""
UNATTENDED="no"          # yes = no prompts (needs --config)
CTID_FLAG=""             # from --ctid
AUTO_CTID="no"           # yes = pick next free ID on conflict
FORCE_OVERWRITE="no"     # yes = replace existing template with same ID
I_KNOW="no"              # yes = skip overwrite confirmation (unattended)
KEEP_ON_FAILURE="no"     # yes = don't remove a half-built container
PRINT_GUEST="no"         # yes = print the in-container setup script and exit

# These CLI values must beat anything in the profile, so hold them aside.
_CLI_CONVERT_TO_TEMPLATE=""
_CLI_CT_NAME=""

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

PROFILE
  --config <file>     Load a profile (.conf): one saved at the summary, or
                      a copy of profile.conf.example.
                      Relative paths are looked up next to this script.
  --name <name>       Set the container hostname. Skips that prompt.

CONTAINER ID
  --ctid <id>         Use exactly this ID. Stops if it is already taken.
  --auto-ctid         Find a free ID automatically.
                        With --ctid:    start at that ID, count upwards.
                        Without --ctid: start at 100.
                      (--vmid / --auto-vmid are accepted as aliases.)

TEMPLATE
  --template          Clean the container and convert it to a Proxmox
                      template at the end.
  --no-template       Leave it as a normal, running container.
                      Neither flag: use the profile value, or ask.

AUTOMATION
  --unattended        No prompts. Requires --config.
                      No ROOTFS_STOR in the profile: the host's only
                      container storage is used (stops if there are several).

DEBUGGING
  --keep-on-failure   If the build fails, keep the half-built container
                      instead of removing it.
  --print-guest-script
                      Print the setup script that would run inside the
                      container, then exit. Nothing is created.
                      The output contains POSTFIX_PASS if your profile
                      sets it.

DANGER ZONE (deletes data)
  --force-overwrite   Destroy an existing container template with the same
                      ID, then rebuild. Templates only. Refuses normal
                      containers and VMs.
                      Command line only. Ignored if set in a profile.
  --i-know-what-i-am-doing
                      Skip the overwrite confirmation.
                      Requires --force-overwrite AND --unattended.

  -h, --help          Show this help.

EXAMPLES
  Interactive first run:
    ./$SCRIPT_NAME

  A running container from a profile:
    ./$SCRIPT_NAME --config docker-host.conf --name docker01 --no-template

  Next free ID from 53000, as a template, no questions:
    ./$SCRIPT_NAME --config debian-base.conf --unattended \\
        --ctid 53000 --auto-ctid --template

  Rebuild an existing template in place, no questions:
    ./$SCRIPT_NAME --config debian-base.conf --unattended --ctid 53001 \\
        --force-overwrite --i-know-what-i-am-doing --template
EOF
}

# Fails clearly if a flag that needs a value is missing one.
_need_arg() {
    [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 needs a value. Use --help for usage."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)             _need_arg "$@"; CONFIG_FILE="$2"; shift 2 ;;
        --name)               _need_arg "$@"; _CLI_CT_NAME="$2"; shift 2 ;;
        --ctid|--vmid)        _need_arg "$@"; CTID_FLAG="$2"; shift 2 ;;
        --auto-ctid|--auto-vmid) AUTO_CTID="yes"; shift ;;
        --unattended)         UNATTENDED="yes"; shift ;;
        --force-overwrite)    FORCE_OVERWRITE="yes"; shift ;;
        --i-know-what-i-am-doing) I_KNOW="yes"; shift ;;
        --keep-on-failure)    KEEP_ON_FAILURE="yes"; shift ;;
        --print-guest-script) PRINT_GUEST="yes"; shift ;;
        --template)           _CLI_CONVERT_TO_TEMPLATE="yes"; shift ;;
        --no-template)        _CLI_CONVERT_TO_TEMPLATE="no"; shift ;;
        -h|--help)            usage; exit 0 ;;
        *)                    die "Unknown argument: $1. Use --help for usage." ;;
    esac
done

[[ $EUID -eq 0 || "$PRINT_GUEST" == "yes" ]] || die "Run this script as root."

# --- Load the profile ---
if [[ -n "$CONFIG_FILE" ]]; then
    [[ "$CONFIG_FILE" != /* ]] && CONFIG_FILE="$SCRIPT_DIR/$CONFIG_FILE"
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
    [[ "$PRINT_GUEST" == "yes" ]] || info "Loading config from: $CONFIG_FILE"

    # Safety flags are CLI-only. Snapshot them so a profile can't change them.
    _safe_flags="$UNATTENDED|$AUTO_CTID|$FORCE_OVERWRITE|$I_KNOW|$KEEP_ON_FAILURE|$PRINT_GUEST|$CTID_FLAG|$CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    IFS='|' read -r UNATTENDED AUTO_CTID FORCE_OVERWRITE I_KNOW KEEP_ON_FAILURE PRINT_GUEST CTID_FLAG CONFIG_FILE <<< "$_safe_flags"
    unset _safe_flags
fi

# Relative hook paths in a profile are looked up next to that profile.
CONFIG_DIR="$SCRIPT_DIR"
[[ -n "$CONFIG_FILE" ]] && CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"

# --- Flag sanity checks ---
[[ "$UNATTENDED" == "yes" && -z "$CONFIG_FILE" ]] \
    && die "--unattended requires --config <file>. There are no saved values to run from."

[[ "$I_KNOW" == "yes" && ( "$FORCE_OVERWRITE" != "yes" || "$UNATTENDED" != "yes" ) ]] \
    && die "--i-know-what-i-am-doing requires both --force-overwrite and --unattended."

[[ "$AUTO_CTID" == "yes" && "$FORCE_OVERWRITE" == "yes" ]] \
    && die "--auto-ctid and --force-overwrite are mutually exclusive. Choose one."

[[ -n "$CTID_FLAG" && ! "$CTID_FLAG" =~ ^[1-9][0-9]{2,8}$ ]] \
    && die "--ctid must be a number from 100 to 999999999."

[[ -n "$_CLI_CT_NAME" ]] && ! _valid_ct_name "$_CLI_CT_NAME" \
    && die "Invalid --name '$_CLI_CT_NAME'. Use letters, digits, '-' and '.' only."

# CLI beats profile.
CONVERT_TO_TEMPLATE="${_CLI_CONVERT_TO_TEMPLATE:-${CONVERT_TO_TEMPLATE:-}}"
[[ -n "$_CLI_CT_NAME" ]] && CT_NAME="$_CLI_CT_NAME"
CTID=""
[[ -n "$CTID_FLAG" ]] && CTID="$CTID_FLAG"

# =============================================================================
#  FAILURE HANDLING
#  On any failure or Ctrl+C: remove the half-built container and temp files.
#  The downloaded template is kept so a retry is fast.
# =============================================================================
CTID_CREATED=""          # set once 'pct create' succeeds
TMP_DIR=""               # host-side temp files (may hold the mail password)
LAST_ERR_LINE=""
TEMPLATE_CONVERTED="no"
GUEST_SCRIPT="/root/.create-lxc-setup.sh"   # path inside the container

on_exit() {
    local rc=$?
    trap - EXIT ERR INT TERM
    [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
    (( rc == 0 )) && return 0

    [[ -n "$LAST_ERR_LINE" ]] && error "Command failed at line $LAST_ERR_LINE (exit code $rc)."
    _destroy_partial_ct
    exit "$rc"
}

_destroy_partial_ct() {
    [[ -n "$CTID_CREATED" ]] || return 0
    ctid_exists "$CTID_CREATED" || return 0
    if [[ "$KEEP_ON_FAILURE" == "yes" ]]; then
        # The setup script can hold the mail password: don't leave it behind.
        pct exec "$CTID_CREATED" -- rm -f "$GUEST_SCRIPT" /root/.create-lxc-hook &>/dev/null || true
        warn "Container ${CTID_CREATED} kept (--keep-on-failure). Look inside:  pct enter ${CTID_CREATED}"
        warn "Remove it with:  pct destroy ${CTID_CREATED} --force 1 --purge 1"
        return 0
    fi
    warn "Removing partially built container ${CTID_CREATED}..."
    pct destroy "$CTID_CREATED" --force 1 --purge 1 --destroy-unreferenced-disks 1 &>/dev/null || true
    warn "Container ${CTID_CREATED} removed."
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
    command -v pct &>/dev/null && command -v pveam &>/dev/null \
        || die "pct / pveam not found. Is this a full Proxmox VE install?"
    success "Proxmox VE detected: $(pveversion | cut -d/ -f2)"
}

# Lists active storages that accept a content type, as "name type" lines.
# Usage: _storages_for rootdir | vztmpl
_storages_for() {
    pvesm status --content "$1" 2>/dev/null \
        | awk 'NR>1 && $3=="active" {print $1, $2}'
}

# =============================================================================
#  OPERATING SYSTEM
#  The list comes from Proxmox's own template index (pveam), plus anything
#  already downloaded, so new releases appear without editing this script.
# =============================================================================
ARCH=""
TEMPLATE_FILE=""         # e.g. debian-13-standard_13.1-2_amd64.tar.zst
OS_DISTRO=""             # ubuntu | debian
OS_VER=""                # 24.04 | 13
OS_NAME=""               # "Ubuntu 24.04"

# Every Ubuntu/Debian "standard" template for this CPU type: available to
# download or already on a storage. Oldest build first.
_template_candidates() {
    local s _t
    {
        pveam available --section system 2>/dev/null | awk '{print $2}'
        while read -r s _t; do
            pveam list "$s" 2>/dev/null | awk 'NR>1 {sub(/^.*vztmpl\//, "", $1); print $1}'
        done < <(_storages_for vztmpl)
    } | grep -E "^(ubuntu|debian)-[0-9.]+-standard_.*_${ARCH}\.tar\.(zst|xz|gz)$" | sort -uV || true
}

select_template_storage() {
    local name _type names=()
    while read -r name _type; do names+=("$name"); done < <(_storages_for vztmpl)
    [[ ${#names[@]} -gt 0 ]] \
        || die "No active storage accepts container templates. Enable 'Container template' on one (Datacenter > Storage)."

    if [[ -n "$TEMPLATE_STOR" ]]; then
        printf '%s\n' "${names[@]}" | grep -qxF -- "$TEMPLATE_STOR" \
            || die "TEMPLATE_STOR '$TEMPLATE_STOR' is missing, inactive or cannot hold container templates. Found: ${names[*]}"
    elif printf '%s\n' "${names[@]}" | grep -qxF "local"; then
        TEMPLATE_STOR="local"
    else
        TEMPLATE_STOR="${names[0]}"
    fi
}

select_os() {
    header "Operating System"
    ARCH="$(dpkg --print-architecture)"
    select_template_storage

    info "Refreshing the Proxmox template list..."
    pveam update &>/dev/null \
        || warn "Could not refresh the list. Using what is already known or downloaded."

    local all=() keys=() t k
    local -A newest=()
    mapfile -t all < <(_template_candidates)
    [[ ${#all[@]} -gt 0 ]] || die "No Ubuntu or Debian container templates found (pveam available)."

    # 'all' is sorted oldest build first, so the last one seen per release wins.
    for t in "${all[@]}"; do
        k="${t%%-standard_*}"
        [[ -n "${newest[$k]:-}" ]] || keys+=("$k")
        newest[$k]="$t"
    done

    if [[ -n "$OS_TEMPLATE" ]]; then
        if [[ -n "${newest[$OS_TEMPLATE]:-}" ]]; then
            k="$OS_TEMPLATE"
        else
            [[ "$UNATTENDED" == "yes" ]] \
                && die "OS_TEMPLATE '$OS_TEMPLATE' is not available. Found: ${keys[*]}"
            warn "OS_TEMPLATE '$OS_TEMPLATE' is not available. Choose another below."
            OS_TEMPLATE=""
        fi
    fi

    if [[ -z "$OS_TEMPLATE" ]]; then
        [[ "$UNATTENDED" == "yes" ]] \
            && die "OS_TEMPLATE is not set in the profile. Choose one of: ${keys[*]}"
        local i
        for i in "${!keys[@]}"; do
            printf "  %d) %-16s %s\n" "$((i + 1))" "${keys[$i]}" "${newest[${keys[$i]}]}"
        done
        echo ""
        _read_index "Select OS" "${#keys[@]}" "${#keys[@]}"
        k="${keys[$((PICK - 1))]}"
        OS_TEMPLATE="$k"
    fi

    TEMPLATE_FILE="${newest[$k]}"
    OS_DISTRO="${k%%-*}"
    OS_VER="${k#*-}"
    OS_NAME="${OS_DISTRO^} ${OS_VER}"
    success "OS: $OS_NAME ($TEMPLATE_FILE on $TEMPLATE_STOR)"
}

download_template() {
    header "Template Download"
    if pveam list "$TEMPLATE_STOR" 2>/dev/null | grep -qF "vztmpl/${TEMPLATE_FILE}"; then
        success "Already downloaded: $TEMPLATE_FILE"
        return
    fi
    # pveam checks the download against Proxmox's published checksum.
    pveam download "$TEMPLATE_STOR" "$TEMPLATE_FILE"
    success "Downloaded: $TEMPLATE_FILE"
}

# =============================================================================
#  STORAGE
# =============================================================================
select_storage() {
    header "Storage Selection"
    echo "  This is where the container's disk will be stored."
    echo ""

    local name type
    local storages=() types=()
    while read -r name type; do
        storages+=("$name")
        types+=("$type")
    done < <(_storages_for rootdir)

    [[ ${#storages[@]} -gt 0 ]] || die "No active storage pools that accept container disks were found."

    # Profile value: use it if it is still valid.
    if [[ -n "$ROOTFS_STOR" ]]; then
        if printf '%s\n' "${storages[@]}" | grep -qxF -- "$ROOTFS_STOR"; then
            success "Using storage from config: $ROOTFS_STOR"
            return
        fi
        [[ "$UNATTENDED" == "yes" ]] \
            && die "Configured storage '$ROOTFS_STOR' is missing, inactive or cannot hold container disks."
        warn "Configured storage '$ROOTFS_STOR' is missing, inactive or cannot hold container disks."
        warn "Choose another below."
    fi

    # Unattended with no storage in the profile: use the only one there is.
    # With several, stop rather than guess.
    if [[ "$UNATTENDED" == "yes" ]]; then
        if [[ ${#storages[@]} -eq 1 ]]; then
            ROOTFS_STOR="${storages[0]}"
            success "Only one storage can hold container disks, using it: $ROOTFS_STOR"
            return
        fi
        die "ROOTFS_STOR is not set in the profile, and this host has ${#storages[@]} storages that can hold container disks: ${storages[*]}
  Add one to the profile, e.g.  ROOTFS_STOR=\"${storages[0]}\""
    fi

    local default_num=1 idx
    for idx in "${!storages[@]}"; do
        printf "  %d) %-20s %s\n" "$((idx + 1))" "${storages[$idx]}" "${types[$idx]}"
        [[ "${storages[$idx]}" == "$ROOTFS_STOR_DEFAULT" ]] && default_num=$((idx + 1))
    done
    echo ""

    _read_index "Select storage pool" "${#storages[@]}" "$default_num"
    ROOTFS_STOR="${storages[$((PICK - 1))]}"
    success "Container will be stored on: $ROOTFS_STOR"
}

# =============================================================================
#  CONTAINER ID HELPERS
#  /etc/pve/.vmlist covers the whole cluster, VMs AND containers.
#  ('pct list' only shows containers on this node, so it misses clashes.)
# =============================================================================
ctid_exists() {
    if [[ -r /etc/pve/.vmlist ]]; then
        grep -q "\"${1}\":" /etc/pve/.vmlist
    else
        pct status "$1" &>/dev/null || qm status "$1" &>/dev/null
    fi
}

# Config path for a container on THIS node. Overwrite only works locally.
_local_ct_conf() { echo "/etc/pve/lxc/${1}.conf"; }

# True if the container is a template. Reads only the main section, not snapshots.
ctid_is_template() {
    local conf
    conf="$(_local_ct_conf "$1")"
    [[ -f "$conf" ]] && sed '/^\[/q' "$conf" | grep -q '^template: 1'
}

ctid_is_running() {
    pct status "$1" 2>/dev/null | grep -q "^status: running"
}

# Container hostname, for warnings. Looks across all cluster nodes.
ctid_name() {
    sed -n 's/^hostname: //p' /etc/pve/nodes/*/lxc/"${1}".conf 2>/dev/null | head -1
}

next_free_ctid() {
    local id="$1"
    while ctid_exists "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

# --force-overwrite is split in two steps, so the old template survives
# if you cancel at the summary or the download fails:
#   1. _check_overwrite     early: safety checks + your confirmation
#   2. replace_old_template late:  re-check, countdown, destroy
OVERWRITE_CTID=""

# Dies unless the ID is a stopped container template on this node.
_assert_overwritable() {
    local id="$1"
    [[ -f "$(_local_ct_conf "$id")" ]] \
        || die "ID $id belongs to a VM or a container on another node. --force-overwrite only replaces container templates on this node."
    ctid_is_running "$id" \
        && die "Container $id is running. Stop it before overwriting."
    ctid_is_template "$id" \
        || die "Container $id ('$(ctid_name "$id")') is not a template. --force-overwrite only replaces templates, to protect normal containers."
    return 0
}

_check_overwrite() {
    local id="$1" name
    _assert_overwritable "$id"
    name="$(ctid_name "$id")"

    echo ""
    warn "OVERWRITE REQUESTED"
    warn "Container $id ('${name}') and its disk will be destroyed and rebuilt."
    warn "This happens just before the new one is created. It cannot be undone."
    echo ""

    if [[ "$UNATTENDED" == "yes" ]]; then
        # Earlier checks guarantee I_KNOW=yes here; re-check anyway.
        [[ "$I_KNOW" == "yes" ]] || die "Unattended overwrite requires --i-know-what-i-am-doing."
        info "Confirmed via --i-know-what-i-am-doing."
    else
        # Unnamed containers are confirmed by ID, so an empty Enter can never match.
        local expected="${name:-$id}" what="name"
        [[ -z "$name" ]] && what="ID"
        echo "  Container ID:   $id"
        echo "  Container name: ${name:-(none)}"
        echo ""
        read -rp "  Type the container ${what} to confirm destruction: " confirm
        [[ "$confirm" == "$expected" ]] || die "The ${what} did not match. Aborting overwrite."
    fi
    OVERWRITE_CTID="$id"
}

# Runs just before create_ct. The container may have changed in the
# meantime, so every safety check runs again.
replace_old_template() {
    [[ -n "$OVERWRITE_CTID" ]] || return 0
    header "Replace Existing Template"

    if ! ctid_exists "$OVERWRITE_CTID"; then
        info "Container $OVERWRITE_CTID no longer exists. Nothing to destroy."
        return
    fi
    _assert_overwritable "$OVERWRITE_CTID"

    warn "Destroying container $OVERWRITE_CTID. Press Ctrl+C to abort."
    _countdown "Destroying"
    pct destroy "$OVERWRITE_CTID" --purge 1 --destroy-unreferenced-disks 1
    success "Container $OVERWRITE_CTID destroyed."
}

get_valid_ctid() {
    header "Container ID"

    # --auto-ctid alone: next free from 100.
    if [[ "$AUTO_CTID" == "yes" && -z "$CTID_FLAG" ]]; then
        CTID="$(next_free_ctid 100)"
        success "Auto-selected next free container ID: $CTID"
        return
    fi

    # From --ctid, else the default, else ask.
    if [[ -z "$CTID" ]]; then
        if [[ "$UNATTENDED" == "yes" ]]; then
            CTID="$CTID_DEFAULT"
        else
            read -rp "Enter container ID [${CTID_DEFAULT}]: " input
            CTID="${input:-$CTID_DEFAULT}"
        fi
    fi

    # Interactive: keep asking until the ID is valid and free.
    # (Unattended conflicts are handled below and never loop.)
    while true; do
        if [[ ! "$CTID" =~ ^[1-9][0-9]{2,8}$ ]]; then
            [[ "$UNATTENDED" == "yes" ]] && die "Invalid container ID: '$CTID'."
            warn "Container ID must be a number from 100 to 999999999."
        elif ! ctid_exists "$CTID"; then
            break
        elif [[ "$FORCE_OVERWRITE" == "yes" ]]; then
            # Confirm now; the actual destroy waits until just before the build.
            _check_overwrite "$CTID"
            break
        elif [[ "$AUTO_CTID" == "yes" ]]; then
            local original="$CTID"
            CTID="$(next_free_ctid "$CTID")"
            warn "ID $original is taken. Using the next free ID: $CTID"
            break
        elif [[ "$UNATTENDED" == "yes" ]]; then
            die "ID $CTID already exists. Re-run with one of:
  --ctid <id>          a different ID
  --auto-ctid          the next free ID
  --force-overwrite    replace the existing template (templates only)"
        else
            warn "ID $CTID already exists."
        fi
        read -rp "Enter a different container ID: " CTID
    done

    success "Container ID: $CTID"
}

# =============================================================================
#  QUESTIONS
#  Tip: at any prompt showing [a value], press Enter to keep it.
# =============================================================================
_host_bridges() {
    local d n
    for d in /sys/class/net/*; do
        n="${d##*/}"
        if [[ -d "$d/bridge" || "$n" == vmbr* ]]; then
            echo "$n"
        fi
    done | sort -u
}

_prompt_bridge() {
    local bridges=() i default_num=1
    mapfile -t bridges < <(_host_bridges)
    [[ ${#bridges[@]} -gt 0 ]] || die "No network bridges found on this host (e.g. vmbr0)."

    echo ""
    echo "Network bridge (the container's network card connects to this):"
    for i in "${!bridges[@]}"; do
        printf "  %d) %s\n" "$((i + 1))" "${bridges[$i]}"
        [[ "${bridges[$i]}" == "$NET_BRIDGE" ]] && default_num=$((i + 1))
    done
    _read_index "Select bridge" "${#bridges[@]}" "$default_num"
    NET_BRIDGE="${bridges[$((PICK - 1))]}"
}

_prompt_network() {
    local ans
    _prompt_bridge

    while true; do
        read -rp "VLAN tag (1-4094, blank = none) [${VLAN:-none}]: " ans
        ans="${ans:-$VLAN}"
        [[ "$ans" == "none" ]] && ans=""
        if _valid_vlan "$ans"; then VLAN="$ans"; break; fi
        warn "Enter a number from 1 to 4094, or leave blank."
    done

    while true; do
        read -rp "IP address ('dhcp', or static like 192.168.1.50/24) [${IP}]: " ans
        ans="${ans:-$IP}"
        if _valid_ip_setting "$ans"; then IP="$ans"; break; fi
        warn "Enter 'dhcp' or an IPv4 address with a prefix, e.g. 192.168.1.50/24."
    done

    if [[ "$IP" == "dhcp" ]]; then
        GATEWAY=""
        return
    fi
    while true; do
        read -rp "Gateway${GATEWAY:+ [$GATEWAY]}: " ans
        ans="${ans:-$GATEWAY}"
        if _valid_ipv4 "$ans"; then GATEWAY="$ans"; break; fi
        warn "Enter the gateway's IPv4 address, e.g. 192.168.1.1."
    done
}

user_prompts() {
    header "Container Settings"

    # Template or container first: it changes the default name.
    if [[ -z "$CONVERT_TO_TEMPLATE" ]]; then
        if [[ "$UNATTENDED" == "yes" ]]; then
            CONVERT_TO_TEMPLATE="no"
        else
            echo "  A template is read-only and can only be cloned."
            echo "  Say no to get a normal container, left running."
            echo ""
            read -rp "Convert to a template at the end? (y/N): " choice
            [[ "${choice:-N}" =~ ^[Yy]$ ]] && CONVERT_TO_TEMPLATE="yes" || CONVERT_TO_TEMPLATE="no"
        fi
    fi

    local default_name="${OS_DISTRO}-${OS_VER//./}-lxc"
    _is_yes "$CONVERT_TO_TEMPLATE" && default_name+="-template"

    if [[ "$UNATTENDED" == "yes" ]]; then
        CT_NAME="${CT_NAME:-$default_name}"
        return
    fi

    if [[ -z "$_CLI_CT_NAME" ]]; then
        local ans
        while true; do
            read -rp "Hostname [${CT_NAME:-$default_name}]: " ans
            ans="${ans:-${CT_NAME:-$default_name}}"
            if _valid_ct_name "$ans"; then CT_NAME="$ans"; break; fi
            warn "Use letters, digits, '-' and '.' only."
        done
    fi

    _read_number "CPU cores" "$CORES" 1 "$(nproc)";          CORES="$NUM"
    _read_number "Memory in MB" "$MEM" 128 1048576;          MEM="$NUM"
    _read_number "Disk size in GB" "${DISK_SIZE%G}" 2 65536; DISK_SIZE="${NUM}G"
    _prompt_network
}

# Relative hook paths are looked up next to the profile.
_hook_path() {
    if [[ "$1" == /* ]]; then echo "$1"; else echo "$CONFIG_DIR/$1"; fi
}

_check_yes_no() {
    local name="$1"
    [[ "${!name}" == "yes" || "${!name}" == "no" ]] \
        || die "$name must be \"yes\" or \"no\" (it is '${!name}')."
}

_check_0_1() {
    local name="$1"
    [[ "${!name}" == "0" || "${!name}" == "1" ]] \
        || die "$name must be 0 or 1 (it is '${!name}')."
}

# Settings that don't depend on this host. Also run for --print-guest-script.
validate_features() {
    local v
    for v in APT_UPGRADE ZSH_DOTFILES POSTFIX_RELAY UNATTENDED_UPGRADES UU_INCLUDE_UPDATES \
             REMOVE_SNAPD DISABLE_IPV6 PIP_BREAK_SYSTEM_PACKAGES SUDO_COREDUMP_FIX; do
        _check_yes_no "$v"
    done
    for v in UNPRIVILEGED NESTING KEYCTL START_ON_BOOT; do
        _check_0_1 "$v"
    done
    [[ "$KEYCTL" == "1" && "$UNPRIVILEGED" != "1" ]] \
        && die "KEYCTL=1 only applies to unprivileged containers (UNPRIVILEGED=1)."

    [[ "$LOCAL_LANG" =~ ^[A-Za-z_]+(\.[A-Za-z0-9-]+)?(@[A-Za-z]+)?$ ]] \
        || die "Invalid LOCAL_LANG '$LOCAL_LANG'. Example: en_GB.UTF-8"
    [[ -z "$TZ" || "$TZ" == "host" || "$TZ" =~ ^[A-Za-z0-9_+/-]+$ ]] \
        || die "Invalid TZ '$TZ'. Example: Europe/London"
    # Proxmox refuses the Etc/* zones.
    [[ "$TZ" != Etc/* ]] || die "TZ '$TZ' is not accepted by Proxmox. Use \"UTC\", \"host\" or a region such as Europe/London."
    [[ "$BASE_PKGS,$EXTRA_PKGS" =~ ^[A-Za-z0-9.+,\ :-]*$ ]] \
        || die "BASE_PKGS / EXTRA_PKGS may only hold package names separated by commas."

    if [[ -n "$ROOT_SSH_KEY" ]]; then
        _valid_pubkeys "$ROOT_SSH_KEY" || die "ROOT_SSH_KEY is not a valid SSH public key."
    fi
    if [[ -n "$ANSIBLE_USER" ]]; then
        _valid_username "$ANSIBLE_USER" || die "Invalid ANSIBLE_USER '$ANSIBLE_USER'."
        _valid_pubkeys "$ANSIBLE_SSH_KEY" \
            || die "ANSIBLE_USER is set, so ANSIBLE_SSH_KEY must hold a valid SSH public key (the account has no password)."
    fi
    if [[ -n "$ADMIN_USER" ]]; then
        _valid_username "$ADMIN_USER" || die "Invalid ADMIN_USER '$ADMIN_USER'."
        [[ "$ADMIN_USER" != "$ANSIBLE_USER" ]] || die "ADMIN_USER and ANSIBLE_USER must be different."
        _valid_pubkeys "$ADMIN_SSH_KEY" \
            || die "ADMIN_USER is set, so ADMIN_SSH_KEY must hold a valid SSH public key (the account has no password)."
    fi

    if _is_yes "$ZSH_DOTFILES"; then
        for v in "${DOTFILES_URLS[@]}"; do
            [[ "$v" =~ ^https://[^[:space:]]+/[^/[:space:]]+$ ]] \
                || die "DOTFILES_URLS entry is not an https file URL: $v"
        done
    fi

    if _is_yes "$POSTFIX_RELAY"; then
        [[ -n "$POSTFIX_RELAYHOST" && -n "$POSTFIX_USER" && -n "$POSTFIX_PASS" ]] \
            || die "POSTFIX_RELAY=yes needs POSTFIX_RELAYHOST, POSTFIX_USER and POSTFIX_PASS in the profile."
        [[ "$POSTFIX_RELAYHOST" =~ ^[][A-Za-z0-9.:-]+$ ]] \
            || die "Invalid POSTFIX_RELAYHOST '$POSTFIX_RELAYHOST'. Example: [smtp.gmail.com]:587"
        [[ "$MAIL_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
            || die "POSTFIX_RELAY=yes needs MAIL_DOMAIN, e.g. example.com."
    fi

    if _is_yes "$UNATTENDED_UPGRADES"; then
        [[ "$UU_AUTO_REBOOT" == "true" || "$UU_AUTO_REBOOT" == "false" ]] \
            || die "UU_AUTO_REBOOT must be \"true\" or \"false\"."
        [[ "$UU_REBOOT_TIME" == "now" || "$UU_REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
            || die "UU_REBOOT_TIME must be HH:MM or \"now\"."
        [[ -z "$UU_MAIL" || "$UU_MAIL" =~ ^[^[:space:]\"@]+@[^[:space:]\"@]+$ ]] \
            || die "Invalid UU_MAIL '$UU_MAIL'."
        for v in "${UU_EXTRA_ORIGINS[@]}"; do
            [[ "$v" != *\"* && "$v" == *=* ]] \
                || die "UU_EXTRA_ORIGINS entries look like 'origin=Docker,archive=\${distro_codename}' (no double quotes): $v"
        done
    fi

    local pair src
    for pair in "${UPLOAD_FILES[@]}"; do
        [[ "$pair" == *:/* ]] || die "UPLOAD_FILES entries are \"local_path:/guest/path\": $pair"
        src="$(_hook_path "${pair%%:/*}")"
        [[ -f "$src" ]] || die "UPLOAD_FILES: file not found: $src"
    done
    for v in "${PROVISION_SCRIPTS[@]}"; do
        src="$(_hook_path "$v")"
        [[ -f "$src" ]] || die "PROVISION_SCRIPTS: file not found: $src"
    done
}

# Settings that are checked against this host.
validate_config() {
    _valid_ct_name "$CT_NAME" || die "Invalid hostname '$CT_NAME'. Use letters, digits, '-' and '.' only."
    _valid_tags "$TAG" || die "Invalid TAG '$TAG'. Use letters, digits, '_', '-', '+', '.', separated by ';'."

    [[ "$CORES" =~ ^[1-9][0-9]*$ ]] || die "Invalid CORES '$CORES'."
    [[ "$MEM" =~ ^[1-9][0-9]*$ ]] && (( 10#$MEM >= 128 )) || die "Invalid MEM '$MEM'. Use MB, at least 128."
    [[ "$SWAP" =~ ^[0-9]+$ ]] || die "Invalid SWAP '$SWAP'. Use MB, or 0 for none."
    [[ "$DISK_SIZE" =~ ^[0-9]+G$ ]] && (( 10#${DISK_SIZE%G} >= 2 )) \
        || die "Invalid DISK_SIZE '$DISK_SIZE'. Use a number of GB followed by G, at least 2G (e.g. 8G)."

    # Must be one of this host's bridges (not empty, not a plain NIC like eth0).
    _host_bridges | grep -qxF -- "$NET_BRIDGE" \
        || die "Bridge '$NET_BRIDGE' (NET_BRIDGE) is not a bridge on this host. Found: $(_host_bridges | tr '\n' ' ')"
    _valid_vlan "$VLAN" || die "Invalid VLAN '$VLAN'. Use 1-4094, or empty for none."
    _valid_ip_setting "$IP" || die "Invalid IP '$IP'. Use \"dhcp\" or an address with a prefix, e.g. 192.168.1.50/24."
    if [[ "$IP" != "dhcp" ]]; then
        _valid_ipv4 "$GATEWAY" \
            || die "A static IP needs GATEWAY (the container must reach the internet to install packages)."
    fi
    [[ -z "$NAMESERVER" ]] || _valid_ipv4 "$NAMESERVER" || die "Invalid NAMESERVER '$NAMESERVER'."
    [[ "$SEARCHDOMAIN" =~ ^[A-Za-z0-9.-]*$ ]] || die "Invalid SEARCHDOMAIN '$SEARCHDOMAIN'."

    [[ -z "$TZ" || "$TZ" == "host" || -f "/usr/share/zoneinfo/$TZ" ]] \
        || die "Unknown time zone '$TZ' (not in /usr/share/zoneinfo). Example: Europe/London"

    # Thin storage can be over-committed on purpose, so this only warns.
    local avail_kb
    avail_kb="$(pvesm status --storage "$ROOTFS_STOR" 2>/dev/null | awk 'NR>1 {print $6}')"
    if [[ "$avail_kb" =~ ^[0-9]+$ ]] && (( avail_kb < 10#${DISK_SIZE%G} * 1024 * 1024 )); then
        warn "Storage '$ROOTFS_STOR' has $(( avail_kb / 1024 / 1024 )) GB free, less than the ${DISK_SIZE} disk."
    fi

    if _is_yes "$CONVERT_TO_TEMPLATE" && [[ "$IP" != "dhcp" ]]; then
        warn "This template has a static IP ($IP). Every clone starts with the same one: change it per clone."
    fi
    return 0
}

# One line listing the optional features that are switched on.
_features_summary() {
    local on=()
    [[ -n "$ROOT_SSH_KEY" ]]                && on+=("root SSH key")
    [[ -n "$ANSIBLE_USER" ]]                && on+=("ansible user '$ANSIBLE_USER'")
    [[ -n "$ADMIN_USER" ]]                  && on+=("admin user '$ADMIN_USER'")
    _is_yes "$ZSH_DOTFILES"                 && on+=("zsh + dotfiles")
    _is_yes "$POSTFIX_RELAY"                && on+=("postfix relay")
    _is_yes "$UNATTENDED_UPGRADES"          && on+=("unattended-upgrades")
    _is_yes "$REMOVE_SNAPD"                 && on+=("no snapd")
    _is_yes "$DISABLE_IPV6"                 && on+=("no IPv6")
    _is_yes "$PIP_BREAK_SYSTEM_PACKAGES"    && on+=("pip system-wide")
    _is_yes "$SUDO_COREDUMP_FIX"            && on+=("sudo coredump fix")
    [[ ${#UPLOAD_FILES[@]} -gt 0 ]]         && on+=("${#UPLOAD_FILES[@]} uploaded file(s)")
    [[ ${#PROVISION_SCRIPTS[@]} -gt 0 ]]    && on+=("${#PROVISION_SCRIPTS[@]} hook script(s)")
    if [[ ${#on[@]} -eq 0 ]]; then
        echo "(none)"
    else
        local joined
        printf -v joined '%s, ' "${on[@]}"
        echo "${joined%, }"
    fi
}

_lxc_features() {
    local f=()
    [[ "$NESTING" == "1" ]] && f+=("nesting=1")
    [[ "$KEYCTL" == "1" ]]  && f+=("keyctl=1")
    local IFS=','
    echo "${f[*]}"
}

print_summary() {
    header "Summary: Review Before Proceeding"
    echo ""

    local net="$NET_BRIDGE${VLAN:+ (VLAN $VLAN)}, $IP${GATEWAY:+ via $GATEWAY}"
    local kind="unprivileged"
    [[ "$UNPRIVILEGED" == "1" ]] || kind="PRIVILEGED"

    _row() { printf "  %-22s %s\n" "$1" "$2"; }
    _row "OS:"                  "$OS_NAME"
    _row "Container ID:"        "$CTID${OVERWRITE_CTID:+ (REPLACES the existing template)}"
    _row "Hostname:"            "$CT_NAME"
    _row "Storage:"             "$ROOTFS_STOR, $DISK_SIZE"
    _row "CPU / Memory:"        "$CORES core(s) / ${MEM} MB (+ ${SWAP} MB swap)"
    _row "Type:"                "$kind${NESTING:+, $(_lxc_features)}"
    _row "Network:"             "$net"
    _row "Tags:"                "$TAG"
    _row "Locale / Timezone:"   "$LOCAL_LANG / ${TZ:-(unchanged)}"
    _row "Packages:"            "$BASE_PKGS${EXTRA_PKGS:+,$EXTRA_PKGS}"
    _row "Upgrade packages:"    "$APT_UPGRADE"
    _row "Features:"            "$(_features_summary)"
    _row "Convert to template:" "$CONVERT_TO_TEMPLATE"
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
#  PROFILE (.conf)
#  Saved right after you confirm the summary, BEFORE any work starts.
#  So if the run fails, your answers are not lost.
# =============================================================================
PROFILE_NAME=""
PROFILE_PATH=""

prompt_config_name() {
    echo ""
    info "Save these answers as a profile to re-use them (or retry if this run fails)."
    read -rp "Profile name (e.g. debian-base, blank to skip): " profile_name
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
    success "Profile saved: $PROFILE_PATH"
}

write_config() {
    [[ -n "$PROFILE_PATH" ]] || return 0

    # The hostname is saved only if you chose one. The built-in default
    # depends on the OS and on template yes/no, so it is worked out each run.
    local saved_name="$CT_NAME" auto_name="${OS_DISTRO}-${OS_VER//./}-lxc"
    [[ "$CT_NAME" == "$auto_name" || "$CT_NAME" == "${auto_name}-template" ]] && saved_name=""

    # umask: the profile may hold your SSH keys, so keep it private to root.
    ( umask 077; cat > "$PROFILE_PATH" <<EOF
# =============================================================================
# Profile: ${PROFILE_NAME}
# Generated by ${SCRIPT_NAME} on $(date '+%Y-%m-%d %H:%M')
# Use it:  ./${SCRIPT_NAME} --config ${PROFILE_NAME}.conf
#
# Every setting is explained in profile.conf.example.
#
# Not saved on purpose:
#   - Container ID: chosen each run, to avoid clashes (--ctid / --auto-ctid).
#   - POSTFIX_PASS: never written by the script. Add it yourself below if
#     you use POSTFIX_RELAY. Keep this file private (it is chmod 600) and
#     out of git.
#   - Danger flags (--force-overwrite etc.): command line only.
# =============================================================================

# --- Operating system ---
OS_TEMPLATE=$(_conf_val "$OS_TEMPLATE")

# --- Storage ---
ROOTFS_STOR=$(_conf_val "$ROOTFS_STOR")
TEMPLATE_STOR=$(_conf_val "$TEMPLATE_STOR")

# --- Container identity ---
# Blank hostname = <distro>-<version>-lxc[-template]; --name overrides.
CT_NAME=$(_conf_val "$saved_name")
TAG=$(_conf_val "$TAG")
CTID_DEFAULT=$(_conf_val "$CTID_DEFAULT")

# --- Container resources ---
CORES=$(_conf_val "$CORES")
MEM=$(_conf_val "$MEM")
SWAP=$(_conf_val "$SWAP")
DISK_SIZE=$(_conf_val "$DISK_SIZE")
UNPRIVILEGED=$(_conf_val "$UNPRIVILEGED")
NESTING=$(_conf_val "$NESTING")
START_ON_BOOT=$(_conf_val "$START_ON_BOOT")

# --- Network ---
NET_BRIDGE=$(_conf_val "$NET_BRIDGE")
VLAN=$(_conf_val "$VLAN")
IP=$(_conf_val "$IP")
GATEWAY=$(_conf_val "$GATEWAY")
NAMESERVER=$(_conf_val "$NAMESERVER")
SEARCHDOMAIN=$(_conf_val "$SEARCHDOMAIN")

# --- Locale, time zone ---
LOCAL_LANG=$(_conf_val "$LOCAL_LANG")
TZ=$(_conf_val "$TZ")

# --- Packages (comma separated) ---
BASE_PKGS=$(_conf_val "$BASE_PKGS")
EXTRA_PKGS=$(_conf_val "$EXTRA_PKGS")
APT_UPGRADE=$(_conf_val "$APT_UPGRADE")

# --- Convert to a template at the end? ---
# "yes" / "no" / blank = ask. --template / --no-template override this.
CONVERT_TO_TEMPLATE=$(_conf_val "$CONVERT_TO_TEMPLATE")

# --- Users (SSH key only, no passwords) ---
ROOT_SSH_KEY=$(_conf_val "$ROOT_SSH_KEY")
ANSIBLE_USER=$(_conf_val "$ANSIBLE_USER")
ANSIBLE_SSH_KEY=$(_conf_val "$ANSIBLE_SSH_KEY")
ADMIN_USER=$(_conf_val "$ADMIN_USER")
ADMIN_SSH_KEY=$(_conf_val "$ADMIN_SSH_KEY")

# --- Shell ---
ZSH_DOTFILES=$(_conf_val "$ZSH_DOTFILES")
DOTFILES_URLS=$(_conf_arr DOTFILES_URLS)

# --- Mail ---
POSTFIX_RELAY=$(_conf_val "$POSTFIX_RELAY")
POSTFIX_RELAYHOST=$(_conf_val "$POSTFIX_RELAYHOST")
POSTFIX_USER=$(_conf_val "$POSTFIX_USER")
POSTFIX_PASS=""                   # not saved: add it here yourself, in single quotes
MAIL_DOMAIN=$(_conf_val "$MAIL_DOMAIN")

# --- Automatic updates ---
UNATTENDED_UPGRADES=$(_conf_val "$UNATTENDED_UPGRADES")
UU_INCLUDE_UPDATES=$(_conf_val "$UU_INCLUDE_UPDATES")
UU_MAIL=$(_conf_val "$UU_MAIL")
UU_AUTO_REBOOT=$(_conf_val "$UU_AUTO_REBOOT")
UU_REBOOT_TIME=$(_conf_val "$UU_REBOOT_TIME")
UU_EXTRA_ORIGINS=$(_conf_arr UU_EXTRA_ORIGINS)

# --- System tweaks ---
REMOVE_SNAPD=$(_conf_val "$REMOVE_SNAPD")
DISABLE_IPV6=$(_conf_val "$DISABLE_IPV6")
PIP_BREAK_SYSTEM_PACKAGES=$(_conf_val "$PIP_BREAK_SYSTEM_PACKAGES")
SUDO_COREDUMP_FIX=$(_conf_val "$SUDO_COREDUMP_FIX")
KEYCTL=$(_conf_val "$KEYCTL")

# --- Hooks (relative paths are looked up next to this profile) ---
UPLOAD_FILES=$(_conf_arr UPLOAD_FILES)
PROVISION_SCRIPTS=$(_conf_arr PROVISION_SCRIPTS)
EOF
    )
}

# =============================================================================
#  CREATE THE CONTAINER
# =============================================================================
_ct_description() {
    cat <<EOF
Built by ${SCRIPT_NAME} on $(date '+%Y-%m-%d %H:%M')

- OS: ${OS_NAME} (${TEMPLATE_FILE})
- Features: $(_features_summary)
- Login: \`pct enter ${CTID}\` from the host, or SSH with a key
EOF
}

create_ct() {
    header "Create Container"

    local net0="name=eth0,bridge=${NET_BRIDGE},ip=${IP}"
    [[ -n "$GATEWAY" ]] && net0+=",gw=${GATEWAY}"
    [[ -n "$VLAN" ]]    && net0+=",tag=${VLAN}"

    local onboot="$START_ON_BOOT"
    _is_yes "$CONVERT_TO_TEMPLATE" && onboot="0"

    local args=(
        --hostname "$CT_NAME"
        --cores "$CORES"
        --memory "$MEM"
        --swap "$SWAP"
        --rootfs "${ROOTFS_STOR}:${DISK_SIZE%G}"
        --net0 "$net0"
        --unprivileged "$UNPRIVILEGED"
        --onboot "$onboot"
        --tags "$TAG"
        --description "$(_ct_description)"
    )
    local features
    features="$(_lxc_features)"
    [[ -n "$features" ]]     && args+=(--features "$features")
    [[ -n "$TZ" ]]           && args+=(--timezone "$TZ")
    [[ -n "$NAMESERVER" ]]   && args+=(--nameserver "$NAMESERVER")
    [[ -n "$SEARCHDOMAIN" ]] && args+=(--searchdomain "$SEARCHDOMAIN")
    if [[ -n "$ROOT_SSH_KEY" ]]; then
        printf '%s\n' "$ROOT_SSH_KEY" > "$TMP_DIR/root_keys.pub"
        args+=(--ssh-public-keys "$TMP_DIR/root_keys.pub")
    fi

    pct create "$CTID" "${TEMPLATE_STOR}:vztmpl/${TEMPLATE_FILE}" "${args[@]}"
    CTID_CREATED="$CTID"
    success "Container $CTID created."

    _fix_root_owner
    pct start "$CTID"
    local i
    for i in {1..30}; do
        pct exec "$CTID" -- true &>/dev/null && break
        sleep 1
    done
    pct exec "$CTID" -- true || die "Container $CTID started but does not answer 'pct exec'."
    success "Container $CTID started."
}

# Some Debian templates unpack with / owned by 'nobody', which breaks
# systemd services and sudo. An unprivileged container cannot fix its own
# /, so it is done here from the host, before the first start.
# Only that exact case is touched: any other owner is left alone.
_fix_root_owner() {
    local mnt="/var/lib/lxc/${CTID}/rootfs" base=0 owner
    if [[ "$UNPRIVILEGED" == "1" ]]; then
        # First host ID mapped into containers (100000 unless changed).
        base="$(awk -F: '$1=="root" {print $2; exit}' /etc/subuid 2>/dev/null)"
        [[ "$base" =~ ^[0-9]+$ ]] || base=100000
    fi
    pct mount "$CTID" >/dev/null || return 0
    owner="$(stat -c '%u' "$mnt" 2>/dev/null || echo "")"
    if [[ "$owner" == "$((base + 65534))" ]]; then
        chown "${base}:${base}" "$mnt"
        info "Fixed the owner of / in the container (the template shipped it as 'nobody')."
    fi
    pct unmount "$CTID" >/dev/null
}

upload_files() {
    [[ ${#UPLOAD_FILES[@]} -gt 0 ]] || return 0
    header "Upload Files"
    local pair src dst
    for pair in "${UPLOAD_FILES[@]}"; do
        src="$(_hook_path "${pair%%:/*}")"
        dst="/${pair#*:/}"
        pct exec "$CTID" -- mkdir -p "$(dirname "$dst")"
        pct push "$CTID" "$src" "$dst"
        success "$src -> $dst"
    done
}

# =============================================================================
#  IN-CONTAINER SETUP
#  Every guest_* function below runs INSIDE the container, not on the host.
#  They are copied into one script (with the settings they need), pushed
#  into the container and run there with 'pct exec'. Nothing is downloaded
#  from this repo at run time: what you read here is what runs.
#  See the result with:  --print-guest-script
# =============================================================================

# Settings the guest functions read.
GUEST_VARS=(
    RED YELLOW GREEN CYAN BOLD RESET
    LOCAL_LANG BASE_PKGS EXTRA_PKGS APT_UPGRADE
    ANSIBLE_USER ANSIBLE_SSH_KEY ADMIN_USER ADMIN_SSH_KEY
    ZSH_DOTFILES DOTFILES_URLS
    POSTFIX_RELAY POSTFIX_RELAYHOST POSTFIX_USER POSTFIX_PASS MAIL_DOMAIN
    UNATTENDED_UPGRADES UU_INCLUDE_UPDATES UU_MAIL UU_AUTO_REBOOT UU_REBOOT_TIME UU_EXTRA_ORIGINS
    REMOVE_SNAPD DISABLE_IPV6 PIP_BREAK_SYSTEM_PACKAGES SUDO_COREDUMP_FIX
)

# The guest functions are only ever called from the generated script.
# shellcheck disable=SC2329,SC2317

guest_apt() {
    apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# Wait for an address, then for the package mirrors to answer.
guest_wait_network() {
    header "Network"
    # Waits for every interface at boot and can stall a container for
    # two minutes. Containers get their network from Proxmox, so it is
    # not needed.
    systemctl disable -q --now systemd-networkd-wait-online.service &>/dev/null || true
    # Ride out a flaky mirror instead of failing the whole build.
    echo 'Acquire::Retries "3";' > /etc/apt/apt.conf.d/80-retries

    local i
    for i in {1..30}; do
        [[ -n "$(hostname -I 2>/dev/null)" ]] && break
        sleep 2
    done
    [[ -n "$(hostname -I 2>/dev/null)" ]] \
        || die "The container got no IP address after 60 seconds. Check the bridge, VLAN and DHCP."
    success "Address: $(hostname -I)"

    for i in {1..10}; do
        if apt-get update -qq; then
            success "Package lists updated."
            return 0
        fi
        warn "apt-get update failed (try $i of 10). Retrying..."
        sleep 3
    done
    die "apt-get update keeps failing. Check the container's internet access and DNS."
}

guest_base() {
    header "Packages"
    local raw=() pkgs=() p
    IFS=', ' read -ra raw <<< "${BASE_PKGS},${EXTRA_PKGS}"
    for p in "${raw[@]}"; do
        [[ -n "$p" ]] && pkgs+=("$p")
    done

    # A local apt cache, if the network advertises one, speeds up the rest.
    if [[ " ${pkgs[*]} " == *" auto-apt-proxy "* ]]; then
        guest_apt install --no-install-recommends auto-apt-proxy
        apt-get update -qq
    fi

    if _is_yes "$APT_UPGRADE"; then
        guest_apt dist-upgrade
        success "Packages upgraded."
    fi

    guest_apt install --no-install-recommends locales "${pkgs[@]}"
    success "Installed: ${pkgs[*]}"

    header "Locale"
    local charset="${LOCAL_LANG#*.}"
    [[ "$charset" == "$LOCAL_LANG" ]] && charset="UTF-8"
    charset="${charset%%@*}"
    sed -i "s/^# *\(${LOCAL_LANG//./\\.} ${charset}\)\$/\1/" /etc/locale.gen
    grep -qxF "${LOCAL_LANG} ${charset}" /etc/locale.gen \
        || echo "${LOCAL_LANG} ${charset}" >> /etc/locale.gen
    locale-gen
    update-locale LANG="$LOCAL_LANG"
    success "Locale: $LOCAL_LANG"
}

# SSH host keys and the mail sender name belong to one container. A clone
# of a template must get its own, so this runs at every boot (it only
# changes anything when something is missing or the hostname changed).
guest_identity() {
    cat > /usr/local/sbin/ct-identity <<'EOS'
#!/bin/sh
# Installed by create-lxc.sh. Runs at every boot (ct-identity.service).
set -eu

# 1. SSH host keys: a template has none, so each clone makes its own.
if command -v ssh-keygen >/dev/null 2>&1 && ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    ssh-keygen -A
fi

# 2. Mail is sent as <hostname>@<domain>: follow the current hostname.
if [ -r /etc/ct-mail-domain ] && command -v postconf >/dev/null 2>&1; then
    host="$(hostname)"
    from="${host}@$(cat /etc/ct-mail-domain)"
    printf '/.+/    %s\n' "$from" > /etc/postfix/sender_canonical_maps
    printf '/From:.*/ REPLACE From: %s\n' "$from" > /etc/postfix/header_check
    postconf -e "myhostname=${host}"
fi
EOS
    chmod 755 /usr/local/sbin/ct-identity

    cat > /etc/systemd/system/ct-identity.service <<'EOS'
[Unit]
Description=Per-container identity (SSH host keys, mail sender name)
Before=ssh.service sshd.service ssh.socket postfix.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ct-identity
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOS
    systemctl daemon-reload
    systemctl enable -q ct-identity.service
}

guest_tweaks() {
    if _is_yes "$REMOVE_SNAPD"; then
        header "Remove snapd"
        if dpkg-query -W -f='${Status}' snapd 2>/dev/null | grep -q "ok installed"; then
            guest_apt autoremove --purge snapd
            rm -rf /var/cache/snapd /root/snap
        fi
        # A negative priority means apt never installs it, even as a dependency.
        printf 'Package: snapd\nPin: release *\nPin-Priority: -10\n' > /etc/apt/preferences.d/no-snapd
        success "snapd removed and pinned."
    fi

    if _is_yes "$DISABLE_IPV6"; then
        header "Disable IPv6"
        printf '%s\n' \
            'net.ipv6.conf.all.disable_ipv6 = 1' \
            'net.ipv6.conf.default.disable_ipv6 = 1' > /etc/sysctl.d/99-disable-ipv6.conf
        sysctl -q -p /etc/sysctl.d/99-disable-ipv6.conf || warn "Could not apply now. It applies at the next boot."
        success "IPv6 disabled."
    fi

    if _is_yes "$PIP_BREAK_SYSTEM_PACKAGES"; then
        printf '[global]\nbreak-system-packages = true\n' > /etc/pip.conf
        success "pip may install system-wide (/etc/pip.conf)."
    fi

    if _is_yes "$SUDO_COREDUMP_FIX"; then
        grep -qsxF 'Set disable_coredump false' /etc/sudo.conf \
            || echo 'Set disable_coredump false' >> /etc/sudo.conf
        success "sudo: disable_coredump false."
    fi
}

guest_zsh() {
    _is_yes "$ZSH_DOTFILES" || return 0
    header "zsh and dotfiles"
    guest_apt install zsh zsh-antigen git curl ca-certificates

    local url
    for url in "${DOTFILES_URLS[@]}"; do
        curl -fsSL --retry 3 -o "/etc/skel/${url##*/}" "$url"
        success "/etc/skel/${url##*/}"
    done

    # root exists already, so it doesn't get /etc/skel by itself.
    # -n: never replace a file root already has.
    cp -a -n /etc/skel/. /root/ 2>/dev/null || true
    chsh -s "$(command -v zsh)" root
    success "root now uses zsh."
}

# Usage: guest_add_user <name> <shell> <system: yes|no> <ssh keys>
# Key-only login (password locked) and passwordless sudo.
guest_add_user() {
    local name="$1" shell="$2" system="$3" pubkeys="$4" home
    if id "$name" &>/dev/null; then
        info "User '$name' already exists. Updating its key and sudo rule."
    elif _is_yes "$system"; then
        useradd -r -m -s "$shell" "$name"
    else
        useradd -m -s "$shell" "$name"
    fi
    passwd -l "$name" >/dev/null

    home="$(getent passwd "$name" | cut -d: -f6)"
    install -d -m 700 -o "$name" -g "$name" "$home/.ssh"
    printf '%s\n' "$pubkeys" > "$home/.ssh/authorized_keys"
    chown "$name:$name" "$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"

    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$name" > "/etc/sudoers.d/$name"
    chmod 0440 "/etc/sudoers.d/$name"
    visudo -cf "/etc/sudoers.d/$name" >/dev/null
    success "User '$name' ready (SSH key only, passwordless sudo)."
}

guest_users() {
    [[ -n "$ANSIBLE_USER" || -n "$ADMIN_USER" ]] || return 0
    header "Users"
    guest_apt install sudo openssh-server

    if [[ -n "$ANSIBLE_USER" ]]; then
        guest_add_user "$ANSIBLE_USER" /bin/bash yes "$ANSIBLE_SSH_KEY"
    fi
    if [[ -n "$ADMIN_USER" ]]; then
        local shell=/bin/bash
        _is_yes "$ZSH_DOTFILES" && shell="$(command -v zsh)"
        guest_add_user "$ADMIN_USER" "$shell" no "$ADMIN_SSH_KEY"
        usermod -aG sudo "$ADMIN_USER"
    fi
}

guest_postfix() {
    _is_yes "$POSTFIX_RELAY" || return 0
    header "Postfix relay"
    local host
    host="$(hostname)"

    debconf-set-selections <<EOF
postfix postfix/main_mailer_type select Internet Site
postfix postfix/mailname string ${host}.${MAIL_DOMAIN}
EOF
    guest_apt install postfix libsasl2-modules ca-certificates bsd-mailx

    ( umask 077
      printf '%s %s:%s\n' "$POSTFIX_RELAYHOST" "$POSTFIX_USER" "$POSTFIX_PASS" > /etc/postfix/sasl_passwd )
    postmap /etc/postfix/sasl_passwd
    chmod 0600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db

    postconf -e "mydestination=\$myhostname, localhost.${MAIL_DOMAIN}, localhost"
    postconf -e "mynetworks=127.0.0.0/8"
    postconf -e "inet_interfaces=loopback-only"
    postconf -e "relayhost=${POSTFIX_RELAYHOST}"
    postconf -e "smtp_sasl_auth_enable=yes"
    postconf -e "smtp_sasl_security_options=noanonymous"
    postconf -e "smtp_sasl_password_maps=hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_tls_security_level=encrypt"
    postconf -e "smtp_tls_CAfile=/etc/ssl/certs/ca-certificates.crt"
    postconf -e "smtp_tls_session_cache_timeout=3600s"
    postconf -e "readme_directory=no"
    postconf -e "sender_canonical_classes=envelope_sender, header_sender"
    postconf -e "sender_canonical_maps=regexp:/etc/postfix/sender_canonical_maps"
    postconf -e "smtp_header_checks=regexp:/etc/postfix/header_check"
    _is_yes "$DISABLE_IPV6" && postconf -e "inet_protocols=ipv4"

    # ct-identity writes the sender maps from the current hostname.
    printf '%s\n' "$MAIL_DOMAIN" > /etc/ct-mail-domain
    /usr/local/sbin/ct-identity
    systemctl restart postfix
    success "Postfix relays through ${POSTFIX_RELAYHOST} as ${host}@${MAIL_DOMAIN}."
}

guest_unattended_upgrades() {
    _is_yes "$UNATTENDED_UPGRADES" || return 0
    header "Unattended upgrades"
    guest_apt install unattended-upgrades

    printf '%s\n' \
        'APT::Periodic::Update-Package-Lists "1";' \
        'APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades

    # Ubuntu names the updates pocket by archive, Debian by codename.
    local updates_key="codename" o
    [[ "${ID:-}" == "ubuntu" ]] && updates_key="archive"

    # ${distro_id} and ${distro_codename} are filled in by unattended-upgrades.
    # shellcheck disable=SC2016
    {
        echo '// Written by create-lxc.sh. These are ADDED to the distro defaults'
        echo '// in 50unattended-upgrades (the security origins).'
        echo 'Unattended-Upgrade::Origins-Pattern {'
        _is_yes "$UU_INCLUDE_UPDATES" \
            && printf '        "origin=${distro_id},%s=${distro_codename}-updates";\n' "$updates_key"
        for o in "${UU_EXTRA_ORIGINS[@]}"; do
            printf '        "%s";\n' "$o"
        done
        echo '};'
        echo ''
        if [[ -n "$UU_MAIL" ]]; then
            printf 'Unattended-Upgrade::Mail "%s";\n' "$UU_MAIL"
            echo 'Unattended-Upgrade::MailReport "on-change";'
        fi
        echo 'Unattended-Upgrade::Remove-Unused-Dependencies "true";'
        printf 'Unattended-Upgrade::Automatic-Reboot "%s";\n' "$UU_AUTO_REBOOT"
        printf 'Unattended-Upgrade::Automatic-Reboot-Time "%s";\n' "$UU_REBOOT_TIME"
    } > /etc/apt/apt.conf.d/51unattended-upgrades
    success "Unattended upgrades on (/etc/apt/apt.conf.d/51unattended-upgrades)."
}

# Always runs last: leave a tidy system.
guest_cleanup() {
    header "Cleanup"
    guest_apt autoremove --purge
    apt-get clean
    success "Package cache cleared."
}

# Template only: remove everything that must be unique per clone.
guest_seal() {
    header "Prepare for templating"
    rm -f /etc/ssh/ssh_host_*
    : > /etc/machine-id
    [[ -L /var/lib/dbus/machine-id ]] || rm -f /var/lib/dbus/machine-id
    rm -rf /var/lib/apt/lists/*
    rm -f /var/lib/dhcp/*.leases
    rm -f /root/.bash_history /root/.zsh_history /home/*/.bash_history /home/*/.zsh_history
    find /tmp /var/tmp -mindepth 1 -delete 2>/dev/null || true
    find /var/log -type f \( -name '*.log' -o -name 'wtmp' -o -name 'btmp' -o -name 'lastlog' \) \
        -exec truncate -s 0 {} + 2>/dev/null || true
    journalctl --rotate &>/dev/null || true
    journalctl --vacuum-time=1s &>/dev/null || true
    success "SSH host keys, machine-id, logs and caches cleared."
}

# Entry point of the generated script.
# Usage: <script> provision | finish | seal
guest_main() {
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
    # ID and VERSION_CODENAME of this container's OS.
    # shellcheck source=/dev/null
    . /etc/os-release

    case "${1:-}" in
        provision)
            guest_wait_network
            guest_base
            guest_identity
            guest_tweaks
            guest_zsh
            guest_users
            guest_postfix
            guest_unattended_upgrades
            ;;
        finish)
            guest_cleanup
            ;;
        seal)
            guest_cleanup
            guest_seal
            ;;
        *)
            die "Usage: $0 provision | finish | seal"
            ;;
    esac
}

# Prints the script that runs inside the container.
build_guest_script() {
    local fn
    echo '#!/bin/bash'
    echo "# Generated by ${SCRIPT_NAME}. Runs inside the container."
    echo 'set -Eeuo pipefail'
    echo ''
    declare -p "${GUEST_VARS[@]}"
    echo ''
    declare -f info success warn error die header _is_yes
    while read -r fn; do
        declare -f "$fn"
    done < <(declare -F | awk '$3 ~ /^guest_/ {print $3}')
    echo ''
    echo 'guest_main "$@"'
}

push_guest_script() {
    ( umask 077; build_guest_script > "$TMP_DIR/setup.sh" )
    pct push "$CTID" "$TMP_DIR/setup.sh" "$GUEST_SCRIPT" --perms 0700
}

# Usage: run_guest provision | finish | seal
run_guest() {
    pct exec "$CTID" -- bash "$GUEST_SCRIPT" "$1"
}

run_hooks() {
    [[ ${#PROVISION_SCRIPTS[@]} -gt 0 ]] || return 0
    local s src hook=/root/.create-lxc-hook
    for s in "${PROVISION_SCRIPTS[@]}"; do
        src="$(_hook_path "$s")"
        header "Hook: $s"
        pct push "$CTID" "$src" "$hook" --perms 0700
        if [[ "$(head -c 2 "$src")" == "#!" ]]; then
            pct exec "$CTID" -- "$hook"
        else
            pct exec "$CTID" -- /bin/sh "$hook"
        fi
        pct exec "$CTID" -- rm -f "$hook"
        success "Hook finished: $s"
    done
}

# =============================================================================
#  FINISH
# =============================================================================
CT_IP=""

finish_ct() {
    if _is_yes "$CONVERT_TO_TEMPLATE"; then
        run_guest seal
        pct exec "$CTID" -- rm -f "$GUEST_SCRIPT"

        header "Convert to Proxmox Template"
        pct shutdown "$CTID" --timeout 120 || pct stop "$CTID"
        pct template "$CTID"
        TEMPLATE_CONVERTED="yes"
        success "Container $CTID converted to template."
    else
        run_guest finish
        pct exec "$CTID" -- rm -f "$GUEST_SCRIPT"
        CT_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')" || true
    fi
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    if [[ "$PRINT_GUEST" == "yes" ]]; then
        validate_features
        build_guest_script
        return
    fi

    echo ""
    echo -e "${BOLD}Proxmox LXC Creator${RESET}"
    echo "==================="

    # 1. Checks and questions (nothing is changed yet)
    proxmox_check
    validate_features
    select_os
    select_storage
    get_valid_ctid
    user_prompts
    validate_config
    print_summary

    # /run is in memory: the setup script (and any mail password in it)
    # never touches the host's disk.
    TMP_DIR="$(mktemp -d /run/create-lxc.XXXXXX)"

    # 2. Build the container
    download_template
    replace_old_template
    create_ct

    # 3. Set it up from the inside
    upload_files
    push_guest_script
    run_guest provision
    run_hooks
    finish_ct

    # Build finished: from here on, nothing may remove the container on exit.
    CTID_CREATED=""

    # --- Done ---
    echo ""
    if [[ "$TEMPLATE_CONVERTED" == "yes" ]]; then
        success "Template '$CT_NAME' (ID: $CTID) is ready to clone."
        info "Clone it:  pct clone $CTID <new id> --hostname <name> --full 1"
    else
        success "Container '$CT_NAME' (ID: $CTID) is running${CT_IP:+ at $CT_IP}."
        info "Log in from the host:  pct enter $CTID"
        info "Make it a template later (see TEMPLATES AND CLONES in this script first):  pct template $CTID"
    fi

    if [[ -n "$PROFILE_PATH" ]]; then
        info "Re-use with: ./${SCRIPT_NAME} --config ${PROFILE_NAME}.conf"
    fi
}

main "$@"
