//! Glance's Media tab: the pure part. What the state probe prints and how
//! it parses, the tab's layout and hit-testing, the seek/volume drag, time
//! formatting, and the argv of every action. No Wayland, no drawing, no
//! processes: glance_view.zig runs the probe through the shared Fetcher,
//! spawns the actions and paints. `zig build test-glance-media`.
//!
//! Player names come from `playerctl -l` and may contain anything a D-Bus
//! name allows, so they are never spliced into shell text: the probe gets
//! the name as its $1, and every action is an argv for /usr/bin/env.

const std = @import("std");
const g = @import("glance.zig");
const Rect = g.Rect;
/// pactl parsing and slider maths shared with the bar's Control Center
/// (../perihelionbar/src/volume.zig): one implementation for both.
pub const volmath = @import("volume");

// --- the state probe ------------------------------------------------------------

const US: u8 = 0x1f; // field separator inside a line

/// One probe = one child: the chosen player's metadata, shuffle and loop,
/// the output volume and mute, and the player list. `$1` is the player
/// ("" = playerctl's default), turned into argv words with `set --`, so the
/// name never becomes script text. Run as: /bin/sh -c PROBE glance-media NAME.
pub const PROBE =
    "if [ -n \"$1\" ]; then set -- -p \"$1\"; else set --; fi\n" ++
    "printf 'M\\037'; playerctl \"$@\" metadata --format " ++
    "'{{playerInstance}}\x1f{{status}}\x1f{{artist}}\x1f{{title}}\x1f{{album}}\x1f{{position}}\x1f{{mpris:length}}\x1f{{mpris:artUrl}}' 2>/dev/null\n" ++
    "printf '\\nS:'; playerctl \"$@\" shuffle 2>/dev/null\n" ++
    "printf '\\nL:'; playerctl \"$@\" loop 2>/dev/null\n" ++
    "printf '\\nV:'; pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | head -n 1\n" ++
    "printf '\\nU:'; pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null\n" ++
    "printf '\\nP:'; playerctl -l 2>/dev/null | tr '\\n' '\\037'\n" ++
    "printf '\\n'\n";

pub const MAX_PLAYERS = 6;

pub fn Text(comptime N: usize) type {
    return struct {
        buf: [N + 1]u8 = @splat(0),
        len: usize = 0,

        const Self = @This();
        pub fn set(self: *Self, s: []const u8) void {
            // Cut on a UTF-8 boundary so a long title never ends mid-glyph.
            var n = @min(s.len, N);
            while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
            @memcpy(self.buf[0..n], s[0..n]);
            self.buf[n] = 0;
            self.len = n;
        }
        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
        pub fn z(self: *const Self) [:0]const u8 {
            return self.buf[0..self.len :0];
        }
    };
}

pub const Status = enum { none, playing, paused, stopped };
pub const Loop = enum {
    none,
    track,
    playlist,

    /// The value playerctl takes for the next state (none -> track ->
    /// playlist -> none, the order players show).
    pub fn next(self: Loop) Loop {
        return switch (self) {
            .none => .track,
            .track => .playlist,
            .playlist => .none,
        };
    }
    pub fn arg(self: Loop) [:0]const u8 {
        return switch (self) {
            .none => "None",
            .track => "Track",
            .playlist => "Playlist",
        };
    }
};

pub const State = struct {
    /// Which player the metadata is from (empty: no player answered).
    player: Text(128) = .{},
    status: Status = .none,
    artist: Text(160) = .{},
    title: Text(200) = .{},
    album: Text(160) = .{},
    pos_us: u64 = 0,
    len_us: u64 = 0,
    art_url: Text(500) = .{},
    shuffle: ?bool = null,
    loop: ?Loop = null,
    /// Output volume in percent (null: pactl didn't answer).
    volume: ?u8 = null,
    muted: bool = false,
    players: [MAX_PLAYERS]Text(128) = @splat(.{}),
    player_count: usize = 0,

    pub fn hasTrack(self: *const State) bool {
        return self.status != .none and (self.title.len > 0 or self.artist.len > 0);
    }

    pub fn playerList(self: *const State) []const Text(128) {
        return self.players[0..self.player_count];
    }
};

