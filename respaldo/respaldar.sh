#!/bin/bash
# Respaldo completo de la MiniTV en la Mac (lo lanza la app "Respaldar MiniTV").
#   1) Contenido -> ~/MiniTV-Respaldo/contenido   (videos, juegos con portadas/partidas/estados/BIOS,
#      memoria de reproducción, opciones de los emuladores). Incremental: solo copia lo nuevo o cambiado.
#   2) Imagen del sistema -> ~/MiniTV-Respaldo/sistema/minitv-sistema-AAAA-MM-DD.img.gz (para
#      Raspberry Pi Imager). La hace la Pi en vivo (minitv-imagen); aquí se descarga y se verifica.
# Avisa con notificaciones y al terminar muestra un resumen. Registro: ~/MiniTV-Respaldo/registro.txt
# Solo herramientas de macOS (bash, ssh, rsync, shasum, osascript, caffeinate).
set -uo pipefail

PI="${MINITV_HOST:-paolo@raspberrypi.local}"
RAIZ="$HOME/MiniTV-Respaldo"
CONT="$RAIZ/contenido"
SIS="$RAIZ/sistema"
REG="$RAIZ/registro.txt"
CERROJO="$RAIZ/.respaldo-en-curso"
SSH_OPC=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=10)

mkdir -p "$CONT" "$SIS"

avisar() {  # notificación (no interrumpe)
    osascript -e "display notification \"$1\" with title \"Respaldar MiniTV\"" >/dev/null 2>&1 || true
}
dialogo() {  # ventana que espera al usuario
    osascript -e "display dialog \"$1\" with title \"Respaldar MiniTV\" buttons {\"Abrir carpeta\", \"OK\"} default button \"OK\" with icon ${2:-note}" \
              -e 'if button returned of result is "Abrir carpeta" then do shell script "open " & quoted form of (POSIX path of (path to home folder) & "MiniTV-Respaldo")' \
              >/dev/null 2>&1 || true
}
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$REG"; }
# rsync con reintentos: el WiFi de la Pi a veces se congela (señal débil, antena compartida con el
# Bluetooth). --partial sigue donde quedó; --timeout corta a los 60 s sin respuesta en vez de 5 min.
copiar() {
    local i
    for i in 1 2 3 4 5 6; do
        rsync -a --partial --timeout=60 -e "ssh ${SSH_OPC[*]}" "$@" >> "$REG" 2>&1 && return 0
        log "  (corte de conexión, reintento $i de 6 en 20 s)"
        sleep 20
    done
    return 1
}
fallar() {
    log "ERROR: $1"
    rm -f "$CERROJO"                 # que la ventana de error no bloquee el próximo respaldo
    dialogo "No se pudo completar el respaldo.\n\n$1\n\nDetalles en MiniTV-Respaldo/registro.txt" caution
    rm -f "$CERROJO"
    exit 1
}

# Un solo respaldo a la vez
if [ -e "$CERROJO" ] && kill -0 "$(cat "$CERROJO")" 2>/dev/null; then
    dialogo "Ya hay un respaldo en curso. Espera el aviso de que terminó." caution
    exit 0
fi
echo $$ > "$CERROJO"
trap 'rm -f "$CERROJO"' EXIT

INICIO=$(date +%s)
log "===== Respaldo iniciado ====="
avisar "Respaldo iniciado. Puede tardar un rato; te aviso al terminar."

ssh "${SSH_OPC[@]}" "$PI" true 2>>"$REG" \
    || fallar "No se pudo conectar con la MiniTV ($PI). ¿Está encendida y en el mismo WiFi?"

# ----- 1) Contenido -----
avisar "Paso 1 de 2: copiando videos, juegos y partidas…"
log "Contenido: videos"
copiar "$PI:videos/" "$CONT/videos/" \
    || fallar "Falló la copia de los videos."
log "Contenido: juegos (portadas, partidas, estados, BIOS)"
copiar "$PI:juegos/" "$CONT/juegos/" \
    || fallar "Falló la copia de los juegos."
log "Contenido: memoria de reproducción y opciones"
mkdir -p "$CONT/memoria" "$CONT/retroarch"
rsync -a -e "ssh ${SSH_OPC[*]}" "$PI:.local/state/minitv/estado.json" "$CONT/memoria/" >> "$REG" 2>&1 \
    || fallar "Falló la copia de la memoria de reproducción."
rsync -a -e "ssh ${SSH_OPC[*]}" "$PI:.config/retroarch/opciones-nucleos.cfg" "$CONT/retroarch/" >> "$REG" 2>&1 || true

# ----- 2) Imagen del sistema -----
avisar "Paso 2 de 2: la MiniTV está creando la imagen del sistema (se apaga unos minutos)…"
log "Imagen: creándola en la Pi"
ssh "${SSH_OPC[@]}" "$PI" "sudo -n /usr/local/sbin/minitv-imagen" >> "$REG" 2>&1 \
    || fallar "La MiniTV no pudo crear la imagen del sistema."
IMG=$(ssh "${SSH_OPC[@]}" "$PI" "ls -1t respaldo-imagen/minitv-sistema-*.img.gz | head -1") \
    || fallar "No se encontró la imagen en la MiniTV."
NOMBRE=$(basename "$IMG")
avisar "Descargando la imagen del sistema a la Mac…"
log "Imagen: descargando $NOMBRE"
copiar "$PI:$IMG" "$PI:$IMG.sha256" "$SIS/" \
    || fallar "Falló la descarga de la imagen."
if [ "$(shasum -a 256 "$SIS/$NOMBRE" | awk '{print $1}')" != "$(cat "$SIS/$NOMBRE.sha256")" ]; then
    fallar "La imagen descargada no coincide con la original (huella SHA-256 distinta). Vuelve a intentarlo."
fi
log "Imagen: verificada (SHA-256 correcta); se borra la copia temporal de la Pi"
ssh "${SSH_OPC[@]}" "$PI" "rm -f respaldo-imagen/minitv-sistema-*.img.gz respaldo-imagen/minitv-sistema-*.img.gz.sha256" >> "$REG" 2>&1 || true
# Guardar solo las dos imágenes más recientes
ls -1t "$SIS"/minitv-sistema-*.img.gz 2>/dev/null | tail -n +3 | while read -r viejo; do
    log "Imagen antigua borrada: $(basename "$viejo")"; rm -f "$viejo" "$viejo.sha256"
done

# ----- Resumen -----
T_IMG=$(du -sh "$SIS/$NOMBRE" | cut -f1)
T_CONT=$(du -sh "$CONT" | cut -f1)
T_TOTAL=$(du -sh "$RAIZ" | cut -f1)
MIN=$(( ($(date +%s) - INICIO + 59) / 60 ))
log "===== Respaldo terminado en $MIN min: imagen $T_IMG, contenido $T_CONT, total $T_TOTAL ====="
dialogo "Respaldo terminado en $MIN minutos.\n\nImagen del sistema: $NOMBRE ($T_IMG)\nContenido (videos, juegos, partidas): $T_CONT\nTotal en MiniTV-Respaldo: $T_TOTAL\n\nCómo restaurar: MiniTV-Respaldo/LEEME.txt"
