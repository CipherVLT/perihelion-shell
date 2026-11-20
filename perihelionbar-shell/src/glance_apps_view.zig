//! Glance's Apps tab, the live side: the dock's pin list and icons, Mango's
//! window list, launches and focus, and the painting. The rules (pins,
//! client parsing, the pinned/running merge, argv, layout, hit-testing)
//! live in glance_apps.zig and are unit-tested there; the pin/window
//! matching and the icon-name rules are the dock's own (../perihelionbar/
//! src/apps.zig).
//!
//! Exists only while the Apps tab is on screen: glance_view.zig creates it
//! when the tab is shown and frees it (icons, the desktop index, Mango's
//! event connection) when another tab is picked or Glance closes. While it
//! exists it listens to Mango's `watch all-tags` events, like the dock,
//! with a 2 s re-read as the dock also does (focus moves within a tag
//! don't always emit), and repaints only when the list actually changed.

const std = @import("std");
const posix = std.posix;
const font_mod = @import("font");
const logging = @import("logging");
const widgets = @import("widgets");
const icontheme = @import("icontheme");
const desktop_entries = @import("desktop_entries");
const fastfetch = @import("fastfetch");
const g = @import("glance.zig");
const ga = @import("glance_apps.zig");
const gv = @import("glance_view.zig");
const appsvc = ga.appsvc;

/// The dock re-reads the window list on this cadence too.
const POLL_MS: i64 = 2000;
const ICON_PX: u32 = @intCast(ga.ICON);
const HEAD_ICON: i32 = 36;
const MAX_RUN_ICONS = 24;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn clock_gettime(clockid: c_int, tp: *posix.timespec) c_int;
const libc_dir = struct {
    extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
    extern "c" fn readdir(dirp: *anyopaque) ?*const Dirent;
    extern "c" fn closedir(dirp: *anyopaque) c_int;
    const Dirent = extern struct {
        d_ino: u64,
        d_off: i64,
        d_reclen: u16,
        d_type: u8,
        d_name: [256]u8,
    };
};

fn nowMs() i64 {
    var tp: posix.timespec = undefined;
    if (clock_gettime(1, &tp) != 0) return 0; // CLOCK_MONOTONIC
    return @as(i64, @intCast(tp.sec)) * 1000 + @divTrunc(@as(i64, @intCast(tp.nsec)), 1_000_000);
}

// --- what pinIconName asks of the system (the bar answers the same way) ---------

fn onPath(binary: []const u8) bool {
    const path_env = std.mem.sliceTo(getenv("PATH") orelse return false, 0);
    var it = std.mem.splitScalar(u8, path_env, ':');
    var buf: [256]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, binary }, 0) catch continue;
        if (access(full.ptr, 1) == 0) return true; // X_OK
    }
    return false;
}

fn iconResolves(icon: []const u8) bool {
    var pbuf: [512]u8 = undefined;
    return icontheme.resolveIconPath(icon, &pbuf) != null;
}

fn readSmall(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const raw = posix.system.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw < 0) return null;
    const fd: posix.fd_t = @intCast(raw);
    defer _ = posix.system.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = posix.read(fd, buf[len..]) catch return null;
        if (n == 0) return buf[0..len];
        len += n;
    }
    return null; // too big for what we read here
}

fn readChoice(file: []const u8, buf: []u8) []const u8 {
    const home = std.mem.sliceTo(getenv("HOME") orelse return "", 0);
    var pb: [300]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "{s}/.config/perihelionbar/{s}", .{ home, file }, 0) catch return "";
    var raw: [256]u8 = undefined;
    const data = readSmall(path, &raw) orelse return "";
    const t = std.mem.trim(u8, data, " \t\r\n");
    const n = @min(buf.len, t.len);
    @memcpy(buf[0..n], t[0..n]);
    return buf[0..n];
}

const probe = appsvc.Probe{ .on_path = onPath, .icon_resolves = iconResolves, .choice = readChoice };

