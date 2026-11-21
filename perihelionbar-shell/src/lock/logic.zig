//! perihelion-lockscreen: everything that can be decided without a display,
//! a font, PAM or libc. The program (main.zig) feeds it events and reads back
//! what to draw and do; the tests here run on any machine.
//!
//!   * Session: locking -> locked -> unlocking, the pending PAM attempt, the
//!     wrong-password and caps-lock state, and which hint the screen shows.
//!   * Password: the typed secret in a fixed buffer, wiped with secureZero.
//!   * Text: the clock (12/24-hour, AM/PM split off), the long date
//!     ("Monday, November 9"), the avatar initial.
//!   * Layout: where each part of the screen sits for a given output size.
//!   * Settings: shell.json's clock_24h, the wallpaper files, the theme
//!     colours from matugen.json.
//!   * Readiness: when `-f` may let its parent go (locked, and a frame shown
//!     on every output or the 2 s cap passed).
//!
//! Nothing here logs. The password never leaves Password and the worker.

const std = @import("std");

// --- auth results --------------------------------------------------------

pub const AuthResult = enum {
    ok,
    denied,
    unavailable,

    /// One byte down the worker's pipe.
    pub fn byte(self: AuthResult) u8 {
        return switch (self) {
            .ok => '1',
            .denied => '0',
            .unavailable => '2',
        };
    }

    /// Anything unexpected (a short read, garbage) counts as unavailable,
    /// never as success.
    pub fn fromByte(v: u8) AuthResult {
        return switch (v) {
            '1' => .ok,
            '0' => .denied,
            else => .unavailable,
        };
    }
};

// --- password ------------------------------------------------------------

pub const PASSWORD_MAX = 255;

/// The typed password. Fixed size so main.zig can mlock it once; every way
/// out of it (clear, backspace, deinit) zeroes with secureZero, which the
/// optimiser may not drop.
pub const Password = struct {
    buf: [PASSWORD_MAX + 1]u8 = @as([PASSWORD_MAX + 1]u8, @splat(0)),
    len: usize = 0,

    pub fn bytes(self: *const Password) []const u8 {
        return self.buf[0..self.len];
    }

    /// Appends UTF-8 text. Text that would overflow the buffer is dropped
    /// whole, so a multi-byte character is never cut in half.
    pub fn append(self: *Password, text: []const u8) bool {
        if (text.len == 0 or self.len + text.len > PASSWORD_MAX) return false;
        @memcpy(self.buf[self.len..][0..text.len], text);
        self.len += text.len;
        return true;
    }

    /// Removes the last UTF-8 character.
    pub fn backspace(self: *Password) bool {
        if (self.len == 0) return false;
        var n = self.len - 1;
        while (n > 0 and (self.buf[n] & 0xC0) == 0x80) n -= 1;
        std.crypto.secureZero(u8, self.buf[n..self.len]);
        self.len = n;
        return true;
    }

    pub fn clear(self: *Password) void {
        std.crypto.secureZero(u8, &self.buf);
        self.len = 0;
    }

    /// Characters, not bytes: what the dots in the field count.
    pub fn chars(self: *const Password) usize {
        return std.unicode.utf8CountCodepoints(self.bytes()) catch self.len;
    }
};

// --- session -------------------------------------------------------------

pub const Phase = enum { locking, locked, unlocking };

/// What the line under the field says (and which colour the field takes).
pub const Hint = enum {
    idle,
    caps_lock,
    checking,
    wrong,
    unavailable,

    pub fn text(self: Hint) []const u8 {
        return switch (self) {
            .idle => "Press Enter to unlock",
            .caps_lock => "Caps Lock is on",
            .checking => "Checking\u{2026}",
            .wrong => "Incorrect password",
            .unavailable => "Authentication is unavailable",
        };
    }
};

pub const Key = union(enum) {
    enter,
    backspace,
    escape,
    /// UTF-8 the keymap produced. Ignored while Ctrl, Alt or Super is held.
    text: []const u8,
    other,
};

pub const KeyAction = enum { none, repaint, submit };

