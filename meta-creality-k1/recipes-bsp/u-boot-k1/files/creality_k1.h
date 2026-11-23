/*
 * Creality K1 (CR4CU220812S11/S12 mainboard, Ingenic X2000-V12) configuration
 * for the Ingenic U-Boot 2013.07 tree, as used by K1 OS.
 *
 * Boot flow:  boot ROM -> SPL (TCSM, eMMC sector 34) -> U-Boot (sector 82)
 *             -> "k1slot" picks the slot from the ota marker (mmcblk0p1) and
 *             the boot counter in the environment -> bootm xImage from
 *             kernel (p5) or kernel2 (p6).
 * The stock Creality bootloader is the same tree built with CONFIG_SPL_OS_OTA_BOOT
 * (its SPL jumps straight to the kernel and its U-Boot is never entered).
 *
 * Copyright (c) 2020 Ingenic Semiconductor Co.,Ltd (x2000_base_common.h)
 * K1 adaptation 2026, K1 OS project.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of
 * the License, or (at your option) any later version.
 */
#ifndef __CONFIG_CREALITY_K1_H__
#define __CONFIG_CREALITY_K1_H__

/* SoC */
#define CONFIG_MIPS32
#define CONFIG_CPU_XBURST2
#define CONFIG_SYS_LITTLE_ENDIAN
#define CONFIG_X2000_V12

/* DDR: the SDK default set (LPDDR2 W97BV6MK, LPDDR3 W63AH6NKB-BI and
 * NK6CL256M16DKX-H1), picked at run time by the efuse "burned ddr id".
 * The stock K1 SPL carries exactly these three chips. */
#include "x2000_ddr.h"
/* The stock SPL's LPDDR3 tables have MR11 = 0x02 (DQ ODT RZQ/2), which the SDK
 * default of 0 switches off. Match stock; the board was qualified with it.
 * The two other table differences to stock (DDRC_CTRL ACTPD, REFCNT divider)
 * stay at the SDK values, see docs/BOOTLOADER.md. */
#undef CONFIG_LPDDR3_KGD_MR11_ODT
#define CONFIG_LPDDR3_KGD_MR11_ODT	0x2

/* Clocks, same as the SDK halley5/x2000_base boards and the stock SPL params
 * (APLL 1.2 GHz CPU, MPLL 1.5 GHz, DDR 750 MHz). */
#define CONFIG_SYS_APLL_FREQ		1200000000
#define CONFIG_SYS_MPLL_FREQ		1500000000
#define CONFIG_SYS_EPLL_FREQ		300000000
#define CONFIG_CPU_SEL_PLL		APLL
#define CONFIG_DDR_SEL_PLL		MPLL
#define CONFIG_SYS_CPU_FREQ		1200000000
#define CONFIG_SYS_MEM_FREQ		750000000

#define CGU_CLK_SRC {				\
		{LCD, MPLL},			\
		{MSC0, MPLL},			\
		{MSC2, MPLL},			\
		{SFC, MPLL},			\
		{CIM, MPLL},			\
		{SRC_EOF,SRC_EOF}		\
	}

#define CONFIG_SYS_EXTAL		24000000
#define CONFIG_SYS_HZ			1000

/* Caches (XBurst2) */
#define CONFIG_SYS_DCACHE_SIZE		(32 * 1024)
#define CONFIG_SYS_DCACHELINE_SIZE	(32)
#define CONFIG_SYS_DCACHE_WAYS		(8)
#define CONFIG_SYS_ICACHE_SIZE		(32 * 1024)
#define CONFIG_SYS_ICACHELINE_SIZE	(32)
#define CONFIG_SYS_ICACHE_WAYS		(8)
#define CONFIG_SYS_CACHELINE_SIZE	(32)
#define CONFIG_BOARD_SCACHE
#define CONFIG_SYS_SCACHE_SIZE		(512 * 1024)
#define CONFIG_SYS_SCACHELINE_SIZE	(64)
#define CONFIG_SYS_SCACHE_WAYS		(16)

/* Console: UART2 on PD30/PD31 (header J1), 115200 8n1, like stock. */
#define CONFIG_SYS_UART_INDEX		2
#define CONFIG_BAUDRATE			115200
#define CONFIG_SPL_SERIAL_SUPPORT
#define CONFIG_SPL_COMMAND_ICACHE

/* No autoboot delay: a second of every start is too much for a console
 * nobody has connected. A key that is already held when U-Boot starts still
 * stops it (J1), and "fw_setenv bootdelay 3" brings the wait back. */
