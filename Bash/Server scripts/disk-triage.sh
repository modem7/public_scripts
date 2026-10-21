#!/usr/bin/env bash
# Read-only disk triage for a full Docker host. Deletes nothing.
# Usage: ./disk-triage.sh 2>&1 | tee /dev/shm/triage.txt
set -euo pipefail
set +x

# Keep sort/bash temp files off the full disk.
if [ -d /dev/shm ] && [ -w /dev/shm ]; then
  export TMPDIR=/dev/shm
else
  TMPDIR=/run/user/$(id -u)
  export TMPDIR
fi
export LC_ALL=C
# fd 3 = real stdout, so timeout notes skip pipes and captures.
exec 3>&1

# Sudo if available, never fatal.
SUDO=()
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then
    SUDO=(sudo -n)
  elif [ -t 0 ] && sudo -v 2>/dev/null; then
    SUDO=(sudo -n)
  fi
fi

DOCKER=()
if timeout 20 docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif [ "${#SUDO[@]}" -gt 0 ] && timeout 20 "${SUDO[@]}" docker info >/dev/null 2>&1; then
  DOCKER=("${SUDO[@]}" docker)
fi

sec() { printf '\n=== %s ===\n' "$*"; }
sub() { printf -- '--- %s\n' "$*"; }

