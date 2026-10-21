#!/bin/sh
# ca-refresh.sh - eMudhra intermediate CA distrust remediation (2026-10-20).
#
# Updates CA stores (apt/apk), Node, user-site certifi, uv and rustup, then
# pulls and recreates running containers that use the patched modem7 images
# and checks the CA package inside them.
#
# Run as your normal login user (not under sudo); it uses sudo where needed,
# or runs directly when you are root (e.g. Proxmox). Run it inside each
# VM/LXC: running it on a hypervisor does not reach the guests.
#
# Usage:
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/modem7/public_scripts/master/Bash/Server%20scripts/ca-refresh.sh)"
#
# Env:
#   DRY_RUN=1    print the commands only, change nothing
#   ONLY="..."   run just these sections: apt apk certifi uv rustup docker
#
# Exits 1 if any step failed; the summary lists what and why.

DRY_RUN=${DRY_RUN:-0}
ONLY=${ONLY:-}
IMAGES="modem7/dnscrypt-proxy modem7/borgmatic-docker modem7/crowdsec-troubleshooter"
MIN_ALPINE_CA=20261020
FAILED=""
NOTES=""
RECREATED=""
PULLED=""

say() { printf '%s\n' "$*"; }
hdr() { printf '\n== %s ==\n' "$*"; }
warn() {
  printf 'WARN: %s\n' "$*"
  NOTES="$NOTES
  - $*"
}
fail_note() {
  FAILED="$FAILED
  - $*"
}
want() {
  [ -z "$ONLY" ] && return 0
  case " $ONLY " in *" $1 "*) return 0 ;; esac
  return 1
}
run() {
  printf '+ %s\n' "$*"
  [ "$DRY_RUN" = 1 ] && return 0
  "$@"
  rc=$?
  [ "$rc" -eq 0 ] || fail_note "$* (exit $rc)"
  return "$rc"
}

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
  [ -n "${SUDO_USER:-}" ] && warn "running under sudo: certifi/uv/rustup steps apply to root, not $SUDO_USER"
elif command -v sudo >/dev/null 2>&1; then
  SUDO=sudo
else
  SUDO=none
fi
root() {
  case $SUDO in
    sudo) run sudo "$@" ;;
    none) warn "no root or sudo, skipped: $*"; return 1 ;;
    *) run "$@" ;;
  esac
}
# Like root() but a failure is only the caller's to report, not recorded in FAILED.
try_root() {
  printf '+ %s\n' "$*"
  [ "$DRY_RUN" = 1 ] && return 0
  case $SUDO in
    sudo) sudo "$@" ;;
    none) return 1 ;;
    *) "$@" ;;
  esac
}

# Oldest YYYYMMDD among ca-certificates / ca-certificates-bundle lines on stdin.
ca_date() {
  sed -n -e 's/^ca-certificates-bundle-\([0-9]\{8\}\)-r.*/\1/p' \
         -e 's/^ca-certificates-\([0-9]\{8\}\)-r.*/\1/p' | sort | head -n 1
}
report_ca() {
  d=$(printf '%s\n' "$2" | ca_date)
  if [ -z "$d" ]; then
    warn "$1: could not read ca-certificates version"
  elif [ "$d" -ge "$MIN_ALPINE_CA" ]; then
    say "OK   $1: $(printf '%s' "$2" | tr '\n' ' ')"
  else
    warn "$1: CA store still $d (< $MIN_ALPINE_CA)"
    fail_note "$1 CA store $d < $MIN_ALPINE_CA"
  fi
}

# ---------- apt (Debian / Ubuntu / Proxmox) ----------
if want apt && command -v apt-get >/dev/null 2>&1; then
  hdr "apt"
  try_root apt-get update || warn "apt-get update reported errors (e.g. Proxmox enterprise repo 401); continuing"
  pkgs="ca-certificates"
  dpkg-query -W -f='${Status}' nodejs 2>/dev/null | grep -q 'install ok installed' && pkgs="$pkgs nodejs"
  # shellcheck disable=SC2086
  root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install --only-upgrade -y $pkgs
  for p in $pkgs; do
    say "$p: $(apt-cache policy "$p" 2>/dev/null | sed -n '2,3p' | tr -s ' ' | tr '\n' ' ')"
  done
  if zcat /usr/share/doc/ca-certificates/changelog.Debian.gz 2>/dev/null | grep -qi emudhra; then
    say "hint: ca-certificates changelog mentions eMudhra"
  else
    warn "hint: ca-certificates changelog has no eMudhra entry yet; the distro fix may not have shipped, recheck later"
  fi
