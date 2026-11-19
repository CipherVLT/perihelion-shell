//! System-info ("fastfetch") service for the desktop Fastfetch card
//! (perihelionbar-shell widgets.zig FastfetchWidget). Same shape as
//! weather.zig and temps.zig: no drawing and no fds of its own. The host
//! calls tick() and, when wantRun() says so, runs one fastfetch child and
//! hands its stdout to runComplete().
//!
//! Perihelion's fastfetch is the stock `fastfetch` package with a custom
//! config: install.sh copies the repo's fastfetch/ to ~/.config/fastfetch/
//! (boxed Hardware / Software / Uptime sections, tree-style keys, the
//! feather logo), and the default copy lives at SHIPPED_CONFIG. The card
//! follows that config:
//!
//!   Config layout (a config was found and has a "modules" list):
//!     The card's rows are the config's modules, in its order: its
//!     section boxes become headers, "break" becomes a gap, and keys keep
//!     their icon and words without the terminal's tree prefix. The binary
//!     runs a derived copy of the config in which each module keeps all
//!     its own options (format, command text, units) but gets a unique key
//!     "@@N", so every output line maps back to exactly one row — even
//!     when the terminal keys repeat ("│ ├" on four rows). Modules the
//!     config doesn't list (local IP, say) are never shown.
//!   Fields layout (no config, or fastfetch_config "none"):
//!     A fixed row list (fastfetch_fields), run as `-c none -s …` so the
//!     output uses fastfetch's own default keys.
//!
//! Binary, best first:
//!   1. shell.json fastfetch_binary: a path, or a name looked up on PATH.
//!   2. `perihelion-fastfetch` on PATH (PERIHELION_BINARY). Nothing in the
//!      repo ships this; it is only probed in case an ISO build adds one.
//!   3. `fastfetch` on PATH (what Perihelion actually installs).
//!   4. None: the built-in reader (/etc/os-release, uname(), /proc, /sys,
//!      statvfs(), the GTK settings file) fills whatever rows it can.
//! A binary that prints nothing usable is dropped for the next one down.
//!
//! Cost: the card fills in natively at once, without waiting for a process.
//! fastfetch then runs once at start and every fastfetch_refresh_minutes
//! (default 30). Uptime, memory, disk and the date/time are redone natively
//! every minute in between, so no process is needed for them. tick()
//! reports whether anything shown changed (a hash of the rows), so the card
//! repaints only then.
//!
//! Tests: `zig build test-fastfetch` in perihelionbar/ (fake /etc, /proc
//! and /sys trees under /tmp, and Perihelion's real config; no fastfetch
//! needed).

const std = @import("std");
const posix = std.posix;

/// The ISO's own build, preferred over the stock binary when on PATH.
/// Assumed to take fastfetch's command line (it is a fastfetch build);
/// if it doesn't, it prints no rows and the service falls back.
pub const PERIHELION_BINARY = "perihelion-fastfetch";
pub const SYSTEM_BINARY = "fastfetch";

pub const DEFAULT_REFRESH_MS: i64 = 30 * 60_000;
const LIVE_MS: i64 = 60_000;
pub const MAX_LOGO_LINES: usize = 24;

/// `sh -c` scripts for the fastfetch run. $0 = binary; $1 = the module
/// list (fields layout) or the derived config file (config layout). Both
/// arrive as arguments, never spliced into the script.
pub const RUN_CMD = "exec \"$0\" -c none --pipe --logo none -s \"$1\" 2>/dev/null";
pub const RUN_CMD_CONFIG = "exec \"$0\" -c \"$1\" --pipe --logo none 2>/dev/null";

/// Perihelion's shipped default config (perihelion-theme restores from it);
/// the card's last place to look after the user's own config.
pub const SHIPPED_CONFIG = "/usr/share/perihelion/fastfetch/config.jsonc";

// --- libc -------------------------------------------------------------------------

const Utsname = extern struct {
    sysname: [65]u8,
    nodename: [65]u8,
    release: [65]u8,
    version: [65]u8,
    machine: [65]u8,
    domainname: [65]u8,
};

/// glibc's struct statvfs on x86_64 (same binding as the bar's disk module).
const Statvfs = extern struct {
    f_bsize: u64,
    f_frsize: u64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: u64,
    f_flag: u64,
    f_namemax: u64,
    f_spare: [6]i32,
};

/// glibc struct tm (x86_64).
const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

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
    extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    extern "c" fn uname(buf: *Utsname) c_int;
    extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;
    extern "c" fn time(t: ?*i64) i64;
    extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;
};

/// "2026-11-18 15:53" — fastfetch's date/time without the seconds (a card
/// refreshed once a minute would otherwise show them frozen).
fn localTimeText(out: []u8) []const u8 {
    const t: i64 = libc.time(null);
    var tm: Tm = undefined;
    if (libc.localtime_r(&t, &tm) == null) return "";
    return std.fmt.bufPrint(out, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min }) catch "";
}

/// mkdir -p for the directories above `path` (best effort).
fn mkdirParents(path: []const u8) void {
    var buf: [400]u8 = undefined;
    if (path.len >= buf.len) return;
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        _ = posix.system.mkdir(buf[0..i :0].ptr, 0o755);
    }
}
const X_OK: c_int = 1;

fn env(name: [*:0]const u8) []const u8 {
    return std.mem.span(libc.getenv(name) orelse return "");
}

// --- small helpers -------------------------------------------------------------------

/// Fixed-capacity, always NUL-terminated text (z() feeds argv directly).
pub fn Text(comptime N: usize) type {
    return struct {
        buf: [N + 1]u8 = [_]u8{0} ** (N + 1),
        len: usize = 0,

        const Self = @This();

        pub fn set(self: *Self, s: []const u8) void {
            var n: usize = @min(s.len, N);
            while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1; // UTF-8 boundary
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

fn pathZ(buf: []u8, comptime fmt: []const u8, args: anytype) ?[:0]const u8 {
    return std.fmt.bufPrintZ(buf, fmt, args) catch null;
}

/// Whole small file into `buf` (truncated at buf.len). Null if unreadable.
fn readFile(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const raw_fd = posix.system.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw_fd < 0) return null;
    const fd: posix.fd_t = @intCast(raw_fd);
    defer _ = posix.system.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = posix.read(fd, buf[len..]) catch return null;
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

fn readTrim(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const t = std.mem.trim(u8, readFile(path, buf) orelse return null, " \t\r\n\x00");
    return if (t.len == 0) null else t;
}

/// Entries in a directory, not counting dot entries or `skip`.
fn countDir(path: [:0]const u8, skip: []const u8) usize {
    const d = libc.opendir(path.ptr) orelse return 0;
    defer _ = libc.closedir(d);
    var n: usize = 0;
    while (libc.readdir(d)) |e| {
        const name = std.mem.sliceTo(&e.d_name, 0);
        if (name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, skip)) continue;
        n += 1;
    }
    return n;
}

/// Value of `key=` in KEY=value / key = value text (os-release, ini).
fn keyValue(text: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = std.mem.trimStart(u8, line[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        const v = std.mem.trim(u8, rest[1..], " \t\"'");
        if (v.len > 0) return v;
    }
    return null;
}

fn cstr(a: []const u8) []const u8 {
    return std.mem.sliceTo(a, 0);
}

/// fastfetch's size style: "5.01 GiB", "512.00 MiB".
fn fmtSize(out: []u8, bytes: u64) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    if (bytes >= 1 << 30) return std.fmt.bufPrint(out, "{d:.2} GiB", .{b / (1 << 30)}) catch "";
    return std.fmt.bufPrint(out, "{d:.2} MiB", .{b / (1 << 20)}) catch "";
}

/// "5.01 GiB / 31.27 GiB (16%)" — fastfetch's memory/disk shape.
fn fmtUsage(out: []u8, used: u64, total: u64) []const u8 {
    var ub: [24]u8 = undefined;
    var tb: [24]u8 = undefined;
    const pct: u64 = if (total > 0) (used * 100 + total / 2) / total else 0;
    return std.fmt.bufPrint(out, "{s} / {s} ({d}%)", .{ fmtSize(&ub, used), fmtSize(&tb, total), pct }) catch "";
}

/// fastfetch's uptime shape: "2 days, 3 hours, 5 mins".
pub fn fmtUptime(out: []u8, secs: u64) []const u8 {
    if (secs < 60) return std.fmt.bufPrint(out, "{d} secs", .{secs}) catch "";
    const d = secs / 86400;
    const h = (secs % 86400) / 3600;
    const m = (secs % 3600) / 60;
    var len: usize = 0;
    const parts = [_]struct { n: u64, one: []const u8, many: []const u8 }{
        .{ .n = d, .one = "day", .many = "days" },
        .{ .n = h, .one = "hour", .many = "hours" },
        .{ .n = m, .one = "min", .many = "mins" },
    };
    for (parts) |p| {
        if (p.n == 0) continue;
        const sep: []const u8 = if (len > 0) ", " else "";
        const s = std.fmt.bufPrint(out[len..], "{s}{d} {s}", .{ sep, p.n, if (p.n == 1) p.one else p.many }) catch break;
        len += s.len;
    }
    return out[0..len];
}

// --- fields -----------------------------------------------------------------------------

/// A row of the card. The tag name is also the fastfetch module name
/// (for --structure) and label() is the key fastfetch prints for it.
pub const Field = enum {
    os,
    host,
    kernel,
    uptime,
    packages,
    shell,
    display,
    wm,
    theme,
    icons,
    font,
    cpu,
    gpu,
    memory,
    disk,
    bios,
    de,
    datetime,

    pub fn label(self: Field) []const u8 {
        return switch (self) {
            .os => "OS",
            .host => "Host",
            .kernel => "Kernel",
            .uptime => "Uptime",
            .packages => "Packages",
            .shell => "Shell",
            .display => "Display",
            .wm => "WM",
            .theme => "Theme",
            .icons => "Icons",
            .font => "Font",
            .cpu => "CPU",
            .gpu => "GPU",
            .memory => "Memory",
            .disk => "Disk",
            .bios => "BIOS",
            .de => "DE",
            .datetime => "Date/Time",
        };
    }

    /// Cheap to read and changes all the time: redone natively every minute.
    pub fn isLive(self: Field) bool {
        return self == .uptime or self == .memory or self == .disk or self == .datetime;
    }

    fn fromKey(key: []const u8) ?Field {
        inline for (@typeInfo(Field).@"enum".fields) |f| {
            const v: Field = @enumFromInt(f.value);
            if (std.mem.eql(u8, key, v.label())) return v;
        }
        return null;
    }
};

pub const FIELD_COUNT = @typeInfo(Field).@"enum".fields.len;
pub const DEFAULT_FIELDS = [_]Field{ .os, .host, .kernel, .uptime, .packages, .shell, .wm, .cpu, .gpu, .memory, .disk };

/// shell.json fastfetch_fields → fields, in the order given, without
/// duplicates. Unknown names are skipped and counted in `unknown`.
pub fn parseFields(names: []const []const u8, out: *[FIELD_COUNT]Field, unknown: *usize) usize {
    var n: usize = 0;
    unknown.* = 0;
    for (names) |name| {
        const f = std.meta.stringToEnum(Field, name) orelse {
            unknown.* += 1;
            continue;
        };
        if (std.mem.indexOfScalar(Field, out[0..n], f) != null) continue;
        out[n] = f;
        n += 1;
    }
    return n;
}

pub const Source = enum {
    custom,
    perihelion,
    system,
    native,

    pub fn describe(self: Source) []const u8 {
        return switch (self) {
            .custom => "fastfetch_binary",
            .perihelion => PERIHELION_BINARY,
            .system => SYSTEM_BINARY,
            .native => "built-in collector",
        };
    }
};

pub const Config = struct {
    /// "" = auto (user config, then SHIPPED_CONFIG), "none" = fields
    /// layout, else a config file path.
    config: []const u8 = "",
    /// Rows for the fields layout (ignored when a config drives the card).
    fields: []const Field = &DEFAULT_FIELDS,
    /// How often to run fastfetch; 0 = only at startup.
    refresh_ms: i64 = DEFAULT_REFRESH_MS,
    /// "" = auto-detect, "none" = never run a binary, else a path or name.
    binary: []const u8 = "",
    /// "auto" (logo.source of the user's fastfetch config, when it's a
    /// text logo), "distro" (Nerd Font glyph), "none", or a logo file path.
    logo: []const u8 = "auto",
    /// Filesystem root for /etc, /proc, /sys, /var ("" in real use).
    root: []const u8 = "",
    /// Home directory ("" = $HOME).
    home: []const u8 = "",
};

/// shell.json keys (std.json, ignore_unknown_fields).
pub const ShellJsonKeys = struct {
    fastfetch_fields: ?[]const []const u8 = null,
    fastfetch_refresh_minutes: ?u32 = null,
    fastfetch_binary: ?[]const u8 = null,
    fastfetch_logo: ?[]const u8 = null,
    fastfetch_config: ?[]const u8 = null,
};

// --- fastfetch output -----------------------------------------------------------------

/// "GPU 2: AMD Radeon RX 7800 XT [Discrete]" → (.gpu, value);
/// "Disk (/home): …" → (.disk, value, mount "/home").
const ParsedRow = struct { field: Field, value: []const u8, qualifier: []const u8 };

fn parseRow(line: []const u8) ?ParsedRow {
    const colon = std.mem.indexOf(u8, line, ": ") orelse return null;
    const key = std.mem.trim(u8, line[0..colon], " ");
    const value = std.mem.trim(u8, line[colon + 2 ..], " \r");
    if (value.len == 0) return null;
    var base = key;
    var qualifier: []const u8 = "";
    if (std.mem.indexOf(u8, key, " (")) |p| {
        base = key[0..p];
        qualifier = std.mem.trim(u8, key[p + 2 ..], ")");
    }
    // Multi-device keys: "GPU 1", "GPU 2".
    if (std.mem.lastIndexOfScalar(u8, base, ' ')) |sp| {
        if (std.fmt.parseInt(u8, base[sp + 1 ..], 10)) |_| base = base[0..sp] else |_| {}
    }
    const field = Field.fromKey(base) orelse return null;
    return .{ .field = field, .value = value, .qualifier = qualifier };
}

/// Perihelion's fastfetch config logo source, from JSONC text: the string
/// value of "source" inside the "logo" object. Null for a built-in logo
/// name given directly ("logo": "arch") or no logo key at all.
pub fn logoSourceFromConfig(text: []const u8) ?[]const u8 {
    const lk = std.mem.indexOf(u8, text, "\"logo\"") orelse return null;
    var i = lk + "\"logo\"".len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r' or text[i] == ':')) i += 1;
    if (i >= text.len or text[i] != '{') return null;
    // End of the logo object, counting nested braces ("color": { … }).
    var obj_end = text.len;
    var depth: usize = 0;
    var k = i;
    while (k < text.len) : (k += 1) {
        if (text[k] == '{') depth += 1;
        if (text[k] == '}') {
            depth -= 1;
            if (depth == 0) {
                obj_end = k;
                break;
            }
        }
    }
    const sk = std.mem.indexOf(u8, text[i..obj_end], "\"source\"") orelse return null;
    var j = i + sk + "\"source\"".len;
    while (j < obj_end and text[j] != '"') j += 1;
    if (j >= obj_end) return null;
    const start = j + 1;
    const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return null;
    const src = text[start..end];
    return if (src.len == 0) null else src;
}

fn isImagePath(p: []const u8) bool {
    const exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".bmp" };
    for (exts) |e| {
        if (p.len >= e.len and std.ascii.eqlIgnoreCase(p[p.len - e.len ..], e)) return true;
    }
    return false;
}

/// Visible columns of a logo line: codepoints, not counting "$N" markers.
pub fn logoCols(line: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '$' and i + 1 < line.len and std.ascii.isDigit(line[i + 1])) {
            i += 2;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        i += n;
        cols += 1;
    }
    return cols;
}

