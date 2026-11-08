"""Суреттерді жасайды: айдаһар күйлері (Dynamic Island, PiP), қосымша белгісі, қысқа дыбыстар.
Linux-та бір рет іске қосылады: python3 tools/make_assets.py (PIL, numpy, scipy керек)."""
import json
import math
import struct
import wave
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "tools/dragon.png"
# Жүрек түсі: ұйқы күңгірт көк, тыңдау жасыл, ойлау күлгін, сөйлеу көгілдір, қате қызыл
HEART = {"sleep": (70, 110, 190), "listen": (40, 255, 120), "think": (180, 130, 255), "speak": (70, 190, 255), "error": (255, 50, 50)}


def load() -> np.ndarray:
    img = Image.open(SRC).convert("RGBA")
    img = img.crop(img.getbbox())
    return np.asarray(img).astype(np.float32)


def heart_weight(arr: np.ndarray) -> np.ndarray:
    """Ноутбуктағыдай: ең үлкен қызыл аймақ жүрек, тек соны бояймыз."""
    rgb, alpha = arr[..., :3], arr[..., 3]
    redness = np.clip((rgb[..., 0] - rgb[..., 1:].max(axis=2)) / 255 * 1.6, 0, 1) * (alpha / 255)
    labels, n = ndimage.label(redness > 0.3)
    heart = labels == (int(np.argmax(ndimage.sum(redness > 0.3, labels, range(1, n + 1)))) + 1)
    region = ndimage.binary_dilation(ndimage.binary_fill_holes(heart), iterations=max(2, arr.shape[1] // 50))
    return (np.clip(redness * 2.2, 0, 1) * region)[..., None]


def tinted(arr: np.ndarray, weight: np.ndarray, color) -> Image.Image:
    rgb, alpha = arr[..., :3], arr[..., 3:]
    light = rgb.max(axis=2, keepdims=True) / 255
    out = rgb * (1 - weight) + np.array(color, np.float32) * light * weight
    return Image.fromarray(np.concatenate([np.clip(out, 0, 255), alpha], axis=2).astype(np.uint8), "RGBA")


def with_rim(img: Image.Image, width: int) -> Image.Image:
    """Қара айдаһар қара Dynamic Island-та көрінсін: сыртынан жұқа ашық жиек."""
    alpha = img.getchannel("A")
    grown = alpha.filter(ImageFilter.MaxFilter(width * 2 + 1)).filter(ImageFilter.GaussianBlur(width / 2))
    rim = Image.new("RGBA", img.size, (190, 200, 215, 0))
    rim.putalpha(grown.point(lambda v: int(v * 0.55)))
    rim.alpha_composite(img)
    return rim


def imageset(name: str, img: Image.Image, folder: Path) -> None:
    d = folder / f"{name}.imageset"
    d.mkdir(parents=True, exist_ok=True)
    img.save(d / f"{name}.png", optimize=True)
    (d / "Contents.json").write_text(json.dumps({
        "images": [{"filename": f"{name}.png", "idiom": "universal", "scale": "3x"}],
        "info": {"author": "xcode", "version": 1}}, indent=2))


def tone(path: Path, freqs, dur: float, volume: float = 0.35) -> None:
    rate = 22050
    n = int(rate * dur)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        frames = bytearray()
        for i in range(n):
            t = i / rate
            f = freqs[0] if t < dur / 2 or len(freqs) == 1 else freqs[1]
            env = min(1.0, t / 0.01, (dur - t) / 0.03)
            frames += struct.pack("<h", int(32767 * volume * env * math.sin(2 * math.pi * f * t)))
        w.writeframes(bytes(frames))


def main() -> None:
    arr = load()
    weight = heart_weight(arr)
    cat = ROOT / "Shared/Dragon.xcassets"
    cat.mkdir(parents=True, exist_ok=True)
    big_cat = ROOT / "Alikhan/DragonBig.xcassets"
    for c in (cat, big_cat):
        c.mkdir(parents=True, exist_ok=True)
        (c / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))
    for state, color in HEART.items():
        img = tinted(arr, weight, color)
        small = img.resize((330, round(330 * img.height / img.width)), Image.LANCZOS)
        imageset(f"dragon_{state}", with_rim(small, 3), cat)          # Dynamic Island, құлып экраны
        big = img.resize((960, round(960 * img.height / img.width)), Image.LANCZOS)
        imageset(f"dragon_big_{state}", with_rim(big, 6), big_cat)    # PiP (тек қосымшада)

    # Қосымша белгісі: 1024, мөлдірліксіз (App Store талабы)
    icon = Image.new("RGBA", (1024, 1024), (0, 0, 0, 255))
    glow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    yy, xx = np.mgrid[0:1024, 0:1024]
    r = np.hypot(xx - 560, yy - 470) / 520
    halo = np.clip(1 - r, 0, 1) ** 2 * 120
    glow_arr = np.zeros((1024, 1024, 4), np.uint8)
    glow_arr[..., 0], glow_arr[..., 1], glow_arr[..., 2], glow_arr[..., 3] = 220, 30, 40, halo.astype(np.uint8)
    icon.alpha_composite(Image.fromarray(glow_arr, "RGBA"))
    art = with_rim(tinted(arr, weight, (255, 40, 40)).resize((900, round(900 * arr.shape[0] / arr.shape[1])), Image.LANCZOS), 5)
    icon.alpha_composite(art, ((1024 - art.width) // 2, (1024 - art.height) // 2))
    appicon = ROOT / "Alikhan/Assets.xcassets/AppIcon.appiconset"
    appicon.mkdir(parents=True, exist_ok=True)
    icon.convert("RGB").save(appicon / "icon.png")
    (appicon / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}}, indent=2))
    (ROOT / "Alikhan/Assets.xcassets/Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))

    sounds = ROOT / "Alikhan/Sounds"
    sounds.mkdir(parents=True, exist_ok=True)
    tone(sounds / "beep.wav", (880, 1320), 0.16)        # «Алихан» расталды
    tone(sounds / "silence.wav", (440,), 0.05, 0.0)     # Live Activity ескертуі дыбыссыз болсын


if __name__ == "__main__":
    main()
