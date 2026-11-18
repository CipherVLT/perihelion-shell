// Display settings for Mango: what the Display page in Perihelion Settings
// reads and writes, kept free of GTK so it can be tested on its own.
//
//   - the connected outputs and their full mode lists, from `wlr-randr`
//     (disabled outputs included, so one switched off can be switched back);
//   - Mango monitor_rule values (`name:DP-1, width:2560, ...`): read and
//     set single keys without disturbing the rest;
//   - colour management presets, the nine Hyprland offers, mapped onto what
//     Mango 0.18 has: an ICC profile per monitor (`icc:`) and HDR (`hdr:`).
//     Mango has no gamut presets of its own, so dcip3 / dp3 / adobe / wide /
//     edid write a small matrix-shaper ICC profile describing the monitor as
//     having those primaries; sRGB content is then mapped into that gamut,
//     which is what Hyprland's `cm` does. hdr turns on Mango's HDR (BT.2020,
//     PQ); hdredid also passes the monitor's own EDID luminance to it;
//   - the night light settings file (perihelion-nightlight runs wlsunset).

const std = @import("std");
const mon = @import("monitors.zig");

pub const MAX_OUT = 8;

// ---------------------------------------------------------------------
// Outputs (wlr-randr)
// ---------------------------------------------------------------------

pub const Output = struct {
    name_buf: [32]u8 = undefined,
    name_len: usize = 0,
    desc_buf: [96]u8 = undefined,
    desc_len: usize = 0,
    enabled: bool = true,
    width: i32 = 0,
    height: i32 = 0,
    hz: f64 = 0,
    x: i32 = 0,
    y: i32 = 0,
    scale: f64 = 1.0,
    transform: u8 = 0,
    caps: mon.OutputCaps = .{},

    pub fn name(self: *const Output) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn desc(self: *const Output) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }
};

/// wlr-randr's transform names, in Mango's `rr` order (0-7, the
/// wl_output_transform values).
pub const transform_names = [_][]const u8{ "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" };
pub const transform_labels = [_][:0]const u8{ "0° normal", "90°", "180°", "270°", "Flipped", "Flipped 90°", "Flipped 180°", "Flipped 270°" };

fn leadingFloat(s: []const u8) ?f64 {
    var e: usize = 0;
    while (e < s.len and (std.ascii.isDigit(s[e]) or s[e] == '.' or (e == 0 and s[e] == '-'))) e += 1;
    if (e == 0) return null;
    return std.fmt.parseFloat(f64, s[0..e]) catch null;
}

/// "2560x1440 px, 239.960007 Hz (preferred, current)" -> w, h, hz.
fn parseModeLine(t: []const u8, w: *i32, h: *i32, hz: *f64) bool {
    const x = std.mem.indexOfScalar(u8, t, 'x') orelse return false;
    w.* = std.fmt.parseInt(i32, t[0..x], 10) catch return false;
    var e = x + 1;
    while (e < t.len and std.ascii.isDigit(t[e])) e += 1;
    h.* = std.fmt.parseInt(i32, t[x + 1 .. e], 10) catch return false;
    const comma = std.mem.indexOfScalarPos(u8, t, e, ',') orelse return false;
    hz.* = leadingFloat(std.mem.trim(u8, t[comma + 1 ..], " \t")) orelse return false;
    return w.* > 0 and h.* > 0;
}

/// Parses `wlr-randr` output: every output, enabled or not, with its current
/// mode, position, scale, transform and full mode list.
pub fn parseWlrRandr(text: []const u8, out: []Output) usize {
    var n: usize = 0;
    var cur: ?*Output = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] != ' ' and line[0] != '\t') {
            cur = null;
            if (n >= out.len) continue;
            const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
            if (sp == 0) continue;
            const o = &out[n];
            o.* = .{};
            const nl = @min(sp, o.name_buf.len);
            @memcpy(o.name_buf[0..nl], line[0..nl]);
            o.name_len = nl;
            // `DP-1 "Dell Inc. DELL U2720Q ABC123 (DP-1)"`
            if (std.mem.indexOfScalar(u8, line, '"')) |q| {
                const rest = line[q + 1 ..];
                var d = rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse rest.len];
                if (std.mem.lastIndexOf(u8, d, " (")) |p| d = d[0..p];
                const dl = @min(d.len, o.desc_buf.len);
                @memcpy(o.desc_buf[0..dl], d[0..dl]);
                o.desc_len = dl;
            }
            cur = o;
            n += 1;
            continue;
        }
        const o = cur orelse continue;
        const t = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, t, "Enabled:")) {
            o.enabled = std.ascii.eqlIgnoreCase(std.mem.trim(u8, t[8..], " \t"), "yes");
        } else if (std.mem.startsWith(u8, t, "Position:")) {
            const r = std.mem.trim(u8, t[9..], " \t");
            const c = std.mem.indexOfScalar(u8, r, ',') orelse continue;
            o.x = std.fmt.parseInt(i32, std.mem.trim(u8, r[0..c], " \t"), 10) catch o.x;
            o.y = std.fmt.parseInt(i32, std.mem.trim(u8, r[c + 1 ..], " \t"), 10) catch o.y;
        } else if (std.mem.startsWith(u8, t, "Scale:")) {
            o.scale = leadingFloat(std.mem.trim(u8, t[6..], " \t")) orelse o.scale;
        } else if (std.mem.startsWith(u8, t, "Transform:")) {
            const v = std.mem.trim(u8, t[10..], " \t");
            for (transform_names, 0..) |tn, i| {
                if (std.mem.eql(u8, v, tn)) o.transform = @intCast(i);
            }
        } else if (std.mem.indexOf(u8, t, " Hz") != null and t.len > 0 and std.ascii.isDigit(t[0])) {
            var w: i32 = 0;
            var h: i32 = 0;
            var hz: f64 = 0;
            if (!parseModeLine(t, &w, &h, &hz)) continue;
            o.caps.addMode(w, h, hz);
            if (std.mem.indexOf(u8, t, "current") != null) {
                o.width = w;
                o.height = h;
                o.hz = hz;
            }
        }
    }
    for (out[0..n]) |*o| o.caps.sortModes();
    return n;
}

