//! Perihelion Settings > System > Updates: everything that can be decided
//! without the network, a display or root. updates_page.zig runs the
//! programs (curl, tar, pkexec) and feeds their output here; every rule
//! that keeps an update safe lives in this file and is unit-tested with
//! made-up data (`zig build test-updater`).
//!
//! The update path, and which function guards each step:
//!
//!   1. Check: GitHub's "latest release" JSON for CipherVLT/perihelion-shell
//!      (apiArgv, parseRelease, Version.order). Drafts and pre-releases are
//!      never offered.
//!   2. Download the release tarball and SHA256SUMS. Only
//!      https://github.com/CipherVLT/perihelion-shell/releases/download/...
//!      URLs are fetched (checkAssetUrl), without following redirects; the
//!      one redirect GitHub answers with is checked by hand and must go to
//!      https://release-assets.githubusercontent.com/ (checkRedirect). curl
//!      runs with --proto =https on both legs.
//!   3. Verify: the tarball's SHA-256 must match its SHA256SUMS line
//!      (parseSha256Sums, digestsEqual).
//!   4. Unpack: `tar -tvzf` is read first, and only regular files and
//!      directories inside the release's top folder, all of them known
//!      names, are allowed (checkTarListing); then tar unpacks into an empty
//!      folder.
//!   5. Manifest: MANIFEST lists every file with its mode and destination;
//!      each line must match the hard-coded ALLOWLIST exactly, and every
//!      required program must be present (parseManifest, checkManifest).
//!      Nothing can land in ~/.config or /etc/pam.d, because nothing in the
//!      allowlist goes there.
//!   6. Try the programs: each compiled binary runs with --version from the
//!      download folder and must print the release's version
//!      (versionOutputOk). One failure (a missing library or symbol) and
//!      nothing is installed.
//!   7. Install: every system file in one `pkexec install -m 0755 -t
//!      /usr/bin ...` (installArgv); home files are written by Settings
//!      itself.
//!   8. Restart the shell (Settings restarts the bar, the dock, the shell
//!      and the app drawer the way its other switches do).

const std = @import("std");

pub const REPO = "CipherVLT/perihelion-shell";
pub const API_URL = "https://api.github.com/repos/" ++ REPO ++ "/releases/latest";
pub const DOWNLOAD_PREFIX = "https://github.com/" ++ REPO ++ "/releases/download/";
pub const REDIRECT_PREFIX = "https://release-assets.githubusercontent.com/";
pub const SUMS_NAME = "SHA256SUMS";
pub const MANIFEST_NAME = "MANIFEST";
pub const ARCH = "x86_64";

// --- versions ------------------------------------------------------------------

/// MAJOR.MINOR.PATCH with an optional "-pre" part ("0.1.0", "v0.2.1",
/// "0.1.0-dev", "0.2.0-rc.1"). Build metadata after "+" is ignored.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    pre: []const u8 = "",

    pub fn parse(text: []const u8) ?Version {
        var t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len > 0 and (t[0] == 'v' or t[0] == 'V')) t = t[1..];
        if (std.mem.indexOfScalar(u8, t, '+')) |plus| t = t[0..plus];
        var pre: []const u8 = "";
        if (std.mem.indexOfScalar(u8, t, '-')) |dash| {
            pre = t[dash + 1 ..];
            t = t[0..dash];
            if (pre.len == 0) return null;
            for (pre) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-')) return null;
        }
        var it = std.mem.splitScalar(u8, t, '.');
        const a = num(it.next()) orelse return null;
        const b = num(it.next()) orelse return null;
        const c = num(it.next()) orelse return null;
        if (it.next() != null) return null;
        return .{ .major = a, .minor = b, .patch = c, .pre = pre };
    }

    fn num(part: ?[]const u8) ?u32 {
        const p = part orelse return null;
        if (p.len == 0 or p.len > 9) return null;
        for (p) |ch| if (!std.ascii.isDigit(ch)) return null;
        return std.fmt.parseInt(u32, p, 10) catch null;
    }

    /// SemVer precedence: a pre-release sorts before its release
    /// (0.1.0-dev < 0.1.0), pre-release parts compare numerically when both
    /// are numbers, otherwise as text, and a shorter list of equal parts
    /// sorts first.
    pub fn order(a: Version, b: Version) std.math.Order {
        inline for (.{ "major", "minor", "patch" }) |f| {
            const o = std.math.order(@field(a, f), @field(b, f));
            if (o != .eq) return o;
        }
        if (a.pre.len == 0 and b.pre.len == 0) return .eq;
        if (a.pre.len == 0) return .gt;
        if (b.pre.len == 0) return .lt;
        var ia = std.mem.splitScalar(u8, a.pre, '.');
        var ib = std.mem.splitScalar(u8, b.pre, '.');
        while (true) {
            const pa = ia.next();
            const pb = ib.next();
            if (pa == null and pb == null) return .eq;
            if (pa == null) return .lt;
            if (pb == null) return .gt;
            const na = std.fmt.parseInt(u64, pa.?, 10) catch null;
            const nb = std.fmt.parseInt(u64, pb.?, 10) catch null;
            const o: std.math.Order = if (na != null and nb != null)
                std.math.order(na.?, nb.?)
            else if (na != null)
                .lt // numeric identifiers sort before text ones
            else if (nb != null)
                .gt
            else
                std.mem.order(u8, pa.?, pb.?);
            if (o != .eq) return o;
        }
    }

    /// Is `latest` worth offering over `installed`?
    pub fn isNewer(latest: Version, installed: Version) bool {
        return order(latest, installed) == .gt;
    }
};

// --- release JSON ----------------------------------------------------------------

pub const MAX_ASSETS = 16;

pub const Asset = struct {
    name: []const u8,
    url: []const u8,
    size: u64,
};

pub const Release = struct {
    tag: []const u8,
    version: Version,
    title: []const u8,
    notes: []const u8,
    published: []const u8,
    assets: [MAX_ASSETS]Asset = undefined,
    n_assets: usize = 0,

    pub fn asset(self: *const Release, name: []const u8) ?Asset {
        for (self.assets[0..self.n_assets]) |a| if (std.mem.eql(u8, a.name, name)) return a;
        return null;
    }
};

pub const ReleaseError = error{ BadJson, NotAnObject, NoTag, BadTag, Draft, PreRelease, OutOfMemory };

