#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Proxmox Template Updater
# =============================================================================

readonly QM=/usr/sbin/qm

declare -a SOURCE_VMS=(9001 9002 9003)
declare -a CLONE_VMS=(6000 6001 6002)
declare -a CLONE_NAMES=(
    "ubuntu-desktop-cloud-master-template"
    "ubuntu2404-cloud-master-template"
    "ubuntu2404-cloud-master-extras-template"
)

AGENT_TIMEOUT=120   # seconds to wait for guest agent to become ready
EXEC_TIMEOUT=600    # seconds to wait for guest script to complete

# Python snippet to extract out-data from QGA JSON output.
# Stored in a variable so shellcheck does not attempt to parse its contents.
# shellcheck disable=SC2016
PY_DECODE='
import sys, json
data = json.load(sys.stdin)
out = data.get("out-data", "")
if out:
    sys.stdout.write(out)
'

# =============================================================================

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

qga_decode() {
    python3 -c "${PY_DECODE}"
}

# Run a SHORT command synchronously in the guest and return decoded stdout.
# --timeout 30 forces synchronous behaviour regardless of command duration.
# Do NOT use for long-running commands — use nohup+poll_guest_pid for those.
qga_exec() {
    local vmid=$1
    shift
    $QM guest exec "${vmid}" --timeout 30 -- "$@" 2>/dev/null | qga_decode 2>/dev/null
}

wait_for_agent() {
    local vmid=$1 elapsed=0
    log "[VM ${vmid}] Waiting for guest agent..."
    until $QM agent "${vmid}" ping &>/dev/null; do
        sleep 5
        elapsed=$(( elapsed + 5 ))
        (( elapsed >= AGENT_TIMEOUT )) && die "[VM ${vmid}] Timed out waiting for guest agent"
    done
    log "[VM ${vmid}] Guest agent ready"
}

wait_for_shutdown() {
    local vmid=$1 elapsed=0
    log "Waiting for VM ${vmid} to shut down..."
    until [[ $($QM status "${vmid}" | awk '{print $2}') == "stopped" ]]; do
        sleep 5
        elapsed=$(( elapsed + 5 ))
        (( elapsed >= AGENT_TIMEOUT )) && die "Timed out waiting for VM ${vmid} to shut down"
    done
    log "VM ${vmid} stopped"
}

# =============================================================================
# Guest scripts (single-quoted strings — no expansion at assignment time).
# Literal single quotes inside are escaped as '\'' (end-quote, quote, re-open).
# =============================================================================

MAIN_SCRIPT='#!/bin/bash
set -euo pipefail
SCRIPT=/tmp/pve-update.sh
trap '\''echo $? > ${SCRIPT}.rc'\'' EXIT

export DEBIAN_FRONTEND=noninteractive

echo "[guest] Checking cloud-init..."
if cloud-init status 2>/dev/null | grep -qE '\''running|waiting'\''; then
    echo "[guest] Waiting for cloud-init to finish..."
    cloud-init status --wait > /dev/null 2>&1
else
    echo "[guest] cloud-init not active, skipping wait."
fi

echo "[guest] Updating package lists..."
aptitude update

echo "[guest] Running safe-upgrade..."
aptitude safe-upgrade -y

if [ -f /var/run/reboot-required ]; then
    echo "[guest] Reboot required."
    touch /tmp/pve-reboot-needed
    echo 0 > /tmp/pve-update.sh.rc
    reboot
fi

echo "[guest] No reboot needed, running cleanup..."
apt-get -y autoremove --purge
apt-get -y clean
apt-get -y autoclean
fstrim -av

cloud-init clean
truncate -s 0 /etc/machine-id
truncate -s 0 /var/lib/dbus/machine-id
rm -f ~/.bash_history
truncate -s 0 /root/.bash_history

sync
echo "[guest] Done."'

POSTREBOOT_SCRIPT='#!/bin/bash
set -euo pipefail
SCRIPT=/tmp/pve-postreboot.sh
trap '\''echo $? > ${SCRIPT}.rc'\'' EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get -y autoremove --purge
apt-get -y clean
apt-get -y autoclean
fstrim -av

