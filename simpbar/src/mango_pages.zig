// Simpbar Config — MangoWM settings pages (the compositor section of the
// navigation sidebar when running under MangoWM / mangowm).
//
// Unlike the Hyprland pages (which edit hyprland.zig's in-memory model and
// render a managed Lua snippet), Mango's config *is* a set of flat
// `key = value` files under ~/.config/mango/cfg/, pulled in by
// ~/.config/mango/config.conf. So these pages read those files through
// mango.zig's line-preserving Doc, edit them in place (every change writes
// the file back atomically), and call `mmsg dispatch reload_config` to apply.
//
// Layout mirrors hypr_pages.zig deliberately:
//   - Its own page list (Event Horizon's settings order); config_main sizes
//     the sidebar from `pages.names` at runtime.
//   - "boxed-list" GtkListBox for the multi-value rule/bind/autostart/env
//     lists, AdwPreferencesGroup form rows for the scalar settings.
//   - Rows are backed by stable addresses (a fixed global Field/ctx pool, or
//     the doc line index as an int user_data), never dangling heap structs.
//   - Signals are connected AFTER the initial value is set, so building a
//     row never fires a spurious write.
//
// Colours here are Mango's 0xRRGGBBAA (lowercase), NOT Hyprland's #rrggbb /
// 0xAARRGGBB, so this file has its own conversion helpers and does not reuse
// hypr_pages.hexToRgba.

const std = @import("std");
const gtk = @import("welcome_gtk.zig");
const hg = @import("hypr_gtk.zig");
const hp = @import("hypr_pages.zig");
const hypr = @import("hyprland.zig");
const mango = @import("mango.zig");
const desk = @import("desk_theme.zig");
const mon = @import("monitors.zig");

const gpa = std.heap.c_allocator;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// ---------------------------------------------------------------------
// Config documents
// ---------------------------------------------------------------------

var doc_appearance: mango.Doc = .{};
var doc_input: mango.Doc = .{};
var doc_monitors: mango.Doc = .{};
var doc_keybinds: mango.Doc = .{};
var doc_rules: mango.Doc = .{};
var doc_layout: mango.Doc = .{};
var doc_autostart: mango.Doc = .{};
var doc_env: mango.Doc = .{};
var doc_misc: mango.Doc = .{};

fn cfgPath(buf: []u8, name: []const u8) []const u8 {
    const home: []const u8 = if (getenv("HOME")) |h| std.mem.span(h) else "/root";
    return std.fmt.bufPrint(buf, "{s}/.config/mango/cfg/{s}", .{ home, name }) catch "";
}

pub fn init() void {
    var b: [512]u8 = undefined;
    doc_appearance.load(cfgPath(&b, "appearance.conf"));
    doc_input.load(cfgPath(&b, "input.conf"));
    doc_monitors.load(cfgPath(&b, "monitors.conf"));
    doc_keybinds.load(cfgPath(&b, "keybinds.conf"));
    doc_rules.load(cfgPath(&b, "rules.conf"));
    doc_layout.load(cfgPath(&b, "layout.conf"));
    doc_autostart.load(cfgPath(&b, "autostart.conf"));
    doc_env.load(cfgPath(&b, "env.conf"));
    doc_misc.load(cfgPath(&b, "misc.conf"));
}

/// Applies the config now: `mmsg dispatch reload_config` re-reads every sourced
/// file. Blocking but fast; usable from a button callback.
pub fn reload() void {
    if (hypr.captureOutput(&.{ "mmsg", "dispatch", "reload_config" }, 4000)) |out| gpa.free(out);
}

// ---------------------------------------------------------------------
// Colour helpers (Mango 0xRRGGBBAA)
// ---------------------------------------------------------------------

fn mangoHexToRgba(hex: []const u8) ?gtk.GdkRGBA {
    var strip = hex;
    if (strip.len > 0 and strip[0] == '#') {
        strip = strip[1..];
    } else if (std.mem.startsWith(u8, strip, "0x") or std.mem.startsWith(u8, strip, "0X")) {
        strip = strip[2..];
    }
    if (strip.len != 6 and strip.len != 8) return null;
    const v = std.fmt.parseInt(u32, strip, 16) catch return null;
    const r: u32 = if (strip.len == 8) (v >> 24) & 0xff else (v >> 16) & 0xff;
    const g: u32 = if (strip.len == 8) (v >> 16) & 0xff else (v >> 8) & 0xff;
    const b: u32 = if (strip.len == 8) (v >> 8) & 0xff else v & 0xff;
    const a: u32 = if (strip.len == 8) v & 0xff else 0xff;
    return .{
        .red = @as(f32, @floatFromInt(r)) / 255.0,
        .green = @as(f32, @floatFromInt(g)) / 255.0,
        .blue = @as(f32, @floatFromInt(b)) / 255.0,
        .alpha = @as(f32, @floatFromInt(a)) / 255.0,
    };
}

fn rgbaToMangoColor(c: gtk.GdkRGBA, buf: []u8) []const u8 {
    const clamp = std.math.clamp;
    const r: u32 = @intFromFloat(@round(clamp(c.red, 0.0, 1.0) * 255.0));
    const g: u32 = @intFromFloat(@round(clamp(c.green, 0.0, 1.0) * 255.0));
    const b: u32 = @intFromFloat(@round(clamp(c.blue, 0.0, 1.0) * 255.0));
    const a: u32 = @intFromFloat(@round(clamp(c.alpha, 0.0, 1.0) * 255.0));
    return std.fmt.bufPrint(buf, "0x{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b, a }) catch "0x000000ff";
}

const ColorCtx = struct { doc: *mango.Doc, key: []const u8 };
var g_color_ctx: [64]ColorCtx = undefined;
var g_color_n: usize = 0;

fn onColorChanged(button: *gtk.GtkColorDialogButton, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *ColorCtx = @ptrCast(@alignCast(user_data.?));
    const rgba = gtk.gtk_color_dialog_button_get_rgba(button).*;
    var buf: [16]u8 = undefined;
    ctx.doc.setValue(ctx.key, rgbaToMangoColor(rgba, &buf));
    _ = ctx.doc.save();
    reload();
}

fn addColorField(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, doc: *mango.Doc, key: []const u8, default: []const u8) void {
    if (g_color_n >= g_color_ctx.len) g_color_n = 0;
    const ctx = &g_color_ctx[g_color_n];
    g_color_n += 1;
    ctx.* = .{ .doc = doc, .key = key };

    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), title);
    const dialog = gtk.gtk_color_dialog_new();
    const button = gtk.gtk_color_dialog_button_new(dialog);
    const cur = doc.value(key) orelse default;
    if (mangoHexToRgba(cur)) |rgba| gtk.gtk_color_dialog_button_set_rgba(button, &rgba);
    gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(button), "notify::rgba", @ptrCast(&onColorChanged), @ptrCast(ctx), null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(button));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

// ---------------------------------------------------------------------
// Scalar form fields — one stable Field per row, edited live.
// ---------------------------------------------------------------------

const Field = struct {
    doc: *mango.Doc,
    key: []const u8,
    is_float: bool = false,
    combo: ?[]const []const u8 = null,
};

var g_fields: [1024]Field = undefined;
var g_fields_n: usize = 0;

fn fieldFor(doc: *mango.Doc, key: []const u8, is_float: bool, combo: ?[]const []const u8) *Field {
    if (g_fields_n >= g_fields.len) g_fields_n = 0;
    const f = &g_fields[g_fields_n];
    g_fields_n += 1;
    f.* = .{ .doc = doc, .key = key, .is_float = is_float, .combo = combo };
    return f;
}

fn onFieldEntry(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const f: *Field = @ptrCast(@alignCast(user_data.?));
    f.doc.setValue(f.key, std.mem.span(gtk.gtk_entry_buffer_get_text(buffer)));
    _ = f.doc.save();
}

fn onFieldSpin(spin: *gtk.GtkSpinButton, user_data: ?*anyopaque) callconv(.c) void {
    const f: *Field = @ptrCast(@alignCast(user_data.?));
    var buf: [64]u8 = undefined;
    const s = if (f.is_float)
        std.fmt.bufPrint(&buf, "{d}", .{hg.gtk_spin_button_get_value(spin)}) catch return
    else
        std.fmt.bufPrint(&buf, "{d}", .{gtk.gtk_spin_button_get_value_as_int(spin)}) catch return;
    f.doc.setValue(f.key, s);
    _ = f.doc.save();
}

fn onFieldSwitch(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const f: *Field = @ptrCast(@alignCast(user_data.?));
    f.doc.setValue(f.key, if (gtk.gtk_switch_get_active(sw) != 0) "1" else "0");
    _ = f.doc.save();
    reload();
}

fn onFieldCombo(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const f: *Field = @ptrCast(@alignCast(user_data.?));
    const vals = f.combo orelse return;
    const idx = gtk.adw_combo_row_get_selected(row);
    if (idx >= vals.len) return;
    f.doc.setValue(f.key, vals[idx]);
    _ = f.doc.save();
    reload();
}

fn addEntryField(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, doc: *mango.Doc, key: []const u8, default: []const u8, width: c_int) void {
    const cur = doc.value(key) orelse default;
    hp.addEntryRow(group, title, cur, width, @ptrCast(&onFieldEntry), @ptrCast(fieldFor(doc, key, false, null)));
}

fn addSpinField(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, min: f64, max: f64, step: f64, doc: *mango.Doc, key: []const u8, default: f64, is_float: bool) void {
    addSpinFieldCb(group, title, min, max, step, doc, key, default, is_float, @ptrCast(&onFieldSpin));
}

fn addSpinFieldCb(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, min: f64, max: f64, step: f64, doc: *mango.Doc, key: []const u8, default: f64, is_float: bool, cb: gtk.GCallback) void {
    const initial = if (is_float) doc.getFloat(key, default) else @as(f64, @floatFromInt(doc.getInt(key, @intFromFloat(default))));
    hp.addSpinRow(group, title, min, max, step, initial, cb, @ptrCast(fieldFor(doc, key, is_float, null)));
}

fn addSwitchField(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, doc: *mango.Doc, key: []const u8, default: bool) void {
    hp.addSwitchRow(group, title, "", doc.getBool(key, default), @ptrCast(&onFieldSwitch), @ptrCast(fieldFor(doc, key, false, null)));
}

fn addComboField(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, labels: []const [*:0]const u8, values: []const []const u8, doc: *mango.Doc, key: []const u8, default: []const u8) void {
    addComboFieldCb(group, title, labels, values, doc, key, default, @ptrCast(&onFieldCombo));
}

fn addComboFieldCb(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, labels: []const [*:0]const u8, values: []const []const u8, doc: *mango.Doc, key: []const u8, default: []const u8, cb: gtk.GCallback) void {
    const cur = doc.value(key) orelse default;
    var sel: c_uint = 0;
    for (values, 0..) |v, i| {
        if (std.mem.eql(u8, cur, v)) {
            sel = @intCast(i);
            break;
        }
    }
    hp.addComboRow(group, title, labels, sel, cb, @ptrCast(fieldFor(doc, key, false, values)));
}

// ---------------------------------------------------------------------
// Per-surface blur switches — the Blur group's Bar / Desktop Widgets
// rows. These are NOT single appearance.conf keys: each toggles the
// `no_blur` param on that surface's layer_rule line in rules.conf
// (Mango only blurs a layer when blur_layer is on AND no rule opts it
// out, so the switch reads/writes that opt-out).
// ---------------------------------------------------------------------

const BlurCtx = struct { surface: []const u8 };
var g_blur_ctx: [8]BlurCtx = undefined;
var g_blur_n: usize = 0;

/// Splits one `layer_rule` value into its comma-separated params. For each
/// non-empty fragment calls `f` with (key, value) — value is "" when the
/// fragment carries no colon (kept verbatim by the writer below, mirroring
/// openRuleDialog's extras handling).
fn eachRuleParam(value: []const u8, ctx: anytype, f: fn (@TypeOf(ctx), []const u8, []const u8, []const u8) void) void {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        if (std.mem.indexOfScalar(u8, p, ':')) |c| {
            f(ctx, p, std.mem.trim(u8, p[0..c], " \t"), std.mem.trim(u8, p[c + 1 ..], " \t"));
        } else {
            f(ctx, p, "", "");
        }
    }
}

/// Index of the LAST layer_rule line matching `surface` (later rules win),
/// or null. Mango matches layer_name as a regex; the GUI works on exact
/// names, same as the Layer Rules editor's display.
fn layerRuleIndexFor(surface: []const u8) ?usize {
    var found: ?usize = null;
    for (doc_rules.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (!std.mem.eql(u8, kv.key, "layer_rule")) continue;
        var name_match = false;
        var it = std.mem.splitScalar(u8, kv.value, ',');
        while (it.next()) |raw| {
            const p = std.mem.trim(u8, raw, " \t");
            const c = std.mem.indexOfScalar(u8, p, ':') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, p[0..c], " \t"), "layer_name") and
                std.mem.eql(u8, std.mem.trim(u8, p[c + 1 ..], " \t"), surface))
            {
                name_match = true;
                break;
            }
        }
        if (name_match) found = i;
    }
    return found;
}

/// Effective blur state for a layer-shell surface: blurred unless its
/// (last matching) layer_rule line opts out with no_blur:1. Missing line or
/// missing param both mean blurred — the default once blur_layer is on.
fn layerBlurEnabled(surface: []const u8) bool {
    const i = layerRuleIndexFor(surface) orelse return true;
    const kv = mango.parseKV(doc_rules.line(i)) orelse return true;
    var it = std.mem.splitScalar(u8, kv.value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        const c = std.mem.indexOfScalar(u8, p, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, p[0..c], " \t"), "no_blur")) {
            const v = std.mem.trim(u8, p[c + 1 ..], " \t");
            return !(std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true"));
        }
    }
    return true;
}

const BlurEmit = struct { out: []u8, n: *usize, first: *bool, want: []const u8, saw: *bool };

fn blurEmitSet(ctx: *BlurEmit, frag: []const u8, pk: []const u8, pv: []const u8) void {
    if (!ctx.first.*) appendStr(ctx.out, ctx.n, ", ");
    ctx.first.* = false;
    if (pk.len == 0) {
        appendStr(ctx.out, ctx.n, frag);
    } else if (std.mem.eql(u8, pk, "no_blur")) {
        appendStr(ctx.out, ctx.n, "no_blur:");
        appendStr(ctx.out, ctx.n, ctx.want);
        ctx.saw.* = true;
    } else {
        appendStr(ctx.out, ctx.n, pk);
        appendStr(ctx.out, ctx.n, ":");
        appendStr(ctx.out, ctx.n, pv);
    }
}

/// Sets the surface's blur state, preserving every other param (and any
/// colon-less extras) on its layer_rule line in place. Appends a minimal
/// opt-out line when turning off with no line to edit; turning on with no
/// line needs no write — blurring is the default for layers.
fn setLayerBlur(surface: []const u8, on: bool) void {
    const want: []const u8 = if (on) "0" else "1";
    if (layerRuleIndexFor(surface)) |mi| {
        const kv = mango.parseKV(doc_rules.line(mi)) orelse return;
        var buf: [mango.MAX_LINE]u8 = undefined;
        var n: usize = 0;
        var first = true;
        var saw = false;
        var ctx: BlurEmit = .{ .out = &buf, .n = &n, .first = &first, .want = want, .saw = &saw };
        appendStr(&buf, &n, "layer_rule = ");
        eachRuleParam(kv.value, &ctx, blurEmitSet);
        if (!saw) {
            appendStr(&buf, &n, ", no_blur:");
            appendStr(&buf, &n, want);
        }
        doc_rules.setLine(mi, buf[0..n]);
    } else if (!on) {
        var buf: [mango.MAX_LINE]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "layer_rule = no_blur:1, layer_name:{s}", .{surface}) catch return;
        doc_rules.appendLine(s);
    }
}

fn onSurfaceBlurSwitch(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *BlurCtx = @ptrCast(@alignCast(user_data.?));
    const on = gtk.gtk_switch_get_active(sw) != 0;
    if (on and !doc_appearance.getBool("blur_layer", true)) {
        // A surface switch is meaningless with layer blur off — enable it
        // (the group description says this happens).
        doc_appearance.setValue("blur_layer", "1");
        _ = doc_appearance.save();
    }
    setLayerBlur(ctx.surface, on);
    _ = doc_rules.save();
    reload();
    rebuildRuleList(&g_rp_lrules);
}

fn addSurfaceBlurSwitch(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, surface: []const u8) void {
    if (g_blur_n >= g_blur_ctx.len) g_blur_n = 0;
    const ctx = &g_blur_ctx[g_blur_n];
    g_blur_n += 1;
    ctx.* = .{ .surface = surface };
    hp.addSwitchRow(group, title, "", layerBlurEnabled(surface), @ptrCast(&onSurfaceBlurSwitch), @ptrCast(ctx));
}

// ---------------------------------------------------------------------
// Small utilities
// ---------------------------------------------------------------------

const MAX_DFIELDS = 24;

fn appendStr(out: []u8, n: *usize, s: []const u8) void {
    if (n.* >= out.len) return;
    const room = out.len - n.*;
    const k = @min(room, s.len);
    @memcpy(out[n.*..][0..k], s[0..k]);
    n.* += k;
}

