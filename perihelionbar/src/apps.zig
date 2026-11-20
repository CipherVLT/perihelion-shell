//! Apps: what a pinned launcher is and which running window belongs to it.
//! Shared by the bar and dock (src/main.zig) and the shell's Glance Apps
//! tab, so both answer "is this pin running?" and "which icon does it wear?"
//! the same way. Moved here unchanged from main.zig (as volume.zig was);
//! main.zig's tests still cover it through aliases.
//!
//! Pure: no sockets, no processes, no file reads. The desktop icon index
//! is filled by its host (the bar from enumerateInstalledApps at startup,
//! Glance when its Apps tab is shown), and pinIconName asks the host about
//! PATH, the icon theme and the Welcome app's choice files through `Probe`.

const std = @import("std");

/// The system questions pinIconName needs answered.
pub const Probe = struct {
    /// `binary` runs from PATH.
    on_path: *const fn (binary: []const u8) bool,
    /// The icon theme has an icon by this name.
    icon_resolves: *const fn (icon: []const u8) bool,
    /// ~/.config/perihelionbar/<file>, trimmed ("" when unset).
    choice: *const fn (file: []const u8, buf: []u8) []const u8,
};

/// Lowercases `src` into `dst`, returning the bytes written (truncated at
/// `dst.len` — appids/titles longer than the taskbar's fixed fields lose
/// their tail, which only costs a match in pathological cases).
pub fn lowerCopy(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    for (src[0..n], 0..) |c, i| dst[i] = std.ascii.toLower(c);
    return n;
}

pub fn parseIdAt(text: []const u8, start_pos: usize) ?i32 {
    var i = start_pos;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    const start = i;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(i32, text[start..i], 10) catch null;
}

/// Splits a top-level JSON array (`[...]`), bare or behind a wrapper object
/// (`{"clients":[...]}`), into its `{...}` element objects. Only `[`/`]
/// move the depth counter; the element scan itself is brace-balanced and
/// string-aware, so nested objects (Hyprland's per-client `"workspace"`),
/// arrays (Mango's `"tags"`), and braces/quotes inside titles can't end an
/// element early.
pub const TopLevelObjects = struct {
    text: []const u8,
    pos: usize,
    /// Array depth at `pos` — kept across next() calls, since the opening
    /// `[` is only scanned once (before the first element).
    arr_depth: usize = 0,

    pub fn next(self: *TopLevelObjects) ?[]const u8 {
        var i = self.pos;
        var in_str = false;
        var esc = false;
        while (i < self.text.len) : (i += 1) {
            const c = self.text[i];
            if (in_str) {
                if (esc) {
                    esc = false;
                } else if (c == '\\') {
                    esc = true;
                } else if (c == '"') {
                    in_str = false;
                }
                continue;
            }
            switch (c) {
                '"' => in_str = true,
                '[' => self.arr_depth += 1,
                ']' => self.arr_depth -|= 1,
                '{' => {
                    if (self.arr_depth != 1) continue;
                    // Element start: scan to its matching close.
                    const start = i;
                    var edepth: usize = 1;
                    var j = i + 1;
                    var sstr = false;
                    var sesc = false;
                    while (j < self.text.len) : (j += 1) {
                        const d = self.text[j];
                        if (sstr) {
                            if (sesc) {
                                sesc = false;
                            } else if (d == '\\') {
                                sesc = true;
                            } else if (d == '"') {
                                sstr = false;
                            }
                            continue;
                        }
                        if (d == '"') {
                            sstr = true;
                        } else if (d == '{' or d == '[') {
                            edepth += 1;
                        } else if (d == '}' or d == ']') {
                            edepth -= 1;
                            if (edepth == 0) {
                                self.pos = j + 1;
                                return self.text[start .. j + 1];
                            }
                        }
                    }
                    return null; // unterminated tail; stop
                },
                else => {},
            }
        }
        return null;
    }
};

pub fn topLevelObjects(array_json: []const u8) TopLevelObjects {
    return .{ .text = array_json, .pos = 0 };
}

