/*
 * k1slot: A/B slot selection, boot counter and kernel loading for the
 * Creality K1 (K1 OS U-Boot).
 *
 * The printer has two sets of partitions on the eMMC (sector numbers from
 * the stock GPT):
 *   slot 1: kernel  = p5 at sector 22528, rootfs  = p7
 *   slot 2: kernel2 = p6 at sector 38912, rootfs2 = p8
 * The active slot is named by a text marker in the ota partition (p1,
 * sector 2048): "ota:kernel" or "ota:kernel2". The stock SPL reads the same
 * marker, so both bootloaders agree on what the slots mean.
 *
 * What stock lacks is a boot counter: when k1_trial=1 in the environment,
 * every boot increments k1_bootcount and saves the environment; once it
 * passes k1_bootlimit the marker is pointed at the other slot and the trial
 * is cleared. A system that comes up far enough resets the counter with
 *   fw_setenv k1_trial 0; fw_setenv k1_bootcount 0
 * (k1os-slot does this on K1 OS). Stock firmware never touches the counter,
 * which is fine because nothing sets k1_trial=1 for it.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of
 * the License, or (at your option) any later version.
 */

#include <common.h>
#include <command.h>
#include <mmc.h>
#include <image.h>
#include <asm/io.h>

DECLARE_GLOBAL_DATA_PTR;

#define K1_SEC_OTA		2048
#define K1_SEC_KERNEL1		22528
#define K1_SEC_KERNEL2		38912
#define K1_KERNEL_SECTORS	16384	/* 8 MiB partitions */

#ifndef CONFIG_K1_LCM_DEFAULT
#define CONFIG_K1_LCM_DEFAULT	0
#endif

extern int saveenv(void);

static struct mmc *k1_mmc(void)
{
	struct mmc *mmc = find_mmc_device(0);

	if (!mmc) {
		printf("k1slot: no mmc device 0\n");
		return NULL;
	}
	if (mmc_init(mmc)) {
		printf("k1slot: mmc 0 init failed\n");
		return NULL;
	}
	return mmc;
}

/* 1 or 2 from the marker, 0 for an unknown text, -1 on a read error */
static int k1_read_marker(struct mmc *mmc)
{
	ALLOC_CACHE_ALIGN_BUFFER(char, buf, 512);

	if (mmc->block_dev.block_read(0, K1_SEC_OTA, 1, buf) != 1)
		return -1;
	buf[511] = 0;
	if (!strncmp(buf, "ota:kernel2", 11))
		return 2;
	if (!strncmp(buf, "ota:kernel", 10))
		return 1;
	return 0;
}

static int k1_write_marker(struct mmc *mmc, int slot)
{
	ALLOC_CACHE_ALIGN_BUFFER(char, buf, 512);

	/* Same 512-byte block stock and k1os-slot write: text, two newlines, zeros. */
	memset(buf, 0, 512);
	strcpy(buf, slot == 2 ? "ota:kernel2\n\n" : "ota:kernel\n\n");
	if (mmc->block_dev.block_write(0, K1_SEC_OTA, 1, buf) != 1) {
		printf("k1slot: writing the ota marker failed\n");
		return -1;
	}
	printf("k1slot: ota marker now names slot %d\n", slot);
	return 0;
}

static int k1_other(int slot)
{
	return slot == 2 ? 1 : 2;
}

static void k1_export(int slot)
{
	setenv_ulong("k1_slot", slot);
	setenv_ulong("k1_root", slot == 2 ? 8 : 7);
}

/* mem=...: what the SPL found, capped at the 256 MiB the kernel maps at 0. */
static void k1_export_mem(void)
{
	char buf[32];
	unsigned long mb = gd->ram_size >> 20;

	if (mb == 0 || mb > 256)
		mb = 256;
	sprintf(buf, "%luM@0x0", mb);
	setenv("k1_mem", buf);
}

/*
 * lcm_id: left at CONFIG_K1_LCM_INFO_ADDR by the SPL after the RTOS ran.
 * k1_lcm_id in the environment is "auto" (use what the RTOS reported, or
 * k1_lcm_default when it reported nothing) or a fixed number. The result goes
 * to the run-time variable k1_lcm, so a later saveenv never freezes a detected
 * value into k1_lcm_id.
 */
