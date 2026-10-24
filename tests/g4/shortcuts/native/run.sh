#!/usr/bin/env bash
# Isolated real compositor evidence; never connects to the caller's display.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
evidence="${1:?usage: run.sh evidence-dir work-dir image-sha256}"
work="${2:?task-owned work directory required}"
image="${3:?prebuilt probe image SHA required; see README}"
[[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'An immutable image id is required' >&2; exit 2; }
available_kib="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
(( available_kib > 10485760 )) || { echo 'BLOCKED: host available memory <=10 GiB' >&2; exit 2; }
mkdir -p "$evidence/logs" "$work/shell/i18n"
evidence="$(cd "$evidence" && pwd)"
work="$(cd "$work" && pwd)"
cp "$root"/tests/g4/shortcuts/native/{Probe.qml,RecorderProbe.qml,wayfire.ini,safety_probe.py,recorder_probe.py} "$work/"
cp "$root/tools/compositor-probe/g1/wfipc.py" "$work/"
for directory in ui jelly change; do
    mkdir -p "$work/shell/$directory"
    cp -a "$root/shell/$directory/." "$work/shell/$directory/"
done
cp "$root/shell/i18n/ditto_en.json" "$work/shell/i18n/"
python3 - "$work" "$evidence" <<'PY'
import hashlib, json, sys
from pathlib import Path
work, evidence = map(Path, sys.argv[1:])
rows = [{"file": str(p.relative_to(work)), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
        for p in sorted(work.rglob('*')) if p.is_file() and p.suffix != '.qmlc']
(evidence / 'native-sources.json').write_text(json.dumps(rows, indent=2) + '\n')
PY
qs_lib="${DITTO_QS_LD_LIBRARY_PATH:?source the pinned runner environment}"
qs_lib="${qs_lib%%:*}"
container="ditto-shortcut-probe-190-replay-$$"
trap 'docker rm -f "$container" >/dev/null 2>&1 || true' EXIT
for probe in safety_probe recorder_probe; do
    timeout -k 5 70 docker run --rm --name "$container" \
        --cpus 2 --memory 4g --pids-limit 512 --network none \
        --cap-drop ALL --security-opt no-new-privileges --ulimit core=0:0 \
        --user "$(id -u):$(id -g)" --entrypoint python3 \
        --mount "type=bind,src=$work,dst=/work,readonly" \
        --mount "type=bind,src=$evidence,dst=/evidence" \
        --mount "type=bind,src=${QT_PREFIX:?},dst=/opt/qt,readonly" \
        --mount "type=bind,src=$qs_lib,dst=/opt/qs-lib,readonly" \
        "$image" "/work/$probe.py" > "$evidence/logs/$probe.log" 2>&1
done
printf 'native probes: safety + recorder passed; virtual keyboard, no Core save\n'