/// Parses GitHub's release object. Strings point into `arena`'s copy.
pub fn parseRelease(arena: std.mem.Allocator, json: []const u8) ReleaseError!Release {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.BadJson;
    if (root != .object) return error.NotAnObject;
    const o = root.object;
    if (boolField(o, "draft")) return error.Draft;
    if (boolField(o, "prerelease")) return error.PreRelease;
    const tag = strField(o, "tag_name") orelse return error.NoTag;
    const version = Version.parse(tag) orelse return error.BadTag;
    var r = Release{
        .tag = tag,
        .version = version,
        .title = strField(o, "name") orelse tag,
        .notes = strField(o, "body") orelse "",
        .published = strField(o, "published_at") orelse "",
    };
    if (o.get("assets")) |assets| {
        if (assets == .array) {
            for (assets.array.items) |item| {
                if (r.n_assets == MAX_ASSETS) break;
                if (item != .object) continue;
                const name = strField(item.object, "name") orelse continue;
                const url = strField(item.object, "browser_download_url") orelse continue;
                const size: u64 = if (item.object.get("size")) |s| (if (s == .integer and s.integer >= 0) @intCast(s.integer) else 0) else 0;
                r.assets[r.n_assets] = .{ .name = name, .url = url, .size = size };
                r.n_assets += 1;
            }
        }
    }
    return r;
}

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn boolField(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

/// "perihelion-shell-0.1.0-x86_64.tar.gz" for tag "v0.1.0".
pub fn tarballName(buf: []u8, v: Version) ![]const u8 {
    if (v.pre.len > 0) return std.fmt.bufPrint(buf, "perihelion-shell-{d}.{d}.{d}-{s}-" ++ ARCH ++ ".tar.gz", .{ v.major, v.minor, v.patch, v.pre });
    return std.fmt.bufPrint(buf, "perihelion-shell-{d}.{d}.{d}-" ++ ARCH ++ ".tar.gz", .{ v.major, v.minor, v.patch });
}

/// The folder every file in the tarball sits in: the tarball name without
/// ".tar.gz".
pub fn topDir(tarball: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, tarball, ".tar.gz")) tarball[0 .. tarball.len - 7] else tarball;
}

// --- URLs -------------------------------------------------------------------------

fn safeUrlChars(s: []const u8) bool {
    for (s) |ch| {
        if (ch <= 0x20 or ch >= 0x7f) return false;
        switch (ch) {
            '"', '\'', '\\', '`', '<', '>', '{', '}', '|', '^' => return false,
            else => {},
        }
    }
    return true;
}

/// "https://github.com/<owner>/<repo>/releases/download/" with the host and
/// path exact, and the owner/repo part compared without case: GitHub
/// treats it so, and its API spells it however the repository is named at
/// the moment (it went from perihelion-shell to Perihelion-shell and back).
fn hasDownloadPrefix(url: []const u8) bool {
    const host = "https://github.com/";
    const tail = "/releases/download/";
    if (url.len < DOWNLOAD_PREFIX.len) return false;
    if (!std.mem.startsWith(u8, url, host)) return false;
    if (!std.ascii.eqlIgnoreCase(url[host.len..][0..REPO.len], REPO)) return false;
    return std.mem.eql(u8, url[host.len + REPO.len ..][0..tail.len], tail);
}

/// The only URLs downloaded directly: this repository's release download
/// for exactly this tag and asset name.
pub fn checkAssetUrl(url: []const u8, tag: []const u8, name: []const u8) bool {
    if (!safeUrlChars(url) or !safeUrlChars(tag) or !safeUrlChars(name)) return false;
    if (tag.len == 0 or name.len == 0) return false;
    if (std.mem.indexOfScalar(u8, tag, '/') != null or std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (std.mem.indexOf(u8, tag, "..") != null or std.mem.indexOf(u8, name, "..") != null) return false;
    if (!hasDownloadPrefix(url)) return false;
    const rest = url[DOWNLOAD_PREFIX.len..];
    if (rest.len != tag.len + 1 + name.len) return false;
    return std.mem.startsWith(u8, rest, tag) and rest[tag.len] == '/' and std.mem.eql(u8, rest[tag.len + 1 ..], name);
}

/// The one host a release download may redirect to, checked by hand
/// (curl never follows redirects here): HTTPS, exactly that host, no
/// user info, no port, and a path after it.
pub fn checkRedirect(location: []const u8) bool {
    const loc = std.mem.trim(u8, location, " \t\r\n");
    if (!safeUrlChars(loc)) return false;
    if (!std.mem.startsWith(u8, loc, REDIRECT_PREFIX)) return false;
    // REDIRECT_PREFIX ends with the host's "/", so "@" or ":" can only be in
    // the path; still refuse an empty path.
    return loc.len > REDIRECT_PREFIX.len;
}

/// curl's `-w` answer for a request made without following redirects:
/// "<http code> <redirect url>". Returns the redirect target when the code
/// is a redirect.
pub fn parseRedirectProbe(out: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, out, " \t\r\n");
    const sp = std.mem.indexOfScalar(u8, t, ' ') orelse return null;
    const code = std.fmt.parseInt(u16, t[0..sp], 10) catch return null;
    if (code != 301 and code != 302 and code != 303 and code != 307 and code != 308) return null;
    const loc = std.mem.trim(u8, t[sp + 1 ..], " ");
    return if (loc.len > 0) loc else null;
}

// --- argv (nothing goes through a shell) ----------------------------------------

pub const CURL = "/usr/bin/curl";
const CURL_COMMON = [_][]const u8{ CURL, "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https", "--max-time", "120", "--max-redirs", "0" };

pub fn apiArgv() [CURL_COMMON.len + 6][]const u8 {
    return CURL_COMMON ++ [_][]const u8{ "--fail", "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28", API_URL };
}

/// First leg: ask github.com for the asset without following its redirect;
/// prints "<code> <redirect url>".
pub fn probeArgv(url: []const u8) [CURL_COMMON.len + 5][]const u8 {
    return CURL_COMMON ++ [_][]const u8{ "--output", "/dev/null", "--write-out", "%{http_code} %{redirect_url}", url };
}

/// Second leg: fetch the checked redirect target to `out_path`.
pub fn fetchArgv(url: []const u8, out_path: []const u8) [CURL_COMMON.len + 4][]const u8 {
    return CURL_COMMON ++ [_][]const u8{ "--fail", "--output", out_path, url };
}

pub fn tarListArgv(tarball: []const u8) [4][]const u8 {
    return .{ "/usr/bin/tar", "-tvzf", tarball, "--" };
}

pub fn tarExtractArgv(tarball: []const u8, dest_dir: []const u8) [8][]const u8 {
    return .{ "/usr/bin/tar", "-xzf", tarball, "-C", dest_dir, "--no-same-owner", "--no-same-permissions", "--" };
}

// --- SHA256SUMS ----------------------------------------------------------------------

/// The digest for `name` from `sha256sum` output ("<64 hex>  <name>", or
/// " *<name>" for binary mode). Null when missing, malformed or listed twice.
pub fn parseSha256Sums(text: []const u8, name: []const u8) ?[32]u8 {
    var found: ?[32]u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 66) continue;
        const hex = line[0..64];
        if (line[64] != ' ') continue;
        var fname = line[65..];
        if (fname.len > 0 and (fname[0] == ' ' or fname[0] == '*')) fname = fname[1..];
        if (!std.mem.eql(u8, fname, name)) continue;
        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, hex) catch return null;
        if (found != null) return null; // two lines for one file: refuse
        found = digest;
    }
    return found;
}

