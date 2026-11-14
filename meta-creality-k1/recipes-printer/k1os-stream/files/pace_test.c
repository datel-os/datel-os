/* Tries pace.h on made-up cameras: the picture loop of k1os-stream.c with a
 * clock that the test moves, and for comparison the timer that loop had
 * before.
 *
 *   cc -std=gnu11 -Wall -Wextra -O1 pace_test.c -o pace_test && ./pace_test
 *
 * MIT License, part of Datel OS. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "pace.h"

#define MS 1000000LL
#define S (1000 * MS)
#define NEVER INT64_MAX

struct cam {
	double fps;                     /* frames a second */
	int64_t grid;                   /* frames show up on multiples of this: a USB transfer of
	                                 * 32 packets ends every 4 ms, and a frame is there when
	                                 * the transfer with its last packet ends */
	int64_t stop_at, resume_at;     /* no frames from the one to the other */
	int64_t late_at, late_by;       /* the first frame from late_at on is held up */
	int64_t noise;                  /* each frame held up by 0 to this much, at random */
};

struct loop {
	int64_t busy;                   /* decode, overlay and encode of one picture */
	int64_t again;                  /* overlay and encode of a picture that is made again */
	int64_t block_at, block_for;    /* one picture that takes this much longer */
	int timer;                      /* the loop as it was: a timer, the newest frame at each tick */
};

struct result {
	long pictures, frames, repeats, lost;   /* lost: camera frames no picture was made of */
	long steps[4];                  /* pictures made of the next frame [1], the one after it [2], a later one [3] */
	int64_t max_age;                /* the oldest frame a picture was made of */
	int64_t min_gap, max_gap;       /* between two pictures */
};

/* When the camera's k-th frame is there; NEVER for a frame it does not give. */
static int64_t arrival(const struct cam *c, long k, uint32_t *rnd)
{
	int64_t ideal = (int64_t)(k * 1e9 / c->fps) + 3 * MS;
	int64_t t = ideal;

	if (c->resume_at && ideal >= c->stop_at && ideal < c->resume_at) {
		return NEVER;
	}
	if (c->late_by && ideal >= c->late_at && ideal < c->late_at + (int64_t)(1e9 / c->fps)) {
		t += c->late_by;
	}
	if (c->noise) {
		*rnd = *rnd * 1664525u + 1013904223u;
		t += (int64_t)(*rnd >> 8) % c->noise;
	}
	if (c->grid) {
		t = (t + c->grid - 1) / c->grid * c->grid;
	}
	return t;
}

/* Runs the loop until `until` and counts what happens from `from` on. */
static struct result run(unsigned fps, const struct cam *c, const struct loop *l, int64_t from, int64_t until)
{
	struct result r;
	struct pace p;
	uint32_t rnd = 12345;
	long k = 0, newest = 0, taken = 0;      /* frames are counted as they arrive, from 1 */
	int64_t next_at, newest_at = 0, now = 0, last_picture = -1, tick = 0;
	int blocked = 0;

	memset(&r, 0, sizeof r);
	r.min_gap = NEVER;
	pace_init(&p, fps, now);
	do {
		next_at = arrival(c, k++, &rnd);
	} while (next_at == NEVER);

