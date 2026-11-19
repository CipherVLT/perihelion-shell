//! Glance (Super+I): the dashboard surface. A centred glass panel over a
//! soft dim, on the `overlay` layer above your windows, with a tab row
//! (Overview · Media · Weather · settings) and, on the Overview, the
//! desktop cards' own painters: Clock, Weather, User, Calendar, Media and
//! System. The rules (layout, hit-testing, animation) live in glance.zig;
//! this file owns the Wayland surface, the card instances and the pixels.
//!
//! Lightness:
//!   - Closed means nothing: no surface, no buffers, no card instances, no
//!     timers, no fetch children. Everything is created on open and freed
//!     when the close animation ends.
//!   - Open, the panel is rendered into its own buffer only when something
//!     on it changed (a card's shown value, the tab, a hovered tab); each
//!     frame then just dims and blits it. No looping animation: after the
//!     220 ms open the loop sleeps until a card's own cadence (clock minute,
//!     media second while playing) or input wakes it.
//!   - The cards are separate instances from the desktop's, ticked only
//!     while Glance is open; weather comes from the cache file the bar and
//!     the desktop card share, so opening Glance doesn't refetch it.

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const font_mod = @import("font");
const logging = @import("logging");
const widgets = @import("widgets");
const glass = @import("glass.zig");
const g = @import("glance.zig");

const BTN_LEFT: u32 = 0x110;
const SETTINGS_CMD: [:0]const u8 = "exec perihelion-settings";
const GEAR = "\u{f013}";

const libc_clock = struct {
    extern "c" fn clock_gettime(clockid: c_int, tp: *posix.timespec) c_int;
};

fn nowMs() i64 {
    var tp: posix.timespec = undefined;
    if (libc_clock.clock_gettime(1, &tp) != 0) return 0; // CLOCK_MONOTONIC
    return @as(i64, @intCast(tp.sec)) * 1000 + @divTrunc(@as(i64, @intCast(tp.nsec)), 1_000_000);
}

/// Card instances in glance.Card order.
const CARD_IDS = [g.CARD_COUNT]widgets.WidgetId{ .clock, .weather, .user, .calendar, .media, .system };

pub const Cards = [g.CARD_COUNT]widgets.Widget;

/// main.zig configures the fresh card instances from shell.json (weather
/// place and units, calendar holidays and reminders, temperature sensors),
/// the same way it configures the desktop's.
pub const SetupFn = *const fn (cards: *Cards) void;

/// What the weather card showed last, so a fetch schedule tick that changed
/// nothing doesn't repaint the panel.
const WeatherSeen = struct {
    fetched_s: i64 = -1,
    available: bool = false,
    in_flight: bool = false,
    status: u8 = 255,
};

