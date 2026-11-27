# CLAUDE.md – Perihelion Shell

## Project Vision
Perihelion Shell is a **feather-lightweight** Wayland desktop shell built primarily in **Zig**.  
It must stay significantly lighter and more efficient than Waybar while delivering a modern, polished experience.

Core principles (in order of priority):
1. **Maximum lightness** – keep binary size, memory usage, and CPU usage as low as possible
2. **Mainly Zig** – the core, bar, widgets, and most logic stay in Zig
3. **Improve existing Quickshell (QML) for the App Drawer** – do not rewrite it in Rust
4. **Eliminate remaining C** – prefer pure Zig alternatives, or QML when the code is UI-related
5. **Modern, polished, glassy GNOME-inspired feel** with smooth high-quality motion

---

## Language Rules

- Default language: **Zig**
- App Drawer: Stay in **Quickshell / QML**. Improve and polish the existing implementation. Do **not** rewrite it in Rust.
- Any remaining **C code**:
  - First look for a clean Zig alternative or rewrite it in Zig
  - If the code is UI-related, prefer rewriting it in QML instead
  - Avoid keeping C unless there is a very strong reason
- Never introduce heavy frameworks or unnecessary dependencies

---

## App Drawer Goals (Quickshell)

Current problems:
- Feels stale, cheap, and choppy
- Scrolling and animations lack smoothness and polish
- Needs a more refined, glassy, modern look

Target:
- Keep the overall UI layout and structure **almost the same**
- Greatly improve animation smoothing and scrolling feel (solid 60 Hz or better)
- Add a clean glassy / modern aesthetic
- Make it feel professionally coded and high-quality
- Remain as lightweight as possible

When working on the App Drawer:
- Focus on proper animation curves, timing, and easing
- Fix choppy scrolling (efficient ListView usage, virtualization, smooth physics)
- Improve visual polish: subtle glass/blur effects, better spacing, refined hover/pressed states, cleaner typography
- Avoid heavy effects that hurt performance
- Prefer small, targeted improvements over large rewrites

---

## Handling Remaining C Code

When you encounter any C code in the project:
1. Identify what it does
2. Check whether a clean Zig equivalent or rewrite is possible
3. If it is UI-related, prefer moving the functionality into QML
4. Only keep C if there is no reasonable Zig or QML alternative
5. Explain the choice and keep the solution as light as possible

---

## Settings Goals

- Make the Settings interface more polished and modern (GNOME-inspired)
- Improve hierarchy, spacing, and overall refinement
- Keep changes lightweight
- Maintain visual consistency with the improved App Drawer

---

## General UI / Design Guidelines

- Modern GNOME visual language with a glassy, refined tone
- Smooth, high-quality animations with proper easing
- Consistent spacing, radii, and motion language across the shell
- Prefer subtle glass/blur and soft depth over heavy visual effects
- Always protect the feather-light character of the project

---

## Performance & Lightness Rules

- Lightness is non-negotiable
- Prefer improving existing Quickshell code over rewriting in another language
- Prefer Zig (or QML for UI) over C
- Avoid anything that significantly increases memory or CPU usage
- When adding visual polish (glass, blur, shadows), keep it efficient

---

## Working Style

- First analyze the existing code before changing it
- Make focused improvements
- When touching C code, actively look for Zig or QML replacements
- Explain why each change improves smoothness, polish, or lightness
- Protect the lightweight nature of the shell at all times

---

## Summary for Claude

You are helping improve **Perihelion Shell** — a feather-lightweight Zig Wayland shell.

- Keep the core in Zig
- Improve the **App Drawer** inside the existing Quickshell (QML) implementation — do not rewrite it in Rust
- Focus on smooth scrolling, proper animation smoothing, a more glassy modern look, and overall polish
- When you find C code, prefer rewriting it in Zig, or in QML if it is UI-related
- Never sacrifice the project’s extreme lightness

## Dock & Widgets Goals

### Dock
- Fix jagged / unrounded corners (especially the right side) — make both ends cleanly and evenly rounded
- Add proper right-click context menu on dock icons with:
  - Unpin
  - New Window
  - Close window
- Keep the dock lightweight and visually clean

### Bar & Widgets
- Fix the volume icon so it matches the other icons (currently black, should be white/light like the rest)
- Improve all desktop widgets (weather, calendar, media, system, etc.) to have a clean modern glass/blur style
- Target look: soft rounded glass panels, good blur, refined spacing, clean typography, and high visual quality (inspired by clean Event Horizon / modern glass widgets)
- Make widgets feel polished and professionally coded rather than basic

