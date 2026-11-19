"""AC-2: the OSW sample sentence becomes digit-free Polish with the expected words,
and `science fiction` becomes `sajens fikszyn`."""
from __future__ import annotations

import re

import pytest

import pl_norm
import podcast_tts
from conftest import PROJECT

OSW = (
    "W 2025 r. rynek był wart 1,5 mld zł, a sprzedaż wzrosła o 23 proc. "
    "Tak wynika z raportu OSW z 17 grudnia 2025."
)


@pytest.fixture(scope="module")
def respell():
    return podcast_tts.load_respell(PROJECT / "respell.toml")


def test_sample_sentence_has_no_digits_left(respell):
    out = podcast_tts.normalise_text(OSW, respell)
    assert not re.search(r"[0-9]", out), f"digits survived normalisation: {out!r}"


def test_sample_sentence_has_the_expected_words(respell):
    out = podcast_tts.normalise_text(OSW, respell)
    for expected in ("miliarda złotych", "procent", "Ośrodka Studiów Wschodnich"):
        assert expected in out, f"{expected!r} missing from {out!r}"


def test_science_fiction_is_spelled_the_polish_way(respell):
    out = podcast_tts.normalise_text(
        "To nie jest science fiction, to zwykła rzeczywistość.", respell
    )
    assert "sajens fikszyn" in out.lower(), out
    assert "science" not in out.lower(), out


def test_bare_pl_norm_leaves_no_digits():
    out = pl_norm.normalise(OSW)
    assert not re.search(r"[0-9]", out), f"pl_norm.normalise left digits: {out!r}"
    assert "procent" in out, out