pub const Session = struct {
    phase: Phase = .locking,
    auth_pending: bool = false,
    caps_lock: bool = false,
    /// The last attempt's outcome, shown until the next keystroke.
    last: ?AuthResult = null,
    failures: u32 = 0,
    /// Dots kept on screen while PAM checks: the password itself is wiped
    /// the moment the worker has its copy.
    pending_chars: usize = 0,

    /// The compositor sent `locked`.
    pub fn lockShown(self: *Session) void {
        if (self.phase == .locking) self.phase = .locked;
    }

    pub fn acceptsInput(self: *const Session) bool {
        return self.phase == .locked and !self.auth_pending;
    }

    /// A key press. Text goes into `pw`; Enter asks main.zig to submit.
    pub fn onKey(self: *Session, pw: *Password, key: Key, modifier_held: bool) KeyAction {
        if (!self.acceptsInput()) return .none;
        switch (key) {
            .enter => return .submit,
            .backspace => {
                const changed = pw.backspace();
                const had_msg = self.dismiss();
                return if (changed or had_msg) .repaint else .none;
            },
            .escape => {
                const had = pw.len > 0;
                pw.clear();
                const had_msg = self.dismiss();
                return if (had or had_msg) .repaint else .none;
            },
            .text => |t| {
                if (modifier_held or t.len == 0) return .none;
                // Control characters (Tab, Delete, ...) are not password text.
                if (t.len == 1 and (t[0] < 0x20 or t[0] == 0x7f)) return .none;
                _ = self.dismiss();
                return if (pw.append(t)) .repaint else .none;
            },
            .other => return .none,
        }
    }

    /// Clears the last attempt's message. True when there was one.
    fn dismiss(self: *Session) bool {
        const had = self.last != null;
        self.last = null;
        return had;
    }

    /// Enter: hands the password to `worker` (anything with
    /// `start(service, user, password) bool`) and wipes the local copy
    /// whether or not the worker started. Returns true when an attempt is
    /// now pending (main.zig then watches the worker's fd).
    pub fn submit(self: *Session, pw: *Password, worker: anytype, service: []const u8, user: []const u8) bool {
        if (!self.acceptsInput()) return false;
        const shown = pw.chars();
        const started = worker.start(service, user, pw.bytes());
        pw.clear();
        if (!started) {
            self.last = .unavailable;
            self.failures += 1;
            return false;
        }
        self.pending_chars = shown;
        self.auth_pending = true;
        self.last = null;
        return true;
    }

    /// The worker finished. True means unlock now.
    pub fn finish(self: *Session, pw: *Password, result: AuthResult) bool {
        pw.clear();
        self.auth_pending = false;
        self.pending_chars = 0;
        switch (result) {
            .ok => {
                if (self.phase != .locked) return false;
                self.phase = .unlocking;
                self.failures = 0;
                self.last = null;
                return true;
            },
            .denied, .unavailable => {
                self.failures += 1;
                self.last = result;
                return false;
            },
        }
    }

    /// Priority: checking, then the last failure, then caps lock.
    pub fn hint(self: *const Session) Hint {
        if (self.auth_pending) return .checking;
        if (self.last) |r| switch (r) {
            .denied => return .wrong,
            .unavailable => return .unavailable,
            .ok => {},
        };
        if (self.caps_lock) return .caps_lock;
        return .idle;
    }

    /// Dots to draw in the field.
    pub fn dots(self: *const Session, pw: *const Password) usize {
        return if (self.auth_pending) self.pending_chars else pw.chars();
    }
};

/// Caps Lock from wl_keyboard.modifiers: the locked mask and the keymap's
/// index for the "Lock" modifier (null when the keymap has none).
pub fn capsLocked(mods_locked: u32, lock_index: ?u32) bool {
    const i = lock_index orelse return false;
    if (i >= 32) return false;
    return (mods_locked >> @intCast(i)) & 1 == 1;
}

// --- clock and date --------------------------------------------------------

pub const ClockText = struct {
    /// "2:05" or "14:05"
    main: []const u8,
    /// "AM", "PM", or empty in 24-hour mode
    suffix: []const u8,
};

/// The clock. 12-hour: "2:05 PM" split into "2:05" and "PM" (no leading
/// zero, 12 for noon and midnight). 24-hour: "14:05" and no suffix.
pub fn formatClock(buf: []u8, hour: u8, minute: u8, h24: bool) ClockText {
    const h = hour % 24;
    const m = minute % 60;
    if (h24) {
        const s = std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ h, m }) catch "";
        return .{ .main = s, .suffix = "" };
    }
    const h12: u8 = if (h % 12 == 0) 12 else h % 12;
    const s = std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ h12, m }) catch "";
    return .{ .main = s, .suffix = if (h < 12) "AM" else "PM" };
}

const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

/// 0 = Sunday. Sakamoto's method, proleptic Gregorian.
pub fn weekday(year: i32, month: u8, day: u8) u8 {
    const t = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    if (month < 1 or month > 12) return 0;
    var y = year;
    if (month < 3) y -= 1;
    const v = y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + t[month - 1] + @as(i32, day);
    return @intCast(@mod(v, 7));
}

/// "Monday, November 9": the year is left out, a lock screen is about now.
pub fn formatDate(buf: []u8, year: i32, month: u8, day: u8) []const u8 {
    if (month < 1 or month > 12 or day < 1 or day > 31) return "";
    const wd = weekday(year, month, day);
    return std.fmt.bufPrint(buf, "{s}, {s} {d}", .{ day_names[wd], month_names[month - 1], day }) catch "";
}