/// Reads `"key":"value"` from a flat JSON object substring (no unescaping —
/// appids/addresses never carry escapes; titles may, and only lose an exact
/// fallback match when they do). Returns null when the key is absent.
pub fn extractJsonString(obj: []const u8, key: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, obj, search, key)) |pos| {
        var i = pos + key.len;
        while (i < obj.len and (obj[i] == ' ' or obj[i] == ':')) : (i += 1) {}
        if (i < obj.len and obj[i] == '"') {
            const start = i + 1;
            var j = start;
            var esc = false;
            while (j < obj.len) : (j += 1) {
                const c = obj[j];
                if (esc) {
                    esc = false;
                } else if (c == '\\') {
                    esc = true;
                } else if (c == '"') {
                    return obj[start..j];
                }
            }
            return null;
        }
        search = i;
    }
    return null;
}

/// Reads `"key":123` (signed) from a flat JSON object substring.
pub fn extractJsonInt(obj: []const u8, key: []const u8) ?i32 {
    const pos = std.mem.indexOf(u8, obj, key) orelse return null;
    var i = pos + key.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == ':')) : (i += 1) {}
    return parseIdAt(obj, i);
}

/// Reads the first id in Mango's `"tags":[1, ...]` array (the tag a window
/// is on). Null for missing/empty arrays (sticky or global windows).
pub fn extractFirstTagId(obj: []const u8) ?i32 {
    const pos = std.mem.indexOf(u8, obj, "\"tags\"") orelse return null;
    const open = std.mem.indexOfPos(u8, obj, pos, "[") orelse return null;
    return parseIdAt(obj, open + 1);
}

/// Reads Hyprland's nested `"workspace":{"id":N, ...}` id. Scoped to the
/// workspace object so a same-named key elsewhere in the client can't win.
pub fn extractWorkspaceId(obj: []const u8) ?i32 {
    const wpos = std.mem.indexOf(u8, obj, "\"workspace\"") orelse return null;
    const open = std.mem.indexOfPos(u8, obj, wpos, "{") orelse return null;
    const close = std.mem.indexOfPos(u8, obj, open, "}") orelse obj.len;
    const seg = obj[open..close];
    const ipos = std.mem.indexOf(u8, seg, "\"id\"") orelse return null;
    var i = ipos + "\"id\"".len;
    while (i < seg.len and (seg[i] == ' ' or seg[i] == ':')) : (i += 1) {}
    return parseIdAt(seg, i);
}

/// Wrapper-script launchers resolve to several possible appids (the Welcome
/// app's choice file, else the fallback probe order in install.sh) — match
/// any of them. Kept next to the scripts' own lists by name so drift is
/// greppable: BROWSER_APPIDS ↔ perihelionbar-launch-browser's probe loop.
pub const BROWSER_APPIDS = [_][]const u8{ "brave", "brave-browser", "zen", "zen-browser", "vivaldi", "vivaldi-stable", "edge", "microsoft-edge", "librewolf", "firefox", "firefox-esr", "chromium", "google-chrome", "chrome" };

/// DISCORD_APPIDS ↔ perihelionbar-launch-discord's probe loop ("fluxer" covers
/// app.fluxer.FluxerDesktop as a whole-word run, same as the other entries).
pub const DISCORD_APPIDS = [_][]const u8{ "vesktop", "equibop", "discord", "fluxer" };

/// Word separators inside an app id or a match key: reverse-DNS dots plus
/// the dash/underscore/space variants distro ids and desktop classes use
/// ("org.gnome.Nautilus", "zen-browser", "steam_app_440").
pub fn isWordSep(c: u8) bool {
    return c == '.' or c == '-' or c == '_' or c == ' ';
}

