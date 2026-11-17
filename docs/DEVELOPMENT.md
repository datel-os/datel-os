# Development

## Building

The build runs in Docker with [kas](https://github.com/siemens/kas). The build tree, `sstate-cache` and `downloads` live in the Docker volume `k1yocto-work`, because Yocto needs a case-sensitive file system and the volume keeps a clean build (hours) from happening twice.

```bash
./build.sh                                   # k1-image
./build.sh virtual/kernel                    # any bitbake target
JOBS=4 ./build.sh                            # bitbake threads and make jobs
```

The log is `build-last.log` in the volume. Images land in `build/tmp/deploy/images/creality-k1/`: `xImage` (kernel), `k1-image-creality-k1.rootfs.squashfs-xz` (system) and `CR4CU220812S11_ota_img_V9.X.Y.Z.img` (the stock updater's package format). `TAG=vX.Y.Z tools/release.sh collect` copies them out of the volume under their release names; `tools/flash-slot2.sh` installs them, see [INSTALL.md](INSTALL.md).

zklippy comes from the private repository `zales/k1-zklippy`, which bitbake fetches over SSH. `build.sh` forwards the SSH agent of whoever runs it into the build container (Docker Desktop's on the Mac); the agent needs a key that may read that repository (`ssh -T git@github.com` greets you by name). GitHub's host keys are pinned in `recipes-printer/zklippy/files/github_known_hosts`. The release runner on the NAS has no such key yet: until it gets one (a read-only deploy key of the repository, which kas takes as `SSH_PRIVATE_KEY_FILE`), a release build stops at zklippy's fetch. A public release with zklippy in it also needs zklippy's source to be public (GPL-3.0).

## Layer layout

`meta-creality-k1/`:

| Directory | Contents |
|---|---|
| `conf/machine/creality-k1.conf`, `conf/machine/include/` | Machine: MIPS32r2 with the `mips32r2el-fp64` tune, kernel, image types |
| `conf/distro/k1os.conf` | Distro `k1os`, `DISTRO_VERSION` (must match a release tag) |
| `classes/` | The `creality-ota` image type |
| `recipes-kernel/linux/` | The kernel recipe: [zales/k1-linux](https://github.com/zales/k1-linux) at a pinned commit of `main`. The device tree, the configuration (`k1_defconfig`) and the Helix driver are in that tree; the layer adds no patch |
| `recipes-core/k1os-base/` | Datel OS services: data directory setup, trial boot and slot confirmation, Wi-Fi MAC, camera and printer-name seeding, `k1os-slot` |
| `recipes-core/images/k1-image.bb` | The image |
| `recipes-core/datel-branding/` | Hostname, MOTD, prompt, Mainsail logo |
| `recipes-printer/` | `zklippy`, `kalico` (`kalico-common` goes into the image: Klipper's example configs and docs and the configuration conversion; `kalico`, the Python host, does not), `k1-mcu-firmware`, `k1os-mcu-update`, `moonraker`, `mainsail`, `guppyscreen`, `k1os-camera`, `moonraker-timelapse`, `k1os-helix`, `k1os-stream` |
| `recipes-httpd/nginx/` | Mainsail and camera proxy configuration |
| `recipes-devtools/zig/` | The Zig compiler (official binary) that builds `zklippy`, `k1os-camera` and `k1os-helix` |
| `recipes-bsp/k1-wifi-nvram/` | Wi-Fi module calibration file |
| `recipes-devtools/gcc/` | gcc built for FP64 and NaN 2008 |
| `recipes-python/`, `recipes-connectivity/` | Python dependencies of Moonraker, sshd on a read-only root |

## What it is built on

- **Kernel:** Linux 6.18.63, kernel.org's stable kernel plus the K1's support, from [zales/k1-linux](https://github.com/zales/k1-linux) at the commit of `main` that `linux-x2000_6.18.bb` pins. That repository's README says how it is put together: the X2000 is one of the SoCs of upstream's Ingenic platform; its clocks, interrupt controller, timer and second CPU have drivers written from Ingenic's SDK kernel 6.6 (the tree NebulaOS keeps for the Ender-3 V3 KE) in the form of upstream's drivers for related chips, its other devices run on upstream's drivers with the X2000 added, everything reaches `main` through pull requests, and each of those says what it was checked with on a printer. The kernel is preemptible (`CONFIG_PREEMPT`), not PREEMPT_RT, which mainline does not offer for MIPS. Releases up to 0.5.1 shipped the SDK kernel 6.6.157 with PREEMPT_RT.
- **Configuration:** the tree's `k1_defconfig`, taken as it is. The recipe adds only the wireless regulatory database as built-in firmware and stops the build if an option the image depends on is missing. `uname -r` is `6.18.63`, and the modules (brcmfmac and the USB network adapters) come from the same build.
- **Device tree:** `arch/mips/boot/dts/ingenic/creality-k1.dts` of that tree, built into the kernel: console, MCU UARTs, eMMC, Wi-Fi, USB, the codec's 32 MiB of memory, the area for the kernel log kept over a restart. `hardware/` here holds the stock files its values come from.
- **System:** Yocto scarthgap (poky, meta-oe, meta-python, meta-networking, meta-webserver, meta-arm for the MCU toolchain), systemd, read-only root.
- **Update package:** the image type `creality-ota` produces an `.img` that the stock updater and a future own updater install. It holds the kernel and the system squashfs and goes into the inactive set of partitions.

## Design decisions worth knowing

**Everything from source, no blobs.** The only binaries in the image are the Wi-Fi chip firmware and its calibration data. The vendor's driver for the video codec, which wanted a prebuilt rate-control library, is replaced by Datel OS's own code.

**FPU ABI.** The XBurst2 FPU has 64-bit registers and only the NaN 2008 encoding. The poky tune `mips32r2el` builds the o32 FP32 ABI with legacy NaN, which the kernel then emulates instruction by instruction; the first print died of it. Datel OS therefore has its own tune `mips32r2el-fp64` and gcc with `--with-fp-32=64 --with-nan=2008`, the same ABI as the stock userspace. Changing it means rebuilding the whole userspace.

**Trial boot.** The stock SPL selects the slot by the text in `mmcblk0p1` and has no boot counter. `k1os-trial-boot.service` points the marker at the other slot before file systems are mounted; `k1os-slot-confirm.service` points it back once `/usr/data` is up and `/usr/data/k1os/boot-keep` exists. See `recipes-core/k1os-base/files/k1os-slot`.

**Helix video codec.** The X2000 has a hardware H.264/JPEG encoder and JPEG decoder (Helix) and an H.264 decoder (Felix, not used). The vendor's V4L2 driver is not used: it read JPEG headers in the kernel without checking a length, and one damaged camera frame stopped the SoC. Datel OS splits the work in two.

- The kernel has `k1os-helix.c` (`drivers/misc/` of [zales/k1-linux](https://github.com/zales/k1-linux), `CONFIG_K1OS_HELIX`), a small driver for `/dev/helix`: the codec's power, its interrupt, memory out of the 32 MiB that the board's device tree reserves for it, mapped into the program, and the cache work around a job. It parses nothing. Two calls: `K1OS_HELIX_ALLOC` for memory, `K1OS_HELIX_RUN` for a job, which names the ranges the program wrote for the codec and the ranges the codec writes for the program.
- Everything that reads a picture or tells the codec what to do is Zig, in `recipes-printer/k1os-helix/files/`: `helix.zig` (the device), `helix_jpeg.zig` (JPEG header parser, decode job), `helix_h264.zig` and `helix_cabac.zig` (parameter sets, slice header, CABAC start states, encode job), `helix_codec.zig` (a decoder and an encoder for pictures of one size). A job is a chain of register writes the codec reads from memory. `k1os-camera` links the same code as an object and k1os-stream's C calls it through `helix_codec.h`; `k1os-helix-enc` is the timelapse's encoder.

The tests run on the build host: the parser against 200 000 damaged headers, and the chains, headers and CABAC states against what the vendor's driver produced for the same input (`testdata/`, made by compiling the vendor's C on a computer). On the printer `k1os-helix-test` decodes and encodes through the driver; the H.264 it gives is bit for bit the vendor driver's.

Things to know when changing it: the codec's memory is cached in the program, so a row the program draws into after a decode has to be named (`drawsRows`), or the codec and the program do not see each other's bytes there; the pool hands out powers of two, so a 1280×720 stream (7.1 MiB) takes 8 MiB of the 32 and anything above 8 MiB would take 16; the codec keeps its power for half a second after a job, because its power gate takes 0.74 ms to open and the kernel waits for that with interrupts off.

**Camera node sharing.** A UVC node streams to one process. That process is `k1os-camera`, which hands each frame to everyone who wants it: MJPEG clients, snapshots and its H.264 encoder.

**Read-only root.** Moonraker, Klipper and GuppyScreen expect writable trees. Moonraker's database, Klipper's configuration, timelapse files and all settings live under `/usr/data/k1os` (partition `mmcblk0p10`, shared by both slots); `k1os-datadir-setup` creates them on the first start and copies defaults once. `/usr/data/k1os/printer_data/config` holds `printer.cfg` and `moonraker.conf`.

**Moonraker as root with `systemd_cli`.** Datel OS has no PolKit. Moonraker's service control runs `sudo systemctl`, so `sudo` is in the image; a static unit that was never started is not offered by Moonraker, hence the ordering reference from `k1os-twitch-autostart.service`. The provider starts `systemctl show` to learn the service states; upstream does that every two seconds, which was a fifth of a CPU here, so a patch makes it every ten and once more right after a service action.

## Pitfalls known up front

- The bootloader passes `init=/linuxrc`; the image links it to `/sbin/init`.
- The bootloader selects the display type with `lcm_id=<n>` on the command line. The reference printer has `lcm_id=3` (ST7701 "tjc"); five more panel variants exist.
- Partition `mmcblk0p9` is the writable overlay of stock and holds the user's stock modifications. Datel OS never mounts it.
- The RTOS of the third core (`zero.bin`, partitions p3/p4) is closed and shows the boot logo. `tools/rtos-splash.py` can replace the logo JPEGs inside a copy of the partition with the Datel OS logo; write the result only to the Datel OS slot and keep the original.
- The Wi-Fi firmware is `cyfmac43430` from linux-firmware; the NVRAM is the AP6212A file from the Ingenic SDK and stock (`ccode=CN`), installed as `brcmfmac43430-sdio.creality,k1.txt`. The regulatory database is in the image, so the kernel uses the country from `wpa_supplicant.conf`.
- The MAC address is read from the `sn_mac` partition before wpa_supplicant starts (`wifi-mac`), falling back to `/usr/data/macaddr.txt`, so the router gives the printer the same address as stock.
- Which access point of a network the printer takes is wpa_supplicant's choice, and the image changes it in two places. A patch to its ranking of scan results (`recipes-connectivity/wpa-supplicant`): upstream lets the throughput estimate decide between two access points whose signal-to-noise ratios, both capped at 25 dB, are less than 7 dB apart, so an 802.11n access point at -70 dBm went before an 802.11g one at -30 dBm. And `/etc/k1os/wpa_supplicant.conf`, read after the user's file, sets a background scan (`bgscan`) for while the signal is weak, so that the printer leaves an access point it only got because the better one did not answer. The chip's own roaming stays off (`/etc/modprobe.d/k1os-wifi.conf`). The measurements are in [NOTES.md](NOTES.md).
- `clock_gettime` is a system call and costs about 0.7 µs, of which 0.4 µs is the system call itself: the kernel's vDSO cannot read the X2000's timer. The coarse clocks (`CLOCK_MONOTONIC_COARSE`, in 10 ms steps) are answered from the vDSO in 0.06 µs.
- The RAM for Linux is 216 MiB with the codec's DMA pool. Input shaper fitting on the printer does not fit in it; `tools/shaper-fit.sh` does it on the computer.

## Branches

- `main`: what the releases are built from.
- `feat/uboot`: an open U-Boot with a boot counter, not verified on the printer.

Releases are tags `vX.Y.Z` built by a self-hosted runner, see [RELEASE.md](RELEASE.md). The engineering log with dated findings is [NOTES.md](NOTES.md).