fn parseStatus(s: []const u8) Status {
    if (std.ascii.eqlIgnoreCase(s, "Playing")) return .playing;
    if (std.ascii.eqlIgnoreCase(s, "Paused")) return .paused;
    if (std.ascii.eqlIgnoreCase(s, "Stopped")) return .stopped;
    return .none;
}

fn parseU64(s: []const u8) u64 {
    const t = std.mem.trim(u8, s, " \t\r");
    // Some players report fractional microseconds ("123456.0").
    const whole = if (std.mem.indexOfScalar(u8, t, '.')) |i| t[0..i] else t;
    return std.fmt.parseInt(u64, whole, 10) catch 0;
}

/// The probe's output, line by line (missing lines keep their defaults, so a
/// machine without pactl or without players still parses).
pub fn parseState(text: []const u8) State {
    var st = State{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 2) continue;
        if (line[0] == 'M' and line[1] == US) {
            var f = std.mem.splitScalar(u8, line[2..], US);
            st.player.set(f.next() orelse "");
            st.status = parseStatus(f.next() orelse "");
            st.artist.set(f.next() orelse "");
            st.title.set(f.next() orelse "");
            st.album.set(f.next() orelse "");
            st.pos_us = parseU64(f.next() orelse "");
            st.len_us = parseU64(f.next() orelse "");
            st.art_url.set(std.mem.trim(u8, f.next() orelse "", " "));
            if (st.player.len == 0) st.status = .none;
            continue;
        }
        if (line.len < 2 or line[1] != ':') continue;
        const v = std.mem.trim(u8, line[2..], " \t");
        switch (line[0]) {
            'S' => st.shuffle = if (std.ascii.eqlIgnoreCase(v, "On")) true else if (std.ascii.eqlIgnoreCase(v, "Off")) false else null,
            'L' => st.loop = if (std.ascii.eqlIgnoreCase(v, "None")) .none else if (std.ascii.eqlIgnoreCase(v, "Track")) .track else if (std.ascii.eqlIgnoreCase(v, "Playlist")) .playlist else null,
            'V' => st.volume = volmath.firstPercent(v),
            'U' => st.muted = volmath.muteLine(v) orelse false,
            'P' => {
                var p = std.mem.splitScalar(u8, v, US);
                while (p.next()) |name_raw| {
                    const name = std.mem.trim(u8, name_raw, " \t");
                    if (name.len == 0 or st.player_count == MAX_PLAYERS) continue;
                    var dup = false;
                    for (st.players[0..st.player_count]) |*e| dup = dup or std.mem.eql(u8, e.slice(), name);
                    if (dup) continue;
                    st.players[st.player_count].set(name);
                    st.player_count += 1;
                }
            },
            else => {},
        }
    }
    return st;
}

/// A short label for a player chip: the bus name without its instance
/// suffix ("firefox.instance_1_23" -> "firefox"), first letter capitalised
/// into `buf`.
pub fn playerLabel(name: []const u8, buf: []u8) []const u8 {
    const base = if (std.mem.indexOf(u8, name, ".instance")) |i| name[0..i] else name;
    const n = @min(base.len, buf.len);
    @memcpy(buf[0..n], base[0..n]);
    if (n > 0) buf[0] = std.ascii.toUpper(buf[0]);
    return buf[0..n];
}

// --- time ------------------------------------------------------------------------

/// "m:ss", or "h:mm:ss" from an hour.
pub fn formatTime(us: u64, buf: []u8) []const u8 {
    const s = us / 1_000_000;
    if (s >= 3600) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, (s / 60) % 60, s % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
}