/// The dock's trash check: anything in ~/.local/share/Trash/files.
fn trashHasFiles() bool {
    const home = std.mem.sliceTo(getenv("HOME") orelse return false, 0);
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "{s}/.local/share/Trash/files", .{home}, 0) catch return false;
    const d = libc_dir.opendir(path.ptr) orelse return false;
    defer _ = libc_dir.closedir(d);
    while (libc_dir.readdir(d)) |e| {
        const n = std.mem.sliceTo(&e.d_name, 0);
        if (!std.mem.eql(u8, n, ".") and !std.mem.eql(u8, n, "..")) return true;
    }
    return false;
}

/// The desktop icon index, filled the way the bar fills it at startup
/// (perihelionbar main.zig buildDesktopIndex): executable basename, then
/// StartupWMClass, then the file stem, first source wins.
fn buildIndex() void {
    appsvc.desktop_idx_len = 0;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var list: std.ArrayList(desktop_entries.DesktopEntry) = .empty;
    desktop_entries.enumerateInstalledApps(arena.allocator(), &list) catch return;
    for (list.items) |app| {
        if (app.icon.len == 0) continue;
        var first = app.exec;
        if (std.mem.indexOfScalar(u8, first, ' ')) |sp| first = first[0..sp];
        if (std.mem.lastIndexOfScalar(u8, first, '/')) |sl| first = first[sl + 1 ..];
        var kbuf: [64]u8 = undefined;
        appsvc.desktopIndexAdd(kbuf[0..appsvc.lowerCopy(&kbuf, first)], app.icon);
        if (app.wm_class.len > 0) appsvc.desktopIndexAdd(kbuf[0..appsvc.lowerCopy(&kbuf, app.wm_class)], app.icon);
        if (app.id.len > 0) appsvc.desktopIndexAdd(kbuf[0..appsvc.lowerCopy(&kbuf, app.id)], app.icon);
    }
}

/// os-release ID → the distro's Nerd Font glyph (the dock's launcher logo).
fn distroGlyph() u32 {
    var buf: [4096]u8 = undefined;
    const text = readSmall("/etc/os-release", &buf) orelse return fastfetch.distroGlyph("linux");
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "ID=")) continue;
        var id = std.mem.trim(u8, line[3..], " \t\r\"'");
        var lb: [32]u8 = undefined;
        id = lb[0..appsvc.lowerCopy(&lb, id)];
        return fastfetch.distroGlyph(id);
    }
    return fastfetch.distroGlyph("linux");
}

// --- Mango IPC (the dock's socket and requests) -------------------------------------

fn connectSock(path: []const u8) ?posix.fd_t {
    var addr: std.os.linux.sockaddr.un = .{ .path = undefined };
    if (path.len >= addr.path.len) return null;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    const raw = std.c.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0);
    if (raw < 0) return null;
    const fd: posix.fd_t = @intCast(raw);
    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.os.linux.sockaddr.un)) != 0) {
        _ = posix.system.close(fd);
        return null;
    }
    return fd;
}

