SUMMARY = "zklippy: Kalico's Klipper host as one Zig binary"
DESCRIPTION = "A port of Kalico's host (klippy and its C helpers) to Zig, module by \
module, with the same G-code, the same messages to the MCUs and the same Moonraker \
API. One binary in place of Python and klippy: less CPU and memory per printed move \
on the K1. klipper.service runs it unless /usr/data/k1os/klipper-host says kalico \
(k1os-klipper-host switches); Kalico stays installed as the way back."
HOMEPAGE = "https://github.com/zales/k1-zklippy"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=1ebbd3e34237af26da5dc08a4e440464"

# A private repository: the build fetches it over SSH with the agent of whoever
# runs build.sh (it forwards the agent into the build container), with
# GitHub's host keys pinned in files/github_known_hosts.
SRC_URI = "git://git@github.com/zales/k1-zklippy.git;protocol=ssh;branch=main \
           file://klipper-host \
           file://k1os-klipper-host \
           file://10-zklippy.conf"
SRCREV = "680aea604e4fcb0f10ceb453873d01b2a87abddf"
PV = "0.1+git${SRCPV}"
S = "${WORKDIR}/git"

GIT_SSH_COMMAND = "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile=${CREALITY_K1_LAYERDIR}/recipes-printer/zklippy/files/github_known_hosts"

DEPENDS = "zig-native"

do_configure[noexec] = "1"

# Zig builds for the K1's ABI (mipsel, MIPS32r2, 64-bit FPU, NaN 2008, no fused
# madd4) against glibc 2.39, the image's, from its own glibc stubs: build.zig's
# -Dk1 target. ReleaseFast is what the printer tests ran.
do_compile() {
    export ZIG_GLOBAL_CACHE_DIR=${WORKDIR}/zig-global-cache
    export ZIG_LOCAL_CACHE_DIR=${WORKDIR}/zig-local-cache
    cd ${S}
    zig build -Dk1=true -Doptimize=ReleaseFast \
        -Dversion=zklippy-g${@d.getVar('SRCREV')[:8]} --prefix ${B}/out
}

# The binary goes next to Kalico's tree: zklippy reports the directory it runs
# from as klipper_path, and Moonraker finds Klipper's docs and its protected
# directory there, as with Kalico.
do_install() {
    install -d ${D}${datadir}/klipper ${D}${bindir} ${D}${libexecdir}/k1os \
        ${D}${systemd_system_unitdir}/klipper.service.d
    install -m 0755 ${B}/out/bin/zklippy ${D}${datadir}/klipper/zklippy
    ln -s ../share/klipper/zklippy ${D}${bindir}/zklippy
    install -m 0755 ${WORKDIR}/klipper-host ${D}${libexecdir}/k1os/klipper-host
    install -m 0755 ${WORKDIR}/k1os-klipper-host ${D}${bindir}/k1os-klipper-host
    install -m 0644 ${WORKDIR}/10-zklippy.conf ${D}${systemd_system_unitdir}/klipper.service.d/
}

FILES:${PN} += "${datadir}/klipper/zklippy ${libexecdir}/k1os ${systemd_system_unitdir}/klipper.service.d"
# Zig links by itself and takes no LDFLAGS: the binary has the classic symbol
# hash table, not GNU_HASH, which glibc reads as well. Zig has no prefix map
# for its debug information, so zklippy-dbg (not in the image) names the build
# directory.
INSANE_SKIP:${PN} += "ldflags"
INSANE_SKIP:${PN}-dbg += "buildpaths"

# klipper.service, Kalico as the way back, and the configuration it converts
RDEPENDS:${PN} += "kalico"
