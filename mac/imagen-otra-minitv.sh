#!/bin/bash
# Imagen para otra MiniTV: lo lanza la app "Imagen para otra MiniTV" del Escritorio.
# Pide a la MiniTV una imagen LIMPIA del sistema (minitv-imagen --limpia: sin tus videos, juegos,
# partidas, wifi, Bluetooth ni claves), la descarga a ~/MiniTV-Respaldo/otra-minitv/, comprueba que
# llegó entera (SHA-256) y explica cómo grabarla en una tarjeta con Raspberry Pi Imager.
# Mientras se copia el sistema (unos minutos) la TV se apaga sola y vuelve.
set -uo pipefail
PI="${MINITV_HOST:-paolo@raspberrypi.local}"
DEST="$HOME/MiniTV-Respaldo/otra-minitv"
REG="$DEST/registro.txt"
SSH_OPC=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=10)
mkdir -p "$DEST"

avisar() { osascript -e "display notification \"$1\" with title \"Imagen para otra MiniTV\"" >/dev/null 2>&1 || true; }
ventana() {
    osascript -e "display dialog \"$1\" with title \"Imagen para otra MiniTV\" buttons {\"Abrir carpeta\", \"OK\"} default button \"OK\" with icon ${2:-note}" \
              -e 'if button returned of result is "Abrir carpeta" then do shell script "open " & quoted form of (POSIX path of (path to home folder) & "MiniTV-Respaldo/otra-minitv")' \
              >/dev/null 2>&1 || true
}
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$REG"; }
fallar() { log "ERROR: $1"; ventana "No se pudo crear la imagen.\n\n$1\n\nDetalles en MiniTV-Respaldo/otra-minitv/registro.txt" caution; exit 1; }
copiar() {   # rsync con reintentos (el wifi de la TV es débil)
    local i
    for i in 1 2 3 4 5 6; do
        rsync -a --partial --timeout=60 -e "ssh ${SSH_OPC[*]}" "$@" >> "$REG" 2>&1 && return 0
        log "  (corte de conexión, reintento $i de 6 en 20 s)"; sleep 20
    done
    return 1
}

log "===== Imagen limpia ====="
ssh "${SSH_OPC[@]}" "$PI" true 2>>"$REG" || fallar "No encuentro la MiniTV. ¿Está encendida y en el mismo wifi?"
avisar "La MiniTV está preparando la imagen (se apaga unos minutos y vuelve)…"
ssh "${SSH_OPC[@]}" "$PI" "sudo -n /usr/local/sbin/minitv-imagen --limpia" >> "$REG" 2>&1 || fallar "La MiniTV no pudo crear la imagen."
IMG=$(ssh "${SSH_OPC[@]}" "$PI" "ls -1t respaldo-imagen/minitv-limpia-*.img.gz | head -1") || fallar "No encontré la imagen en la MiniTV."
NOMBRE=$(basename "$IMG")
avisar "Descargando la imagen a la Mac (puede tardar un rato)…"
copiar "$PI:$IMG" "$PI:$IMG.sha256" "$DEST/" || fallar "Se cortó la descarga. Vuelve a abrir la app: sigue donde quedó."
[ "$(shasum -a 256 "$DEST/$NOMBRE" | awk '{print $1}')" = "$(cat "$DEST/$NOMBRE.sha256")" ] \
    || fallar "La imagen descargada no coincide con la original. Vuelve a intentarlo."
ssh "${SSH_OPC[@]}" "$PI" "rm -f respaldo-imagen/minitv-limpia-*.img.gz respaldo-imagen/minitv-limpia-*.img.gz.sha256" >> "$REG" 2>&1 || true
ls -1t "$DEST"/minitv-limpia-*.img.gz 2>/dev/null | tail -n +2 | while read -r v; do rm -f "$v" "$v.sha256"; done
log "Lista: $NOMBRE"
ventana "Imagen lista: $NOMBRE ($(du -h "$DEST/$NOMBRE" | cut -f1)).\n\nPara armar otra MiniTV:\n1. Raspberry Pi Imager → Elegir SO → «Usar personalizado» → esta imagen.\n2. Grabarla en una microSD (32 GB o más) y NO aplicar ajustes de personalización.\n3. Ponerla en la otra MiniTV y encenderla: crea su red «MiniTV»; la clave sale en Ajustes → Control remoto.\n\nGuía completa: GUIA-ARMADO.md en el repositorio."