# Run with timeout, print a short note on failure, never abort.
t() {
  local secs=$1 rc=0
  shift
  local what="$*"
  what=${what#sudo -n }
  what=${what:0:60}
  timeout "$secs" "$@" || rc=$?
  if [ "$rc" -eq 124 ]; then echo "  [timed out after ${secs}s: $what]" >&3
  elif [ "$rc" -ne 0 ] && [ "$rc" -ne 141 ]; then echo "  [rc=$rc, may be partial: $what]" >&3; fi
  return 0
}
# Same, as root when possible.
st() {
  local secs=$1
  shift
  t "$secs" "${SUDO[@]}" "$@"
}
# du -sh one path, quiet.
dush() { st 120 du -xsh "$@" 2>/dev/null; }

printf 'disk-triage on %s at %s\n' "$(hostname)" "$(date -Is)"
printf 'kernel %s | sudo: %s | docker: %s\n' "$(uname -r)" \
  "$([ "${#SUDO[@]}" -gt 0 ] || [ "$(id -u)" -eq 0 ] && echo yes || echo no)" \
  "$([ "${#DOCKER[@]}" -gt 0 ] && echo "${DOCKER[*]}" || echo unavailable)"

sec "1. Filesystems"
FSX=(-x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x nsfs -x fuse.snapfuse)
t 30 df -hT "${FSX[@]}" 2>/dev/null
sub "inodes"
t 30 df -i "${FSX[@]}" 2>/dev/null
sub "lsblk"
t 30 lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null

sec "2. Largest dirs on / (du -x depth 2, top 15)"
{ st 600 du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -15; } || true

sec "3. Docker"
if [ "${#DOCKER[@]}" -eq 0 ]; then
  echo "docker not reachable (not installed, not running, or no permission)"
  DROOT=/var/lib/docker
else
  DROOT=$(t 20 "${DOCKER[@]}" info --format '{{.DockerRootDir}}' 2>/dev/null | head -1) || true
  [ -n "$DROOT" ] && [ "${DROOT#/}" != "$DROOT" ] || DROOT=/var/lib/docker
  t 20 "${DOCKER[@]}" info --format \
    'version={{.ServerVersion}} root={{.DockerRootDir}} driver={{.Driver}} {{json .DriverStatus}} logdriver={{.LoggingDriver}}' 2>/dev/null
  sub "docker system df"
  t 120 "${DOCKER[@]}" system df 2>&1
  DFV=$(t 180 "${DOCKER[@]}" system df -v 2>/dev/null) || true
  sub "top 10 images by size"
  { t 60 "${DOCKER[@]}" images --format '{{.Size}}\t{{.Repository}}:{{.Tag}}\t{{.ID}}' 2>/dev/null \
      | sort -rh | head -10; } || true
  sub "top 10 volumes by size (name links size)"
  { printf '%s\n' "$DFV" | awk '/^Local Volumes space usage/{f=1;next} /^Build cache/{f=0} f&&NF==3&&$1!="VOLUME"{print $3"\t"$2"\t"$1}' \
      | sort -rh | head -10; } || true
  sub "build cache"
  { printf '%s\n' "$DFV" | grep -m1 '^Build cache usage' || echo "n/a"; } || true
  sub "dangling"
  printf 'dangling images: %s\n' "$({ timeout 60 "${DOCKER[@]}" images -qf dangling=true 2>/dev/null | wc -l; } || true)"
  printf 'dangling volumes: %s\n' "$({ timeout 60 "${DOCKER[@]}" volume ls -qf dangling=true 2>/dev/null | wc -l; } || true)"
  printf 'stopped containers: %s\n' "$({ timeout 60 "${DOCKER[@]}" ps -aq -f status=exited -f status=created -f status=dead 2>/dev/null | wc -l; } || true)"
  sub "top 15 containers by writable layer (size (virtual) name status)"
  { t 180 "${DOCKER[@]}" ps -as --format '{{.Size}}\t{{.Names}}\t{{.Status}}' 2>/dev/null \
      | sort -rh | head -15; } || true
fi

sub "data root: $DROOT"
t 20 df -hT "$DROOT" 2>/dev/null
sub "data root subdirs"
for d in overlay2 volumes containers image buildkit containerd tmp; do
  [ -e "$DROOT/$d" ] || ${SUDO[@]+"${SUDO[@]}"} test -e "$DROOT/$d" 2>/dev/null || continue
  dush "$DROOT/$d"
done
if ${SUDO[@]+"${SUDO[@]}"} test -d /var/lib/containerd 2>/dev/null; then
  sub "/var/lib/containerd (containerd image store)"
  { st 300 du -xh --max-depth=1 /var/lib/containerd 2>/dev/null | sort -rh | head -8; } || true
fi

sub "top 15 container json logs"
declare -A CNAME=()
if [ "${#DOCKER[@]}" -gt 0 ]; then
  while read -r id name; do
    [ -n "${id:-}" ] && CNAME[$id]=$name
  done < <(t 60 "${DOCKER[@]}" ps -a --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null)
fi
LOGS=$({ timeout 120 ${SUDO[@]+"${SUDO[@]}"} find "$DROOT/containers" -maxdepth 2 -name '*-json.log*' -printf '%s\t%p\n' 2>/dev/null \
  | sort -rn; } || true)
if [ -z "$LOGS" ]; then
  echo "none found (non json-file log driver, or no access)"
else
  printf '%s\n' "$LOGS" | awk -F'\t' '{s+=$1} END{printf "total json logs: %.1f MiB in %d files\n", s/1048576, NR}'
  { printf '%s\n' "$LOGS" | head -15; } | while IFS=$'\t' read -r sz path; do
    case "$sz" in ''|*[!0-9]*) continue ;; esac
    id=${path#"$DROOT/containers/"}; id=${id%%/*}
    printf '%s\t%s\t%s\n' "$(numfmt --to=iec "$sz")" "${CNAME[$id]:-?}" "${id:0:12}"
  done
fi

sec "4. Other culprits"
sub "/var/log (top 10)"
{ st 120 du -xah --max-depth=2 /var/log 2>/dev/null | sort -rh | head -10; } || true
sub "journald"
st 60 journalctl --disk-usage 2>&1 | tail -1
sub "apt cache"
dush /var/cache/apt
sub "snap"
if [ -d /var/lib/snapd ]; then
  dush /var/lib/snapd
  dush /var/lib/snapd/snaps
  if command -v snap >/dev/null 2>&1; then
    printf 'snap revisions total/disabled: %s/%s\n' \
      "$({ timeout 30 snap list --all 2>/dev/null | tail -n +2 | wc -l; } || true)" \
      "$({ timeout 30 snap list --all 2>/dev/null | awk '/disabled/{n++} END{print n+0}'; } || true)"
  fi
else
  echo "no snapd"
fi
sub "kernels (running $(uname -r))"
# shellcheck disable=SC2016
{ t 30 dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Installed-Size}\n' 'linux-image-*' 2>/dev/null \
    | awk '$1 ~ /^.i/ {print $2, int($3/1024)"M"}'; } || true
dush /boot
{ st 60 du -sh /usr/lib/modules/* 2>/dev/null | sort -rh | head -10; } || true
sub "tmp dirs"
dush /tmp /var/tmp
sub "core dumps"
dush /var/lib/systemd/coredump /var/crash
sub "/root and /home"
dush /root
{ st 300 du -xsh /home/* 2>/dev/null | sort -rh | head -10; } || true
sub "swap"
t 10 swapon --show 2>/dev/null
for f in /swapfile /swap.img; do
  [ -e "$f" ] && t 10 ls -lh "$f" 2>/dev/null
done
true

sec "5. Deleted but still open (lsof +L1, top 15)"
if command -v lsof >/dev/null 2>&1; then
  # -F fields: p pid, c cmd, f fd, s size, D dev, i inode, n name. Dedupe by dev:inode.
  { st 120 lsof -nPb +L1 -F pcfsDin 2>/dev/null | awk '
      /^p/{pid=substr($0,2); next}
      /^c/{cmd=substr($0,2); next}
      /^f/{sz=0; dev=""; ino=""; next}
      /^s/{sz=substr($0,2); next}
      /^D/{dev=substr($0,2); next}
      /^i/{ino=substr($0,2); next}
      /^n/{k=dev":"ino; if (!(k in seen) && sz>0) {seen[k]=1; tot+=sz; printf "%d\t%s\t%s\t%s\n", sz, cmd, pid, substr($0,2)}}
      END{printf "%d\tTOTAL\t-\t(unique deleted files)\n", tot}' \
    | sort -rn | head -16 | numfmt --to=iec --field=1 2>/dev/null; } || true
else
  echo "lsof not installed"
  { st 60 find /proc/[0-9]*/fd -lname '*(deleted)' -printf '%p -> %l\n' 2>/dev/null | head -15; } || true
fi

sec "6. Largest files on / over 100M (top 20)"
{ st 600 find / -xdev -type f -size +100M -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | head -20 | numfmt --to=iec --field=1 2>/dev/null; } || true

sec "7. Known template/loop culprits"
HAVE_SD=no
command -v systemctl >/dev/null 2>&1 && HAVE_SD=yes
# First line of a quiet, time-limited command. Never fails.
q() { { timeout 10 "$@" 2>/dev/null | head -1; } || true; }
# du -sk total of the given paths, as root when possible.
kbof() {
  local k
  k=$({ timeout 60 ${SUDO[@]+"${SUDO[@]}"} du -xsck "$@" 2>/dev/null | awk 'END{print $1+0}'; } || true)
  case "$k" in ''|*[!0-9]*) k=0 ;; esac
  echo "$k"
}

sub "postfix"
if command -v postconf >/dev/null 2>&1 || [ -d /var/spool/postfix ]; then
  pf_act=unknown pf_en=unknown
  if [ "$HAVE_SD" = yes ]; then
    pf_act=$(q systemctl is-active postfix); pf_en=$(q systemctl is-enabled postfix)
  fi
  echo "postfix active=${pf_act:-?} enabled=${pf_en:-?}"
  if [ "$pf_act" = active ] || [ "${pf_en#enabled}" != "$pf_en" ]; then
    echo "WARN: postfix is running/enabled; a Docker VM rarely needs a local MTA"
  else
    echo "ok: postfix not running"
  fi
  # Queue count from the postqueue summary line; spool file count as fallback.
  pq=""
  if command -v postqueue >/dev/null 2>&1; then
    pq=$({ timeout 60 ${SUDO[@]+"${SUDO[@]}"} postqueue -p 2>/dev/null | awk '
        /^Mail queue is empty/{n=0}
        /^-- .* in [0-9]+ Requests?\.$/{n=$(NF-1)}
        END{if (n != "") print n}'; } || true)
  fi
  if [ -z "$pq" ]; then
    pq=$({ timeout 60 ${SUDO[@]+"${SUDO[@]}"} find /var/spool/postfix/incoming /var/spool/postfix/active \
        /var/spool/postfix/deferred /var/spool/postfix/hold /var/spool/postfix/maildrop \
        -type f 2>/dev/null | wc -l; } || true)
    pq="${pq:-?} (spool file count)"
  fi
  echo "mail queue: $pq"
  case "${pq%% *}" in
    ''|*[!0-9]*) ;;
    *) if [ "${pq%% *}" -ge 100 ]; then echo "WARN: mail queue has ${pq%% *} messages"; else echo "ok: mail queue small"; fi ;;
  esac
  mkb=$(kbof /var/mail/* /var/spool/postfix)
  dush /var/spool/postfix
  { st 30 du -xsh /var/mail/* 2>/dev/null | sort -rh | head -5; } || true
  if [ "$mkb" -ge 102400 ]; then
    echo "WARN: mail spool + mailboxes use $(numfmt --to=iec $((mkb * 1024)))"
  else
    echo "ok: mail spool + mailboxes $(numfmt --to=iec $((mkb * 1024)))"
  fi
else
  echo "ok: postfix not installed"
fi

sub "hostname vs mail name (cloned template?)"
hn=$(q hostname)
mh=""; mn=""
command -v postconf >/dev/null 2>&1 && mh=$(q postconf -h myhostname)
[ -r /etc/mailname ] && mn=$(q head -1 /etc/mailname)
echo "hostname=${hn:-?} myhostname=${mh:--} mailname=${mn:--}"
hmis=0
for n in "$mh" "$mn"; do
  [ -n "$n" ] || continue
  if [ "${n%%.*}" != "${hn%%.*}" ]; then
    echo "WARN: '$n' does not match hostname '${hn}' (cloned template?)"
    hmis=1
  fi
done
[ "$hmis" -eq 0 ] && echo "ok: names match or no mail config"

sub "crash-looping services (NRestarts >= 100, top 10)"
if [ "$HAVE_SD" = yes ]; then
  mapfile -t UNITS < <({ timeout 20 systemctl list-units --type=service --all --plain --no-legend 2>/dev/null \
      | awk '{for (i=1;i<=NF;i++) if ($i ~ /\.service$/) {print $i; break}}'; } || true)
  LOOPS=""
  if [ "${#UNITS[@]}" -gt 0 ]; then
    LOOPS=$({ timeout 60 systemctl show -p Id -p NRestarts -- "${UNITS[@]}" 2>/dev/null | awk -F= '
        /^Id=/{id=$2} /^NRestarts=/{if ($2+0 >= 100) print $2"\t"id}' | sort -rn; } || true)
  fi
  if [ -n "$LOOPS" ]; then
    printf '%s\n' "$LOOPS" | head -10 | while IFS=$'\t' read -r n u; do
      echo "WARN: $u restarted $n times"
    done
  else
    echo "ok: no service with NRestarts >= 100 (${#UNITS[@]} checked)"
  fi
  sg=serial-getty@ttyS0.service
  sg_act=$(q systemctl is-active "$sg"); sg_en=$(q systemctl is-enabled "$sg")
  sg_n=$(q systemctl show -p NRestarts --value "$sg")
  # No real UART: device missing or port type 0 (PORT_UNKNOWN).
  utype=$(q cat /sys/class/tty/ttyS0/type)
  if [ ! -c /dev/ttyS0 ]; then sreal="no (/dev/ttyS0 absent)"
  elif [ "${utype:-0}" = 0 ]; then sreal="no (uart type ${utype:-unknown})"
  else sreal="yes (uart type $utype)"
  fi
  echo "$sg active=${sg_act:-?} enabled=${sg_en:-?} restarts=${sg_n:-?} real serial: $sreal"
  if { [ "$sg_act" = active ] || [ "$sg_act" = activating ] || [ "${sg_en#enabled}" != "$sg_en" ]; } \
     && { [ "${sreal%% *}" = no ] || [ "${sg_n:-0}" -ge 100 ] 2>/dev/null; }; then
    echo "WARN: $sg runs without a usable serial console"
    echo "      fix: sudo systemctl mask --now $sg"
  else
    echo "ok: serial getty not looping"
  fi
else
  echo "systemctl not available"
fi

sub "runaway logs (/var/log files over 500M, top 10)"
BIGLOGS=$({ timeout 60 ${SUDO[@]+"${SUDO[@]}"} find /var/log -xdev -type f -size +500M -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | head -10 | numfmt --to=iec --field=1 2>/dev/null; } || true)
if [ -n "$BIGLOGS" ]; then
  printf '%s\n' "$BIGLOGS" | while IFS= read -r l; do echo "WARN: $l"; done
else
  echo "ok: no /var/log file over 500M"
fi
# Largest of syslog / mail.log, then its top repeated lines with digits stripped.
LBIG="" LSZ=0
for f in /var/log/syslog /var/log/mail.log; do
  s=$({ timeout 10 ${SUDO[@]+"${SUDO[@]}"} stat -c %s "$f" 2>/dev/null; } || true)
  case "$s" in ''|*[!0-9]*) continue ;; esac
  if [ "$s" -gt "$LSZ" ]; then LSZ=$s; LBIG=$f; fi
done
if [ -n "$LBIG" ]; then
  sub "top 3 repeated patterns in last 2000 lines of $LBIG ($(numfmt --to=iec "$LSZ"))"
  PATS=$({ timeout 30 ${SUDO[@]+"${SUDO[@]}"} tail -n 2000 "$LBIG" 2>/dev/null \
      | sed -E 's/^[^ ]+ //; s/[0-9]+//g' | cut -c1-140 | sort | uniq -c | sort -rn | head -3; } || true)
  if [ -n "$PATS" ]; then
    printf '%s\n' "$PATS"
    top=$(printf '%s\n' "$PATS" | awk 'NR==1{print $1+0}')
    if [ "${top:-0}" -ge 400 ]; then echo "WARN: one message pattern is ${top}/2000 lines, likely a loop"
    else echo "ok: no dominant repeated message"; fi
  else
    echo "unreadable (no access)"
  fi
else
  echo "no readable /var/log/syslog or /var/log/mail.log"
fi

sub "swapfile (>2G and <5% used is reclaimable)"
SW=$({ timeout 10 swapon --show=NAME,TYPE,SIZE,USED --bytes --noheadings 2>/dev/null; } || true)
swarn=0
while read -r name type size used; do
  [ "${type:-}" = file ] || continue
  case "$size$used" in ''|*[!0-9]*) continue ;; esac
  if [ "$size" -gt 2147483648 ] && [ $((used * 20)) -lt "$size" ]; then
    echo "WARN: $name is $(numfmt --to=iec "$size") with $(numfmt --to=iec "$used") used; reclaimable"
    swarn=1
  fi
done < <(printf '%s\n' "$SW")
[ "$swarn" -eq 0 ] && echo "ok: no oversized idle swapfile"
true

sec "8. Container mounts (>=10M shown; size, type, source -> container:dest)"
if [ "${#DOCKER[@]}" -eq 0 ]; then
  echo "docker not reachable"
else
  declare -A MSIZE=()
  MLINES=()
  hidden=0
  # shellcheck disable=SC2016
  while IFS='|' read -r cname mtype src dest; do
    [ -n "${src:-}" ] || continue
    case "$src" in
      /etc/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*|/var/run|/var/run/*) hidden=$((hidden + 1)); continue ;;
    esac
    if [ -z "${MSIZE[$src]+x}" ]; then
      kb=$({ timeout 60 ${SUDO[@]+"${SUDO[@]}"} du -sk "$src" 2>/dev/null | awk 'NR==1{print $1}'; } || true)
      case "$kb" in ''|*[!0-9]*) kb="?" ;; esac
      MSIZE[$src]=$kb
    fi
    kb=${MSIZE[$src]}
    if [ "$kb" != "?" ] && [ "$kb" -lt 10240 ]; then
      hidden=$((hidden + 1)); continue
    fi
    if [ "$kb" = "?" ]; then h="?"; else h=$(numfmt --to=iec $((kb * 1024))); fi
    MLINES+=("$(printf '%s\t%s\t%s -> %s:%s' "$h" "$mtype" "$src" "${cname#/}" "$dest")")
  done < <(t 60 "${DOCKER[@]}" ps -q 2>/dev/null | while read -r cid; do
      t 20 "${DOCKER[@]}" inspect --format \
        '{{$n := .Name}}{{range .Mounts}}{{$n}}|{{.Type}}|{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$cid" 2>/dev/null
    done | sort -t'|' -k3,3 -k1,1)
  shown=${#MLINES[@]}
  if [ "$shown" -gt 15 ]; then hidden=$((hidden + shown - 15)); shown=15; fi
  if [ "${#MLINES[@]}" -gt 0 ]; then
    { printf '%s\n' "${MLINES[@]}" | sort -rh | head -15; } || true
  fi
  echo "shown: $shown, hidden (small, system paths or beyond top 15): $hidden"
fi

printf '\n=== done %s ===\n' "$(date -Is)"
