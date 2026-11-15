//! NetworkManager state for Perihelion Settings' Network page.
//!
//! No GTK here: the one shell script that asks nmcli for everything in a
//! single run (SCRIPT), the parser for what it prints, and the small text
//! formatters the page uses. Kept apart so it can be unit-tested
//! (`zig test src/network.zig`) and so the page stays a thin view.

const std = @import("std");

/// A short string stored in place (no allocation); longer input is cut.
pub fn Str(comptime N: usize) type {
    return struct {
        buf: [N]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn set(self: *Self, s: []const u8) void {
            const n = @min(s.len, N);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

pub const MAX_CONNS = 24;
pub const MAX_VPNS = 4;

pub const ConnKind = enum { vpn, wireguard };

/// A saved VPN connection (NetworkManager profile).
pub const Conn = struct {
    uuid: Str(40) = .{},
    name: Str(80) = .{},
    kind: ConnKind = .vpn,
    active: bool = false,
    autoconnect: bool = false,
    device: Str(16) = .{},
};

/// A VPN that is up right now.
pub const Vpn = struct {
    uuid: Str(40) = .{},
    /// The tunnel interface (wg0, tun0): where its traffic is counted.
    iface: Str(16) = .{},
    addr: Str(64) = .{},
    gateway: Str(64) = .{},
    dns: Str(96) = .{},
    /// NetworkManager's plugin name for plugin VPNs ("openvpn").
    vtype: Str(32) = .{},
    /// Unix time it came up (from Perihelion's NetworkManager dispatcher
    /// script), or 0 when not known.
    since: i64 = 0,
};

pub const Link = enum { none, off, disconnected, connecting, connected };

pub const NmState = enum { ok, missing, down };

pub const State = struct {
    nm: NmState = .ok,
    wifi: Link = .none,
    wifi_dev: Str(16) = .{},
    ssid: Str(64) = .{},
    signal: u8 = 0,
    security: Str(32) = .{},
    rate: Str(24) = .{},
    wired: Link = .none,
    wired_dev: Str(16) = .{},
    wired_name: Str(64) = .{},
    conns: [MAX_CONNS]Conn = undefined,
    n_conns: usize = 0,
    vpns: [MAX_VPNS]Vpn = undefined,
    n_vpns: usize = 0,

    pub fn connFor(self: *const State, uuid: []const u8) ?*const Conn {
        for (self.conns[0..self.n_conns]) |*c| {
            if (std.mem.eql(u8, c.uuid.slice(), uuid)) return c;
        }
        return null;
    }
};

/// Everything the page shows, in one run (about 50 ms). Sections start with
/// an "@@" line; `nmcli -t` separates fields with ':' and escapes a ':' or
/// '\' inside a value with a backslash.
pub const SCRIPT: [:0]const u8 =
    \\export LC_ALL=C
    \\command -v nmcli >/dev/null 2>&1 || { echo '@@nonm'; exit 0; }
    \\echo '@@dev'
    \\nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null || { echo '@@down'; exit 0; }
    \\echo '@@wifi'
    \\nmcli -t -f IN-USE,SIGNAL,SECURITY,RATE,SSID device wifi list --rescan no 2>/dev/null
    \\echo '@@conn'
    \\nmcli -t -f UUID,TYPE,ACTIVE,DEVICE,AUTOCONNECT,NAME connection show 2>/dev/null
    \\nmcli -t -f UUID,TYPE connection show --active 2>/dev/null | while IFS=: read -r u t; do
    \\  case "$t" in
    \\    vpn|wireguard)
    \\      echo "@@vpn $u"
    \\      nmcli -t -f GENERAL,IP4,VPN connection show uuid "$u" 2>/dev/null
    \\      [ -r "/run/perihelion/vpn/$u" ] && echo "SINCE:$(cat "/run/perihelion/vpn/$u")"
    \\      ;;
    \\  esac
    \\done
    \\echo '@@end'
;

/// Splits one `nmcli -t` line at its unescaped colons. Fields are unescaped
/// into `store`; returns how many were written to `out`.
pub fn splitTerse(line: []const u8, store: []u8, out: [][]const u8) usize {
    var n: usize = 0;
    var w: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < out.len) : (i += 1) {
        var c = line[i];
        if (c == '\\' and i + 1 < line.len) {
            i += 1;
            c = line[i];
        } else if (c == ':') {
            out[n] = store[start..w];
            n += 1;
            start = w;
            continue;
        }
        if (w < store.len) {
            store[w] = c;
            w += 1;
        }
    }
    if (n < out.len) {
        out[n] = store[start..w];
        n += 1;
    }
    return n;
}

fn linkOf(state: []const u8) Link {
    if (std.mem.startsWith(u8, state, "connected")) return .connected;
    if (std.mem.startsWith(u8, state, "connecting")) return .connecting;
    if (std.mem.startsWith(u8, state, "disconnected")) return .disconnected;
    if (std.mem.startsWith(u8, state, "unavailable")) return .off;
    return .none;
}

fn isSet(v: []const u8) bool {
    return v.len > 0 and !std.mem.eql(u8, v, "--");
}

const Section = enum { none, dev, wifi, conn, vpn };

pub fn parse(text: []const u8, st: *State) void {
    st.* = .{};
    var section: Section = .none;
    var cur: ?*Vpn = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "@@")) {
            const tag = line[2..];
            cur = null;
            section = .none;
            if (std.mem.eql(u8, tag, "nonm")) {
                st.nm = .missing;
            } else if (std.mem.eql(u8, tag, "down")) {
                st.nm = .down;
            } else if (std.mem.eql(u8, tag, "dev")) {
                section = .dev;
            } else if (std.mem.eql(u8, tag, "wifi")) {
                section = .wifi;
            } else if (std.mem.eql(u8, tag, "conn")) {
                section = .conn;
            } else if (std.mem.startsWith(u8, tag, "vpn ") and st.n_vpns < MAX_VPNS) {
                section = .vpn;
                st.vpns[st.n_vpns] = .{};
                cur = &st.vpns[st.n_vpns];
                cur.?.uuid.set(std.mem.trim(u8, tag[4..], " "));
                st.n_vpns += 1;
            }
            continue;
        }
        var store: [512]u8 = undefined;
        var f: [8][]const u8 = undefined;
        const n = splitTerse(line, &store, &f);
        switch (section) {
            .none => {},
            .dev => { // DEVICE, TYPE, STATE, CONNECTION
                if (n < 4) continue;
                const link = linkOf(f[2]);
                if (std.mem.eql(u8, f[1], "wifi")) {
                    if (@intFromEnum(link) > @intFromEnum(st.wifi)) {
                        st.wifi = link;
                        st.wifi_dev.set(f[0]);
                        if (link == .connected or link == .connecting) st.ssid.set(f[3]);
                    }
                } else if (std.mem.eql(u8, f[1], "ethernet")) {
                    if (@intFromEnum(link) > @intFromEnum(st.wired)) {
                        st.wired = link;
                        st.wired_dev.set(f[0]);
                        st.wired_name.set(f[3]);
                    }
                }
            },
            .wifi => { // IN-USE, SIGNAL, SECURITY, RATE, SSID
                if (n < 5 or f[0].len == 0 or f[0][0] != '*') continue;
                st.signal = std.fmt.parseInt(u8, f[1], 10) catch 0;
                st.security.set(f[2]);
                st.rate.set(f[3]);
                if (f[4].len > 0) st.ssid.set(f[4]);
            },
            .conn => { // UUID, TYPE, ACTIVE, DEVICE, AUTOCONNECT, NAME
                if (n < 6 or st.n_conns >= MAX_CONNS) continue;
                const kind: ConnKind = if (std.mem.eql(u8, f[1], "vpn"))
                    .vpn
                else if (std.mem.eql(u8, f[1], "wireguard"))
                    .wireguard
                else
                    continue;
                var c: Conn = .{ .kind = kind };
                c.uuid.set(f[0]);
                c.active = std.mem.eql(u8, f[2], "yes");
                if (isSet(f[3])) c.device.set(f[3]);
                c.autoconnect = std.mem.eql(u8, f[4], "yes");
                c.name.set(f[5]);
                st.conns[st.n_conns] = c;
                st.n_conns += 1;
            },
            .vpn => { // KEY:value lines of the GENERAL, IP4 and VPN sections
                const v = cur orelse continue;
                if (n < 2 or !isSet(f[1])) continue;
                const key = f[0];
                const val = f[1];
                if (std.mem.eql(u8, key, "GENERAL.IP-IFACE")) {
                    v.iface.set(val);
                } else if (std.mem.eql(u8, key, "GENERAL.DEVICES")) {
                    if (v.iface.len == 0) v.iface.set(val);
                } else if (std.mem.startsWith(u8, key, "IP4.ADDRESS")) {
                    if (v.addr.len == 0) v.addr.set(val);
                } else if (std.mem.eql(u8, key, "VPN.GATEWAY")) {
                    v.gateway.set(val);
                } else if (std.mem.eql(u8, key, "IP4.GATEWAY")) {
                    if (v.gateway.len == 0) v.gateway.set(val);
                } else if (std.mem.startsWith(u8, key, "IP4.DNS")) {
                    var joined: [96]u8 = undefined;
                    const s = if (v.dns.len == 0)
                        val
                    else
                        std.fmt.bufPrint(&joined, "{s}, {s}", .{ v.dns.slice(), val }) catch v.dns.slice();
                    v.dns.set(s);
                } else if (std.mem.eql(u8, key, "VPN.TYPE")) {
                    v.vtype.set(val);
                } else if (std.mem.eql(u8, key, "SINCE")) {
                    v.since = std.fmt.parseInt(i64, std.mem.trim(u8, val, " \t"), 10) catch 0;
                }
            },
        }
    }
}

