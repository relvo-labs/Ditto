#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include "xdg-activation-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

struct window {
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct wl_buffer *buffer;
    bool configured;
};

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_pointer *pointer;
static struct xdg_wm_base *wm_base;
static struct xdg_activation_v1 *activation;
static struct window launcher;
static struct window target;
static struct wl_surface *pointer_surface;
static bool token_requested;
static bool token_done;

static struct wl_buffer *make_buffer(uint32_t color) {
    const int width = 320, height = 180, stride = width * 4;
    const size_t size = (size_t)stride * height;
    char name[] = "/tmp/ditto-activation-XXXXXX";
    int fd = mkstemp(name);
    if (fd < 0 || unlink(name) < 0 || ftruncate(fd, (off_t)size) < 0) {
        perror("activation buffer");
        exit(2);
    }
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE,
                            MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) {
        perror("mmap");
        exit(2);
    }
    for (size_t i = 0; i < size / sizeof(*pixels); ++i) pixels[i] = color;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        pool, 0, width, height, stride, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    munmap(pixels, size);
    close(fd);
    return buffer;
}

static void surface_configure(void *data, struct xdg_surface *surface,
                              uint32_t serial) {
    struct window *window = data;
    xdg_surface_ack_configure(surface, serial);
    if (!window->configured) {
        wl_surface_attach(window->surface, window->buffer, 0, 0);
        wl_surface_damage(window->surface, 0, 0, 320, 180);
        wl_surface_commit(window->surface);
        window->configured = true;
        if (launcher.configured && target.configured) {
            puts("READY");
            fflush(stdout);
        }
    }
}

static const struct xdg_surface_listener surface_listener = {
    .configure = surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel,
                               int32_t width, int32_t height,
                               struct wl_array *states) {
    (void)data; (void)toplevel; (void)width; (void)height; (void)states;
}
static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
    (void)data; (void)toplevel;
}
static void toplevel_bounds(void *data, struct xdg_toplevel *toplevel,
                            int32_t width, int32_t height) {
    (void)data; (void)toplevel; (void)width; (void)height;
}
static void toplevel_caps(void *data, struct xdg_toplevel *toplevel,
                          struct wl_array *caps) {
    (void)data; (void)toplevel; (void)caps;
}
static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
    .configure_bounds = toplevel_bounds,
    .wm_capabilities = toplevel_caps,
};

static void token_done_event(void *data, struct xdg_activation_token_v1 *token,
                             const char *value) {
    (void)data;
    xdg_activation_v1_activate(activation, value, target.surface);
    xdg_activation_token_v1_destroy(token);
    wl_display_flush(display);
    token_done = true;
    puts("TOKEN_DONE");
    fflush(stdout);
}
static const struct xdg_activation_token_v1_listener token_listener = {
    .done = token_done_event,
};

static void request_token(uint32_t serial) {
    if (token_requested || pointer_surface != launcher.surface) return;
    token_requested = true;
    struct xdg_activation_token_v1 *token =
        xdg_activation_v1_get_activation_token(activation);
    xdg_activation_token_v1_add_listener(token, &token_listener, NULL);
    xdg_activation_token_v1_set_serial(token, serial, seat);
    xdg_activation_token_v1_set_surface(token, launcher.surface);
    xdg_activation_token_v1_set_app_id(token, "ditto-activation-target");
    xdg_activation_token_v1_commit(token);
}

