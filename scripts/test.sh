#!/bin/sh
# Run every standalone smoke test with an isolated Neovim configuration.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
if [ -z "${OBSIDIAN_EMBEDS_RTP:-}" ]; then
  echo 'Set OBSIDIAN_EMBEDS_RTP to absolute, colon-separated Obsidian, Plenary and parser runtime paths.' >&2
  exit 2
fi
nvim=${NVIM_BIN:-nvim}
test_home=$(mktemp -d "${TMPDIR:-/tmp}/obsidian-embed-tests.XXXXXX")
trap 'rm -rf "$test_home"' EXIT HUP INT TERM
export HOME="$test_home/home"
export XDG_CONFIG_HOME="$test_home/config"
export XDG_DATA_HOME="$test_home/data"
export XDG_STATE_HOME="$test_home/state"
export XDG_CACHE_HOME="$test_home/cache"
export XDG_RUNTIME_DIR="$test_home/runtime"
export NVIM_LOG_FILE="$test_home/nvim.log"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
cd "$root"

if rg -n 'resolve_note_async|Note\.from_file|obsidian\.note"\)\.from_file|obsidian_embeds\.tracker|set_workspace_root|obsidian\.workspace"\)\.set' \
  "$root/lua/obsidian-embed" --glob '*.lua'; then
  echo 'forbidden synchronous resolver boundary found' >&2
  exit 1
fi
if rg -n 'command\.type|command\(out' \
  "$root/lua/obsidian-embed/runtime.lua" "$root/lua/obsidian-embed/machine.lua"; then
  echo 'removed command protocol regressed' >&2
  exit 1
fi
if rg -n 'session\.[A-Za-z_][A-Za-z0-9_]*\s*=[^=]' "$root/lua/obsidian-embed/runtime.lua"; then
  echo 'runtime mutated semantic state owned by the machine' >&2
  exit 1
fi

"$nvim" --headless -u NONE -i NONE -l "$root/scripts/check-test-runtime.lua"
count=0
for test in "$root"/tests/*-smoke.lua; do
  printf '\nRunning %s\n' "${test##*/}"
  "$nvim" --headless -u NONE -i NONE -l "$test"
  count=$((count + 1))
done
printf '\nPassed %s standalone smoke tests.\n' "$count"