#define CONFIG_BOOTDELAY		0
#define CONFIG_ZERO_BOOTDELAY_CHECK

/*
 * eMMC on MSC0, 8 data lines on PD17..PD26 (CONFIG_JZ_MMC_MSC0_PD).
 * The SPL reads with the small polling driver (spl_jzsdhci.c), U-Boot with
 * the SDHCI driver (jz_sdhci.c).
 */
#define CONFIG_GENERIC_MMC
#define CONFIG_MMC
#define CONFIG_MMC_SPL_PARAMS
#define CONFIG_SDHCI
#define CONFIG_JZ_SDHCI
#define CONFIG_CMD_MMC
#define CONFIG_JZ_MMC_MSC0_PD
#define CONFIG_SPL_JZ_MSC_BUS_8BIT
#define CONFIG_SPL_JZSDHCI
#define CONFIG_EFI_PARTITION
#define CONFIG_DOS_PARTITION

/* U-Boot proper lives at sector 82 = 17 KiB (MBR+GPT) + 24 KiB (SPL pad). */
#define CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR	82
#define CONFIG_UBOOT_OFFSET		0x6000

/*
 * Built-in partition table for the SPL (board/ingenic/creality_k1/partitions.tab,
 * turned into spl_gpt_tab_data.h at build time). It mirrors the GPT Creality
 * ships; the SPL looks partitions up by name.
 */
#define CONFIG_GPT_TAB_BUILT_IN
#define CONFIG_GPT_TABLE_PATH		"$(TOPDIR)/board/$(BOARDDIR)"

/*
 * RTOS boot in the SPL, exactly like stock: load rtos/rtos2 (the slot the ota
 * marker names) to 0x86000000, copy the sn_mac partition into its heap, run it
 * on the second XBurst2 core until it signals, read the panel id it leaves
 * behind (lcm_id), reset the second core. See the k1 patch to spl_jzsdhci.c.
 */
#define CONFIG_SPL_RTOS_BOOT
/* Fallback offset the SDK code wants defined; the K1 table is used instead. */
#define CONFIG_RTOS_OFFSET		(17 * 1024 + CONFIG_SPL_PAD_TO)
#define CONFIG_RTOS_OFFSET_SECTOR	(CONFIG_RTOS_OFFSET / 512)
#define CONFIG_RTOS_BOOT_ON_SECOND_CPU
#define CONFIG_SPL_RTOS_NAME		"rtos"
#define CONFIG_SPL_RTOS_NAME2		"rtos2"
#define CONFIG_SPL_OTA_NAME		"ota"
#define CONFIG_SPL_OS_NAME2		"kernel2"
#define CONFIG_SPL_RTOS_OTA_SELECT
#define CONFIG_SPL_RTOS_LINUX_MAPPED_FILESYSTEM_NAME	"sn_mac"
#define CONFIG_K1_LCM_FROM_RTOS
/* Where the SPL leaves {"K1LC", lcm_id} for U-Boot (uncached, low RAM). */
#define CONFIG_K1_LCM_INFO_ADDR		0xa0000f00
#define CONFIG_K1_LCM_MAGIC		0x4b314c43	/* "K1LC" */
/* Used when the RTOS reported no panel id (0): this printer's panel. */
#define CONFIG_K1_LCM_DEFAULT		3

/* GPIO */
#define CONFIG_JZ_GPIO

/* Commands */
#define CONFIG_CMD_BOOTD
#define CONFIG_CMD_CONSOLE
#define CONFIG_CMD_ECHO
#define CONFIG_CMD_LOADB
#define CONFIG_CMD_MEMORY
#define CONFIG_CMD_MISC
#define CONFIG_CMD_RUN
#define CONFIG_CMD_SOURCE
#define CONFIG_CMD_GETTIME
#define CONFIG_CMD_GPIO
#define CONFIG_CMD_ITEST
#define CONFIG_CMD_SETEXPR
#define CONFIG_CMD_SAVEENV
#define CONFIG_CMD_DDR_TEST
#define CONFIG_SYS_HUSH_PARSER
#define CONFIG_SYS_PROMPT_HUSH_PS2	"> "

#define CONFIG_LOADS_ECHO		1

/* Misc */
#define CONFIG_SKIP_LOWLEVEL_INIT
#define CONFIG_BOARD_EARLY_INIT_F
#define CONFIG_SYS_NO_FLASH
#define CONFIG_SYS_FLASH_BASE		0
#define CONFIG_ENV_OVERWRITE
#define CONFIG_MISC_INIT_R		1
#define CONFIG_SYS_NAND_SELF_INIT
#define CONFIG_BOOTP_MASK		(CONFIG_BOOTP_DEFAUL)