/// Where the track is at `now`: the probed position plus the time since,
/// while playing; clamped to the length.
pub fn positionAt(st: *const State, probed_ms: i64, now_ms: i64) u64 {
    var p = st.pos_us;
    if (st.status == .playing and now_ms > probed_ms) p += @as(u64, @intCast(now_ms - probed_ms)) * 1000;
    if (st.len_us > 0) p = @min(p, st.len_us);
    return p;
}

/// 0..1 along a track rect for pointer x.
pub fn fraction(track: Rect, x: i32) f64 {
    if (track.w <= 0) return 0;
    const f = @as(f64, @floatFromInt(x - track.x)) / @as(f64, @floatFromInt(track.w));
    return std.math.clamp(f, 0.0, 1.0);
}

/// The volume for pointer x on the slider, and the thumb x for a volume:
/// the shared slider maths (the Control Center's) on Glance's track rect.
pub fn volumeAt(track: Rect, x: i32) u8 {
    return volmath.sliderXToVal(track.x, @as(i64, track.x) + track.w, x);
}

pub fn volumeX(track: Rect, val: u8) i32 {
    return @intCast(volmath.sliderValToX(track.x, @as(i64, track.x) + track.w, val));
}

// --- layout ----------------------------------------------------------------------

pub const Control = enum { shuffle, prev, toggle, next, loop };
pub const CONTROL_COUNT: i32 = std.meta.tags(Control).len;

pub const COVER_MAX: i32 = 248;
pub const CHIP_H: i32 = 30;
pub const CHIP_PAD_X: i32 = 14;
pub const CHIP_GAP: i32 = 8;
pub const BTN: i32 = 44;
pub const BTN_GAP: i32 = 10;
pub const TRACK_H: i32 = 6;
/// Taller than the bar it covers, so the thin tracks are easy to grab.
pub const TRACK_HIT: i32 = 22;
pub const VOL_TRACK_W: i32 = 260;

pub const Layout = struct {
    cover: Rect = .{},
    /// The text column: player and state, title, artist, album.
    text: Rect = .{},
    seek: Rect = .{},
    times_y: i32 = 0,
    controls: [@intCast(CONTROL_COUNT)]Rect = @splat(.{}),
    mute: Rect = .{},
    volume: Rect = .{},
    chips: [MAX_PLAYERS]Rect = @splat(.{}),
    chip_count: usize = 0,
};

/// The tab inside Glance's content rect `c`: cover on the left, the text,
/// seek bar, controls and volume to its right, and one chip per player
/// along the bottom (`chip_w`: each label's text width; none when only one
/// player exists).
pub fn layout(c: Rect, lh: i32, chip_w: []const i32) Layout {
    var l = Layout{};
    const chips_h: i32 = CHIP_H + 14;
    const s = @max(@min(COVER_MAX, c.h - chips_h), 64);
    l.cover = .{ .x = c.x, .y = c.y, .w = s, .h = s };
    const rx = c.x + s + 28;
    const rw = @max(c.x + c.w - rx, 120);
    // Four lines: the player and its state, title, artist, album.
    l.text = .{ .x = rx, .y = c.y + 4, .w = rw, .h = 4 * lh + 14 };

    l.seek = .{ .x = rx, .y = l.text.y + l.text.h + 22, .w = rw, .h = TRACK_H };
    l.times_y = l.seek.y + TRACK_H + 8 + lh; // baseline-ish: bottom of the time row

    const row_w = CONTROL_COUNT * BTN + (CONTROL_COUNT - 1) * BTN_GAP;
    const bx0 = rx + @divTrunc(rw - row_w, 2);
    const by = l.times_y + 14;
    for (0..@intCast(CONTROL_COUNT)) |i| {
        l.controls[i] = .{ .x = bx0 + @as(i32, @intCast(i)) * (BTN + BTN_GAP), .y = by, .w = BTN, .h = BTN };
    }

    const vy = by + BTN + 22;
    l.mute = .{ .x = rx, .y = vy, .w = 32, .h = 32 };
    l.volume = .{ .x = rx + 44, .y = vy + 13, .w = @min(VOL_TRACK_W, @max(rw - 110, 60)), .h = TRACK_H };

    if (chip_w.len > 1) {
        var x = c.x;
        const y = c.y + c.h - CHIP_H;
        for (chip_w, 0..) |w, i| {
            if (i == MAX_PLAYERS) break;
            const cw = w + 2 * CHIP_PAD_X;
            if (x + cw > c.x + c.w) break;
            l.chips[i] = .{ .x = x, .y = y, .w = cw, .h = CHIP_H };
            l.chip_count = i + 1;
            x += cw + CHIP_GAP;
        }
    }
    return l;
}

