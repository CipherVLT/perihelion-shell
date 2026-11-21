//! lock-preview: draws perihelion-lockscreen's screen to PNG files without
//! locking anything, one picture per state (idle, typing, checking, wrong
//! password, caps lock, 24-hour, no wallpaper, no avatar). For reviewing the
//! design and for CI's picture artifact; never installed.
//!
//!   lock-preview OUT_DIR [WALLPAPER] [AVATAR] [WIDTH HEIGHT]

const std = @import("std");
const c = @import("c.zig");
const logic = @import("logic.zig");
const paint = @import("paint.zig");
const image = @import("image.zig");
const cairo = c.cairo;

fn render(gpa: std.mem.Allocator, dir: []const u8, name: []const u8, w: u32, h: u32, wall: ?*const image.Image, pal: logic.Palette, v: paint.View) !void {
    const surf = cairo.cairo_image_surface_create(cairo.FORMAT_ARGB32, @intCast(w), @intCast(h)) orelse return error.Cairo;
    defer cairo.cairo_surface_destroy(surf);
    const data = cairo.cairo_image_surface_get_data(surf) orelse return error.Cairo;
    const px: [*]u32 = @ptrCast(@alignCast(data));
    if (wall) |img| image.blitCover(px[0 .. w * h], w, h, img);
    cairo.cairo_surface_mark_dirty(surf);
    const cr = cairo.cairo_create(surf) orelse return error.Cairo;
    defer cairo.cairo_destroy(cr);
    paint.paintBackdrop(cr, @intCast(h), wall != null, pal);
    paint.paintLock(cr, @intCast(w), @intCast(h), &v);
    cairo.cairo_surface_flush(surf);
    var pbuf: [700]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&pbuf, "{s}/lock-{s}.png", .{ dir, name }, 0);
    if (cairo.cairo_surface_write_to_png(surf, path.ptr) != cairo.STATUS_SUCCESS) return error.WritePng;
    _ = gpa;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.c_allocator;
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    const dir = it.next() orelse return error.Usage;
    const wall_path = it.next() orelse "";
    const avatar_path = it.next() orelse "";
    const w: u32 = if (it.next()) |a| try std.fmt.parseInt(u32, a, 10) else 1920;
    const h: u32 = if (it.next()) |a| try std.fmt.parseInt(u32, a, 10) else 1080;

    var zbuf: [700]u8 = undefined;
    var wall: ?image.Image = null;
    if (wall_path.len > 0) {
        const z = try std.fmt.bufPrintSentinel(&zbuf, "{s}", .{wall_path}, 0);
        wall = image.decodeWallpaper(gpa, z, w, h);
    }
    var avatar: ?*cairo.Surface = null;
    if (avatar_path.len > 0) {
        const z = try std.fmt.bufPrintSentinel(&zbuf, "{s}", .{avatar_path}, 0);
        avatar = paint.loadAvatar(z, 512);
    }
    const pal = logic.Palette{};
    var cb: [16]u8 = undefined;
    var db: [48]u8 = undefined;
    const date = logic.formatDate(&db, 2026, 11, 9);
    const base = paint.View{
        .clock = logic.formatClock(&cb, 14, 5, false),
        .date = date,
        .user = "perihelion",
        .avatar = avatar,
        .palette = pal,
    };
    const wp: ?*const image.Image = if (wall) |*img| img else null;
    try render(gpa, dir, "idle", w, h, wp, pal, base);
    var v = base;
    v.dots = 7;
    v.caret_on = true;
    try render(gpa, dir, "typing", w, h, wp, pal, v);
    v.hint = .checking;
    try render(gpa, dir, "checking", w, h, wp, pal, v);
    v = base;
    v.hint = .wrong;
    try render(gpa, dir, "wrong", w, h, wp, pal, v);
    v = base;
    v.hint = .caps_lock;
    v.dots = 3;
    try render(gpa, dir, "caps", w, h, wp, pal, v);
    var cb24: [16]u8 = undefined;
    v = base;
    v.clock = logic.formatClock(&cb24, 14, 5, true);
    try render(gpa, dir, "24h", w, h, wp, pal, v);
    v = base;
    v.avatar = null;
    try render(gpa, dir, "initial", w, h, wp, pal, v);
    try render(gpa, dir, "no-wallpaper", w, h, null, pal, v);
}
