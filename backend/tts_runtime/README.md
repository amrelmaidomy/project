# Habibi Egyptian runtime

This isolated Python environment keeps F5/Habibi's Torch, NumPy and Pydantic
requirements separate from the FastAPI/Whisper environment. Install its locked
CPU dependencies from the repository root:

```sh
uv sync --project backend/tts_runtime --frozen --no-dev --python 3.12
```

The lock includes PyTorch and torchaudio CPU wheels. The Windows setup script's
`-UseCuda` option prepares the separately locked `cuda/` runtime and selects its
Python executable. GPU inference must still be checked on the target laptop.

The API's `HabibiService` starts `worker.py` lazily and communicates over a private
JSON-lines pipe. One request runs at a time, with a two-second maximum busy wait
and a 300-second synthesis deadline. Timeout or service shutdown terminates the
worker. Audio is PCM16 WAV, validated by the API and removed from disk after the
response is read. Up to eight small replies can remain in memory as a bounded
cache; speech text and reference text are not logged.

## Local assets

With `MA3AK_MODELS_DIR` set, expected files are:

```text
<MA3AK_MODELS_DIR>/habibi-egyptian/
  model_100000.safetensors
  vocab.txt
  vocos/
    config.yaml
    pytorch_model.bin
```

Without that variable, the model directory defaults to
`~/TTSModels/Habibi-Egyptian`. A manually downloaded checkpoint under
`Specialized/EGY/` is also discovered. Overrides:

- `TTS_MODEL_PATH`: checkpoint file or directory.
- `TTS_VOCAB_PATH`: its matching Egyptian vocabulary file.
- `TTS_VOCODER_PATH`: local Vocos directory.
- `TTS_PYTHON`: the isolated runtime's Python executable.
- `TTS_DEVICE`: `cpu` by default.
- `TTS_TIMEOUT_SECONDS`: `300` by default.
- `TTS_CPU_THREADS`: `4` by default, limited to 1–16.
- `TTS_NFE_STEPS`: the upstream default of `32`, limited to 8–64. Reducing this
  value can reduce speech intelligibility; the runtime keeps float32 on CPU.
- `TTS_REFERENCE_AUDIO` and `TTS_REFERENCE_TEXT`: an optional custom reference
  recording and its exact transcript. Both must be supplied together.

The worker does not download missing assets. Its model loading uses local
files with Hugging Face and Transformers offline mode enabled.
Reference decoding uses soundfile, followed by the official silence trimming,
50 ms audio tail and transcript punctuation rules. Windows does not need an
FFmpeg executable for this path.

## Reference voice and sources

The default reference is `habibi_tts/assets/EGY.mp3`, distributed inside the
official `habibi-tts==0.1.1` package. Its published transcript is:

> ايه الكلام. بقولك ايه. استخدم صوتي في المحادثات. استخدمه هيعجبك اوي.

The authors identify that reference as an ElevenLabs voice-library demonstration
in their [asset documentation](https://github.com/SWivid/Habibi-TTS/blob/main/src/habibi_tts/assets/README.md).
It is used as an explicitly labelled demo reference; no audio copy is committed
or rehosted by this project. To use another voice, configure a reference recording
you can use, between 0.5 and 12 seconds, with its exact transcript.

The Egyptian specialized checkpoint and vocabulary come from
[`SWivid/Habibi-TTS`](https://huggingface.co/SWivid/Habibi-TTS/tree/3ad11a152851245c002156526c5e1d0b12f2b9d5/Specialized/EGY),
revision `3ad11a152851245c002156526c5e1d0b12f2b9d5`. The authors release that
specialized model under Apache 2.0. The runtime follows the official specialized
inference path, using the matching checkpoint/vocabulary and no unified-model
dialect embedding. Vocos is loaded from a separately prepared local directory.

## Validation and performance

The pinned CPU runtime was installed and used for real local inference with the
verified Egyptian checkpoint and Vocos files. On a cloud machine limited to four
CPU cores, a cold 32-step float32 generation took 201.85 seconds for 3.979 seconds
of speech. A Whisper large-v3-turbo round trip recovered the main reply
`أنا رفيق قولي أذكرك بإيه` from `أهلا بيك. أنا رفيق. قول لي أذكرك بإيه؟`,
but omitted the opening greeting. This is an automatic check, not a listening
assessment. An eight-step quantized experiment lost words and is not used.

CPU conversation can therefore pause for several minutes, and longer replies
may exceed the 300-second deadline. CUDA performance and memory use on the
Quadro T2000 4 GB remain to be tested on the target laptop.
