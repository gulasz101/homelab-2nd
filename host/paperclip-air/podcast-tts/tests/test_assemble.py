"""AC-7: assembly builds two ffmpeg loudnorm passes, the second with the measured
pass-1 values, silence padding and the bitrate. Assert on the commands; never run ffmpeg."""
from __future__ import annotations

import re

import pytest

import podcast_tts
from conftest import CANNED_LOUDNORM, FakeRunner, field, make_wav, write_config

PARAGRAPH_IDS = [0, 0, 1]


def _commands(tmp_path):
    paths = [make_wav(tmp_path / "work" / f"{index:04d}.wav") for index in range(3)]
    cfg = podcast_tts.load_config(write_config(tmp_path))
    runner = FakeRunner()
    commands = podcast_tts.assemble(
        audio_paths=paths,
        paragraph_ids=PARAGRAPH_IDS,
        config=cfg,
        out_path=tmp_path / "episode.mp3",
        work_dir=tmp_path / "work",
        run=runner,
    )
    assert len(runner.commands) == 2, (
        f"expected exactly two ffmpeg passes, got {len(runner.commands)}: {runner.commands!r}"
    )
    assert [list(map(str, cmd)) for cmd in commands] == [
        list(map(str, cmd)) for cmd in runner.commands
    ], "assemble must return the argv lists it ran"
    return cfg, runner.commands


def _joined(commands):
    return " ".join(" ".join(str(part) for part in cmd) for cmd in commands)


def test_pass_one_measures_with_loudnorm(tmp_path):
    _, commands = _commands(tmp_path)
    pass1 = " ".join(str(part) for part in commands[0])
    assert "loudnorm" in pass1, pass1
    assert "print_format=json" in pass1, f"pass 1 must ask for the measurement JSON: {pass1}"
    assert "measured_I" not in pass1, "pass 1 measures; it must not already apply values"


def test_pass_two_applies_the_measured_values(tmp_path):
    _, commands = _commands(tmp_path)
    pass2 = " ".join(str(part) for part in commands[1])
    expected = {
        "measured_I": r"-23(?:\.0+)?",
        "measured_TP": r"-2(?:\.0+)?",
        "measured_LRA": r"7(?:\.0+)?",
        "measured_thresh": r"-33(?:\.0+)?",
        "offset": r"0(?:\.0+)?",
    }
    for key, number in expected.items():
        pattern = rf"{key}={number}\b"
        assert re.search(pattern, pass2), (
            f"pass 2 must carry {key} from the pass-1 JSON ({pattern}): {pass2}"
        )
    assert re.search(r"loudnorm=[^\s]*-?I=-16", pass2), (
        f"pass 2 must apply the -16 LUFS target: {pass2}"
    )
    assert "TP=-1.5" in pass2, f"pass 2 must apply TP=-1.5: {pass2}"
    assert "LRA=11" in pass2, f"pass 2 must apply LRA=11: {pass2}"


def test_the_mp3_pass_encodes_mono_24k_at_the_configured_bitrate(tmp_path):
    cfg, commands = _commands(tmp_path)
    bitrate = field(cfg, "bitrate")
    text = " ".join(str(part) for part in commands[-1])
    assert "-b:a" in text, f"the mp3 pass sets no audio bitrate: {text}"
    assert bitrate in text, f"the mp3 pass does not use bitrate {bitrate!r}: {text}"
    assert re.search(r"(-ar|sample_rate=)\s*24000", text), f"not 24 kHz: {text}"
    assert re.search(r"(-ac|-channels|channel_layout=mono|mono)", text), f"not mono: {text}"


def test_silence_padding_uses_both_configured_pauses(tmp_path):
    cfg, commands = _commands(tmp_path)
    text = _joined(commands)
    # 350 ms between two chunks of the same paragraph, 800 ms between paragraphs,
    # expressed either in seconds (0.35, 0.8) or in milliseconds (350, 800).
    assert re.search(r"(?:0\.35\d*|\b350m?s?\b|\b350\b)", text), (
        f"no {field(cfg, 'pause_ms')} ms chunk pause in the assembly: {text}"
    )
    assert re.search(r"(?:0\.8\d*|\b800m?s?\b|\b800\b)", text), (
        f"no {field(cfg, 'paragraph_pause_ms')} ms paragraph pause in the assembly: {text}"
    )


