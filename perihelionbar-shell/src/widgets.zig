//! perihelionbar-shell's "paint-only desktop widget" model.
//!
//! This is a direct port of the idea behind Event-Horizon-Shell's
//! `DesktopWidget` base class (C++, MIT — github.com/Event-Horizon-desktop-
//! environment/Event-Horizon-Shell): a widget owns no window; it is a small
//! struct that paints its current state into a shared ARGB surface buffer
//! on demand, reports the cadence at which it needs repainting, and reacts
//! to clicks over its rect. The host (main.zig) draws every widget into one
//! full-output "desktop layer" surface per monitor, lazy-scheduled from each
//! widget's cadence — no fixed animation loop.
//!
//! All drawing is software (freetype glyph coverage alpha-blended into a
//! wl_shm ARGB8888 buffer), matching how the bar renders and how the original
//! shell renders with Cairo.

const std = @import("std");
const posix = std.posix;
const font_mod = @import("font");
const art_mod = @import("art");
const logging = @import("logging");
const icontheme = @import("icontheme");
// Weather data service (Open-Meteo), shared with the bar's indicator:
// ../perihelionbar/src/weather.zig, wired as a module in build.zig.
const wsvc = @import("weather");
// CPU/GPU temperature service, shared with the bar: ../perihelionbar/src/temps.zig.
const tsvc = @import("temps");
// System-info service for the Fastfetch card: ../perihelionbar/src/fastfetch.zig.
const ffsvc = @import("fastfetch");
// Top-processes service for the Processes card: ../perihelionbar/src/procs.zig.
const psvc = @import("procs");
// Reminders file parsing for the Calendar card: ../perihelionbar/src/reminders.zig.
const rsvc = @import("reminders");
// Network-rate service for the Network card: ../perihelionbar/src/netrate.zig.
const nsvc = @import("netrate");
// User/uptime service for the User card: ../perihelionbar/src/userinfo.zig.
const usvc = @import("userinfo");

pub const WidgetId = enum { clock, weather, media, system, calendar, note1, icons, fastfetch, processes, network, user };

/// Card ids that existed once and were removed. An old shell.json or
/// widgets-disabled may still name them; they are skipped without a
/// warning (see parseWidgetId).
pub const RETIRED_WIDGET_IDS = [_][]const u8{"watch"};

pub const ParsedWidgetId = union(enum) { id: WidgetId, retired, unknown };

/// A shell.json / widgets-disabled card id: a live card, a removed one
/// (ignore quietly), or something unknown (worth a warning).
pub fn parseWidgetId(s: []const u8) ParsedWidgetId {
    if (std.meta.stringToEnum(WidgetId, s)) |id| return .{ .id = id };
    for (RETIRED_WIDGET_IDS) |r| {
        if (std.mem.eql(u8, s, r)) return .retired;
    }
    return .unknown;
}

/// Axis-aligned rect in surface coordinates. The host keeps one per widget
/// (measured from the font at startup, placed from config).
pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and
            px < self.x + @as(i32, @intCast(self.w)) and
            py < self.y + @as(i32, @intCast(self.h));
    }
};

/// Themed palette for cards. Colors are 0xAARRGGBB. `card_alpha` is 0-100
/// and only scales card fills (frosted-glass look, like the bar's
/// bg_opacity_percent); text/borders stay fully opaque.
pub const Theme = struct {
    bg_color: u32 = 0xFF0F0F0F,
    text_color: u32 = 0xFFDCDCDC,
    border_color: u32 = 0xFF454545,
    hover_color: u32 = 0xFF3A3A3A,
    /// Warm accent for public-holiday days on the calendar. Sourced from the
    /// matugen template's `holiday_color` when present, so it follows the
    /// wallpaper theme like the rest.
    holiday_color: u32 = 0xFFF0805C,
    /// Second accent (matugen tertiary / the palette's accent3; the
    /// template's `matrix_color`). The Fastfetch card's logo uses it for
    /// its $2 parts, the way the terminal logo uses a second colour.
    accent2_color: u32 = 0xFF94E2D5,
    card_alpha: u32 = 55,
    radius_px: u32 = 12,
};

/// Public so the host can compute a note's text width, which sharing this
/// constant (and thus always matching paint) is worth the API surface.
pub const CARD_PAD: i64 = 14;
const ROW_GAP: i64 = 5;
const BAR_H: i64 = 6;

// Media-card geometry. cardSizeFor and MediaWidget.paint share these so the
// measured rect always fits the painted layout (13px font metrics).
const MEDIA_W: i64 = 340;
const MEDIA_COVER: i64 = 64;
const MEDIA_HEAD_GAP: i64 = 10;
const MEDIA_PROG_H: i64 = 4;
const MEDIA_TIME_GAP: i64 = 8;
const MEDIA_TITLE_GAP: i64 = 4;
const MEDIA_CTRL_GAP: i64 = 10;

// Calendar-card geometry: header row (< month year >), weekday row, a 6x7
// day grid, and a footer line naming today's/next holiday. cardSizeFor and
// CalendarWidget share these.
const CAL_W: i64 = 196;
const CAL_CELL_W: i64 = 24; // 7 cells: 168 = CAL_W - 2*CARD_PAD
const CAL_CELL_H: i64 = 20;
const CAL_ROWS: i64 = 6;
const CAL_HEAD_GAP: i64 = 6;
const CAL_WD_GAP: i64 = 4;
const CAL_FOOT_GAP: i64 = 6;
const CAL_ARROW_ZONE: i64 = 20; // clickable width of the < / > header zones
// Reminders list under the footer: a gap, a Notes-style header (title over
// a hairline), then one row per reminder (shell.json calendar_reminders).
const CAL_REM_GAP: i64 = 10;
const CAL_REM_HEAD_GAP: i64 = 8; // same as NOTE_HEADER_GAP

/// shell.json calendar_reminders: rows listed under the month grid
/// (0 = no list). Set by the host before cards are measured.
pub var calendar_reminder_rows: usize = 0;
/// Most rows shell.json calendar_reminders can ask for.
pub const CAL_REMINDER_ROWS_MAX: usize = rsvc.MAX_ROWS;

/// Height the reminders list adds to the Calendar card (0 when off).
fn calRemindersH(lh: i64) i64 {
    if (calendar_reminder_rows == 0) return 0;
    return CAL_REM_GAP + lh + CAL_REM_HEAD_GAP + @as(i64, @intCast(calendar_reminder_rows)) * lh;
}

// Weather-card geometry: a four-line header (big temperature across lines
// 1-2, condition, place) over a forecast strip of day columns (label, icon
// + rain chance, high, low). cardSizeFor and WeatherWidget.paint share these.
const WX_W: i64 = 284;
const WX_HEAD_LINES: i64 = 4;
const WX_STRIP_LINES: i64 = 4;
const WX_STRIP_GAP: i64 = 12; // header → hairline → strip
const WX_STRIP_ROW_GAP: i64 = 2;
const WX_COL_MIN: i64 = 50; // 284 wide at 1x → five day columns

// Desktop-icons geometry: a 2-column grid of icon cells (44px bitmap + up
// to two 13px label lines), no card background — these sit directly on the
// wallpaper the way a classic desktop does. Sizing is content-driven: the
// host sizes the widget's rect from the scanned item count (see IconsWidget
// gridSize and main.zig applyIconsSize), so the corner-resize grip is
// disabled for this widget while Ctrl+drag keeps working.
pub const ICON_PX: i64 = 44; // icon bitmap box inside a cell
pub const ICON_CELL_W: i64 = 96; // cell width incl. side padding
pub const ICON_CELL_H: i64 = 88; // icon + two label lines
pub const ICON_GAP: i64 = 6; // between cells
pub const ICON_TILE_PAD: i64 = 10;
pub const ICON_COLS: usize = 2;
pub const MENU_W: i64 = 132;
pub const MENU_ROW_H: i64 = 26;
pub const MAX_ICONS: usize = 64; // scan cap (a desktop with 64+ shortcuts needs folders, not this list)
pub const ICON_NAME_MAX: usize = 128;
pub const ICON_PATH_MAX: usize = 340;
pub const ICON_EXEC_MAX: usize = 340;
pub const ICON_ARGS_MAX: usize = 16;

/// 0xAARRGGBB with alpha rescaled to `alpha_pct` (0-100), RGB untouched.
/// Used for card fills so only the background's opacity varies.
pub fn withAlpha(color: u32, alpha_pct: u32) u32 {
    const a: u32 = alpha_pct * 255 / 100;
    return (a << 24) | (color & 0x00FFFFFF);
}

/// 0xAARRGGBB with a fixed 8-bit alpha — for dimmed secondary text.
pub fn dim(color: u32, alpha_08: u32) u32 {
    return (alpha_08 << 24) | (color & 0x00FFFFFF);
}

pub fn lineH(font: *const font_mod.Font) i64 {
    return @as(i64, font.ascentPx()) + font.descentPx();
}

/// Card size per widget, measured from the font at startup so cards scale
/// with font size. Returns {width, height}.
pub fn cardSizeFor(id: WidgetId, font: *const font_mod.Font) [2]u32 {
    const lh: i64 = lineH(font);
    return switch (id) {
        .clock => clockCardSize(font),
        .weather => .{ @intCast(WX_W), @intCast(2 * CARD_PAD + WX_HEAD_LINES * lh + (WX_HEAD_LINES - 1) * ROW_GAP + WX_STRIP_GAP + WX_STRIP_LINES * lh + (WX_STRIP_LINES - 1) * WX_STRIP_ROW_GAP) },
        .media => .{ @intCast(MEDIA_W), @intCast(2 * CARD_PAD + MEDIA_COVER + MEDIA_HEAD_GAP + MEDIA_PROG_H + MEDIA_TIME_GAP + lh + MEDIA_CTRL_GAP + lh) },
        // Bars: CPU, MEM and GPU rows, each a label line over a 4px-gapped
        // bar. Rings: four gauges in a row with a label under each.
        .system => if (system_style == .rings)
            .{ @intCast(2 * CARD_PAD + 4 * RING_D + 3 * RING_GAP), @intCast(2 * CARD_PAD + RING_D + RING_LABEL_GAP + lh) }
        else
            .{ 190, @intCast(2 * CARD_PAD + 3 * lh + 2 * ROW_GAP + 3 * BAR_H + 2 * 4) },
        .calendar => .{ @intCast(CAL_W), @intCast(2 * CARD_PAD + 3 * lh + CAL_HEAD_GAP + CAL_WD_GAP + CAL_ROWS * CAL_CELL_H + CAL_FOOT_GAP + calRemindersH(lh)) },
        // Sticky note: a text card, tall enough for six wrapped lines.
        // Header strip (tabs, +, ×) over notes_lines lines of text.
        .note1 => .{ @intCast(NoteWidget.NOTE_W), @intCast(2 * CARD_PAD + noteHeaderH(lh) + notes_layout.lines * lh) },
        // Desktop icons: the real size is content-driven (rescan count =>
        // applyIconsSize); the base is just the empty-state minimum so the
        // first frame has a tile to paint into.
        .icons => .{ @intCast(2 * ICON_TILE_PAD + ICON_COLS * ICON_CELL_W + (ICON_COLS - 1) * ICON_GAP), @intCast(2 * ICON_TILE_PAD + ICON_CELL_H) },
        .fastfetch => fastfetchCardSize(font),
        // Header line, then one name/value line over a thin bar per row.
        .processes => .{ @intCast(PROC_W), @intCast(2 * CARD_PAD + lh + PROC_HEAD_GAP + @as(i64, @intCast(processes_rows)) * (lh + PROC_ROW_GAP + PROC_BAR_H + 2)) },
        // Header, optional graph, then the down/up line.
        // Avatar disc beside the name, user@host and uptime lines.
        .user => .{ @intCast(USER_W), @intCast(2 * CARD_PAD + @max(USER_AVATAR_D, userLines() * lh)) },
        .network => .{ @intCast(NET_W), @intCast(2 * CARD_PAD + 2 * lh + NET_GAP + (if (network_graph) NET_GRAPH_H + NET_GAP else 0)) },
    };
}

/// Monospace cell width estimate for sizing before any glyph is measured
/// (JetBrains Mono's advance is 0.6 em, rounded up a little).
fn monoCell(font: *const font_mod.Font) i64 {
    return @divTrunc(@as(i64, font.pixel_size) * 62 + 99, 100);
}

// --- clock styles ---------------------------------------------------------

pub const ClockStyle = enum {
    /// Large HH:MM, small seconds/AM-PM beside it, the date under it.
    digital,
    /// Split-flap tiles in the accent colour.
    flip,
    /// macOS-style: hours over minutes, big, with the date beside them.
    stacked,
    /// The original two-line text clock.
    classic,

    pub fn parse(s: []const u8) ?ClockStyle {
        if (std.meta.stringToEnum(ClockStyle, s)) |v| return v;
        if (std.ascii.eqlIgnoreCase(s, "macos")) return .stacked;
        return null;
    }
};

/// Clock options (shell.json clock_*), set by the host before any card is
/// measured; the card's size depends on them.
pub const ClockLayout = struct {
    style: ClockStyle = .digital,
    seconds: bool = false,
    date: bool = true,
    h24: bool = true,
};
pub var clock_layout: ClockLayout = .{};

const CLOCK_W: i64 = 190;
const FLIP_TILE_GAP: i64 = 4;
const FLIP_COLON_W: i64 = 12;
const FLIP_SIDE_GAP: i64 = 8;
const STACK_GAP: i64 = 6;
const STACK_COL_GAP: i64 = 16;

fn clockCardSize(font: *const font_mod.Font) [2]u32 {
    const lh = lineH(font);
    const asc: i64 = font.ascentPx();
    const cell = monoCell(font);
    const L = clock_layout;
    const date_h: i64 = if (L.date) ROW_GAP + lh else 0;
    const side_w: i64 = (if (L.seconds) 3 * cell else 0) + (if (!L.h24) 3 * cell else 0);
    return switch (L.style) {
        .classic => .{ @intCast(CLOCK_W), @intCast(2 * CARD_PAD + lh + date_h) },
        .digital => .{
            @intCast(@max(CLOCK_W, 2 * CARD_PAD + 5 * 2 * cell + side_w + FLIP_SIDE_GAP)),
            // Digits have no descenders: the 2x line is 2 * ascent tall.
            @intCast(2 * CARD_PAD + 2 * asc + date_h),
        },
        .flip => blk: {
            const tile_w = 2 * cell + 12;
            const tile_h = 2 * asc + 8;
            const side = if (side_w > 0) FLIP_SIDE_GAP + 2 * cell else 0;
            break :blk .{
                @intCast(@max(CLOCK_W, 2 * CARD_PAD + 4 * tile_w + 2 * FLIP_TILE_GAP + FLIP_COLON_W + side)),
                @intCast(2 * CARD_PAD + tile_h + date_h),
            };
        },
        .stacked => .{
            @intCast(@max(CLOCK_W, 2 * CARD_PAD + 6 * cell + STACK_COL_GAP + 10 * cell)),
            @intCast(2 * CARD_PAD + 6 * asc + STACK_GAP),
        },
    };
}

// --- system card ring style ------------------------------------------------

pub const SystemStyle = enum {
    bars,
    rings,

    pub fn parse(s: []const u8) ?SystemStyle {
        if (std.ascii.eqlIgnoreCase(s, "bars") or std.ascii.eqlIgnoreCase(s, "rows")) return .bars;
        if (std.ascii.eqlIgnoreCase(s, "rings") or std.ascii.eqlIgnoreCase(s, "gauges")) return .rings;
        return null;
    }
};
/// shell.json system_style, set by the host before cards are measured.
pub var system_style: SystemStyle = .bars;
const RING_D: i64 = 58;
const RING_GAP: i64 = 14;
const RING_W: i64 = 6;
const RING_LABEL_GAP: i64 = 6;

// --- processes card geometry -------------------------------------------------

/// shell.json processes_count, set by the host before cards are measured.
pub var processes_rows: usize = 6;
const PROC_W: i64 = 250;
const PROC_HEAD_GAP: i64 = 8;
const PROC_ROW_GAP: i64 = 3;
const PROC_BAR_H: i64 = 2;

// --- network card geometry ---------------------------------------------------

/// shell.json network_graph, set by the host before cards are measured.
pub var network_graph: bool = true;
const NET_W: i64 = 250; // same column width as the Processes card
const NET_GAP: i64 = 8;
const NET_GRAPH_H: i64 = 44;

// --- user card geometry ------------------------------------------------------

/// shell.json user_host / user_uptime_short, set by the host before cards
/// are measured.
pub var user_host: bool = true;
pub var user_uptime_short: bool = false;
const USER_W: i64 = 240;
const USER_AVATAR_D: i64 = 44;
const USER_GAP: i64 = 12; // avatar → text column

fn userLines() i64 {
    return if (user_host) 3 else 2;
}

// Fastfetch-card geometry: logo column (text logo or distro glyph), then
// the title, a rule, one row per field and a palette row.
const FF_TEXT_W: i64 = 340;
const FF_LOGO_GAP: i64 = 18;
const FF_ROW_GAP: i64 = 2;
const FF_GLYPH_W: i64 = 96;
const FF_LABEL_GAP: i64 = 10;

/// What the Fastfetch card's size depends on, known before the widget is
/// built (the host sets it from the configured service before initWidgets
/// measures any card, and it never changes while the shell runs, so every
/// cardSizeFor call — startup, zoom, resize — agrees).
pub const FastfetchLayout = struct {
    /// Full-height lines: rows and section headers.
    rows: i64 = ffsvc.DEFAULT_FIELDS.len,
    /// Half-height gaps (the config's "break" modules).
    spacers: i64 = 0,
    palette: bool = true,
    logo_cols: i64 = 0,
    logo_lines: i64 = 0,
    logo_off: bool = false,
};
pub var fastfetch_layout: FastfetchLayout = .{};

pub fn setFastfetchLayout(svc: *const ffsvc.Service) void {
    var lines: i64 = @intCast(svc.field_count);
    var spacers: i64 = 0;
    if (svc.layout == .config) {
        lines = 0;
        for (svc.cardRows()) |*r| {
            if (r.kind == .spacer) spacers += 1 else lines += 1;
        }
    }
    fastfetch_layout = .{
        .rows = lines,
        .spacers = spacers,
        .palette = svc.palette,
        .logo_cols = @intCast(svc.logo_cols),
        .logo_lines = @intCast(svc.logo_count),
        .logo_off = svc.logo_off,
    };
}

fn fastfetchCardSize(font: *const font_mod.Font) [2]u32 {
    const lh = lineH(font);
    const L = fastfetch_layout;
    // Monospace cell (JetBrains Mono's advance is 0.6 em); a little over so
    // block-drawn logos never clip. Paint measures for real.
    const cell = @divTrunc(@as(i64, font.pixel_size) * 62 + 99, 100);
    const logo_w: i64 = if (L.logo_off) 0 else if (L.logo_cols > 0) L.logo_cols * cell else FF_GLYPH_W;
    const gap: i64 = if (logo_w > 0) FF_LOGO_GAP else 0;
    const text_rows = L.rows + 2 + @as(i64, if (L.palette) 1 else 0); // title, rule, rows, palette
    const rows_h = text_rows * lh + (text_rows - 1) * FF_ROW_GAP + L.spacers * @divTrunc(lh, 2);
    const logo_h = L.logo_lines * lh;
    return .{
        @intCast(2 * CARD_PAD + logo_w + gap + FF_TEXT_W),
        @intCast(2 * CARD_PAD + @max(rows_h, logo_h, FF_GLYPH_W)),
    };
}

/// Drawing context handed to a widget's paint: the FULL surface buffer plus
/// font/theme. All coordinates are surface-absolute (the host paints every
/// widget into the same buffer), and the host has already drawn the card
/// background behind each widget's rect before calling paint.
pub const Canvas = struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
    font: *font_mod.Font,
    theme: *const Theme,
    /// Content zoom for corner-resized cards (1.0 = base size): the host
    /// swaps `font` for a pixel-size-matched face AND sets this, and each
    /// paint scales its layout constants with `zx` below. Text metrics
    /// come from the swapped font automatically; only the compile-time
    /// geometry needs explicit scaling at each use site.
    zoom: f32 = 1.0,

    /// Scale a layout constant into zoomed space (pads, gaps, radii,
    /// cover/cell sizes — everything that isn't a font metric or a
    /// rect-derived width).
    pub fn zx(self: Canvas, v: i64) i64 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * self.zoom));
    }

    /// Straight-alpha OVER blend of a 0xAARRGGBB src onto dst, preserving
    /// dst alpha — cards are translucent, so glyph coverage must composite
    /// instead of assuming an opaque backdrop like the bar can.
    pub fn blendOver(dst: u32, src: u32) u32 {
        const sa: u32 = (src >> 24) & 0xFF;
        if (sa == 255) return src;
        if (sa == 0) return dst;
        const da: u32 = (dst >> 24) & 0xFF;
        const oa = sa + (da * (255 - sa)) / 255;
        if (oa == 0) return 0;
        const sr = (src >> 16) & 0xFF;
        const sg = (src >> 8) & 0xFF;
        const sb = src & 0xFF;
        const dr = (dst >> 16) & 0xFF;
        const dg = (dst >> 8) & 0xFF;
        const db = dst & 0xFF;
        const r = (sr * sa + (dr * da * (255 - sa)) / 255) / oa;
        const g = (sg * sa + (dg * da * (255 - sa)) / 255) / oa;
        const b = (sb * sa + (db * da * (255 - sa)) / 255) / oa;
        return (oa << 24) | (r << 16) | (g << 8) | b;
    }

    pub fn fillRect(self: Canvas, x0: i64, y0: i64, w: u64, h: u64, color: u32) void {
        const x_start = @max(x0, 0);
        const y_start = @max(y0, 0);
        const x_end = @min(x0 + @as(i64, @intCast(w)), @as(i64, @intCast(self.width)));
        const y_end = @min(y0 + @as(i64, @intCast(h)), @as(i64, @intCast(self.height)));
        if (x_end <= x_start or y_end <= y_start) return;
        const sa = (color >> 24) & 0xFF;
        if (sa == 0) return; // fully transparent: blendOver is the identity
        const x0u: usize = @intCast(x_start);
        const x1u: usize = @intCast(x_end);
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const row = self.pixels[@as(usize, @intCast(y)) * self.width ..][0..self.width];
            // Opaque primitives (bars, tiles, filled cells)
            // are most of the fillRect calls; write them row-wise instead of
            // running the per-pixel alpha blend.
            if (sa == 255) {
                @memset(row[x0u..x1u], color);
                continue;
            }
            var x = x_start;
            while (x < x_end) : (x += 1) {
                row[@intCast(x)] = blendOver(row[@intCast(x)], color);
            }
        }
    }

    fn insideRounded(x: i64, y: i64, l: i64, t: i64, w: i64, h: i64, r: i64) bool {
        if (x < l or y < t or x >= l + w or y >= t + h) return false;
        if (r <= 0) return true;
        if (x >= l + r and x < l + w - r) return true;
        if (y >= t + r and y < t + h - r) return true;
        const cx = std.math.clamp(x, l + r, l + w - r - 1);
        const cy = std.math.clamp(y, t + r, t + h - r - 1);
        const dx = x - cx;
        const dy = y - cy;
        return dx * dx + dy * dy <= r * r;
    }

    /// Fills a rounded card with `fill` (already alpha-scaled) plus a 1px
    /// rounded border in `border`.
    pub fn card(self: Canvas, r: Rect, fill: u32, border: u32) void {
        const radius: i64 = @intCast(@min(self.theme.radius_px, @min(r.w, r.h) / 2));
        const l: i64 = r.x;
        const t: i64 = r.y;
        const w: i64 = @intCast(r.w);
        const h: i64 = @intCast(r.h);
        const inner_r = if (radius > 0) radius - 1 else 0;
        const x_start = @max(l, 0);
        const x_end = @min(l + w, @as(i64, @intCast(self.width)));
        const y_start = @max(t, 0);
        const y_end = @min(t + h, @as(i64, @intCast(self.height)));
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const row = self.pixels[@as(usize, @intCast(y)) * self.width ..][0..self.width];
            var x = x_start;
            while (x < x_end) : (x += 1) {
                const idx: usize = @intCast(x);
                if (!insideRounded(x, y, l, t, w, h, radius)) continue;
                const in_inner = insideRounded(x, y, l + 1, t + 1, w - 2, h - 2, inner_r);
                row[idx] = blendOver(row[idx], if (in_inner) fill else border);
            }
        }
    }

    /// Sum of each codepoint's advance width in `text`.
    pub fn textWidth(self: Canvas, text: []const u8) i64 {
        var total: i64 = 0;
        var i: usize = 0;
        while (nextUtf8Codepoint(text, &i)) |cp| {
            total += (self.font.glyph(cp) catch continue).advance_x;
        }
        return total;
    }

    /// Draws `text` with its pen origin at (`x`, baseline `baseline_y`),
    /// alpha-blending glyph coverage over whatever the card underneath left.
    /// Returns the total advance width.
    pub fn drawText(self: Canvas, x: i64, baseline_y: i64, text: []const u8, color: u32) i64 {
        var pen: i64 = x;
        var i: usize = 0;
        while (nextUtf8Codepoint(text, &i)) |cp| {
            const g = self.font.glyph(cp) catch continue;
            const x0 = pen + g.bitmap_left;
            const y0 = baseline_y - g.bitmap_top;
            for (0..g.height) |row_off| {
                for (0..g.width) |col_off| {
                    const coverage = g.pixels[row_off * g.width + col_off];
                    if (coverage == 0) continue;
                    const px = x0 + @as(i64, @intCast(col_off));
                    const py = y0 + @as(i64, @intCast(row_off));
                    if (px < 0 or py < 0) continue;
                    const pxu: usize = @intCast(px);
                    const pyu: usize = @intCast(py);
                    if (pxu >= self.width or pyu >= self.height) continue;
                    // Glyph coverage is the glyph's alpha: 0xAARRGGBB src with
                    // A=coverage and RGB=text color (straight alpha).
                    const src = (@as(u32, coverage) << 24) | (color & 0x00FFFFFF);
                    self.pixels[pyu * self.width + pxu] = blendOver(self.pixels[pyu * self.width + pxu], src);
                }
            }
            pen += g.advance_x;
        }
        return pen - x;
    }

    /// Blits straight-alpha RGBA bytes (`w*h*4` row-major) with a rounded-
    /// corner mask — the media cover art over its tile. Per-pixel OVER blend
    /// like drawText, so translucent PNG edges composite instead of punching
    /// holes to the wallpaper.
    pub fn blitRgba(self: Canvas, x: i64, y: i64, w: u64, h: u64, rgba: []const u8, radius: i64) void {
        const iw: i64 = @intCast(w);
        const ih: i64 = @intCast(h);
        var row: u64 = 0;
        while (row < h) : (row += 1) {
            var col: u64 = 0;
            while (col < w) : (col += 1) {
                const o = (row * w + col) * 4;
                const a: u32 = rgba[o + 3];
                if (a == 0) continue;
                const px = x + @as(i64, @intCast(col));
                const py = y + @as(i64, @intCast(row));
                if (px < 0 or py < 0) continue;
                const pxu: usize = @intCast(px);
                const pyu: usize = @intCast(py);
                if (pxu >= self.width or pyu >= self.height) continue;
                if (!insideRounded(px, py, x, y, iw, ih, radius)) continue;
                const src = (a << 24) | (@as(u32, rgba[o]) << 16) | (@as(u32, rgba[o + 1]) << 8) | rgba[o + 2];
                self.pixels[pyu * self.width + pxu] = blendOver(self.pixels[pyu * self.width + pxu], src);
            }
        }
    }

    /// Blits straight-alpha ARGB32 (`w*h` row-major 0xAARRGGBB) — the
    /// icontheme decoder's icon tiles (desktop icons). Per-pixel OVER
    /// blend with the same rounded mask as blitRgba, so transparent
    /// corners and antialiased rims composite instead of punching holes.
    pub fn blitArgb(self: Canvas, x: i64, y: i64, w: u64, h: u64, argb: []const u32, radius: i64) void {
        const iw: i64 = @intCast(w);
        const ih: i64 = @intCast(h);
        var row: u64 = 0;
        while (row < h) : (row += 1) {
            var col: u64 = 0;
            while (col < w) : (col += 1) {
                const src = argb[row * w + col];
                const a: u32 = (src >> 24) & 0xFF;
                if (a == 0) continue;
                const px = x + @as(i64, @intCast(col));
                const py = y + @as(i64, @intCast(row));
                if (px < 0 or py < 0) continue;
                const pxu: usize = @intCast(px);
                const pyu: usize = @intCast(py);
                if (pxu >= self.width or pyu >= self.height) continue;
                if (!insideRounded(px, py, x, y, iw, ih, radius)) continue;
                self.pixels[pyu * self.width + pxu] = blendOver(self.pixels[pyu * self.width + pxu], src);
            }
        }
    }

    /// A float-space point — the anti-aliased primitives below take arrays
    /// of these.
    pub const FPt = struct { x: f64, y: f64 };

    /// Alpha-blend `color` at (x, y) with fractional coverage `cov`
    /// (0..1) — shared exit for the AA primitives: `cov` becomes the
    /// source's alpha, then the usual straight-alpha OVER blend.
    fn blendCov(self: Canvas, x: i64, y: i64, color: u32, cov: f64) void {
        if (cov <= 0.0) return;
        if (x < 0 or y < 0) return;
        const pxu: usize = @intCast(x);
        const pyu: usize = @intCast(y);
        if (pxu >= self.width or pyu >= self.height) return;
        const a: f64 = @floatFromInt((color >> 24) & 0xFF);
        const eff: u32 = @intFromFloat(@min(1.0, cov) * a);
        if (eff == 0) return;
        const src = (eff << 24) | (color & 0x00FFFFFF);
        self.pixels[pyu * self.width + pxu] = blendOver(self.pixels[pyu * self.width + pxu], src);
    }

    /// Anti-aliased filled circle: solid inside, one-pixel feather at the
    /// rim from the signed distance to it (gauge caps, avatar discs).
    pub fn fillCircleAA(self: Canvas, cx: f64, cy: f64, rad: f64, color: u32) void {
        const x0: i64 = @intFromFloat(@floor(cx - rad - 1.0));
        const x1: i64 = @intFromFloat(@ceil(cx + rad + 1.0));
        const y0: i64 = @intFromFloat(@floor(cy - rad - 1.0));
        const y1: i64 = @intFromFloat(@ceil(cy + rad + 1.0));
        var y = @max(y0, 0);
        while (y <= y1) : (y += 1) {
            var x = @max(x0, 0);
            while (x <= x1) : (x += 1) {
                const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
                const dist = @sqrt(dx * dx + dy * dy);
                self.blendCov(x, y, color, rad + 0.5 - dist);
            }
        }
    }

    /// AA-filled ring (annulus) — gauge tracks. Coverage is the smaller of
    /// both rims'.
    pub fn fillRingAA(self: Canvas, cx: f64, cy: f64, rad_in: f64, rad_out: f64, color: u32) void {
        const x0: i64 = @intFromFloat(@floor(cx - rad_out - 1.0));
        const x1: i64 = @intFromFloat(@ceil(cx + rad_out + 1.0));
        const y0: i64 = @intFromFloat(@floor(cy - rad_out - 1.0));
        const y1: i64 = @intFromFloat(@ceil(cy + rad_out + 1.0));
        var y = @max(y0, 0);
        while (y <= y1) : (y += 1) {
            var x = @max(x0, 0);
            while (x <= x1) : (x += 1) {
                const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
                const dist = @sqrt(dx * dx + dy * dy);
                self.blendCov(x, y, color, @min(rad_out + 0.5 - dist, dist - (rad_in - 0.5)));
            }
        }
    }

    /// AA-filled arc of a ring, clockwise from 12 o'clock over `frac` of a
    /// full turn, with round caps — the System card's gauges. The angular
    /// edge is cut hard, but each end sits under its cap disc, so the
    /// visible outline is AA everywhere. Meant for an opaque `color` (caps
    /// overlap the arc).
    pub fn fillArcAA(self: Canvas, cx: f64, cy: f64, rad_in: f64, rad_out: f64, frac: f64, color: u32) void {
        const f = std.math.clamp(frac, 0.0, 1.0);
        if (f <= 0.0) return;
        if (f >= 0.999) return self.fillRingAA(cx, cy, rad_in, rad_out, color);
        const tau = 2.0 * std.math.pi;
        const sweep = f * tau;
        const x0: i64 = @intFromFloat(@floor(cx - rad_out - 1.0));
        const x1: i64 = @intFromFloat(@ceil(cx + rad_out + 1.0));
        const y0: i64 = @intFromFloat(@floor(cy - rad_out - 1.0));
        const y1: i64 = @intFromFloat(@ceil(cy + rad_out + 1.0));
        var y = @max(y0, 0);
        while (y <= y1) : (y += 1) {
            var x = @max(x0, 0);
            while (x <= x1) : (x += 1) {
                const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
                const dist = @sqrt(dx * dx + dy * dy);
                const cov = @min(rad_out + 0.5 - dist, dist - (rad_in - 0.5));
                if (cov <= 0.0) continue;
                var a = std.math.atan2(dx, -dy); // 0 at the top, clockwise
                if (a < 0.0) a += tau;
                if (a > sweep) continue;
                self.blendCov(x, y, color, cov);
            }
        }
        const mid = (rad_in + rad_out) / 2.0;
        const half = (rad_out - rad_in) / 2.0;
        self.fillCircleAA(cx, cy - mid, half, color);
        self.fillCircleAA(cx + @sin(sweep) * mid, cy - @cos(sweep) * mid, half, color);
    }

    /// AA-filled convex polygon (either winding): per-pixel coverage from
    /// the distance to the nearest edge, so rotated shapes stay smooth.
    pub fn fillConvex(self: Canvas, pts: []const FPt, color: u32) void {
        if (pts.len < 3) return;
        var minx = pts[0].x;
        var maxx = pts[0].x;
        var miny = pts[0].y;
        var maxy = pts[0].y;
        for (pts[1..]) |p| {
            minx = @min(minx, p.x);
            maxx = @max(maxx, p.x);
            miny = @min(miny, p.y);
            maxy = @max(maxy, p.y);
        }
        // Signed area picks up the winding; flip distances so "inside" is
        // positive either way.
        var area: f64 = 0;
        for (pts, 0..) |p, i| {
            const q = pts[(i + 1) % pts.len];
            area += p.x * q.y - q.x * p.y;
        }
        const orient: f64 = if (area >= 0) 1.0 else -1.0;
        const x0: i64 = @intFromFloat(@floor(minx - 1.0));
        const x1: i64 = @intFromFloat(@ceil(maxx + 1.0));
        const y0: i64 = @intFromFloat(@floor(miny - 1.0));
        const y1: i64 = @intFromFloat(@ceil(maxy + 1.0));
        var y = @max(y0, 0);
        while (y <= y1) : (y += 1) {
            var x = @max(x0, 0);
            while (x <= x1) : (x += 1) {
                const px = @as(f64, @floatFromInt(x)) + 0.5;
                const py = @as(f64, @floatFromInt(y)) + 0.5;
                var min_d: f64 = std.math.floatMax(f64);
                for (pts, 0..) |p, i| {
                    const q = pts[(i + 1) % pts.len];
                    const ex = q.x - p.x;
                    const ey = q.y - p.y;
                    const len = @sqrt(ex * ex + ey * ey);
                    if (len == 0.0) continue;
                    const cross = (ex * (py - p.y) - ey * (px - p.x)) * orient;
                    min_d = @min(min_d, cross / len);
                }
                self.blendCov(x, y, color, min_d + 0.5);
            }
        }
    }
};

