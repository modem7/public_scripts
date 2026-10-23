#!/bin/bash
# =============================================================================
#  build-templates.sh
#  Holds no secrets: those go in shared.conf (git-ignored).
#
#  Builds modem7's Ubuntu cloud-init templates on a Proxmox host, fully
#  offline, by generating profiles + payload scripts and handing them to
#  the public create-ubuntu-cloud-template.sh via --config.
#
#  Two kinds of config, both git-ignored (copy the .example files):
#    profiles/<t>.conf  VM settings per template: name, tags, packages,
#                       snapd, IPv6, desktop, RAM, disk, ...
#    shared.conf        settings for every template: mail, ansible,
#                       dotfiles, tweaks, plus host defaults (storage,
#                       bridge, VLAN, SSH key) a profile can override.
#  This script only wires them together and adds the payloads.
#
#    base     server
#    extras   server + admin tools
#    desktop  GNOME + RDP
#
#  Usage (as root, on the Proxmox host):
#    ./build-templates.sh base|extras|desktop|all [-- <create-script args>]
#    ./build-templates.sh extras --verify     # build, then verify-clone.sh it
#      (--send-test-mail <addr> and --keep are passed on; only with --verify)
#    ./build-templates.sh --generate-only     # write files, don't build
#    ./build-templates.sh --help              # full help, no root needed
#
#  Default create-script args: --unattended --vmid 52000 --auto-vmid --template
#
#  Still manual, on the FIRST clone of each template:
#    - Postfix test: echo test | mail -s "test from $(hostname)" <you>
#    - Desktop: log in on the console once, log out, then RDP in with the
#      login from /root/rdp-credentials.txt.
# =============================================================================
set -Eeuo pipefail

# =============================================================================
#  SETTINGS
#  Your values live in shared.conf next to this script (or the file named
#  by $SHARED_CONF). It is git-ignored: copy shared.conf.example to start.
#  Anything not set there keeps the default below. Per-template VM settings
#  live in profiles/<t>.conf, not here.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="${PROFILES_DIR:-$SCRIPT_DIR/profiles}"

PUBLIC_SCRIPT="${PUBLIC_SCRIPT:-/root/create-ubuntu-cloud-template.sh}"   # refreshed from GitHub each run
# Tried in order: the script's own folder (public_scripts #35), then where it
# lived before that, so this works whether or not that move is merged.
PUBLIC_SCRIPT_URLS=(
    "https://raw.githubusercontent.com/modem7/public_scripts/master/Bash/Proxmox%20Scripts/Ubuntu%20Cloud%20Template/create-ubuntu-cloud-template.sh"
    "https://raw.githubusercontent.com/modem7/public_scripts/master/Bash/Proxmox%20Scripts/create-ubuntu-cloud-template.sh"
)
ZSWAP_SCRIPT_URL="https://raw.githubusercontent.com/modem7/public_scripts/master/Bash/Server%20scripts/zram-to-zswap.sh"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/template-build}"     # generated profiles + payloads (root-only)
VERIFY_CLONE="${VERIFY_CLONE:-$SCRIPT_DIR/verify-clone.sh}"   # run by --verify

# --- Host defaults: written into every profile, which can override them ---
DISTRO_VER="resolute"
DISK_STOR=""                       # blank = the host's only VM-disk storage (local-lvm / local-zfs)
NET_BRIDGE="vmbr0"
VLAN=""
CI_SSH_KEY=""                      # cloud-init user's key(s), or "github.com/<user>"; written as SSH_KEY
CLOUD_PASSWORD=""                  # blank = generated each build, shown at the end

ANSIBLE_SSH_PUBKEY=""              # required

MAIL_RELAY="gmail"                 # gmail, custom (MAIL_RELAY_HOST/PORT) or none (local only)
MAIL_RELAY_HOST=""                 # custom only
MAIL_RELAY_PORT=""                 # custom only: 587, 465 or 25
MAIL_RELAY_USER=""                 # SMTP login; required for gmail, blank (custom) = no login
MAIL_RELAY_PASSWORD=""             # required when MAIL_RELAY_USER is set
MAIL_ROOT_TO=""                    # root's mail; blank = MAIL_RELAY_USER if it has an @
MAIL_SENDER=""                     # blank = no sender rewrite
MAIL_DOMAIN=""                     # required; mail is sent as user@<short hostname>.MAIL_DOMAIN
GMAIL_USER=""                      # old names for MAIL_RELAY_USER / MAIL_RELAY_PASSWORD
GMAIL_APP_PASSWORD=""

UU_MAIL=""                         # blank = no unattended-upgrades mail

DOTFILES_RAW=""                    # blank = no dotfiles in /etc/skel
DOTFILES=(.p10k.zsh .zshrc .zshenv)
WAKATIME_CFG=""                    # whole ~/.wakatime.cfg; blank = none

# --- System tweaks ---
LOGIN_SHELL="/usr/bin/zsh"             # clone's login user + new users; blank = leave bash.
#   /usr/bin, not /bin: your dotfiles compare $SHELL with `which zsh`.
NEEDRESTART_MODE="a"               # a = restart services itself, l = list only,
                                   # i = ask; blank = leave the OS default (i)
HIDE_PRO_ADVERTS="yes"             # no Ubuntu Pro/ESM adverts in apt or the login message
# Journal size cap, re-worked out on every boot (so a bigger disk is picked up):
#   the smaller of JOURNAL_MAX_MB and JOURNAL_MAX_PERCENT % of the filesystem.
#   OS default = 10% of the filesystem, capped at 4G. Blank JOURNAL_MAX_MB = OS default.
JOURNAL_MAX_MB="1024"
JOURNAL_MAX_PERCENT="10"

# --- Packages the payloads need ---
# Added to every profile's EXTRA_VIRT_PKGS (only those it lacks), so editing
# a profile can't break Postfix, unattended upgrades or the login shell.
# bsd-mailx is installed by the postfix payload, AFTER the debconf preseed:
# installed earlier it would pull postfix in with the default answers.
# libsasl2-modules is added after shared.conf is read, if the relay logs in.
BUILDER_PKGS=(unattended-upgrades zsh)

