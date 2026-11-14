//! H.264 on the Helix: what the codec has to be told for one frame.
//!
//! The Helix does the motion search, the transform, the entropy coding and
//! the reconstruction. It is given, per frame, a chain of register writes
//! (see helix_vpu.zig) with the picture's size and addresses, the quantiser,
//! the start state of every CABAC context and the slice header, which it puts
//! in front of the data it produces. The parameter sets are written here too.
//!
//! One slice per frame, Main profile with CABAC, one reference frame, frames
//! only, a fixed quantiser per frame: the caller's rate control picks it.
//! The values of the many tuning registers are the ones the vendor's driver
//! used in this mode; they are kept as numbers where nothing here varies them.
const std = @import("std");
const helix = @import("helix.zig");
const cabac = @import("helix_cabac.zig");

pub const Error = helix.ChainError || error{
    /// a size or an address the codec cannot take
    BadFrame,
};

pub const Config = struct {
    width: u16,
    height: u16,
    /// level_idc: 31 is level 3.1
    level: u8 = 31,
    min_qp: u8 = 20,
    max_qp: u8 = 45,
    /// the in-loop filter of the reconstruction
    deblock: bool = false,

    pub fn mbWidth(c: Config) u32 {
        return (@as(u32, c.width) + 15) / 16;
    }
    pub fn mbHeight(c: Config) u32 {
        return (@as(u32, c.height) + 15) / 16;
    }
    /// bytes of luma in a reconstructed frame; its chroma takes half
    pub fn frameBytes(c: Config) u32 {
        return c.mbWidth() * 16 * c.mbHeight() * 16;
    }
};

pub const Frame = struct {
    /// an IDR picture; anything else is a P picture after the previous frame
    idr: bool,
    qp: u8,
    /// frames since the last IDR picture
    number: u32,
    /// alternates between IDR pictures
    idr_id: u1 = 0,
    /// the picture to encode, NV12, `width` bytes a row
    raw_luma: u32,
    raw_chroma: u32,
    /// where the codec keeps its own copy of this frame (frameBytes and half)
    recon_luma: u32,
    recon_chroma: u32,
    /// the copy of the previous frame
    ref_luma: u32,
    ref_chroma: u32,
    /// where the slice goes
    out: u32,
    /// `work_bytes` of scratch memory
    work: u32,
};

/// scratch memory an encode needs, all of it the codec's own
pub const work_bytes = 1 << 21;
/// the codec takes these addresses without their low seven bits
pub const address_align = helix.buffer_align;
/// the reconstructed chroma additionally
pub const recon_align = 256;

// ---- bits ----

const BitWriter = struct {
    out: []u8,
    bits: usize = 0,

    fn put(w: *BitWriter, count: u6, value: u32) void {
        var i: u6 = count;
        while (i > 0) {
            i -= 1;
            const byte = w.bits / 8;
            if (w.bits % 8 == 0) w.out[byte] = 0;
            if (value >> @intCast(i) & 1 != 0) w.out[byte] |= @as(u8, 0x80) >> @intCast(w.bits % 8);
            w.bits += 1;
        }
    }
    /// Exp-Golomb, unsigned
    fn ue(w: *BitWriter, value: u32) void {
        const v = value + 1;
        const len: u6 = @intCast(32 - @clz(v));
        w.put(len - 1, 0);
        w.put(len, v);
    }
    /// Exp-Golomb, signed
    fn se(w: *BitWriter, value: i32) void {
        w.ue(if (value > 0) @intCast(value * 2 - 1) else @intCast(-value * 2));
    }
    /// fills the last byte with `bit`
    fn alignWith(w: *BitWriter, bit: u1) void {
        while (w.bits % 8 != 0) w.put(1, bit);
    }
    fn trailing(w: *BitWriter) void {
        w.put(1, 1);
        w.alignWith(0);
    }
    fn bytes(w: *const BitWriter) usize {
        return w.bits / 8;
    }
};

const nal_slice = 1;
const nal_idr = 5;
const nal_sps = 7;
const nal_pps = 8;

/// A NAL unit with its start code; `payload` gets the bytes that keep a start
/// code from appearing inside it.
fn nal(out: []u8, ref_idc: u8, kind: u8, payload: []const u8) usize {
    out[0..4].* = .{ 0, 0, 0, 1 };
    out[4] = ref_idc << 5 | kind;
    var n: usize = 5;
    for (payload, 0..) |b, i| {
        if (i >= 2 and b <= 3 and payload[i - 1] == 0 and payload[i - 2] == 0) {
            out[n] = 3;
            n += 1;
        }
        out[n] = b;
        n += 1;
    }
    return n;
}

pub const parameter_sets_max = 64;

