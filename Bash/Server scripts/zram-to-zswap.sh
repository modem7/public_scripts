#!/usr/bin/env bash
# zram-to-zswap.sh — audit + migrate a host from zram-config to zswap, with backup/revert
# Usage:
#   ./zram-to-zswap.sh                    # dry run: shows the migration plan, changes nothing
#   ./zram-to-zswap.sh --apply            # migrate: back up current state, then apply
#   ./zram-to-zswap.sh --revert           # dry run: shows what a revert would do
#   ./zram-to-zswap.sh --revert --apply   # revert: restore the most recent backup
#
# Tunables (override via env):
#   ZSWAP_COMPRESSOR=zstd
#   ZSWAP_POOL_PERCENT=20   # % of RAM zswap's pool can use — already scales with RAM
#   SWAP_DIVISOR=4          # backing real swap size = totalmem / SWAP_DIVISOR
#   SWAP_FLOOR_MB=512       # ...clamped to at least this...
#   SWAP_CAP_MB=8192        # ...and at most this (the zswap pool absorbs the rest)
#   NEW_SWAP_SIZE=          # set explicitly (e.g. 2G) to bypass the auto calculation
#   BACKUP_ROOT=/var/backups/zram-to-zswap

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo ./zram-to-zswap.sh ...)." >&2
  exit 1
fi

MODE="migrate"
APPLY=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --revert) MODE="revert" ;;
  esac
done

BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/zram-to-zswap}"

ZSWAP_COMPRESSOR="${ZSWAP_COMPRESSOR:-zstd}"
ZSWAP_POOL_PERCENT="${ZSWAP_POOL_PERCENT:-20}"
SWAP_DIVISOR="${SWAP_DIVISOR:-4}"
SWAP_FLOOR_MB="${SWAP_FLOOR_MB:-512}"
SWAP_CAP_MB="${SWAP_CAP_MB:-8192}"

calc_swap_size_mb() {
  local totalmem_mb swap_mb
  totalmem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  swap_mb=$(( totalmem_mb / SWAP_DIVISOR ))
  if (( swap_mb < SWAP_FLOOR_MB )); then
    swap_mb=$SWAP_FLOOR_MB
  fi
  if (( swap_mb > SWAP_CAP_MB )); then
    swap_mb=$SWAP_CAP_MB
  fi
  echo "$swap_mb"
}

if [[ -z "${NEW_SWAP_SIZE:-}" ]]; then
  NEW_SWAP_SIZE="$(calc_swap_size_mb)M"
  AUTO_SIZED=true
else
  AUTO_SIZED=false
fi

hr() { echo; echo "== $* =="; }

# $0 is meaningless when this is run as `curl ... | sudo bash -s -- --apply`
# (no local file to point back to) — fall back to a re-fetch-and-run one-liner.
SCRIPT_URL="https://raw.githubusercontent.com/modem7/public_scripts/master/Bash/Server%20scripts/zram-to-zswap.sh"
revert_hint() {
  if [[ -f "$0" && "$0" != "bash" && "$0" != "-bash" && "$0" != "sh" ]]; then
    echo "sudo $0 --revert --apply"
  else
    echo "curl -s '$SCRIPT_URL' | sudo bash -s -- --revert --apply"
  fi
}

hr "Host identity"
hostnamectl

