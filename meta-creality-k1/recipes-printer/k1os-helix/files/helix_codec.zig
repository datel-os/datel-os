//! A JPEG decoder and an H.264 encoder on the Helix for pictures of one size:
//! what the camera stream and the timelapse both do with the codec.
//!
//! One picture at a time: `decode` turns a JPEG into the frame (NV12, one
//! row of `width` bytes after another), the program may draw into the rows it
//! has named with `drawsRows`, and `encode` makes the frame an H.264 picture.
//! Everything else the codec needs (the chain, its copy of the last two
//! pictures, its scratch memory, the output) is kept here.
const std = @import("std");
const helix = @import("helix.zig");
const jpeg = @import("helix_jpeg.zig");
const h264 = @import("helix_h264.zig");

pub const Options = struct {
    /// multiples of 16
    width: u32,
    height: u32,
    /// level_idc of the H.264 stream: 31 is level 3.1
    level: u8 = 31,
    min_qp: u8 = 18,
    max_qp: u8 = 45,
    /// only `decode` will be used: the encoder's memory is not taken
    decode_only: bool = false,
};

pub const OpenError = helix.Error || error{
    /// not a size the codec is run with here
    BadSize,
};

pub const DecodeError = jpeg.Error || helix.Error || helix.ChainError || error{
    /// a picture of another size than the codec was opened for
    WrongSize,
    /// the picture's data ends before the picture does
    CutOff,
    /// more data than a picture of this size is given room for
    TooLong,
    /// the codec gave the picture up; the frame holds no picture now
    CodecError,
};

pub const EncodeError = helix.Error || h264.Error || error{
    /// nothing was decoded, or the last decode failed
    NoFrame,
    /// the codec wrote more than the output has room for
    TooLong,
    /// the codec gave the picture up
    CodecError,
};

/// An encoded picture: the parameter sets (only in front of a key picture)
/// and the slice, both valid until the next `encode`.
pub const Picture = struct {
    sets: []const u8,
    slice: []const u8,
    key: bool,

    pub fn bytes(p: Picture) usize {
        return p.sets.len + p.slice.len;
    }
};

const max_bands = 4;

