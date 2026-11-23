#!/bin/bash
# Boot the files of a release once on a real printer before they are published.
# .github/workflows/release.yml runs this between the build and the publication,
# on the runner that sits in the printer's network.
#
#   tools/release-test.sh           write, trial boot, checks, return
#   tools/release-test.sh find      only look for the printer and say what it runs
#
# What it does, on a printer that runs a kept Datel OS:
#   1. waits until the printer is there, idle and cool (a print in progress is
#      waited for, never disturbed)
#   2. writes the release's kernel and root filesystem into the slot that is
#      NOT running (tools/flash-slot2.sh, verified by read-back)
#   3. points the boot marker at that slot and restarts. The new system starts
#      as a trial: its first step points the marker back, and boot-keep still
#      names the old slot
#   4. runs tools/release-test-checks.py on it: version, systemd, Klipper and
#      its three MCUs, G-code that moves nothing, camera, Mainsail
#   5. restarts again, which brings the previous system back, and checks that
#      it is the kept one
#
# The printer ends on the system it started on. The other slot holds the
# release afterwards: whatever was there before is overwritten, so
# OVERWRITE_OTHER_SLOT=1 has to say that this is fine.
#
# Not covered: a kernel that stops before its first service never points the
# marker back, and the stock bootloader has no boot counter. Such a release
# leaves the printer down until the marker is swapped over USB
# (tools/usbboot/README.md). The test says so and exits with 4.
#
# TAG            release tag (default: the tag on HEAD); names the files in RELEASE_DIR
# RELEASE_DIR    where the release's files are (default: release/)
# KERNEL ROOTFS  the two files directly, with VERSION=X.Y.Z, instead of TAG
# PRINTER        root@<ip>; without it the /24 of NET is searched for Moonraker's port
# NET            first three numbers of the printer's network (default 192.168.1)
# KEY            SSH private key for the printer (default ~/.ssh/k1_printer_ecdsa)
# WAIT           seconds to wait for a printer that is absent, printing or hot
#                (default 6 hours)
# LOG_DIR        where the report goes (default release-test/)
#
# Exit: 0 passed; 1 a check failed (the printer is back on its own system);
# 2 the test could not start (no printer, never idle, not a kept Datel OS);
# 3 the write failed (the other slot is marked empty, the printer never left
# its system); 4 the printer did not come back to its own system.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="${RELEASE_DIR:-$HERE/release}"
LOG_DIR="${LOG_DIR:-$HERE/release-test}"
NET="${NET:-192.168.1}"
KEY="${KEY:-$HOME/.ssh/k1_printer_ecdsa}"
WAIT="${WAIT:-21600}"
PRINTER="${PRINTER:-}"
GIVEN_PRINTER="$PRINTER"
BOOT_WAIT=480      # a restart takes about 50 s; the Wi-Fi may need minutes more
MODE="${1:-test}"

say() { echo "$(date -u +%H:%M:%S) $*"; }
die() { say "STOP: $2"; exit "$1"; }
now() { date +%s; }

ssh_to() {  # $1 root@ip, the rest is the command; stdin is the caller's
    local target="$1"; shift
    ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=4 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$target" "$@"
}
remote() { ssh_to "$PRINTER" "$@"; }

# Hosts of the /24 that answer on Moonraker's port
scan() {
    local i pids=()
    for i in $(seq 1 254); do
        ( exec 3<>"/dev/tcp/$NET.$i/7125" && echo "$NET.$i" ) 2>/dev/null &
        pids+=("$!")
    done
    sleep 3
    kill "${pids[@]}" 2>/dev/null
    wait 2>/dev/null
    return 0
}

# Sets PRINTER to a host that lets our key in and has Datel OS's slot tool
find_printer() {
    local ip
    if [ -n "$GIVEN_PRINTER" ]; then
        ssh_to "$GIVEN_PRINTER" 'test -x /usr/libexec/k1os/slot' < /dev/null 2>/dev/null && { PRINTER="$GIVEN_PRINTER"; return 0; }
        return 1
    fi
    if [ -n "$PRINTER" ] && ssh_to "$PRINTER" 'test -x /usr/libexec/k1os/slot' < /dev/null 2>/dev/null; then return 0; fi
    for ip in $(scan | sort -t. -k4 -n); do
        if ssh_to "root@$ip" 'test -x /usr/libexec/k1os/slot' < /dev/null 2>/dev/null; then PRINTER="root@$ip"; return 0; fi
    done
    return 1
}

