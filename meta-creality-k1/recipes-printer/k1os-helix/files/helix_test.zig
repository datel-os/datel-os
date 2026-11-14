//! Trials of the Helix codec on the printer, through /dev/helix:
//!
//!   k1os-helix-test decode <in.jpg> <out.nv12|-> [repeat] [nosync]
//!   k1os-helix-test encode <in.jpg> <out.h264> <qp> <frames> [gop]
//!   k1os-helix-test checks <in.jpg>
//!   k1os-helix-test cross <a.jpg> <b.jpg> [rounds]
//!
//! Installed as k1os-helix-test. The pictures are camera frames or
//! snapshots. "decode ... nosync" names no range the codec writes, to time
//! a job without that. "checks" asks the kernel for
//! what it has to refuse. "cross" writes on one CPU and runs the job on the
//! other, and the other way round for what the codec wrote: both pictures
//! must be of one size.
const std = @import("std");
const linux = std.os.linux;
const helix = @import("helix.zig");
const jpeg = @import("helix_jpeg.zig");
const h264 = @import("helix_h264.zig");

extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn read(fd: c_int, buf: [*]u8, len: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern fn close(fd: c_int) c_int;
extern fn printf(fmt: [*:0]const u8, ...) c_int;
extern fn atoi(s: [*:0]const u8) c_int;
extern fn sched_setaffinity(pid: c_int, size: usize, mask: *const usize) c_int;

const o_rdonly = 0;
const o_creat_trunc_wronly = 0x0100 | 0x0200 | 1; // MIPS

const max_width = 1280;
const max_height = 736;
/// what the trials take from the codec's pool: a power of two, as the pool
/// would round it up anyway
const pool_bytes = 8 << 20;
const data_max = 512 << 10;
const out_max = 1 << 20;

fn nowUs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
}

fn fail(what: [*:0]const u8) u8 {
    _ = printf("k1os-helix-test: %s\n", what);
    return 1;
}

fn usage() u8 {
    _ = printf("usage: k1os-helix-test decode <in.jpg> <out.nv12|-> [repeat] [nosync]\n" ++
        "       k1os-helix-test encode <in.jpg> <out.h264> <qp> <frames> [gop]\n" ++
        "       k1os-helix-test checks <in.jpg>\n" ++
        "       k1os-helix-test cross <a.jpg> <b.jpg> [rounds]\n");
    return 2;
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = write(fd, bytes.ptr + done, bytes.len - done);
        if (n <= 0) return false;
        done += @intCast(n);
    }
    return true;
}

/// A picture: the file, its header and where its entropy-coded data is.
const Picture = struct {
    file: [data_max]u8 = undefined,
    len: usize = 0,
    header: jpeg.Header = .{},

    fn load(p: *Picture, path: [*:0]const u8) bool {
        const fd = open(path, o_rdonly);
        if (fd < 0) {
            _ = printf("k1os-helix-test: cannot open %s\n", path);
            return false;
        }
        defer _ = close(fd);
        p.len = 0;
        while (p.len < p.file.len) {
            const n = read(fd, p.file[p.len..].ptr, p.file.len - p.len);
            if (n <= 0) break;
            p.len += @intCast(n);
        }
        p.header = jpeg.parse(p.file[0..p.len], max_width, max_height) catch |e| {
            _ = printf("k1os-helix-test: %s: %s\n", path, @errorName(e).ptr);
            return false;
        };
        return true;
    }
    fn data(p: *const Picture) []const u8 {
        return p.file[p.header.data_offset..p.len];
    }
    fn stride(p: *const Picture) usize {
        return p.header.mbWidth() * 16;
    }
    fn rows(p: *const Picture) usize {
        return p.header.mbHeight() * 16;
    }
};

