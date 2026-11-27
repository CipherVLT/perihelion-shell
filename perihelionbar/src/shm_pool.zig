//! Reused wl_shm buffers for one surface.
//!
//! A surface owns one Pool with a fixed number of slots (2 or 3). Drawing a
//! frame asks the pool for a free slot (`acquire`), paints into its pixels,
//! attaches its buffer and hands it back with `present`, which marks it busy
//! until the compositor sends wl_buffer.release. A busy slot is never painted.
//! Buffers are created once per size and reused; a new size, `reset` or
//! `deinit` destroys every buffer (wl_buffer.destroy + munmap), and the
//! counters in `stats` let tests check that creates and destroys balance.
//!
//! Each slot also keeps `stale`: the area painted into other slots since this
//! one was last current. A caller that repaints only what changed paints
//! `stale` plus its own new damage; a caller that repaints the whole frame
//! can ignore it.
//!
//! This file needs nothing but std: the Wayland side comes in through
//! `WlBackend(wl)`, given the generated `wl` namespace of the build that uses
//! it, and the tests use a fake backend.

const std = @import("std");
const posix = std.posix;

pub const MAX_SLOTS: usize = 3;

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn isEmpty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }

    pub fn unite(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x + a.w, b.x + b.w);
        const y1 = @max(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    fn overlapsOrTouches(a: Rect, b: Rect) bool {
        return a.x <= b.x + b.w and b.x <= a.x + a.w and a.y <= b.y + b.h and b.y <= a.y + a.h;
    }
};

/// A small damage region: up to MAX_RECTS rectangles, or the whole surface.
/// Touching or overlapping rects merge; one more than fits collapses the
/// region to its bounding box, so it never grows.
pub const Region = struct {
    pub const MAX_RECTS: usize = 4;

    full: bool = false,
    len: u8 = 0,
    rects: [MAX_RECTS]Rect = undefined,

    pub const empty: Region = .{};
    pub const whole: Region = .{ .full = true };

    pub fn isEmpty(self: *const Region) bool {
        return !self.full and self.len == 0;
    }

    pub fn items(self: *const Region) []const Rect {
        return self.rects[0..self.len];
    }

    pub fn add(self: *Region, r: Rect) void {
        if (self.full or r.isEmpty()) return;
        var cur = r;
        // Absorb every rect cur touches (repeat: a merge can reach more).
        var merged = true;
        while (merged) {
            merged = false;
            var i: usize = 0;
            while (i < self.len) {
                if (self.rects[i].overlapsOrTouches(cur)) {
                    cur = cur.unite(self.rects[i]);
                    self.rects[i] = self.rects[self.len - 1];
                    self.len -= 1;
                    merged = true;
                } else i += 1;
            }
        }
        if (self.len < MAX_RECTS) {
            self.rects[self.len] = cur;
            self.len += 1;
            return;
        }
        var box = cur;
        for (self.items()) |x| box = box.unite(x);
        self.rects[0] = box;
        self.len = 1;
    }

    pub fn addRegion(self: *Region, other: *const Region) void {
        if (other.full) {
            self.* = whole;
            return;
        }
        for (other.items()) |r| self.add(r);
    }

    pub fn bbox(self: *const Region, w: u32, h: u32) Rect {
        if (self.full) return .{ .x = 0, .y = 0, .w = @intCast(w), .h = @intCast(h) };
        var box = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        for (self.items()) |r| box = box.unite(r);
        return box;
    }
};

/// The smallest rectangle holding every pixel that differs between two
/// frames of the same size, or null when they are identical.
pub fn diffBox(prev: []const u32, cur: []const u32, w: u32, h: u32) ?Rect {
    const width: usize = w;
    std.debug.assert(prev.len >= width * h and cur.len >= width * h);
    var top: ?usize = null;
    var bottom: usize = 0;
    var left: usize = width;
    var right: usize = 0;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const a = prev[y * width ..][0..width];
        const b = cur[y * width ..][0..width];
        if (std.mem.eql(u32, a, b)) continue;
        if (top == null) top = y;
        bottom = y;
        var x0: usize = 0;
        while (a[x0] == b[x0]) x0 += 1;
        var x1: usize = width - 1;
        while (a[x1] == b[x1]) x1 -= 1;
        left = @min(left, x0);
        right = @max(right, x1);
    }
    const t = top orelse return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(t),
        .w = @intCast(right - left + 1),
        .h = @intCast(bottom - t + 1),
    };
}

