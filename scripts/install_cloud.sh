#!/usr/bin/env bash
set -euo pipefail
MA3AK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MA3AK_ROOT/scripts/cloud_env.sh"
mkdir -p "$MA3AK_TOOLING" "$PUB_CACHE" "$GRADLE_USER_HOME" "$ANDROID_USER_HOME"

MA3AK_FLUTTER_COMMIT=adc901062556672b4138e18a4dc62a4be8f4b3c2
if [[ ! -d "$MA3AK_TOOLING/flutter" ]]; then
  git clone --depth 1 --branch 3.35.7 https://github.com/flutter/flutter.git "$MA3AK_TOOLING/flutter"
fi
if [[ "$(git -C "$MA3AK_TOOLING/flutter" rev-parse HEAD)" != "$MA3AK_FLUTTER_COMMIT" ]]; then
  printf '%s\n' 'Existing cloud Flutter SDK differs from pinned 3.35.7; choose a separate MA3AK_TOOLING path.' >&2
  exit 1
fi
flutter --suppress-analytics --version

bash "$MA3AK_ROOT/scripts/install_jdk.sh"
source "$MA3AK_ROOT/scripts/cloud_env.sh"

# Java does not use HTTPS_PROXY automatically. Preserve unrelated local settings
# and add only missing non-secret host/port proxy fields.
python3 - <<'PY'
from pathlib import Path
from urllib.parse import urlsplit
import os

proxy = urlsplit(os.environ.get('HTTPS_PROXY') or os.environ.get('https_proxy') or '')
if proxy.hostname:
    properties = Path(os.environ['GRADLE_USER_HOME']) / 'gradle.properties'
    current = properties.read_text() if properties.exists() else ''
    existing = {line.partition('=')[0].strip() for line in current.splitlines()}
    settings = {
        'systemProp.http.proxyHost': proxy.hostname,
        'systemProp.http.proxyPort': str(proxy.port or 80),
        'systemProp.https.proxyHost': proxy.hostname,
        'systemProp.https.proxyPort': str(proxy.port or 80),
    }
    missing = [f'{key}={value}' for key, value in settings.items() if key not in existing]
    if missing:
        with properties.open('a') as output:
            output.write('\n# Cloud proxy host/port; no credentials.\n' + '\n'.join(missing) + '\n')
PY

bash "$MA3AK_ROOT/scripts/install_android_sdk.sh"
flutter --suppress-analytics config --android-sdk "$ANDROID_HOME"
flutter --suppress-analytics precache --android

# Flutter's Linux SQLite tests load libsqlite3.so; this image supplies the ABI
# compatible libsqlite3.so.0. Android uses the packaged SQLite native library.
if [[ ! -e "$MA3AK_TOOLING/lib/libsqlite3.so" ]] && command -v ldconfig >/dev/null; then
  MA3AK_SQLITE_LIBRARY="$(ldconfig -p | awk '$1 == "libsqlite3.so.0" { print $NF; exit }')"
  if [[ -n "$MA3AK_SQLITE_LIBRARY" ]]; then
    mkdir -p "$MA3AK_TOOLING/lib"
    ln -s "$MA3AK_SQLITE_LIBRARY" "$MA3AK_TOOLING/lib/libsqlite3.so"
  fi
fi

cd "$MA3AK_ROOT/backend"
uv sync --frozen --group dev
uv sync --frozen --project "$MA3AK_ROOT/backend/tts_runtime" --python 3.12
uv run --frozen python "$MA3AK_ROOT/scripts/prepare-models.py" --models-dir "${MA3AK_MODELS_DIR:-/workspace/shared/Ma3akModels}"
cd "$MA3AK_ROOT/mobile"
flutter --suppress-analytics pub get --enforce-lockfile
if [[ ! -f "$MA3AK_ROOT/mobile/android/app/src/main/assets/wakeword/models.json" ]]; then
  # Optional, clearly labeled English integration demo. Never replace a custom
  # Arabic model manifest already installed by the user.
  python3 "$MA3AK_ROOT/scripts/fetch_wake_models.py" --demo
fi
printf '%s\n' 'Setup complete. Run bash scripts/check.sh from the repository root.'
