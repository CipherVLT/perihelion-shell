# Perihelion Bar on Fedora

From a freshly installed Fedora to Perihelion Bar running on MangoWM.

Other guides: [Arch and Arch-based](arch.md) · [PikaOS](pikaos.md) · [Perihelion Linux](perihelion-linux.md) · [all distros and their CI status](../../README.md#install)

## What you need

- **Fedora 45 or later**: Workstation, Server or a spin. Fedora 45 with MangoWM is tested in CI on every change; later releases and Hyprland on Fedora are not tested in CI yet.
- Not the image-based editions (Silverblue, Kinoite, Bazzite): they can't install into `/usr`, and the installer stops there. **Perihelion Linux** ships Perihelion Bar ready to use instead; see [its guide](perihelion-linux.md).
- An x86_64 PC with an internet connection.
- A normal user account that can use `sudo` (the first account the Fedora installer creates is one, if you ticked "administrator"). Don't run the installer as root.
- **MangoWM** (default) or **Hyprland**; the installer installs the one you pick.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/CipherVLT/perihelion-shell/main/install.sh | bash
```

Or from a checkout (`sudo dnf install git` first if you don't have git):

```sh
git clone https://github.com/CipherVLT/perihelion-shell.git
cd perihelion-shell
./install.sh
```

The flags (`--yes`, `--wm=`, `--existing=`, `--rebuild`, `--extras`) are explained in the [README](../../README.md#quick-install).

### What each step does

Five numbered steps; everything is also written to `~/.local/state/perihelionbar/install.log`.

1. **Checking this system.** Recognises Fedora from `/etc/os-release`, checks the release (45 or later) and that it isn't an image-based system, and asks which window manager to set up.
2. **Packages.** Lists what is missing. If any of it comes from Terra and Terra isn't set up, it asks before adding it (see [Terra](#the-terra-repository)). Then, after you confirm, one `sudo dnf install --refresh` installs everything.
3. **Building Perihelion Bar.** Downloads Zig 0.17.1 from ziglang.org (the same official build on every distro), checks its minisign signature, keeps it in `~/.local/share/perihelionbar/zig-0.17.1`, builds the five programs and installs them with their scripts to `/usr/bin`, plus the lock screen's PAM file, the **Perihelion (MangoWM)** login session, icons and Perihelion's default configs under `/usr/share/perihelion/`.
4. **Your configs.** Writes the configs into your home folder (see [Existing configs](#existing-configs)).
5. **Starting with the session.** Checks that your Mango config starts Perihelion Bar, reports switched-off Control Center services, and sets up the hourly update check.

## Packages

| Purpose | Packages |
|---|---|
| Building | `git-core curl tar xz minisign pkgconf-pkg-config wayland-devel wayland-protocols-devel libxkbcommon-devel freetype-devel gdk-pixbuf2-devel gtk4-devel libadwaita-devel glib2-devel cairo-devel pango-devel pam-devel` |
| Window manager | `mangowm xdg-desktop-portal-wlr` (MangoWM, from Terra) or `hyprland xdg-desktop-portal-hyprland` |
| App drawer, theming | `quickshell`, `python3 python3-gobject`, `matugen` (Terra) |
| Session pieces | `mako mate-polkit swaybg swayidle wlsunset wlr-randr dbus-tools util-linux procps-ng` |
| Desktop tools the bar opens | `fuzzel kitty btop cmatrix fastfetch pavucontrol zenity jq libnotify` |
| Media, screenshots | `pipewire wireplumber pipewire-pulseaudio pulseaudio-utils cava playerctl brightnessctl grim slurp wl-clipboard` |
| Control Center | `NetworkManager bluez upower`, and `power-profiles-daemon` only when tuned, tuned-ppd, tlp and auto-cpufreq are all absent (Fedora Workstation ships tuned-ppd, which offers the same power profiles) |
| Fonts, icons, portals | `jetbrainsmono-nerd-fonts nerdfontssymbolsonly-nerd-fonts bibata-cursor-theme` (Terra), `dejavu-sans-mono-fonts rsms-inter-vf-fonts google-noto-sans-fonts google-noto-color-emoji-fonts librsvg2 adwaita-icon-theme qt6ct xdg-desktop-portal xdg-desktop-portal-gtk xdg-user-dirs xdg-utils xorg-x11-server-Xwayland polkit gnome-keyring gvfs` |

Weak dependencies are not installed. Not installed at all: graphics drivers, gaming packages, Flatpak. `--extras` adds `imv`, `blueman` and `wev`.

Not available on Fedora: **Strata**, the file manager on Super+E. The installer says so; bind another file manager in `~/.config/mango/cfg/keybinds.conf` if you want one there.

If a download fails (a mirror is behind, or the cached metadata is old), the installer explains it, offers `sudo dnf clean metadata` and one retry, and otherwise stops with what to do.

## The Terra repository

Five packages Perihelion Bar needs are not in Fedora's own repositories; they come from [Terra](https://terra.fyralabs.com), the community repository Perihelion Linux also uses:

- `mangowm` (MangoWM)
- `matugen` (colours from your wallpaper)
- `jetbrainsmono-nerd-fonts` and `nerdfontssymbolsonly-nerd-fonts` (the bar's font and icons)
- `bibata-cursor-theme` (the cursor)

The installer only adds Terra when one of these is missing and Terra isn't already set up, and it **asks first**. Saying no stops the installer, since these packages are required.

It adds Terra the way Terra's own documentation does: by installing the `terra-release` package from Terra itself, which brings the repository file and its signing keys.

**Add it by hand:**

```sh
sudo dnf install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release
```

(`$releasever` stays in single quotes; dnf fills in your Fedora release.) `--nogpgcheck` applies only to this first package, because its signing key is the thing being installed; everything from Terra afterwards is checked against that key.

**Remove it:** `sudo dnf remove terra-release` removes the repository and its keys. Packages you installed from Terra stay until you remove them.

## Start it

Log out, then pick **Perihelion (MangoWM)** on your login screen. GDM (Workstation) and SDDM (KDE and other spins) both list sessions from `/usr/share/wayland-sessions/`; in GDM the session list is behind the gear button after you click your name. The first time, it copies Perihelion's Mango config into `~/.config/mango` if you don't have one, then starts Mango, and `exec_once=perihelion-session-start` in `~/.config/mango/cfg/autostart.conf` starts the bar, dock, widgets, notifications, idle lock and the rest.

The stock **Mango** session (from the mangowm package) is listed too and works once `~/.config/mango` exists.

### First keys to try

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

The installer writes `~/.config/mango/`, `~/.config/perihelionbar/`, kitty, btop, GTK 3/4 and qt6ct settings, and first copies of the fuzzel, fastfetch and cava configs. A missing file is written, a matching one left alone; for a file of yours that differs you choose **keep mine**, **take the new one** (yours is copied to `~/.local/state/perihelionbar/backup-<date>/` first) or **write it beside mine** as `<file>.perihelion-new` (what `--yes` does by default). Answers are remembered in `~/.local/state/perihelionbar/installer-answers`.

## Update

- **Perihelion Settings → System → Updates** (see [Updates](../../README.md#updates)).
- Or run the installer again.

## Uninstall

There is no uninstall script. The installer lists every file it put outside your home folder in `~/.local/state/perihelionbar/installed-files`:

```sh
xargs -a ~/.local/state/perihelionbar/installed-files sudo rm -f
rm -rf ~/.local/share/perihelionbar ~/.cache/perihelionbar
systemctl --user disable --now perihelion-update-check.timer
rm -f ~/.config/systemd/user/perihelion-update-check.*
```

That covers `/usr/bin`, `/etc/pam.d/perihelion-lock`, the login session, launchers, icons and `/usr/share/perihelion/`. Restore your earlier configs with `cp -a ~/.local/state/perihelionbar/backup-<date>/. ~/`. Packages stay installed; remove the ones you don't want with `sudo dnf remove`, and Terra with `sudo dnf remove terra-release`.

## Troubleshooting

- **Install log:** `~/.local/state/perihelionbar/install.log`.
- **Session log:** `~/.config/perihelionbar-config/logs/perihelion-session-start/trace.log`.

Problems seen in testing:

- **"needs Fedora 45 or later" / "image-based (rpm-ostree) system"**: the installer stopped before changing anything. Use Fedora 45+ Workstation/Server, or Perihelion Linux.
- **dnf: a download fails** (Curl error, 404): accept the offered `dnf clean metadata` and retry; if it fails again, wait a little (a mirror is syncing) and run the installer again.
- **"JetBrainsMono Nerd Font not found"**: Terra wasn't added, so `jetbrainsmono-nerd-fonts` is missing. Add Terra (above) and run the installer again.
- **Nothing starts after logging in**: you picked the stock Mango session without a `~/.config/mango`. Log in once with **Perihelion (MangoWM)**.
- **The power-profile row is dim**: the row reads `powerprofilesctl list`. Run it in a terminal; if it fails, the power daemon on this system doesn't answer it (the installer leaves `power-profiles-daemon` out when tuned is installed, rather than replace your power manager).
