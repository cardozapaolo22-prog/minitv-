"""Administrar la Mini TV desde el navegador (lo usa minitv-remoto, página admin.html).

Todo bajo /api/ y con PIN (4 números; se ve en la TV: Ajustes → Control remoto):
  POST /api/entrar {pin}            -> cookie de sesión (12 h); 5 errores = 1 minuto bloqueado
  GET  /api/sesion                  -> {"ok": bool}
  GET  /api/resumen                 -> espacio, series y episodios, cola de conversión, consolas y juegos
  PUT  /api/subir/video?serie=ID|nueva=NOMBRE&archivo=NOMBRE   (cuerpo = el archivo)
  PUT  /api/subir/juego?archivo=NOMBRE[&consola=ID]            (cuerpo = el archivo)
  POST /api/borrar {tipo: episodio|serie|juego|tarea, ...}
  GET/POST /api/canales             -> canales.txt (canales, sus series y "mosca: izquierda")
  GET/PUT  /api/logo?canal=NOMBRE   -> ~/videos/logos/<canal>.png
  GET  /api/portada?consola=ID&archivo=NOMBRE
  GET/POST /api/wifi                -> redes de casa guardadas / agregar u olvidar una
  POST /api/pin {nuevo}
Los videos subidos se convierten en la TV (ffmpeg, 320x240, como recodificar-minitv.sh) de a uno,
con prioridad baja, y se pausan mientras alguien juega. La cola sobrevive a un reinicio.
"""
import io
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import threading
import time
import unicodedata
import urllib.parse
import urllib.request
import zipfile

VIDEO_DIR = "/home/paolo/videos"
JUEGOS_DIR = "/home/paolo/juegos"
LOGOS_DIR = os.path.join(VIDEO_DIR, "logos")
CANALES = os.path.join(VIDEO_DIR, "canales.txt")
SUBIDAS = os.path.join(VIDEO_DIR, ".subidas")           # originales esperando conversión
COLA = os.path.join(SUBIDAS, "cola.json")
SUBIDAS_JUEGOS = os.path.join(JUEGOS_DIR, ".subidas")
CONFIG = os.path.expanduser("~/.config/minitv/admin.json")
CACHE = os.path.expanduser("~/.cache/minitv")
ESTADO_TV = "/run/minitv/remoto.json"
WIFI = "/usr/local/sbin/minitv-wifi"
EXT_VIDEO = (".mp4", ".mkv", ".avi", ".mov", ".m4v", ".wmv", ".mpg", ".mpeg", ".webm", ".flv", ".3gp", ".ts", ".vob")
LIBRETRO = "https://thumbnails.libretro.com"
PORTADA_W, PORTADA_H = 118, 128
#            carpeta: (nombre en el menú, sistema en libretro, extensiones)
CONSOLAS = {
    "gb":      ("Game Boy", "Nintendo - Game Boy", (".gb",)),
    "gbc":     ("Game Boy Color", "Nintendo - Game Boy Color", (".gbc",)),
    "gba":     ("Game Boy Advance", "Nintendo - Game Boy Advance", (".gba",)),
    "nes":     ("NES", "Nintendo - Nintendo Entertainment System", (".nes",)),
    "snes":    ("Super Nintendo", "Nintendo - Super Nintendo Entertainment System", (".sfc", ".smc")),
    "genesis": ("Sega Genesis", "Sega - Mega Drive - Genesis", (".md", ".gen", ".smd", ".bin")),
    "psx":     ("PlayStation", "Sony - PlayStation", (".cue", ".chd", ".pbp", ".m3u", ".bin")),
    "arcade":  ("Arcade", "FBNeo - Arcade Games", (".zip",)),
}
PROHIBIDOS = re.compile(r"[\x00-\x1f/\\]")
FILE_CUE = re.compile(r'(?im)^\s*FILE\s+"?([^"\r\n]+?)"?\s+\w+\s*$')


def log(*a):
    print("minitv-admin:", *a, flush=True)


def nfc(t):
    return unicodedata.normalize("NFC", t)


def nombre_limpio(nombre, maximo=120):
    """Nombre de archivo seguro (sin rutas, sin empezar con punto)."""
    n = nfc(os.path.basename(str(nombre).replace("\\", "/")))
    n = PROHIBIDOS.sub("", n).strip().lstrip(".").strip()
    return n[:maximo]


def dentro_de(base, ruta):
    """True si ruta está dentro de base (sin trucos con ..)."""
    base, ruta = os.path.realpath(base), os.path.realpath(ruta)
    return ruta.startswith(base + os.sep)


def _borrar_silencioso(ruta):
    try:
        os.remove(ruta)
    except OSError:
        pass


