//! Reminders service for the desktop Calendar card (perihelionbar-shell
//! widgets.zig CalendarWidget). Same shape as procs.zig / temps.zig: no
//! drawing and no fds. The card reads the file; this module parses it and
//! answers "what is due today and next".
//!
//! File format (~/.config/perihelionbar/reminders.txt), one per line:
//!     YYYY-MM-DD HH:MM [lead] text
//! `lead` is the number of days before the date to notify (0 = on the
//! day). It is optional, so a hand-written "2026-10-20 10:00 PayDay" works:
//! a non-numeric first token means the text starts right there. Blank
//! lines and lines starting with '#' are comments.
//!
//! Cost: parsing is a single pass over at most a few KiB, done only when
//! the file's bytes changed. upcoming() is a bounded insertion sort over
//! at most MAX entries.
//!
//! Tests: `zig build test-reminders` in perihelionbar/ (fake file text,
//! fixed "today" values; no clock or disk access).

const std = @import("std");

/// Most reminders the card keeps from the file (later lines are ignored).
pub const MAX: usize = 48;
/// Rows the Calendar card can list under the month grid.
pub const MAX_ROWS: usize = 6;

pub const Reminder = struct {
    y: i32,
    m: u8,
    d: u8,
    hh: u8,
    mm: u8,
    lead: u8,
    text_off: u16,
    text_len: u16,
    raw_len: u16,
    /// Notification state, owned by the card (reloads carry it across).
    fired: bool,
    /// The exact file line: reloads match on it to keep `fired`.
    raw: [176]u8,

    pub fn text(self: *const Reminder) []const u8 {
        return self.raw[self.text_off .. self.text_off + self.text_len];
    }

    pub fn line(self: *const Reminder) []const u8 {
        return self.raw[0..self.raw_len];
    }

    /// Days since 1970-01-01 for the reminder's date.
    pub fn day(self: *const Reminder) i64 {
        return daysFromCivil(self.y, self.m, self.d);
    }

    /// Minutes since midnight; with day() it gives the sort order.
    pub fn minuteOfDay(self: *const Reminder) u16 {
        return @as(u16, self.hh) * 60 + self.mm;
    }
};

/// Parses "YYYY-MM-DD HH:MM [lead] text" into `out` (raw copy included).
/// False for anything malformed: wrong shape, out-of-range fields, a lead
/// with no text after it, or a line longer than Reminder.raw.
pub fn parseLine(src: []const u8, out: *Reminder) bool {
    if (src.len < 18) return false;
    if (src[4] != '-' or src[7] != '-' or src[10] != ' ' or src[13] != ':' or src[16] != ' ') return false;
    if (src.len > out.raw.len) return false;
    const y = std.fmt.parseInt(i32, src[0..4], 10) catch return false;
    const m = std.fmt.parseInt(u8, src[5..7], 10) catch return false;
    const d = std.fmt.parseInt(u8, src[8..10], 10) catch return false;
    const hh = std.fmt.parseInt(u8, src[11..13], 10) catch return false;
    const mm = std.fmt.parseInt(u8, src[14..16], 10) catch return false;
    var i: usize = 17;
    while (i < src.len and src[i] != ' ') i += 1;
    const lead_opt: ?u8 = std.fmt.parseInt(u8, src[17..i], 10) catch null;
    if (lead_opt != null and (i >= src.len or i + 1 >= src.len)) return false; // lead but no text
    const lead = lead_opt orelse 0;
    var text_start: usize = if (lead_opt != null) i + 1 else 17;
    while (text_start < src.len and src[text_start] == ' ') text_start += 1;
    if (text_start >= src.len) return false; // text required
    if (y < 1970 or y > 2100 or m < 1 or m > 12 or d < 1 or d > 31) return false;
    if (hh > 23 or mm > 59 or lead > 60) return false;
    @memcpy(out.raw[0..src.len], src);
    out.raw_len = @intCast(src.len);
    out.y = y;
    out.m = m;
    out.d = d;
    out.hh = hh;
    out.mm = mm;
    out.lead = lead;
    out.text_off = @intCast(text_start);
    out.text_len = @intCast(src.len - text_start);
    out.fired = false;
    return true;
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
/// days_from_civil).
pub fn daysFromCivil(y_in: i32, m: u8, d: u8) i64 {
    const y: i64 = @as(i64, y_in) - @as(i64, if (m <= 2) 1 else 0);
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const mp: i64 = @mod(@as(i64, m) + 9, 12);
    const doy: i64 = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Indices into `list` of the reminders dated today or later, earliest
/// first (date, then time, then file order), at most `out.len` of them.
/// Today's entries stay in even after their time passed: the card shows
/// the whole of today.
pub fn upcoming(list: []const Reminder, today: i64, out: []usize) usize {
    var n: usize = 0;
    for (list, 0..) |*r, idx| {
        const rd = r.day();
        if (rd < today) continue;
        // Find the slot: after every entry that sorts before or equal (so
        // equal keys keep file order).
        var pos: usize = n;
        while (pos > 0) {
            const o = &list[out[pos - 1]];
            const od = o.day();
            if (od < rd or (od == rd and o.minuteOfDay() <= r.minuteOfDay())) break;
            pos -= 1;
        }
        if (pos >= out.len) continue; // sorts after everything kept
        const last = @min(n, out.len - 1);
        var k: usize = last;
        while (k > pos) : (k -= 1) out[k] = out[k - 1];
        out[pos] = idx;
        if (n < out.len) n += 1;
    }
    return n;
}

const WEEKDAYS = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const MONTHS = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Short day label for a reminder row: "Today", "Tomorrow", the weekday
/// within the coming week ("Thu"), else "20 Nov". Returns a slice of
/// `buf` or a static string.
pub fn dayLabel(r: *const Reminder, today: i64, buf: []u8) []const u8 {
    const rd = r.day();
    if (rd == today) return "Today";
    if (rd == today + 1) return "Tomorrow";
    if (rd > today and rd < today + 7) {
        // 1970-01-01 was a Thursday (index 4).
        return WEEKDAYS[@intCast(@mod(rd + 4, 7))];
    }
    return std.fmt.bufPrint(buf, "{d} {s}", .{ r.d, MONTHS[r.m - 1] }) catch "";
}

// --- tests ------------------------------------------------------------------

fn parseAll(text: []const u8, out: []Reminder) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        if (n >= out.len) break;
        if (parseLine(l, &out[n])) n += 1;
    }
    return n;
}

