SUMMARY = "Mainsail web interface for Klipper"
DESCRIPTION = "Release build of Mainsail v${PV}, served by nginx with the Moonraker API \
proxied on the same port. Its WebRTC camera player gets methods that close what \
they opened once the view is gone (webrtc-player.js)."
HOMEPAGE = "https://github.com/mainsail-crew/mainsail"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-3.0-only;md5=c79ff39f19dfec6d293b95dea7b07891"

SRC_URI = "https://github.com/mainsail-crew/mainsail/releases/download/v${PV}/mainsail.zip;subdir=mainsail-dist \
           file://mainsail.nginx \
           file://webrtc-player.js \
           file://patch-webrtc-player.py \
          "
SRC_URI[sha256sum] = "c4d9d96f89851c6ae0709c2f20725447f3fe8c57cf193869b0083441bd93378a"

S = "${WORKDIR}/mainsail-dist"

inherit allarch

do_install() {
    install -d ${D}${datadir}/mainsail
    cp -R --no-preserve=ownership ${S}/. ${D}${datadir}/mainsail/
    # the WebRTC player must not leave connections open behind it; the
    # script stops the build if this is not the release it was written for
    python3 ${WORKDIR}/patch-webrtc-player.py ${D}${datadir}/mainsail ${WORKDIR}/webrtc-player.js
    install -d ${D}${sysconfdir}/nginx/sites-enabled
    install -m 0644 ${WORKDIR}/mainsail.nginx ${D}${sysconfdir}/nginx/sites-enabled/mainsail
}

FILES:${PN} += "${datadir}/mainsail"
RDEPENDS:${PN} += "nginx moonraker"
