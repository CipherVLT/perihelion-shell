
# Perihelion Bar

A native Zig/Wayland desktop for **MangoWM and Hyprland**: the bar and dock, desktop cards, Glance, the window overview, Settings (with Updates), a lock screen, an app drawer, wallpaper theming and a wallpaper picker. Light by design.

Where it came from and whose work it includes: [NOTICE.md](NOTICE.md).

On **Fedora**, Perihelion Linux ships Perihelion Bar ready to use. On **Arch Linux** (and Arch-based distros: CachyOS, EndeavourOS, Garuda, ...) the installer below sets it up.

## Install (Arch)

```sh
curl -fsSL https://raw.githubusercontent.com/CipherVLT/perihelion-shell/main/install.sh | bash
```

Or download first and read it before running:

```sh
git clone https://github.com/CipherVLT/perihelion-shell.git
cd perihelion-shell
less install.sh scripts/*.sh
./install.sh
```

Run it as your normal user; it asks for sudo for the steps that need it. Options:
`--yes` (take every default, no questions), `--wm=mango|hyprland|both` (default: the
window managers you have installed; MangoWM when you have neither),
`--existing=keep|new|beside` (what `--yes` does with a config of yours that differs;
default `beside`), `--rebuild`. With curl, pass them after `bash -s --`, for example
`curl -fsSL .../install.sh | bash -s -- --wm=hyprland`.

**What it changes**

- **Packages:** brings the system up to date and installs what is missing in one
  `pacman -Syu --needed` (the window manager you picked, the build tools, and the
  programs the desktop uses: quickshell, fuzzel, kitty, swaybg, swayidle, matugen, ...).
  AUR packages (Strata, the Bibata cursor) only through paru or yay if you have one;
  otherwise it tells you what to install.
- **Programs:** Zig 0.17.1 from ziglang.org (signature checked with minisign, kept in
  `~/.local/share/perihelionbar/`), then `perihelion-bar`, `perihelion-shell`,
  `perihelion-settings`, the lock screen and their helpers built from this commit and
  installed to `/usr/bin`; the lock screen's PAM file at `/etc/pam.d/perihelion-lock`;
  the app drawer's QML in `~/.local/share/perihelionbar/appdrawer`.
- **Configs:** MangoWM gets `~/.config/mango/` (config.conf plus cfg/, the same keys
  and programs as Perihelion Linux). Hyprland gets `~/.config/hypr/perihelion.lua` and
  one line, `require("perihelion")`, at the end of your `hyprland.lua`; nothing else in
  that file changes. Also `~/.config/perihelionbar/`, kitty, fuzzel, btop, GTK and qt6ct.
- **Never silently over yours:** for each config of yours that differs it asks: keep
  mine, take the new one (yours is copied to
  `~/.local/state/perihelionbar/backup-<date>/` first), or write the new one beside
  yours as `<file>.perihelion-new`. It remembers the answers for the next run.
- **Updates:** Settings → System → Updates shows *Installed with: install.sh* and checks
  for releases with a user timer (`perihelion-update-check.timer`).

Run it again any time to update: it changes only what is out of date and skips the
build when the installed programs already match the commit. The log is
`~/.local/state/perihelionbar/install.log`; a failing step stops the installer and
shows the end of the log.

**Undo**

```sh
xargs -a ~/.local/state/perihelionbar/installed-files sudo rm -f   # the installed programs and files
cp -a ~/.local/state/perihelionbar/backup-<date>/. ~/                  # your configs from before
```

On Hyprland, delete the `require("perihelion")` line in `~/.config/hypr/hyprland.lua`.
Packages stay installed; remove any you don't want with `sudo pacman -Rns`.

**From source** (no installer): `zig build -Doptimize=fast` in `perihelionbar/` and in
`perihelionbar-shell/`, with Zig 0.17.1.

After installing, log in to MangoWM or Hyprland. `perihelion-bar --version` prints the
version and commit, for example `perihelion-bar 0.1.0-dev (20034aa)`.

## Updates

