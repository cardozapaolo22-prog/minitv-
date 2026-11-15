#!/bin/bash
# Crea (o actualiza) la app "Enviar a MiniTV" en el Escritorio, con el ícono de Paolo TV.
# Uso: mac/instalar-app.sh      (necesita la MiniTV encendida solo para bajar el ícono)
set -euo pipefail
AQUI="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Desktop/Enviar a MiniTV.app"
rm -rf "$APP"
osacompile -o "$APP" "$AQUI/enviar.applescript"
cp "$AQUI/enviar-a-minitv.sh" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/enviar-a-minitv.sh"
TMP=$(mktemp -d)
if curl -fsS --max-time 20 -o "$TMP/icono.png" "http://${MINITV_WEB:-minitv.local}/icono-512.png"; then
    mkdir "$TMP/icono.iconset"
    for t in 16 32 128 256 512; do
        sips -z $t $t "$TMP/icono.png" --out "$TMP/icono.iconset/icon_${t}x${t}.png" >/dev/null
        sips -z $((t * 2)) $((t * 2)) "$TMP/icono.png" --out "$TMP/icono.iconset/icon_${t}x${t}@2x.png" >/dev/null
    done
    iconutil -c icns "$TMP/icono.iconset" -o "$APP/Contents/Resources/applet.icns"
fi
rm -rf "$TMP"
touch "$APP"
echo "Listo: $APP"
