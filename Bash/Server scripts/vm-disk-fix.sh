#!/usr/bin/env bash
# Remediation companion to vm-disk-triage.sh. Dry run by default: changes nothing.
# Usage: ./vm-disk-fix.sh              (dry run, prints 'would: ...')
#        ./vm-disk-fix.sh --apply      (safe fixes only)
#        ./vm-disk-fix.sh --help       (all flags)
set -euo pipefail
set +x

# Keep any bash temp files off the full disk.
if [ -d /dev/shm ] && [ -w /dev/shm ]; then
  export TMPDIR=/dev/shm
else
  TMPDIR=/run/user/$(id -u)
  export TMPDIR
fi
export LC_ALL=C
umask 022

usage() {
  cat <<'EOF'
vm-disk-fix.sh: free disk space on a VM cloned from an old template.
Dry run by default: prints 'would: ...' with sizes and changes nothing.

  --apply            perform the safe fixes below
  --log-limit=SIZE   truncate threshold for /var/log logs (default 500M)
  --journal-size=SIZE  journal vacuum target and SystemMaxUse (default 200M)

Safe fixes (done with --apply), in this order:
  1. truncate -s 0 /var/log/syslog, mail.log and any /var/log/*.log over the
     limit (rotated .1/.gz files are kept)
  2. apt-get clean
  3. remove /var/cache/netdata and /var/log/journal/*.netdata, only if
     netdata is not active and no netdata process runs
  4. journalctl --vacuum-size
  5. mask serial-getty@ttyS0 only if there is no real UART
  6. write /etc/systemd/journald.conf.d/size-limit.conf if no limit is set

Opt-in fixes (need their own flag, and --apply to act):
  --crash            delete /var/crash/*
  --postfix          stop postfix, purge its queue, truncate /var/mail/root
                     if over 1M, then disable it (no local mail after this).
                     Refuses if /var/mail has mail newer than 7 days.
  --force            override the 7-day mail check for --postfix
  --fix-mailname     set postfix myhostname and /etc/mailname to the real
                     hostname (only if postfix stays enabled)
  --shrink-swap=SIZE recreate a swapfile at SIZE (file only, under 5% used,
                     enough free RAM; not zram, not btrfs)

  -h, --help, --list show this text
Never touches /var/lib/docker, containerd, volumes or /mnt.
EOF
}

# Size argument to bytes (IEC: 500M, 2G). Empty on error.
size_arg() {
  local b
  b=$({ numfmt --from=iec -- "$1" 2>/dev/null; } || true)
  case "$b" in ''|*[!0-9]*) return 0 ;; esac
  [ "$b" -gt 0 ] && echo "$b"
  return 0
}
argerr() {
  printf 'error: %s (see --help)\n' "$1" | tr -d '\000-\010\013-\037\177' >&2
  exit 2
}

APPLY=0 POSTFIX=0 FIX_MAILNAME=0 CRASH=0 FORCE=0 SHRINK=""
LOG_LIMIT=524288000 JOURNAL_SIZE=209715200
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --postfix) POSTFIX=1 ;;
    --fix-mailname) FIX_MAILNAME=1 ;;
    --crash) CRASH=1 ;;
    --force) FORCE=1 ;;
    --shrink-swap=*) SHRINK=$(size_arg "${a#*=}"); [ -n "$SHRINK" ] || argerr "bad size: $a" ;;
    --log-limit=*) LOG_LIMIT=$(size_arg "${a#*=}"); [ -n "$LOG_LIMIT" ] || argerr "bad size: $a" ;;
    --journal-size=*) JOURNAL_SIZE=$(size_arg "${a#*=}"); [ -n "$JOURNAL_SIZE" ] || argerr "bad size: $a" ;;
    -h|--help|--list) usage; exit 0 ;;
    *) argerr "unknown option: $a" ;;
  esac
done
# Round swap size up to whole MiB (dd fallback writes MiB blocks).
if [ -n "$SHRINK" ]; then
  SHRINK=$(( (SHRINK + 1048575) / 1048576 * 1048576 ))
fi

# Test hook. DISK_FIX_ROOT=/abs/dir runs against a sandbox:
#  - every path is prefixed with it, and $DISK_FIX_ROOT/bin goes first on PATH
#  - every command in STUBS must resolve to a stub in that bin dir
#  - it refuses to run as root, and every write is checked to stay inside
# Unset (normal use): R is empty, paths and commands are the real ones.
STUBS=(systemctl journalctl apt-get postsuper postqueue postconf swapon swapoff mkswap fallocate blkid pgrep hostname)
R=""
if [ -n "${DISK_FIX_ROOT:-}" ]; then
  R=$(readlink -f -- "$DISK_FIX_ROOT" 2>/dev/null) || R=""
  if [ -z "$R" ] || [ "$R" = / ] || [ ! -d "$R/bin" ]; then
    echo "error: DISK_FIX_ROOT must be a sandbox dir with a bin/ of stubs" >&2; exit 2
  fi
  if [ "$(id -u)" -eq 0 ]; then
    echo "error: refusing to run the sandbox as root" >&2; exit 2
  fi
  PATH="$R/bin:$PATH"
  for c in "${STUBS[@]}"; do
    if [ "$(command -v "$c" 2>/dev/null || true)" != "$R/bin/$c" ]; then
      echo "error: sandbox is missing stub $R/bin/$c" >&2; exit 2
    fi
  done
elif [ "$(id -u)" -ne 0 ]; then
  # Needs root. Re-exec via sudo -n (sudo also drops DISK_FIX_ROOT).
  if sudo -n true 2>/dev/null; then
    exec sudo -n -- "$BASH" "$(readlink -f -- "${BASH_SOURCE[0]}")" "$@"
  fi
  echo "error: vm-disk-fix.sh needs root; run it with sudo (sudo -n is not available)" >&2
  exit 1
fi

sec() { printf '\n=== %s ===\n' "$*"; }
# Strip control chars (keep tab, newline), plus C1 controls via perl. Same as vm-disk-triage.sh.
if command -v perl >/dev/null 2>&1; then
  clean() {
    perl -pe 's/[\x00-\x08\x0B-\x1F\x7F]//g;
      s/(\xC2[\x80-\x9F])|([\xC2-\xDF][\x80-\xBF]|\xE0[\xA0-\xBF][\x80-\xBF]|[\xE1-\xEC\xEE\xEF][\x80-\xBF]{2}|\xED[\x80-\x9F][\x80-\xBF]|\xF0[\x90-\xBF][\x80-\xBF]{2}|[\xF1-\xF3][\x80-\xBF]{3}|\xF4[\x80-\x8F][\x80-\xBF]{2})|[\x80-\x9F]/defined $2 ? $2 : ""/ge'
  }
else
  clean() { tr -d '\000-\010\013-\037\177'; }
fi
# Print one sanitised line. Use for anything holding a path or name.
say() { printf '%s' "$*" | tr '\n\t' '??' | clean; echo; }
# First line of a quiet, time-limited command. Never fails.
q() { { timeout 10 "$@" 2>/dev/null | head -1; } || true; }
num() { case "${1:-}" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
iec() { numfmt --to=iec "$(num "$1")"; }
# Size for config files: IEC if exact, else bytes.
csz() {
  local h
  h=$(iec "$1")
  if [ "$(numfmt --from=iec "$h" 2>/dev/null || true)" = "$1" ]; then echo "$h"; else echo "$1"; fi
}
# Allocated KiB of the given paths (total). Missing paths count as 0.
kb_of() {
  local k
  k=$({ timeout 300 du -xsck -- "$@" 2>/dev/null | awk 'END{print $1+0}'; } || true)
  num "$k"
}
dfline() {
  { timeout 20 df -h --output=size,used,avail,pcent "${R:-/}" 2>/dev/null | tail -1; } || echo "df unavailable"
}

# Refuse writes outside the sandbox (when set) and on protected paths.
target_ok() {
  local rp rel
  rp=$(readlink -f -- "$1" 2>/dev/null) || { say "refuse: cannot resolve $1"; return 1; }
  if [ -n "$R" ]; then
    case "$rp" in "$R"/*) ;; *) say "refuse: $1 is outside the sandbox"; return 1 ;; esac
  fi
  rel=${rp#"$R"}
  case "$rel" in
    /|/var/lib/docker|/var/lib/docker/*|/var/lib/containerd|/var/lib/containerd/*|/mnt|/mnt/*)
      say "refuse: $1 is a protected path"; return 1 ;;
  esac
  return 0
}

FREED=0 PLAN=0 FAILS=0
# act DESC CMD...: dry run prints 'would:', apply runs CMD and prints 'did:' or 'FAIL:'.
act() {
  local desc=$1 rc=0
  shift
  if [ "$APPLY" -eq 0 ]; then say "would: $desc"; return 0; fi
  "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then say "did: $desc"
  else say "FAIL: $desc (rc=$rc)"; FAILS=$((FAILS + 1)); fi
  return "$rc"
}
# account EST_BYTES BEFORE_KB MEASURE_FN ARGS...: add the estimate (dry run)
# or the measured drop (apply) to the totals.
account() {
  local est=$1 before=$2 after d
  shift 2
  if [ "$APPLY" -eq 0 ]; then PLAN=$((PLAN + est)); return 0; fi
  after=$("$@")
  d=$(( (before - after) * 1024 ))
  [ "$d" -ge 0 ] || d=0
  FREED=$((FREED + d))
  echo "      freed $(iec "$d")"
}
# Run quietly (stdout dropped), for chatty tools like mkswap.
quiet() { "$@" >/dev/null; }
# State of a unit: first line of is-active / is-enabled.
uact() { q systemctl is-active "$1"; }
uen() { q systemctl is-enabled "$1"; }

MODE="dry run (no changes)"
[ "$APPLY" -eq 1 ] && MODE="apply"
FLAGS=""
[ "$POSTFIX" -eq 1 ] && FLAGS="$FLAGS --postfix"
[ "$FIX_MAILNAME" -eq 1 ] && FLAGS="$FLAGS --fix-mailname"
[ "$CRASH" -eq 1 ] && FLAGS="$FLAGS --crash"
[ "$FORCE" -eq 1 ] && FLAGS="$FLAGS --force"
[ -n "$SHRINK" ] && FLAGS="$FLAGS --shrink-swap=$(iec "$SHRINK")"
say "vm-disk-fix on $(q hostname) at $(date -Is): $MODE${FLAGS:+ |$FLAGS}"
[ -n "$R" ] && say "SANDBOX: $R"
echo "log limit $(iec "$LOG_LIMIT"), journal target $(iec "$JOURNAL_SIZE")"
DF_BEFORE=$(dfline)
echo "df / before: size used avail use% = $DF_BEFORE"

# 1. Runaway logs. Truncate, never rm, so open handles stay valid.
fix_logs() {
  sec "1. Logs over $(iec "$LOG_LIMIT") in /var/log"
  local d="$R/var/log" f sz kb dev n=0
  local -A seen=()
  dev=$({ stat -c %d -- "$d" 2>/dev/null; } || true)
  for f in "$d/syslog" "$d/mail.log" "$d"/*.log; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ -z "${seen[$f]+x}" ] || continue
    seen[$f]=1
    [ "$({ stat -c %d -- "$f" 2>/dev/null; } || true)" = "$dev" ] || continue
    sz=$(num "$({ stat -c %s -- "$f" 2>/dev/null; } || true)")
    [ "$sz" -gt "$LOG_LIMIT" ] || continue
    n=$((n + 1))
    target_ok "$f" || continue
    kb=$(kb_of "$f")
    if act "truncate -s 0 $f (size $(iec "$sz"), frees $(iec $((kb * 1024))))" \
        timeout 60 truncate -s 0 -- "$f"; then
      account $((kb * 1024)) "$kb" kb_of "$f"
    fi
  done
  [ "$n" -gt 0 ] || echo "ok: no syslog, mail.log or /var/log/*.log over the limit"
  return 0
}

# 2. apt cache: .deb archives, partial downloads, *.bin caches.
apt_kb() {
  local k
  k=$({ timeout 120 find "$R/var/cache/apt" -xdev \
      \( -path "$R/var/cache/apt/archives/*.deb" -o -path "$R/var/cache/apt/archives/partial/*" \
         -o \( -path "$R/var/cache/apt/*.bin" ! -path "$R/var/cache/apt/*/*" \) \) \
      -type f -printf '%k\n' 2>/dev/null | awk '{s+=$1} END{print s+0}'; } || true)
  num "$k"
}
fix_apt() {
  sec "2. apt cache"
  local kb
  if ! command -v apt-get >/dev/null 2>&1; then echo "ok: no apt-get"; return 0; fi
  kb=$(apt_kb)
  if [ "$kb" -eq 0 ]; then echo "ok: apt cache already clean"; return 0; fi
  if act "apt-get clean (frees $(iec $((kb * 1024))))" timeout 120 apt-get clean; then
    account $((kb * 1024)) "$kb" apt_kb
  fi
  return 0
}

