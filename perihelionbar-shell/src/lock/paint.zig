//! Drawing for perihelion-lockscreen, in plain cairo + pango.
//!
//! The screen: the desktop wallpaper under a light tint and two soft fades,
//! the date and a large clock cut from frosted glass (the clock carries a
//! small AM/PM beside it in 12-hour mode), and a centred login cluster — a
//! glass avatar, the account name, a frosted password pill with a round
//! arrow button, and one hint line ("Press Enter to unlock", "Caps Lock is
//! on", "Checking…", "Incorrect password").
//!
//! Blur is local, as in the design: only the glyphs, the avatar plate and
//! the pill frost what lies behind them. Text is white glass over the
//! wallpaper; the theme (perihelion-theme's matugen.json) supplies the
//! accent ("checking"), the red (wrong password) and the plate shown when
//! the wallpaper cannot be read.
//!
//! No widget tree and no animation beyond the caret: a lock screen should
//! depend on as little as possible.

const std = @import("std");
const c = @import("c.zig");
const logic = @import("logic.zig");
const cairo = c.cairo;
const pango = c.pango;
const Cr = cairo.Context;

/// Inter first (the design's face), then Noto Sans (on every Perihelion
/// install), then whatever fontconfig calls sans.
const FONT_FAMILY = "Inter Variable,Inter,Noto Sans,sans-serif";

pub const View = struct {
    clock: logic.ClockText = .{ .main = "", .suffix = "" },
    date: []const u8 = "",
    user: []const u8 = "",
    hint: logic.Hint = .idle,
    dots: usize = 0,
    caret_on: bool = false,
    avatar: ?*cairo.Surface = null,
    palette: logic.Palette = .{},
};

const Rgba = struct { r: f64, g: f64, b: f64, a: f64 };

fn rgb(hex: u32, a: f64) Rgba {
    return .{
        .r = @as(f64, @floatFromInt((hex >> 16) & 0xff)) / 255.0,
        .g = @as(f64, @floatFromInt((hex >> 8) & 0xff)) / 255.0,
        .b = @as(f64, @floatFromInt(hex & 0xff)) / 255.0,
        .a = a,
    };
}

/// Mixes toward white: theme colours read as light text over dark fades.
fn lighten(col: Rgba, f: f64) Rgba {
    return .{ .r = col.r + (1 - col.r) * f, .g = col.g + (1 - col.g) * f, .b = col.b + (1 - col.b) * f, .a = col.a };
}

const ink: Rgba = .{ .r = 0.95, .g = 0.96, .b = 1.0, .a = 0.96 };
const glass_edge: Rgba = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 0.30 };

fn set(cr: *Cr, col: Rgba) void {
    cairo.cairo_set_source_rgba(cr, col.r, col.g, col.b, col.a);
}

fn circlePath(cr: *Cr, cx: f64, cy: f64, r: f64) void {
    cairo.cairo_new_sub_path(cr);
    cairo.cairo_arc(cr, cx, cy, r, 0, 2.0 * std.math.pi);
    cairo.cairo_close_path(cr);
}

fn roundedRect(cr: *Cr, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const r = @min(radius, @min(w, h) / 2.0);
    cairo.cairo_new_sub_path(cr);
    cairo.cairo_arc(cr, x + w - r, y + r, r, -std.math.pi / 2.0, 0);
    cairo.cairo_arc(cr, x + w - r, y + h - r, r, 0, std.math.pi / 2.0);
    cairo.cairo_arc(cr, x + r, y + h - r, r, std.math.pi / 2.0, std.math.pi);
    cairo.cairo_arc(cr, x + r, y + r, r, std.math.pi, 1.5 * std.math.pi);
    cairo.cairo_close_path(cr);
}

fn fillRounded(cr: *Cr, x: f64, y: f64, w: f64, h: f64, radius: f64, col: Rgba) void {
    roundedRect(cr, x, y, w, h, radius);
    set(cr, col);
    cairo.cairo_fill(cr);
}

fn strokeRounded(cr: *Cr, x: f64, y: f64, w: f64, h: f64, radius: f64, col: Rgba, width: f64) void {
    roundedRect(cr, x, y, w, h, radius);
    set(cr, col);
    cairo.cairo_set_line_width(cr, width);
    cairo.cairo_stroke(cr);
}

