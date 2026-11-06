# Theming: Catppuccin matched to the wallpaper

`perihelion-theme` (repo root) picks a Catppuccin flavor from how light the
wallpaper is and three Catppuccin accents from its strongest colors, then
writes them to the bar, the cava wave, the desktop widgets, the app drawer
(nwg-drawer), fuzzel (launcher and power menu), Strata and Mango's borders.
Every color is a real Catppuccin color; the wallpaper only chooses which.

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

Settings live in `~/.config/simpbar/theme`, written by Simpbar Config:

```
flavor=auto        # auto, latte, frappe, macchiato, mocha
accent=wallpaper   # wallpaper, or flavor (blue, pink, yellow)
```

- `presets/` are the four flavors as fixed simpbar palettes, from Mirrez's
  simpbar-catppuccin-matugen package. The test checks the script's palette
  against them. `COLOR_MAP.md` is that package's role table.
- `test-perihelion-theme.py` runs in CI: picking, writing, and leaving
  hand-edited files alone.

Palette: https://catppuccin.com/palette (MIT).