fn writeAll(fd: posix.fd_t, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// One request, read to EOF into `out` (Mango closes after replying).
fn mangoRequest(sock: []const u8, cmd: []const u8, out: []u8) ?[]const u8 {
    const fd = connectSock(sock) orelse return null;
    defer _ = posix.system.close(fd);
    if (!writeAll(fd, cmd) or !writeAll(fd, "\n")) return null;
    var len: usize = 0;
    while (len < out.len) {
        const n = posix.read(fd, out[len..]) catch return null;
        if (n == 0) break;
        len += n;
    }
    return out[0..len];
}

// --- the tab ---------------------------------------------------------------------

const RunIcon = struct {
    appid: ga.Text(64) = .{},
    px: ?[]u32 = null,
};

pub const AppsTab = struct {
    gpa: std.mem.Allocator,
    pins: ga.PinList = .{},
    clients: ga.ClientList = .{},
    merged: ga.Merged = .{},
    layout: ga.Layout = .{},
    hover: ga.Hit = .none,
    press_hit: ?ga.Hit = null,
    sock: ga.Text(256) = .{},
    watch_fd: posix.fd_t = -1,
    next_poll_ms: i64 = 0,
    drawer_ok: bool = false,
    trash_full: bool = false,
    glyph: u32 = 0,
    pin_icons: [ga.MAX_PINS]?[]u32 = @as([ga.MAX_PINS]?[]u32, @splat(null)),
    run_icons: [MAX_RUN_ICONS]RunIcon = @as([MAX_RUN_ICONS]RunIcon, @splat(.{})),
    trash_icons: [2]?[]u32 = .{ null, null }, // empty, full

    /// Everything the tab shows, read once on the way in.
    pub fn open(self: *AppsTab) void {
        const t0 = nowMs();
        buildIndex();
        self.loadPins();
        self.drawer_ok = onPath("appdrawer");
        self.glyph = distroGlyph();
        self.trash_full = trashHasFiles();
        // The dock's trash icon names, empty and full.
        const names = [2][4][]const u8{
            .{ "perihelion-trash", "user-trash", "perihelion-trash-full", "user-trash-full" },
            .{ "perihelion-trash-full", "perihelion-trash", "user-trash-full", "user-trash" },
        };
        for (names, 0..) |list, i| {
            for (list) |n| {
                if (self.decode(n, @intCast(HEAD_ICON))) |px| {
                    self.trash_icons[i] = px;
                    break;
                }
            }
        }
        if (getenv("MANGO_INSTANCE_SIGNATURE")) |sig| {
            self.sock.set(std.mem.sliceTo(sig, 0));
            self.openWatch();
        }
        _ = self.refreshClients();
        self.next_poll_ms = nowMs() + POLL_MS;
        logging.step("glance: apps tab ready ({d} pins, {d} windows) in {d} ms", .{ self.pins.len, self.clients.len, nowMs() - t0 });
    }

    pub fn deinit(self: *AppsTab) void {
        if (self.watch_fd >= 0) _ = posix.system.close(self.watch_fd);
        self.watch_fd = -1;
        for (&self.pin_icons) |*p| {
            if (p.*) |px| self.gpa.free(px);
            p.* = null;
        }
        for (&self.run_icons) |*r| {
            if (r.px) |px| self.gpa.free(px);
            r.* = .{};
        }
        for (&self.trash_icons) |*p| {
            if (p.*) |px| self.gpa.free(px);
            p.* = null;
        }
        appsvc.desktop_idx_len = 0; // the index is only needed while the tab is up
    }

    fn loadPins(self: *AppsTab) void {
        const home = std.mem.sliceTo(getenv("HOME") orelse "/root", 0);
        var pb: [400]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "{s}/.config/perihelionbar/config.json", .{home}, 0) catch return;
        const buf = self.gpa.alloc(u8, 256 * 1024) catch return;
        defer self.gpa.free(buf);
        const bytes = readSmall(path, buf) orelse {
            self.pins = .{}; // no config yet: nothing pinned
            return;
        };
        self.pins = ga.parsePins(bytes);
        for (self.pins.slice(), 0..) |*p, i| {
            var nb: [128]u8 = undefined;
            const name: ?[]const u8 = if (p.icon.len > 0) p.icon.slice() else appsvc.pinIconName(p.command.slice(), probe, &nb);
            if (name) |n| self.pin_icons[i] = self.decode(n, ICON_PX);
        }
    }

    /// Icon name or path → a size x size ARGB tile (null when there's none).
    fn decode(self: *AppsTab, name: []const u8, size: u32) ?[]u32 {
        var pbuf: [512]u8 = undefined;
        const path = icontheme.resolveIconPath(name, &pbuf) orelse return null;
        return self.decodePath(path, size);
    }

    fn decodePath(self: *AppsTab, path: []const u8, size: u32) ?[]u32 {
        var zb: [520]u8 = undefined;
        if (path.len >= zb.len) return null;
        @memcpy(zb[0..path.len], path);
        zb[path.len] = 0;
        const d = icontheme.decodeIcon(self.gpa, zb[0..path.len :0], size) catch return null;
        defer self.gpa.free(d.pixels);
        const square = self.gpa.alloc(u32, @as(usize, size) * size) catch return null;
        icontheme.copyIntoIconBuffer(d, square, size);
        return square;
    }

    /// The running app's icon, found the dock's way (Steam's cache, then
    /// apps.runningIconNames), resolved once per appid while the tab is up.
    fn runIcon(self: *AppsTab, appid: []const u8) ?[]u32 {
        for (&self.run_icons) |*r| {
            if (r.appid.len > 0 and std.mem.eql(u8, r.appid.slice(), appid)) return r.px;
        }
        for (&self.run_icons) |*r| {
            if (r.appid.len != 0) continue;
            r.appid.set(appid);
            var sb: [512]u8 = undefined;
            if (icontheme.steamGameIconPath(appid, &sb)) |p| r.px = self.decodePath(p, ICON_PX);
            if (r.px == null) {
                const names = appsvc.runningIconNames(appid);
                for (names.slice()) |n| {
                    r.px = self.decode(n, ICON_PX);
                    if (r.px != null) break;
                }
            }
            return r.px;
        }
        return null; // cache full: the letter tile
    }

    fn openWatch(self: *AppsTab) void {
        const fd = connectSock(self.sock.slice()) orelse return;
        if (!writeAll(fd, "watch all-tags\n")) {
            _ = posix.system.close(fd);
            return;
        }
        self.watch_fd = fd;
    }

    /// Re-reads the window list; true when it changed.
    fn refreshClients(self: *AppsTab) bool {
        if (self.sock.len == 0) return false;
        var buf: [64 * 1024]u8 = undefined;
        // A failed request keeps the last list (like the dock).
        const json = mangoRequest(self.sock.slice(), "get all-clients", &buf) orelse return false;
        const next = ga.parseClients(json);
        if (next.eql(&self.clients)) return false;
        self.clients = next;
        self.merged = ga.merge(self.pins.slice(), self.clients.slice());
        return true;
    }

    // --- schedule -------------------------------------------------------------------

    pub fn pollFds(self: *const AppsTab, out: []posix.fd_t) usize {
        if (self.watch_fd < 0 or out.len == 0) return 0;
        out[0] = self.watch_fd;
        return 1;
    }

    pub fn deadline(self: *const AppsTab) i64 {
        return self.next_poll_ms;
    }

    /// The 2 s re-read (windows and trash); true when something shown changed.
    pub fn tick(self: *AppsTab, now: i64) bool {
        if (now < self.next_poll_ms) return false;
        self.next_poll_ms = now + POLL_MS;
        var changed = self.refreshClients();
        const full = trashHasFiles();
        if (full != self.trash_full) {
            self.trash_full = full;
            changed = true;
        }
        return changed;
    }

    /// A Mango event arrived: drain it and re-read the list.
    pub fn onPipes(self: *AppsTab) bool {
        if (self.watch_fd < 0 or !widgets.fdReadable(self.watch_fd)) return false;
        var drain: [4096]u8 = undefined;
        const n = posix.read(self.watch_fd, &drain) catch 0;
        if (n == 0) {
            // The stream ended (compositor restart): the 2 s re-read carries on.
            _ = posix.system.close(self.watch_fd);
            self.watch_fd = -1;
        }
        return self.refreshClients();
    }

    // --- input -------------------------------------------------------------------

    pub fn motion(self: *AppsTab, x: i32, y: i32) bool {
        const h = ga.hitTest(&self.layout, x, y);
        if (h.eql(self.hover)) return false;
        self.hover = h;
        return true;
    }

    pub fn leave(self: *AppsTab) bool {
        const was = self.hover != .none;
        self.hover = .none;
        self.press_hit = null;
        return was;
    }

    pub fn press(self: *AppsTab, x: i32, y: i32) void {
        self.press_hit = ga.hitTest(&self.layout, x, y);
    }

    /// Press and release on the same thing is a click. True when it
    /// launched or raised something, so Glance closes to show it.
    pub fn release(self: *AppsTab, x: i32, y: i32) bool {
        const pr = self.press_hit orelse return false;
        self.press_hit = null;
        const h = ga.hitTest(&self.layout, x, y);
        if (!pr.eql(h)) return false;
        var a: ga.Argv = .{};
        switch (h) {
            .none => return false,
            .launcher => {
                if (!self.drawer_ok) return false;
                ga.programArgv("appdrawer", &a);
                widgets.spawnDetachedArgv(ga.ENV, a.ptr());
                return true;
            },
            .trash => {
                ga.programArgv("perihelion-trash", &a);
                widgets.spawnDetachedArgv(ga.ENV, a.ptr());
                return true;
            },
            .pinned => |i| return self.activate(i),
            .running => |i| return self.activate(@intCast(self.merged.pinned + i)),
        }
    }

    fn activate(self: *AppsTab, idx: usize) bool {
        if (idx >= self.merged.len) return false;
        switch (ga.clickAction(self.merged.items[idx], self.clients.slice())) {
            .none => return false,
            .focus => |id| {
                var rb: [48]u8 = undefined;
                var out: [256]u8 = undefined;
                _ = mangoRequest(self.sock.slice(), ga.focusRequest(id, &rb), &out);
                return true;
            },
            .launch => |pi| {
                var a: ga.Argv = .{};
                if (!ga.launchArgv(self.pins.pins[pi].command.slice(), &a)) {
                    logging.warn("glance: can't split pin command \"{s}\"", .{self.pins.pins[pi].command.slice()});
                    return false;
                }
                widgets.spawnDetachedArgv(ga.ENV, a.ptr());
                return true;
            },
        }
    }

    // --- painting --------------------------------------------------------------------

    pub fn render(self: *AppsTab, c: widgets.Canvas, content: g.Rect, font: *font_mod.Font) void {
        const th = c.theme;
        const lh: i32 = @intCast(widgets.lineH(font));
        const asc: i32 = @intCast(font.ascentPx());
        if (self.merged.len < self.pins.len) self.merged = ga.merge(self.pins.slice(), self.clients.slice());
        const n_pin = self.merged.pinned;
        const n_run = self.merged.len - self.merged.pinned;
        self.layout = ga.layout(content, lh, n_pin, n_run);
        const l = &self.layout;
        const radius: i32 = @intCast(@max(th.radius_px, 6) - 4);

        // Top row: the launcher (left) and the trash (right).
        self.headButton(c, font, l.launcher, radius, self.hover == .launcher and self.drawer_ok, "All apps", if (self.drawer_ok) "Open the app drawer" else "App drawer not installed", null, self.drawer_ok);
        const tpx = self.trash_icons[@intFromBool(self.trash_full)];
        self.headButton(c, font, l.trash, radius, self.hover == .trash, "Trash", ga.trashText(self.trash_full), tpx, true);

        // Sections.
        tile(c, l.pinned, radius + 2);
        tile(c, l.running, radius + 2);
        heading(c, l.pinned, asc, "Pinned");
        heading(c, l.running, asc, "Running");
        if (n_pin == 0) emptyLine(c, l.pinned, asc, lh, ga.pinnedEmpty(&self.pins));
        if (n_run == 0) emptyLine(c, l.running, asc, lh, ga.runningEmpty(self.sock.len == 0, self.clients.len > 0));
        for (l.pinCells(), 0..) |cell, i| {
            if (l.pin_more > 0 and i + 1 == l.pin_shown) {
                moreCell(c, cell, asc, l.pin_more, radius);
                continue;
            }
            self.appCell(c, font, cell, i, self.hover == .pinned and self.hover.pinned == i, radius);
        }
        for (l.runCells(), 0..) |cell, i| {
            if (l.run_more > 0 and i + 1 == l.run_shown) {
                moreCell(c, cell, asc, l.run_more, radius);
                continue;
            }
            self.appCell(c, font, cell, self.merged.pinned + i, self.hover == .running and self.hover.running == i, radius);
        }
    }

    fn headButton(self: *AppsTab, c: widgets.Canvas, font: *font_mod.Font, r: g.Rect, radius: i32, hot: bool, title: []const u8, sub: []const u8, icon: ?[]u32, enabled: bool) void {
        const th = c.theme;
        gv.fillRounded(c, r, radius + 2, if (hot) 0x1CFFFFFF else 0x0FFFFFFF, 0x1CFFFFFF);
        const asc: i32 = @intCast(font.ascentPx());
        const lh: i32 = @intCast(widgets.lineH(font));
        const ix = r.x + 12;
        const iy = r.y + @divTrunc(r.h - HEAD_ICON, 2);
        if (icon) |px| {
            c.blitArgb(ix, iy, @intCast(HEAD_ICON), @intCast(HEAD_ICON), px, 0);
        } else {
            // The launcher wears the distro logo, like the dock's.
            const col = if (enabled) th.border_color else widgets.dim(th.text_color, 0x60) | 0xFF000000;
            _ = widgets.drawIconFit(c, toRect(r), self.glyph, ix, iy, HEAD_ICON, HEAD_ICON, 3, col, false);
        }
        const tx = ix + HEAD_ICON + 12;
        const top = r.y + @divTrunc(r.h - (2 * lh + 2), 2);
        var fit: [96]u8 = undefined;
        const w = r.x + r.w - 12 - tx;
        _ = c.drawTextA(tx, top + asc, widgets.fitText(c, title, w, &fit), if (enabled) th.text_color else widgets.dim(th.text_color, 0x90));
        _ = c.drawTextA(tx, top + lh + 2 + asc, widgets.fitText(c, sub, w, &fit), widgets.dim(th.text_color, 0x99));
    }

    fn appCell(self: *AppsTab, c: widgets.Canvas, font: *font_mod.Font, cell: g.Rect, idx: usize, hot: bool, radius: i32) void {
        const th = c.theme;
        const e = self.merged.items[idx];
        const asc: i32 = @intCast(font.ascentPx());
        if (hot) gv.fillRounded(c, cell, radius, 0x16FFFFFF, 0);
        var lb: [64]u8 = undefined;
        var label: []const u8 = "";
        var px: ?[]u32 = null;
        if (e.pin) |pi| {
            label = ga.pinLabel(&self.pins.pins[pi], &lb);
            px = self.pin_icons[pi];
        } else if (e.client) |ci| {
            const cl = &self.clients.items[ci];
            label = ga.shortName(cl.appid_raw.slice());
            px = self.runIcon(cl.appid.slice());
        }
        const ix = cell.x + @divTrunc(cell.w - ga.ICON, 2);
        const iy = cell.y + 8;
        if (px) |p| {
            c.blitArgb(ix, iy, ICON_PX, ICON_PX, p, 0);
        } else {
            // No icon: the app's first letter on an accent tile.
            gv.fillRounded(c, .{ .x = ix + 4, .y = iy + 4, .w = ga.ICON - 8, .h = ga.ICON - 8 }, 10, (th.border_color & 0x00FFFFFF) | 0x40000000, 0);
            var ch: [4]u8 = .{ '?', 0, 0, 0 };
            var chl: usize = 1;
            if (label.len > 0) {
                chl = std.unicode.utf8ByteSequenceLength(label[0]) catch 1;
                chl = @min(chl, label.len);
                @memcpy(ch[0..chl], label[0..chl]);
                if (chl == 1) ch[0] = std.ascii.toUpper(ch[0]);
            }
            const tw: i32 = @intCast(c.textWidth(ch[0..chl]));
            _ = widgets.drawScaledText(c, ix + @divTrunc(ga.ICON - 2 * tw, 2), iy + @divTrunc(ga.ICON, 2) + asc - 2, ch[0..chl], 2, th.text_color);
        }
        var fit: [80]u8 = undefined;
        const t = widgets.fitText(c, label, cell.w - 8, &fit);
        const tw: i32 = @intCast(c.textWidth(t));
        const ty = iy + ga.ICON + 6 + asc;
        _ = c.drawTextA(cell.x + @divTrunc(cell.w - tw, 2), ty, t, if (e.running()) th.text_color else widgets.dim(th.text_color, 0xB8));
        // The running marker under the label, like the dock's dot: wider
        // for the focused app, one dot per window up to three.
        if (e.running()) {
            const by = cell.y + cell.h - 5;
            if (e.focused) {
                gv.fillRounded(c, .{ .x = cell.x + @divTrunc(cell.w, 2) - 8, .y = by, .w = 16, .h = 4 }, 2, th.border_color | 0xFF000000, 0);
            } else {
                const dots: i32 = @intCast(@min(e.count, 3));
                const span = dots * 4 + (dots - 1) * 3;
                var k: i32 = 0;
                while (k < dots) : (k += 1) {
                    gv.fillRounded(c, .{ .x = cell.x + @divTrunc(cell.w - span, 2) + k * 7, .y = by, .w = 4, .h = 4 }, 2, widgets.dim(th.border_color, 0xD0), 0);
                }
            }
        }
    }
};

