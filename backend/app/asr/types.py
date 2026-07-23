"""ASR result types. Offline recognizer emits only finalized segment text — no partials."""
from dataclasses import dataclass


@dataclass(frozen=True)
class FinalResult:
    segment_id: int
    text: str