// --- UTF-8 plumbing (ported from the bar) ---------------------------------

fn nextUtf8Codepoint(text: []const u8, i: *usize) ?u32 {
    if (i.* >= text.len) return null;
    const b0 = text[i.*];
    if (b0 < 0x80) {
        i.* += 1;
        return b0;
    }
    if (b0 & 0xE0 == 0xC0 and i.* + 1 < text.len) {
        const cp = (@as(u32, b0 & 0x1F) << 6) | (text[i.* + 1] & 0x3F);
        i.* += 2;
        return cp;
    }
    if (b0 & 0xF0 == 0xE0 and i.* + 2 < text.len) {
        const cp = (@as(u32, b0 & 0x0F) << 12) | (@as(u32, text[i.* + 1] & 0x3F) << 6) | (text[i.* + 2] & 0x3F);
        i.* += 3;
        return cp;
    }
    if (b0 & 0xF8 == 0xF0 and i.* + 3 < text.len) {
        const cp = (@as(u32, b0 & 0x07) << 18) | (@as(u32, text[i.* + 1] & 0x3F) << 12) | (@as(u32, text[i.* + 2] & 0x3F) << 6) | (text[i.* + 3] & 0x3F);
        i.* += 4;
        return cp;
    }
    i.* += 1; // malformed lead byte — skip as a single byte
    return 0x20;
}

fn utf8Encode(cp: u32, out: []u8) usize {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        out[0] = @intCast(0xF0 | (cp >> 18));
        out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

/// Blits an uncached oversized glyph (shared font_mod.glyphScaled) with its
/// top-left at (`x0`, `y0`), coverage-blended via blendOver so translucent
/// card edges composite instead of punching holes. Returns the advance.
fn drawBigIcon(c: Canvas, x0: i64, y0: i64, big: *const font_mod.BigGlyph, color: u32) i64 {
    for (0..big.height) |row| {
        for (0..big.width) |col| {
            const coverage = big.pixels[row * big.width + col];
            if (coverage == 0) continue;
            const px = x0 + @as(i64, big.bitmap_left) + @as(i64, @intCast(col));
            const py = y0 + @as(i64, @intCast(row));
            if (px < 0 or py < 0) continue;
            const pxu: usize = @intCast(px);
            const pyu: usize = @intCast(py);
            if (pxu >= c.width or pyu >= c.height) continue;
            const src = (@as(u32, coverage) << 24) | (color & 0x00FFFFFF);
            c.pixels[pyu * c.width + pxu] = Canvas.blendOver(c.pixels[pyu * c.width + pxu], src);
        }
    }
    return big.advance_x;
}

/// Condition effect kinds for the weather card animation — mirrors the
/// bar's WeatherFx table (the shell can't import the bar's main.zig).
const WeatherFx = enum { none, rain, snow, storm, clear, cloud, fog, wind };

/// Card animation for a condition family (weather.zig Kind).
fn fxForKind(kind: wsvc.Kind) WeatherFx {
    return switch (kind) {
        .clear => .clear,
        .partly_cloudy, .overcast => .cloud,
        .fog => .fog,
        .drizzle, .freezing, .rain, .showers => .rain,
        .snow, .snow_showers => .snow,
        .thunderstorm => .storm,
        .unknown => .none,
    };
}

/// Deterministic 0..1 scatter for particle `i` — same stateless clock as
/// the bar's fxHash01.
fn fxHash01(i: i64) f32 {
    const h: u64 = @as(u64, @intCast(i)) *% 2654435761;
    return @as(f32, @floatFromInt((h >> 8) & 0xFFFF)) / 65535.0;
}

/// 0xFFRRGGBB mix of two opaque colors (t toward b) — for tints the
/// coverage-blend path can't express (it replaces alpha with coverage).
fn mixRgb(a: u32, b: u32, t: f32) u32 {
    const ar: f32 = @floatFromInt((a >> 16) & 0xFF);
    const ag: f32 = @floatFromInt((a >> 8) & 0xFF);
    const ab: f32 = @floatFromInt(a & 0xFF);
    const br: f32 = @floatFromInt((b >> 16) & 0xFF);
    const bg: f32 = @floatFromInt((b >> 8) & 0xFF);
    const bb: f32 = @floatFromInt(b & 0xFF);
    const r: u32 = @intFromFloat(ar + (br - ar) * t);
    const g: u32 = @intFromFloat(ag + (bg - ag) * t);
    const bl: u32 = @intFromFloat(ab + (bb - ab) * t);
    return (@as(u32, 0xFF) << 24) | (r << 16) | (g << 8) | bl;
}

/// Warm radial glow for clear skies: soft halo centered on (cx, cy) with
/// radius `rad`, hottest in the middle. Drawn under the condition icon so
/// the glyph stays crisp — sunshine you can feel.
fn drawSunGlow(c: Canvas, r: Rect, cx: i64, cy: i64, rad: i64) void {
    if (rad <= 0) return;
    const fr: f32 = @floatFromInt(rad);
    var y = cy - rad;
    while (y <= cy + rad) : (y += 1) {
        var x = cx - rad;
        while (x <= cx + rad) : (x += 1) {
            const dx: f32 = @floatFromInt(x - cx);
            const dy: f32 = @floatFromInt(y - cy);
            const d = @sqrt(dx * dx + dy * dy) / fr;
            if (d >= 1.0) continue;
            const u = 1.0 - d;
            const a: u8 = @intFromFloat(70.0 * u * u);
            putCardFx(c, r, x, y, 0xFFE9A8, a);
        }
    }
}

/// One effect pixel inside the card rect, coverage-blended (alpha-safe for
/// translucent cards, unlike the bar's opaque pipeline).
fn putCardFx(c: Canvas, r: Rect, x: i64, y: i64, rgb: u32, alpha: u8) void {
    const rx0: i64 = r.x;
    const ry0: i64 = r.y;
    const rx1: i64 = r.x + @as(i64, @intCast(r.w));
    const ry1: i64 = r.y + @as(i64, @intCast(r.h));
    if (x < rx0 or x >= rx1 or y < ry0 or y >= ry1) return;
    if (x < 0 or y < 0) return;
    const pxu: usize = @intCast(x);
    const pyu: usize = @intCast(y);
    if (pxu >= c.width or pyu >= c.height) return;
    const src = (@as(u32, alpha) << 24) | (rgb & 0x00FFFFFF);
    c.pixels[pyu * c.width + pxu] = Canvas.blendOver(c.pixels[pyu * c.width + pxu], src);
}

/// Hover overlay for the weather card: condition particles over the whole
/// card rect, driven by the widget's 60ms anim_frame (see the union tick).
/// Drawn after the content at low alpha — weather that moves when watched.
fn drawWeatherFxCard(c: Canvas, r: Rect, kind: WeatherFx, frame: u32, tint: u32) void {
    if (kind == .none) return;
    const w: i64 = @intCast(r.w);
    const h: i64 = @intCast(r.h);
    if (w <= 0 or h <= 0) return;
    const fi: i64 = @intCast(frame % 100000);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const x0: i64 = r.x;
    const y0: i64 = r.y;
    switch (kind) {
        .none => {},
        .rain => {
            var i: i64 = 0;
            while (i < 18) : (i += 1) {
                const fx = x0 + @as(i64, @intFromFloat(fxHash01(i * 2 + 1) * fw));
                const fy = y0 + @mod(fi * 3 + @divTrunc(i * h, 18), h);
                const rgb = tint & 0x00FFFFFF;
                putCardFx(c, r, fx, fy, rgb, 100);
                putCardFx(c, r, fx, fy + 1, rgb, 100);
                putCardFx(c, r, fx, fy + 2, rgb, 100);
            }
        },
        .snow => {
            var i: i64 = 0;
            while (i < 18) : (i += 1) {
                const fy = y0 + @mod(@divTrunc(fi, 2) + @divTrunc(i * h, 18), h);
                const sway = @round(2.0 * std.math.sin(@as(f32, @floatFromInt(fi)) * 0.08 + @as(f32, @floatFromInt(i)) * 1.7));
                const fx = x0 + @as(i64, @intFromFloat(fxHash01(i * 2 + 3) * fw)) + @as(i64, @intFromFloat(sway));
                putCardFx(c, r, fx, fy, 0xFFFFFF, 120);
            }
        },
        .storm => {
            var i: i64 = 0;
            while (i < 14) : (i += 1) {
                const fx = x0 + @as(i64, @intFromFloat(fxHash01(i * 2 + 1) * fw));
                const fy = y0 + @mod(fi * 3 + @divTrunc(i * h, 14), h);
                const rgb = tint & 0x00FFFFFF;
                putCardFx(c, r, fx, fy, rgb, 90);
                putCardFx(c, r, fx, fy + 1, rgb, 90);
                putCardFx(c, r, fx, fy + 2, rgb, 90);
            }
            if (@mod(fi, 110) < 5) {
                var yy = y0;
                while (yy < y0 + h) : (yy += 1) {
                    var xx = x0;
                    while (xx < x0 + w) : (xx += 1) {
                        putCardFx(c, r, xx, yy, 0xFFFFFF, 40);
                    }
                }
            }
        },
        // Perihelion: no sweeping highlight line on clear skies (it read as a
        // flickering grey line across the card); the sun glow stays.
        .clear => {},
        .cloud => {
            var i: i64 = 0;
            while (i < 4) : (i += 1) {
                const px = x0 + @mod(fi + i * @divTrunc(w, 4), w);
                const py = y0 + @as(i64, @intFromFloat(fxHash01(i * 2 + 5) * fh));
                var ky: i64 = 0;
                while (ky < 3) : (ky += 1) {
                    var kx: i64 = 0;
                    while (kx < 5) : (kx += 1) {
                        putCardFx(c, r, px + kx, py + ky, 0xFFFFFF, 45);
                    }
                }
            }
        },
        .fog => {
            var q: i64 = 0;
            while (q < 3) : (q += 1) {
                const ly = y0 + @divTrunc((q + 1) * h, 4);
                var xx = x0;
                while (xx < x0 + w) : (xx += 1) {
                    if (@mod(xx + fi * 2 + q * 6, 12) < 7) {
                        putCardFx(c, r, xx, ly, tint & 0x00FFFFFF, 40);
                    }
                }
            }
        },
        .wind => {
            var i: i64 = 0;
            while (i < 6) : (i += 1) {
                const wy = y0 + @as(i64, @intFromFloat(fxHash01(i * 2 + 7) * fh));
                const sx = x0 + @mod(i * @divTrunc(w, 6) - fi * 4, w);
                var k: i64 = 0;
                while (k < 6) : (k += 1) {
                    putCardFx(c, r, sx + k, wy, tint & 0x00FFFFFF, 55);
                }
            }
        },
    }
}

// --- spawn helper (ported from the bar's spawnDetached) -------------------

const libc_proc = struct {
    // fork() is kept as a private helper inside std.c — bind it ourselves.
    extern "c" fn fork() c_int;
};

/// Runs `command` through `sh -c`, detached via the standard double-fork so
/// it survives us and doesn't leave a zombie.
pub fn spawnDetached(command: [:0]const u8) void {
    const pid = libc_proc.fork();
    if (pid < 0) return;
    if (pid == 0) {
        const pid2 = libc_proc.fork();
        if (pid2 == 0) {
            _ = std.c.setsid();
            var argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command.ptr, null };
            _ = std.c.execve("/bin/sh", &argv, std.c.environ);
            std.c._exit(127);
        }
        std.c._exit(0);
    }
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
}

// --- shared data-fetch plumbing ------------------------------------------
//
// Spawns a short-lived child (curl, playerctl) and captures its stdout over
// a pipe without blocking the main loop — the same PolledCommand pattern the
// bar uses for weather/pacman/mpris. `pending_fd` (when >= 0) is an fd in
// the host's poll() set; the widget calls onReadable when poll says it's
// readable.

fn setCloexec(fd: posix.fd_t) void {
    _ = std.c.fcntl(fd, 2, @as(c_int, 1)); // F_SETFD, FD_CLOEXEC
}

pub const Fetcher = struct {
    // Sized for the largest payload any widget pulls down: the calendar's
    // holiday JSON (a year of entries runs ~7 KB).
    read_buf: [10240]u8 = undefined,
    read_len: usize = 0,
    pending_fd: posix.fd_t = -1,
    // Perihelion: set at EOF, so a fetch that ended with no output can be told
    // apart from one still in flight (onReadable returns 0 for both).
    eof: bool = false,

    pub fn busy(self: *const Fetcher) bool {
        return self.pending_fd >= 0;
    }

    pub fn fd(self: *const Fetcher) posix.fd_t {
        return self.pending_fd;
    }

    /// Runs `argv` (execve-style) with its stdout piped to read_fd, which we
    /// keep. No-op while a previous fetch is still in flight.
    pub fn start(self: *Fetcher, path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) void {
        if (self.pending_fd >= 0) return;
        self.read_len = 0;
        self.eof = false;

        var pipe_fds: [2]posix.fd_t = undefined;
        if (std.c.pipe(&pipe_fds) != 0) return;
        const read_fd = pipe_fds[0];
        const write_fd = pipe_fds[1];
        setCloexec(read_fd);

        const pid = libc_proc.fork();
        if (pid < 0) {
            _ = posix.system.close(read_fd);
            _ = posix.system.close(write_fd);
            return;
        }
        if (pid == 0) {
            _ = std.c.dup2(write_fd, 1);
            _ = posix.system.close(write_fd);
            _ = posix.system.close(read_fd);
            _ = std.c.execve(path, argv, std.c.environ);
            std.c._exit(127);
        }
        _ = posix.system.close(write_fd);
        self.pending_fd = read_fd;
    }

    /// Call when poll() reports pending_fd readable. Returns how many bytes
    /// were copied into `out` once the fetch is complete (EOF), or 0 while
    /// still in flight.
    pub fn onReadable(self: *Fetcher, out: []u8) usize {
        var chunk: [256]u8 = undefined;
        const n = posix.read(self.pending_fd, &chunk) catch return 0;
        if (n == 0) {
            self.eof = true;
            const trimmed = std.mem.trim(u8, self.read_buf[0..self.read_len], " \t\r\n");
            const copy_len = @min(trimmed.len, out.len);
            @memcpy(out[0..copy_len], trimmed[0..copy_len]);
            return copy_len;
        }
        const copy_len = @min(n, self.read_buf.len - self.read_len);
        @memcpy(self.read_buf[self.read_len..][0..copy_len], chunk[0..copy_len]);
        self.read_len += copy_len;
        return 0;
    }

    pub fn closeFd(self: *Fetcher) void {
        _ = posix.system.close(self.pending_fd);
        self.pending_fd = -1;
    }
};

// --- clock ----------------------------------------------------------------

const libc_time = struct {
    extern "c" fn time(t: ?*i64) i64;
    extern "c" fn localtime_r(timer: *const i64, result: *Tm) ?*Tm;
    extern "c" fn mktime(tm: *Tm) i64;

    // Layout matches glibc's `struct tm` (tm_gmtoff/tm_zone tail is a glibc
    // extension, present on Linux x86_64).
    const Tm = extern struct {
        sec: c_int,
        min: c_int,
        hour: c_int,
        mday: c_int,
        mon: c_int,
        year: c_int,
        wday: c_int,
        yday: c_int,
        isdst: c_int,
        gmtoff: c_long,
        zone: ?[*:0]const u8,
    };
};

const DAYS = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const MONTHS = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const MONTHS_FULL = [_][]const u8{
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
};
const WD_ROW = [_][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };

// --- proleptic-Gregorian date math ----------------------------------------
//
// Pure integer conversions (Howard Hinnant's days_from_civil / civil_from_
// days): no timezone surprises, no mktime round-trips for calendar layout.
// mktime is still used where wall-clock matters (notification due times).

fn daysFromCivil(y: i32, m: u32, d: u32) i64 {
    const yy: i64 = y - @as(i32, if (m <= 2) 1 else 0);
    const era: i64 = @divFloor(yy, 400);
    const yoe: i64 = yy - era * 400; // [0, 399]
    const mp: i64 = if (m > 2) @as(i64, @intCast(m)) - 3 else @as(i64, @intCast(m)) + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + @as(i64, @intCast(d)) - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z0: i64) struct { y: i32, m: u8, d: u8 } {
    const z = z0 + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = @intCast(if (m <= 2) y + 1 else y), .m = @intCast(m), .d = @intCast(d) };
}

/// Weekday of an epoch day: 0 = Sunday (day 0 = 1970-01-01 = Thursday).
fn wdayOf(days: i64) u8 {
    return @intCast(@mod(days + 4, 7));
}

/// Monday-first column (0..6) for a Sunday-based weekday.
fn monCol(wd: u8) u8 {
    return @mod(wd + 6, 7);
}

fn daysInMonth(y: i32, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) 29 else 28,
        else => 30,
    };
}

const WEEKDAYS_FULL = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

/// Desktop clock. Style, 12/24-hour, seconds and date come from
/// clock_layout (shell.json clock_*). update() reports whether anything
/// shown changed, so without seconds the card repaints once a minute.
pub const ClockWidget = struct {
    hour: u8 = 0, // as shown: 0-23, or 1-12 in 12-hour mode
    min: u8 = 0,
    sec: u8 = 0,
    pm: bool = false,
    wday: u8 = 0,
    mday: u8 = 1,
    mon: u8 = 0,
    shown_key: u64 = 0,
    ready: bool = false,

    pub const interval_ms: i64 = 1000;

    /// Reads the time; true when the face would look different.
    pub fn update(self: *ClockWidget) bool {
        const L = clock_layout;
        const now = libc_time.time(null);
        var tm: libc_time.Tm = undefined;
        _ = libc_time.localtime_r(&now, &tm);
        var h: u8 = @intCast(tm.hour);
        var pm = false;
        if (!L.h24) {
            pm = h >= 12;
            h %= 12;
            if (h == 0) h = 12;
        }
        self.hour = h;
        self.min = @intCast(tm.min);
        self.sec = @intCast(@min(tm.sec, 59)); // leap second shows as :59
        self.pm = pm;
        self.wday = @intCast(@mod(tm.wday, 7));
        self.mday = @intCast(tm.mday);
        self.mon = @intCast(@mod(tm.mon, 12));
        var key: u64 = @as(u64, h) * 60 + self.min;
        key = key * 60 + (if (L.seconds) @as(u64, self.sec) else 0);
        key = key * 2 + @intFromBool(pm);
        key = ((key * 7 + self.wday) * 32 + self.mday) * 12 + self.mon;
        const changed = !self.ready or key != self.shown_key;
        self.shown_key = key;
        self.ready = true;
        return changed;
    }

    fn timeText(self: *const ClockWidget, out: []u8) []const u8 {
        return if (clock_layout.h24)
            std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}", .{ self.hour, self.min }) catch ""
        else
            std.fmt.bufPrint(out, "{d}:{d:0>2}", .{ self.hour, self.min }) catch "";
    }

    fn ampm(self: *const ClockWidget) []const u8 {
        return if (self.pm) "PM" else "AM";
    }

    pub fn paint(self: *const ClockWidget, c: Canvas, r: Rect) void {
        switch (clock_layout.style) {
            .classic => self.paintClassic(c, r),
            .digital => self.paintDigital(c, r),
            .flip => self.paintFlip(c, r),
            .stacked => self.paintStacked(c, r),
        }
    }

    /// Weekday in the accent, then the rest dimmed: "Wednesday, Nov 18".
    fn drawDate(self: *const ClockWidget, c: Canvas, x: i64, baseline: i64, full_weekday: bool) void {
        const text_col = c.theme.text_color;
        const wd = if (full_weekday) WEEKDAYS_FULL[self.wday] else DAYS[self.wday];
        const w = c.drawText(x, baseline, wd, c.theme.border_color);
        var db: [24]u8 = undefined;
        const rest = std.fmt.bufPrint(&db, ", {s} {d}", .{ MONTHS[self.mon], self.mday }) catch "";
        _ = c.drawText(x + w, baseline, rest, dim(text_col, 0xBB));
    }

    fn paintClassic(self: *const ClockWidget, c: Canvas, r: Rect) void {
        const L = clock_layout;
        const pad = c.zx(CARD_PAD);
        const padx: i64 = r.x + pad;
        const b1 = r.y + pad + c.font.ascentPx();
        var tb: [16]u8 = undefined;
        var mb: [32]u8 = undefined;
        var sb: [4]u8 = undefined;
        const secs = if (L.seconds) (std.fmt.bufPrint(&sb, ":{d:0>2}", .{self.sec}) catch "") else "";
        const t = std.fmt.bufPrint(&mb, "{s}{s}{s}{s}", .{
            self.timeText(&tb),
            secs,
            if (L.h24) "" else " ",
            if (L.h24) "" else self.ampm(),
        }) catch "";
        _ = c.drawText(padx, b1, t, c.theme.text_color);
        if (L.date) {
            var db: [24]u8 = undefined;
            const sub = std.fmt.bufPrint(&db, "{s} {d} {s}", .{ DAYS[self.wday], self.mday, MONTHS[self.mon] }) catch "";
            _ = c.drawText(padx, b1 + lineH(c.font) + c.zx(ROW_GAP), sub, dim(c.theme.text_color, 0xCC));
        }
    }

    fn paintDigital(self: *const ClockWidget, c: Canvas, r: Rect) void {
        const L = clock_layout;
        const pad = c.zx(CARD_PAD);
        const left: i64 = r.x + pad;
        const top: i64 = r.y + pad;
        const asc: i64 = c.font.ascentPx();
        const text_col = c.theme.text_color;
        var tb: [16]u8 = undefined;
        const b_big = top + 2 * asc;
        var x = left + drawScaledText(c, left, b_big, self.timeText(&tb), 2, text_col);
        if (L.seconds) {
            var sb: [8]u8 = undefined;
            x += c.zx(4) + c.drawText(x + c.zx(4), b_big, std.fmt.bufPrint(&sb, ":{d:0>2}", .{self.sec}) catch "", dim(text_col, 0x99));
        }
        if (!L.h24) _ = c.drawText(x + c.zx(6), b_big, self.ampm(), c.theme.border_color);
        if (L.date) self.drawDate(c, left, b_big + c.zx(ROW_GAP) + asc, true);
    }

    fn paintFlip(self: *const ClockWidget, c: Canvas, r: Rect) void {
        const L = clock_layout;
        const pad = c.zx(CARD_PAD);
        const left: i64 = r.x + pad;
        const top: i64 = r.y + pad;
        const asc: i64 = c.font.ascentPx();
        const text_col = c.theme.text_color;
        const accent = c.theme.border_color;
        const cell = c.textWidth("0");
        const tile_w = 2 * cell + c.zx(12);
        const tile_h = 2 * asc + c.zx(8);
        const fill = (c.theme.hover_color & 0x00FFFFFF) | 0xC0000000;
        const edge = dim(text_col, 0x22);
        const split = dim(c.theme.bg_color, 0x99);
        var digits: [4]u8 = undefined;
        digits[0] = '0' + self.hour / 10;
        digits[1] = '0' + self.hour % 10;
        digits[2] = '0' + self.min / 10;
        digits[3] = '0' + self.min % 10;
        var x = left;
        for (digits, 0..) |d, i| {
            if (i == 2) {
                // Colon: two dots between the hour and minute pairs.
                const ccx: f64 = @floatFromInt(x + @divTrunc(c.zx(FLIP_COLON_W), 2));
                const rad: f64 = @floatFromInt(@max(c.zx(2), 1));
                c.fillCircleAA(ccx, @as(f64, @floatFromInt(top)) + @as(f64, @floatFromInt(tile_h)) * 0.35, rad, accent);
                c.fillCircleAA(ccx, @as(f64, @floatFromInt(top)) + @as(f64, @floatFromInt(tile_h)) * 0.65, rad, accent);
                x += c.zx(FLIP_COLON_W);
            }
            // 12-hour times have no leading zero: an empty first tile.
            const blank = i == 0 and !L.h24 and d == '0';
            c.card(.{ .x = @intCast(x), .y = @intCast(top), .w = @intCast(tile_w), .h = @intCast(tile_h) }, fill, edge);
            if (!blank) {
                const one = [1]u8{d};
                _ = drawScaledText(c, x + @divTrunc(tile_w - 2 * cell, 2), top + c.zx(4) + 2 * asc, &one, 2, accent);
            }
            c.fillRect(x, top + @divTrunc(tile_h, 2), @intCast(tile_w), 1, split);
            x += tile_w + (if (i == 1) 0 else c.zx(FLIP_TILE_GAP));
        }
        // Seconds (small, bottom) and AM/PM (top) beside the tiles.
        const sx = x + c.zx(FLIP_SIDE_GAP);
        if (!L.h24) _ = c.drawText(sx, top + asc + c.zx(2), self.ampm(), accent);
        if (L.seconds) {
            var sb: [4]u8 = undefined;
            _ = c.drawText(sx, top + tile_h - c.zx(4), std.fmt.bufPrint(&sb, "{d:0>2}", .{self.sec}) catch "", dim(text_col, 0x99));
        }
        if (L.date) self.drawDate(c, left, top + tile_h + c.zx(ROW_GAP) + asc, true);
    }

    fn paintStacked(self: *const ClockWidget, c: Canvas, r: Rect) void {
        const L = clock_layout;
        const pad = c.zx(CARD_PAD);
        const left: i64 = r.x + pad;
        const top: i64 = r.y + pad;
        const lh = lineH(c.font);
        const asc: i64 = c.font.ascentPx();
        const text_col = c.theme.text_color;
        const accent = c.theme.border_color;
        var hb: [4]u8 = undefined;
        var mb: [4]u8 = undefined;
        const hs = (if (L.h24) std.fmt.bufPrint(&hb, "{d:0>2}", .{self.hour}) else std.fmt.bufPrint(&hb, "{d}", .{self.hour})) catch "";
        const ms = std.fmt.bufPrint(&mb, "{d:0>2}", .{self.min}) catch "";
        const b1 = top + 3 * asc;
        const b2 = b1 + 3 * asc + c.zx(STACK_GAP);
        const w1 = drawScaledText(c, left, b1, hs, 3, accent);
        const w2 = drawScaledText(c, left, b2, ms, 3, text_col);
        // The side column: weekday, month/day, then seconds and AM/PM.
        const col = left + @max(w1, w2) + c.zx(STACK_COL_GAP);
        var y = top + asc + c.zx(2);
        if (L.date) {
            _ = c.drawText(col, y, WEEKDAYS_FULL[self.wday], accent);
            y += lh + c.zx(ROW_GAP);
            var db: [16]u8 = undefined;
            _ = c.drawText(col, y, std.fmt.bufPrint(&db, "{s} {d}", .{ MONTHS_FULL[self.mon], self.mday }) catch "", dim(text_col, 0xBB));
            y += lh + c.zx(ROW_GAP);
        }
        var sb: [4]u8 = undefined;
        var eb: [12]u8 = undefined;
        const extra = std.fmt.bufPrint(&eb, "{s}{s}{s}", .{
            if (L.seconds) (std.fmt.bufPrint(&sb, ":{d:0>2}", .{self.sec}) catch "") else "",
            if (L.seconds and !L.h24) " " else "",
            if (!L.h24) self.ampm() else "",
        }) catch "";
        if (extra.len > 0) _ = c.drawText(col, y, extra, dim(text_col, 0x99));
    }

    pub fn click(self: *const ClockWidget) void {
        _ = self;
    }
};

// --- weather --------------------------------------------------------------
//
// The data side lives in weather.zig (Open-Meteo, location resolution,
// refresh/retry schedule, the answer cache shared with the bar's weather
// indicator); this is just the card. Same fetch plumbing as the
// other cards: one curl child at a time over a Fetcher pipe in the host's
// poll set.

/// Text drawn at an integer multiple of the font size, baseline-aligned —
/// the big temperature. Each glyph is rasterized uncached (glyphScaled), so
/// keep it to a few characters.
fn drawScaledText(c: Canvas, x: i64, baseline: i64, text: []const u8, scale: u32, color: u32) i64 {
    if (scale <= 1) return c.drawText(x, baseline, text, color);
    var pen = x;
    var i: usize = 0;
    while (nextUtf8Codepoint(text, &i)) |cp| {
        const g = c.font.glyphScaled(cp, scale) catch continue;
        defer c.font.gpa.free(g.pixels);
        _ = drawBigIcon(c, pen, baseline - g.bitmap_top, &g, color);
        pen += g.advance_x;
    }
    return pen - x;
}

fn drawRight(c: Canvas, right_x: i64, baseline: i64, text: []const u8, color: u32) void {
    _ = c.drawText(right_x - c.textWidth(text), baseline, text, color);
}

fn drawCentered(c: Canvas, center_x: i64, baseline: i64, text: []const u8, color: u32) void {
    _ = c.drawText(center_x - @divTrunc(c.textWidth(text), 2), baseline, text, color);
}

/// Non-blocking readiness check for one fetch pipe. The host calls every
/// widget's onPipe when *any* pipe is ready, and Fetcher.onReadable does a
/// blocking read — without this a slow curl would stall the whole loop.
fn fdReadable(fd: posix.fd_t) bool {
    if (fd < 0) return false;
    var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&pfd, 0) catch return false;
    return n > 0 and (pfd[0].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0;
}

const RAIN_BLUE: u32 = 0xFF4AA8FF;

/// What a click on the Weather card does (shell.json weather_click).
pub const WeatherClick = enum {
    /// Open the full forecast for the place in the browser: weather.gov in
    /// the US, Windy elsewhere.
    forecast,
    /// Switch °C/°F (saved as weather_units; the bar follows).
    units,

    pub fn parse(s: []const u8) ?WeatherClick {
        if (std.ascii.eqlIgnoreCase(s, "forecast")) return .forecast;
        if (std.ascii.eqlIgnoreCase(s, "units")) return .units;
        return null;
    }
};
/// Set by the host from shell.json before the cards start.
pub var weather_click: WeatherClick = .forecast;