// ---------------------------------------------------------------------
// monitor_rule values
// ---------------------------------------------------------------------

/// The value of `key` in a rule value ("" when absent).
pub fn getField(value: []const u8, key: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        const c = std.mem.indexOfScalar(u8, p, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, p[0..c], " \t"), key)) return std.mem.trim(u8, p[c + 1 ..], " \t");
    }
    return "";
}

const Buf = struct {
    b: []u8,
    n: usize = 0,
    ok: bool = true,
    fn s(self: *Buf, t: []const u8) void {
        if (self.n + t.len > self.b.len) {
            self.ok = false;
            return;
        }
        @memcpy(self.b[self.n..][0..t.len], t);
        self.n += t.len;
    }
    fn pair(self: *Buf, k: []const u8, v: []const u8) void {
        if (self.n != 0) self.s(", ");
        self.s(k);
        self.s(":");
        self.s(v);
    }
};

/// `value` with `key` set to `new` (appended when absent), or removed when
/// `new` is "". Every other pair is kept as it was. Null when `out` is too
/// small.
pub fn setField(value: []const u8, key: []const u8, new: []const u8, out: []u8) ?[]const u8 {
    var b = Buf{ .b = out };
    var saw = false;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        const c = std.mem.indexOfScalar(u8, p, ':');
        const pk = if (c) |cc| std.mem.trim(u8, p[0..cc], " \t") else p;
        if (std.mem.eql(u8, pk, key)) {
            if (saw or new.len == 0) {
                saw = true;
                continue;
            }
            saw = true;
            b.pair(key, new);
        } else {
            if (b.n != 0) b.s(", ");
            b.s(p);
        }
    }
    if (!saw and new.len != 0) b.pair(key, new);
    return if (b.ok) out[0..b.n] else null;
}

/// A rule for an output that has none yet, from its live state, so the
/// first change keeps everything else as it is now.
pub fn baseRule(o: *const Output, out: []u8) ?[]const u8 {
    var b = Buf{ .b = out };
    var tmp: [48]u8 = undefined;
    b.pair("name", o.name());
    if (o.width > 0 and o.height > 0 and o.hz > 0) {
        b.pair("width", std.fmt.bufPrint(&tmp, "{d}", .{o.width}) catch return null);
        b.pair("height", std.fmt.bufPrint(&tmp, "{d}", .{o.height}) catch return null);
        b.pair("refresh", fmtHz(o.hz, &tmp));
    }
    b.pair("x", std.fmt.bufPrint(&tmp, "{d}", .{o.x}) catch return null);
    b.pair("y", std.fmt.bufPrint(&tmp, "{d}", .{o.y}) catch return null);
    if (o.scale != 1.0) b.pair("scale", fmtScale(o.scale, &tmp));
    if (o.transform != 0) b.pair("rr", std.fmt.bufPrint(&tmp, "{d}", .{o.transform}) catch return null);
    if (!o.enabled) b.pair("disable", "1");
    return if (b.ok) out[0..b.n] else null;
}

/// A refresh rate as Mango reads it: exact to the millihertz, so the
/// nearest-mode match picks this mode and not a neighbour (59.94 vs 60).
pub fn fmtHz(hz: f64, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.3}", .{hz}) catch "60.000";
}

pub fn fmtScale(s: f64, buf: []u8) []const u8 {
    const t = std.fmt.bufPrint(buf, "{d:.2}", .{s}) catch return "1";
    var e = t.len;
    while (e > 0 and t[e - 1] == '0') e -= 1;
    if (e > 0 and t[e - 1] == '.') e -= 1;
    return t[0..e];
}

// ---------------------------------------------------------------------
// Colour management presets
// ---------------------------------------------------------------------

pub const Preset = enum(u8) { auto, srgb, dcip3, dp3, adobe, wide, edid, hdr, hdredid };
pub const preset_names = [_][:0]const u8{ "auto", "srgb", "dcip3", "dp3", "adobe", "wide", "edid", "hdr", "hdredid" };

pub fn presetFromName(s: []const u8) ?Preset {
    for (preset_names, 0..) |n, i| {
        if (std.mem.eql(u8, s, n)) return @enumFromInt(i);
    }
    return null;
}

/// What a preset does in Mango, for the row's subtitle.
pub fn presetHelp(p: Preset) [:0]const u8 {
    return switch (p) {
        .auto => "Mango's standard output: sRGB, 8 bits per channel.",
        .srgb => "sRGB primaries, Mango's standard output.",
        .dcip3 => "For a DCI-P3 panel: colours are mapped into DCI-P3 (via a generated ICC profile).",
        .dp3 => "For a Display P3 panel: colours are mapped into Apple's P3 (via a generated ICC profile).",
        .adobe => "For an Adobe RGB panel: colours are mapped into Adobe RGB (via a generated ICC profile).",
        .wide => "For a wide-gamut panel: colours are mapped into BT.2020 (via a generated ICC profile).",
        .edid => "Uses the primaries the monitor reports in its EDID (often inaccurate).",
        .hdr => "Turns on HDR: BT.2020 and PQ. Needs an HDR monitor and GPU support.",
        .hdredid => "HDR, with the brightness range the monitor reports in its EDID.",
    };
}

pub fn presetUsesIcc(p: Preset) bool {
    return switch (p) {
        .dcip3, .dp3, .adobe, .wide, .edid => true,
        else => false,
    };
}

pub const Xy = struct { x: f64, y: f64 };
pub const Primaries = struct { r: Xy, g: Xy, b: Xy, w: Xy };