/// The circle's letter when there is no account photo: the first character,
/// upper-cased when it is ASCII.
pub fn avatarInitial(user: []const u8, buf: *[4]u8) []const u8 {
    if (user.len == 0) return "";
    const n: usize = std.unicode.utf8ByteSequenceLength(user[0]) catch 1;
    if (n > user.len) return "";
    if (n == 1) {
        buf[0] = std.ascii.toUpper(user[0]);
        return buf[0..1];
    }
    @memcpy(buf[0..n], user[0..n]);
    return buf[0..n];
}

// --- layout ----------------------------------------------------------------

/// Positions in buffer pixels, all derived from the output's height so the
/// screen keeps its proportions from a laptop panel to a 4K monitor.
pub const Layout = struct {
    w: f64,
    h: f64,
    date_top: f64,
    date_size: f64,
    clock_top: f64,
    clock_size: f64,
    avatar_cx: f64,
    avatar_cy: f64,
    avatar_d: f64,
    user_top: f64,
    user_size: f64,
    field_x: f64,
    field_y: f64,
    field_w: f64,
    field_h: f64,
    hint_top: f64,
    hint_size: f64,

    /// Font size for the user line, needed before its height is measured.
    pub fn userSize(h: f64) f64 {
        return @max(h * 0.025, 12.0);
    }

    /// `user_line_h` is the measured height of the username line.
    pub fn compute(w: f64, h: f64, user_line_h: f64) Layout {
        const gap = h * 0.016;
        var y = h * 0.58;
        const avatar_d = @max(h * 0.086, 44.0);
        const avatar_cy = y + avatar_d / 2.0;
        y += avatar_d + gap - h * 0.002;
        const user_top = y;
        y += user_line_h + gap;
        const field_w = @max(150.0, @min(240.0, w * 0.19));
        const field_h = @max(28.0, @min(38.0, h * 0.044));
        const field_y = y;
        y = field_y + field_h + gap;
        return .{
            .w = w,
            .h = h,
            .date_top = h * 0.12,
            .date_size = @max(h * 0.025, 11.0),
            .clock_top = h * 0.16,
            .clock_size = @max(h * 0.17, 44.0),
            .avatar_cx = w / 2.0,
            .avatar_cy = avatar_cy,
            .avatar_d = avatar_d,
            .user_top = user_top,
            .user_size = userSize(h),
            .field_x = (w - field_w) / 2.0,
            .field_y = field_y,
            .field_w = field_w,
            .field_h = field_h,
            .hint_top = y,
            .hint_size = @max(h * 0.019, 10.5),
        };
    }

    /// How many dots fit in the field before they stop growing.
    pub fn maxDots(self: *const Layout) usize {
        const dot_d = @max(self.field_h * 0.22, 6.0);
        return @intFromFloat(@max(1.0, (self.field_w - 16.0) / (dot_d * 2.0)));
    }

    /// Where the date, the username and the hint sit (buffer pixels), a
    /// little wider and taller than the text itself: what Legibility.measure
    /// samples.
    pub fn textBands(self: *const Layout) [3]Band {
        return .{
            .{ .x0 = self.w * 0.30, .x1 = self.w * 0.70, .y0 = self.date_top, .y1 = self.date_top + self.date_size * 1.6 },
            .{ .x0 = self.w * 0.38, .x1 = self.w * 0.62, .y0 = self.user_top, .y1 = self.user_top + self.user_size * 1.6 },
            .{ .x0 = self.w * 0.34, .x1 = self.w * 0.66, .y0 = self.hint_top, .y1 = self.hint_top + self.hint_size * 1.7 },
        };
    }
};

// --- readability on bright wallpapers --------------------------------------

/// A rectangle in buffer pixels.
pub const Band = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// Mean brightness (0..1, Rec. 709 weights on the stored values) of the
/// opaque ARGB32 pixels inside `band`, sampled on a grid of at most about
/// 48x16 points: enough to judge a text band, cheap enough to run once per
/// output size. 0 for an empty band.
pub fn bandLuma(px: []const u32, w: usize, h: usize, band: Band) f64 {
    if (w == 0 or h == 0 or px.len < w * h) return 0;
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    const x0: usize = @intFromFloat(std.math.clamp(@floor(band.x0), 0, fw));
    const x1: usize = @intFromFloat(std.math.clamp(@ceil(band.x1), 0, fw));
    const y0: usize = @intFromFloat(std.math.clamp(@floor(band.y0), 0, fh));
    const y1: usize = @intFromFloat(std.math.clamp(@ceil(band.y1), 0, fh));
    if (x1 <= x0 or y1 <= y0) return 0;
    const sx = @max(1, (x1 - x0) / 48);
    const sy = @max(1, (y1 - y0) / 16);
    var sum: f64 = 0;
    var n: usize = 0;
    var y = y0;
    while (y < y1) : (y += sy) {
        var x = x0;
        while (x < x1) : (x += sx) {
            const p = px[y * w + x];
            const r: f64 = @floatFromInt((p >> 16) & 0xff);
            const g: f64 = @floatFromInt((p >> 8) & 0xff);
            const b: f64 = @floatFromInt(p & 0xff);
            sum += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
            n += 1;
        }
    }
    return if (n == 0) 0 else sum / @as(f64, @floatFromInt(n));
}