pub const WeatherWidget = struct {
    svc: wsvc.Service = .{},
    fetch: Fetcher = .{},
    anim_frame: u32 = 0,
    /// Set by a click (°C/°F toggle); the host persists the new unit to
    /// shell.json and clears it.
    units_changed: bool = false,

    /// curl through sh so PATH finds it. The URL arrives as $1 and is never
    /// spliced into the script, so no character in it can break quoting.
    /// --fail keeps HTTP error pages off stdout: an empty answer is a failed
    /// attempt, which weather.zig's retry schedule handles.
    const CURL_CMD =
        "exec curl -sS --fail --compressed --connect-timeout 5 --max-time 10 " ++
        "-A perihelion-shell -H 'Accept: application/json' --url \"$1\"";

    pub fn configure(self: *WeatherWidget, cfg: wsvc.Config) void {
        self.svc = wsvc.Service.init(cfg);
    }

    fn fxKind(self: *const WeatherWidget) WeatherFx {
        if (!self.svc.data.available) return .none;
        return fxForKind(wsvc.kindFor(self.svc.data.w_code));
    }

    /// Moving conditions repaint at 60 ms; clear skies (a static glow),
    /// unknown codes and the no-data states settle at 1 s, which is still
    /// plenty for the fetch schedule.
    pub fn animating(self: *const WeatherWidget) bool {
        const k = self.fxKind();
        return k != .none and k != .clear;
    }

    /// Starts the next request weather.zig asks for, if any is due.
    pub fn pump(self: *WeatherWidget, now: i64) void {
        if (self.fetch.busy()) return;
        const url = self.svc.poll(now) orelse return;
        var argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", CURL_CMD, "perihelion-weather", url.ptr, null };
        self.fetch.start("/bin/sh", &argv);
        // pipe()/fork() failed: count it as a failed attempt so the retry
        // schedule runs instead of a request stuck "in flight" forever.
        if (!self.fetch.busy()) self.svc.complete("", now);
    }

    /// Call when a fetch pipe may be readable. Returns true when a fetch
    /// finished (the snapshot or status may have changed).
    pub fn onPipe(self: *WeatherWidget) bool {
        if (!self.fetch.busy() or !fdReadable(self.fetch.fd())) return false;
        var out: [10240]u8 = undefined;
        const n = self.fetch.onReadable(&out);
        if (n == 0 and !self.fetch.eof) return false;
        self.fetch.closeFd();
        self.svc.complete(out[0..n], monoMs());
        return true;
    }

    /// A click opens the forecast page, or (weather_click "units") toggles
    /// °C/°F, which the host saves as shell.json weather_units.
    pub fn click(self: *WeatherWidget) void {
        switch (weather_click) {
            .units => {
                self.svc.units = self.svc.units.toggled();
                self.units_changed = true;
            },
            .forecast => {
                var ub: [160]u8 = undefined;
                const url = self.svc.forecastUrl(&ub) orelse return; // place not known yet
                var cb: [200]u8 = undefined;
                // The URL is digits, letters and URL punctuation only (no
                // quote), so single quotes keep it one argument.
                const cmd = std.fmt.bufPrintZ(&cb, "exec xdg-open '{s}'", .{url}) catch return;
                spawnDetached(cmd);
            },
        }
    }

    pub fn paint(self: *const WeatherWidget, c: Canvas, r: Rect) void {
        const lh = lineH(c.font);
        const pad = c.zx(CARD_PAD);
        const rg = c.zx(ROW_GAP);
        const asc: i64 = c.font.ascentPx();
        const left: i64 = r.x + pad;
        const right: i64 = r.x + @as(i64, @intCast(r.w)) - pad;
        const top: i64 = r.y + pad;
        const text_col = c.theme.text_color;
        // One baseline per header line; the big temperature spans 1-2.
        const b1 = top + asc;
        const b2 = b1 + lh + rg;
        const b3 = b2 + lh + rg;
        const b4 = b3 + lh + rg;
        const d = &self.svc.data;
        const units = self.svc.units;

        if (!d.available) {
            const msg: [2][]const u8 = switch (self.svc.status()) {
                .locating => .{ "Weather", "Finding your location\u{2026}" },
                .no_location => .{ "Weather", "Set a location in shell.json" },
                .city_not_found => .{ "Weather", "City not found" },
                .fetching, .waiting, .ready => if (d.loading)
                    .{ "Weather", "Loading forecast\u{2026}" }
                else
                    .{ "Weather unavailable", "Retrying shortly" },
            };
            var fit_buf: [72]u8 = undefined;
            _ = c.drawText(left, b1, msg[0], text_col);
            _ = c.drawText(left, b2, fitText(c, msg[1], right - left, &fit_buf), dim(text_col, 0xAA));
            return;
        }

        const kind = wsvc.kindFor(d.w_code);
        const tint_raw = wsvc.tintFor(d.w_code, d.is_day);
        const tint = if (tint_raw != 0) tint_raw else text_col;
        const icon_cp = wsvc.iconFor(d.w_code, d.is_day);
        const head_h = 4 * lh + 3 * rg;

        // Condition icon: the left column, centered on the header. The
        // raster steps down from 4x until it fits, then 1x text as a last
        // resort, so an oversized glyph never breaks the card.
        var text_x = left;
        var si: u32 = @max(2, @as(u32, @intFromFloat(@round(4.0 * c.zoom))));
        var drew = false;
        while (si >= 2 and !drew) : (si -= 1) {
            const big = c.font.glyphScaled(icon_cp, si) catch continue;
            defer c.font.gpa.free(big.pixels);
            if (@as(i64, big.height) > head_h) continue;
            const iy = top + @divTrunc(head_h - @as(i64, big.height), 2);
            // Clear days get the warm halo behind the sun.
            if (kind == .clear and d.is_day) {
                const ir: i64 = @max(@as(i64, big.width), @as(i64, big.height));
                drawSunGlow(c, r, left + @divTrunc(@as(i64, big.width), 2), iy + @divTrunc(@as(i64, big.height), 2), @divTrunc(ir, 2) + c.zx(10));
            }
            text_x += drawBigIcon(c, left, iy, &big, tint) + c.zx(10);
            drew = true;
        }
        if (!drew) {
            var ib: [4]u8 = undefined;
            const il = utf8Encode(icon_cp, &ib);
            text_x += c.drawText(left, b2, ib[0..il], tint) + c.zx(8);
        }

        // Lines 1-2: big temperature; feels-like and humidity · wind
        // right-aligned beside it when there's room.
        var tbuf: [16]u8 = undefined;
        const temp_s = std.fmt.bufPrint(&tbuf, "{d}\u{00B0}", .{wsvc.roundi(d.temp(units))}) catch "";
        const temp_w = drawScaledText(c, text_x, b2, temp_s, 2, text_col);
        var lb: [80]u8 = undefined;
        var fb: [96]u8 = undefined;
        const avail = right - (text_x + temp_w + c.zx(10));
        if (avail > c.zx(30)) {
            const feels = std.fmt.bufPrint(&lb, "Feels {d}\u{00B0}", .{wsvc.roundi(d.feelsLike(units))}) catch "";
            drawRight(c, right, b1, fitText(c, feels, avail, &fb), dim(text_col, 0xCC));
            var wb: [16]u8 = undefined;
            const wind_s = d.windText(units, &wb);
            const hw = std.fmt.bufPrint(&lb, "{d}% \u{00B7} {s}", .{ d.humidity, wind_s }) catch "";
            drawRight(c, right, b2, fitText(c, hw, avail, &fb), dim(text_col, 0x99));
        }

        // Line 3: condition; chance of rain (or "offline" when the last
        // refresh failed) on the right.
        var right3_w: i64 = 0;
        if (d.stale) {
            const s = "offline";
            right3_w = c.textWidth(s);
            drawRight(c, right, b3, s, dim(text_col, 0x88));
        } else if (d.precip_prob > 0) {
            var pb: [16]u8 = undefined;
            const p = std.fmt.bufPrint(&pb, "\u{E371} {d}%", .{d.precip_prob}) catch "";
            right3_w = c.textWidth(p);
            drawRight(c, right, b3, p, dim(RAIN_BLUE, 0xDD));
        }
        var cb: [64]u8 = undefined;
        const cond = wsvc.conditionText(d.w_code);
        _ = c.drawText(text_x, b3, fitText(c, cond, right - text_x - right3_w - c.zx(8), &cb), dim(text_col, 0xDD));

        // Line 4: place; next sunset (day) or sunrise (night) on the right.
        var sb: [24]u8 = undefined;
        var sun_w: i64 = 0;
        if (d.nextSunEvent()) |ev| {
            const glyph: []const u8 = if (ev.sunrise) "\u{E34C}" else "\u{E34D}";
            const s = std.fmt.bufPrint(&sb, "{s} {s}", .{ glyph, ev.at }) catch "";
            sun_w = c.textWidth(s);
            drawRight(c, right, b4, s, dim(text_col, 0x99));
        }
        var pl: [64]u8 = undefined;
        const place: []const u8 = if (d.city.len > 0) d.city.slice() else "\u{2014}";
        _ = c.drawText(text_x, b4, fitText(c, place, right - text_x - sun_w - c.zx(8), &pl), dim(text_col, 0xBB));

        // Forecast strip under a hairline: day, icon (+ rain chance), high, low.
        const head_bottom = top + head_h;
        const strip_gap = c.zx(WX_STRIP_GAP);
        const inner_w = right - left;
        if (inner_w > 0) {
            c.fillRect(left, head_bottom + @divTrunc(strip_gap, 2), @intCast(inner_w), 1, dim(text_col, 0x26));
        }
        const days = d.days();
        if (days.len > 0 and inner_w > 0) {
            const col_min = @max(c.zx(WX_COL_MIN), 1);
            const fit_cols: usize = @intCast(std.math.clamp(@divTrunc(inner_w, col_min), 1, @as(i64, wsvc.FORECAST_DAYS)));
            const ncols = @min(fit_cols, days.len);
            const col_w = @divTrunc(inner_w, @as(i64, @intCast(ncols)));
            const srg = c.zx(WX_STRIP_ROW_GAP);
            const s1 = head_bottom + strip_gap + asc;
            const s2 = s1 + lh + srg;
            const s3 = s2 + lh + srg;
            const s4 = s3 + lh + srg;
            const gap = c.zx(4);
            for (days[0..ncols], 0..) |*day, i| {
                const cx = left + col_w * @as(i64, @intCast(i)) + @divTrunc(col_w, 2);
                const label: []const u8 = if (i == 0) "Today" else day.day_name.slice();
                drawCentered(c, cx, s1, label, if (i == 0) text_col else dim(text_col, 0xAA));

                var ib: [4]u8 = undefined;
                const il = utf8Encode(wsvc.iconFor(day.w_code, true), &ib);
                const dtint_raw = wsvc.tintFor(day.w_code, true);
                const dtint = if (dtint_raw != 0) dtint_raw else text_col;
                if (day.precip_prob >= 10) {
                    var pb: [8]u8 = undefined;
                    const p = std.fmt.bufPrint(&pb, "{d}%", .{day.precip_prob}) catch "";
                    const iw = c.textWidth(ib[0..il]);
                    const x0 = cx - @divTrunc(iw + gap + c.textWidth(p), 2);
                    _ = c.drawText(x0, s2, ib[0..il], dtint);
                    _ = c.drawText(x0 + iw + gap, s2, p, dim(RAIN_BLUE, 0xCC));
                } else {
                    drawCentered(c, cx, s2, ib[0..il], dtint);
                }

                var hb: [12]u8 = undefined;
                var lob: [12]u8 = undefined;
                const hi = std.fmt.bufPrint(&hb, "{d}\u{00B0}", .{wsvc.roundi(day.max(units))}) catch "";
                const lo = std.fmt.bufPrint(&lob, "{d}\u{00B0}", .{wsvc.roundi(day.min(units))}) catch "";
                drawCentered(c, cx, s3, hi, text_col);
                drawCentered(c, cx, s4, lo, dim(text_col, 0x88));
            }
        }

        // Condition animation over the whole card, driven by the union
        // tick's anim_frame.
        const fx = fxForKind(kind);
        if (fx != .none) drawWeatherFxCard(c, r, fx, self.anim_frame, tint);
    }
};

// --- fastfetch ---------------------------------------------------------------
//
// The data side is fastfetch.zig (which binary, if any; native fallback;
// logo). The card draws fastfetch's classic shape: logo on the left, then
// "user@host", a rule, Key: value rows and a row of palette dots — all in
// matugen colours (logo $1 = accent, $2 = second accent; keys in the accent).

/// One fastfetch logo line with its $N colour markers; returns its width.
fn drawLogoLine(c: Canvas, x: i64, baseline: i64, line: []const u8, palette: [4]u32) i64 {
    var pen = x;
    var color = palette[0]; // fastfetch starts in colour 1
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '$' and i + 1 < line.len and std.ascii.isDigit(line[i + 1])) {
            if (i > seg_start) pen += c.drawText(pen, baseline, line[seg_start..i], color);
            const n: usize = line[i + 1] - '0'; // '0'..'9'
            color = if (n >= 1 and n <= palette.len) palette[n - 1] else palette[palette.len - 1];
            i += 2;
            seg_start = i;
            continue;
        }
        i += 1;
    }
    if (line.len > seg_start) pen += c.drawText(pen, baseline, line[seg_start..], color);
    return pen - x;
}

pub const FastfetchWidget = struct {
    svc: ffsvc.Service = .{},
    /// The fastfetch child, when a binary is in use (one run per refresh).
    fetch: Fetcher = .{},

    /// Due checks only; the card repaints when tick() reports a change.
    pub const interval_ms: i64 = 1000;

    pub fn configure(self: *FastfetchWidget, svc: *const ffsvc.Service) void {
        self.svc = svc.*;
    }

    pub fn tick(self: *FastfetchWidget) bool {
        const now = monoMs();
        const changed = self.svc.tick(now);
        self.pump(now);
        return changed;
    }

    fn pump(self: *FastfetchWidget, now: i64) void {
        if (self.fetch.busy() or !self.svc.wantRun(now)) return;
        // Config layout: $1 = the derived copy of the user's config;
        // fields layout: $1 = the module list (see fastfetch.zig).
        var argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", self.svc.runScript().ptr, self.svc.binZ().ptr, self.svc.runArgZ().ptr, null };
        self.fetch.start("/bin/sh", &argv);
        if (!self.fetch.busy()) _ = self.svc.runComplete("", now);
    }

    pub fn onPipe(self: *FastfetchWidget) bool {
        if (!self.fetch.busy() or !fdReadable(self.fetch.fd())) return false;
        var out: [10240]u8 = undefined;
        const n = self.fetch.onReadable(&out);
        if (n == 0 and !self.fetch.eof) return false;
        self.fetch.closeFd();
        return self.svc.runComplete(out[0..n], monoMs());
    }

    pub fn paint(self: *const FastfetchWidget, c: Canvas, r: Rect) void {
        const s = &self.svc;
        const lh = lineH(c.font);
        const pad = c.zx(CARD_PAD);
        const rg = c.zx(FF_ROW_GAP);
        const asc: i64 = c.font.ascentPx();
        const top: i64 = r.y + pad;
        const left: i64 = r.x + pad;
        const right: i64 = r.x + @as(i64, @intCast(r.w)) - pad;
        const text_col = c.theme.text_color;
        const accent = c.theme.border_color;
        const accent2 = c.theme.accent2_color;

        // Logo column.
        var text_x = left;
        if (!s.logo_off) {
            if (s.logo_count > 0) {
                const palette = [4]u32{ accent, accent2, c.theme.holiday_color, text_col };
                var widest: i64 = 0;
                var y = top + asc;
                for (s.logoLines()) |*line| {
                    widest = @max(widest, drawLogoLine(c, left, y, line.slice(), palette));
                    y += lh;
                }
                text_x = left + widest + c.zx(FF_LOGO_GAP);
            } else {
                // No text logo: the distro's glyph, as large as fits.
                const box = c.zx(FF_GLYPH_W);
                const cp = ffsvc.distroGlyph(s.distro_id.slice());
                var si: u32 = @max(2, @as(u32, @intFromFloat(@round(6.0 * c.zoom))));
                while (si >= 2) : (si -= 1) {
                    const big = c.font.glyphScaled(cp, si) catch continue;
                    defer c.font.gpa.free(big.pixels);
                    if (@as(i64, big.width) > box or @as(i64, big.height) > box) continue;
                    const gx = left + @divTrunc(box - @as(i64, big.width), 2) - big.bitmap_left;
                    _ = drawBigIcon(c, gx, top + @divTrunc(box - @as(i64, big.height), 2), &big, accent);
                    break;
                }
                text_x = left + box + c.zx(FF_LOGO_GAP);
            }
        }
        const avail = right - text_x;
        if (avail <= 0) return;

        // "user@host", with the rule fastfetch draws under it.
        var b = top + asc;
        const title = s.title.slice();
        var tw: i64 = 0;
        if (std.mem.indexOfScalar(u8, title, '@')) |at| {
            tw += c.drawText(text_x, b, title[0..at], accent);
            tw += c.drawText(text_x + tw, b, "@", text_col);
            tw += c.drawText(text_x + tw, b, title[at + 1 ..], accent);
        } else {
            tw = c.drawText(text_x, b, title, accent);
        }
        b += lh + rg;
        c.fillRect(text_x, b - asc + @divTrunc(lh, 2), @intCast(@max(@min(tw, avail), 1)), 1, dim(text_col, 0x55));
        b += lh + rg;

        var fit_buf: [140]u8 = undefined;
        if (s.layout == .config) {
            // The user's fastfetch config: its sections as headers with a
            // hairline (the terminal's boxes), its keys (icon + words, no
            // tree prefix) aligned in one column, "break" as a half gap.
            var label_w: i64 = 0;
            for (s.cardRows()) |*row| {
                if (row.kind == .row) label_w = @max(label_w, c.textWidth(row.label.slice()));
            }
            const val_x = text_x + label_w + c.zx(FF_LABEL_GAP);
            for (s.cardRows()) |*row| {
                switch (row.kind) {
                    .spacer => b += @divTrunc(lh, 2),
                    .header => {
                        const hw = c.drawText(text_x, b, fitText(c, row.label.slice(), avail, &fit_buf), accent2);
                        const lx = text_x + hw + c.zx(8);
                        if (right - lx > c.zx(8)) {
                            c.fillRect(lx, b - @divTrunc(asc, 3), @intCast(right - lx), 1, dim(accent2, 0x66));
                        }
                        b += lh + rg;
                    },
                    .row => {
                        _ = c.drawText(text_x, b, row.label.slice(), accent);
                        if (row.value.len > 0) {
                            _ = c.drawText(val_x, b, fitText(c, row.value.slice(), right - val_x, &fit_buf), text_col);
                        } else {
                            _ = c.drawText(val_x, b, "\u{2014}", dim(text_col, 0x66));
                        }
                        b += lh + rg;
                    },
                }
            }
        } else {
            // Fields layout: fastfetch's default keys, aligned.
            var label_w: i64 = 0;
            for (s.shownFields()) |f| label_w = @max(label_w, c.textWidth(f.label()));
            const val_x = text_x + label_w + c.zx(FF_LABEL_GAP);
            for (s.shownFields()) |f| {
                _ = c.drawText(text_x, b, f.label(), accent);
                const v = s.value(f);
                if (v.len > 0) {
                    _ = c.drawText(val_x, b, fitText(c, v, right - val_x, &fit_buf), text_col);
                } else {
                    _ = c.drawText(val_x, b, "\u{2014}", dim(text_col, 0x66));
                }
                b += lh + rg;
            }
        }

        // Palette dots, where the config ends on its colours module
        // (Perihelion's does); always in the fields layout.
        if (s.palette) {
            const dots = [_]u32{ accent, accent2, c.theme.holiday_color, c.theme.hover_color, dim(text_col, 0x99), text_col };
            var dx = text_x;
            for (dots) |col| {
                dx += c.drawText(dx, b, "\u{25CF}", col) + c.zx(6);
            }
        }
    }
};

// --- processes -----------------------------------------------------------------
//
// The data side is procs.zig (one /proc pass per interval, CPU from tick
// deltas, resident memory). Read-only: the card lists, it never acts on a
// process. A click switches between CPU and memory order (saved as
// processes_sort).

pub const ProcessesWidget = struct {
    svc: psvc.Service = .{},
    /// Set by a click; the host saves processes_sort and clears it.
    sort_changed: bool = false,

    /// Due checks only; procs.zig samples on its own interval and the
    /// card repaints when tick() reports a change.
    pub const interval_ms: i64 = 1000;

    pub fn configure(self: *ProcessesWidget, cfg: psvc.Config) void {
        self.svc = psvc.Service.init(cfg);
    }

    pub fn tick(self: *ProcessesWidget) bool {
        return self.svc.tick(monoMs());
    }

    pub fn click(self: *ProcessesWidget) void {
        self.svc.toggleSort();
        self.sort_changed = true;
        _ = self.svc.tick(monoMs()); // re-rank now (CPU needs its next sample)
    }

    pub fn paint(self: *const ProcessesWidget, c: Canvas, r: Rect) void {
        const s = &self.svc;
        const lh = lineH(c.font);
        const pad = c.zx(CARD_PAD);
        const asc: i64 = c.font.ascentPx();
        const left: i64 = r.x + pad;
        const right: i64 = r.x + @as(i64, @intCast(r.w)) - pad;
        const top: i64 = r.y + pad;
        const text_col = c.theme.text_color;
        const accent = c.theme.border_color;

        var b = top + asc;
        _ = c.drawText(left, b, "Processes", text_col);
        drawRight(c, right, b, if (s.sort == .cpu) "by CPU" else "by memory", accent);
        b += lh + c.zx(PROC_HEAD_GAP);
        if (!s.ready()) {
            _ = c.drawText(left, b, "Measuring\u{2026}", dim(text_col, 0x88));
            return;
        }
        const row_pitch = lh + c.zx(PROC_ROW_GAP) + c.zx(PROC_BAR_H) + c.zx(2);
        const track = dim(text_col, 0x18);
        const fill = dim(accent, 0xCC);
        var vb: [24]u8 = undefined;
        var nb: [72]u8 = undefined;
        var fit_buf: [80]u8 = undefined;
        for (s.shown()) |*p| {
            const v = if (s.sort == .cpu) psvc.fmtCpu(&vb, p.cpu_x10) else psvc.fmtMem(&vb, p.rss);
            const vw = c.textWidth(v);
            drawRight(c, right, b, v, dim(text_col, 0xCC));
            const name = if (p.count > 1)
                (std.fmt.bufPrint(&nb, "{s} \u{00D7}{d}", .{ p.name.slice(), p.count }) catch p.name.slice())
            else
                p.name.slice();
            _ = c.drawText(left, b, fitText(c, name, right - left - vw - c.zx(10), &fit_buf), text_col);
            // Thin bar: share of one CPU, or of total memory.
            const frac: f64 = if (s.sort == .cpu)
                @min(@as(f64, @floatFromInt(p.cpu_x10)) / 1000.0, 1.0)
            else if (s.mem_total > 0)
                @min(@as(f64, @floatFromInt(p.rss)) / @as(f64, @floatFromInt(s.mem_total)), 1.0)
            else
                0.0;
            const by = b + c.zx(PROC_ROW_GAP) + @max(lh - asc, 0) - c.zx(1);
            const bw = right - left;
            c.fillRect(left, by, @intCast(@max(bw, 0)), @intCast(c.zx(PROC_BAR_H)), track);
            const fw: i64 = @intFromFloat(@round(@as(f64, @floatFromInt(bw)) * frac));
            if (fw > 0) c.fillRect(left, by, @intCast(fw), @intCast(c.zx(PROC_BAR_H)), fill);
            b += row_pitch;
        }
    }
};

/// Download/upload rates of the physical interfaces (netrate.zig), with a
/// graph of the last samples: download in the accent colour, upload in
/// the dimmed text colour, both scaled to the busiest kept sample.
pub const NetworkWidget = struct {
    svc: nsvc.Service = .{},

    /// Due checks only; netrate.zig samples on its own interval.
    pub const interval_ms: i64 = 1000;

    pub fn configure(self: *NetworkWidget, cfg: nsvc.Config) void {
        self.svc = nsvc.Service.init(cfg);
    }

    pub fn tick(self: *NetworkWidget) bool {
        return self.svc.tick(monoMs());
    }

    pub fn paint(self: *const NetworkWidget, c: Canvas, r: Rect) void {
        const s = &self.svc;
        const lh = lineH(c.font);
        const pad = c.zx(CARD_PAD);
        const asc: i64 = c.font.ascentPx();
        const left: i64 = r.x + pad;
        const right: i64 = r.x + @as(i64, @intCast(r.w)) - pad;
        const text_col = c.theme.text_color;
        const accent = c.theme.border_color;

        var b = r.y + pad + asc;
        _ = c.drawText(left, b, "Network", text_col);
        if (s.ifaces == 0) {
            drawRight(c, right, b, "offline", dim(text_col, 0x88));
        }
        var y = r.y + pad + lh + c.zx(NET_GAP);

        if (network_graph) {
            const gh = c.zx(NET_GRAPH_H);
            const gw = right - left;
            // Faint baseline so an idle link still reads as a graph.
            c.fillRect(left, y + gh - 1, @intCast(@max(gw, 0)), 1, dim(text_col, 0x22));
            if (s.hist_len >= 2 and gw > 0) {
                // Scale: the busiest kept sample, at least 1 KB/s so a
                // trickle doesn't fill the whole height.
                const top_rate: f64 = @floatFromInt(@max(s.histMax(), 1024));
                const step: f64 = @as(f64, @floatFromInt(gw)) / @as(f64, @floatFromInt(nsvc.HISTORY - 1));
                // Right-aligned: the newest sample sits at the right edge.
                const x0: f64 = @as(f64, @floatFromInt(right)) - step * @as(f64, @floatFromInt(s.hist_len - 1));
                const base: f64 = @floatFromInt(y + gh - 1);
                const h: f64 = @floatFromInt(gh - 2);
                const lw: f64 = @max(1.0, @as(f64, @floatFromInt(c.zx(2))) * 0.75);
                inline for (.{ true, false }) |is_tx| {
                    const col = if (is_tx) dim(text_col, 0x77) else accent;
                    var i: usize = 1;
                    while (i < s.hist_len) : (i += 1) {
                        const v0: f64 = @floatFromInt(s.histAt(i - 1, is_tx));
                        const v1: f64 = @floatFromInt(s.histAt(i, is_tx));
                        strokeAA(
                            c,
                            x0 + step * @as(f64, @floatFromInt(i - 1)),
                            base - h * @min(v0 / top_rate, 1.0),
                            x0 + step * @as(f64, @floatFromInt(i)),
                            base - h * @min(v1 / top_rate, 1.0),
                            lw,
                            col,
                        );
                    }
                }
            }
            y += gh + c.zx(NET_GAP);
        }

        b = y + asc;
        if (!s.ready()) {
            _ = c.drawText(left, b, "Measuring\u{2026}", dim(text_col, 0x88));
            return;
        }
        var db: [32]u8 = undefined;
        var ub: [32]u8 = undefined;
        var down_buf: [24]u8 = undefined;
        var up_buf: [24]u8 = undefined;
        const down = std.fmt.bufPrint(&db, "\u{2193} {s}", .{nsvc.fmtRate(&down_buf, s.rx_rate)}) catch "";
        const up = std.fmt.bufPrint(&ub, "\u{2191} {s}", .{nsvc.fmtRate(&up_buf, s.tx_rate)}) catch "";
        _ = c.drawText(left, b, down, accent);
        drawRight(c, right, b, up, dim(text_col, 0xCC));
    }
};

/// Who is logged in and for how long: an initial-letter disc in the accent
/// colour, the display name, login@host, and the uptime (the long wording
/// falls back to the short one when it doesn't fit).
pub const UserWidget = struct {
    svc: usvc.Service = .{},

    /// Due checks only; userinfo.zig reads the uptime every 30 s and
    /// reports a change once a minute.
    pub const interval_ms: i64 = 5000;

    pub fn tick(self: *UserWidget) bool {
        return self.svc.tick(monoMs());
    }

    pub fn paint(self: *const UserWidget, c: Canvas, r: Rect) void {
        const s = &self.svc;
        const lh = lineH(c.font);
        const pad = c.zx(CARD_PAD);
        const asc: i64 = c.font.ascentPx();
        const text_col = c.theme.text_color;
        const accent = c.theme.border_color;
        const left: i64 = r.x + pad;
        const right: i64 = r.x + @as(i64, @intCast(r.w)) - pad;
        const inner_h: i64 = @as(i64, @intCast(r.h)) - 2 * pad;

        // Avatar: the display name's first letter on an accent disc.
        const d = c.zx(USER_AVATAR_D);
        const cy: f64 = @floatFromInt(r.y + pad + @divTrunc(inner_h, 2));
        const cx: f64 = @floatFromInt(left + @divTrunc(d, 2));
        c.fillCircleAA(cx, cy, @as(f64, @floatFromInt(d)) / 2.0, dim(accent, 0xDD));
        const name = s.display.slice();
        if (name.len > 0) {
            var lb: [8]u8 = undefined;
            const first_len = std.unicode.utf8ByteSequenceLength(name[0]) catch 1;
            const first = name[0..@min(first_len, name.len)];
            @memcpy(lb[0..first.len], first);
            if (first.len == 1) lb[0] = std.ascii.toUpper(lb[0]);
            const letter = lb[0..first.len];
            const lw = c.textWidth(letter);
            const base: i64 = @as(i64, @intFromFloat(cy)) + @divTrunc(asc, 2) - c.zx(1);
            _ = c.drawText(@as(i64, @intFromFloat(cx)) - @divTrunc(lw, 2), base, letter, c.theme.bg_color | 0xFF000000);
        }

        // Text column, centred against the avatar.
        const tx = left + d + c.zx(USER_GAP);
        const tw = right - tx;
        const lines = userLines();
        var b = r.y + pad + @divTrunc(inner_h - lines * lh, 2) + asc;
        var fit: [96]u8 = undefined;
        _ = c.drawText(tx, b, fitText(c, name, tw, &fit), text_col);
        b += lh;
        if (user_host) {
            var hb: [112]u8 = undefined;
            const uh = std.fmt.bufPrint(&hb, "{s}@{s}", .{ s.login.slice(), s.host.slice() }) catch s.login.slice();
            var fit2: [120]u8 = undefined;
            _ = c.drawText(tx, b, fitText(c, uh, tw, &fit2), dim(text_col, 0x99));
            b += lh;
        }
        if (!s.have_uptime) return;
        var ub: [64]u8 = undefined;
        var up = if (user_uptime_short) usvc.fmtShort(&ub, s.uptime_s) else usvc.fmtLong(&ub, s.uptime_s);
        if (!user_uptime_short and c.textWidth(up) > tw) up = usvc.fmtShort(&ub, s.uptime_s);
        _ = c.drawText(tx, b, up, accent);
    }
};

// --- monotonic clock (same hand-bound libc approach as main.zig) -----------

const libc_mono = struct {
    extern "c" fn clock_gettime(clockid: c_int, tp: *posix.timespec) c_int;
};

/// Monotonic milliseconds — only deltas are meaningful. Used to interpolate
/// the media progress bar between 2 s metadata refetches.
fn monoMs() i64 {
    var tp: posix.timespec = undefined;
    if (libc_mono.clock_gettime(1, &tp) != 0) return 0; // 1 = CLOCK_MONOTONIC
    const sec: i64 = @intCast(tp.sec);
    const nsec: i64 = @intCast(tp.nsec);
    return sec * 1000 + @divTrunc(nsec, 1_000_000);
}

/// Truncates `text` with an ellipsis so it fits `max_w`, writing into `dst`
/// (which must hold text.len + 3). Returns the slice to draw.
pub fn fitText(c: Canvas, text: []const u8, max_w: i64, dst: []u8) []const u8 {
    if (c.textWidth(text) <= max_w) return text;
    const ell: []const u8 = "\u{2026}";
    const ell_w = c.textWidth(ell);
    var end: usize = 0;
    var w: i64 = 0;
    var j: usize = 0;
    while (nextUtf8Codepoint(text, &j)) |cp| {
        const adv = (c.font.glyph(cp) catch continue).advance_x;
        if (w + adv + ell_w > max_w) break;
        w += adv;
        end = j;
    }
    const total = end + ell.len;
    if (total > dst.len) return text[0..0];
    @memcpy(dst[0..end], text[0..end]);
    @memcpy(dst[end..total], ell);
    return dst[0..total];
}

/// Formats microseconds as m:ss into `buf`.
fn fmtDur(us: u64, buf: []u8) []const u8 {
    const s = us / 1_000_000;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch buf[0..0];
}

// --- media -----------------------------------------------------------------

const MPRIS_SCRIPT = "playerctl metadata --format 'M\x1f{{status}}\x1f{{artist}}\x1f{{title}}\x1f{{position}}\x1f{{mpris:length}}\x1f{{mpris:artUrl}}' 2>/dev/null; printf '\\nS:'; playerctl shuffle 2>/dev/null; printf '\\nL:'; playerctl loop 2>/dev/null; printf '\\n'";

/// Where downloaded http(s) cover art lands before decode. Single fixed
/// path — fetches are strictly sequential, so nothing races it.
const ART_CACHE: [:0]const u8 = "/tmp/perihelionbar-shell-art.bin";

pub const MediaLoop = enum { none, track, playlist };
pub const MediaControl = enum { shuffle, prev, toggle, next, loop };
pub const MediaPhase = enum { meta, art };