/// AdwPreferencesGroup titles, AdwActionRow titles/subtitles are parsed as
/// Pango markup, so a literal '&'/'<'/'>' in user config (e.g. a bind whose
/// arguments contain "&&") would otherwise fail to render. Copies `s` into
/// `buf` (entity-escaped) and returns it NUL-terminated.
fn escapeZ(s: []const u8, buf: []u8) [*:0]const u8 {
    var n: usize = 0;
    for (s) |c| {
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => {
                if (n + 1 >= buf.len) break;
                buf[n] = c;
                n += 1;
                continue;
            },
        };
        if (n + rep.len >= buf.len) break;
        @memcpy(buf[n..][0..rep.len], rep);
        n += rep.len;
    }
    buf[n] = 0;
    return buf[0..n :0].ptr;
}

fn addRowButtonEx(row: *gtk.AdwActionRow, label: [:0]const u8, cb: gtk.GCallback, user_data: ?*anyopaque, rp: ?*const RulePage) void {
    const btn = gtk.gtk_button_new_with_label(label);
    gtk.gtk_widget_set_valign(@ptrCast(btn), gtk.ALIGN_CENTER);
    if (rp) |r| gtk.g_object_set_data(@ptrCast(btn), "rp", @ptrCast(@constCast(r)));
    _ = gtk.g_signal_connect_data(@ptrCast(btn), "clicked", cb, user_data, null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(btn));
}

/// Local copy of hp.addEntryRow that also returns the entry widget, for the
/// dialogs that rebuild their line from several entries.
fn addEntryRowRet(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, initial: []const u8, width: c_int, cb: gtk.GCallback, user_data: ?*anyopaque) *gtk.GtkEntry {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), title);
    const entry = gtk.gtk_entry_new();
    gtk.gtk_widget_set_size_request(@ptrCast(entry), width, -1);
    gtk.gtk_widget_set_valign(@ptrCast(entry), gtk.ALIGN_CENTER);
    const buffer = gtk.gtk_entry_get_buffer(entry);
    hp.setEntryZ(buffer, initial);
    _ = gtk.g_signal_connect_data(@ptrCast(buffer), "notify::text", cb, user_data, null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(entry));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
    return entry;
}

// ---------------------------------------------------------------------
// Edit-dialog context (one dialog at a time)
// ---------------------------------------------------------------------

const DlgKind = enum { pair, bind, raw };

const DlgCtx = struct {
    kind: DlgKind = .pair,
    doc: *mango.Doc = undefined,
    key: []const u8 = "",
    line: usize = 0,
    spec: []const [:0]const u8 = &.{},
    entries: [MAX_DFIELDS]*gtk.GtkEntry = undefined,
    nfields: usize = 0,
    extras: [1024]u8 = undefined,
    extras_len: usize = 0,
};

var g_dlg: DlgCtx = undefined;

fn buildPairValue(ctx: *DlgCtx, out: []u8) []const u8 {
    var n: usize = 0;
    var first = true;
    var i: usize = 0;
    while (i < ctx.nfields) : (i += 1) {
        const t = hp.entryText(ctx.entries[i]);
        if (t.len == 0) continue;
        if (!first) appendStr(out, &n, ", ");
        first = false;
        appendStr(out, &n, ctx.spec[i]);
        appendStr(out, &n, ":");
        appendStr(out, &n, t);
    }
    if (ctx.extras_len > 0) {
        if (!first) appendStr(out, &n, ", ");
        appendStr(out, &n, ctx.extras[0..ctx.extras_len]);
    }
    return out[0..n];
}

fn buildBindValue(ctx: *DlgCtx, out: []u8) []const u8 {
    var n: usize = 0;
    appendStr(out, &n, hp.entryText(ctx.entries[0]));
    appendStr(out, &n, ", ");
    appendStr(out, &n, hp.entryText(ctx.entries[1]));
    appendStr(out, &n, ", ");
    appendStr(out, &n, hp.entryText(ctx.entries[2]));
    const args = hp.entryText(ctx.entries[3]);
    if (args.len > 0) {
        appendStr(out, &n, ", ");
        appendStr(out, &n, args);
    }
    return out[0..n];
}

fn writeDlgLine() void {
    var vb: [2048]u8 = undefined;
    const value: []const u8 = switch (g_dlg.kind) {
        .pair => buildPairValue(&g_dlg, &vb),
        .bind => buildBindValue(&g_dlg, &vb),
        .raw => hp.entryText(g_dlg.entries[0]),
    };
    var lb: [2200]u8 = undefined;
    const line = std.fmt.bufPrint(&lb, "{s} = {s}", .{ g_dlg.key, value }) catch return;
    g_dlg.doc.setLine(g_dlg.line, line);
    _ = g_dlg.doc.save();
}

fn onDlgEntryChanged(_: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    writeDlgLine();
}

fn onCtxDialogClosed(_: *hg.AdwDialog, _: ?*anyopaque) callconv(.c) void {
    reload();
    rebuildAll();
}

fn presentCtxDialog(parent: *anyopaque, title: [:0]const u8, content: *gtk.GtkBox) void {
    const d = hg.adw_dialog_new();
    hg.adw_dialog_set_title(d, title);
    hg.adw_dialog_set_content_width(d, 600);
    hg.adw_dialog_set_child(d, @ptrCast(content));
    _ = gtk.g_signal_connect_data(@ptrCast(d), "closed", @ptrCast(&onCtxDialogClosed), null, null, 0);
    hp.addDialogFooter(content, d);
    hg.adw_dialog_present(d, parent);
}

// ---------------------------------------------------------------------
// Rule pages (monitor_rule / window_rule / layer_rule / tag_rule)
// ---------------------------------------------------------------------

const RulePage = struct {
    doc: *mango.Doc,
    key: []const u8,
    spec: []const [:0]const u8,
    list: *?*gtk.GtkListBox,
    title: [:0]const u8,
    desc: [:0]const u8,
    add_label: [:0]const u8,
    add_value: []const u8,
    dlg_title: [:0]const u8,
};

var g_monitors_list: ?*gtk.GtkListBox = null;
var g_wrules_list: ?*gtk.GtkListBox = null;
var g_lrules_list: ?*gtk.GtkListBox = null;
var g_tagrules_list: ?*gtk.GtkListBox = null;

const MON_SPEC = [_][:0]const u8{ "name", "width", "height", "refresh", "x", "y", "scale", "rr", "vrr", "mirror" };
const WIN_SPEC = [_][:0]const u8{ "app_id", "title", "is_floating", "is_scratchpad", "is_opensilent", "is_not_focus", "no_border", "no_animation", "no_blur", "no_shadow", "no_radius", "move_to_tag", "move_to_monitor" };
const LAYER_SPEC = [_][:0]const u8{ "layer_name", "no_animation", "no_blur", "no_shadow", "no_radius", "animation_type_open", "animation_type_close" };
const TAG_SPEC = [_][:0]const u8{ "id", "layout_name" };

var g_rp_monitors: RulePage = .{
    .doc = &doc_monitors,
    .key = "monitor_rule",
    .spec = &MON_SPEC,
    .list = &g_monitors_list,
    .title = "Monitors",
    .desc = "One row per monitor_rule. Values are comma-separated key:value pairs (name, width, height, refresh, x, y, scale, rr, vrr, mirror). Auto-detect fills them from the connected displays.",
    .add_label = "Add Monitor Rule",
    .add_value = "name:DP-1, width:1920, height:1080, refresh:60, x:0, y:0, rr:0, vrr:0",
    .dlg_title = "Edit Monitor Rule",
};
var g_rp_wrules: RulePage = .{
    .doc = &doc_rules,
    .key = "window_rule",
    .spec = &WIN_SPEC,
    .list = &g_wrules_list,
    .title = "Window Rules",
    .desc = "One row per window_rule. Match fields (app_id, title) plus options like is_floating, no_border, no_blur.",
    .add_label = "Add Window Rule",
    .add_value = "app_id:",
    .dlg_title = "Edit Window Rule",
};
var g_rp_lrules: RulePage = .{
    .doc = &doc_rules,
    .key = "layer_rule",
    .spec = &LAYER_SPEC,
    .list = &g_lrules_list,
    .title = "Layer Rules",
    .desc = "One row per layer_rule, matched by layer_name. Controls animations, blur, shadows and radius for layer-shell surfaces.",
    .add_label = "Add Layer Rule",
    .add_value = "layer_name:",
    .dlg_title = "Edit Layer Rule",
};
var g_rp_tags: RulePage = .{
    .doc = &doc_layout,
    .key = "tag_rule",
    .spec = &TAG_SPEC,
    .list = &g_tagrules_list,
    .title = "Tag Layouts",
    .desc = "One row per tag_rule, assigning a layout to each tag (workspace). Later rules win for the same tag.",
    .add_label = "Add Tag Layout",
    .add_value = "id:1, layout_name:dwindle",
    .dlg_title = "Edit Tag Layout",
};

fn ruleTitle(rp: *const RulePage, value: []const u8, buf: []u8) [*:0]const u8 {
    const keys = [_][]const u8{ "name", "app_id", "layer_name", "id" };
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        const c = std.mem.indexOfScalar(u8, p, ':') orelse continue;
        const pk = std.mem.trim(u8, p[0..c], " \t");
        const pv = std.mem.trim(u8, p[c + 1 ..], " \t");
        if (pv.len == 0) continue;
        for (keys) |k| {
            if (std.mem.eql(u8, pk, k)) return escapeZ(pv, buf);
        }
    }
    return escapeZ(rp.title, buf);
}

fn openRuleDialog(parent: *anyopaque, rp: *const RulePage, line: usize) void {
    if (line >= rp.doc.lineCount()) return;
    const kv = mango.parseKV(rp.doc.line(line)) orelse return;

    g_dlg = .{ .kind = .pair, .doc = rp.doc, .key = rp.key, .line = line, .spec = rp.spec, .nfields = rp.spec.len };

    var vals = [_][]const u8{""} ** MAX_DFIELDS;
    var extras_n: usize = 0;
    var it = std.mem.splitScalar(u8, kv.value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        var matched = false;
        if (std.mem.indexOfScalar(u8, p, ':')) |c| {
            const pk = std.mem.trim(u8, p[0..c], " \t");
            const pv = std.mem.trim(u8, p[c + 1 ..], " \t");
            for (rp.spec, 0..) |sk, i| {
                if (std.mem.eql(u8, pk, sk)) {
                    vals[i] = pv;
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            if (extras_n > 0) appendStr(&g_dlg.extras, &extras_n, ", ");
            appendStr(&g_dlg.extras, &extras_n, p);
        }
    }
    g_dlg.extras_len = extras_n;

    const content = hp.newDialogBox();
    const group = gtk.adw_preferences_group_new();
    var i: usize = 0;
    while (i < rp.spec.len and i < MAX_DFIELDS) : (i += 1) {
        g_dlg.entries[i] = addEntryRowRet(group, rp.spec[i], vals[i], 220, @ptrCast(&onDlgEntryChanged), @ptrCast(&g_dlg));
    }
    gtk.gtk_box_append(content, @ptrCast(group));
    presentCtxDialog(parent, rp.dlg_title, content);
}

fn onRuleEdit(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const d = gtk.g_object_get_data(@ptrCast(button), "rp") orelse return;
    const rp: *const RulePage = @ptrCast(@alignCast(d));
    const line = @intFromPtr(user_data.?) - 1;
    // Monitor rules get the capability-aware canvas dialog (resolution /
    // refresh dropdowns from wlr-randr modes); everything else keeps the
    // generic pair editor.
    if (rp == &g_rp_monitors) {
        openMangoMonitorDialog(@ptrCast(button), line);
        return;
    }
    openRuleDialog(@ptrCast(button), rp, line);
}

fn onRuleRemove(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const d = gtk.g_object_get_data(@ptrCast(button), "rp") orelse return;
    const rp: *const RulePage = @ptrCast(@alignCast(d));
    rp.doc.removeLine(@intFromPtr(user_data.?) - 1);
    _ = rp.doc.save();
    reload();
    rebuildRuleList(rp);
    if (rp == &g_rp_monitors) queueMangoCanvasDraw();
}

fn onRuleAdd(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const rp: *const RulePage = @ptrCast(@alignCast(user_data.?));
    var lb: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&lb, "{s} = {s}", .{ rp.key, rp.add_value }) catch return;
    rp.doc.appendLine(line);
    _ = rp.doc.save();
    reload();
    rebuildRuleList(rp);
    queueMangoCanvasDraw();
    if (rp == &g_rp_monitors) {
        openMangoMonitorDialog(@ptrCast(button), rp.doc.lineCount() - 1);
        return;
    }
    openRuleDialog(@ptrCast(button), rp, rp.doc.lineCount() - 1);
}

fn rebuildRuleList(rp: *const RulePage) void {
    const listbox = rp.list.* orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (rp.doc.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (!std.mem.eql(u8, kv.key, rp.key)) continue;

        const row = gtk.adw_action_row_new();
        var tb: [hp.MAX_TITLE]u8 = undefined;
        gtk.adw_preferences_row_set_title(@ptrCast(row), ruleTitle(rp, kv.value, &tb));
        var sb: [hp.MAX_ZBUF]u8 = undefined;
        gtk.adw_action_row_set_subtitle(row, escapeZ(kv.value, &sb));
        addRowButtonEx(row, "Edit", @ptrCast(&onRuleEdit), @ptrFromInt(i + 1), rp);
        addRowButtonEx(row, "Remove", @ptrCast(&onRuleRemove), @ptrFromInt(i + 1), rp);
        gtk.gtk_list_box_append(listbox, @ptrCast(row));
    }
}

fn addRulePage(outer: *gtk.GtkBox, rp: *const RulePage) void {
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, rp.title);
    gtk.adw_preferences_group_set_description(group, rp.desc);
    gtk.gtk_box_append(outer, @ptrCast(group));

    const lb = hp.newListBox();
    rp.list.* = lb;
    gtk.gtk_box_append(outer, @ptrCast(lb));
    rebuildRuleList(rp);
    hp.appendActionButton(outer, rp.add_label, @ptrCast(&onRuleAdd), @ptrCast(@constCast(rp)));
}

// ---------------------------------------------------------------------
// Monitors page — Event-Horizon-style editor for MangoWM.
// monitor_rule lines keep their flat `key:value` format; the page adds:
//   - a visual arrange canvas (click to select, drag to move, snap +
//     normalize on drop),
//   - capability-aware Resolution / Refresh dropdowns parsed from the FULL
//     `wlr-randr` mode list (not just the current mode),
//   - side-by-side / align-tops helpers,
//   - and the original Auto-detect button (fills name/width/height/
//     refresh/x/y from live outputs, preserving scale/rr/vrr/mirror).
// ---------------------------------------------------------------------

const MANGO_CANVAS_W: c_int = 620;
const MANGO_CANVAS_H: c_int = 280;
const MANGO_CANVAS_PAD: f64 = 0.1;

var g_mango_canvas: ?*hg.GtkDrawingArea = null;
var g_mango_selected: usize = 0; // index into monitor_rule lines list
var g_mango_caps: [8]mon.WlrCapsEntry = undefined;
var g_mango_caps_n: usize = 0;

var g_mdrag_idx: isize = -1;
var g_mdrag_anchor_x: i32 = 0;
var g_mdrag_anchor_y: i32 = 0;
var g_mdrag_fit_min_x: f64 = 0;
var g_mdrag_fit_min_y: f64 = 0;
var g_mdrag_fit_scale: f64 = 1;

// Edit-dialog dropdown storage (one dialog at a time).
var g_mdlg_res_bufs: [mon.MAX_RES][16:0]u8 = undefined;
var g_mdlg_res_ptrs: [mon.MAX_RES][*:0]const u8 = undefined;
var g_mdlg_hz_bufs: [mon.MAX_HZ][16:0]u8 = undefined;
var g_mdlg_hz_ptrs: [mon.MAX_HZ][*:0]const u8 = undefined;
// The doc line the open dialog edits (dropdown callbacks need it; the
// generic DlgCtx is not used for monitor rules).
var g_mdlg_line: usize = 0;

fn queueMangoCanvasDraw() void {
    if (g_mango_canvas) |c| hg.gtk_widget_queue_draw(@ptrCast(c));
}

fn findMonitorRuleLine(name: []const u8) ?usize {
    for (doc_monitors.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (!std.mem.eql(u8, kv.key, "monitor_rule")) continue;
        var it = std.mem.splitScalar(u8, kv.value, ',');
        while (it.next()) |raw| {
            const p = std.mem.trim(u8, raw, " \t");
            const c = std.mem.indexOfScalar(u8, p, ':') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, p[0..c], " \t"), "name") and
                std.mem.eql(u8, std.mem.trim(u8, p[c + 1 ..], " \t"), name)) return i;
        }
    }
    return null;
}

/// Geometry keys rewritten from detection (see desk.composeMangoRule).
/// Everything else on the line is preserved verbatim — except refresh,
/// kept from the old line only when detection has nothing newer to say.

