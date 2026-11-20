//! Glance's Weather tab: the pure part. The tab's layout (a hero with the
//! current conditions and a grid of detail tiles, an hourly strip, a 7-day
//! row), hit-testing, the empty/error messages and every piece of text it
//! shows, from the shared weather service's snapshot. No Wayland, no
//! drawing, no fetching: glance_view.zig drives the Overview's weather card
//! (its cache and refresh schedule) and glance_weather_view.zig paints.
//! `zig build test-glance-weather`; the answer parsing is tested with the
//! service (`zig build test-weather` in ../perihelionbar).

const std = @import("std");
const g = @import("glance.zig");
const Rect = g.Rect;
/// The shared weather service (../perihelionbar/src/weather.zig).
pub const wsvc = @import("weather");

// --- geometry ---------------------------------------------------------------------

pub const GAP: i32 = g.GAP; // between the sections, like the Overview's cards
pub const TILE_PAD: i32 = 12; // inside the hero and the two strips
pub const DETAIL_PAD: i32 = 8; // inside a detail tile
pub const DETAIL_GAP: i32 = 10; // between detail tiles
pub const ROW_GAP: i32 = 6; // between a strip cell's rows
pub const DETAIL_COLS: usize = 3;
pub const DETAIL_ROWS: usize = 2;
/// Narrowest hour cell ("12 PM" plus breathing room at the 13 px font).
pub const HOUR_MIN_W: i32 = 52;
pub const DAY_MIN_W: i32 = 96;
pub const MAX_HOURS: usize = wsvc.HOURLY_HOURS - 1; // "now" plus 23, at most 24 cells
pub const MAX_DAYS: usize = wsvc.FORECAST_DAYS;
pub const BTN: i32 = 28; // the hero's round icon buttons
pub const BTN_GAP: i32 = 6;
/// Hero share of the top band's width, in percent (the detail grid gets the rest).
pub const HERO_PCT: i32 = 45;

pub const Detail = enum {
    feels_like,
    humidity,
    wind,
    pressure,
    sunrise,
    sunset,

    pub fn label(self: Detail) []const u8 {
        return switch (self) {
            .feels_like => "Feels like",
            .humidity => "Humidity",
            .wind => "Wind",
            .pressure => "Pressure",
            .sunrise => "Sunrise",
            .sunset => "Sunset",
        };
    }

    /// Nerd Font weather-icons codepoints (same block the card uses).
    pub fn glyph(self: Detail) u21 {
        return switch (self) {
            .feels_like => 0xE350, // thermometer
            .humidity => 0xE373, // humidity
            .wind => 0xE34B, // strong_wind
            .pressure => 0xE372, // barometer
            .sunrise => 0xE34C, // sunrise
            .sunset => 0xE34D, // sunset
        };
    }
};
pub const DETAIL_COUNT = std.meta.tags(Detail).len;

pub const Layout = struct {
    hero: Rect = .{},
    details: [DETAIL_COUNT]Rect = @as([DETAIL_COUNT]Rect, @splat(.{})),
    refresh: Rect = .{},
    forecast: Rect = .{},
    hourly: Rect = .{},
    hour_cells: [MAX_HOURS]Rect = @as([MAX_HOURS]Rect, @splat(.{})),
    hour_count: usize = 0,
    daily: Rect = .{},
    day_cells: [MAX_DAYS]Rect = @as([MAX_DAYS]Rect, @splat(.{})),
    day_count: usize = 0,
    /// "Hourly" / "7-day" headings over the strips, only when there's room.
    titles: bool = false,
    /// Strip icons at twice the font size, only when there's room.
    big_icons: bool = true,
    /// Height of a strip cell's icon row.
    icon_h: i32 = 0,

    pub fn hours(self: *const Layout) []const Rect {
        return self.hour_cells[0..self.hour_count];
    }

    pub fn days(self: *const Layout) []const Rect {
        return self.day_cells[0..self.day_count];
    }
};

fn detailH(lh: i32) i32 {
    return 2 * DETAIL_PAD + 2 * lh + 4;
}

fn bandH(lh: i32) i32 {
    return @as(i32, DETAIL_ROWS) * detailH(lh) + (@as(i32, DETAIL_ROWS) - 1) * DETAIL_GAP;
}

/// A strip cell: label, icon, value, rain chance.
fn cellsH(lh: i32, icon_h: i32) i32 {
    return 3 * lh + icon_h + 3 * ROW_GAP;
}

fn titleH(lh: i32, on: bool) i32 {
    return if (on) lh + ROW_GAP else 0;
}