pub const MediaWidget = struct {
    artist_buf: [128]u8 = undefined,
    artist_len: usize = 0,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    has_track: bool = false,
    playing: bool = false,
    shuffle_on: bool = false,
    loop_mode: MediaLoop = .none,
    pos_us: u64 = 0,
    len_us: u64 = 0,
    stamp_ms: i64 = 0,
    next_fetch_ms: i64 = 0,
    painted_sec: i64 = -1,
    /// Cover-art state. `art_url_*` is the last MPRIS artUrl seen; a new URL
    /// resets to fetch again, an unchanged one is never re-downloaded.
    art_url_buf: [512]u8 = undefined,
    art_url_len: usize = 0,
    art: enum { none, ready, failed } = .none,
    art_rgba: [art_mod.COVER_BYTES]u8 = undefined,
    art_w: u8 = 0,
    art_h: u8 = 0,
    /// Which fetch the shared pipe is carrying: metadata text, or the curl
    /// completion marker for a cover-art download.
    phase: MediaPhase = .meta,
    fetch: Fetcher = .{},

    // Progress repaints while playing; the metadata refetch below runs every
    // 2 s (gated by next_fetch_ms) so one playerctl child per second isn't
    // spawned just to move the bar.
    pub const interval_ms: i64 = 1000;

    pub fn refresh(self: *MediaWidget) void {
        if (self.fetch.busy()) return;
        var argv = [_:null]?[*:0]const u8{ "sh", "-c", MPRIS_SCRIPT, null };
        self.fetch.start("/bin/sh", &argv);
    }

    /// Position at `now_ms`, interpolating from the last fetch while playing
    /// and clamping at the track length.
    fn displayPosUs(self: *const MediaWidget, now_ms: i64) u64 {
        if (!self.playing or self.stamp_ms == 0 or self.len_us == 0) return self.pos_us;
        const delta_ms: u64 = if (now_ms > self.stamp_ms) @intCast(now_ms - self.stamp_ms) else 0;
        const remaining = if (self.pos_us >= self.len_us) 0 else self.len_us - self.pos_us;
        return self.pos_us + @min(delta_ms * 1000, remaining);
    }

    /// Cadence tick — refetch metadata every 2 s, repaint every second while
    /// the position display advances. Returns true when pixels changed.
    pub fn tick(self: *MediaWidget) bool {
        const now = monoMs();
        if (now >= self.next_fetch_ms) {
            self.refresh();
            self.next_fetch_ms = now + 2000;
        }
        if (!self.has_track or !self.playing or self.len_us == 0) return false;
        const sec: i64 = @intCast(self.displayPosUs(now) / 1_000_000);
        if (sec == self.painted_sec) return false;
        self.painted_sec = sec;
        return true;
    }

    /// file:// MPRIS art URL -> filesystem path, %XX-decoded, NUL-terminated
    /// for the decoder. Returns null when the URL isn't usable.
    fn fileUrlPath(url: []const u8, dst: []u8) ?[:0]u8 {
        const prefix = "file://";
        if (!std.mem.startsWith(u8, url, prefix)) return null;
        var rest = url[prefix.len..];
        if (std.mem.startsWith(u8, rest, "localhost")) rest = rest["localhost".len..];
        var n: usize = 0;
        var i: usize = 0;
        while (i < rest.len) {
            if (n + 1 >= dst.len) return null;
            if (rest[i] == '%' and i + 2 < rest.len) {
                const hi = std.fmt.charToDigit(rest[i + 1], 16) catch null;
                const lo = std.fmt.charToDigit(rest[i + 2], 16) catch null;
                if (hi != null and lo != null) {
                    dst[n] = hi.? * 16 + lo.?;
                    n += 1;
                    i += 3;
                    continue;
                }
            }
            dst[n] = rest[i];
            n += 1;
            i += 1;
        }
        dst[n] = 0;
        return dst[0..n :0];
    }

    /// Decodes `path` into the cover buffer. Returns true with dims stored on
    /// success, false (placeholder kept) on any failure.
    fn loadArtFile(self: *MediaWidget, path: [:0]const u8) bool {
        if (art_mod.decodeCover(path, &self.art_rgba)) |dims| {
            self.art_w = dims.w;
            self.art_h = dims.h;
            self.art = .ready;
            return true;
        }
        self.art = .failed;
        return false;
    }

    /// Reconciles cover art after a metadata fetch: new URL -> decode now for
    /// file://, queue a curl download for http(s), placeholder otherwise.
    /// Unchanged URLs are never re-fetched.
    fn updateArt(self: *MediaWidget, art_url: []const u8) void {
        if (std.mem.eql(u8, art_url, self.art_url_buf[0..self.art_url_len])) return;
        const u = art_url[0..@min(art_url.len, self.art_url_buf.len)];
        @memcpy(self.art_url_buf[0..u.len], u);
        self.art_url_len = u.len;
        self.art = .none;
        self.art_w = 0;
        self.art_h = 0;
        if (u.len == 0) return;
        var path_buf: [512]u8 = undefined;
        if (fileUrlPath(u, &path_buf)) |path| {
            _ = self.loadArtFile(path);
            return;
        }
        const http = std.mem.startsWith(u8, u, "http://") or std.mem.startsWith(u8, u, "https://");
        if (!http or std.mem.indexOfScalar(u8, u, '\'') != null) {
            self.art = .failed; // data: URIs and unquotable URLs stay placeholders
            return;
        }
        var script: [1024]u8 = undefined;
        const s = std.fmt.bufPrintZ(&script, "curl -s -o {s} -- '{s}' && printf art-ok || printf art-fail", .{ ART_CACHE, u }) catch {
            self.art = .failed;
            return;
        };
        var argv = [_:null]?[*:0]const u8{ "sh", "-c", s.ptr, null };
        self.fetch.start("/bin/sh", &argv);
        self.phase = .art;
    }

    /// Call when the fetch pipe is readable. Returns true when the fetch
    /// finished (state may have changed).
    pub fn onPipe(self: *MediaWidget) bool {
        var out: [1024]u8 = undefined;
        const n = self.fetch.onReadable(&out);
        if (n == 0) return false;
        self.fetch.closeFd();
        // Cover-art download finished: the marker (printed after curl
        // exits, so the cache file is complete) says whether curl itself
        // succeeded; the decode can still fail on format.
        if (self.phase == .art) {
            self.phase = .meta;
            const marker = std.mem.trim(u8, out[0..n], " \t\r\n");
            if (std.mem.eql(u8, marker, "art-ok")) {
                _ = self.loadArtFile(ART_CACHE);
            } else {
                self.art = .failed;
            }
            return true;
        }
        const now = monoMs();
        var meta: ?[]const u8 = null;
        var shuffle_s: ?[]const u8 = null;
        var loop_s: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, out[0..n], '\n');
        while (lines.next()) |ln| {
            const t = std.mem.trim(u8, ln, " \t\r");
            if (t.len == 0) continue;
            if (t.len > 1 and t[0] == 'M' and t[1] == 0x1F) {
                meta = t[2..];
            } else if (std.mem.startsWith(u8, t, "S:")) {
                shuffle_s = std.mem.trim(u8, t[2..], " \t");
            } else if (std.mem.startsWith(u8, t, "L:")) {
                loop_s = std.mem.trim(u8, t[2..], " \t");
            }
        }
        if (meta == null) {
            self.has_track = false;
            self.playing = false;
            self.shuffle_on = false;
            self.loop_mode = .none;
            self.pos_us = 0;
            self.len_us = 0;
            self.stamp_ms = 0;
            self.painted_sec = -1;
            self.art = .none;
            self.art_url_len = 0;
            return true;
        }
        var parts = std.mem.splitScalar(u8, meta.?, 0x1F);
        const status = std.mem.trim(u8, parts.next() orelse "", " \t");
        const artist = std.mem.trim(u8, parts.next() orelse "", " \t");
        const title = std.mem.trim(u8, parts.next() orelse "", " \t");
        const pos_s = std.mem.trim(u8, parts.next() orelse "", " \t");
        const len_s = std.mem.trim(u8, parts.next() orelse "", " \t");
        const art_s = std.mem.trim(u8, parts.next() orelse "", " \t");
        const a = artist[0..@min(artist.len, self.artist_buf.len)];
        @memcpy(self.artist_buf[0..a.len], a);
        self.artist_len = a.len;
        const t = title[0..@min(title.len, self.title_buf.len)];
        @memcpy(self.title_buf[0..t.len], t);
        self.title_len = t.len;
        self.playing = std.ascii.eqlIgnoreCase(status, "Playing");
        const paused = std.ascii.eqlIgnoreCase(status, "Paused");
        self.pos_us = std.fmt.parseInt(u64, pos_s, 10) catch 0;
        self.len_us = std.fmt.parseInt(u64, len_s, 10) catch 0;
        if (shuffle_s) |s| {
            if (std.ascii.eqlIgnoreCase(s, "On")) self.shuffle_on = true //
            else self.shuffle_on = false;
        } else self.shuffle_on = false;
        if (loop_s) |s| {
            if (std.ascii.eqlIgnoreCase(s, "Track")) self.loop_mode = .track //
            else if (std.ascii.eqlIgnoreCase(s, "Playlist")) self.loop_mode = .playlist //
            else self.loop_mode = .none;
        } else self.loop_mode = .none;
        self.has_track = self.title_len > 0 or self.artist_len > 0 or self.len_us > 0 or self.playing or paused;
        if (!self.has_track) {
            self.pos_us = 0;
            self.len_us = 0;
            self.stamp_ms = 0;
            self.painted_sec = -1;
            self.art = .none;
            self.art_url_len = 0;
            return true;
        }
        self.updateArt(art_s);
        self.stamp_ms = now;
        self.painted_sec = @intCast(self.displayPosUs(now) / 1_000_000);
        return true;
    }

    /// Absolute layout of the media card's rows, shared by paint and click
    /// hit-testing so the control zones always match the drawn glyphs.
    const MediaLayout = struct {
        inner_x: i64,
        inner_w: i64,
        title_b: i64,
        artist_b: i64,
        prog_y: i64,
        times_b: i64,
        ctrl_top: i64,
        ctrl_base: i64,
        ctrl_bottom: i64,
    };

    fn mediaLayout(r: Rect, font: *font_mod.Font, zoom: f32) MediaLayout {
        const ascent: i64 = font.ascentPx();
        const descent: i64 = font.descentPx();
        const pad = zf(CARD_PAD, zoom);
        const cover = zf(MEDIA_COVER, zoom);
        const inner_x = r.x + pad;
        const inner_w = @as(i64, @intCast(r.w)) - 2 * pad;
        const title_b = r.y + pad + ascent;
        const artist_b = title_b + ascent + descent + zf(MEDIA_TITLE_GAP, zoom);
        const prog_y = r.y + pad + cover + zf(MEDIA_HEAD_GAP, zoom);
        const times_b = prog_y + zf(MEDIA_PROG_H, zoom) + zf(MEDIA_TIME_GAP, zoom) + ascent;
        const ctrl_top = times_b + descent + zf(MEDIA_CTRL_GAP, zoom);
        return .{
            .inner_x = inner_x,
            .inner_w = inner_w,
            .title_b = title_b,
            .artist_b = artist_b,
            .prog_y = prog_y,
            .times_b = times_b,
            .ctrl_top = ctrl_top,
            .ctrl_base = ctrl_top + ascent,
            .ctrl_bottom = ctrl_top + ascent + descent,
        };
    }

    /// Which transport control (if any) sits under surface point (px, py).
    /// Slots run shuffle / prev / play-pause / next / repeat left to right.
    fn controlAt(r: Rect, font: *font_mod.Font, zoom: f32, px: i32, py: i32) ?MediaControl {
        const l = mediaLayout(r, font, zoom);
        if (py < l.ctrl_top or py > l.ctrl_bottom) return null;
        if (px < l.inner_x or px >= l.inner_x + l.inner_w) return null;
        return switch (@divTrunc((@as(i64, px) - l.inner_x) * 5, l.inner_w)) {
            0 => .shuffle,
            1 => .prev,
            2 => .toggle,
            3 => .next,
            4 => .loop,
            else => null,
        };
    }

    pub fn paint(self: *const MediaWidget, c: Canvas, r: Rect) void {
        if (!self.has_track) {
            const b = r.y + c.zx(CARD_PAD) + c.font.ascentPx();
            _ = c.drawText(r.x + c.zx(CARD_PAD), b, "no media playing", dim(c.theme.text_color, 0x99));
            return;
        }
        const l = mediaLayout(r, c.font, c.zoom);
        const ascent: i64 = c.font.ascentPx();
        const descent: i64 = c.font.descentPx();
        const cover = c.zx(MEDIA_COVER);

        // Cover tile — no image decoder in the shell, so a rounded tile with
        // a music glyph stands in for album art (mpris:artUrl is fetched but
        // not rendered).
        const tile = Rect{
            .x = @intCast(l.inner_x),
            .y = @intCast(r.y + c.zx(CARD_PAD)),
            .w = @intCast(cover),
            .h = @intCast(cover),
        };
        c.card(tile, c.theme.hover_color, c.theme.border_color);
        if (self.art == .ready and self.art_w > 0 and self.art_h > 0) {
            // Real cover art, centered in the tile inside the 1px border
            // ring, masked to the tile's inner corner radius.
            const aw: i64 = self.art_w;
            const ah: i64 = self.art_h;
            const tile_r: i64 = @min(@as(i64, @intCast(c.theme.radius_px)), @divTrunc(cover, 2));
            c.blitRgba(
                l.inner_x + @divTrunc(cover - aw, 2),
                r.y + c.zx(CARD_PAD) + @divTrunc(cover - ah, 2),
                @intCast(aw),
                @intCast(ah),
                self.art_rgba[0..@as(usize, self.art_w) * self.art_h * 4],
                if (tile_r > 0) tile_r - 1 else 0,
            );
        } else {
            const note: []const u8 = "\u{f001}";
            const note_w = c.textWidth(note);
            _ = c.drawText(
                l.inner_x + @divTrunc(cover - note_w, 2),
                r.y + c.zx(CARD_PAD) + @divTrunc(cover + ascent - descent, 2),
                note,
                dim(c.theme.text_color, 0xAA),
            );
        }

        // Title over artist, truncated to the space right of the cover.
        const text_x = l.inner_x + cover + c.zx(10);
        const text_w = r.x + @as(i64, @intCast(r.w)) - c.zx(CARD_PAD) - text_x;
        var tclip: [300]u8 = undefined;
        var aclip: [160]u8 = undefined;
        const title = if (self.title_len > 0) self.title_buf[0..self.title_len] else "Unknown title";
        _ = c.drawText(text_x, l.title_b, fitText(c, title, text_w, &tclip), c.theme.text_color);
        if (self.artist_len > 0) {
            _ = c.drawText(text_x, l.artist_b, fitText(c, self.artist_buf[0..self.artist_len], text_w, &aclip), dim(c.theme.text_color, 0xCC));
        }

        // Progress bar with knob, elapsed left and remaining right.
        const pos = self.displayPosUs(monoMs());
        const clamped = @min(pos, self.len_us);
        const fill_w: u64 = if (self.len_us == 0) 0 else clamped * @as(u64, @intCast(l.inner_w)) / self.len_us;
        const prog_h = c.zx(MEDIA_PROG_H);
        c.fillRect(l.inner_x, l.prog_y, @intCast(l.inner_w), @intCast(prog_h), dim(c.theme.text_color, 0x44));
        if (fill_w > 0) c.fillRect(l.inner_x, l.prog_y, @intCast(fill_w), @intCast(prog_h), c.theme.text_color);
        if (self.len_us > 0) {
            const kw: i64 = c.zx(7);
            const kx = std.math.clamp(l.inner_x + @as(i64, @intCast(fill_w)) - @divTrunc(kw, 2), l.inner_x, l.inner_x + l.inner_w - kw);
            c.fillRect(kx, l.prog_y + @divTrunc(prog_h - kw, 2), @intCast(kw), @intCast(kw), c.theme.text_color);
        }
        var ebuf: [16]u8 = undefined;
        _ = c.drawText(l.inner_x, l.times_b, fmtDur(pos, &ebuf), dim(c.theme.text_color, 0xAA));
        var rbuf: [24]u8 = undefined;
        const right: []const u8 = if (self.len_us > 0) blk: {
            var tmp: [16]u8 = undefined;
            break :blk std.fmt.bufPrint(&rbuf, "-{s}", .{fmtDur(self.len_us - clamped, &tmp)}) catch rbuf[0..0];
        } else "--:--";
        _ = c.drawText(l.inner_x + l.inner_w - c.textWidth(right), l.times_b, right, dim(c.theme.text_color, 0xAA));

        // Transport controls: shuffle / prev / play-pause / next / repeat.
        // Font Awesome codepoints, all verified in the bundled Nerd Font.
        const glyphs = [_][]const u8{
            "\u{f074}", // shuffle
            "\u{f048}", // previous
            if (self.playing) "\u{f04c}" else "\u{f04b}", // pause / play
            "\u{f051}", // next
            "\u{f01e}", // repeat
        };
        var i: usize = 0;
        while (i < glyphs.len) : (i += 1) {
            const cx = l.inner_x + @divTrunc(l.inner_w * (2 * @as(i64, @intCast(i)) + 1), 10);
            const gw = c.textWidth(glyphs[i]);
            const col = switch (i) {
                0 => if (self.shuffle_on) c.theme.text_color else dim(c.theme.text_color, 0x66),
                4 => if (self.loop_mode != .none) c.theme.text_color else dim(c.theme.text_color, 0x66),
                else => c.theme.text_color,
            };
            _ = c.drawText(cx - @divTrunc(gw, 2), l.ctrl_base, glyphs[i], col);
        }
    }

    /// Left-click inside the card: transport controls act, anything else is a
    /// play-pause toggle like before. State flips optimistically; the next
    /// metadata refetch (<= 2 s) confirms it.
    pub fn clickAt(self: *MediaWidget, r: Rect, font: *font_mod.Font, zoom: f32, px: i32, py: i32) void {
        const now = monoMs();
        if (self.has_track) {
            if (controlAt(r, font, zoom, px, py)) |ctl| {
                switch (ctl) {
                    .shuffle => {
                        spawnDetached("playerctl shuffle Toggle");
                        self.shuffle_on = !self.shuffle_on;
                    },
                    .prev => spawnDetached("playerctl previous"),
                    .toggle => {
                        spawnDetached("playerctl play-pause");
                        self.pos_us = self.displayPosUs(now);
                        self.playing = !self.playing;
                        self.stamp_ms = now;
                        self.painted_sec = @intCast(self.pos_us / 1_000_000);
                    },
                    .next => spawnDetached("playerctl next"),
                    .loop => {
                        const target: MediaLoop = switch (self.loop_mode) {
                            .none => .track,
                            .track => .playlist,
                            .playlist => .none,
                        };
                        const arg: []const u8 = switch (target) {
                            .none => "None",
                            .track => "Track",
                            .playlist => "Playlist",
                        };
                        var cmd_buf: [32]u8 = undefined;
                        const cmd = std.fmt.bufPrintZ(&cmd_buf, "playerctl loop {s}", .{arg}) catch return;
                        spawnDetached(cmd);
                        self.loop_mode = target;
                    },
                }
                self.next_fetch_ms = 0;
                return;
            }
        }
        spawnDetached("playerctl play-pause");
        self.next_fetch_ms = 0;
    }
};

// --- system monitor ---------------------------------------------------------

fn readFileInto(path: [:0]const u8, buf: []u8) usize {
    const raw_fd = posix.system.open(path, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw_fd < 0) return 0;
    const fd: posix.fd_t = @intCast(raw_fd);
    defer _ = posix.system.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// CPU / memory / GPU card. Usage comes from /proc; temperatures from the
/// shared temps.zig service (hwmon, thermal zones, nvidia-smi for the
/// proprietary NVIDIA driver). The third row is the selected GPU; on a
/// machine with no GPU sensor (or system_gpu "none") it falls back to the
/// load average instead.
pub const SystemWidget = struct {
    cpu_pct: u8 = 0,
    mem_pct: u8 = 0,
    load_buf: [12]u8 = undefined,
    load_len: usize = 0,
    prev_total: u64 = 0,
    prev_idle: u64 = 0,
    have_prev: bool = false,
    temps: tsvc.Service = .{},
    units: tsvc.Units = .celsius,
    /// The nvidia-smi child (only ever started for a proprietary-driver
    /// NVIDIA GPU that is selected and awake).
    fetch: Fetcher = .{},
    /// Set by a click that switched GPUs; the host saves system_gpu.
    gpu_changed: bool = false,

    pub const interval_ms: i64 = 2000;

    pub fn configure(self: *SystemWidget, cfg: tsvc.Config, units: tsvc.Units) void {
        self.temps = tsvc.Service.init(cfg);
        self.units = units;
    }

    fn updateCpu(self: *SystemWidget) void {
        var buf: [1024]u8 = undefined;
        const n = readFileInto("/proc/stat", &buf);
        if (n == 0) return;
        const text = buf[0..n];
        const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        const line = text[0..line_end];
        var it = std.mem.tokenizeAny(u8, line, " ");
        _ = it.next() orelse return; // "cpu"
        var fields: [8]u64 = undefined;
        var count: usize = 0;
        while (it.next()) |tok| {
            if (count >= fields.len) break;
            fields[count] = std.fmt.parseInt(u64, tok, 10) catch 0;
            count += 1;
        }
        if (count < 2) return;
        const idle = fields[3] + fields[4];
        var total: u64 = 0;
        for (fields[0..count]) |f| total += f;
        if (self.have_prev and total > self.prev_total) {
            const dt = total - self.prev_total;
            const di = idle - self.prev_idle;
            const busy = dt - di;
            const pct: u64 = if (busy >= dt) 100 else (100 * busy) / dt;
            self.cpu_pct = @intCast(pct);
        }
        self.prev_total = total;
        self.prev_idle = idle;
        self.have_prev = true;
    }

    fn updateMem(self: *SystemWidget) void {
        var buf: [1024]u8 = undefined;
        const n = readFileInto("/proc/meminfo", &buf);
        if (n == 0) return;
        const text = buf[0..n];
        var total: u64 = 0;
        var available: u64 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (total != 0 and available != 0) break;
            if (std.mem.startsWith(u8, line, "MemTotal:")) {
                total = parseKbAfterColon(line);
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                available = parseKbAfterColon(line);
            }
        }
        if (total > 0 and available <= total) {
            self.mem_pct = @intCast((100 * (total - available)) / total);
        }
    }

    fn updateLoad(self: *SystemWidget) void {
        var buf: [128]u8 = undefined;
        const n = readFileInto("/proc/loadavg", &buf);
        if (n == 0) return;
        var it = std.mem.tokenizeAny(u8, buf[0..n], " \t\n");
        const first = it.next() orelse return;
        const v = std.fmt.parseFloat(f32, first) catch return;
        const scaled: i64 = @intFromFloat(@round(v * 100.0));
        const whole: i64 = @divTrunc(scaled, 100);
        const frac: i64 = @mod(scaled, 100);
        // frac must be unsigned: Zig 0.16 fmt prints '+' for signed ints
        // under a width spec ("2.+98" instead of "2.98"). @mod keeps it
        // in [0,100) for any input sign, so the cast cannot overflow.
        const s = std.fmt.bufPrint(&self.load_buf, "{d}.{d:0>2}", .{ whole, @as(u32, @intCast(frac)) }) catch return;
        self.load_len = s.len;
    }

    /// Samples everything that's due. True when the card would look
    /// different, so the host only repaints on a real change.
    pub fn refresh(self: *SystemWidget) bool {
        const old_cpu = self.cpu_pct;
        const old_mem = self.mem_pct;
        var old_load: [12]u8 = undefined;
        const old_load_len = self.load_len;
        @memcpy(old_load[0..old_load_len], self.load_buf[0..old_load_len]);
        self.updateCpu();
        self.updateMem();
        const now = monoMs();
        var changed = self.temps.tick(now);
        // The load row only shows when there is no GPU row.
        if (self.temps.selectedGpu() == null) self.updateLoad();
        self.pumpSmi(now);
        changed = changed or old_cpu != self.cpu_pct or old_mem != self.mem_pct or
            !std.mem.eql(u8, old_load[0..old_load_len], self.load_buf[0..self.load_len]);
        return changed;
    }

    fn pumpSmi(self: *SystemWidget, now: i64) void {
        if (self.fetch.busy() or !self.temps.wantSmi(now)) return;
        var argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", tsvc.SMI_CMD, null };
        self.fetch.start("/bin/sh", &argv);
        if (!self.fetch.busy()) _ = self.temps.smiComplete("", now);
    }

    /// The nvidia-smi pipe may be readable. True when its answer changed
    /// what the card shows.
    pub fn onPipe(self: *SystemWidget) bool {
        if (!self.fetch.busy() or !fdReadable(self.fetch.fd())) return false;
        var out: [2048]u8 = undefined;
        const n = self.fetch.onReadable(&out);
        if (n == 0 and !self.fetch.eof) return false;
        self.fetch.closeFd();
        return self.temps.smiComplete(out[0..n], monoMs());
    }

    fn drawBar(c: Canvas, x: i64, y: i64, w: i64, h: i64, pct: u8) void {
        c.fillRect(x, y, @intCast(w), @intCast(h), dim(c.theme.border_color, 0x70));
        const fill_w: i64 = @divTrunc(w * pct, 100);
        if (fill_w > 0) c.fillRect(x, y, @intCast(fill_w), @intCast(h), c.theme.text_color);
    }

    pub fn paint(self: *const SystemWidget, c: Canvas, r: Rect) void {
        if (system_style == .rings) return self.paintRings(c, r);
        const pad = c.zx(CARD_PAD);
        const rg = c.zx(ROW_GAP);
        const barh = c.zx(BAR_H);
        const gap4 = c.zx(4);
        const gap6 = c.zx(6);
        const padx: i64 = r.x + pad;
        const inner_w: i64 = @as(i64, @intCast(r.w)) - 2 * pad;
        const right: i64 = padx + inner_w;
        const ascent: i64 = c.font.ascentPx();
        const text_col = c.theme.text_color;
        const value_col = dim(text_col, 0xCC);
        const gpu = self.temps.selectedGpu();
        // With several GPUs the row names the vendor, so a click that
        // cycles them visibly changes something.
        const gpu_label: []const u8 = if (gpu) |g| (if (self.temps.gpuList().len > 1) g.vendor.label() else "GPU") else "LOAD";
        const label_w = @max(c.textWidth("CPU"), @max(c.textWidth("MEM"), c.textWidth(gpu_label)));
        const val_x = padx + label_w + gap6;
        var pct_buf: [16]u8 = undefined;
        var temp_buf: [16]u8 = undefined;

        // CPU: usage, temperature on the right (warm/hot tint past 70/85 °C).
        const b1 = r.y + pad + ascent;
        _ = c.drawText(padx, b1, "CPU", text_col);
        _ = c.drawText(val_x, b1, std.fmt.bufPrint(&pct_buf, "{d}%", .{self.cpu_pct}) catch "", value_col);
        if (self.temps.cpuMc()) |mc| {
            const tint = tsvc.heatTint(mc);
            drawRight(c, right, b1, tsvc.fmtTemp(mc, self.units, &temp_buf), if (tint != 0) tint else value_col);
        }
        drawBar(c, padx, b1 + gap4, inner_w, barh, self.cpu_pct);

        // MEM.
        const b2 = b1 + barh + rg + gap4 + lineH(c.font);
        _ = c.drawText(padx, b2, "MEM", text_col);
        _ = c.drawText(val_x, b2, std.fmt.bufPrint(&pct_buf, "{d}%", .{self.mem_pct}) catch "", value_col);
        drawBar(c, padx, b2 + gap4, inner_w, barh, self.mem_pct);

        // GPU (busy % when the driver reports it), or the load average.
        const b3 = b2 + barh + rg + gap4 + lineH(c.font);
        _ = c.drawText(padx, b3, gpu_label, text_col);
        if (gpu) |g| {
            if (g.busy_pct) |bp| {
                _ = c.drawText(val_x, b3, std.fmt.bufPrint(&pct_buf, "{d}%", .{bp}) catch "", value_col);
            }
            if (g.asleep) {
                // Runtime-suspended dGPU: not read, so it stays asleep.
                drawRight(c, right, b3, "asleep", dim(text_col, 0x88));
            } else {
                const tint = tsvc.heatTint(g.temp_mc);
                drawRight(c, right, b3, tsvc.fmtTemp(g.temp_mc, self.units, &temp_buf), if (tint != 0) tint else value_col);
            }
            if (g.busy_pct) |bp| drawBar(c, padx, b3 + gap4, inner_w, barh, bp);
        } else {
            _ = c.drawText(val_x, b3, self.load_buf[0..self.load_len], value_col);
        }
    }

    /// "62°" from a temperature (the ring's centre has no room for the unit).
    fn shortTemp(mc: i32, units: tsvc.Units, out: []u8) []const u8 {
        const t = tsvc.fmtTemp(mc, units, out);
        if (t.len > 0 and (t[t.len - 1] == 'C' or t[t.len - 1] == 'F')) return t[0 .. t.len - 1];
        return t;
    }

    /// Ring style: CPU, memory, GPU (busy %, else its temperature) and CPU
    /// temperature as gauges. Same data as the bars; accent when normal,
    /// amber past the warning mark, the theme's error colour past the
    /// critical one (CPU/GPU 60/80 %, memory 75/90 %, temperatures 70/85 °C).
    fn paintRings(self: *const SystemWidget, c: Canvas, r: Rect) void {
        const pad = c.zx(CARD_PAD);
        const left: i64 = r.x + pad;
        const top: i64 = r.y + pad;
        const inner_w: i64 = @as(i64, @intCast(r.w)) - 2 * pad;
        const asc: i64 = c.font.ascentPx();
        const desc: i64 = c.font.descentPx();
        const text_col = c.theme.text_color;
        const accent = c.theme.border_color;
        const warn: u32 = 0xFFFFB340;
        const crit = c.theme.holiday_color;
        const idle = dim(text_col, 0x66);

        const Gauge = struct { label: []const u8, frac: f64, text: []const u8, color: u32 };
        const level = struct {
            fn of(v: u32, warn_at: u32, crit_at: u32, a: u32, w: u32, cr: u32) u32 {
                if (v >= crit_at) return cr;
                if (v >= warn_at) return w;
                return a;
            }
        }.of;
        var bufs: [4][16]u8 = undefined;
        var gauges: [4]Gauge = undefined;
        var n: usize = 0;

        gauges[n] = .{ .label = "CPU", .frac = @as(f64, @floatFromInt(self.cpu_pct)) / 100.0, .text = std.fmt.bufPrint(&bufs[n], "{d}%", .{self.cpu_pct}) catch "", .color = level(self.cpu_pct, 60, 80, accent, warn, crit) };
        n += 1;
        gauges[n] = .{ .label = "MEM", .frac = @as(f64, @floatFromInt(self.mem_pct)) / 100.0, .text = std.fmt.bufPrint(&bufs[n], "{d}%", .{self.mem_pct}) catch "", .color = level(self.mem_pct, 75, 90, accent, warn, crit) };
        n += 1;
        if (self.temps.selectedGpu()) |g| {
            if (g.asleep) {
                gauges[n] = .{ .label = "GPU", .frac = 0, .text = "zz", .color = idle };
            } else if (g.busy_pct) |bp| {
                gauges[n] = .{ .label = "GPU", .frac = @as(f64, @floatFromInt(bp)) / 100.0, .text = std.fmt.bufPrint(&bufs[n], "{d}%", .{bp}) catch "", .color = level(bp, 60, 80, accent, warn, crit) };
            } else if (g.temp_mc) |mc| {
                const tint = tsvc.heatTint(mc);
                gauges[n] = .{ .label = "GPU", .frac = @as(f64, @floatFromInt(mc)) / 100_000.0, .text = shortTemp(mc, self.units, &bufs[n]), .color = if (tint != 0) tint else accent };
            } else {
                gauges[n] = .{ .label = "GPU", .frac = 0, .text = "\u{2014}", .color = idle };
            }
            n += 1;
        }
        if (self.temps.cpuMc()) |mc| {
            const tint = tsvc.heatTint(mc);
            gauges[n] = .{ .label = "TEMP", .frac = @as(f64, @floatFromInt(mc)) / 100_000.0, .text = shortTemp(mc, self.units, &bufs[n]), .color = if (tint != 0) tint else accent };
        } else {
            gauges[n] = .{ .label = "TEMP", .frac = 0, .text = "\u{2014}", .color = idle };
        }
        n += 1;

        const slot = @divTrunc(inner_w, @as(i64, @intCast(n)));
        const d = @max(@min(c.zx(RING_D), slot - c.zx(6)), c.zx(16));
        const ro: f64 = @as(f64, @floatFromInt(d)) / 2.0;
        const ri: f64 = ro - @as(f64, @floatFromInt(c.zx(RING_W)));
        const track = dim(text_col, 0x26);
        for (gauges[0..n], 0..) |*gg, i| {
            const cx_i = left + slot * @as(i64, @intCast(i)) + @divTrunc(slot, 2);
            const cx: f64 = @floatFromInt(cx_i);
            const cy: f64 = @as(f64, @floatFromInt(top)) + ro;
            c.fillRingAA(cx, cy, ri, ro, track);
            c.fillArcAA(cx, cy, ri, ro, gg.frac, gg.color);
            const tw = c.textWidth(gg.text);
            _ = c.drawText(cx_i - @divTrunc(tw, 2), top + @divTrunc(d, 2) + @divTrunc(asc - desc, 2), gg.text, text_col);
            const lw = c.textWidth(gg.label);
            _ = c.drawText(cx_i - @divTrunc(lw, 2), top + d + c.zx(RING_LABEL_GAP) + asc, gg.label, dim(text_col, 0xAA));
        }
    }

    /// Click: next GPU when there are several (saved as system_gpu).
    pub fn click(self: *SystemWidget) void {
        if (self.temps.cycleGpu()) {
            self.gpu_changed = true;
            _ = self.temps.tick(monoMs()); // show the new GPU's reading now
        }
    }
};

fn parseKbAfterColon(line: []const u8) u64 {
    const idx = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
    var it = std.mem.tokenizeAny(u8, line[idx + 1 ..], " \t");
    const num = it.next() orelse return 0;
    return std.fmt.parseInt(u64, num, 10) catch 0;
}

// --- calendar ---------------------------------------------------------------
//
// Month grid + reminders + public holidays. Two external touchpoints, both
// following the bar/shell conventions of spawning tiny helpers rather than
// growing in-process UI machinery:
//
//   * reminders live in a plain text file (~/.config/perihelionbar/reminders.txt,
//     one per line: "YYYY-MM-DD HH:MM [lead] text" — lead = days before the
//     date to notify, 0 = on the day, and optional for hand-written lines
//     (the rest of the line is the text). Editing goes through rofi when a day
//     is clicked; notifications through notify-send when a due time passes.
//   * holidays come from date.nager.at's free no-key API for a configurable
//     country (shell.json: holiday_country, holiday_region), colour-coded:
//     global public holidays in the bright accent, regional ones dimmed.

const MAX_HOLIDAYS: usize = 48;
const REM_MAX: usize = rsvc.MAX;
const NOTIFY_GRACE_S: i64 = 900; // deliver a due notification up to 15 min late

const Holiday = struct {
    m: u8,
    d: u8,
    global: bool,
    name_len: u8,
    name: [56]u8,
};

const Reminder = rsvc.Reminder;

const CalPhase = enum { holidays, menu };

/// Notification moment for a reminder: its date shifted back `lead` days, at
/// HH:MM local time (mktime — wall-clock, so DST resolves normally).
fn dueEpoch(r: Reminder) i64 {
    const c = civilFromDays(daysFromCivil(r.y, r.m, r.d) - @as(i64, r.lead));
    var tm: libc_time.Tm = std.mem.zeroes(libc_time.Tm);
    tm.year = c.y - 1900;
    tm.mon = c.m - 1;
    tm.mday = c.d;
    tm.hour = r.hh;
    tm.min = r.mm;
    tm.isdst = -1;
    return libc_time.mktime(&tm);
}

/// Wraps `text` in single quotes for `sh -c`, escaping embedded quotes.
/// Returns the slice written, or null if `out` is too small.
fn shQuote(text: []const u8, out: []u8) ?[]const u8 {
    if (out.len < 3) return null;
    out[0] = '\'';
    var n: usize = 1;
    for (text) |ch| {
        if (ch == '\'') {
            if (n + 4 >= out.len) return null;
            @memcpy(out[n .. n + 4], "'\\''");
            n += 4;
        } else {
            if (n + 1 >= out.len) return null;
            out[n] = ch;
            n += 1;
        }
    }
    out[n] = '\'';
    return out[0 .. n + 1];
}

/// Reads `"key": "value"` out of a JSON object slice, unescaping \" and \\.
/// Returns null when the key is absent or malformed.
fn jsonField(obj: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    const k = std.mem.indexOf(u8, obj, key) orelse return null;
    var i = k + key.len;
    while (i < obj.len and obj[i] == ' ') i += 1;
    if (i >= obj.len or obj[i] != ':') return null;
    i += 1;
    while (i < obj.len and obj[i] == ' ') i += 1;
    if (i >= obj.len or obj[i] != '"') return null;
    i += 1;
    var n: usize = 0;
    while (i < obj.len) {
        const ch = obj[i];
        if (ch == '"') return out[0..n];
        if (ch == '\\' and i + 1 < obj.len) {
            const c: u8 = switch (obj[i + 1]) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => { // \uXXXX: drop (nager emits raw UTF-8, not escapes)
                    i += 2;
                    continue;
                },
            };
            if (n >= out.len) return out[0..n];
            out[n] = c;
            n += 1;
            i += 2;
            continue;
        }
        if (n >= out.len) return out[0..n];
        out[n] = ch;
        n += 1;
        i += 1;
    }
    return null; // unterminated string
}

/// True when the holiday's `counties` array mentions the configured region
/// ("WA" matches county "AU-WA"). Absent/null counties never match.
fn countyMatches(obj: []const u8, region: []const u8) bool {
    const key = "\"counties\":[";
    const c = std.mem.indexOf(u8, obj, key) orelse return false;
    const start = c + key.len;
    const end = std.mem.indexOfScalarPos(u8, obj, start, ']') orelse obj.len;
    var i = start;
    while (i < end) {
        const q1 = std.mem.indexOfScalarPos(u8, obj, i, '"') orelse return false;
        const q2 = std.mem.indexOfScalarPos(u8, obj, q1 + 1, '"') orelse return false;
        const county = obj[q1 + 1 .. q2];
        if (std.mem.eql(u8, county, region)) return true;
        if (county.len > region.len + 1 and
            county[county.len - region.len - 1] == '-' and
            std.mem.eql(u8, county[county.len - region.len ..], region)) return true;
        i = q2 + 1;
    }
    return false;
}