/// One buffer. `buffer` and the mapping belong to the backend; `busy` is set
/// by `present` and cleared by the compositor's release.
pub const Slot = struct {
    buffer: ?*anyopaque = null,
    map: []align(std.heap.page_size_min) u8 = &.{},
    pixels: []u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    busy: bool = false,
    stale: Region = Region.whole,
    /// Called (with `owner`) when the compositor releases this buffer, so an
    /// owner that found every slot busy can draw the frame it skipped.
    owner: ?*anyopaque = null,
    on_release: ?*const fn (*anyopaque) void = null,

    pub fn released(self: *Slot) void {
        self.busy = false;
        if (self.on_release) |cb| if (self.owner) |o| cb(o);
    }
};

pub const Stats = struct {
    created: u32 = 0,
    destroyed: u32 = 0,

    pub fn live(s: Stats) u32 {
        return s.created - s.destroyed;
    }
};

/// Backend: a type with
///   fn create(self: *B, slot: *Slot, w: u32, h: u32) !void  (fills buffer/map/pixels)
///   fn destroy(self: *B, slot: *Slot) void                  (frees what create made)
pub fn Pool(comptime B: type) type {
    return struct {
        const Self = @This();

        backend: *B,
        n_slots: u8,
        slots: [MAX_SLOTS]Slot = @splat(.{}),
        width: u32 = 0,
        height: u32 = 0,
        stats: Stats = .{},

        pub fn init(backend: *B, n_slots: u8) Self {
            std.debug.assert(n_slots >= 1 and n_slots <= MAX_SLOTS);
            return .{ .backend = backend, .n_slots = n_slots };
        }

        /// Where the compositor's release should report (set once, before
        /// the first acquire; slots keep it across re-creation).
        pub fn setReleaseHook(self: *Self, owner: *anyopaque, cb: *const fn (*anyopaque) void) void {
            for (&self.slots) |*s| {
                s.owner = owner;
                s.on_release = cb;
            }
        }

        /// A free slot of this size, created if needed; null while every slot
        /// is busy (draw again when one is released). A size change destroys
        /// every buffer first.
        pub fn acquire(self: *Self, w: u32, h: u32) !?*Slot {
            if (w == 0 or h == 0) return null;
            if (w != self.width or h != self.height) {
                self.reset();
                self.width = w;
                self.height = h;
            }
            // A free slot that already has a buffer first, then an empty one.
            for (self.slots[0..self.n_slots]) |*s| {
                if (s.buffer != null and !s.busy) return s;
            }
            for (self.slots[0..self.n_slots]) |*s| {
                if (s.buffer == null) {
                    try self.backend.create(s, w, h);
                    s.width = w;
                    s.height = h;
                    s.busy = false;
                    s.stale = Region.whole;
                    self.stats.created += 1;
                    return s;
                }
            }
            return null;
        }

        /// `slot` was attached and committed with `damage`: it is busy until
        /// released, current (nothing stale), and every other slot now lags
        /// behind by `damage`.
        pub fn present(self: *Self, slot: *Slot, damage: *const Region) void {
            for (self.slots[0..self.n_slots]) |*s| {
                if (s == slot or s.buffer == null) continue;
                s.stale.addRegion(damage);
            }
            slot.busy = true;
            slot.stale = Region.empty;
        }

        /// Destroys every buffer (resize, output gone, surface hidden).
        pub fn reset(self: *Self) void {
            for (&self.slots) |*s| {
                if (s.buffer == null) continue;
                self.backend.destroy(s);
                s.buffer = null;
                s.map = &.{};
                s.pixels = &.{};
                s.busy = false;
                s.stale = Region.whole;
                self.stats.destroyed += 1;
            }
            self.width = 0;
            self.height = 0;
        }

        pub fn deinit(self: *Self) void {
            self.reset();
        }
    };
}

