//! Frosted glass for the desktop widget cards.
//!
//! The shell's surface sits straight on the wallpaper (swaybg, `-m fill`),
//! so instead of asking the compositor to blur behind every card — a pass
//! over the whole screen each frame — it keeps its own blurred copy of the
//! wallpaper and paints each card with the part that lies under it, tinted
//! with the theme. That is the frosted look, for one decode and blur per
//! wallpaper change:
//!
//!   * decoded at a quarter of the screen's long side (about 480x270 for
//!     1080p, ~0.5 MB) — the blur removes the detail anyway, and bilinear
//!     sampling upscales it smoothly;
//!   * three box-blur passes (a near-Gaussian), done once;
//!   * mapped exactly like swaybg's fill mode (scale to cover, centered), so
//!     what shows through a card lines up with the wallpaper around it.
//!
//! A card is the sample, tinted toward the theme's card color, lifted a
//! touch, with antialiased rounded corners and a hairline border that is
//! brighter at the top (light catching the glass edge). Without a wallpaper
//! image (plain color, or not found) cards fall back to the flat tint.

const std = @import("std");
const pixbuf = @import("gdkpixbuf");

pub const Backdrop = struct {
    pixels: []u32 = &.{},
    w: u32 = 0,
    h: u32 = 0,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,

    pub fn ready(self: *const Backdrop) bool {
        return self.pixels.len > 0;
    }

    pub fn deinit(self: *Backdrop, gpa: std.mem.Allocator) void {
        if (self.pixels.len > 0) gpa.free(self.pixels);
        self.* = .{};
    }

    /// Loads and blurs `path` unless it is the image already loaded.
    /// Returns true when the backdrop changed (cards need repainting).
    pub fn loadIfChanged(self: *Backdrop, gpa: std.mem.Allocator, path: []const u8, screen_long_side: u32) bool {
        if (path.len == 0) {
            const had = self.ready();
            self.deinit(gpa);
            return had;
        }
        if (self.ready() and std.mem.eql(u8, path, self.path_buf[0..self.path_len])) return false;
        if (path.len >= self.path_buf.len) return false;

        var zbuf: [512]u8 = undefined;
        @memcpy(zbuf[0..path.len], path);
        zbuf[path.len] = 0;
        const target: c_int = @intCast(@max(160, screen_long_side / 4));
        const pb = pixbuf.simpbar_pixbuf_load(@ptrCast(&zbuf), target) orelse {
            self.deinit(gpa);
            return true;
        };
        defer pixbuf.simpbar_pixbuf_free(pb);

        const w: u32 = @intCast(pixbuf.simpbar_pixbuf_width(pb));
        const h: u32 = @intCast(pixbuf.simpbar_pixbuf_height(pb));
        const stride: usize = @intCast(pixbuf.simpbar_pixbuf_rowstride(pb));
        const ch: usize = @intCast(pixbuf.simpbar_pixbuf_channels(pb));
        const src = pixbuf.simpbar_pixbuf_pixels(pb);
        if (w == 0 or h == 0 or ch < 3) return false;

        const px = gpa.alloc(u32, @as(usize, w) * h) catch return false;
        for (0..h) |y| {
            for (0..w) |x| {
                const p = src + y * stride + x * ch;
                px[y * w + x] = 0xFF000000 | (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | p[2];
            }
        }
        boxBlur(gpa, px, w, h, @max(2, w / 80)) catch {};

        if (self.pixels.len > 0) gpa.free(self.pixels);
        self.pixels = px;
        self.w = w;
        self.h = h;
        @memcpy(self.path_buf[0..path.len], path);
        self.path_len = path.len;
        return true;
    }

    /// Wallpaper color at screen pixel (sx, sy) on a screen_w x screen_h
    /// output, through swaybg's fill mapping, bilinearly filtered.
    fn sample(self: *const Backdrop, sx: f32, sy: f32, screen_w: f32, screen_h: f32) u32 {
        const fw: f32 = @floatFromInt(self.w);
        const fh: f32 = @floatFromInt(self.h);
        const scale = @max(screen_w / fw, screen_h / fh);
        const ox = (screen_w - fw * scale) / 2.0;
        const oy = (screen_h - fh * scale) / 2.0;
        const ix = std.math.clamp((sx - ox) / scale - 0.5, 0.0, fw - 1.001);
        const iy = std.math.clamp((sy - oy) / scale - 0.5, 0.0, fh - 1.001);
        const x0: usize = @intFromFloat(@floor(ix));
        const y0: usize = @intFromFloat(@floor(iy));
        const tx = ix - @floor(ix);
        const ty = iy - @floor(iy);
        const x1 = @min(x0 + 1, self.w - 1);
        const y1 = @min(y0 + 1, self.h - 1);
        const a = self.pixels[y0 * self.w + x0];
        const b = self.pixels[y0 * self.w + x1];
        const c = self.pixels[y1 * self.w + x0];
        const d = self.pixels[y1 * self.w + x1];
        return lerpRgb(lerpRgb(a, b, tx), lerpRgb(c, d, tx), ty);
    }
};

/// Three separable box-blur passes (horizontal then vertical), radius r:
/// a close Gaussian approximation in O(pixels) per pass.
fn boxBlur(gpa: std.mem.Allocator, px: []u32, w: u32, h: u32, r: u32) !void {
    const tmp = try gpa.alloc(u32, px.len);
    defer gpa.free(tmp);
    for (0..3) |_| {
        blurLine(px, tmp, w, h, r, true);
        blurLine(tmp, px, w, h, r, false);
    }
}

fn blurLine(src: []const u32, dst: []u32, w: u32, h: u32, r: u32, horizontal: bool) void {
    const lines: usize = if (horizontal) h else w;
    const n: usize = if (horizontal) w else h;
    const win: u32 = 2 * r + 1;
    for (0..lines) |line| {
        const at = struct {
            fn idx(hz: bool, ln: usize, i: usize, ww: u32) usize {
                return if (hz) ln * ww + i else i * ww + ln;
            }
        };
        var sr: u32 = 0;
        var sg: u32 = 0;
        var sb: u32 = 0;
        // Window centered on 0, edges clamped.
        var k: i64 = -@as(i64, r);
        while (k <= r) : (k += 1) {
            const i: usize = @intCast(std.math.clamp(k, 0, @as(i64, @intCast(n - 1))));
            const p = src[at.idx(horizontal, line, i, w)];
            sr += (p >> 16) & 0xFF;
            sg += (p >> 8) & 0xFF;
            sb += p & 0xFF;
        }
        for (0..n) |i| {
            dst[at.idx(horizontal, line, i, w)] = 0xFF000000 | ((sr / win) << 16) | ((sg / win) << 8) | (sb / win);
            const out_i: usize = @intCast(std.math.clamp(@as(i64, @intCast(i)) - @as(i64, r), 0, @as(i64, @intCast(n - 1))));
            const in_i: usize = @intCast(std.math.clamp(@as(i64, @intCast(i)) + @as(i64, r) + 1, 0, @as(i64, @intCast(n - 1))));
            const po = src[at.idx(horizontal, line, out_i, w)];
            const pi = src[at.idx(horizontal, line, in_i, w)];
            sr = sr + ((pi >> 16) & 0xFF) - ((po >> 16) & 0xFF);
            sg = sg + ((pi >> 8) & 0xFF) - ((po >> 8) & 0xFF);
            sb = sb + (pi & 0xFF) - (po & 0xFF);
        }
    }
}

fn lerpRgb(a: u32, b: u32, t: f32) u32 {
    const ar: f32 = @floatFromInt((a >> 16) & 0xFF);
    const ag: f32 = @floatFromInt((a >> 8) & 0xFF);
    const ab: f32 = @floatFromInt(a & 0xFF);
    const br: f32 = @floatFromInt((b >> 16) & 0xFF);
    const bg: f32 = @floatFromInt((b >> 8) & 0xFF);
    const bb: f32 = @floatFromInt(b & 0xFF);
    const r: u32 = @intFromFloat(@round(ar + (br - ar) * t));
    const g: u32 = @intFromFloat(@round(ag + (bg - ag) * t));
    const bl: u32 = @intFromFloat(@round(ab + (bb - ab) * t));
    return 0xFF000000 | (r << 16) | (g << 8) | bl;
}

/// Scales every channel (alpha too) by `cov`: the tile is premultiplied, so
/// an antialiased edge fades without a dark fringe.
fn withCoverage(p: u32, cov: f32) u32 {
    if (cov >= 1.0) return p;
    var out: u32 = 0;
    var shift: u5 = 0;
    while (true) : (shift += 8) {
        const v: f32 = @floatFromInt((p >> shift) & 0xFF);
        out |= (@as(u32, @intFromFloat(@round(v * cov))) & 0xFF) << shift;
        if (shift == 24) break;
    }
    return out;
}

/// Signed distance from (px, py) to a w x h rounded rect at the origin.
fn roundedDist(px: f32, py: f32, w: f32, h: f32, r: f32) f32 {
    const qx = @abs(px - w / 2.0) - (w / 2.0 - r);
    const qy = @abs(py - h / 2.0) - (h / 2.0 - r);
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0) - r;
}