fn onMonitorsDetectClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (desk.detectMango() == 0) return;
    refreshMangoCaps();
    for (desk.detectedMonitors()) |*d| {
        if (d.name().len == 0 or d.width == 0 or d.height == 0) continue;
        const li = findMonitorRuleLine(d.name());
        var old: ?[]const u8 = null;
        if (li) |idx| {
            if (mango.parseKV(doc_monitors.line(idx))) |kv| old = kv.value;
        }
        var vbuf: [mango.MAX_LINE]u8 = undefined;
        const line = desk.composeMangoRule(d.name(), d.width, d.height, d.refresh, d.x, d.y, old, li == null, &vbuf);
        if (li) |idx| doc_monitors.setLine(idx, line) else doc_monitors.appendLine(line);
    }
    _ = doc_monitors.save();
    reload();
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

// --- Caps (full wlr-randr mode list) ---

fn refreshMangoCaps() void {
    g_mango_caps_n = 0;
    const out = hypr.captureOutput(&.{ "wlr-randr" }, 3000) orelse return;
    defer gpa.free(out);
    g_mango_caps_n = mon.parseWlrRandrCaps(out, &g_mango_caps);
}

fn mangoCapsFor(name: []const u8) ?*const mon.OutputCaps {
    if (name.len == 0) return null;
    var i: usize = 0;
    while (i < g_mango_caps_n) : (i += 1) {
        if (std.mem.eql(u8, g_mango_caps[i].name(), name)) return &g_mango_caps[i].caps;
    }
    return null;
}

// --- Rule value helpers ---

fn ruleField(value: []const u8, key: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        const c = std.mem.indexOfScalar(u8, p, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, p[0..c], " \t"), key)) {
            return std.mem.trim(u8, p[c + 1 ..], " \t");
        }
    }
    return "";
}

fn ruleInt(value: []const u8, key: []const u8, fallback: i32) i32 {
    const s = ruleField(value, key);
    if (s.len == 0) return fallback;
    return std.fmt.parseInt(i32, s, 10) catch fallback;
}

/// Collects doc line indices for every monitor_rule. Returns count.
fn mangoMonitorLines(out: []usize) usize {
    var n: usize = 0;
    for (doc_monitors.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (!std.mem.eql(u8, kv.key, "monitor_rule")) continue;
        if (n < out.len) {
            out[n] = i;
            n += 1;
        }
    }
    return n;
}

fn mangoRects(rects: []mon.ArrangeRect, line_idxs: []const usize) usize {
    var n: usize = 0;
    for (line_idxs, 0..) |li, k| {
        if (k >= rects.len) break;
        const kv = mango.parseKV(doc_monitors.line(li)) orelse continue;
        const w = ruleInt(kv.value, "width", 1920);
        const h = ruleInt(kv.value, "height", 1080);
        const x = ruleInt(kv.value, "x", 0);
        const y = ruleInt(kv.value, "y", 0);
        const scale_s = ruleField(kv.value, "scale");
        const ss: []const u8 = if (scale_s.len != 0) scale_s else "1";
        var lw: i32 = 0;
        var lh: i32 = 0;
        mon.logicalExtents(w, h, ss, 0, &lw, &lh);
        rects[k] = .{ .x = x, .y = y, .w = lw, .h = lh };
        n += 1;
    }
    return n;
}

fn mangoRuleName(line_idx: usize, buf: []u8) []const u8 {
    const kv = mango.parseKV(doc_monitors.line(line_idx)) orelse return "";
    const nm = ruleField(kv.value, "name");
    const n = @min(nm.len, buf.len);
    @memcpy(buf[0..n], nm[0..n]);
    return buf[0..n];
}

/// Rewrites x/y for each monitor_rule, preserving every other pair
/// (width/height/refresh/scale/rr/vrr/mirror) via composeMangoRule.
fn writeMangoPositions(rects: []const mon.ArrangeRect, line_idxs: []const usize) void {
    for (rects, 0..) |r, k| {
        if (k >= line_idxs.len) break;
        const li = line_idxs[k];
        const kv = mango.parseKV(doc_monitors.line(li)) orelse continue;
        const nm = ruleField(kv.value, "name");
        if (nm.len == 0) continue;
        const w = ruleInt(kv.value, "width", 0);
        const h = ruleInt(kv.value, "height", 0);
        if (w == 0 or h == 0) continue;
        const rf = ruleField(kv.value, "refresh");
        const refresh: u32 = if (rf.len != 0) std.fmt.parseInt(u32, rf, 10) catch 0 else 0;
        var vbuf: [mango.MAX_LINE]u8 = undefined;
        const line = desk.composeMangoRule(nm, @intCast(w), @intCast(h), refresh, r.x, r.y, kv.value, false, &vbuf);
        doc_monitors.setLine(li, line);
    }
    _ = doc_monitors.save();
    reload();
}

/// Sets one key:value pair on a monitor_rule line, preserving the rest.
fn setMangoRuleField(line_idx: usize, key: []const u8, value: []const u8) void {
    const kv = mango.parseKV(doc_monitors.line(line_idx)) orelse return;
    var out: [mango.MAX_LINE]u8 = undefined;
    var n: usize = 0;
    const W = struct {
        fn s(buf: []u8, nn: *usize, t: []const u8) void {
            if (nn.* >= buf.len) return;
            const k = @min(t.len, buf.len - nn.*);
            @memcpy(buf[nn.*..][0..k], t[0..k]);
            nn.* += k;
        }
    };
    W.s(&out, &n, "monitor_rule = ");
    var first = true;
    var saw = false;
    var it = std.mem.splitScalar(u8, kv.value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        const c = std.mem.indexOfScalar(u8, p, ':');
        const pk: []const u8 = if (c) |cc| std.mem.trim(u8, p[0..cc], " \t") else p;
        if (std.mem.eql(u8, pk, key)) {
            saw = true;
            if (value.len == 0) continue;
            if (!first) W.s(&out, &n, ", ");
            first = false;
            W.s(&out, &n, key);
            W.s(&out, &n, ":");
            W.s(&out, &n, value);
        } else {
            if (!first) W.s(&out, &n, ", ");
            first = false;
            W.s(&out, &n, p);
        }
    }
    if (!saw and value.len != 0) {
        if (!first) W.s(&out, &n, ", ");
        W.s(&out, &n, key);
        W.s(&out, &n, ":");
        W.s(&out, &n, value);
    }
    doc_monitors.setLine(line_idx, out[0..n]);
    _ = doc_monitors.save();
}

// --- Canvas paint + interaction ---

fn onMangoCanvasDraw(_: *hg.GtkDrawingArea, cr: *hg.CairoT, w: c_int, h: c_int, _: ?*anyopaque) callconv(.c) void {
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    var rects: [8]mon.ArrangeRect = undefined;
    const n = mangoRects(&rects, line_idxs[0..m]);
    const cw: i32 = @intCast(w);
    const ch: i32 = @intCast(h);
    hg.cairo_set_source_rgb(cr, 0.11, 0.11, 0.14);
    hg.cairo_rectangle(cr, 0, 0, @floatFromInt(@max(1, cw)), @floatFromInt(@max(1, ch)));
    hg.cairo_fill(cr);
    if (n == 0) {
        hg.cairo_set_source_rgb(cr, 0.6, 0.6, 0.65);
        hg.cairo_select_font_face(cr, "monospace", 0, 0);
        hg.cairo_set_font_size(cr, 13);
        hg.cairo_move_to(cr, 16, 24);
        var msg: [128:0]u8 = undefined;
        const s = std.fmt.bufPrintZ(&msg, "No monitor rules — Add one or hit Auto-detect.", .{}) catch "No monitors.";
        hg.cairo_show_text(cr, s.ptr);
        return;
    }
    const fit = mon.computeCanvasFit(rects[0..n], cw, ch, MANGO_CANVAS_PAD);
    const sf = @max(fit.fit_scale, 1e-6);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = rects[i];
        if (r.w <= 0 or r.h <= 0) continue;
        const sx = (r.x - fit.min_x) * sf;
        const sy = (r.y - fit.min_y) * sf;
        const sw: f64 = @as(f64, @floatFromInt(r.w)) * sf;
        const sh: f64 = @as(f64, @floatFromInt(r.h)) * sf;
        if (i == g_mango_selected) {
            hg.cairo_set_source_rgba(cr, 0.28, 0.55, 0.95, 0.45);
        } else {
            hg.cairo_set_source_rgba(cr, 0.35, 0.38, 0.48, 0.55);
        }
        hg.cairo_rectangle(cr, sx, sy, @max(4, sw), @max(4, sh));
        hg.cairo_fill(cr);
        if (i == g_mango_selected) {
            hg.cairo_set_source_rgb(cr, 0.45, 0.7, 1.0);
        } else {
            hg.cairo_set_source_rgb(cr, 0.55, 0.58, 0.65);
        }
        hg.cairo_set_line_width(cr, if (i == g_mango_selected) 2.5 else 1.5);
        hg.cairo_rectangle(cr, sx, sy, @max(4, sw), @max(4, sh));
        hg.cairo_stroke(cr);
        hg.cairo_set_source_rgb(cr, 0.92, 0.92, 0.95);
        hg.cairo_select_font_face(cr, "monospace", 0, 0);
        hg.cairo_set_font_size(cr, 12);
        hg.cairo_move_to(cr, sx + 6, sy + 16);
        var nbuf: [64]u8 = undefined;
        const nm = mangoRuleName(line_idxs[i], &nbuf);
        var lbuf: [72:0]u8 = undefined;
        const zs = std.fmt.bufPrintZ(&lbuf, "{s}", .{if (nm.len != 0) nm else "???"}) catch "?";
        hg.cairo_show_text(cr, zs.ptr);
    }
}

fn mangoCanvasHit(px: f64, py: f64) isize {
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    var rects: [8]mon.ArrangeRect = undefined;
    const n = mangoRects(&rects, line_idxs[0..m]);
    if (n == 0) return -1;
    const fit = mon.computeCanvasFit(rects[0..n], MANGO_CANVAS_W, MANGO_CANVAS_H, MANGO_CANVAS_PAD);
    const sf = @max(fit.fit_scale, 1e-6);
    var i: isize = @intCast(n);
    while (i > 0) {
        i -= 1;
        const idx: usize = @intCast(i);
        const r = rects[idx];
        if (r.w <= 0 or r.h <= 0) continue;
        const sx = (r.x - fit.min_x) * sf;
        const sy = (r.y - fit.min_y) * sf;
        const sw: f64 = @as(f64, @floatFromInt(r.w)) * sf;
        const sh: f64 = @as(f64, @floatFromInt(r.h)) * sf;
        if (px >= sx and px < sx + sw and py >= sy and py < sy + sh) return i;
    }
    return -1;
}

fn onMangoCanvasPressed(_: *hg.GtkGestureClick, n_press: c_int, x: f64, y: f64, user_data: ?*anyopaque) callconv(.c) void {
    const hit = mangoCanvasHit(x, y);
    if (hit >= 0) {
        g_mango_selected = @intCast(hit);
        queueMangoCanvasDraw();
        if (n_press >= 2) {
            var line_idxs: [8]usize = undefined;
            const m = mangoMonitorLines(&line_idxs);
            if (@as(usize, @intCast(hit)) < m) {
                if (user_data) |parent| openMangoMonitorDialog(parent, line_idxs[@intCast(hit)]);
            }
        }
    }
}

fn onMangoDragBegin(_: *hg.GtkGestureDrag, x: f64, y: f64, _: ?*anyopaque) callconv(.c) void {
    const hit = mangoCanvasHit(x, y);
    g_mdrag_idx = hit;
    if (hit < 0) return;
    g_mango_selected = @intCast(hit);
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    var rects: [8]mon.ArrangeRect = undefined;
    const n = mangoRects(&rects, line_idxs[0..m]);
    const fit = mon.computeCanvasFit(rects[0..n], MANGO_CANVAS_W, MANGO_CANVAS_H, MANGO_CANVAS_PAD);
    g_mdrag_fit_min_x = fit.min_x;
    g_mdrag_fit_min_y = fit.min_y;
    g_mdrag_fit_scale = @max(fit.fit_scale, 1e-6);
    const idx: usize = @intCast(hit);
    if (idx < m) {
        const kv = mango.parseKV(doc_monitors.line(line_idxs[idx])) orelse return;
        g_mdrag_anchor_x = ruleInt(kv.value, "x", 0);
        g_mdrag_anchor_y = ruleInt(kv.value, "y", 0);
    }
    queueMangoCanvasDraw();
}

fn setMangoRuleFieldNoSave(line_idx: usize, key: []const u8, value: []const u8) void {
    const kv = mango.parseKV(doc_monitors.line(line_idx)) orelse return;
    var out: [mango.MAX_LINE]u8 = undefined;
    var n: usize = 0;
    const W = struct {
        fn s(buf: []u8, nn: *usize, t: []const u8) void {
            if (nn.* >= buf.len) return;
            const k = @min(t.len, buf.len - nn.*);
            @memcpy(buf[nn.*..][0..k], t[0..k]);
            nn.* += k;
        }
    };
    W.s(&out, &n, "monitor_rule = ");
    var first = true;
    var saw = false;
    var it = std.mem.splitScalar(u8, kv.value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        const c = std.mem.indexOfScalar(u8, p, ':');
        const pk: []const u8 = if (c) |cc| std.mem.trim(u8, p[0..cc], " \t") else p;
        if (std.mem.eql(u8, pk, key)) {
            saw = true;
            if (!first) W.s(&out, &n, ", ");
            first = false;
            W.s(&out, &n, key);
            W.s(&out, &n, ":");
            W.s(&out, &n, value);
        } else {
            if (!first) W.s(&out, &n, ", ");
            first = false;
            W.s(&out, &n, p);
        }
    }
    if (!saw) {
        if (!first) W.s(&out, &n, ", ");
        W.s(&out, &n, key);
        W.s(&out, &n, ":");
        W.s(&out, &n, value);
    }
    doc_monitors.setLine(line_idx, out[0..n]);
}

fn onMangoDragUpdate(gesture: *hg.GtkGestureDrag, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    if (g_mdrag_idx < 0) return;
    const idx: usize = @intCast(g_mdrag_idx);
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    if (idx >= m) return;
    var ox: f64 = 0;
    var oy: f64 = 0;
    hg.gtk_gesture_drag_get_offset(gesture, &ox, &oy);
    const inv = 1.0 / @max(g_mdrag_fit_scale, 1e-9);
    const nx: i32 = g_mdrag_anchor_x + @as(i32, @intFromFloat(@round(ox * inv)));
    const ny: i32 = g_mdrag_anchor_y + @as(i32, @intFromFloat(@round(oy * inv)));
    var xbuf: [16]u8 = undefined;
    var ybuf: [16]u8 = undefined;
    const xs = std.fmt.bufPrint(&xbuf, "{d}", .{nx}) catch return;
    const ys = std.fmt.bufPrint(&ybuf, "{d}", .{ny}) catch return;
    setMangoRuleFieldNoSave(line_idxs[idx], "x", xs);
    setMangoRuleFieldNoSave(line_idxs[idx], "y", ys);
    queueMangoCanvasDraw();
}

fn onMangoDragEnd(_: *hg.GtkGestureDrag, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    if (g_mdrag_idx < 0) return;
    const moved: usize = @intCast(g_mdrag_idx);
    g_mdrag_idx = -1;
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    var rects: [8]mon.ArrangeRect = undefined;
    const n = mangoRects(&rects, line_idxs[0..m]);
    const dis = [_]bool{false} ** 8;
    mon.finalizeDrag(rects[0..n], dis[0..n], moved);
    writeMangoPositions(rects[0..n], line_idxs[0..m]);
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

fn onMangoArrangeClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    var rects: [8]mon.ArrangeRect = undefined;
    const n = mangoRects(&rects, line_idxs[0..m]);
    if (n == 0) return;
    const dis = [_]bool{false} ** 8;
    mon.arrangeSideBySide(rects[0..n], dis[0..n]);
    writeMangoPositions(rects[0..n], line_idxs[0..m]);
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

fn onMangoAlignTopsClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    var rects: [8]mon.ArrangeRect = undefined;
    const n = mangoRects(&rects, line_idxs[0..m]);
    if (n == 0) return;
    const dis = [_]bool{false} ** 8;
    mon.alignTops(rects[0..n], dis[0..n]);
    var mn_y: i32 = std.math.maxInt(i32);
    for (rects[0..n]) |r| mn_y = @min(mn_y, r.y);
    if (mn_y != std.math.maxInt(i32)) {
        for (rects[0..n]) |*r| r.y -= mn_y;
    }
    writeMangoPositions(rects[0..n], line_idxs[0..m]);
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

fn onMangoCapsRefreshClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    refreshMangoCaps();
    queueMangoCanvasDraw();
}

// --- Capability-aware monitor_rule dialog ---

fn onMangoResChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(row);
    const kv = mango.parseKV(doc_monitors.line(g_mdlg_line)) orelse return;
    const nm = ruleField(kv.value, "name");
    const caps = mangoCapsFor(nm) orelse return;
    if (idx >= caps.n_res) return;
    const res = caps.resolution(idx);
    const x = std.mem.indexOfScalar(u8, res, 'x') orelse return;
    const ws = res[0..x];
    const hs = res[x + 1 ..];
    const list = caps.hzList(idx);
    if (list.len > 0) {
        var rib: [16]u8 = undefined;
        const ri = std.fmt.bufPrint(&rib, "{d}", .{@as(i32, @intFromFloat(@round(list[0])))}) catch return;
        setMangoRuleField(g_mdlg_line, "width", ws);
        setMangoRuleField(g_mdlg_line, "height", hs);
        setMangoRuleField(g_mdlg_line, "refresh", ri);
    } else {
        setMangoRuleField(g_mdlg_line, "width", ws);
        setMangoRuleField(g_mdlg_line, "height", hs);
    }
    reload();
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

