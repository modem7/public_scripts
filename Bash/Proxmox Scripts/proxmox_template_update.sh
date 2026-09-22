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
EXEC_TIMEOUT=900    # seconds to wait for guest script to complete (raised: kernel unpacks are slow)

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
set -uo pipefail
SCRIPT=/tmp/pve-update.sh
FAILSTEP_FILE=/tmp/pve-update.sh.failstep

on_exit() {
    local rc=$?
    echo "${rc}" > "${SCRIPT}.rc"
    if [ "${rc}" -ne 0 ] && [ -f "${FAILSTEP_FILE}" ]; then
        echo "[guest] FAILED at step: $(cat ${FAILSTEP_FILE})" >&2
    fi
}
trap on_exit EXIT

step() { echo "$1" > "${FAILSTEP_FILE}"; echo "[guest] >> $1"; }

export DEBIAN_FRONTEND=noninteractive

step "dpkg sanity check"
# If a previous run was interrupted mid-unpack, dpkg refuses everything
# until it is reconfigured. Detect and self-heal instead of failing every
# subsequent run at the same spot.
if ! dpkg --audit >/dev/null 2>&1 || grep -qs "half-installed\|half-configured\|unpacked" <(dpkg -l 2>/dev/null | awk "{print \$1}"); then
    echo "[guest] dpkg looks interrupted, running dpkg --configure -a..."
    dpkg --configure -a || {
        echo "[guest] dpkg --configure -a failed, trying apt-get -f install..." >&2
        apt-get -y -f install || true
        dpkg --configure -a
    }
fi

step "check cloud-init"
if cloud-init status 2>/dev/null | grep -qE '\''running|waiting'\''; then
    echo "[guest] Waiting for cloud-init to finish..."
    cloud-init status --wait > /dev/null 2>&1
else
    echo "[guest] cloud-init not active, skipping wait."
fi

step "apt update"
if ! aptitude update 2>&1; then
    echo "[guest] aptitude update failed, retrying once after dpkg --configure -a..." >&2
    dpkg --configure -a || true
    aptitude update
fi

step "apt safe-upgrade"
if ! aptitude safe-upgrade -y 2>&1; then
    echo "[guest] safe-upgrade failed. dpkg state:" >&2
    dpkg --audit >&2 || true
    exit 1
fi

step "check reboot-required"
if [ -f /var/run/reboot-required ]; then
    echo "[guest] Reboot required."
    touch /tmp/pve-reboot-needed
    echo 0 > "${SCRIPT}.rc"
    step "reboot"
    reboot
    exit 0
fi

step "cleanup: autoremove"
apt-get -y autoremove --purge
step "cleanup: apt clean"
apt-get -y clean
apt-get -y autoclean
step "cleanup: fstrim"
fstrim -av

step "cleanup: cloud-init clean"
cloud-init clean
truncate -s 0 /etc/machine-id
truncate -s 0 /var/lib/dbus/machine-id
rm -f ~/.bash_history
truncate -s 0 /root/.bash_history

step "done"
sync
echo "[guest] Done."'

POSTREBOOT_SCRIPT='#!/bin/bash
set -uo pipefail
SCRIPT=/tmp/pve-postreboot.sh
FAILSTEP_FILE=/tmp/pve-postreboot.sh.failstep

on_exit() {
    local rc=$?
    echo "${rc}" > "${SCRIPT}.rc"
    if [ "${rc}" -ne 0 ] && [ -f "${FAILSTEP_FILE}" ]; then
        echo "[guest] FAILED at step: $(cat ${FAILSTEP_FILE})" >&2
    fi
}
trap on_exit EXIT

step() { echo "$1" > "${FAILSTEP_FILE}"; echo "[guest] >> $1"; }

export DEBIAN_FRONTEND=noninteractive

step "dpkg sanity check"
if ! dpkg --audit >/dev/null 2>&1; then
    echo "[guest] dpkg looks interrupted post-reboot, running dpkg --configure -a..."
    dpkg --configure -a || {
        apt-get -y -f install || true
        dpkg --configure -a
    }
fi

step "cleanup: autoremove"
apt-get -y autoremove --purge
step "cleanup: apt clean"
apt-get -y clean
apt-get -y autoclean
step "cleanup: fstrim"
fstrim -av

step "cleanup: cloud-init clean"
cloud-init clean
truncate -s 0 /etc/machine-id
truncate -s 0 /var/lib/dbus/machine-id
rm -f ~/.bash_history
truncate -s 0 /root/.bash_history

step "done"
sync
echo "[guest] Post-reboot cleanup done."'

