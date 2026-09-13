#!/usr/bin/env python3
"""Long-lived JSON-lines worker for MLX Whisper."""

from __future__ import annotations

import contextlib
import json
import os
import re
import sys
import threading
import time
import traceback
import wave
from dataclasses import dataclass
from typing import Any, Callable, TextIO

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"
MAX_PROMPT_CHARACTERS = 1200


def start_parent_watchdog(
    parent_pid: int | None = None,
    interval: float = 1.0,
    get_parent_pid: Callable[[], int] = os.getppid,
    exit_process: Callable[[int], None] = os._exit,
) -> threading.Thread | None:
    """Exit promptly if the owning Vox process disappears during model work."""
    expected_parent = parent_pid if parent_pid is not None else get_parent_pid()
    if expected_parent <= 1:
        return None

    def watch() -> None:
        while True:
            time.sleep(interval)
            if get_parent_pid() != expected_parent:
                exit_process(0)
                return

    thread = threading.Thread(target=watch, name="vox-parent-watchdog", daemon=True)
    thread.start()
    return thread


def _clean_entries(entries: Any) -> list[dict[str, str]]:
    if not isinstance(entries, list):
        return []
    cleaned: list[dict[str, str]] = []
    for entry in entries[:200]:
        if not isinstance(entry, dict):
            continue
        source = str(entry.get("source", "")).strip()
        replacement = str(entry.get("replacement", "")).strip()
        if source and replacement:
            cleaned.append({"source": source, "replacement": replacement})
    return cleaned


def build_prompt(entries: Any) -> str | None:
    """Build a compact Whisper prompt containing preferred spellings."""
    cleaned = _clean_entries(entries)
    if not cleaned:
        return None
    preferred = list(dict.fromkeys(entry["replacement"] for entry in cleaned))
    prompt = "用語集（次の表記を優先）: " + "、".join(preferred) + "。"
    return prompt[:MAX_PROMPT_CHARACTERS]


def apply_dictionary(text: str, entries: Any) -> str:
    """Apply explicit corrections after recognition, longest source first."""
    cleaned = sorted(_clean_entries(entries), key=lambda item: len(item["source"]), reverse=True)
    if not cleaned:
        return text.strip()

    replacements: dict[str, str] = {}
    sources: list[str] = []
    for entry in cleaned:
        key = entry["source"].casefold()
        if key not in replacements:
            replacements[key] = entry["replacement"]
            sources.append(entry["source"])

    # A single substitution pass prevents one replacement from being matched by
    # another dictionary entry (for example, ML -> ... after mlx -> MLX).
    pattern = re.compile("|".join(re.escape(source) for source in sources), flags=re.IGNORECASE)
    return pattern.sub(lambda match: replacements[match.group(0).casefold()], text).strip()


def load_pcm_wav(path: str) -> Any:
    """Load Vox's PCM WAV directly, without starting an FFmpeg process."""
    import numpy as np

    with wave.open(path, "rb") as audio_file:
        channels = audio_file.getnchannels()
        sample_width = audio_file.getsampwidth()
        sample_rate = audio_file.getframerate()
        frames = audio_file.readframes(audio_file.getnframes())

    if sample_width != 2:
        raise ValueError(f"unsupported WAV sample width: {sample_width * 8} bit")
    samples = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1, dtype=np.float32)
    if sample_rate != 16_000 and samples.size:
        output_size = max(1, round(samples.size * 16_000 / sample_rate))
        old_positions = np.arange(samples.size, dtype=np.float64)
        new_positions = np.linspace(0, samples.size - 1, output_size, dtype=np.float64)
        samples = np.interp(new_positions, old_positions, samples).astype(np.float32)
    return samples


def audio_is_silent(samples: Any) -> bool:
    """Reject empty/near-silent captures before Whisper can hallucinate text."""
    import numpy as np

    array = np.asarray(samples, dtype=np.float32)
    if array.size < 1_600:  # Less than 100 ms at 16 kHz.
        return True
    peak = float(np.max(np.abs(array)))
    rms = float(np.sqrt(np.mean(np.square(array), dtype=np.float64)))
    return rms < 0.0015 and peak < 0.012


@dataclass
class Backend:
    transcribe: Callable[..., dict[str, Any]]
    warmup: Callable[[str], None]


