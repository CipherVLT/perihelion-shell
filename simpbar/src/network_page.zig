//! Perihelion Settings > System > Network: Wi-Fi and wired status, and VPN
//! (what is connected, for how long, its tunnel, live throughput, and the
//! saved connections with connect / disconnect / remove / import).
//!
//! NetworkManager does the work, through nmcli. Nothing here blocks the
//! window: every nmcli run is an async GSubprocess, and the page only asks
//! while it is on screen (every 4 s; the throughput figures come from the
//! kernel's interface counters once a second, which costs nothing).

const std = @import("std");
const gtk = @import("welcome_gtk.zig");
const hg = @import("hypr_gtk.zig");
const hp = @import("hypr_pages.zig");
const net = @import("network.zig");

extern "c" fn g_subprocess_newv(argv: [*]const ?[*:0]const u8, flags: c_int, err: ?*?*anyopaque) ?*anyopaque;
extern "c" fn g_subprocess_communicate_async(sub: *anyopaque, stdin_buf: ?*anyopaque, cancellable: ?*anyopaque, callback: *const fn (?*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) void;
extern "c" fn g_subprocess_communicate_finish(sub: *anyopaque, result: *anyopaque, stdout_buf: ?*?*anyopaque, stderr_buf: ?*?*anyopaque, err: ?*?*anyopaque) c_int;
extern "c" fn g_subprocess_get_if_exited(sub: *anyopaque) c_int;
extern "c" fn g_subprocess_get_exit_status(sub: *anyopaque) c_int;
extern "c" fn g_bytes_get_data(bytes: *anyopaque, size: *usize) ?[*]const u8;
extern "c" fn g_bytes_unref(bytes: *anyopaque) void;
extern "c" fn gtk_widget_set_visible(widget: *anyopaque, visible: c_int) void;
extern "c" fn gtk_widget_get_mapped(widget: *anyopaque) c_int;
extern "c" fn adw_alert_dialog_new(heading: ?[*:0]const u8, body: ?[*:0]const u8) *anyopaque;
extern "c" fn adw_alert_dialog_add_response(self: *anyopaque, id: [*:0]const u8, label: [*:0]const u8) void;
extern "c" fn adw_alert_dialog_set_response_appearance(self: *anyopaque, id: [*:0]const u8, appearance: c_int) void;
extern "c" fn adw_alert_dialog_set_default_response(self: *anyopaque, id: [*:0]const u8) void;
extern "c" fn adw_alert_dialog_set_close_response(self: *anyopaque, id: [*:0]const u8) void;
extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

// GSubprocessFlags: stdout through a pipe, stderr merged into it (so a
// failed nmcli's message comes back as the output).
const SUBPROCESS_STDOUT_PIPE: c_int = 1 << 2;
const SUBPROCESS_STDERR_MERGE: c_int = 1 << 6;
const ADW_RESPONSE_DESTRUCTIVE: c_int = 2;

/// The Settings window, for dialogs (set by config_main).
pub var parent_window: ?*anyopaque = null;

// ---------------------------------------------------------------------
// Running nmcli without blocking the window
// ---------------------------------------------------------------------

const Done = *const fn (ok: bool, out: []const u8) void;

fn onRunDone(source: ?*anyopaque, res: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const sub = source orelse return;
    const done: Done = @ptrFromInt(@intFromPtr(user_data.?));
    var out_bytes: ?*anyopaque = null;
    const finished = g_subprocess_communicate_finish(sub, res, &out_bytes, null, null) != 0;
    var ok = false;
    if (finished and g_subprocess_get_if_exited(sub) != 0) ok = g_subprocess_get_exit_status(sub) == 0;
    var text: []const u8 = "";
    if (out_bytes) |b| {
        var size: usize = 0;
        if (g_bytes_get_data(b, &size)) |p| text = p[0..size];
    }
    done(ok, text);
    if (out_bytes) |b| g_bytes_unref(b);
    gtk.g_object_unref(sub);
}

/// Starts `argv` (null-terminated) and calls `done` on the GTK thread when
/// it has finished. False when it could not be started.
fn run(argv: []const ?[*:0]const u8, done: Done) bool {
    const sub = g_subprocess_newv(argv.ptr, SUBPROCESS_STDOUT_PIPE | SUBPROCESS_STDERR_MERGE, null) orelse return false;
    g_subprocess_communicate_async(sub, null, null, &onRunDone, @ptrFromInt(@intFromPtr(done)));
    return true;
}

/// Starts a program and lets it go (a terminal, an editor).
fn launch(argv: []const ?[*:0]const u8) void {
    if (g_subprocess_newv(argv.ptr, 0, null)) |sub| gtk.g_object_unref(sub);
}

// ---------------------------------------------------------------------
// Page state
// ---------------------------------------------------------------------

var g_state: net.State = .{};
var g_have_state = false;
var g_busy = false;
var g_ticks: u32 = 0;

var g_page: ?*gtk.GtkBox = null;
var g_wifi_row: ?*gtk.AdwActionRow = null;
var g_wifi_icon: ?*gtk.GtkImage = null;
var g_wired_row: ?*gtk.AdwActionRow = null;
var g_vpn_row: ?*gtk.AdwActionRow = null;
var g_vpn_icon: ?*gtk.GtkImage = null;
var g_vpn_disconnect: ?*gtk.GtkButton = null;
var g_tunnel_row: ?*gtk.AdwActionRow = null;
var g_route_row: ?*gtk.AdwActionRow = null;
var g_speed_row: ?*gtk.AdwActionRow = null;
var g_saved_list: ?*gtk.GtkListBox = null;
var g_message: ?*gtk.GtkLabel = null;

/// The saved list as last drawn (uuid, state and name of every row), so it
/// is only rebuilt when something in it changed.
var g_saved_sig: [2048]u8 = undefined;
var g_saved_sig_len: usize = 0;
var g_saved_drawn = false;
var g_row_uuid: [net.MAX_CONNS]net.Str(40) = undefined;
var g_row_name: [net.MAX_CONNS]net.Str(80) = undefined;

/// Which VPN the status rows show, and when this window watched it connect
/// (used when NetworkManager's own start time isn't available).
var g_shown_uuid: net.Str(40) = .{};
var g_watched_since: i64 = 0;

/// Throughput: the tunnel's byte counters at the previous tick.
var g_rate_iface: net.Str(16) = .{};
var g_rx_prev: u64 = 0;
var g_tx_prev: u64 = 0;
var g_rate_valid = false;

var g_pending_delete: net.Str(40) = .{};

// ---------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------

/// `s` as a NUL-terminated copy with Pango markup characters escaped (row
/// titles and subtitles are markup; a network called "A&B" must not break
/// the row).
fn markupZ(s: []const u8, buf: []u8) [*:0]const u8 {
    var n: usize = 0;
    for (s) |c| {
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => "",
        };
        if (rep.len == 0) {
            if (n + 1 >= buf.len) break;
            buf[n] = c;
            n += 1;
            continue;
        }
        if (n + rep.len >= buf.len) break;
        @memcpy(buf[n .. n + rep.len], rep);
        n += rep.len;
    }
    buf[n] = 0;
    return buf[0..n :0].ptr;
}