/// Nerd Font glyph for an os-release ID (U+F3xx "linux-*" set).
pub fn distroGlyph(id: []const u8) u32 {
    const map = [_]struct { id: []const u8, cp: u32 }{
        .{ .id = "arch", .cp = 0xF303 },     .{ .id = "endeavouros", .cp = 0xF322 },
        .{ .id = "manjaro", .cp = 0xF312 },  .{ .id = "cachyos", .cp = 0xF385 },
        .{ .id = "garuda", .cp = 0xF337 },   .{ .id = "artix", .cp = 0xF31F },
        .{ .id = "fedora", .cp = 0xF30A },   .{ .id = "ubuntu", .cp = 0xF31B },
        .{ .id = "debian", .cp = 0xF306 },   .{ .id = "nixos", .cp = 0xF313 },
        .{ .id = "opensuse", .cp = 0xF314 }, .{ .id = "gentoo", .cp = 0xF30D },
        .{ .id = "void", .cp = 0xF32E },
    };
    for (map) |m| {
        if (std.mem.startsWith(u8, id, m.id)) return m.cp;
    }
    return 0xF31A; // linux-tux
}

// --- config layout: the user's fastfetch config as card rows -----------------------

pub const Layout = enum { config, fields };
pub const MAX_ROWS: usize = 28;
pub const RowKind = enum { header, row, spacer };
/// Rows the card refreshes itself every minute (Service.syncRows): only
/// where the config keeps fastfetch's default format, so the native value
/// looks the same. Date/time is always refreshed (seconds dropped).
pub const Live = enum { none, uptime, datetime, memory, disk };

pub const CardRow = struct {
    kind: RowKind = .row,
    label: Text(64) = .{},
    value: Text(128) = .{},
    /// Index N of the "@@N" key in the derived config; -1 = not run.
    module: i16 = -1,
    /// Native source for the instant first paint and the built-in fallback.
    field: ?Field = null,
    live: Live = .none,
    /// Holds a value from the binary (or the config itself), not a
    /// native stand-in.
    fresh: bool = false,
};

pub const Plan = struct {
    rows: usize = 0,
    modules: usize = 0,
    derived_len: usize = 0,
    palette: bool = false,
    datetime: bool = false,
};

fn isBoxCp(cp: u21) bool {
    return cp >= 0x2500 and cp <= 0x259F; // box drawing + block elements
}

/// JSONC → JSON: comments and trailing commas out, strings untouched.
fn stripJsonc(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    const a = try alloc.alloc(u8, src.len);
    var n: usize = 0;
    var i: usize = 0;
    var in_str = false;
    while (i < src.len) {
        const c = src[i];
        if (in_str) {
            a[n] = c;
            n += 1;
            if (c == '\\' and i + 1 < src.len) {
                a[n] = src[i + 1];
                n += 1;
                i += 2;
                continue;
            }
            if (c == '"') in_str = false;
            i += 1;
            continue;
        }
        if (c == '"') in_str = true;
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            i = @min(i + 2, src.len);
            continue;
        }
        a[n] = c;
        n += 1;
        i += 1;
    }
    const b = try alloc.alloc(u8, n);
    var m: usize = 0;
    in_str = false;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const c = a[k];
        if (in_str) {
            b[m] = c;
            m += 1;
            if (c == '\\' and k + 1 < n) {
                k += 1;
                b[m] = a[k];
                m += 1;
                continue;
            }
            if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') in_str = true;
        if (c == ',') {
            var j = k + 1;
            while (j < n and std.ascii.isWhitespace(a[j])) j += 1;
            if (j < n and (a[j] == '}' or a[j] == ']')) continue;
        }
        b[m] = c;
        m += 1;
    }
    return b[0..m];
}

/// Default name for a module type ("localip" → "Local IP").
fn typeLabel(t: []const u8, out: []u8) []const u8 {
    if (std.meta.stringToEnum(Field, t)) |f| return f.label();
    const extra = [_]struct { t: []const u8, l: []const u8 }{
        .{ .t = "localip", .l = "Local IP" },         .{ .t = "publicip", .l = "Public IP" },
        .{ .t = "swap", .l = "Swap" },                 .{ .t = "battery", .l = "Battery" },
        .{ .t = "terminal", .l = "Terminal" },         .{ .t = "terminalfont", .l = "Terminal Font" },
        .{ .t = "locale", .l = "Locale" },             .{ .t = "board", .l = "Board" },
        .{ .t = "chassis", .l = "Chassis" },           .{ .t = "cursor", .l = "Cursor" },
        .{ .t = "command", .l = "Command" },           .{ .t = "opengl", .l = "OpenGL" },
        .{ .t = "vulkan", .l = "Vulkan" },             .{ .t = "processes", .l = "Processes" },
        .{ .t = "lm", .l = "Login Manager" },
    };
    for (extra) |e| {
        if (std.mem.eql(u8, t, e.t)) return e.l;
    }
    const n = @min(t.len, out.len);
    @memcpy(out[0..n], t[0..n]);
    if (n > 0) out[0] = std.ascii.toUpper(out[0]);
    return out[0..n];
}