pub const Glance = struct {
    // Wiring, borrowed from main for the process lifetime.
    gpa: std.mem.Allocator,
    font: *font_mod.Font,
    theme: *const widgets.Theme,
    compositor: *wl.Compositor,
    shm: *wl.Shm,
    layer_shell: *zwlr.LayerShellV1,
    /// The desktop's blurred wallpaper (glass.zig): the panel's frost.
    backdrop: *const glass.Backdrop,
    setup: SetupFn,
    start_tab: g.Tab = .overview,

    surface: ?*wl.Surface = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    width: u32 = 0,
    height: u32 = 0,

    anim: g.Anim = .{},
    tab: g.Tab = .overview,
    layout: g.Layout = .{},
    cards: ?*Cards = null,
    next_tick: [g.CARD_COUNT]i64 = @as([g.CARD_COUNT]i64, @splat(0)),
    weather_seen: WeatherSeen = .{},
    panel_px: ?[]u32 = null,
    /// The panel's glass alone (the frosted wallpaper is per-pixel float
    /// work): rendered on open, resize and palette change, then copied
    /// under every content repaint instead of being recomputed.
    panel_bg: ?[]u32 = null,
    bg_valid: bool = false,
    panel_dirty: bool = true,
    frame_dirty: bool = false,
    full_damage: bool = true,
    hover: g.Hit = .backdrop,
    press: ?g.Hit = null,
    px: i32 = 0,
    py: i32 = 0,

    pub fn deinit(self: *Glance) void {
        self.teardown();
    }

    // --- commands -------------------------------------------------------------

    /// One control-socket command. False when the surface can't be made.
    pub fn command(self: *Glance, cmd: g.Command) bool {
        const now = nowMs();
        switch (cmd.verb) {
            .close => return self.apply(self.anim.close(now)),
            .open => {
                if (self.anim.phase == .closed) self.tab = cmd.tab orelse self.start_tab else if (cmd.tab) |t| self.setTab(t);
                return self.apply(self.anim.open(now));
            },
            .toggle => {
                // Already up on another page: show that page instead of closing.
                if (self.anim.takesInput()) {
                    if (cmd.tab) |t| {
                        if (t != self.tab) {
                            self.setTab(t);
                            return true;
                        }
                    }
                }
                if (self.anim.phase == .closed) self.tab = cmd.tab orelse self.start_tab;
                return self.apply(self.anim.toggle(now));
            },
        }
    }

    fn apply(self: *Glance, action: g.Action) bool {
        switch (action) {
            .none => return true,
            .map => return self.mapNow(),
            .teardown => {
                self.teardown();
                return true;
            },
        }
    }

    /// The palette (or wallpaper) changed: repaint the glass and the cards
    /// with it if Glance is up.
    pub fn themeChanged(self: *Glance) void {
        self.bg_valid = false;
        self.panel_dirty = true;
    }

    pub fn takesKeys(self: *const Glance) bool {
        return self.surface != null and self.anim.takesInput();
    }

    fn setTab(self: *Glance, t: g.Tab) void {
        if (t == self.tab) return;
        self.tab = t;
        self.hover = g.hitTest(&self.layout, t, self.px, self.py);
        self.panel_dirty = true;
    }

    // --- surface lifecycle --------------------------------------------------

    fn mapNow(self: *Glance) bool {
        if (self.surface != null) return true;
        const cards = self.gpa.create(Cards) catch |err| {
            logging.err("glance: no memory for the cards: {}", .{err});
            self.anim.reset();
            return false;
        };
        for (CARD_IDS, 0..) |id, i| {
            cards[i] = switch (id) {
                .clock => .{ .clock = .{} },
                .weather => .{ .weather = .{} },
                .user => .{ .user = .{} },
                .calendar => .{ .calendar = .{} },
                .media => .{ .media = .{} },
                .system => .{ .system = .{} },
                else => unreachable,
            };
        }
        self.setup(cards);
        self.cards = cards;
        self.next_tick = @as([g.CARD_COUNT]i64, @splat(0)); // all due on the first tick
        self.weather_seen = .{};

        const surface = self.compositor.createSurface() catch |err| {
            logging.err("glance: createSurface failed: {}", .{err});
            self.teardown();
            return false;
        };
        // No output: the compositor puts it on the focused one.
        const ls = self.layer_shell.getLayerSurface(surface, null, .overlay, "perihelion-shell-glance") catch |err| {
            logging.err("glance: getLayerSurface failed: {}", .{err});
            surface.destroy();
            self.teardown();
            return false;
        };
        self.surface = surface;
        self.layer_surface = ls;
        ls.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
        // 0: stay clear of the bar's exclusive zone, so the bar is never dimmed.
        ls.setExclusiveZone(0);
        // Exclusive keyboard while open: Esc closes, nothing leaks to windows.
        ls.setKeyboardInteractivity(.exclusive);
        ls.setListener(*Glance, layerListener, self);
        surface.commit();
        logging.step("glance: opening on {s}", .{@tagName(self.tab)});
        return true;
    }

    /// Back to nothing: surface, buffers and cards all go.
    fn teardown(self: *Glance) void {
        if (self.layer_surface) |ls| ls.destroy();
        self.layer_surface = null;
        if (self.surface) |s| s.destroy();
        self.surface = null;
        if (self.cards) |cards| {
            for (cards) |*c| c.release();
            self.gpa.destroy(cards);
        }
        self.cards = null;
        if (self.panel_px) |p| self.gpa.free(p);
        self.panel_px = null;
        if (self.panel_bg) |p| self.gpa.free(p);
        self.panel_bg = null;
        self.bg_valid = false;
        self.width = 0;
        self.height = 0;
        self.anim.reset();
        self.hover = .backdrop;
        self.press = null;
        self.panel_dirty = true;
        self.frame_dirty = false;
    }

    fn layerListener(_: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, self: *Glance) void {
        switch (event) {
            .configure => |cfg| {
                if (self.layer_surface) |ls| ls.ackConfigure(cfg.serial);
                if (self.anim.phase == .mapping and self.anim.close_pending) {
                    _ = self.anim.mapped(nowMs());
                    self.teardown();
                    return;
                }
                const w = if (cfg.width > 0) cfg.width else self.width;
                const h = if (cfg.height > 0) cfg.height else self.height;
                if (w == 0 or h == 0) return;
                if (w != self.width or h != self.height or self.panel_px == null) {
                    self.width = w;
                    self.height = h;
                    if (!self.relayout()) {
                        self.teardown();
                        return;
                    }
                }
                _ = self.anim.mapped(nowMs());
                self.frame_dirty = true;
                self.full_damage = true;
                self.paintFrame();
            },
            .closed => {
                logging.step("glance: compositor closed the surface", .{});
                self.teardown();
            },
        }
    }

    /// Layout for the current output size, and a panel buffer to match.
    fn relayout(self: *Glance) bool {
        var sizes: [g.CARD_COUNT]g.Size = undefined;
        for (CARD_IDS, 0..) |id, i| {
            const s = widgets.cardSizeFor(id, self.font);
            sizes[i] = .{ .w = @intCast(s[0]), .h = @intCast(s[1]) };
        }
        var tab_w: [g.TAB_COUNT]i32 = undefined;
        for (0..g.TAB_COUNT) |i| tab_w[i] = @intCast(self.textWidth(@as(g.Tab, @enumFromInt(i)).label()));
        self.layout = g.compute(@intCast(self.width), @intCast(self.height), sizes, tab_w);
        if (self.panel_px) |p| self.gpa.free(p);
        self.panel_px = null;
        if (self.panel_bg) |p| self.gpa.free(p);
        self.panel_bg = null;
        const area: usize = @as(usize, @intCast(self.layout.panel.w)) * @as(usize, @intCast(self.layout.panel.h));
        self.panel_px = self.gpa.alloc(u32, area) catch |err| {
            logging.err("glance: no memory for the panel: {}", .{err});
            return false;
        };
        self.panel_bg = self.gpa.alloc(u32, area) catch |err| {
            logging.err("glance: no memory for the panel: {}", .{err});
            return false;
        };
        self.bg_valid = false;
        self.panel_dirty = true;
        return true;
    }

    // --- poll loop hooks ------------------------------------------------------

    /// The next instant the host loop must wake Glance: an animation frame,
    /// or the earliest card cadence while open. Null while closed.
    pub fn deadline(self: *const Glance) ?i64 {
        if (self.surface == null) return null;
        if (self.anim.animating()) return nowMs() + g.FRAME_MS;
        if (self.cards == null or !self.anim.takesInput()) return null;
        var d: i64 = std.math.maxInt(i64);
        for (self.next_tick) |n| d = @min(d, n);
        return d;
    }

    /// The cards' fetch pipes for the host's poll set (none while closed).
    pub fn pollFds(self: *const Glance, out: []posix.fd_t) usize {
        const cards = self.cards orelse return 0;
        var n: usize = 0;
        for (cards) |*c| {
            const fd = c.pollFd();
            if (fd < 0 or n == out.len) continue;
            out[n] = fd;
            n += 1;
        }
        return n;
    }

    /// A poll fd was readable: let the cards read their fetches.
    pub fn onPipes(self: *Glance) void {
        const cards = self.cards orelse return;
        for (cards) |*c| {
            if (c.onPipe()) self.panel_dirty = true;
        }
    }

    /// Every loop pass: animation, due card cadences, then at most one frame.
    pub fn tick(self: *Glance, now: i64) void {
        if (self.surface == null) return;
        if (self.anim.animating()) {
            if (self.anim.step(now) == .teardown) {
                self.teardown();
                return;
            }
            self.frame_dirty = true;
        }
        if (self.cards) |cards| {
            if (self.anim.takesInput()) {
                for (cards, 0..) |*c, i| {
                    if (now < self.next_tick[i]) continue;
                    if (c.* == .weather) {
                        // The fetch schedule only: the condition animation
                        // stays still inside Glance (no looping repaint).
                        if (self.pumpWeather(&c.weather, now)) self.panel_dirty = true;
                        self.next_tick[i] = now + 1000;
                    } else {
                        if (c.tick()) self.panel_dirty = true;
                        self.next_tick[i] = now + c.intervalMs();
                    }
                }
            }
        }
        if (self.panel_dirty) self.frame_dirty = true;
        if (self.frame_dirty) self.paintFrame();
    }

    fn pumpWeather(self: *Glance, w: *widgets.WeatherWidget, now: i64) bool {
        w.pump(now);
        const seen = WeatherSeen{
            .fetched_s = w.svc.data_fetched_s,
            .available = w.svc.data.available,
            .in_flight = w.svc.in_flight != null,
            .status = @intFromEnum(w.svc.status()),
        };
        const changed = !std.meta.eql(seen, self.weather_seen);
        self.weather_seen = seen;
        return changed;
    }

    // --- input ----------------------------------------------------------------

    pub fn motion(self: *Glance, x: i32, y: i32) void {
        self.px = x;
        self.py = y;
        if (!self.anim.takesInput()) return;
        const h = g.hitTest(&self.layout, self.tab, x, y);
        if (h.eql(self.hover)) return;
        // Only the tab row reacts to hover; cards keep their desktop look.
        if (isChrome(h) or isChrome(self.hover)) self.panel_dirty = true;
        self.hover = h;
    }

    pub fn leave(self: *Glance) void {
        if (isChrome(self.hover)) self.panel_dirty = true;
        self.hover = .backdrop;
    }

    fn isChrome(h: g.Hit) bool {
        return h == .tab or h == .settings;
    }

    /// Press and release on the same thing activates it; a click outside
    /// the panel closes Glance.
    pub fn button(self: *Glance, btn: u32, pressed: bool) void {
        if (btn != BTN_LEFT or !self.anim.takesInput()) return;
        const h = g.hitTest(&self.layout, self.tab, self.px, self.py);
        if (pressed) {
            self.press = h;
            return;
        }
        const pr = self.press orelse return;
        self.press = null;
        if (!pr.eql(h)) return;
        switch (h) {
            .backdrop => _ = self.apply(self.anim.close(nowMs())),
            .panel => {},
            .tab => |t| self.setTab(t),
            .settings => {
                widgets.spawnDetached(SETTINGS_CMD);
                _ = self.apply(self.anim.close(nowMs()));
            },
            .card => |c| self.clickCard(c),
        }
    }

    fn clickCard(self: *Glance, c: g.Card) void {
        const cards = self.cards orelse return;
        const i = @intFromEnum(c);
        const r = self.cardRect(c);
        const lx = self.px - self.layout.panel.x;
        const ly = self.py - self.layout.panel.y;
        const on_ctl = c == .media and cards[i].media.hitsControl(r, self.font, 1.0, lx, ly);
        switch (g.cardClick(c, on_ctl)) {
            .none => {},
            .switch_tab => |t| self.setTab(t),
            .forward => {
                cards[i].click(self.font, 1.0, r, lx, ly);
                self.panel_dirty = true;
            },
        }
    }

    /// Keys while Glance holds the keyboard. Always swallowed.
    pub fn keyPress(self: *Glance, keycode: u32) bool {
        if (!self.takesKeys()) return false;
        switch (g.keyAction(keycode)) {
            .close => _ = self.apply(self.anim.close(nowMs())),
            .none => {},
        }
        return true;
    }

    // --- painting ---------------------------------------------------------------

    fn cardRect(self: *const Glance, c: g.Card) widgets.Rect {
        return toRect(self.layout.card(c));
    }

    fn textWidth(self: *Glance, text: []const u8) i64 {
        var total: i64 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const cp = std.unicode.utf8Decode(text[i..@min(i + len, text.len)]) catch '?';
            i += len;
            total += (self.font.glyph(cp) catch continue).advance_x;
        }
        return total;
    }

    /// Re-renders the panel buffer: glass, tab row, then the page.
    fn renderPanel(self: *Glance) void {
        const px = self.panel_px orelse return;
        const bg = self.panel_bg orelse return;
        const l = &self.layout;
        const pw: u32 = @intCast(l.panel.w);
        const ph: u32 = @intCast(l.panel.h);
        const th = self.theme;
        if (!self.bg_valid) {
            // Frosted glass from the blurred wallpaper, like the desktop
            // cards; without a wallpaper image, a nearly opaque dark frost
            // that reads the same over any window.
            const frost = self.backdrop.ready();
            glass.paintCard(bg, pw, ph, l.panel.x, l.panel.y, self.width, self.height, self.backdrop, .{
                .tint = th.bg_color,
                .tint_pct = if (frost) @max(th.card_alpha, 62) else 90,
                .radius = th.radius_px + 6,
            });
            self.bg_valid = true;
        }
        @memcpy(px, bg);
        const c = widgets.Canvas{ .pixels = px.ptr, .width = pw, .height = ph, .font = self.font, .theme = th };

        // Tab row: the current page is an accent pill, the rest plain text
        // that lights up under the pointer.
        const asc: i64 = self.font.ascentPx();
        const desc: i64 = self.font.descentPx();
        for (0..g.TAB_COUNT) |i| {
            const t: g.Tab = @enumFromInt(i);
            const r = l.tabs[i];
            const active = t == self.tab;
            const hovered = self.hover == .tab and self.hover.tab == t;
            const fill: u32 = if (active) (th.border_color & 0x00FFFFFF) | 0xE6000000 else if (hovered) 0x1AFFFFFF else 0;
            if (fill != 0) fillRounded(c, r, @divTrunc(r.h, 2), fill, 0);
            const label = t.label();
            const tw = self.textWidth(label);
            const color: u32 = if (active) (th.bg_color | 0xFF000000) else if (hovered) th.text_color else widgets.dim(th.text_color, 0xC0);
            _ = c.drawTextA(r.x + @divTrunc(r.w - tw, 2), r.y + @divTrunc(r.h + asc - desc, 2), label, color);
        }
        {
            const r = l.settings;
            const hovered = self.hover == .settings;
            if (hovered) fillRounded(c, r, @divTrunc(r.h, 2), 0x1AFFFFFF, 0);
            const gw = self.textWidth(GEAR);
            _ = c.drawTextA(r.x + @divTrunc(r.w - @as(i32, @intCast(gw)), 2), r.y + @divTrunc(r.h + asc - desc, 2), GEAR, if (hovered) th.text_color else widgets.dim(th.text_color, 0xC0));
        }

        switch (self.tab) {
            .overview => self.renderCards(c),
            .media => self.renderPlaceholder(c, "Media", "Cover art, seeking, players and volume arrive in the next update."),
            .weather => self.renderPlaceholder(c, "Weather", "Details, the 7-day outlook and an hourly strip arrive in a later update."),
        }
        self.panel_dirty = false;
    }

    fn renderCards(self: *Glance, c: widgets.Canvas) void {
        const cards = self.cards orelse return;
        const radius: i32 = @intCast(@max(self.theme.radius_px, 6) - 4);
        for (cards, 0..) |*card, i| {
            const r = self.layout.cards[i];
            // A soft inner tile: lighter glass on the panel's glass, with a
            // hairline edge (no shadow).
            fillRounded(c, r, radius, 0x0FFFFFFF, 0x1CFFFFFF);
            card.paint(c, toRect(r));
        }
    }

    fn renderPlaceholder(self: *Glance, c: widgets.Canvas, title: []const u8, line: []const u8) void {
        const r = self.layout.content;
        const lh: i64 = widgets.lineH(self.font);
        const cy: i64 = r.y + @divTrunc(r.h, 2);
        const heading = "Coming soon";
        // Three centred lines: the page name in the accent, the heading,
        // and a dimmer sentence under it.
        _ = c.drawTextA(r.x + @divTrunc(r.w - self.textWidth(title), 2), cy - lh, title, self.theme.border_color);
        _ = c.drawTextA(r.x + @divTrunc(r.w - self.textWidth(heading), 2), cy + 8, heading, self.theme.text_color);
        _ = c.drawTextA(r.x + @divTrunc(r.w - self.textWidth(line), 2), cy + lh + 22, line, widgets.dim(self.theme.text_color, 0x99));
    }

    /// One full-output frame: the dim, then the panel at the animation's
    /// scale and opacity.
    fn paintFrame(self: *Glance) void {
        const surface = self.surface orelse return;
        if (self.width == 0 or self.height == 0) return;
        if (self.panel_dirty) self.renderPanel();
        const panel = self.panel_px orelse return;
        const w = self.width;
        const h = self.height;
        const stride = w * 4;
        const size: usize = @as(usize, stride) * h;
        const fd = posix.memfd_create("perihelion-glance-frame", 0) catch |err| {
            logging.err("glance: frame memfd: {}", .{err});
            return;
        };
        defer _ = posix.system.close(fd);
        switch (posix.errno(posix.system.ftruncate(fd, @intCast(size)))) {
            .SUCCESS => {},
            else => return,
        }
        const data = posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch |err| {
            logging.err("glance: frame mmap: {}", .{err});
            return;
        };
        defer posix.munmap(data);
        const pixels: []u32 = @as([*]u32, @ptrCast(@alignCast(data.ptr)))[0 .. size / 4];

        const p = self.anim.progress;
        const dim_a: u32 = g.dimAlpha(p);
        if (dim_a > 0) @memset(pixels, dim_a << 24); // premultiplied black
        const l = self.layout.panel;
        composite(pixels, w, h, panel, @intCast(l.w), @intCast(l.h), l.x, l.y, p);

        const pool = self.shm.createPool(fd, @intCast(size)) catch |err| {
            logging.err("glance: createPool: {}", .{err});
            return;
        };
        defer pool.destroy();
        const buffer = pool.createBuffer(0, @intCast(w), @intCast(h), @intCast(stride), .argb8888) catch |err| {
            logging.err("glance: createBuffer: {}", .{err});
            return;
        };
        defer buffer.destroy();
        surface.attach(buffer, 0, 0);
        // The dim only changes while animating (and on the first frame):
        // otherwise just the panel changed.
        if (self.full_damage or self.anim.animating()) {
            surface.damageBuffer(0, 0, @intCast(w), @intCast(h));
        } else {
            surface.damageBuffer(l.x, l.y, l.w, l.h);
        }
        surface.commit();
        self.frame_dirty = false;
        self.full_damage = false;
    }
};