/// Below this mean brightness the white text already reads well: nothing
/// is added, the screen stays exactly as designed.
pub const BRIGHT_LUMA: f64 = 0.50;
/// Strongest darkening, reached at FULL_LUMA and above (a white sky).
pub const MAX_SCRIM: f64 = 0.34;
pub const MIN_SCRIM: f64 = 0.14;
pub const FULL_LUMA: f64 = 0.85;

/// How dark the soft patch behind one line of text is: 0 unless the
/// wallpaper behind it is bright, then rising with the brightness.
pub fn scrimAlpha(luma: f64) f64 {
    if (!(luma >= BRIGHT_LUMA)) return 0; // also catches NaN
    const t = std.math.clamp((luma - BRIGHT_LUMA) / (FULL_LUMA - BRIGHT_LUMA), 0, 1);
    return MIN_SCRIM + (MAX_SCRIM - MIN_SCRIM) * t;
}

/// The darkening for the three text lines of one output.
pub const Legibility = struct {
    date: f64 = 0,
    user: f64 = 0,
    hint: f64 = 0,

    /// From the finished backdrop (wallpaper + tint + fades), so it judges
    /// what is really behind the text.
    pub fn measure(px: []const u32, w: usize, h: usize, l: *const Layout) Legibility {
        const b = l.textBands();
        return .{
            .date = scrimAlpha(bandLuma(px, w, h, b[0])),
            .user = scrimAlpha(bandLuma(px, w, h, b[1])),
            .hint = scrimAlpha(bandLuma(px, w, h, b[2])),
        };
    }
};

// --- settings files --------------------------------------------------------

/// ~/.config/perihelion/wallpaper: "image <path>" (or "color #rrggbb",
/// which means no picture).
pub fn wallpaperFromPerihelion(text: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, line, "image ")) {
        const v = std.mem.trim(u8, line[6..], " \t");
        return if (v.len > 0) v else null;
    }
    return null;
}

/// True when ~/.config/perihelion/wallpaper picks a plain colour, so the
/// older file must not be consulted.
pub fn wallpaperIsColor(text: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trim(u8, text, " \t\r\n"), "color ");
}

/// ~/.config/perihelionbar/wallpaper: a "path=<path>" line.
pub fn wallpaperFromBar(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "path=") and line.len > 5) return line[5..];
    }
    return null;
}

/// shell.json's clock_24h (Settings -> "24-hour clock"). Missing file, key
/// or malformed JSON keep Settings' default: 24-hour.
pub fn clock24h(gpa: std.mem.Allocator, json: []const u8) bool {
    const Shape = struct { clock_24h: ?bool = null };
    const parsed = std.json.parseFromSlice(Shape, gpa, json, .{ .ignore_unknown_fields = true }) catch return true;
    defer parsed.deinit();
    return parsed.value.clock_24h orelse true;
}

/// The theme colours, 0xRRGGBB. Defaults match the swaylock-era fallback.
pub const Palette = struct {
    /// The plate shown when the wallpaper cannot be read (bg_color).
    bg: u32 = 0x24273a,
    /// "Checking" ring and button (border_color, the theme accent).
    accent: u32 = 0x8cafff,
    /// Wrong password (holiday_color, the theme's red).
    danger: u32 = 0xff6969,
};

pub fn parseHex(s: []const u8) ?u32 {
    const t = std.mem.trim(u8, s, " \t");
    const hex = if (t.len > 0 and t[0] == '#') t[1..] else t;
    if (hex.len != 6 and hex.len != 8) return null;
    const v = std.fmt.parseInt(u32, hex[0..6], 16) catch return null;
    return v;
}

/// Reads ~/.config/perihelionbar/matugen.json, written by perihelion-theme.
pub fn palette(gpa: std.mem.Allocator, json: []const u8) Palette {
    const Shape = struct {
        bg_color: ?[]const u8 = null,
        border_color: ?[]const u8 = null,
        holiday_color: ?[]const u8 = null,
    };
    var p = Palette{};
    const parsed = std.json.parseFromSlice(Shape, gpa, json, .{ .ignore_unknown_fields = true }) catch return p;
    defer parsed.deinit();
    if (parsed.value.bg_color) |v| p.bg = parseHex(v) orelse p.bg;
    if (parsed.value.border_color) |v| p.accent = parseHex(v) orelse p.accent;
    if (parsed.value.holiday_color) |v| p.danger = parseHex(v) orelse p.danger;
    return p;
}