/// Row label from a configured key: the terminal's tree/box prefix
/// ("│ ├", "| |->", "└ └") goes, the Nerd Font icon and words stay. A key
/// that is only an icon gets the module's name after it.
pub fn deriveLabel(key: []const u8, type_label: []const u8, out: []u8) []const u8 {
    var i: usize = 0;
    while (i < key.len) {
        const c = key[i];
        if (c < 0x80) {
            if (std.mem.indexOfScalar(u8, " |->+<`'*=", c) != null) {
                i += 1;
                continue;
            }
            break;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch break;
        if (i + n > key.len) break;
        const cp = std.unicode.utf8Decode(key[i .. i + n]) catch break;
        if (!isBoxCp(cp)) break;
        i += n;
    }
    const rest = std.mem.trimEnd(u8, key[i..], " ");
    for (rest) |c| {
        if (std.ascii.isAlphabetic(c)) return rest;
    }
    if (rest.len == 0) return type_label;
    if (type_label.len == 0) return rest;
    return std.fmt.bufPrint(out, "{s} {s}", .{ rest, type_label }) catch type_label;
}

/// Section title from a custom box line: "┌───Hardware───┐" → "Hardware".
/// Null for a line with no words (a box's bottom edge).
pub fn sectionTitle(format: []const u8, out: []u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    var words = false;
    var last_space = true;
    while (i < format.len) {
        const len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
        if (i + len > format.len) break;
        const seg = format[i .. i + len];
        i += len;
        var keep = false;
        if (len == 1) {
            const c = seg[0];
            if (std.ascii.isAlphanumeric(c)) {
                keep = true;
                words = true;
            } else if (c == ' ' or c == '/' or c == '&' or c == '.') {
                keep = true;
            }
        } else {
            const cp = std.unicode.utf8Decode(seg) catch continue;
            keep = !isBoxCp(cp);
            if (keep) words = true;
        }
        if (!keep or (seg.len == 1 and seg[0] == ' ')) {
            if (!last_space and n < out.len) {
                out[n] = ' ';
                n += 1;
            }
            last_space = true;
            continue;
        }
        if (n + seg.len > out.len) break;
        @memcpy(out[n .. n + seg.len], seg);
        n += seg.len;
        last_space = false;
    }
    if (!words) return null;
    return std.mem.trim(u8, out[0..n], " ");
}

/// Small fixed-buffer JSON writer for the derived config.
const Buf = struct {
    b: []u8,
    n: usize = 0,
    ok: bool = true,

    fn put(self: *Buf, s: []const u8) void {
        if (!self.ok) return;
        if (self.n + s.len > self.b.len) {
            self.ok = false;
            return;
        }
        @memcpy(self.b[self.n .. self.n + s.len], s);
        self.n += s.len;
    }

    fn fmt(self: *Buf, comptime f: []const u8, args: anytype) void {
        if (!self.ok) return;
        const r = std.fmt.bufPrint(self.b[self.n..], f, args) catch {
            self.ok = false;
            return;
        };
        self.n += r.len;
    }

    fn str(self: *Buf, s: []const u8) void {
        self.put("\"");
        for (s) |c| {
            switch (c) {
                '"' => self.put("\\\""),
                '\\' => self.put("\\\\"),
                '\n' => self.put("\\n"),
                '\t' => self.put("\\t"),
                else => if (c < 0x20) self.fmt("\\u{x:0>4}", .{c}) else self.put(&[_]u8{c}),
            }
        }
        self.put("\"");
    }
};

fn writeValue(w: *Buf, v: std.json.Value) void {
    switch (v) {
        .null => w.put("null"),
        .bool => |x| w.put(if (x) "true" else "false"),
        .integer => |x| w.fmt("{d}", .{x}),
        .float => |x| w.fmt("{d}", .{x}),
        .number_string => |x| w.put(x),
        .string => |x| w.str(x),
        .array => |a| {
            w.put("[");
            for (a.items, 0..) |item, i| {
                if (i > 0) w.put(",");
                writeValue(w, item);
            }
            w.put("]");
        },
        .object => |o| writeObject(w, o, &.{}, null),
    }
}

/// An object minus the `skip` keys, plus a raw `extra` member.
fn writeObject(w: *Buf, o: std.json.ObjectMap, skip: []const []const u8, extra: ?[]const u8) void {
    w.put("{");
    var first = true;
    var it = o.iterator();
    while (it.next()) |e| {
        var skipped = false;
        for (skip) |k| {
            if (std.mem.eql(u8, e.key_ptr.*, k)) skipped = true;
        }
        if (skipped) continue;
        if (!first) w.put(",");
        first = false;
        w.str(e.key_ptr.*);
        w.put(":");
        writeValue(w, e.value_ptr.*);
    }
    if (extra) |x| {
        if (!first) w.put(",");
        w.put(x);
    }
    w.put("}");
}

fn strField(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

/// Reads a fastfetch JSONC config into card rows and writes the derived
/// config the binary runs (same modules and options, keys "@@N", no
/// logo, separator ": "). Null when it isn't a usable config.
pub fn buildPlan(alloc: std.mem.Allocator, jsonc: []const u8, rows: *[MAX_ROWS]CardRow, derived: []u8) ?Plan {
    const clean = stripJsonc(alloc, jsonc) catch return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, clean, .{}) catch return null;
    if (root != .object) return null;
    const mods_v = root.object.get("modules") orelse return null;
    if (mods_v != .array) return null;

    var plan = Plan{};
    var w = Buf{ .b = derived };
    // The user's display options (units, precision, bars…) still apply;
    // only what would break parsing is replaced.
    w.put("{\"display\":");
    const display_v = root.object.get("display");
    if (display_v != null and display_v.? == .object) {
        writeObject(&w, display_v.?.object, &.{ "separator", "key", "keyWidth", "color", "pipe" }, "\"separator\":\": \"");
    } else {
        w.put("{\"separator\":\": \"}");
    }
    w.put(",\"modules\":[");

    for (mods_v.array.items) |item| {
        var obj: ?std.json.ObjectMap = null;
        const raw_t: []const u8 = switch (item) {
            .string => |x| x,
            .object => |o| blk: {
                obj = o;
                break :blk strField(o, "type") orelse continue;
            },
            else => continue,
        };
        var tb: [32]u8 = undefined;
        const t = std.ascii.lowerString(&tb, raw_t[0..@min(raw_t.len, tb.len)]);
        const key: ?[]const u8 = if (obj) |o| strField(o, "key") else null;
        const format: ?[]const u8 = if (obj) |o| strField(o, "format") else null;

        if (std.mem.eql(u8, t, "break")) {
            if (plan.rows > 0 and plan.rows < MAX_ROWS and rows[plan.rows - 1].kind != .spacer) {
                rows[plan.rows] = .{ .kind = .spacer };
                plan.rows += 1;
            }
            continue;
        }
        // The card draws its own palette dots, title and rule.
        if (std.mem.eql(u8, t, "colors")) {
            plan.palette = true;
            continue;
        }
        if (std.mem.eql(u8, t, "title") or std.mem.eql(u8, t, "separator")) continue;
        if (plan.rows == MAX_ROWS) break;

        var lb: [96]u8 = undefined;
        var tlb: [32]u8 = undefined;
        if (std.mem.eql(u8, t, "custom")) {
            // Text the config writes itself: no need to run it.
            const f = format orelse continue;
            if (key) |k| {
                var cr = CardRow{ .fresh = true };
                cr.label.set(deriveLabel(k, "", &lb));
                cr.value.set(f);
                rows[plan.rows] = cr;
                plan.rows += 1;
            } else if (sectionTitle(f, &lb)) |title| {
                var hr = CardRow{ .kind = .header };
                hr.label.set(title);
                rows[plan.rows] = hr;
                plan.rows += 1;
            }
            continue;
        }

        const tl = typeLabel(t, &tlb);
        var r = CardRow{ .field = std.meta.stringToEnum(Field, t) };
        r.label.set(if (key) |k| deriveLabel(k, tl, &lb) else tl);
        if (std.mem.eql(u8, t, "datetime")) {
            // Shown natively and kept current; no point running it.
            r.live = .datetime;
            plan.datetime = true;
            rows[plan.rows] = r;
            plan.rows += 1;
            continue;
        }
        if (format == null) {
            r.live = if (std.mem.eql(u8, t, "uptime")) .uptime else if (std.mem.eql(u8, t, "memory")) .memory else if (std.mem.eql(u8, t, "disk")) .disk else .none;
        }
        const idx = plan.modules;
        r.module = @intCast(idx);
        rows[plan.rows] = r;
        plan.rows += 1;

        var kb: [24]u8 = undefined;
        const tag = std.fmt.bufPrint(&kb, "\"key\":\"@@{d}\"", .{idx}) catch continue;
        if (idx > 0) w.put(",");
        if (obj) |o| {
            writeObject(&w, o, &.{ "key", "keyColor", "keyFormat", "keyWidth", "keyIcon" }, tag);
        } else {
            w.put("{\"type\":");
            w.str(t);
            w.put(",");
            w.put(tag);
            w.put("}");
        }
        plan.modules += 1;
    }
    w.put("]}");
    while (plan.rows > 0 and rows[plan.rows - 1].kind == .spacer) plan.rows -= 1;
    if (!w.ok or plan.rows == 0) return null;
    plan.derived_len = w.n;
    return plan;
}

const Tagged = struct { idx: i16, value: []const u8 };

/// "@@7: 812 days" → (7, "812 days"). Key padding before ':' is tolerated.
fn parseTagged(line: []const u8) ?Tagged {
    const t = std.mem.trimStart(u8, line, " ");
    if (!std.mem.startsWith(u8, t, "@@")) return null;
    var j: usize = 2;
    while (j < t.len and std.ascii.isDigit(t[j])) j += 1;
    if (j == 2) return null;
    const idx = std.fmt.parseInt(i16, t[2..j], 10) catch return null;
    var rest = std.mem.trimStart(u8, t[j..], " ");
    if (std.mem.startsWith(u8, rest, ":")) rest = rest[1..];
    const v = std.mem.trim(u8, rest, " \r");
    if (v.len == 0) return null;
    return .{ .idx = idx, .value = v };
}

// --- the service ------------------------------------------------------------------------

pub const Service = struct {
    fields: [FIELD_COUNT]Field = undefined,
    field_count: usize = 0,
    refresh_ms: i64 = DEFAULT_REFRESH_MS,
    root: Text(96) = .{},
    home: Text(160) = .{},

    source: Source = .native,
    bin: Text(256) = .{},
    /// The stock fastfetch, kept as the fallback when a preferred binary
    /// prints nothing usable.
    fallback_bin: Text(256) = .{},
    structure: Text(160) = .{},

    values: [FIELD_COUNT]Text(128) = [_]Text(128){.{}} ** FIELD_COUNT,
    /// "user@hostname", fastfetch's title line.
    title: Text(96) = .{},
    distro_id: Text(32) = .{},

    logo: [MAX_LOGO_LINES]Text(256) = [_]Text(256){.{}} ** MAX_LOGO_LINES,
    logo_count: usize = 0,
    logo_cols: usize = 0,
    logo_off: bool = false,

    started: bool = false,
    in_flight: bool = false,
    next_run_ms: i64 = 0,
    next_live_ms: i64 = 0,
    next_static_ms: i64 = 0,
    shown_hash: u64 = 0,

    layout: Layout = .fields,
    rows: [MAX_ROWS]CardRow = [_]CardRow{.{}} ** MAX_ROWS,
    row_count: usize = 0,
    /// The config ends on a "colors" module (fields layout: always).
    palette: bool = true,
    has_datetime: bool = false,
    config_path: Text(320) = .{},
    derived_path: Text(320) = .{},

    /// Detection and config reading only (PATH lookups, a few small file
    /// reads, one small file write): no process.
    pub fn init(cfg: Config) Service {
        var s = Service{ .refresh_ms = if (cfg.refresh_ms <= 0) 0 else @max(cfg.refresh_ms, 60_000) };
        s.root.set(cfg.root);
        s.home.set(if (cfg.home.len > 0) cfg.home else env("HOME"));
        s.detectSource(cfg.binary);
        var text_buf: [32768]u8 = undefined;
        const cfg_text = s.findConfig(cfg.config, &text_buf);
        if (cfg_text) |text| s.useConfigLayout(text);
        if (s.layout == .fields) {
            const fields = if (cfg.fields.len > 0) cfg.fields else &DEFAULT_FIELDS;
            for (fields) |f| {
                if (s.field_count == FIELD_COUNT) break;
                if (std.mem.indexOfScalar(Field, s.fields[0..s.field_count], f) != null) continue;
                s.fields[s.field_count] = f;
                s.field_count += 1;
            }
            s.buildStructure();
        }
        s.loadLogo(cfg.logo, cfg_text);
        return s;
    }

    pub fn cardRows(self: *const Service) []const CardRow {
        return self.rows[0..self.row_count];
    }

    /// The fastfetch config in use: given path, then the user's
    /// ($XDG_CONFIG_HOME or ~/.config)/fastfetch/config.jsonc, then the
    /// copy Perihelion ships. Null for "none" or when there is none.
    fn findConfig(self: *Service, spec: []const u8, buf: []u8) ?[]const u8 {
        if (std.ascii.eqlIgnoreCase(spec, "none")) return null;
        var pb: [320]u8 = undefined;
        if (spec.len > 0) {
            const p = (if (std.mem.startsWith(u8, spec, "~/"))
                pathZ(&pb, "{s}{s}", .{ self.home.slice(), spec[1..] })
            else
                pathZ(&pb, "{s}", .{spec})) orelse return null;
            const text = readFile(p, buf) orelse return null;
            self.config_path.set(p);
            return text;
        }
        const xdg = env("XDG_CONFIG_HOME");
        if (xdg.len > 0 and self.root.len == 0) {
            if (pathZ(&pb, "{s}/fastfetch/config.jsonc", .{xdg})) |p| {
                if (readFile(p, buf)) |text| {
                    self.config_path.set(p);
                    return text;
                }
            }
        }
        if (pathZ(&pb, "{s}/.config/fastfetch/config.jsonc", .{self.home.slice()})) |p| {
            if (readFile(p, buf)) |text| {
                self.config_path.set(p);
                return text;
            }
        }
        if (pathZ(&pb, "{s}" ++ SHIPPED_CONFIG, .{self.root.slice()})) |p| {
            if (readFile(p, buf)) |text| {
                self.config_path.set(p);
                return text;
            }
        }
        return null;
    }

    fn useConfigLayout(self: *Service, text: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var derived: [16384]u8 = undefined;
        const plan = buildPlan(arena.allocator(), text, &self.rows, &derived) orelse return;
        self.layout = .config;
        self.row_count = plan.rows;
        self.palette = plan.palette;
        self.has_datetime = plan.datetime;
        // Native fields behind the rows: first paint, minute refresh, fallback.
        self.field_count = 0;
        for (self.rows[0..self.row_count]) |*r| {
            const f = r.field orelse continue;
            if (std.mem.indexOfScalar(Field, self.fields[0..self.field_count], f) != null) continue;
            self.fields[self.field_count] = f;
            self.field_count += 1;
        }
        if (plan.modules == 0 or !self.writeDerived(derived[0..plan.derived_len])) {
            // Nothing to run, or nowhere to put the derived config: the
            // card still follows the config's layout, filled natively.
            self.source = .native;
        }
    }

    /// The derived config goes to $XDG_RUNTIME_DIR (tmpfs, per user), else
    /// ~/.cache/perihelionbar. Written once per shell start.
    fn writeDerived(self: *Service, data: []const u8) bool {
        var pb: [320]u8 = undefined;
        const run = env("XDG_RUNTIME_DIR");
        const path = (if (run.len > 0 and self.root.len == 0)
            pathZ(&pb, "{s}/perihelion-fastfetch-card.jsonc", .{run})
        else
            pathZ(&pb, "{s}/.cache/perihelionbar/fastfetch-card.jsonc", .{self.home.slice()})) orelse return false;
        mkdirParents(path);
        var tb: [340]u8 = undefined;
        const tmp = pathZ(&tb, "{s}.tmp", .{path}) orelse return false;
        const raw = posix.system.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(posix.mode_t, 0o600));
        if (raw < 0) return false;
        const fd: posix.fd_t = @intCast(raw);
        var off: usize = 0;
        while (off < data.len) {
            const n = std.c.write(fd, data.ptr + off, data.len - off);
            if (n <= 0) break;
            off += @intCast(n);
        }
        _ = posix.system.close(fd);
        if (off != data.len or std.c.rename(tmp.ptr, path.ptr) != 0) return false;
        self.derived_path.set(path);
        return true;
    }

    pub fn shownFields(self: *const Service) []const Field {
        return self.fields[0..self.field_count];
    }

    pub fn value(self: *const Service, f: Field) []const u8 {
        return self.values[@intFromEnum(f)].slice();
    }

    pub fn logoLines(self: *const Service) []const Text(256) {
        return self.logo[0..self.logo_count];
    }

    /// Host tick. True when a row the card shows changed.
    pub fn tick(self: *Service, now_ms: i64) bool {
        if (!self.started) {
            self.started = true;
            self.collectNative(.all);
            self.syncRows(.all);
            self.next_live_ms = now_ms + self.liveDelay();
            self.next_static_ms = if (self.refresh_ms > 0) now_ms + self.refresh_ms else std.math.maxInt(i64);
            self.next_run_ms = now_ms; // first fastfetch run right away
            return self.rehash();
        }
        var did = false;
        if (now_ms >= self.next_live_ms) {
            self.collectNative(.live);
            self.syncRows(.live);
            self.next_live_ms = now_ms + self.liveDelay();
            did = true;
        }
        // With no binary, the static rows are re-read natively on the
        // fastfetch schedule instead (packages after an update, theme…).
        if (self.source == .native and now_ms >= self.next_static_ms) {
            self.collectNative(.static);
            self.syncRows(.static);
            self.next_static_ms = if (self.refresh_ms > 0) now_ms + self.refresh_ms else std.math.maxInt(i64);
            did = true;
        }
        return did and self.rehash();
    }

    /// With a date/time row, refresh on the minute so the clock is right;
    /// otherwise every 60 s from now.
    fn liveDelay(self: *const Service) i64 {
        if (!self.has_datetime) return LIVE_MS;
        const now_s = libc.time(null);
        return (60 - @mod(now_s, 60)) * 1000 + 50;
    }

    /// Native values into the config layout's rows: everything on first
    /// paint (until the binary answers), live rows every minute.
    fn syncRows(self: *Service, which: Which) void {
        if (self.layout != .config) return;
        for (self.rows[0..self.row_count]) |*r| {
            if (r.kind != .row) continue;
            const f = r.field orelse continue;
            const v = self.value(f);
            if (v.len == 0) continue;
            const live = r.live != .none;
            const take = switch (which) {
                .live => live,
                .all, .static => live or !r.fresh,
            };
            if (take) r.value.set(v);
        }
    }

    /// The script and its $1 for this layout (see RUN_CMD/RUN_CMD_CONFIG).
    pub fn runScript(self: *const Service) [:0]const u8 {
        return if (self.layout == .config) RUN_CMD_CONFIG else RUN_CMD;
    }

    pub fn runArgZ(self: *const Service) [:0]const u8 {
        return if (self.layout == .config) self.derived_path.z() else self.structure.z();
    }

    /// True when the host should run runScript() now with argv
    /// {"/bin/sh", "-c", runScript(), binZ(), runArgZ()}.
    pub fn wantRun(self: *Service, now_ms: i64) bool {
        if (self.source == .native or self.in_flight or now_ms < self.next_run_ms) return false;
        self.in_flight = true;
        self.next_run_ms = if (self.refresh_ms > 0) now_ms + self.refresh_ms else std.math.maxInt(i64);
        return true;
    }

    pub fn binZ(self: *const Service) [:0]const u8 {
        return self.bin.z();
    }

    pub fn structureZ(self: *const Service) [:0]const u8 {
        return self.structure.z();
    }

    /// The fastfetch run ended (`body` = its stdout, empty on failure).
    /// True when a shown row changed.
    pub fn runComplete(self: *Service, body: []const u8, now_ms: i64) bool {
        self.in_flight = false;
        if (self.layout == .config) {
            var seen_rows = [_]bool{false} ** MAX_ROWS;
            var got_rows: usize = 0;
            var tlines = std.mem.splitScalar(u8, body, '\n');
            while (tlines.next()) |line| {
                const tg = parseTagged(line) orelse continue;
                for (self.rows[0..self.row_count], 0..) |*r, i| {
                    if (r.module != tg.idx) continue;
                    got_rows += 1;
                    if (!seen_rows[i]) {
                        r.value.set(tg.value);
                    } else {
                        // Several lines (two GPUs, three disks): one row.
                        var jb: [256]u8 = undefined;
                        if (std.fmt.bufPrint(&jb, "{s}, {s}", .{ r.value.slice(), tg.value })) |joined| r.value.set(joined) else |_| {}
                    }
                    seen_rows[i] = true;
                    r.fresh = true;
                }
            }
            if (got_rows == 0) self.dropSource(now_ms);
            return self.rehash();
        }
        var seen = [_]bool{false} ** FIELD_COUNT;
        var disk_root = false;
        var got: usize = 0;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const row = parseRow(line) orelse continue;
            const idx = @intFromEnum(row.field);
            if (std.mem.indexOfScalar(Field, self.shownFields(), row.field) == null) continue;
            got += 1;
            const v = &self.values[idx];
            switch (row.field) {
                // Several GPUs / displays: one row, comma-joined.
                .gpu, .display => {
                    if (!seen[idx]) {
                        v.set(row.value);
                    } else {
                        var jb: [256]u8 = undefined;
                        // Too long to join: keep what's there (never set()
                        // a value from its own buffer — @memcpy can't alias).
                        if (std.fmt.bufPrint(&jb, "{s}, {s}", .{ v.slice(), row.value })) |joined| v.set(joined) else |_| {}
                    }
                },
                // Several disks: the root filesystem wins.
                .disk => {
                    if (!disk_root) {
                        v.set(row.value);
                        disk_root = std.mem.eql(u8, row.qualifier, "/");
                    }
                },
                else => v.set(row.value),
            }
            seen[idx] = true;
        }
        if (got == 0) self.dropSource(now_ms);
        return self.rehash();
    }

    /// The binary printed nothing usable (not fastfetch-compatible, broken,
    /// missing): drop to the next source down.
    fn dropSource(self: *Service, now_ms: i64) void {
        if (self.source != .system and self.fallback_bin.len > 0 and
            !std.mem.eql(u8, self.fallback_bin.slice(), self.bin.slice()))
        {
            self.source = .system;
            self.bin = self.fallback_bin;
            self.next_run_ms = now_ms; // try it on the next tick
        } else {
            self.source = .native;
            self.collectNative(.static);
            self.syncRows(.static);
            self.next_static_ms = if (self.refresh_ms > 0) now_ms + self.refresh_ms else std.math.maxInt(i64);
        }
    }

    fn rehash(self: *Service) bool {
        var h = std.hash.Wyhash.init(0);
        h.update(self.title.slice());
        if (self.layout == .config) {
            for (self.cardRows()) |*r| {
                h.update(r.value.slice());
                h.update("\x00");
            }
        } else for (self.shownFields()) |f| {
            h.update(self.value(f));
            h.update("\x00");
        }
        const v = h.final();
        if (v == self.shown_hash) return false;
        self.shown_hash = v;
        return true;
    }

    fn buildStructure(self: *Service) void {
        var b: [160]u8 = undefined;
        var len: usize = 0;
        for (self.shownFields()) |f| {
            const sep: []const u8 = if (len > 0) ":" else "";
            const part = std.fmt.bufPrint(b[len..], "{s}{s}", .{ sep, @tagName(f) }) catch break;
            len += part.len;
        }
        self.structure.set(b[0..len]);
    }

    fn findOnPath(name: []const u8, out: *Text(256)) bool {
        var zb: [300]u8 = undefined;
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            const z = pathZ(&zb, "{s}", .{name}) orelse return false;
            if (libc.access(z.ptr, X_OK) != 0) return false;
            out.set(name);
            return true;
        }
        var it = std.mem.splitScalar(u8, env("PATH"), ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const z = pathZ(&zb, "{s}/{s}", .{ dir, name }) orelse continue;
            if (libc.access(z.ptr, X_OK) != 0) continue;
            out.set(z);
            return true;
        }
        return false;
    }

    fn detectSource(self: *Service, binary: []const u8) void {
        _ = findOnPath(SYSTEM_BINARY, &self.fallback_bin);
        if (std.ascii.eqlIgnoreCase(binary, "none")) {
            self.source = .native;
            return;
        }
        if (binary.len > 0) {
            var home_buf: [300]u8 = undefined;
            const p = if (std.mem.startsWith(u8, binary, "~/"))
                (std.fmt.bufPrint(&home_buf, "{s}{s}", .{ self.home.slice(), binary[1..] }) catch binary)
            else
                binary;
            if (findOnPath(p, &self.bin)) {
                self.source = .custom;
                return;
            }
            // Not found: fall through to auto-detection (the host logs it).
        }
        if (findOnPath(PERIHELION_BINARY, &self.bin)) {
            self.source = .perihelion;
        } else if (self.fallback_bin.len > 0) {
            self.bin = self.fallback_bin;
            self.source = .system;
        } else {
            self.source = .native;
        }
    }

    fn loadLogo(self: *Service, spec: []const u8, cfg_text: ?[]const u8) void {
        self.logo_count = 0;
        self.logo_cols = 0;
        if (std.ascii.eqlIgnoreCase(spec, "none")) {
            self.logo_off = true;
            return;
        }
        if (std.ascii.eqlIgnoreCase(spec, "distro")) return;
        var src_buf: [320]u8 = undefined;
        var src: []const u8 = spec;
        if (spec.len == 0 or std.ascii.eqlIgnoreCase(spec, "auto")) {
            // The fastfetch config the card found (Perihelion's points at
            // the feather logo); with fastfetch_config "none", still the
            // user's own config for the logo.
            var text_buf: [16384]u8 = undefined;
            const text = cfg_text orelse blk: {
                var cb: [320]u8 = undefined;
                const xdg = env("XDG_CONFIG_HOME");
                const cfg_path = (if (xdg.len > 0 and self.root.len == 0)
                    pathZ(&cb, "{s}/fastfetch/config.jsonc", .{xdg})
                else
                    pathZ(&cb, "{s}/.config/fastfetch/config.jsonc", .{self.home.slice()})) orelse return;
                break :blk readFile(cfg_path, &text_buf) orelse return;
            };
            const s = logoSourceFromConfig(text) orelse return;
            if (s.len > src_buf.len) return;
            @memcpy(src_buf[0..s.len], s);
            src = src_buf[0..s.len];
        }
        if (isImagePath(src)) return; // image logos are the terminal's business
        var pb: [400]u8 = undefined;
        const path = (if (std.mem.startsWith(u8, src, "~/"))
            pathZ(&pb, "{s}{s}", .{ self.home.slice(), src[1..] })
        else
            pathZ(&pb, "{s}", .{src})) orelse return;
        var lb: [8192]u8 = undefined;
        const text = readFile(path, &lb) orelse return;
        if (std.mem.indexOfScalar(u8, text, 0) != null) return; // binary, not a text logo
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            if (self.logo_count == MAX_LOGO_LINES) break;
            const line = std.mem.trimEnd(u8, raw, " \r");
            self.logo[self.logo_count].set(line);
            self.logo_cols = @max(self.logo_cols, logoCols(line));
            self.logo_count += 1;
        }
        // Trailing blank lines would only add height.
        while (self.logo_count > 0 and self.logo[self.logo_count - 1].len == 0) self.logo_count -= 1;
    }

    // --- native collection ---

    const Which = enum { all, live, static };

    fn wants(self: *const Service, f: Field, which: Which) bool {
        if (std.mem.indexOfScalar(Field, self.shownFields(), f) == null) return false;
        return switch (which) {
            .all => true,
            .live => f.isLive(),
            .static => !f.isLive(),
        };
    }

    fn collectNative(self: *Service, which: Which) void {
        const root = self.root.slice();
        var uts: Utsname = undefined;
        const have_uts = libc.uname(&uts) == 0;
        if (which != .live) {
            const user = env("USER");
            const host = if (have_uts) cstr(&uts.nodename) else "localhost";
            var tb: [96]u8 = undefined;
            self.title.set(std.fmt.bufPrint(&tb, "{s}@{s}", .{ if (user.len > 0) user else "user", host }) catch host);
        }
        var buf: [4096]u8 = undefined;
        var out: [256]u8 = undefined;
        var pb: [320]u8 = undefined;

        if (self.wants(.os, which) or (which != .live and self.distro_id.len == 0)) {
            if (pathZ(&pb, "{s}/etc/os-release", .{root})) |p| {
                if (readFile(p, &buf)) |t| {
                    if (keyValue(t, "ID")) |id| self.distro_id.set(id);
                    if (self.wants(.os, which)) {
                        const name = keyValue(t, "PRETTY_NAME") orelse keyValue(t, "NAME") orelse "Linux";
                        const arch = if (have_uts) cstr(&uts.machine) else "";
                        self.setVal(.os, std.fmt.bufPrint(&out, "{s} {s}", .{ name, arch }) catch name);
                    }
                }
            }
        }
        if (self.wants(.kernel, which) and have_uts) {
            self.setVal(.kernel, std.fmt.bufPrint(&out, "{s} {s}", .{ cstr(&uts.sysname), cstr(&uts.release) }) catch "");
        }
        if (self.wants(.host, which)) self.collectHost(root, &buf, &out);
        if (self.wants(.uptime, which)) {
            if (pathZ(&pb, "{s}/proc/uptime", .{root})) |p| {
                if (readTrim(p, &buf)) |t| {
                    const sp = std.mem.indexOfAny(u8, t, " .") orelse t.len;
                    const secs = std.fmt.parseInt(u64, t[0..sp], 10) catch 0;
                    self.setVal(.uptime, fmtUptime(&out, secs));
                }
            }
        }
        if (self.wants(.memory, which)) {
            if (pathZ(&pb, "{s}/proc/meminfo", .{root})) |p| {
                if (readFile(p, &buf)) |t| {
                    const total = meminfoKb(t, "MemTotal:") orelse 0;
                    const avail = meminfoKb(t, "MemAvailable:") orelse total;
                    if (total > 0) self.setVal(.memory, fmtUsage(&out, (total -| avail) * 1024, total * 1024));
                }
            }
        }
        if (self.wants(.disk, which)) self.collectDisk(root, &buf, &out);
        if (self.wants(.packages, which)) self.collectPackages(root, &out);
        if (self.wants(.shell, which)) {
            const sh = env("SHELL");
            const base = if (std.mem.lastIndexOfScalar(u8, sh, '/')) |i| sh[i + 1 ..] else sh;
            if (base.len > 0) self.setVal(.shell, base);
        }
        if (self.wants(.wm, which) or self.wants(.de, which)) {
            var name = env("XDG_CURRENT_DESKTOP");
            if (std.mem.indexOfScalar(u8, name, ':')) |i| name = name[0..i];
            if (name.len == 0) name = env("XDG_SESSION_DESKTOP");
            if (name.len == 0) name = env("DESKTOP_SESSION");
            if (name.len > 0 and self.wants(.de, which)) self.setVal(.de, name);
            if (name.len > 0 and self.wants(.wm, which)) {
                var nb: [64]u8 = undefined;
                const n = @min(name.len, nb.len);
                @memcpy(nb[0..n], name[0..n]);
                nb[0] = std.ascii.toUpper(nb[0]);
                const proto: []const u8 = if (env("WAYLAND_DISPLAY").len > 0) " (Wayland)" else if (env("DISPLAY").len > 0) " (X11)" else "";
                self.setVal(.wm, std.fmt.bufPrint(&out, "{s}{s}", .{ nb[0..n], proto }) catch nb[0..n]);
            }
        }
        if (self.wants(.theme, which) or self.wants(.icons, which) or self.wants(.font, which)) {
            self.collectGtk(&buf);
        }
        if (self.wants(.datetime, which)) self.setVal(.datetime, localTimeText(&out));
        if (self.wants(.bios, which)) {
            var vb: [64]u8 = undefined;
            var db: [64]u8 = undefined;
            const vp = pathZ(&pb, "{s}/sys/class/dmi/id/bios_version", .{root});
            const ver = if (vp) |p| readTrim(p, &vb) else null;
            if (ver) |v| {
                const dp = pathZ(&pb, "{s}/sys/class/dmi/id/bios_date", .{root});
                const date = if (dp) |p| readTrim(p, &db) else null;
                if (date) |d| {
                    self.setVal(.bios, std.fmt.bufPrint(&out, "{s} ({s})", .{ v, d }) catch v);
                } else {
                    self.setVal(.bios, v);
                }
            }
        }
        if (self.wants(.cpu, which)) self.collectCpu(root, &buf, &out);
        if (self.wants(.gpu, which)) self.collectGpu(root, &out);
        if (self.wants(.display, which)) self.collectDisplays(root, &out);
    }

    fn setVal(self: *Service, f: Field, v: []const u8) void {
        self.values[@intFromEnum(f)].set(v);
    }

    fn meminfoKb(text: []const u8, key: []const u8) ?u64 {
        const i = std.mem.indexOf(u8, text, key) orelse return null;
        var rest = std.mem.trimStart(u8, text[i + key.len ..], " \t");
        const end = std.mem.indexOfAny(u8, rest, " \n") orelse rest.len;
        rest = rest[0..end];
        return std.fmt.parseInt(u64, rest, 10) catch null;
    }

    fn collectHost(self: *Service, root: []const u8, buf: []u8, out: []u8) void {
        const junk = [_][]const u8{ "To be filled by O.E.M.", "Default string", "System Product Name", "System Version", "Not Applicable", "None", "Not Specified" };
        var pb: [320]u8 = undefined;
        var vb: [96]u8 = undefined;
        const name_p = pathZ(&pb, "{s}/sys/class/dmi/id/product_name", .{root}) orelse return;
        if (readTrim(name_p, buf)) |name| {
            for (junk) |j| {
                if (std.mem.eql(u8, name, j)) return self.collectDtModel(root, buf);
            }
            const n = @min(name.len, 96);
            var nb: [96]u8 = undefined;
            @memcpy(nb[0..n], name[0..n]);
            const ver_p = pathZ(&pb, "{s}/sys/class/dmi/id/product_version", .{root}) orelse return;
            const ver = readTrim(ver_p, &vb);
            var good_ver = ver != null;
            if (ver) |v| {
                for (junk) |j| {
                    if (std.mem.eql(u8, v, j)) good_ver = false;
                }
            }
            if (good_ver) {
                self.setVal(.host, std.fmt.bufPrint(out, "{s} ({s})", .{ nb[0..n], ver.? }) catch nb[0..n]);
            } else {
                self.setVal(.host, nb[0..n]);
            }
            return;
        }
        self.collectDtModel(root, buf);
    }

    /// ARM boards: the devicetree model string.
    fn collectDtModel(self: *Service, root: []const u8, buf: []u8) void {
        var pb: [320]u8 = undefined;
        const p = pathZ(&pb, "{s}/sys/firmware/devicetree/base/model", .{root}) orelse return;
        if (readTrim(p, buf)) |m| self.setVal(.host, m);
    }

    fn collectDisk(self: *Service, root: []const u8, buf: []u8, out: []u8) void {
        var st: Statvfs = undefined;
        var pb: [320]u8 = undefined;
        const mount = pathZ(&pb, "{s}/", .{root}) orelse return;
        if (libc.statvfs(mount.ptr, &st) != 0 or st.f_blocks == 0) return;
        const total = st.f_blocks * st.f_frsize;
        const used = (st.f_blocks - st.f_bfree) * st.f_frsize;
        var ub: [96]u8 = undefined;
        const usage = fmtUsage(&ub, used, total);
        // fastfetch appends the filesystem type: "… (16%) - btrfs".
        var fstype: []const u8 = "";
        if (pathZ(&pb, "{s}/proc/mounts", .{root})) |mp| {
            if (readFile(mp, buf)) |t| {
                var it = std.mem.splitScalar(u8, t, '\n');
                while (it.next()) |line| {
                    var f = std.mem.tokenizeScalar(u8, line, ' ');
                    _ = f.next() orelse continue;
                    const mnt = f.next() orelse continue;
                    const ty = f.next() orelse continue;
                    if (std.mem.eql(u8, mnt, "/")) fstype = ty; // last one wins (overmounts)
                }
            }
        }
        if (fstype.len > 0) {
            self.setVal(.disk, std.fmt.bufPrint(out, "{s} - {s}", .{ usage, fstype }) catch usage);
        } else {
            self.setVal(.disk, usage);
        }
    }

    fn collectPackages(self: *Service, root: []const u8, out: []u8) void {
        var pb: [320]u8 = undefined;
        var len: usize = 0;
        const sources = [_]struct { rel: []const u8, user: bool, skip: []const u8, tag: []const u8 }{
            .{ .rel = "/var/lib/pacman/local", .user = false, .skip = "ALPM_DB_VERSION", .tag = "pacman" },
            .{ .rel = "/var/lib/flatpak/app", .user = false, .skip = "", .tag = "flatpak-system" },
            .{ .rel = "/.local/share/flatpak/app", .user = true, .skip = "", .tag = "flatpak-user" },
        };
        for (sources) |src| {
            const p = (if (src.user)
                pathZ(&pb, "{s}{s}", .{ self.home.slice(), src.rel })
            else
                pathZ(&pb, "{s}{s}", .{ root, src.rel })) orelse continue;
            const n = countDir(p, src.skip);
            if (n == 0) continue;
            const sep: []const u8 = if (len > 0) ", " else "";
            const part = std.fmt.bufPrint(out[len..], "{s}{d} ({s})", .{ sep, n, src.tag }) catch break;
            len += part.len;
        }
        if (len > 0) self.setVal(.packages, out[0..len]);
    }

    fn collectGtk(self: *Service, buf: []u8) void {
        var pb: [320]u8 = undefined;
        const xdg = env("XDG_CONFIG_HOME");
        const p = (if (xdg.len > 0 and self.root.len == 0)
            pathZ(&pb, "{s}/gtk-3.0/settings.ini", .{xdg})
        else
            pathZ(&pb, "{s}/.config/gtk-3.0/settings.ini", .{self.home.slice()})) orelse return;
        const t = readFile(p, buf) orelse return;
        var out: [160]u8 = undefined;
        if (keyValue(t, "gtk-theme-name")) |v| self.setVal(.theme, std.fmt.bufPrint(&out, "{s} [GTK3]", .{v}) catch v);
        if (keyValue(t, "gtk-icon-theme-name")) |v| self.setVal(.icons, std.fmt.bufPrint(&out, "{s} [GTK3]", .{v}) catch v);
        if (keyValue(t, "gtk-font-name")) |v| self.setVal(.font, std.fmt.bufPrint(&out, "{s} [GTK3]", .{v}) catch v);
    }

    fn collectCpu(self: *Service, root: []const u8, buf: []u8, out: []u8) void {
        var pb: [320]u8 = undefined;
        var model: []const u8 = "";
        var mb: [128]u8 = undefined;
        if (pathZ(&pb, "{s}/proc/cpuinfo", .{root})) |p| {
            // The model name is in the first CPU's block: 4 KB is plenty
            // even on a 64-thread machine.
            if (readFile(p, buf)) |t| {
                var it = std.mem.splitScalar(u8, t, '\n');
                while (it.next()) |line| {
                    const keys = [_][]const u8{ "model name", "Hardware", "Model" };
                    for (keys) |k| {
                        if (!std.mem.startsWith(u8, line, k)) continue;
                        const c = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                        const v = std.mem.trim(u8, line[c + 1 ..], " \t");
                        const n = @min(v.len, mb.len);
                        @memcpy(mb[0..n], v[0..n]);
                        model = mb[0..n];
                    }
                    if (model.len > 0) break;
                }
            }
        }
        if (model.len == 0) return;
        var count: usize = 0;
        if (pathZ(&pb, "{s}/sys/devices/system/cpu/present", .{root})) |p| {
            var cb: [64]u8 = undefined;
            if (readTrim(p, &cb)) |ranges| count = countCpuRanges(ranges);
        }
        var ghz: f64 = 0;
        if (pathZ(&pb, "{s}/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq", .{root})) |p| {
            var fb: [32]u8 = undefined;
            if (readTrim(p, &fb)) |khz| ghz = @as(f64, @floatFromInt(std.fmt.parseInt(u64, khz, 10) catch 0)) / 1_000_000.0;
        }
        var cb2: [32]u8 = undefined;
        const cnt: []const u8 = if (count > 0) (std.fmt.bufPrint(&cb2, " ({d})", .{count}) catch "") else "";
        if (ghz > 0) {
            self.setVal(.cpu, std.fmt.bufPrint(out, "{s}{s} @ {d:.2} GHz", .{ model, cnt, ghz }) catch model);
        } else {
            self.setVal(.cpu, std.fmt.bufPrint(out, "{s}{s}", .{ model, cnt }) catch model);
        }
    }

    fn collectGpu(self: *Service, root: []const u8, out: []u8) void {
        var len: usize = 0;
        var pb: [320]u8 = undefined;
        var have_nvidia_model = false;
        // Proprietary NVIDIA: the driver names its GPUs under /proc.
        if (pathZ(&pb, "{s}/proc/driver/nvidia/gpus", .{root})) |np| {
            if (libc.opendir(np.ptr)) |d| {
                defer _ = libc.closedir(d);
                while (libc.readdir(d)) |e| {
                    const addr = std.mem.sliceTo(&e.d_name, 0);
                    if (addr.len == 0 or addr[0] == '.') continue;
                    var ib: [320]u8 = undefined;
                    const ip = pathZ(&ib, "{s}/proc/driver/nvidia/gpus/{s}/information", .{ root, addr }) orelse continue;
                    var tb: [1024]u8 = undefined;
                    const t = readFile(ip, &tb) orelse continue;
                    const model = blk: {
                        var it = std.mem.splitScalar(u8, t, '\n');
                        while (it.next()) |line| {
                            if (!std.mem.startsWith(u8, line, "Model:")) continue;
                            break :blk std.mem.trim(u8, line["Model:".len..], " \t");
                        }
                        break :blk "NVIDIA GPU";
                    };
                    const sep: []const u8 = if (len > 0) ", " else "";
                    const part = std.fmt.bufPrint(out[len..], "{s}{s}", .{ sep, model }) catch break;
                    len += part.len;
                    have_nvidia_model = true;
                }
            }
        }
        if (pathZ(&pb, "{s}/sys/class/drm", .{root})) |dp| {
            if (libc.opendir(dp.ptr)) |d| {
                defer _ = libc.closedir(d);
                while (libc.readdir(d)) |e| {
                    const card = std.mem.sliceTo(&e.d_name, 0);
                    if (!std.mem.startsWith(u8, card, "card") or card.len == 4) continue;
                    _ = std.fmt.parseInt(u8, card[4..], 10) catch continue; // skip connectors
                    var vb: [320]u8 = undefined;
                    var tb: [128]u8 = undefined;
                    const vp = pathZ(&vb, "{s}/sys/class/drm/{s}/device/vendor", .{ root, card }) orelse continue;
                    const vendor = readTrim(vp, &tb) orelse continue;
                    var name: []const u8 = if (std.mem.eql(u8, vendor, "0x1002"))
                        "AMD Radeon Graphics"
                    else if (std.mem.eql(u8, vendor, "0x8086"))
                        "Intel Graphics"
                    else if (std.mem.eql(u8, vendor, "0x10de"))
                        (if (have_nvidia_model) continue else "NVIDIA GPU")
                    else
                        continue;
                    var nb2: [128]u8 = undefined;
                    const pp = pathZ(&vb, "{s}/sys/class/drm/{s}/device/product_name", .{ root, card }) orelse continue;
                    if (readTrim(pp, &nb2)) |pn| name = pn;
                    const sep: []const u8 = if (len > 0) ", " else "";
                    const part = std.fmt.bufPrint(out[len..], "{s}{s}", .{ sep, name }) catch break;
                    len += part.len;
                }
            }
        }
        if (len > 0) self.setVal(.gpu, out[0..len]);
    }

    /// Connected outputs' preferred modes ("2560x1440, 1920x1080").
    fn collectDisplays(self: *Service, root: []const u8, out: []u8) void {
        var len: usize = 0;
        var pb: [320]u8 = undefined;
        const dp = pathZ(&pb, "{s}/sys/class/drm", .{root}) orelse return;
        const d = libc.opendir(dp.ptr) orelse return;
        defer _ = libc.closedir(d);
        while (libc.readdir(d)) |e| {
            const conn = std.mem.sliceTo(&e.d_name, 0);
            if (!std.mem.startsWith(u8, conn, "card") or std.mem.indexOfScalar(u8, conn, '-') == null) continue;
            var sb: [320]u8 = undefined;
            var tb: [32]u8 = undefined;
            const sp = pathZ(&sb, "{s}/sys/class/drm/{s}/status", .{ root, conn }) orelse continue;
            const status = readTrim(sp, &tb) orelse continue;
            if (!std.mem.eql(u8, status, "connected")) continue;
            var mb: [512]u8 = undefined;
            const mp = pathZ(&sb, "{s}/sys/class/drm/{s}/modes", .{ root, conn }) orelse continue;
            const modes = readTrim(mp, &mb) orelse continue;
            const first = if (std.mem.indexOfScalar(u8, modes, '\n')) |i| modes[0..i] else modes;
            const sep: []const u8 = if (len > 0) ", " else "";
            const part = std.fmt.bufPrint(out[len..], "{s}{s}", .{ sep, first }) catch break;
            len += part.len;
        }
        if (len > 0) self.setVal(.display, out[0..len]);
    }
};

