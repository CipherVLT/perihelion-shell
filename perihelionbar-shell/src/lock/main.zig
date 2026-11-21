//! perihelion-lockscreen — Perihelion's session lock (ext-session-lock-v1).
//!
//! One lock object, one lock surface per output (monitors plugged in while
//! locked get theirs as soon as they appear), and a PAM worker thread for
//! the password. /usr/bin/perihelion-lock runs it with -f, which returns
//! only once the compositor has confirmed the lock and every output has
//! shown a locked frame (or 2 s have passed), so swayidle's before-sleep
//! hook cannot suspend an unlocked screen.
//!
//! Safety rules:
//!   * Only a correct password unlocks. No signal, crash or error path ever
//!     sends unlock_and_destroy; SIGTERM/SIGINT/SIGHUP exit with the session
//!     still locked, and the compositor keeps it locked (Mango covers the
//!     screen with its locked background). Starting the locker again from a
//!     text console takes the lock back over.
//!   * A second start while a lock is active is refused by the compositor
//!     with `finished`; it exits 0 and leaves the first lock alone.
//!   * The password lives in a locked (never swapped) buffer and is wiped
//!     with secureZero after every attempt and on exit. Nothing is logged
//!     about it — not even its length.
//!
//! Logs: state changes only (locked, unlocked, wrong attempt, PAM
//! unavailable, surfaces added and removed), in the shell's log folder.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;
const logging = @import("logging");
const logic = @import("logic.zig");
const auth = @import("auth.zig");
const paint = @import("paint.zig");
const image = @import("image.zig");
const Image = image.Image;
const c = @import("c.zig");
const cairo = c.cairo;

pub const panic = std.debug.FullPanic(logging.panicHandler);

const USAGE =
    \\usage: perihelion-lockscreen [-f]
    \\  Locks the session (ext-session-lock-v1) until the account password
    \\  is entered.
    \\  -f, --daemonize  return once the screen is locked and keep running
    \\                   in the background (what swayidle needs)
    \\
;

// --- libc -------------------------------------------------------------------

const libc = struct {
    extern "c" fn fork() c_int;
    extern "c" fn setsid() c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn time(t: ?*i64) i64;
    extern "c" fn localtime_r(timer: *const i64, result: *Tm) ?*Tm;
    extern "c" fn clock_gettime(clockid: c_int, tp: *linux.timespec) c_int;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    extern "c" fn dup2(a: c_int, b: c_int) c_int;
    extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
    extern "c" fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
    extern "c" fn ftruncate(fd: c_int, len: i64) c_int;
    /// libc's poll: returns -1 (EINTR) when a stop signal arrives, where
    /// std.posix.poll would retry and only notice at the next timeout.
    extern "c" fn poll(fds: [*]posix.pollfd, n: c_ulong, timeout: c_int) c_int;

    const O_RDONLY = 0;
    const O_RDWR = 2;
    const O_CLOEXEC = 0o2000000;
    const MFD_CLOEXEC = 1;

    const Tm = extern struct {
        sec: c_int,
        min: c_int,
        hour: c_int,
        mday: c_int,
        mon: c_int,
        year: c_int,
        wday: c_int,
        yday: c_int,
        isdst: c_int,
        gmtoff: c_long,
        zone: ?[*:0]const u8,
    };
};

fn nowMs() i64 {
    var tp: linux.timespec = undefined;
    if (libc.clock_gettime(1, &tp) != 0) return 0; // CLOCK_MONOTONIC
    return @as(i64, @intCast(tp.sec)) * 1000 + @divTrunc(@as(i64, @intCast(tp.nsec)), 1_000_000);
}

fn localNow() libc.Tm {
    var tm = std.mem.zeroes(libc.Tm);
    const now = libc.time(null);
    _ = libc.localtime_r(&now, &tm);
    return tm;
}

fn printErr(text: []const u8) void {
    _ = libc.write(2, text.ptr, text.len);
}

