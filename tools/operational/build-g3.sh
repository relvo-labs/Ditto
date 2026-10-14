#!/usr/bin/env bash
# Called only inside the new pinned task checkout. Offline; no global installer.
set -euo pipefail
[[ $(git rev-parse HEAD) == 17f5d76dc043d7d8117f1e99458a9a0c9255354b ]]
[[ -z $(git status --porcelain) ]]
[[ $(node --version) == v22.23.2 && $(pnpm --version) == 10.11.0 ]]
export CARGO_NET_OFFLINE=true
export CARGO_BUILD_JOBS=2
export CARGO_TARGET_DIR="$PWD/target"
export npm_config_offline=true
export COREPACK_ENABLE_NETWORK=0
cargo build --offline --locked --release -p ditto-core -p ditto-supervisor -p dittoctl -p ditto-confine -p ditto-test-host
bash tools/generation-host/build.sh release
cargo build --offline --locked -p ditto-test-host --bin ditto-generation-host --features fault-injection --target-dir target/g3-fault-fixtures
# Use upstream source cache only; never reuse the installed executable/build.
proxy_cache=/home/neil/funlab/Ditto/target/dbus-proxy-src
proxy_commit=72b40c8f6d9d585cfbdb249690724f740d207087
[[ $(git -C "$proxy_cache" rev-parse HEAD) == "$proxy_commit" ]]
git clone --no-hardlinks --no-checkout "$proxy_cache" target/dbus-proxy-src
git -C target/dbus-proxy-src checkout --detach "$proxy_commit"
bash tools/dbus-proxy/build.sh release
pnpm install --offline --frozen-lockfile
pnpm --filter @ditto/host-runtime build
pnpm --filter @ditto/agent-runtime build
# Match the verification-relay selection in install-session.sh, including
# only crashes_host and the D-34 QML/Cordis fixtures (no stress bundles).
bash scripts/build-builtin-packages.sh target/ditto-packages
mkdir target/ditto-packages-verification
cp target/ditto-packages/*.dittopkg target/ditto-packages-verification/
pnpm --filter @ditto/plugin-fixtures build
packages/host-sdk/bin/ditto-plugin pack packages/plugin-fixtures/faults/crashes_host --out target/ditto-packages-verification/ditto.fixture.fault_crashes_host-1.0.0.dittopkg --no-handlers
node packages/host-sdk/scripts/pack-each.mjs packages/plugin-fixtures/qml/* packages/plugin-fixtures/cordis/* --out target/ditto-packages-verification
[[ -z $(git status --porcelain) ]]
