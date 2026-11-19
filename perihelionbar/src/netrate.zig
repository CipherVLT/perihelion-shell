//! Network-rate service for the desktop Network card (perihelionbar-shell
//! widgets.zig NetworkWidget). Same shape as procs.zig / temps.zig: no
//! drawing, no fds kept open, the host calls tick().
//!
//! One sample = one read of /proc/net/dev (a few hundred bytes of procfs,
//! never blocks). Download and upload are summed over the physical
//! interfaces: names starting with eth, en, wl or ww (wired, Wi-Fi, mobile
//! broadband). Loopback, bridges, VPN tunnels and container veths are left
//! out, so traffic isn't counted twice. Rates are bytes per second over
//! the real time between two samples, and the last HISTORY samples feed
//! the card's graph.
//!
//! tick() reports whether anything shown changed, so an idle link with
//! an all-zero history doesn't repaint the card.
//!
//! Tests: `zig build test-netrate` in perihelionbar/ (fake /proc/net/dev
//! text and a fake file under /tmp).

const std = @import("std");
const posix = std.posix;

/// Samples kept for the graph (60 at the default 2 s = the last 2 minutes).
pub const HISTORY: usize = 60;
pub const DEFAULT_INTERVAL_MS: i64 = 2000;
pub const MIN_INTERVAL_S: u32 = 1;
pub const MAX_INTERVAL_S: u32 = 10;

pub const Totals = struct {
    rx: u64 = 0,
    tx: u64 = 0,
    /// Physical interfaces counted.
    ifaces: u32 = 0,
};

/// True for interface names the card counts (see the file comment).
pub fn isPhysical(name: []const u8) bool {
    const prefixes = [_][]const u8{ "eth", "en", "wl", "ww" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, name, p)) return true;
    }
    return false;
}

/// Sums received/transmitted bytes of the physical interfaces in a
/// /proc/net/dev dump. Lines look like
///   "  wlan0: 123456 789 0 0 0 0 0 0 654321 456 0 0 0 0 0 0"
/// (receive bytes are field 1, transmit bytes field 9). The two header
/// lines have no ':' and are skipped, as are malformed lines.
pub fn parseProcNetDev(text: []const u8) Totals {
    var t: Totals = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!isPhysical(name)) continue;
        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        var rx: ?u64 = null;
        var tx: ?u64 = null;
        var i: usize = 0;
        while (fields.next()) |f| : (i += 1) {
            if (i == 0) rx = std.fmt.parseInt(u64, f, 10) catch null;
            if (i == 8) {
                tx = std.fmt.parseInt(u64, f, 10) catch null;
                break;
            }
        }
        if (rx == null or tx == null) continue;
        t.rx +%= rx.?;
        t.tx +%= tx.?;
        t.ifaces += 1;
    }
    return t;
}

/// "0 B/s", "512 B/s", "12.3 KB/s", "4.5 MB/s", "1.2 GB/s" (1024 steps).
pub fn fmtRate(buf: []u8, bytes_per_s: u64) []const u8 {
    const b: f64 = @floatFromInt(bytes_per_s);
    if (bytes_per_s < 1024) return std.fmt.bufPrint(buf, "{d} B/s", .{bytes_per_s}) catch "";
    if (b < 1024.0 * 1024.0) return std.fmt.bufPrint(buf, "{d:.1} KB/s", .{b / 1024.0}) catch "";
    if (b < 1024.0 * 1024.0 * 1024.0) return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{b / (1024.0 * 1024.0)}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} GB/s", .{b / (1024.0 * 1024.0 * 1024.0)}) catch "";
}

pub const Config = struct {
    interval_ms: i64 = DEFAULT_INTERVAL_MS,
    /// Where the counters come from (tests point this at a fake file).
    path: [:0]const u8 = "/proc/net/dev",
};