/// "0-15" → 16, "0-3,8-11" → 8, "0" → 1.
fn countCpuRanges(s: []const u8) usize {
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const a = std.fmt.parseInt(usize, part[0..dash], 10) catch continue;
            const b = std.fmt.parseInt(usize, part[dash + 1 ..], 10) catch continue;
            if (b >= a) total += b - a + 1;
        } else if (std.fmt.parseInt(usize, part, 10)) |_| {
            total += 1;
        } else |_| {}
    }
    return total;
}

// --- tests -----------------------------------------------------------------------------------

test "fastfetch rows map to fields" {
    const r = parseRow("GPU 2: AMD Radeon RX 7800 XT [Discrete]").?;
    try std.testing.expectEqual(Field.gpu, r.field);
    try std.testing.expectEqualStrings("AMD Radeon RX 7800 XT [Discrete]", r.value);
    const d = parseRow("Disk (/home): 120.50 GiB / 931.51 GiB (13%) - ext4").?;
    try std.testing.expectEqual(Field.disk, d.field);
    try std.testing.expectEqualStrings("/home", d.qualifier);
    try std.testing.expectEqual(Field.display, parseRow("Display (DP-1): 2560x1440 @ 144 Hz").?.field);
    try std.testing.expectEqual(Field.wm, parseRow("WM: Mango (Wayland)").?.field);
    try std.testing.expect(parseRow("Terminal: foot") == null); // not a card field
    try std.testing.expect(parseRow("user@host") == null);
    try std.testing.expect(parseRow("OS: ") == null);
}