fn toRect(r: g.Rect) widgets.Rect {
    return .{ .x = r.x, .y = r.y, .w = @intCast(@max(r.w, 0)), .h = @intCast(@max(r.h, 0)) };
}

/// Signed distance from (fx, fy) to a w x h rounded rect with radius r
/// (negative inside).
fn roundedDist(fx: f32, fy: f32, w: f32, h: f32, r: f32) f32 {
    const qx = @abs(fx - w / 2.0) - (w / 2.0 - r);
    const qy = @abs(fy - h / 2.0) - (h / 2.0 - r);
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0) - r;
}

fn scaleAlpha(color: u32, k: f32) u32 {
    const a: f32 = @floatFromInt((color >> 24) & 0xFF);
    const na: u32 = @intFromFloat(@round(std.math.clamp(a * k, 0.0, 255.0)));
    return (na << 24) | (color & 0x00FFFFFF);
}

/// Antialiased rounded rect: `fill` inside, a ~1 px `border` band along the
/// edge (0 = none). Straight-alpha colours, blended over the canvas.
fn fillRounded(c: widgets.Canvas, r: g.Rect, radius: i32, fill: u32, border: u32) void {
    const w: f32 = @floatFromInt(r.w);
    const h: f32 = @floatFromInt(r.h);
    const rad: f32 = @min(@as(f32, @floatFromInt(@max(radius, 0))), @min(w, h) / 2.0);
    const x0 = @max(r.x, 0);
    const y0 = @max(r.y, 0);
    const x1 = @min(r.x + r.w, @as(i32, @intCast(c.width)));
    const y1 = @min(r.y + r.h, @as(i32, @intCast(c.height)));
    var y = y0;
    while (y < y1) : (y += 1) {
        const fy = @as(f32, @floatFromInt(y - r.y)) + 0.5;
        const row = c.pixels[@as(usize, @intCast(y)) * c.width ..][0..c.width];
        var x = x0;
        while (x < x1) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x - r.x)) + 0.5;
            const d = roundedDist(fx, fy, w, h, rad);
            const cov = std.math.clamp(0.5 - d, 0.0, 1.0);
            if (cov <= 0.0) continue;
            const idx: usize = @intCast(x);
            const in_border = border != 0 and d > -1.5;
            const col = if (in_border) border else fill;
            if ((col >> 24) == 0) continue;
            row[idx] = widgets.Canvas.blendOver(row[idx], scaleAlpha(col, cov));
        }
    }
}

