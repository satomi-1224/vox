import importlib.util
import io
import json
import pathlib
import sys
import threading
import unittest
from contextlib import redirect_stderr


MODULE_PATH = pathlib.Path(__file__).parents[1] / "vox_worker.py"
SPEC = importlib.util.spec_from_file_location("vox_worker", MODULE_PATH)
assert SPEC and SPEC.loader
vox_worker = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = vox_worker
SPEC.loader.exec_module(vox_worker)


class DictionaryTests(unittest.TestCase):
    def test_build_prompt_uses_preferred_spellings_once(self):
        entries = [
            {"source": "ぼっくす", "replacement": "Vox"},
            {"source": "vox", "replacement": "Vox"},
            {"source": "えむえるえっくす", "replacement": "MLX"},
        ]
        self.assertEqual(vox_worker.build_prompt(entries), "用語集（次の表記を優先）: Vox、MLX。")

    def test_apply_dictionary_is_case_insensitive_and_longest_first(self):
        entries = [
            {"source": "ML", "replacement": "machine learning"},
            {"source": "MLX", "replacement": "MLX"},
        ]
        self.assertEqual(vox_worker.apply_dictionary("mlx and ml", entries), "MLX and machine learning")

    def test_empty_entries_are_ignored(self):
        entries = [{"source": "", "replacement": "bad"}, {"source": "x", "replacement": ""}]
        self.assertIsNone(vox_worker.build_prompt(entries))
        self.assertEqual(vox_worker.apply_dictionary("text", entries), "text")


class FakeBackend:
    def __init__(self):
        self.warmed = []
        self.options = None

    def warmup(self, model):
        self.warmed.append(model)

    def transcribe(self, **kwargs):
        self.options = kwargs
        return {"text": "ぼっくす", "language": "ja"}


class WorkerTests(unittest.TestCase):
    def test_parent_watchdog_exits_when_owner_disappears(self):
        exited = threading.Event()
        exit_codes = []
        thread = vox_worker.start_parent_watchdog(
            parent_pid=123,
            interval=0.001,
            get_parent_pid=lambda: 1,
            exit_process=lambda code: (exit_codes.append(code), exited.set()),
        )
        self.assertIsNotNone(thread)
        self.assertTrue(exited.wait(timeout=0.2))
        self.assertEqual(exit_codes, [0])

    def test_transcription_reuses_warmed_model_and_applies_dictionary(self):
        fake = FakeBackend()
        backend = vox_worker.Backend(transcribe=fake.transcribe, warmup=fake.warmup)
        worker = vox_worker.Worker(
            lambda: backend,
            audio_loader=lambda _: "samples",
            silence_detector=lambda _: False,
        )
        messages = []
        worker.handle({"id": "1", "command": "warmup", "model": "test/model"}, messages.append)
        worker.handle(
            {
                "id": "2",
                "command": "transcribe",
                "model": "test/model",
                "audio_path": "/tmp/audio.wav",
                "language": "ja",
                "dictionary": [{"source": "ぼっくす", "replacement": "Vox"}],
            },
            messages.append,
        )
        self.assertEqual(fake.warmed, ["test/model"])
        self.assertEqual(
            [message.get("state") for message in messages],
            ["preparing_model", "ready", "transcribing", "ready"],
        )
        self.assertEqual(messages[-1]["text"], "Vox")
        self.assertEqual(messages[-1]["language"], "ja")
        self.assertEqual(
            fake.options["initial_prompt"],
            "用語集（次の表記を優先）: Vox。",
        )

    def test_protocol_survives_invalid_request(self):
        input_stream = io.StringIO("not json\n")
        output_stream = io.StringIO()
        with redirect_stderr(io.StringIO()):
            vox_worker.run(input_stream, output_stream)
        messages = [json.loads(line) for line in output_stream.getvalue().splitlines()]
        self.assertEqual(messages[0]["state"], "worker_ready")
        self.assertEqual(messages[1]["type"], "error")

    def test_silent_audio_skips_model_loading(self):
        def unexpected_backend():
            self.fail("silent audio must not load the model")

        worker = vox_worker.Worker(
            unexpected_backend,
            audio_loader=lambda _: "silence",
            silence_detector=lambda _: True,
        )
        messages = []
        worker.handle(
            {
                "id": "quiet",
                "command": "transcribe",
                "audio_path": "/tmp/quiet.wav",
                "language": "ja",
            },
            messages.append,
        )
        self.assertEqual(messages[-1]["text"], "")
        self.assertEqual(messages[-1]["elapsed_ms"], 0.0)


if __name__ == "__main__":
    unittest.main()