	while (now < until) {
		enum pace_do what = PACE_WAIT;
		int waiting = 0;

		for (;;) {
			int64_t wait_ns = 0, timeout;
			int got = 0;
			/* src_fill(): every frame that has arrived by now */
			while (next_at <= now) {
				newest++;
				newest_at = next_at;
				got = 1;
				do {
					next_at = arrival(c, k++, &rnd);
				} while (next_at == NEVER);
			}
			waiting |= got;
			if (l->timer) {
				if (now >= tick) {
					what = waiting ? PACE_ARRIVED : PACE_REPEAT;
					break;
				}
				wait_ns = tick - now;
			} else {
				what = pace_next(&p, now, waiting, got, &wait_ns);
				if (what != PACE_WAIT) {
					break;
				}
			}
			/* poll(): whole milliseconds, rounded up as the loop asks for them */
			timeout = now + (wait_ns / MS + 1) * MS;
			/* the timer slept through arrivals, a frame ends the wait now */
			now = l->timer || next_at > timeout ? timeout : next_at;
		}

		if (what != PACE_REPEAT) {
			if (now >= from) {
				long step = newest - taken;
				r.frames++;
				r.lost += step - 1;
				r.steps[step > 3 ? 3 : step]++;
				if (now - newest_at > r.max_age) {
					r.max_age = now - newest_at;
				}
			}
			taken = newest;
		} else if (now >= from) {
			r.repeats++;
		}
		if (!l->timer) {
			pace_made(&p, now, what);
		}
		if (now >= from) {
			r.pictures++;
			if (last_picture >= 0) {
				int64_t gap = now - last_picture;
				if (gap < r.min_gap) {
					r.min_gap = gap;
				}
				if (gap > r.max_gap) {
					r.max_gap = gap;
				}
			}
			last_picture = now;
		}
		now += what == PACE_REPEAT ? l->again : l->busy;
		if (l->block_for && !blocked && now >= l->block_at) {
			now += l->block_for;
			blocked = 1;
		}
		if (l->timer) {
			tick += 1000000000LL / fps;
			if (now > tick + 1000000000LL / fps) {
				tick = now;
			}
		}
	}
	return r;
}

static int failures;

static void check(int ok, const char *what)
{
	if (!ok) {
		printf("    FAILED: %s\n", what);
		failures++;
	}
}

static struct result show(const char *name, unsigned fps, const struct cam *c, const struct loop *l,
                          int64_t from, int64_t until)
{
	struct result r = run(fps, c, l, from, until);
	printf("%-44s %5ld pictures, %5ld frames, %4ld repeats, %4ld lost, age up to %4.1f ms, "
	       "gaps %5.1f to %5.1f ms\n",
	       name, r.pictures, r.frames, r.repeats, r.lost, r.max_age / 1e6,
	       r.min_gap == NEVER ? 0.0 : r.min_gap / 1e6, r.max_gap / 1e6);
	return r;
}

