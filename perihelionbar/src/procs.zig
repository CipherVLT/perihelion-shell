//! Top-processes service for the desktop Processes card (perihelionbar-shell
//! widgets.zig ProcessesWidget). Same shape as weather.zig / temps.zig:
//! no drawing, no fds kept open, the host calls tick().
//!
//! One sample = one pass over /proc: a single read of /proc/<pid>/stat per
//! process (name, parent, CPU ticks, resident pages), plus /proc/stat for
//! the machine's tick total. CPU % is the change in a process's ticks over
//! the change in all CPUs' ticks, times the CPU count — the top/htop
//! convention, so a busy single-threaded program reads 100% and a busy
//! multi-threaded one can read more. Memory is resident set size.
//! Kernel threads (children of kthreadd) are left out.
//!
//! Cost: about one small file read per process every interval (default
//! 3 s), a few milliseconds of CPU on a typical desktop, on the shell's
//! main loop. The previous sample's per-process ticks live in a buffer from
//! the page allocator (it grows if a machine runs more processes), so the
//! card itself stays small. Only the shown rows' full command names are
//! read (/proc/<pid>/cmdline), not every process's. tick() reports whether
//! the shown rows changed, so the card repaints only then.
//!
//! Read-only: nothing here signals or changes a process.
//!
//! Tests: `zig build test-procs` in perihelionbar/ (fake /proc under /tmp).

const std = @import("std");
const posix = std.posix;

pub const MAX_SHOWN: usize = 8;
pub const MIN_SHOWN: usize = 3;
pub const DEFAULT_INTERVAL_MS: i64 = 3000;
/// The first CPU reading needs two samples; take the second one quickly.
const WARMUP_MS: i64 = 1000;
const MAX_GROUPS: usize = 256;

const Dirent = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [256]u8,
};

const libc = struct {
    const DIR = opaque {};
    extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
    extern "c" fn readdir(dir: *DIR) ?*Dirent;
    extern "c" fn closedir(dir: *DIR) c_int;
    extern "c" fn getpagesize() c_int;
};