fi

# ---------- apk (Alpine) ----------
if want apk && command -v apk >/dev/null 2>&1; then
  hdr "apk"
  root apk update
  pkgs=""
  for p in ca-certificates ca-certificates-bundle nodejs; do
    apk info -e "$p" >/dev/null 2>&1 && pkgs="$pkgs $p"
  done
  # shellcheck disable=SC2086
  [ -n "$pkgs" ] && root apk add --upgrade $pkgs
  d=$(apk info -v 2>/dev/null | ca_date)
  if [ -n "$d" ] && [ "$d" -lt "$MIN_ALPINE_CA" ]; then
    warn "Alpine CA store is $d (< $MIN_ALPINE_CA); this Alpine branch may be EOL or not yet patched"
  fi
fi

# ---------- certifi in user site-packages ----------
if want certifi; then
  hdr "certifi (user site-packages)"
  found=0
  for d in "$HOME"/.local/lib/python3*/site-packages/certifi; do
    [ -d "$d" ] || continue
    found=1
    pyv=${d#"$HOME"/.local/lib/}
    pyv=${pyv%%/*}
    py=$(command -v "$pyv" 2>/dev/null) || { warn "$pyv not found for $d"; continue; }
    if "$py" -m pip --version >/dev/null 2>&1; then :; else
      warn "no pip for $py, skipped $d"
      continue
    fi
    stdlib=$("$py" -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])' 2>/dev/null)
    if [ -n "$stdlib" ] && [ -f "$stdlib/EXTERNALLY-MANAGED" ]; then
      run "$py" -m pip install --user --upgrade --break-system-packages certifi
    else
      run "$py" -m pip install --user --upgrade certifi
    fi
  done
  [ "$found" -eq 0 ] && say "no user-site certifi found"
fi

# ---------- uv ----------
if want uv && command -v uv >/dev/null 2>&1; then
  hdr "uv"
  uvp=$(command -v uv)
  say "+ uv self update"
  if [ "$DRY_RUN" = 1 ] || uv self update; then
    :
  elif [ "$uvp" = "$HOME/.local/bin/uv" ] && command -v curl >/dev/null 2>&1; then
    run sh -c 'curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh'
  else
    warn "uv self update failed and $uvp is not a standalone install; update it with its package manager"
  fi
  run uv tool upgrade --all
fi

# ---------- rustup ----------
if want rustup && command -v rustup >/dev/null 2>&1; then
  hdr "rustup"
  run rustup self update
  run rustup update
fi

# ---------- Docker containers ----------
if want docker && command -v docker >/dev/null 2>&1; then
  hdr "docker"
  DK=""
  if docker info >/dev/null 2>&1; then
    DK=docker
  elif [ "$SUDO" = sudo ] && sudo docker info >/dev/null 2>&1; then
    DK=sudo
  fi
  dk() { if [ "$DK" = sudo ]; then sudo docker "$@"; else docker "$@"; fi; }
  DC=""
  if [ -n "$DK" ]; then
    if dk compose version >/dev/null 2>&1; then
      DC=plugin
    elif command -v docker-compose >/dev/null 2>&1; then
      DC=v1
    fi
  fi
  dc() {
    if [ "$DC" = plugin ]; then dk compose "$@"
    elif [ "$DK" = sudo ]; then sudo docker-compose "$@"
    else docker-compose "$@"; fi
  }
  # Strip digest, tag, registry host and library/ so refs compare equal.
  norm_image() {
    i=${1%%@*}
    case ${i##*/} in *:*) i=${i%:*} ;; esac
    case $i in
      */*) case ${i%%/*} in *.*|*:*|localhost) i=${i#*/} ;; esac ;;
    esac
    printf '%s' "${i#library/}"
  }

  if [ -z "$DK" ]; then
    warn "docker installed but not reachable (daemon down or no permission); skipped"
  else
    tmp=$(mktemp)
    ids=$(dk ps -q)
    if [ -n "$ids" ]; then
      # shellcheck disable=SC2086
      dk inspect -f '{{.Name}}|{{.Config.Image}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{index .Config.Labels "com.docker.compose.project.environment_file"}}|{{index .Config.Labels "com.docker.compose.service"}}' $ids > "$tmp"
    fi
    seen=" "
    matched=0
    while IFS='|' read -r cname image proj wd cfgs envf svc <&3; do
      cname=${cname#/}
      n=$(norm_image "$image")
      case " $IMAGES " in *" $n "*) ;; *) continue ;; esac
      matched=1
      if [ -n "$proj" ] && [ -n "$svc" ] && [ -n "$DC" ]; then
        key="$proj/$svc"
        case $seen in *" $key "*) continue ;; esac
        seen="$seen$key "
        cfg1=${cfgs%%,*}
        if [ -n "$cfg1" ] && [ -f "$cfg1" ]; then :; else
          warn "$cname ($key): compose file '$cfg1' not found here (Portainer stack?); update it from its manager"
          continue
        fi
        set -f
        oldifs=$IFS
        IFS=,
        set -- -p "$proj"
        [ -n "$wd" ] && set -- "$@" --project-directory "$wd"
        for c in $cfgs; do set -- "$@" -f "$c"; done
        for e in $envf; do
          if [ -f "$e" ]; then set -- "$@" --env-file "$e"; else warn "$key: env file $e missing, ignored"; fi
        done
        IFS=$oldifs
        set +f
        say "-- $cname: compose service $key ($image)"
        if run dc "$@" pull "$svc" && run dc "$@" up -d --no-deps "$svc"; then
          RECREATED="$RECREATED $cname"
        fi
      else
        key="img:$image"
        case $seen in *" $key "*) continue ;; esac
        seen="$seen$key "
        say "-- $cname: not a compose service ($image)"
        run dk pull "$image" && PULLED="$PULLED $image"
        warn "$cname is not managed by compose here; pulled $image, recreate the container yourself"
      fi
    done 3<"$tmp"
    rm -f "$tmp"
    [ "$matched" -eq 0 ] && say "no running containers use: $IMAGES"

    if [ "$DRY_RUN" = 1 ]; then :; else
      for c in $RECREATED; do
        report_ca "container $c" "$(dk exec "$c" sh -c 'apk info -v 2>/dev/null | grep "^ca-cert"' 2>/dev/null)"
      done
      for im in $PULLED; do
        report_ca "image $im" "$(dk run --rm --entrypoint sh "$im" -c 'apk info -v 2>/dev/null | grep "^ca-cert"' 2>/dev/null)"
      done
    fi
  fi
