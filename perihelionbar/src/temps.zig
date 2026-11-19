//! CPU / GPU temperature service, shared by the desktop System card
//! (perihelionbar-shell widgets.zig SystemWidget) and the bar's
//! CPU-temperature module. Same shape as weather.zig: no drawing, no fds of
//! its own — the host calls tick() and, for NVIDIA, runs one nvidia-smi
//! child when wantSmi() says so.
//!
//! Sources, cheapest first (no lm_sensors needed: `sensors` reads the same
//! hwmon files this reads directly, without a process per sample):
//!   CPU  /sys/class/hwmon chips k10temp / zenpower / coretemp / k8temp /
//!        cpu_thermal (label Tdie > Tctl > "Package id 0" > first input),
//!        else /sys/class/thermal zones (x86_pkg_temp > cpu/soc > acpitz).
//!   GPU  /sys/class/drm/cardN/device/hwmon (amdgpu "edge", nouveau,
//!        i915/xe where exposed) + amdgpu gpu_busy_percent;
//!        proprietary NVIDIA has no hwmon, so `nvidia-smi` (nvidia-utils),
//!        at most every 5 s, with backoff when it fails or is missing.
//!
//! Discovery runs once and then every 5 minutes (or right after a sensor
//! read fails); each sample is then 1–3 small sysfs reads. Only the
//! selected GPU is sampled. A runtime-suspended discrete GPU is reported
//! asleep and never touched — querying it would wake it and drain a
//! laptop battery.
//!
//! Tests: `zig build test-temps` in perihelionbar/ (they build a fake
//! sysfs tree under /tmp, so no particular hardware is needed).

const std = @import("std");
const posix = std.posix;

pub const MAX_GPUS: usize = 4;
pub const DEFAULT_INTERVAL_MS: i64 = 2000;
pub const NVIDIA_MIN_INTERVAL_MS: i64 = 5000;
const NVIDIA_BACKOFF_CAP_MS: i64 = 300_000;
const RESCAN_MS: i64 = 300_000;

/// What the host runs (through sh, so PATH finds it) when wantSmi() is true.
/// stderr is dropped: a missing binary or driver mismatch is already
/// handled by smiComplete's backoff and would otherwise spam the log.
pub const SMI_CMD = "exec nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,pci.bus_id --format=csv,noheader,nounits 2>/dev/null";

// --- libc: directory listing (glibc dirent64 layout, as the bar binds it) ---

const libc = struct {
    const DIR = opaque {};
    extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
    extern "c" fn readdir(dir: *DIR) ?*Dirent;
    extern "c" fn closedir(dir: *DIR) c_int;
};

const Dirent = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [256]u8,
};

const Dir = struct {
    d: *libc.DIR,

    fn open(path: [:0]const u8) ?Dir {
        return .{ .d = libc.opendir(path.ptr) orelse return null };
    }

    /// Next entry name, skipping dot entries. Valid until the next call.
    fn next(self: Dir) ?[]const u8 {
        while (libc.readdir(self.d)) |e| {
            const name = std.mem.sliceTo(&e.d_name, 0);
            if (name.len == 0 or name[0] == '.') continue;
            return name;
        }
        return null;
    }

    fn close(self: Dir) void {
        _ = libc.closedir(self.d);
    }
};

// --- small helpers -------------------------------------------------------------

pub fn Text(comptime N: usize) type {
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

const Path = Text(200);

fn pathZ(buf: []u8, comptime fmt: []const u8, args: anytype) ?[:0]const u8 {
    return std.fmt.bufPrintZ(buf, fmt, args) catch null;
}

/// Reads a small sysfs file, trimmed. Null if missing/unreadable/empty.
fn readTrim(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const raw_fd = posix.system.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw_fd < 0) return null;
    const fd: posix.fd_t = @intCast(raw_fd);
    defer _ = posix.system.close(fd);
    const n = posix.read(fd, buf) catch return null;
    const t = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return if (t.len == 0) null else t;
}

fn readInt(path: [:0]const u8) ?i64 {
    var buf: [32]u8 = undefined;
    const t = readTrim(path, &buf) orelse return null;
    return std.fmt.parseInt(i64, t, 10) catch null;
}

fn readIntSlice(path: []const u8) ?i64 {
    var zb: [220]u8 = undefined;
    const z = pathZ(&zb, "{s}", .{path}) orelse return null;
    return readInt(z);
}

fn readTrimSlice(path: []const u8, buf: []u8) ?[]const u8 {
    var zb: [220]u8 = undefined;
    const z = pathZ(&zb, "{s}", .{path}) orelse return null;
    return readTrim(z, buf);
}

/// Sane millidegree reading (sysfs reports m°C; some zones report °C).
fn plausibleMc(v: i64) ?i32 {
    if (v > 1000 and v < 150_000) return @intCast(v);
    if (v > 0 and v < 150) return @intCast(v * 1000);
    return null;
}

fn roundC(mc: i32) i32 {
    return @divTrunc(mc + (if (mc >= 0) @as(i32, 500) else -500), 1000);
}

