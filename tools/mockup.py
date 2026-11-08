"""Экран үлгілері (PNG): Swift кодындағы түстер мен орналасу бойынша салынған, телефон скриншоты емес."""
import math
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
F = "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf"
FB = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
def font(s, b=False): return ImageFont.truetype(FB if b else F, s)
def hx(h, a=255): h = h.lstrip("#"); return (int(h[:2], 16), int(h[2:4], 16), int(h[4:], 16), a)

PAL = {"sleep": ("3a4656", "1c232d", "5eead4"), "listen": ("4ade80", "047857", "34d399"),
       "think": ("a78bfa", "5b21b6", "8b5cf6"), "speak": ("7dd3fc", "1d4ed8", "38bdf8"), "error": ("fb7185", "9f1239", "f43f5e")}
ACC = {"sleep": "4a6a9a", "listen": "34d399", "think": "a78bfa", "speak": "38bdf8", "error": "f43f5e"}
W, H = 390, 844


def orb(state, size=260):
    k = size / 84; c = size / 2; light, dark, glow = [np.array(hx(x)[:3], float) for x in PAL[state]]
    yy, xx = np.mgrid[0:size, 0:size].astype(float)
    img = np.zeros((size, size, 4))
    r = 25 * k; d = np.hypot(xx - c, yy - c)
    halo = np.clip(np.where(d < r * .85 * 1, 1, 1 - (d - r * .85) / (c - r * .85)), 0, 1) * 0.45
    img[..., :3] = glow; img[..., 3] = halo * (d < c)
    if state == "listen":
        for i, ph in enumerate((0.2, 0.55, 0.85)):
            rr = r + ph * (c - r - k); ring = np.clip(1 - abs(d - rr) / (1.2 * k), 0, 1) * 0.55 * (1 - ph)
            img[..., 3] = np.maximum(img[..., 3], ring)
    lx, ly = c - r * .35, c - r * .45; t = np.clip(np.hypot(xx - lx, yy - ly) / (r * 1.6), 0, 1)
    top = light + (255 - light) * .25
    col = np.where(t[..., None] < .55, top + (light - top) * (t[..., None] / .55), light + (dark - light) * ((t[..., None] - .55) / .45))
    inside = np.clip(r - d + .5, 0, 1)[..., None]
    img[..., :3] = img[..., :3] * (1 - inside) + col * inside; img[..., 3] = np.maximum(img[..., 3], inside[..., 0])
    sh = ((xx - (c - r * .07)) / (r * .55)) ** 2 + ((yy - (c - r * .47)) / (r * .35)) ** 2
    g = np.clip(1 - sh, 0, 1) * .35 * inside[..., 0]
    img[..., :3] = img[..., :3] * (1 - g[..., None]) + 255 * g[..., None]
    im = Image.fromarray(img.clip(0, 255).astype(np.uint8) if False else np.dstack([img[..., :3], img[..., 3:] * 255]).clip(0, 255).astype(np.uint8), "RGBA")
    dr = ImageDraw.Draw(im)
    if state == "speak":
        for i in range(5):
            h = (6 + (0.35 + 0.65 * abs(math.sin(i * 1.9 + 1))) * 22) * k; x = c + (i - 2) * 6.5 * k
            dr.rounded_rectangle([x - 2 * k, c - h / 2, x + 2 * k, c + h / 2], 2 * k, fill=(255, 255, 255, 235))
    else:
        txt = {"listen": "А", "sleep": "А", "error": "!", "think": "•••"}[state]; f = font(int((14 if state == "think" else 20) * k), True)
        dr.text((c, c), txt, font=f, anchor="mm", fill=(255, 255, 255, 240 if state != "sleep" else 170))
    if state == "think":
        rr = r + 5 * k
        for a in range(0, 120, 2):
            al = int(230 * (1 - a / 120)); ang = math.radians(-90 + a)
            dr.ellipse([c + rr * math.cos(ang) - 1.5 * k, c + rr * math.sin(ang) - 1.5 * k, c + rr * math.cos(ang) + 1.5 * k, c + rr * math.sin(ang) + 1.5 * k], fill=(255, 255, 255, al))
    return im