/// The dedicated stack when the system ships it, else Fedora's and Arch's
/// `login`, which every install has.
pub fn pamService(dedicated_exists: bool) []const u8 {
    return if (dedicated_exists) "perihelion-lock" else "login";
}

// --- -f readiness ----------------------------------------------------------

pub const READY_CAP_MS: i64 = 2000;

/// `-f` lets the parent exit once the compositor sent `locked` and every
/// lock surface has had a frame presented, or READY_CAP_MS after the lock
/// request when frames are slow. Mango sends `locked` before anything is
/// drawn, so `locked` alone is not enough before a suspend.
pub const Readiness = struct {
    started_ms: i64,
    locked: bool = false,
    surfaces: usize = 0,
    presented: usize = 0,
    reported: bool = false,

    pub fn ready(self: *const Readiness, now_ms: i64) bool {
        if (!self.locked) return false;
        if (self.surfaces > 0 and self.presented >= self.surfaces) return true;
        return now_ms - self.started_ms >= READY_CAP_MS;
    }

    /// Milliseconds until the cap, for the poll timeout (-1: nothing to wait for).
    pub fn waitMs(self: *const Readiness, now_ms: i64) i32 {
        if (self.reported or !self.locked) return -1;
        const left = READY_CAP_MS - (now_ms - self.started_ms);
        return @intCast(std.math.clamp(left, 0, READY_CAP_MS));
    }
};

// --- tests -------------------------------------------------------------------

const tt = std.testing;

/// Stands in for the PAM worker: records what it was given, never runs PAM.
const FakeWorker = struct {
    accept: bool = true,
    calls: usize = 0,
    seen: [PASSWORD_MAX + 1]u8 = @as([PASSWORD_MAX + 1]u8, @splat(0)),
    seen_len: usize = 0,
    service: []const u8 = "",
    user: []const u8 = "",

    pub fn start(self: *FakeWorker, service: []const u8, user: []const u8, password: []const u8) bool {
        self.calls += 1;
        self.service = service;
        self.user = user;
        @memcpy(self.seen[0..password.len], password);
        self.seen_len = password.len;
        return self.accept;
    }
};

fn lockedSession() Session {
    var s = Session{};
    s.lockShown();
    return s;
}

fn allZero(b: []const u8) bool {
    for (b) |c| if (c != 0) return false;
    return true;
}

test "auth result byte round trip; garbage is unavailable" {
    for ([_]AuthResult{ .ok, .denied, .unavailable }) |r| try tt.expectEqual(r, AuthResult.fromByte(r.byte()));
    try tt.expectEqual(AuthResult.unavailable, AuthResult.fromByte('x'));
    try tt.expectEqual(AuthResult.unavailable, AuthResult.fromByte(0));
}

test "no input before the compositor confirms the lock" {
    var s = Session{};
    var pw = Password{};
    try tt.expectEqual(KeyAction.none, s.onKey(&pw, .{ .text = "a" }, false));
    try tt.expectEqual(@as(usize, 0), pw.len);
    var w = FakeWorker{};
    try tt.expect(!s.submit(&pw, &w, "login", "me"));
    try tt.expectEqual(@as(usize, 0), w.calls);
}

test "typing, backspace over UTF-8, escape" {
    var s = lockedSession();
    var pw = Password{};
    try tt.expectEqual(KeyAction.repaint, s.onKey(&pw, .{ .text = "a" }, false));
    try tt.expectEqual(KeyAction.repaint, s.onKey(&pw, .{ .text = "é" }, false));
    try tt.expectEqual(@as(usize, 2), pw.chars());
    try tt.expectEqual(@as(usize, 3), pw.len);
    try tt.expectEqual(KeyAction.repaint, s.onKey(&pw, .backspace, false));
    try tt.expectEqualStrings("a", pw.bytes());
    try tt.expect(allZero(pw.buf[1..]));
    // Ctrl+A is not text, nor is Tab.
    try tt.expectEqual(KeyAction.none, s.onKey(&pw, .{ .text = "x" }, true));
    try tt.expectEqual(KeyAction.none, s.onKey(&pw, .{ .text = "\t" }, false));
    try tt.expectEqual(KeyAction.repaint, s.onKey(&pw, .escape, false));
    try tt.expectEqual(@as(usize, 0), pw.len);
    try tt.expect(allZero(&pw.buf));
    try tt.expectEqual(KeyAction.none, s.onKey(&pw, .backspace, false));
}

test "password overflow drops whole characters" {
    var pw = Password{};
    var i: usize = 0;
    while (i < PASSWORD_MAX) : (i += 1) try tt.expect(pw.append("a"));
    try tt.expect(!pw.append("b"));
    try tt.expect(!pw.append("é"));
    try tt.expectEqual(@as(usize, PASSWORD_MAX), pw.len);
}