**Perihelion Settings → System → Updates** keeps Perihelion Shell current from its GitHub releases.

- **This device:** the installed version and commit, how it was installed (*install.sh*, *Release update* or *Perihelion Linux*), **Check automatically** (on by default) with **Check every N hours** (6 by default; `"updates"` in `config.json`), and when it last checked.
- **Software update:** a status line and four buttons, each live only when it makes sense: **Check now**, **Download**, **Install update**, **Restart shell**.
- **Release notes:** the latest release's notes, after a check.

To check for and apply an update on Arch:

1. Open **Perihelion Settings → System → Updates** and press **Check now** (or wait: the `perihelion-update-check` timer checks in the background and sends a notification when a new release is out).
2. If it says *vX.Y.Z is available*, read the release notes and press **Download**. It downloads the release and checks it before anything changes: the SHA-256 checksum, that the tarball holds only the known program files, the release's manifest against the updater's built-in list of files and destinations, and that every program actually starts on your system (`--version`). Any failure stops here, says why, and installs nothing.
3. Press **Install update** and give your password (one `pkexec` prompt). The programs go to `/usr/bin`; the app drawer's QML goes to `~/.local/share/perihelionbar/appdrawer`. Your settings in `~/.config` and `/etc/pam.d` are never touched.
4. Press **Restart shell**: the bar, the dock, the desktop and the app drawer restart on the new version. `perihelion-bar --version` now shows it.

From a terminal, the same steps: `perihelion-settings --check-updates`, then `perihelion-settings --download-update` (prints `ready <folder>`), then `perihelion-settings --install-update <folder> <tag>`, then `perihelion-bar-start` (restarts the bar and the dock) and `appdrawer restart`.

Safety: downloads come only from this repository's GitHub releases over HTTPS. The one redirect GitHub answers with is checked by hand and must go to `release-assets.githubusercontent.com`. Nothing goes through a shell. Downloads go to a new folder in `/tmp`. Releases are built on Arch Linux for any x86_64 CPU. On **Perihelion Linux** the page shows and checks releases, but the shell is updated with the system.

To turn the background check off: switch off **Check automatically**, or `systemctl --user disable --now perihelion-update-check.timer`.

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
- The Fastfetch card follows your fastfetch config, the same one your terminal uses. With Perihelion's config, that means your distro's logo in the wallpaper's colours, then `user@host`, then the Hardware, Software and Uptime / Age / DT sections with the same rows and icons (PC, CPU, GPU, memory, disk, distro, kernel, BIOS, packages, WM, OS age, uptime, date and time). The terminal's box lines become section headers, and the tree marks before each key are dropped. Only modules your config lists are shown, so no local IP unless you add it.
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

**Overview (`Alt + W`):** GNOME-style grid of live window screenshots with search + workspace strip + favorites dash. `perihelion-shell overview toggle` works from scripts too.

**Glance (`Super + I` on MangoWM, in Perihelion Linux and in the Mango config `install.sh` deploys):** a dashboard over your windows: a glass panel in the middle of the screen with the wallpaper dimmed behind it, a row of tabs (**Overview**, **Media**, **Weather**, **Apps**) and a gear that opens Perihelion Settings. The Overview has the desktop cards themselves: Clock and Weather on the left, the Calendar in the middle, User and Media on the right, and System along the bottom. They look and behave like their desktop versions: the calendar's month arrows work, and so do the media buttons. Clicking the Weather card opens the Weather tab, and clicking the Media card anywhere but its buttons opens the Media tab. **Esc** or a click outside the panel closes it. You don't need the cards on your desktop to use Glance.