fn setRow(row: ?*gtk.AdwActionRow, title: []const u8, subtitle: []const u8) void {
    const r = row orelse return;
    var tb: [256]u8 = undefined;
    var sb: [512]u8 = undefined;
    gtk.adw_preferences_row_set_title(@ptrCast(r), markupZ(title, &tb));
    gtk.adw_action_row_set_subtitle(r, markupZ(subtitle, &sb));
}

fn setVisible(widget: ?*anyopaque, on: bool) void {
    if (widget) |w| gtk_widget_set_visible(w, if (on) 1 else 0);
}

fn setMessage(text: []const u8) void {
    const label = g_message orelse return;
    var buf: [600]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    gtk.gtk_label_set_text(label, buf[0..n :0].ptr);
    setVisible(@ptrCast(label), n > 0);
}

fn readCounter(iface: []const u8, name: []const u8) ?u64 {
    var pb: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pb, "/sys/class/net/{s}/statistics/{s}", .{ iface, name }) catch return null;
    const fd = open(path.ptr, 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    var raw: [32]u8 = undefined;
    const n = read(fd, &raw, raw.len);
    if (n <= 0) return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, raw[0..@intCast(n)], " \n"), 10) catch null;
}

fn now() i64 {
    return @intCast(time(null));
}

// ---------------------------------------------------------------------
// Drawing the state
// ---------------------------------------------------------------------

