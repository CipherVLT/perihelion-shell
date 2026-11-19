//! Screen-brightness reader for the bar's brightness OSD. No drawing, no
//! keyboard: the compositor's keybinds run `brightnessctl set +5%`
//! themselves, and the bar only notices the backlight value move.
//!
//! Device: the backlight class device brightnessctl would act on, preferring
//! the kernel's own priority order by `type`: firmware (ACPI) over platform
//! over raw (the same choice GNOME and systemd make); ties go to the larger
//! max_brightness, then the name. No device at all (desktops, VMs) leaves
//! the reader inert: init finds nothing, pollFd() is -1 and sample() never
//! reads anything.
//!
//! Cost: `actual_brightness` is opened once and kept open. The kernel calls
//! sysfs_notify on it whenever the brightness changes, so the bar polls the
//! fd for POLLPRI and reads only then (plus a cheap fallback re-read once a
//! second, for drivers that don't notify). The first read only records the
//! value; later reads report a change.
//!
//! Tests: `zig build test-backlight` (fake class trees under /tmp, picked
//! through `PERIHELIONBAR_BACKLIGHT_DIR`, which exists for tests only).

const std = @import("std");
const posix = std.posix;

pub const DEFAULT_DIR = "/sys/class/backlight";
/// Test-only override of DEFAULT_DIR.
pub const ENV_DIR = "PERIHELIONBAR_BACKLIGHT_DIR";

const Dirent = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [256]u8,
};

const libc = struct {
    const DIR = opaque {};
    extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
    extern "c" fn readdir(dir: *DIR) ?*Dirent;
    extern "c" fn closedir(dir: *DIR) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn pread(fd: c_int, buf: [*]u8, n: usize, off: i64) isize;
};

/// The class directory to scan: the test override, else sysfs.
pub fn classDir() []const u8 {
    const v = std.mem.span(libc.getenv(ENV_DIR) orelse return DEFAULT_DIR);
    return if (v.len > 0) v else DEFAULT_DIR;
}

/// Priority of a backlight `type`: firmware > platform > raw > unknown.
pub fn typeRank(t: []const u8) u8 {
    const s = std.mem.trim(u8, t, " \t\r\n");
    if (std.mem.eql(u8, s, "firmware")) return 3;
    if (std.mem.eql(u8, s, "platform")) return 2;
    if (std.mem.eql(u8, s, "raw")) return 1;
    return 0;
}

/// Brightness as a rounded percentage of max (0 max reads as 0).
pub fn percent(cur: u64, max: u64) u8 {
    if (max == 0) return 0;
    const c = @min(cur, max);
    return @intCast((c * 100 + max / 2) / max);
}

fn readSmall(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const raw = posix.system.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw < 0) return null;
    const fd: posix.fd_t = @intCast(raw);
    defer _ = posix.system.close(fd);
    const n = posix.read(fd, buf) catch return null;
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

fn readU64(path: [:0]const u8) ?u64 {
    var b: [32]u8 = undefined;
    const t = readSmall(path, &b) orelse return null;
    return std.fmt.parseInt(u64, t, 10) catch null;
}

pub const Backlight = struct {
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    max: u64 = 0,
    /// actual_brightness (or brightness) kept open for POLLPRI + pread.
    fd: posix.fd_t = -1,
    /// Last value read; null until the first read.
    last: ?u64 = null,

    pub fn name(self: *const Backlight) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn present(self: *const Backlight) bool {
        return self.fd >= 0;
    }

    /// The fd to poll for POLLPRI, or -1 without a device.
    pub fn pollFd(self: *const Backlight) posix.fd_t {
        return self.fd;
    }

    /// Picks the device under `dir` and opens its value file. Nothing found
    /// (no directory, no usable device) gives an inert reader.
    pub fn init(dir: []const u8) Backlight {
        var self = Backlight{};
        var dz: [256]u8 = undefined;
        const dir_z = std.fmt.bufPrintSentinel(&dz, "{s}", .{dir}, 0) catch return self;
        const d = libc.opendir(dir_z.ptr) orelse return self;
        defer _ = libc.closedir(d);
        var best_rank: i16 = -1;
        var best_max: u64 = 0;
        while (libc.readdir(d)) |e| {
            const n = std.mem.sliceTo(&e.d_name, 0);
            if (n.len == 0 or n[0] == '.' or n.len > self.name_buf.len) continue;
            var pb: [400]u8 = undefined;
            const mp = std.fmt.bufPrintSentinel(&pb, "{s}/{s}/max_brightness", .{ dir, n }, 0) catch continue;
            const max = readU64(mp) orelse continue;
            if (max == 0) continue;
            var tb: [32]u8 = undefined;
            const tp = std.fmt.bufPrintSentinel(&pb, "{s}/{s}/type", .{ dir, n }, 0) catch continue;
            const rank: i16 = typeRank(readSmall(tp, &tb) orelse "");
            const better = rank > best_rank or
                (rank == best_rank and max > best_max) or
                (rank == best_rank and max == best_max and std.mem.order(u8, n, self.name()) == .lt);
            if (!better) continue;
            best_rank = rank;
            best_max = max;
            @memcpy(self.name_buf[0..n.len], n);
            self.name_len = n.len;
        }
        if (self.name_len == 0) return self;
        self.max = best_max;
        for ([_][]const u8{ "actual_brightness", "brightness" }) |f| {
            var pb: [400]u8 = undefined;
            const p = std.fmt.bufPrintSentinel(&pb, "{s}/{s}/{s}", .{ dir, self.name(), f }, 0) catch continue;
            const raw = posix.system.open(p.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(posix.mode_t, 0));
            if (raw >= 0) {
                self.fd = @intCast(raw);
                break;
            }
        }
        return self;
    }

    pub fn deinit(self: *Backlight) void {
        if (self.fd >= 0) _ = posix.system.close(self.fd);
        self.fd = -1;
    }

    /// Reads the value. Returns the new percentage when it moved since the
    /// previous read; the first read, an unchanged value, or no device
    /// return null.
    pub fn sample(self: *Backlight) ?u8 {
        if (self.fd < 0) return null;
        var b: [32]u8 = undefined;
        const n = libc.pread(self.fd, &b, b.len, 0);
        if (n <= 0) return null;
        const v = std.fmt.parseInt(u64, std.mem.trim(u8, b[0..@intCast(n)], " \t\r\n"), 10) catch return null;
        const prev = self.last;
        self.last = v;
        if (prev == null or prev.? == v) return null;
        return percent(v, self.max);
    }

    /// Current percentage (after at least one read).
    pub fn pct(self: *const Backlight) u8 {
        return percent(self.last orelse 0, self.max);
    }
};