test "submit hands the worker a copy and wipes the buffer" {
    var s = lockedSession();
    var pw = Password{};
    _ = s.onKey(&pw, .{ .text = "hunter2" }, false);
    try tt.expectEqual(KeyAction.submit, s.onKey(&pw, .enter, false));
    var w = FakeWorker{};
    try tt.expect(s.submit(&pw, &w, "perihelion-lock", "me"));
    try tt.expectEqualStrings("hunter2", w.seen[0..w.seen_len]);
    try tt.expectEqualStrings("perihelion-lock", w.service);
    try tt.expectEqualStrings("me", w.user);
    try tt.expectEqual(@as(usize, 0), pw.len);
    try tt.expect(allZero(&pw.buf));
    // The field keeps its dots while PAM checks, and input is held.
    try tt.expect(s.auth_pending);
    try tt.expectEqual(@as(usize, 7), s.dots(&pw));
    try tt.expectEqual(Hint.checking, s.hint());
    try tt.expectEqual(KeyAction.none, s.onKey(&pw, .{ .text = "z" }, false));
    try tt.expect(!s.submit(&pw, &w, "perihelion-lock", "me"));
    try tt.expectEqual(@as(usize, 1), w.calls);
}

test "wrong password: message, count, cleared by the next key" {
    var s = lockedSession();
    var pw = Password{};
    var w = FakeWorker{};
    _ = s.onKey(&pw, .{ .text = "nope" }, false);
    try tt.expect(s.submit(&pw, &w, "login", "me"));
    try tt.expect(!s.finish(&pw, .denied));
    try tt.expectEqual(Phase.locked, s.phase);
    try tt.expectEqual(Hint.wrong, s.hint());
    try tt.expectEqual(@as(u32, 1), s.failures);
    try tt.expectEqual(@as(usize, 0), s.dots(&pw));
    _ = s.onKey(&pw, .{ .text = "y" }, false);
    try tt.expectEqual(Hint.idle, s.hint());
    try tt.expectEqual(@as(u32, 1), s.failures);
}

test "PAM unavailable, and a worker that cannot start" {
    var s = lockedSession();
    var pw = Password{};
    var w = FakeWorker{};
    try tt.expect(s.submit(&pw, &w, "login", "me"));
    try tt.expect(!s.finish(&pw, .unavailable));
    try tt.expectEqual(Hint.unavailable, s.hint());
    try tt.expectEqual(Phase.locked, s.phase);

    var s2 = lockedSession();
    var pw2 = Password{};
    _ = s2.onKey(&pw2, .{ .text = "pw" }, false);
    var broken = FakeWorker{ .accept = false };
    try tt.expect(!s2.submit(&pw2, &broken, "login", "me"));
    try tt.expect(!s2.auth_pending);
    try tt.expectEqual(Hint.unavailable, s2.hint());
    try tt.expect(allZero(&pw2.buf));
}

test "correct password unlocks exactly once" {
    var s = lockedSession();
    var pw = Password{};
    var w = FakeWorker{};
    try tt.expect(s.submit(&pw, &w, "login", "me"));
    try tt.expect(s.finish(&pw, .ok));
    try tt.expectEqual(Phase.unlocking, s.phase);
    try tt.expect(!s.acceptsInput());
    try tt.expect(!s.finish(&pw, .ok));
}

test "caps lock hint and its priority" {
    var s = lockedSession();
    var pw = Password{};
    try tt.expect(capsLocked(0b10, 1));
    try tt.expect(!capsLocked(0b10, 0));
    try tt.expect(!capsLocked(0xffff_ffff, null));
    try tt.expect(!capsLocked(0xffff_ffff, 40));
    s.caps_lock = true;
    try tt.expectEqual(Hint.caps_lock, s.hint());
    var w = FakeWorker{};
    try tt.expect(s.submit(&pw, &w, "login", "me"));
    try tt.expectEqual(Hint.checking, s.hint());
    _ = s.finish(&pw, .denied);
    try tt.expectEqual(Hint.wrong, s.hint());
    _ = s.onKey(&pw, .{ .text = "a" }, false);
    try tt.expectEqual(Hint.caps_lock, s.hint());
    try tt.expectEqualStrings("Caps Lock is on", Hint.caps_lock.text());
}

