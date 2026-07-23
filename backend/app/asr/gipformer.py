"""Gipformer ASR wrapper via sherpa-onnx OfflineRecognizer.

Offline (whole-segment) transcription only — Gipformer's README does not confirm
a streaming/causal export, and the repo's own infer_onnx.py example uses the
offline sherpa-onnx pattern. See BACKEND.md "ASR Mode Decision" for the
streaming upgrade path if that changes.
"""
import logging

import numpy as np
import sherpa_onnx

from app import config

log = logging.getLogger(__name__)


class GipformerASR:
    def __init__(self) -> None:
        log.info("Loading Gipformer ASR (vi) from %s", config.GIPFORMER_MODEL_DIR)
        self._recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=str(config.GIPFORMER_ENCODER),
            decoder=str(config.GIPFORMER_DECODER),
            joiner=str(config.GIPFORMER_JOINER),
            tokens=str(config.GIPFORMER_TOKENS),
            num_threads=config.GIPFORMER_NUM_THREADS,
            sample_rate=config.SAMPLE_RATE,
            feature_dim=80,
            decoding_method=config.GIPFORMER_DECODING_METHOD,
        )
        log.info("Gipformer ASR loaded")

    def transcribe(self, pcm_f32: np.ndarray) -> str:
        """pcm_f32: mono float32 samples in [-1, 1] at config.SAMPLE_RATE."""
        stream = self._recognizer.create_stream()
        stream.accept_waveform(config.SAMPLE_RATE, pcm_f32)
        self._recognizer.decode_stream(stream)
        text = stream.result.text.strip()
        return _normalize_case(text)


def _normalize_case(text: str) -> str:
    """Gipformer's vocabulary is uppercase-only (trained that way — see
    models/gipformer/tokens.txt), so raw output is always ALL CAPS. Lowercase
    it before it reaches the translation prompt: the uppercase VI text was
    priming the LLM to mirror shouting-case into its English output too."""
    if not text:
        return text
    lowered = text.lower()
    return lowered[0].upper() + lowered[1:]
