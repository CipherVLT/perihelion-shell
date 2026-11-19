//! Glance's Media tab, the live side: the state probe through the shared
//! Fetcher, the large cover, actions spawned as argv, and the painting.
//! The rules (probe format, layout, hit-testing, drags, argv) live in
//! glance_media.zig and are unit-tested there.
//!
//! Exists only while the Media tab is on screen: glance_view.zig creates it
//! when the tab is shown and frees it when another tab is picked or Glance
//! closes, so no probe, download or timer runs otherwise.

const std = @import("std");
const posix = std.posix;
const font_mod = @import("font");
const logging = @import("logging");
const widgets = @import("widgets");
const art = @import("art");
const g = @import("glance.zig");
const gm = @import("glance_media.zig");
const gv = @import("glance_view.zig");

/// Where an http(s) cover lands before decode (the desktop card has its own).
const ART_FILE: [:0]const u8 = "/tmp/perihelionbar-shell-glance-art.bin";

const GLYPH_SHUFFLE = "\u{f074}";
const GLYPH_PREV = "\u{f048}";
const GLYPH_PLAY = "\u{f04b}";
const GLYPH_PAUSE = "\u{f04c}";
const GLYPH_NEXT = "\u{f051}";
const GLYPH_REPEAT = "\u{f01e}";
const GLYPH_NOTE = "\u{f001}";
const GLYPH_MUTED = "\u{f026}";

/// Live volume while dragging the slider: at most this often.
const VOLUME_LIVE_MS: i64 = 100;

extern "c" fn clock_gettime(clockid: c_int, tp: *posix.timespec) c_int;

fn nowMs() i64 {
    var tp: posix.timespec = undefined;
    if (clock_gettime(1, &tp) != 0) return 0; // CLOCK_MONOTONIC
    return @as(i64, @intCast(tp.sec)) * 1000 + @divTrunc(@as(i64, @intCast(tp.nsec)), 1_000_000);
}

