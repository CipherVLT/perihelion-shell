//! What a Mango config must contain for Perihelion, checked without Mango:
//! Super+I opens Glance (with its "#:" cheatsheet line) and nothing else is
//! on Super+I, Super+L locks, Alt+W opens the window overview, and the
//! session starts the desktop: either the one line
//! `exec_once=perihelion-session-start` (which starts every piece once), or,
//! in configs from before it, the dbus activation line (portals), swayidle
//! with the lock, perihelion-bar-start (bar + dock, and no second bar) and
//! perihelion-shell, each on its own line. Next to the starter, a piece on
//! its own line is reported (it would race the starter). config.conf
//! sources both files.
//!
//! Lines are matched the way Mango reads them: `bind = SUPER, i, spawn, x`
//! and `bind=SUPER,i,spawn,x` are the same bind, modifiers in any order and
//! case, keys case-insensitive. Binds inside a `key_mode=<name>` block other
//! than `default` don't count.
//!
//! Tests: `zig build test-mango-config` (sample configs, and the repo's own
//! mango/ files, embedded at build time).
const std = @import("std");

pub const MOD_SUPER: u8 = 1;
pub const MOD_SHIFT: u8 = 2;
pub const MOD_CTRL: u8 = 4;
pub const MOD_ALT: u8 = 8;
/// Any modifier name this module doesn't know.
pub const MOD_OTHER: u8 = 0x80;

pub const GLANCE_CMD = "perihelion-shell glance toggle";
pub const LOCK_CMD = "perihelion-lock";
pub const OVERVIEW_CMD = "perihelion-shell overview toggle";
pub const SWAYIDLE_CMD = "swayidle -w timeout 600 perihelion-lock before-sleep perihelion-lock";
pub const DBUS_CMD = "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE";
pub const BAR_CMD = "perihelion-bar-start";
pub const SHELL_CMD = "perihelion-shell";
pub const SESSION_CMD = "perihelion-session-start";