// --- units / display ---------------------------------------------------------------

pub const Units = enum {
    celsius,
    fahrenheit,

    pub fn parse(s: []const u8) ?Units {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(s, "c") or eq(s, "celsius") or eq(s, "metric")) return .celsius;
        if (eq(s, "f") or eq(s, "fahrenheit") or eq(s, "imperial")) return .fahrenheit;
        return null;
    }

    pub fn tag(self: Units) []const u8 {
        return if (self == .fahrenheit) "F" else "C";
    }
};

/// "62°C" / "144°F", or an em dash when there is no reading.
pub fn fmtTemp(mc: ?i32, units: Units, out: []u8) []const u8 {
    const v = mc orelse return "\u{2014}";
    const c: f32 = @as(f32, @floatFromInt(v)) / 1000.0;
    const shown = if (units == .fahrenheit) c * 9.0 / 5.0 + 32.0 else c;
    const r: i32 = @intFromFloat(@round(std.math.clamp(shown, -99.0, 999.0)));
    return std.fmt.bufPrint(out, "{d}\u{00B0}{s}", .{ r, units.tag() }) catch "";
}

/// Warm/hot tint (0xAARRGGBB), or 0 for "normal: use the theme text color"
/// so matugen keeps the card's look until something actually runs hot.
pub fn heatTint(mc: ?i32) u32 {
    const v = mc orelse return 0;
    if (v >= 85_000) return 0xFFFF6B6B;
    if (v >= 70_000) return 0xFFFFB340;
    return 0;
}

// --- data model -----------------------------------------------------------------------

pub const Vendor = enum {
    amd,
    intel,
    nvidia,
    other,

    pub fn label(self: Vendor) []const u8 {
        return switch (self) {
            .amd => "AMD",
            .intel => "Intel",
            .nvidia => "NVIDIA",
            .other => "GPU",
        };
    }

    fn fromPciId(id: u32) Vendor {
        return switch (id) {
            0x1002 => .amd,
            0x8086 => .intel,
            0x10de => .nvidia,
            else => .other,
        };
    }
};

pub const Gpu = struct {
    vendor: Vendor = .other,
    /// DRM card number (255 for an NVIDIA GPU seen only under /proc).
    card: u8 = 255,
    /// PCI address, lowercase "0000:03:00.0".
    pci: Text(16) = .{},
    name: Text(48) = .{},
    temp_path: Path = .{},
    busy_path: Path = .{},
    pm_path: Path = .{},
    vram_mb: u64 = 0,
    discrete: bool = false,
    /// Read through nvidia-smi (proprietary driver: no hwmon).
    via_smi: bool = false,
    temp_mc: ?i32 = null,
    busy_pct: ?u8 = null,
    /// Runtime-suspended: not sampled, shown as asleep.
    asleep: bool = false,
};

pub const Config = struct {
    interval_ms: i64 = DEFAULT_INTERVAL_MS,
    /// "auto" | "none" | list index ("0", "1") | PCI address | "amd" / "intel" / "nvidia".
    gpu: []const u8 = "auto",
    /// Allow running nvidia-smi for proprietary-driver NVIDIA GPUs.
    nvidia_smi: bool = true,
    /// Filesystem root for /sys and /proc ("" in real use; tests point it
    /// at a fake tree).
    root: []const u8 = "",
};

/// shell.json keys (std.json, ignore_unknown_fields), shared by both hosts.
pub const ShellJsonKeys = struct {
    system_gpu: ?[]const u8 = null,
    system_temp_units: ?[]const u8 = null,
    system_temp_interval_seconds: ?u32 = null,
    system_nvidia_smi: ?bool = null,
};

pub fn configFromKeys(k: ShellJsonKeys) Config {
    const secs = std.math.clamp(k.system_temp_interval_seconds orelse 2, 1, 60);
    return .{
        .interval_ms = @as(i64, secs) * 1000,
        .gpu = k.system_gpu orelse "auto",
        .nvidia_smi = k.system_nvidia_smi orelse true,
    };
}

pub fn unitsFromKeys(k: ShellJsonKeys) Units {
    return if (k.system_temp_units) |u| (Units.parse(u) orelse .celsius) else .celsius;
}

// --- nvidia-smi output ---------------------------------------------------------------

pub const SmiRow = struct {
    name: []const u8,
    temp_c: ?i32,
    util: ?u8,
    pci: [12]u8,
};

/// "0, NVIDIA GeForce RTX 3080, 54, 12, 00000000:01:00.0" → row. Fields
/// nvidia-smi can't read come back as "[N/A]" and become null.
pub fn parseSmiLine(line: []const u8) ?SmiRow {
    var f: [5][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, line, ',');
    while (it.next()) |part| {
        if (n == f.len) return null;
        f[n] = std.mem.trim(u8, part, " \t\r");
        n += 1;
    }
    if (n != 5) return null;
    var row = SmiRow{
        .name = f[1],
        .temp_c = std.fmt.parseInt(i32, f[2], 10) catch null,
        .util = std.fmt.parseInt(u8, f[3], 10) catch null,
        .pci = undefined,
    };
    // nvidia-smi pads the PCI domain to 8 digits ("00000000:01:00.0");
    // sysfs uses 4 ("0000:01:00.0"). Keep the last 12 characters.
    const bus = f[4];
    if (bus.len < 12) return null;
    const tail = bus[bus.len - 12 ..];
    if (tail[4] != ':' or tail[7] != ':' or tail[10] != '.') return null;
    for (tail, 0..) |ch, i| row.pci[i] = std.ascii.toLower(ch);
    return row;
}

