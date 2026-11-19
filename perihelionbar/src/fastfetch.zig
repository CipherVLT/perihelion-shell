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
    extern "c" fn getuid() u32;
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
        buf: [N + 1]u8 = @as([N + 1]u8, @splat(0)),
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
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0) catch null;
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
        for (std.meta.tags(Field)) |v| {
            if (std.mem.eql(u8, key, v.label())) return v;
        }
        return null;
    }
};

pub const FIELD_COUNT = std.meta.tags(Field).len;
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
    /// Whose login shell to show (null = getuid()).
    uid: ?u32 = null,
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

// --- desktop readers: shell, terminal, terminal font, GTK theme ------------------------
//
// The card runs fastfetch from perihelion-shell, not from a terminal, so
// fastfetch's shell module names perihelion-shell, and its terminal,
// terminal-font and WM-theme modules find nothing (Mango has no theme of
// its own). Those four rows are filled here instead: the login shell from
// the passwd entry, the terminal the user would get (TERMINAL,
// xdg-terminal-exec's list, Mango's Super+Return bind, foot), that
// terminal's font from its config, and the GTK theme. Read once at start
// (a few small files); versions come from the regular fastfetch run.

/// Rows the card fills from the desktop rather than from fastfetch.
pub const Native = enum { none, shell, terminal, terminal_font, wm_theme };

/// What buildPlan needs to know about the desktop: binaries whose
/// `--version` the fastfetch run should print, and whether gsettings can
/// be asked for the GTK theme.
pub const Extras = struct {
    shell_path: []const u8 = "",
    term_path: []const u8 = "",
    gsettings: bool = false,
};

pub const GSETTINGS_THEME_CMD = "gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null";

pub fn baseName(p: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, p, "/");
    return if (std.mem.lastIndexOfScalar(u8, t, '/')) |i| t[i + 1 ..] else t;
}

/// Login shell of `uid` from passwd text (name:pw:uid:gid:gecos:home:shell).
pub fn passwdShell(text: []const u8, uid: u32) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        _ = f.next() orelse continue;
        _ = f.next() orelse continue;
        const u = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        if (u != uid) continue;
        _ = f.next() orelse continue;
        _ = f.next() orelse continue;
        _ = f.next() orelse continue;
        const sh = std.mem.trim(u8, f.next() orelse continue, " \t\r");
        return if (sh.len > 0) sh else null;
    }
    return null;
}

/// The version in a `--version` line: the first token that starts with a
/// digit and has a dot, cut at the first other character.
/// "GNU bash, version 5.2.37(1)-release" -> "5.2.37",
/// "fish, version 4.0.2", "kitty 0.39.1 created by …",
/// "foot version: 1.20.2 +pgo" -> the numbers.
pub fn parseVersion(line: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t,:");
    while (it.next()) |tok| {
        if (!std.ascii.isDigit(tok[0])) continue;
        var end: usize = 0;
        var dots: usize = 0;
        while (end < tok.len and (std.ascii.isDigit(tok[end]) or tok[end] == '.')) : (end += 1) {
            if (tok[end] == '.') dots += 1;
        }
        const v = std.mem.trimEnd(u8, tok[0..end], ".");
        if (dots > 0 and std.mem.indexOfScalar(u8, v, '.') != null) return v;
    }
    return null;
}

/// "name version" from a `--version` line, or just the name.
fn withVersion(out: []u8, name: []const u8, version_line: []const u8) []const u8 {
    const v = parseVersion(version_line) orelse return name;
    return std.fmt.bufPrint(out, "{s} {s}", .{ name, v }) catch name;
}

/// Terminal entries of an xdg-terminals.list, in order, as binary-ish
/// names ("foot.desktop" -> "foot", "com.mitchellh.ghostty.desktop" ->
/// "ghostty", "kitty.desktop:new-window" -> "kitty"). Comments,
/// directives ("/execarg…") and exclusions ("-name") are skipped.
pub fn xdgTerminalEntries(text: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (n == out.len) break;
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '/' or line[0] == '-') continue;
        if (line[0] == '+') line = line[1..];
        if (std.mem.indexOfScalar(u8, line, ':')) |c| line = line[0..c];
        if (std.mem.endsWith(u8, line, ".desktop")) line = line[0 .. line.len - ".desktop".len];
        if (std.mem.lastIndexOfScalar(u8, line, '.')) |d| line = line[d + 1 ..];
        if (line.len == 0) continue;
        out[n] = line;
        n += 1;
    }
    return n;
}

/// A desktop id that names a launcher rather than the terminal itself.
fn terminalBinary(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "foot-server") or std.mem.eql(u8, name, "footclient")) return "foot";
    return name;
}

/// The program Mango's Return binds spawn (the plain Super+Return one when
/// there are several): "bind=SUPER,Return,spawn,kitty" -> "kitty".
pub fn mangoTerminal(text: []const u8) ?[]const u8 {
    var first: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "bind")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        // bind, bindl, bindr, bindlr, binds (Mango's variants).
        const suffix = std.mem.trimEnd(u8, line[4..eq], " ");
        var name_ok = suffix.len <= 2;
        for (suffix) |ch| {
            if (std.mem.indexOfScalar(u8, "lrs", ch) == null) name_ok = false;
        }
        if (!name_ok) continue;
        var f = std.mem.splitScalar(u8, line[eq + 1 ..], ',');
        const mods = std.mem.trim(u8, f.next() orelse continue, " \t");
        const key = std.mem.trim(u8, f.next() orelse continue, " \t");
        const action = std.mem.trim(u8, f.next() orelse continue, " \t");
        const cmd = std.mem.trim(u8, f.rest(), " \t");
        if (!std.ascii.eqlIgnoreCase(key, "Return")) continue;
        if (!std.mem.eql(u8, action, "spawn") and !std.mem.eql(u8, action, "spawn_shell")) continue;
        var tok = std.mem.tokenizeAny(u8, cmd, " \t");
        const prog = baseName(tok.next() orelse continue);
        if (prog.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(mods, "SUPER")) return prog;
        if (first == null) first = prog;
    }
    return first;
}

