"""Lazy, bounded Habibi Egyptian speech synthesis in an isolated Python runtime."""

from __future__ import annotations

import io
import json
import math
import os
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import wave
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path


class TtsUnavailableError(RuntimeError):
    """The local synthesis runtime cannot complete the request."""


class InvalidTtsTextError(ValueError):
    """The text cannot be synthesized by this API."""


_BACKEND = Path(__file__).resolve().parents[1]
MAX_TEXT_CHARS = 600
MAX_WAV_BYTES = 20 * 1024 * 1024


@dataclass(frozen=True)
class HabibiSettings:
    model_path: Path
    vocab_path: Path
    vocoder_path: Path
    python: Path
    device: str = "cpu"
    reference_audio: Path | None = None
    reference_text: str | None = None
    timeout_seconds: float = 300
    worker: Path = _BACKEND / "tts_runtime" / "worker.py"

    @classmethod
    def from_environment(cls) -> HabibiSettings:
        configured_root = os.getenv("MA3AK_MODELS_DIR")
        model_root = (
            Path(configured_root) / "habibi-egyptian"
            if configured_root
            else Path.home() / "TTSModels" / "Habibi-Egyptian"
        )
        supplied = Path(os.getenv("TTS_MODEL_PATH", str(model_root))).expanduser()
        if supplied.suffix == ".safetensors":
            checkpoint = supplied
            model_root = supplied.parent
        else:
            model_root = supplied
            if not (model_root / "model_100000.safetensors").is_file():
                nested = model_root / "Specialized" / "EGY"
                if (nested / "model_100000.safetensors").is_file():
                    supplied = nested
            checkpoint = supplied / "model_100000.safetensors"
        reference = os.getenv("TTS_REFERENCE_AUDIO")
        default_python = (
            _BACKEND
            / "tts_runtime"
            / ".venv"
            / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
        )
        return cls(
            model_path=checkpoint,
            vocab_path=Path(os.getenv("TTS_VOCAB_PATH", str(checkpoint.parent / "vocab.txt"))),
            vocoder_path=Path(os.getenv("TTS_VOCODER_PATH", str(model_root / "vocos"))),
            python=Path(os.getenv("TTS_PYTHON", str(default_python))),
            device=os.getenv("TTS_DEVICE", "cpu").strip(),
            reference_audio=Path(reference).expanduser() if reference else None,
            reference_text=os.getenv("TTS_REFERENCE_TEXT") or None,
            timeout_seconds=float(os.getenv("TTS_TIMEOUT_SECONDS", "300")),
        )