def test_pass_one_json_is_parsed_not_guessed(tmp_path):
    """The second pass must carry the canned numbers, not the spec defaults."""
    _, commands = _commands(tmp_path)
    pass2 = " ".join(str(part) for part in commands[1])
    assert "-23" in pass2 and "-33" in pass2
    assert "input_i" not in pass2, "the raw pass-1 JSON must not leak into pass 2"
    assert CANNED_LOUDNORM.strip().splitlines()[0] not in pass2


# --------------------------------------------------------------------------- #
# AC-1: pass 1 must only measure                                             #
# --------------------------------------------------------------------------- #

def _outputs(cmd):
    """Split one ffmpeg argv into (mapped label, argv tail) per output.

    Every output of a pass starts at its `-map`, so the `-map` positions are the
    output boundaries and the argument right after each is the label it maps.
    """
    cmd = [str(part) for part in cmd]
    maps = [index for index, part in enumerate(cmd) if part == "-map"]
    assert maps, f"no -map in the ffmpeg command: {cmd}"
    ends = maps[1:] + [len(cmd)]
    return [(cmd[start + 1], cmd[start + 2:stop]) for start, stop in zip(maps, ends)]


def _labels_fed_by(graph, needle):
    """The output labels of the filter chains in `graph` that name `needle`."""
    labels = set()
    for node in graph.split(";"):
        if needle not in node:
            continue
        match = re.search(r"\[([^\]]+)\]\s*$", node)
        if match:
            labels.add(match.group(1))
    return labels


def _output_format(tail):
    """The `-f` format of an output tail, or None when it is inferred."""
    if "-f" in tail:
        position = tail.index("-f")
        if position + 1 < len(tail):
            return tail[position + 1]
    return None


def test_pass1_measures_only_and_leaves_the_intermediate_wav_plain(tmp_path):
    """AC-1: the intermediate WAV is the plain concat, and the loudnorm branch is
    discarded with -f null, so pass 2 applies the measurement to unnormalised
    audio instead of normalising the same audio twice."""
    _, commands = _commands(tmp_path)
    cmd1 = [str(part) for part in commands[0]]
    graph = cmd1[cmd1.index("-filter_complex") + 1]

    assert "print_format=json" in graph, (
        f"pass 1 must still ask loudnorm for the measurement JSON: {graph}"
    )
    assert "measured_I" not in " ".join(cmd1), (
        "pass 1 measures; it must not carry the values it is supposed to produce"
    )

    loudnorm_labels = _labels_fed_by(graph, "loudnorm")
    assert loudnorm_labels, f"pass 1 has no loudnorm measurement branch: {graph}"

    outputs = _outputs(cmd1)
    assert len(outputs) == 2, (
        "pass 1 must write exactly two outputs - the plain concat to the intermediate "
        f"WAV and the loudnorm measurement to -f null - got {outputs!r}"
    )
    measured = [tail for label, tail in outputs if label in loudnorm_labels]
    plain = [(label, tail) for label, tail in outputs if label not in loudnorm_labels]
    assert len(measured) == 1, (
        f"the loudnorm branch must feed exactly one output: {outputs!r}"
    )
    assert len(plain) == 1, (
        "the intermediate WAV must be written from the concat branch, which must not "
        f"pass through loudnorm: {outputs!r} (loudnorm feeds {sorted(loudnorm_labels)})"
    )

    measured_tail = measured[0]
    assert _output_format(measured_tail) == "null", (
        "the loudnorm branch must be thrown away with -f null instead of being written "
        f"to the intermediate WAV: {measured_tail!r}"
    )
    assert measured_tail[-1] in ("-", "/dev/null"), (
        f"the -f null measurement needs a discard sink, got {measured_tail[-1]!r}"
    )

    _, plain_tail = plain[0]
    assert _output_format(plain_tail) != "null", (
        f"the plain concat branch must be written to a real file: {plain_tail!r}"
    )
    assert plain_tail[-1].endswith(".wav"), (
        "the intermediate WAV must come from the plain concat branch, got "
        f"{plain_tail[-1]!r}"
    )