fn grow(r: Rect, hit_h: i32) Rect {
    return .{ .x = r.x - 4, .y = r.y + @divTrunc(r.h - hit_h, 2), .w = r.w + 8, .h = hit_h };
}

pub const Hit = union(enum) {
    none,
    control: Control,
    seek,
    volume,
    mute,
    player: usize,

    pub fn eql(a: Hit, b: Hit) bool {
        return switch (a) {
            .none => b == .none,
            .seek => b == .seek,
            .volume => b == .volume,
            .mute => b == .mute,
            .control => |c| b == .control and b.control == c,
            .player => |p| b == .player and b.player == p,
        };
    }
};

/// What sits under panel-local point (x, y). Seek and transport only count
/// with a track to act on; volume and players always do.
pub fn hitTest(l: *const Layout, has_track: bool, x: i32, y: i32) Hit {
    if (has_track) {
        for (l.controls, 0..) |r, i| {
            if (r.contains(x, y)) return .{ .control = @fromBackingInt(@intCast(i)) };
        }
        if (grow(l.seek, TRACK_HIT).contains(x, y)) return .seek;
    }
    if (l.mute.contains(x, y)) return .mute;
    if (grow(l.volume, TRACK_HIT).contains(x, y)) return .volume;
    for (l.chips[0..l.chip_count], 0..) |r, i| {
        if (r.contains(x, y)) return .{ .player = i };
    }
    return .none;
}

// --- dragging ----------------------------------------------------------------------

/// A press on the seek or volume track starts a drag; motion moves the
/// preview; the release commits (wherever the pointer is: the surface
/// keeps the pointer grab while the button is held). A press elsewhere is
/// an ordinary click.
pub const Drag = struct {
    kind: enum { none, seek, volume } = .none,
    /// Seek: 0..1 along the track.
    frac: f64 = 0,
    /// Volume: 0..100 through the shared slider maths.
    val: u8 = 0,

    pub const Commit = union(enum) { none, seek: f64, volume: u8 };

    pub fn active(self: *const Drag) bool {
        return self.kind != .none;
    }

    pub fn press(self: *Drag, l: *const Layout, hit: Hit, x: i32) bool {
        switch (hit) {
            .seek => self.* = .{ .kind = .seek, .frac = fraction(l.seek, x) },
            .volume => self.* = .{ .kind = .volume, .val = volumeAt(l.volume, x) },
            else => return false,
        }
        return true;
    }

    /// True when the preview moved.
    pub fn motion(self: *Drag, l: *const Layout, x: i32) bool {
        switch (self.kind) {
            .none => return false,
            .seek => {
                const f = fraction(l.seek, x);
                if (f == self.frac) return false;
                self.frac = f;
            },
            .volume => {
                const v = volumeAt(l.volume, x);
                if (v == self.val) return false;
                self.val = v;
            },
        }
        return true;
    }

    pub fn release(self: *Drag) Commit {
        defer self.* = .{};
        return switch (self.kind) {
            .none => .none,
            .seek => .{ .seek = self.frac },
            .volume => .{ .volume = self.val },
        };
    }

    /// Glance closed or lost the pointer mid-drag: forget it, commit nothing.
    pub fn cancel(self: *Drag) void {
        self.* = .{};
    }
};