fn stripH(lh: i32, icon_h: i32, titles: bool) i32 {
    return 2 * TILE_PAD + titleH(lh, titles) + cellsH(lh, icon_h);
}

/// Height the tab needs with these options.
pub fn neededH(lh: i32, big_icons: bool, titles: bool) i32 {
    const icon_h = if (big_icons) 2 * lh else lh;
    return bandH(lh) + 2 * GAP + 2 * stripH(lh, icon_h, titles);
}

/// Splits `inner` into `n` columns whose widths differ by at most 1 px.
fn columns(out: []Rect, n: usize, x: i32, w: i32, y: i32, h: i32) void {
    const ni: i32 = @intCast(n);
    for (0..n) |i| {
        const ii: i32 = @intCast(i);
        const x0 = x + @divTrunc(w * ii, ni);
        const x1 = x + @divTrunc(w * (ii + 1), ni);
        out[i] = .{ .x = x0, .y = y, .w = x1 - x0, .h = h };
    }
}

/// Lays the tab out in the content rect `c`:
///   top     hero (current conditions; full-forecast and refresh buttons
///           in its bottom-right corner) beside a 3 x 2 grid of detail tiles
///   middle  the hourly strip, as many consecutive hours as fit (up to 24)
///   bottom  the 7-day row
/// Headings and 2x strip icons are dropped, in that order, when the content
/// is too short; spare height goes to the two strips. `hours_avail` and
/// `days_avail` are how many hours and days the snapshot has.
pub fn layout(c: Rect, lh: i32, hours_avail: usize, days_avail: usize) Layout {
    var l = Layout{};
    l.big_icons = true;
    l.titles = neededH(lh, true, true) <= c.h;
    if (!l.titles and neededH(lh, true, false) > c.h) l.big_icons = false;
    l.icon_h = if (l.big_icons) 2 * lh else lh;

    // Top band: hero, then the detail grid.
    const band_h = @min(bandH(lh), @max(c.h, 0));
    const hero_w = @divTrunc((c.w - GAP) * HERO_PCT, 100);
    l.hero = .{ .x = c.x, .y = c.y, .w = hero_w, .h = band_h };
    const gx = c.x + hero_w + GAP;
    const gw = c.w - hero_w - GAP;
    const dh = detailH(lh);
    var row_rects: [DETAIL_COLS]Rect = undefined;
    for (0..DETAIL_ROWS) |r| {
        const ry = c.y + @as(i32, @intCast(r)) * (dh + DETAIL_GAP);
        // Columns with DETAIL_GAP between them.
        const cw_total = gw - (@as(i32, DETAIL_COLS) - 1) * DETAIL_GAP;
        columns(&row_rects, DETAIL_COLS, 0, cw_total, ry, dh);
        for (row_rects, 0..) |cr, k| {
            l.details[r * DETAIL_COLS + k] = .{ .x = gx + cr.x + @as(i32, @intCast(k)) * DETAIL_GAP, .y = cr.y, .w = cr.w, .h = cr.h };
        }
    }
    l.refresh = .{ .x = l.hero.x + l.hero.w - TILE_PAD - BTN, .y = l.hero.y + l.hero.h - TILE_PAD - BTN, .w = BTN, .h = BTN };
    l.forecast = .{ .x = l.refresh.x - BTN_GAP - BTN, .y = l.refresh.y, .w = BTN, .h = BTN };

    // The two strips share what's left below the band, evenly.
    const below = c.y + band_h + GAP;
    const rest = @max(c.y + c.h - below - GAP, 0);
    const strip_a = @divTrunc(rest, 2);
    const strip_b = rest - strip_a;
    l.hourly = .{ .x = c.x, .y = below, .w = c.w, .h = strip_a };
    l.daily = .{ .x = c.x, .y = below + strip_a + GAP, .w = c.w, .h = strip_b };

    const th = titleH(lh, l.titles);
    const inner_x = c.x + TILE_PAD;
    const inner_w = @max(c.w - 2 * TILE_PAD, 0);
    {
        const fit: usize = @intCast(std.math.clamp(@divTrunc(inner_w, HOUR_MIN_W), 0, @as(i32, MAX_HOURS)));
        l.hour_count = @min(fit, hours_avail);
        const cy = l.hourly.y + TILE_PAD + th;
        columns(&l.hour_cells, l.hour_count, inner_x, inner_w, cy, @max(l.hourly.h - 2 * TILE_PAD - th, 0));
    }
    {
        const fit: usize = @intCast(std.math.clamp(@divTrunc(inner_w, DAY_MIN_W), 0, @as(i32, MAX_DAYS)));
        l.day_count = @min(fit, days_avail);
        const cy = l.daily.y + TILE_PAD + th;
        columns(&l.day_cells, l.day_count, inner_x, inner_w, cy, @max(l.daily.h - 2 * TILE_PAD - th, 0));
    }
    return l;
}

