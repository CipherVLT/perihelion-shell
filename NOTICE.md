# Notices

Perihelion Shell is licensed under the GNU General Public License v3.0
(see [LICENSE](LICENSE)). It includes work from these projects.

## simpbar

Perihelion Bar began as a fork of simpbar by jaytheoutpatient, used and changed with his permission.

## zig-wayland

`perihelionbar/zig-pkg/wayland-0.7.0-*` and `perihelionbar-shell/zig-pkg/wayland-0.7.0-*`
are zig-wayland 0.7.0, unchanged: the Wayland bindings and protocol scanner
both programs build with.

- Project: zig-wayland, https://codeberg.org/ifreund/zig-wayland
- Copyright © 2020 Isaac Freund
- Licence: MIT (its `LICENSE` file is kept beside the code)

## wlr-protocols

The Wayland protocol descriptions in `perihelionbar/protocols/` and
`perihelionbar-shell/protocols/`, from
https://gitlab.freedesktop.org/wlroots/wlr-protocols. Each file carries its
copyright and licence in its `<copyright>` block.

- `wlr-layer-shell-unstable-v1.xml`: Copyright © 2017 Drew DeVault; HPND-style
  permission notice (use, copy, modify, distribute and sell, with the
  notice kept).
- `wlr-screencopy-unstable-v1.xml`: Copyright © 2018 Simon Ser, © 2019 Andri
  Yngvason; MIT licence.

## Event Horizon: lock screen

`perihelionbar-shell/src/lock/` (perihelion-lockscreen) is a port of the
lock screen from Event Horizon 0.1.7: its design (the frosted-glass date,
clock, avatar, password pill and hint line) and its PAM worker, painter
and session-lock handling, rewritten for Perihelion's Wayland bindings,
theme and settings.

- Project: Event Horizon, https://github.com/Event-Horizon-desktop-environment/Event-Horizon
- Copyright © 2026 the Event Horizon contributors
- Licence: its `LICENSE` file is the GNU General Public License v3.0, while
  its README says "The code is MIT licensed". Perihelion uses it under the
  GPL-3.0 (the terms of the LICENSE file, and the same licence as this
  project); the MIT statement is noted here as the upstream README gives it.

Colour palettes in `theme/palettes/` have their own notices in
`theme/palettes/NOTICE.md`.