pub const Codec = struct {
    dev: helix.Device,
    cfg: h264.Config,
    decode_only: bool,

    chain: helix.Dma,
    /// the entropy-coded data of the JPEG being decoded
    data: helix.Dma,
    luma: helix.Dma,
    chroma: helix.Dma,
    /// the encoder's own copies of the last two pictures, luma and chroma
    recon: [2][2]helix.Dma = undefined,
    out: helix.Dma = undefined,
    work: helix.Dma = undefined,

    /// rows the program draws into, and the same as ranges of both planes
    bands: [max_bands][2]u32 = undefined,
    bands_n: usize = 0,
    drawn: [2 * max_bands]helix.Dma = undefined,
    drawn_n: usize = 0,

    frame_valid: bool = false,
    /// pictures since the last key picture; 0: the next one is a key picture
    number: u32 = 0,
    idr_id: u1 = 0,
    /// which of `recon` the next picture is written to
    cur: u1 = 0,
    /// how much of `out` the program has read since the codec last wrote it
    out_seen: usize = helix.buffer_align,
    sets: [h264.parameter_sets_max]u8 = undefined,
    sets_len: usize = 0,
    /// the codec's status after a CodecError
    last_status: u32 = 0,

    /// Bytes of one plane pair's luma; the chroma takes half.
    fn frameBytes(o: Options) usize {
        return o.width * o.height;
    }

    /// What `open` asks the codec's pool for. The pool rounds it up to a
    /// power of two: 1280x720 comes to 8 MiB, 1920x1088 to 16 MiB.
    pub fn memoryBytes(o: Options) usize {
        const frame = frameBytes(o);
        var n: usize = h264.chain_words * 4 + frame / 2 + frame * 3 / 2;
        if (!o.decode_only) n += 2 * (frame * 3 / 2) + frame * 3 / 4 + h264.work_bytes;
        // every piece starts on a buffer boundary, the two chroma copies on 256
        return n + 16 * helix.buffer_align + 2 * h264.recon_align;
    }

    pub fn open(o: Options) OpenError!Codec {
        if (o.width % 16 != 0 or o.height % 16 != 0 or o.width < 160 or o.height < 120 or
            o.width > 2560 or o.height > 2048) return error.BadSize;
        var dev = try helix.Device.open(memoryBytes(o));
        errdefer dev.close();
        return carve(dev, o) orelse error.NoMemory;
    }

    /// Cuts the device's memory up. The encoder's scratch memory comes last:
    /// should the codec ever write more output than it was given room for,
    /// it spoils its own scratch and nothing else.
    fn carve(dev: helix.Device, o: Options) ?Codec {
        var take: helix.Carver = .{ .all = dev.mem };
        const frame = frameBytes(o);
        var c: Codec = .{
            .dev = dev,
            .cfg = .{
                .width = @intCast(o.width),
                .height = @intCast(o.height),
                .level = o.level,
                .min_qp = o.min_qp,
                .max_qp = o.max_qp,
            },
            .decode_only = o.decode_only,
            .chain = take.take(h264.chain_words * 4) orelse return null,
            .data = take.take(frame / 2) orelse return null,
            .luma = take.take(frame) orelse return null,
            .chroma = take.take(frame / 2) orelse return null,
        };
        if (!o.decode_only) {
            for (&c.recon) |*r| {
                r[0] = take.take(frame) orelse return null;
                r[1] = take.takeAligned(frame / 2, h264.recon_align) orelse return null;
            }
            c.out = take.take(frame * 3 / 4) orelse return null;
            c.work = take.take(h264.work_bytes) orelse return null;
            c.sets_len = h264.parameterSets(c.cfg, &c.sets);
        }
        return c;
    }

    pub fn close(c: *Codec) void {
        c.dev.close();
    }

    /// The program draws into rows y0 to y1-1 of the frame after a decode,
    /// or reads them. Rows it has not named it must leave alone: the codec
    /// and the program would not see each other's bytes there. Call it
    /// before the first decode.
    pub fn drawsRows(c: *Codec, y0: u32, y1: u32) void {
        // whole chroma rows
        var band = [2]u32{ @min(y0, c.cfg.height) & ~@as(u32, 1), @min((y1 + 1) & ~@as(u32, 1), c.cfg.height) };
        if (band[0] >= band[1]) return;

        // what it touches or overlaps becomes one band with it
        var n: usize = 0;
        for (c.bands[0..c.bands_n]) |b| {
            if (b[0] <= band[1] and band[0] <= b[1]) {
                band = .{ @min(band[0], b[0]), @max(band[1], b[1]) };
            } else {
                c.bands[n] = b;
                n += 1;
            }
        }
        if (n == max_bands) {
            // no room for another: everything from the first row to the last
            for (c.bands[0..n]) |b| band = .{ @min(band[0], b[0]), @max(band[1], b[1]) };
            n = 0;
        }
        c.bands[n] = band;
        c.bands_n = n + 1;

        const stride = c.cfg.width;
        c.drawn_n = 0;
        for (c.bands[0..c.bands_n]) |b| {
            c.drawn[c.drawn_n] = c.luma.sub(b[0] * stride, (b[1] - b[0]) * stride);
            c.drawn[c.drawn_n + 1] = c.chroma.sub(b[0] / 2 * stride, (b[1] - b[0]) / 2 * stride);
            c.drawn_n += 2;
        }
    }

    /// Decodes a JPEG picture into the frame. After an error from the
    /// picture itself (jpeg.Error, WrongSize, CutOff, TooLong) the frame is
    /// what it was; after CodecError it holds no picture.
    pub fn decode(c: *Codec, picture: []const u8) DecodeError!void {
        const h = try jpeg.parse(picture, c.cfg.width, c.cfg.height);
        if (h.width != c.cfg.width or h.height != c.cfg.height) return error.WrongSize;
        if (!jpeg.complete(picture)) return error.CutOff;
        const data = picture[h.data_offset..];
        if (data.len > c.data.bytes.len) return error.TooLong;

        @memcpy(c.data.bytes[0..data.len], data);
        _ = try jpeg.decodeChain(c.chain.words(), &h, c.data.pa, c.luma.pa, c.chroma.pa);
        c.frame_valid = false;
        const r = try c.dev.run(.{
            .chain = c.chain,
            .to_codec = &.{c.data.first(data.len)},
            .from_codec = c.drawn[0..c.drawn_n],
        });
        if (!r.ok() or r.status & helix.status.jpeg_end == 0) {
            c.last_status = r.status;
            return error.CodecError;
        }
        c.frame_valid = true;
    }

    /// Encodes the frame. `key` asks for a key picture; the first picture
    /// and the one after a failure are key pictures anyway.
    pub fn encode(c: *Codec, key: bool, qp: u8) EncodeError!Picture {
        if (c.decode_only or !c.frame_valid) return error.NoFrame;
        const idr = key or c.number == 0;
        const f: h264.Frame = .{
            .idr = idr,
            .qp = qp,
            .number = if (idr) 0 else c.number,
            .idr_id = c.idr_id,
            .raw_luma = c.luma.pa,
            .raw_chroma = c.chroma.pa,
            .recon_luma = c.recon[c.cur][0].pa,
            .recon_chroma = c.recon[c.cur][1].pa,
            .ref_luma = c.recon[c.cur ^ 1][0].pa,
            .ref_chroma = c.recon[c.cur ^ 1][1].pa,
            .out = c.out.pa,
            .work = c.work.pa,
        };
        _ = try h264.encodeChain(c.chain.words(), c.cfg, f);
        var header: [h264.slice_header_max]u8 = undefined;
        const header_len = h264.sliceHeader(f, &header);

        // whatever goes wrong from here: the codec's copy of this picture is
        // not one to predict the next from
        c.number = 0;
        const r = try c.dev.run(.{
            .chain = c.chain,
            .to_codec = c.drawn[0..c.drawn_n],
            .from_codec = &.{c.out.first(c.out_seen)},
        });
        if (!r.ok()) {
            c.last_status = r.status;
            return error.CodecError;
        }
        const len = header_len + r.bytes + r.escapes;
        if (len > c.out.bytes.len) return error.TooLong;
        h264.finishSlice(c.out.bytes);
        c.out_seen = std.mem.alignForward(usize, len, helix.buffer_align);

        if (idr) c.idr_id ^= 1;
        c.number = f.number + 1;
        c.cur ^= 1;
        return .{ .sets = if (idr) c.sets[0..c.sets_len] else &.{}, .slice = c.out.bytes[0..len], .key = idr };
    }
};

