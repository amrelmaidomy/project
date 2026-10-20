#!/usr/bin/env python3
"""Run the API with the model paths prepared on this machine."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG_KEYS = {
    "MA3AK_MODELS_DIR",
    "WHISPER_MODEL",
    "WHISPER_DEVICE",
    "WHISPER_COMPUTE_TYPE",
    "TTS_MODEL_PATH",
    "TTS_VOCAB_PATH",
    "TTS_VOCODER_PATH",
    "TTS_PYTHON",
    "TTS_DEVICE",
    "TTS_REFERENCE_AUDIO",
    "TTS_REFERENCE_TEXT",
    "TTS_NFE_STEPS",
    "TTS_CPU_THREADS",
    "TTS_TIMEOUT_SECONDS",
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=int(os.getenv("PORT", "8000")))
    args = parser.parse_args()
    config_path = ROOT / ".local" / "model-config.json"
    if config_path.exists():
        config = json.loads(config_path.read_text(encoding="utf-8-sig"))
        if not isinstance(config, dict):
            raise SystemExit("Invalid .local/model-config.json; run model setup again.")
        for key, value in config.items():
            if key in CONFIG_KEYS and isinstance(value, str):
                # Explicit shell overrides take precedence over saved defaults.
                os.environ.setdefault(key, value)
    else:
        print(
            "No saved model config; using environment defaults. See docs/model-setup.md."
        )
    sys.path.insert(0, str(ROOT / "backend"))
    import uvicorn

    uvicorn.run("main:app", host=args.host, port=args.port)


if __name__ == "__main__":
    main()