/// A value the user just set, shown instead of the probe's until the
/// player or pactl has had time to catch up (no jump back to the old value).
pub fn Held(comptime T: type) type {
    return struct {
        value: T = undefined,
        until_ms: i64 = 0,

        const Self = @This();
        pub const HOLD_MS: i64 = 1500;
        pub fn set(self: *Self, v: T, now_ms: i64) void {
            self.value = v;
            self.until_ms = now_ms + HOLD_MS;
        }
        pub fn get(self: *const Self, probed: T, now_ms: i64) T {
            return if (now_ms < self.until_ms) self.value else probed;
        }
    };
}

// --- actions as argv -----------------------------------------------------------------

/// Run through /usr/bin/env, so PATH finds the program and no shell ever
/// sees an argument.
pub const ENV: [:0]const u8 = "/usr/bin/env";
pub const MAX_ARGV = 8;

pub const Argv = struct {
    items: [MAX_ARGV + 1]?[*:0]const u8 = @splat(null),
    len: usize = 0,
    /// Owns the one formatted argument (a position or a percentage).
    num: [32]u8 = @splat(0),

    fn add(self: *Argv, s: [*:0]const u8) void {
        self.items[self.len] = s;
        self.len += 1;
    }

    /// The NUL-terminated array execve wants.
    pub fn ptr(self: *const Argv) [*:null]const ?[*:0]const u8 {
        return @ptrCast(&self.items);
    }

    pub fn arg(self: *const Argv, i: usize) []const u8 {
        return std.mem.span(self.items[i].?);
    }
};

fn playerctl(a: *Argv, player: [:0]const u8) void {
    a.add("env");
    a.add("playerctl");
    if (player.len > 0) {
        a.add("-p");
        a.add(player.ptr);
    }
}

/// The transport buttons. `loop` is the state being left (the command
/// moves to the next one). `player` must stay alive while the argv is used.
pub fn controlArgv(out: *Argv, c: Control, player: [:0]const u8, loop: Loop) void {
    out.* = .{};
    playerctl(out, player);
    switch (c) {
        .toggle => out.add("play-pause"),
        .prev => out.add("previous"),
        .next => out.add("next"),
        .shuffle => {
            out.add("shuffle");
            out.add("Toggle");
        },
        .loop => {
            out.add("loop");
            out.add(loop.next().arg().ptr);
        },
    }
}

/// Absolute seek to `frac` of the track (playerctl position takes seconds).
pub fn seekArgv(out: *Argv, player: [:0]const u8, len_us: u64, frac: f64) void {
    out.* = .{};
    playerctl(out, player);
    out.add("position");
    const secs = @as(f64, @floatFromInt(len_us)) * std.math.clamp(frac, 0.0, 1.0) / 1_000_000.0;
    const s = std.fmt.bufPrintSentinel(&out.num, "{d:.3}", .{secs}, 0) catch "0";
    out.add(s.ptr);
}

pub fn volumeArgv(out: *Argv, pct: u8) void {
    out.* = .{};
    out.add("env");
    out.add("pactl");
    out.add("set-sink-volume");
    out.add("@DEFAULT_SINK@");
    const s = std.fmt.bufPrintSentinel(&out.num, "{d}%", .{@min(pct, 100)}, 0) catch "0%";
    out.add(s.ptr);
}

pub fn muteArgv(out: *Argv) void {
    out.* = .{};
    out.add("env");
    out.add("pactl");
    out.add("set-sink-mute");
    out.add("@DEFAULT_SINK@");
    out.add("toggle");
}

// --- cadence ---------------------------------------------------------------------

/// How often the probe runs while the Media tab is on screen.
pub const PROBE_MS: i64 = 2000;
/// A moment after an action, so the result shows up fast.
pub const AFTER_ACTION_MS: i64 = 250;

// --- tests ---------------------------------------------------------------------------

const tt = std.testing;