/// Reads a small file into `buf` (truncated at buf.len). Null when missing.
fn readSmall(path: [:0]const u8, buf: []u8) ?[]u8 {
    const fd = libc.open(path.ptr, libc.O_RDONLY | libc.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = libc.close(fd);
    var got: usize = 0;
    while (got < buf.len) {
        const n = libc.read(fd, buf[got..].ptr, buf.len - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    return buf[0..got];
}

// --- signals ------------------------------------------------------------------

/// SIGTERM, SIGINT, SIGHUP: stop the loop and exit with the session still
/// locked. They never unlock.
var g_stop = std.atomic.Value(bool).init(false);

fn onStopSignal(_: posix.SIG) callconv(.c) void {
    g_stop.store(true, .release);
}

fn installSignals() void {
    const stop = posix.Sigaction{ .handler = .{ .handler = onStopSignal }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.TERM, &stop, null);
    posix.sigaction(.INT, &stop, null);
    posix.sigaction(.HUP, &stop, null);
    const ignore = posix.Sigaction{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.PIPE, &ignore, null);
}

// --- buffers and surfaces -------------------------------------------------------

const Buffer = struct {
    wl_buffer: ?*wl.Buffer = null,
    mem: []align(std.heap.page_size_min) u8 = &.{},
    surf: ?*cairo.Surface = null,
    busy: bool = false,
    owner: ?*LockSurface = null,

    fn deinit(self: *Buffer) void {
        if (self.surf) |s| cairo.cairo_surface_destroy(s);
        if (self.wl_buffer) |b| b.destroy();
        if (self.mem.len > 0) posix.munmap(self.mem);
        self.* = .{};
    }
};

fn bufferListener(_: *wl.Buffer, event: wl.Buffer.Event, buf: *Buffer) void {
    switch (event) {
        .release => {
            buf.busy = false;
            if (buf.owner) |ls| if (ls.dirty) ls.out.st.paintSurface(ls);
        },
    }
}

const LockSurface = struct {
    out: *Output,
    surface: *wl.Surface,
    lock_surface: *ext.SessionLockSurfaceV1,
    /// Logical size from configure; the buffers are this times the scale.
    w: u32 = 0,
    h: u32 = 0,
    configured: bool = false,
    presented: bool = false,
    dirty: bool = false,
    bufs: [2]Buffer = .{ .{}, .{} },
    buf_w: u32 = 0,
    buf_h: u32 = 0,
    /// The backdrop (wallpaper + tint + fades) at buffer size, copied into
    /// each frame so a keystroke never re-scales the wallpaper.
    base: []u32 = &.{},
    frame_cb: ?*wl.Callback = null,

    fn destroy(self: *LockSurface, gpa: std.mem.Allocator) void {
        if (self.frame_cb) |cb| cb.destroy();
        for (&self.bufs) |*b| b.deinit();
        if (self.base.len > 0) gpa.free(self.base);
        self.lock_surface.destroy();
        self.surface.destroy();
        gpa.destroy(self);
    }
};

fn lockSurfaceListener(lsurf: *ext.SessionLockSurfaceV1, event: ext.SessionLockSurfaceV1.Event, ls: *LockSurface) void {
    switch (event) {
        .configure => |e| {
            lsurf.ackConfigure(e.serial);
            ls.w = e.width;
            ls.h = e.height;
            ls.configured = true;
            ls.out.st.paintSurface(ls);
        },
    }
}

fn frameListener(cb: *wl.Callback, event: wl.Callback.Event, ls: *LockSurface) void {
    switch (event) {
        .done => {
            cb.destroy();
            ls.frame_cb = null;
            if (!ls.presented) {
                ls.presented = true;
                ls.out.st.readiness.presented += 1;
            }
        },
    }
}

const Output = struct {
    st: *State,
    name: u32,
    wl_output: *wl.Output,
    scale: i32 = 1,
    mode_w: u32 = 0,
    mode_h: u32 = 0,
    surf: ?*LockSurface = null,
};

fn outputListener(_: *wl.Output, event: wl.Output.Event, out: *Output) void {
    switch (event) {
        .scale => |e| {
            const s = std.math.clamp(e.factor, 1, 4);
            if (s != out.scale) {
                out.scale = s;
                if (out.surf) |ls| out.st.paintSurface(ls);
            }
        },
        .mode => |e| {
            if (e.flags.current) {
                out.mode_w = @intCast(@max(0, e.width));
                out.mode_h = @intCast(@max(0, e.height));
            }
        },
        else => {},
    }
}

// --- the lock ---------------------------------------------------------------------

const State = struct {
    // Secrets first: the whole State is mlocked, these are why.
    password: logic.Password = .{},
    worker: auth.Worker = .{},

    gpa: std.mem.Allocator,
    display: *wl.Display,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    seat: ?*wl.Seat = null,
    keyboard: ?*wl.Keyboard = null,
    manager: ?*ext.SessionLockManagerV1 = null,
    lock: ?*ext.SessionLockV1 = null,
    locked_event: bool = false,
    finished_event: bool = false,
    outputs: std.ArrayList(*Output) = .empty,

    session: logic.Session = .{},
    readiness: logic.Readiness = .{ .started_ms = 0 },
    ready_fd: c_int = -1,

    user_buf: [64]u8 = undefined,
    user: []const u8 = "",
    service: []const u8 = "login",
    h24: bool = true,
    palette: logic.Palette = .{},
    wallpaper: ?Image = null,
    avatar: ?*cairo.Surface = null,

    xkb_ctx: ?*c.xkb.Context = null,
    keymap: ?*c.xkb.Keymap = null,
    xkb_state: ?*c.xkb.State = null,
    lock_index: ?u32 = null,

    /// What the last frame showed, to skip timer frames that change nothing.
    shown_minute: i32 = -1,
    shown_caret: bool = false,
    unlocked: bool = false,

    fn createSurface(self: *State, out: *Output) void {
        if (out.surf != null) return;
        const lock = self.lock orelse return;
        if (self.finished_event or self.unlocked) return;
        const compositor = self.compositor orelse return;
        const surface = compositor.createSurface() catch return;
        const lsurf = lock.getLockSurface(surface, out.wl_output) catch {
            surface.destroy();
            return;
        };
        const ls = self.gpa.create(LockSurface) catch {
            lsurf.destroy();
            surface.destroy();
            return;
        };
        ls.* = .{ .out = out, .surface = surface, .lock_surface = lsurf };
        lsurf.setListener(*LockSurface, lockSurfaceListener, ls);
        out.surf = ls;
        self.readiness.surfaces += 1;
        logging.step("lock: surface added (output {d})", .{out.name});
    }

    fn removeOutput(self: *State, name: u32) void {
        for (self.outputs.items, 0..) |out, i| {
            if (out.name != name) continue;
            if (out.surf) |ls| {
                if (ls.presented) self.readiness.presented -|= 1;
                self.readiness.surfaces -|= 1;
                ls.destroy(self.gpa);
                logging.step("lock: surface removed (output {d})", .{name});
            }
            out.wl_output.release();
            self.gpa.destroy(out);
            _ = self.outputs.swapRemove(i);
            return;
        }
    }

    /// Largest output in pixels, for decoding the wallpaper only as big as
    /// needed.
    fn coverSize(self: *const State) [2]u32 {
        var w: u32 = 0;
        var h: u32 = 0;
        for (self.outputs.items) |o| {
            w = @max(w, o.mode_w);
            h = @max(h, o.mode_h);
        }
        if (w == 0 or h == 0) return .{ 3840, 2160 };
        return .{ w, h };
    }

    fn ensureBuffers(self: *State, ls: *LockSurface, bw: u32, bh: u32) bool {
        if (ls.buf_w == bw and ls.buf_h == bh and ls.bufs[0].wl_buffer != null) return true;
        // Size changed: buffers still on screen are released by the
        // compositor later; destroying them now is allowed.
        for (&ls.bufs) |*b| b.deinit();
        if (ls.base.len > 0) self.gpa.free(ls.base);
        ls.base = &.{};
        ls.buf_w = 0;
        ls.buf_h = 0;
        const shm = self.shm orelse return false;
        const stride: usize = @as(usize, bw) * 4;
        const size = stride * bh;
        for (&ls.bufs) |*b| {
            const fd = libc.memfd_create("perihelion-lockscreen", libc.MFD_CLOEXEC);
            if (fd < 0) return false;
            defer _ = libc.close(fd);
            if (libc.ftruncate(fd, @intCast(size)) != 0) return false;
            b.mem = posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch return false;
            const pool = shm.createPool(fd, @intCast(size)) catch return false;
            defer pool.destroy();
            b.wl_buffer = pool.createBuffer(0, @intCast(bw), @intCast(bh), @intCast(stride), .argb8888) catch return false;
            b.wl_buffer.?.setListener(*Buffer, bufferListener, b);
            b.owner = ls;
            b.surf = cairo.cairo_image_surface_create_for_data(b.mem.ptr, cairo.FORMAT_ARGB32, @intCast(bw), @intCast(bh), @intCast(stride));
            if (b.surf == null) return false;
        }
        // The backdrop, built once for this size.
        ls.base = self.gpa.alloc(u32, @as(usize, bw) * bh) catch return false;
        const have_wall = self.wallpaper != null;
        if (self.wallpaper) |*img| image.blitCover(ls.base, bw, bh, img) else @memset(ls.base, 0);
        if (cairo.cairo_image_surface_create_for_data(@ptrCast(ls.base.ptr), cairo.FORMAT_ARGB32, @intCast(bw), @intCast(bh), @intCast(stride))) |bs| {
            defer cairo.cairo_surface_destroy(bs);
            if (cairo.cairo_create(bs)) |cr| {
                defer cairo.cairo_destroy(cr);
                paint.paintBackdrop(cr, @intCast(bh), have_wall, self.palette);
            }
            cairo.cairo_surface_flush(bs);
        }
        ls.buf_w = bw;
        ls.buf_h = bh;
        return true;
    }

    fn view(self: *State, clock_buf: []u8, date_buf: []u8) paint.View {
        const tm = localNow();
        return .{
            .clock = logic.formatClock(clock_buf, @intCast(tm.hour), @intCast(tm.min), self.h24),
            .date = logic.formatDate(date_buf, tm.year + 1900, @intCast(tm.mon + 1), @intCast(tm.mday)),
            .user = self.user,
            .hint = self.session.hint(),
            .dots = self.session.dots(&self.password),
            .caret_on = @mod(tm.sec, 2) == 0,
            .avatar = self.avatar,
            .palette = self.palette,
        };
    }

    fn paintSurface(self: *State, ls: *LockSurface) void {
        if (!ls.configured or ls.w == 0 or ls.h == 0 or self.unlocked) return;
        const scale: u32 = @intCast(ls.out.scale);
        const bw = ls.w * scale;
        const bh = ls.h * scale;
        if (!self.ensureBuffers(ls, bw, bh)) {
            logging.err("lock: could not allocate a {d}x{d} buffer", .{ bw, bh });
            return;
        }
        const buf = for (&ls.bufs) |*b| {
            if (!b.busy) break b;
        } else {
            ls.dirty = true; // painted when one comes back
            return;
        };
        ls.dirty = false;
        const dst: [*]u32 = @ptrCast(@alignCast(buf.mem.ptr));
        @memcpy(dst[0..ls.base.len], ls.base);
        const surf = buf.surf.?;
        cairo.cairo_surface_mark_dirty(surf);
        if (cairo.cairo_create(surf)) |cr| {
            defer cairo.cairo_destroy(cr);
            var clock_buf: [16]u8 = undefined;
            var date_buf: [48]u8 = undefined;
            const v = self.view(&clock_buf, &date_buf);
            paint.paintLock(cr, @intCast(bw), @intCast(bh), &v);
        }
        cairo.cairo_surface_flush(surf);

        ls.surface.setBufferScale(@intCast(scale));
        ls.surface.attach(buf.wl_buffer, 0, 0);
        ls.surface.damageBuffer(0, 0, @intCast(bw), @intCast(bh));
        if (!ls.presented and ls.frame_cb == null) {
            if (ls.surface.frame()) |cb| {
                ls.frame_cb = cb;
                cb.setListener(*LockSurface, frameListener, ls);
            } else |_| {}
        }
        buf.busy = true;
        ls.surface.commit();
    }

    fn paintAll(self: *State) void {
        const tm = localNow();
        self.shown_minute = tm.hour * 60 + tm.min;
        self.shown_caret = @mod(tm.sec, 2) == 0;
        for (self.outputs.items) |out| if (out.surf) |ls| self.paintSurface(ls);
    }

    /// The 1 s tick: repaint only when the minute or the caret changed.
    fn tick(self: *State) void {
        const tm = localNow();
        const minute = tm.hour * 60 + tm.min;
        const caret = @mod(tm.sec, 2) == 0;
        const caret_matters = self.session.dots(&self.password) > 0 and !self.session.auth_pending;
        if (minute != self.shown_minute or (caret_matters and caret != self.shown_caret)) self.paintAll();
    }

    /// Correct password: the only path that unlocks.
    fn unlock(self: *State) void {
        if (self.unlocked) return;
        const lock = self.lock orelse return;
        if (!self.locked_event) return;
        self.unlocked = true;
        lock.unlockAndDestroy();
        self.lock = null;
        for (self.outputs.items) |out| if (out.surf) |ls| {
            ls.destroy(self.gpa);
            out.surf = null;
        };
        _ = self.display.roundtrip();
        logging.step("lock: unlocked", .{});
    }

    fn reportReady(self: *State, byte: u8) void {
        if (self.ready_fd < 0) return;
        const one = [1]u8{byte};
        _ = libc.write(self.ready_fd, &one, 1);
        _ = libc.close(self.ready_fd);
        self.ready_fd = -1;
        self.readiness.reported = true;
    }

    fn submit(self: *State) void {
        if (self.session.submit(&self.password, &self.worker, self.service, self.user)) {
            self.paintAll();
        } else {
            logging.warn("lock: PAM unavailable (the attempt could not start)", .{});
            self.paintAll();
        }
    }

    fn authDone(self: *State) void {
        const r = self.worker.finish();
        const unlock_now = self.session.finish(&self.password, r);
        switch (r) {
            .ok => {},
            .denied => logging.step("lock: wrong attempt ({d} so far)", .{self.session.failures}),
            .unavailable => logging.warn("lock: PAM unavailable (service {s})", .{self.service}),
        }
        if (unlock_now) self.unlock() else self.paintAll();
    }

    fn wipe(self: *State) void {
        self.password.clear();
        // A thread still inside PAM owns its copy (and wipes it when PAM
        // returns); exiting takes the memory with it either way.
        if (!self.worker.running()) self.worker.wipe();
    }
};

// --- registry, seat, keyboard -------------------------------------------------------

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, st: *State) void {
    switch (event) {
        .global => |g| {
            const iface = std.mem.sliceTo(g.interface, 0);
            if (std.mem.eql(u8, iface, "wl_compositor")) {
                st.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 4)) catch return;
            } else if (std.mem.eql(u8, iface, "wl_shm")) {
                st.shm = registry.bind(g.name, wl.Shm, 1) catch return;
            } else if (std.mem.eql(u8, iface, "wl_seat")) {
                if (st.seat != null) return; // one seat is the session's seat
                const seat = registry.bind(g.name, wl.Seat, @min(g.version, 7)) catch return;
                st.seat = seat;
                seat.setListener(*State, seatListener, st);
            } else if (std.mem.eql(u8, iface, "ext_session_lock_manager_v1")) {
                st.manager = registry.bind(g.name, ext.SessionLockManagerV1, 1) catch return;
            } else if (std.mem.eql(u8, iface, "wl_output")) {
                if (g.version < 2) return; // scale needs v2; every compositor in use has v4
                const o = registry.bind(g.name, wl.Output, @min(g.version, 4)) catch return;
                const out = st.gpa.create(Output) catch {
                    o.release();
                    return;
                };
                out.* = .{ .st = st, .name = g.name, .wl_output = o };
                o.setListener(*Output, outputListener, out);
                st.outputs.append(st.gpa, out) catch {
                    o.release();
                    st.gpa.destroy(out);
                    return;
                };
                // A monitor plugged in while locked gets its surface at once.
                st.createSurface(out);
            }
        },
        .global_remove => |g| st.removeOutput(g.name),
    }
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, st: *State) void {
    switch (event) {
        .capabilities => |e| {
            if (e.capabilities.keyboard and st.keyboard == null) {
                const kb = seat.getKeyboard() catch return;
                st.keyboard = kb;
                kb.setListener(*State, keyboardListener, st);
            } else if (!e.capabilities.keyboard) {
                if (st.keyboard) |kb| kb.release();
                st.keyboard = null;
            }
        },
        .name => {},
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, st: *State) void {
    switch (event) {
        .keymap => |e| {
            defer _ = libc.close(e.fd);
            if (e.format != .xkb_v1 or e.size == 0) return;
            const map = posix.mmap(null, e.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, e.fd, 0) catch return;
            defer posix.munmap(map);
            const ctx = st.xkb_ctx orelse (c.xkb.xkb_context_new(0) orelse return);
            st.xkb_ctx = ctx;
            // The map is NUL-terminated by the compositor (the size includes it).
            const text: [*:0]const u8 = @ptrCast(map.ptr);
            const km = c.xkb.xkb_keymap_new_from_string(ctx, text, c.xkb.KEYMAP_FORMAT_TEXT_V1, 0) orelse return;
            const state = c.xkb.xkb_state_new(km) orelse {
                c.xkb.xkb_keymap_unref(km);
                return;
            };
            if (st.xkb_state) |old| c.xkb.xkb_state_unref(old);
            if (st.keymap) |old| c.xkb.xkb_keymap_unref(old);
            st.keymap = km;
            st.xkb_state = state;
            const idx = c.xkb.xkb_keymap_mod_get_index(km, "Lock");
            st.lock_index = if (idx == c.xkb.MOD_INVALID) null else idx;
        },
        .modifiers => |e| {
            if (st.xkb_state) |s| _ = c.xkb.xkb_state_update_mask(s, e.mods_depressed, e.mods_latched, e.mods_locked, 0, 0, e.group);
            const caps = logic.capsLocked(e.mods_locked, st.lock_index);
            if (caps != st.session.caps_lock) {
                st.session.caps_lock = caps;
                st.paintAll();
            }
        },
        .key => |e| {
            if (e.state != .pressed) return;
            const s = st.xkb_state orelse return;
            const code = e.key + 8;
            const sym = c.xkb.xkb_state_key_get_one_sym(s, code);
            var utf8: [16]u8 = undefined;
            defer std.crypto.secureZero(u8, &utf8);
            const key: logic.Key = switch (sym) {
                c.xkb.KEY_Return, c.xkb.KEY_KP_Enter => .enter,
                c.xkb.KEY_BackSpace => .backspace,
                c.xkb.KEY_Escape => .escape,
                else => blk: {
                    const n = c.xkb.xkb_state_key_get_utf8(s, code, &utf8, utf8.len);
                    if (n <= 0 or n >= utf8.len) break :blk .other;
                    break :blk .{ .text = utf8[0..@intCast(n)] };
                },
            };
            const held = c.xkb.xkb_state_mod_name_is_active(s, "Control", c.xkb.STATE_MODS_EFFECTIVE) == 1 or
                c.xkb.xkb_state_mod_name_is_active(s, "Mod1", c.xkb.STATE_MODS_EFFECTIVE) == 1 or
                c.xkb.xkb_state_mod_name_is_active(s, "Mod4", c.xkb.STATE_MODS_EFFECTIVE) == 1;
            switch (st.session.onKey(&st.password, key, held)) {
                .none => {},
                .repaint => st.paintAll(),
                .submit => st.submit(),
            }
        },
        .enter, .leave, .repeat_info => {},
    }
}

fn lockListener(_: *ext.SessionLockV1, event: ext.SessionLockV1.Event, st: *State) void {
    switch (event) {
        .locked => {
            st.locked_event = true;
            st.session.lockShown();
            st.readiness.locked = true;
            logging.step("lock: locked ({d} output(s))", .{st.readiness.surfaces});
            st.paintAll();
        },
        .finished => {
            st.finished_event = true;
        },
    }
}

// --- startup -------------------------------------------------------------------------

fn loadSettings(st: *State) void {
    if (std.c.getpwuid(std.c.getuid())) |pw| {
        if (pw.name) |n| {
            const s = std.mem.span(n);
            const k = @min(s.len, st.user_buf.len);
            @memcpy(st.user_buf[0..k], s[0..k]);
            st.user = st.user_buf[0..k];
        }
    }
    if (st.user.len == 0) if (libc.getenv("USER")) |u| {
        const s = std.mem.span(u);
        const k = @min(s.len, st.user_buf.len);
        @memcpy(st.user_buf[0..k], s[0..k]);
        st.user = st.user_buf[0..k];
    };
    st.service = logic.pamService(libc.access("/etc/pam.d/perihelion-lock", 4) == 0);

    const home = std.mem.span(libc.getenv("HOME") orelse return);
    var path_buf: [600]u8 = undefined;
    var file_buf: [64 * 1024]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&path_buf, "{s}/.config/perihelionbar/shell.json", .{home}, 0)) |p| {
        if (readSmall(p, &file_buf)) |text| st.h24 = logic.clock24h(st.gpa, text);
    } else |_| {}
    if (std.fmt.bufPrintSentinel(&path_buf, "{s}/.config/perihelionbar/matugen.json", .{home}, 0)) |p| {
        if (readSmall(p, &file_buf)) |text| st.palette = logic.palette(st.gpa, text);
    } else |_| {}
}

