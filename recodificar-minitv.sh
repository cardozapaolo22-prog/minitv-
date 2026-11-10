#!/bin/bash
# Recodifica videos a 320x240 H.264 (MP4) para la MiniTV:
# Raspberry Pi Zero 2 W + pantalla ILI9341 con fbcp-ili9341.
set -euo pipefail

PI_HOST="${MINITV_HOST:-paolo@raspberrypi.local}"
PI_DIR="${MINITV_DIR:-videos}"
SALIDA="./minitv_320x240"
MODO=ajustar      # ajustar = imagen completa con bandas negras; recortar = llena la pantalla
AUDIO=si
# Ajustes por defecto elegidos tras la prueba del 4x20 (2026-11-05): ~21% menos peso que
# CRF 26 + mono 64 kb/s, misma CPU en la Pi y diferencia de calidad imperceptible.
AUDIO_MONO=si       # mono con volumen normalizado (loudnorm); -E para estéreo 96 kb/s
AUDIO_KBPS=48       # -a: bitrate del audio mono
TUNE=animation      # -t: ajuste de x264 (animation para dibujos; -t none para imagen real)
CRF=28
ENVIAR=no
SERIE=""            # canal de destino, p. ej. "02 Los Simpson" (una carpeta por serie)
RECORTAR_NEGRO=si   # quitar el negro con el que empiezan muchos videos (fundido de entrada)
QUITAR_BANDAS=si    # quitar bandas negras fijas (p. ej. un 4:3 metido en un 16:9)

uso() {
    cat <<EOF
Uso: $(basename "$0") [opciones] VIDEO|CARPETA ...

  -o DIR   carpeta de salida (por defecto: $SALIDA)
  -r       recortar para llenar la pantalla (por defecto: bandas negras)
  -s       sin audio
  -m       audio mono con volumen normalizado (loudnorm, -16 LUFS) — es lo predeterminado
  -E       audio estéreo AAC 96 kb/s sin normalizar (en lugar de mono)
  -a KBPS  bitrate del audio mono (por defecto: $AUDIO_KBPS)
  -t TUNE  ajuste de x264 según el contenido (por defecto: $TUNE; "none" para imagen real)
  -q CRF   calidad x264: menor = mejor y más pesado (por defecto: $CRF)
  -n       no recortar el negro del principio (por defecto se recorta)
  -B       no quitar las bandas negras laterales/superiores (por defecto se quitan si las hay)
  -c SERIE serie/canal de destino, "NN Nombre" (p. ej. "02 Los Simpson"); si no existe se crea
  -e       subir cada video a la Pi ($PI_HOST:$PI_DIR/SERIE) en cuanto termina; requiere -c
  -h       mostrar esta ayuda

Ejemplos:
  $(basename "$0") -c "02 Los Simpson" -e "/Volumes/USB/los simpson"
  $(basename "$0") -c "05 Caricaturas" -r -e ~/Movies/caricaturas/
EOF
}

while getopts "o:rsmEa:t:q:nBc:eh" opt; do
    case $opt in
        o) SALIDA=$OPTARG ;;
        c) SERIE=$OPTARG ;;
        r) MODO=recortar ;;
        s) AUDIO=no ;;
        m) AUDIO_MONO=si ;;
        E) AUDIO_MONO=no ;;
        a) AUDIO_KBPS=$OPTARG ;;
        t) TUNE=$OPTARG ;;
        q) CRF=$OPTARG ;;
        n) RECORTAR_NEGRO=no ;;
        B) QUITAR_BANDAS=no ;;
        e) ENVIAR=si ;;
        h) uso; exit 0 ;;
        *) uso; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -gt 0 ] || { uso; exit 1; }
if [ -n "$SERIE" ]; then
    if ! [[ "$SERIE" =~ ^[0-9]+\ .+ ]]; then
        echo "Error: la serie debe ser \"NN Nombre\", con el número de canal delante (p. ej. \"02 Los Simpson\")." >&2
        exit 1
    fi
    SALIDA="$SALIDA/$SERIE"
elif [ "$ENVIAR" = si ]; then
    echo "Error: para enviar (-e) indica la serie con -c, p. ej. -c \"02 Los Simpson\"." >&2
    exit 1
fi