# 3. Netdata leftovers, only when netdata is not running in any form.
fix_netdata() {
  sec "3. Netdata leftovers"
  local t kb st jst en
  local -a tg=()
  if [ -d "$R/var/cache/netdata" ] && [ ! -L "$R/var/cache/netdata" ]; then tg+=("$R/var/cache/netdata"); fi
  for t in "$R/var/log/journal"/*.netdata; do
    [ -d "$t" ] && [ ! -L "$t" ] && tg+=("$t")
  done
  if [ "${#tg[@]}" -eq 0 ]; then echo "ok: no /var/cache/netdata or journal/*.netdata"; return 0; fi
  st=$(uact netdata); en=$(uen netdata); jst=$(uact systemd-journald@netdata)
  say "netdata active=${st:-?} enabled=${en:--} journald@netdata active=${jst:-?}"
  case "$st" in inactive|failed) ;; *) say "skip: netdata unit is '${st:-unknown}', leftovers kept"; return 0 ;; esac
  case "$jst" in inactive|failed) ;; *) say "skip: systemd-journald@netdata is '${jst:-unknown}', kept"; return 0 ;; esac
  if timeout 10 pgrep -x netdata >/dev/null 2>&1; then
    echo "skip: a netdata process is running (container?), leftovers kept"; return 0
  fi
  for t in "${tg[@]}"; do
    target_ok "$t" || continue
    kb=$(kb_of "$t")
    if act "rm -rf $t (frees $(iec $((kb * 1024))))" timeout 300 rm -rf --one-file-system -- "$t"; then
      account $((kb * 1024)) "$kb" kb_of "$t"
    fi
  done
  return 0
}

# Opt-in: crash dumps.
fix_crash() {
  sec "4. Crash dumps (/var/crash, needs --crash)"
  local t kb tot=0
  local -a tg=()
  for t in "$R/var/crash"/*; do
    [ -e "$t" ] || [ -L "$t" ] || continue
    tg+=("$t")
  done
  if [ "${#tg[@]}" -eq 0 ]; then echo "ok: /var/crash is empty"; return 0; fi
  tot=$(kb_of "${tg[@]}")
  if [ "$CRASH" -eq 0 ]; then
    echo "skip: ${#tg[@]} entries in /var/crash ($(iec $((tot * 1024)))); use --crash to delete"
    return 0
  fi
  for t in "${tg[@]}"; do
    target_ok "$t" || continue
    kb=$(kb_of "$t")
    if act "rm -rf $t (frees $(iec $((kb * 1024))))" timeout 120 rm -rf --one-file-system -- "$t"; then
      account $((kb * 1024)) "$kb" kb_of "$t"
    fi
  done
  return 0
}

# Opt-in: postfix bounce loop.
PF_OFF=0
pf_kb() { kb_of "$R/var/spool/postfix" "$R/var/mail/root"; }
fix_postfix() {
  sec "5. Postfix (needs --postfix)"
  local pa pe ia ie pq spool mb mbk kb
  local -a fresh=()
  if ! command -v postsuper >/dev/null 2>&1 && [ ! -d "$R/var/spool/postfix" ]; then
    echo "ok: postfix not installed"; return 0
  fi
  pa=$(uact postfix); pe=$(uen postfix)
  # Ubuntu runs the real MTA as postfix@-, normally pulled in by postfix.service.
  ia=$(uact postfix@-.service); ie=$(uen postfix@-.service)
  spool=$(kb_of "$R/var/spool/postfix")
  mb="$R/var/mail/root"
  mbk=$(kb_of "$mb")
  pq=""
  if [ "$pa" = active ]; then
    pq=$({ timeout 60 postqueue -p 2>/dev/null | awk '
        /^Mail queue is empty/{n=0}
        /^-- .* in [0-9]+ Requests?\.$/{n=$(NF-1)}
        END{if (n != "") print n}'; } || true)
  fi
  if [ -z "$pq" ]; then
    pq=$({ timeout 60 find "$R/var/spool/postfix/incoming" "$R/var/spool/postfix/active" \
        "$R/var/spool/postfix/deferred" "$R/var/spool/postfix/hold" "$R/var/spool/postfix/maildrop" \
        -type f 2>/dev/null | wc -l; } || true)
  fi
  pq=$(num "$pq")
  say "postfix active=${pa:-?} enabled=${pe:-?} postfix@- active=${ia:-?} enabled=${ie:-?} queue=$pq spool=$(iec $((spool * 1024))) /var/mail/root=$(iec $((mbk * 1024)))"
  if [ "$pa" != active ] && [ "${pe#enabled}" = "$pe" ] && [ "$ia" != active ] && [ "${ie#enabled}" = "$ie" ]; then
    echo "ok: postfix not running or enabled"; return 0
  fi
  if [ "$POSTFIX" -eq 0 ]; then
    echo "skip: postfix is running/enabled; use --postfix to purge the queue and disable it"
    return 0
  fi
  mapfile -t fresh < <({ timeout 30 find "$R/var/mail" -mindepth 1 -maxdepth 1 -type f -size +0c -mtime -7 2>/dev/null | clean; } || true)
  if [ "${#fresh[@]}" -gt 0 ] && [ "$FORCE" -eq 0 ]; then
    say "refuse: mail newer than 7 days in /var/mail: ${fresh[*]##*/}"
    echo "      read it first (it may be the loop's own bounces), then rerun with --force"
    return 0
  fi
  [ "${#fresh[@]}" -gt 0 ] && say "note: --force given, ignoring fresh mail in: ${fresh[*]##*/}"
  echo "note: disabling postfix means no local mail delivery (cron/sudo notices are dropped)"
  kb=$((spool + mbk))
  act "systemctl stop postfix" timeout 120 systemctl stop postfix || return 0
  act "postsuper -d ALL ($pq queued; spool + mailbox $(iec $((kb * 1024))))" timeout 300 postsuper -d ALL || true
  if [ -f "$mb" ] && [ ! -L "$mb" ] && [ "$(num "$(stat -c %s -- "$mb" 2>/dev/null || true)")" -gt 1048576 ]; then
    if target_ok "$mb"; then
      act "truncate -s 0 $mb ($(iec $((mbk * 1024))))" timeout 60 truncate -s 0 -- "$mb" || true
    fi
  fi
  if act "systemctl disable --now postfix" timeout 120 systemctl disable --now postfix; then
    PF_OFF=1
    echo "      undo: systemctl enable --now postfix"
  fi
  if [ "${ie#enabled}" != "$ie" ]; then
    act "systemctl disable --now postfix@-.service" timeout 120 systemctl disable --now postfix@-.service || true
  fi
  account $((kb * 1024)) "$kb" pf_kb
  return 0
}

