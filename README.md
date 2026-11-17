<img src="docs/logo.svg" width="96" align="right" alt="Datel OS">

# Datel OS

Open firmware for the Creality K1, built from source with Yocto: Linux 6.18, zklippy (Kalico's host as one Zig binary) with open firmware for all three MCUs, Moonraker, Mainsail, camera streaming, hardware-encoded timelapse and Twitch live streaming. The stock bootloader stays in place and the second eMMC slot always holds a way back.

**Pre-release for developers.** It runs on the author's K1 in both A/B slots. The display does not work yet, recovery from a kernel that fails to boot needs a USB cable, and everything is verified on one printer. Since version 0.8.0 the Klipper host is **zklippy**: Kalico's host ported module by module to one Zig binary, in place of Kalico's Python host, which left the image. 0.8.0 also keeps the journal to 16 MiB of `/run`, has no unused Linux host MCU any more, and its health line reports the RAM tmpfs holds. The kernel is 0.7.0's.

Version 0.8.1 gave the camera's graph and statistics panels half their CPU cost and made Mainsail's WebRTC camera give its viewer place back when its view is gone ([Viewer limits](docs/CAMERA.md#viewer-limits)).

Version 0.8.2 is 0.8.1 with the fixes of a review of the whole project:
* **Every new system is a trial again.** `boot-keep` names the slot that was kept, so a system written into the other slot no longer confirms itself on its first boot, before anyone has seen it run: it needs its own `k1os-slot keep`. A slot that `tools/flash-slot2.sh` is writing, or left half written, is never made the next boot ([Trial boot and keeping a slot](docs/INSTALL.md#trial-boot-and-keeping-a-slot)). Use this version's `flash-slot2.sh` from now on.
* The title template of the Twitch stream is rendered in a sandbox. Any host on the local network can set it through Moonraker, and it ran in Moonraker's process, as root, without one. A template may use the placeholders, `{% if %}`, `{% set %}` and a short list of filters ([TWITCH.md](docs/TWITCH.md)).
* zklippy: `SAVE_CONFIG` replaces `printer.cfg` with a finished file instead of writing in place, where a power cut left it empty; a macro variable no longer keeps a pointer into freed memory; a restart leaves nothing of the old printer behind; `M114` and the shutdown report no longer bring the host down on rare input.
* One damaged snapshot no longer costs a timelapse its video, and the camera's certificate fingerprint stays inside its buffer.

What ran before this release: the tests on the build host only. zklippy's test suite on a Mac, with the comparisons against Kalico for macros and `SAVE_CONFIG`; `k1os-slot` against files in place of the eMMC, and `flash-slot2.sh` against a stand-in for the printer, with the write broken off before each of its steps; the title template against Jinja 3.1.4; the timelapse script with stand-ins for the encoder.

**Nothing of 0.8.2 has run on a printer: not this image, not the new `k1os-slot`, not `flash-slot2.sh` with the printer's own BusyBox.** Write it into the slot that is not running and try it before `k1os-slot keep`; the system you run now stays in the other slot. Read [Limitations](#limitations) before installing.

What ran on the reference printer for the versions before it, on 17 November 2026:
* An 89-minute print under zklippy, started by hand on 0.7.0 with the same zklippy binary. It completed with the steps never less than 3.0 s ahead and no page of the program read back from the disk.
* Version 0.8.0, as built from its sources before its release: it booted from the second slot and was kept, with zklippy ready in 10 s, its memory locked, no Moonraker warning and no failed unit, and an 18-minute print completed on it.
* The camera daemon with 0.8.1's drawing of the panels, built from the same sources outside the image and started in place of 0.8.0's, through that 18-minute print with two WebRTC viewers, and Mainsail's player with its new methods in a desktop browser against the printer's camera.

## What works

| Area | State |
|---|---|
| Kernel | Linux 6.18.63, kernel.org's stable kernel with the K1's support from [zales/k1-linux](https://github.com/zales/k1-linux) (the X2000 on upstream's Ingenic platform, upstream's drivers with the X2000 added, a K1 device tree): eMMC, Wi-Fi with the stock MAC, all three MCU UARTs, UVC camera, Helix video codec. The CPU runs at 912 MHz instead of the boot loader's 1200 ([why](docs/DIAGNOSTICS.md#cpu-clock-and-floating-point)) |
| System | Yocto scarthgap, systemd, read-only squashfs root, data in `/usr/data/k1os`, A/B slots with a trial boot that falls back to the other slot |
| Printing | zklippy, Kalico's host as one Zig binary ([KALICO.md](docs/KALICO.md#the-host-zklippy)); open firmware on all three MCUs, load cell probe; an 89-minute print completed under zklippy on 17 November 2026 |
| Web UI | Moonraker and Mainsail behind nginx, printer name and camera registered on first boot |
| Camera | 720p MJPEG, snapshots and H.264 over WebRTC from the Helix codec (shared with the Twitch stream), all from one daemon of 1 MB, `k1os-camera` |
| Timelapse | moonraker-timelapse with the render on the X2000 Helix hardware encoder |
| Twitch | Live stream with a status bar, temperature graph and printer statistics in the picture, controlled from Mainsail, automatic stream title |
| Updates | Write the inactive slot over SSH, trial boot, GitHub Releases from tags |
| Staying alive | Hardware watchdog, compressed swap, an OOM kill instead of a freeze with the print killed last, the journal kept across a reboot and sent to a syslog server, a health line every minute, a flight recorder that keeps the last 15 minutes before Klipper stops |
| Display and touch | **Missing.** The screen shows the RTOS boot logo only |
| Own bootloader | In progress on branch `feat/uboot`, not verified on the printer |

## Limitations

Ordered by how much it hurts.

1. **No display.** Datel OS has no panel driver. Control the printer through Mainsail, OrcaSlicer or SSH.
2. **No automatic fallback from a kernel that does not boot.** The stock SPL has no boot counter. The trial boot protects from the first systemd service on; a kernel that hangs before that needs the USB mask-ROM boot ([tools/usbboot/README.md](tools/usbboot/README.md)). That way back was needed once on the S12 board, on 14 November 2026 with the first Linux 6.18 kernel, and it worked.
3. **Installation needs root over SSH on stock.** Creality publishes the stock root password in its rooting guide. Datel OS keeps the same root password, so it opens both slots.
4. **MCU firmware changes only on a cold start.** When moving between stock and Datel OS, power the printer off and on.
5. **Verified on one printer:** board CR4CU220812S11, panel `lcm_id=3`.
6. **Wi-Fi is 2.4 GHz only.** The camera stream can saturate a weak link; the default is 8 fps.
7. **The CPU is slower than on stock.** At 1200 MHz the reference printer computes wrong floating point results and Kalico shuts down in the middle of a print, so the kernel runs it at 912 MHz, the highest clock that stayed clean in the test (816 MHz up to version 0.6.0). The margin is thin: at 936 MHz, the next step, the test gave a wrong result within a minute ([the measurements](docs/DIAGNOSTICS.md#cpu-clock-and-floating-point)). Prints at 912 MHz since 16 November 2026 finished, the longest 3 h 40 min; one at five times the sliced speed stopped with "Timer too close", for a reason not settled. A print at several times the sliced speed with two camera viewers and the Twitch stream at once can use both CPUs up; the Klipper host is set to tolerate stalls of up to three seconds.
8. **zklippy is new.**
   * On the reference printer it heats, homes, probes and meshes, and two prints completed under it: one of 89 minutes, and one of 18 minutes on version 0.8.0's image.
   * Its first long print stopped after 131 s, when 40 MB written to the eMMC stalled the host for 2.4 s. Since then zklippy locks its memory and reads the G-code a megabyte ahead in a thread of its own; the 89-minute print ran so.
   * A print at several times the sliced speed, the reason for zklippy, has not run under it yet.
   * Kalico's Python host is not in the image. The way back to it is the other slot, or version 0.7.0.
   * Writing large files on the printer while it prints can still stall Moonraker for seconds.

## Install

Short version; the full procedure with backup, recovery and first-start steps is in [docs/INSTALL.md](docs/INSTALL.md).

1. Copy your SSH key to the stock printer: `ssh-copy-id -i ~/.ssh/k1_printer_ecdsa.pub root@<ip>`.
2. Download a [release](https://github.com/zales/datel-os/releases) and verify `SHA256SUMS`, or build (below).
3. Write the inactive slot and verify it. `IDLE=1` says that the printer is not printing: stock without Moonraker cannot tell the script, and it does not write on a guess:

```bash
IDLE=1 KERNEL=dl/datel-os-vX.Y.Z-xImage ROOTFS=dl/datel-os-vX.Y.Z-rootfs.squashfs PRINTER=root@<ip> tools/flash-slot2.sh --write
```

4. Point the boot marker at the new slot and power-cycle the printer:

```bash
KERNEL=dl/datel-os-vX.Y.Z-xImage ROOTFS=dl/datel-os-vX.Y.Z-rootfs.squashfs PRINTER=root@<ip> tools/flash-slot2.sh --switch
```

Datel OS starts in trial mode: a power cycle returns to the previous system until you run `k1os-slot keep` on the printer.

## Build

Needs Docker. The build tree lives in the Docker volume `k1yocto-work` because Yocto needs a case-sensitive file system. The first build takes hours; later ones minutes.

```bash
./build.sh
```

Images land in the volume under `build/tmp/deploy/images/creality-k1/`; `TAG=vX.Y.Z tools/release.sh collect` copies them out. Details in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Documentation

| Document | Contents |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | Backup, flashing, trial boot, both slots, going back to stock, recovery |
| [docs/KALICO.md](docs/KALICO.md) | The Klipper host (zklippy) and the MCU firmware: configuration conversion, probe and input shaper calibration, fans |
| [docs/CAMERA.md](docs/CAMERA.md) | Camera settings, OrcaSlicer, timelapse |
| [docs/TWITCH.md](docs/TWITCH.md) | Twitch live stream: setup, Mainsail dialog, overlay, automatic title |
| [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md) | Watchdog, the journal after a hang and on another machine, the health line, the flight recorder, the CPU clock and floating point, what happens out of memory |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Layer layout, build, kernel and image internals, design decisions |
| [docs/HARDWARE.md](docs/HARDWARE.md) | K1 hardware as found on the stock system: partitions, pins, peripherals |
| [docs/RELEASE.md](docs/RELEASE.md) | Release files, the build runner, cutting a release |
| [docs/NOTES.md](docs/NOTES.md) | Engineering log: findings and measurements by date |

## Repository layout

| Path | Contents |
|---|---|
| `meta-creality-k1/` | The Yocto layer: machine and distro, kernel recipe with the K1 device tree, printer software, Datel OS services |
| `kas-creality-k1.yml` | kas configuration of the build |
| `build.sh` | Builds in Docker |
| `tools/` | `flash-slot2.sh` (install over SSH), `release.sh`, `shaper-fit.sh`, `rtos-splash.py`, `usbboot/`, `fptest/` (floating point consistency tests and a tool that changes the CPU clock) |
| `hardware/` | Stock device tree, module parameters and live GPIO state of the reference printer |
| `docs/` | Documentation |

## Licensing

Our code, recipes, scripts, documentation and artwork are under the MIT license ([LICENSE](LICENSE)). The image contains third-party software under its own licenses; every recipe in `meta-creality-k1` names its license and exact source.

| Component | License | Source |
|---|---|---|
| Linux 6.18 with the K1's support | GPL-2.0 | [zales/k1-linux](https://github.com/zales/k1-linux); what mainline lacks for the X2000 is written there from [NebulaOS-KE/NebulaOS-kernel](https://github.com/NebulaOS-KE/NebulaOS-kernel) (Ingenic's SDK kernel 6.6), and a file written from one of the SDK's names it at its top |
| Kalico (its example configs and docs) and the MCU firmware | GPL-3.0 | [pellcorp/kalico](https://github.com/pellcorp/kalico), [zales/k1-kalico-firmware](https://github.com/zales/k1-kalico-firmware) (a fork of pellcorp/k1-kalico-firmware) |
| zklippy, Kalico's host ported to Zig | GPL-3.0 | `zales/k1-zklippy` (a private repository); the source of the version in the image is in every release's files as `datel-os-vX.Y.Z-zklippy-src.tar.gz` |
| Moonraker, Mainsail, moonraker-timelapse | GPL-3.0 | upstream |
| Mbed TLS 3.6.2 (the DTLS handshake of WebRTC, inside `k1os-camera`) | Apache-2.0 | [Mbed-TLS/mbedtls](https://github.com/Mbed-TLS/mbedtls) |
| Zig 0.17.1 (build tool only) | MIT | [ziglang.org](https://ziglang.org/) |
| Spleen bitmap font | BSD-2-Clause | [fcambus/spleen](https://github.com/fcambus/spleen) |
| GuppyScreen | GPL-3.0, MIT, BSD-3 | upstream |
| Wi-Fi firmware `brcmfmac43430-sdio.bin` | linux-firmware license (binary) | linux-firmware |
| AP6212A NVRAM | vendor calibration data, no stated license | Ingenic SDK / stock firmware |
| Yocto poky, meta-openembedded | MIT and per-package licenses | upstream |

Neither the image nor a release contains the stock bootloader (SPL, U-Boot), the RTOS `zero.bin` of the third core, or the contents of partition `mmcblk0p9`. Nothing is taken from the unlicensed pellcorp/creality repository.