########################################################################
# Revert mode
########################################################################
if [[ "$MODE" == "revert" ]]; then
  TARGET="${BACKUP_ROOT}/latest"
  if [[ ! -e "$TARGET" ]]; then
    echo "No backup found at $TARGET — nothing to revert." >&2
    exit 1
  fi
  BACKUP_DIR=$(readlink -f "$TARGET")
  echo "Using backup: $BACKUP_DIR"

  if [[ ! -f "$BACKUP_DIR/manifest.env" ]]; then
    echo "manifest.env missing in $BACKUP_DIR — refusing to revert (backup incomplete, likely from an interrupted run)." >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  source "$BACKUP_DIR/manifest.env"

  hr "Revert plan"
  echo "Disable zswap at runtime"
  if [[ -f "$BACKUP_DIR/cmdline-path" ]]; then
    echo "Restore $(cat "$BACKUP_DIR/cmdline-path") from backup and refresh the bootloader"
  fi
  echo "Restore /etc/fstab from backup"
  if [[ -n "${SWAP_DEV:-}" ]]; then
    echo "swapoff $SWAP_DEV"
    if [[ "${SWAP_DEV_WAS_CREATED:-false}" == "true" ]]; then
      echo "NOTE: $SWAP_DEV was created by the migration — it will be left in place, not destroyed."
      echo "      Remove it manually afterwards if you don't want to keep it."
    fi
  fi
  if [[ "${PKG_ZRAM_CONFIG_WAS_INSTALLED:-false}" == "true" ]]; then
    echo "Reinstall zram-config, restore your original /usr/bin/init-zram-swapping, re-enable and start it"
  fi

  if ! $APPLY; then
    echo
    echo "Dry run complete — nothing was changed. Re-run with '--revert --apply' to make it real."
    exit 0
  fi

  hr "Reverting"

  if [[ -e /sys/module/zswap/parameters/enabled ]]; then
    echo 0 > /sys/module/zswap/parameters/enabled
  fi

  if [[ -f "$BACKUP_DIR/cmdline-path" ]]; then
    CMDLINE_FILE_RESTORE=$(cat "$BACKUP_DIR/cmdline-path")
    cp -a "$BACKUP_DIR/cmdline.bak" "$CMDLINE_FILE_RESTORE"
    if [[ "$CMDLINE_FILE_RESTORE" == "/etc/kernel/cmdline" ]]; then
      proxmox-boot-tool refresh
    else
      update-grub
    fi
  fi

  cp -a "$BACKUP_DIR/fstab.bak" /etc/fstab

  if [[ -n "${SWAP_DEV:-}" ]]; then
    swapoff "$SWAP_DEV" 2>/dev/null || true
  fi

  if [[ "${PKG_ZRAM_CONFIG_WAS_INSTALLED:-false}" == "true" ]]; then
    dpkg -s zram-config >/dev/null 2>&1 || apt install -y zram-config

    # apt's postinst may have already started the service with the stock
    # script before we get a chance to restore ours — tear that down first,
    # otherwise the already-active devices mean our script never re-runs.
    systemctl stop zram-config 2>/dev/null || true
    for zdev in /dev/zram*; do
      [[ -b "$zdev" ]] || continue
      swapon --show=NAME --noheadings | grep -qx "$zdev" && swapoff "$zdev"
      echo 1 > "/sys/block/$(basename "$zdev")/reset" 2>/dev/null || true
    done

    if [[ -f "$BACKUP_DIR/init-zram-swapping.bak" ]]; then
      cp -a "$BACKUP_DIR/init-zram-swapping.bak" /usr/bin/init-zram-swapping
      chmod +x /usr/bin/init-zram-swapping
    fi
    systemctl restart zram-config 2>/dev/null || /usr/bin/init-zram-swapping
  fi

  hr "Result"
  swapon --show
  free -h
  echo
  echo "Revert complete. Reboot to confirm the restored boot configuration persists."
  exit 0
fi

########################################################################
# Migrate mode
########################################################################

hr "Current swap / memory state"
swapon --show
free -h
zramctl 2>/dev/null || true

ROOT_FSTYPE=$(findmnt -no FSTYPE /)
echo "Root filesystem: $ROOT_FSTYPE"

if command -v proxmox-boot-tool >/dev/null 2>&1 && [[ -f /etc/kernel/cmdline ]]; then
  CMDLINE_FILE="/etc/kernel/cmdline"
  REFRESH_CMD="proxmox-boot-tool refresh"
elif [[ -f /etc/default/grub ]]; then
  CMDLINE_FILE="/etc/default/grub"
  REFRESH_CMD="update-grub"
else
  CMDLINE_FILE=""
fi

TOTALMEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if $AUTO_SIZED; then
  echo "Backing swap size: ${NEW_SWAP_SIZE} (auto: ${TOTALMEM_MB}MB / ${SWAP_DIVISOR}, floor ${SWAP_FLOOR_MB}MB, cap ${SWAP_CAP_MB}MB)"
else
  echo "Backing swap size: ${NEW_SWAP_SIZE} (explicit override)"
fi

ZRAM_DEVICES=$(swapon --show=NAME --noheadings | grep '^/dev/zram' || true)
REAL_SWAP=$(swapon --show=NAME --noheadings | grep -v '^/dev/zram' || true)

hr "Diagnosis"
if [[ -n "$ZRAM_DEVICES" && -n "$REAL_SWAP" ]]; then
  echo "zram AND real disk swap both active ($REAL_SWAP) — the combination"
  echo "the article warns against (LRU inversion)."
  echo "Plan: keep existing real swap, drop zram, enable zswap."
