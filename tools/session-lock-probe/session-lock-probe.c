#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <wayland-client.h>

#include "ext-session-lock-v1-client-protocol.h"

static struct ext_session_lock_manager_v1 *manager;
static bool locked;
static bool finished;

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data;
    (void)version;
    if (strcmp(interface, ext_session_lock_manager_v1_interface.name) == 0) {
        manager = wl_registry_bind(registry, name,
            &ext_session_lock_manager_v1_interface, 1);
    }
}

static void global_remove(void *data, struct wl_registry *registry,
                          uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = global,
    .global_remove = global_remove,
};

static void lock_locked(void *data, struct ext_session_lock_v1 *lock) {
    (void)data;
    (void)lock;
    locked = true;
}

static void lock_finished(void *data, struct ext_session_lock_v1 *lock) {
    (void)data;
    (void)lock;
    finished = true;
}

static const struct ext_session_lock_v1_listener lock_listener = {
    .locked = lock_locked,
    .finished = lock_finished,
};

int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) {
        fputs("could not connect to Wayland\n", stderr);
        return 2;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !manager) {
        fputs("ext_session_lock_manager_v1 is unavailable\n", stderr);
        return 3;
    }

    struct ext_session_lock_v1 *lock =
        ext_session_lock_manager_v1_lock(manager);
    ext_session_lock_v1_add_listener(lock, &lock_listener, NULL);
    wl_display_flush(display);

    struct pollfd pfd = {.fd = wl_display_get_fd(display), .events = POLLIN};
    for (int elapsed = 0; elapsed < 5000 && !locked && !finished;
         elapsed += 100) {
        int ready = poll(&pfd, 1, 100);
        if (ready < 0 || (ready > 0 && wl_display_dispatch(display) < 0)) {
            fputs("Wayland dispatch failed during lock\n", stderr);
            return 4;
        }
    }
    if (!locked) {
        fprintf(stderr, "minimal lock was not secured (finished=%s)\n",
                finished ? "true" : "false");
        return 5;
    }

    ext_session_lock_v1_unlock_and_destroy(lock);
    wl_display_flush(display);
    printf("{\"probed\":true,\"supported\":true,"
           "\"locked_event\":true,\"unlock_sent\":true}\n");
    ext_session_lock_manager_v1_destroy(manager);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return 0;
}