# Etiquetas de descarga que no son parte del título (se comparan en minúsculas, sin puntos)
ETIQUETAS = {
    "dvdrip", "bdrip", "brrip", "bluray", "webrip", "webdl", "web", "dl", "hdrip", "hdtv", "dvdscr", "dvd", "tsrip",
    "camrip", "cam", "hdcam", "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx", "aac", "ac3", "dts",
    "mp3", "dd51", "51", "2160p", "1080p", "720p", "480p", "360p", "4k", "uhd", "hd", "sd", "lat", "latino",
    "castellano", "espanol", "español", "spanish", "esp", "eng", "english", "dual", "sub", "subs", "subtitulado",
    "vose", "proper", "repack", "internal", "limited", "extended", "unrated", "remastered", "yify", "yts", "rarbg",
    "retrotve", "seriesretro", "serieslan", "com", "net", "org", "www", "mkv", "mp4", "avi", "torrent",
}


def limpiar_titulo(nombre):
    """'Batman.La.broma.asesina.2016.DVDrip-lat' -> 'Batman La broma asesina (2016)'.
    Quita puntos y guiones bajos, etiquetas de descarga (DVDrip, 1080p, x264, Latino...), sitios web
    y lo que va entre corchetes; el año queda entre paréntesis. Respeta 1x01, S01E02, etc."""
    original = nombre
    nombre = re.sub(r"\[[^\]]*\]", " ", nombre)                       # [grupo], [www.sitio.com]
    nombre = re.sub(r"(?i)\bwww\.[^\s]+", " ", nombre)
    nombre = re.sub(r"(?<!\d)\.|\.(?!\d{1,2}\b)|_", " ", nombre)      # puntos (no los de 1.5 o 5.1) y _
    partes = []
    for p in nombre.split():
        trozos = [t for t in re.split(r"-", p) if t]
        utiles = [t for t in trozos if re.sub(r"[^0-9a-záéíóúñ]", "", t.lower()) not in ETIQUETAS]
        if trozos and not utiles:
            continue                                                  # p. ej. "DVDrip-lat"
        partes.append("-".join(utiles) if len(utiles) < len(trozos) else p)
    t = " ".join(partes)
    t = re.sub(r"\(\s*\)", "", t)
    t = re.sub(r"(?<![\d(])\b(19[3-9]\d|20[0-4]\d)\b(?![\d)])", r"(\1)", t)   # año suelto -> (2016)
    t = re.sub(r"\s+", " ", t).strip(" -–·")
    if not t or re.fullmatch(r"\(\d{4}\)", t):                      # solo un año: mejor el nombre tal cual
        return original.strip()
    return t


def orden_natural(t):
    return [int(p) if p.isdigit() else p.lower() for p in re.split(r"(\d+)", t)]


# ============================== configuración y PIN ==============================
class Config:
    def __init__(self):
        self.candado = threading.Lock()
        self.datos = {}
        try:
            with open(CONFIG, encoding="utf-8") as f:
                self.datos = json.load(f)
        except (OSError, ValueError):
            pass
        if not re.fullmatch(r"\d{4}", str(self.datos.get("pin", ""))):
            self.datos["pin"] = f"{secrets.randbelow(10000):04d}"      # PIN nuevo: se ve en la TV
            self.guardar()

    def guardar(self):
        with self.candado:
            os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
            tmp = CONFIG + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.datos, f)
            os.chmod(tmp, 0o600)
            os.replace(tmp, CONFIG)


class Sesiones:
    DURACION = 12 * 3600

    def __init__(self, config):
        self.config = config
        self.vivas = {}
        self.errores, self.bloqueo = 0, 0.0
        self.candado = threading.Lock()

    def entrar(self, pin):
        with self.candado:
            t = time.time()
            if t < self.bloqueo:
                return None, f"Demasiados intentos. Espera {int(self.bloqueo - t) + 1} s."
            if secrets.compare_digest(str(pin), str(self.config.datos["pin"])):
                self.errores = 0
                token = secrets.token_urlsafe(24)
                self.vivas[token] = t + self.DURACION
                return token, None
            self.errores += 1
            if self.errores >= 5:
                self.errores, self.bloqueo = 0, t + 60
                return None, "PIN incorrecto. Demasiados intentos: espera 1 minuto."
            return None, "PIN incorrecto."

    def valida(self, token):
        with self.candado:
            fin = self.vivas.get(token or "")
            if fin and fin > time.time():
                return True
            self.vivas.pop(token or "", None)
            return False

    def salir(self, token):
        with self.candado:
            self.vivas.pop(token or "", None)


# ============================== series y videos ==============================
def series():
    """[(id, nombre, carpeta)] de ~/videos ("NN Nombre"), en orden."""
    out = []
    try:
        nombres = os.listdir(VIDEO_DIR)
    except OSError:
        return out
    for n in nombres:
        ruta = os.path.join(VIDEO_DIR, n)
        if n.startswith(".") or n == "logos" or not os.path.isdir(ruta):
            continue
        m = re.match(r"\s*(\d+)\s+(.+)", n)
        out.append((n, m.group(2).strip() if m else n, ruta, int(m.group(1)) if m else 0))
    out.sort(key=lambda s: (s[3], s[1].lower()))
    return [(i, nom, ruta) for i, nom, ruta, _ in out]


