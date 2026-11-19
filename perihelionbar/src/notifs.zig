//! Notification-center data for the bar's notifications panel. No drawing,
//! no processes: the bar runs makoctl itself (nonblocking, only when the
//! panel opens or after Clear / Do not disturb) and hands the output here.
//!
//! mako keeps showing the pop-ups; the panel only reads its history.
//! mako 1.11 (Fedora 45) prints `makoctl history -j` as a JSON array of
//! objects with id, summary, body, app_name, app_icon, category,
//! desktop_entry, urgency and actions, and plain `makoctl history` as
//! "Notification <id>: <summary>" blocks with "  App name: …" lines (no
//! body). Neither has a time, so the panel shows no age. Parsing is
//! defensive: JSON first, then the plain shape, then the raw text; nothing
//! here can fail on odd input, and input past MAX_READ is never looked at.
//!
//! mako can't clear its history, so "Clear all" remembers the newest id it
//! cleared together with mako's PID (ids restart when mako restarts) in a
//! small state file, and the panel hides everything up to that id. The same
//! file keeps the Do-not-disturb choice, which mako forgets on restart.
//!
//! Tests: `zig build test-notifs` (sample outputs, garbage, a huge input,
//! state files and a fake /proc under /tmp).

const std = @import("std");
const posix = std.posix;

/// Most bytes of makoctl output read and parsed.
pub const MAX_READ: usize = 64 * 1024;
/// Most notifications kept for the panel, newest first.
pub const MAX_ITEMS: usize = 20;

pub const DND_MODE = "do-not-disturb";

pub fn Text(comptime N: usize) type {
    return struct {
        buf: [N]u8 = undefined,
        len: usize = 0,
        const Self = @This();
        /// Copies `s`, turning newlines and tabs into spaces, dropping
        /// other control bytes and never cutting a UTF-8 sequence.
        pub fn set(self: *Self, s: []const u8) void {
            var n: usize = 0;
            var i: usize = 0;
            while (i < s.len and n < N) {
                const c = s[i];
                const len: usize = if (c < 0x80) 1 else std.unicode.utf8ByteSequenceLength(c) catch 1;
                if (i + len > s.len or n + len > N) break;
                if (c < 0x20 or c == 0x7F) {
                    if ((c == '\n' or c == '\t' or c == '\r') and n > 0 and self.buf[n - 1] != ' ') {
                        self.buf[n] = ' ';
                        n += 1;
                    }
                    i += 1;
                    continue;
                }
                @memcpy(self.buf[n .. n + len], s[i .. i + len]);
                n += len;
                i += len;
            }
            self.len = n;
        }
        pub fn slice(self: *const Self) []const u8 {
            return std.mem.trim(u8, self.buf[0..self.len], " ");
        }
    };
}

pub const Item = struct {
    id: u32 = 0,
    app: Text(48) = .{},
    summary: Text(120) = .{},
    body: Text(240) = .{},
    /// 0 low, 1 normal, 2 critical.
    urgency: u8 = 1,
};

pub const Shape = enum { empty, json, plain, raw };

pub const History = struct {
    items: [MAX_ITEMS]Item = undefined,
    count: usize = 0,
    shape: Shape = .empty,
    /// Unrecognised output, first part (shown as-is instead of rows).
    raw: Text(200) = .{},
    /// Highest id seen, including ones dropped past MAX_ITEMS.
    max_id: u32 = 0,

    pub fn slice(self: *const History) []const Item {
        return self.items[0..self.count];
    }

    /// Keeps the item if there is room, else replaces the oldest one when
    /// it is newer (the list ends up the MAX_ITEMS newest).
    fn add(self: *History, it: Item) void {
        self.max_id = @max(self.max_id, it.id);
        if (self.count < MAX_ITEMS) {
            self.items[self.count] = it;
            self.count += 1;
            return;
        }
        var oldest: usize = 0;
        for (self.items[1..], 1..) |x, i| {
            if (x.id < self.items[oldest].id) oldest = i;
        }
        if (it.id > self.items[oldest].id) self.items[oldest] = it;
    }

    fn sortNewestFirst(self: *History) void {
        std.mem.sort(Item, self.items[0..self.count], {}, struct {
            fn gt(_: void, a: Item, b: Item) bool {
                return a.id > b.id;
            }
        }.gt);
    }

    /// Drops everything up to `cleared` (Clear all).
    pub fn hideUpTo(self: *History, cleared: u32) void {
        if (cleared == 0) return;
        var n: usize = 0;
        for (self.items[0..self.count]) |it| {
            if (it.id <= cleared) continue;
            self.items[n] = it;
            n += 1;
        }
        self.count = n;
    }
};

