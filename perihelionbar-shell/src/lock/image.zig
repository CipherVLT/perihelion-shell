//! The wallpaper for perihelion-lockscreen: decoded with gdk-pixbuf only as
//! large as the biggest output needs, then scaled to cover each output the
//! way swaybg's fill mode does, so the lock screen lines up with the desktop.

const std = @import("std");
const c = @import("c.zig");
const paint = @import("paint.zig");

// --- images -------------------------------------------------------------------

/// The decoded wallpaper, premultiplied ARGB32, sized to cover the largest
/// output.
pub const Image = struct {
    pixels: []u32,
    w: usize,
    h: usize,
};

pub fn decodeWallpaper(gpa: std.mem.Allocator, path: [:0]const u8, cover_w: u32, cover_h: u32) ?Image {
    var iw: c_int = 0;
    var ih: c_int = 0;
    if (c.pixbuf.gdk_pixbuf_get_file_info(path.ptr, &iw, &ih) == null or iw <= 0 or ih <= 0) return null;
    const fw: f64 = @floatFromInt(iw);
    const fh: f64 = @floatFromInt(ih);
    // Decode only as large as the biggest output needs (a 6K photo on a
    // 1080p screen would otherwise sit in memory at full size).
    const s = @min(1.0, @max(@as(f64, @floatFromInt(cover_w)) / fw, @as(f64, @floatFromInt(cover_h)) / fh));
    const tw: c_int = @max(1, @as(c_int, @intFromFloat(@ceil(fw * s))));
    const th: c_int = @max(1, @as(c_int, @intFromFloat(@ceil(fh * s))));
    var err: ?*anyopaque = null;
    const raw = c.pixbuf.gdk_pixbuf_new_from_file_at_scale(path.ptr, tw, th, 1, &err);
    if (err) |e| c.pixbuf.g_error_free(e);
    const pb = raw orelse return null;
    defer c.pixbuf.g_object_unref(pb);
    const w: usize = @intCast(c.pixbuf.gdk_pixbuf_get_width(pb));
    const h: usize = @intCast(c.pixbuf.gdk_pixbuf_get_height(pb));
    const ch = c.pixbuf.gdk_pixbuf_get_n_channels(pb);
    if (w == 0 or h == 0 or (ch != 3 and ch != 4)) return null;
    const pixels = gpa.alloc(u32, w * h) catch return null;
    paint.copyPixbuf(pb, @ptrCast(pixels.ptr), w * 4);
    return .{ .pixels = pixels, .w = w, .h = h };
}

/// Scale-to-cover, centred (swaybg's fill mode, so the lock screen lines up
/// with the desktop), bilinear.
pub fn blitCover(dst: []u32, dw: usize, dh: usize, img: *const Image) void {
    const sx = @as(f64, @floatFromInt(img.w)) / @as(f64, @floatFromInt(dw));
    const sy = @as(f64, @floatFromInt(img.h)) / @as(f64, @floatFromInt(dh));
    const s = @min(sx, sy);
    const ox = (@as(f64, @floatFromInt(img.w)) - @as(f64, @floatFromInt(dw)) * s) / 2.0;
    const oy = (@as(f64, @floatFromInt(img.h)) - @as(f64, @floatFromInt(dh)) * s) / 2.0;
    const maxx = @as(f64, @floatFromInt(img.w - 1));
    const maxy = @as(f64, @floatFromInt(img.h - 1));
    for (0..dh) |y| {
        const fy = std.math.clamp(oy + (@as(f64, @floatFromInt(y)) + 0.5) * s - 0.5, 0, maxy);
        const y0: usize = @intFromFloat(fy);
        const y1 = @min(y0 + 1, img.h - 1);
        const ty = fy - @as(f64, @floatFromInt(y0));
        for (0..dw) |x| {
            const fx = std.math.clamp(ox + (@as(f64, @floatFromInt(x)) + 0.5) * s - 0.5, 0, maxx);
            const x0: usize = @intFromFloat(fx);
            const x1 = @min(x0 + 1, img.w - 1);
            const tx = fx - @as(f64, @floatFromInt(x0));
            const p00 = img.pixels[y0 * img.w + x0];
            const p10 = img.pixels[y0 * img.w + x1];
            const p01 = img.pixels[y1 * img.w + x0];
            const p11 = img.pixels[y1 * img.w + x1];
            var out: u32 = 0;
            inline for (.{ 0, 8, 16, 24 }) |shift| {
                const sh: u5 = shift;
                const a = @as(f64, @floatFromInt((p00 >> sh) & 0xff));
                const b = @as(f64, @floatFromInt((p10 >> sh) & 0xff));
                const cc = @as(f64, @floatFromInt((p01 >> sh) & 0xff));
                const d = @as(f64, @floatFromInt((p11 >> sh) & 0xff));
                const top = a + (b - a) * tx;
                const bot = cc + (d - cc) * tx;
                const v: u32 = @intFromFloat(@round(top + (bot - top) * ty));
                out |= @as(u32, @min(v, 255)) << sh;
            }
            dst[y * dw + x] = out;
        }
    }
}