/// Files a Mango config pulls in ("source=./cfg/keybinds.conf",
/// "source_optional=~/…"), in order.
pub fn mangoSources(text: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        const v = if (std.mem.startsWith(u8, line, "source="))
            line["source=".len..]
        else if (std.mem.startsWith(u8, line, "source_optional="))
            line["source_optional=".len..]
        else
            continue;
        const p = std.mem.trim(u8, v, " \t\"");
        if (p.len == 0) continue;
        out[n] = p;
        n += 1;
    }
    return n;
}

/// A terminal font as found in its config: family and size (either may be
/// missing; the reader fills in the terminal's defaults).
pub const TermFont = struct {
    family: Text(80) = .{},
    size: Text(16) = .{},

    /// "JetBrainsMono Nerd Font 11".
    pub fn format(self: *const TermFont, out: []u8) []const u8 {
        if (self.family.len == 0) return "";
        if (self.size.len == 0) return self.family.slice();
        return std.fmt.bufPrint(out, "{s} {s}", .{ self.family.slice(), self.size.slice() }) catch self.family.slice();
    }
};

/// "11.0" -> "11", "10.50" -> "10.5".
fn cleanSize(s: []const u8) []const u8 {
    var v = std.mem.trim(u8, s, " \t\"'");
    if (std.mem.indexOfScalar(u8, v, '.') != null) {
        v = std.mem.trimEnd(u8, v, "0");
        v = std.mem.trimEnd(u8, v, ".");
    }
    return v;
}

/// foot.ini: the first font of `font=` in [main] (or before any section),
/// with its :size= (points) or :pixelsize= (shown as px).
pub fn footFont(text: []const u8, out: *TermFont) void {
    var main = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            main = std.mem.eql(u8, line, "[main]");
            continue;
        }
        if (!main) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), "font")) continue;
        var first = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.indexOfScalar(u8, first, ',')) |c| first = std.mem.trim(u8, first[0..c], " \t");
        var parts = std.mem.splitScalar(u8, first, ':');
        out.family.set(std.mem.trim(u8, parts.next() orelse "", " \t"));
        out.size = .{};
        while (parts.next()) |attr| {
            const a = std.mem.trim(u8, attr, " \t");
            if (std.mem.startsWith(u8, a, "size=")) out.size.set(cleanSize(a["size=".len..]));
            if (std.mem.startsWith(u8, a, "pixelsize=")) {
                var pb: [24]u8 = undefined;
                out.size.set(std.fmt.bufPrint(&pb, "{s}px", .{cleanSize(a["pixelsize=".len..])}) catch "");
            }
        }
    }
}

/// One kitty.conf line: font_family / font_size into `out`; the path of an
/// `include` line is returned for the caller to follow.
pub fn kittyLine(raw: []const u8, out: *TermFont) ?[]const u8 {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    const sp = std.mem.indexOfAny(u8, line, " \t") orelse return null;
    const key = line[0..sp];
    const val = std.mem.trim(u8, line[sp..], " \t");
    if (std.mem.eql(u8, key, "include")) return val;
    if (std.mem.eql(u8, key, "font_family")) {
        // kitty 0.36+: font_family family="JetBrains Mono" style=…
        if (std.mem.indexOf(u8, val, "family=")) |fi| {
            var v = val[fi + "family=".len ..];
            if (v.len > 0 and (v[0] == '"' or v[0] == '\'')) {
                const q = v[0];
                v = v[1..];
                v = v[0 .. std.mem.indexOfScalar(u8, v, q) orelse v.len];
            } else {
                v = v[0 .. std.mem.indexOfAny(u8, v, " \t") orelse v.len];
            }
            out.family.set(v);
        } else if (!std.mem.eql(u8, val, "auto")) {
            out.family.set(val);
        }
    }
    if (std.mem.eql(u8, key, "font_size")) out.size.set(cleanSize(val));
    return null;
}

/// alacritty.toml: [font] size, and the normal face's family ([font.normal]
/// family = …, or [font] normal = { family = … }).
pub fn alacrittyFont(text: []const u8, out: *TermFont) void {
    var section: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            section = std.mem.trim(u8, line, "[] \t");
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, section, "font") and std.mem.eql(u8, key, "size")) out.size.set(cleanSize(val));
        if (std.mem.eql(u8, section, "font.normal") and std.mem.eql(u8, key, "family")) out.family.set(std.mem.trim(u8, val, "\"'"));
        if (std.mem.eql(u8, section, "font") and std.mem.eql(u8, key, "normal")) {
            if (std.mem.indexOf(u8, val, "family")) |fi| {
                var v = val[fi + "family".len ..];
                v = std.mem.trimStart(u8, v, " \t=");
                if (v.len > 0 and (v[0] == '"' or v[0] == '\'')) {
                    const q = v[0];
                    v = v[1..];
                    out.family.set(v[0 .. std.mem.indexOfScalar(u8, v, q) orelse v.len]);
                }
            }
        }
    }
}

/// gsettings' answer "'adw-gtk3-dark'\n" -> "adw-gtk3-dark".
pub fn gsettingsString(out: []const u8) []const u8 {
    return std.mem.trim(u8, out, " \t\r\n'\"");
}

/// A format that starts with its own label, the way a config written for
/// the terminal does ("OS Age: {result}", "Uptime: {formatted}"): the
/// words become the row's label and the rest stays the format, so the
/// card doesn't show "Uptime   Uptime: 11 mins".
pub const FormatPrefix = struct { words: []const u8, rest: []const u8 };

