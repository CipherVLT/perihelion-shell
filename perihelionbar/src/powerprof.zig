//! Power-profile state for the bar's Control Center, parsed from
//! `powerprofilesctl list` (power-profiles-daemon 0.30, Fedora 45). No
//! processes here: the bar runs the command while the panel is open.
//!
//! `list` prints one block per profile, the active one marked with '*':
//!   "* balanced:" / "  power-saver:" followed by indented "CpuDriver:",
//!   "PlatformDriver:" and "Degraded:" lines. `get` prints just the active
//!   name and `set <name>` accepts only names the daemon reports.
//! No daemon: the command fails (no blocks), which reads as unavailable.
//!
//! Tests: `zig build test-powerprof`.

const std = @import("std");

pub const MAX_READ: usize = 8 * 1024;
pub const MAX_PROFILES: usize = 6;

pub const Profiles = struct {
    names: [MAX_PROFILES][24]u8 = undefined,
    lens: [MAX_PROFILES]usize = @as([MAX_PROFILES]usize, @splat(0)),
    count: usize = 0,
    active: ?usize = null,

    pub fn name(self: *const Profiles, i: usize) []const u8 {
        return self.names[i][0..self.lens[i]];
    }

    pub fn available(self: *const Profiles) bool {
        return self.count > 0 and self.active != null;
    }

    pub fn activeName(self: *const Profiles) []const u8 {
        return if (self.active) |a| self.name(a) else "";
    }

    fn has(self: *const Profiles, n: []const u8) bool {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.name(i), n)) return true;
        }
        return false;
    }
};

/// Profile names are plain lowercase words with dashes; anything else is
/// not a header line.
fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > 24) return false;
    for (n) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return true;
}

pub fn parseList(text: []const u8) Profiles {
    var p = Profiles{};
    var it = std.mem.splitScalar(u8, text[0..@min(text.len, MAX_READ)], '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (line.len < 3) continue;
        const marker = line[0];
        if (marker != '*' and marker != ' ') continue;
        if (line[1] != ' ' or line[line.len - 1] != ':') continue;
        const n = line[2 .. line.len - 1];
        if (!validName(n) or p.has(n) or p.count == MAX_PROFILES) continue;
        @memcpy(p.names[p.count][0..n.len], n);
        p.lens[p.count] = n.len;
        if (marker == '*') p.active = p.count;
        p.count += 1;
    }
    return p;
}

/// The click order: power-saver -> balanced -> performance -> power-saver,
/// over the profiles the daemon has (others come after, in its order).
pub fn next(p: *const Profiles) ?[]const u8 {
    if (!p.available()) return null;
    const order = [_][]const u8{ "power-saver", "balanced", "performance" };
    var seq: [MAX_PROFILES]usize = undefined;
    var n: usize = 0;
    for (order) |o| {
        for (0..p.count) |i| {
            if (std.mem.eql(u8, p.name(i), o)) {
                seq[n] = i;
                n += 1;
            }
        }
    }
    for (0..p.count) |i| {
        var known = false;
        for (order) |o| {
            if (std.mem.eql(u8, p.name(i), o)) known = true;
        }
        if (!known) {
            seq[n] = i;
            n += 1;
        }
    }
    if (n < 2) return null;
    for (seq[0..n], 0..) |idx, k| {
        if (idx == p.active.?) return p.name(seq[(k + 1) % n]);
    }
    return null;
}

/// Short label for the pill's state line.
pub fn label(n: []const u8) []const u8 {
    if (std.mem.eql(u8, n, "power-saver")) return "Saver";
    if (std.mem.eql(u8, n, "balanced")) return "Balanced";
    if (std.mem.eql(u8, n, "performance")) return "Performance";
    return n;
}

// --- tests ------------------------------------------------------------------

const LIST3 = "  performance:\n    CpuDriver:\tamd_pstate\n    PlatformDriver:\tplatform_profile\n    Degraded:   no\n\n" ++
    "* balanced:\n    CpuDriver:\tamd_pstate\n    PlatformDriver:\tplatform_profile\n\n" ++
    "  power-saver:\n    CpuDriver:\tamd_pstate\n    PlatformDriver:\tplatform_profile\n";

test "list: three profiles, balanced active, cycle order" {
    const p = parseList(LIST3);
    try std.testing.expectEqual(@as(usize, 3), p.count);
    try std.testing.expectEqualStrings("balanced", p.activeName());
    try std.testing.expectEqualStrings("performance", next(&p).?);
    try std.testing.expectEqualStrings("Balanced", label(p.activeName()));
}

test "list: two profiles (no performance), wrap around" {
    const p = parseList("  balanced:\n    PlatformDriver:\tplaceholder\n\n* power-saver:\n    PlatformDriver:\tplaceholder\n");
    try std.testing.expectEqual(@as(usize, 2), p.count);
    try std.testing.expectEqualStrings("balanced", next(&p).?);
    const q = parseList("* balanced:\n  power-saver:\n");
    try std.testing.expectEqualStrings("power-saver", next(&q).?);
    const r = parseList("  power-saver:\n  balanced:\n* performance:\n");
    try std.testing.expectEqualStrings("power-saver", next(&r).?);
}

test "list: no daemon, garbage, no active marker, one profile" {
    try std.testing.expect(!parseList("").available());
    try std.testing.expect(!parseList("Traceback (most recent call last):\n  File x, line 1:\nGLib.GError: g-dbus-error-quark: The name is not activatable (2)\n").available());
    try std.testing.expect(!parseList("  balanced:\n  power-saver:\n").available());
    try std.testing.expect(next(&parseList("* balanced:\n")) == null);
    try std.testing.expect(next(&parseList("")) == null);
    var big: [MAX_READ * 2]u8 = undefined;
    @memset(&big, '*');
    try std.testing.expect(!parseList(&big).available());
}
