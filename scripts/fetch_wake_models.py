#!/usr/bin/env python3
"""Install only HTTPS/SHA-256-pinned openWakeWord ONNX assets; no training occurs.

The optional English demo pins actual upstream Android-port assets at an immutable
Git commit. For Arabic, supply a manifest with your trained classifier and its hash.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

UPSTREAM_COMMIT = "b49f3ab14cf558ac0c2aef73a5e6c83da7a08558"
BASE_URL = (
    "https://raw.githubusercontent.com/msnilsen/openwakeword-android/"
    f"{UPSTREAM_COMMIT}/openwakeword/src/main/assets/openwakeword/"
)
MAX_BYTES = 32 * 1024 * 1024
DEMO = {
    "version": 1,
    "source": f"https://github.com/msnilsen/openwakeword-android/tree/{UPSTREAM_COMMIT}",
    "mel": {
        "file": "melspectrogram.onnx",
        "url": BASE_URL + "melspectrogram.onnx",
        "sha256": "ba2b0e0f8b7b875369a2c89cb13360ff53bac436f2895cced9f479fa65eb176f",
    },
    "embedding": {
        "file": "embedding_model.onnx",
        "url": BASE_URL + "embedding_model.onnx",
        "sha256": "70d164290c1d095d1d4ee149bc5e00543250a7316b59f31d056cff7bd3075c1f",
    },
    "classifiers": {
        "hey_jarvis": {
            "file": "hey_jarvis.onnx",
            "url": BASE_URL + "hey_jarvis_v0.1.onnx",
            "sha256": "94a13cfe60075b132f6a472e7e462e8123ee70861bc3fb58434a73712ee0d2cb",
            "phrase": "Hey Jarvis",
            "threshold": 0.6,
            "license": "CC-BY-NC-SA-4.0",
        }
    },
}


def entries(manifest: dict) -> list[dict]:
    if manifest.get("version") != 1:
        raise ValueError("Manifest version must be 1.")
    classifiers = manifest.get("classifiers")
    if not isinstance(classifiers, dict) or not classifiers:
        raise ValueError("At least one explicitly named classifier is required.")
    for profile, classifier in classifiers.items():
        expected = {"ya_mosaed": "يا مساعد", "hey_jarvis": "Hey Jarvis"}.get(profile)
        if expected is None or classifier.get("phrase") != expected:
            raise ValueError("Classifier profile and declared phrase do not match.")
        threshold = classifier.get("threshold", 0.6)
        if not isinstance(threshold, (int, float)) or not 0.01 <= threshold <= 0.99:
            raise ValueError("Threshold must be between 0.01 and 0.99.")
    models = [manifest["mel"], manifest["embedding"], *classifiers.values()]
    names: set[str] = set()
    for model in models:
        name = model.get("file", "")
        digest = model.get("sha256", "")
        url = urlparse(model.get("url", ""))
        if not re.fullmatch(r"[A-Za-z0-9_.-]+\.onnx", name) or name in names:
            raise ValueError("Use distinct plain .onnx filenames without directories.")
        if not re.fullmatch(r"[a-fA-F0-9]{64}", digest):
            raise ValueError(f"Supply an independently verified SHA-256 for {name}.")
        if url.scheme != "https" or not url.hostname or url.username or url.password:
            raise ValueError(f"Use an HTTPS URL without embedded credentials for {name}.")
        names.add(name)
    return models


def sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def runtime_manifest(manifest: dict) -> dict:
    """Never package download URLs, signed queries, or arbitrary user metadata."""
    def model(entry: dict, classifier: bool = False) -> dict:
        result = {"file": entry["file"], "sha256": entry["sha256"].lower()}
        if classifier:
            result.update(phrase=entry["phrase"], threshold=entry.get("threshold", 0.6))
        return result
    return {
        "version": 1,
        "mel": model(manifest["mel"]),
        "embedding": model(manifest["embedding"]),
        "classifiers": {name: model(entry, True) for name, entry in manifest["classifiers"].items()},
    }


def verify_inference(directory: Path, manifest: dict) -> None:
    """Run the real ONNX stages against silence; not a microphone/accuracy test."""
    from collections import deque

    import numpy as np
    import onnxruntime as ort

    options = ort.SessionOptions()
    options.intra_op_num_threads = 1
    options.inter_op_num_threads = 1

    def session(entry: dict):
        runtime = ort.InferenceSession(str(directory / entry["file"]), options, providers=["CPUExecutionProvider"])
        if len(runtime.get_inputs()) != 1 or len(runtime.get_outputs()) != 1:
            raise ValueError("Wake ONNX models require exactly one input and output.")
        print(f"{entry['file']}: {runtime.get_inputs()[0].shape} -> {runtime.get_outputs()[0].shape}")
        return runtime

    def run(runtime, value, shape):
        result = runtime.run(None, {runtime.get_inputs()[0].name: value})[0]
        if result.dtype != np.float32 or result.shape != shape or not np.isfinite(result).all():
            raise ValueError(f"Unexpected ONNX output shape/type: {result.shape}/{result.dtype}")
        return result

    mel = session(manifest["mel"])
    embedding = session(manifest["embedding"])
    classifiers = {name: session(entry) for name, entry in manifest["classifiers"].items()}
    mel_frames = deque(maxlen=76)
    features = deque(maxlen=16)
    scores = {name: [] for name in classifiers}
    # Same frame/overlap/window contract as the native pipeline; real model runs.
    for _ in range(40):
        spectrum = run(mel, np.zeros((1, 1760), np.float32), (1, 1, 8, 32))[0, 0] / 10 + 2
        mel_frames.extend(spectrum)
        if len(mel_frames) < 76:
            continue
        value = np.asarray(mel_frames, np.float32)[None, :, :, None]
        feature = run(embedding, value, (1, 1, 1, 96)).reshape(96)
        features.append(feature)
        if len(features) < 16:
            continue
        for name, classifier in classifiers.items():
            score = float(run(classifier, np.asarray(features, np.float32)[None, :, :], (1, 1))[0, 0])
            if not 0 <= score <= 1:
                raise ValueError("Classifier produced a score outside [0, 1].")
            scores[name].append(score)
    for name, values in scores.items():
        if not values or max(values) >= manifest["classifiers"][name].get("threshold", 0.6):
            raise ValueError(f"The {name} classifier failed the silence smoke check.")
        print(f"Real ONNX silence smoke: {name}, {len(values)} predictions, max score={max(values):.8f}; no trigger.")


def download(model: dict, directory: Path, replace: bool) -> None:
    target = directory / model["file"]
    expected = model["sha256"].lower()
    if target.exists():
        if target.stat().st_size <= MAX_BYTES and sha256(target) == expected:
            print(f"Verified cached {target.name}")
            return
        if not replace:
            raise ValueError(f"Existing {target.name} differs. Review it, then use --replace if intended.")
    temporary: Path | None = None
    try:
        request = Request(model["url"], headers={"User-Agent": "Ma3ak-Wake-Model-Installer/1.0"})
        # urllib's default SSL context verifies both certificate and hostname.
        with urlopen(request, timeout=60) as response, tempfile.NamedTemporaryFile(
            dir=directory, prefix=".wake-", suffix=".part", delete=False
        ) as output:
            temporary = Path(output.name)
            if urlparse(response.geturl()).scheme != "https":
                raise ValueError("Refusing a redirect to an unencrypted download.")
            digest = hashlib.sha256()
            total = 0
            while chunk := response.read(64 * 1024):
                total += len(chunk)
                if total > MAX_BYTES:
                    raise ValueError("Wake models must not exceed 32 MiB each.")
                digest.update(chunk)
                output.write(chunk)
            if not total or digest.hexdigest() != expected:
                raise ValueError(f"SHA-256 mismatch for {target.name}; downloaded bytes were rejected.")
        os.replace(temporary, target)
        temporary = None
        print(f"Downloaded and verified {target.name}")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--demo", action="store_true", help="Explicit English Hey Jarvis demo only.")
    source.add_argument("--manifest", type=Path, help="Reviewed JSON with independent hashes for every model.")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1]
                        / "mobile/android/app/src/main/assets/wakeword")
    parser.add_argument("--replace", action="store_true", help="Replace conflicting files after successful verification.")
    parser.add_argument("--verify-inference", action="store_true", help="Run real ONNX tensor/silence smoke; requires numpy and onnxruntime.")
    args = parser.parse_args()
    manifest = DEMO if args.demo else json.loads(args.manifest.read_text(encoding="utf-8"))
    models = entries(manifest)
    sanitized = runtime_manifest(manifest)
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    for model in models:
        download(model, directory, args.replace)
    target_manifest = directory / "models.json"
    if target_manifest.exists():
        existing = json.loads(target_manifest.read_text(encoding="utf-8"))
        if runtime_manifest(existing) != sanitized and not args.replace:
            raise ValueError("Existing models.json differs; review before using --replace.")
    # The runtime rechecks every SHA-256 before loading ONNX.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=directory,
                                     prefix=".manifest-", delete=False) as output:
        json.dump(sanitized, output, ensure_ascii=False, indent=2)
        output.write("\n")
        temporary = Path(output.name)
    os.replace(temporary, target_manifest)
    # Carry the source/model licenses inside the APK alongside optional assets.
    notices = Path(__file__).resolve().parents[1] / 'mobile/lib/features/wake_word'
    for name in ('LICENSE.openwakeword', 'LICENSE.hey_jarvis'):
        source = notices / name
        target = directory / name
        if source.exists():
            content = source.read_bytes()
            if target.exists() and target.read_bytes() != content:
                raise ValueError(f'Existing {name} differs; review before replacing it.')
            if not target.exists():
                target.write_bytes(content)
    print("Installed manifest. Rebuild the APK to package these assets.")
    if args.demo:
        print("English demo only: this does not recognize يا مساعد and does not train a custom model.")
    if args.verify_inference:
        verify_inference(directory, manifest)


if __name__ == "__main__":
    main()