pub const D65 = Xy{ .x = 0.3127, .y = 0.3290 };
pub const prim_srgb = Primaries{ .r = .{ .x = 0.64, .y = 0.33 }, .g = .{ .x = 0.30, .y = 0.60 }, .b = .{ .x = 0.15, .y = 0.06 }, .w = D65 };
pub const prim_dcip3 = Primaries{ .r = .{ .x = 0.680, .y = 0.320 }, .g = .{ .x = 0.265, .y = 0.690 }, .b = .{ .x = 0.150, .y = 0.060 }, .w = .{ .x = 0.314, .y = 0.351 } };
pub const prim_dp3 = Primaries{ .r = .{ .x = 0.680, .y = 0.320 }, .g = .{ .x = 0.265, .y = 0.690 }, .b = .{ .x = 0.150, .y = 0.060 }, .w = D65 };
pub const prim_adobe = Primaries{ .r = .{ .x = 0.64, .y = 0.33 }, .g = .{ .x = 0.21, .y = 0.71 }, .b = .{ .x = 0.15, .y = 0.06 }, .w = D65 };
pub const prim_bt2020 = Primaries{ .r = .{ .x = 0.708, .y = 0.292 }, .g = .{ .x = 0.170, .y = 0.797 }, .b = .{ .x = 0.131, .y = 0.046 }, .w = D65 };

pub fn presetPrimaries(p: Preset) ?Primaries {
    return switch (p) {
        .dcip3 => prim_dcip3,
        .dp3 => prim_dp3,
        .adobe => prim_adobe,
        .wide => prim_bt2020,
        else => null,
    };
}

/// The colour keys a preset owns in a rule; applying a preset replaces them.
const colour_keys = [_][]const u8{ "icc", "hdr", "hdr_min_lum", "hdr_max_lum", "hdr_max_avg_lum" };

pub const Luminance = struct { max: f64, max_avg: f64, min: f64 };

/// `value` with the colour keys replaced for preset `p`. `icc_path` is the
/// generated profile (ICC presets); `lum` the EDID luminance (hdredid).
pub fn applyPreset(value: []const u8, p: Preset, icc_path: []const u8, lum: ?Luminance, out: []u8) ?[]const u8 {
    var a: [1024]u8 = undefined;
    var b: [1024]u8 = undefined;
    var cur: []const u8 = value;
    var flip = false;
    for (colour_keys) |k| {
        const dst: []u8 = if (flip) &b else &a;
        cur = setField(cur, k, "", dst) orelse return null;
        flip = !flip;
    }
    var tmp: [32]u8 = undefined;
    var dst: []u8 = if (flip) &b else &a;
    switch (p) {
        .auto, .srgb => {},
        .dcip3, .dp3, .adobe, .wide, .edid => {
            if (icc_path.len == 0) return null;
            cur = setField(cur, "icc", icc_path, dst) orelse return null;
        },
        .hdr, .hdredid => {
            cur = setField(cur, "hdr", "1", dst) orelse return null;
            if (p == .hdredid) {
                if (lum) |l| {
                    if (l.max > 0) {
                        flip = !flip;
                        dst = if (flip) &b else &a;
                        cur = setField(cur, "hdr_max_lum", std.fmt.bufPrint(&tmp, "{d:.1}", .{l.max}) catch return null, dst) orelse return null;
                        flip = !flip;
                        dst = if (flip) &b else &a;
                        cur = setField(cur, "hdr_max_avg_lum", std.fmt.bufPrint(&tmp, "{d:.1}", .{l.max_avg}) catch return null, dst) orelse return null;
                        flip = !flip;
                        dst = if (flip) &b else &a;
                        cur = setField(cur, "hdr_min_lum", std.fmt.bufPrint(&tmp, "{d:.4}", .{l.min}) catch return null, dst) orelse return null;
                    }
                }
            }
        },
    }
    if (cur.len > out.len) return null;
    @memcpy(out[0..cur.len], cur);
    return out[0..cur.len];
}

/// The preset a rule describes. `remembered` is the last choice saved for
/// this output: Mango's output is the same for auto and srgb (and for hdr
/// and hdredid when the EDID gave no luminance), so it tells them apart.
/// Null when the rule has an ICC profile Perihelion didn't generate.
pub fn presetOfRule(value: []const u8, remembered: ?Preset) ?Preset {
    if (std.mem.eql(u8, getField(value, "hdr"), "1")) {
        if (getField(value, "hdr_max_lum").len != 0) return .hdredid;
        if (remembered) |r| {
            if (r == .hdredid) return .hdredid;
        }
        return .hdr;
    }
    const icc = getField(value, "icc");
    if (icc.len != 0) {
        // Ours are named <output>.<preset>.icc.
        const base = icc[(if (std.mem.lastIndexOfScalar(u8, icc, '/')) |s| s + 1 else 0)..];
        if (!std.mem.endsWith(u8, base, ".icc")) return null;
        const stem = base[0 .. base.len - 4];
        const dot = std.mem.lastIndexOfScalar(u8, stem, '.') orelse return null;
        const p = presetFromName(stem[dot + 1 ..]) orelse return null;
        return if (presetUsesIcc(p)) p else null;
    }
    if (remembered) |r| {
        if (r == .srgb) return .srgb;
    }
    return .auto;
}

/// The preset remembered for `output` in the presets file ("DP-1=srgb" lines).
pub fn rememberedIn(text: []const u8, output: []const u8) ?Preset {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..eq], output)) return presetFromName(line[eq + 1 ..]);
    }
    return null;
}

/// The presets file with `output`'s line set to `p`.
pub fn withRemembered(text: []const u8, output: []const u8, p: Preset, out: []u8) ?[]const u8 {
    var b = Buf{ .b = out };
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..eq], output)) continue;
        b.s(line);
        b.s("\n");
    }
    b.s(output);
    b.s("=");
    b.s(preset_names[@intFromEnum(p)]);
    b.s("\n");
    return if (b.ok) out[0..b.n] else null;
}