def episodios(carpeta):
    try:
        archivos = os.listdir(carpeta)
    except OSError:
        return []
    eps = [f for f in archivos if f.lower().endswith(EXT_VIDEO) and not f.startswith(".")]
    return sorted(eps, key=orden_natural)


def carpeta_serie_nueva(nombre):
    """Crea "NN Nombre" con el número siguiente (o devuelve la que ya se llama así)."""
    nombre = nombre_limpio(nombre, 60)
    if not nombre:
        raise ValueError("Falta el nombre de la serie")
    numeros = [0]
    for sid, nom, _ in series():
        if nom.lower() == nombre.lower():
            return sid
        m = re.match(r"(\d+)", sid)
        if m:
            numeros.append(int(m.group(1)))
    sid = f"{max(numeros) + 1:02d} {nombre}"
    os.makedirs(os.path.join(VIDEO_DIR, sid), exist_ok=True)
    return sid


def modo_tv():
    try:
        with open(ESTADO_TV, encoding="utf-8") as f:
            return json.load(f).get("modo")
    except (OSError, ValueError):
        return None


class Conversor(threading.Thread):
    """Convierte de a uno los videos subidos (cola.json) a 320x240 en la carpeta de su serie."""
    VF = ("scale=320:240:force_original_aspect_ratio=decrease:flags=lanczos,"
          "pad=320:240:(ow-iw)/2:(oh-ih)/2:black,setsar=1")

    def __init__(self):
        super().__init__(daemon=True)
        self.candado = threading.Lock()
        self.despertar = threading.Event()
        self.tareas = []
        self.proc = None
        try:
            with open(COLA, encoding="utf-8") as f:
                self.tareas = json.load(f)
        except (OSError, ValueError):
            pass
        for t in self.tareas:                              # lo que se cortó por un reinicio, otra vez
            if t.get("estado") in ("convirtiendo", "cancelando"):
                t["estado"], t["progreso"] = "esperando", 0
            if t.get("estado") == "esperando":            # (con el nombre limpio, si se subió antes)
                t["nombre"] = limpiar_titulo(t["nombre"])
        for _, _, carpeta in series():                     # restos de conversiones cortadas por un reinicio
            for f in os.listdir(carpeta):
                if f.startswith(".") and f.endswith(".parte.mp4"):
                    _borrar_silencioso(os.path.join(carpeta, f))

    def _guardar(self):
        os.makedirs(SUBIDAS, exist_ok=True)
        tmp = COLA + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.tareas, f, ensure_ascii=False)
        os.replace(tmp, COLA)

    def agregar(self, origen, serie, nombre):
        with self.candado:
            self.tareas.append({"id": secrets.token_hex(6), "origen": origen, "serie": serie, "nombre": nombre,
                                "estado": "esperando", "progreso": 0, "error": ""})
            self._guardar()
        self.despertar.set()

    def lista(self):
        with self.candado:
            ahora = time.time()                            # las terminadas hace rato se olvidan
            self.tareas = [t for t in self.tareas if t["estado"] in ("esperando", "convirtiendo", "cancelando")
                           or ahora - t.get("fin", ahora) < 6 * 3600]
            return [{k: v for k, v in t.items() if k != "origen"} for t in self.tareas]

    def quitar(self, tid):
        with self.candado:
            t = next((t for t in self.tareas if t["id"] == tid), None)
            if not t:
                return False
            if t["estado"] == "convirtiendo" and self.proc:
                t["estado"] = "cancelando"
                self.proc.send_signal(signal.SIGCONT)
                self.proc.terminate()
            else:
                self.tareas.remove(t)
                if t["estado"] in ("esperando", "error"):
                    _borrar_silencioso(t["origen"])
            self._guardar()
            return True

    def run(self):
        while True:
            with self.candado:
                t = next((t for t in self.tareas if t["estado"] == "esperando"), None)
                if t:
                    t["estado"] = "convirtiendo"
                    self._guardar()
            if not t:
                self.despertar.wait(30)
                self.despertar.clear()
                continue
            try:
                ok, error = self._convertir(t)
            except Exception as e:                         # que un video raro no pare la cola
                ok, error = False, f"Error al convertir: {e}"
            with self.candado:
                if t["estado"] == "cancelando":
                    self.tareas.remove(t)
                    _borrar_silencioso(t["origen"])
                else:
                    t["estado"], t["error"], t["fin"] = ("listo" if ok else "error"), error, time.time()
                    if ok:
                        t["progreso"] = 100
                        _borrar_silencioso(t["origen"])
                self._guardar()

    def _convertir(self, t):
        carpeta = os.path.join(VIDEO_DIR, t["serie"])
        os.makedirs(carpeta, exist_ok=True)
        base = nombre_limpio(t["nombre"]) or "Episodio"
        final = os.path.join(carpeta, base + ".mp4")
        k = 2
        while os.path.exists(final):
            final = os.path.join(carpeta, f"{base} ({k}).mp4")
            k += 1
        parcial = os.path.join(carpeta, "." + os.path.basename(final) + ".parte.mp4")   # oculto: la TV no lo ve
        try:
            dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of",
                                        "default=nw=1:nk=1", t["origen"]], capture_output=True, text=True,
                                       timeout=60).stdout.strip() or 0)
        except (OSError, ValueError, subprocess.SubprocessError):
            dur = 0
        cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", t["origen"], "-map", "0:v:0", "-map", "0:a:0?",
               "-vf", self.VF, "-c:v", "libx264", "-preset", "veryfast", "-crf", "28", "-profile:v", "high",
               "-level:v", "3.0", "-threads", "2", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-c:a", "aac",
               "-b:a", "48k", "-ac", "1", "-ar", "48000", "-movflags", "+faststart",
               "-progress", "pipe:1", "-nostats", parcial]
        log(f"convirtiendo {t['origen']} -> {final}")
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                     preexec_fn=lambda: os.setpriority(os.PRIO_PROCESS, 0, 19))
        proc = self.proc
        fin_vigia = threading.Event()

        def vigilar():                                     # pausa mientras alguien juega
            pausado = False
            while not fin_vigia.wait(2):
                jugando = modo_tv() == "juego"
                if jugando != pausado and proc.poll() is None:
                    proc.send_signal(signal.SIGSTOP if jugando else signal.SIGCONT)
                    pausado = jugando
                    with self.candado:
                        t["pausa"] = jugando
        threading.Thread(target=vigilar, daemon=True).start()
        errores = []
        threading.Thread(target=lambda: errores.append(proc.stderr.read()), daemon=True).start()
        for linea in proc.stdout:
            if linea.startswith("out_time_ms=") and dur > 0:
                try:
                    p = min(99, int(int(linea.split("=")[1]) / 1e6 / dur * 100))
                except ValueError:
                    continue
                with self.candado:
                    t["progreso"] = max(0, p)
        codigo = proc.wait()
        fin_vigia.set()
        t.pop("pausa", None)
        self.proc = None
        if codigo == 0 and os.path.exists(parcial) and os.path.getsize(parcial) > 0:
            os.replace(parcial, final)
            log(f"listo: {final}")
            return True, ""
        _borrar_silencioso(parcial)
        error = (errores[0] if errores else "").strip()
        log(f"falló ({codigo}): {error[-300:]}")
        return False, "No se pudo convertir este video" + (f" ({error.splitlines()[-1][:120]})" if error else "")