/// The wallpaper the desktop shows (same files as perihelion-shell's glass).
fn wallpaperPath(out: []u8) ?[:0]const u8 {
    const home = std.mem.span(libc.getenv("HOME") orelse return null);
    var path_buf: [600]u8 = undefined;
    var file_buf: [4096]u8 = undefined;
    var found: ?[]const u8 = null;
    if (std.fmt.bufPrintSentinel(&path_buf, "{s}/.config/perihelion/wallpaper", .{home}, 0)) |p| {
        if (readSmall(p, &file_buf)) |text| {
            if (logic.wallpaperIsColor(text)) return null;
            found = logic.wallpaperFromPerihelion(text);
        }
    } else |_| {}
    if (found == null) {
        if (std.fmt.bufPrintSentinel(&path_buf, "{s}/.config/perihelionbar/wallpaper", .{home}, 0)) |p| {
            if (readSmall(p, &file_buf)) |text| found = logic.wallpaperFromBar(text);
        } else |_| {}
    }
    const v = found orelse return null;
    return std.fmt.bufPrintSentinel(out, "{s}", .{v}, 0) catch null;
}

fn loadAvatar(st: *State) void {
    var buf: [600]u8 = undefined;
    if (libc.getenv("HOME")) |h| {
        if (std.fmt.bufPrintSentinel(&buf, "{s}/.face", .{std.mem.span(h)}, 0)) |p| {
            if (paint.loadAvatar(p, 512)) |s| {
                st.avatar = s;
                return;
            }
        } else |_| {}
    }
    if (st.user.len > 0) {
        if (std.fmt.bufPrintSentinel(&buf, "/var/lib/AccountsService/icons/{s}", .{st.user}, 0)) |p| {
            st.avatar = paint.loadAvatar(p, 512);
        } else |_| {}
    }
}