/// The codec's memory, cut up for a decode and an encode of up to 1280x736.
const Memory = struct {
    dev: helix.Device,
    chain: helix.Dma,
    data: helix.Dma,
    luma: helix.Dma,
    chroma: helix.Dma,
    recon: [2][2]helix.Dma,
    work: helix.Dma,
    out: helix.Dma,

    fn init() ?Memory {
        const dev = helix.Device.open(pool_bytes) catch |e| {
            _ = printf("k1os-helix-test: /dev/helix: %s\n", @errorName(e).ptr);
            return null;
        };
        var c: helix.Carver = .{ .all = dev.mem };
        const frame = max_width * max_height;
        var m: Memory = undefined;
        m.chain = c.take(h264.chain_words * 4) orelse return null;
        m.data = c.take(data_max) orelse return null;
        m.luma = c.take(frame) orelse return null;
        m.chroma = c.take(frame / 2) orelse return null;
        for (&m.recon) |*r| {
            r[0] = c.take(frame) orelse return null;
            r[1] = c.takeAligned(frame / 2, h264.recon_align) orelse return null;
        }
        m.work = c.take(h264.work_bytes) orelse return null;
        m.out = c.take(out_max) orelse return null;
        m.dev = dev;
        return m;
    }

    /// Decodes a picture into luma and chroma. `sync` names the picture's
    /// planes as written by the codec, which a program that reads them needs.
    fn decode(m: *const Memory, p: *const Picture, sync: bool) ?helix.Result {
        const d = p.data();
        @memcpy(m.data.bytes[0..d.len], d);
        return m.decodeInPlace(p, d.len, sync);
    }

    /// The same with the data already in place.
    fn decodeInPlace(m: *const Memory, p: *const Picture, data_len: usize, sync: bool) ?helix.Result {
        const size = p.stride() * p.rows();
        _ = jpeg.decodeChain(m.chain.words(), &p.header, m.data.pa, m.luma.pa, m.chroma.pa) catch return null;
        const r = m.dev.run(.{
            .chain = m.chain,
            .to_codec = &.{m.data.first(data_len)},
            .from_codec = if (sync) &.{ m.luma.first(size), m.chroma.first(size / 2) } else &.{},
        }) catch |e| {
            _ = printf("k1os-helix-test: decode: %s\n", @errorName(e).ptr);
            return null;
        };
        if (!r.ok() or r.status & helix.status.jpeg_end == 0) {
            _ = printf("k1os-helix-test: decode: status %08x\n", r.status);
            return null;
        }
        return r;
    }

    /// CRC of the decoded picture without its padding rows and columns.
    fn pictureCrc(m: *const Memory, p: *const Picture) u32 {
        var crc: std.hash.Crc32 = .init();
        const s = p.stride();
        for (0..p.header.height) |y| crc.update(m.luma.bytes[y * s ..][0..p.header.width]);
        for (0..(@as(usize, p.header.height) + 1) / 2) |y| crc.update(m.chroma.bytes[y * s ..][0..p.header.width]);
        return crc.final();
    }
};

fn pin(cpu: u5) bool {
    const mask: usize = @as(usize, 1) << cpu;
    return sched_setaffinity(0, @sizeOf(usize), &mask) == 0;
}

var picture_a: Picture = .{};
var picture_b: Picture = .{};

pub fn main(init: std.process.Init.Minimal) u8 {
    var args = init.args.iterate();
    _ = args.next();
    const mode = args.next() orelse return usage();
    const first = args.next() orelse return usage();
    if (!picture_a.load(first)) return 1;
    const p = &picture_a;
    _ = printf("%ux%u, header %u bytes, data %u bytes\n", @as(c_uint, p.header.width), @as(c_uint, p.header.height), @as(c_uint, @intCast(p.header.data_offset)), @as(c_uint, @intCast(p.data().len)));
    var mem = Memory.init() orelse return fail("no memory from the codec's pool");
    defer mem.dev.close();

    if (std.mem.eql(u8, mode, "decode")) {
        const out_path = args.next() orelse return usage();
        const repeat: usize = if (args.next()) |r| @intCast(@max(1, atoi(r))) else 1;
        const sync = if (args.next()) |a| !std.mem.eql(u8, a, "nosync") else true;
        return runDecode(&mem, p, out_path, repeat, sync);
    } else if (std.mem.eql(u8, mode, "encode")) {
        const out_path = args.next() orelse return usage();
        const qp: u8 = @intCast(std.math.clamp(atoi(args.next() orelse return usage()), 0, 51));
        const frames: usize = @intCast(@max(1, atoi(args.next() orelse return usage())));
        const gop: usize = if (args.next()) |g| @intCast(@max(1, atoi(g))) else 30;
        return runEncode(&mem, p, out_path, qp, frames, gop);
    } else if (std.mem.eql(u8, mode, "checks")) {
        return runChecks(&mem, p);
    } else if (std.mem.eql(u8, mode, "cross")) {
        if (!picture_b.load(args.next() orelse return usage())) return 1;
        const rounds: usize = if (args.next()) |r| @intCast(@max(1, atoi(r))) else 20;
        return runCross(&mem, p, &picture_b, rounds);
    }
    return usage();
}