# ============================== juegos ==============================
def titulo_juego(archivo):
    base = os.path.splitext(archivo)[0]
    return re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", base).strip() or base


def nombres_arcade():
    out = {}
    try:
        with open(os.path.join(JUEGOS_DIR, "arcade", "nombres.txt"), encoding="utf-8") as f:
            for linea in f:
                if "\t" in linea:
                    k, v = linea.rstrip("\n").split("\t", 1)
                    out[k] = v
    except OSError:
        pass
    return out


def pistas_de_cue(ruta):
    try:
        with open(ruta, encoding="utf-8", errors="replace") as f:
            return [m.group(1) for m in FILE_CUE.finditer(f.read())]
    except OSError:
        return []


def juegos_de(consola):
    carpeta = os.path.join(JUEGOS_DIR, consola)
    exts = CONSOLAS[consola][2] + ((".zip",) if consola != "psx" else ())
    try:
        archivos = os.listdir(carpeta)
    except OSError:
        return []
    archivos = [f for f in archivos if not f.startswith(".") and os.path.isfile(os.path.join(carpeta, f))
                and f.lower().endswith(exts)]
    if consola == "psx":                                   # las pistas .bin van con su .cue
        pistas = set()
        for c in archivos:
            if c.lower().endswith(".cue"):
                pistas.update(pistas_de_cue(os.path.join(carpeta, c)))
        archivos = [f for f in archivos if not (f.lower().endswith(".bin") and f in pistas)]
    return sorted(archivos, key=orden_natural)


def consola_por_extension(nombre):
    ext = os.path.splitext(nombre)[1].lower()
    if ext in (".bin", ".zip"):
        return None
    for c, (_, _, exts) in CONSOLAS.items():
        if ext in exts:
            return c
    return None


