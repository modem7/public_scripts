#!/bin/bash
# =============================================================================
#  verify-clone.sh
#  Holds no secrets.
#
#  Checks a template made by build-templates.sh without touching it: clones
#  it, boots the clone, waits for the guest agent and cloud-init, runs
#  verify-template.sh inside it through the agent, then destroys the clone.
#
#  Usage (as root, on the Proxmox host):
#    ./verify-clone.sh <template-vmid> [options]
#    ./verify-clone.sh --help              # full help, no root needed
#
#  The template needs qemu-guest-agent installed and the VM option agent=1.
#  Exit code: verify-template.sh's (0 ok, 1 FAIL), or 2-5 for this
#  script's own errors (see --help).
# =============================================================================
set -uo pipefail
set +x

# =============================================================================
#  SETTINGS
#  QM, PVESH and the poll timings can be overridden so a mock can be used.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QM="${QM:-qm}"
PVESH="${PVESH:-pvesh}"
POLL_INTERVAL="${POLL_INTERVAL:-3}"
MAX_STDIN=$((1024 * 1024))       # qm guest exec --pass-stdin limit
MAIL_WAIT="${MAIL_WAIT:-60}"     # seconds to wait for Postfix to relay
MAIL_POLL="${MAIL_POLL:-5}"

# =============================================================================
#  HELP
#  Checked before the root and qm checks, so --help works anywhere.
# =============================================================================
usage() {
    cat <<'EOF'
verify-clone.sh: check a template by running verify-template.sh in a clone.

Clones the template, starts the clone, waits for the guest agent and for
cloud-init to finish, runs verify-template.sh inside it through the guest
agent, prints the result, then destroys the clone.

USAGE
  ./verify-clone.sh <template-vmid> [options]
  ./verify-clone.sh -h|--help|help

ARGUMENTS
  <template-vmid>           VMID of the template to check. Required.
  --profile <p>             base, extras or desktop. Passed to
                            verify-template.sh. Default: it works it out.
  --send-test-mail <addr>   Passed to verify-template.sh, which sends a
                            test mail. This script then waits up to 60s
                            for Postfix to log status=sent for it.
  --vmid <id>               VMID for the clone. Must not exist yet.
                            Default: the next free one (pvesh nextid).
  --full                    Full clone. Default: linked clone.
  --storage <name>          Target storage for a full clone. Only with --full.
  --keep                    Leave the clone running afterwards.
  --timeout <secs>          Limit for each of: the guest agent coming up,
                            and cloud-init finishing. Default: 300
  --verify-timeout <secs>   Limit for the verify run itself. Default: 600
  --script <path>           verify-template.sh to run.
                            Default: the one next to this script.
  -h, --help, help          Show this help.

EXIT CODES
  0    verify-template.sh passed (WARNs are fine).
  1    verify-template.sh had a FAIL, the test mail failed, or the clone
       could not be made or started.
  2    Usage error, or a check before cloning failed.
  3    The guest agent did not answer within --timeout.
  4    cloud-init finished with an error, or is not installed.
  5    A command in the guest did not finish within its timeout.
  130  Interrupted (Ctrl-C). 143: terminated.
  The clone is destroyed in every case, unless --keep is given.

EXAMPLES
  ./verify-clone.sh 9002
  ./verify-clone.sh 9002 --profile extras
  ./verify-clone.sh 9002 --send-test-mail you@example.com
  ./verify-clone.sh 9002 --full --storage local-lvm --vmid 9101
  ./verify-clone.sh 9002 --keep

NOTES
  - Run as root on the Proxmox host.
  - Only a VM this run created is ever stopped or destroyed.
  - A linked clone needs storage that supports it (LVM-thin, ZFS, Ceph,
    qcow2). If it fails, try --full.
  - The clone gets the template's Cloud-Init settings, so it may take an
    IP from DHCP for the duration of the run.
  - Manual clean-up, if needed: qm destroy <id> --purge
EOF
}

# =============================================================================
#  ARGUMENTS
# =============================================================================
TEMPLATE="" PROFILE="" TEST_MAIL="" NEWID="" FULL=0 STORAGE="" KEEP=0
TIMEOUT=300 VERIFY_TIMEOUT=600 VERIFY_SCRIPT="$SCRIPT_DIR/verify-template.sh"