/// "WireGuard", "OpenVPN", ... for a connection (and its plugin name).
pub fn kindLabel(kind: ConnKind, vtype: []const u8) []const u8 {
    if (kind == .wireguard) return "WireGuard";
    if (std.mem.indexOf(u8, vtype, "openvpn") != null) return "OpenVPN";
    if (std.mem.indexOf(u8, vtype, "openconnect") != null) return "OpenConnect";
    if (std.mem.indexOf(u8, vtype, "vpnc") != null) return "Cisco VPN";
    if (std.mem.indexOf(u8, vtype, "strongswan") != null or std.mem.indexOf(u8, vtype, "libreswan") != null) return "IPsec";
    if (std.mem.indexOf(u8, vtype, "l2tp") != null) return "L2TP";
    if (std.mem.indexOf(u8, vtype, "pptp") != null) return "PPTP";
    return "VPN";
}

/// What `nmcli connection import type …` takes for a config file, by its
/// extension: WireGuard's .conf or OpenVPN's .ovpn.
pub fn importType(path: []const u8) ?[:0]const u8 {
    if (std.ascii.endsWithIgnoreCase(path, ".conf")) return "wireguard";
    if (std.ascii.endsWithIgnoreCase(path, ".ovpn")) return "openvpn";
    return null;
}