class HabibiService:
    """One persistent worker; no unbounded inference queue or startup downloads."""

    def __init__(self, settings: HabibiSettings | None = None) -> None:
        self.settings = settings or HabibiSettings.from_environment()
        self._gate = threading.Semaphore(1)
        self._state_lock = threading.Lock()
        self._lifecycle_lock = threading.Lock()
        self._cache_lock = threading.Lock()
        self._state = "not_loaded"
        self._error: str | None = None
        self._closed = False
        self._process: subprocess.Popen[str] | None = None
        self._responses: queue.Queue[dict | None] = queue.Queue(maxsize=4)
        self._temporary: tempfile.TemporaryDirectory[str] | None = None
        self._request_id = 0
        self._cache: OrderedDict[str, bytes] = OrderedDict()

    def health(self) -> dict[str, str | bool]:
        with self._state_lock:
            result: dict[str, str | bool] = {
                "state": self._state,
                "model": "Habibi-TTS Specialized/EGY",
                "device": self.settings.device,
                "reference": "custom"
                if self.settings.reference_audio
                else "official_egyptian_demo",
            }
            if self._error:
                result["error"] = self._error
            return result

    def _state_change(self, state: str, error: str | None = None) -> None:
        with self._state_lock:
            self._state = state
            self._error = error

    def _configuration_check(self) -> None:
        config = self.settings
        if config.device not in {"cpu", "cuda"}:
            raise TtsUnavailableError("TTS_DEVICE must be cpu or cuda.")
        if not math.isfinite(config.timeout_seconds) or not 0 < config.timeout_seconds <= 300:
            raise TtsUnavailableError("TTS_TIMEOUT_SECONDS must be between 0 and 300 seconds.")
        for path, label in [
            (config.model_path, "Egyptian checkpoint"),
            (config.vocab_path, "Egyptian vocabulary"),
            (config.vocoder_path / "config.yaml", "Vocos config"),
            (config.vocoder_path / "pytorch_model.bin", "Vocos weights"),
            (config.worker, "Habibi worker"),
        ]:
            if not path.is_file():
                raise TtsUnavailableError(f"Missing {label}. Run the model preparation script.")
        if not config.python.is_file() and shutil.which(str(config.python)) is None:
            raise TtsUnavailableError("Habibi Python runtime is missing. Run the setup script.")
        if config.reference_audio:
            if not config.reference_audio.is_file() or not (config.reference_text or "").strip():
                raise TtsUnavailableError(
                    "Custom TTS reference needs an audio file and its transcript."
                )
        elif config.reference_text:
            raise TtsUnavailableError("Set TTS_REFERENCE_AUDIO with a custom reference transcript.")

    def _start_worker(self) -> tuple[subprocess.Popen[str], str]:
        with self._lifecycle_lock:
            if self._closed:
                raise TtsUnavailableError("Habibi service is closed.")
            self._start_worker_locked()
            assert self._process is not None and self._temporary is not None
            return self._process, self._temporary.name

    def _start_worker_locked(self) -> None:
        if self._process and self._process.poll() is None:
            return
        self._configuration_check()
        self._temporary = tempfile.TemporaryDirectory(
            prefix="ma3ak-tts-", ignore_cleanup_errors=True
        )
        config = self.settings
        args = [
            str(config.python),
            "-u",
            str(config.worker),
            "--model",
            str(config.model_path),
            "--vocab",
            str(config.vocab_path),
            "--vocoder",
            str(config.vocoder_path),
            "--device",
            config.device,
            "--output-dir",
            self._temporary.name,
        ]
        if config.reference_audio:
            args += [
                "--reference-audio",
                str(config.reference_audio),
                "--reference-text",
                config.reference_text or "",
            ]
        environment = os.environ.copy()
        environment.update(
            {
                "PYTHONUTF8": "1",
                "PYTHONUNBUFFERED": "1",
                "HF_HUB_OFFLINE": "1",
                "TRANSFORMERS_OFFLINE": "1",
                "TOKENIZERS_PARALLELISM": "false",
                "WANDB_MODE": "disabled",
                "GRADIO_ANALYTICS_ENABLED": "false",
                # Upstream reference preprocessing also creates temporary WAVs.
                # Keep those inside the directory removed on timeout/shutdown.
                "TMPDIR": self._temporary.name,
                "TEMP": self._temporary.name,
                "TMP": self._temporary.name,
            }
        )
        responses: queue.Queue[dict | None] = queue.Queue(maxsize=4)
        self._responses = responses
        process = subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=None,
            text=True,
            encoding="utf-8",
            env=environment,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        self._process = process

        def read_responses() -> None:
            assert process.stdout is not None
            try:
                for line in process.stdout:
                    if len(line) > 64 * 1024:
                        break
                    try:
                        message = json.loads(line)
                    except ValueError:
                        break
                    if not isinstance(message, dict):
                        break
                    try:
                        responses.put_nowait(message)
                    except queue.Full:
                        break
            except (OSError, ValueError):
                # A concurrent service close may close the process pipe.
                pass
            finally:
                try:
                    responses.put_nowait(None)
                except queue.Full:
                    pass

        threading.Thread(target=read_responses, name="habibi-replies", daemon=True).start()

    @staticmethod
    def _validate_wav(data: bytes) -> None:
        if len(data) > MAX_WAV_BYTES:
            raise TtsUnavailableError("Habibi returned too much audio.")
        try:
            with wave.open(io.BytesIO(data), "rb") as audio:
                frames = audio.getnframes()
                rate = audio.getframerate()
                channels = audio.getnchannels()
                if (
                    audio.getcomptype() != "NONE"
                    or audio.getsampwidth() != 2
                    or channels not in {1, 2}
                    or not 8000 <= rate <= 48000
                    or frames <= 0
                    or frames / rate > 180
                    or len(audio.readframes(frames)) != frames * channels * 2
                ):
                    raise ValueError("Invalid synthesis WAV")
        except (wave.Error, EOFError, OSError, ValueError) as exc:
            raise TtsUnavailableError("Habibi returned invalid WAV audio.") from exc

    def synthesize(self, text: str) -> bytes:
        text = text.strip()
        if not text or len(text) > MAX_TEXT_CHARS:
            raise InvalidTtsTextError(f"Text must contain 1 to {MAX_TEXT_CHARS} characters.")
        deadline = time.monotonic() + self.settings.timeout_seconds
        if not self._gate.acquire(timeout=min(2, max(self.settings.timeout_seconds, 0))):
            raise TtsUnavailableError("Habibi is busy with another reply. Try again shortly.")
        output: Path | None = None
        try:
            if self._closed:
                raise TtsUnavailableError("Habibi service is closed.")
            with self._cache_lock:
                cached = self._cache.get(text)
                if cached is not None:
                    self._cache.move_to_end(text)
                    return cached
            self._state_change("loading")
            process, directory = self._start_worker()
            self._request_id += 1
            request_id = self._request_id
            output = Path(directory) / f"reply-{request_id}.wav"
            assert process.stdin is not None
            process.stdin.write(
                json.dumps(
                    {
                        "id": request_id,
                        "text": text,
                        "output": str(output),
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )
            process.stdin.flush()
            try:
                response = self._responses.get(timeout=max(0.001, deadline - time.monotonic()))
            except queue.Empty as exc:
                raise TtsUnavailableError(
                    "Habibi synthesis timed out. Try a shorter reply."
                ) from exc
            if response is None:
                raise TtsUnavailableError("Habibi worker stopped. Check the local runtime setup.")
            if response.get("id") != request_id or response.get("ok") is not True:
                raise TtsUnavailableError(
                    "Habibi could not synthesize the reply. Check its model setup."
                )
            if not output.is_file() or output.stat().st_size > MAX_WAV_BYTES:
                raise TtsUnavailableError("Habibi did not return a valid audio file.")
            data = output.read_bytes()
            self._validate_wav(data)
            if self._closed:
                raise TtsUnavailableError("Habibi service is closed.")
            self._state_change("ready")
            with self._cache_lock:
                if len(data) <= 1024 * 1024 and not self._closed:
                    self._cache[text] = data
                    while len(self._cache) > 8:
                        self._cache.popitem(last=False)
            return data
        except (OSError, ValueError, TtsUnavailableError) as exc:
            self._state_change(
                "closed" if self._closed else "error",
                None
                if self._closed
                else str(exc)
                if isinstance(exc, TtsUnavailableError)
                else "Habibi runtime failed. Check the local setup.",
            )
            self._stop_worker()
            if isinstance(exc, TtsUnavailableError):
                raise
            raise TtsUnavailableError("Habibi runtime failed. Check the local setup.") from exc
        finally:
            if output:
                output.unlink(missing_ok=True)
            self._gate.release()

    def _stop_worker(self) -> None:
        with self._lifecycle_lock:
            self._stop_worker_locked()

    def _stop_worker_locked(self) -> None:
        process, self._process = self._process, None
        if process is not None:
            try:
                process.terminate()
                process.wait(timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    process.kill()
                    process.wait(timeout=3)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            for stream in [process.stdin, process.stdout]:
                if stream:
                    try:
                        stream.close()
                    except (OSError, ValueError):
                        pass
        temporary, self._temporary = self._temporary, None
        if temporary:
            temporary.cleanup()

    def close(self) -> None:
        self._closed = True
        with self._cache_lock:
            self._cache.clear()
        self._stop_worker()
        self._state_change("closed")
