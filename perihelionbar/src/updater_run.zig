//! The working half of Settings > Updates: the headless subcommands
//! `perihelion-settings --check-updates [--if-due]`, `--download-update`,
//! `--verify-update DIR TAG` and `--install-update DIR TAG`. The page runs
//! them asynchronously and reads their last line; the auto-check timer runs
//! `--check-updates --if-due`; CI runs `--verify-update` on a release built
//! from its own binaries.
//!
//! Every decision comes from updater_core.zig. This file only runs
//! programs (absolute paths, argv, never a shell), reads and writes files,
//! and reports. It never deletes anything: downloads go to a fresh
//! mkdtemp folder in /tmp.
//!
//! Output protocol (stdout, one line each): "step <text>" while working,
//! then exactly one of "error <text>", "ready <dir>", "installed <tag>",
//! "latest <tag> <installed version> available|up_to_date", "skipped <why>".

const std = @import("std");
const core = @import("updater_core.zig");
const cli_version = @import("cli_version");

const gpa = std.heap.c_allocator;

const libc = struct {
    extern "c" fn fork() c_int;
    extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
    extern "c" fn dup2(a: c_int, b: c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn chdir(path: [*:0]const u8) c_int;
    extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
    extern "c" fn alarm(seconds: c_uint) c_uint;
    extern "c" fn _exit(code: c_int) noreturn;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
    extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
    extern "c" fn rename(a: [*:0]const u8, b: [*:0]const u8) c_int;
    extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn time(t: ?*i64) i64;
    extern "c" fn fchmod(fd: c_int, mode: c_uint) c_int;
    extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;
};

// x86_64 struct stat (the release is x86_64 only).
const Stat = extern struct {
    dev: u64,
    ino: u64,
    nlink: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    _pad0: u32,
    rdev: u64,
    size: i64,
    blksize: i64,
    blocks: i64,
    times: [6]i64, // atime, mtime, ctime (sec, nsec each)
    reserved: [3]i64,
};

comptime {
    if (@sizeOf(Stat) != 144) @compileError("struct stat is 144 bytes on x86_64");
}

const O_RDONLY = 0;
const O_WRONLY = 1;
const O_CREAT = 0o100;
const O_TRUNC = 0o1000;
const O_CLOEXEC = 0o2000000;
const O_NOFOLLOW = 0o400000;

// --- output -----------------------------------------------------------------------

fn say(comptime kind: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, kind ++ " " ++ fmt ++ "\n", args) catch return;
    // One line per write: the page reads whole lines.
    for (line) |*ch| if (ch.* == '\n' and ch != &line[line.len - 1]) {
        ch.* = ' ';
    };
    _ = libc.write(1, line.ptr, line.len);
}

// --- running programs -----------------------------------------------------------

pub const Ran = struct {
    exited_ok: bool,
    out: []const u8,
};

/// Runs argv[0] (an absolute path) with stdout and stderr captured into
/// `buf` (the rest is read and dropped), in `cwd` when given, killed by
/// SIGALRM after `limit_s` seconds.
pub fn run(argv: []const []const u8, cwd: ?[]const u8, limit_s: c_uint, buf: []u8) Ran {
    var zbufs: [40][512]u8 = undefined;
    var zargv: [41:null]?[*:0]const u8 = @splat(null);
    if (argv.len == 0 or argv.len > 40) return .{ .exited_ok = false, .out = "too many arguments" };
    for (argv, 0..) |a, i| {
        const za = std.fmt.bufPrintSentinel(&zbufs[i], "{s}", .{a}, 0) catch return .{ .exited_ok = false, .out = "argument too long" };
        zargv[i] = za.ptr;
    }
    var cwd_buf: [512]u8 = undefined;
    const cwd_z: ?[*:0]const u8 = if (cwd) |d| (std.fmt.bufPrintSentinel(&cwd_buf, "{s}", .{d}, 0) catch return .{ .exited_ok = false, .out = "path too long" }).ptr else null;

    var fds: [2]c_int = .{ -1, -1 };
    if (libc.pipe2(&fds, O_CLOEXEC) != 0) return .{ .exited_ok = false, .out = "pipe failed" };
    const pid = libc.fork();
    if (pid < 0) {
        _ = libc.close(fds[0]);
        _ = libc.close(fds[1]);
        return .{ .exited_ok = false, .out = "fork failed" };
    }
    if (pid == 0) {
        _ = libc.dup2(fds[1], 1);
        _ = libc.dup2(fds[1], 2);
        const devnull = libc.open("/dev/null", O_RDONLY);
        if (devnull >= 0) _ = libc.dup2(devnull, 0);
        if (cwd_z) |d| if (libc.chdir(d) != 0) libc._exit(126);
        _ = libc.alarm(limit_s);
        _ = libc.execv(zargv[0].?, &zargv);
        libc._exit(127);
    }
    _ = libc.close(fds[1]);
    var got: usize = 0;
    var sink: [4096]u8 = undefined;
    while (true) {
        const n = if (got < buf.len) libc.read(fds[0], buf[got..].ptr, buf.len - got) else libc.read(fds[0], &sink, sink.len);
        if (n <= 0) break;
        if (got < buf.len) got += @intCast(n);
    }
    _ = libc.close(fds[0]);
    var status: c_int = 0;
    while (libc.waitpid(pid, &status, 0) < 0) {}
    const st: u32 = @bitCast(status);
    const exited = (st & 0x7f) == 0;
    const code = (st >> 8) & 0xff;
    return .{ .exited_ok = exited and code == 0, .out = buf[0..got] };
}

