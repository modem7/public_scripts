#!/bin/bash
# A && pass || fail is safe throughout: pass() always returns 0.
# shellcheck disable=SC2015,SC2012
# =============================================================================
#  verify-template.sh
#  Run as root INSIDE a clone of one of the templates made by
#  build-templates.sh. Checks that everything from the old
#  Ubuntu-Cloud-Master-Extras runbook (plus the later additions) is in place.
#
#  Usage:  sudo ./verify-template.sh [--profile base|extras|desktop]
#                                    [--send-test-mail <address>]
#    --profile         Default: worked out from what is installed.
#    --send-test-mail  Also sends the postfix test email (the one manual step).
#
#  Exit code: 0 = no FAILs (WARNs are fine), 1 = at least one FAIL.
#  Holds no secrets: it checks the Gmail password is set, never what it is.
# =============================================================================
set -uo pipefail

# --- What the templates are meant to have (match build-templates.conf) ---
EXPECT_LANG="en_GB.UTF-8"
EXPECT_TZ="Europe/London"
EXPECT_KEYMAP="gb"
EXPECT_MAIL_DOMAIN="modem7.com"
EXPECT_GMAIL_USER="modem7@gmail.com"
EXPECT_UU_MAIL="modem7@gmail.com"
EXPECT_ANSIBLE_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFv+XL86DUoq1o4EEC24uYecv4nU76XcmTeOO1rin9gx ansible"
EXPECT_SHELL="/usr/bin/zsh"
EXPECT_NEEDRESTART="a"
EXPECT_JOURNAL_MAX_MB=1024
EXPECT_JOURNAL_PERCENT=10
EXPECT_TUNED="virtual-guest"

PKGS_CORE="aptitude auto-apt-proxy libsasl2-modules tuned tuned-utils unattended-upgrades zsh
           qemu-guest-agent cloud-init cloud-utils cloud-guest-utils postfix bsd-mailx"
PKGS_TOOLS="acl bind9-dnsutils cifs-utils curl git htop needrestart net-tools plocate unzip"
PKGS_DESKTOP="ubuntu-desktop-minimal gnome-remote-desktop openssl"
# Dropped on purpose; should NOT be installed.
PKGS_DROPPED="resolvconf tuned-utils-systemtap mlocate"

# =============================================================================
PROFILE=""
TEST_MAIL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)        PROFILE="${2:-}"; shift 2 ;;
        --send-test-mail) TEST_MAIL="${2:-}"; shift 2 ;;
        -h|--help)        sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0)." >&2; exit 2; }

if [[ -t 1 ]]; then G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' B='\033[1m' N='\033[0m'; else G='' Y='' R='' B='' N=''; fi
PASSES=0 WARNS=0 FAILS=0
pass()    { echo -e "  ${G}PASS${N}  $*"; PASSES=$((PASSES + 1)); }
warn()    { echo -e "  ${Y}WARN${N}  $*"; WARNS=$((WARNS + 1)); }
fail()    { echo -e "  ${R}FAIL${N}  $*"; FAILS=$((FAILS + 1)); }
section() { echo -e "\n${B}== $* ==${N}"; }
# check "<description>" <command...>   PASS if the command succeeds
check()   { local d="$1"; shift; if "$@" &>/dev/null; then pass "$d"; else fail "$d"; fi; }

installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed'; }
mode_of()   { stat -c '%a' "$1" 2>/dev/null; }
owner_of()  { stat -c '%U' "$1" 2>/dev/null; }
uu_conf()   { apt-config dump 2>/dev/null | awk -v k="$1" '$1 == k { gsub(/[";]/, "", $2); print $2; exit }'; }

# What Proxmox's Cloud-Init tab sent this clone (user, password, keys, name).
USERDATA="$(cloud-init query userdata 2>/dev/null)"
ud_val() { sed -n "s/^$1: *//p" <<< "$USERDATA" | head -1 | sed 's/^["'"'"']//; s/["'"'"']$//'; }
CI_USER="$(ud_val user)"
CI_HOST="$(ud_val hostname)"
CI_PASS="$(ud_val password)"
mapfile -t CI_KEYS < <(sed -n '/^ssh_authorized_keys:/,/^[^ -]/{s/^ *- *//p}' <<< "$USERDATA" | sed 's/^["'"'"']//; s/["'"'"']$//')

# The clone's login user: the Cloud-Init tab's user, else the first
# "real" user (uid 1000+) that isn't ansible.
LOGIN_USER="${CI_USER:-$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "ansible" { print $1; exit }' /etc/passwd)}"

if [[ -z "$PROFILE" ]]; then
    if installed ubuntu-desktop-minimal; then PROFILE="desktop"
    elif installed git && installed htop;  then PROFILE="extras"
    else PROFILE="base"; fi
    AUTO=" (detected)"
else
    AUTO=""
fi
[[ "$PROFILE" =~ ^(base|extras|desktop)$ ]] || { echo "--profile must be base, extras or desktop." >&2; exit 2; }

echo -e "${B}Template check: $(hostname) - profile: ${PROFILE}${AUTO}${N}"
echo "Login user: ${LOGIN_USER:-(none found)}   Kernel: $(uname -r)"

# =============================================================================
section "First boot"
st="$(cloud-init status 2>/dev/null | awk '/^status:/ {print $2}')"
case "$st" in
    done)    pass "cloud-init finished (status: done)" ;;
    running) warn "cloud-init still running: wait a minute and re-run" ;;
    *)       fail "cloud-init status: ${st:-unknown} (see: cloud-init status --long)" ;;
