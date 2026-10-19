"""Whisper inference without a model download during application startup."""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from threading import Lock
from typing import Any

logger = logging.getLogger(__name__)


class SpeechUnavailableError(RuntimeError):
    """The configured Whisper model or runtime is unavailable."""


class InvalidAudioError(ValueError):
    """The uploaded recording contains no usable speech."""


@dataclass(frozen=True)
class WhisperSettings:
    model: str = "small"
    device: str = "cpu"
    compute_type: str = "int8"
    download_root: str | None = None

    @classmethod
    def from_environment(cls) -> "WhisperSettings":
        device = os.getenv("WHISPER_DEVICE", "cpu").strip()
        if device not in {"cpu", "cuda"}:
            raise ValueError("WHISPER_DEVICE must be cpu or cuda")
        return cls(
            model=os.getenv("WHISPER_MODEL", "large-v3-turbo" if device == "cuda" else "small"),
            device=device,
            compute_type=os.getenv(
                "WHISPER_COMPUTE_TYPE", "float16" if device == "cuda" else "int8"
            ),
            download_root=os.getenv("WHISPER_DOWNLOAD_ROOT") or None,
        )


class WhisperService:
    """Load once on first transcription and serialize access to the model."""

    def __init__(self, settings: WhisperSettings | None = None) -> None:
        self.settings = settings or WhisperSettings.from_environment()
        self._model: Any = None
        self._state = "not_loaded"
        self._error: str | None = None
        self._state_lock = Lock()
        self._load_lock = Lock()
        self._inference_lock = Lock()

    def health(self) -> dict[str, str]:
        with self._state_lock:
            result = {
                "state": self._state,
                "model": self.settings.model,
                "device": self.settings.device,
                "compute_type": self.settings.compute_type,
            }
            if self._error is not None:
                result["error"] = self._error
            return result

    def _load_model(self) -> Any:
        with self._load_lock:
            if self._state == "error":
                raise SpeechUnavailableError(self._error)
            if self._model is not None:
                return self._model
            with self._state_lock:
                self._state = "loading"
            try:
                # Keep this import lazy: /health and text parsing need no GPU,
                # CTranslate2 initialization, network, or model download.
                from faster_whisper import WhisperModel

                self._model = WhisperModel(
                    self.settings.model,
                    device=self.settings.device,
                    compute_type=self.settings.compute_type,
                    download_root=self.settings.download_root,
                )
            except Exception as exc:
                logger.exception("Could not initialize Whisper")
                with self._state_lock:
                    self._state = "error"
                    self._error = (
                        f"Whisper initialization failed ({type(exc).__name__}). "
                        "Check model access and runtime configuration, then restart."
                    )
                raise SpeechUnavailableError(self._error) from exc
            with self._state_lock:
                self._state = "ready"
            return self._model

    def transcribe(self, audio_path: str) -> str:
        model = self._load_model()
        try:
            with self._inference_lock:
                segments, _ = model.transcribe(
                    audio_path,
                    language="ar",
                    task="transcribe",
                    vad_filter=True,
                    vad_parameters={"min_silence_duration_ms": 500},
                    beam_size=5,
                    condition_on_previous_text=False,
                )
                # faster-whisper produces a lazy generator; consume it under
                # the lock so errors and model use stay inside this request.
                text = " ".join(segment.text.strip() for segment in segments).strip()
        except (ValueError, EOFError) as exc:
            raise InvalidAudioError("تعذر قراءة التسجيل الصوتي.") from exc
        except Exception as exc:
            logger.exception("Whisper transcription failed")
            with self._state_lock:
                self._state = "error"
                self._error = (
                    f"Whisper inference failed ({type(exc).__name__}). "
                    "Check runtime configuration, then restart."
                )
            raise SpeechUnavailableError(self._error) from exc
        if not text:
            raise InvalidAudioError("لم يتم العثور على كلام واضح في التسجيل.")
        return text
