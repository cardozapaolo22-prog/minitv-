// minitv-estatica: estática de TV ("sintonizando") en una capa propia del firmware,
// ENCIMA del video de VLC. Así tapa la capa negra que VLC muestra mientras prepara el
// primer cuadro. Es la misma estática que se usa al cambiar de canal.
//
// Uso:  minitv-estatica             estática en bucle (visible)
//       minitv-estatica encendido   animación de tubo que se abre a estática, y luego estática
//       minitv-estatica apagado     apagado tipo tubo sobre lo que se ve ahora; luego negro
// Señales:  USR1 = ocultar (deja ver el video)   USR2 = mostrar   TERM/INT/HUP = salir
// Rótulo opcional (p. ej. "Cargando…"): con cada USR2 se vuelve a leer ROTULO (320x240 RGBA
// crudo, lo dibuja minitv con Pillow) y se mezcla encima de la estática; si no existe, no hay.
// Mientras está oculta no dibuja (no gasta CPU). Ignora USR1 hasta que el tubo termina
// de abrirse, para que la animación de encendido siempre se vea completa.
//
// Compilar:  gcc -O2 -Wall -o minitv-estatica minitv-estatica.c -lm -lbcm_host -lvchiq_arm -lvcos

#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "bcm_host.h"

#define FPS          30.0
#define CAPA_ARRIBA  10000    // por encima del video de VLC (capa 1)
#define CAPA_OCULTA  -10000   // por debajo de todo (incluida la consola, -127)

// Tiempos de la animación de encendido (segundos)
#define T_LINEA   0.10   // el punto se estira en una línea horizontal
#define T_ABRIR   0.20   // la línea se abre en vertical hasta llenar la pantalla
#define T_BLANCO  0.25   // hasta aquí el interior es blanco pleno...
#define T_FUNDIDO 0.30   // ...y en este tiempo se funde (a negro si hay logo; si no, a estática)
#define T_TUBO    (T_BLANCO + T_FUNDIDO)

// Logo tras el tubo: 320x240 RGB crudo sobre negro (lo genera generar-logo.py)
#define LOGO            "/usr/local/share/minitv/logo-arranque.rgb"
#define T_LOGO          2.0    // tiempo total del logo en pantalla
#define T_LOGO_FUNDIDO  0.7    // fundido de entrada desde negro

#define ROTULO          "/run/minitv/rotulo.rgba"

// Lee el rótulo (W*H RGBA). Devuelve NULL si no hay o no tiene el tamaño esperado.
static uint8_t *leer_rotulo(int W, int H) {
    FILE *f = fopen(ROTULO, "rb");
    if (!f) return NULL;
    uint8_t *r = malloc((size_t)W * H * 4);
    if (r && fread(r, 1, (size_t)W * H * 4, f) != (size_t)W * H * 4) { free(r); r = NULL; }
    fclose(f);
    return r;
}

static const uint8_t BAYER[4][4] = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } };

static volatile sig_atomic_t salir = 0, pedir_ocultar = 0, pedir_mostrar = 0;
static void al_salir(int s)   { (void)s; salir = 1; }
static void al_ocultar(int s) { (void)s; pedir_ocultar = 1; pedir_mostrar = 0; }
static void al_mostrar(int s) { (void)s; pedir_mostrar = 1; pedir_ocultar = 0; }

static uint32_t semilla = 2463534242u;
static inline uint32_t azar(void) {  // xorshift32
    semilla ^= semilla << 13; semilla ^= semilla >> 17; semilla ^= semilla << 5;
    return semilla;
}

