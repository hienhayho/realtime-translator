"""Whisper base.en ASR wrapper via sherpa-onnx OfflineRecognizer.

English-only decode (language="en" fixed, no lang-detect overhead) — this
model always runs alongside Gipformer per segment (see app/asr/bilingual.py),
the LLM picks which transcript is real. See BACKEND.md "Bilingual Transcription".
"""
import logging

import numpy as np
import sherpa_onnx

from app import config

log = logging.getLogger(__name__)


class WhisperASR:
    def __init__(self) -> None:
        log.info("Loading Whisper base.en ASR (en) from %s", config.WHISPER_MODEL_DIR)
        self._recognizer = sherpa_onnx.OfflineRecognizer.from_whisper(
            encoder=str(config.WHISPER_ENCODER),
            decoder=str(config.WHISPER_DECODER),
            tokens=str(config.WHISPER_TOKENS),
            language="en",
            task="transcribe",
            num_threads=config.WHISPER_NUM_THREADS,
        )
        log.info("Whisper base.en ASR loaded")

    def transcribe(self, pcm_f32: np.ndarray) -> str:
        """pcm_f32: mono float32 samples in [-1, 1] at config.SAMPLE_RATE."""
        stream = self._recognizer.create_stream()
        stream.accept_waveform(config.SAMPLE_RATE, pcm_f32)
        self._recognizer.decode_stream(stream)
        return stream.result.text.strip()
