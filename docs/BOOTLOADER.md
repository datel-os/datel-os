# An open bootloader for the K1

State on 23 November 2026: **it runs on the reference printer, from the eMMC.** The build of 17 November (`U-Boot 2013.07-k1-gd86790d2e`) was written to sectors 34 to 342 from the running Datel OS, without the test from RAM, because nobody was at the printer and its owner took the risk. Two restarts went through it: the SPL, U-Boot and `k1slot` started Datel OS from slot 2 in about 31 s each, as the stock SPL does.

What those two starts showed:
* the DDR init, the SPL reading U-Boot from the eMMC, U-Boot reading the marker and the kernel, `bootm` of Datel OS's 6.18 kernel with the command line `k1_boot` builds (both CPUs, the same memory, `lcm_id=3`);
* the first start saved the environment (`k1_env_saved=1`, `k1_trial=0`), the second read it back;
* Klipper ready, and the checks of `tools/release-test-checks.py` passed on the system so started.

What they did not show:
* a start after a real power-on. Both were restarts, with the DDR chip already powered;
* the stock system (slot 1) started by this bootloader;
* a kernel that hangs without a panic. Nothing restarts it, so the count goes on only with the power switch.

**The boot counter**, the same day, with this branch's image (merged with `main`) in slot 1:
* `fw_printenv` in Linux reads the environment U-Boot saved, and `k1os-slot status` says `u-boot:  open, trial=0 bootcount=0/3`.
* Armed (`k1os-slot arm`) and started once with the two slot services masked from the kernel command line (`k1_extra_args`): `k1_bootcount` read 1 afterwards. U-Boot counts.
* The next start, with the services back: the journal says `k1os-slot: boot counter cleared`, the environment reads `k1_trial=0`, `k1_bootcount=0`. A system that comes up ends the count.
* The fall back: the first block of slot 1's root filesystem zeroed, the counter armed, one restart asked. The kernel could not mount its root, panicked and restarted itself after its 10 s, three times; at the fourth start U-Boot wrote `ota:kernel2` into the marker and started slot 2. The printer answered from slot 2 79 s after the restart was asked, with `k1_fallback_from=1` and `k1_trial=0` in the environment. The block was then put back and slot 1 kept again.

An older Datel OS (before this branch) can still not arm the counter: it has no `fw_setenv`, and `tools/flash-slot2.sh --switch` run against it arms nothing.

The stock bootloader's bytes (sectors 34 to 433, read from the printer right before the write and equal to the backup of 5 November) are kept as `stock-bootloader-sectors-34-433.bin`; "Writing it to the eMMC" below has the way back.

