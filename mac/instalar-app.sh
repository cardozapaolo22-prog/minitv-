#!/bin/bash
# Crea (o actualiza) en el Escritorio las apps de la MiniTV, con el ícono de Paolo TV:
#   "Enviar a MiniTV"          arrastrar videos, juegos o carpetas encima
#   "Imagen para otra MiniTV"  imagen limpia del sistema para armar otra MiniTV igual
# Uso: mac/instalar-app.sh      (la MiniTV encendida, solo para bajar el ícono)
set -euo pipefail
AQUI="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ICNS=""
if curl -fsS --max-time 20 -o "$TMP/icono.png" "http://${MINITV_WEB:-minitv.local}/icono-512.png"; then
    mkdir "$TMP/icono.iconset"
    for t in 16 32 128 256 512; do
        sips -z $t $t "$TMP/icono.png" --out "$TMP/icono.iconset/icon_${t}x${t}.png" >/dev/null
        sips -z $((t * 2)) $((t * 2)) "$TMP/icono.png" --out "$TMP/icono.iconset/icon_${t}x${t}@2x.png" >/dev/null
    done
    iconutil -c icns "$TMP/icono.iconset" -o "$TMP/applet.icns" && ICNS="$TMP/applet.icns"
fi

crear_app() {   # crear_app "Nombre" archivo.applescript guion.sh
    local app="$HOME/Desktop/$1.app"
    rm -rf "$app"
    osacompile -o "$app" "$AQUI/$2"
    cp "$AQUI/$3" "$app/Contents/Resources/"
    chmod +x "$app/Contents/Resources/$3"
    [ -n "$ICNS" ] && cp "$ICNS" "$app/Contents/Resources/applet.icns"
    touch "$app"
    echo "Listo: $app"
}
crear_app "Enviar a MiniTV" enviar.applescript enviar-a-minitv.sh
crear_app "Imagen para otra MiniTV" imagen.applescript imagen-otra-minitv.sh