# =============================================================================
#  HELP
#  Checked before the config and root checks, so --help works anywhere.
# =============================================================================
usage() {
    cat <<'EOF'
build-templates.sh: build Ubuntu cloud-init templates on a Proxmox host.

Generates the profiles and payload scripts for three templates (base,
extras, desktop), then runs create-ubuntu-cloud-template.sh --config
<profile> to build each one. Each profile is assembled from shared.conf
and your profiles/<target>.conf.

USAGE
  ./build-templates.sh base|extras|desktop|all [--verify [--keep]
                       [--send-test-mail <addr>]] [-- <create-script args>]
  ./build-templates.sh --generate-only
  ./build-templates.sh -h|--help|help

ARGUMENTS
  base              Build the base template.
  extras            Build the extras template.
  desktop           Build the desktop template.
  all               Build all three: base, extras, then desktop.
  --generate-only   Write all profiles and payloads to OUT_DIR. Build nothing.
  --verify          After each template is built, run verify-clone.sh on
                    it with --profile <target> --config <shared.conf>.
                    A verify that fails or cannot run does not stop the
                    other targets, but the exit code is then 1. Not with
                    --generate-only.
  --send-test-mail <addr>
                    Passed to verify-clone.sh. Only with --verify.
  --keep            Passed to verify-clone.sh: each verify clone is left
                    running, and its VMID is shown in the summary. Only
                    with --verify.
  -- <args>         Passed as they are to create-ubuntu-cloud-template.sh.
                    Default: --unattended --vmid 52000 --auto-vmid --template
                    Any args given replace the whole default list, e.g.
                    -- --unattended --vmid 53000 --auto-vmid --template
  -h, --help, help  Show this help.

TEMPLATES
  Name, tags, packages and VM settings come from profiles/<target>.conf.
  The .example profiles give:
  base      ubuntu-2604-base. Server. aptitude, auto-apt-proxy,
            libsasl2-modules, tuned, tuned-utils, unattended-upgrades, zsh.
  extras    ubuntu-2604-extras. base plus admin tools: acl, bind9-dnsutils,
            cifs-utils, curl, git, htop, needrestart, net-tools, plocate,
            unzip.
  desktop   ubuntu-2604-desktop. extras plus GNOME and RDP. Keeps snapd.
            4096 MB RAM, 40G disk.
  All three get: Postfix (relay set by MAIL_RELAY), an ansible user with
  sudo, unattended upgrades and zram to zswap on first boot. Also, each
  as set in shared.conf: a journald size cap, dotfiles in /etc/skel, and
  the login shell, needrestart and Pro advert tweaks.

CONFIG
  Two kinds of file, both git-ignored. Copy the .example next to each.

  profiles/<target>.conf (one per template, in PROFILES_DIR)
    VM settings, as for create-ubuntu-cloud-template.sh --config (see
    profile.conf.example): TEMPL_NAME_DEFAULT, TAG, EXTRA_VIRT_PKGS,
    REMOVE_SNAPD, DISABLE_IPV6, TUNED_PROFILE, GROW_IMAGE_FIRST,
    UNATTENDED_UPGRADES, UU_AUTOCLEAN_DAYS, ENABLE_FSTRIM_TIMER,
    CONVERT_TO_TEMPLATE, and for the desktop DESKTOP, DESKTOP_RDP,
    TABLET, VGA, MEM, BALLOON, DISK_SIZE. No secrets.
    Must exist for each target built and pass bash -n.

  shared.conf (settings for every template)
    Looked up in this order: SHARED_CONF, BUILD_CONF, shared.conf next
    to this script, then the old build-templates.conf (with a warning).
    Unset keys keep their defaults. It holds secrets: chmod 600 it and
    never commit it. PKGS_* and TAG_BASE are no longer read: set
    EXTRA_VIRT_PKGS and TAG in the profiles.

  How OUT_DIR/<target>.conf is put together, in order:
    1. Host defaults from shared.conf (DISTRO_VER, DISK_STOR, NET_BRIDGE,
       VLAN, CI_SSH_KEY as SSH_KEY, CLOUD_PASSWORD if set).
    2. profiles/<target>.conf as it is, so it can override step 1.
       Override the SSH key there with SSH_KEY, not CI_SSH_KEY.
    3. The payloads, appended with +=: UPLOAD_FILES, CUSTOMIZE_SCRIPTS,
       FIRSTBOOT_SCRIPTS, EXTRA_VC_ARGS, and any of unattended-upgrades,
       zsh and (if the relay logs in) libsasl2-modules missing from
       EXTRA_VIRT_PKGS.

  shared.conf, required:
    ANSIBLE_SSH_PUBKEY   Public key for the ansible user.
    MAIL_DOMAIN          Mail is sent as user@<short hostname>.MAIL_DOMAIN.

  shared.conf, mail (default):
    MAIL_RELAY           gmail. One of:
                           gmail   smtp.gmail.com port 587, with a login
                           custom  MAIL_RELAY_HOST and MAIL_RELAY_PORT
                           none    no relay: mail stays on the clone
    MAIL_RELAY_HOST      custom only: host name or IPv4 address.
    MAIL_RELAY_PORT      custom only: 587 (STARTTLS, required), 465
                         (TLS from the start), or 25 or any other
                         port (TLS required if there is a login,
                         otherwise TLS if offered).
    MAIL_RELAY_USER      SMTP login. Required for gmail. For custom,
                         blank = no login (an internal relay).
    MAIL_RELAY_PASSWORD  Password for that login (Gmail: an app
                         password). Required when MAIL_RELAY_USER is set.
    MAIL_ROOT_TO         Where root's mail goes. Default: MAIL_RELAY_USER
                         if it is an address, else required (with none,
                         blank = /etc/aliases left alone).
    MAIL_SENDER          blank = no rewrite: mail goes out as
                         user@<fqdn>. Set = every sender rewritten to
                         this address (some relays need it).
    GMAIL_USER and GMAIL_APP_PASSWORD are still read as the old names
    for MAIL_RELAY_USER and MAIL_RELAY_PASSWORD, with a warning.

  shared.conf, host defaults (default):
    DISTRO_VER           resolute
    DISK_STOR            blank = the host's only VM-disk storage
    NET_BRIDGE           vmbr0
    VLAN                 blank
    CI_SSH_KEY           blank (key(s), or github.com/<user>)
    CLOUD_PASSWORD       blank = generated each build, shown at the end

  shared.conf, optional (default):
    UU_MAIL              blank = no unattended-upgrades mail
    DOTFILES_RAW         blank = no dotfiles in /etc/skel
    DOTFILES             .p10k.zsh .zshrc .zshenv
    WAKATIME_CFG         blank = no .wakatime.cfg in /etc/skel
    LOGIN_SHELL          /usr/bin/zsh (blank = leave bash)
    NEEDRESTART_MODE     a (a, l, i, or blank = OS default)
    HIDE_PRO_ADVERTS     yes
    JOURNAL_MAX_MB       1024 (blank = OS default)
    JOURNAL_MAX_PERCENT  10

ENVIRONMENT
  SHARED_CONF            Shared config file.
                         Default: shared.conf next to this script
  BUILD_CONF             Old name for SHARED_CONF, still read.
  PROFILES_DIR           Folder with the <target>.conf profiles.
                         Default: profiles next to this script
  PUBLIC_SCRIPT          Local copy of create-ubuntu-cloud-template.sh.
                         Default: /root/create-ubuntu-cloud-template.sh
  OUT_DIR                Where generated files go.
                         Default: template-build next to this script
  UPDATE_PUBLIC_SCRIPT   no = keep the local PUBLIC_SCRIPT. Default: yes
  VERIFY_CLONE           verify-clone.sh run by --verify. verify-template.sh
                         must be next to it.
                         Default: verify-clone.sh next to this script

OUTPUT
  OUT_DIR/<target>.conf  Profile for each chosen template.
  OUT_DIR/payload/       Payload scripts and files baked into the image.
  Both are root-only and rewritten on every run.

EXAMPLES
  ./build-templates.sh --generate-only
  ./build-templates.sh extras
  ./build-templates.sh all
  ./build-templates.sh all --verify --send-test-mail you@example.com
  ./build-templates.sh base -- --unattended --vmid 53000 --auto-vmid --template
  SHARED_CONF=/root/other.conf ./build-templates.sh desktop
  PROFILES_DIR=/root/profiles ./build-templates.sh all

NOTES
  - Run as root on the Proxmox host, --generate-only included.
  - Each build downloads the latest create-ubuntu-cloud-template.sh from
    GitHub to PUBLIC_SCRIPT, falling back to the copy already there.
  - Each run downloads zram-to-zswap.sh from GitHub.
  - --verify clones each finished template, boots the clone, runs the
    checks in it and removes the clone. The template needs the guest
    agent. It takes a few minutes per template. The new template's VMID
    is the one VMID in qm list after the build that was not there
    before; if there is not exactly one, that verify is skipped and
    counts as failed.
  - Clones kept by --keep stay running until you remove them by hand:
    qm destroy <clone-vmid> --purge
  - Still manual, on the first clone of each template:
      sudo ./verify-template.sh --send-test-mail <address>
    (from a copy inside the clone), check the test mail arrived, and on
    the desktop log in on the console once, log out, then RDP in with the
    login from /root/rdp-credentials.txt.
EOF
}