/// Top of each row inside a strip cell (label, icon, value, rain), with the
/// cell's spare height split above and below so the rows sit centred.
pub fn cellRows(cell: Rect, lh: i32, icon_h: i32) [4]i32 {
    const spare = @max(cell.h - cellsH(lh, icon_h), 0);
    const y0 = cell.y + @divTrunc(spare, 2);
    const y1 = y0 + lh + ROW_GAP;
    const y2 = y1 + icon_h + ROW_GAP;
    const y3 = y2 + lh + ROW_GAP;
    return .{ y0, y1, y2, y3 };
}

// --- hit-testing --------------------------------------------------------------

pub const Hit = union(enum) {
    none,
    refresh,
    forecast,
    hour: u8,
    day: u8,

    pub fn eql(a: Hit, b: Hit) bool {
        return switch (a) {
            .none => b == .none,
            .refresh => b == .refresh,
            .forecast => b == .forecast,
            .hour => |i| b == .hour and b.hour == i,
            .day => |i| b == .day and b.day == i,
        };
    }
};

/// Panel-local point → what's under it. The buttons exist only with a
/// reading (`has_data`); without one the tab shows a message and a refresh
/// button in its place (`retry_btn`, see emptyRetryRect).
pub fn hitTest(l: *const Layout, has_data: bool, retry_btn: ?Rect, x: i32, y: i32) Hit {
    if (!has_data) {
        if (retry_btn) |r| {
            if (r.contains(x, y)) return .refresh;
        }
        return .none;
    }
    if (l.refresh.contains(x, y)) return .refresh;
    if (l.forecast.contains(x, y)) return .forecast;
    for (l.hours(), 0..) |r, i| {
        if (r.contains(x, y)) return .{ .hour = @intCast(i) };
    }
    for (l.days(), 0..) |r, i| {
        if (r.contains(x, y)) return .{ .day = @intCast(i) };
    }
    return .none;
}

// --- empty and error states ---------------------------------------------------------

pub const Empty = struct {
    title: []const u8,
    line: []const u8,
    /// Offer a "Try again" button (a refresh the user can ask for).
    retry: bool = false,
};

/// What the tab says when there is no reading to show.
pub fn emptyState(status: wsvc.Status, loading: bool) Empty {
    return switch (status) {
        .locating => .{ .title = "Finding your location\u{2026}", .line = "Looking up where you are to fetch the forecast." },
        .no_location => .{
            .title = "No location set",
            .line = "Set weather_city in ~/.config/perihelionbar/shell.json, or turn weather_auto_location on.",
        },
        .city_not_found => .{
            .title = "City not found",
            .line = "Check weather_city in ~/.config/perihelionbar/shell.json (\"City\", \"City, ST\" or \"lat,lon\").",
        },
        .fetching, .waiting, .ready => if (loading)
            .{ .title = "Loading the forecast\u{2026}", .line = "Asking Open-Meteo for the latest conditions." }
        else
            .{ .title = "Weather unavailable", .line = "Can't reach the weather service right now. Retrying automatically.", .retry = true },
    };
}

/// Where the "Try again" button of an empty state sits: centred under the
/// message (whose second line ends at `text_bottom`).
pub fn emptyRetryRect(c: Rect, text_bottom: i32, w: i32) Rect {
    return .{ .x = c.x + @divTrunc(c.w - w, 2), .y = text_bottom + 18, .w = w, .h = BTN + 4 };
}

// --- text ----------------------------------------------------------------------

/// "Now" for the first cell, then "17:00" or "5 PM"; midnight says which
/// day starts (`next_day`, e.g. "Fri") when that's known.
pub fn hourLabel(hour: u8, index: usize, h24: bool, next_day: []const u8, buf: []u8) []const u8 {
    if (index == 0) return "Now";
    if (hour == 0 and next_day.len > 0) return next_day;
    if (h24) return std.fmt.bufPrint(buf, "{d:0>2}:00", .{hour}) catch "";
    const h12: u8 = if (hour % 12 == 0) 12 else hour % 12;
    return std.fmt.bufPrint(buf, "{d} {s}", .{ h12, if (hour < 12) "AM" else "PM" }) catch "";
}