def load_backend() -> Backend:
    # Keep imports lazy so protocol and dictionary tests do not require MLX.
    with contextlib.redirect_stdout(sys.stderr):
        import mlx.core as mx
        import mlx_whisper
        from mlx_whisper.transcribe import ModelHolder

    def warmup(model: str) -> None:
        with contextlib.redirect_stdout(sys.stderr):
            ModelHolder.get_model(model, mx.float16)

    def transcribe(**kwargs: Any) -> dict[str, Any]:
        with contextlib.redirect_stdout(sys.stderr):
            return mlx_whisper.transcribe(**kwargs)

    return Backend(transcribe=transcribe, warmup=warmup)


class Worker:
    def __init__(
        self,
        backend_loader: Callable[[], Backend] = load_backend,
        audio_loader: Callable[[str], Any] = load_pcm_wav,
        silence_detector: Callable[[Any], bool] = audio_is_silent,
    ) -> None:
        self._backend_loader = backend_loader
        self._audio_loader = audio_loader
        self._silence_detector = silence_detector
        self._backend: Backend | None = None
        self._loaded_model: str | None = None

    def _backend_instance(self) -> Backend:
        if self._backend is None:
            self._backend = self._backend_loader()
        return self._backend

    def warmup(self, model: str) -> None:
        if self._loaded_model == model:
            return
        self._backend_instance().warmup(model)
        self._loaded_model = model

    def handle(self, request: dict[str, Any], emit: Callable[[dict[str, Any]], None]) -> None:
        request_id = str(request.get("id", ""))
        command = request.get("command")
        model = str(request.get("model") or DEFAULT_MODEL)

        if command == "warmup":
            if self._loaded_model != model:
                emit({"id": request_id, "type": "status", "state": "preparing_model"})
            self.warmup(model)
            emit({"id": request_id, "type": "result", "state": "ready"})
            return

        if command != "transcribe":
            raise ValueError(f"unknown command: {command!r}")

        audio_path = request.get("audio_path")
        if not isinstance(audio_path, str) or not audio_path:
            raise ValueError("audio_path is required")

        entries = request.get("dictionary")
        audio = self._audio_loader(audio_path)
        if self._silence_detector(audio):
            emit(
                {
                    "id": request_id,
                    "type": "result",
                    "state": "ready",
                    "text": "",
                    "language": request.get("language"),
                    "elapsed_ms": 0.0,
                }
            )
            return

        if self._loaded_model != model:
            emit({"id": request_id, "type": "status", "state": "preparing_model"})
        self.warmup(model)
        emit({"id": request_id, "type": "status", "state": "transcribing"})
        options: dict[str, Any] = {
            "audio": audio,
            "path_or_hf_repo": model,
            "verbose": None,
            "temperature": 0.0,
            "condition_on_previous_text": False,
            "word_timestamps": False,
            "task": "transcribe",
            "fp16": True,
        }
        language = request.get("language")
        if isinstance(language, str) and language:
            options["language"] = language
        prompt = build_prompt(entries)
        if prompt:
            options["initial_prompt"] = prompt

        started = time.perf_counter()
        result = self._backend_instance().transcribe(**options)
        elapsed_ms = (time.perf_counter() - started) * 1000
        text = apply_dictionary(str(result.get("text", "")), entries)
        emit(
            {
                "id": request_id,
                "type": "result",
                "state": "ready",
                "text": text,
                "language": result.get("language"),
                "elapsed_ms": round(elapsed_ms, 1),
            }
        )


def run(input_stream: TextIO = sys.stdin, output_stream: TextIO = sys.stdout) -> None:
    worker = Worker()

    def emit(payload: dict[str, Any]) -> None:
        output_stream.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
        output_stream.flush()

    emit({"type": "status", "state": "worker_ready"})
    for line in input_stream:
        line = line.strip()
        if not line:
            continue
        request_id = ""
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("request must be a JSON object")
            request_id = str(request.get("id", ""))
            worker.handle(request, emit)
        except Exception as error:  # Keep the worker alive after a bad request.
            traceback.print_exc(file=sys.stderr)
            emit({"id": request_id, "type": "error", "message": str(error)})


if __name__ == "__main__":
    start_parent_watchdog()
    run()
