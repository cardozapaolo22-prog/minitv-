#!/bin/bash
# Devuelve el contenido respaldado (~/MiniTV-Respaldo/contenido) a la MiniTV: videos, juegos (portadas,
# partidas, estados, BIOS), memoria de reproducción y opciones de los emuladores.
# Lo lanza la app "Restaurar contenido MiniTV". No borra nada de la MiniTV: solo agrega o actualiza.
set -uo pipefail

PI="${MINITV_HOST:-paolo@raspberrypi.local}"
CONT="$HOME/MiniTV-Respaldo/contenido"
REG="$HOME/MiniTV-Respaldo/registro.txt"
SSH_OPC=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=10)

avisar() { osascript -e "display notification \"$1\" with title \"Restaurar MiniTV\"" >/dev/null 2>&1 || true; }
dialogo() { osascript -e "display dialog \"$1\" with title \"Restaurar MiniTV\" buttons {\"OK\"} default button \"OK\" with icon ${2:-note}" >/dev/null 2>&1 || true; }
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] (restaurar) $*" >> "$REG"; }
fallar() { log "ERROR: $1"; ssh "${SSH_OPC[@]}" "$PI" "sudo -n systemctl start minitv" >/dev/null 2>&1; dialogo "No se pudo completar.\n\n$1\n\nDetalles en MiniTV-Respaldo/registro.txt" caution; exit 1; }

[ -d "$CONT/videos" ] || { dialogo "No hay ningún respaldo de contenido en MiniTV-Respaldo/contenido. Primero usa Respaldar MiniTV." caution; exit 1; }
ssh "${SSH_OPC[@]}" "$PI" true 2>/dev/null \
    || { dialogo "No se pudo conectar con la MiniTV ($PI). ¿Está encendida y en el mismo WiFi?" caution; exit 1; }

log "===== Restauración de contenido iniciada ====="
avisar "Copiando videos y juegos a la MiniTV…"
rsync -a --partial -e "ssh ${SSH_OPC[*]}" "$CONT/videos/" "$PI:videos/" >> "$REG" 2>&1 || fallar "Falló la copia de los videos."
rsync -a --partial -e "ssh ${SSH_OPC[*]}" "$CONT/juegos/" "$PI:juegos/" >> "$REG" 2>&1 || fallar "Falló la copia de los juegos."
# La memoria y las opciones con la MiniTV detenida (si no, la sobrescribiría al cerrar)
ssh "${SSH_OPC[@]}" "$PI" "sudo -n systemctl stop minitv; mkdir -p .local/state/minitv .config/retroarch" >> "$REG" 2>&1
[ -f "$CONT/memoria/estado.json" ] && { rsync -a -e "ssh ${SSH_OPC[*]}" "$CONT/memoria/estado.json" "$PI:.local/state/minitv/" >> "$REG" 2>&1 || fallar "Falló la copia de la memoria de reproducción."; }
[ -f "$CONT/retroarch/opciones-nucleos.cfg" ] && rsync -a -e "ssh ${SSH_OPC[*]}" "$CONT/retroarch/opciones-nucleos.cfg" "$PI:.config/retroarch/" >> "$REG" 2>&1
ssh "${SSH_OPC[@]}" "$PI" "sudo -n systemctl start minitv" >> "$REG" 2>&1
log "===== Restauración de contenido terminada ====="
dialogo "Listo: la MiniTV ya tiene de nuevo los videos, los juegos, las partidas y la memoria de reproducción."