// --- sensor ranking (pure, tested) ----------------------------------------------

fn cpuChipScore(name: []const u8) u8 {
    const top = [_][]const u8{ "k10temp", "zenpower", "coretemp", "k8temp" };
    for (top) |t| if (std.mem.eql(u8, name, t)) return 3;
    const soc = [_][]const u8{ "cpu_thermal", "cpu-thermal", "soc_thermal", "soc-thermal" };
    for (soc) |t| if (std.mem.eql(u8, name, t)) return 2;
    return 0;
}

fn thermalZoneScore(zone_type: []const u8) u8 {
    if (std.mem.eql(u8, zone_type, "x86_pkg_temp")) return 3;
    if (std.mem.startsWith(u8, zone_type, "cpu") or std.mem.startsWith(u8, zone_type, "soc")) return 2;
    if (std.mem.eql(u8, zone_type, "acpitz")) return 1;
    return 0;
}

/// Within a CPU chip: the conventional "the CPU temperature" label.
fn cpuLabelRank(label: ?[]const u8) u8 {
    const l = label orelse return 1;
    if (std.mem.eql(u8, l, "Tdie")) return 5; // true die temp (Tctl may be offset)
    if (std.mem.eql(u8, l, "Tctl")) return 4;
    if (std.mem.eql(u8, l, "Package id 0")) return 4;
    if (std.ascii.eqlIgnoreCase(l, "cpu")) return 3;
    return 1;
}

/// Auto-selection order: discrete before integrated, then bigger VRAM,
/// then anything we can actually read, then card order.
fn gpuRank(g: *const Gpu) u64 {
    var r: u64 = 0;
    if (g.discrete) r += 1 << 40;
    const vram: u64 = @min(g.vram_mb, (1 << 30) - 1);
    r += vram << 8;
    if (g.temp_path.len > 0 or g.via_smi) r += 1 << 4;
    r += 255 - @as(u64, g.card) / 16; // earlier card wins ties (coarse)
    return r;
}

fn chooseGpu(gpus: []const Gpu, pref: []const u8) ?usize {
    if (gpus.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(pref, "none")) return null;
    if (pref.len > 0 and !std.ascii.eqlIgnoreCase(pref, "auto")) {
        if (std.fmt.parseInt(usize, pref, 10)) |i| {
            if (i < gpus.len) return i;
        } else |_| {}
        for (gpus, 0..) |*g, i| {
            if (std.ascii.eqlIgnoreCase(g.pci.slice(), pref)) return i;
        }
        for (gpus, 0..) |*g, i| {
            if (std.ascii.eqlIgnoreCase(g.vendor.label(), pref)) return i;
        }
        // Named GPU gone (eGPU unplugged…): fall through to auto.
    }
    var best: usize = 0;
    for (gpus, 0..) |*g, i| {
        if (gpuRank(g) > gpuRank(&gpus[best])) best = i;
    }
    return best;
}

// --- the service -------------------------------------------------------------------------