pub fn splitFormatPrefix(format: []const u8) ?FormatPrefix {
    const brace = std.mem.indexOfScalar(u8, format, '{') orelse return null;
    const colon = std.mem.indexOf(u8, format[0..brace], ": ") orelse return null;
    const words = std.mem.trim(u8, format[0..colon], " ");
    var alpha = false;
    for (words) |ch| {
        if (std.ascii.isAlphabetic(ch)) alpha = true;
    }
    if (!alpha) return null;
    const rest = std.mem.trimStart(u8, format[colon + 2 ..], " ");
    if (rest.len == 0) return null;
    return .{ .words = words, .rest = rest };
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
    /// Filled from the desktop instead of fastfetch's own module (see
    /// Native).
    native: Native = .none,
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

/// 'text' for sh, with embedded quotes escaped. Null if `out` is too small.
fn shellQuote(text: []const u8, out: []u8) ?[]const u8 {
    var w = Buf{ .b = out };
    w.put("'");
    for (text) |ch| {
        if (ch == '\'') w.put("'\\''") else w.put(&[_]u8{ch});
    }
    w.put("'");
    return if (w.ok) out[0..w.n] else null;
}

/// Reads a fastfetch JSONC config into card rows and writes the derived
/// config the binary runs (same modules and options, keys "@@N", no
/// logo, separator ": "). The shell, terminal, terminal-font and WM-theme
/// modules become desktop rows (Native): the binary prints the shell's and
/// terminal's `--version` line and gsettings' GTK theme for them instead.
/// Null when it isn't a usable config.
pub fn buildPlan(alloc: std.mem.Allocator, jsonc: []const u8, rows: *[MAX_ROWS]CardRow, derived: []u8, ex: Extras) ?Plan {
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

        // "OS Age: {result}": the words are the label, the rest the format.
        const prefix: ?FormatPrefix = if (format) |f| splitFormatPrefix(f) else null;
        const tl = if (prefix) |px| px.words else typeLabel(t, &tlb);
        const eff_format: ?[]const u8 = if (prefix) |px| px.rest else format;
        var r = CardRow{ .field = std.meta.stringToEnum(Field, t) };
        r.label.set(if (key) |k| deriveLabel(k, tl, &lb) else tl);

        const native: Native = if (std.mem.eql(u8, t, "shell"))
            .shell
        else if (std.mem.eql(u8, t, "terminal"))
            .terminal
        else if (std.mem.eql(u8, t, "terminalfont"))
            .terminal_font
        else if (std.mem.eql(u8, t, "wmtheme"))
            .wm_theme
        else
            .none;
        if (native != .none) {
            r.field = null;
            r.native = native;
            // What the run prints for this row, if anything.
            var cb: [400]u8 = undefined;
            const cmd: ?[]const u8 = switch (native) {
                .shell, .terminal => blk: {
                    const path = if (native == .shell) ex.shell_path else ex.term_path;
                    if (path.len == 0) break :blk null;
                    var qb: [300]u8 = undefined;
                    const q = shellQuote(path, &qb) orelse break :blk null;
                    break :blk std.fmt.bufPrint(&cb, "{s} --version 2>/dev/null | head -n 1", .{q}) catch null;
                },
                .wm_theme => if (ex.gsettings) GSETTINGS_THEME_CMD else null,
                else => null,
            };
            if (cmd) |text| {
                const idx = plan.modules;
                r.module = @intCast(idx);
                if (idx > 0) w.put(",");
                w.fmt("{{\"type\":\"command\",\"key\":\"@@{d}\",\"text\":", .{idx});
                w.str(text);
                w.put("}");
                plan.modules += 1;
            }
            rows[plan.rows] = r;
            plan.rows += 1;
            continue;
        }
        if (std.mem.eql(u8, t, "datetime")) {
            // Shown natively and kept current; no point running it.
            r.live = .datetime;
            plan.datetime = true;
            rows[plan.rows] = r;
            plan.rows += 1;
            continue;
        }
        // Live rows only where the card's own value looks like fastfetch's
        // (its default format; "{formatted}" is the uptime default).
        const default_fmt = eff_format == null or
            (std.mem.eql(u8, t, "uptime") and std.mem.eql(u8, eff_format.?, "{formatted}"));
        if (default_fmt) {
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
            if (prefix) |px| {
                // Same module, its label words dropped from the format.
                var eb: [600]u8 = undefined;
                var ew = Buf{ .b = &eb };
                ew.put(tag);
                ew.put(",\"format\":");
                ew.str(px.rest);
                if (!ew.ok) continue;
                writeObject(&w, o, &.{ "key", "keyColor", "keyFormat", "keyWidth", "keyIcon", "format" }, eb[0..ew.n]);
            } else {
                writeObject(&w, o, &.{ "key", "keyColor", "keyFormat", "keyWidth", "keyIcon" }, tag);
            }
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

    values: [FIELD_COUNT]Text(128) = @as([FIELD_COUNT]Text(128), @splat(.{})),
    /// "user@hostname", fastfetch's title line.
    title: Text(96) = .{},
    distro_id: Text(32) = .{},

    logo: [MAX_LOGO_LINES]Text(256) = @as([MAX_LOGO_LINES]Text(256), @splat(.{})),
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
    rows: [MAX_ROWS]CardRow = @as([MAX_ROWS]CardRow, @splat(.{})),
    row_count: usize = 0,
    /// The config ends on a "colors" module (fields layout: always).
    palette: bool = true,
    has_datetime: bool = false,
    config_path: Text(320) = .{},
    derived_path: Text(320) = .{},

    // The desktop rows (Native), read once at start.
    shell_path: Text(256) = .{},
    shell_name: Text(64) = .{},
    term_name: Text(64) = .{},
    term_path: Text(256) = .{},
    term_font: Text(112) = .{},
    gtk_theme: Text(96) = .{},
    gsettings: bool = false,

    /// Detection and config reading only (PATH lookups, a few small file
    /// reads, one small file write): no process.
    pub fn init(cfg: Config) Service {
        var s = Service{ .refresh_ms = if (cfg.refresh_ms <= 0) 0 else @max(cfg.refresh_ms, 60_000) };
        s.root.set(cfg.root);
        s.home.set(if (cfg.home.len > 0) cfg.home else env("HOME"));
        s.detectSource(cfg.binary);
        s.detectDesktop(cfg.uid orelse libc.getuid());
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
        // Version lines only for binaries that can actually be run.
        var sp_ok = false;
        if (self.shell_path.len > 0) sp_ok = libc.access(self.shell_path.z().ptr, X_OK) == 0;
        const ex = Extras{
            .shell_path = if (sp_ok) self.shell_path.slice() else "",
            .term_path = self.term_path.slice(),
            .gsettings = self.gsettings,
        };
        const plan = buildPlan(arena.allocator(), text, &self.rows, &derived, ex) orelse return;
        self.layout = .config;
        self.row_count = plan.rows;
        self.fillDesktopRows();
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
            var seen_rows = @as([MAX_ROWS]bool, @splat(false));
            var got_rows: usize = 0;
            var tlines = std.mem.splitScalar(u8, body, '\n');
            while (tlines.next()) |line| {
                const tg = parseTagged(line) orelse continue;
                for (self.rows[0..self.row_count], 0..) |*r, i| {
                    if (r.module != tg.idx) continue;
                    got_rows += 1;
                    if (r.native != .none) {
                        self.desktopAnswer(r, tg.value);
                        seen_rows[i] = true;
                        continue;
                    }
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
        var seen = @as([FIELD_COUNT]bool, @splat(false));
        var disk_root = false;
        var got: usize = 0;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const row = parseRow(line) orelse continue;
            // fastfetch's shell is its parent, perihelion-shell: keep the
            // login shell read natively.
            if (row.field == .shell) continue;
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

    // --- desktop rows (shell, terminal, terminal font, GTK theme) ---

    /// A binary by name: under root's /usr/bin in tests, else on PATH.
    fn findBin(self: *const Service, name: []const u8, out: *Text(256)) bool {
        if (name.len == 0) return false;
        if (self.root.len > 0) {
            var zb: [400]u8 = undefined;
            const z = pathZ(&zb, "{s}/usr/bin/{s}", .{ self.root.slice(), name }) orelse return false;
            if (libc.access(z.ptr, X_OK) != 0) return false;
            out.set(z);
            return true;
        }
        return findOnPath(name, out);
    }

    /// The user's config dir: $XDG_CONFIG_HOME (real use only), else
    /// ~/.config.
    fn configDir(self: *const Service, buf: []u8) []const u8 {
        const xdg = env("XDG_CONFIG_HOME");
        if (xdg.len > 0 and self.root.len == 0) return std.fmt.bufPrint(buf, "{s}", .{xdg}) catch "";
        return std.fmt.bufPrint(buf, "{s}/.config", .{self.home.slice()}) catch "";
    }

    /// A path from a config file: "~/x" under home, "/x" under root (tests),
    /// "./x" or "x" relative to `dir`.
    fn resolvePath(self: *const Service, p: []const u8, dir: []const u8, out: []u8) ?[:0]const u8 {
        if (std.mem.startsWith(u8, p, "~/")) return pathZ(out, "{s}{s}", .{ self.home.slice(), p[1..] });
        if (p.len > 0 and p[0] == '/') return pathZ(out, "{s}{s}", .{ self.root.slice(), p });
        const rel = if (std.mem.startsWith(u8, p, "./")) p[2..] else p;
        return pathZ(out, "{s}/{s}", .{ dir, rel });
    }

    fn detectDesktop(self: *Service, uid: u32) void {
        var buf: [16384]u8 = undefined;
        var pb: [400]u8 = undefined;
        var cb: [320]u8 = undefined;
        const cfg = self.configDir(&cb);

        // Login shell: passwd entry, else $SHELL.
        var sh: []const u8 = "";
        if (pathZ(&pb, "{s}/etc/passwd", .{self.root.slice()})) |p| {
            if (readFile(p, &buf)) |t| sh = passwdShell(t, uid) orelse "";
        }
        if (sh.len == 0 and self.root.len == 0) sh = env("SHELL");
        self.shell_path.set(sh);
        self.shell_name.set(baseName(sh));

        self.detectTerminal(cfg, &buf);
        self.detectTermFont(cfg, &buf);

        // GTK theme: GTK 4's settings, then GTK 3's; gsettings (asked in
        // the fastfetch run) wins when it answers.
        for ([_][]const u8{ "gtk-4.0", "gtk-3.0" }) |v| {
            const p = pathZ(&pb, "{s}/{s}/settings.ini", .{ cfg, v }) orelse continue;
            const t = readFile(p, &buf) orelse continue;
            if (keyValue(t, "gtk-theme-name")) |name| {
                self.gtk_theme.set(name);
                break;
            }
        }
        var gb: Text(256) = .{};
        self.gsettings = self.findBin("gsettings", &gb);
    }

    /// The terminal the user gets: $TERMINAL, xdg-terminal-exec's list
    /// (first installed entry), the program Mango's Return bind spawns,
    /// then foot when it's installed.
    fn detectTerminal(self: *Service, cfg: []const u8, buf: []u8) void {
        var pb: [400]u8 = undefined;
        if (self.root.len == 0) {
            var tok = std.mem.tokenizeAny(u8, env("TERMINAL"), " \t");
            if (tok.next()) |t| {
                if (self.setTerminal(baseName(t), false)) return;
            }
        }
        // xdg-terminal-exec: desktop-specific lists first.
        var desk_buf: [32]u8 = undefined;
        var desk: []const u8 = "";
        if (self.root.len == 0) {
            var d = env("XDG_CURRENT_DESKTOP");
            if (std.mem.indexOfScalar(u8, d, ':')) |i| d = d[0..i];
            if (d.len > 0 and d.len <= desk_buf.len) desk = std.ascii.lowerString(&desk_buf, d);
        }
        const r = self.root.slice();
        var lists: [5]?[:0]const u8 = @splat(null);
        var lb: [5][400]u8 = undefined;
        if (desk.len > 0) lists[0] = pathZ(&lb[0], "{s}/{s}-xdg-terminals.list", .{ cfg, desk });
        lists[1] = pathZ(&lb[1], "{s}/xdg-terminals.list", .{cfg});
        if (desk.len > 0) lists[2] = pathZ(&lb[2], "{s}/etc/xdg/{s}-xdg-terminals.list", .{ r, desk });
        lists[3] = pathZ(&lb[3], "{s}/etc/xdg/xdg-terminals.list", .{r});
        lists[4] = pathZ(&lb[4], "{s}/usr/share/xdg-terminal-exec/xdg-terminals.list", .{r});
        for (lists) |lp| {
            const p = lp orelse continue;
            const t = readFile(p, buf) orelse continue;
            var entries: [16][]const u8 = undefined;
            const n = xdgTerminalEntries(t, &entries);
            for (entries[0..n]) |e| {
                if (self.setTerminal(terminalBinary(e), true)) return;
            }
        }
        // Mango: the user's config, then the system one Perihelion ships.
        const mango_cfgs = [_]struct { base: []const u8, under_root: bool }{
            .{ .base = cfg, .under_root = false },
            .{ .base = "/usr/share/perihelion", .under_root = true },
            .{ .base = "/etc", .under_root = true },
        };
        for (mango_cfgs) |mc| {
            var db: [400]u8 = undefined;
            const dir = (if (mc.under_root)
                std.fmt.bufPrint(&db, "{s}{s}/mango", .{ r, mc.base })
            else
                std.fmt.bufPrint(&db, "{s}/mango", .{mc.base})) catch continue;
            const main_p = pathZ(&pb, "{s}/config.conf", .{dir}) orelse continue;
            // Own buffer: the source list below points into it while each
            // sourced file is read into `buf`.
            var mbuf: [8192]u8 = undefined;
            const t = readFile(main_p, &mbuf) orelse continue;
            if (mangoTerminal(t)) |prog| {
                if (self.setTerminal(prog, false)) return;
            }
            var srcs: [16][]const u8 = undefined;
            const n = mangoSources(t, &srcs);
            for (srcs[0..n]) |src| {
                var rp: [400]u8 = undefined;
                const sp = self.resolvePath(src, dir, &rp) orelse continue;
                const st = readFile(sp, buf) orelse continue;
                if (mangoTerminal(st)) |prog| {
                    if (self.setTerminal(prog, false)) return;
                }
            }
        }
        _ = self.setTerminal("foot", true);
    }

    /// Takes `name` as the terminal. With `need_bin`, only when it is
    /// installed; without, the name stands even if no binary is found
    /// (the row shows it without a version).
    fn setTerminal(self: *Service, name: []const u8, need_bin: bool) bool {
        if (name.len == 0) return false;
        var path: Text(256) = .{};
        const have = self.findBin(name, &path);
        if (need_bin and !have) return false;
        self.term_name.set(name);
        self.term_path = if (have) path else .{};
        return true;
    }

    /// The terminal's font from its config: foot, kitty (following its
    /// include lines) or alacritty, with each one's defaults.
    fn detectTermFont(self: *Service, cfg: []const u8, buf: []u8) void {
        const name = self.term_name.slice();
        var pb: [400]u8 = undefined;
        var f = TermFont{};
        const r = self.root.slice();
        if (std.mem.eql(u8, name, "foot")) {
            f.family.set("monospace");
            f.size.set("8");
            const paths = [_]?[:0]const u8{ pathZ(&pb, "{s}/foot/foot.ini", .{cfg}), null };
            var found = false;
            if (paths[0]) |p| {
                if (readFile(p, buf)) |t| {
                    footFont(t, &f);
                    found = true;
                }
            }
            if (!found) {
                if (pathZ(&pb, "{s}/etc/xdg/foot/foot.ini", .{r})) |p| {
                    if (readFile(p, buf)) |t| footFont(t, &f);
                }
            }
        } else if (std.mem.eql(u8, name, "kitty")) {
            f.family.set("monospace");
            f.size.set("11");
            var dir_b: [400]u8 = undefined;
            const user = pathZ(&pb, "{s}/kitty/kitty.conf", .{cfg});
            var opened = false;
            if (user) |p| {
                if (std.fmt.bufPrint(&dir_b, "{s}/kitty", .{cfg})) |dir| {
                    opened = self.kittyFile(p, dir, &f, 0);
                } else |_| {}
            }
            if (!opened) {
                if (std.fmt.bufPrint(&dir_b, "{s}/etc/xdg/kitty", .{r})) |dir| {
                    if (pathZ(&pb, "{s}/kitty.conf", .{dir})) |p| _ = self.kittyFile(p, dir, &f, 0);
                } else |_| {}
            }
        } else if (std.mem.eql(u8, name, "alacritty")) {
            f.family.set("monospace");
            f.size.set("11.25");
            const cands = [_]?[:0]const u8{
                pathZ(&pb, "{s}/alacritty/alacritty.toml", .{cfg}),
            };
            var done = false;
            if (cands[0]) |p| {
                if (readFile(p, buf)) |t| {
                    alacrittyFont(t, &f);
                    done = true;
                }
            }
            if (!done) {
                var hb: [400]u8 = undefined;
                if (pathZ(&hb, "{s}/.alacritty.toml", .{self.home.slice()})) |p| {
                    if (readFile(p, buf)) |t| {
                        alacrittyFont(t, &f);
                        done = true;
                    }
                }
            }
            if (!done) {
                if (pathZ(&pb, "{s}/etc/alacritty/alacritty.toml", .{r})) |p| {
                    if (readFile(p, buf)) |t| alacrittyFont(t, &f);
                }
            }
        } else return;
        var ob: [112]u8 = undefined;
        self.term_font.set(f.format(&ob));
    }

    /// One kitty.conf and the files it includes (depth-limited). False
    /// when the file can't be read.
    fn kittyFile(self: *const Service, path: [:0]const u8, dir: []const u8, f: *TermFont, depth: u8) bool {
        var buf: [16384]u8 = undefined;
        const t = readFile(path, &buf) orelse return false;
        var it = std.mem.splitScalar(u8, t, '\n');
        while (it.next()) |line| {
            const inc = kittyLine(line, f) orelse continue;
            if (depth >= 4 or std.mem.indexOfAny(u8, inc, "*?$") != null) continue;
            var rp: [400]u8 = undefined;
            const p = self.resolvePath(inc, dir, &rp) orelse continue;
            const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse continue;
            var db: [400]u8 = undefined;
            const sub = std.fmt.bufPrint(&db, "{s}", .{p[0..slash]}) catch continue;
            _ = self.kittyFile(p, sub, f, depth + 1);
        }
        return true;
    }

    /// Desktop values into the config layout's rows; rows with nothing to
    /// show and nothing coming from the run are dropped, so the card never
    /// shows an empty row.
    fn fillDesktopRows(self: *Service) void {
        var n: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            var r = row;
            if (r.kind == .row and r.native != .none) {
                r.value.set(switch (r.native) {
                    .shell => self.shell_name.slice(),
                    .terminal => self.term_name.slice(),
                    .terminal_font => self.term_font.slice(),
                    .wm_theme => self.gtk_theme.slice(),
                    .none => "",
                });
                if (r.value.len == 0 and r.module < 0) continue;
            }
            // No spacer first, none twice in a row.
            if (r.kind == .spacer and (n == 0 or self.rows[n - 1].kind == .spacer)) continue;
            self.rows[n] = r;
            n += 1;
        }
        while (n > 0 and self.rows[n - 1].kind == .spacer) n -= 1;
        self.row_count = n;
    }

    /// The run's line for a desktop row: a `--version` line for the shell
    /// and terminal ("bash 5.2.37"), gsettings' theme name.
    fn desktopAnswer(self: *Service, r: *CardRow, line: []const u8) void {
        var vb: [128]u8 = undefined;
        switch (r.native) {
            .shell => r.value.set(withVersion(&vb, self.shell_name.slice(), line)),
            .terminal => r.value.set(withVersion(&vb, self.term_name.slice(), line)),
            .wm_theme => {
                const t = gsettingsString(line);
                if (t.len > 0) r.value.set(t);
            },
            else => {},
        }
        r.fresh = true;
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
        if (self.wants(.shell, which) and self.shell_name.len > 0) self.setVal(.shell, self.shell_name.slice());
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
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{p}, 0) catch return;
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
    var rows: [MAX_ROWS]CardRow = @as([MAX_ROWS]CardRow, @splat(.{}));
    var derived: [16384]u8 = undefined;
    const plan = buildPlan(arena.allocator(), PERIHELION_CONFIG, &rows, &derived, .{}).?;
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


// --- desktop readers ---------------------------------------------------------------------

test "login shell from passwd, versions from --version lines" {
    const pw =
        \\root:x:0:0:root:/root:/bin/bash
        \\perihelion:x:1000:1000:Perihelion User:/home/perihelion:/usr/bin/fish
        \\nologin:x:1001:1001::/home/n:
    ;
    try std.testing.expectEqualStrings("/usr/bin/fish", passwdShell(pw, 1000).?);
    try std.testing.expectEqualStrings("/bin/bash", passwdShell(pw, 0).?);
    try std.testing.expect(passwdShell(pw, 1001) == null);
    try std.testing.expect(passwdShell(pw, 4242) == null);
    try std.testing.expectEqualStrings("5.2.37", parseVersion("GNU bash, version 5.2.37(1)-release (x86_64-redhat-linux-gnu)").?);
    try std.testing.expectEqualStrings("4.0.2", parseVersion("fish, version 4.0.2").?);
    try std.testing.expectEqualStrings("5.9", parseVersion("zsh 5.9 (x86_64-redhat-linux-gnu)").?);
    try std.testing.expectEqualStrings("0.39.1", parseVersion("kitty 0.39.1 created by Kovid Goyal").?);
    try std.testing.expectEqualStrings("1.20.2", parseVersion("foot version: 1.20.2 +pgo +ime +graphemes -assertions").?);
    try std.testing.expect(parseVersion("no digits here") == null);
    try std.testing.expect(parseVersion("x86_64 build 42") == null);
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("fish 4.0.2", withVersion(&b, "fish", "fish, version 4.0.2"));
    try std.testing.expectEqualStrings("fish", withVersion(&b, "fish", ""));
}

test "terminal from xdg-terminals.list and Mango binds" {
    var e: [8][]const u8 = undefined;
    const n = xdgTerminalEntries("# mine\n/execarg_default -e\n-xterm.desktop\n+com.mitchellh.ghostty.desktop\nkitty.desktop:new-window\n\nfoot.desktop\n", &e);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("ghostty", e[0]);
    try std.testing.expectEqualStrings("kitty", e[1]);
    try std.testing.expectEqualStrings("foot", e[2]);
    try std.testing.expectEqualStrings("foot", terminalBinary("foot-server"));

    const binds =
        \\# Terminal
        \\bind=SUPER+SHIFT,Return,spawn,kitty --class perihelion-float
        \\bind=SUPER,Return,spawn,/usr/bin/kitty
        \\bind=NONE,Return,setkeymode,default
    ;
    try std.testing.expectEqualStrings("kitty", mangoTerminal(binds).?);
    try std.testing.expectEqualStrings("foot", mangoTerminal("bind=SUPER+ALT,Return,spawn,foot -e btop\n").?);
    try std.testing.expect(mangoTerminal("bind=SUPER,d,spawn,rofi\nbinding=SUPER,Return,spawn,x\n") == null);
    var src: [4][]const u8 = undefined;
    const sn = mangoSources("source=./cfg/keybinds.conf\n# source=./off.conf\nsource_optional=~/.config/mango/glass.conf\n", &src);
    try std.testing.expectEqual(@as(usize, 2), sn);
    try std.testing.expectEqualStrings("./cfg/keybinds.conf", src[0]);
    try std.testing.expectEqualStrings("~/.config/mango/glass.conf", src[1]);
}

test "terminal fonts: foot, kitty, alacritty" {
    var b: [112]u8 = undefined;
    var f = TermFont{};
    footFont("[main]\nfont=JetBrainsMono Nerd Font:size=11, Noto Color Emoji\n[colors]\nfont=ignored\n", &f);
    try std.testing.expectEqualStrings("JetBrainsMono Nerd Font 11", f.format(&b));
    f = .{};
    footFont("font=Fira Code:pixelsize=14\n", &f);
    try std.testing.expectEqualStrings("Fira Code 14px", f.format(&b));

    f = .{};
    _ = kittyLine("font_family      DejaVu Sans Mono", &f);
    _ = kittyLine("font_size 11.0", &f);
    try std.testing.expectEqualStrings("DejaVu Sans Mono 11", f.format(&b));
    _ = kittyLine("font_family family=\"JetBrains Mono\" style=Regular", &f);
    _ = kittyLine("font_size 10.50", &f);
    try std.testing.expectEqualStrings("JetBrains Mono 10.5", f.format(&b));
    try std.testing.expectEqualStrings("/etc/xdg/kitty/kitty.conf", kittyLine("include /etc/xdg/kitty/kitty.conf", &f).?);
    try std.testing.expect(kittyLine("# font_family X", &f) == null);

    f = .{};
    alacrittyFont("[font]\nsize = 12.0\n\n[font.normal]\nfamily = \"Iosevka Term\"\nstyle = \"Regular\"\n", &f);
    try std.testing.expectEqualStrings("Iosevka Term 12", f.format(&b));
    f = .{};
    alacrittyFont("[font]\nnormal = { family = \"Hack\", style = \"Regular\" }\nsize = 9.5\n", &f);
    try std.testing.expectEqualStrings("Hack 9.5", f.format(&b));
    try std.testing.expectEqualStrings("adw-gtk3-dark", gsettingsString("'adw-gtk3-dark'\n"));
}

test "format prefixes become labels" {
    const a = splitFormatPrefix("OS Age: {result}").?;
    try std.testing.expectEqualStrings("OS Age", a.words);
    try std.testing.expectEqualStrings("{result}", a.rest);
    try std.testing.expectEqualStrings("{formatted}", splitFormatPrefix("Uptime: {formatted}").?.rest);
    try std.testing.expect(splitFormatPrefix("{5} {1} Type {2}") == null);
    try std.testing.expect(splitFormatPrefix("Perihelion Linux {arch}") == null);
    try std.testing.expect(splitFormatPrefix("{1}: {2}") == null);
}

/// The ISO's fastfetch config (system_files/common/usr/share/perihelion/
/// fastfetch/config.jsonc), trimmed to the rows this test checks.
const ISO_CONFIG =
    \\{
    \\    "display": { "separator": " ➜  " },
    \\    "modules": [
    \\        "break",
    \\        { "type": "os", "key": "OS   ", "format": "Perihelion Linux {arch}" },
    \\        { "type": "shell", "key": " └  " },
    \\        "break",
    \\        { "type": "wm", "key": "WM   " },
    \\        { "type": "wmtheme", "key": " ├ 󰉼 " },
    \\        { "type": "terminal", "key": " ├  " },
    \\        { "type": "terminalfont", "key": " └  " },
    \\        "break",
    \\        { "type": "command", "text": "perihelion-os-age", "format": "OS Age: {result}", "key": " ├ 󰃭 " },
    \\        { "type": "uptime", "format": "Uptime: {formatted}", "key": " └ 󰥔 " },
    \\        "break",
    \\    ]
    \\}
;

test "ISO config: desktop rows, no doubled labels, empty rows dropped" {
    var rb: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&rb, "/tmp/perihelion-ff-iso-{d}", .{std.c.getpid()}) catch unreachable;
    var hb: [80]u8 = undefined;
    const home = std.fmt.bufPrint(&hb, "{s}/home", .{root}) catch unreachable;
    writeFile(root, "etc/passwd", "root:x:0:0::/root:/bin/bash\nperihelion:x:1000:1000::/home/perihelion:/usr/bin/bash\n", 0o644);
    writeFile(root, "usr/bin/bash", "#!/bin/sh\n", 0o755);
    writeFile(root, "usr/bin/kitty", "#!/bin/sh\n", 0o755);
    // Mango's config sources the keybinds that launch kitty.
    writeFile(home, ".config/mango/config.conf", "source=./cfg/keybinds.conf\n", 0o644);
    writeFile(home, ".config/mango/cfg/keybinds.conf", "bind=SUPER,Return,spawn,kitty\n", 0o644);
    // kitty.conf includes the system file that sets the font.
    writeFile(home, ".config/kitty/kitty.conf", "include /etc/xdg/kitty/kitty.conf\nglobinclude perihelion-colors.conf\n", 0o644);
    writeFile(root, "etc/xdg/kitty/kitty.conf", "font_family DejaVu Sans Mono\nfont_size 11.0\n", 0o644);
    writeFile(home, ".config/gtk-4.0/settings.ini", "[Settings]\ngtk-theme-name=adw-gtk3-dark\n", 0o644);
    writeFile(home, ".config/fastfetch/config.jsonc", ISO_CONFIG, 0o644);

    var s = Service.init(.{ .root = root, .home = home, .uid = 1000, .logo = "none" });
    try std.testing.expectEqual(Layout.config, s.layout);
    try std.testing.expectEqualStrings("kitty", s.term_name.slice());
    try std.testing.expectEqualStrings("DejaVu Sans Mono 11", s.term_font.slice());

    const R = struct { label: []const u8, value: []const u8, native: Native };
    const want = [_]R{
        .{ .label = "OS", .value = "", .native = .none },
        .{ .label = "\u{E795} Shell", .value = "bash", .native = .shell },
        .{ .label = "", .value = "", .native = .none }, // spacer
        .{ .label = "WM", .value = "", .native = .none },
        .{ .label = "\u{F027C} Wmtheme", .value = "adw-gtk3-dark", .native = .wm_theme },
        .{ .label = "\u{E795} Terminal", .value = "kitty", .native = .terminal },
        .{ .label = "\u{F031} Terminal Font", .value = "DejaVu Sans Mono 11", .native = .terminal_font },
        .{ .label = "", .value = "", .native = .none }, // spacer
        .{ .label = "\u{F00ED} OS Age", .value = "", .native = .none },
        .{ .label = "\u{F0954} Uptime", .value = "", .native = .none },
    };
    const rows = s.cardRows();
    try std.testing.expectEqual(want.len, rows.len);
    for (want, 0..) |w, i| {
        if (w.label.len == 0) {
            try std.testing.expectEqual(RowKind.spacer, rows[i].kind);
            continue;
        }
        try std.testing.expectEqual(w.native, rows[i].native);
        if (w.native != .none) try std.testing.expectEqualStrings(w.value, rows[i].value.slice());
    }
    try std.testing.expectEqualStrings("OS Age", rows[8].label.slice()[rows[8].label.len - 6 ..]);
    try std.testing.expectEqual(Live.uptime, rows[9].live);

    // The run: bash's and kitty's --version lines, the command's bare
    // result (its "OS Age: " prefix is gone from the derived format).
    s.source = .system;
    s.bin.set("/usr/bin/fastfetch");
    s.fallback_bin.set("/usr/bin/fastfetch");
    var idx_shell: i16 = -1;
    var idx_term: i16 = -1;
    var idx_age: i16 = -1;
    for (rows) |*r| {
        if (r.native == .shell) idx_shell = r.module;
        if (r.native == .terminal) idx_term = r.module;
        if (std.mem.endsWith(u8, r.label.slice(), "OS Age")) idx_age = r.module;
    }
    try std.testing.expect(idx_shell >= 0 and idx_term >= 0 and idx_age >= 0);
    var ob: [512]u8 = undefined;
    const out = try std.fmt.bufPrint(&ob, "@@{d}: GNU bash, version 5.2.37(1)-release (x86_64-redhat-linux-gnu)\n@@{d}: kitty 0.39.1 created by Kovid Goyal\n@@{d}: 3 days\n", .{ idx_shell, idx_term, idx_age });
    _ = s.runComplete(out, 0);
    try std.testing.expectEqualStrings("bash 5.2.37", s.cardRows()[1].value.slice());
    try std.testing.expectEqualStrings("kitty 0.39.1", s.cardRows()[5].value.slice());
    try std.testing.expectEqualStrings("3 days", s.cardRows()[8].value.slice());

    // Derived config: the command keeps its text, its format lost the label.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var rows2: [MAX_ROWS]CardRow = @as([MAX_ROWS]CardRow, @splat(.{}));
    var derived: [16384]u8 = undefined;
    const plan = buildPlan(arena.allocator(), ISO_CONFIG, &rows2, &derived, .{ .shell_path = "/usr/bin/bash", .term_path = "/usr/bin/kitty" }).?;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), derived[0..plan.derived_len], .{});
    var saw_age = false;
    var saw_uptime = false;
    var saw_shell_cmd = false;
    for (parsed.object.get("modules").?.array.items) |m| {
        const t = m.object.get("type").?.string;
        if (std.mem.eql(u8, t, "command")) {
            const text = m.object.get("text").?.string;
            if (std.mem.eql(u8, text, "perihelion-os-age")) {
                try std.testing.expectEqualStrings("{result}", m.object.get("format").?.string);
                saw_age = true;
            }
            if (std.mem.eql(u8, text, "'/usr/bin/bash' --version 2>/dev/null | head -n 1")) saw_shell_cmd = true;
        }
        if (std.mem.eql(u8, t, "uptime")) {
            try std.testing.expectEqualStrings("{formatted}", m.object.get("format").?.string);
            saw_uptime = true;
        }
        try std.testing.expect(!std.mem.eql(u8, t, "shell") and !std.mem.eql(u8, t, "terminal") and !std.mem.eql(u8, t, "terminalfont"));
    }
    try std.testing.expect(saw_age and saw_uptime and saw_shell_cmd);
}

test "no terminal font or GTK theme: those rows are dropped" {
    var rb: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&rb, "/tmp/perihelion-ff-none-{d}", .{std.c.getpid()}) catch unreachable;
    var hb: [80]u8 = undefined;
    const home = std.fmt.bufPrint(&hb, "{s}/home", .{root}) catch unreachable;
    writeFile(home, ".config/fastfetch/config.jsonc", ISO_CONFIG, 0o644);
    var s = Service.init(.{ .root = root, .home = home, .uid = 1000, .logo = "none" });
    for (s.cardRows()) |*r| {
        try std.testing.expect(r.native != .terminal_font and r.native != .wm_theme and r.native != .terminal);
        try std.testing.expect(r.native != .shell); // no passwd entry, $SHELL ignored in tests
    }
    // Spacers never doubled after the drops.
    const rows = s.cardRows();
    for (rows[1..], 1..) |*r, i| {
        try std.testing.expect(!(r.kind == .spacer and rows[i - 1].kind == .spacer));
    }
}