fn verticalFade(cr: *Cr, y0: f64, y1: f64, a0: f64, a1: f64) void {
    const pat = cairo.cairo_pattern_create_linear(0, y0, 0, y1) orelse return;
    cairo.cairo_pattern_add_color_stop_rgba(pat, 0, 0, 0, 0, a0);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 1, 0, 0, 0, a1);
    cairo.cairo_set_source(cr, pat);
    cairo.cairo_paint(cr);
    cairo.cairo_pattern_destroy(pat);
}

/// The backdrop every frame starts from, drawn once per output size: the
/// wallpaper (already in the surface when `have_wallpaper`) or the theme's
/// background plate, then the tint and the two fades.
pub fn paintBackdrop(cr: *Cr, h: i32, have_wallpaper: bool, pal: logic.Palette) void {
    const fh: f64 = @floatFromInt(h);
    if (!have_wallpaper) {
        set(cr, rgb(pal.bg, 1.0));
        cairo.cairo_paint(cr);
    }
    set(cr, .{ .r = 0, .g = 0, .b = 0, .a = 0.06 });
    cairo.cairo_paint(cr);
    verticalFade(cr, 0, fh * 0.42, 0.38, 0.0);
    verticalFade(cr, fh * 0.64, fh, 0.0, 0.40);
}

// --- frost: a small box blur of what is already on the surface -----------

const frost_max = 64;

/// Samples the region at about a quarter resolution, box-blurs the cells
/// twice and scales them back with bilinear filtering, clipped to a rounded
/// rectangle. Works on whatever the surface already holds, so every output
/// frosts its own wallpaper.
fn frost(cr: *Cr, x: f64, y: f64, w: f64, h: f64, radius: f64, blur_radius: usize) void {
    const target = cairo.cairo_get_target(cr) orelse return;
    if (cairo.cairo_surface_get_type(target) != cairo.SURFACE_TYPE_IMAGE) return;
    if (x < 0 or y < 0) return;
    const tw = cairo.cairo_image_surface_get_width(target);
    const th = cairo.cairo_image_surface_get_height(target);
    const rw: i32 = @intFromFloat(@ceil(w));
    const rh: i32 = @intFromFloat(@ceil(h));
    const x0: i32 = @intFromFloat(@floor(x));
    const y0: i32 = @intFromFloat(@floor(y));
    if (rw <= 0 or rh <= 0 or x0 + rw > tw or y0 + rh > th) return;

    cairo.cairo_surface_flush(target);
    const data = cairo.cairo_image_surface_get_data(target) orelse return;
    const stride = cairo.cairo_image_surface_get_stride(target);

    const gw: usize = @intCast(@max(4, @min(frost_max, @divTrunc(rw, 4))));
    const gh: usize = @intCast(@max(4, @min(frost_max, @divTrunc(rh, 4))));
    var grid: [frost_max * frost_max]u32 = undefined;
    var tmp: [frost_max * frost_max]u32 = undefined;

    const rwf: f64 = @floatFromInt(rw);
    const rhf: f64 = @floatFromInt(rh);
    const gwf: f64 = @floatFromInt(gw);
    const ghf: f64 = @floatFromInt(gh);
    for (0..gh) |gy| {
        for (0..gw) |gx| {
            const fx = @as(f64, @floatFromInt(x0)) + (@as(f64, @floatFromInt(gx)) + 0.5) * rwf / gwf;
            const fy = @as(f64, @floatFromInt(y0)) + (@as(f64, @floatFromInt(gy)) + 0.5) * rhf / ghf;
            const sx: i32 = @min(tw - 1, @max(0, @as(i32, @intFromFloat(fx))));
            const sy: i32 = @min(th - 1, @max(0, @as(i32, @intFromFloat(fy))));
            const off: usize = @intCast(sy * stride + sx * 4);
            const px: *align(1) const u32 = @ptrCast(data + off);
            grid[gy * gw + gx] = px.*;
        }
    }
    for (0..2) |_| {
        blurPass(grid[0 .. gw * gh], tmp[0 .. gw * gh], gw, gh, blur_radius, true);
        blurPass(tmp[0 .. gw * gh], grid[0 .. gw * gh], gw, gh, blur_radius, false);
    }

    const small = cairo.cairo_image_surface_create_for_data(@ptrCast(&grid), cairo.FORMAT_ARGB32, @intCast(gw), @intCast(gh), @intCast(gw * 4)) orelse return;
    defer cairo.cairo_surface_destroy(small);
    cairo.cairo_save(cr);
    roundedRect(cr, x, y, w, h, radius);
    cairo.cairo_clip(cr);
    cairo.cairo_translate(cr, x, y);
    cairo.cairo_scale(cr, w / gwf, h / ghf);
    cairo.cairo_set_source_surface(cr, small, 0, 0);
    if (cairo.cairo_get_source(cr)) |pat| cairo.cairo_pattern_set_filter(pat, cairo.FILTER_BILINEAR);
    cairo.cairo_paint(cr);
    cairo.cairo_restore(cr);
}

