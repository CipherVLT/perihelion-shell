//! perihelionbar-shell — desktop widgets for Wayland, written in Zig.
//!
//! One full-output layer-shell surface per monitor on the `bottom` layer
//! (above the wallpaper, behind your windows, rainmeter-style), painted
//! entirely in software into wl_shm ARGB buffers. Each configured widget is
//! a small paint-only object (see widgets.zig) drawn into that shared
//! surface; the host repaints lazily — it poll()s with a timeout computed
//! from the earliest widget cadence deadline, never a fixed animation loop.
//!
//! Input is limited to the widget rects (surface set_input_region), so the
//! rest of the desktop passes clicks straight through to windows.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const font_mod = @import("font");
const logging = @import("logging");
const widgets_mod = @import("widgets");
const glass = @import("glass.zig");
const overview_mod = @import("overview");
const glance = @import("glance.zig");
const glance_view = @import("glance_view.zig");
const weather_service = @import("weather");
const temps_service = @import("temps");
const ff_service = @import("fastfetch");
const procs_service = @import("procs");
const netrate_service = @import("netrate");

pub const panic = std.debug.FullPanic(logging.panicHandler);

const MAX_OUTPUTS: usize = 8;
// 6 base widgets + 3 sticky notes = 9 ≤ 12. Only bits tell you a tile is
// stale, without scanning every widget for changes.
const MAX_WIDGETS: usize = 12;
const FONT_PIXEL_SIZE: u32 = 13;
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;

// getenv by hand — enough here, no env-map machinery needed (same approach
// as the bar).
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const libc_clock = struct {
    extern "c" fn clock_gettime(clockid: c_int, tp: *posix.timespec) c_int;
};

/// Monotonic milliseconds since some arbitrary epoch — only deltas are
/// meaningful. 0.16 removed std.time.milliTimestamp/Instant, and the bar
/// binds its own libc time helpers, so this follows suit.
fn nowMs() i64 {
    var tp: posix.timespec = undefined;
    if (libc_clock.clock_gettime(1, &tp) != 0) return 0; // 1 = CLOCK_MONOTONIC
    const sec: i64 = @intCast(tp.sec);
    const nsec: i64 = @intCast(tp.nsec);
    return sec * 1000 + @divTrunc(nsec, 1_000_000);
}

// --- configuration ---------------------------------------------------------

const JsonWidgetCfg = struct {
    id: []const u8 = "clock",
    x: i32 = 0,
    y: i32 = 0,
    /// Card size override (corner resize persists it here); null/absent
    /// means the type's base size from cardSizeFor.
    w: ?u32 = null,
    h: ?u32 = null,
};

const JsonConfig = struct {
    font_path: ?[]const u8 = null,
    card_bg_opacity: ?u8 = null,
    card_corner_radius: ?u32 = null,
    holiday_country: ?[]const u8 = null,
    holiday_region: ?[]const u8 = null,
    overview_favorites: ?[]const []const u8 = null,
    // Glance dashboard (Super+I): on/off and the page it opens on.
    glance_enabled: ?bool = null,
    glance_start_tab: ?[]const u8 = null,
    // Weather card (widgets.zig WeatherWidget / weather.zig). Coordinates
    // win over a city; with neither, IP geolocation (when allowed).
    weather_latitude: ?f64 = null,
    weather_longitude: ?f64 = null,
    weather_city: ?[]const u8 = null,
    weather_units: ?[]const u8 = null,
    weather_click: ?[]const u8 = null,
    weather_auto_location: ?bool = null,
    weather_refresh_minutes: ?u32 = null,
    weather_ip_url: ?[]const u8 = null,
    // System card temperatures (temps.zig).
    system_gpu: ?[]const u8 = null,
    system_temp_units: ?[]const u8 = null,
    system_temp_interval_seconds: ?u32 = null,
    system_nvidia_smi: ?bool = null,
    // Fastfetch card (fastfetch.zig).
    fastfetch_fields: ?[]const []const u8 = null,
    fastfetch_refresh_minutes: ?u32 = null,
    fastfetch_binary: ?[]const u8 = null,
    fastfetch_logo: ?[]const u8 = null,
    fastfetch_config: ?[]const u8 = null,
    // Clock card face.
    clock_style: ?[]const u8 = null,
    clock_24h: ?bool = null,
    clock_seconds: ?bool = null,
    clock_date: ?bool = null,
    // System card look: "columns" | "bars" | "rings".
    system_style: ?[]const u8 = null,
    // Processes card (procs.zig).
    processes_sort: ?[]const u8 = null,
    processes_count: ?u32 = null,
    processes_interval_seconds: ?u32 = null,
    processes_group: ?bool = null,
    // Calendar card: reminder rows listed under the month grid.
    calendar_reminders: ?u32 = null,
    // Network card (netrate.zig).
    network_graph: ?bool = null,
    network_interval_seconds: ?u32 = null,
    // User card (userinfo.zig).
    user_host: ?bool = null,
    user_uptime_short: ?bool = null,
    user_show_name: ?bool = null,
    // Notes card.
    notes_tabs: ?bool = null,
    notes_checklists: ?bool = null,
    notes_lines: ?u32 = null,
    notes_dir: ?[]const u8 = null,
    notes_page: ?u32 = null,
    widgets: ?[]const JsonWidgetCfg = null,
};

const JsonMatugenColors = struct {
    bg_color: ?[]const u8 = null,
    text_color: ?[]const u8 = null,
    border_color: ?[]const u8 = null,
    hover_color: ?[]const u8 = null,
    holiday_color: ?[]const u8 = null,
    // Tertiary accent (every preset and the matugen template carry it);
    // widgets know it as accent2_color.
    matrix_color: ?[]const u8 = null,
    // Perihelion: perihelion-theme may set how opaque the widget cards are
    // for its current style (Material You's darker surfaces need more to
    // read as the bar's grey). Absent: shell.json's card_bg_opacity.
    card_bg_opacity: ?u32 = null,
};

const WidgetCfg = struct {
    id: widgets_mod.WidgetId,
    x: i32,
    y: i32,
    /// Persisted size override, 0 = base size (matches absent JSON keys).
    w: u32 = 0,
    h: u32 = 0,
};

const ShellConfig = struct {
    font_path: []const u8 = "",
    card_bg_opacity: u8 = 55,
    corner_radius: u32 = 18, // Perihelion: soft glass cards (perihelionbar: 12)
    holiday_country: []const u8 = "AU",
    holiday_region: []const u8 = "",
    weather_latitude: ?f64 = null,
    weather_longitude: ?f64 = null,
    weather_city: []const u8 = "",
    weather_units: weather_service.Units = .celsius,
    /// weather_units "auto" (the default): °F for US places, °C elsewhere.
    weather_units_auto: bool = true,
    /// What a click on the Weather card does.
    weather_click: widgets_mod.WeatherClick = .forecast,
    weather_auto_location: bool = true,
    weather_refresh_minutes: u32 = 15,
    /// Empty = weather.zig's default (ipapi.co).
    weather_ip_url: []const u8 = "",
    /// "auto" | "none" | index | PCI address | "amd"/"intel"/"nvidia";
    /// a click on the System card saves the PCI address it switched to.
    system_gpu: []const u8 = "auto",
    system_temp_units: temps_service.Units = .celsius,
    system_temp_interval_seconds: u32 = 2,
    system_nvidia_smi: bool = true,
    /// Fastfetch card rows in order (count 0 = fastfetch.zig's defaults).
    fastfetch_fields: [ff_service.FIELD_COUNT]ff_service.Field = undefined,
    fastfetch_field_count: usize = 0,
    /// 0 = run fastfetch once at startup only.
    fastfetch_refresh_minutes: u32 = 30,
    /// "" auto-detect, "none" built-in collector only, else a path/name.
    fastfetch_binary: []const u8 = "",
    /// "auto" | "distro" | "none" | path to a text logo.
    fastfetch_logo: []const u8 = "auto",
    /// "" = auto (~/.config/fastfetch/config.jsonc, then Perihelion's
    /// shipped copy) | "none" (fields layout) | a config file path.
    fastfetch_config: []const u8 = "",
    /// Clock face: digital | flip | stacked ("macos") | classic.
    clock: widgets_mod.ClockLayout = .{},
    system_style: widgets_mod.SystemStyle = .columns,
    /// Processes card: order, rows (3-8), sample interval, group by name.
    processes_sort: procs_service.Sort = .cpu,
    processes_count: u32 = 6,
    processes_interval_seconds: u32 = 3,
    processes_group: bool = false,
    /// Calendar card: today's and upcoming reminders listed under the
    /// month grid, 0-6 rows (0 = no list, the card keeps its old size).
    calendar_reminders: u32 = 0,
    /// Network card: draw the rate graph, and seconds between samples.
    network_graph: bool = true,
    network_interval_seconds: u32 = 2,
    /// User card: show login@host, and the short uptime wording.
    user_host: bool = true,
    user_uptime_short: bool = false,
    user_show_name: bool = false,
    /// Notes card: header with tabs, checklist drawing, base text lines.
    notes: widgets_mod.NotesLayout = .{},
    /// "" = ~/.config/perihelionbar/notes; a leading "~/" means $HOME.
    notes_dir: []const u8 = "",
    /// File number of the open note (noteN.txt), saved on each switch.
    notes_page: u8 = 1,
    /// Glance dashboard (Super+I, `perihelion-shell glance`): off means the
    /// command answers "off" and nothing is ever built for it.
    glance_enabled: bool = true,
    /// The page a plain `glance toggle` opens on.
    glance_start_tab: glance.Tab = .overview,
    /// Overview dash launch commands (shell.json `overview_favorites`).
    fav_cmds: [overview_mod.MAX_FAVS][]const u8 = undefined,
    fav_count: usize = 0,
    widget_cfgs: [MAX_WIDGETS]WidgetCfg = undefined,
    widget_count: usize = 0,
};

const DEFAULT_WIDGETS = [_]WidgetCfg{
    .{ .id = .clock, .x = 24, .y = 24 },
    // Weather carries a forecast strip under its header (≈ 195px tall at
    // the 13px font); the rest of the column starts below it.
    .{ .id = .weather, .x = 24, .y = 106 },
    .{ .id = .media, .x = 24, .y = 314 },
    // Media is a tall card (cover + progress + controls ≈ 158px at the
    // 13px font); system sits below it with a gap (columns ≈ 138px).
    .{ .id = .system, .x = 24, .y = 484 },
    // Calendar below the stack (238 x ≈ 262px with no reminder rows);
    // drag anywhere with Ctrl+left-click once running.
    .{ .id = .calendar, .x = 24, .y = 634 },
    // The single sticky note in the second column, under the desktop-icon
    // grid (which only reaches it past 16 shortcuts). Drag it anywhere
    // with Ctrl+left-click.
    .{ .id = .note1, .x = 380, .y = 860 },
    // The desktop-icon grid (~/Desktop shortcuts) floats top-center: both
    // side columns belong to the widget stacks. Its height
    // grows and shrinks with the scanned shortcut count; drag it anywhere
    // with Ctrl+left-click.
    .{ .id = .icons, .x = 380, .y = 24 },
    // The Fastfetch card takes the right column under the User card (≈ 480px
    // wide with Perihelion's feather logo; drag it anywhere).
    .{ .id = .fastfetch, .x = 1416, .y = 248 },
    // Top processes under the Fastfetch card on the right (≈ 250 x 197px
    // at six rows and the 13px font).
    .{ .id = .processes, .x = 1636, .y = 760 },
    // Network rates beside the Processes card, same width (≈ 122px tall
    // with the graph); under it they overlapped.
    .{ .id = .network, .x = 1376, .y = 760 },
    // Who and how long, above the Fastfetch card, right edges lined up
    // (336 x ≈ 92px at the 13px font).
    .{ .id = .user, .x = 1560, .y = 40 },
};

var shell_config_path_buf: [512]u8 = undefined;
var shell_config_path: [:0]const u8 = "";
var matugen_path_buf: [512]u8 = undefined;
var matugen_path: [:0]const u8 = "";
var reminders_path_buf: [512]u8 = undefined;
var reminders_path: [:0]const u8 = "";
var notes_dir_path_buf: [512]u8 = undefined;
var notes_dir_path: [:0]const u8 = "";
var desktop_dir_path_buf: [512]u8 = undefined;
var desktop_dir_path: [:0]const u8 = "";
var widgets_disabled_path_buf: [512]u8 = undefined;
var widgets_disabled_path: [:0]const u8 = "";
var shell_pidfile_path_buf: [512]u8 = undefined;
var shell_pidfile_path: [:0]const u8 = "";

/// SIGUSR1 live-reload flag: matugen's post_hook sends the shell the very
/// same signal it sends the bar (see [templates.perihelionbar] in
/// matugen/config.toml), so a wallpaper change reaches both at once. The
/// handler only raises this — file I/O is not async-signal-safe — and the
/// poll loop does the reading. The shell is single-threaded, so a plain flag
/// is enough here; the bar needs a self-pipe only because it isn't.
var g_reload_pending = std.atomic.Value(bool).init(false);

fn reloadSignalHandler(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = sig;
    _ = info;
    _ = ctx;
    g_reload_pending.store(true, .release);
}

// --- xkbcommon (hand-bound, like everything else in this shell) ------------

// The sticky notes translate compositor key events back into text, and only
// xkbcommon can interpret the keymap the compositor sends. The bar links it
// for the same reason; the C surface here is the four calls we need.
const xkb = struct {
    pub const Context = opaque {};
    pub const Keymap = opaque {};
    pub const State = opaque {};
    pub const CONTEXT_NO_FLAGS: c_uint = 0;
    pub const KEYMAP_FORMAT_TEXT_V1: c_uint = 1;
    pub const KEYMAP_COMPILE_NO_FLAGS: c_uint = 0;

    extern "c" fn xkb_context_new(flags: c_uint) ?*Context;
    extern "c" fn xkb_context_unref(ctx: ?*Context) void;
    extern "c" fn xkb_keymap_new_from_string(ctx: *Context, str: [*:0]const u8, format: c_uint, flags: c_uint) ?*Keymap;
    extern "c" fn xkb_keymap_unref(keymap: ?*Keymap) void;
    extern "c" fn xkb_state_new(keymap: *Keymap) ?*State;
    extern "c" fn xkb_state_unref(state: ?*State) void;
    extern "c" fn xkb_state_update_mask(state: *State, depressed: u32, latched: u32, locked: u32, depressed_layout: u32, latched_layout: u32, locked_layout: u32) c_int;
    extern "c" fn xkb_state_key_get_utf32(state: *State, key: u32) u32;
};

var g_xkb_ctx: ?*xkb.Context = null;
var g_xkb_keymap: ?*xkb.Keymap = null;
var g_xkb_state: ?*xkb.State = null;
/// True once the compositor's keymap has been compiled — note editing won't
/// decode anything before it (and the self-test waits for it).
var g_kb_ready = false;

fn resolveConfigPaths() void {
    const home = std.mem.span(getenv("HOME") orelse return);
    var dir_buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.config/perihelionbar", .{home}, 0) catch return;
    _ = posix.system.mkdir(dir.ptr, 0o755); // EEXIST on a normal first boot — best-effort
    shell_config_path = std.fmt.bufPrintSentinel(&shell_config_path_buf, "{s}/shell.json", .{dir}, 0) catch "";
    matugen_path = std.fmt.bufPrintSentinel(&matugen_path_buf, "{s}/matugen.json", .{dir}, 0) catch "";
    reminders_path = std.fmt.bufPrintSentinel(&reminders_path_buf, "{s}/reminders.txt", .{dir}, 0) catch "";
    notes_dir_path = std.fmt.bufPrintSentinel(&notes_dir_path_buf, "{s}/notes", .{dir}, 0) catch "";
    if (notes_dir_path.len > 0) _ = posix.system.mkdir(notes_dir_path.ptr, 0o755); // sticky-note slots
    // The shortcuts folder — the freedesktop ~/Desktop. Never mkdir'd
    // here on purpose: an empty desktop shows no grid, and the app
    // drawer's "Add to desktop" creates it on the first drop.
    const homez = std.mem.span(getenv("HOME") orelse "");
    desktop_dir_path = std.fmt.bufPrintSentinel(&desktop_dir_path_buf, "{s}/Desktop", .{homez}, 0) catch "";
    // Per-widget on/off list (written by perihelionbar-config, one widget id per
    // line): widgets named here are skipped at startup. Missing file means
    // all enabled, so fresh installs behave exactly as before. A separate
    // file rather than flags inside shell.json so the GUI never has to
    // rewrite shell.json (which would risk clobbering drag-persisted widget
    // positions); the GUI owns this file outright.
    widgets_disabled_path = std.fmt.bufPrintSentinel(&widgets_disabled_path_buf, "{s}/widgets-disabled", .{dir}, 0) catch "";
    // Pidfile so perihelionbar-config can restart the widgets when a toggle flips
    // (same convention as the bar's perihelionbar.pid).
    shell_pidfile_path = std.fmt.bufPrintSentinel(&shell_pidfile_path_buf, "{s}/perihelionbar-shell.pid", .{dir}, 0) catch "";
}