elif [[ -n "$ZRAM_DEVICES" && -z "$REAL_SWAP" ]]; then
  echo "Only zram active, no real backing swap."
  echo "Plan: provision ${NEW_SWAP_SIZE} real swap, drop zram, enable zswap."
elif [[ -z "$ZRAM_DEVICES" && -n "$REAL_SWAP" ]]; then
  echo "Real swap already active ($REAL_SWAP), no zram in use."
  echo "Plan: nothing to remove — just enable zswap in front of it."
else
  echo "No swap active at all."
  echo "Plan: provision ${NEW_SWAP_SIZE} real swap, then enable zswap."
fi

if [[ -n "$ZRAM_DEVICES" ]]; then
  ZRAM_DATA_KB=$(zramctl --noheadings --bytes -o DATA 2>/dev/null | awk '{s+=$1} END{print int(s/1024)}')
  AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
  if [[ -n "$ZRAM_DATA_KB" && "$ZRAM_DATA_KB" -gt "$AVAIL_KB" ]]; then
    echo "WARNING: zram holds more uncompressed data than available RAM."
    echo "  swapoff needs to decompress it all back into RAM — this may thrash."
  fi
fi

### Back up current state before touching anything ###
if $APPLY; then
  BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  hr "Backing up current state to $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  cp -a /etc/fstab "$BACKUP_DIR/fstab.bak"
  if [[ -n "$CMDLINE_FILE" ]]; then
    cp -a "$CMDLINE_FILE" "$BACKUP_DIR/cmdline.bak"
    echo "$CMDLINE_FILE" > "$BACKUP_DIR/cmdline-path"
  fi
  if [[ -e /usr/bin/init-zram-swapping ]]; then
    cp -a /usr/bin/init-zram-swapping "$BACKUP_DIR/init-zram-swapping.bak"
  fi
  PKG_ZRAM_CONFIG_WAS_INSTALLED=$(dpkg -s zram-config >/dev/null 2>&1 && echo true || echo false)
  ln -sfn "$BACKUP_DIR" "${BACKUP_ROOT}/latest"
  echo "Backup saved (symlinked as ${BACKUP_ROOT}/latest). Revert with:"
  echo "  $(revert_hint)"
else
  PKG_ZRAM_CONFIG_WAS_INSTALLED=""
fi

### Step 1: provision real swap if none exists ###
if [[ -z "$REAL_SWAP" ]]; then
  hr "Provisioning ${NEW_SWAP_SIZE} backing swap (root fs: $ROOT_FSTYPE)"

  if [[ "$ROOT_FSTYPE" == "zfs" ]]; then
    POOL=$(findmnt -no SOURCE / | cut -d/ -f1)
    SWAP_DEV="/dev/zvol/${POOL}/swap"
    echo "Detected ZFS pool: $POOL"
    if zfs list -H -o name "${POOL}/swap" >/dev/null 2>&1; then
      echo "zvol ${POOL}/swap already exists — reusing it, not recreating"
      DEVICE_EXISTS=true
    else
      DEVICE_EXISTS=false
    fi
    if $APPLY && ! $DEVICE_EXISTS; then
      zfs create -V "${NEW_SWAP_SIZE}" -b "$(getconf PAGESIZE)" \
        -o compression=off -o primarycache=metadata -o sync=always "${POOL}/swap"
      mkswap -f "$SWAP_DEV"
    fi

  elif command -v vgs >/dev/null 2>&1 && vgs --noheadings 2>/dev/null | grep -q .; then
    VG=$(vgs --noheadings -o vg_name | awk 'NR==1{print $1}')
    SWAP_DEV="/dev/${VG}/swap"
    echo "Detected LVM volume group: $VG"
    if lvs --noheadings "${VG}/swap" >/dev/null 2>&1; then
      echo "LV ${VG}/swap already exists — reusing it, not recreating"
      DEVICE_EXISTS=true
    else
      DEVICE_EXISTS=false
    fi
    if $APPLY && ! $DEVICE_EXISTS; then
      lvcreate -L "${NEW_SWAP_SIZE}" -n swap "${VG}"
      mkswap "$SWAP_DEV"
    fi

  else
    SWAP_DEV="/swapfile"
    echo "No ZFS root / LVM VG detected — falling back to a swapfile"
    if [[ -e "$SWAP_DEV" ]]; then
      echo "$SWAP_DEV already exists — reusing it, not recreating"
      DEVICE_EXISTS=true
    else
      DEVICE_EXISTS=false
    fi
    if $APPLY && ! $DEVICE_EXISTS; then
      fallocate -l "${NEW_SWAP_SIZE}" "$SWAP_DEV"
      chmod 600 "$SWAP_DEV"
      mkswap "$SWAP_DEV"
    fi
  fi

  if $APPLY; then
    grep -q "^${SWAP_DEV}" /etc/fstab || echo "${SWAP_DEV} none swap sw 0 0" >> /etc/fstab
    swapon "$SWAP_DEV"
  elif $DEVICE_EXISTS; then
    echo "  [dry-run] would reuse existing ${SWAP_DEV}, ensure fstab entry, swapon"
  else
    echo "  [dry-run] would provision ${NEW_SWAP_SIZE} at ${SWAP_DEV}, mkswap, add to fstab, swapon"
  fi