static void k1_export_lcm(void)
{
	const char *cur = getenv("k1_lcm_id");
	unsigned long id = 0;
	int reported = 0;

#ifdef CONFIG_K1_LCM_INFO_ADDR
	if (readl(CONFIG_K1_LCM_INFO_ADDR) == CONFIG_K1_LCM_MAGIC) {
		id = readl(CONFIG_K1_LCM_INFO_ADDR + 4);
		reported = 1;
	}
#endif
	setenv_ulong("k1_lcm_detected", reported ? id : 0);
	if (cur && strcmp(cur, "auto")) {
		setenv("k1_lcm", cur);	/* fixed by the user */
		return;
	}
	if (!reported || id == 0)
		id = getenv_ulong("k1_lcm_default", 10, CONFIG_K1_LCM_DEFAULT);
	setenv_ulong("k1_lcm", id);
}

static int k1_select(struct mmc *mmc)
{
	int marker = k1_read_marker(mmc);
	int slot = marker > 0 ? marker : 1;
	unsigned long trial = getenv_ulong("k1_trial", 10, 0);
	unsigned long count = getenv_ulong("k1_bootcount", 10, 0);
	unsigned long limit = getenv_ulong("k1_bootlimit", 10, 3);
	int save = 0;

	if (marker <= 0)
		printf("k1slot: ota marker %s, using slot 1\n",
		       marker < 0 ? "unreadable" : "unknown");

	/* First run on a printer with no saved environment: store the
	 * built-in defaults so that fw_setenv in Linux finds a valid one. */
	if (!getenv("k1_env_saved")) {
		setenv("k1_env_saved", "1");
		save = 1;
	}

	if (trial) {
		count++;
		if (limit && count > limit) {
			int other = k1_other(slot);

			printf("k1slot: slot %d did not confirm in %lu boots, "
			       "falling back to slot %d\n", slot, limit, other);
			if (k1_write_marker(mmc, other) == 0)
				slot = other;
			setenv_ulong("k1_fallback_from", marker);
			setenv("k1_trial", "0");
			count = 0;
		} else {
			printf("k1slot: trial boot %lu of %lu for slot %d\n",
			       count, limit, slot);
		}
		setenv_ulong("k1_bootcount", count);
		save = 1;
	}

	if (save && saveenv())
		printf("k1slot: saving the environment failed\n");

	k1_export(slot);
	k1_export_mem();
	k1_export_lcm();
	printf("k1slot: booting slot %d (root mmcblk0p%s, mem %s, lcm_id %s)\n",
	       slot, getenv("k1_root"), getenv("k1_mem"), getenv("k1_lcm"));
	return 0;
}

/* Read the slot's xImage (legacy uImage) into addr; try the other slot if
 * its header or data CRC is bad. */
static int k1_load_one(struct mmc *mmc, int slot, ulong addr)
{
	ulong sec = slot == 2 ? K1_SEC_KERNEL2 : K1_SEC_KERNEL1;
	image_header_t *hdr = (image_header_t *)addr;
	ulong size, sectors;

	if (mmc->block_dev.block_read(0, sec, 1, hdr) != 1) {
		printf("k1slot: slot %d: cannot read the kernel header\n", slot);
		return -1;
	}
	if (!image_check_magic(hdr) || !image_check_hcrc(hdr)) {
		printf("k1slot: slot %d: no valid image header\n", slot);
		return -1;
	}
	size = image_get_image_size(hdr);
	sectors = (size + 511) / 512;
	if (sectors > K1_KERNEL_SECTORS) {
		printf("k1slot: slot %d: image of %lu bytes does not fit the partition\n",
		       slot, size);
		return -1;
	}
	if (mmc->block_dev.block_read(0, sec, sectors, hdr) != sectors) {
		printf("k1slot: slot %d: kernel read failed\n", slot);
		return -1;
	}
	if (!image_check_dcrc(hdr)) {
		printf("k1slot: slot %d: kernel data CRC error\n", slot);
		return -1;
	}
	printf("k1slot: slot %d: %s, %lu bytes at 0x%08lx\n",
	       slot, image_get_name(hdr), size, addr);
	setenv_hex("filesize", size);
	return 0;
}