/// The sequence and the picture parameter set, as two NAL units.
pub fn parameterSets(c: Config, out: *[parameter_sets_max]u8) usize {
    var raw: [24]u8 = undefined;
    var w: BitWriter = .{ .out = &raw };
    w.put(8, 77); // Main profile
    w.put(4, 0b0100); // constraint_set1: a Main decoder can take it
    w.put(4, 0);
    w.put(8, c.level);
    w.ue(0); // seq_parameter_set_id
    w.ue(0); // frame numbers of 4 bits
    w.ue(2); // output order is decoding order
    w.ue(1); // one reference frame
    w.put(1, 0); // no gaps in frame_num
    w.ue(c.mbWidth() - 1);
    w.ue(c.mbHeight() - 1);
    w.put(1, 1); // frames only
    w.put(1, 1); // direct_8x8_inference
    const crop_right = c.mbWidth() * 16 - c.width;
    const crop_bottom = c.mbHeight() * 16 - c.height;
    if (crop_right != 0 or crop_bottom != 0) {
        w.put(1, 1);
        w.ue(0);
        w.ue(crop_right / 2);
        w.ue(0);
        w.ue(crop_bottom / 2);
    } else {
        w.put(1, 0);
    }
    w.put(1, 0); // no VUI
    w.trailing();
    var n = nal(out, 3, nal_sps, raw[0..w.bytes()]);

    w = .{ .out = &raw };
    w.ue(0); // pic_parameter_set_id
    w.ue(0); // seq_parameter_set_id
    w.put(1, 1); // CABAC
    w.put(1, 0); // no picture order in the slice headers
    w.ue(0); // one slice group
    w.ue(0); // one reference picture in list 0
    w.ue(0); // and in list 1
    w.put(1, 0); // no weighted prediction
    w.put(2, 0);
    w.se(0); // slices give their quantiser relative to 26
    w.se(0);
    w.se(0); // chroma uses the luma quantiser
    w.put(1, 0); // no deblocking parameters in the slice headers
    w.put(1, 0); // intra prediction may use inter neighbours
    w.put(1, 0); // no redundant pictures
    w.trailing();
    n += nal(out[n..], 3, nal_pps, raw[0..w.bytes()]);
    return n;
}

pub const slice_header_max = 16;

/// What the codec puts in front of a frame's data: start code, NAL header and
/// slice header, the last byte filled with ones as CABAC wants it. The second
/// byte of the start code is 0xff here and has to be set to 0 in the output
/// once the frame is encoded (`finishSlice`): the codec would otherwise take
/// the start code for data that needs an escape.
pub fn sliceHeader(f: Frame, out: *[slice_header_max]u8) usize {
    out.* = @splat(0);
    out[0..4].* = .{ 0, 0xff, 0, 1 };
    out[4] = if (f.idr) 3 << 5 | nal_idr else 2 << 5 | nal_slice;
    var w: BitWriter = .{ .out = out, .bits = 40 };
    w.ue(0); // first macroblock
    w.ue(if (f.idr) 7 else 5); // all slices of the picture are I, or P
    w.ue(0); // pic_parameter_set_id
    w.put(4, f.number & 15);
    if (f.idr) {
        w.ue(f.idr_id);
        w.put(2, 0); // keep no earlier picture, this one is no long-term reference
    } else {
        w.put(1, 0); // the number of references the parameter set gives
        w.put(1, 0); // the reference list in its default order
        w.put(1, 0); // sliding window reference marking
        w.ue(0); // cabac_init_idc
    }
    w.se(@as(i32, @min(f.qp, 51)) - 26);
    w.alignWith(1);
    return w.bytes();
}

/// Removes the mark `sliceHeader` put into the start code.
pub fn finishSlice(out: []u8) void {
    out[1] = 0;
}

/// The state every CABAC context starts a slice with: bit 6 is the more
/// probable symbol, the rest the probability, in the codec's own numbering.
pub fn cabacStates(idr: bool, qp: u8) [460]u8 {
    const init = if (idr) &cabac.i_slice else &cabac.p_slice;
    var states: [460]u8 = undefined;
    for (init, &states) |mn, *s| {
        s.* = @intCast(std.math.clamp(((@as(i32, mn[0]) * @min(qp, 51)) >> 4) + mn[1], 1, 126));
    }
    return states;
}

// ---- registers ----