cloud-init clean
truncate -s 0 /etc/machine-id
truncate -s 0 /var/lib/dbus/machine-id
rm -f ~/.bash_history
truncate -s 0 /root/.bash_history

sync
echo "[guest] Post-reboot cleanup done."'

# =============================================================================

push_guest_script() {
    # Write a script into the guest using --pass-stdin, then chmod +x.
    # --pass-stdin pipes the content directly, avoiding base64 encode/decode.
    # --timeout 30 ensures synchronous completion.
    local vmid=$1 content=$2 dst=$3
    printf '%s' "${content}" | \
        $QM guest exec "${vmid}" --pass-stdin 1 --timeout 30 -- \
        /bin/bash -c "cat > ${dst} && chmod +x ${dst}" \
        > /dev/null 2>&1
}

launch_guest_script() {
    # Fire a script in the background via nohup. No --timeout here since
    # nohup forks and returns instantly — tracked via poll_guest_pid.
    local vmid=$1 script=$2 logfile=$3 pidfile=$4
    $QM guest exec "${vmid}" -- \
        /bin/bash -c "nohup ${script} >${logfile} 2>&1 & echo \$! >${pidfile}" \
        > /dev/null 2>&1 || true
    # Brief pause to let nohup detach before we start polling
    sleep 2
}

poll_guest_pid() {
    local vmid=$1 pidfile=$2 logfile=$3 rcfile=$4
    local elapsed=0 last_log_size=0

    log "[VM ${vmid}] Polling guest process..."
    while true; do
        sleep 10
        elapsed=$(( elapsed + 10 ))

        # Stream any new log lines, prefixed with VM ID
        local log_output
        log_output=$(qga_exec "${vmid}" /bin/bash -c "cat ${logfile} 2>/dev/null || true" || true)
        if [[ -n "${log_output}" ]]; then
            local new_lines
            new_lines=$(echo "${log_output}" | tail -n +$(( last_log_size + 1 )))
            if [[ -n "${new_lines}" ]]; then
                echo "${new_lines}" | sed "s/^/[VM ${vmid}] /"
            fi
            last_log_size=$(echo "${log_output}" | wc -l)
        fi

        # Check liveness of the background PID
        local raw_status
        raw_status=$(qga_exec "${vmid}" /bin/bash -c \
            "pid=\$(cat ${pidfile} 2>/dev/null) || { echo stopped; exit 0; }
             kill -0 \"\${pid}\" 2>/dev/null && echo running || echo stopped" \
            || true)
        local status="${raw_status:-stopped}"

        if [[ "${status}" != "running" ]]; then
            # Allow trap to finish writing the rc file before reading it
            sleep 2
            local raw_rc
            raw_rc=$(qga_exec "${vmid}" /bin/bash -c \
                "cat ${rcfile} 2>/dev/null || echo 1" \
                | tr -d '[:space:]' || true)
            local rc="${raw_rc:-1}"
            if [[ "${rc}" != "0" ]]; then
                die "[VM ${vmid}] Guest script exited with code ${rc}"
            fi
            log "[VM ${vmid}] Guest script completed successfully"
            return 0
        fi

        (( elapsed >= EXEC_TIMEOUT )) && die "[VM ${vmid}] Timed out waiting for guest script"
    done
}

