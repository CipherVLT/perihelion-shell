# Catppuccin → simpbar color map

simpbar reads a flat JSON of named keys from `~/.config/simpbar/matugen.json`.
There is no internal Catppuccin (or named-palette) registry yet — only these keys.

| simpbar key                 | Suggested Catppuccin role      | Notes                          |
|----------------------------|--------------------------------|--------------------------------|
| `bg_color`                 | `base` / `mantle`              | Bar background                 |
| `text_color`               | `text`                         | Primary text                   |
| `border_color`             | `lavender` / `blue`            | Accent / border                |
| `hover_color`              | `surface1` / `overlay0`        | Hover / active pill            |
| `holiday_color`            | `red`                          | Error / holiday                |
| `cava_color`               | `mauve` / `pink`               | Visualizer                     |
| `module_bg_color`          | `surface0`                     | Module pills                   |
| `workspace_active_color`   | `lavender` / `mauve`           | Active workspace               |
| `workspace_inactive_color` | `overlay0` / `subtext0`        | Inactive workspace             |
| `popup_bg_color`           | `mantle` / `surface0`          | Popups                         |
| `popup_hover_color`        | `surface1`                     | Popup hover                    |
| `popup_separator_color`    | `overlay0`                     | Separators                     |
| `popup_disabled_color`     | `overlay1`                     | Disabled text                  |
| `bezel_color`              | `lavender` / `sapphire` / `blue` | Bezel ring                   |
| `matrix_color`             | `teal` / `green`               | Extra accent                   |

## Official Catppuccin reference

- Palette site: https://catppuccin.com/palette/
- Flavors: Latte (light), Frappé, Macchiato, Mocha (darkest)

## Why wallpaper colors can look “wrong”

simpbar only consumes the keys above. Matugen produces Material You roles
(`primary`, `surface`, `on_surface`, …). The upstream template maps those
roles into the keys. When you want a *named* Catppuccin look, use the static
presets in `presets/` instead of (or after) a matugen run.
