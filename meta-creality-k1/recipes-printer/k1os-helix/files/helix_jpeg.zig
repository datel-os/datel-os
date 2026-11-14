//! JPEG on the Helix: the header of a picture, turned into what the decoder
//! is configured with (the Huffman tables in the codec's own packing, the
//! quantisation tables, one word per colour component), and the chain that
//! decodes it.
//!
//! The Helix decodes the entropy-coded data itself; everything before it is
//! read here. The vendor's kernel driver did this in the kernel and believed
//! every length in the picture, so a damaged camera frame could send it across
//! kernel memory. Here every read is checked against the picture, and a
//! picture this parser does not take is an error, nothing more.
//!
//! Baseline JPEG only (SOF0, 8 bit), one or three components, tables 0 and 1,
//! which is what a UVC camera sends.
const std = @import("std");
const helix = @import("helix.zig");

pub const Error = error{
    /// not a JPEG, or cut off inside the header
    Truncated,
    /// a marker or a value the Helix has no use for
    Unsupported,
    /// a length or a table that contradicts itself
    Corrupt,
    /// larger than the frame the caller has room for
    TooLarge,
};

pub const Header = struct {
    width: u16 = 0,
    height: u16 = 0,
    /// where the entropy-coded data starts
    data_offset: usize = 0,
    /// the smallest code of each length, packed into four words per table;
    /// the standard tables when the picture has none
    huffmin: [16]u32 = @splat(0),
    /// per table and code length: index of its first symbol minus its first code, 9 bits
    huffbase: [64]u32 = @splat(0),
    /// the symbols; both DC tables share twelve entries, a nibble each
    huffsymb: [336]u32 = @splat(0),
    /// four quantisation tables in the order the picture has them (zigzag)
    qmem: [256]u32 = @splat(0),
    /// per component: blocks in an MCU minus one, quantisation table, Huffman tables
    pxc: [4]u32 = @splat(0),

    /// macroblocks (16x16) across and down
    pub fn mbWidth(h: *const Header) u32 {
        return (@as(u32, h.width) + 15) / 16;
    }
    pub fn mbHeight(h: *const Header) u32 {
        return (@as(u32, h.height) + 15) / 16;
    }
};

const dc_symbols = 12;
const ac_symbols = 162;
/// where a table's symbols live in huffsymb: AC 0, both DC tables, AC 1
const symb_ac0 = 0;
const symb_dc = 162;
const symb_ac1 = 174;

const Reader = struct {
    d: []const u8,
    pos: usize = 0,

    fn left(r: *const Reader) usize {
        return r.d.len - r.pos;
    }
    fn byte(r: *Reader) Error!u8 {
        if (r.pos >= r.d.len) return error.Truncated;
        defer r.pos += 1;
        return r.d[r.pos];
    }
    fn word(r: *Reader) Error!u16 {
        const hi = try r.byte();
        return @as(u16, hi) << 8 | try r.byte();
    }
    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.left()) return error.Truncated;
        defer r.pos += n;
        return r.d[r.pos..][0..n];
    }
};