/// True when `needle`'s words appear as one contiguous run of `hay`'s
/// words: case is ignored and separators *between* words are skipped while
/// walking, but the run has to start and end on a whole word of `hay`
/// (index 0 / a separator on each side). So "perihelionbar-config" hits
/// "io.github.ciphervlt.perihelionbar.Config", "gnome-text-editor" hits
/// "org.gnome.TextEditor" and "chrome" hits "google-chrome" — while "edge"
/// never lands inside "ledger", "zen" never inside "zenity", and one
/// shared word ("perihelionbar", "com", "org") can never stand in for a whole
/// sibling key.
pub fn wordRunIn(hay: []const u8, needle: []const u8) bool {
    if (hay.len == 0 or needle.len == 0) return false;
    var needle_words: usize = 0;
    for (needle) |c| {
        if (!isWordSep(c)) needle_words += 1;
    }
    if (needle_words == 0) return false; // separators-only key matches nothing
    var start: usize = 0;
    while (start < hay.len) : (start += 1) {
        // A run may only begin at a word edge: index 0 or just past a sep.
        if (start > 0 and !isWordSep(hay[start - 1])) continue;
        var hi = start;
        var ni: usize = 0;
        while (true) {
            while (ni < needle.len and isWordSep(needle[ni])) ni += 1;
            if (ni == needle.len) break;
            while (hi < hay.len and isWordSep(hay[hi])) hi += 1;
            if (hi == hay.len or std.ascii.toLower(hay[hi]) != std.ascii.toLower(needle[ni])) break;
            hi += 1;
            ni += 1;
        }
        // Needle fully consumed, and the run stopped on a whole word: hit.
        var done = ni;
        while (done < needle.len and isWordSep(needle[done])) done += 1;
        if (done == needle.len and (hi == hay.len or isWordSep(hay[hi]))) return true;
    }
    return false;
}

/// True when `appid_norm` (already lowercased) names the app `key`
/// (lowercase): the two are compared as word runs in both directions, so
/// "org.gnome.nautilus" ↔ "nautilus", "zen-browser" ↔ "zen" and
/// "…perihelionbar.Config" ↔ "perihelionbar-config" all hit, and a flatpak pin
/// ("com.spotify.Client") still finds a window reporting plain "spotify".
///
/// Both directions, whole words only: the old per-component substring test
/// matched any single dot component either way, which made every window of
/// one family light every pin of that family — `…perihelionbar.Config` satisfied
/// the `perihelionbar-welcome` pin through their shared "perihelionbar" component (and
/// "com" satisfied every flatpak-style pin at once), so starting
/// perihelionbar-config lit the welcome dot too.
pub fn appidMatchesKey(appid_norm: []const u8, key: []const u8) bool {
    if (key.len == 0 or appid_norm.len == 0) return false;
    return wordRunIn(appid_norm, key) or wordRunIn(key, appid_norm);
}

/// Command → match key: first shell word's basename, lowercased
/// ("org.gnome.Nautilus" never appears here — commands are binaries, the
/// DNS-splitting happens on the appid side). Flatpak/snap wrappers resolve
/// to the wrapped app id (`flatpak run … com.spotify.Client @@` → the id,
/// not "flatpak" — otherwise every sandboxed pin matches nothing and
/// spawns duplicates). Empty when unmatchable.
pub fn launcherMatchKey(command_in: []const u8, buf: []u8) []const u8 {
    // Perihelion: "env VAR=x app ..." (common in .desktop Exec lines, which
    // the drawer's "Pin to dock" copies) matches as "app".
    var command = command_in;
    if (std.mem.startsWith(u8, command, "env ")) {
        var rest = command[4..];
        while (true) {
            while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            const tok = rest[0..end];
            if (tok.len == 0 or !(std.mem.indexOfScalar(u8, tok, '=') != null or tok[0] == '-')) break;
            rest = rest[end..];
        }
        command = rest;
    }
    var word = command;
    if (std.mem.indexOfScalar(u8, word, ' ')) |sp| word = word[0..sp];
    if (std.mem.lastIndexOfScalar(u8, word, '/')) |sl| word = word[sl + 1 ..];
    if (std.mem.endsWith(u8, word, ".desktop")) word = word[0 .. word.len - ".desktop".len];
    if (word.len == 0) return "";
    if (std.mem.eql(u8, word, "flatpak") or std.mem.eql(u8, word, "snap")) {
        if (wrappedAppId(command, buf)) |id| return id;
        // `flatpak update`-style verbs with no app: fall through to the
        // wrapper name itself (matches nothing, launches fine).
    }
    return buf[0..lowerCopy(buf, word)];
}

