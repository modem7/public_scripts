#!/usr/bin/env bash
# =============================================================================
# zfs-tune.sh
# Apply safe ZFS performance tuning to an existing Proxmox host.
#
# Repo:   https://github.com/modem7/public_scripts
# Guide:  https://www.modem7.com/books/proxmox/page/proxmox-zfs-performance-tuning
#
# Usage:
#   bash zfs-tune.sh            # apply changes
#   bash zfs-tune.sh --dry-run  # preview only, no changes made
#
# What this script does:
#   - zpool upgrade on all pools with available features
#   - atime=off on any pool where it isn't already set
#   - compression=zstd where compression is off or generic 'on'
#     (intentional lz4/zstd left alone)
#   - dnodesize=auto on data pools (skips rpool — GRUB incompatibility)
#   - Calculates and writes zfs_arc_max / zfs_arc_min based on host RAM
#   - Sets zfs_txg_timeout=1 (smooths write latency spikes)
#   - Applies txg_timeout immediately via sysfs (no reboot needed)
#   - Runs update-initramfs -u if zfs.conf was changed
#
# What this script does NOT do:
#   - Touch ashift, volblocksize, or pool topology (require recreation)
#   - Change VM disk cache settings (do per-VM via Proxmox UI or qm set)
#   - Add ZIL/SLOG or L2ARC devices
#   - Modify rpool compression or dnodesize
# =============================================================================

set -uo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[APPLIED]${NC}  $*"; }
skip() { echo -e "${YELLOW}[SKIPPED]${NC}  $*"; }
info() { echo -e "           ${CYAN}$*${NC}"; }
warn() { echo -e "${RED}[WARNING]${NC}  $*"; }
run()  {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC}  $*"
  else
    eval "$@"
  fi
}

echo "========================================"
echo " ZFS Quick Gains — $(hostname)"
[[ $DRY_RUN -eq 1 ]] && echo " Mode: DRY RUN (no changes will be made)"
echo "========================================"
echo

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  warn "Must be run as root. Exiting."
  exit 1
fi

# ── Get pool list ─────────────────────────────────────────────────────────────
POOLS=$(zpool list -H -o name 2>/dev/null)
if [[ -z "$POOLS" ]]; then
  warn "No ZFS pools found. Exiting."
  exit 1
fi

echo "Pools found: $(echo $POOLS | tr '\n' ' ')"
echo

# ── 1. zpool upgrade ──────────────────────────────────────────────────────────
echo "--- Pool feature upgrades ---"
for pool in $POOLS; do
  STATUS=$(zpool status "$pool" 2>/dev/null | grep -c "features are not enabled" || true)
  if [[ "$STATUS" -gt 0 ]]; then
    run "zpool upgrade $pool"
    ok "$pool — upgraded to latest feature set"
  else
    skip "$pool — already at latest feature set"
  fi
done
echo

# ── 2. atime=off ──────────────────────────────────────────────────────────────
echo "--- atime ---"
for pool in $POOLS; do
  ATIME=$(zfs get -H -o value atime "$pool")
  if [[ "$ATIME" == "on" ]]; then
    run "zfs set atime=off $pool"
    ok "$pool — atime set to off"
  else
    skip "$pool — atime already off (value: $ATIME)"
  fi
done
echo

# ── 3. compression ────────────────────────────────────────────────────────────
echo "--- compression ---"
for pool in $POOLS; do
  COMP=$(zfs get -H -o value compression "$pool")
  SOURCE=$(zfs get -H -o source compression "$pool")
  if [[ "$COMP" == "off" || "$COMP" == "on" ]] && [[ "$SOURCE" == "local" || "$SOURCE" == "default" ]]; then
    run "zfs set compression=zstd $pool"
    ok "$pool — compression set to zstd (was: $COMP)"
  elif [[ "$COMP" == "lz4" ]]; then
    skip "$pool — compression is lz4 (acceptable, leaving as-is)"
    info "To upgrade to zstd: zfs set compression=zstd $pool"
  elif [[ "$COMP" == "zstd"* ]]; then
    skip "$pool — compression already zstd"
  else
    skip "$pool — compression=$COMP source=$SOURCE (leaving as-is)"
  fi
done
echo

# ── 4. dnodesize=auto (skip rpool) ────────────────────────────────────────────
echo "--- dnodesize ---"
for pool in $POOLS; do
  DNODE=$(zfs get -H -o value dnodesize "$pool")
  if [[ "$pool" == "rpool" ]]; then
    skip "$pool — skipping rpool (GRUB incompatibility with non-legacy dnodesize)"
  elif [[ "$DNODE" == "legacy" ]]; then
    run "zfs set dnodesize=auto $pool"
    ok "$pool — dnodesize set to auto"
  else
    skip "$pool — dnodesize already $DNODE"
  fi
done
echo

