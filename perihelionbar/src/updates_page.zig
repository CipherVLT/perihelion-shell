//! Perihelion Settings > System > Updates.
//!
//!   This device      installed version and commit, how it was installed,
//!                    automatic checks (on/off, every N hours), last checked
//!   Software update  a status line, then Check now / Download / Install
//!                    update / Restart shell, each live only when it makes
//!                    sense (updater_core.buttons)
//!   Release notes    the latest release's notes, after a check
//!
//! The page is a thin front: every step runs this same program headless
//! (`perihelion-settings --check-updates`, `--download-update`,
//! `--install-update DIR TAG`; see updater_run.zig) as an async GSubprocess,
//! so the window never blocks, and reads the step's last line. Nothing runs
//! until the page is first shown.

const std = @import("std");
const gtk = @import("welcome_gtk.zig");
const hg = @import("hypr_gtk.zig");
const hp = @import("hypr_pages.zig");
const core = @import("updater_core.zig");
const urun = @import("updater_run.zig");
const cli_version = @import("cli_version");

extern "c" fn g_subprocess_newv(argv: [*]const ?[*:0]const u8, flags: c_int, err: ?*?*anyopaque) ?*anyopaque;
extern "c" fn g_subprocess_communicate_async(sub: *anyopaque, stdin_buf: ?*anyopaque, cancellable: ?*anyopaque, callback: *const fn (?*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) void;
extern "c" fn g_subprocess_communicate_finish(sub: *anyopaque, result: *anyopaque, stdout_buf: ?*?*anyopaque, stderr_buf: ?*?*anyopaque, err: ?*?*anyopaque) c_int;
extern "c" fn g_bytes_get_data(bytes: *anyopaque, size: *usize) ?[*]const u8;
extern "c" fn g_bytes_unref(bytes: *anyopaque) void;
extern "c" fn gtk_widget_set_visible(widget: *anyopaque, visible: c_int) void;
extern "c" fn gtk_widget_get_mapped(widget: *anyopaque) c_int;
extern "c" fn gtk_label_set_selectable(self: *anyopaque, setting: c_int) void;
extern "c" fn time(t: ?*i64) i64;

const SUBPROCESS_STDOUT_PIPE: c_int = 1 << 2;
const SUBPROCESS_STDERR_MERGE: c_int = 1 << 6;

/// Set by config_main: the auto-check settings changed (save them).
pub var on_settings: ?*const fn (auto: bool, hours: u32) void = null;
/// Set by config_main: restart the bar, the dock, the shell and the drawer.
pub var on_restart: ?*const fn () void = null;

// --- state ------------------------------------------------------------------------------

var g_phase: core.Phase = .idle;
var g_method: core.Method = .unknown;
var g_have_release = false;
var g_inited = false;
var g_tag_buf: [64]u8 = undefined;
var g_tag: []const u8 = "";
var g_dir_buf: [256]u8 = undefined;
var g_dir: []const u8 = "";
var g_detail_buf: [512]u8 = undefined;

var g_page: ?*gtk.GtkBox = null;
var g_version_row: ?*gtk.AdwActionRow = null;
var g_method_row: ?*gtk.AdwActionRow = null;
var g_auto_row: ?*hg.AdwSwitchRow = null;
var g_interval_row: ?*gtk.AdwActionRow = null;
var g_interval_spin: ?*gtk.GtkSpinButton = null;
var g_checked_row: ?*gtk.AdwActionRow = null;
var g_status_row: ?*gtk.AdwActionRow = null;
var g_spinner: ?*gtk.GtkSpinner = null;
var g_btn_check: ?*gtk.GtkButton = null;
var g_btn_download: ?*gtk.GtkButton = null;
var g_btn_install: ?*gtk.GtkButton = null;
var g_btn_restart: ?*gtk.GtkButton = null;
var g_notes_group: ?*gtk.AdwPreferencesGroup = null;
var g_notes_label: ?*gtk.GtkLabel = null;

// --- running the headless steps ------------------------------------------------------------

const Done = *const fn (kind: []const u8, rest: []const u8) void;

/// The last non-empty line of a step's output, split into its first word
/// and the rest ("ready /tmp/x" -> "ready", "/tmp/x").
fn lastLine(out: []const u8) struct { []const u8, []const u8 } {
    var it = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, out, "\r\n "), '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return .{ line, "" };
        return .{ line[0..sp], line[sp + 1 ..] };
    }
    return .{ "error", "The step stopped without saying why." };
}