# Runs on the printer right before a step that loads or restarts it: no print,
# no heater with a target, nozzle cool (a restart stops the hotend fan).
# Exit 3 with the reason on the last line when the printer is busy.
GATE='
q="http://127.0.0.1:7125/printer/objects/query?print_stats=state&virtual_sdcard=is_active&extruder=temperature,target&heater_bed=target"
a=$(wget -T 8 -qO- "$q" 2>/dev/null | tr -d " ")
s=$(echo "$a" | sed -n "s/.*\"print_stats\":{\"state\":\"\([a-z]*\)\".*/\1/p")
sd=$(echo "$a" | sed -n "s/.*\"is_active\":\([a-z]*\).*/\1/p")
t=$(echo "$a" | sed -n "s/.*\"extruder\":{[^}]*\"temperature\":\([0-9.]*\).*/\1/p")
tt=$(echo "$a" | sed -n "s/.*\"extruder\":{[^}]*\"target\":\([0-9.]*\).*/\1/p")
bt=$(echo "$a" | sed -n "s/.*\"heater_bed\":{\"target\":\([0-9.]*\).*/\1/p")
echo "gate: print \"$s\", sd active \"$sd\", nozzle \"$t\" C target \"$tt\", bed target \"$bt\""
case "$s" in standby|complete|cancelled|error) ;; *) echo "BUSY: print state \"$s\""; exit 3 ;; esac
[ "$sd" = false ] || { echo "BUSY: a file is being printed"; exit 3; }
case "$tt$bt" in 0.00.0) ;; *) echo "BUSY: a heater has a target"; exit 3 ;; esac
case "$t" in ""|*[!0-9.]*) echo "BUSY: no nozzle temperature"; exit 3 ;; esac
[ "${t%.*}" -lt 60 ] || { echo "BUSY: nozzle at $t C"; exit 3; }
'

# Waits until the printer is found and the gate lets it through; $1 seconds at most
wait_idle() {
    local start out why="" last=""
    start=$(now)
    while :; do
        if find_printer; then
            out=$(remote "$GATE" < /dev/null 2>&1) && { say "$PRINTER: $(echo "$out" | tail -n 1)"; return 0; }
            why="$PRINTER: $(echo "$out" | tail -n 1)"
        else
            if [ -n "$GIVEN_PRINTER" ]; then why="no Datel OS answers at $GIVEN_PRINTER"
            else why="no printer with Datel OS answers in $NET.0/24"; fi
        fi
        [ "$why" = "$last" ] || { say "waiting: $why"; last="$why"; }
        [ $(( $(now) - start )) -lt "$1" ] || { say "gave up after $1 s: $why"; return 1; }
        sleep 60
    done
}

# wait_root <partition> <seconds> [<uptime>]: until the printer answers from that
# root after a restart. A system that has been up for longer than the wait
# itself (or than <uptime> seconds) is one that never restarted.
wait_root() {
    local start out up
    start=$(now)
    while [ $(( $(now) - start )) -lt "$2" ]; do
        out=$(remote 'echo "$(cut -d. -f1 /proc/uptime) $(tr " " "\n" < /proc/cmdline | grep ^root=)"' < /dev/null 2>/dev/null) || out=
        up=${out%% *}
        case "$out" in *"root=/dev/mmcblk0p$1")
            if [ "$up" -lt "${3:-$(( $(now) - start + 30 ))}" ]; then
                say "up after $(( $(now) - start )) s: uptime $up s, ${out#* }"; return 0
            fi ;;
        esac
        # the address may have changed with the system; look again when none was given
        if [ -z "$out" ] && [ -z "$GIVEN_PRINTER" ] && [ $(( $(now) - start )) -gt 120 ]; then find_printer || true; fi
        sleep 4
    done
    say "no answer from root=/dev/mmcblk0p$1 within $2 s (last: '${out:-nothing}')"
    return 1
}