fn readFileAlloc(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    if (path.len == 0) return error.NoPath;
    const raw_fd = posix.system.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw_fd < 0) return error.OpenFailed;
    const fd: posix.fd_t = @intCast(raw_fd);
    defer _ = posix.system.close(fd);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &chunk) catch break;
        if (n == 0) break;
        try list.appendSlice(allocator, chunk[0..n]);
        if (list.items.len > 1024 * 1024) break; // sanity cap
    }
    return list.toOwnedSlice(allocator);
}

/// Bitmask of widgets the user switched off in perihelionbar-config: bit i is
/// @intFromEnum(WidgetId) for each id named (one per line) in the
/// widgets-disabled file. Missing/unreadable file = 0 (all enabled).
/// Unknown ids warn and skip rather than failing startup.
fn disabledMask(allocator: std.mem.Allocator) u16 {
    // The u16 mask (and u4 shifts below) hold at most 16 widgets — today
    // there are 11. Trip the compiler, not a runtime panic, if a 17th
    // arrives (tile_dirty is a u16 too).
    comptime {
        const n = std.meta.tags(widgets_mod.WidgetId).len;
        if (n > 16) @compileError("disabledMask: u16 mask holds at most 16 widgets");
        if (n > MAX_WIDGETS) @compileError("MAX_WIDGETS must cover every WidgetId");
    }
    if (widgets_disabled_path.len == 0) return 0;
    const bytes = readFileAlloc(allocator, widgets_disabled_path) catch return 0;
    defer allocator.free(bytes);
    var mask: u16 = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const id = std.mem.trim(u8, line, " \t\r");
        if (id.len == 0) continue;
        const e = switch (widgets_mod.parseWidgetId(id)) {
            .id => |v| v,
            // A card that no longer exists (the old watch): nothing to
            // switch off, and nothing worth a warning on every start.
            .retired => continue,
            .unknown => {
                logging.warn("widgets: unknown id \"{s}\" in widgets-disabled — skipping", .{id});
                continue;
            },
        };
        mask |= @as(u16, 1) << @as(u4, @intCast(@intFromEnum(e)));
    }
    return mask;
}

/// Compacts cfg.widget_cfgs in place, dropping widgets the user switched off
/// (see disabledMask). Runs on a startup copy in main(), not on g_shell_cfg —
/// positions of dropped widgets stay in shell.json untouched, so re-enabling
/// restores them where they were.
fn applyDisabledWidgets(allocator: std.mem.Allocator, cfg: *ShellConfig) void {
    const mask = disabledMask(allocator);
    if (mask == 0) return;
    var n: usize = 0;
    for (cfg.widget_cfgs[0..cfg.widget_count]) |wc| {
        const bit: u16 = @as(u16, 1) << @as(u4, @intCast(@intFromEnum(wc.id)));
        if (mask & bit != 0) {
            logging.step("widgets: {s} switched off — skipping", .{@tagName(wc.id)});
            continue;
        }
        cfg.widget_cfgs[n] = wc;
        n += 1;
    }
    cfg.widget_count = n;
}

/// Writes this process's PID to ~/.config/perihelionbar/perihelionbar-shell.pid so
/// perihelionbar-config knows what to signal when the widgets switch flips.
/// Best effort, mirroring the bar's writePidfile — a missing pidfile just
/// means the GUI falls back to spawning, never a reason to fail startup.
fn writeShellPidfile() void {
    if (shell_pidfile_path.len == 0) return;
    const raw_fd = posix.system.open(shell_pidfile_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(posix.mode_t, 0o644));
    if (raw_fd < 0) return;
    const fd: posix.fd_t = @intCast(raw_fd);
    defer _ = posix.system.close(fd);
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{std.c.getpid()}) catch return;
    var off: usize = 0;
    while (off < text.len) {
        const n = posix.system.write(fd, text[off..].ptr, text.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn parseHexColor(s: []const u8) !u32 {
    if (s.len != 7 or s[0] != '#') return error.InvalidColor;
    const rgb = try std.fmt.parseInt(u32, s[1..7], 16);
    return 0xFF000000 | rgb;
}

/// The startup config, kept around so config writes (drag-persisted widget
/// positions) can round-trip every other key untouched.
var g_shell_cfg: ShellConfig = blk: {
    var c = ShellConfig{};
    for (DEFAULT_WIDGETS, 0..) |dw, i| c.widget_cfgs[i] = dw;
    c.widget_count = DEFAULT_WIDGETS.len;
    break :blk c;
};

/// Reads shell.json (missing/malformed → defaults). Read once at startup —
/// no live reload in v1.
fn loadConfig(gpa: std.mem.Allocator) ShellConfig {
    var cfg = ShellConfig{};
    for (DEFAULT_WIDGETS, 0..) |dw, i| cfg.widget_cfgs[i] = dw;
    cfg.widget_count = DEFAULT_WIDGETS.len;
    // Dash defaults until shell.json lists its own overview_favorites.
    for (overview_mod.DEFAULT_FAVS, 0..) |f, i| cfg.fav_cmds[i] = f;
    cfg.fav_count = overview_mod.DEFAULT_FAVS.len;
    g_shell_cfg = cfg;
    if (shell_config_path.len == 0) return cfg;

    const bytes = readFileAlloc(gpa, shell_config_path) catch |err| {
        if (err != error.OpenFailed) {
            logging.warn("config: could not read {s}: {}", .{ shell_config_path, err });
        }
        return cfg;
    };
    defer gpa.free(bytes);

    // alloc_always: the default (alloc_if_needed) would leave string fields
    // pointing into `bytes`, which is freed below — a dangling holiday_country
    // then segfaults the calendar widget's configure(). Strings must outlive
    // this function (they land in cfg / g_shell_cfg for the process lifetime).
    const parsed = std.json.parseFromSliceLeaky(JsonConfig, gpa, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        logging.warn("config: could not parse {s}: {} — keeping defaults", .{ shell_config_path, err });
        return cfg;
    };

    if (parsed.font_path) |fp| {
        if (fp.len > 0) cfg.font_path = fp;
    }
    if (parsed.card_bg_opacity) |a| cfg.card_bg_opacity = @min(a, 100);
    if (parsed.card_corner_radius) |r| cfg.corner_radius = r;
    if (parsed.holiday_country) |hc| {
        if (hc.len > 0) cfg.holiday_country = hc;
    }
    if (parsed.holiday_region) |hr| cfg.holiday_region = hr;
    if (parsed.weather_latitude) |v| cfg.weather_latitude = v;
    if (parsed.weather_longitude) |v| cfg.weather_longitude = v;
    if (parsed.weather_city) |v| cfg.weather_city = v;
    if (parsed.weather_units) |v| {
        if (weather_service.Units.parse(v)) |u| {
            cfg.weather_units = u;
            cfg.weather_units_auto = false;
        } else {
            if (!std.ascii.eqlIgnoreCase(v, "auto")) logging.warn("config: weather_units \"{s}\" is not auto, C or F — using auto", .{v});
            cfg.weather_units_auto = true;
        }
    }
    if (parsed.weather_click) |v| {
        cfg.weather_click = widgets_mod.WeatherClick.parse(v) orelse blk: {
            logging.warn("config: weather_click \"{s}\" is not forecast or units — using forecast", .{v});
            break :blk .forecast;
        };
    }
    if (parsed.weather_auto_location) |v| cfg.weather_auto_location = v;
    if (parsed.weather_refresh_minutes) |v| cfg.weather_refresh_minutes = std.math.clamp(v, 1, 1440);
    if (parsed.weather_ip_url) |v| cfg.weather_ip_url = v;
    if (parsed.system_gpu) |v| {
        if (v.len > 0) cfg.system_gpu = v;
    }
    if (parsed.system_temp_units) |v| {
        cfg.system_temp_units = temps_service.Units.parse(v) orelse blk: {
            logging.warn("config: system_temp_units \"{s}\" is not C or F — using C", .{v});
            break :blk .celsius;
        };
    }
    if (parsed.system_temp_interval_seconds) |v| cfg.system_temp_interval_seconds = std.math.clamp(v, 1, 60);
    if (parsed.system_nvidia_smi) |v| cfg.system_nvidia_smi = v;
    if (parsed.fastfetch_fields) |names| {
        var unknown: usize = 0;
        cfg.fastfetch_field_count = ff_service.parseFields(names, &cfg.fastfetch_fields, &unknown);
        if (unknown > 0) logging.warn("config: fastfetch_fields has {d} unknown name(s) — skipped", .{unknown});
    }
    if (parsed.fastfetch_refresh_minutes) |v| cfg.fastfetch_refresh_minutes = @min(v, 1440);
    if (parsed.fastfetch_binary) |v| cfg.fastfetch_binary = v;
    if (parsed.fastfetch_logo) |v| {
        if (v.len > 0) cfg.fastfetch_logo = v;
    }
    if (parsed.fastfetch_config) |v| cfg.fastfetch_config = v;
    if (parsed.clock_style) |v| {
        cfg.clock.style = widgets_mod.ClockStyle.parse(v) orelse blk: {
            logging.warn("config: clock_style \"{s}\" unknown (digital|flip|stacked|classic) — using digital", .{v});
            break :blk .digital;
        };
    }
    if (parsed.clock_24h) |v| cfg.clock.h24 = v;
    if (parsed.clock_seconds) |v| cfg.clock.seconds = v;
    if (parsed.clock_date) |v| cfg.clock.date = v;
    if (parsed.system_style) |v| {
        cfg.system_style = widgets_mod.SystemStyle.parse(v) orelse blk: {
            logging.warn("config: system_style \"{s}\" unknown (columns|bars|rings) — using columns", .{v});
            break :blk .columns;
        };
    }
    if (parsed.processes_sort) |v| {
        cfg.processes_sort = procs_service.Sort.parse(v) orelse blk: {
            logging.warn("config: processes_sort \"{s}\" unknown (cpu|memory) — using cpu", .{v});
            break :blk .cpu;
        };
    }
    if (parsed.processes_count) |v| cfg.processes_count = @intCast(std.math.clamp(@as(usize, v), procs_service.MIN_SHOWN, procs_service.MAX_SHOWN));
    if (parsed.processes_interval_seconds) |v| cfg.processes_interval_seconds = std.math.clamp(v, 1, 60);
    if (parsed.processes_group) |v| cfg.processes_group = v;
    if (parsed.network_graph) |v| cfg.network_graph = v;
    if (parsed.user_host) |v| cfg.user_host = v;
    if (parsed.user_uptime_short) |v| cfg.user_uptime_short = v;
    if (parsed.user_show_name) |v| cfg.user_show_name = v;
    if (parsed.network_interval_seconds) |v| cfg.network_interval_seconds = std.math.clamp(v, netrate_service.MIN_INTERVAL_S, netrate_service.MAX_INTERVAL_S);
    if (parsed.calendar_reminders) |v| cfg.calendar_reminders = @intCast(@min(@as(usize, v), widgets_mod.CAL_REMINDER_ROWS_MAX));
    if (parsed.notes_tabs) |v| cfg.notes.tabs = v;
    if (parsed.notes_checklists) |v| cfg.notes.checklists = v;
    if (parsed.notes_lines) |v| cfg.notes.lines = std.math.clamp(@as(i64, v), 3, 30);
    if (parsed.notes_dir) |v| cfg.notes_dir = v;
    if (parsed.notes_page) |v| cfg.notes_page = @intCast(std.math.clamp(v, 1, widgets_mod.NoteWidget.MAX_PAGES));
    if (parsed.glance_enabled) |v| cfg.glance_enabled = v;
    if (parsed.glance_start_tab) |v| {
        cfg.glance_start_tab = glance.Tab.parse(v) orelse blk: {
            logging.warn("config: glance_start_tab \"{s}\" unknown (overview|media|weather) — using overview", .{v});
            break :blk .overview;
        };
    }
    if (parsed.overview_favorites) |fs| {
        // An explicit list replaces the defaults entirely (including an
        // explicit empty list = no dash). Strings are alloc_always, so they
        // live for the process — saveConfig round-trips them later.
        var n: usize = 0;
        for (fs) |f| {
            if (f.len == 0 or n >= overview_mod.MAX_FAVS) continue;
            cfg.fav_cmds[n] = f;
            n += 1;
        }
        cfg.fav_count = n;
    }
    if (parsed.widgets) |ws| {
        if (ws.len == 0) {
            cfg.widget_count = 0; // explicit empty list = all widgets off
            g_shell_cfg = cfg;
            return cfg;
        }
        var count: usize = 0;
        for (ws) |w| {
            if (count >= MAX_WIDGETS) break;
            const id = switch (widgets_mod.parseWidgetId(w.id)) {
                .id => |v| v,
                // Removed cards (the old watch) drop out silently; the
                // next saveConfig writes the list without them.
                .retired => continue,
                .unknown => {
                    logging.warn("config: unknown widget id \"{s}\" — skipping", .{w.id});
                    continue;
                },
            };
            cfg.widget_cfgs[count] = .{ .id = id, .x = w.x, .y = w.y, .w = w.w orelse 0, .h = w.h orelse 0 };
            count += 1;
        }
        // Backfill defaults for widgets shell.json doesn't name (it only
        // gains entries when a widget is dragged, so never-dragged widgets
        // would otherwise vanish entirely): every widget always exists with
        // a position, and widgets-disabled alone controls visibility. This
        // mirrors the bar GUI's ensureKindsPresent for the same "modules
        // disappeared" trap.
        for (DEFAULT_WIDGETS) |dw| {
            var found = false;
            for (cfg.widget_cfgs[0..count]) |wc| {
                if (wc.id == dw.id) {
                    found = true;
                    break;
                }
            }
            if (!found and count < MAX_WIDGETS) {
                cfg.widget_cfgs[count] = dw;
                count += 1;
            }
        }
        cfg.widget_count = count;
    }
    g_shell_cfg = cfg;
    return cfg;
}

/// Merges the matugen palette (same keys the bar reads) when present.
/// Any failure keeps the defaults entirely.
fn tryApplyMatugenColors(gpa: std.mem.Allocator, theme: *widgets_mod.Theme) bool {
    if (matugen_path.len == 0) return false;
    const bytes = readFileAlloc(gpa, matugen_path) catch |err| {
        if (err != error.OpenFailed) {
            logging.warn("config: could not read {s}: {}", .{ matugen_path, err });
        }
        return false;
    };
    defer gpa.free(bytes);
    const colors = std.json.parseFromSliceLeaky(JsonMatugenColors, gpa, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        logging.warn("config: could not parse {s}: {} — keeping defaults", .{ matugen_path, err });
        return false;
    };
    if (colors.bg_color) |hex| {
        theme.bg_color = parseHexColor(hex) catch theme.bg_color;
    }
    if (colors.text_color) |hex| {
        theme.text_color = parseHexColor(hex) catch theme.text_color;
    }
    if (colors.border_color) |hex| {
        theme.border_color = parseHexColor(hex) catch theme.border_color;
    }
    if (colors.hover_color) |hex| {
        theme.hover_color = parseHexColor(hex) catch theme.hover_color;
    }
    if (colors.holiday_color) |hex| {
        theme.holiday_color = parseHexColor(hex) catch theme.holiday_color;
    }
    if (colors.matrix_color) |hex| {
        theme.accent2_color = parseHexColor(hex) catch theme.accent2_color;
    }
    if (colors.card_bg_opacity) |a| theme.card_alpha = @min(a, 100);
    return true;
}

/// Re-reads the palette on SIGUSR1 so a wallpaper change reaches the widgets
/// the same moment it reaches the bar. Rebuilt from defaults exactly like the
/// startup path — never mutated — so a key dropped from the file falls back
/// instead of carrying yesterday's value forward; shell.json's card alpha and
/// corner radius are carried over untouched. Widget *placement* is
/// deliberately not re-applied (that needs a rebuild, and the hook only ever
/// fires for palette changes). With no readable file the current palette
/// stays put rather than snapping back to grey defaults.
fn reloadTheme(host: *Host) void {
    var theme = widgets_mod.Theme{
        // shell.json's value, so a palette without card_bg_opacity goes back
        // to it after one (Material You) that set its own.
        .card_alpha = g_shell_cfg.card_bg_opacity,
        .radius_px = host.theme.radius_px,
    };
    if (!tryApplyMatugenColors(host.gpa, &theme)) {
        logging.warn("theme: reload found no matugen colors — keeping the current palette", .{});
        return;
    }
    host.theme = theme;
    host.backdrop_checked = false; // the wallpaper may have changed with it
    // Every cached tile still holds the old colours, so invalidate all of
    // them — the same frame-wide reset the hover path uses.
    markAllDirty(host);
    if (host.glance) |gl| gl.themeChanged();
    logging.step("theme: reloaded matugen colors", .{});
}

fn setCloexec(fd: posix.fd_t) void {
    _ = std.c.fcntl(fd, 2, @as(c_int, 1)); // F_SETFD, FD_CLOEXEC
}

fn fontPathZ(path: []const u8, buf: []u8) ?[:0]const u8 {
    if (path.len == 0 or path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

// --- Wayland plumbing ------------------------------------------------------

const Globals = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    /// zwlr_screencopy_manager_v1 (bound at v1, see overview.zig): the
    /// overview's real window thumbnails. Absent on compositors without it
    /// — the overview falls back to icon cards.
    screencopy: ?*zwlr.ScreencopyManagerV1 = null,
    seat: ?*wl.Seat = null,
    seat_has_pointer: bool = false,
    seat_has_keyboard: bool = false,
    /// Outputs + their wl_output.name (v4) — the names tie hyprctl's JSON
    /// ("focused monitor") to a real wl_output for screencopy/layer mapping.
    outputs: overview_mod.OutputSet = .{},
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |g| {
            const iface = std.mem.sliceTo(g.interface, 0);
            if (std.mem.eql(u8, iface, "wl_compositor")) {
                globals.compositor = registry.bind(g.name, wl.Compositor, 4) catch return;
            } else if (std.mem.eql(u8, iface, "wl_shm")) {
                globals.shm = registry.bind(g.name, wl.Shm, 1) catch return;
            } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
                globals.layer_shell = registry.bind(g.name, zwlr.LayerShellV1, 4) catch return;
            } else if (std.mem.eql(u8, iface, "wl_seat")) {
                const seat = registry.bind(g.name, wl.Seat, 7) catch return;
                globals.seat = seat;
                seat.setListener(*Globals, seatListener, globals);
            } else if (std.mem.eql(u8, iface, "wl_output")) {
                const output = registry.bind(g.name, wl.Output, 4) catch return;
                const slot = globals.outputs.add(output) orelse return;
                output.setListener(*overview_mod.OutputSet.Slot, overview_mod.OutputSet.listener, slot);
            } else if (std.mem.eql(u8, iface, "zwlr_screencopy_manager_v1")) {
                // v1 is all the overview needs (buffer/copy/ready/failed),
                // and skipping v3's buffer_done handshake keeps the capture
                // state machine trivial — bind below whatever's advertised.
                globals.screencopy = registry.bind(g.name, zwlr.ScreencopyManagerV1, @min(g.version, 1)) catch return;
            }
        },
        .global_remove => {},
    }
}

fn seatListener(_: *wl.Seat, event: wl.Seat.Event, globals: *Globals) void {
    switch (event) {
        .capabilities => |caps| {
            globals.seat_has_pointer = caps.capabilities.pointer;
            globals.seat_has_keyboard = caps.capabilities.keyboard;
        },
        .name => {},
    }
}

const Desktop = struct {
    host: *Host,
    surface: *wl.Surface,
    layer_surface: *zwlr.LayerSurfaceV1,
    width: u32 = 0,
    height: u32 = 0,
    configured: bool = false,
};

const Host = struct {
    gpa: std.mem.Allocator,
    theme: widgets_mod.Theme,
    font: *font_mod.Font,
    shm: *wl.Shm,
    compositor: *wl.Compositor,
    desktops: [MAX_OUTPUTS]Desktop = undefined,
    desktop_count: usize = 0,
    widgets: [MAX_WIDGETS]widgets_mod.Widget = undefined,
    widget_rects: [MAX_WIDGETS]widgets_mod.Rect = undefined,
    widget_count: usize = 0,
    next_tick_ms: [MAX_WIDGETS]i64 = @as([MAX_WIDGETS]i64, @splat(0)),
    needs_repaint: bool = false,
    /// Per-widget ARGB tile cache (allocated in initWidgets, freed in
    /// main): a widget re-renders into its own tile only when its
    /// `tile_dirty` bit is set, and every frame just composites the tiles
    /// onto a fresh zero-filled surface. A card that changes then costs
    /// one tile repaint instead of re-rastering every widget on every
    /// output.
    tiles: [MAX_WIDGETS]?[]u32 = @as([MAX_WIDGETS]?[]u32, @splat(null)),
    tile_dirty: u16 = 0xFFFF, // all dirty until first paint; MAX_WIDGETS ≤ 16
    /// Frosted glass behind the cards: the wallpaper, decoded small and
    /// blurred once (glass.zig). Re-read on startup and on each palette
    /// reload (a wallpaper change always comes with one). A card shows the
    /// part under it, so a tile that moves (drag) re-renders at its new spot.
    backdrop: glass.Backdrop = .{},
    backdrop_checked: bool = false,
    tile_origin: [MAX_WIDGETS][2]i32 = @as([MAX_WIDGETS][2]i32, @splat(.{ std.math.minInt(i32), 0 })),
    /// Per-widget zoomed fonts (corner resize scales content, not just the
    /// card): slot i holds a face at the integer pixel size matching the
    /// widget's current zoom, or null when it renders at base size / the
    /// scaled load failed. Re-created only when the size bucket changes.
    /// Note1 never zooms (it reflows) and always uses the shared font.
    zoom_fonts: [MAX_WIDGETS]?font_mod.Font = @as([MAX_WIDGETS]?font_mod.Font, @splat(null)),
    zoom_px: [MAX_WIDGETS]u32 = @as([MAX_WIDGETS]u32, @splat(0)),
    hovered_index: ?usize = null,
    pointer_desktop: ?usize = null,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    // Sticky-note editing: the one note currently receiving keys via the
    // compositor's on_demand keyboard grab. The host owns the slot (the
    // widget owns text/caret) and the key-repeat clock.
    edit_index: ?usize = null,
    /// Wheel motion not yet turned into whole lines (onWheel).
    wheel_accum: f64 = 0,
    repeat_key: ?u32 = null,
    repeat_next_ms: i64 = 0,
    kb_rate: i32 = 0, // key auto-repeat from wl_keyboard.repeat_info (0 = off)
    kb_delay: i32 = 400,
    // Ctrl+drag state. A press is held pending until release so the Ctrl
    // decision survives the focus-on-click ordering (the modifiers event can
    // arrive just after the press): press+Ctrl becomes a drag, anything else
    // becomes a click on release.
    ctrl_down: bool = false,
    // Perihelion: Alt + right-click removes a widget. The right press is held
    // here until the modifiers event (which can follow the press) says Alt.
    alt_down: bool = false,
    pending_right: ?usize = null,
    left_down: bool = false,
    press_index: ?usize = null,
    drag_index: ?usize = null,
    drag_off_x: i32 = 0,
    drag_off_y: i32 = 0,
    /// Corner-resize grab: press on a card's bottom-right grip starts a
    /// live resize (top-left pinned) instead of a click or a move. Offsets
    /// keep the grabbed corner under the pointer, mirroring drag_off_*.
    resize_index: ?usize = null,
    resize_off_x: i32 = 0,
    resize_off_y: i32 = 0,
    // Overview mode (Alt+W): a second layer surface on the overlay layer,
    // created on open and destroyed on close. Null when construction
    // failed — that degrades the feature, never the shell.
    overview: ?*overview_mod.Overview = null,
    /// True while pointer focus sits on the overview surface rather than a
    /// desktop surface (routes motion/clicks there instead of widgets).
    pointer_over_ov: bool = false,
    /// Glance (Super+I): its own overlay surface, built on open and freed
    /// on close. Null when shell.json switches it off.
    glance: ?*glance_view.Glance = null,
    /// True while pointer focus sits on the Glance surface.
    pointer_over_gl: bool = false,
};

/// The pre-Open-Meteo card read a city or ZIP from the first line of
/// ~/.config/perihelionbar/weather-location; keep honouring it when
/// shell.json names no weather_city, so upgrades keep their place.
fn legacyWeatherLocation(gpa: std.mem.Allocator, out: []u8) []const u8 {
    const home = std.mem.span(getenv("HOME") orelse return "");
    var pbuf: [512]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pbuf, "{s}/.config/perihelionbar/weather-location", .{home}, 0) catch return "";
    const text = readFileAlloc(gpa, path) catch return "";
    defer gpa.free(text);
    const first = if (std.mem.indexOfScalar(u8, text, '\n')) |i| text[0..i] else text;
    const line = std.mem.trim(u8, first, " \t\r");
    const n = @min(line.len, out.len);
    @memcpy(out[0..n], line[0..n]);
    return out[0..n];
}