const SAMPLE =
    "M\x1fspotify.instance_7\x1fPlaying\x1fBoards of Canada\x1fRoygbiv\x1fMusic Has the Right\x1f61234567\x1f151000000\x1fhttps://i.scdn.co/image/ab67\n" ++
    "S:Off\n" ++
    "L:Playlist\n" ++
    "V:Volume: front-left: 26214 /  40% / -23.88 dB,   front-right: 26214 /  40% / -23.88 dB\n" ++
    "U:Mute: no\n" ++
    "P:spotify.instance_7\x1ffirefox.instance_1_23\x1fmpv\x1fspotify.instance_7\x1f\n";

test "parseState: a full probe" {
    const st = parseState(SAMPLE);
    try tt.expectEqualStrings("spotify.instance_7", st.player.slice());
    try tt.expectEqual(Status.playing, st.status);
    try tt.expectEqualStrings("Boards of Canada", st.artist.slice());
    try tt.expectEqualStrings("Roygbiv", st.title.slice());
    try tt.expectEqualStrings("Music Has the Right", st.album.slice());
    try tt.expectEqual(@as(u64, 61234567), st.pos_us);
    try tt.expectEqual(@as(u64, 151000000), st.len_us);
    try tt.expectEqualStrings("https://i.scdn.co/image/ab67", st.art_url.slice());
    try tt.expectEqual(@as(?bool, false), st.shuffle);
    try tt.expectEqual(@as(?Loop, .playlist), st.loop);
    try tt.expectEqual(@as(?u8, 40), st.volume);
    try tt.expect(!st.muted);
    // Duplicates and the empty tail dropped, order kept.
    try tt.expectEqual(@as(usize, 3), st.player_count);
    try tt.expectEqualStrings("firefox.instance_1_23", st.players[1].slice());
    try tt.expect(st.hasTrack());
}

test "parseState: no players, no pactl" {
    const st = parseState("M\x1f\nS:\nL:\nV:\nU:\nP:\n");
    try tt.expect(!st.hasTrack());
    try tt.expectEqual(Status.none, st.status);
    try tt.expect(st.volume == null);
    try tt.expect(st.shuffle == null and st.loop == null);
    try tt.expectEqual(@as(usize, 0), st.player_count);
    try tt.expect(!parseState("").hasTrack());
}

test "parseState: muted, fractional position, a stream without length or art" {
    const st = parseState("M\x1fmpv\x1fPaused\x1f\x1fLive radio\x1f\x1f5000000.0\x1f\x1f\nU:Mute: yes\n");
    try tt.expectEqual(Status.paused, st.status);
    try tt.expectEqual(@as(u64, 5000000), st.pos_us);
    try tt.expectEqual(@as(u64, 0), st.len_us);
    try tt.expectEqual(@as(usize, 0), st.art_url.len);
    try tt.expect(st.muted);
    try tt.expect(st.hasTrack());
}

test "volume: the shared maths on Glance's track (same values as the Control Center)" {
    const track = Rect{ .x = 300, .y = 0, .w = 260, .h = 6 };
    var x: i32 = track.x - 20;
    while (x <= track.x + track.w + 20) : (x += 7) {
        try tt.expectEqual(volmath.sliderXToVal(track.x, track.x + track.w, x), volumeAt(track, x));
    }
    var v: u8 = 0;
    // Truncating maths (as in the Control Center): on a 260 px track the
    // thumb for v reads back as v, or v - 1 where 2.6 * v isn't whole.
    while (v <= 100) : (v += 1) {
        const back = volumeAt(track, volumeX(track, v));
        try tt.expect(back == v or back + 1 == v);
    }
    // The probe's pactl lines go through the shared parser too.
    const st = parseState("V:Volume: front-left: 88474 / 135% / 7.82 dB\nU:Mute: yes\n");
    try tt.expectEqual(@as(?u8, 135), st.volume);
    try tt.expect(st.muted);
}

test "Text.set cuts on a UTF-8 boundary" {
    var t: Text(4) = .{};
    t.set("ab\u{e9}\u{e9}"); // a b é(2 bytes) é(2 bytes): 6 bytes, room for 4
    try tt.expectEqualStrings("ab\u{e9}", t.slice());
    try tt.expectEqual(@as(u8, 0), t.z()[t.len]);
}