esac
if [[ -z "$(ls -A /usr/lib/virt-sysprep/scripts 2>/dev/null)" ]]; then
    pass "first-boot scripts all ran (queue empty)"
else
    fail "first-boot scripts still queued: $(ls /usr/lib/virt-sysprep/scripts | tr '\n' ' ')"
fi
mid="$(cat /etc/machine-id 2>/dev/null)"
[[ "$mid" =~ ^[0-9a-f]{32}$ ]] && pass "machine-id set ($mid)" || fail "machine-id missing or blank"
root_dev="$(findmnt -no SOURCE /)"
disk="/dev/$(lsblk -no PKNAME "$root_dev" 2>/dev/null | head -1)"
if [[ -b "$disk" ]]; then
    free_mb=$(( ( $(blockdev --getsize64 "$disk") - $(blockdev --getsize64 "$root_dev") ) / 1048576 ))
    (( free_mb < 1200 )) && pass "root partition fills the disk ($(df -h --output=size / | tail -1 | tr -d ' '))" \
                          || warn "root partition is ${free_mb} MB smaller than the disk: not grown?"
fi

# =============================================================================
section "Cloud-init login (Proxmox Cloud-Init tab)"
if [[ -z "$USERDATA" ]]; then
    warn "no cloud-init user-data found: skipping (not a Proxmox clone?)"