/// Pulls the wrapped app id out of a `flatpak run …` / `snap run …`
/// command: first token past `run` that isn't a flag. Flatpak ids always
/// carry dots (com.spotify.Client); snap names are bare (spotify), so the
/// dot rule only applies to flatpak. `=`-bearing tokens (--command=x,
/// --branch=x) and @@-forwarding placeholders never qualify.
pub fn wrappedAppId(command: []const u8, buf: []u8) ?[]const u8 {
    const is_snap = blk: {
        var w = command;
        if (std.mem.indexOfScalar(u8, w, ' ')) |sp| w = w[0..sp];
        const base = if (std.mem.lastIndexOfScalar(u8, w, '/')) |sl| w[sl + 1 ..] else w;
        break :blk std.mem.eql(u8, base, "snap");
    };
    var toks = std.mem.splitScalar(u8, command, ' ');
    var past_run = false;
    while (toks.next()) |tok| {
        if (!past_run) {
            if (std.mem.eql(u8, tok, "run")) past_run = true;
            continue;
        }
        if (tok.len == 0 or tok[0] == '-' or std.mem.indexOfScalar(u8, tok, '=') != null) continue;
        if (!is_snap and std.mem.indexOfScalar(u8, tok, '.') == null) continue;
        return buf[0..lowerCopy(buf, tok)];
    }
    return null;
}

/// True when the running client (`appid_norm` + `title_norm`, both
/// lowercased) belongs to `command`'s app. The app-drawer power button and
/// friends launch panels, not windows, and never match; the two wrapper
/// scripts match their whole candidate family; everything else matches its
/// binary name against appid (falling back to window title for odd hosts
/// like Steam's per-game appids).
pub fn clientMatchesLauncher(command: []const u8, appid_norm: []const u8, title_norm: []const u8) bool {
    if (launcherLaunchesAppdrawer(command)) return false;
    if (std.mem.eql(u8, command, "perihelionbar-launch-browser")) {
        for (BROWSER_APPIDS) |cand| if (appidMatchesKey(appid_norm, cand)) return true;
        return false;
    }
    if (std.mem.eql(u8, command, "perihelionbar-launch-discord")) {
        for (DISCORD_APPIDS) |cand| if (appidMatchesKey(appid_norm, cand)) return true;
        return false;
    }
    var kbuf: [64]u8 = undefined;
    const key = launcherMatchKey(command, &kbuf);
    if (key.len == 0) return false;
    if (appidMatchesKey(appid_norm, key)) return true;
    // Title fallback: "nautilus" also appears in file-manager titles, while
    // appids stay canonical — weak on purpose (contains only, one way).
    if (title_norm.len > 0 and std.mem.indexOf(u8, title_norm, key) != null) return true;
    return false;
}

/// True when `command` launches the app drawer: the first
/// whitespace-separated token's basename is "appdrawer" ("appdrawer",
/// "/usr/bin/appdrawer", "appdrawer open", ...). Renaming the pin's label
/// doesn't fool it, and a hypothetical "my-appdrawer-fork" correctly does
/// NOT match.
pub fn launcherLaunchesAppdrawer(command: []const u8) bool {
    // Trimmed on the left only in effect: trailing whitespace ends the first
    // token at the split below, so a both-sides trim is equivalent here
    // (std.mem has no trimLeft in this Zig version).
    var s = std.mem.trim(u8, command, " \t");
    if (s.len == 0) return false;
    if (std.mem.indexOfScalar(u8, s, ' ')) |sp| s = s[0..sp];
    if (std.mem.indexOfScalar(u8, s, '\t')) |t| s = s[0..t];
    var base = s;
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |sl| base = s[sl + 1 ..];
    return std.mem.eql(u8, base, "appdrawer");
}

/// True for Perihelion's recycle-bin pin ("perihelion-trash", any path or
/// arguments) — Perihelion Settings adds and removes it.
pub fn launcherIsTrash(command: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, command, " \t");
    const first = it.next() orelse return false;
    const base = if (std.mem.lastIndexOfScalar(u8, first, '/')) |i| first[i + 1 ..] else first;
    return std.mem.eql(u8, base, "perihelion-trash");
}

/// Installed-application icon index: lowercase lookup key (executable
/// basename or StartupWMClass) → icon name as the .desktop file spells it
/// (case preserved — theme filenames are case-sensitive). Built once at
/// startup from enumerateInstalledApps; first source wins, so user
/// overrides in ~/.local/share/applications beat system files, matching
/// the app drawer's own listing order.
///
/// Sized to swallow a busy desktop: every entry is 144 bytes of BSS, and a
/// full index fails silently from the caller's side (the app just keeps
/// its label). Flatpak exports are scanned last, so a too-small cap shows
/// up as exactly "sandboxed apps have no icons" — 1024 clears a full KDE
/// install plus a couple of hundred Flatpak exports with room to spare.
pub const MAX_DESKTOP_IDX: usize = 1024;