#define CONFIG_SYS_MAXARGS		16
#define CONFIG_SYS_LONGHELP
#define CONFIG_SYS_PROMPT		"k1os# "
#define CONFIG_SYS_CBSIZE		1024
#define CONFIG_SYS_PBSIZE		(CONFIG_SYS_CBSIZE + sizeof(CONFIG_SYS_PROMPT) + 16)

#define CONFIG_SYS_MONITOR_LEN		(384 * 1024)
#define CONFIG_SYS_MALLOC_LEN		(16 * 1024 * 1024)
#define CONFIG_SYS_BOOTPARAMS_LEN	(128 * 1024)

#define CONFIG_SYS_SDRAM_BASE		0x80000000
#define CONFIG_SYS_SDRAM_MAX_TOP	0x90000000
#define CONFIG_SYS_INIT_SP_OFFSET	0x400000
#define CONFIG_SYS_LOAD_ADDR		0x81000000
#define CONFIG_SYS_MEMTEST_START	0x80000000
#define CONFIG_SYS_MEMTEST_END		0x88000000

#define CONFIG_SYS_TEXT_BASE		0x80100000
#define CONFIG_SYS_SC_TEXT_BASE		0x80100004
#define CONFIG_SYS_MONITOR_BASE		CONFIG_SYS_TEXT_BASE

/*
 * Environment: 32 KiB in the eMMC at 384 KiB + sector 82 = byte 0x6A400,
 * inside the first MiB (before the ota partition at 1 MiB). Zero on a stock
 * printer, so the first boot runs on the built-in defaults and saves them.
 * Userspace: fw_setenv with "/dev/mmcblk0 0x6A400 0x8000".
 */
/* CONFIG_ENV_IS_IN_MMC comes from boards.cfg */
#define CONFIG_SYS_MMC_ENV_DEV		0
#define CONFIG_ENV_SIZE			(32 << 10)
#define CONFIG_ENV_OFFSET		(CONFIG_SYS_MONITOR_LEN + CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR * 512)

/* SPL */
#define CONFIG_SPL
#define CONFIG_SPL_FRAMEWORK
#define CONFIG_SPL_NO_CPU_SUPPORT_CODE
#define CONFIG_SPL_START_S_PATH		"$(CPUDIR)/$(SOC)"
#define CONFIG_SPL_LDSCRIPT		"$(CPUDIR)/$(SOC)/u-boot-spl.lds"
#define CONFIG_SPL_PAD_TO		24576
#define CONFIG_SPL_BOARD_INIT
#define CONFIG_SPL_LIBGENERIC_SUPPORT
#define CONFIG_SPL_GPIO_SUPPORT
#define CONFIG_SPL_TEXT_BASE		0xb2401000
#define CONFIG_SPL_MAX_SIZE		(24 * 1024)

/*
 * Boot environment. k1slot (board/ingenic/creality_k1/k1slot.c):
 *   select  reads the ota marker, applies the boot counter and exports
 *           k1_slot, k1_root, k1_mem, k1_lcm (from k1_lcm_id=auto|<n>)
 *   load    reads the slot's xImage (falls back to the other slot if the
 *           image header or CRC is bad)
 * The kernel command line is the stock one.
 */
#define CONFIG_BOOTARGS			""
#define CONFIG_BOOTCOMMAND		"run k1_boot"
#define CONFIG_EXTRA_ENV_SETTINGS \
	"loadaddr=0x81000000\0" \
	"verify=n\0" \
	"k1_bootlimit=3\0" \
	"k1_bootcount=0\0" \
	"k1_trial=0\0" \
	"k1_lcm_id=auto\0" \
	"k1_console=ttyS2,115200n8\0" \
	"k1_extra_args=\0" \
	"k1_wdt=0\0" \
	"k1_boot=k1slot select; k1slot load ${loadaddr} && " \
		"setenv bootargs console=${k1_console} mem=${k1_mem} lcm_id=${k1_lcm} " \
		"init=/linuxrc root=/dev/mmcblk0p${k1_root} rootwait rootfstype=squashfs ro k1_ubms=${k1_ms} ${k1_extra_args} && " \
		"bootm ${loadaddr}\0"

#endif /* __CONFIG_CREALITY_K1_H__ */
