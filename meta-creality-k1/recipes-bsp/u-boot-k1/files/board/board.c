/*
 * Creality K1 (Ingenic X2000-V12) board setup for K1 OS
 *
 * Based on board/ingenic/x2000_base/board.c,
 * Copyright (c) 2013 Ingenic Semiconductor Co.,Ltd
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of
 * the License, or (at your option) any later version.
 */

#include <common.h>
#include <nand.h>
#include <net.h>
#include <netdev.h>
#include <asm/gpio.h>
#include <asm/arch/cpm.h>
#include <asm/arch/clk.h>
#include <asm/arch/mmc.h>

int board_early_init_f(void)
{
	return 0;
}

int board_early_init_r(void)
{
	return 0;
}

int misc_init_r(void)
{
	return 0;
}

#ifdef CONFIG_MMC
extern void jz_mmc_init(void);
int board_mmc_init(bd_t *bd)
{
	jz_mmc_init();
	return 0;
}
#endif

#ifdef CONFIG_SYS_NAND_SELF_INIT
void board_nand_init(void)
{
	return;
}
#endif

int board_eth_init(bd_t *bis)
{
	return 0;
}

int checkboard(void)
{
	puts("Board: Creality K1 mainboard (Ingenic XBurst2 X2000-V12 SoC), K1 OS U-Boot\n");
	return 0;
}

#ifdef CONFIG_SPL_BUILD
void spl_board_init(void)
{
}
#endif /* CONFIG_SPL_BUILD */