fn blurPass(src: []const u32, dst: []u32, gw: usize, gh: usize, radius: usize, horizontal: bool) void {
    const r: isize = @intCast(radius);
    for (0..gh) |y| {
        for (0..gw) |x| {
            var acc = [4]u64{ 0, 0, 0, 0 };
            var n: u64 = 0;
            var d: isize = -r;
            while (d <= r) : (d += 1) {
                const sx: isize = @as(isize, @intCast(x)) + (if (horizontal) d else 0);
                const sy: isize = @as(isize, @intCast(y)) + (if (horizontal) 0 else d);
                if (sx < 0 or sy < 0 or sx >= @as(isize, @intCast(gw)) or sy >= @as(isize, @intCast(gh))) continue;
                const p = src[@as(usize, @intCast(sy)) * gw + @as(usize, @intCast(sx))];
                acc[0] += (p >> 24) & 0xFF;
                acc[1] += (p >> 16) & 0xFF;
                acc[2] += (p >> 8) & 0xFF;
                acc[3] += p & 0xFF;
                n += 1;
            }
            if (n == 0) n = 1;
            dst[y * gw + x] = (@as(u32, @intCast(acc[0] / n)) << 24) | (@as(u32, @intCast(acc[1] / n)) << 16) |
                (@as(u32, @intCast(acc[2] / n)) << 8) | @as(u32, @intCast(acc[3] / n));
        }
    }
}

// --- text ------------------------------------------------------------------------

/// A laid-out run and its size. Owning the layout lets the clock draw the
/// same glyphs as a shadow and then as glass.
const Text = struct {
    layout: ?*pango.Layout = null,
    w: i32 = 0,
    h: i32 = 0,

    fn init(cr: *Cr, label: []const u8, size: f64, weight: c_int, tracking_px: f64, features: [:0]const u8) Text {
        var self = Text{};
        if (label.len == 0) return self;
        const lo = pango.pango_cairo_create_layout(cr) orelse return self;
        self.layout = lo;
        if (pango.pango_font_description_new()) |desc| {
            defer pango.pango_font_description_free(desc);
            pango.pango_font_description_set_family(desc, FONT_FAMILY);
            pango.pango_font_description_set_weight(desc, weight);
            pango.pango_font_description_set_absolute_size(desc, @max(1.0, size) * pango.SCALE);
            pango.pango_layout_set_font_description(lo, desc);
        }
        pango.pango_layout_set_text(lo, label.ptr, @intCast(label.len));
        // Pango replaces the whole list, so tracking and features go in together.
        if (pango.pango_attr_list_new()) |attrs| {
            defer pango.pango_attr_list_unref(attrs);
            if (tracking_px != 0.0) {
                if (pango.pango_attr_letter_spacing_new(@intFromFloat(tracking_px * pango.SCALE))) |a| pango.pango_attr_list_insert(attrs, a);
            }
            if (features.len > 0) {
                if (pango.pango_attr_font_features_new(features.ptr)) |a| pango.pango_attr_list_insert(attrs, a);
            }
            pango.pango_layout_set_attributes(lo, attrs);
        }
        var w: c_int = 0;
        var h: c_int = 0;
        pango.pango_layout_get_pixel_size(lo, &w, &h);
        self.w = w;
        self.h = h;
        return self;
    }

    fn deinit(self: *Text) void {
        if (self.layout) |lo| pango.g_object_unref(lo);
        self.layout = null;
    }

    fn show(self: *const Text, cr: *Cr, x: f64, y: f64) void {
        const lo = self.layout orelse return;
        cairo.cairo_move_to(cr, x, y);
        pango.pango_cairo_show_layout(cr, lo);
    }

    fn baseline(self: *const Text) f64 {
        const lo = self.layout orelse return 0;
        return @as(f64, @floatFromInt(pango.pango_layout_get_baseline(lo))) / pango.SCALE;
    }

    fn ink(self: *const Text) pango.Rectangle {
        var r = pango.Rectangle{};
        if (self.layout) |lo| pango.pango_layout_get_pixel_extents(lo, &r, null);
        return r;
    }
};

