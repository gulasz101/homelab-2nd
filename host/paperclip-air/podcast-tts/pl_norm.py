#!/usr/bin/env python3
"""Polish text normalisation for TTS (chatterbox-multilingual).

Ported from the bake-off prototype (`tts-bakeoff/pl_norm.py`) for GUL-1749. The
listening test that produced it named three defects, all of them a text-layer
problem rather than an engine problem:

  - numbers/abbreviations: "1,5 mld zł", "23 proc.", "OSW", "17 grudnia", "2025"
    -> chatterbox read the whole sentence as gibberish with a foreign accent;
  - English phrases inside Polish text: "science fiction" was read with Polish
    spelling ("skience fiktion");
  - Polish proper nouns with digraphs can lose a letter ("Chin" -> "cin"), which
    needs per-word phonetic respelling, not a generic rule.

This module does the parts that can be done mechanically (numbers, units,
abbreviations, a small foreign-phrase dictionary) and leaves the rest to the
explicit respelling dictionary (`respell.toml`) that a human ears-checks.

Run `python3 pl_norm.py` to print the self-test table.
"""
from __future__ import annotations

import re

ONES = ["zero", "jeden", "dwa", "trzy", "cztery", "pięć", "sześć", "siedem",
        "osiem", "dziewięć", "dziesięć", "jedenaście", "dwanaście", "trzynaście",
        "czternaście", "piętnaście", "szesnaście", "siedemnaście", "osiemnaście",
        "dziewiętnaście"]
TENS = {2: "dwadzieścia", 3: "trzydzieści", 4: "czterdzieści", 5: "pięćdziesiąt",
        6: "sześćdziesiąt", 7: "siedemdziesiąt", 8: "osiemdziesiąt", 9: "dziewięćdziesiąt"}
HUNDREDS = {1: "sto", 2: "dwieście", 3: "trzysta", 4: "czterysta", 5: "pięćset",
            6: "sześćset", 7: "siedemset", 8: "osiemset", 9: "dziewięćset"}

# Phrase-level fixes: English words inside Polish copy, and abbreviations that
# must be spoken out in full. Keys are matched case-insensitively. The same
# table is seeded into `respell.toml`, so a listening note can change it without
# touching this file; this copy keeps `python3 pl_norm.py` self-testing on its
# own.
PHRASES = {
    "science fiction": "sajens fikszyn",
    "smart city": "smart siti",
    "machine learning": "maszyn lernin",
    "open source": "open sors",
    "OSW": "Ośrodka Studiów Wschodnich",
    "UE": "Unii Europejskiej",
    "USA": "Stanów Zjednoczonych",
    "np.": "na przykład",
    "itd.": "i tak dalej",
    "itp.": "i tym podobne",
    "km": "kilometrów",
    "GB": "gigabajtów",
}

# Abbreviations that stay behind after the numeric passes and must be spoken.
ABBREVIATIONS = {
    "r.": "roku",
    "tys.": "tysięcy",
    "mld.": "miliardów",
    "mln.": "milionów",
}

# Per-word phonetic respellings that needed a human ear. `respell.toml` is the
# place to add new ones; these two are the prototype's confirmed entries.
RESPELL = {
    # Wojtek, 2026-11-18, listening to chatterbox-v2/para01: "Chin" heard as "cin",
    # "całej" heard as "kałej". Both confirmed acoustically (see probe_*.py).
    # "całej" -> "tsałej": engine read "c" as /k/ (stop closure + 1.0 kHz burst);
    #   "ts" produced the alveolar affricate (4.4 kHz burst, 90 ms) = correct.
    "całej": "tsałej",
    # "Chin" -> "Hin": Polish h and ch are the same /x/, so "Hin" is phonetically
    #   exact. The engine did render [ç] either way, but the devoiced "z"->[s]
    #   dragged 180 ms and the pair fused into one sibilant; "H" cut the fused run
    #   to 90 ms and dropped the 4 kHz+ energy that made it sound like "c".
    "Chin": "Hin",
}

DIGITS = re.compile(r"[0-9]")


