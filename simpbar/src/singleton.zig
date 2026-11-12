//! One Perihelion Bar and one Dock, ever.
//!
//! Both are the same program (perihelion-bar); the dock is started with
//! SIMPBAR_DOCK=1. Two layers keep each to a single copy:
//!
//!   * a lock: each role holds an exclusive flock (bar.lock / dock.lock)
//!     for its whole life. The kernel drops it when the process ends, crash
//!     included, so it can never go stale. A second copy of a role cannot
//!     get it and exits before it creates anything on screen;
//!   * a sweep: the copy that holds the lock ends every other copy of its
//!     role it finds in /proc (copies from older builds hold no lock, so
//!     the lock alone cannot see them). Perihelion Settings uses the same
//!     scan to stop and count copies when a switch is flipped.
//!
//! Shared by the bar (main.zig) and Perihelion Settings (config_main.zig).
//! libc only, no allocation.

const std = @import("std");

pub const Role = enum { bar, dock };

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn getuid() c_uint;
extern "c" fn getpid() c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn flock(fd: c_int, operation: c_int) c_int;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;

const DIR = opaque {};
extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
extern "c" fn readdir(dir: *DIR) ?*Dirent;
extern "c" fn closedir(dir: *DIR) c_int;

/// glibc's 64-bit struct dirent on Linux (same binding as main.zig's).
const Dirent = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [256]u8,
};

// Linux open(2) flags (identical on x86_64 and aarch64).
const O_RDONLY: c_int = 0;
const O_RDWR: c_int = 0o2;
const O_CREAT: c_int = 0o100;
const O_CLOEXEC: c_int = 0o2000000;
const LOCK_EX: c_int = 2;
const LOCK_NB: c_int = 4;
const SIGTERM: c_int = 15;
const SIGKILL: c_int = 9;

/// The process name both roles run under (/proc/<pid>/status "Name:").
const PROC_NAME = "perihelion-bar";
const DOCK_FLAG = "SIMPBAR_DOCK=1";

pub const Lock = enum {
    /// This process is now the one copy of its role.
    held,
    /// Another copy of this role is running: leave.
    busy,
    /// No lock file could be opened anywhere (read-only home and no runtime
    /// dir): run unlocked rather than refuse to start. Never sweeps.
    unavailable,
};

/// How long a second copy keeps trying before it leaves: long enough for a
/// copy that was just told to stop to let go (a restart), short enough to
/// be immediate. It has no window, surface or pidfile while it waits.
const ACQUIRE_TRIES: u32 = 6; // x 50 ms

fn openLock(role: Role) c_int {
    const name: []const u8 = if (role == .dock) "dock" else "bar";
    var buf: [600]u8 = undefined;
    const home = std.mem.span(getenv("HOME") orelse "/root");
    if (std.fmt.bufPrintZ(&buf, "{s}/.config/simpbar/{s}.lock", .{ home, name })) |path| {
        const fd = open(path.ptr, O_RDWR | O_CREAT | O_CLOEXEC, @as(c_uint, 0o644));
        if (fd >= 0) return fd;
    } else |_| {}
    if (getenv("XDG_RUNTIME_DIR")) |rt| {
        if (std.fmt.bufPrintZ(&buf, "{s}/perihelion-{s}.lock", .{ std.mem.span(rt), name })) |path| {
            const fd = open(path.ptr, O_RDWR | O_CREAT | O_CLOEXEC, @as(c_uint, 0o644));
            if (fd >= 0) return fd;
        } else |_| {}
    }
    return -1;
}

/// Takes this role's lock for the life of the process (the fd is never
/// closed on purpose; O_CLOEXEC keeps it out of everything we launch).
pub fn acquire(role: Role) Lock {
    const fd = openLock(role);
    if (fd < 0) return .unavailable;
    var tries: u32 = 0;
    while (true) {
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) return .held;
        tries += 1;
        if (tries >= ACQUIRE_TRIES) break;
        _ = usleep(50_000);
    }
    _ = close(fd);
    return .busy;
}

fn readInto(path: [*:0]const u8, buf: []u8) ?[]u8 {
    const fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return buf[0..len];
}

/// The value of a "Key:\tvalue" line in /proc/<pid>/status.
fn statusField(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        return std.mem.trim(u8, line[key.len..], " \t");
    }
    return null;
}

/// Whether a NUL-separated environment block has SIMPBAR_DOCK=1.
fn envIsDock(env: []const u8) bool {
    var it = std.mem.splitScalar(u8, env, 0);
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry, DOCK_FLAG)) return true;
    }
    return false;
}

