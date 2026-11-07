#!/bin/bash
# Write Datel OS into the slot that is not running, over SSH. Slot 2 is
# kernel2 = mmcblk0p6 + rootfs2 = mmcblk0p8 (written while slot 1 runs); slot 1
# is kernel = mmcblk0p5 + rootfs = mmcblk0p7 (written while slot 2 runs).
# Nothing else on the eMMC is touched.
#
#   tools/flash-slot2.sh            check only, writes nothing
#   tools/flash-slot2.sh --write    write and verify the slot, marker untouched
#   tools/flash-slot2.sh --switch   point the marker at that slot (next boot)
#
# SLOT=2 (default) or SLOT=1 picks the target. Images come from out/
# (OUT= names another directory); KERNEL= and ROOTFS= name the two files
# directly, e.g. the ones from a GitHub Release.
#
# A write is refused while a print runs or is paused, and also when the
# printer does not say: Moonraker is not up yet after a boot, Klipper is not
# connected, or it is stock firmware without Moonraker. IDLE=1 says that no
# print is running and lets the write go on then.
#
# Datel OS boots as a trial: its first step points the marker back at the
# slot it was written from, so a power cycle returns to the previous system
# until you run "k1os-slot keep" on the new one. That holds for every new
# system: boot-keep names the slot that was kept, and a keep that names the
# slot written here is removed with the system it was said about.
#
# While a slot is written it holds no system, and says so: the first 4 KiB of
# its kernel and of its rootfs are zeroed before the write and put in last,
# after the rest was read back. Datel OS's trial boot never points the marker
# at a slot whose kernel or rootfs starts with a zero block, so a write that
# broke off cannot become the next boot.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PRINTER="${PRINTER:-root@192.168.1.104}"
KEY="${KEY:-$HOME/.ssh/k1_printer_ecdsa}"
PUBKEY="${PUBKEY:-$KEY.pub}"
# Stock and Datel OS have different host keys and may swap IP leases, so the
# host-key cache is not used; the printer is authenticated by our own key.
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$PRINTER")
OUT="${OUT:-$HERE/out}"
KERNEL="${KERNEL:-$OUT/xImage-k1os}"
ROOTFS="${ROOTFS:-$OUT/k1-image-rootfs.squashfs}"
MODE="${1:-check}"
SLOT="${SLOT:-2}"
case "$SLOT" in
2) KDEV=/dev/mmcblk0p6; RDEV=/dev/mmcblk0p8; FROM=/dev/mmcblk0p7; MARK_FROM=ota:kernel;  MARK_TO=ota:kernel2 ;;
1) KDEV=/dev/mmcblk0p5; RDEV=/dev/mmcblk0p7; FROM=/dev/mmcblk0p8; MARK_FROM=ota:kernel2; MARK_TO=ota:kernel ;;
*) echo "STOP: SLOT must be 1 or 2" >&2; exit 1 ;;
esac
OTHER=$(( 3 - SLOT ))

die() { echo "STOP: $*" >&2; exit 1; }
md5of() { md5 -q "$1"; }

# Pad to whole 4 KiB blocks so the read-back can use dd with block counts.
pad4k() {
    local f="$1" out="$2" size pad
    cp "$f" "$out"
    size=$(stat -f %z "$out")
    pad=$(( (4096 - size % 4096) % 4096 ))
    [ "$pad" -gt 0 ] && dd if=/dev/zero bs=1 count="$pad" 2>/dev/null >> "$out"
    return 0
}

