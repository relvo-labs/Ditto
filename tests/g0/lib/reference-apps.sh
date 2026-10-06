#!/usr/bin/env bash
# Frozen G0 reference applications. Reference-machine runs must use all three
# roles; development runs may keep using their smaller fixtures.

reference_app_id() {
  case "$1" in
    browser) echo firefox_firefox ;;
    terminal) echo ditto-ref-terminal ;;
    editor) echo org.kde.kate ;;
    *) echo "unknown reference application role: $1" >&2; return 2 ;;
  esac
}

start_reference_app() {
  local role="$1" app_id
  app_id="$(reference_app_id "$role")"
  case "$role" in
    browser)
      firefox_profile="$HOME/snap/firefox/common/ditto-g0-reference-profile"
      mkdir -p "$firefox_profile"
      # Firefox restores the last window state from xulstore.json. The matrix
      # ends by maximizing it, so without this the next run starts maximized
      # and move/resize answer `unsupported` (nightly 36302494395).
      rm -f -- "$firefox_profile/xulstore.json"
      # Firefox 156.0.1 routes Wayland through its own in-process proxy; under
      # the headless fixture compositor that proxy never maps a toplevel. The
      # direct connection is the same xdg-toplevel path the matrix measures.
      MOZ_ENABLE_WAYLAND=1 MOZ_DISABLE_WAYLAND_PROXY=1 firefox --no-remote --profile "$firefox_profile" \
        about:blank >"$RUNTIME_DIR/firefox.log" 2>&1 &
      ;;
    terminal)
      foot --app-id="$app_id" sh -c 'sleep infinity' \
        >"$RUNTIME_DIR/foot.log" 2>&1 &
      ;;
    editor)
      QT_QPA_PLATFORM=wayland kate --new >"$RUNTIME_DIR/kate.log" 2>&1 &
      ;;
  esac
  local pid=$!
  WINDOW_PIDS+=("$pid")
  # The Firefox snap asks the settings portal before its first window. With
  # no desktop login at the seat no portal backend can start, and GDBus gives
  # up after about 25 s (nightly 37472287369); the window then maps normally.
  local tries=100
  [[ "$role" == browser ]] && tries=600
  if ! compositor_wait_for_window "$app_id" "$tries"; then
    case "$role" in
      browser) cat "$RUNTIME_DIR/firefox.log" 2>/dev/null || true ;;
      terminal) cat "$RUNTIME_DIR/foot.log" 2>/dev/null || true ;;
      editor) cat "$RUNTIME_DIR/kate.log" 2>/dev/null || true ;;
    esac
    echo "$role ($app_id) did not map as a native Wayland window" >&2
    return 1
  fi
  local mapped_pid
  mapped_pid="$(compositor_window_pid "$app_id")"
  [[ "$mapped_pid" =~ ^[0-9]+$ ]] || { echo "could not resolve mapped PID for $role" >&2; return 1; }
  [[ "$mapped_pid" == "$pid" ]] || WINDOW_PIDS+=("$mapped_pid")
  REFERENCE_APP_ROLES+=("$role")
  REFERENCE_APP_IDS+=("$app_id")
  REFERENCE_APP_PIDS+=("$mapped_pid")
}

start_all_reference_apps() {
  REFERENCE_APP_ROLES=()
  REFERENCE_APP_IDS=()
  REFERENCE_APP_PIDS=()
  start_reference_app browser
  start_reference_app terminal
  start_reference_app editor
}

kate_service() {
  qdbus | awk '/org\.kde\.kate-[0-9]+/{print $1; exit}'
}

kate_open_unsaved() {
  local content="$1" service
  service="$(kate_service)"
  [[ -n "$service" ]] || { echo 'Kate D-Bus service did not appear' >&2; return 1; }
  [[ "$(qdbus "$service" /MainApplication org.kde.Kate.Application.openInput "$content" UTF-8)" == true ]]
}

wayfire_key() {
  local key="$1" state="$2"
  wayfire_ipc stipc/feed_key "{\"key\":\"$key\",\"state\":$state}" >/dev/null
}

wayfire_shortcut() {
  local key="$1"
  wayfire_key KEY_LEFTCTRL true
  wayfire_key "$key" true
  wayfire_key "$key" false
  wayfire_key KEY_LEFTCTRL false
}

kate_unsaved_hash() {
  compositor_focus_window "$(reference_app_id editor)"
  wayfire_shortcut KEY_A
  wayfire_shortcut KEY_C
  timeout 5 wl-paste --no-newline | sha256sum | awk '{print $1}'
}
