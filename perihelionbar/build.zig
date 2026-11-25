const std = @import("std");
const Build = std.Build;

// zig-wayland exposes a build-time helper (Scanner) that turns protocol XML
// into Zig source at build time. This import works because `wayland` is
// declared as a dependency in build.zig.zon.
const Scanner = @import("wayland").Scanner;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wayland_dep = b.dependency("wayland", .{});

    const scanner = Scanner.create(b, .{});

    // Core protocol module produced by the scanner. We import specific
    // interfaces from it below via `wayland.client.wl` / `.zwlr`.
    const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });

    // Core Wayland interfaces we need: surfaces, shared memory, outputs.
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");

    // wlr-layer-shell is NOT part of upstream wayland-protocols — it's a
    // wlroots extension. Vendor the XML yourself; see protocols/README.md.
    scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
    // Keep awake (Control Center): an idle inhibitor on the bar's surface.
    scanner.addSystemProtocol("unstable/idle-inhibit/idle-inhibit-unstable-v1.xml");

    // Generate bindings up to the given protocol version. Bump these if you
    // need newer requests/events.
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_output", 4);
    scanner.generate("xdg_wm_base", 3);
    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("zwp_idle_inhibit_manager_v1", 1);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("wayland", wayland_mod);
    // gdk-pixbuf's hand-written Zig declarations (icontheme.zig's decoder).
    exe_mod.addImport("gdkpixbuf", b.createModule(.{
        .root_source_file = b.path("src/gdkpixbuf.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    // Weather service shared with perihelionbar-shell's desktop card
    // (Open-Meteo, location, refresh/retry schedule, shared answer cache).
    // Pure std + libc; the shell imports this same file as a module.
    const weather_mod = b.createModule(.{
        .root_source_file = b.path("src/weather.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("weather", weather_mod);
    // CPU/GPU temperature service, shared with the shell's System card.
    const temps_mod = b.createModule(.{
        .root_source_file = b.path("src/temps.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("temps", temps_mod);
    // System-info service behind the shell's Fastfetch card. The bar does
    // not use it; it lives here with the other shared services and its
    // tests run from this build.
    const fastfetch_mod = b.createModule(.{
        .root_source_file = b.path("src/fastfetch.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Top-processes service behind the shell's Processes card (same
    // convention: shared source, tests run from this build).
    const procs_mod = b.createModule(.{
        .root_source_file = b.path("src/procs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // User/uptime service behind the shell's User card (same
    // convention: shared source, tests run from this build).
    const userinfo_mod = b.createModule(.{
        .root_source_file = b.path("src/userinfo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Backlight reader behind the bar's brightness OSD.
    const backlight_mod = b.createModule(.{
        .root_source_file = b.path("src/backlight.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("backlight", backlight_mod);
    // Notification-center data behind the bar's notifications panel.
    const notifs_mod = b.createModule(.{
        .root_source_file = b.path("src/notifs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("notifs", notifs_mod);
    // Control Center: Wi-Fi / Bluetooth and power-profile output parsing.
    // Volume parsing and slider maths (src/volume.zig): the volume module,
    // mixer, OSD and Control Center here, and Glance's Media tab in the shell.
    const volume_mod = b.createModule(.{
        .root_source_file = b.path("src/volume.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("volume", volume_mod);
    // Version and commit for --version and Settings > Updates.
    const info_mod = buildInfoModule(b);
    const cli_version_mod = b.createModule(.{
        .root_source_file = b.path("src/cli_version.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_version_mod.addImport("build_info", info_mod);
    exe_mod.addImport("cli_version", cli_version_mod);
    // Coming back after Mango closes the bar's layer surface (output gone,
    // e.g. on resume): src/respawn.zig, shared with the shell.
    const respawn_mod = b.createModule(.{
        .root_source_file = b.path("src/respawn.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("respawn", respawn_mod);
    const radios_mod = b.createModule(.{
        .root_source_file = b.path("src/radios.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("radios", radios_mod);
    const powerprof_mod = b.createModule(.{
        .root_source_file = b.path("src/powerprof.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("powerprof", powerprof_mod);
    // Network-rate service behind the shell's Network card (same
    // convention: shared source, tests run from this build).
    const netrate_mod = b.createModule(.{
        .root_source_file = b.path("src/netrate.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Reminders file parsing behind the shell's Calendar card (same
    // convention: shared source, tests run from this build).
    const reminders_mod = b.createModule(.{
        .root_source_file = b.path("src/reminders.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.linkSystemLibrary("wayland-client", .{});
    exe_mod.linkSystemLibrary("freetype2", .{}); // real Nerd Font/Unicode glyph rendering (src/font.zig)
    exe_mod.linkSystemLibrary("gdk-pixbuf-2.0", .{}); // tray icon-name -> PNG/SVG decode (src/icontheme.zig)
    // No EGL/GLESv2/wayland-egl linkage: the bar presents exclusively through
    // the wl_shm memfd path, so no GL stack is loaded into the process.
    // gdk-pixbuf.h pulls in GLib headers that Zig's translate-c can't parse
    // (back-to-back _Pragma(...) runs), so src/gdkpixbuf.zig declares the few
    // calls we need by hand, like welcome_gtk.zig does for GTK. No C file is
    // compiled.

    const exe = b.addExecutable(.{
        .name = "perihelion-bar",
        .root_module = exe_mod,
    });
    // Zig 0.16 defaults Debug builds to the self-hosted x86 backend +
    // self-hosted ELF linker, and both fall over on this project:
    //   - the backend segfaults compiling the Debug binaries
    //     ("process terminated with signal SEGV"), and
    //   - zig ld cannot handle the R_X86_64_PC64 relocations in the
    //     .sframe section that GCC 16's crt1.o ships
    //     ("fatal linker error: unhandled relocation type ...
    //      in crt1.o:.sframe").
    // ReleaseFast already picks LLVM+LLD by mode default; pin both
    // explicitly so every optimize mode builds the same way.
    exe.use_llvm = true;
    exe.use_lld = true;

    _ = wayland_dep;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run perihelionbar");
    run_step.dependOn(&run_cmd.step);

    // Unit tests: the ~40 `test` blocks at the bottom of src/main.zig (the
    // file calls itself `main` as a module, so everything above is linker
    // dead weight — the tests only pull what they exercise). Runs with
    // `zig build test`; same module wiring as the exe, minus the install.
    const tests = b.addTest(.{
        .root_module = exe_mod,
        .use_llvm = true, // same backend pin as the exe above
        .use_lld = true,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run src/main.zig unit tests");
    test_step.dependOn(&run_tests.step);

    // `zig build test-weather`: src/weather.zig's parsing, schedule and
    // cache-format tests (no Wayland or fonts needed).
    const weather_tests = b.addTest(.{ .root_module = weather_mod, .use_llvm = true, .use_lld = true });
    const weather_test_step = b.step("test-weather", "Run src/weather.zig unit tests");
    weather_test_step.dependOn(&b.addRunArtifact(weather_tests).step);

    // `zig build test-temps`: src/temps.zig (builds a fake sysfs tree under
    // /tmp, so it runs on any machine).
    const temps_tests = b.addTest(.{ .root_module = temps_mod, .use_llvm = true, .use_lld = true });
    const temps_test_step = b.step("test-temps", "Run src/temps.zig unit tests");
    temps_test_step.dependOn(&b.addRunArtifact(temps_tests).step);

    // `zig build test-fastfetch`: src/fastfetch.zig (fake /etc, /proc, /sys
    // trees under /tmp; no fastfetch binary needed).
    const fastfetch_tests = b.addTest(.{ .root_module = fastfetch_mod, .use_llvm = true, .use_lld = true });
    const fastfetch_test_step = b.step("test-fastfetch", "Run src/fastfetch.zig unit tests");
    fastfetch_test_step.dependOn(&b.addRunArtifact(fastfetch_tests).step);

    // `zig build test-procs`: src/procs.zig (stat parsing, formatting, and a
    // fake /proc tree under /tmp for ranking, grouping and CPU deltas).
    const procs_tests = b.addTest(.{ .root_module = procs_mod, .use_llvm = true, .use_lld = true });
    const procs_test_step = b.step("test-procs", "Run src/procs.zig unit tests");
    procs_test_step.dependOn(&b.addRunArtifact(procs_tests).step);

    // `zig build test-reminders`: src/reminders.zig (line parsing, the
    // upcoming list and day labels from fake file text).
    const reminders_tests = b.addTest(.{ .root_module = reminders_mod, .use_llvm = true, .use_lld = true });
    const reminders_test_step = b.step("test-reminders", "Run src/reminders.zig unit tests");
    reminders_test_step.dependOn(&b.addRunArtifact(reminders_tests).step);

    // `zig build test-netrate`: src/netrate.zig (/proc/net/dev parsing,
    // rate formatting, the sample history, a fake counters file in /tmp).
    const netrate_tests = b.addTest(.{ .root_module = netrate_mod, .use_llvm = true, .use_lld = true });
    const netrate_test_step = b.step("test-netrate", "Run src/netrate.zig unit tests");
    netrate_test_step.dependOn(&b.addRunArtifact(netrate_tests).step);

    // `zig build test-userinfo`: src/userinfo.zig (passwd and uptime
    // parsing, uptime wording, fake files in /tmp).
    const userinfo_tests = b.addTest(.{ .root_module = userinfo_mod, .use_llvm = true, .use_lld = true });
    const userinfo_test_step = b.step("test-userinfo", "Run src/userinfo.zig unit tests");
    userinfo_test_step.dependOn(&b.addRunArtifact(userinfo_tests).step);

    // `zig build test-backlight`: src/backlight.zig (percent math, device
    // choice and change detection on fake class trees under /tmp).
    const backlight_tests = b.addTest(.{ .root_module = backlight_mod, .use_llvm = true, .use_lld = true });
    const backlight_test_step = b.step("test-backlight", "Run src/backlight.zig unit tests");
    backlight_test_step.dependOn(&b.addRunArtifact(backlight_tests).step);

    // `zig build test-notifs`: src/notifs.zig (makoctl output samples,
    // garbage and huge inputs, the state file, a fake /proc under /tmp).
    const notifs_tests = b.addTest(.{ .root_module = notifs_mod, .use_llvm = true, .use_lld = true });
    const notifs_test_step = b.step("test-notifs", "Run src/notifs.zig unit tests");
    notifs_test_step.dependOn(&b.addRunArtifact(notifs_tests).step);

    // `zig build test-radios` / `test-powerprof`: the Control Center's
    // nmcli, bluetoothctl and powerprofilesctl parsing (fake output).
    const radios_tests = b.addTest(.{ .root_module = radios_mod, .use_llvm = true, .use_lld = true });
    const radios_test_step = b.step("test-radios", "Run src/radios.zig unit tests");
    radios_test_step.dependOn(&b.addRunArtifact(radios_tests).step);
    // `zig build test-volume`: src/volume.zig (pactl lines, the poll text,
    // slider value <-> x, labels and icon tiers).
    const volume_tests = b.addTest(.{ .root_module = volume_mod, .use_llvm = true, .use_lld = true });
    const volume_test_step = b.step("test-volume", "Run src/volume.zig unit tests");
    volume_test_step.dependOn(&b.addRunArtifact(volume_tests).step);
    // `zig build test-updater`: Settings > Updates' rules (versions, release
    // JSON, URLs and the redirect host, SHA256SUMS, tar listing, manifest
    // against the allowlist, argv, buttons), on made-up data only.
    const updater_core_mod = b.createModule(.{
        .root_source_file = b.path("src/updater_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const updater_tests = b.addTest(.{ .root_module = updater_core_mod, .use_llvm = true, .use_lld = true });
    const updater_test_step = b.step("test-updater", "Run src/updater_core.zig unit tests");
    updater_test_step.dependOn(&b.addRunArtifact(updater_tests).step);
    // `zig build test-respawn`: the restart rule after an output goes away.
    const respawn_tests = b.addTest(.{ .root_module = respawn_mod, .use_llvm = true, .use_lld = true });
    const respawn_test_step = b.step("test-respawn", "Run src/respawn.zig unit tests");
    respawn_test_step.dependOn(&b.addRunArtifact(respawn_tests).step);
    const powerprof_tests = b.addTest(.{ .root_module = powerprof_mod, .use_llvm = true, .use_lld = true });
    const powerprof_test_step = b.step("test-powerprof", "Run src/powerprof.zig unit tests");
    powerprof_test_step.dependOn(&b.addRunArtifact(powerprof_tests).step);

    // `zig build test-mango-config`: src/mango_config_check.zig against
    // sample configs and the Mango config the installer ships (desktop/mango/) (Super+I -> Glance,
    // Super+L -> lock, swayidle, dbus, bar + shell autostart). Pure std.
    const mango_check_mod = b.createModule(.{
        .root_source_file = b.path("src/mango_config_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    mango_check_mod.addAnonymousImport("mango_config_conf", .{ .root_source_file = b.path("../desktop/mango/config.conf") });
    mango_check_mod.addAnonymousImport("mango_keybinds_conf", .{ .root_source_file = b.path("../desktop/mango/cfg/keybinds.conf") });
    mango_check_mod.addAnonymousImport("mango_autostart_conf", .{ .root_source_file = b.path("../desktop/mango/cfg/autostart.conf") });
    const mango_check_tests = b.addTest(.{ .root_module = mango_check_mod, .use_llvm = true, .use_lld = true });
    const mango_check_step = b.step("test-mango-config", "Run src/mango_config_check.zig unit tests");
    mango_check_step.dependOn(&b.addRunArtifact(mango_check_tests).step);

    // `zig build test-icons`: the icon theme lookup (src/icontheme.zig),
    // which main.zig's tests don't reach.
    const icon_mod = b.createModule(.{
        .root_source_file = b.path("src/icontheme.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    icon_mod.addImport("gdkpixbuf", b.createModule(.{
        .root_source_file = b.path("src/gdkpixbuf.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    icon_mod.linkSystemLibrary("gdk-pixbuf-2.0", .{});
    const icon_tests = b.addTest(.{ .root_module = icon_mod, .use_llvm = true, .use_lld = true });
    const icon_test_step = b.step("test-icons", "Run src/icontheme.zig unit tests");
    icon_test_step.dependOn(&b.addRunArtifact(icon_tests).step);

    // perihelionbar-welcome: separate GTK4/libadwaita companion app, independent
    // of the bar above (no Wayland/freetype/gdk-pixbuf deps). Talks to
    // GTK/libadwaita through hand-written extern bindings in
    // src/welcome_gtk.zig rather than @cImport — see that file for why.
    const welcome_mod = b.createModule(.{
        .root_source_file = b.path("src/welcome_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    welcome_mod.addImport("cli_version", cli_version_mod);
    welcome_mod.linkSystemLibrary("gtk4", .{});
    welcome_mod.linkSystemLibrary("libadwaita-1", .{});
    welcome_mod.linkSystemLibrary("gobject-2.0", .{});
    welcome_mod.linkSystemLibrary("glib-2.0", .{});
    welcome_mod.linkSystemLibrary("gio-2.0", .{});

    const welcome_exe = b.addExecutable(.{
        .name = "perihelionbar-welcome",
        .root_module = welcome_mod,
    });
    welcome_exe.use_llvm = true; // see perihelionbar exe above: Debug defaults SEGV/ld-lld
    welcome_exe.use_lld = true;
    b.installArtifact(welcome_exe);

    const run_welcome_cmd = b.addRunArtifact(welcome_exe);
    run_welcome_cmd.step.dependOn(b.getInstallStep());
    const run_welcome_step = b.step("run-welcome", "Run perihelionbar-welcome");
    run_welcome_step.dependOn(&run_welcome_cmd.step);

    // perihelionbar-config: GUI for configuring the bar's appearance/module
    // layout and creating/pinning desktop shortcuts. Same dep set as
    // perihelionbar-welcome (no Wayland/freetype/gdk-pixbuf) — reuses
    // src/welcome_gtk.zig's GObject bindings directly.
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    config_mod.addImport("cli_version", cli_version_mod);
    config_mod.linkSystemLibrary("gtk4", .{});
    config_mod.linkSystemLibrary("libadwaita-1", .{});
    config_mod.linkSystemLibrary("gobject-2.0", .{});
    config_mod.linkSystemLibrary("glib-2.0", .{});
    config_mod.linkSystemLibrary("gio-2.0", .{});

    const config_exe = b.addExecutable(.{
        .name = "perihelion-settings",
        .root_module = config_mod,
    });
    config_exe.use_llvm = true; // see perihelionbar exe above: Debug defaults SEGV/ld-lld
    config_exe.use_lld = true;
    b.installArtifact(config_exe);

    const run_config_cmd = b.addRunArtifact(config_exe);
    run_config_cmd.step.dependOn(b.getInstallStep());
    const run_config_step = b.step("run-config", "Run perihelionbar-config");
    run_config_step.dependOn(&run_config_cmd.step);
}

/// The version every program reports (`--version`, Settings > Updates).
/// Release builds pass -Dversion=<tag without v> and -Dcommit=<sha>; local
/// builds say this and ask git for the commit. Keep in step with the other
/// package's build.zig.
const DEFAULT_VERSION = "0.1.0-dev";

fn buildInfoModule(b: *Build) *Build.Module {
    const version = b.option([]const u8, "version", "Version compiled into the programs") orelse DEFAULT_VERSION;
    const commit = b.option([]const u8, "commit", "Commit compiled into the programs (default: git)") orelse blk: {
        var code: u8 = 0;
        const out = b.runAllowFail(&.{ "git", "rev-parse", "--short=7", "HEAD" }, &code, .ignore) catch break :blk "unknown";
        const t = std.mem.trim(u8, out, " \t\r\n");
        break :blk if (t.len > 0) t else "unknown";
    };
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    opts.addOption([]const u8, "commit", commit);
    return opts.createModule();
}