test "playerLabel" {
    var b: [32]u8 = undefined;
    try tt.expectEqualStrings("Firefox", playerLabel("firefox.instance_1_23", &b));
    try tt.expectEqualStrings("Mpv", playerLabel("mpv", &b));
    try tt.expectEqualStrings("", playerLabel("", &b));
}

test "formatTime and positionAt" {
    var b: [16]u8 = undefined;
    try tt.expectEqualStrings("0:00", formatTime(0, &b));
    try tt.expectEqualStrings("2:31", formatTime(151_000_000, &b));
    try tt.expectEqualStrings("1:02:03", formatTime(3723_000_000, &b));
    var st = parseState(SAMPLE);
    try tt.expectEqual(@as(u64, 61234567 + 2_000_000), positionAt(&st, 1000, 3000));
    try tt.expectEqual(st.len_us, positionAt(&st, 0, 1_000_000_000)); // clamped
    st.status = .paused;
    try tt.expectEqual(st.pos_us, positionAt(&st, 1000, 3000)); // paused: still
}

const CONTENT = Rect{ .x = 20, .y = 70, .w = 890, .h = 439 };

fn inside(o: Rect, r: Rect) bool {
    return r.x >= o.x and r.y >= o.y and r.x + r.w <= o.x + o.w and r.y + r.h <= o.y + o.h;
}

test "layout: everything inside the content, chips only with two players or more" {
    const l = layout(CONTENT, 17, &.{ 50, 60, 30 });
    try tt.expectEqual(COVER_MAX, l.cover.w);
    try tt.expect(inside(CONTENT, l.cover));
    try tt.expect(inside(CONTENT, l.seek));
    try tt.expect(inside(CONTENT, l.volume));
    for (l.controls) |r| try tt.expect(inside(CONTENT, r));
    try tt.expectEqual(@as(usize, 3), l.chip_count);
    for (l.chips[0..3]) |r| try tt.expect(inside(CONTENT, r));
    try tt.expect(l.seek.x >= l.cover.x + l.cover.w);
    // Controls below the seek bar, volume below the controls, chips at the bottom.
    try tt.expect(l.controls[0].y > l.seek.y);
    try tt.expect(l.volume.y > l.controls[0].y + l.controls[0].h);
    try tt.expect(l.chips[0].y >= l.volume.y);
    try tt.expectEqual(@as(usize, 0), layout(CONTENT, 17, &.{50}).chip_count);
}

test "layout: chips that don't fit are left out" {
    const narrow = Rect{ .x = 0, .y = 0, .w = 200, .h = 300 };
    const l = layout(narrow, 17, &.{ 80, 80, 80 });
    try tt.expectEqual(@as(usize, 1), l.chip_count);
}

test "hitTest: controls and seek need a track; volume, mute and chips don't" {
    const l = layout(CONTENT, 17, &.{ 50, 60 });
    const ctl = l.controls[2];
    try tt.expect(hitTest(&l, true, ctl.x + 3, ctl.y + 3).eql(.{ .control = .toggle }));
    try tt.expect(hitTest(&l, false, ctl.x + 3, ctl.y + 3) == .none);
    // The seek bar is 6 px tall but grabbable a few px above and below.
    try tt.expect(hitTest(&l, true, l.seek.x + 10, l.seek.y - 6) == .seek);
    try tt.expect(hitTest(&l, false, l.seek.x + 10, l.seek.y) == .none);
    try tt.expect(hitTest(&l, false, l.volume.x + 5, l.volume.y + 2) == .volume);
    try tt.expect(hitTest(&l, false, l.mute.x + 2, l.mute.y + 2) == .mute);
    try tt.expect(hitTest(&l, false, l.chips[1].x + 2, l.chips[1].y + 2).eql(.{ .player = 1 }));
    try tt.expect(hitTest(&l, true, l.cover.x + 5, l.cover.y + 5) == .none);
}