const R = struct {
    const tcsm_flush = 0xc0000;

    // EFE: the front end that reads the picture
    const efe_ctrl = 0x40000;
    const efe_geom = 0x40004;
    const efe_coef_ba = 0x4000c;
    const efe_rawy = 0x40010;
    const efe_rawu = 0x40014;
    const efe_topmv_ba = 0x40018;
    const efe_toppa_ba = 0x4001c;
    const efe_mechn_ba = 0x40020;
    const efe_mauchn_ba = 0x40024;
    const efe_dblkchn_ba = 0x40028;
    const efe_sdechn_ba = 0x4002c;
    const efe_raw_dba = 0x40030;
    const efe_rawv = 0x40034;
    const efe_raw_strd = 0x40038;
    const efe_roi_max_qp = 0x40040;
    const efe_roi_first = 0x40044; // two words of settings, eight of positions
    const efe_qp_gen_tab = 0x4006c;
    const efe_qpg_ctrl = 0x40074;
    const efe_qpg_cfg0 = 0x40078; // seven words
    const efe_skin_ctrl = 0x400ac;
    const efe_skin_pthd0 = 0x400b0;
    const efe_skin_qp_ofst = 0x400bc;
    const efe_eigen_cfg0 = 0x400c0; // seven words
    const efe_diffy_cfg = 0x400dc; // three words
    const efe_skin_param0 = 0x400e8;
    const efe_ssad = 0x40108;
    const efe_dcs = 0x4010c;
    const efe_cqp_ofst = 0x40120;

    // JRFD: the reference frame reader
    const jrfd_trig = 0x10000;
    const jrfd_ctrl = 0x10004;
    const jrfd_hdya = 0x10008;
    const jrfd_hdca = 0x1000c;
    const jrfd_hstr = 0x10010;
    const jrfd_bdya = 0x10014;
    const jrfd_bdca = 0x10018;
    const jrfd_bstr = 0x1001c;
    const jrfd_mhdy = 0x10020; // four words for a second reference

    // MCE: motion estimation
    const mce_glb_ctrl = 0x50000;
    const mce_comp_ctrl = 0x50010;
    const mce_esti_ctrl = 0x50040;
    const mce_mrgi = 0x50044;
    const mce_mvr = 0x50048;
    const mce_fsc = 0x5004c;
    const mce_frm_size = 0x50060;
    const mce_frm_strd = 0x50064;
    const mce_slc_spos = 0x50068;
    const mce_refy0 = 0x5006c;
    const mce_refc0 = 0x50070;
    const mce_refy1 = 0x50074;
    const mce_refc1 = 0x50078;
    const mce_glb_mv = 0x5007c;
    const mce_tmv_ba = 0x50104;
    const mce_chn_sync = 0x50108;
    const mce_chn_ba = 0x5010c;
    const mce_refy0_1 = 0x50110;
    const mce_refc0_1 = 0x50114;

    // VMAU: mode decision, transform and quantisation
    const vmau_ncchn_addr = 0x8000c;
    const vmau_top_base = 0x80028;
    const vmau_ctx = 0x8002c;
    const vmau_md_cfg0 = 0x80030;
    const vmau_md_cfg1 = 0x80034;
    const vmau_md_cfg2 = 0x80038;
    const vmau_md_cfg3 = 0x8003c;
    const vmau_gbl_run = 0x80040;
    const vmau_gbl_ctr = 0x80044;
    const vmau_video_type = 0x80050;
    const vmau_y_gs = 0x80054;
    const vmau_dec_done = 0x80058;
    const vmau_enc_done = 0x8005c;
    const vmau_deadzone = 0x80078;
    const vmau_acmask = 0x8007c;
    const vmau_md_cfg4 = 0x800d8;
    const vmau_md_cfg5 = 0x800dc;
    const vmau_md_cfg6 = 0x800fc;
    const vmau_md_cfg7 = 0x80114;
    const vmau_md_cfg8 = 0x80118;
    const vmau_md_cfg9 = 0x8011c;
    const vmau_ctx_cfbc = 0x80174;
    const vmau_md_cfg11 = 0x80194;
    const vmau_md_mode = 0x80198;
    const vmau_deadzone1 = 0x8019c;
    const vmau_ipred_cfg0 = 0x801c0; // six words
    const vmau_scaling = 0x80800;

    const dblk_cfg = 0x7005c;
    const dblk_trig = 0x70060;

    // SDE: the entropy coder
    const sde_stat = 0x90000;
    const sde_sl_ctrl = 0x90004;
    const sde_sl_geom = 0x90008;
    const sde_gl_ctrl = 0x9000c;
    const sde_codec_id = 0x90010;
    const sde_cfg0 = 0x90014;
    const sde_cfg1 = 0x90018;
    const sde_cfg2 = 0x9001c;
    const sde_cfg3 = 0x90020;
    const sde_cfg4 = 0x90024;
    const sde_cfg5 = 0x90028;
    const sde_cfg6 = 0x9002c;
    const sde_cfg7 = 0x90030;
    const sde_ctx_tbl = 0x92000;

    // EMC: where the codec's working data lives
    const emc_frm_size = 0x30000;
    const emc_bs_addr = 0x30004;
    const emc_dblk_addr = 0x30008;
    const emc_recon_addr = 0x3000c;
    const emc_mv_addr = 0x30010;
    const emc_se_addr = 0x30014;
    const emc_qpt_addr = 0x30018;
    const emc_slv_init = 0x30024;
    const emc_bs_size = 0x30040;
    const emc_cpx_addr = 0x3004c;
    const emc_mod_addr = 0x30050;
    const emc_sad_addr = 0x30054;
    const emc_ncu_addr = 0x30058;

    // SCH: the scheduler between the blocks
    const sch_schc = 0x00060;
    const sch_bnd = 0x00064;
    const sch_schg0 = 0x00068; // SCHG0, SCHG1, SCHE1 to SCHE4

    // ODMA: the reconstructed frame writer
    const odma_trig = 0x60000;
    const odma_ctrl = 0x60004;
    const odma_bdya = 0x60008;
    const odma_bdca = 0x6000c;
    const odma_bstr = 0x60010;
    const odma_hdya = 0x60014; // four words: headers of a compressed frame

    // IFA: the picture analysis in front
    const ifa_ctrl = 0xb0000;
    const ifa_frm_size = 0xb0004;
    const ifa_rawy_ba = 0xb0008;
    const ifa_rawc_ba = 0xb000c;
    const ifa_raw_str = 0xb0010;
    const ifa_refy_ba0 = 0xb0014;
    const ifa_refc_ba0 = 0xb0018;
    const ifa_thrd_y = 0xb001c;
    const ifa_thrd_c = 0xb0020;
    const ifa_refy_ba1 = 0xb0030;
    const ifa_refc_ba1 = 0xb0034;
};