fn signalIcon(signal: u8) [:0]const u8 {
    if (signal >= 75) return "network-wireless-signal-excellent-symbolic";
    if (signal >= 50) return "network-wireless-signal-good-symbolic";
    if (signal >= 25) return "network-wireless-signal-ok-symbolic";
    return "network-wireless-signal-weak-symbolic";
}

fn renderLinks() void {
    const st = &g_state;
    var buf: [256]u8 = undefined;
    if (st.nm != .ok) {
        setRow(g_wifi_row, "Network", if (st.nm == .missing)
            "NetworkManager is not installed, so there is nothing to show here."
        else
            "NetworkManager is not running. Start it with: sudo systemctl start NetworkManager");
        if (g_wifi_icon) |ic| gtk.gtk_image_set_from_icon_name(ic, "network-offline-symbolic");
        setVisible(@ptrCast(g_wired_row), false);
        return;
    }
    switch (st.wifi) {
        .connected => {
            var parts: [200]u8 = undefined;
            var w: usize = 0;
            const head = std.fmt.bufPrint(parts[w..], "Connected", .{}) catch "";
            w += head.len;
            if (st.signal > 0) {
                const s = std.fmt.bufPrint(parts[w..], " \u{00b7} signal {d}%", .{st.signal}) catch "";
                w += s.len;
            }
            if (st.rate.len > 0) {
                const s = std.fmt.bufPrint(parts[w..], " \u{00b7} {s}", .{st.rate.slice()}) catch "";
                w += s.len;
            }
            if (st.security.len > 0) {
                const s = std.fmt.bufPrint(parts[w..], " \u{00b7} {s}", .{st.security.slice()}) catch "";
                w += s.len;
            }
            setRow(g_wifi_row, if (st.ssid.len > 0) st.ssid.slice() else "Wi-Fi", parts[0..w]);
            if (g_wifi_icon) |ic| gtk.gtk_image_set_from_icon_name(ic, signalIcon(st.signal));
        },
        .connecting => {
            const t = std.fmt.bufPrint(&buf, "Connecting to {s}\u{2026}", .{st.ssid.slice()}) catch "Connecting";
            setRow(g_wifi_row, "Wi-Fi", t);
            if (g_wifi_icon) |ic| gtk.gtk_image_set_from_icon_name(ic, "network-wireless-acquiring-symbolic");
        },
        .disconnected => {
            setRow(g_wifi_row, "Wi-Fi", "Not connected. Networks opens the list of Wi-Fi networks.");
            if (g_wifi_icon) |ic| gtk.gtk_image_set_from_icon_name(ic, "network-wireless-offline-symbolic");
        },
        .off => {
            setRow(g_wifi_row, "Wi-Fi", "Turned off, or blocked by a hardware switch.");
            if (g_wifi_icon) |ic| gtk.gtk_image_set_from_icon_name(ic, "network-wireless-disabled-symbolic");
        },
        .none => {
            setRow(g_wifi_row, "Wi-Fi", "No Wi-Fi adapter was found.");
            if (g_wifi_icon) |ic| gtk.gtk_image_set_from_icon_name(ic, "network-wireless-offline-symbolic");
        },
    }
    switch (st.wired) {
        .connected, .connecting => {
            const t = std.fmt.bufPrint(&buf, "{s} \u{00b7} {s}", .{ if (st.wired == .connected) "Connected" else "Connecting", st.wired_dev.slice() }) catch "Connected";
            setRow(g_wired_row, "Wired", t);
            setVisible(@ptrCast(g_wired_row), true);
        },
        .disconnected, .off => {
            setRow(g_wired_row, "Wired", "Cable unplugged");
            setVisible(@ptrCast(g_wired_row), true);
        },
        .none => setVisible(@ptrCast(g_wired_row), false),
    }
}

/// "Connected for 2 h 14 min" (or plain "Connected" when the start isn't
/// known), refreshed every second.
fn renderVpnHead() void {
    const st = &g_state;
    if (st.n_vpns == 0) return;
    const v = &st.vpns[0];
    const conn = st.connFor(v.uuid.slice());
    const name: []const u8 = if (conn) |c| c.name.slice() else "VPN";
    const since = if (v.since > 0) v.since else g_watched_since;
    var buf: [128]u8 = undefined;
    var db: [32]u8 = undefined;
    const sub = if (since > 0)
        std.fmt.bufPrint(&buf, "Connected for {s}", .{net.fmtDuration(&db, now() - since)}) catch "Connected"
    else
        "Connected";
    setRow(g_vpn_row, name, sub);
}

