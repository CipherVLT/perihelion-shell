"""Tests for perihelion-theme. Run: python3 -I theme/test-perihelion-theme.py

Builds small PNGs (no image libraries needed to make them), runs the script
in a throwaway home folder and checks what it picks and what it writes."""

import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
import importlib.util
from importlib.machinery import SourceFileLoader

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "perihelion-theme")
_loader = SourceFileLoader("perihelion_theme", SCRIPT)
pt = importlib.util.module_from_spec(importlib.util.spec_from_loader("perihelion_theme", _loader))
_loader.exec_module(pt)
failures = 0


def check(cond, what):
    global failures
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures += 1


def png(path, pixel_fn, w=64, h=64):
    raw = b"".join(b"\x00" + b"".join(bytes(pixel_fn(x, y)) for x in range(w)) for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def run(home, *args):
    env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=os.path.join(home, ".config"),
               XDG_CACHE_HOME=os.path.join(home, ".cache"),
               PERIHELION_THEME_SHARE=os.path.join(home, "share"))
    env.pop("MANGO_INSTANCE_SIGNATURE", None)
    return subprocess.run([sys.executable, "-I", SCRIPT, *args], env=env,
                          capture_output=True, text=True, check=False)


def dry(home, *args):
    r = run(home, "--dry-run", *args)
    if r.returncode != 0:
        print(r.stderr)
    return json.loads(r.stdout)


# 1. The palette matches the four presets shipped in theme/presets.
for flavor in pt.FLAVORS:
    with open(os.path.join(ROOT, "theme", "presets", flavor + ".json"), encoding="utf-8") as f:
        preset = json.load(f)
    vals = set(pt.PALETTES[flavor].values())
    check(all(v.lstrip("#").lower() in vals for v in preset.values()),
          f"{flavor}: every preset color is a Catppuccin {flavor} color")
    check(len(pt.PALETTES[flavor]) == 26, f"{flavor}: all 26 colors")