# ── 5. ARC sizing ─────────────────────────────────────────────────────────────
echo "--- ARC sizing ---"
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))

if   [[ $TOTAL_RAM_GB -ge 256 ]]; then ARC_MAX_GB=64
elif [[ $TOTAL_RAM_GB -ge 128 ]]; then ARC_MAX_GB=32
elif [[ $TOTAL_RAM_GB -ge 64  ]]; then ARC_MAX_GB=16
elif [[ $TOTAL_RAM_GB -ge 32  ]]; then ARC_MAX_GB=6
else                                    ARC_MAX_GB=2
fi

ARC_MAX_BYTES=$((ARC_MAX_GB * 1024 * 1024 * 1024))
ARC_MIN_BYTES=$((ARC_MAX_BYTES / 4))
ARC_MIN_GB=$((ARC_MAX_GB / 4))

info "Detected RAM:  ${TOTAL_RAM_GB}GB"
info "ARC max:       ${ARC_MAX_GB}GB  (${ARC_MAX_BYTES} bytes)"
info "ARC min:       ${ARC_MIN_GB}GB  (${ARC_MIN_BYTES} bytes)"

CONF=/etc/modprobe.d/zfs.conf
NEEDS_UPDATE=0

EXISTING_MAX=$(grep -oP '(?<=zfs_arc_max=)\d+' "$CONF" 2>/dev/null || echo 0)
EXISTING_MIN=$(grep -oP '(?<=zfs_arc_min=)\d+' "$CONF" 2>/dev/null || echo 0)
EXISTING_TXG=$(grep -oP '(?<=zfs_txg_timeout=)\d+' "$CONF" 2>/dev/null || echo 5)

if [[ "$EXISTING_MAX" != "$ARC_MAX_BYTES" ]] || \
   [[ "$EXISTING_MIN" != "$ARC_MIN_BYTES" ]] || \
   [[ "$EXISTING_TXG" != "1" ]]; then
  NEEDS_UPDATE=1
fi

if [[ $NEEDS_UPDATE -eq 1 ]]; then
  if [[ $DRY_RUN -eq 0 ]]; then
    # Back up existing conf if it has content
    if [[ -s "$CONF" ]]; then
      cp "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"
      info "Backed up existing $CONF"
    fi
    sed -i '/zfs_arc_max\|zfs_arc_min\|zfs_txg_timeout/d' "$CONF" 2>/dev/null || true
    cat >> "$CONF" << ZFSCFG
options zfs zfs_arc_min=${ARC_MIN_BYTES}
options zfs zfs_arc_max=${ARC_MAX_BYTES}
options zfs zfs_txg_timeout=1
ZFSCFG
  fi
  ok "zfs.conf — arc_min=${ARC_MIN_GB}GB  arc_max=${ARC_MAX_GB}GB  txg_timeout=1"
  info "Written to: $CONF"
else
  skip "zfs.conf — arc_max, arc_min, txg_timeout already correctly set"
fi
echo

# ── 6. Apply txg_timeout immediately ──────────────────────────────────────────
echo "--- txg_timeout (live apply) ---"
LIVE_TXG=$(cat /sys/module/zfs/parameters/zfs_txg_timeout 2>/dev/null || echo "unknown")
if [[ "$LIVE_TXG" != "1" ]]; then
  run "echo 1 > /sys/module/zfs/parameters/zfs_txg_timeout"
  ok "zfs_txg_timeout → 1 (was: ${LIVE_TXG}s) — effective immediately"
else
  skip "zfs_txg_timeout already 1"
fi
echo

# ── 7. update-initramfs ───────────────────────────────────────────────────────
echo "--- initramfs ---"
if [[ $NEEDS_UPDATE -eq 1 ]]; then
  run "update-initramfs -u"
  ok "initramfs updated — settings will persist after reboot"
  warn "Reboot required for ARC min/max to fully take effect"
else
  skip "initramfs — no zfs.conf changes to persist"
fi
echo

# ── Summary ───────────────────────────────────────────────────────────────────
echo "========================================"
echo " Done — $(hostname)"
echo ""
echo " Requires manual action (not handled here):"
echo "   volblocksize  — Datacenter → Storage → Edit → Block Size"
echo "                   (must be set before creating VMs, cannot change existing)"
echo "   VM disk cache — set cache=none per VM in Proxmox UI or:"
echo "                   qm set <vmid> --scsi0 <disk>,cache=none,..."
echo "   ashift        — set at pool creation only"
echo "   Pool topology — set at pool creation only"
echo "   ZIL/SLOG      — zpool add \$POOL log \$DEVICE"
echo "   L2ARC         — zpool add \$POOL cache \$DEVICE"
echo "   IO scheduler  — /etc/udev/rules.d/60-zfs-scheduler.rules"
echo ""
echo " Monitor ARC hit rate after reboot:"
echo "   arcstat 1 10   (target dmh% above 85%)"
echo "========================================"