test "clock text, 12 and 24 hour" {
    var buf: [16]u8 = undefined;
    var c = formatClock(&buf, 14, 5, false);
    try tt.expectEqualStrings("2:05", c.main);
    try tt.expectEqualStrings("PM", c.suffix);
    c = formatClock(&buf, 0, 0, false);
    try tt.expectEqualStrings("12:00", c.main);
    try tt.expectEqualStrings("AM", c.suffix);
    c = formatClock(&buf, 12, 30, false);
    try tt.expectEqualStrings("12:30", c.main);
    try tt.expectEqualStrings("PM", c.suffix);
    c = formatClock(&buf, 9, 7, true);
    try tt.expectEqualStrings("09:07", c.main);
    try tt.expectEqualStrings("", c.suffix);
    c = formatClock(&buf, 23, 59, true);
    try tt.expectEqualStrings("23:59", c.main);
}

test "date text and weekdays" {
    var buf: [48]u8 = undefined;
    try tt.expectEqualStrings("Monday, November 9", formatDate(&buf, 2026, 11, 9));
    try tt.expectEqualStrings("Friday, November 20", formatDate(&buf, 2026, 11, 20));
    try tt.expectEqual(@as(u8, 6), weekday(2000, 1, 1)); // Saturday
    try tt.expectEqual(@as(u8, 4), weekday(2024, 2, 29)); // Thursday
    try tt.expectEqualStrings("", formatDate(&buf, 2026, 13, 1));
}

test "avatar initial" {
    var b: [4]u8 = undefined;
    try tt.expectEqualStrings("P", avatarInitial("perihelion", &b));
    try tt.expectEqualStrings("É", avatarInitial("Élodie", &b));
    try tt.expectEqualStrings("", avatarInitial("", &b));
}

test "layout stays ordered and inside the output" {
    for ([_][2]f64{ .{ 1366, 768 }, .{ 1920, 1080 }, .{ 3840, 2160 }, .{ 640, 480 } }) |sz| {
        const l = Layout.compute(sz[0], sz[1], Layout.userSize(sz[1]) * 1.3);
        try tt.expect(l.date_top < l.clock_top);
        try tt.expect(l.clock_top + l.clock_size < l.avatar_cy - l.avatar_d / 2.0);
        try tt.expect(l.avatar_cy + l.avatar_d / 2.0 < l.user_top + 1.0);
        try tt.expect(l.user_top < l.field_y);
        try tt.expect(l.field_y + l.field_h < l.hint_top + 1.0);
        try tt.expect(l.hint_top + l.hint_size < sz[1]);
        try tt.expect(l.field_x >= 0 and l.field_x + l.field_w <= sz[0]);
        try tt.expect(l.maxDots() >= 1);
    }
}

test "wallpaper files" {
    try tt.expectEqualStrings("/w/a.jpg", wallpaperFromPerihelion("image /w/a.jpg\n").?);
    try tt.expect(wallpaperFromPerihelion("color #112233\n") == null);
    try tt.expect(wallpaperIsColor("color #112233"));
    try tt.expect(!wallpaperIsColor("image /x"));
    try tt.expectEqualStrings("/w/b.png", wallpaperFromBar("mode=fill\npath=/w/b.png\n").?);
    try tt.expect(wallpaperFromBar("mode=fill\n") == null);
}

test "clock_24h from shell.json" {
    try tt.expect(!clock24h(tt.allocator, "{\"clock_24h\": false, \"other\": 1}"));
    try tt.expect(clock24h(tt.allocator, "{\"clock_24h\": true}"));
    try tt.expect(clock24h(tt.allocator, "{}"));
    try tt.expect(clock24h(tt.allocator, "not json"));
}

test "palette from matugen.json" {
    const p = palette(tt.allocator, "{\"bg_color\":\"#101010\",\"border_color\":\"#a0b0c0\",\"holiday_color\":\"#ff0000ff\",\"x\":2}");
    try tt.expectEqual(@as(u32, 0x101010), p.bg);
    try tt.expectEqual(@as(u32, 0xa0b0c0), p.accent);
    try tt.expectEqual(@as(u32, 0xff0000), p.danger);
    const d = palette(tt.allocator, "{\"bg_color\":\"oops\"}");
    try tt.expectEqual((Palette{}).bg, d.bg);
    try tt.expectEqual((Palette{}).bg, palette(tt.allocator, "").bg);
}

test "PAM service choice" {
    try tt.expectEqualStrings("perihelion-lock", pamService(true));
    try tt.expectEqualStrings("login", pamService(false));
}

test "-f readiness: locked plus frames, or the cap" {
    var r = Readiness{ .started_ms = 1000 };
    try tt.expect(!r.ready(5000));
    try tt.expectEqual(@as(i32, -1), r.waitMs(1000));
    r.locked = true;
    r.surfaces = 2;
    r.presented = 1;
    try tt.expect(!r.ready(1500));
    try tt.expectEqual(@as(i32, 1500), r.waitMs(1500));
    r.presented = 2;
    try tt.expect(r.ready(1500));
    r.presented = 0;
    try tt.expect(r.ready(3000));
    try tt.expectEqual(@as(i32, 0), r.waitMs(9000));
}

