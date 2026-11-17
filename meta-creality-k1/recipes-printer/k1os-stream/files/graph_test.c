/* Checks the panels' blit in graph.c: the darkening a word at a time equals
 * the formulas a byte at a time for every value in every byte, and composing
 * both panels a word at a time gives the frame that the byte-at-a-time code
 * gives, in every corner and for panels of several printer states.
 *
 *   cc -std=gnu11 -Wall -Wextra -O1 graph_test.c overlay.c -o graph_test && ./graph_test
 *
 * MIT License, part of Datel OS. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "graph.c"

#define W 1280
#define H 720
#define STATUS_BAR 40

static unsigned failures;
static uint32_t seed = 0x2545f491u;

static uint32_t rnd(void)
{
	seed ^= seed << 13;
	seed ^= seed >> 17;
	seed ^= seed << 5;
	return seed;
}

static void check(int ok, const char *what, unsigned a, unsigned b)
{
	if (!ok && failures++ < 10) {
		fprintf(stderr, "FAIL %s (%u, %u)\n", what, a, b);
	}
}

static void test_darkening(void)
{
	static const uint32_t around[] = { 0x00000000u, 0xffffffffu, 0x80808080u, 0x7f7f7f7fu,
	                                   0x0f0f0f0fu, 0xf0f0f0f0u, 0x10101010u, 0xefefefefu };
	const unsigned fixed = sizeof around / sizeof around[0];
	unsigned p, k, i, j, words = 0;

	for (p = 0; p < 256; p++) {
		for (k = 0; k < 4; k++) {
			for (i = 0; i < fixed + 32; i++) {
				uint32_t w = i < fixed ? around[i] : rnd();
				uint32_t l, c;
				w = (w & ~(0xffu << (8 * k))) | (uint32_t)p << (8 * k);
				l = dark_luma4(w);
				c = dark_chroma4(w);
				for (j = 0; j < 4; j++) {
					uint8_t b = (uint8_t)(w >> (8 * j));
					check((uint8_t)(l >> (8 * j)) == dark_luma(b), "luma darkening", b, j);
					check((uint8_t)(c >> (8 * j)) == dark_chroma(b), "chroma darkening", b, j);
				}
				words++;
			}
		}
	}
	printf("darkening: %u words, every value in every byte\n", words);
}

static void make_state(struct printer_state *st, unsigned round)
{
	static const char *const states[] = { "printing", "paused", "complete", "standby",
	                                      "cancelled", "error", "printing", "printing" };
	memset(st, 0, sizeof *st);
	st->valid = round % 8 != 5;
	snprintf(st->state, sizeof st->state, "%s", states[round % 8]);
	st->progress = (double)(rnd() % 1001) / 1000.0;
	st->print_duration = rnd() % 20000;
	st->nozzle = 20 + rnd() % 260;
	st->nozzle_target = rnd() % 2 ? 220 : 0;
	st->bed = 20 + rnd() % 90;
	st->bed_target = rnd() % 2 ? 60 : 0;
	st->have_chamber = st->have_mcu_temp = st->have_motion = st->have_fan = round % 3 != 0;
	st->chamber = 31;
	st->mcu_temp = 40 + rnd() % 40;
	st->speed = rnd() % 801;
	st->flow = rnd() % 30;
	st->z = (rnd() % 30000) / 100.0;
	st->fan = (rnd() % 101) / 100.0;
}

static void make_history(struct temp_history *h)
{
	unsigned i;
	h->n = 300 + rnd() % (HISTORY_N - 299);
	for (i = 0; i < h->n; i++) {
		h->nozzle[i] = (int16_t)(rnd() % 13 == 0 ? TEMP_NONE : (int16_t)(200 + rnd() % 2600));
		h->nozzle_target[i] = (int16_t)(i % 400 < 200 ? 2200 : 0);
		h->bed[i] = (int16_t)(200 + rnd() % 900);
		h->bed_target[i] = 600;
	}
}

static void fill(uint8_t *b, size_t n)
{
	size_t i;
	for (i = 0; i < n; i++) {
		b[i] = (uint8_t)rnd();
	}
}

/* what graph_blit() must give: each panel byte at a time */
static void reference(const struct graph *g, uint8_t *y, uint8_t *uv)
{
	blit_bytes(y + (size_t)g->y0 * g->stride + g->x0, g->stride, GRAPH_H, g->luma, g->mask, 0);
	blit_bytes(uv + (size_t)(g->y0 / 2) * g->stride + g->x0, g->stride, GRAPH_H / 2, g->uv,
	           g->uvmask, 1);
}