def phone(bg_top="0b0f16", bg_bot="151b26"):
    a = np.linspace(0, 1, H)[:, None, None]; t, b = np.array(hx(bg_top)[:3]), np.array(hx(bg_bot)[:3])
    arr = np.broadcast_to(t + (b - t) * a, (H, W, 3)).astype(np.uint8)
    return Image.fromarray(arr).convert("RGBA")


def frame(screen, title):
    out = Image.new("RGBA", (W + 40, H + 90), hx("f4f4f2"))
    mask = Image.new("L", (W, H), 0); ImageDraw.Draw(mask).rounded_rectangle([0, 0, W, H], 48, fill=255)
    d = ImageDraw.Draw(out); d.rounded_rectangle([12, 52, W + 28, H + 68], 56, fill=hx("1a1a1a"))
    out.paste(screen, (20, 60), mask); d.text(((W + 40) / 2, 26), title, font=font(20, True), anchor="mm", fill=hx("222222"))
    return out


def island(d, x, y, w, h=37):
    d.rounded_rectangle([x, y, x + w, y + h], h / 2, fill=(0, 0, 0, 255))


def wrap(d, text, xy, f, fill, width):
    x, y = xy; line = ""
    for w in text.split():
        if d.textlength(line + " " + w, font=f) > width and line:
            d.text((x, y), line, font=f, fill=fill); y += f.size + 6; line = w
        else: line = (line + " " + w).strip()
    d.text((x, y), line, font=f, fill=fill); return y + f.size + 6


def dragon(state, w):
    im = Image.open(ROOT / f"Shared/Dragon.xcassets/dragon_{state}.imageset/dragon_{state}.png")
    return im.resize((w, round(w * im.height / im.width)), Image.LANCZOS)


def dragon_main(state, w=350):
    im = Image.open(ROOT / f"Alikhan/DragonBig.xcassets/dragon_big_{state}.imageset/dragon_big_{state}.png")
    im = im.resize((w, round(w * im.height / im.width)), Image.LANCZOS)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    cx, cy, r = im.width * 0.544, im.height * 0.443, im.width * 0.33
    yy, xx = np.mgrid[0:im.height, 0:im.width]; dd = np.hypot(xx - cx, yy - cy) / r
    g = np.zeros((im.height, im.width, 4), np.uint8); g[..., :3] = hx(ACC[state])[:3]; g[..., 3] = (np.clip(1 - dd, 0, 1) ** 1.6 * 150).astype(np.uint8)
    out.alpha_composite(Image.fromarray(g, "RGBA")); out.alpha_composite(im); return out