/// memory inside the codec, by its bus address
const vram = struct {
    const residual = 0x132c0000;
    const top_pa = 0x132c4000;
    const top_mv = 0x132c4800;
    const mau_chain = 0x132c4c00;
    const dblk_chain = 0x132c5000;
    const me_chain = 0x132c5400;
    const sde_chain = 0x132c5600;
    const qp_table = 0x132c5800;
    const raw = 0x132f0000;
    const dummy = 0x132ffffc;
    const sync_me = 0x13200070;
    const sync_mau = 0x13200074;
    const sync_sde = 0x1320007c;
};

// parts of the scratch memory, in order
const work_dblk = 1 << 20;
const work_recon = 1 << 18;
const work_mv = 1 << 11;
const work_se = 1 << 11;
const work_qpt_rc = 0xc000;
const work_cpx = 0x20000;
const work_mod = 0x8000;
const work_sad = 0x20000;

const raw_nv12 = 2 << 2;

/// range of the less probable symbol for each probability state, four
/// quantised ranges a word
const lps_range = [64]u32{
    0xeeceaefc, 0xe1c3a5fc, 0xd6b99cfc, 0xcbb094f2, 0xc1a78ce4, 0xb79e85da, 0xad967ece, 0xa48e78c4,
    0x9c8772ba, 0x94806cb0, 0x8c7966a6, 0x8573619e, 0x7e6d5c96, 0x7867578e, 0x72625386, 0x6c5d4e80,
    0x66584a78, 0x61544672, 0x5c4f436c, 0x574b3f66, 0x53473c62, 0x4e43395c, 0x4a403658, 0x463d3352,
    0x4339304e, 0x3f362e4a, 0x3c342b46, 0x39312942, 0x362e273e, 0x332c253c, 0x30292338, 0x2e272136,
    0x2b251f32, 0x29231d30, 0x27211c2c, 0x251f1a2a, 0x231e1928, 0x211c1826, 0x1f1b1624, 0x1d191522,
    0x1c181420, 0x1a17131e, 0x1915121c, 0x1714111a, 0x16131018, 0x15120f18, 0x14110e16, 0x13100d14,
    0x120f0c14, 0x110e0c12, 0x100d0b12, 0x0f0d0a10, 0x0e0c0a10, 0x0d0b090e, 0x0c0a090e, 0x0c0a080c,
    0x0b09070c, 0x0a09070a, 0x0a08070a, 0x0908060a, 0x09070608, 0x08070508, 0x07060508, 0x00000000,
};

/// the 8x8 quantisation matrices the codec is given, intra and inter luma
const matrix_intra = [64]u8{
    16, 20, 23, 26, 28, 33, 35, 37, 20, 21, 26, 28, 33, 35, 37, 39,
    23, 26, 28, 33, 35, 37, 39, 41, 26, 28, 33, 35, 37, 39, 41, 43,
    28, 33, 35, 37, 39, 41, 43, 46, 33, 35, 37, 39, 41, 43, 46, 48,
    35, 37, 39, 41, 43, 46, 48, 50, 37, 39, 41, 43, 46, 48, 50, 52,
};
const matrix_inter = [64]u8{
    19, 23, 25, 27, 29, 31, 32, 34, 23, 23, 27, 29, 31, 32, 34, 35,
    25, 27, 29, 31, 32, 34, 35, 37, 27, 29, 31, 32, 34, 35, 37, 38,
    29, 31, 32, 34, 35, 37, 38, 40, 31, 32, 34, 35, 37, 38, 40, 42,
    32, 34, 35, 37, 38, 40, 42, 43, 34, 35, 37, 38, 40, 42, 43, 45,
};

/// Which CABAC context the mode decision is given in each of its 42 slots.
fn modeContext(slot: usize, idr: bool) usize {
    if (slot < 10) return slot + @as(usize, if (idr) 3 else 14);
    if (slot < 22) return slot - 10 + 73;
    if (slot < 28) return slot - 22 + 64;
    return slot - 28 + 40;
}