pub const Service = struct {
    interval_ms: i64 = DEFAULT_INTERVAL_MS,
    nvidia_smi: bool = true,
    root: Text(96) = .{},
    gpu_pref: Text(32) = .{},

    cpu_path: Path = .{},
    cpu_mc: ?i32 = null,

    gpus: [MAX_GPUS]Gpu = [_]Gpu{.{}} ** MAX_GPUS,
    gpu_count: usize = 0,
    selected: ?usize = null,

    scanned: bool = false,
    next_sample_ms: i64 = 0,
    next_rescan_ms: i64 = 0,
    next_smi_ms: i64 = 0,
    smi_in_flight: bool = false,
    smi_failures: u8 = 0,

    pub fn init(cfg: Config) Service {
        var s = Service{
            .interval_ms = std.math.clamp(cfg.interval_ms, 1000, 60_000),
            .nvidia_smi = cfg.nvidia_smi,
        };
        s.root.set(cfg.root);
        s.gpu_pref.set(if (cfg.gpu.len > 0) cfg.gpu else "auto");
        return s;
    }

    pub fn cpuMc(self: *const Service) ?i32 {
        return self.cpu_mc;
    }

    pub fn selectedGpu(self: *const Service) ?*const Gpu {
        const i = self.selected orelse return null;
        return &self.gpus[i];
    }

    pub fn gpuList(self: *const Service) []const Gpu {
        return self.gpus[0..self.gpu_count];
    }

    /// Current GPU choice as it should be saved (PCI address after a click).
    pub fn gpuPref(self: *const Service) []const u8 {
        return self.gpu_pref.slice();
    }

    /// Call from the host's tick. Rescans when due, samples when due.
    /// True when anything a card would show changed.
    pub fn tick(self: *Service, now_ms: i64) bool {
        const before = self.displayKey();
        if (!self.scanned or now_ms >= self.next_rescan_ms) {
            self.rescan();
            self.scanned = true;
            self.next_rescan_ms = now_ms + RESCAN_MS;
            self.next_sample_ms = now_ms;
        }
        if (now_ms < self.next_sample_ms) return false;
        self.next_sample_ms = now_ms + self.interval_ms;
        self.sampleCpu(now_ms);
        self.sampleGpu(now_ms);
        return !std.meta.eql(before, self.displayKey());
    }

    /// True when the host should run SMI_CMD now and pass its stdout to
    /// smiComplete(). Only for a selected, awake, proprietary NVIDIA GPU.
    pub fn wantSmi(self: *Service, now_ms: i64) bool {
        if (!self.nvidia_smi or self.smi_in_flight or now_ms < self.next_smi_ms) return false;
        const i = self.selected orelse return false;
        const g = &self.gpus[i];
        if (!g.via_smi) return false;
        if (g.asleep) {
            self.next_smi_ms = now_ms + self.interval_ms;
            return false;
        }
        self.smi_in_flight = true;
        self.next_smi_ms = now_ms + @max(self.interval_ms, NVIDIA_MIN_INTERVAL_MS);
        return true;
    }

    /// nvidia-smi finished (empty `body` = it failed or isn't installed).
    /// True when the shown reading changed.
    pub fn smiComplete(self: *Service, body: []const u8, now_ms: i64) bool {
        self.smi_in_flight = false;
        const before = self.displayKey();
        var matched = false;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const row = parseSmiLine(line) orelse continue;
            for (self.gpus[0..self.gpu_count]) |*g| {
                if (!g.via_smi or !std.mem.eql(u8, g.pci.slice(), &row.pci)) continue;
                g.name.set(row.name);
                g.temp_mc = if (row.temp_c) |t| plausibleMc(@as(i64, t) * 1000) else null;
                g.busy_pct = if (row.util) |u| @as(u8, @min(u, 100)) else null;
                matched = true;
            }
        }
        if (matched) {
            self.smi_failures = 0;
        } else {
            // Missing nvidia-smi or a driver mismatch would otherwise fork
            // a failing process every 5 s forever: back off 5 s → 5 min.
            self.smi_failures +|= 1;
            const shift: u6 = @intCast(@min(self.smi_failures, 6));
            self.next_smi_ms = now_ms + @min(NVIDIA_MIN_INTERVAL_MS << shift, NVIDIA_BACKOFF_CAP_MS);
            if (self.smi_failures >= 3) {
                if (self.selected) |i| self.gpus[i].temp_mc = null;
            }
        }
        return !std.meta.eql(before, self.displayKey());
    }

    /// Click on the card: next GPU (wraps). False with fewer than two.
    pub fn cycleGpu(self: *Service) bool {
        if (self.gpu_count < 2) return false;
        const cur = self.selected orelse self.gpu_count - 1;
        const nxt = (cur + 1) % self.gpu_count;
        self.selected = nxt;
        const g = &self.gpus[nxt];
        if (g.pci.len > 0) {
            self.gpu_pref.set(g.pci.slice());
        } else {
            var b: [4]u8 = undefined;
            self.gpu_pref.set(std.fmt.bufPrint(&b, "{d}", .{nxt}) catch "auto");
        }
        self.next_sample_ms = 0;
        self.next_smi_ms = 0;
        self.smi_failures = 0;
        return true;
    }

    const DisplayKey = struct { cpu: i32, gpu: i32, busy: i16, asleep: bool, sel: i16 };

    fn displayKey(self: *const Service) DisplayKey {
        const g = self.selectedGpu();
        return .{
            .cpu = if (self.cpu_mc) |v| roundC(v) else std.math.minInt(i32),
            .gpu = if (g) |x| (if (x.temp_mc) |v| roundC(v) else std.math.minInt(i32)) else std.math.minInt(i32),
            .busy = if (g) |x| (if (x.busy_pct) |b| @as(i16, b) else -1) else -1,
            .asleep = if (g) |x| x.asleep else false,
            .sel = if (self.selected) |i| @intCast(i) else -1,
        };
    }

    fn sampleCpu(self: *Service, now_ms: i64) void {
        if (self.cpu_path.len == 0) {
            self.cpu_mc = null;
            return;
        }
        const v = readIntSlice(self.cpu_path.slice()) orelse {
            self.cpu_mc = null;
            self.next_rescan_ms = now_ms; // sensor vanished (driver reload)
            return;
        };
        self.cpu_mc = plausibleMc(v);
    }

    fn sampleGpu(self: *Service, now_ms: i64) void {
        const i = self.selected orelse return;
        const g = &self.gpus[i];
        if (g.discrete and g.pm_path.len > 0) {
            var b: [24]u8 = undefined;
            const st = readTrimSlice(g.pm_path.slice(), &b) orelse "";
            g.asleep = std.mem.eql(u8, st, "suspended");
            if (g.asleep) return; // don't wake it
        }
        if (g.via_smi) return; // the nvidia-smi child fills it in
        if (g.temp_path.len > 0) {
            if (readIntSlice(g.temp_path.slice())) |v| {
                g.temp_mc = plausibleMc(v);
            } else {
                g.temp_mc = null;
                self.next_rescan_ms = now_ms;
            }
        }
        if (g.busy_path.len > 0) {
            g.busy_pct = if (readIntSlice(g.busy_path.slice())) |v| @as(u8, @intCast(std.math.clamp(v, 0, 100))) else null;
        }
    }

    // --- discovery ---

    fn rescan(self: *Service) void {
        self.scanCpu();
        // Keep readings across a rescan (no flicker, and NVIDIA's comes
        // from a child process that may not run again for a few seconds).
        const old = self.gpus;
        const old_count = self.gpu_count;
        self.scanGpus();
        for (self.gpus[0..self.gpu_count]) |*g| {
            for (old[0..old_count]) |*o| {
                if (!std.mem.eql(u8, g.pci.slice(), o.pci.slice())) continue;
                g.temp_mc = o.temp_mc;
                g.busy_pct = o.busy_pct;
                if (g.via_smi and o.name.len > 0) g.name = o.name;
            }
        }
        self.selected = chooseGpu(self.gpus[0..self.gpu_count], self.gpu_pref.slice());
    }

    fn scanCpu(self: *Service) void {
        self.cpu_path.len = 0;
        const root = self.root.slice();
        var best: u8 = 0;
        var pb: [220]u8 = undefined;
        if (pathZ(&pb, "{s}/sys/class/hwmon", .{root})) |hp| {
            if (Dir.open(hp)) |dir| {
                defer dir.close();
                while (dir.next()) |chip| {
                    var nb: [220]u8 = undefined;
                    const np = pathZ(&nb, "{s}/sys/class/hwmon/{s}/name", .{ root, chip }) orelse continue;
                    var vb: [40]u8 = undefined;
                    const drv = readTrim(np, &vb) orelse continue;
                    const score = cpuChipScore(drv);
                    if (score <= best) continue;
                    var chip_dir: [220]u8 = undefined;
                    const cd = std.fmt.bufPrint(&chip_dir, "{s}/sys/class/hwmon/{s}", .{ root, chip }) catch continue;
                    var out: Path = .{};
                    if (bestTempInput(cd, &cpuLabelRank, &out)) {
                        self.cpu_path = out;
                        best = score;
                    }
                }
            }
        }
        if (best >= 2) return;
        if (pathZ(&pb, "{s}/sys/class/thermal", .{root})) |tp| {
            if (Dir.open(tp)) |dir| {
                defer dir.close();
                while (dir.next()) |zone| {
                    if (!std.mem.startsWith(u8, zone, "thermal_zone")) continue;
                    var zb: [220]u8 = undefined;
                    const zp = pathZ(&zb, "{s}/sys/class/thermal/{s}/type", .{ root, zone }) orelse continue;
                    var tb: [40]u8 = undefined;
                    const zt = readTrim(zp, &tb) orelse continue;
                    const score = thermalZoneScore(zt);
                    if (score <= best) continue;
                    var ib: [220]u8 = undefined;
                    const ip = std.fmt.bufPrint(&ib, "{s}/sys/class/thermal/{s}/temp", .{ root, zone }) catch continue;
                    if (readIntSlice(ip) == null) continue;
                    self.cpu_path.set(ip);
                    best = score;
                }
            }
        }
    }

    fn scanGpus(self: *Service) void {
        self.gpu_count = 0;
        const root = self.root.slice();
        var pb: [220]u8 = undefined;
        if (pathZ(&pb, "{s}/sys/class/drm", .{root})) |dp| {
            if (Dir.open(dp)) |dir| {
                defer dir.close();
                while (dir.next()) |entry| {
                    if (self.gpu_count == MAX_GPUS) break;
                    // "card0" yes; "card0-DP-1" (connectors) and renderD* no.
                    if (!std.mem.startsWith(u8, entry, "card") or entry.len == 4) continue;
                    const num = std.fmt.parseInt(u8, entry[4..], 10) catch continue;
                    var g = Gpu{ .card = num };
                    if (probeDrmCard(root, entry, &g)) {
                        self.gpus[self.gpu_count] = g;
                        self.gpu_count += 1;
                    }
                }
            }
        }
        // Proprietary NVIDIA without DRM modesetting has no cardN at all;
        // its GPUs are listed by PCI address here.
        if (pathZ(&pb, "{s}/proc/driver/nvidia/gpus", .{root})) |np| {
            if (Dir.open(np)) |dir| {
                defer dir.close();
                while (dir.next()) |addr| {
                    if (self.gpu_count == MAX_GPUS) break;
                    var lower: [16]u8 = undefined;
                    if (addr.len > lower.len) continue;
                    for (addr, 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
                    const pci = lower[0..addr.len];
                    var known = false;
                    for (self.gpus[0..self.gpu_count]) |*g| {
                        if (std.mem.eql(u8, g.pci.slice(), pci)) known = true;
                    }
                    if (known) continue;
                    var g = Gpu{ .vendor = .nvidia, .discrete = true, .via_smi = true };
                    g.pci.set(pci);
                    g.name.set("NVIDIA");
                    var pm: [220]u8 = undefined;
                    if (std.fmt.bufPrint(&pm, "{s}/sys/bus/pci/devices/{s}/power/runtime_status", .{ root, pci })) |p| g.pm_path.set(p) else |_| {}
                    self.gpus[self.gpu_count] = g;
                    self.gpu_count += 1;
                }
            }
        }
        // Stable indices (readdir order is arbitrary): sort by card number.
        var i: usize = 1;
        while (i < self.gpu_count) : (i += 1) {
            var j = i;
            while (j > 0 and self.gpus[j - 1].card > self.gpus[j].card) : (j -= 1) {
                const t = self.gpus[j - 1];
                self.gpus[j - 1] = self.gpus[j];
                self.gpus[j] = t;
            }
        }
    }
};

