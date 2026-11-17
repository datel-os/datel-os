SUMMARY = "Datel OS: open-source firmware image for the Creality K1"
LICENSE = "MIT"

inherit core-image extrausers

IMAGE_FEATURES += "read-only-rootfs ssh-server-openssh"

# Root keeps the stock firmware's password (the hash is copied from /etc/shadow of
# the stock rootfs on mmcblk0p7; Creality publishes the password in its rooting guide),
# so one password opens both slots. The root is read-only: passwd cannot change it
# on the printer, only here. The hash goes through a double-quoted shell string in
# extrausers.bbclass, so every $ is escaped or the shell eats $5, $do2Fx5 and $8.
EXTRA_USERS_PARAMS = "usermod -p '\$5\$do2Fx5.o9ndk\$8EchNjZMu2F.uTPtRnsr8QiZOFfS488o7dz9cjsMO66' root;"

IMAGE_INSTALL = " \
    packagegroup-core-boot \
    kernel-modules \
    linux-firmware-bcm43430 k1-wifi-nvram wireless-regdb-static \
    wpa-supplicant iw \
    e2fsprogs-e2fsck \
    mtd-utils \
    python3 python3-pyserial \
    k1os-base datel-branding \
"

# Printing stack: Kalico (pellcorp's tree with the K1 load cell probe) with our
# own firmware for the three MCUs, Moonraker, Mainsail on nginx and Guppy
# Screen on the touch display.
IMAGE_INSTALL += "kalico moonraker mainsail guppyscreen nginx"
# The Klipper host klipper.service runs: zklippy, Kalico's host ported to one
# Zig binary; Kalico stays as the way back (k1os-klipper-host kalico).
IMAGE_INSTALL += "zklippy"
# Camera: MJPEG and snapshots, H.264 over WebRTC, the Twitch stream; one daemon.
IMAGE_INSTALL += "k1os-camera"
# Flight recorder: what the system did in the minutes before Klipper stopped.
IMAGE_INSTALL += "k1os-trace"
# Timelapse: moonraker-timelapse with the render step on the X2000 Helix codec
# (k1os-helix; k1os-camera's h264-to-mp4 writes the MP4 file).
IMAGE_INSTALL += "moonraker-timelapse k1os-helix"
# Twitch live stream with a status overlay: its service and Mainsail controls
# (k1os-camera encodes and sends it).
IMAGE_INSTALL += "k1os-stream"
# For a look at the running printer over SSH: what each process and thread
# takes of the two CPUs and of the memory.
IMAGE_INSTALL += "htop"

IMAGE_ROOTFS_EXTRA_SPACE = "0"

# The stock bootloader passes init=/linuxrc on the kernel command line.
# (The names in ROOTFS_POSTPROCESS_COMMAND stand without a semicolon: with one
# the command still runs, but its text is no longer part of do_rootfs's
# signature and a change to it would not make the image anew.)
k1os_linuxrc() {
    ln -sf /sbin/init ${IMAGE_ROOTFS}/linuxrc
}
ROOTFS_POSTPROCESS_COMMAND += "k1os_linuxrc"

# /etc/os-release names the day the image was made (BUILD_ID). The os-release
# package cannot carry it: a date among its fields is part of its task's
# signature, and bitbake ends a build with "the metadata is not deterministic"
# when it parsed the recipe on one day and looks at it again on another. So
# the day is written here, when the root file system is put together, and
# DATE is kept out of this task's signature: the image is made anew when
# something in it changes, not when the day does.
k1os_build_id() {
    sed -i '/^BUILD_ID=/d' ${IMAGE_ROOTFS}${nonarch_libdir}/os-release
    echo 'BUILD_ID="${DATE}"' >> ${IMAGE_ROOTFS}${nonarch_libdir}/os-release
}
k1os_build_id[vardepsexclude] = "DATE"
ROOTFS_POSTPROCESS_COMMAND += "k1os_build_id"
