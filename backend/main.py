"""FastAPI entry point. Run from backend with ``uvicorn main:app``."""

from __future__ import annotations

import os
import tempfile
import wave
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from pydantic import BaseModel, Field, field_validator
from starlette.concurrency import run_in_threadpool

from models.reminder_schema import ParseReminderRequest, ParseReminderResponse
from parser.reminder_parser import parse_reminder
from services.habibi_service import HabibiService, InvalidTtsTextError, TtsUnavailableError
from services.whisper_service import (
    InvalidAudioError,
    SpeechUnavailableError,
    WhisperService,
)


@asynccontextmanager
async def lifespan(application: FastAPI):
    try:
        yield
    finally:
        global _tts_service
        if _tts_service is not None:
            await run_in_threadpool(_tts_service.close)
            _tts_service = None


app = FastAPI(
    title="معاك — رفيق المواعيد",
    version="1.2.0",
    description="Arabic reminders with local Whisper large-v3-turbo and Habibi Egyptian TTS.",
    lifespan=lifespan,
)

_origins = [value.strip() for value in os.getenv("CORS_ORIGINS", "").split(",") if value.strip()]
if _origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=_origins,
        allow_methods=["GET", "POST"],
        allow_headers=["Content-Type"],
    )

MAX_AUDIO_BYTES = int(os.getenv("MAX_AUDIO_BYTES", str(10 * 1024 * 1024)))
MAX_AUDIO_SECONDS = float(os.getenv("MAX_AUDIO_SECONDS", "120"))
if MAX_AUDIO_BYTES <= 0 or MAX_AUDIO_SECONDS <= 0:
    raise ValueError("Audio size and duration limits must be positive")

_speech_service: WhisperService | None = None
_tts_service: HabibiService | None = None


def get_speech_service() -> WhisperService:
    global _speech_service
    if _speech_service is None:
        _speech_service = WhisperService()
    return _speech_service


def get_tts_service() -> HabibiService:
    global _tts_service
    if _tts_service is None:
        _tts_service = HabibiService()
    return _tts_service


class TranscribeResponse(BaseModel):
    text: str


class SynthesizeRequest(BaseModel):
    text: str = Field(min_length=1, max_length=600)

    @field_validator("text")
    @classmethod
    def nonblank_text(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("اكتب النص المطلوب تحويله لصوت.")
        return value


@app.get("/health")
def health(
    speech: WhisperService = Depends(get_speech_service),
    tts: HabibiService = Depends(get_tts_service),
) -> dict:
    """API readiness is independent from the optional lazy speech model."""
    return {"status": "ok", "speech": speech.health(), "tts": tts.health()}


@app.post("/synthesize", response_class=Response)
async def synthesize(
    request: SynthesizeRequest,
    tts: HabibiService = Depends(get_tts_service),
) -> Response:
    """Return real Habibi Egyptian PCM WAV; never substitute a device voice."""
    try:
        audio = await run_in_threadpool(tts.synthesize, request.text)
    except InvalidTtsTextError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except TtsUnavailableError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return Response(content=audio, media_type="audio/wav", headers={"Cache-Control": "no-store"})


@app.post("/parse-reminder", response_model=ParseReminderResponse)
def parse_reminder_endpoint(request: ParseReminderRequest) -> ParseReminderResponse:
    return parse_reminder(request)


def validate_wav(path: str) -> None:
    """Check real WAV structure and payload before loading the speech model."""
    try:
        with wave.open(path, "rb") as recording:
            channels = recording.getnchannels()
            rate = recording.getframerate()
            frames = recording.getnframes()
            width = recording.getsampwidth()
            if (
                recording.getcomptype() != "NONE"
                or channels not in {1, 2}
                or not 8000 <= rate <= 48000
                or width not in {1, 2, 3, 4}
                or frames <= 0
            ):
                raise InvalidAudioError("استخدم تسجيل WAV PCM صالحًا، ويفضل 16 kHz mono.")
            if frames / rate > MAX_AUDIO_SECONDS:
                raise InvalidAudioError(f"مدة التسجيل يجب ألا تتجاوز {MAX_AUDIO_SECONDS:g} ثانية.")
            expected_size = frames * channels * width
            if expected_size > MAX_AUDIO_BYTES:
                raise InvalidAudioError("حجم بيانات الصوت المعلنة أكبر من الحد المسموح.")
            if len(recording.readframes(frames)) != expected_size:
                raise InvalidAudioError("التسجيل الصوتي غير مكتمل.")
    except (wave.Error, EOFError, OSError) as exc:
        raise InvalidAudioError("الملف ليس تسجيل WAV PCM صالحًا.") from exc


@app.post("/transcribe", response_model=TranscribeResponse)
async def transcribe(
    file: UploadFile = File(...),
    speech: WhisperService = Depends(get_speech_service),
) -> TranscribeResponse:
    """Receive the mobile recorder's WAV as multipart field ``file``."""
    path: str | None = None
    try:
        content_type = (file.content_type or "").split(";", 1)[0].lower()
        if content_type not in {
            "audio/wav",
            "audio/x-wav",
            "audio/wave",
            "audio/vnd.wave",
            "application/octet-stream",
            "",
        }:
            raise HTTPException(status_code=415, detail="ارفع التسجيل بصيغة WAV PCM.")
        size = 0
        with tempfile.NamedTemporaryFile(
            prefix="ya-mosaed-", suffix=".wav", delete=False
        ) as output:
            path = output.name
            while chunk := await file.read(64 * 1024):
                size += len(chunk)
                if size > MAX_AUDIO_BYTES:
                    raise HTTPException(status_code=413, detail="التسجيل أكبر من الحد المسموح.")
                output.write(chunk)
        if size == 0:
            raise HTTPException(status_code=422, detail="التسجيل الصوتي فارغ.")
        await run_in_threadpool(validate_wav, path)
        text = await run_in_threadpool(speech.transcribe, path)
        return TranscribeResponse(text=text)
    except InvalidAudioError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except SpeechUnavailableError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    finally:
        await file.close()
        if path is not None:
            Path(path).unlink(missing_ok=True)
