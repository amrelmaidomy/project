"""HTTP contracts and speech failure paths, independent of model downloads."""

import io
import sys
import wave
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

import main
from services.whisper_service import (
    InvalidAudioError,
    SpeechUnavailableError,
    WhisperService,
    WhisperSettings,
)


def wav_bytes(*, seconds=0.1, rate=16000):
    output = io.BytesIO()
    with wave.open(output, "wb") as recording:
        recording.setnchannels(1)
        recording.setsampwidth(2)
        recording.setframerate(rate)
        recording.writeframes(b"\0\0" * int(seconds * rate))
    return output.getvalue()


class FakeSpeech:
    def __init__(self):
        self.paths = []
        self.error = None

    def health(self):
        return {"state": "not_loaded", "model": "small", "device": "cpu", "compute_type": "int8"}

    def transcribe(self, path):
        self.paths.append(path)
        assert Path(path).is_file()
        if self.error:
            raise self.error
        return "عندي دكتور بكرة الساعة خمسة"


@pytest.fixture
def api():
    speech = FakeSpeech()
    main.app.dependency_overrides[main.get_speech_service] = lambda: speech
    with TestClient(main.app) as client:
        yield client, speech
    main.app.dependency_overrides.clear()


def test_health_exposes_lazy_speech_state(api):
    client, speech = api
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    assert response.json()["speech"]["state"] == "not_loaded"
    assert speech.paths == []


def test_parser_endpoint_contract(api):
    client, _ = api
    response = client.post(
        "/parse-reminder",
        json={
            "text": "عندي محاضرة الخميس الساعة ثلاثة العصر فكرني قبلها بساعتين",
            "now": "2026-10-19T12:00:00+03:00",
            "timezone": "Africa/Cairo",
        },
    )
    assert response.status_code == 200
    result = response.json()
    assert result["title"] == "محاضرة"
    assert result["event_datetime"].startswith("2026-10-22T15:00")
    assert result["reminder_datetime"].startswith("2026-10-22T13:00")
    assert result["missing_fields"] == []


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"text": " "},
        {"text": "x" * 4001},
        {"text": "بكرة", "timezone": "Not/AZone"},
        {"text": "بكرة", "now": "2026-10-19T12:00:00"},
    ],
)
def test_invalid_parser_requests_are_422(api, payload):
    client, _ = api
    assert client.post("/parse-reminder", json=payload).status_code == 422


def test_transcription_receives_wav_and_removes_temporary_file(api):
    client, speech = api
    response = client.post("/transcribe", files={"file": ("voice.wav", wav_bytes(), "audio/wav")})
    assert response.status_code == 200
    assert response.json() == {"text": "عندي دكتور بكرة الساعة خمسة"}
    assert len(speech.paths) == 1
    assert not Path(speech.paths[0]).exists()


@pytest.mark.parametrize("content", [b"", b"not audio", wav_bytes()[:-20]])
def test_invalid_audio_never_calls_model(api, content):
    client, speech = api
    response = client.post("/transcribe", files={"file": ("bad.wav", content, "audio/wav")})
    assert response.status_code == 422
    assert speech.paths == []


def test_duration_limit_is_enforced_before_inference(api, monkeypatch):
    client, speech = api
    monkeypatch.setattr(main, "MAX_AUDIO_SECONDS", 0.05)
    response = client.post("/transcribe", files={"file": ("voice.wav", wav_bytes(), "audio/wav")})
    assert response.status_code == 422
    assert speech.paths == []


def test_byte_limit_and_cleanup(api, monkeypatch, tmp_path):
    client, speech = api
    monkeypatch.setattr(main, "MAX_AUDIO_BYTES", 30)
    monkeypatch.setattr(main.tempfile, "tempdir", str(tmp_path))
    response = client.post("/transcribe", files={"file": ("voice.wav", wav_bytes(), "audio/wav")})
    assert response.status_code == 413
    assert list(tmp_path.iterdir()) == []
    assert speech.paths == []


def test_unsupported_format(api):
    client, speech = api
    response = client.post("/transcribe", files={"file": ("voice.mp3", b"data", "audio/mpeg")})
    assert response.status_code == 415
    assert speech.paths == []


@pytest.mark.parametrize(
    "error, status",
    [
        (SpeechUnavailableError("model unavailable"), 503),
        (InvalidAudioError("no speech"), 422),
    ],
)
def test_speech_errors_keep_http_contract_and_cleanup(api, error, status):
    client, speech = api
    speech.error = error
    response = client.post("/transcribe", files={"file": ("voice.wav", wav_bytes(), "audio/wav")})
    assert response.status_code == status
    assert not Path(speech.paths[0]).exists()


def test_service_loads_once_and_uses_arabic_silero_vad(monkeypatch):
    calls = []

    class FakeWhisperModel:
        def __init__(self, *args, **kwargs):
            calls.append((args, kwargs))

        def transcribe(self, path, **kwargs):
            assert kwargs["language"] == "ar"
            assert kwargs["vad_filter"] is True
            assert kwargs["vad_parameters"] == {"min_silence_duration_ms": 500}
            return iter([SimpleNamespace(text=" عندي دكتور ")]), SimpleNamespace()

    monkeypatch.setitem(
        sys.modules, "faster_whisper", SimpleNamespace(WhisperModel=FakeWhisperModel)
    )
    speech = WhisperService(WhisperSettings())
    assert speech.health()["state"] == "not_loaded"
    assert calls == []
    assert speech.transcribe("example.wav") == "عندي دكتور"
    assert speech.transcribe("example.wav") == "عندي دكتور"
    assert len(calls) == 1
    assert calls[0][1]["compute_type"] == "int8"
    assert speech.health()["state"] == "ready"


def test_model_load_failure_is_reported_without_repeated_downloads(monkeypatch):
    attempts = []

    def fail_to_load(*args, **kwargs):
        attempts.append(args)
        raise RuntimeError("download unavailable")

    monkeypatch.setitem(sys.modules, "faster_whisper", SimpleNamespace(WhisperModel=fail_to_load))
    speech = WhisperService(WhisperSettings())
    for _ in range(2):
        with pytest.raises(SpeechUnavailableError):
            speech.transcribe("example.wav")
    assert len(attempts) == 1
    assert speech.health()["state"] == "error"


def test_cuda_defaults_to_final_model(monkeypatch):
    monkeypatch.setenv("WHISPER_DEVICE", "cuda")
    monkeypatch.delenv("WHISPER_MODEL", raising=False)
    monkeypatch.delenv("WHISPER_COMPUTE_TYPE", raising=False)
    settings = WhisperSettings.from_environment()
    assert settings.model == "large-v3-turbo"
    assert settings.compute_type == "float16"


def test_runtime_failure_updates_health_and_requires_restart(monkeypatch):
    attempts = []

    class BrokenRuntime:
        def __init__(self, *args, **kwargs):
            pass

        def transcribe(self, path, **kwargs):
            attempts.append(path)
            raise TypeError("incompatible audio decoder runtime")

    monkeypatch.setitem(sys.modules, "faster_whisper", SimpleNamespace(WhisperModel=BrokenRuntime))
    speech = WhisperService(WhisperSettings())
    for _ in range(2):
        with pytest.raises(SpeechUnavailableError):
            speech.transcribe("example.wav")
    assert len(attempts) == 1
    assert speech.health()["state"] == "error"
    assert "TypeError" in speech.health()["error"]