def main_screen(state, heard, said, card=False):
    s = phone(); d = ImageDraw.Draw(s); island(d, W / 2 - 62, 11, 124)
    d.text((24, 64), {"listen": "Тыңдап тұр", "speak": "Сөйлеп тұр", "think": "Ойланып жатыр", "sleep": "«Алихан» деңіз"}[state], font=font(16), fill=hx(ACC[state]))
    gx, gy = W - 40, 76
    for a in range(0, 360, 45):
        r = math.radians(a); d.line([gx + 7 * math.cos(r), gy + 7 * math.sin(r), gx + 12 * math.cos(r), gy + 12 * math.sin(r)], fill=(220, 220, 220, 230), width=4)
    d.ellipse([gx - 8, gy - 8, gx + 8, gy + 8], outline=(220, 220, 220, 230), width=4)
    o = dragon_main(state); s.alpha_composite(o, (int(W / 2 - o.width / 2), 230))
    tx, ty = W - 84, 76
    d.rectangle([tx - 9, ty - 9, tx + 9, ty + 9], outline=(220, 220, 220, 230), width=3)
    d.line([tx - 4, ty, tx - 1, ty + 4, tx + 5, ty - 4], fill=(220, 220, 220, 230), width=3)
    d.ellipse([tx + 6, ty - 18, tx + 22, ty - 2], fill=hx("f43f5e")); d.text((tx + 14, ty - 10), "1", font=font(11, True), anchor="mm", fill=(255, 255, 255, 255))
    y = 520
    if heard: y = wrap(d, "Сіз: " + heard, (24, y), font(16), (200, 200, 200, 170), W - 48) + 6
    if said: y = wrap(d, said, (24, y), font(18), (255, 255, 255, 255), W - 48)
    if card:
        top = 720; ov = Image.new("RGBA", s.size, (0, 0, 0, 0))
        ImageDraw.Draw(ov).rounded_rectangle([16, top, W - 16, top + 50], 14, fill=(255, 255, 255, 22)); s.alpha_composite(ov); d = ImageDraw.Draw(s)
        d.text((36, top + 25), "TikTok-қа кіру керек: логин мен пароль", font=font(14), anchor="lm", fill=(255, 255, 255, 240))
        d.text((W - 36, top + 25), "›", font=font(22), anchor="rm", fill=(255, 255, 255, 140))
    if False:
        top = y + 18; ov = Image.new("RGBA", s.size, (0, 0, 0, 0))
        ImageDraw.Draw(ov).rounded_rectangle([16, top, W - 16, top + 170], 16, fill=(255, 255, 255, 22)); s.alpha_composite(ov); d = ImageDraw.Draw(s)
        d.text((32, top + 16), "Тапсырма сізді күтіп тұр", font=font(17, True), fill=hx("fbbf24"))
        wrap(d, "Сэр, ClipPay-ге кіру керек: https://clippay.kz/login. Біткенде «жасадым» деңіз.", (32, top + 48), font(15), (255, 255, 255, 240), W - 64)
        d.rounded_rectangle([32, top + 118, 122, top + 152], 9, outline=(140, 160, 255, 255), width=2); d.text((77, top + 135), "Ашу", font=font(15), anchor="mm", fill=hx("9fb4ff"))
        d.rounded_rectangle([W - 160, top + 118, W - 32, top + 152], 9, fill=hx("10b981")); d.text((W - 96, top + 135), "✓ Жасадым", font=font(15, True), anchor="mm", fill=(255, 255, 255, 255))
    return s


def tasks_screen():
    s = Image.new("RGBA", (W, H), hx("000000")); d = ImageDraw.Draw(s); island(d, W / 2 - 62, 11, 124)
    d.text((W - 24, 70), "Жабу", font=font(17, True), anchor="ra", fill=hx("3b82f6"))
    d.text((20, 100), "Тапсырмаларым", font=font(30, True), fill=(255, 255, 255, 255))
    d.text((32, 160), "СІЗДЕН КҮТЕДІ", font=font(12), fill=(150, 150, 155, 255))
    def row(top, text, when, link):
        d.rounded_rectangle([16, top, W - 16, top + 150], 12, fill=hx("1c1c1e"))
        yb = wrap(d, text, (32, top + 14), font(15), (255, 255, 255, 255), W - 64)
        d.text((32, yb), when, font=font(12), fill=(150, 150, 155, 255))
        if link:
            d.rounded_rectangle([32, top + 104, 120, top + 138], 9, fill=hx("2c2c2e")); d.text((76, top + 121), "Ашу", font=font(15), anchor="mm", fill=hx("3b82f6"))
        d.rounded_rectangle([W - 172, top + 104, W - 32, top + 138], 9, fill=hx("10b981")); d.text((W - 102, top + 121), "✓ Орындадым", font=font(15, True), anchor="mm", fill=(255, 255, 255, 255))
    row(182, "Сэр, TikTok-қа видео салу үшін кіру керек: логин мен паролді енгізіңіз.", "2 минут бұрын", True)
    row(344, "Сэр, Kaspi-ден келген SMS кодты растаңыз.", "15 минут бұрын", False)
    d.text((32, 516), "ОРЫНДАЛДЫ", font=font(12), fill=(150, 150, 155, 255))
    d.rounded_rectangle([16, 538, W - 16, 582], 12, fill=hx("1c1c1e"))
    d.text((32, 560), "ClipPay-ге кіру", font=font(15), anchor="lm", fill=(150, 150, 155, 255))
    return s