test "remembered presets file" {
    const t = std.testing;
    var b: [128]u8 = undefined;
    const one = withRemembered("", "DP-1", .srgb, &b).?;
    try t.expectEqualStrings("DP-1=srgb\n", one);
    var b2: [128]u8 = undefined;
    const two = withRemembered(one, "HDMI-A-1", .hdr, &b2).?;
    var b3: [128]u8 = undefined;
    const three = withRemembered(two, "DP-1", .auto, &b3).?;
    try t.expectEqualStrings("HDMI-A-1=hdr\nDP-1=auto\n", three);
    try t.expectEqual(Preset.hdr, rememberedIn(three, "HDMI-A-1").?);
    try t.expect(rememberedIn(three, "DP-2") == null);
}

// ---------------------------------------------------------------------
// EDID
// ---------------------------------------------------------------------

fn edidValid(e: []const u8) bool {
    const hdr = [_]u8{ 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 };
    return e.len >= 128 and std.mem.eql(u8, e[0..8], &hdr);
}

/// The chromaticities in the EDID base block (bytes 25-34, 10 bits each).
pub fn edidPrimaries(e: []const u8) ?Primaries {
    if (!edidValid(e)) return null;
    const lo1 = e[25];
    const lo2 = e[26];
    const f = struct {
        fn v(hi: u8, lo: u8, shift: u3) f64 {
            const bits: u16 = (@as(u16, hi) << 2) | ((lo >> shift) & 3);
            return @as(f64, @floatFromInt(bits)) / 1024.0;
        }
    }.v;
    const p = Primaries{
        .r = .{ .x = f(e[27], lo1, 6), .y = f(e[28], lo1, 4) },
        .g = .{ .x = f(e[29], lo1, 2), .y = f(e[30], lo1, 0) },
        .b = .{ .x = f(e[31], lo2, 6), .y = f(e[32], lo2, 4) },
        .w = .{ .x = f(e[33], lo2, 2), .y = f(e[34], lo2, 0) },
    };
    // A blank or nonsense block (all zero y) can't make a profile.
    if (p.r.y <= 0 or p.g.y <= 0 or p.b.y <= 0 or p.w.y <= 0) return null;
    return p;
}

/// The HDR static metadata block of the EDID's CTA-861 extension: the
/// panel's desired max, max frame-average and min luminance in cd/m².
pub fn edidLuminance(e: []const u8) ?Luminance {
    if (!edidValid(e)) return null;
    const ext = e[126];
    var i: usize = 1;
    while (i <= ext and (i + 1) * 128 <= e.len) : (i += 1) {
        const blk = e[i * 128 .. (i + 1) * 128];
        if (blk[0] != 0x02) continue;
        const end = @min(@as(usize, blk[2]), 127);
        var p: usize = 4;
        while (p < end) {
            const tag = blk[p] >> 5;
            const len: usize = blk[p] & 0x1f;
            if (p + 1 + len > 128) break;
            if (tag == 7 and len >= 4 and blk[p + 1] == 6) {
                const pl = blk[p + 1 .. p + 1 + len];
                const max = 50.0 * std.math.pow(f64, 2.0, @as(f64, @floatFromInt(pl[3])) / 32.0);
                const avg = if (len >= 5) 50.0 * std.math.pow(f64, 2.0, @as(f64, @floatFromInt(pl[4])) / 32.0) else max;
                const minv = if (len >= 6) blk: {
                    const c: f64 = @as(f64, @floatFromInt(pl[5])) / 255.0;
                    break :blk max * c * c / 100.0;
                } else 0.0;
                return .{ .max = max, .max_avg = avg, .min = minv };
            }
            p += 1 + len;
        }
    }
    return null;
}

// ---------------------------------------------------------------------
// ICC profiles (v2 display class, matrix/TRC, gamma 2.2)
// ---------------------------------------------------------------------

const M3 = [3][3]f64;

fn mul(a: M3, b: M3) M3 {
    var r: M3 = undefined;
    for (0..3) |i| {
        for (0..3) |j| r[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
    }
    return r;
}

fn mulv(a: M3, v: [3]f64) [3]f64 {
    return .{
        a[0][0] * v[0] + a[0][1] * v[1] + a[0][2] * v[2],
        a[1][0] * v[0] + a[1][1] * v[1] + a[1][2] * v[2],
        a[2][0] * v[0] + a[2][1] * v[1] + a[2][2] * v[2],
    };
}

fn inv(m: M3) ?M3 {
    const det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
        m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
        m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    if (@abs(det) < 1e-12) return null;
    const d = 1.0 / det;
    return .{
        .{ (m[1][1] * m[2][2] - m[1][2] * m[2][1]) * d, (m[0][2] * m[2][1] - m[0][1] * m[2][2]) * d, (m[0][1] * m[1][2] - m[0][2] * m[1][1]) * d },
        .{ (m[1][2] * m[2][0] - m[1][0] * m[2][2]) * d, (m[0][0] * m[2][2] - m[0][2] * m[2][0]) * d, (m[0][2] * m[1][0] - m[0][0] * m[1][2]) * d },
        .{ (m[1][0] * m[2][1] - m[1][1] * m[2][0]) * d, (m[0][1] * m[2][0] - m[0][0] * m[2][1]) * d, (m[0][0] * m[1][1] - m[0][1] * m[1][0]) * d },
    };
}

fn xyz(c: Xy) [3]f64 {
    return .{ c.x / c.y, 1.0, (1.0 - c.x - c.y) / c.y };
}

const D50 = [3]f64{ 0.9642, 1.0, 0.8249 };

/// RGB -> XYZ for these primaries, Bradford-adapted to D50 (the ICC PCS).
/// Its columns are the profile's rXYZ, gXYZ and bXYZ.
pub fn rgbToXyzD50(p: Primaries) ?M3 {
    const r = xyz(p.r);
    const g = xyz(p.g);
    const b = xyz(p.b);
    const w = xyz(p.w);
    const m: M3 = .{ .{ r[0], g[0], b[0] }, .{ r[1], g[1], b[1] }, .{ r[2], g[2], b[2] } };
    const s = mulv(inv(m) orelse return null, w);
    const rgb: M3 = .{
        .{ m[0][0] * s[0], m[0][1] * s[1], m[0][2] * s[2] },
        .{ m[1][0] * s[0], m[1][1] * s[1], m[1][2] * s[2] },
        .{ m[2][0] * s[0], m[2][1] * s[1], m[2][2] * s[2] },
    };
    const brad: M3 = .{ .{ 0.8951, 0.2664, -0.1614 }, .{ -0.7502, 1.7135, 0.0367 }, .{ 0.0389, -0.0685, 1.0296 } };
    const cs = mulv(brad, w);
    const cd = mulv(brad, D50);
    const scale: M3 = .{ .{ cd[0] / cs[0], 0, 0 }, .{ 0, cd[1] / cs[1], 0 }, .{ 0, 0, cd[2] / cs[2] } };
    const adapt = mul(inv(brad) orelse return null, mul(scale, brad));
    return mul(adapt, rgb);
}

fn put32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .big);
}

