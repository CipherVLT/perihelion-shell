//! Glance's Apps tab: the pure part. The dock's pin list as Glance reads
//! it, Mango's client list, the merge of the two (pinned apps in the dock's
//! order with a running marker, then the running apps no pin owns), the
//! tab's layout and hit-testing, and the argv of every launch. No Wayland,
//! no sockets, no processes: glance_apps_view.zig talks to Mango and paints.
//! `zig build test-glance-apps`.
//!
//! Matching a window to a pin is the dock's own code (../perihelionbar/src/
//! apps.zig), so the running marker here and the dock's dot always agree.

const std = @import("std");
const g = @import("glance.zig");
const Rect = g.Rect;
/// The dock's pin/window logic, shared (../perihelionbar/src/apps.zig).
pub const appsvc = @import("apps");

// --- the pin list -----------------------------------------------------------------

pub const MAX_PINS = 48; // the dock's MAX_LAUNCHERS order of magnitude
pub const MAX_CLIENTS = 32; // the dock's MAX_RUNNING_APPS
pub const MAX_ENTRIES = MAX_PINS + 16; // pins plus the dock's MAX_UNPINNED_GROUPS

pub fn Text(comptime N: usize) type {
    return struct {
        buf: [N]u8 = undefined,
        len: usize = 0,
        const Self = @This();
        pub fn set(self: *Self, s: []const u8) void {
            var n: usize = @min(s.len, N);
            while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }
        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

pub const Pin = struct {
    label: Text(64) = .{},
    command: Text(400) = .{},
    /// The config's explicit icon name ("" = derive it like the dock).
    icon: Text(128) = .{},
    /// Index in config.json "launchers" (what the dock's own menus use).
    config_index: u16 = 0,
};

/// config.json, as far as the pins go (the dock's LauncherButton fields).
const ConfigPins = struct {
    launchers: ?[]const struct {
        label: ?[]const u8 = null,
        command: ?[]const u8 = null,
        icon: ?[]const u8 = null,
    } = null,
};

pub const PinList = struct {
    pins: [MAX_PINS]Pin = undefined,
    len: usize = 0,
    /// config.json had an app-drawer pin (the dock's left bookend).
    has_drawer_pin: bool = false,
    /// config.json had a trash pin (the dock's right bookend).
    has_trash_pin: bool = false,
    /// The file was there but wasn't valid JSON.
    bad: bool = false,

    pub fn slice(self: *const PinList) []const Pin {
        return self.pins[0..self.len];
    }
};

/// The pinned row the dock shows, in its order: config.json "launchers"
/// minus the app-drawer and trash pins (the dock draws those as its fixed
/// bookends, never among the pins). Pins without a command are skipped,
/// as the dock can't launch them either.
pub fn parsePins(bytes: []const u8) PinList {
    var out = PinList{};
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const cfg = std.json.parseFromSliceLeaky(ConfigPins, arena.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch {
        out.bad = true;
        return out;
    };
    const list = cfg.launchers orelse return out;
    for (list, 0..) |l, i| {
        const cmd = std.mem.trim(u8, l.command orelse "", " \t\r\n");
        if (cmd.len == 0) continue;
        if (appsvc.launcherLaunchesAppdrawer(cmd)) {
            out.has_drawer_pin = true;
            continue;
        }
        if (appsvc.launcherIsTrash(cmd)) {
            out.has_trash_pin = true;
            continue;
        }
        if (out.len == MAX_PINS) break;
        var p = Pin{ .config_index = @intCast(@min(i, std.math.maxInt(u16))) };
        p.command.set(cmd);
        p.label.set(l.label orelse "");
        p.icon.set(l.icon orelse "");
        out.pins[out.len] = p;
        out.len += 1;
    }
    return out;
}

// --- Mango's clients ------------------------------------------------------------------

pub const Client = struct {
    /// Mango's numeric client id (what `dispatch focusid,<id>` takes).
    id: u32 = 0,
    appid: Text(64) = .{}, // lowercased, like the dock's
    title: Text(64) = .{}, // lowercased, like the dock's
    /// The appid as Mango spelled it (for the label and the icon lookup).
    appid_raw: Text(64) = .{},
    focused: bool = false,
};

pub const ClientList = struct {
    items: [MAX_CLIENTS]Client = undefined,
    len: usize = 0,

    pub fn slice(self: *const ClientList) []const Client {
        return self.items[0..self.len];
    }

    pub fn eql(a: *const ClientList, b: *const ClientList) bool {
        if (a.len != b.len) return false;
        for (a.slice(), b.slice()) |x, y| {
            if (x.id != y.id or x.focused != y.focused or
                !std.mem.eql(u8, x.appid.slice(), y.appid.slice()) or
                !std.mem.eql(u8, x.title.slice(), y.title.slice())) return false;
        }
        return true;
    }
};

/// Mango's `get all-clients` answer, read the way the dock reads it
/// (perihelionbar main.zig RunningApps.refreshMango): the same JSON helpers,
/// a window needs an appid and a numeric id, focus is `"is_focused":true`.
pub fn parseClients(json: []const u8) ClientList {
    var out = ClientList{};
    var objs = appsvc.topLevelObjects(json);
    while (objs.next()) |obj| {
        if (out.len >= MAX_CLIENTS) break;
        const appid = appsvc.extractJsonString(obj, "\"appid\"") orelse continue;
        if (appid.len == 0) continue;
        const id = appsvc.extractJsonInt(obj, "\"id\"") orelse continue;
        if (id < 0) continue;
        var c = Client{ .id = @intCast(id) };
        c.appid.len = appsvc.lowerCopy(&c.appid.buf, appid);
        c.appid_raw.set(appid);
        if (appsvc.extractJsonString(obj, "\"title\"")) |t| c.title.len = appsvc.lowerCopy(&c.title.buf, t);
        c.focused = std.mem.indexOf(u8, obj, "\"is_focused\":true") != null;
        out.items[out.len] = c;
        out.len += 1;
    }
    return out;
}

// --- the merge ----------------------------------------------------------------------

pub const Entry = struct {
    /// Index into the pin list, or null for a running app no pin owns.
    pin: ?u16 = null,
    /// Windows of this app.
    count: u16 = 0,
    focused: bool = false,
    /// The window a click raises: the focused one, else the first (the
    /// dock's launcherLive / collectUnpinned choice).
    client: ?u16 = null,

    pub fn running(self: Entry) bool {
        return self.count > 0;
    }
};

pub const Merged = struct {
    items: [MAX_ENTRIES]Entry = undefined,
    len: usize = 0,
    /// How many of the first entries are pins (the rest are unpinned running apps).
    pinned: usize = 0,

    pub fn slice(self: *const Merged) []const Entry {
        return self.items[0..self.len];
    }
    pub fn pinnedSlice(self: *const Merged) []const Entry {
        return self.items[0..self.pinned];
    }
    pub fn runningSlice(self: *const Merged) []const Entry {
        return self.items[self.pinned..self.len];
    }
};

/// Pins in the dock's order, each with its windows (the dock's matcher:
/// clientMatchesLauncher), then one entry per appid for the windows no pin
/// owns, in the compositor's order, as the dock's taskbar tail groups them.
pub fn merge(pins: []const Pin, clients: []const Client) Merged {
    var m = Merged{};
    var owned: [MAX_CLIENTS]bool = @splat(false);
    for (pins, 0..) |*p, pi| {
        var e = Entry{ .pin = @intCast(pi) };
        for (clients, 0..) |*c, ci| {
            if (!appsvc.clientMatchesLauncher(p.command.slice(), c.appid.slice(), c.title.slice())) continue;
            owned[ci] = true;
            if (e.count == 0) e.client = @intCast(ci);
            e.count += 1;
            if (c.focused) {
                e.focused = true;
                e.client = @intCast(ci);
            }
        }
        m.items[m.len] = e;
        m.len += 1;
    }
    m.pinned = m.len;
    for (clients, 0..) |*c, ci| {
        if (owned[ci]) continue;
        var found: ?usize = null;
        for (m.items[m.pinned..m.len], m.pinned..) |*e, ei| {
            if (std.mem.eql(u8, clients[e.client.?].appid.slice(), c.appid.slice())) {
                found = ei;
                break;
            }
        }
        if (found) |ei| {
            m.items[ei].count += 1;
            if (c.focused) {
                m.items[ei].focused = true;
                m.items[ei].client = @intCast(ci);
            }
            continue;
        }
        if (m.len == m.items.len) break;
        m.items[m.len] = .{ .count = 1, .focused = c.focused, .client = @intCast(ci) };
        m.len += 1;
    }
    return m;
}

/// A running app's short name: the appid's last dotted part, as the dock's
/// taskbar tail names it ("org.gnome.Nautilus" → "Nautilus").
pub fn shortName(appid: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, appid, '.')) |dot| {
        if (dot + 1 < appid.len) return appid[dot + 1 ..];
    }
    return appid;
}

/// A pin's label: its config label, else the command's match key.
pub fn pinLabel(p: *const Pin, buf: []u8) []const u8 {
    if (p.label.len > 0) return p.label.slice();
    return appsvc.launcherMatchKey(p.command.slice(), buf);
}

// --- argv, never a shell ------------------------------------------------------------------

pub const MAX_ARGV = 24;
pub const ENV: [:0]const u8 = "/usr/bin/env";

/// One launch's argv, NUL-terminated words in its own storage. `env` comes
/// first, so a pin written as `env VAR=x app` keeps working and `app` is
/// found on PATH, exactly as when the dock runs it.
pub const Argv = struct {
    store: [1024]u8 = undefined,
    used: usize = 0,
    words: [MAX_ARGV + 1]?[*:0]const u8 = @as([MAX_ARGV + 1]?[*:0]const u8, @splat(null)),
    n: usize = 0,

    pub fn push(self: *Argv, w: []const u8) bool {
        if (self.n >= MAX_ARGV or self.used + w.len + 1 > self.store.len) return false;
        @memcpy(self.store[self.used..][0..w.len], w);
        self.store[self.used + w.len] = 0;
        self.words[self.n] = @ptrCast(&self.store[self.used]);
        self.used += w.len + 1;
        self.n += 1;
        self.words[self.n] = null;
        return true;
    }

    pub fn ptr(self: *const Argv) [*:null]const ?[*:0]const u8 {
        return @ptrCast(&self.words);
    }

    pub fn word(self: *const Argv, i: usize) []const u8 {
        return std.mem.span(self.words[i].?);
    }
};

/// Splits a pin's command into words the way a POSIX shell would read
/// plain words: blanks separate, '…' is literal, "…" keeps blanks (with \"
/// \\ \$ \` escapes), a backslash outside quotes takes the next character
/// literally. Nothing is expanded or run: no variables, globs, pipes or
/// `;` — pin commands are .desktop Exec lines, which have none of those.
/// False on an unterminated quote or a command too long for the buffers.
pub fn splitCommand(cmd: []const u8, out: *Argv) bool {
    var word: [512]u8 = undefined;
    var wl: usize = 0;
    var in_word = false;
    var i: usize = 0;
    while (i < cmd.len) : (i += 1) {
        const ch = cmd[i];
        switch (ch) {
            ' ', '\t', '\n' => {
                if (in_word) {
                    if (!out.push(word[0..wl])) return false;
                    wl = 0;
                    in_word = false;
                }
            },
            '\'' => {
                in_word = true;
                const end = std.mem.indexOfScalarPos(u8, cmd, i + 1, '\'') orelse return false;
                const part = cmd[i + 1 .. end];
                if (wl + part.len > word.len) return false;
                @memcpy(word[wl..][0..part.len], part);
                wl += part.len;
                i = end;
            },
            '"' => {
                in_word = true;
                i += 1;
                while (true) : (i += 1) {
                    if (i >= cmd.len) return false;
                    var c2 = cmd[i];
                    if (c2 == '"') break;
                    if (c2 == '\\' and i + 1 < cmd.len and std.mem.indexOfScalar(u8, "\"\\$`", cmd[i + 1]) != null) {
                        i += 1;
                        c2 = cmd[i];
                    }
                    if (wl == word.len) return false;
                    word[wl] = c2;
                    wl += 1;
                }
            },
            '\\' => {
                in_word = true;
                if (i + 1 < cmd.len) {
                    i += 1;
                    if (wl == word.len) return false;
                    word[wl] = cmd[i];
                    wl += 1;
                }
            },
            else => {
                in_word = true;
                if (wl == word.len) return false;
                word[wl] = ch;
                wl += 1;
            },
        }
    }
    if (in_word and !out.push(word[0..wl])) return false;
    return true;
}

/// argv for a pin: env, then the command's words. False when it can't be
/// split (the pin isn't launched rather than guessed at).
pub fn launchArgv(cmd: []const u8, out: *Argv) bool {
    out.* = .{};
    if (!out.push("env")) return false;
    if (!splitCommand(cmd, out)) return false;
    return out.n > 1;
}

/// argv for a fixed program with no arguments ("appdrawer", "perihelion-trash").
pub fn programArgv(name: []const u8, out: *Argv) void {
    out.* = .{};
    _ = out.push("env");
    _ = out.push(name);
}

/// The Mango request that raises client `id` (the dock's and the overview's
/// focus request). The id is a number, so nothing else can ride along.
pub fn focusRequest(id: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "dispatch focusid,{d}", .{id}) catch "";
}