/// Premultiplied src (scaled by k in 0..256) over premultiplied dst.
inline fn over(dst: u32, src: u32, k: u32) u32 {
    const sa = ((src >> 24) & 0xFF) * k >> 8;
    if (sa == 0) return dst;
    const inv = 255 - sa;
    var out: u32 = 0;
    inline for (.{ 0, 8, 16 }) |sh| {
        const s = ((src >> sh) & 0xFF) * k >> 8;
        const d = (dst >> sh) & 0xFF;
        out |= @as(u32, @min(s + d * inv / 255, 255)) << sh;
    }
    const da = (dst >> 24) & 0xFF;
    return out | (@as(u32, @min(sa + da * inv / 255, 255)) << 24);
}

/// Blits the panel (premultiplied) centred on its rect at the animation's
/// scale, faded by p. Bilinear while scaling, a straight copy-blend at rest.
fn composite(dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32, x0: i32, y0: i32, p: f64) void {
    const k: u32 = @intFromFloat(@round(std.math.clamp(p, 0.0, 1.0) * 256.0));
    if (k == 0) return;
    const s = g.scaleAt(p);
    const fsw: f64 = @floatFromInt(sw);
    const fsh: f64 = @floatFromInt(sh);
    const cx = @as(f64, @floatFromInt(x0)) + fsw / 2.0;
    const cy = @as(f64, @floatFromInt(y0)) + fsh / 2.0;
    if (s >= 0.9999) {
        var y: u32 = 0;
        while (y < sh) : (y += 1) {
            const dy = @as(i64, y0) + y;
            if (dy < 0 or dy >= dh) continue;
            var x: u32 = 0;
            while (x < sw) : (x += 1) {
                const dx = @as(i64, x0) + x;
                if (dx < 0 or dx >= dw) continue;
                const di: usize = @intCast(dy * dw + dx);
                dst[di] = over(dst[di], src[y * sw + x], k);
            }
        }
        return;
    }
    const left: i64 = @intFromFloat(@floor(cx - fsw * s / 2.0));
    const right: i64 = @intFromFloat(@ceil(cx + fsw * s / 2.0));
    const top: i64 = @intFromFloat(@floor(cy - fsh * s / 2.0));
    const bottom: i64 = @intFromFloat(@ceil(cy + fsh * s / 2.0));
    var dy: i64 = @max(top, 0);
    while (dy < @min(bottom, @as(i64, dh))) : (dy += 1) {
        const sy = (@as(f64, @floatFromInt(dy)) + 0.5 - cy) / s + fsh / 2.0 - 0.5;
        var dx: i64 = @max(left, 0);
        while (dx < @min(right, @as(i64, dw))) : (dx += 1) {
            const sx = (@as(f64, @floatFromInt(dx)) + 0.5 - cx) / s + fsw / 2.0 - 0.5;
            const px = bilinear(src, sw, sh, sx, sy);
            if (px == 0) continue;
            const di: usize = @intCast(dy * @as(i64, dw) + dx);
            dst[di] = over(dst[di], px, k);
        }
    }
}

