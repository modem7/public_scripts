#!/usr/bin/env bash
# =============================================================================
# zfs-tune.sh
# Apply safe ZFS performance tuning to an existing Proxmox host.
# Aimed at SSD / NVMe pools in single-disk, stripe (RAID 0) or mirror (RAID 1)
# layouts. HDD / raidz pools are detected and only get the generic settings.
#
# Repo:   https://github.com/modem7/public_scripts
# Guide:  https://www.modem7.com/books/proxmox/page/proxmox-zfs-performance-tuning
#
# Usage:
#   bash zfs-tune.sh               # show plan, confirm, then apply
#   bash zfs-tune.sh --dry-run     # preview only, no changes made
#   bash zfs-tune.sh --help        # all options
#
# Safety:
#   - Shows the full plan and asks for confirmation before changing anything
#     (use --yes for unattended runs; without a terminal it refuses to apply)
#   - Only touches pools that are ONLINE and writable; --pool / --exclude-pool
#     limit it further
#   - Detects the boot pool (whatever it is called) and leaves its features
#     and dnodesize alone unless the host boots via proxmox-boot-tool
#   - zpool upgrade is opt-in (--upgrade-pools) as it cannot be undone
#   - Never sets sync=disabled, never touches ashift/topology/volblocksize
#   - Every change is written to /root/zfs-tune-rollback-<timestamp>.sh
#
# What this script does:
#   - autotrim=on for NVMe pools (SATA SSDs opt-in, see --autotrim-sata)
#   - atime=off where it is on
#   - compression where it is off or generic 'on':
#     lz4 on NVMe pools, zstd on SATA SSD / HDD pools
#     (intentional lz4/zstd left alone)
#   - dnodesize=auto
#   - ARC min/max: keeps a valid existing config, fixes invalid ones
#     (min >= max, duplicate lines), applies live via sysfs
#   - zfs_txg_timeout back to the default of 5s (1s causes more, smaller
#     transaction groups = extra write amplification and SSD wear)
#   - Consolidates zfs options in /etc/modprobe.d and runs update-initramfs
#   - Reports (does not change): ashift, NVMe LBA format, zvol volblocksize,
#     VM disk cache modes, swap-on-zvol, pool capacity, drive wear
# =============================================================================

set -uo pipefail

DRY_RUN=0
ASSUME_YES=0
UPGRADE_POOLS=0
AUTOTRIM_SATA=0
ARC_MAX_GB_OPT=""
ARC_MIN_GB_OPT=""
TXG_TARGET=5
INCLUDE_POOLS=()
EXCLUDE_POOLS=()

usage() {
  cat <<'EOF'
Usage: zfs-tune.sh [options]

  --dry-run            Preview only, no changes made
  -y, --yes            Apply without asking (for unattended runs)
  --pool NAME          Only tune this pool (repeatable)
  --exclude-pool NAME  Never touch this pool (repeatable)
  --upgrade-pools      Also run 'zpool upgrade' where features are pending.
                       One-way: older ZFS versions can no longer import the pool
  --autotrim-sata      Also enable autotrim on SATA SSD pools (default: NVMe
                       only; SATA pools rely on the monthly zfsutils trim cron)
  --arc-max-gb N       Force zfs_arc_max (default: keep a valid existing value,
                       otherwise 25% of RAM)
  --arc-min-gb N       Force zfs_arc_min (default: keep a valid existing value,
                       otherwise arc_max/8, minimum 1GB)
  --txg N              zfs_txg_timeout in seconds (default: 5, the ZFS default)
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=1 ;;
    -y|--yes)        ASSUME_YES=1 ;;
    --pool)          INCLUDE_POOLS+=("${2:?--pool needs a value}"); shift ;;
    --exclude-pool)  EXCLUDE_POOLS+=("${2:?--exclude-pool needs a value}"); shift ;;
    --upgrade-pools) UPGRADE_POOLS=1 ;;
    --autotrim-sata) AUTOTRIM_SATA=1 ;;
    --arc-max-gb)    ARC_MAX_GB_OPT="${2:?--arc-max-gb needs a value}"; shift ;;
    --arc-min-gb)    ARC_MIN_GB_OPT="${2:?--arc-min-gb needs a value}"; shift ;;
    --txg)           TXG_TARGET="${2:?--txg needs a value}"; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[$([[ $DRY_RUN -eq 1 ]] && echo 'WOULD  ' || echo 'APPLIED')]${NC}  $*"; }
