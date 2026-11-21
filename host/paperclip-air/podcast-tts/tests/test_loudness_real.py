"""AC-3: with the real ffmpeg the assembled MP3 measures -16 +/- 1 LUFS integrated.

Unlike the rest of the suite this test runs ffmpeg for real: the point is the
loudness of the finished episode, not the argv of the two passes. The chunk WAVs
are generated here (a quiet tone, so pass 2 has real gain to apply) - no fixture
files, no model, no network.
"""
from __future__ import annotations

import json
import math
import re
import shutil
import struct
import subprocess
import wave

import pytest

import podcast_tts
from conftest import write_config

SAMPLE_RATE = 24000
TARGET_LUFS = -16.0
TOLERANCE = 1.0
# About -37 LUFS integrated, so the loudness pass has ~20 dB of gain to apply and
# a double-normalised file overshoots the target by a wide margin.
AMPLITUDE = 0.02


def _tone_wav(path, seconds=4.0, frequency=220.0):
    """Write a mono 24 kHz 16-bit tone WAV; generated, never committed."""
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = bytearray()
    for index in range(int(SAMPLE_RATE * seconds)):
        value = AMPLITUDE * math.sin(2.0 * math.pi * frequency * index / SAMPLE_RATE)
        frames += struct.pack("<h", int(value * 32767))
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(bytes(frames))
    return path


def _measure_integrated_lufs(path):
    """Measure one file with ffmpeg's loudnorm and return its integrated loudness."""
    proc = subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-nostats", "-i", str(path),
            "-af", "loudnorm=print_format=json", "-f", "null", "-",
        ],
        capture_output=True,
        text=True,
        timeout=180,
    )
    assert proc.returncode == 0, (
        f"ffmpeg could not measure {path}: {proc.stderr[-1500:]}"
    )
    blocks = re.findall(r"\{[^{}]*\"input_i\"[^{}]*\}", proc.stderr, flags=re.DOTALL)
    assert blocks, f"ffmpeg printed no loudnorm JSON for {path}: {proc.stderr[-1500:]}"
    measured = float(json.loads(blocks[-1])["input_i"])
    assert math.isfinite(measured), f"{path} must have a measurable loudness, got {measured}"
    return measured


def test_real_ffmpeg_assembled_mp3_measures_minus_16_lufs(tmp_path):
    if shutil.which("ffmpeg") is None:
        pytest.fail(
            "AC-3 needs the real ffmpeg on PATH; skipping would hide the measurement"
        )

    work_dir = tmp_path / "work"
    paths = [
        _tone_wav(work_dir / "0000.wav", frequency=220.0),
        _tone_wav(work_dir / "0001.wav", frequency=330.0),
    ]
    cfg = podcast_tts.load_config(write_config(tmp_path))
    out_path = tmp_path / "episode.mp3"

    podcast_tts.assemble(
        audio_paths=paths,
        paragraph_ids=[0, 1],
        config=cfg,
        out_path=out_path,
        work_dir=work_dir,
    )
    assert out_path.is_file(), f"assemble did not write the episode: {out_path}"
    assert out_path.stat().st_size > 0, f"the episode is empty: {out_path}"

    measured = _measure_integrated_lufs(out_path)
    assert abs(measured - TARGET_LUFS) <= TOLERANCE, (
        f"the assembled MP3 measures {measured:.2f} LUFS integrated; "
        f"it must be {TARGET_LUFS:g} +/- {TOLERANCE:g} LUFS"
    )