pub const DesktopIdxEntry = struct {
    key_buf: [64]u8 = undefined,
    key_len: usize = 0,
    icon_buf: [64]u8 = undefined,
    icon_len: usize = 0,
};

pub var desktop_idx: [MAX_DESKTOP_IDX]DesktopIdxEntry = undefined;

pub var desktop_idx_len: usize = 0;

pub fn desktopIndexAdd(key: []const u8, icon: []const u8) void {
    if (key.len == 0 or icon.len == 0 or desktop_idx_len >= desktop_idx.len) return;
    for (desktop_idx[0..desktop_idx_len]) |*e| {
        if (std.mem.eql(u8, e.key_buf[0..e.key_len], key)) return; // first wins
    }
    var e = &desktop_idx[desktop_idx_len];
    e.key_len = lowerCopy(&e.key_buf, key);
    const il = @min(e.icon_buf.len, icon.len);
    @memcpy(e.icon_buf[0..il], icon[0..il]);
    e.icon_len = il;
    desktop_idx_len += 1;
}

/// Already-lowercased key → icon name, or null. Pure lookup over the
/// startup-built index (tests populate it directly).
pub fn desktopIndexLookup(key_norm: []const u8) ?[]const u8 {
    for (desktop_idx[0..desktop_idx_len]) |*e| {
        if (std.mem.eql(u8, e.key_buf[0..e.key_len], key_norm)) return e.icon_buf[0..e.icon_len];
    }
    return null;
}

/// Deep variant: the full key, then each of its '.'-separated components
/// ("com.spotify.client" → the desktop entry keyed "spotify"). Skips
/// registry-ish components (com/org/io/net/app) and stubs — those only
/// ever false-positive. What makes wrapped flatpak ids resolve to the
/// sandox's real icon instead of a label.
pub fn desktopIndexLookupDeep(key_norm: []const u8) ?[]const u8 {
    if (desktopIndexLookup(key_norm)) |icon| return icon;
    var parts = std.mem.splitScalar(u8, key_norm, '.');
    while (parts.next()) |part| {
        if (part.len <= 2) continue;
        if (std.mem.eql(u8, part, "com") or std.mem.eql(u8, part, "org") or std.mem.eql(u8, part, "net") or std.mem.eql(u8, part, "app")) continue;
        if (desktopIndexLookup(part)) |icon| return icon;
    }
    return null;
}

/// Wrapper-script binaries in probe order (mirroring install.sh's
/// perihelionbar-launch-browser / -discord loops — keep in sync by name).
pub const BROWSER_BINS = [_][]const u8{ "brave", "brave-browser", "zen-browser", "zen", "vivaldi-stable", "vivaldi", "microsoft-edge-stable", "microsoft-edge", "librewolf", "firefox", "firefox-esr" };

pub const DISCORD_BINS = [_][]const u8{ "vesktop", "equibop", "discord", "fluxer" };

/// Icon name for a wrapper script: the user's chosen binary when set and
/// installed, else the first probe binary that's either on PATH or has a
/// resolvable icon (Fluxer lives outside PATH but has a theme icon).
/// Null when nothing resolves — the pin falls back to its label.
pub fn wrapperIconName(candidates: []const []const u8, choice_file: []const u8, probe: Probe, out: []u8) ?[]const u8 {
    var cbuf: [64]u8 = undefined;
    const choice = probe.choice(choice_file, &cbuf);
    if (choice.len > 0 and probe.on_path(choice)) {
        if (desktopIndexLookup(choice)) |icon| {
            const l = @min(out.len, icon.len);
            @memcpy(out[0..l], icon[0..l]);
            return out[0..l];
        }
        const l = @min(out.len, choice.len);
        @memcpy(out[0..l], choice[0..l]);
        return out[0..l];
    }
    for (candidates) |bin| {
        if (!probe.on_path(bin)) {
            // Not launchable via PATH, but may still be the running app's
            // icon (Fluxer lives outside PATH yet has a theme icon) —
            // accept it when an icon resolves.
            const icon = desktopIndexLookup(bin) orelse bin;
            if (!probe.icon_resolves(icon)) continue;
            const l = @min(out.len, icon.len);
            @memcpy(out[0..l], icon[0..l]);
            return out[0..l];
        }
        var kbuf: [64]u8 = undefined;
        const kl = lowerCopy(&kbuf, bin);
        const icon = desktopIndexLookup(kbuf[0..kl]) orelse bin;
        const l = @min(out.len, icon.len);
        @memcpy(out[0..l], icon[0..l]);
        return out[0..l];
    }
    return null;
}