# =============================================================================

push_guest_script() {
    local vmid=$1 content=$2 dst=$3
    if ! printf '%s' "${content}" | \
        $QM guest exec "${vmid}" --pass-stdin 1 --timeout 30 -- \
        /bin/bash -c "cat > ${dst} && chmod +x ${dst}" \
        > /dev/null 2>&1
    then
        die "[VM ${vmid}] Failed to push script to ${dst}"
    fi
}

launch_guest_script() {
    local vmid=$1 script=$2 logfile=$3 pidfile=$4
    # Clear stale rc/failstep files from a previous run before launching,
    # so a crash before the trap fires can't be misread as a stale success.
    qga_exec "${vmid}" /bin/bash -c "rm -f ${logfile}.rc ${logfile%.log}.failstep ${logfile}" || true
    $QM guest exec "${vmid}" -- \
        /bin/bash -c "nohup ${script} >${logfile} 2>&1 & echo \$! >${pidfile}" \
        > /dev/null 2>&1 || true
    sleep 2
}

poll_guest_pid() {
    local vmid=$1 pidfile=$2 logfile=$3 rcfile=$4
    local elapsed=0 last_log_size=0

    log "[VM ${vmid}] Polling guest process..."
    while true; do
        sleep 10
        elapsed=$(( elapsed + 10 ))

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

        local raw_status
        raw_status=$(qga_exec "${vmid}" /bin/bash -c \
            "pid=\$(cat ${pidfile} 2>/dev/null) || { echo stopped; exit 0; }
             kill -0 \"\${pid}\" 2>/dev/null && echo running || echo stopped" \
            || true)
        local status="${raw_status:-stopped}"

        if [[ "${status}" != "running" ]]; then
            sleep 2
            local raw_rc
            raw_rc=$(qga_exec "${vmid}" /bin/bash -c \
                "cat ${rcfile} 2>/dev/null || echo unknown" \
                | tr -d '[:space:]' || true)
            local rc="${raw_rc:-unknown}"

            if [[ "${rc}" == "unknown" ]]; then
                # Process died without ever writing an rc file — e.g. OOM-killed,
                # guest agent lost the connection, or the trap never ran.
                die "[VM ${vmid}] Guest process vanished with no exit code recorded (log: ${logfile})"
            fi

            if [[ "${rc}" != "0" ]]; then
                local failstep
                failstep=$(qga_exec "${vmid}" /bin/bash -c \
                    "cat ${logfile%.log}.failstep 2>/dev/null || echo unknown" || true)
                die "[VM ${vmid}] Guest script exited with code ${rc} at step '${failstep:-unknown}' — see log above"
            fi
            log "[VM ${vmid}] Guest script completed successfully"
            return 0
        fi

        if (( elapsed >= EXEC_TIMEOUT )); then
            die "[VM ${vmid}] Timed out after ${EXEC_TIMEOUT}s waiting for guest script (log: ${logfile})"
        fi
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
declare -a UPDATE_VMIDS=()
for vmid in "${SOURCE_VMS[@]}"; do
    log "Spawning update for VM ${vmid}..."
    update_vm "${vmid}" 2>&1 &
    UPDATE_PIDS+=($!)
    UPDATE_VMIDS+=("${vmid}")
done

log "Waiting for all VM updates to complete..."
FAILED=0
declare -a FAILED_VMIDS=()
for i in "${!UPDATE_PIDS[@]}"; do
    if ! wait "${UPDATE_PIDS[$i]}"; then
        FAILED=1
        FAILED_VMIDS+=("${UPDATE_VMIDS[$i]}")
    fi
done

if (( FAILED )); then
    die "Update failed for VM(s): ${FAILED_VMIDS[*]} — see per-VM errors above. Not proceeding to clone/template steps."
fi
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
    if ! $QM clone "${SOURCE_VMS[$i]}" "${CLONE_VMS[$i]}" --name "${CLONE_NAMES[$i]}"; then
        die "Clone failed: ${SOURCE_VMS[$i]} -> ${CLONE_VMS[$i]}"
    fi
done

# =============================================================================
# Step 6 — Configure and convert clones
# =============================================================================
log "=== Step 6: Configuring and converting clones ==="
for vmid in "${CLONE_VMS[@]}"; do
    if ! $QM set "${vmid}" --ipconfig0 ip=dhcp; then
        die "Failed to set ipconfig on VM ${vmid}"
    fi
    if ! $QM template "${vmid}"; then
        die "Failed to convert VM ${vmid} to template"
    fi
    log "VM ${vmid} converted to template"
done

log "=== All done ==="