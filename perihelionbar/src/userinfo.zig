//! User/uptime service for the desktop User card (perihelionbar-shell
//! widgets.zig UserWidget). Same shape as procs.zig / netrate.zig: no
//! drawing, no fds kept open, the host calls tick().
//!
//! Who: the login name and display name come from the passwd entry of the
//! process's uid (the display name is the first comma field of GECOS; an
//! empty one falls back to the login name). The host name comes from
//! /proc/sys/kernel/hostname. Both are read once, at startup.
//! How long: /proc/uptime, read every 30 s; tick() reports a change only
//! when the shown minute moves, so the card repaints once a minute.
//!
//! Tests: `zig build test-userinfo` in perihelionbar/ (fake passwd and
//! uptime text, fake files under /tmp).

const std = @import("std");
const posix = std.posix;

const libc = struct {
    extern "c" fn getuid() u32;
};

pub const CHECK_MS: i64 = 30_000;

pub const Config = struct {
    passwd_path: [:0]const u8 = "/etc/passwd",
    hostname_path: [:0]const u8 = "/proc/sys/kernel/hostname",
    uptime_path: [:0]const u8 = "/proc/uptime",
    /// null = the process's own uid.
    uid: ?u32 = null,
};

fn Text(comptime N: usize) type {
    return struct {
        buf: [N]u8 = undefined,
        len: usize = 0,
        const Self = @This();
        fn set(self: *Self, s: []const u8) void {
            var n: usize = @min(s.len, N);
            // Never cut a UTF-8 sequence in half.
            while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }
        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

/// Finds the passwd line for `uid` and returns its login name and display
/// name (GECOS up to the first comma, or the login name when empty).
pub fn parsePasswd(text: []const u8, uid: u32) ?struct { login: []const u8, display: []const u8 } {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, ':');
        const login = f.next() orelse continue;
        _ = f.next() orelse continue; // password
        const uid_s = f.next() orelse continue;
        _ = f.next() orelse continue; // gid
        const gecos = f.next() orelse "";
        const u = std.fmt.parseInt(u32, uid_s, 10) catch continue;
        if (u != uid or login.len == 0) continue;
        const comma = std.mem.indexOfScalar(u8, gecos, ',') orelse gecos.len;
        const name = std.mem.trim(u8, gecos[0..comma], " ");
        return .{ .login = login, .display = if (name.len > 0) name else login };
    }
    return null;
}

/// Whole seconds from /proc/uptime ("12345.67 98765.43").
pub fn parseUptime(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    const end = std.mem.indexOfAny(u8, t, ". ") orelse t.len;
    if (end == 0) return null;
    return std.fmt.parseInt(u64, t[0..end], 10) catch null;
}

fn plural(n: u64) []const u8 {
    return if (n == 1) "" else "s";
}

/// "up 2 days, 3 hours, 5 minutes" (zero parts left out); under a minute
/// "up 42 seconds".
pub fn fmtLong(buf: []u8, secs: u64) []const u8 {
    const d = secs / 86400;
    const h = (secs % 86400) / 3600;
    const m = (secs % 3600) / 60;
    if (d == 0 and h == 0 and m == 0) return std.fmt.bufPrint(buf, "up {d} second{s}", .{ secs, plural(secs) }) catch "";
    var n: usize = 0;
    const head = "up ";
    if (buf.len < head.len) return "";
    @memcpy(buf[0..head.len], head);
    n = head.len;
    const parts = [_]struct { v: u64, unit: []const u8 }{
        .{ .v = d, .unit = "day" },
        .{ .v = h, .unit = "hour" },
        .{ .v = m, .unit = "minute" },
    };
    var first = true;
    for (parts) |p| {
        if (p.v == 0) continue;
        const piece = std.fmt.bufPrint(buf[n..], "{s}{d} {s}{s}", .{ if (first) "" else ", ", p.v, p.unit, plural(p.v) }) catch return buf[0..n];
        n += piece.len;
        first = false;
    }
    return buf[0..n];
}

/// "up 2d 3h 5m" (zero parts left out); under a minute "up 42s".
pub fn fmtShort(buf: []u8, secs: u64) []const u8 {
    const d = secs / 86400;
    const h = (secs % 86400) / 3600;
    const m = (secs % 3600) / 60;
    if (d == 0 and h == 0 and m == 0) return std.fmt.bufPrint(buf, "up {d}s", .{secs}) catch "";
    var n: usize = 0;
    const head = "up";
    if (buf.len < head.len) return "";
    @memcpy(buf[0..head.len], head);
    n = head.len;
    const parts = [_]struct { v: u64, unit: u8 }{ .{ .v = d, .unit = 'd' }, .{ .v = h, .unit = 'h' }, .{ .v = m, .unit = 'm' } };
    for (parts) |p| {
        if (p.v == 0) continue;
        const piece = std.fmt.bufPrint(buf[n..], " {d}{c}", .{ p.v, p.unit }) catch return buf[0..n];
        n += piece.len;
    }
    return buf[0..n];
}

