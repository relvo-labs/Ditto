#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
pnpm --filter @ditto/host-runtime build
pnpm --filter @ditto/agent-runtime build
bash scripts/build-builtin-packages.sh target/ditto-packages
