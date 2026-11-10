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