/// "06:42" as is in 24-hour mode, "6:42 AM" otherwise; "—" when unknown.
pub fn clockText(hhmm: []const u8, h24: bool, buf: []u8) []const u8 {
    if (hhmm.len != 5 or hhmm[2] != ':') return "\u{2014}";
    if (h24) return hhmm;
    const h = std.fmt.parseInt(u8, hhmm[0..2], 10) catch return "\u{2014}";
    if (h > 23) return "\u{2014}";
    const h12: u8 = if (h % 12 == 0) 12 else h % 12;
    return std.fmt.bufPrint(buf, "{d}:{s} {s}", .{ h12, hhmm[3..5], if (h < 12) "AM" else "PM" }) catch "";
}

pub fn dayLabel(index: usize, name: []const u8) []const u8 {
    if (index == 0) return "Today";
    return if (name.len > 0) name else "\u{2014}";
}

/// "72°" (rounded; -0.4 shows as 0).
pub fn tempText(v: f32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}\u{00B0}", .{wsvc.roundi(v)}) catch "";
}

const COMPASS = [_][]const u8{ "N", "NE", "E", "SE", "S", "SW", "W", "NW" };

/// The 8-point compass name for a direction in degrees (where the wind
/// blows from, as forecasts say it).
pub fn compass(deg: u16) []const u8 {
    const d: u32 = @as(u32, deg % 360);
    return COMPASS[((d * 2 + 45) / 90) % 8];
}

/// "12 mph NW" / "19 km/h" (no direction known).
pub fn windText(w: *const wsvc.Weather, units: wsvc.Units, buf: []u8) []const u8 {
    var sb: [24]u8 = undefined;
    const speed = w.windText(units, &sb);
    if (w.wind_dir) |deg| return std.fmt.bufPrint(buf, "{s} {s}", .{ speed, compass(deg) }) catch speed;
    return std.fmt.bufPrint(buf, "{s}", .{speed}) catch "";
}

/// Sea-level pressure in the units' own convention: inHg alongside °F,
/// hPa alongside °C. "—" when the answer had none.
pub fn pressureText(hpa: f32, units: wsvc.Units, buf: []u8) []const u8 {
    if (!(hpa > 0)) return "\u{2014}";
    return switch (units) {
        .fahrenheit => std.fmt.bufPrint(buf, "{d:.2} inHg", .{hpa * 0.0295300}) catch "",
        // Not wsvc.roundi: its garbage guard stops at 999.
        .celsius => std.fmt.bufPrint(buf, "{d} hPa", .{@as(i32, @intFromFloat(@round(@min(hpa, 2000))))}) catch "",
    };
}

/// A detail tile's value.
pub fn detailValue(d: Detail, w: *const wsvc.Weather, units: wsvc.Units, h24: bool, buf: []u8) []const u8 {
    return switch (d) {
        .feels_like => tempText(w.feelsLike(units), buf),
        .humidity => std.fmt.bufPrint(buf, "{d}%", .{w.humidity}) catch "",
        .wind => windText(w, units, buf),
        .pressure => pressureText(w.pressureHpa(), units, buf),
        .sunrise => clockText(w.sunrise.slice(), h24, buf),
        .sunset => clockText(w.sunset.slice(), h24, buf),
    };
}

/// "H 75°  L 58°" from today's forecast; empty without one.
pub fn hiLoText(w: *const wsvc.Weather, units: wsvc.Units, buf: []u8) []const u8 {
    const days = w.days();
    if (days.len == 0) return "";
    return std.fmt.bufPrint(buf, "H {d}\u{00B0}  L {d}\u{00B0}", .{ wsvc.roundi(days[0].max(units)), wsvc.roundi(days[0].min(units)) }) catch "";
}

/// "Updated 5:45 PM", or "Offline · 5:45 PM" (when the reading shown is
/// from) once a refresh has failed.
pub fn updatedText(w: *const wsvc.Weather, h24: bool, buf: []u8) []const u8 {
    var cb: [16]u8 = undefined;
    const t = clockText(w.observed.slice(), h24, &cb);
    if (w.stale) {
        if (w.observed.len == 0) return "Offline";
        return std.fmt.bufPrint(buf, "Offline \u{00B7} {s}", .{t}) catch "Offline";
    }
    if (w.observed.len == 0) return "";
    return std.fmt.bufPrint(buf, "Updated {s}", .{t}) catch "";
}

