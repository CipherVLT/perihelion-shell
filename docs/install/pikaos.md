# Perihelion Bar on PikaOS

From a freshly installed PikaOS to Perihelion Bar running on MangoWM.

> **Experimental, not tested in CI.** There is no official PikaOS container image, so unlike Arch and Fedora this path is not installed end to end on every change. Each package name below was checked against PikaOS's own repository index; the install itself needs testing on a real PikaOS machine. Please report what you find.

Other guides: [Arch and Arch-based](arch.md) · [Fedora](fedora.md) · [Perihelion Linux](perihelion-linux.md) · [all distros and their CI status](../../README.md#install)

## What you need

- **PikaOS 4** (codename Nest; `/etc/os-release` says `ID=pika`). PikaOS is a rolling distro built on Debian sid, with its own repository (`ppa.pika-os.com`) and `apt`, which its `pikman` tool wraps. The installer uses `apt-get` directly.
- An up-to-date system works best: run `pikman upgrade` (or `sudo apt full-upgrade`) before installing.
- An x86_64 PC with an internet connection, and a normal user account that can use `sudo`. Don't run the installer as root.
- **MangoWM** (default) or **Hyprland**; both are in PikaOS's repository and the installer installs the one you pick.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/CipherVLT/perihelion-shell/main/install.sh | bash
```

Or from a checkout:

```sh
git clone https://github.com/CipherVLT/perihelion-shell.git
cd perihelion-shell
./install.sh
```

The flags (`--yes`, `--wm=`, `--existing=`, `--rebuild`, `--extras`) are explained in the [README](../../README.md#quick-install).

### What each step does

1. **Checking this system.** Recognises PikaOS by `ID=pika` (other Debian-based distros are not supported and the installer stops), checks for PikaOS 4 or later, and asks which window manager to set up.
2. **Packages.** `sudo apt-get update`, then the missing packages in one `sudo apt-get install --no-install-recommends`, after you confirm. Then the JetBrainsMono Nerd Font, which PikaOS doesn't package (see [The bar's font](#the-bars-font)).
3. **Building Perihelion Bar.** Downloads Zig 0.17.1 from ziglang.org (the same official build on every distro), checks its minisign signature, builds the five programs and installs them with their scripts to `/usr/bin`, plus the lock screen's PAM file, the **Perihelion (MangoWM)** login session, icons and the default configs under `/usr/share/perihelion/`.
4. **Your configs.** Writes the configs into your home folder (see [Existing configs](#existing-configs)).
5. **Starting with the session.** Checks your Mango config, reports switched-off Control Center services, and sets up the hourly update check.

Everything is written to `~/.local/state/perihelionbar/install.log`.

## Packages

All from PikaOS's own repository, including MangoWM, Quickshell and matugen. No third-party repository is added.

| Purpose | Packages |
|---|---|
| Building | `build-essential git curl tar xz-utils minisign pkgconf libwayland-dev wayland-protocols libxkbcommon-dev libfreetype-dev libgdk-pixbuf-2.0-dev libgtk-4-dev libadwaita-1-dev libglib2.0-dev libcairo2-dev libpango1.0-dev libpam0g-dev` |
| Window manager | `mangowm xdg-desktop-portal-wlr` (MangoWM) or `hyprland xdg-desktop-portal-hyprland` |
| App drawer, theming | `quickshell`, `python3 python3-gi gir1.2-gtk-4.0`, `matugen` |
| Session pieces | `mako-notifier mate-polkit swaybg swayidle wlsunset wlr-randr dbus-bin dbus-user-session util-linux procps systemd` |
| Desktop tools the bar opens | `fuzzel kitty btop cmatrix fastfetch pavucontrol zenity jq libnotify-bin` |
| Media, screenshots | `pipewire wireplumber pipewire-pulse pulseaudio-utils cava playerctl brightnessctl grim slurp wl-clipboard` |
| Control Center | `network-manager bluez upower`, and `power-profiles-daemon` unless tuned, tlp or auto-cpufreq is installed |
| Fonts, icons, portals | `fontconfig fonts-nerd-symbols fonts-dejavu-core fonts-inter fonts-noto-core fonts-noto-color-emoji librsvg2-common adwaita-icon-theme bibata-cursor-theme qt6ct xdg-desktop-portal xdg-desktop-portal-gtk xdg-user-dirs xdg-utils xwayland polkitd gnome-keyring gvfs` |

Recommended packages are not installed. Not installed at all: graphics drivers, gaming packages, Flatpak. `--extras` adds `imv`, `blueman` and `wev`.

**Not available on PikaOS:**

- **The JetBrainsMono Nerd Font**: downloaded, see below.
- **Strata**, the file manager on Super+E: skipped, and the installer says so. Bind another file manager in `~/.config/mango/cfg/keybinds.conf` if you want one there.

If a download fails (the package lists are older than the repository), the installer explains it, offers `apt-get clean`, a fresh `apt-get update` and one retry, and otherwise stops and suggests `pikman upgrade` first.

## The bar's font

Perihelion Bar draws its text and icons with `JetBrainsMonoNerdFont-Regular.ttf`. PikaOS packages plain JetBrains Mono and the Nerd Font symbols, but not the JetBrainsMono Nerd Font. So the installer **asks**, then:

1. downloads `JetBrainsMono.tar.xz` from the official Nerd Fonts release v3.5.1 (`github.com/ryanoasis/nerd-fonts`);
2. checks its SHA-256 against the value pinned in the installer (`04d5e8f9…10cf`, the one Nerd Fonts publish for that release) and installs nothing if it doesn't match;
3. installs the JetBrainsMono Nerd Font files and their licence (SIL Open Font License) to `/usr/local/share/fonts/JetBrainsMonoNerdFont/` and refreshes the font cache.

Saying no stops the installer, since the bar can't draw without the font. These files are listed for uninstalling like everything else.

## Start it

Log out, then pick **Perihelion (MangoWM)** on your login screen (it reads sessions from `/usr/share/wayland-sessions/`, where the stock **Mango** session from the mangowm package also is). The first time, it copies Perihelion's Mango config into `~/.config/mango` if you don't have one, then starts Mango; `exec_once=perihelion-session-start` in `~/.config/mango/cfg/autostart.conf` starts the bar, dock, widgets, notifications (mako), the password prompt agent (`/usr/libexec/polkit-mate-authentication-agent-1` on PikaOS), the idle lock and the rest.

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

The installer writes `~/.config/mango/`, `~/.config/perihelionbar/`, kitty, btop, GTK 3/4 and qt6ct settings, and first copies of the fuzzel, fastfetch and cava configs. For a file of yours that differs you choose **keep mine**, **take the new one** (yours is copied to `~/.local/state/perihelionbar/backup-<date>/` first) or **write it beside mine** as `<file>.perihelion-new` (what `--yes` does by default).

## Update

- **Perihelion Settings → System → Updates** (see [Updates](../../README.md#updates)).
- Or run the installer again.

## Uninstall

There is no uninstall script. Every file the installer put outside your home folder, the downloaded font included, is listed in `~/.local/state/perihelionbar/installed-files`:

```sh
xargs -a ~/.local/state/perihelionbar/installed-files sudo rm -f
sudo fc-cache -f
rm -rf ~/.local/share/perihelionbar ~/.cache/perihelionbar
systemctl --user disable --now perihelion-update-check.timer
rm -f ~/.config/systemd/user/perihelion-update-check.*
```

Restore your earlier configs with `cp -a ~/.local/state/perihelionbar/backup-<date>/. ~/`. Packages stay installed; remove the ones you don't want with `sudo apt remove`.

## Troubleshooting

- **Install log:** `~/.local/state/perihelionbar/install.log`.
- **Session log:** `~/.config/perihelionbar-config/logs/perihelion-session-start/trace.log`.

What to look out for (this path hasn't been through CI):

- **apt: "Failed to fetch … 404 Not Found"**: the package lists are behind the repository. Accept the offered refresh; if it fails again, run `pikman upgrade` and then the installer.
- **apt wants to remove or hold back packages**: on a rolling distro an out-of-date system can conflict with new packages. Update the system first (`pikman upgrade`), then run the installer again.
- **"JetBrainsMono Nerd Font not found"**: the font download was declined or failed. Run the installer again and accept it.
- **Nothing starts after logging in**: you picked the stock Mango session without a `~/.config/mango`. Log in once with **Perihelion (MangoWM)**.