const shadow: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0.16 };

/// One close, faint shadow copy (cairo has no blur), then the text.
fn showShadowed(cr: *Cr, t: *const Text, x: f64, y: f64, off: f64, col: Rgba) void {
    set(cr, shadow);
    t.show(cr, x, y + off);
    set(cr, col);
    t.show(cr, x, y);
}

/// Glyphs as frosted glass: the glyph outline becomes the clip, the
/// wallpaper behind is blurred in place, and a white gradient goes over it.
fn glassGlyphs(cr: *Cr, t: *const Text, x: f64, y: f64, size: f64, top_alpha: f64, bottom_alpha: f64) void {
    const lo = t.layout orelse return;
    const r = t.ink();
    cairo.cairo_save(cr);
    cairo.cairo_move_to(cr, x, y);
    pango.pango_cairo_layout_path(cr, lo);
    cairo.cairo_clip(cr);
    frost(
        cr,
        x + @as(f64, @floatFromInt(r.x)) - 4.0,
        y + @as(f64, @floatFromInt(r.y)) - 4.0,
        @as(f64, @floatFromInt(r.width)) + 8.0,
        @as(f64, @floatFromInt(r.height)) + 8.0,
        0.0,
        3,
    );
    cairo.cairo_restore(cr);

    cairo.cairo_save(cr);
    cairo.cairo_move_to(cr, x, y);
    pango.pango_cairo_layout_path(cr, lo);
    cairo.cairo_clip(cr);
    if (cairo.cairo_pattern_create_linear(0, y, 0, y + size)) |fill| {
        cairo.cairo_pattern_add_color_stop_rgba(fill, 0, 1, 1, 1, top_alpha);
        cairo.cairo_pattern_add_color_stop_rgba(fill, 1, 1, 1, 1, bottom_alpha);
        cairo.cairo_set_source(cr, fill);
        cairo.cairo_paint(cr);
        cairo.cairo_pattern_destroy(fill);
    }
    cairo.cairo_restore(cr);
}

fn drawDate(cr: *Cr, cx: f64, top: f64, size: f64, label: []const u8) void {
    if (label.len == 0) return;
    var t = Text.init(cr, label, size, 600, 0.005 * size, "");
    defer t.deinit();
    if (t.w == 0) return;
    const x = cx - @as(f64, @floatFromInt(t.w)) / 2.0;
    set(cr, shadow);
    t.show(cr, x, top + @max(1.0, size * 0.06));
    glassGlyphs(cr, &t, x, top, size, 0.70, 0.48);
}