// ---- tests ----

const testing = std.testing;

fn testCodec(mem: []u8, o: Options) Codec {
    return Codec.carve(.{ .fd = -1, .mem = .{ .pa = 0x0e000000, .bytes = mem } }, o).?;
}

test "the memory of a codec" {
    try testing.expect(Codec.memoryBytes(.{ .width = 1280, .height = 720 }) <= 8 << 20);
    try testing.expect(Codec.memoryBytes(.{ .width = 1920, .height = 1088 }) <= 16 << 20);
    try testing.expect(Codec.memoryBytes(.{ .width = 1280, .height = 720, .decode_only = true }) <= 2 << 20);
    try testing.expectError(error.BadSize, Codec.open(.{ .width = 1280, .height = 724 }));
    try testing.expectError(error.BadSize, Codec.open(.{ .width = 4096, .height = 2048 }));

    // what memoryBytes says is enough, and no two pieces share a byte
    const o: Options = .{ .width = 320, .height = 240 };
    const mem = try testing.allocator.alignedAlloc(u8, .@"4", Codec.memoryBytes(o));
    defer testing.allocator.free(mem);
    const c = testCodec(mem, o);
    const pieces = [_]helix.Dma{ c.chain, c.data, c.luma, c.chroma, c.recon[0][0], c.recon[0][1], c.recon[1][0], c.recon[1][1], c.out, c.work };
    var end: u32 = 0x0e000000;
    for (pieces) |p| {
        try testing.expect(p.pa >= end);
        try testing.expectEqual(@as(u32, 0), p.pa % helix.buffer_align);
        end = p.pa + @as(u32, @intCast(p.bytes.len));
    }
    try testing.expect(end <= 0x0e000000 + mem.len);
    try testing.expectEqual(@as(usize, 320 * 240), c.luma.bytes.len);
    try testing.expectEqual(@as(usize, 320 * 120), c.chroma.bytes.len);
    try testing.expectEqual(@as(u32, 0), c.recon[0][1].pa % h264.recon_align);
    try testing.expectEqual(@as(u32, 0), c.recon[1][1].pa % h264.recon_align);
    try testing.expectEqual(@as(usize, h264.work_bytes), c.work.bytes.len);
    try testing.expect(c.sets_len > 16);
}