if ! command -v ffmpeg >/dev/null; then
    echo "Error: no encuentro ffmpeg. Instálalo y asegúrate de que esté en el PATH." >&2
    exit 1
fi

# Video: H.264 perfil High nivel 3.0 (de sobra para 320x240; la GPU de la Pi lo decodifica por hardware)
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
    VCODEC=(-c:v libx264 -preset slow -crf "$CRF" -profile:v high -level:v 3.0)
    if [ -n "$TUNE" ] && [ "$TUNE" != none ]; then VCODEC+=(-tune "$TUNE"); fi
else
    echo "Aviso: este ffmpeg no tiene libx264; uso el codificador de hardware del Mac (h264_videotoolbox)." >&2
    VCODEC=(-c:v h264_videotoolbox -b:v 700k -profile:v high)
fi

if [ "$MODO" = recortar ]; then
    VF="scale=320:240:force_original_aspect_ratio=increase:flags=lanczos,crop=320:240,setsar=1"
else
    VF="scale=320:240:force_original_aspect_ratio=decrease:flags=lanczos,pad=320:240:(ow-iw)/2:(oh-ih)/2:black,setsar=1"
fi

if [ "$AUDIO" = si ] && [ "$AUDIO_MONO" = si ]; then
    # Volumen normalizado (EBU R128: -16 LUFS, picos de -1,5 dB) y mezcla a mono
    ACODEC=(-map '0:a:0?' -af "loudnorm=I=-16:TP=-1.5:LRA=11" -c:a aac -b:a "${AUDIO_KBPS}k" -ac 1 -ar 48000)
elif [ "$AUDIO" = si ]; then
    ACODEC=(-map '0:a:0?' -c:a aac -b:a 96k -ac 2 -ar 48000)
else
    ACODEC=(-an)
fi

# Segundos de negro puro al principio del video (0 si no empieza en negro).
# Solo mira los primeros 30 s y solo cuenta un tramo negro que empiece en el primer medio
# segundo (algunos videos tienen un par de cuadros sueltos antes del negro).
negro_inicial() {
    ffmpeg -nostdin -hide_banner -t 30 -i "$1" -map 0:v:0 -vf "blackdetect=d=0.1:pix_th=0.10" -an -f null - 2>&1 |
        awk '/black_start:/ { for (i = 1; i <= NF; i++) { if ($i ~ /^black_start:/) s = substr($i, 13); if ($i ~ /^black_end:/) e = substr($i, 11) }
                              if (s + 0 <= 0.5) { print e; found = 1 }; exit }
             END { if (!found) print 0 }'
}

