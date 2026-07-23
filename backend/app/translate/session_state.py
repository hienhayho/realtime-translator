"""Per-WS-session segment history. Tracks segment_id sequencing and keeps a
record of what's been sent — also the source of rolling translation context
fed back into the LLM prompt, see BACKEND.md "Core Design: Standalone
Per-Segment Translation" (now revisited at 9B scale) and bonsai.py."""
from dataclasses import dataclass, field

# How many prior locked segments' translated_text to feed back as context.
# See BACKEND.md — context was dropped entirely at 4B (caused echo/duplication),
# revisited at 9B. Kept at 1 (not 2+) to minimize the model's surface area for
# echoing context instead of translating the new segment — still observed at
# 9B with 2 lines of context, even after fixing the separate llama-server
# prompt-caching bug (--no-cache-prompt). See BACKEND.md "Core Design".
CONTEXT_WINDOW = 1


@dataclass
class LockedSegment:
    segment_id: int
    source_language: str  # "vi" or "en"
    source_text: str
    translated_text: str


@dataclass
class SessionState:
    locked: list[LockedSegment] = field(default_factory=list)
    next_segment_id: int = 0

    def lock(self, source_language: str, source_text: str, translated_text: str) -> int:
        segment_id = self.next_segment_id
        self.locked.append(
            LockedSegment(segment_id, source_language, source_text, translated_text)
        )
        self.next_segment_id += 1
        return segment_id

    def recent_context(self) -> list[str]:
        """Last CONTEXT_WINDOW locked segments' translated_text, oldest first —
        kept flowing across a source-language switch (e.g. two speakers of
        different languages), not reset per language."""
        if not self.locked:
            return []
        return [seg.translated_text for seg in self.locked[-CONTEXT_WINDOW:]]

    def reset(self) -> None:
        self.locked.clear()
        self.next_segment_id = 0