/// Constant-time comparison.
pub fn digestsEqual(a: [32]u8, b: [32]u8) bool {
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// --- the allowlist ---------------------------------------------------------------------

pub const Scope = enum { system, home };

pub const Allowed = struct {
    /// Path inside the release folder.
    src: []const u8,
    /// Absolute destination, or "~/..." for the home folder.
    dest: []const u8,
    mode: u16,
    scope: Scope,
    /// A compiled program: must be in every release and passes --version.
    binary: bool = false,
};

/// Every file an update may write, and where. Mirrors what install.sh
/// installs as programs; config files, PAM files and ~/.config are never
/// in it.
pub const ALLOWLIST = [_]Allowed{
    .{ .src = "bin/perihelion-bar", .dest = "/usr/bin/perihelion-bar", .mode = 0o755, .scope = .system, .binary = true },
    .{ .src = "bin/perihelion-settings", .dest = "/usr/bin/perihelion-settings", .mode = 0o755, .scope = .system, .binary = true },
    .{ .src = "bin/perihelionbar-welcome", .dest = "/usr/bin/perihelionbar-welcome", .mode = 0o755, .scope = .system, .binary = true },
    .{ .src = "bin/perihelion-shell", .dest = "/usr/bin/perihelion-shell", .mode = 0o755, .scope = .system, .binary = true },
    .{ .src = "bin/perihelion-lockscreen", .dest = "/usr/bin/perihelion-lockscreen", .mode = 0o755, .scope = .system, .binary = true },
    .{ .src = "bin/perihelion-lock", .dest = "/usr/bin/perihelion-lock", .mode = 0o755, .scope = .system },
    .{ .src = "bin/perihelion-bar-start", .dest = "/usr/bin/perihelion-bar-start", .mode = 0o755, .scope = .system },
    .{ .src = "bin/appdrawer", .dest = "/usr/bin/appdrawer", .mode = 0o755, .scope = .system },
    .{ .src = "bin/perihelionbar-matugen", .dest = "/usr/bin/perihelionbar-matugen", .mode = 0o755, .scope = .system },
    .{ .src = "bin/perihelion-trash", .dest = "/usr/bin/perihelion-trash", .mode = 0o755, .scope = .system },
    .{ .src = "bin/perihelion-dock-pin", .dest = "/usr/bin/perihelion-dock-pin", .mode = 0o755, .scope = .system },
    .{ .src = "bin/perihelion-theme", .dest = "/usr/bin/perihelion-theme", .mode = 0o755, .scope = .system },
    .{ .src = "bin/perihelionbar-wallpaper", .dest = "/usr/bin/perihelionbar-wallpaper", .mode = 0o755, .scope = .system },
    .{ .src = "bin/perihelionbar-restore-wallpaper", .dest = "/usr/bin/perihelionbar-restore-wallpaper", .mode = 0o755, .scope = .system },
    .{ .src = "appdrawer/AppModel.qml", .dest = "~/.local/share/perihelionbar/appdrawer/AppModel.qml", .mode = 0o644, .scope = .home },
    .{ .src = "appdrawer/AppTile.qml", .dest = "~/.local/share/perihelionbar/appdrawer/AppTile.qml", .mode = 0o644, .scope = .home },
    .{ .src = "appdrawer/BluetoothDeviceRow.qml", .dest = "~/.local/share/perihelionbar/appdrawer/BluetoothDeviceRow.qml", .mode = 0o644, .scope = .home },
    .{ .src = "appdrawer/BluetoothPanel.qml", .dest = "~/.local/share/perihelionbar/appdrawer/BluetoothPanel.qml", .mode = 0o644, .scope = .home },
    .{ .src = "appdrawer/Distro.qml", .dest = "~/.local/share/perihelionbar/appdrawer/Distro.qml", .mode = 0o644, .scope = .home },
    .{ .src = "appdrawer/Drawer.qml", .dest = "~/.local/share/perihelionbar/appdrawer/Drawer.qml", .mode = 0o644, .scope = .home },
    .{ .src = "appdrawer/Icons.qml", .dest = "~/.local/share/perihelionbar/appdrawer/Icons.qml", .mode = 0o644, .scope = .home },
    .{ .src = "appdrawer/ScrollIndicator.qml", .dest = "~/.local/share/perihelionbar/appdrawer/ScrollIndicator.qml", .mode = 0o644, .scope = .home },
    .{ .src = "appdrawer/SmoothWheel.qml", .dest = "~/.local/share/perihelionbar/appdrawer/SmoothWheel.qml", .mode = 0o644, .scope = .home },
    .{ .src = "appdrawer/Theme.qml", .dest = "~/.local/share/perihelionbar/appdrawer/Theme.qml", .mode = 0o644, .scope = .home },
    .{ .src = "appdrawer/WallhavenSearch.qml", .dest = "~/.local/share/perihelionbar/appdrawer/WallhavenSearch.qml", .mode = 0o644, .scope = .home },
    .{ .src = "appdrawer/WallpaperModel.qml", .dest = "~/.local/share/perihelionbar/appdrawer/WallpaperModel.qml", .mode = 0o644, .scope = .home },
    .{ .src = "appdrawer/WallpaperTile.qml", .dest = "~/.local/share/perihelionbar/appdrawer/WallpaperTile.qml", .mode = 0o644, .scope = .home },
    .{ .src = "appdrawer/shell.qml", .dest = "~/.local/share/perihelionbar/appdrawer/shell.qml", .mode = 0o644, .scope = .home },
};

pub fn findAllowed(src: []const u8) ?*const Allowed {
    for (&ALLOWLIST) |*a| if (std.mem.eql(u8, a.src, src)) return a;
    return null;
}

// --- MANIFEST ----------------------------------------------------------------------------

/// One MANIFEST line: "<octal mode> <src> <dest>". Blank lines and lines
/// starting with "#" are skipped.
pub const Entry = struct {
    mode: u16,
    src: []const u8,
    dest: []const u8,
};

pub const MAX_ENTRIES = ALLOWLIST.len;

pub const Manifest = struct {
    entries: [MAX_ENTRIES]Entry = undefined,
    n: usize = 0,

    pub fn slice(self: *const Manifest) []const Entry {
        return self.entries[0..self.n];
    }
};

pub const ManifestError = error{ BadLine, BadMode, TooManyEntries, Empty };

pub fn parseManifest(text: []const u8) ManifestError!Manifest {
    var m = Manifest{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const mode_s = f.next() orelse return error.BadLine;
        const src = f.next() orelse return error.BadLine;
        const dest = f.next() orelse return error.BadLine;
        if (f.next() != null) return error.BadLine;
        const mode = std.fmt.parseInt(u16, mode_s, 8) catch return error.BadMode;
        if (m.n == MAX_ENTRIES) return error.TooManyEntries;
        m.entries[m.n] = .{ .mode = mode, .src = src, .dest = dest };
        m.n += 1;
    }
    if (m.n == 0) return error.Empty;
    return m;
}

pub const ManifestProblem = union(enum) {
    ok,
    /// A file the allowlist doesn't know.
    unknown: []const u8,
    /// A known file with another destination or mode.
    mismatch: []const u8,
    duplicate: []const u8,
    /// A required program is missing.
    missing: []const u8,
};

/// Every line must match an allowlist entry exactly (source, destination,
/// mode), no file twice, and every compiled program present.
pub fn checkManifest(m: *const Manifest) ManifestProblem {
    for (m.slice(), 0..) |e, i| {
        const a = findAllowed(e.src) orelse return .{ .unknown = e.src };
        if (!std.mem.eql(u8, a.dest, e.dest) or a.mode != e.mode) return .{ .mismatch = e.src };
        for (m.slice()[0..i]) |prev| if (std.mem.eql(u8, prev.src, e.src)) return .{ .duplicate = e.src };
    }
    for (ALLOWLIST) |a| {
        if (!a.binary) continue;
        const present = for (m.slice()) |e| {
            if (std.mem.eql(u8, e.src, a.src)) break true;
        } else false;
        if (!present) return .{ .missing = a.src };
    }
    return .ok;
}

pub fn describe(buf: []u8, p: ManifestProblem) []const u8 {
    return switch (p) {
        .ok => "The manifest is fine.",
        .unknown => |s| std.fmt.bufPrint(buf, "The release lists a file the updater does not know: {s}.", .{s}) catch "The release lists an unknown file.",
        .mismatch => |s| std.fmt.bufPrint(buf, "The release puts {s} somewhere it does not belong.", .{s}) catch "The release has a wrong destination.",
        .duplicate => |s| std.fmt.bufPrint(buf, "The release lists {s} twice.", .{s}) catch "The release lists a file twice.",
        .missing => |s| std.fmt.bufPrint(buf, "The release is missing {s}.", .{s}) catch "The release is missing a program.",
    };
}

// --- the tarball's listing ---------------------------------------------------------------

pub const ListingProblem = union(enum) {
    ok,
    /// A symlink, device, hard link or anything but a file or folder.
    not_regular: []const u8,
    /// A name outside the top folder, absolute, or with "..".
    outside: []const u8,
    /// A file that is neither MANIFEST nor in the allowlist.
    unknown: []const u8,
    empty,
};

/// Reads `tar -tvzf` output (GNU tar: "<mode> <owner> <size> <date> <time>
/// <name>"). Every entry must be a regular file or a folder inside `top`;
/// every file must be MANIFEST or an allowlisted source.
pub fn checkTarListing(listing: []const u8, top: []const u8) ListingProblem {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const mode = f.next() orelse return .{ .not_regular = line };
        _ = f.next() orelse return .{ .not_regular = line }; // owner/group
        _ = f.next() orelse return .{ .not_regular = line }; // size
        _ = f.next() orelse return .{ .not_regular = line }; // date
        _ = f.next() orelse return .{ .not_regular = line }; // time
        const name = f.rest();
        if (name.len == 0) return .{ .not_regular = line };
        if (mode[0] != '-' and mode[0] != 'd') return .{ .not_regular = name };
        // One token only: a name with spaces (or " -> target") is refused.
        if (std.mem.indexOfAny(u8, name, " \t") != null) return .{ .not_regular = name };
        if (name[0] == '/' or std.mem.indexOf(u8, name, "..") != null) return .{ .outside = name };
        if (!std.mem.startsWith(u8, name, top)) return .{ .outside = name };
        var rest = name[top.len..];
        if (rest.len > 0 and rest[0] != '/') return .{ .outside = name };
        if (rest.len > 0) rest = rest[1..];
        n += 1;
        if (mode[0] == 'd') {
            const dir = std.mem.trimEnd(u8, rest, "/");
            if (dir.len == 0 or std.mem.eql(u8, dir, "bin") or std.mem.eql(u8, dir, "appdrawer")) continue;
            return .{ .unknown = name };
        }
        if (std.mem.eql(u8, rest, MANIFEST_NAME)) continue;
        if (findAllowed(rest) == null) return .{ .unknown = name };
    }
    return if (n == 0) .empty else .ok;
}