fn runDecode(mem: *const Memory, p: *const Picture, out_path: [:0]const u8, repeat: usize, sync: bool) u8 {
    var total_us: i64 = 0;
    var worst_us: i64 = 0;
    var crc: u32 = 0;
    for (0..repeat) |i| {
        const t0 = nowUs();
        // the last job always names the planes: they are read below
        const r = mem.decode(p, sync or i + 1 == repeat) orelse return 1;
        const us = nowUs() - t0;
        total_us += us;
        worst_us = @max(worst_us, us);
        if (i == 0) _ = printf("job 0: status %08x\n", r.status);
        if (sync or i + 1 == repeat) {
            const c = mem.pictureCrc(p);
            if (i != 0 and crc != 0 and c != crc) {
                _ = printf("k1os-helix-test: job %u gave another picture: crc %08x, before %08x\n", @as(c_uint, @intCast(i)), c, crc);
                return 1;
            }
            crc = c;
        }
    }
    _ = printf("%u jobs, %u us each with the copy in (worst %u), crc %08x\n", @as(c_uint, @intCast(repeat)), @as(c_uint, @intCast(@divTrunc(total_us, @as(i64, @intCast(repeat))))), @as(c_uint, @intCast(worst_us)), crc);

    if (std.mem.eql(u8, out_path, "-")) return 0;
    const out = open(out_path, o_creat_trunc_wronly, @as(c_uint, 0o644));
    if (out < 0) return fail("cannot create the output");
    defer _ = close(out);
    const s = p.stride();
    for (0..p.header.height) |y| {
        if (!writeAll(out, mem.luma.bytes[y * s ..][0..p.header.width])) return fail("write");
    }
    for (0..(@as(usize, p.header.height) + 1) / 2) |y| {
        if (!writeAll(out, mem.chroma.bytes[y * s ..][0..p.header.width])) return fail("write");
    }
    return 0;
}

/// Decodes the picture once and encodes it `frames` times: an IDR picture
/// every `gop` frames, P pictures between them.
fn runEncode(mem: *const Memory, p: *const Picture, out_path: [:0]const u8, qp: u8, frames: usize, gop: usize) u8 {
    // the encoder reads what the decoder wrote: no range to name for it
    _ = mem.decode(p, false) orelse return 1;

    const cfg: h264.Config = .{ .width = p.header.width, .height = p.header.height, .min_qp = 10, .max_qp = 40 };
    const out = open(out_path, o_creat_trunc_wronly, @as(c_uint, 0o644));
    if (out < 0) return fail("cannot create the output");
    defer _ = close(out);
    var sets: [h264.parameter_sets_max]u8 = undefined;
    const sets_len = h264.parameterSets(cfg, &sets);

    var total_us: i64 = 0;
    var worst_us: i64 = 0;
    var total_bytes: usize = 0;
    var idr_id: u1 = 0;
    // what the program has read of the output since the codec last wrote it
    var seen: usize = helix.buffer_align;
    for (0..frames) |n| {
        const idr = n % gop == 0;
        const cur = n % gop % 2;
        const f: h264.Frame = .{
            .idr = idr,
            .qp = qp,
            .number = @intCast(n % gop),
            .idr_id = idr_id,
            .raw_luma = mem.luma.pa,
            .raw_chroma = mem.chroma.pa,
            .recon_luma = mem.recon[cur][0].pa,
            .recon_chroma = mem.recon[cur][1].pa,
            .ref_luma = mem.recon[cur ^ 1][0].pa,
            .ref_chroma = mem.recon[cur ^ 1][1].pa,
            .out = mem.out.pa,
            .work = mem.work.pa,
        };
        if (idr) idr_id ^= 1;
        _ = h264.encodeChain(mem.chain.words(), cfg, f) catch return fail("chain");
        var header: [h264.slice_header_max]u8 = undefined;
        const header_len = h264.sliceHeader(f, &header);

        const t0 = nowUs();
        const r = mem.dev.run(.{ .chain = mem.chain, .from_codec = &.{mem.out.first(seen)} }) catch |e| {
            _ = printf("k1os-helix-test: frame %u: %s\n", @as(c_uint, @intCast(n)), @errorName(e).ptr);
            return 1;
        };
        const us = nowUs() - t0;
        total_us += us;
        worst_us = @max(worst_us, us);
        if (!r.ok()) {
            _ = printf("k1os-helix-test: frame %u: status %08x\n", @as(c_uint, @intCast(n)), r.status);
            return 1;
        }
        const len = header_len + r.bytes + r.escapes;
        if (len > out_max) return fail("the codec reports more data than fits");
        h264.finishSlice(mem.out.bytes);
        if (idr and !writeAll(out, sets[0..sets_len])) return fail("write");
        if (!writeAll(out, mem.out.bytes[0..len])) return fail("write");
        seen = std.mem.alignForward(usize, len, helix.buffer_align);
        total_bytes += len;
        if (n < 3) _ = printf("frame %u: status %08x, %u bytes\n", @as(c_uint, @intCast(n)), r.status, @as(c_uint, @intCast(len)));
    }
    _ = printf("%u frames at QP %u, %u bytes, %u us each (worst %u)\n", @as(c_uint, @intCast(frames)), @as(c_uint, qp), @as(c_uint, @intCast(total_bytes)), @as(c_uint, @intCast(@divTrunc(total_us, @as(i64, @intCast(frames))))), @as(c_uint, @intCast(worst_us)));
    return 0;
}