fn toRect(r: g.Rect) widgets.Rect {
    return .{ .x = r.x, .y = r.y, .w = @intCast(@max(r.w, 0)), .h = @intCast(@max(r.h, 0)) };
}

fn tile(c: widgets.Canvas, r: g.Rect, radius: i32) void {
    if (r.w <= 0 or r.h <= 0) return;
    gv.fillRounded(c, r, radius, 0x0FFFFFFF, 0x1CFFFFFF);
}

fn heading(c: widgets.Canvas, r: g.Rect, asc: i32, text: []const u8) void {
    _ = c.drawTextA(r.x + ga.PAD + 2, r.y + ga.PAD + asc, text, widgets.dim(c.theme.text_color, 0x99));
}

fn emptyLine(c: widgets.Canvas, r: g.Rect, asc: i32, lh: i32, text: []const u8) void {
    var fit: [160]u8 = undefined;
    const t = widgets.fitText(c, text, r.w - 2 * ga.PAD, &fit);
    const tw: i32 = @intCast(c.textWidth(t));
    const top = r.y + ga.PAD + lh + ga.TITLE_GAP;
    const h = r.y + r.h - ga.PAD - top;
    _ = c.drawTextA(r.x + @divTrunc(r.w - tw, 2), top + @divTrunc(h - lh, 2) + asc, t, widgets.dim(c.theme.text_color, 0x88));
}

fn moreCell(c: widgets.Canvas, cell: g.Rect, asc: i32, more: usize, radius: i32) void {
    gv.fillRounded(c, .{ .x = cell.x + 18, .y = cell.y + 8, .w = cell.w - 36, .h = ga.ICON }, radius, 0x14FFFFFF, 0);
    var b: [12]u8 = undefined;
    const t = std.fmt.bufPrint(&b, "+{d}", .{more}) catch "";
    const tw: i32 = @intCast(c.textWidth(t));
    _ = c.drawTextA(cell.x + @divTrunc(cell.w - tw, 2), cell.y + 8 + @divTrunc(ga.ICON, 2) + @divTrunc(asc, 2), t, c.theme.text_color);
}
