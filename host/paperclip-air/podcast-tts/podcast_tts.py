#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["mlx-audio>=0.6.6", "numpy"]
# ///
"""Polish text to MP3 in Wojtek's cloned voice (GUL-1749, spec of GUL-1746).

Chatterbox Multilingual v3 on MLX, in-process with `mlx-audio` -- never the
Voicebox daemon, which pins Chatterbox to the CPU on macOS. The model is loaded
lazily, once per run, so importing this module costs nothing and `--dry-run`
never touches the GPU.

    uv run podcast_tts.py --config cfg.toml --in article.txt --out episode.mp3

Pipeline: chunk -> normalise (respell.toml phrases, pl_norm, [words]) -> refuse
any chunk that still carries a digit -> synthesise with retries into
`work-dir/NNNN.wav` -> assemble with two-pass loudnorm. `work-dir/manifest.json`
makes a re-run skip chunks whose text has not changed.

Tests inject both the engine and `ffmpeg`; nothing here needs a model, a network
or a GPU to be importable.
"""
from __future__ import annotations

import argparse
import array
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time
import wave
from dataclasses import dataclass

import pl_norm

SAMPLE_RATE = 24000

# Defaults documented in config.example.toml and the red tests' conftest.
DEFAULTS = {
    "model": "mlx-community/chatterbox-multilingual-v3",
    "ref_audio": "",
    "lang_code": "pl",
    "max_chunk_chars": 300,
    "pause_ms": 350,
    "paragraph_pause_ms": 800,
    "retries": 2,
    "bitrate": "128k",
    "respell": "respell.toml",
}

LOUDNORM_TARGET = "I=-16:TP=-1.5:LRA=11"

# Sentence ends, and the punctuation that may close one (`"`, `„`, `)` ...).
SENTENCE_END = ".!?…"
CLAUSE_END = ",;"
CLOSERS = "\"'”»)]"

# Abbreviations whose full stop does not end a sentence when a lowercase word
# follows ("W 2025 r. rynek ..."). `proc.` at the end of a sentence is followed by
# an uppercase word, so the lowercase test below leaves that boundary alone.
_ABBREV = r"(?:r|proc|np|itd|itp|tys|mld|mln|nr|dr|prof|ul|al|pl|godz|tys|św)\."
_ABBREV_TAIL = re.compile(r"\b" + _ABBREV + r"$", re.IGNORECASE)
_SENTENCE_SPLIT = re.compile(r"(?<=[.!?…])[\"'”»)\]]*\s+")
_PARAGRAPH_SPLIT = re.compile(r"\n\s*\n")
_LOWERCASE_START = re.compile(r"^[a-ząćęłńóśżź]")


# --------------------------------------------------------------------------- #
# config
# --------------------------------------------------------------------------- #
@dataclass
class Config:
    model: str
    ref_audio: str
    lang_code: str
    max_chunk_chars: int
    pause_ms: int
    paragraph_pause_ms: int
    retries: int
    bitrate: str
    respell: str
    path: str | None = None


def _read_toml(path):
    import tomllib

    with open(path, "rb") as handle:
        return tomllib.load(handle)


def load_config(path):
    """Load a TOML config. A relative `respell` resolves against the config's own
    directory, so an example config next to its respell.toml just works."""
    path = pathlib.Path(path)
    raw = _read_toml(path)
    unknown = set(raw) - set(DEFAULTS)
    if unknown:
        raise ValueError(f"{path}: unknown config keys: {', '.join(sorted(unknown))}")
    values = {**DEFAULTS, **raw}
    respell = pathlib.Path(str(values["respell"]))
    if not respell.is_absolute():
        respell = path.parent / respell
    values["respell"] = str(respell)
    for key in ("max_chunk_chars", "pause_ms", "paragraph_pause_ms", "retries"):
        values[key] = int(values[key])
    cfg = Config(path=str(path), **values)
    if cfg.max_chunk_chars < 40:
        raise ValueError(f"{path}: max_chunk_chars={cfg.max_chunk_chars} is too small to speak")
    return cfg


@dataclass
class Respell:
    phrases: dict
    words: dict
    path: str | None = None


def load_respell(path):
    """The ear-checked respelling dictionary: `[phrases]` then `[words]`."""
    path = pathlib.Path(path)
    if not path.is_file():
        raise FileNotFoundError(f"respell dictionary not found: {path}")
    raw = _read_toml(path)
    phrases = {str(k): str(v) for k, v in (raw.get("phrases") or {}).items()}
    words = {str(k): str(v) for k, v in (raw.get("words") or {}).items()}
    return Respell(phrases=phrases, words=words, path=str(path))


