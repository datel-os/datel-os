//! The Helix, the video codec of the Ingenic X2000, through /dev/helix.
//!
//! A job is a list of register writes (a "chain") in memory the codec reads
//! by itself, and buffers it is given by physical address. The kernel's part
//! (k1os-helix.c) is small: the codec's power, its interrupt, memory at a
//! known physical address and the caches. What a chain says is decided here,
//! in helix_jpeg.zig and helix_h264.zig.
//!
//! The memory is ordinary cached memory to the program, and the codec reads
//! and writes it behind the caches' back. So every job says which ranges the
//! program wrote for the codec (`to_codec`) and which the codec writes for
//! the program (`from_codec`):
//!
//!   - what the program wrote and does not name, the codec may not see;
//!   - what the codec wrote and the program did not name in that job or a
//!     later one, the program may not see: it reads what it read before;
//!   - while a job runs, the program leaves the job's ranges alone.
//!
//! A range the program neither wrote nor reads (a reference frame the codec
//! keeps for itself) needs no mention. Ranges mean whole cache lines of 64
//! bytes, so buffers should begin and end on one.
const std = @import("std");

/// buffers begin and end on this: the codec takes addresses without their
/// low seven bits, and a cache line is half of it
pub const buffer_align = 128;

/// Memory the codec reaches: the same bytes at a physical address.
pub const Dma = struct {
    pa: u32,
    bytes: []u8,

    pub fn words(d: Dma) []u32 {
        return @as([*]u32, @ptrCast(@alignCast(d.bytes.ptr)))[0 .. d.bytes.len / 4];
    }
    pub fn sub(d: Dma, offset: usize, len: usize) Dma {
        return .{ .pa = d.pa + @as(u32, @intCast(offset)), .bytes = d.bytes[offset..][0..len] };
    }
    /// the first `len` bytes
    pub fn first(d: Dma, len: usize) Dma {
        return d.sub(0, len);
    }
};

/// Hands out pieces of a Dma one after another, each on a buffer boundary.
pub const Carver = struct {
    all: Dma,
    used: usize = 0,

    pub fn take(c: *Carver, len: usize) ?Dma {
        return c.takeAligned(len, buffer_align);
    }
    /// a piece whose address is a multiple of `alignment`, itself one of buffer_align
    pub fn takeAligned(c: *Carver, len: usize, alignment: usize) ?Dma {
        const start = c.used + (alignment - (c.all.pa + c.used) % alignment) % alignment;
        const size = std.mem.alignForward(usize, len, buffer_align);
        if (start > c.all.bytes.len or size > c.all.bytes.len - start) return null;
        c.used = start + size;
        return c.all.sub(start, size);
    }
};

// ---- chains ----

const chain_valid = 1 << 31;
const chain_last = 1 << 30;
const chain_register = 0xffffc;

pub const ChainError = error{
    /// the chain does not fit the memory it was given
    ChainTooLong,
};

/// Writes a chain entry by entry: a value, then the register it goes to.
pub const Chain = struct {
    out: []u32,
    n: usize = 0,

    pub fn put(c: *Chain, reg: u32, value: u32) ChainError!void {
        return c.entry(reg, value, 0);
    }
    /// the entry the codec stops reading at
    pub fn last(c: *Chain, reg: u32, value: u32) ChainError!void {
        return c.entry(reg, value, chain_last);
    }
    /// `count` registers in a row
    pub fn zeros(c: *Chain, first_reg: u32, count: u32) ChainError!void {
        for (0..count) |i| try c.put(first_reg + @as(u32, @intCast(i)) * 4, 0);
    }
    fn entry(c: *Chain, reg: u32, value: u32, flags: u32) ChainError!void {
        if (c.n + 2 > c.out.len) return error.ChainTooLong;
        c.out[c.n] = value;
        c.out[c.n + 1] = chain_valid | flags | (reg & chain_register);
        c.n += 2;
    }
};

/// For tests: the register an entry of a chain goes to, and whether the
/// chain ends there.
pub fn entryRegister(word: u32) u32 {
    return word & chain_register;
}
pub fn entryIsLast(word: u32) bool {
    return word & chain_last != 0;
}

// ---- jobs ----

/// bits of Result.status
pub const status = struct {
    pub const end_of_frame = 1 << 0;
    pub const chain_error = 1 << 2;
    pub const timeout = 1 << 3;
    pub const jpeg_end = 1 << 4;
    pub const bitstream_error = 1 << 7;
    pub const tlb_error = 0x1f << 10;
    pub const errors = chain_error | timeout | bitstream_error | tlb_error;
};