// --- layout -------------------------------------------------------------------------

pub const PAD: i32 = 12; // inside a section tile
pub const GAP: i32 = g.GAP; // between sections
pub const HEAD_H: i32 = 56; // the launcher / trash row
pub const CELL_W: i32 = 92;
pub const ICON: i32 = 48;
pub const CELL_GAP: i32 = 8;
pub const TITLE_GAP: i32 = 8; // section heading -> cells

fn cellH(lh: i32) i32 {
    return 8 + ICON + 6 + lh + 8;
}

pub const Layout = struct {
    /// The launcher button (left) and the trash button (right) on the top row.
    launcher: Rect = .{},
    trash: Rect = .{},
    pinned: Rect = .{},
    running: Rect = .{},
    pin_cells: [MAX_ENTRIES]Rect = @as([MAX_ENTRIES]Rect, @splat(.{})),
    pin_shown: usize = 0,
    run_cells: [MAX_ENTRIES]Rect = @as([MAX_ENTRIES]Rect, @splat(.{})),
    run_shown: usize = 0,
    /// Entries left out for lack of room ("+N" in the last cell).
    pin_more: usize = 0,
    run_more: usize = 0,
    cols: usize = 0,

    pub fn pinCells(self: *const Layout) []const Rect {
        return self.pin_cells[0..self.pin_shown];
    }
    pub fn runCells(self: *const Layout) []const Rect {
        return self.run_cells[0..self.run_shown];
    }
};