fi

# ---------- summary ----------
hdr "summary: $(uname -n)"
command -v dpkg-query >/dev/null 2>&1 && say "ca-certificates (apt): $(dpkg-query -W -f='${Version}' ca-certificates 2>/dev/null)"
command -v apk >/dev/null 2>&1 && say "ca-certificates (apk): $(apk info -v 2>/dev/null | grep '^ca-certificates' | tr '\n' ' ')"
if command -v node >/dev/null 2>&1; then
  nv=$(node -v 2>/dev/null)
  nv=${nv#v}
  say "node: $nv"
  case $nv in
    22.*)
      mi=${nv#22.}
      pa=${mi#*.}
      mi=${mi%%.*}
      if [ "$mi" -lt 23 ] || { [ "$mi" -eq 23 ] && [ "${pa:-0}" -lt 4 ]; }; then
        warn "node $nv is older than 22.23.4"
      fi
      ;;
  esac
fi
for d in "$HOME"/.local/lib/python3*/site-packages/certifi-*.dist-info; do
  [ -d "$d" ] && say "certifi: ${d##*/}"
done
command -v uv >/dev/null 2>&1 && say "$(uv --version 2>/dev/null)"
command -v rustc >/dev/null 2>&1 && say "$(rustc --version 2>/dev/null)"
[ -f /var/run/reboot-required ] && say "reboot required (/var/run/reboot-required)"
[ -n "$NOTES" ] && say "warnings:$NOTES"
say "Restart long-running services that make outbound TLS calls so they reload the CA store."
if [ -n "$FAILED" ]; then
  say "FAILED:$FAILED"
  exit 1
fi
if [ "$DRY_RUN" = 1 ]; then
  say "DRY RUN - nothing changed (unset DRY_RUN for a real run)"
else
  say "all steps OK"
fi