// --- files -------------------------------------------------------------------------

fn z(buf: []u8, comptime fmt: []const u8, args: anytype) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0) catch null;
}

/// Reads a whole regular file (not following a symlink), at most `max`.
pub fn readFile(path: []const u8, max: usize) ?[]u8 {
    var pb: [600]u8 = undefined;
    const p = z(&pb, "{s}", .{path}) orelse return null;
    const fd = libc.open(p.ptr, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return null;
    defer _ = libc.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = libc.read(fd, &chunk, chunk.len);
        if (n < 0) {
            list.deinit(gpa);
            return null;
        }
        if (n == 0) break;
        if (list.items.len + @as(usize, @intCast(n)) > max) {
            list.deinit(gpa);
            return null;
        }
        list.appendSlice(gpa, chunk[0..@intCast(n)]) catch {
            list.deinit(gpa);
            return null;
        };
    }
    return list.toOwnedSlice(gpa) catch null;
}

/// Writes through a temporary file and a rename, so a reader never sees half.
pub fn writeFile(path: []const u8, data: []const u8, mode: c_uint) bool {
    var pb: [600]u8 = undefined;
    var tb: [610]u8 = undefined;
    const p = z(&pb, "{s}", .{path}) orelse return false;
    const t = z(&tb, "{s}.new", .{path}) orelse return false;
    const fd = libc.open(t.ptr, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, mode);
    if (fd < 0) return false;
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) {
            _ = libc.close(fd);
            return false;
        }
        off += @intCast(n);
    }
    _ = libc.fchmod(fd, mode);
    _ = libc.close(fd);
    return libc.rename(t.ptr, p.ptr) == 0;
}

/// mkdir -p for a path inside the home folder.
fn mkdirs(path: []const u8) void {
    var buf: [600]u8 = undefined;
    if (path.len >= buf.len) return;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            @memcpy(buf[0..i], path[0..i]);
            buf[i] = 0;
            _ = libc.mkdir(@ptrCast(&buf), 0o755);
        }
    }
}

fn isRegular(path: []const u8) bool {
    var pb: [600]u8 = undefined;
    const p = z(&pb, "{s}", .{path}) orelse return false;
    var st: Stat = undefined;
    if (libc.lstat(p.ptr, &st) != 0) return false;
    return (st.mode & 0o170000) == 0o100000;
}