/// The Huffman tables of a picture, in the codec's packing.
const Huffman = struct {
    /// the smallest code of each length, per table
    min: [64]u32 = @splat(0),
    base: [64]u32 = @splat(0),
    symb: [336]u32 = @splat(0),
    /// the picture brought tables of its own
    any: bool = false,

    /// The content of a DHT segment: one or more tables.
    fn read(t: *Huffman, seg: *Reader) Error!void {
        while (seg.left() != 0) {
            const id = try seg.byte();
            const class = id >> 4;
            const table = id & 15;
            if (class > 1 or table > 1) return error.Unsupported;
            const dc = class == 0;
            const counts = try seg.take(16);
            var total: usize = 0;
            for (counts) |c| total += c;
            if (total > if (dc) @as(usize, dc_symbols) else ac_symbols) return error.Corrupt;
            const symbols = try seg.take(total);

            // rows of `base` and of `min`: AC 0, DC 0, AC 1, DC 1
            const row: usize = (@as(usize, table) * 2 + @intFromBool(dc)) * 16;
            var next: usize = if (dc) symb_dc else if (table == 0) symb_ac0 else symb_ac1;
            var code: u32 = 0;
            var s: usize = 0;
            for (counts, 0..) |count, length| {
                t.min[row + length] = code;
                t.base[row + length] = (@as(u32, @intCast(next)) -% code) & 0x1ff;
                for (0..count) |_| {
                    const v = symbols[s];
                    s += 1;
                    if (dc) {
                        if (v > 15) return error.Corrupt;
                        t.symb[next] |= if (table == 0) @as(u32, v) else @as(u32, v) << 4;
                    } else {
                        t.symb[next] = v;
                    }
                    next += 1;
                    code += 1;
                }
                code <<= 1;
            }
            t.any = true;
        }
    }

    fn store(t: *const Huffman, h: *Header) void {
        h.huffbase = t.base;
        h.huffsymb = t.symb;
        // The smallest code of each length takes as many bits as the length
        // (at most 8 are kept): lengths 1 to 8 fill a 4-bit and a 32-bit
        // word, lengths 9 to 12 and 13 to 16 a byte each in two more.
        for (0..4) |table| {
            const m = t.min[table * 16 ..][0..16];
            var v: u32 = m[0] & 1;
            v = v << 2 | (m[1] & 3);
            v = v << 3 | (m[2] & 7);
            const top = (v >> 2) & 0xf;
            v = v << 4 | (m[3] & 15);
            v = v << 5 | (m[4] & 31);
            v = v << 6 | (m[5] & 63);
            v = v << 7 | (m[6] & 127);
            v = v << 8 | (m[7] & 255);
            h.huffmin[table * 4 + 0] = (m[12] & 255) << 24 | (m[13] & 255) << 16 | (m[14] & 255) << 8 | (m[15] & 255);
            h.huffmin[table * 4 + 1] = (m[8] & 255) << 24 | (m[9] & 255) << 16 | (m[10] & 255) << 8 | (m[11] & 255);
            h.huffmin[table * 4 + 2] = v;
            h.huffmin[table * 4 + 3] = top;
        }
    }
};

/// The tables of the JPEG standard (ITU-T T.81, annex K.3) as the content of
/// a DHT segment: luminance DC and AC, chrominance DC and AC. A picture
/// without tables of its own means these, and a camera's MJPEG frames are
/// such pictures.
const standard_dht = [_]u8{
    0x00, 0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x01, 0x00, 0x03,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x10, 0x00, 0x02, 0x01, 0x03, 0x03,
    0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7d, 0x01, 0x02, 0x03, 0x00, 0x04,
    0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81,
    0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82,
    0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36,
    0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56,
    0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76,
    0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95,
    0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3,
    0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca,
    0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7,
    0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0x11, 0x00, 0x02,
    0x01, 0x02, 0x04, 0x04, 0x03, 0x04, 0x07, 0x05, 0x04, 0x04, 0x00, 0x01, 0x02, 0x77, 0x00, 0x01,
    0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22,
    0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62,
    0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a,
    0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a,
    0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe2, 0xe3,
    0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
};

const standard_tables: Huffman = blk: {
    @setEvalBranchQuota(100_000);
    var t: Huffman = .{};
    var seg: Reader = .{ .d = &standard_dht };
    t.read(&seg) catch unreachable;
    break :blk t;
};

/// Whether the picture ends as a JPEG does, give or take the few bytes a
/// camera pads its frames with. A frame cut off earlier would still be
/// decoded, into whatever the missing data happens to mean.
pub fn complete(jpeg: []const u8) bool {
    const tail = jpeg[jpeg.len -| 32..];
    return std.mem.find(u8, tail, &.{ 0xff, 0xd9 }) != null;
}

