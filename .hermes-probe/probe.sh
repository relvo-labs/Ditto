#!/usr/bin/env bash
set +e
cd ~/funlab/Ditto
r() { timeout 30 python3 tests/g1/lib/gui.py relay "$1" "${2:-{\}}" 2>&1; }
echo "== sessions"; loginctl list-sessions --no-legend
echo "== ditto units"; systemctl --user list-units --plain --no-legend 'ditto-*' | cut -c1-120
source <(sed -n '/^d34_packages()/,/^}/p;/^d34_entries()/,/^}/p' tests/g1/measure/cold-login.sh)
relay_call() { r "$@"; }
workspace=$PWD
echo "== d34 entries"; d34_entries
head=$(r desktop.profiles.get '{}' | jq -r .result.profile.head_revision); echo "head=$head"
mapfile -t entries < <(d34_entries)
if (( ${#entries[@]} )); then
  echo "== dry propose (preflight only?)"
  r desktop.changes.propose "$(jq -cn --arg base "$head" '{base_revision:$base, dry_run:true, ops:($ARGS.positional|map({op:"remove_entry",entry_id:.}))}' --args "${entries[@]}")" | head -c 3000; echo
fi
echo "== last changes"; r desktop.changes.list '{"limit":3}' | jq -c '.result.changes[]|{change_id,state,reasons,created_at}' 2>&1 | head -c 3000
echo "== entries summary"; r desktop.profiles.get '{}' | jq -c '.result.document.entries[]|[.package,.version,.disabled]' | sort | uniq -c
