"""AC-4: a `[words]` entry in a temp respell.toml is applied without a code change."""
from __future__ import annotations

import re

import pl_norm
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


# --------------------------------------------------------------------------- #
# GUL-2079 (variant B, second order): four ear-confirmed respellings from the
# GUL-2024 probe (s1-B.mp3, s2-B.mp3). Fixtures are the rows of that probe's
# evidence table: each sentence was rendered and heard with the entry in place.
# --------------------------------------------------------------------------- #

ICV_SENTENCE = "Nowy standard ICV jest już wdrażany w Europie."
BEIDOU_SENTENCE = "BeiDou to chiński system nawigacji satelitarnej."
ZHINENG_SENTENCE = "Chiński zhineng wanglian qiche rozwija się szybko."

RESPELLED_SENTENCES = {
    "Intelligent and Connected Vehicles": (
        "Systemy Intelligent and Connected Vehicles zmieniają rynek.",
        "Systemy inteligent end konektyd wijikls zmieniają rynek.",
    ),
    "zhineng wanglian qiche": (
        ZHINENG_SENTENCE,
        "Chiński czyneng wanglian czicze rozwija się szybko.",
    ),
    "ICV": (ICV_SENTENCE, "Nowy standard i si wi jest już wdrażany w Europie."),
    "BeiDou": (BEIDOU_SENTENCE, "bejdou to chiński system nawigacji satelitarnej."),
}


def _shipped():
    return podcast_tts.load_respell(PROJECT / "respell.toml")


def test_intelligent_and_connected_vehicles_respelling_applies():
    text, expected = RESPELLED_SENTENCES["Intelligent and Connected Vehicles"]
    out = podcast_tts.normalise_text(text, _shipped())
    assert out == expected, out


def test_zhineng_wanglian_qiche_respelling_applies():
    text, expected = RESPELLED_SENTENCES["zhineng wanglian qiche"]
    out = podcast_tts.normalise_text(text, _shipped())
    assert out == expected, out


def test_icv_respelling_applies():
    text, expected = RESPELLED_SENTENCES["ICV"]
    out = podcast_tts.normalise_text(text, _shipped())
    assert out == expected, out


def test_beidou_respelling_applies():
    text, expected = RESPELLED_SENTENCES["BeiDou"]
    out = podcast_tts.normalise_text(text, _shipped())
    assert out == expected, out


def test_respelled_foreign_tokens_leave_no_digit():
    # the digit guard's precondition: none of these sentences may carry a digit
    # into a chunk, whatever the engine does with the respelling
    respell = _shipped()
    for text in (ZHINENG_SENTENCE, ICV_SENTENCE, BEIDOU_SENTENCE):
        out = podcast_tts.normalise_text(text, respell)
        assert re.search(r"[0-9]", out) is None, out


def test_plain_polish_sentence_is_not_touched():
    # negative case: no entry matches, so the respell pass is a no-op
    plain = "Przyjęciu ustawy towarzyszyła długa debata."
    out = podcast_tts.normalise_text(plain, _shipped())
    assert out == pl_norm.normalise(plain), out
