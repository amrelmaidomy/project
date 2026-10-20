#!/usr/bin/env python3
"""Exercise real speech endpoints; save a WAV for a human listening check."""

from __future__ import annotations

import argparse
import io
import json
import time
import uuid
import wave
from pathlib import Path
from urllib.request import Request, urlopen


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    parser.add_argument(
        "--audio", type=Path, help="Optional real PCM WAV to transcribe first."
    )
    parser.add_argument("--text", default="أهلا بيك. أنا رفيق. قول لي أذكرك بإيه؟")
    parser.add_argument("--output", type=Path, default=Path("dist/habibi-reply.wav"))
    args = parser.parse_args()
    base_url = args.base_url.rstrip("/")

    def request(
        path: str, body: bytes | None = None, content_type: str = "application/json"
    ):
        started = time.monotonic()
        req = Request(
            base_url + path, data=body, headers={"Content-Type": content_type}
        )
        with urlopen(req, timeout=330) as response:
            data = response.read()
        print(f"{path}: {time.monotonic() - started:.2f}s")
        return data

    print(request("/health").decode("utf-8"))
    if args.audio:
        boundary = "ma3ak-" + uuid.uuid4().hex
        body = (
            (
                f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="sample.wav"\r\n'
                "Content-Type: audio/wav\r\n\r\n"
            ).encode()
            + args.audio.read_bytes()
            + f"\r\n--{boundary}--\r\n".encode()
        )
        result = request(
            "/transcribe", body, f"multipart/form-data; boundary={boundary}"
        )
        print("Transcript:", json.loads(result)["text"])
    audio = request("/synthesize", json.dumps({"text": args.text}).encode("utf-8"))
    with wave.open(io.BytesIO(audio)) as recording:
        if recording.getnchannels() != 1 or recording.getsampwidth() != 2:
            raise SystemExit("Expected mono PCM16 WAV.")
        print(
            f"WAV: {recording.getframerate()}Hz, {recording.getnframes() / recording.getframerate():.2f}s"
        )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(audio)
    print("Saved:", args.output.resolve())
    print(request("/health").decode("utf-8"))
    print(
        "Listen to the WAV to assess pronunciation; HTTP success alone does not verify the spoken words."
    )


if __name__ == "__main__":
    main()