/// Reads the header of `jpeg` up to the start of the scan. `max_width` and
/// `max_height` are the picture the output frame was sized for.
pub fn parse(jpeg: []const u8, max_width: u32, max_height: u32) Error!Header {
    var h: Header = .{};
    var r: Reader = .{ .d = jpeg };
    var huffman: Huffman = .{};
    var blocks: [4]u8 = @splat(0);
    var qt_sel: [4]u8 = @splat(0);
    var components: usize = 0;

    if (try r.word() != 0xffd8) return error.Truncated;

    while (true) {
        if (try r.byte() != 0xff) return error.Corrupt;
        const marker = try r.byte();
        const len = try r.word();
        if (len < 2) return error.Corrupt;
        var seg: Reader = .{ .d = try r.take(len - 2) };

        switch (marker) {
            0xc0 => { // SOF0
                if (components != 0) return error.Corrupt;
                if (try seg.byte() != 8) return error.Unsupported;
                h.height = try seg.word();
                h.width = try seg.word();
                components = try seg.byte();
                if (components != 1 and components != 3) return error.Unsupported;
                if (seg.left() != 3 * components) return error.Corrupt;
                if (h.width == 0 or h.height == 0) return error.Corrupt;
                if (h.mbWidth() > (max_width + 15) / 16 or h.mbHeight() > (max_height + 15) / 16)
                    return error.TooLarge;
                for (0..components) |i| {
                    _ = try seg.byte(); // component id
                    blocks[i] = try seg.byte();
                    qt_sel[i] = try seg.byte();
                    const hs = blocks[i] >> 4;
                    const vs = blocks[i] & 15;
                    if (hs < 1 or hs > 2 or vs < 1 or vs > 2) return error.Unsupported;
                    if (qt_sel[i] > 3) return error.Corrupt;
                }
            },
            0xc4 => try huffman.read(&seg),
            0xdb => { // DQT, one or more tables
                while (seg.left() != 0) {
                    const id = try seg.byte();
                    const wide = id >> 4;
                    const table: usize = id & 15;
                    if (wide > 1 or table > 3) return error.Corrupt;
                    for (0..64) |i| {
                        h.qmem[table * 64 + i] = if (wide == 1) try seg.word() else try seg.byte();
                    }
                }
            },
            0xdd => { // DRI: restart markers are not passed to the Helix
                if (seg.left() != 2) return error.Corrupt;
                if (try seg.word() != 0) return error.Unsupported;
            },
            0xda => { // SOS: the header ends here
                if (components == 0) return error.Corrupt;
                const n: usize = try seg.byte();
                if (n != components or seg.left() != 2 * n + 3) return error.Corrupt;
                for (0..4) |i| {
                    var dc_table: u32 = 0;
                    var ac_table: u32 = 0;
                    if (i < n) {
                        _ = try seg.byte(); // component id
                        const tables = try seg.byte();
                        dc_table = tables >> 4;
                        ac_table = tables & 15;
                        if (dc_table > 1 or ac_table > 1) return error.Unsupported;
                    }
                    const mcu_blocks = @as(u32, blocks[i] & 3) * (blocks[i] >> 4 & 3);
                    h.pxc[i] = ((mcu_blocks -% 1) & 0xf) << 4 | @as(u32, qt_sel[i]) << 2 |
                        dc_table << 1 | ac_table;
                }
                if (r.left() == 0) return error.Truncated;
                h.data_offset = r.pos;
                break;
            },
            0xe0...0xef, 0xfe => {}, // APPn, COM
            else => return error.Unsupported,
        }
    }

    (if (huffman.any) &huffman else &standard_tables).store(&h);
    return h;
}

// ---- the chain ----

const reg = struct {
    const tcsm_flush = 0xc0000;
    const trig = 0xe0000;
    const glbi = 0xe0004;
    const stat = 0xe0008;
    const bsa = 0xe000c;
    const p0a = 0xe0010;
    const p1a = 0xe0014;
    const nmcu = 0xe0028;
    const nrsm = 0xe002c;
    const p0c = 0xe0030;
    const width = 0xe0040;
    const hufb = 0xe1200;
    const hufm = 0xe1300;
    const qmem = 0xe1400;
    const hufs = 0xe1800;
};

const glbi_open_clock = 1;
const glbi_enable = 1;
const glbi_decode = 1 << 3;
const glbi_three_colours = 2 << 4;
const glbi_mcu_420 = 0x0a << 16;
const width_nv12 = 1 << 15;
const trig_core = 1 << 0;
const trig_bitstream = 1 << 1;
const trig_picture = 1 << 2;

/// words a decode chain takes
pub const chain_words = 2 * (2 + 16 + 64 + 336 + 256 + 11 + 2);

