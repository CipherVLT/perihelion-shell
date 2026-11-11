# Theming: colors matched to the wallpaper

`perihelion-theme` (repo root) has two styles:

- **Catppuccin** (default): a Catppuccin flavor from how light the wallpaper
  is and three Catppuccin accents from its strongest colors. Every color is
  a real Catppuccin color; the wallpaper only chooses which.
- **Material You**: matugen (simpbar's own engine) makes Material Design 3
  colors from the wallpaper, with its scheme types (tonal spot, vibrant, ...).

Either way they go to the bar, the cava wave, the desktop widgets, the app
drawer (nwg-drawer), fuzzel (launcher and power menu), Strata, Mango's
borders, fastfetch (the distro logo, labels and values), the terminal cava,
btop, cmatrix and notifications (mako).

| Key in `~/.config/simpbar/matugen.json` | Catppuccin color |
|---|---|
| bg_color | base |
| text_color | text |
| border_color, workspace_active_color, bezel_color | accent 1 |
| cava_color | accent 2 |
| matrix_color | accent 3 (the wave runs accent 1 → 2 → 3) |
| hover_color, module_bg_color | surface0 |
| popup_bg_color | mantle |
| popup_hover_color | surface1 |
| popup_separator_color | surface2 |
| workspace_inactive_color | overlay0 |
| popup_disabled_color | overlay1 |
| holiday_color | red |

Settings live in `~/.config/simpbar/theme`, written by Perihelion Settings:

```
style=catppuccin           # catppuccin (a palette), or material
flavor=auto                # Catppuccin: auto, latte, frappe, macchiato, mocha
accent=wallpaper           # Catppuccin: wallpaper, or flavor (blue, pink, yellow)
scheme=scheme-content      # Material You: matugen's --type
```

In Material You, accent 1 / 2 / 3 are primary / secondary / tertiary.

- `presets/` are the four flavors as fixed simpbar palettes, from Mirrez's
  simpbar-catppuccin-matugen package. The test checks the script's palette
  against them. `COLOR_MAP.md` is that package's role table.
- `test-perihelion-theme.py` runs in CI: picking, writing, and leaving
  hand-edited files alone.

Palette: https://catppuccin.com/palette (MIT).

## Event Horizon's colour themes, and your own palettes

`palettes/` holds Event Horizon's built-in colour themes (its "Custom Theme"
catalog: Catppuccin, Gruvbox, Rosé Pine, Dracula, Nord, Tokyo Night,
Solarized, Everforest, Kanagawa, Ayu, Atom, Night Owl, Sonokai, Andromeda
and the big Google set), one JSON file each, with stable ids from the path:
`catppuccin/mocha-sky`, `google/tokyo-night`, `google/tokyo-night-light`.
They come after the 14 built-in choices in Perihelion Settings' Palette row
(type to search) and work like the built-in palettes: the wallpaper orders
the three accents and, with Wallpaper tint on, tints the backgrounds.

Re-import after an Event Horizon release (one command; reads the table with
`git show`, so local patches in the checkout don't leak in):

```
theme/import-eh-palettes.py ~/src/Event-Horizon --ref <commit>
```

It writes the files, `SOURCE.json` (commit, counts, flagged palettes) and
`NOTICE.md` (credits). Hex values are converted exactly as Event Horizon
does (`rgbToHex`). Palettes whose text is hard to read (`low_contrast`,
WCAG below 4.5:1) or that Event Horizon files under Light on a dark
background (`light_mismatch`) are flagged; `perihelion-theme
--list-palettes` leaves the low-contrast ones out (`--all` shows them).
Licence: GPL-3.0 like Event Horizon, credits in `palettes/NOTICE.md`.

**Your own palettes:** put files of the same format in
`~/.local/share/perihelion/palettes/` (`$XDG_DATA_HOME/perihelion/palettes`).
A file there is `custom/<name>`; in a subfolder it's `<folder>/<name>`, and
the same id as a shipped palette replaces it. They show up in Perihelion
Settings (marked "yours") and follow the wallpaper like the rest; an edited
file recolors at the next wallpaper change or `perihelion-theme --force`.
Only `background`, `foreground` and `accent` are required:

```json
{
  "name": "Sunset",
  "light": false,
  "colors": {
    "background": "#1b1020", "foreground": "#f5e6ff", "accent": "#ff7a59",
    "accent2": "#ffb86c", "accent3": "#c792ea"
  },
  "ansi": ["#1b1020", "#ff5370", "#c3e88d", "#ffcb6b", "#82aaff", "#c792ea", "#89ddff", "#f5e6ff",
           "#4b3a55", "#ff5370", "#c3e88d", "#ffcb6b", "#82aaff", "#c792ea", "#89ddff", "#ffffff"]
}
```

| Key in `colors` | Event Horizon role | Used for |
|---|---|---|
| background | surface | base: bar, popups (mantle/crust are it mixed toward `shadow`) |
| foreground | on_surface | text |
| surface | surface_variant | surface0: module and hover backgrounds |
| surface_text | on_surface_variant | subtext0 (overlay1/2 sit between it and `outline`) |
| hover / hover_text | hover / on_hover | surface1 (surface2 is it mixed with `outline`) |
| outline | outline | overlay0: inactive workspaces |
| shadow | shadow | the darkest steps |
| accent, accent2, accent3 | primary, secondary, tertiary | the three accents (border, wave, matrix) |
| error | err | reserved; never picked as an accent |
| *_text | on_* | kept for exactness and later use |

Left out, `light` comes from the background; missing roles are mixed from
background and foreground. `ansi` (16 colors) sets the terminal's red to
cyan when Material You isn't there to; without it (all of Event Horizon's
themes) Catppuccin's are used, as in the Material You style.

Installed copies of `perihelion-theme` look in `/usr/share/perihelion/palettes`
(`$PERIHELION_THEME_SHARE/palettes`), so the ISO build has to install
`theme/palettes/` there (Perihelion's `build/install-simpbar.sh`); a git
checkout finds `theme/palettes/` next to the script.

## The terminal and fastfetch

Like Event Horizon, the terminal's palette is Material from the wallpaper in
both styles (matugen, dark, the chosen scheme: Content by default), laid out as Event Horizon's
matugen kitty template: color1 = base16 base08 darkened 20, color2/3 =
secondary/tertiary fixed-dim, color4-6 their dark tones. fastfetch keeps
Veyl OS's layout, which names terminal colors (OS 31, WM 32, PC and after 33,
the Fedora logo 34/37), so it follows the wallpaper through kitty. Without
matugen, tones of the theme's three accents stand in.