/// "45 s", "12 min", "2 h 14 min", "3 d 4 h".
pub fn fmtDuration(buf: []u8, secs_in: i64) []const u8 {
    const secs: u64 = @intCast(@max(secs_in, 0));
    if (secs < 60) return std.fmt.bufPrint(buf, "{d} s", .{secs}) catch "";
    if (secs < 3600) return std.fmt.bufPrint(buf, "{d} min", .{secs / 60}) catch "";
    if (secs < 86400) return std.fmt.bufPrint(buf, "{d} h {d} min", .{ secs / 3600, (secs % 3600) / 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d} d {d} h", .{ secs / 86400, (secs % 86400) / 3600 }) catch "";
}

/// "512 B", "38 kB", "1.2 MB", "3.4 GB" (decimal units, as network speeds
/// are quoted).
pub fn fmtBytes(buf: []u8, bytes: u64) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    if (bytes < 1000) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";
    if (bytes < 1_000_000) return std.fmt.bufPrint(buf, "{d:.0} kB", .{b / 1e3}) catch "";
    if (bytes < 1_000_000_000) return std.fmt.bufPrint(buf, "{d:.1} MB", .{b / 1e6}) catch "";
    return std.fmt.bufPrint(buf, "{d:.2} GB", .{b / 1e9}) catch "";
}

test "splitTerse unescapes" {
    var store: [128]u8 = undefined;
    var f: [8][]const u8 = undefined;
    const n = splitTerse("a\\:b:c::d\\\\e", &store, &f);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("a:b", f[0]);
    try std.testing.expectEqualStrings("c", f[1]);
    try std.testing.expectEqualStrings("", f[2]);
    try std.testing.expectEqualStrings("d\\e", f[3]);
}

