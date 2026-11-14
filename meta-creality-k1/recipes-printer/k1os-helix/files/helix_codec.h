/* The X2000 Helix video codec for a stream of pictures of one size: a JPEG
 * decoder into one NV12 frame and an H.264 encoder that reads it. The code
 * is Zig (helix_codec.zig and what it imports, built into one object with
 * helix_c.zig) and runs the codec through /dev/helix.
 *
 * MIT License, part of Datel OS. */
#ifndef HELIX_CODEC_H
#define HELIX_CODEC_H

#include <stddef.h>
#include <stdint.h>
#include <sys/uio.h>

struct helix_codec;

/* width and height are multiples of 16; level is the H.264 level_idc (31 for
 * level 3.1). One codec at a time. NULL when the codec or its memory is not
 * to be had; the reason goes to stderr. */
struct helix_codec *helix_codec_open(unsigned width, unsigned height, unsigned level,
                                     int qp_min, int qp_max);
void helix_codec_close(struct helix_codec *c);

/* The frame: the luma plane and the interleaved chroma plane, rows of
 * `width` bytes. Ordinary memory to the program, but the codec reads and
 * writes it behind the caches' back: the program may read and write only
 * rows it has named with helix_codec_draws(), and only between a decode and
 * the next encode. */
uint8_t *helix_codec_luma(struct helix_codec *c);
uint8_t *helix_codec_chroma(struct helix_codec *c);
/* Names luma rows y0 to y1-1 (and the chroma rows under them) as rows the
 * program draws into or reads. Before the first decode. */
void helix_codec_draws(struct helix_codec *c, unsigned y0, unsigned y1);

/* Decodes a JPEG picture into the frame. 1: done. 0: the picture was left
 * out, helix_codec_why() says why; the frame is as it was, or holds no
 * picture at all when the codec gave up on it. -1: the codec is not working. */
int helix_codec_decode(struct helix_codec *c, const uint8_t *jpeg, size_t len);

/* Encodes the frame at quantiser qp; key != 0 asks for a key picture (the
 * first picture is one anyway). Returns how many of iov[0..1] hold the
 * picture, as Annex B and valid until the next call: a key picture starts
 * with its parameter sets. 0: no picture this time (helix_codec_why()), the
 * next one will be a key picture. -1: the codec is not working. */
int helix_codec_encode(struct helix_codec *c, int key, int qp, struct iovec *iov);

/* Why the last decode or encode returned 0 or -1. */
const char *helix_codec_why(void);

#endif
