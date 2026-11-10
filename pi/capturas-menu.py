import importlib.machinery, os, socket, subprocess, time, json
m = importlib.machinery.SourceFileLoader("minitv", "/usr/local/bin/minitv").load_module()
OUT = os.path.expanduser("~/compilar/capturas"); os.makedirs(OUT, exist_ok=True)
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
def orden(*os_, p=0.45):
    for o in os_:
        s.sendto(o.encode(), "/run/minitv/control.sock"); time.sleep(p)
def foto(nombre):
    subprocess.run(["/usr/local/bin/minitv-captura", "foto", "/tmp/c.ppm"], stdout=subprocess.DEVNULL, check=True)
    m.Image.open("/tmp/c.ppm").save(f"{OUT}/{nombre}.png"); print("foto", nombre)
CATS = ["TV", "Juegos", "Series", "USB", "Ajustes"]
# Estado inicial del menú tras reiniciar (igual que TV.__init__)
e = m.Estado(); series = m.buscar_series()
if e.datos.get("ultimo_modo") == "tv":
    cat, foco = 0, 0
else:
    ids = [x.id for x in series]; cat = 2; foco = ids.index(e.datos.get("ultima")) if e.datos.get("ultima") in ids else 0
subprocess.run(["sudo", "systemctl", "restart", "minitv"], check=True); time.sleep(6)
def a_categoria(actual, foco_actual, destino):
    orden(*["arriba"] * (foco_actual + 1))
    orden(*["elegir"] * ((CATS.index(destino) - actual) % len(CATS)))
    orden("abajo")                                   # foco en el primer elemento
# 1) TV
a_categoria(cat, foco, "TV"); foto("1-tv-menu")
orden("elegir", p=0.1)
for i in range(12):                                  # esperar a que se vea el episodio con el rótulo
    time.sleep(0.4); foto(f"1-tv-en-vivo-{i}")
orden("menu", p=1.2)                                 # vuelve al menú en TV
# 2) Juegos -> PlayStation (CTR)
a_categoria(0, 0, "Juegos")
consolas = [c.id for c in m.buscar_consolas()]
orden(*["abajo"] * consolas.index("psx")); orden("elegir", p=0.8)
juegos = [c for c in m.buscar_consolas() if c.id == "psx"][0].juegos
ultimo = m.Estado().datos["juegos"].get("psx"); i = juegos.index(ultimo) if ultimo in juegos else 0
orden(*["arriba"] * i, p=0.5); time.sleep(0.5); foto("2-juegos-portada-ctr")
orden("abajo", p=0.8); foto("2-juegos-portada-twisted")
orden("menu")                                        # a la lista de consolas (foco en PlayStation)
# 3) Ajustes -> Bluetooth
a_categoria(1, consolas.index("psx"), "Ajustes")
orden("abajo"); foto("3-ajustes")
orden("elegir", p=2.5); foto("3-bluetooth")
orden("elegir", p=12); foto("3-bluetooth-buscar")
orden("menu", p=0.6); orden("abajo"); orden("elegir", p=2.5); foto("3-bluetooth-guardados")
orden("elegir", p=0.8); foto("3-bluetooth-teclado")
orden("menu", "menu", "menu", p=0.6)
print("listo")
