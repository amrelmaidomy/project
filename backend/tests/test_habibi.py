"""Exercise real subprocess framing/deadlines without downloading neural weights."""

import importlib.util
import io
import sys
import threading
import time
import wave
from dataclasses import replace
from pathlib import Path

import pytest

from services.habibi_service import (
    HabibiService,
    HabibiSettings,
    InvalidTtsTextError,
    TtsUnavailableError,
)


@pytest.fixture
def settings(tmp_path: Path) -> HabibiSettings:
    for name in ["model_100000.safetensors", "vocab.txt", "config.yaml", "pytorch_model.bin"]:
        (tmp_path / name).write_text("fixture")
    worker = tmp_path / "worker.py"
    worker.write_text("""
import argparse, json, sys, tempfile, time, wave
from pathlib import Path
parser=argparse.ArgumentParser()
for name in ['model','vocab','vocoder','device','output-dir']:
    parser.add_argument('--'+name)
args=parser.parse_args()
assert Path(tempfile.gettempdir()) == Path(args.output_dir)
for line in sys.stdin:
    data=json.loads(line)
    if data['text']=='hang': time.sleep(30)
    if data['text']=='bad':
        open(data['output'],'wb').write(b'not a WAV')
    elif data['text']=='fail':
        print(json.dumps({'id':data['id'],'ok':False}),flush=True)
        continue
    else:
        with wave.open(data['output'],'wb') as output:
            output.setnchannels(1);output.setsampwidth(2);output.setframerate(24000)
            output.writeframes(bytes(4800))
    print(json.dumps({'id':data['id'],'ok':True}),flush=True)
""")
    return HabibiSettings(
        model_path=tmp_path / "model_100000.safetensors",
        vocab_path=tmp_path / "vocab.txt",
        vocoder_path=tmp_path,
        python=Path(sys.executable),
        worker=worker,
        timeout_seconds=5,
    )


def test_missing_models_are_lazy_and_reported_without_starting_process(tmp_path):
    service = HabibiService(
        HabibiSettings(
            model_path=tmp_path / "missing",
            vocab_path=tmp_path / "missing-vocab",
            vocoder_path=tmp_path,
            python=Path(sys.executable),
        )
    )
    assert service.health()["state"] == "not_loaded"
    with pytest.raises(TtsUnavailableError, match="Missing Egyptian checkpoint"):
        service.synthesize("أهلًا")
    assert service.health()["state"] == "error"
    assert service._process is None


def test_real_rpc_returns_pcm16_wav_reuses_worker_and_caches_short_replies(settings):
    service = HabibiService(settings)
    try:
        audio = service.synthesize("أهلًا، أنا رفيق")
        process = service._process
        assert process is not None
        with wave.open(io.BytesIO(audio), "rb") as wav:
            assert wav.getsampwidth() == 2
            assert wav.getframerate() == 24000
            assert wav.getnframes() == 2400
        assert service.synthesize("أهلًا، أنا رفيق") == audio
        assert service.synthesize("قولّي أذكرك بإيه") == audio
        assert service._process is process
        assert service.health()["state"] == "ready"
        assert list(Path(service._temporary.name).iterdir()) == []
    finally:
        service.close()
    assert process.poll() is not None


@pytest.mark.parametrize("text", ["", "   ", "أ" * 601])
def test_invalid_text_never_starts_worker(settings, text):
    service = HabibiService(settings)
    with pytest.raises(InvalidTtsTextError):
        service.synthesize(text)
    assert service._process is None


@pytest.mark.parametrize("text", ["bad", "fail"])
def test_worker_failure_or_invalid_audio_never_returns_success(settings, text):
    service = HabibiService(settings)
    with pytest.raises(TtsUnavailableError):
        service.synthesize(text)
    assert service.health()["state"] == "error"
    assert service._process is None
    assert service._temporary is None


def test_deadline_terminates_worker_and_deletes_outputs(settings):
    service = HabibiService(replace(settings, timeout_seconds=0.15))
    before = time.monotonic()
    with pytest.raises(TtsUnavailableError, match="timed out"):
        service.synthesize("hang")
    assert time.monotonic() - before < 3
    assert service._process is None
    assert service._temporary is None


def test_busy_service_has_bounded_wait_instead_of_queuing(settings):
    service = HabibiService(replace(settings, timeout_seconds=0.05))
    service._gate.acquire()
    try:
        with pytest.raises(TtsUnavailableError, match="busy"):
            service.synthesize("أهلًا")
    finally:
        service._gate.release()
    assert service._process is None


def test_close_stops_inflight_worker_and_unblocks_request(settings):
    service = HabibiService(settings)
    failures = []

    def synthesize():
        try:
            service.synthesize("hang")
        except TtsUnavailableError as error:
            failures.append(error)

    thread = threading.Thread(target=synthesize)
    thread.start()
    deadline = time.monotonic() + 2
    while service._process is None and time.monotonic() < deadline:
        time.sleep(0.01)
    process = service._process
    assert process is not None
    service.close()
    thread.join(timeout=2)
    assert not thread.is_alive()
    assert process.poll() is not None
    assert failures
    assert service.health()["state"] == "closed"


def test_environment_discovers_manual_nested_checkpoint(monkeypatch, tmp_path):
    root = tmp_path / "habibi-egyptian"
    nested = root / "Specialized" / "EGY"
    nested.mkdir(parents=True)
    (nested / "model_100000.safetensors").touch()
    monkeypatch.setenv("MA3AK_MODELS_DIR", str(tmp_path))
    monkeypatch.delenv("TTS_MODEL_PATH", raising=False)
    monkeypatch.delenv("TTS_VOCAB_PATH", raising=False)
    monkeypatch.delenv("TTS_VOCODER_PATH", raising=False)
    configured = HabibiSettings.from_environment()
    assert configured.model_path == nested / "model_100000.safetensors"
    assert configured.vocab_path == nested / "vocab.txt"
    assert configured.vocoder_path == root / "vocos"


def test_custom_reference_requires_matching_transcript(settings, tmp_path):
    reference = tmp_path / "own.wav"
    reference.touch()
    service = HabibiService(replace(settings, reference_audio=reference))
    with pytest.raises(TtsUnavailableError, match="transcript"):
        service.synthesize("أهلًا")
    assert service._process is None


def test_wav_validator_rejects_incomplete_pcm():
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(24000)
        wav.writeframes(bytes(4800))
    with pytest.raises(TtsUnavailableError, match="invalid WAV"):
        HabibiService._validate_wav(output.getvalue()[:-20])


def test_unpunctuated_arabic_is_split_without_losing_words():
    worker_path = Path(__file__).resolve().parents[1] / "tts_runtime" / "worker.py"
    spec = importlib.util.spec_from_file_location("habibi_worker", worker_path)
    worker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(worker)
    text = "كلام عربي من غير علامات ترقيم " * 15
    chunks = worker.split_for_synthesis(text)
    assert len(chunks) > 1
    assert " ".join(chunks) == " ".join(text.split())
    assert all(len(chunk.encode("utf-8")) <= 180 for chunk in chunks)
    with pytest.raises(ValueError, match="word"):
        worker.split_for_synthesis("أ" * 100)
