//! k1os-helix-enc: JPEG pictures to H.264 on the Helix codec, for the
//! timelapse. Every picture is decoded on the codec, encoded at a fixed
//! quantiser and appended to the output as an Annex B access unit.
//!
//!   k1os-helix-enc [-q qp] [-g gop] [-p total] [-a] [-D] [-v] -o out.h264 frame.jpg...
//!
//! A single "-" as the file list reads the names from stdin, one per line.
//! -D only decodes and writes the NV12 frames. The pictures have to be
//! baseline JPEGs of one size, a multiple of 16 each way: the camera's
//! snapshots. One that is not, or is damaged, is reported and left out.
//!
//! Exit status: 0 when every picture went in, 3 when some failed in the
//! codec, 1 when there is no output, 2 for bad options.
const std = @import("std");
const linux = std.os.linux;
const helix = @import("helix.zig");
const codec = @import("helix_codec.zig");

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fread(ptr: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
extern fn fwrite(ptr: [*]const u8, size: usize, n: usize, f: *anyopaque) usize;
extern fn fclose(f: *anyopaque) c_int;
extern fn read(fd: c_int, buf: [*]u8, len: usize) isize;
extern fn dprintf(fd: c_int, fmt: [*:0]const u8, ...) c_int;
extern fn atoi(s: [*:0]const u8) c_int;

/// the largest picture file taken; a camera frame is a tenth of it
const file_max = 4 << 20;
var file: [file_max]u8 = undefined;

fn nowMs() f64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) * 1000.0 + @as(f64, @floatFromInt(ts.nsec)) / 1e6;
}

fn usage() u8 {
    _ = dprintf(2, "usage: k1os-helix-enc [-q qp] [-g gop] [-p total] [-a] [-D] [-v] -o out.h264 frame.jpg...\n" ++
        "  -q  fixed quantiser 18..51, lower is better and larger (default 28)\n" ++
        "  -g  frames between key pictures (default 30)\n" ++
        "  -p  draw a progress bar at the bottom: this is frame N of `total` frames\n" ++
        "  -a  append to the output instead of truncating it\n" ++
        "  -D  decode only: write the NV12 frames instead of H.264\n" ++
        "  -v  verbose\n" ++
        "  -   read the JPEG file names from stdin, one per line\n");
    return 2;
}

/// The names of the pictures: the rest of the command line, or lines of stdin.
const Names = struct {
    args: *std.process.Args.Iterator,
    first: ?[:0]const u8,
    from_stdin: bool,
    buf: [8192]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,
    eof: bool = false,

    fn next(n: *Names) ?[:0]const u8 {
        if (!n.from_stdin) {
            if (n.first) |f| {
                n.first = null;
                return f;
            }
            return n.args.next();
        }
        while (true) {
            if (std.mem.findScalar(u8, n.buf[n.pos..n.len], '\n')) |end| {
                const line = std.mem.trimEnd(u8, n.buf[n.pos..][0..end], "\r");
                n.buf[n.pos + line.len] = 0;
                const start = n.pos;
                n.pos += end + 1;
                if (line.len == 0) continue;
                return n.buf[start..][0..line.len :0];
            }
            if (n.eof) {
                // a last line without its line break
                if (n.pos >= n.len or n.len == n.buf.len) return null;
                const line = n.buf[n.pos..n.len];
                n.buf[n.len] = 0;
                n.pos = n.len;
                return line.ptr[0..line.len :0];
            }
            // make room and read on; a name longer than the buffer ends the list
            std.mem.copyForwards(u8, &n.buf, n.buf[n.pos..n.len]);
            n.len -= n.pos;
            n.pos = 0;
            if (n.len >= n.buf.len - 1) return null;
            const got = read(0, n.buf[n.len..].ptr, n.buf.len - 1 - n.len);
            if (got <= 0) n.eof = true else n.len += @intCast(got);
        }
    }
};

fn readFile(path: [*:0]const u8) ?[]const u8 {
    const f = fopen(path, "rb") orelse return null;
    defer _ = fclose(f);
    var len: usize = 0;
    while (len < file.len) {
        const n = fread(file[len..].ptr, 1, file.len - len, f);
        if (n == 0) break;
        len += n;
    }
    return if (len == file.len) null else file[0..len];
}

/// The progress of a timelapse: frame `done` of `total` as a green bar on a
/// dark one along the bottom of the picture.
const progress_height = 12;
const progress_margin = 8;