test "parseLine: with and without lead, malformed lines" {
    var r: Reminder = undefined;
    try std.testing.expect(parseLine("2026-11-20 09:30 2 Dentist", &r));
    try std.testing.expectEqual(@as(u8, 2), r.lead);
    try std.testing.expectEqual(@as(u8, 9), r.hh);
    try std.testing.expectEqualStrings("Dentist", r.text());
    try std.testing.expectEqualStrings("2026-11-20 09:30 2 Dentist", r.line());

    try std.testing.expect(parseLine("2026-10-20 10:00 PayDay", &r));
    try std.testing.expectEqual(@as(u8, 0), r.lead);
    try std.testing.expectEqualStrings("PayDay", r.text());

    try std.testing.expect(!parseLine("2026-10-20 10:00 3", &r)); // lead, no text
    try std.testing.expect(!parseLine("2026-13-20 10:00 x", &r)); // month 13
    try std.testing.expect(!parseLine("2026-10-20 24:00 x", &r)); // hour 24
    try std.testing.expect(!parseLine("20261020 10:00 hello", &r)); // shape
    try std.testing.expect(!parseLine("short", &r));
}

test "daysFromCivil: known dates" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 20410), daysFromCivil(2025, 11, 18));
    try std.testing.expectEqual(@as(i64, 20512), daysFromCivil(2026, 2, 28));
    try std.testing.expectEqual(@as(i64, 20513), daysFromCivil(2026, 3, 1));
}

test "upcoming: drops the past, sorts by date and time, caps the rows" {
    const file =
        \\# comment
        \\2026-11-10 08:00 0 last week
        \\2026-11-25 12:00 0 next week
        \\2026-11-18 18:00 0 today evening
        \\2026-11-18 07:00 0 today morning
        \\2026-11-19 09:00 0 tomorrow a
        \\2026-11-19 09:00 0 tomorrow b
        \\2027-01-02 10:00 0 next year
        \\not a reminder
    ;
    var list: [MAX]Reminder = undefined;
    const n = parseAll(file, &list);
    try std.testing.expectEqual(@as(usize, 7), n);
    const today = daysFromCivil(2026, 11, 18);

    var idx: [MAX_ROWS]usize = undefined;
    const k = upcoming(list[0..n], today, &idx);
    try std.testing.expectEqual(@as(usize, 6), k);
    const want = [_][]const u8{ "today morning", "today evening", "tomorrow a", "tomorrow b", "next week", "next year" };
    for (want, 0..) |w, i| try std.testing.expectEqualStrings(w, list[idx[i]].text());

    var two: [2]usize = undefined;
    const k2 = upcoming(list[0..n], today, &two);
    try std.testing.expectEqual(@as(usize, 2), k2);
    try std.testing.expectEqualStrings("today morning", list[two[0]].text());
    try std.testing.expectEqualStrings("today evening", list[two[1]].text());

    // Nothing left after the last entry's day.
    const k3 = upcoming(list[0..n], daysFromCivil(2027, 1, 3), &idx);
    try std.testing.expectEqual(@as(usize, 0), k3);
}

test "upcoming: an early entry later in the file still lands first when full" {
    const file =
        \\2026-12-05 09:00 0 c
        \\2026-12-04 09:00 0 b
        \\2026-12-06 09:00 0 d
        \\2026-12-01 09:00 0 a
    ;
    var list: [8]Reminder = undefined;
    const n = parseAll(file, &list);
    var idx: [2]usize = undefined;
    const k = upcoming(list[0..n], daysFromCivil(2026, 11, 30), &idx);
    try std.testing.expectEqual(@as(usize, 2), k);
    try std.testing.expectEqualStrings("a", list[idx[0]].text());
    try std.testing.expectEqualStrings("b", list[idx[1]].text());
}

test "dayLabel: today, tomorrow, weekday, date" {
    var r: Reminder = undefined;
    var buf: [16]u8 = undefined;
    const today = daysFromCivil(2026, 11, 18); // a Wednesday
    try std.testing.expect(parseLine("2026-11-18 09:00 0 x", &r));
    try std.testing.expectEqualStrings("Today", dayLabel(&r, today, &buf));
    try std.testing.expect(parseLine("2026-11-19 09:00 0 x", &r));
    try std.testing.expectEqualStrings("Tomorrow", dayLabel(&r, today, &buf));
    try std.testing.expect(parseLine("2026-11-20 09:00 0 x", &r));
    try std.testing.expectEqualStrings("Fri", dayLabel(&r, today, &buf));
    try std.testing.expect(parseLine("2026-11-25 09:00 0 x", &r));
    try std.testing.expectEqualStrings("25 Nov", dayLabel(&r, today, &buf));
}
