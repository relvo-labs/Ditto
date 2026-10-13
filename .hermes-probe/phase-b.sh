#!/usr/bin/env bash
# G2 EX2-14 on the reference machine: temporary GDM autologin, 4 states x 3
# cold logins, then the GDM configuration restored byte-identical and the
# machine left at the login screen. Temporary (not for merge).
set -uo pipefail
st=$HOME/.local/state/ditto-g2-exit; mkdir -p "$st"; ts=$(date -u +%Y%m%dT%H%M%SZ)
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$st/phase-b.log"; }
cd ~/funlab/Ditto
log "phase-b start at $(git rev-parse HEAD) dirty=$(git status --porcelain | wc -l)"
cargo build --locked --release -p ditto-measure 2>&1 | tail -1
sudo -n cp -p /etc/gdm3/custom.conf "$st/custom.conf.orig-$ts"
sudo -n cp -p /etc/gdm3/custom.conf /etc/gdm3/custom.conf.g2-exit-$ts
sha=$(sha256sum /etc/gdm3/custom.conf | cut -d' ' -f1); log "custom.conf sha256 $sha"
restore() {
  sudo -n cp -p "$st/custom.conf.orig-$ts" /etc/gdm3/custom.conf
  if [[ "$(sha256sum /etc/gdm3/custom.conf | cut -d' ' -f1)" == "$sha" ]]; then log "gdm custom.conf restored byte-identical ($sha)"; else log "RESTORE MISMATCH"; fi
  log "relogin to the login screen"; sudo -n /usr/local/libexec/ditto-relogin >>"$st/phase-b.log" 2>&1
  log "phase-b done"
}
trap restore EXIT
sudo -n python3 -c "
p='/etc/gdm3/custom.conf'; s=open(p).read()
assert 'AutomaticLoginEnable=True' not in s
s=s.replace('[daemon]\n','[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=neil\n',1)
open(p,'w').write(s)"
log "autologin enabled"
# series.sh refuses a shell of the Ditto login it restarts; this job's runner
# is a user service outside every login, but the user manager's environment
# carries the last login's variables.
env -u WAYLAND_DISPLAY -u XDG_SESSION_DESKTOP -u DISPLAY \
  DITTO_ARTIFACTS="$PWD/artifacts/g2-ref-exit" DITTO_SERIES_FINAL_RELOGIN=0 DITTO_LOGIN_TIMEOUT_SECONDS=600 \
  bash tests/g1/measure/series.sh rescue_no_node desktop_full_no_agent desktop_full_agent_warm desktop_full_agent_active
log "series exit $?"