fn renderVpn() void {
    const st = &g_state;
    const up = st.nm == .ok and st.n_vpns > 0;
    setVisible(@ptrCast(g_vpn_disconnect), up);
    setVisible(@ptrCast(g_tunnel_row), up);
    setVisible(@ptrCast(g_route_row), up);
    setVisible(@ptrCast(g_speed_row), up);
    if (g_vpn_icon) |ic| gtk.gtk_image_set_from_icon_name(ic, if (up) "network-vpn-symbolic" else "network-vpn-disconnected-symbolic");
    if (!up) {
        setRow(g_vpn_row, "Disconnected", if (st.n_conns == 0)
            "No VPN is set up yet. Add VPN imports a WireGuard or OpenVPN file."
        else
            "No VPN is connected. Connect one from the list below.");
        g_shown_uuid.set("");
        g_watched_since = 0;
        g_rate_valid = false;
        return;
    }
    const v = &st.vpns[0];
    // A VPN this window watched come up: its start is known even without
    // NetworkManager's timestamp.
    if (!std.mem.eql(u8, g_shown_uuid.slice(), v.uuid.slice())) {
        g_watched_since = if (g_have_state) now() else 0;
        g_shown_uuid.set(v.uuid.slice());
        g_rate_valid = false;
    }
    renderVpnHead();

    const conn = st.connFor(v.uuid.slice());
    const kind = net.kindLabel(if (conn) |c| c.kind else .vpn, v.vtype.slice());
    var buf: [256]u8 = undefined;
    var w: usize = 0;
    const a = std.fmt.bufPrint(buf[w..], "{s} \u{00b7} interface {s}", .{ kind, if (v.iface.len > 0) v.iface.slice() else "unknown" }) catch "";
    w += a.len;
    if (v.addr.len > 0) {
        const b = std.fmt.bufPrint(buf[w..], " \u{00b7} your address {s}", .{v.addr.slice()}) catch "";
        w += b.len;
    }
    setRow(g_tunnel_row, "Tunnel", buf[0..w]);

    var rb: [256]u8 = undefined;
    w = 0;
    if (v.gateway.len > 0) {
        const b = std.fmt.bufPrint(rb[w..], "Server {s}", .{v.gateway.slice()}) catch "";
        w += b.len;
    }
    if (v.dns.len > 0) {
        const b = std.fmt.bufPrint(rb[w..], "{s}DNS {s}", .{ if (w > 0) " \u{00b7} " else "", v.dns.slice() }) catch "";
        w += b.len;
    }
    setRow(g_route_row, "Server and DNS", if (w > 0) rb[0..w] else "Not reported by this connection.");
    renderSpeed(false);
}

/// Download and upload through the tunnel. `advance` is the once-a-second
/// tick; without it only the totals are redrawn.
fn renderSpeed(advance: bool) void {
    const st = &g_state;
    if (st.n_vpns == 0) return;
    const iface = st.vpns[0].iface.slice();
    const rx = readCounter(iface, "rx_bytes");
    const tx = readCounter(iface, "tx_bytes");
    if (iface.len == 0 or rx == null or tx == null) {
        setRow(g_speed_row, "Throughput", "No traffic counters for this tunnel.");
        g_rate_valid = false;
        return;
    }
    var down: u64 = 0;
    var up: u64 = 0;
    const same = g_rate_valid and std.mem.eql(u8, g_rate_iface.slice(), iface);
    if (same and rx.? >= g_rx_prev and tx.? >= g_tx_prev) {
        down = rx.? - g_rx_prev;
        up = tx.? - g_tx_prev;
    }
    if (advance or !same) {
        g_rate_iface.set(iface);
        g_rx_prev = rx.?;
        g_tx_prev = tx.?;
        g_rate_valid = true;
    }
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;
    var b4: [24]u8 = undefined;
    var title: [96]u8 = undefined;
    var sub: [128]u8 = undefined;
    const t = std.fmt.bufPrint(&title, "\u{2193} {s}/s   \u{2191} {s}/s", .{ net.fmtBytes(&b1, down), net.fmtBytes(&b2, up) }) catch "Throughput";
    const s = std.fmt.bufPrint(&sub, "Throughput \u{00b7} {s} received and {s} sent since it connected", .{ net.fmtBytes(&b3, rx.?), net.fmtBytes(&b4, tx.?) }) catch "Throughput";
    if (advance or !same) setRow(g_speed_row, t, s);
}