fn onMangoHzChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx: usize = @intCast(gtk.adw_combo_row_get_selected(row));
    const kv = mango.parseKV(doc_monitors.line(g_mdlg_line)) orelse return;
    const nm = ruleField(kv.value, "name");
    const ws = ruleField(kv.value, "width");
    const hs = ruleField(kv.value, "height");
    const caps = mangoCapsFor(nm) orelse return;
    var ri: usize = 0;
    var found = false;
    var i: usize = 0;
    while (i < caps.n_res) : (i += 1) {
        const r = caps.resolution(i);
        const x = std.mem.indexOfScalar(u8, r, 'x') orelse continue;
        if (std.mem.eql(u8, r[0..x], ws) and std.mem.eql(u8, r[x + 1 ..], hs)) {
            ri = i;
            found = true;
            break;
        }
    }
    if (!found) return;
    const list = caps.hzList(ri);
    if (idx >= list.len) return;
    var rib: [16]u8 = undefined;
    const ri_s = std.fmt.bufPrint(&rib, "{d}", .{@as(i32, @intFromFloat(@round(list[idx])))}) catch return;
    setMangoRuleField(g_mdlg_line, "refresh", ri_s);
    reload();
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

fn onMangoCtxDialogClosed(_: *hg.AdwDialog, _: ?*anyopaque) callconv(.c) void {
    reload();
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

fn openMangoMonitorDialog(parent: *anyopaque, line: usize) void {
    if (line >= doc_monitors.lineCount()) return;
    const kv0 = mango.parseKV(doc_monitors.line(line)) orelse return;
    if (!std.mem.eql(u8, kv0.key, "monitor_rule")) {
        openRuleDialog(parent, &g_rp_monitors, line);
        return;
    }
    g_mdlg_line = line;
    const kv = mango.parseKV(doc_monitors.line(line)) orelse return;
    const nm = ruleField(kv.value, "name");
    const ws = ruleField(kv.value, "width");
    const hs = ruleField(kv.value, "height");
    const rf = ruleField(kv.value, "refresh");
    const xs = ruleField(kv.value, "x");
    const ys = ruleField(kv.value, "y");
    const ss = ruleField(kv.value, "scale");
    const rrs = ruleField(kv.value, "rr");
    const vrs = ruleField(kv.value, "vrr");
    const mir = ruleField(kv.value, "mirror");

    const content = hp.newDialogBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Monitor Rule");
    {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Name");
        const entry = gtk.gtk_entry_new();
        gtk.gtk_widget_set_size_request(@ptrCast(entry), 180, -1);
        gtk.gtk_widget_set_valign(@ptrCast(entry), gtk.ALIGN_CENTER);
        hp.setEntryZ(gtk.gtk_entry_get_buffer(entry), nm);
        _ = gtk.g_signal_connect_data(@ptrCast(gtk.gtk_entry_get_buffer(entry)), "notify::text", @ptrCast(&onMangoNameChanged), null, null, 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(entry));
        gtk.adw_preferences_group_add(group, @ptrCast(row));
    }
    const caps = mangoCapsFor(nm);
    if (caps != null and caps.?.n_res > 0) {
        const c = caps.?;
        var cur_res_buf: [32]u8 = undefined;
        const cur_res = std.fmt.bufPrint(&cur_res_buf, "{s}x{s}", .{ ws, hs }) catch "";
        var ri = c.findResolution(cur_res) orelse 0;
        if (ri >= c.n_res) ri = 0;
        var rn: usize = 0;
        while (rn < c.n_res and rn < mon.MAX_RES) : (rn += 1) {
            const s = c.resolution(rn);
            const n = @min(s.len, 15);
            @memcpy(g_mdlg_res_bufs[rn][0..n], s[0..n]);
            g_mdlg_res_bufs[rn][n] = 0;
            g_mdlg_res_ptrs[rn] = g_mdlg_res_bufs[rn][0..n :0];
        }
        hp.addComboRow(group, "Resolution", g_mdlg_res_ptrs[0..rn], @intCast(ri), @ptrCast(&onMangoResChanged), null);
        const list = c.hzList(ri);
        var hn: usize = 0;
        var sel: usize = 0;
        for (list, 0..) |hz, hi| {
            if (hn >= mon.MAX_HZ) break;
            var hzb: [16]u8 = undefined;
            const s = mon.formatHz(hz, &hzb);
            const n = @min(s.len, 15);
            @memcpy(g_mdlg_hz_bufs[hn][0..n], s[0..n]);
            g_mdlg_hz_bufs[hn][n] = 0;
            g_mdlg_hz_ptrs[hn] = g_mdlg_hz_bufs[hn][0..n :0];
            const rounded: i32 = @intFromFloat(@round(hz));
            var rib: [16]u8 = undefined;
            const rs = std.fmt.bufPrint(&rib, "{d}", .{rounded}) catch "";
            if (std.mem.eql(u8, rs, rf)) sel = hn;
            hn += 1;
            _ = hi;
        }
        if (hn > 0) {
            hp.addComboRow(group, "Refresh Rate", g_mdlg_hz_ptrs[0..hn], @intCast(sel), @ptrCast(&onMangoHzChanged), null);
        }
    }
    addMangoField(group, "Width", ws, "width", 100);
    addMangoField(group, "Height", hs, "height", 100);
    addMangoField(group, "Refresh", rf, "refresh", 100);
    addMangoField(group, "X", xs, "x", 100);
    addMangoField(group, "Y", ys, "y", 100);
    addMangoField(group, "Scale", ss, "scale", 100);
    addMangoField(group, "RR", rrs, "rr", 100);
    addMangoField(group, "VRR", vrs, "vrr", 100);
    addMangoField(group, "Mirror", mir, "mirror", 160);
    gtk.gtk_box_append(content, @ptrCast(group));
    const d = hg.adw_dialog_new();
    hg.adw_dialog_set_title(d, "Edit Monitor Rule");
    hg.adw_dialog_set_content_width(d, 600);
    hg.adw_dialog_set_child(d, @ptrCast(content));
    _ = gtk.g_signal_connect_data(@ptrCast(d), "closed", @ptrCast(&onMangoCtxDialogClosed), null, null, 0);
    hp.addDialogFooter(content, d);
    hg.adw_dialog_present(d, parent);
}

const MangoFieldCtx = struct { key: []const u8 };
var g_mango_field_ctx: [16]MangoFieldCtx = undefined;
var g_mango_field_n: usize = 0;

fn onMangoFieldChanged(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *MangoFieldCtx = @ptrCast(@alignCast(user_data.?));
    setMangoRuleField(g_mdlg_line, ctx.key, std.mem.span(gtk.gtk_entry_buffer_get_text(buffer)));
}

fn onMangoNameChanged(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    setMangoRuleField(g_mdlg_line, "name", std.mem.span(gtk.gtk_entry_buffer_get_text(buffer)));
}

fn addMangoField(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, initial: []const u8, key: []const u8, width: c_int) void {
    if (g_mango_field_n >= g_mango_field_ctx.len) g_mango_field_n = 0;
    const ctx = &g_mango_field_ctx[g_mango_field_n];
    g_mango_field_n += 1;
    ctx.* = .{ .key = key };
    hp.addEntryRow(group, title, initial, width, @ptrCast(&onMangoFieldChanged), @ptrCast(ctx));
}

// ---------------------------------------------------------------------
// Keybinds page
// ---------------------------------------------------------------------

var g_keybinds_list: ?*gtk.GtkListBox = null;

fn isBindKey(k: []const u8) bool {
    return std.mem.eql(u8, k, "bind") or std.mem.eql(u8, k, "mousebind") or
        std.mem.eql(u8, k, "axisbind") or std.mem.eql(u8, k, "gesturebind");
}

fn parseBind(v: []const u8, mods: *[]const u8, key: *[]const u8, action: *[]const u8, args: *[]const u8) void {
    var parts = [_][]const u8{ "", "", "", "" };
    var idx: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < v.len and idx < 4) : (i += 1) {
        if (v[i] == ',') {
            if (idx < 3) {
                parts[idx] = std.mem.trim(u8, v[start..i], " \t");
                idx += 1;
                start = i + 1;
            } else break;
        }
    }
    parts[idx] = std.mem.trim(u8, v[start..], " \t");
    mods.* = parts[0];
    key.* = parts[1];
    action.* = parts[2];
    args.* = parts[3];
}

fn openBindDialog(parent: *anyopaque, line: usize) void {
    if (line >= doc_keybinds.lineCount()) return;
    const kv = mango.parseKV(doc_keybinds.line(line)) orelse return;
    const is_bind = std.mem.eql(u8, kv.key, "bind");
    // Use a static key: kv.key points into the doc line, which setLine()
    // replaces (and frees) on the first edit, so a stored slice would dangle.
    const bkey: []const u8 = if (std.mem.eql(u8, kv.key, "mousebind"))
        "mousebind"
    else if (std.mem.eql(u8, kv.key, "axisbind"))
        "axisbind"
    else if (std.mem.eql(u8, kv.key, "gesturebind"))
        "gesturebind"
    else
        "bind";

    g_dlg = .{ .kind = if (is_bind) .bind else .raw, .doc = &doc_keybinds, .key = bkey, .line = line };

    const content = hp.newDialogBox();
    const group = gtk.adw_preferences_group_new();
    if (is_bind) {
        var m: []const u8 = "";
        var k: []const u8 = "";
        var a: []const u8 = "";
        var ar: []const u8 = "";
        parseBind(kv.value, &m, &k, &a, &ar);
        const titles = [_][:0]const u8{ "Modifiers", "Key", "Action", "Arguments" };
        const inits = [_][]const u8{ m, k, a, ar };
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            g_dlg.entries[i] = addEntryRowRet(group, titles[i], inits[i], 220, @ptrCast(&onDlgEntryChanged), @ptrCast(&g_dlg));
        }
        g_dlg.nfields = 4;
    } else {
        g_dlg.entries[0] = addEntryRowRet(group, "Value", kv.value, 360, @ptrCast(&onDlgEntryChanged), @ptrCast(&g_dlg));
        g_dlg.nfields = 1;
    }
    gtk.gtk_box_append(content, @ptrCast(group));
    presentCtxDialog(parent, "Edit Keybind", content);
}

fn onBindEdit(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    openBindDialog(@ptrCast(button), @intFromPtr(user_data.?) - 1);
}

fn onBindRemove(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    doc_keybinds.removeLine(@intFromPtr(user_data.?) - 1);
    _ = doc_keybinds.save();
    reload();
    rebuildKeybindsList();
}

fn onBindAdd(button: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    doc_keybinds.appendLine("bind = SUPER, q, killclient");
    _ = doc_keybinds.save();
    reload();
    rebuildKeybindsList();
    openBindDialog(@ptrCast(button), doc_keybinds.lineCount() - 1);
}

fn rebuildKeybindsList() void {
    const listbox = g_keybinds_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (doc_keybinds.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (!isBindKey(kv.key)) continue;

        const row = gtk.adw_action_row_new();
        var tb: [hp.MAX_TITLE]u8 = undefined;
        if (std.mem.eql(u8, kv.key, "bind")) {
            var m: []const u8 = "";
            var k: []const u8 = "";
            var a: []const u8 = "";
            var ar: []const u8 = "";
            parseBind(kv.value, &m, &k, &a, &ar);
            gtk.adw_preferences_row_set_title(@ptrCast(row), hp.fmtZ(&tb, "{s} + {s}", .{ m, k }));
            var raw_sub: [hp.MAX_ZBUF]u8 = undefined;
            const rs = std.fmt.bufPrint(&raw_sub, "{s} {s}", .{ a, ar }) catch "";
            var esc: [hp.MAX_ZBUF * 6]u8 = undefined;
            gtk.adw_action_row_set_subtitle(row, escapeZ(rs, &esc));
        } else {
            gtk.adw_preferences_row_set_title(@ptrCast(row), escapeZ(kv.key, &tb));
            var esc: [hp.MAX_ZBUF * 6]u8 = undefined;
            gtk.adw_action_row_set_subtitle(row, escapeZ(kv.value, &esc));
        }
        addRowButtonEx(row, "Edit", @ptrCast(&onBindEdit), @ptrFromInt(i + 1), null);
        addRowButtonEx(row, "Remove", @ptrCast(&onBindRemove), @ptrFromInt(i + 1), null);
        gtk.gtk_list_box_append(listbox, @ptrCast(row));
    }
}

// ---------------------------------------------------------------------
// Autostart page
// ---------------------------------------------------------------------

var g_autostart_list: ?*gtk.GtkListBox = null;

const AutoCtx = struct { doc: *mango.Doc, key: []const u8, line: usize };
var g_auto_ctx: [1024]AutoCtx = undefined;
var g_auto_n: usize = 0;

fn onAutoChanged(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *AutoCtx = @ptrCast(@alignCast(user_data.?));
    var lb: [mango.MAX_LINE]u8 = undefined;
    const line = std.fmt.bufPrint(&lb, "{s} = {s}", .{ ctx.key, std.mem.span(gtk.gtk_entry_buffer_get_text(buffer)) }) catch return;
    ctx.doc.setLine(ctx.line, line);
    _ = ctx.doc.save();
}

fn onAutoRemove(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    doc_autostart.removeLine(@intFromPtr(user_data.?) - 1);
    _ = doc_autostart.save();
    reload();
    rebuildAutostartList();
}

fn addAutostartRow(listbox: *gtk.GtkListBox, key: []const u8, line: usize) void {
    const kv = mango.parseKV(doc_autostart.line(line)) orelse return;
    const is_exec = std.mem.eql(u8, key, "exec");
    // Static key (see openBindDialog): the doc line is rewritten on edit.
    const skey: []const u8 = if (is_exec) "exec" else "exec_once";
    if (g_auto_n >= g_auto_ctx.len) g_auto_n = 0;
    const ctx = &g_auto_ctx[g_auto_n];
    g_auto_n += 1;
    ctx.* = .{ .doc = &doc_autostart, .key = skey, .line = line };

    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), if (is_exec) "Startup Command (exec)" else "Startup Command (exec_once)");
    const entry = gtk.gtk_entry_new();
    gtk.gtk_widget_set_size_request(@ptrCast(entry), 360, -1);
    gtk.gtk_widget_set_valign(@ptrCast(entry), gtk.ALIGN_CENTER);
    const buffer = gtk.gtk_entry_get_buffer(entry);
    hp.setEntryZ(buffer, kv.value);
    _ = gtk.g_signal_connect_data(@ptrCast(buffer), "notify::text", @ptrCast(&onAutoChanged), @ptrCast(ctx), null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(entry));
    hp.addRowButton(row, "Remove", @ptrCast(&onAutoRemove), @ptrFromInt(line + 1));
    gtk.gtk_list_box_append(listbox, @ptrCast(row));
}

fn rebuildAutostartList() void {
    const listbox = g_autostart_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (doc_autostart.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (std.mem.eql(u8, kv.key, "exec_once") or std.mem.eql(u8, kv.key, "exec")) {
            addAutostartRow(listbox, kv.key, i);
        }
    }
}

fn onAutostartAdd(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    doc_autostart.appendLine("exec_once = ");
    _ = doc_autostart.save();
    rebuildAutostartList();
}

fn buildAutostartPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Autostart");
    gtk.adw_preferences_group_set_description(group, "exec_once runs once at startup; exec runs every reload. Both are read from ~/.config/mango/cfg/autostart.conf.");
    gtk.gtk_box_append(outer, @ptrCast(group));

    g_autostart_list = hp.newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_autostart_list.?));
    rebuildAutostartList();
    hp.appendActionButton(outer, "Add Startup Command", @ptrCast(&onAutostartAdd), null);
    return outer;
}

// ---------------------------------------------------------------------
// Environment page
// ---------------------------------------------------------------------

var g_env_list: ?*gtk.GtkListBox = null;

const EnvCtx = struct { doc: *mango.Doc, line: usize, name: *gtk.GtkEntry, value: *gtk.GtkEntry };
var g_env_ctx: [1024]EnvCtx = undefined;
var g_env_n: usize = 0;

fn onEnvChanged(_: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *EnvCtx = @ptrCast(@alignCast(user_data.?));
    var lb: [mango.MAX_LINE]u8 = undefined;
    const line = std.fmt.bufPrint(&lb, "env = {s},{s}", .{ hp.entryText(ctx.name), hp.entryText(ctx.value) }) catch return;
    ctx.doc.setLine(ctx.line, line);
    _ = ctx.doc.save();
}

fn onEnvRemove(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    doc_env.removeLine(@intFromPtr(user_data.?) - 1);
    _ = doc_env.save();
    reload();
    rebuildEnvList();
}