fn sha256File(path: []const u8) ?[32]u8 {
    var pb: [600]u8 = undefined;
    const p = z(&pb, "{s}", .{path}) orelse return null;
    const fd = libc.open(p.ptr, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return null;
    defer _ = libc.close(fd);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = libc.read(fd, &chunk, chunk.len);
        if (n < 0) return null;
        if (n == 0) break;
        h.update(chunk[0..@intCast(n)]);
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

// --- where things live --------------------------------------------------------------

fn home() []const u8 {
    return std.mem.span(libc.getenv("HOME") orelse "/nonexistent");
}

/// ~/.local/state/perihelionbar (or $XDG_STATE_HOME/perihelionbar).
fn stateDir(buf: []u8) []const u8 {
    if (libc.getenv("XDG_STATE_HOME")) |x| {
        const s = std.mem.span(x);
        if (s.len > 0 and s[0] == '/') return std.fmt.bufPrint(buf, "{s}/perihelionbar", .{s}) catch "";
    }
    return std.fmt.bufPrint(buf, "{s}/.local/state/perihelionbar", .{home()}) catch "";
}

fn statePath(buf: []u8, name: []const u8) []const u8 {
    var db: [512]u8 = undefined;
    const d = stateDir(&db);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ d, name }) catch "";
}

pub fn loadSaved(text_out: *?[]u8) core.Saved {
    var pb: [600]u8 = undefined;
    text_out.* = readFile(statePath(&pb, "updates"), 4096);
    return core.Saved.parse(text_out.* orelse "");
}

fn storeSaved(s: core.Saved) void {
    var db: [512]u8 = undefined;
    mkdirs(stateDir(&db));
    var buf: [256]u8 = undefined;
    const text = s.format(&buf) catch return;
    var pb: [600]u8 = undefined;
    _ = writeFile(statePath(&pb, "updates"), text, 0o644);
}

pub fn readMarker() ?[]u8 {
    var pb: [600]u8 = undefined;
    return readFile(statePath(&pb, "install-method"), 256);
}

pub fn isoRefExists() bool {
    return libc.access("/usr/share/perihelion/perihelionbar.ref", 0) == 0;
}

/// The installed shell's version: /usr/bin/perihelion-bar --version, or
/// this program's own when that can't be read.
pub fn installedVersion(buf: []u8) []const u8 {
    var out: [256]u8 = undefined;
    const r = run(&.{ "/usr/bin/perihelion-bar", "--version" }, null, 10, &out);
    if (r.exited_ok) {
        var it = std.mem.tokenizeAny(u8, r.out, " \t\r\n()");
        while (it.next()) |tok| if (core.Version.parse(tok) != null) {
            const n = @min(tok.len, buf.len);
            @memcpy(buf[0..n], tok[0..n]);
            return buf[0..n];
        };
    }
    return cli_version.version;
}

// --- check -----------------------------------------------------------------------------

/// `--check-updates [--if-due]`. With --if-due (the timer) it only checks
/// when auto-check is on and the interval has passed, and sends one
/// notification per new release.
pub fn check(if_due: bool, auto_check: bool, interval_h: u32) u8 {
    var saved_text: ?[]u8 = null;
    var saved = loadSaved(&saved_text);
    defer if (saved_text) |t| gpa.free(t);
    const now = libc.time(null);
    if (if_due and !core.checkDue(auto_check, interval_h, saved.last_checked, now)) {
        say("skipped", "{s}", .{if (auto_check) "not due yet" else "automatic checks are off"});
        return 0;
    }
    say("step", "Asking GitHub for the latest release", .{});
    const json_buf = gpa.alloc(u8, 1 << 20) catch return fail("out of memory");
    defer gpa.free(json_buf);
    const argv = core.apiArgv();
    const r = run(&argv, null, 150, json_buf);
    if (!r.exited_ok) {
        // 404 from the "latest release" endpoint: nothing published yet. That
        // is an answer, so it counts as a check (the timer waits again).
        if (std.mem.indexOf(u8, r.out, "error: 404") != null) {
            saved.last_checked = now;
            storeSaved(saved);
            return fail("No release has been published yet.");
        }
        return fail(firstLine(r.out, "GitHub could not be reached."));
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rel = core.parseRelease(arena.allocator(), r.out) catch |e| return fail(switch (e) {
        error.Draft, error.PreRelease => "The latest release is not a final release yet.",
        error.NoTag, error.BadTag => "The latest release has no usable version tag.",
        else => "GitHub's answer could not be read.",
    });
    // Keep the answer: the page shows its notes, --download-update uses it.
    var db: [512]u8 = undefined;
    mkdirs(stateDir(&db));
    var pb: [600]u8 = undefined;
    _ = writeFile(statePath(&pb, "latest-release.json"), r.out, 0o644);

    var vb: [64]u8 = undefined;
    const installed_s = installedVersion(&vb);
    const installed = core.Version.parse(installed_s) orelse core.Version{ .major = 0, .minor = 0, .patch = 0, .pre = "unknown" };
    const newer = rel.version.isNewer(installed);
    saved.last_checked = now;
    saved.latest_tag = rel.tag;
    if (if_due and newer and !std.mem.eql(u8, saved.notified_tag, rel.tag)) {
        notify(rel.tag);
        saved.notified_tag = rel.tag;
    }
    storeSaved(saved);
    say("latest", "{s} {s} {s}", .{ rel.tag, installed_s, if (newer) "available" else "up_to_date" });
    return 0;
}

fn notify(tag: []const u8) void {
    if (libc.access("/usr/bin/notify-send", 1) != 0) return;
    var tb: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&tb, "Perihelion Shell {s} is available", .{tag}) catch return;
    var out: [256]u8 = undefined;
    _ = run(&.{ "/usr/bin/notify-send", "--app-name=Perihelion Settings", "--icon=software-update-available-symbolic", title, "Open Perihelion Settings > Updates to install it." }, null, 10, &out);
}