fn urgencyOf(s: []const u8) u8 {
    if (std.ascii.eqlIgnoreCase(s, "low")) return 0;
    if (std.ascii.eqlIgnoreCase(s, "critical")) return 2;
    return 1;
}

fn strOf(v: ?std.json.Value) []const u8 {
    const x = v orelse return "";
    return switch (x) {
        .string => |s| s,
        else => "",
    };
}

fn parseJson(text: []const u8, out: *History) bool {
    var buf: [256 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const root = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), text, .{}) catch return false;
    // makoctl prints a bare array; accept {"data": [...]} too (older
    // makoctl wrapped the D-Bus reply that way).
    const arr = switch (root) {
        .array => |a| a,
        .object => |o| blk: {
            const d = o.get("data") orelse return false;
            var cur = d;
            // {"data": [[ ... ]]}
            while (cur == .array and cur.array.items.len == 1 and cur.array.items[0] == .array) cur = cur.array.items[0];
            if (cur != .array) return false;
            break :blk cur.array;
        },
        else => return false,
    };
    for (arr.items) |v| {
        if (v != .object) continue;
        const o = v.object;
        var it = Item{};
        const idv = o.get("id") orelse continue;
        it.id = switch (idv) {
            .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else continue,
            .object => |io| blk: { // {"id": {"data": 7}}
                const d = io.get("data") orelse continue;
                if (d != .integer or d.integer < 0 or d.integer > std.math.maxInt(u32)) continue;
                break :blk @intCast(d.integer);
            },
            else => continue,
        };
        it.summary.set(strOf(o.get("summary")));
        it.body.set(strOf(o.get("body")));
        const app = strOf(o.get("app_name"));
        it.app.set(if (app.len > 0) app else strOf(o.get("app-name")));
        it.urgency = switch (o.get("urgency") orelse std.json.Value{ .null = {} }) {
            .string => |s| urgencyOf(s),
            .integer => |n| @intCast(std.math.clamp(n, 0, 2)),
            else => 1,
        };
        out.add(it);
    }
    out.shape = .json;
    return true;
}

fn parsePlain(text: []const u8, out: *History) bool {
    var any = false;
    var cur: ?Item = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " \r");
        if (std.mem.startsWith(u8, line, "Notification ")) {
            if (cur) |c| out.add(c);
            cur = null;
            const rest = line["Notification ".len..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            const id = std.fmt.parseInt(u32, std.mem.trim(u8, rest[0..colon], " "), 10) catch continue;
            var n = Item{ .id = id };
            n.summary.set(std.mem.trim(u8, rest[colon + 1 ..], " "));
            cur = n;
            any = true;
            continue;
        }
        const c = &(cur orelse continue);
        const t = std.mem.trim(u8, line, " ");
        if (std.mem.startsWith(u8, t, "App name:")) c.app.set(std.mem.trim(u8, t["App name:".len..], " "));
        if (std.mem.startsWith(u8, t, "Urgency:")) c.urgency = urgencyOf(std.mem.trim(u8, t["Urgency:".len..], " "));
        if (std.mem.startsWith(u8, t, "Body:")) c.body.set(std.mem.trim(u8, t["Body:".len..], " "));
    }
    if (cur) |c| out.add(c);
    if (any) out.shape = .plain;
    return any;
}