## Bar & Dock Rules (Important)

### Mutual Exclusion
- The Perihelion Bar and the Dock cannot both be active at the bottom at the same time.
- If the Dock is enabled → the “Bottom” position option for the Perihelion Bar must be greyed out / disabled.
- If the Perihelion Bar is set to Bottom → the Dock must automatically turn off and be greyed out.
- This prevents overlapping and keeps the desktop clean.

### Visual Style (Glass & Clean)
- Remove all solid/heavy shadows from both the Perihelion Bar and the Dock.
- The Dock should have a clean, floating, see-through glass look (inspired by Event Horizon super dock).
- The Perihelion Bar should also be clean glass with no shadows under the clock, weather, or system icons.
- Both should let the wallpaper show through clearly.

### Dock Specific
- Fix the trash icon (currently has black smudged artifacts with Numix Circle). Make it clean and robust across icon packs.
- Target look: soft rounded glass dock, subtle transparency/blur, clean icon presentation, no heavy drop shadow underneath.

  ## Bar & Dock Layout Rules

### Top Bar
- Provide a clear settings toggle to completely hide the workspace indicator/switcher.
- Left side Application Launcher must dynamically show the logo of the current distribution (Fedora, Arch, CachyOS, Nobara, Bazzite, Pika OS, etc.).
- Add a far-left spacer so the launcher is not flush against the screen edge.

Left-side order:
1. Spacer
2. Distro-logo Application Launcher

### Bottom Dock
- Completely independent from the Top Bar.
- Far left of the Dock contains its own Application Launcher (with dynamic distro logo) + Media Control Center widget next to it.
- This left block is structurally separate from pinned/running application icons.
- Maintain bookend symmetry with the far right side (spacer + Trash).
- Give both ends proper breathing room.

## Dock Positioning & Behavior

- The Dock should sit low and close to the bottom edge of the screen (not floating too high).
- “Shrink the dash” must meaningfully reduce padding and spacing around icons, making the dock noticeably more compact.
- Prefer a clean floating glass style with proper distance from the bottom edge.

## Glass / Blur Quality

- Glass and blur effects must be clean and high-quality.
- Avoid heavy distortion, warping, or dirty-looking blur.
- Target a soft, elegant frosted glass appearance.

## Weather Widgets

- Rebuild both the small top-bar weather indicator and the larger weather widget.
- Target a clean modern design with large temperature, condition text, and optional hourly strip.
- Use a high-quality glass / frosted see-through style.
- When Matugen is active, switch to a frosted black / dark glass appearance.
- Prefer lightweight data sources (Open-Meteo or wttr.in).
- Keep rendering efficient and free of GPU jank.

## Dock Hover Style

- Do **not** use a black pill or dark rounded background on hover for dock icons.
- On hover, the icon itself should light up / brighten.
- Keep the hover effect clean, subtle, and modern (similar to Event Horizon dock style).
- Avoid heavy or dirty-looking hover backgrounds.

  ## Bar & Dock Instance Rules (Critical)

- There must only ever be **one** Perihelion Bar and **one** Dock at a time.
- Turning the Perihelion Bar off must only hide/disable the Bar. It must never create or spawn a Dock.
- Turning the Dock off and on must only show/hide the existing Dock. It must never create additional Dock instances.
- Both the Bar and Dock must be treated as singletons. Prevent any code path that can spawn duplicates.

# CLAUDE.md

Guidance for Claude / Claude Code when working on Perihelion-shell and the Perihelion Linux ISO.

## Project Identity

- **perihelion-shell** — Zig/Wayland bar + desktop widgets. Primary codebase.
- **Perihelion** (ISO repo) — Fedora-based distro that pins a specific commit of perihelion-shell and ships it as Perihelion Linux (MangoWM-first).
- Perihelion is an independent project. All work is Perihelion-native.
- Target compositor: **MangoWM only**. Do not touch Hyprland or Niri paths unless explicitly asked.

## Toolchain

- Zig version: **0.17** (pinned at **0.17.1** in CI and the ISO build).
- `zig version` must print `0.17.1` for every build and test.
- Pin exactly 0.17.1 in:
  - CI workflows
  - both `build.zig.zon` files (`minimum_zig_version = "0.17.0"` is acceptable)
  - `install.sh`
  - the ISO’s `install-perihelionbar.sh`
- The official 0.17.1 tarball and signature must download and verify with CI’s `ZIG_PUBKEY`.
- Do not use Zig 0.16.

## Current State (as of late 2026)

