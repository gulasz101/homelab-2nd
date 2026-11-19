"""Fixtures and the API contract for the podcast-tts red tests (GUL-1749).

These tests are the contract. They expect exactly this public surface from the
modules in the parent directory (`host/paperclip-air/podcast-tts/`); the green
stage implements it and nothing here is relaxed to make a test pass.

`config.example.toml` (and any test config) keys, with their defaults:

    model               str   model id passed to mlx_audio's load_model
    ref_audio           str   reference-voice WAV
    lang_code           str   "pl"
    max_chunk_chars     int   300
    pause_ms            int   350
    paragraph_pause_ms  int   800
    retries             int   2
    bitrate             str   "128k"
    respell             str   path to respell.toml

podcast_tts.py

    load_config(path) -> Config
        attributes named like the keys above; `respell`, if relative, resolves
        against the config file's own directory.
    load_respell(path) -> Respell
        `.phrases` and `.words` dicts (`.toml` tables `[phrases]`, `[words]`).
    chunk_text(text, max_chunk_chars=300) -> list of chunks
        each chunk has `.index` (0-based, sequential), `.text`, `.paragraph`
        (0-based). No chunk longer than max_chunk_chars, no chunk ends inside a
        sentence (only after `.`/`!`/`?`, or after `,`/`;` for an over-long
        sentence).
    normalise_text(text, respell) -> str
        respell phrases, then pl_norm.normalise, then respell words.
    Pipeline(config, engine=None, run=None)
        .run(text, out_path, work_dir) -> summary
        `engine(text) -> (samples, sample_rate)` replaces the model, `run(cmd)
        -> CompletedProcess` replaces `ffmpeg`; both are injected in every test
        (no model, no ffmpeg, no network).
    assemble(audio_paths=[...], paragraph_ids=[...], config=cfg, out_path=...,
             work_dir=..., run=runner) -> list of the ffmpeg argv lists it ran
        two loudnorm passes: pass 1 measures (`print_format=json`), pass 2
        applies the parsed values.
    DigitInChunkError   raised before the engine is called; `.chunk_index`, and
                        the message names the index and the offending text.
    ChunkFailedError    raised after the retries are spent; `.chunk_index`, and
                        the message names the index.

pl_norm.py

    normalise(text) -> str, Polish normalisation: numbers, money, dates/years,
    units, abbreviations left over from the prototype.
"""
from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import wave

import pytest

HERE = pathlib.Path(__file__).resolve().parent
PROJECT = HERE.parent
for _entry in (str(HERE), str(PROJECT)):
    if _entry not in sys.path:
        sys.path.insert(0, _entry)

SAMPLE_RATE = 24000

DEFAULT_CONFIG = {
    "model": "mlx-community/chatterbox-multilingual-v3",
    "ref_audio": "ref.wav",
    "lang_code": "pl",
    "max_chunk_chars": 300,
    "pause_ms": 350,
    "paragraph_pause_ms": 800,
    "retries": 2,
    "bitrate": "128k",
    "respell": "respell.toml",
}

# ffmpeg's pass-1 measurement, framed the way ffmpeg prints it on stderr.
CANNED_LOUDNORM = """\
[Parsed_loudnorm_0 @ 0x7f8a1c0] 
{
\t"input_i" : "-23.00",
\t"input_tp" : "-2.00",
\t"input_lra" : "7.00",
\t"input_thresh" : "-33.00",
\t"output_i" : "-16.00",
\t"output_tp" : "-1.50",
\t"output_lra" : "11.00",
\t"output_thresh" : "-23.00",
\t"normalization_type" : "dynamic",
\t"target_offset" : "0.00"
}
"""


def field(obj, name):
    """Read a chunk/config/respell field whether it came back as a dict or an object."""
    if isinstance(obj, dict):
        return obj[name]
    return getattr(obj, name)


class FakeEngine:
    """Stands in for `mlx_audio`; records every chunk it is asked to synthesise."""

    def __init__(self, fail_on=None, empty_on=None, chunk_seconds=0.1):
        self.calls = []
        self.fail_on = fail_on
        self.empty_on = empty_on
        self.chunk_seconds = chunk_seconds

    def __call__(self, text, *args, **kwargs):
        self.calls.append(text)
        if self.fail_on and self.fail_on in text:
            raise RuntimeError("fake engine: failing on purpose")
        if self.empty_on and self.empty_on in text:
            return [], SAMPLE_RATE
        return [0.0] * int(SAMPLE_RATE * self.chunk_seconds), SAMPLE_RATE


class FakeRunner:
    """Stands in for `ffmpeg`: records argv, answers pass 1 with canned loudnorm JSON."""

    def __init__(self, loudnorm_stderr=CANNED_LOUDNORM):
        self.commands = []
        self.loudnorm_stderr = loudnorm_stderr

    def __call__(self, cmd, *args, **kwargs):
        cmd = list(cmd)
        self.commands.append(cmd)
        joined = " ".join(str(part) for part in cmd)
        stderr = ""
        if "loudnorm" in joined and "measured_I" not in joined:
            stderr = self.loudnorm_stderr
        return subprocess.CompletedProcess(cmd, 0, "", stderr)


def make_wav(path, seconds=0.1, sample_rate=SAMPLE_RATE):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = int(sample_rate * seconds)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(b"\x00\x00" * frames)
    return path


def write_config(tmp_path, **overrides):
    """Write a temp config.toml covering every key; absolute paths, nothing implicit."""
    tmp_path = pathlib.Path(tmp_path)
    values = dict(DEFAULT_CONFIG)
    ref_audio = make_wav(tmp_path / "ref.wav")
    values["ref_audio"] = str(ref_audio)
    default_respell = PROJECT / "respell.toml"
    values["respell"] = str(default_respell)
    values.update(overrides)
    lines = []
    for key, value in values.items():
        if isinstance(value, str):
            lines.append(f"{key} = {json.dumps(value)}")
        else:
            lines.append(f"{key} = {value}")
    path = tmp_path / "config.toml"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def write_respell(path, phrases=None, words=None):
    """Write a temp respell.toml, so a listening note needs no code change."""
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# ear-checked respellings", "", "[phrases]"]
    for key, value in (phrases or {}).items():
        lines.append(f"{json.dumps(key)} = {json.dumps(value)}")
    lines.append("")
    lines.append("[words]")
    for key, value in (words or {}).items():
        lines.append(f"{json.dumps(key)} = {json.dumps(value)}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


@pytest.fixture
def pipeline(tmp_path):
    """Build a Pipeline over a temp config with a fake engine and a fake ffmpeg."""

    def _build(config_overrides=None, engine=None, runner=None):
        import podcast_tts

        cfg_path = write_config(tmp_path, **(config_overrides or {}))
        cfg = podcast_tts.load_config(cfg_path)
        engine = engine if engine is not None else FakeEngine()
        runner = runner if runner is not None else FakeRunner()
        return podcast_tts.Pipeline(cfg, engine=engine, run=runner), engine, runner

    return _build
