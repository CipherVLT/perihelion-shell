
<img width="1254" height="1254" alt="Neon Gradient Feather Emblem" src="https://github.com/user-attachments/assets/a04835bf-6f32-4dc9-8dc7-68c03ae6553a" />

# Perihelion Bar

A native Zig/Wayland status bar for **Hyprland and MangoWM** — simple, clean, out of the way — plus an installer that sets up a ricing-friendly Arch desktop around it.

Perihelion's own bar: it began as a fork of [simpbar](https://github.com/jaytheoutpatient/simpbar) by jaytheoutpatient (with his blessing) and has since been reworked throughout.

Built for **Arch Linux** (EndeavourOS, CachyOS, Garuda, XeroLinux should work too). Pick your window manager (**Hyprland** or **MangoWM**) up front; **Chaotic-AUR** is configured for binary packages.

## Install

```
curl -sSL https://raw.githubusercontent.com/CipherVLT/perihelion-shell/main/install.sh | bash
```

Interactive — answers a few questions, asks for sudo **once**, then installs everything. Reboot when done (`systemctl reboot`).

What you get: bar + desktop widgets + app drawer with Bluetooth, wallpaper picker with matugen auto-theming, foot, rofi, swaync, fish, Neovim, browser/Discord of your choice, OBS/video tools optional. Gaming launchers (Steam/Lutris/Heroic) come from the Xero installer's GAMING picks.

## Desktop widgets

`perihelionbar-shell` paints widget cards on the wallpaper layer: clock, weather, media controls, system monitor, top processes, network speed, user and uptime, fastfetch, calendar with reminders, sticky note.

- Same matugen colors as the bar, translucent cards.
- Turn cards on or off, and pick their options (clock face, System columns, bars or rings, units, Processes rows, Network graph and refresh, User card host and uptime wording, calendar reminders, note tabs and checklists), in **Perihelion Settings → Appearance → Desktop Widgets / Desktop Card Options**. The options are saved in `shell.json`, and the cards restart to apply them.
- **Ctrl + drag** any card to move it — position saves to `~/.config/perihelionbar/shell.json`.
- The Calendar card shows the month with arrows to step through months (click the month name to come back to today), the weekdays, and the days of the neighbouring months dimmed. Today sits on a soft disc in your accent colour, public holidays are in the holiday colour, and a day with a reminder has a short accent bar under its number. Under the month, today's holiday or the next one is shown with its date and how many days away it is.
- Calendar reminders live in `~/.config/perihelionbar/reminders.txt` (`YYYY-MM-DD HH:MM text`, or `YYYY-MM-DD HH:MM lead text` to be notified `lead` days early). Click a day to add or remove one.
  - The Calendar card can list today's and upcoming reminders under the month, earliest first, under a **Reminders** header. Each shows its text with the day and time under it (`Today · 09:00`); today's ones whose time has passed are dimmed. Click a row to open that day's reminders. Pick how many rows in Settings, or set `"calendar_reminders"` in `shell.json` to 0 (off, the default) up to 6. The card grows by one header plus the rows, so you may need to drag a card that sits right under it.
  - The card re-reads the file every 30 seconds (and right after you add or remove a reminder from the card). The read is at most 4 KB of a local file, and the list is only redrawn when it changes.
- The Notes card holds up to nine notes. Click a note to type in it. Esc, or clicking somewhere else, saves it, and it also saves itself a moment after you stop typing.
  - **Tabs:** the header has one tab per note, **+** for a new note and **×** to delete the open note. Click × twice to confirm. The deleted text is kept in `notes/.last-deleted.txt`, in case you change your mind. A new note you leave empty just goes away.
  - **Checklists:** start a line with `- [ ] ` and it shows as a checkbox when you're not typing. Click the box to tick it. `- ` lines show as bullets and `# ` lines as headings. While you type, you see the plain text.
  - **Files:** each note is a plain text file, `~/.config/perihelionbar/notes/note1.txt` to `note9.txt`, so your old note is note 1. Edit them with anything; the card picks up changes and new files by itself. A note can hold 4 KB. A bigger file is shown but not editable here, so it never gets cut short.
  - Scroll with the mouse wheel when a note is longer than the card, or drag the card's bottom-right corner to make it bigger.

  Settings in `shell.json`:

  ```json
  "notes_tabs": true,
  "notes_checklists": true,
  "notes_lines": 6,
  "notes_dir": "",
  "notes_page": 1
  ```

  `notes_tabs: false` hides the header for a single plain note. `notes_lines` (3–30) sets how many lines the card shows. `notes_dir` keeps notes in another folder, such as a synced one (`"~/Sync/notes"`). `notes_page` remembers which note was open.
