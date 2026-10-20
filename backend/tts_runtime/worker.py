"""Private JSON-lines worker. Heavy TTS dependencies never enter the API process."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import sys
import tempfile
from pathlib import Path

DEMO_TRANSCRIPT = "ايه الكلام. بقولك ايه. استخدم صوتي في المحادثات. استخدمه هيعجبك اوي."


def split_for_synthesis(text: str, max_bytes: int = 180) -> list[str]:
    """Bound neural sequence length even when a paragraph has no punctuation."""
    chunks = []
    current = ""
    for word in text.split():
        if len(word.encode("utf-8")) > max_bytes:
            raise ValueError("A synthesis word exceeds the supported length")
        candidate = f"{current} {word}" if current else word
        if current and len(candidate.encode("utf-8")) > max_bytes:
            chunks.append(current)
            current = word
        else:
            current = candidate
    if current:
        chunks.append(current)
    return chunks


class EgyptianSynthesizer:
    def __init__(self, args: argparse.Namespace) -> None:
        from importlib.resources import files

        import numpy as np
        import soundfile as sf
        import torch
        from f5_tts.infer.utils_infer import (
            load_model,
            load_vocoder,
            preprocess_ref_audio_text,
        )
        from hydra.utils import get_class
        from omegaconf import OmegaConf

        threads = max(1, min(int(os.getenv("TTS_CPU_THREADS", "4")), 16))
        torch.set_num_threads(threads)
        torch.set_num_interop_threads(min(threads, 2))
        if args.device == "cuda" and not torch.cuda.is_available():
            raise RuntimeError("CUDA was selected but is unavailable")
        config = OmegaConf.load(str(files("f5_tts").joinpath("configs/F5TTS_v1_Base.yaml")))
        model_class = get_class(f"f5_tts.model.{config.model.backbone}")
        self.model = load_model(
            model_class,
            config.model.arch,
            args.model,
            mel_spec_type="vocos",
            vocab_file=args.vocab,
            device=args.device,
        )
        self.vocoder = load_vocoder(
            vocoder_name="vocos",
            is_local=True,
            local_path=args.vocoder,
            device=args.device,
        )
        reference = args.reference_audio or str(files("habibi_tts").joinpath("assets/EGY.mp3"))
        self.reference_text = args.reference_text or DEMO_TRANSCRIPT
        samples, rate = sf.read(reference, dtype="float32", always_2d=True)
        if not 0.5 <= len(samples) / rate <= 12:
            raise ValueError(
                "Reference audio must contain 0.5 to 12 seconds with its exact transcript"
            )
        if not np.isfinite(samples).all() or float(np.sqrt(np.mean(samples**2))) < 0.00001:
            raise ValueError("Reference audio contains no usable signal")
        # Follow the official reference silence trimming, 50 ms tail, and text
        # punctuation rules. Decode to WAV first so Windows needs no FFmpeg.
        with tempfile.TemporaryDirectory(prefix="ma3ak-reference-") as directory:
            decoded = Path(directory) / "reference.wav"
            sf.write(str(decoded), samples, rate, subtype="PCM_16")
            processed, self.reference_text = preprocess_ref_audio_text(
                str(decoded), self.reference_text, show_info=lambda _: None
            )
            try:
                samples, rate = sf.read(processed, dtype="float32", always_2d=True)
            finally:
                Path(processed).unlink(missing_ok=True)
        self.reference = (torch.from_numpy(samples.mean(axis=1)).unsqueeze(0), rate)
        self.device = args.device
        self.steps = int(os.getenv("TTS_NFE_STEPS", "32"))
        if not 8 <= self.steps <= 64:
            raise ValueError("TTS_NFE_STEPS must be between 8 and 64")

    def synthesize(self, text: str, output: Path) -> None:
        import numpy as np
        import soundfile as sf
        from habibi_tts.infer.utils_infer import infer_batch_process

        # Run one batch at a time: the upstream helper otherwise parallelizes
        # all text chunks, multiplying CPU memory and competing model calls.
        chunks = split_for_synthesis(text)
        generated = []
        for chunk in chunks:
            result = next(
                infer_batch_process(
                    self.reference,
                    self.reference_text,
                    [chunk],
                    self.model,
                    self.vocoder,
                    mel_spec_type="vocos",
                    progress=None,
                    nfe_step=self.steps,
                    device=self.device,
                    dialect_id=None,
                )
            )
            audio, rate, _ = result
            audio = np.asarray(audio, dtype=np.float32)
            if audio.ndim != 1 or not audio.size or not np.isfinite(audio).all():
                raise ValueError("Synthesis returned invalid samples")
            generated.append(audio)
        combined = np.concatenate(generated)
        if len(combined) / rate > 180:
            raise ValueError("Synthesis exceeds the audio duration limit")
        sf.write(str(output), np.clip(combined, -1, 1), rate, subtype="PCM_16", format="WAV")


def main() -> None:
    parser = argparse.ArgumentParser()
    for name in ["model", "vocab", "vocoder", "device", "output-dir"]:
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--reference-audio")
    parser.add_argument("--reference-text")
    args = parser.parse_args()
    directory = Path(args.output_dir).resolve()
    synthesizer: EgyptianSynthesizer | None = None
    for line in sys.stdin:
        request_id = None
        output = None
        try:
            if len(line) > 32 * 1024:
                raise ValueError("Request too large")
            request = json.loads(line)
            request_id = request["id"]
            text = request["text"].strip()
            if not text or len(text) > 600:
                raise ValueError("Invalid text length")
            output = Path(request["output"]).resolve()
            if output.parent != directory or output.suffix != ".wav":
                raise ValueError("Invalid output path")
            # Upstream prints reference and generated text. Keep both private;
            # stdout is reserved for our protocol and no request text is logged.
            with contextlib.redirect_stdout(io.StringIO()):
                if synthesizer is None:
                    synthesizer = EgyptianSynthesizer(args)
                synthesizer.synthesize(text, output)
            response = {"id": request_id, "ok": True}
        except Exception as error:
            if output and output.parent == directory:
                output.unlink(missing_ok=True)
            response = {"id": request_id, "ok": False, "error": type(error).__name__}
            # Error type is useful for local diagnosis without leaking speech.
            print(f"Habibi worker failed: {type(error).__name__}", file=sys.stderr, flush=True)
        print(json.dumps(response), flush=True)


if __name__ == "__main__":
    main()