pub const CalendarWidget = struct {
    // View state: which month is shown, and whether it tracks the real one.
    view_y: i32 = 0,
    view_m: u8 = 1,
    have_view: bool = false,
    follow: bool = true,
    /// Epoch day of the real today — today's highlight and the footer's
    /// "next holiday" always refer to actual dates, not the browsed month.
    today_days: i64 = 0,

    // Holiday list (for `holiday_year`, the real current year).
    holiday_year: i32 = 0,
    fetch_year: i32 = 0,
    holiday_count: usize = 0,
    holidays: [MAX_HOLIDAYS]Holiday = undefined,
    holiday_retry_ms: i64 = 0,
    phase: CalPhase = .holidays,
    fetch: Fetcher = .{},

    // Reminders, kept in sync with the file.
    reminders: [REM_MAX]Reminder = undefined,
    reminder_count: usize = 0,
    cache: [4096]u8 = undefined,
    cache_len: usize = 0,

    rem_buf: [512]u8 = undefined,
    rem_len: usize = 0,
    country_buf: [8]u8 = undefined,
    country_len: usize = 0,
    region_buf: [8]u8 = undefined,
    region_len: usize = 0,

    // Monthly-ish cadence: 30 s covers the day rollover, the notification
    // window, and reminder-file changes without a busy loop.
    pub const interval_ms: i64 = 30_000;

    /// One-time wiring from the host: reminders path + holiday country/region
    /// from shell.json (sanitized — the country lands in a URL path).
    pub fn configure(self: *CalendarWidget, rem_path: []const u8, country_code: []const u8, region_code: []const u8) void {
        const p = rem_path[0..@min(rem_path.len, self.rem_buf.len - 1)];
        @memcpy(self.rem_buf[0..p.len], p);
        self.rem_buf[p.len] = 0;
        self.rem_len = p.len;

        var n: usize = 0;
        for (country_code) |ch| {
            if (std.ascii.isAlphabetic(ch) and n < self.country_buf.len) {
                self.country_buf[n] = ch;
                n += 1;
            }
        }
        if (n == 0) {
            @memcpy(self.country_buf[0..2], "AU");
            n = 2;
        }
        self.country_len = n;

        var rn: usize = 0;
        for (region_code) |ch| {
            if ((std.ascii.isAlphanumeric(ch) or ch == '-') and rn < self.region_buf.len) {
                self.region_buf[rn] = ch;
                rn += 1;
            }
        }
        self.region_len = rn;
    }

    fn remPath(self: *const CalendarWidget) [:0]const u8 {
        return self.rem_buf[0..self.rem_len :0];
    }

    fn country(self: *const CalendarWidget) []const u8 {
        return self.country_buf[0..self.country_len];
    }

    fn region(self: *const CalendarWidget) []const u8 {
        return self.region_buf[0..self.region_len];
    }

    // --- holidays ---------------------------------------------------------

    fn startHolidayFetch(self: *CalendarWidget, year: i32) void {
        if (self.fetch.busy()) return;
        var url_buf: [160]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://date.nager.at/api/v3/PublicHolidays/{d}/{s}", .{ year, self.country() }) catch return;
        var script: [256]u8 = undefined;
        // The printf marker keeps output non-empty even when curl fails, so
        // the fetch pipe always reaches EOF-with-bytes (the Fetcher treats a
        // fully empty read as "still in flight"); --max-time stops a black-
        // holed network from wedging the fetcher (and the retry gate) open.
        const s = std.fmt.bufPrintZ(&script, "curl -sf --max-time 20 -- '{s}' || printf '\\nH'", .{url}) catch return;
        var argv = [_:null]?[*:0]const u8{ "sh", "-c", s.ptr, null };
        self.fetch.start("/bin/sh", &argv);
        self.phase = .holidays;
    }

    /// Parses a date.nager.at PublicHolidays response into self.holidays.
    /// `region` empty keeps every entry; otherwise non-global holidays are
    /// kept only when their county matches. Returns false when the payload
    /// isn't a JSON list at all (curl error page, truncated body).
    fn parseHolidays(self: *CalendarWidget, json: []const u8, region_filter: []const u8) bool {
        if (std.mem.indexOf(u8, json, "[") == null) return false;
        var count: usize = 0;
        var i: usize = 0;
        while (count < MAX_HOLIDAYS) {
            const o = std.mem.indexOfScalarPos(u8, json, i, '{') orelse break;
            const e = std.mem.indexOfScalarPos(u8, json, o, '}') orelse break;
            const obj = json[o .. e + 1];
            i = e;
            var dbuf: [16]u8 = undefined;
            const date = jsonField(obj, "\"date\"", &dbuf) orelse continue;
            if (date.len < 10) continue;
            const m = std.fmt.parseInt(u8, date[5..7], 10) catch continue;
            const d = std.fmt.parseInt(u8, date[8..10], 10) catch continue;
            if (m < 1 or m > 12 or d < 1 or d > 31) continue;
            const global = std.mem.indexOf(u8, obj, "\"global\":false") == null;
            if (!global and region_filter.len > 0 and !countyMatches(obj, region_filter)) continue;
            var nbuf: [56]u8 = undefined;
            const name = jsonField(obj, "\"localName\"", &nbuf) orelse
                jsonField(obj, "\"name\"", &nbuf) orelse "Holiday";
            var h = Holiday{ .m = m, .d = d, .global = global, .name_len = 0, .name = undefined };
            const nm = name[0..@min(name.len, h.name.len)];
            @memcpy(h.name[0..nm.len], nm);
            h.name_len = @intCast(nm.len);
            self.holidays[count] = h;
            count += 1;
        }
        self.holiday_count = count;
        // Insertion sort by (month, day) — cheap at this size, and the
        // footer's "next holiday" logic wants ordered entries.
        var k: usize = 1;
        while (k < count) : (k += 1) {
            var j: usize = k;
            while (j > 0 and (self.holidays[j].m < self.holidays[j - 1].m or
                (self.holidays[j].m == self.holidays[j - 1].m and self.holidays[j].d < self.holidays[j - 1].d)))
            {
                const tmp = self.holidays[j];
                self.holidays[j] = self.holidays[j - 1];
                self.holidays[j - 1] = tmp;
                j -= 1;
            }
        }
        return true;
    }

    fn holidayFor(self: *const CalendarWidget, y: i32, m: u8, d: u8) ?*const Holiday {
        if (y != self.holiday_year) return null;
        for (0..self.holiday_count) |i| {
            const h = &self.holidays[i];
            if (h.m == m and h.d == d) return h;
        }
        return null;
    }

    // --- reminders --------------------------------------------------------

    /// Re-reads the reminders file. Unchanged content is a cheap no-op;
    /// changed content is re-parsed with each line's `fired` flag carried
    /// over from the previous set (matched by exact line), so reloads —
    /// every tick, or right after the rofi menu closes — never re-notify.
    /// Returns true when the entry set changed (day dots may move).
    fn loadReminders(self: *CalendarWidget) bool {
        var buf: [4096]u8 = undefined;
        const n = readFileInto(self.remPath(), &buf);
        if (n == self.cache_len and (n == 0 or std.mem.eql(u8, buf[0..n], self.cache[0..self.cache_len]))) {
            return false;
        }
        const copy_len = @min(n, self.cache.len);
        @memcpy(self.cache[0..copy_len], buf[0..copy_len]);
        self.cache_len = copy_len;

        const now_t = libc_time.time(null);
        var fresh: [REM_MAX]Reminder = undefined;
        var fresh_count: usize = 0;
        var fired_count: usize = 0;
        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |raw_line| {
            var line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            // Tolerate one stray leading '+' (seen on a hand- or tool-edited
            // line once) — valid lines always start with the year.
            if (line[0] == '+') {
                logging.step("calendar: stripping stray '+' from: {s}", .{line});
                line = line[1..];
            }
            if (fresh_count >= REM_MAX) break;
            var r: Reminder = undefined;
            if (!rsvc.parseLine(line, &r)) {
                logging.step("calendar: skipping malformed line: {s}", .{line});
                continue;
            }
            var carried = false;
            for (0..self.reminder_count) |i| {
                const old = &self.reminders[i];
                if (old.raw_len == r.raw_len and std.mem.eql(u8, old.raw[0..old.raw_len], r.raw[0..r.raw_len])) {
                    r.fired = old.fired;
                    carried = true;
                    break;
                }
            }
            // Only a never-seen entry whose due time already passed is born
            // fired (created too late to announce). A carried entry keeps its
            // armed state even when the file is edited around it — otherwise
            // a reparse between "due" and "next tick" would swallow the
            // notification.
            if (!carried and dueEpoch(r) < now_t) {
                r.fired = true;
                logging.step("calendar: new past-due entry marked silently: {s}", .{line});
            }
            fresh[fresh_count] = r;
            fresh_count += 1;
            if (r.fired) fired_count += 1;
        }
        self.reminders = fresh;
        self.reminder_count = fresh_count;
        logging.step("calendar: reminders loaded: {d} entries ({d} fired)", .{ fresh_count, fired_count });
        return true;
    }

    fn hasReminder(self: *const CalendarWidget, y: i32, m: u8, d: u8) bool {
        for (0..self.reminder_count) |i| {
            const r = self.reminders[i];
            if (r.y == y and r.m == m and r.d == d) return true;
        }
        return false;
    }

    /// Fires notifications for reminders whose due time passed since the
    /// last tick, marking them fired either way (a due time missed by more
    /// than the grace window — suspend, downtime — is marked silently).
    fn checkReminders(self: *CalendarWidget, now_t: i64) void {
        for (0..self.reminder_count) |i| {
            const r = &self.reminders[i];
            if (r.fired) continue;
            const due = dueEpoch(r.*);
            if (now_t < due) continue;
            r.fired = true;
            if (now_t - due > NOTIFY_GRACE_S) {
                logging.step("calendar: reminder {s} missed the {d}s window ({d}s late) — marked silently", .{ r.text(), NOTIFY_GRACE_S, now_t - due });
                continue;
            }
            var when_buf: [32]u8 = undefined;
            const when = std.fmt.bufPrint(&when_buf, "{s} {d} {s} {d:0>2}:{d:0>2}", .{
                DAYS[wdayOf(daysFromCivil(r.y, r.m, r.d)) % 7],
                r.d,
                MONTHS[r.m - 1],
                r.hh,
                r.mm,
            }) catch continue;
            var t_q: [400]u8 = undefined;
            var w_q: [80]u8 = undefined;
            const title = shQuote(r.text(), &t_q) orelse continue;
            const body = shQuote(when, &w_q) orelse continue;
            var cmd: [560]u8 = undefined;
            const s = std.fmt.bufPrintZ(&cmd, "notify-send -a perihelionbar -u normal {s} {s}", .{ title, body }) catch continue;
            logging.step("calendar: reminder due, notifying: {s}", .{r.text()});
            spawnDetached(s);
        }
    }

    /// Click on a day: rofi menu for that date — add a reminder (free-text,
    /// optionally "HH:MM lead text" prefixed) or delete an existing one.
    /// The script edits the file; the completion fires loadReminders().
    fn openDayMenu(self: *CalendarWidget, y: i32, m: u8, d: u8) void {
        if (self.fetch.busy()) return;
        var d_buf: [16]u8 = undefined;
        // NOTE: view_y is i32, but Zig 0.16's fmt renders an explicit '+'
        // for signed ints whenever a width/fill spec is applied — that '+'
        // leaked into the date (d='+2026-10-09'), which broke the menu's
        // grep match and wrote '+'-prefixed lines. Cast to unsigned.
        const ds = std.fmt.bufPrint(&d_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(@max(y, 0))), m, d }) catch return;
        var script: [1536]u8 = undefined;
        const s = std.fmt.bufPrintZ(&script,
            \\printf 'menu-run\n'
            \\f='{s}'
            \\d='{s}'
            \\menu=$(printf '+ New reminder\n'; grep -F -- "$d " "$f" 2>/dev/null | sed 's/^[0-9-]* //')
            \\sel=$(printf '%s\n' "$menu" | rofi -dmenu -i -p "Reminders · $d") || exit 0
            \\[ -n "$sel" ] || exit 0
            \\case "$sel" in
            \\'+ New reminder')
            \\  inp=$(rofi -dmenu -p "$d — text, or HH:MM lead text" </dev/null) || exit 0
            \\  case "$inp" in
            \\    '') exit 0 ;;
            \\    [0-9][0-9]:[0-9][0-9]' '*) line="$d $inp" ;;
            \\    *) line="$d 09:00 0 $inp" ;;
            \\  esac
            \\  printf '%s\n' "$line" >> "$f"
            \\  notify-send -a perihelionbar "Reminder added" "$line" 2>/dev/null
            \\  ;;
            \\*)
            \\  grep -vxF -- "$d $sel" "$f" > "$f.tmp" 2>/dev/null
            \\  mv "$f.tmp" "$f" 2>/dev/null
            \\  notify-send -a perihelionbar "Reminder removed" "$d $sel" 2>/dev/null
            \\  ;;
            \\esac
            \\printf 'menu-done'
        , .{ self.remPath(), ds }) catch return;
        var argv = [_:null]?[*:0]const u8{ "sh", "-c", s.ptr, null };
        self.fetch.start("/bin/sh", &argv);
        self.phase = .menu;
    }

    // --- cadence / io -----------------------------------------------------

    /// 30 s tick: follow the real month/day, kick a holiday fetch when the
    /// year isn't loaded yet, re-sync the reminders file, fire due
    /// notifications. Returns true when displayed pixels changed.
    pub fn tick(self: *CalendarWidget) bool {
        var changed = false;
        const now_t = libc_time.time(null);
        var tm: libc_time.Tm = undefined;
        _ = libc_time.localtime_r(&now_t, &tm);
        const cur_y: i32 = tm.year + 1900;
        const cur_m: u8 = @intCast(tm.mon + 1);
        const cur_d: u8 = @intCast(tm.mday);
        const today = daysFromCivil(cur_y, cur_m, cur_d);

        if (!self.have_view) {
            self.view_y = cur_y;
            self.view_m = cur_m;
            self.have_view = true;
            self.follow = true;
            changed = true;
        } else if (self.follow and (self.view_y != cur_y or self.view_m != cur_m)) {
            self.view_y = cur_y;
            self.view_m = cur_m;
            changed = true;
        }
        if (self.today_days != today) {
            self.today_days = today;
            changed = true;
        }

        if (self.holiday_year != cur_y and !self.fetch.busy() and monoMs() >= self.holiday_retry_ms) {
            self.fetch_year = cur_y;
            self.holiday_retry_ms = monoMs() + 3_600_000; // hourly retry until a year loads
            self.startHolidayFetch(cur_y);
        }
        if (self.loadReminders()) changed = true;
        self.checkReminders(now_t);
        return changed;
    }

    /// Fetch pipe finished: holiday JSON parsed, or the rofi menu closed
    /// (either way the reminders file may have changed).
    pub fn onPipe(self: *CalendarWidget) bool {
        var out: [10240]u8 = undefined;
        const n = self.fetch.onReadable(&out);
        if (n == 0) return false;
        self.fetch.closeFd();
        switch (self.phase) {
            .holidays => {
                if (self.parseHolidays(out[0..n], self.region())) {
                    self.holiday_year = self.fetch_year;
                    return true;
                }
                return false; // next hourly gate retries
            },
            .menu => return self.loadReminders(),
        }
    }

    // --- layout / painting ------------------------------------------------

    /// Absolute layout shared by paint and click hit-testing.
    const CalLayout = struct {
        padx: i64,
        grid_x: i64,
        grid_y: i64,
        b1: i64, // header baseline
        wd_b: i64, // weekday row baseline
        foot_b: i64, // footer baseline
        lh: i64,
        rem_top: i64, // top of the "Reminders" header (list on)
        rows_top: i64, // top of the first reminder row
    };

    fn calLayout(r: Rect, font: *font_mod.Font, zoom: f32) CalLayout {
        const lh = lineH(font);
        const ascent: i64 = font.ascentPx();
        const pad = zf(CARD_PAD, zoom);
        const head_gap = zf(CAL_HEAD_GAP, zoom);
        const wd_gap = zf(CAL_WD_GAP, zoom);
        const cell_h = zf(CAL_CELL_H, zoom);
        const foot_gap = zf(CAL_FOOT_GAP, zoom);
        const padx = r.x + pad;
        const b1 = r.y + pad + ascent;
        const wd_b = r.y + pad + lh + head_gap + ascent;
        const grid_y = r.y + pad + 2 * lh + head_gap + wd_gap;
        const foot_b = grid_y + CAL_ROWS * cell_h + foot_gap + ascent;
        const rem_top = foot_b - ascent + lh + zf(CAL_REM_GAP, zoom);
        const rows_top = rem_top + lh + zf(CAL_REM_HEAD_GAP, zoom);
        return .{ .padx = padx, .grid_x = padx, .grid_y = grid_y, .b1 = b1, .wd_b = wd_b, .foot_b = foot_b, .lh = lh, .rem_top = rem_top, .rows_top = rows_top };
    }

    fn navMonth(self: *CalendarWidget, delta: i32) void {
        self.follow = false; // browsing detaches from the real month
        var m: i32 = @as(i32, self.view_m) + delta;
        var y = self.view_y;
        if (m < 1) {
            m = 12;
            y -= 1;
        } else if (m > 12) {
            m = 1;
            y += 1;
        }
        self.view_m = @intCast(m);
        self.view_y = y;
    }

    fn jumpToToday(self: *CalendarWidget) void {
        const now_t = libc_time.time(null);
        var tm: libc_time.Tm = undefined;
        _ = libc_time.localtime_r(&now_t, &tm);
        self.view_y = tm.year + 1900;
        self.view_m = @intCast(tm.mon + 1);
        self.follow = true;
    }

    pub fn paint(self: *const CalendarWidget, c: Canvas, r: Rect) void {
        const l = calLayout(r, c.font, c.zoom);
        const ascent: i64 = c.font.ascentPx();
        const cell_w = c.zx(CAL_CELL_W);
        const cell_h = c.zx(CAL_CELL_H);
        const grid_w: i64 = 7 * cell_w;

        // Header: < Month YYYY > — chevrons from Font Awesome, title click
        // jumps back to the real month (see clickAt).
        if (self.have_view) {
            var title_buf: [32]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, "{s} {d}", .{ MONTHS_FULL[self.view_m - 1], self.view_y }) catch "";
            const left: []const u8 = "\u{f053}";
            const right: []const u8 = "\u{f054}";
            _ = c.drawText(l.grid_x, l.b1, left, dim(c.theme.text_color, 0x99));
            _ = c.drawText(l.grid_x + grid_w - c.textWidth(right), l.b1, right, dim(c.theme.text_color, 0x99));
            const tw = c.textWidth(title);
            _ = c.drawText(l.grid_x + @divTrunc(grid_w - tw, 2), l.b1, title, c.theme.text_color);
        }

        // Weekday header (Monday first — matches the grid below).
        for (WD_ROW, 0..) |lbl, col| {
            const lw = c.textWidth(lbl);
            _ = c.drawText(
                l.grid_x + @as(i64, @intCast(col)) * cell_w + @divTrunc(cell_w - lw, 2),
                l.wd_b,
                lbl,
                dim(c.theme.text_color, 0x88),
            );
        }

        if (self.have_view) {
            const first_col: i64 = monCol(wdayOf(daysFromCivil(self.view_y, self.view_m, 1)));
            const dim_days = daysInMonth(self.view_y, self.view_m);
            var day: i32 = 1;
            var pos: i64 = first_col;
            while (day <= dim_days) : (day += 1) {
                const col = @mod(pos, 7);
                const row = @divFloor(pos, 7);
                pos += 1;
                const x0 = l.grid_x + col * cell_w;
                const y0 = l.grid_y + row * cell_h;
                const is_today = daysFromCivil(self.view_y, self.view_m, @intCast(day)) == self.today_days;
                const hol = self.holidayFor(self.view_y, self.view_m, @intCast(day));
                if (is_today) {
                    // Accent pill behind today's number.
                    c.card(
                        .{ .x = @intCast(x0 + 1), .y = @intCast(y0 + 1), .w = @intCast(cell_w - 2), .h = @intCast(cell_h - 3) },
                        dim(c.theme.border_color, 0x33),
                        dim(c.theme.border_color, 0x99),
                    );
                }
                var num_buf: [4]u8 = undefined;
                const num = std.fmt.bufPrint(&num_buf, "{d}", .{day}) catch continue;
                const num_col: u32 = if (hol) |h|
                    if (h.global) c.theme.holiday_color else dim(c.theme.holiday_color, 0x99)
                else if (is_today) c.theme.text_color //
                else dim(c.theme.text_color, 0xE0);
                _ = c.drawText(x0 + @divTrunc(cell_w - c.textWidth(num), 2), y0 + 2 + ascent, num, num_col);
                if (self.hasReminder(self.view_y, self.view_m, @intCast(day))) {
                    const dot: i64 = @max(2, c.zx(3));
                    c.fillRect(x0 + @divTrunc(cell_w, 2) - @divTrunc(dot, 2), y0 + cell_h - c.zx(4), @intCast(dot), @intCast(dot), c.theme.text_color);
                }
            }
        }

        // Footer: today's holiday in the accent color, else the next
        // upcoming one of the real year.
        if (self.holiday_count > 0) {
            var chosen: ?*const Holiday = null;
            var is_today_hol = false;
            for (0..self.holiday_count) |i| {
                const h = &self.holidays[i];
                const hd = daysFromCivil(self.holiday_year, h.m, h.d);
                if (hd == self.today_days) {
                    chosen = h;
                    is_today_hol = true;
                    break;
                }
                if (hd > self.today_days and chosen == null) chosen = h;
            }
            if (chosen) |h| {
                var label_buf: [96]u8 = undefined;
                const label = if (is_today_hol)
                    std.fmt.bufPrint(&label_buf, "{s}", .{h.name[0..h.name_len]}) catch ""
                else
                    std.fmt.bufPrint(&label_buf, "Next: {s} · {d} {s}", .{ h.name[0..h.name_len], h.d, MONTHS[h.m - 1] }) catch "";
                var clip: [120]u8 = undefined;
                const col = if (is_today_hol) c.theme.holiday_color else dim(c.theme.text_color, 0x99);
                _ = c.drawText(l.padx, l.foot_b, fitText(c, label, grid_w, &clip), col);
            }
        }

        if (calendar_reminder_rows > 0) self.paintReminders(c, l, grid_w);
    }

    /// The reminders shown under the grid: today's and the next ones,
    /// earliest first, at most calendar_reminder_rows. Fills `out`.
    fn listedReminders(self: *const CalendarWidget, out: *[rsvc.MAX_ROWS]usize) usize {
        const rows = @min(calendar_reminder_rows, rsvc.MAX_ROWS);
        return rsvc.upcoming(self.reminders[0..self.reminder_count], self.today_days, out[0..rows]);
    }

    /// Reminders list: a Notes-style header (accent title over a hairline),
    /// then "day  time  text" rows. Today's day label is in the accent; a
    /// reminder of today whose time already passed is dimmed.
    fn paintReminders(self: *const CalendarWidget, c: Canvas, l: CalLayout, inner_w: i64) void {
        const t = c.theme.text_color;
        const accent = c.theme.border_color;
        const ascent: i64 = c.font.ascentPx();
        _ = c.drawText(l.padx, l.rem_top + ascent, "Reminders", accent);
        c.fillRect(l.padx, l.rem_top + l.lh + @divTrunc(c.zx(CAL_REM_HEAD_GAP), 2), @intCast(@max(inner_w, 0)), 1, dim(t, 0x22));

        var idx: [rsvc.MAX_ROWS]usize = undefined;
        const n = self.listedReminders(&idx);
        if (n == 0) {
            _ = c.drawText(l.padx, l.rows_top + ascent, "Nothing coming up", dim(t, 0x88));
            return;
        }
        // Day column as wide as the widest label actually shown.
        var label_w: i64 = 0;
        for (idx[0..n]) |ri| {
            var lb: [16]u8 = undefined;
            label_w = @max(label_w, c.textWidth(rsvc.dayLabel(&self.reminders[ri], self.today_days, &lb)));
        }
        const gap = c.zx(6);
        const time_x = l.padx + label_w + gap;
        const text_x = time_x + c.textWidth("00:00") + gap;
        for (idx[0..n], 0..) |ri, row| {
            const r = &self.reminders[ri];
            const b = l.rows_top + @as(i64, @intCast(row)) * l.lh + ascent;
            const is_today = r.day() == self.today_days;
            const passed = is_today and r.fired;
            var lb: [16]u8 = undefined;
            _ = c.drawText(l.padx, b, rsvc.dayLabel(r, self.today_days, &lb), if (is_today and !passed) accent else dim(t, 0x99));
            var tb: [8]u8 = undefined;
            const tm = std.fmt.bufPrint(&tb, "{d:0>2}:{d:0>2}", .{ r.hh, r.mm }) catch "";
            _ = c.drawText(time_x, b, tm, dim(t, 0x99));
            var clip: [200]u8 = undefined;
            _ = c.drawText(text_x, b, fitText(c, r.text(), l.padx + inner_w - text_x, &clip), if (passed) dim(t, 0x88) else t);
        }
    }

    /// Left-click: header arrows step months, the month title jumps back to
    /// today, a day cell opens its rofi reminder menu.
    pub fn clickAt(self: *CalendarWidget, r: Rect, font: *font_mod.Font, zoom: f32, px: i32, py: i32) void {
        if (!self.have_view) return;
        const l = calLayout(r, font, zoom);
        const cell_w = zf(CAL_CELL_W, zoom);
        const cell_h = zf(CAL_CELL_H, zoom);
        const arrow_zone = zf(CAL_ARROW_ZONE, zoom);
        const grid_w: i64 = 7 * cell_w;
        const px64: i64 = px;
        const py64: i64 = py;
        const head_top: i64 = r.y + zf(CARD_PAD, zoom);
        if (py64 >= head_top and py64 < head_top + l.lh) {
            if (px64 < l.grid_x + arrow_zone) navMonth(self, -1) //
            else if (px64 >= l.grid_x + grid_w - arrow_zone) navMonth(self, 1) //
            else jumpToToday(self);
            return;
        }
        if (py64 >= l.grid_y and py64 < l.grid_y + CAL_ROWS * cell_h and
            px64 >= l.grid_x and px64 < l.grid_x + grid_w)
        {
            const col = @divFloor(px64 - l.grid_x, cell_w);
            const row = @divFloor(py64 - l.grid_y, cell_h);
            const first_col = @as(i64, monCol(wdayOf(daysFromCivil(self.view_y, self.view_m, 1))));
            const day = row * 7 + col - first_col + 1;
            if (day >= 1 and day <= daysInMonth(self.view_y, self.view_m)) {
                self.openDayMenu(self.view_y, self.view_m, @intCast(day));
            }
            return;
        }
        // A reminder row opens its day's menu (add another, or remove it).
        if (calendar_reminder_rows > 0 and py64 >= l.rows_top and px64 >= l.padx and px64 < l.padx + grid_w) {
            const row: usize = @intCast(@divFloor(py64 - l.rows_top, l.lh));
            var idx: [rsvc.MAX_ROWS]usize = undefined;
            const n = self.listedReminders(&idx);
            if (row < n) {
                const rem = &self.reminders[idx[row]];
                self.openDayMenu(rem.y, rem.m, rem.d);
            }
        }
    }
};

// --- notes (sticky notes with tabs) -------------------------------------------

// The Notes card: plain-text notes you type straight into the desktop card.
// Each note is one file, ~/.config/perihelionbar/notes/noteN.txt (N = 1-9),
// so the original single note1.txt is simply note 1. A header holds one tab
// per note, + for a new note and × to delete the open one (a second click
// confirms; the deleted text is kept in notes/.last-deleted.txt).
//
// The folder is watched with inotify: notes changed by another editor or a
// sync tool reload on their own, and new noteN.txt files appear as tabs. An
// edit in progress always wins over the file — its next save replaces it.
//
// While not editing, "- [ ] " / "- [x] " lines draw as checkboxes (click
// the box to tick it), "- " lines as bullets and "# " lines as headings.
// The decoration takes exactly the width of the characters it replaces, so
// editing (which shows the raw text) never reflows the note.
//
// Editing is whole-process single-slot: the host sets `edit_index` when a
// click leaves the card `editing` ([on_demand] keyboard interactivity grants
// focus), routes compositor key events here through xkb (UTF-32 decode), and
// releases the slot on Esc, focus-leave, or a click elsewhere. Edits save
// atomically (tmp + rename) on release and after a quiet typing pause, so a
// crash can't eat recent keystrokes.
//
// Text is capped at NOTE_MAX *bytes* so the fixed wrap-line array always
// fits the worst case (every byte a newline ⇒ text.len + 1 lines). A file
// bigger than that is shown cut off and never written back (read-only), so
// the card can't truncate a long note someone wrote elsewhere.

/// Notes options (shell.json notes_*), set by the host before cards are
/// measured: the header and the base line count change the card's size.
pub const NotesLayout = struct {
    /// Header with note tabs, + and ×. Off = one plain note (the open one).
    tabs: bool = true,
    /// Checkboxes, bullets and headings while not editing.
    checklists: bool = true,
    /// Text lines the card shows at its base size (3-30).
    lines: i64 = 6,
};
pub var notes_layout: NotesLayout = .{};

const NOTE_HEADER_GAP: i64 = 8;
const NOTE_TAB_PADX: i64 = 6;
const NOTE_TAB_GAP: i64 = 4;
const NOTE_DELETE_ARM_MS: i64 = 3000;
const NOTE_AUTOSAVE_MS: i64 = 1500;

/// Height of the header strip above the text (0 with notes_tabs off).
pub fn noteHeaderH(lh: i64) i64 {
    return if (notes_layout.tabs) lh + NOTE_HEADER_GAP else 0;
}

/// Scale a layout constant by a zoom factor (corner-resize content zoom).
/// Canvas.zx is the method form for paints; this covers layout/hit-test
/// helpers without a canvas in scope.
fn zf(base: i64, zoom: f32) i64 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(base)) * zoom));
}

/// Visible text lines for a card height, below the header: notes_lines at
/// base size, growing with the rect (corner resize reflows the note instead
/// of just padding it). Min 1 so a clamped card still edits line one.
pub fn noteVisLines(card_h: i64, lh: i64) usize {
    if (lh <= 0) return 1;
    const v = @divTrunc(card_h - 2 * CARD_PAD - noteHeaderH(lh), lh);
    return @max(1, @as(usize, @intCast(@max(v, 0))));
}

test "notes: visible lines follow card height" {
    const t = std.testing;
    const saved = notes_layout;
    defer notes_layout = saved;
    // No header: base card (2*14 pads + 6 lines at lh 20) shows 6; grown
    // cards show more; degenerate inputs still edit line one.
    notes_layout.tabs = false;
    try t.expectEqual(@as(usize, 6), noteVisLines(2 * CARD_PAD + 6 * 20, 20));
    try t.expectEqual(@as(usize, 12), noteVisLines(2 * CARD_PAD + 12 * 20, 20));
    try t.expectEqual(@as(usize, 1), noteVisLines(30, 20));
    try t.expectEqual(@as(usize, 1), noteVisLines(148, 0));
    // With the header, its strip comes off the top first.
    notes_layout.tabs = true;
    try t.expectEqual(@as(usize, 6), noteVisLines(2 * CARD_PAD + noteHeaderH(20) + 6 * 20, 20));
    try t.expectEqual(@as(usize, 4), noteVisLines(2 * CARD_PAD + 6 * 20, 20));
}

test "zoom scales layout constants" {
    const t = std.testing;
    try t.expectEqual(@as(i64, 24), zf(24, 1.0));
    try t.expectEqual(@as(i64, 36), zf(24, 1.5));
    try t.expectEqual(@as(i64, 14), zf(7, 2.0));
    try t.expectEqual(@as(i64, 10), zf(7, 1.4)); // 9.8 rounds to 10
    try t.expectEqual(@as(i64, 0), zf(0, 3.0));
}

/// Where the header's controls sit, relative to the card's inner left edge.
/// Paint and click both use it, so they can't disagree. Tabs sit on the
/// left, + and × on the right; when the tabs don't fit, a compact
/// "‹ 3/9 ›" pager takes their place.
pub const NoteHeader = struct {
    btn_w: i64,
    /// Tabs mode: tab i starts at i * (btn_w + NOTE_TAB_GAP).
    tabs: bool = true,
    /// Pager mode: ‹ and › around the "n/N" label.
    prev_x: i64 = 0,
    label_x: i64 = 0,
    label_w: i64 = 0,
    next_x: i64 = 0,
    /// null = not shown.
    plus_x: ?i64 = null,
    del_x: ?i64 = null,
};

pub const NoteHit = union(enum) { none, tab: usize, prev, next, plus, delete };

fn noteHeaderLayout(measure: anytype, inner_w: i64, page_count: usize, can_add: bool, can_delete: bool) NoteHeader {
    const btn_w = measure.advance('0') + 2 * NOTE_TAB_PADX;
    const step = btn_w + NOTE_TAB_GAP;
    var h = NoteHeader{ .btn_w = btn_w };
    var right = inner_w;
    if (can_delete) {
        h.del_x = right - btn_w;
        right -= step;
    }
    if (can_add) {
        h.plus_x = right - btn_w;
        right -= step;
    }
    const n: i64 = @intCast(page_count);
    if (n * step - NOTE_TAB_GAP > right) {
        h.tabs = false;
        h.prev_x = 0;
        h.label_x = btn_w + NOTE_TAB_GAP;
        h.label_w = advSlice(measure, "9/9");
        h.next_x = h.label_x + h.label_w + NOTE_TAB_GAP;
    }
    return h;
}

fn inSpan(x: i64, at: i64, w: i64) bool {
    return x >= at and x < at + w;
}

fn noteHeaderHit(h: NoteHeader, page_count: usize, rel_x: i64) NoteHit {
    if (h.del_x) |dx| {
        if (inSpan(rel_x, dx, h.btn_w)) return .delete;
    }
    if (h.plus_x) |px| {
        if (inSpan(rel_x, px, h.btn_w)) return .plus;
    }
    if (page_count <= 1 or rel_x < 0) return .none;
    if (h.tabs) {
        const step = h.btn_w + NOTE_TAB_GAP;
        const i: usize = @intCast(@divTrunc(rel_x, step));
        if (i < page_count and inSpan(rel_x, @as(i64, @intCast(i)) * step, h.btn_w)) return .{ .tab = i };
        return .none;
    }
    if (inSpan(rel_x, h.prev_x, h.btn_w)) return .prev;
    if (inSpan(rel_x, h.next_x, h.btn_w)) return .next;
    return .none;
}

test "notes: header layout and hit-testing agree" {
    const t = std.testing;
    const m = FixedAdv{}; // 8px advance → 20px buttons, 24px steps
    // Three notes in 222px: tabs on the left, + and × on the right.
    const h = noteHeaderLayout(m, 222, 3, true, true);
    try t.expect(h.tabs);
    try t.expectEqual(@as(?i64, 202), h.del_x);
    try t.expectEqual(@as(?i64, 178), h.plus_x);
    try t.expectEqual(NoteHit{ .tab = 0 }, noteHeaderHit(h, 3, 5));
    try t.expectEqual(NoteHit{ .tab = 2 }, noteHeaderHit(h, 3, 48 + 19));
    try t.expectEqual(@as(NoteHit, .none), noteHeaderHit(h, 3, 48 + 21)); // the gap after tab 3
    try t.expectEqual(@as(NoteHit, .none), noteHeaderHit(h, 3, 100));
    try t.expectEqual(@as(NoteHit, .plus), noteHeaderHit(h, 3, 180));
    try t.expectEqual(@as(NoteHit, .delete), noteHeaderHit(h, 3, 210));
    // Nine notes don't fit: the pager replaces the tabs.
    const p = noteHeaderLayout(m, 222, 9, false, true);
    try t.expect(!p.tabs);
    try t.expectEqual(p.plus_x, null);
    try t.expectEqual(@as(NoteHit, .prev), noteHeaderHit(p, 9, 3));
    try t.expectEqual(@as(NoteHit, .next), noteHeaderHit(p, 9, p.next_x + 1));
    // One note: no tabs to hit, only the buttons.
    const one = noteHeaderLayout(m, 222, 1, true, false);
    try t.expectEqual(one.del_x, null);
    try t.expectEqual(@as(NoteHit, .none), noteHeaderHit(one, 1, 5));
}

/// How a line of a note is decorated while not editing. `prefix` is the
/// byte length of the marker the decoration replaces.
const NoteLineKind = enum { plain, todo, done, bullet, heading };
const NoteLine = struct { kind: NoteLineKind, prefix: usize };

