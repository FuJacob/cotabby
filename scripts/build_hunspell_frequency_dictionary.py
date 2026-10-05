#!/usr/bin/env python3
"""Build a SymSpell frequency dictionary for a language SymSpell does not publish.

SymSpell's multilingual dictionaries were made by intersecting corpus word frequencies with
Hunspell word lists. This script does the same for Turkish (tr) and Macedonian (mk) from
pinned, openly licensed sources:

  * word frequencies: hermitdave/FrequencyWords, OpenSubtitles 2018 "full" list
    (content CC BY-SA 4.0)
  * spelling validation: wooorm/dictionaries Hunspell files, checked with the `hunspell` CLI
    (tr: MIT, mk: GPL-3.0-or-later)

Only alphabetic words that Hunspell accepts are kept, most frequent first, capped at 100,000.
Hunspell is run on each word (not matched against the .dic stems) because Turkish and
Macedonian are inflected: most valid word forms never appear literally in the stem list.

Usage:  scripts/build_hunspell_frequency_dictionary.py tr|mk OUTPUT_DIR
Requires: hunspell on PATH (`brew install hunspell`), network access.
"""

import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

FREQUENCY_WORDS_COMMIT = "525f9b560de45753a5ea01069454e72e9aa541c6"
DICTIONARIES_COMMIT = "8cfea406b505e4d7df52d5a19bce525df98c54ab"
MAX_WORDS = 100_000
# Turkish's full list has ~2M rows; the first 400k frequency-ranked rows already yield far more
# than MAX_WORDS valid words, and validating the long tail would only add noise and time.
CANDIDATE_LIMIT = {"tr": 400_000, "mk": None}


def fetch(url: str, destination: Path) -> None:
    with urllib.request.urlopen(url) as response:
        destination.write_bytes(response.read())


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in CANDIDATE_LIMIT:
        print(__doc__)
        return 2
    language, output_dir = sys.argv[1], Path(sys.argv[2])
    with tempfile.TemporaryDirectory() as work:
        work_dir = Path(work)
        frequencies = work_dir / f"{language}_full.txt"
        fetch(
            f"https://raw.githubusercontent.com/hermitdave/FrequencyWords/{FREQUENCY_WORDS_COMMIT}"
            f"/content/2018/{language}/{language}_full.txt",
            frequencies,
        )
        for extension in ("aff", "dic"):
            fetch(
                f"https://raw.githubusercontent.com/wooorm/dictionaries/{DICTIONARIES_COMMIT}"
                f"/dictionaries/{language}/index.{extension}",
                work_dir / f"index.{extension}",
            )

        rows = []
        limit = CANDIDATE_LIMIT[language]
        for line in frequencies.read_text(encoding="utf-8").splitlines():
            parts = line.split()
            if len(parts) != 2 or not parts[0].isalpha() or len(parts[0]) > 40:
                continue
            rows.append((parts[0], int(parts[1])))
            if limit and len(rows) >= limit:
                break

        accepted = subprocess.run(
            ["hunspell", "-d", str(work_dir / "index"), "-G", "-i", "utf-8"],
            input="\n".join(word for word, _ in rows).encode("utf-8"),
            capture_output=True,
            check=True,
        ).stdout.decode("utf-8")
        valid = set(accepted.splitlines())
        kept = [(word, count) for word, count in rows if word in valid][:MAX_WORDS]

    output = output_dir / f"{language}-100k.txt"
    output.write_text("".join(f"{word} {count}\n" for word, count in kept), encoding="utf-8")
    print(f"{language}: {len(rows)} candidates, {len(kept)} kept -> {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
