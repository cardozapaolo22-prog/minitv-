// minitv-rotulo: muestra un rótulo (imagen RGBA con transparencia) en una capa propia del
// firmware, ENCIMA del video de VLC (capa 1) y DEBAJO de la estática (capa 10000). Pasados unos
// segundos se desvanece y el programa termina. Lo usa minitv en la categoría TV
// ("TV · Los Simpson 7x07" arriba a la derecha al empezar cada episodio).
//
// Uso:  minitv-rotulo ARCHIVO.rgba ANCHO ALTO X Y [SEGUNDOS]
//       (ARCHIVO: ANCHO*ALTO píxeles RGBA crudos; SEGUNDOS visibles antes de desvanecerse, 3 por defecto)
// Señales: TERM/INT/HUP = quitarlo ya.
//
// Compilar:  gcc -O2 -Wall -o minitv-rotulo minitv-rotulo.c -lbcm_host -lvchiq_arm -lvcos

#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "bcm_host.h"

#define CAPA         2       // encima del video de VLC (1), debajo de la estática (10000)
#define T_FUNDIDO    0.6     // duración del desvanecimiento (segundos)

static volatile sig_atomic_t salir = 0;
static void al_salir(int s) { (void)s; salir = 1; }

static double ahora(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

// Copia la imagen al recurso con la transparencia multiplicada por k (0..256)
static void escribir(DISPMANX_RESOURCE_HANDLE_T recurso, const uint8_t *img, uint8_t *cuadro, int w, int h,
                     int paso, VC_RECT_T *rect, int k) {
    for (int fila = 0; fila < h; fila++) {
        const uint8_t *s = img + (size_t)fila * w * 4;
        uint8_t *d = cuadro + (size_t)fila * paso;
        for (int i = 0; i < w; i++, s += 4, d += 4) {
            d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = (uint8_t)(s[3] * k >> 8);
        }
    }
    vc_dispmanx_resource_write_data(recurso, VC_IMAGE_RGBA32, paso, cuadro, rect);
}

int main(int argc, char **argv) {
    if (argc < 6) {
        fprintf(stderr, "Uso: %s ARCHIVO.rgba ANCHO ALTO X Y [SEGUNDOS]\n", argv[0]);
        return 1;
    }
    const int w = atoi(argv[2]), h = atoi(argv[3]), x = atoi(argv[4]), y = atoi(argv[5]);
    const double visible = argc > 6 ? atof(argv[6]) : 3.0;
    if (w <= 0 || h <= 0) return 1;

    const size_t tam = (size_t)w * h * 4;
    uint8_t *img = malloc(tam), *cuadro = malloc((size_t)ALIGN_UP(w * 4, 32) * h);
    FILE *f = fopen(argv[1], "rb");
    if (!f || fread(img, 1, tam, f) != tam) { fprintf(stderr, "No se pudo leer %s\n", argv[1]); return 1; }
    fclose(f);

    struct sigaction sa = { 0 };
    sa.sa_handler = al_salir;
    sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); sigaction(SIGHUP, &sa, NULL);

    bcm_host_init();
    DISPMANX_DISPLAY_HANDLE_T pantalla = vc_dispmanx_display_open(0);
    if (!pantalla) { fprintf(stderr, "No se pudo abrir el display\n"); return 1; }

    const int paso = ALIGN_UP(w * 4, 32);
    uint32_t vc_img;
    DISPMANX_RESOURCE_HANDLE_T recurso = vc_dispmanx_resource_create(VC_IMAGE_RGBA32, w, h, &vc_img);
    VC_RECT_T rect, origen, destino;
    vc_dispmanx_rect_set(&rect, 0, 0, w, h);
    vc_dispmanx_rect_set(&origen, 0, 0, w << 16, h << 16);
    vc_dispmanx_rect_set(&destino, x, y, w, h);

    escribir(recurso, img, cuadro, w, h, paso, &rect, 256);
    VC_DISPMANX_ALPHA_T alfa = { DISPMANX_FLAGS_ALPHA_FROM_SOURCE, 255, 0 };
    DISPMANX_UPDATE_HANDLE_T u = vc_dispmanx_update_start(0);
    DISPMANX_ELEMENT_HANDLE_T capa = vc_dispmanx_element_add(u, pantalla, CAPA, &destino, recurso, &origen,
                                                             DISPMANX_PROTECTION_NONE, &alfa, NULL, DISPMANX_NO_ROTATE);
    vc_dispmanx_update_submit_sync(u);

    const double t0 = ahora();
    while (!salir) {
        const double t = ahora() - t0;
        if (t < visible) { usleep(50000); continue; }
        if (t >= visible + T_FUNDIDO) break;
        double k = 1.0 - (t - visible) / T_FUNDIDO;
        escribir(recurso, img, cuadro, w, h, paso, &rect, (int)(256 * k * k));                  // se apaga suave
        u = vc_dispmanx_update_start(0);
        vc_dispmanx_element_modified(u, capa, &rect);
        vc_dispmanx_update_submit_sync(u);             // al ritmo del refresco
    }

    u = vc_dispmanx_update_start(0);
    vc_dispmanx_element_remove(u, capa);
    vc_dispmanx_update_submit_sync(u);
    vc_dispmanx_resource_delete(recurso);
    vc_dispmanx_display_close(pantalla);
    return 0;
}