static double ahora(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static inline uint16_t rgb565(int r, int g, int b) {
    return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

static void cambiar_capa(DISPMANX_ELEMENT_HANDLE_T e, int capa) {
    DISPMANX_UPDATE_HANDLE_T u = vc_dispmanx_update_start(0);
    vc_dispmanx_element_change_layer(u, e, capa);
    vc_dispmanx_update_submit_sync(u);
}

// --- Apagado tipo tubo -------------------------------------------------------------------
// Foto de lo que se ve ahora; se aplasta en vertical hasta una línea que se vuelve blanca,
// la línea se encoge a un punto y el punto se apaga. Después queda en negro hasta TERM.
#define A_APLASTAR 0.22
#define A_ENCOGER  0.16
#define A_PUNTO    0.30

static inline uint16_t hacia_blanco(uint16_t p, int k /*0..256*/) {
    int r = (p >> 11) << 3, g = ((p >> 5) & 63) << 2, b = (p & 31) << 3;
    return rgb565(r + ((255 - r) * k >> 8), g + ((255 - g) * k >> 8), b + ((255 - b) * k >> 8));
}

static int apagar_tubo(DISPMANX_DISPLAY_HANDLE_T pantalla, int W, int H, int paso) {
    uint32_t img;
    VC_RECT_T rect, origen;
    vc_dispmanx_rect_set(&rect, 0, 0, W, H);
    vc_dispmanx_rect_set(&origen, 0, 0, W << 16, H << 16);
    const int ancho_fila = paso / 2;
    uint16_t *foto = calloc((size_t)ancho_fila * H, 2), *cuadro = calloc((size_t)ancho_fila * H, 2);

    // 1) Foto de la pantalla actual (antes de poner nuestra capa encima)
    DISPMANX_RESOURCE_HANDLE_T rfoto = vc_dispmanx_resource_create(VC_IMAGE_RGB565, W, H, &img);
    vc_dispmanx_snapshot(pantalla, rfoto, 0);
    vc_dispmanx_resource_read_data(rfoto, &rect, foto, paso);
    vc_dispmanx_resource_delete(rfoto);

    // 2) Capa por encima de todo (incluida la estática) que empieza mostrando esa foto
    DISPMANX_RESOURCE_HANDLE_T recurso = vc_dispmanx_resource_create(VC_IMAGE_RGB565, W, H, &img);
    vc_dispmanx_resource_write_data(recurso, VC_IMAGE_RGB565, paso, foto, &rect);
    VC_DISPMANX_ALPHA_T opaco = { DISPMANX_FLAGS_ALPHA_FIXED_ALL_PIXELS, 255, 0 };
    DISPMANX_UPDATE_HANDLE_T u = vc_dispmanx_update_start(0);
    DISPMANX_ELEMENT_HANDLE_T capa = vc_dispmanx_element_add(u, pantalla, CAPA_ARRIBA + 1, &rect, recurso, &origen,
                                                             DISPMANX_PROTECTION_NONE, &opaco, NULL, DISPMANX_NO_ROTATE);
    vc_dispmanx_update_submit_sync(u);

    struct sigaction sa = { 0 };
    sa.sa_handler = al_salir; sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); sigaction(SIGHUP, &sa, NULL);

    const int cx = W / 2, cy = H / 2;
    const double t0 = ahora();
    int terminado = 0;
    while (!salir) {
        const double t = ahora() - t0;
        if (terminado) { usleep(50000); continue; }
        memset(cuadro, 0, (size_t)ancho_fila * H * 2);

        if (t < A_APLASTAR) {                       // la imagen se aplasta y se aclara
            double k = t / A_APLASTAR;
            int alto = (int)(H * (1 - k) * (1 - k));
            if (alto < 2) alto = 2;
            int arriba = cy - alto / 2, claro = (int)(256 * k);
            for (int y = 0; y < alto; y++) {
                const uint16_t *src = foto + (size_t)(y * H / alto) * ancho_fila;
                uint16_t *dst = cuadro + (size_t)(arriba + y) * ancho_fila;
                for (int x = 0; x < W; x++) dst[x] = hacia_blanco(src[x], claro);
            }
        } else if (t < A_APLASTAR + A_ENCOGER) {    // línea blanca que se encoge hacia el centro
            double k = (t - A_APLASTAR) / A_ENCOGER;
            int semiancho = (int)(W / 2 * (1 - k) * (1 - k));
            if (semiancho < 2) semiancho = 2;
            for (int y = cy - 1; y <= cy; y++)
                for (int x = cx - semiancho; x < cx + semiancho; x++) cuadro[(size_t)y * ancho_fila + x] = 0xFFFF;
        } else if (t < A_APLASTAR + A_ENCOGER + A_PUNTO) {   // punto que se apaga
            double k = (t - A_APLASTAR - A_ENCOGER) / A_PUNTO;
            int v = (int)(255 * (1 - k)), radio = k < 0.5 ? 2 : 1;
            for (int y = cy - radio; y < cy + radio; y++)
                for (int x = cx - radio; x < cx + radio; x++) cuadro[(size_t)y * ancho_fila + x] = rgb565(v, v, v);
        } else {
            terminado = 1;                          // negro y esperar
        }

        vc_dispmanx_resource_write_data(recurso, VC_IMAGE_RGB565, paso, cuadro, &rect);
        u = vc_dispmanx_update_start(0);
        vc_dispmanx_element_modified(u, capa, &rect);
        vc_dispmanx_update_submit_sync(u);          // al ritmo del refresco (60 Hz)
    }

    u = vc_dispmanx_update_start(0);
    vc_dispmanx_element_remove(u, capa);
    vc_dispmanx_update_submit_sync(u);
    vc_dispmanx_resource_delete(recurso);
    vc_dispmanx_display_close(pantalla);
    return 0;
}

int main(int argc, char **argv) {
    int encendido = argc > 1 && strcmp(argv[1], "encendido") == 0;

    // En el arranque la mini TV empieza antes de que udev dé permisos de /dev/vchiq al grupo
    // video: esperar (máx. 3 s) en vez de fallar, que bcm_host_init() termina el programa.
    for (int i = 0; i < 300 && access("/dev/vchiq", R_OK | W_OK) != 0; i++) usleep(10000);

    bcm_host_init();
    DISPMANX_DISPLAY_HANDLE_T pantalla = vc_dispmanx_display_open(0);
    if (!pantalla) { fprintf(stderr, "No se pudo abrir el display\n"); return 1; }
    DISPMANX_MODEINFO_T info;
    vc_dispmanx_display_get_info(pantalla, &info);
    const int W = info.width, H = info.height, paso = ALIGN_UP(W * 2, 32);

    if (argc > 1 && strcmp(argv[1], "apagado") == 0)
        return apagar_tubo(pantalla, W, H, paso);

    uint32_t img;
    DISPMANX_RESOURCE_HANDLE_T recurso = vc_dispmanx_resource_create(VC_IMAGE_RGB565, W, H, &img);
    uint16_t *cuadro = calloc((size_t)paso / 2 * H, 2);   // empieza en negro
    VC_RECT_T rect, origen;
    vc_dispmanx_rect_set(&rect, 0, 0, W, H);
    vc_dispmanx_rect_set(&origen, 0, 0, W << 16, H << 16);
    vc_dispmanx_resource_write_data(recurso, VC_IMAGE_RGB565, paso, cuadro, &rect);

    VC_DISPMANX_ALPHA_T opaco = { DISPMANX_FLAGS_ALPHA_FIXED_ALL_PIXELS, 255, 0 };
    DISPMANX_UPDATE_HANDLE_T u = vc_dispmanx_update_start(0);
    DISPMANX_ELEMENT_HANDLE_T capa = vc_dispmanx_element_add(u, pantalla, CAPA_ARRIBA, &rect, recurso, &origen,
                                                             DISPMANX_PROTECTION_NONE, &opaco, NULL, DISPMANX_NO_ROTATE);
    vc_dispmanx_update_submit_sync(u);

    struct sigaction sa = { 0 };
    sa.sa_handler = al_salir;   sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); sigaction(SIGHUP, &sa, NULL);
    sa.sa_handler = al_ocultar; sigaction(SIGUSR1, &sa, NULL);
    sa.sa_handler = al_mostrar; sigaction(SIGUSR2, &sa, NULL);
    semilla ^= (uint32_t)(ahora() * 1e6);

    const int blanco_r = 222, blanco_g = 236, blanco_b = 255;
    // Logo del encendido (opcional: sin el archivo, el tubo se abre directamente a estática)
    uint8_t *logo = NULL;
    if (encendido) {
        FILE *f = fopen(LOGO, "rb");
        if (f) {
            logo = malloc((size_t)W * H * 3);
            if (fread(logo, 1, (size_t)W * H * 3, f) != (size_t)W * H * 3) { free(logo); logo = NULL; }
            fclose(f);
        }
    }
    const double fin_encendido = logo ? T_TUBO + T_LOGO : T_TUBO;
    uint8_t *rotulo = NULL;

    const double t0 = ahora();
    int visible = 1;
    long n = 0;
    double t_ritmo = t0;

    while (!salir) {
        const double t = ahora() - t0;
        const int tubo = encendido && t < fin_encendido;      // tubo (+ logo): no se deja ocultar
        const int en_tubo = encendido && t < T_TUBO;
        const int en_logo = logo && t >= T_TUBO && t < fin_encendido;

        if (pedir_ocultar && !tubo) {
            pedir_ocultar = 0;
            if (visible) { cambiar_capa(capa, CAPA_OCULTA); visible = 0; }
        }
        if (pedir_mostrar) {
            pedir_mostrar = 0;
            free(rotulo);
            rotulo = leer_rotulo(W, H);                       // puede haber cambiado (o ya no estar)
            if (!visible) { cambiar_capa(capa, CAPA_ARRIBA); visible = 1; t_ritmo = ahora(); n = 0; }
        }
        if (!visible) { usleep(20000); continue; }

        // --- Estática: ruido gris azulado, con una banda de brillo que rueda y rayas sueltas ---
        // (mientras hay tubo + logo, la base es negra en vez de estática)
        const int parpadeo = 218 + (azar() & 37);
        if (logo && encendido && t < fin_encendido) memset(cuadro, 0, (size_t)paso * H);
        else for (int y = 0; y < H; y++) {
            int ganancia = (int)(parpadeo * (0.72f + 0.28f * sinf(y * 0.045f - (float)t * 7.0f)));
            if ((azar() & 63) == 0) ganancia = ganancia * 3 / 2;          // raya horizontal brillante
            uint16_t *fila = cuadro + (size_t)y * (paso / 2);
            for (int x = 0; x < W; x += 4) {
                uint32_t r = azar();
                for (int k = 0; k < 4 && x + k < W; k++, r >>= 8) {
                    int v = ((int)(r & 255) * ganancia) >> 8;
                    if (v > 255) v = 255;
                    fila[x + k] = rgb565(v * 225 >> 8, v * 240 >> 8, v);
                }
            }
        }

        // --- Logo: fundido de entrada desde negro, con tramado ordenado al pasar a 16 bits ---
        if (en_logo) {
            float k = fminf(1.0f, (float)((t - T_TUBO) / T_LOGO_FUNDIDO));
            int peso = (int)(256 * k * k * (3 - 2 * k));        // curva suave (smoothstep)
            for (int y = 0; y < H; y++) {
                uint16_t *fila = cuadro + (size_t)y * (paso / 2);
                const uint8_t *src = logo + (size_t)y * W * 3;
                for (int x = 0; x < W; x++, src += 3) {
                    int d = BAYER[y & 3][x & 3];
                    int r = (src[0] * peso >> 8) + (d >> 1), g = (src[1] * peso >> 8) + (d >> 2),
                        b = (src[2] * peso >> 8) + (d >> 1);
                    fila[x] = rgb565(r > 255 ? 255 : r, g > 255 ? 255 : g, b > 255 ? 255 : b);
                }
            }
        }

        // --- Encendido: rectángulo que se abre; fuera, negro; dentro, blanco que se funde ---
        if (en_tubo) {
            float semiancho = t < T_LINEA ? 1.0f + (W / 2.0f) * (float)(t / T_LINEA) : W / 2.0f;
            float semialto = t < T_LINEA ? 1.0f
                           : 1.0f + (H / 2.0f - 1.0f) * fminf(1.0f, (float)((t - T_LINEA) / T_ABRIR));
            int peso = (int)(256 * (t < T_BLANCO ? 1.0 : fmax(0.0, 1.0 - (t - T_BLANCO) / T_FUNDIDO)));
            for (int y = 0; y < H; y++) {
                uint16_t *fila = cuadro + (size_t)y * (paso / 2);
                int dentro_y = fabsf(y - H / 2.0f + 0.5f) <= semialto;
                for (int x = 0; x < W; x++) {
                    if (!dentro_y || fabsf(x - W / 2.0f + 0.5f) > semiancho) { fila[x] = 0; continue; }
                    uint16_t e = fila[x];
                    int er = (e >> 11) << 3, eg = ((e >> 5) & 63) << 2, eb = (e & 31) << 3;
                    fila[x] = rgb565((er * (256 - peso) + blanco_r * peso) >> 8,
                                     (eg * (256 - peso) + blanco_g * peso) >> 8,
                                     (eb * (256 - peso) + blanco_b * peso) >> 8);
                }
            }
        }

        // --- Rótulo encima de la estática (mezcla por alfa) ---
        if (rotulo && !tubo) {
            for (int y = 0; y < H; y++) {
                uint16_t *fila = cuadro + (size_t)y * (paso / 2);
                const uint8_t *src = rotulo + (size_t)y * W * 4;
                for (int x = 0; x < W; x++, src += 4) {
                    int a = src[3];
                    if (!a) continue;
                    uint16_t e = fila[x];
                    int er = (e >> 11) << 3, eg = ((e >> 5) & 63) << 2, eb = (e & 31) << 3;
                    fila[x] = rgb565((er * (255 - a) + src[0] * a) / 255, (eg * (255 - a) + src[1] * a) / 255,
                                     (eb * (255 - a) + src[2] * a) / 255);
                }
            }
        }

        vc_dispmanx_resource_write_data(recurso, VC_IMAGE_RGB565, paso, cuadro, &rect);
        u = vc_dispmanx_update_start(0);
        vc_dispmanx_element_modified(u, capa, &rect);
        vc_dispmanx_update_submit(u, NULL, NULL);

        // Ritmo fijo de 30 cuadros por segundo
        n++;
        double espera = t_ritmo + n / FPS - ahora();
        if (espera > 0) usleep((useconds_t)(espera * 1e6));
        else if (espera < -0.5) { t_ritmo = ahora(); n = 0; }
    }

    u = vc_dispmanx_update_start(0);
    vc_dispmanx_element_remove(u, capa);
    vc_dispmanx_update_submit_sync(u);
    vc_dispmanx_resource_delete(recurso);
    vc_dispmanx_display_close(pantalla);
    return 0;
}