# 4. Journal vacuum. Measures /var/log/journal without *.netdata namespaces.
journal_kb() {
  local k
  k=$({ timeout 120 du -xsk --exclude='*.netdata' -- "$R/var/log/journal" 2>/dev/null | awk 'END{print $1+0}'; } || true)
  num "$k"
}
fix_journal() {
  sec "6. journald size"
  local kb tgt
  if ! command -v journalctl >/dev/null 2>&1; then echo "ok: no journalctl"; return 0; fi
  kb=$(journal_kb)
  tgt=$JOURNAL_SIZE
  if [ $((kb * 1024)) -le "$tgt" ]; then
    echo "ok: /var/log/journal is $(iec $((kb * 1024))), within $(iec "$tgt")"; return 0
  fi
  if act "journalctl --vacuum-size=$(csz "$tgt") (journal $(iec $((kb * 1024))), frees about $(iec $((kb * 1024 - tgt))))" \
      timeout 300 journalctl --vacuum-size="$tgt"; then
    account $((kb * 1024 - tgt)) "$kb" journal_kb
    [ "$APPLY" -eq 1 ] && echo "      note: active journal files are kept, so it may stay a little over"
  fi
  return 0
}

# 5. serial-getty@ttyS0 on a VM with no real UART.
fix_getty() {
  sec "7. serial-getty@ttyS0"
  local u=serial-getty@ttyS0.service ua ue un ut real why
  if ! command -v systemctl >/dev/null 2>&1; then echo "ok: no systemctl"; return 0; fi
  ua=$(uact "$u"); ue=$(uen "$u")
  un=$(q systemctl show -p NRestarts --value "$u")
  ut=$(q cat "$R/sys/class/tty/ttyS0/type")
  if [ ! -e "$R/dev/ttyS0" ]; then real=no why="/dev/ttyS0 absent"
  elif [ "$ut" = 0 ]; then real=no why="uart type 0"
  else real=yes why="uart type ${ut:-unreadable}"
  fi
  say "$u active=${ua:-?} enabled=${ue:-?} restarts=${un:-?} real serial: $real ($why)"
  if [ "${ue#masked}" != "$ue" ]; then echo "ok: already masked"; return 0; fi
  if [ "$real" = yes ]; then echo "ok: real UART present, left alone"; return 0; fi
  if act "systemctl mask --now $u" timeout 60 systemctl mask --now "$u"; then
    echo "      undo: systemctl unmask $u && systemctl start $u"
  fi
  return 0
}

