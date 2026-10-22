"""Generate four original 2048×2732 wallpapers and a matching App Store icon.
Artwork is functional: all four themes are selectable in Appearance.
No padding files, downloaded photos, or third-party art licences are needed.
"""
from pathlib import Path
import json
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "ios/www/artwork"
OUT.mkdir(parents=True, exist_ok=True)
PALETTES = {
    "aurora": ["#151633", "#6e62cc", "#b8a5f2", "#b5d9ec"],
    "lagoon": ["#082c3d", "#287f9b", "#71d3c6", "#c4edf1"],
    "ember": ["#371d39", "#ab5a82", "#ec9c8d", "#f6dcb5"],
    "midnight": ["#080d24", "#264278", "#6979bd", "#bfbbec"],
}
def rgb(value):
    return np.array([int(value[i:i+2], 16) for i in (1, 3, 5)], dtype=np.float32)

width, height = 2048, 2732
y, x = np.mgrid[0:height, 0:width].astype(np.float32)
x /= width
y /= height
manifest = []
for seed, (name, colors) in enumerate(PALETTES.items()):
    base, middle, glow, light = map(rgb, colors)
    blend = np.clip(x * .32 + y * .6, 0, 1)[..., None]
    pixels = base * (1-blend) + middle * blend
    halo = np.exp(-((x-.8)**2/.32 + (y-.16)**2/.22))[..., None] * .8
    pixels = pixels * (1-halo) + glow * halo
    # A tilted, softly lit glass orbit, matching the vector web artwork.
    dx, dy = x-.5, (y-.5)*1.2
    u, v = dx*.866 + dy*.5, -dx*.5 + dy*.866
    radius = np.sqrt((u/.26)**2+(v/.43)**2)
    ring = np.exp(-((radius-1)/.13)**2)[..., None]
    specular = np.clip(.25 + .65*(1-y) + .2*x, 0, 1)[..., None]
    pixels = pixels*(1-ring*.52) + (glow*(1-specular)+light*specular)*ring*.52
    edge = np.exp(-((radius-1.13)/.004)**2)[..., None]*.45
    pixels = pixels*(1-edge)+light*edge
    # Fine photographic grain avoids gradient banding on bright OLED displays.
    rng = np.random.default_rng(4021+seed)
    pixels += rng.normal(0, 2.4, pixels.shape).astype(np.float32)
    image = Image.fromarray(np.clip(pixels, 0, 255).astype(np.uint8), "RGB")
    target = OUT / (name+".png")
    image.save(target, optimize=True)
    manifest.append({"name":name,"width":width,"height":height,"bytes":target.stat().st_size})
    print(name, f"{target.stat().st_size / 1024**2:.2f} MiB")
# Icon: a luminous four-point star inside an orbital glass field.
icon = Image.open(OUT / "aurora.png").resize((1024, 1366)).crop((0, 171, 1024, 1195)).convert("RGBA")
shadow = Image.new("RGBA", icon.size)
d = ImageDraw.Draw(shadow)
d.ellipse((180, 270, 860, 760), outline=(226, 218, 255, 150), width=8)
shadow = shadow.filter(ImageFilter.GaussianBlur(2))
icon = Image.alpha_composite(icon, shadow)
d = ImageDraw.Draw(icon)
d.polygon([(512, 210),(588, 436),(814,512),(588,588),(512,814),(436,588),(210,512),(436,436)], fill=(249,246,255,255))
d.ellipse((202, 344, 234, 376), fill=(234,225,255,255))
icon_path = ROOT / "ios/AIStudio/Assets.xcassets/AppIcon.appiconset/icon.png"
icon.convert("RGB").save(icon_path)
(OUT / "manifest.json").write_text(json.dumps(manifest, indent=2))
print("Original artwork pack:", f"{sum(m['bytes'] for m in manifest)/1024**2:.2f} MiB")
