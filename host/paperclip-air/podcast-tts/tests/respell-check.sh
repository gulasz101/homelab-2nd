#!/usr/bin/env bash
# GUL-2026: the four ear-confirmed respellings are in the shipped dictionary and
# are applied by `normalise_text` before the engine sees the chunk.
#
#   bash tests/respell-check.sh          # every AC, for `scripts/check.sh`
#   bash tests/respell-check.sh --ac 2   # one AC, for the factory's AC runner
#
# The factory reads one `AC-n: PASS|FAIL` line per assigned AC and treats a line
# for any other AC as a setup error, so `--ac N` prints only AC-N's line.
# Stdlib only: no pytest on this box (2026-11-22, `No module named pytest`), and
# CI has no venv for host/ -- the assertions are the same ones the pytest cases
# in tests/test_respell.py make.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT=$(cd "$HERE/.." && pwd)
AC=${2:-}

if [ -n "$AC" ]; then
  case "$AC" in
    AC-[0-9]|AC-[0-9][0-9]) : ;;
    *) echo "usage: $0 [--ac AC-n]" >&2; exit 2 ;;
  esac
elif [ "${1:-}" = "" ]; then
  AC=""
else
  echo "usage: $0 [--ac AC-n]" >&2; exit 2
fi

python3 - "$PROJECT" "$AC" <<'PY'
import re
import sys

project, wanted = sys.argv[1], sys.argv[2]
sys.path.insert(0, project)

import pl_norm  # noqa: E402
import podcast_tts  # noqa: E402

RESPELL = podcast_tts.load_respell(project + "/respell.toml")

# The probe sentences from GUL-2024 (s1-B.mp3, s2-B.mp3): the four phrases as
# they appeared in the article, each inside a normal Polish sentence so the
# match, the numeric pass and the word pass all run.
SENTENCES = {
    "Intelligent and Connected Vehicles": (
        "Systemy Intelligent and Connected Vehicles zmieniaja rynek.",
        "Systemy inteligent end konektyd wijikls zmieniaja rynek.",
    ),
    "zhineng wanglian qiche": (
        "Chinski zhineng wanglian qiche rozwija sie szybko.",
        "Chinski czyneng wanglian czicze rozwija sie szybko.",
    ),
    "ICV": (
        "Nowy standard ICV jest juz wdrazany w Europie.",
        "Nowy standard i si wi jest juz wdrazany w Europie.",
    ),
    "BeiDou": (
        "BeiDou to chinski system nawigacji satelitarnej.",
        "bejdou to chinski system nawigacji satelitarnej.",
    ),
}
NEW_KEYS = {
    "Intelligent and Connected Vehicles": "inteligent end konektyd wijikls",
    "zhineng wanglian qiche": "czyneng wanglian czicze",
    "ICV": "i si wi",
    "BeiDou": "bejdou",
}
PLAIN = "Przyjecie ustawy towarzyszyla dluga debata."


def check_phrases(keys):
    """Each key normalises to its respelling, inside a sentence, and no digit survives."""
    reasons = []
    for key in keys:
        text, expected = SENTENCES[key]
        out = podcast_tts.normalise_text(text, RESPELL)
        if RESPELL.phrases.get(key) != NEW_KEYS[key]:
            reasons.append("%r missing from [phrases]" % key)
            continue
        if out != expected:
            reasons.append("%r -> %r, wanted %r" % (key, out, expected))
            continue
        if re.search(r"[0-9]", out):
            reasons.append("%r leaves a digit in %r" % (key, out))
    return reasons


def ac1():
    return check_phrases(["Intelligent and Connected Vehicles", "zhineng wanglian qiche"])


def ac2():
    return check_phrases(["ICV", "BeiDou"])


def ac3():
    """No over-matching: the entries live in [phrases] and leave plain Polish alone."""
    reasons = []
    missing = [key for key, value in NEW_KEYS.items() if RESPELL.phrases.get(key) != value]
    if missing:
        reasons.append("[phrases] missing %s" % ", ".join(repr(k) for k in missing))
    for key in NEW_KEYS:
        if RESPELL.words.get(key) or NEW_KEYS[key] in RESPELL.words.values():
            reasons.append("%r is in [words]; it belongs in [phrases]" % key)
    out = podcast_tts.normalise_text(PLAIN, RESPELL)
    if out != pl_norm.normalise(PLAIN):
        reasons.append("a plain Polish sentence changed: %r" % out)
    return reasons


ACS = {"AC-1": ac1, "AC-2": ac2, "AC-3": ac3}
names = [wanted] if wanted else sorted(ACS)
unknown = [n for n in names if n not in ACS]
if unknown:
    sys.exit("unknown AC: %s" % ", ".join(unknown))

bad = 0
for name in names:
    reasons = ACS[name]()
    if reasons:
        bad += 1
        print("%s: FAIL %s" % (name, "; ".join(reasons[:3])))
    else:
        print("%s: PASS" % name)
sys.exit(1 if bad else 0)
PY