/// "City, Country" when both are known (country left off when it's the
/// same word, as IP lookups sometimes answer), else whichever is.
pub fn placeText(w: *const wsvc.Weather, buf: []u8) []const u8 {
    const city = w.city.slice();
    const country = w.country.slice();
    if (city.len == 0) return if (country.len > 0) country else "";
    if (country.len == 0 or std.ascii.eqlIgnoreCase(city, country)) return city;
    return std.fmt.bufPrint(buf, "{s}, {s}", .{ city, country }) catch city;
}

/// Rain chance worth showing (below 10% reads as noise, as on the card).
pub fn showsRain(prob: u32) bool {
    return prob >= 10;
}

// --- the 7-day range bars ---------------------------------------------------------------

pub const Range = struct { lo: f32, hi: f32 };

/// Coldest low and warmest high over the shown days.
pub fn weekRange(days: []const wsvc.ForecastDay, units: wsvc.Units) ?Range {
    if (days.len == 0) return null;
    var r = Range{ .lo = days[0].min(units), .hi = days[0].max(units) };
    for (days[1..]) |*d| {
        r.lo = @min(r.lo, d.min(units));
        r.hi = @max(r.hi, d.max(units));
    }
    return r;
}

/// The part of a `track_w`-wide bar one day's low..high covers, against the
/// week's range: {start, width} in px, at least `min_w` wide and always
/// inside the track.
pub fn rangeSpan(week: Range, lo: f32, hi: f32, track_w: i32, min_w: i32) [2]i32 {
    if (track_w <= 0) return .{ 0, 0 };
    const span = week.hi - week.lo;
    const tw: f32 = @floatFromInt(track_w);
    var a: f32 = 0;
    var b: f32 = tw;
    if (span > 0.01) {
        a = std.math.clamp((@min(lo, hi) - week.lo) / span, 0, 1) * tw;
        b = std.math.clamp((@max(lo, hi) - week.lo) / span, 0, 1) * tw;
    }
    var x0: i32 = @intFromFloat(@round(a));
    var w: i32 = @intFromFloat(@round(b - a));
    const mw = @min(min_w, track_w);
    if (w < mw) {
        // Grow around the middle, then slide back inside the track.
        x0 -= @divTrunc(mw - w, 2);
        w = mw;
    }
    x0 = std.math.clamp(x0, 0, track_w - w);
    return .{ x0, w };
}

// --- tests --------------------------------------------------------------------

const tt = std.testing;

/// The Glance content rect at the 13 px font (see glance.zig's tests).
const CONTENT = Rect{ .x = 20, .y = 70, .w = 890, .h = 439 };
const LH: i32 = 17;

fn inside(outer: Rect, inner: Rect) bool {
    return inner.x >= outer.x and inner.y >= outer.y and
        inner.x + inner.w <= outer.x + outer.w and inner.y + inner.h <= outer.y + outer.h;
}