/// Owns the system_gpu string after a click: the widget's own buffer
/// changes on the next click, so g_shell_cfg must not point into it.
var g_system_gpu_buf: [32]u8 = undefined;

/// After a °C/°F click: SIGUSR2 to the bar, if its pidfile names a live
/// bar process (perihelion-bar, or the perihelionbar link older configs
/// start it by). Saved before this runs, so the bar reads the new value.
const BAR_WEATHER_RELOAD_CMD =
    "p=$(cat \"$HOME/.config/perihelionbar/perihelionbar.pid\" 2>/dev/null); " ++
    "case \"$p\" in ''|*[!0-9]*) exit 0;; esac; " ++
    "case \"$(cat /proc/$p/comm 2>/dev/null)\" in perihelionbar|perihelion-bar) kill -USR2 \"$p\";; esac";

fn configureWeather(w: *widgets_mod.WeatherWidget, gpa: std.mem.Allocator, cfg: *const ShellConfig) void {
    var legacy_buf: [96]u8 = undefined;
    const city = if (cfg.weather_city.len > 0) cfg.weather_city else legacyWeatherLocation(gpa, &legacy_buf);
    var cache_buf: [400]u8 = undefined;
    // Service.init copies every string, so the stack buffer may go.
    w.configure(.{
        .latitude = cfg.weather_latitude,
        .longitude = cfg.weather_longitude,
        .city = city,
        .auto_location = cfg.weather_auto_location,
        .units = cfg.weather_units,
        .units_auto = cfg.weather_units_auto,
        .refresh_ms = @as(i64, cfg.weather_refresh_minutes) * 60_000,
        .ip_url = cfg.weather_ip_url,
        // Shared with the top bar: whichever process fetched last, the
        // other adopts that answer instead of asking Open-Meteo again.
        .cache_path = weather_service.defaultCachePath(&cache_buf),
    });
}

/// The Fastfetch card's service, set up before initWidgets measures cards:
/// its size depends on the configured rows and on the logo it found.
var g_ff_service: ff_service.Service = .{};

fn prepareFastfetch(cfg: *const ShellConfig) void {
    for (cfg.widget_cfgs[0..cfg.widget_count]) |wc| {
        if (wc.id != .fastfetch) continue;
        g_ff_service = ff_service.Service.init(.{
            .config = cfg.fastfetch_config,
            .fields = if (cfg.fastfetch_field_count > 0) cfg.fastfetch_fields[0..cfg.fastfetch_field_count] else &ff_service.DEFAULT_FIELDS,
            .refresh_ms = @as(i64, cfg.fastfetch_refresh_minutes) * 60_000,
            .binary = cfg.fastfetch_binary,
            .logo = cfg.fastfetch_logo,
        });
        if (cfg.fastfetch_binary.len > 0 and !std.ascii.eqlIgnoreCase(cfg.fastfetch_binary, "none") and
            g_ff_service.source != .custom)
        {
            logging.warn("fastfetch: fastfetch_binary \"{s}\" is not an executable — auto-detecting", .{cfg.fastfetch_binary});
        }
        if (g_ff_service.layout == .config) {
            logging.step("fastfetch: card follows {s} ({d} rows)", .{ g_ff_service.config_path.slice(), g_ff_service.row_count });
        } else if (cfg.fastfetch_config.len > 0 and !std.ascii.eqlIgnoreCase(cfg.fastfetch_config, "none")) {
            logging.warn("fastfetch: fastfetch_config \"{s}\" is missing or has no modules — using fastfetch_fields", .{cfg.fastfetch_config});
        }
        logging.step("fastfetch: using {s}{s}{s}; logo: {s}", .{
            g_ff_service.source.describe(),
            if (g_ff_service.bin.len > 0 and g_ff_service.source != .native) " at " else "",
            if (g_ff_service.source != .native) g_ff_service.bin.slice() else "",
            if (g_ff_service.logo_off) "off" else if (g_ff_service.logo_count > 0) "fastfetch config text logo" else "distro glyph",
        });
        widgets_mod.setFastfetchLayout(&g_ff_service);
        return;
    }
}

var notes_custom_dir_buf: [300]u8 = undefined;

/// The notes folder: shell.json notes_dir ("~/" = $HOME, trailing slashes
/// dropped, created if missing), else ~/.config/perihelionbar/notes.
fn resolveNotesDir(want: []const u8) []const u8 {
    const d = std.mem.trimEnd(u8, want, "/");
    if (d.len == 0) return notes_dir_path;
    const path = if (std.mem.startsWith(u8, d, "~/"))
        std.fmt.bufPrintSentinel(&notes_custom_dir_buf, "{s}{s}", .{ std.mem.span(getenv("HOME") orelse ""), d[1..] }, 0)
    else
        std.fmt.bufPrintSentinel(&notes_custom_dir_buf, "{s}", .{d}, 0);
    const z = path catch {
        logging.warn("config: notes_dir is too long — using the default folder", .{});
        return notes_dir_path;
    };
    _ = posix.system.mkdir(z.ptr, 0o755); // EEXIST is the normal case
    return z;
}

fn jsonBool(v: bool) []const u8 {
    return if (v) "true" else "false";
}