pub const Bind = struct {
    mods: u8,
    key: []const u8,
    action: []const u8,
    /// Everything after the action's comma, trimmed (may hold commas).
    arg: []const u8,
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// `name = value` with any spacing; null when the line isn't one.
fn keyValue(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const t = trim(line);
    if (t.len == 0 or t[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    return .{ .key = trim(t[0..eq]), .value = trim(t[eq + 1 ..]) };
}

pub fn parseMods(s: []const u8) u8 {
    var m: u8 = 0;
    var it = std.mem.splitScalar(u8, s, '+');
    while (it.next()) |raw| {
        const p = trim(raw);
        if (std.ascii.eqlIgnoreCase(p, "SUPER")) m |= MOD_SUPER //
        else if (std.ascii.eqlIgnoreCase(p, "SHIFT")) m |= MOD_SHIFT //
        else if (std.ascii.eqlIgnoreCase(p, "CTRL")) m |= MOD_CTRL //
        else if (std.ascii.eqlIgnoreCase(p, "ALT")) m |= MOD_ALT //
        else if (std.ascii.eqlIgnoreCase(p, "NONE")) {} else m |= MOD_OTHER;
    }
    return m;
}

/// A `bind` line (also bindl/bindr/...; not mousebind/axisbind/gesturebind).
pub fn parseBind(line: []const u8) ?Bind {
    const kv = keyValue(line) orelse return null;
    if (!std.mem.startsWith(u8, kv.key, "bind")) return null;
    var it = std.mem.splitScalar(u8, kv.value, ',');
    const mods = it.next() orelse return null;
    const key = it.next() orelse return null;
    const action = it.next() orelse return null;
    return .{
        .mods = parseMods(mods),
        .key = trim(key),
        .action = trim(action),
        .arg = trim(it.rest()),
    };
}

/// The command of an `exec_once` line, trimmed; null for anything else.
pub fn parseExecOnce(line: []const u8) ?[]const u8 {
    const kv = keyValue(line) orelse return null;
    if (!std.mem.eql(u8, kv.key, "exec_once")) return null;
    return kv.value;
}

/// Same words in the same order, whatever the spacing between them.
pub fn sameWords(a: []const u8, b: []const u8) bool {
    var ia = std.mem.tokenizeAny(u8, a, " \t");
    var ib = std.mem.tokenizeAny(u8, b, " \t");
    while (true) {
        const wa = ia.next();
        const wb = ib.next();
        if (wa == null or wb == null) return wa == null and wb == null;
        if (!std.mem.eql(u8, wa.?, wb.?)) return false;
    }
}

fn firstWord(s: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    return it.next() orelse "";
}

fn isBind(b: Bind, mods: u8, key: []const u8) bool {
    return b.mods == mods and std.ascii.eqlIgnoreCase(b.key, key);
}

fn isSpawnOf(b: Bind, cmd: []const u8) bool {
    return std.mem.eql(u8, b.action, "spawn") and sameWords(b.arg, cmd);
}

pub const Problem = enum {
    glance_missing,
    glance_duplicate,
    glance_no_cheatsheet,
    /// Super+I bound to anything but Glance (an old `minimized` line).
    super_i_other,
    lock_missing,
    lock_duplicate,
    overview_missing,
    dbus_missing,
    swayidle_missing,
    bar_missing,
    /// A bare perihelion-bar/perihelionbar exec_once next to the starter.
    bar_started_twice,
    shell_missing,
    /// perihelion-session-start plus a piece it starts on a line of its own.
    started_twice,
    source_keybinds_missing,
    source_autostart_missing,
};

pub const Report = struct {
    problems: std.EnumSet(Problem) = .empty,

    pub fn ok(self: Report) bool {
        return self.problems.count() == 0;
    }
    pub fn has(self: Report, p: Problem) bool {
        return self.problems.contains(p);
    }
};

fn checkKeybinds(text: []const u8, r: *Report) void {
    var glance: usize = 0;
    var lock: usize = 0;
    var overview: usize = 0;
    var cheatsheet = false;
    var default_mode = true;
    var prev: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = trim(raw);
        defer {
            if (line.len != 0) prev = line;
        }
        if (keyValue(line)) |kv| if (std.mem.eql(u8, kv.key, "key_mode")) {
            default_mode = std.mem.eql(u8, kv.value, "default");
            continue;
        };
        if (!default_mode) continue;
        const b = parseBind(line) orelse continue;
        if (isBind(b, MOD_SUPER, "i")) {
            if (isSpawnOf(b, GLANCE_CMD)) {
                glance += 1;
                if (std.mem.startsWith(u8, prev, "#:")) cheatsheet = true;
            } else r.problems.insert(.super_i_other);
        }
        if (isBind(b, MOD_SUPER, "l")) {
            if (isSpawnOf(b, LOCK_CMD)) lock += 1 else r.problems.insert(.lock_duplicate);
        }
        if (isBind(b, MOD_ALT, "w") and isSpawnOf(b, OVERVIEW_CMD)) overview += 1;
    }
    if (glance == 0) r.problems.insert(.glance_missing);
    if (glance > 1) r.problems.insert(.glance_duplicate);
    if (glance > 0 and !cheatsheet) r.problems.insert(.glance_no_cheatsheet);
    if (lock == 0) r.problems.insert(.lock_missing);
    if (lock > 1) r.problems.insert(.lock_duplicate);
    if (overview == 0) r.problems.insert(.overview_missing);
}

fn checkAutostart(text: []const u8, r: *Report) void {
    var dbus = false;
    var swayidle = false;
    var bar = false;
    var bare_bar = false;
    var shell = false;
    var session = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const cmd = parseExecOnce(raw) orelse continue;
        if (sameWords(cmd, SESSION_CMD)) session = true;
        if (sameWords(cmd, DBUS_CMD)) dbus = true;
        if (sameWords(cmd, SWAYIDLE_CMD)) swayidle = true;
        if (sameWords(cmd, BAR_CMD)) bar = true;
        if (sameWords(cmd, SHELL_CMD)) shell = true;
        const w = firstWord(cmd);
        if (std.mem.eql(u8, w, "perihelion-bar") or std.mem.eql(u8, w, "perihelionbar")) bare_bar = true;
    }
    if (session) {
        // The starter does all of it; anything it starts listed again races it.
        if (dbus or swayidle or bar or bare_bar or shell) r.problems.insert(.started_twice);
        return;
    }
    if (!dbus) r.problems.insert(.dbus_missing);
    if (!swayidle) r.problems.insert(.swayidle_missing);
    if (!bar) r.problems.insert(.bar_missing);
    if (bar and bare_bar) r.problems.insert(.bar_started_twice);
    if (!shell) r.problems.insert(.shell_missing);
}

fn sources(config: []const u8, file: []const u8) bool {
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |raw| {
        const kv = keyValue(raw) orelse continue;
        if (!std.mem.eql(u8, kv.key, "source")) continue;
        const v = if (std.mem.startsWith(u8, kv.value, "./")) kv.value[2..] else kv.value;
        if (std.mem.eql(u8, v, file)) return true;
    }
    return false;
}

/// config.conf, cfg/keybinds.conf and cfg/autostart.conf, as text.
pub fn check(config: []const u8, keybinds: []const u8, autostart: []const u8) Report {
    var r: Report = .{};
    checkKeybinds(keybinds, &r);
    checkAutostart(autostart, &r);
    if (!sources(config, "cfg/keybinds.conf")) r.problems.insert(.source_keybinds_missing);
    if (!sources(config, "cfg/autostart.conf")) r.problems.insert(.source_autostart_missing);
    return r;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const tt = std.testing;

const good_config = "source=./cfg/keybinds.conf\nsource = ./cfg/autostart.conf\n";
const good_keys =
    \\#: Glance dashboard: clock, weather, calendar, media and system (Esc closes)
    \\bind = SUPER, i, spawn, perihelion-shell glance toggle
    \\bind = SUPER, l, spawn, perihelion-lock
    \\bind = ALT, w, spawn, perihelion-shell overview toggle
    \\bind = SUPER+SHIFT, I, restore_minimized
    \\bind = SUPER, j, minimized,
;
const good_auto =
    \\exec_once=dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
    \\exec_once=perihelion-bar-start
    \\exec_once = perihelion-shell
    \\exec_once=swayidle -w timeout 600 perihelion-lock before-sleep perihelion-lock
;

test "parseBind: any spacing, modifiers as a set, arg keeps commas" {
    const a = parseBind("bind = SUPER+SHIFT, I, restore_minimized").?;
    try tt.expectEqual(MOD_SUPER | MOD_SHIFT, a.mods);
    try tt.expectEqualStrings("I", a.key);
    try tt.expectEqualStrings("restore_minimized", a.action);
    try tt.expectEqualStrings("", a.arg);
    const b = parseBind("bind=shift+super,i,spawn,a, b").?;
    try tt.expectEqual(a.mods, b.mods);
    try tt.expectEqualStrings("a, b", b.arg);
    try tt.expectEqual(MOD_ALT, parseBind("  bindl = ALT,w,spawn,x").?.mods);
    try tt.expectEqual(@as(u8, 0), parseBind("bind=NONE,Print,spawn,x").?.mods);
    try tt.expectEqual(MOD_SUPER | MOD_OTHER, parseBind("bind=SUPER+HYPER,i,spawn,x").?.mods);
    try tt.expect(parseBind("# bind = SUPER, i, minimized,") == null);
    try tt.expect(parseBind("mousebind = SUPER, btn_left, moveresize,curmove") == null);
    try tt.expect(parseBind("bind = SUPER, i") == null);
    try tt.expect(parseBind("exec_once=x") == null);
}

test "parseExecOnce and sameWords" {
    try tt.expectEqualStrings("perihelion-shell", parseExecOnce("exec_once = perihelion-shell ").?);
    try tt.expect(parseExecOnce("exec = perihelion-shell") == null);
    try tt.expect(parseExecOnce("#exec_once=perihelion-shell") == null);
    try tt.expect(sameWords("a  b\tc", "a b c"));
    try tt.expect(!sameWords("a b", "a b c"));
    try tt.expect(!sameWords("a b c", "a b"));
    try tt.expect(!sameWords("perihelion-shell glance", "perihelion-shell"));
}

test "a complete config passes, in either spelling" {
    try tt.expect(check(good_config, good_keys, good_auto).ok());
    const iso_keys =
        \\#: Lock screen
        \\bind=SUPER,l,spawn,perihelion-lock
        \\#: Window overview with live previews and search (Perihelion Shell)
        \\bind=ALT,w,spawn,perihelion-shell overview toggle
        \\#: Glance dashboard: clock, weather, calendar, media and system (Esc closes)
        \\bind=SUPER,i,spawn,perihelion-shell glance toggle
        \\key_mode=resize
        \\bind=NONE,Escape,setkeymode,default
        \\key_mode=default
    ;
    try tt.expect(check("source=./cfg/keybinds.conf\nsource=./cfg/autostart.conf", iso_keys, good_auto).ok());
}

test "the old Super+I minimize line is reported" {
    const keys = good_keys ++ "\nbind = SUPER, i, minimized,\n";
    const r = check(good_config, keys, good_auto);
    try tt.expect(r.has(.super_i_other));
    try tt.expect(!r.has(.glance_missing));
    const only_old = "bind = SUPER, i, minimized,\nbind = SUPER, l, spawn, perihelion-lock\n";
    const r2 = check(good_config, only_old, good_auto);
    try tt.expect(r2.has(.super_i_other));
    try tt.expect(r2.has(.glance_missing));
}

test "a second Glance bind and a missing cheatsheet line" {
    const r = check(good_config, good_keys ++ "\nbind=SUPER,I,spawn,perihelion-shell  glance toggle\n", good_auto);
    try tt.expect(r.has(.glance_duplicate));
    const bare = "bind = SUPER, i, spawn, perihelion-shell glance toggle\n";
    try tt.expect(check(good_config, bare, good_auto).has(.glance_no_cheatsheet));
    // A blank line between them is fine; another line isn't.
    try tt.expect(!check(good_config, "#: Glance\n\nbind=SUPER,i,spawn,perihelion-shell glance toggle", good_auto).has(.glance_no_cheatsheet));
    try tt.expect(check(good_config, "#: Glance\n# note\nbind=SUPER,i,spawn,perihelion-shell glance toggle", good_auto).has(.glance_no_cheatsheet));
}

test "Super+Shift+I and binds inside another key mode are not Super+I" {
    const keys = good_keys ++ "\nkey_mode=resize\nbind=SUPER,i,minimized,\nkey_mode=default\n";
    try tt.expect(check(good_config, keys, good_auto).ok());
}

test "lock: missing, or Super+L doing something else" {
    try tt.expect(check(good_config, "#: G\nbind=SUPER,i,spawn,perihelion-shell glance toggle", good_auto).has(.lock_missing));
    try tt.expect(check(good_config, good_keys ++ "\nbind=SUPER,l,spawn,swaylock", good_auto).has(.lock_duplicate));
    try tt.expect(check(good_config, good_keys ++ "\nbind=SUPER,l,spawn,perihelion-lock", good_auto).has(.lock_duplicate));
}

test "autostart: each required line" {
    const r = check(good_config, good_keys, "exec_once = perihelionbar\nexec_once = perihelionbar-shell\n");
    try tt.expect(r.has(.dbus_missing));
    try tt.expect(r.has(.swayidle_missing));
    try tt.expect(r.has(.bar_missing));
    try tt.expect(r.has(.shell_missing));
    try tt.expect(!r.has(.bar_started_twice));
    try tt.expect(check(good_config, good_keys, good_auto ++ "\nexec_once=perihelion-bar").has(.bar_started_twice));
    // Commented out doesn't count.
    try tt.expect(check(good_config, good_keys, "#exec_once=perihelion-bar-start").has(.bar_missing));
}

test "autostart: the one starter line covers everything; listing a piece again is reported" {
    const r = check(good_config, good_keys, "exec_once = perihelion-session-start\n");
    try tt.expect(r.ok());
    const twice = check(good_config, good_keys, "exec_once=perihelion-session-start\nexec_once=perihelion-bar-start\n");
    try tt.expect(twice.has(.started_twice));
    try tt.expect(check(good_config, good_keys, "exec_once=perihelion-session-start\nexec_once=perihelion-shell").has(.started_twice));
    // Commented out, or as `exec` (every reload), it doesn't count.
    try tt.expect(check(good_config, good_keys, "#exec_once=perihelion-session-start").has(.bar_missing));
    try tt.expect(check(good_config, good_keys, "exec=perihelion-session-start").has(.bar_missing));
}

test "config.conf must source both files" {
    const r = check("source=./cfg/monitors.conf\n# source=./cfg/keybinds.conf", good_keys, good_auto);
    try tt.expect(r.has(.source_keybinds_missing));
    try tt.expect(r.has(.source_autostart_missing));
}

test "the repo's own Mango config has everything Perihelion needs" {
    const r = check(@embedFile("mango_config_conf"), @embedFile("mango_keybinds_conf"), @embedFile("mango_autostart_conf"));
    var it = r.problems.iterator();
    while (it.next()) |p| std.debug.print("mango/: {s}\n", .{@tagName(p)});
    try tt.expect(r.ok());
}