/// The big time, tracked tight with tabular figures, and the AM/PM run hung
/// beside it near the baseline. Centred on the time alone.
fn drawClock(cr: *Cr, cx: f64, top: f64, size: f64, clock: logic.ClockText) void {
    if (clock.main.len == 0) return;
    var t = Text.init(cr, clock.main, size, 650, -0.045 * size, "tnum 1");
    defer t.deinit();
    if (t.w == 0) return;
    // Centre the em box in a box `size` tall, like CSS line-height: 1.
    const y = top + (size - @as(f64, @floatFromInt(t.h))) / 2.0;
    const x = cx - @as(f64, @floatFromInt(t.w)) / 2.0;
    const shadow_off = @max(2.0, size * 0.012);

    const suffix_size = size * 0.24;
    var s = Text.init(cr, clock.suffix, suffix_size, 600, 0, "");
    defer s.deinit();
    const sx = x + @as(f64, @floatFromInt(t.w)) + size * 0.12;
    const sy = y + t.baseline() - s.baseline() - size * 0.04;
    const has_suffix = clock.suffix.len > 0 and s.w > 0;

    set(cr, shadow);
    t.show(cr, x, y + shadow_off);
    if (has_suffix) s.show(cr, sx, sy + @max(1.0, suffix_size * 0.05));
    glassGlyphs(cr, &t, x, y, size, 0.66, 0.40);
    if (has_suffix) glassGlyphs(cr, &s, sx, sy, suffix_size, 0.66, 0.46);
}

/// The round avatar: the account photo cover-cropped inside a glass ring,
/// or a frosted plate with the account's initial.
fn drawAvatar(cr: *Cr, cx: f64, cy: f64, diameter: f64, user: []const u8, avatar: ?*cairo.Surface) void {
    if (user.len == 0 and avatar == null) return;
    const r = diameter / 2.0;

    circlePath(cr, cx, cy + @max(2.0, diameter * 0.055), r + 1.0);
    set(cr, .{ .r = 0, .g = 0, .b = 0, .a = 0.26 });
    cairo.cairo_fill(cr);
    circlePath(cr, cx, cy + @max(4.0, diameter * 0.10), r + 1.0);
    set(cr, .{ .r = 0, .g = 0, .b = 0, .a = 0.10 });
    cairo.cairo_fill(cr);

    if (avatar) |surf| {
        const iwf: f64 = @floatFromInt(cairo.cairo_image_surface_get_width(surf));
        const ihf: f64 = @floatFromInt(cairo.cairo_image_surface_get_height(surf));
        if (iwf > 0 and ihf > 0) {
            const scale = @max(diameter / iwf, diameter / ihf);
            cairo.cairo_save(cr);
            circlePath(cr, cx, cy, r);
            cairo.cairo_clip(cr);
            cairo.cairo_translate(cr, cx, cy);
            cairo.cairo_scale(cr, scale, scale);
            cairo.cairo_set_source_surface(cr, surf, -iwf / 2.0, -ihf / 2.0);
            if (cairo.cairo_get_source(cr)) |pat| cairo.cairo_pattern_set_filter(pat, cairo.FILTER_BILINEAR);
            cairo.cairo_paint(cr);
            cairo.cairo_restore(cr);

            // A soft shade at the bottom seats the photo in the ring.
            cairo.cairo_save(cr);
            circlePath(cr, cx, cy, r);
            cairo.cairo_clip(cr);
            if (cairo.cairo_pattern_create_linear(0, cy + r * 0.35, 0, cy + r)) |pat| {
                cairo.cairo_pattern_add_color_stop_rgba(pat, 0, 0, 0, 0, 0);
                cairo.cairo_pattern_add_color_stop_rgba(pat, 1, 0, 0, 0, 0.22);
                cairo.cairo_set_source(cr, pat);
                cairo.cairo_paint(cr);
                cairo.cairo_pattern_destroy(pat);
            }
            cairo.cairo_restore(cr);
        }
    } else {
        frost(cr, cx - r, cy - r, diameter, diameter, r, 3);
        circlePath(cr, cx, cy, r);
        set(cr, .{ .r = 40.0 / 255.0, .g = 46.0 / 255.0, .b = 70.0 / 255.0, .a = 0.50 });
        cairo.cairo_fill(cr);
        circlePath(cr, cx, cy, r);
        if (cairo.cairo_pattern_create_linear(0, cy - r, 0, cy + r)) |pat| {
            cairo.cairo_pattern_add_color_stop_rgba(pat, 0, 1, 1, 1, 0.32);
            cairo.cairo_pattern_add_color_stop_rgba(pat, 1, 1, 1, 1, 0.10);
            cairo.cairo_set_source(cr, pat);
            cairo.cairo_fill(cr);
            cairo.cairo_pattern_destroy(pat);
        } else cairo.cairo_new_path(cr);
    }

    circlePath(cr, cx, cy, r);
    set(cr, .{ .r = 1, .g = 1, .b = 1, .a = 0.32 });
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);
    // A thin highlight along the top inside edge.
    cairo.cairo_new_sub_path(cr);
    cairo.cairo_arc(cr, cx, cy, @max(1.0, r - 0.5), std.math.pi, 2.0 * std.math.pi);
    set(cr, .{ .r = 1, .g = 1, .b = 1, .a = 0.25 });
    cairo.cairo_stroke(cr);

    if (avatar != null) return;
    var ibuf: [4]u8 = undefined;
    const initial = logic.avatarInitial(user, &ibuf);
    if (initial.len == 0) return;
    var t = Text.init(cr, initial, @max(diameter * 0.42, 18.0), 600, 0, "");
    defer t.deinit();
    if (t.w == 0) return;
    const box = t.ink();
    const ix = cx - (@as(f64, @floatFromInt(box.x)) + @as(f64, @floatFromInt(box.width)) / 2.0);
    const iy = cy - (@as(f64, @floatFromInt(box.y)) + @as(f64, @floatFromInt(box.height)) / 2.0);
    set(cr, ink);
    t.show(cr, ix, iy);
}