fn initWidgets(host: *Host, cfg: ShellConfig) void {
    prepareFastfetch(&cfg);
    // Card sizes depend on these, so they're set before anything is measured.
    widgets_mod.clock_layout = cfg.clock;
    widgets_mod.system_style = cfg.system_style;
    widgets_mod.processes_rows = cfg.processes_count;
    widgets_mod.calendar_reminder_rows = cfg.calendar_reminders;
    widgets_mod.network_graph = cfg.network_graph;
    widgets_mod.user_host = cfg.user_host;
    widgets_mod.user_uptime_short = cfg.user_uptime_short;
    widgets_mod.user_show_name = cfg.user_show_name;
    widgets_mod.notes_layout = cfg.notes;
    widgets_mod.weather_click = cfg.weather_click;
    for (cfg.widget_cfgs[0..cfg.widget_count]) |wc| {
        // Base size for the type, overridden by a persisted corner resize
        // (clamped: never below the designed base, never absurd — a
        // hand-edited monster still gets a tile).
        const base = widgets_mod.cardSizeFor(wc.id, host.font);
        var size = base;
        if (wc.w != 0) size[0] = @max(wc.w, base[0]);
        if (wc.h != 0) size[1] = @max(wc.h, base[1]);
        size[0] = @min(size[0], 2048);
        size[1] = @min(size[1], 2048);
        host.widgets[host.widget_count] = switch (wc.id) {
            .clock => .{ .clock = .{} },
            .weather => .{ .weather = .{} },
            .media => .{ .media = .{} },
            .system => .{ .system = .{} },
            .calendar => .{ .calendar = .{} },
            .note1 => .{ .note1 = .{} },
            .icons => .{ .icons = .{} },
            .fastfetch => .{ .fastfetch = .{} },
            .processes => .{ .processes = .{} },
            .network => .{ .network = .{} },
            .user => .{ .user = .{} },
        };
        if (wc.id == .calendar) {
            host.widgets[host.widget_count].calendar.configure(
                reminders_path,
                cfg.holiday_country,
                cfg.holiday_region,
            );
        } else switch (wc.id) {
            // Sticky note loads its text (possibly empty) from disk.
            .note1 => host.widgets[host.widget_count].note1.configure(resolveNotesDir(cfg.notes_dir), cfg.notes_page),
            // Desktop icons arm the inotify watch and take their first
            // scan right away; sizing waits for the first paintDesktop.
            .icons => host.widgets[host.widget_count].icons.configure(host.gpa, desktop_dir_path),
            // Location, units and refresh cadence from shell.json.
            .weather => configureWeather(&host.widgets[host.widget_count].weather, host.gpa, &cfg),
            .system => host.widgets[host.widget_count].system.configure(.{
                .interval_ms = @as(i64, cfg.system_temp_interval_seconds) * 1000,
                .gpu = cfg.system_gpu,
                .nvidia_smi = cfg.system_nvidia_smi,
            }, cfg.system_temp_units),
            .fastfetch => host.widgets[host.widget_count].fastfetch.configure(&g_ff_service),
            .processes => host.widgets[host.widget_count].processes.configure(.{
                .sort = cfg.processes_sort,
                .count = cfg.processes_count,
                .interval_ms = @as(i64, cfg.processes_interval_seconds) * 1000,
                .group = cfg.processes_group,
            }),
            .network => host.widgets[host.widget_count].network.configure(.{
                .interval_ms = @as(i64, cfg.network_interval_seconds) * 1000,
            }),
            else => {},
        }
        host.widget_rects[host.widget_count] = .{
            .x = wc.x,
            .y = wc.y,
            .w = size[0],
            .h = size[1],
        };
        // Its private paint tile (see Host.tiles). OOM here can't be
        // recovered from — the widget would have nowhere to draw — so log
        // and leave the tile null; paintDesktop skips null tiles.
        const n = host.widget_count;
        host.tiles[n] = blk: {
            const area: usize = @as(usize, size[0]) * @as(usize, size[1]);
            break :blk host.gpa.alloc(u32, area) catch |err| {
                logging.err("widgets: could not allocate {s} tile: {}", .{ @tagName(wc.id), err });
                break :blk null;
            };
        };
        host.widget_count += 1;
    }
}

/// The allocator, for Glance's card setup (a plain function pointer, so it
/// can't carry the Host along).
var g_gpa: std.mem.Allocator = undefined;

/// Glance's fresh card instances get the desktop cards' settings: weather
/// place and units, calendar holidays and reminders, temperature sensors.
/// Clock, User and Media read the shared layout globals initWidgets set.
fn setupGlanceCards(cards: *glance_view.Cards) void {
    for (cards) |*c| switch (c.*) {
        .weather => |*w| configureWeather(w, g_gpa, &g_shell_cfg),
        .calendar => |*k| k.configure(reminders_path, g_shell_cfg.holiday_country, g_shell_cfg.holiday_region),
        .system => |*sy| sy.configure(.{
            .interval_ms = @as(i64, g_shell_cfg.system_temp_interval_seconds) * 1000,
            .gpu = g_shell_cfg.system_gpu,
            .nvidia_smi = g_shell_cfg.system_nvidia_smi,
        }, g_shell_cfg.system_temp_units),
        else => {},
    };
}

/// Restricts the desktop surface's input to the union of widget rects so the
/// rest of the desktop passes clicks through to windows.
fn setInputRegion(host: *Host, d: *Desktop) void {
    const region = host.compositor.createRegion() catch return;
    defer region.destroy();
    for (0..host.widget_count) |i| {
        const r = host.widget_rects[i];
        region.add(r.x, r.y, @intCast(r.w), @intCast(r.h));
    }
    d.surface.setInputRegion(region);
}

/// Applies the (possibly moved) widget rects to every output's input region.
fn refreshInputRegions(host: *Host) void {
    for (0..host.desktop_count) |i| setInputRegion(host, &host.desktops[i]);
}

/// Escapes a string into a JSON double-quoted value body.
fn jsonEscape(s: []const u8, out: []u8) ?[]const u8 {
    var n: usize = 0;
    for (s) |ch| {
        if (ch == '"' or ch == '\\') {
            if (n + 2 > out.len) return null;
            out[n] = '\\';
            out[n + 1] = ch;
            n += 2;
        } else if (ch >= 0x20) {
            if (n + 1 > out.len) return null;
            out[n] = ch;
            n += 1;
        }
    }
    return out[0..n];
}

/// Writes shell.json with the current widget positions (after a drag),
/// round-tripping every other key from the config loaded at startup.
/// Temp file + rename so a crash mid-write can't corrupt the config.
fn saveConfig(host: *Host) void {
    if (shell_config_path.len == 0) return;

    const W = struct {
        buf: []u8,
        len: usize = 0,
        fn append(self: *@This(), s: []const u8) bool {
            if (self.len + s.len > self.buf.len) return false;
            @memcpy(self.buf[self.len..][0..s.len], s);
            self.len += s.len;
            return true;
        }
        fn appendFmt(self: *@This(), comptime fmt: []const u8, args: anytype) bool {
            const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return false;
            self.len += s.len;
            return true;
        }
    };

    var out: [8192]u8 = undefined;
    var w = W{ .buf = &out };
    // One scratch escape buffer, reused per field — each escaped value is
    // appended (copied into `out`) before the next escape overwrites it.
    var esc: [600]u8 = undefined;

    const font_esc = jsonEscape(g_shell_cfg.font_path, &esc) orelse return;
    if (!w.appendFmt(
        "{{\n  \"font_path\": \"{s}\",\n  \"card_bg_opacity\": {d},\n  \"card_corner_radius\": {d},\n",
        .{ font_esc, g_shell_cfg.card_bg_opacity, g_shell_cfg.corner_radius },
    )) return;
    const country_esc = jsonEscape(g_shell_cfg.holiday_country, &esc) orelse return;
    if (!w.appendFmt("  \"holiday_country\": \"{s}\",\n", .{country_esc})) return;
    const region_esc = jsonEscape(g_shell_cfg.holiday_region, &esc) orelse return;
    if (!w.appendFmt("  \"holiday_region\": \"{s}\",\n", .{region_esc})) return;
    // Weather keys are always written (null coordinates = unset) so they
    // are discoverable in the file; weather_units also changes on click.
    const wcity_esc = jsonEscape(g_shell_cfg.weather_city, &esc) orelse return;
    if (!w.appendFmt("  \"weather_city\": \"{s}\",\n", .{wcity_esc})) return;
    if (g_shell_cfg.weather_latitude) |lat| {
        if (!w.appendFmt("  \"weather_latitude\": {d},\n", .{lat})) return;
    } else {
        if (!w.append("  \"weather_latitude\": null,\n")) return;
    }
    if (g_shell_cfg.weather_longitude) |lon| {
        if (!w.appendFmt("  \"weather_longitude\": {d},\n", .{lon})) return;
    } else {
        if (!w.append("  \"weather_longitude\": null,\n")) return;
    }
    const auto_loc: []const u8 = if (g_shell_cfg.weather_auto_location) "true" else "false";
    if (!w.appendFmt(
        "  \"weather_units\": \"{s}\",\n  \"weather_click\": \"{s}\",\n  \"weather_auto_location\": {s},\n  \"weather_refresh_minutes\": {d},\n",
        .{ if (g_shell_cfg.weather_units_auto) "auto" else g_shell_cfg.weather_units.tag(), @tagName(g_shell_cfg.weather_click), auto_loc, g_shell_cfg.weather_refresh_minutes },
    )) return;
    const wip_esc = jsonEscape(g_shell_cfg.weather_ip_url, &esc) orelse return;
    if (!w.appendFmt("  \"weather_ip_url\": \"{s}\",\n", .{wip_esc})) return;
    const sgpu_esc = jsonEscape(g_shell_cfg.system_gpu, &esc) orelse return;
    const smi: []const u8 = if (g_shell_cfg.system_nvidia_smi) "true" else "false";
    if (!w.appendFmt(
        "  \"system_gpu\": \"{s}\",\n  \"system_temp_units\": \"{s}\",\n  \"system_temp_interval_seconds\": {d},\n  \"system_nvidia_smi\": {s},\n",
        .{ sgpu_esc, g_shell_cfg.system_temp_units.tag(), g_shell_cfg.system_temp_interval_seconds, smi },
    )) return;
    // fastfetch_fields as the names fastfetch.zig accepts, in row order.
    if (!w.append("  \"fastfetch_fields\": [")) return;
    const ff_fields: []const ff_service.Field = if (g_shell_cfg.fastfetch_field_count > 0)
        g_shell_cfg.fastfetch_fields[0..g_shell_cfg.fastfetch_field_count]
    else
        &ff_service.DEFAULT_FIELDS;
    for (ff_fields, 0..) |f, fi| {
        if (!w.appendFmt("{s}\"{s}\"", .{ if (fi > 0) ", " else "", @tagName(f) })) return;
    }
    if (!w.append("],\n")) return;
    const ffbin_esc = jsonEscape(g_shell_cfg.fastfetch_binary, &esc) orelse return;
    if (!w.appendFmt("  \"fastfetch_refresh_minutes\": {d},\n  \"fastfetch_binary\": \"{s}\",\n", .{ g_shell_cfg.fastfetch_refresh_minutes, ffbin_esc })) return;
    const fflogo_esc = jsonEscape(g_shell_cfg.fastfetch_logo, &esc) orelse return;
    if (!w.appendFmt("  \"fastfetch_logo\": \"{s}\",\n", .{fflogo_esc})) return;
    const ffcfg_esc = jsonEscape(g_shell_cfg.fastfetch_config, &esc) orelse return;
    if (!w.appendFmt("  \"fastfetch_config\": \"{s}\",\n", .{ffcfg_esc})) return;
    const clk = g_shell_cfg.clock;
    if (!w.appendFmt(
        "  \"clock_style\": \"{s}\",\n  \"clock_24h\": {s},\n  \"clock_seconds\": {s},\n  \"clock_date\": {s},\n  \"system_style\": \"{s}\",\n",
        .{ @tagName(clk.style), jsonBool(clk.h24), jsonBool(clk.seconds), jsonBool(clk.date), @tagName(g_shell_cfg.system_style) },
    )) return;
    if (!w.appendFmt(
        "  \"processes_sort\": \"{s}\",\n  \"processes_count\": {d},\n  \"processes_interval_seconds\": {d},\n  \"processes_group\": {s},\n",
        .{ g_shell_cfg.processes_sort.tag(), g_shell_cfg.processes_count, g_shell_cfg.processes_interval_seconds, jsonBool(g_shell_cfg.processes_group) },
    )) return;
    if (!w.appendFmt("  \"calendar_reminders\": {d},\n", .{g_shell_cfg.calendar_reminders})) return;
    if (!w.appendFmt(
        "  \"network_graph\": {s},\n  \"network_interval_seconds\": {d},\n",
        .{ jsonBool(g_shell_cfg.network_graph), g_shell_cfg.network_interval_seconds },
    )) return;
    if (!w.appendFmt(
        "  \"user_host\": {s},\n  \"user_uptime_short\": {s},\n  \"user_show_name\": {s},\n",
        .{ jsonBool(g_shell_cfg.user_host), jsonBool(g_shell_cfg.user_uptime_short), jsonBool(g_shell_cfg.user_show_name) },
    )) return;
    const nd_esc = jsonEscape(g_shell_cfg.notes_dir, &esc) orelse return;
    const nl = g_shell_cfg.notes;
    if (!w.appendFmt(
        "  \"notes_tabs\": {s},\n  \"notes_checklists\": {s},\n  \"notes_lines\": {d},\n  \"notes_dir\": \"{s}\",\n  \"notes_page\": {d},\n",
        .{ jsonBool(nl.tabs), jsonBool(nl.checklists), nl.lines, nd_esc, g_shell_cfg.notes_page },
    )) return;
    if (!w.appendFmt(
        "  \"glance_enabled\": {s},\n  \"glance_start_tab\": \"{s}\",\n",
        .{ jsonBool(g_shell_cfg.glance_enabled), @tagName(g_shell_cfg.glance_start_tab) },
    )) return;
    // overview_favorites round-trips too — saveConfig must not drop keys it
    // didn't just write (that's the whole round-trip contract here).
    if (!w.append("  \"overview_favorites\": [")) return;
    for (0..g_shell_cfg.fav_count) |i| {
        const fav_esc = jsonEscape(g_shell_cfg.fav_cmds[i], &esc) orelse return;
        const tail: []const u8 = if (i + 1 == g_shell_cfg.fav_count) "],\n" else ", ";
        if (!w.appendFmt("\"{s}\"{s}", .{ fav_esc, tail })) return;
    }
    if (g_shell_cfg.fav_count == 0 and !w.append("],\n")) return;
    if (!w.append("  \"widgets\": [\n")) return;
    for (0..host.widget_count) |i| {
        const id = std.meta.activeTag(host.widgets[i]);
        const r = host.widget_rects[i];
        const tail: []const u8 = if (i + 1 == host.widget_count) "\n" else ",\n";
        if (!w.appendFmt(
            "    {{ \"id\": \"{s}\", \"x\": {d}, \"y\": {d}, \"w\": {d}, \"h\": {d} }}{s}",
            .{ @tagName(id), r.x, r.y, r.w, r.h, tail },
        )) return;
    }
    if (!w.append("  ]\n}\n")) return;

    var tmp_buf: [532]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tmp_buf, "{s}.tmp", .{shell_config_path}, 0) catch return;
    const raw_fd = posix.system.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(posix.mode_t, 0o644));
    if (raw_fd < 0) {
        logging.warn("config: could not write {s}", .{tmp});
        return;
    }
    const fd: posix.fd_t = @intCast(raw_fd);
    var off: usize = 0;
    while (off < w.len) {
        const n = std.c.write(fd, out[off..w.len].ptr, w.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    _ = posix.system.close(fd);
    if (off != w.len) {
        logging.warn("config: short write to {s}", .{tmp});
        return;
    }
    if (std.c.rename(tmp.ptr, shell_config_path.ptr) != 0) {
        logging.warn("config: could not rename {s} into place", .{tmp});
        return;
    }
    logging.step("config: saved widget positions to {s}", .{shell_config_path});
}

/// The wallpaper swaybg shows: Perihelion's ~/.config/perihelion/wallpaper
/// ("image <path>"), else perihelionbar's ~/.config/perihelionbar/wallpaper
/// ("path=<path>"). Empty for a plain color or none.
fn currentWallpaper(gpa: std.mem.Allocator, out: []u8) []const u8 {
    const home = std.mem.span(getenv("HOME") orelse return "");
    var pbuf: [512]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&pbuf, "{s}/.config/perihelion/wallpaper", .{home}, 0)) |p| {
        if (readFileAlloc(gpa, p)) |text| {
            defer gpa.free(text);
            const line = std.mem.trim(u8, text, " \t\r\n");
            if (std.mem.startsWith(u8, line, "image ")) {
                const v = std.mem.trim(u8, line[6..], " \t");
                if (v.len <= out.len) {
                    @memcpy(out[0..v.len], v);
                    return out[0..v.len];
                }
            }
            if (std.mem.startsWith(u8, line, "color ")) return "";
        } else |_| {}
    } else |_| {}
    if (std.fmt.bufPrintSentinel(&pbuf, "{s}/.config/perihelionbar/wallpaper", .{home}, 0)) |p| {
        if (readFileAlloc(gpa, p)) |text| {
            defer gpa.free(text);
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (!std.mem.startsWith(u8, line, "path=")) continue;
                const v = line[5..];
                if (v.len <= out.len) {
                    @memcpy(out[0..v.len], v);
                    return out[0..v.len];
                }
            }
        } else |_| {}
    } else |_| {}
    return "";
}

fn refreshBackdrop(host: *Host, d: *const Desktop) void {
    host.backdrop_checked = true;
    var buf: [512]u8 = undefined;
    const path = currentWallpaper(host.gpa, &buf);
    if (host.backdrop.loadIfChanged(host.gpa, path, @max(d.width, d.height))) {
        markAllDirty(host);
        // An open Glance frosts its panel from the same picture.
        if (host.glance) |gl| gl.themeChanged();
    }
}

