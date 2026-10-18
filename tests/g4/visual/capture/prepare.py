#!/usr/bin/env python3
"""Collect the applications the capture's Dock shows, from this machine.

For each role in the reference Dock (files, browser, terminal, editor, images,
music, settings) take the first desktop entry that is installed here, read its
Name and Icon, and resolve the icon through the icon theme on disk. A role with
nothing installed is left out; an icon that does not resolve is left empty so
the Dock shows its lettered fallback. Nothing is downloaded or drawn.

The resolution approximates the freedesktop icon-theme lookup (theme, its
Inherits, hicolor, pixmaps; scalable first, else the largest bitmap). The real
Shell asks Quickshell, which may pick a different file for the same name.

Writes .staged/capture-data.js (for the QML scene) and
.staged/capture-sources.json (paths and hashes, for the evidence record).
"""
import configparser
import hashlib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STAGED = os.path.join(HERE, "..", ".staged")

ROLES = [
    ("files", ["org.gnome.Nautilus", "org.kde.dolphin", "thunar"]),
    ("browser", ["firefox", "firefox_firefox", "org.mozilla.firefox", "chromium"]),
    ("terminal", ["org.gnome.Ptyxis", "org.codeberg.dnkl.foot", "org.gnome.Console", "org.kde.konsole"]),
    ("editor", ["org.gnome.TextEditor", "org.kde.kate", "org.gnome.gedit"]),
    ("images", ["org.gnome.Loupe", "org.gnome.eog", "org.kde.gwenview"]),
    ("music", ["org.gnome.Music", "org.gnome.Rhythmbox3", "org.kde.elisa"]),
    ("settings", ["org.gnome.Settings", "systemsettings"]),
]


def data_dirs():
    dirs = [os.path.expanduser("~/.local/share")]
    dirs += (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":")
    dirs.append("/var/lib/snapd/desktop")
    return [d for d in dirs if d]


def find_entry(app_id):
    for base in data_dirs():
        path = os.path.join(base, "applications", app_id + ".desktop")
        if os.path.isfile(path):
            return path
    return None


def read_entry(path):
    parser = configparser.RawConfigParser(strict=False, interpolation=None)
    parser.optionxform = str
    parser.read(path, encoding="utf-8")
    section = parser["Desktop Entry"]
    name = section.get("Name[zh_TW]") or section.get("Name") or ""
    return name, section.get("Icon", "")


def icon_theme():
    try:
        out = subprocess.run(["gsettings", "get", "org.gnome.desktop.interface", "icon-theme"],
                             capture_output=True, text=True, timeout=5).stdout.strip().strip("'")
        return out or "hicolor"
    except (OSError, subprocess.TimeoutExpired):
        return "hicolor"


def theme_chain(theme):
    chain, queue = [], [theme]
    while queue:
        name = queue.pop(0)
        if name in chain:
            continue
        index = os.path.join("/usr/share/icons", name, "index.theme")
        if not os.path.isdir(os.path.join("/usr/share/icons", name)):
            continue
        chain.append(name)
        if os.path.isfile(index):
            for line in open(index, encoding="utf-8", errors="replace"):
                if line.startswith("Inherits="):
                    queue += [part.strip() for part in line.split("=", 1)[1].split(",") if part.strip()]
    if "hicolor" not in chain:
        chain.append("hicolor")
    return chain


def size_of(path):
    if "/scalable/" in path or path.endswith(".svg"):
        return 10_000
    match = re.search(r"/(\d+)x\d+(@\d+)?/", path)
    return int(match.group(1)) if match else 0


def resolve_icon(name, chain):
    if not name:
        return None
    if name.startswith("/"):
        return name if os.path.isfile(name) else None
    for theme in chain:
        root = os.path.join("/usr/share/icons", theme)
        found = []
        for directory, _, files in os.walk(root):
            for ext in (".svg", ".png"):
                if name + ext in files:
                    found.append(os.path.join(directory, name + ext))
        apps = [p for p in found if "/apps/" in p] or found
        if apps:
            return max(apps, key=size_of)
    for ext in (".svg", ".png"):
        path = os.path.join("/usr/share/pixmaps", name + ext)
        if os.path.isfile(path):
            return path
    return None


def sha256(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def main():
    os.makedirs(STAGED, exist_ok=True)
    theme = icon_theme()
    chain = theme_chain(theme)
    apps, icon_map, sources, pinned = [], {}, [], []
    for role, candidates in ROLES:
        chosen = next(((app_id, find_entry(app_id)) for app_id in candidates if find_entry(app_id)), None)
        if not chosen:
            sources.append({"role": role, "installed": False, "candidates": candidates})
            continue
        app_id, entry = chosen
        name, icon = read_entry(entry)
        resolved = resolve_icon(icon, chain)
        apps.append({"app_id": app_id, "name": name, "icon": icon if resolved else "",
                     "generic_name": None, "categories": [], "keywords": []})
        if resolved:
            icon_map[icon] = "file://" + resolved
        pinned.append(app_id)
        sources.append({"role": role, "installed": True, "app_id": app_id, "desktop_entry": entry,
                        "desktop_entry_sha256": sha256(entry), "icon_name": icon,
                        "icon_file": resolved, "icon_sha256": sha256(resolved) if resolved else None})
    status_names = [
        "audio-card-symbolic", "audio-volume-muted-symbolic", "audio-volume-low-symbolic",
        "audio-volume-medium-symbolic", "audio-volume-high-symbolic", "network-error-symbolic",
        "network-idle-symbolic", "network-wireless-offline-symbolic", "network-wireless-signal-excellent-symbolic",
    ]
    status_sources = []
    for name in status_names:
        resolved = resolve_icon(name, chain)
        if resolved:
            icon_map[name] = "file://" + resolved
        status_sources.append({"icon_name": name, "icon_file": resolved,
                               "icon_sha256": sha256(resolved) if resolved else None})
    # Pin the N1 regression to real installed Yaru SVGs even when the active
    # desktop theme differs. These are test inputs, not bundled product icons.
    yaru_map, yaru_sources = {}, []
    for name in status_names:
        resolved = resolve_icon(name, ["Yaru"])
        if resolved:
            yaru_map[name] = "file://" + resolved
        yaru_sources.append({"icon_name": name, "icon_file": resolved,
                             "icon_sha256": sha256(resolved) if resolved else None})
    with open(os.path.join(STAGED, "capture-data.js"), "w", encoding="utf-8") as out:
        out.write(".pragma library\n")
        out.write("var apps = " + json.dumps(apps, ensure_ascii=False) + ";\n")
        out.write("var iconMap = " + json.dumps(icon_map) + ";\n")
        out.write("var yaruIconMap = " + json.dumps(yaru_map) + ";\n")
        out.write("var pinned = " + json.dumps(pinned) + ";\n")
    with open(os.path.join(STAGED, "capture-sources.json"), "w", encoding="utf-8") as out:
        json.dump({"icon_theme": theme, "theme_chain": chain, "roles": sources, "status_icons": status_sources, "yaru_test_icons": yaru_sources}, out, ensure_ascii=False, indent=2)
        out.write("\n")
    for source in sources:
        if source["installed"]:
            print(f"{source['role']:9s} {source['app_id']:28s} icon={source['icon_file'] or '(fallback)'}")
        else:
            print(f"{source['role']:9s} (not installed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
