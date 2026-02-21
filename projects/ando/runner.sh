#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_NAME="ando"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required but was not found in PATH" >&2
  exit 1
fi

if tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
  tmux kill-session -t "${SESSION_NAME}"
fi

CMD="cd \"${SCRIPT_DIR}\" && julia --startup-file=no --project=. -e \"using Pkg; Pkg.instantiate()\" && exec julia --startup-file=no --project=. runner.jl"
tmux new-session -d -s "${SESSION_NAME}" "zsh -lc '${CMD}'"

echo "Started tmux session '${SESSION_NAME}'"
echo "Attach with: tmux attach -t ${SESSION_NAME}"