/// Picks the best-ranked tempN_input (N = 1..16) in a hwmon directory,
/// writing its path into `out`. False when the directory has none.
fn bestTempInput(dir: []const u8, rankFn: *const fn (?[]const u8) u8, out: *Path) bool {
    var best: u8 = 0;
    var n: usize = 1;
    while (n <= 16) : (n += 1) {
        var ib: [220]u8 = undefined;
        const ip = std.fmt.bufPrint(&ib, "{s}/temp{d}_input", .{ dir, n }) catch break;
        if (readIntSlice(ip) == null) continue;
        var lb: [220]u8 = undefined;
        const lp = std.fmt.bufPrint(&lb, "{s}/temp{d}_label", .{ dir, n }) catch break;
        var labb: [40]u8 = undefined;
        const rank = rankFn(readTrimSlice(lp, &labb));
        if (rank > best) {
            best = rank;
            out.set(ip);
        }
    }
    return best > 0;
}

fn gpuLabelRank(label: ?[]const u8) u8 {
    const l = label orelse return 1;
    if (std.mem.eql(u8, l, "edge")) return 3; // amdgpu: the board-level reading
    if (std.mem.eql(u8, l, "junction")) return 2; // hotspot: higher, spikier
    return 1;
}

/// Fills `g` from /sys/class/drm/<card>/device. False for non-PCI devices
/// (virtual/simple framebuffers) that have no vendor id.
fn probeDrmCard(root: []const u8, card: []const u8, g: *Gpu) bool {
    var base_buf: [200]u8 = undefined;
    const base = std.fmt.bufPrint(&base_buf, "{s}/sys/class/drm/{s}/device", .{ root, card }) catch return false;
    var pb: [220]u8 = undefined;
    var tb: [600]u8 = undefined;

    const vp = std.fmt.bufPrint(&pb, "{s}/vendor", .{base}) catch return false;
    const vendor_s = readTrimSlice(vp, &tb) orelse return false;
    const hex = if (std.mem.startsWith(u8, vendor_s, "0x")) vendor_s[2..] else vendor_s;
    g.vendor = Vendor.fromPciId(std.fmt.parseInt(u32, hex, 16) catch return false);

    const up = std.fmt.bufPrint(&pb, "{s}/uevent", .{base}) catch return false;
    if (readTrimSlice(up, &tb)) |uevent| {
        var lines = std.mem.splitScalar(u8, uevent, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "PCI_SLOT_NAME=")) {
                var lower: [16]u8 = undefined;
                const v = line["PCI_SLOT_NAME=".len..];
                const n = @min(v.len, lower.len);
                for (v[0..n], 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
                g.pci.set(lower[0..n]);
            }
        }
    }

    // hwmon/hwmonN under the device (amdgpu, nouveau, i915/xe on some parts).
    var hb: [220]u8 = undefined;
    if (pathZ(&hb, "{s}/hwmon", .{base})) |hp| {
        if (Dir.open(hp)) |dir| {
            defer dir.close();
            while (dir.next()) |h| {
                if (!std.mem.startsWith(u8, h, "hwmon")) continue;
                var hd: [220]u8 = undefined;
                const hdir = std.fmt.bufPrint(&hd, "{s}/hwmon/{s}", .{ base, h }) catch continue;
                var out: Path = .{};
                if (bestTempInput(hdir, &gpuLabelRank, &out)) {
                    g.temp_path = out;
                    break;
                }
            }
        }
    }

    const bp = std.fmt.bufPrint(&pb, "{s}/gpu_busy_percent", .{base}) catch return false;
    if (readIntSlice(bp) != null) g.busy_path.set(bp);
    const pp = std.fmt.bufPrint(&pb, "{s}/power/runtime_status", .{base}) catch return false;
    if (readTrimSlice(pp, &tb) != null) g.pm_path.set(pp);
    const mp = std.fmt.bufPrint(&pb, "{s}/mem_info_vram_total", .{base}) catch return false;
    if (readIntSlice(mp)) |bytes| g.vram_mb = @intCast(@max(bytes, 0) >> 20);

    g.discrete = switch (g.vendor) {
        .nvidia => true,
        // APUs carve out a small UMA buffer; dedicated cards have GBs.
        .amd => g.vram_mb > 2048,
        else => false,
    };
    g.via_smi = g.vendor == .nvidia and g.temp_path.len == 0;

    const np = std.fmt.bufPrint(&pb, "{s}/product_name", .{base}) catch return false;
    if (readTrimSlice(np, &tb)) |pn| {
        g.name.set(pn);
    } else {
        g.name.set(switch (g.vendor) {
            .amd => "AMD Radeon",
            .intel => "Intel Graphics",
            .nvidia => "NVIDIA",
            .other => "GPU",
        });
    }
    return true;
}