test "runComplete: joins GPUs, prefers the root disk, falls back when empty" {
    var s = Service{};
    const fs = [_]Field{ .os, .gpu, .disk, .memory };
    @memcpy(s.fields[0..fs.len], &fs);
    s.field_count = fs.len;
    s.source = .system;
    s.bin.set("/usr/bin/fastfetch");
    s.fallback_bin.set("/usr/bin/fastfetch");
    s.in_flight = true;
    const out =
        \\OS: Arch Linux x86_64
        \\GPU 1: AMD Radeon RX 7800 XT [Discrete]
        \\GPU 2: AMD Raphael [Integrated]
        \\Disk (/boot): 120.00 MiB / 1.00 GiB (12%) - vfat
        \\Disk (/): 75.20 GiB / 465.63 GiB (16%) - btrfs
        \\Disk (/home): 1.00 GiB / 2.00 GiB (50%) - ext4
        \\Memory: 5.01 GiB / 31.27 GiB (16%)
    ;
    try std.testing.expect(s.runComplete(out, 0));
    try std.testing.expect(!s.in_flight);
    try std.testing.expectEqualStrings("AMD Radeon RX 7800 XT [Discrete], AMD Raphael [Integrated]", s.value(.gpu));
    try std.testing.expectEqualStrings("75.20 GiB / 465.63 GiB (16%) - btrfs", s.value(.disk));
    // Same output again: nothing changed for the card.
    try std.testing.expect(!s.runComplete(out, 1));
    // The binary stops printing anything: no rows → native collector.
    _ = s.runComplete("", 2);
    try std.testing.expectEqual(Source.native, s.source);
}

