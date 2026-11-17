SUMMARY = "Kalico (Klipper fork) host software, pellcorp's K1 branch"
DESCRIPTION = "Kalico with pellcorp's K1 series additions: the load cell probe for the \
bed strain gauges (hx711s), the Creality MCU bootloader entry and MIPS fixes. Pairs \
with the MCU firmware from k1-mcu-firmware built from the same release branch."
HOMEPAGE = "https://github.com/pellcorp/kalico"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=1ebbd3e34237af26da5dc08a4e440464"

SRC_URI = "git://github.com/pellcorp/kalico.git;protocol=https;branch=nov2026 \
           file://klipper.service \
           file://k1os_kalico.cfg \
           file://k1os-kalico-config \
           file://k1os-kalico-config.service \
           file://0001-plan-4-s-and-send-steps-3-s-ahead.patch \
           file://0002-load_cell-measure-only-while-the-samples-are-used.patch \
           file://0003-serialhdl-discard-what-arrived-before-the-session.patch"
SRCREV = "7095e20918e5290c6aa754dbc9d6513c8959db14"
PV = "nov2026+git${SRCPV}"
S = "${WORKDIR}/git"

inherit python3native systemd

# Two packages. kalico-common is what any Klipper host on the K1 needs and
# what the image installs: Klipper's example configs and docs (Moonraker
# serves both from klipper_path), the conversion of the stock configuration
# (k1os-kalico-config, k1os_kalico.cfg) and the MCU firmware. kalico is
# Kalico's own Python host with its klipper.service; zklippy replaces it in
# the image.
PACKAGES =+ "${PN}-common"
SYSTEMD_PACKAGES = "${PN} ${PN}-common"
SYSTEMD_SERVICE:${PN} = "klipper.service"
SYSTEMD_SERVICE:${PN}-common = "k1os-kalico-config.service"

KLIPPER_DIR = "${datadir}/klipper"

# No Linux host MCU (klipper_mcu) is built. On the stock K1 only [mcu rpi]
# used one, for Creality's EEPROM module [bl24c16f], and k1os-kalico-config
# removes both. Started anyway, nobody read its pseudo-tty: its stats report
# every 5 s filled the tty's buffers about 2 h after boot, and from then on
# each report was a refused write and a line in the journal.
do_configure() {
    rm -f ${S}/klippy/chelper/c_helper.so
}

do_compile() {
    cd ${S}/klippy/chelper
    srcs=$(python3 -c 'import re;print(" ".join(re.findall(r"[\x27\"]([A-Za-z0-9_]+\.c)[\x27\"]", re.search(r"SOURCE_FILES = \[(.*?)\]",open("__init__.py").read(),re.S).group(1))))')
    ${CC} ${CFLAGS} ${LDFLAGS} -Wall -O2 -shared -fPIC -flto -fwhole-program -fno-use-linker-plugin \
        -o c_helper.so $srcs
}

do_install() {
    install -d ${D}${KLIPPER_DIR}
    cp -R --no-preserve=ownership ${S}/klippy ${D}${KLIPPER_DIR}/
    cp -R --no-preserve=ownership ${S}/config ${D}${KLIPPER_DIR}/
    # Moonraker serves <klipper>/docs and warns when the directory is missing;
    # the text alone (the images are 20 MB)
    install -d ${D}${KLIPPER_DIR}/docs
    install -m 0644 ${S}/docs/*.md ${D}${KLIPPER_DIR}/docs/
    install -m 0644 ${S}/klippy/chelper/c_helper.so ${D}${KLIPPER_DIR}/klippy/chelper/c_helper.so
    find ${D}${KLIPPER_DIR} -name '*.o' -delete
    python3 -m compileall -q -j 0 -s ${D} -p / ${D}${KLIPPER_DIR}/klippy || true
    # Without a git checkout Klipper reads its version from .version
    echo "kalico-nov2026-g${@d.getVar('SRCREV')[:8]}" > ${D}${KLIPPER_DIR}/klippy/.version

    install -d ${D}${systemd_system_unitdir} ${D}${libexecdir}/k1os ${D}${sysconfdir}/k1os
    install -m 0644 ${WORKDIR}/klipper.service ${WORKDIR}/k1os-kalico-config.service ${D}${systemd_system_unitdir}/
    install -m 0755 ${WORKDIR}/k1os-kalico-config ${D}${libexecdir}/k1os/kalico-config
    install -m 0644 ${WORKDIR}/k1os_kalico.cfg ${D}${sysconfdir}/k1os/k1os_kalico.cfg
}

FILES:${PN}-common = "${KLIPPER_DIR}/config ${KLIPPER_DIR}/docs \
    ${libexecdir}/k1os ${sysconfdir}/k1os ${systemd_system_unitdir}/k1os-kalico-config.service"
FILES:${PN} += "${KLIPPER_DIR}/klippy ${systemd_system_unitdir}/klipper.service"

RDEPENDS:${PN}-common = "k1os-base python3-core python3-shell k1-mcu-firmware"
RDEPENDS:${PN} += " \
    ${PN}-common \
    python3-modules \
    python3-cffi \
    python3-greenlet \
    python3-jinja2 \
    python3-markupsafe \
    python3-pyserial \
    python3-numpy \
"
# zklippy brings its own klipper.service
RCONFLICTS:${PN} = "zklippy"
