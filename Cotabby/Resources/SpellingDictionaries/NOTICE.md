# Bundled Spelling Dictionaries

Cotabby bundles language-specific frequency dictionaries for its Swift port of
[SymSpell](https://github.com/wolfgarbe/SymSpell). The dictionaries remain separate at runtime;
their corpus counts are never merged or compared across languages.

## English

`frequency_dictionary_en_82_765.txt` is stored one directory above this notice. It is SymSpell's
English dictionary derived from Google Books Ngram frequencies and SCOWL. Its notice is documented
in the repository-level `THIRD_PARTY_LICENSES.md`.

## Multilingual Dictionaries

The following files are unmodified copies from SymSpell commit
`b8b2905bde` (March 13, 2020):

| File | Language | SHA-256 |
| --- | --- | --- |
| `de-100k.txt` | German | `a98c27cbe0921cb3a9927eb28639efb45fc3493f72466cca0622c64dff4e74a9` |
| `es-100l.txt` | Spanish | `fd538cb220cd00d0a9f20d2190ba6f033b76f91ee08c6c0df8fadbf46bbdf319` |
| `fr-100k.txt` | French | `b7dca46c0002daa0c6d70e1078bef4110815f65b0c90c35be1ae900ba2f5e9fc` |
| `he-100k.txt` | Hebrew | `b1305dc929be951e20d50440585a627b4c9d95e2044122a73b33a0ba25b713d9` |
| `it-100k.txt` | Italian | `5f746afb7e6ae802872061ef025ce883cfa2a8779780968fa285dfd0907e9cfc` |
| `ru-100k.txt` | Russian | `2028262759546fdc346386369a59541d0464f48634c3103ff3f36d01518efcc6` |

SymSpell generated these datasets by intersecting Google Books Ngram frequencies with Hunspell
word lists from `wooorm/dictionaries`. The source notices bundled here were captured from
`wooorm/dictionaries` commit `5ede45bb705d3f9f525ea779f7b487f9fc062013` (March 1, 2020), the
latest repository revision before SymSpell published these derived files.

| Language | Historical package license | Bundled notice |
| --- | --- | --- |
| German | GPL-2.0 or GPL-3.0 | `Licenses/de.txt` |
| Spanish | GPL-3.0, LGPL-3.0, or MPL-1.1 | `Licenses/es.txt` |
| French | MPL-2.0 | `Licenses/fr.txt` |
| Hebrew | AGPL-3.0 | `Licenses/he.txt` |
| Italian | GPL-3.0 | `Licenses/it.txt` |
| Russian | Package metadata: LGPL-3.0; source notice contains additional redistribution terms | `Licenses/ru.txt` |

Complete GPL-3.0, LGPL-3.0, AGPL-3.0, MPL-2.0, and CC BY-SA 4.0 texts are included in `Licenses/`.

## Turkish and Macedonian

SymSpell publishes no Turkish or Macedonian dictionary, so these two files were built with the same
method SymSpell used (corpus frequencies intersected with a Hunspell word list) by
`scripts/build_hunspell_frequency_dictionary.py`, which reproduces them byte for byte:

| File | Language | SHA-256 |
| --- | --- | --- |
| `tr-100k.txt` | Turkish | `6c927006c2b3330bbb73675970f2ef21b8f36e19c9750d9989e47253dd7366f3` |
| `mk-100k.txt` | Macedonian | `034f5022fb98c9bbd1b3951c95fb58501fcac0fe07ea6a07ea5cf3e43a6f963d` |

- **Frequencies:** `hermitdave/FrequencyWords` commit `525f9b560de45753a5ea01069454e72e9aa541c6`,
  `content/2018/{tr,mk}/*_full.txt`, generated from the OpenSubtitles 2018 corpus
  (P. Lison and J. Tiedemann, 2016, "OpenSubtitles2016: Extracting Large Parallel Corpora from Movie
  and TV Subtitles", http://opus.nlpl.eu/OpenSubtitles2018.php; http://www.opensubtitles.org/).
  FrequencyWords licenses its content under CC BY-SA 4.0 (`Licenses/CC-BY-SA-4.0.txt`); the two
  derived files are distributed under the same license.
- **Spelling validation:** `wooorm/dictionaries` commit `8cfea406b505e4d7df52d5a19bce525df98c54ab`,
  checked with Hunspell 1.7.4. Only words Hunspell accepts are kept.

| Language | Hunspell dictionary license | Bundled notice |
| --- | --- | --- |
| Turkish | MIT (Harun Reşit Zafer) | `Licenses/tr.txt` |
| Macedonian | GPL-3.0-or-later (Dimitrij Mijoski) | `Licenses/mk.txt` |

Google Books Ngram data is licensed under
[CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).