// --- tests ------------------------------------------------------------------

fn mkdirP(path: []const u8) void {
    var buf: [300]u8 = undefined;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        _ = posix.system.mkdir(buf[0..i :0].ptr, 0o755);
    }
}

fn writeFile(dir: []const u8, rel: []const u8, body: []const u8) void {
    var pb: [300]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, rel }) catch return;
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |s| mkdirP(p[0..s]);
    var zb: [300]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{p}, 0) catch return;
    const raw = posix.system.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(posix.mode_t, 0o644));
    if (raw < 0) return;
    _ = std.c.write(@intCast(raw), body.ptr, body.len);
    _ = posix.system.close(@intCast(raw));
}

test "percent math" {
    try std.testing.expectEqual(@as(u8, 0), percent(0, 255));
    try std.testing.expectEqual(@as(u8, 100), percent(255, 255));
    try std.testing.expectEqual(@as(u8, 50), percent(128, 255));
    try std.testing.expectEqual(@as(u8, 5), percent(4800, 96000));
    try std.testing.expectEqual(@as(u8, 100), percent(999, 10)); // clamped
    try std.testing.expectEqual(@as(u8, 0), percent(5, 0));
    try std.testing.expectEqual(@as(u8, 3), typeRank("firmware\n"));
    try std.testing.expectEqual(@as(u8, 1), typeRank("raw"));
    try std.testing.expectEqual(@as(u8, 0), typeRank("odd"));
}

test "device choice: firmware over raw, then the larger range" {
    var rb: [64]u8 = undefined;
    const dir = std.fmt.bufPrint(&rb, "/tmp/perihelion-bl-pick-{d}", .{std.c.getpid()}) catch unreachable;
    writeFile(dir, "intel_backlight/type", "raw\n");
    writeFile(dir, "intel_backlight/max_brightness", "96000\n");
    writeFile(dir, "intel_backlight/actual_brightness", "48000\n");
    writeFile(dir, "acpi_video0/type", "firmware\n");
    writeFile(dir, "acpi_video0/max_brightness", "100\n");
    writeFile(dir, "acpi_video0/actual_brightness", "40\n");
    writeFile(dir, "acpi_video1/type", "firmware\n");
    writeFile(dir, "acpi_video1/max_brightness", "15\n");
    writeFile(dir, "broken/type", "firmware\n"); // no max_brightness: skipped
    var b = Backlight.init(dir);
    defer b.deinit();
    try std.testing.expectEqualStrings("acpi_video0", b.name());
    try std.testing.expectEqual(@as(u64, 100), b.max);
    try std.testing.expect(b.present());
}

test "first read is silent, a change reports, no change stays quiet" {
    var rb: [64]u8 = undefined;
    const dir = std.fmt.bufPrint(&rb, "/tmp/perihelion-bl-change-{d}", .{std.c.getpid()}) catch unreachable;
    writeFile(dir, "amdgpu_bl1/type", "raw\n");
    writeFile(dir, "amdgpu_bl1/max_brightness", "255\n");
    writeFile(dir, "amdgpu_bl1/brightness", "128\n"); // no actual_brightness: falls back
    var b = Backlight.init(dir);
    defer b.deinit();
    try std.testing.expect(b.sample() == null); // first read only records
    try std.testing.expectEqual(@as(u8, 50), b.pct());
    try std.testing.expect(b.sample() == null); // unchanged
    writeFile(dir, "amdgpu_bl1/brightness", "140\n");
    try std.testing.expectEqual(@as(?u8, 55), b.sample());
    try std.testing.expect(b.sample() == null);
}

test "missing directory or no device is inert" {
    var b = Backlight.init("/tmp/perihelion-bl-does-not-exist");
    try std.testing.expect(!b.present());
    try std.testing.expectEqual(@as(posix.fd_t, -1), b.pollFd());
    try std.testing.expect(b.sample() == null);
    var rb: [64]u8 = undefined;
    const dir = std.fmt.bufPrint(&rb, "/tmp/perihelion-bl-empty-{d}", .{std.c.getpid()}) catch unreachable;
    mkdirP(dir);
    var e = Backlight.init(dir);
    try std.testing.expect(!e.present());
    try std.testing.expect(e.sample() == null);
}