static int k1_load(struct mmc *mmc, ulong addr)
{
	int slot = getenv_ulong("k1_slot", 10, 0);

	if (slot != 1 && slot != 2) {
		slot = k1_read_marker(mmc);
		if (slot <= 0)
			slot = 1;
		k1_export(slot);
	}
	if (k1_load_one(mmc, slot, addr) == 0)
		return 0;
	printf("k1slot: trying slot %d instead\n", k1_other(slot));
	if (k1_load_one(mmc, k1_other(slot), addr) == 0) {
		k1_export(k1_other(slot));
		return 0;
	}
	return 1;
}

static int k1_status(struct mmc *mmc)
{
	int marker = k1_read_marker(mmc);

	printf("ota marker:   %s\n", marker == 2 ? "ota:kernel2 (slot 2)" :
	       marker == 1 ? "ota:kernel (slot 1)" : "unknown");
	printf("k1_trial:     %s\n", getenv("k1_trial") ? getenv("k1_trial") : "0");
	printf("k1_bootcount: %s of k1_bootlimit %s\n",
	       getenv("k1_bootcount") ? getenv("k1_bootcount") : "0",
	       getenv("k1_bootlimit") ? getenv("k1_bootlimit") : "3");
#ifdef CONFIG_K1_LCM_INFO_ADDR
	if (readl(CONFIG_K1_LCM_INFO_ADDR) == CONFIG_K1_LCM_MAGIC)
		printf("lcm_id:       %u (from the RTOS)\n",
		       readl(CONFIG_K1_LCM_INFO_ADDR + 4));
	else
		printf("lcm_id:       not reported by the SPL\n");
#endif
	return 0;
}

static int do_k1slot(cmd_tbl_t *cmdtp, int flag, int argc, char * const argv[])
{
	struct mmc *mmc = k1_mmc();

	if (!mmc)
		return 1;

	if (argc < 2 || !strcmp(argv[1], "status"))
		return k1_status(mmc);

	if (!strcmp(argv[1], "select"))
		return k1_select(mmc);

	if (!strcmp(argv[1], "load")) {
		ulong addr = argc > 2 ? simple_strtoul(argv[2], NULL, 16)
				      : getenv_ulong("loadaddr", 16, CONFIG_SYS_LOAD_ADDR);
		return k1_load(mmc, addr);
	}

	if (!strcmp(argv[1], "marker")) {
		int slot;

		if (argc < 3) {
			slot = k1_read_marker(mmc);
			printf("%d\n", slot);
			return slot > 0 ? 0 : 1;
		}
		slot = simple_strtoul(argv[2], NULL, 10);
		if (slot != 1 && slot != 2)
			return CMD_RET_USAGE;
		if (k1_write_marker(mmc, slot))
			return 1;
		/* A slot switched to from here is on trial until it confirms. */
		setenv("k1_trial", "1");
		setenv("k1_bootcount", "0");
		return saveenv() ? 1 : 0;
	}

	if (!strcmp(argv[1], "confirm")) {
		setenv("k1_trial", "0");
		setenv("k1_bootcount", "0");
		return saveenv() ? 1 : 0;
	}

	return CMD_RET_USAGE;
}

U_BOOT_CMD(
	k1slot, 3, 0, do_k1slot,
	"Creality K1 A/B slot selection",
	"status          - show the ota marker and the boot counter\n"
	"k1slot select          - pick the slot (marker + counter); sets k1_slot, k1_root, k1_mem, k1_lcm\n"
	"k1slot load [addr]     - read the slot's xImage to addr (default ${loadaddr})\n"
	"k1slot marker [1|2]    - show or set the ota marker (setting starts a trial)\n"
	"k1slot confirm         - end the trial: k1_trial=0, k1_bootcount=0, saveenv"
);