def login_screen():
    s = Image.new("RGBA", (W, H), hx("000000")); d = ImageDraw.Draw(s); island(d, W / 2 - 62, 11, 124)
    d.text((20, 70), "Жабу", font=font(17), fill=hx("3b82f6")); d.text((W / 2, 80), "tiktok.com", font=font(17, True), anchor="mm", fill=(255, 255, 255, 255))
    wrap(d, "Сэр, TikTok-қа видео салу үшін кіру керек: логин мен паролді енгізіңіз.", (14, 106), font(13), (150, 150, 155, 255), W - 28)
    d.rectangle([0, 160, W, 760], fill=hx("ffffff"))
    d.text((W / 2, 230), "TikTok-қа кіру", font=font(24, True), anchor="mm", fill=hx("161823"))
    for i, ph in enumerate(("Телефон / email / логин", "Пароль")):
        d.rounded_rectangle([30, 290 + i * 66, W - 30, 340 + i * 66], 6, fill=hx("f1f1f2")); d.text((44, 315 + i * 66), ph, font=font(15), anchor="lm", fill=hx("8a8b91"))
    d.rounded_rectangle([30, 440, W - 30, 490], 6, fill=hx("fe2c55")); d.text((W / 2, 465), "Кіру", font=font(16, True), anchor="mm", fill=(255, 255, 255, 255))
    d.text((W / 2, 560), "(сайттың өз беті, қосымша ішінде)", font=font(13), anchor="mm", fill=hx("8a8b91"))
    wrap(d, "Логин мен парольді осы бетте өзіңіз жазасыз. Алихан оны көрмейді, сақтамайды.", (24, 690), font(12), hx("8a8b91"), W - 48)
    d.rounded_rectangle([12, 772, W - 12, 818], 12, fill=hx("10b981")); d.text((W / 2, 795), "✓ Орындадым", font=font(17, True), anchor="mm", fill=(255, 255, 255, 255))
    return s


def lock_screen():
    s = phone("1e2a44", "0d1220"); d = ImageDraw.Draw(s)
    island(d, W / 2 - 100, 11, 200)
    s.alpha_composite(dragon("listen", 54), (int(W / 2 - 98), 12))
    d.text((W / 2 + 88, 29), "≋", font=font(18, True), anchor="mm", fill=hx(ACC["listen"]))
    d.text((W / 2, 120), "сенбі, 8 қараша", font=font(18), anchor="mm", fill=(255, 255, 255, 220))
    d.text((W / 2, 190), "21:47", font=font(84, True), anchor="mm", fill=(255, 255, 255, 235))
    top = 560; ov = Image.new("RGBA", s.size, (0, 0, 0, 0))
    ImageDraw.Draw(ov).rounded_rectangle([14, top, W - 14, top + 132], 22, fill=(10, 10, 12, 230)); s.alpha_composite(ov); d = ImageDraw.Draw(s)
    s.alpha_composite(dragon("listen", 100), (22, top + 26))
    d.text((122, top + 20), "≋  Тыңдап тұрмын, сэр", font=font(17, True), fill=hx(ACC["listen"]))
    d.text((122, top + 52), "Сіз: анама қоңырау шал", font=font(14), fill=(200, 200, 200, 190))
    wrap(d, "Қазір анаңызға қоңырау шалып жатырмын.", (122, top + 76), font(15), (255, 255, 255, 255), W - 150)
    d.text((W / 2, 800), "Құлып экраны және Dynamic Island", font=font(13), anchor="mm", fill=(255, 255, 255, 120))
    return s