/// -f: fork; the parent waits for one byte from the child and exits with
/// it ('L' locked, 'A' another lock is active: both 0; EOF: the child
/// failed before locking: 1). The child returns the pipe's write end.
fn daemonize() c_int {
    var fds: [2]c_int = .{ -1, -1 };
    if (libc.pipe2(&fds, libc.O_CLOEXEC) != 0) {
        printErr("perihelion-lockscreen: pipe failed\n");
        std.process.exit(1);
    }
    const pid = libc.fork();
    if (pid < 0) {
        printErr("perihelion-lockscreen: fork failed\n");
        std.process.exit(1);
    }
    if (pid > 0) {
        _ = libc.close(fds[1]);
        var one = [1]u8{0};
        while (true) {
            const n = libc.read(fds[0], &one, 1);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n == 1 and (one[0] == 'L' or one[0] == 'A')) std.process.exit(0);
            std.process.exit(1);
        }
    }
    _ = libc.close(fds[0]);
    _ = libc.setsid();
    const devnull = libc.open("/dev/null", libc.O_RDWR | libc.O_CLOEXEC);
    if (devnull >= 0) {
        _ = libc.dup2(devnull, 0);
        _ = libc.dup2(devnull, 1);
        _ = libc.dup2(devnull, 2);
        if (devnull > 2) _ = libc.close(devnull);
    }
    return fds[1];
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var daemon = false;
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--daemonize")) {
            daemon = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printErr(USAGE);
            return 0;
        } else {
            printErr(USAGE);
            return 2;
        }
    }

    const ready_fd: c_int = if (daemon) daemonize() else -1;
    installSignals();
    logging.init("perihelion-lockscreen");
    defer logging.deinit();

    const gpa = std.heap.c_allocator;
    const display = wl.Display.connect(null) catch {
        logging.err("lock: no Wayland display", .{});
        return 1;
    };
    defer display.disconnect();

    const st = gpa.create(State) catch return 1;
    st.* = .{ .gpa = gpa, .display = display, .ready_fd = ready_fd };
    // Keep the password and the worker's copy out of swap.
    if (c.mlock(st, @sizeOf(State)) != 0) logging.warn("lock: mlock failed; the password buffer may be swappable", .{});
    defer {
        st.wipe();
        _ = c.munlock(st, @sizeOf(State));
    }

    loadSettings(st);

    const registry = display.getRegistry() catch return 1;
    registry.setListener(*State, registryListener, st);
    if (display.roundtrip() != .SUCCESS) return 1;
    if (display.roundtrip() != .SUCCESS) return 1; // seat capabilities, output modes and scales

    const manager = st.manager orelse {
        logging.err("lock: the compositor has no ext-session-lock-v1; not locking", .{});
        return 1;
    };
    if (st.compositor == null or st.shm == null) {
        logging.err("lock: wl_compositor or wl_shm missing", .{});
        return 1;
    }

    var path_buf: [600]u8 = undefined;
    if (wallpaperPath(&path_buf)) |p| {
        const cover = st.coverSize();
        st.wallpaper = image.decodeWallpaper(gpa, p, cover[0], cover[1]);
        if (st.wallpaper == null) logging.warn("lock: wallpaper unreadable; using the theme background", .{});
    }
    loadAvatar(st);

    st.readiness.started_ms = nowMs();
    const lock = manager.lock() catch return 1;
    st.lock = lock;
    lock.setListener(*State, lockListener, st);
    for (st.outputs.items) |out| st.createSurface(out);
    if (display.roundtrip() != .SUCCESS) return 1;

    if (st.finished_event and !st.locked_event) {
        // Refused: another locker holds the session. It stays in charge.
        logging.step("lock: another lock is active; leaving it alone", .{});
        lock.destroy();
        st.lock = null;
        st.reportReady('A');
        _ = display.roundtrip();
        return 0;
    }

    const code = run(st);
    if (!st.unlocked) {
        // Leaving while locked (signal, lost display): no unlock request is
        // ever sent, so the compositor keeps the session locked.
        logging.step("lock: exiting with the session still locked", .{});
    }
    return code;
}