/// What a finished job left in the codec.
pub const Result = struct {
    /// the scheduler's status
    status: u32,
    /// H.264: bytes of slice data after the slice header, and how many
    /// escape bytes the codec added to them on top
    bytes: u32,
    escapes: u32,

    /// the codec reached the end of the frame and reports no error
    pub fn ok(r: Result) bool {
        return r.status & status.end_of_frame != 0 and r.status & status.errors == 0;
    }
};

pub const Job = struct {
    /// where the chain is; its length is the chain's own business
    chain: Dma,
    /// what the program wrote for this job
    to_codec: []const Dma = &.{},
    /// what the job writes and the program will read
    from_codec: []const Dma = &.{},
    timeout_ms: u32 = 1000,
};

pub const Error = error{
    /// no /dev/helix, or not for this user
    NoDevice,
    /// the codec's pool has no piece that large left
    NoMemory,
    /// a chain or range the kernel does not take
    BadJob,
    /// no end of the job in time; the codec was stopped
    JobTimeout,
    /// the codec did not stop and takes no more jobs until a reboot
    CodecStuck,
    Unexpected,
};

// The kernel's structures (k1os-helix.c).
const max_ranges = 8;
const KernelRange = extern struct { offset: u32 = 0, bytes: u32 = 0 };
const KernelAlloc = extern struct { bytes: u32, phys: u32 = 0 };
const KernelRun = extern struct {
    chain: u32,
    timeout_ms: u32,
    to_codec: [max_ranges]KernelRange = @splat(.{}),
    from_codec: [max_ranges]KernelRange = @splat(.{}),
    status: u32 = 0,
    bytes: u32 = 0,
    escapes: u32 = 0,
    reserved: u32 = 0,
};

/// _IOWR('H', nr, T) as MIPS numbers it: direction in the top three bits
fn ioctlNumber(nr: u32, comptime T: type) c_int {
    return @bitCast(@as(u32, 6 << 29 | @sizeOf(T) << 16 | 'H' << 8 | nr));
}
const ioctl_alloc = ioctlNumber(0, KernelAlloc);
const ioctl_run = ioctlNumber(1, KernelRun);

const libc = struct {
    extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern fn close(fd: c_int) c_int;
    extern fn ioctl(fd: c_int, request: c_int, ...) c_int;
    extern fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque;
    extern fn munmap(addr: *anyopaque, len: usize) c_int;
};

// Linux on MIPS
const o_rdwr = 2;
const o_cloexec = 0o2000000;
const prot_read_write = 3;
const map_shared = 1;
const map_failed: usize = @bitCast(@as(isize, -1));
const eintr = 4;
const eio = 5;
const enomem = 12;
const einval = 22;
const etimedout = 145;

pub const Device = struct {
    fd: c_int,
    /// all the memory this program has in the codec's reach
    mem: Dma,

    /// Opens the codec and takes `bytes` of memory, which it keeps until
    /// `close`. The pool hands out powers of two: asking for 9 MiB takes
    /// 16 MiB of its 32.
    pub fn open(bytes: usize) Error!Device {
        const fd = libc.open("/dev/helix", o_rdwr | o_cloexec);
        if (fd < 0) return error.NoDevice;
        errdefer _ = libc.close(fd);

        var a: KernelAlloc = .{ .bytes = std.math.cast(u32, bytes) orelse return error.NoMemory };
        if (libc.ioctl(fd, ioctl_alloc, &a) < 0) {
            return if (std.c._errno().* == enomem) error.NoMemory else error.Unexpected;
        }
        const p = libc.mmap(null, a.bytes, prot_read_write, map_shared, fd, 0);
        if (p == null or @intFromPtr(p) == map_failed) return error.Unexpected;
        return .{ .fd = fd, .mem = .{ .pa = a.phys, .bytes = @as([*]u8, @ptrCast(p))[0..a.bytes] } };
    }

    pub fn close(d: *Device) void {
        _ = libc.munmap(d.mem.bytes.ptr, d.mem.bytes.len);
        _ = libc.close(d.fd);
        d.* = undefined;
    }

    fn range(d: *const Device, r: Dma) ?KernelRange {
        if (r.pa < d.mem.pa) return null;
        const offset = r.pa - d.mem.pa;
        if (offset > d.mem.bytes.len or r.bytes.len > d.mem.bytes.len - offset) return null;
        return .{ .offset = offset, .bytes = @intCast(r.bytes.len) };
    }

    /// Runs a job and returns when the codec is done and stopped. Whether the
    /// job did what it should is in the result.
    pub fn run(d: *const Device, job: Job) Error!Result {
        if (job.to_codec.len > max_ranges or job.from_codec.len > max_ranges) return error.BadJob;
        var r: KernelRun = .{
            .chain = (d.range(job.chain) orelse return error.BadJob).offset,
            .timeout_ms = job.timeout_ms,
        };
        for (job.to_codec, 0..) |m, i| r.to_codec[i] = d.range(m) orelse return error.BadJob;
        for (job.from_codec, 0..) |m, i| r.from_codec[i] = d.range(m) orelse return error.BadJob;

        // a signal while another program's job runs: the wait starts over
        while (libc.ioctl(d.fd, ioctl_run, &r) < 0) {
            switch (std.c._errno().*) {
                eintr => continue,
                einval => return error.BadJob,
                etimedout => return error.JobTimeout,
                eio => return error.CodecStuck,
                else => return error.Unexpected,
            }
        }
        return .{ .status = r.status, .bytes = r.bytes, .escapes = r.escapes };
    }

};