fn savedSignature(buf: []u8) usize {
    var w: usize = 0;
    for (g_state.conns[0..g_state.n_conns]) |*c| {
        const s = std.fmt.bufPrint(buf[w..], "{s}|{d}|{d}|{s};", .{ c.uuid.slice(), @intFromBool(c.active), @intFromBool(c.autoconnect), c.name.slice() }) catch break;
        w += s.len;
    }
    return w;
}

fn renderSaved() void {
    const list = g_saved_list orelse return;
    var sig: [2048]u8 = undefined;
    const n = savedSignature(&sig);
    if (g_saved_drawn and n == g_saved_sig_len and std.mem.eql(u8, sig[0..n], g_saved_sig[0..n])) return;
    @memcpy(g_saved_sig[0..n], sig[0..n]);
    g_saved_sig_len = n;
    g_saved_drawn = true;

    gtk.gtk_list_box_remove_all(list);
    if (g_state.n_conns == 0) {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "No VPN connections yet");
        gtk.adw_action_row_set_subtitle(row, "Add VPN imports a WireGuard .conf or an OpenVPN .ovpn file from your provider.");
        gtk.gtk_list_box_append(list, @ptrCast(row));
        return;
    }
    for (g_state.conns[0..g_state.n_conns], 0..) |*c, i| {
        g_row_uuid[i] = c.uuid;
        g_row_name[i] = c.name;
        const row = gtk.adw_action_row_new();
        var tb: [256]u8 = undefined;
        gtk.adw_preferences_row_set_title(@ptrCast(row), markupZ(c.name.slice(), &tb));
        var sb: [160]u8 = undefined;
        const kind = net.kindLabel(c.kind, "");
        const sub = std.fmt.bufPrintZ(&sb, "{s} \u{00b7} {s}{s}", .{
            kind,
            if (c.active) "Connected" else "Not connected",
            if (c.autoconnect) " \u{00b7} connects automatically" else "",
        }) catch "VPN";
        gtk.adw_action_row_set_subtitle(row, sub.ptr);

        const tag: ?*anyopaque = @ptrFromInt(i + 1);
        const toggle = gtk.gtk_button_new_with_label(if (c.active) "Disconnect" else "Connect");
        gtk.gtk_widget_set_valign(@ptrCast(toggle), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(toggle), "clicked", if (c.active) @ptrCast(&onRowDisconnect) else @ptrCast(&onRowConnect), tag, null, 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(toggle));

        const remove = gtk.gtk_button_new_from_icon_name("user-trash-symbolic");
        gtk.gtk_widget_set_valign(@ptrCast(remove), gtk.ALIGN_CENTER);
        gtk.gtk_widget_add_css_class(@ptrCast(remove), "flat");
        hg.gtk_widget_set_tooltip_text(@ptrCast(remove), "Remove this connection");
        _ = gtk.g_signal_connect_data(@ptrCast(remove), "clicked", @ptrCast(&onRowRemove), tag, null, 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(remove));

        gtk.gtk_list_box_append(list, @ptrCast(row));
    }
}

fn render() void {
    renderLinks();
    renderVpn();
    renderSaved();
}

// ---------------------------------------------------------------------
// Refreshing
// ---------------------------------------------------------------------

const REFRESH_ARGV = [_]?[*:0]const u8{ "/bin/sh", "-c", net.SCRIPT.ptr, null };

fn onRefreshDone(_: bool, out: []const u8) void {
    g_busy = false;
    net.parse(out, &g_state);
    render();
    g_have_state = true;
}

fn refresh() void {
    if (g_busy) return;
    g_busy = true;
    if (!run(&REFRESH_ARGV, onRefreshDone)) g_busy = false;
}

fn onTick(_: ?*anyopaque) callconv(.c) c_int {
    const page = g_page orelse return 0;
    // Only while the page is on screen: no nmcli, no wake-ups worth
    // mentioning, when Settings shows something else.
    if (gtk_widget_get_mapped(@ptrCast(page)) == 0) {
        g_ticks = 0;
        g_rate_valid = false;
        return 1;
    }
    if (g_ticks % 4 == 0) refresh();
    g_ticks +%= 1;
    if (g_state.nm == .ok and g_state.n_vpns > 0) {
        renderVpnHead();
        renderSpeed(true);
    }
    return 1;
}

