#!/bin/sh
# Test of k1os-slot against files in place of the eMMC:
#   sh k1os-slot-test.sh <path to k1os-slot>
# The recipe runs it on the build host (do_compile).
set -u
SLOT=${1:?usage: k1os-slot-test.sh <k1os-slot>}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export K1OS_SLOT_MARKER=$T/p1 K1OS_SLOT_KEEP=$T/boot-keep K1OS_SLOT_CMDLINE=$T/cmdline \
    K1OS_SLOT_PART=$T/p K1OS_SLOT_RUN=$T
# No open bootloader unless a test puts one there (uboot below): the build
# host's own fw_printenv, if it has one, is never asked.
export K1OS_SLOT_FW_PRINTENV=$T/fw_printenv K1OS_SLOT_FW_SETENV=$T/fw_setenv
fails=0

marker() { dd if="$T/p1" bs=512 count=1 2>/dev/null | tr -d '\000' | head -n 1; }
# The block is written to the file itself: through a pipe, dd's one read of 512
# bytes may return only the text and leave a marker of 13 bytes.
set_marker() { { printf '%s\n\n' "$1"; dd if=/dev/zero bs=$((510 - ${#1})) count=1 2>/dev/null; } > "$T/p1"; }
boot() { echo "console=ttyS2 root=/dev/mmcblk0p$1 rootwait ro" > "$T/cmdline"; }
system() { for p in "$@"; do { printf 'hsqs'; dd if=/dev/zero bs=8188 count=1 2>/dev/null; } > "$T/p$p"; done; }
empty() { for p in "$@"; do dd if=/dev/zero of="$T/p$p" bs=8192 count=1 2>/dev/null; done; }
run() { ${K1OS_SLOT_SH:-sh} "$SLOT" "$@" >"$T/out" 2>&1; }
is() {  # $1 what, $2 got, $3 want
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}
fresh() { rm -f "$T/boot-keep"; system 5 6 7 8; }
# The open bootloader's environment as a file of name=value lines, with the
# two tools that read and write it; a file that is not there is the bad CRC
# of the stock bootloader's empty area.
uboot() {
    cat > "$T/fw_printenv" <<EOT
#!/bin/sh
[ -f "$T/fwenv" ] || { echo "Cannot read environment, using default" >&2; exit 1; }
[ "\$1" = -n ] && shift
v=\$(sed -n "s/^\$1=//p" "$T/fwenv")
[ -n "\$v" ] || exit 1
echo "\$v"
EOT
    cat > "$T/fw_setenv" <<EOT
#!/bin/sh
[ -f "$T/fwenv" ] || exit 1
echo setenv >> "$T/fwwrites"
grep -v "^\$1=" "$T/fwenv" > "$T/fwenv.new"; echo "\$1=\$2" >> "$T/fwenv.new"; mv "$T/fwenv.new" "$T/fwenv"
EOT
    chmod +x "$T/fw_printenv" "$T/fw_setenv"
    printf '%s\n' k1_env_saved=1 k1_bootlimit=3 "$@" > "$T/fwenv"
    : > "$T/fwwrites"
}
no_uboot() { rm -f "$T/fw_printenv" "$T/fw_setenv" "$T/fwenv" "$T/fwwrites"; }
fwvar() { sed -n "s/^$1=//p" "$T/fwenv"; }

# a new system in slot 2, written from slot 1: a trial until it is kept
fresh; boot 8; set_marker ota:kernel2
run trial;   is "trial points at the other slot" "$(marker)" ota:kernel
run confirm; is "no boot-keep: stays a trial" "$(marker)" ota:kernel
run keep;    is "keep points at this slot" "$(marker)" ota:kernel2
is "keep names this slot" "$(cat "$T/boot-keep")" ota:kernel2
run trial; run confirm; is "a kept slot comes back to itself" "$(marker)" ota:kernel2
run status;  is "status of a kept slot" "$(grep '^keep:' "$T/out")" "keep:    yes"

# the next system, in slot 1, does not inherit that keep
boot 7; set_marker ota:kernel
run trial;   is "new system: trial points back" "$(marker)" ota:kernel2
run confirm; is "new system: the other slot's keep is not its own" "$(marker)" ota:kernel2
run status;  is "status says whose keep it is" "$(grep '^keep:' "$T/out")" "keep:    no (trial; boot-keep names ota:kernel2)"
# ... and the kept system is still kept when the power cycle brings it back
boot 8
run trial; run confirm; is "the kept system still confirms itself" "$(marker)" ota:kernel2

# a boot-keep without a name (Datel OS up to 0.8.1) keeps nothing here
fresh; : > "$T/boot-keep"; boot 7; set_marker ota:kernel
run trial; run confirm; is "boot-keep without a name: a trial" "$(marker)" ota:kernel2
run status; is "status of a nameless boot-keep" "$(grep '^keep:' "$T/out")" "keep:    no (trial; boot-keep names no slot)"
printf 'junk\n' > "$T/boot-keep"
run confirm; is "boot-keep with another text: a trial" "$(marker)" ota:kernel2

# release
fresh; boot 8; set_marker ota:kernel2; run keep
run release; is "release points at the other slot" "$(marker)" ota:kernel
is "release removes boot-keep" "$(ls "$T/boot-keep" 2>/dev/null)" ""

# the other slot is being written (or a write broke off): never the next boot
for part in 5 7; do
    fresh; boot 8; set_marker ota:kernel2; run keep; empty $part
    run trial; rc=$?
    is "p$part empty: trial leaves the marker" "$(marker)" ota:kernel2
    is "p$part empty: trial is no failure" "$rc" 0
    run release; rc=$?
    is "p$part empty: release refuses" "$rc $(marker) $(cat "$T/boot-keep")" "1 ota:kernel2 ota:kernel2"
    run status; is "p$part empty: status says so" "$(grep -c '^other:' "$T/out")" 1
done
fresh; boot 7; set_marker ota:kernel; empty 6
run trial; is "slot 2 empty, running slot 1: marker stays" "$(marker)" ota:kernel
# a partition that is not there counts as a system, as before the check
fresh; boot 8; set_marker ota:kernel2; rm -f "$T/p5"
run trial; is "unreadable partition: trial as before" "$(marker)" ota:kernel

# an unknown root never reaches the marker
for cmd in trial confirm keep release; do
    fresh; echo "console=ttyS2 root=PARTUUID=1234 ro" > "$T/cmdline"; set_marker ota:kernel2
    echo ota:kernel2 > "$T/boot-keep"
    run $cmd; is "unknown root: $cmd leaves the marker" "$(marker)" ota:kernel2
done
before=$(md5sum < "$T/p1")
is "the marker block is 512 bytes, text, two newlines, zeros" \
    "$(wc -c < "$T/p1" | tr -d ' ') $(dd if="$T/p1" bs=1 skip=11 count=2 2>/dev/null | od -An -tx1 | tr -d ' ')" "512 0a0a"
is "p1 untouched by the unknown root" "$(md5sum < "$T/p1")" "$before"

# the stock bootloader: no counter, and nothing here fails for it
no_uboot; fresh; boot 8; set_marker ota:kernel2
run confirm; is "stock bootloader: confirm is no failure" "$?" 0
run status;  is "stock bootloader: status says so" "$(grep '^u-boot:' "$T/out")" "u-boot:  stock (no environment)"
run arm;     is "stock bootloader: nothing to arm" "$?" 1

# the open bootloader with a tool but an area it never saved (bad CRC)
uboot; rm -f "$T/fwenv"
run status;  is "unsaved environment reads as stock" "$(grep '^u-boot:' "$T/out")" "u-boot:  stock (no environment)"
run arm;     is "unsaved environment: nothing to arm" "$?" 1

# the open bootloader: arm starts a count, a system that starts ends it
uboot k1_trial=0 k1_bootcount=2; fresh; boot 7; set_marker ota:kernel2
run arm;     is "arm starts the count from zero" "$? $(fwvar k1_trial) $(fwvar k1_bootcount)" "0 1 0"
is "arm leaves the marker" "$(marker)" ota:kernel2
run status;  is "status shows the count" "$(grep '^u-boot:' "$T/out")" "u-boot:  open, trial=1 bootcount=0/3"
# the new system's first boot, counted once by the bootloader
uboot k1_trial=1 k1_bootcount=1; boot 8
run trial; run confirm
is "a trial boot that started ends the count" "$(fwvar k1_trial) $(fwvar k1_bootcount)" "0 0"
is "... and is still a trial by the marker" "$(marker)" ota:kernel
: > "$T/fwwrites"; run confirm
is "nothing set: confirm does not write the environment" "$(wc -l < "$T/fwwrites" | tr -d ' ')" 0
uboot k1_trial=1 k1_bootcount=2; fresh; boot 8; set_marker ota:kernel2
run keep;    is "keep ends the count too" "$(marker) $(fwvar k1_trial) $(fwvar k1_bootcount)" "ota:kernel2 0 0"
# a count left without a trial
uboot k1_trial=0 k1_bootcount=3
run confirm; is "a stale count is cleared" "$(fwvar k1_bootcount)" 0
no_uboot

[ "$fails" = 0 ] && echo "k1os-slot: all tests passed" || echo "k1os-slot: $fails FAILED"
[ "$fails" = 0 ]
