#!/usr/bin/env bash
# Reproduce the immutable package artifact that blocked subsequent checkouts.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
fixture="$(mktemp -d)"
cleanup() { chmod -R u+rwX "$fixture"; rm -rf "$fixture"; }
trap cleanup EXIT
mkdir -p "$fixture/source/packages/sha256/bundle"
printf '%s\n' '{"immutable":"evidence"}' >"$fixture/source/packages/sha256/bundle/manifest.json"
chmod 400 "$fixture/source/packages/sha256/bundle/manifest.json"
chmod 500 "$fixture/source/packages/sha256/bundle"
# Exercise the production collector with a local transport, without a VM.
vm_rsync() { rsync -a "$@"; }
vm_collect_artifacts "$fixture/source/" "$fixture/copy/"
cmp "$fixture/source/packages/sha256/bundle/manifest.json" "$fixture/copy/packages/sha256/bundle/manifest.json"
[[ "$(stat -c %a "$fixture/source/packages/sha256/bundle")" == 500 ]]
[[ "$(stat -c %a "$fixture/source/packages/sha256/bundle/manifest.json")" == 400 ]]
[[ "$(stat -c %a "$fixture/copy/packages/sha256/bundle")" == 700 ]]
[[ "$(stat -c %a "$fixture/copy/packages/sha256/bundle/manifest.json")" == 600 ]]
# Match checkout's recursive deletion without a permission-repair step.
rm -rf "$fixture/copy"
[[ ! -e "$fixture/copy" ]]
echo 'PASS immutable VM evidence is unchanged in the guest and removable in CI'
