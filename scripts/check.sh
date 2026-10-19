#!/usr/bin/env bash
set -euo pipefail
MA3AK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -d /workspace/.tooling/flutter ]]; then
  source "$MA3AK_ROOT/scripts/cloud_env.sh"
fi
cd "$MA3AK_ROOT/backend"
uv run --frozen pytest
uv run --frozen ruff check .
cd "$MA3AK_ROOT/mobile"
flutter pub get --enforce-lockfile
flutter --suppress-analytics analyze --no-pub
flutter test --no-pub --reporter expanded