def island_screen():
    s = phone("2b2f3a", "1a1d24"); d = ImageDraw.Draw(s)
    d.text((24, 80), "Dynamic Island күйлері", font=font(18, True), fill=(255, 255, 255, 230))
    y = 120
    for st, lab in (("sleep", "ұйқы: «Алихан» сөзін күтеді"), ("listen", "тыңдап тұр"), ("think", "ойланып жатыр"), ("speak", "сөйлеп тұр"), ("error", "қате")):
        island(d, W / 2 - 110, y, 220, 40); s.alpha_composite(dragon(st, 54), (int(W / 2 - 96), y + 1))
        sym = {"sleep": "☾", "listen": "≋", "think": "•••", "speak": "🔊" if False else "♪", "error": "!"}[st]
        d.ellipse([W / 2 + 80, y + 12, W / 2 + 92, y + 24], fill=hx(ACC[st]))
        d.text((W / 2, y + 50), lab, font=font(13), anchor="mm", fill=(255, 255, 255, 170)); y += 82
    y += 10; d.text((24, y), "«Алихан» расталғанда (кеңейтілген):", font=font(14), fill=(255, 255, 255, 200)); y += 30
    d.rounded_rectangle([10, y, W - 10, y + 150], 44, fill=(0, 0, 0, 255))
    s.alpha_composite(dragon("listen", 104), (22, y + 12))
    d.text((W / 2 + 10, y + 34), "Тыңдап тұрмын, сэр", font=font(17, True), anchor="mm", fill=hx(ACC["listen"]))
    d.text((W - 40, y + 34), "≋", font=font(20, True), anchor="mm", fill=hx(ACC["listen"]))
    d.text((34, y + 86), "Сіз: Алихан", font=font(13), fill=(200, 200, 200, 180))
    d.text((34, y + 108), "Тыңдап тұрмын, сэр", font=font(15), fill=(255, 255, 255, 255))
    return s


def settings_screen():
    s = Image.new("RGBA", (W, H), hx("000000")); d = ImageDraw.Draw(s); island(d, W / 2 - 62, 11, 124)
    d.text((W - 24, 70), "Дайын", font=font(17, True), anchor="ra", fill=hx("3b82f6"))
    d.text((20, 100), "Баптау", font=font(32, True), fill=(255, 255, 255, 255))
    def section(y, head, rows, foot=None):
        d.text((32, y), head.upper(), font=font(12), fill=(150, 150, 155, 255)); y += 22
        d.rounded_rectangle([16, y, W - 16, y + 44 * len(rows)], 12, fill=hx("1c1c1e"))
        for i, (l, r) in enumerate(rows):
            yy = y + 44 * i
            if i: d.line([32, yy, W - 16, yy], fill=hx("38383a"))
            d.text((32, yy + 22), l, font=font(15), anchor="lm", fill=(255, 255, 255, 255))
            if r == "on" or r == "off":
                cx = W - 58; d.rounded_rectangle([cx, yy + 9, cx + 46, yy + 35], 13, fill=hx("34c759") if r == "on" else hx("39393d"))
                d.ellipse([cx + (22 if r == "on" else 2), yy + 11, cx + (44 if r == "on" else 24), yy + 33], fill=(255, 255, 255, 255))
            elif r: d.text((W - 32, yy + 22), r, font=font(15), anchor="rm", fill=(150, 150, 155, 255))
        y += 44 * len(rows) + 8
        if foot: y = wrap(d, foot, (32, y), font(12), (150, 150, 155, 255), W - 64)
        return y + 16
    y = section(160, "Сервер", [("http://100.78.149.53:8000", ""), ("••••••••••••", ""), ("Байланысты тексеру", "дұрыс")], "Сервер тек Tailscale желісінде.")
    y = section(y, "Тыңдау", [("Үнемі тыңдау", "on"), ("Наушник микрофоны", "off"), ("Picture-in-Picture айдаһар", "off"),
                              ("Дауыс шегі: 1.65 есе", ""), ("Соңғы сағатта /wake/confirm", "12 рет")])
    y = section(y, "Рұқсаттар", [("Микрофон, контактілер, еске салулар", ""), ("iOS баптауын ашу", "")])
    return s


shots = [frame(main_screen("listen", "тиктокқа осы видеоны сал", "Жақсы, сэр. TikTok-қа кіру керек, тапсырмаларыңызға қостым.", card=True), "1. Басты экран"),
         frame(tasks_screen(), "2. Тапсырмаларым"), frame(login_screen(), "3. Кіру беті (қосымша ішінде)"),
         frame(lock_screen(), "4. Құлып экраны"), frame(island_screen(), "5. Dynamic Island"), frame(settings_screen(), "6. Баптау")]
sheet = Image.new("RGBA", (3 * shots[0].width, 2 * shots[0].height), hx("f4f4f2"))
for i, sh in enumerate(shots): sheet.alpha_composite(sh, ((i % 3) * sh.width, (i // 3) * sh.height))
sheet.convert("RGB").save(ROOT / "docs/mockup.png", optimize=True)
print("ok", sheet.size)