// --- trying the programs ------------------------------------------------------------------

/// `<program> --version` must exit 0 and name the release's version.
pub fn versionOutputOk(out: []const u8, exited_ok: bool, want: Version) bool {
    if (!exited_ok) return false;
    var it = std.mem.tokenizeAny(u8, out, " \t\r\n()");
    while (it.next()) |tok| {
        const v = Version.parse(tok) orelse continue;
        if (v.order(want) == .eq and std.mem.eql(u8, v.pre, want.pre)) return true;
    }
    return false;
}

/// What a program prints for --version: "<name> <version> (<commit>)".
pub fn versionLine(buf: []u8, name: []const u8, version: []const u8, commit: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} ({s})\n", .{ name, version, commit }) catch "?\n";
}

// --- installing ----------------------------------------------------------------------------

pub const PKEXEC = "/usr/bin/pkexec";
pub const INSTALL = "/usr/bin/install";

/// One pkexec call for every system file: they all go to /usr/bin with
/// mode 0755 (the allowlist has no other system destination), so
/// `install -m 0755 -t /usr/bin <files>` covers them. `staged` are the
/// files' paths in the unpacked release, in manifest order. Returns the
/// number of argv slots used.
pub fn installArgv(out: [][]const u8, staged: []const []const u8) ?usize {
    const head = [_][]const u8{ PKEXEC, INSTALL, "-m", "0755", "-t", "/usr/bin", "--" };
    if (staged.len == 0 or out.len < head.len + staged.len) return null;
    @memcpy(out[0..head.len], &head);
    for (staged, 0..) |s, i| {
        // install -t keeps the basename; it must be the destination's.
        if (findAllowedByBasename(std.fs.path.basename(s))) |a| {
            if (a.scope != .system) return null;
        } else return null;
        out[head.len + i] = s;
    }
    return head.len + staged.len;
}

fn findAllowedByBasename(base: []const u8) ?*const Allowed {
    for (&ALLOWLIST) |*a| {
        if (a.scope == .system and std.mem.eql(u8, std.fs.path.basename(a.dest), base)) return a;
    }
    return null;
}

/// "~/x" -> "<home>/x". Null for anything else.
pub fn homePath(buf: []u8, home: []const u8, dest: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, dest, "~/")) return null;
    if (home.len == 0 or home[0] != '/') return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ std.mem.trimEnd(u8, home, "/"), dest[2..] }) catch null;
}

// --- how this copy was installed --------------------------------------------------------

pub const Method = enum {
    iso,
    install_sh,
    release,
    unknown,

    pub fn label(self: Method) []const u8 {
        return switch (self) {
            .iso => "Perihelion Linux (image)",
            .install_sh => "install.sh",
            .release => "Release update",
            .unknown => "Built from source",
        };
    }

    /// Perihelion Linux updates the shell with the system image.
    pub fn canInstall(self: Method) bool {
        return self != .iso;
    }
};

