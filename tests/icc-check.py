#!/usr/bin/env python3
"""Opens every ICC profile Perihelion's Display page generates (written by
`zig test src/display.zig`) with Little CMS, the library wlroots applies them
with, and converts colours from sRGB through each one: white must stay white,
grey must stay neutral, and pure sRGB red must move inside the wider gamut."""
import io, sys, pathlib
from PIL import Image, ImageCms

d = pathlib.Path(sys.argv[1])
want = {"dcip3", "dp3", "adobe", "wide", "edid"}
found = {p.stem for p in d.glob("*.icc")}
if found != want:
    sys.exit(f"FAIL profiles: {sorted(found)} (want {sorted(want)})")
srgb = ImageCms.createProfile("sRGB")
fail = False
for name in sorted(want):
    prof = ImageCms.ImageCmsProfile(str(d / f"{name}.icc"))
    t = ImageCms.buildTransform(srgb, prof, "RGB", "RGB")
    conv = lambda c: ImageCms.applyTransform(Image.new("RGB", (1, 1), c), t).getpixel((0, 0))
    white, grey, red = conv((255, 255, 255)), conv((128, 128, 128)), conv((255, 0, 0))
    ok = (min(white) >= 253 and max(grey) - min(grey) <= 3 and red[0] < 250 and red != (255, 0, 0))
    print(("ok  " if ok else "FAIL"), f"{name:6} desc={ImageCms.getProfileDescription(prof).strip()!r} "
          f"white={white} grey={grey} red={red}")
    fail |= not ok
sys.exit(1 if fail else 0)