tmp = tempfile.mkdtemp()
try:
    home = os.path.join(tmp, "home")
    os.makedirs(home)
    img = lambda n: os.path.join(tmp, n)  # noqa: E731

    # 2. Picking.
    png(img("dark-red.png"), lambda x, y: (200, 30, 40) if x < 20 else (18, 18, 24))
    d = dry(home, img("dark-red.png"))
    check(d["flavor"] == "mocha", f"dark picture -> mocha ({d['flavor']})")
    check(d["accents"][0] in ("red", "maroon", "flamingo"), f"red streak -> red accent ({d['accents'][0]})")
    check(len(set(d["accents"])) == 3, "three different accents")

    png(img("light.png"), lambda x, y: (235, 238, 245) if y > 10 else (40, 110, 230))
    d = dry(home, img("light.png"))
    check(d["flavor"] == "latte", f"light picture -> latte ({d['flavor']})")
    check(d["accents"][0] in ("blue", "sapphire", "sky", "lavender"), f"blue band -> blue accent ({d['accents'][0]})")

    png(img("grey.png"), lambda x, y: ((x * 3) % 200,) * 3)
    d = dry(home, img("grey.png"))
    check(d["accents"] == ["blue", "pink", "yellow"], f"grey picture -> Perihelion's accents ({d['accents']})")

    png(img("green-purple.png"), lambda x, y: (60, 170, 70) if x < 32 else (140, 70, 200))
    d = dry(home, img("green-purple.png"), "--flavor", "macchiato")
    check(d["flavor"] == "macchiato", "--flavor is honored")
    check({"green"} <= set(d["accents"]) and ({"mauve", "lavender"} & set(d["accents"])),
          f"green and purple both picked ({d['accents']})")
    d = dry(home, img("green-purple.png"), "--accent", "flavor")
    check(d["accents"] == ["blue", "pink", "yellow"], "--accent flavor -> blue, pink, yellow")
    d = dry(home, "--color", "#24273a")
    check(d["flavor"] in ("mocha", "macchiato"), f"plain dark color -> dark flavor ({d['flavor']})")

    # 3. Writing, in a home laid out like a fresh Perihelion install.
    cfg = os.path.join(home, ".config")
    share = os.path.join(home, "share")
    os.makedirs(os.path.join(share, "fuzzel"))
    shipped_fuzzel = "[main]\nfont=Noto Sans:size=12\n\n[colors]\nbackground=24273add\ntext=cad3f5ff\n\n[border]\nwidth=2\n"
    for rel, text in (("fuzzel/fuzzel.ini", shipped_fuzzel),):
        with open(os.path.join(share, rel), "w", encoding="utf-8") as f:
            f.write(text)
        os.makedirs(os.path.dirname(os.path.join(cfg, rel)), exist_ok=True)
        with open(os.path.join(cfg, rel), "w", encoding="utf-8") as f:
            f.write(text)
    os.makedirs(os.path.join(cfg, "mango"))
    os.makedirs(os.path.join(cfg, "kitty"))
    with open(os.path.join(cfg, "mango", "config.conf"), "w", encoding="utf-8") as f:
        f.write("focus_color=0x8aadf4ff\n")
    os.makedirs(os.path.join(cfg, "simpbar"))
    with open(os.path.join(cfg, "simpbar", "theme"), "w", encoding="utf-8") as f:
        f.write("flavor=macchiato\naccent=wallpaper\ntint=off\n")

    r = run(home, img("green-purple.png"))
    check(r.returncode == 0, "full run succeeds" + ("" if r.returncode == 0 else ": " + r.stderr))
    with open(os.path.join(cfg, "simpbar", "matugen.json"), encoding="utf-8") as f:
        mj = json.load(f)
    check(len([k for k in mj if k.endswith("_color")]) == 15 and mj["bg_color"] == "#24273a", "matugen.json: 15 keys, Macchiato base (theme file honored)")
    check(mj["bezel_color"] != mj["cava_color"] != mj["matrix_color"], "wave gradient gets three colors")
    check(all(mj.get(k, "").startswith("#") for k in ("popup_bg_color", "popup_hover_color", "popup_separator_color")),
          "matugen.json carries the app drawer's popup colors")
    check(not os.path.exists(os.path.join(cfg, "nwg-drawer", "drawer.css")), "no nwg-drawer CSS any more")
    fz = pt.read(os.path.join(cfg, "fuzzel", "fuzzel.ini"))
    check("[main]\nfont=Noto Sans:size=12" in fz and "[border]\nwidth=2" in fz, "fuzzel.ini: other sections untouched")
    check("border=" + mj["border_color"].lstrip("#") + "ff" in fz, "fuzzel.ini: colors follow the accent")
    st = pt.read(os.path.join(cfg, "strata", "themes", "tokyo-night.toml"))
    check(st and 'accent = "' + mj["border_color"] + '"' in st, "Strata theme written")
    mc = pt.read(os.path.join(cfg, "mango", "config.conf"))
    check(mc.count("source_optional=~/.config/mango/colors.conf") == 1, "Mango config sources colors.conf")
    check("focus_color=0x" + mj["border_color"].lstrip("#") in pt.read(os.path.join(cfg, "mango", "colors.conf")),
          "Mango border follows the accent")

    # 4. Second run: nothing changes; a different wallpaper changes everything.
    before = {p: pt.read(os.path.join(cfg, p)) for p in ("simpbar/matugen.json", "mango/config.conf")}
    run(home, img("green-purple.png"), "--force")
    check(all(pt.read(os.path.join(cfg, p)) == t for p, t in before.items()), "same wallpaper: same files, source line not repeated")
    run(home, img("dark-red.png"))
    check(pt.read(os.path.join(cfg, "simpbar", "matugen.json")) != before["simpbar/matugen.json"], "new wallpaper: new colors")

    # 5. Hand-edited files are left alone; "manual" turns it all off.
    with open(os.path.join(cfg, "fuzzel", "fuzzel.ini"), "w", encoding="utf-8") as f:
        f.write("[colors]\nbackground=000000ff\n")
    run(home, img("light.png"))
    check(pt.read(os.path.join(cfg, "fuzzel", "fuzzel.ini")) == "[colors]\nbackground=000000ff\n", "edited fuzzel colors kept")
    with open(os.path.join(cfg, "simpbar", "config.json"), "w", encoding="utf-8") as f:
        json.dump({"appearance": {"auto_theme": "manual"}}, f)
    snap = pt.read(os.path.join(cfg, "simpbar", "matugen.json"))
    r = run(home, img("green-purple.png"), "--force")
    check(pt.read(os.path.join(cfg, "simpbar", "matugen.json")) == snap and "off" in r.stdout, "auto_theme manual: nothing written")

    # 6. fastfetch: Veyl OS's terminal-color layout (OS 31, WM 32, PC and
    # after 33), kept as is or restored from older 24-bit files.
    os.remove(os.path.join(cfg, "simpbar", "config.json"))
    os.makedirs(os.path.join(share, "fastfetch"))
    veyl = """{
    "logo": {
        "padding": { "top": 3 }
    },
    "display": {
          "separator": " ➜  "
    },
    "modules": [
        "break",
        "break",
        "break",
         {
            "type": "os",
            "key": "OS   ",
            "keyColor": "31",  // = color1
        },
        "break",
        {
            "type": "wm",
            "key": "WM   ",
            "keyColor": "32",
        },
        "break",
        {
            "type": "host",
            "format": "{5} {1} Type {2}",
            "key": "PC   ",
            "keyColor": "33",
        },
        "break",
        {
            "type": "command",
            "format": "OS Age: {result}",
            "keyColor": "33",
        }
    ]
}
"""
    old = veyl.replace('"keyColor": "31"', '"keyColor": "1;38;2;237;135;150"').replace(
        '"keyColor": "32"', '"keyColor": "1;38;2;238;212;159"').replace(
        '"keyColor": "33"', '"keyColor": "1;38;2;238;212;159"').replace(
        '"padding": { "top": 3 }', '"padding": { "top": 3 },\n        "color": { "1": "38;2;95;117;166", "2": "38;2;138;173;244" }').replace(
        '"separator": " ➜  "', '"separator": " ➜  ",\n          "color": { "title": "1;38;2;138;173;244", "output": "38;2;194;206;245", "separator": "38;2;128;135;162" }')
    old = pt.FASTFETCH_NOTE + "\n" + old
    with open(os.path.join(share, "fastfetch", "config.jsonc"), "w", encoding="utf-8") as f:
        f.write(veyl)
    os.makedirs(os.path.join(cfg, "fastfetch"), exist_ok=True)
    ff_path = os.path.join(cfg, "fastfetch", "config.jsonc")
    with open(ff_path, "w", encoding="utf-8") as f:
        f.write(old)
    run(home, img("green-purple.png"), "--force")
    check(pt.read(ff_path) == veyl, "fastfetch: an older 24-bit file goes back to Veyl's terminal-color layout")
    run(home, img("dark-red.png"), "--force")
    check(pt.read(ff_path) == veyl, "fastfetch: Veyl's layout is left as is")
    with open(ff_path, "w", encoding="utf-8") as f:
        f.write(veyl.replace('"keyColor": "31"', '"keyColor": "35"'))
    run(home, img("light.png"), "--force")
    check('"keyColor": "35"' in pt.read(ff_path), "fastfetch: a hand-edited file is kept")

    # kitty carries the colors: Event Horizon's slots
    kc = pt.read(os.path.join(cfg, "kitty", "perihelion-colors.conf"))
    slots = dict(line.split(None, 1) for line in kc.splitlines() if line and not line.startswith("#"))
    check(all(f"color{i}" in slots for i in range(16)), "kitty: all 16 colors")
    check(len({slots["color1"].strip(), slots["color2"].strip(), slots["color3"].strip()}) == 3,
          f"kitty: OS/WM/PC colors differ ({slots['color1'].strip()}, {slots['color2'].strip()}, {slots['color3'].strip()})")
    check(pt.hsl_lighten("#808080", -20.0) == "#4d4d4d", "matugen's lighten: HSL lightness minus 20 points")
    # the last run was the light wallpaper: the terminal stays dark and readable
    lum = lambda h: pt.lch(pt.hex_rgb(h.strip().lstrip("#")))[0]  # noqa: E731
    check(lum(slots["background"]) < 0.35, f"kitty, light wallpaper: dark background ({slots['background'].strip()})")
    check(all(lum(slots[k]) > 0.6 for k in ("foreground", "color1", "color2", "color3")),
          "kitty, light wallpaper: text and fastfetch sections readable on it")
    check(float(slots["background_opacity"]) >= 0.9, "kitty, light wallpaper: less see-through")
    run(home, img("dark-red.png"), "--force")
    kc = pt.read(os.path.join(cfg, "kitty", "perihelion-colors.conf"))
    slots = dict(line.split(None, 1) for line in kc.splitlines() if line and not line.startswith("#"))
    check(lum(slots["color1"]) > 0.55, f"kitty: the OS color is bright enough to read ({slots['color1'].strip()})")
    check(float(slots["background_opacity"]) <= 0.82, "kitty, dark wallpaper: Perihelion's usual glass")
    check(lum(pt.ok_band("#401010", 0.66, 0.78)) >= 0.65, "ok_band lifts a too-dark red")
    check(lum(pt.ok_band("#20207a", 0.66, 0.78)) >= 0.65, "ok_band lifts a too-dark blue the same")

    # 6b. terminal cava, btop, cmatrix
    cava_default = "[color]\ngradient = 1\ngradient_count = 3\ngradient_color_1 = '#8aadf4'\ngradient_color_2 = '#f5bde6'\ngradient_color_3 = '#eed49f'\n"
    for d in (os.path.join(share, "cava"), os.path.join(cfg, "cava")):
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "config"), "w", encoding="utf-8") as f:
            f.write(cava_default)
    run(home, img("green-purple.png"), "--flavor", "mocha", "--force")
    with open(os.path.join(cfg, "simpbar", "matugen.json"), encoding="utf-8") as f:
        mj = json.load(f)
    cv = pt.read(os.path.join(cfg, "cava", "config"))
    check(f"gradient_color_1 = '{mj['bezel_color']}'" in cv and f"gradient_color_3 = '{mj['matrix_color']}'" in cv,
          "cava: terminal gradient = the bar wave's accents")
    check(cv.count("perihelion-theme") == 1 and cv.startswith("[color]"), "cava: one note line, rest kept")
    bt = pt.read(os.path.join(cfg, "btop", "themes", "perihelion.theme"))
    check(bt and f'theme[main_bg]="{mj["bg_color"]}"' in bt and f'theme[hi_fg]="{mj["bezel_color"]}"' in bt,
          "btop: theme follows the palette")
    check(len(re.findall(r'^theme\[\w+\]="#[0-9a-f]{6}"$', bt, re.M)) == 42, "btop: 42 well-formed theme keys")
    cm = pt.read(os.path.join(cfg, "perihelion", "cmatrix-color")).strip()
    check(cm in ("red", "yellow", "green", "cyan", "blue", "magenta", "white"), f"cmatrix: named color ({cm})")
    check(pt.cmatrix_color(pt.build_theme("macchiato", ["blue", "pink", "yellow"])) == "blue", "cmatrix: blue accent -> blue")
    check(pt.cmatrix_color(pt.build_theme("macchiato", ["green", "pink", "yellow"])) == "green", "cmatrix: green accent -> green")

    mk = pt.mako_config(pt.build_theme("macchiato", ["blue", "pink", "yellow"]))
    check("border-color=#8aadf4" in mk and "background-color=#24273aee" in mk and "[urgency=high]" in mk,
          "mako: notification colors from the palette")

    # 6c. Wallpaper tint: backgrounds take the wallpaper's hue
    for name, rgb, lo, hi in (("purple", (150, 60, 210), 280, 330), ("green", (40, 190, 80), 120, 170)):
        png(img(name + ".png"), lambda x, y, rgb=rgb: rgb if (x + y) % 3 else (30, 30, 36))
        d = dry(home, img(name + ".png"), "--flavor", "macchiato", "--tint", "on")
        L, C, H = pt.lch(pt.hex_rgb(d["matugen"]["bg_color"].lstrip("#")))
        check(lo <= H <= hi and C > 0.02, f"tint: {name} wallpaper -> {name} bar background (hue {H:.0f})")
        base_L = pt.lch(pt.hex_rgb("24273a"))[0]
        check(abs(L - base_L) < 0.01, f"tint: {name} keeps Macchiato's lightness")
    d = dry(home, img("purple.png"), "--flavor", "macchiato", "--tint", "off")
    check(d["matugen"]["bg_color"] == "#24273a", "tint off: Macchiato's own base")
    d = dry(home, img("grey.png"), "--flavor", "macchiato", "--tint", "on")
    check(d["matugen"]["bg_color"] == "#24273a", "grey wallpaper: nothing to tint with")

    # 6d. Other palettes
    for pal in pt.PALETTE_CHOICES:
        d = dry(home, img("green-purple.png"), "--palette", pal)
        ok = len(set(d["accents"])) == 3 and all(
            re.fullmatch(r"#[0-9a-f]{6}", v) for k, v in d["matugen"].items() if k.endswith("_color"))
        check(ok, f"palette {pal}: {d['palette']}, accents {d['accents']}")
    check(dry(home, img("light.png"), "--palette", "gruvbox-auto")["palette"] == "gruvbox-light",
          "gruvbox-auto: light wallpaper -> Gruvbox Light")
    check(dry(home, img("dark-red.png"), "--palette", "rose-pine-auto")["palette"] == "rose-pine",
          "rose-pine-auto: dark wallpaper -> Rosé Pine")

    # 7. Material You through matugen (a stand-in when matugen isn't installed).
    fake_bin = os.path.join(tmp, "bin")
    os.makedirs(fake_bin)
    real = shutil.which("matugen")
    if not real:
        with open(os.path.join(fake_bin, "matugen"), "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\ncat <<'J'\n" + json.dumps({"colors": {
                r: {"dark": {"color": h}, "default": {"color": h}, "light": {"color": "#ffffff"}}
                for r, h in (("primary", "#d0bcff"), ("secondary", "#ccc2dc"), ("tertiary", "#efb8c8"),
                             ("surface", "#141218"), ("on_surface", "#e6e0e9"), ("error", "#f2b8b5"),
                             ("surface_container", "#211f26"), ("outline", "#938f99"))}}) + "\nJ\n")
        os.chmod(os.path.join(fake_bin, "matugen"), 0o755)
    os.environ["PATH"] = fake_bin + os.pathsep + os.environ["PATH"]
    d = dry(home, img("green-purple.png"), "--style", "material", "--scheme", "scheme-vibrant")
    check(d["flavor"] == "material" and d["accents"] == ["primary", "secondary", "tertiary"],
          "material: colors come from matugen" + (" (real matugen)" if real else " (stand-in)"))
    check(d["matugen"]["bezel_color"] != d["matugen"]["matrix_color"], "material: three-color wave")
    check(d["matugen"].get("card_bg_opacity") == pt.MATERIAL_CARD_OPACITY, "material: widget cards opaque like the bar")
    check("card_bg_opacity" not in dry(home, img("dark-red.png"), "--style", "catppuccin")["matugen"],
          "palette, dark wallpaper: shell.json's card opacity")
    check(dry(home, img("light.png"), "--style", "catppuccin")["matugen"].get("card_bg_opacity", 0) > 40,
          "palette, light wallpaper: cards opaque enough to read")
    r = run(home, img("green-purple.png"), "--style", "material", "--force")
    check(r.returncode == 0 and "Material You" in r.stdout, "material: full run")
    os.environ["PATH"] = os.pathsep.join(p for p in os.environ["PATH"].split(os.pathsep) if p != fake_bin)
    if not real:
        r = run(home, img("green-purple.png"), "--style", "material", "--force")
        check(r.returncode == 0 and "Catppuccin" in r.stdout and "instead" in r.stderr,
              "material without matugen: falls back to Catppuccin")
finally:
    shutil.rmtree(tmp)

print(f"\n{failures} failure(s)")
sys.exit(1 if failures else 0)
