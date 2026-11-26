# Perihelion Bar on Perihelion Linux

Perihelion Linux (the Fedora-based ISO) ships Perihelion Bar as part of the system. There is nothing to install.

Other guides: [Arch and Arch-based](arch.md) · [Fedora](fedora.md) · [PikaOS](pikaos.md) · [all distros and their CI status](../../README.md#install)

## What you get

- Perihelion Bar, its dock, the desktop widgets, Glance, the window overview, Perihelion Settings, the lock screen and the app drawer, already installed in `/usr/bin`.
- The **Perihelion (MangoWM)** login session, preselected on the login screen. The stock **Mango** session is also listed.
- Your account's configs in `~/.config` (Mango, Perihelion Bar, kitty, fuzzel, btop), copied at install time. Accounts created later get them too, from `/etc/skel` or, if they are missing, from the login session at the first login.

The ISO build rehearses this whole install in CI (packages, the setup scripts, a user created after installing) before an image is made.

## Don't run the installer here

If you run `install.sh` on Perihelion Linux anyway, it recognises the system (by `/usr/share/perihelion/perihelionbar.ref`), says that Perihelion Bar is already installed, and stops without changing anything. Installing a second copy over the system's own would fight the image.

## Start it

Log in with **Perihelion (MangoWM)**. `~/.config/mango/cfg/autostart.conf` holds one line, `exec_once=perihelion-session-start`, which starts the bar, dock, widgets, notifications, the password prompt agent, the idle lock and the rest.

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

## Update

Perihelion Bar is updated with the system. **Perihelion Settings → System → Updates** shows the installed version and checks for new releases, but on Perihelion Linux the shell itself comes with system updates rather than from that page.

## Your configs

Your files in `~/.config` are yours to edit; Perihelion Settings edits the Mango ones (`~/.config/mango/cfg/`) directly. The originals stay in `/usr/share/perihelion/`, so you can always compare or copy one back, for example `cp /usr/share/perihelion/mango/cfg/keybinds.conf ~/.config/mango/cfg/`.

## Troubleshooting

- **Session log:** `~/.config/perihelionbar-config/logs/perihelion-session-start/trace.log` lists what started at login, what was already running and what is missing.
- **Login session log:** `~/.config/perihelionbar-config/logs/perihelion-session/trace.log` says whether the session used your Mango config or wrote a new one.
- **Nothing starts after logging in**: you picked the stock Mango session and `~/.config/mango` is missing. Log in once with **Perihelion (MangoWM)**; it writes the config.
- **A piece stopped** (the bar, the dock, the widgets): run `perihelion-session-start` in a terminal; it starts only what isn't running. `Super + Shift + D` restarts the bar and dock.