/// `iso_ref` = /usr/share/perihelion/perihelionbar.ref exists; `marker` =
/// ~/.local/state/perihelionbar/install-method ("install.sh <commit>" or
/// "release <tag>"), null when missing.
pub fn detectMethod(iso_ref: bool, marker: ?[]const u8) Method {
    if (iso_ref) return .iso;
    const m = std.mem.trim(u8, marker orelse return .unknown, " \t\r\n");
    if (std.mem.startsWith(u8, m, "release")) return .release;
    if (std.mem.startsWith(u8, m, "install.sh")) return .install_sh;
    return .unknown;
}

// --- auto-check ---------------------------------------------------------------------------

pub const DEFAULT_INTERVAL_H: u32 = 6;
pub const MIN_INTERVAL_H: u32 = 1;
pub const MAX_INTERVAL_H: u32 = 168;

pub fn clampInterval(h: u32) u32 {
    return std.math.clamp(h, MIN_INTERVAL_H, MAX_INTERVAL_H);
}

/// Is an automatic check due? `last` = epoch seconds of the last check (0 =
/// never); a clock that went backwards counts as due.
pub fn checkDue(enabled: bool, interval_h: u32, last: i64, now: i64) bool {
    if (!enabled) return false;
    if (last <= 0 or now < last) return true;
    return now - last >= @as(i64, clampInterval(interval_h)) * 3600;
}

/// ~/.local/state/perihelionbar/updates: "key=value" lines.
pub const Saved = struct {
    last_checked: i64 = 0,
    latest_tag: []const u8 = "",
    notified_tag: []const u8 = "",

    pub fn parse(text: []const u8) Saved {
        var s = Saved{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = line[0..eq];
            const v = line[eq + 1 ..];
            if (std.mem.eql(u8, k, "last_checked")) s.last_checked = std.fmt.parseInt(i64, v, 10) catch 0;
            if (std.mem.eql(u8, k, "latest_tag")) s.latest_tag = if (Version.parse(v) != null) v else "";
            if (std.mem.eql(u8, k, "notified_tag")) s.notified_tag = if (Version.parse(v) != null) v else "";
        }
        return s;
    }

    pub fn format(self: Saved, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "last_checked={d}\nlatest_tag={s}\nnotified_tag={s}\n", .{ self.last_checked, self.latest_tag, self.notified_tag });
    }
};

/// "3 hours ago" style text for the Last checked row.
pub fn agoText(buf: []u8, last: i64, now: i64) []const u8 {
    if (last <= 0) return "Never";
    const d = now - last;
    if (d < 0) return "Just now";
    if (d < 60) return "Just now";
    if (d < 3600) return std.fmt.bufPrint(buf, "{d} min ago", .{@divTrunc(d, 60)}) catch "?";
    if (d < 86400) {
        const h = @divTrunc(d, 3600);
        return std.fmt.bufPrint(buf, "{d} hour{s} ago", .{ h, if (h == 1) "" else "s" }) catch "?";
    }
    const days = @divTrunc(d, 86400);
    return std.fmt.bufPrint(buf, "{d} day{s} ago", .{ days, if (days == 1) "" else "s" }) catch "?";
}

// --- the page's buttons --------------------------------------------------------------------

pub const Phase = enum {
    idle,
    checking,
    up_to_date,
    available,
    downloading,
    /// Downloaded, verified, unpacked, manifest checked, programs tried.
    ready,
    installing,
    /// Installed; the running shell is still the old one.
    installed,
    restarting,
    failed,
};

pub const Buttons = struct {
    check: bool,
    download: bool,
    install: bool,
    restart: bool,
};

/// Which buttons are live. `can_install` = the install method allows it
/// (not the Perihelion Linux image); `have_release` = a newer release is
/// known (from this check or a failed step after it).
pub fn buttons(phase: Phase, can_install: bool, have_release: bool) Buttons {
    const busy = switch (phase) {
        .checking, .downloading, .installing, .restarting => true,
        else => false,
    };
    return .{
        .check = !busy,
        .download = can_install and have_release and (phase == .available or phase == .failed),
        .install = can_install and phase == .ready,
        .restart = phase == .installed,
    };
}

pub fn statusText(phase: Phase) []const u8 {
    return switch (phase) {
        .idle => "Not checked yet.",
        .checking => "Checking for updates\u{2026}",
        .up_to_date => "Perihelion Shell is up to date.",
        .available => "An update is available.",
        .downloading => "Downloading and checking the update\u{2026}",
        .ready => "Downloaded and verified. Ready to install.",
        .installing => "Installing\u{2026}",
        .installed => "Installed. Restart the shell to use it.",
        .restarting => "Restarting the shell\u{2026}",
        .failed => "Something went wrong.",
    };
}

// --- tests -----------------------------------------------------------------------------------

const tt = std.testing;

fn ver(s: []const u8) Version {
    return Version.parse(s).?;
}

test "Version.parse" {
    try tt.expectEqual(Version{ .major = 0, .minor = 1, .patch = 0 }, ver("v0.1.0"));
    try tt.expectEqual(Version{ .major = 1, .minor = 22, .patch = 333 }, ver("1.22.333"));
    try tt.expectEqualStrings("dev", ver("0.1.0-dev").pre);
    try tt.expectEqualStrings("rc.1", ver("0.2.0-rc.1+abc").pre);
    for ([_][]const u8{ "", "v", "1", "1.2", "1.2.3.4", "1.2.x", "1..3", "1.2.3-", "01234567890.0.0", "1.2.3-a b", "1.2.3-$x" }) |bad| {
        try tt.expect(Version.parse(bad) == null);
    }
}

test "Version.order: releases, -dev and pre-releases" {
    try tt.expect(ver("0.1.0").order(ver("0.0.9")) == .gt);
    try tt.expect(ver("0.2.0").order(ver("0.10.0")) == .lt);
    try tt.expect(ver("1.0.0").order(ver("v1.0.0")) == .eq);
    // -dev sorts before its release, after the one before.
    try tt.expect(ver("0.1.0-dev").order(ver("0.1.0")) == .lt);
    try tt.expect(ver("0.1.0-dev").order(ver("0.0.9")) == .gt);
    try tt.expect(ver("0.1.0").isNewer(ver("0.1.0-dev")));
    try tt.expect(!ver("0.1.0").isNewer(ver("0.1.0")));
    try tt.expect(!ver("0.1.0").isNewer(ver("0.1.1-dev")));
    // SemVer's own example order.
    const chain = [_][]const u8{ "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0" };
    for (chain[0 .. chain.len - 1], chain[1..]) |a, b| try tt.expect(ver(a).order(ver(b)) == .lt);
}

const FAKE_RELEASE =
    \\{"tag_name":"v0.1.0","name":"Perihelion Shell 0.1.0","draft":false,"prerelease":false,
    \\ "published_at":"2026-12-01T10:00:00Z","body":"## Changes\n- Updates page\n- Lock screen",
    \\ "assets":[
    \\  {"name":"perihelion-shell-0.1.0-x86_64.tar.gz","size":4200000,
    \\   "browser_download_url":"https://github.com/CipherVLT/perihelion-shell/releases/download/v0.1.0/perihelion-shell-0.1.0-x86_64.tar.gz"},
    \\  {"name":"SHA256SUMS","size":100,
    \\   "browser_download_url":"https://github.com/CipherVLT/perihelion-shell/releases/download/v0.1.0/SHA256SUMS"},
    \\  {"name":"odd","size":-5,"browser_download_url":"x"},
    \\  {"nope":1}, 7
    \\ ]}
