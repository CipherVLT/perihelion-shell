//! Glance's Weather tab, the live side: painting and pointer state. The
//! rules (layout, hit-testing, messages, every piece of text) live in
//! glance_weather.zig and are unit-tested there.
//!
//! It owns no data and starts no fetch: the snapshot is the Overview's
//! weather card instance (glance_view.zig), whose service reads the cache
//! the bar and the desktop card share and keeps their refresh schedule.
//! glance_view.zig pumps that card only while this tab (or the Overview)
//! is the page on screen, so nothing runs while Glance is closed or the
//! Media tab is shown.

const std = @import("std");
const font_mod = @import("font");
const widgets = @import("widgets");
const g = @import("glance.zig");
const gw = @import("glance_weather.zig");
const gv = @import("glance_view.zig");
const wsvc = gw.wsvc;

const GLYPH_REFRESH = "\u{f021}";
const GLYPH_OPEN = "\u{f08e}"; // external link
const GLYPH_RAIN: u32 = 0xE371; // raindrop, as on the card
const RAIN_BLUE: u32 = 0xFF4AA8FF; // the card's rain tint

/// What a click asks glance_view.zig to do.
pub const Action = enum { none, refresh, forecast };

pub const WeatherTab = struct {
    layout: gw.Layout = .{},
    hover: gw.Hit = .none,
    press_hit: ?gw.Hit = null,
    /// The empty state's "Try again" button, while one is shown.
    retry: ?g.Rect = null,
    /// Whether a reading was on screen at the last paint (what hit-testing
    /// must match).
    has_data: bool = false,

    // --- input ------------------------------------------------------------------

    fn hit(self: *const WeatherTab, x: i32, y: i32) gw.Hit {
        return gw.hitTest(&self.layout, self.has_data, self.retry, x, y);
    }

    /// Panel-local motion; true when the hover highlight moved.
    pub fn motion(self: *WeatherTab, x: i32, y: i32) bool {
        const h = self.hit(x, y);
        if (h.eql(self.hover)) return false;
        self.hover = h;
        return true;
    }

    pub fn leave(self: *WeatherTab) bool {
        const was = self.hover != .none;
        self.hover = .none;
        self.press_hit = null;
        return was;
    }

    pub fn press(self: *WeatherTab, x: i32, y: i32) void {
        self.press_hit = self.hit(x, y);
    }

    /// Press and release on the same button is a click.
    pub fn release(self: *WeatherTab, x: i32, y: i32) Action {
        const pr = self.press_hit orelse return .none;
        self.press_hit = null;
        const h = self.hit(x, y);
        if (!pr.eql(h)) return .none;
        return switch (h) {
            .refresh => .refresh,
            .forecast => .forecast,
            .none, .hour, .day => .none,
        };
    }

    // --- painting -----------------------------------------------------------------

    pub fn render(self: *WeatherTab, c: widgets.Canvas, content: g.Rect, font: *font_mod.Font, w: *const widgets.WeatherWidget) void {
        const lh: i32 = @intCast(widgets.lineH(font));
        const d = &w.svc.data;
        self.has_data = d.available;
        self.layout = gw.layout(content, lh, d.hours().len, d.days().len);
        if (!d.available) {
            self.renderEmpty(c, content, font, w);
            return;
        }
        self.retry = null;
        const h24 = widgets.clock_layout.h24;
        const radius: i32 = @intCast(@max(c.theme.radius_px, 6) - 4);
        const l = &self.layout;
        // Soft inner tiles on the panel's glass, a hairline edge, no shadow:
        // the Overview's card tiles.
        tile(c, l.hero, radius + 2);
        for (l.details) |r| tile(c, r, radius);
        tile(c, l.hourly, radius + 2);
        tile(c, l.daily, radius + 2);
        self.renderHero(c, font, w, h24);
        self.renderDetails(c, font, w, h24);
        self.renderHourly(c, font, w, h24, radius);
        self.renderDaily(c, font, w, radius);
    }

    fn renderHero(self: *const WeatherTab, c: widgets.Canvas, font: *font_mod.Font, w: *const widgets.WeatherWidget, h24: bool) void {
        const th = c.theme;
        const l = &self.layout;
        const r = l.hero;
        const d = &w.svc.data;
        const units = w.svc.units;
        const asc: i32 = @intCast(font.ascentPx());
        const desc: i32 = @intCast(font.descentPx());
        const lh: i32 = asc + desc;
        const pad: i32 = gw.TILE_PAD + 4;
        const tint_raw = wsvc.tintFor(d.w_code, d.is_day);
        const tint = if (tint_raw != 0) tint_raw else th.text_color;

        // Condition icon: a square on the left, as large as fits.
        const box = @max(@min(r.h - 2 * pad, @divTrunc(r.w, 3)), 0);
        const glow = wsvc.kindFor(d.w_code) == .clear and d.is_day;
        _ = widgets.drawIconFit(c, toRect(r), wsvc.iconFor(d.w_code, d.is_day), r.x + pad, r.y + @divTrunc(r.h - box, 2), box, box, 6, tint, glow);
        const tx = r.x + pad + box + (if (box > 0) @as(i32, 16) else 0);
        const right = r.x + r.w - pad;
        var fit: [160]u8 = undefined;

        // Big temperature, top-aligned with the text column, and on its
        // right when the reading is from.
        var tb: [16]u8 = undefined;
        const temp_s = gw.tempText(d.temp(units), &tb);
        const scale: u32 = if (r.h >= 5 * lh) 3 else 2;
        const tbase = r.y + pad + capTop(font, scale);
        const temp_w: i32 = @intCast(widgets.drawScaledText(c, tx, tbase, temp_s, scale, th.text_color));
        var ub: [48]u8 = undefined;
        const upd = gw.updatedText(d, h24, &ub);
        const upd_room = right - (tx + temp_w + 12);
        if (upd.len > 0 and upd_room > 24) {
            // Offline in the warm accent, so a stale reading is noticed.
            const col = if (d.stale) th.holiday_color else widgets.dim(th.text_color, 0x88);
            const t = widgets.fitText(c, upd, upd_room, &fit);
            _ = c.drawTextA(right - @as(i32, @intCast(c.textWidth(t))), r.y + pad + asc - 2, t, col);
        }

        // Condition with today's high/low under the temperature; the place
        // on the bottom row, left of the buttons.
        const avail = @max(right - tx, 0);
        const b1 = tbase + lh + 4;
        const b3 = l.refresh.y + @divTrunc(l.refresh.h + asc - desc, 2);
        const cond_w: i32 = @intCast(c.drawTextA(tx, b1, widgets.fitText(c, wsvc.conditionText(d.w_code), avail, &fit), th.text_color));
        var hb: [40]u8 = undefined;
        const hilo = gw.hiLoText(d, units, &hb);
        const hx = tx + cond_w + 14;
        if (hilo.len > 0 and right - hx >= @as(i32, @intCast(c.textWidth(hilo)))) {
            _ = c.drawTextA(hx, b1, hilo, widgets.dim(th.text_color, 0xA0));
        }
        var pb: [112]u8 = undefined;
        const place = gw.placeText(d, &pb);
        if (place.len > 0) {
            const marker = "\u{f041}";
            const room = l.forecast.x - 8 - tx;
            const mw: i32 = @intCast(c.textWidth(marker));
            if (room > mw + 30) {
                _ = c.drawTextA(tx, b3, marker, th.border_color);
                _ = c.drawTextA(tx + mw + 6, b3, widgets.fitText(c, place, room - mw - 6, &fit), widgets.dim(th.text_color, 0xC0));
            }
        }

        // Refresh (dim while a request runs) and the full-forecast link.
        const busy = w.svc.in_flight != null;
        iconButton(c, font, l.refresh, GLYPH_REFRESH, self.hover == .refresh, if (busy) widgets.dim(th.text_color, 0x55) else widgets.dim(th.text_color, 0xC8));
        iconButton(c, font, l.forecast, GLYPH_OPEN, self.hover == .forecast, widgets.dim(th.text_color, 0xC8));
    }

    fn renderDetails(self: *const WeatherTab, c: widgets.Canvas, font: *font_mod.Font, w: *const widgets.WeatherWidget, h24: bool) void {
        const th = c.theme;
        const asc: i32 = @intCast(font.ascentPx());
        const desc: i32 = @intCast(font.descentPx());
        const lh = asc + desc;
        var vb: [40]u8 = undefined;
        var fit: [64]u8 = undefined;
        for (self.layout.details, 0..) |r, i| {
            const det: gw.Detail = @enumFromInt(i);
            const x = r.x + gw.DETAIL_PAD + 2;
            const inner = @max(r.w - 2 * gw.DETAIL_PAD - 4, 0);
            const spare = @max(r.h - (2 * lh + 4), 0);
            const b1 = r.y + @divTrunc(spare, 2) + asc;
            const b2 = b1 + lh + 4;
            // Icon in the accent, in its own box (weather glyphs run wider
            // than a cell); label dimmed over the value at full strength.
            const box = @min(2 * lh, @max(r.h - 2 * gw.DETAIL_PAD, 0));
            _ = widgets.drawIconFit(c, toRect(r), det.glyph(), x, r.y + @divTrunc(r.h - box, 2), box, box, 2, th.border_color, false);
            const vx = x + box + 8;
            const vw = @max(inner - box - 8, 0);
            _ = c.drawTextA(vx, b1, widgets.fitText(c, det.label(), vw, &fit), widgets.dim(th.text_color, 0x99));
            const v = gw.detailValue(det, &w.svc.data, w.svc.units, h24, &vb);
            _ = c.drawTextA(vx, b2, widgets.fitText(c, v, vw, &fit), th.text_color);
        }
    }

    fn renderHourly(self: *const WeatherTab, c: widgets.Canvas, font: *font_mod.Font, w: *const widgets.WeatherWidget, h24: bool, radius: i32) void {
        const th = c.theme;
        const l = &self.layout;
        const d = &w.svc.data;
        const asc: i32 = @intCast(font.ascentPx());
        const lh: i32 = @intCast(widgets.lineH(font));
        if (l.titles) heading(c, l.hourly, asc, "Hourly");
        if (l.hour_count == 0) {
            centred(c, l.hourly, asc, lh, "The hourly forecast arrives with the next refresh.");
            return;
        }
        const hours = d.hours();
        // The day a midnight cell starts (the series spans at most one).
        const next_day: []const u8 = if (d.forecast_len > 1) d.forecast[1].day_name.slice() else "";
        for (l.hours(), 0..) |cell, i| {
            const hp = &hours[i];
            if (self.hover == .hour and self.hover.hour == i) highlight(c, cell, radius);
            const rows = gw.cellRows(cell, lh, l.icon_h);
            const cx = cell.x + @divTrunc(cell.w, 2);
            var lb: [12]u8 = undefined;
            const label = gw.hourLabel(hp.hour, i, h24, next_day, &lb);
            const col = if (i == 0) th.text_color else if (hp.hour == 0) th.border_color else widgets.dim(th.text_color, 0xAA);
            drawCentred(c, cx, rows[0] + asc, label, col);
            self.stripIcon(c, cell, rows[1], wsvc.iconFor(hp.w_code, hp.is_day), wsvc.tintFor(hp.w_code, hp.is_day));
            var tb: [16]u8 = undefined;
            drawCentred(c, cx, rows[2] + asc, gw.tempText(hp.temp(w.svc.units), &tb), th.text_color);
            if (gw.showsRain(hp.precip_prob)) rainChance(c, cx, rows[3] + asc, hp.precip_prob);
        }
    }

    fn renderDaily(self: *const WeatherTab, c: widgets.Canvas, font: *font_mod.Font, w: *const widgets.WeatherWidget, radius: i32) void {
        const th = c.theme;
        const l = &self.layout;
        const d = &w.svc.data;
        const units = w.svc.units;
        const asc: i32 = @intCast(font.ascentPx());
        const desc: i32 = @intCast(font.descentPx());
        const lh: i32 = asc + desc;
        if (l.titles) heading(c, l.daily, asc, "7-day forecast");
        if (l.day_count == 0) {
            centred(c, l.daily, asc, lh, "The daily forecast arrives with the next refresh.");
            return;
        }
        const days = d.days()[0..l.day_count];
        const week = gw.weekRange(days, units) orelse return;
        for (l.days(), 0..) |cell, i| {
            const day = &days[i];
            if (self.hover == .day and self.hover.day == i) highlight(c, cell, radius);
            const rows = gw.cellRows(cell, lh, l.icon_h);
            const cx = cell.x + @divTrunc(cell.w, 2);
            drawCentred(c, cx, rows[0] + asc, gw.dayLabel(i, day.day_name.slice()), if (i == 0) th.text_color else widgets.dim(th.text_color, 0xAA));
            self.stripIcon(c, cell, rows[1], wsvc.iconFor(day.w_code, true), wsvc.tintFor(day.w_code, true));

            // Low, a bar of the day's span within the week's range, high.
            var lob: [16]u8 = undefined;
            var hib: [16]u8 = undefined;
            const lo = gw.tempText(day.min(units), &lob);
            const hi = gw.tempText(day.max(units), &hib);
            const lo_w: i32 = @intCast(c.textWidth(lo));
            const hi_w: i32 = @intCast(c.textWidth(hi));
            const inset: i32 = 8;
            const base = rows[2] + asc;
            _ = c.drawTextA(cell.x + inset, base, lo, widgets.dim(th.text_color, 0x99));
            _ = c.drawTextA(cell.x + cell.w - inset - hi_w, base, hi, th.text_color);
            const tx0 = cell.x + inset + lo_w + 6;
            const track_w = cell.x + cell.w - inset - hi_w - 6 - tx0;
            if (track_w >= 12) {
                const bar_h: i32 = 4;
                const by = rows[2] + @divTrunc(lh - bar_h, 2);
                gv.fillRounded(c, .{ .x = tx0, .y = by, .w = track_w, .h = bar_h }, 2, 0x26FFFFFF, 0);
                const span = gw.rangeSpan(week, day.min(units), day.max(units), track_w, bar_h * 2);
                gv.fillRounded(c, .{ .x = tx0 + span[0], .y = by, .w = span[1], .h = bar_h }, 2, th.border_color | 0xFF000000, 0);
            }
            if (gw.showsRain(day.precip_prob)) rainChance(c, cx, rows[3] + asc, day.precip_prob);
        }
    }

    /// A strip cell's condition icon: 2x when the layout has room, else 1x.
    fn stripIcon(self: *const WeatherTab, c: widgets.Canvas, cell: g.Rect, top: i32, cp: u32, tint_raw: u32) void {
        const tint = if (tint_raw != 0) tint_raw else c.theme.text_color;
        const max_scale: u32 = if (self.layout.big_icons) 2 else 1;
        _ = widgets.drawIconFit(c, toRect(cell), cp, cell.x, top, cell.w, self.layout.icon_h, max_scale, tint, false);
    }

    // --- empty and error states -----------------------------------------------------

    fn renderEmpty(self: *WeatherTab, c: widgets.Canvas, content: g.Rect, font: *font_mod.Font, w: *const widgets.WeatherWidget) void {
        const th = c.theme;
        const e = gw.emptyState(w.svc.status(), w.svc.data.loading);
        const asc: i32 = @intCast(font.ascentPx());
        const lh: i32 = @intCast(widgets.lineH(font));
        const icon_box: i32 = 4 * lh;
        const block_h = icon_box + 14 + lh + 8 + lh + (if (e.retry) 18 + gw.BTN + 4 else 0);
        const top = content.y + @divTrunc(content.h - block_h, 2);
        // Large and quiet: a map marker for location trouble, else the
        // weather font's "not available".
        const cp: u32 = switch (w.svc.status()) {
            .no_location, .city_not_found, .locating => 0xF041, // map-marker
            else => 0xE374, // na
        };
        // drawIconFit paints coverage in an opaque colour: mix it quiet.
        _ = widgets.drawIconFit(c, toRect(content), cp, content.x, top, content.w, icon_box, 4, mix(th.text_color, th.bg_color, 0.6), false);
        const b1 = top + icon_box + 14 + asc;
        const b2 = b1 + lh + 8;
        var fit: [200]u8 = undefined;
        drawCentred(c, content.x + @divTrunc(content.w, 2), b1, e.title, th.text_color);
        drawCentred(c, content.x + @divTrunc(content.w, 2), b2, widgets.fitText(c, e.line, content.w - 40, &fit), widgets.dim(th.text_color, 0x99));
        if (!e.retry) {
            self.retry = null;
            return;
        }
        const label = "Try again";
        const bw: i32 = @as(i32, @intCast(c.textWidth(label))) + 2 * 18;
        const r = gw.emptyRetryRect(content, b2 + @as(i32, @intCast(font.descentPx())), bw);
        self.retry = r;
        const hot = self.hover == .refresh;
        gv.fillRounded(c, r, @divTrunc(r.h, 2), (th.border_color & 0x00FFFFFF) | (if (hot) @as(u32, 0xFF000000) else 0xE6000000), 0);
        drawCentred(c, r.x + @divTrunc(r.w, 2), r.y + @divTrunc(r.h + asc - @as(i32, @intCast(font.descentPx())), 2), label, th.bg_color | 0xFF000000);
    }
};