What it is for: the stock SPL has no boot counter, so a kernel that hangs before the first service is started again on every power-up, and only the USB mask-ROM boot gets the printer back ([Limitations](../README.md#limitations), number 2). This bootloader counts the boots of a new slot and returns to the other one by itself.

## Source and licence

| What | Where from | Licence |
|---|---|---|
| U-Boot 2013.07 for the Ingenic X2000 (SPL and U-Boot) | [NebulaOS-KE/NebulaOS-kernel](https://github.com/NebulaOS-KE/NebulaOS-kernel), directory `u-boot/`, commit `d86790d2`; the directory has not changed since the repository's first commit (21 December 2025, the "initial release" of Ingenic's SDK) | GPL-2.0 (`COPYING`) |
| The K1 board (`board/ingenic/creality_k1`, `include/configs/creality_k1.h`, the `k1slot` command) | our own, in `meta-creality-k1/recipes-bsp/u-boot-k1/files` | GPL-2.0 |
| The USB boot tool [ballaswag/ingenic-usbboot](https://github.com/ballaswag/ingenic-usbboot) | commit c65eaa3; its `spl.bin` and `uboot.bin` are the "burner_x2000" binaries of the same SDK (September 2023), without source | GPL-2.0 (`usbboot.c`) |

What was not found: mainline U-Boot knows neither the X2000 nor XBurst2 (only the T series, through OpenIPC); NebulaOS does not change the bootloader; the boards `k1mbv01/02/04` in Ingenic's tree are another company's board with an M200 chip, not the Creality K1.

Datel OS's kernel came from the same repository up to 0.5.1. It is [zales/k1-linux](https://github.com/zales/k1-linux) now, which has no bootloader, so this recipe is the only thing that still fetches the SDK tree.

**The stock bootloader of the K1 is the same tree.** The prompt `x2000_base#`, the line `Board: halley5 (Ingenic XBurst2 X2000-V12 SoC)`, built on `Apr 26 2023` with Ingenic's gcc 7.2.0. The `INGE` parameter header in sector 0 and in the SPL is byte for byte the output of `tools/ingenic-tools/spl_params_fixer_x2000_v12.c` (PLL 624 MHz, CPCCR 0x95073310). Creality added only two things to the SPL: reading the `sn_mac` partition and the `lcm_id` parameter (below).

## How stock starts and how this bootloader starts

The first MiB of the eMMC (from the backup `~/Documents/K1-zaloha-2026-11-05`):

| Bytes | Sectors | Contents |
|---|---|---|
| 0x0000–0x01FF | 0 | 256 bytes of `INGE` parameters for the boot ROM, and the protective MBR |
| 0x0200–0x43FF | 1–33 | GPT (10 partitions, `ota` to `userdata`; none for the bootloader) |
| 0x4400–0xA3FF | 34–81 | SPL: the `MSPL` header and block count, parameters at +0x100, code from +0x800 (runs in TCSM at 0xb2401000), padded to 24 KiB |
| 0xA400– | 82– | U-Boot (`CONFIG_SYS_TEXT_BASE` 0x80100000); stock 170 049 bytes, ours 133 496 |
| 0x6A400–0x723FF | 850–913 | U-Boot's environment, 32 KiB; all zeros on a stock printer |

**Stock:** boot ROM → SPL. The SPL itself reads the marker in `ota` (p1), loads the RTOS of that slot (p3 or p4, 500 KiB at 0x86000000), copies the `sn_mac` partition into the RTOS's heap, starts the RTOS on the second XBurst2 core, waits until the RTOS overwrites the first word of its image (done), reads `lcm_id` from it, resets the second core, loads the slot's `xImage` (a legacy U-Boot image, load = entry = 0x80F00000) and jumps into it with argv `{0, cmdline}`. The full U-Boot in sector 82 **never runs** in a normal start (`bootcmd` is empty); it is there for Ingenic's cloner. No counter, no way back.

**`lcm_id`**, from the disassembly of the stock SPL: after detecting the panel the RTOS writes the panel's number into the word that `mapped_rtosdata_size` in the RTOS header points at (0x86085400 for `rtos`). The SPL remembers that word before it starts the RTOS, compares it afterwards and puts a changed value into `lcm_id=`. When the RTOS writes nothing, stock passes `lcm_id=0`.

**This bootloader:** boot ROM → SPL (the same SDK code with the board `creality_k1`: msc0 with 8 bits, the K1's partition table built in, the RTOS as stock does it, with `sn_mac` and with `lcm_id`, which it leaves at 0xa0000f00 as `"K1LC", id`) → U-Boot from sector 82 → `bootcmd=run k1_boot`:

```
k1slot select                 # marker in p1 + counter -> k1_slot, k1_root, k1_mem, k1_lcm
k1slot load ${loadaddr}       # the slot's xImage to 0x81000000; the other slot on a bad header or CRC
setenv bootargs console=${k1_console} mem=${k1_mem} lcm_id=${k1_lcm} init=/linuxrc \
       root=/dev/mmcblk0p${k1_root} rootwait rootfstype=squashfs ro ${k1_extra_args}
bootm ${loadaddr}
```

The kernel command line is the one the stock SPL passes (`console=ttyS2,115200n8 mem=256M@0x0 lcm_id=3 init=/linuxrc root=/dev/mmcblk0p7|8 rootwait rootfstype=squashfs ro`), so the stock kernel 4.4 and Datel OS's kernel start from it alike. Datel OS's `xImage` has the same header as stock's: an uncompressed image with load and entry address 0x80F00000 (read from the header of the 6.18.63 image of 17 November 2026). `k1_lcm_id=auto` takes the RTOS's value and, when that is 0, `k1_lcm_default` (3, this printer's panel); a fixed number in `k1_lcm_id` goes first. The result is in the run-time variable `k1_lcm`.

What it adds to stock:

- **A boot counter.** The variables `k1_trial`, `k1_bootcount` and `k1_bootlimit` (3). While `k1_trial=1`, every start raises `k1_bootcount` and saves the environment; past the limit U-Boot points the marker in p1 at the other slot, clears `k1_trial` and starts from there. See the next section for who arms and who clears it.
- **A console.** One second of `Hit any key to stop autoboot`, the hush shell, `mmc`, `md`, `loadb`, `k1slot status|marker|confirm`, `saveenv`. Recovery without USB: a cable on J1 and `k1slot marker 1`.
- **A net under an empty environment.** The first start saves the built-in defaults (`k1_env_saved=1`), and even if a tool in Linux wrote an environment without `bootcmd`, U-Boot uses the compiled-in one (patch `0002`).
- **A time limit for the RTOS.** Stock waits for the RTOS's signal for ever; our SPL goes on without it after 10 s.
- **A slot that is being written is never started.** `tools/flash-slot2.sh` zeroes the first 4 KiB of a slot's kernel while it writes; `k1slot load` finds no image header there and loads the other slot.

## The counter and Datel OS's trial boot

Datel OS already boots as a trial without this bootloader ([INSTALL.md](INSTALL.md#trial-boot-and-keeping-a-slot)): its first service points the marker back at the other slot, and `k1os-slot keep` makes the new slot stay. That protects from the first service on. The counter covers what is before it, a kernel that never gets that far. The two do not depend on each other.

| Who | What it does with the counter |
|---|---|
| `tools/flash-slot2.sh --switch` | after pointing the marker at the new slot it runs `k1os-slot arm` on the printer: `k1_bootcount=0`, `k1_trial=1` |
| `k1os-slot arm` | the same by hand, for the slot the marker names |
| U-Boot, every start with `k1_trial=1` | counts; at the fourth start of a slot that never confirmed it writes the other slot into the marker |
| `k1os-slot confirm` (every Datel OS boot, once `/usr/data` is up) and `k1os-slot keep` | `k1_trial=0`, `k1_bootcount=0`. It writes only when one of them is set |
| `k1slot marker 1\|2` on the console | sets the marker and arms the counter |

With the stock bootloader the environment area is zero, `fw_printenv` reports a bad CRC, and `k1os-slot` does all of the above by the marker alone; `k1os-slot status` says `u-boot:  stock (no environment)`. The script's test (`k1os-slot-test.sh`, run by the recipe on the build host) covers both cases with stand-ins for `fw_printenv` and `fw_setenv`.

**Never arm the counter for the stock slot.** Stock firmware confirms nothing, so after three starts the bootloader would send the printer back. `k1os-slot release` therefore does not arm it. Without `k1_trial=1` nothing is counted and stock starts as it always did.

What nobody presses a button for: a kernel that hangs before the first service does not restart by itself, because nothing has started the watchdog yet. The counter needs the three starts to come from somewhere, today from the power switch.

## What the recipe builds

`meta-creality-k1/recipes-bsp/u-boot-k1/u-boot-k1_2013.07.bb`, built with `./build.sh u-boot-k1`. An image build leaves it out until it has run on a printer; `K1OS_BUILD_UBOOT = "1"` builds it along with `k1-image`. Output in `build/tmp/deploy/images/creality-k1/`:

| File | What it is |
|---|---|
| `u-boot-k1-spl.bin` | the SPL as it lies from sector 34 (`MSPL` header, parameters, code), 18 024 bytes |
| `u-boot-k1.bin` | U-Boot, sector 82; also stage 2 for usbboot |
| `u-boot-k1-with-spl.bin` | the SPL padded to 24 KiB, then U-Boot: the eMMC's bytes from 0x4400 |
| `u-boot-k1-sector0.bin` | sector 0: boot ROM parameters and the protective MBR (equal to stock's) |
| `u-boot-k1-mbr-gpt.bin` | the whole first MiB as the SDK puts it together; its GPT has new GUIDs, **never write it** to a stock eMMC |
| `u-boot-k1-usb-stage1.bin` | the SPL built with `RUN_FIRMWARE_VIA_USB_BOOT`: it returns to the boot ROM after the DDR init (stage 1 for usbboot), 12 276 bytes |

The configuration `creality_k1` in `boards.cfg`: `SPL_JZMMC_SUPPORT, ENV_IS_IN_MMC, GPT_CREATOR, JZ_MMC_MSC0, SPL_PARAMS_FIXER`; `creality_k1_usb` adds `RUN_FIRMWARE_VIA_USB_BOOT`. Compiled by the layer's gcc 13 (`-msoft-float`); the SDK's host tools (`gpt_creator`, `spl_params_fixer`, `ddr_params_creator`) by the native gcc. Patches: `0001` picks `rtos` or `rtos2` by the marker without `SPL_OS_OTA_BOOT`, reads `lcm_id` from the RTOS and limits the wait; `0002` is the fallback `bootcmd`.

In the image, `k1os-base` installs `/etc/fw_env.config` (the environment's place) and pulls in `libubootenv-bin` for `fw_printenv` and `fw_setenv`.

## What is checked without a printer

The image from bitbake against the backup of the stock bootloader, build of 17 November 2026:

- Sector 0 (the `INGE` parameters and the MBR) is **equal**. The SPL's first 0x800 bytes are **equal**: the `MSPL` header with 36 blocks and the 256 bytes of parameters at +0x100. So are the first 64 bytes of the SPL's code (the same `start.S`). The GPT made from our `partitions.tab` has the same 10 partitions with the same sectors as stock's.
- The binaries say which source they are: `U-Boot 2013.07-k1-gd86790d2e`. The recipe writes that itself; left alone, the tree asks git and names the tip of the branch, which is not what bitbake unpacked. Apart from that line and the build's time they are the build of 7 November 2026.
- The DDR table (`supported_ddr_reg_values`; three chips, W97BV6MK, W63AH6NKB-BI, NK6CL256M16DKX-H1) has the same timing, mapping and sizes; stock's version of the structure is 28 bytes shorter (without the fields `phy_drvodt` and `phy_deskew`, which a newer SDK added with a "do not use" flag). Three values differed. `MR11` of LPDDR3: stock 0x02 (DQ ODT RZQ/2), the SDK 0 (off); the recipe sets stock's value, the one the board was tuned with. `DDRC_CTRL` bit 15 (`ACTPD`): stock leaves banks open in power-down, the SDK closes them first; the SDK's is kept. `DDRC_REFCNT` bit 1 for LPDDR3 (the refresh counter's divider): stock 1, the SDK 0 with the same constant 0xb6; a lower divider refreshes at least as often as stock, so the SDK's is kept. (Compared on 7 November 2026; the board files have not changed since.)
- The SPL fits its 24 KiB and U-Boot its 384 KiB (the environment starts at 384 KiB); the recipe checks both and stops the build when one is exceeded.

Not checked: everything at run time. That is the DDR init on this S12 board, reading the eMMC in the SPL and in U-Boot (the SDK's SDHCI driver runs with 1 or 4 bits by what the controller offers), the RTOS start and the value of `lcm_id`, `bootm` of Datel OS's kernel, saving the environment, and `fw_setenv` from Linux.

## The test from RAM over USB (writes nothing)

It cannot be done over SSH: the bootloader runs before Linux, and the only way to start it without writing to the eMMC is the chip's USB boot ROM (the BOOT button and micro USB). The same way leads back after a write that went wrong, which is why nothing is written to the eMMC while nobody is at the printer.

That way was used for real on this S12 board on 14 November 2026, with Ingenic's own binaries: `usbboot --uboot` and `--swap-ota` brought the printer back from a kernel that did not start. Our SPL and U-Boot have not been sent through it yet.

Needed: usbboot built by [tools/usbboot/README.md](../tools/usbboot/README.md), a USB-UART adapter on J1 (115200; GND, RX and TX; the board supplies its own 3.3 V), micro USB to the computer, the board in mask-ROM mode (BOOT + RESET). Copy the files from `build/tmp/deploy/images/creality-k1/` to `~/k1-usbboot/`.

```bash
cd ~/k1-usbboot && sudo ./usbboot --cpu x2000 --stage1 u-boot-k1-usb-stage1.bin
```

The console should show `U-Boot SPL 2013.07 (...)`, the lines `Current Version`, `DDR: ... LPDDR3` and `run start1 firmware finished, return to bootrom!`. Then:

```bash
sudo ./usbboot --cpu x2000 --stage2 u-boot-k1.bin
```

and on the console `U-Boot 2013.07`, `Board: Creality K1 mainboard`, a countdown of 1 s. Press a key, stay at the `k1os#` prompt and try **reads only**:

```
k1slot status          # the marker, the counter, lcm_id (without the RTOS: "not reported")
mmc info               # eMMC 7.3 GiB, bus width, speed
k1slot select          # careful: saves the environment to the eMMC (k1_env_saved), the first write, see below
k1slot load            # the slot's xImage to 0x81000000, its length, CRC
bootm ${loadaddr}      # Datel OS has to come up as it does from the stock SPL
```

`k1slot select` and `saveenv` write 32 KiB at 0x6A400, in the empty part of the bootloader area. That is the first and only write the test makes, and zeros undo it (`dd if=/dev/zero of=/dev/mmcblk0 bs=512 seek=850 count=64`). To avoid even that, run only `k1slot status`, `k1slot load` and `bootm`; the kernel then gets no `bootargs`, so set them by hand first as `k1_boot` does.

What this test does not show: the SPL of `u-boot-k1-spl.bin` reading U-Boot from the eMMC (in USB mode usbboot supplies it), and the RTOS start (stage 1 returns to the ROM before it). Both are the SDK's code unchanged, which runs in the stock SPL.

If our stage 1 does not initialise the DDR on the S12: `sudo ./usbboot --uboot` loads Ingenic's `spl.bin` and burner U-Boot; our `u-boot-k1.bin` can then be sent as stage 2 in its place.

## Writing it to the eMMC: what it would take (not decided)

Only after the test from RAM went through, with `bootm` of Datel OS. It is written from the running Linux over SSH, with the console on J1 open in case it fails, and not while a print runs.

1. The backup of the area 0–0xA3FFF is in `~/Documents/K1-zaloha-2026-11-05` (`mmcblk0-sectors-0-1488895.bin`; sectors 0–2047 are the whole first MiB).
2. Write the SPL and U-Boot: `u-boot-k1-with-spl.bin` from sector 34 (`dd of=/dev/mmcblk0 bs=512 seek=34 conv=fsync`). The file is 158 072 bytes, 309 sectors, and ends at sector 342, far before the environment (850) and `ota` (2048).
3. **Do not write sector 0:** our parameters equal stock's (checked), and the MBR and GPT stay. If the SPL's size ever changes, write only the first 256 bytes of `u-boot-k1-sector0.bin`.
4. Read it back, compare the MD5, then restart with the console open. BusyBox's `dd` on the printer has no `conv=fsync`: write with a plain `dd` and run `sync`.

The way back: `dd if=mmcblk0-sectors-0-1488895.bin bs=512 skip=34 count=400 | ssh root@<printer> 'dd of=/dev/mmcblk0 bs=512 seek=34 conv=fsync'` puts the stock SPL and U-Boot back. The write touched sectors 34 to 342; stock's U-Boot is the longer one and ends in sector 414, so 400 sectors from 34 cover both and stay far below the environment at 850. When the printer does not start at all, USB is left: `usbboot --uboot` (Ingenic's burner) and writing the backup with `--download` and `burn`, or the cloner. Writing through the burner is not tried on this S12 board, which is why the test from RAM comes before the write.

## What is left

- A start from a power-on, and stock in slot 1 started by it.
- The test from RAM over USB was skipped; it is still the way to try a new build without writing it.
- U-Boot reads the eMMC with the SDK's SDHCI driver without HS200; a kernel of 5 MiB takes about 1 s. Later `MMC_MODE_8BIT` and a faster clock.
- Starting the watchdog in U-Boot before `bootm`, so that a kernel that hangs is restarted and counted without the power switch. The kernel's watchdog driver has to take over a running watchdog for that; not looked at.
- `lcm_id` for other panels: `fw_setenv k1_lcm_default N`.