fn paintDesktop(host: *Host, d: *Desktop) !void {
    const stride = d.width * 4; // ARGB8888
    const size: usize = @as(usize, stride) * d.height;
    if (size == 0) return;

    const fd = try posix.memfd_create("perihelionbar-shell-buffer", 0);
    defer _ = posix.system.close(fd);
    switch (posix.errno(posix.system.ftruncate(fd, @intCast(size)))) {
        .SUCCESS => {},
        else => return error.FTruncateFailed,
    }
    const data = try posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer posix.munmap(data);

    const pixels: [*]u32 = @ptrCast(@alignCast(data.ptr));
    // No explicit clear: a freshly ftruncate'd memfd reads as zeros, and
    // every widget pixel below is blitted from its tile — the untouched
    // background stays fully transparent.

    // 0) Content-driven icons: the grid's tile grows/shrinks with the
    //    scanned shortcut count before its dirty-bit tile renders.
    applyIconsSize(host);

    // Glass: (re)load the blurred wallpaper when due, and re-render any card
    // that moved since its last render (what shows through it changed).
    if (!host.backdrop_checked) refreshBackdrop(host, d);
    if (host.backdrop.ready()) {
        for (0..host.widget_count) |i| {
            const r = host.widget_rects[i];
            if (host.tile_origin[i][0] != r.x or host.tile_origin[i][1] != r.y)
                host.tile_dirty |= @as(u16, 1) << @intCast(i);
        }
    }

    // 1) Re-render the tiles whose widgets asked for it (state change from
    //    tick/onPipe/click, or a frame-wide hover/theme change). A tile is
    //    widget-local: rect at (0, 0), so paint coordinates stay small.
    for (0..host.widget_count) |i| {
        const bit = @as(u16, 1) << @intCast(i);
        if ((host.tile_dirty & bit) == 0) continue;
        const tile = host.tiles[i] orelse continue;
        // Fresh backdrop every re-render — cards and glyph edges alpha-
        // blend, so leftover pixels from the previous render (or the
        // allocator's 0xAA fill pattern) would bleed through. Same reason
        // the old path memset the whole surface.
        @memset(tile, 0);
        const rect = host.widget_rects[i];
        // Corner-resize zoom: content scales with the card (note1 reflows
        // at base size instead). Font and layout zoom travel together via
        // the swapped face + Canvas.zoom, so metrics never disagree.
        const zoom = widgetZoom(host, i);
        const tc = widgets_mod.Canvas{
            .pixels = tile.ptr,
            .width = rect.w,
            .height = rect.h,
            .font = zoomFontFor(host, i, zoom),
            .theme = &host.theme,
            .zoom = zoom,
        };
        const tr = widgets_mod.Rect{ .x = 0, .y = 0, .w = rect.w, .h = rect.h };
        // The desktop-icon grid has no frosted card behind it: bare
        // glyphs over the wallpaper like a classic desktop. Cards never highlight on hover — the fill stays bg_color
        // under the pointer; hover tracking itself (clicks, the weather
        // condition-fx) is untouched, only the wash is gone.
        switch (std.meta.activeTag(host.widgets[i])) {
            .icons => {},
            else => {
                // Frosted glass card (glass.zig): the blurred wallpaper under
                // it, tinted with the theme, smooth corners, a light edge.
                glass.paintCard(tile, rect.w, rect.h, rect.x, rect.y, d.width, d.height, &host.backdrop, .{
                    .tint = host.theme.bg_color,
                    .tint_pct = host.theme.card_alpha,
                    .radius = host.theme.radius_px,
                });
            },
        }
        host.tile_origin[i] = .{ rect.x, rect.y };
        host.widgets[i].paint(tc, tr);
        // Resize affordance over the content (tile-local): visible while
        // hovered or grabbed, repainted away with the tile otherwise. The
        // icons grid is content-sized, so it never shows the grip.
        if ((host.hovered_index == i or host.resize_index == i) and
            std.meta.activeTag(host.widgets[i]) != .icons)
        {
            drawResizeGrip(tc, tr);
        }
    }
    host.tile_dirty = 0;

    // 2) Composite every tile onto the fresh surface (positions come from
    //    the current rects, so drags just move the blits).
    for (0..host.widget_count) |i| {
        const tile = host.tiles[i] orelse continue;
        blitTile(pixels, d, host.widget_rects[i], tile);
    }

    const pool = try host.shm.createPool(fd, @intCast(size));
    defer pool.destroy();
    const buffer = try pool.createBuffer(
        0,
        @intCast(d.width),
        @intCast(d.height),
        @intCast(stride),
        .argb8888,
    );
    defer buffer.destroy();

    d.surface.attach(buffer, 0, 0);
    d.surface.damageBuffer(0, 0, @intCast(d.width), @intCast(d.height));
    d.surface.commit();
}

/// Row-wise copy of a widget's tile onto the surface, clipped to it (a
/// widget may sit partially off-edge if an output shrinks under it).
fn blitTile(pixels: [*]u32, d: *Desktop, r: widgets_mod.Rect, tile: []const u32) void {
    const tw: i32 = @intCast(r.w);
    const th: i32 = @intCast(r.h);
    const sx0 = @max(0, -r.x);
    const sy0 = @max(0, -r.y);
    const sx1 = @min(tw, @as(i32, @intCast(d.width)) - r.x);
    const sy1 = @min(th, @as(i32, @intCast(d.height)) - r.y);
    if (sx1 <= sx0 or sy1 <= sy0) return;
    const dst_x: usize = @intCast(@max(r.x, 0) + sx0);
    const row_len: usize = @intCast(sx1 - sx0);
    var sy: i32 = sy0;
    while (sy < sy1) : (sy += 1) {
        const dst_y: usize = @intCast(@max(r.y, 0) + sy);
        const src_off: usize = @as(usize, @intCast(sy * tw)) + @as(usize, @intCast(sx0));
        const dst_off = dst_y * d.width + dst_x;
        @memcpy(pixels[dst_off .. dst_off + row_len], tile[src_off .. src_off + row_len]);
    }
}

/// State inside widget `i` changed (tick / fetch / click) — its tile must
/// re-render before the next frame.
fn markDirty(host: *Host, i: usize) void {
    host.needs_repaint = true;
    host.tile_dirty |= @as(u16, 1) << @intCast(i);
}

/// A frame-wide factor changed (hover highlight): every tile is stale.
fn markAllDirty(host: *Host) void {
    host.needs_repaint = true;
    host.tile_dirty = 0xFFFF;
}

/// Content-driven sizing for the desktop-icons grid: each scan changes the
/// item count, so the widget's rect tracks the grid (zero = no grid at
/// all). Runs at the top of paintDesktop so a resize lands before the tile
/// renders; a rect change also re-establishes input regions immediately.
fn applyIconsSize(host: *Host) void {
    for (0..host.widget_count) |i| {
        if (std.meta.activeTag(host.widgets[i]) != .icons) continue;
        const want = widgets_mod.IconsWidget.gridSizeFor(host.widgets[i].icons.item_count);
        const r = &host.widget_rects[i];
        if (r.w == want[0] and r.h == want[1]) continue;
        r.w = @intCast(want[0]);
        r.h = @intCast(want[1]);
        if (want[0] == 0 or want[1] == 0) {
            // Empty folder: drop the tile; a zero rect paints and blits
            // nothing and keeps no input region (initWidgets allocated a
            // base-size tile for the first frame only).
            if (host.tiles[i]) |t| host.gpa.free(t);
            host.tiles[i] = null;
            markDirty(host, i);
        } else {
            reallocTile(host, i); // frees, reallocs, marks dirty
        }
        refreshInputRegions(host);
        host.needs_repaint = true;
    }
}

/// Motion pass for the desktop icons (hover wash + popup rows). Returns
/// repaint-need; `active` = the pointer currently sits on a desktop surface.
fn iconsPointerChanged(host: *Host, active: bool) bool {
    var changed = false;
    for (0..host.widget_count) |i| {
        if (std.meta.activeTag(host.widgets[i]) != .icons) continue;
        if (host.widgets[i].icons.pointer(host.widget_rects[i], active, host.pointer_x, host.pointer_y)) {
            markDirty(host, i);
            changed = true;
        }
    }
    return changed;
}

/// Any open icons popup closes (a press landed elsewhere, or the pointer
/// left the grid entirely).
fn closeIconsMenus(host: *Host) void {
    for (0..host.widget_count) |i| {
        if (std.meta.activeTag(host.widgets[i]) != .icons) continue;
        if (host.widgets[i].icons.menu_open) {
            host.widgets[i].icons.closeMenu();
            markDirty(host, i);
        }
    }
}

/// Right-button press routing: over the icons grid it opens the Open/Remove
/// popup for the cell under the pointer; anywhere else it just dismisses
/// an open popup. Driven through pointerButton like every other press, so
/// the self-test exercises the same path.
fn handleRightPress(host: *Host) void {
    var hit: ?usize = null;
    for (0..host.widget_count) |i| {
        if (host.widget_rects[i].contains(host.pointer_x, host.pointer_y)) {
            hit = i;
            break;
        }
    }
    if (hit) |i| {
        if (host.alt_down) {
            removeWidget(host, i);
            return;
        }
        host.pending_right = i;
        if (std.meta.activeTag(host.widgets[i]) == .icons) {
            host.widgets[i].icons.rightClick(host.widget_rects[i], host.pointer_x, host.pointer_y);
            markDirty(host, i);
            return;
        }
    }
    closeIconsMenus(host);
}