# Recorte de bandas negras fijas ("crop=w:h:x:y") o vacío si no hay bandas de más del 3%.
bandas_negras() {
    local info iw ih crop w h
    info=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$1") || return 0
    iw=${info%,*}; ih=${info#*,}
    crop=$(ffmpeg -nostdin -hide_banner -ss 60 -t 120 -i "$1" -map 0:v:0 -vf "cropdetect=limit=24:round=2:reset=0" -an -f null - 2>&1 |
        grep -oE "crop=[0-9]+:[0-9]+:[0-9]+:[0-9]+" | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
    [ -n "$crop" ] || return 0
    w=$(echo "$crop" | cut -d= -f2 | cut -d: -f1); h=$(echo "$crop" | cut -d: -f2)
    if [ $((w * 100)) -lt $((iw * 97)) ] || [ $((h * 100)) -lt $((ih * 97)) ]; then echo "$crop"; fi
}

mkdir -p "$SALIDA"
EXT_RE='\.(mp4|m4v|mov|mkv|avi|webm|mpg|mpeg|wmv|flv|3gp|ts|mts)$'

# Reúne la lista de archivos (los argumentos pueden ser archivos o carpetas)
ARCHIVOS=()
for entrada in "$@"; do
    if [ -d "$entrada" ]; then
        # Sin ocultos: en discos exFAT/FAT macOS crea "._nombre" con metadatos, que no son videos
        while IFS= read -r -d '' f; do ARCHIVOS+=("$f"); done < <(find "$entrada" -type f ! -name '.*' -print0 | sort -z)
    elif [ -f "$entrada" ]; then
        ARCHIVOS+=("$entrada")
    else
        echo "Aviso: no existe $entrada" >&2
    fi
done

# Solo los videos (en el orden recibido)
VIDEOS=()
for f in "${ARCHIVOS[@]+"${ARCHIVOS[@]}"}"; do
    shopt -s nocasematch
    [[ "$f" =~ $EXT_RE ]] && [[ "$(basename "$f")" != .* ]] && VIDEOS+=("$f")
    shopt -u nocasematch
done
TOTAL=${#VIDEOS[@]}

if [ "$ENVIAR" = si ]; then
    DESTINO="$PI_DIR/$SERIE"
    DESTINO_Q=$(printf '%q' "$DESTINO")    # escapado para la shell remota (espacios, tildes...)
    ssh "$PI_HOST" "mkdir -p $DESTINO_Q"
fi
# Subidas en paralelo con la conversión: cada video se sube en segundo plano mientras se
# convierte el siguiente. Solo una subida a la vez, en orden (se espera a la anterior).
# Sin --partial: si una subida se corta, rsync borra su temporal y en la Pi no queda un
# archivo a medias con nombre de episodio.
REGISTRO_SUBIDAS=$(mktemp -t minitv-subidas)
PID_SUBIDA=""
subir_ahora() {
    if rsync -t "$1" "$PI_HOST:$DESTINO_Q/"; then
        echo "  Subido a $PI_HOST:$DESTINO: $(basename "$1")"
        echo ok >> "$REGISTRO_SUBIDAS"
    else
        echo "  ERROR al subir $1" >&2
    fi
}
subir() {
    [ "$ENVIAR" = si ] || return 0
    [ -n "$PID_SUBIDA" ] && wait "$PID_SUBIDA"
    subir_ahora "$1" &
    PID_SUBIDA=$!
}

ok=0; saltados=0; fallos=0; n=0
for f in "${VIDEOS[@]+"${VIDEOS[@]}"}"; do
    n=$((n + 1))
    nombre=$(basename "${f%.*}")
    destino="$SALIDA/$nombre.mp4"
    if [ -e "$destino" ] && [ "$destino" -nt "$f" ]; then
        echo "[$n/$TOTAL] = Ya existe: $destino"
        saltados=$((saltados + 1))
        subir "$destino"
        continue
    fi

    echo "[$n/$TOTAL] > $f"
    INICIO=()
    RECORTE=""
    if [ "$QUITAR_BANDAS" = si ]; then
        RECORTE=$(bandas_negras "$f" || true)
        [ -n "$RECORTE" ] && echo "  bandas negras: se quitan ($RECORTE)"
    fi
    if [ "$RECORTAR_NEGRO" = si ]; then
        negro=$(negro_inicial "$f" || echo 0)   # si no se puede analizar, no se recorta
        if awk -v n="$negro" 'BEGIN { exit !(n > 0) }'; then
            echo "  empieza con ${negro} s de negro: se recorta"
            INICIO=(-ss "$negro")   # antes de -i: búsqueda precisa al recodificar; audio y video juntos
        fi
    fi
    # Escribe primero a .part para no dejar archivos a medias si se interrumpe
    if ffmpeg -nostdin -hide_banner -loglevel error -stats -y "${INICIO[@]+"${INICIO[@]}"}" -i "$f" \
        -map 0:v:0 -vf "${RECORTE:+$RECORTE,}$VF" -fpsmax 30 -pix_fmt yuv420p "${VCODEC[@]}" \
        "${ACODEC[@]}" -sn -dn -map_metadata -1 -movflags +faststart \
        -f mp4 "$destino.part"; then
        mv "$destino.part" "$destino"
        echo "  OK: $destino ($(du -h "$destino" | cut -f1))"
        ok=$((ok + 1))
        subir "$destino"
    else
        rm -f "$destino.part"
        echo "  FALLÓ: $f" >&2
        fallos=$((fallos + 1))
    fi
done

if [ -n "$PID_SUBIDA" ]; then
    echo "Esperando a que termine la última subida..."
    wait "$PID_SUBIDA"
fi
echo
echo "Listo: $ok recodificados, $saltados ya existían, $fallos fallidos. Salida: $SALIDA"
[ "$ENVIAR" = si ] && echo "Subidos a la Pi: $(wc -l < "$REGISTRO_SUBIDAS" | tr -d ' '). Aparecen en el menú la próxima vez que lo abras."
rm -f "$REGISTRO_SUBIDAS"

[ "$fallos" -eq 0 ]