// --- tests ----------------------------------------------------------------------------------

test "nvidia-smi rows" {
    const r = parseSmiLine("0, NVIDIA GeForce RTX 3080, 54, 12, 00000000:01:00.0").?;
    try std.testing.expectEqualStrings("NVIDIA GeForce RTX 3080", r.name);
    try std.testing.expectEqual(@as(?i32, 54), r.temp_c);
    try std.testing.expectEqual(@as(?u8, 12), r.util);
    try std.testing.expectEqualStrings("0000:01:00.0", &r.pci);
    const na = parseSmiLine("1, Tesla T4, [N/A], [N/A], 00000000:3B:00.0").?;
    try std.testing.expect(na.temp_c == null and na.util == null);
    try std.testing.expectEqualStrings("0000:3b:00.0", &na.pci); // lowercased to match sysfs
    try std.testing.expect(parseSmiLine("") == null);
    try std.testing.expect(parseSmiLine("NVIDIA-SMI has failed because it couldn't communicate") == null);
}

test "ranking and selection" {
    try std.testing.expect(cpuLabelRank("Tdie") > cpuLabelRank("Tctl"));
    try std.testing.expect(cpuLabelRank("Tctl") > cpuLabelRank("Tccd1"));
    try std.testing.expectEqual(@as(u8, 0), cpuChipScore("nvme"));
    try std.testing.expect(thermalZoneScore("x86_pkg_temp") > thermalZoneScore("acpitz"));
    var gpus = [_]Gpu{ .{ .vendor = .intel, .card = 0 }, .{ .vendor = .amd, .card = 1, .vram_mb = 16368, .discrete = true } };
    gpus[0].pci.set("0000:00:02.0");
    gpus[1].pci.set("0000:03:00.0");
    try std.testing.expectEqual(@as(?usize, 1), chooseGpu(&gpus, "auto")); // discrete wins
    try std.testing.expectEqual(@as(?usize, 0), chooseGpu(&gpus, "0000:00:02.0"));
    try std.testing.expectEqual(@as(?usize, 0), chooseGpu(&gpus, "intel"));
    try std.testing.expectEqual(@as(?usize, 1), chooseGpu(&gpus, "1"));
    try std.testing.expectEqual(@as(?usize, 1), chooseGpu(&gpus, "0000:99:00.0")); // gone → auto
    try std.testing.expect(chooseGpu(&gpus, "none") == null);
    try std.testing.expect(chooseGpu(gpus[0..0], "auto") == null);
}

