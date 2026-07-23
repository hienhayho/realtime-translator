"""Silero VAD wrapper: turns a raw PCM stream into speech-segment start/end events.

Confirmed API (silero-vad PyPI package): load_silero_vad(), VADIterator(model, sampling_rate=...),
fixed-size window (512 samples @ 16kHz), returns {"start": t} / {"end": t} dicts on state transitions.
"""
import numpy as np
from silero_vad import VADIterator, load_silero_vad

from app import config

WINDOW_SAMPLES = 512  # required window size for silero-vad at 16kHz
_WINDOW_MS = WINDOW_SAMPLES / config.SAMPLE_RATE * 1000


class SpeechSegmenter:
    """Feed PCM in WINDOW_SAMPLES-sized chunks; get told when a segment starts/ends.

    Also force-cuts a segment at VAD_MAX_SEGMENT_MS of continuous speech even
    if Silero hasn't detected a pause — see config.py. The forced cut is a
    segment boundary on our side only; Silero's own start/end state isn't
    reset, so if the speaker is still talking, the very next window is
    immediately "in speech" again for the next segment (no re-trigger needed).
    """

    def __init__(self) -> None:
        model = load_silero_vad()
        self._vad = VADIterator(
            model,
            sampling_rate=config.SAMPLE_RATE,
            threshold=config.VAD_THRESHOLD,
            min_silence_duration_ms=config.VAD_MIN_SILENCE_MS,
        )
        self._in_speech = False
        self._speech_ms = 0.0

    def process_window(self, pcm_f32: np.ndarray) -> str | None:
        """pcm_f32 must be exactly WINDOW_SAMPLES samples. Returns 'start', 'end', or None."""
        event = self._vad(pcm_f32, return_seconds=False)

        if event is not None and "start" in event:
            self._in_speech = True
            self._speech_ms = _WINDOW_MS
            return "start"

        if event is not None and "end" in event:
            self._in_speech = False
            self._speech_ms = 0.0
            return "end"

        if self._in_speech:
            self._speech_ms += _WINDOW_MS
            if self._speech_ms >= config.VAD_MAX_SEGMENT_MS:
                self._speech_ms = 0.0
                return "end"

        return None

    @property
    def in_speech(self) -> bool:
        return self._in_speech

    def reset(self) -> None:
        self._vad.reset_states()
        self._in_speech = False
        self._speech_ms = 0.0