fn onStepDone(source: ?*anyopaque, res: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const sub = source orelse return;
    const done: Done = @ptrFromInt(@intFromPtr(user_data.?));
    var out_bytes: ?*anyopaque = null;
    _ = g_subprocess_communicate_finish(sub, res, &out_bytes, null, null);
    var text: []const u8 = "";
    if (out_bytes) |b| {
        var size: usize = 0;
        if (g_bytes_get_data(b, &size)) |p| text = p[0..size];
    }
    const kr = lastLine(text);
    done(kr[0], kr[1]);
    if (out_bytes) |b| g_bytes_unref(b);
    gtk.g_object_unref(sub);
}

/// Runs this program again with `args` (it handles them headless).
fn step(args: []const ?[*:0]const u8, done: Done) bool {
    var argv: [8]?[*:0]const u8 = @splat(null);
    argv[0] = "/proc/self/exe";
    for (args, 1..) |a, i| argv[i] = a;
    const sub = g_subprocess_newv(&argv, SUBPROCESS_STDOUT_PIPE | SUBPROCESS_STDERR_MERGE, null) orelse return false;
    g_subprocess_communicate_async(sub, null, null, &onStepDone, @ptrFromInt(@intFromPtr(done)));
    return true;
}

// --- rendering ---------------------------------------------------------------------------

fn setSubtitle(row: ?*gtk.AdwActionRow, text: []const u8) void {
    const r = row orelse return;
    var buf: [600]u8 = undefined;
    gtk.adw_action_row_set_subtitle(r, markupZ(text, &buf));
}

/// Row subtitles are Pango markup: escape what the network sent.
fn markupZ(s: []const u8, buf: []u8) [*:0]const u8 {
    var n: usize = 0;
    for (s) |c| {
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => &.{c},
        };
        if (n + rep.len + 1 > buf.len) break;
        @memcpy(buf[n..][0..rep.len], rep);
        n += rep.len;
    }
    buf[n] = 0;
    return @ptrCast(buf[0..n :0].ptr);
}

fn render(detail: []const u8) void {
    if (g_status_row) |r| {
        var tb: [128]u8 = undefined;
        const title: []const u8 = switch (g_phase) {
            .available => std.fmt.bufPrint(&tb, "{s} is available", .{g_tag}) catch core.statusText(g_phase),
            .ready => std.fmt.bufPrint(&tb, "{s} is ready to install", .{g_tag}) catch core.statusText(g_phase),
            .installed => std.fmt.bufPrint(&tb, "{s} is installed", .{g_tag}) catch core.statusText(g_phase),
            else => core.statusText(g_phase),
        };
        var zb: [160]u8 = undefined;
        gtk.adw_preferences_row_set_title(@ptrCast(r), markupZ(title, &zb));
    }
    const d: []const u8 = if (detail.len > 0) detail else switch (g_phase) {
        .available => if (g_method.canInstall()) "Download it to check it before anything is installed." else "Perihelion Linux brings it with the next system update.",
        .ready => "Checksum, contents and every program checked. Installing asks for your password.",
        .installed => "The running bar, dock and desktop are still the old version.",
        else => "",
    };
    setSubtitle(g_status_row, d);
    const busy = switch (g_phase) {
        .checking, .downloading, .installing, .restarting => true,
        else => false,
    };
    if (g_spinner) |sp| {
        gtk_widget_set_visible(@ptrCast(sp), @intFromBool(busy));
        if (busy) gtk.gtk_spinner_start(sp) else gtk.gtk_spinner_stop(sp);
    }
    const b = core.buttons(g_phase, g_method.canInstall(), g_have_release);
    if (g_btn_check) |w| gtk.gtk_widget_set_sensitive(@ptrCast(w), @intFromBool(b.check));
    if (g_btn_download) |w| gtk.gtk_widget_set_sensitive(@ptrCast(w), @intFromBool(b.download));
    if (g_btn_install) |w| gtk.gtk_widget_set_sensitive(@ptrCast(w), @intFromBool(b.install));
    if (g_btn_restart) |w| gtk.gtk_widget_set_sensitive(@ptrCast(w), @intFromBool(b.restart));
}

