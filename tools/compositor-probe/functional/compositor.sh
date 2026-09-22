#!/usr/bin/env bash
# Compositor-neutral queries for the functional probe.
#
# The probe asks every compositor the same questions; each backend answers
# through whatever IPC it has. Two rules keep the answers comparable:
# a backend that cannot answer a question prints nothing, so the caller reports
# "not probed" instead of inventing a verdict; and no backend normalises its
# model into another one's shape, because the differences between them are what
# the compositor decision is made from.
#
# Select the backend with DITTO_COMPOSITOR. The default is wayfire, the
# compositor D-02 selected; the sway backend is abandoned and kept only so the
# comparison that decision was made from can be reproduced. Backends are
# expected on PATH; a Wayfire built into a private prefix needs its bin on PATH
# and its lib on LD_LIBRARY_PATH before this is sourced.

DITTO_COMPOSITOR="${DITTO_COMPOSITOR:-wayfire}"
COMPOSITOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

wayfire_ipc() {
  python3 "$COMPOSITOR_LIB_DIR/wayfire-ipc.py" "$@"
}

compositor_label() {
  case "$DITTO_COMPOSITOR" in
    sway) echo "sway-$(sway --version | awk '{print $3}')" ;;
    wayfire) echo "wayfire-$(wayfire --version | awk '{print $1}')" ;;
    *) echo "$DITTO_COMPOSITOR-unknown" ;;
  esac
}

# Wait until exactly one window with this app id is mapped.
compositor_wait_for_window() {
  local app_id="$1"
  local _
  for _ in $(seq 1 100); do
    case "$DITTO_COMPOSITOR" in
      sway)
        swaymsg --raw --type get_tree 2>/dev/null |
          jq -e --arg id "$app_id" '[.. | objects | select(.app_id? == $id)] | length == 1' >/dev/null && return 0
        ;;
      wayfire)
        wayfire_ipc window-rules/list-views 2>/dev/null |
          jq -e --arg id "$app_id" '[.[] | select(."app-id" == $id and .mapped)] | length == 1' >/dev/null && return 0
        ;;
    esac
    sleep 0.1
  done
  return 1
}

# Top edge of the window, in output coordinates.
compositor_window_top() {
  local app_id="$1"
  case "$DITTO_COMPOSITOR" in
    sway)
      swaymsg --raw --type get_tree | jq --arg id "$app_id" 'first(.. | objects | select(.app_id? == $id) | .rect.y)'
      ;;
    wayfire)
      wayfire_ipc window-rules/list-views | jq --arg id "$app_id" 'first(.[] | select(."app-id" == $id) | .geometry.y)'
      ;;
  esac
}

# The window's rectangle, as `{x, y, width, height}`.
compositor_window_rect() {
  local app_id="$1"
  case "$DITTO_COMPOSITOR" in
    sway)
      swaymsg --raw --type get_tree | jq -c --arg id "$app_id" 'first(.. | objects | select(.app_id? == $id) | .rect | {x, y, width, height})'
      ;;
    wayfire)
      wayfire_ipc window-rules/list-views | jq -c --arg id "$app_id" 'first(.[] | select(."app-id" == $id) | .geometry | {x: (.x|floor), y: (.y|floor), width: (.width|floor), height: (.height|floor)})'
      ;;
  esac
}

compositor_focus_window() {
  local app_id="$1"
  case "$DITTO_COMPOSITOR" in
    sway) swaymsg "[app_id=$app_id] focus" >/dev/null ;;
    wayfire)
      local id
      id="$(wayfire_ipc window-rules/list-views | jq -r --arg id "$app_id" 'first(.[] | select(."app-id" == $id) | .id)')"
      [[ -n "$id" && "$id" != "null" ]] || return 1
      wayfire_ipc window-rules/focus-view "{\"id\":$id}" >/dev/null
      ;;
  esac
}

compositor_move_window() {
  local app_id="$1" x="$2" y="$3"
  local rect
  rect="$(compositor_window_rect "$app_id")" || return 1
  compositor_place_window "$app_id" "$x" "$y" \
    "$(jq -r .width <<<"$rect")" "$(jq -r .height <<<"$rect")"
}

# Switch to the nth workspace, counting from 1 in the order the compositor
# presents them. The two models differ (a named list against a grid), so the
# index is translated rather than assumed to be a name.
compositor_switch_workspace() {
  local index="$1"
  case "$DITTO_COMPOSITOR" in
    sway) swaymsg "workspace $index" >/dev/null ;;
    wayfire)
      local output grid_width x y
      output="$(wayfire_ipc window-rules/list-outputs | jq -c '.[0]')"
      grid_width="$(jq -r '.workspace.grid_width' <<<"$output")"
      x=$(((index - 1) % grid_width))
      y=$(((index - 1) / grid_width))
      wayfire_ipc vswitch/set-workspace \
        "{\"x\":$x,\"y\":$y,\"output-id\":$(jq -r .id <<<"$output")}" >/dev/null
      ;;
  esac
}

# Top edge of the area the compositor leaves to applications. Sway does not
# report one, so this prints nothing there and the caller falls back to the
# window position.
compositor_usable_top() {
  case "$DITTO_COMPOSITOR" in
    wayfire) wayfire_ipc window-rules/list-outputs | jq 'first(.[] | .workarea.y)' ;;
    *) : ;;
  esac
}

