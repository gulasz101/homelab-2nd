"""AC-6: a failing chunk is retried, then the run fails with the chunk index in the error."""
from __future__ import annotations

import re

import pytest

ARTICLE = (
    "Pierwszy akapit mówi o rynku i o ludziach.\n\n"
    "Drugi akapit to AWARIA silnika na produkcji.\n\n"
    "Trzeci akapit mówi o przyszłości."
)
RETRIES = 2


def _run_and_capture_error(tmp_path, pipeline, engine, runner):
    pipe, _, _ = pipeline({"retries": RETRIES})
    with pytest.raises(Exception) as excinfo:
        pipe.run(ARTICLE, tmp_path / "episode.mp3", tmp_path / "work")
    return excinfo.value


def test_a_raising_chunk_is_retried_then_the_run_fails(tmp_path, pipeline):
    import podcast_tts
    from conftest import FakeEngine, FakeRunner

    engine = FakeEngine(fail_on="AWARIA")
    runner = FakeRunner()
    pipe, _, _ = pipeline({"retries": RETRIES}, engine=engine, runner=runner)
    with pytest.raises(Exception) as excinfo:
        pipe.run(ARTICLE, tmp_path / "episode.mp3", tmp_path / "work")
    error = excinfo.value

    assert isinstance(error, podcast_tts.ChunkFailedError), (
        f"expected ChunkFailedError, got {type(error).__name__}: {error}"
    )
    attempts = [call for call in engine.calls if "AWARIA" in call]
    assert len(attempts) == RETRIES + 1, (
        f"expected {RETRIES + 1} attempts on the failing chunk, got {len(attempts)}"
    )
    assert getattr(error, "chunk_index", None) == 1, (
        f"expected chunk_index 1, got {getattr(error, 'chunk_index', None)}"
    )
    message = str(error)
    assert re.search(r"(?i)chunk\D{0,12}\b1\b", message), (
        f"the error must name the failing chunk index: {message!r}"
    )


def test_an_empty_audio_chunk_is_retried_then_the_run_fails(tmp_path, pipeline):
    import podcast_tts
    from conftest import FakeEngine, FakeRunner

    engine = FakeEngine(empty_on="AWARIA")
    runner = FakeRunner()
    pipe, _, _ = pipeline({"retries": RETRIES}, engine=engine, runner=runner)
    with pytest.raises(Exception) as excinfo:
        pipe.run(ARTICLE, tmp_path / "episode.mp3", tmp_path / "work")
    error = excinfo.value

    assert isinstance(error, podcast_tts.ChunkFailedError), (
        f"expected ChunkFailedError, got {type(error).__name__}: {error}"
    )
    attempts = [call for call in engine.calls if "AWARIA" in call]
    assert len(attempts) == RETRIES + 1, (
        f"expected {RETRIES + 1} attempts on the empty chunk, got {len(attempts)}"
    )
    assert getattr(error, "chunk_index", None) == 1