test "a preferred binary that prints nothing falls back to stock fastfetch" {
    var s = Service{};
    s.fields[0] = .os;
    s.field_count = 1;
    s.source = .perihelion;
    s.bin.set("/usr/bin/perihelion-fastfetch");
    s.fallback_bin.set("/usr/bin/fastfetch");
    _ = s.runComplete("perihelion-fastfetch: unknown option -c\n", 5);
    try std.testing.expectEqual(Source.system, s.source);
    try std.testing.expectEqualStrings("/usr/bin/fastfetch", s.binZ());
    try std.testing.expect(s.wantRun(5)); // retried at once
}

test "formatting" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("2 days, 3 hours, 5 mins", fmtUptime(&b, 2 * 86400 + 3 * 3600 + 5 * 60 + 9));
    try std.testing.expectEqualStrings("1 hour, 1 min", fmtUptime(&b, 3660));
    try std.testing.expectEqualStrings("42 secs", fmtUptime(&b, 42));
    try std.testing.expectEqualStrings("1.00 GiB / 4.00 GiB (25%)", fmtUsage(&b, 1 << 30, 4 << 30));
    try std.testing.expectEqualStrings("512.00 MiB", fmtSize(&b, 512 << 20));
    try std.testing.expectEqual(@as(usize, 16), countCpuRanges("0-15"));
    try std.testing.expectEqual(@as(usize, 8), countCpuRanges("0-3,8-11"));
    try std.testing.expectEqual(@as(usize, 1), countCpuRanges("0"));
}