// --- small painters ---------------------------------------------------------------

/// Opaque 0xFFRRGGBB, `t` of the way from a to b.
fn mix(a: u32, b: u32, t: f32) u32 {
    var out: u32 = 0xFF000000;
    inline for (.{ 16, 8, 0 }) |sh| {
        const x: f32 = @floatFromInt((a >> sh) & 0xFF);
        const y: f32 = @floatFromInt((b >> sh) & 0xFF);
        out |= @as(u32, @intFromFloat(@round(x + (y - x) * t))) << sh;
    }
    return out;
}

fn toRect(r: g.Rect) widgets.Rect {
    return .{ .x = r.x, .y = r.y, .w = @intCast(@max(r.w, 0)), .h = @intCast(@max(r.h, 0)) };
}

fn tile(c: widgets.Canvas, r: g.Rect, radius: i32) void {
    if (r.w <= 0 or r.h <= 0) return;
    gv.fillRounded(c, r, radius, 0x0FFFFFFF, 0x1CFFFFFF);
}

fn highlight(c: widgets.Canvas, cell: g.Rect, radius: i32) void {
    gv.fillRounded(c, .{ .x = cell.x + 2, .y = cell.y, .w = cell.w - 4, .h = cell.h }, radius, 0x14FFFFFF, 0);
}