fn rowsFor(n: usize, cols: usize) usize {
    if (cols == 0) return 0;
    return (n + cols - 1) / cols;
}

/// Places `n` cells row by row in `r` below its heading, from the left; when they don't
/// all fit, the last shown cell becomes "+N".
fn placeCells(out: []Rect, r: Rect, n: usize, cols: usize, rows: usize, lh: i32) struct { shown: usize, more: usize } {
    const cap = cols * rows;
    const shown = @min(n, cap);
    const ch = cellH(lh);
    // Left-aligned under the section's heading.
    const x0 = r.x + PAD;
    const y0 = r.y + PAD + lh + TITLE_GAP;
    for (0..shown) |i| {
        const col: i32 = @intCast(i % cols);
        const row: i32 = @intCast(i / cols);
        out[i] = .{ .x = x0 + col * (CELL_W + CELL_GAP), .y = y0 + row * (ch + CELL_GAP), .w = CELL_W, .h = ch };
    }
    // Shown cells include the "+N" one, which stands for the rest.
    const more = if (n > cap and cap > 0) n - cap + 1 else 0;
    return .{ .shown = shown, .more = more };
}

/// Lays the tab out in the content rect `c`: the launcher and trash
/// buttons on top, then the Pinned section and the Running section, each a
/// grid of icon cells. Rows go to Pinned first, but Running always keeps
/// at least one row; a section with nothing in it keeps one row for its
/// empty message.
pub fn layout(c: Rect, lh: i32, n_pinned: usize, n_running: usize) Layout {
    var l = Layout{};
    const btn_w = @min(@divTrunc(c.w - GAP, 2), 300);
    l.launcher = .{ .x = c.x, .y = c.y, .w = btn_w, .h = HEAD_H };
    l.trash = .{ .x = c.x + c.w - btn_w, .y = c.y, .w = btn_w, .h = HEAD_H };

    const inner_w = c.w - 2 * PAD;
    l.cols = @intCast(std.math.clamp(@divTrunc(inner_w + CELL_GAP, CELL_W + CELL_GAP), 1, 16));
    const ch = cellH(lh);
    const sec_over = 2 * PAD + lh + TITLE_GAP; // a section's fixed height
    const avail = c.h - HEAD_H - 2 * GAP - 2 * sec_over;
    const rows_total: usize = @intCast(@max(@divTrunc(avail + CELL_GAP, ch + CELL_GAP), 2));
    const want_p = @max(rowsFor(n_pinned, l.cols), 1);
    const want_r = @max(rowsFor(n_running, l.cols), 1);
    var rows_p = @min(want_p, rows_total - 1);
    const rows_r = @min(want_r, rows_total - rows_p);
    // Running needs fewer than it was offered: give the rest back to Pinned.
    rows_p = @min(want_p, rows_total - rows_r);

    const sec_h = struct {
        fn f(rows: usize, cell_h: i32, over: i32) i32 {
            const r: i32 = @intCast(rows);
            return over + r * cell_h + (r - 1) * CELL_GAP;
        }
    }.f;
    const py = c.y + HEAD_H + GAP;
    l.pinned = .{ .x = c.x, .y = py, .w = c.w, .h = sec_h(rows_p, ch, sec_over) };
    const ry = l.pinned.y + l.pinned.h + GAP;
    // Running takes the rest of the height down to the content's bottom.
    l.running = .{ .x = c.x, .y = ry, .w = c.w, .h = @max(c.y + c.h - ry, sec_h(rows_r, ch, sec_over)) };
    const p = placeCells(&l.pin_cells, l.pinned, n_pinned, l.cols, rows_p, lh);
    l.pin_shown = p.shown;
    l.pin_more = p.more;
    const r = placeCells(&l.run_cells, l.running, n_running, l.cols, rows_r, lh);
    l.run_shown = r.shown;
    l.run_more = r.more;
    return l;
}