fn firstLine(text: []const u8, fallback: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return fallback;
    const nl = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    return t[0..@min(nl, 300)];
}

fn fail(msg: []const u8) u8 {
    say("error", "{s}", .{msg});
    return 1;
}

// --- download ----------------------------------------------------------------------------

/// `--download-update`: the release saved by the last check, into a new
/// folder, then the full verification.
pub fn download() u8 {
    var pb: [600]u8 = undefined;
    const json = readFile(statePath(&pb, "latest-release.json"), 1 << 20) orelse return fail("Check for updates first.");
    defer gpa.free(json);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rel = core.parseRelease(arena.allocator(), json) catch return fail("The saved release could not be read; check again.");

    var nb: [128]u8 = undefined;
    const tarball = core.tarballName(&nb, rel.version) catch return fail("bad version");
    const want = [_][]const u8{ tarball, core.SUMS_NAME };

    var tmpl = "/tmp/perihelion-update-XXXXXX".*;
    const dir_z = libc.mkdtemp(&tmpl) orelse return fail("Could not make a download folder in /tmp.");
    const dir = std.mem.span(dir_z);

    for (want) |name| {
        const a = rel.asset(name) orelse {
            var eb: [200]u8 = undefined;
            return fail(std.fmt.bufPrint(&eb, "The release has no {s}.", .{name}) catch "The release is incomplete.");
        };
        if (!core.checkAssetUrl(a.url, rel.tag, name)) return fail("The release points at a download outside this project; refusing.");
        say("step", "Downloading {s}", .{name});
        var ob: [2048]u8 = undefined;
        const probe = core.probeArgv(a.url);
        const pr = run(&probe, null, 60, &ob);
        if (!pr.exited_ok) return fail(firstLine(pr.out, "github.com could not be reached."));
        const loc = core.parseRedirectProbe(pr.out) orelse return fail("github.com did not answer with the expected redirect.");
        if (!core.checkRedirect(loc)) return fail("The download redirects to an unexpected host; refusing.");
        var fb: [600]u8 = undefined;
        const out_path = std.fmt.bufPrint(&fb, "{s}/{s}", .{ dir, name }) catch return fail("path too long");
        const fetch = core.fetchArgv(loc, out_path);
        var eb2: [2048]u8 = undefined;
        const fr = run(&fetch, null, 150, &eb2);
        if (!fr.exited_ok) return fail(firstLine(fr.out, "The download failed."));
    }
    if (verifyDir(dir, rel.tag) != 0) return 1;
    say("ready", "{s}", .{dir});
    return 0;
}

// --- verify --------------------------------------------------------------------------------

pub fn verify(dir: []const u8, tag: []const u8) u8 {
    if (verifyDir(dir, tag) != 0) return 1;
    say("ready", "{s}", .{dir});
    return 0;
}