/// The frosted password pill: blur, a white veil, a sheen across the top,
/// a 1 px rim, the dots (or "Enter Password") and the arrow button.
fn drawField(cr: *Cr, l: *const logic.Layout, view: *const View) void {
    const x = l.field_x;
    const y = l.field_y;
    const w = l.field_w;
    const h = l.field_h;
    const r = h / 2.0;
    const cy = y + h / 2.0;
    const accent = rgb(view.palette.accent, 0.90);
    const danger = rgb(view.palette.danger, 0.90);
    const pending = view.hint == .checking;
    const failed = view.hint == .wrong or view.hint == .unavailable;

    fillRounded(cr, x, y + 4.0, w, h, r, .{ .r = 0, .g = 0, .b = 0, .a = 0.20 });
    fillRounded(cr, x, y + 8.0, w, h, r, .{ .r = 0, .g = 0, .b = 0, .a = 0.08 });
    if (pending) {
        fillRounded(cr, x - 3.0, y - 3.0, w + 6.0, h + 6.0, r + 3.0, rgb(view.palette.accent, 0.18));
    } else if (failed) {
        fillRounded(cr, x - 3.0, y - 3.0, w + 6.0, h + 6.0, r + 3.0, rgb(view.palette.danger, 0.16));
    }

    frost(cr, x, y, w, h, r, 3);
    fillRounded(cr, x, y, w, h, r, .{ .r = 1, .g = 1, .b = 1, .a = 0.10 });
    cairo.cairo_save(cr);
    roundedRect(cr, x, y, w, h, r);
    cairo.cairo_clip(cr);
    if (cairo.cairo_pattern_create_linear(0, y, 0, y + h * 0.55)) |sheen| {
        cairo.cairo_pattern_add_color_stop_rgba(sheen, 0, 1, 1, 1, 0.18);
        cairo.cairo_pattern_add_color_stop_rgba(sheen, 1, 1, 1, 1, 0.0);
        cairo.cairo_set_source(cr, sheen);
        cairo.cairo_paint(cr);
        cairo.cairo_pattern_destroy(sheen);
    }
    cairo.cairo_restore(cr);
    strokeRounded(cr, x + 0.5, y + 0.5, w - 1.0, h - 1.0, r, if (pending) accent else if (failed) danger else glass_edge, 1.0);

    const go_d = @max(0.0, h - 8.0);
    const go_cx = x + w - 4.0 - go_d / 2.0;
    const has_text = view.dots > 0;

    if (!has_text) {
        var p = Text.init(cr, "Enter Password", @max(h * 0.55, 11.0), 500, 0, "");
        defer p.deinit();
        if (p.w > 0) {
            set(cr, .{ .r = 1, .g = 1, .b = 1, .a = 0.50 });
            p.show(cr, x + (w - @as(f64, @floatFromInt(p.w))) / 2.0, cy - @as(f64, @floatFromInt(p.h)) / 2.0);
        }
    } else {
        const dot_d = @max(h * 0.22, 6.0);
        const n = @min(view.dots, l.maxDots());
        const first = x + w / 2.0 - @as(f64, @floatFromInt(n - 1)) * dot_d;
        set(cr, .{ .r = 0.96, .g = 0.97, .b = 1.0, .a = 0.96 });
        for (0..n) |i| {
            circlePath(cr, first + @as(f64, @floatFromInt(i)) * dot_d * 2.0, cy, dot_d / 2.0);
            cairo.cairo_fill(cr);
        }
        if (view.caret_on and !pending) {
            const caret_h = @max(h * 0.56, 14.0);
            const caret_x = first + @as(f64, @floatFromInt(n - 1)) * dot_d * 2.0 + dot_d / 2.0 + 3.0;
            fillRounded(cr, caret_x, cy - caret_h / 2.0, 1.5, caret_h, 0.75, .{ .r = 1, .g = 1, .b = 1, .a = 0.85 });
        }
    }

    var go_fill = Rgba{ .r = 1, .g = 1, .b = 1, .a = 0.18 };
    var go_alpha: f64 = 1.0;
    if (pending) {
        go_fill = accent;
    } else if (failed) {
        go_fill = danger;
    } else if (!has_text) {
        go_alpha = 0.35;
    }
    circlePath(cr, go_cx, cy, go_d / 2.0);
    set(cr, .{ .r = 0, .g = 0, .b = 0, .a = 0.16 * go_alpha });
    cairo.cairo_fill(cr);
    circlePath(cr, go_cx, cy, go_d / 2.0);
    set(cr, .{ .r = go_fill.r, .g = go_fill.g, .b = go_fill.b, .a = @min(1.0, go_fill.a * go_alpha * 1.15) });
    cairo.cairo_fill(cr);
    circlePath(cr, go_cx, cy, go_d / 2.0);
    set(cr, .{ .r = 1, .g = 1, .b = 1, .a = 0.30 * go_alpha });
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);

    // The arrow, a 24-unit icon drawn at half the button.
    const scale = go_d * 0.5 / 24.0;
    const ox = go_cx - go_d * 0.25;
    const oy = cy - go_d * 0.25;
    set(cr, .{ .r = 1, .g = 1, .b = 1, .a = go_alpha });
    cairo.cairo_set_line_width(cr, @max(1.0, 2.2 * scale));
    cairo.cairo_set_line_cap(cr, cairo.LINE_CAP_ROUND);
    cairo.cairo_set_line_join(cr, cairo.LINE_JOIN_ROUND);
    cairo.cairo_move_to(cr, ox + 5.0 * scale, oy + 12.0 * scale);
    cairo.cairo_line_to(cr, ox + 19.0 * scale, oy + 12.0 * scale);
    cairo.cairo_move_to(cr, ox + 13.0 * scale, oy + 6.0 * scale);
    cairo.cairo_line_to(cr, ox + 19.0 * scale, oy + 12.0 * scale);
    cairo.cairo_line_to(cr, ox + 13.0 * scale, oy + 18.0 * scale);
    cairo.cairo_stroke(cr);
}