fn s15(v: f64) u32 {
    const i: i32 = @intFromFloat(@round(v * 65536.0));
    return @bitCast(i);
}

fn putXyz(b: []u8, at: usize, v: [3]f64) void {
    @memcpy(b[at..][0..4], "XYZ ");
    put32(b, at + 4, 0);
    put32(b, at + 8, s15(v[0]));
    put32(b, at + 12, s15(v[1]));
    put32(b, at + 16, s15(v[2]));
}

/// A v2 monitor profile for primaries `p` with a gamma-2.2 curve.
/// Returns the bytes written to `out` (about 500), or null.
pub fn makeIcc(p: Primaries, description: []const u8, out: []u8) ?[]const u8 {
    const m = rgbToXyzD50(p) orelse return null;
    const desc = description[0..@min(description.len, 64)];
    const cprt = "No copyright, use freely";
    const sigs = [_]*const [4]u8{ "desc", "cprt", "wtpt", "rXYZ", "gXYZ", "bXYZ", "rTRC", "gTRC", "bTRC" };
    const ntags = sigs.len;
    const desc_size: usize = 12 + desc.len + 1 + 4 + 4 + 2 + 1 + 67;
    const cprt_size: usize = 8 + cprt.len + 1;
    const xyz_size: usize = 20;
    const curv_size: usize = 14;
    const al = struct {
        fn a(v: usize) usize {
            return (v + 3) & ~@as(usize, 3);
        }
    }.a;
    var off: usize = 128 + 4 + ntags * 12;
    const desc_off = off;
    off += al(desc_size);
    const cprt_off = off;
    off += al(cprt_size);
    const wtpt_off = off;
    off += xyz_size;
    const r_off = off;
    off += xyz_size;
    const g_off = off;
    off += xyz_size;
    const b_off = off;
    off += xyz_size;
    const trc_off = off;
    off += al(curv_size);
    const total = off;
    if (out.len < total) return null;
    const buf = out[0..total];
    @memset(buf, 0);

    // Header
    put32(buf, 0, @intCast(total));
    put32(buf, 8, 0x02100000);
    @memcpy(buf[12..16], "mntr");
    @memcpy(buf[16..20], "RGB ");
    @memcpy(buf[20..24], "XYZ ");
    std.mem.writeInt(u16, buf[24..26], 2026, .big);
    std.mem.writeInt(u16, buf[26..28], 1, .big);
    std.mem.writeInt(u16, buf[28..30], 1, .big);
    @memcpy(buf[36..40], "acsp");
    put32(buf, 68, s15(D50[0]));
    put32(buf, 72, s15(D50[1]));
    put32(buf, 76, s15(D50[2]));

    // Tag table
    put32(buf, 128, ntags);
    const offs = [_]usize{ desc_off, cprt_off, wtpt_off, r_off, g_off, b_off, trc_off, trc_off, trc_off };
    const sizes = [_]usize{ desc_size, cprt_size, xyz_size, xyz_size, xyz_size, xyz_size, curv_size, curv_size, curv_size };
    for (sigs, 0..) |sig, i| {
        const at = 132 + i * 12;
        @memcpy(buf[at..][0..4], sig);
        put32(buf, at + 4, @intCast(offs[i]));
        put32(buf, at + 8, @intCast(sizes[i]));
    }

    // desc (textDescriptionType)
    @memcpy(buf[desc_off..][0..4], "desc");
    put32(buf, desc_off + 8, @intCast(desc.len + 1));
    @memcpy(buf[desc_off + 12 ..][0..desc.len], desc);
    // cprt (textType)
    @memcpy(buf[cprt_off..][0..4], "text");
    @memcpy(buf[cprt_off + 8 ..][0..cprt.len], cprt);
    // White point and primaries (D50-adapted)
    putXyz(buf, wtpt_off, D50);
    putXyz(buf, r_off, .{ m[0][0], m[1][0], m[2][0] });
    putXyz(buf, g_off, .{ m[0][1], m[1][1], m[2][1] });
    putXyz(buf, b_off, .{ m[0][2], m[1][2], m[2][2] });
    // One shared gamma-2.2 curve (u8Fixed8: 2.2 = 0x0233)
    @memcpy(buf[trc_off..][0..4], "curv");
    put32(buf, trc_off + 8, 1);
    std.mem.writeInt(u16, buf[trc_off + 12 ..][0..2], 0x0233, .big);
    return buf;
}

// ---------------------------------------------------------------------
// Night light (perihelion-nightlight / wlsunset)
// ---------------------------------------------------------------------

pub const Schedule = enum(u8) { manual, always };
pub const schedule_labels = [_][:0]const u8{ "Manual", "Always on" };

pub const NightLight = struct {
    enabled: bool = false,
    schedule: Schedule = .manual,
    day: i32 = 6500,
    night: i32 = 4000,
    start: i32 = 20 * 60, // minutes after midnight
    end: i32 = 6 * 60,
    follow_sun: bool = false,
    lat: f64 = 0,
    lon: f64 = 0,
};

