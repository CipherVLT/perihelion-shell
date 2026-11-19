const std = @import("std");
const Build = std.Build;

// perihelionbar-shell — the "desktop widgets" idea from Event-Horizon-Shell,
// rewritten in Zig on top of the infra the bar (../perihelionbar) already proves:
// the same zig-wayland scanner for layer-shell surfaces, and the bar's
// font.zig (freetype glyph cache) + logging.zig imported as source modules.
const Scanner = @import("wayland").Scanner;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wayland_dep = b.dependency("wayland", .{});

    const scanner = Scanner.create(b, .{});

    const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
    // Screenshot capture for the overview's window thumbnails (vendored
    // from swaywm/wlr-protocols; Hyprland implements zwlr_screencopy too).
    scanner.addCustomProtocol(b.path("protocols/wlr-screencopy-unstable-v1.xml"));

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_output", 4);
    scanner.generate("zwlr_layer_shell_v1", 4);
    // Bound at v1 at runtime (see registryListener): v1 already has the
    // buffer/copy/ready/failed flow the overview needs, and skipping v3's
    // buffer_done handshake keeps the capture state machine trivial.
    scanner.generate("zwlr_screencopy_manager_v1", 3);
    // xdg_wm_base is generated too (the scanner pulls it in for surface
    // role wiring) even though the shell itself never creates an xdg window.

    // Shared-with-perihelionbar source modules: the shell only needs the font
    // cache and logging; it never touches the bar's tray/icons/Hyprland glue.
    const font_mod = b.createModule(.{
        .root_source_file = b.path("../perihelionbar/src/font.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    font_mod.linkSystemLibrary("freetype2", .{});

    const logging_mod = b.createModule(.{
        .root_source_file = b.path("../perihelionbar/src/logging.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Weather service, shared with the bar's top-bar indicator (lives with
    // the bar's sources like font.zig): Open-Meteo, location, refresh
    // schedule, and the answer cache both processes read and write.
    const weather_mod = b.createModule(.{
        .root_source_file = b.path("../perihelionbar/src/weather.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // CPU/GPU temperature service, shared with the bar (same convention).
    const temps_mod = b.createModule(.{
        .root_source_file = b.path("../perihelionbar/src/temps.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // System-info service for the Fastfetch card (same convention).
    const fastfetch_mod = b.createModule(.{
        .root_source_file = b.path("../perihelionbar/src/fastfetch.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Top-processes service for the Processes card (same convention).
    const procs_mod = b.createModule(.{
        .root_source_file = b.path("../perihelionbar/src/procs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const widgets_mod = b.createModule(.{
        .root_source_file = b.path("src/widgets.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    widgets_mod.addImport("font", font_mod);
    widgets_mod.addImport("weather", weather_mod);
    widgets_mod.addImport("temps", temps_mod);
    widgets_mod.addImport("fastfetch", fastfetch_mod);
    widgets_mod.addImport("procs", procs_mod);
    widgets_mod.addImport("logging", logging_mod);

    // Album-art decode for the media card: same gdk-pixbuf shim the bar
    // compiles for tray icons, referenced out of ../perihelionbar/src like the
    // font module above (the installer stages both trees side by side).
    const art_mod = b.createModule(.{
        .root_source_file = b.path("src/art.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // gdk-pixbuf's Zig declarations live with the bar's sources.
    const pixbuf_mod = b.createModule(.{
        .root_source_file = b.path("../perihelionbar/src/gdkpixbuf.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    art_mod.addImport("gdkpixbuf", pixbuf_mod);
    widgets_mod.addImport("art", art_mod);

    // Desktop icons: icon NAME -> file resolution + pixbuf decode, straight
    // from the bar (it walks user flatpak exports, user icon dirs, hicolor,
    // and the Steam library caches, and its decodeIcon returns 0xAARRGGBB
    // tiles). Grabs the same ../perihelionbar/src include path for the shim header;
    // the shim's symbols themselves come from the executable's compiled copy.
    const icontheme_mod = b.createModule(.{
        .root_source_file = b.path("../perihelionbar/src/icontheme.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    icontheme_mod.addImport("gdkpixbuf", pixbuf_mod);
    widgets_mod.addImport("icontheme", icontheme_mod);

    // Overview mode (Alt+W): the second layer surface on the overlay layer,
    // screencopy thumbnails, hyprctl window/workspace queries. Own module so
    // main.zig stays the host/wiring file.
    const overview_mod = b.createModule(.{
        .root_source_file = b.path("src/overview.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    overview_mod.addImport("wayland", wayland_mod);
    overview_mod.addImport("font", font_mod);
    overview_mod.addImport("logging", logging_mod);
    overview_mod.addImport("widgets", widgets_mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("wayland", wayland_mod);
    exe_mod.addImport("gdkpixbuf", pixbuf_mod); // glass.zig: the blurred wallpaper behind the cards
    exe_mod.addImport("font", font_mod);
    exe_mod.addImport("logging", logging_mod);
    exe_mod.addImport("widgets", widgets_mod);
    exe_mod.addImport("weather", weather_mod); // shell.json weather_* keys (main.zig)
    exe_mod.addImport("temps", temps_mod); // shell.json system_* keys (main.zig)
    exe_mod.addImport("fastfetch", fastfetch_mod); // shell.json fastfetch_* keys (main.zig)
    exe_mod.addImport("procs", procs_mod); // shell.json processes_* keys (main.zig)
    exe_mod.addImport("overview", overview_mod);
    // No EGL/GL stack: everything renders CPU-side into wl_shm ARGB buffers,
    // exactly like the bar.
    exe_mod.linkSystemLibrary("wayland-client", .{});
    exe_mod.linkSystemLibrary("freetype2", .{});
    exe_mod.linkSystemLibrary("gdk-pixbuf-2.0", .{}); // media cover-art decode (src/art.zig)
    // Sticky-note typing decodes the compositor's keymap through xkb; the
    // bar links the same library for its input handling.
    exe_mod.linkSystemLibrary("xkbcommon", .{});
    // gdk-pixbuf is called through ../perihelionbar/src/gdkpixbuf.zig (pure Zig
    // extern declarations); no C file is compiled.

    const exe = b.addExecutable(.{
        .name = "perihelion-shell",
        .root_module = exe_mod,
    });
    // Same toolchain pins as the bar (../perihelionbar/build.zig): Zig 0.16's
    // Debug defaults fall over on this project, and ReleaseFast's LLVM/LLD
    // defaults are what we want in every optimize mode anyway.
    exe.use_llvm = true;
    exe.use_lld = true;

    _ = wayland_dep;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run perihelionbar-shell");
    run_step.dependOn(&run_cmd.step);

    // `zig build test-widgets`: src/widgets.zig's unit tests — note editing
    // and wrapping, the Notes card's pages on disk (under /tmp), header
    // hit-testing, checklist markers. No display needed. gdk-pixbuf is
    // linked for the art/icon declarations the module pulls in.
    widgets_mod.linkSystemLibrary("gdk-pixbuf-2.0", .{});
    const widgets_tests = b.addTest(.{ .root_module = widgets_mod, .use_llvm = true, .use_lld = true });
    const widgets_test_step = b.step("test-widgets", "Run src/widgets.zig unit tests");
    widgets_test_step.dependOn(&b.addRunArtifact(widgets_tests).step);
}