def detectar_consola(ruta, nombre):
    """Consola de un juego subido, o None si hay que preguntar."""
    ext = os.path.splitext(nombre)[1].lower()
    if ext == ".bin":
        try:
            with open(ruta, "rb") as f:
                f.seek(256)
                if f.read(4) == b"SEGA":
                    return "genesis"
        except OSError:
            pass
        return None
    if ext == ".zip":
        try:
            with zipfile.ZipFile(ruta) as z:
                dentro = [n for n in z.namelist() if not n.endswith("/") and not n.startswith("__MACOSX")]
        except (OSError, zipfile.BadZipFile):
            return None
        for n in dentro:
            c = consola_por_extension(n)
            if c and c != "psx":
                return c
        return "arcade" if dentro else None                # romset de arcade (FinalBurn Neo)
    return consola_por_extension(nombre)


def _listado_libretro(consola, tipo):
    os.makedirs(CACHE, exist_ok=True)
    archivo = os.path.join(CACHE, f"libretro-{consola}-{tipo}.txt")
    try:
        if time.time() - os.path.getmtime(archivo) < 7 * 86400:
            with open(archivo, encoding="utf-8") as f:
                return f.read().splitlines()
    except OSError:
        pass
    url = f"{LIBRETRO}/{urllib.parse.quote(CONSOLAS[consola][1])}/{tipo}/"
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "MiniTV"}), timeout=90) as r:
        html = r.read().decode("utf-8", "replace")
    nombres = [urllib.parse.unquote(m) for m in re.findall(r'href="([^"/]+\.png)"', html)]
    with open(archivo, "w", encoding="utf-8") as f:
        f.write("\n".join(nombres))
    return nombres


def _clave(t):
    t = t.lower()
    t = re.sub(r"\.png$", "", t)
    t = re.sub(r"\([^)]*\)|\[[^\]]*\]", "", t)
    t = re.sub(r"^the\s+|,\s*the\b", "", t)
    return re.sub(r"[^a-z0-9]", "", t)


def _mejor_imagen(nombres, buscado):
    """Mismo título (sin etiquetas, mayúsculas ni signos); entre varias: USA > World > Europe > Japan."""
    k = _clave(buscado)
    if not k:
        return None
    mejor, pm = None, 1e9
    for n in nombres:
        if _clave(n) != k:
            continue
        if n == buscado + ".png":
            return n
        p = 100 if "[" in n else 0
        p += 0 if "(USA" in n else 1 if "(World" in n else 2 if "(Europe" in n else 3 if "(Japan" in n else 5
        p += 10 if re.search(r"\((Beta|Proto|Demo|Sample)", n, re.I) else 0
        if p < pm:
            mejor, pm = n, p
    return mejor


def buscar_portada(consola, archivo):
    """Descarga la carátula (o la pantalla de título) de libretro y la guarda reducida."""
    from PIL import Image
    base = os.path.splitext(archivo)[0]
    buscado = nombres_arcade().get(base, base) if consola == "arcade" else base
    destino = os.path.join(JUEGOS_DIR, consola, "portadas", base + ".png")
    if os.path.exists(destino):
        return True
    for tipo in ("Named_Boxarts", "Named_Titles"):
        try:
            img = _mejor_imagen(_listado_libretro(consola, tipo), buscado)
            if not img:
                continue
            url = f"{LIBRETRO}/{urllib.parse.quote(CONSOLAS[consola][1])}/{tipo}/{urllib.parse.quote(img)}"
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "MiniTV"}), timeout=60) as r:
                im = Image.open(io.BytesIO(r.read())).convert("RGB")
            im.thumbnail((PORTADA_W, PORTADA_H), Image.LANCZOS)
            os.makedirs(os.path.dirname(destino), exist_ok=True)
            im.save(destino)
            log(f"portada de {archivo}: {img}")
            return True
        except Exception as e:                             # sin internet, página caída...: sin portada
            log(f"portada de {archivo}: {e}")
            return False
    log(f"portada de {archivo}: no está en libretro")
    return False


# ============================== canales ==============================
CABECERA_CANALES = """# Canales de la categoría TV (~/videos/canales.txt en la MiniTV)
# Lo edita la página Administrar del control remoto (o a mano).
# Formato:
#   [Nombre del canal]
#   mosca: izquierda       (opcional: la mosca abajo a la izquierda; si no, a la derecha)
#   Nombre de la serie     (como la carpeta de ~/videos, sin el número)
# Logos: ~/videos/logos/<Nombre del canal>.png (si no hay, se ven las siglas).
"""


def leer_canales():
    canales, actual = [], None
    try:
        with open(CANALES, encoding="utf-8", errors="replace") as f:
            for linea in f:
                linea = nfc(linea.strip())
                if not linea or linea.startswith("#"):
                    continue
                if linea.startswith("[") and linea.endswith("]"):
                    actual = {"nombre": linea[1:-1].strip(), "series": [], "mosca": "derecha"}
                    canales.append(actual)
                elif actual and linea.lower().replace(" ", "").startswith("mosca:"):
                    actual["mosca"] = linea.split(":", 1)[1].strip().lower()
                elif actual:
                    actual["series"].append(linea)
    except OSError:
        pass
    for c in canales:
        c["logo"] = os.path.exists(os.path.join(LOGOS_DIR, c["nombre"] + ".png"))
    return canales


