# Datel OS: which access point of a network the printer takes. wpa_supplicant
# put an 802.11n access point at -70 dBm before an 802.11g one at -30 dBm,
# for a throughput estimate 2 % higher; the patch says how and what changes.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://0001-scan-a-weaker-BSS-needs-a-clearly-higher-estimate.patch"