/// makoctl history output (-j or plain) -> the newest MAX_ITEMS items,
/// newest first. Never fails: an unknown shape keeps its first bytes in
/// `raw`, nothing at all is `.empty`.
pub fn parseHistory(text_in: []const u8) History {
    var h = History{};
    const text = std.mem.trim(u8, text_in[0..@min(text_in.len, MAX_READ)], " \t\r\n");
    if (text.len == 0) return h;
    if ((text[0] == '[' or text[0] == '{') and parseJson(text, &h)) {
        h.sortNewestFirst();
        return h;
    }
    h = .{};
    if (parsePlain(text, &h)) {
        h.sortNewestFirst();
        return h;
    }
    h = .{};
    h.shape = .raw;
    h.raw.set(text);
    return h;
}

/// "dnd=1\ncleared=42\npid=1234\n": the panel's remembered choices.
pub const State = struct {
    dnd: bool = false,
    cleared: u32 = 0,
    /// mako's PID when `cleared` was taken; another PID means mako
    /// restarted (ids start over), so the cleared id no longer applies.
    pid: u32 = 0,

    pub fn parse(text: []const u8) State {
        var s = State{};
        var it = std.mem.splitScalar(u8, text[0..@min(text.len, 4096)], '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = line[0..eq];
            const v = line[eq + 1 ..];
            if (std.mem.eql(u8, k, "dnd")) s.dnd = std.mem.eql(u8, v, "1");
            if (std.mem.eql(u8, k, "cleared")) s.cleared = std.fmt.parseInt(u32, v, 10) catch 0;
            if (std.mem.eql(u8, k, "pid")) s.pid = std.fmt.parseInt(u32, v, 10) catch 0;
        }
        return s;
    }

    pub fn format(self: State, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "dnd={d}\ncleared={d}\npid={d}\n", .{ @intFromBool(self.dnd), self.cleared, self.pid }) catch "";
    }

    /// The cleared id that still applies to the mako running as `pid`.
    pub fn clearedFor(self: State, pid: u32) u32 {
        return if (pid != 0 and pid == self.pid) self.cleared else 0;
    }
};

/// The state file: $XDG_STATE_HOME/perihelionbar/notifications, else
/// ~/.local/state/perihelionbar/notifications.
pub fn statePath(buf: []u8, xdg_state: []const u8, home: []const u8) ?[:0]const u8 {
    if (xdg_state.len > 0) return std.fmt.bufPrintSentinel(buf, "{s}/perihelionbar/notifications", .{xdg_state}, 0) catch null;
    if (home.len == 0) return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/.local/state/perihelionbar/notifications", .{home}, 0) catch null;
}

pub fn loadState(path: [:0]const u8) State {
    const raw = posix.system.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw < 0) return .{};
    const fd: posix.fd_t = @intCast(raw);
    defer _ = posix.system.close(fd);
    var b: [512]u8 = undefined;
    const n = posix.read(fd, &b) catch return .{};
    return State.parse(b[0..n]);
}

/// Atomic write (temp file + rename), creating the directory.
pub fn saveState(path: [:0]const u8, s: State) bool {
    var db: [512]u8 = undefined;
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/') continue;
        @memcpy(db[0..i], path[0..i]);
        db[i] = 0;
        _ = posix.system.mkdir(db[0..i :0].ptr, 0o755);
    }
    var tb: [520]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tb, "{s}.tmp", .{path}, 0) catch return false;
    const raw = posix.system.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(posix.mode_t, 0o600));
    if (raw < 0) return false;
    const fd: posix.fd_t = @intCast(raw);
    var b: [128]u8 = undefined;
    const text = s.format(&b);
    const w = std.c.write(fd, text.ptr, text.len);
    _ = posix.system.close(fd);
    if (w != @as(isize, @intCast(text.len))) return false;
    return std.c.rename(tmp.ptr, path.ptr) == 0;
}

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
    extern "c" fn getuid() u32;
};