static void test_blit(void)
{
	static uint8_t y1[W * H] __attribute__((aligned(16))), uv1[W * H / 2] __attribute__((aligned(16)));
	static uint8_t y2[W * H] __attribute__((aligned(16))), uv2[W * H / 2] __attribute__((aligned(16)));
	static struct graph gr, sp;
	static struct temp_history hist;
	struct printer_state st;
	struct sys_stats sys = { 37, 120, 230, -55 };
	unsigned corner, round, frames = 0;

	for (corner = GRAPH_TL; corner <= GRAPH_BR; corner++) {
		if (graph_init(&gr, W, H, STATUS_BAR, (enum graph_corner)corner) < 0 ||
		    graph_init_beside(&sp, &gr, H, STATUS_BAR) < 0) {
			check(0, "panels placed", corner, 0);
			continue;
		}
		check(gr.x0 % 4 == 0 && sp.x0 % 4 == 0, "panels on whole words", gr.x0, sp.x0);
		for (round = 0; round < 16; round++) {
			make_state(&st, round);
			make_history(&hist);
			graph_render(&gr, &st, &hist);
			stats_render(&sp, &st, &sys, round % 4 ? 2100.0 : 0.0);

			fill(y1, sizeof y1);
			fill(uv1, sizeof uv1);
			memcpy(y2, y1, sizeof y1);
			memcpy(uv2, uv1, sizeof uv1);
			graph_blit(&gr, 1, y1, uv1);
			graph_blit(&sp, 1, y1, uv1);
			reference(&gr, y2, uv2);
			reference(&sp, y2, uv2);
			check(!memcmp(y1, y2, sizeof y1), "luma plane", corner, round);
			check(!memcmp(uv1, uv2, sizeof uv1), "chroma plane", corner, round);

			/* a frame shown again keeps what was composed into it, even
			 * when the panels were rendered in between */
			stats_render(&sp, &st, &sys, 1234.0);
			graph_blit(&gr, 0, y1, uv1);
			graph_blit(&sp, 0, y1, uv1);
			check(!memcmp(y1, y2, sizeof y1) && !memcmp(uv1, uv2, sizeof uv1),
			      "repeated frame untouched", corner, round);
			frames++;
		}
	}
	printf("blit: %u frames with both panels, 4 corners\n", frames);
}

/* a frame whose rows are not whole words goes the byte way */
static void test_odd_stride(void)
{
	static uint8_t y1[1282 * H + 2], uv1[1282 * H / 2 + 2], y2[1282 * H + 2], uv2[1282 * H / 2 + 2];
	static struct graph gr;
	static struct temp_history hist;
	struct printer_state st;

	if (graph_init(&gr, 1282, H, STATUS_BAR, GRAPH_TL) < 0) {
		check(0, "odd stride placed", 0, 0);
		return;
	}
	make_state(&st, 0);
	make_history(&hist);
	graph_render(&gr, &st, &hist);
	fill(y1, sizeof y1);
	fill(uv1, sizeof uv1);
	memcpy(y2, y1, sizeof y1);
	memcpy(uv2, uv1, sizeof uv1);
	graph_blit(&gr, 1, y1, uv1);
	reference(&gr, y2, uv2);
	check(!memcmp(y1, y2, sizeof y1) && !memcmp(uv1, uv2, sizeof uv1), "odd stride", 0, 0);
	printf("blit: a frame 1282 wide, byte by byte\n");
}

int main(void)
{
	test_darkening();
	test_blit();
	test_odd_stride();
	if (failures) {
		printf("%u failures\n", failures);
		return 1;
	}
	printf("all good\n");
	return 0;
}