test "the rows a program draws into" {
    const o: Options = .{ .width = 320, .height = 240, .decode_only = true };
    const mem = try testing.allocator.alignedAlloc(u8, .@"4", Codec.memoryBytes(o));
    defer testing.allocator.free(mem);
    var c = testCodec(mem, o);
    try testing.expectEqual(@as(usize, 0), c.drawn_n);

    // a bar at the bottom: its luma rows and half as many chroma rows
    c.drawsRows(160, 240);
    try testing.expectEqual(@as(usize, 2), c.drawn_n);
    try testing.expectEqual(c.luma.pa + 160 * 320, c.drawn[0].pa);
    try testing.expectEqual(@as(usize, 80 * 320), c.drawn[0].bytes.len);
    try testing.expectEqual(c.chroma.pa + 80 * 320, c.drawn[1].pa);
    try testing.expectEqual(@as(usize, 40 * 320), c.drawn[1].bytes.len);

    // odd rows widen to whole chroma rows; a second band stays apart
    c.drawsRows(17, 31);
    try testing.expectEqual(@as(usize, 4), c.drawn_n);
    try testing.expectEqual([2]u32{ 16, 32 }, c.bands[1]);

    // one that touches both joins them; rows past the picture are cut off
    c.drawsRows(30, 400);
    try testing.expectEqual(@as(usize, 1), c.bands_n);
    try testing.expectEqual([2]u32{ 16, 240 }, c.bands[0]);
    c.drawsRows(500, 600);
    try testing.expectEqual(@as(usize, 1), c.bands_n);

    // more bands than there is room for become one
    var d = testCodec(mem, o);
    for ([_]u32{ 0, 40, 80, 120, 160 }) |y| d.drawsRows(y, y + 8);
    try testing.expectEqual(@as(usize, 1), d.bands_n);
    try testing.expectEqual([2]u32{ 0, 168 }, d.bands[0]);
}

test "no picture to encode before one was decoded" {
    const o: Options = .{ .width = 320, .height = 240 };
    const mem = try testing.allocator.alignedAlloc(u8, .@"4", Codec.memoryBytes(o));
    defer testing.allocator.free(mem);
    var c = testCodec(mem, o);
    try testing.expectError(error.NoFrame, c.encode(true, 30));
    // and a picture that is none never reaches the codec
    try testing.expectError(error.Truncated, c.decode(&.{ 0xff, 0xd8 }));
    try testing.expectError(error.NoFrame, c.encode(true, 30));
}