fn renderDevice() void {
    var vb: [64]u8 = undefined;
    var out: [256]u8 = undefined;
    // The installed bar, not this window: after an update the two differ
    // until Settings is reopened.
    const r = urun.run(&.{ "/usr/bin/perihelion-bar", "--version" }, null, 10, &out);
    var commit: []const u8 = cli_version.commit;
    var version: []const u8 = cli_version.version;
    if (r.exited_ok) {
        version = urun.installedVersion(&vb);
        if (std.mem.indexOfScalar(u8, r.out, '(')) |o| if (std.mem.indexOfScalarPos(u8, r.out, o, ')')) |c| {
            commit = r.out[o + 1 .. c];
        };
    }
    var tb: [160]u8 = undefined;
    setSubtitle(g_version_row, std.fmt.bufPrint(&tb, "{s} \u{b7} commit {s}", .{ version, commit }) catch version);

    const marker = urun.readMarker();
    defer if (marker) |m| std.heap.c_allocator.free(m);
    g_method = core.detectMethod(urun.isoRefExists(), marker);
    setSubtitle(g_method_row, g_method.label());

    var saved_text: ?[]u8 = null;
    const saved = urun.loadSaved(&saved_text);
    defer if (saved_text) |t| std.heap.c_allocator.free(t);
    var ab: [48]u8 = undefined;
    setSubtitle(g_checked_row, core.agoText(&ab, saved.last_checked, time(null)));
}

/// The release the last check saved: its notes, and whether it is newer.
fn loadRelease() void {
    var pb: [600]u8 = undefined;
    const home = std.mem.span(std.c.getenv("HOME") orelse return);
    const xdg = std.c.getenv("XDG_STATE_HOME");
    const path = if (xdg != null and std.mem.span(xdg.?).len > 0)
        std.fmt.bufPrint(&pb, "{s}/perihelionbar/latest-release.json", .{std.mem.span(xdg.?)}) catch return
    else
        std.fmt.bufPrint(&pb, "{s}/.local/state/perihelionbar/latest-release.json", .{home}) catch return;
    const json = urun.readFile(path, 1 << 20) orelse return;
    defer std.heap.c_allocator.free(json);
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const rel = core.parseRelease(arena.allocator(), json) catch return;
    const n = @min(rel.tag.len, g_tag_buf.len);
    @memcpy(g_tag_buf[0..n], rel.tag[0..n]);
    g_tag = g_tag_buf[0..n];

    var vb: [64]u8 = undefined;
    const installed = core.Version.parse(urun.installedVersion(&vb));
    g_have_release = if (installed) |iv| rel.version.isNewer(iv) else true;

    if (g_notes_group) |grp| {
        var tb: [160]u8 = undefined;
        const title = std.fmt.bufPrintSentinel(&tb, "Release notes \u{2014} {s}", .{rel.title}, 0) catch "Release notes";
        gtk.adw_preferences_group_set_title(grp, title.ptr);
        gtk_widget_set_visible(@ptrCast(grp), 1);
    }
    if (g_notes_label) |l| {
        const notes = if (rel.notes.len > 0) rel.notes else "This release has no notes.";
        const zn = arena.allocator().dupeSentinel(u8, notes[0..@min(notes.len, 16 * 1024)], 0) catch return;
        gtk.gtk_label_set_text(l, zn.ptr);
    }
}

fn initOnce() void {
    if (g_inited) return;
    g_inited = true;
    renderDevice();
    loadRelease();
    if (g_tag.len > 0) g_phase = if (g_have_release) .available else .up_to_date;
    render("");
}

fn onTick(_: ?*anyopaque) callconv(.c) c_int {
    const page = g_page orelse return 0;
    if (gtk_widget_get_mapped(@ptrCast(page)) != 0) {
        initOnce();
        return 0; // first show done; the page updates itself after each step
    }
    return 1;
}

// --- actions ----------------------------------------------------------------------------------

fn failed(rest: []const u8) void {
    g_phase = .failed;
    const n = @min(rest.len, g_detail_buf.len);
    @memcpy(g_detail_buf[0..n], rest[0..n]);
    render(g_detail_buf[0..n]);
}

