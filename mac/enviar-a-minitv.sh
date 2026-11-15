#!/bin/bash
# Enviar a MiniTV: lo lanza la app "Enviar a MiniTV" del Escritorio (arrastrar videos, juegos o carpetas
# encima del ícono). Videos -> pregunta la serie, los convierte en la Mac (recodificar-minitv.sh, rápido)
# y los sube; juegos -> enviar-juegos (con portada). Avisa con notificaciones y una ventana al terminar.
# Para borrar u ordenar: página Administrar del control (http://minitv.local/admin.html).
# Solo herramientas de macOS + ffmpeg (el mismo que usa recodificar-minitv.sh).
set -uo pipefail
# Abierta desde el Escritorio, la app no hereda el PATH de la Terminal: buscar ffmpeg donde suele estar
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$PATH"
DIR="${MINITV_CARPETA:-$HOME/minitv}"              # donde están recodificar-minitv.sh y enviar-juegos
PI="${MINITV_HOST:-paolo@raspberrypi.local}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)
REG="$DIR/enviar-a-minitv.log"
EXT_VIDEO="mp4|mkv|avi|mov|m4v|wmv|mpg|mpeg|webm|flv|3gp|ts|vob"
EXT_JUEGO="gb|gbc|gba|nes|sfc|smc|md|gen|smd|bin|cue|chd|pbp|m3u|zip"

avisar() { osascript -e "display notification \"$1\" with title \"Enviar a MiniTV\"" >/dev/null 2>&1 || true; }
ventana() {  # ventana TEXTO [icono]
    osascript -e "display dialog \"$1\" with title \"Enviar a MiniTV\" buttons {\"OK\"} default button \"OK\" with icon ${2:-note}" >/dev/null 2>&1 || true
}
elegir() {   # elegir "pregunta" opción1 opción2 ... -> imprime la elegida ("" si cancela)
    local q=$1 lista="" o; shift
    for o in "$@"; do lista+="\"${o//\"/\\\"}\", "; done
    osascript -e "set r to choose from list {${lista%, }} with title \"Enviar a MiniTV\" with prompt \"$q\" OK button name \"Elegir\" cancel button name \"Cancelar\"" \
              -e 'if r is false then return ""' -e 'return item 1 of r' 2>/dev/null
}
preguntar() { # preguntar "pregunta" -> texto escrito ("" si cancela)
    osascript -e "set r to display dialog \"$1\" default answer \"\" with title \"Enviar a MiniTV\" buttons {\"Cancelar\", \"Aceptar\"} default button \"Aceptar\"" \
              -e 'if button returned of r is "Cancelar" then return ""' -e 'return text returned of r' 2>/dev/null
}
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$REG"; }

[ $# -gt 0 ] || { ventana "Arrastra videos, juegos o carpetas encima del ícono de Enviar a MiniTV."; exit 0; }
log "===== Enviar: $* ====="

# Separar videos y juegos (también dentro de carpetas)
VIDEOS=(); JUEGOS=()
while IFS= read -r -d '' f; do
    case "$(basename "$f")" in ._*|.*) continue ;; esac
    ext=$(echo "${f##*.}" | tr '[:upper:]' '[:lower:]')
    if [[ "$ext" =~ ^($EXT_VIDEO)$ ]]; then VIDEOS+=("$f")
    elif [[ "$ext" =~ ^($EXT_JUEGO)$ ]]; then JUEGOS+=("$f"); fi