fn noteLineKind(line: []const u8) NoteLine {
    if (line.len >= 5 and (line[0] == '-' or line[0] == '*') and line[1] == ' ' and
        line[2] == '[' and line[4] == ']' and (line.len == 5 or line[5] == ' '))
    {
        const prefix = @min(line.len, 6);
        if (line[3] == ' ') return .{ .kind = .todo, .prefix = prefix };
        if (line[3] == 'x' or line[3] == 'X') return .{ .kind = .done, .prefix = prefix };
    }
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') return .{ .kind = .bullet, .prefix = 2 };
    if (line.len >= 2 and line[0] == '#' and line[1] == ' ') return .{ .kind = .heading, .prefix = 2 };
    return .{ .kind = .plain, .prefix = 0 };
}

/// Start of the hard (newline-separated) line holding byte `pos`.
fn logicalStart(text_: []const u8, pos: usize) usize {
    var p = @min(pos, text_.len);
    while (p > 0 and text_[p - 1] != '\n') p -= 1;
    return p;
}

/// End (exclusive, before the newline) of the hard line starting at `start`.
fn logicalEnd(text_: []const u8, start: usize) usize {
    return std.mem.indexOfScalarPos(u8, text_, start, '\n') orelse text_.len;
}

test "notes: checklist, bullet and heading markers" {
    const t = std.testing;
    try t.expectEqual(NoteLine{ .kind = .todo, .prefix = 6 }, noteLineKind("- [ ] milk"));
    try t.expectEqual(NoteLine{ .kind = .done, .prefix = 6 }, noteLineKind("* [X] eggs"));
    try t.expectEqual(NoteLine{ .kind = .todo, .prefix = 5 }, noteLineKind("- [ ]"));
    try t.expectEqual(NoteLine{ .kind = .bullet, .prefix = 2 }, noteLineKind("- [y] not a box"));
    try t.expectEqual(NoteLine{ .kind = .bullet, .prefix = 2 }, noteLineKind("* item"));
    try t.expectEqual(NoteLine{ .kind = .heading, .prefix = 2 }, noteLineKind("# Today"));
    try t.expectEqual(NoteLine{ .kind = .plain, .prefix = 0 }, noteLineKind("#hashtag"));
    try t.expectEqual(NoteLine{ .kind = .plain, .prefix = 0 }, noteLineKind("-dash"));
    const txt = "one\n- [ ] two\nthree";
    try t.expectEqual(@as(usize, 4), logicalStart(txt, 9));
    try t.expectEqual(@as(usize, 13), logicalEnd(txt, 4));
    try t.expectEqual(@as(usize, 14), logicalStart(txt, txt.len));
}

const NoteBtnStyle = enum { normal, active, danger };

/// One header pill: rounded fill, label centred on the text baseline.
fn drawNoteButton(c: Canvas, x: i64, y: i64, w: i64, h: i64, label: []const u8, style: NoteBtnStyle) void {
    const t = c.theme.text_color;
    const fill: u32 = switch (style) {
        .normal => dim(t, 0x16),
        .active => c.theme.border_color,
        .danger => c.theme.holiday_color,
    };
    const fg: u32 = switch (style) {
        .normal => dim(t, 0xBB),
        .active => c.theme.bg_color | 0xFF000000,
        .danger => 0xFFFFFFFF,
    };
    c.card(.{ .x = @intCast(x), .y = @intCast(y), .w = @intCast(@max(w, 1)), .h = @intCast(@max(h, 1)) }, fill, 0);
    const lw = c.textWidth(label);
    _ = c.drawText(x + @divTrunc(w - lw, 2), y + c.font.ascentPx(), label, fg);
}

/// A thick AA line segment (the checkbox tick).
fn strokeAA(c: Canvas, x0: f64, y0: f64, x1: f64, y1: f64, width: f64, color: u32) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len <= 0.0) return;
    const nx = -dy / len * width / 2.0;
    const ny = dx / len * width / 2.0;
    const pts = [4]Canvas.FPt{
        .{ .x = x0 + nx, .y = y0 + ny },
        .{ .x = x1 + nx, .y = y1 + ny },
        .{ .x = x1 - nx, .y = y1 - ny },
        .{ .x = x0 - nx, .y = y0 - ny },
    };
    c.fillConvex(&pts, color);
}

/// Checkbox in a text row: an outlined box, or an accent box with a tick.
fn drawCheckbox(c: Canvas, x: i64, row_top: i64, lh: i64, checked: bool) void {
    const s = @max(@divTrunc(lh * 6, 10), 8);
    const bx = x + 1;
    const by = row_top + @divTrunc(lh - s, 2);
    const accent = c.theme.border_color;
    const box = Rect{ .x = @intCast(bx), .y = @intCast(by), .w = @intCast(s), .h = @intCast(s) };
    if (!checked) {
        c.card(box, 0, dim(c.theme.text_color, 0x99));
        return;
    }
    c.card(box, accent, accent);
    const fx: f64 = @floatFromInt(bx);
    const fy: f64 = @floatFromInt(by);
    const fs: f64 = @floatFromInt(s);
    const ink = c.theme.bg_color | 0xFF000000;
    strokeAA(c, fx + fs * 0.22, fy + fs * 0.52, fx + fs * 0.43, fy + fs * 0.73, fs * 0.15, ink);
    strokeAA(c, fx + fs * 0.40, fy + fs * 0.73, fx + fs * 0.79, fy + fs * 0.30, fs * 0.15, ink);
}

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn rmdir(path: [*:0]const u8) c_int;

pub const NoteWidget = struct {
    pub const NOTE_MAX: usize = 4095;
    pub const MAX_WRAP_LINES: usize = NOTE_MAX + 2;
    pub const MAX_PAGES: u8 = 9;
    /// Public — cardSizeFor measures the card from these.
    pub const NOTE_W: i64 = 250;
    /// Cadence while editing (caret blink + autosave) or while × waits for
    /// its confirming click. Otherwise nothing changes on its own — the
    /// folder watch wakes the card — so Widget.intervalMs drops it to 60 s.
    pub const interval_ms: i64 = 500;
    pub const idle_interval_ms: i64 = 60_000;

    /// +1: reads take one byte past the cap to spot an oversized file.
    text_buf: [NOTE_MAX + 1]u8 = undefined,
    text_len: usize = 0,
    /// The open note's file (NUL-terminated).
    path_buf: [320]u8 = undefined,
    path_len: usize = 0,
    /// The notes folder.
    dir_buf: [300]u8 = undefined,
    dir_len: usize = 0,
    /// File numbers (noteN.txt) of the notes there are, ascending.
    pages: [MAX_PAGES]u8 = undefined,
    page_count: usize = 0,
    /// File number of the open note.
    slot: u8 = 1,
    /// The open note's file is bigger than NOTE_MAX: shown cut off, never
    /// edited or saved.
    read_only: bool = false,
    /// Byte offset of the caret while editing.
    caret: usize = 0,
    editing: bool = false,
    dirty: bool = false,
    /// First wrapped line shown at the top of the text area.
    scroll: usize = 0,
    /// Horizontal goal kept across Up/Down (like a normal editor).
    desired_x: i64 = 0,
    blink_on: bool = true,
    /// monoMs() of the last keyed change — autosave cadence source.
    last_change_ms: i64 = 0,
    /// inotify watch on the folder (-1 = none yet; tick retries).
    notify_fd: posix.fd_t = -1,
    /// monoMs() deadline for the confirming click on × (0 = not armed).
    delete_armed_until: i64 = 0,
    /// Set when the open note changed; the host saves notes_page.
    page_changed: bool = false,

    pub fn path(self: *const NoteWidget) [:0]const u8 {
        return self.path_buf[0..self.path_len :0];
    }

    pub fn text(self: *const NoteWidget) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    fn dir(self: *const NoteWidget) []const u8 {
        return self.dir_buf[0..self.dir_len];
    }

    pub fn armed(self: *const NoteWidget) bool {
        return self.delete_armed_until != 0;
    }

    fn disarm(self: *NoteWidget) void {
        self.delete_armed_until = 0;
    }

    fn canAdd(self: *const NoteWidget) bool {
        return self.page_count < MAX_PAGES;
    }

    /// × shows when there's something to delete: another note, or text.
    fn canDelete(self: *const NoteWidget) bool {
        return self.page_count > 1 or self.text_len > 0;
    }

    fn slotPath(self: *const NoteWidget, slot: u8, buf: []u8) ?[:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{s}/note{d}.txt", .{ self.dir(), slot }) catch null;
    }

    fn hasPage(self: *const NoteWidget, slot: u8) bool {
        return std.mem.indexOfScalar(u8, self.pages[0..self.page_count], slot) != null;
    }

    fn pageIndex(self: *const NoteWidget) usize {
        return std.mem.indexOfScalar(u8, self.pages[0..self.page_count], self.slot) orelse 0;
    }

    /// Points the card at the notes folder, opens note `slot` (the one
    /// that was open last time; the first note there is if it's gone) and
    /// starts watching the folder.
    pub fn configure(self: *NoteWidget, notes_dir: []const u8, slot: u8) void {
        if (notes_dir.len == 0 or notes_dir.len > self.dir_buf.len) return;
        @memcpy(self.dir_buf[0..notes_dir.len], notes_dir);
        self.dir_len = notes_dir.len;
        const want: u8 = if (slot >= 1 and slot <= MAX_PAGES) slot else 1;
        _ = self.scanPages(null);
        const first = if (self.hasPage(want) or self.page_count == 0) want else self.pages[0];
        self.loadPage(first);
        _ = self.scanPages(first);
        self.editing = false;
        self.armWatch();
        logging.step("notes: {d} note(s) in {s}, note{d} open ({d} bytes{s})", .{
            self.page_count, self.dir(), self.slot, self.text_len, if (self.read_only) ", read-only" else "",
        });
    }

    /// Rebuilds the note list from the noteN.txt files in the folder, plus
    /// `keep` (the open note, which may not be saved yet). True when the
    /// list changed.
    fn scanPages(self: *NoteWidget, keep: ?u8) bool {
        var mask: u16 = 0;
        var pb: [340]u8 = undefined;
        var s: u8 = 1;
        while (s <= MAX_PAGES) : (s += 1) {
            const p = self.slotPath(s, &pb) orelse continue;
            if (access(p.ptr, 0) == 0) mask |= @as(u16, 1) << @intCast(s);
        }
        if (keep) |k| mask |= @as(u16, 1) << @intCast(k);
        var fresh: [MAX_PAGES]u8 = undefined;
        var n: usize = 0;
        s = 1;
        while (s <= MAX_PAGES) : (s += 1) {
            if (mask & (@as(u16, 1) << @intCast(s)) != 0) {
                fresh[n] = s;
                n += 1;
            }
        }
        const changed = n != self.page_count or !std.mem.eql(u8, fresh[0..n], self.pages[0..self.page_count]);
        @memcpy(self.pages[0..n], fresh[0..n]);
        self.page_count = n;
        return changed;
    }

    /// Opens note `slot`: its path, and its text from disk (empty when the
    /// file doesn't exist yet).
    fn loadPage(self: *NoteWidget, slot: u8) void {
        self.slot = slot;
        self.caret = 0;
        self.scroll = 0;
        self.dirty = false;
        self.last_change_ms = 0;
        self.desired_x = 0;
        const p = self.slotPath(slot, &self.path_buf) orelse {
            self.path_len = 0;
            self.text_len = 0;
            self.read_only = false;
            return;
        };
        self.path_len = p.len;
        const n = readFileInto(self.path(), &self.text_buf);
        self.read_only = n > NOTE_MAX;
        self.text_len = @min(n, NOTE_MAX);
        self.caret = self.text_len;
    }

    /// Save, stop editing and drop a pending delete — before the open note
    /// changes.
    fn leavePage(self: *NoteWidget) void {
        self.commit();
        self.endEditing();
        self.disarm();
    }

    /// Opens the note at tab position `idx`.
    fn switchToIndex(self: *NoteWidget, idx: usize) void {
        if (idx >= self.page_count) return;
        const target = self.pages[idx];
        if (target == self.slot) return;
        self.leavePage();
        self.loadPage(target);
        // An empty note that was never saved has no file: it drops out here.
        _ = self.scanPages(self.slot);
        self.page_changed = true;
    }

    /// Opens a new, empty note and starts editing it. Its file appears with
    /// the first save, so a new note left empty simply goes away.
    fn newPage(self: *NoteWidget) bool {
        if (!self.canAdd()) return false;
        var top: u8 = 0;
        for (self.pages[0..self.page_count]) |p| top = @max(top, p);
        var slot: u8 = top + 1;
        if (slot > MAX_PAGES) {
            slot = 1;
            while (slot <= MAX_PAGES and self.hasPage(slot)) slot += 1;
            if (slot > MAX_PAGES) return false;
        }
        self.leavePage();
        self.loadPage(slot);
        _ = self.scanPages(self.slot);
        self.editing = true;
        self.blink_on = true;
        self.page_changed = true;
        return true;
    }

    /// Deletes the open note: saves it, moves its file to .last-deleted.txt
    /// (one level of undo, by hand), and opens a neighbour. The last note
    /// left just becomes empty.
    fn deletePage(self: *NoteWidget) void {
        self.leavePage();
        if (self.path_len > 0) {
            var bb: [340]u8 = undefined;
            if (std.fmt.bufPrintZ(&bb, "{s}/.last-deleted.txt", .{self.dir()})) |bak| {
                // Fails harmlessly for a note that was never saved.
                _ = std.c.rename(self.path().ptr, bak.ptr);
            } else |_| {}
        }
        const idx = self.pageIndex();
        if (self.page_count > 1) {
            const next_idx = if (idx + 1 < self.page_count) idx + 1 else idx - 1;
            self.loadPage(self.pages[next_idx]);
        } else {
            self.loadPage(self.slot); // file moved away: reads empty
        }
        _ = self.scanPages(self.slot);
        self.page_changed = true;
        logging.step("notes: deleted a note, note{d} open", .{self.slot});
    }

    /// Ticks or unticks the checkbox of the hard line starting at `ls`
    /// (same length either way, so the caret and layout don't move) and
    /// saves right away.
    fn toggleCheck(self: *NoteWidget, ls: usize) bool {
        if (self.read_only) return false;
        const k = noteLineKind(self.text()[ls..logicalEnd(self.text(), ls)]);
        if (k.kind != .todo and k.kind != .done) return false;
        self.text_buf[ls + 3] = if (k.kind == .todo) 'x' else ' ';
        self.dirty = true;
        self.commit();
        return true;
    }

    /// Persist the text if it changed (tmp file + rename). Called on edit
    /// release — Esc, focus leave, click elsewhere, a note switch.
    pub fn commit(self: *NoteWidget) void {
        if (self.write()) {
            logging.step("notes: saved {d} bytes to {s}", .{ self.text_len, self.path() });
        }
    }

    /// Leave editing: hide the caret, drop the view back to the top.
    pub fn endEditing(self: *NoteWidget) void {
        self.editing = false;
        self.blink_on = true;
        self.scroll = 0;
    }

    /// Cadence tick: expire an unconfirmed ×, retry a missing folder watch,
    /// and while editing flip the caret blink and autosave a typing pause.
    pub fn tick(self: *NoteWidget) bool {
        var changed = false;
        const now = monoMs();
        if (self.delete_armed_until != 0 and now >= self.delete_armed_until) {
            self.delete_armed_until = 0;
            changed = true;
        }
        if (self.notify_fd < 0 and self.dir_len > 0) {
            self.armWatch();
            if (self.notify_fd >= 0 and self.refresh()) changed = true;
        }
        if (!self.editing) return changed;
        self.blink_on = !self.blink_on;
        if (now - self.last_change_ms > NOTE_AUTOSAVE_MS) _ = self.write();
        return true;
    }

    /// One nonblocking cloexec inotify watch on the notes folder.
    fn armWatch(self: *NoteWidget) void {
        if (self.notify_fd >= 0 or self.dir_len == 0) return;
        var zb: [301]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zb, "{s}", .{self.dir()}) catch return;
        const fd: posix.fd_t = @intCast(inotify_init1(INOTIFY_FLAGS));
        if (fd < 0) return;
        if (inotify_add_watch(fd, z.ptr, IN_WATCH_MASK) < 0) {
            _ = posix.system.close(fd);
            return;
        }
        self.notify_fd = fd;
    }

    /// The folder changed: drain the events, then refresh. True when the
    /// card looks different.
    pub fn onNotify(self: *NoteWidget) bool {
        var any = false;
        var buf: [4096]u8 align(4) = undefined;
        while (true) {
            const n = posix.read(self.notify_fd, &buf) catch break;
            if (n == 0) break;
            any = true;
        }
        if (!any) return false;
        return self.refresh();
    }

    /// Re-reads the note list, and the open note when its file changed on
    /// disk. Never while editing or holding unsaved text: the edit wins and
    /// its next save replaces the file. (Our own saves land here too and
    /// compare equal, so they don't repaint.)
    fn refresh(self: *NoteWidget) bool {
        var changed = self.scanPages(self.slot);
        if (self.editing or self.dirty or self.path_len == 0) return changed;
        var fresh: [NOTE_MAX + 1]u8 = undefined;
        const n = readFileInto(self.path(), &fresh);
        const len = @min(n, NOTE_MAX);
        const ro = n > NOTE_MAX;
        if (len != self.text_len or ro != self.read_only or !std.mem.eql(u8, fresh[0..len], self.text())) {
            @memcpy(self.text_buf[0..len], fresh[0..len]);
            self.text_len = len;
            self.read_only = ro;
            self.caret = len;
            changed = true;
        }
        return changed;
    }

    /// Every keyed change re-adds the dirty flag and wakes the fence.
    fn markChanged(self: *NoteWidget) void {
        self.dirty = true;
        self.last_change_ms = monoMs();
        self.blink_on = true;
    }

    /// Save-on-dirty: returns true when a write actually happened.
    fn write(self: *NoteWidget) bool {
        if (!self.dirty) return false;
        self.dirty = false;
        if (self.path_len == 0) return false; // unconfigured (unit tests) — nothing to persist
        if (self.read_only) return false; // never truncate an oversized file
        return writeFileAtomicZ(self.path(), self.text());
    }

    // --- caret editing (pure — the host feeds keys, we move bytes) --------

    fn insertCp(self: *NoteWidget, cp: u21) bool {
        var enc: [4]u8 = undefined;
        const n = utf8Encode(cp, &enc);
        if (self.text_len + n > NOTE_MAX) return false;
        // Shift the tail up by n (memmove semantics: dest precedes source).
        var k = self.text_len;
        while (k > self.caret) : (k -= 1) {
            self.text_buf[k + n - 1] = self.text_buf[k - 1];
        }
        @memcpy(self.text_buf[self.caret..][0..n], enc[0..n]);
        self.caret += n;
        self.text_len += n;
        return true;
    }

    /// Byte offset just before the codepoint ending at `at`.
    fn prevBoundary(self: *const NoteWidget, at: usize) usize {
        var p = at;
        while (p > 0 and (self.text_buf[p - 1] & 0xC0) == 0x80) p -= 1; // back over continuation bytes
        if (p > 0) return p - 1;
        return 0;
    }

    /// Byte offset just after the codepoint starting at `at`.
    fn nextBoundary(self: *const NoteWidget, at: usize) usize {
        var i = at;
        _ = nextUtf8Codepoint(self.text(), &i);
        return i;
    }

    fn backspace(self: *NoteWidget) bool {
        if (self.caret == 0) return false;
        const lo = self.prevBoundary(self.caret);
        // Pull the tail left (dest is before source — forward copy is safe).
        var k = self.caret;
        while (k < self.text_len) : (k += 1) {
            self.text_buf[lo + (k - self.caret)] = self.text_buf[k];
        }
        self.text_len -= self.caret - lo;
        self.caret = lo;
        return true;
    }

    fn deleteForward(self: *NoteWidget) bool {
        if (self.caret >= self.text_len) return false;
        const hi = self.nextBoundary(self.caret);
        var k = hi;
        while (k < self.text_len) : (k += 1) {
            self.text_buf[self.caret + (k - hi)] = self.text_buf[k];
        }
        self.text_len -= hi - self.caret;
        return true;
    }

    fn moveLeft(self: *NoteWidget) bool {
        if (self.caret == 0) return false;
        self.caret = self.prevBoundary(self.caret);
        return true;
    }

    fn moveRight(self: *NoteWidget) bool {
        if (self.caret >= self.text_len) return false;
        self.caret = self.nextBoundary(self.caret);
        return true;
    }

    fn caretX(self: *const NoteWidget, measure: anytype, lines: []const LayoutLine, li: usize, caret: usize) i64 {
        return advSlice(measure, self.text()[lines[li].start..caret]);
    }

    fn moveUpInner(self: *NoteWidget, measure: anytype, lines: []const LayoutLine, count: usize) bool {
        if (self.caret == 0) return false;
        const li = caretLine(lines, count, self.caret);
        if (li == 0) return false;
        const l = lines[li - 1];
        self.caret = offsetNear(measure, self.text()[l.start..l.end], self.desired_x) + l.start;
        return true;
    }

    fn moveDownInner(self: *NoteWidget, measure: anytype, lines: []const LayoutLine, count: usize) bool {
        if (self.caret >= self.text_len) return false;
        const li = caretLine(lines, count, self.caret);
        if (li + 1 >= count) return false;
        const l = lines[li + 1];
        self.caret = offsetNear(measure, self.text()[l.start..l.end], self.desired_x) + l.start;
        return true;
    }

    /// Scroll so the caret's wrapped line stays among the visible ones, and
    /// keep the stored scroll honest when the text shrank under it. `vis`
    /// is the card's current visible-line count (grows when resized).
    fn keepVisible(self: *NoteWidget, lines: []const LayoutLine, count: usize, vis: usize) void {
        if (count > vis and self.scroll > count - vis) self.scroll = count - vis;
        if (count <= vis) self.scroll = 0;
        const li = caretLine(lines, count, self.caret);
        if (li < self.scroll) self.scroll = li;
        if (li >= self.scroll + vis) self.scroll = li - vis + 1;
    }

    /// Feed one compositor key event. `utf32` comes from xkb (already
    /// unmapped on non-printables); `keycode` is the raw evdev code for the
    /// editing specials (Backspace etc.) that have no UTF-32 equivalent.
    /// Returns what the host should do with the key afterward.
    pub const KeyResult = enum { ignored, handled, exited };

    pub fn keyPress(self: *NoteWidget, measure: anytype, max_w: i64, vis: usize, keycode: u32, utf32: u32) KeyResult {
        if (keycode == KEY_ESC) {
            self.commit();
            self.endEditing();
            self.disarm();
            return .exited;
        }
        if (self.read_only) return .ignored;
        self.disarm();
        var lines_arr: [MAX_WRAP_LINES]LayoutLine = undefined;
        const lines = &lines_arr;
        const count = wrapLines(measure, self.text(), max_w, lines);
        const handled = switch (keycode) {
            KEY_BACKSPACE => self.backspace(),
            KEY_DELETE => self.deleteForward(),
            KEY_ENTER, KEY_KP_ENTER => self.insertCp('\n'),
            KEY_LEFT => self.moveLeft(),
            KEY_RIGHT => self.moveRight(),
            KEY_UP => self.moveUpInner(measure, lines, count),
            KEY_DOWN => self.moveDownInner(measure, lines, count),
            KEY_HOME => blk: {
                self.caret = lines[caretLine(lines, count, self.caret)].start;
                break :blk true;
            },
            KEY_END => blk: {
                self.caret = lines[caretLine(lines, count, self.caret)].end;
                break :blk true;
            },
            else => blk: {
                // Printable text only: control magnitudes (C0) and DEL (0x7F)
                // never insert — xkb hands them back as 0 anyway.
                if (utf32 == 0 or utf32 < 0x20 or utf32 == 0x7F) return .ignored;
                break :blk self.insertCp(@intCast(utf32));
            },
        };
        if (!handled) return .ignored;
        self.markChanged();
        if (keycode != KEY_UP and keycode != KEY_DOWN) {
            const li = caretLine(lines, count, self.caret);
            self.desired_x = self.caretX(measure, lines, li, self.caret);
        }
        self.keepVisible(lines, count, vis);
        return .handled;
    }

    /// The text's first shown wrapped line for `count` lines in `vis` rows.
    fn shownScroll(self: *const NoteWidget, count: usize, vis: usize) usize {
        if (count <= vis) return 0;
        return @min(self.scroll, count - vis);
    }

    /// A click inside the card. Header controls act on notes; a checkbox
    /// (while not editing) ticks; anywhere else in the text starts editing
    /// or moves the caret to the click. The host reads `editing` afterwards
    /// to take or hand back the keyboard, and `page_changed` to save which
    /// note is open.
    pub fn clickAt(self: *NoteWidget, r: Rect, font: *font_mod.Font, px: i32, py: i32) void {
        const fm = FontMeasure{ .font = font };
        const lh = lineH(font);
        const left: i64 = @as(i64, r.x) + CARD_PAD;
        const top: i64 = @as(i64, r.y) + CARD_PAD;
        const inner_w: i64 = @as(i64, @intCast(r.w)) - 2 * CARD_PAD;
        const head_h = noteHeaderH(lh);
        const rel_x = @as(i64, px) - left;

        if (notes_layout.tabs and @as(i64, py) < top + head_h) {
            const h = noteHeaderLayout(fm, inner_w, self.page_count, self.canAdd(), self.canDelete());
            const hit = noteHeaderHit(h, self.page_count, rel_x);
            if (self.armed()) {
                // While × waits, the header only asks "Delete this note?":
                // × again confirms, anything else cancels.
                if (hit == .delete) self.deletePage() else self.disarm();
                return;
            }
            switch (hit) {
                .delete => {
                    self.commit();
                    self.endEditing();
                    self.delete_armed_until = monoMs() + NOTE_DELETE_ARM_MS;
                },
                .plus => {
                    _ = self.newPage();
                },
                .tab => |i| self.switchToIndex(i),
                .prev => self.switchToIndex((self.pageIndex() + self.page_count - 1) % self.page_count),
                .next => self.switchToIndex((self.pageIndex() + 1) % self.page_count),
                .none => {},
            }
            return;
        }

        self.disarm();
        const vis = noteVisLines(@as(i64, @intCast(r.h)), lh);
        var lines: [MAX_WRAP_LINES]LayoutLine = undefined;
        const count = wrapLines(fm, self.text(), inner_w, &lines);
        const scroll = self.shownScroll(count, vis);
        var rel_y = @as(i64, py) - (top + head_h);
        rel_y = std.math.clamp(rel_y, 0, @as(i64, @intCast(vis)) * lh - 1); // padding clicks → nearest line
        var li = scroll + @as(usize, @intCast(@divTrunc(rel_y, lh)));
        if (li >= count) li = count - 1;
        const l = lines[li];

        if (!self.editing and notes_layout.checklists) {
            const ls = logicalStart(self.text(), l.start);
            if (ls == l.start) {
                const k = noteLineKind(self.text()[ls..logicalEnd(self.text(), ls)]);
                if ((k.kind == .todo or k.kind == .done) and rel_x >= 0 and
                    rel_x < advSlice(fm, self.text()[ls .. ls + k.prefix]))
                {
                    _ = self.toggleCheck(ls);
                    return;
                }
            }
        }
        if (self.read_only) return;

        self.editing = true;
        self.blink_on = true;
        self.scroll = scroll;
        const rx = @max(rel_x, 0);
        self.caret = offsetNear(fm, self.text()[l.start..l.end], rx) + l.start;
        const line_w = advSlice(fm, self.text()[l.start..l.end]);
        self.desired_x = @min(rx, line_w);
    }

    /// Mouse wheel over the card: scroll the text by `delta` lines (positive
    /// = down). True when the view moved.
    pub fn scrollBy(self: *NoteWidget, r: Rect, font: *font_mod.Font, delta: i32) bool {
        const lh = lineH(font);
        var lines: [MAX_WRAP_LINES]LayoutLine = undefined;
        const count = wrapLines(FontMeasure{ .font = font }, self.text(), @as(i64, @intCast(r.w)) - 2 * CARD_PAD, &lines);
        const vis = noteVisLines(@as(i64, @intCast(r.h)), lh);
        if (count <= vis) return false;
        const max_scroll: i64 = @intCast(count - vis);
        const cur: i64 = @intCast(self.shownScroll(count, vis));
        const want: usize = @intCast(std.math.clamp(cur + delta, 0, max_scroll));
        if (want == self.scroll) return false;
        self.scroll = want;
        return true;
    }

    fn paintHeader(self: *const NoteWidget, c: Canvas, left: i64, top: i64, inner_w: i64, lh: i64) void {
        const t = c.theme.text_color;
        const accent = c.theme.border_color;
        const baseline = top + c.font.ascentPx();
        const h = noteHeaderLayout(FontMeasure{ .font = c.font }, inner_w, self.page_count, self.canAdd(), self.canDelete());
        c.fillRect(left, top + lh + @divTrunc(NOTE_HEADER_GAP, 2), @intCast(@max(inner_w, 0)), 1, dim(t, 0x22));
        if (self.armed()) {
            _ = c.drawText(left, baseline, "Delete this note?", c.theme.holiday_color);
            if (h.del_x) |dx| drawNoteButton(c, left + dx, top, h.btn_w, lh, "\u{00D7}", .danger);
            return;
        }
        if (self.page_count <= 1) {
            _ = c.drawText(left, baseline, "Notes", accent);
        } else if (h.tabs) {
            const cur = self.pageIndex();
            const step = h.btn_w + NOTE_TAB_GAP;
            for (0..self.page_count) |i| {
                var nb: [4]u8 = undefined;
                const label = std.fmt.bufPrint(&nb, "{d}", .{i + 1}) catch "";
                drawNoteButton(c, left + @as(i64, @intCast(i)) * step, top, h.btn_w, lh, label, if (i == cur) .active else .normal);
            }
        } else {
            drawNoteButton(c, left + h.prev_x, top, h.btn_w, lh, "\u{2039}", .normal);
            var lb: [8]u8 = undefined;
            const label = std.fmt.bufPrint(&lb, "{d}/{d}", .{ self.pageIndex() + 1, self.page_count }) catch "";
            const lw = c.textWidth(label);
            _ = c.drawText(left + h.label_x + @divTrunc(h.label_w - lw, 2), baseline, label, accent);
            drawNoteButton(c, left + h.next_x, top, h.btn_w, lh, "\u{203A}", .normal);
        }
        if (h.plus_x) |px| drawNoteButton(c, left + px, top, h.btn_w, lh, "+", .normal);
        if (h.del_x) |dx| drawNoteButton(c, left + dx, top, h.btn_w, lh, "\u{00D7}", .normal);
    }

    /// One wrapped row with its line's decoration: a checkbox or bullet in
    /// place of the marker on the line's first row, struck-through dim
    /// text for ticked items, the accent colour for headings.
    fn paintDecoratedRow(self: *const NoteWidget, c: Canvas, x: i64, baseline: i64, row_top: i64, lh: i64, l: LayoutLine) void {
        const txt = self.text();
        const fm = FontMeasure{ .font = c.font };
        const t = c.theme.text_color;
        const accent = c.theme.border_color;
        const ls = logicalStart(txt, l.start);
        const k = noteLineKind(txt[ls..logicalEnd(txt, ls)]);
        var from = l.start;
        var tx = x;
        if (ls == l.start and k.prefix > 0 and l.end >= l.start + k.prefix) {
            switch (k.kind) {
                .todo, .done => drawCheckbox(c, x, row_top, lh, k.kind == .done),
                .bullet => {
                    const bw = c.textWidth("\u{2022}");
                    _ = c.drawText(x + @divTrunc(fm.advance('-') - bw, 2), baseline, "\u{2022}", accent);
                },
                .heading, .plain => {},
            }
            from = l.start + k.prefix;
            tx = x + advSlice(fm, txt[l.start..from]);
        }
        if (l.end <= from) return;
        const seg = txt[from..l.end];
        switch (k.kind) {
            .done => {
                const ink = dim(t, 0x77);
                const w = c.drawText(tx, baseline, seg, ink);
                c.fillRect(tx, baseline - @divTrunc(@as(i64, c.font.ascentPx()) * 3, 10), @intCast(@max(w, 0)), 1, ink);
            },
            .heading => {
                _ = c.drawText(tx, baseline, seg, accent);
            },
            else => {
                _ = c.drawText(tx, baseline, seg, t);
            },
        }
    }

    pub fn paint(self: *const NoteWidget, c: Canvas, r: Rect) void {
        const rx: i64 = r.x;
        const ry: i64 = r.y;
        const lh = lineH(c.font);
        const ascent: i64 = c.font.ascentPx();
        const left = rx + CARD_PAD;
        const inner_w: i64 = @as(i64, @intCast(r.w)) - 2 * CARD_PAD;
        const t = c.theme.text_color;
        const accent = c.theme.border_color;
        if (notes_layout.tabs) self.paintHeader(c, left, ry + CARD_PAD, inner_w, lh);
        const body_top = ry + CARD_PAD + noteHeaderH(lh);

        var lines: [MAX_WRAP_LINES]LayoutLine = undefined;
        const count = wrapLines(FontMeasure{ .font = c.font }, self.text(), inner_w, &lines);
        var vis = noteVisLines(@as(i64, @intCast(r.h)), lh);
        if (self.read_only and vis > 1) vis -= 1; // last row: the read-only notice
        const scroll = self.shownScroll(count, vis);
        const body_h: i64 = @as(i64, @intCast(vis)) * lh;

        const decorate = notes_layout.checklists and !self.editing;
        const rows = @min(vis, count);
        for (0..rows) |row| {
            const l = lines[scroll + row];
            const row_top = body_top + @as(i64, @intCast(row)) * lh;
            if (decorate) {
                self.paintDecoratedRow(c, left, row_top + ascent, row_top, lh, l);
            } else if (l.end > l.start) {
                _ = c.drawText(left, row_top + ascent, self.text()[l.start..l.end], t);
            }
        }

        if (self.text_len == 0 and !self.editing) {
            const hint = if (self.page_count > 1) "Empty note \u{2014} click to write" else "Click to write a note";
            _ = c.drawText(left, body_top + ascent, hint, dim(t, 0x66));
        }

        // Editing: an accent bar down the left margin.
        const margin = @divTrunc(CARD_PAD, 2);
        if (self.editing) c.fillRect(rx + margin - 1, body_top, 2, @intCast(body_h), dim(accent, 0xCC));

        // More text than fits: a thin scrollbar in the right margin.
        if (count > vis) {
            const sx = rx + @as(i64, @intCast(r.w)) - margin - 1;
            c.fillRect(sx, body_top, 2, @intCast(body_h), dim(t, 0x18));
            const thumb_h = @max(@divTrunc(body_h * @as(i64, @intCast(vis)), @as(i64, @intCast(count))), @divTrunc(lh, 2));
            const travel = body_h - thumb_h;
            const ty = body_top + @divTrunc(travel * @as(i64, @intCast(scroll)), @as(i64, @intCast(count - vis)));
            c.fillRect(sx, ty, 2, @intCast(thumb_h), dim(accent, 0xAA));
        }

        if (self.read_only) {
            var fit_buf: [96]u8 = undefined;
            const msg = fitText(c, "Too long to edit here (over 4 KB)", inner_w, &fit_buf);
            _ = c.drawText(left, body_top + body_h + ascent, msg, dim(c.theme.holiday_color, 0xDD));
        }

        // Blinking caret at its byte offset within the visible wrapped line.
        if (self.editing and self.blink_on) {
            const li = caretLine(&lines, count, self.caret);
            if (li >= scroll and li < scroll + vis) {
                const caret_x = left + advSlice(FontMeasure{ .font = c.font }, self.text()[lines[li].start..self.caret]);
                const top = body_top + 1 + @as(i64, @intCast(li - scroll)) * lh;
                c.fillRect(caret_x, top, 2, @intCast(lh - 2), t);
            }
        }
    }
};