fn drawHint(cr: *Cr, l: *const logic.Layout, view: *const View) void {
    const col: Rgba = switch (view.hint) {
        .idle => .{ .r = 0.80, .g = 0.83, .b = 0.90, .a = 0.92 },
        .caps_lock => lighten(rgb(view.palette.accent, 1.0), 0.35),
        .checking => lighten(rgb(view.palette.accent, 1.0), 0.45),
        .wrong, .unavailable => lighten(rgb(view.palette.danger, 1.0), 0.35),
    };
    var t = Text.init(cr, view.hint.text(), l.hint_size, 500, 0, "");
    defer t.deinit();
    if (t.w == 0) return;
    showShadowed(cr, &t, l.w / 2.0 - @as(f64, @floatFromInt(t.w)) / 2.0, l.hint_top, @max(1.0, l.hint_size * 0.08), col);
}

/// Everything above the backdrop. `cr` targets a surface that already holds
/// paintBackdrop's result.
pub fn paintLock(cr: *Cr, w: i32, h: i32, view: *const View) void {
    if (w <= 0 or h <= 0) return;
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);

    var user_text = Text.init(cr, view.user, logic.Layout.userSize(fh), 600, 0, "");
    defer user_text.deinit();
    const l = logic.Layout.compute(fw, fh, @floatFromInt(user_text.h));

    drawDate(cr, fw / 2.0, l.date_top, l.date_size, view.date);
    drawClock(cr, fw / 2.0, l.clock_top, l.clock_size, view.clock);
    drawAvatar(cr, l.avatar_cx, l.avatar_cy, l.avatar_d, view.user, view.avatar);
    if (user_text.w > 0) {
        showShadowed(cr, &user_text, fw / 2.0 - @as(f64, @floatFromInt(user_text.w)) / 2.0, l.user_top, @max(1.0, l.user_size * 0.08), .{ .r = 1, .g = 1, .b = 1, .a = 0.95 });
    }
    drawField(cr, &l, view);
    drawHint(cr, &l, view);
}

