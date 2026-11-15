# Mini TV

Televisor retro hecho con una Raspberry Pi Zero 2 W (Raspberry Pi OS Bullseye 32 bits), pantalla
ILI9341 de 320x240 (fbcp-ili9341), audio PWM por GPIO18 a un PAM8403 y dos botones
(GPIO3: menú / mantener 2 s = apagar; GPIO16: bajar / mantener 0,8 s = elegir).

Menú propio (`pi/minitv`, Python + Pillow): **TV** (canales con episodios al azar, mosca y
"Más adelante"), **Juegos** (RetroArch), **Música** (la TV como parlante Bluetooth), **Series**,
**USB** y **Ajustes**.

---

## Control remoto en el celular

Un control plateado estilo años 2000 ("Paolo TV") que se abre en el navegador del teléfono. No usa
internet: la página la sirve la propia TV.

| Botón | En el menú | Viendo un episodio / canal | Jugando |
|---|---|---|---|
| ⏻ (rojo) | apaga la pantalla con la animación de tubo / la vuelve a encender | igual | igual (RetroArch guarda antes) |
| ▲ ▼ | moverse | canal siguiente / anterior | — |
| ◀ ▶ | categoría anterior / siguiente (dentro de una lista: ◀ = atrás) | — | — |
| OK | elegir | muestra qué se ve y qué viene | — |
| Menú | vuelve a la portada del menú | abre el menú | sale del juego |
| Atrás | un nivel atrás | abre el menú | sale del juego |
| ▶❚❚ | — | pausa / sigue | — |
| ■ | — | detiene y vuelve al menú | sale del juego |
| − / + | volumen | volumen | volumen |

Si el control pierde la conexión muestra: *"No encuentro la TV. Revisa que estés en la red MiniTV o
en tu wifi de casa."* y se reconecta solo.

El botón rojo deja la TV **en reposo** (pantalla negra, la Pi sigue encendida para que el control la
pueda volver a prender). Para apagarla del todo: botón 1 de la TV mantenido 2 s, o Ajustes → Apagar.

### Abrirlo

* **En casa** (el teléfono en el mismo wifi que la TV): `http://minitv.local`
  (si el teléfono no resuelve `.local`, la IP que muestra Ajustes → Control remoto).
* **Sin el wifi de casa**: la TV crea su propia red (ver abajo); conéctate a **MiniTV**
  (clave `miray2000`) y abre `http://192.168.4.1` o `http://minitv.local`.
* En la TV, **Ajustes → Control remoto** muestra la red, la clave, la dirección y códigos QR
  (en la red propia, un QR para unirse al wifi y otro para abrir el control).

### Ponerlo como app en la pantalla de inicio

* **iPhone** (Safari): abrir la dirección → botón Compartir → *Añadir a pantalla de inicio*.
* **Android** (Chrome): abrir la dirección → menú ⋮ → *Añadir a la pantalla principal* /
  *Instalar app*.

Se abre a pantalla completa con su ícono. La página vive en la TV, así que el teléfono tiene que estar
en la red de casa o en la red MiniTV (por `http://`, sin HTTPS, no se puede guardar copia offline).

Vibración al tocar: Android siempre; iPhone desde iOS 18 (la "vibración" de los interruptores de
Safari).

### Modo mando (juegos)

Botón **🎮 Modo mando**, con el celular en horizontal: cruceta a la izquierda; A (rojo), B (amarillo),
X (azul), Y (gris) en rombo a la derecha; L y R arriba; Select y Start al centro; **✕ Salir del juego**
y **📺 Control** (vuelve al control de TV).

* La TV crea un **mando de verdad** por cada celular (virtual, con uinput): RetroArch lo reconoce
  con el perfil `MiniTV Mando.cfg`. Dos celulares = jugador 1 y jugador 2 (hasta 4).
* Varios dedos a la vez (p. ej. correr + saltar) y diagonales en la cruceta deslizando el dedo.
* Cada cambio se manda al instante por WebSocket (sin retardo de Nagle); en el wifi de casa
  responde en ~40 ms.
* En el menú de la TV el mando del celular también sirve para moverse.

---

## Red wifi propia ("MiniTV")

`minitv-red` (servicio `minitv-red.service`) al encender:

1. Si ve la red de casa (las de `/etc/wpa_supplicant/wpa_supplicant.conf`) se conecta como siempre
   y no hace nada más: SSH sigue funcionando.
2. Si no la ve en ~5 s, crea la red **MiniTV** (WPA2, `hostapd` + `dnsmasq`, IP `192.168.4.1`,
   DHCP sin puerta de enlace: el teléfono sigue usando sus datos móviles para internet). Aparece
   unos 13–15 s después de encender.