update_vm() {
    local vmid=$1
    wait_for_agent "${vmid}"

    log "[VM ${vmid}] Writing update script..."
    push_guest_script "${vmid}" "${MAIN_SCRIPT}" /tmp/pve-update.sh

    log "[VM ${vmid}] Launching update script..."
    launch_guest_script "${vmid}" \
        /tmp/pve-update.sh \
        /tmp/pve-update.sh.log \
        /tmp/pve-update.sh.pid

    poll_guest_pid "${vmid}" \
        /tmp/pve-update.sh.pid \
        /tmp/pve-update.sh.log \
        /tmp/pve-update.sh.rc

    local raw_rebooted
    raw_rebooted=$(qga_exec "${vmid}" /bin/bash -c \
        '[ -f /tmp/pve-reboot-needed ] && echo yes || echo no' || true)
    local rebooted="${raw_rebooted:-no}"

    if [[ "${rebooted}" == "yes" ]]; then
        log "[VM ${vmid}] Rebooting for kernel update..."
        sleep 15
        wait_for_agent "${vmid}"

        log "[VM ${vmid}] Writing post-reboot script..."
        push_guest_script "${vmid}" "${POSTREBOOT_SCRIPT}" /tmp/pve-postreboot.sh

        log "[VM ${vmid}] Launching post-reboot script..."
        launch_guest_script "${vmid}" \
            /tmp/pve-postreboot.sh \
            /tmp/pve-postreboot.sh.log \
            /tmp/pve-postreboot.sh.pid

        poll_guest_pid "${vmid}" \
            /tmp/pve-postreboot.sh.pid \
            /tmp/pve-postreboot.sh.log \
            /tmp/pve-postreboot.sh.rc
    fi
}

# =============================================================================
# Step 1 — Destroy existing clone templates
# =============================================================================
log "=== Step 1: Destroying existing clone templates ==="
for vmid in "${CLONE_VMS[@]}"; do
    if $QM status "${vmid}" &>/dev/null; then
        log "Destroying VM ${vmid}..."
        $QM destroy "${vmid}" --destroy-unreferenced-disks 1
    else
        log "VM ${vmid} does not exist, skipping"
    fi
done

# =============================================================================
# Step 2 — Start source VMs
# =============================================================================
log "=== Step 2: Starting source VMs ==="
for vmid in "${SOURCE_VMS[@]}"; do
    vm_status=$($QM status "${vmid}" | awk '{print $2}')
    if [[ "${vm_status}" == "running" ]]; then
        log "VM ${vmid} already running, skipping start"
    else
        log "Starting VM ${vmid}..."
        $QM start "${vmid}"
    fi
done

# =============================================================================
# Step 3 — Update source VMs concurrently
# =============================================================================
log "=== Step 3: Updating source VMs (concurrent) ==="
declare -a UPDATE_PIDS=()
for vmid in "${SOURCE_VMS[@]}"; do
    log "Spawning update for VM ${vmid}..."
    update_vm "${vmid}" 2>&1 &
    UPDATE_PIDS+=($!)
done

log "Waiting for all VM updates to complete..."
FAILED=0
for pid in "${UPDATE_PIDS[@]}"; do
    if ! wait "${pid}"; then
        FAILED=1
    fi
done
(( FAILED )) && die "One or more VM updates failed"
log "=== All VM updates completed ==="

# =============================================================================
# Step 4 — Shut down source VMs
# =============================================================================
log "=== Step 4: Shutting down source VMs ==="
for vmid in "${SOURCE_VMS[@]}"; do
    log "Shutting down VM ${vmid}..."
    $QM shutdown "${vmid}"
done
for vmid in "${SOURCE_VMS[@]}"; do
    wait_for_shutdown "${vmid}"
done

# =============================================================================
# Step 5 — Clone
# =============================================================================
log "=== Step 5: Cloning VMs ==="
for i in "${!SOURCE_VMS[@]}"; do
    log "Cloning ${SOURCE_VMS[$i]} -> ${CLONE_VMS[$i]} (${CLONE_NAMES[$i]})..."
    $QM clone "${SOURCE_VMS[$i]}" "${CLONE_VMS[$i]}" --name "${CLONE_NAMES[$i]}"
done

# =============================================================================
# Step 6 — Configure and convert clones
# =============================================================================
log "=== Step 6: Configuring and converting clones ==="
for vmid in "${CLONE_VMS[@]}"; do
    $QM set "${vmid}" --ipconfig0 ip=dhcp
    $QM template "${vmid}"
    log "VM ${vmid} converted to template"
done

log "=== All done ==="