test "drag: press, motion, release commits; clicks elsewhere don't drag" {
    const l = layout(CONTENT, 17, &.{});
    var d = Drag{};
    try tt.expect(!d.press(&l, .mute, 0));
    try tt.expect(!d.active());
    try tt.expect(d.press(&l, .seek, l.seek.x));
    try tt.expect(d.active());
    try tt.expect(d.motion(&l, l.seek.x + @divTrunc(l.seek.w, 2)));
    try tt.expect(!d.motion(&l, l.seek.x + @divTrunc(l.seek.w, 2))); // same spot: no repaint
    // Dragged past the end (release off the track still commits, clamped).
    _ = d.motion(&l, l.seek.x + l.seek.w + 500);
    try tt.expectEqual(Drag.Commit{ .seek = 1.0 }, d.release());
    try tt.expect(!d.active());
    try tt.expectEqual(Drag.Commit.none, d.release());

    try tt.expect(d.press(&l, .volume, l.volume.x));
    _ = d.motion(&l, l.volume.x + @divTrunc(l.volume.w * 45, 100));
    const c = d.release();
    try tt.expect(c == .volume and c.volume >= 44 and c.volume <= 46);

    _ = d.press(&l, .volume, l.volume.x);
    d.cancel();
    try tt.expectEqual(Drag.Commit.none, d.release());
}

test "Held: shows the set value, then the probe again" {
    var h: Held(u8) = .{};
    try tt.expectEqual(@as(u8, 40), h.get(40, 0));
    h.set(70, 1000);
    try tt.expectEqual(@as(u8, 70), h.get(40, 1000 + Held(u8).HOLD_MS - 1));
    try tt.expectEqual(@as(u8, 40), h.get(40, 1000 + Held(u8).HOLD_MS));
}

test "argv: player names stay one argument, never shell text" {
    var a: Argv = .{};
    const evil: [:0]const u8 = "x; rm -rf ~ $(id) 'q\"";
    controlArgv(&a, .toggle, evil, .none);
    try tt.expectEqual(@as(usize, 5), a.len);
    try tt.expectEqualStrings("env", a.arg(0));
    try tt.expectEqualStrings("playerctl", a.arg(1));
    try tt.expectEqualStrings("-p", a.arg(2));
    try tt.expectEqualStrings(evil, a.arg(3));
    try tt.expectEqualStrings("play-pause", a.arg(4));
    try tt.expect(a.items[a.len] == null); // NUL-terminated for execve

    controlArgv(&a, .loop, "", .track);
    try tt.expectEqual(@as(usize, 4), a.len); // no -p for the default player
    try tt.expectEqualStrings("loop", a.arg(2));
    try tt.expectEqualStrings("Playlist", a.arg(3));

    controlArgv(&a, .shuffle, "mpv", .none);
    try tt.expectEqualStrings("Toggle", a.arg(5));

    seekArgv(&a, "mpv", 151_000_000, 0.5);
    try tt.expectEqualStrings("position", a.arg(4));
    try tt.expectEqualStrings("75.500", a.arg(5));

    volumeArgv(&a, 130);
    try tt.expectEqualStrings("pactl", a.arg(1));
    try tt.expectEqualStrings("100%", a.arg(4)); // the slider tops out at 100
    muteArgv(&a);
    try tt.expectEqualStrings("toggle", a.arg(4));
}

test "probe: the player is read from $1, never formatted into the script" {
    try tt.expect(std.mem.indexOf(u8, PROBE, "\"$1\"") != null);
    try tt.expect(std.mem.indexOf(u8, PROBE, "{s}") == null);
    // Every playerctl call that targets a player goes through "$@".
    var it = std.mem.splitSequence(u8, PROBE, "playerctl ");
    _ = it.next();
    while (it.next()) |rest| {
        try tt.expect(std.mem.startsWith(u8, rest, "\"$@\"") or std.mem.startsWith(u8, rest, "-l"));
    }
}