usage_error() { { echo "Error: $*"; echo; usage; } >&2; exit 1; }

# The target and this script's own options come first. After the target,
# the first other argument (or --) starts the create-script args.
TARGET="" VERIFY=no TEST_MAIL="" KEEP=no
while (( $# )); do
    case "$1" in
        --verify) VERIFY=yes ;;
        --keep)   KEEP=yes ;;
        --send-test-mail)
            [[ -n "${2:-}" ]] || usage_error "--send-test-mail needs an address."
            TEST_MAIL="$2"; shift ;;
        *)  [[ -z "$TARGET" ]] || break
            case "$1" in
                -h|--help|help) usage; exit 0 ;;
                base|extras|desktop|all|--generate-only) TARGET="$1" ;;
                "") usage_error "no target given." ;;
                *)  usage_error "unknown target: $1" ;;
            esac ;;
    esac
    shift
done
[[ -n "$TARGET" ]] || usage_error "no target given."
[[ "$VERIFY" == yes || -z "$TEST_MAIL" ]] || usage_error "--send-test-mail only works with --verify."
[[ "$VERIFY" == yes || "$KEEP" == no ]] || usage_error "--keep only works with --verify."
[[ "$VERIFY" == no || "$TARGET" != --generate-only ]] || usage_error "--verify does not work with --generate-only."
[[ "${1:-}" == "--" ]] && shift
CREATE_ARGS=("$@")

# =============================================================================
info() { echo -e "\033[0;36m[build]\033[0m $*"; }
warn() { echo -e "\033[0;33m[build]\033[0m $*" >&2; }
die()  { echo -e "\033[0;31m[build]\033[0m $*" >&2; exit 1; }

# =============================================================================
#  SHARED CONFIG
#  SHARED_CONF, then BUILD_CONF (old name), then shared.conf here, then the
#  old build-templates.conf. A file named by the environment must exist.
# =============================================================================
if [[ -n "${SHARED_CONF:-}" ]]; then
    :
elif [[ -n "${BUILD_CONF:-}" ]]; then
    SHARED_CONF="$BUILD_CONF"
elif [[ -f "$SCRIPT_DIR/shared.conf" ]]; then
    SHARED_CONF="$SCRIPT_DIR/shared.conf"
elif [[ -f "$SCRIPT_DIR/build-templates.conf" ]]; then
    SHARED_CONF="$SCRIPT_DIR/build-templates.conf"
    warn "Using the old $SHARED_CONF: rename it to shared.conf."
else
    SHARED_CONF="$SCRIPT_DIR/shared.conf"
fi
[[ -f "$SHARED_CONF" ]] || die "Missing $SHARED_CONF (copy shared.conf.example)."
# shellcheck source=/dev/null
source "$SHARED_CONF"