/// The same for the 225 slots of coefficient contexts: runs of contexts for
/// the significance map, the last coefficient and the levels of each block kind.
const coefficient_runs = [_][2]u16{
    .{ 4, 85 },   .{ 15, 105 }, .{ 15, 166 }, .{ 10, 227 }, // luma DC
    .{ 4, 89 },   .{ 14, 120 }, .{ 14, 181 }, .{ 10, 237 }, // luma AC
    .{ 4, 93 },   .{ 15, 134 }, .{ 15, 195 }, .{ 10, 247 }, // luma 4x4
    .{ 4, 97 },   .{ 3, 149 },  .{ 3, 210 },  .{ 9, 257 }, // chroma DC
    .{ 4, 101 },  .{ 14, 152 }, .{ 14, 213 }, .{ 10, 266 }, // chroma AC
    .{ 15, 402 }, .{ 9, 417 },  .{ 10, 426 }, // luma 8x8
};

/// words the chain of a frame takes at most
pub const chain_words = 2100;

/// Writes the chain that encodes one frame and returns its length in words.
pub fn encodeChain(out: []u32, cfg: Config, f: Frame) Error!usize {
    const w: u32 = cfg.width;
    const h: u32 = cfg.height;
    const mbw = cfg.mbWidth();
    const mbh = cfg.mbHeight();
    const qp: u32 = @min(f.qp, 51);
    const p: u32 = @intFromBool(!f.idr);
    if (mbw == 0 or mbh == 0 or mbw > 256 or mbh > 256) return error.BadFrame;
    for ([_]u32{ f.out, f.work }) |a| if (a % address_align != 0) return error.BadFrame;
    if (f.recon_chroma % recon_align != 0) return error.BadFrame;

    var header: [slice_header_max]u8 = undefined;
    const header_len = sliceHeader(f, &header);
    const state = cabacStates(f.idr, f.qp);

    var c: helix.Chain = .{ .out = out };
    try c.put(R.tcsm_flush, 0);

    // the picture and where the blocks pass their work on
    try c.put(R.efe_geom, (mbh - 1) << 8 | (mbw - 1));
    try c.put(R.efe_coef_ba, vram.residual);
    try c.put(R.efe_rawy, f.raw_luma);
    try c.put(R.efe_rawu, f.raw_chroma);
    try c.put(R.efe_rawv, 0);
    try c.put(R.efe_raw_strd, w << 16 | w);
    try c.put(R.efe_topmv_ba, vram.top_mv);
    try c.put(R.efe_toppa_ba, vram.top_pa);
    try c.put(R.efe_mechn_ba, vram.me_chain);
    try c.put(R.efe_mauchn_ba, vram.mau_chain);
    try c.put(R.efe_dblkchn_ba, vram.dblk_chain);
    try c.put(R.efe_sdechn_ba, vram.sde_chain);
    try c.put(R.efe_raw_dba, vram.raw);

    // quantiser: one for the frame, no regions of interest, no macroblock
    // rate control, no skin detection (its thresholds are set all the same)
    try c.put(R.efe_roi_max_qp, cfg.max_qp);
    try c.zeros(R.efe_roi_first, 10);
    try c.put(R.efe_qp_gen_tab, vram.qp_table & 0xfffff);
    try c.put(R.efe_cqp_ofst, 0);
    try c.put(R.efe_ssad, 0);
    try c.put(R.efe_dcs, 4 << 20);
    try c.put(R.efe_qpg_ctrl, qp << 8 | @as(u32, cfg.min_qp) << 16 | @as(u32, cfg.max_qp) << 24);
    try c.zeros(R.efe_qpg_cfg0, 7);
    try c.zeros(R.efe_eigen_cfg0, 7);
    try c.zeros(R.efe_diffy_cfg, 3);
    try c.put(R.efe_skin_ctrl, 20 << 8);
    try c.put(R.efe_skin_pthd0, 0xaf8c7864);
    try c.put(R.efe_skin_pthd0 + 4, 0x8c7d6432);
    try c.put(R.efe_skin_pthd0 + 8, 0xe1af9678);
    try c.put(R.efe_skin_qp_ofst, 0x003e3c3a);
    try c.put(R.efe_skin_param0, 0x0c25bd33);
    try c.put(R.efe_skin_param0 + 4, 0x10f65409);
    try c.put(R.efe_skin_param0 + 8, 0x37465405);

    // the previous frame, uncompressed
    try c.put(R.jrfd_ctrl, 2 << 28 | h << 14 | w);
    try c.put(R.jrfd_hdya, 0);
    try c.put(R.jrfd_hdca, 0);
    try c.put(R.jrfd_hstr, ((((w + 63) >> 6) * mbh) & 0xffff) << 16 | ((((w + 31) >> 5) * mbh) & 0xffff));
    try c.put(R.jrfd_bdya, f.ref_luma);
    try c.put(R.jrfd_bdca, f.ref_chroma);
    try c.put(R.jrfd_bstr, (mbw * 16) << 16 | mbw * 8);
    try c.zeros(R.jrfd_mhdy, 4);
    try c.put(R.jrfd_trig, 1 << 5);

    if (!f.idr) {
        // motion search: quarter pel, 16x16, a wider search on large pictures
        try c.put(R.mce_chn_ba, vram.me_chain);
        try c.put(R.mce_tmv_ba, vram.top_mv);
        try c.put(R.mce_chn_sync, vram.sync_me);
        try c.put(R.mce_frm_size, (h - 1) << 16 | (w - 1));
        try c.put(R.mce_frm_strd, (mbw * 16) << 16 | mbw * 16);
        try c.put(R.mce_comp_ctrl, 0x800a8021);
        try c.put(R.mce_esti_ctrl, 0x873f5008);
        try c.put(R.mce_mrgi, 0);
        try c.put(R.mce_mvr, 0x03fc03fc);
        try c.put(R.mce_refy0, f.ref_luma);
        try c.put(R.mce_refc0, f.ref_chroma);
        try c.put(R.mce_refy0_1, 0);
        try c.put(R.mce_refc0_1, 0);
        try c.put(R.mce_refy1, 0);
        try c.put(R.mce_refc1, 0);
        try c.put(R.mce_slc_spos, 0);
        try c.put(R.mce_fsc, if (mbw > 50 and mbh > 38) 0x88080303 else 0);
        try c.put(R.mce_glb_mv, 0);
        try c.put(R.mce_glb_ctrl, 0x547fdeb1);
    }

    // mode decision and transform
    try c.put(R.vmau_gbl_run, 4); // reset
    try c.put(R.vmau_video_type, 0x80000b00 | @as(u32, @intFromBool(f.idr)) << 12);
    try c.put(R.vmau_ncchn_addr, vram.mau_chain);
    try c.put(R.vmau_enc_done, vram.dummy);
    try c.put(R.vmau_dec_done, vram.sync_mau);
    try c.put(R.vmau_y_gs, (mbh * 16) << 16 | mbw * 16);
    try c.put(R.vmau_gbl_ctr, 0x01000001);
    try c.put(R.vmau_deadzone, 0x0b150b15);
    try c.put(R.vmau_deadzone1, 0x0b5552d5);
    try c.put(R.vmau_top_base, vram.top_pa);
    try c.put(R.vmau_md_cfg0, (mbh - 1) << 24 | (mbw - 1) << 16 | (if (f.idr) @as(u32, 1) else 2));
    try c.put(R.vmau_md_cfg1, 0x0000c200);
    try c.put(R.vmau_md_cfg2, 0xcc000000);
    try c.put(R.vmau_md_cfg3, 0);
    try c.put(R.vmau_md_cfg4, 0);
    try c.put(R.vmau_md_cfg5, 0);
    try c.put(R.vmau_md_cfg6, 0x55004304);
    try c.put(R.vmau_md_cfg7, qp << 17 | 0x11);
    try c.put(R.vmau_md_cfg8, 0);
    try c.put(R.vmau_md_cfg9, 0);
    try c.put(R.vmau_md_cfg11, 0x02000000);
    try c.put(R.vmau_acmask, 0xffff8002);
    for (0..40) |_| try c.put(R.vmau_md_mode, 0);
    // it estimates the bits of its choices with the entropy coder's contexts
    for (0..42) |slot| try c.put(R.vmau_ctx, state[modeContext(slot, f.idr)]);
    for (coefficient_runs) |run| {
        for (0..run[0]) |i| try c.put(R.vmau_ctx_cfbc, state[run[1] + i]);
    }
    try c.put(R.vmau_ipred_cfg0, 0x30000006);
    try c.put(R.vmau_ipred_cfg0 + 4, 0x44444444);
    try c.put(R.vmau_ipred_cfg0 + 8, 0);
    try c.put(R.vmau_ipred_cfg0 + 12, 0x00430000);
    try c.put(R.vmau_ipred_cfg0 + 16, 0);
    try c.put(R.vmau_ipred_cfg0 + 20, 0);
    try scalingLists(&c);
    try c.put(R.vmau_gbl_run, 1);

    try c.put(R.dblk_cfg, @as(u32, @intFromBool(!cfg.deblock)) << 17 | 12 << 8 | 12);
    try c.put(R.dblk_trig, 8);

    // entropy coder: CABAC, the slice's quantiser and kind, its contexts
    try c.put(R.sde_stat, 0);
    try c.put(R.sde_gl_ctrl, 0x11);
    try c.put(R.sde_sl_geom, mbh << 24 | mbw << 16);
    try c.put(R.sde_codec_id, 2);
    try c.put(R.sde_cfg0, 3);
    try c.put(R.sde_cfg1, 1 << 20 | qp << 8 | 1 << 7 | 1 << 4 | (p + 1));
    try c.put(R.sde_cfg2, vram.sde_chain);
    try c.put(R.sde_cfg3, vram.sync_sde);
    try c.put(R.sde_cfg4, 0);
    for (state, 0..) |s, i| {
        const probability: usize = if (s <= 63) 63 - s else s - 64;
        try c.put(R.sde_ctx_tbl + @as(u32, @intCast(i)) * 4, lps_range[probability] | (s >> 6 & 1));
    }
    try c.put(R.sde_sl_ctrl, 2);

    // output and scratch memory; small pictures use the slower memory mode
    const work = f.work & ~@as(u32, address_align - 1);
    try c.put(R.emc_frm_size, @as(u32, @intFromBool(mbw - 1 <= 32)) << 18 | (mbh - 1) << 8 | (mbw - 1));
    try c.put(R.emc_bs_addr, f.out & ~@as(u32, address_align - 1));
    var at = work;
    try c.put(R.emc_dblk_addr, at);
    at += work_dblk;
    try c.put(R.emc_recon_addr, at);
    at += work_recon;
    try c.put(R.emc_mv_addr, at);
    at += work_mv;
    try c.put(R.emc_se_addr, at);
    at += work_se;
    try c.put(R.emc_qpt_addr, at);
    at += work_qpt_rc;
    try c.put(R.emc_cpx_addr, at);
    at += work_cpx;
    try c.put(R.emc_mod_addr, at);
    at += work_mod;
    try c.put(R.emc_ncu_addr, at + work_sad);
    try c.put(R.emc_sad_addr, at);
    try c.put(R.emc_bs_size, 0);
    try c.put(R.emc_slv_init, 1);

    try c.put(R.sch_schc, 0);
    try c.put(R.sch_bnd, 0);
    try c.zeros(R.sch_schg0, 6);
    try c.put(R.sch_schc, 0x08080400 | p << 2);
    try c.put(R.sch_bnd, 0x97850f02 | p);

    // this frame's reconstruction, the next frame's reference
    const chroma_row = mbw * 128;
    const chroma_span = chroma_row * (mbh + 4);
    try c.put(R.odma_ctrl, 1 << 31 | @as(u32, @intFromBool((chroma_span - 384) % chroma_row == 0)) << 29 | h << 14 | w);
    try c.put(R.odma_bdya, f.recon_luma);
    try c.put(R.odma_bdca, f.recon_chroma);
    try c.put(R.odma_bstr, (mbw * 16) << 16 | mbw * 8);
    try c.zeros(R.odma_hdya, 4);
    try c.put(R.odma_trig, 1 << 5);

    try c.put(R.ifa_frm_size, ((h - 1) & 0xfff) << 16 | ((w - 1) & 0xfff));
    try c.put(R.ifa_rawy_ba, f.raw_luma);
    try c.put(R.ifa_rawc_ba, f.raw_chroma);
    try c.put(R.ifa_refy_ba0, f.ref_luma);
    try c.put(R.ifa_refc_ba0, f.ref_chroma);
    try c.put(R.ifa_refy_ba1, 0);
    try c.put(R.ifa_refc_ba1, 0);
    try c.put(R.ifa_raw_str, w << 16 | w);
    try c.put(R.ifa_thrd_y, 0);
    try c.put(R.ifa_thrd_c, 0);
    try c.put(R.ifa_ctrl, 0x0002ff21);

    // the slice header, a word at a time
    try c.put(R.sde_cfg5, 1);
    try c.put(R.sde_cfg6, @intCast(header_len - 1));
    var i: usize = 0;
    while (i < header_len) : (i += 4) {
        try c.put(R.sde_cfg7, std.mem.readInt(u32, header[i..][0..4], .little));
    }
    try c.put(R.sde_cfg5, 2);

    // go
    try c.last(R.efe_ctrl, 1 << 31 | 1 << 30 | qp << 8 | @as(u32, @intFromBool(h % 16 != 0)) << 7 |
        1 << 5 | p << 4 | raw_nv12 | 1 << 1 | 1);
    return c.n;
}