int main(void)
{
	/* 7 ms to decode a frame and 14 ms to encode the picture; a picture that
	 * has not changed is encoded faster */
	const struct loop idle = { .busy = 21 * MS, .again = 12 * MS };
	struct cam k1 = { .fps = 30.03, .grid = 4 * MS };       /* the K1's camera */
	struct result r;

	/* What was wrong: the timer at 30.00 against the camera at 30.03. */
	{
		struct loop timer = idle;
		timer.timer = 1;
		r = show("timer 30, camera 30.03 (as it was)", 30, &k1, &timer, 3 * S, 123 * S);
		check(r.repeats > 40 && r.lost > 40, "the timer should lose frames and repeat pictures here");
	}

	/* The same camera, and one a little slow: every frame, once, as it comes. */
	r = show("30, camera 30.03", 30, &k1, &idle, 3 * S, 123 * S);
	check(r.repeats == 0 && r.lost == 0, "every frame once");
	check(r.max_age < 2 * MS, "frames are taken as they arrive");
	check(r.pictures >= 3602 && r.pictures <= 3605, "30.03 pictures a second");
	r = show("30, camera 30.03, the first 3 s", 30, &k1, &idle, 0, 3 * S);
	check(r.repeats == 0 && r.lost == 0, "nothing is lost while the pace settles");
	{
		struct cam c = k1;
		c.fps = 29.97;
		r = show("30, camera 29.97", 30, &c, &idle, 3 * S, 123 * S);
		check(r.repeats == 0 && r.lost == 0 && r.max_age < 2 * MS, "every frame once, as it arrives");
	}
	{
		struct cam c = k1;
		c.grid = 0;
		c.noise = 3 * MS;
		r = show("30, camera 30.03, held up 0 to 3 ms", 30, &c, &idle, 3 * S, 123 * S);
		check(r.repeats == 0 && r.lost == 0 && r.max_age < 2 * MS, "every frame once, as it arrives");
	}

	/* A frame that is held up does not cost a picture while it is inside
	 * the window; one that is later costs that frame, and no more. */
	{
		struct cam c = k1;
		c.late_at = 10 * S;
		c.late_by = 10 * MS;
		r = show("30, camera 30.03, one frame 10 ms late", 30, &c, &idle, 3 * S, 30 * S);
		check(r.repeats == 0 && r.lost == 0, "a frame 10 ms late is still taken");
		check(r.max_age < 12 * MS, "and the ones behind it wait a few ms at most");
		c.late_by = 25 * MS;
		r = show("30, camera 30.03, one frame 25 ms late", 30, &c, &idle, 3 * S, 30 * S);
		check(r.repeats <= 1 && r.lost <= 1, "a frame 25 ms late costs one picture");
	}

	/* A slower camera: its frames as they come, the last picture again in between. */
	{
		struct cam c = k1;
		c.fps = 15.015;
		r = show("30, camera 15.015", 30, &c, &idle, 3 * S, 123 * S);
		check(r.lost == 0 && r.max_age < 2 * MS, "every frame once, as it arrives");
		check(r.pictures >= 3540 && r.pictures <= 3670, "30 pictures a second");
		c.fps = 25;
		r = show("30, camera 25", 30, &c, &idle, 3 * S, 123 * S);
		check(r.lost == 0, "every frame once");
		check(r.pictures >= 3540 && r.pictures <= 3670, "30 pictures a second");
	}

	/* A faster camera: the pictures keep to their rate; of a camera twice
	 * as fast every second frame, as it comes. */
	r = show("15, camera 30.03", 15, &k1, &idle, 3 * S, 123 * S);
	check(r.repeats == 0 && r.steps[2] == r.frames, "every second frame");
	check(r.max_age < 2 * MS, "taken as it arrives");
	r = show("20, camera 30.03", 20, &k1, &idle, 3 * S, 123 * S);
	check(r.repeats == 0 && r.pictures >= 2360 && r.pictures <= 2440, "20 pictures a second");
	r = show("25, camera 30.03", 25, &k1, &idle, 3 * S, 123 * S);
	check(r.repeats == 0 && r.pictures >= 2950 && r.pictures <= 3050, "25 pictures a second, not the camera's 30");

	/* The camera stops and comes back: pictures go on at their rate, and
	 * its frames are picked up again. */
	{
		struct cam c = k1;
		c.stop_at = 10 * S;
		c.resume_at = 13 * S;
		r = show("30, camera gone (10 s to 13 s)", 30, &c, &idle, 10200 * MS, 12800 * MS);
		check(r.frames == 0 && r.pictures >= 76 && r.pictures <= 80, "30 pictures a second without a camera");
		check(r.min_gap > 30 * MS && r.max_gap < 37 * MS, "evenly");
		r = show("30, camera back (from 13 s)", 30, &c, &idle, 14 * S, 34 * S);
		check(r.repeats == 0 && r.lost == 0 && r.max_age < 2 * MS, "every frame once, as it arrives");
	}

	/* A loop that cannot keep up makes the pictures it can, of the newest
	 * frame each time, and does not make up for the ones it missed. */
	{
		struct loop slow = { .busy = 41 * MS, .again = 24 * MS };
		struct loop blocked = idle;
		r = show("30, camera 30.03, 41 ms a picture", 30, &k1, &slow, 3 * S, 123 * S);
		check(r.repeats == 0 && r.min_gap >= 41 * MS && r.max_gap < 50 * MS, "one picture after the other");
		blocked.block_at = 10 * S;
		blocked.block_for = 2 * S;
		r = show("30, camera 30.03, the loop held for 2 s", 30, &k1, &blocked, 12 * S, 12200 * MS);
		check(r.pictures <= 7 && r.repeats <= 1 && r.min_gap >= 21 * MS, "no burst of pictures afterwards");
		r = show("  the 3 s after that", 30, &k1, &blocked, 12200 * MS, 15 * S);
		check(r.repeats == 0 && r.lost == 0, "every frame once while the pace settles again");
		r = show("  and from then on", 30, &k1, &blocked, 15 * S, 45 * S);
		check(r.repeats == 0 && r.lost == 0 && r.max_age < 2 * MS, "every frame once, as it arrives");
	}

	if (failures) {
		printf("%d checks FAILED\n", failures);
		return 1;
	}
	printf("all checks passed\n");
	return 0;
}