/// Perihelion: hides widget `i` for good (Alt + right-click). Adds its id
/// to widgets-disabled, the same file perihelionbar-config's switches write, then
/// restarts the shell so the desktop redraws without it. The last widget
/// stays: with none left the shell exits, and Alt+W's overview with it.
fn removeWidget(host: *Host, i: usize) void {
    host.pending_right = null;
    if (host.widget_count <= 1) {
        logging.warn("widgets: keeping the last widget (the overview needs perihelionbar-shell running)", .{});
        return;
    }
    if (widgets_disabled_path.len == 0) return;
    const id = @tagName(std.meta.activeTag(host.widgets[i]));
    const raw_fd = posix.system.open(widgets_disabled_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(posix.mode_t, 0o644));
    if (raw_fd < 0) return;
    const fd: posix.fd_t = @intCast(raw_fd);
    var buf: [64]u8 = undefined;
    // Leading newline: the file may not end in one; blank lines are skipped.
    const text = std.fmt.bufPrint(&buf, "\n{s}\n", .{id}) catch {
        _ = posix.system.close(fd);
        return;
    };
    var off: usize = 0;
    while (off < text.len) {
        const n = posix.system.write(fd, text[off..].ptr, text.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    _ = posix.system.close(fd);
    logging.step("widgets: {s} removed (Alt + right-click) — restarting", .{id});
    endEdit(host); // save a note being typed before going away
    widgets_mod.spawnDetached("sleep 0.4; exec perihelion-shell");
    std.process.exit(0);
}

fn layerSurfaceListener(_: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, d: *Desktop) void {
    switch (event) {
        .configure => |cfg| {
            d.layer_surface.ackConfigure(cfg.serial);
            if (cfg.width > 0) d.width = cfg.width;
            if (cfg.height > 0) d.height = cfg.height;
            if (!d.configured) {
                d.configured = true;
                setInputRegion(d.host, d);
            }
            paintDesktop(d.host, d) catch |err| {
                logging.err("draw failed: {}", .{err});
            };
        },
        .closed => std.process.exit(0),
    }
}

/// Returns true if the hovered widget changed (caller should repaint).
fn updateHover(host: *Host) bool {
    var new_hover: ?usize = null;
    for (0..host.widget_count) |i| {
        if (host.widget_rects[i].contains(host.pointer_x, host.pointer_y)) {
            new_hover = i;
            break;
        }
    }
    if (new_hover == host.hovered_index) return false;
    host.hovered_index = new_hover;
    return true;
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, host: *Host) void {
    switch (event) {
        .enter => |e| {
            if (host.glance) |gl| {
                if (gl.surface == e.surface) {
                    host.pointer_over_gl = true;
                    host.pointer_over_ov = false;
                    host.pointer_desktop = null;
                    gl.motion(e.surface_x.toInt(), e.surface_y.toInt());
                    return;
                }
            }
            host.pointer_over_gl = false;
            if (host.overview) |ov| {
                if (ov.surface == e.surface) {
                    host.pointer_over_ov = true;
                    host.pointer_desktop = null;
                    ov.motion(e.surface_x.toInt(), e.surface_y.toInt());
                    return;
                }
            }
            host.pointer_over_ov = false;
            for (0..host.desktop_count) |i| {
                if (host.desktops[i].surface == e.surface) {
                    host.pointer_desktop = i;
                    break;
                }
            }
            host.pointer_x = e.surface_x.toInt();
            host.pointer_y = e.surface_y.toInt();
            if (updateHover(host)) markAllDirty(host);
            _ = iconsPointerChanged(host, true);
        },
        .leave => {
            if (host.pointer_over_gl) {
                host.pointer_over_gl = false;
                if (host.glance) |gl| gl.leave();
                return;
            }
            if (host.pointer_over_ov) {
                host.pointer_over_ov = false;
                if (host.overview) |ov| ov.leave();
                return;
            }
            host.pointer_desktop = null;
            // While a button is held the implicit grab keeps events flowing,
            // so a leave during a drag shouldn't (and normally can't) happen.
            if (host.drag_index == null and host.hovered_index != null) {
                host.hovered_index = null;
                markAllDirty(host);
            }
            _ = iconsPointerChanged(host, false);
        },
        .motion => |e| {
            if (host.pointer_over_gl) {
                if (host.glance) |gl| gl.motion(e.surface_x.toInt(), e.surface_y.toInt());
                return;
            }
            if (host.pointer_over_ov) {
                if (host.overview) |ov| ov.motion(e.surface_x.toInt(), e.surface_y.toInt());
                return;
            }
            host.pointer_x = e.surface_x.toInt();
            host.pointer_y = e.surface_y.toInt();
            if (host.resize_index) |i| {
                // Corner resize in progress: grow/shrink the card live with
                // the top-left pinned, reallocating the paint tile as the
                // size changes (content re-renders from the new rect, so
                // rect-relative widgets like weather fx and notes reflow).
                const r = &host.widget_rects[i];
                const base = widgets_mod.cardSizeFor(std.meta.activeTag(host.widgets[i]), host.font);
                const d = &host.desktops[host.pointer_desktop orelse 0];
                var nw = host.pointer_x - r.x + host.resize_off_x;
                var nh = host.pointer_y - r.y + host.resize_off_y;
                nw = std.math.clamp(nw, @as(i32, @intCast(base[0])), @as(i32, @intCast(d.width)));
                nh = std.math.clamp(nh, @as(i32, @intCast(base[1])), @as(i32, @intCast(d.height)));
                if (@as(i64, nw) != @as(i64, r.w) or @as(i64, nh) != @as(i64, r.h)) {
                    r.w = @intCast(nw);
                    r.h = @intCast(nh);
                    clampWidget(host, i); // keep the grown card on its output
                    reallocTile(host, i); // frees, reallocs, marks dirty
                    host.hovered_index = i;
                    host.needs_repaint = true;
                }
            } else if (host.drag_index) |i| {
                // Ctrl+drag in progress: the card follows the pointer,
                // clamped to the output it's being moved on. Tiles are
                // position-independent — only the blit moves, so no
                // re-render is needed, just a new frame.
                const r = &host.widget_rects[i];
                r.x = host.pointer_x - host.drag_off_x;
                r.y = host.pointer_y - host.drag_off_y;
                clampWidget(host, i);
                host.hovered_index = i;
                host.needs_repaint = true;
            } else {
                if (updateHover(host)) markAllDirty(host);
                // Cell-level hover wash + popup row highlight (icons grid).
                _ = iconsPointerChanged(host, true);
            }
        },
        .button => |e| {
            if (host.pointer_over_gl) {
                if (host.glance) |gl| gl.button(e.button, e.state == .pressed);
                return;
            }
            if (host.pointer_over_ov) {
                if (host.overview) |ov| ov.button(e.button, e.state == .pressed);
                return;
            }
            pointerButton(host, e.button, e.state == .pressed);
        },
        .frame => {},
        // Wheel over the notes card scrolls its text (the other cards
        // have nothing to scroll).
        .axis => |e| {
            if (host.pointer_over_ov or host.pointer_over_gl or e.axis != .vertical_scroll) return;
            onWheel(host, e.value.toDouble());
        },
        .axis_source => {},
        .axis_stop => {},
        .axis_discrete => {},
    }
}

/// Accumulates wheel/touchpad motion into whole lines (about one line per
/// wheel notch) and scrolls the notes card under the pointer.
fn onWheel(host: *Host, value: f64) void {
    const i = host.hovered_index orelse {
        host.wheel_accum = 0;
        return;
    };
    if (host.widgets[i] != .note1) return;
    host.wheel_accum += value;
    const lines: i32 = @intFromFloat(@trunc(host.wheel_accum / WHEEL_UNITS_PER_LINE));
    if (lines == 0) return;
    host.wheel_accum -= @as(f64, @floatFromInt(lines)) * WHEEL_UNITS_PER_LINE;
    if (host.widgets[i].note1.scrollBy(host.widget_rects[i], host.font, lines)) markDirty(host, i);
}

/// Wayland axis units per text line: a wheel notch is 10-15 units.
const WHEEL_UNITS_PER_LINE: f64 = 12.0;

/// Left-button press/release over a widget — the body of the pointer
/// listener's button arm, split out so the self-test can drive the exact
/// same code path without synthesizing wl events. A press anywhere that
/// isn't the note being edited commits that note first (Plasma-style: the
/// focused-vs-clicking ordering can otherwise eat keystrokes).
fn pointerButton(host: *Host, btn: u32, pressed: bool) void {
    if (btn == BTN_RIGHT) {
        if (pressed) handleRightPress(host) else host.pending_right = null;
        return;
    }
    if (btn != BTN_LEFT) return;
    if (pressed) {
        host.left_down = true;
        host.press_index = host.hovered_index;
        // A press outside the desktop-icons widget closes its popup (a
        // press inside routes through the click below, where the row acts).
        if (host.hovered_index) |hi| {
            if (std.meta.activeTag(host.widgets[hi]) != .icons) closeIconsMenus(host);
        } else {
            closeIconsMenus(host);
        }
        if (host.edit_index) |ei| {
            const pi = host.press_index;
            if (pi == null or pi != ei) endEdit(host);
        }
        // A corner grip starts a resize; anywhere else the press is a move
        // when Ctrl is known (see tryStartDrag) or a click on release.
        if (!tryStartResize(host)) tryStartDrag(host);
        logging.step("ptr: press hovered={?} ctrl={}", .{ host.hovered_index, host.ctrl_down });
    } else {
        host.left_down = false;
        if (host.drag_index != null) {
            endDrag(host);
        } else if (host.resize_index != null) {
            endResize(host);
        } else if (host.press_index) |i| {
            host.press_index = null;
            // A click is press + release over the same widget.
            if (host.widget_rects[i].contains(host.pointer_x, host.pointer_y)) {
                host.widgets[i].click(zoomFontFor(host, i, widgetZoom(host, i)), widgetZoom(host, i), host.widget_rects[i], host.pointer_x, host.pointer_y);
                // A weather click flips °C/°F; keep the choice across restarts.
                if (host.widgets[i] == .weather and host.widgets[i].weather.units_changed) {
                    host.widgets[i].weather.units_changed = false;
                    g_shell_cfg.weather_units = host.widgets[i].weather.svc.units;
                    g_shell_cfg.weather_units_auto = false; // a chosen unit, kept
                    saveConfig(host);
                    // Tell the top bar to re-read shell.json's weather keys
                    // (SIGUSR2 = weather-only reload, no full config reload).
                    // Only signal a pid that really is the bar: a stale
                    // pidfile may name an unrelated process, which SIGUSR2's
                    // default action would kill.
                    widgets_mod.spawnDetached(BAR_WEATHER_RELOAD_CMD);
                }
                // A System card click that switched GPUs: remember which.
                if (host.widgets[i] == .system and host.widgets[i].system.gpu_changed) {
                    host.widgets[i].system.gpu_changed = false;
                    const pref = host.widgets[i].system.temps.gpuPref();
                    const n = @min(pref.len, g_system_gpu_buf.len);
                    @memcpy(g_system_gpu_buf[0..n], pref[0..n]);
                    g_shell_cfg.system_gpu = g_system_gpu_buf[0..n];
                    saveConfig(host);
                }
                // A Processes card click that flipped CPU/memory order.
                if (host.widgets[i] == .processes and host.widgets[i].processes.sort_changed) {
                    host.widgets[i].processes.sort_changed = false;
                    g_shell_cfg.processes_sort = host.widgets[i].processes.svc.sort;
                    saveConfig(host);
                }
                // A click that left the notes card editing opens the
                // single-edit slot: the card took on_demand keyboard focus,
                // so the compositor routes key events here. The widget owns
                // text/caret; the host owns the slot, the repeat clock, and
                // the edit cadence. Header buttons and checkbox ticks don't
                // edit, so they hand the slot back.
                if (host.widgets[i] == .note1) {
                    const n = &host.widgets[i].note1;
                    if (n.editing) {
                        host.edit_index = i;
                    } else if (host.edit_index == i) {
                        host.edit_index = null;
                        host.repeat_key = null;
                        host.repeat_next_ms = 0;
                    }
                    if (n.page_changed) {
                        n.page_changed = false;
                        g_shell_cfg.notes_page = n.slot;
                        saveConfig(host);
                    }
                    reschedule(host, i);
                }
                logging.step("ptr: click idx={d} edit={?}", .{ i, host.edit_index });
                markDirty(host, i); // widgets flip state on click
            }
        }
    }
}

/// True when a Ctrl+drag may begin: button down, Ctrl held, no drag yet,
/// and the press landed on a widget.
fn tryStartDrag(host: *Host) void {
    if (!host.left_down or !host.ctrl_down or host.drag_index != null) return;
    const index = host.press_index orelse host.hovered_index orelse return;
    const r = host.widget_rects[index];
    host.drag_index = index;
    host.drag_off_x = host.pointer_x - r.x;
    host.drag_off_y = host.pointer_y - r.y;
    host.press_index = null; // consumed: a drag is not a click
    host.hovered_index = index;
    markAllDirty(host); // hover highlight moved with the drag
}

/// Keeps widget `index` fully inside the output the pointer is on (surface
/// coordinates — outputs all share one position set per widget).
fn clampWidget(host: *Host, index: usize) void {
    const d = &host.desktops[host.pointer_desktop orelse 0];
    const r = &host.widget_rects[index];
    const max_x: i32 = @max(@as(i32, @intCast(d.width)) - @as(i32, @intCast(r.w)), 0);
    const max_y: i32 = @max(@as(i32, @intCast(d.height)) - @as(i32, @intCast(r.h)), 0);
    r.x = std.math.clamp(r.x, 0, max_x);
    r.y = std.math.clamp(r.y, 0, max_y);
}

/// Button released mid-drag: settle the position, re-arm the input regions
/// (they still cover the pre-drag location), and persist to shell.json.
fn endDrag(host: *Host) void {
    const index = host.drag_index orelse return;
    host.drag_index = null;
    clampWidget(host, index);
    host.needs_repaint = true;
    refreshInputRegions(host);
    saveConfig(host);
}

/// Corner grip side (px): press inside the card's bottom-right square
/// starts a resize instead of a click.
const RESIZE_GRIP: i64 = 16;

fn resizeHit(r: widgets_mod.Rect, x: i32, y: i32) bool {
    const rx: i64 = r.x;
    const ry: i64 = r.y;
    const rw: i64 = r.w;
    const rh: i64 = r.h;
    const px: i64 = x;
    const py: i64 = y;
    return px >= rx + rw - RESIZE_GRIP and px < rx + rw and py >= ry + rh - RESIZE_GRIP and py < ry + rh;
}

/// Press landed on a card's resize grip: start a corner resize instead of
/// a click or a move. An explicit target beats modifiers — Ctrl+corner
/// resizes, it doesn't move.
fn tryStartResize(host: *Host) bool {
    if (!host.left_down or host.resize_index != null) return false;
    if (host.drag_index != null) return false;
    const index = host.press_index orelse host.hovered_index orelse return false;
    // The icons grid is content-sized — its corner grip does nothing.
    if (std.meta.activeTag(host.widgets[index]) == .icons) return false;
    const r = host.widget_rects[index];
    if (!resizeHit(r, host.pointer_x, host.pointer_y)) return false;
    host.resize_index = index;
    host.resize_off_x = (r.x + @as(i32, @intCast(r.w))) - host.pointer_x;
    host.resize_off_y = (r.y + @as(i32, @intCast(r.h))) - host.pointer_y;
    host.press_index = null; // consumed: a resize is not a click
    host.hovered_index = index;
    markDirty(host, index); // repaint with the lit grip under the grab
    return true;
}

/// Reallocate widget i's paint tile for its current rect (resize path).
/// Refuses absurd areas instead of OOMing — paintDesktop skips null tiles,
/// and the release re-clamps anyway.
fn reallocTile(host: *Host, i: usize) void {
    const r = host.widget_rects[i];
    const area: usize = @as(usize, r.w) * @as(usize, r.h);
    if (area == 0 or area > 16 * 1024 * 1024) {
        logging.warn("widgets: refusing {d}x{d} tile", .{ r.w, r.h });
        return;
    }
    if (host.tiles[i]) |old| host.gpa.free(old);
    host.tiles[i] = host.gpa.alloc(u32, area) catch |err| {
        logging.err("widgets: could not allocate {d}x{d} tile: {}", .{ r.w, r.h, err });
        return;
    };
    markDirty(host, i);
}

/// Button released mid-resize: settle the size, re-arm the input regions
/// (they still cover the pre-resize rect), and persist to shell.json.
fn endResize(host: *Host) void {
    const index = host.resize_index orelse return;
    host.resize_index = null;
    clampWidget(host, index);
    host.needs_repaint = true;
    refreshInputRegions(host);
    saveConfig(host);
    markDirty(host, index); // drop the lit grip
}

/// Resize affordance: three faint diagonal strokes in the card's
/// bottom-right corner, painted into the tile while hovered or grabbed.
fn drawResizeGrip(tc: widgets_mod.Canvas, r: widgets_mod.Rect) void {
    const col = (@as(u32, 0x58) << 24) | (tc.theme.border_color & 0x00FFFFFF);
    const w: i64 = r.w;
    const h: i64 = r.h;
    var k: i64 = 0;
    while (k < 3) : (k += 1) {
        var s: i64 = 0;
        while (s < 5) : (s += 1) {
            const x = w - 3 - k * 5 - s;
            const y = h - 3 - (4 - s);
            if (x < 0 or y < 0) continue;
            const pxu: usize = @intCast(x);
            const pyu: usize = @intCast(y);
            if (pxu >= tc.width or pyu >= tc.height) continue;
            tc.pixels[pyu * tc.width + pxu] = widgets_mod.Canvas.blendOver(tc.pixels[pyu * tc.width + pxu], col);
        }
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, host: *Host) void {
    switch (event) {
        .keymap => |e| {
            logging.step("kb: keymap event format={s} size={d}", .{ @tagName(e.format), e.size });
            // The keymap fd is ours to close once received (spec) — do that
            // no matter how far decoding gets.
            defer _ = posix.system.close(e.fd);
            if (e.format != .xkb_v1) {
                logging.warn("kb: keymap format {s} not xkb_v1 — ignoring", .{@tagName(e.format)});
                return;
            }
            // The keymap fd shares its file offset with whoever else holds
            // the description (the compositor just finished writing it), so
            // it can arrive sitting at EOF — rewind before reading.
            _ = std.c.lseek(e.fd, 0, 0); // SEEK_SET
            const size: usize = e.size;
            const buf = host.gpa.alloc(u8, size + 2) catch return;
            defer host.gpa.free(buf);
            var got: usize = 0;
            while (got < size) {
                const n = posix.read(e.fd, buf[got..size]) catch |rd_err| {
                    logging.warn("kb: keymap read error: {}", .{rd_err});
                    break;
                };
                if (n == 0) break;
                got += n;
            }
            if (got == 0) {
                const off = std.c.lseek(e.fd, 0, 1); // SEEK_CUR
                logging.warn("kb: keymap read 0 bytes (fd={d} size={d} off={d})", .{ e.fd, e.size, off });
                return;
            }
            buf[got] = 0; // xkb wants a NUL-terminated string
            if (g_xkb_ctx == null) g_xkb_ctx = xkb.xkb_context_new(xkb.CONTEXT_NO_FLAGS);
            const ctx = g_xkb_ctx orelse return;
            const km = xkb.xkb_keymap_new_from_string(ctx, buf[0..got:0], xkb.KEYMAP_FORMAT_TEXT_V1, xkb.KEYMAP_COMPILE_NO_FLAGS) orelse {
                logging.warn("kb: keymap parse failed ({d} bytes read)", .{got});
                return;
            };
            const st = xkb.xkb_state_new(km) orelse {
                xkb.xkb_keymap_unref(km);
                return;
            };
            if (g_xkb_keymap) |old| xkb.xkb_keymap_unref(old);
            if (g_xkb_state) |old| xkb.xkb_state_unref(old);
            g_xkb_keymap = km;
            g_xkb_state = st;
            g_kb_ready = true;
            logging.step("keyboard: xkb keymap live ({d} bytes)", .{got});
        },
        // The compositor always follows enter with a modifiers event, so
        // focus changes need no handling of their own.
        .enter => logging.step("kb: focus enter", .{}),
        .leave => {
            logging.step("kb: focus leave", .{});
            host.ctrl_down = false;
            host.alt_down = false;
            host.pending_right = null;
            host.repeat_key = null;
            // Editing a note then clicking a window (our surface loses the
            // on_demand focus) commits it, Plasma-style.
            endEdit(host);
        },
        .key => |e| {
            logging.step("kb: ev key={d} {s} edit={?}", .{ e.key, if (e.state == .pressed) "down" else "up", host.edit_index });
            onKeyboardKey(host, e.key, e.state == .pressed);
        },
        .modifiers => |e| {
            // Control is real-mod index 2 in the depressed mask.
            const ctrl = e.mods_depressed & (1 << 2) != 0;
            host.ctrl_down = ctrl;
            // Perihelion: Alt is real-mod index 3 (Mod1).
            host.alt_down = e.mods_depressed & (1 << 3) != 0;
            if (host.alt_down) {
                if (host.pending_right) |pi| removeWidget(host, pi);
            }
            // A press can precede this event (clicking takes focus first);
            // the moment Ctrl is known and the button is down over a widget,
            // turn the pending press into a drag.
            if (ctrl) tryStartDrag(host);
            // Keep xkb's modifier/group state in lockstep so UTF-32 decode
            // honors the actual layout (Shift for caps, group for altgr).
            if (g_xkb_state) |st| {
                _ = xkb.xkb_state_update_mask(st, e.mods_depressed, e.mods_latched, e.mods_locked, 0, 0, e.group);
            }
        },
        .repeat_info => |e| {
            // The compositor's auto-repeat parameters; we synthesize repeats
            // from them while editing (rate Hz, delay ms; rate 0 = no repeat).
            host.kb_rate = e.rate;
            host.kb_delay = e.delay;
        },
    }
}

fn onKeyboardKey(host: *Host, keycode: u32, pressed: bool) void {
    if (pressed) keyPress(host, keycode) else keyRelease(host, keycode);
}

fn keyRelease(host: *Host, keycode: u32) void {
    if (host.repeat_key == keycode) host.repeat_key = null;
}

/// True while a held key should keep synthesizing repeats: a note edit or
/// the overview's search box currently owns the keyboard.
fn repeatWanted(host: *Host) bool {
    if (host.edit_index != null) return true;
    if (host.overview) |ov| return ov.takesKeys();
    return false;
}

/// Routes one keyboard press. The overview owns the keyboard while its
/// surface is up (exclusive focus for search); otherwise nothing happens
/// unless a note is being edited. The key is decoded through xkb into
/// UTF-32 before handing it on.
fn keyPress(host: *Host, keycode: u32) void {
    // Glance holds the keyboard exclusively while it's up.
    if (host.glance) |gl| {
        if (gl.keyPress(keycode)) {
            logging.step("kb: glance key={d}", .{keycode});
            return;
        }
    }
    if (host.overview) |ov| {
        if (ov.takesKeys()) {
            var ov_utf32: u32 = 0;
            if (g_xkb_state) |st| ov_utf32 = xkb.xkb_state_key_get_utf32(st, keycode + 8);
            const ov_handled = ov.keyPress(keycode, ov_utf32, host.ctrl_down);
            logging.step("kb: ov key={d} U+{x:0>4} ctrl={} handled={}", .{ keycode, ov_utf32, host.ctrl_down, ov_handled });
            if (ov_handled) armRepeat(host, keycode);
            return;
        }
        if (ov.surface != null) {
            logging.step("kb: ov drops key={d} (anim not taking keys)", .{keycode});
        }
    }
    const i = host.edit_index orelse return;
    // Ctrl chords are ignored while editing (no text shortcuts) — except
    // Esc, which always commits.
    if (keycode != widgets_mod.KEY_ESC and host.ctrl_down) return;
    var utf32: u32 = 0;
    if (g_xkb_state) |st| utf32 = xkb.xkb_state_key_get_utf32(st, keycode + 8);
    const res = switch (host.widgets[i]) {
        .note1 => |*n| n.keyPress(widgets_mod.FontMeasure{ .font = host.font }, noteMaxW(host, i), noteVisLines(host, i), keycode, utf32),
        else => .ignored,
    };
    logging.step("kb: key={d} U+{x:0>4} edit={d} -> {s}", .{ keycode, utf32, i, @tagName(res) });
    switch (res) {
        .ignored => {},
        .handled => {
            markDirty(host, i);
            armRepeat(host, keycode);
            // The whole keystroke burst shouldn't wait out the idle cadence.
            reschedule(host, i);
        },
        .exited => {
            host.edit_index = null;
            host.repeat_key = null;
            host.repeat_next_ms = 0;
            reschedule(host, i);
            markDirty(host, i);
        },
    }
}

/// Content zoom for widget i: uniform min-ratio of its rect to the type's
/// base size, never below 1 (cards can't shrink past base). Note1 is
/// exempt — it reflows instead of zooming.
fn widgetZoom(host: *Host, i: usize) f32 {
    // Notes reflow at base size and the icons grid is content-sized —
    // neither participates in corner-resize zoom.
    if (std.meta.activeTag(host.widgets[i]) == .note1 or
        std.meta.activeTag(host.widgets[i]) == .icons) return 1.0;
    const base = widgets_mod.cardSizeFor(std.meta.activeTag(host.widgets[i]), host.font);
    const zw = @as(f32, @floatFromInt(host.widget_rects[i].w)) / @as(f32, @floatFromInt(base[0]));
    const zh = @as(f32, @floatFromInt(host.widget_rects[i].h)) / @as(f32, @floatFromInt(base[1]));
    return @max(1.0, @min(zw, zh));
}

/// Scaled face for widget i's content zoom (integer pixel buckets — a new
/// face loads only when the bucket changes, so live drags don't reload
/// per motion). Falls back to the shared face on any failure. The caller
/// sets Canvas.zoom to match; font metrics and layout scaling stay in
/// sync by construction.
fn zoomFontFor(host: *Host, i: usize, zoom: f32) *font_mod.Font {
    if (std.meta.activeTag(host.widgets[i]) == .note1 or
        std.meta.activeTag(host.widgets[i]) == .icons) return host.font;
    const want: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(host.font.pixel_size)) * zoom))));
    if (host.zoom_fonts[i] == null or host.zoom_px[i] != want) {
        if (host.zoom_fonts[i]) |*f| f.deinit();
        host.zoom_fonts[i] = null;
        var pbuf: [512]u8 = undefined;
        if (fontPathZ(g_shell_cfg.font_path, &pbuf)) |path_z| {
            if (font_mod.Font.init(host.gpa, path_z, want)) |f| {
                host.zoom_fonts[i] = f;
                host.zoom_px[i] = want;
            } else |_| {}
        }
    }
    if (host.zoom_fonts[i]) |*f| return f;
    return host.font;
}