# --------------------------------------------------------------------------- #
# chunking
# --------------------------------------------------------------------------- #
@dataclass
class Chunk:
    index: int
    text: str
    paragraph: int


def _split_sentences(paragraph):
    """Split one paragraph into sentences, keeping a closing quote or bracket and
    not breaking after an abbreviation followed by a lowercase word."""
    pieces = [p.strip() for p in _SENTENCE_SPLIT.split(paragraph.strip())]
    sentences = []
    for piece in pieces:
        if not piece:
            continue
        if sentences and _ABBREV_TAIL.search(sentences[-1]) and _LOWERCASE_START.match(piece):
            sentences[-1] = sentences[-1] + " " + piece
        else:
            sentences.append(piece)
    return sentences


def _split_long_sentence(sentence, max_chars):
    """Cut an over-long sentence at the last comma/semicolon that fits. A sentence
    with no clause break at all still has to respect the limit, so it falls back
    to the last space and only cuts mid-word when a single word is longer."""
    pieces = []
    rest = sentence.strip()
    while len(rest) > max_chars:
        window = rest[:max_chars]
        cut = max(window.rfind(","), window.rfind(";"))
        if cut > 0:
            piece, rest = rest[: cut + 1].strip(), rest[cut + 1:].strip()
        else:
            cut = window.rfind(" ")
            if cut <= 0:
                cut = max_chars - 1
            piece, rest = rest[:cut].strip(), rest[cut:].strip()
        if not piece:
            break
        pieces.append(piece)
    if rest:
        pieces.append(rest)
    return pieces


def chunk_text(text, max_chunk_chars=300):
    """Paragraphs, then sentences: no chunk longer than `max_chunk_chars`, no
    chunk ending mid-sentence (a clause break is allowed for a sentence that is
    itself longer than the limit)."""
    max_chunk_chars = int(max_chunk_chars)
    chunks = []
    paragraph_id = -1

    def emit(value, paragraph):
        chunks.append(Chunk(index=len(chunks), text=value, paragraph=paragraph))

    for paragraph in _PARAGRAPH_SPLIT.split(text.replace("\r\n", "\n")):
        paragraph = paragraph.strip()
        if not paragraph:
            continue
        paragraph_id += 1
        buffer = ""
        for sentence in _split_sentences(paragraph):
            pieces = _split_long_sentence(sentence, max_chunk_chars)
            last = len(pieces) - 1
            for position, piece in enumerate(pieces):
                if position != last:
                    # a clause of an over-long sentence is its own chunk: the
                    # chunker must not glue a clause break onto a full sentence
                    if buffer:
                        emit(buffer, paragraph_id)
                        buffer = ""
                    emit(piece, paragraph_id)
                    continue
                if buffer and len(buffer) + 1 + len(piece) <= max_chunk_chars:
                    buffer = buffer + " " + piece
                else:
                    if buffer:
                        emit(buffer, paragraph_id)
                    buffer = piece
        if buffer:
            emit(buffer, paragraph_id)
    return chunks


# --------------------------------------------------------------------------- #
# normalisation
# --------------------------------------------------------------------------- #
def _phrase_pattern(key):
    return re.compile(r"(?<![\w.])" + re.escape(key) + r"(?![\w])", re.IGNORECASE)


def normalise_text(text, respell):
    """respell.toml `[phrases]` -> pl_norm -> respell.toml `[words]`. The word pass
    is last, so a respelling cannot be swallowed by the numeric pass."""
    phrases = getattr(respell, "phrases", None) or {}
    words = getattr(respell, "words", None) or {}
    out = text
    for key in sorted(phrases, key=len, reverse=True):
        out = _phrase_pattern(key).sub(phrases[key], out)
    out = pl_norm.normalise(out)
    for key in sorted(words, key=len, reverse=True):
        out = re.sub(r"\b" + re.escape(key) + r"\b", words[key], out)
    return re.sub(r"\s+", " ", out).strip()


# --------------------------------------------------------------------------- #
# errors
# --------------------------------------------------------------------------- #
class PodcastTTSError(Exception):
    """Base class for the two failures the CLI reports by chunk."""


class DigitInChunkError(PodcastTTSError):
    """A chunk still contains a digit after normalisation: refusing beats guessing."""

    def __init__(self, chunk_index, text):
        self.chunk_index = int(chunk_index)
        self.text = text
        digits = sorted(set(re.findall(r"[0-9]", text)))
        super().__init__(
            f"chunk {self.chunk_index}: the normaliser could not speak "
            f"{'/'.join(digits) or 'a digit'} in {text!r} -- add a rule to pl_norm.py "
            f"or a [words] entry to respell.toml, then re-run"
        )