pub fn parseNightLight(text: []const u8) NightLight {
    var nl = NightLight{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, k, "enabled")) nl.enabled = std.mem.eql(u8, v, "1");
        if (std.mem.eql(u8, k, "schedule")) nl.schedule = if (std.mem.eql(u8, v, "always")) .always else .manual;
        if (std.mem.eql(u8, k, "day")) nl.day = std.math.clamp(std.fmt.parseInt(i32, v, 10) catch nl.day, 1000, 10000);
        if (std.mem.eql(u8, k, "night")) nl.night = std.math.clamp(std.fmt.parseInt(i32, v, 10) catch nl.night, 1000, 10000);
        if (std.mem.eql(u8, k, "start")) nl.start = std.math.clamp(std.fmt.parseInt(i32, v, 10) catch nl.start, 0, 1439);
        if (std.mem.eql(u8, k, "end")) nl.end = std.math.clamp(std.fmt.parseInt(i32, v, 10) catch nl.end, 0, 1439);
        if (std.mem.eql(u8, k, "follow_sun")) nl.follow_sun = std.mem.eql(u8, v, "1");
        if (std.mem.eql(u8, k, "lat")) nl.lat = std.math.clamp(std.fmt.parseFloat(f64, v) catch nl.lat, -90, 90);
        if (std.mem.eql(u8, k, "lon")) nl.lon = std.math.clamp(std.fmt.parseFloat(f64, v) catch nl.lon, -180, 180);
    }
    return nl;
}

pub fn formatNightLight(nl: NightLight, out: []u8) ?[]const u8 {
    return std.fmt.bufPrint(out,
        \\# Perihelion night light (Settings → Display). perihelion-nightlight
        \\# reads this and runs wlsunset. Times are minutes after midnight.
        \\enabled={d}
        \\schedule={s}
        \\day={d}
        \\night={d}
        \\start={d}
        \\end={d}
        \\follow_sun={d}
        \\lat={d:.2}
        \\lon={d:.2}
        \\
    , .{
        @intFromBool(nl.enabled),
        if (nl.schedule == .always) "always" else "manual",
        nl.day,
        nl.night,
        nl.start,
        nl.end,
        @intFromBool(nl.follow_sun),
        nl.lat,
        nl.lon,
    }) catch null;
}