/// Text width available inside the note card (match NoteWidget.paint).
fn noteMaxW(host: *Host, i: usize) i64 {
    return @as(i64, @intCast(host.widget_rects[i].w)) - 2 * widgets_mod.CARD_PAD;
}

/// Visible note lines for widget i's current card height (reflows when
/// corner-resized). Matches NoteWidget.paint's own computation.
fn noteVisLines(host: *Host, i: usize) usize {
    return widgets_mod.noteVisLines(@as(i64, @intCast(host.widget_rects[i].h)), widgets_mod.lineH(host.font));
}

/// Set up compositor-style auto-repeat (rate Hz, delay ms) for the key that
/// just edited. Repeat fires through the poll deadline, not per event.
fn armRepeat(host: *Host, keycode: u32) void {
    if (host.kb_rate <= 0) return;
    host.repeat_key = keycode;
    host.repeat_next_ms = nowMs() + @max(host.kb_delay, 30);
}

/// Re-arm a widget's cadence from now (a note that starts editing, or gets
/// a key, wants its 500 ms blink/autosave ticks immediately).
fn reschedule(host: *Host, i: usize) void {
    host.next_tick_ms[i] = nowMs() + host.widgets[i].intervalMs();
}

/// Stop editing the editing note: commit (Esc / focus-leave / click
/// elsewhere) and hand the slot and key routing back.
fn endEdit(host: *Host) void {
    const i = host.edit_index orelse return;
    host.edit_index = null;
    host.repeat_key = null;
    host.repeat_next_ms = 0;
    switch (host.widgets[i]) {
        .note1 => |*n| {
            n.commit();
            n.endEditing();
        },
        else => {},
    }
    reschedule(host, i);
    markDirty(host, i);
}

/// Reaps finished detached children (weather/media fetches) so they don't
/// pile up as zombies.
fn reapChildren() void {
    while (true) {
        var status: c_int = undefined;
        const pid = std.c.waitpid(-1, &status, std.c.W.NOHANG);
        if (pid <= 0) break;
    }
}

// --- sticky-note self-test (PERIHELIONBAR_SELFTEST=1) -----------------------------
// This box has no input-injection tool (wtype/ydotool/dotool absent,
// /dev/uinput needs root), so with the env var set the shell drives note1
// through the SAME pointer/keyboard code paths the compositor events take,
// verifies the persisted file, then restores the note's original text.
//   1. a synthetic press+release over note1 starts editing,
//   2. evdev key codes go through onKeyboardKey → xkb decode → NoteWidget,
//   3. Esc commits and note1.txt must contain exactly the typed text,
//   4. the original note text is written back so nothing is left behind.
var g_selftest = false;
var g_st_done = false;
var g_st_start_ms: i64 = 0;

fn runSelfTest(host: *Host) void {
    g_st_done = true;
    var slot_idx: ?usize = null;
    for (0..host.widget_count) |i| {
        if (widgets_mod.noteSlot(&host.widgets[i]) == 1) {
            slot_idx = i;
            break;
        }
    }
    const i = slot_idx orelse {
        logging.warn("selftest: config has no note1 — SKIP", .{});
        return;
    };
    const n = &host.widgets[i].note1;
    const orig_len = n.text_len;
    var orig_buf: [widgets_mod.NoteWidget.NOTE_MAX]u8 = undefined;
    @memcpy(orig_buf[0..orig_len], n.text()[0..orig_len]);
    const path = n.path();
    var failures: usize = 0;

    // Click into the note's first text line (question mark placement: the
    // card rect is known, the pointer is fake).
    const r = host.widget_rects[i];
    const lh = widgets_mod.lineH(host.font);
    host.pointer_x = r.x + 40;
    host.pointer_y = r.y + @as(i32, @intCast(widgets_mod.CARD_PAD + widgets_mod.noteHeaderH(lh) + @divTrunc(lh, 2)));
    _ = updateHover(host);
    pointerButton(host, BTN_LEFT, true);
    pointerButton(host, BTN_LEFT, false);
    if (host.edit_index != i) {
        failures += 1;
        logging.err("selftest: click did not start editing (edit_index={?})", .{host.edit_index});
    }

    // Type "abc 123", backspace once, Enter, then Esc to commit. evdev key
    // codes: a=30 b=48 c=46 space=57 1=2 2=3 3=4 backspace=14 enter=28 esc=1.
    const seq = [_]u32{ 30, 48, 46, 57, 2, 3, 4, 14, 28, 1 };
    for (seq) |code| {
        onKeyboardKey(host, code, true);
        onKeyboardKey(host, code, false);
    }
    if (host.edit_index != null) {
        failures += 1;
        logging.err("selftest: Esc did not close editing", .{});
    }

    const saved = readFileAlloc(host.gpa, path) catch null;
    defer if (saved) |s| host.gpa.free(s);
    const want = "abc 12\n";
    if (saved) |s| {
        if (!std.mem.eql(u8, s, want)) {
            failures += 1;
            logging.err("selftest: note1.txt = \"{s}\", want \"{s}\"", .{ s, want });
        }
    } else {
        failures += 1;
        logging.err("selftest: could not read back {s}", .{path});
    }

    // Restore the original note (content in memory + on disk) and release
    // the edit slot so the desktop is exactly as it was.
    n.text_len = orig_len;
    @memcpy(n.text_buf[0..orig_len], orig_buf[0..orig_len]);
    n.caret = orig_len;
    n.scroll = 0;
    n.editing = false;
    n.dirty = false;
    host.edit_index = null;
    host.repeat_key = null;
    _ = widgets_mod.writeFileAtomicZ(path, orig_buf[0..orig_len]);
    reschedule(host, i);
    markDirty(host, i);

    if (failures == 0) {
        logging.step("SELFTEST PASS — note edit→commit round-trip ok (\"{s}\" saved, original restored)", .{want});
    } else {
        logging.err("SELFTEST FAIL — {d} failure(s); note restored to original", .{failures});
    }
}

// --- overview control socket (Alt+W) ---------------------------------------
//
// `perihelionbar-shell overview [toggle|open|close]` connects here. One daemon
// per XDG_RUNTIME_DIR: a live socket makes the second instance exit
// quietly (the bind probe below), stale files are unlinked and rebound.
// Requests are one line ("overview toggle\n"), so accept + a bounded read +
// reply all happen inside the poll loop — the daemon never blocks on a
// client, and clients never need to know about Wayland.

const IPC_PATH_LEN = 256;

fn ipcSockPathZ(buf: []u8) ?[:0]const u8 {
    const dir = std.mem.sliceTo(getenv("XDG_RUNTIME_DIR") orelse return null, 0);
    return std.fmt.bufPrintSentinel(buf, "{s}/perihelionbar-shell.sock", .{dir}, 0) catch null;
}

fn ipcUnixAddr(path: []const u8) !std.os.linux.sockaddr.un {
    var addr: std.os.linux.sockaddr.un = .{ .path = undefined };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

/// Creates (or takes over) the control socket. `error.AlreadyRunning` means
/// a live daemon answered the connect probe — main exits 0 on it, which is
/// what keeps autostart + the Alt+W bind from double-painting the desktop.
fn ipcListen() !posix.fd_t {
    var path_buf: [IPC_PATH_LEN]u8 = undefined;
    const path = ipcSockPathZ(&path_buf) orelse return error.NoRuntimeDir;

    const probe = std.c.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0);
    if (probe >= 0) {
        const probe_fd: posix.fd_t = @intCast(probe);
        const probe_addr = try ipcUnixAddr(path);
        const alive = std.c.connect(probe_fd, @ptrCast(&probe_addr), @sizeOf(std.os.linux.sockaddr.un)) == 0;
        _ = posix.system.close(probe_fd);
        if (alive) return error.AlreadyRunning;
    }

    _ = std.c.unlink(path.ptr); // stale file from a crashed run
    const raw = std.c.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0);
    if (raw < 0) return error.SocketCreateFailed;
    const fd: posix.fd_t = @intCast(raw);
    errdefer _ = posix.system.close(fd);
    const addr = try ipcUnixAddr(path);
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.os.linux.sockaddr.un)) != 0) return error.BindFailed;
    if (std.c.listen(fd, 4) != 0) return error.ListenFailed;
    return fd;
}

/// Handle one control-socket connection: read the request (the client
/// writes immediately after connect, but the wakeup and that write race —
/// poll briefly first; requests are <64 bytes so one read is the whole
/// message) and reply. Static replies, so the client can gate on "ok".
fn ipcAccept(listen_fd: posix.fd_t, host: *Host) void {
    const raw = std.c.accept4(
        listen_fd,
        null,
        null,
        std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK,
    );
    if (raw < 0) return;
    const fd: posix.fd_t = @intCast(raw);
    defer _ = posix.system.close(fd);

    var pfds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    _ = posix.poll(&pfds, 200) catch 0;
    if (pfds[0].revents & posix.POLL.IN == 0) return;

    var buf: [256]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return;
    const reply = ipcHandle(host, buf[0..@intCast(n)]);
    _ = std.c.write(fd, reply.ptr, reply.len);
}

fn ipcHandle(host: *Host, data: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    // `glance [toggle|open|close] [overview|media|weather]` (Super+I).
    if (glance.parseLine(trimmed)) |parsed| {
        const cmd = parsed catch return "err usage: glance [toggle|open|close] [overview|media|weather]\n";
        const gl = host.glance orelse return "err glance is off (shell.json glance_enabled)\n";
        return if (gl.command(cmd)) "ok\n" else "err glance could not open\n";
    }
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const head = it.next() orelse return "err empty\n";
    if (!std.mem.eql(u8, head, "overview")) return "err unknown command\n";
    const verb = it.next() orelse "toggle";
    const ov = host.overview orelse return "err overview unavailable\n";
    if (std.mem.eql(u8, verb, "open")) {
        return if (ov.open()) "ok\n" else "err open failed\n";
    } else if (std.mem.eql(u8, verb, "close")) {
        ov.close();
        return "ok\n";
    } else if (std.mem.eql(u8, verb, "toggle")) {
        return if (ov.toggle()) "ok\n" else "err toggle failed\n";
    }
    return "err unknown action\n";
}

fn cliPrint(fd: c_int, msg: []const u8) void {
    _ = std.c.write(fd, msg.ptr, msg.len);
}

const CLI_USAGE =
    "usage: perihelion-shell [overview [toggle|open|close]]\n" ++
    "       perihelion-shell glance [toggle|open|close] [overview|media|weather]\n";

fn cliOverview(action: []const u8) noreturn {
    if (!std.mem.eql(u8, action, "toggle") and
        !std.mem.eql(u8, action, "open") and
        !std.mem.eql(u8, action, "close"))
    {
        cliPrint(2, CLI_USAGE);
        std.process.exit(2);
    }
    var msg_buf: [64]u8 = undefined;
    cliSend(std.fmt.bufPrint(&msg_buf, "overview {s}\n", .{action}) catch unreachable);
}

/// `perihelion-shell glance ...`: checked here first, so a typo gets the
/// usage line without bothering the daemon.
fn cliGlance(args: []const []const u8) noreturn {
    const cmd = glance.parseArgs(args) catch {
        cliPrint(2, CLI_USAGE);
        std.process.exit(2);
    };
    var msg_buf: [64]u8 = undefined;
    cliSend(glance.formatRequest(&msg_buf, cmd) catch unreachable);
}