/// The two 8x8 matrices in the order the codec walks a macroblock (four 4x4
/// quarters), first as reciprocals for the quantiser, then as they are.
fn scalingLists(c: *helix.Chain) Error!void {
    var z: [2][64]u8 = undefined;
    for ([_]*const [64]u8{ &matrix_intra, &matrix_inter }, 0..) |m, k| {
        for (0..64) |j| {
            const x = j % 8;
            const y = j / 8;
            z[k][16 * ((y / 4) * 2 + x / 4) + 4 * (y % 4) + x % 4] = m[j];
        }
    }
    var reg: u32 = R.vmau_scaling;
    for (z) |m| {
        for (0..32) |j| {
            const a: u32 = (1 << 12) / @as(u32, m[2 * j]);
            const b: u32 = (1 << 12) / @as(u32, m[2 * j + 1]);
            try c.put(reg, (b & 0xfff) << 12 | (a & 0xfff));
            reg += 4;
        }
    }
    for (z) |m| {
        for (0..16) |j| {
            var v: u32 = 0;
            for (0..4) |k| v |= @as(u32, m[4 * j + k] & 0x3f) << @intCast(6 * k);
            try c.put(reg, v);
            reg += 4;
        }
    }
}

// ---- tests ----

const testing = std.testing;

/// frames set up by the vendor's driver, built for this machine: per case 32
/// words of settings, its parameter sets (256 bytes), slice header (128),
/// CABAC states (1024) and chain
const vendor = @embedFile("testdata/h264-frames.vendor");

