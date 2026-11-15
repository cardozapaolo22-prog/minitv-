# Cómo armar otra Mini TV (Paolo TV)

Guía para hacer una Mini TV igual a la original: piezas, conexiones, la tarjeta con el sistema y la
primera configuración desde el celular. No hace falta programar ni usar Claude.

---

## 1. Piezas

| Pieza | Detalle |
|---|---|
| **Raspberry Pi Zero 2 W** | con los pines soldados (o soldarlos) |
| **Pantalla ILI9341 SPI de 2,8" (320x240)** | módulo con pines VCC, GND, CS, RESET, DC, SDI(MOSI), SCK, LED (y SDO, que no se usa) |
| **Amplificador PAM8403** | módulo pequeño de 5 V |
| **Parlante** | 3 W, 4–8 Ω |
| **Resistencia** | ~1 kΩ en serie entre la Pi y el amplificador |
| **Condensador cerámico 33–100 nF** | recomendado (filtra el zumbido del audio PWM) |
| **2 pulsadores** | botón 1 (menú / apagar) y botón 2 (bajar / elegir) |
| **Tarjeta microSD** | 32 GB o más (la original usa 128 GB: cabe mucho más contenido) |
| **Fuente 5 V 2,5 A micro-USB** | la oficial de Raspberry Pi va bien |
| Cables dupont hembra-hembra, caja | la que quieras |

Opcional: encoder giratorio KY-040 (el sistema ya tiene sus pines reservados, ver abajo).

---

## 2. Conexiones

Los números de **pin** son la posición física en el conector de 40 pines de la Pi
(pin 1 = el del cuadrado, junto a la tarjeta microSD).

### Pantalla ILI9341

| Pantalla | Pi (pin) | Señal |
|---|---|---|
| VCC | 1 | 3,3 V |
| GND | 6 | GND |
| CS | 24 | GPIO8 (SPI CE0) |
| RESET | 22 | GPIO25 |
| DC | 18 | GPIO24 |
| SDI (MOSI) | 19 | GPIO10 |
| SCK | 23 | GPIO11 |
| LED | 11 | GPIO17 (la luz se apaga al apagar la TV) |
| SDO (MISO) | — | sin conectar |

### Audio

| Desde | Hacia | Nota |
|---|---|---|
| Pi pin 12 (GPIO18, audio PWM) | resistencia ~1 kΩ → entrada **R** del PAM8403 | con el condensador de 33–100 nF entre la entrada y GND |
| Pi pin 14 (GND) | GND de entrada del PAM8403 | |
| Pi pin 2 o 4 (5 V) | VCC del PAM8403 | |
| Pi pin 9 o 39 (GND) | GND de alimentación del PAM8403 | |
| Salida **R+ / R−** del PAM8403 | parlante | |

### Botones (cada uno entre el GPIO y un GND)

| Botón | Pi (pin) | GND (pin) | Qué hace |
|---|---|---|---|
| Botón 1 | 5 (GPIO3) | 9 | corto = menú / atrás; mantener 2 s = apagar (y encender: GPIO3 despierta a la Pi) |
| Botón 2 | 36 (GPIO16) | 34 | corto = bajar; mantener 0,8 s = elegir |

### Encoder KY-040 (opcional, reservado)

| KY-040 | Pi (pin) |
|---|---|
| CLK | 29 (GPIO5) |
| DT | 31 (GPIO6) |
| SW | 37 (GPIO26) |
| + | 17 (3,3 V) |
| GND | 39 |

---

## 3. La tarjeta con el sistema

1. En la Mac, abre la app **«Imagen para otra MiniTV»** del Escritorio (con tu MiniTV encendida).
   Crea una imagen **limpia** del sistema: todo lo de la TV (menú, canales, juegos, emuladores,
   control remoto) pero **sin** tus videos, juegos, partidas, redes wifi, Bluetooth ni claves.
   Tu TV se apaga unos minutos mientras se copia y vuelve sola. La imagen queda en
   `~/MiniTV-Respaldo/otra-minitv/minitv-limpia-FECHA.img.gz` (unos 700 MB).
2. Descarga e instala **Raspberry Pi Imager** (raspberrypi.com/software).
3. Raspberry Pi Imager → *Elegir dispositivo*: Raspberry Pi Zero 2 W → *Elegir SO*:
   **Usar personalizado** → elige la imagen `minitv-limpia-….img.gz` → *Elegir almacenamiento*: la
   microSD → *Siguiente* → cuando pregunte por la personalización: **No** (la imagen ya trae todo).
4. Pon la microSD en la Pi nueva y enciéndela. El primer arranque tarda un poco más: agranda el
   sistema a toda la tarjeta y crea sus propias claves.

---

## 4. Primera configuración (desde el celular)

1. Al encender, la TV nueva no conoce ningún wifi, así que crea su propia red **MiniTV**.
2. En la TV: **Ajustes → Control remoto** muestra la clave de esa red (es distinta en cada TV),
   el **PIN** para Administrar y dos códigos QR.
3. En el celular: únete a la red **MiniTV** (QR de la izquierda) y abre el control
   (QR de la derecha, o `http://192.168.4.1`).
4. En el control: **⚙️ Administrar** → escribe el PIN → **Ajustes → Wifi de casa**: nombre y clave
   del wifi de la casa → *Guardar esta red*.
5. Reinicia la TV (botón 1 mantenido 2 s y vuelve a encenderla): se conecta al wifi de la casa.
   Desde ahí el control está en `http://minitv.local`.
6. **Administrar → Videos / Juegos** para cargar series y juegos; **Canales** para armar los canales
   y ponerles logo.

---

## 5. Datos de la TV nueva

| Qué | Valor |
|---|---|
| Red propia (sin wifi de casa) | **MiniTV**, clave propia (en Ajustes → Control remoto) |
| Control remoto | `http://minitv.local` (en casa) o `http://192.168.4.1` (red MiniTV) |
| PIN de Administrar | propio de cada TV (Ajustes → Control remoto); se cambia en Administrar → Ajustes |
| Acceso técnico (SSH) | `ssh paolo@raspberrypi.local`, clave inicial **minitv** (pide cambiarla la primera vez) |

> Si hay **dos** Mini TV en la misma casa, las dos se llaman igual en la red (`minitv.local` y
> `raspberrypi.local`): usa la dirección IP que muestra Ajustes → Control remoto en cada una.

---

## 6. Si algo no funciona

| Síntoma | Revisar |
|---|---|
| Pantalla en blanco | VCC/GND, CS (pin 24), DC (pin 18), RESET (pin 22). Pantalla blanca fija = la Pi no le habla |
| Pantalla negra pero la Pi enciende | LED en pin 11 (GPIO17) |
| Sin sonido | GPIO18 (pin 12) a la entrada **R** del PAM8403, 5 V del PAM8403, parlante en la salida R |
| Zumbido / sonido áspero | agregar el condensador cerámico de 33–100 nF |
| No aparece la red MiniTV | esperar ~20 s tras encender; si la TV encontró un wifi guardado, se conecta a ese |
| Los botones no responden | cada botón va entre su GPIO y un GND (no a 3,3 V) |
