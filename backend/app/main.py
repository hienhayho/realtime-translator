"""FastAPI app: WS endpoint wiring VAD -> dual ASR (Gipformer vi + Whisper en)
-> Bonsai bilingual translation.

Client sends binary PCM16 mono @16kHz frames plus JSON control messages.
Server pushes JSON messages back (see app/ws/protocol.py). See BACKEND.md
"Bilingual Transcription".
"""
import asyncio
import json
import logging
import time
from contextlib import asynccontextmanager

import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from app import config
from app.asr.gipformer import GipformerASR
from app.asr.whisper import WhisperASR
from app.audio.buffer import SegmentBuffer
from app.audio.vad import WINDOW_SAMPLES, SpeechSegmenter
from app.logging_config import configure_logging
from app.translate.bonsai import BonsaiTranslator
from app.translate.session_state import SessionState
from app.ws.protocol import AsrFinalMessage, ErrorMessage, TranslationUpdateMessage

configure_logging()
log = logging.getLogger(__name__)

_vi_asr = GipformerASR()
_en_asr = WhisperASR()
_translator = BonsaiTranslator()


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield
    await _translator.aclose()


app = FastAPI(lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, str]:
    """Polled by the Swift app's BackendProcessManager. A 200 here means ASR
    models already finished loading (they load eagerly at module import
    time, before this route is even reachable)."""
    return {"status": "ok"}


def _pcm16_bytes_to_f32(data: bytes) -> np.ndarray:
    return np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0


@app.websocket("/ws")
async def translate_session(ws: WebSocket) -> None:
    await ws.accept()

    segmenter = SpeechSegmenter()
    seg_buffer = SegmentBuffer()
    session = SessionState()
    listening = False
    pending_window = np.empty(0, dtype=np.float32)

    async def handle_segment_end() -> None:
        pcm = seg_buffer.flush()
        if pcm.size == 0:
            return
        segment_id = session.next_segment_id
        duration_s = pcm.size / config.SAMPLE_RATE
        started = time.monotonic()
        log.info("Segment %d: processing %.2fs of audio", segment_id, duration_s)

        vi_text, en_text = await asyncio.gather(
            asyncio.to_thread(_vi_asr.transcribe, pcm),
            asyncio.to_thread(_en_asr.transcribe, pcm),
        )
        if not vi_text and not en_text:
            log.info("Segment %d: both ASR outputs empty, dropping", segment_id)
            return

        result = await _translator.translate(vi_text, en_text, context=session.recent_context())
        source_text = vi_text if result.source_language == "vi" else en_text
        if not source_text:
            log.info(
                "Segment %d: LLM picked source_language=%s but that ASR output was empty, dropping",
                segment_id,
                result.source_language,
            )
            return

        elapsed_s = time.monotonic() - started
        log.info(
            "Segment %d: done in %.2fs (source_language=%s, %d chars -> %d chars)",
            segment_id,
            elapsed_s,
            result.source_language,
            len(source_text),
            len(result.translated_text),
        )
        await ws.send_json(
            AsrFinalMessage(
                text=source_text,
                source_language=result.source_language,
                segment_id=segment_id,
            ).model_dump()
        )

        session.lock(result.source_language, source_text, result.translated_text)

        await ws.send_json(
            TranslationUpdateMessage(
                text=result.translated_text,
                source_language=result.source_language,
                is_final=True,
                segment_id=segment_id,
            ).model_dump()
        )

    try:
        while True:
            message = await ws.receive()

            if "bytes" in message and message["bytes"] is not None:
                if not listening:
                    continue
                pending_window = np.concatenate([pending_window, _pcm16_bytes_to_f32(message["bytes"])])
                while pending_window.size >= WINDOW_SAMPLES:
                    window, pending_window = pending_window[:WINDOW_SAMPLES], pending_window[WINDOW_SAMPLES:]
                    seg_buffer.append(window)
                    event = segmenter.process_window(window)
                    if event == "end":
                        if segmenter.in_speech:
                            log.info("Segment %d: force-cut at %dms (no pause detected)", session.next_segment_id, config.VAD_MAX_SEGMENT_MS)
                        await handle_segment_end()

            elif "text" in message and message["text"] is not None:
                payload = json.loads(message["text"])
                if payload.get("type") != "control":
                    continue
                action = payload.get("action")
                if action == "start":
                    listening = True
                elif action == "stop":
                    listening = False
                    if segmenter.in_speech:
                        await handle_segment_end()
                elif action == "reset":
                    listening = False
                    segmenter.reset()
                    seg_buffer.flush()
                    session.reset()
                    pending_window = np.empty(0, dtype=np.float32)

    except WebSocketDisconnect:
        pass
    except Exception as exc:  # noqa: BLE001 — surface unexpected errors to client before dropping
        try:
            await ws.send_json(ErrorMessage(message=str(exc)).model_dump())
        except Exception:  # noqa: BLE001
            pass