# 6. Persistent journald size limit.
JCONF="$R/etc/systemd/journald.conf.d/size-limit.conf"
write_jconf() {
  local rt=52428800
  [ "$JOURNAL_SIZE" -lt "$rt" ] && rt=$JOURNAL_SIZE
  target_ok "${JCONF%/*}" || return 1
  mkdir -p -- "${JCONF%/*}" &&
    printf '# Written by vm-disk-fix.sh\n[Journal]\nSystemMaxUse=%s\nRuntimeMaxUse=%s\n' \
      "$(csz "$JOURNAL_SIZE")" "$(csz "$rt")" > "$JCONF"
}
fix_jconf() {
  sec "8. journald size limit drop-in"
  local f
  local -a hit=()
  if [ -e "$JCONF" ]; then say "ok: $JCONF present"; return 0; fi
  for f in "$R/etc/systemd/journald.conf" "$R/etc/systemd/journald.conf.d"/*.conf; do
    [ -f "$f" ] || continue
    if grep -qs '^[[:space:]]*SystemMaxUse=' -- "$f"; then hit+=("$f"); fi
  done
  if [ "${#hit[@]}" -gt 0 ]; then say "ok: SystemMaxUse already set in ${hit[*]}"; return 0; fi
  if act "write $JCONF (SystemMaxUse=$(csz "$JOURNAL_SIZE"))" write_jconf; then
    echo "      note: takes effect on the next journald restart (systemctl restart systemd-journald)"
  fi
  return 0
}

# Opt-in: postfix name left over from the template.
write_mailname() { target_ok "$R/etc/mailname" && printf '%s\n' "$1" > "$R/etc/mailname"; }
fix_mailname() {
  sec "9. Postfix mail name (needs --fix-mailname)"
  local hn mh mn n bad=0 old="" pa pe md
  if ! command -v postconf >/dev/null 2>&1; then echo "ok: postfix not installed"; return 0; fi
  hn=$(q hostname)
  mh=$(q postconf -h myhostname)
  mn=""
  [ -r "$R/etc/mailname" ] && mn=$(q head -1 "$R/etc/mailname")
  say "hostname=${hn:-?} myhostname=${mh:--} mailname=${mn:--}"
  for n in "$mh" "$mn"; do
    [ -n "$n" ] || continue
    if [ "${n%%.*}" != "${hn%%.*}" ]; then bad=1; old=${old:-$n}; fi
  done
  if [ "$bad" -eq 0 ]; then echo "ok: names match hostname"; return 0; fi
  if [ "$PF_OFF" -eq 1 ]; then echo "skip: postfix is being disabled by --postfix"; return 0; fi
  pa=$(uact postfix); pe=$(uen postfix)
  if [ "$pa" != active ] && [ "${pe#enabled}" = "$pe" ]; then echo "skip: postfix not enabled"; return 0; fi
  if [ "$FIX_MAILNAME" -eq 0 ]; then say "skip: name mismatch; use --fix-mailname to set it to '$hn'"; return 0; fi
  case "$hn" in
    ''|*[!A-Za-z0-9.-]*|[.-]*) say "refuse: hostname '$hn' is not a plain host name"; return 0 ;;
  esac
  if [ "${mh%%.*}" != "${hn%%.*}" ]; then
    act "postconf -e myhostname=$hn" timeout 30 postconf -e "myhostname=$hn" || return 0
  fi
  if [ -n "$mn" ] && [ "${mn%%.*}" != "${hn%%.*}" ]; then
    act "write $R/etc/mailname = $hn" write_mailname "$hn" || return 0
  fi
  if [ "$pa" = active ]; then act "systemctl reload postfix" timeout 60 systemctl reload postfix || true; fi
  md=$(q postconf -h mydestination)
  case "$md" in *"$old"*) say "note: mydestination still lists '$old'; check it by hand" ;; esac
  return 0
}

# Opt-in: shrink a mostly idle swapfile.
mkswapfile() {
  # mkswapfile PATH BYTES USE_DD
  local p=$1 b=$2 dd=$3
  target_ok "$p" || return 1
  truncate -s 0 -- "$p" || return 1
  if [ "$dd" -eq 0 ]; then
    timeout 300 fallocate -l "$b" -- "$p" || return 1
  else
    timeout 1800 dd if=/dev/zero of="$p" bs=1M count=$((b / 1048576)) status=none conv=fsync || return 1
  fi
  chmod 600 -- "$p"
}
fix_swap() {
  sec "10. Swap (needs --shrink-swap=SIZE)"
  local sw name type size used prio p="" ps=0 pu=0 pp=0 nf=0 zr=0 zs=0 fs ma opts pri uuid
  local -a mk=() on=()
  sw=$({ timeout 10 swapon --show=NAME,TYPE,SIZE,USED,PRIO --bytes --noheadings --raw 2>/dev/null | clean; } || true)
  while read -r name type size used prio; do
    [ -n "${name:-}" ] || continue
    case "$name" in /dev/zram*) zr=1; continue ;; esac
    if [ "$type" = file ]; then
      nf=$((nf + 1)); p=$name ps=$(num "$size") pu=$(num "$used")
      case "${prio:-}" in -[0-9]*|[0-9]*) pp=$prio ;; *) pp=-1 ;; esac
    fi
  done < <(printf '%s\n' "$sw")
  case "$(q cat "$R/sys/module/zswap/parameters/enabled")" in Y|y|1) zs=1 ;; esac
  if [ -z "$sw" ]; then echo "ok: no active swap"; return 0; fi
  printf '%s\n' "$sw" | while read -r name type size used prio; do
    say "$name $type size=$(iec "$size") used=$(iec "$used") prio=$prio"
  done
  if [ -z "$SHRINK" ]; then
    if [ "$nf" -eq 1 ] && [ "$ps" -gt 2147483648 ] && [ $((pu * 20)) -lt "$ps" ]; then
      say "skip: $p is $(iec "$ps") with $(iec "$pu") used; --shrink-swap=SIZE to shrink"
    else
      echo "ok: nothing to do without --shrink-swap"
    fi
    return 0
  fi
  [ "$zr" -eq 0 ] || { echo "refuse: zram swap in use; not touching the swap model"; return 0; }
  [ "$nf" -ge 1 ] || { echo "refuse: no active swapfile (partition or zram only)"; return 0; }
  [ "$nf" -eq 1 ] || { echo "refuse: more than one swapfile; shrink by hand"; return 0; }
  if [ ! -f "$p" ] || [ -L "$p" ]; then say "refuse: $p is not a regular file"; return 0; fi
  target_ok "$p" || return 0
  if [ "$SHRINK" -lt 33554432 ]; then echo "refuse: --shrink-swap below 32M"; return 0; fi
  if [ "$SHRINK" -ge "$ps" ]; then say "ok: $p is $(iec "$ps"), not bigger than $(iec "$SHRINK")"; return 0; fi
  if [ $((pu * 20)) -ge "$ps" ]; then say "refuse: $p is $(iec "$pu") used, 5% or more"; return 0; fi
  ma=$(num "$({ awk '/^MemAvailable:/{print $2; exit}' "$R/proc/meminfo" 2>/dev/null; } || true)")
  if [ $((ma * 1024)) -le $((pu + 268435456)) ]; then
    echo "refuse: MemAvailable $(iec $((ma * 1024))) is not above swap used + 256M"; return 0
  fi
  fs=$(q stat -f -c %T -- "$p")
  if [ "$fs" = btrfs ]; then echo "refuse: swapfile on btrfs (needs btrfs filesystem mkswapfile)"; return 0; fi
  [ "$zs" -eq 1 ] && say "note: $p is the zswap writeback backing; zswap keeps working on a smaller file"
  uuid=$(q blkid -o value -s UUID -- "$p")
  case "$uuid" in *[!0-9A-Fa-f-]*) uuid="" ;; esac
  opts=$({ awk -v p="$p" -v u="UUID=$uuid" '$1 !~ /^#/ && ($1==p || (u != "UUID=" && $1==u)) && $3=="swap" {print $4; exit}' \
      "$R/etc/fstab" 2>/dev/null | clean; } || true)
  pri=""
  case ",$opts," in *,pri=*) pri=${opts#*pri=}; pri=${pri%%,*} ;; esac
  case "$pri" in ''|*[!0-9]*) pri="" ;; esac
  [ -n "$pri" ] || { [ "$pp" -ge 0 ] && pri=$pp; } || true
  if [ -n "$opts" ]; then say "fstab: $p swap $opts (left unchanged)"
  else say "note: $p is not in /etc/fstab; it will not come back after reboot (unchanged)"; fi
  mk=(mkswap); [ -n "$uuid" ] && mk+=(-U "$uuid")
  on=(swapon); [ -n "$pri" ] && on+=(-p "$pri")
  local kb
  kb=$(kb_of "$p")
  act "swapoff $p ($(iec "$pu") moves to RAM)" timeout 600 swapoff -- "$p" || return 0
  local ok=0 f0=$FAILS
  if act "recreate $p at $(iec "$SHRINK") with fallocate (dd if that fails), chmod 600, frees $(iec $((ps - SHRINK)))" mkswapfile "$p" "$SHRINK" 0 \
     || act "recreate $p at $(iec "$SHRINK") with dd" mkswapfile "$p" "$SHRINK" 1; then
    if act "${mk[*]} $p" quiet timeout 60 "${mk[@]}" -- "$p" && act "${on[*]} $p" timeout 60 "${on[@]}" -- "$p"; then
      ok=1
    elif [ "$APPLY" -eq 1 ]; then
      # fallocate files can have unwritten extents some kernels reject; retry with dd.
      act "retry: recreate $p with dd" mkswapfile "$p" "$SHRINK" 1 &&
        act "${mk[*]} $p" quiet timeout 60 "${mk[@]}" -- "$p" &&
        act "${on[*]} $p" timeout 60 "${on[@]}" -- "$p" && ok=1
    fi
  fi
  if [ "$ok" -eq 0 ] && [ "$APPLY" -eq 1 ]; then
    say "FAIL: $p is NOT active swap now. Fix by hand: fallocate/dd, chmod 600, mkswap, swapon $p"
    return 0
  fi
  # Recovered via a fallback: do not count the earlier FAIL lines.
  FAILS=$f0
  account $((ps - SHRINK)) "$kb" kb_of "$p"
  return 0
}

# Space-freeing steps first, small writes after.
fix_logs
fix_apt
fix_netdata
fix_crash
fix_postfix
fix_journal
fix_getty
fix_jconf
fix_mailname
fix_swap

sec "Summary"
echo "df / before: $DF_BEFORE"
if [ "$APPLY" -eq 1 ]; then
  echo "df / after:  $(dfline)"
  echo "freed (measured): $(iec "$FREED") ($FREED bytes)"
else
  echo "would free about $(iec "$PLAN") ($PLAN bytes); nothing was changed"
  echo "rerun with --apply (and any opt-in flags) to act"
fi
[ "$FAILS" -eq 0 ] || echo "WARN: $FAILS step(s) failed, see FAIL lines above"
echo "Run vm-disk-triage.sh again to confirm."
[ "$FAILS" -eq 0 ]
