"""WS message schema, server -> client. Client -> server sends raw binary PCM
frames plus JSON control messages; see BACKEND.md for the wire format."""
from typing import Literal

from pydantic import BaseModel


class AsrFinalMessage(BaseModel):
    type: Literal["asr_final"] = "asr_final"
    text: str
    source_language: Literal["vi", "en"]
    segment_id: int


class TranslationUpdateMessage(BaseModel):
    type: Literal["translation_update"] = "translation_update"
    text: str
    source_language: Literal["vi", "en"]
    is_final: bool
    segment_id: int


class ErrorMessage(BaseModel):
    type: Literal["error"] = "error"
    message: str


class ControlMessage(BaseModel):
    type: Literal["control"] = "control"
    action: Literal["start", "stop", "reset"]