/// The chain that decodes one picture into NV12. `data` is where the codec
/// finds the entropy-coded part (the picture from Header.data_offset on);
/// `luma` and `chroma` take mbWidth*16 by mbHeight*16 bytes and half as many.
/// Returns the chain's length in words.
pub fn decodeChain(out: []u32, h: *const Header, data: u32, luma: u32, chroma: u32) helix.ChainError!usize {
    var c: helix.Chain = .{ .out = out };
    try c.put(reg.tcsm_flush, 0);
    try c.put(reg.glbi, glbi_open_clock);
    for (h.huffmin, 0..) |v, i| try c.put(reg.hufm + @as(u32, @intCast(i)) * 4, v);
    for (h.huffbase, 0..) |v, i| try c.put(reg.hufb + @as(u32, @intCast(i)) * 4, v);
    for (h.huffsymb, 0..) |v, i| try c.put(reg.hufs + @as(u32, @intCast(i)) * 4, v);
    for (h.qmem, 0..) |v, i| try c.put(reg.qmem + @as(u32, @intCast(i)) * 4, v);
    try c.put(reg.stat, 0);
    try c.put(reg.bsa, data);
    try c.put(reg.p0a, luma);
    try c.put(reg.p1a, chroma);
    try c.put(reg.nmcu, h.mbWidth() * h.mbHeight() - 1);
    try c.put(reg.nrsm, 0);
    try c.put(reg.width, width_nv12 | (h.mbWidth() - 1));
    for (h.pxc, 0..) |v, i| try c.put(reg.p0c + @as(u32, @intCast(i)) * 4, v);
    try c.put(reg.glbi, glbi_mcu_420 | glbi_three_colours | glbi_decode | glbi_enable);
    try c.last(reg.trig, trig_bitstream | trig_picture | trig_core);
    return c.n;
}

// ---- tests ----

const testing = std.testing;
/// a camera frame (1280x720, with the standard Huffman tables put in) cut off
/// after 391 bytes of scan data
const frame = @embedFile("testdata/frame-header.jpg");
/// what the vendor's parser made of it: huffmin[16] hea[64] heb[336] qt[256]
/// pxc[4] width height header size, little-endian words
const vendor = @embedFile("testdata/frame-header.tables");

fn vendorWord(i: usize) u32 {
    return std.mem.readInt(u32, vendor[i * 4 ..][0..4], .little);
}

test "the tables the vendor's parser makes of a camera frame" {
    const h = try parse(frame, 1280, 720);
    for (h.huffmin, 0..) |v, i| try testing.expectEqual(vendorWord(i), v);
    for (h.huffbase, 0..) |v, i| try testing.expectEqual(vendorWord(16 + i), v);
    for (h.huffsymb, 0..) |v, i| try testing.expectEqual(vendorWord(80 + i), v);
    for (h.qmem, 0..) |v, i| try testing.expectEqual(vendorWord(416 + i), v);
    for (h.pxc, 0..) |v, i| try testing.expectEqual(vendorWord(672 + i), v);
    try testing.expectEqual(vendorWord(676), h.width);
    try testing.expectEqual(vendorWord(677), h.height);
    try testing.expectEqual(vendorWord(678), h.data_offset);
    try testing.expectEqual(@as(u32, 80), h.mbWidth());
    try testing.expectEqual(@as(u32, 45), h.mbHeight());
}

test "a picture larger than the frame is refused" {
    try testing.expectError(error.TooLarge, parse(frame, 640, 480));
    _ = try parse(frame, 1280, 712); // the same 45 macroblock rows
}

test "every truncation of the header is an error" {
    const h = try parse(frame, 1280, 720);
    for (0..h.data_offset + 1) |len| {
        try testing.expectError(error.Truncated, parse(frame[0..len], 1280, 720));
    }
    _ = try parse(frame[0 .. h.data_offset + 1], 1280, 720);
}