fn texel(src: []const u32, sw: u32, sh: u32, x: i64, y: i64) u32 {
    if (x < 0 or y < 0 or x >= sw or y >= sh) return 0;
    return src[@intCast(y * @as(i64, sw) + x)];
}

/// Bilinear sample of a premultiplied image (transparent outside).
fn bilinear(src: []const u32, sw: u32, sh: u32, sx: f64, sy: f64) u32 {
    const fx = @floor(sx);
    const fy = @floor(sy);
    const ix: i64 = @intFromFloat(fx);
    const iy: i64 = @intFromFloat(fy);
    const ax: u32 = @intFromFloat((sx - fx) * 256.0);
    const ay: u32 = @intFromFloat((sy - fy) * 256.0);
    const p00 = texel(src, sw, sh, ix, iy);
    const p10 = texel(src, sw, sh, ix + 1, iy);
    const p01 = texel(src, sw, sh, ix, iy + 1);
    const p11 = texel(src, sw, sh, ix + 1, iy + 1);
    var out: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |shf| {
        const a = (p00 >> shf) & 0xFF;
        const b = (p10 >> shf) & 0xFF;
        const cc = (p01 >> shf) & 0xFF;
        const d = (p11 >> shf) & 0xFF;
        const top = a * (256 - ax) + b * ax;
        const bot = cc * (256 - ax) + d * ax;
        const v = (top * (256 - ay) + bot * ay) >> 16;
        out |= @as(u32, @min(v, 255)) << shf;
    }
    return out;
}
