SUMMARY = "The X2000 Helix video codec for programs, and the timelapse's encoder"
DESCRIPTION = "The Helix is the SoC's hardware H.264 and JPEG encoder and JPEG decoder. The \
kernel gives programs its power, interrupt and memory (/dev/helix, k1os-helix.c in \
linux-x2000); everything that reads a picture or tells the codec what to do is here, in \
Zig: the JPEG header parser, the H.264 parameter sets and slice headers, and the chains \
of register writes that are the codec's jobs. k1os-camera builds the same code in for \
the camera stream. k1os-helix-enc turns JPEG snapshots into an H.264 stream; \
timelapse-render is the ffmpeg stand-in moonraker-timelapse calls, which runs it and lets \
h264-to-mp4 (recipe k1os-camera) wrap the stream into MP4. k1os-helix-test tries the codec \
and the kernel's driver on a printer. No picture is decoded or encoded on the CPU."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://helix.zig file://helix_jpeg.zig file://helix_h264.zig file://helix_cabac.zig \
           file://helix_codec.zig file://helix_c.zig file://helix_codec.h \
           file://helix_enc.zig file://helix_test.zig \
           file://testdata/frame-header.jpg file://testdata/frame-header.tables \
           file://testdata/h264-frames.vendor \
           file://k1os-timelapse-render"
S = "${WORKDIR}"

DEPENDS = "zig-native"

do_configure[noexec] = "1"

# Zig compiles for the K1's ABI and statically against its own musl, as for
# k1os-camera. The tests run first, on the build host: the parser against
# damaged pictures, and the chains, headers and tables against what the
# vendor's driver produced for the same input (testdata/).
do_compile() {
    export ZIG_GLOBAL_CACHE_DIR=${WORKDIR}/zig-global-cache
    export ZIG_LOCAL_CACHE_DIR=${WORKDIR}/zig-local-cache
    cd ${S}
    zig test helix_codec.zig -target ${BUILD_ARCH}-linux-musl -lc
    for program in helix_enc:k1os-helix-enc helix_test:k1os-helix-test; do
        zig build-exe ${program%:*}.zig -target mipsel-linux-musleabihf -mcpu=mips32r2+fp64+nan2008 \
            -lc -O ReleaseSafe -fstrip -femit-bin=${B}/${program#*:}
    done
}

do_install() {
    install -d ${D}${bindir} ${D}${libexecdir}/k1os
    install -m 0755 ${B}/k1os-helix-enc ${B}/k1os-helix-test ${D}${bindir}/
    install -m 0755 ${WORKDIR}/k1os-timelapse-render ${D}${libexecdir}/k1os/timelapse-render
}

FILES:${PN} += "${libexecdir}/k1os"
# h264-to-mp4
RDEPENDS:${PN} += "k1os-camera"
# static, and stripped by Zig
INSANE_SKIP:${PN} += "already-stripped"