/// PID of a process named `comm` owned by `uid` under `proc` ("/proc" in
/// real use), or 0. One readdir plus a small read per numeric entry.
pub fn findPid(proc: []const u8, comm: []const u8, uid: ?u32) u32 {
    var pz: [256]u8 = undefined;
    const pdir = std.fmt.bufPrintSentinel(&pz, "{s}", .{proc}, 0) catch return 0;
    const d = libc.opendir(pdir.ptr) orelse return 0;
    defer _ = libc.closedir(d);
    const want_uid = uid orelse libc.getuid();
    while (libc.readdir(d)) |e| {
        const name = std.mem.sliceTo(&e.d_name, 0);
        const pid = std.fmt.parseInt(u32, name, 10) catch continue;
        var pb: [300]u8 = undefined;
        const cp = std.fmt.bufPrintSentinel(&pb, "{s}/{s}/comm", .{ proc, name }, 0) catch continue;
        const raw = posix.system.open(cp.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
        if (raw < 0) continue;
        var b: [64]u8 = undefined;
        const n = posix.read(@intCast(raw), &b) catch 0;
        _ = posix.system.close(@intCast(raw));
        if (!std.mem.eql(u8, std.mem.trim(u8, b[0..n], " \n"), comm)) continue;
        // Owner: the "Uid:" line of status (a fake tree may leave it out).
        const sp = std.fmt.bufPrintSentinel(&pb, "{s}/{s}/status", .{ proc, name }, 0) catch continue;
        const sraw = posix.system.open(sp.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
        if (sraw >= 0) {
            var sb: [2048]u8 = undefined;
            const sn = posix.read(@intCast(sraw), &sb) catch 0;
            _ = posix.system.close(@intCast(sraw));
            if (std.mem.indexOf(u8, sb[0..sn], "\nUid:")) |ui| {
                var tok = std.mem.tokenizeAny(u8, sb[ui + 5 .. sn], " \t\n");
                const u = std.fmt.parseInt(u32, tok.next() orelse "", 10) catch want_uid;
                if (u != want_uid) continue;
            }
        }
        return pid;
    }
    return 0;
}

/// The marker the bar's makoctl scripts print when makoctl failed (mako
/// not running, makoctl missing).
pub const FAIL_MARK = "@@makoctl-failed";

/// Splits a script's output into the history text and whether makoctl
/// failed (FAIL_MARK on its own line at the end).
pub fn splitFail(out: []const u8) struct { text: []const u8, failed: bool } {
    const t = std.mem.trimEnd(u8, out, " \r\n");
    if (std.mem.endsWith(u8, t, FAIL_MARK)) return .{ .text = t[0 .. t.len - FAIL_MARK.len], .failed = true };
    return .{ .text = t, .failed = false };
}

// --- tests ------------------------------------------------------------------

const JSON_SAMPLE =
    \\[
    \\  {
    \\    "id": 7,
    \\    "app_name": "Firefox",
    \\    "app_icon": "firefox",
    \\    "category": "",
    \\    "desktop_entry": "firefox",
    \\    "summary": "Download finished",
    \\    "body": "perihelion.iso\nsaved to Downloads",
    \\    "urgency": "normal",
    \\    "actions": {}
    \\  },
    \\  {
    \\    "id": 9,
    \\    "app_name": "notify-send",
    \\    "summary": "Hello été",
    \\    "body": "",
    \\    "urgency": "critical",
    \\    "actions": { "default": "Open" }
    \\  },
    \\  { "id": 3, "app_name": "Discord", "summary": "New message", "body": "hey", "urgency": "low" }
    \\]
;

test "json history: newest first, fields, urgency, newlines flattened" {
    const h = parseHistory(JSON_SAMPLE);
    try std.testing.expectEqual(Shape.json, h.shape);
    try std.testing.expectEqual(@as(usize, 3), h.count);
    try std.testing.expectEqual(@as(u32, 9), h.items[0].id);
    try std.testing.expectEqualStrings("Hello été", h.items[0].summary.slice());
    try std.testing.expectEqual(@as(u8, 2), h.items[0].urgency);
    try std.testing.expectEqualStrings("Firefox", h.items[1].app.slice());
    try std.testing.expectEqualStrings("perihelion.iso saved to Downloads", h.items[1].body.slice());
    try std.testing.expectEqual(@as(u8, 0), h.items[2].urgency);
    try std.testing.expectEqual(@as(u32, 9), h.max_id);
}

test "plain history and the old wrapped json" {
    const plain =
        \\Notification 12: Battery low
        \\  App name: upower
        \\  Urgency: critical
        \\Notification 4: Track changed
        \\  App name: Spotify
        \\  Category: x
        \\  Actions:
        \\    default: Open
    ;
    const h = parseHistory(plain);
    try std.testing.expectEqual(Shape.plain, h.shape);
    try std.testing.expectEqual(@as(usize, 2), h.count);
    try std.testing.expectEqualStrings("Battery low", h.items[0].summary.slice());
    try std.testing.expectEqualStrings("upower", h.items[0].app.slice());
    try std.testing.expectEqualStrings("Spotify", h.items[1].app.slice());

    const wrapped = "{\"type\":\"aa{sv}\",\"data\":[[{\"id\":{\"type\":\"u\",\"data\":5},\"summary\":\"x\"}]]}";
    const w = parseHistory(wrapped);
    try std.testing.expectEqual(Shape.json, w.shape);
    try std.testing.expectEqual(@as(u32, 5), w.items[0].id);
}

test "empty, garbage and broken input never crash" {
    try std.testing.expectEqual(Shape.empty, parseHistory("").shape);
    try std.testing.expectEqual(Shape.empty, parseHistory(" \n\t").shape);
    try std.testing.expectEqual(Shape.json, parseHistory("[]").shape);
    try std.testing.expectEqual(@as(usize, 0), parseHistory("[]").count);
    const g = parseHistory("Failed to connect to user bus: No such file\x01\x02");
    try std.testing.expectEqual(Shape.raw, g.shape);
    try std.testing.expect(std.mem.startsWith(u8, g.raw.slice(), "Failed to connect"));
    // Truncated JSON falls back to raw text, not a crash.
    try std.testing.expectEqual(Shape.raw, parseHistory("[{\"id\": 3, \"summary\": \"cut").shape);
    // Wrong types are skipped.
    const odd = parseHistory("[1, \"x\", {\"id\": -4}, {\"id\": \"7\"}, {\"summary\": \"no id\"}, {\"id\": 2, \"summary\": 5}]");
    try std.testing.expectEqual(@as(usize, 1), odd.count);
    try std.testing.expectEqual(@as(u32, 2), odd.items[0].id);
    try std.testing.expectEqualStrings("", odd.items[0].summary.slice());
}

test "huge input: capped read, the newest MAX_ITEMS kept" {
    var big: [MAX_READ + 4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&big);
    w.writeAll("[") catch unreachable;
    var i: u32 = 1;
    while (i <= 60) : (i += 1) {
        w.print("{s}{{\"id\":{d},\"app_name\":\"app\",\"summary\":\"s{d}\",\"body\":\"", .{ if (i > 1) "," else "", i, i }) catch unreachable;
        var k: usize = 0;
        while (k < 600) : (k += 1) w.writeByte('b') catch unreachable;
        w.writeAll("\"}") catch unreachable;
    }
    w.writeAll("]") catch unreachable;
    const text = w.buffered();
    try std.testing.expect(text.len < MAX_READ); // 60 items fit
    const h = parseHistory(text);
    try std.testing.expectEqual(MAX_ITEMS, h.count);
    try std.testing.expectEqual(@as(u32, 60), h.items[0].id);
    try std.testing.expectEqual(@as(u32, 41), h.items[MAX_ITEMS - 1].id);
    try std.testing.expectEqual(@as(usize, 240), h.items[0].body.len); // body cut to fit
    // Past MAX_READ: only the first MAX_READ bytes are looked at (here a
    // cut-off array, shown raw) and nothing crashes.
    @memset(big[0..], 'x');
    big[0] = '[';
    const r = parseHistory(big[0..]);
    try std.testing.expectEqual(Shape.raw, r.shape);
    try std.testing.expectEqual(@as(usize, 200), r.raw.len);
}

test "clear hides up to the remembered id; fail marker" {
    var h = parseHistory(JSON_SAMPLE);
    h.hideUpTo(7);
    try std.testing.expectEqual(@as(usize, 1), h.count);
    try std.testing.expectEqual(@as(u32, 9), h.items[0].id);
    const s = splitFail("[]\n" ++ FAIL_MARK ++ "\n");
    try std.testing.expect(s.failed);
    try std.testing.expectEqualStrings("[]\n", s.text);
    try std.testing.expect(!splitFail("[]").failed);
}

test "state file: parse, format, atomic save and load, pid binding" {
    const st = State.parse("dnd=1\ncleared=42\npid=777\njunk\n=\n");
    try std.testing.expect(st.dnd);
    try std.testing.expectEqual(@as(u32, 42), st.cleared);
    try std.testing.expectEqual(@as(u32, 42), st.clearedFor(777));
    try std.testing.expectEqual(@as(u32, 0), st.clearedFor(778)); // mako restarted
    try std.testing.expect(!State.parse("garbage\x00\xff").dnd);

    var pb: [128]u8 = undefined;
    var rb: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&rb, "/tmp/perihelion-notifs-{d}", .{std.c.getpid()}) catch unreachable;
    const path = statePath(&pb, "", root).?;
    try std.testing.expect(std.mem.endsWith(u8, path, "/.local/state/perihelionbar/notifications"));
    try std.testing.expectEqual(State{}, loadState(path)); // missing file
    try std.testing.expect(saveState(path, .{ .dnd = true, .cleared = 9, .pid = 3 }));
    const back = loadState(path);
    try std.testing.expect(back.dnd);
    try std.testing.expectEqual(@as(u32, 9), back.cleared);
    try std.testing.expect(saveState(path, .{ .dnd = false }));
    try std.testing.expect(!loadState(path).dnd);
    var xb: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/x/perihelionbar/notifications", statePath(&xb, "/x", "/home/u").?);
}

test "mako pid from a fake /proc" {
    var rb: [64]u8 = undefined;
    const proc = std.fmt.bufPrint(&rb, "/tmp/perihelion-notifs-proc-{d}", .{std.c.getpid()}) catch unreachable;
    const files = [_]struct { rel: []const u8, body: []const u8 }{
        .{ .rel = "1/comm", .body = "systemd\n" },
        .{ .rel = "self/comm", .body = "mako\n" }, // not numeric: skipped
        .{ .rel = "420/comm", .body = "mako\n" },
        .{ .rel = "420/status", .body = "Name:\tmako\nUid:\t999\t999\t999\t999\n" }, // other user
        .{ .rel = "421/comm", .body = "mako\n" },
        .{ .rel = "421/status", .body = "Name:\tmako\nUid:\t1000\t1000\t1000\t1000\n" },
    };
    for (files) |f| {
        var p: [200]u8 = undefined;
        const full = std.fmt.bufPrint(&p, "{s}/{s}", .{ proc, f.rel }) catch unreachable;
        const slash = std.mem.lastIndexOfScalar(u8, full, '/').?;
        var dz: [200]u8 = undefined;
        var k: usize = 1;
        while (k <= slash) : (k += 1) {
            if (k != slash and full[k] != '/') continue;
            @memcpy(dz[0..k], full[0..k]);
            dz[k] = 0;
            _ = posix.system.mkdir(dz[0..k :0].ptr, 0o755);
        }
        var z: [200]u8 = undefined;
        const fz = std.fmt.bufPrintSentinel(&z, "{s}", .{full}, 0) catch unreachable;
        const raw = posix.system.open(fz.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(posix.mode_t, 0o644));
        _ = std.c.write(@intCast(raw), f.body.ptr, f.body.len);
        _ = posix.system.close(@intCast(raw));
    }
    try std.testing.expectEqual(@as(u32, 421), findPid(proc, "mako", 1000));
    try std.testing.expectEqual(@as(u32, 0), findPid(proc, "swaync", 1000));
    try std.testing.expectEqual(@as(u32, 0), findPid("/tmp/perihelion-no-such-proc", "mako", 1000));
}