usage_error() { { echo "Error: $*"; echo "Run ./verify-clone.sh --help for usage."; } >&2; exit 2; }
need_val() { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || usage_error "$1 needs a value."; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help|help)   usage; exit 0 ;;
        --profile)        need_val "$@"; PROFILE="$2"; shift 2 ;;
        --send-test-mail) need_val "$@"; TEST_MAIL="$2"; shift 2 ;;
        --vmid)           need_val "$@"; NEWID="$2"; shift 2 ;;
        --full)           FULL=1; shift ;;
        --storage)        need_val "$@"; STORAGE="$2"; shift 2 ;;
        --keep)           KEEP=1; shift ;;
        --timeout)        need_val "$@"; TIMEOUT="$2"; shift 2 ;;
        --verify-timeout) need_val "$@"; VERIFY_TIMEOUT="$2"; shift 2 ;;
        --script)         need_val "$@"; VERIFY_SCRIPT="$2"; shift 2 ;;
        -*)               usage_error "unknown option: $1" ;;
        *)  [[ -z "$TEMPLATE" ]] || usage_error "more than one template VMID given."
            TEMPLATE="$1"; shift ;;
    esac
done

[[ -n "$TEMPLATE" ]]                  || usage_error "no template VMID given."
[[ "$TEMPLATE" =~ ^[0-9]+$ ]]         || usage_error "template VMID must be a number: $TEMPLATE"
[[ -z "$NEWID" || "$NEWID" =~ ^[0-9]+$ ]] || usage_error "--vmid must be a number: $NEWID"
[[ -z "$PROFILE" || "$PROFILE" =~ ^(base|extras|desktop)$ ]] \
                                      || usage_error "--profile must be base, extras or desktop."
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]     || usage_error "--timeout must be a whole number of seconds."
[[ "$VERIFY_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || usage_error "--verify-timeout must be a whole number of seconds."
[[ -z "$STORAGE" || $FULL -eq 1 ]]    || usage_error "--storage only works with --full."
[[ "$NEWID" != "$TEMPLATE" ]]         || usage_error "--vmid is the template's own VMID."

# =============================================================================
#  OUTPUT
#  Colours only when stdout is a terminal.
# =============================================================================
if [[ -t 1 ]]; then G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' C='\033[0;36m' B='\033[1m' N='\033[0m'
else G='' Y='' R='' C='' B='' N=''; fi
info() { echo -e "${C}==>${N} $*"; }
warn() { echo -e "${Y}WARN:${N} $*" >&2; }
die()  { echo -e "${R}Error:${N} $1" >&2; exit "${2:-1}"; }

# =============================================================================
#  CHECKS
# =============================================================================
# VERIFY_CLONE_SKIP_ROOT=1 is for tests with a mock qm only. Not in --help.
[[ $EUID -eq 0 || "${VERIFY_CLONE_SKIP_ROOT:-}" == 1 ]] || die "Run as root on the Proxmox host." 2
command -v "$QM" >/dev/null    || die "$QM not found: run this on the Proxmox host." 2
command -v "$PVESH" >/dev/null || die "$PVESH not found: run this on the Proxmox host." 2
if command -v python3 >/dev/null; then JSON=python3
elif command -v jq >/dev/null; then JSON=jq
else die "Need python3 or jq to read qm's output." 2; fi

[[ -f "$VERIFY_SCRIPT" ]] || die "verify script not found: $VERIFY_SCRIPT (use --script <path>)." 2
grep -q '^#  verify-template.sh$' "$VERIFY_SCRIPT" \
    || die "$VERIFY_SCRIPT is not verify-template.sh (its header does not name it). Wrong file or name?" 2
size=$(stat -c %s "$VERIFY_SCRIPT")
(( size <= MAX_STDIN )) || die "$VERIFY_SCRIPT is $size bytes: qm guest exec takes at most $MAX_STDIN on stdin." 2

tpl_conf="$("$QM" config "$TEMPLATE" 2>&1)" || die "VM $TEMPLATE not found: $tpl_conf" 2
grep -qx 'template: 1' <<< "$tpl_conf" || die "VM $TEMPLATE is not a template." 2
grep -qE '^agent: *(1|enabled=1)' <<< "$tpl_conf" \
    || warn "template $TEMPLATE does not show agent=1: the guest agent wait will likely time out."

if [[ -z "$NEWID" ]]; then
    NEWID="$("$PVESH" get /cluster/nextid)" || die "pvesh get /cluster/nextid failed." 2
    NEWID="${NEWID//[[:space:]]/}"
    [[ "$NEWID" =~ ^[0-9]+$ ]] || die "pvesh get /cluster/nextid gave no VMID: $NEWID" 2
fi
"$QM" status "$NEWID" &>/dev/null && die "VMID $NEWID already exists: pick another with --vmid." 2

# =============================================================================
#  CLEAN-UP
#  CLONED is set only after qm clone succeeded, so this never touches a VM
#  that existed before the run.
# =============================================================================
CLONED=0
CLONE_STATE="not created"
WORK="$(mktemp -d)" || die "mktemp failed."

# shellcheck disable=SC2317,SC2329  # only called by the EXIT trap
cleanup() {
    local rc=$?
    trap '' INT TERM
    if (( CLONED )); then
        if (( KEEP )); then
            CLONE_STATE="kept: $NEWID"
            echo
            info "Clone $NEWID kept (still running)."
            echo "    Its IP:    qm guest cmd $NEWID network-get-interfaces"
            echo "    Remove it: qm destroy $NEWID --purge"
        else
            info "Removing clone $NEWID"
            if "$QM" status "$NEWID" 2>/dev/null | grep -q 'status: running'; then
                "$QM" stop "$NEWID" --timeout 30 || warn "qm stop $NEWID failed."
            fi
            if "$QM" destroy "$NEWID" --purge --destroy-unreferenced-disks 1; then
                CLONE_STATE="removed"
            else
                CLONE_STATE="NOT removed: $NEWID"
                (( rc == 0 )) && rc=1
                echo -e "${R}Error:${N} could not destroy clone $NEWID. Remove it by hand:" >&2
                echo "    qm stop $NEWID; qm destroy $NEWID --purge --destroy-unreferenced-disks 1" >&2
            fi
        fi
    fi
    rm -rf "$WORK"
    if (( rc == 0 )); then echo -e "${B}Result:${N} ${G}passed${N}, clone ${CLONE_STATE}"
    else echo -e "${B}Result:${N} ${R}failed (exit $rc)${N}, clone ${CLONE_STATE}"; fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# =============================================================================
#  GUEST EXEC
#  guest_exec [-q] <vmid> <timeout> [stdin-file] -- cmd...
#  Runs cmd in the guest via the agent. Leaves the guest's output in
#  $WORK/out and $WORK/err and prints them (unless -q). Returns the guest's
#  exit code, 5 if it did not finish in time, or qm's own code if qm failed.
#  qm prints JSON like {"exitcode":0,"exited":1,"out-data":"..."}; this is
#  not documented, so anything not starting with { is shown as plain text.
# =============================================================================
parse_json() {   # <json-file>: writes out/err, prints "exited exitcode signal out-trunc err-trunc"
    if [[ "$JSON" == python3 ]]; then
        python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for key, path in (("out-data", sys.argv[2]), ("err-data", sys.argv[3])):
    with open(path, "w", encoding="utf-8", errors="replace") as f:
        f.write(str(d.get(key, "")))
v = lambda k: "" if d.get(k) is None else str(int(d[k]) if isinstance(d[k], bool) else d[k])
print(v("exited") or "0", v("exitcode") or "-", v("signal") or "-",
      v("out-truncated") or "0", v("err-truncated") or "0")
' "$1" "$WORK/out" "$WORK/err"
    else
        jq -j '."out-data" // ""' "$1" > "$WORK/out" || return 1
        jq -j '."err-data" // ""' "$1" > "$WORK/err" || return 1
        jq -r '[(.exited // 0), (.exitcode // "-"), (.signal // "-"),
                (."out-truncated" // 0), (."err-truncated" // 0)]
               | map(if . == true then 1 elif . == false then 0 else . end) | map(tostring) | join(" ")' "$1"
    fi
}

show_output() {   # as the guest wrote it, plus a newline if the last line lacks one
    cat "$WORK/out"
    [[ -s "$WORK/out" && -n "$(tail -c1 "$WORK/out")" ]] && echo
    cat "$WORK/err" >&2
    [[ -s "$WORK/err" && -n "$(tail -c1 "$WORK/err")" ]] && echo >&2
    return 0
}

guest_exec() {
    local quiet=0 vmid tmo input=/dev/null rc meta exited code sig otrunc etrunc
    [[ "$1" == -q ]] && { quiet=1; shift; }
    vmid="$1" tmo="$2"; shift 2
    [[ "$1" != -- ]] && { input="$1"; shift; }
    shift   # the --
    local stdin_opt=()
    [[ "$input" != /dev/null ]] && stdin_opt=(--pass-stdin 1)

    "$QM" guest exec "$vmid" "${stdin_opt[@]}" --timeout "$tmo" -- "$@" \
        < "$input" > "$WORK/qm.out" 2> "$WORK/qm.err"
    rc=$?
    if [[ "$(tr -d ' \t\r\n' < "$WORK/qm.out" | head -c1)" == "{" ]] \
            && meta="$(parse_json "$WORK/qm.out")"; then
        read -r exited code sig otrunc etrunc <<< "$meta"
        (( quiet )) || show_output
        [[ "$otrunc" == 1 ]] && warn "guest output was cut short by the agent (out-truncated)."
        [[ "$etrunc" == 1 ]] && warn "guest error output was cut short by the agent (err-truncated)."
        if [[ "$exited" != 1 ]]; then
            warn "'$*' did not finish within ${tmo}s in the guest."
            return 5
        fi
        [[ "$sig" != "-" ]] && { warn "'$*' was killed by signal $sig in the guest."; return 1; }
        [[ "$code" == "-" ]] && { warn "'$*' gave no exit code."; return 5; }
        [[ "$code" =~ ^[0-9]+$ ]] || { warn "'$*' gave exit code $code."; return 1; }
        return "$(( code > 255 ? 1 : code ))"
    fi
    # Not JSON: show what qm printed as it is.
    cp "$WORK/qm.out" "$WORK/out"; cp "$WORK/qm.err" "$WORK/err"
    (( quiet )) || show_output
    (( rc == 0 )) || warn "qm guest exec failed (exit $rc)."
    return "$rc"
}

# =============================================================================
#  MAIN
# =============================================================================
mode="linked" clone_opts=()
(( FULL )) && { mode="full"; clone_opts=(--full 1); }
[[ -n "$STORAGE" ]] && clone_opts+=(--storage "$STORAGE")

info "Cloning template $TEMPLATE to $NEWID ($mode)"
if ! "$QM" clone "$TEMPLATE" "$NEWID" --name "verify-$TEMPLATE-$NEWID" "${clone_opts[@]}"; then
    (( FULL )) || echo "Hint: the storage may not support linked clones. Try again with --full." >&2
    die "qm clone failed."
fi
CLONED=1

info "Starting $NEWID"
"$QM" start "$NEWID" || die "qm start $NEWID failed."

info "Waiting for the guest agent (up to ${TIMEOUT}s)"
deadline=$((SECONDS + TIMEOUT))
until "$QM" agent "$NEWID" ping &>/dev/null; do
    if (( SECONDS >= deadline )); then
        echo "The guest agent did not answer within ${TIMEOUT}s." >&2
        echo "The template needs qemu-guest-agent installed and the VM option agent=1." >&2
        exit 3
    fi
    sleep "$POLL_INTERVAL"
done

info "Waiting for cloud-init to finish (up to ${TIMEOUT}s)"
guest_exec "$NEWID" "$TIMEOUT" -- /bin/sh -c \
    'command -v cloud-init >/dev/null || exit 127; exec cloud-init status --wait'
rc=$?
case "$rc" in
    0)   ;;
    2)   warn "cloud-init reported a recoverable error: carrying on." ;;
    5)   exit 5 ;;
    127) echo "cloud-init is not installed in the guest." >&2; exit 4 ;;
    *)   echo "cloud-init failed (exit $rc)." >&2; exit 4 ;;
esac

verify_args=()
[[ -n "$PROFILE" ]]   && verify_args+=(--profile "$PROFILE")
[[ -n "$TEST_MAIL" ]] && verify_args+=(--send-test-mail "$TEST_MAIL")

info "Running $(basename "$VERIFY_SCRIPT") in $NEWID (up to ${VERIFY_TIMEOUT}s)"
echo -e "${B}----- guest output -----${N}"
guest_exec "$NEWID" "$VERIFY_TIMEOUT" "$VERIFY_SCRIPT" -- /bin/bash -s -- "${verify_args[@]}"
RC=$?
echo -e "${B}----- end of guest output -----${N}"
(( RC == 5 )) && exit 5

# Postfix sends in the background: wait for the relay's verdict.
if [[ -n "$TEST_MAIL" ]]; then
    info "Waiting for Postfix to relay the test mail (up to ${MAIL_WAIT}s)"
    mail_deadline=$((SECONDS + MAIL_WAIT))
    while :; do
        # postfix@- is the unit that logs deliveries on Ubuntu; postfix is the wrapper.
        guest_exec -q "$NEWID" 30 -- journalctl -u postfix -u 'postfix@*' --no-pager --since "-10 min"
        mine="$(grep -F -- "to=<$TEST_MAIL>" "$WORK/out")"
        if grep -q 'status=sent' <<< "$mine"; then
            echo -e "  ${G}PASS${N}  mail relayed (status=sent)"
            break
        elif line="$(grep -E 'status=(deferred|bounced)' <<< "$mine" | tail -1)" && [[ -n "$line" ]]; then
            echo "        $line"
            grep -iE 'warning|error|fatal|panic' "$WORK/out" | grep -vF -- "$line" | tail -5 | sed 's/^/        /'
            echo -e "  ${R}FAIL${N}  mail not relayed: $(grep -oE 'status=(deferred|bounced)' <<< "$line")"
            (( RC == 0 )) && RC=1
            break
        elif (( SECONDS >= mail_deadline )); then
            echo -e "  ${Y}WARN${N}  no delivery result for $TEST_MAIL within ${MAIL_WAIT}s (check: journalctl -u postfix@-)"
            break
        fi
        sleep "$MAIL_POLL"
    done
fi

exit "$RC"