fn onCheckDone(kind: []const u8, rest: []const u8) void {
    renderDevice();
    if (!std.mem.eql(u8, kind, "latest")) return failed(rest);
    loadRelease();
    g_phase = if (g_have_release) .available else .up_to_date;
    render("");
}

fn onCheck(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    g_phase = .checking;
    render("");
    if (!step(&.{"--check-updates"}, onCheckDone)) failed("Could not start the check.");
}

fn onDownloadDone(kind: []const u8, rest: []const u8) void {
    if (!std.mem.eql(u8, kind, "ready")) return failed(rest);
    const n = @min(rest.len, g_dir_buf.len);
    @memcpy(g_dir_buf[0..n], rest[0..n]);
    g_dir = g_dir_buf[0..n];
    g_phase = .ready;
    render("");
}

fn onDownload(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    g_phase = .downloading;
    render("");
    if (!step(&.{"--download-update"}, onDownloadDone)) failed("Could not start the download.");
}

fn onInstallDone(kind: []const u8, rest: []const u8) void {
    if (!std.mem.eql(u8, kind, "installed")) return failed(rest);
    g_phase = .installed;
    g_have_release = false;
    renderDevice();
    render("");
}

fn onInstall(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (g_dir.len == 0 or g_tag.len == 0) return;
    var db: [260]u8 = undefined;
    var tb: [70]u8 = undefined;
    const dz = std.fmt.bufPrintSentinel(&db, "{s}", .{g_dir}, 0) catch return;
    const tz = std.fmt.bufPrintSentinel(&tb, "{s}", .{g_tag}, 0) catch return;
    g_phase = .installing;
    render("");
    if (!step(&.{ "--install-update", dz.ptr, tz.ptr }, onInstallDone)) failed("Could not start the install.");
}

fn onRestartSettled(_: ?*anyopaque) callconv(.c) c_int {
    g_phase = .up_to_date;
    renderDevice();
    render("The bar, the dock, the desktop and the app drawer run the new version.");
    return 0;
}

fn onRestart(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    g_phase = .restarting;
    render("");
    if (on_restart) |f| f();
    _ = gtk.g_timeout_add(1500, onRestartSettled, null);
}

fn onAutoChanged(row: *anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const on = hg.adw_switch_row_get_active(@ptrCast(row)) != 0;
    if (g_interval_row) |r| gtk.gtk_widget_set_sensitive(@ptrCast(r), @intFromBool(on));
    const hours: u32 = if (g_interval_spin) |s| @intCast(@max(1, gtk.gtk_spin_button_get_value_as_int(s))) else core.DEFAULT_INTERVAL_H;
    if (on_settings) |f| f(on, hours);
}

fn onIntervalChanged(spin: *gtk.GtkSpinButton, _: ?*anyopaque) callconv(.c) void {
    const on = if (g_auto_row) |r| hg.adw_switch_row_get_active(r) != 0 else true;
    const hours: u32 = @intCast(@max(1, gtk.gtk_spin_button_get_value_as_int(spin)));
    if (on_settings) |f| f(on, hours);
}

// --- the page -----------------------------------------------------------------------------------

fn infoRow(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, icon: [:0]const u8) *gtk.AdwActionRow {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), title);
    gtk.adw_action_row_add_prefix(row, @ptrCast(gtk.gtk_image_new_from_icon_name(icon)));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
    return row;
}

fn button(box: *gtk.GtkBox, label: [:0]const u8, handler: gtk.GCallback, suggested: bool) *gtk.GtkButton {
    const b = gtk.gtk_button_new_with_label(label);
    gtk.gtk_widget_add_css_class(@ptrCast(b), "pill");
    if (suggested) gtk.gtk_widget_add_css_class(@ptrCast(b), "suggested-action");
    _ = gtk.g_signal_connect_data(@ptrCast(b), "clicked", handler, null, null, 0);
    gtk.gtk_box_append(box, @ptrCast(b));
    return b;
}