pub const Hit = union(enum) {
    none,
    launcher,
    trash,
    pinned: u8,
    running: u8,

    pub fn eql(a: Hit, b: Hit) bool {
        return switch (a) {
            .none => b == .none,
            .launcher => b == .launcher,
            .trash => b == .trash,
            .pinned => |i| b == .pinned and b.pinned == i,
            .running => |i| b == .running and b.running == i,
        };
    }
};

/// Panel-local point → what's under it. The "+N" cell isn't an app.
pub fn hitTest(l: *const Layout, x: i32, y: i32) Hit {
    if (l.launcher.contains(x, y)) return .launcher;
    if (l.trash.contains(x, y)) return .trash;
    for (l.pinCells(), 0..) |r, i| {
        if (l.pin_more > 0 and i + 1 == l.pin_shown) break;
        if (r.contains(x, y)) return .{ .pinned = @intCast(i) };
    }
    for (l.runCells(), 0..) |r, i| {
        if (l.run_more > 0 and i + 1 == l.run_shown) break;
        if (r.contains(x, y)) return .{ .running = @intCast(i) };
    }
    return .none;
}

/// What a click on an app does: raise its window when it has one, else
/// launch the pin (the dock's left click, minus its window cycling: Glance
/// closes after the click, so there is nothing to cycle through).
pub const AppAction = union(enum) { none, focus: u32, launch: u16 };