# The whole area the compositor leaves to applications, as
# `{x, y, width, height}`. Empty where the compositor does not report one.
compositor_usable_rect() {
  case "$DITTO_COMPOSITOR" in
    wayfire)
      wayfire_ipc window-rules/list-outputs |
        jq -c 'first(.[] | .workarea | {x: (.x|floor), y: (.y|floor), width: (.width|floor), height: (.height|floor)})'
      ;;
    *) : ;;
  esac
}

compositor_outputs_json() {
  case "$DITTO_COMPOSITOR" in
    sway)
      swaymsg --raw --type get_outputs | jq -c '{count: length, first: (.[0] | {name, width: .rect.width, height: .rect.height, scale})}'
      ;;
    wayfire)
      # Wayfire's IPC reports output geometry but not scale; the field stays
      # null with the reason rather than being filled from somewhere else.
      wayfire_ipc window-rules/list-outputs |
        jq -c '{count: length,
                first: (.[0] | {name, width: .geometry.width, height: .geometry.height, scale: null}),
                scale_source: "not reported by window-rules/list-outputs"}'
      ;;
  esac
}

# The session id a capability call addresses: the compositor's own id
# namespace, which is why it differs per backend.
compositor_window_id() {
  local app_id="$1"
  case "$DITTO_COMPOSITOR" in
    sway)
      local con_id
      con_id="$(swaymsg --raw --type get_tree | jq -r --arg id "$app_id" 'first(.. | objects | select(.app_id? == $id) | .id)')"
      echo "sway-con-$con_id"
      ;;
    wayfire)
      local view_id
      view_id="$(wayfire_ipc window-rules/list-views | jq -r --arg id "$app_id" 'first(.[] | select(."app-id" == $id) | .id)')"
      echo "wayfire-view-$view_id"
      ;;
  esac
}

# Put a window in the shape that has coordinates. Sway tiles by default and has
# to be told; Wayfire's views are already free-floating unless a tiling plugin
# is loaded, so there is nothing to ask for and nothing is pretended.
compositor_make_floating() {
  local app_id="$1"
  case "$DITTO_COMPOSITOR" in
    sway) swaymsg "[app_id=$app_id] floating enable" >/dev/null ;;
    wayfire) : ;;
  esac
}

# Whether this environment can put a pointer event where the probe wants one.
# Row C-07 cannot be judged without it, and a compositor that cannot do it keeps
# the row unprobed with the reason instead of being given a verdict.
compositor_pointer_injection() {
  case "$DITTO_COMPOSITOR" in
    wayfire)
      if wayfire_ipc stipc/ping >/dev/null 2>&1; then echo yes; else echo no; fi
      ;;
    *) echo no ;;
  esac
}

# Sway can place the cursor but cannot press a button, which is why C-07 stays
# unprobed there: half a click proves nothing about an input region.
compositor_move_cursor() {
  case "$DITTO_COMPOSITOR" in
    wayfire) wayfire_ipc stipc/move_cursor "{\"x\":$1,\"y\":$2}" >/dev/null ;;
    sway) swaymsg seat - cursor set "$1" "$2" >/dev/null 2>&1 || true ;;
    *) return 1 ;;
  esac
}

compositor_click() {
  case "$DITTO_COMPOSITOR" in
    wayfire) wayfire_ipc stipc/feed_button '{"combo":"BTN_LEFT","mode":"full"}' >/dev/null ;;
    *) return 1 ;;
  esac
}

compositor_focused_app_id() {
  case "$DITTO_COMPOSITOR" in
    sway) swaymsg --raw --type get_tree | jq -r 'first(.. | objects | select(.focused? == true) | .app_id // empty)' ;;
    wayfire) wayfire_ipc window-rules/get-focused-view | jq -r '.info."app-id" // empty' ;;
  esac
}

# Put a window where the probe needs it. Only the compositors that give
# coordinates to a window can do this; the caller checks first.
compositor_place_window() {
  local app_id="$1" x="$2" y="$3" width="$4" height="$5"
  case "$DITTO_COMPOSITOR" in
    wayfire)
      local id
      id="$(wayfire_ipc window-rules/list-views | jq -r --arg id "$app_id" 'first(.[] | select(."app-id" == $id) | .id)')"
      [[ -n "$id" && "$id" != "null" ]] || return 1
      wayfire_ipc window-rules/configure-view \
        "{\"id\":$id,\"geometry\":{\"x\":$x,\"y\":$y,\"width\":$width,\"height\":$height}}" >/dev/null
      ;;
    sway)
      swaymsg "[app_id=$app_id] floating enable, move absolute position $x $y, resize set width ${width}px height ${height}px" >/dev/null
      ;;
  esac
}

# Workspace model. The two compositors do not have the same one and this
# deliberately does not hide that: sway has a dynamic named list, Wayfire has a
# fixed grid per workspace set.
compositor_workspaces_json() {
  case "$DITTO_COMPOSITOR" in
    sway)
      swaymsg --raw --type get_workspaces | jq -c '{count: length, model: "named list"}'
      ;;
    wayfire)
      wayfire_ipc window-rules/list-wsets |
        jq -c '{count: ([.[] | .workspace.grid_width * .workspace.grid_height] | add // 0),
                wsets: length,
                grid: (.[0].workspace | {width: .grid_width, height: .grid_height}),
                current: (.[0].workspace | {x, y}),
                model: "fixed grid per workspace set"}'
      ;;
  esac
}
