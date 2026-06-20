#!/usr/bin/env python3
"""Tests for file_transcription_worker.py — no real model required.

Run: python3 scripts/tests/test_file_transcription_worker.py
"""

from __future__ import annotations

import io
import json
import sys
import types
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))

import file_transcription_worker as worker  # noqa: E402


class FakeResult:
    def __init__(self, text, language="Cantonese", truncated=False):
        self.text = text
        self.language = language
        self.truncated = truncated


def fake_transcribe_factory(text_by_input=None, fail_inputs=None, emit_progress=True):
    text_by_input = text_by_input or {}
    fail_inputs = fail_inputs or set()

    def fake_transcribe(audio, *, model, context, language, return_timestamps,
                        diarize, return_chunks, verbose, on_progress):
        assert return_timestamps is False and diarize is False and return_chunks is False
        if audio in fail_inputs:
            raise RuntimeError("boom")
        if emit_progress and on_progress:
            on_progress({"event": "chunk_completed", "chunk_index": 1, "total_chunks": 2,
                         "progress": 0.5, "processed_audio_sec": 5.0, "audio_duration_sec": 10.0})
            on_progress({"event": "chunk_completed", "chunk_index": 2, "total_chunks": 2,
                         "progress": 1.0, "processed_audio_sec": 10.0, "audio_duration_sec": 10.0})
        return FakeResult(text_by_input.get(audio, "你好世界"))

    return fake_transcribe


def parse_jsonl(output: str):
    events = []
    for line in output.splitlines():
        if not line.strip():
            continue
        events.append(json.loads(line))  # raises if any non-JSON line on stdout
    return events


class ManifestTests(unittest.TestCase):
    def test_rejects_empty(self):
        with TemporaryDirectory() as d:
            p = Path(d) / "m.json"
            p.write_text(json.dumps({"version": 1, "files": []}), encoding="utf-8")
            with self.assertRaises(ValueError):
                worker.load_manifest(p)

    def test_rejects_missing_fields(self):
        with TemporaryDirectory() as d:
            p = Path(d) / "m.json"
            p.write_text(json.dumps({"files": [{"id": "a"}]}), encoding="utf-8")
            with self.assertRaises(ValueError):
                worker.load_manifest(p)


class RunTests(unittest.TestCase):
    def _make_input(self, d: Path, name: str) -> Path:
        wav = d / name
        wav.write_bytes(b"RIFFfake")
        return wav

    def test_emits_only_jsonl_and_writes_output(self):
        with TemporaryDirectory() as d:
            d = Path(d)
            wav = self._make_input(d, "a.wav")
            out = d / "a-transcript.txt"
            files = [{"id": "a", "input_wav": str(wav), "output_txt": str(out)}]
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = worker.run(files, "context", model=object(),
                                transcribe=fake_transcribe_factory({str(wav): "廣東話"}),
                                traditional=False)
            self.assertEqual(rc, 0)
            events = parse_jsonl(buf.getvalue())  # all lines valid JSON
            kinds = [e["event"] for e in events]
            self.assertEqual(kinds[0], "worker_ready")
            self.assertIn("file_started", kinds)
            self.assertIn("asr_progress", kinds)
            self.assertEqual(kinds[-1], "batch_completed")
            self.assertTrue(out.is_file())
            self.assertEqual(out.read_text(encoding="utf-8"), "廣東話")

    def test_progress_monotonic_and_bounded(self):
        with TemporaryDirectory() as d:
            d = Path(d)
            wav = self._make_input(d, "a.wav")
            files = [{"id": "a", "input_wav": str(wav), "output_txt": str(d / "o.txt")}]
            buf = io.StringIO()
            with redirect_stdout(buf):
                worker.run(files, "", model=object(), transcribe=fake_transcribe_factory(), traditional=False)
            progresses = [e["progress"] for e in parse_jsonl(buf.getvalue()) if e["event"] == "asr_progress"]
            self.assertTrue(progresses)
            self.assertEqual(progresses, sorted(progresses))
            self.assertGreaterEqual(progresses[0], 0.0)
            self.assertLessEqual(progresses[-1], 1.0)

    def test_bad_file_emits_failed_and_continues(self):
        with TemporaryDirectory() as d:
            d = Path(d)
            good1 = self._make_input(d, "g1.wav")
            bad = self._make_input(d, "bad.wav")
            good2 = self._make_input(d, "g2.wav")
            files = [
                {"id": "1", "input_wav": str(good1), "output_txt": str(d / "1.txt")},
                {"id": "2", "input_wav": str(bad), "output_txt": str(d / "2.txt")},
                {"id": "3", "input_wav": str(good2), "output_txt": str(d / "3.txt")},
            ]
            buf = io.StringIO()
            with redirect_stdout(buf):
                worker.run(files, "", model=object(),
                           transcribe=fake_transcribe_factory(fail_inputs={str(bad)}),
                           traditional=False)
            events = parse_jsonl(buf.getvalue())
            failed = [e for e in events if e["event"] == "file_failed"]
            completed = [e for e in events if e["event"] == "file_completed"]
            batch = [e for e in events if e["event"] == "batch_completed"][0]
            self.assertEqual([e["file_id"] for e in failed], ["2"])
            self.assertEqual(sorted(e["file_id"] for e in completed), ["1", "3"])
            self.assertEqual(batch["succeeded"], 2)
            self.assertEqual(batch["failed"], 1)
            self.assertTrue((d / "3.txt").is_file())  # third file still processed

    def test_empty_transcript_marks_failed(self):
        with TemporaryDirectory() as d:
            d = Path(d)
            wav = self._make_input(d, "a.wav")
            files = [{"id": "a", "input_wav": str(wav), "output_txt": str(d / "o.txt")}]
            buf = io.StringIO()
            with redirect_stdout(buf):
                worker.run(files, "", model=object(),
                           transcribe=fake_transcribe_factory({str(wav): "   "}),
                           traditional=False)
            events = parse_jsonl(buf.getvalue())
            self.assertTrue(any(e["event"] == "file_failed" and e["code"] == "empty_transcript" for e in events))
            self.assertFalse((d / "o.txt").is_file())


class SingleModelLoadTests(unittest.TestCase):
    def test_main_loads_model_once_for_batch(self):
        load_calls = {"n": 0}

        fake_mod = types.ModuleType("mlx_qwen3_asr")

        def load_model(path):
            load_calls["n"] += 1
            return (object(), object())

        fake_mod.load_model = load_model
        fake_mod.transcribe = fake_transcribe_factory()
        sys.modules["mlx_qwen3_asr"] = fake_mod
        try:
            with TemporaryDirectory() as d:
                d = Path(d)
                wavs = []
                files = []
                for i in range(3):
                    w = d / f"f{i}.wav"
                    w.write_bytes(b"RIFFfake")
                    wavs.append(w)
                    files.append({"id": str(i), "input_wav": str(w), "output_txt": str(d / f"{i}.txt")})
                manifest = d / "manifest.json"
                manifest.write_text(json.dumps({"version": 1, "context": "", "files": files}), encoding="utf-8")
                argv = ["worker", "--manifest", str(manifest), "--model-dir", str(d / "model"),
                        "--output-dir", str(d)]
                old = sys.argv
                sys.argv = argv
                try:
                    buf = io.StringIO()
                    with redirect_stdout(buf):
                        rc = worker.main()
                finally:
                    sys.argv = old
                self.assertEqual(rc, 0)
                self.assertEqual(load_calls["n"], 1, "model must load exactly once per batch")
        finally:
            del sys.modules["mlx_qwen3_asr"]


if __name__ == "__main__":
    unittest.main(verbosity=2)
