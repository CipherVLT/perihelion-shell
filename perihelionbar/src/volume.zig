//! Volume parsing and percent maths shared by the bar (the volume module,
//! its mixer popup, the OSD and the Control Center slider) and the shell's
//! Glance Media tab, so both read pactl the same way and a slider at the
//! same spot means the same percentage. Pure: text in, numbers out.
//! `zig build test-volume`.

const std = @import("std");

/// First `NN%` in `line` (pactl's "Volume: front-left: 26214 /  40% / ..."
/// reports the front-left channel first), saturated to u8, or null when
/// there is none.
pub fn firstPercent(line: []const u8) ?u8 {
    const pct = std.mem.indexOfScalar(u8, line, '%') orelse return null;
    var s = pct;
    while (s > 0 and line[s - 1] >= '0' and line[s - 1] <= '9') : (s -= 1) {}
    if (s == pct) return null;
    const v = std.fmt.parseInt(u16, line[s..pct], 10) catch return null;
    return @intCast(@min(v, 255));
}

/// A pactl `Mute: yes|no` line (already trimmed): true/false, or null when
/// `line` isn't a mute line.
pub fn muteLine(line: []const u8) ?bool {
    if (!std.mem.startsWith(u8, line, "Mute:")) return null;
    return std.mem.eql(u8, std.mem.trim(u8, line["Mute:".len..], " \t"), "yes");
}

/// Thumb x for a 0-100 value on a track from x0 to x1.
pub fn sliderValToX(x0: i64, x1: i64, val: u8) i64 {
    return x0 + @divTrunc((x1 - x0) * @as(i64, val), 100);
}

/// 0-100 value for a pointer x on a track (clamped for overshoot; a
/// degenerate track reads 0).
pub fn sliderXToVal(x0: i64, x1: i64, x: i64) u8 {
    if (x1 <= x0) return 0;
    const v = @divTrunc((x - x0) * 100, x1 - x0);
    if (v < 0) return 0;
    if (v > 100) return 100;
    return @intCast(v);
}

/// The level as shown next to a slider: "muted" or "NN%".
pub fn valueText(muted: bool, pct: u8, buf: []u8) []const u8 {
    if (muted) return "muted";
    return std.fmt.bufPrint(buf, "{d}%", .{pct}) catch "?";
}

/// Speaker icon tier for a 0-100 volume (wireplumber's "default"
/// format-icons: low/medium/high, U+F026/F027/F028).
pub fn iconFor(pct: u8) []const u8 {
    return if (pct >= 67) "\u{f028}" else if (pct >= 34) "\u{f027}" else "\u{f026}";
}

/// The bar's volume poll text ("<digits>[\nMUTED]"): the level, the mute
/// flag, and the digits for labels. `ok` is false on empty or garbled
/// output (PipeWire down, unknown sink): show nothing rather than stale.
pub const Poll = struct {
    pct: u8 = 0,
    muted: bool = false,
    text: []const u8 = "",
    ok: bool = false,
};

pub fn parsePoll(text: []const u8, buf: []u8) Poll {
    var it = std.mem.splitScalar(u8, text, '\n');
    var digits: []const u8 = "";
    var muted = false;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "MUTED")) {
            muted = true;
            continue;
        }
        if (digits.len == 0) {
            var all_digits = true;
            for (line) |c| {
                if (c < '0' or c > '9') {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) digits = line;
        }
    }
    if (digits.len == 0) return .{};
    const pct: u8 = @intCast(@min(std.fmt.parseInt(u32, digits, 10) catch 0, 255));
    const n = @min(digits.len, buf.len);
    @memcpy(buf[0..n], digits[0..n]);
    return .{ .pct = pct, .muted = muted, .text = buf[0..n], .ok = true };
}

// --- tests --------------------------------------------------------------------

const tt = std.testing;

test "firstPercent: pactl lines, saturation, nothing to read" {
    try tt.expectEqual(@as(?u8, 40), firstPercent("Volume: front-left: 26214 /  40% / -23.88 dB,   front-right: 26214 /  45% / -20 dB"));
    try tt.expectEqual(@as(?u8, 100), firstPercent("Volume: mono: 65536 / 100% / 0.00 dB"));
    try tt.expectEqual(@as(?u8, 0), firstPercent("Volume: mono: 10 /  0% / -inf dB"));
    try tt.expectEqual(@as(?u8, 135), firstPercent("Volume: front-left: 88474 / 135% / 7.82 dB"));
    try tt.expectEqual(@as(?u8, 255), firstPercent("Volume: 999%")); // saturates
    try tt.expect(firstPercent("Volume:") == null);
    try tt.expect(firstPercent("%") == null);
    try tt.expect(firstPercent("") == null);
}

test "muteLine" {
    try tt.expectEqual(@as(?bool, true), muteLine("Mute: yes"));
    try tt.expectEqual(@as(?bool, false), muteLine("Mute: no"));
    try tt.expectEqual(@as(?bool, true), muteLine("Mute:\tyes "));
    try tt.expect(muteLine("Volume: 40%") == null);
}

test "slider: value -> x -> value, clamping, degenerate track" {
    const x0: i64 = 14;
    const x1: i64 = 186;
    try tt.expectEqual(x0, sliderValToX(x0, x1, 0));
    try tt.expectEqual(x1, sliderValToX(x0, x1, 100));
    try tt.expectEqual(@as(u8, 0), sliderXToVal(x0, x1, x0));
    try tt.expectEqual(@as(u8, 100), sliderXToVal(x0, x1, x1));
    try tt.expectEqual(@as(u8, 50), sliderXToVal(x0, x1, @divTrunc(x0 + x1, 2)));
    try tt.expectEqual(@as(u8, 0), sliderXToVal(x0, x1, x0 - 40));
    try tt.expectEqual(@as(u8, 100), sliderXToVal(x0, x1, x1 + 40));
    try tt.expectEqual(@as(u8, 0), sliderXToVal(50, 50, 60));
    // Truncating maths: one pixel short of a step stays below it.
    try tt.expectEqual(@as(u8, 49), sliderXToVal(0, 200, 99));
    // Every value lands back on itself through the thumb position.
    var v: u8 = 0;
    while (v <= 100) : (v += 1) try tt.expectEqual(v, sliderXToVal(0, 300, sliderValToX(0, 300, v)));
}

test "valueText and iconFor" {
    var b: [8]u8 = undefined;
    try tt.expectEqualStrings("muted", valueText(true, 80, &b));
    try tt.expectEqualStrings("80%", valueText(false, 80, &b));
    try tt.expectEqualStrings("\u{f026}", iconFor(0));
    try tt.expectEqualStrings("\u{f026}", iconFor(33));
    try tt.expectEqualStrings("\u{f027}", iconFor(34));
    try tt.expectEqualStrings("\u{f027}", iconFor(66));
    try tt.expectEqualStrings("\u{f028}", iconFor(67));
}

test "parsePoll" {
    var b: [16]u8 = undefined;
    const p1 = parsePoll("67\n", &b);
    try tt.expect(p1.ok and !p1.muted);
    try tt.expectEqual(@as(u8, 67), p1.pct);
    try tt.expectEqualStrings("67", p1.text);
    const p2 = parsePoll("0\nMUTED\n", &b);
    try tt.expect(p2.ok and p2.muted);
    try tt.expectEqual(@as(u8, 0), p2.pct);
    try tt.expect(!parsePoll("", &b).ok);
    try tt.expect(!parsePoll("hello\n", &b).ok);
    try tt.expectEqual(@as(u8, 255), parsePoll("400\n", &b).pct);
}
