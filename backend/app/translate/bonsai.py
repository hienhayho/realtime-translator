"""HTTP client for local llama-server (OpenAI-compatible), serving Qwen3.5-9B.

We do not embed llama.cpp in this process. llama-server runs as a separate
process (see BACKEND.md "Model Setup"); this client just calls its
/v1/chat/completions endpoint. Filename kept as bonsai.py from the earlier
Bonsai-8B setup.

Bilingual mode: every segment is transcribed by both Gipformer (vi) and
Whisper tiny.en (en) in parallel — see app/asr/bilingual.py. Whichever ASR
ran on the wrong-language audio tends to emit garbage/empty text, so this
client sends BOTH raw transcripts to the LLM and lets it pick the real one
(source_language) and translate into the other language (translated_text).
Constrained via response_format/json_schema (grammar-backed on llama-server's
side, not just prompt-asked) so the output is always valid JSON matching the
schema below. See BACKEND.md "Bilingual Transcription".

Rolling context: optionally takes the last few locked translations, purely
for pronoun/terminology/topic continuity. At 4B this caused the model to
echo/duplicate context into its output instead of translating the new
segment — see BACKEND.md "Core Design" — so the prompt below explicitly
labels context as reference-only and repeats "do not translate or repeat
the context" right next to where it's inserted. Revisit if this recurs on
the current (9B) model.
"""
import json
import logging
import re

import httpx

from app import config

log = logging.getLogger(__name__)

_THINK_TAG_RE = re.compile(r"<think>.*?</think>", re.DOTALL)

_SYSTEM_PROMPT = (
    "You are a real-time bilingual Vietnamese<->English transcription "
    "disambiguator and translator. You receive two automatic speech "
    "recognition (ASR) outputs for the SAME audio segment: one from a "
    "Vietnamese-only ASR model, one from an English-only ASR model. Exactly "
    "one of them is a real transcript of the actual speech; the other is "
    "from the wrong-language model and will usually be empty, nonsensical, "
    "or garbled. Decide which one is real (source_language), then translate "
    "that real transcript into the OTHER language (translated_text) — if "
    "source_language is 'vi', translated_text must be English; if "
    "source_language is 'en', translated_text must be Vietnamese. You may "
    "also receive a few prior translated lines as CONTEXT — that is "
    "reference only, for keeping pronouns/terminology/topic consistent. "
    "NEVER translate, repeat, summarize, or continue the context — only "
    "ever translate the new ASR output for THIS segment. Output nothing but "
    "the JSON object — no notes, no explanations."
)

_RESPONSE_SCHEMA = {
    "type": "json_schema",
    "json_schema": {
        "name": "bilingual_translation",
        "strict": True,
        "schema": {
            "type": "object",
            "properties": {
                "source_language": {"type": "string", "enum": ["vi", "en"]},
                "translated_text": {"type": "string"},
            },
            "required": ["source_language", "translated_text"],
            "additionalProperties": False,
        },
    },
}


class BilingualResult:
    def __init__(self, source_language: str, translated_text: str) -> None:
        self.source_language = source_language
        self.translated_text = translated_text


class BonsaiTranslator:
    def __init__(self) -> None:
        log.info("Translator client targeting llama-server at %s", config.LLM_CHAT_ENDPOINT)
        self._client = httpx.AsyncClient(timeout=config.LLM_REQUEST_TIMEOUT_S)

    async def translate(
        self, vi_asr_text: str, en_asr_text: str, context: list[str] | None = None
    ) -> BilingualResult:
        context_block = ""
        if context:
            lines = "\n".join(f"- {line!r}" for line in context)
            context_block = (
                f"CONTEXT (reference only, do NOT translate, repeat, or continue this "
                f"— it is from EARLIER segments, already handled):\n{lines}\n\n"
                f"---\n\n"
            )
        user_content = (
            f"{context_block}"
            f"NEW SEGMENT TO TRANSLATE NOW (ignore everything above, translate only this):\n"
            f"Vietnamese ASR output: {vi_asr_text!r}\n"
            f"English ASR output: {en_asr_text!r}"
        )
        response = await self._client.post(
            config.LLM_CHAT_ENDPOINT,
            json={
                "messages": [
                    {"role": "system", "content": _SYSTEM_PROMPT},
                    {"role": "user", "content": user_content},
                ],
                "temperature": config.LLM_TEMPERATURE,
                "top_p": config.LLM_TOP_P,
                "max_tokens": config.LLM_MAX_TOKENS,
                "response_format": _RESPONSE_SCHEMA,
            },
        )
        response.raise_for_status()
        data = response.json()
        content = data["choices"][0]["message"]["content"]
        # Defensive: strip any <think>...</think> reasoning block in case
        # enable_thinking:false doesn't fully suppress it for this model/template.
        content = _THINK_TAG_RE.sub("", content).strip()
        parsed = json.loads(content)
        return BilingualResult(
            source_language=parsed["source_language"],
            translated_text=parsed["translated_text"].strip(),
        )

    async def aclose(self) -> None:
        await self._client.aclose()