test "formatting and units" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("62\u{00B0}C", fmtTemp(61_625, .celsius, &b));
    try std.testing.expectEqualStrings("143\u{00B0}F", fmtTemp(61_625, .fahrenheit, &b));
    try std.testing.expectEqualStrings("\u{2014}", fmtTemp(null, .celsius, &b));
    try std.testing.expectEqual(@as(?i32, 41_375), plausibleMc(41_375));
    try std.testing.expectEqual(@as(?i32, 45_000), plausibleMc(45)); // zone reporting °C
    try std.testing.expect(plausibleMc(0) == null);
    try std.testing.expect(plausibleMc(-273_000) == null);
    try std.testing.expectEqual(@as(u32, 0), heatTint(55_000));
    try std.testing.expect(heatTint(90_000) != 0);
    const cfg = configFromKeys(.{ .system_temp_interval_seconds = 0 });
    try std.testing.expectEqual(@as(i64, 1000), cfg.interval_ms);
    try std.testing.expectEqual(Units.fahrenheit, unitsFromKeys(.{ .system_temp_units = "F" }));
}

// Fake sysfs tree for the discovery tests.
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

test "discovery on a fake sysfs: Ryzen + Radeon dGPU + Intel iGPU" {
    var rb: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&rb, "/tmp/perihelion-temps-test-{d}", .{std.c.getpid()}) catch unreachable;
    // An NVMe chip that must not be mistaken for the CPU.
    writeFile(root, "sys/class/hwmon/hwmon0/name", "nvme\n");
    writeFile(root, "sys/class/hwmon/hwmon0/temp1_input", "38850\n");
    // k10temp: Tctl on temp1, a CCD on temp3.
    writeFile(root, "sys/class/hwmon/hwmon1/name", "k10temp\n");
    writeFile(root, "sys/class/hwmon/hwmon1/temp1_input", "45125\n");
    writeFile(root, "sys/class/hwmon/hwmon1/temp1_label", "Tctl\n");
    writeFile(root, "sys/class/hwmon/hwmon1/temp3_input", "43000\n");
    writeFile(root, "sys/class/hwmon/hwmon1/temp3_label", "Tccd1\n");
    // card1: Radeon with 16 GiB VRAM, edge + junction sensors.
    writeFile(root, "sys/class/drm/card1/device/vendor", "0x1002\n");
    writeFile(root, "sys/class/drm/card1/device/uevent", "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:03:00.0\n");
    writeFile(root, "sys/class/drm/card1/device/hwmon/hwmon2/temp1_input", "51000\n");
    writeFile(root, "sys/class/drm/card1/device/hwmon/hwmon2/temp1_label", "edge\n");
    writeFile(root, "sys/class/drm/card1/device/hwmon/hwmon2/temp2_input", "58000\n");
    writeFile(root, "sys/class/drm/card1/device/hwmon/hwmon2/temp2_label", "junction\n");
    writeFile(root, "sys/class/drm/card1/device/gpu_busy_percent", "7\n");
    writeFile(root, "sys/class/drm/card1/device/power/runtime_status", "active\n");
    writeFile(root, "sys/class/drm/card1/device/mem_info_vram_total", "17163091968\n");
    // card0: Intel iGPU, no temperature sensor; a connector entry to skip.
    writeFile(root, "sys/class/drm/card0/device/vendor", "0x8086\n");
    writeFile(root, "sys/class/drm/card0/device/uevent", "DRIVER=i915\nPCI_SLOT_NAME=0000:00:02.0\n");
    writeFile(root, "sys/class/drm/card0-DP-1/status", "connected\n");

    var s = Service.init(.{ .root = root });
    try std.testing.expect(s.tick(0));
    try std.testing.expectEqual(@as(?i32, 45_125), s.cpuMc());
    try std.testing.expectEqual(@as(usize, 2), s.gpuList().len);
    try std.testing.expectEqual(@as(u8, 0), s.gpuList()[0].card); // sorted
    const g = s.selectedGpu().?;
    try std.testing.expectEqual(Vendor.amd, g.vendor);
    try std.testing.expectEqualStrings("0000:03:00.0", g.pci.slice());
    try std.testing.expectEqual(@as(?i32, 51_000), g.temp_mc); // edge, not junction
    try std.testing.expectEqual(@as(?u8, 7), g.busy_pct);
    try std.testing.expect(!s.wantSmi(0)); // not an NVIDIA proprietary GPU

    // Not due yet → no work, no change.
    try std.testing.expect(!s.tick(500));
    // Same reading → due, but nothing changed for the card.
    try std.testing.expect(!s.tick(DEFAULT_INTERVAL_MS));

    // The dGPU runtime-suspends: shown asleep, its sensor left alone.
    writeFile(root, "sys/class/drm/card1/device/power/runtime_status", "suspended\n");
    try std.testing.expect(s.tick(2 * DEFAULT_INTERVAL_MS));
    try std.testing.expect(s.selectedGpu().?.asleep);

    // Click cycles to the iGPU and remembers it by PCI address.
    try std.testing.expect(s.cycleGpu());
    try std.testing.expectEqualStrings("0000:00:02.0", s.gpuPref());
}

