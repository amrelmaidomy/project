#!/usr/bin/env bash
set -euo pipefail
MA3AK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -d /workspace/.tooling/flutter ]]; then
  source "$MA3AK_ROOT/scripts/cloud_env.sh"
fi
cd "$MA3AK_ROOT/backend"
exec uv run --frozen python "$MA3AK_ROOT/scripts/run_backend.py" --host 0.0.0.0 --port "${PORT:-8000}"
