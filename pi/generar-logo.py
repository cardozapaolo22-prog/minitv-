#!/usr/bin/python3
"""generar-logo.py: prepara el logo de la Mini TV a partir de un PNG (con o sin transparencia).

Uso: generar-logo.py LOGO.png CARPETA_SALIDA [alto_menu] [ancho_arranque]
  alto_menu       alto del logo pequeño del menú (por defecto 22; se usa 26)
  ancho_arranque  ancho máximo del logo en el arranque (por defecto 200 de 320)
Genera en CARPETA_SALIDA:
  logo-arranque.rgb   320x240, logo centrado sobre negro, RGB crudo (lo lee minitv-estatica)
  logo-arranque.png   lo mismo en PNG, para revisarlo
  logo-menu.png       versión pequeña compuesta sobre el fondo del menú (#0d1b3d)
"""
import sys

from PIL import Image, ImageDraw, ImageFilter

W, H = 320, 240
FONDO_MENU = (0x0D, 0x1B, 0x3D)

origen, salida = sys.argv[1], sys.argv[2]
alto_menu = int(sys.argv[3]) if len(sys.argv) > 3 else 22
ancho_arranque = int(sys.argv[4]) if len(sys.argv) > 4 else 200
im = Image.open(origen).convert("RGBA")

# Quitar el fondo si no tiene transparencia: el blanco conectado a los bordes pasa a transparente
if im.getchannel("A").getextrema()[0] == 255:
    marca = (255, 0, 255, 255)
    copia = im.copy()
    for esquina in ((0, 0), (im.width - 1, 0), (0, im.height - 1), (im.width - 1, im.height - 1)):
        ImageDraw.floodfill(copia, esquina, marca, thresh=40)
    mascara = Image.new("L", im.size, 255)
    mascara.putdata([0 if p == marca else 255 for p in copia.getdata()])
    im.putalpha(mascara.filter(ImageFilter.GaussianBlur(0.7)))
    print("Fondo blanco quitado")

# Recortar el margen vacío
im = im.crop(im.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox())


def reducir(img, ancho_max, alto_max):
    """Reduce con alfa premultiplicado (sin halos en los bordes)."""
    k = min(ancho_max / img.width, alto_max / img.height)
    tam = (max(1, round(img.width * k)), max(1, round(img.height * k)))
    return img.convert("RGBa").resize(tam, Image.LANCZOS).convert("RGBA")


def sobre(fondo_color, logo, tam_lienzo, pos):
    lienzo = Image.new("RGBA", tam_lienzo, fondo_color + (255,))
    lienzo.alpha_composite(logo, pos)
    return lienzo.convert("RGB")


# Pantalla de arranque: logo centrado sobre negro, con margen amplio alrededor
grande = reducir(im, min(ancho_arranque, W - 24), H - 40)
arranque = sobre((0, 0, 0), grande, (W, H), ((W - grande.width) // 2, (H - grande.height) // 2))
arranque = arranque.filter(ImageFilter.UnsharpMask(radius=0.8, percent=60, threshold=2))
arranque.save(f"{salida}/logo-arranque.png")
with open(f"{salida}/logo-arranque.rgb", "wb") as f:
    f.write(arranque.tobytes())

# Menú: versión pequeña sobre el azul noche del fondo
pequeno = reducir(im, 200, alto_menu)
menu = sobre(FONDO_MENU, pequeno, pequeno.size, (0, 0))
menu = menu.filter(ImageFilter.UnsharpMask(radius=0.6, percent=80, threshold=1))
menu.save(f"{salida}/logo-menu.png")

print(f"Logo recortado: {im.width}x{im.height} -> arranque {grande.width}x{grande.height}, "
      f"menú {pequeno.width}x{pequeno.height}")