done < <(find "$@" -type f -print0 2>/dev/null | sort -z)
if [ ${#VIDEOS[@]} -eq 0 ] && [ ${#JUEGOS[@]} -eq 0 ]; then
    ventana "No encontré videos ni juegos en lo que arrastraste." caution; exit 0
fi

if [ ${#VIDEOS[@]} -gt 0 ] && ! command -v ffmpeg >/dev/null; then
    ventana "Para convertir videos falta ffmpeg en esta Mac (no lo encuentro en ~/.local/bin, /opt/homebrew/bin ni /usr/local/bin)." caution; exit 1
fi
if ! "${SSH[@]}" "$PI" true 2>>"$REG"; then
    ventana "No encuentro la MiniTV. ¿Está encendida y conectada al mismo wifi que esta Mac?" caution; exit 1
fi

RESUMEN=""
# ----- videos -----
if [ ${#VIDEOS[@]} -gt 0 ]; then
    SERIES=()
    while IFS= read -r s; do [ -n "$s" ] && SERIES+=("$s"); done < <("${SSH[@]}" "$PI" \
        'cd ~/videos && for d in */; do d=${d%/}; case "$d" in logos|.*) ;; *) echo "$d";; esac; done' 2>>"$REG" | sort -n)
    NOMBRES=(); for s in "${SERIES[@]+"${SERIES[@]}"}"; do NOMBRES+=("$(echo "$s" | sed -E 's/^[0-9]+ +//')"); done
    eleccion=$(elegir "¿A qué serie van estos ${#VIDEOS[@]} videos?" "➕ Serie nueva…" "${NOMBRES[@]+"${NOMBRES[@]}"}")
    [ -n "$eleccion" ] || { log "cancelado"; exit 0; }
    if [ "$eleccion" = "➕ Serie nueva…" ]; then
        nueva=$(preguntar "Nombre de la serie nueva (por ejemplo: Bob Esponja)" | tr -d '/\\' | sed -E 's/^ +| +$//g')
        [ -n "$nueva" ] || { log "cancelado"; exit 0; }
        n=0; for s in "${SERIES[@]+"${SERIES[@]}"}"; do k=$((10#$(echo "$s" | grep -oE '^[0-9]+' || echo 0))); [ $k -gt $n ] && n=$k; done
        SERIE=$(printf "%02d %s" $((n + 1)) "$nueva")
    else
        SERIE=""
        for i in "${!NOMBRES[@]}"; do [ "${NOMBRES[$i]}" = "$eleccion" ] && SERIE="${SERIES[$i]}"; done
    fi
    tipo=$(elegir "¿Qué tipo de video es? (ajusta la compresión)" "Dibujos animados" "Imagen real (personas)")
    [ -n "$tipo" ] || { log "cancelado"; exit 0; }
    TUNE=(); [ "$tipo" = "Imagen real (personas)" ] && TUNE=(-t none)
    avisar "Convirtiendo y subiendo ${#VIDEOS[@]} videos a ${SERIE#* }… (te aviso al terminar)"
    log "videos -> $SERIE (${tipo})"
    # Nombres limpios ("Batman.La.broma.asesina.2016.DVDrip-lat" -> "Batman La broma asesina (2016)"),
    # con la misma regla que la TV (limpiar_titulo de minitv_admin); el video se convierte con ese nombre
    ENLACES=$(mktemp -d)
    LIMPIOS=()
    i=0
    while IFS= read -r limpio; do
        f="${VIDEOS[$i]}"; i=$((i + 1))
        [ -n "$limpio" ] || limpio=$(basename "${f%.*}")
        limpio=${limpio//\//-}
        ln -s "$f" "$ENLACES/$limpio.${f##*.}" 2>/dev/null && LIMPIOS+=("$ENLACES/$limpio.${f##*.}") || LIMPIOS+=("$f")
    done < <(for f in "${VIDEOS[@]}"; do b=$(basename "$f"); echo "${b%.*}"; done | "${SSH[@]}" "$PI" \
             'python3 -c "import sys; sys.path.insert(0, \"/usr/local/lib/minitv\"); from minitv_admin import limpiar_titulo as L; [print(L(l.rstrip(chr(10)))) for l in sys.stdin]"' 2>>"$REG" \
             || for f in "${VIDEOS[@]}"; do echo; done)
    [ ${#LIMPIOS[@]} -eq ${#VIDEOS[@]} ] || LIMPIOS=("${VIDEOS[@]}")
    SALIDA_REC=$(mktemp)
    ( cd "$DIR" && /usr/bin/caffeinate -i ./recodificar-minitv.sh -c "$SERIE" -e "${TUNE[@]+"${TUNE[@]}"}" "${LIMPIOS[@]}" ) > "$SALIDA_REC" 2>&1
    cat "$SALIDA_REC" >> "$REG"
    rm -rf "$ENLACES"
    "${SSH[@]}" "$PI" minitv-normalizar >> "$REG" 2>&1 || true
    # Lo que de verdad pasó: "Listo: N recodificados, M ya existían, F fallidos" y lo que hay en la TV
    read -r ok ya fallos < <(sed -nE 's/^Listo: ([0-9]+) recodificados, ([0-9]+) ya exist[^,]*, ([0-9]+) fallidos.*/\1 \2 \3/p' "$SALIDA_REC" | tail -1)
    en_tv=$("${SSH[@]}" "$PI" "ls -1 videos/$(printf '%q' "$SERIE") 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ')
    if [ -z "${ok:-}" ]; then
        error=$(grep -m1 -E '^Error' "$SALIDA_REC" | tr -d '"\\')
        rm -f "$SALIDA_REC"
        log "FALLÓ la conversión: ${error:-sin detalle}"
        ventana "No se pudieron convertir los videos.\n\n${error:-Revisa el registro: minitv/enviar-a-minitv.log}" caution
        exit 1
    fi
    rm -f "$SALIDA_REC"
    RESUMEN+="Videos de «${SERIE#* }»: $ok convertidos y subidos"
    [ "${ya:-0}" -gt 0 ] && RESUMEN+=", $ya ya estaban"
    [ "${fallos:-0}" -gt 0 ] && RESUMEN+=", $fallos NO se pudieron convertir"
    RESUMEN+=". En la TV hay ${en_tv:-?} episodios de esta serie.\n"
fi

# ----- juegos -----
if [ ${#JUEGOS[@]} -gt 0 ]; then
    avisar "Subiendo ${#JUEGOS[@]} juegos con sus portadas…"
    log "juegos: ${#JUEGOS[@]}"
    if ( cd "$DIR" && ./enviar-juegos "${JUEGOS[@]}" ) >> "$REG" 2>&1; then
        RESUMEN+="Juegos: ${#JUEGOS[@]} archivos enviados (aparecen en Juegos).\n"
    else
        RESUMEN+="Juegos: hubo problemas con algunos (detalles en enviar-a-minitv.log).\n"
    fi
fi

log "listo"
avisar "Listo"
ventana "Listo.\n\n${RESUMEN}\nVuelve al menú de la TV (botón 1) para verlos."
