//! Coming back after the compositor drops our layer surface.
//!
//! Mango destroys every layer surface on an output when that output goes
//! away (monitor.c: wlr_layer_surface_v1_destroy), and the client gets
//! `closed`. That happens on a real unplug, and also on resume when the
//! GPU re-probes its connectors (virtio-gpu in a VM, some DisplayPort
//! monitors): the output disappears and a new one takes its place. The bar,
//! the dock and the shell used to exit(0) on `closed`, and nothing started
//! them again, so the desktop came back with no bar, no cards and no dock.
//!
//! Now they start themselves again: a forked child waits a moment (the new
//! output needs to be announced first), then execs the same command line
//! with the same environment, so the dock comes back as the dock. The
//! singleton lock is free by then, because the old process exits at once.
//!
//! The rule below caps it: at most MAX_IN_WINDOW restarts per WINDOW_S
//! seconds, with a growing delay, so a compositor that is shutting down (it
//! closes every surface, then the new process cannot connect and exits) or
//! keeps closing the surface can never cause a restart loop. The count rides
//! along in the PERIHELION_RESPAWN environment variable ("count:since").

const std = @import("std");

pub const ENV = "PERIHELION_RESPAWN";
pub const WINDOW_S: i64 = 300;
pub const MAX_IN_WINDOW: u32 = 6;
pub const FIRST_DELAY_MS: u32 = 500;
pub const MAX_DELAY_MS: u32 = 8000;

pub const State = struct {
    count: u32 = 0,
    since_s: i64 = 0,
};

/// "count:since" from the environment; anything malformed counts as none.
pub fn parse(text: ?[]const u8) State {
    const t = text orelse return .{};
    const colon = std.mem.indexOfScalar(u8, t, ':') orelse return .{};
    const count = std.fmt.parseInt(u32, t[0..colon], 10) catch return .{};
    const since = std.fmt.parseInt(i64, t[colon + 1 ..], 10) catch return .{};
    if (since < 0) return .{};
    return .{ .count = count, .since_s = since };
}

pub fn format(buf: []u8, s: State) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{d}:{d}", .{ s.count, s.since_s }, 0);
}

pub const Decision = union(enum) {
    restart: struct { state: State, delay_ms: u32 },
    give_up,
};

/// What to do on `closed`, given the restarts so far and the time now.
pub fn decide(prev: State, now_s: i64) Decision {
    var s = prev;
    // A fresh window: first restart, the old window ran out, or the clock
    // went backwards.
    if (s.count == 0 or now_s < s.since_s or now_s - s.since_s >= WINDOW_S) s = .{ .count = 0, .since_s = now_s };
    if (s.count >= MAX_IN_WINDOW) return .give_up;
    s.count += 1;
    const shift: u5 = @intCast(@min(s.count - 1, 16));
    const delay: u64 = @as(u64, FIRST_DELAY_MS) << shift;
    return .{ .restart = .{ .state = s, .delay_ms = @intCast(@min(delay, MAX_DELAY_MS)) } };
}

/// Splits /proc/self/cmdline (NUL-separated, NUL-terminated) into argv.
/// Returns the number of arguments written (argv[n] is set to null).
pub fn splitCmdline(cmdline: []u8, argv: []?[*:0]const u8) usize {
    if (argv.len == 0) return 0;
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < cmdline.len and n + 1 < argv.len) : (i += 1) {
        if (cmdline[i] != 0) continue;
        argv[n] = @ptrCast(cmdline[start..i :0].ptr);
        n += 1;
        start = i + 1;
    }
    argv[n] = null;
    return n;
}

// --- the side-effecting part (not unit-tested; tests/ covers the rule) ------

const libc = struct {
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn time(t: ?*i64) i64;
    extern "c" fn fork() c_int;
    extern "c" fn setsid() c_int;
    extern "c" fn usleep(us: c_uint) c_int;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn _exit(code: c_int) noreturn;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
};

pub const Outcome = enum { restarting, gave_up, failed };

var cmdline_buf: [4096]u8 = undefined;

