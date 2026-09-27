#!/usr/bin/env bash
# Vendor guard (plan/03/03 §12, EX1-14 ③), after the harness script of the same
# name: a change under packages/host-runtime/vendor/*/src/ must come with a
# change to packages/host-runtime/vendor/README.md, whose modification log is
# the record of every divergence from upstream.
#
# usage:
#   scripts/check-vendor-manifest.sh                 commits on HEAD since the merge base with origin/main
#   scripts/check-vendor-manifest.sh --base <ref>    …since the merge base with <ref>
#   scripts/check-vendor-manifest.sh --staged        the index only (pre-commit)
#   scripts/check-vendor-manifest.sh --working       the base diff plus staged, unstaged and untracked files
#   scripts/check-vendor-manifest.sh --self-test     prove the guard blocks and passes in a scratch repository
#   --repo <dir>                                     run against another checkout (used by the self-test)
set -euo pipefail

base="origin/main"
mode="commits"
repo="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --staged) mode="staged"; shift ;;
    --working) mode="working"; shift ;;
    --repo) repo="$2"; shift 2 ;;
    --self-test) mode="self-test"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

vendor_src='^packages/host-runtime/vendor/[^/]+/src/'
manifest='packages/host-runtime/vendor/README.md'

if [[ "$mode" == "self-test" ]]; then
  self="$(readlink -f "$0")"
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  git -C "$scratch" init -q -b main
  git -C "$scratch" config user.email guard@test.invalid
  git -C "$scratch" config user.name guard
  mkdir -p "$scratch/packages/host-runtime/vendor/cordis/src"
  echo 'export const a = 1' > "$scratch/packages/host-runtime/vendor/cordis/src/index.ts"
  echo '# log' > "$scratch/$manifest"
  git -C "$scratch" add -A && git -C "$scratch" commit -qm base
  git -C "$scratch" switch -qc change
  echo 'export const a = 2' > "$scratch/packages/host-runtime/vendor/cordis/src/index.ts"
  git -C "$scratch" commit -qam 'vendor edit without log'
  if "$self" --repo "$scratch" --base main >/dev/null 2>&1; then
    echo 'self-test FAILED: a vendored source change without a README change was not blocked' >&2
    exit 1
  fi
  echo 'self-test: blocked a vendored source change without a README change'
  echo 'D1. …' >> "$scratch/$manifest"
  git -C "$scratch" commit -qam 'log it'
  "$self" --repo "$scratch" --base main >/dev/null
  echo 'self-test: passed once the README change came with it'
  echo 'export const a = 3' > "$scratch/packages/host-runtime/vendor/cordis/src/index.ts"
  git -C "$scratch" add -A
  if "$self" --repo "$scratch" --staged >/dev/null 2>&1; then
    echo 'self-test FAILED: a staged vendored source change without a README change was not blocked' >&2
    exit 1
  fi
  echo 'self-test: blocked a staged vendored source change without a README change'
  exit 0
fi

cd "$repo"
case "$mode" in
  staged)
    changed=$(git diff --cached --name-only)
    ;;
  commits|working)
    if ! git rev-parse --verify --quiet "$base" >/dev/null; then
      echo "vendor manifest guard: base ref $base not found (fetch it or pass --base)" >&2
      exit 2
    fi
    changed=$(git diff --name-only "$(git merge-base "$base" HEAD)" HEAD)
    if [[ "$mode" == "working" ]]; then
      changed=$(printf '%s\n%s\n%s\n%s\n' "$changed" "$(git diff --cached --name-only)" "$(git diff --name-only)" \
        "$(git ls-files --others --exclude-standard)")
    fi
    ;;
esac

vendor_changed=$(echo "$changed" | grep -E "$vendor_src" | sort -u || true)
manifest_changed=$(echo "$changed" | grep -Fx "$manifest" || true)

if [[ -n "$vendor_changed" && -z "$manifest_changed" ]]; then
  echo 'vendor manifest guard: vendored SOURCE changed without updating packages/host-runtime/vendor/README.md:'
  echo "$vendor_changed" | sed 's/^/  /'
  echo 'Record the change in the "Ditto 修改集" (or the lock table for a sync) and include it in the same change.'
  exit 1
fi
echo "vendor manifest guard: ok ($(echo "$vendor_changed" | grep -c . || true) vendored source file(s) changed)"
