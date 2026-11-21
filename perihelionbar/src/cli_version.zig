//! `<program> --version`: "<name> <version> (<commit>)" and exit, before
//! anything else starts (no display, no GTK, no lock). The updater runs it
//! on every downloaded program before installing, so a missing library or
//! symbol shows up there instead of on the desktop. The version and commit
//! come from the build (-Dversion, -Dcommit; see build.zig).

const std = @import("std");
const info = @import("build_info");

pub const version: []const u8 = info.version;
pub const commit: []const u8 = info.commit;

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;

/// Exits with the version line when the first argument is --version.
pub fn handle(name: []const u8) void {
    var buf: [256]u8 = undefined;
    const fd = open("/proc/self/cmdline", 0o2000000);
    if (fd < 0) return;
    const n = read(fd, &buf, buf.len);
    _ = close(fd);
    if (n <= 0) return;
    const cmd = buf[0..@intCast(n)];
    const end0 = std.mem.indexOfScalar(u8, cmd, 0) orelse return;
    const rest = cmd[end0 + 1 ..];
    const arg = rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse rest.len];
    if (!std.mem.eql(u8, arg, "--version")) return;
    var out: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&out, "{s} {s} ({s})\n", .{ name, version, commit }) catch return;
    _ = write(1, line.ptr, line.len);
    _exit(0);
}