[ -f "$KERNEL" ] || die "missing $KERNEL"
[ -f "$ROOTFS" ] || die "missing $ROOTFS"
[ -f "$PUBKEY" ] || die "missing $PUBKEY (Datel OS allows SSH login with a key only)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pad4k "$KERNEL" "$TMP/kernel"; pad4k "$ROOTFS" "$TMP/rootfs"
KS=$(stat -f %z "$TMP/kernel"); RS=$(stat -f %z "$TMP/rootfs")
KM=$(md5of "$TMP/kernel"); RM=$(md5of "$TMP/rootfs")
# Each image in two parts: the first 4 KiB block, written last, and the rest.
split4k() {
    dd if="$1" of="$1.head" bs=4096 count=1 2>/dev/null
    dd if="$1" of="$1.body" bs=4096 skip=1 2>/dev/null
    [ "$(tr -d '\000' < "$1.head" | wc -c)" -gt 0 ] || die "$1 starts with a zero block; it would read as an empty slot"
}
[ "$KS" -ge 8192 ] && [ "$RS" -ge 8192 ] || die "kernel or rootfs is shorter than two blocks"
split4k "$TMP/kernel"; split4k "$TMP/rootfs"
KBM=$(md5of "$TMP/kernel.body"); RBM=$(md5of "$TMP/rootfs.body")

echo "== printer state"
STATE=$("${SSH[@]}" '
  echo "cmdline=$(cat /proc/cmdline)"
  echo "marker=$(dd if=/dev/mmcblk0p1 bs=512 count=1 2>/dev/null | tr -d "\000" | head -n 1)"
  echo "kdev=$(( $(cat /sys/class/block/'"${KDEV#/dev/}"'/size) * 512 ))"
  echo "rdev=$(( $(cat /sys/class/block/'"${RDEV#/dev/}"'/size) * 512 ))"
  q="http://127.0.0.1:7125/printer/objects/query?print_stats=state"
  echo "print=$( (curl -s "$q" 2>/dev/null || wget -T 3 -qO- "$q" 2>/dev/null) | sed -n "s/.*\"state\": *\"\([a-z]*\)\".*/\1/p")"
')
echo "$STATE"
get() { echo "$STATE" | sed -n "s/^$1=//p"; }

case " $(get cmdline) " in *" root=$FROM "*) ;; *) die "not running from slot $OTHER ($FROM); refusing to touch slot $SLOT" ;; esac
[ "$(get marker)" = "$MARK_FROM" ] || [ "$MODE" = "--switch" ] || die "marker is '$(get marker)', expected $MARK_FROM"
# Only an answer that says so counts as "no print". IDLE=1 is the user's word
# for it where the printer gives none; it does not overrule a print that the
# printer reports.
case "$(get print)" in
printing|paused)
    die "a print is $(get print); wait until it finishes" ;;
standby|complete|cancelled|error)
    ;;
*)
    if [ "${IDLE:-}" = 1 ]; then
        echo "print state not readable; IDLE=1 says that no print is running"
    elif [ "$MODE" = "--write" ]; then
        die "cannot read the print state (got '$(get print)'): wait until Klipper is ready, or set IDLE=1 if no print is running"
    elif [ "$MODE" = check ]; then
        echo "print state not readable: --write will refuse unless IDLE=1 says that no print is running"
    fi ;;
esac
[ "$KS" -le "$(get kdev)" ] || die "kernel $KS B does not fit $KDEV"
[ "$RS" -le "$(get rdev)" ] || die "rootfs $RS B does not fit $RDEV"
echo "== images (slot $SLOT)"
echo "kernel  $KS B  md5 $KM  -> $KDEV"
echo "rootfs  $RS B  md5 $RM  -> $RDEV"

# The read-back is to come from the eMMC, not from the pages the write left in
# memory, so those are dropped first (where the kernel lets us).
verify() {  # $1 dev, $2 size, $3 md5, $4 blocks to skip (0: the whole image)
    local got skip="${4:-0}"
    got=$("${SSH[@]}" "sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; dd if=$1 bs=4096 skip=$skip count=$(( $2 / 4096 - skip )) 2>/dev/null | md5sum | cut -d' ' -f1")
    [ "$got" = "$3" ] || die "$1 read-back md5 $got != $3"
    echo "$1 verified ($got)"
}

