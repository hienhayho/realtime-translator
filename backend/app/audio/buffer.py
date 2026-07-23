"""Rolling PCM accumulator for one WS session's in-progress speech segment."""
import numpy as np


class SegmentBuffer:
    def __init__(self) -> None:
        self._chunks: list[np.ndarray] = []

    def append(self, pcm_f32: np.ndarray) -> None:
        self._chunks.append(pcm_f32)

    def is_empty(self) -> bool:
        return not self._chunks

    def flush(self) -> np.ndarray:
        """Return concatenated audio and reset the buffer."""
        if not self._chunks:
            return np.empty(0, dtype=np.float32)
        merged = np.concatenate(self._chunks)
        self._chunks.clear()
        return merged