fn addEnvRow(listbox: *gtk.GtkListBox, line: usize) void {
    const kv = mango.parseKV(doc_env.line(line)) orelse return;

    var nm = kv.value;
    var vl: []const u8 = "";
    if (std.mem.indexOfScalar(u8, kv.value, ',')) |c| {
        nm = kv.value[0..c];
        vl = kv.value[c + 1 ..];
    }
    nm = std.mem.trim(u8, nm, " \t");
    vl = std.mem.trim(u8, vl, " \t");

    if (g_env_n >= g_env_ctx.len) g_env_n = 0;
    const ctx = &g_env_ctx[g_env_n];
    g_env_n += 1;

    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Variable");

    const name_entry = gtk.gtk_entry_new();
    gtk.gtk_widget_set_size_request(@ptrCast(name_entry), 180, -1);
    gtk.gtk_widget_set_valign(@ptrCast(name_entry), gtk.ALIGN_CENTER);
    hp.setEntryZ(gtk.gtk_entry_get_buffer(name_entry), nm);

    const value_entry = gtk.gtk_entry_new();
    gtk.gtk_widget_set_size_request(@ptrCast(value_entry), 260, -1);
    gtk.gtk_widget_set_valign(@ptrCast(value_entry), gtk.ALIGN_CENTER);
    hp.setEntryZ(gtk.gtk_entry_get_buffer(value_entry), vl);

    ctx.* = .{ .doc = &doc_env, .line = line, .name = name_entry, .value = value_entry };
    _ = gtk.g_signal_connect_data(@ptrCast(gtk.gtk_entry_get_buffer(name_entry)), "notify::text", @ptrCast(&onEnvChanged), @ptrCast(ctx), null, 0);
    _ = gtk.g_signal_connect_data(@ptrCast(gtk.gtk_entry_get_buffer(value_entry)), "notify::text", @ptrCast(&onEnvChanged), @ptrCast(ctx), null, 0);

    gtk.adw_action_row_add_suffix(row, @ptrCast(name_entry));
    gtk.adw_action_row_add_suffix(row, @ptrCast(value_entry));
    hp.addRowButton(row, "Remove", @ptrCast(&onEnvRemove), @ptrFromInt(line + 1));
    gtk.gtk_list_box_append(listbox, @ptrCast(row));
}

fn rebuildEnvList() void {
    const listbox = g_env_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (doc_env.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (std.mem.eql(u8, kv.key, "env")) addEnvRow(listbox, i);
    }
}

fn onEnvAdd(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    doc_env.appendLine("env = VARIABLE,");
    _ = doc_env.save();
    rebuildEnvList();
}

fn buildEnvPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Environment Variables");
    gtk.adw_preferences_group_set_description(group, "env = NAME,VALUE entries from env.conf. Values replace the inherited variable and are re-applied on every reload.");
    gtk.gtk_box_append(outer, @ptrCast(group));

    g_env_list = hp.newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_env_list.?));
    rebuildEnvList();
    hp.appendActionButton(outer, "Add Environment Variable", @ptrCast(&onEnvAdd), null);
    return outer;
}

// ---------------------------------------------------------------------
// Cursor + GTK theme (General page). Cursor theme comes from a dropdown of
// real cursor directories (~/.cursors first, then ~/.icons and the XDG /
// system icon dirs) instead of free text; the size spin additionally pushes
// the size through gsettings. GTK theme is desktop-global (gsettings +
// settings.ini) with no appearance.conf key, so it gets a plain combo row.
// ---------------------------------------------------------------------

fn onMangoCursorThemeChanged(row: *gtk.AdwComboRow, pspec: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    onFieldCombo(row, pspec, user_data);
    const idx = gtk.adw_combo_row_get_selected(row);
    const vals = desk.cursorValues();
    if (idx >= vals.len) return;
    desk.applyCursorTheme(vals[idx]);
}

fn onMangoCursorSizeChanged(spin: *gtk.GtkSpinButton, user_data: ?*anyopaque) callconv(.c) void {
    onFieldSpin(spin, user_data);
    desk.applyCursorSize(@intCast(gtk.gtk_spin_button_get_value_as_int(spin)));
}

fn onMangoGtkThemeChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(row);
    const vals = desk.gtkValues();
    if (idx >= vals.len) return;
    desk.applyGtkTheme(vals[idx]);
}

fn buildCursorGroup(outer: *gtk.GtkBox) void {
    desk.discoverCursors();
    const cur = doc_appearance.value("cursor_theme") orelse "";
    desk.ensureCursorPresent(cur);
    const cursor = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(cursor, "Cursor");
    gtk.adw_preferences_group_set_description(cursor, "Cursor theme and size (appearance.conf). Drop themes into ~/.cursors to list them here.");
    if (desk.cursorValues().len == 0) {
        addEntryField(cursor, "Cursor Theme", &doc_appearance, "cursor_theme", "", 160);
    } else {
        addComboFieldCb(cursor, "Cursor Theme", desk.cursorLabels(), desk.cursorValues(), &doc_appearance, "cursor_theme", cur, @ptrCast(&onMangoCursorThemeChanged));
    }
    addSpinFieldCb(cursor, "Cursor Size (px)", 8, 128, 1, &doc_appearance, "cursor_size", 24, false, @ptrCast(&onMangoCursorSizeChanged));
    gtk.gtk_box_append(outer, @ptrCast(cursor));
}

fn buildMangoGtkThemeGroup(outer: *gtk.GtkBox) void {
    desk.discoverGtkThemes();
    var cbuf: [desk.MAX_NAME]u8 = undefined;
    const cur = desk.currentGtkThemeBuf(&cbuf);
    desk.ensureGtkPresent(cur);
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "GTK Theme");
    gtk.adw_preferences_group_set_description(group, "Theme for GTK apps (gsettings + settings.ini). Drop themes into ~/.themes to list them here.");
    const vals = desk.gtkValues();
    if (vals.len == 0) {
        gtk.gtk_box_append(outer, @ptrCast(group));
        return;
    }
    var sel: c_uint = 0;
    for (vals, 0..) |v, i| {
        if (std.mem.eql(u8, cur, v)) {
            sel = @intCast(i);
            break;
        }
    }
    hp.addComboRow(group, "GTK Theme", desk.gtkLabels(), sel, @ptrCast(&onMangoGtkThemeChanged), null);
    gtk.gtk_box_append(outer, @ptrCast(group));
}

// ---------------------------------------------------------------------
// Option tables. Every scalar Mango setting the pages offer is one Opt:
// which cfg file it lives in, its key, and Mango's own default (what the
// row shows while the key is absent). The pages below are built from
// these tables, and `dumpDefaults` prints them back as a config so the
// install rehearsal can check every key against the Mango that ships
// (`mango -p`): no row here can write a key Mango doesn't know.
// Titles and subtitles are Pango markup: no ampersands or angle brackets.
// ---------------------------------------------------------------------

const DocId = enum { appearance, input, layout, misc };

fn docOf(id: DocId) *mango.Doc {
    return switch (id) {
        .appearance => &doc_appearance,
        .input => &doc_input,
        .layout => &doc_layout,
        .misc => &doc_misc,
    };
}

const Kind = enum { toggle, int, float, text, combo, color };

const Opt = struct {
    kind: Kind,
    doc: DocId,
    key: []const u8,
    title: [:0]const u8,
    sub: [:0]const u8 = "",
    on: bool = false,
    num: f64 = 0,
    min: f64 = 0,
    max: f64 = 1,
    step: f64 = 1,
    text: []const u8 = "",
    labels: []const [*:0]const u8 = &.{},
    values: []const []const u8 = &.{},
    width: c_int = 180,
};

fn oTg(doc: DocId, key: []const u8, on: bool, title: [:0]const u8, sub: [:0]const u8) Opt {
    return .{ .kind = .toggle, .doc = doc, .key = key, .title = title, .sub = sub, .on = on };
}
fn oNum(doc: DocId, key: []const u8, def: f64, min: f64, max: f64, step: f64, title: [:0]const u8, sub: [:0]const u8) Opt {
    return .{ .kind = .int, .doc = doc, .key = key, .title = title, .sub = sub, .num = def, .min = min, .max = max, .step = step };
}
fn oFlt(doc: DocId, key: []const u8, def: f64, min: f64, max: f64, step: f64, title: [:0]const u8, sub: [:0]const u8) Opt {
    return .{ .kind = .float, .doc = doc, .key = key, .title = title, .sub = sub, .num = def, .min = min, .max = max, .step = step };
}
fn oTxt(doc: DocId, key: []const u8, def: []const u8, width: c_int, title: [:0]const u8, sub: [:0]const u8) Opt {
    return .{ .kind = .text, .doc = doc, .key = key, .title = title, .sub = sub, .text = def, .width = width };
}
fn oCmb(doc: DocId, key: []const u8, def: []const u8, labels: []const [*:0]const u8, values: []const []const u8, title: [:0]const u8, sub: [:0]const u8) Opt {
    return .{ .kind = .combo, .doc = doc, .key = key, .title = title, .sub = sub, .text = def, .labels = labels, .values = values };
}
fn oCol(doc: DocId, key: []const u8, def: []const u8, title: [:0]const u8) Opt {
    return .{ .kind = .color, .doc = doc, .key = key, .title = title, .text = def };
}

const Group = struct { title: [:0]const u8, desc: [:0]const u8 = "", opts: []const Opt };

const RELOGIN = " Applies the next time you log in.";

const ACCEL_LABELS = [_][*:0]const u8{ "None", "Flat", "Adaptive" };
const ACCEL_VALUES = [_][]const u8{ "0", "1", "2" };
const SCROLL_LABELS = [_][*:0]const u8{ "Two fingers", "Edge", "Button held" };
const SCROLL_VALUES = [_][]const u8{ "1", "2", "4" };
const CLICK_LABELS = [_][*:0]const u8{ "Button areas", "Clickfinger" };
const CLICK_VALUES = [_][]const u8{ "1", "2" };
const HSPLIT_LABELS = [_][*:0]const u8{ "Follow the cursor", "Right", "Left" };
const VSPLIT_LABELS = [_][*:0]const u8{ "Follow the cursor", "Below", "Above" };
const SPLIT_VALUES = [_][]const u8{ "0", "1", "2" };
const CORNER_LABELS = [_][*:0]const u8{ "Top left", "Top right", "Bottom left", "Bottom right" };
const CORNER_VALUES = [_][]const u8{ "0", "1", "2", "3" };
const TEAR_LABELS = [_][*:0]const u8{ "Off", "On", "Fullscreen windows only" };
const TEAR_VALUES = [_][]const u8{ "0", "1", "2" };

// -- General ----------------------------------------------------------

const G_GENERAL = [_]Group{
    .{ .title = "Window gaps", .desc = "Inner spacing is between tiles; outer is the screen edge.", .opts = &.{
        oNum(.appearance, "gap_inner_horizontal", 5, 0, 128, 1, "Inner gap, side to side (px)", ""),
        oNum(.appearance, "gap_inner_vertical", 5, 0, 128, 1, "Inner gap, top to bottom (px)", ""),
        oNum(.appearance, "gap_outer_horizontal", 10, 0, 128, 1, "Outer gap, left and right (px)", ""),
        oNum(.appearance, "gap_outer_vertical", 10, 0, 128, 1, "Outer gap, top and bottom (px)", ""),
        oTg(.layout, "smart_gaps", false, "No gaps for a single window", "A window alone on its workspace fills the whole area."),
    } },
    .{ .title = "Workspaces", .opts = &.{
        oNum(.misc, "tag_num", 9, 1, 31, 1, "Number of workspaces", "Windows on workspaces past this number move to the last one."),
        oTg(.misc, "tag_carousel", false, "Wrap around", "Going past the last workspace comes back to the first."),
        oTg(.misc, "tag_gather", false, "Keep workspaces consecutive", "Used workspaces close up so there are no empty ones between them."),
        oTg(.misc, "view_current_to_back", false, "Press again to go back", "Choosing the workspace you are on returns to the previous one."),
    } },
    .{ .title = "Focus", .opts = &.{
        oTg(.misc, "sloppy_focus", true, "Focus follows the pointer", "The window under the pointer gets keyboard focus without a click."),
        oTg(.misc, "focus_on_activate", true, "Let apps ask for focus", "A window that requests attention, such as a link opening in your browser, is focused."),
        oTg(.misc, "focus_cross_monitor", false, "Directional focus crosses monitors", ""),
        oTg(.misc, "focus_cross_tag", false, "Directional focus crosses workspaces", ""),
    } },
};

// -- Decoration -------------------------------------------------------

const G_DECOR_TOP = [_]Group{
    .{ .title = "Borders and corners", .opts = &.{
        oNum(.appearance, "border_px", 4, 0, 32, 1, "Border width (px)", ""),
        oNum(.appearance, "border_radius", 12, 0, 64, 1, "Corner radius (px)", "12 matches Perihelion's frosted app windows."),
        oTg(.misc, "no_border_when_single", false, "No border for a single window", ""),
        oTg(.appearance, "no_radius_when_single", false, "Square corners for a single window", ""),
    } },
    .{ .title = "Opacity", .desc = "Whole-window opacity, text included. For frosted windows with sharp text use Window glass on the Appearance page instead.", .opts = &.{
        oFlt(.appearance, "focused_opacity", 1.0, 0.1, 1.0, 0.05, "Focused window", ""),
        oFlt(.appearance, "unfocused_opacity", 1.0, 0.1, 1.0, 0.05, "Other windows", ""),
    } },
};

const BLUR_HEAD = [_]Opt{
    oTg(.appearance, "blur", false, "Blur behind windows", ""),
    oTg(.appearance, "blur_layer", false, "Blur behind panels", "The bar, dock, app drawer and widgets."),
};
const BLUR_TAIL = [_]Opt{
    oNum(.appearance, "blur_params_radius", 5, 1, 32, 1, "Radius", "How far each pass samples. Small values over several passes stay clean."),
    oNum(.appearance, "blur_params_num_passes", 1, 1, 8, 1, "Passes", "More passes are smoother."),
    oFlt(.appearance, "blur_params_noise", 0.02, 0.0, 1.0, 0.01, "Noise", "A trace hides banding in smooth gradients; more looks grainy."),
    oFlt(.appearance, "blur_params_brightness", 0.9, 0.0, 2.0, 0.01, "Brightness", ""),
    oFlt(.appearance, "blur_params_contrast", 0.9, 0.0, 2.0, 0.01, "Contrast", ""),
    oFlt(.appearance, "blur_params_saturation", 1.2, 0.0, 2.0, 0.01, "Saturation", ""),
};

const G_DECOR_BOTTOM = [_]Group{
    .{ .title = "Shadows", .opts = &.{
        oTg(.appearance, "shadows", false, "Window shadows", ""),
        oTg(.appearance, "shadow_only_floating", true, "Only under floating windows", "Tiled windows sit edge to edge, where a shadow only costs performance."),
        oTg(.appearance, "layer_shadows", false, "Shadows under panels", "Perihelion's glass bar and dock look cleanest without."),
        oNum(.appearance, "shadows_size", 10, 0, 100, 1, "Size (px)", ""),
        oNum(.appearance, "shadows_blur", 15, 0, 100, 1, "Softness (px)", ""),
        oNum(.appearance, "shadows_position_x", 0, -100, 100, 1, "Offset, sideways (px)", ""),
        oNum(.appearance, "shadows_position_y", 0, -100, 100, 1, "Offset, downwards (px)", ""),
        oCol(.appearance, "shadows_color", "0x000000ff", "Color"),
    } },
    .{ .title = "Dimming", .opts = &.{
        oTg(.appearance, "dim_enable", false, "Dim windows", "Lays a tint over windows; by default only the unfocused ones."),
        oCol(.appearance, "dim_focused_color", "0x00000000", "Focused window"),
        oCol(.appearance, "dim_unfocused_color", "0x00000055", "Other windows"),
    } },
    .{ .title = "Colors", .desc = "Base colours in appearance.conf. The border colours follow the wallpaper: perihelion-theme writes ~/.config/mango/colors.conf, which config.conf reads last, so those win over the values here.", .opts = &.{
        oCol(.appearance, "root_color", "0x201b14ff", "Root background"),
        oCol(.appearance, "border_color", "0x444444ff", "Border"),
        oCol(.appearance, "focus_color", "0x47add6ff", "Focused border"),
        oCol(.appearance, "maximized_screen_color", "0x47add6ff", "Maximized"),
        oCol(.appearance, "urgent_color", "0xad401fff", "Urgent"),
        oCol(.appearance, "scratchpad_color", "0x516c93ff", "Scratchpad"),
        oCol(.appearance, "global_color", "0xb153a7ff", "Global"),
        oCol(.appearance, "overlay_color", "0x14a57cff", "Overlay"),
    } },
};

// -- Keyboards --------------------------------------------------------

const G_KEYBOARD = [_]Group{
    .{ .title = "Layout", .desc = "XKB names, as in /usr/share/X11/xkb/rules/base.lst. Leave a field empty for the default.", .opts = &.{
        oTxt(.input, "xkb_rules_layout", "us", 180, "Layouts", "One code, or several separated by commas: us,de"),
        oTxt(.input, "xkb_rules_variant", "", 180, "Variant", "For example dvorak, colemak or intl."),
        oTxt(.input, "xkb_rules_options", "", 240, "Options", "For example caps:escape, or grp:alt_shift_toggle to switch layouts."),
        oTxt(.input, "xkb_rules_model", "", 180, "Model", "For example pc104. Usually left empty."),
    } },
    .{ .title = "Typing", .opts = &.{
        oNum(.input, "repeat_rate", 25, 1, 100, 1, "Repeat rate (per second)", ""),
        oNum(.input, "repeat_delay", 600, 100, 2000, 10, "Delay before repeating (ms)", ""),
        oTg(.input, "numlock_on", false, "Num Lock on at login", ""),
    } },
};

