// minitv-captura: mide lo que se ve en pantalla (la imagen compuesta del firmware, la misma
// que copia fbcp-ili9341 al panel) y clasifica cada cuadro como NEGRO, ESTATICA o IMAGEN.
// Imprime cada cambio de clase con la hora desde el arranque (misma escala que journalctl
// -o short-monotonic) y al final un resumen con los cuadros negros que hubo DESPUÉS de que
// apareciera algo en pantalla.
//
// Uso:  minitv-captura [segundos] [hasta_segundos_de_uptime]
//       minitv-captura foto archivo.ppm      (guarda lo que se ve en pantalla)
// Compilar:  gcc -O2 -Wall -o minitv-captura minitv-captura.c -lbcm_host -lvchiq_arm -lvcos

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "bcm_host.h"

static double ahora(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

// Guarda lo que se ve en pantalla como imagen PPM (P6).
static int foto(const char *archivo) {
    bcm_host_init();
    DISPMANX_DISPLAY_HANDLE_T d = vc_dispmanx_display_open(0);
    if (!d) { fprintf(stderr, "No se pudo abrir el display\n"); return 1; }
    DISPMANX_MODEINFO_T info;
    vc_dispmanx_display_get_info(d, &info);
    const int W = info.width, H = info.height;
    uint32_t img;
    DISPMANX_RESOURCE_HANDLE_T res = vc_dispmanx_resource_create(VC_IMAGE_RGBA32, W, H, &img);
    VC_RECT_T rect;
    vc_dispmanx_rect_set(&rect, 0, 0, W, H);
    uint8_t *buf = malloc((size_t)W * H * 4);
    vc_dispmanx_snapshot(d, res, 0);
    vc_dispmanx_resource_read_data(res, &rect, buf, W * 4);
    FILE *f = fopen(archivo, "wb");
    if (!f) { perror(archivo); return 1; }
    fprintf(f, "P6\n%d %d\n255\n", W, H);
    for (int i = 0; i < W * H; i++) fwrite(buf + i * 4, 1, 3, f);
    fclose(f);
    vc_dispmanx_resource_delete(res);
    vc_dispmanx_display_close(d);
    printf("Foto guardada: %s (%dx%d)\n", archivo, W, H);
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 2 && strcmp(argv[1], "foto") == 0) return foto(argv[2]);
    double duracion = argc > 1 ? atof(argv[1]) : 10.0;
    double hasta = argc > 2 ? atof(argv[2]) : 0.0;   // alternativa: medir hasta este uptime

    bcm_host_init();
    DISPMANX_DISPLAY_HANDLE_T d = 0;
    for (int i = 0; i < 200 && !d; i++) { d = vc_dispmanx_display_open(0); if (!d) usleep(20000); }
    if (!d) { fprintf(stderr, "No se pudo abrir el display\n"); return 1; }
    DISPMANX_MODEINFO_T info;
    vc_dispmanx_display_get_info(d, &info);
    const int W = info.width, H = info.height;
    uint32_t img;
    DISPMANX_RESOURCE_HANDLE_T res = vc_dispmanx_resource_create(VC_IMAGE_RGBA32, W, H, &img);
    VC_RECT_T rect;
    vc_dispmanx_rect_set(&rect, 0, 0, W, H);
    uint8_t *buf = malloc((size_t)W * H * 4);

    const char *nombres[] = { "NEGRO", "ESTATICA", "IMAGEN" };
    int anterior = -1, visto_algo = 0;
    long cuadros = 0, negros_tras_inicio = 0, cuadros_clase = 0;
    double inicio = ahora(), desde = inicio;

    while (hasta > 0 ? ahora() < hasta : ahora() - inicio < duracion) {
        vc_dispmanx_snapshot(d, res, 0);
        vc_dispmanx_resource_read_data(res, &rect, buf, W * 4);
        double t = ahora();

        // Luminancia media y "rugosidad" (diferencia media entre píxeles vecinos) en una muestra
        long suma = 0, dif = 0, n = 0;
        for (int y = 0; y < H; y += 2) {
            uint8_t *fila = buf + (size_t)y * W * 4;
            int previo = -1;
            for (int x = 0; x < W; x++) {
                uint8_t *p = fila + x * 4;
                int lum = (p[0] * 77 + p[1] * 150 + p[2] * 29) >> 8;
                if (previo >= 0) dif += abs(lum - previo);
                previo = lum; suma += lum; n++;
            }
        }
        double media = (double)suma / n, rugosidad = (double)dif / n;
        int clase = media < 10 ? 0 : (rugosidad > 35 ? 1 : 2);

        cuadros++;
        if (clase != 0) visto_algo = 1;
        else if (visto_algo) negros_tras_inicio++;
        if (clase != anterior) {
            if (anterior >= 0)
                printf("    (%ld cuadros, %.2f s)\n", cuadros_clase, t - desde);
            printf("%8.3f  %-8s  luz media %5.1f  rugosidad %5.1f\n", t, nombres[clase], media, rugosidad);
            fflush(stdout);
            anterior = clase; desde = t; cuadros_clase = 0;
        }
        cuadros_clase++;
        usleep(5000);
    }
    printf("    (%ld cuadros, %.2f s)\n", cuadros_clase, ahora() - desde);
    printf("RESUMEN: %ld cuadros medidos (%.0f por segundo); cuadros NEGROS después de aparecer imagen: %ld\n",
           cuadros, cuadros / (ahora() - inicio), negros_tras_inicio);

    vc_dispmanx_resource_delete(res);
    vc_dispmanx_display_close(d);
    return 0;
}