/// For tests of the kernel's own checks: the calls as they are, answering
/// with errno (0: accepted).
pub const raw = struct {
    pub fn open() c_int {
        return libc.open("/dev/helix", o_rdwr | o_cloexec);
    }
    pub fn close(fd: c_int) void {
        _ = libc.close(fd);
    }
    pub fn alloc(fd: c_int, bytes: u32) c_int {
        var a: KernelAlloc = .{ .bytes = bytes };
        return if (libc.ioctl(fd, ioctl_alloc, &a) < 0) std.c._errno().* else 0;
    }
    pub fn run(fd: c_int, chain_offset: u32, to_offset: u32, to_bytes: u32, timeout_ms: u32, got: ?*u32) c_int {
        var r: KernelRun = .{ .chain = chain_offset, .timeout_ms = timeout_ms };
        r.to_codec[0] = .{ .offset = to_offset, .bytes = to_bytes };
        const e = if (libc.ioctl(fd, ioctl_run, &r) < 0) std.c._errno().* else 0;
        if (got) |g| g.* = r.status;
        return e;
    }
    pub fn mapFails(fd: c_int, bytes: usize, offset: usize) bool {
        const p = libc.mmap(null, bytes, prot_read_write, map_shared, fd, @intCast(offset));
        if (p == null or @intFromPtr(p) == map_failed) return true;
        _ = libc.munmap(p.?, bytes);
        return false;
    }
};

// ---- tests ----

const testing = std.testing;

test "the kernel's structures" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(KernelAlloc));
    try testing.expectEqual(@as(usize, 152), @sizeOf(KernelRun));
    try testing.expectEqual(@as(usize, 136), @offsetOf(KernelRun, "status"));
    try testing.expectEqual(@as(u32, 0xc0084800), @as(u32, @bitCast(ioctl_alloc)));
    try testing.expectEqual(@as(u32, 0xc0984801), @as(u32, @bitCast(ioctl_run)));
}

test "a chain" {
    var words: [6]u32 = undefined;
    var c: Chain = .{ .out = &words };
    try c.put(0x40004, 7);
    try c.zeros(0x40010, 1);
    try c.last(0xe0000, 1);
    try testing.expectEqualSlices(u32, &.{ 7, 0x80040004, 0, 0x80040010, 1, 0xc00e0000 }, &words);
    try testing.expectError(error.ChainTooLong, c.put(0, 0));
    try testing.expect(entryIsLast(words[5]) and !entryIsLast(words[3]));
    try testing.expectEqual(@as(u32, 0xe0000), entryRegister(words[5]));
}

test "pieces of memory" {
    var bytes: [1000]u8 align(4) = undefined;
    var c: Carver = .{ .all = .{ .pa = 0x0e000000, .bytes = &bytes } };
    const a = c.take(100).?;
    const b = c.take(300).?;
    try testing.expectEqual(@as(u32, 0x0e000000), a.pa);
    try testing.expectEqual(@as(usize, 128), a.bytes.len);
    try testing.expectEqual(@as(u32, 0x0e000080), b.pa);
    try testing.expectEqual(@as(usize, 384), b.bytes.len);
    try testing.expect(c.take(500) == null);
    const d = c.takeAligned(100, 256).?;
    try testing.expectEqual(@as(u32, 0x0e000200), d.pa);
    try testing.expectEqual(@as(usize, 128), d.bytes.len);
    try testing.expectEqual(@as(usize, 256), c.take(256).?.bytes.len);
    try testing.expect(c.take(200) == null);
    try testing.expectEqual(@as(usize, 25), b.words()[0..25].len);
}
