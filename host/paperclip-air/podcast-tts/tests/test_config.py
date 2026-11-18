"""AC-8: config.example.toml loads, and no test imports mlx_audio."""
from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys

import pytest

import podcast_tts
from conftest import DEFAULT_CONFIG, PROJECT, field

EXPECTED = dict(DEFAULT_CONFIG)


def test_example_config_loads_with_the_documented_values():
    cfg = podcast_tts.load_config(PROJECT / "config.example.toml")
    assert field(cfg, "lang_code") == "pl"
    assert field(cfg, "max_chunk_chars") == 300
    assert field(cfg, "pause_ms") == 350
    assert field(cfg, "paragraph_pause_ms") == 800
    assert field(cfg, "retries") == 2
    assert field(cfg, "bitrate") == "128k"
    assert str(field(cfg, "model")).strip(), "the example config names no model id"
    assert str(field(cfg, "ref_audio")).strip(), "the example config names no reference WAV"


def test_example_config_respell_path_points_at_a_real_file():
    cfg = podcast_tts.load_config(PROJECT / "config.example.toml")
    respell = pathlib.Path(str(field(cfg, "respell")))
    if not respell.is_absolute():
        respell = PROJECT / respell
    assert respell.is_file(), f"respell path resolves nowhere: {respell}"
    loaded = podcast_tts.load_respell(respell)
    assert isinstance(field(loaded, "words"), dict)


def test_no_test_file_imports_mlx_audio():
    pattern = re.compile(r"^\s*(?:import\s+mlx_audio|from\s+mlx_audio)", re.MULTILINE)
    for path in sorted((PROJECT / "tests").glob("test_*.py")):
        source = path.read_text(encoding="utf-8")
        assert not pattern.search(source), f"{path.name} imports mlx_audio"


def test_importing_the_modules_does_not_pull_mlx_audio():
    code = (
        "import sys, podcast_tts, pl_norm\n"
        "print(' '.join(sorted(m for m in sys.modules if m.split('.')[0] == 'mlx_audio')))\n"
    )
    env = dict(os.environ)
    env["PYTHONPATH"] = str(PROJECT)
    proc = subprocess.run(
        [sys.executable, "-c", code],
        cwd=str(PROJECT),
        capture_output=True,
        text=True,
        env=env,
    )
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == "", (
        f"importing the modules imported mlx_audio: {proc.stdout.strip()!r}"
    )
