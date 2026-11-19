"""AC-1: the chunker never exceeds max_chunk_chars and never splits mid-sentence."""
from __future__ import annotations

import pytest

from conftest import field

SENTENCE_END = ".!?…"
CLAUSE_END = ",;"
CLOSERS = "\"'”»)]"

BASIC = (
    "Rynek w Polsce rośnie. Eksperci mówią o trwałym trendzie. "
    "To dopiero początek tej historii.\n\n"
    "Drugi akapit jest krótki. Ma dwa zdania.\n\n"
    "Trzeci akapit ma tylko jedno zdanie i jest najkrótszy."
)

LONG_CLAUSE = (
    "analitycy zgodnie podkreślają, że rynek w Polsce rośnie szybciej niż w regionie"
)


def long_sentence():
    """One sentence well past the 300-char limit, with commas to split at."""
    return ", ".join([LONG_CLAUSE] * 4) + "."


def chunks_of(text, max_chars):
    import podcast_tts

    return podcast_tts.chunk_text(text, max_chunk_chars=max_chars)


def ending(chunk_text):
    return chunk_text.rstrip().rstrip(CLOSERS)


@pytest.mark.parametrize("max_chars", [120, 300])
@pytest.mark.parametrize(
    "text",
    [BASIC, long_sentence(), BASIC + "\n\n" + long_sentence()],
    ids=["paragraphs", "one-long-sentence", "mixed"],
)
def test_no_chunk_exceeds_the_limit(text, max_chars):
    chunks = chunks_of(text, max_chars)
    assert chunks, "the chunker returned nothing"
    for chunk in chunks:
        chunk_text = field(chunk, "text")
        assert chunk_text.strip(), "the chunker produced an empty chunk"
        assert len(chunk_text) <= max_chars, (
            f"chunk {field(chunk, 'index')} is {len(chunk_text)} chars, "
            f"limit {max_chars}: {chunk_text!r}"
        )


@pytest.mark.parametrize("max_chars", [120, 300])
def test_no_chunk_ends_mid_sentence(max_chars):
    text = BASIC + "\n\n" + long_sentence()
    chunks = chunks_of(text, max_chars)
    for chunk in chunks[:-1]:
        tail = ending(field(chunk, "text"))
        assert tail and tail[-1] in SENTENCE_END + CLAUSE_END, (
            f"chunk {field(chunk, 'index')} ends mid-sentence: {field(chunk, 'text')!r}"
        )


def test_long_sentence_splits_at_a_comma():
    chunks = chunks_of(long_sentence(), 300)
    assert len(chunks) > 1, "a sentence longer than the limit must be split"
    for chunk in chunks[:-1]:
        tail = ending(field(chunk, "text"))
        assert tail[-1] in CLAUSE_END, (
            "an over-long sentence must split at a comma or semicolon, "
            f"not at {tail[-1]!r}: {field(chunk, 'text')!r}"
        )


@pytest.mark.parametrize("max_chars", [120, 300])
def test_no_word_is_lost_or_duplicated(max_chars):
    text = BASIC + "\n\n" + long_sentence()
    chunks = chunks_of(text, max_chars)
    rebuilt = " ".join(field(chunk, "text") for chunk in chunks)
    assert rebuilt.split() == text.split()


def test_paragraphs_are_tracked_and_kept_apart():
    chunks = chunks_of(BASIC, 300)
    paragraphs = [field(chunk, "paragraph") for chunk in chunks]
    assert paragraphs == sorted(paragraphs), "paragraph ids must not go backwards"
    assert set(paragraphs) == {0, 1, 2}, f"expected three paragraphs, got {sorted(set(paragraphs))}"
    assert len(set(paragraphs)) == 3
    for chunk in chunks:
        assert "\n\n" not in field(chunk, "text"), "a chunk spans two paragraphs"


def test_indices_are_sequential():
    chunks = chunks_of(BASIC + "\n\n" + long_sentence(), 120)
    assert [field(chunk, "index") for chunk in chunks] == list(range(len(chunks)))