test "fields, logo source, logo columns, distro glyph" {
    var out: [FIELD_COUNT]Field = undefined;
    var unknown: usize = 0;
    const names = [_][]const u8{ "os", "cpu", "bogus", "os", "gpu" };
    const n = parseFields(&names, &out, &unknown);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(usize, 1), unknown);
    try std.testing.expectEqual(Field.gpu, out[2]);

    const cfg =
        \\{
        \\    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
        \\    "logo": {
        \\        "source": "~/.config/fastfetch/feather.txt",
        \\        "color": { "1": "blue", "2": "magenta" }
        \\    },
        \\    "modules": [ "break" ]
        \\}
    ;
    try std.testing.expectEqualStrings("~/.config/fastfetch/feather.txt", logoSourceFromConfig(cfg).?);
    try std.testing.expectEqualStrings("/x/l.txt", logoSourceFromConfig("{\"logo\": {\"color\": {\"1\": \"blue\"}, \"source\": \"/x/l.txt\"}}").?);
    try std.testing.expect(logoSourceFromConfig("{ \"logo\": \"arch\" }") == null);
    try std.testing.expect(logoSourceFromConfig("{ \"modules\": [] }") == null);

    try std.testing.expectEqual(@as(usize, 5), logoCols("  $2\u{2584}\u{2588}$1\u{2584}"));
    try std.testing.expectEqual(@as(u32, 0xF303), distroGlyph("arch"));
    try std.testing.expectEqual(@as(u32, 0xF31A), distroGlyph("slackware"));
    try std.testing.expect(isImagePath("~/Pictures/logo.PNG"));
}

// Fake trees for the native collector and logo loading.
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

fn writeFile(root: []const u8, rel: []const u8, content: []const u8, mode: posix.mode_t) void {
    var pb: [300]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ root, rel }) catch return;
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| mkdirP(p[0..slash]);
    var zb: [300]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{p}) catch return;
    const raw = posix.system.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode);
    if (raw < 0) return;
    const fd: posix.fd_t = @intCast(raw);
    _ = std.c.write(fd, content.ptr, content.len);
    _ = posix.system.close(fd);
}

test "native collection on a fake system, feather logo from the fastfetch config" {
    var rb: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&rb, "/tmp/perihelion-ff-test-{d}", .{std.c.getpid()}) catch unreachable;
    var hb: [80]u8 = undefined;
    const home = std.fmt.bufPrint(&hb, "{s}/home", .{root}) catch unreachable;
    writeFile(root, "etc/os-release", "NAME=\"Arch Linux\"\nPRETTY_NAME=\"Arch Linux\"\nID=arch\n", 0o644);
    writeFile(root, "proc/uptime", "93784.21 100000.00\n", 0o644);
    writeFile(root, "proc/meminfo", "MemTotal:       32768000 kB\nMemFree:  1000 kB\nMemAvailable:   24379392 kB\n", 0o644);
    writeFile(root, "proc/cpuinfo", "processor\t: 0\nvendor_id\t: AuthenticAMD\nmodel name\t: AMD Ryzen 7 7700X 8-Core Processor\n", 0o644);
    writeFile(root, "sys/devices/system/cpu/present", "0-15\n", 0o644);
    writeFile(root, "sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq", "5573000\n", 0o644);
    writeFile(root, "sys/class/dmi/id/product_name", "MS-7E12\n", 0o644);
    writeFile(root, "sys/class/dmi/id/product_version", "1.0\n", 0o644);
    writeFile(root, "sys/class/drm/card1/device/vendor", "0x1002\n", 0o644);
    writeFile(root, "sys/class/drm/card1-DP-1/status", "connected\n", 0o644);
    writeFile(root, "sys/class/drm/card1-DP-1/modes", "2560x1440\n1920x1080\n", 0o644);
    writeFile(root, "sys/class/drm/card1-HDMI-A-1/status", "disconnected\n", 0o644);
    writeFile(root, "var/lib/pacman/local/ALPM_DB_VERSION", "9\n", 0o644);
    writeFile(root, "var/lib/pacman/local/bash-5.2/desc", "x", 0o644);
    writeFile(root, "var/lib/pacman/local/zig-0.16/desc", "x", 0o644);
    writeFile(home, ".config/gtk-3.0/settings.ini", "[Settings]\ngtk-theme-name=adw-gtk3-dark\ngtk-icon-theme-name = Papirus-Dark\n", 0o644);
    writeFile(home, ".config/fastfetch/config.jsonc", "{ \"logo\": { \"source\": \"~/.config/fastfetch/feather.txt\" } }", 0o644);
    writeFile(home, ".config/fastfetch/feather.txt", "   $2\u{2584}\u{2588}\u{2584}\n  $1\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\n\n", 0o644);

    const fields = [_]Field{ .os, .host, .uptime, .packages, .cpu, .gpu, .memory, .display, .theme, .icons };
    var s = Service.init(.{ .fields = &fields, .binary = "none", .root = root, .home = home });
    // The fake config has a logo but no "modules": fields layout.
    try std.testing.expectEqual(Layout.fields, s.layout);
    try std.testing.expectEqual(Source.native, s.source);
    try std.testing.expect(s.tick(0));
    try std.testing.expect(std.mem.startsWith(u8, s.value(.os), "Arch Linux "));
    try std.testing.expectEqualStrings("MS-7E12 (1.0)", s.value(.host));
    try std.testing.expectEqualStrings("1 day, 2 hours, 3 mins", s.value(.uptime));
    try std.testing.expectEqualStrings("2 (pacman)", s.value(.packages));
    try std.testing.expectEqualStrings("AMD Ryzen 7 7700X 8-Core Processor (16) @ 5.57 GHz", s.value(.cpu));
    try std.testing.expectEqualStrings("AMD Radeon Graphics", s.value(.gpu));
    try std.testing.expectEqualStrings("8.00 GiB / 31.25 GiB (26%)", s.value(.memory));
    try std.testing.expectEqualStrings("2560x1440", s.value(.display));
    try std.testing.expectEqualStrings("adw-gtk3-dark [GTK3]", s.value(.theme));
    try std.testing.expectEqualStrings("Papirus-Dark [GTK3]", s.value(.icons));
    try std.testing.expectEqualStrings("arch", s.distro_id.slice());
    // Logo: two lines (trailing blank dropped), widest is 7 columns.
    try std.testing.expectEqual(@as(usize, 2), s.logoLines().len);
    try std.testing.expectEqual(@as(usize, 7), s.logo_cols);
    // Nothing due within the minute → no work, no repaint.
    try std.testing.expect(!s.tick(30_000));
    // Uptime moves on → the live refresh reports a change.
    writeFile(root, "proc/uptime", "97384.00 100000.00\n", 0o644);
    try std.testing.expect(s.tick(LIVE_MS));
    // No binary ever: wantRun never asks for a process.
    try std.testing.expect(!s.wantRun(LIVE_MS));
}

test "custom binary path is detected and preferred" {
    var rb: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&rb, "/tmp/perihelion-ff-bin-{d}", .{std.c.getpid()}) catch unreachable;
    writeFile(root, "bin/myfetch", "#!/bin/sh\necho 'OS: Test'\n", 0o755);
    var pb: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/bin/myfetch", .{root}) catch unreachable;
    const s = Service.init(.{ .binary = path, .config = "none", .logo = "none", .home = root });
    try std.testing.expectEqual(Source.custom, s.source);
    try std.testing.expectEqualStrings(path, s.binZ());
    try std.testing.expectEqualStrings("os:host:kernel:uptime:packages:shell:wm:cpu:gpu:memory:disk", s.structureZ());
    // A path that isn't executable falls back to auto-detection.
    writeFile(root, "bin/notexec", "x", 0o644);
    var nb: [96]u8 = undefined;
    const bad = std.fmt.bufPrint(&nb, "{s}/bin/notexec", .{root}) catch unreachable;
    const s2 = Service.init(.{ .binary = bad, .config = "none", .logo = "none", .home = root });
    try std.testing.expect(s2.source != .custom);
}