pub fn clickAction(e: Entry, clients: []const Client) AppAction {
    if (e.client) |ci| {
        if (ci < clients.len) return .{ .focus = clients[ci].id };
    }
    if (e.pin) |pi| return .{ .launch = pi };
    return .none;
}

// --- empty states -----------------------------------------------------------------------

pub fn pinnedEmpty(pins: *const PinList) []const u8 {
    if (pins.bad) return "The dock's pin list (config.json) couldn't be read.";
    return "Nothing pinned. Pin apps from the app drawer (right-click an app, Pin to dock).";
}

pub fn runningEmpty(no_compositor: bool, any_windows: bool) []const u8 {
    if (no_compositor) return "Running apps are listed under MangoWM.";
    if (any_windows) return "Every open app is pinned above.";
    return "No windows open.";
}

/// "Trash · 3 items" style status under the trash button's label.
pub fn trashText(full: bool) []const u8 {
    return if (full) "Has items \u{00B7} open in Files" else "Empty";
}

// --- tests --------------------------------------------------------------------------------

const tt = std.testing;

const CONFIG =
    \\{"appearance": {"x": 1}, "launchers": [
    \\  {"label": "Apps", "command": "appdrawer", "display": "icon"},
    \\  {"label": "Files", "command": "nautilus --new-window", "icon": "org.gnome.Nautilus"},
    \\  {"label": "Browser", "command": "perihelionbar-launch-browser"},
    \\  {"label": "", "command": "/usr/bin/flatpak run --branch=stable com.spotify.Client @@u @@"},
    \\  {"label": "Broken", "command": "   "},
    \\  {"label": "Trash", "command": "perihelion-trash"},
    \\  {"label": "Term", "command": "env GDK_BACKEND=wayland foot"}
    \\], "dock": {"enabled": true}}
