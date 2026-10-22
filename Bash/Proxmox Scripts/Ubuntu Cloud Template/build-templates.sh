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
OUT_DIR="${OUT_DIR:-/root/template-build}"     # generated profiles + payloads (root-only)

# --- Host defaults: written into every profile, which can override them ---
DISTRO_VER="resolute"
DISK_STOR=""                       # blank = the host's only VM-disk storage (local-lvm / local-zfs)
NET_BRIDGE="vmbr0"
VLAN=""
CI_SSH_KEY=""                      # cloud-init user's key(s), or "github.com/<user>"; written as SSH_KEY
CLOUD_PASSWORD=""                  # blank = generated each build, shown at the end

ANSIBLE_SSH_PUBKEY=""              # required

GMAIL_USER=""                      # required
GMAIL_APP_PASSWORD=""              # required
MAIL_DOMAIN=""                     # required; mail is sent as user@<short hostname>.MAIL_DOMAIN

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
BUILDER_PKGS=(libsasl2-modules unattended-upgrades zsh)

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
  ./build-templates.sh base|extras|desktop|all [-- <create-script args>]
  ./build-templates.sh --generate-only
  ./build-templates.sh -h|--help|help

ARGUMENTS
  base              Build the base template.
  extras            Build the extras template.
  desktop           Build the desktop template.
  all               Build all three: base, extras, then desktop.
  --generate-only   Write all profiles and payloads to OUT_DIR. Build nothing.
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
  All three get: Postfix relay via Gmail, an ansible user with sudo,
  unattended upgrades and zram to zswap on first boot. Also, each as set
  in shared.conf: a journald size cap, dotfiles in /etc/skel, and the
  login shell, needrestart and Pro advert tweaks.

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
       FIRSTBOOT_SCRIPTS, EXTRA_VC_ARGS, and any of libsasl2-modules,
       unattended-upgrades and zsh missing from EXTRA_VIRT_PKGS.

  shared.conf, required:
    ANSIBLE_SSH_PUBKEY   Public key for the ansible user.
    GMAIL_USER           Gmail account mail is relayed through.
    GMAIL_APP_PASSWORD   App password for that account.
    MAIL_DOMAIN          Mail is sent as user@<short hostname>.MAIL_DOMAIN.

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
                         Default: /root/template-build
  UPDATE_PUBLIC_SCRIPT   no = keep the local PUBLIC_SCRIPT. Default: yes

OUTPUT
  OUT_DIR/<target>.conf  Profile for each chosen template.
  OUT_DIR/payload/       Payload scripts and files baked into the image.
  Both are root-only and rewritten on every run.

EXAMPLES
  ./build-templates.sh --generate-only
  ./build-templates.sh extras
  ./build-templates.sh all
  ./build-templates.sh base -- --unattended --vmid 53000 --auto-vmid --template
  SHARED_CONF=/root/other.conf ./build-templates.sh desktop
  PROFILES_DIR=/root/profiles ./build-templates.sh all

NOTES
  - Run as root on the Proxmox host, --generate-only included.
  - Each build downloads the latest create-ubuntu-cloud-template.sh from
    GitHub to PUBLIC_SCRIPT, falling back to the copy already there.
  - Each run downloads zram-to-zswap.sh from GitHub.
  - Still manual, on the first clone of each template:
      sudo ./verify-template.sh --send-test-mail <address>
    (from a copy inside the clone), check the test mail arrived, and on
    the desktop log in on the console once, log out, then RDP in with the
    login from /root/rdp-credentials.txt.
EOF
}

case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
    base|extras|desktop|all|--generate-only) ;;
    "") { echo "Error: no target given."; echo; usage; } >&2; exit 1 ;;
    *)  { echo "Error: unknown target: $1"; echo; usage; } >&2; exit 1 ;;
esac

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

write_postfix_payload() {
    {
        echo '#!/bin/bash'
        echo "# Generated by build-templates.sh: postfix relay via Gmail."
        echo "GMAIL_USER=$(q "$GMAIL_USER")"
        echo "GMAIL_APP_PASSWORD=$(q "$GMAIL_APP_PASSWORD")"
        echo "MAIL_DOMAIN=$(q "$MAIL_DOMAIN")"
        cat <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string localhost" | debconf-set-selections
apt-get install -y -q postfix bsd-mailx

relay="[smtp.gmail.com]:587"
db="$(postconf -h default_database_type)"   # hash or lmdb
# Placeholder until first boot: no clone is called localhost, so
# postfix-identity always re-stamps this with the clone's real name.
fqdn="localhost.${MAIL_DOMAIN}"
echo "$fqdn" > /etc/mailname

install -d -m 755 /etc/postfix/sasl
( umask 077; printf '%s %s:%s\n' "$relay" "$GMAIL_USER" "$GMAIL_APP_PASSWORD" > /etc/postfix/sasl/sasl_passwd )
postmap "$db:/etc/postfix/sasl/sasl_passwd"
chmod 600 /etc/postfix/sasl/sasl_passwd*

# No sender rewrite: mail goes out as the natural user@<fqdn>.
# Short queue lifetimes so an undeliverable message can't loop for days.
postconf -e \
    "relayhost=$relay" \
    "smtp_tls_security_level=encrypt" \
    "smtp_tls_CAfile=/etc/ssl/certs/ca-certificates.crt" \
    "smtp_sasl_auth_enable=yes" \
    "smtp_sasl_security_options=noanonymous" \
    "smtp_sasl_password_maps=$db:/etc/postfix/sasl/sasl_passwd" \
    "inet_interfaces=loopback-only" \
    "inet_protocols=ipv4" \
    "mynetworks=127.0.0.0/8" \
    "mydomain=$MAIL_DOMAIN" \
    "myhostname=$fqdn" \
    "myorigin=/etc/mailname" \
    'mydestination=$myhostname, localhost.$mydomain, localhost' \
    "maximal_queue_lifetime=1d" \
    "bounce_queue_lifetime=1d"

# Root's local mail (bounces, users' cron jobs) goes to Gmail.
grep -q '^root:' /etc/aliases 2>/dev/null || printf 'root: %s\n' "$GMAIL_USER" >> /etc/aliases
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

generate() {
    local v
    for v in ANSIBLE_SSH_PUBKEY GMAIL_USER GMAIL_APP_PASSWORD MAIL_DOMAIN; do
        [[ -n "${!v}" ]] || die "Set $v in $SHARED_CONF."
    done
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
TARGET="${1:-}"
[[ $# -gt 0 ]] && shift
[[ "${1:-}" == "--" ]] && shift
CREATE_ARGS=("$@")
(( ${#CREATE_ARGS[@]} )) || CREATE_ARGS=(--unattended --vmid 52000 --auto-vmid --template)

case "$TARGET" in
    base|extras|desktop) PROFILES=("$TARGET") ;;
    all)                 PROFILES=(base extras desktop) ;;
    --generate-only)     PROFILES=(); GENERATE=(base extras desktop) ;;
    *) usage >&2; exit 1 ;;   # unreachable: checked in HELP above
esac

[[ $EUID -eq 0 ]] || die "Run as root."
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

for p in "${PROFILES[@]}"; do
    info "Building: $p"
    bash "$PUBLIC_SCRIPT" --config "$OUT_DIR/$p.conf" "${CREATE_ARGS[@]}"
done