fi

### Step 2: remove zram-config ###
if [[ -n "$ZRAM_DEVICES" ]]; then
  hr "Removing zram-config"
  if $APPLY; then
    for dev in $ZRAM_DEVICES; do swapoff "$dev"; done
    systemctl disable --now zram-config 2>/dev/null || true
    # apt's package index may not have zram-config (not in every distro's
    # default repos, or the repo that provided it is no longer configured)
    # even though it's genuinely installed — dpkg only needs local state.
    if ! apt purge -y zram-config 2>/dev/null; then
      dpkg --purge zram-config 2>/dev/null || echo "  WARNING: could not purge the zram-config package (may already be gone, or installed outside apt) — continuing anyway."
    fi
    rm -f /usr/bin/init-zram-swapping
  else
    echo "  [dry-run] would swapoff $ZRAM_DEVICES, purge zram-config, remove init-zram-swapping"
  fi
fi

### Step 3: enable zswap now (runtime) ###
hr "Enabling zswap (runtime)"
if [[ -e /sys/module/zswap/parameters/enabled ]]; then
  if $APPLY; then
    # Pre-load zsmalloc explicitly: writing zpool=zsmalloc can otherwise make
    # the kernel request_module() it on demand, which kernel lockdown (common
    # with Secure Boot enabled) blocks via sysfs even for root.
    modprobe zsmalloc 2>/dev/null || true
    # Each write is grouped in braces so the 2>/dev/null takes effect before
    # the redirection into the sysfs file is attempted — bash prints its own
    # "Permission denied" diagnostic for a failed target-file open *before*
    # a same-line 2>/dev/null on the command would otherwise suppress it.
    RUNTIME_OK=true
    { echo "${ZSWAP_COMPRESSOR}" > /sys/module/zswap/parameters/compressor; } 2>/dev/null || RUNTIME_OK=false
    { echo zsmalloc > /sys/module/zswap/parameters/zpool; } 2>/dev/null || RUNTIME_OK=false
    { echo "${ZSWAP_POOL_PERCENT}" > /sys/module/zswap/parameters/max_pool_percent; } 2>/dev/null || RUNTIME_OK=false
    { echo 1 > /sys/module/zswap/parameters/enabled; } 2>/dev/null || RUNTIME_OK=false
    if ! $RUNTIME_OK; then
      echo "  WARNING: one or more zswap sysfs writes were denied (kernel lockdown /"
      echo "  Secure Boot commonly blocks dynamic module loading via sysfs, even as root)."
      echo "  Some settings may still have applied — actual live state is checked in the"
      echo "  Result section below. The kernel cmdline is set regardless, so a reboot"
      echo "  will apply the full configuration either way."
    fi
  else
    echo "  [dry-run] would set compressor=${ZSWAP_COMPRESSOR}, zpool=zsmalloc,"
    echo "  max_pool_percent=${ZSWAP_POOL_PERCENT}, enabled=1"
  fi
else
  echo "  /sys/module/zswap/parameters not found — needs the cmdline param + reboot first."
fi

### Step 4: persist across reboots via kernel cmdline ###
hr "Persisting zswap via kernel cmdline"
CMDLINE_PARAMS="zswap.enabled=1 zswap.compressor=${ZSWAP_COMPRESSOR} zswap.zpool=zsmalloc zswap.max_pool_percent=${ZSWAP_POOL_PERCENT}"

