#!/usr/bin/env python3
"""Prepare only the selected local speech models, with pinned SHA-256 checks.

Run using the backend Python environment; this script does not install packages
or download the Habibi Unified / other dialect checkpoints.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Asset:
    repo: str
    revision: str
    filename: str
    local_name: str
    sha256: str
    size: int


WHISPER = [
    Asset("dropbox-dash/faster-whisper-large-v3-turbo", "0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf", "model.bin", "model.bin", "e76620f83d5f5b69efd3d87e3dc180c1bd21df9fbebacfd4335e5e1efcc018da", 1617884929),
    Asset("dropbox-dash/faster-whisper-large-v3-turbo", "0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf", "config.json", "config.json", "b0253ea6c0d3bea6b1e19e91a02acfd3b53f4467362efcb5a3e6b16c9b3a9b7e", 2263),
    Asset("dropbox-dash/faster-whisper-large-v3-turbo", "0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf", "preprocessor_config.json", "preprocessor_config.json", "7ccc62c6f2765af1f3b46c00c9b5894426835a05021c8b9c01eecb6dfb542711", 340),
    Asset("dropbox-dash/faster-whisper-large-v3-turbo", "0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf", "tokenizer.json", "tokenizer.json", "297b13372ac43916285644fb9687add3cc62ee2a1adb60da3dc25cc94c1871fd", 2710337),
    Asset("dropbox-dash/faster-whisper-large-v3-turbo", "0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf", "vocabulary.json", "vocabulary.json", "c69260f2ab26d659b7c398f9a2b2b48ed0df16c3b47d7326782fd9cba71690c1", 1068114),
]
HABIBI = [
    Asset("SWivid/Habibi-TTS", "3ad11a152851245c002156526c5e1d0b12f2b9d5", "Specialized/EGY/model_100000.safetensors", "model_100000.safetensors", "abfc7b4889e7c365a16b68f606eda210078e4a42e308c5461aba7dd9fe349ee1", 1348855601),
    Asset("SWivid/Habibi-TTS", "3ad11a152851245c002156526c5e1d0b12f2b9d5", "Specialized/EGY/vocab.txt", "vocab.txt", "ceed48f51f0211ffbb8b36007ead3c9b8698fbda9709f184fd712bd3dcd095c5", 11983),
]
VOCOS = [
    Asset("charactr/vocos-mel-24khz", "0feb3fdd929bcd6649e0e7c5a688cf7dd012ef21", "config.yaml", "config.yaml", "da9033922f969a47f0c160010226919e59f27761fd5066f3828d46de6650b0fc", 461),
    Asset("charactr/vocos-mel-24khz", "0feb3fdd929bcd6649e0e7c5a688cf7dd012ef21", "pytorch_model.bin", "pytorch_model.bin", "97ec976ad1fd67a33ab2682d29c0ac7df85234fae875aefcc5fb215681a91b2a", 54365991),
]


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def matches(path: Path, asset: Asset) -> bool:
    return path.is_file() and path.stat().st_size == asset.size and digest(path) == asset.sha256


def prepare(asset: Asset, destination: Path, candidates: list[Path], *, offline: bool, replace: bool) -> None:
    if matches(destination, asset):
        print(f"Verified: {destination}", flush=True)
        return
    if destination.exists():
        if not replace:
            raise RuntimeError(f"Existing file differs from the pinned model: {destination}. Keep it elsewhere or use --replace explicitly.")
        if not destination.is_file():
            raise RuntimeError(f"Expected a file, found a directory: {destination}")
        destination.unlink()
    for candidate in candidates:
        if candidate != destination and matches(candidate, asset):
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(candidate, destination)
            if not matches(destination, asset):
                raise RuntimeError(f"Copied model failed verification: {destination}")
            print(f"Reused existing download: {destination}", flush=True)
            return
    if offline:
        raise RuntimeError(f"Missing pinned model file in offline mode: {destination}")

    from huggingface_hub import hf_hub_download

    destination.parent.mkdir(parents=True, exist_ok=True)
    # A separate staging folder lets a nested HF filename become a simple local
    # file without a second multi-gigabyte cache copy. HF can resume interrupted
    # downloads; an unverified file is never installed as the final asset.
    staging = destination.parent / ".downloads"
    print(f"Downloading {asset.repo}/{asset.filename} ({asset.size / 1e9:.2f} GB)...", flush=True)
    downloaded = Path(hf_hub_download(
        repo_id=asset.repo,
        filename=asset.filename,
        revision=asset.revision,
        local_dir=str(staging),
    ))
    if not matches(downloaded, asset):
        raise RuntimeError(f"Downloaded model failed SHA-256 verification: {asset.filename}")
    downloaded.replace(destination)
    print(f"Verified: {destination}", flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models-dir", type=Path, default=Path(os.getenv("MA3AK_MODELS_DIR", str(Path.home() / "Ma3akModels"))))
    parser.add_argument("--config", type=Path, default=ROOT / ".local" / "model-config.json")
    parser.add_argument("--whisper-dir", type=Path, help="Use a selected local large-v3-turbo folder.")
    parser.add_argument("--reference-audio", type=Path, help="Optional personal Egyptian reference recording.")
    parser.add_argument("--reference-text", help="Exact transcript of --reference-audio.")
    parser.add_argument("--offline", action="store_true", help="Verify/reuse files only, with no download requests.")
    parser.add_argument("--replace", action="store_true", help="Replace a mismatched file at the selected target.")
    parser.add_argument("--only", choices=["all", "whisper", "habibi"], default="all", help="Partial preparation does not save the final app configuration.")
    parser.add_argument("--list", action="store_true", help="Print pinned sources and sizes without changing files.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.list:
        print(json.dumps([asdict(asset) for asset in WHISPER + HABIBI + VOCOS], indent=2))
        return
    if bool(args.reference_audio) != bool(args.reference_text):
        raise RuntimeError("Provide --reference-audio and its exact --reference-text together.")
    if args.reference_audio and not args.reference_audio.expanduser().is_file():
        raise RuntimeError(f"Reference recording does not exist: {args.reference_audio}")
    models_root = args.models_dir.expanduser().resolve()
    existing_whisper = Path.home() / "WhisperModels" / "large-v3-turbo"
    whisper_root = (args.whisper_dir or (existing_whisper if (existing_whisper / "model.bin").is_file() else models_root / "whisper-large-v3-turbo")).expanduser().resolve()
    habibi_root = models_root / "habibi-egyptian"
    vocos_root = habibi_root / "vocos"
    if args.only in {"all", "whisper"}:
        for asset in WHISPER:
            prepare(asset, whisper_root / asset.local_name, [], offline=args.offline, replace=args.replace)
    if args.only in {"all", "habibi"}:
        for asset in HABIBI:
            manual = Path.home() / "TTSModels" / "Habibi-Egyptian"
            candidates = [
                manual / asset.local_name,
                manual / "Specialized" / "EGY" / asset.local_name,
                Path.home() / "TTSModels" / "Habibi" / "Specialized" / "EGY" / asset.local_name,
                Path.home() / "Downloads" / asset.local_name,
            ]
            prepare(asset, habibi_root / asset.local_name, candidates, offline=args.offline, replace=args.replace)
        for asset in VOCOS:
            prepare(asset, vocos_root / asset.local_name, [], offline=args.offline, replace=args.replace)
    if args.only != "all":
        print(f"Selected models prepared at: {models_root}. Run without --only to save the complete app configuration.")
        return

    config_path = args.config.expanduser().resolve()
    config = json.loads(config_path.read_text(encoding="utf-8-sig")) if config_path.exists() else {}
    if not isinstance(config, dict):
        raise RuntimeError("Existing model configuration must be a JSON object.")
    config.update({
        "WHISPER_MODEL": str(whisper_root),
        "WHISPER_DEVICE": "cpu",
        "WHISPER_COMPUTE_TYPE": "int8",
        "MA3AK_MODELS_DIR": str(models_root),
        "TTS_MODEL_PATH": str(habibi_root / "model_100000.safetensors"),
        "TTS_VOCAB_PATH": str(habibi_root / "vocab.txt"),
        "TTS_VOCODER_PATH": str(vocos_root),
        "TTS_DEVICE": "cpu",
    })
    if args.reference_audio:
        config["TTS_REFERENCE_AUDIO"] = str(args.reference_audio.expanduser().resolve())
        config["TTS_REFERENCE_TEXT"] = args.reference_text
    tts_python = ROOT / "backend" / "tts_runtime" / ".venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    if tts_python.is_file():
        config["TTS_PYTHON"] = str(tts_python)
    config["_metadata"] = {"format": 1, "sources": [asdict(asset) for asset in WHISPER + HABIBI + VOCOS]}
    config_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=config_path.parent, delete=False) as stream:
        json.dump(config, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
        temporary = Path(stream.name)
    temporary.replace(config_path)
    print(f"Model configuration saved: {config_path}")
    print("Whisper large-v3-turbo and Egyptian Habibi + Vocos are ready for the backend.")
    print("Habibi uses its packaged Egyptian example voice unless a personal reference was configured.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, ImportError) as error:
        print(f"Model preparation failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None
