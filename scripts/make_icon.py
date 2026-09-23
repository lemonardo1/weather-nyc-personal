"""Kandinsky-style app icon in the chart's three colors. Run: python3 scripts/make_icon.py"""
from PIL import Image, ImageDraw
import os

S = 4  # supersample for antialiasing
N = 1024 * S
BG = (5, 10, 20)
BLUE = (102, 184, 250)
VIOLET = (107, 92, 217)
GREEN = (107, 219, 115)

def s(*v): return [x * S for x in v]

img = Image.new("RGB", (N, N), BG)
d = ImageDraw.Draw(img)

def circle(cx, cy, r, fill=None, outline=None, width=0):
    d.ellipse(s(cx - r, cy - r, cx + r, cy + r), fill=fill, outline=outline, width=width * S)

# Large blue circle with a dark core and violet eye (Several Circles / Yellow-Red-Blue)
circle(420, 440, 250, fill=BLUE)
circle(420, 440, 150, fill=BG)
circle(420, 440, 92, fill=VIOLET)

# Violet disc overlapping lower right
circle(700, 690, 150, fill=VIOLET)
circle(700, 690, 150, outline=BG, width=14)

# Green diagonal cutting across, with a thin companion line
d.line(s(120, 910, 920, 110), fill=GREEN, width=22 * S)
d.line(s(200, 960, 960, 200), fill=GREEN, width=6 * S)

# Green half-disc on the upper right, blue triangle bottom left
d.pieslice(s(700, 150, 900, 350), 180, 360, fill=GREEN)
d.polygon(s(150, 900, 330, 900, 240, 740), fill=BLUE)

# Small checkered accent: three short violet bars
for i in range(3):
    y = 170 + i * 34
    d.line(s(150, y, 290, y), fill=VIOLET, width=12 * S)

out = os.path.join(os.path.dirname(__file__), "..", "WeatherNYC", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
img.resize((1024, 1024), Image.LANCZOS).save(out)
print(out)
