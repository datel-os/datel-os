SUMMARY = "Linux 6.18 for the Creality K1 (Ingenic X2000)"
DESCRIPTION = "kernel.org's stable Linux 6.18 with what the K1's board needs, from \
datel-os/k1-linux: the X2000 as a SoC of upstream's Ingenic platform, drivers for its \
clocks, interrupt controller, timer and second CPU, upstream's drivers with the X2000 \
added for its other devices, the board's device tree, and the driver for the Helix \
codec (/dev/helix)."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

inherit kernel

# main of datel-os/k1-linux. Everything reaches that branch through pull requests,
# and each of them says what it was checked with on the printer; the commit
# here is the one of pull request 33, with which a watchdog that the boot
# loader started survives the kernel's start (docs/BOOTLOADER.md). Below it are
# pull request 31 (an oops is a panic, no uevent helper), pull request 30,
# which sets the CPU to 912 MHz, the X2000 on upstream's Ingenic platform
# (pull requests 26 to 28) and the README of pull request 29.
SRC_URI = "git://github.com/datel-os/k1-linux.git;protocol=https;branch=main"
SRCREV = "839963f38632dac67e6c4af061ae324f4bfe1744"
S = "${WORKDIR}/git"

LINUX_VERSION = "6.18.63"
PV = "${LINUX_VERSION}+git${SRCPV}"

COMPATIBLE_MACHINE = "creality-k1"

# The configuration is the tree's own k1_defconfig. It builds the board's
# device tree into the kernel, and that device tree sets the CPU to 912 MHz
# (the boot loader's 1200 MHz gives wrong floating point results on the K1).
# It has the Helix driver, runtime power management and what systemd and the
# image's services need; the check below names what the image depends on.
#
# One thing is added here. cfg80211 is built in and loads regulatory.db one
# second into the boot, long before the root filesystem is mounted; the copy
# in /lib/firmware comes too late. Built into the kernel, the database is
# there in time. It comes from wireless-regdb, the same files the image
# installs, which is why the defconfig cannot name them.
#
# The two files are copied into the source tree and named by a path relative
# to it. An absolute path would be one into this build's sysroot, and it would
# go into the configuration that is packaged as /boot/config.
DEPENDS += "wireless-regdb"
REGDB_DIR = "${STAGING_DIR_HOST}${nonarch_base_libdir}/firmware"

do_configure:prepend() {
    [ -f ${REGDB_DIR}/regulatory.db ] && [ -f ${REGDB_DIR}/regulatory.db.p7s ] || bbfatal "regulatory.db is missing in ${REGDB_DIR}"
    install -d ${S}/k1os-firmware
    install -m 0644 ${REGDB_DIR}/regulatory.db ${REGDB_DIR}/regulatory.db.p7s ${S}/k1os-firmware/
    cp ${S}/arch/mips/configs/k1_defconfig ${WORKDIR}/defconfig
    printf '%s\n' 'CONFIG_EXTRA_FIRMWARE="regulatory.db regulatory.db.p7s"' \
        'CONFIG_EXTRA_FIRMWARE_DIR="k1os-firmware"' >> ${WORKDIR}/defconfig
    rm -f ${B}/.config
}

# Fail the build if something the image depends on is not in the configuration:
# the board and its built-in device tree, the root filesystem's
# format, Wi-Fi as a module (its firmware is in the root filesystem), the
# built-in regulatory database, the camera, /dev/helix, zram swap and the
# multi-gen LRU (k1os-base), per-thread scheduling statistics (k1os-trace),
# the GPIO and I2C character devices (OpenOCD, Klipper's host MCU), the kernel
# log kept over a restart, runtime power management (without it the USB
# controller interrupts 8000 times a second at idle), and the hardware
# watchdog with a pre-timeout that panics (systemd sets the pre-timeout, and
# reads the governor from sysfs before it does: k1os-base).
do_configure:append() {
    for opt in CONFIG_MACH_INGENIC_SOC=y CONFIG_X2000_CREALITY_K1=y CONFIG_BUILTIN_DTB=y \
               CONFIG_SQUASHFS_XZ=y CONFIG_BRCMFMAC=m \
               'CONFIG_EXTRA_FIRMWARE="regulatory.db regulatory.db.p7s"' 'CONFIG_EXTRA_FIRMWARE_DIR="k1os-firmware"' \
               CONFIG_USB_VIDEO_CLASS=y CONFIG_K1OS_HELIX=y \
               CONFIG_ZRAM=y CONFIG_LRU_GEN=y CONFIG_LRU_GEN_ENABLED=y CONFIG_SCHEDSTATS=y \
               CONFIG_GPIO_CDEV=y CONFIG_I2C_CHARDEV=y CONFIG_PSTORE_RAM=y CONFIG_PM=y \
               CONFIG_JZ4740_WDT=y CONFIG_WATCHDOG_SYSFS=y CONFIG_WATCHDOG_PRETIMEOUT_DEFAULT_GOV_PANIC=y; do
        grep -qx "$opt" ${B}/.config || bbfatal "kernel config is missing $opt"
    done
    # The CPU's clock was an option of the SDK's clock driver. With upstream's
    # framework the board's device tree assigns it, so that is what is checked.
    grep -q 'assigned-clock-rates = <912000000>;' ${S}/arch/mips/boot/dts/ingenic/creality-k1.dts || \
        bbfatal "the board's device tree does not set the CPU to 912 MHz"
}

# The stock boot loader takes a legacy U-Boot image of a kernel that unpacks
# itself. This tree's make target for it is uzImage.bin; the machine, the OTA
# image type and the tools call the file xImage, as the SDK kernel did.
# kernel.bbclass makes KERNEL_IMAGETYPE_FOR_MAKE and installs and deploys
# arch/mips/boot/${KERNEL_IMAGETYPE}.
KERNEL_IMAGETYPE_FOR_MAKE = "uzImage.bin"
DEPENDS += "u-boot-tools-native"
do_compile:append() {
    cp ${B}/arch/mips/boot/uzImage.bin ${B}/arch/mips/boot/xImage
}