const VendorCase = struct {
    cfg: Config,
    frame: Frame,
    sets: []const u8,
    header: []const u8,
    states: []const u8,
    chain: []const u8,
};

fn vendorWord(at: usize) u32 {
    return std.mem.readInt(u32, vendor[at..][0..4], .little);
}

fn vendorCase(pos: *usize) ?VendorCase {
    if (pos.* >= vendor.len) return null;
    const at = pos.*;
    const idr = vendorWord(at + 12) != 0;
    const words = vendorWord(at + 88);
    const sets = at + 128;
    const header = sets + 256;
    const states = header + 128;
    const chain = states + 1024;
    pos.* = chain + words * 4;
    return .{
        .cfg = .{
            .width = @intCast(vendorWord(at)),
            .height = @intCast(vendorWord(at + 4)),
            .level = @intCast(vendorWord(at + 8)),
            .min_qp = @intCast(vendorWord(at + 24)),
            .max_qp = @intCast(vendorWord(at + 28)),
            .deblock = vendorWord(at + 32) != 0,
        },
        .frame = .{
            .idr = idr,
            .qp = @intCast(vendorWord(at + (if (idr) @as(usize, 16) else 20))),
            .number = vendorWord(at + 36),
            .idr_id = @intCast(vendorWord(at + 40)),
            .raw_luma = vendorWord(at + 48),
            .raw_chroma = vendorWord(at + 52),
            .recon_luma = vendorWord(at + 56),
            .recon_chroma = vendorWord(at + 60),
            .ref_luma = vendorWord(at + 64),
            .ref_chroma = vendorWord(at + 68),
            .out = vendorWord(at + 72),
            .work = vendorWord(at + 76),
        },
        .sets = vendor[sets..][0..vendorWord(at + 80)],
        .header = vendor[header..][0..vendorWord(at + 84)],
        .states = vendor[states..][0..460],
        .chain = vendor[chain..][0 .. words * 4],
    };
}