/// "20:00" for 1200.
pub fn fmtClock(minutes: i32, buf: []u8) []const u8 {
    if (buf.len < 5) return "00:00";
    const m: u32 = @intCast(std.math.clamp(minutes, 0, 1439));
    const h = m / 60;
    const mm = m % 60;
    buf[0] = '0' + @as(u8, @intCast(h / 10));
    buf[1] = '0' + @as(u8, @intCast(h % 10));
    buf[2] = ':';
    buf[3] = '0' + @as(u8, @intCast(mm / 10));
    buf[4] = '0' + @as(u8, @intCast(mm % 10));
    return buf[0..5];
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const sample_randr =
    \\DP-1 "Dell Inc. DELL S2721DGF ABC123 (DP-1)"
    \\  Make: Dell Inc.
    \\  Model: DELL S2721DGF
    \\  Physical size: 600x340 mm
    \\  Enabled: yes
    \\  Modes:
    \\    2560x1440 px, 59.951000 Hz
    \\    2560x1440 px, 239.960007 Hz (preferred, current)
    \\    2560x1440 px, 143.912003 Hz
    \\    1920x1080 px, 60.000000 Hz
    \\  Position: 2560,0
    \\  Transform: 90
    \\  Scale: 1.250000
    \\  Adaptive Sync: disabled
    \\DP-2 "LG Electronics 27GL850 XYZ (DP-2)"
    \\  Enabled: no
    \\  Modes:
    \\    2560x1440 px, 144.000000 Hz (preferred)
    \\  Position: 0,0
    \\  Transform: normal
    \\  Scale: 1.000000
    \\
;

test "wlr-randr: every output, its current mode and full mode list" {
    const t = std.testing;
    var outs: [MAX_OUT]Output = undefined;
    const n = parseWlrRandr(sample_randr, &outs);
    try t.expectEqual(@as(usize, 2), n);
    const a = &outs[0];
    try t.expectEqualStrings("DP-1", a.name());
    try t.expectEqualStrings("Dell Inc. DELL S2721DGF ABC123", a.desc());
    try t.expect(a.enabled);
    try t.expectEqual(@as(i32, 2560), a.width);
    try t.expectApproxEqAbs(@as(f64, 239.960007), a.hz, 1e-6);
    try t.expectEqual(@as(i32, 2560), a.x);
    try t.expectEqual(@as(u8, 1), a.transform);
    try t.expectApproxEqAbs(@as(f64, 1.25), a.scale, 1e-9);
    try t.expectEqualStrings("2560x1440", a.caps.resolution(0));
    try t.expectEqual(@as(usize, 3), a.caps.hzList(0).len);
    try t.expectApproxEqAbs(@as(f64, 239.960007), a.caps.hzList(0)[0], 1e-6); // highest first
    try t.expectEqualStrings("1920x1080", a.caps.resolution(1));
    try t.expect(!outs[1].enabled); // a disabled output is still listed
    try t.expectEqualStrings("DP-2", outs[1].name());
}

test "rule fields: set, replace, remove, keep the rest" {
    const t = std.testing;
    var b: [256]u8 = undefined;
    const v = "name:DP-1, width:2560, height:1440, refresh:239.960, x:0, y:0, vrr:1";
    try t.expectEqualStrings("1440", getField(v, "height"));
    try t.expectEqualStrings("name:DP-1, width:1920, height:1440, refresh:239.960, x:0, y:0, vrr:1", setField(v, "width", "1920", &b).?);
    try t.expectEqualStrings("name:DP-1, width:2560, height:1440, refresh:239.960, x:0, y:0", setField(v, "vrr", "", &b).?);
    try t.expectEqualStrings(v ++ ", scale:1.5", setField(v, "scale", "1.5", &b).?);
    var small: [8]u8 = undefined;
    try t.expect(setField(v, "x", "1", &small) == null);
}

test "base rule from the live output; exact refresh" {
    const t = std.testing;
    var outs: [MAX_OUT]Output = undefined;
    _ = parseWlrRandr(sample_randr, &outs);
    var b: [256]u8 = undefined;
    try t.expectEqualStrings("name:DP-1, width:2560, height:1440, refresh:239.960, x:2560, y:0, scale:1.25, rr:1", baseRule(&outs[0], &b).?);
    try t.expectEqualStrings("name:DP-2, x:0, y:0, disable:1", baseRule(&outs[1], &b).?);
    var s: [16]u8 = undefined;
    try t.expectEqualStrings("2", fmtScale(2.0, &s));
    try t.expectEqualStrings("1.5", fmtScale(1.5, &s));
}

test "presets map onto Mango's icc and hdr keys, and read back" {
    const t = std.testing;
    var b: [512]u8 = undefined;
    const base = "name:DP-1, width:2560, height:1440, refresh:239.960, vrr:1";
    const p3 = applyPreset(base, .dcip3, "/home/u/.local/share/perihelion/icc/DP-1.dcip3.icc", null, &b).?;
    try t.expectEqualStrings(base ++ ", icc:/home/u/.local/share/perihelion/icc/DP-1.dcip3.icc", p3);
    try t.expectEqual(Preset.dcip3, presetOfRule(p3, null).?);
    var b2: [512]u8 = undefined;
    const h = applyPreset(p3, .hdr, "", null, &b2).?;
    try t.expectEqualStrings(base ++ ", hdr:1", h);
    try t.expectEqual(Preset.hdr, presetOfRule(h, null).?);
    var b3: [512]u8 = undefined;
    const he = applyPreset(h, .hdredid, "", .{ .max = 1015.6, .max_avg = 403.0, .min = 0.0123 }, &b3).?;
    try t.expectEqualStrings(base ++ ", hdr:1, hdr_max_lum:1015.6, hdr_max_avg_lum:403.0, hdr_min_lum:0.0123", he);
    try t.expectEqual(Preset.hdredid, presetOfRule(he, null).?);
    var b4: [512]u8 = undefined;
    const back = applyPreset(he, .srgb, "", null, &b4).?;
    try t.expectEqualStrings(base, back);
    try t.expectEqual(Preset.srgb, presetOfRule(back, .srgb).?);
    try t.expectEqual(Preset.auto, presetOfRule(back, null).?);
    // Someone else's ICC profile: not one of the presets.
    try t.expect(presetOfRule("name:DP-1, icc:/usr/share/color/icc/mine.icc", null) == null);
    try t.expect(applyPreset(base, .adobe, "", null, &b) == null); // an ICC preset needs its file
}

test "ICC: sRGB primaries give the standard D50 colorants; structure is sound" {
    const t = std.testing;
    const m = rgbToXyzD50(prim_srgb).?;
    // The colorants of the well-known sRGB ICC profile.
    try t.expectApproxEqAbs(@as(f64, 0.4361), m[0][0], 2e-3);
    try t.expectApproxEqAbs(@as(f64, 0.2225), m[1][0], 2e-3);
    try t.expectApproxEqAbs(@as(f64, 0.3851), m[0][1], 2e-3);
    try t.expectApproxEqAbs(@as(f64, 0.7169), m[1][1], 2e-3);
    try t.expectApproxEqAbs(@as(f64, 0.1431), m[0][2], 2e-3);
    try t.expectApproxEqAbs(@as(f64, 0.7141), m[2][2], 2e-3);
    // White (R+G+B) lands on D50.
    try t.expectApproxEqAbs(@as(f64, 0.9642), m[0][0] + m[0][1] + m[0][2], 1e-3);
    try t.expectApproxEqAbs(@as(f64, 0.8249), m[2][0] + m[2][1] + m[2][2], 1e-3);

    var buf: [1024]u8 = undefined;
    const icc = makeIcc(prim_dcip3, "Perihelion DCI-P3 (DP-1)", &buf).?;
    try t.expectEqual(@as(u32, @intCast(icc.len)), std.mem.readInt(u32, icc[0..4], .big));
    try t.expectEqualStrings("acsp", icc[36..40]);
    try t.expectEqualStrings("mntr", icc[12..16]);
    const ntags = std.mem.readInt(u32, icc[128..132], .big);
    try t.expectEqual(@as(u32, 9), ntags);
    for (0..ntags) |i| {
        const at = 132 + i * 12;
        const off = std.mem.readInt(u32, icc[at + 4 ..][0..4], .big);
        const size = std.mem.readInt(u32, icc[at + 8 ..][0..4], .big);
        try t.expect(off % 4 == 0 and off + size <= icc.len);
    }
}

test "ICC files for every gamut preset, for the lcms check in CI" {
    // Written to /tmp so CI can open them with Little CMS (the library
    // wlroots uses) and convert a colour through each.
    const dir = "/tmp/perihelion-icc-test";
    _ = mkdir(dir, 0o755);
    const presets = [_]Preset{ .dcip3, .dp3, .adobe, .wide };
    for (presets) |p| {
        var buf: [1024]u8 = undefined;
        const icc = makeIcc(presetPrimaries(p).?, preset_names[@intFromEnum(p)], &buf).?;
        var pb: [128]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&pb, "{s}/{s}.icc", .{ dir, preset_names[@intFromEnum(p)] });
        try std.testing.expect(writeFileZ(path, icc));
    }
    var buf: [1024]u8 = undefined;
    const e = sampleEdid();
    const icc = makeIcc(edidPrimaries(&e).?, "edid", &buf).?;
    try std.testing.expect(writeFileZ(dir ++ "/edid.icc", icc));
}

