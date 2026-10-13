#!/usr/bin/env bash
set +e
cd ~/funlab/Ditto
r() { timeout 60 python3 tests/g1/lib/gui.py relay "$1" "${2:-{\}}" 2>&1; }
echo "== sessions"; loginctl list-sessions --no-legend
head=$(r desktop.profiles.get | jq -r .result.profile.head_revision); echo "head=$head"
echo "== upgrade raw"; r desktop.profiles.upgrade "$(jq -cn --arg b "$head" '{base_revision:$b, idempotency_key:"g2-exit-upgrade-2026-10-13"}')" | head -c 3000; echo
echo "== caps"; r desktop.capabilities.list | jq -c '[.result.capabilities[]?|select(.id|test("profiles"))|.id]' 2>&1 | head -c 800
