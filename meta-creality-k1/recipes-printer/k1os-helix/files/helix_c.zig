//! The codec for C programs: helix_codec.h. k1os-stream's camera pipeline is
//! C and gets its pictures decoded and encoded here.
const std = @import("std");
const codec = @import("helix_codec.zig");

const Iovec = extern struct { base: ?[*]const u8, len: usize };
extern fn dprintf(fd: c_int, fmt: [*:0]const u8, ...) c_int;

// One codec at a time, and no allocator needed for it.
var the_codec: codec.Codec = undefined;
var in_use = false;
var why: [*:0]const u8 = "";

export fn helix_codec_open(width: c_uint, height: c_uint, level: c_uint, qp_min: c_int, qp_max: c_int) ?*codec.Codec {
    if (in_use) {
        _ = dprintf(2, "helix: the codec is open already\n");
        return null;
    }
    the_codec = codec.Codec.open(.{
        .width = width,
        .height = height,
        .level = @intCast(@min(level, 255)),
        .min_qp = @intCast(std.math.clamp(qp_min, 0, 51)),
        .max_qp = @intCast(std.math.clamp(qp_max, 0, 51)),
    }) catch |e| {
        _ = dprintf(2, "helix: no codec for %ux%u: %s\n", width, height, @errorName(e).ptr);
        return null;
    };
    in_use = true;
    return &the_codec;
}

export fn helix_codec_close(c: ?*codec.Codec) void {
    if (c) |open| {
        open.close();
        in_use = false;
    }
}

export fn helix_codec_luma(c: *codec.Codec) [*]u8 {
    return c.luma.bytes.ptr;
}

export fn helix_codec_chroma(c: *codec.Codec) [*]u8 {
    return c.chroma.bytes.ptr;
}

export fn helix_codec_draws(c: *codec.Codec, y0: c_uint, y1: c_uint) void {
    c.drawsRows(y0, y1);
}

export fn helix_codec_decode(c: *codec.Codec, jpeg: [*]const u8, len: usize) c_int {
    c.decode(jpeg[0..len]) catch |e| {
        why = @errorName(e).ptr;
        return switch (e) {
            // the picture's fault, or the codec's with this one picture
            error.Truncated, error.Unsupported, error.Corrupt, error.TooLarge => 0,
            error.WrongSize, error.CutOff, error.TooLong, error.CodecError => 0,
            else => -1,
        };
    };
    return 1;
}

export fn helix_codec_encode(c: *codec.Codec, key: c_int, qp: c_int, iov: *[2]Iovec) c_int {
    const picture = c.encode(key != 0, @intCast(std.math.clamp(qp, 0, 51))) catch |e| {
        why = @errorName(e).ptr;
        return switch (e) {
            error.NoFrame, error.TooLong, error.CodecError => 0,
            else => -1,
        };
    };
    var n: usize = 0;
    if (picture.sets.len != 0) {
        iov[n] = .{ .base = picture.sets.ptr, .len = picture.sets.len };
        n += 1;
    }
    iov[n] = .{ .base = picture.slice.ptr, .len = picture.slice.len };
    return @intCast(n + 1);
}

export fn helix_codec_why() [*:0]const u8 {
    return why;
}
