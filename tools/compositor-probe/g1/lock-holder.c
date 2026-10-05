/*
 * C-19 lock client. Unlike tools/session-lock-probe (lock, then unlock at
 * once), this one keeps the session locked with an opaque magenta surface on
 * every output, so it can be SIGKILLed while the lock is held. With the
 * argument `unlock` it instead locks, waits for `locked`, and unlocks: the
 * probe uses that to ask whether a second client may take over a lock whose
 * first client died.
 *
 * Prints one line per state change on stdout: `locked`, `finished`, `unlocked`.
 */
#define _GNU_SOURCE
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include "ext-session-lock-v1-client-protocol.h"

#define MAX_OUTPUTS 8
#define COLOUR 0xffff00ffu /* ARGB magenta: easy to find in a screenshot */

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct ext_session_lock_manager_v1 *manager;
static struct wl_output *outputs[MAX_OUTPUTS];
static int output_count;
static bool locked, finished;

struct lock_surface {
    struct wl_surface *surface;
    struct ext_session_lock_surface_v1 *lock_surface;
};

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data;
    (void)version;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, wl_output_interface.name) == 0 && output_count < MAX_OUTPUTS) {
        outputs[output_count++] = wl_registry_bind(registry, name, &wl_output_interface, 1);
    } else if (strcmp(interface, ext_session_lock_manager_v1_interface.name) == 0) {
        manager = wl_registry_bind(registry, name, &ext_session_lock_manager_v1_interface, 1);
    }
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {global, global_remove};

static struct wl_buffer *solid_buffer(uint32_t width, uint32_t height) {
    size_t stride = (size_t)width * 4, size = stride * height;
    int fd = memfd_create("ditto-lock-holder", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)size) < 0) {
        return NULL;
    }
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) {
        close(fd);
        return NULL;
    }
    for (size_t i = 0; i < size / 4; i++) {
        pixels[i] = COLOUR;
    }
    munmap(pixels, size);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        pool, 0, (int32_t)width, (int32_t)height, (int32_t)stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return buffer;
}

static void surface_configure(void *data, struct ext_session_lock_surface_v1 *lock_surface,
                              uint32_t serial, uint32_t width, uint32_t height) {
    struct lock_surface *self = data;
    ext_session_lock_surface_v1_ack_configure(lock_surface, serial);
    struct wl_buffer *buffer = solid_buffer(width, height);
    if (!buffer) {
        fputs("could not allocate the lock buffer\n", stderr);
        exit(6);
    }
    wl_surface_attach(self->surface, buffer, 0, 0);
    wl_surface_damage(self->surface, 0, 0, (int32_t)width, (int32_t)height);
    wl_surface_commit(self->surface);
}

static const struct ext_session_lock_surface_v1_listener surface_listener = {surface_configure};

static void lock_locked(void *data, struct ext_session_lock_v1 *lock) {
    (void)data;
    (void)lock;
    locked = true;
    puts("locked");
    fflush(stdout);
}

static void lock_finished(void *data, struct ext_session_lock_v1 *lock) {
    (void)data;
    (void)lock;
    finished = true;
    puts("finished");
    fflush(stdout);
}

static const struct ext_session_lock_v1_listener lock_listener = {lock_locked, lock_finished};

int main(int argc, char **argv) {
    bool unlock = argc > 1 && strcmp(argv[1], "unlock") == 0;
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) {
        fputs("could not connect to Wayland\n", stderr);
        return 2;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !manager || !compositor || !shm) {
        fputs("ext_session_lock_manager_v1, wl_compositor or wl_shm is unavailable\n", stderr);
        return 3;
    }

    struct ext_session_lock_v1 *lock = ext_session_lock_manager_v1_lock(manager);
    ext_session_lock_v1_add_listener(lock, &lock_listener, NULL);
    static struct lock_surface surfaces[MAX_OUTPUTS];
    for (int i = 0; i < output_count; i++) {
        surfaces[i].surface = wl_compositor_create_surface(compositor);
        surfaces[i].lock_surface =
            ext_session_lock_v1_get_lock_surface(lock, surfaces[i].surface, outputs[i]);
        ext_session_lock_surface_v1_add_listener(surfaces[i].lock_surface, &surface_listener,
                                                 &surfaces[i]);
    }
    wl_display_flush(display);

    struct pollfd pfd = {.fd = wl_display_get_fd(display), .events = POLLIN};
    for (;;) {
        if (unlock && locked) {
            ext_session_lock_v1_unlock_and_destroy(lock);
            wl_display_roundtrip(display);
            puts("unlocked");
            fflush(stdout);
            return 0;
        }
        if (finished) {
            return 5;
        }
        wl_display_flush(display);
        int ready = poll(&pfd, 1, 1000);
        if (ready < 0 || (ready > 0 && wl_display_dispatch(display) < 0)) {
            fputs("Wayland dispatch failed\n", stderr);
            return 4;
        }
    }
}