// ---------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------

fn onActionDone(ok: bool, out: []const u8) void {
    if (ok) {
        setMessage("");
    } else {
        const text = std.mem.trim(u8, out, " \t\r\n");
        setMessage(if (text.len > 0) text else "NetworkManager could not do that.");
    }
    refresh();
}

/// `nmcli connection <verb> uuid <uuid>`.
fn connectionAction(verb: [*:0]const u8, uuid: []const u8) void {
    var ub: [48]u8 = undefined;
    const uz = std.fmt.bufPrintZ(&ub, "{s}", .{uuid}) catch return;
    const argv = [_]?[*:0]const u8{ "nmcli", "--wait", "20", "connection", verb, "uuid", uz.ptr, null };
    if (!run(&argv, onActionDone)) setMessage("nmcli could not be started.");
}

fn rowIndex(user_data: ?*anyopaque) ?usize {
    const tag = @intFromPtr(user_data);
    if (tag == 0 or tag > net.MAX_CONNS) return null;
    return tag - 1;
}

fn onRowConnect(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const i = rowIndex(user_data) orelse return;
    setMessage("Connecting\u{2026}");
    connectionAction("up", g_row_uuid[i].slice());
}

fn onRowDisconnect(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const i = rowIndex(user_data) orelse return;
    connectionAction("down", g_row_uuid[i].slice());
}

fn onDisconnectActive(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (g_state.n_vpns == 0) return;
    connectionAction("down", g_state.vpns[0].uuid.slice());
}

fn onRemoveResponse(_: *anyopaque, response: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    if (!std.mem.eql(u8, std.mem.span(response), "remove")) return;
    if (g_pending_delete.len == 0) return;
    connectionAction("delete", g_pending_delete.slice());
    g_pending_delete.set("");
}

fn onRowRemove(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const i = rowIndex(user_data) orelse return;
    g_pending_delete = g_row_uuid[i];
    var hb: [200]u8 = undefined;
    const heading = std.fmt.bufPrintZ(&hb, "Remove \u{201c}{s}\u{201d}?", .{g_row_name[i].slice()}) catch "Remove this VPN?";
    const dialog = adw_alert_dialog_new(heading.ptr, "The saved connection and its keys are deleted from this computer. To use it again you would import its file again.");
    adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
    adw_alert_dialog_add_response(dialog, "remove", "Remove");
    adw_alert_dialog_set_response_appearance(dialog, "remove", ADW_RESPONSE_DESTRUCTIVE);
    adw_alert_dialog_set_default_response(dialog, "cancel");
    adw_alert_dialog_set_close_response(dialog, "cancel");
    _ = gtk.g_signal_connect_data(dialog, "response", @ptrCast(&onRemoveResponse), null, null, 0);
    if (parent_window) |w| hg.adw_dialog_present(@ptrCast(dialog), w);
}

var g_file_dialog: ?*gtk.GtkFileDialog = null;

fn onVpnFilePicked(source: ?*anyopaque, res: *gtk.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const dlg = source orelse return;
    const file = gtk.gtk_file_dialog_open_finish(@ptrCast(dlg), res, null) orelse return; // dismissed
    defer gtk.g_object_unref(@ptrCast(file));
    const path_z = gtk.g_file_get_path(file) orelse return;
    const path = std.mem.span(path_z);
    const kind = net.importType(path) orelse {
        setMessage("That file is neither a WireGuard .conf nor an OpenVPN .ovpn file.");
        return;
    };
    setMessage("Importing\u{2026}");
    const argv = [_]?[*:0]const u8{ "nmcli", "connection", "import", "type", kind.ptr, "file", path_z, null };
    if (!run(&argv, onActionDone)) setMessage("nmcli could not be started.");
}

fn onAddVpn(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (g_file_dialog == null) {
        g_file_dialog = gtk.gtk_file_dialog_new();
        gtk.gtk_file_dialog_set_title(g_file_dialog.?, "VPN file (WireGuard .conf or OpenVPN .ovpn)");
    }
    gtk.gtk_file_dialog_open(g_file_dialog.?, @ptrCast(parent_window), null, onVpnFilePicked, null);
}

fn onWifiNetworks(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    // NetworkManager's own chooser, in a floating terminal.
    launch(&[_]?[*:0]const u8{ "kitty", "--class", "perihelion-float", "-e", "nmtui-connect", null });
}