pub const Service = struct {
    cfg: Config = .{},
    prev: Totals = .{},
    prev_ms: i64 = 0,
    have_prev: bool = false,
    next_ms: i64 = 0,
    /// Current rates, bytes per second.
    rx_rate: u64 = 0,
    tx_rate: u64 = 0,
    ifaces: u32 = 0,
    /// Ring of past rates; `hist_len` valid entries ending at `hist_head`.
    rx_hist: [HISTORY]u64 = @as([HISTORY]u64, @splat(0)),
    tx_hist: [HISTORY]u64 = @as([HISTORY]u64, @splat(0)),
    hist_head: usize = 0,
    hist_len: usize = 0,

    pub fn init(cfg: Config) Service {
        return .{ .cfg = cfg };
    }

    /// True once two samples gave a first rate.
    pub fn ready(self: *const Service) bool {
        return self.hist_len > 0;
    }

    /// Reads the counters when a sample is due. True when the card should
    /// repaint.
    pub fn tick(self: *Service, now_ms: i64) bool {
        if (now_ms < self.next_ms) return false;
        self.next_ms = now_ms + self.cfg.interval_ms;
        var buf: [4096]u8 = undefined;
        const n = readAll(self.cfg.path, &buf);
        return self.sample(buf[0..n], now_ms);
    }

    /// Feeds one /proc/net/dev dump taken at `now_ms`. True when the shown
    /// values changed. A counter that went backwards (interface reset,
    /// device unplugged) restarts the baseline instead of reading as a
    /// huge spike.
    pub fn sample(self: *Service, text: []const u8, now_ms: i64) bool {
        const t = parseProcNetDev(text);
        const ifaces_changed = t.ifaces != self.ifaces;
        self.ifaces = t.ifaces;
        defer {
            self.prev = t;
            self.prev_ms = now_ms;
            self.have_prev = true;
        }
        if (!self.have_prev or now_ms <= self.prev_ms or t.rx < self.prev.rx or t.tx < self.prev.tx or ifaces_changed) {
            return ifaces_changed;
        }
        const dt: u64 = @intCast(now_ms - self.prev_ms);
        const rx = (t.rx - self.prev.rx) * 1000 / dt;
        const tx = (t.tx - self.prev.tx) * 1000 / dt;
        const was_idle = self.rx_rate == 0 and self.tx_rate == 0 and self.allZero();
        self.rx_rate = rx;
        self.tx_rate = tx;
        self.push(rx, tx);
        // An idle link that stays idle changes nothing on screen.
        return !(was_idle and rx == 0 and tx == 0 and self.hist_len > 1);
    }

    fn push(self: *Service, rx: u64, tx: u64) void {
        self.hist_head = (self.hist_head + 1) % HISTORY;
        self.rx_hist[self.hist_head] = rx;
        self.tx_hist[self.hist_head] = tx;
        if (self.hist_len < HISTORY) self.hist_len += 1;
    }

    fn allZero(self: *const Service) bool {
        for (0..self.hist_len) |i| {
            const k = (self.hist_head + HISTORY - i) % HISTORY;
            if (self.rx_hist[k] != 0 or self.tx_hist[k] != 0) return false;
        }
        return true;
    }

    /// The i-th oldest kept sample (0 = oldest), rx or tx.
    pub fn histAt(self: *const Service, i: usize, tx: bool) u64 {
        const k = (self.hist_head + HISTORY + 1 - self.hist_len + i) % HISTORY;
        return if (tx) self.tx_hist[k] else self.rx_hist[k];
    }

    /// Largest kept rate in either direction (the graph's scale).
    pub fn histMax(self: *const Service) u64 {
        var m: u64 = 0;
        for (0..self.hist_len) |i| m = @max(m, @max(self.histAt(i, false), self.histAt(i, true)));
        return m;
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

const DEV_A =
    \\Inter-|   Receive                                                |  Transmit
    \\ face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    \\    lo: 9000000    100    0    0    0     0          0         0  9000000    100    0    0    0     0       0          0
    \\wlp3s0: 1000000   2000    0    0    0     0          0         0   200000   1000    0    0    0     0       0          0
    \\enp4s0:  500000    100    0    0    0     0          0         0    50000     10    0    0    0     0       0          0
    \\docker0: 7777777   10    0    0    0     0          0         0  7777777     10    0    0    0     0       0          0
    \\  tun0: 3333333     10    0    0    0     0          0         0  3333333     10    0    0    0     0       0          0
;

test "parseProcNetDev: sums physical interfaces only" {
    const t = parseProcNetDev(DEV_A);
    try std.testing.expectEqual(@as(u32, 2), t.ifaces);
    try std.testing.expectEqual(@as(u64, 1_500_000), t.rx);
    try std.testing.expectEqual(@as(u64, 250_000), t.tx);
    // Header-only and truncated lines count nothing.
    const bad = parseProcNetDev("Inter-| Receive\n eth0: 12 3\n");
    try std.testing.expectEqual(@as(u32, 0), bad.ifaces);
}

test "fmtRate: unit steps" {
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0 B/s", fmtRate(&b, 0));
    try std.testing.expectEqualStrings("1023 B/s", fmtRate(&b, 1023));
    try std.testing.expectEqualStrings("1.0 KB/s", fmtRate(&b, 1024));
    try std.testing.expectEqualStrings("12.5 KB/s", fmtRate(&b, 12800));
    try std.testing.expectEqualStrings("4.5 MB/s", fmtRate(&b, 4718592));
    try std.testing.expectEqualStrings("1.0 GB/s", fmtRate(&b, 1024 * 1024 * 1024));
}

test "Service.sample: rates over real time, resets, idle stays quiet" {
    var s = Service.init(.{});
    const line = "eth0: {d} 1 0 0 0 0 0 0 {d} 1 0 0 0 0 0 0\n";
    var buf: [128]u8 = undefined;

    _ = s.sample(try std.fmt.bufPrint(&buf, line, .{ 1000, 500 }), 0);
    try std.testing.expect(!s.ready());
    // 2 s later: +4096 down, +2048 up => 2048 B/s and 1024 B/s.
    try std.testing.expect(s.sample(try std.fmt.bufPrint(&buf, line, .{ 5096, 2548 }), 2000));
    try std.testing.expect(s.ready());
    try std.testing.expectEqual(@as(u64, 2048), s.rx_rate);
    try std.testing.expectEqual(@as(u64, 1024), s.tx_rate);
    try std.testing.expectEqual(@as(u64, 2048), s.histMax());

    // Counter went backwards: new baseline, no spike, rate unchanged.
    _ = s.sample(try std.fmt.bufPrint(&buf, line, .{ 10, 10 }), 4000);
    try std.testing.expectEqual(@as(u64, 2048), s.rx_rate);
    try std.testing.expectEqual(@as(usize, 1), s.hist_len);

    // Fresh service on an idle link: the first zero sample paints once,
    // later zero samples don't.
    var q = Service.init(.{});
    _ = q.sample(try std.fmt.bufPrint(&buf, line, .{ 7, 7 }), 0);
    try std.testing.expect(q.sample(try std.fmt.bufPrint(&buf, line, .{ 7, 7 }), 1000));
    try std.testing.expect(!q.sample(try std.fmt.bufPrint(&buf, line, .{ 7, 7 }), 2000));
    try std.testing.expect(q.sample(try std.fmt.bufPrint(&buf, line, .{ 1031, 7 }), 3000));
    try std.testing.expectEqual(@as(u64, 1024), q.rx_rate);
}

test "Service.histAt: oldest first, ring wraps" {
    var s = Service.init(.{});
    for (0..HISTORY + 5) |i| s.push(i, 0);
    try std.testing.expectEqual(@as(usize, HISTORY), s.hist_len);
    try std.testing.expectEqual(@as(u64, 5), s.histAt(0, false));
    try std.testing.expectEqual(@as(u64, HISTORY + 4), s.histAt(HISTORY - 1, false));
}

test "Service.tick: reads a fake /proc/net/dev file on its interval" {
    const path = "/tmp/perihelion-netrate-test-dev";
    {
        const fd = posix.system.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(posix.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = posix.system.close(@intCast(fd));
        const body = "eth0: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0\n";
        _ = posix.system.write(@intCast(fd), body.ptr, body.len);
    }
    defer _ = posix.system.unlink(path);
    var s = Service.init(.{ .interval_ms = 1000, .path = path });
    _ = s.tick(0);
    try std.testing.expect(s.have_prev);
    try std.testing.expectEqual(@as(u64, 100), s.prev.rx);
    try std.testing.expect(!s.tick(500)); // not due yet
}