test "notes: pages on disk — new, switch, delete, refresh" {
    const t = std.testing;
    var dbuf: [96]u8 = undefined;
    const d = try std.fmt.bufPrintZ(&dbuf, "/tmp/perihelion-notes-test-{d}", .{std.c.getpid()});
    _ = posix.system.mkdir(d.ptr, 0o755);
    defer {
        var cb: [128]u8 = undefined;
        for ([_][]const u8{ "note1.txt", "note2.txt", "note3.txt", ".last-deleted.txt" }) |f| {
            if (std.fmt.bufPrintZ(&cb, "{s}/{s}", .{ d, f })) |cp| {
                _ = unlink(cp.ptr);
            } else |_| {}
        }
        _ = rmdir(d.ptr);
    }
    var pb: [128]u8 = undefined;
    try t.expect(writeFileAtomicZ(try std.fmt.bufPrintZ(&pb, "{s}/note1.txt", .{d}), "first"));
    try t.expect(writeFileAtomicZ(try std.fmt.bufPrintZ(&pb, "{s}/note3.txt", .{d}), "- [ ] third"));

    var n = NoteWidget{};
    n.configure(d, 3); // the remembered note is open
    defer {
        if (n.notify_fd >= 0) _ = posix.system.close(n.notify_fd);
    }
    try t.expectEqualSlices(u8, &[_]u8{ 1, 3 }, n.pages[0..n.page_count]);
    try t.expectEqual(@as(u8, 3), n.slot);
    try t.expectEqualSlices(u8, "- [ ] third", n.text());

    // Ticking a checkbox saves straight away.
    try t.expect(n.toggleCheck(0));
    var rb: [64]u8 = undefined;
    try t.expectEqualSlices(u8, "- [x] third", rb[0..readFileInto(n.path(), &rb)]);

    // A new note takes the next number and has no file until it's saved;
    // left empty, it drops out when another note opens.
    try t.expect(n.newPage());
    try t.expectEqual(@as(u8, 4), n.slot);
    try t.expect(n.editing);
    try t.expectEqual(@as(usize, 3), n.page_count);
    n.switchToIndex(0);
    try t.expectEqual(@as(u8, 1), n.slot);
    try t.expectEqualSlices(u8, &[_]u8{ 1, 3 }, n.pages[0..n.page_count]);
    try t.expectEqualSlices(u8, "first", n.text());

    // Another program writes note2.txt and rewrites note1: both show up.
    try t.expect(writeFileAtomicZ(try std.fmt.bufPrintZ(&pb, "{s}/note2.txt", .{d}), "second"));
    try t.expect(writeFileAtomicZ(try std.fmt.bufPrintZ(&pb, "{s}/note1.txt", .{d}), "first, edited"));
    try t.expect(n.refresh());
    try t.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, n.pages[0..n.page_count]);
    try t.expectEqualSlices(u8, "first, edited", n.text());
    try t.expect(!n.refresh()); // nothing new: no repaint

    // ...but an edit in progress is never overwritten.
    n.editing = true;
    n.text_len = 0;
    n.caret = 0;
    try t.expect(n.insertCp('z'));
    n.dirty = true;
    try t.expect(writeFileAtomicZ(try std.fmt.bufPrintZ(&pb, "{s}/note1.txt", .{d}), "from elsewhere"));
    _ = n.refresh();
    try t.expectEqualSlices(u8, "z", n.text());
    n.endEditing();

    // Delete saves, keeps a copy, and opens the neighbour.
    n.deletePage();
    try t.expectEqualSlices(u8, &[_]u8{ 2, 3 }, n.pages[0..n.page_count]);
    try t.expectEqual(@as(u8, 2), n.slot);
    const bak = try std.fmt.bufPrintZ(&pb, "{s}/.last-deleted.txt", .{d});
    try t.expectEqualSlices(u8, "z", rb[0..readFileInto(bak, &rb)]);
}

test "notes: an oversized file is read-only and never written" {
    const t = std.testing;
    var dbuf: [96]u8 = undefined;
    const d = try std.fmt.bufPrintZ(&dbuf, "/tmp/perihelion-notes-big-{d}", .{std.c.getpid()});
    _ = posix.system.mkdir(d.ptr, 0o755);
    var pb: [128]u8 = undefined;
    const p = try std.fmt.bufPrintZ(&pb, "{s}/note1.txt", .{d});
    defer {
        _ = unlink(p.ptr);
        _ = rmdir(d.ptr);
    }
    const big = [_]u8{'x'} ** (NoteWidget.NOTE_MAX + 10);
    try t.expect(writeFileAtomicZ(p, &big));
    var n = NoteWidget{};
    n.configure(d, 1);
    defer {
        if (n.notify_fd >= 0) _ = posix.system.close(n.notify_fd);
    }
    try t.expect(n.read_only);
    try t.expectEqual(NoteWidget.NOTE_MAX, n.text_len);
    try t.expectEqual(NoteWidget.KeyResult.ignored, n.keyPress(FixedAdv{}, 200, 6, 999, 'a'));
    n.dirty = true;
    n.commit();
    var rb: [NoteWidget.NOTE_MAX + 20]u8 = undefined;
    try t.expectEqual(@as(usize, big.len), readFileInto(p, &rb));
}

/// Mode-independent font advance — the layout math reads glyph advances
/// through this so the same code runs in painting and in tests (tests use a
/// fixed-advance stand-in via `measure: anytype`).
// --- desktop shortcuts (~/Desktop as real desktop icons) -------------------
//
// Scans Type=Application .desktop files and shows a self-arranging 2-column
// grid of 44px icons on the same bottom-layer surface the widgets paint —
// above the wallpaper, behind windows, exactly like a classic desktop.
// Single click selects, double click launches, right click opens a small
// Open/Remove popup. The folder is watched with inotify, so files the app
// drawer's "Add to desktop" (or Steam, or a file manager) drop there appear
// and disappear live, never needing a restart.
//
// Icon art reuses the bar's resolver (icontheme.*): an absolute Icon= path
// is used straight from disk, steam_app_<id> names reach the Steam library
// caches, everything else goes through the freedesktop theme walk (user
// flatpak exports and user icon dirs first, then hicolor). No hit means a
// letter chip, mirroring the app drawer's fallback tile.
//
// The grid is the classic "auto-arrange" mode: items sort alphabetically and
// flow into the columns; free per-icon dragging (the reference shell's
// desktop_icons_layout.txt) is a v2 idea. The grid itself Ctrl+drags like
// every other widget; the corner-resize grip is disabled since its size is
// content-driven.

/// inotify bits (sys/inotify.h), bound by hand like the rest of libc here.
/// The watch covers exactly what can change a grid: entry add/delete, both
/// halves of a rename, a finished content write, and an mtime bump.
const IN_ATTRIB: u32 = 0x4;
const IN_CLOSE_WRITE: u32 = 0x8;
const IN_MOVED_FROM: u32 = 0x40;
const IN_MOVED_TO: u32 = 0x80;
const IN_CREATE: u32 = 0x100;
const IN_DELETE: u32 = 0x200;
const IN_WATCH_MASK: u32 = IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE;

extern "c" fn inotify_init1(flags: c_int) c_int;
extern "c" fn inotify_add_watch(fd: c_int, path: [*:0]const u8, mask: u32) c_int;
extern "c" fn fork() c_int;
extern "c" fn setsid() i32;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;

// IN_NONBLOCK | IN_CLOEXEC (O_NONBLOCK, O_CLOEXEC)
const INOTIFY_FLAGS: c_int = 0o4000 | 0o2000000;

/// glibc's struct dirent64 (x86_64/Linux layout) + directory iteration —
/// the same declaration desktop_entries.zig and icontheme.zig use. Only
/// d_name (and d_type when it's populated) is read here.
const libc_dir = struct {
    const DT_DIR: u8 = 4;
    const Dirent = extern struct {
        d_ino: u64 = 0,
        d_off: i64 = 0,
        d_reclen: u16 = 0,
        d_type: u8 = 0,
        d_name: [256]u8 = undefined,
    };
    extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
    extern "c" fn readdir(dirp: *anyopaque) ?*const Dirent;
    extern "c" fn closedir(dirp: *anyopaque) c_int;
};

/// One desktop shortcut. Fixed buffers, zero lifetime juggling: every rescan
/// overwrites the list wholesale (items copy by value), pixels free first.
pub const DesktopItem = struct {
    name_buf: [ICON_NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    path_buf: [ICON_PATH_MAX]u8 = undefined,
    path_len: usize = 0,
    icon_buf: [ICON_PATH_MAX]u8 = undefined,
    icon_len: usize = 0,
    exec_buf: [ICON_EXEC_MAX]u8 = undefined,
    exec_len: usize = 0,
    cwd_buf: [ICON_PATH_MAX]u8 = undefined,
    cwd_len: usize = 0,
    terminal: bool = false,
    /// Decoded ARGB8888 square (ICON_PX², aspect-fit, icontheme.copyIntoIconBuffer
    /// layout — transparent where nothing painted). null = letter chip.
    pixels: ?[]u32 = null,

    pub fn name(self: *const DesktopItem) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn path(self: *const DesktopItem) []const u8 {
        return self.path_buf[0..self.path_len];
    }
    pub fn exec(self: *const DesktopItem) []const u8 {
        return self.exec_buf[0..self.exec_len];
    }
    pub fn cwd(self: *const DesktopItem) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }
    pub fn icon(self: *const DesktopItem) []const u8 {
        return self.icon_buf[0..self.icon_len];
    }
};

/// Copies `s` into a fixed buffer, truncating. Returns false when anything
/// was cut (callers treat critical fields as unlaunchable on truncation).
fn setStored(dst: []u8, dst_len: *usize, s: []const u8) bool {
    const n = @min(s.len, dst.len);
    @memcpy(dst[0..n], s[0..n]);
    dst_len.* = n;
    return s.len == n;
}

fn hasSuffix(s: []const u8, suffix: []const u8) bool {
    return s.len >= suffix.len and std.mem.eql(u8, s[s.len - suffix.len ..], suffix);
}

/// Parses one .desktop file body into `out`'s fixed buffers. Only the
/// [Desktop Entry] group matters — a later `[...]` header ends key parsing
/// (localized Name[xx] variants and action groups never leak in). Returns
/// false when the entry is not a launchable app: no [Desktop Entry], no
/// Exec=value, an overflowed critical buffer (path/exec), or a stripped
/// name that came out empty without a usable file stem.
pub fn parseDesktopFile(rec: *DesktopItem, raw: []const u8, dir: []const u8, file_name: []const u8) bool {
    rec.* = .{};

    var in_entry = false;
    var has_exec = false;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_entry) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Type")) {
            if (!std.mem.eql(u8, value, "Application")) return false;
        } else if (std.mem.eql(u8, key, "Name")) {
            if (!setStored(rec.name_buf[0..], &rec.name_len, value)) return false;
        } else if (std.mem.eql(u8, key, "Icon")) {
            if (!setStored(rec.icon_buf[0..], &rec.icon_len, value)) return false;
        } else if (std.mem.eql(u8, key, "Exec")) {
            if (!setStored(rec.exec_buf[0..], &rec.exec_len, value)) return false;
            has_exec = true;
        } else if (std.mem.eql(u8, key, "Path")) {
            if (!setStored(rec.cwd_buf[0..], &rec.cwd_len, value)) return false;
        } else if (std.mem.eql(u8, key, "Terminal")) {
            rec.terminal = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
        }
    }
    if (rec.name_len == 0) {
        // Localized files commonly lack an unqualified Name=; fall back to
        // the file stem. Still unusable when THAT is empty.
        const stem_end = if (hasSuffix(file_name, ".desktop")) file_name.len - ".desktop".len else file_name.len;
        if (stem_end == 0) return false;
        if (!setStored(rec.name_buf[0..], &rec.name_len, file_name[0..stem_end])) return false;
    }
    if (!has_exec or rec.exec_len == 0) return false;

    // The item's absolute path is what launch/remove acts on. A path too
    // long for a *launchable* item can't be truncated safely — drop it.
    if (!setStored(rec.path_buf[0..], &rec.path_len, dir)) return false;
    if (rec.path_len > 0 and rec.path_buf[rec.path_len - 1] != '/') {
        if (rec.path_len + 1 > ICON_PATH_MAX) return false;
        rec.path_buf[rec.path_len] = '/';
        rec.path_len += 1;
    }
    if (rec.path_len + file_name.len > ICON_PATH_MAX) return false;
    @memcpy(rec.path_buf[rec.path_len..][0..file_name.len], file_name);
    rec.path_len += file_name.len;
    return true;
}

/// Tokenizes a desktop Exec= value into `scratch`-backed argv. Honors the
/// spec's quoting (double, single, backslash-next) and drops field-code
/// material we can't satisfy without file/URL context (%f %F %u %U %i %c %k;
/// %% collapses to a literal %). Free-standing code tokens disappear
/// entirely; a token built from surrounding text with embedded codes keeps
/// its other characters. argv slices point into `scratch`; each is
/// NUL-terminated per token.
pub const ExecArgv = struct {
    argv: [ICON_ARGS_MAX][*:0]const u8 = undefined,
    argc: usize = 0,
};

/// One Exec= parse in flight: argv slots fill from a cursor over `scratch`,
/// so token bytes are compacted in place as quotes resolve.
const ExecCursor = struct {
    scratch: []u8,
    out: *ExecArgv,
    sp: usize = 0,
    tok_head: usize = 0,
    tok_len: usize = 0,
    /// False while the token has only contained dropped field-code bytes —
    /// such a token vanishes at the boundary instead of becoming "".
    tok_subst: bool = false,

    fn put(self: *ExecCursor, ch: u8) void {
        if (self.sp >= self.scratch.len) return; // overflow guard: drop
        self.scratch[self.sp] = ch;
        self.sp += 1;
        self.tok_len += 1;
        self.tok_subst = true;
    }

    /// Ends the current token at the next boundary: free-standing or
    /// empty tokens roll the scratch stick back and vanish; real tokens
    /// commit a NUL byte and take an argv slot.
    fn endToken(self: *ExecCursor) void {
        const commit = self.tok_len > 0 and self.tok_subst and
            self.out.argc < ICON_ARGS_MAX and self.sp < self.scratch.len;
        if (commit) {
            self.scratch[self.sp] = 0;
            self.out.argv[self.out.argc] = self.scratch[self.tok_head..self.sp :0].ptr;
            self.out.argc += 1;
            self.sp += 1;
        } else {
            self.sp = self.tok_head;
        }
        self.tok_head = self.sp;
        self.tok_len = 0;
        self.tok_subst = false;
    }
};

/// Tokenizes a desktop Exec= value into `scratch`-backed argv. Honors the
/// spec's quoting (double, single, backslash-next) and drops field-code
/// material we can't satisfy without file/URL context (%f %F %u %U %i %c %k;
/// %% collapses to a literal %). Free-standing code tokens disappear
/// entirely; a token built from surrounding text with embedded codes keeps
/// its other characters. argv slices point into `scratch`, each
/// NUL-terminated, so the array stays valid while `scratch` does.
pub fn parseExec(exec: []const u8, scratch: []u8) ExecArgv {
    var out = ExecArgv{};
    var cur = ExecCursor{ .scratch = scratch, .out = &out };
    var state: enum { normal, dquote, squote } = .normal;
    var i: usize = 0;
    while (i < exec.len) {
        const ch = exec[i];
        switch (state) {
            .normal => switch (ch) {
                ' ', '\t' => {
                    cur.endToken();
                    i += 1;
                },
                '"' => {
                    state = .dquote;
                    i += 1;
                },
                '\'' => {
                    state = .squote;
                    i += 1;
                },
                '\\' => {
                    // Out of quotes backslash escapes the next byte.
                    if (i + 1 < exec.len) {
                        cur.put(exec[i + 1]);
                        i += 2;
                    } else {
                        i += 1;
                    }
                },
                '%' => {
                    if (i + 1 < exec.len) {
                        const code = exec[i + 1];
                        if (code == '%') {
                            cur.put('%');
                            i += 2;
                        } else if (code == 'f' or code == 'F' or code == 'u' or
                            code == 'U' or code == 'i' or code == 'c' or code == 'k')
                        {
                            // A dropped field code contributes no bytes;
                            // the token closes empty at the boundary.
                            i += 2;
                        } else {
                            cur.put(ch); // unknown +%x: keep the % literal
                            i += 1;
                        }
                    } else {
                        cur.put(ch);
                        i += 1;
                    }
                },
                else => {
                    cur.put(ch);
                    i += 1;
                },
            },
            .dquote => switch (ch) {
                '"' => {
                    state = .normal;
                    i += 1;
                },
                '\\' => blk: {
                    // Inside double quotes the spec honors only these four
                    // escapes; any other backslash stays literal.
                    if (i + 1 < exec.len) switch (exec[i + 1]) {
                        '"', '\\', '$', '`' => {
                            cur.put(exec[i + 1]);
                            i += 2;
                            break :blk;
                        },
                        else => {},
                    };
                    cur.put('\\');
                    i += 1;
                },
                else => {
                    cur.put(ch);
                    i += 1;
                },
            },
            .squote => switch (ch) {
                '\'' => {
                    state = .normal;
                    i += 1;
                },
                else => {
                    cur.put(ch); // backslashes are literal in single quotes
                    i += 1;
                },
            },
        }
    }
    cur.endToken();
    return out;
}

pub const IconsWidget = struct {
    /// Grid rescan cadence. The inotify watch makes file events instant;
    /// this tick only re-arms a failed watch when ~/Desktop appears
    /// mid-session.
    pub const interval_ms: i64 = 5000;
    /// Two releases over the same cell inside this window launch.
    pub const dbl_click_ms: i64 = 500;
    pub const MENU_H: i64 = 2 * MENU_ROW_H + 14;
    pub const MENU_PAD: i64 = 7;

    gpa: std.mem.Allocator = undefined,
    dir_buf: [ICON_PATH_MAX]u8 = undefined,
    dir_len: usize = 0,
    items: [MAX_ICONS]DesktopItem = undefined,
    item_count: usize = 0,
    notify_fd: posix.fd_t = -1,
    hover: ?u16 = null,
    /// Selected icon; dropped automatically when a scan loses it.
    selected: ?u16 = null,
    last_click_idx: ?u16 = null,
    last_click_ms: i64 = 0,
    /// The Open/Remove popup, in tile-local coordinates, for `menu_item`'s row.
    menu_open: bool = false,
    menu_x: i64 = 0,
    menu_y: i64 = 0,
    menu_item: usize = 0,
    /// 0 = none, 1 = Open row, 2 = Remove row.
    menu_hover: u8 = 0,

    /// Desktop labels sit on the wallpaper, not on a card: theme text colors
    /// are tuned for card backgrounds and a dimmed copy of one reads dark and
    /// heavy over a dark wallpaper. The desktop convention everywhere else
    /// applies instead — near-white with a soft dark shadow behind it, so a
    /// label stays legible on any wallpaper.
    const label_color: u32 = 0xEAFFFFFF; // ~92% white
    const shadow_color: u32 = dim(0x000000, 100); // ~40% black

    pub fn configure(self: *IconsWidget, gpa: std.mem.Allocator, directory: []const u8) void {
        self.gpa = gpa;
        if (setStored(self.dir_buf[0..], &self.dir_len, directory)) {
            self.dir_len = @min(self.dir_len, self.dir_buf.len);
        }
        self.armWatch();
        _ = self.rescan();
    }

    fn dir(self: *const IconsWidget) []const u8 {
        return self.dir_buf[0..self.dir_len];
    }

    /// One nonblocking cloexec inotify watch on the folder. A missing dir
    /// (fresh session, before anything created it) leaves notify_fd at -1 —
    /// the tick re-arms every 5s until either the app drawer's mkdir runs
    /// for "Add to desktop" or the user creates the folder.
    fn armWatch(self: *IconsWidget) void {
        if (self.notify_fd >= 0) _ = posix.system.close(self.notify_fd);
        self.notify_fd = -1;
        var zbuf: [ICON_PATH_MAX + 1]u8 = undefined;
        if (self.dir_len == 0 or self.dir_len > zbuf.len - 1) return;
        @memcpy(zbuf[0..self.dir_len], self.dir_buf[0..self.dir_len]);
        zbuf[self.dir_len] = 0;
        const fd: posix.fd_t = @intCast(inotify_init1(INOTIFY_FLAGS));
        if (fd < 0) return;
        const wd = inotify_add_watch(fd, zbuf[0..self.dir_len :0].ptr, IN_WATCH_MASK);
        if (wd < 0) {
            _ = posix.system.close(fd);
            return;
        }
        self.notify_fd = fd;
    }

    /// Cadence tick: re-arm a dead watch, and rescan when that finally
    /// succeeds (a notify_fd of -1 is the only state that tick repairs).
    pub fn tick(self: *IconsWidget) bool {
        if (self.notify_fd >= 0) return false;
        self.armWatch();
        if (self.notify_fd < 0) return false;
        return self.rescan();
    }

    /// Drains the inotify queue and rescans if anything arrived. One rescan
    /// per drain, not per event — mkdir/cp/sed bursts collapse into one.
    pub fn onPipe(self: *IconsWidget) bool {
        var any = false;
        var buf: [4096]u8 align(4) = undefined;
        while (true) {
            const n = posix.read(self.notify_fd, &buf) catch break;
            if (n == 0) break;
            any = true;
            var i: usize = 0;
            while (i + 16 <= n) {
                const name_len = std.mem.readInt(u32, buf[i + 12 ..][0..4], .little);
                if (name_len == 0 or i + 16 + name_len > n) break;
                i += 16 + name_len;
            }
        }
        if (!any) return false;
        return self.rescan();
    }

    /// Rescans ~/Desktop into fresh items and swaps the list in when the
    /// set changed. Identical name/path/exec/terminal rows with decode
    /// caches alive keep the old list untouched (no icon re-decode churn
    /// on attribute-only notifications). Returns true when pixels changed.
    pub fn rescan(self: *IconsWidget) bool {
        var fresh: [MAX_ICONS]DesktopItem = undefined;
        var count: usize = 0;

        blk: {
            var zbuf: [ICON_PATH_MAX + 1]u8 = undefined;
            if (self.dir_len == 0 or self.dir_len > zbuf.len - 1) break :blk;
            @memcpy(zbuf[0..self.dir_len], self.dir_buf[0..self.dir_len]);
            zbuf[self.dir_len] = 0;
            const dirp = libc_dir.opendir(zbuf[0..self.dir_len :0].ptr) orelse break :blk;
            defer _ = libc_dir.closedir(dirp);
            var ent_opt = libc_dir.readdir(dirp);
            while (ent_opt) |ent| {
                ent_opt = libc_dir.readdir(dirp);
                const name = std.mem.sliceTo(&ent.d_name, 0);
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or ent.d_type == libc_dir.DT_DIR) continue;
                if (!hasSuffix(name, ".desktop")) continue;
                if (count >= MAX_ICONS) {
                    logging.step("icons: >{d} shortcuts in {s} — the rest stay hidden", .{ MAX_ICONS, self.dir() });
                    break;
                }
                var pbuf: [ICON_PATH_MAX + 1]u8 = undefined;
                const rel = std.fmt.bufPrintZ(&pbuf, "{s}/{s}", .{ self.dir(), name }) catch continue;
                var raw: [8192]u8 = undefined;
                const got = readFileCapped(rel, &raw);
                if (!parseDesktopFile(&fresh[count], raw[0..got], self.dir(), name)) continue;
                count += 1;
            }
        }
        // The grid sorts alphabetically like a classic desktop.
        sortItems(fresh[0..count]);

        var unchanged = count == self.item_count;
        if (unchanged) {
            for (fresh[0..count], self.items[0..count]) |*nf, *of| {
                if (!std.mem.eql(u8, nf.name(), of.name()) or
                    !std.mem.eql(u8, nf.path(), of.path()) or
                    !std.mem.eql(u8, nf.exec(), of.exec()) or
                    nf.terminal != of.terminal or
                    of.pixels == null)
                {
                    unchanged = false;
                    break;
                }
            }
        }
        if (unchanged) return false;

        for (self.items[0..self.item_count]) |*old| {
            if (old.pixels) |px| self.gpa.free(px);
        }
        // Histogram-tail entries beyond `count` are stale garbage but
        // unreachable (item_count bounds every loop).
        self.items = fresh;
        self.item_count = count;
        if (self.selected) |s| {
            if (s >= count) self.selected = null;
        }
        if (self.menu_open and self.menu_item >= count) self.menu_open = false;
        for (self.items[0..count]) |*item| {
            item.pixels = self.decodeArt(item);
        }
        logging.step("icons: {d} shortcut(s) on the desktop", .{count});
        return true;
    }

    fn nameSort(_: void, a: *const DesktopItem, b: *const DesktopItem) bool {
        const an = std.ascii.allocLowerString(std.heap.page_allocator, a.name()) catch return false;
        defer std.heap.page_allocator.free(an);
        const bn = std.ascii.allocLowerString(std.heap.page_allocator, b.name()) catch return true;
        defer std.heap.page_allocator.free(bn);
        return std.mem.lessThan(u8, an, bn);
    }

    /// Insertion sort over the (≤64) items — alphabetical by name, the
    /// classic auto-arranged desktop order.
    fn sortItems(items: []DesktopItem) void {
        for (1..items.len) |i| {
            var j = i;
            while (j > 0 and nameLess(&items[j], &items[j - 1])) {
                const tmp = items[j];
                items[j] = items[j - 1];
                items[j - 1] = tmp;
                j -= 1;
            }
        }
    }

    fn nameLess(a: *const DesktopItem, b: *const DesktopItem) bool {
        const max = @max(a.name_len, b.name_len);
        var i: usize = 0;
        while (i < max) : (i += 1) {
            const ca = if (i < a.name_len) std.ascii.toLower(a.name_buf[i]) else 0;
            const cb = if (i < b.name_len) std.ascii.toLower(b.name_buf[i]) else 0;
            if (ca != cb) return ca < cb;
        }
        return false;
    }

    fn readFileCapped(path: [:0]const u8, buf: []u8) usize {
        const raw_fd = posix.system.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
        if (raw_fd < 0) return 0;
        const fd: posix.fd_t = @intCast(raw_fd);
        defer _ = posix.system.close(fd);
        var got: usize = 0;
        while (got < buf.len) {
            const n = posix.read(fd, buf[got..]) catch break;
            if (n == 0) break;
            got += n;
        }
        return got;
    }

    /// Icon= for one item → decoded ARGB square buffer (null = letter chip
    /// fallback, like the drawer's untiled look).
    fn decodeArt(self: *IconsWidget, item: *const DesktopItem) ?[]u32 {
        var path_buf: [ICON_PATH_MAX + 1]u8 = undefined;
        const path_len = iconArtPath(item, path_buf[0..ICON_PATH_MAX]) orelse {
            logging.step("icons: no icon file for '{s}' (Icon={s})", .{ item.name(), item.icon() });
            return null;
        };
        path_buf[path_len] = 0;
        logging.step("icons: '{s}' art <- {s}", .{ item.name(), path_buf[0..path_len] });

        const decoded = icontheme.decodeIcon(self.gpa, path_buf[0..path_len :0], @intCast(ICON_PX)) catch {
            logging.step("icons: decode failed for '{s}'", .{path_buf[0..path_len]});
            return null;
        };
        defer self.gpa.free(decoded.pixels);
        const square = self.gpa.alloc(u32, @as(usize, @intCast(ICON_PX)) * @as(usize, @intCast(ICON_PX))) catch return null;
        icontheme.copyIntoIconBuffer(decoded, square, @intCast(ICON_PX));
        return square;
    }

    /// Resolves an item's art file into `out` (icontheme's resolvers return
    /// slices of the very buffer they write, so the length travels with it).
    /// Order: the game id inside a steam://rungameid exec, then the Icon=
    /// name itself. The exec-first order is what makes Steam shortcuts
    /// right: the client writes Icon=steam for every game — the generic
    /// client icon — while the exec names the game, whose square art sits
    /// in the library cache; the drawer-written shortcut resolves that same
    /// client png into an absolute Icon= path, which must not outrank the
    /// game art either. The client's own entry execs /usr/bin/steam with no
    /// rungameid, so it keeps the client icon.
    fn iconArtPath(item: *const DesktopItem, out: *[ICON_PATH_MAX]u8) ?usize {
        // A rungameid exec marks a game shortcut whatever Icon= says; the
        // steam_app_ wrapper is what icontheme's cache walk keys on.
        var norm_buf: [24]u8 = undefined;
        if (steamAppIdFromExec(item.exec())) |appid| {
            if (std.fmt.bufPrint(&norm_buf, "steam_app_{s}", .{appid})) |norm| {
                if (icontheme.steamGameIconPath(norm, out)) |hit| return hit.len;
            } else |_| {}
        }
        const name = item.icon();
        if (name[0] == '/') {
            // Absolute Icon= goes straight to disk.
            if (name.len > out.len) return null;
            @memcpy(out[0..name.len], name);
            return name.len;
        }
        if (icontheme.steamGameIconPath(name, out)) |hit| return hit.len;
        if (icontheme.resolveIconPath(name, out)) |hit| return hit.len;
        return null;
    }

    /// The appid digits in a steam://rungameid/<appid> exec — the marker of
    /// a per-game shortcut. Returns a subslice of `exec`.
    fn steamAppIdFromExec(exec: []const u8) ?[]const u8 {
        const marker = "rungameid/";
        const at = std.mem.indexOf(u8, exec, marker) orelse return null;
        var end = at + marker.len;
        while (end < exec.len and exec[end] >= '0' and exec[end] <= '9') end += 1;
        if (end == at + marker.len) return null;
        return exec[at + marker.len .. end];
    }

    /// Grid rect for `count` items: fixed 2-column width, rows follow the
    /// count, zero size when the folder has no shortcuts at all (nothing
    /// to paint, nothing to click).
    pub fn gridSizeFor(count: usize) [2]u32 {
        if (count == 0) return .{ 0, 0 };
        const w: i64 = 2 * ICON_TILE_PAD +
            @as(i64, @intCast(ICON_COLS)) * ICON_CELL_W +
            @as(i64, @intCast(ICON_COLS - 1)) * ICON_GAP;
        const rows = (count + ICON_COLS - 1) / ICON_COLS;
        const h: i64 = 2 * ICON_TILE_PAD +
            @as(i64, @intCast(rows)) * ICON_CELL_H +
            @as(i64, @intCast(rows - 1)) * ICON_GAP;
        return .{ @intCast(w), @intCast(h) };
    }

    fn columnsFor(width: u32) usize {
        const inner = @as(i64, width) - 2 * ICON_TILE_PAD;
        if (inner < ICON_CELL_W) return 1;
        const n = @divFloor(inner + ICON_GAP, ICON_CELL_W + ICON_GAP);
        return @intCast(@max(n, 1));
    }

    /// Grid cell under a tile-local point, or null between cells.
    fn cellAt(self: *const IconsWidget, r: Rect, px: i32, py: i32) ?usize {
        const lx: i64 = px - r.x;
        const ly: i64 = py - r.y;
        const cols = columnsFor(r.w);
        const step_w = ICON_CELL_W + ICON_GAP;
        const step_h = ICON_CELL_H + ICON_GAP;
        if (lx < ICON_TILE_PAD or ly < ICON_TILE_PAD) return null;
        const col = @divFloor(lx - ICON_TILE_PAD, step_w);
        const row = @divFloor(ly - ICON_TILE_PAD, step_h);
        if (@mod(lx - ICON_TILE_PAD, step_w) >= ICON_CELL_W) return null;
        if (@mod(ly - ICON_TILE_PAD, step_h) >= ICON_CELL_H) return null;
        if (col < 0 or row < 0) return null;
        const idx = @as(i64, row) * @as(i64, @intCast(cols)) + col;
        if (idx < 0 or idx >= @as(i64, @intCast(self.item_count))) return null;
        return @intCast(idx);
    }

    /// Per-motion pointer pass (surface coords + whether the pointer is on
    /// a desktop surface): hover state for the wash and the popup rows.
    /// Returns repaint-need.
    pub fn pointer(self: *IconsWidget, r: Rect, active: bool, px: i32, py: i32) bool {
        const old_hover = self.hover;
        const old_menu_hover = self.menu_hover;
        const wanted: ?u16 = if (active) blk: {
            const c0 = self.cellAt(r, px, py) orelse break :blk null;
            break :blk @intCast(c0);
        } else null;
        self.hover = wanted;
        if (self.menu_open) {
            const lx: i64 = px - r.x;
            const ly: i64 = py - r.y;
            self.menu_hover = if (active) self.menuRowAt(lx, ly) else 0;
        }
        return !std.meta.eql(old_hover, self.hover) or old_menu_hover != self.menu_hover;
    }

    /// Row (1=Open, 2=Remove) under a tile-local point, or 0 outside.
    fn menuRowAt(self: *const IconsWidget, lx: i64, ly: i64) u8 {
        if (lx < self.menu_x or lx >= self.menu_x + MENU_W) return 0;
        if (ly < self.menu_y or ly >= self.menu_y + MENU_H) return 0;
        const rel = ly - self.menu_y - MENU_PAD;
        return if (rel >= 0 and rel < MENU_ROW_H)
            1
        else if (rel >= MENU_ROW_H and rel < 2 * MENU_ROW_H)
            2
        else
            0;
    }

    pub fn closeMenu(self: *IconsWidget) void {
        self.menu_open = false;
        self.menu_hover = 0;
    }

    /// Left click (surface coords): popup rows act, presses elsewhere close
    /// it, then a cell click selects — and a second one inside the window
    /// launches. Empty cells clear the selection.
    pub fn click(self: *IconsWidget, r: Rect, px: i32, py: i32) void {
        const lx: i64 = px - r.x;
        const ly: i64 = py - r.y;
        if (self.menu_open) {
            const row = self.menuRowAt(lx, ly);
            if (row != 0) {
                self.closeMenu();
                if (row == 2) {
                    self.remove(self.menu_item);
                } else {
                    self.launch(self.menu_item);
                }
                return;
            }
            self.closeMenu();
        }
        const cell = self.cellAt(r, px, py);
        if (cell == null) {
            self.selected = null;
            self.last_click_idx = null;
            return;
        }
        const idx_u: usize = cell.?;
        const idx: u16 = @intCast(idx_u);
        const now = monoMs();
        if (self.last_click_idx != null and self.last_click_idx.? == idx and
            now - self.last_click_ms <= dbl_click_ms)
        {
            self.launch(idx_u);
            self.selected = idx;
            self.last_click_idx = null;
            return;
        }
        self.selected = idx;
        self.last_click_idx = idx;
        self.last_click_ms = now;
    }

    /// Right press over a cell: open the Open/Remove popup there. Over
    /// empty grid or with nothing under the pointer it just dismisses.
    pub fn rightClick(self: *IconsWidget, r: Rect, px: i32, py: i32) void {
        const cell = self.cellAt(r, px, py);
        if (cell == null) {
            self.closeMenu();
            return;
        }
        const lx: i64 = px - r.x;
        const ly: i64 = py - r.y;
        self.menu_x = std.math.clamp(lx - @divFloor(MENU_W, 2), ICON_TILE_PAD, @max(ICON_TILE_PAD, @as(i64, r.w) - MENU_W - ICON_TILE_PAD));
        self.menu_y = std.math.clamp(ly + 8, ICON_TILE_PAD, @max(ICON_TILE_PAD, @as(i64, r.h) - MENU_H - ICON_TILE_PAD));
        self.menu_item = cell.?;
        self.hover = @intCast(cell.?);
        self.menu_open = true;
        self.menu_hover = 0;
    }

    /// Deletes the .desktop file behind an item — the inotify delete event
    /// collapses the grid right after.
    pub fn remove(self: *IconsWidget, idx: usize) void {
        if (idx >= self.item_count) return;
        const item = &self.items[idx];
        var zbuf: [ICON_PATH_MAX + 1]u8 = undefined;
        if (item.path_len >= zbuf.len) return;
        @memcpy(zbuf[0..item.path_len], item.path_buf[0..item.path_len]);
        zbuf[item.path_len] = 0;
        if (unlink(zbuf[0..item.path_len :0].ptr) != 0) {
            logging.step("icons: remove failed: {s}", .{item.path()});
            return;
        }
        // No rescan here: the watch fires IN_DELETE on the next poll.
        logging.step("icons: removed {s}", .{item.path()});
    }

    /// Forks + execs the item's command, detached (own session, so the
    /// widgets' lifetime never limits the launched app). Terminal= entries
    /// wrap in foot → sh -c exactly like the app drawer's launcher.
    pub fn launch(self: *IconsWidget, idx: usize) void {
        if (idx >= self.item_count) return;
        const item = &self.items[idx];

        var execz: [ICON_EXEC_MAX + 1]u8 = undefined;
        @memcpy(execz[0..item.exec_len], item.exec_buf[0..item.exec_len]);
        execz[item.exec_len] = 0;

        var scratch: [2 * ICON_EXEC_MAX + 2 * ICON_ARGS_MAX]u8 = undefined;
        var child_argv = [_]?[*:0]const u8{null} ** (ICON_ARGS_MAX + 1);
        var argc: usize = 0;

        if (item.terminal) {
            child_argv[0] = "foot";
            child_argv[1] = "-e";
            child_argv[2] = "sh";
            child_argv[3] = "-c";
            child_argv[4] = execz[0..item.exec_len :0].ptr;
            argc = 5;
        } else {
            const toks = parseExec(execz[0..item.exec_len], &scratch);
            argc = toks.argc;
            for (0..argc) |k| child_argv[k] = toks.argv[k];
        }
        if (argc == 0) {
            logging.step("icons: exec '{s}' produced no argv", .{item.exec()});
            return;
        }
        child_argv[argc] = null;

        const pid = fork();
        if (pid < 0) {
            logging.step("icons: fork failed (errno {d})", .{pid});
            return;
        }
        if (pid == 0) {
            // Child: separate session, optional working dir, then exec.
            _ = setsid();
            if (item.cwd_len > 0) {
                var cwdz: [ICON_PATH_MAX + 1]u8 = undefined;
                @memcpy(cwdz[0..item.cwd_len], item.cwd_buf[0..item.cwd_len]);
                cwdz[item.cwd_len] = 0;
                _ = chdir(cwdz[0..item.cwd_len :0].ptr);
            }
            _ = execvp(child_argv[0].?, @ptrCast(&child_argv));
            _exit(127); // execvp only returns on failure — don't touch state
        }
        logging.step("icons: launched \"{s}\" (pid {d})", .{ item.name(), pid });
    }

    /// Paints the grid into the widget tile: cells at fixed geometry, hover
    /// wash, selection ring, decoded icon (or letter chip), wrapped label —
    /// with the popup drawn last so it sits above every cell.
    pub fn paint(self: *const IconsWidget, c: Canvas, r: Rect) void {
        if (self.item_count == 0 or r.w == 0 or r.h == 0) return;
        const cols = columnsFor(r.w);
        const pad: i64 = c.zx(ICON_TILE_PAD);
        const cell_w: i64 = c.zx(ICON_CELL_W);
        const cell_h: i64 = c.zx(ICON_CELL_H);
        const gap: i64 = c.zx(ICON_GAP);
        const icon_px: i64 = c.zx(ICON_PX);
        const lh: i64 = lineH(c.font);

        for (0..self.item_count) |idx| {
            const col: i64 = @intCast(idx % cols);
            const row: i64 = @intCast(idx / cols);
            const x = pad + col * (cell_w + gap);
            const y = pad + row * (cell_h + gap);
            const cell = Rect{ .x = @intCast(x), .y = @intCast(y), .w = @intCast(cell_w), .h = @intCast(cell_h) };
            const hovered = self.hover != null and @as(?u16, @intCast(idx)) == self.hover;
            const selected = self.selected != null and @as(?u16, @intCast(idx)) == self.selected;
            if (hovered or selected) {
                // Windows-style wash: selection stronger than hover.
                const alpha: u32 = if (selected) 55 else 30;
                c.card(cell, withAlpha(c.theme.hover_color, alpha), if (selected) dim(c.theme.hover_color, 210) else 0);
            }
            const item = &self.items[idx];
            const icon_x = x + @divFloor(cell_w - icon_px, 2);
            const icon_y = y + c.zx(3);
            const icon_rect = Rect{ .x = @intCast(icon_x), .y = @intCast(icon_y), .w = @intCast(icon_px), .h = @intCast(icon_px) };
            if (item.pixels) |px_buf| {
                c.blitArgb(icon_x, icon_y, @intCast(icon_px), @intCast(icon_px), px_buf, c.zx(8));
            } else {
                // Letter chip fallback (mirrors the app drawer's tiles).
                c.card(icon_rect, withAlpha(c.theme.border_color, 60), 0);
                var cp_end: usize = 0;
                const cp = nextUtf8Codepoint(item.name(), &cp_end) orelse ' ';
                _ = cp;
                const first = item.name()[0..@min(cp_end, item.name_len)];
                if (first.len > 0) {
                    const lw = c.textWidth(first);
                    const baseline = icon_y + @divFloor(icon_px, 2) + @divFloor(@as(i64, c.font.ascentPx()), 2);
                    _ = c.drawText(icon_x + @divFloor(icon_px - lw, 2), baseline, first, c.theme.text_color);
                }
            }
            // Label: up to two wrapped 13px lines under the icon, centered —
            // shadow pass first (+1,+1), then the text on top.
            const budget = cell_w - c.zx(8);
            const parts = wrapLabel(c, item.name(), budget);
            const label_top = icon_y + icon_px + c.zx(5);
            var baseline = label_top + @as(i64, c.font.ascentPx());
            for (parts[0..2], 0..) |part, li| {
                if (part.bytes.len == 0) continue;
                const dots_w: i64 = if (part.ellipsize) cpAdvance(c, "…", 0, 3) else 0;
                const lw = c.textWidth(part.bytes) + dots_w;
                const pen = x + @divFloor(cell_w - lw, 2);
                if (part.ellipsize) {
                    const body_w = lw - dots_w;
                    _ = c.drawText(pen + 1, baseline + 1, part.bytes, shadow_color);
                    _ = c.drawText(pen + body_w + 1, baseline + 1, "…", shadow_color);
                    _ = c.drawText(pen, baseline, part.bytes, label_color);
                    _ = c.drawText(pen + body_w, baseline, "…", label_color);
                } else {
                    _ = c.drawText(pen + 1, baseline + 1, part.bytes, shadow_color);
                    _ = c.drawText(pen, baseline, part.bytes, label_color);
                }
                if (li == 0) baseline += lh - c.zx(2) else break;
            }
        }

        if (self.menu_open) {
            const mr = Rect{
                .x = @intCast(self.menu_x),
                .y = @intCast(self.menu_y),
                .w = @intCast(MENU_W),
                .h = @intCast(MENU_H),
            };
            c.card(mr, withAlpha(c.theme.bg_color, 88), c.theme.border_color);
            const rows = [_][]const u8{ "Open", "Remove" };
            for (rows, 1..) |label, row_no| {
                const row_u8: u8 = @intCast(row_no);
                const ry = self.menu_y + MENU_PAD + @as(i64, @intCast(row_no - 1)) * MENU_ROW_H;
                const rr = Rect{ .x = @intCast(self.menu_x + 4), .y = @intCast(ry), .w = @intCast(MENU_W - 8), .h = @intCast(MENU_ROW_H) };
                if (self.menu_hover == row_u8) {
                    c.card(rr, withAlpha(c.theme.hover_color, 70), 0);
                }
                const color = if (row_no == 2) dim(c.theme.holiday_color, 230) else c.theme.text_color;
                const baseline = ry + @divFloor(MENU_ROW_H, 2) - @divFloor(lh, 2) + @as(i64, c.font.ascentPx());
                _ = c.drawText(self.menu_x + 12, baseline, label, color);
            }
        }
    }
};

