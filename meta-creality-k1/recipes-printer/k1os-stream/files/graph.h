/* k1os-stream: graph panel (temperature history, progress bar) drawn into an
 * NV12 frame. MIT License, part of Datel OS. */
#ifndef K1OS_GRAPH_H
#define K1OS_GRAPH_H

#include <stdint.h>

#include "moonraker.h"
#include "sysstat.h"

#define GRAPH_W 320
#define GRAPH_H 128

enum graph_corner { GRAPH_TL, GRAPH_TR, GRAPH_BL, GRAPH_BR };

struct graph {
	unsigned x0, y0;            /* panel position in the frame: x0 a multiple of 4, y0 even */
	unsigned stride;            /* frame width */
	/* The panel, rendered once a second: opaque pixels have 0xff in mask,
	 * and in uvmask in both bytes of their U V pair; the rest shows the
	 * darkened camera picture. graph_blit() reads them four bytes at a time. */
	uint8_t luma[GRAPH_W * GRAPH_H] __attribute__((aligned(4)));
	uint8_t mask[GRAPH_W * GRAPH_H] __attribute__((aligned(4)));
	uint8_t uv[GRAPH_W * GRAPH_H / 2] __attribute__((aligned(4)));      /* interleaved U V, GRAPH_W bytes a row */
	uint8_t uvmask[GRAPH_W * GRAPH_H / 2] __attribute__((aligned(4)));  /* laid out as uv */
};

/* Place the panel in a corner of a width x height frame, above a bottom
 * bar of bar_h rows. Returns -1 when the frame is too small. */
int graph_init(struct graph *g, unsigned width, unsigned height, unsigned bar_h,
               enum graph_corner corner);
/* Place a second panel of the same size next to `other`: under it, or above
 * it when there is no room below (bottom corners). Returns -1 when neither fits. */
int graph_init_beside(struct graph *g, const struct graph *other, unsigned height, unsigned bar_h);
/* Render the statistics panel: temperatures the graph does not show, speed
 * and flow, Z and fan, the printer's CPU and memory, Wi-Fi and the stream's
 * bitrate (kbit <= 0: not known yet). Once a second. */
void stats_render(struct graph *g, const struct printer_state *st, const struct sys_stats *sys,
                  double kbit);
/* Render the panel from the latest state and history (once a second). */
void graph_render(struct graph *g, const struct printer_state *st, const struct temp_history *h);
/* Compose the panel into the frame whose planes are y and uv. fresh = 1 when
 * the frame holds a newly decoded picture: the picture under the panel is
 * darkened and the panel drawn over it. fresh = 0 when the same frame is
 * shown again: it still holds the composed panel and is left as it is, so a
 * panel rendered in between appears with the next new picture. */
void graph_blit(const struct graph *g, int fresh, uint8_t *y, uint8_t *uv);

#endif