/// Forks a child that waits, then execs this program's own command line
/// again. The caller logs the outcome and exits right after.
pub fn restartSelf() Outcome {
    const prev = parse(if (libc.getenv(ENV)) |v| std.mem.span(v) else null);
    const d = decide(prev, libc.time(null));
    const r = switch (d) {
        .give_up => return .gave_up,
        .restart => |r| r,
    };

    const fd = libc.open("/proc/self/cmdline", 0o2000000); // O_RDONLY | O_CLOEXEC
    if (fd < 0) return .failed;
    var got: usize = 0;
    while (got < cmdline_buf.len - 1) {
        const n = libc.read(fd, cmdline_buf[got..].ptr, cmdline_buf.len - 1 - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    _ = libc.close(fd);
    if (got == 0) return .failed;
    if (cmdline_buf[got - 1] != 0) {
        cmdline_buf[got] = 0;
        got += 1;
    }
    var argv: [32:null]?[*:0]const u8 = @splat(null);
    if (splitCmdline(cmdline_buf[0..got], argv[0..]) == 0) return .failed;

    var val_buf: [48]u8 = undefined;
    const val = format(&val_buf, r.state) catch return .failed;
    _ = libc.setenv(ENV, val.ptr, 1);

    const pid = libc.fork();
    if (pid < 0) return .failed;
    if (pid == 0) {
        _ = libc.setsid();
        _ = libc.usleep(r.delay_ms * 1000);
        // By name through PATH, so an updated binary is the one that starts.
        _ = libc.execvp(argv[0].?, &argv);
        libc._exit(127);
    }
    return .restarting;
}

// --- tests -------------------------------------------------------------------

const tt = std.testing;

test "parse: valid, missing and malformed" {
    try tt.expectEqual(State{ .count = 2, .since_s = 1700 }, parse("2:1700"));
    try tt.expectEqual(State{}, parse(null));
    try tt.expectEqual(State{}, parse(""));
    try tt.expectEqual(State{}, parse("x:1"));
    try tt.expectEqual(State{}, parse("1:"));
    try tt.expectEqual(State{}, parse("3"));
    try tt.expectEqual(State{}, parse("1:-5"));
}

test "format round-trips through parse" {
    var buf: [48]u8 = undefined;
    const s = State{ .count = 4, .since_s = 1_790_000_000 };
    try tt.expectEqual(s, parse(try format(&buf, s)));
}

test "first restart: fresh window, short delay" {
    const d = decide(.{}, 1000);
    try tt.expectEqual(@as(u32, 1), d.restart.state.count);
    try tt.expectEqual(@as(i64, 1000), d.restart.state.since_s);
    try tt.expectEqual(FIRST_DELAY_MS, d.restart.delay_ms);
}

test "delay doubles and is capped" {
    var s = State{};
    var delays: [MAX_IN_WINDOW]u32 = undefined;
    for (0..MAX_IN_WINDOW) |i| {
        const d = decide(s, 1000 + @as(i64, @intCast(i)));
        s = d.restart.state;
        delays[i] = d.restart.delay_ms;
    }
    try tt.expectEqualSlices(u32, &.{ 500, 1000, 2000, 4000, 8000, 8000 }, &delays);
}

test "gives up after MAX_IN_WINDOW restarts inside the window" {
    const s = State{ .count = MAX_IN_WINDOW, .since_s = 1000 };
    try tt.expect(decide(s, 1000 + WINDOW_S - 1) == .give_up);
}

test "a new window starts once the old one has run out" {
    const s = State{ .count = MAX_IN_WINDOW, .since_s = 1000 };
    const d = decide(s, 1000 + WINDOW_S);
    try tt.expectEqual(@as(u32, 1), d.restart.state.count);
    try tt.expectEqual(FIRST_DELAY_MS, d.restart.delay_ms);
}

test "clock going backwards starts a new window" {
    const s = State{ .count = MAX_IN_WINDOW, .since_s = 5000 };
    try tt.expectEqual(@as(u32, 1), decide(s, 100).restart.state.count);
}

test "splitCmdline" {
    var raw = "perihelion-bar\x00--x\x00a b\x00".*;
    var argv: [8]?[*:0]const u8 = undefined;
    const n = splitCmdline(&raw, &argv);
    try tt.expectEqual(@as(usize, 3), n);
    try tt.expectEqualStrings("perihelion-bar", std.mem.span(argv[0].?));
    try tt.expectEqualStrings("a b", std.mem.span(argv[2].?));
    try tt.expect(argv[3] == null);
}

test "splitCmdline never overruns argv" {
    var raw = "a\x00b\x00c\x00d\x00".*;
    var argv: [3]?[*:0]const u8 = undefined;
    try tt.expectEqual(@as(usize, 2), splitCmdline(&raw, &argv));
    try tt.expect(argv[2] == null);
}