pub fn Text(comptime N: usize) type {
    return struct {
        buf: [N]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn set(self: *Self, s: []const u8) void {
            var n: usize = @min(s.len, N);
            while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

fn readFile(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const raw_fd = posix.system.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw_fd < 0) return null;
    const fd: posix.fd_t = @intCast(raw_fd);
    defer _ = posix.system.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = posix.read(fd, buf[len..]) catch return null;
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

pub const Sort = enum {
    cpu,
    memory,

    pub fn parse(s: []const u8) ?Sort {
        if (std.ascii.eqlIgnoreCase(s, "cpu")) return .cpu;
        if (std.ascii.eqlIgnoreCase(s, "memory") or std.ascii.eqlIgnoreCase(s, "mem") or std.ascii.eqlIgnoreCase(s, "ram")) return .memory;
        return null;
    }

    pub fn tag(self: Sort) []const u8 {
        return if (self == .cpu) "cpu" else "memory";
    }

    pub fn toggled(self: Sort) Sort {
        return if (self == .cpu) .memory else .cpu;
    }
};

pub const Proc = struct {
    pid: u32 = 0,
    name: Text(48) = .{},
    /// Tenths of a percent of one CPU (125 = 12.5%).
    cpu_x10: u32 = 0,
    /// Resident memory, bytes.
    rss: u64 = 0,
    /// Processes merged into this row (group mode), else 1.
    count: u32 = 1,
};

pub const Config = struct {
    sort: Sort = .cpu,
    count: usize = 6,
    interval_ms: i64 = DEFAULT_INTERVAL_MS,
    /// Merge processes with the same name (all of a browser's helpers).
    group: bool = false,
    /// Filesystem root for /proc ("" in real use; tests use a fake tree).
    root: []const u8 = "",
};

/// The fields of /proc/<pid>/stat this needs.
pub const Stat = struct {
    comm: []const u8,
    ppid: u32,
    ticks: u64,
    rss_pages: u64,
};

/// Parses a /proc/<pid>/stat line. The name sits in parentheses and may
/// itself contain spaces and parentheses ("(Web Content)", "((sd-pam))"),
/// so the fields are counted from the *last* ')'.
pub fn parseStat(line: []const u8) ?Stat {
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    if (close <= open) return null;
    var it = std.mem.tokenizeScalar(u8, line[close + 1 ..], ' ');
    // Field 3 (state) is index 0 here: field N is index N - 3.
    var idx: usize = 0;
    var ppid: u32 = 0;
    var utime: u64 = 0;
    var stime: u64 = 0;
    var rss: u64 = 0;
    while (it.next()) |tok| : (idx += 1) {
        switch (idx) {
            1 => ppid = std.fmt.parseInt(u32, tok, 10) catch return null,
            11 => utime = std.fmt.parseInt(u64, tok, 10) catch return null,
            12 => stime = std.fmt.parseInt(u64, tok, 10) catch return null,
            21 => {
                // rss can read -1-ish garbage on exotic kernels; treat as 0.
                rss = std.fmt.parseInt(u64, tok, 10) catch 0;
                break;
            },
            else => {},
        }
    }
    if (idx < 21) return null;
    return .{ .comm = line[open + 1 .. close], .ppid = ppid, .ticks = utime + stime, .rss_pages = rss };
}

/// /proc/stat's first line → (total ticks, CPU count).
pub fn parseProcStat(text: []const u8) ?struct { total: u64, ncpu: u32 } {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return null;
    if (!std.mem.startsWith(u8, first, "cpu ")) return null;
    var it = std.mem.tokenizeScalar(u8, first[4..], ' ');
    var total: u64 = 0;
    var n: usize = 0;
    // user nice system idle iowait irq softirq steal (guest time is
    // already counted in user, so stop at 8).
    while (it.next()) |tok| : (n += 1) {
        if (n == 8) break;
        total += std.fmt.parseInt(u64, tok, 10) catch 0;
    }
    var ncpu: u32 = 0;
    while (lines.next()) |l| {
        if (l.len > 3 and std.mem.startsWith(u8, l, "cpu") and std.ascii.isDigit(l[3])) ncpu += 1;
    }
    return .{ .total = total, .ncpu = @max(ncpu, 1) };
}

/// "12.5%" / "100%" (one decimal under 100).
pub fn fmtCpu(out: []u8, cpu_x10: u32) []const u8 {
    if (cpu_x10 >= 1000) return std.fmt.bufPrint(out, "{d}%", .{(cpu_x10 + 5) / 10}) catch "";
    return std.fmt.bufPrint(out, "{d}.{d}%", .{ cpu_x10 / 10, cpu_x10 % 10 }) catch "";
}

/// "1.2 GiB" / "512 MiB".
pub fn fmtMem(out: []u8, bytes: u64) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    if (bytes >= 1 << 30) return std.fmt.bufPrint(out, "{d:.1} GiB", .{b / (1 << 30)}) catch "";
    return std.fmt.bufPrint(out, "{d} MiB", .{bytes >> 20}) catch "";
}

const Sample = struct { pid: u32, ticks: u64 };

fn lessByPid(_: void, a: Sample, b: Sample) bool {
    return a.pid < b.pid;
}

fn findTicks(samples: []const Sample, pid: u32) ?u64 {
    var lo: usize = 0;
    var hi: usize = samples.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (samples[mid].pid == pid) return samples[mid].ticks;
        if (samples[mid].pid < pid) lo = mid + 1 else hi = mid;
    }
    return null;
}

pub const Service = struct {
    sort: Sort = .cpu,
    count: usize = 6,
    interval_ms: i64 = DEFAULT_INTERVAL_MS,
    group: bool = false,
    root: Text(96) = .{},

    top: [MAX_SHOWN]Proc = [_]Proc{.{}} ** MAX_SHOWN,
    top_len: usize = 0,
    mem_total: u64 = 0,
    page_size: u64 = 4096,

    prev: []Sample = &.{},
    prev_len: usize = 0,
    cur: []Sample = &.{},
    prev_total: u64 = 0,
    ncpu: u32 = 1,
    /// A previous sample exists to measure the next one against.
    warm: bool = false,
    /// The shown CPU figures came from a real interval (two samples).
    cpu_valid: bool = false,
    next_ms: i64 = 0,
    shown_hash: u64 = 0,

    pub fn init(cfg: Config) Service {
        var s = Service{
            .sort = cfg.sort,
            .count = std.math.clamp(cfg.count, MIN_SHOWN, MAX_SHOWN),
            .interval_ms = std.math.clamp(cfg.interval_ms, 1000, 60_000),
            .group = cfg.group,
        };
        s.root.set(cfg.root);
        const ps = libc.getpagesize();
        if (ps > 0) s.page_size = @intCast(ps);
        return s;
    }

    pub fn shown(self: *const Service) []const Proc {
        return self.top[0..self.top_len];
    }

    /// CPU rows mean nothing until two samples exist.
    pub fn ready(self: *const Service) bool {
        return self.sort == .memory or self.cpu_valid;
    }

    /// True when the shown rows changed.
    pub fn tick(self: *Service, now_ms: i64) bool {
        if (now_ms < self.next_ms) return false;
        self.sample();
        self.next_ms = now_ms + (if (self.cpu_valid) self.interval_ms else WARMUP_MS);
        return self.rehash();
    }

    /// Click on the card: CPU ↔ memory. The next tick re-ranks.
    pub fn toggleSort(self: *Service) void {
        self.sort = self.sort.toggled();
        self.next_ms = 0;
    }

    fn rehash(self: *Service) bool {
        var h = std.hash.Wyhash.init(@intFromEnum(self.sort));
        h.update(std.mem.asBytes(&self.cpu_valid));
        var vb: [24]u8 = undefined;
        for (self.shown()) |*p| {
            h.update(p.name.slice());
            h.update(std.mem.asBytes(&p.count));
            h.update(if (self.sort == .cpu) fmtCpu(&vb, p.cpu_x10) else fmtMem(&vb, p.rss));
        }
        const v = h.final();
        if (v == self.shown_hash) return false;
        self.shown_hash = v;
        return true;
    }

    /// Grows both sample buffers, keeping the previous sample and the
    /// first `keep_cur` entries of the one being collected.
    fn ensureCapacity(self: *Service, want: usize, keep_cur: usize) bool {
        if (self.cur.len >= want) return true;
        const cap = @max(want, 4096);
        const alloc = std.heap.page_allocator;
        const next_cur = alloc.alloc(Sample, cap) catch return false;
        const next_prev = alloc.alloc(Sample, cap) catch {
            alloc.free(next_cur);
            return false;
        };
        @memcpy(next_cur[0..keep_cur], self.cur[0..keep_cur]);
        @memcpy(next_prev[0..self.prev_len], self.prev[0..self.prev_len]);
        if (self.cur.len > 0) alloc.free(self.cur);
        if (self.prev.len > 0) alloc.free(self.prev);
        self.cur = next_cur;
        self.prev = next_prev;
        return true;
    }

    fn better(self: *const Service, a: *const Proc, b: *const Proc) bool {
        return if (self.sort == .cpu)
            (a.cpu_x10 > b.cpu_x10 or (a.cpu_x10 == b.cpu_x10 and a.rss > b.rss))
        else
            (a.rss > b.rss or (a.rss == b.rss and a.cpu_x10 > b.cpu_x10));
    }

    /// Keeps the best `count` candidates, ordered best first.
    fn offer(self: *Service, p: *const Proc) void {
        var pos: usize = self.top_len;
        while (pos > 0 and self.better(p, &self.top[pos - 1])) pos -= 1;
        if (pos >= self.count) return;
        const last = @min(self.top_len, self.count - 1);
        var i = last;
        while (i > pos) : (i -= 1) self.top[i] = self.top[i - 1];
        self.top[pos] = p.*;
        if (self.top_len < self.count) self.top_len += 1;
    }

    fn sample(self: *Service) void {
        const root = self.root.slice();
        var pb: [160]u8 = undefined;
        var buf: [4096]u8 = undefined;

        if (self.mem_total == 0) {
            if (std.fmt.bufPrintZ(&pb, "{s}/proc/meminfo", .{root})) |p| {
                if (readFile(p, &buf)) |t| {
                    if (std.mem.indexOf(u8, t, "MemTotal:")) |i| {
                        var it = std.mem.tokenizeScalar(u8, t[i + "MemTotal:".len ..], ' ');
                        if (it.next()) |kb| self.mem_total = (std.fmt.parseInt(u64, std.mem.trim(u8, kb, "\n"), 10) catch 0) * 1024;
                    }
                }
            } else |_| {}
        }
        var total: u64 = 0;
        if (std.fmt.bufPrintZ(&pb, "{s}/proc/stat", .{root})) |p| {
            if (readFile(p, &buf)) |t| {
                if (parseProcStat(t)) |ps| {
                    total = ps.total;
                    self.ncpu = ps.ncpu;
                }
            }
        } else |_| {}
        const dtotal = if (self.warm and total > self.prev_total) total - self.prev_total else 0;

        if (!self.ensureCapacity(4096, 0)) return;
        self.top_len = 0;
        var groups: [MAX_GROUPS]Proc = undefined;
        var group_len: usize = 0;
        var n: usize = 0;

        const dp = std.fmt.bufPrintZ(&pb, "{s}/proc", .{root}) catch return;
        const dir = libc.opendir(dp.ptr) orelse return;
        defer _ = libc.closedir(dir);
        while (libc.readdir(dir)) |e| {
            const name = std.mem.sliceTo(&e.d_name, 0);
            if (name.len == 0 or !std.ascii.isDigit(name[0])) continue;
            const pid = std.fmt.parseInt(u32, name, 10) catch continue;
            var sp: [160]u8 = undefined;
            const stat_path = std.fmt.bufPrintZ(&sp, "{s}/proc/{s}/stat", .{ root, name }) catch continue;
            var lb: [1024]u8 = undefined;
            const line = readFile(stat_path, &lb) orelse continue; // exited meanwhile
            const st = parseStat(line) orelse continue;
            if (pid == 2 or st.ppid == 2) continue; // kernel threads

            if (n == self.cur.len) {
                if (!self.ensureCapacity(self.cur.len * 2, n)) break;
            }
            self.cur[n] = .{ .pid = pid, .ticks = st.ticks };
            n += 1;

            var p = Proc{ .pid = pid, .rss = st.rss_pages * self.page_size };
            if (dtotal > 0) {
                if (findTicks(self.prev[0..self.prev_len], pid)) |before| {
                    const d = st.ticks -| before;
                    p.cpu_x10 = @intCast(@min(d * 1000 * self.ncpu / dtotal, 100_000));
                }
            }
            p.name.set(st.comm);
            if (self.group) {
                var found = false;
                for (groups[0..group_len]) |*g| {
                    if (!std.mem.eql(u8, g.name.slice(), p.name.slice())) continue;
                    g.cpu_x10 += p.cpu_x10;
                    g.rss += p.rss;
                    g.count += 1;
                    found = true;
                    break;
                }
                if (!found and group_len < MAX_GROUPS) {
                    groups[group_len] = p;
                    group_len += 1;
                }
            } else {
                self.offer(&p);
            }
        }
        if (self.group) {
            for (groups[0..group_len]) |*g| self.offer(g);
        } else {
            // A friendlier name than the 15-character kernel one, from the
            // command line — only for the few rows actually shown.
            for (self.top[0..self.top_len]) |*p| self.applyCmdlineName(p);
        }

        // This sample becomes the reference for the next one.
        std.mem.sort(Sample, self.cur[0..n], {}, lessByPid);
        const tmp = self.prev;
        self.prev = self.cur;
        self.cur = tmp;
        self.prev_len = n;
        self.prev_total = total;
        self.warm = total > 0;
        self.cpu_valid = dtotal > 0;
    }

    fn applyCmdlineName(self: *const Service, p: *Proc) void {
        var pb: [160]u8 = undefined;
        const path = std.fmt.bufPrintZ(&pb, "{s}/proc/{d}/cmdline", .{ self.root.slice(), p.pid }) catch return;
        var cb: [512]u8 = undefined;
        const raw = readFile(path, &cb) orelse return;
        const argv0 = std.mem.sliceTo(raw, 0);
        if (argv0.len == 0) return;
        // Some programs rewrite argv[0] with spaces ("sshd: user@pts/0").
        const first = if (std.mem.indexOfScalar(u8, argv0, ' ')) |sp| argv0[0..sp] else argv0;
        const base = if (std.mem.lastIndexOfScalar(u8, first, '/')) |i| first[i + 1 ..] else first;
        if (base.len == 0 or base[0] == '-') return; // login shells: "-bash"
        p.name.set(base);
    }
};

// --- tests -----------------------------------------------------------------

fn statLine(buf: []u8, pid: u32, comm: []const u8, ppid: u32, utime: u64, stime: u64, rss: u64) []const u8 {
    // Fields 1..24 as the kernel prints them (fields after rss are ignored).
    return std.fmt.bufPrint(buf, "{d} ({s}) S {d} 1 1 0 -1 4194304 100 0 0 0 {d} {d} 0 0 20 0 1 0 100 1000000 {d} 18446744073709551615", .{ pid, comm, ppid, utime, stime, rss }) catch unreachable;
}

test "stat parsing handles names with spaces and parentheses" {
    var b: [256]u8 = undefined;
    const s = parseStat(statLine(&b, 4242, "Web Content", 1000, 150, 50, 2560)).?;
    try std.testing.expectEqualStrings("Web Content", s.comm);
    try std.testing.expectEqual(@as(u32, 1000), s.ppid);
    try std.testing.expectEqual(@as(u64, 200), s.ticks);
    try std.testing.expectEqual(@as(u64, 2560), s.rss_pages);
    const odd = parseStat(statLine(&b, 7, "(sd-pam)", 1, 0, 0, 0)).?;
    try std.testing.expectEqualStrings("(sd-pam)", odd.comm);
    try std.testing.expect(parseStat("garbage") == null);
    try std.testing.expect(parseStat("12 (short) S 1 2 3") == null);
}

test "proc stat totals and formatting" {
    const ps = parseProcStat("cpu  100 0 50 800 10 5 5 0 30 0\ncpu0 50 0 25 400 5 2 3 0 0 0\ncpu1 50 0 25 400 5 3 2 0 0 0\nintr 1\n").?;
    try std.testing.expectEqual(@as(u64, 970), ps.total);
    try std.testing.expectEqual(@as(u32, 2), ps.ncpu);
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("12.5%", fmtCpu(&b, 125));
    try std.testing.expectEqualStrings("0.0%", fmtCpu(&b, 0));
    try std.testing.expectEqualStrings("143%", fmtCpu(&b, 1427));
    try std.testing.expectEqualStrings("1.5 GiB", fmtMem(&b, 3 << 29));
    try std.testing.expectEqualStrings("512 MiB", fmtMem(&b, 512 << 20));
    try std.testing.expectEqual(Sort.memory, Sort.parse("RAM").?);
}

fn mkdirP(path: []const u8) void {
    var buf: [300]u8 = undefined;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        _ = posix.system.mkdir(buf[0..i :0].ptr, 0o755);
    }
}

