#!/bin/bash
# Genera las pantallas de la MiniTV (320x240, H.264, sin audio):
#   encendido.mp4  - animación de encendido tipo tubo (1,3 s)
#   sin-senal.mp4  - barras de colores con "SIN SEÑAL" (10 s, se reproduce en bucle)
# Uso: ./generar-pantallas.sh [carpeta_salida]   (por defecto: ./pantallas)
set -euo pipefail

OUT="${1:-./pantallas}"
FUENTE="/System/Library/Fonts/Supplemental/Arial Bold.ttf"
mkdir -p "$OUT"
X264=(-c:v libx264 -preset slow -crf 18 -profile:v high -level:v 3.0 -pix_fmt yuv420p -movflags +faststart -an)

# --- Encendido tipo tubo ---------------------------------------------------
# W: semiancho de la línea (0 -> 160 px en 0,12 s)
# H: semialto (1 px hasta 0,12 s, luego se abre a 120 px en 0,23 s)
# B: brillo (pleno hasta 0,45 s, luego se funde a negro hacia 1,15 s)
W='160*min(1,T/0.12)'
H="if(lt(T,0.12),1,1+119*min(1,(T-0.12)/0.23))"
B="if(lt(T,0.45),255,255*max(0,(1.15-T)/0.7))"
DENTRO="lte(abs(X-160),$W)*lte(abs(Y-120),$H)"
GRANO="(0.92+0.08*random(1))"   # grano proporcional al brillo: el negro queda negro puro
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=black:s=320x240:r=30:d=1.3,format=rgb24" \
    -vf "geq=r='0.86*$B*$DENTRO*$GRANO':g='0.93*$B*$DENTRO*$GRANO':b='$B*$DENTRO*$GRANO',gblur=sigma=1.5" \
    "${X264[@]}" "$OUT/encendido.mp4"

# --- Sin señal ---------------------------------------------------------------
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "smptebars=s=320x240:r=30:d=10" \
    -vf "drawbox=x=50:y=92:w=220:h=56:color=black@0.85:t=fill,drawtext=fontfile='$FUENTE':text='SIN SEÑAL':fontsize=30:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2:enable='lt(mod(t,2),1.5)'" \
    "${X264[@]}" "$OUT/sin-senal.mp4"

ls -lh "$OUT"