static void pointer_enter(void *data, struct wl_pointer *p, uint32_t serial,
                          struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y) {
    (void)data; (void)p; (void)serial; (void)x; (void)y;
    pointer_surface = surface;
}
static void pointer_leave(void *data, struct wl_pointer *p, uint32_t serial,
                          struct wl_surface *surface) {
    (void)data; (void)p; (void)serial; (void)surface;
    pointer_surface = NULL;
}
static void pointer_motion(void *data, struct wl_pointer *p, uint32_t time,
                           wl_fixed_t x, wl_fixed_t y) {
    (void)data; (void)p; (void)time; (void)x; (void)y;
}
static void pointer_button(void *data, struct wl_pointer *p, uint32_t serial,
                           uint32_t time, uint32_t button, uint32_t state) {
    (void)data; (void)p; (void)time; (void)button;
    if (state == WL_POINTER_BUTTON_STATE_PRESSED) request_token(serial);
}
static void pointer_axis(void *data, struct wl_pointer *p, uint32_t time,
                         uint32_t axis, wl_fixed_t value) {
    (void)data; (void)p; (void)time; (void)axis; (void)value;
}
static void pointer_frame(void *data, struct wl_pointer *p) {(void)data;(void)p;}
static void pointer_axis_source(void *data, struct wl_pointer *p, uint32_t s) {(void)data;(void)p;(void)s;}
static void pointer_axis_stop(void *data, struct wl_pointer *p, uint32_t t, uint32_t a) {(void)data;(void)p;(void)t;(void)a;}
static void pointer_axis_discrete(void *data, struct wl_pointer *p, uint32_t a, int32_t d) {(void)data;(void)p;(void)a;(void)d;}
static void pointer_axis_value120(void *data, struct wl_pointer *p, uint32_t a, int32_t v) {(void)data;(void)p;(void)a;(void)v;}
static void pointer_axis_relative(void *data, struct wl_pointer *p, uint32_t a, uint32_t d) {(void)data;(void)p;(void)a;(void)d;}
static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter, .leave = pointer_leave, .motion = pointer_motion,
    .button = pointer_button, .axis = pointer_axis, .frame = pointer_frame,
    .axis_source = pointer_axis_source, .axis_stop = pointer_axis_stop,
    .axis_discrete = pointer_axis_discrete,
    .axis_value120 = pointer_axis_value120,
    .axis_relative_direction = pointer_axis_relative,
};

static void seat_caps(void *data, struct wl_seat *s, uint32_t caps) {
    (void)data;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !pointer) {
        pointer = wl_seat_get_pointer(s);
        wl_pointer_add_listener(pointer, &pointer_listener, NULL);
    }
}
static void seat_name(void *data, struct wl_seat *s, const char *name) {(void)data;(void)s;(void)name;}
static const struct wl_seat_listener seat_listener = {.capabilities=seat_caps,.name=seat_name};

static void wm_ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {.ping = wm_ping};

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data;
    if (strcmp(interface, wl_compositor_interface.name) == 0)
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 4 ? version : 4);
    else if (strcmp(interface, wl_shm_interface.name) == 0)
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (strcmp(interface, wl_seat_interface.name) == 0) {
        seat = wl_registry_bind(registry, name, &wl_seat_interface, version < 9 ? version : 9);
        wl_seat_add_listener(seat, &seat_listener, NULL);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    } else if (strcmp(interface, xdg_activation_v1_interface.name) == 0)
        activation = wl_registry_bind(registry, name, &xdg_activation_v1_interface, 1);
}
static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {(void)data;(void)registry;(void)name;}
static const struct wl_registry_listener registry_listener = {.global=global,.global_remove=global_remove};

static void create_window(struct window *window, const char *app_id,
                          const char *title, uint32_t color) {
    window->surface = wl_compositor_create_surface(compositor);
    window->buffer = make_buffer(color);
    window->xdg_surface = xdg_wm_base_get_xdg_surface(wm_base, window->surface);
    xdg_surface_add_listener(window->xdg_surface, &surface_listener, window);
    window->toplevel = xdg_surface_get_toplevel(window->xdg_surface);
    xdg_toplevel_add_listener(window->toplevel, &toplevel_listener, window);
    xdg_toplevel_set_app_id(window->toplevel, app_id);
    xdg_toplevel_set_title(window->toplevel, title);
    wl_surface_commit(window->surface);
}

int main(void) {
    display = wl_display_connect(NULL);
    if (!display) return 2;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!compositor || !shm || !seat || !wm_base || !activation) {
        fputs("required xdg activation globals are unavailable\n", stderr);
        return 3;
    }
    create_window(&launcher, "ditto-activation-launcher", "Ditto activation launcher", 0xff315d80);
    create_window(&target, "ditto-activation-target", "Ditto activation target", 0xff80315d);
    while (!token_done && wl_display_dispatch(display) >= 0) {}
    if (!token_done) return 4;
    wl_display_roundtrip(display);
    sleep(2);
    return 0;
}