/// Client side of the control socket: send one request line, print the
/// daemon's reply, exit 0 when it starts with "ok". Never returns.
fn cliSend(msg: []const u8) noreturn {
    var path_buf: [IPC_PATH_LEN]u8 = undefined;
    const path = ipcSockPathZ(&path_buf) orelse {
        cliPrint(2, "perihelion-shell: XDG_RUNTIME_DIR not set\n");
        std.process.exit(1);
    };
    const raw = std.c.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0);
    if (raw < 0) {
        cliPrint(2, "perihelion-shell: socket() failed\n");
        std.process.exit(1);
    }
    const fd: posix.fd_t = @intCast(raw);
    const addr = ipcUnixAddr(path) catch {
        _ = posix.system.close(fd);
        cliPrint(2, "perihelion-shell: control path too long\n");
        std.process.exit(1);
    };
    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.os.linux.sockaddr.un)) != 0) {
        _ = posix.system.close(fd);
        cliPrint(2, "perihelion-shell: no running instance (start perihelion-shell first)\n");
        std.process.exit(1);
    }

    var off: usize = 0;
    while (off < msg.len) {
        const n = std.c.write(fd, msg[off..].ptr, msg.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }

    // The daemon replies then closes, so read until EOF (it always answers
    // or drops the connection — no hang risk beyond the daemon's own).
    var reply: [512]u8 = undefined;
    var got: usize = 0;
    while (got < reply.len) {
        const n = std.c.read(fd, reply[got..].ptr, reply.len - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    _ = posix.system.close(fd);

    if (got == 0) {
        cliPrint(2, "perihelion-shell: no reply from the running instance\n");
        std.process.exit(1);
    }
    const out: []const u8 = reply[0..got];
    if (std.mem.startsWith(u8, out, "ok")) {
        cliPrint(1, out);
        std.process.exit(0);
    }
    cliPrint(2, out);
    std.process.exit(1);
}

pub fn main(init: std.process.Init.Minimal) !void {
    // Client mode: `perihelionbar-shell overview [toggle|open|close]` sends the
    // verb to the running daemon over its control socket and prints the
    // reply — this is exactly what Alt+W runs (see hyprland.lua). Anything
    // else as a first argument is a typo, not a daemon start.
    var args_it = std.process.Args.Iterator.init(init.args);
    _ = args_it.next(); // argv[0]
    if (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "overview")) {
            cliOverview(args_it.next() orelse "toggle");
        }
        if (std.mem.eql(u8, arg, "glance")) {
            var words: [glance.MAX_ARGS][]const u8 = undefined;
            var n: usize = 0;
            while (args_it.next()) |a| {
                if (n == words.len) {
                    cliPrint(2, CLI_USAGE);
                    std.process.exit(2);
                }
                words[n] = a;
                n += 1;
            }
            cliGlance(words[0..n]);
        }
        var ubuf: [384]u8 = undefined;
        const usage = std.fmt.bufPrint(
            &ubuf,
            "perihelion-shell: unknown command \"{s}\"\n" ++ CLI_USAGE,
            .{arg},
        ) catch "perihelion-shell: unknown command\n";
        cliPrint(2, usage);
        std.process.exit(2);
    }

    logging.init("perihelion-shell");
    defer logging.deinit();

    // SIGUSR1 live-reload (g_reload_pending): matugen rewrites the palette
    // file on every wallpaper change and signals both this shell and the bar
    // so neither is left showing yesterday's colours.
    {
        const act = posix.Sigaction{
            .handler = .{ .sigaction = reloadSignalHandler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.SIGINFO,
        };
        posix.sigaction(.USR1, &act, null);
    }
    // DebugAllocator does leak tracking and guard work on every allocation;
    // keep it for Debug builds, but use libc's release allocator for the
    // shipping builds. Both choices stay paired with every free below.
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa: std.mem.Allocator = if (builtin.mode == .debug)
        gpa_state.allocator()
    else
        std.heap.c_allocator;

    g_gpa = gpa;
    resolveConfigPaths();
    var cfg = loadConfig(gpa);
    // Per-widget kill switches (perihelionbar-config writes the disabled list):
    // filter the startup copy, leaving g_shell_cfg (and shell.json positions)
    // complete so re-enabling restores widgets where they were. Zero left
    // means exit before touching Wayland — the autostart entries relaunch
    // this binary every login, so this is what keeps "everything off" off
    // across sessions without editing autostart files. `overview ...` client
    // commands return before this point and are unaffected.
    applyDisabledWidgets(gpa, &cfg);
    if (cfg.widget_count == 0) {
        logging.step("widgets: all widgets switched off — exiting", .{});
        return;
    }
    var theme = widgets_mod.Theme{
        .card_alpha = cfg.card_bg_opacity,
        .radius_px = cfg.corner_radius,
    };
    if (tryApplyMatugenColors(gpa, &theme)) {
        logging.step("theme: applied matugen colors", .{});
    }

    var font_path_buf: [512]u8 = undefined;
    const font_path_z = fontPathZ(cfg.font_path, &font_path_buf) orelse font_mod.FONT_PATH;
    var font = font_mod.Font.init(gpa, font_path_z, FONT_PIXEL_SIZE) catch |err| blk: {
        logging.warn("font: could not load {s}: {} — falling back to {s}", .{ font_path_z, err, font_mod.FONT_PATH });
        break :blk try font_mod.Font.init(gpa, font_mod.FONT_PATH, FONT_PIXEL_SIZE);
    };
    defer font.deinit();

    const display = try wl.Display.connect(null);
    defer display.disconnect();
    setCloexec(display.getFd());

    const registry = try display.getRegistry();
    var globals = Globals{};
    registry.setListener(*Globals, registryListener, &globals);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const compositor = globals.compositor orelse return error.NoCompositor;
    const shm = globals.shm orelse return error.NoShm;
    const layer_shell = globals.layer_shell orelse return error.NoLayerShell;

    if (globals.seat) |seat| {
        _ = seat;
    }

    var host = Host{
        .gpa = gpa,
        .theme = theme,
        .font = &font,
        .shm = shm,
        .compositor = compositor,
    };
    initWidgets(&host, cfg);
    defer for (host.tiles) |t| if (t) |buf| gpa.free(buf); // leak-check clean
    defer host.backdrop.deinit(gpa);
    defer for (&host.zoom_fonts) |*slot| {
        if (slot.*) |*f| f.deinit();
        slot.* = null;
    };
    logging.step("widgets: {d} placed on {d} output(s)", .{ host.widget_count, globals.outputs.count });

    // Overview mode (Alt+W): constructed once, surface created/destroyed
    // per open. Every reference stays valid for the process lifetime (the
    // Host, the font, the Globals), which the listeners rely on. Failure
    // degrades to "no overview", never to a dead shell.
    const ov_ptr = gpa.create(overview_mod.Overview) catch |err| blk: {
        logging.err("overview: init failed: {}", .{err});
        break :blk null;
    };
    if (ov_ptr) |ov| {
        ov.* = .{
            .gpa = gpa,
            .font = &font,
            .theme = &host.theme,
            .compositor = compositor,
            .shm = shm,
            .layer_shell = layer_shell,
            .screencopy = globals.screencopy,
            .outputs = &globals.outputs,
            .favs = cfg.fav_cmds[0..cfg.fav_count],
        };
        host.overview = ov;
    }
    defer if (host.overview) |ov| {
        ov.deinit();
        gpa.destroy(ov);
    };

    // Glance (Super+I): wiring only. Its surface, panel buffer and card
    // instances exist only while it's open (glance_view.zig).
    if (cfg.glance_enabled) {
        if (gpa.create(glance_view.Glance)) |gl| {
            gl.* = .{
                .gpa = gpa,
                .font = &font,
                .theme = &host.theme,
                .compositor = compositor,
                .shm = shm,
                .layer_shell = layer_shell,
                .backdrop = &host.backdrop,
                .setup = setupGlanceCards,
                .start_tab = cfg.glance_start_tab,
            };
            host.glance = gl;
        } else |err| logging.err("glance: init failed: {}", .{err});
    }
    defer if (host.glance) |gl| {
        gl.deinit();
        gpa.destroy(gl);
    };

    // One desktop layer surface per output (or a single compositor-picked
    // surface if the registry reported none), anchored edge-to-edge on the
    // bottom layer — above the wallpaper's background level, never below
    // it. Same-level layers stack by map order, so a freshly restarted
    // swaybg (every wallpaper change) would bury .background widgets under
    // the new wallpaper surface; .bottom always composites above it while
    // staying below windows and the bar.
    const desktop_count: usize = if (globals.outputs.count > 0) globals.outputs.count else 1;
    for (0..desktop_count) |i| {
        const surface = compositor.createSurface() catch continue;
        const output: ?*wl.Output = if (i < globals.outputs.count) globals.outputs.list[i] else null;
        const layer_surface = layer_shell.getLayerSurface(
            surface,
            output,
            .bottom,
            "perihelion-shell",
        ) catch {
            surface.destroy();
            continue;
        };
        layer_surface.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
        layer_surface.setExclusiveZone(0);
        // on_demand: clicking a card takes keyboard focus, which is the only
        // way a client sees modifier state — Ctrl+drag needs it. Focus
        // returns to the clicked window on its next click, like any other
        // on_demand surface; keys are otherwise ignored.
        layer_surface.setKeyboardInteractivity(.on_demand);
        host.desktops[host.desktop_count] = .{
            .host = &host,
            .surface = surface,
            .layer_surface = layer_surface,
        };
        host.desktop_count += 1;

        // Initial empty commit so the compositor engages the layer role and
        // sends the first configure (the bar relies on the same configure
        // event to learn the surface size).
        surface.commit();

        const d = &host.desktops[host.desktop_count - 1];
        layer_surface.setListener(*Desktop, layerSurfaceListener, d);
    }
    if (host.desktop_count == 0) return error.NoSurfaceCreated;

    const pointer: ?*wl.Pointer = if (globals.seat) |seat|
        (if (globals.seat_has_pointer) seat.getPointer() catch null else null)
    else
        null;
    defer if (pointer) |p| p.release();
    if (pointer) |p| p.setListener(*Host, pointerListener, &host);

    // Keyboard exists purely for modifier state (Ctrl+drag); it gets focus
    // on_demand when a card is clicked.
    const keyboard: ?*wl.Keyboard = if (globals.seat) |seat|
        (if (globals.seat_has_keyboard) seat.getKeyboard() catch null else null)
    else
        null;
    defer if (keyboard) |kb| kb.release();
    if (keyboard) |kb| kb.setListener(*Host, keyboardListener, &host);

    g_selftest = getenv("PERIHELIONBAR_SELFTEST") != null;
    if (g_selftest) logging.warn("selftest: PERIHELIONBAR_SELFTEST set — note1 will be driven at startup", .{});
    g_st_start_ms = nowMs();

    // Control socket for `perihelionbar-shell overview ...` (Alt+W). A live daemon
    // answering the probe makes this a clean 0-exit; an unusable socket just
    // logs — the widgets must outlive a broken /run. The selftest runs
    // alongside a live daemon, so it skips the socket entirely.
    const ipc_fd: posix.fd_t = if (g_selftest) -1 else ipcListen() catch |err| blk: {
        if (err == error.AlreadyRunning) {
            logging.step("ipc: another perihelionbar-shell holds the control socket — exiting", .{});
            return;
        }
        logging.warn("ipc: no control socket (overview toggle dead): {}", .{err});
        break :blk -1;
    };

    // Pidfile only once this instance actually owns the daemon slot (past the
    // AlreadyRunning exit above, and never in selftest mode): the GUI's
    // toggle-restart waits for this pidfile to change, which must mean "new
    // instance fully up", and a zero-widget exit leaves no pidfile pointing
    // at a dead process.
    if (!g_selftest) writeShellPidfile();

    // Slot 0: display fd, slot 1: control socket (fixed), slots 2+:
    // widget fetch pipes, then Glance's card pipes while it's open
    // (refreshed every loop).
    var poll_fds = [_]posix.pollfd{
        .{ .fd = display.getFd(), .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = ipc_fd, .events = posix.POLL.IN, .revents = 0 },
    } ++ @as([MAX_WIDGETS + glance.CARD_COUNT]posix.pollfd, @splat(.{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }));

    while (true) {
        // Refresh the pipe fds (they change across fetch cycles).
        for (poll_fds[2..]) |*pf| pf.fd = -1;
        for (0..host.widget_count) |i| {
            const widget_fd = host.widgets[i].pollFd();
            if (widget_fd < 0) continue;
            for (poll_fds[2..]) |*pf| {
                if (pf.fd < 0) {
                    pf.fd = widget_fd;
                    break;
                }
            }
        }
        if (host.glance) |gl| {
            var gl_fds: [glance.CARD_COUNT]posix.fd_t = undefined;
            const n = gl.pollFds(&gl_fds);
            for (poll_fds[2 + MAX_WIDGETS ..][0..n], gl_fds[0..n]) |*pf, fd| pf.fd = fd;
        }

        _ = display.flush();

        const now = nowMs();

        // Poll with a timeout computed from the earliest widget cadence
        // deadline — the "lazy repaint" schedule from the friend's shell.
        var next_deadline: i64 = std.math.maxInt(i64);
        for (0..host.widget_count) |i| {
            next_deadline = @min(next_deadline, host.next_tick_ms[i]);
        }
        // A held key (note edit, overview search) needs its auto-repeat
        // fired on schedule too.
        if (host.repeat_key != null and repeatWanted(&host)) {
            next_deadline = @min(next_deadline, host.repeat_next_ms);
        }
        // Capture in flight: the screencopy answer (or its timeout) must
        // wake the loop even with no widget cadence pending.
        if (host.overview) |ov| {
            if (ov.deadline()) |d| next_deadline = @min(next_deadline, d);
        }
        // Glance: animation frames, or its cards' cadences while open.
        if (host.glance) |gl| {
            if (gl.deadline()) |d| next_deadline = @min(next_deadline, d);
        }
        const timeout: i32 = blk: {
            if (next_deadline == std.math.maxInt(i64)) break :blk -1; // nothing to wake for; wait for events only
            const rel = next_deadline - now;
            break :blk @intCast(@max(@min(rel, std.math.maxInt(i32)), 0));
        };

        const ready = posix.poll(&poll_fds, timeout) catch 0;

        // SIGUSR1 (matugen's post_hook) → re-read the palette. The signal
        // interrupts poll() as well, which surfaces here as ready == 0, so a
        // reload is picked up on this pass whether or not an event woke us —
        // including when the loop was parked waiting for the next frame.
        if (g_reload_pending.swap(false, .acquire)) reloadTheme(&host);

        if (ready > 0) {
            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
            }
            if (poll_fds[1].revents & posix.POLL.IN != 0) ipcAccept(ipc_fd, &host);
            var pipe_ready = false;
            for (poll_fds[2..]) |pf| {
                if (pf.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
                    pipe_ready = true;
                    break;
                }
            }
            if (pipe_ready) {
                for (0..host.widget_count) |i| {
                    if (host.widgets[i].onPipe()) markDirty(&host, i);
                }
                if (host.glance) |gl| gl.onPipes();
            }
        }

        reapChildren();

        // Fire any widget cadences that came due.
        const now2 = nowMs();

        // Overview housekeeping: a screencopy that never answers must not
        // leave Alt+W silently dead (maps with cards instead), and pointer
        // focus needs hygiene once the surface is gone — a destroyed
        // surface isn't guaranteed to produce a leave event, but the flag
        // must not outlive it or desktop hover would stay routed to
        // nowhere.
        if (host.overview) |ov| {
            ov.pollTimeout(now2);
            if (ov.anim == .closed and host.pointer_over_ov) host.pointer_over_ov = false;
        }
        // Glance: animation step, due card ticks, at most one frame. Same
        // pointer hygiene once its surface is gone.
        if (host.glance) |gl| {
            gl.tick(now2);
            if (gl.surface == null and host.pointer_over_gl) host.pointer_over_gl = false;
        }

        for (0..host.widget_count) |i| {
            if (now2 >= host.next_tick_ms[i]) {
                if (host.widgets[i].tick()) markDirty(&host, i);
                host.next_tick_ms[i] = now2 + host.widgets[i].intervalMs();
            }
        }

        // Hold-down auto-repeat while editing a note or the overview search
        // — synthesized from the compositor's rate/delay so
        // Backspace/arrows/repeated letters feel like a native editor
        // instead of a per-event text widget.
        if (host.repeat_key != null and repeatWanted(&host) and now2 >= host.repeat_next_ms) {
            keyPress(&host, host.repeat_key.?);
            host.repeat_next_ms = now2 + @max(@divTrunc(1000, @max(host.kb_rate, 1)), 10);
        }

        // Self-test: once the keymap is live, drive note1 through the exact
        // pointer/key paths the compositor events use, then verify the file.
        if (g_selftest and !g_st_done and g_kb_ready and now2 - g_st_start_ms > 800) {
            runSelfTest(&host);
        }

        if (host.needs_repaint) {
            host.needs_repaint = false;
            for (0..host.desktop_count) |i| {
                paintDesktop(&host, &host.desktops[i]) catch |err| {
                    logging.err("draw failed: {}", .{err});
                };
            }
        }
    }
}