#!/usr/bin/python3
"""Íconos del control remoto (pantalla de inicio del iPhone / Android): control plateado MIRAY.
Uso: generar-iconos.py CARPETA   -> icono-512.png, icono-192.png, apple-touch-icon.png (180)"""
import sys
from PIL import Image, ImageDraw, ImageFont

N = 512
im = Image.new("RGB", (N, N))
d = ImageDraw.Draw(im)
for y in range(N):                                   # plata con brillo diagonal
    for x in range(0, N, 4):
        k = 0.5 + 0.5 * (1 - abs((x * 0.6 + y * 0.4) / N - 0.45) * 1.6)
        v = int(170 + 75 * max(0.0, min(1.0, k)))
        d.line((x, y, x + 3, y), fill=(v, v + 3, v + 8))
f = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 62)
t = "MIRAY"
tw = d.textsize(t, font=f)[0]
d.text(((N - tw) // 2 + 2, 92), t, font=f, fill=(255, 255, 255))
d.text(((N - tw) // 2, 90), t, font=f, fill=(70, 76, 85))
cx, cy, R = 256, 318, 148                            # cruz redonda con OK azul
d.ellipse((cx - R, cy - R + 8, cx + R, cy + R + 8), fill=(120, 127, 136))
d.ellipse((cx - R, cy - R, cx + R, cy + R), fill=(205, 210, 216), outline=(240, 243, 246), width=4)
for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
    px, py = cx + dx * 108, cy + dy * 108
    s = 20
    if dy:
        pts = [(px - s, py - dy * s * 0.6), (px + s, py - dy * s * 0.6), (px, py + dy * s)]
    else:
        pts = [(px - dx * s * 0.6, py - s), (px - dx * s * 0.6, py + s), (px + dx * s, py)]
    d.polygon(pts, fill=(80, 86, 95))
r = 66
d.ellipse((cx - r - 7, cy - r - 7, cx + r + 7, cy + r + 7), fill=(159, 220, 255))
d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(42, 111, 214))
f2 = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 46)
tw, th = d.textsize("OK", font=f2)
d.text((cx - tw // 2, cy - th // 2 - 4), "OK", font=f2, fill=(255, 255, 255))
d.ellipse((392, 70, 440, 118), fill=(217, 35, 26), outline=(140, 14, 8), width=3)   # botón rojo
out = sys.argv[1] if len(sys.argv) > 1 else "."
im.save(f"{out}/icono-512.png")
im.resize((192, 192), Image.LANCZOS).save(f"{out}/icono-192.png")
im.resize((180, 180), Image.LANCZOS).save(f"{out}/apple-touch-icon.png")