// -- Mouse and touchpad -----------------------------------------------

const G_POINTER = [_]Group{
    .{ .title = "Mouse", .opts = &.{
        oCmb(.input, "mouse_accel_profile", "2", &ACCEL_LABELS, &ACCEL_VALUES, "Acceleration", "Flat moves the pointer exactly as far as the mouse; Adaptive speeds up with fast movements."),
        oFlt(.input, "mouse_accel_speed", 0.0, -1.0, 1.0, 0.05, "Pointer speed", "From -1 (slowest) to 1 (fastest)."),
        oTg(.input, "mouse_natural_scrolling", false, "Natural scrolling", "The page follows the wheel, as on a phone."),
        oFlt(.input, "axis_scroll_factor", 1.0, 0.1, 10.0, 0.1, "Scroll speed", ""),
        oTg(.input, "mouse_left_handed", false, "Left-handed", "Swaps the left and right buttons."),
        oTg(.input, "mouse_middle_button_emulation", false, "Middle click by pressing both buttons", ""),
    } },
    .{ .title = "Touchpad", .opts = &.{
        oTg(.input, "disable_trackpad", false, "Turn the touchpad off", ""),
        oTg(.input, "tap_to_click", true, "Tap to click", ""),
        oTg(.input, "tap_and_drag", true, "Tap and drag", "Tap, then touch again and move to drag."),
        oTg(.input, "drag_lock", true, "Drag lock", "A drag carries on when you lift your finger briefly."),
        oTg(.input, "trackpad_natural_scrolling", false, "Natural scrolling", ""),
        oTg(.input, "trackpad_disable_while_typing", true, "Ignore the touchpad while typing", ""),
        oCmb(.input, "trackpad_accel_profile", "2", &ACCEL_LABELS, &ACCEL_VALUES, "Acceleration", ""),
        oFlt(.input, "trackpad_accel_speed", 0.0, -1.0, 1.0, 0.05, "Pointer speed", "From -1 (slowest) to 1 (fastest)."),
        oCmb(.input, "trackpad_scroll_method", "1", &SCROLL_LABELS, &SCROLL_VALUES, "Scroll with", ""),
        oFlt(.input, "trackpad_scroll_factor", 1.0, 0.1, 10.0, 0.1, "Scroll speed", ""),
        oCmb(.input, "trackpad_click_method", "1", &CLICK_LABELS, &CLICK_VALUES, "Right and middle click", "Button areas: where on the pad you press. Clickfinger: two fingers for right, three for middle."),
        oTg(.input, "trackpad_left_handed", false, "Left-handed", ""),
        oTg(.input, "trackpad_middle_button_emulation", false, "Middle click by pressing both buttons", ""),
    } },
    .{ .title = "Gestures", .opts = &.{
        oNum(.input, "swipe_min_threshold", 1, 0, 64, 1, "Swipe threshold", "How far fingers must move before a swipe counts."),
        oTg(.input, "gesture_live", true, "Follow the fingers", "Workspace and overview transitions move with your fingers instead of starting when you let go."),
        oNum(.input, "gesture_swipe_distance", 300, 50, 2000, 10, "Swipe distance for one workspace (px)", ""),
    } },
    .{ .title = "Touchscreen", .opts = &.{
        oTg(.input, "touch_enable", true, "Touchscreen", ""),
        oTg(.input, "touch_enable_mouse_emulation", false, "Touch acts as a click in apps without touch support", ""),
    } },
};

// -- Layouts ----------------------------------------------------------

const G_LAYOUT = [_]Group{
    .{ .title = "Dwindle", .desc = "Perihelion's default: each new window splits the focused one.", .opts = &.{
        oFlt(.layout, "dwindle_split_ratio", 0.5, 0.05, 0.95, 0.05, "Split ratio", "The share of the space the existing window keeps."),
        oCmb(.layout, "dwindle_horizontal_split", "1", &HSPLIT_LABELS, &SPLIT_VALUES, "Side-by-side splits open", ""),
        oCmb(.layout, "dwindle_vertical_split", "1", &VSPLIT_LABELS, &SPLIT_VALUES, "Stacked splits open", ""),
        oTg(.layout, "dwindle_smart_split", false, "Split towards the pointer", "The pointer's position in the focused window picks the side."),
        oTg(.layout, "dwindle_preserve_split", false, "Keep split directions", "Closing a window doesn't reshuffle the others."),
        oTg(.layout, "dwindle_smart_resize", false, "Resize towards the pointer", ""),
        oTg(.layout, "dwindle_manual_split", false, "Manual splits", ""),
    } },
    .{ .title = "Scroller", .opts = &.{
        oNum(.layout, "scroller_structs", 20, 0, 300, 1, "Side margin (px)", "Space kept free beside a full-width window."),
        oFlt(.layout, "scroller_default_proportion", 0.9, 0.1, 1.0, 0.05, "New window width", "As a share of the screen."),
        oTg(.layout, "scroller_ignore_proportion_single", true, "A single window ignores widths", ""),
        oFlt(.layout, "scroller_default_proportion_single", 1.0, 0.1, 1.0, 0.05, "Single window width", "Used when the row above is off."),
        oTg(.layout, "scroller_focus_center", false, "Always centre the focused window", ""),
        oTg(.layout, "scroller_prefer_center", false, "Centre a window that was off screen", ""),
        oTg(.layout, "scroller_prefer_overspread", true, "Spread windows into spare room", ""),
        oTg(.layout, "edge_scroller_pointer_focus", true, "Pointer can focus half-hidden windows", ""),
        oTxt(.layout, "scroller_proportion_preset", "0.5,0.8,1.0", 200, "Width presets", "The widths cycled through, separated by commas."),
    } },
    .{ .title = "Master and stack", .opts = &.{
        oTg(.layout, "new_is_master", true, "New windows become the master", ""),
        oFlt(.layout, "default_master_factor", 0.55, 0.05, 0.95, 0.05, "Master share of the screen", ""),
        oNum(.layout, "default_master_count", 1, 1, 16, 1, "Windows in the master area", ""),
        oTg(.layout, "center_master_overspread", false, "Centre layout: master fills an empty stack side", ""),
        oTg(.layout, "center_when_single_stack", true, "Centre layout: centre the master with one stack window", ""),
    } },
    .{ .title = "Monocle and deck", .opts = &.{
        oTg(.layout, "monocle_tab_mode", true, "Monocle: show windows as tabs", ""),
        oTg(.layout, "monocle_no_border", false, "Monocle: no borders", ""),
        oTg(.layout, "monocle_no_gap", false, "Monocle: no gaps", ""),
        oTg(.layout, "monocle_no_radius", false, "Monocle: square corners", ""),
        oTg(.layout, "deck_tab_mode", true, "Deck: show the stack as tabs", ""),
    } },
    .{ .title = "Switching layouts", .opts = &.{
        oTxt(.layout, "circle_layout", "", 240, "Layouts to cycle through", "For the switch_layout action, for example tile,scroller,dwindle. Empty cycles through all of them."),
    } },
};

// -- Misc -------------------------------------------------------------

const G_MISC = [_]Group{
    .{ .title = "Floating windows", .opts = &.{
        oTg(.misc, "enable_floating_snap", false, "Snap to edges and other windows", ""),
        oNum(.misc, "snap_distance", 30, 0, 200, 1, "Snap distance (px)", ""),
    } },
    .{ .title = "Dragging and resizing", .opts = &.{
        oTg(.misc, "drag_tile_to_tile", false, "Drag a tile onto another to swap them", ""),
        oTg(.misc, "drag_tile_small", true, "Shrink a tile while it is dragged", ""),
        oTg(.misc, "enable_border_resize", true, "Resize by dragging a window border", ""),
        oNum(.misc, "border_resize_size", 10, 0, 64, 1, "Border grab width (px)", "0 uses the border's own width."),
    } },
    .{ .title = "Scratchpad", .opts = &.{
        oTg(.misc, "single_scratchpad", true, "Show one scratchpad at a time", ""),
        oTg(.misc, "scratchpad_cross_monitor", false, "Share scratchpads between monitors", ""),
        oFlt(.misc, "scratchpad_width_ratio", 0.8, 0.1, 1.0, 0.05, "Width", "As a share of the screen."),
        oFlt(.misc, "scratchpad_height_ratio", 0.9, 0.1, 1.0, 0.05, "Height", ""),
    } },
    .{ .title = "Overview", .opts = &.{
        oNum(.misc, "overview_gap_inner", 5, 0, 300, 1, "Gap between windows (px)", ""),
        oNum(.misc, "overview_gap_outer", 30, 0, 300, 1, "Gap to the screen edge (px)", ""),
        oTg(.misc, "enable_hotarea", false, "Hot corner", "Moving the pointer into a screen corner opens the overview."),
        oCmb(.misc, "hotarea_corner", "2", &CORNER_LABELS, &CORNER_VALUES, "Corner", ""),
        oNum(.misc, "hotarea_size", 10, 1, 300, 1, "Corner size (px)", ""),
        oTg(.misc, "hotarea_disable_on_fullscreen", true, "Not while a window is fullscreen", ""),
    } },
    .{ .title = "Configuration", .opts = &.{
        oTg(.misc, "auto_reload_config", true, "Apply config files as soon as they are saved", "Perihelion Settings relies on this for most rows; leave it on."),
    } },
};

// -- Render -----------------------------------------------------------

const G_RENDER = [_]Group{
    .{ .title = "Tearing", .opts = &.{
        oCmb(.misc, "allow_tearing", "0", &TEAR_LABELS, &TEAR_VALUES, "Allow tearing", "A game shows each frame the moment it is ready: the lowest input lag, at the cost of visible tear lines. Fullscreen windows only is the usual choice for games. A window can also be forced with a force_tearing window rule."),
    } },
    .{ .title = "Effects", .opts = &.{
        oTg(.appearance, "blur_optimized", true, "Cache the blurred wallpaper", "The frost behind glass is made once per wallpaper instead of every frame. Turning this off blurs live windows too, at a real GPU cost."),
    } },
};

// -- Cursor -----------------------------------------------------------

const G_CURSOR = [_]Group{
    .{ .title = "Behaviour", .opts = &.{
        oNum(.misc, "cursor_hide_timeout", 0, 0, 300, 1, "Hide when idle (seconds)", "0 never hides it."),
        oTg(.misc, "cursor_hide_on_keypress", false, "Hide while typing", ""),
        oTg(.misc, "warp_cursor", true, "Jump to the focused window", "Changing focus with the keyboard moves the pointer to that window."),
        oTg(.misc, "drag_warp_cursor", true, "Follow a window dragged into a tile", ""),
    } },
};

// -- Group ------------------------------------------------------------

const G_GROUP = [_]Group{
    .{ .title = "Group bar", .desc = "The title strip of windows grouped into one frame.", .opts = &.{
        oTg(.appearance, "always_show_group_bar", false, "Show on every window", "Also on windows that are not in a group."),
        oNum(.appearance, "group_bar_height", 33, 0, 200, 1, "Height (px)", ""),
        oTg(.appearance, "group_bar_close_button_enable", false, "Close button", ""),
        oNum(.appearance, "group_bar_button_size", 16, 4, 64, 1, "Close button size (px)", ""),
        oNum(.appearance, "group_bar_button_margin", 4, 0, 64, 1, "Close button inset (px)", ""),
        oCol(.appearance, "group_bar_button_color", "0xad401fff", "Close button"),
    } },
    .{ .title = "Group bar style", .opts = &.{
        oTxt(.appearance, "group_bar_decorate_font_desc", "monospace Bold 13", 220, "Font", "Family, style and size."),
        oCol(.appearance, "group_bar_decorate_fg_color", "0xc0caf5ff", "Text"),
        oCol(.appearance, "group_bar_decorate_bg_color", "0x1d2021ff", "Background"),
        oCol(.appearance, "group_bar_decorate_focus_fg_color", "0x9ece6aff", "Focused text"),
        oCol(.appearance, "group_bar_decorate_focus_bg_color", "0x3c3836ff", "Focused background"),
        oCol(.appearance, "group_bar_decorate_border_color", "0x3b4261ff", "Border"),
        oNum(.appearance, "group_bar_decorate_border_width", 4, 0, 100, 1, "Border width (px)", ""),
        oNum(.appearance, "group_bar_decorate_corner_radius", 5, 0, 100, 1, "Corner radius (px)", ""),
        oNum(.appearance, "group_bar_decorate_padding_x", 0, 0, 100, 1, "Padding, sideways (px)", ""),
        oNum(.appearance, "group_bar_decorate_padding_y", 0, 0, 100, 1, "Padding, up and down (px)", ""),
    } },
    .{ .title = "Tab bar", .desc = "The tabs the monocle and deck layouts show (Layouts page).", .opts = &.{
        oNum(.appearance, "tab_bar_height", 33, 0, 200, 1, "Height (px)", ""),
        oTxt(.appearance, "tab_bar_decorate_font_desc", "monospace Bold 13", 220, "Font", ""),
        oCol(.appearance, "tab_bar_decorate_fg_color", "0xc0caf5ff", "Text"),
        oCol(.appearance, "tab_bar_decorate_bg_color", "0x1d2021ff", "Background"),
        oCol(.appearance, "tab_bar_decorate_focus_fg_color", "0x7aa2f7ff", "Focused text"),
        oCol(.appearance, "tab_bar_decorate_focus_bg_color", "0x3c3836ff", "Focused background"),
        oCol(.appearance, "tab_bar_decorate_border_color", "0x3b4261ff", "Border"),
        oNum(.appearance, "tab_bar_decorate_border_width", 4, 0, 100, 1, "Border width (px)", ""),
        oNum(.appearance, "tab_bar_decorate_corner_radius", 5, 0, 100, 1, "Corner radius (px)", ""),
    } },
};

// -- XWayland / OpenGL / Quirks ---------------------------------------

const G_XWAYLAND = [_]Group{
    .{ .title = "X11 server", .opts = &.{
        oTg(.misc, "xwayland_persistence", true, "Keep XWayland running", "Starts the X11 server at login and keeps it, so X11 apps open without a delay. Off starts it with the first X11 app instead." ++ RELOGIN),
        oTg(.misc, "xwayland_ignore_scale", false, "Ignore the display scale for X11 apps", "On a scaled monitor X11 apps are stretched and look soft. On draws them at native size: sharp, but small unless the app scales itself."),
    } },
};

const G_OPENGL = [_]Group{
    .{ .title = "NVIDIA", .opts = &.{
        oTg(.misc, "sync_obj_enable", true, "Nvidia anti-flicker", "Explicit sync: every frame reaches the screen in the order it was drawn. Without it NVIDIA drivers can flicker or flash old frames, most of all in X11 apps and games. Harmless on other GPUs." ++ RELOGIN),
    } },
};

const G_QUIRKS = [_]Group{
    .{ .title = "Apps and shortcuts", .opts = &.{
        oTg(.misc, "allow_shortcuts_inhibit", true, "Let apps capture shortcuts", "Games, remote desktops and virtual machines may take the whole keyboard, Super shortcuts included."),
        oTg(.misc, "disable_middle_paste", false, "No middle-click paste", "Turns the primary selection off for Wayland apps. X11 apps keep it."),
        oNum(.misc, "axis_bind_apply_timeout", 100, 0, 2000, 10, "Scroll-bind pause (ms)", "How long scroll steps count as one gesture for scroll-wheel shortcuts."),
    } },
    .{ .title = "Staying awake", .opts = &.{
        oTg(.misc, "idle_inhibit_ignore_visible", false, "Hidden windows may keep the screen on", "For example a music player on another workspace."),
        oTg(.misc, "idle_inhibit_when_fullscreen", false, "Stay awake while a fullscreen window is focused", ""),
    } },
    .{ .title = "Stacking and moving", .opts = &.{
        oTg(.misc, "float_full_to_top", false, "Fullscreen, floating and top panels share one layer", "They can then cover each other; whichever was raised last is on top."),
        oTg(.misc, "allow_lock_transparent", false, "Allow a see-through lock screen", ""),
        oTg(.misc, "focus_direction_only_zone_overlap", true, "Directional focus needs overlap", "Focus only moves to a window that lines up with the current one."),
        oTg(.misc, "exchange_cross_monitor", false, "Swapping and moving windows crosses monitors", ""),
    } },
};

const ALL_TABLES = [_][]const Group{ &G_GENERAL, &G_DECOR_TOP, &G_DECOR_BOTTOM, &G_KEYBOARD, &G_POINTER, &G_LAYOUT, &G_MISC, &G_RENDER, &G_CURSOR, &G_GROUP, &G_XWAYLAND, &G_OPENGL, &G_QUIRKS };
const LOOSE_OPTS = [_][]const Opt{ &BLUR_HEAD, &BLUR_TAIL };

fn optDefault(o: *const Opt, buf: []u8) []const u8 {
    return switch (o.kind) {
        .toggle => if (o.on) "1" else "0",
        .int => std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(o.num))}) catch "0",
        .float => std.fmt.bufPrint(buf, "{d:.2}", .{o.num}) catch "0",
        .text, .combo, .color => o.text,
    };
}

extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