;

test "parsePins: the dock's order, without its drawer and trash bookends" {
    const pl = parsePins(CONFIG);
    try tt.expect(!pl.bad and pl.has_drawer_pin and pl.has_trash_pin);
    try tt.expectEqual(@as(usize, 4), pl.len);
    try tt.expectEqualStrings("Files", pl.pins[0].label.slice());
    try tt.expectEqualStrings("org.gnome.Nautilus", pl.pins[0].icon.slice());
    try tt.expectEqual(@as(u16, 1), pl.pins[0].config_index);
    try tt.expectEqualStrings("perihelionbar-launch-browser", pl.pins[1].command.slice());
    try tt.expectEqual(@as(u16, 6), pl.pins[3].config_index); // indices stay config's
    var kb: [64]u8 = undefined;
    try tt.expectEqualStrings("com.spotify.client", pinLabel(&pl.pins[2], &kb));
    // Missing file content, no launchers, bad JSON.
    try tt.expectEqual(@as(usize, 0), parsePins("{}").len);
    try tt.expect(!parsePins("{}").bad);
    try tt.expect(parsePins("{\"launchers\": [").bad);
    try tt.expect(parsePins("").bad);
}

const CLIENTS =
    \\[{"id":7,"appid":"org.gnome.Nautilus","title":"Home","is_focused":false,"tags":[1]},
    \\{"id":9,"appid":"firefox","title":"Mozilla \"Firefox\" {x}","is_focused":true,"tags":[2]},
    \\{"id":11,"appid":"foot","title":"~","is_focused":false,"tags":[1]},
    \\{"id":12,"appid":"Alacritty","title":"a","is_focused":false,"tags":[3]},
    \\{"id":13,"appid":"Alacritty","title":"b","is_focused":false,"tags":[3]},
    \\{"id":14,"appid":"","title":"no appid","is_focused":false},
    \\{"appid":"noid","title":"x"}]
;

test "parseClients: the dock's rules (appid and id required, focus flag)" {
    const cl = parseClients(CLIENTS);
    try tt.expectEqual(@as(usize, 5), cl.len);
    try tt.expectEqual(@as(u32, 7), cl.items[0].id);
    try tt.expectEqualStrings("org.gnome.nautilus", cl.items[0].appid.slice());
    try tt.expectEqualStrings("org.gnome.Nautilus", cl.items[0].appid_raw.slice());
    try tt.expect(cl.items[1].focused and !cl.items[0].focused);
    try tt.expectEqual(@as(usize, 0), parseClients("").len);
    try tt.expectEqual(@as(usize, 0), parseClients("garbage [{").len);
    var a = parseClients(CLIENTS);
    const b = parseClients(CLIENTS);
    try tt.expect(a.eql(&b));
    a.items[2].focused = true;
    try tt.expect(!a.eql(&b));
}