wait_klipper() {
    local start st=
    start=$(now)
    while [ $(( $(now) - start )) -lt "$1" ]; do
        st=$(remote 'wget -T 5 -qO- http://127.0.0.1:7125/printer/info 2>/dev/null' < /dev/null 2>/dev/null |
             tr -d ' ' | sed -n 's/.*"state":"\([a-z]*\)".*/\1/p')
        [ "$st" = ready ] && { say "Klipper ready after $(( $(now) - start )) s"; return 0; }
        sleep 4
    done
    say "Klipper state '${st:-no answer}' after $1 s"
    return 1
}

# ---- what is tested
if [ "$MODE" = find ]; then
    find_printer || die 2 "no printer with Datel OS answers${GIVEN_PRINTER:+ at $GIVEN_PRINTER}"
    say "printer: $PRINTER"
    remote '/usr/libexec/k1os/slot status; . /etc/os-release; echo "VERSION=$VERSION BUILD_ID=$BUILD_ID"' < /dev/null
    remote "$GATE" < /dev/null
    exit 0
fi
[ "$MODE" = test ] || { sed -n '2,45p' "$0" >&2; exit 2; }

if [ -n "${KERNEL:-}" ] || [ -n "${ROOTFS:-}" ]; then
    [ -n "${KERNEL:-}" ] && [ -n "${ROOTFS:-}" ] && [ -n "${VERSION:-}" ] || die 2 "KERNEL, ROOTFS and VERSION go together"
    WHAT="$VERSION ($(basename "$KERNEL"), $(basename "$ROOTFS"))"
else
    TAG="${TAG:-$(git -C "$HERE" describe --tags --exact-match 2>/dev/null || true)}"
    [ -n "$TAG" ] || die 2 "HEAD has no tag; set TAG=vX.Y.Z, or KERNEL, ROOTFS and VERSION"
    VERSION="${TAG#v}"; VERSION="${VERSION%%-*}"
    KERNEL="$RELEASE_DIR/datel-os-$TAG-xImage"
    ROOTFS="$RELEASE_DIR/datel-os-$TAG-rootfs.squashfs"
    WHAT="$TAG"
fi
[ -f "$KERNEL" ] || die 2 "missing $KERNEL"
[ -f "$ROOTFS" ] || die 2 "missing $ROOTFS"
[ -f "$KEY" ] || die 2 "missing SSH key $KEY"
[ "${OVERWRITE_OTHER_SLOT:-}" = 1 ] ||
    die 2 "the test overwrites the slot the printer is not running from; say OVERWRITE_OTHER_SLOT=1"

mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_DIR/release-test.log") 2>&1
say "== release test of $WHAT"

# ---- 1. the printer, idle, on a kept Datel OS
wait_idle "$WAIT" || exit 2
STATE=$(remote '
    case " $(cat /proc/cmdline) " in
        *" root=/dev/mmcblk0p8 "*) echo "running=2" ;;
        *" root=/dev/mmcblk0p7 "*) echo "running=1" ;;
    esac
    /usr/libexec/k1os/slot status | sed -n "s/^keep: *\([a-z]*\).*/keep=\1/p; s/^next: *//p" | sed "s/^ota:/next=ota:/"
    . /etc/os-release; echo "version=$VERSION"' < /dev/null) || die 2 "cannot read the printer's state"
get() { echo "$STATE" | sed -n "s/^$1=//p"; }
FROM=$(get running)
case "$FROM" in
    1) TO=2; FROM_PART=7; TO_PART=8; FROM_MARK=ota:kernel ;;
    2) TO=1; FROM_PART=8; TO_PART=7; FROM_MARK=ota:kernel2 ;;
    *) die 2 "the printer runs from neither slot's root: $(echo "$STATE" | tr '\n' ' ')" ;;
esac
say "$PRINTER runs $(get version) from slot $FROM, keep $(get keep), next boot $(get next)"
# Only a kept system comes back by itself after the trial of the other slot
[ "$(get keep)" = yes ] && [ "$(get next)" = "$FROM_MARK" ] ||
    die 2 "slot $FROM is not kept (k1os-slot keep): the printer would not return to it after the test"