;

test "parseRelease: fake release JSON" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const r = try parseRelease(arena.allocator(), FAKE_RELEASE);
    try tt.expectEqualStrings("v0.1.0", r.tag);
    try tt.expectEqual(ver("0.1.0"), r.version);
    try tt.expectEqualStrings("Perihelion Shell 0.1.0", r.title);
    try tt.expect(std.mem.indexOf(u8, r.notes, "Updates page") != null);
    try tt.expectEqual(@as(usize, 3), r.n_assets);
    try tt.expectEqual(@as(u64, 4200000), r.asset("perihelion-shell-0.1.0-x86_64.tar.gz").?.size);
    try tt.expectEqual(@as(u64, 0), r.asset("odd").?.size);
    try tt.expect(r.asset("missing") == null);
}

test "parseRelease: refusals" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tt.expectError(error.BadJson, parseRelease(a, "{nope"));
    try tt.expectError(error.NotAnObject, parseRelease(a, "[1,2]"));
    try tt.expectError(error.NoTag, parseRelease(a, "{\"name\":\"x\"}"));
    try tt.expectError(error.BadTag, parseRelease(a, "{\"tag_name\":\"latest\"}"));
    try tt.expectError(error.Draft, parseRelease(a, "{\"tag_name\":\"v1.0.0\",\"draft\":true}"));
    try tt.expectError(error.PreRelease, parseRelease(a, "{\"tag_name\":\"v1.0.0\",\"prerelease\":true}"));
    // No assets at all is a valid release (the page then says so).
    const r = try parseRelease(a, "{\"tag_name\":\"v1.0.0\"}");
    try tt.expectEqual(@as(usize, 0), r.n_assets);
    try tt.expectEqualStrings("v1.0.0", r.title);
}

test "tarballName and topDir" {
    var buf: [96]u8 = undefined;
    const n = try tarballName(&buf, ver("v0.1.0"));
    try tt.expectEqualStrings("perihelion-shell-0.1.0-x86_64.tar.gz", n);
    try tt.expectEqualStrings("perihelion-shell-0.1.0-x86_64", topDir(n));
    try tt.expectEqualStrings("perihelion-shell-0.2.0-rc.1-x86_64.tar.gz", try tarballName(&buf, ver("0.2.0-rc.1")));
}

test "checkAssetUrl: the repository name in any case, everything else exact" {
    // GitHub resolves owner/repo in any case and its release JSON spells it
    // as currently named; a rename that only changes case must not make the
    // updater refuse every asset.
    for ([_][]const u8{
        "https://github.com/CipherVLT/perihelion-shell/releases/download/v0.1.0/SHA256SUMS",
        "https://github.com/CipherVLT/Perihelion-shell/releases/download/v0.1.0/SHA256SUMS",
        "https://github.com/ciphervlt/PERIHELION-SHELL/releases/download/v0.1.0/SHA256SUMS",
    }) |good| try tt.expect(checkAssetUrl(good, "v0.1.0", "SHA256SUMS"));
    for ([_][]const u8{
        "https://GITHUB.com/CipherVLT/perihelion-shell/releases/download/v0.1.0/SHA256SUMS",
        "https://github.com/CipherVLT/perihelion-shell/Releases/download/v0.1.0/SHA256SUMS",
        "https://github.com/CipherVLT/perihelion-shellx/releases/download/v0.1.0/SHA256SUMS",
        "https://github.com/CipherVLT/another-project/releases/download/v0.1.0/SHA256SUMS",
        "https://github.com/CipherVLT/perihelion-shel",
    }) |bad| try tt.expect(!checkAssetUrl(bad, "v0.1.0", "SHA256SUMS"));
}

test "checkAssetUrl: only this repo, this tag, this name" {
    const tag = "v0.1.0";
    const name = "SHA256SUMS";
    try tt.expect(checkAssetUrl("https://github.com/CipherVLT/perihelion-shell/releases/download/v0.1.0/SHA256SUMS", tag, name));
    for ([_][]const u8{
        "http://github.com/CipherVLT/perihelion-shell/releases/download/v0.1.0/SHA256SUMS",
        "https://github.com/Other/perihelion-shell/releases/download/v0.1.0/SHA256SUMS",
        "https://github.com/CipherVLT/perihelion-shell/releases/download/v0.2.0/SHA256SUMS",
        "https://github.com/CipherVLT/perihelion-shell/releases/download/v0.1.0/SHA256SUMS.evil",
        "https://github.com/CipherVLT/perihelion-shell/releases/download/v0.1.0/../x/SHA256SUMS",
        "https://github.com.evil.example/CipherVLT/perihelion-shell/releases/download/v0.1.0/SHA256SUMS",
        "https://github.com/CipherVLT/perihelion-shell/releases/download/v0.1.0/SHA256SUMS ",
        "",
    }) |bad| try tt.expect(!checkAssetUrl(bad, tag, name));
    try tt.expect(!checkAssetUrl(DOWNLOAD_PREFIX ++ "../x", "..", "x"));
    try tt.expect(!checkAssetUrl(DOWNLOAD_PREFIX ++ "a/b/c", "a/b", "c"));
}

test "checkRedirect: release-assets.githubusercontent.com over HTTPS only" {
    try tt.expect(checkRedirect("https://release-assets.githubusercontent.com/github-production-release-asset/123/abc?sp=r&sig=x%2By"));
    try tt.expect(checkRedirect("  https://release-assets.githubusercontent.com/x\r\n"));
    for ([_][]const u8{
        "http://release-assets.githubusercontent.com/x",
        "https://release-assets.githubusercontent.com/",
        "https://release-assets.githubusercontent.com.evil.example/x",
        "https://release-assets.githubusercontent.com:8443/x",
        "https://user@release-assets.githubusercontent.com/x",
        "https://objects.githubusercontent.com/x",
        "https://evil.example/https://release-assets.githubusercontent.com/x",
        "https://release-assets.githubusercontent.com/x y",
        "https://release-assets.githubusercontent.com/x\"",
        "",
    }) |bad| try tt.expect(!checkRedirect(bad));
}

test "parseRedirectProbe" {
    try tt.expectEqualStrings("https://release-assets.githubusercontent.com/a", parseRedirectProbe("302 https://release-assets.githubusercontent.com/a").?);
    try tt.expect(parseRedirectProbe("200 ") == null);
    try tt.expect(parseRedirectProbe("404 https://x") == null);
    try tt.expect(parseRedirectProbe("302 ") == null);
    try tt.expect(parseRedirectProbe("garbage") == null);
}

