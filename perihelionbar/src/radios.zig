//! Wi-Fi and Bluetooth state for the bar's Control Center, parsed from
//! command output. No processes here: the bar runs the commands (only
//! while the panel is open) and hands their output in.
//!
//! Fedora 45 (NetworkManager 1.58, bluez 5.87):
//!   nmcli radio wifi                                  -> "enabled" | "disabled"
//!   nmcli -t -f TYPE,STATE device                     -> "wifi:connected" lines
//!   nmcli -t -f ACTIVE,SSID device wifi list --rescan no -> "yes:Home-5G" lines
//!     (terse mode escapes ':' and '\' with '\')
//!   bluetoothctl --timeout 2 show -> "Controller AA:BB:… (public)" then
//!     "\tPowered: yes|no"; "No default controller available" without one.
//! The radio switch reads "enabled" even with no Wi-Fi hardware, so the
//! device list decides whether Wi-Fi exists at all.
//!
//! Anything unrecognised reads as unavailable. Tests: `zig build test-radios`.

const std = @import("std");

/// Most bytes of command output looked at.
pub const MAX_READ: usize = 16 * 1024;

pub const Avail = enum { unknown, absent, off, on };

pub const Wifi = struct {
    state: Avail = .unknown,
    ssid_buf: [64]u8 = undefined,
    ssid_len: usize = 0,

    pub fn ssid(self: *const Wifi) []const u8 {
        return self.ssid_buf[0..self.ssid_len];
    }
};

/// Undoes nmcli's terse escaping ("My\:Net" -> "My:Net") into `out`.
pub fn unescapeTerse(s: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) i += 1;
        out[n] = s[i];
        n += 1;
    }
    return out[0..n];
}

/// Splits a terse line at its first unescaped ':'.
fn splitTerse(line: []const u8) ?struct { a: []const u8, b: []const u8 } {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == ':') return .{ .a = line[0..i], .b = line[i + 1 ..] };
    }
    return null;
}

/// Wi-Fi from the three nmcli outputs.
pub fn parseWifi(radio: []const u8, devices: []const u8, aps: []const u8) Wifi {
    var w = Wifi{};
    var have_dev = false;
    var it = std.mem.splitScalar(u8, devices[0..@min(devices.len, MAX_READ)], '\n');
    while (it.next()) |raw| {
        const parts = splitTerse(std.mem.trim(u8, raw, " \r")) orelse continue;
        if (!std.mem.eql(u8, parts.a, "wifi")) continue;
        // "unavailable" devices still exist (radio off shows that way).
        if (std.mem.eql(u8, parts.b, "unmanaged")) continue;
        have_dev = true;
    }
    if (!have_dev) {
        w.state = .absent;
        return w;
    }
    const r = std.mem.trim(u8, radio[0..@min(radio.len, 256)], " \t\r\n");
    if (std.mem.eql(u8, r, "enabled")) {
        w.state = .on;
    } else if (std.mem.eql(u8, r, "disabled")) {
        w.state = .off;
        return w;
    } else {
        w.state = .unknown;
        return w;
    }
    var ai = std.mem.splitScalar(u8, aps[0..@min(aps.len, MAX_READ)], '\n');
    while (ai.next()) |raw| {
        const parts = splitTerse(std.mem.trim(u8, raw, " \r")) orelse continue;
        if (!std.mem.eql(u8, parts.a, "yes")) continue;
        const s = unescapeTerse(parts.b, &w.ssid_buf);
        w.ssid_len = s.len;
        break;
    }
    return w;
}

/// Bluetooth from `bluetoothctl show`: absent (no controller, or bluetoothd
/// not answering), on or off.
pub fn parseBluetooth(show: []const u8) Avail {
    const t = show[0..@min(show.len, MAX_READ)];
    if (std.mem.indexOf(u8, t, "No default controller") != null) return .absent;
    if (std.mem.indexOf(u8, t, "Controller ") == null) return .absent;
    var it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "Powered:")) continue;
        const v = std.mem.trim(u8, line["Powered:".len..], " \t");
        if (std.mem.eql(u8, v, "yes")) return .on;
        if (std.mem.eql(u8, v, "no")) return .off;
    }
    return .unknown;
}

// --- tests ------------------------------------------------------------------

test "wifi: connected, ssid with an escaped colon" {
    const w = parseWifi("enabled\n", "ethernet:connected\nwifi:connected\nloopback:connected (externally)\n", "no:Neighbour\nyes:Home\\:5G\nno:Other\n");
    try std.testing.expectEqual(Avail.on, w.state);
    try std.testing.expectEqualStrings("Home:5G", w.ssid());
}

test "wifi: radio off, on without a network, no hardware, garbage" {
    try std.testing.expectEqual(Avail.off, parseWifi("disabled", "wifi:unavailable\n", "").state);
    const idle = parseWifi("enabled", "wifi:disconnected\n", "no:Cafe\n");
    try std.testing.expectEqual(Avail.on, idle.state);
    try std.testing.expectEqualStrings("", idle.ssid());
    try std.testing.expectEqual(Avail.absent, parseWifi("enabled", "ethernet:connected\n", "").state);
    try std.testing.expectEqual(Avail.absent, parseWifi("", "", "").state);
    try std.testing.expectEqual(Avail.absent, parseWifi("enabled", "wifi:unmanaged\n", "").state);
    try std.testing.expectEqual(Avail.unknown, parseWifi("Error: NetworkManager is not running.", "wifi:connected\n", "").state);
    var big: [MAX_READ * 2]u8 = undefined;
    @memset(&big, ':');
    try std.testing.expectEqual(Avail.absent, parseWifi(&big, &big, &big).state);
}

test "bluetooth: on, off, no controller, daemon down" {
    try std.testing.expectEqual(Avail.on, parseBluetooth("Controller 00:1A:7D:DA:71:13 (public)\n\tManufacturer: 0x0002\n\tName: deskbox\n\tPowered: yes\n\tPowerState: on\n"));
    try std.testing.expectEqual(Avail.off, parseBluetooth("Controller 00:1A:7D:DA:71:13 (public)\n\tPowered: no\n\tPowerState: off-blocked\n"));
    try std.testing.expectEqual(Avail.absent, parseBluetooth("No default controller available\n"));
    try std.testing.expectEqual(Avail.absent, parseBluetooth("Waiting to connect to bluetoothd..."));
    try std.testing.expectEqual(Avail.absent, parseBluetooth(""));
    try std.testing.expectEqual(Avail.unknown, parseBluetooth("Controller 00:11:22:33:44:55 (public)\n\tName: x\n"));
}