fn overlaps(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

test "layout: the default panel fits everything, 2x icons, no headings" {
    const l = layout(CONTENT, LH, 25, 7);
    try tt.expect(l.big_icons);
    try tt.expect(!l.titles); // 446 > 439: headings would not fit
    try tt.expectEqual(2 * LH, l.icon_h);
    try tt.expect(neededH(LH, true, false) <= CONTENT.h);
    const sections = [_]Rect{ l.hero, l.hourly, l.daily };
    for (sections) |r| try tt.expect(inside(CONTENT, r));
    for (l.details) |r| {
        try tt.expect(inside(CONTENT, r));
        try tt.expect(!overlaps(r, l.hero));
    }
    for (l.details, 0..) |a, i| {
        for (l.details[i + 1 ..]) |b| try tt.expect(!overlaps(a, b));
    }
    // The grid's right edge meets the content's; hero and grid share the band.
    try tt.expectEqual(CONTENT.x + CONTENT.w, l.details[2].x + l.details[2].w);
    try tt.expectEqual(l.hero.y + l.hero.h, l.details[5].y + l.details[5].h);
    // Strips under the band, a GAP apart, the last ending at the bottom.
    try tt.expectEqual(l.hero.y + l.hero.h + GAP, l.hourly.y);
    try tt.expectEqual(l.hourly.y + l.hourly.h + GAP, l.daily.y);
    try tt.expectEqual(CONTENT.y + CONTENT.h, l.daily.y + l.daily.h);
    // Buttons in the hero's bottom-right corner, side by side.
    try tt.expect(inside(l.hero, l.refresh) and inside(l.hero, l.forecast));
    try tt.expect(!overlaps(l.refresh, l.forecast));
    try tt.expectEqual(l.hero.y + l.hero.h - TILE_PAD, l.refresh.y + l.refresh.h);
    try tt.expectEqual(l.hero.x + l.hero.w - TILE_PAD, l.refresh.x + l.refresh.w);
}

test "layout: as many consecutive hours as fit, all seven days" {
    const l = layout(CONTENT, LH, 25, 7);
    // (890 - 24) / 52 = 16 hour cells; 866 / 96 = 9 → all 7 days.
    try tt.expectEqual(@as(usize, 16), l.hour_count);
    try tt.expectEqual(@as(usize, 7), l.day_count);
    var x = l.hourly.x + TILE_PAD;
    for (l.hours()) |r| {
        try tt.expectEqual(x, r.x); // contiguous, no gaps or overlaps
        try tt.expect(r.w >= HOUR_MIN_W);
        try tt.expect(inside(l.hourly, r));
        x += r.w;
    }
    try tt.expectEqual(l.hourly.x + l.hourly.w - TILE_PAD, x);
    for (l.days()) |r| try tt.expect(inside(l.daily, r) and r.w >= DAY_MIN_W);
    // A wide panel shows the whole day ahead, never more than 24 cells.
    const wide = layout(.{ .x = 0, .y = 0, .w = 2400, .h = 500 }, LH, 25, 7);
    try tt.expectEqual(MAX_HOURS, wide.hour_count);
    // Fewer hours or days in the snapshot: only those.
    const few = layout(CONTENT, LH, 5, 3);
    try tt.expectEqual(@as(usize, 5), few.hour_count);
    try tt.expectEqual(@as(usize, 3), few.day_count);
    const none = layout(CONTENT, LH, 0, 0);
    try tt.expectEqual(@as(usize, 0), none.hour_count);
}

test "layout: headings when tall, 1x icons when short, never outside" {
    const tall = layout(.{ .x = 0, .y = 0, .w = 890, .h = 600 }, LH, 25, 7);
    try tt.expect(tall.titles and tall.big_icons);
    // Spare height goes to the strips, rows stay centred in their cells.
    const rows = cellRows(tall.hour_cells[0], LH, tall.icon_h);
    try tt.expect(rows[0] > tall.hour_cells[0].y);
    try tt.expect(rows[3] + LH <= tall.hour_cells[0].y + tall.hour_cells[0].h);
    const short = layout(.{ .x = 0, .y = 0, .w = 890, .h = 380 }, LH, 25, 7);
    try tt.expect(!short.titles and !short.big_icons);
    try tt.expectEqual(LH, short.icon_h);
    // Even far too short, nothing escapes the content rect.
    const tiny_c = Rect{ .x = 5, .y = 5, .w = 300, .h = 60 };
    const tiny = layout(tiny_c, LH, 25, 7);
    for ([_]Rect{ tiny.hero, tiny.hourly, tiny.daily }) |r| {
        try tt.expect(r.h >= 0);
        try tt.expect(r.y >= tiny_c.y);
    }
    for (tiny.hours()) |r| try tt.expect(r.h >= 0);
}

test "hitTest: buttons, hours and days with data; only retry without" {
    const l = layout(CONTENT, LH, 25, 7);
    try tt.expect(hitTest(&l, true, null, l.refresh.x + 2, l.refresh.y + 2) == .refresh);
    try tt.expect(hitTest(&l, true, null, l.forecast.x + 2, l.forecast.y + 2) == .forecast);
    const h3 = l.hour_cells[3];
    try tt.expect(hitTest(&l, true, null, h3.x + 1, h3.y + 1).eql(.{ .hour = 3 }));
    const d6 = l.day_cells[6];
    try tt.expect(hitTest(&l, true, null, d6.x + d6.w - 1, d6.y + d6.h - 1).eql(.{ .day = 6 }));
    try tt.expect(hitTest(&l, true, null, l.hero.x + 2, l.hero.y + l.hero.h - 2) == .none);
    try tt.expect(hitTest(&l, true, null, -5, -5) == .none);
    // No reading: the cells and buttons are gone, the retry button answers.
    try tt.expect(hitTest(&l, false, null, l.refresh.x + 2, l.refresh.y + 2) == .none);
    try tt.expect(hitTest(&l, false, null, h3.x + 1, h3.y + 1) == .none);
    const retry = emptyRetryRect(CONTENT, 300, 110);
    try tt.expect(inside(CONTENT, retry));
    try tt.expect(hitTest(&l, false, retry, retry.x + 5, retry.y + 5) == .refresh);
    try tt.expect(!Hit.eql(.{ .hour = 1 }, .{ .day = 1 }));
}

test "empty states say what's wrong, never blank" {
    const s = std.meta.tags(wsvc.Status);
    for (s) |st| {
        for ([_]bool{ false, true }) |loading| {
            const e = emptyState(st, loading);
            try tt.expect(e.title.len > 0 and e.line.len > 0);
        }
    }
    try tt.expectEqualStrings("No location set", emptyState(.no_location, false).title);
    try tt.expectEqualStrings("City not found", emptyState(.city_not_found, false).title);
    try tt.expect(emptyState(.waiting, false).retry); // offline, nothing cached
    try tt.expect(!emptyState(.fetching, true).retry);
    try tt.expect(!emptyState(.no_location, false).retry);
}

test "hour, clock and day labels" {
    var b: [16]u8 = undefined;
    try tt.expectEqualStrings("Now", hourLabel(17, 0, false, "Fri", &b));
    try tt.expectEqualStrings("Now", hourLabel(0, 0, false, "Fri", &b)); // now beats midnight
    try tt.expectEqualStrings("5 PM", hourLabel(17, 1, false, "Fri", &b));
    try tt.expectEqualStrings("Fri", hourLabel(0, 3, false, "Fri", &b));
    try tt.expectEqualStrings("Fri", hourLabel(0, 3, true, "Fri", &b));
    try tt.expectEqualStrings("12 AM", hourLabel(0, 3, false, "", &b));
    try tt.expectEqualStrings("00:00", hourLabel(0, 3, true, "", &b));
    try tt.expectEqualStrings("12 PM", hourLabel(12, 3, false, "Fri", &b));
    try tt.expectEqualStrings("9 AM", hourLabel(9, 3, false, "Fri", &b));
    try tt.expectEqualStrings("07:00", hourLabel(7, 2, true, "Fri", &b));
    try tt.expectEqualStrings("6:42 AM", clockText("06:42", false, &b));
    try tt.expectEqualStrings("4:28 PM", clockText("16:28", false, &b));
    try tt.expectEqualStrings("12:05 AM", clockText("00:05", false, &b));
    try tt.expectEqualStrings("16:28", clockText("16:28", true, &b));
    try tt.expectEqualStrings("\u{2014}", clockText("", false, &b));
    try tt.expectEqualStrings("\u{2014}", clockText("99:00", false, &b));
    try tt.expectEqualStrings("Today", dayLabel(0, "Wed"));
    try tt.expectEqualStrings("Thu", dayLabel(1, "Thu"));
    try tt.expectEqualStrings("\u{2014}", dayLabel(2, ""));
}

test "compass points" {
    try tt.expectEqualStrings("N", compass(0));
    try tt.expectEqualStrings("N", compass(22));
    try tt.expectEqualStrings("NE", compass(23));
    try tt.expectEqualStrings("E", compass(90));
    try tt.expectEqualStrings("SW", compass(225));
    try tt.expectEqualStrings("NW", compass(315));
    try tt.expectEqualStrings("N", compass(359));
    try tt.expectEqualStrings("N", compass(360));
}

/// A reading as the service would hold it (°C inside, like Open-Meteo).
fn sample() wsvc.Weather {
    var w = wsvc.Weather{ .available = true, .loading = false };
    w.temp_c = 22.0;
    w.temp_f = wsvc.cToF(22.0);
    w.feels_like_c = 21.4;
    w.feels_like_f = wsvc.cToF(21.4);
    w.humidity = 64;
    w.wind_kmh = 19.3; // 12 mph
    w.wind_dir = 315;
    w.pressure = 990;
    w.pressure_msl = 1013.25;
    w.sunrise.set("06:42");
    w.sunset.set("16:28");
    w.observed.set("17:45");
    w.city.set("Chicago");
    w.country.set("United States");
    w.forecast[0] = .{ .max_c = 23.9, .min_c = 14.4 }; // 75 / 58 °F
    w.forecast[1] = .{ .max_c = 18.0, .min_c = 9.0 };
    w.forecast_len = 2;
    return w;
}

test "details in °F/mph/inHg and °C/km/h/hPa" {
    var w = sample();
    var b: [40]u8 = undefined;
    try tt.expectEqualStrings("71\u{00B0}", detailValue(.feels_like, &w, .fahrenheit, false, &b));
    try tt.expectEqualStrings("21\u{00B0}", detailValue(.feels_like, &w, .celsius, false, &b));
    try tt.expectEqualStrings("64%", detailValue(.humidity, &w, .fahrenheit, false, &b));
    try tt.expectEqualStrings("12 mph NW", detailValue(.wind, &w, .fahrenheit, false, &b));
    try tt.expectEqualStrings("19 km/h NW", detailValue(.wind, &w, .celsius, false, &b));
    try tt.expectEqualStrings("29.92 inHg", detailValue(.pressure, &w, .fahrenheit, false, &b));
    try tt.expectEqualStrings("1013 hPa", detailValue(.pressure, &w, .celsius, false, &b));
    try tt.expectEqualStrings("6:42 AM", detailValue(.sunrise, &w, .fahrenheit, false, &b));
    try tt.expectEqualStrings("16:28", detailValue(.sunset, &w, .celsius, true, &b));
    // Unknowns read as a dash or drop out, never as made-up numbers.
    w.wind_dir = null;
    try tt.expectEqualStrings("12 mph", detailValue(.wind, &w, .fahrenheit, false, &b));
    w.pressure_msl = 0;
    w.pressure = 0;
    try tt.expectEqualStrings("\u{2014}", detailValue(.pressure, &w, .celsius, false, &b));
    w.sunset = .{};
    try tt.expectEqualStrings("\u{2014}", detailValue(.sunset, &w, .celsius, false, &b));
    try tt.expectEqualStrings("Sunrise", Detail.sunrise.label());
}

test "hero lines: high/low, updated, place" {
    var w = sample();
    var b: [64]u8 = undefined;
    try tt.expectEqualStrings("H 75\u{00B0}  L 58\u{00B0}", hiLoText(&w, .fahrenheit, &b));
    try tt.expectEqualStrings("H 24\u{00B0}  L 14\u{00B0}", hiLoText(&w, .celsius, &b));
    try tt.expectEqualStrings("Updated 5:45 PM", updatedText(&w, false, &b));
    try tt.expectEqualStrings("Updated 17:45", updatedText(&w, true, &b));
    w.stale = true;
    try tt.expectEqualStrings("Offline \u{00B7} 5:45 PM", updatedText(&w, false, &b));
    w.observed = .{};
    try tt.expectEqualStrings("Offline", updatedText(&w, false, &b));
    w.stale = false;
    try tt.expectEqualStrings("", updatedText(&w, false, &b));
    try tt.expectEqualStrings("Chicago, United States", placeText(&w, &b));
    w.country.set("chicago");
    try tt.expectEqualStrings("Chicago", placeText(&w, &b));
    w.city = .{};
    try tt.expectEqualStrings("chicago", placeText(&w, &b));
    w.forecast_len = 0;
    try tt.expectEqualStrings("", hiLoText(&w, .celsius, &b));
    var tb: [8]u8 = undefined;
    try tt.expectEqualStrings("0\u{00B0}", tempText(-0.4, &tb));
    try tt.expectEqualStrings("-3\u{00B0}", tempText(-2.6, &tb));
    try tt.expect(!showsRain(9) and showsRain(10));
}

test "week range and range bars" {
    const w = sample();
    const r = weekRange(w.days(), .celsius).?;
    try tt.expectApproxEqAbs(@as(f32, 9.0), r.lo, 1e-4);
    try tt.expectApproxEqAbs(@as(f32, 23.9), r.hi, 1e-4);
    try tt.expect(weekRange(&.{}, .celsius) == null);
    // The full week fills the track; one day covers its share.
    try tt.expectEqual([2]i32{ 0, 100 }, rangeSpan(.{ .lo = 0, .hi = 10 }, 0, 10, 100, 8));
    try tt.expectEqual([2]i32{ 20, 50 }, rangeSpan(.{ .lo = 0, .hi = 10 }, 2, 7, 100, 8));
    // Swapped low/high are fine; a one-degree day keeps a visible width.
    try tt.expectEqual([2]i32{ 20, 50 }, rangeSpan(.{ .lo = 0, .hi = 10 }, 7, 2, 100, 8));
    const thin = rangeSpan(.{ .lo = 0, .hi = 10 }, 10, 10, 100, 8);
    try tt.expectEqual(@as(i32, 8), thin[1]);
    try tt.expect(thin[0] + thin[1] <= 100);
    // A flat week (every day the same) fills the track; zero width is empty.
    try tt.expectEqual([2]i32{ 0, 60 }, rangeSpan(.{ .lo = 5, .hi = 5 }, 5, 5, 60, 8));
    try tt.expectEqual([2]i32{ 0, 0 }, rangeSpan(.{ .lo = 0, .hi = 10 }, 2, 7, 0, 8));
}