fn sampleEdid() [256]u8 {
    var e = [_]u8{0} ** 256;
    const hdr = [_]u8{ 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 };
    @memcpy(e[0..8], &hdr);
    // Chromaticity of a typical wide-gamut panel: R .6806/.3095 G .2617/.6826
    // B .1494/.0605 W .3125/.3291 (10-bit codes split hi/lo as in the spec).
    const codes = [_]u16{ 697, 317, 268, 699, 153, 62, 320, 337 };
    e[25] = @intCast(((codes[0] & 3) << 6) | ((codes[1] & 3) << 4) | ((codes[2] & 3) << 2) | (codes[3] & 3));
    e[26] = @intCast(((codes[4] & 3) << 6) | ((codes[5] & 3) << 4) | ((codes[6] & 3) << 2) | (codes[7] & 3));
    for (codes, 0..) |c, i| e[27 + i] = @intCast(c >> 2);
    e[126] = 1;
    // CTA-861 extension with an HDR static metadata block:
    // tag 7 (extended), len 6, ext tag 6, EOTF, SM, max 115, avg 75, min 10
    e[128] = 0x02;
    e[129] = 0x03;
    e[130] = 4 + 7;
    e[132] = (7 << 5) | 6;
    e[133] = 6;
    e[134] = 0x05;
    e[135] = 0x01;
    e[136] = 115;
    e[137] = 75;
    e[138] = 10;
    return e;
}

test "EDID: primaries and HDR luminance" {
    const t = std.testing;
    const e = sampleEdid();
    const p = edidPrimaries(&e).?;
    try t.expectApproxEqAbs(@as(f64, 697.0 / 1024.0), p.r.x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 699.0 / 1024.0), p.g.y, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 337.0 / 1024.0), p.w.y, 1e-9);
    const l = edidLuminance(&e).?;
    try t.expectApproxEqAbs(50.0 * std.math.pow(f64, 2.0, 115.0 / 32.0), l.max, 1e-6);
    try t.expectApproxEqAbs(50.0 * std.math.pow(f64, 2.0, 75.0 / 32.0), l.max_avg, 1e-6);
    try t.expect(l.min > 0 and l.min < 1);
    var blank = [_]u8{0} ** 128;
    try t.expect(edidPrimaries(&blank) == null);
    try t.expect(edidLuminance(e[0..128]) == null); // no extension block present
}

test "night light settings round-trip; clock labels" {
    const t = std.testing;
    const nl = NightLight{ .enabled = true, .schedule = .always, .day = 6200, .night = 3400, .start = 1290, .end = 375, .follow_sun = true, .lat = 41.88, .lon = -87.63 };
    var b: [512]u8 = undefined;
    const text = formatNightLight(nl, &b).?;
    const back = parseNightLight(text);
    try t.expect(back.enabled and back.follow_sun);
    try t.expectEqual(Schedule.always, back.schedule);
    try t.expectEqual(@as(i32, 3400), back.night);
    try t.expectEqual(@as(i32, 1290), back.start);
    try t.expectApproxEqAbs(@as(f64, -87.63), back.lon, 1e-9);
    const d = parseNightLight("night=99999\nlat=500\n");
    try t.expectEqual(@as(i32, 10000), d.night);
    try t.expectApproxEqAbs(@as(f64, 90), d.lat, 1e-9);
    var c: [8]u8 = undefined;
    try t.expectEqualStrings("20:00", fmtClock(1200, &c));
    try t.expectEqualStrings("06:15", fmtClock(375, &c));
}

// ---------------------------------------------------------------------
// Files (used by the page; libc, like the rest of Settings)
// ---------------------------------------------------------------------

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
extern "c" fn closedir(d: *anyopaque) c_int;
extern "c" fn readdir(d: *anyopaque) ?*Dirent;
const Dirent = extern struct { d_ino: u64, d_off: i64, d_reclen: u16, d_type: u8, d_name: [256]u8 };
const O_RDONLY: c_int = 0;
const O_WRONLY_CREAT_TRUNC: c_int = 0o1 | 0o100 | 0o1000;

pub fn readFileZ(path: [*:0]const u8, buf: []u8) ?[]u8 {
    const fd = open(path, O_RDONLY);
    if (fd < 0) return null;
    defer _ = close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = read(fd, buf[n..].ptr, buf.len - n);
        if (r <= 0) break;
        n += @intCast(r);
    }
    return buf[0..n];
}

/// Writes `data` to `path` through a temporary file and a rename.
pub fn writeFileZ(path: [:0]const u8, data: []const u8) bool {
    var tb: [600]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tb, "{s}.tmp", .{path}) catch return false;
    const fd = open(tmp.ptr, O_WRONLY_CREAT_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return false;
    var n: usize = 0;
    while (n < data.len) {
        const w = write(fd, data[n..].ptr, data.len - n);
        if (w <= 0) {
            _ = close(fd);
            return false;
        }
        n += @intCast(w);
    }
    _ = close(fd);
    return rename(tmp.ptr, path.ptr) == 0;
}

/// mkdir -p for a path under $HOME.
pub fn makeDirs(path: []const u8) void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            var z: [600]u8 = undefined;
            const pz = std.fmt.bufPrintZ(&z, "{s}", .{path[0..i]}) catch return;
            _ = mkdir(pz.ptr, 0o755);
        }
    }
}

/// The EDID of output `name` from /sys/class/drm/card*-<name>/edid.
pub fn readEdid(name: []const u8, buf: []u8) ?[]u8 {
    const d = opendir("/sys/class/drm") orelse return null;
    defer _ = closedir(d);
    while (readdir(d)) |e| {
        const en = std.mem.sliceTo(&e.d_name, 0);
        if (!std.mem.startsWith(u8, en, "card")) continue;
        const dash = std.mem.indexOfScalar(u8, en, '-') orelse continue;
        if (!std.mem.eql(u8, en[dash + 1 ..], name)) continue;
        var pb: [256]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pb, "/sys/class/drm/{s}/edid", .{en}) catch continue;
        const got = readFileZ(p.ptr, buf) orelse continue;
        if (got.len >= 128) return got;
    }
    return null;
}