test "argv: curl never follows redirects and is HTTPS-only; no shell anywhere" {
    const api = apiArgv();
    try tt.expectEqualStrings(CURL, api[0]);
    try tt.expectEqualStrings(API_URL, api[api.len - 1]);
    const probe = probeArgv("https://github.com/x");
    const fetch = fetchArgv("https://release-assets.githubusercontent.com/x", "/tmp/a b");
    inline for (.{ api[0..], probe[0..], fetch[0..] }) |argv| {
        var proto = false;
        var redirs0 = false;
        for (argv, 0..) |a, i| {
            try tt.expect(!std.mem.eql(u8, a, "-L") and !std.mem.eql(u8, a, "--location"));
            try tt.expect(!std.mem.eql(u8, a, "/bin/sh") and !std.mem.eql(u8, a, "sh"));
            if (std.mem.eql(u8, a, "--proto")) proto = std.mem.eql(u8, argv[i + 1], "=https");
            if (std.mem.eql(u8, a, "--max-redirs")) redirs0 = std.mem.eql(u8, argv[i + 1], "0");
        }
        try tt.expect(proto and redirs0);
    }
    // The output path is one argument, spaces and all.
    try tt.expectEqualStrings("/tmp/a b", fetch[fetch.len - 2]);
    const x = tarExtractArgv("/d/r.tar.gz", "/d/x");
    try tt.expectEqualStrings("--no-same-owner", x[5]);
}

test "parseSha256Sums" {
    const sums =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  perihelion-shell-0.1.0-x86_64.tar.gz\n" ++
        "0000000000000000000000000000000000000000000000000000000000000001 *other\r\n";
    const d = parseSha256Sums(sums, "perihelion-shell-0.1.0-x86_64.tar.gz").?;
    try tt.expectEqual(@as(u8, 0xe3), d[0]);
    try tt.expectEqual(@as(u8, 0x55), d[31]);
    try tt.expectEqual(@as(u8, 1), parseSha256Sums(sums, "other").?[31]);
    try tt.expect(parseSha256Sums(sums, "perihelion-shell") == null);
    try tt.expect(parseSha256Sums("zz" ++ sums[2..], "perihelion-shell-0.1.0-x86_64.tar.gz") == null);
    try tt.expect(parseSha256Sums(sums ++ sums, "other") == null); // listed twice
    try tt.expect(parseSha256Sums("", "x") == null);
    // The digest of the empty input, checked against std's SHA-256.
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &h, .{});
    try tt.expect(digestsEqual(h, d));
    h[3] ^= 1;
    try tt.expect(!digestsEqual(h, d));
}

fn goodManifest(buf: []u8) []const u8 {
    var n: usize = 0;
    for (ALLOWLIST) |a| {
        const line = std.fmt.bufPrint(buf[n..], "{o} {s} {s}\n", .{ a.mode, a.src, a.dest }) catch unreachable;
        n += line.len;
    }
    return buf[0..n];
}

test "manifest: the full allowlist passes" {
    var buf: [8192]u8 = undefined;
    const m = try parseManifest(goodManifest(&buf));
    try tt.expectEqual(ALLOWLIST.len, m.n);
    try tt.expect(checkManifest(&m) == .ok);
}

test "manifest: refusals" {
    try tt.expectError(error.Empty, parseManifest("# nothing\n\n"));
    try tt.expectError(error.BadLine, parseManifest("755 bin/perihelion-bar\n"));
    try tt.expectError(error.BadLine, parseManifest("755 a b c\n"));
    try tt.expectError(error.BadMode, parseManifest("rwx bin/perihelion-bar /usr/bin/perihelion-bar\n"));
    const cases = [_]struct { text: []const u8, want: std.meta.Tag(ManifestProblem) }{
        .{ .text = "755 bin/evil /usr/bin/evil\n", .want = .unknown },
        .{ .text = "755 bin/perihelion-bar /usr/local/bin/perihelion-bar\n", .want = .mismatch },
        .{ .text = "4755 bin/perihelion-bar /usr/bin/perihelion-bar\n", .want = .mismatch },
        .{ .text = "644 appdrawer/shell.qml ~/.config/quickshell/appdrawer/shell.qml\n", .want = .mismatch },
        .{ .text = "644 bin/perihelion-lock /etc/pam.d/perihelion-lock\n", .want = .mismatch },
        .{ .text = "755 bin/perihelion-bar /usr/bin/perihelion-bar\n755 bin/perihelion-bar /usr/bin/perihelion-bar\n", .want = .duplicate },
        .{ .text = "755 bin/perihelion-bar /usr/bin/perihelion-bar\n", .want = .missing },
    };
    for (cases) |c| {
        const m = try parseManifest(c.text);
        try tt.expectEqual(c.want, std.meta.activeTag(checkManifest(&m)));
    }
    var dbuf: [200]u8 = undefined;
    try tt.expect(std.mem.indexOf(u8, describe(&dbuf, .{ .unknown = "bin/evil" }), "bin/evil") != null);
}

test "allowlist: nothing in ~/.config or /etc, system files all /usr/bin 0755" {
    for (ALLOWLIST) |a| {
        try tt.expect(std.mem.indexOf(u8, a.dest, ".config") == null);
        try tt.expect(!std.mem.startsWith(u8, a.dest, "/etc"));
        try tt.expect(std.mem.indexOf(u8, a.dest, "..") == null);
        switch (a.scope) {
            .system => {
                try tt.expect(std.mem.startsWith(u8, a.dest, "/usr/bin/"));
                try tt.expectEqual(@as(u16, 0o755), a.mode);
                try tt.expectEqualStrings(std.fs.path.basename(a.src), std.fs.path.basename(a.dest));
            },
            .home => try tt.expect(std.mem.startsWith(u8, a.dest, "~/.local/share/perihelionbar/")),
        }
    }
}

test "checkTarListing" {
    const top = "perihelion-shell-0.1.0-x86_64";
    const good =
        "drwxr-xr-x ci/ci 0 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64/\n" ++
        "-rw-r--r-- ci/ci 900 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64/MANIFEST\n" ++
        "drwxr-xr-x ci/ci 0 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64/bin/\n" ++
        "-rwxr-xr-x ci/ci 2000000 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64/bin/perihelion-bar\n" ++
        "drwxr-xr-x ci/ci 0 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64/appdrawer/\n" ++
        "-rw-r--r-- ci/ci 3000 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64/appdrawer/shell.qml\n";
    try tt.expect(checkTarListing(good, top) == .ok);
    try tt.expect(checkTarListing("", top) == .empty);
    const cases = [_]struct { line: []const u8, want: std.meta.Tag(ListingProblem) }{
        .{ .line = "lrwxrwxrwx ci/ci 0 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64/bin/perihelion-bar -> /etc/passwd", .want = .not_regular },
        .{ .line = "hrw-r--r-- ci/ci 0 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64/bin/perihelion-bar link to x", .want = .not_regular },
        .{ .line = "crw-r--r-- ci/ci 1,3 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64/bin/null", .want = .not_regular },
        .{ .line = "-rw-r--r-- ci/ci 1 2026-12-01 10:00 /etc/passwd", .want = .outside },
        .{ .line = "-rw-r--r-- ci/ci 1 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64/../x", .want = .outside },
        .{ .line = "-rw-r--r-- ci/ci 1 2026-12-01 10:00 other/bin/perihelion-bar", .want = .outside },
        .{ .line = "-rw-r--r-- ci/ci 1 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64x/bin/perihelion-bar", .want = .outside },
        .{ .line = "-rw-r--r-- ci/ci 1 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64/bin/evil", .want = .unknown },
        .{ .line = "drwxr-xr-x ci/ci 0 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64/etc/", .want = .unknown },
        .{ .line = "-rw-r--r-- ci/ci 1 2026-12-01 10:00 perihelion-shell-0.1.0-x86_64/bin/a b", .want = .not_regular },
    };
    for (cases) |c| try tt.expectEqual(c.want, std.meta.activeTag(checkTarListing(c.line, top)));
}