Desktop cards and bar features already landed and working:
- Weather (Open-Meteo, shared cache, top-bar indicator)
- System (rings + bars, CPU/GPU temps)
- Fastfetch (follows real config)
- Clock (digital / flip / stacked / classic)
- Processes
- Network
- Notes
- Calendar
- Media
- User
- Brightness OSD
- Notification center (mako history + DND)
- Control Center (volume, brightness, Wi-Fi, Bluetooth, power profile, keep-awake, DND)
- Glance Slice 1 (Super+I dashboard, Overview tab)

## Porting Rules (Event Horizon → Perihelion)

When porting widgets or features from Event Horizon dotfiles:

1. **Rewrite in Zig**. Do not leave QML.
2. **No Event Horizon branding** in code, strings, docs, or comments you add.
3. **Reuse existing services** where possible (weather.zig, temps.zig, notifs.zig, backlight.zig, radios.zig, powerprof.zig, etc.).
4. **Matugen theming** only. No hardcoded Event Horizon colors.
5. **shell.json / config.json keys** with sensible defaults + Settings rows when user-facing.
6. **Redraw only on change**. Cheap polling. No blocking on the main loop.
7. **Independent cards** where practical. Shared cache/services are fine.
8. **MangoWM-first**. Idle-inhibit, layer-shell, and keybinds must work under Mango.
9. **Incremental**. Small commits. Update PROGRESS.md. Full Zig test suite before push.
10. After shell changes land, update the pin in the Perihelion ISO repo (`build/refs/perihelionbar.ref`) and verify only the Mango ISO build.

## Key Conventions

- Tests: `zig build` + `zig build test-*` steps must pass under Zig 0.17.1.
- Config: Prefer extending existing `shell.json` / `config.json` over new files.
- State: Use `~/.local/state/perihelionbar/` or XDG paths. Never write to the user’s real config during tests.
- Glass / blur: Respect existing matugen + frosted glass paths.
- Bar modules: New modules go through `ModuleKind`, Settings round-trip, and default-on insertion where appropriate.

## Current Priorities

1. **Glance** (DarkDash-inspired dashboard) — Slice 1 done. Next is Media tab, then Weather, then Apps (needed before any dock retirement).
2. Keep the existing dock functional until Glance is ready to take over.
3. Privacy indicators and other polish items are lower priority.

## What Not To Do

- Do not reintroduce the old base project's name, framing, assets or credits in code or docs.
- Do not add Event Horizon logos, strings, or branding.
- Do not break the MangoWM ISO path.
- Do not start large new systems (full Control Center rewrites, embedded terminal, lock screen) without explicit request.
- Do not assume Hyprland or Niri behavior.
- Do not use Zig 0.16. The project is on Zig 0.17.1.

## Useful Paths (local development)

- Shell: `/home/mirrez/ciphervlt/perihelion-shell`
- ISO: `/home/mirrez/ciphervlt/Perihelion`
- Event Horizon reference (read-only): `/home/mirrez/ciphervlt/eh-dotfiles/Event-Horizon-Dotfiles-main`
- PROGRESS.md: `/home/mirrez/ciphervlt/PROGRESS.md`

When in doubt, check current `main` of both repos and PROGRESS.md before starting new work.
perihelion-shell — Zig Optimization & Architecture Rules

## Toolchain & Build
- Verify exact compiler version first with `zig version` before writing `std` calls (do not use deprecated Zig 0.11/0.12 APIs).
- Release builds must be tested with `zig build -Doptimize=ReleaseSafe` and `zig build -Doptimize=ReleaseFast`.

## Memory & Allocation Rules
- **Zero heap allocations in hot paths** (input/event loop, prompt rendering, ANSI/command tokenization).
- Use `std.heap.ArenaAllocator` with `.reset(.retain_capacity)` for per-command or per-frame lifecycles.
- Use `std.BoundedArray` or stack buffers + `std.heap.FixedBufferAllocator` for bounded strings, paths, and IPC packets.
- Every allocation must have an immediate `defer` or `errdefer` cleanup; verify zero leaks in `zig build test` using `std.testing.allocator`.

## Systems & Linux Performance
- Batch all terminal/socket writes through `std.io.BufferedWriter`; never issue unbuffered per-token `write` syscalls.
- Prefer `std.MultiArrayList` over `std.ArrayList` for collections scanned in tight loops.
- Use `std.mem` SIMD-accelerated search helpers (`indexOfScalar`, `indexOfAny`) instead of manual byte loops.

## Benchmarking Protocol
- Before optimizing any function, write a reproducible benchmark or profile with `perf record -g ./zig-out/bin/perihelion-shell` so changes are backed by measurements.

