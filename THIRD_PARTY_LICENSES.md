# Third-Party Licenses

Cotabby is licensed under the GNU Affero General Public License v3.0 (see
[`LICENSE`](LICENSE)). It bundles third-party software and data that keep their own
licenses; the notices that ask to be reproduced are included below.

The Swift package dependencies Cotabby links against (llama.cpp, CotabbyInference,
Sparkle, swift-log) are credited in the in-app Acknowledgements
(Settings → About → Acknowledgements) and in the README, each linking to its
upstream license text.

## SymSpell

The inline autocorrect feature uses a Swift port of SymSpell (Wolf Garbe's
Symmetric Delete spelling-correction algorithm). The port lives in
`Cotabby/Support/SymSpell.swift`. SymSpell is distributed under the MIT License:

```
MIT License

Copyright (c) 2018 Wolf Garbe

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Upstream: https://github.com/wolfgarbe/SymSpell

## Frequency dictionaries

`Cotabby/Resources/frequency_dictionary_en_82_765.txt` is the English frequency
dictionary that ships with SymSpell. Per SymSpell, it is derived from two sources.

### Google Books Ngram data (CC BY 3.0)

The word frequencies are derived from the Google Books Ngram dataset, released under
the Creative Commons Attribution 3.0 Unported license (CC BY 3.0). The data is used
in derived form (word/frequency pairs).

- Dataset: https://books.google.com/ngrams
- License: https://creativecommons.org/licenses/by/3.0/

### SCOWL (Spell Checker Oriented Word Lists)

The word list is derived from SCOWL by Kevin Atkinson:

```
Copyright 2000-2026 by Kevin Atkinson

Permission to use, copy, modify, distribute, and sell any part of the English
Speller Database (ESDB, previously known as SCOWLv2), or word lists
created from it, is hereby granted without fee, provided that the above
copyright notice appears in all copies and that both the above copyright
notice and this notice appear in supporting documentation. Kevin Atkinson
makes no representations about the suitability of this database for any
purpose. It is provided "as is" without express or implied warranty.
```

SCOWL itself incorporates material from several sources (12dicts by Alan Beale,
ENABLE2K, the UK Advanced Cryptics Dictionary by J Ross Beresford, WordNet by
Princeton University, and others). Their individual copyright notices are in the
full SCOWL copyright file.

- Project: http://wordlist.aspell.net/
- Full copyright: https://github.com/en-wl/wordlist/blob/v2/Copyright

### Multilingual dictionaries

Cotabby also bundles the German, Spanish, French, Hebrew, Italian, and Russian
frequency dictionaries published in SymSpell's `SymSpell.FrequencyDictionary`
folder at commit `b8b2905bde` (March 13, 2020). SymSpell generated these by
intersecting Google Books Ngram frequencies with Hunspell word lists.

The exact source notices, applicable full license texts, upstream commits, and
file checksums are bundled with the app under:

`Cotabby/Resources/SpellingDictionaries/NOTICE.md`

The corresponding source word-list notices were captured from
`wooorm/dictionaries` commit
`5ede45bb705d3f9f525ea779f7b487f9fc062013`, the latest revision before
SymSpell published the derived multilingual files.

Chinese is intentionally not bundled: SymSpell's generation notes do not identify
the source word list and license for that file, and Cotabby's current typo gate does
not yet provide reliable word segmentation for languages without whitespace.