else
    if [[ -n "$CI_HOST" ]]; then
        [[ "$(hostname -s)" == "${CI_HOST%%.*}" ]] && pass "hostname is $(hostname -s), as set" \
                                                   || fail "hostname is $(hostname -s), Cloud-Init tab says $CI_HOST"
    fi
    if id "$LOGIN_USER" &>/dev/null; then
        pass "user $LOGIN_USER exists (from the Cloud-Init tab)"
    else
        fail "user $LOGIN_USER from the Cloud-Init tab does not exist"
    fi
    if [[ -n "$CI_PASS" ]]; then
        hash="$(getent shadow "$LOGIN_USER" | cut -d: -f2)"
        if [[ "$CI_PASS" == '$'* ]]; then
            # Proxmox sends a hash: the user's must be the same one.
            [[ "$hash" == "$CI_PASS" ]] && pass "$LOGIN_USER password matches the Cloud-Init tab" \
                                        || fail "$LOGIN_USER password differs from the Cloud-Init tab"
        else
            [[ "$(CI_PASS="$CI_PASS" perl -e 'print crypt($ENV{CI_PASS}, $ARGV[0])' "$hash")" == "$hash" ]] \
                && pass "$LOGIN_USER password matches the Cloud-Init tab" \
                || fail "$LOGIN_USER password differs from the Cloud-Init tab"
        fi
    else
        warn "no password in the Cloud-Init tab"
    fi
    if (( ${#CI_KEYS[@]} )); then
        ak="$(getent passwd "$LOGIN_USER" | cut -d: -f6)/.ssh/authorized_keys"
        missing=0
        for k in "${CI_KEYS[@]}"; do grep -qxF -- "$k" "$ak" 2>/dev/null || missing=$((missing + 1)); done
        (( missing == 0 )) && pass "all ${#CI_KEYS[@]} SSH key(s) from the Cloud-Init tab are in $ak" \
                           || fail "$missing of ${#CI_KEYS[@]} SSH key(s) from the Cloud-Init tab missing from $ak"
    else
        warn "no SSH keys in the Cloud-Init tab"
    fi
fi

# =============================================================================
section "Packages"
want="$PKGS_CORE"
[[ "$PROFILE" != base ]]  && want+=" $PKGS_TOOLS"
[[ "$PROFILE" == desktop ]] && want+=" $PKGS_DESKTOP"
missing=()
for p in $want; do installed "$p" || missing+=("$p"); done
(( ${#missing[@]} == 0 )) && pass "all $(wc -w <<< "$want") expected packages installed" \
                          || fail "missing packages: ${missing[*]}"
extra=()
for p in $PKGS_DROPPED; do installed "$p" && extra+=("$p"); done
(( ${#extra[@]} == 0 )) && pass "dropped packages absent ($PKGS_DROPPED)" \
                        || warn "dropped packages are installed: ${extra[*]}"
if [[ "$PROFILE" == desktop ]]; then
    installed snapd && pass "snapd installed (desktop keeps it)" || fail "snapd missing (Firefox/App Center need it)"
else
    installed snapd && fail "snapd is installed" || pass "snapd not installed"
    check "snapd pinned out (/etc/apt/preferences.d/no-snapd.pref)" \
        grep -q 'Pin-Priority: -10' /etc/apt/preferences.d/no-snapd.pref
fi

# =============================================================================
section "Proxmox / cloud-init"
check "qemu-guest-agent running" systemctl is-active --quiet qemu-guest-agent
check "cloud-init datasources limited to NoCloud, ConfigDrive (99_pve.cfg)" \
    grep -q 'datasource_list: \[ NoCloud, ConfigDrive \]' /etc/cloud/cloud.cfg.d/99_pve.cfg

# =============================================================================
section "System"
v="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)"
[[ "$v" == 1 ]] && pass "IPv6 disabled" || fail "IPv6 not disabled (net.ipv6.conf.all.disable_ipv6=$v)"
if systemctl is-active --quiet tuned; then
    a="$(tuned-adm active 2>/dev/null | sed -n 's/^Current active profile: //p')"
    [[ "$a" == "$EXPECT_TUNED" ]] && pass "tuned running, profile $a" || fail "tuned profile is '$a', expected $EXPECT_TUNED"
else
    fail "tuned not running"
fi
check "fstrim.timer enabled" systemctl is-enabled --quiet fstrim.timer
l="$(localectl status 2>/dev/null)"
grep -q "LANG=$EXPECT_LANG" <<< "$l" && pass "locale $EXPECT_LANG" || fail "system locale is not $EXPECT_LANG"
# The saved setting, not localectl: on 26.04 localectl can show a layout
# it failed to save, which is then lost on reboot.
kb="$(sed -n 's/^XKBLAYOUT="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/default/keyboard 2>/dev/null)"
[[ "$kb" == "$EXPECT_KEYMAP" ]] && pass "keyboard layout $kb (saved in /etc/default/keyboard)" \
                               || fail "keyboard layout saved as '${kb:-unset}', expected $EXPECT_KEYMAP (lost on reboot)"
if locale -a 2>/dev/null | grep -qi '^en_US'; then
    warn "en_US locale also generated (runbook generated $EXPECT_LANG only)"
else
    pass "only the expected locale generated (no en_US)"
fi
tz="$(timedatectl show -p Timezone --value 2>/dev/null)"
[[ "$tz" == "$EXPECT_TZ" ]] && pass "timezone $tz" || fail "timezone is '$tz', expected $EXPECT_TZ"

# =============================================================================
section "Swap / zswap"
if swapon --show=NAME --noheadings | grep -q .; then
    pass "swap active: $(swapon --show=NAME,SIZE --noheadings | xargs)"
else
    fail "no swap active"
fi
z="$(cat /sys/module/zswap/parameters/enabled 2>/dev/null)"
[[ "$z" == Y ]] && pass "zswap on ($(cat /sys/module/zswap/parameters/compressor 2>/dev/null))" || fail "zswap off"
check "zswap kept across reboots (/etc/default/grub.d/99-zswap.cfg)" grep -q 'zswap.enabled=1' /etc/default/grub.d/99-zswap.cfg
if grep -q 'zswap.enabled=1' /proc/cmdline; then
    pass "zswap on the kernel command line"
else
    warn "zswap not on the kernel command line yet: normal until the clone's first reboot"
fi

# =============================================================================
section "Ansible user"
if id ansible &>/dev/null; then
    pass "user ansible exists"
    [[ "$(getent passwd ansible | cut -d: -f7)" == /bin/bash ]] && pass "ansible shell is /bin/bash" || warn "ansible shell is not /bin/bash"
    [[ "$(passwd -S ansible | awk '{print $2}')" == L ]] && pass "ansible password locked" || fail "ansible password not locked"
    k=/home/ansible/.ssh/authorized_keys
    [[ "$(mode_of /home/ansible/.ssh)" == 700 && "$(owner_of /home/ansible/.ssh)" == ansible ]] \
        && pass "~ansible/.ssh is 700, owned by ansible" || fail "~ansible/.ssh permissions/owner wrong"
    [[ "$(mode_of "$k")" == 600 && "$(owner_of "$k")" == ansible ]] \
        && pass "authorized_keys is 600, owned by ansible" || fail "authorized_keys permissions/owner wrong"
    grep -qxF "$EXPECT_ANSIBLE_KEY" "$k" 2>/dev/null && pass "authorized_keys has the expected ansible key" \
                                                     || fail "expected ansible key not in authorized_keys"
    [[ "$(mode_of /etc/sudoers.d/ansible)" == 440 ]] && visudo -cqf /etc/sudoers.d/ansible &>/dev/null \
        && pass "sudoers.d/ansible is 440 and valid" || fail "sudoers.d/ansible missing, wrong mode or invalid"
    sudo -l -U ansible 2>/dev/null | grep -q 'NOPASSWD: ALL' && pass "ansible has passwordless sudo" || fail "ansible has no passwordless sudo"
else
    fail "user ansible missing"
fi

# =============================================================================
section "Postfix"
check "postfix running" systemctl is-active --quiet postfix
check "postfix config valid (postfix check)" postfix check
pc() { postconf -h "$1" 2>/dev/null; }
expect_pc() { local v; v="$(pc "$1")"; [[ "$v" == "$2" ]] && pass "$1 = $v" || fail "$1 = '$v', expected '$2'"; }
expect_pc relayhost "[smtp.gmail.com]:587"
expect_pc smtp_tls_security_level encrypt
expect_pc smtp_sasl_auth_enable yes
expect_pc smtp_sasl_security_options noanonymous
expect_pc inet_interfaces loopback-only
expect_pc inet_protocols ipv4
expect_pc mydomain "$EXPECT_MAIL_DOMAIN"
fqdn="$(hostname -s).$EXPECT_MAIL_DOMAIN"
expect_pc myhostname "$fqdn"
[[ "$(cat /etc/mailname 2>/dev/null)" == "$fqdn" ]] && pass "/etc/mailname = $fqdn (this clone's name)" \
                                                    || fail "/etc/mailname is not $fqdn (postfix-identity not run?)"
expect_pc myorigin /etc/mailname
expect_pc maximal_queue_lifetime 1d
expect_pc bounce_queue_lifetime 1d
# No sender rewrite: mail goes out as the natural user@<fqdn>.
for k in sender_canonical_maps smtp_header_checks; do
    v="$(pc "$k")"
    [[ -z "$v" ]] && pass "$k unset (no sender rewrite)" || fail "$k = '$v', expected unset"
done
check "root mail aliased (root: line in /etc/aliases)" grep -q '^root:' /etc/aliases
grep -qE "^root:[[:space:]]*${EXPECT_GMAIL_USER}[[:space:]]*$" /etc/aliases 2>/dev/null \
    && pass "root mail goes to $EXPECT_GMAIL_USER" || warn "root: alias in /etc/aliases is not $EXPECT_GMAIL_USER"
check 'no cron mail from /etc/crontab (MAILTO="")' grep -qx 'MAILTO=""' /etc/crontab
sp=/etc/postfix/sasl/sasl_passwd
if [[ -f "$sp" ]]; then
    grep -q "^\[smtp.gmail.com\]:587 ${EXPECT_GMAIL_USER}:." "$sp" && pass "Gmail login set for $EXPECT_GMAIL_USER (password not shown)" \
                                                                 || fail "sasl_passwd has no login for $EXPECT_GMAIL_USER"
    [[ "$(mode_of "$sp")" == 600 ]] && pass "sasl_passwd is 600" || fail "sasl_passwd mode is $(mode_of "$sp"), expected 600"
    ls "$sp".* &>/dev/null && pass "sasl_passwd map built ($(basename "$(ls "$sp".* | head -1)"))" || fail "sasl_passwd map not built (postmap)"
else
    fail "$sp missing"
fi
if [[ -n "$TEST_MAIL" ]]; then
    echo "Template check from $(hostname) at $(date)" | mail -s "Template check: $(hostname)" "$TEST_MAIL" \
        && pass "test email queued to $TEST_MAIL: check your inbox (and: journalctl -u postfix)" \
        || fail "could not queue the test email"
else
    warn "test email not sent (add --send-test-mail <address>)"
fi

# =============================================================================
section "Unattended upgrades"
check "unattended-upgrades service enabled" systemctl is-enabled --quiet unattended-upgrades
[[ "$(uu_conf APT::Periodic::Update-Package-Lists)" == 1 ]] && pass "daily package list update on" || fail "daily package list update off"
[[ "$(uu_conf APT::Periodic::Unattended-Upgrade)" == 1 ]] && pass "daily unattended upgrade on" || fail "daily unattended upgrade off"
[[ "$(uu_conf APT::Periodic::AutocleanInterval)" == 7 ]] && pass "autoclean every 7 days" || fail "AutocleanInterval is not 7"
r="$(uu_conf Unattended-Upgrade::Automatic-Reboot)"
[[ "$r" != true ]] && pass "no automatic reboot" || fail "automatic reboot is on (should be off)"
[[ "$(uu_conf Unattended-Upgrade::Mail)" == "$EXPECT_UU_MAIL" ]] && pass "upgrade reports mailed to $EXPECT_UU_MAIL" || fail "Unattended-Upgrade::Mail is not $EXPECT_UU_MAIL"
[[ "$(uu_conf Unattended-Upgrade::MailReport)" == on-change ]] && pass "MailReport on-change" || fail "MailReport is not on-change"
[[ "$(uu_conf Unattended-Upgrade::Remove-Unused-Dependencies)" == true ]] && pass "Remove-Unused-Dependencies true" || fail "Remove-Unused-Dependencies not true"
origins="$(apt-config dump 2>/dev/null)"
missing=()
for o in 'Docker:' 'crowdsec/crowdsec:' 'Jamie Cameron:stable' 'LP-PPA-ansible-ansible:' 'Artifactory:' \
         'netdata/netdata-repoconfig:' 'ESMApps:' 'ESM:' '-security' '-updates'; do
    grep -q "Allowed-Origins:: .*${o}" <<< "$origins" || missing+=("$o")
done
grep -q 'Origins-Pattern:: "origin=gh,codename=main"' <<< "$origins" || missing+=("origin=gh,codename=main")
(( ${#missing[@]} == 0 )) && pass "all expected upgrade origins listed" || fail "missing upgrade origins: ${missing[*]}"

# =============================================================================
section "Users, shell, dotfiles"
for f in .p10k.zsh .zshrc .zshenv; do
    [[ -s "/etc/skel/$f" ]] && pass "/etc/skel/$f present" || fail "/etc/skel/$f missing or empty"
done
w=/etc/skel/.wakatime.cfg
if [[ -f "$w" ]]; then
    [[ "$(mode_of "$w")" == 600 ]] && pass ".wakatime.cfg is 600" || fail ".wakatime.cfg mode is $(mode_of "$w"), expected 600"
    grep -q '^api_key *= *[^ ]' "$w" && pass ".wakatime.cfg has an api_key (not shown)" || fail ".wakatime.cfg has no api_key"
    grep -q '^\[internal\]' "$w" && fail ".wakatime.cfg still has an [internal] section" || pass ".wakatime.cfg has no [internal] section"
else
    fail "$w missing"
fi
if [[ -n "$LOGIN_USER" ]]; then
    [[ "$(getent passwd "$LOGIN_USER" | cut -d: -f7)" == "$EXPECT_SHELL" ]] \
        && pass "login user $LOGIN_USER uses $EXPECT_SHELL" || fail "login user $LOGIN_USER does not use $EXPECT_SHELL"
    id -nG "$LOGIN_USER" | grep -qw sudo && pass "$LOGIN_USER is in the sudo group" || fail "$LOGIN_USER is not in the sudo group"
    [[ -s "/home/$LOGIN_USER/.zshrc" ]] && pass "$LOGIN_USER got the dotfiles from /etc/skel" || warn "$LOGIN_USER has no ~/.zshrc"
fi
grep -q "^DSHELL=$EXPECT_SHELL" /etc/adduser.conf && pass "adduser default shell $EXPECT_SHELL" || fail "adduser default shell is not $EXPECT_SHELL"
grep -q "^SHELL=$EXPECT_SHELL" /etc/default/useradd && pass "useradd default shell $EXPECT_SHELL" || fail "useradd default shell is not $EXPECT_SHELL"

# =============================================================================
section "needrestart, adverts, journal"
grep -q "\$nrconf{restart} = '$EXPECT_NEEDRESTART';" /etc/needrestart/conf.d/50-restart-mode.conf 2>/dev/null \
    && pass "needrestart restart mode '$EXPECT_NEEDRESTART'" || fail "needrestart restart mode not '$EXPECT_NEEDRESTART'"
[[ ! -e /etc/apt/apt.conf.d/20apt-esm-hook.conf ]] && pass "apt Pro/ESM hook disabled" || fail "apt Pro/ESM hook still active"
grep -q '^ENABLED=0' /etc/default/motd-news 2>/dev/null && pass "motd news off" || fail "motd news still on"
[[ ! -x /etc/update-motd.d/91-contract-ua-esm-status ]] && pass "Pro status removed from the login message" || fail "Pro status still in the login message"
cap="$(sed -n 's/^SystemMaxUse=\([0-9]*\)M$/\1/p' /etc/systemd/journald.conf.d/50-size.conf 2>/dev/null)"
fs_mb=$(( $(df --output=size -k /var/log | tail -1) / 1024 ))
want_cap=$(( fs_mb * EXPECT_JOURNAL_PERCENT / 100 )); (( want_cap > EXPECT_JOURNAL_MAX_MB )) && want_cap=$EXPECT_JOURNAL_MAX_MB
[[ "$cap" == "$want_cap" ]] && pass "journal capped at ${cap}M (min ${EXPECT_JOURNAL_MAX_MB}M, ${EXPECT_JOURNAL_PERCENT}% of ${fs_mb}M)" \
                            || fail "journal cap is '${cap:-unset}', expected ${want_cap}M"
echo "        journal now uses: $(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]*[KMG]' | head -1)"

# =============================================================================
if [[ "$PROFILE" == desktop ]]; then
    section "Desktop"
    [[ "$(systemctl get-default)" == graphical.target ]] && pass "boots to the login screen (graphical.target)" || fail "default target is not graphical"
    unmasked=()
    for t in sleep suspend hibernate hybrid-sleep; do
        [[ "$(systemctl is-enabled "$t.target" 2>/dev/null)" == masked ]] || unmasked+=("$t")
    done
    (( ${#unmasked[@]} == 0 )) && pass "sleep/suspend/hibernate masked" || fail "not masked: ${unmasked[*]}"
    check "GNOME first-login wizard skipped (/etc/skel/.config/gnome-initial-setup-done)" test -f /etc/skel/.config/gnome-initial-setup-done
    check "gdm running" systemctl is-active --quiet gdm
    check "grd-instance.service enabled" systemctl is-enabled --quiet grd-instance.service
    [[ "$(cat /var/lib/grd-instance/machine-id 2>/dev/null)" == "$mid" ]] && pass "RDP set up for this clone (machine-id matches)" \
                                                                        || fail "RDP not set up for this clone"
    c=/root/rdp-credentials.txt
    [[ -f "$c" && "$(mode_of "$c")" == 600 ]] && pass "$c present, 600" || fail "$c missing or not 600"
    check "gnome-remote-desktop running" systemctl is-active --quiet gnome-remote-desktop
    ss -ltn 2>/dev/null | grep -q ':3389 ' && pass "RDP listening on port 3389" || fail "nothing listening on port 3389"
    grdctl --system status 2>/dev/null | grep -A3 -i '^RDP' | grep -qi 'enabled' \
        && pass "grdctl: RDP enabled" || warn "could not confirm RDP is enabled (grdctl --system status)"
fi

# =============================================================================
echo -e "\n${B}Result:${N} ${G}${PASSES} passed${N}, ${Y}${WARNS} warnings${N}, ${R}${FAILS} failed${N}"
(( FAILS == 0 ))
