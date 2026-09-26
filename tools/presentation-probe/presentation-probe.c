#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <wayland-client.h>

#include "presentation-time-client-protocol.h"
#include "xdg-shell-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wp_presentation *presentation;
static struct wl_surface *surface;
static struct wl_buffer *buffer;
static int configured;
static int target_frames = 180;
static int presented_frames;
static int discarded_frames;
static uint64_t previous_ns;
static uint32_t clock_id;

static void draw_frame(void);

static void feedback_sync_output(void *data, struct wp_presentation_feedback *feedback,
                                 struct wl_output *output) {
    (void)data; (void)feedback; (void)output;
}

static void feedback_presented(void *data, struct wp_presentation_feedback *feedback,
                               uint32_t sec_hi, uint32_t sec_lo, uint32_t nsec,
                               uint32_t refresh, uint32_t seq_hi, uint32_t seq_lo,
                               uint32_t flags) {
    (void)data;
    uint64_t seconds = ((uint64_t)sec_hi << 32) | sec_lo;
    uint64_t sequence = ((uint64_t)seq_hi << 32) | seq_lo;
    uint64_t timestamp = seconds * 1000000000ULL + nsec;
    double interval_ms = previous_ns ? (timestamp - previous_ns) / 1000000.0 : 0.0;
    printf("{\"frame\":%d,\"timestamp_ns\":%llu,\"interval_ms\":%.6f,"
           "\"refresh_ns\":%u,\"sequence\":%llu,\"flags\":%u,\"clock_id\":%u}\n",
           presented_frames + 1, (unsigned long long)timestamp, interval_ms, refresh,
           (unsigned long long)sequence, flags, clock_id);
    fflush(stdout);
    previous_ns = timestamp;
    presented_frames++;
    wp_presentation_feedback_destroy(feedback);
    if (presented_frames + discarded_frames < target_frames) draw_frame();
}

static void feedback_discarded(void *data, struct wp_presentation_feedback *feedback) {
    (void)data;
    discarded_frames++;
    wp_presentation_feedback_destroy(feedback);
    if (presented_frames + discarded_frames < target_frames) draw_frame();
}

static const struct wp_presentation_feedback_listener feedback_listener = {
    .sync_output = feedback_sync_output,
    .presented = feedback_presented,
    .discarded = feedback_discarded,
};

static void presentation_clock_id(void *data, struct wp_presentation *object, uint32_t id) {
    (void)data; (void)object; clock_id = id;
}

static const struct wp_presentation_listener presentation_listener = {
    .clock_id = presentation_clock_id,
};

static void wm_ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
    (void)data; xdg_wm_base_pong(base, serial);
}

static const struct xdg_wm_base_listener wm_listener = {.ping = wm_ping};

static void xdg_configure(void *data, struct xdg_surface *xdg_surface, uint32_t serial) {
    (void)data; xdg_surface_ack_configure(xdg_surface, serial); configured = 1;
}

static const struct xdg_surface_listener xdg_listener = {.configure = xdg_configure};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface, wl_compositor_interface.name))
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 6 ? version : 6);
    else if (!strcmp(interface, wl_shm_interface.name))
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, xdg_wm_base_interface.name))
        wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
    else if (!strcmp(interface, wp_presentation_interface.name))
        presentation = wl_registry_bind(registry, name, &wp_presentation_interface, 1);
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global, .global_remove = registry_remove,
};

static struct wl_buffer *make_buffer(void) {
    const int width = 64, height = 64, stride = width * 4, size = stride * height;
    int fd = memfd_create("ditto-presentation-probe", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, size) < 0) return NULL;
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) { close(fd); return NULL; }
    for (int i = 0; i < width * height; i++) pixels[i] = 0xff7457d9;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *result = wl_shm_pool_create_buffer(
        pool, 0, width, height, stride, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    munmap(pixels, size);
    close(fd);
    return result;
}

static void draw_frame(void) {
    struct wp_presentation_feedback *feedback = wp_presentation_feedback(presentation, surface);
    wp_presentation_feedback_add_listener(feedback, &feedback_listener, NULL);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, 64, 64);
    wl_surface_commit(surface);
}

int main(int argc, char **argv) {
    if (argc == 2) target_frames = atoi(argv[1]);
    if (target_frames < 2) { fprintf(stderr, "frame count must be at least 2\n"); return 2; }
    display = wl_display_connect(NULL);
    if (!display) { perror("wl_display_connect"); return 1; }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    wl_display_roundtrip(display);
    if (!compositor || !shm || !wm_base || !presentation) {
        fprintf(stderr, "required Wayland globals are missing\n"); return 1;
    }
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    wp_presentation_add_listener(presentation, &presentation_listener, NULL);
    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xdg_surface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xdg_surface, &xdg_listener, NULL);
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xdg_surface);
    xdg_toplevel_set_title(toplevel, "Ditto presentation probe");
    xdg_toplevel_set_app_id(toplevel, "ditto-presentation-probe");
    wl_surface_commit(surface);
    while (!configured && wl_display_dispatch(display) >= 0) {}
    buffer = make_buffer();
    if (!buffer) { perror("make_buffer"); return 1; }
    draw_frame();
    while (presented_frames + discarded_frames < target_frames && wl_display_dispatch(display) >= 0) {}
    fprintf(stderr, "presented=%d discarded=%d clock_id=%u\n",
            presented_frames, discarded_frames, clock_id);
    return presented_frames == target_frames ? 0 : 1;
}
