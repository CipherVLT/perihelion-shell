# Perihelion Bar on Arch Linux and Arch-based distros

From a freshly installed Arch-based system to Perihelion Bar running on MangoWM (or Hyprland).

Other guides: [Fedora](fedora.md) · [PikaOS](pikaos.md) · [Perihelion Linux](perihelion-linux.md) · [all distros and their CI status](../../README.md#install)

## What you need

- **Arch Linux**, or an Arch-based distro that uses pacman and Arch's package names: **CachyOS** (its v3 and v4 repositories work the same way), **EndeavourOS**, **Garuda**. Arch and CachyOS v3 are tested in CI on every change; the others take the same path but are not tested in CI (see the [table](../../README.md#install)).
- An x86_64 PC with an internet connection.
- A normal user account that can use `sudo`. Don't run the installer as root; it asks for your password when a step needs it.
- **MangoWM** or **Hyprland**. You don't need either installed beforehand: the installer installs the one you pick (MangoWM by default).
- Optional: an AUR helper (`paru` or `yay`) for the two AUR packages listed below.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/CipherVLT/perihelion-shell/main/install.sh | bash
```

Or from a checkout, if you'd like to read it first:

```sh
git clone https://github.com/CipherVLT/perihelion-shell.git
cd perihelion-shell
./install.sh
```

The flags (`--yes`, `--wm=`, `--existing=`, `--rebuild`, `--extras`) are explained in the [README](../../README.md#quick-install).

### What each step does

The installer prints a title and then five numbered steps. Everything it does is also written to `~/.local/state/perihelionbar/install.log`.

1. **Checking this system.** Recognises the distro from `/etc/os-release`, refuses to run as root, and asks which window manager to set up (it remembers the answer for next time).
2. **Packages.** Lists what is missing and, after you confirm, installs it in a single `sudo pacman -Syu --needed` (see [Packages](#packages-and-a-stale-database) below). Then the two AUR packages, if you have an AUR helper.
3. **Building Perihelion Bar.** Downloads Zig 0.17.1 from ziglang.org, checks its minisign signature, and keeps it in `~/.local/share/perihelionbar/zig-0.17.1`. Builds `perihelion-bar`, `perihelion-settings`, `perihelionbar-welcome`, `perihelion-shell` and `perihelion-lockscreen`, and installs them with their helper scripts to `/usr/bin`. Also installs the lock screen's PAM file (`/etc/pam.d/perihelion-lock`), the **Perihelion (MangoWM)** login session, app icons, and Perihelion's default configs under `/usr/share/perihelion/`. When the installed programs already match this commit, the build is skipped.
4. **Your configs.** Writes the configs into your home folder (see [Existing configs](#existing-configs)), and removes images that older versions left behind (only files whose checksum matches).
5. **Starting with the session.** Checks that your window manager config starts Perihelion Bar, reports Control Center services that are switched off (it never enables them for you), and sets up the hourly update check (`perihelion-update-check.timer`).

At the end it prints what it installed, what it wrote next to your own files, and the first keys to try.

## Packages and a stale database

### What is installed

Only what Perihelion Bar uses:

| Purpose | Packages |
|---|---|
| Building | `base-devel git curl tar xz minisign pkgconf`, and the libraries the programs link: `wayland wayland-protocols libxkbcommon freetype2 gdk-pixbuf2 gtk4 libadwaita glib2 cairo pango pam` |
| Window manager | `mangowm xdg-desktop-portal-wlr` (MangoWM) or `hyprland xdg-desktop-portal-hyprland` (Hyprland) |
| App drawer, theming | `quickshell`, `python python-gobject`, `matugen` |
| Session pieces | `mako` (notifications), `mate-polkit` (password prompts), `swaybg`, `swayidle`, `wlsunset`, `wlr-randr`, `dbus` |
| Desktop tools the bar opens | `fuzzel kitty btop cmatrix fastfetch pavucontrol zenity jq libnotify` |
| Media, screenshots | `pipewire wireplumber pipewire-pulse libpulse cava playerctl brightnessctl grim slurp wl-clipboard` |
| Control Center | `networkmanager bluez bluez-utils upower`, and `power-profiles-daemon` unless tlp, auto-cpufreq or tuned already manage power |
| Fonts, icons, portals | `ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols-mono ttf-dejavu inter-font noto-fonts noto-fonts-emoji librsvg adwaita-icon-theme qt6ct xdg-desktop-portal xdg-desktop-portal-gtk xdg-user-dirs xdg-utils xorg-xwayland polkit gnome-keyring gvfs` |
| AUR (only with paru or yay) | `strata-bin` (the file manager on Super+E), `bibata-cursor-theme-bin` (the cursor) |

Not installed: graphics drivers, gaming packages, 32-bit libraries, Flatpak. `--extras` adds an image viewer (`imv`), `blueman` and `wev`, which Perihelion Bar doesn't need.

Without an AUR helper the installer tells you which AUR packages it skipped; Super+E then opens nothing until you install a file manager.

### When a mirror answers 404

Installing from an out-of-date package database asks the mirrors for versions they have already replaced, and they answer 404. The installer always refreshes first (`-Syu`), but a mirror that lags behind can still cause it. When it happens, the installer:

1. says plainly that your mirror list or package database is out of date, and shows the files that failed;
2. offers to run `sudo pacman -Syyu` (a forced refresh of the database) and try once more;
3. if that fails too, stops and tells you which mirror tool to run, then to start the installer again.

Mirror tools it suggests:

- **CachyOS:** `sudo cachyos-rate-mirrors` (it ranks the mirrors for every CachyOS repository, including v3 and v4).
- **EndeavourOS:** `eos-rankmirrors`.
- **Others:** `rate-mirrors` or `reflector` if you have one, otherwise put a current mirror first in `/etc/pacman.d/mirrorlist`.

Nothing is installed halfway: pacman runs the whole transaction or none of it.

## Start it

Log out, then pick **Perihelion (MangoWM)** on your login screen. The first time, it copies Perihelion's Mango config into `~/.config/mango` if you don't have one, then starts Mango; the bar, dock, desktop widgets, notifications, the idle lock and the rest start from the one line `exec_once=perihelion-session-start` in `~/.config/mango/cfg/autostart.conf`.

The stock **Mango** session is still on the list. It works as well, as long as `~/.config/mango` exists (with no config there, Mango falls back to its own and starts nothing).

**Already have a Mango setup?** The installer offers Perihelion's files next to yours (see below). The two lines that matter are `exec_once=perihelion-session-start` in your autostart and the keybinds in `cfg/keybinds.conf`.

**Hyprland:** the installer writes `~/.config/hypr/perihelion.lua` and adds one line, `require("perihelion")`, to the end of your `hyprland.lua` (on Hyprland 0.55 or 0.56 with only a `hyprland.conf`, it writes `perihelion.conf` and a `source =` line instead). Nothing else in your file changes.

### First keys to try (MangoWM)

| Keys | Action |
|---|---|
| Super + Enter | Terminal (kitty) |
| Super + D | App launcher |
| Super + A | App drawer |
| Super + I | Glance |
| Alt + W | Window overview |
| Super + Shift + W | Wallpapers |
| Super + L | Lock the screen |
| Super + Shift + Q | Power menu |
| Super + H | Every key |
| Super + Shift + D | Restart the bar and dock |

## Existing configs

Files the installer writes in your home folder: `~/.config/mango/` (config.conf and cfg/), `~/.config/perihelionbar/`, kitty, btop, GTK 3/4 and qt6ct settings, and first copies of the fuzzel, fastfetch and cava configs.

A missing file is written; a file that already matches is left alone. For a file of yours that differs, you choose:

- **Keep mine.**
- **Take the new one.** Yours is first copied to `~/.local/state/perihelionbar/backup-<date>/`, under the same path.
- **Write it beside mine** as `<file>.perihelion-new`, to compare and merge yourself. This is what `--yes` does unless you pass `--existing=keep` or `--existing=new`.

The answers are remembered in `~/.local/state/perihelionbar/installer-answers`; a file you edit later is asked about again.

## Update

- **Perihelion Settings → System → Updates** checks the GitHub releases, verifies a download and installs it (one password prompt). See [Updates](../../README.md#updates).
- Or run the installer again: it updates the programs to the current commit and leaves matching files alone.

## Uninstall

There is no uninstall script. Everything the installer put outside your home folder is listed, one path per line, in `~/.local/state/perihelionbar/installed-files`:

```sh
xargs -a ~/.local/state/perihelionbar/installed-files sudo rm -f
```

That removes the programs in `/usr/bin`, `/etc/pam.d/perihelion-lock`, `/usr/share/wayland-sessions/perihelion.desktop`, the launchers in `/usr/share/applications`, the icons, and `/usr/share/perihelion/`. Then, in your home folder:

- `rm -rf ~/.local/share/perihelionbar ~/.cache/perihelionbar` (Zig, the app drawer's QML, the build cache)
- `systemctl --user disable --now perihelion-update-check.timer`, then delete `~/.config/systemd/user/perihelion-update-check.*`
- your configs from before: `cp -a ~/.local/state/perihelionbar/backup-<date>/. ~/`
- on Hyprland, the `require("perihelion")` (or `source =`) line in your Hyprland config

Packages stay installed; remove the ones you don't want with `sudo pacman -Rns <package>`.

## Troubleshooting

- **Install log:** `~/.local/state/perihelionbar/install.log`. A failing step stops the installer and shows its last lines.
- **Session log:** `~/.config/perihelionbar-config/logs/perihelion-session-start/trace.log` lists what started at login, what was already running and what is missing.

Problems seen in testing:

- **pacman: 404 for a package** (for example `vulkan-intel` on CachyOS with a stale database): see [When a mirror answers 404](#when-a-mirror-answers-404).
- **Nothing starts after logging in**: you picked the stock Mango session and have no `~/.config/mango`. Log in with **Perihelion (MangoWM)** once; it writes the config.
- **"a question needs a terminal"**: the installer was piped without a keyboard (for example over a non-interactive SSH session). Add `--yes` after `bash -s --`.
- **"Quickshell has crashed, likely due to a Qt version mismatch. Runtime Qt version 6.12.1, buildtime Qt version 6.12.0."** Only the app drawer (Super+A) uses Quickshell. The bar, dock and cards keep running. Qt was updated before your repository rebuilt Quickshell for it, and Quickshell must run on the exact Qt it was built with. `quickshell -V -v` shows both versions (`Qt: 6.12.1 (built against 6.12.0)`), and the installer's report warns about it. Fix: run `sudo pacman -Syu`. If it persists, wait for the repo rebuild, or rebuild Quickshell from the AUR (`paru -S quickshell-git --rebuild`). The app drawer no longer leaves the crash dialog on the desktop. The crash is logged to the session log above instead, and Super+A tries again.
- **Small dots along the focused window's border, or rough window corners** (seen with NVIDIA's proprietary driver): SceneFX, which draws Mango's rounded corners, mis-renders rounded borders on some NVIDIA setups ([wlrfx/scenefx#233](https://github.com/wlrfx/scenefx/issues/233), no fixed release yet). A smaller radius makes them go away; 0 (square, Perihelion's default) always does. Set **Corner radius** in Perihelion Settings → Mango → Decoration, or `border_radius=` in `~/.config/mango/cfg/appearance.conf`. To try a value without saving it: `mmsg dispatch setoption,border_radius,4`. Configs from before the default changed keep their radius; the installer's report mentions it on NVIDIA.
- **A Control Center row is dim**: its service is off. The installer's report names it, for example `sudo systemctl enable --now bluetooth.service`.
- **Super+E does nothing**: Strata (from the AUR) isn't installed. Install it with your AUR helper, or bind another file manager in `~/.config/mango/cfg/keybinds.conf`.
