# K1 USB rescue test (read-only)

Tool: [ballaswag/ingenic-usbboot](https://github.com/ballaswag/ingenic-usbboot), commit c65eaa3.
Only `--swap-ota` writes to the eMMC (partition p1). Reading partitions changes nothing.

## Building on a Mac

```bash
brew install libusb pkg-config
git clone https://github.com/ballaswag/ingenic-usbboot.git ~/k1-usbboot
cd ~/k1-usbboot && git checkout c65eaa337cc9fb64fd8a2ea22bcf3f9395c9945c && make
```

## The test

1. Connect the MicroUSB port on the main board to the Mac. The cable must carry data, not just power. The port is on the top edge of the board on the left, the RESET and BOOT buttons on the same edge on the right (figure 3 in the [Creality guide](https://wiki.creality.com/en/k1-flagship-series/k1/quick-start-guide/brick-rescue-wire-brushing-process)).
2. The printer must be switched on; the board needs its 24 V supply. Do not print, the buttons reset it.
3. Hold BOOT and RESET for about 3 s, release RESET and then BOOT. The system LED glows faintly and the board waits in mask-ROM mode.
4. On the Mac check that the board shows up as "Ingenic USB BOOT DEVICE" (a108:eaef):

```bash
system_profiler SPUSBDataType | grep -i -A3 ingenic
```

Then continue by reading p1:
5. Start U-Boot in RAM and read partition p1 (offset 0x100000, 1 MiB):

```bash
cd ~/k1-usbboot && sudo ./usbboot --uboot && sudo ./usbboot -o 0x100000 -s 0x100000 --dump-partition ./ota.out
```

6. Compare with the backup. Both numbers must be the same:

```bash
md5 -q ~/k1-usbboot/ota.out; dd if=~/Documents/K1-zaloha-2026-11-05/mmcblk0-sectors-0-1488895.bin bs=512 skip=2048 count=2048 2>/dev/null | md5 -q
```

7. Press RESET. The printer starts stock normally.

A match means USB rescue works on this S12 board. A broken slot 2 can then be undone with `sudo ./usbboot --uboot && sudo ./usbboot --swap-ota`.

Used for real on 14 November 2026: the first Linux 6.18 kernel stopped before the first service on every start, and the marker swap from mask-ROM mode brought the reference printer back to the other slot.

## Starting the open bootloader from RAM

The same mask-ROM mode and the same `usbboot`, with the output of the `u-boot-k1` recipe (`./build.sh u-boot-k1`, files in `build/tmp/deploy/images/creality-k1/`) in place of Ingenic's binaries. Nothing is written to the eMMC until you run `saveenv` or `k1slot select` yourself: those store the 32 KiB environment at byte 0x6A400, in the empty part of the bootloader area.

Connect a USB-UART adapter to J1 first (115200 8n1; GND, RX and TX only). Without the console there is nothing to watch.

```bash
cd ~/k1-usbboot
cp /path/to/deploy/u-boot-k1-usb-stage1.bin /path/to/deploy/u-boot-k1.bin .
sudo ./usbboot --cpu x2000 --stage1 u-boot-k1-usb-stage1.bin   # SPL: DDR init, returns to the ROM
sudo ./usbboot --cpu x2000 --stage2 u-boot-k1.bin              # U-Boot at 0x80100000
```

The console shows `U-Boot SPL 2013.07`, `DDR: ... type is : LPDDR3`, `run start1 firmware finished, return to bootrom!`, then `U-Boot 2013.07 ... Board: Creality K1 mainboard ...` and the countdown. Press a key and go on by [docs/BOOTLOADER.md](../../docs/BOOTLOADER.md) (`k1slot status`, `mmc info`, `k1slot load`, `bootm`). RESET brings the printer back to the stock bootloader in the eMMC.

If our stage 1 does not get through the DDR init on the S12 board (the console goes quiet after `DDR:`), use `sudo ./usbboot --uboot` (Ingenic's `spl.bin` and burner) and send only our U-Boot: `sudo ./usbboot --cpu x2000 --stage2 u-boot-k1.bin`.