fn drawProgress(luma: []u8, chroma: []u8, w: usize, h: usize, done: usize, total: usize) void {
    if (w < 4 * progress_margin or h < 4 * progress_margin) return;
    const x0 = progress_margin;
    const x1 = w - progress_margin;
    const y0 = h - progress_margin - progress_height;
    const fill = x0 + 2 + (x1 - x0 - 4) * @min(done, total) / @max(total, 1);
    for (0..progress_height) |r| {
        const row = luma[(y0 + r) * w ..][0..w];
        @memset(row[x0..x1], 20);
        if (r >= 2 and r < progress_height - 2 and fill > x0 + 2) @memset(row[x0 + 2 .. fill], 140);
    }
    for (0..progress_height / 2) |r| {
        const row = chroma[(y0 / 2 + r) * w ..][0..w];
        @memset(row[x0..x1], 128);
        if (r >= 1 and r < progress_height / 2 - 1) {
            var x: usize = x0 + 2;
            while (x < fill) : (x += 2) {
                row[x] = 96;
                row[x + 1] = 75;
            }
        }
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var args = init.args.iterate();
    _ = args.next();
    var out_path: ?[:0]const u8 = null;
    var qp: c_int = 28;
    var gop: c_int = 30;
    var progress_total: c_int = 0;
    var append = false;
    var decode_only = false;
    var verbose = false;
    var first: ?[:0]const u8 = null;

    while (args.next()) |a| {
        if (a.len < 2 or a[0] != '-') {
            first = a;
            break;
        }
        if (std.mem.eql(u8, a, "-o")) {
            out_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, a, "-q")) {
            qp = atoi(args.next() orelse return usage());
        } else if (std.mem.eql(u8, a, "-g")) {
            gop = atoi(args.next() orelse return usage());
        } else if (std.mem.eql(u8, a, "-p")) {
            progress_total = atoi(args.next() orelse return usage());
        } else if (std.mem.eql(u8, a, "-a")) {
            append = true;
        } else if (std.mem.eql(u8, a, "-D")) {
            decode_only = true;
        } else if (std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else return usage();
    }
    const out_name = out_path orelse return usage();
    if (first == null) return usage();
    if (qp < 18 or qp > 51) {
        _ = dprintf(2, "k1os-helix-enc: QP %d out of range 18..51 (below 18 a picture can outgrow the room the codec has for it)\n", qp);
        return 2;
    }
    if (gop < 1 or gop > 120) {
        _ = dprintf(2, "k1os-helix-enc: GOP %d out of range 1..120\n", gop);
        return 2;
    }
    var names: Names = .{ .args = &args, .first = first, .from_stdin = std.mem.eql(u8, first.?, "-") };

    const out = fopen(out_name, if (append) "ab" else "wb") orelse {
        _ = dprintf(2, "k1os-helix-enc: cannot write %s\n", out_name.ptr);
        return 1;
    };
    defer _ = fclose(out);

    var the_codec: ?codec.Codec = null;
    defer if (the_codec) |*c| c.close();
    var done: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var out_bytes: u64 = 0;
    var decode_ms: f64 = 0;
    var encode_ms: f64 = 0;
    var fatal = false;
    const started = nowMs();

    while (names.next()) |path| {
        const picture = readFile(path) orelse {
            _ = dprintf(2, "k1os-helix-enc: %s: cannot read it, or it is larger than %u MiB\n", path.ptr, @as(c_uint, file_max >> 20));
            failed += 1;
            continue;
        };
        if (the_codec == null) {
            // the first picture that is one tells the size
            const h = @import("helix_jpeg.zig").parse(picture, 2560, 2048) catch |e| {
                _ = dprintf(2, "k1os-helix-enc: %s: %s, skipped\n", path.ptr, @errorName(e).ptr);
                skipped += 1;
                continue;
            };
            the_codec = codec.Codec.open(.{
                .width = h.width,
                .height = h.height,
                .level = if (@as(u32, h.width) * h.height > 1280 * 720) 40 else 31,
                .min_qp = 10,
                .max_qp = 40,
                .decode_only = decode_only,
            }) catch |e| switch (e) {
                error.BadSize => {
                    _ = dprintf(2, "k1os-helix-enc: %s: %ux%u, the size must be a multiple of 16 between 160x120 and 2560x2048, skipped\n", path.ptr, @as(c_uint, h.width), @as(c_uint, h.height));
                    skipped += 1;
                    continue;
                },
                else => {
                    _ = dprintf(2, "k1os-helix-enc: no codec for %ux%u: %s\n", @as(c_uint, h.width), @as(c_uint, h.height), @errorName(e).ptr);
                    fatal = true;
                    break;
                },
            };
            const c = &the_codec.?;
            if (decode_only) {
                c.drawsRows(0, c.cfg.height);
            } else if (progress_total > 0) {
                const y0 = @as(u32, c.cfg.height) - progress_margin - progress_height;
                c.drawsRows(y0, y0 + progress_height);
            }
            if (verbose) _ = dprintf(2, "k1os-helix-enc: %ux%u, QP %d, GOP %d\n", @as(c_uint, h.width), @as(c_uint, h.height), qp, gop);
        }
        const c = &the_codec.?;
        const w: usize = c.cfg.width;
        const h: usize = c.cfg.height;

        var t = nowMs();
        c.decode(picture) catch |e| switch (e) {
            error.Truncated, error.Unsupported, error.Corrupt, error.TooLarge, error.WrongSize, error.CutOff, error.TooLong => {
                _ = dprintf(2, "k1os-helix-enc: %s: %s, skipped\n", path.ptr, @errorName(e).ptr);
                skipped += 1;
                continue;
            },
            error.CodecError => {
                _ = dprintf(2, "k1os-helix-enc: %s: the codec gave it up (status %08x)\n", path.ptr, c.last_status);
                failed += 1;
                if (failed > 3 and done == 0) {
                    fatal = true;
                    break;
                }
                continue;
            },
            else => {
                _ = dprintf(2, "k1os-helix-enc: %s: %s\n", path.ptr, @errorName(e).ptr);
                fatal = true;
                break;
            },
        };
        decode_ms += nowMs() - t;

        if (decode_only) {
            if (fwrite(c.luma.bytes.ptr, 1, w * h, out) != w * h or fwrite(c.chroma.bytes.ptr, 1, w * h / 2, out) != w * h / 2) {
                _ = dprintf(2, "k1os-helix-enc: cannot write %s\n", out_name.ptr);
                fatal = true;
                break;
            }
            out_bytes += w * h * 3 / 2;
            done += 1;
            _ = dprintf(2, "frame=%5d decoded\n", @as(c_int, @intCast(done)));
            continue;
        }
        if (progress_total > 0) drawProgress(c.luma.bytes, c.chroma.bytes, w, h, done + 1, @intCast(progress_total));

        t = nowMs();
        const encoded = c.encode(done % @as(usize, @intCast(gop)) == 0, @intCast(qp)) catch |e| switch (e) {
            error.CodecError, error.TooLong => {
                _ = dprintf(2, "k1os-helix-enc: %s: not encoded: %s\n", path.ptr, @errorName(e).ptr);
                failed += 1;
                if (failed > 3 and done == 0) {
                    fatal = true;
                    break;
                }
                continue;
            },
            else => {
                _ = dprintf(2, "k1os-helix-enc: %s: %s\n", path.ptr, @errorName(e).ptr);
                fatal = true;
                break;
            },
        };
        encode_ms += nowMs() - t;
        if (fwrite(encoded.sets.ptr, 1, encoded.sets.len, out) != encoded.sets.len or
            fwrite(encoded.slice.ptr, 1, encoded.slice.len, out) != encoded.slice.len)
        {
            _ = dprintf(2, "k1os-helix-enc: cannot write %s\n", out_name.ptr);
            fatal = true;
            break;
        }
        out_bytes += encoded.bytes();
        done += 1;
        // the line ffmpeg prints: moonraker-timelapse reads "frame=N" from it
        _ = dprintf(2, "frame=%5d fps=%5.1f q=%d.0 size=%8llukB\n", @as(c_int, @intCast(done)), @as(f64, @floatFromInt(done)) * 1000.0 / (nowMs() - started + 1), qp, out_bytes / 1024);
    }

    if (done != 0 or failed != 0 or skipped != 0) {
        const per: f64 = @floatFromInt(@max(done, 1));
        _ = dprintf(2, "k1os-helix-enc: %u frames %s (%llu bytes), %u skipped, %u failed, %.0f ms total, decode %.1f ms/frame, encode %.1f ms/frame\n", @as(c_uint, @intCast(done)), @as([*:0]const u8, if (decode_only) "decoded" else "encoded"), out_bytes, @as(c_uint, @intCast(skipped)), @as(c_uint, @intCast(failed)), nowMs() - started, decode_ms / per, encode_ms / per);
    }
    if (fatal or done == 0) return 1;
    return if (failed == 0) 0 else 3;
}