var failures: u32 = 0;

fn expect(what: [*:0]const u8, got: c_int, want: c_int) void {
    const ok = got == want;
    if (!ok) failures += 1;
    const verdict: [*:0]const u8 = if (ok) "ok" else "FAILED";
    _ = printf("  %-52s errno %3d, expected %3d  %s\n", what, got, want, verdict);
}

/// What the kernel has to refuse, and that the codec works afterwards.
fn runChecks(mem: *const Memory, p: *const Picture) u8 {
    const enxio = 6;
    const enomem = 12;
    const ebusy = 16;
    const einval = 22;
    const etimedout = 145;
    const size: u32 = @intCast(mem.dev.mem.bytes.len);
    const words = mem.data.words();
    const data_offset: u32 = mem.data.pa - mem.dev.mem.pa;

    _ = mem.decode(p, true) orelse return 1;
    const crc = mem.pictureCrc(p);
    _ = printf("a picture before the checks: crc %08x\n", crc);

    const fd = helix.raw.open();
    if (fd < 0) return fail("cannot open /dev/helix a second time");
    expect("a job without memory", helix.raw.run(fd, 0, 0, 0, 100, null), enxio);
    expect("mapping without memory", @intFromBool(helix.raw.mapFails(fd, 4096, 0)), 1);
    expect("no bytes of memory", helix.raw.alloc(fd, 0), einval);
    expect("more memory than the pool has", helix.raw.alloc(fd, 64 << 20), enomem);
    expect("a page of memory", helix.raw.alloc(fd, 100), 0);
    expect("memory a second time", helix.raw.alloc(fd, 4096), ebusy);
    expect("mapping more than the memory", @intFromBool(helix.raw.mapFails(fd, 8192, 0)), 1);
    expect("mapping past its end", @intFromBool(helix.raw.mapFails(fd, 4096, 4096)), 1);
    expect("mapping it", @intFromBool(helix.raw.mapFails(fd, 4096, 0)), 0);
    helix.raw.close(fd);

    expect("a chain at an odd offset", helix.raw.run(mem.dev.fd, data_offset + 4, 0, 0, 100, null), einval);
    expect("a chain behind the memory", helix.raw.run(mem.dev.fd, size, 0, 0, 100, null), einval);
    expect("a chain far behind the memory", helix.raw.run(mem.dev.fd, 0xffffff80, 0, 0, 100, null), einval);
    @memset(words[0..32768], 0x80040004); // every entry valid, none the last
    expect("a chain without end", helix.raw.run(mem.dev.fd, data_offset, 0, 0, 100, null), einval);
    words[1] = 0x00040004;
    expect("a chain with an entry that is not one", helix.raw.run(mem.dev.fd, data_offset, 0, 0, 100, null), einval);
    words[1] = 0x80040004;
    words[32767] = 0xc00c0000;
    expect("a chain longer than any", helix.raw.run(mem.dev.fd, data_offset, 0, 0, 100, null), einval);

    // a chain that ends and starts nothing: one write to the flush register
    words[0] = 0;
    words[1] = 0xc00c0000;
    expect("a range behind the memory", helix.raw.run(mem.dev.fd, data_offset, size - 64, 128, 100, null), einval);
    expect("a range that wraps around", helix.raw.run(mem.dev.fd, data_offset, 0xffffffc0, 128, 100, null), einval);
    var got: u32 = 0;
    const t0 = nowUs();
    expect("a job that never ends, 100 ms allowed", helix.raw.run(mem.dev.fd, data_offset, 0, 0, 100, &got), etimedout);
    _ = printf("    it took %u ms, status %08x\n", @as(c_uint, @intCast(@divTrunc(nowUs() - t0, 1000))), got);

    _ = mem.decode(p, true) orelse return fail("no decode after the checks");
    const after = mem.pictureCrc(p);
    if (after != crc) failures += 1;
    const verdict: [*:0]const u8 = if (after == crc) "ok" else "FAILED";
    _ = printf("the picture after the checks: crc %08x  %s\n", after, verdict);
    _ = printf("%u failed\n", failures);
    return if (failures == 0) 0 else 1;
}