pub const MediaTab = struct {
    gpa: std.mem.Allocator,
    probe: widgets.Fetcher = .{},
    art_fetch: widgets.Fetcher = .{},
    st: gm.State = .{},
    have_probe: bool = false,
    probed_ms: i64 = 0,
    next_probe_ms: i64 = 0,
    /// The second the progress was last painted at (repaint only when it moves).
    painted_sec: i64 = -1,
    /// The player the user picked ("" = playerctl's default).
    chosen: gm.Text(128) = .{},
    layout: gm.Layout = .{},
    drag: gm.Drag = .{},
    press_hit: ?gm.Hit = null,
    hover: gm.Hit = .none,
    vol_held: gm.Held(u8) = .{},
    seek_held: gm.Held(u64) = .{},
    vol_sent_ms: i64 = 0,
    /// Last level sent to pactl (255: none yet; the slider tops out at 100).
    vol_sent: u8 = 255,
    art_url: gm.Text(500) = .{},
    art_state: enum { none, loading, ready, failed } = .none,
    art_px: ?[]u8 = null,
    art_size: u16 = 0,
    art_w: u16 = 0,
    art_h: u16 = 0,

    pub fn deinit(self: *MediaTab) void {
        if (self.probe.busy()) self.probe.closeFd();
        if (self.art_fetch.busy()) self.art_fetch.closeFd();
        if (self.art_px) |p| self.gpa.free(p);
        self.art_px = null;
    }

    // --- schedule -------------------------------------------------------------

    pub fn pollFds(self: *const MediaTab, out: []posix.fd_t) usize {
        var n: usize = 0;
        for ([_]posix.fd_t{ self.probe.fd(), self.art_fetch.fd() }) |fd| {
            if (fd < 0 or n == out.len) continue;
            out[n] = fd;
            n += 1;
        }
        return n;
    }

    /// When the tab must be looked at again: the next probe, or the next
    /// whole second of the progress while playing.
    pub fn deadline(self: *const MediaTab, now: i64) i64 {
        var d = self.next_probe_ms;
        if (self.st.status == .playing and self.st.len_us > 0) {
            const p = self.shownPos(now);
            d = @min(d, now + @as(i64, @intCast((1_000_000 - p % 1_000_000) / 1000)) + 5);
        }
        return d;
    }

    /// Starts a due probe; true when the panel must repaint (a new second).
    pub fn tick(self: *MediaTab, now: i64) bool {
        if (now >= self.next_probe_ms and !self.probe.busy()) {
            var argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", gm.PROBE, "glance-media", self.chosen.z().ptr, null };
            self.probe.start("/bin/sh", &argv);
            self.next_probe_ms = now + gm.PROBE_MS;
        }
        if (self.st.status != .playing) return false;
        const sec: i64 = @intCast(self.shownPos(now) / 1_000_000);
        if (sec == self.painted_sec) return false;
        self.painted_sec = sec;
        return true;
    }

    /// Reads finished fetches; true when something shown changed.
    pub fn onPipes(self: *MediaTab) bool {
        var changed = false;
        if (self.probe.busy() and widgets.fdReadable(self.probe.fd())) {
            var out: [10240]u8 = undefined;
            const n = self.probe.onReadable(&out);
            if (n > 0 or self.probe.eof) {
                self.probe.closeFd();
                self.applyProbe(out[0..n]);
                changed = true;
            }
        }
        if (self.art_fetch.busy() and widgets.fdReadable(self.art_fetch.fd())) {
            var out: [64]u8 = undefined;
            _ = self.art_fetch.onReadable(&out);
            if (self.art_fetch.eof) {
                self.art_fetch.closeFd();
                self.decodeArt(ART_FILE);
                changed = true;
            }
        }
        return changed;
    }

    fn applyProbe(self: *MediaTab, text: []const u8) void {
        self.st = gm.parseState(text);
        self.probed_ms = nowMs();
        self.have_probe = true;
        // The picked player went away: back to the default.
        if (self.chosen.len > 0) {
            var still = false;
            for (self.st.playerList()) |*p| still = still or std.mem.eql(u8, p.slice(), self.chosen.slice());
            if (!still) self.chosen.set("");
        }
        self.updateArt();
    }

    // --- cover -------------------------------------------------------------------

    fn updateArt(self: *MediaTab) void {
        const url = self.st.art_url.slice();
        if (std.mem.eql(u8, url, self.art_url.slice())) return;
        self.art_url.set(url);
        self.art_state = .none;
        if (self.art_fetch.busy()) self.art_fetch.closeFd();
        if (url.len == 0) return;
        var pbuf: [512]u8 = undefined;
        if (widgets.MediaWidget.fileUrlPath(url, &pbuf)) |path| {
            self.decodeArt(path);
            return;
        }
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
            self.art_state = .failed;
            return;
        }
        // The URL is one argv word: no shell, so no quoting to get wrong.
        var argv = [_:null]?[*:0]const u8{
            "env",                "curl", "-sS", "--fail",           "--compressed", "--connect-timeout", "5",
            "--max-time",         "10",   "-A",  "perihelion-shell", "-o",           ART_FILE,            "--url",
            self.art_url.z().ptr, null,
        };
        self.art_fetch.start(gm.ENV, &argv);
        self.art_state = if (self.art_fetch.busy()) .loading else .failed;
    }

    fn decodeArt(self: *MediaTab, path: [:0]const u8) void {
        const size = self.art_size;
        if (size == 0) {
            self.art_state = .failed;
            return;
        }
        const need = @as(usize, size) * size * 4;
        if (self.art_px == null or self.art_px.?.len != need) {
            if (self.art_px) |p| self.gpa.free(p);
            self.art_px = self.gpa.alloc(u8, need) catch null;
        }
        const buf = self.art_px orelse {
            self.art_state = .failed;
            return;
        };
        if (art.decodeInto(path, size, buf)) |d| {
            self.art_w = d.w;
            self.art_h = d.h;
            self.art_state = .ready;
        } else self.art_state = .failed;
    }

    // --- shown values ---------------------------------------------------------------

    fn shownPos(self: *const MediaTab, now: i64) u64 {
        if (now < self.seek_held.until_ms) {
            // The seek target, moving on from when it was set.
            const since = now - (self.seek_held.until_ms - @TypeOf(self.seek_held).HOLD_MS);
            var p = self.seek_held.value;
            if (self.st.status == .playing and since > 0) p += @as(u64, @intCast(since)) * 1000;
            return if (self.st.len_us > 0) @min(p, self.st.len_us) else p;
        }
        return gm.positionAt(&self.st, self.probed_ms, now);
    }

    fn shownVolume(self: *const MediaTab, now: i64) ?u8 {
        if (self.drag.kind == .volume) return self.drag.val;
        const probed = self.st.volume orelse return if (now < self.vol_held.until_ms) self.vol_held.value else null;
        return self.vol_held.get(probed, now);
    }

    // --- input ------------------------------------------------------------------------

    /// Panel-local press. True when a drag started (repaint).
    pub fn press(self: *MediaTab, x: i32, y: i32) bool {
        const h = gm.hitTest(&self.layout, self.st.hasTrack(), x, y);
        if (self.drag.press(&self.layout, h, x)) {
            self.press_hit = null;
            self.liveVolume(nowMs());
            return true;
        }
        self.press_hit = h;
        return false;
    }

    /// Panel-local motion. True when something shown changed.
    pub fn motion(self: *MediaTab, x: i32, y: i32) bool {
        if (self.drag.active()) {
            if (!self.drag.motion(&self.layout, x)) return false;
            self.liveVolume(nowMs());
            return true;
        }
        const h = gm.hitTest(&self.layout, self.st.hasTrack(), x, y);
        if (h.eql(self.hover)) return false;
        self.hover = h;
        return true;
    }

    pub fn leave(self: *MediaTab) bool {
        const was = self.hover != .none;
        self.hover = .none;
        return was;
    }

    /// The button came up. A drag commits wherever the pointer is (the
    /// surface keeps the pointer while the button is held); otherwise a
    /// press and release on the same thing is a click. True: repaint.
    pub fn release(self: *MediaTab, x: i32, y: i32) bool {
        const now = nowMs();
        if (self.drag.active()) {
            switch (self.drag.release()) {
                .none => {},
                .seek => |f| self.seekTo(f, now),
                .volume => |v| self.setVolume(v, now),
            }
            return true;
        }
        const pr = self.press_hit orelse return false;
        self.press_hit = null;
        const h = gm.hitTest(&self.layout, self.st.hasTrack(), x, y);
        if (!pr.eql(h)) return false;
        switch (h) {
            .none, .seek, .volume => return false,
            .control => |ctl| self.control(ctl, now),
            .mute => {
                var a: gm.Argv = .{};
                gm.muteArgv(&a);
                widgets.spawnDetachedArgv(gm.ENV, a.ptr());
                self.st.muted = !self.st.muted;
                self.soon(now);
            },
            .player => |i| {
                if (i >= self.st.player_count) return false;
                self.chosen.set(self.st.players[i].slice());
                self.next_probe_ms = 0; // show it now
            },
        }
        return true;
    }

    pub fn cancelDrag(self: *MediaTab) void {
        self.drag.cancel();
        self.press_hit = null;
    }

    fn soon(self: *MediaTab, now: i64) void {
        self.next_probe_ms = @min(self.next_probe_ms, now + gm.AFTER_ACTION_MS);
    }

    fn control(self: *MediaTab, ctl: gm.Control, now: i64) void {
        var a: gm.Argv = .{};
        gm.controlArgv(&a, ctl, self.st.player.z(), self.st.loop orelse .none);
        widgets.spawnDetachedArgv(gm.ENV, a.ptr());
        // Show the result right away; the next probe confirms it.
        switch (ctl) {
            .toggle => {
                const p = self.shownPos(now);
                self.st.pos_us = p;
                self.probed_ms = now;
                self.seek_held = .{};
                self.st.status = if (self.st.status == .playing) .paused else .playing;
            },
            .shuffle => self.st.shuffle = !(self.st.shuffle orelse false),
            .loop => self.st.loop = @as(gm.Loop, self.st.loop orelse gm.Loop.none).next(),
            .prev, .next => {},
        }
        self.soon(now);
    }

    fn seekTo(self: *MediaTab, frac: f64, now: i64) void {
        if (self.st.len_us == 0) return;
        var a: gm.Argv = .{};
        gm.seekArgv(&a, self.st.player.z(), self.st.len_us, frac);
        widgets.spawnDetachedArgv(gm.ENV, a.ptr());
        self.seek_held.set(@intFromFloat(@as(f64, @floatFromInt(self.st.len_us)) * frac), now);
        self.next_probe_ms = @min(self.next_probe_ms, now + 700);
    }

    fn setVolume(self: *MediaTab, pct: u8, now: i64) void {
        if (pct != self.vol_sent) {
            var a: gm.Argv = .{};
            gm.volumeArgv(&a, pct);
            widgets.spawnDetachedArgv(gm.ENV, a.ptr());
            self.vol_sent = pct;
            self.vol_sent_ms = now;
        }
        self.vol_held.set(pct, now);
        self.soon(now);
    }

    /// While the volume slider is held: follow it, throttled.
    fn liveVolume(self: *MediaTab, now: i64) void {
        if (self.drag.kind != .volume or now - self.vol_sent_ms < VOLUME_LIVE_MS) return;
        self.setVolume(self.drag.val, now);
    }

    // --- painting -------------------------------------------------------------------

    fn chipLabels(self: *const MediaTab, bufs: *[gm.MAX_PLAYERS][40]u8, out: *[gm.MAX_PLAYERS][]const u8) []const []const u8 {
        for (self.st.playerList(), 0..) |*p, i| out[i] = gm.playerLabel(p.slice(), &bufs[i]);
        return out[0..self.st.player_count];
    }

    pub fn render(self: *MediaTab, c: widgets.Canvas, content: g.Rect, font: *font_mod.Font) void {
        const th = c.theme;
        const lh: i32 = @intCast(widgets.lineH(font));
        const asc: i32 = @intCast(font.ascentPx());
        const accent = th.border_color;
        const now = nowMs();

        var lbufs: [gm.MAX_PLAYERS][40]u8 = undefined;
        var labels: [gm.MAX_PLAYERS][]const u8 = undefined;
        const names = self.chipLabels(&lbufs, &labels);
        var widths: [gm.MAX_PLAYERS]i32 = undefined;
        for (names, 0..) |n, i| widths[i] = @intCast(c.textWidth(n));
        self.layout = gm.layout(content, lh, widths[0..names.len]);
        const l = &self.layout;

        // Cover: decoded at the tile's size the first time it's known.
        const csize: u16 = @intCast(l.cover.w);
        if (self.art_size != csize) {
            self.art_size = csize;
            if (self.art_state == .ready or self.art_state == .failed) {
                const url_again = self.art_url;
                self.art_url = .{};
                self.st.art_url = url_again;
                self.updateArt();
            }
        }
        const cr: i32 = @intCast(@max(th.radius_px, 8));
        if (self.art_state == .ready and self.art_px != null) {
            const ox = l.cover.x + @divTrunc(l.cover.w - @as(i32, self.art_w), 2);
            const oy = l.cover.y + @divTrunc(l.cover.h - @as(i32, self.art_h), 2);
            c.blitRgba(ox, oy, self.art_w, self.art_h, self.art_px.?[0 .. @as(usize, self.art_w) * self.art_h * 4], cr);
        } else {
            gv.fillRounded(c, l.cover, cr, 0x14FFFFFF, 0x1FFFFFFF);
            const gw: i32 = @intCast(c.textWidth(GLYPH_NOTE));
            _ = c.drawTextA(l.cover.x + @divTrunc(l.cover.w - gw, 2), l.cover.y + @divTrunc(l.cover.h + asc, 2), GLYPH_NOTE, widgets.dim(th.text_color, 0x66));
        }

        // Text column.
        const tx = l.text.x;
        const tw = l.text.w;
        var fit: [256]u8 = undefined;
        if (!self.have_probe) {
            _ = c.drawTextA(tx, l.text.y + asc, "Looking for players\u{2026}", widgets.dim(th.text_color, 0xAA));
        } else if (!self.st.hasTrack()) {
            _ = c.drawTextA(tx, l.text.y + asc, "Nothing playing", th.text_color);
            _ = c.drawTextA(tx, l.text.y + asc + lh + 6, widgets.fitText(c, "Start music in any player and it shows up here.", tw, &fit), widgets.dim(th.text_color, 0x99));
        } else {
            var hb: [80]u8 = undefined;
            var pb: [40]u8 = undefined;
            const state: []const u8 = switch (self.st.status) {
                .playing => "Playing",
                .paused => "Paused",
                .stopped => "Stopped",
                .none => "",
            };
            const head = std.fmt.bufPrint(&hb, "{s} \u{b7} {s}", .{ gm.playerLabel(self.st.player.slice(), &pb), state }) catch "";
            _ = c.drawTextA(tx, l.text.y + asc, head, accent);
            const title = if (self.st.title.len > 0) self.st.title.slice() else "Unknown title";
            _ = c.drawTextA(tx, l.text.y + asc + lh + 6, widgets.fitText(c, title, tw, &fit), th.text_color);
            if (self.st.artist.len > 0) _ = c.drawTextA(tx, l.text.y + asc + 2 * lh + 10, widgets.fitText(c, self.st.artist.slice(), tw, &fit), widgets.dim(th.text_color, 0xC0));
            if (self.st.album.len > 0) _ = c.drawTextA(tx, l.text.y + asc + 3 * lh + 12, widgets.fitText(c, self.st.album.slice(), tw, &fit), widgets.dim(th.text_color, 0x88));
            self.renderSeek(c, now, asc);
            self.renderControls(c, asc);
        }
        self.renderVolume(c, now, asc, lh);
        self.renderChips(c, names, asc);
        self.painted_sec = @intCast(self.shownPos(now) / 1_000_000);
    }

    fn renderSeek(self: *MediaTab, c: widgets.Canvas, now: i64, asc: i32) void {
        const l = &self.layout;
        const th = c.theme;
        const len = self.st.len_us;
        const pos: u64 = if (self.drag.kind == .seek) @intFromFloat(@as(f64, @floatFromInt(len)) * self.drag.frac) else self.shownPos(now);
        const hot = self.drag.kind == .seek or self.hover == .seek;
        const r = l.seek;
        gv.fillRounded(c, r, @divTrunc(r.h, 2), 0x2EFFFFFF, 0);
        if (len > 0) {
            const fw: i32 = @intFromFloat(@as(f64, @floatFromInt(r.w)) * @as(f64, @floatFromInt(@min(pos, len))) / @as(f64, @floatFromInt(len)));
            if (fw > 0) gv.fillRounded(c, .{ .x = r.x, .y = r.y, .w = @max(fw, r.h), .h = r.h }, @divTrunc(r.h, 2), th.border_color | 0xFF000000, 0);
            const kr: i32 = if (hot) 8 else 6;
            gv.fillRounded(c, .{ .x = r.x + fw - kr, .y = r.y + @divTrunc(r.h, 2) - kr, .w = 2 * kr, .h = 2 * kr }, kr, th.text_color | 0xFF000000, 0);
        }
        var b1: [16]u8 = undefined;
        var b2: [16]u8 = undefined;
        const left = gm.formatTime(pos, &b1);
        const right: []const u8 = if (len > 0) gm.formatTime(len, &b2) else "--:--";
        const ty = l.times_y - widgetsDesc(c) + 0;
        _ = asc;
        const tc = widgets.dim(th.text_color, 0xAA);
        _ = c.drawTextA(r.x, ty, left, tc);
        _ = c.drawTextA(r.x + r.w - @as(i32, @intCast(c.textWidth(right))), ty, right, tc);
    }

    fn widgetsDesc(c: widgets.Canvas) i32 {
        return @intCast(c.font.descentPx());
    }

    fn renderControls(self: *MediaTab, c: widgets.Canvas, asc: i32) void {
        const th = c.theme;
        const glyphs = [_][]const u8{ GLYPH_SHUFFLE, GLYPH_PREV, if (self.st.status == .playing) GLYPH_PAUSE else GLYPH_PLAY, GLYPH_NEXT, GLYPH_REPEAT };
        for (self.layout.controls, 0..) |r, i| {
            const ctl: gm.Control = @fromBackingInt(@intCast(i));
            const hovered = self.hover == .control and self.hover.control == ctl;
            var col = th.text_color;
            if (ctl == .toggle) {
                // The main button: an accent disc, the glyph in the panel colour.
                gv.fillRounded(c, r, @divTrunc(r.w, 2), (th.border_color & 0x00FFFFFF) | (if (hovered) @as(u32, 0xFF000000) else 0xE6000000), 0);
                col = th.bg_color | 0xFF000000;
            } else {
                if (hovered) gv.fillRounded(c, r, @divTrunc(r.w, 2), 0x1AFFFFFF, 0);
                const on: ?bool = switch (ctl) {
                    .shuffle => self.st.shuffle,
                    .loop => if (self.st.loop) |lp| lp != .none else null,
                    else => true,
                };
                col = if (on == null) widgets.dim(th.text_color, 0x40) else if (on.?) (if (ctl == .shuffle or ctl == .loop) th.border_color else th.text_color) else widgets.dim(th.text_color, 0x80);
            }
            const gw: i32 = @intCast(c.textWidth(glyphs[i]));
            _ = c.drawTextA(r.x + @divTrunc(r.w - gw, 2), r.y + @divTrunc(r.h + asc - widgetsDesc(c), 2), glyphs[i], col);
            if (ctl == .loop and self.st.loop == .track) {
                // Repeat one: a small "1" under the glyph.
                _ = c.drawTextA(r.x + @divTrunc(r.w, 2) + 6, r.y + r.h - 6, "1", th.border_color);
            }
        }
    }

    fn renderVolume(self: *MediaTab, c: widgets.Canvas, now: i64, asc: i32, lh: i32) void {
        _ = lh;
        const l = &self.layout;
        const th = c.theme;
        const vol = self.shownVolume(now);
        const muted = self.st.muted;
        const mhov = self.hover == .mute;
        if (mhov) gv.fillRounded(c, l.mute, @divTrunc(l.mute.w, 2), 0x1AFFFFFF, 0);
        // The Control Center's speaker tiers (shared volume module).
        const glyph = if (muted) GLYPH_MUTED else gm.volmath.iconFor(vol orelse 0);
        const gw: i32 = @intCast(c.textWidth(glyph));
        _ = c.drawTextA(l.mute.x + @divTrunc(l.mute.w - gw, 2), l.mute.y + @divTrunc(l.mute.h + asc - widgetsDesc(c), 2), glyph, if (muted) widgets.dim(th.text_color, 0x80) else th.text_color);
        const r = l.volume;
        gv.fillRounded(c, r, @divTrunc(r.h, 2), 0x2EFFFFFF, 0);
        var pb: [8]u8 = undefined;
        const label: []const u8 = if (vol) |v| gm.volmath.valueText(muted, v, &pb) else "\u{2014}";
        if (vol) |v| {
            const fw: i32 = gm.volumeX(r, @min(v, 100)) - r.x;
            const fill: u32 = if (muted) widgets.dim(th.text_color, 0x60) else th.border_color | 0xFF000000;
            if (fw > 0) gv.fillRounded(c, .{ .x = r.x, .y = r.y, .w = @max(fw, r.h), .h = r.h }, @divTrunc(r.h, 2), fill, 0);
            const kr: i32 = if (self.drag.kind == .volume or self.hover == .volume) 8 else 6;
            gv.fillRounded(c, .{ .x = r.x + fw - kr, .y = r.y + @divTrunc(r.h, 2) - kr, .w = 2 * kr, .h = 2 * kr }, kr, th.text_color | 0xFF000000, 0);
        }
        _ = c.drawTextA(r.x + r.w + 14, r.y + @divTrunc(r.h + asc - widgetsDesc(c), 2), label, widgets.dim(th.text_color, 0xC0));
    }

    fn renderChips(self: *MediaTab, c: widgets.Canvas, names: []const []const u8, asc: i32) void {
        const th = c.theme;
        for (self.layout.chips[0..self.layout.chip_count], 0..) |r, i| {
            const current = std.mem.eql(u8, self.st.players[i].slice(), self.st.player.slice());
            const hovered = self.hover == .player and self.hover.player == i;
            const fill: u32 = if (current) (th.border_color & 0x00FFFFFF) | 0xE6000000 else if (hovered) 0x24FFFFFF else 0x14FFFFFF;
            gv.fillRounded(c, r, @divTrunc(r.h, 2), fill, 0);
            const tw: i32 = @intCast(c.textWidth(names[i]));
            const col: u32 = if (current) th.bg_color | 0xFF000000 else th.text_color;
            _ = c.drawTextA(r.x + @divTrunc(r.w - tw, 2), r.y + @divTrunc(r.h + asc - widgetsDesc(c), 2), names[i], col);
        }
    }
};