/// One wrapped label part: bytes plus whether to append the ellipsis after.
const LabelPart = struct { bytes: []const u8, ellipsize: bool = false };

/// Splits a shortcut name into at most two label lines, each under `budget`
/// px wide, preferring a space break; the tail of line 2 elides with `…`.
fn wrapLabel(c: Canvas, text: []const u8, budget: i64) [2]LabelPart {
    var out = [2]LabelPart{ .{ .bytes = text[0..0] }, .{ .bytes = text[0..0] } };
    if (c.textWidth(text) <= budget) {
        out[0] = .{ .bytes = text };
        return out;
    }
    // Longest prefix that fits becomes line 1.
    var fit_end: usize = 0;
    var w: i64 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        if (nextUtf8Codepoint(text, &i) == null) break;
        const adv = cpAdvance(c, text, start, i);
        if (w + adv > budget) break;
        w += adv;
        fit_end = i;
    }
    var l1 = text[0..fit_end];
    var rest = text[fit_end..];
    if (fit_end > 0) {
        if (std.mem.lastIndexOfScalar(u8, l1, ' ')) |sp| {
            // Break at the last space instead of mid-word.
            l1 = text[0..sp];
            rest = text[sp + 1 ..];
        }
    }
    out[0] = .{ .bytes = l1 };
    if (c.textWidth(rest) <= budget) {
        out[1] = .{ .bytes = rest };
        return out;
    }
    const dots_w = cpAdvance(c, "…", 0, 3);
    var fit2: usize = 0;
    var w2: i64 = 0;
    var j: usize = 0;
    while (j < rest.len) {
        const start = j;
        if (nextUtf8Codepoint(rest, &j) == null) break;
        const adv = cpAdvance(c, rest, start, j);
        if (w2 + adv + dots_w > budget) break;
        w2 += adv;
        fit2 = j;
    }
    out[1] = .{ .bytes = rest[0..fit2], .ellipsize = true };
    return out;
}

fn cpAdvance(c: Canvas, s: []const u8, start: usize, end: usize) i64 {
    if (end <= start or start >= s.len) return 0;
    var j = start;
    const cp = nextUtf8Codepoint(s, &j) orelse return 0;
    const g = c.font.glyph(cp) catch return 0;
    return g.advance_x;
}

test "icons: exec tokenizing strips field codes and honors quotes" {
    var scratch: [512]u8 = undefined;

    var toks = parseExec("steam steam://rungameid/1245620", &scratch);
    try std.testing.expectEqual(@as(usize, 2), toks.argc);
    try std.testing.expectEqualStrings("steam", std.mem.span(toks.argv[0]));
    try std.testing.expectEqualStrings("steam://rungameid/1245620", std.mem.span(toks.argv[1]));

    toks = parseExec("\"foo bar\" -x %f %U", &scratch);
    try std.testing.expectEqual(@as(usize, 2), toks.argc);
    try std.testing.expectEqualStrings("foo bar", std.mem.span(toks.argv[0]));
    try std.testing.expectEqualStrings("-x", std.mem.span(toks.argv[1]));

    toks = parseExec("kitty -e 'test a'", &scratch);
    try std.testing.expectEqual(@as(usize, 3), toks.argc);
    try std.testing.expectEqualStrings("kitty", std.mem.span(toks.argv[0]));
    try std.testing.expectEqualStrings("-e", std.mem.span(toks.argv[1]));
    try std.testing.expectEqualStrings("test a", std.mem.span(toks.argv[2]));

    // Field codes vanish; %% collapses; unknown codes stay literal.
    toks = parseExec("100%% sure%z %f", &scratch);
    try std.testing.expectEqual(@as(usize, 2), toks.argc);
    try std.testing.expectEqualStrings("100%", std.mem.span(toks.argv[0]));
    try std.testing.expectEqualStrings("sure%z", std.mem.span(toks.argv[1]));
}

test "icons: desktop file parsing" {
    var item: DesktopItem = undefined;
    try std.testing.expect(parseDesktopFile(&item,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Balatro
        \\Exec=steam steam://rungameid/1245620
        \\Icon=steam_app_1245620
        \\[Desktop Action window]
        \\Name=Window
        \\Exec=steam steam://bad
        \\
    , "/home/x/Desktop", "Balatro.desktop"));
    try std.testing.expectEqualStrings("Balatro", item.name());
    try std.testing.expectEqualStrings("steam steam://rungameid/1245620", item.exec());
    try std.testing.expectEqualStrings("steam_app_1245620", item.icon());
    try std.testing.expectEqualStrings("/home/x/Desktop/Balatro.desktop", item.path());

    // Not launchable: type mismatch, no Exec, no [Desktop Entry] header.
    try std.testing.expect(!parseDesktopFile(&item, "[Desktop Entry]\nType=Link\nExec=whatever\n", "/d", "x.desktop"));
    try std.testing.expect(!parseDesktopFile(&item, "[Desktop Entry]\nName=No exec\n", "/d", "x.desktop"));
    try std.testing.expect(!parseDesktopFile(&item, "Type=Link\nExec=before-header\n", "/d", "x.desktop"));

    // Name falls back to the file stem; Terminal parses both spellings.
    try std.testing.expect(parseDesktopFile(&item, "[Desktop Entry]\nTerminal=true\nExec=kitty\n", "/d", "Terminal App.desktop"));
    try std.testing.expect(item.terminal);
    try std.testing.expectEqualStrings("Terminal App", item.name());
}

test "icons: exec rungameid extraction" {
    try std.testing.expectEqualStrings("2379780", IconsWidget.steamAppIdFromExec("steam steam://rungameid/2379780").?);
    try std.testing.expectEqualStrings("440", IconsWidget.steamAppIdFromExec("/usr/bin/steam steam://rungameid/440 %U").?);
    // The client's own shortcut and other launchers: no game id present.
    try std.testing.expect(IconsWidget.steamAppIdFromExec("/usr/bin/steam %U") == null);
    try std.testing.expect(IconsWidget.steamAppIdFromExec("lutris lutris:rungame/diablo") == null);
}

test "icons: grid sizing" {
    try std.testing.expectEqual(@as(u32, 218), IconsWidget.gridSizeFor(2)[0]);
    try std.testing.expectEqual(@as(u32, 296), IconsWidget.gridSizeFor(5)[1]); // 3 rows
    try std.testing.expectEqual(@as(u32, 108), IconsWidget.gridSizeFor(1)[1]);
    try std.testing.expectEqual(@as(u32, 0), IconsWidget.gridSizeFor(0)[0]);
}

pub const FontMeasure = struct {
    font: *font_mod.Font,
    pub fn advance(self: FontMeasure, cp: u32) i64 {
        return (self.font.glyph(cp) catch return 8).advance_x;
    }
};

/// One wrapped line: byte range of its content. `end` excludes the newline
/// or line-breaking space that terminated it.
const LayoutLine = struct { start: usize, end: usize };

/// Sum of `text`'s glyph advances.
fn advSlice(measure: anytype, text: []const u8) i64 {
    var i: usize = 0;
    var w: i64 = 0;
    while (nextUtf8Codepoint(text, &i)) |cp| w += measure.advance(cp);
    return w;
}

/// Greedy word-wrap over `lines` (capacity ≥ text.len + 1 always holds for
/// the note buffers). Breaks at hard newlines and at the line-breaking space
/// nearest the limit — that space terminates the wrapped line and is dropped
/// from it — and hard-breaks words longer than a whole line.
fn wrapLines(measure: anytype, text: []const u8, max_w: i64, lines: []LayoutLine) usize {
    var count: usize = 0;
    var start: usize = 0;
    var w: i64 = 0;
    var last_space: ?usize = null;
    var i: usize = 0;
    while (i < text.len) {
        const cp_start = i;
        const cp = nextUtf8Codepoint(text, &i) orelse break;
        var consumed = false;
        if (cp == '\n') {
            lines[count] = .{ .start = start, .end = cp_start };
            count += 1;
            start = i;
            w = 0;
            last_space = null;
            consumed = true;
        } else {
            const a = measure.advance(cp);
            if (w > 0 and w + a > max_w and cp_start > start) {
                if (last_space) |sp| {
                    lines[count] = .{ .start = start, .end = sp };
                    count += 1;
                    if (sp == cp_start) {
                        // The overflowing char IS the line-breaking space:
                        // drop it from both sides and start fresh after it.
                        start = i;
                        w = 0;
                        last_space = null;
                        consumed = true;
                    } else {
                        start = sp + 1;
                        w = advSlice(measure, text[start..cp_start]);
                        last_space = null;
                    }
                } else {
                    // No space yet on this line — hard-break the long word.
                    lines[count] = .{ .start = start, .end = cp_start };
                    count += 1;
                    start = cp_start;
                    w = 0;
                }
            }
            if (!consumed) {
                if (cp == ' ') last_space = cp_start;
                w += a;
            }
        }
    }
    lines[count] = .{ .start = start, .end = text.len };
    return count + 1;
}

/// Index of the wrapped line that holds byte offset `caret` (the last line
/// wins when the caret sits on a line break).
fn caretLine(lines: []const LayoutLine, count: usize, caret: usize) usize {
    var li: usize = 0;
    for (1..count) |i| {
        if (lines[i].start > caret) break;
        li = i;
    }
    return li;
}

/// Byte offset in `line_text` whose boundary is closest to pixel `x`.
fn offsetNear(measure: anytype, line_text: []const u8, x: i64) usize {
    var i: usize = 0;
    var w: i64 = 0;
    while (i < line_text.len) {
        const start = i;
        const cp = nextUtf8Codepoint(line_text, &i) orelse break;
        const a = measure.advance(cp);
        if (x < w + @divTrunc(a, 2)) return start;
        if (x < w + a) return i;
        w += a;
    }
    return line_text.len;
}

/// Linux evdev key codes the note editor routes by hardware code — stable
/// across layouts; the xkb round-trip only decodes text.
pub const KEY_ESC: u32 = 1;
pub const KEY_BACKSPACE: u32 = 14;
pub const KEY_ENTER: u32 = 28;
pub const KEY_KP_ENTER: u32 = 96;
pub const KEY_LEFT: u32 = 105;
pub const KEY_RIGHT: u32 = 106;
pub const KEY_UP: u32 = 103;
pub const KEY_DOWN: u32 = 108;
pub const KEY_HOME: u32 = 102;
pub const KEY_END: u32 = 107;
pub const KEY_DELETE: u32 = 111;

/// Atomic file write (tmp + rename) — the same pattern saveConfig uses, for
/// the note payloads. Returns true on success.
pub fn writeFileAtomicZ(path: [:0]const u8, data: []const u8) bool {
    if (path.len + 4 >= 512) return false;
    var tmp_buf: [400]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{path}) catch return false;
    const raw_fd = posix.system.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(posix.mode_t, 0o644));
    if (raw_fd < 0) return false;
    const fd: posix.fd_t = @intCast(raw_fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    _ = posix.system.close(fd);
    if (off != data.len) return false;
    return std.c.rename(tmp.ptr, path.ptr) == 0;
}

// --- the composite widget ---------------------------------------------------

pub const Widget = union(WidgetId) {
    clock: ClockWidget,
    weather: WeatherWidget,
    media: MediaWidget,
    system: SystemWidget,
    calendar: CalendarWidget,
    note1: NoteWidget,
    icons: IconsWidget,
    fastfetch: FastfetchWidget,
    processes: ProcessesWidget,
    network: NetworkWidget,
    user: UserWidget,

    // By pointer, not by value: the union is as big as its largest card
    // (the Fastfetch card's rows and logo, ~27 KB), and this runs every tick.
    pub fn intervalMs(self: *const Widget) i64 {
        return switch (self.*) {
            .clock => ClockWidget.interval_ms,
            // Moving conditions animate at 60ms; static ones (clear sky,
            // no data yet) idle at 1s. The fetch schedule rides the tick.
            .weather => |*w| if (w.animating()) 60 else 1000,
            .media => MediaWidget.interval_ms,
            .system => SystemWidget.interval_ms,
            .calendar => CalendarWidget.interval_ms,
            // Editing notes blink every half second; idle ones never repaint.
            .note1 => |*n| if (n.editing or n.armed()) NoteWidget.interval_ms else NoteWidget.idle_interval_ms,
            // The icons grid only self-heals a dead inotify watch here.
            .icons => IconsWidget.interval_ms,
            .fastfetch => FastfetchWidget.interval_ms,
            .processes => ProcessesWidget.interval_ms,
            .network => NetworkWidget.interval_ms,
            .user => UserWidget.interval_ms,
        };
    }

    /// Cadence tick — update state / kick fetches. Returns true if the
    /// widget's pixels need repainting now.
    pub fn tick(self: *Widget) bool {
        return switch (self.*) {
            // Repaints only when the face changes (once a minute without
            // seconds).
            .clock => |*c| c.update(),
            // Repaints only when a shown value changed.
            .system => |*s| s.refresh(),
            .weather => |*w| blk: {
                // Advance the condition animation, then let weather.zig's
                // schedule decide whether a fetch is due (it rate-limits
                // itself: 15 min refresh, 30 s floor, retry backoff), so
                // this never forks curl per tick.
                w.anim_frame +%= 1;
                w.pump(monoMs());
                break :blk true;
            },
            .media => |*m| blk: {
                break :blk m.tick();
            },
            .calendar => |*k| blk: {
                break :blk k.tick();
            },
            .note1 => |*n| blk: {
                break :blk n.tick();
            },
            // Repaints only when a shown row changed.
            .fastfetch => |*f| f.tick(),
            .processes => |*p| p.tick(),
            // Repaints only when a shown rate or the graph changed.
            .network => |*n| n.tick(),
            // Repaints on first load and when the uptime's minute moves.
            .user => |*u| u.tick(),
            .icons => |*ic| blk: {
                break :blk ic.tick();
            },
        };
    }

    /// The fd poll() should watch for this widget, or -1.
    pub fn pollFd(self: *const Widget) posix.fd_t {
        // Pointer captures: this runs for every widget on every loop pass.
        return switch (self.*) {
            .weather => |*w| w.fetch.fd(),
            .system => |*s| s.fetch.fd(),
            .media => |*m| m.fetch.fd(),
            .calendar => |*k| k.fetch.fd(),
            // The desktop icons' inotify watch: folder events land here.
            .icons => |*ic| ic.notify_fd,
            // The notes folder watch: outside edits and new note files.
            .note1 => |*n| n.notify_fd,
            .fastfetch => |*f| f.fetch.fd(),
            else => -1,
        };
    }

    /// A fetch pipe became readable. Returns true when the widget consumed a
    /// completed fetch (pixels may have changed).
    pub fn onPipe(self: *Widget) bool {
        return switch (self.*) {
            .weather => |*w| w.onPipe(),
            .system => |*s| s.onPipe(),
            .media => |*m| m.onPipe(),
            .calendar => |*k| k.onPipe(),
            .icons => |*ic| ic.onPipe(),
            .note1 => |*n| n.onNotify(),
            .fastfetch => |*f| f.onPipe(),
            else => false,
        };
    }

    /// Left-click action. Media and calendar get the click point plus their
    /// rect so their controls hit-test; every other widget ignores the extras.
    pub fn click(self: *Widget, font: *font_mod.Font, zoom: f32, r: Rect, x: i32, y: i32) void {
        switch (self.*) {
            .clock => |c| c.click(),
            .weather => |*w| w.click(),
            .media => |*m| m.clickAt(r, font, zoom, x, y),
            .system => |*s| s.click(),
            .calendar => |*k| k.clickAt(r, font, zoom, x, y),
            .note1 => |*n| n.clickAt(r, font, x, y),
            .icons => |*ic| ic.click(r, x, y),
            .fastfetch => {},
            .processes => |*p| p.click(),
            .network => {},
            .user => {},
        }
    }

    /// Draw content inside the already-painted card.
    pub fn paint(self: *const Widget, c: Canvas, r: Rect) void {
        // Pointer captures: no per-paint copy of a card's whole state.
        switch (self.*) {
            .clock => |*w| w.paint(c, r),
            .weather => |*w| w.paint(c, r),
            .media => |*w| w.paint(c, r),
            .system => |*w| w.paint(c, r),
            .calendar => |*w| w.paint(c, r),
            .note1 => |*n| n.paint(c, r),
            .icons => |*ic| ic.paint(c, r),
            .fastfetch => |*f| f.paint(c, r),
            .processes => |*p| p.paint(c, r),
            .network => |*n| n.paint(c, r),
            .user => |*u| u.paint(c, r),
        }
    }
};

/// The sticky-note slot number of a note widget, else null — the host uses
/// it to open/close the single-edit slot on pointer clicks.
pub fn noteSlot(w: *const Widget) ?u8 {
    return switch (w.*) {
        .note1 => 1,
        else => null,
    };
}

// --- widget id tests -------------------------------------------------------

test "widget ids: live, retired watch, unknown" {
    try std.testing.expectEqual(ParsedWidgetId{ .id = .clock }, parseWidgetId("clock"));
    try std.testing.expectEqual(ParsedWidgetId{ .id = .user }, parseWidgetId("user"));
    try std.testing.expectEqual(ParsedWidgetId.retired, parseWidgetId("watch"));
    try std.testing.expectEqual(ParsedWidgetId.unknown, parseWidgetId("clocks"));
    try std.testing.expectEqual(ParsedWidgetId.unknown, parseWidgetId(""));
}

// --- sticky-note tests ------------------------------------------------------

/// Fixed 8px-advance stand-in for FontMeasure — the wrap/caret math never
/// touches the real freetype font, so these run headless.
const FixedAdv = struct {
    pub fn advance(self: FixedAdv, cp: u32) i64 {
        _ = self;
        _ = cp;
        return 8;
    }
};

test "notes: greedy word wrap" {
    const m = FixedAdv{};
    var lines: [NoteWidget.MAX_WRAP_LINES]LayoutLine = undefined;
    // 5 chars fit: "aaaa bbbb cccc" wraps at both line-breaking spaces.
    const text1 = "aaaa bbbb cccc";
    const n1 = wrapLines(m, text1, 40, &lines);
    try std.testing.expectEqual(@as(usize, 3), n1);
    try std.testing.expectEqualSlices(u8, "aaaa", text1[lines[0].start..lines[0].end]);
    try std.testing.expectEqualSlices(u8, "bbbb", text1[lines[1].start..lines[1].end]);
    try std.testing.expectEqualSlices(u8, "cccc", text1[lines[2].start..lines[2].end]);
    // Explicit newlines force breaks.
    const text2 = "ab\ncd";
    const n2 = wrapLines(m, text2, 40, &lines);
    try std.testing.expectEqual(@as(usize, 2), n2);
    try std.testing.expectEqualSlices(u8, "ab", text2[lines[0].start..lines[0].end]);
    try std.testing.expectEqualSlices(u8, "cd", text2[lines[1].start..lines[1].end]);
    // A word longer than the line is hard-broken mid-word.
    const text3 = "abcdefghij";
    const n3 = wrapLines(m, text3, 40, &lines);
    try std.testing.expectEqual(@as(usize, 2), n3);
    try std.testing.expectEqualSlices(u8, "abcde", text3[lines[0].start..lines[0].end]);
    try std.testing.expectEqualSlices(u8, "fghij", text3[lines[1].start..lines[1].end]);
    // Empty text is a single empty line.
    const n4 = wrapLines(m, "", 40, &lines);
    try std.testing.expectEqual(@as(usize, 1), n4);
    try std.testing.expectEqual(@as(usize, 0), lines[0].end - lines[0].start);
}

test "notes: caret moves are codepoint-aware" {
    var note = NoteWidget{};
    _ = note.insertCp('a'); // 1 byte
    _ = note.insertCp('b'); // 1 byte
    _ = note.insertCp(0xE9); // é — 2 bytes
    try std.testing.expectEqual(@as(usize, 4), note.text_len);
    try std.testing.expectEqual(@as(usize, 4), note.caret);
    // Left crosses the whole é in one step, not half a byte.
    _ = note.moveLeft();
    try std.testing.expectEqual(@as(usize, 2), note.caret);
    _ = note.moveRight();
    try std.testing.expectEqual(@as(usize, 4), note.caret);
    // Backspace before é removes it whole.
    _ = note.backspace();
    try std.testing.expectEqual(@as(usize, 2), note.text_len);
    try std.testing.expectEqual(@as(usize, 2), note.caret);
    try std.testing.expectEqualSlices(u8, "ab", note.text());
}

test "notes: text capped at NOTE_MAX" {
    var note = NoteWidget{};
    for (0..NoteWidget.NOTE_MAX) |_| _ = note.insertCp('x');
    try std.testing.expectEqual(NoteWidget.NOTE_MAX, note.text_len);
    _ = note.insertCp('y'); // no room — still exactly NOTE_MAX
    try std.testing.expectEqual(NoteWidget.NOTE_MAX, note.text_len);
    // Deleting a byte frees a slot again.
    _ = note.backspace();
    _ = note.insertCp('y');
    try std.testing.expectEqual(NoteWidget.NOTE_MAX, note.text_len);
    try std.testing.expectEqual(@as(u8, 'y'), note.text_buf[note.text_len - 1]);
}

test "notes: wrap line array fits the worst case" {
    var note = NoteWidget{};
    for (0..NoteWidget.NOTE_MAX) |_| _ = note.insertCp('\n');
    var lines: [NoteWidget.MAX_WRAP_LINES]LayoutLine = undefined;
    const n = wrapLines(FixedAdv{}, note.text(), 40, &lines);
    // NOTE_MAX newlines ⇒ NOTE_MAX lines + one trailing empty.
    try std.testing.expectEqual(NoteWidget.NOTE_MAX + 1, n);
    try std.testing.expect(n <= lines.len);
}

test "notes: keyPress edit commands, Enter, Esc" {
    var note = NoteWidget{};
    const m = FixedAdv{};
    const K = NoteWidget.KeyResult;
    // Non-special keycodes with an xkb-decoded codepoint insert text.
    try std.testing.expectEqual(K.handled, note.keyPress(m, 40, 6, 999, 'a'));
    try std.testing.expectEqual(K.handled, note.keyPress(m, 40, 6, 999, 'b'));
    try std.testing.expectEqual(K.handled, note.keyPress(m, 40, 6, KEY_ENTER, 0));
    try std.testing.expectEqualSlices(u8, "ab\n", note.text());
    // Delete is exactly one codepoint, and Backspace undoes a newline.
    _ = note.moveLeft();
    _ = note.deleteForward();
    try std.testing.expectEqualSlices(u8, "ab", note.text());
    try std.testing.expectEqual(K.handled, note.keyPress(m, 40, 6, KEY_BACKSPACE, 0));
    try std.testing.expectEqualSlices(u8, "a", note.text());
    // Home / End sweep the visual line.
    _ = note.keyPress(m, 40, 6, 999, 'b');
    try std.testing.expectEqual(K.handled, note.keyPress(m, 40, 6, KEY_HOME, 0));
    try std.testing.expectEqual(@as(usize, 0), note.caret);
    try std.testing.expectEqual(K.handled, note.keyPress(m, 40, 6, KEY_END, 0));
    try std.testing.expectEqual(@as(usize, 2), note.caret);
    // Non-printable / unmapped keys are ignored, not inserted.
    try std.testing.expectEqual(K.ignored, note.keyPress(m, 40, 6, 999, 0));
    try std.testing.expectEqual(K.ignored, note.keyPress(m, 40, 6, 999, 0x7F));
    try std.testing.expectEqualSlices(u8, "ab", note.text());
    // Esc commits and hands the slot back.
    try std.testing.expectEqual(K.exited, note.keyPress(m, 40, 6, KEY_ESC, 0));
    try std.testing.expect(!note.editing);
}

test "notes: up/down walk wrapped lines" {
    var note = NoteWidget{};
    const m = FixedAdv{};
    const K = NoteWidget.KeyResult;
    for ("aaaa bbbb cccc") |ch| _ = note.insertCp(@intCast(ch));
    note.caret = note.text_len;
    note.desired_x = 0;
    // Line 3 -> line 2 at the same column.
    try std.testing.expectEqual(K.handled, note.keyPress(m, 40, 6, KEY_UP, 0));
    try std.testing.expectEqual(@as(usize, 5), note.caret); // start of "bbbb"
    try std.testing.expectEqual(K.handled, note.keyPress(m, 40, 6, KEY_UP, 0));
    try std.testing.expectEqual(@as(usize, 0), note.caret); // start of "aaaa"
    // At the top, Up is a no-op (ignored).
    try std.testing.expectEqual(K.ignored, note.keyPress(m, 40, 6, KEY_UP, 0));
    // And Down walks back down.
    try std.testing.expectEqual(K.handled, note.keyPress(m, 40, 6, KEY_DOWN, 0));
    try std.testing.expectEqual(@as(usize, 5), note.caret);
    try std.testing.expectEqual(K.handled, note.keyPress(m, 40, 6, KEY_DOWN, 0));
    try std.testing.expectEqual(K.ignored, note.keyPress(m, 40, 6, KEY_DOWN, 0));
}