pub const CardStyle = struct {
    /// Theme card color and how much of it covers the glass (0-100).
    tint: u32,
    tint_pct: u32,
    radius: u32,
};

/// Paints one card into a tile (tw x th, premultiplied ARGB) whose top-left
/// sits at (origin_x, origin_y) on a screen_w x screen_h output.
/// With no backdrop the card is the flat tint at tint_pct opacity.
pub fn paintCard(tile: []u32, tw: u32, th: u32, origin_x: i32, origin_y: i32, screen_w: u32, screen_h: u32, bd: *const Backdrop, style: CardStyle) void {
    const w: f32 = @floatFromInt(tw);
    const h: f32 = @floatFromInt(th);
    const r: f32 = @min(@as(f32, @floatFromInt(style.radius)), @min(w, h) / 2.0);
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const t: f32 = @as(f32, @floatFromInt(@min(style.tint_pct, 100))) / 100.0;
    const glass = bd.ready();
    // Frosted glass reads lighter than the picture under it: a little white.
    const lift: u32 = 0xFFFFFFFF;
    const tint = style.tint | 0xFF000000;
    // Without a wallpaper image: the flat tint at its own opacity.
    const flat_op: f32 = @max(t, 0.35);

    for (0..th) |yy| {
        const fy = @as(f32, @floatFromInt(yy)) + 0.5;
        // Edge highlight: bright along the top, fading down the sides.
        const edge_t = std.math.clamp(fy / h, 0.0, 1.0);
        const edge_a = 0.30 - 0.20 * edge_t;
        for (0..tw) |xx| {
            const fx = @as(f32, @floatFromInt(xx)) + 0.5;
            const dist = roundedDist(fx, fy, w, h, r);
            const cov = std.math.clamp(0.5 - dist, 0.0, 1.0);
            const idx = yy * tw + xx;
            if (cov <= 0.0) {
                tile[idx] = 0;
                continue;
            }
            // Opaque color and opacity, combined with the edge coverage last.
            var col: u32 = tint;
            var op: f32 = flat_op;
            if (glass) {
                const base = bd.sample(@as(f32, @floatFromInt(origin_x)) + fx, @as(f32, @floatFromInt(origin_y)) + fy, sw, sh);
                col = lerpRgb(lerpRgb(base, tint, t), lift, 0.05);
                op = 1.0;
            }
            // Hairline border inside the edge (about 1 px), lighter at the top.
            const band = std.math.clamp(1.5 + dist, 0.0, 1.0);
            if (band > 0.0) {
                col = lerpRgb(col, lift, band * edge_a);
                op = @max(op, band * 0.7);
            }
            tile[idx] = withCoverage(col, op * cov);
        }
    }
}