test "merge: pins with their windows, then unpinned apps grouped by appid" {
    const pl = parsePins(CONFIG);
    const cl = parseClients(CLIENTS);
    const m = merge(pl.slice(), cl.slice());
    try tt.expectEqual(@as(usize, 4), m.pinned);
    const files = m.items[0];
    try tt.expectEqual(@as(u16, 1), files.count);
    try tt.expectEqual(@as(?u16, 0), files.client);
    const browser = m.items[1];
    try tt.expect(browser.focused and browser.count == 1);
    try tt.expectEqual(@as(?u16, 1), browser.client);
    try tt.expect(!m.items[2].running()); // spotify isn't open
    try tt.expectEqual(@as(u16, 1), m.items[3].count); // env … foot matches foot
    // Unpinned: the two Alacritty windows fold into one entry.
    const rs = m.runningSlice();
    try tt.expectEqual(@as(usize, 1), rs.len);
    try tt.expectEqual(@as(u16, 2), rs[0].count);
    try tt.expect(rs[0].pin == null);
    try tt.expectEqualStrings("Alacritty", shortName(cl.items[rs[0].client.?].appid_raw.slice()));
    // No pins: every app is "running"; no windows: pins only, none running.
    const only = merge(&.{}, cl.slice());
    try tt.expectEqual(@as(usize, 0), only.pinned);
    try tt.expectEqual(@as(usize, 4), only.len);
    const idle = merge(pl.slice(), &.{});
    try tt.expectEqual(@as(usize, 4), idle.len);
    for (idle.slice()) |e| try tt.expect(!e.running());
}

test "clickAction: raise a window, else launch the pin" {
    const pl = parsePins(CONFIG);
    const cl = parseClients(CLIENTS);
    const m = merge(pl.slice(), cl.slice());
    try tt.expectEqual(AppAction{ .focus = 9 }, clickAction(m.items[1], cl.slice()));
    try tt.expectEqual(AppAction{ .launch = 2 }, clickAction(m.items[2], cl.slice()));
    try tt.expectEqual(AppAction{ .focus = 12 }, clickAction(m.runningSlice()[0], cl.slice()));
    try tt.expectEqual(AppAction.none, clickAction(.{}, cl.slice()));
}

test "shortName" {
    try tt.expectEqualStrings("Nautilus", shortName("org.gnome.Nautilus"));
    try tt.expectEqualStrings("foot", shortName("foot"));
    try tt.expectEqualStrings("odd.", shortName("odd."));
}

test "splitCommand: words, quotes and escapes, nothing run or expanded" {
    var a: Argv = .{};
    try tt.expect(launchArgv("nautilus --new-window", &a));
    try tt.expectEqual(@as(usize, 3), a.n);
    try tt.expectEqualStrings("env", a.word(0));
    try tt.expectEqualStrings("nautilus", a.word(1));
    try tt.expectEqualStrings("--new-window", a.word(2));
    try tt.expect(a.words[3] == null);
    try tt.expect(launchArgv("env GDK_BACKEND=wayland  foot", &a));
    try tt.expectEqualStrings("GDK_BACKEND=wayland", a.word(2));
    try tt.expectEqualStrings("foot", a.word(3));
    // Quoted words stay one argument; shell syntax is just text.
    try tt.expect(launchArgv("app 'two words' \"say \\\"hi\\\" $HOME\" a\\ b ';' x;rm", &a));
    try tt.expectEqualStrings("two words", a.word(2));
    try tt.expectEqualStrings("say \"hi\" $HOME", a.word(3));
    try tt.expectEqualStrings("a b", a.word(4));
    try tt.expectEqualStrings(";", a.word(5));
    try tt.expectEqualStrings("x;rm", a.word(6));
    try tt.expect(launchArgv("app ''", &a));
    try tt.expectEqual(@as(usize, 3), a.n); // '' is an empty argument
    // Refused, not guessed: unterminated quotes, blanks only.
    try tt.expect(!launchArgv("app 'oops", &a));
    try tt.expect(!launchArgv("app \"oops", &a));
    try tt.expect(!launchArgv("   ", &a));
    // Too many words or too long: refused.
    var many: [80]u8 = undefined;
    for (0..40) |i| {
        many[2 * i] = 'a';
        many[2 * i + 1] = ' ';
    }
    try tt.expect(!launchArgv(&many, &a));
    programArgv("appdrawer", &a);
    try tt.expectEqual(@as(usize, 2), a.n);
    try tt.expectEqualStrings("appdrawer", a.word(1));
}

test "focusRequest is the dock's Mango request with a numeric id" {
    var b: [40]u8 = undefined;
    try tt.expectEqualStrings("dispatch focusid,42", focusRequest(42, &b));
}

/// The Glance content rect at the 13 px font.
const CONTENT = Rect{ .x = 20, .y = 70, .w = 890, .h = 439 };
const LH: i32 = 17;