test "parameter sets as the vendor's driver writes them" {
    var pos: usize = 0;
    var cases: usize = 0;
    while (vendorCase(&pos)) |v| : (cases += 1) {
        var out: [parameter_sets_max]u8 = undefined;
        const n = parameterSets(v.cfg, &out);
        try testing.expectEqualSlices(u8, v.sets, out[0..n]);
    }
    try testing.expect(cases >= 20);
}

test "slice headers as the vendor's driver writes them" {
    var pos: usize = 0;
    while (vendorCase(&pos)) |v| {
        var out: [slice_header_max]u8 = undefined;
        const n = sliceHeader(v.frame, &out);
        try testing.expectEqualSlices(u8, v.header, out[0..n]);
    }
}

test "CABAC start states as the vendor's driver computes them" {
    var pos: usize = 0;
    while (vendorCase(&pos)) |v| {
        const states = cabacStates(v.frame.idr, v.frame.qp);
        try testing.expectEqualSlices(u8, v.states, &states);
    }
}

test "frame chains as the vendor's driver builds them" {
    var pos: usize = 0;
    var case: usize = 0;
    while (vendorCase(&pos)) |v| : (case += 1) {
        var words: [chain_words]u32 = undefined;
        const n = try encodeChain(&words, v.cfg, v.frame);
        try testing.expectEqual(v.chain.len / 4, n);
        for (words[0..n], 0..) |word, i| {
            const want = std.mem.readInt(u32, v.chain[i * 4 ..][0..4], .little);
            if (want != word) {
                std.debug.print("case {d} ({d}x{d} idr {}): word {d} (register {x}) is {x}, the vendor has {x}\n", .{
                    case, v.cfg.width, v.cfg.height, v.frame.idr, i, helix.entryRegister(words[i | 1]), word, want,
                });
                return error.TestExpectedEqual;
            }
        }
    }
}

test "a chain that does not fit and addresses the codec cannot take" {
    const cfg: Config = .{ .width = 1280, .height = 720 };
    var f: Frame = .{ .idr = true, .qp = 30, .number = 0, .raw_luma = 0x100000, .raw_chroma = 0x200000, .recon_luma = 0x300000, .recon_chroma = 0x400000, .ref_luma = 0x500000, .ref_chroma = 0x600000, .out = 0x700000, .work = 0x800000 };
    var short: [1000]u32 = undefined;
    try testing.expectError(error.ChainTooLong, encodeChain(&short, cfg, f));
    var words: [chain_words]u32 = undefined;
    f.out += 4;
    try testing.expectError(error.BadFrame, encodeChain(&words, cfg, f));
}