/// The caches of the two CPUs. The kernel does its cache work on the CPU the
/// job is started on; this asks whether that covers what the other CPU holds.
fn runCross(mem: *const Memory, a: *const Picture, b: *const Picture, rounds: usize) u8 {
    if (a.header.width != b.header.width or a.header.height != b.header.height) return fail("the pictures differ in size");
    if (!pin(0)) return fail("cannot choose a CPU");

    // what each picture decodes to, all on one CPU
    _ = mem.decode(a, true) orelse return 1;
    const crc_a = mem.pictureCrc(a);
    _ = mem.decode(b, true) orelse return 1;
    const crc_b = mem.pictureCrc(b);
    _ = printf("on one CPU: a %08x, b %08x\n", crc_a, crc_b);
    if (crc_a == crc_b) return fail("the pictures decode alike: nothing to tell apart");

    var stale_to: usize = 0;
    var stale_from: usize = 0;
    var other: usize = 0;
    for (0..rounds) |_| {
        // 1. Written on CPU 0, run from CPU 1: does the codec get b's data
        // (memory as the last job left it) or a's (still in CPU 0's cache)?
        _ = pin(0);
        _ = mem.decode(b, true) orelse return 1;
        const d = a.data();
        @memcpy(mem.data.bytes[0..d.len], d);
        _ = pin(1);
        _ = mem.decodeInPlace(a, d.len, true) orelse return 1;
        const got_to = mem.pictureCrc(a);
        if (got_to == crc_b) stale_to += 1 else if (got_to != crc_a) other += 1;

        // 2. Read on CPU 0, written by a job run from CPU 1, read on CPU 0
        // again: the new picture, or the one CPU 0 still has cached?
        _ = pin(0);
        _ = mem.decode(b, true) orelse return 1;
        if (mem.pictureCrc(b) != crc_b) other += 1;
        _ = pin(1);
        _ = mem.decode(a, true) orelse return 1;
        _ = pin(0);
        const got_from = mem.pictureCrc(a);
        if (got_from == crc_b) stale_from += 1 else if (got_from != crc_a) other += 1;
    }
    _ = printf("%u rounds: written on one CPU, run from the other: %u times the codec got old data\n", @as(c_uint, @intCast(rounds)), @as(c_uint, @intCast(stale_to)));
    _ = printf("           codec's output read on the other CPU: %u times the old picture\n", @as(c_uint, @intCast(stale_from)));
    _ = printf("           %u times a picture that is neither\n", @as(c_uint, @intCast(other)));
    return if (stale_to + stale_from + other == 0) 0 else 1;
}
