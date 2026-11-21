//! Password checking for perihelion-lockscreen.
//!
//! PAM blocks (pam_faildelay alone waits about two seconds after a wrong
//! password), so each attempt runs on its own thread while the Wayland loop
//! keeps drawing. The thread writes one result byte down a pipe; main.zig
//! watches the read end and calls `finish`, which joins the thread.
//!
//! The worker keeps its own copy of the password in a locked (never
//! swapped) buffer, wiped with secureZero as soon as PAM returns. Nothing
//! here logs.

const std = @import("std");
const linux = std.os.linux;
const c = @import("c.zig");
const logic = @import("logic.zig");

pub const Result = logic.AuthResult;

const SERVICE_MAX = 63;
const USER_MAX = 63;

/// One PAM conversation. pam_start borrows these for the whole call.
const Conversation = struct {
    user: [*:0]const u8,
    password: []const u8,
};

/// pam_conv.conv. The response array and its strings are allocated with
/// the C allocator because PAM frees them (and wipes the secret) itself.
fn converse(num_msg: c_int, msg: ?[*]?*const c.pam.Message, resp: ?*?[*]c.pam.Response, appdata: ?*anyopaque) callconv(.c) c_int {
    const conv: *const Conversation = @ptrCast(@alignCast(appdata orelse return c.pam.CONV_ERR));
    const msgs = msg orelse return c.pam.CONV_ERR;
    const out_ptr = resp orelse return c.pam.CONV_ERR;
    if (num_msg <= 0 or num_msg > c.pam.MAX_NUM_MSG) return c.pam.CONV_ERR;
    const n: usize = @intCast(num_msg);
    const raw = c.calloc(n, @sizeOf(c.pam.Response)) orelse return c.pam.BUF_ERR;
    const out: [*]c.pam.Response = @ptrCast(@alignCast(raw));
    for (0..n) |i| {
        const m = msgs[i] orelse continue;
        const answer: []const u8 = switch (m.msg_style) {
            c.pam.PROMPT_ECHO_OFF => conv.password,
            c.pam.PROMPT_ECHO_ON => std.mem.span(conv.user),
            else => continue, // info and error texts need no answer
        };
        const buf_raw = c.malloc(answer.len + 1) orelse {
            for (out[0..i]) |r| if (r.resp) |p| {
                // Only ever our own copies; wipe before handing back.
                const s = std.mem.span(@as([*:0]u8, @ptrCast(p)));
                std.crypto.secureZero(u8, s);
                c.free(p);
            };
            c.free(raw);
            return c.pam.BUF_ERR;
        };
        const buf: [*]u8 = @ptrCast(buf_raw);
        @memcpy(buf[0..answer.len], answer);
        buf[answer.len] = 0;
        out[i].resp = buf;
    }
    out_ptr.* = out;
    return c.pam.SUCCESS;
}

const PASSWORD_CAP = logic.PASSWORD_MAX;

/// One blocking authentication. Never call this on the main loop.
fn authenticate(service: [*:0]const u8, user: [*:0]const u8, password: []const u8) Result {
    var conv_state = Conversation{ .user = user, .password = password };
    const conv = c.pam.Conv{ .conv = converse, .appdata_ptr = &conv_state };
    var handle: ?*c.pam.Handle = null;
    const started = c.pam.pam_start(service, user, &conv, &handle);
    const h = handle orelse return .unavailable;
    if (started != c.pam.SUCCESS) {
        _ = c.pam.pam_end(h, started);
        return .unavailable;
    }
    const status = c.pam.pam_authenticate(h, 0);
    _ = c.pam.pam_end(h, status);
    return if (status == c.pam.SUCCESS) .ok else .denied;
}

/// The off-thread half. Lives inside the program's state for its whole
/// life (main.zig mlocks it); `start` only while no attempt is running.
pub const Worker = struct {
    service: [SERVICE_MAX + 1]u8 = @as([SERVICE_MAX + 1]u8, @splat(0)),
    user: [USER_MAX + 1]u8 = @as([USER_MAX + 1]u8, @splat(0)),
    password: [PASSWORD_CAP + 1]u8 = @as([PASSWORD_CAP + 1]u8, @splat(0)),
    password_len: usize = 0,
    thread: ?std.Thread = null,
    read_fd: i32 = -1,
    write_fd: i32 = -1,
    result: std.atomic.Value(u8) = std.atomic.Value(u8).init('2'),

    pub fn running(self: *const Worker) bool {
        return self.thread != null;
    }

    /// The fd to watch while running; -1 when idle.
    pub fn fd(self: *const Worker) i32 {
        return self.read_fd;
    }

    /// Copies the credentials and starts the thread. False (and nothing
    /// kept) when a value is out of range or the thread can't start.
    pub fn start(self: *Worker, service: []const u8, user: []const u8, password: []const u8) bool {
        if (self.thread != null) return false;
        if (service.len == 0 or service.len > SERVICE_MAX) return false;
        if (user.len == 0 or user.len > USER_MAX) return false;
        if (password.len > PASSWORD_CAP) return false;
        @memset(&self.service, 0);
        @memset(&self.user, 0);
        self.wipe();
        @memcpy(self.service[0..service.len], service);
        @memcpy(self.user[0..user.len], user);
        @memcpy(self.password[0..password.len], password);
        self.password_len = password.len;
        self.result.store('2', .release);

        var fds: [2]i32 = .{ -1, -1 };
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) {
            self.wipe();
            return false;
        }
        self.read_fd = fds[0];
        self.write_fd = fds[1];
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.closeFds();
            self.wipe();
            return false;
        };
        return true;
    }

    fn run(self: *Worker) void {
        const service: [*:0]const u8 = @ptrCast(&self.service);
        const user: [*:0]const u8 = @ptrCast(&self.user);
        const r = authenticate(service, user, self.password[0..self.password_len]);
        self.wipe();
        self.result.store(r.byte(), .release);
        const one = [1]u8{r.byte()};
        _ = linux.write(self.write_fd, &one, 1);
    }

    /// Joins the thread and returns its result. Call once the fd is
    /// readable (or on exit, where it blocks until PAM returns).
    pub fn finish(self: *Worker) Result {
        const t = self.thread orelse return .unavailable;
        t.join();
        self.thread = null;
        var one = [1]u8{'2'};
        const n: isize = @bitCast(linux.read(self.read_fd, &one, 1));
        const b = if (n == 1) one[0] else self.result.load(.acquire);
        self.closeFds();
        self.wipe();
        return Result.fromByte(b);
    }

    fn closeFds(self: *Worker) void {
        if (self.read_fd >= 0) _ = linux.close(self.read_fd);
        if (self.write_fd >= 0) _ = linux.close(self.write_fd);
        self.read_fd = -1;
        self.write_fd = -1;
    }

    pub fn wipe(self: *Worker) void {
        std.crypto.secureZero(u8, &self.password);
        self.password_len = 0;
    }
};
