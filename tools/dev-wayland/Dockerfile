FROM debian:testing@sha256:16faa8d1cd99fcb2d30eebe90454e26b20499055fa7094e9b55d32d1a7666f08

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates dbus foot jq procps python3 quickshell wayland-utils \
       qt6-base-dev qt6-declarative-dev qt6-svg-dev qt6-wayland qt6-wayland-dev \
       qml6-module-qtquick-window sway wayvnc weston xwayland \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 ditto

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

USER ditto
WORKDIR /workspace