// /proc/<pid>/environ always shows the environment a process was STARTED
// with (the bar removing SIMPBAR_DOCK from its live environment does not
// change it), which is exactly the role it runs as.
var env_buf: [131072]u8 = undefined;

/// The role `pid` runs as, or null when it is not a live perihelion-bar of
/// this user (or can't be told for sure: then it is left alone).
fn roleOf(pid: c_int) ?Role {
    var path_buf: [64]u8 = undefined;
    var status_buf: [2048]u8 = undefined;
    const status_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/status", .{pid}) catch return null;
    const status = readInto(status_path.ptr, &status_buf) orelse return null;
    const name = statusField(status, "Name:") orelse return null;
    if (!std.mem.eql(u8, name, PROC_NAME)) return null;
    // A zombie has already let go of everything; it only awaits its parent.
    const state = statusField(status, "State:") orelse return null;
    if (state.len == 0 or state[0] == 'Z' or state[0] == 'X') return null;
    const uid_line = statusField(status, "Uid:") orelse return null;
    var uid_it = std.mem.tokenizeAny(u8, uid_line, " \t");
    const uid = std.fmt.parseInt(c_uint, uid_it.next() orelse return null, 10) catch return null;
    if (uid != getuid()) return null;

    const env_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/environ", .{pid}) catch return null;
    const env = readInto(env_path.ptr, &env_buf) orelse return null;
    if (env.len == env_buf.len) return null; // cut short: can't be sure
    return if (envIsDock(env)) .dock else .bar;
}

pub const MAX_COPIES = 64;

/// Every other running copy of `role` (never this process). Returns how
/// many pids were written to `out`.
pub fn list(role: Role, out: []c_int) usize {
    const dir = opendir("/proc") orelse return 0;
    defer _ = closedir(dir);
    const self = getpid();
    var n: usize = 0;
    while (readdir(dir)) |ent| {
        const name = std.mem.sliceTo(&ent.d_name, 0);
        if (name.len == 0 or name[0] < '0' or name[0] > '9') continue;
        const pid = std.fmt.parseInt(c_int, name, 10) catch continue;
        if (pid == self) continue;
        const r = roleOf(pid) orelse continue;
        if (r != role) continue;
        if (n >= out.len) break;
        out[n] = pid;
        n += 1;
    }
    return n;
}

pub fn count(role: Role) usize {
    var pids: [MAX_COPIES]c_int = undefined;
    return list(role, &pids);
}

/// Asks every other copy of `role` to stop. For the copy that holds the
/// lock: anything else of its role is a duplicate. Returns how many.
pub fn sweep(role: Role) usize {
    var pids: [MAX_COPIES]c_int = undefined;
    const n = list(role, &pids);
    for (pids[0..n]) |pid| _ = kill(pid, SIGTERM);
    return n;
}

/// Stops every copy of `role` and returns once none is left (asks first,
/// insists after 1.5 s). For Perihelion Settings: "off" and "restart" are
/// finished when this returns, so the next "on" starts from zero.
pub fn stopAll(role: Role) void {
    if (sweep(role) == 0) return;
    var waited: u32 = 0;
    while (waited < 1500) : (waited += 50) {
        _ = usleep(50_000);
        if (count(role) == 0) return;
    }
    var pids: [MAX_COPIES]c_int = undefined;
    const n = list(role, &pids);
    for (pids[0..n]) |pid| _ = kill(pid, SIGKILL);
    waited = 0;
    while (waited < 500 and count(role) > 0) : (waited += 50) _ = usleep(50_000);
}

test "status fields and role flag" {
    const status = "Name:\tperihelion-bar\nUmask:\t0022\nState:\tS (sleeping)\nUid:\t1000\t1000\t1000\t1000\n";
    try std.testing.expectEqualStrings("perihelion-bar", statusField(status, "Name:").?);
    try std.testing.expectEqualStrings("S (sleeping)", statusField(status, "State:").?);
    try std.testing.expect(statusField(status, "Nope:") == null);
    try std.testing.expect(envIsDock("HOME=/home/a\x00SIMPBAR_DOCK=1\x00PATH=/usr/bin\x00"));
    try std.testing.expect(!envIsDock("HOME=/home/a\x00PATH=/usr/bin\x00"));
    try std.testing.expect(!envIsDock("X_SIMPBAR_DOCK=1\x00"));
}