case "$MODE" in
check)
    echo "== check only, nothing written. Next: $0 --write" ;;
--write)
    echo "== slot $SLOT holds no system from here on (first block of $KDEV and $RDEV zeroed)"
    "${SSH[@]}" "
      set -e
      k=/usr/data/k1os/boot-keep
      if [ \"\$(head -n 1 \$k 2>/dev/null)\" = $MARK_TO ]; then rm -f \$k; echo 'boot-keep named slot $SLOT: removed'; fi
      dd if=/dev/zero of=$KDEV bs=4096 count=1 2>/dev/null
      dd if=/dev/zero of=$RDEV bs=4096 count=1 2>/dev/null
      sync"
    echo "== writing kernel ($KDEV)"
    "${SSH[@]}" "dd of=$KDEV bs=4096 seek=1 2>/dev/null; sync" < "$TMP/kernel.body"
    verify "$KDEV" "$KS" "$KBM" 1
    echo "== writing rootfs ($RDEV), about a minute"
    "${SSH[@]}" "dd of=$RDEV bs=4096 seek=1 2>/dev/null; sync" < "$TMP/rootfs.body"
    verify "$RDEV" "$RS" "$RBM" 1
    echo "== first blocks: slot $SLOT holds a system again"
    "${SSH[@]}" "dd of=$RDEV bs=4096 count=1 2>/dev/null; sync" < "$TMP/rootfs.head"
    "${SSH[@]}" "dd of=$KDEV bs=4096 count=1 2>/dev/null; sync" < "$TMP/kernel.head"
    if ! (verify "$KDEV" "$KS" "$KM" && verify "$RDEV" "$RS" "$RM"); then
        "${SSH[@]}" "dd if=/dev/zero of=$KDEV bs=4096 count=1 2>/dev/null; dd if=/dev/zero of=$RDEV bs=4096 count=1 2>/dev/null; sync" ||
            echo "could not mark slot $SLOT as empty again" >&2
        die "slot $SLOT does not read back as written; it is marked as holding no system"
    fi
    echo "== SSH key for Datel OS (/usr/data/k1os/ssh/authorized_keys)"
    "${SSH[@]}" 'mkdir -p /usr/data/k1os/ssh && chmod 700 /usr/data/k1os/ssh && k=$(cat) &&
      { grep -qxF "$k" /usr/data/k1os/ssh/authorized_keys 2>/dev/null || echo "$k" >> /usr/data/k1os/ssh/authorized_keys; } &&
      chmod 600 /usr/data/k1os/ssh/authorized_keys && sync && wc -l < /usr/data/k1os/ssh/authorized_keys' < "$PUBKEY"
    echo "== slot $SLOT written and verified, marker still $MARK_FROM. Next: SLOT=$SLOT $0 --switch" ;;
--switch)
    verify "$KDEV" "$KS" "$KM"
    verify "$RDEV" "$RS" "$RM"
    "${SSH[@]}" "
      b=/tmp/k1os-marker
      { printf '$MARK_TO\n\n'; dd if=/dev/zero bs=$(( 512 - ${#MARK_TO} - 2 )) count=1 2>/dev/null; } > \$b
      dd if=\$b of=/dev/mmcblk0p1 bs=512 count=1 2>/dev/null; sync; rm -f \$b
      dd if=/dev/mmcblk0p1 bs=512 count=1 2>/dev/null | tr -d '\000' | head -n 1
      # With the open bootloader: count the boots of the new slot, so that a
      # kernel that never starts is left after k1_bootlimit of them. Says
      # nothing with the stock bootloader, on stock, or on an older Datel OS.
      command -v k1os-slot >/dev/null 2>&1 && k1os-slot arm 2>/dev/null || true"
    echo "== marker points at slot $SLOT. Reboot the printer to try it." ;;
*)
    die "unknown option $MODE" ;;
esac
