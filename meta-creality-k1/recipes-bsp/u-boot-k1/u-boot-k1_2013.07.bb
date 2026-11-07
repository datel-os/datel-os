SUMMARY = "Open bootloader for the Creality K1: Ingenic X2000 SPL + U-Boot 2013.07"
DESCRIPTION = "Ingenic's U-Boot 2013.07 tree for the X2000 (the same tree Creality built the \
stock K1 bootloader from), with a Creality K1 board: eMMC on MSC0, the K1 partition \
table, the stock RTOS splash hand-off in the SPL, and a U-Boot stage that picks the \
A/B slot from the ota marker with a boot counter in the environment (k1slot). \
Built for study and for RAM boot over USB; see docs/BOOTLOADER.md before writing it to the eMMC."
HOMEPAGE = "https://github.com/NebulaOS-KE/NebulaOS-kernel"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=1707d6db1d42237583f50183a5651ecb"

# Ingenic's SDK as NebulaOS publishes it for the Ender-3 V3 KE, directory
# u-boot/; that directory has not changed since the repository's first commit.
# (Datel OS's kernel came from the same tree up to 0.5.1; it is now
# zales/k1-linux, which has no bootloader.)
SRC_URI = "git://github.com/NebulaOS-KE/NebulaOS-kernel.git;protocol=https;branch=openke;subpath=u-boot \
           file://creality_k1.h \
           file://boards-creality_k1.cfg \
           file://board/ \
           file://0001-spl-jzsdhci-creality-k1-rtos-slot-and-lcm-id.patch \
           file://0002-main-fall-back-to-the-built-in-bootcmd.patch \
          "
SRCREV = "d86790d2e23178e52054c71562f9c40994a5469b"
PV = "2013.07+git${SRCPV}"
S = "${WORKDIR}/u-boot"
B = "${S}"

COMPATIBLE_MACHINE = "creality-k1"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit deploy

# creality_k1     the eMMC bootloader: SPL (sector 34) + U-Boot (sector 82)
# creality_k1_usb the same SPL built to return to the boot ROM after the DDR
#                 init, for "usbboot --stage1" (the ROM then takes U-Boot as
#                 stage 2 over USB). Its U-Boot binary is identical.
UBOOT_K1_CONFIGS ?= "creality_k1 creality_k1_usb"

# The 2013 build system takes the toolchain from CROSS_COMPILE and builds its
# host tools (mkimage, gpt_creator, spl_params_fixer, ddr_params_creator) with
# HOSTCC. CC needs the sysroot so that -print-libgcc-file-name finds libgcc
# for the SPL link. It sets its own CFLAGS, so the environment ones do not
# leak in (LDFLAGS would, see do_compile).
EXTRA_OEMAKE = 'CROSS_COMPILE=${TARGET_PREFIX} CC="${TARGET_PREFIX}gcc ${TOOLCHAIN_OPTIONS}" \
                HOSTCC="${BUILD_CC} ${BUILD_CFLAGS} ${BUILD_LDFLAGS}" HOSTSTRIP=true'

do_configure() {
    install -m 0644 ${WORKDIR}/creality_k1.h ${S}/include/configs/creality_k1.h
    rm -rf ${S}/board/ingenic/creality_k1
    install -d ${S}/board/ingenic/creality_k1
    install -m 0644 ${WORKDIR}/board/* ${S}/board/ingenic/creality_k1/
    grep -q '^creality_k1[[:space:]]' ${S}/boards.cfg || cat ${WORKDIR}/boards-creality_k1.cfg >> ${S}/boards.cfg
    # The tree knows compilers up to GCC 12 (include/linux/compiler-gccN.h);
    # newer ones need the same header, or even autoconf.mk comes out empty.
    for v in 13 14 15 16; do
        [ -f ${S}/include/linux/compiler-gcc$v.h ] || cp ${S}/include/linux/compiler-gcc12.h ${S}/include/linux/compiler-gcc$v.h
    done
}

# "make <board>_config" must run alone: the generated include/config.h gets
# garbled when it races with a parallel make. The exported LDFLAGS (-Wl,-O1,
# --hash-style, ...) must not reach this tree: it appends them to plain ld
# calls, which reject gcc-style options.
do_compile() {
    unset LDFLAGS CFLAGS CPPFLAGS ASFLAGS
    rm -rf ${WORKDIR}/build-out
    for cfg in ${UBOOT_K1_CONFIGS}; do
        oe_runmake distclean
        oe_runmake -j1 ${cfg}_config
        oe_runmake
        install -d ${WORKDIR}/build-out/${cfg}
        install -m 0644 ${B}/spl/u-boot-spl.bin ${B}/u-boot.bin ${B}/u-boot-with-spl.bin \
            ${B}/u-boot-with-spl-mbr-gpt.bin ${WORKDIR}/build-out/${cfg}/
        # Sizes the eMMC layout relies on: SPL < 24 KiB pad, U-Boot < 384 KiB (env at 384 KiB).
        spl=$(stat -c %s ${B}/spl/u-boot-spl.bin); ub=$(stat -c %s ${B}/u-boot.bin)
        [ "$spl" -le 24576 ] || bbfatal "SPL is $spl bytes, more than the 24 KiB slot"
        [ "$ub" -le 393216 ] || bbfatal "u-boot.bin is $ub bytes, would overlap the environment at 384 KiB"
    done
}

do_install() {
    :
}

# Deployed files (DEPLOY_DIR_IMAGE):
#   u-boot-k1-spl.bin          SPL as it sits at eMMC sector 34 (MSPL header + params + code)
#   u-boot-k1.bin              U-Boot proper, eMMC sector 82 / usbboot stage 2
#   u-boot-k1-with-spl.bin     SPL padded to 24 KiB + U-Boot: bytes 0x4400.. of the eMMC
#   u-boot-k1-sector0.bin      first 512 bytes: boot ROM params + protective MBR
#   u-boot-k1-mbr-gpt.bin      the whole first MiB as the SDK lays it out (reference only,
#                              its GPT has new GUIDs; never write it over a stock eMMC)
#   u-boot-k1-usb-stage1.bin   SPL that returns to the boot ROM: usbboot --stage1
do_deploy() {
    o=${WORKDIR}/build-out
    install -d ${DEPLOYDIR}
    install -m 0644 $o/creality_k1/u-boot-spl.bin ${DEPLOYDIR}/u-boot-k1-spl.bin
    install -m 0644 $o/creality_k1/u-boot.bin ${DEPLOYDIR}/u-boot-k1.bin
    install -m 0644 $o/creality_k1/u-boot-with-spl.bin ${DEPLOYDIR}/u-boot-k1-with-spl.bin
    install -m 0644 $o/creality_k1/u-boot-with-spl-mbr-gpt.bin ${DEPLOYDIR}/u-boot-k1-mbr-gpt.bin
    dd if=$o/creality_k1/u-boot-with-spl-mbr-gpt.bin of=${DEPLOYDIR}/u-boot-k1-sector0.bin bs=512 count=1 2>/dev/null
    if [ -f $o/creality_k1_usb/u-boot-spl.bin ]; then
        install -m 0644 $o/creality_k1_usb/u-boot-spl.bin ${DEPLOYDIR}/u-boot-k1-usb-stage1.bin
    fi
}
addtask deploy after do_compile before do_build

# Nothing goes into the root filesystem from here; fw_env.config and the
# k1os-slot integration live in k1os-base.
PACKAGES = ""