test "versionOutputOk" {
    var buf: [80]u8 = undefined;
    const line = versionLine(&buf, "perihelion-bar", "0.1.0", "abc1234");
    try tt.expectEqualStrings("perihelion-bar 0.1.0 (abc1234)\n", line);
    try tt.expect(versionOutputOk(line, true, ver("v0.1.0")));
    try tt.expect(!versionOutputOk(line, false, ver("0.1.0")));
    try tt.expect(!versionOutputOk("perihelion-bar 0.1.0-dev (x)", true, ver("0.1.0")));
    try tt.expect(!versionOutputOk("perihelion-bar: error while loading shared libraries: libfoo.so.1", true, ver("0.1.0")));
    try tt.expect(!versionOutputOk("", true, ver("0.1.0")));
}

test "installArgv: one pkexec install for the system files, nothing else" {
    var out: [32][]const u8 = undefined;
    const staged = [_][]const u8{ "/s/x/bin/perihelion-bar", "/s/x/bin/perihelion-lock" };
    const n = installArgv(&out, &staged).?;
    try tt.expectEqual(@as(usize, 9), n);
    try tt.expectEqualStrings(PKEXEC, out[0]);
    try tt.expectEqualStrings(INSTALL, out[1]);
    try tt.expectEqualStrings("/usr/bin", out[5]);
    try tt.expectEqualStrings("--", out[6]);
    try tt.expectEqualStrings("/s/x/bin/perihelion-lock", out[8]);
    try tt.expect(installArgv(&out, &.{"/s/x/bin/evil"}) == null);
    try tt.expect(installArgv(&out, &.{"/s/x/appdrawer/shell.qml"}) == null);
    try tt.expect(installArgv(&out, &.{}) == null);
    try tt.expect(installArgv(out[0..3], &staged) == null);
}

test "homePath" {
    var buf: [128]u8 = undefined;
    try tt.expectEqualStrings("/home/u/.local/share/perihelionbar/appdrawer/shell.qml", homePath(&buf, "/home/u/", "~/.local/share/perihelionbar/appdrawer/shell.qml").?);
    try tt.expect(homePath(&buf, "/home/u", "/usr/bin/x") == null);
    try tt.expect(homePath(&buf, "", "~/x") == null);
    try tt.expect(homePath(&buf, "relative", "~/x") == null);
}

test "detectMethod" {
    try tt.expectEqual(Method.iso, detectMethod(true, "release v0.1.0"));
    try tt.expectEqual(Method.release, detectMethod(false, "release v0.1.0\n"));
    try tt.expectEqual(Method.install_sh, detectMethod(false, "install.sh abc1234"));
    try tt.expectEqual(Method.unknown, detectMethod(false, null));
    try tt.expectEqual(Method.unknown, detectMethod(false, "something"));
    try tt.expect(!Method.iso.canInstall());
    try tt.expect(Method.install_sh.canInstall());
}

test "checkDue and the interval" {
    try tt.expect(!checkDue(false, 6, 0, 1000));
    try tt.expect(checkDue(true, 6, 0, 1000));
    try tt.expect(!checkDue(true, 6, 1000, 1000 + 6 * 3600 - 1));
    try tt.expect(checkDue(true, 6, 1000, 1000 + 6 * 3600));
    try tt.expect(checkDue(true, 6, 5000, 100)); // clock went backwards
    try tt.expect(checkDue(true, 0, 1000, 1000 + 3600)); // clamped to 1 h
    try tt.expectEqual(@as(u32, 168), clampInterval(9999));
}

test "Saved round-trip and bad values" {
    var buf: [128]u8 = undefined;
    const s = Saved{ .last_checked = 1790000000, .latest_tag = "v0.1.0", .notified_tag = "v0.1.0" };
    const back = Saved.parse(try s.format(&buf));
    try tt.expectEqual(s.last_checked, back.last_checked);
    try tt.expectEqualStrings("v0.1.0", back.latest_tag);
    const bad = Saved.parse("last_checked=x\nlatest_tag=../../etc\nnope\n");
    try tt.expectEqual(@as(i64, 0), bad.last_checked);
    try tt.expectEqualStrings("", bad.latest_tag);
}

test "agoText" {
    var buf: [32]u8 = undefined;
    try tt.expectEqualStrings("Never", agoText(&buf, 0, 100));
    try tt.expectEqualStrings("Just now", agoText(&buf, 100, 130));
    try tt.expectEqualStrings("5 min ago", agoText(&buf, 100, 400));
    try tt.expectEqualStrings("1 hour ago", agoText(&buf, 0 + 1, 3601 + 1));
    try tt.expectEqualStrings("3 days ago", agoText(&buf, 1, 1 + 3 * 86400));
}

test "buttons: each only when it makes sense" {
    // Nothing known yet: only Check.
    try tt.expectEqual(Buttons{ .check = true, .download = false, .install = false, .restart = false }, buttons(.idle, true, false));
    // Busy: nothing at all.
    for ([_]Phase{ .checking, .downloading, .installing, .restarting }) |p| {
        try tt.expectEqual(Buttons{ .check = false, .download = false, .install = false, .restart = false }, buttons(p, true, true));
    }
    try tt.expectEqual(Buttons{ .check = true, .download = true, .install = false, .restart = false }, buttons(.available, true, true));
    try tt.expectEqual(Buttons{ .check = true, .download = false, .install = true, .restart = false }, buttons(.ready, true, true));
    try tt.expectEqual(Buttons{ .check = true, .download = false, .install = false, .restart = true }, buttons(.installed, true, true));
    try tt.expectEqual(Buttons{ .check = true, .download = false, .install = false, .restart = false }, buttons(.up_to_date, true, false));
    // A failed download can be retried; a failed check with nothing known can't download.
    try tt.expect(buttons(.failed, true, true).download);
    try tt.expect(!buttons(.failed, true, false).download);
    // Perihelion Linux image: check and read notes, never download or install.
    try tt.expectEqual(Buttons{ .check = true, .download = false, .install = false, .restart = false }, buttons(.available, false, true));
    try tt.expect(!buttons(.ready, false, true).install);
}

test "every phase has a status line" {
    for (std.meta.tags(Phase)) |p| try tt.expect(statusText(p).len > 0);
}