class ChunkFailedError(PodcastTTSError):
    """Every retry for one chunk failed (engine raised, or returned no audio)."""

    def __init__(self, chunk_index, attempts, cause):
        self.chunk_index = int(chunk_index)
        self.attempts = int(attempts)
        self.cause = cause
        super().__init__(
            f"chunk {self.chunk_index} failed after {self.attempts} attempts: {cause}"
        )


# --------------------------------------------------------------------------- #
# audio helpers
# --------------------------------------------------------------------------- #
def _hash_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:32]


def _write_wav(path, samples, sample_rate):
    """Write float samples (-1..1) as 16-bit mono PCM, the format ffmpeg gets."""
    values = array.array("h")
    for sample in samples:
        value = float(sample)
        if value != value:  # NaN
            value = 0.0
        value = max(-1.0, min(1.0, value))
        values.append(int(round(value * 32767)))
    if sys.byteorder != "little":
        values.byteswap()
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(int(sample_rate))
        handle.writeframes(values.tobytes())


def _default_run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def _ffmpeg(proc, label):
    """Return `proc` if ffmpeg exited 0, else fail loudly (F-1: a broken encode
    must not be reported as a finished episode). The stderr tail is what ffmpeg
    actually complained about, so it goes into the message."""
    code = getattr(proc, "returncode", 0)
    if code:
        lines = [line for line in (getattr(proc, "stderr", "") or "").splitlines() if line.strip()]
        tail = " | ".join(lines[-3:]) or "no stderr"
        raise PodcastTTSError(f"{label} failed with exit status {code}: {tail}")
    return proc


def _parse_loudnorm(stderr):
    """Pull the last JSON object out of ffmpeg's loudnorm measurement on stderr."""
    blocks = re.findall(r"\{[^{}]*\}", stderr or "", flags=re.DOTALL)
    for block in reversed(blocks):
        try:
            payload = json.loads(block)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict) and "input_i" in payload:
            return payload
    raise PodcastTTSError(
        "ffmpeg pass 1 printed no loudnorm measurement JSON; nothing to apply in pass 2"
    )


def assemble(audio_paths, paragraph_ids, config, out_path, work_dir, run=None):
    """Concatenate the chunk WAVs with the configured silence, then normalise in
    two ffmpeg passes: pass 1 only measures (the plain concat is written to the
    intermediate WAV while the loudnorm branch is measured and thrown away), pass
    2 applies those measurements and encodes the MP3. Measuring unnormalised audio
    is what keeps pass 2 from normalising the same audio twice. Returns the argv
    lists it ran."""
    run = run or _default_run
    audio_paths = [pathlib.Path(p) for p in audio_paths]
    paragraph_ids = list(paragraph_ids)
    if not audio_paths:
        raise PodcastTTSError("nothing to assemble: no chunk audio")
    if len(paragraph_ids) != len(audio_paths):
        raise ValueError("paragraph_ids and audio_paths must be the same length")
    out_path = pathlib.Path(out_path)
    work_dir = pathlib.Path(work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)
    rate = SAMPLE_RATE
    paused = work_dir / "assembled.wav"

    pause = int(config.pause_ms) / 1000.0
    paragraph_pause = int(config.paragraph_pause_ms) / 1000.0

    # The concat order, with a generated silence input for every gap.
    order = []
    for position, path in enumerate(audio_paths):
        order.append(("audio", path))
        if position + 1 < len(audio_paths):
            same_paragraph = paragraph_ids[position] == paragraph_ids[position + 1]
            order.append(("silence", pause if same_paragraph else paragraph_pause))

    cmd1 = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "info"]
    for kind, value in order:
        if kind == "audio":
            cmd1 += ["-i", str(value)]
        else:
            cmd1 += ["-f", "lavfi", "-t", f"{value:g}", "-i",
                     f"anullsrc=r={rate}:cl=mono"]
    streams = "".join(f"[{index}:a]" for index in range(len(order)))
    graph1 = (
        f"{streams}concat=n={len(order)}:v=0:a=1[joined];"
        "[joined]asplit=2[plain][measure];"
        f"[measure]loudnorm={LOUDNORM_TARGET}:print_format=json[0];"
        # The measurement branch has no output of its own: drain it so the graph
        # is complete and nothing loudnorm-normalised reaches assembled.wav.
        "[0]anullsink"
    )
    cmd1 += [
        "-filter_complex", graph1,
        # Output 1: the plain concat, untouched, as the intermediate WAV.
        "-map", "[plain]", "-ar", str(rate), "-ac", "1", str(paused),
        # Output 2: the discard sink pass 1 must expose for its measurement side.
        "-map", "0", "-f", "null", "-",
    ]
    proc1 = _ffmpeg(run(cmd1), "ffmpeg pass 1 (concat + loudnorm measurement)")
    measured = _parse_loudnorm(getattr(proc1, "stderr", "") or "")

    graph2 = (
        "[0:a]loudnorm=" + LOUDNORM_TARGET
        + f":measured_I={measured['input_i']}"
        + f":measured_TP={measured['input_tp']}"
        + f":measured_LRA={measured['input_lra']}"
        + f":measured_thresh={measured['input_thresh']}"
        + f":offset={measured.get('target_offset', '0.00')}"
        + "[out]"
    )
    cmd2 = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "info",
        "-i", str(paused),
        "-filter_complex", graph2, "-map", "[out]",
        "-ar", str(rate), "-ac", "1", "-b:a", str(config.bitrate),
        str(out_path),
    ]
    _ffmpeg(run(cmd2), "ffmpeg pass 2 (loudnorm + mp3 encode)")
    return [cmd1, cmd2]