fn dumpOpt(o: *const Opt) void {
    var nb: [32]u8 = undefined;
    const v = optDefault(o, &nb);
    if (v.len == 0) return; // an empty text field writes no line
    var lb: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&lb, "{s}={s}\n", .{ o.key, v }) catch return;
    _ = write(1, line.ptr, line.len);
}

/// `perihelion-settings --mango-keys`: every key these pages can write,
/// with its default, as a Mango config on stdout (see the header above).
pub fn dumpDefaults() void {
    for (ALL_TABLES) |groups| {
        for (groups) |*g| {
            for (g.opts) |*o| dumpOpt(o);
        }
    }
    for (LOOSE_OPTS) |opts| {
        for (opts) |*o| dumpOpt(o);
    }
}

// ---------------------------------------------------------------------
// Rows from the tables
// ---------------------------------------------------------------------

/// Float rows write two decimals (0.15, not 0.15000000000000002).
fn onOptFloat(spin: *gtk.GtkSpinButton, user_data: ?*anyopaque) callconv(.c) void {
    const f: *Field = @ptrCast(@alignCast(user_data.?));
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.2}", .{hg.gtk_spin_button_get_value(spin)}) catch return;
    f.doc.setValue(f.key, s);
    _ = f.doc.save();
}

/// Text rows: an emptied field removes the key (Mango's default) rather
/// than writing `key=`.
fn onOptEntry(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const f: *Field = @ptrCast(@alignCast(user_data.?));
    const text = std.mem.trim(u8, std.mem.span(gtk.gtk_entry_buffer_get_text(buffer)), " \t");
    if (text.len == 0) {
        if (f.doc.lineIndexOf(f.key)) |i| f.doc.removeLine(i);
    } else {
        f.doc.setValue(f.key, text);
    }
    _ = f.doc.save();
}

fn optRow(o: *const Opt) *gtk.AdwActionRow {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), o.title);
    if (o.sub.len > 0) gtk.adw_action_row_set_subtitle(row, o.sub);
    return row;
}

fn addOpt(group: *gtk.AdwPreferencesGroup, o: *const Opt) void {
    const doc = docOf(o.doc);
    switch (o.kind) {
        .toggle => {
            const row = optRow(o);
            const sw = gtk.gtk_switch_new();
            gtk.gtk_switch_set_active(sw, if (doc.getBool(o.key, o.on)) 1 else 0);
            gtk.gtk_widget_set_valign(@ptrCast(sw), gtk.ALIGN_CENTER);
            _ = gtk.g_signal_connect_data(@ptrCast(sw), "notify::active", @ptrCast(&onFieldSwitch), @ptrCast(fieldFor(doc, o.key, false, null)), null, 0);
            gtk.adw_action_row_add_suffix(row, @ptrCast(sw));
            gtk.adw_action_row_set_activatable_widget(row, @ptrCast(sw));
            gtk.adw_preferences_group_add(group, @ptrCast(row));
        },
        .int, .float => {
            const is_float = o.kind == .float;
            const initial = if (is_float) doc.getFloat(o.key, o.num) else @as(f64, @floatFromInt(doc.getInt(o.key, @intFromFloat(o.num))));
            const row = optRow(o);
            const spin = gtk.gtk_spin_button_new_with_range(o.min, o.max, o.step);
            gtk.gtk_spin_button_set_value(spin, initial);
            gtk.gtk_widget_set_valign(@ptrCast(spin), gtk.ALIGN_CENTER);
            const handler: gtk.GCallback = if (is_float) @ptrCast(&onOptFloat) else @ptrCast(&onFieldSpin);
            _ = gtk.g_signal_connect_data(@ptrCast(spin), "value-changed", handler, @ptrCast(fieldFor(doc, o.key, is_float, null)), null, 0);
            hp.attachNumber(row, spin); // a slider
            gtk.adw_preferences_group_add(group, @ptrCast(row));
        },
        .text => {
            const row = optRow(o);
            const entry = gtk.gtk_entry_new();
            gtk.gtk_widget_set_size_request(@ptrCast(entry), o.width, -1);
            gtk.gtk_widget_set_valign(@ptrCast(entry), gtk.ALIGN_CENTER);
            const buffer = gtk.gtk_entry_get_buffer(entry);
            hp.setEntryZ(buffer, doc.value(o.key) orelse o.text);
            _ = gtk.g_signal_connect_data(@ptrCast(buffer), "notify::text", @ptrCast(&onOptEntry), @ptrCast(fieldFor(doc, o.key, false, null)), null, 0);
            gtk.adw_action_row_add_suffix(row, @ptrCast(entry));
            gtk.adw_preferences_group_add(group, @ptrCast(row));
        },
        .combo => {
            const cur = doc.value(o.key) orelse o.text;
            var sel: c_uint = 0;
            for (o.values, 0..) |v, i| {
                if (std.mem.eql(u8, cur, v)) {
                    sel = @intCast(i);
                    break;
                }
            }
            var arr: [16]?[*:0]const u8 = undefined;
            const n = @min(o.labels.len, arr.len - 1);
            for (o.labels[0..n], 0..) |l, i| arr[i] = l;
            arr[n] = null;
            const row = gtk.adw_combo_row_new();
            gtk.adw_preferences_row_set_title(@ptrCast(row), o.title);
            if (o.sub.len > 0) gtk.adw_action_row_set_subtitle(@ptrCast(row), o.sub);
            gtk.adw_combo_row_set_model(row, @ptrCast(gtk.gtk_string_list_new(@ptrCast(&arr))));
            gtk.adw_combo_row_set_selected(row, sel);
            _ = gtk.g_signal_connect_data(@ptrCast(row), "notify::selected", @ptrCast(&onFieldCombo), @ptrCast(fieldFor(doc, o.key, false, o.values)), null, 0);
            gtk.adw_preferences_group_add(group, @ptrCast(row));
        },
        .color => addColorField(group, o.title, doc, o.key, o.text),
    }
}

fn newGroup(title: [:0]const u8, desc: [:0]const u8) *gtk.AdwPreferencesGroup {
    const grp = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(grp, title);
    if (desc.len > 0) gtk.adw_preferences_group_set_description(grp, desc);
    return grp;
}

fn addGroups(outer: *gtk.GtkBox, groups: []const Group) void {
    for (groups) |*g| {
        const grp = newGroup(g.title, g.desc);
        for (g.opts) |*o| addOpt(grp, o);
        gtk.gtk_box_append(outer, @ptrCast(grp));
    }
}

/// A row that only shows something (status, hardware): title, text, icon.
fn addInfoRow(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, text: []const u8, icon: [:0]const u8) void {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), title);
    var esc: [512]u8 = undefined;
    gtk.adw_action_row_set_subtitle(row, escapeZ(text, &esc));
    gtk.adw_action_row_add_prefix(row, @ptrCast(gtk.gtk_image_new_from_icon_name(icon)));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

// ---------------------------------------------------------------------
// env.conf switches: a setting that is an environment variable for the
// compositor (read when Mango starts, before it opens the GPU).
// ---------------------------------------------------------------------

/// `inverted`: the switch is ON while the variable is absent (the variable
/// turns something off).
const EnvToggle = struct { name: []const u8, value: []const u8, inverted: bool = false };

fn envLineIndex(name: []const u8) ?usize {
    for (doc_env.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (!std.mem.eql(u8, kv.key, "env")) continue;
        const comma = std.mem.indexOfScalar(u8, kv.value, ',') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, kv.value[0..comma], " \t"), name)) return i;
    }
    return null;
}

fn envIs(t: *const EnvToggle) bool {
    const i = envLineIndex(t.name) orelse return false;
    const kv = mango.parseKV(doc_env.line(i)) orelse return false;
    const comma = std.mem.indexOfScalar(u8, kv.value, ',') orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, kv.value[comma + 1 ..], " \t"), t.value);
}

fn setEnvToggle(t: *const EnvToggle, on: bool) void {
    const idx = envLineIndex(t.name);
    if (on) {
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "env={s},{s}", .{ t.name, t.value }) catch return;
        if (idx) |i| doc_env.setLine(i, text) else doc_env.appendLine(text);
    } else if (idx) |i| {
        doc_env.removeLine(i);
    }
    _ = doc_env.save();
    rebuildEnvList();
}

fn onEnvToggle(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const t: *const EnvToggle = @ptrCast(@alignCast(user_data.?));
    setEnvToggle(t, (gtk.gtk_switch_get_active(sw) != 0) != t.inverted);
}

fn addEnvToggle(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, sub: [:0]const u8, t: *const EnvToggle) void {
    hp.addSwitchRow(group, title, sub, envIs(t) != t.inverted, @ptrCast(&onEnvToggle), @ptrCast(@constCast(t)));
}

const ENV_SOFT_CURSOR = EnvToggle{ .name = "WLR_NO_HARDWARE_CURSORS", .value = "1" };
const ENV_NO_SCANOUT = EnvToggle{ .name = "WLR_SCENE_DISABLE_DIRECT_SCANOUT", .value = "1", .inverted = true };

// ---------------------------------------------------------------------
// Pages
// ---------------------------------------------------------------------

fn buildGeneralPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    addGroups(outer, &G_GENERAL);
    buildMangoGtkThemeGroup(outer);
    return outer;
}

fn buildDecorationPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    addGroups(outer, &G_DECOR_TOP);

    const blur = newGroup("Blur", "The frost behind glass. Blur needs something see-through over it: Background Opacity for the bar, Colored glass for the dock, Window glass for app windows. Turning a surface on also turns on blur behind panels, which it needs.");
    for (&BLUR_HEAD) |*o| addOpt(blur, o);
    addSurfaceBlurSwitch(blur, "Blur behind the bar", "perihelion-bar");
    addSurfaceBlurSwitch(blur, "Blur behind the dock", "perihelion-dock");
    addSurfaceBlurSwitch(blur, "Blur behind desktop widgets", "perihelion-shell");
    for (&BLUR_TAIL) |*o| addOpt(blur, o);
    gtk.gtk_box_append(outer, @ptrCast(blur));

    addGroups(outer, &G_DECOR_BOTTOM);
    return outer;
}

fn buildKeyboardsPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    addGroups(outer, &G_KEYBOARD);
    return outer;
}

fn buildPointerPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    addGroups(outer, &G_POINTER);
    return outer;
}

fn buildMiscPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    addGroups(outer, &G_MISC);
    return outer;
}

// Variable refresh rate. Mango has two real controls: `vrr` on each
// monitor_rule (always on for that monitor) and the window rule
// vrr_only_fullscreen (VRR only while that window is fullscreen, with the
// monitor's own vrr at 0). The row below sets them together.
const VRR_RULE = "vrr_only_fullscreen:1,app_id:.*";
const VRR_LABELS = [_][*:0]const u8{ "Off", "Fullscreen windows only", "Always on" };
const VRR_SUB = "Fullscreen windows only keeps the desktop at a steady refresh rate and uses VRR just for a fullscreen game or video. That avoids the stutter VRR causes on the desktop, where the rate jumps every time the pointer moves: laggy drag and drop, juddering video.";
const VRR_SUB_NEEDS_MONITORS = "Always on is set per monitor, and no monitor is listed yet: open Monitors, press Auto-detect, then choose it again. " ++ VRR_SUB;

fn vrrRuleIndex() ?usize {
    var i: usize = 0;
    while (i < doc_rules.lineCount()) : (i += 1) {
        const kv = mango.parseKV(doc_rules.line(i)) orelse continue;
        if (!std.mem.eql(u8, kv.key, "window_rule")) continue;
        if (std.mem.eql(u8, std.mem.trim(u8, kv.value, " \t"), VRR_RULE)) return i;
    }
    return null;
}

const MonitorVrr = struct { rules: usize = 0, on: usize = 0 };

fn monitorVrr() MonitorVrr {
    var out: MonitorVrr = .{};
    var i: usize = 0;
    while (i < doc_monitors.lineCount()) : (i += 1) {
        const kv = mango.parseKV(doc_monitors.line(i)) orelse continue;
        if (!std.mem.eql(u8, kv.key, "monitor_rule")) continue;
        out.rules += 1;
        if (std.mem.eql(u8, ruleField(kv.value, "vrr"), "1")) out.on += 1;
    }
    return out;
}

/// 0 off, 1 fullscreen windows only, 2 always on: what the files say now.
fn vrrMode() c_uint {
    if (vrrRuleIndex() != null) return 1;
    return if (monitorVrr().on > 0) 2 else 0;
}

/// `value` (a monitor_rule's fields) with vrr set to `on`, into `buf`.
fn ruleWithVrr(value: []const u8, on: bool, buf: []u8) ?[]const u8 {
    const want: []const u8 = if (on) "vrr:1" else "vrr:0";
    var w: usize = 0;
    var found = false;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) continue;
        var piece = part;
        if (std.mem.indexOfScalar(u8, part, ':')) |c| {
            if (std.mem.eql(u8, std.mem.trim(u8, part[0..c], " \t"), "vrr")) {
                piece = want;
                found = true;
            }
        }
        const sep: []const u8 = if (w > 0) "," else "";
        const out = std.fmt.bufPrint(buf[w..], "{s}{s}", .{ sep, piece }) catch return null;
        w += out.len;
    }
    if (!found) {
        const out = std.fmt.bufPrint(buf[w..], "{s}{s}", .{ if (w > 0) "," else "", want }) catch return null;
        w += out.len;
    }
    return buf[0..w];
}

fn setMonitorsVrr(on: bool) void {
    var i: usize = 0;
    while (i < doc_monitors.lineCount()) : (i += 1) {
        const kv = mango.parseKV(doc_monitors.line(i)) orelse continue;
        if (!std.mem.eql(u8, kv.key, "monitor_rule")) continue;
        var vb: [1024]u8 = undefined;
        const fields = ruleWithVrr(kv.value, on, &vb) orelse continue;
        var lb: [1100]u8 = undefined;
        const text = std.fmt.bufPrint(&lb, "monitor_rule={s}", .{fields}) catch continue;
        doc_monitors.setLine(i, text);
    }
}

fn onVrrChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(row);
    if (idx > 2) return;
    if (idx == vrrMode()) return; // already what the files say
    if (idx == 2 and monitorVrr().rules == 0) {
        // Nothing to switch on: say so and show what is really set.
        gtk.adw_action_row_set_subtitle(@ptrCast(row), VRR_SUB_NEEDS_MONITORS);
        gtk.adw_combo_row_set_selected(row, vrrMode());
        return;
    }
    gtk.adw_action_row_set_subtitle(@ptrCast(row), VRR_SUB);
    setMonitorsVrr(idx == 2);
    const rule_at = vrrRuleIndex();
    if (idx == 1 and rule_at == null) {
        doc_rules.appendLine("window_rule=" ++ VRR_RULE);
    } else if (idx != 1) {
        if (rule_at) |i| doc_rules.removeLine(i);
    }
    _ = doc_monitors.save();
    _ = doc_rules.save();
    rebuildRuleList(&g_rp_monitors);
    rebuildRuleList(&g_rp_wrules);
    reload();
}

fn buildRenderPage() *gtk.GtkBox {
    const outer = hp.pageBox();

    const vrr = newGroup("Variable refresh rate", "VRR (FreeSync, G-Sync) lets the monitor follow the frame rate instead of a fixed one.");
    {
        var arr: [VRR_LABELS.len + 1]?[*:0]const u8 = undefined;
        for (VRR_LABELS, 0..) |l, i| arr[i] = l;
        arr[VRR_LABELS.len] = null;
        const row = gtk.adw_combo_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Use VRR");
        gtk.adw_action_row_set_subtitle(@ptrCast(row), VRR_SUB);
        gtk.adw_combo_row_set_model(row, @ptrCast(gtk.gtk_string_list_new(@ptrCast(&arr))));
        gtk.adw_combo_row_set_selected(row, vrrMode());
        _ = gtk.g_signal_connect_data(@ptrCast(row), "notify::selected", @ptrCast(&onVrrChanged), null, null, 0);
        gtk.adw_preferences_group_add(vrr, @ptrCast(row));
    }
    gtk.gtk_box_append(outer, @ptrCast(vrr));

    addGroups(outer, &G_RENDER);

    const present = newGroup("Presentation", "");
    addEnvToggle(present, "Direct scanout", "A fullscreen window is handed straight to the display, skipping the compositor: less latency and GPU work. Turn it off if a fullscreen game or video flickers, shows black, or loses its colors." ++ RELOGIN, &ENV_NO_SCANOUT);
    gtk.gtk_box_append(outer, @ptrCast(present));
    return outer;
}

fn buildCursorPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    buildCursorGroup(outer);
    addGroups(outer, &G_CURSOR);
    return outer;
}

fn buildGroupPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    addGroups(outer, &G_GROUP);
    return outer;
}

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;

fn fileExists(path: [*:0]const u8) bool {
    return access(path, 0) == 0;
}