fn run(st: *State) u8 {
    const display = st.display;
    var last_tick = nowMs();
    while (!st.unlocked) {
        if (g_stop.load(.acquire)) return 1;
        if (st.finished_event) {
            // The compositor ended the lock on its own (it is shutting down or
            // replaced the lock); nothing is left to guard.
            logging.step("lock: compositor finished the lock", .{});
            if (st.lock) |l| {
                if (st.locked_event) l.unlockAndDestroy() else l.destroy();
                st.lock = null;
            }
            _ = display.flush();
            return 0;
        }

        const now = nowMs();
        if (!st.readiness.reported and st.ready_fd >= 0 and st.readiness.ready(now)) {
            if (st.readiness.presented < st.readiness.surfaces) logging.warn("lock: -f released after the 2 s cap", .{});
            st.reportReady('L');
        }
        if (now - last_tick >= 1000) {
            last_tick = now;
            st.tick();
        }

        if (display.dispatchPending() != .SUCCESS) return 1;
        _ = display.flush();

        var timeout: i32 = @intCast(@max(0, 1000 - (nowMs() - last_tick)));
        if (st.ready_fd >= 0) {
            const w = st.readiness.waitMs(nowMs());
            if (w >= 0) timeout = @min(timeout, w);
        }
        var fds = [2]posix.pollfd{
            .{ .fd = display.getFd(), .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = st.worker.fd(), .events = posix.POLL.IN, .revents = 0 },
        };
        const nfds: usize = if (st.worker.running()) 2 else 1;
        const ready = libc.poll(&fds, nfds, timeout);
        if (ready <= 0) continue; // timeout, or a signal (checked at the top)
        if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) {
            logging.err("lock: lost the Wayland connection", .{});
            return 1;
        }
        if (fds[0].revents & posix.POLL.IN != 0) {
            if (display.dispatch() != .SUCCESS) {
                logging.err("lock: Wayland dispatch failed", .{});
                return 1;
            }
        }
        if (nfds == 2 and fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) st.authDone();
    }
    st.reportReady('L');
    return 0;
}