test "parse: wifi, saved connections, an active WireGuard tunnel" {
    const sample =
        \\@@dev
        \\wlp3s0:wifi:connected:Home Net
        \\wg-home:wireguard:connected:Home VPN
        \\enp2s0:ethernet:unavailable:
        \\lo:loopback:connected (externally):lo
        \\@@wifi
        \\ :48:WPA2:130 Mbit/s:Neighbour
        \\*:72:WPA2 WPA3:270 Mbit/s:Home Net
        \\@@conn
        \\11111111-2222-3333-4444-555555555555:802-11-wireless:yes:wlp3s0:yes:Home Net
        \\aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:wireguard:yes:wg-home:no:Home VPN
        \\99999999-8888-7777-6666-555555555555:vpn:no::no:Work\: Berlin
        \\@@vpn aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
        \\GENERAL.NAME:Home VPN
        \\GENERAL.DEVICES:wg-home
        \\GENERAL.IP-IFACE:wg-home
        \\GENERAL.STATE:activated
        \\IP4.ADDRESS[1]:10.2.0.2/32
        \\IP4.GATEWAY:
        \\IP4.DNS[1]:10.2.0.1
        \\IP4.DNS[2]:1.1.1.1
        \\SINCE:1763160000
        \\@@end
    ;
    var st: State = .{};
    parse(sample, &st);
    const t = std.testing;
    try t.expectEqual(NmState.ok, st.nm);
    try t.expectEqual(Link.connected, st.wifi);
    try t.expectEqualStrings("Home Net", st.ssid.slice());
    try t.expectEqual(@as(u8, 72), st.signal);
    try t.expectEqualStrings("270 Mbit/s", st.rate.slice());
    try t.expectEqual(Link.off, st.wired);
    try t.expectEqual(@as(usize, 2), st.n_conns);
    try t.expectEqual(ConnKind.wireguard, st.conns[0].kind);
    try t.expect(st.conns[0].active and !st.conns[0].autoconnect);
    try t.expectEqualStrings("Work: Berlin", st.conns[1].name.slice());
    try t.expect(!st.conns[1].active);
    try t.expectEqual(@as(usize, 1), st.n_vpns);
    const v = &st.vpns[0];
    try t.expectEqualStrings("wg-home", v.iface.slice());
    try t.expectEqualStrings("10.2.0.2/32", v.addr.slice());
    try t.expectEqualStrings("", v.gateway.slice());
    try t.expectEqualStrings("10.2.0.1, 1.1.1.1", v.dns.slice());
    try t.expectEqual(@as(i64, 1763160000), v.since);
    try t.expectEqualStrings("Home VPN", st.connFor(v.uuid.slice()).?.name.slice());
}

test "parse: an OpenVPN plugin connection rides on the Wi-Fi device" {
    const sample =
        \\@@dev
        \\wlp3s0:wifi:connected:Cafe
        \\tun0:tun:connected (externally):tun0
        \\@@conn
        \\99999999-8888-7777-6666-555555555555:vpn:yes:wlp3s0:no:Work
        \\@@vpn 99999999-8888-7777-6666-555555555555
        \\GENERAL.DEVICES:wlp3s0
        \\GENERAL.IP-IFACE:tun0
        \\GENERAL.VPN:yes
        \\IP4.ADDRESS[1]:10.8.0.6/24
        \\IP4.GATEWAY:10.8.0.1
        \\VPN.TYPE:openvpn
        \\VPN.GATEWAY:vpn.example.org
    ;
    var st: State = .{};
    parse(sample, &st);
    const v = &st.vpns[0];
    try std.testing.expectEqualStrings("tun0", v.iface.slice());
    try std.testing.expectEqualStrings("vpn.example.org", v.gateway.slice());
    try std.testing.expectEqualStrings("OpenVPN", kindLabel(st.conns[0].kind, v.vtype.slice()));
    try std.testing.expectEqual(@as(i64, 0), v.since);
}

test "parse: no NetworkManager" {
    var st: State = .{};
    parse("@@nonm\n", &st);
    try std.testing.expectEqual(NmState.missing, st.nm);
    parse("@@dev\n@@down\n", &st);
    try std.testing.expectEqual(NmState.down, st.nm);
}

test "formatters" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("45 s", fmtDuration(&b, 45));
    try std.testing.expectEqualStrings("12 min", fmtDuration(&b, 12 * 60 + 5));
    try std.testing.expectEqualStrings("2 h 14 min", fmtDuration(&b, 2 * 3600 + 14 * 60));
    try std.testing.expectEqualStrings("3 d 4 h", fmtDuration(&b, 3 * 86400 + 4 * 3600));
    try std.testing.expectEqualStrings("512 B", fmtBytes(&b, 512));
    try std.testing.expectEqualStrings("38 kB", fmtBytes(&b, 38_400));
    try std.testing.expectEqualStrings("1.2 MB", fmtBytes(&b, 1_200_000));
    try std.testing.expectEqualStrings("wireguard", importType("/home/a/Home.CONF").?);
    try std.testing.expect(importType("/home/a/notes.txt") == null);
}