def int_words(n, ordinal_genitive_year=False):
    """Cardinal Polish numerals for 0..999999. `ordinal_genitive_year` renders a
    year the way it is spoken: 2025 -> 'dwa tysiące dwudziestego piątego'."""
    if n == 0:
        return ONES[0]
    parts = []
    if n >= 1000:
        th = n // 1000
        parts.append(int_words(th))
        if th == 1:
            parts.append("tysiąc")
        elif th % 10 in (2, 3, 4) and th % 100 not in (12, 13, 14):
            parts.append("tysiące")
        else:
            parts.append("tysięcy")
        n %= 1000
        if n == 0:
            return " ".join(parts)
    if n >= 100:
        parts.append(HUNDREDS[n // 100])
        n %= 100
    if n >= 20:
        parts.append(TENS[n // 10])
        n %= 10
    if n:
        parts.append(ONES[n])
    out = " ".join(p for p in parts if p)
    if ordinal_genitive_year:
        # only the final word takes the genitive ending, which is what a spoken
        # year sounds like: dwa tysiące dwudziestego piątego
        gen = {"jeden": "pierwszego", "dwa": "drugiego", "trzy": "trzeciego",
               "cztery": "czwartego", "pięć": "piątego", "sześć": "szóstego",
               "siedem": "siódmego", "osiem": "ósmego", "dziewięć": "dziewiątego",
               "dziesięć": "dziesiątego", "jedenaście": "jedenastego",
               "dwanaście": "dwunastego", "trzynaście": "trzynastego",
               "czternaście": "czternastego", "piętnaście": "piętnastego",
               "szesnaście": "szesnastego", "siedemnaście": "siedemnastego",
               "osiemnaście": "osiemnastego", "dwadzieścia": "dwudziestego",
               "trzydzieści": "trzydziestego", "czterdzieści": "czterdziestego",
               "pięćdziesiąt": "pięćdziesiątego", "sześćdziesiąt": "sześćdziesiątego",
               "siedemdziesiąt": "siedemdziesiątego", "osiemdziesiąt": "osiemdziesiątego",
               "dziewięćdziesiąt": "dziewięćdziesiątego"}
        # tens + ones pairs need both words inflected: dwadzieścia piątego
        words = out.split(" ")
        if len(words) >= 2 and words[-2] in ("dwadzieścia", "trzydzieści", "czterdzieści",
                                             "pięćdziesiąt", "sześćdziesiąt",
                                             "siedemdziesiąt", "osiemdziesiąt",
                                             "dziewięćdziesiąt"):
            return " ".join(words[:-2] + [gen[words[-2]], gen[words[-1]]])
        return " ".join(words[:-1] + [gen.get(words[-1], words[-1])])
    return out


def decimal_words(s):
    """'1,5' -> 'jeden i pół'; '3,5' -> 'trzy i pół'."""
    whole, _, frac = s.partition(",")
    half = {"5": "pół"}.get(frac)
    if half:
        return f"{int_words(int(whole))} i {half}"
    return f"{int_words(int(whole))} przecinek {' '.join(ONES[int(d)] for d in frac)}"


MONTHS = ("stycznia|lutego|marca|kwietnia|maja|czerwca|lipca|sierpnia|"
          "września|października|listopada|grudnia")

_DAY_GEN = {1: "pierwszego", 2: "drugiego", 3: "trzeciego", 4: "czwartego",
            5: "piątego", 6: "szóstego", 7: "siódmego", 8: "ósmego",
            9: "dziewiątego", 10: "dziesiątego", 11: "jedenastego",
            12: "dwunastego", 13: "trzynastego", 14: "czternastego",
            15: "piętnastego", 16: "szesnastego", 17: "siedemnastego",
            18: "osiemnastego", 19: "dziewiętnastego", 20: "dwudziestego",
            21: "dwudziestego pierwszego", 22: "dwudziestego drugiego",
            23: "dwudziestego trzeciego", 24: "dwudziestego czwartego",
            25: "dwudziestego piątego", 26: "dwudziestego szóstego",
            27: "dwudziestego siódmego", 28: "dwudziestego ósmego",
            29: "dwudziestego dziewiątego", 30: "trzydziestego",
            31: "trzydziestego pierwszego"}


def _num_words(num):
    return decimal_words(num) if "," in num else int_words(int(num))


def _money(m):
    """'1,5 mld zł' / '2025 zł' -> spoken Polish. Money goes before any bare-number
    rule, or '2025 zł' gets read as a year."""
    num, unit = m.group(1), m.group(2)
    unit_spoken = {"mld": "miliarda złotych", "mln": "milionów złotych",
                   "tys": "tysięcy złotych", None: "złotych"}[unit]
    return f"{_num_words(num)} {unit_spoken}"


def has_leftover_digit(text):
    """True when a digit survived normalisation, i.e. a number no rule speaks."""
    return bool(DIGITS.search(text))


def normalise(text):
    # 1. multi-word fixes (English phrases, abbreviations)
    for k, v in PHRASES.items():
        text = re.sub(r"(?<![\w.])" + re.escape(k) + r"(?![\w])", v, text,
                      flags=re.IGNORECASE)
    # 2. money and units before bare numbers, or "2025 zł" gets read as a year
    text = re.sub(r"\b(\d+(?:,\d+)?)\s*(?:(mld|mln|tys)\s*)?zł\b", _money, text)
    text = re.sub(r"\b(\d+(?:,\d+)?)\s*(?:(proc|procent)\.?)?\s*%",
                  lambda m: _num_words(m.group(1)) + " procent", text)
    text = re.sub(r"\b(\d+(?:,\d+)?)\s*(proc|procent)\.?",
                  lambda m: _num_words(m.group(1)) + " procent", text)
    text = re.sub(r"\b(\d+(?:,\d+)?)\s*(mld|mln)\b",
                  lambda m: _num_words(m.group(1)) + " " +
                  {"mld": "miliarda", "mln": "milionów"}[m.group(2)], text)
    # 3. dates: "17 grudnia" -> "siedemnastego grudnia"
    text = re.sub(r"\b(\d{1,2})\s+(" + MONTHS + r")\b",
                  lambda m: _DAY_GEN.get(int(m.group(1)), int_words(int(m.group(1))))
                  + " " + m.group(2), text)
    # 4. a 4-digit number followed by "roku"/"r." is a spoken year (ordinal)
    text = re.sub(r"\b(1[0-9]{3}|20[0-9]{2})\b(?=\s*(roku|r\.|$))",
                  lambda m: int_words(int(m.group(1)), True), text)
    # 5. any remaining 4-digit number in year range is almost always a year
    text = re.sub(r"\b(19\d{2}|20\d{2})\b", lambda m: int_words(int(m.group(1)), True), text)
    # 6. leftover decimals and integers
    text = re.sub(r"\b(\d+),(\d+)\b", lambda m: decimal_words(m.group(0)), text)
    text = re.sub(r"\b\d+\b", lambda m: int_words(int(m.group(0))), text)
    # 7. abbreviations the numeric passes leave behind ("2025 r." -> "... roku")
    lowered = {k.lower(): v for k, v in ABBREVIATIONS.items()}
    text = re.sub(r"\b([A-Za-z]{1,4}\.)",
                  lambda m: lowered.get(m.group(1).lower(), m.group(1)), text)
    for k, v in RESPELL.items():
        text = re.sub(r"\b" + re.escape(k) + r"\b", v, text)
    return re.sub(r"\s+", " ", text).strip()


TESTS = [
    ("numbers", "W 2025 roku rynek smartfonów na kółkach w Polsce był wart 1,5 mld zł, "
                "a sprzedaż wzrosła o 23 proc. — tak wynika z raportu OSW z 17 grudnia."),
    ("para01-head", "Temat, o którym porozmawiamy, brzmi jak tytuł filmu science fiction, "
                    "ale to rzeczywistość roku dwa tysiące dwudziestego piątego."),
    ("small", "3,5 proc. z 17 samochodów i 2025 zł w 2025 roku."),
    ("leftover", "Nowy model X5Q trafił właśnie do sprzedaży."),
]

if __name__ == "__main__":
    for label, t in TESTS:
        out = normalise(t)
        flag = "  <-- DIGIT LEFT" if has_leftover_digit(out) else ""
        print(label)
        print("  in :", t)
        print("  out:", out + flag)
        print()
