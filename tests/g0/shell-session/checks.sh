#!/usr/bin/env bash
# Helpers shared by the session fixture and its seat-free regression.

session_handoff_dir() {
  mktemp -d "$1/ditto-shell-session-pin.XXXXXX"
}

wait_session_mask() {
  local log="$1" floor="$2" _
  for _ in $(seq 1 "${3:-150}"); do
    # Consume the entire file (no grep -q / SIGPIPE), ignoring startup lines.
    awk -v floor="$floor" '
      NR > floor && /hit mask rectangles=24([^0-9]|$)/ { found=1 }
      END { exit !found }
    ' "$log" && return 0
    sleep 0.1
  done
  tail -40 "$log" >&2
  echo 'check 1 failed: no new legacy hit mask (24 rectangles) after pin began' >&2
  return 1
}

require_session_survival() {
  local log="$1" floor="$2" stopped_at="$3" pid="$4"
  kill -0 "$pid" 2>/dev/null || {
    echo 'check 5 failed: the shell died with the desktop service' >&2
    return 1
  }
  # FrameProbe exists only on the legacy surface. Both the line offset and
  # its QML timestamp must postdate Core exit, excluding buffered old frames.
  # Require continuing frames after a 2 s settling period, rather than just
  # the one-off redraw that can accompany the disconnect notification.
  awk -v floor="$floor" -v stopped_at="$stopped_at" '
    NR > floor {
      for (i=1; i<=NF-2; i++) {
        if ($i == "ditto-frame" && $(i+1) ~ /^[0-9]+$/ &&
            $(i+2) ~ /^[0-9]+$/ && $(i+1)+0 > stopped_at+2000 && $(i+2)+0 > 0) found++
      }
    }
    END { exit !(found >= 2) }
  ' "$log" && return 0
  tail -40 "$log" >&2
  echo 'check 5 failed: no continuing legacy character frames 2 s after Core exited' >&2
  return 1
}