pub fn build(auto_check: bool, interval_h: u32) *gtk.GtkBox {
    const outer = hp.pageBox();
    g_page = outer;

    // -- This device ------------------------------------------------------------
    const device = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(device, "This device");
    g_version_row = infoRow(device, "Installed version", "application-x-executable-symbolic");
    setSubtitle(g_version_row, cli_version.version);
    g_method_row = infoRow(device, "Installed with", "system-software-install-symbolic");
    {
        const row = hg.adw_switch_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Check automatically");
        gtk.adw_action_row_set_subtitle(@ptrCast(row), "Looks for a new release in the background and tells you when there is one.");
        hg.adw_switch_row_set_active(row, @intFromBool(auto_check));
        _ = gtk.g_signal_connect_data(@ptrCast(row), "notify::active", @ptrCast(&onAutoChanged), null, null, 0);
        gtk.adw_preferences_group_add(device, @ptrCast(row));
        g_auto_row = row;
    }
    {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Check every");
        gtk.adw_action_row_set_subtitle(row, "Hours between automatic checks");
        const spin = gtk.gtk_spin_button_new_with_range(@floatFromInt(core.MIN_INTERVAL_H), @floatFromInt(core.MAX_INTERVAL_H), 1);
        gtk.gtk_spin_button_set_value(spin, @floatFromInt(core.clampInterval(interval_h)));
        gtk.gtk_widget_set_valign(@ptrCast(spin), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(spin), "value-changed", @ptrCast(&onIntervalChanged), null, null, 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(spin));
        gtk.gtk_widget_set_sensitive(@ptrCast(row), @intFromBool(auto_check));
        gtk.adw_preferences_group_add(device, @ptrCast(row));
        g_interval_row = row;
        g_interval_spin = spin;
    }
    g_checked_row = infoRow(device, "Last checked", "document-open-recent-symbolic");
    gtk.gtk_box_append(outer, @ptrCast(device));

    // -- Software update ---------------------------------------------------------
    const upd = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(upd, "Software update");
    gtk.adw_preferences_group_set_description(upd, "Releases of Perihelion Shell from GitHub. Every download is checked (SHA-256, contents, and each program started once) before anything is installed.");
    {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Not checked yet.");
        gtk.adw_action_row_add_prefix(row, @ptrCast(gtk.gtk_image_new_from_icon_name("software-update-available-symbolic")));
        const sp = gtk.gtk_spinner_new();
        gtk.gtk_widget_set_valign(@ptrCast(sp), gtk.ALIGN_CENTER);
        gtk.adw_action_row_add_suffix(row, @ptrCast(sp));
        gtk.adw_preferences_group_add(upd, @ptrCast(row));
        g_status_row = row;
        g_spinner = sp;
    }
    gtk.gtk_box_append(outer, @ptrCast(upd));

    const buttons = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_set_halign(@ptrCast(buttons), gtk.ALIGN_CENTER);
    g_btn_check = button(buttons, "Check now", @ptrCast(&onCheck), false);
    g_btn_download = button(buttons, "Download", @ptrCast(&onDownload), false);
    g_btn_install = button(buttons, "Install update", @ptrCast(&onInstall), true);
    g_btn_restart = button(buttons, "Restart shell", @ptrCast(&onRestart), false);
    gtk.gtk_box_append(outer, @ptrCast(buttons));

    // -- Release notes -------------------------------------------------------------
    const notes = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(notes, "Release notes");
    const label = gtk.gtk_label_new("");
    gtk.gtk_label_set_wrap(label, 1);
    gtk.gtk_label_set_xalign(label, 0);
    gtk_label_set_selectable(@ptrCast(label), 1);
    // The text inside a card with room around it (a label carries no padding).
    const card = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(@ptrCast(card), "card");
    gtk.gtk_widget_set_margin_top(@ptrCast(label), 14);
    gtk.gtk_widget_set_margin_bottom(@ptrCast(label), 14);
    gtk.gtk_widget_set_margin_start(@ptrCast(label), 16);
    gtk.gtk_widget_set_margin_end(@ptrCast(label), 16);
    gtk.gtk_box_append(card, @ptrCast(label));
    gtk.adw_preferences_group_add(notes, @ptrCast(card));
    gtk.gtk_box_append(outer, @ptrCast(notes));
    gtk_widget_set_visible(@ptrCast(notes), 0);
    g_notes_group = notes;
    g_notes_label = label;

    render("");
    _ = gtk.g_timeout_add(250, onTick, null);
    return outer;
}
