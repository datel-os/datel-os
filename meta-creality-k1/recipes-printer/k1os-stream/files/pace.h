/* k1os-stream's pace: when the next picture is made, and of what.
 *
 * Pictures go out --fps times a second, but the camera keeps its own time.
 * A timer of 30.00 ticks a second against a camera that gives 30.03 frames
 * drifts through one frame period every 35 s, and while the two are close
 * one tick finds no new frame and the next finds two: about 28 pictures
 * shown twice and 28 frames lost, two seconds of judder every 35 s.
 *
 * So the camera sets the time. A picture is due one period after the last.
 * A frame that arrives within a quarter period of that moment becomes the
 * picture at once, and the due time follows the arrivals, by at most 1/64
 * of a period per picture, until they lie half a window before it. A frame
 * that arrives earlier than the window (a camera faster than the pictures)
 * waits for the due time, and the newest one is taken then; of a camera
 * twice as fast every second frame arrives inside the window, and those are
 * the ones taken. With no frame by the end of the window (a slower camera,
 * or none) the last picture is made again, which keeps the stream and the
 * overlay going. The bound on following keeps the rate at --fps: a camera
 * at 30 does not turn pictures asked for at 25 into 30.
 *
 * Nothing here reads a clock or waits. The caller passes the time, so the
 * rules can be tried on made-up cameras: pace_test.c.
 *
 * MIT License, part of Datel OS. */
#ifndef K1OS_PACE_H
#define K1OS_PACE_H

#include <stdint.h>

struct pace {
	int64_t period;     /* between two pictures, in ns */
	int64_t tol;        /* half the window around the due time */
	int64_t slew;       /* the most the due time follows the camera, per picture */
	int64_t due;        /* when the next picture is due */
};

enum pace_do {
	PACE_WAIT,          /* nothing yet: wait for a frame, at most *wait_ns */
	PACE_ARRIVED,       /* a picture of the frame that has just come */
	PACE_WAITED,        /* a picture of the frame that came early and waited */
	PACE_REPEAT         /* no frame in time: the last picture again */
};

static inline void pace_init(struct pace *p, unsigned fps, int64_t now)
{
	p->period = 1000000000LL / fps;
	p->tol = p->period / 4;
	p->slew = p->period / 64;
	p->due = now;
}

/* What to do at the time `now`. waiting: a frame has come that no picture
 * was made of; arrived: it came since the call before this one. Changes
 * nothing: pace_made() does, once the picture is certain. */
static inline enum pace_do pace_next(const struct pace *p, int64_t now, int waiting, int arrived,
                                     int64_t *wait_ns)
{
	if (waiting) {
		if (now > p->due + p->tol) {
			/* the caller comes late, the frame has waited for it */
			return PACE_WAITED;
		}
		if (arrived && now >= p->due - p->tol) {
			return PACE_ARRIVED;
		}
		if (now >= p->due) {
			return PACE_WAITED;
		}
		*wait_ns = p->due - now;
		return PACE_WAIT;
	}
	if (now >= p->due + p->tol) {
		return PACE_REPEAT;
	}
	*wait_ns = p->due + p->tol - now;
	return PACE_WAIT;
}

/* A picture was made at `now` as pace_next() said: moves the due time on. */
static inline void pace_made(struct pace *p, int64_t now, enum pace_do what)
{
	int64_t step = 0;

	if (what == PACE_ARRIVED) {
		/* Arrivals are held half a window before the due time: a frame is
		 * held up now and then, it never comes ahead of time, so the room
		 * belongs behind the arrival. */
		step = now - (p->due - p->tol / 2);
		if (step > p->slew) {
			step = p->slew;
		}
		if (step < -p->slew) {
			step = -p->slew;
		}
	} else if (what == PACE_WAITED) {
		/* toward the frame that had to wait */
		step = -p->slew;
	}
	p->due += p->period + step;
	if (p->due < now) {
		/* the caller cannot keep up: no burst of pictures to catch up */
		p->due = now + p->period;
	}
}

#endif