if [[ -z "$CMDLINE_FILE" ]]; then
  echo "  Could not detect proxmox-boot-tool or GRUB — set these manually:"
  echo "  $CMDLINE_PARAMS"
elif grep -q 'zswap.enabled' "$CMDLINE_FILE"; then
  echo "  $CMDLINE_FILE already has zswap params, leaving as-is"
elif $APPLY; then
  if [[ "$CMDLINE_FILE" == "/etc/kernel/cmdline" ]]; then
    sed -i "s/\$/ ${CMDLINE_PARAMS}/" "$CMDLINE_FILE"
  else
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${CMDLINE_PARAMS}\"/" "$CMDLINE_FILE"
  fi
  $REFRESH_CMD
else
  echo "  [dry-run] would append to $CMDLINE_FILE and run: $REFRESH_CMD"
  echo "    $CMDLINE_PARAMS"
fi

### Save manifest for revert ###
if $APPLY; then
  SWAP_DEV_WAS_CREATED=false
  [[ "${DEVICE_EXISTS:-true}" == "false" ]] && SWAP_DEV_WAS_CREATED=true
  {
    echo "ZRAM_DEVICES='${ZRAM_DEVICES}'"
    echo "SWAP_DEV='${SWAP_DEV:-}'"
    echo "SWAP_DEV_WAS_CREATED='${SWAP_DEV_WAS_CREATED}'"
    echo "PKG_ZRAM_CONFIG_WAS_INSTALLED='${PKG_ZRAM_CONFIG_WAS_INSTALLED}'"
  } > "$BACKUP_DIR/manifest.env"
fi

### Step 5: verify ###
hr "Result"
swapon --show
free -h
if [[ -e /sys/module/zswap/parameters/enabled ]]; then
  # Individual parameter files can go missing even when .../enabled exists —
  # seen in the wild where a denied zpool write left that one file gone by
  # the time we get here. Check each before reading rather than assuming.
  read_zswap_param() { [[ -e "/sys/module/zswap/parameters/$1" ]] && cat "/sys/module/zswap/parameters/$1" || echo "(not present)"; }
  ZSWAP_ENABLED_NOW=$(read_zswap_param enabled)
  ZSWAP_COMPRESSOR_NOW=$(read_zswap_param compressor)
  ZSWAP_ZPOOL_NOW=$(read_zswap_param zpool)
  ZSWAP_POOL_PERCENT_NOW=$(read_zswap_param max_pool_percent)
  echo "zswap enabled:          ${ZSWAP_ENABLED_NOW}"
  echo "zswap compressor:       ${ZSWAP_COMPRESSOR_NOW}"
  echo "zswap zpool:            ${ZSWAP_ZPOOL_NOW}"
  echo "zswap max_pool_percent: ${ZSWAP_POOL_PERCENT_NOW}"
fi

if $APPLY; then
  echo
  # Judge success from what's actually live now, not from whether every sysfs
  # write in Step 3 succeeded — enabled=1 can succeed even if zpool didn't.
  if [[ "${ZSWAP_ENABLED_NOW:-N}" == "Y" && "${ZSWAP_COMPRESSOR_NOW:-}" == "$ZSWAP_COMPRESSOR" \
        && "${ZSWAP_ZPOOL_NOW:-}" == "zsmalloc" && "${ZSWAP_POOL_PERCENT_NOW:-}" == "$ZSWAP_POOL_PERCENT" ]]; then
    echo "Done. zswap is fully live and configured as requested — no reboot required,"
    echo "though one is worth doing once to confirm the setting survives it."
  elif [[ "${ZSWAP_ENABLED_NOW:-N}" == "Y" ]]; then
    echo "Done, with a caveat: zswap is live but not fully configured as requested"
    echo "(compare the values above to compressor=${ZSWAP_COMPRESSOR}, zpool=zsmalloc,"
    echo "max_pool_percent=${ZSWAP_POOL_PERCENT} — see the WARNING above for which"
    echo "write(s) were denied). The kernel cmdline is set correctly, so a reboot"
    echo "will bring it up fully configured."
  else
    echo "Done, but zswap could not be enabled at runtime at all (see WARNING above)."
    echo "The kernel cmdline is set correctly, so it will come up after a reboot."
  fi
  echo "To undo everything this run did: $(revert_hint)"
else
  echo
  echo "Dry run complete — nothing was changed. Re-run with --apply to make it real."
fi
