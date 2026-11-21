"""AC-5: resume skips finished chunks and regenerates a chunk whose text changed."""
from __future__ import annotations

import json

import pytest

import podcast_tts
from conftest import field

ARTICLE = (
    "Pierwszy akapit mówi o rynku i o ludziach.\n\n"
    "Drugi akapit mówi o pieniądzach i o pracy.\n\n"
    "Trzeci akapit mówi o przyszłości tego rynku."
)
CHANGED = (
    "Pierwszy akapit mówi o rynku i o ludziach.\n\n"
    "Drugi akapit mówi o pieniądzach i o pracy.\n\n"
    "Trzeci akapit mówi teraz o zupełnie innej przyszłości."
)


def _run(tmp_path, engine, runner, text, tag):
    import conftest

    cfg = podcast_tts.load_config(conftest.write_config(tmp_path))
    pipe = podcast_tts.Pipeline(cfg, engine=engine, run=runner)
    work_dir = tmp_path / "work"
    out_path = tmp_path / f"{tag}.mp3"
    return pipe.run(text, out_path, work_dir), work_dir


def _manifest(work_dir):
    path = work_dir / "manifest.json"
    assert path.is_file(), "the resume manifest must live at work-dir/manifest.json"
    payload = json.loads(path.read_text(encoding="utf-8"))
    entries = payload.get("chunks", payload) if isinstance(payload, dict) else payload
    if isinstance(entries, dict):
        entries = list(entries.values())
    assert isinstance(entries, list) and entries, f"unexpected manifest shape: {payload!r}"
    return entries


def test_resume_skips_finished_chunks_and_regenerates_a_changed_one(tmp_path):
    import conftest

    cfg = podcast_tts.load_config(conftest.write_config(tmp_path))
    expected_chunks = len(podcast_tts.chunk_text(ARTICLE, max_chunk_chars=field(cfg, "max_chunk_chars")))
    assert expected_chunks >= 2

    engine1, runner1 = conftest.FakeEngine(), conftest.FakeRunner()
    summary1, work_dir = _run(tmp_path, engine1, runner1, ARTICLE, "first")
    assert len(engine1.calls) == expected_chunks, "the first run synthesises every chunk"

    entries = _manifest(work_dir)
    assert len(entries) == expected_chunks, f"manifest covers {len(entries)} of {expected_chunks} chunks"
    for entry in entries:
        for key in ("index", "hash", "status"):
            assert key in entry, f"manifest entry {entry!r} has no {key!r}"

    # a re-run of unchanged text synthesises nothing
    engine2, runner2 = conftest.FakeEngine(), conftest.FakeRunner()
    _run(tmp_path, engine2, runner2, ARTICLE, "second")
    assert engine2.calls == [], f"resume regenerated {len(engine2.calls)} finished chunks"

    # one changed paragraph regenerates exactly that chunk
    engine3, runner3 = conftest.FakeEngine(), conftest.FakeRunner()
    _run(tmp_path, engine3, runner3, CHANGED, "third")
    assert len(engine3.calls) == 1, (
        f"expected only the changed chunk to be regenerated, got {len(engine3.calls)}: "
        f"{engine3.calls!r}"
    )
    assert "zupełnie innej przyszłości" in engine3.calls[0], engine3.calls[0]


# --------------------------------------------------------------------------- #
# AC-2: a shorter re-run prunes the manifest                                  #
# --------------------------------------------------------------------------- #

SHORT = "Krótkie zdanie o rynku i o ludziach."


def test_a_shorter_rerun_prunes_stale_manifest_entries(tmp_path):
    """AC-2: after re-running a shorter script in the same work dir, manifest.json
    lists only the current chunk indexes; the longer run's entries are gone."""
    import conftest

    cfg = podcast_tts.load_config(conftest.write_config(tmp_path))
    max_chars = int(field(cfg, "max_chunk_chars"))
    long_chunks = podcast_tts.chunk_text(ARTICLE, max_chunk_chars=max_chars)
    short_chunks = podcast_tts.chunk_text(SHORT, max_chunk_chars=max_chars)
    assert len(short_chunks) < len(long_chunks), (
        f"the short script must need fewer chunks: {len(short_chunks)} vs {len(long_chunks)}"
    )

    _run(tmp_path, conftest.FakeEngine(), conftest.FakeRunner(), ARTICLE, "long")
    work_dir = tmp_path / "work"
    before = {field(entry, "index") for entry in _manifest(work_dir)}
    assert before == set(range(len(long_chunks))), (
        f"the first run's manifest lists {sorted(before)}, expected {sorted(range(len(long_chunks)))}"
    )

    engine = conftest.FakeEngine()
    _run(tmp_path, engine, conftest.FakeRunner(), SHORT, "short")
    assert len(engine.calls) == len(short_chunks), (
        f"the shorter run synthesised {len(engine.calls)} chunks, expected {len(short_chunks)}"
    )

    after = {field(entry, "index") for entry in _manifest(work_dir)}
    expected = set(range(len(short_chunks)))
    assert after == expected, (
        f"manifest.json lists {sorted(after)} after the shorter re-run; it must only hold "
        f"the current chunk indexes {sorted(expected)}"
    )