/// XWayland: Mango has no switch for the X11 layer itself (it is built in
/// and always started), so the page shows its real state and offers the two
/// settings Mango does have.
fn buildXWaylandPage() *gtk.GtkBox {
    const outer = hp.pageBox();

    const installed = fileExists("/usr/bin/Xwayland");
    const display: ?[]const u8 = if (getenv("DISPLAY")) |d| std.mem.span(d) else null;
    const ready = installed and display != null and display.?.len > 0;

    const status = newGroup("XWayland", "X11-only apps (Vital and many other audio plug-ins, older games, some Wine and Java apps) run through XWayland. Wayland-native apps are completely unaffected by this setting.");
    {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Enable XWayland compatibility layer");
        var buf: [200]u8 = undefined;
        var esc: [300]u8 = undefined;
        const text: []const u8 = if (!installed)
            "Unavailable: the Xwayland server is not installed (sudo dnf install xorg-x11-server-Xwayland)."
        else if (ready)
            (std.fmt.bufPrint(&buf, "On, serving X11 apps on display {s}. Mango keeps this layer on and has no setting to turn it off, so the switch is fixed.", .{display.?}) catch "On.")
        else
            "Not running in this session. Log out and back in.";
        gtk.adw_action_row_set_subtitle(row, escapeZ(text, &esc));
        const sw = gtk.gtk_switch_new();
        gtk.gtk_switch_set_active(sw, if (ready) 1 else 0);
        gtk.gtk_widget_set_valign(@ptrCast(sw), gtk.ALIGN_CENTER);
        gtk.gtk_widget_set_sensitive(@ptrCast(sw), 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(sw));
        gtk.adw_preferences_group_add(status, @ptrCast(row));
    }
    gtk.gtk_box_append(outer, @ptrCast(status));

    addGroups(outer, &G_XWAYLAND);
    return outer;
}

/// "NVIDIA 570.86.16" from /proc/driver/nvidia/version, or null without
/// the proprietary driver.
fn nvidiaVersion(buf: []u8) ?[]const u8 {
    const fd = open("/proc/driver/nvidia/version", 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    var raw: [512]u8 = undefined;
    const n = read(fd, &raw, raw.len);
    if (n <= 0) return null;
    const text = raw[0..@intCast(n)];
    const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    // "NVRM version: NVIDIA UNIX x86_64 Kernel Module  570.86.16  Fri ..."
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |tok| {
        if (tok.len >= 3 and tok[0] >= '0' and tok[0] <= '9' and std.mem.indexOfScalar(u8, tok, '.') != null) {
            return std.fmt.bufPrint(buf, "NVIDIA driver {s}", .{tok}) catch null;
        }
    }
    return std.fmt.bufPrint(buf, "NVIDIA driver", .{}) catch null;
}

fn buildOpenGLPage() *gtk.GtkBox {
    const outer = hp.pageBox();

    const hw = newGroup("Graphics", "");
    var vb: [64]u8 = undefined;
    if (nvidiaVersion(&vb)) |v| {
        addInfoRow(hw, "Driver", v, "emblem-ok-symbolic");
    } else {
        addInfoRow(hw, "Driver", "No NVIDIA driver is loaded (Intel, AMD or nouveau through Mesa). The NVIDIA settings below are safe to leave as they are.", "computer-symbolic");
    }
    gtk.gtk_box_append(outer, @ptrCast(hw));

    const nv = newGroup("NVIDIA", "Mango draws with OpenGL ES. These are its switches for the flicker NVIDIA drivers are known for.");
    for (G_OPENGL[0].opts) |*o| addOpt(nv, o);
    addEnvToggle(nv, "Software cursor", "Draws the pointer as part of the picture instead of on the GPU's cursor plane. Fixes a flickering, lagging or invisible pointer." ++ RELOGIN, &ENV_SOFT_CURSOR);
    gtk.gtk_box_append(outer, @ptrCast(nv));

    return outer;
}

fn buildQuirksPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    addGroups(outer, &G_QUIRKS);
    return outer;
}

// ---------------------------------------------------------------------
// Animations page (appearance.conf)
// ---------------------------------------------------------------------

const ANIM_TYPE_LABELS = [_][*:0]const u8{ "zoom", "slide" };
const ANIM_TYPE_VALUES = [_][]const u8{ "zoom", "slide" };
const DIR_LABELS = [_][*:0]const u8{ "Vertical", "Horizontal" };
const DIR_VALUES = [_][]const u8{ "0", "1" };

fn buildAnimationsPage() *gtk.GtkBox {
    const outer = hp.pageBox();

    const anim = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(anim, "Animations");
    addSwitchField(anim, "Enable Animations", &doc_appearance, "animations", true);
    addSwitchField(anim, "Layer Animations", &doc_appearance, "layer_animations", true);
    addComboField(anim, "Open Type", &ANIM_TYPE_LABELS, &ANIM_TYPE_VALUES, &doc_appearance, "animation_type_open", "zoom");
    addComboField(anim, "Close Type", &ANIM_TYPE_LABELS, &ANIM_TYPE_VALUES, &doc_appearance, "animation_type_close", "zoom");
    addComboField(anim, "Tag Direction", &DIR_LABELS, &DIR_VALUES, &doc_appearance, "tag_animation_direction", "1");
    addSwitchField(anim, "Fade In", &doc_appearance, "animation_fade_in", true);
    addSwitchField(anim, "Fade Out", &doc_appearance, "animation_fade_out", true);
    gtk.gtk_box_append(outer, @ptrCast(anim));

    const timing = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(timing, "Durations (ms)");
    addSpinField(timing, "Move", 0, 5000, 10, &doc_appearance, "animation_duration_move", 300, false);
    addSpinField(timing, "Open", 0, 5000, 10, &doc_appearance, "animation_duration_open", 100, false);
    addSpinField(timing, "Tag Switch", 0, 5000, 10, &doc_appearance, "animation_duration_tag", 300, false);
    addSpinField(timing, "Close", 0, 5000, 10, &doc_appearance, "animation_duration_close", 400, false);
    addSpinField(timing, "Focus", 0, 5000, 10, &doc_appearance, "animation_duration_focus", 0, false);
    gtk.gtk_box_append(outer, @ptrCast(timing));

    const zf = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(zf, "Zoom and Fade");
    addSpinField(zf, "Zoom Initial Ratio", 0.0, 1.0, 0.05, &doc_appearance, "zoom_initial_ratio", 0.1, true);
    addSpinField(zf, "Zoom End Ratio", 0.0, 1.0, 0.05, &doc_appearance, "zoom_end_ratio", 0.5, true);
    addSpinField(zf, "Fade In Begin Opacity", 0.0, 1.0, 0.05, &doc_appearance, "fade_in_begin_opacity", 0.3, true);
    addSpinField(zf, "Fade Out Begin Opacity", 0.0, 1.0, 0.05, &doc_appearance, "fade_out_begin_opacity", 0.2, true);
    gtk.gtk_box_append(outer, @ptrCast(zf));

    const curves = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(curves, "Curves");
    gtk.adw_preferences_group_set_description(curves, "Bézier control points, e.g. 0.46, 1.0, 0.29, 1.");
    addEntryField(curves, "Open", &doc_appearance, "animation_curve_open", "0.87, 0, 0.13, 1", 260);
    addEntryField(curves, "Move", &doc_appearance, "animation_curve_move", "0.46, 1.0, 0.29, 1", 260);
    addEntryField(curves, "Tag", &doc_appearance, "animation_curve_tag", "0.46, 1.0, 0.29, 1", 260);
    addEntryField(curves, "Close", &doc_appearance, "animation_curve_close", "0.87, 0, 0.13, 1", 260);
    addEntryField(curves, "Focus", &doc_appearance, "animation_curve_focus", "0.46, 1.0, 0.29, 1", 260);
    addEntryField(curves, "Opacity Fade In", &doc_appearance, "animation_curve_opacity_fade_in", "0.46, 1.0, 0.29, 1", 260);
    addEntryField(curves, "Opacity Fade Out", &doc_appearance, "animation_curve_opacity_fade_out", "0.5, 0.5, 0.5, 0.5", 260);
    gtk.gtk_box_append(outer, @ptrCast(curves));

    return outer;
}

// ---------------------------------------------------------------------
// Layouts page (rules.conf tag rules + layout.conf)
// ---------------------------------------------------------------------

fn buildLayoutPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    addRulePage(outer, &g_rp_tags);
    addGroups(outer, &G_LAYOUT);
    return outer;
}

// ---------------------------------------------------------------------
// Monitors / Window Rules pages
// ---------------------------------------------------------------------

fn buildMonitorsPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    // Update the description to mention the canvas + modes.
    g_rp_monitors.desc = "One row per monitor_rule. Drag cards on the canvas to arrange; Auto-detect fills name, resolution, refresh and position from the connected displays (extras like scale/rr/vrr/mirror are preserved). Resolution choices come from wlr-randr's full mode list.";
    addRulePage(outer, &g_rp_monitors);

    refreshMangoCaps();

    g_mango_canvas = hg.gtk_drawing_area_new();
    hg.gtk_drawing_area_set_content_width(g_mango_canvas.?, MANGO_CANVAS_W);
    hg.gtk_drawing_area_set_content_height(g_mango_canvas.?, MANGO_CANVAS_H);
    hg.gtk_drawing_area_set_draw_func(g_mango_canvas.?, &onMangoCanvasDraw, null, null);
    gtk.gtk_box_append(outer, @ptrCast(g_mango_canvas.?));

    const click = hg.gtk_gesture_click_new();
    _ = gtk.g_signal_connect_data(@ptrCast(click), "pressed", @ptrCast(&onMangoCanvasPressed), g_mango_canvas.?, null, 0);
    gtk.gtk_widget_add_controller(@ptrCast(g_mango_canvas.?), @ptrCast(click));

    const drag = hg.gtk_gesture_drag_new();
    _ = gtk.g_signal_connect_data(@ptrCast(drag), "drag-begin", @ptrCast(&onMangoDragBegin), null, null, 0);
    _ = gtk.g_signal_connect_data(@ptrCast(drag), "drag-update", @ptrCast(&onMangoDragUpdate), null, null, 0);
    _ = gtk.g_signal_connect_data(@ptrCast(drag), "drag-end", @ptrCast(&onMangoDragEnd), null, null, 0);
    gtk.gtk_widget_add_controller(@ptrCast(g_mango_canvas.?), @ptrCast(drag));

    hp.appendActionButton(outer, "Auto-detect Monitors", @ptrCast(&onMonitorsDetectClicked), null);
    hp.appendActionButton(outer, "Arrange Side-by-Side", @ptrCast(&onMangoArrangeClicked), null);
    hp.appendActionButton(outer, "Align Tops", @ptrCast(&onMangoAlignTopsClicked), null);
    hp.appendActionButton(outer, "Refresh Modes", @ptrCast(&onMangoCapsRefreshClicked), null);
    return outer;
}

fn buildWindowRulesPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    addRulePage(outer, &g_rp_wrules);
    return outer;
}

fn buildLayerRulesPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    addRulePage(outer, &g_rp_lrules);
    return outer;
}

// ---------------------------------------------------------------------
// Keybinds page
// ---------------------------------------------------------------------

fn buildKeybindsPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Keybinds");
    gtk.adw_preferences_group_set_description(group, "bind / mousebind / axisbind / gesturebind lines from keybinds.conf. Binds are MODIFIERS, KEY, ACTION, ARGUMENTS.");
    gtk.gtk_box_append(outer, @ptrCast(group));

    g_keybinds_list = hp.newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_keybinds_list.?));
    rebuildKeybindsList();
    hp.appendActionButton(outer, "Add Keybind", @ptrCast(&onBindAdd), null);
    return outer;
}

// ---------------------------------------------------------------------
// Rebuild everything / page registry
// ---------------------------------------------------------------------

fn rebuildAll() void {
    rebuildRuleList(&g_rp_monitors);
    rebuildRuleList(&g_rp_wrules);
    rebuildRuleList(&g_rp_lrules);
    rebuildRuleList(&g_rp_tags);
    rebuildKeybindsList();
    rebuildAutostartList();
    rebuildEnvList();
}

pub const pages = struct {
    // Event Horizon's settings order first, then the pages that edit lists.
    pub const names = [_][:0]const u8{
        "General",      "Decoration", "Keyboards",   "Mouse & Touchpad", "Binds",
        "Layouts",      "Animations", "Misc",        "Render",             "Cursor",
        "Group",        "XWayland",   "OpenGL",      "Quirks",             "Monitors",
        "Window Rules", "Layer Rules", "Autostart",  "Environment",
    };
    pub const icons = [_][:0]const u8{
        "emblem-system-symbolic",                    "preferences-desktop-appearance-symbolic", "input-keyboard-symbolic",
        "input-mouse-symbolic",                      "preferences-desktop-keyboard-shortcuts-symbolic",
        "view-grid-symbolic",                        "media-playlist-repeat-symbolic",          "preferences-other-symbolic",
        "display-brightness-symbolic",               "input-touchpad-symbolic",                 "tab-new-symbolic",
        "computer-symbolic",                         "applications-graphics-symbolic",          "dialog-warning-symbolic",
        "video-display-symbolic",                    "preferences-system-windows-symbolic",     "layer-group-symbolic",
        "system-run-symbolic",                       "preferences-system-symbolic",
    };

    pub fn widgets() [names.len]*gtk.GtkBox {
        return .{
            buildGeneralPage(),
            buildDecorationPage(),
            buildKeyboardsPage(),
            buildPointerPage(),
            buildKeybindsPage(),
            buildLayoutPage(),
            buildAnimationsPage(),
            buildMiscPage(),
            buildRenderPage(),
            buildCursorPage(),
            buildGroupPage(),
            buildXWaylandPage(),
            buildOpenGLPage(),
            buildQuirksPage(),
            buildMonitorsPage(),
            buildWindowRulesPage(),
            buildLayerRulesPage(),
            buildAutostartPage(),
            buildEnvPage(),
        };
    }
};

test "option tables: unique keys, sane defaults" {
    const t = std.testing;
    var seen: [512][]const u8 = undefined;
    var n: usize = 0;
    for (ALL_TABLES) |groups| {
        for (groups) |*g| {
            for (g.opts) |*o| {
                for (seen[0..n]) |k| try t.expect(!std.mem.eql(u8, k, o.key));
                seen[n] = o.key;
                n += 1;
                switch (o.kind) {
                    .int, .float => try t.expect(o.num >= o.min and o.num <= o.max and o.step > 0),
                    .combo => {
                        try t.expectEqual(o.labels.len, o.values.len);
                        var found = false;
                        for (o.values) |v| found = found or std.mem.eql(u8, v, o.text);
                        try t.expect(found);
                    },
                    .color => try t.expect(mangoHexToRgba(o.text) != null),
                    else => {},
                }
                // Pango markup: these would break the row's label.
                try t.expect(std.mem.indexOfAny(u8, o.title, "&<>") == null);
                try t.expect(std.mem.indexOfAny(u8, o.sub, "&<>") == null);
            }
        }
    }
    try t.expect(n > 120);
}

// ---------------------------------------------------------------------
// Tests — layer-blur switch logic (pure Doc operations, no display).
// Run: zig test src/mango_pages.zig
// ---------------------------------------------------------------------

test "layer blur round-trip" {
    const t = std.testing;
    doc_rules.reset();
    defer doc_rules.reset();
    // In-memory fixture mirroring a real rules.conf (selection opt-out,
    // bar line with extra params, widgets line, comment).
    doc_rules.appendLine("# Layer rules fixture");
    doc_rules.appendLine("layer_rule = no_animation:1, no_blur:1, layer_name:selection");
    doc_rules.appendLine("layer_rule = no_animation:0, no_blur:0, layer_name:simpbar");
    doc_rules.appendLine("layer_rule = no_blur:0, layer_name:simpbar-shell");

    // Fixture state: bar + widgets blurred, selection opted out.
    try t.expect(layerBlurEnabled("simpbar"));
    try t.expect(layerBlurEnabled("simpbar-shell"));
    try t.expect(!layerBlurEnabled("selection"));
    try t.expect(layerBlurEnabled("never-seen")); // no line = default blur

    // Turning the bar off preserves its other params in place.
    setLayerBlur("simpbar", false);
    try t.expect(!layerBlurEnabled("simpbar"));
    try t.expectEqualStrings("layer_rule = no_animation:0, no_blur:1, layer_name:simpbar", doc_rules.line(2));

    // ...and back on.
    setLayerBlur("simpbar", true);
    try t.expect(layerBlurEnabled("simpbar"));
    try t.expectEqualStrings("layer_rule = no_animation:0, no_blur:0, layer_name:simpbar", doc_rules.line(2));

    // Turning off a surface with no line appends a minimal opt-out.
    doc_rules.removeLine(3); // drop the simpbarshell line
    try t.expect(layerBlurEnabled("simpbar-shell"));
    setLayerBlur("simpbar-shell", false);
    try t.expect(!layerBlurEnabled("simpbar-shell"));
    try t.expectEqualStrings("layer_rule = no_blur:1, layer_name:simpbar-shell", doc_rules.line(doc_rules.lineCount() - 1));

    // Turning on a lineless surface writes nothing (default already blurs).
    const n_before = doc_rules.lineCount();
    setLayerBlur("never-seen", true);
    try t.expectEqual(n_before, doc_rules.lineCount());

    // Last matching line wins, for both read and write.
    doc_rules.appendLine("layer_rule = no_blur:1, layer_name:simpbar");
    try t.expect(!layerBlurEnabled("simpbar"));
    setLayerBlur("simpbar", true);
    try t.expect(layerBlurEnabled("simpbar"));
    try t.expectEqualStrings("layer_rule = no_blur:0, layer_name:simpbar", doc_rules.line(doc_rules.lineCount() - 1));
    try t.expectEqualStrings("layer_rule = no_animation:0, no_blur:0, layer_name:simpbar", doc_rules.line(2));
}