fn inside(o: Rect, r: Rect) bool {
    return r.x >= o.x and r.y >= o.y and r.x + r.w <= o.x + o.w and r.y + r.h <= o.y + o.h;
}

fn overlaps(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

test "layout: buttons on top, two sections, cells inside, no overlaps" {
    const l = layout(CONTENT, LH, 6, 3);
    try tt.expect(!overlaps(l.launcher, l.trash));
    try tt.expectEqual(CONTENT.x + CONTENT.w, l.trash.x + l.trash.w);
    try tt.expectEqual(@as(usize, 8), l.cols); // (866 + 8) / 100
    try tt.expectEqual(@as(usize, 6), l.pin_shown);
    try tt.expectEqual(@as(usize, 3), l.run_shown);
    try tt.expectEqual(@as(usize, 0), l.pin_more);
    for ([_]Rect{ l.launcher, l.trash, l.pinned, l.running }) |r| try tt.expect(inside(CONTENT, r));
    try tt.expect(l.pinned.y >= l.launcher.y + l.launcher.h);
    try tt.expect(l.running.y >= l.pinned.y + l.pinned.h);
    try tt.expectEqual(CONTENT.y + CONTENT.h, l.running.y + l.running.h);
    for (l.pinCells(), 0..) |r, i| {
        try tt.expect(inside(l.pinned, r));
        for (l.pinCells()[i + 1 ..]) |o| try tt.expect(!overlaps(r, o));
    }
    for (l.runCells()) |r| try tt.expect(inside(l.running, r));
}

test "layout: overflow shows +N; running keeps a row; empty sections keep one" {
    // 30 pins: more than fit in the rows left after Running's one.
    const l = layout(CONTENT, LH, 30, 2);
    try tt.expect(l.pin_more > 0);
    try tt.expectEqual(@as(usize, 30), l.pin_shown - 1 + l.pin_more);
    try tt.expectEqual(@as(usize, 2), l.run_shown);
    for (l.pinCells()) |r| try tt.expect(inside(l.pinned, r));
    // The "+N" cell isn't clickable; the one before it is.
    const last = l.pin_cells[l.pin_shown - 1];
    try tt.expect(hitTest(&l, last.x + 2, last.y + 2) == .none);
    const prev = l.pin_cells[l.pin_shown - 2];
    try tt.expect(hitTest(&l, prev.x + 2, prev.y + 2).eql(.{ .pinned = @intCast(l.pin_shown - 2) }));
    // Nothing at all: both sections still there, for their messages.
    const e = layout(CONTENT, LH, 0, 0);
    try tt.expect(e.pinned.h > 0 and e.running.h > 0);
    try tt.expectEqual(@as(usize, 0), e.pin_shown + e.run_shown);
}

test "hitTest: launcher, trash, pinned and running cells" {
    const l = layout(CONTENT, LH, 4, 2);
    try tt.expect(hitTest(&l, l.launcher.x + 3, l.launcher.y + 3) == .launcher);
    try tt.expect(hitTest(&l, l.trash.x + 3, l.trash.y + 3) == .trash);
    const p2 = l.pin_cells[2];
    try tt.expect(hitTest(&l, p2.x + 1, p2.y + 1).eql(.{ .pinned = 2 }));
    const r1 = l.run_cells[1];
    try tt.expect(hitTest(&l, r1.x + r1.w - 1, r1.y + r1.h - 1).eql(.{ .running = 1 }));
    try tt.expect(hitTest(&l, l.pinned.x + 1, l.pinned.y + 1) == .none);
    try tt.expect(!Hit.eql(.{ .pinned = 1 }, .{ .running = 1 }));
}

test "empty-state text" {
    try tt.expect(std.mem.indexOf(u8, pinnedEmpty(&parsePins("{}")), "Nothing pinned") != null);
    try tt.expect(std.mem.indexOf(u8, pinnedEmpty(&parsePins("{")), "couldn't be read") != null);
    try tt.expectEqualStrings("No windows open.", runningEmpty(false, false));
    try tt.expectEqualStrings("Every open app is pinned above.", runningEmpty(false, true));
    try tt.expect(std.mem.indexOf(u8, runningEmpty(true, false), "MangoWM") != null);
    try tt.expectEqualStrings("Empty", trashText(false));
}
