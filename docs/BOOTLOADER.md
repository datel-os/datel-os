# Otevřený bootloader pro K1 (větev `feat/uboot`)

Stav 7. 11. 2026: recept `u-boot-k1` se přeloží, výsledek je zkontrolovaný proti
stock bootloaderu bajt po bajtu tam, kde to jde, ale **na tiskárně ještě neběžel**.
Do eMMC se v téhle větvi nic nezapisuje; první zkouška je start z RAM přes USB
(níže), zápis do eMMC je samostatný krok ke schválení.

## Odkud je zdroj a pod jakou licencí

| Co | Odkud | Licence |
|---|---|---|
| U-Boot 2013.07 pro Ingenic X2000 (SPL i U-Boot) | [NebulaOS-KE/NebulaOS-kernel](https://github.com/NebulaOS-KE/NebulaOS-kernel), adresář `u-boot/`, stejný commit `d86790d2` jako naše jádro; adresář se od prvního commitu repozitáře (21. 12. 2025, „initial release“ Ingenic SDK) nezměnil | GPL-2.0 (`COPYING`) |
| Deska K1 (`board/ingenic/creality_k1`, `include/configs/creality_k1.h`, příkaz `k1slot`) | vlastní, v `meta-creality-k1/recipes-bsp/u-boot-k1/files` | GPL-2.0 |
| Nástroj pro USB start [ballaswag/ingenic-usbboot](https://github.com/ballaswag/ingenic-usbboot) | commit c65eaa3; jeho `spl.bin`/`uboot.bin` jsou binárky „burner_x2000“ ze stejného SDK (září 2023), bez zdroje | GPL-2.0 (usbboot.c) |

Co se nenašlo: mainline U-Boot X2000 ani XBurst2 nezná (jen T-série přes
OpenIPC); NebulaOS bootloader nemění; desky `k1mbv01/02/04` v Ingenic stromu
jsou cizí deska s čipem M200, ne Creality K1.

**Stock bootloader K1 je tentýž strom.** Prompt `x2000_base#`, hlášení
`Board: halley5 (Ingenic XBurst2 X2000-V12 SoC)`, překlad `Apr 26 2023`
Ingenic gcc 7.2.0. Hlavička parametrů `INGE` v sektoru 0 i v SPL je bajt po
bajtu výstup `tools/ingenic-tools/spl_params_fixer_x2000_v12.c` (PLL 624 MHz,
CPCCR 0x95073310). Creality do SPL přidala jen čtení oddílu `sn_mac` a parametr
`lcm_id` (viz níže).

## Jak startuje stock a jak startuje K1 OS U-Boot

Rozložení první MiB eMMC (ze zálohy `~/Documents/K1-zaloha-2026-11-05`):

| Bajty | Sektory | Obsah |
|---|---|---|
| 0x0000–0x01FF | 0 | 256 B parametrů `INGE` pro boot ROM + ochranný MBR |
| 0x0200–0x43FF | 1–33 | GPT (10 oddílů `ota` … `userdata`, pro bootloader žádný) |
| 0x4400–0xA3FF | 34–81 | SPL: hlavička `MSPL` + počet bloků, parametry na +0x100, kód od +0x800 (běží v TCSM na 0xb2401000), zarovnáno na 24 KiB |
| 0xA400– | 82– | U-Boot (`CONFIG_SYS_TEXT_BASE` 0x80100000), stock 167 KB, náš 135 KB |
| 0x6A400–0x723FF | 850–913 | prostředí U-Bootu, 32 KiB; na stock tiskárně samé nuly |

**Stock:** boot ROM → SPL → SPL sám přečte značku v `ota` (p1), nahraje RTOS
daného slotu (p3/p4, 500 KiB na 0x86000000), do jeho haldy zkopíruje oddíl
`sn_mac`, spustí RTOS na druhém jádru XBurst2, počká, až RTOS přepíše první
slovo svého obrazu (hotovo), přečte z něj `lcm_id`, druhé jádro resetuje, nahraje
`xImage` ze slotu (uImage, load = entry = 0x80F00000) a skočí do něj s argv
`{0, cmdline}`. Plný U-Boot v sektoru 82 se při normálním startu **nikdy
nespustí** (`bootcmd` prázdný); slouží jen cloneru. Žádné počítadlo, žádný
návrat.

**`lcm_id`:** z disassembleru stock SPL: RTOS po detekci panelu zapíše číslo
panelu do slova, na které ukazuje položka `mapped_rtosdata_size` v hlavičce
RTOS (0x86085400 pro `rtos`); SPL si hodnotu zapamatuje před startem RTOS,
po jeho skončení ji porovná a změněnou hodnotu dá do `lcm_id=`. Když RTOS nic
nenapíše, stock předá `lcm_id=0`.

**K1 OS U-Boot:** boot ROM → SPL (stejný kód SDK, deska `creality_k1`: msc0
8 bitů, vestavěná tabulka oddílů K1, RTOS jako stock včetně `sn_mac` a čtení
`lcm_id`, které uloží na 0xa0000f00 jako `"K1LC", id`) → U-Boot ze sektoru 82
→ `bootcmd=run k1_boot`:

```
k1slot select                 # značka v p1 + počítadlo -> k1_slot, k1_root, k1_mem, k1_lcm
k1slot load ${loadaddr}       # xImage slotu na 0x81000000, při vadné hlavičce/CRC druhý slot
setenv bootargs console=${k1_console} mem=${k1_mem} lcm_id=${k1_lcm} init=/linuxrc \
       root=/dev/mmcblk0p${k1_root} rootwait rootfstype=squashfs ro ${k1_extra_args}
bootm ${loadaddr}
```

Výsledná příkazová řádka jádra je stejná jako ze stock SPL (`console=ttyS2,115200n8
mem=256M@0x0 lcm_id=3 init=/linuxrc root=/dev/mmcblk0p7|8 rootwait rootfstype=squashfs ro`),
takže z ní startuje jak stock jádro 4.4, tak K1 OS 6.6. `k1_lcm_id=auto` bere
hodnotu od RTOS, při 0 výchozí `k1_lcm_default` (3, panel téhle tiskárny);
pevné číslo v `k1_lcm_id` má přednost. Výsledek je v běhové proměnné `k1_lcm`.

Co proti stocku přibylo:

- **Počítadlo startů.** Proměnné `k1_trial`, `k1_bootcount`, `k1_bootlimit` (3).
  Při `k1_trial=1` každý start zvýší `k1_bootcount` a uloží prostředí; po
  překročení limitu U-Boot přepíše značku v p1 na druhý slot, `k1_trial` smaže
  a startuje odtamtud. Počítadlo nuluje `k1os-slot confirm` (každý úspěšný start
  K1 OS) přes `fw_setenv` (`libubootenv`, `/etc/fw_env.config`). Zapíná ho
  `k1os-slot arm` po přepnutí značky na slot s K1 OS, nebo `k1slot marker 1|2`
  z konzole. Stock nic nepotvrzuje, proto se počítadlo pro přepnutí na stock
  nezapíná a bez `k1_trial=1` se nic nepočítá; stock tak startuje jako dřív.
- **Konzole.** 1 s `Hit any key to stop autoboot`, hush shell, `mmc`, `md`,
  `loadb`, `k1slot status|marker|confirm`, `saveenv`. Zotavení bez USB: kabel
  na J1 a `k1slot marker 1`.
- **Záchrana proti prázdnému prostředí.** První start uloží vestavěné výchozí
  prostředí (`k1_env_saved=1`), a i kdyby uživatelský nástroj zapsal prostředí
  bez `bootcmd`, U-Boot použije zakompilovaný (patch `0002`).
- **Časový limit na RTOS.** Stock čeká na signál RTOS donekonečna; náš SPL
  po 10 s pokračuje bez něj.

## Co recept staví

`meta-creality-k1/recipes-bsp/u-boot-k1/u-boot-k1_2013.07.bb` (součást
`bitbake k1-image` přes `EXTRA_IMAGEDEPENDS`, vypne `K1OS_BUILD_UBOOT = "0"`).
Výstup v `tmp/deploy/images/creality-k1/`:

| Soubor | Co to je |
|---|---|
| `u-boot-k1-spl.bin` | SPL tak, jak leží od sektoru 34 (hlavička `MSPL`, parametry, kód), 18 040 B |
| `u-boot-k1.bin` | U-Boot, sektor 82; zároveň stage 2 pro usbboot |
| `u-boot-k1-with-spl.bin` | SPL doplněný na 24 KiB + U-Boot = bajty 0x4400– eMMC |
| `u-boot-k1-sector0.bin` | sektor 0: parametry boot ROM + ochranný MBR (shodný se stock) |
| `u-boot-k1-mbr-gpt.bin` | celá první MiB, jak ji skládá SDK; GPT má nové GUID, **nikdy nezapisovat** na stock eMMC |
| `u-boot-k1-usb-stage1.bin` | SPL přeložený s `RUN_FIRMWARE_VIA_USB_BOOT`: po inicializaci DDR se vrátí do boot ROM (stage 1 pro usbboot), 12 292 B |

Konfigurace `creality_k1` v `boards.cfg`: `SPL_JZMMC_SUPPORT, ENV_IS_IN_MMC,
GPT_CREATOR, JZ_MMC_MSC0, SPL_PARAMS_FIXER`; `creality_k1_usb` navíc
`RUN_FIRMWARE_VIA_USB_BOOT`. Překlad gcc 13 z vrstvy (`-msoft-float`), hostitelské
nástroje SDK (`gpt_creator`, `spl_params_fixer`, `ddr_params_creator`) nativním gcc.
Patche: `0001` výběr `rtos`/`rtos2` podle značky i bez `SPL_OS_OTA_BOOT`, čtení
`lcm_id` od RTOS a limit čekání; `0002` náhradní `bootcmd`.

## Co je ověřené bez tiskárny

Porovnání obrazu z bitbake (gcc 13 z vrstvy) se zálohou stock bootloaderu,
build 7. 11. 2026:

- sektor 0 (parametry `INGE` i MBR) **shodný**; hlavička SPL `MSPL` + 36 bloků
  a 256 B parametrů na +0x100 **shodné**, prvních 64 B kódu SPL také (stejný
  `start.S`); GPT vygenerovaná z naší
  `partitions.tab` má stejných 10 oddílů se stejnými sektory jako stock.
- tabulka DDR (`supported_ddr_reg_values`, tři čipy W97BV6MK, W63AH6NKB-BI,
  NK6CL256M16DKX-H1) má stejné časování, mapování i velikosti; stock verze
  struktury je o 28 B kratší (bez polí `phy_drvodt`/`phy_deskew`, které novější
  SDK přidalo s příznakem „nepoužít“). Lišily se tři hodnoty: `MR11` LPDDR3
  (stock 0x02 = DQ ODT RZQ/2, SDK 0 = vypnuto; recept nastavuje stock hodnotu,
  s ní je deska odladěná), `DDRC_CTRL` bit 15 (`ACTPD`: stock nechává banky
  otevřené při power-down, SDK je předem uzavře; ponecháno SDK) a `DDRC_REFCNT`
  bit 1 u LPDDR3 (dělička čítače obnovy: stock 1, SDK 0 při stejné konstantě
  0xb6; nižší dělička = obnova nejméně stejně častá jako u stocku, ponecháno SDK).
- SPL 18 040 B < 24 KiB, U-Boot 133 KB < 384 KiB (prostředí začíná na 384 KiB); recept
  obě meze kontroluje a při překročení build zastaví.

Neověřené: vše za běhu. Konkrétně inicializace DDR na této desce S12, čtení
eMMC v SPL i v U-Bootu (SDHCI ovladač SDK běží na 1 nebo 4 bity podle
schopností řadiče), start RTOS a hodnota `lcm_id`, `bootm` K1 OS jádra, zápis
prostředí, `fw_setenv` z Linuxu.

## Zkouška z RAM přes USB (nic se nezapisuje)

Přes SSH to nejde: bootloader běží dřív než Linux a jediná cesta, jak ho
spustit bez zápisu do eMMC, je USB boot ROM čipu (tlačítko BOOT + MicroUSB).
Stejnou cestou vede i záchrana po nepovedeném zápisu, proto se do eMMC
nezapisuje, dokud u tiskárny nikdo fyzicky není. Stav 7. 11. 2026: Mac
připravený (`~/k1-usbboot/` s přeloženým usbboot a oběma soubory), zkouška
čeká na fyzický přístup k tiskárně.

Potřeba: usbboot přeložený podle `tools/usbboot/README.md`, USB-UART na J1
(115200, GND + RX/TX; napájení z desky, 3,3 V), MicroUSB k Macu, deska v režimu
mask-ROM (BOOT + RESET). Soubory z `tmp/deploy/images/creality-k1/` zkopírovat
do `~/k1-usbboot/`.

```bash
cd ~/k1-usbboot && sudo ./usbboot --cpu x2000 --stage1 u-boot-k1-usb-stage1.bin
```

Na konzoli má být `U-Boot SPL 2013.07 (...)`, hlášky `Current Version`, `DDR:
... LPDDR3` a `run start1 firmware finished, return to bootrom!`. Pak:

```bash
sudo ./usbboot --cpu x2000 --stage2 u-boot-k1.bin
```

a na konzoli `U-Boot 2013.07`, `Board: Creality K1 mainboard`, odpočet 1 s.
Stisknout klávesu, zůstat v promptu `k1os#` a zkusit **jen čtení**:

```
k1slot status          # značka ota:kernel2, počítadlo, lcm_id (bez RTOS „not reported“)
mmc info               # eMMC 7.3 GiB, šířka sběrnice, rychlost
k1slot select          # pozor: uloží prostředí do eMMC (k1_env_saved) -- první zápis, viz níže
k1slot load            # xImage ze slotu 2 na 0x81000000, délka, CRC
bootm ${loadaddr}      # K1 OS musí naběhnout stejně jako ze stock SPL
```

`k1slot select` a `saveenv` zapisují 32 KiB na 0x6A400, což je v prázdné části
bootloaderové oblasti; to je první a jediný zápis, který zkouška udělá, a dá se
vrátit vynulováním (`dd if=/dev/zero of=/dev/mmcblk0 bs=512 seek=850 count=64`).
Kdo nechce ani to, spustí jen `k1slot status`, `k1slot load` a `bootm`.

Co tahle zkouška neprověří: SPL ze souboru `u-boot-k1-spl.bin` čte U-Boot
z eMMC (v USB režimu ho dodá usbboot) a start RTOS (stage 1 se vrací do ROM
před ním). Obojí je nezměněný kód SDK, který ve stock SPL běží.

Alternativa, kdyby náš stage 1 na S12 neinicializoval DDR: `sudo ./usbboot
--uboot` nahraje Ingenic `spl.bin` + burner U-Boot z usbboot; náš `u-boot-k1.bin`
pak lze poslat jako stage 2 místo něj.

## Zápis do eMMC: co by to obnášelo (zatím neschváleno)

Jen po úspěšné zkoušce z RAM včetně `bootm` K1 OS. Zapisuje se z běžícího
Linuxu přes SSH, s otevřenou konzolí na J1 pro případ, že by to selhalo.

1. Záloha oblasti 0–0xA3FFF: `dd if=/dev/mmcblk0 bs=512 count=2048` už je
   v `~/Documents/K1-zaloha-2026-11-05` (sektory 0–2047 = celá první MiB).
2. Zapsat SPL + U-Boot: `u-boot-k1-with-spl.bin` od sektoru 34
   (`dd of=/dev/mmcblk0 bs=512 seek=34 conv=fsync`). Soubor má asi 158 KB =
   309 sektorů, končí u sektoru 343, hluboko před prostředím (850) i `ota` (2048).
3. Sektor 0 **nepřepisovat**: naše parametry jsou se stock shodné (ověřeno),
   MBR i GPT zůstávají. Kdyby se někdy velikost SPL změnila, zapsat jen prvních
   256 B z `u-boot-k1-sector0.bin`.
4. Zpětně přečíst a porovnat MD5, potom restart s konzolí.

Návrat: `dd if=mmcblk0-sectors-0-1488895.bin bs=512 skip=34 count=311 | ssh
root@tiskarna 'dd of=/dev/mmcblk0 bs=512 seek=34 conv=fsync'` vrátí stock SPL
i U-Boot (stock U-Boot je delší, 167 KB = 327 sektorů; proto `count=330`). Když
tiskárna nenaběhne vůbec, zbývá USB: `usbboot --uboot` (Ingenic burner) a zápis
zálohy přes `--download` + `burn`, nebo cloner; obojí na této desce S12
neověřené, proto zkouška z RAM předchází zápisu.

## Co zbývá

- Zkouška z RAM na tiskárně (čeká na fyzický přístup: USB-UART na J1, MicroUSB, BOOT + RESET).
- Po ní rozhodnutí o zápisu do eMMC.
- U-Boot čte eMMC ovladačem SDHCI SDK bez HS200; jádro 4 MiB se načte do ~1 s.
  Časem `MMC_MODE_8BIT` + vyšší takt.
- Updater K1 OS má po zápisu nového slotu volat `k1os-slot arm`.
- Konfigurace `lcm_id` pro jiné panely: `fw_setenv k1_lcm_default N`.