# --------------------------------------------------------------------------- #
# pipeline
# --------------------------------------------------------------------------- #
def _mlx_engine(config):
    """Load Chatterbox v3 once and synthesise one chunk at a time. `mlx_audio` is
    imported here, never at module import: tests and `--dry-run` stay CPU-free."""
    state = {}

    def load():
        if "model" not in state:
            from mlx_audio.tts.utils import load_model

            state["model"] = load_model(config.model)
        return state["model"]

    def engine(text):
        import numpy as np

        model = load()
        pieces, rate = [], SAMPLE_RATE
        for result in model.generate(
            text=text,
            ref_audio=config.ref_audio,
            lang_code=config.lang_code,
            verbose=False,
        ):
            pieces.append(np.asarray(result.audio).reshape(-1))
            rate = int(getattr(result, "sample_rate", SAMPLE_RATE) or SAMPLE_RATE)
        if not pieces:
            return [], rate
        return np.concatenate(pieces), rate

    return engine


class Pipeline:
    """chunk -> normalise -> digit guard -> synthesise (resumable, retried) -> assemble."""

    def __init__(self, config, engine=None, run=None):
        self.config = config
        self.respell = load_respell(config.respell)
        self._engine = engine
        self.run_cmd = run or _default_run

    # -- engine ---------------------------------------------------------- #
    def engine(self, text):
        if self._engine is None:
            self._engine = _mlx_engine(self.config)
        return self._engine(text)

    # -- manifest -------------------------------------------------------- #
    @staticmethod
    def _read_manifest(path):
        if not path.is_file():
            return {}
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return {}
        entries = payload.get("chunks", []) if isinstance(payload, dict) else payload
        found = {}
        for entry in entries or []:
            if isinstance(entry, dict) and "index" in entry:
                try:
                    found[int(entry["index"])] = entry
                except (TypeError, ValueError):
                    continue
        return found

    @staticmethod
    def _write_manifest(path, entries):
        ordered = [entries[index] for index in sorted(entries)]
        path.write_text(
            json.dumps({"version": 1, "chunks": ordered}, ensure_ascii=False, indent=1) + "\n",
            encoding="utf-8",
        )

    # -- one chunk ------------------------------------------------------- #
    def _synthesise(self, chunk, text):
        """Up to `retries` retries on an exception or empty audio, then fail loudly."""
        attempts = max(1, int(self.config.retries) + 1)
        cause = None
        for attempt in range(1, attempts + 1):
            started = time.monotonic()
            try:
                samples, rate = self.engine(text)
            except Exception as exc:  # noqa: BLE001 - the engine's failures are opaque
                cause = exc
                continue
            if samples is None or len(samples) == 0:
                cause = RuntimeError("the engine returned no audio")
                continue
            return samples, int(rate or SAMPLE_RATE), time.monotonic() - started
        raise ChunkFailedError(chunk.index, attempts, cause)

    # -- the run --------------------------------------------------------- #
    def run(self, text, out_path, work_dir):
        out_path = pathlib.Path(out_path)
        work_dir = pathlib.Path(work_dir)
        work_dir.mkdir(parents=True, exist_ok=True)

        chunks = chunk_text(text, self.config.max_chunk_chars)
        if not chunks:
            raise ValueError("nothing to synthesise: the input has no text")

        spoken = [normalise_text(chunk.text, self.respell) for chunk in chunks]

        # AC-3: refuse before the engine is touched, and name every offending chunk.
        for chunk, normalised in zip(chunks, spoken):
            if re.search(r"[0-9]", normalised):
                raise DigitInChunkError(chunk.index, normalised)

        manifest_path = work_dir / "manifest.json"
        entries = self._read_manifest(manifest_path)

        # AC-2: a shorter script in the same work dir must not inherit entries (or
        # orphaned WAVs) for chunk indexes this run does not have.
        current = {chunk.index for chunk in chunks}
        stale = [index for index in entries if index not in current]
        if stale:
            for index in sorted(stale):
                entry = entries.pop(index)
                name = str(entry.get("file") or f"{index:04d}.wav")
                orphan = work_dir / name if pathlib.PurePath(name).name == name else None
                if orphan is not None:
                    try:
                        orphan.unlink()
                    except OSError:
                        pass
            self._write_manifest(manifest_path, entries)

        audio_paths, paragraph_ids = [], []
        generated = skipped = 0
        audio_seconds = generation_seconds = 0.0

        for chunk, normalised in zip(chunks, spoken):
            digest = _hash_text(normalised)
            wav_path = work_dir / f"{chunk.index:04d}.wav"
            entry = entries.get(chunk.index)
            resumed = (
                entry is not None
                and entry.get("hash") == digest
                and entry.get("status") == "done"
                and wav_path.is_file()
            )
            if resumed:
                skipped += 1
            else:
                samples, rate, seconds = self._synthesise(chunk, normalised)
                _write_wav(wav_path, samples, rate)
                entry = {
                    "index": chunk.index,
                    "hash": digest,
                    "status": "done",
                    "paragraph": chunk.paragraph,
                    "file": wav_path.name,
                    "text": normalised,
                    "generation_seconds": round(seconds, 3),
                    "audio_seconds": round(len(samples) / float(rate), 3),
                }
                entries[chunk.index] = entry
                self._write_manifest(manifest_path, entries)
                generated += 1
            chunk_audio = float(entry.get("audio_seconds") or 0.0)
            audio_seconds += chunk_audio
            generation_seconds += float(entry.get("generation_seconds") or 0.0)
            audio_paths.append(wav_path)
            paragraph_ids.append(chunk.paragraph)

        commands = assemble(
            audio_paths=audio_paths,
            paragraph_ids=paragraph_ids,
            config=self.config,
            out_path=out_path,
            work_dir=work_dir,
            run=self.run_cmd,
        )

        return {
            "out_path": str(out_path),
            "work_dir": str(work_dir),
            "chunks": len(chunks),
            "generated": generated,
            "skipped": skipped,
            "audio_seconds": round(audio_seconds, 2),
            "generation_seconds": round(generation_seconds, 2),
            "real_time_factor": (
                round(generation_seconds / audio_seconds, 2) if audio_seconds else None
            ),
            "ffmpeg_calls": len(commands),
        }


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def build_parser():
    parser = argparse.ArgumentParser(
        prog="podcast_tts.py",
        description="Polish text to MP3 in Wojtek's cloned voice (Chatterbox Multilingual v3 on MLX).",
    )
    parser.add_argument("--config", required=True, help="path to the TOML config")
    parser.add_argument("--in", dest="input", required=True, help="article text file")
    parser.add_argument("--out", required=True, help="MP3 to write")
    parser.add_argument("--work-dir", default=None,
                        help="chunk WAVs and manifest.json (default: next to the MP3)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the normalised chunks and exit without loading the model")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    config = load_config(args.config)
    respell = load_respell(config.respell)
    text = pathlib.Path(args.input).read_text(encoding="utf-8")
    chunks = chunk_text(text, config.max_chunk_chars)

    if args.dry_run:
        for chunk in chunks:
            print(f"--- chunk {chunk.index} (paragraph {chunk.paragraph}, "
                  f"{len(chunk.text)} chars)")
            print(normalise_text(chunk.text, respell))
        print(f"--- {len(chunks)} chunks, nothing synthesised (dry run)")
        return 0

    out_path = pathlib.Path(args.out)
    work_dir = pathlib.Path(args.work_dir) if args.work_dir else out_path.with_suffix("")
    summary = Pipeline(config).run(text, out_path, work_dir)
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