# ---- 2. write the other slot
export PRINTER KEY KERNEL ROOTFS
export SLOT="$TO"
say "== writing slot $TO"
if ! "$HERE/tools/flash-slot2.sh" --write; then
    say "the write of slot $TO failed; the printer still runs slot $FROM and that stays the next boot"
    exit 3
fi

# ---- 3. marker at the new slot and restart, both behind the gate
say "== trial boot of slot $TO"
if ! "$HERE/tools/flash-slot2.sh" --switch; then
    remote '/usr/libexec/k1os/slot confirm' < /dev/null
    die 3 "slot $TO did not verify before the switch"
fi
if ! remote "$GATE"'
( sleep 1; systemctl reboot ) >/dev/null 2>&1 &
echo "restart asked"' < /dev/null; then
    # the printer got busy in between: the marker goes back to the kept slot
    remote '/usr/libexec/k1os/slot confirm; /usr/libexec/k1os/slot status' < /dev/null
    die 2 "the printer became busy before the restart; the next boot is slot $FROM again"
fi
sleep 15

RESULT=0
if ! wait_root "$TO_PART" "$BOOT_WAIT"; then
    # Did it fall back by itself (a watchdog restart after the trial step)?
    if wait_root "$FROM_PART" 60 $(( BOOT_WAIT + 120 )); then
        # the journal is in RAM: what slot $TO logged is only where the printer streams it
        say "FAIL: slot $TO did not stay up; the printer restarted into slot $FROM by itself"
        wait_klipper 240 || exit 4
        exit 1
    fi
    say "FAIL: the printer answers from neither slot. If $WHAT stopped before its first service,"
    say "the marker still names slot $TO: swap it over USB (tools/usbboot/README.md, --swap-ota)."
    exit 4
fi

# ---- 4. the checks
wait_klipper 240 || RESULT=1
say "== checks on slot $TO"
remote "python3 - '$VERSION' '$TO_PART' '$FROM_MARK'" < "$HERE/tools/release-test-checks.py" || RESULT=1
if [ "$RESULT" != 0 ]; then
    say "== the journal's warnings of this boot"
    remote 'journalctl -b -p warning -n 60 -o short-monotonic --no-pager | tail -n 60' < /dev/null
fi

# ---- 5. back to the kept system
say "== back to slot $FROM"
# Someone may have started a print on the system under test: wait for it. A
# Klipper that is not ready prints nothing and holds no heater, so there the
# restart does not wait.
KSTATE=$(remote 'wget -T 5 -qO- http://127.0.0.1:7125/printer/info 2>/dev/null' < /dev/null 2>/dev/null |
         tr -d ' ' | sed -n 's/.*"state":"\([a-z]*\)".*/\1/p')
if [ "$KSTATE" != ready ]; then
    say "Klipper state '${KSTATE:-no answer}' on slot $TO: restarting without the gate"
elif ! wait_idle "$WAIT"; then
    say "the printer stays busy on slot $TO; a restart or a power cycle returns it to slot $FROM"
    exit 4
fi
remote '( sleep 1; systemctl reboot ) >/dev/null 2>&1 & echo "restart asked"' < /dev/null
sleep 15
wait_root "$FROM_PART" "$BOOT_WAIT" || { say "FAIL: the printer did not come back to slot $FROM"; exit 4; }
BACK=$(remote '/usr/libexec/k1os/slot status' < /dev/null)
echo "$BACK"
echo "$BACK" | grep -q '^keep: *yes' && echo "$BACK" | grep -q "^next: *$FROM_MARK\$" ||
    { say "FAIL: slot $FROM is not the kept next boot"; exit 4; }
wait_klipper 240 || { say "FAIL: Klipper is not ready on slot $FROM after the test"; exit 4; }

if [ "$RESULT" = 0 ]; then
    say "PASSED: $WHAT started on $PRINTER and passed every check; slot $TO holds it, slot $FROM runs"
else
    say "FAILED: $WHAT did not pass; slot $TO holds it, slot $FROM runs"
fi
exit "$RESULT"
