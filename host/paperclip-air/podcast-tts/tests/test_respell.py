"""AC-4: a `[words]` entry in a temp respell.toml is applied without a code change."""
from __future__ import annotations

import re

import podcast_tts
from conftest import PROJECT, field, write_respell

TEXT = "Mówiliśmy o Chinach w 2025 roku i o całej reszcie rynku."


def test_shipped_respell_has_both_tables():
    respell = podcast_tts.load_respell(PROJECT / "respell.toml")
    phrases = field(respell, "phrases")
    words = field(respell, "words")
    assert isinstance(phrases, dict) and phrases, "[phrases] must be seeded with PHRASES"
    assert isinstance(words, dict), "[words] must exist (it starts empty)"


def test_shipped_phrase_table_is_applied():
    respell = podcast_tts.load_respell(PROJECT / "respell.toml")
    out = podcast_tts.normalise_text("To jest science fiction.", respell)
    assert "sajens fikszyn" in out.lower(), out


def test_new_word_entry_applies_without_a_code_change(tmp_path):
    before = podcast_tts.load_respell(
        write_respell(tmp_path / "before.toml", phrases={}, words={})
    )
    after = podcast_tts.load_respell(
        write_respell(
            tmp_path / "after.toml",
            phrases={},
            words={"Chinach": "Hinach"},
        )
    )

    out_before = podcast_tts.normalise_text(TEXT, before)
    assert "Chinach" in out_before, out_before
    assert "Hinach" not in out_before, out_before

    out_after = podcast_tts.normalise_text(TEXT, after)
    assert "Hinach" in out_after, out_after
    assert "Chinach" not in out_after, out_after
    # words are applied last, after the numbers, so a respelling cannot be
    # swallowed by (or swallow) the numeric pass
    assert not re.search(r"[0-9]", out_after), out_after