fn writeFile(root: []const u8, rel: []const u8, content: []const u8) void {
    var pb: [300]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ root, rel }) catch return;
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| mkdirP(p[0..slash]);
    var zb: [300]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{p}) catch return;
    const raw = posix.system.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(posix.mode_t, 0o644));
    if (raw < 0) return;
    const fd: posix.fd_t = @intCast(raw);
    _ = std.c.write(fd, content.ptr, content.len);
    _ = posix.system.close(fd);
}

fn writeProc(root: []const u8, pid: u32, comm: []const u8, ppid: u32, ticks: u64, rss: u64, cmdline: []const u8) void {
    var rel: [64]u8 = undefined;
    var b: [256]u8 = undefined;
    writeFile(root, std.fmt.bufPrint(&rel, "proc/{d}/stat", .{pid}) catch unreachable, statLine(&b, pid, comm, ppid, ticks, 0, rss));
    writeFile(root, std.fmt.bufPrint(&rel, "proc/{d}/cmdline", .{pid}) catch unreachable, cmdline);
}

test "sampling a fake /proc: CPU deltas, memory order, kernel threads, grouping" {
    var rb: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&rb, "/tmp/perihelion-procs-test-{d}", .{std.c.getpid()}) catch unreachable;
    writeFile(root, "proc/meminfo", "MemTotal:       16384000 kB\n");
    writeFile(root, "proc/stat", "cpu  1000 0 0 9000 0 0 0 0 0 0\ncpu0 500 0 0 4500 0 0 0 0 0 0\ncpu1 500 0 0 4500 0 0 0 0 0 0\n");
    writeProc(root, 2, "kthreadd", 0, 0, 0, "");
    writeProc(root, 50, "kworker/0:1", 2, 500, 0, "");
    writeProc(root, 100, "firefox", 1, 1000, 100_000, "/usr/lib/firefox/firefox\x00--new-window\x00");
    writeProc(root, 101, "Isolated Web Co", 100, 400, 50_000, "/usr/lib/firefox/firefox\x00-contentproc\x00");
    writeProc(root, 102, "Isolated Web Co", 100, 400, 40_000, "/usr/lib/firefox/firefox\x00-contentproc\x00");
    writeProc(root, 200, "zig", 1, 100, 20_000, "zig\x00build\x00");

    var s = Service.init(.{ .root = root, .count = 4 });
    s.page_size = 4096;
    try std.testing.expect(s.tick(0));
    try std.testing.expect(!s.ready()); // CPU needs a second sample
    try std.testing.expectEqual(@as(i64, WARMUP_MS), s.next_ms);
    try std.testing.expect(!s.tick(500)); // not due

    // One second later: 1000 machine ticks passed on 2 CPUs; zig used 200,
    // firefox 50, the content processes nothing, the kworker 400.
    writeFile(root, "proc/stat", "cpu  1500 0 0 9500 0 0 0 0 0 0\ncpu0 750 0 0 4750 0 0 0 0 0 0\ncpu1 750 0 0 4750 0 0 0 0 0 0\n");
    writeProc(root, 200, "zig", 1, 300, 20_000, "zig\x00build\x00");
    writeProc(root, 100, "firefox", 1, 1050, 100_000, "/usr/lib/firefox/firefox\x00--new-window\x00");
    writeProc(root, 50, "kworker/0:1", 2, 900, 0, "");
    try std.testing.expect(s.tick(WARMUP_MS));
    try std.testing.expect(s.ready());
    const top = s.shown();
    try std.testing.expectEqual(@as(usize, 4), top.len);
    try std.testing.expectEqualStrings("zig", top[0].name.slice());
    try std.testing.expectEqual(@as(u32, 400), top[0].cpu_x10); // 200/1000 × 2 CPUs = 40.0%
    try std.testing.expectEqualStrings("firefox", top[1].name.slice()); // from cmdline
    try std.testing.expectEqual(@as(u32, 100), top[1].cpu_x10);
    for (top) |*p| try std.testing.expect(p.pid != 50 and p.pid != 2); // no kernel threads

    // Memory order, then grouped by name.
    s.toggleSort();
    _ = s.tick(WARMUP_MS + 10);
    try std.testing.expectEqual(@as(u32, 100), s.shown()[0].pid);
    try std.testing.expectEqual(@as(u64, 100_000 * 4096), s.shown()[0].rss);
    s.group = true;
    s.next_ms = 0;
    _ = s.tick(WARMUP_MS + 20);
    try std.testing.expectEqualStrings("firefox", s.shown()[0].name.slice());
    try std.testing.expectEqualStrings("Isolated Web Co", s.shown()[1].name.slice());
    try std.testing.expectEqual(@as(u32, 2), s.shown()[1].count);
    try std.testing.expectEqual(@as(u64, 90_000 * 4096), s.shown()[1].rss);
}