def guardar_canales(canales):
    partes = [CABECERA_CANALES]
    vistos = set()
    for c in canales:
        nombre = nombre_limpio(c.get("nombre", ""), 40).replace("[", "").replace("]", "")
        if not nombre or nombre.lower() in vistos:
            continue
        vistos.add(nombre.lower())
        partes.append(f"\n[{nombre}]")
        if c.get("mosca") == "izquierda":
            partes.append("mosca: izquierda")
        for s in c.get("series", []):
            s = nombre_limpio(s, 60)
            if s:
                partes.append(s)
    tmp = CANALES + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(partes) + "\n")
    os.replace(tmp, CANALES)


def guardar_logo(canal, datos):
    from PIL import Image
    canal = nombre_limpio(canal, 40)
    if not canal:
        raise ValueError("Falta el canal")
    try:
        im = Image.open(io.BytesIO(datos)).convert("RGBA")
    except Exception:
        raise ValueError("No pude leer esa imagen (usa PNG o JPG)")
    im.thumbnail((400, 160), Image.LANCZOS)
    os.makedirs(LOGOS_DIR, exist_ok=True)
    im.save(os.path.join(LOGOS_DIR, canal + ".png"))


# ============================== la API ==============================
class Admin:
    def __init__(self):
        self.config = Config()
        self.sesiones = Sesiones(self.config)
        for d in (SUBIDAS, SUBIDAS_JUEGOS):
            os.makedirs(d, exist_ok=True)
        self.conversor = Conversor()
        self.conversor.start()

    # --- utilidades HTTP ---
    @staticmethod
    def _json(h, codigo, datos, extra=()):
        cuerpo = json.dumps(datos, ensure_ascii=False).encode()
        h.send_response(codigo)
        h.send_header("Content-Type", "application/json; charset=utf-8")
        h.send_header("Content-Length", str(len(cuerpo)))
        h.send_header("Cache-Control", "no-store")
        for k, v in extra:
            h.send_header(k, v)
        h.end_headers()
        h.wfile.write(cuerpo)

    @staticmethod
    def _token(h):
        for parte in h.headers.get("Cookie", "").split(";"):
            k, _, v = parte.strip().partition("=")
            if k == "minitv_admin":
                return v
        return None

    @staticmethod
    def _leer_json(h, maximo=200000):
        n = int(h.headers.get("Content-Length") or 0)
        if n > maximo:
            raise ValueError("Demasiado grande")
        try:
            return json.loads(h.rfile.read(n) or b"{}")
        except ValueError:
            return {}

    @staticmethod
    def _recibir_archivo(h, destino):
        """Copia el cuerpo de la petición a 'destino' por partes. False si llegó incompleto."""
        n = int(h.headers.get("Content-Length") or 0)
        if n <= 0:
            return False
        if n > shutil.disk_usage(os.path.dirname(destino)).free - 500 * 1024 * 1024:
            raise ValueError("No hay espacio suficiente en la TV")
        recibido = 0
        try:
            with open(destino, "wb") as f:
                while recibido < n:
                    trozo = h.rfile.read(min(1 << 20, n - recibido))
                    if not trozo:
                        break
                    f.write(trozo)
                    recibido += len(trozo)
        except OSError:
            recibido = -1
        if recibido < n:
            _borrar_silencioso(destino)
            h.close_connection = True
            return False
        return True

    # --- entrada ---
    def atender(self, h, metodo):
        url = urllib.parse.urlsplit(h.path)
        ruta = url.path
        q = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        try:
            if ruta == "/api/entrar" and metodo == "POST":
                token, error = self.sesiones.entrar(str(self._leer_json(h).get("pin", "")))
                if not token:
                    return self._json(h, 403, {"ok": False, "error": error})
                return self._json(h, 200, {"ok": True}, [("Set-Cookie", f"minitv_admin={token}; Path=/; HttpOnly; "
                                                          f"SameSite=Strict; Max-Age={Sesiones.DURACION}")])
            if ruta == "/api/sesion":
                return self._json(h, 200, {"ok": self.sesiones.valida(self._token(h))})
            if not self.sesiones.valida(self._token(h)):
                if metodo == "PUT":
                    h.close_connection = True              # no leer un archivo grande sin permiso
                return self._json(h, 401, {"ok": False, "error": "Escribe el PIN", "pin": True})
            if ruta == "/api/salir":
                self.sesiones.salir(self._token(h))
                return self._json(h, 200, {"ok": True})
            if ruta == "/api/resumen":
                return self._json(h, 200, self.resumen())
            if ruta == "/api/subir/video" and metodo == "PUT":
                return self.subir_video(h, q)
            if ruta == "/api/subir/juego" and metodo == "PUT":
                return self.subir_juego(h, q)
            if ruta == "/api/borrar" and metodo == "POST":
                return self.borrar(h, self._leer_json(h))
            if ruta == "/api/canales":
                if metodo == "POST":
                    guardar_canales(self._leer_json(h).get("canales", []))
                return self._json(h, 200, {"ok": True, "canales": leer_canales(),
                                           "series": [nom for _, nom, _ in series()]})
            if ruta == "/api/logo":
                if metodo == "PUT":
                    n = int(h.headers.get("Content-Length") or 0)
                    if n > 8 * 1024 * 1024:
                        h.close_connection = True
                        raise ValueError("La imagen es muy grande (máximo 8 MB)")
                    guardar_logo(q.get("canal", ""), h.rfile.read(n))
                    return self._json(h, 200, {"ok": True})
                return self._imagen(h, os.path.join(LOGOS_DIR, nombre_limpio(q.get("canal", "")) + ".png"), LOGOS_DIR)
            if ruta == "/api/portada":
                c = q.get("consola", "")
                if c not in CONSOLAS:
                    raise ValueError("Consola desconocida")
                base = os.path.splitext(nombre_limpio(q.get("archivo", "")))[0]
                return self._imagen(h, os.path.join(JUEGOS_DIR, c, "portadas", base + ".png"), JUEGOS_DIR)
            if ruta == "/api/wifi":
                return self.wifi(h, metodo)
            if ruta == "/api/pin" and metodo == "POST":
                nuevo = str(self._leer_json(h).get("nuevo", ""))
                if not re.fullmatch(r"\d{4}", nuevo):
                    raise ValueError("El PIN debe tener 4 números")
                self.config.datos["pin"] = nuevo
                self.config.guardar()
                return self._json(h, 200, {"ok": True})
            return self._json(h, 404, {"ok": False, "error": "No existe"})
        except ValueError as e:
            return self._json(h, 400, {"ok": False, "error": str(e)})
        except (OSError, subprocess.SubprocessError) as e:
            log(f"error en {ruta}: {e}")
            return self._json(h, 500, {"ok": False, "error": f"Error en la TV: {getattr(e, 'strerror', None) or e}"})

    def _imagen(self, h, ruta, base):
        if not dentro_de(base, ruta) or not os.path.isfile(ruta):
            return self._json(h, 404, {"ok": False})
        with open(ruta, "rb") as f:
            cuerpo = f.read()
        h.send_response(200)
        h.send_header("Content-Type", "image/png")
        h.send_header("Content-Length", str(len(cuerpo)))
        h.send_header("Cache-Control", "no-cache")
        h.end_headers()
        h.wfile.write(cuerpo)

    # --- resumen ---
    def resumen(self):
        uso = shutil.disk_usage(VIDEO_DIR)
        lista = []
        for sid, nom, ruta in series():
            eps = []
            for e in episodios(ruta):
                try:
                    eps.append({"archivo": e, "mb": round(os.path.getsize(os.path.join(ruta, e)) / 1e6, 1)})
                except OSError:
                    pass
            lista.append({"id": sid, "nombre": nom, "episodios": eps, "mb": round(sum(e["mb"] for e in eps))})
        consolas = []
        arcade = nombres_arcade()
        for c, (nombre, _, _) in CONSOLAS.items():
            js = []
            for j in juegos_de(c):
                base = os.path.splitext(j)[0]
                js.append({"archivo": j, "titulo": arcade.get(base) or titulo_juego(j),
                           "portada": os.path.exists(os.path.join(JUEGOS_DIR, c, "portadas", base + ".png"))})
            consolas.append({"id": c, "nombre": nombre, "juegos": js})
        return {"ok": True, "libre_gb": round(uso.free / 1e9, 1), "total_gb": round(uso.total / 1e9, 1),
                "series": lista, "cola": self.conversor.lista(), "consolas": consolas}

    # --- subir ---
    def subir_video(self, h, q):
        archivo = nombre_limpio(q.get("archivo", ""))
        if not archivo.lower().endswith(EXT_VIDEO):
            h.close_connection = True
            raise ValueError("Ese archivo no es un video que la TV conozca")
        if q.get("nueva"):
            sid = carpeta_serie_nueva(q["nueva"])
        else:
            sid = q.get("serie", "")
            carpeta = os.path.join(VIDEO_DIR, sid)
            if not sid or not dentro_de(VIDEO_DIR, carpeta) or not os.path.isdir(carpeta):
                h.close_connection = True
                raise ValueError("Elige una serie")
        destino = os.path.join(SUBIDAS, secrets.token_hex(8) + os.path.splitext(archivo)[1].lower())
        if not self._recibir_archivo(h, destino):
            return self._json(h, 400, {"ok": False, "error": "La subida se cortó. Vuelve a intentarlo."})
        nombre = limpiar_titulo(os.path.splitext(archivo)[0])
        self.conversor.agregar(destino, sid, nombre)
        log(f"video subido: {archivo} -> {sid}")
        return self._json(h, 200, {"ok": True, "serie": sid})

    def subir_juego(self, h, q):
        archivo = nombre_limpio(q.get("archivo", ""))
        if not archivo:
            h.close_connection = True
            raise ValueError("Falta el nombre del archivo")
        tmp = os.path.join(SUBIDAS_JUEGOS, secrets.token_hex(8) + "-" + archivo)
        if not self._recibir_archivo(h, tmp):
            return self._json(h, 400, {"ok": False, "error": "La subida se cortó. Vuelve a intentarlo."})
        consola = q.get("consola") or detectar_consola(tmp, archivo)
        if consola not in CONSOLAS:
            _borrar_silencioso(tmp)
            if archivo.lower().endswith(".bin"):
                return self._json(h, 400, {"ok": False, "pregunta": True,
                                           "error": "No sé de qué consola es este .bin: elige la consola y súbelo otra vez."})
            raise ValueError("No reconozco este juego. Formatos: .gb .gbc .gba .nes .sfc .smc .md .gen .bin .cue .chd .pbp .zip")
        carpeta = os.path.join(JUEGOS_DIR, consola)
        os.makedirs(carpeta, exist_ok=True)
        os.replace(tmp, os.path.join(carpeta, archivo))
        log(f"juego subido: {archivo} -> {consola}")
        if not archivo.lower().endswith(".bin") or consola != "psx":
            threading.Thread(target=buscar_portada, args=(consola, archivo), daemon=True).start()
        return self._json(h, 200, {"ok": True, "consola": consola, "nombre_consola": CONSOLAS[consola][0]})

    # --- borrar ---
    def borrar(self, h, d):
        tipo = d.get("tipo")
        if tipo == "tarea":
            return self._json(h, 200, {"ok": self.conversor.quitar(str(d.get("id", "")))})
        if tipo in ("episodio", "serie"):
            carpeta = os.path.join(VIDEO_DIR, str(d.get("serie", "")))
            if not dentro_de(VIDEO_DIR, carpeta) or not os.path.isdir(carpeta):
                raise ValueError("Esa serie no existe")
            if tipo == "serie":
                shutil.rmtree(carpeta)
                log(f"serie borrada: {carpeta}")
                return self._json(h, 200, {"ok": True})
            ruta = os.path.join(carpeta, str(d.get("archivo", "")))
            if not dentro_de(carpeta, ruta) or not os.path.isfile(ruta):
                raise ValueError("Ese episodio no existe")
            os.remove(ruta)
            log(f"episodio borrado: {ruta}")
            return self._json(h, 200, {"ok": True})
        if tipo == "juego":
            c = d.get("consola")
            if c not in CONSOLAS:
                raise ValueError("Consola desconocida")
            carpeta = os.path.join(JUEGOS_DIR, c)
            ruta = os.path.join(carpeta, str(d.get("archivo", "")))
            if not dentro_de(carpeta, ruta) or not os.path.isfile(ruta):
                raise ValueError("Ese juego no existe")
            borrar = [ruta]
            if ruta.lower().endswith(".cue"):              # PlayStation: también sus pistas
                borrar += [os.path.join(carpeta, p) for p in pistas_de_cue(ruta)
                           if dentro_de(carpeta, os.path.join(carpeta, p))]
            base = os.path.splitext(os.path.basename(ruta))[0]
            borrar.append(os.path.join(carpeta, "portadas", base + ".png"))
            for p in borrar:                               # las partidas guardadas se quedan
                _borrar_silencioso(p)
            log(f"juego borrado: {ruta}")
            return self._json(h, 200, {"ok": True})
        raise ValueError("No sé qué borrar")

    # --- wifi ---
    def wifi(self, h, metodo):
        if metodo == "POST":
            d = self._leer_json(h)
            accion, ssid = d.get("accion"), str(d.get("ssid", "")).strip()
            if accion == "agregar":
                clave = str(d.get("clave", ""))
                if not ssid or not (8 <= len(clave) <= 63):
                    raise ValueError("Escribe el nombre de la red y una clave de 8 a 63 caracteres")
                datos = {"ssid": ssid, "clave": clave}
            elif accion == "olvidar":
                datos = {"ssid": ssid}
            else:
                raise ValueError("Acción desconocida")
            r = subprocess.run(["sudo", "-n", WIFI, accion], input=json.dumps(datos), capture_output=True,
                               text=True, timeout=30)
            if r.returncode != 0:
                raise ValueError(r.stderr.strip() or "No se pudo cambiar el wifi")
        r = subprocess.run(["sudo", "-n", WIFI, "lista"], capture_output=True, text=True, timeout=15)
        try:
            with open("/run/minitv-red/modo") as f:
                modo = f.read().strip()
        except OSError:
            modo = ""
        return self._json(h, 200, {"ok": True, "redes": [l for l in r.stdout.splitlines() if l.strip()], "modo": modo})