fn drawCentred(c: widgets.Canvas, cx: i32, baseline: i32, text: []const u8, color: u32) void {
    const tw: i32 = @intCast(c.textWidth(text));
    _ = c.drawTextA(cx - @divTrunc(tw, 2), baseline, text, color);
}

/// A strip's heading, top-left inside it.
fn heading(c: widgets.Canvas, r: g.Rect, asc: i32, text: []const u8) void {
    _ = c.drawTextA(r.x + gw.TILE_PAD + 2, r.y + gw.TILE_PAD + asc, text, widgets.dim(c.theme.text_color, 0x99));
}

/// One dim line in the middle of a strip (no series to show yet).
fn centred(c: widgets.Canvas, r: g.Rect, asc: i32, lh: i32, text: []const u8) void {
    var fit: [120]u8 = undefined;
    const t = widgets.fitText(c, text, r.w - 2 * gw.TILE_PAD, &fit);
    drawCentred(c, r.x + @divTrunc(r.w, 2), r.y + @divTrunc(r.h - lh, 2) + asc, t, widgets.dim(c.theme.text_color, 0x88));
}

/// "<raindrop> 40%" in the card's rain blue, centred on cx.
fn rainChance(c: widgets.Canvas, cx: i32, baseline: i32, prob: u32) void {
    var ib: [4]u8 = undefined;
    const il = std.unicode.utf8Encode(@intCast(GLYPH_RAIN), &ib) catch 0;
    var pb: [8]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{d}%", .{prob}) catch "";
    const iw: i32 = @intCast(c.textWidth(ib[0..il]));
    const pw: i32 = @intCast(c.textWidth(p));
    const x0 = cx - @divTrunc(iw + 4 + pw, 2);
    _ = c.drawTextA(x0, baseline, ib[0..il], widgets.dim(RAIN_BLUE, 0xDD));
    _ = c.drawTextA(x0 + iw + 4, baseline, p, widgets.dim(RAIN_BLUE, 0xDD));
}

/// A round icon button: a soft disc under the pointer, the glyph centred.
fn iconButton(c: widgets.Canvas, font: *font_mod.Font, r: g.Rect, glyph: []const u8, hot: bool, color: u32) void {
    if (hot) gv.fillRounded(c, r, @divTrunc(r.w, 2), 0x1AFFFFFF, 0);
    const gw_px: i32 = @intCast(c.textWidth(glyph));
    const asc: i32 = @intCast(font.ascentPx());
    const desc: i32 = @intCast(font.descentPx());
    _ = c.drawTextA(r.x + @divTrunc(r.w - gw_px, 2), r.y + @divTrunc(r.h + asc - desc, 2), glyph, if (hot) c.theme.text_color else color);
}

/// Distance from a scaled digit's top to its baseline, so the big
/// temperature can be placed by its top edge.
fn capTop(font: *font_mod.Font, scale: u32) i32 {
    const big = font.glyphScaled('0', scale) catch return @intCast(font.ascentPx() * @as(i32, @intCast(scale)));
    defer font.gpa.free(big.pixels);
    return @intCast(big.bitmap_top);
}
