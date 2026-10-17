#!/usr/bin/env bash
# Dedicated test binary; normal Core and OS policy, three fixed source faults.
set -euo pipefail
cd "$(dirname "$0")/../../.."
cargo build --locked -p ditto-core -p ditto-confine -p ditto-test-host
bash tools/generation-host/build.sh
mkdir -p artifacts/g3
fixture="$(mktemp -d "$PWD/artifacts/g3/fixed-pipeline-XXXXXX")"
mkdir -m 0700 "$fixture/bin"
cp target/debug/{ditto-core,ditto-worker,ditto-confine,ditto-generation-host,ditto-generation-runner,ditto-generation-runner.json} "$fixture/bin/"
cargo build --locked -p ditto-test-host --bin ditto-generation-host --features fault-injection --target-dir "$fixture/build"
cp "$fixture/build/debug/ditto-generation-host" "$fixture/bin/ditto-generation-host"
if scripts/check-release-fault-points.sh "$fixture/bin/ditto-generation-host"; then exit 1; fi
DITTO_BINARIES="$fixture/bin" DITTO_G3_FIXED_FAILURES=1 node tests/g3/integration/run.mjs