test "scrim: nothing on dark or mid wallpapers, more on brighter ones" {
    try tt.expectEqual(@as(f64, 0), scrimAlpha(0.0));
    try tt.expectEqual(@as(f64, 0), scrimAlpha(0.30));
    try tt.expectEqual(@as(f64, 0), scrimAlpha(BRIGHT_LUMA - 0.001));
    try tt.expectEqual(@as(f64, 0), scrimAlpha(std.math.nan(f64)));
    try tt.expectApproxEqAbs(MIN_SCRIM, scrimAlpha(BRIGHT_LUMA), 1e-9);
    try tt.expectApproxEqAbs(MAX_SCRIM, scrimAlpha(FULL_LUMA), 1e-9);
    try tt.expectApproxEqAbs(MAX_SCRIM, scrimAlpha(1.0), 1e-9);
    // Monotone between the two ends.
    var prev: f64 = 0;
    var l: f64 = BRIGHT_LUMA;
    while (l <= 1.0) : (l += 0.01) {
        const a = scrimAlpha(l);
        try tt.expect(a >= prev);
        try tt.expect(a <= MAX_SCRIM);
        prev = a;
    }
}

test "bandLuma: white, black, and only the band counts" {
    const w = 64;
    const h = 40;
    var px: [w * h]u32 = undefined;
    // Top half white, bottom half black.
    for (0..h) |y| for (0..w) |x| {
        px[y * w + x] = if (y < h / 2) 0xFFFFFFFF else 0xFF000000;
    };
    try tt.expectApproxEqAbs(@as(f64, 1.0), bandLuma(&px, w, h, .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = 10 }), 1e-9);
    try tt.expectApproxEqAbs(@as(f64, 0.0), bandLuma(&px, w, h, .{ .x0 = 0, .y0 = 25, .x1 = w, .y1 = 40 }), 1e-9);
    const mid = bandLuma(&px, w, h, .{ .x0 = 0, .y0 = 10, .x1 = w, .y1 = 30 });
    try tt.expect(mid > 0.4 and mid < 0.6);
    // Out of range and empty bands are clamped, never read past the buffer.
    try tt.expectApproxEqAbs(@as(f64, 0.0), bandLuma(&px, w, h, .{ .x0 = -50, .y0 = 30, .x1 = 900, .y1 = 900 }), 1e-9);
    try tt.expectEqual(@as(f64, 0), bandLuma(&px, w, h, .{ .x0 = 10, .y0 = 10, .x1 = 10, .y1 = 20 }));
    try tt.expectEqual(@as(f64, 0), bandLuma(px[0..10], w, h, .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h }));
    // Green weighs most (Rec. 709).
    var g: [4]u32 = @splat(0xFF00FF00);
    var b: [4]u32 = @splat(0xFF0000FF);
    try tt.expect(bandLuma(&g, 2, 2, .{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 2 }) > bandLuma(&b, 2, 2, .{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 2 }));
}

test "Legibility.measure: bright screen darkens all three lines, dark screen none" {
    const w = 640;
    const h = 400;
    const l = Layout.compute(w, h, 14);
    var bright: [w * h]u32 = @splat(0xFFF2F0EA);
    const lb = Legibility.measure(&bright, w, h, &l);
    try tt.expect(lb.date > 0 and lb.user > 0 and lb.hint > 0);
    var dark: [w * h]u32 = @splat(0xFF1A1C24);
    const ld = Legibility.measure(&dark, w, h, &l);
    try tt.expectEqual(Legibility{}, ld);
    // Bright only behind the date: only the date gets the patch.
    var mixed: [w * h]u32 = @splat(0xFF1A1C24);
    const band = l.textBands()[0];
    for (0..h) |y| for (0..w) |x| {
        const fx: f64 = @floatFromInt(x);
        const fy: f64 = @floatFromInt(y);
        if (fy >= band.y0 - 2 and fy < band.y1 + 2 and fx >= band.x0 - 2 and fx < band.x1 + 2) mixed[y * w + x] = 0xFFFFFFFF;
    };
    const lm = Legibility.measure(&mixed, w, h, &l);
    try tt.expect(lm.date > 0);
    try tt.expectEqual(@as(f64, 0), lm.user);
    try tt.expectEqual(@as(f64, 0), lm.hint);
}

test "textBands sit inside the screen and in reading order" {
    const l = Layout.compute(1920, 1080, 30);
    const b = l.textBands();
    for (b) |r| {
        try tt.expect(r.x0 >= 0 and r.x1 <= 1920 and r.y0 >= 0 and r.y1 <= 1080);
        try tt.expect(r.x1 > r.x0 and r.y1 > r.y0);
    }
    try tt.expect(b[0].y1 < b[1].y0); // date above the username
    try tt.expect(b[1].y1 < b[2].y1); // username above the hint
}