/// Perihelion's real fastfetch/config.jsonc (tabs as spaces), as shipped.
const PERIHELION_CONFIG =
    \\{
    \\    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    \\    "logo": {
    \\        "source": "~/.config/fastfetch/feather.txt",
    \\        "color": {
    \\            "1": "blue",
    \\            "2": "magenta"
    \\        },
    \\        "height": 19,
    \\        "width": 1,
    \\        "padding": {
    \\            "top": 1,
    \\            "left": 3
    \\        }
    \\    },
    \\    "modules": [
    \\        "break",
    \\        {
    \\            "type": "custom",
    \\            "format": "┌──────────────────────Hardware──────────────────────┐"
    \\        },
    \\        {
    \\            "type": "host",
    \\            "key": " PC",
    \\            "keyColor": "green"
    \\        },
    \\        {
    \\            "type": "cpu",
    \\            "key": "│ ├",
    \\            "keyColor": "green"
    \\        },
    \\        {
    \\            "type": "gpu",
    \\            "key": "│ ├󰍛",
    \\            "keyColor": "green"
    \\        },
    \\        {
    \\            "type": "memory",
    \\            "key": "│ ├󰍛",
    \\            "keyColor": "green"
    \\        },
    \\        {
    \\            "type": "disk",
    \\            "key": "└ └",
    \\            "keyColor": "green"
    \\        },
    \\        {
    \\            "type": "custom",
    \\            "format": "└────────────────────────────────────────────────────┘"
    \\        },
    \\        "break",
    \\        {
    \\            "type": "custom",
    \\            "format": "┌──────────────────────Software──────────────────────┐"
    \\        },
    \\        {
    \\            "type": "os",
    \\            "key": "󰻀 Linux distro",
    \\            "keyColor": "yellow"
    \\        },
    \\        {
    \\            "type": "kernel",
    \\            "key": "│ ├",
    \\            "keyColor": "yellow"
    \\        },
    \\        {
    \\            "type": "bios",
    \\            "key": "│ ├",
    \\            "keyColor": "yellow"
    \\        },
    \\        {
    \\            "type": "packages",
    \\            "key": "│ ├󰏖",
    \\            "keyColor": "yellow"
    \\        },
    \\        {
    \\            "type": "wm",
    \\            "key": "| |->",
    \\            "keyColor": "yellow"
    \\
    \\    },
    \\        {
    \\            "type": "custom",
    \\            "key": "└ └",
    \\            "format": "Perihelion Bar Shell",
    \\            "keyColor": "yellow"
    \\    },
    \\    {
    \\            "type": "custom",
    \\            "format": "└────────────────────────────────────────────────────┘"
    \\        },
    \\        "break",
    \\        {
    \\            "type": "custom",
    \\            "format": "┌───────────────────Uptime / Age / DT────────────────┐"
    \\        },
    \\        {
    \\            "type": "command",
    \\            "key": "  OS Age ",
    \\            "keyColor": "magenta",
    \\            "text": "birth_install=$(stat -c %W /); current=$(date +%s); time_progression=$((current - birth_install)); days_difference=$((time_progression / 86400)); echo $days_difference days"
    \\        },
    \\        {
    \\            "type": "uptime",
    \\            "key": "  Uptime ",
    \\            "keyColor": "magenta"
    \\        },
    \\        {
    \\            "type": "datetime",
    \\            "key": "  DateTime ",
    \\            "keyColor": "magenta"
    \\        },
    \\        {
    \\            "type": "custom",
    \\            "format": "└────────────────────────────────────────────────────┘"
    \\        },
    \\
    \\//        {
    \\//            "type": "colors"
    \\//        },
    \\
    \\        {
    \\            "type": "colors",
    \\            "paddingLeft": 0,
    \\            "symbol": "circle"
    \\        }
    \\
    \\    ]
    \\}
    ;

test "jsonc, labels and section titles" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const j = try stripJsonc(arena.allocator(), "{\"a\": \"x // not a comment\", // gone\n \"b\": [1, 2,], /* gone */ }");
    try std.testing.expectEqualStrings("{\"a\": \"x // not a comment\", \n \"b\": [1, 2]  }", j);

    var b: [96]u8 = undefined;
    try std.testing.expectEqualStrings("\u{F109} PC", deriveLabel("\u{F109} PC", "Host", &b));
    try std.testing.expectEqualStrings("\u{F4BC} CPU", deriveLabel("\u{2502} \u{251C}\u{F4BC}", "CPU", &b));
    try std.testing.expectEqualStrings("WM", deriveLabel("| |->", "WM", &b));
    try std.testing.expectEqualStrings("OS Age", deriveLabel("  OS Age ", "Command", &b));
    try std.testing.expectEqualStrings("\u{F489}", deriveLabel("\u{2514} \u{2514}\u{F489}", "", &b));
    try std.testing.expectEqualStrings("Hardware", sectionTitle("\u{250C}\u{2500}\u{2500}Hardware\u{2500}\u{2510}", &b).?);
    try std.testing.expectEqualStrings("Uptime / Age / DT", sectionTitle("\u{250C}\u{2500}Uptime / Age / DT\u{2500}\u{2510}", &b).?);
    try std.testing.expect(sectionTitle("\u{2514}\u{2500}\u{2500}\u{2518}", &b) == null);
}

test "Perihelion's config becomes sectioned rows and a tagged derived config" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var rows: [MAX_ROWS]CardRow = [_]CardRow{.{}} ** MAX_ROWS;
    var derived: [16384]u8 = undefined;
    const plan = buildPlan(arena.allocator(), PERIHELION_CONFIG, &rows, &derived).?;
    try std.testing.expect(plan.palette);
    try std.testing.expect(plan.datetime);
    // host cpu gpu memory disk | os kernel bios packages wm | command uptime
    try std.testing.expectEqual(@as(usize, 12), plan.modules);

    const R = struct { kind: RowKind, label: []const u8, module: i16 };
    const want = [_]R{
        .{ .kind = .header, .label = "Hardware", .module = -1 },
        .{ .kind = .row, .label = "\u{F109} PC", .module = 0 },
        .{ .kind = .row, .label = "\u{F4BC} CPU", .module = 1 },
        .{ .kind = .row, .label = "\u{F035B} GPU", .module = 2 },
        .{ .kind = .row, .label = "\u{F035B} Memory", .module = 3 },
        .{ .kind = .row, .label = "\u{F489} Disk", .module = 4 },
        .{ .kind = .spacer, .label = "", .module = -1 },
        .{ .kind = .header, .label = "Software", .module = -1 },
        .{ .kind = .row, .label = "\u{F0EC0} Linux distro", .module = 5 },
        .{ .kind = .row, .label = "\u{F013} Kernel", .module = 6 },
        .{ .kind = .row, .label = "\u{F013} BIOS", .module = 7 },
        .{ .kind = .row, .label = "\u{F03D6} Packages", .module = 8 },
        .{ .kind = .row, .label = "WM", .module = 9 },
        .{ .kind = .row, .label = "\u{F489}", .module = -1 },
        .{ .kind = .spacer, .label = "", .module = -1 },
        .{ .kind = .header, .label = "Uptime / Age / DT", .module = -1 },
        .{ .kind = .row, .label = "OS Age", .module = 10 },
        .{ .kind = .row, .label = "Uptime", .module = 11 },
        .{ .kind = .row, .label = "DateTime", .module = -1 },
    };
    try std.testing.expectEqual(want.len, plan.rows);
    for (want, 0..) |w, i| {
        try std.testing.expectEqual(w.kind, rows[i].kind);
        try std.testing.expectEqualStrings(w.label, rows[i].label.slice());
        try std.testing.expectEqual(w.module, rows[i].module);
    }
    try std.testing.expectEqualStrings("Perihelion Bar Shell", rows[13].value.slice());
    try std.testing.expectEqual(Live.memory, rows[4].live);
    try std.testing.expectEqual(Live.uptime, rows[17].live);
    try std.testing.expectEqual(Live.datetime, rows[18].live);

    // The derived config is valid JSON: no logo, every module keyed @@N,
    // the command module's shell text carried over untouched.
    const d = derived[0..plan.derived_len];
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), d, .{});
    try std.testing.expect(parsed.object.get("logo") == null);
    const mods = parsed.object.get("modules").?.array.items;
    try std.testing.expectEqual(@as(usize, 12), mods.len);
    try std.testing.expectEqualStrings("@@10", mods[10].object.get("key").?.string);
    try std.testing.expectEqualStrings("command", mods[10].object.get("type").?.string);
    try std.testing.expect(std.mem.indexOf(u8, mods[10].object.get("text").?.string, "stat -c %W /") != null);
    try std.testing.expect(mods[0].object.get("keyColor") == null);
    try std.testing.expectEqualStrings(": ", parsed.object.get("display").?.object.get("separator").?.string);
}

test "config layout: tagged output fills rows, repeats join, fallback to native" {
    var rb: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&rb, "/tmp/perihelion-ff-cfg-{d}", .{std.c.getpid()}) catch unreachable;
    var hb: [80]u8 = undefined;
    const home = std.fmt.bufPrint(&hb, "{s}/home", .{root}) catch unreachable;
    writeFile(home, ".config/fastfetch/config.jsonc", PERIHELION_CONFIG, 0o644);
    writeFile(home, ".config/fastfetch/feather.txt", "$1\u{2588}\n", 0o644);
    var s = Service.init(.{ .root = root, .home = home });
    try std.testing.expectEqual(Layout.config, s.layout);
    try std.testing.expect(std.mem.endsWith(u8, s.config_path.slice(), "/.config/fastfetch/config.jsonc"));
    try std.testing.expectEqual(@as(usize, 1), s.logoLines().len);
    if (s.source != .native) {
        // A derived config was written for the binary to run.
        try std.testing.expect(std.mem.endsWith(u8, s.runArgZ(), "fastfetch-card.jsonc"));
        try std.testing.expectEqualStrings(RUN_CMD_CONFIG, s.runScript());
    }
    s.source = .system;
    s.bin.set("/usr/bin/fastfetch");
    s.fallback_bin.set("/usr/bin/fastfetch");
    const out =
        \\@@0: MS-7E12 (1.0)
        \\@@2: AMD Radeon RX 7800 XT [Discrete]
        \\@@2: AMD Raphael [Integrated]
        \\
        \\@@10: 812 days
        \\noise without a tag
    ;
    try std.testing.expect(s.runComplete(out, 0));
    const rows = s.cardRows();
    try std.testing.expectEqualStrings("MS-7E12 (1.0)", rows[1].value.slice());
    try std.testing.expect(rows[1].fresh);
    try std.testing.expectEqualStrings("AMD Radeon RX 7800 XT [Discrete], AMD Raphael [Integrated]", rows[3].value.slice());
    try std.testing.expectEqualStrings("812 days", rows[16].value.slice());
    try std.testing.expect(!s.runComplete(out, 1)); // unchanged → no repaint
    _ = s.runComplete("", 2); // binary went quiet
    try std.testing.expectEqual(Source.native, s.source);
    try std.testing.expectEqualStrings("812 days", s.cardRows()[16].value.slice()); // kept
}