/// Icon name for a pinned command: the explicit config icon wins (handled
/// by the caller — this is only the DERIVED fallback), the app-drawer pin
/// has no icon (it wears the distro glyph instead), wrappers probe their
/// families, and plain binaries go through the desktop index with the
/// binary name itself as the last resort (decode decides resolvability).
pub fn pinIconName(command: []const u8, probe: Probe, out: []u8) ?[]const u8 {
    if (launcherLaunchesAppdrawer(command)) return null;
    if (std.mem.eql(u8, command, "perihelionbar-launch-browser")) return wrapperIconName(&BROWSER_BINS, "browser-choice", probe, out);
    if (std.mem.eql(u8, command, "perihelionbar-launch-discord")) return wrapperIconName(&DISCORD_BINS, "discord-choice", probe, out);
    var kbuf: [64]u8 = undefined;
    const key = launcherMatchKey(command, &kbuf);
    if (key.len == 0) return null;
    const icon = desktopIndexLookupDeep(key) orelse key;
    const l = @min(out.len, icon.len);
    @memcpy(out[0..l], icon[0..l]);
    return out[0..l];
}

/// Icon names to try for a running window's appid (lowercased), first hit
/// wins: the desktop index's answer (else the last dotted part), then the
/// full appid as a literal icon name, then each DNS component (a theme may
/// ship "spotify" while the running id is the full "com.spotify.client").
/// The bar tries Steam's library cache before these; Glance does the same.
pub const IconNames = struct {
    names: [16][]const u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const IconNames) []const []const u8 {
        return self.names[0..self.len];
    }

    fn add(self: *IconNames, n: []const u8) void {
        if (self.len == self.names.len) return;
        self.names[self.len] = n;
        self.len += 1;
    }
};

pub fn runningIconNames(id: []const u8) IconNames {
    var out = IconNames{};
    var short = id;
    if (std.mem.lastIndexOfScalar(u8, id, '.')) |dot| short = id[dot + 1 ..];
    const cand = desktopIndexLookupDeep(id) orelse short;
    out.add(cand);
    if (!std.mem.eql(u8, cand, id)) out.add(id);
    var parts = std.mem.splitScalar(u8, id, '.');
    while (parts.next()) |part| {
        if (part.len <= 2 or std.mem.eql(u8, part, short)) continue;
        if (std.mem.eql(u8, part, "com") or std.mem.eql(u8, part, "org") or std.mem.eql(u8, part, "net") or std.mem.eql(u8, part, "app")) continue;
        out.add(part);
    }
    return out;
}

test "runningIconNames: index answer, full id, then DNS parts" {
    const t = std.testing;
    const saved = desktop_idx_len;
    defer desktop_idx_len = saved;
    desktop_idx_len = 0;
    desktopIndexAdd("spotify", "spotify-client");
    const a = runningIconNames("com.spotify.client");
    try t.expectEqual(@as(usize, 3), a.len);
    try t.expectEqualStrings("spotify-client", a.names[0]);
    try t.expectEqualStrings("com.spotify.client", a.names[1]);
    try t.expectEqualStrings("spotify", a.names[2]);
    const b = runningIconNames("foot");
    try t.expectEqual(@as(usize, 1), b.len); // short == id: tried once
    try t.expectEqualStrings("foot", b.names[0]);
    const c = runningIconNames("org.gnome.texteditor");
    try t.expectEqualStrings("texteditor", c.names[0]);
    try t.expectEqualStrings("org.gnome.texteditor", c.names[1]);
    try t.expectEqualStrings("gnome", c.names[2]);
    try t.expectEqual(@as(usize, 3), c.len);
}