test "nvidia via /proc without DRM: smi drives the reading, failures back off" {
    var rb: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&rb, "/tmp/perihelion-temps-nv-{d}", .{std.c.getpid()}) catch unreachable;
    writeFile(root, "proc/driver/nvidia/gpus/0000:01:00.0/information", "Model: X\n");
    writeFile(root, "sys/bus/pci/devices/0000:01:00.0/power/runtime_status", "active\n");
    var s = Service.init(.{ .root = root });
    _ = s.tick(0);
    const g = s.selectedGpu().?;
    try std.testing.expect(g.via_smi and g.vendor == .nvidia);
    try std.testing.expect(s.wantSmi(0));
    try std.testing.expect(!s.wantSmi(1)); // one child at a time
    try std.testing.expect(s.smiComplete("0, NVIDIA GeForce RTX 4070, 47, 3, 00000000:01:00.0\n", 100));
    try std.testing.expectEqual(@as(?i32, 47_000), s.selectedGpu().?.temp_mc);
    try std.testing.expectEqualStrings("NVIDIA GeForce RTX 4070", s.selectedGpu().?.name.slice());
    // nvidia-smi missing: empty output → exponential backoff, not every 5 s.
    try std.testing.expect(!s.wantSmi(1000)); // rate limit
    const t1 = NVIDIA_MIN_INTERVAL_MS + 100;
    try std.testing.expect(s.wantSmi(t1));
    _ = s.smiComplete("", t1);
    try std.testing.expect(s.next_smi_ms >= t1 + 2 * NVIDIA_MIN_INTERVAL_MS);
}
