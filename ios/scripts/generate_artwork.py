"""Draw the 1024×1024 app icon: a white twelve-ray spark on Claude's terracotta, matching the app's spark.
Pillow only, about a second on any machine, so it runs on Linux CI instead of macOS.
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
SIZE, SCALE = 1024, 4  # drawn 4x larger, then scaled down for smooth edges
big = SIZE * SCALE
icon = Image.new("RGB", (big, big), (217, 119, 87))

# A soft light from the top left, like the paper texture of the app.
glow = Image.new("L", (big, big), 0)
ImageDraw.Draw(glow).ellipse((-big * 0.35, -big * 0.45, big * 0.9, big * 0.75), fill=46)
glow = glow.filter(ImageFilter.GaussianBlur(big // 9))
icon = Image.composite(Image.new("RGB", (big, big), (236, 146, 112)), icon, glow)

# The spark: the same geometry as spark() in index.html (12 tapered rays, long and short).
draw = ImageDraw.Draw(icon)
cx = cy = big / 2
unit = big / 24 * 0.62
for k in range(12):
    a = k * math.pi / 6 + (0.08 if k % 2 else 0)
    r = (8.6 if k % 2 else 11) * unit
    w = (0.95 if k % 2 else 1.25) * unit
    x, y = math.cos(a), math.sin(a)
    px, py = -y * w, x * w
    draw.polygon([(cx + px, cy + py), (cx + x * r, cy + y * r), (cx - px, cy - py)], fill=(255, 250, 245))
draw.ellipse((cx - 2.1 * unit, cy - 2.1 * unit, cx + 2.1 * unit, cy + 2.1 * unit), fill=(255, 250, 245))

icon = icon.resize((SIZE, SIZE), Image.LANCZOS)
out = ROOT / "ios/AIStudio/Assets.xcassets/AppIcon.appiconset/icon.png"
icon.save(out, optimize=True)
print("App icon:", out.relative_to(ROOT), f"{out.stat().st_size / 1024:.0f} KB")