- **Media tab:** the large cover, the player and whether it's playing, the title, artist and album; a seek bar (click or drag it, the track jumps there when you let go) with the elapsed and total time; shuffle, previous, play/pause, next and repeat (a small 1 means repeat one); the output volume with a mute button and a slider you can drag (the sound follows while you drag). With more than one player running, a row of buttons along the bottom picks which one the tab shows and controls. It reads the player every 2 seconds while the tab is on screen (one short `playerctl`/`pactl` run), and not at all otherwise. Player names go to `playerctl -p` as plain arguments, never through a shell.
- **Weather tab:** the current conditions large (icon, temperature, condition, today's high and low, the place, and when the reading is from, marked Offline in the accent if the last refresh failed), six small tiles (feels like, humidity, wind with its direction, sea-level pressure, sunrise, sunset), an hourly strip starting at Now with the time, icon, temperature and chance of rain (as many hours as fit, up to 24; midnight shows the new day's name), and the 7-day forecast with each day's low and high on a bar scaled to the week. Units follow the Weather card (°F, mph and inHg, or °C, km/h and hPa) and times follow the clock's 12/24-hour setting. The arrow button opens the full forecast in the browser, the circular one refreshes now. Without a reading it says why: no location set, city not found, finding your location, loading, or offline with a Try again button. It shares the Weather card's cache and refresh period (15 minutes unless `weather_refresh_minutes` says otherwise), and checks it only while the tab is on screen.
- **Apps tab:** an **All apps** button (with your distro's logo) that opens the app drawer, and a **Trash** button that says whether the trash is empty and opens it in the file manager (there is no empty-trash button here). Under them, **Pinned**: the dock's pinned apps, from the dock's own list and in its order, with the same icons. An app with open windows has a marker under it (wider when it has focus, one dot per window up to three). Then **Running**: open apps that aren't pinned, one per app, as the dock's taskbar groups them. Clicking an app raises its window, or starts it when nothing is open, and Glance closes. Pins are read-only here: pin and unpin from the app drawer and the dock. The tab follows Mango's window events (as the dock does) plus a 2-second re-read while it's on screen, and nothing at all otherwise. Apps start from their pin's command split into words, never through a shell. Running apps are listed on MangoWM only.
- From a script: `perihelion-shell glance [toggle|open|close] [overview|media|weather|apps]`. The tab picks the page an open shows, and `toggle media` while Glance is up on another page switches to Media instead of closing.
- Light by design: nothing exists while it's closed (no surface, no buffers, no card copies, no timers, no `playerctl` or `curl` runs). Open, its cards tick on their own schedules, and the panel is drawn again only when something on it changes. After the 220 ms fade-and-grow there is no animation running. Weather comes from the answer the bar and the desktop card already share, so opening Glance doesn't fetch it again.
- **Perihelion Settings → Appearance → Glance**, or in `shell.json`:

  ```json
  "glance_enabled": true,
  "glance_start_tab": "overview"
  ```

  `glance_enabled: false` makes the command answer that Glance is off. `glance_start_tab` (`overview`, `media`, `weather` or `apps`) is the page a plain toggle opens on.

## Bar extras

**Brightness OSD:** when the screen brightness changes (the brightness keys run `brightnessctl`), the bar shows the same panel as the volume OSD: a sun icon, the level bar and the percentage, gone about 2 seconds after the last change. The bar doesn't listen to the keyboard: it keeps the backlight's `actual_brightness` file open and the kernel wakes it on every change (plus one tiny re-read a second for drivers that don't signal). It picks the device brightnessctl would (firmware over platform over raw). Without a backlight (desktops, virtual machines) it does nothing at all. Turn it off with `"bar": { "brightness_osd": false }` in `~/.config/perihelionbar/config.json`.

**Notifications:** mako still shows the pop-ups; the bar adds a bell (module `notifications`, on unless `config.json` gives it `"enabled": false`). Clicking it opens a panel with mako's recent notifications, newest first (up to 20 kept, 10 shown with a "+N older" line): the app, the title and the first line of the text. mako's history has no times, so there is no age. Underneath:

- **Do not disturb** turns mako's `do-not-disturb` mode on or off (`makoctl mode -a` / `-r`): no pop-ups, while the history still fills. The bell is crossed out while it's on. mako forgets modes when it restarts, so the bar saves the choice in `~/.local/state/perihelionbar/notifications` and puts it back when mako starts again. The mode comes from the `[mode=do-not-disturb]` / `invisible=1` section `perihelion-theme` writes into `~/.config/mako/config` (a mako config you wrote yourself needs those two lines).
- **Clear all** dismisses the pop-ups (`makoctl dismiss --all`) and empties the panel. mako can't delete its history, so the bar remembers the newest notification it cleared (in the same state file) and hides everything up to it, until mako restarts.

makoctl runs only when you open the panel or press one of the two buttons, never on a timer, and is stopped if it doesn't answer within 3 seconds. Without mako running, the bell is dimmed and the panel says so. The bell shows no unread count: that would mean asking mako every few seconds.

**Control Center:** a sliders icon (module `control_center`, on unless `config.json` gives it `"enabled": false`) opens one panel:

- **Volume** slider for the main output (click the speaker to mute), and **Brightness** for the screen backlight (`brightnessctl`). While the panel is open the volume and brightness OSDs stay away, since the sliders already show the level. Without a backlight the Brightness slider is dimmed.
- **Wi-Fi**: turns the Wi-Fi radio on or off (`nmcli radio wifi`) and shows the network you're on. Dimmed with "No Wi-Fi" when there's no Wi-Fi hardware.
- **Bluetooth**: powers the adapter on or off (`bluetoothctl power`, unblocking it with `rfkill` first). Dimmed with "No adapter" when there is none or bluetoothd isn't running.
- **Power**: each click moves to the next profile power-profiles-daemon offers (Saver, Balanced, Performance). Dimmed without the daemon.
- **Keep awake**: stops the screen from locking and the session from going idle (swayidle's 10-minute lock) while it's on. The bar holds an idle inhibitor on its own surface, so when the bar quits the inhibitor goes with it and the machine can't stay awake by accident. It only lasts for the session, and it doesn't stop a lock when you suspend yourself. Mango counts an inhibitor only while its surface is shown, which the bar always is; with the bar switched off there's no Control Center either. Dimmed if the compositor doesn't offer idle inhibiting.
- **Do not disturb**: the same switch as in the notifications panel (mako's do-not-disturb mode); changing it in either place changes both and the bell.

Pills that are on wear your accent colour. The states are read only while the panel is open: once when it opens and every 2 seconds after, each command stopped if it hangs for 3 seconds. Nothing runs while it's closed.

## Lock screen (MangoWM)

**perihelion-lockscreen** locks the session: the wallpaper under soft fades, the date and a large clock cut from frosted glass (AM/PM beside it in 12-hour mode), your account photo in a glass circle (`~/.face`, then the AccountsService icon, otherwise your initial on a frosted plate), your username, a frosted **Enter Password** pill with an arrow, and one hint line: *Press Enter to unlock*, *Caps Lock is on*, *Checking…* or *Incorrect password*. Escape clears what you typed.

- **When it runs:** `Super + L`, **Lock** in the power menu, and swayidle after 10 idle minutes and before every suspend. All three run `/usr/bin/perihelion-lock`, which starts `perihelion-lockscreen -f`. `-f` returns only once the compositor has confirmed the lock and every monitor shows it (at most 2 seconds), so a suspend can't catch the desktop unlocked. Pressing `Super + L` while locked does nothing and leaves the lock as it is.
- **Follows your setup:** the current wallpaper (or the theme's background colour if the wallpaper can't be read), the theme's accent and red from `perihelion-theme`, and **Settings → 24-hour clock** (`clock_24h` in `shell.json`). The username is read when it starts.
- **Safe by design:** it uses ext-session-lock-v1, so only a correct password unlocks. If the lock screen crashes or is killed, Mango keeps the session locked (see *If the lock screen crashes* below). It puts one lock surface on every monitor, including monitors plugged in while locked. The password is checked by PAM on a separate thread, using `/etc/pam.d/perihelion-lock` (`auth include login`, the same check as a console login; `login` itself if that file is missing). The typed password stays in memory that is never swapped and is wiped after every attempt and on exit. The log (`perihelion-lockscreen/` in the log folder) records only locks, unlocks, wrong attempts, PAM problems and monitors coming and going, never anything about the password.
- **After suspend:** if the monitor is re-detected on resume (some GPUs and virtual machines do that), Mango closes everything on the old monitor; the bar, the dock and the desktop widgets now start again on the new one by themselves (at most 6 times in 5 minutes).
- **Readable on any wallpaper:** when the wallpaper behind the date, the username or the hint is bright, a soft dark patch and a stronger shadow sit behind that line (measured once per monitor size; dark wallpapers look exactly as designed). Pictures: `assets/lock-preview/` (a bright wallpaper before and after, and a dark one).
- **Light:** it isn't running while you're unlocked. While locked it draws a frame when the minute changes, when you type, and once a second for the caret while there's text in the field. cairo, pango and PAM are linked into this one program only.

### If the lock screen crashes

Mango then shows a plain locked background. Nothing on the desktop takes input, but Mango still switches consoles with `Ctrl + Alt + F1`–`F12`, and the session (with your open windows) is still there. To unlock:

1. Switch to a text console: `Ctrl + Alt + F3`, and log in as yourself.
2. Start the lock screen again on your session:

   ```sh
   export XDG_RUNTIME_DIR=/run/user/$(id -u)
   ls "$XDG_RUNTIME_DIR"            # your session's socket: wayland-0 (or wayland-1, …)
   WAYLAND_DISPLAY=wayland-0 perihelion-lockscreen -f
   ```

   Use the `wayland-N` name `ls` printed (not the `.lock` file). If there are several, it's the one Mango created; `perihelion-lockscreen` exits with an error on the wrong one, so try the next. With `-f` it returns to the prompt once the lock is back, and keeps running when you log out of the console (`exit`).
3. Go back to the graphical session: `Ctrl + Alt + F1` (or `F2`, whichever shows your desktop), and unlock with your password.

## Welcome & Settings

**Perihelion Bar Welcome** (`perihelionbar-welcome`): a first-login tour with update and Settings shortcuts, a few optional extras (audio effects, graphics apps, video players, text editors), the keybindings and the project links.

**Perihelion Settings** (`perihelion-settings`): the bar's look and modules, the dock, desktop cards, colours, Updates, and pages for your window manager (keys, monitors, animations, rules, autostart, environment). On MangoWM it edits `~/.config/mango/cfg/` directly.

## Keybindings

The same on MangoWM (`~/.config/mango/cfg/keybinds.conf`) and Hyprland
(`~/.config/hypr/perihelion.lua`); `Super + H` lists every key.

| Keys | Action |
|---|---|
| `Super + Enter` | Terminal (kitty); `Super + Shift + Enter` floating |
| `Super + D` | App launcher |
| `Super + A` | App drawer |
| `Super + I` | Glance |
| `Alt + W` | Window overview |
| `Super + Shift + W` | Wallpapers |
| `Super + E` / `Super + B` | Files (Strata) / browser |
| `Super + L` | Lock the screen |
| `Super + Shift + Q` | Power menu |
| `Super + Shift + D` | Restart the bar and dock |
| `Super + Q` / `Super + W` / `Super + F` | Close / float / fullscreen |
| `Super + 1–9`, `Super + Shift + 1–9` | Workspaces, move window there |
| `Super + Shift + S`, `Print` | Screenshot: region, screen |
| `Super + G`, `Super + Shift + G` | Glass windows, blur strength (MangoWM) |

Both start the bar and its dock with `perihelion-bar-start` (run it again to restart
both), plus `perihelion-shell`, the app drawer, swayidle (lock after 10 minutes and
before suspend) and the dbus activation line the portals need.

## Credits

- The lock screen's design and much of its code (`perihelionbar-shell/src/lock/`): **Event Horizon**'s lock screen. Copyright and licence in [NOTICE.md](NOTICE.md).
- Palettes in `theme/palettes/`: **Event Horizon**'s colour themes (GPL-3.0), each crediting the scheme it is named after in `theme/palettes/NOTICE.md`. Monokai's are left out (no open licence).

## License

Perihelion Shell is free software under the [GNU General Public License v3.0](LICENSE):
you may redistribute and modify it under the terms of the GPL, version 3.