fn onRefreshClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    setMessage("");
    refresh();
}

// ---------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------

fn infoRow(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, icon: ?[:0]const u8) *gtk.AdwActionRow {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), title);
    if (icon) |ic| gtk.adw_action_row_add_prefix(row, @ptrCast(gtk.gtk_image_new_from_icon_name(ic)));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
    return row;
}

fn suffixButton(row: *gtk.AdwActionRow, label: [:0]const u8, handler: gtk.GCallback) *gtk.GtkButton {
    const btn = gtk.gtk_button_new_with_label(label);
    gtk.gtk_widget_set_valign(@ptrCast(btn), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(btn), "clicked", handler, null, null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(btn));
    return btn;
}

pub fn build() *gtk.GtkBox {
    const outer = hp.pageBox();
    g_page = outer;

    // -- Wi-Fi and wired ------------------------------------------------
    const links = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(links, "Connection");
    {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Wi-Fi");
        gtk.adw_action_row_set_subtitle(row, "Checking\u{2026}");
        const icon = gtk.gtk_image_new_from_icon_name("network-wireless-symbolic");
        gtk.adw_action_row_add_prefix(row, @ptrCast(icon));
        g_wifi_icon = icon;
        if (access("/usr/bin/nmtui-connect", 0) == 0 and access("/usr/bin/kitty", 0) == 0) {
            _ = suffixButton(row, "Networks", @ptrCast(&onWifiNetworks));
        }
        gtk.adw_preferences_group_add(links, @ptrCast(row));
        g_wifi_row = row;
    }
    g_wired_row = infoRow(links, "Wired", "network-wired-symbolic");
    setVisible(@ptrCast(g_wired_row), false);
    gtk.gtk_box_append(outer, @ptrCast(links));

    // -- VPN status -----------------------------------------------------
    const vpn = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(vpn, "VPN");
    gtk.adw_preferences_group_set_description(vpn, "WireGuard and OpenVPN connections, managed by NetworkManager.");
    {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Disconnected");
        gtk.adw_action_row_set_subtitle(row, "Checking\u{2026}");
        const icon = gtk.gtk_image_new_from_icon_name("network-vpn-disconnected-symbolic");
        gtk.adw_action_row_add_prefix(row, @ptrCast(icon));
        g_vpn_icon = icon;
        const btn = suffixButton(row, "Disconnect", @ptrCast(&onDisconnectActive));
        gtk.gtk_widget_add_css_class(@ptrCast(btn), "destructive-action");
        g_vpn_disconnect = btn;
        gtk.adw_preferences_group_add(vpn, @ptrCast(row));
        g_vpn_row = row;
    }
    g_tunnel_row = infoRow(vpn, "Tunnel", null);
    g_route_row = infoRow(vpn, "Server and DNS", null);
    g_speed_row = infoRow(vpn, "Throughput", null);
    setVisible(@ptrCast(g_vpn_disconnect), false);
    setVisible(@ptrCast(g_tunnel_row), false);
    setVisible(@ptrCast(g_route_row), false);
    setVisible(@ptrCast(g_speed_row), false);
    gtk.gtk_box_append(outer, @ptrCast(vpn));

    // -- Saved connections ----------------------------------------------
    const saved = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(saved, "Saved VPN connections");
    gtk.gtk_box_append(outer, @ptrCast(saved));
    g_saved_list = hp.newListBox();
    gtk.gtk_list_box_set_selection_mode(g_saved_list.?, 0); // GTK_SELECTION_NONE
    gtk.gtk_box_append(outer, @ptrCast(g_saved_list.?));

    hp.appendActionButton(outer, "Add VPN", @ptrCast(&onAddVpn), null);
    hp.appendActionButton(outer, "Refresh", @ptrCast(&onRefreshClicked), null);

    const message = gtk.gtk_label_new("");
    gtk.gtk_label_set_wrap(message, 1);
    gtk.gtk_label_set_xalign(message, 0.5);
    gtk.gtk_widget_add_css_class(@ptrCast(message), "dim-label");
    gtk.gtk_box_append(outer, @ptrCast(message));
    g_message = message;
    setVisible(@ptrCast(message), false);

    g_saved_drawn = false;
    refresh();
    _ = gtk.g_timeout_add(1000, onTick, null);
    return outer;
}