- Weather comes from [Open-Meteo](https://open-meteo.com) (no API key): current conditions plus a 7-day strip on the card, icon + temperature on the bar, refreshed every 15 minutes. The bar and the card read the same settings and share one cached answer (`~/.cache/perihelionbar/weather.cache`), so they always agree. Click the card to open the full forecast (weather.gov in the US, Windy elsewhere). Temperatures are in °F for places in the US and °C elsewhere, unless you choose. Set the place in `shell.json`:

  ```json
  "weather_latitude": 41.8781,
  "weather_longitude": -87.6298,
  "weather_city": "Chicago",
  "weather_units": "auto",
  "weather_click": "forecast",
  "weather_auto_location": true,
  "weather_refresh_minutes": 15,
  "weather_ip_url": ""
  ```

  Coordinates are the most reliable choice, and `weather_city` is then just the label. With no coordinates, `weather_city` is looked up once. It can be a city or postal code, `"DeSoto, TX"` (a city in that US state), `"Lyon, FR"` (a city in that country) or `"32.59,-96.86"` (coordinates). With neither, the shell guesses the place from your IP address (turn that off with `weather_auto_location: false`). The first line of `~/.config/perihelionbar/weather-location` is read the same way when `weather_city` is empty.

  `weather_units` is `"auto"`, `"C"` or `"F"`. `weather_click: "units"` makes a click switch °C/°F instead of opening the forecast. Both are also in Perihelion Settings.
- The Fastfetch card follows your fastfetch config, the same one your terminal uses. With Perihelion's config, that means the feather logo in the wallpaper's colours, then `user@host`, then the Hardware, Software and Uptime / Age / DT sections with the same rows and icons (PC, CPU, GPU, memory, disk, distro, kernel, BIOS, packages, WM, OS age, uptime, date and time). The terminal's box lines become section headers, and the tree marks before each key are dropped. Only modules your config lists are shown, so no local IP unless you add it.
  - **Which config:** `fastfetch_config`, else `~/.config/fastfetch/config.jsonc` (or under `$XDG_CONFIG_HOME`), else Perihelion's default at `/usr/share/perihelion/fastfetch/config.jsonc`.
  - **Which program:** `fastfetch_binary`, else `perihelion-fastfetch` if one is on your PATH, else `fastfetch`. With none of them, the card fills in what it can read itself.
  - **How often:** fastfetch runs at start and every 30 minutes. Uptime, memory, disk and the clock are updated every minute without starting a process.
  - **Rows fastfetch can't see from the desktop:** the card isn't started from a terminal, so it fills these itself. **Shell** is your login shell (from your account, else `$SHELL`) with its version, such as `bash 5.2.37`. **Terminal** is the terminal you'd get: `$TERMINAL`, else the first installed entry of xdg-terminal-exec's `xdg-terminals.list`, else what Mango's Super+Return bind launches, else foot if it's installed; shown with its version. **Terminal Font** comes from that terminal's config: foot's `foot.ini` (`font=`), kitty's `kitty.conf` (`font_family` / `font_size`, following `include` lines) or alacritty's `alacritty.toml`, with each terminal's default when the config doesn't set one. **Wmtheme** shows the GTK theme (gsettings, else `gtk-4.0` or `gtk-3.0` `settings.ini`), since Mango has no theme of its own. These are read once at start.
  - A key whose format repeats its own label (`"format": "Uptime: {formatted}"`, `"OS Age: {result}"`) shows that label once: the row reads `Uptime   11 mins` and `OS Age   0 days`.
  - A row with nothing to show is left out instead of showing a dash.

  Settings in `shell.json`:

  ```json
  "fastfetch_config": "",
  "fastfetch_binary": "",
  "fastfetch_refresh_minutes": 30,
  "fastfetch_logo": "auto",
  "fastfetch_fields": ["os", "host", "kernel", "uptime", "packages", "shell", "wm", "cpu", "gpu", "memory", "disk"]
  ```

  - **`fastfetch_config`:** a config file path, or `"none"` to ignore your config and show `fastfetch_fields` (fastfetch's plain rows; add `display`, `theme`, `icons`, `font`, `bios`, `de` or `datetime` if you like).
  - **`fastfetch_binary`:** a path, a name on your PATH, or `"none"` to never start a process.
  - **`fastfetch_logo`:** `"auto"` (the text logo your config points to), `"distro"`, `"none"`, or a path to a text logo.

- The System card shows CPU and memory use plus CPU and GPU temperatures, read straight from the kernel's sensors (no `lm_sensors` needed). NVIDIA's proprietary driver is read with `nvidia-smi` (from `nvidia-utils`), at most every 5 seconds. A sleeping laptop GPU shows "asleep" and is left alone, so it doesn't wake up. With more than one GPU, click the card to switch between them. Settings in `shell.json`:

  ```json
  "system_gpu": "auto",
  "system_temp_units": "C",
  "system_temp_interval_seconds": 2,
  "system_nvidia_smi": true
  ```

  `system_gpu` takes `"auto"` (prefers a dedicated card), `"none"` (shows the load average instead), a list position (`"0"`, `"1"`), a vendor (`"amd"`, `"intel"`, `"nvidia"`), or a PCI address such as `"0000:03:00.0"`.

  `"system_style"` picks the card's look. `"columns"` (the default) shows seven readings side by side: CPU, CPU temperature, memory, GPU temperature, GPU busy, download and upload. Each has its value on top, a thin rounded bar that fills from the bottom, and an icon under it. A reading is in your accent colour normally, turns amber when it gets busy or warm, and turns your theme's error colour when it's high. The marks are 60 % and 80 % for CPU and GPU, 75 % and 90 % for memory, and 70 °C and 85 °C for temperatures; the network bars are full at 10 MB/s. A reading the computer doesn't have (no GPU sensor in a virtual machine, say) stays in its place, dimmed, with "n/a". `"bars"` keeps the rows: CPU, memory, and the GPU, or the load average when the GPU has no reading. `"rings"` shows ring gauges for CPU, memory, GPU and CPU temperature, using the same colours; a reading the computer doesn't have gets no ring.

- The Clock card has four faces. Pick one with `clock_style`:
  - `"digital"` (default): big hours and minutes, with the date underneath and the weekday in your accent colour.
  - `"flip"`: split-flap tiles.
  - `"stacked"` (or `"macos"`): hours above minutes, with the date beside them.
  - `"classic"`: the original two lines of text.

  The other settings work with every face:

  ```json
  "clock_style": "digital",
  "clock_24h": true,
  "clock_seconds": false,
  "clock_date": true
  ```

  Without seconds, the card only redraws once a minute.

- The Processes card lists the busiest programs, by CPU or by memory. Click it to switch, and your choice is saved. It only shows them: it can't stop or change a process. It reads `/proc` itself every 3 seconds and never starts a program. CPU is shown as a share of one core, like `top`, so one program can show more than 100 %. Kernel threads are left out. Settings in `shell.json`:

  ```json
  "processes_sort": "cpu",
  "processes_count": 6,
  "processes_interval_seconds": 3,
  "processes_group": false
  ```

  `processes_count` can be 3 to 8. `processes_group: true` adds up programs that run as several processes, such as a browser, and shows how many there are (`firefox ×12`). The card is on by default. You can hide it in Settings like any other card.

- The Network card shows your download and upload speed, added up over your wired, Wi-Fi and mobile-broadband connections. Loopback, VPN tunnels, bridges and container interfaces are left out, so nothing is counted twice. Under the header, a graph shows the last 60 readings (two minutes at the default): download in your accent colour, upload dimmer, scaled to the busiest reading. It reads `/proc/net/dev` itself and never starts a program. It says *offline* when no such connection exists, and it only redraws when a number or the graph changes. Settings in `shell.json`:

  ```json
  "network_graph": true,
  "network_interval_seconds": 2
  ```

  `network_interval_seconds` can be 1 to 10. With `network_graph: false` the card is just the header and the two speeds.

- The User card shows your distro's logo on a rounded square tile, `user@host` as a bold heading with a thin line under it, and how long the computer has been up (`Uptime  2 hours, 39 mins`, or `2h 39m` when the long form doesn't fit) next to a small clock. The logo is the icon your `/etc/os-release` names in `LOGO=` (on Perihelion, Fedora's `fedora-logo-icon`), found through your icon theme; without one, the distro symbol the Fastfetch card uses, and failing that the first letter of your name on an accent-coloured circle. Your name, the host name and the logo are read once at startup, and the uptime from `/proc/uptime`. The card redraws once a minute. Settings in `shell.json`:

  ```json
  "user_host": true,
  "user_uptime_short": false,
  "user_show_name": false
  ```

  `user_host: false` makes the heading just your user name. `user_uptime_short: true` always uses the short form. `user_show_name: true` adds your full name (from your account, or your login name) under the heading.

**Overview (`Alt + W`):** GNOME-style grid of live window screenshots with search + workspace strip + favorites dash. `perihelionbar-shell overview toggle` works from scripts too.

## Welcome & Config

**Perihelion Bar Welcome** (first login, then pinned in the bar): intro, one-click updates, wallpaper picker, text-editor/browser/Discord picks, keybinding reference.

**Perihelion Bar Config:** bar appearance + modules + nine WM pages (General, Monitors, Animations, Keybinds, Window/Workspace/Layer Rules, Autostart, Environment). Hyprland writes `hyprland-perihelionbar.lua`, MangoWM edits `~/.config/mango/cfg/` directly.

## Keybindings

Hyprland set (MangoWM in `~/.config/mango/cfg/keybinds.conf`, same spirit):

| Keys | Action |
|---|---|
| `SUPER + Enter` | Terminal |
| `SUPER + Space` | Rofi |
| `SUPER + Tab` | App drawer |
| `SUPER + Shift + Tab` | Wallpapers |
| `SUPER + W` | Restart bar |
| `Alt + W` | Overview |
| `SUPER + E` | Files |
| `SUPER + Q` | Close window |
| `SUPER + 1–0` | Workspaces |


## Images

<img width="1920" height="1080" alt="screenshot-2026-10-19_11-47-27" src="https://github.com/user-attachments/assets/b220c3cb-e8b4-43aa-8b16-ec077d18ae85" />
<img width="1920" height="1080" alt="screenshot-2026-10-19_11-48-40" src="https://github.com/user-attachments/assets/cdabfa9e-d839-43d6-9a3d-d0ad3a2809fe" />
<img width="1920" height="1080" alt="screenshot-2026-10-19_11-48-18" src="https://github.com/user-attachments/assets/a72ed3a5-118b-4d20-b88a-47dfa004dd5e" />
<img width="1919" height="1080" alt="screenshot-2026-10-19_11-48-00" src="https://github.com/user-attachments/assets/94a141d8-cf41-43c7-8448-b72c604dbd89" />
<img width="1919" height="1080" alt="screenshot-2026-10-19_11-47-43" src="https://github.com/user-attachments/assets/f005fcda-d05b-43d4-a554-895af6de5eda" />






## Credits

- Install script start: **Ryzendew**.
- `xero/xero-install.sh`: **XeroLinux Team** (Xero Arch Installer, GPL-3.0) — base-system installer this fork builds on.
- Hyprland-settings UX inspired by **HyprMod** by **BlueManCZ**.
- Palettes in `theme/palettes/`: **Event Horizon**'s colour themes (GPL-3.0), each crediting the scheme it is named after in `theme/palettes/NOTICE.md`. Monokai's are left out (no open licence).

## License

Perihelion Shell is free software under the [GNU General Public License v3.0](LICENSE):
you may redistribute and modify it under the terms of the GPL, version 3.