test "damaged headers never read outside the picture" {
    // the slices are exact, so a read past the end fails the bounds check of
    // a safe build; anything else is an error or a header
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    const h = try parse(frame, 1280, 720);
    var copy: [frame.len]u8 = undefined;
    for (0..200_000) |_| {
        @memcpy(&copy, frame);
        for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
            copy[random.uintLessThan(usize, h.data_offset)] = random.int(u8);
        }
        const len = if (random.boolean()) copy.len else random.uintLessThan(usize, copy.len);
        if (parse(copy[0..len], 1280, 720)) |got| {
            try testing.expect(got.data_offset < len);
            try testing.expect(got.mbWidth() <= 80 and got.mbHeight() <= 45);
            for (got.huffbase) |v| try testing.expect(v <= 0x1ff);
            for (got.huffsymb) |v| try testing.expect(v <= 0xff);
        } else |_| {}
    }
}

test "a decode chain" {
    const h = try parse(frame, 1280, 720);
    var words: [chain_words]u32 = undefined;
    try testing.expectEqual(@as(usize, chain_words), try decodeChain(&words, &h, 0x0f010000, 0x0f400000, 0x0f500000));
    // the first write flushes, the last one starts the core and ends the chain
    try testing.expectEqual(@as(u32, 0), words[0]);
    try testing.expectEqual(@as(u32, reg.tcsm_flush), helix.entryRegister(words[1]));
    try testing.expectEqual(@as(u32, 7), words[words.len - 2]);
    try testing.expectEqual(@as(u32, reg.trig), helix.entryRegister(words[words.len - 1]));
    try testing.expect(helix.entryIsLast(words[words.len - 1]));
    // 80 by 45 macroblocks, and only the last entry ends the chain
    var found: usize = 0;
    var i: usize = 0;
    while (i < words.len) : (i += 2) {
        if (i + 2 < words.len) try testing.expect(!helix.entryIsLast(words[i + 1]));
        if (helix.entryRegister(words[i + 1]) == reg.nmcu) {
            try testing.expectEqual(@as(u32, 3599), words[i]);
            found += 1;
        }
        if (helix.entryRegister(words[i + 1]) == reg.width) {
            try testing.expectEqual(@as(u32, width_nv12 | 79), words[i]);
            found += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), found);
    var short: [chain_words - 2]u32 = undefined;
    try testing.expectError(error.ChainTooLong, decodeChain(&short, &h, 0, 0, 0));
}

test "a picture without Huffman tables means the standard ones" {
    // the test frame is a camera frame with the standard tables put in
    const with = try parse(frame, 1280, 720);
    const dht = std.mem.find(u8, frame, &.{ 0xff, 0xc4 }).?;
    const dht_len = 2 + (@as(usize, frame[dht + 2]) << 8 | frame[dht + 3]);
    try testing.expectEqual(@as(usize, 2 + 2 + standard_dht.len), dht_len);
    try testing.expectEqualSlices(u8, &standard_dht, frame[dht + 4 ..][0..standard_dht.len]);
    var bare: [frame.len]u8 = undefined;
    @memcpy(bare[0..dht], frame[0..dht]);
    @memcpy(bare[dht .. frame.len - dht_len], frame[dht + dht_len ..]);
    const without = try parse(bare[0 .. frame.len - dht_len], 1280, 720);
    try testing.expectEqual(with.data_offset - dht_len, without.data_offset);
    try testing.expectEqualSlices(u32, &with.huffmin, &without.huffmin);
    try testing.expectEqualSlices(u32, &with.huffbase, &without.huffbase);
    try testing.expectEqualSlices(u32, &with.huffsymb, &without.huffsymb);
    try testing.expectEqualSlices(u32, &with.qmem, &without.qmem);
    try testing.expectEqualSlices(u32, &with.pxc, &without.pxc);
}

test "a picture that ends as one" {
    try testing.expect(!complete(frame)); // the test frame is cut off in its data
    const whole = [_]u8{ 0xff, 0xd8, 0xff, 0xd9 };
    const data: [100]u8 = @splat(0x55);
    const padding: [7]u8 = @splat(0);
    const more: [64]u8 = @splat(0);
    const padded = [_]u8{ 0xff, 0xd8 } ++ data ++ [_]u8{ 0xff, 0xd9 } ++ padding;
    const cut = whole ++ more;
    try testing.expect(complete(&whole));
    try testing.expect(complete(&padded));
    try testing.expect(!complete(&cut));
    try testing.expect(!complete(&[_]u8{}));
}
