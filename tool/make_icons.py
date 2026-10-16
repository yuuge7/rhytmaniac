"""Draws Rhytmaniac's launcher icon: a mirrored signal strip in the heat ramp
on plum ink. Run from the project root: python tool/make_icons.py"""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
INK = (21, 13, 29)
RAMP = [(59, 28, 110), (122, 35, 130), (194, 54, 108), (238, 99, 64), (251, 175, 69), (253, 240, 169)]
HEIGHTS = [0.30, 0.52, 0.78, 1.0, 0.70, 0.46, 0.26]


def heat(t):
    x = max(0.0, min(1.0, t)) * (len(RAMP) - 1)
    i = min(int(x), len(RAMP) - 2)
    f = x - i
    return tuple(round(a + (b - a) * f) for a, b in zip(RAMP[i], RAMP[i + 1]))


def draw_bars(img, box, scale):
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = box
    n = len(HEIGHTS)
    w = (x1 - x0) / n
    bar = w * 0.56
    mid = (y0 + y1) / 2
    for i, h in enumerate(HEIGHTS):
        cx = x0 + w * (i + 0.5)
        half = (y1 - y0) / 2 * h
        color = heat(0.25 + 0.75 * h)
        d.rounded_rectangle([cx - bar / 2, mid - half, cx + bar / 2, mid + half], radius=bar / 2, fill=color)


def legacy(size):
    s = size * 4
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle([0, 0, s - 1, s - 1], radius=s * 0.22, fill=INK)
    draw_bars(img, (s * 0.17, s * 0.2, s * 0.83, s * 0.8), s)
    return img.resize((size, size), Image.LANCZOS)


def foreground(size):
    s = size * 4
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    # Adaptive icons show the middle 66/108 of the layer; keep art inside it.
    draw_bars(img, (s * 0.29, s * 0.31, s * 0.71, s * 0.69), s)
    return img.resize((size, size), Image.LANCZOS)


dens = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
res = ROOT / 'android/app/src/main/res'
for name, k in dens.items():
    d = res / f'mipmap-{name}'
    d.mkdir(parents=True, exist_ok=True)
    legacy(round(48 * k)).save(d / 'ic_launcher.png')
    foreground(round(108 * k)).save(d / 'ic_launcher_foreground.png')
any_dir = res / 'mipmap-anydpi-v26'
any_dir.mkdir(exist_ok=True)
(any_dir / 'ic_launcher.xml').write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '    <background android:drawable="@color/ic_launcher_background"/>\n'
    '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
    '</adaptive-icon>\n')
values = res / 'values'
(values / 'ic_launcher_colors.xml').write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
    '    <color name="ic_launcher_background">#150D1D</color>\n</resources>\n')
legacy(1024).save(ROOT / 'tool/icon_preview.png')
# iOS app icon set (single 1024 plus the sizes Flutter's template lists).
ios = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
if ios.exists():
    for f in ios.glob('*.png'):
        with Image.open(f) as im:
            w = im.size[0]
        flat = Image.new('RGB', (w, w), INK)
        art = legacy(w)
        flat.paste(art, (0, 0), art)
        flat.save(f)
print('icons written')
