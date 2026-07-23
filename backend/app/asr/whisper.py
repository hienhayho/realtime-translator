"""Whisper ASR wrapper via sherpa-onnx OfflineRecognizer.

English-only decode (language="en" fixed, no lang-detect overhead) — this
model always runs alongside Gipformer per segment (see app/asr/bilingual.py),
the LLM picks which transcript is real. See BACKEND.md "Bilingual Transcription".
Tier (tiny.en/base.en/medium.en) is selectable via WHISPER_TIER env var, see
config.py.
"""
import logging

import numpy as np
import sherpa_onnx

from app import config

log = logging.getLogger(__name__)


class WhisperASR:
    def __init__(self) -> None:
        log.info("Loading Whisper %s ASR (en) from %s", config.WHISPER_TIER, config.WHISPER_MODEL_DIR)
        self._recognizer = sherpa_onnx.OfflineRecognizer.from_whisper(
            encoder=str(config.WHISPER_ENCODER),
            decoder=str(config.WHISPER_DECODER),
            tokens=str(config.WHISPER_TOKENS),
            language="en",
            task="transcribe",
            num_threads=config.WHISPER_NUM_THREADS,
        )
        log.info("Whisper %s ASR loaded", config.WHISPER_TIER)

    def transcribe(self, pcm_f32: np.ndarray) -> str:
        """pcm_f32: mono float32 samples in [-1, 1] at config.SAMPLE_RATE."""
        stream = self._recognizer.create_stream()
        stream.accept_waveform(config.SAMPLE_RATE, pcm_f32)
        self._recognizer.decode_stream(stream)
        return stream.result.text.strip()
