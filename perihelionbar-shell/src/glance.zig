//! Glance (Super+I): the dashboard's pure logic. Command parsing, the panel
//! layout, hit-testing and the open/close state machine live here, with no
//! Wayland and no drawing, so every rule is unit-tested on plain numbers
//! (`zig build test-glance`). glance_view.zig draws it; main.zig wires the
//! control socket, the pointer and the keyboard to it.
//!
//! Coordinates: `Layout.panel` is in surface (output-local) pixels; every
//! other rect is panel-local, because the panel is painted into its own
//! buffer and only blitted onto the full-output surface.

const std = @import("std");

pub const Tab = enum {
    overview,
    media,
    weather,

    pub fn parse(s: []const u8) ?Tab {
        inline for (@typeInfo(Tab).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    pub fn label(self: Tab) []const u8 {
        return switch (self) {
            .overview => "Overview",
            .media => "Media",
            .weather => "Weather",
        };
    }
};

pub const TAB_COUNT = @typeInfo(Tab).@"enum".fields.len;

pub const Verb = enum {
    toggle,
    open,
    close,

    pub fn parse(s: []const u8) ?Verb {
        inline for (@typeInfo(Verb).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// `perihelion-shell glance [toggle|open|close] [overview|media|weather]`.
/// The tab picks the page an open shows; without one Glance opens on
/// shell.json's glance_start_tab.
pub const Command = struct {
    verb: Verb = .toggle,
    tab: ?Tab = null,
};

pub const ParseError = error{ UnknownVerb, UnknownTab, TooManyArgs };

/// Arguments after the word "glance" (CLI argv or the socket line).
pub fn parseArgs(args: []const []const u8) ParseError!Command {
    var cmd = Command{};
    if (args.len == 0) return cmd;
    cmd.verb = Verb.parse(args[0]) orelse return error.UnknownVerb;
    if (args.len == 1) return cmd;
    // close has nothing to pick a page for.
    if (cmd.verb == .close) return error.TooManyArgs;
    cmd.tab = Tab.parse(args[1]) orelse return error.UnknownTab;
    if (args.len > 2) return error.TooManyArgs;
    return cmd;
}

pub const MAX_ARGS = 4;

/// Splits one control-socket request ("glance open media\n") into its
/// words. Returns null when the line isn't a glance request at all.
pub fn parseLine(line: []const u8) ?ParseError!Command {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const head = it.next() orelse return null;
    if (!std.mem.eql(u8, head, "glance")) return null;
    var words: [MAX_ARGS][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |w| {
        if (n == words.len) return error.TooManyArgs;
        words[n] = w;
        n += 1;
    }
    return parseArgs(words[0..n]);
}

/// The request line the CLI sends for `cmd` (always explicit: verb and,
/// when given, the tab), so the daemon never has to guess.
pub fn formatRequest(buf: []u8, cmd: Command) ![]const u8 {
    if (cmd.tab) |t| return std.fmt.bufPrint(buf, "glance {s} {s}\n", .{ @tagName(cmd.verb), @tagName(t) });
    return std.fmt.bufPrint(buf, "glance {s}\n", .{@tagName(cmd.verb)});
}

// --- geometry ---------------------------------------------------------------

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
};

pub const Size = struct { w: i32, h: i32 };

/// The Overview tab's cards, in paint order.
pub const Card = enum { clock, weather, user, calendar, media, system };
pub const CARD_COUNT = @typeInfo(Card).@"enum".fields.len;

pub const PAD: i32 = 20; // panel edge -> tab row and cards
pub const GAP: i32 = 14; // between cards
pub const TAB_H: i32 = 34;
pub const TAB_PAD_X: i32 = 16; // label inset inside a tab pill
pub const TAB_GAP: i32 = 6;
pub const TAB_ROW_GAP: i32 = 16; // tab row -> content
/// Smallest content area, so the placeholder tabs never collapse when the
/// cards are tiny (a small font).
pub const MIN_CONTENT_W: i32 = 520;
pub const MIN_CONTENT_H: i32 = 260;

pub const Layout = struct {
    /// Surface coordinates.
    panel: Rect = .{},
    /// Panel-local from here on.
    tabs: [TAB_COUNT]Rect = [_]Rect{.{}} ** TAB_COUNT,
    settings: Rect = .{},
    content: Rect = .{},
    cards: [CARD_COUNT]Rect = [_]Rect{.{}} ** CARD_COUNT,

    pub fn card(self: *const Layout, c: Card) Rect {
        return self.cards[@intFromEnum(c)];
    }
};

/// Lays the Overview out from the cards' designed sizes (`sizes`, the
/// desktop cards' base sizes, so their painters always fit):
///   left   Clock over Weather
///   middle Calendar
///   right  User over Media
///   bottom System, across the full width (every System style spreads its
///          gauges over the card's width)
/// Cards widen to their column; the last card of each column grows to the
/// tallest column, so the three bottoms line up above the System strip.
/// The tab row runs along the top (label widths come from the font:
/// `tab_label_w`), the settings button sits at its right end, and the panel
/// is centred on the output (pinned to the top-left when the output is
/// smaller than the panel).
pub fn compute(out_w: i32, out_h: i32, sizes: [CARD_COUNT]Size, tab_label_w: [TAB_COUNT]i32) Layout {
    var l = Layout{};
    const s = struct {
        fn at(sz: [CARD_COUNT]Size, c: Card) Size {
            return sz[@intFromEnum(c)];
        }
    };
    const clock = s.at(sizes, .clock);
    const weather = s.at(sizes, .weather);
    const user = s.at(sizes, .user);
    const calendar = s.at(sizes, .calendar);
    const media = s.at(sizes, .media);
    const system = s.at(sizes, .system);

    const wl = @max(clock.w, weather.w);
    const wm = calendar.w;
    const wr = @max(user.w, media.w);
    const cols_h = @max(@max(clock.h + GAP + weather.h, calendar.h), user.h + GAP + media.h);
    const content_w = @max(@max(wl + GAP + wm + GAP + wr, system.w), MIN_CONTENT_W);
    const content_h = @max(cols_h + GAP + system.h, MIN_CONTENT_H);
    // Spare height from the minimum goes to the columns, not the strip.
    const top_h = content_h - GAP - system.h;

    const top = PAD + TAB_H + TAB_ROW_GAP;
    l.content = .{ .x = PAD, .y = top, .w = content_w, .h = content_h };

    // Spare width (a wide System card or the minimum) goes to the middle.
    const wm_fit = content_w - wl - wr - 2 * GAP;
    const xl = PAD;
    const xm = xl + wl + GAP;
    const xr = xm + wm_fit + GAP;
    l.cards[@intFromEnum(Card.clock)] = .{ .x = xl, .y = top, .w = wl, .h = clock.h };
    l.cards[@intFromEnum(Card.weather)] = .{ .x = xl, .y = top + clock.h + GAP, .w = wl, .h = top_h - clock.h - GAP };
    l.cards[@intFromEnum(Card.calendar)] = .{ .x = xm, .y = top, .w = wm_fit, .h = top_h };
    l.cards[@intFromEnum(Card.user)] = .{ .x = xr, .y = top, .w = wr, .h = user.h };
    l.cards[@intFromEnum(Card.media)] = .{ .x = xr, .y = top + user.h + GAP, .w = wr, .h = top_h - user.h - GAP };
    l.cards[@intFromEnum(Card.system)] = .{ .x = PAD, .y = top + top_h + GAP, .w = content_w, .h = system.h };

    var tx: i32 = PAD;
    for (0..TAB_COUNT) |i| {
        const w = tab_label_w[i] + 2 * TAB_PAD_X;
        l.tabs[i] = .{ .x = tx, .y = PAD, .w = w, .h = TAB_H };
        tx += w + TAB_GAP;
    }
    const pw = content_w + 2 * PAD;
    const ph = top + content_h + PAD;
    l.settings = .{ .x = pw - PAD - TAB_H, .y = PAD, .w = TAB_H, .h = TAB_H };
    l.panel = .{
        .x = @max(@divTrunc(out_w - pw, 2), 0),
        .y = @max(@divTrunc(out_h - ph, 2), 0),
        .w = pw,
        .h = ph,
    };
    return l;
}

pub const Hit = union(enum) {
    /// Outside the panel: a click here closes Glance.
    backdrop,
    /// Inside the panel but on nothing that reacts.
    panel,
    tab: Tab,
    settings,
    card: Card,

    pub fn eql(a: Hit, b: Hit) bool {
        return switch (a) {
            .backdrop => b == .backdrop,
            .panel => b == .panel,
            .settings => b == .settings,
            .tab => |t| b == .tab and b.tab == t,
            .card => |c| b == .card and b.card == c,
        };
    }
};

/// What sits under surface point (x, y). Cards only exist on the Overview.
pub fn hitTest(l: *const Layout, tab: Tab, x: i32, y: i32) Hit {
    if (!l.panel.contains(x, y)) return .backdrop;
    const lx = x - l.panel.x;
    const ly = y - l.panel.y;
    for (l.tabs, 0..) |r, i| {
        if (r.contains(lx, ly)) return .{ .tab = @enumFromInt(i) };
    }
    if (l.settings.contains(lx, ly)) return .settings;
    if (tab == .overview) {
        for (l.cards, 0..) |r, i| {
            if (r.contains(lx, ly)) return .{ .card = @enumFromInt(i) };
        }
    }
    return .panel;
}

/// A click on a card: what Glance does with it. `.forward` hands it to the
/// card's own click handler (calendar month arrows, media controls).
pub const CardClick = union(enum) { none, forward, switch_tab: Tab };

/// Weather jumps to its tab; Calendar keeps its own clicks (month arrows);
/// Media keeps its control row and jumps to its tab anywhere else
/// (`on_media_control` says whether the point hit a control). Clock, User
/// and System don't react: the System card's GPU switch belongs to the
/// desktop card, which saves it.
pub fn cardClick(c: Card, on_media_control: bool) CardClick {
    return switch (c) {
        .weather => .{ .switch_tab = .weather },
        .calendar => .forward,
        .media => if (on_media_control) .forward else .{ .switch_tab = .media },
        .clock, .user, .system => .none,
    };
}

// --- keys -------------------------------------------------------------------

pub const KEY_ESC: u32 = 1; // evdev

pub const KeyAction = enum { none, close };

/// Esc closes. Everything else is swallowed while Glance has the keyboard
/// (tab switching by key arrives with the keyboard slice).
pub fn keyAction(keycode: u32) KeyAction {
    return if (keycode == KEY_ESC) .close else .none;
}

// --- open/close animation -----------------------------------------------------

pub const OPEN_MS: i64 = 220;
pub const CLOSE_MS: i64 = 160;
/// Poll tick while animating (same cadence as the overview).
pub const FRAME_MS: i64 = 16;
/// Dim behind the panel at full open (0..255).
pub const DIM_MAX: f64 = 110.0;
pub const SCALE_FROM: f64 = 0.96;

/// Cubic ease-out: fast start, soft landing.
pub fn easeOut(t: f64) f64 {
    const u = 1.0 - std.math.clamp(t, 0.0, 1.0);
    return 1.0 - u * u * u;
}

/// Panel scale at animation progress p (0 closed .. 1 open).
pub fn scaleAt(p: f64) f64 {
    return SCALE_FROM + (1.0 - SCALE_FROM) * std.math.clamp(p, 0.0, 1.0);
}

pub fn dimAlpha(p: f64) u8 {
    return @intFromFloat(@round(DIM_MAX * std.math.clamp(p, 0.0, 1.0)));
}

pub const Phase = enum {
    /// No surface, no buffers, no cards: nothing exists.
    closed,
    /// Surface created, waiting for the compositor's first configure.
    mapping,
    opening,
    open,
    closing,
};

/// What the view must do after a state change.
pub const Action = enum { none, map, teardown };

pub const Anim = struct {
    phase: Phase = .closed,
    progress: f64 = 0,
    from: f64 = 0,
    target: f64 = 0,
    start_ms: i64 = 0,
    /// Close asked for before the first configure: tear down from inside
    /// that configure (destroying a layer surface with its configure still
    /// queued is a protocol error).
    close_pending: bool = false,

    pub fn open(self: *Anim, now: i64) Action {
        switch (self.phase) {
            .closed => {
                self.phase = .mapping;
                self.close_pending = false;
                return .map;
            },
            .mapping => self.close_pending = false,
            .closing => self.startTo(.opening, 1, now),
            .opening, .open => {},
        }
        return .none;
    }

    pub fn close(self: *Anim, now: i64) Action {
        switch (self.phase) {
            .closed, .closing => {},
            .mapping => self.close_pending = true,
            .opening, .open => self.startTo(.closing, 0, now),
        }
        return .none;
    }

    pub fn toggle(self: *Anim, now: i64) Action {
        return switch (self.phase) {
            .closed, .closing => self.open(now),
            .mapping => blk: {
                // A second press before the first frame: cancel the open.
                self.close_pending = !self.close_pending;
                break :blk .none;
            },
            .opening, .open => self.close(now),
        };
    }

    /// The first configure arrived.
    pub fn mapped(self: *Anim, now: i64) Action {
        if (self.phase != .mapping) return .none;
        if (self.close_pending) {
            self.reset();
            return .teardown;
        }
        self.progress = 0;
        self.startTo(.opening, 1, now);
        return .none;
    }

    /// Advance the open/close animation to `now` (absolute time, so any
    /// poll tick may call it). `.teardown` when a close has finished.
    pub fn step(self: *Anim, now: i64) Action {
        if (self.phase != .opening and self.phase != .closing) return .none;
        const dur: f64 = @floatFromInt(if (self.phase == .opening) OPEN_MS else CLOSE_MS);
        const t = @as(f64, @floatFromInt(@max(now - self.start_ms, 0))) / dur;
        self.progress = self.from + (self.target - self.from) * easeOut(t);
        if (t < 1.0) return .none;
        if (self.phase == .opening) {
            self.phase = .open;
            self.progress = 1;
            return .none;
        }
        self.reset();
        return .teardown;
    }

    /// The compositor dropped the surface (output gone): back to closed.
    pub fn reset(self: *Anim) void {
        self.* = .{};
    }

    pub fn animating(self: *const Anim) bool {
        return self.phase == .opening or self.phase == .closing;
    }

    /// Keys and clicks count only while the panel is (becoming) visible.
    pub fn takesInput(self: *const Anim) bool {
        return self.phase == .opening or self.phase == .open;
    }

    fn startTo(self: *Anim, phase: Phase, target: f64, now: i64) void {
        self.phase = phase;
        self.from = self.progress;
        self.target = target;
        self.start_ms = now;
    }
};

// --- tests --------------------------------------------------------------------

const tt = std.testing;

test "parseArgs: verbs, tabs, defaults and errors" {
    try tt.expectEqual(Command{}, try parseArgs(&.{}));
    try tt.expectEqual(Command{ .verb = .open }, try parseArgs(&.{"open"}));
    try tt.expectEqual(Command{ .verb = .toggle, .tab = .media }, try parseArgs(&.{ "toggle", "media" }));
    try tt.expectEqual(Command{ .verb = .open, .tab = .weather }, try parseArgs(&.{ "open", "Weather" }));
    try tt.expectEqual(Command{ .verb = .close }, try parseArgs(&.{"close"}));
    try tt.expectError(error.UnknownVerb, parseArgs(&.{"show"}));
    try tt.expectError(error.UnknownVerb, parseArgs(&.{"Open"})); // verbs are exact
    try tt.expectError(error.UnknownTab, parseArgs(&.{ "open", "apps" }));
    try tt.expectError(error.TooManyArgs, parseArgs(&.{ "close", "media" }));
    try tt.expectError(error.TooManyArgs, parseArgs(&.{ "open", "media", "now" }));
}

test "parseLine and formatRequest round-trip" {
    try tt.expect(parseLine("overview toggle\n") == null);
    try tt.expect(parseLine("   \n") == null);
    try tt.expectEqual(Command{}, try parseLine("glance\n").?);
    try tt.expectEqual(Command{ .verb = .open, .tab = .weather }, try parseLine("  glance  open   weather \r\n").?);
    try tt.expectError(error.TooManyArgs, parseLine("glance open media a b c").?);
    var buf: [64]u8 = undefined;
    const cmds = [_]Command{ .{}, .{ .verb = .close }, .{ .verb = .open, .tab = .media }, .{ .verb = .toggle, .tab = .overview } };
    for (cmds) |c| {
        const line = try formatRequest(&buf, c);
        try tt.expect(std.mem.endsWith(u8, line, "\n"));
        try tt.expectEqual(c, try parseLine(line).?);
    }
}

test "Tab.parse and labels" {
    try tt.expectEqual(Tab.overview, Tab.parse("overview").?);
    try tt.expectEqual(Tab.media, Tab.parse("MEDIA").?);
    try tt.expect(Tab.parse("") == null);
    try tt.expectEqualStrings("Weather", Tab.weather.label());
}

/// Base sizes close to the 13 px font's real cards.
const SIZES = [CARD_COUNT]Size{
    .{ .w = 190, .h = 76 }, // clock
    .{ .w = 284, .h = 197 }, // weather
    .{ .w = 336, .h = 92 }, // user
    .{ .w = 238, .h = 262 }, // calendar
    .{ .w = 340, .h = 158 }, // media
    .{ .w = 340, .h = 138 }, // system
};
const TAB_W = [TAB_COUNT]i32{ 64, 40, 56 };

fn inside(outer: Rect, inner: Rect) bool {
    return inner.x >= outer.x and inner.y >= outer.y and
        inner.x + inner.w <= outer.x + outer.w and inner.y + inner.h <= outer.y + outer.h;
}

fn overlaps(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

test "layout: centred, every card at least its base size, no overlaps" {
    const l = compute(1920, 1080, SIZES, TAB_W);
    // 284 + 14 + 238 + 14 + 340 + 2 * 20
    try tt.expectEqual(@as(i32, 930), l.panel.w);
    try tt.expectEqual(@divTrunc(1920 - l.panel.w, 2), l.panel.x);
    try tt.expectEqual(@divTrunc(1080 - l.panel.h, 2), l.panel.y);
    const local = Rect{ .w = l.panel.w, .h = l.panel.h };
    for (l.cards, 0..) |r, i| {
        try tt.expect(r.w >= SIZES[i].w and r.h >= SIZES[i].h);
        try tt.expect(inside(l.content, r));
        try tt.expect(inside(local, r));
        for (l.cards[i + 1 ..]) |o| try tt.expect(!overlaps(r, o));
    }
    // The three column bottoms line up above the System strip, which spans
    // the content width and ends at its bottom.
    const sys = l.card(.system);
    for ([_]Card{ .weather, .calendar, .media }) |c| {
        const r = l.card(c);
        try tt.expectEqual(sys.y - GAP, r.y + r.h);
    }
    try tt.expectEqual(l.content.x, sys.x);
    try tt.expectEqual(l.content.w, sys.w);
    try tt.expectEqual(l.content.y + l.content.h, sys.y + sys.h);
    // Tallest column (Clock 76 + gap + Weather 197) + gap + System (138).
    try tt.expectEqual(@as(i32, 76 + GAP + 197 + GAP + 138), l.content.h);
    // Tab row above the cards, settings button on its right edge.
    for (l.tabs) |r| try tt.expect(r.y + r.h <= l.content.y);
    try tt.expectEqual(l.panel.w - PAD, l.settings.x + l.settings.w);
    try tt.expect(!overlaps(l.tabs[TAB_COUNT - 1], l.settings));
}

test "layout: a System card wider than the columns widens the middle" {
    var wide = SIZES;
    wide[@intFromEnum(Card.system)] = .{ .w = 1200, .h = 100 };
    const l = compute(1920, 1080, wide, TAB_W);
    try tt.expectEqual(@as(i32, 1200), l.content.w);
    const cal = l.card(.calendar);
    try tt.expect(cal.w > 238);
    try tt.expectEqual(l.content.x + l.content.w, l.card(.media).x + l.card(.media).w);
}

test "layout: small output pins the panel, tiny cards keep a minimum area" {
    const l = compute(800, 500, SIZES, TAB_W);
    try tt.expectEqual(@as(i32, 0), l.panel.x);
    try tt.expectEqual(@as(i32, 0), l.panel.y);
    const tiny = [_]Size{.{ .w = 10, .h = 10 }} ** CARD_COUNT;
    const m = compute(1920, 1080, tiny, TAB_W);
    try tt.expectEqual(MIN_CONTENT_W, m.content.w);
    try tt.expectEqual(MIN_CONTENT_H, m.content.h);
}

test "hitTest: backdrop, tabs, settings, cards only on the overview" {
    const l = compute(1920, 1080, SIZES, TAB_W);
    const px = l.panel.x;
    const py = l.panel.y;
    try tt.expect(hitTest(&l, .overview, px - 1, py + 10) == .backdrop);
    try tt.expect(hitTest(&l, .overview, 0, 0) == .backdrop);
    try tt.expect(hitTest(&l, .overview, px + 2, py + 2) == .panel);
    const tab1 = l.tabs[1];
    try tt.expect(hitTest(&l, .overview, px + tab1.x + 3, py + tab1.y + 3).eql(.{ .tab = .media }));
    try tt.expect(hitTest(&l, .media, px + l.settings.x + 1, py + l.settings.y + 1) == .settings);
    const cal = l.card(.calendar);
    const cx = px + cal.x + 5;
    const cy = py + cal.y + 5;
    try tt.expect(hitTest(&l, .overview, cx, cy).eql(.{ .card = .calendar }));
    try tt.expect(hitTest(&l, .media, cx, cy) == .panel);
    try tt.expect(hitTest(&l, .weather, cx, cy) == .panel);
    // The gap between two cards is panel, not a card.
    const clk = l.card(.clock);
    try tt.expect(hitTest(&l, .overview, px + clk.x + 5, py + clk.y + clk.h + 2) == .panel);
}

test "cardClick routes" {
    try tt.expectEqual(CardClick{ .switch_tab = .weather }, cardClick(.weather, false));
    try tt.expectEqual(CardClick.forward, cardClick(.calendar, false));
    try tt.expectEqual(CardClick.forward, cardClick(.media, true));
    try tt.expectEqual(CardClick{ .switch_tab = .media }, cardClick(.media, false));
    try tt.expectEqual(CardClick.none, cardClick(.system, false));
    try tt.expectEqual(CardClick.none, cardClick(.clock, true));
}

test "keys: only Esc acts" {
    try tt.expectEqual(KeyAction.close, keyAction(KEY_ESC));
    try tt.expectEqual(KeyAction.none, keyAction(15)); // Tab, for now
    try tt.expectEqual(KeyAction.none, keyAction(28));
}

test "easing, scale and dim curves" {
    try tt.expectEqual(@as(f64, 0), easeOut(0));
    try tt.expectEqual(@as(f64, 1), easeOut(1));
    try tt.expectEqual(@as(f64, 1), easeOut(7)); // clamped
    try tt.expect(easeOut(0.5) > 0.5); // ease-out front-loads the motion
    try tt.expectApproxEqAbs(@as(f64, 0.96), scaleAt(0), 1e-9);
    try tt.expectApproxEqAbs(@as(f64, 1.0), scaleAt(1), 1e-9);
    try tt.expectEqual(@as(u8, 0), dimAlpha(0));
    try tt.expectEqual(@as(u8, 110), dimAlpha(1));
}

test "anim: open maps, configure starts, step finishes" {
    var a = Anim{};
    try tt.expect(!a.takesInput());
    try tt.expectEqual(Action.map, a.open(0));
    try tt.expectEqual(Phase.mapping, a.phase);
    try tt.expectEqual(Action.none, a.open(1)); // already on its way
    try tt.expectEqual(Action.none, a.mapped(10));
    try tt.expectEqual(Phase.opening, a.phase);
    try tt.expect(a.takesInput() and a.animating());
    try tt.expectEqual(Action.none, a.step(10 + OPEN_MS / 2));
    try tt.expect(a.progress > 0.5 and a.progress < 1);
    try tt.expectEqual(Action.none, a.step(10 + OPEN_MS));
    try tt.expectEqual(Phase.open, a.phase);
    try tt.expectEqual(@as(f64, 1), a.progress);
    try tt.expect(!a.animating());
}

test "anim: close runs out to teardown, reopen mid-close resumes" {
    var a = Anim{};
    _ = a.open(0);
    _ = a.mapped(0);
    _ = a.step(OPEN_MS);
    try tt.expectEqual(Action.none, a.close(1000));
    try tt.expectEqual(Phase.closing, a.phase);
    try tt.expect(!a.takesInput());
    _ = a.step(1000 + CLOSE_MS / 2);
    const mid = a.progress;
    try tt.expect(mid > 0 and mid < 1);
    // Toggle again halfway through the close: opens from where it is.
    try tt.expectEqual(Action.none, a.toggle(1100));
    try tt.expectEqual(Phase.opening, a.phase);
    try tt.expectEqual(mid, a.from);
    _ = a.step(1100 + OPEN_MS);
    try tt.expectEqual(Phase.open, a.phase);
    _ = a.toggle(2000);
    try tt.expectEqual(Action.teardown, a.step(2000 + CLOSE_MS));
    try tt.expectEqual(Phase.closed, a.phase);
    try tt.expectEqual(@as(f64, 0), a.progress);
}

test "anim: close before the first configure tears down on configure" {
    var a = Anim{};
    _ = a.open(0);
    _ = a.close(1);
    try tt.expect(a.close_pending);
    try tt.expectEqual(Action.teardown, a.mapped(2));
    try tt.expectEqual(Phase.closed, a.phase);
    // Toggle twice before configure: cancel, then un-cancel.
    _ = a.open(3);
    _ = a.toggle(4);
    try tt.expect(a.close_pending);
    _ = a.toggle(5);
    try tt.expect(!a.close_pending);
    try tt.expectEqual(Action.none, a.mapped(6));
    try tt.expectEqual(Phase.opening, a.phase);
}

test "anim: close while closed and step while idle do nothing" {
    var a = Anim{};
    try tt.expectEqual(Action.none, a.close(0));
    try tt.expectEqual(Action.none, a.step(100));
    try tt.expectEqual(Action.none, a.mapped(100));
    try tt.expectEqual(Phase.closed, a.phase);
}
