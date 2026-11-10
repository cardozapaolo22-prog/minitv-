#!/bin/bash
# Compila RetroArch (dispmanx, parcheado) y los núcleos ligeros para la MiniTV.
# Antes (2026-11-07), en la Pi, con el swap subido a 1 GB (/etc/dphys-swapfile, CONF_SWAPSIZE=1024):
#   sudo apt-get install build-essential pkg-config libasound2-dev libudev-dev zlib1g-dev
#   mkdir ~/compilar && cd ~/compilar
#   git clone --depth 1 -b v1.22.2 https://github.com/libretro/RetroArch.git
#   git clone --depth 1 --recurse-submodules https://github.com/libretro/{gambatte-libretro→gambatte,gpsp,
#       libretro-fceumm→fceumm,snes9x2005,picodrive,pcsx_rearmed}.git
#   cd RetroArch && git apply ../retroarch-dispmanx-minitv.patch      (escala entera en dispmanx)
#   CFLAGS="-O2 -mcpu=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard" \
#   LDFLAGS="-lbcm_host -lvcos -lvchiq_arm -pthread" ./configure --prefix=/usr/local \
#     --disable-x11 --disable-wayland --disable-kms --disable-vulkan --disable-qt --disable-ffmpeg \
#     --disable-sdl --disable-sdl2 --disable-pulse --disable-oss --disable-jack --disable-materialui \
#     --disable-xmb --disable-ozone --disable-cheevos --disable-discord --disable-freetype --disable-opengl \
#     --disable-opengl1 --disable-opengl_core --disable-cdrom --disable-egl --disable-videocore \
#     --enable-dispmanx --enable-alsa --enable-udev --enable-neon --enable-floathard --enable-networking
# (Bullseye de 2023 ya no trae libbrcmEGL/libbrcmGLESv2: sin GL, el video va por dispmanx.
#  --enable-videocore exige su contexto EGL y no enlaza; dispmanx solo necesita las libs de LDFLAGS,
#  que configure no añade solo si VideoCore está desactivado.)
cd ~/compilar
estado(){ echo "$(date +%H:%M:%S) $*" >> estado.txt; }
( while true; do echo "$(date +%H:%M:%S) $(vcgencmd measure_temp) $(vcgencmd get_throttled)" >> temperatura.txt; sleep 30; done ) &
VIGIA=$!
export CFLAGS="-O2 -mcpu=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard"
estado "RetroArch: inicio"
( cd RetroArch && make -j2 > ../ra-make.log 2>&1 && sudo make install >> ../ra-make.log 2>&1 ) && estado "RetroArch: OK" || estado "RetroArch: ERROR"
unset CFLAGS
sudo mkdir -p /usr/local/lib/libretro
nucleo(){ # carpeta  archivo.so  orden...
  local d=$1 so=$2; shift 2
  estado "$d: inicio"
  if ( cd $d && "$@" > ../$d.log 2>&1 ) && [ -f $d/$so ]; then sudo cp $d/$so /usr/local/lib/libretro/ && estado "$d: OK"; else estado "$d: ERROR"; fi
}
nucleo gambatte     gambatte_libretro.so     make -f Makefile.libretro -j2 platform=unix
nucleo gpsp         gpsp_libretro.so         make -j2 platform=rpi3
nucleo fceumm       fceumm_libretro.so       make -f Makefile.libretro -j2 platform=rpi3
nucleo snes9x2005   snes9x2005_libretro.so   make -j2 platform=unix
nucleo picodrive    picodrive_libretro.so    make -f Makefile.libretro -j2 platform=rpi3
nucleo pcsx_rearmed pcsx_rearmed_libretro.so make -f Makefile.libretro -j2 platform=rpi3
kill $VIGIA
estado "FIN"