skip() { echo -e "${YELLOW}[SKIPPED]${NC}  $*"; }
info() { echo -e "           ${CYAN}$*${NC}"; }
warn() { echo -e "${RED}[WARNING]${NC}  $*"; }
note() { echo -e "${CYAN}[INFO]${NC}     $*"; }
die()  { warn "$*"; exit 1; }
run()  {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC}  $*"
  else
    "$@" || { warn "Command failed: $*"; FAILURES=$((FAILURES + 1)); return 1; }
  fi
}
# write_sysfs <value> <file>
write_sysfs() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC}  echo $1 > $2"
  else
    echo "$1" > "$2" || { warn "Failed to write $2"; FAILURES=$((FAILURES + 1)); return 1; }
  fi
}

FAILURES=0
STAMP=$(date +%Y%m%d%H%M%S)
ROLLBACK=/root/zfs-tune-rollback-${STAMP}.sh
# record <revert command> — appended to the rollback script (real runs only)
record() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  if [[ ! -f "$ROLLBACK" ]]; then
    printf '#!/usr/bin/env bash\n# Reverts changes made by zfs-tune.sh on %s at %s\nset -x\n' \
      "$(hostname)" "$(date)" > "$ROLLBACK"
    chmod 700 "$ROLLBACK"
  fi
  echo "$*" >> "$ROLLBACK"
}

GiB=$((1024 * 1024 * 1024))
to_gb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'; }
in_list() { local x="$1"; shift; local i; for i in "$@"; do [[ "$i" == "$x" ]] && return 0; done; return 1; }

echo "========================================"
echo " ZFS Tune — $(hostname)"
[[ $DRY_RUN -eq 1 ]] && echo " Mode: DRY RUN (no changes will be made)"
echo "========================================"
echo

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Must be run as root. Exiting."

for n in "$TXG_TARGET" ${ARC_MAX_GB_OPT:+"$ARC_MAX_GB_OPT"} ${ARC_MIN_GB_OPT:+"$ARC_MIN_GB_OPT"}; do
  [[ "$n" =~ ^[0-9]+$ ]] || die "Numeric option expected, got '$n'. Exiting."
done
[[ "$TXG_TARGET" -ge 1 && "$TXG_TARGET" -le 30 ]] || die "--txg must be between 1 and 30. Exiting."

for cmd in zpool zfs awk lsblk findmnt grep sed; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' not found. Exiting."
done
[[ -d /sys/module/zfs/parameters ]] || die "ZFS kernel module not loaded. Exiting."
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container -q; then
  die "Running inside a container — run this on the Proxmox host itself. Exiting."
fi
if ! command -v pveversion >/dev/null 2>&1; then
  warn "This does not look like a Proxmox VE host. Proxmox-specific checks will be skipped."
fi

# Prevent two copies running at once
exec 9>/run/zfs-tune.lock
command -v flock >/dev/null 2>&1 && { flock -n 9 || die "Another zfs-tune.sh is already running. Exiting."; }