/// One frame on `pool`: take a free slot, let `ctx.paint(slot)` fill it and
/// say what changed (null: nothing, so nothing is committed and the slot
/// stays free), then `ctx.commit(slot, &damage)` and mark it presented.
/// Returns false when every slot is still held by the compositor; the caller
/// draws again from its release hook.
pub fn drawFrame(pool: anytype, w: u32, h: u32, ctx: anytype) !bool {
    const slot = (try pool.acquire(w, h)) orelse return false;
    const damage: Region = ctx.paint(slot) orelse return true;
    ctx.commit(slot, &damage);
    pool.present(slot, &damage);
    return true;
}

/// The real backend over a build's generated `wl` namespace: one memfd per
/// buffer, mapped once; the wl_shm_pool is destroyed right after the buffer
/// is made (the buffer keeps the memory) and the fd closed (the compositor
/// holds its own).
pub fn WlBackend(comptime wl: type) type {
    return struct {
        const Self = @This();

        shm: *wl.Shm,

        pub fn create(self: *Self, slot: *Slot, w: u32, h: u32) !void {
            const stride: usize = @as(usize, w) * 4;
            const size: usize = stride * h;
            const fd = try posix.memfd_create("perihelion-buffer", std.os.linux.MFD.CLOEXEC);
            defer _ = posix.system.close(fd);
            switch (posix.errno(posix.system.ftruncate(fd, @intCast(size)))) {
                .SUCCESS => {},
                else => return error.FTruncateFailed,
            }
            const map = try posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
            errdefer posix.munmap(map);
            const pool = try self.shm.createPool(fd, @intCast(size));
            defer pool.destroy();
            const buffer = try pool.createBuffer(0, @intCast(w), @intCast(h), @intCast(stride), .argb8888);
            buffer.setListener(*Slot, listener, slot);
            slot.buffer = buffer;
            slot.map = map;
            const words: [*]u32 = @ptrCast(@alignCast(map.ptr));
            slot.pixels = words[0 .. @as(usize, w) * h];
        }

        pub fn destroy(_: *Self, slot: *Slot) void {
            if (slot.buffer) |b| {
                const buffer: *wl.Buffer = @ptrCast(@alignCast(b));
                buffer.destroy();
            }
            if (slot.map.len > 0) posix.munmap(slot.map);
        }

        pub fn wlBuffer(slot: *const Slot) *wl.Buffer {
            return @ptrCast(@alignCast(slot.buffer.?));
        }

        fn listener(_: *wl.Buffer, event: wl.Buffer.Event, slot: *Slot) void {
            switch (event) {
                .release => slot.released(),
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Tests: a fake backend that counts and hands out heap pixels.

const Fake = struct {
    created: u32 = 0,
    destroyed: u32 = 0,
    fail_next: bool = false,
    store: [MAX_SLOTS * 4][]u32 = undefined,
    n: usize = 0,

    fn create(self: *Fake, slot: *Slot, w: u32, h: u32) !void {
        if (self.fail_next) {
            self.fail_next = false;
            return error.OutOfMemory;
        }
        const px = try std.testing.allocator.alloc(u32, @as(usize, w) * h);
        @memset(px, 0);
        slot.pixels = px;
        slot.buffer = @ptrCast(px.ptr);
        self.created += 1;
    }

    fn destroy(self: *Fake, slot: *Slot) void {
        std.testing.allocator.free(slot.pixels);
        self.destroyed += 1;
    }
};

const tt = std.testing;

test "buffers are created once and reused" {
    var fake = Fake{};
    var pool = Pool(Fake).init(&fake, 3);
    defer pool.deinit();
    var frame: u32 = 0;
    while (frame < 100) : (frame += 1) {
        const s = (try pool.acquire(64, 8)).?;
        pool.present(s, &Region.whole);
        s.released(); // compositor done with it before the next frame
    }
    try tt.expectEqual(@as(u32, 1), fake.created);
    try tt.expectEqual(@as(u32, 1), pool.stats.live());
}

test "a busy slot is never handed out; all busy gives null" {
    var fake = Fake{};
    var pool = Pool(Fake).init(&fake, 2);
    defer pool.deinit();
    const a = (try pool.acquire(10, 10)).?;
    pool.present(a, &Region.whole);
    const b = (try pool.acquire(10, 10)).?;
    try tt.expect(a != b);
    pool.present(b, &Region.whole);
    try tt.expectEqual(@as(?*Slot, null), try pool.acquire(10, 10));
    a.released();
    try tt.expectEqual(a, (try pool.acquire(10, 10)).?);
    try tt.expectEqual(@as(u32, 2), fake.created);
}

test "a new size destroys every buffer, busy ones included" {
    var fake = Fake{};
    var pool = Pool(Fake).init(&fake, 3);
    const a = (try pool.acquire(10, 10)).?;
    pool.present(a, &Region.whole);
    _ = (try pool.acquire(10, 10)).?;
    try tt.expectEqual(@as(u32, 2), pool.stats.live());
    const c = (try pool.acquire(20, 5)).?;
    try tt.expectEqual(@as(u32, 2), fake.destroyed);
    try tt.expectEqual(@as(usize, 100), c.pixels.len);
    pool.deinit();
    try tt.expectEqual(fake.created, fake.destroyed);
    try tt.expectEqual(@as(u32, 0), pool.stats.live());
}

test "a failed create leaves the slot empty and nothing counted" {
    var fake = Fake{ .fail_next = true };
    var pool = Pool(Fake).init(&fake, 2);
    defer pool.deinit();
    try tt.expectError(error.OutOfMemory, pool.acquire(4, 4));
    try tt.expectEqual(@as(u32, 0), pool.stats.created);
    _ = (try pool.acquire(4, 4)).?;
    try tt.expectEqual(@as(u32, 1), pool.stats.live());
}

test "stale tracks what other slots painted since" {
    var fake = Fake{};
    var pool = Pool(Fake).init(&fake, 2);
    defer pool.deinit();
    const a = (try pool.acquire(100, 100)).?;
    try tt.expect(a.stale.full); // a new buffer has nothing valid
    pool.present(a, &Region.whole);
    const b = (try pool.acquire(100, 100)).?;
    pool.present(b, &Region.whole);
    a.released();
    b.released();
    // a is current up to its own frame; b's full frame came after.
    try tt.expect(a.stale.full);
    const a2 = (try pool.acquire(100, 100)).?;
    var d = Region.empty;
    d.add(.{ .x = 5, .y = 5, .w = 10, .h = 10 });
    pool.present(a2, &d);
    a2.released();
    // b now lags by exactly the clock-sized rect a2 painted.
    try tt.expect(!b.stale.full);
    try tt.expectEqual(@as(usize, 1), b.stale.len);
    try tt.expectEqual(Rect{ .x = 5, .y = 5, .w = 10, .h = 10 }, b.stale.rects[0]);
    try tt.expect(a2.stale.isEmpty());
}

test "release hook reaches the owner" {
    const Owner = struct {
        n: u32 = 0,
        fn hook(p: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.n += 1;
        }
    };
    var fake = Fake{};
    var owner = Owner{};
    var pool = Pool(Fake).init(&fake, 2);
    defer pool.deinit();
    pool.setReleaseHook(&owner, Owner.hook);
    const s = (try pool.acquire(4, 4)).?;
    pool.present(s, &Region.whole);
    s.released();
    try tt.expectEqual(@as(u32, 1), owner.n);
    try tt.expect(!s.busy);
}

const FakeFrame = struct {
    commits: u32 = 0,
    held: [MAX_SLOTS]?*Slot = @splat(null),
    lag: usize = 0, // how many presented buffers the compositor still holds
    unchanged: bool = false,

    fn paint(self: *FakeFrame, slot: *Slot) ?Region {
        if (self.unchanged) return null;
        @memset(slot.pixels, 0xff000000 | self.commits);
        return Region.whole;
    }
    fn commit(self: *FakeFrame, slot: *Slot, _: *const Region) void {
        self.commits += 1;
        if (self.lag == 0) return;
        // Release the oldest once more than `lag` are held.
        var i: usize = self.lag;
        if (self.held[i - 1]) |old| old.released();
        while (i > 1) : (i -= 1) self.held[i - 1] = self.held[i - 2];
        self.held[0] = slot;
    }
};

test "drawFrame: 100 frames make at most 3 buffers, even with a slow compositor" {
    inline for (.{ 0, 1, 2 }) |lag| {
        var fake = Fake{};
        var pool = Pool(Fake).init(&fake, 3);
        var ctx = FakeFrame{ .lag = lag };
        var drawn: u32 = 0;
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            if (try drawFrame(&pool, 32, 4, &ctx)) drawn += 1;
            if (lag == 0) for (&pool.slots) |*s| if (s.busy) s.released();
        }
        try tt.expectEqual(@as(u32, 100), drawn);
        try tt.expect(fake.created <= 3);
        try tt.expectEqual(@as(u32, lag + 1), fake.created);
        pool.deinit();
        try tt.expectEqual(fake.created, fake.destroyed);
    }
}

test "drawFrame: an unchanged frame commits nothing and keeps the slot free" {
    var fake = Fake{};
    var pool = Pool(Fake).init(&fake, 2);
    defer pool.deinit();
    var ctx = FakeFrame{ .unchanged = true };
    try tt.expect(try drawFrame(&pool, 8, 8, &ctx));
    try tt.expectEqual(@as(u32, 0), ctx.commits);
    for (pool.slots) |s| try tt.expect(!s.busy);
}

test "drawFrame: every slot held gives false, nothing drawn" {
    var fake = Fake{};
    var pool = Pool(Fake).init(&fake, 2);
    defer pool.deinit();
    var ctx = FakeFrame{};
    try tt.expect(try drawFrame(&pool, 8, 8, &ctx));
    try tt.expect(try drawFrame(&pool, 8, 8, &ctx));
    try tt.expect(!try drawFrame(&pool, 8, 8, &ctx));
    try tt.expectEqual(@as(u32, 2), ctx.commits);
}

test "region merges touching rects and collapses past its capacity" {
    var r = Region.empty;
    r.add(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    r.add(.{ .x = 10, .y = 0, .w = 10, .h = 10 }); // touches: merged
    try tt.expectEqual(@as(usize, 1), r.len);
    try tt.expectEqual(Rect{ .x = 0, .y = 0, .w = 20, .h = 10 }, r.rects[0]);
    r.add(.{ .x = 100, .y = 0, .w = 1, .h = 1 });
    r.add(.{ .x = 200, .y = 0, .w = 1, .h = 1 });
    r.add(.{ .x = 300, .y = 0, .w = 1, .h = 1 });
    try tt.expectEqual(@as(usize, 4), r.len);
    r.add(.{ .x = 400, .y = 50, .w = 1, .h = 1 }); // fifth: bounding box
    try tt.expectEqual(@as(usize, 1), r.len);
    try tt.expectEqual(Rect{ .x = 0, .y = 0, .w = 401, .h = 51 }, r.rects[0]);
    r.add(.{ .x = 0, .y = 0, .w = 0, .h = 5 }); // empty: ignored
    try tt.expectEqual(@as(usize, 1), r.len);
    var w = Region.whole;
    w.add(.{ .x = 1, .y = 1, .w = 1, .h = 1 });
    try tt.expect(w.full);
}

test "diffBox finds the changed area, null when identical" {
    var a: [8 * 4]u32 = @splat(0);
    var b = a;
    try tt.expectEqual(@as(?Rect, null), diffBox(&a, &b, 8, 4));
    b[1 * 8 + 2] = 7;
    b[2 * 8 + 5] = 7;
    try tt.expectEqual(Rect{ .x = 2, .y = 1, .w = 4, .h = 2 }, diffBox(&a, &b, 8, 4).?);
    a = b;
    b[3 * 8 + 7] = 1;
    try tt.expectEqual(Rect{ .x = 7, .y = 3, .w = 1, .h = 1 }, diffBox(&a, &b, 8, 4).?);
}