pub const Service = struct {
    cfg: Config = .{},
    login: Text(32) = .{},
    display: Text(64) = .{},
    host: Text(64) = .{},
    uptime_s: u64 = 0,
    have_uptime: bool = false,
    loaded: bool = false,
    next_ms: i64 = 0,

    pub fn init(cfg: Config) Service {
        return .{ .cfg = cfg };
    }

    /// Reads who/where once, then the uptime when due. True when the shown
    /// text changed (first load, or the uptime's minute moved).
    pub fn tick(self: *Service, now_ms: i64) bool {
        var changed = false;
        if (!self.loaded) {
            self.loadIdentity();
            changed = true;
        }
        if (now_ms < self.next_ms) return changed;
        self.next_ms = now_ms + CHECK_MS;
        var buf: [128]u8 = undefined;
        const n = readAll(self.cfg.uptime_path, &buf);
        const secs = parseUptime(buf[0..n]) orelse return changed;
        const was_min = self.uptime_s / 60;
        const had = self.have_uptime;
        self.uptime_s = secs;
        self.have_uptime = true;
        // Under a minute the long form counts seconds, so repaint each check.
        return changed or !had or secs / 60 != was_min or secs < 60;
    }

    fn loadIdentity(self: *Service) void {
        self.loaded = true;
        // Big enough for a typical local passwd; a longer one is read in
        // part, and a missing entry falls back to "user".
        var pw: [16384]u8 = undefined;
        const n = readAll(self.cfg.passwd_path, &pw);
        const uid = self.cfg.uid orelse libc.getuid();
        if (parsePasswd(pw[0..n], uid)) |p| {
            self.login.set(p.login);
            self.display.set(p.display);
        } else {
            self.login.set("user");
            self.display.set("user");
        }
        var hb: [128]u8 = undefined;
        const hn = readAll(self.cfg.hostname_path, &hb);
        const h = std.mem.trim(u8, hb[0..hn], " \t\r\n");
        self.host.set(if (h.len > 0) h else "localhost");
    }
};

fn readAll(path: [:0]const u8, buf: []u8) usize {
    const raw_fd = posix.system.open(path, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw_fd < 0) return 0;
    const fd: posix.fd_t = @intCast(raw_fd);
    defer _ = posix.system.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

// --- tests ------------------------------------------------------------------

const PASSWD =
    \\root:x:0:0:root:/root:/bin/bash
    \\# a comment
    \\alex:x:1000:1000:Alex Moreau,,,:/home/alex:/usr/bin/fish
    \\sam:x:1001:1001::/home/sam:/bin/bash
    \\broken-line
;

test "parsePasswd: display name from GECOS, login fallback, missing uid" {
    const a = parsePasswd(PASSWD, 1000).?;
    try std.testing.expectEqualStrings("alex", a.login);
    try std.testing.expectEqualStrings("Alex Moreau", a.display);
    const s = parsePasswd(PASSWD, 1001).?;
    try std.testing.expectEqualStrings("sam", s.display);
    try std.testing.expect(parsePasswd(PASSWD, 4242) == null);
}

test "parseUptime" {
    try std.testing.expectEqual(@as(?u64, 12345), parseUptime("12345.67 98765.43\n"));
    try std.testing.expectEqual(@as(?u64, 7), parseUptime("7 1"));
    try std.testing.expect(parseUptime("") == null);
    try std.testing.expect(parseUptime("abc") == null);
}

test "fmtLong / fmtShort" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("up 42 seconds", fmtLong(&b, 42));
    try std.testing.expectEqualStrings("up 1 minute", fmtLong(&b, 60));
    try std.testing.expectEqualStrings("up 1 hour, 23 minutes", fmtLong(&b, 3600 + 23 * 60 + 5));
    try std.testing.expectEqualStrings("up 2 days, 5 minutes", fmtLong(&b, 2 * 86400 + 300));
    try std.testing.expectEqualStrings("up 42s", fmtShort(&b, 42));
    try std.testing.expectEqualStrings("up 1h 23m", fmtShort(&b, 3600 + 23 * 60));
    try std.testing.expectEqualStrings("up 3d 4h", fmtShort(&b, 3 * 86400 + 4 * 3600 + 30));
}

fn writeFile(path: [:0]const u8, body: []const u8) !void {
    const fd = posix.system.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(posix.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = posix.system.close(@intCast(fd));
    _ = posix.system.write(@intCast(fd), body.ptr, body.len);
}

test "Service.tick: identity once, repaint only when the minute moves" {
    const pw = "/tmp/perihelion-userinfo-test-passwd";
    const hn = "/tmp/perihelion-userinfo-test-hostname";
    const up = "/tmp/perihelion-userinfo-test-uptime";
    try writeFile(pw, PASSWD);
    try writeFile(hn, "deskbox\n");
    try writeFile(up, "3600.10 1.0\n");
    defer _ = posix.system.unlink(pw);
    defer _ = posix.system.unlink(hn);
    defer _ = posix.system.unlink(up);

    var s = Service.init(.{ .passwd_path = pw, .hostname_path = hn, .uptime_path = up, .uid = 1000 });
    try std.testing.expect(s.tick(0));
    try std.testing.expectEqualStrings("Alex Moreau", s.display.slice());
    try std.testing.expectEqualStrings("alex", s.login.slice());
    try std.testing.expectEqualStrings("deskbox", s.host.slice());
    try std.testing.expectEqual(@as(u64, 3600), s.uptime_s);

    try std.testing.expect(!s.tick(1000)); // not due
    try writeFile(up, "3630.00 1.0\n");
    try std.testing.expect(!s.tick(CHECK_MS)); // same minute
    try writeFile(up, "3661.00 1.0\n");
    try std.testing.expect(s.tick(2 * CHECK_MS)); // minute moved
}