# Settings that moved to the profiles. Ignored if still set.
mapfile -t leftover < <(compgen -v PKGS_ || true)
[[ -v TAG_BASE ]] && leftover+=(TAG_BASE)
(( ${#leftover[@]} == 0 )) \
    || warn "Ignored in $SHARED_CONF (set EXTRA_VIRT_PKGS and TAG in profiles/<t>.conf instead): ${leftover[*]}"
unset leftover

# Mail: old Gmail names, relay presets, root alias. Checked in generate().
if [[ -n "$GMAIL_USER" || -n "$GMAIL_APP_PASSWORD" ]]; then
    warn "GMAIL_USER / GMAIL_APP_PASSWORD are old names: rename them to MAIL_RELAY_USER / MAIL_RELAY_PASSWORD in $SHARED_CONF."
    [[ -n "$MAIL_RELAY_USER" ]] || MAIL_RELAY_USER="$GMAIL_USER"
    [[ -n "$MAIL_RELAY_PASSWORD" ]] || MAIL_RELAY_PASSWORD="$GMAIL_APP_PASSWORD"
fi
MAIL_RELAY="${MAIL_RELAY:-gmail}"
if [[ "$MAIL_RELAY" == gmail ]]; then
    MAIL_RELAY_HOST="smtp.gmail.com"
    MAIL_RELAY_PORT="587"
fi
if [[ "$MAIL_RELAY" != none && -z "$MAIL_ROOT_TO" && "$MAIL_RELAY_USER" == *@* ]]; then
    MAIL_ROOT_TO="$MAIL_RELAY_USER"
fi
# True if the relay logs in (SASL).
relay_login() { [[ "$MAIL_RELAY" != none && -n "$MAIL_RELAY_USER" ]]; }
relay_login && BUILDER_PKGS=(libsasl2-modules "${BUILDER_PKGS[@]}")

# Quote a value so it can be 'source'd back safely.
q() { printf '%q' "$1"; }

# =============================================================================
#  PAYLOADS
#  Each starts with its settings as quoted variables, then a fixed body.
# =============================================================================

write_ansible_payload() {
    {
        echo '#!/bin/bash'
        echo "# Generated by build-templates.sh: ansible user, key, sudo."
        echo "KEY=$(q "$ANSIBLE_SSH_PUBKEY")"
        cat <<'EOF'
set -euo pipefail

id ansible &>/dev/null || useradd --system --create-home --shell /bin/bash ansible
install -d -m 700 -o ansible -g ansible /home/ansible/.ssh
printf '%s\n' "$KEY" > /home/ansible/.ssh/authorized_keys
chown ansible:ansible /home/ansible/.ssh/authorized_keys
chmod 600 /home/ansible/.ssh/authorized_keys

printf 'ansible ALL=(root) NOPASSWD:ALL\n' > /etc/sudoers.d/ansible
chmod 0440 /etc/sudoers.d/ansible
if ! visudo -cf /etc/sudoers.d/ansible; then
    rm -f /etc/sudoers.d/ansible
    echo "sudoers file for ansible failed visudo check" >&2
    exit 1
fi
EOF
    } > "$OUT_DIR/payload/ansible.sh"
}

# The body is put together here, per MAIL_RELAY, so the script on the
# image only holds the steps it runs. Settings are quoted variables at the
# top; host and port are checked in generate() before they are written.
# SC2016: the single-quoted $ is payload text, expanded on the image.
# shellcheck disable=SC2016
write_postfix_payload() {
    local relay="" pc=() i
    [[ "$MAIL_RELAY" == none ]] || relay="[$MAIL_RELAY_HOST]:$MAIL_RELAY_PORT"

    # postconf -e arguments, as payload text.
    if [[ -n "$relay" ]]; then
        pc+=('"relayhost=$relay"')
        case "$MAIL_RELAY_PORT" in
            587) pc+=('"smtp_tls_security_level=encrypt"') ;;
            465) pc+=('"smtp_tls_security_level=encrypt"' '"smtp_tls_wrappermode=yes"') ;;
            *)   # With a login, never fall back to plain text.
                 if relay_login; then pc+=('"smtp_tls_security_level=encrypt"')
                 else pc+=('"smtp_tls_security_level=may"'); fi ;;
        esac
        pc+=('"smtp_tls_CAfile=/etc/ssl/certs/ca-certificates.crt"')
    fi
    if relay_login; then
        pc+=('"smtp_sasl_auth_enable=yes"'
             '"smtp_sasl_security_options=noanonymous"'
             '"smtp_sasl_password_maps=$db:/etc/postfix/sasl/sasl_passwd"')
    fi
    if [[ -n "$MAIL_SENDER" ]]; then
        pc+=('"sender_canonical_classes=envelope_sender, header_sender"'
             '"sender_canonical_maps=static:$MAIL_SENDER"')
    fi
    pc+=('"inet_interfaces=loopback-only"'
         '"inet_protocols=ipv4"'
         '"mynetworks=127.0.0.0/8"'
         '"mydomain=$MAIL_DOMAIN"'
         '"myhostname=$fqdn"'
         '"myorigin=/etc/mailname"'
         "'mydestination=\$myhostname, localhost.\$mydomain, localhost'"
         '"maximal_queue_lifetime=1d"'
         '"bounce_queue_lifetime=1d"')

    {
        echo '#!/bin/bash'
        echo "# Generated by build-templates.sh: postfix, MAIL_RELAY=$MAIL_RELAY."
        if relay_login; then
            echo "MAIL_RELAY_USER=$(q "$MAIL_RELAY_USER")"
            echo "MAIL_RELAY_PASSWORD=$(q "$MAIL_RELAY_PASSWORD")"
        fi
        echo "MAIL_DOMAIN=$(q "$MAIL_DOMAIN")"
        [[ -z "$MAIL_ROOT_TO" ]] || echo "MAIL_ROOT_TO=$(q "$MAIL_ROOT_TO")"
        [[ -z "$MAIL_SENDER" ]] || echo "MAIL_SENDER=$(q "$MAIL_SENDER")"
        cat <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string localhost" | debconf-set-selections
apt-get install -y -q postfix bsd-mailx

EOF
        [[ -z "$relay" ]] || echo "relay=\"$relay\""
        relay_login && echo 'db="$(postconf -h default_database_type)"   # hash or lmdb'
        cat <<'EOF'
# Placeholder until first boot: no clone is called localhost, so
# postfix-identity always re-stamps this with the clone's real name.
fqdn="localhost.${MAIL_DOMAIN}"
echo "$fqdn" > /etc/mailname

EOF
        if relay_login; then
            cat <<'EOF'
install -d -m 755 /etc/postfix/sasl
( umask 077; printf '%s %s:%s\n' "$relay" "$MAIL_RELAY_USER" "$MAIL_RELAY_PASSWORD" > /etc/postfix/sasl/sasl_passwd )
postmap "$db:/etc/postfix/sasl/sasl_passwd"
chmod 600 /etc/postfix/sasl/sasl_passwd*

EOF
        fi
        if [[ -n "$MAIL_SENDER" ]]; then
            echo '# Every sender (envelope and From header) is rewritten to MAIL_SENDER.'
        else
            echo '# No sender rewrite: mail goes out as the natural user@<fqdn>.'
        fi
        echo "# Short queue lifetimes so an undeliverable message can't loop for days."
        echo "postconf -e \\"
        for (( i = 0; i < ${#pc[@]} - 1; i++ )); do
            echo "    ${pc[i]} \\"
        done
        echo "    ${pc[-1]}"
        if [[ -n "$relay" ]]; then
            cat <<'EOF'
# "Local only" sets these to error, which bounces every outgoing mail.
postconf -X default_transport relay_transport
EOF
        else
            cat <<'EOF'
# MAIL_RELAY=none: "Local only" stays as it is, so mail never leaves.
EOF
        fi
        echo
        if [[ -n "$MAIL_ROOT_TO" ]]; then
            cat <<'EOF'
# Root's local mail (bounces, users' cron jobs) goes to MAIL_ROOT_TO.
grep -q '^root:' /etc/aliases 2>/dev/null || printf 'root: %s\n' "$MAIL_ROOT_TO" >> /etc/aliases
EOF
        fi
        cat <<'EOF'
newaliases

# The chroot copy of resolv.conf must be root-owned, or postfix warns.
[[ -f /var/spool/postfix/etc/resolv.conf ]] && chown root:root /var/spool/postfix/etc/resolv.conf

# No cron mail from /etc/crontab. Users' own crontabs are not affected.
if [[ -f /etc/crontab ]] && ! grep -q '^MAILTO=' /etc/crontab; then
    n="$(grep -nE '^(SHELL|PATH)=' /etc/crontab | tail -1 | cut -d: -f1 || true)"
    if [[ -n "$n" ]]; then
        sed -i "${n}a MAILTO=\"\"" /etc/crontab
    else
        sed -i '1i MAILTO=""' /etc/crontab
    fi
fi
EOF
    } > "$OUT_DIR/payload/postfix.sh"

    # Runs on every boot via cloud-init's per-boot scripts: after cloud-init
    # has set the hostname, with no systemd ordering to get wrong. No-op
    # unless the hostname changed (i.e. on a new clone, or after a rename).
    {
        echo '#!/bin/bash'
        echo "# Generated by build-templates.sh: stamp this clone's name into postfix."
        echo "MAIL_DOMAIN=$(q "$MAIL_DOMAIN")"
        cat <<'EOF'
set -euo pipefail

fqdn="$(hostname -s).${MAIL_DOMAIN}"
[[ "$(cat /etc/mailname 2>/dev/null)" == "$fqdn" ]] && exit 0

echo "$fqdn" > /etc/mailname
postconf -e "myhostname=$fqdn"
systemctl reload postfix 2>/dev/null || true
echo "postfix-identity: sending as <user>@$fqdn"
EOF
    } > "$OUT_DIR/payload/postfix-identity"
}

write_uu_origins() {
    cat > "$OUT_DIR/payload/51unattended-upgrades" <<EOF
// Generated by build-templates.sh
// #clear: this file is the whole list, not added to 50unattended-upgrades.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;

Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}:\${distro_codename}-updates";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
    "Docker:\${distro_codename}";
    "packagecloud.io/crowdsec/crowdsec:\${distro_codename}";
    "Jamie Cameron:stable";
    "LP-PPA-ansible-ansible:\${distro_codename}";
    "Artifactory:\${distro_codename}";
    "packagecloud.io/netdata/netdata-repoconfig:\${distro_codename}";
};

Unattended-Upgrade::Origins-Pattern {
    "origin=gh,codename=main";
};

Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    if [[ -n "$UU_MAIL" ]]; then
        printf 'Unattended-Upgrade::Mail "%s";\nUnattended-Upgrade::MailReport "on-change";\n' \
            "$UU_MAIL" >> "$OUT_DIR/payload/51unattended-upgrades"
    fi
}

write_skel_payload() {
    {
        echo '#!/bin/bash'
        echo "# Generated by build-templates.sh: dotfiles + WakaTime in /etc/skel."
        echo "DOTFILES_RAW=$(q "$DOTFILES_RAW")"
        echo "DOTFILES=($(for f in "${DOTFILES[@]}"; do printf '%q ' "$f"; done))"
        echo "WAKATIME_CFG=$(q "$WAKATIME_CFG")"
        cat <<'EOF'
set -euo pipefail

if [[ -n "$DOTFILES_RAW" ]]; then
    for f in "${DOTFILES[@]}"; do
        curl -fsSL --retry 3 -o "/etc/skel/$f" "$DOTFILES_RAW/$f"
    done
fi

if [[ -n "$WAKATIME_CFG" ]]; then
    ( umask 077; printf '%s\n' "$WAKATIME_CFG" > /etc/skel/.wakatime.cfg )
fi
EOF
    } > "$OUT_DIR/payload/skel.sh"
}

write_tweaks_payload() {
    {
        echo '#!/bin/bash'
        echo "# Generated by build-templates.sh: shell, needrestart, Pro adverts."
        echo "LOGIN_SHELL=$(q "$LOGIN_SHELL")"
        echo "NEEDRESTART_MODE=$(q "$NEEDRESTART_MODE")"
        echo "HIDE_PRO_ADVERTS=$(q "$HIDE_PRO_ADVERTS")"
        cat <<'EOF'
set -euo pipefail

if [[ -n "$LOGIN_SHELL" ]]; then
    [[ -x "$LOGIN_SHELL" ]] || { echo "LOGIN_SHELL $LOGIN_SHELL not installed" >&2; exit 1; }
    # The clone's cloud-init user (merged into cloud.cfg's default_user).
    cat > /etc/cloud/cloud.cfg.d/90-login-shell.cfg <<CFG
# Generated by build-templates.sh
system_info:
  default_user:
    shell: $LOGIN_SHELL
CFG
    # Users added later with adduser or useradd.
    sed -i "s|^#\?DSHELL=.*|DSHELL=$LOGIN_SHELL|" /etc/adduser.conf
    useradd -D -s "$LOGIN_SHELL"
fi

if [[ -n "$NEEDRESTART_MODE" ]]; then
    mkdir -p /etc/needrestart/conf.d
    printf '# Generated by build-templates.sh\n$nrconf{restart} = %s;\n' "'$NEEDRESTART_MODE'" \
        > /etc/needrestart/conf.d/50-restart-mode.conf
fi

if [[ "$HIDE_PRO_ADVERTS" == "yes" ]]; then
    # apt: "x updates could be installed with Ubuntu Pro" etc.
    hook=/etc/apt/apt.conf.d/20apt-esm-hook.conf
    [[ -e "$hook" ]] && dpkg-divert --quiet --local --rename --divert "$hook.disabled" --add "$hook"
    command -v pro >/dev/null && pro config set apt_news=false >/dev/null 2>&1 || true
    # Login message: news + Pro status. statoverride survives package updates.
    [[ -f /etc/default/motd-news ]] && sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
    systemctl disable motd-news.timer 2>/dev/null || true
    f=/etc/update-motd.d/91-contract-ua-esm-status
    [[ -e "$f" ]] && ! dpkg-statoverride --list "$f" >/dev/null && dpkg-statoverride --update --add root root 0644 "$f"
fi
exit 0
EOF
    } > "$OUT_DIR/payload/tweaks.sh"
}

# journald only takes fixed sizes, so work it out from the filesystem size
# on every boot (cloud-init per-boot script: runs after the disk is grown).
write_journald_payload() {
    {
        echo '#!/bin/bash'
        echo "# Generated by build-templates.sh: cap the journal at min(MAX_MB, PERCENT% of disk)."
        echo "MAX_MB=$(q "$JOURNAL_MAX_MB")"
        echo "PERCENT=$(q "$JOURNAL_MAX_PERCENT")"
        cat <<'EOF'
set -euo pipefail
conf=/etc/systemd/journald.conf.d/50-size.conf

fs_mb=$(( $(df --output=size -k /var/log | tail -1) / 1024 ))
size=$(( fs_mb * PERCENT / 100 ))
(( size > MAX_MB )) && size=$MAX_MB
want="# Generated by build-templates.sh (journald-size, every boot)
# min(${MAX_MB}M, ${PERCENT}% of the ${fs_mb}M filesystem)
[Journal]
SystemMaxUse=${size}M"

[[ -f "$conf" && "$(cat "$conf")" == "$want" ]] && exit 0
mkdir -p "$(dirname "$conf")"
printf '%s
' "$want" > "$conf"
systemctl restart systemd-journald
echo "journald-size: SystemMaxUse=${size}M"
EOF
    } > "$OUT_DIR/payload/journald-size"
}

# zswap sizes swap from the clone's RAM and writes to /sys, so it can't run
# offline: the script is baked in, and runs on each clone's first boot.
write_zswap_payload() {
    curl -fsSL --retry 3 -o "$OUT_DIR/payload/zram-to-zswap.sh" "$ZSWAP_SCRIPT_URL" \
        || die "Could not download zram-to-zswap.sh"
    cat > "$OUT_DIR/payload/zswap-firstboot.sh" <<'EOF'
#!/bin/bash
# Generated by build-templates.sh: zram -> zswap on first boot.
set -euo pipefail
bash /usr/local/sbin/zram-to-zswap.sh --apply
EOF
}

# =============================================================================
#  PROFILES
# =============================================================================

# True if this run builds (or generates) the given template.
want() { [[ " ${GENERATE[*]} " == *" $1 "* ]]; }


# Profile file for a target.
profile_src() { echo "$PROFILES_DIR/$1.conf"; }

# The EXTRA_VIRT_PKGS a profile ends up with (host defaults, then the
# profile), spaces removed. Read in a subshell so nothing leaks in here.
profile_pkgs() {
    (
        EXTRA_VIRT_PKGS=""
        # shellcheck source=/dev/null
        source "$1" >/dev/null
        printf '%s' "${EXTRA_VIRT_PKGS// /}"
    )
}

# Usage: write_profile <target>
# Assembles OUT_DIR/<target>.conf: header, host defaults from shared.conf,
# the profile as it is (so it can override them), then the payload
# plumbing appended with +=.
write_profile() {
    local name="$1" src p have pkg missing=""
    src="$(profile_src "$name")"
    p="$OUT_DIR/$name.conf"
    have="$(profile_pkgs "$src")" || die "Could not read $src."
    for pkg in "${BUILDER_PKGS[@]}"; do
        [[ ",$have," == *",$pkg,"* ]] || missing+="${missing:+,}$pkg"
    done
    {
        cat <<EOF
# Generated by build-templates.sh on $(date '+%Y-%m-%d %H:%M'). Do not edit:
# change the files below and re-run build-templates.sh.
#   shared:  $SHARED_CONF
#   profile: $src

# --- Host defaults from the shared config (the profile can override) ---
DISTRO_VER=$(q "$DISTRO_VER")
DISK_STOR=$(q "$DISK_STOR")
NET_BRIDGE=$(q "$NET_BRIDGE")
VLAN=$(q "$VLAN")
SSH_KEY=$(q "$CI_SSH_KEY")
$( [[ -n "$CLOUD_PASSWORD" ]] && echo "CLOUD_PASSWORD=$(q "$CLOUD_PASSWORD")" )

# --- Profile: $src ---
EOF
        cat "$src"
        cat <<EOF

# --- Added by build-templates.sh: the payloads ---
$( [[ -n "$missing" ]] && echo "EXTRA_VIRT_PKGS+=$(q "${have:+,}$missing")" )
UPLOAD_FILES+=(
    $(q "$OUT_DIR/payload/51unattended-upgrades:/etc/apt/apt.conf.d/51unattended-upgrades")
    $(q "$OUT_DIR/payload/postfix-identity:/var/lib/cloud/scripts/per-boot/postfix-identity")
    $(q "$OUT_DIR/payload/zram-to-zswap.sh:/usr/local/sbin/zram-to-zswap.sh")
$( [[ -n "$JOURNAL_MAX_MB" ]] && echo "    $(q "$OUT_DIR/payload/journald-size:/var/lib/cloud/scripts/per-boot/journald-size")" )
)
CUSTOMIZE_SCRIPTS+=(
    $(q "$OUT_DIR/payload/ansible.sh")
    $(q "$OUT_DIR/payload/postfix.sh")
    $(q "$OUT_DIR/payload/skel.sh")
    $(q "$OUT_DIR/payload/tweaks.sh")
)
FIRSTBOOT_SCRIPTS+=(
    $(q "$OUT_DIR/payload/zswap-firstboot.sh")
)
EXTRA_VC_ARGS+=(
    --chmod "0755:/var/lib/cloud/scripts/per-boot/postfix-identity"
    --chmod "0755:/usr/local/sbin/zram-to-zswap.sh"
$( [[ -n "$JOURNAL_MAX_MB" ]] && echo '    --chmod "0755:/var/lib/cloud/scripts/per-boot/journald-size"' )
    # Old runbook: only the chosen locale is generated, not en_US too.
    --run-command $(q "sed -i 's/^en_US.UTF-8 UTF-8/# en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen")
)
EOF
    } > "$p"
    info "Profile: $p"
}

# Every wanted profile must exist and parse. Checked before anything is
# written, so a bad profile leaves OUT_DIR as it was.
check_profiles() {
    local t src
    for t in base extras desktop; do
        want "$t" || continue
        src="$(profile_src "$t")"
        [[ -f "$src" ]] || die "Missing profile $src (copy profiles/$t.conf.example to profiles/$t.conf and edit it)."
        bash -n "$src" || die "Profile $src has a syntax error (see above)."
        grep -qE '^[[:space:]]*TEMPL_NAME_DEFAULT=' "$src" \
            || warn "$src does not set TEMPL_NAME_DEFAULT: the template gets the create script's default name."
    done
}

# True if an address is one of the .example placeholders.
placeholder_addr() {
    local a="${1,,}"
    [[ "$a" == you@gmail.com || "$a" == you@example.com || "$a" =~ @example\.[^@]*$ ]]
}

# The mail settings must make sense for MAIL_RELAY, with no placeholders
# left from shared.conf.example. Never prints the password.
check_mail() {
    local v
    case "$MAIL_RELAY" in
        gmail|custom|none) ;;
        *) die "MAIL_RELAY must be gmail, custom or none, not '$MAIL_RELAY'." ;;
    esac
    [[ ! "${MAIL_DOMAIN,,}" =~ ^example\.(com|org|net)$ ]] \
        || die "MAIL_DOMAIN is still the placeholder $MAIL_DOMAIN: set your own domain in $SHARED_CONF."
    # The relay login first: MAIL_ROOT_TO may have been copied from it.
    if [[ "$MAIL_RELAY" != none ]] && placeholder_addr "$MAIL_RELAY_USER"; then
        die "MAIL_RELAY_USER is still the placeholder $MAIL_RELAY_USER: set your own login in $SHARED_CONF."
    fi
    for v in MAIL_ROOT_TO MAIL_SENDER; do
        [[ -z "${!v}" || "${!v}" == *@* ]] || die "$v must be an email address."
        if placeholder_addr "${!v}"; then
            die "$v is still the placeholder ${!v}: set your own address in $SHARED_CONF."
        fi
    done
    [[ "$MAIL_RELAY" == none ]] && return 0

    if [[ "$MAIL_RELAY" == custom ]]; then
        [[ -n "$MAIL_RELAY_HOST" ]] || die "Set MAIL_RELAY_HOST in $SHARED_CONF (MAIL_RELAY=custom)."
        [[ "$MAIL_RELAY_HOST" =~ ^[A-Za-z0-9.-]+$ ]] \
            || die "MAIL_RELAY_HOST must be a host name or IPv4 address, not '$MAIL_RELAY_HOST'."
        [[ -n "$MAIL_RELAY_PORT" ]] || die "Set MAIL_RELAY_PORT in $SHARED_CONF (MAIL_RELAY=custom)."
        if [[ ! "$MAIL_RELAY_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || (( MAIL_RELAY_PORT > 65535 )); then
            die "MAIL_RELAY_PORT must be a port number, not '$MAIL_RELAY_PORT'."
        fi
    else
        [[ -n "$MAIL_RELAY_USER" ]] || die "Set MAIL_RELAY_USER in $SHARED_CONF (MAIL_RELAY=gmail)."
    fi
    if [[ -n "$MAIL_RELAY_USER" ]]; then
        [[ -n "$MAIL_RELAY_PASSWORD" ]] || die "Set MAIL_RELAY_PASSWORD in $SHARED_CONF (MAIL_RELAY_USER is set)."
        [[ ! "$MAIL_RELAY_PASSWORD" =~ ^x+$ ]] \
            || die "MAIL_RELAY_PASSWORD is still the xxxx placeholder: set the real password in $SHARED_CONF."
    fi
    [[ -n "$MAIL_ROOT_TO" ]] \
        || die "Set MAIL_ROOT_TO in $SHARED_CONF: where root's mail goes (MAIL_RELAY_USER is not an address)."
}

generate() {
    local v
    for v in ANSIBLE_SSH_PUBKEY MAIL_DOMAIN; do
        [[ -n "${!v}" ]] || die "Set $v in $SHARED_CONF."
    done
    check_mail
    [[ -z "$JOURNAL_MAX_MB" || ( "$JOURNAL_MAX_MB" =~ ^[0-9]+$ && "$JOURNAL_MAX_PERCENT" =~ ^[0-9]+$ ) ]] \
        || die "JOURNAL_MAX_MB and JOURNAL_MAX_PERCENT must be numbers."
    [[ -z "$NEEDRESTART_MODE" || "$NEEDRESTART_MODE" =~ ^[ali]$ ]] || die "NEEDRESTART_MODE must be a, l, i or blank."
    [[ -n "$WAKATIME_CFG" ]] || info "WAKATIME_CFG is blank: no .wakatime.cfg in /etc/skel."
    check_profiles

    umask 077
    mkdir -p "$OUT_DIR/payload"
    chmod 700 "$OUT_DIR" "$OUT_DIR/payload"

    write_ansible_payload
    write_postfix_payload
    write_uu_origins
    write_skel_payload
    write_zswap_payload
    write_tweaks_payload
    write_journald_payload
    chmod 700 "$OUT_DIR"/payload/*.sh "$OUT_DIR/payload/postfix-identity" "$OUT_DIR/payload/journald-size"

    # Everything template-specific is in the profiles.
    local t
    for t in base extras desktop; do
        want "$t" || continue
        write_profile "$t"
    done
}

# =============================================================================
#  MAIN
# =============================================================================
(( ${#CREATE_ARGS[@]} )) || CREATE_ARGS=(--unattended --vmid 52000 --auto-vmid --template)

case "$TARGET" in
    base|extras|desktop) PROFILES=("$TARGET") ;;
    all)                 PROFILES=(base extras desktop) ;;
    --generate-only)     PROFILES=(); GENERATE=(base extras desktop) ;;
    *) usage >&2; exit 1 ;;   # unreachable: checked in HELP above
esac

[[ $EUID -eq 0 ]] || die "Run as root."
# Checked before anything is built, so a long build is not wasted.
if [[ "$VERIFY" == yes ]]; then
    for f in "$VERIFY_CLONE" "$(dirname "$VERIFY_CLONE")/verify-template.sh"; do
        [[ -f "$f" && -r "$f" ]] || die "--verify needs $f (missing or not readable)."
    done
    command -v qm >/dev/null || die "--verify needs qm (run on the Proxmox host)."
fi
[[ -v GENERATE ]] || GENERATE=("${PROFILES[@]}")
generate
(( ${#PROFILES[@]} )) || { info "Files written to $OUT_DIR. Nothing built."; exit 0; }

# Fetch the latest public script every run, so fixes are always picked up.
# If GitHub can't be reached, fall back to the copy already here.
# UPDATE_PUBLIC_SCRIPT=no keeps the local copy (e.g. one you edited).
if [[ "${UPDATE_PUBLIC_SCRIPT:-yes}" == "yes" ]]; then
    updated=no
    for url in "${PUBLIC_SCRIPT_URLS[@]}"; do
        if curl -fsSL -o "$PUBLIC_SCRIPT.new" "$url" 2>/dev/null && bash -n "$PUBLIC_SCRIPT.new"; then
            mv "$PUBLIC_SCRIPT.new" "$PUBLIC_SCRIPT"
            chmod 755 "$PUBLIC_SCRIPT"
            info "Public script updated from: $url"
            updated=yes
            break
        fi
    done
    if [[ "$updated" == no ]]; then
        rm -f "$PUBLIC_SCRIPT.new"
        [[ -f "$PUBLIC_SCRIPT" ]] || die "Could not download the public script."
        info "Could not update the public script: using the existing $PUBLIC_SCRIPT"
    fi
fi
[[ -f "$PUBLIC_SCRIPT" ]] || die "$PUBLIC_SCRIPT not found (UPDATE_PUBLIC_SCRIPT=no)."

# VMIDs on this node, sorted. qm list: a header, then the VMID first.
list_vmids() { qm list | awk '$1 ~ /^[0-9]+$/ { print $1 }' | sort; }

# --verify results, one "target|vmid|kept clone|result" each, and the summary.
RESULTS=()
VERIFY_FAILED=no
summary() {
    local r t id kept res
    info "Verify summary:"
    printf '  %-8s %-7s %-11s %s\n' TARGET VMID "KEPT CLONE" RESULT
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r t id kept res <<<"$r"
        printf '  %-8s %-7s %-11s %s\n' "$t" "$id" "$kept" "$res"
    done
    [[ "$KEEP" == no ]] || info "Remove each kept clone by hand: qm destroy <id> --purge"
}

# Usage: verify_built <target> <VMIDs before the build>
# The new template is the one VMID that was not there before the build.
# With --keep, the kept clone is found the same way, around the verify.
verify_built() {
    local p="$1" before="$2" after new post kept="-" rc=0 args=()
    if [[ "$before" == "?" ]] || ! after="$(list_vmids)"; then
        new=""
    else
        new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -v '^$' || true)"
    fi
    if [[ -z "$new" || "$new" == *$'\n'* ]]; then
        new="${new//$'\n'/ }"
        warn "Could not work out the VMID of the $p template (new VMIDs: ${new:-none}; want exactly one). Not verified."
        RESULTS+=("$p|?|-|skipped (VMID unknown)")
        VERIFY_FAILED=yes
        return 0
    fi
    [[ -n "$TEST_MAIL" ]] && args+=(--send-test-mail "$TEST_MAIL")
    [[ "$KEEP" == yes ]] && args+=(--keep)
    info "Verifying: $p (VMID $new)"
    bash "$VERIFY_CLONE" "$new" --profile "$p" --config "$SHARED_CONF" "${args[@]}" || rc=$?
    if [[ "$KEEP" == yes ]]; then
        if post="$(list_vmids)"; then
            kept="$(comm -13 <(printf '%s\n' "$after") <(printf '%s\n' "$post") | grep -v '^$' || true)"
            kept="${kept//$'\n'/ }"
        fi
        [[ -n "$kept" && "$kept" != "-" ]] || kept="none found"
    fi
    if (( rc == 0 )); then
        RESULTS+=("$p|$new|$kept|passed")
    else
        RESULTS+=("$p|$new|$kept|FAILED (exit $rc)")
        VERIFY_FAILED=yes
    fi
    # Ctrl-C or kill during the verify stops the whole run.
    if (( rc == 130 || rc == 143 )); then summary; exit "$rc"; fi
}

for p in "${PROFILES[@]}"; do
    info "Building: $p"
    if [[ "$VERIFY" == no ]]; then
        bash "$PUBLIC_SCRIPT" --config "$OUT_DIR/$p.conf" "${CREATE_ARGS[@]}"
        continue
    fi
    before="$(list_vmids)" || { warn "qm list failed: the new VMID cannot be worked out."; before="?"; }
    rc=0
    bash "$PUBLIC_SCRIPT" --config "$OUT_DIR/$p.conf" "${CREATE_ARGS[@]}" || rc=$?
    if (( rc )); then
        # A failed build stops the run, as without --verify.
        RESULTS+=("$p|-|-|not verified (build failed, exit $rc)")
        summary
        exit "$rc"
    fi
    verify_built "$p" "$before"
done
if [[ "$VERIFY" == yes ]]; then
    summary
    [[ "$VERIFY_FAILED" == no ]] || exit 1
fi