# ── Pool selection ────────────────────────────────────────────────────────────
mapfile -t ALL_POOLS < <(zpool list -H -o name 2>/dev/null)
[[ ${#ALL_POOLS[@]} -gt 0 ]] || die "No ZFS pools found. Exiting."

for p in "${INCLUDE_POOLS[@]}" "${EXCLUDE_POOLS[@]}"; do
  in_list "$p" "${ALL_POOLS[@]}" || die "Pool '$p' does not exist. Exiting."
done

echo "--- Pools ---"
POOLS=()
for pool in "${ALL_POOLS[@]}"; do
  HEALTH=$(zpool list -H -o health "$pool")
  RO=$(zpool get -H -o value readonly "$pool" 2>/dev/null)
  if [[ ${#INCLUDE_POOLS[@]} -gt 0 ]] && ! in_list "$pool" "${INCLUDE_POOLS[@]}"; then
    skip "$pool — not selected with --pool"
  elif in_list "$pool" "${EXCLUDE_POOLS[@]}"; then
    skip "$pool — excluded with --exclude-pool"
  elif [[ "$HEALTH" != "ONLINE" ]]; then
    warn "$pool — health is $HEALTH, not touching it. Fix the pool first."
  elif [[ "$RO" == "on" ]]; then
    skip "$pool — imported read-only"
  else
    POOLS+=("$pool")
  fi
done
[[ ${#POOLS[@]} -gt 0 ]] || die "No pools eligible for tuning. Exiting."

# ── Host detection ────────────────────────────────────────────────────────────
echo
echo "--- Host ---"
TOTAL_RAM_BYTES=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) * 1024 ))
[[ -d /sys/firmware/efi ]] && BOOT_FW="UEFI" || BOOT_FW="legacy BIOS"
ROOT_FS=$(findmnt -no FSTYPE / 2>/dev/null)

# Boot pools: the pool holding / plus any pool with bootfs set.
BOOT_POOLS=()
if [[ "$ROOT_FS" == "zfs" ]]; then
  ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null)
  BOOT_POOLS+=("${ROOT_SRC%%/*}")
fi
for pool in "${ALL_POOLS[@]}"; do
  BFS=$(zpool get -H -o value bootfs "$pool" 2>/dev/null)
  [[ -n "$BFS" && "$BFS" != "-" ]] && ! in_list "$pool" "${BOOT_POOLS[@]}" && BOOT_POOLS+=("$pool")
done

# A boot pool is only safe to upgrade / change dnodesize when the bootloader
# does not read it directly. proxmox-boot-tool copies kernels to the ESP, so
# GRUB/systemd-boot never touch the pool.
# Output is captured first: piping into `grep -q` can SIGPIPE the tool, which
# pipefail would turn into a false negative.
PBT_MANAGED=0
if command -v proxmox-boot-tool >/dev/null 2>&1; then
  PBT_STATUS=$(proxmox-boot-tool status 2>&1)
  grep -q "is configured with" <<<"$PBT_STATUS" && PBT_MANAGED=1
fi
boot_locked() { [[ $PBT_MANAGED -eq 0 ]] && in_list "$1" "${BOOT_POOLS[@]}"; }

info "RAM:          $(to_gb "$TOTAL_RAM_BYTES")GB, $(nproc) CPU threads"
info "Boot:         ${BOOT_FW}, root fs ${ROOT_FS:-unknown}, proxmox-boot-tool $([[ $PBT_MANAGED -eq 1 ]] && echo managed || echo 'not in use')"
[[ ${#BOOT_POOLS[@]} -gt 0 ]] && info "Boot pool(s): ${BOOT_POOLS[*]}$([[ $PBT_MANAGED -eq 0 ]] && echo ' (protected: features/dnodesize left alone)')"

# media_of <device path> -> nvme | ssd | hdd
media_of() {
  local name parent
  name=$(basename "$(readlink -f "$1")")
  parent=$(lsblk -dno PKNAME "/dev/$name" 2>/dev/null | head -1)
  [[ -n "$parent" ]] && name="$parent"
  if [[ "$name" == nvme* ]]; then
    echo nvme
  elif [[ "$(cat "/sys/block/$name/queue/rotational" 2>/dev/null)" == "1" ]]; then
    echo hdd
  else
    echo ssd
  fi
}

declare -A POOL_MEDIA POOL_LAYOUT POOL_DEVS
for pool in "${POOLS[@]}"; do
  # Data vdevs only — log/cache/spare devices don't define the pool's media
  mapfile -t devs < <(zpool status -LP "$pool" 2>/dev/null | awk '
    /^[ \t]+(logs|cache|spares|special|dedup)[ \t]*$/ { aux = 1; next }
    $1 == "'"$pool"'" { aux = 0 }
    !aux && $1 ~ /^\/dev\// { print $1 }')
  has_nvme=0; has_ssd=0; has_hdd=0
  for d in "${devs[@]}"; do
    case "$(media_of "$d")" in
      nvme) has_nvme=1 ;;
      ssd)  has_ssd=1 ;;
      hdd)  has_hdd=1 ;;
    esac
  done
  if   [[ $has_hdd -eq 1 ]]; then POOL_MEDIA[$pool]=hdd
  elif [[ $has_ssd -eq 1 ]]; then POOL_MEDIA[$pool]=ssd
  elif [[ $has_nvme -eq 1 ]]; then POOL_MEDIA[$pool]=nvme
  else POOL_MEDIA[$pool]=unknown
  fi

  vdevs=$(zpool list -vH "$pool" 2>/dev/null | awk 'NR>1 {print $1}')
  if   grep -q '^raidz' <<<"$vdevs"; then POOL_LAYOUT[$pool]=raidz
  elif grep -q '^draid' <<<"$vdevs"; then POOL_LAYOUT[$pool]=draid
  elif grep -q '^mirror' <<<"$vdevs"; then POOL_LAYOUT[$pool]=mirror
  elif [[ ${#devs[@]} -eq 1 ]]; then POOL_LAYOUT[$pool]=single
  else POOL_LAYOUT[$pool]=stripe
  fi
  POOL_DEVS[$pool]="${devs[*]}"
  info "Pool $(printf '%-10s' "$pool") ${POOL_MEDIA[$pool]}, ${POOL_LAYOUT[$pool]}, ${#devs[@]} device(s)"
done
echo

# ── Tuning (run once as a plan, then for real) ───────────────────────────────
# zfs_set_prop <dataset> <prop> <value> — records how to undo it
zfs_set_prop() {
  local ds=$1 prop=$2 val=$3 old src
  read -r old src < <(zfs get -H -o value,source "$prop" "$ds")
  run zfs set "$prop=$val" "$ds" || return 1
  if [[ "$src" == "local" ]]; then
    record "zfs set $prop=$old $ds"
  else
    record "zfs inherit $prop $ds"
  fi
}

tune() {
  NEEDS_UPDATE=0

  # ── 1. zpool upgrade (opt-in) ─────────────────────────────────────────────
  # Only counts features `zpool upgrade` would actually enable; features marked
  # (*) in its listing must be enabled explicitly and are left alone. Pools with
  # a 'compatibility' property are limited to that feature set by ZFS itself.
  echo "--- Pool feature upgrades ---"
  local UPGRADE_LIST PENDING
  UPGRADE_LIST=$(zpool upgrade 2>/dev/null)
  for pool in "${POOLS[@]}"; do
    PENDING=$(awk -v p="$pool" '
      /^POOL +FEATURE/ { list = 1; next }
      !list { next }
      /^[^ \t-]/ { cur = $1; next }
      cur == p && NF && $1 !~ /\(\*\)$/ { n++ }
      END { print n + 0 }' <<<"$UPGRADE_LIST")
    if [[ "$PENDING" -eq 0 ]]; then
      skip "$pool — no auto-applied features pending"
    elif boot_locked "$pool"; then
      skip "$pool — $PENDING feature(s) pending, but this boot pool is read by the bootloader"
      info "Upgrading could make the system unbootable."
    elif [[ $UPGRADE_POOLS -eq 0 ]]; then
      skip "$pool — $PENDING feature(s) pending (re-run with --upgrade-pools to enable)"
      info "One-way change: older ZFS versions (other hosts, rescue media) can no longer import it."
    else
      if run zpool upgrade "$pool" >/dev/null; then
        record "# zpool upgrade $pool cannot be reverted"
        ok "$pool — enabled $PENDING pending feature(s)"
      fi
    fi
  done
  echo

  # ── 2. autotrim ───────────────────────────────────────────────────────────
  # NVMe handles inline TRIM well. Many consumer SATA SSDs (e.g. Crucial MX500)
  # stall on frequent TRIM, so those default to the zfsutils monthly trim cron.
  echo "--- autotrim ---"
  local MEDIA AUTOTRIM
  for pool in "${POOLS[@]}"; do
    MEDIA=${POOL_MEDIA[$pool]}
    AUTOTRIM=$(zpool get -H -o value autotrim "$pool")
    if [[ "$AUTOTRIM" == "on" ]]; then
      skip "$pool — autotrim already on"
    elif [[ "$MEDIA" == "nvme" || ( "$MEDIA" == "ssd" && $AUTOTRIM_SATA -eq 1 ) ]]; then
      if run zpool set autotrim=on "$pool"; then
        record "zpool set autotrim=$AUTOTRIM $pool"
        ok "$pool — autotrim set to on ($MEDIA)"
      fi
    elif [[ "$MEDIA" == "ssd" ]]; then
      skip "$pool — SATA SSD, leaving autotrim off (use --autotrim-sata to enable)"
      if [[ -f /etc/cron.d/zfsutils-linux ]] && grep -q 'zfs-linux/trim' /etc/cron.d/zfsutils-linux; then
        info "Monthly trim cron present in /etc/cron.d/zfsutils-linux"
      else
        warn "$pool — no scheduled trim found either. Run periodically: zpool trim $pool"
      fi
    else
      skip "$pool — $MEDIA pool, autotrim not applicable"
    fi
  done
  echo

  # ── 3. atime=off ──────────────────────────────────────────────────────────
  echo "--- atime ---"
  for pool in "${POOLS[@]}"; do
    if [[ "$(zfs get -H -o value atime "$pool")" == "on" ]]; then
      zfs_set_prop "$pool" atime off && \
        ok "$pool — atime set to off"
    else
      skip "$pool — atime already off"
    fi
  done
  echo

  # ── 4. compression ────────────────────────────────────────────────────────
  # lz4 keeps up with NVMe throughput on any CPU; zstd trades CPU for ratio,
  # which suits slower SATA SSDs / HDDs. Only new writes are affected.
  echo "--- compression ---"
  local WANT COMP
  for pool in "${POOLS[@]}"; do
    [[ "${POOL_MEDIA[$pool]}" == "nvme" ]] && WANT=lz4 || WANT=zstd
    COMP=$(zfs get -H -o value compression "$pool")
    if [[ "$COMP" == "off" || "$COMP" == "on" ]]; then
      zfs_set_prop "$pool" compression "$WANT" && \
        ok "$pool — compression set to $WANT (was: $COMP)"
    else
      skip "$pool — compression=$COMP (intentional, leaving as-is)"
    fi
    # Child datasets overriding the pool are reported, not changed
    while read -r ds val; do
      note "$ds — compression=$val set locally (overrides pool, left as-is)"
    done < <(zfs get -H -r -s local -o name,value compression "$pool" 2>/dev/null \
               | awk -v p="$pool" '$1 != p && ($2 == "off" || $2 == "on")')
  done
  echo

  # ── 5. dnodesize=auto ─────────────────────────────────────────────────────
  echo "--- dnodesize ---"
  local DNODE
  for pool in "${POOLS[@]}"; do
    DNODE=$(zfs get -H -o value dnodesize "$pool")
    if [[ "$DNODE" != "legacy" ]]; then
      skip "$pool — dnodesize already $DNODE"
    elif boot_locked "$pool"; then
      skip "$pool — boot pool read by the bootloader, non-legacy dnodesize can break boot"
    else
      zfs_set_prop "$pool" dnodesize auto && \
        ok "$pool — dnodesize set to auto"
    fi
  done
  echo

  # ── 6. Module parameters: ARC + txg_timeout ───────────────────────────────
  echo "--- ARC / txg_timeout ---"
  local CONF=/etc/modprobe.d/zfs.conf

  # Last value of a zfs module option across modprobe.d (what modprobe uses)
  conf_val()   { grep -hoP "^\s*options\s+zfs\s.*\b$1=\K\d+" /etc/modprobe.d/*.conf 2>/dev/null | tail -1; }
  conf_count() { grep -hoP "^\s*options\s+zfs\s.*\b$1=\d+" /etc/modprobe.d/*.conf 2>/dev/null | wc -l; }

  local EXISTING_MAX EXISTING_MIN EXISTING_TXG MAX_WHY MIN_WHY
  EXISTING_MAX=$(conf_val zfs_arc_max)
  EXISTING_MIN=$(conf_val zfs_arc_min)
  EXISTING_TXG=$(conf_val zfs_txg_timeout)

  if [[ -n "$ARC_MAX_GB_OPT" ]]; then
    ARC_MAX=$((ARC_MAX_GB_OPT * GiB)); MAX_WHY="from --arc-max-gb"
  elif [[ -n "$EXISTING_MAX" && "$EXISTING_MAX" -ge $GiB && "$EXISTING_MAX" -le $(( TOTAL_RAM_BYTES - 2 * GiB )) ]]; then
    ARC_MAX=$EXISTING_MAX; MAX_WHY="existing value kept"
  else
    ARC_MAX=$(( TOTAL_RAM_BYTES / 4 / GiB * GiB ))
    [[ $ARC_MAX -lt $GiB ]] && ARC_MAX=$GiB
    MAX_WHY="25% of RAM"
  fi

  # arc_min must stay below arc_max or ZFS silently ignores it
  if [[ -n "$ARC_MIN_GB_OPT" ]]; then
    ARC_MIN=$((ARC_MIN_GB_OPT * GiB)); MIN_WHY="from --arc-min-gb"
  elif [[ -n "$EXISTING_MIN" && "$EXISTING_MIN" -gt 0 && "$EXISTING_MIN" -lt "$ARC_MAX" ]]; then
    ARC_MIN=$EXISTING_MIN; MIN_WHY="existing value kept"
  else
    ARC_MIN=$(( ARC_MAX / 8 ))
    [[ $ARC_MIN -lt $GiB ]] && ARC_MIN=$GiB
    [[ $ARC_MIN -ge $ARC_MAX ]] && ARC_MIN=$(( ARC_MAX / 2 ))
    MIN_WHY="arc_max/8"
    if [[ -n "$EXISTING_MIN" && "$EXISTING_MIN" -ge "$ARC_MAX" ]]; then
      warn "Existing zfs_arc_min ($(to_gb "$EXISTING_MIN")GB) >= zfs_arc_max — ZFS ignores it, fixing"
    fi
  fi

  [[ $ARC_MIN -lt $ARC_MAX ]] || die "arc_min ($(to_gb $ARC_MIN)GB) must be below arc_max ($(to_gb $ARC_MAX)GB). Exiting."
  [[ $ARC_MAX -le $(( TOTAL_RAM_BYTES - 2 * GiB )) ]] || die "arc_max leaves less than 2GB for the host. Exiting."

  info "ARC max:      $(to_gb $ARC_MAX)GB  ($MAX_WHY)"
  info "ARC min:      $(to_gb $ARC_MIN)GB  ($MIN_WHY)"
  info "txg_timeout:  ${TXG_TARGET}s  (currently ${EXISTING_TXG:-5 (default)})"

  # Guest memory committed on this node vs RAM left after a full ARC
  local GUEST_MB=0
  if [[ -d /etc/pve/qemu-server ]]; then
    GUEST_MB=$(awk '/^\[/ { nextfile } /^memory:/ { s += $2 } END { print s + 0 }' \
                 /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf 2>/dev/null)
    info "Guest memory: $(to_gb $((GUEST_MB * 1024 * 1024)))GB configured across VMs/CTs on this node"
    if [[ $(( GUEST_MB * 1024 * 1024 + ARC_MAX + 2 * GiB )) -gt $TOTAL_RAM_BYTES ]]; then
      warn "Guests + full ARC + 2GB host overhead exceed RAM. ARC shrinks under pressure,"
      info "but consider a lower --arc-max-gb if guests are OOM-killed or the host swaps."
    fi
  fi

  [[ "$EXISTING_MAX" != "$ARC_MAX" || "$EXISTING_MIN" != "$ARC_MIN" ]] && NEEDS_UPDATE=1
  [[ "${EXISTING_TXG:-5}" != "$TXG_TARGET" ]] && NEEDS_UPDATE=1
  for p in zfs_arc_max zfs_arc_min zfs_txg_timeout; do
    [[ $(conf_count $p) -gt 1 ]] && { NEEDS_UPDATE=1; note "$p defined more than once in /etc/modprobe.d — consolidating"; }
  done

  if [[ $NEEDS_UPDATE -eq 1 ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then
      # Back up every file touched, strip our parameters from zfs options lines
      # (keeping any other parameters on those lines), drop lines left empty.
      local f bak
      for f in /etc/modprobe.d/*.conf "$CONF"; do
        [[ -f "$f" ]] || continue
        [[ "$f" == "$CONF" ]] || grep -qP '^\s*options\s+zfs\s.*\b(zfs_arc_max|zfs_arc_min|zfs_txg_timeout)=' "$f" || continue
        bak="${f}.bak.${STAMP}"
        [[ -f "$bak" ]] && continue
        cp -p "$f" "$bak" && record "cp -p '$bak' '$f'"
        info "Backed up $f → $bak"
      done
      [[ -f "$CONF" ]] || record "rm -f '$CONF'"
      for f in /etc/modprobe.d/*.conf; do
        grep -qP '^\s*options\s+zfs\s.*\b(zfs_arc_max|zfs_arc_min|zfs_txg_timeout)=' "$f" || continue
        sed -i -E '/^\s*options\s+zfs\s/ { s/\s+(zfs_arc_max|zfs_arc_min|zfs_txg_timeout)=[0-9]+//g; /^\s*options\s+zfs\s*$/d }' "$f"
      done
      {
        echo "options zfs zfs_arc_min=${ARC_MIN}"
        echo "options zfs zfs_arc_max=${ARC_MAX}"
        # Default is 5; only write an override if something else was asked for
        [[ "$TXG_TARGET" != "5" ]] && echo "options zfs zfs_txg_timeout=${TXG_TARGET}"
      } >> "$CONF"
    fi
    ok "zfs.conf — arc_min=$(to_gb $ARC_MIN)GB  arc_max=$(to_gb $ARC_MAX)GB  txg_timeout=${TXG_TARGET}s"
  else
    skip "zfs.conf — already correct"
  fi
  echo

  # ── 7. Apply module parameters live ───────────────────────────────────────
  echo "--- Live apply (no reboot needed) ---"
  local PARAMS=/sys/module/zfs/parameters LIVE_MAX LIVE_MIN LIVE_TXG
  LIVE_MAX=$(cat $PARAMS/zfs_arc_max)
  LIVE_MIN=$(cat $PARAMS/zfs_arc_min)
  LIVE_TXG=$(cat $PARAMS/zfs_txg_timeout)

  set_arc_min() {
    if [[ "$LIVE_MIN" != "$ARC_MIN" ]]; then
      write_sysfs "$ARC_MIN" $PARAMS/zfs_arc_min && record "echo $LIVE_MIN > $PARAMS/zfs_arc_min"
      ok "zfs_arc_min → $(to_gb $ARC_MIN)GB (was: $(to_gb "$LIVE_MIN")GB)"
    else
      skip "zfs_arc_min already $(to_gb $ARC_MIN)GB"
    fi
  }
  set_arc_max() {
    if [[ "$LIVE_MAX" != "$ARC_MAX" ]]; then
      write_sysfs "$ARC_MAX" $PARAMS/zfs_arc_max && record "echo $LIVE_MAX > $PARAMS/zfs_arc_max"
      ok "zfs_arc_max → $(to_gb $ARC_MAX)GB (was: $(to_gb "$LIVE_MAX")GB)"
    else
      skip "zfs_arc_max already $(to_gb $ARC_MAX)GB"
    fi
  }
  # min may never exceed max at any point
  if [[ $ARC_MAX -lt $LIVE_MIN ]]; then set_arc_min; set_arc_max; else set_arc_max; set_arc_min; fi

  if [[ "$LIVE_TXG" != "$TXG_TARGET" ]]; then
    write_sysfs "$TXG_TARGET" $PARAMS/zfs_txg_timeout && record "echo $LIVE_TXG > $PARAMS/zfs_txg_timeout"
    ok "zfs_txg_timeout → ${TXG_TARGET}s (was: ${LIVE_TXG}s)"
  else
    skip "zfs_txg_timeout already ${TXG_TARGET}s"
  fi
  echo

  # ── 8. update-initramfs ───────────────────────────────────────────────────
  # The zfs module can load from the initramfs, which carries its own copy of
  # modprobe.d. On proxmox-boot-tool hosts the ESPs are re-synced by its hook.
  echo "--- initramfs ---"
  if [[ $NEEDS_UPDATE -eq 0 ]]; then
    skip "initramfs — no zfs.conf changes to persist"
  elif command -v update-initramfs >/dev/null 2>&1; then
    if run update-initramfs -u -k all; then
      record "update-initramfs -u -k all"
      ok "initramfs updated — settings persist across reboots"
    fi
  else
    warn "update-initramfs not found — regenerate your initramfs manually"
  fi
  echo
}

if [[ $DRY_RUN -eq 1 ]]; then
  tune
elif [[ $ASSUME_YES -eq 1 ]]; then
  tune
else
  # Show the plan first, then ask. Read from the terminal so this also works
  # when the script itself arrives on stdin (curl ... | bash).
  echo "=== Plan (nothing changed yet) ==="
  echo
  DRY_RUN=1; tune; DRY_RUN=0
  if [[ ! -r /dev/tty ]]; then
    die "No terminal to confirm on. Re-run with --yes to apply unattended. Exiting."
  fi
  read -r -p "Apply the changes above? [y/N] " REPLY </dev/tty
  [[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted, nothing changed."; exit 0; }
  echo
  echo "=== Applying ==="
  echo
  tune
fi

# ── Report (no changes) ───────────────────────────────────────────────────────
echo "--- Report (no changes made) ---"

# ashift
for pool in "${POOLS[@]}"; do
  ASHIFT=$(zpool get -H -o value ashift "$pool" 2>/dev/null)
  if [[ -z "$ASHIFT" || "$ASHIFT" == "0" ]]; then
    ASHIFT=$(zdb -C "$pool" 2>/dev/null | awk '/ashift:/ {print $2; exit}')
  fi
  if [[ -n "$ASHIFT" && "$ASHIFT" -lt 12 && "${POOL_MEDIA[$pool]}" != "hdd" ]]; then
    warn "$pool — ashift=$ASHIFT. SSDs want ashift=12 (4K); only fixable by recreating the pool"
  fi
done

# Pool capacity & redundancy
for pool in "${POOLS[@]}"; do
  CAP=$(zpool list -H -o capacity "$pool" | tr -d '%')
  [[ "$CAP" -ge 80 ]] && warn "$pool — ${CAP}% full. Pools slow down and fragment above ~80%"
  case "${POOL_LAYOUT[$pool]}" in
    single|stripe) note "$pool — ${POOL_LAYOUT[$pool]}, no redundancy. One drive failure loses the pool; keep backups current" ;;
  esac
done

# sync=disabled risks data loss on consumer drives without power-loss protection
for pool in "${POOLS[@]}"; do
  while read -r ds; do
    warn "$ds — sync=disabled. Recent writes are lost on power cut / crash"
  done < <(zfs get -H -r -s local -o name,value sync "$pool" 2>/dev/null | awk '$2 == "disabled" {print $1}')
done

# NVMe namespaces formatted 512B that support 4K
if command -v nvme >/dev/null 2>&1; then
  for ns in /dev/nvme*n[0-9]; do
    [[ -b "$ns" ]] || continue
    ID=$(nvme id-ns -H "$ns" 2>/dev/null) || continue
    if grep -q 'Data Size: 512 bytes.*in use' <<<"$ID" && grep -q 'Data Size: 4096 bytes' <<<"$ID"; then
      note "$ns — formatted with 512B LBAs but supports 4K. Harmless with ashift=12."
      info "Reformatting (nvme format --lbaf=N) DESTROYS all data — only when rebuilding the pool."
    fi
  done
fi

# Drive wear
if command -v smartctl >/dev/null 2>&1; then
  for pool in "${POOLS[@]}"; do
    for d in ${POOL_DEVS[$pool]}; do
      dev=$(basename "$d"); parent=$(lsblk -dno PKNAME "$d" 2>/dev/null | head -1)
      [[ -n "$parent" ]] && dev=$parent
      SMART=$(smartctl -A "/dev/$dev" 2>/dev/null)
      USED=$(awk -F: '/Percentage Used/ {gsub(/[ %]/, "", $2); print $2}' <<<"$SMART")
      [[ -z "$USED" ]] && USED=$(awk '/Percent_Lifetime_Remain/ {print 100 - $4}' <<<"$SMART")
      [[ "$USED" =~ ^[0-9]+$ && "$USED" -ge 80 ]] && warn "/dev/$dev ($pool) — ${USED}% of rated endurance used"
    done
  done
fi

# zvol volblocksize vs Proxmox storage blocksize
if [[ -f /etc/pve/storage.cfg ]]; then
  while read -r store pool bs; do
    in_list "${pool%%/*}" "${POOLS[@]}" || continue
    LARGE=$(zfs get -H -r -t volume -o value volblocksize "$pool" 2>/dev/null \
              | awk '{ v = $1; sub(/K$/, "", v); if (v + 0 > 16) n++ } END { print n + 0 }')
    LARGE_BS=0
    [[ "${bs,,}" =~ ^(32k|64k|128k|256k|512k|1m)$ ]] && LARGE_BS=1
    if [[ $LARGE_BS -eq 1 || "$LARGE" -gt 0 ]]; then
      note "storage '$store' — blocksize ${bs:-16k (default)}, $LARGE zvol(s) above 16K volblocksize"
      info "Every guest write smaller than the block rewrites the whole block (read-modify-write),"
      info "adding write amplification and SSD wear. 16k is the Proxmox/OpenZFS default for"
      info "general VM use; keep larger blocks for large sequential workloads only."
      if [[ $LARGE_BS -eq 1 ]]; then
        info "For new disks: pvesm set $store --blocksize 16k"
      fi
      if [[ "$LARGE" -gt 0 ]]; then
        info "Existing zvols keep their volblocksize until re-created: restore from backup,"
        info "or move the disk to another storage and back."
      fi
    fi
  done < <(awk '
    /^[a-z]+:/ { if (type == "zfspool" && pool != "") print store, pool, bs; split($0, a, /:[ \t]*/); type = a[1]; store = a[2]; pool = ""; bs = "" }
    /^[ \t]+pool /      { pool = $2 }
    /^[ \t]+blocksize / { bs = $2 }
    END { if (type == "zfspool" && pool != "") print store, pool, bs }' /etc/pve/storage.cfg)
fi

# VM disk cache modes (current config only, snapshot sections ignored)
for f in /etc/pve/qemu-server/*.conf; do
  [[ -f "$f" ]] || continue
  awk -v vm="$(basename "$f" .conf)" '
    /^\[/ { exit }
    /^(scsi|virtio|sata|ide)[0-9]+:/ && !/media=cdrom/ {
      disk = $1; sub(/:$/, "", disk)
      if (match($0, /cache=[a-z]+/)) {
        mode = substr($0, RSTART + 6, RLENGTH - 6)
        if (mode != "none") printf "VM %s %s — cache=%s (none is recommended on ZFS; ARC already caches)\n", vm, disk, mode
      }
      if ($0 !~ /discard=on/) printf "VM %s %s — discard not enabled, guest TRIM will not free pool space\n", vm, disk
    }' "$f" | while read -r line; do note "$line"; done
done

# Swap on a zvol can deadlock under memory pressure
while read -r swapdev; do
  if [[ "$(basename "$(readlink -f "$swapdev")")" == zd* ]]; then
    warn "Swap on zvol ($swapdev) — can deadlock under memory pressure."
    info "Prefer zram, or swap on a plain partition."
  fi
done < <(swapon --show=NAME --noheadings 2>/dev/null)
echo

# ── Summary ───────────────────────────────────────────────────────────────────
echo "========================================"
echo " Done — $(hostname)"
if [[ $DRY_RUN -eq 0 ]]; then
  [[ $FAILURES -gt 0 ]] && warn "$FAILURES command(s) failed — see above"
  [[ -f "$ROLLBACK" ]] && echo " Rollback script: $ROLLBACK"
fi
echo ""
echo " Requires manual action (not handled here):"
echo "   volblocksize  — Datacenter → Storage → Edit → Block Size (new disks only)"
echo "   VM disk cache — qm set <vmid> --scsi0 <disk>,cache=none,discard=on,ssd=1,iothread=1"
echo "   ashift / pool topology — set at pool creation only"
echo ""
echo " Monitor after tuning:"
echo "   arcstat 1 10          (target dh% above 90%)"
echo "   zpool iostat -vl 5    (per-device latency)"
echo "   smartctl -A /dev/nvme0 | grep -E 'Percentage Used|Data Units Written'"
echo "========================================"
[[ $FAILURES -eq 0 ]]
