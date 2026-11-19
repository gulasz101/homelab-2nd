"""AC-3: a chunk with a digit the normaliser cannot handle stops the run before the
engine is called, and the error names the chunk."""
from __future__ import annotations

import re

import pytest

CLEAN = "Pierwszy akapit mówi o rynku i o ludziach, którzy na nim pracują."
DIRTY = "Nowy model X5Q trafił właśnie do sprzedaży."
SECOND_PARAGRAPH = "Drugi akapit jest zupełnie zwyczajny."


def test_digit_in_the_only_chunk_stops_the_run(tmp_path, pipeline):
    pipe, engine, runner = pipeline()
    with pytest.raises(Exception) as excinfo:
        pipe.run(DIRTY, tmp_path / "episode.mp3", tmp_path / "work")
    import podcast_tts

    error = excinfo.value
    assert isinstance(error, podcast_tts.DigitInChunkError), (
        f"expected DigitInChunkError, got {type(error).__name__}: {error}"
    )
    assert engine.calls == [], "the engine must not be called when a digit survives"
    assert runner.commands == [], "nothing may be assembled when a digit survives"
    message = str(error)
    assert "X5Q" in message, f"the error must quote the offending text: {message!r}"
    assert error.chunk_index == 0
    assert re.search(r"(?i)chunk\D{0,12}\b0\b", message), (
        f"the error must name the chunk index: {message!r}"
    )


def test_digit_in_a_later_chunk_names_that_chunk(tmp_path, pipeline):
    pipe, engine, runner = pipeline()
    text = CLEAN + "\n\n" + DIRTY + "\n\n" + SECOND_PARAGRAPH
    with pytest.raises(Exception) as excinfo:
        pipe.run(text, tmp_path / "episode.mp3", tmp_path / "work")
    import podcast_tts

    error = excinfo.value
    assert isinstance(error, podcast_tts.DigitInChunkError), (
        f"expected DigitInChunkError, got {type(error).__name__}: {error}"
    )
    assert engine.calls == [], "the engine must not be called when a digit survives"
    message = str(error)
    assert error.chunk_index == 1, f"expected chunk 1, got {error.chunk_index}"
    assert re.search(r"(?i)chunk\D{0,12}\b1\b", message), (
        f"the error must name the chunk index: {message!r}"
    )
    assert "X5Q" in message, f"the error must quote the offending text: {message!r}"