/// Decodes an account photo into a premultiplied ARGB32 surface, at most
/// `max_px` on its long side (the avatar is small; a 4K photo need not stay
/// in memory). EXIF rotation is applied. Null on any failure.
pub fn loadAvatar(path: [:0]const u8, max_px: c_int) ?*cairo.Surface {
    var err: ?*anyopaque = null;
    const raw = c.pixbuf.gdk_pixbuf_new_from_file_at_scale(path.ptr, max_px, max_px, 1, &err);
    if (err) |e| c.pixbuf.g_error_free(e);
    const loaded = raw orelse return null;
    const pb = c.pixbuf.gdk_pixbuf_apply_embedded_orientation(loaded) orelse loaded;
    defer {
        if (pb != loaded) c.pixbuf.g_object_unref(pb);
        c.pixbuf.g_object_unref(loaded);
    }
    const w = c.pixbuf.gdk_pixbuf_get_width(pb);
    const h = c.pixbuf.gdk_pixbuf_get_height(pb);
    const ch = c.pixbuf.gdk_pixbuf_get_n_channels(pb);
    if (w <= 0 or h <= 0 or (ch != 3 and ch != 4)) return null;
    const surf = cairo.cairo_image_surface_create(cairo.FORMAT_ARGB32, w, h) orelse return null;
    if (cairo.cairo_surface_status(surf) != cairo.STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    const dst = cairo.cairo_image_surface_get_data(surf) orelse {
        cairo.cairo_surface_destroy(surf);
        return null;
    };
    cairo.cairo_surface_flush(surf);
    copyPixbuf(pb, dst, @intCast(cairo.cairo_image_surface_get_stride(surf)));
    cairo.cairo_surface_mark_dirty(surf);
    return surf;
}

/// Pixbuf RGB(A) rows into premultiplied little-endian ARGB32 rows.
pub fn copyPixbuf(pb: *c.pixbuf.Pixbuf, dst: [*]u8, dst_stride: usize) void {
    const w: usize = @intCast(c.pixbuf.gdk_pixbuf_get_width(pb));
    const h: usize = @intCast(c.pixbuf.gdk_pixbuf_get_height(pb));
    const ch: usize = @intCast(c.pixbuf.gdk_pixbuf_get_n_channels(pb));
    const has_alpha = c.pixbuf.gdk_pixbuf_get_has_alpha(pb) != 0 and ch == 4;
    const rs: usize = @intCast(c.pixbuf.gdk_pixbuf_get_rowstride(pb));
    const src = c.pixbuf.gdk_pixbuf_get_pixels(pb);
    for (0..h) |y| {
        for (0..w) |x| {
            const s = y * rs + x * ch;
            const a: u32 = if (has_alpha) src[s + 3] else 255;
            const off = y * dst_stride + x * 4;
            dst[off] = @intCast((@as(u32, src[s + 2]) * a + 127) / 255);
            dst[off + 1] = @intCast((@as(u32, src[s + 1]) * a + 127) / 255);
            dst[off + 2] = @intCast((@as(u32, src[s]) * a + 127) / 255);
            dst[off + 3] = @intCast(a);
        }
    }
}