/// SHA-256, the tar listing, unpacking, the manifest, and every program's
/// --version run from the download folder.
fn verifyDir(dir: []const u8, tag: []const u8) u8 {
    const version = core.Version.parse(tag) orelse return fail("bad version tag");
    var nb: [128]u8 = undefined;
    const tarball = core.tarballName(&nb, version) catch return fail("bad version");
    const top = core.topDir(tarball);

    say("step", "Checking the SHA-256 checksum", .{});
    var pb: [600]u8 = undefined;
    const sums_path = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, core.SUMS_NAME }) catch return fail("path too long");
    const sums = readFile(sums_path, 64 * 1024) orelse return fail("SHA256SUMS is missing.");
    defer gpa.free(sums);
    const want = core.parseSha256Sums(sums, tarball) orelse return fail("SHA256SUMS has no (single) line for the release tarball.");
    var tb: [600]u8 = undefined;
    const tar_path = std.fmt.bufPrint(&tb, "{s}/{s}", .{ dir, tarball }) catch return fail("path too long");
    if (!isRegular(tar_path)) return fail("The release tarball is missing.");
    const got = sha256File(tar_path) orelse return fail("The tarball could not be read.");
    if (!core.digestsEqual(got, want)) return fail("The checksum does not match: the download is damaged or was changed. Nothing was installed.");

    say("step", "Checking what the tarball contains", .{});
    const list_buf = gpa.alloc(u8, 256 * 1024) catch return fail("out of memory");
    defer gpa.free(list_buf);
    const list_argv = core.tarListArgv(tar_path);
    const lr = run(&list_argv, null, 60, list_buf);
    if (!lr.exited_ok) return fail(firstLine(lr.out, "tar could not read the tarball."));
    switch (core.checkTarListing(lr.out, top)) {
        .ok => {},
        .empty => return fail("The tarball is empty."),
        .not_regular => |n| return failName("The tarball holds something that is not a plain file: ", n),
        .outside => |n| return failName("The tarball holds a path outside its folder: ", n),
        .unknown => |n| return failName("The tarball holds an unexpected file: ", n),
    }

    say("step", "Unpacking", .{});
    var xb: [600]u8 = undefined;
    const xdir = std.fmt.bufPrint(&xb, "{s}/x", .{dir}) catch return fail("path too long");
    var xzb: [600]u8 = undefined;
    const xz = z(&xzb, "{s}", .{xdir}) orelse return fail("path too long");
    if (libc.mkdir(xz.ptr, 0o700) != 0 and libc.access(xz.ptr, 0) != 0) return fail("Could not make the unpack folder.");
    var ob: [4096]u8 = undefined;
    const ex_argv = core.tarExtractArgv(tar_path, xdir);
    const er = run(&ex_argv, null, 120, &ob);
    if (!er.exited_ok) return fail(firstLine(er.out, "tar could not unpack the release."));

    say("step", "Checking the manifest", .{});
    var mb: [600]u8 = undefined;
    const man_path = std.fmt.bufPrint(&mb, "{s}/{s}/{s}", .{ xdir, top, core.MANIFEST_NAME }) catch return fail("path too long");
    const man_text = readFile(man_path, 64 * 1024) orelse return fail("The release has no MANIFEST.");
    defer gpa.free(man_text);
    const m = core.parseManifest(man_text) catch return fail("The MANIFEST could not be read.");
    const problem = core.checkManifest(&m);
    if (problem != .ok) {
        var db: [300]u8 = undefined;
        return fail(core.describe(&db, problem));
    }
    for (m.slice()) |e| {
        var sb: [600]u8 = undefined;
        const staged = std.fmt.bufPrint(&sb, "{s}/{s}/{s}", .{ xdir, top, e.src }) catch return fail("path too long");
        if (!isRegular(staged)) return failName("The release is missing a listed file: ", e.src);
    }

    say("step", "Trying each program (--version)", .{});
    var bdb: [600]u8 = undefined;
    const bin_dir = std.fmt.bufPrint(&bdb, "{s}/{s}/bin", .{ xdir, top }) catch return fail("path too long");
    for (m.slice()) |e| {
        const a = core.findAllowed(e.src).?;
        if (!a.binary) continue;
        var sb: [600]u8 = undefined;
        const staged = std.fmt.bufPrint(&sb, "{s}/{s}/{s}", .{ xdir, top, e.src }) catch return fail("path too long");
        var out: [2048]u8 = undefined;
        const r = run(&.{ staged, "--version" }, bin_dir, 15, &out);
        if (!core.versionOutputOk(r.out, r.exited_ok, version)) {
            var eb: [600]u8 = undefined;
            return fail(std.fmt.bufPrint(&eb, "{s} does not start on this system: {s}. Nothing was installed.", .{ std.fs.path.basename(e.src), firstLine(r.out, "no output") }) catch "A program does not start on this system. Nothing was installed.");
        }
    }
    return 0;
}