3. Mientras está en la red propia, cada 3 minutos **sin ningún teléfono conectado** vuelve a probar
   la red de casa (por si el router tardó en arrancar tras un corte de luz).

Nombre, clave e IP: `/etc/minitv/red-propia.conf`. Prueba sin apagar: `sudo minitv-red prueba 90`
(red propia 90 s y vuelve sola a la de casa). Estado: `/run/minitv-red/modo`.

`minitv-alias` anuncia `minitv.local` por mDNS con la IP actual (en casa y en la red propia); el
nombre de la Pi sigue siendo `raspberrypi.local`.

---

## Archivos del control remoto (`pi/remoto/`)

| Archivo | Dónde va en la Pi |
|---|---|
| `minitv-remoto` (servidor HTTP + WebSocket + mandos uinput; solo stdlib + python3-evdev) | `/usr/local/bin/` |
| `minitv-remoto.service` (usuario paolo, puerto 80 con `CAP_NET_BIND_SERVICE`) | `/etc/systemd/system/` |
| `web/index.html`, `web/manifest.webmanifest` | `/usr/local/share/minitv/remoto/` |
| `generar-iconos.py` (crea los íconos en esa carpeta) | se ejecuta en la Pi |
| `99-minitv-uinput.rules` (grupo input puede crear mandos) | `/etc/udev/rules.d/` |
| `MiniTV Mando.cfg` (perfil de RetroArch) | `~/.config/retroarch/autoconfig/udev/` |
| `minitv-red`, `minitv-alias` | `/usr/local/sbin/` |
| `minitv-red.service`, `minitv-alias.service` | `/etc/systemd/system/` |
| `red-propia.conf` | `/etc/minitv/` |

Paquetes: `hostapd` (queda enmascarado: solo lo arranca minitv-red), `dnsmasq-base`, `avahi-utils`,
`python3-qrcode`, `python3-evdev`.

Protocolo (WebSocket `/ws`, texto): `o:ORDEN` (sube, baja, izquierda, derecha, ok, atras, inicio,
pausa, stop, vol+, vol-, encendido) → `/run/minitv/control.sock`; `h` → `e:{estado}` (de
`/run/minitv/remoto.json`, que escribe minitv); `m:on` / `m:off` (mando virtual, responde `j:N`);
`p:MÁSCARA` (bits 0–7: B A X Y L R Select Start; 8–11: ▲ ▼ ◀ ▶).

### Instalar / actualizar

```bash
scp -r pi/remoto pi/minitv paolo@raspberrypi.local:/tmp/
ssh paolo@raspberrypi.local '
  cd /tmp/remoto
  sudo apt-get install -y --no-install-recommends hostapd dnsmasq-base avahi-utils python3-qrcode python3-evdev
  sudo install -m 755 minitv-remoto /usr/local/bin/ && sudo install -m 755 /tmp/minitv /usr/local/bin/minitv
  sudo install -m 755 minitv-red minitv-alias /usr/local/sbin/
  sudo mkdir -p /etc/minitv /usr/local/share/minitv/remoto
  sudo install -m 644 red-propia.conf /etc/minitv/
  sudo install -m 644 web/* /usr/local/share/minitv/remoto/ && sudo python3 generar-iconos.py /usr/local/share/minitv/remoto
  sudo install -m 644 99-minitv-uinput.rules /etc/udev/rules.d/ && sudo udevadm trigger --name-match=uinput
  install -m 644 "MiniTV Mando.cfg" ~/.config/retroarch/autoconfig/udev/
  sudo install -m 644 *.service /etc/systemd/system/ && sudo systemctl daemon-reload
  sudo systemctl enable --now minitv-remoto minitv-alias minitv-red
  sudo systemctl restart minitv'
```

### Cómo probarlo

**En casa**
1. Celular en el wifi de casa → `http://minitv.local` (o el QR de Ajustes → Control remoto).
2. La pantallita verde dice lo que hace la TV ("Menú", "En el aire · Nickelodeon"…).
3. ▲▼◀▶ y OK en el menú; durante un canal ▲▼ cambian de canal; − + cambian el volumen;
   ⏻ apaga y prende la pantalla.
4. Modo mando: abrir un juego, girar el celular, jugar; ✕ sale del juego.

**En la red propia**
1. Apagar el router (o llevar la TV lejos) y encender la TV.
2. En ~15 s aparece la red **MiniTV**: unirse con la clave `miray2000` (o el QR de la izquierda en
   Ajustes → Control remoto).
3. Abrir `http://192.168.4.1` (o el QR de la derecha).
4. Al volver a casa: reiniciar la TV, o esperar — si no hay ningún celular conectado a MiniTV, a los
   3 minutos vuelve sola al wifi de casa.