fn failName(prefix: []const u8, name: []const u8) u8 {
    var buf: [600]u8 = undefined;
    return fail(std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, name[0..@min(name.len, 300)] }) catch prefix);
}

// --- install ------------------------------------------------------------------------------

/// `--install-update DIR TAG`: verifies again (the programs run once more),
/// then one pkexec install for the system files and plain writes for the
/// home files, then records how this copy was installed.
pub fn install(dir: []const u8, tag: []const u8) u8 {
    if (isoRefExists()) return fail("Perihelion Linux updates the shell with the system; use the system updater.");
    if (verifyDir(dir, tag) != 0) return 1;
    const version = core.Version.parse(tag).?;
    var nb: [128]u8 = undefined;
    const top = core.topDir(core.tarballName(&nb, version) catch return fail("bad version"));
    var mb: [600]u8 = undefined;
    const man_path = std.fmt.bufPrint(&mb, "{s}/x/{s}/{s}", .{ dir, top, core.MANIFEST_NAME }) catch return fail("path too long");
    const man_text = readFile(man_path, 64 * 1024) orelse return fail("The release has no MANIFEST.");
    defer gpa.free(man_text);
    const m = core.parseManifest(man_text) catch return fail("The MANIFEST could not be read.");

    var staged_bufs: [core.MAX_ENTRIES][600]u8 = undefined;
    var staged: [core.MAX_ENTRIES][]const u8 = undefined;
    var n_sys: usize = 0;
    for (m.slice()) |e| {
        const a = core.findAllowed(e.src).?;
        if (a.scope != .system) continue;
        staged[n_sys] = std.fmt.bufPrint(&staged_bufs[n_sys], "{s}/x/{s}/{s}", .{ dir, top, e.src }) catch return fail("path too long");
        n_sys += 1;
    }
    var argv: [core.MAX_ENTRIES + 8][]const u8 = undefined;
    const n = core.installArgv(&argv, staged[0..n_sys]) orelse return fail("The install list is not allowed.");
    say("step", "Installing the programs (asks for your password)", .{});
    var out: [4096]u8 = undefined;
    const r = run(argv[0..n], null, 600, &out);
    if (!r.exited_ok) return fail(firstLine(r.out, "The install was cancelled or failed. Nothing in /usr/bin changed."));

    say("step", "Installing the app drawer", .{});
    for (m.slice()) |e| {
        const a = core.findAllowed(e.src).?;
        if (a.scope != .home) continue;
        var sb: [600]u8 = undefined;
        const src = std.fmt.bufPrint(&sb, "{s}/x/{s}/{s}", .{ dir, top, e.src }) catch return fail("path too long");
        var hb: [600]u8 = undefined;
        const dest = core.homePath(&hb, home(), a.dest) orelse return fail("No home folder.");
        const data = readFile(src, 4 << 20) orelse return failName("Could not read ", e.src);
        defer gpa.free(data);
        mkdirs(std.fs.path.dirname(dest) orelse return fail("bad destination"));
        if (!writeFile(dest, data, a.mode)) return failName("Could not write ", dest);
    }

    var db: [512]u8 = undefined;
    mkdirs(stateDir(&db));
    var kb: [96]u8 = undefined;
    const marker = std.fmt.bufPrint(&kb, "release {s}\n", .{tag}) catch "release\n";
    var pb: [600]u8 = undefined;
    _ = writeFile(statePath(&pb, "install-method"), marker, 0o644);
    say("installed", "{s}", .{tag});
    return 0;
}

/// `--release-manifest`: one "<mode> <src> <dest>" line per allowlist entry.
pub fn printManifest() void {
    for (core.ALLOWLIST) |a| {
        var buf: [300]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{o} {s} {s}\n", .{ a.mode, a.src, a.dest }) catch continue;
        _ = libc.write(1, line.ptr, line.len);
    }
}
