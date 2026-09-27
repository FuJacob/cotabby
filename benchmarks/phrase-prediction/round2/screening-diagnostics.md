# Historical screening diagnostics

Descriptive diagnostics from the already-inspected140-case historical screening subset; no protected-fresh reports are read.

Completed alternatives: 12/12. Pending: none.

Accuracy uses recorded Swift correctness flags. Raw and shown changes compare exact strings; a wording change may leave exact-next-word correctness unchanged.

| Candidate | Context | Raw changed | Shown changed | Wrong → correct | Correct → wrong | Net correct |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| H1 | screen | 167/770 | 167/770 | 4 | 8 | -4 |
| H1 | none | 59/770 | 59/770 | 0 | 0 | +0 |
| H2 | screen | 62/770 | 62/770 | 1 | 3 | -2 |
| H2 | none | 3/770 | 3/770 | 0 | 0 | +0 |
| H3 | screen | 7/770 | 7/770 | 0 | 0 | +0 |
| H3 | none | 0/770 | 0/770 | 0 | 0 | +0 |
| H4 | screen | 223/770 | 223/770 | 5 | 13 | -8 |
| H4 | none | 201/770 | 201/770 | 3 | 2 | +1 |
| F1 | screen | 286/770 | 286/770 | 12 | 15 | -3 |
| F1 | none | 0/770 | 0/770 | 0 | 0 | +0 |
| F2 | screen | 242/770 | 242/770 | 11 | 15 | -4 |
| F2 | none | 0/770 | 0/770 | 0 | 0 | +0 |
| F3 | screen | 398/770 | 398/770 | 16 | 24 | -8 |
| F3 | none | 0/770 | 0/770 | 0 | 0 | +0 |
| F4 | screen | 428/770 | 428/770 | 19 | 33 | -14 |
| F4 | none | 0/770 | 0/770 | 0 | 0 | +0 |
| M1 | screen | 256/770 | 256/770 | 10 | 17 | -7 |
| M1 | none | 361/770 | 361/770 | 12 | 10 | +2 |
| M2 | screen | 324/770 | 324/770 | 17 | 11 | +6 |
| M2 | none | 525/770 | 525/770 | 16 | 26 | -10 |
| M3 | screen | 386/770 | 386/770 | 12 | 36 | -24 |
| M3 | none | 579/770 | 579/770 | 23 | 48 | -25 |
| M4 | screen | 241/770 | 241/770 | 11 | 17 | -6 |
| M4 | none | 413/770 | 413/770 | 19 | 13 | +6 |

## H3 tie

H3 screen has 7 raw and 7 shown changes, with 0 wins and 0 losses; no-screen has 0 raw and 0 shown changes, with 0 wins and 0 losses. Recorded predicted-word changes: screen 0, no-screen 0. Changed screen continuations retain incorrect outcomes at 6 checkpoints and correct outcomes at 1. A tied score therefore must be interpreted using these transitions, not assumed to mean identical outputs.

## Category changes

Each cell lists net correct (wrong → correct / correct → wrong), followed by the number of changed shown outputs. Denominators and all zero-change cells are retained in JSON.

| Candidate | Context | Category | Net (wins / losses) | Shown changed |
| --- | --- | --- | ---: | ---: |
| H1 | screen | conversation | +0 (0 / 0) | 9/96 |
| H1 | screen | entertainment | +0 (0 / 0) | 18/111 |
| H1 | screen | everyday | -1 (0 / 1) | 9/105 |
| H1 | screen | science | +0 (1 / 1) | 40/108 |
| H1 | screen | technology | -2 (0 / 2) | 29/116 |
| H1 | screen | travel | -1 (2 / 3) | 35/120 |
| H1 | screen | work | +0 (1 / 1) | 27/114 |
| H1 | none | conversation | +0 (0 / 0) | 8/96 |
| H1 | none | entertainment | +0 (0 / 0) | 12/111 |
| H1 | none | everyday | +0 (0 / 0) | 3/105 |
| H1 | none | science | +0 (0 / 0) | 5/108 |
| H1 | none | technology | +0 (0 / 0) | 9/116 |
| H1 | none | travel | +0 (0 / 0) | 7/120 |
| H1 | none | work | +0 (0 / 0) | 15/114 |
| H2 | screen | conversation | +0 (0 / 0) | 6/96 |
| H2 | screen | entertainment | +0 (0 / 0) | 10/111 |
| H2 | screen | everyday | -1 (0 / 1) | 4/105 |
| H2 | screen | science | +0 (0 / 0) | 18/108 |
| H2 | screen | technology | -1 (0 / 1) | 12/116 |
| H2 | screen | travel | +0 (0 / 0) | 2/120 |
| H2 | screen | work | +0 (1 / 1) | 10/114 |
| H2 | none | conversation | +0 (0 / 0) | 1/96 |
| H2 | none | work | +0 (0 / 0) | 2/114 |
| H3 | screen | everyday | +0 (0 / 0) | 1/105 |
| H3 | screen | science | +0 (0 / 0) | 1/108 |
| H3 | screen | technology | +0 (0 / 0) | 2/116 |
| H3 | screen | work | +0 (0 / 0) | 3/114 |
| H4 | screen | conversation | -1 (0 / 1) | 17/96 |
| H4 | screen | entertainment | -2 (0 / 2) | 40/111 |
| H4 | screen | everyday | -2 (0 / 2) | 22/105 |
| H4 | screen | science | +0 (1 / 1) | 41/108 |
| H4 | screen | technology | -2 (1 / 3) | 44/116 |
| H4 | screen | travel | -1 (2 / 3) | 33/120 |
| H4 | screen | work | +0 (1 / 1) | 26/114 |
| H4 | none | conversation | -1 (0 / 1) | 30/96 |
| H4 | none | entertainment | +0 (0 / 0) | 32/111 |
| H4 | none | everyday | +0 (0 / 0) | 21/105 |
| H4 | none | science | +1 (1 / 0) | 15/108 |
| H4 | none | technology | +1 (1 / 0) | 41/116 |
| H4 | none | travel | +0 (1 / 1) | 27/120 |
| H4 | none | work | +0 (0 / 0) | 35/114 |
| F1 | screen | conversation | +0 (1 / 1) | 26/96 |
| F1 | screen | entertainment | +0 (1 / 1) | 40/111 |
| F1 | screen | everyday | +0 (2 / 2) | 39/105 |
| F1 | screen | science | +2 (4 / 2) | 39/108 |
| F1 | screen | technology | -2 (1 / 3) | 40/116 |
| F1 | screen | travel | -4 (1 / 5) | 45/120 |
| F1 | screen | work | +1 (2 / 1) | 57/114 |
| F2 | screen | conversation | +1 (1 / 0) | 27/96 |
| F2 | screen | entertainment | +0 (0 / 0) | 28/111 |
| F2 | screen | everyday | -4 (3 / 7) | 35/105 |
| F2 | screen | science | +2 (2 / 0) | 32/108 |
| F2 | screen | technology | -1 (2 / 3) | 41/116 |
| F2 | screen | travel | -3 (1 / 4) | 35/120 |
| F2 | screen | work | +1 (2 / 1) | 44/114 |
| F3 | screen | conversation | -4 (1 / 5) | 49/96 |
| F3 | screen | entertainment | -2 (1 / 3) | 66/111 |
| F3 | screen | everyday | +5 (8 / 3) | 65/105 |
| F3 | screen | science | +1 (3 / 2) | 40/108 |
| F3 | screen | technology | -1 (2 / 3) | 51/116 |
| F3 | screen | travel | -6 (1 / 7) | 69/120 |
| F3 | screen | work | -1 (0 / 1) | 58/114 |
| F4 | screen | conversation | -4 (1 / 5) | 50/96 |
| F4 | screen | entertainment | -4 (0 / 4) | 65/111 |
| F4 | screen | everyday | -3 (2 / 5) | 58/105 |
| F4 | screen | science | +0 (3 / 3) | 47/108 |
| F4 | screen | technology | +3 (4 / 1) | 63/116 |
| F4 | screen | travel | -9 (6 / 15) | 91/120 |
| F4 | screen | work | +3 (3 / 0) | 54/114 |
| M1 | screen | conversation | +1 (1 / 0) | 24/96 |
| M1 | screen | entertainment | -4 (0 / 4) | 42/111 |
| M1 | screen | everyday | +0 (2 / 2) | 28/105 |
| M1 | screen | science | -2 (1 / 3) | 38/108 |
| M1 | screen | technology | +0 (3 / 3) | 41/116 |
| M1 | screen | travel | -3 (2 / 5) | 45/120 |
| M1 | screen | work | +1 (1 / 0) | 38/114 |
| M1 | none | conversation | +3 (3 / 0) | 52/96 |
| M1 | none | entertainment | -2 (0 / 2) | 63/111 |
| M1 | none | everyday | +0 (3 / 3) | 53/105 |
| M1 | none | science | -1 (0 / 1) | 25/108 |
| M1 | none | technology | +0 (1 / 1) | 71/116 |
| M1 | none | travel | +1 (2 / 1) | 54/120 |
| M1 | none | work | +1 (3 / 2) | 43/114 |
| M2 | screen | conversation | -2 (0 / 2) | 40/96 |
| M2 | screen | entertainment | -2 (0 / 2) | 51/111 |
| M2 | screen | everyday | +4 (6 / 2) | 54/105 |
| M2 | screen | science | -1 (1 / 2) | 35/108 |
| M2 | screen | technology | +6 (6 / 0) | 53/116 |
| M2 | screen | travel | +0 (3 / 3) | 43/120 |
| M2 | screen | work | +1 (1 / 0) | 48/114 |
| M2 | none | conversation | -3 (0 / 3) | 76/96 |
| M2 | none | entertainment | +1 (3 / 2) | 85/111 |
| M2 | none | everyday | +0 (4 / 4) | 81/105 |
| M2 | none | science | -1 (1 / 2) | 40/108 |
| M2 | none | technology | +1 (3 / 2) | 85/116 |
| M2 | none | travel | -3 (3 / 6) | 66/120 |
| M2 | none | work | -5 (2 / 7) | 92/114 |
| M3 | screen | conversation | -3 (1 / 4) | 59/96 |
| M3 | screen | entertainment | -6 (2 / 8) | 70/111 |
| M3 | screen | everyday | -5 (0 / 5) | 50/105 |
| M3 | screen | science | -4 (2 / 6) | 45/108 |
| M3 | screen | technology | -2 (2 / 4) | 56/116 |
| M3 | screen | travel | -2 (5 / 7) | 64/120 |
| M3 | screen | work | -2 (0 / 2) | 42/114 |
| M3 | none | conversation | +1 (3 / 2) | 67/96 |
| M3 | none | entertainment | -3 (3 / 6) | 95/111 |
| M3 | none | everyday | +1 (5 / 4) | 79/105 |
| M3 | none | science | -9 (1 / 10) | 62/108 |
| M3 | none | technology | -2 (7 / 9) | 97/116 |
| M3 | none | travel | -6 (2 / 8) | 96/120 |
| M3 | none | work | -7 (2 / 9) | 83/114 |
| M4 | screen | conversation | -1 (0 / 1) | 26/96 |
| M4 | screen | entertainment | -3 (0 / 3) | 26/111 |
| M4 | screen | everyday | -1 (2 / 3) | 30/105 |
| M4 | screen | science | +1 (2 / 1) | 39/108 |
| M4 | screen | technology | +0 (4 / 4) | 45/116 |
| M4 | screen | travel | -2 (3 / 5) | 42/120 |
| M4 | screen | work | +0 (0 / 0) | 33/114 |
| M4 | none | conversation | +1 (2 / 1) | 53/96 |
| M4 | none | entertainment | +1 (2 / 1) | 64/111 |
| M4 | none | everyday | +0 (2 / 2) | 57/105 |
| M4 | none | science | +1 (1 / 0) | 35/108 |
| M4 | none | technology | +3 (3 / 0) | 81/116 |
| M4 | none | travel | +0 (5 / 5) | 67/120 |
| M4 | none | work | +0 (4 / 4) | 56/114 |

## Boundary changes

Every current observation is a word boundary before the target’s first letter. Prefix-ending labels describe literal punctuation, not a semantic sentence-boundary judgment. Target-form labels are descriptive reference-token shapes. These sparse groups are not separate validation sets.

| Candidate | Context | Boundary axis / label | Checkpoints | Shown changed | Wins / losses |
| --- | --- | --- | ---: | ---: | ---: |
| H1 | screen | phrasePosition / first_checkpoint | 140 | 37 | 0 / 0 |
| H1 | screen | phrasePosition / later_checkpoint | 630 | 130 | 4 / 8 |
| H1 | screen | prefixEnding / after_letter_or_digit | 770 | 167 | 4 / 8 |
| H1 | screen | targetForm / apostrophe | 7 | 1 | 0 / 0 |
| H1 | screen | targetForm / initial_capital | 6 | 1 | 0 / 0 |
| H1 | screen | targetForm / plain_word | 756 | 165 | 4 / 8 |
| H1 | none | phrasePosition / first_checkpoint | 140 | 19 | 0 / 0 |
| H1 | none | phrasePosition / later_checkpoint | 630 | 40 | 0 / 0 |
| H1 | none | prefixEnding / after_letter_or_digit | 770 | 59 | 0 / 0 |
| H1 | none | targetForm / initial_capital | 6 | 1 | 0 / 0 |
| H1 | none | targetForm / plain_word | 756 | 58 | 0 / 0 |
| H2 | screen | phrasePosition / first_checkpoint | 140 | 14 | 0 / 0 |
| H2 | screen | phrasePosition / later_checkpoint | 630 | 48 | 1 / 3 |
| H2 | screen | prefixEnding / after_letter_or_digit | 770 | 62 | 1 / 3 |
| H2 | screen | targetForm / plain_word | 756 | 62 | 1 / 3 |
| H2 | none | phrasePosition / first_checkpoint | 140 | 1 | 0 / 0 |
| H2 | none | phrasePosition / later_checkpoint | 630 | 2 | 0 / 0 |
| H2 | none | prefixEnding / after_letter_or_digit | 770 | 3 | 0 / 0 |
| H2 | none | targetForm / plain_word | 756 | 3 | 0 / 0 |
| H3 | screen | phrasePosition / first_checkpoint | 140 | 2 | 0 / 0 |
| H3 | screen | phrasePosition / later_checkpoint | 630 | 5 | 0 / 0 |
| H3 | screen | prefixEnding / after_letter_or_digit | 770 | 7 | 0 / 0 |
| H3 | screen | targetForm / plain_word | 756 | 7 | 0 / 0 |
| H4 | screen | phrasePosition / first_checkpoint | 140 | 48 | 0 / 0 |
| H4 | screen | phrasePosition / later_checkpoint | 630 | 175 | 5 / 13 |
| H4 | screen | prefixEnding / after_letter_or_digit | 770 | 223 | 5 / 13 |
| H4 | screen | targetForm / apostrophe | 7 | 4 | 0 / 0 |
| H4 | screen | targetForm / initial_capital | 6 | 1 | 0 / 1 |
| H4 | screen | targetForm / plain_word | 756 | 218 | 5 / 12 |
| H4 | none | phrasePosition / first_checkpoint | 140 | 51 | 1 / 0 |
| H4 | none | phrasePosition / later_checkpoint | 630 | 150 | 2 / 2 |
| H4 | none | prefixEnding / after_letter_or_digit | 770 | 201 | 3 / 2 |
| H4 | none | targetForm / apostrophe | 7 | 2 | 0 / 0 |
| H4 | none | targetForm / initial_capital | 6 | 2 | 0 / 0 |
| H4 | none | targetForm / plain_word | 756 | 197 | 3 / 2 |
| F1 | screen | phrasePosition / first_checkpoint | 140 | 61 | 2 / 1 |
| F1 | screen | phrasePosition / later_checkpoint | 630 | 225 | 10 / 14 |
| F1 | screen | prefixEnding / after_letter_or_digit | 770 | 286 | 12 / 15 |
| F1 | screen | targetForm / apostrophe | 7 | 5 | 0 / 0 |
| F1 | screen | targetForm / hyphenated | 1 | 1 | 0 / 0 |
| F1 | screen | targetForm / initial_capital | 6 | 1 | 0 / 1 |
| F1 | screen | targetForm / plain_word | 756 | 279 | 12 / 14 |
| F2 | screen | phrasePosition / first_checkpoint | 140 | 64 | 1 / 1 |
| F2 | screen | phrasePosition / later_checkpoint | 630 | 178 | 10 / 14 |
| F2 | screen | prefixEnding / after_letter_or_digit | 770 | 242 | 11 / 15 |
| F2 | screen | targetForm / apostrophe | 7 | 3 | 0 / 0 |
| F2 | screen | targetForm / hyphenated | 1 | 1 | 0 / 0 |
| F2 | screen | targetForm / initial_capital | 6 | 1 | 0 / 1 |
| F2 | screen | targetForm / plain_word | 756 | 237 | 11 / 14 |
| F3 | screen | phrasePosition / first_checkpoint | 140 | 95 | 1 / 2 |
| F3 | screen | phrasePosition / later_checkpoint | 630 | 303 | 15 / 22 |
| F3 | screen | prefixEnding / after_letter_or_digit | 770 | 398 | 16 / 24 |
| F3 | screen | targetForm / apostrophe | 7 | 5 | 0 / 1 |
| F3 | screen | targetForm / hyphenated | 1 | 1 | 0 / 0 |
| F3 | screen | targetForm / initial_capital | 6 | 1 | 0 / 0 |
| F3 | screen | targetForm / plain_word | 756 | 391 | 16 / 23 |
| F4 | screen | phrasePosition / first_checkpoint | 140 | 100 | 1 / 9 |
| F4 | screen | phrasePosition / later_checkpoint | 630 | 328 | 18 / 24 |
| F4 | screen | prefixEnding / after_letter_or_digit | 770 | 428 | 19 / 33 |
| F4 | screen | targetForm / apostrophe | 7 | 3 | 0 / 0 |
| F4 | screen | targetForm / initial_capital | 6 | 2 | 0 / 0 |
| F4 | screen | targetForm / plain_word | 756 | 423 | 19 / 33 |
| M1 | screen | phrasePosition / first_checkpoint | 140 | 68 | 1 / 1 |
| M1 | screen | phrasePosition / later_checkpoint | 630 | 188 | 9 / 16 |
| M1 | screen | prefixEnding / after_letter_or_digit | 770 | 256 | 10 / 17 |
| M1 | screen | targetForm / apostrophe | 7 | 1 | 0 / 0 |
| M1 | screen | targetForm / initial_capital | 6 | 2 | 0 / 0 |
| M1 | screen | targetForm / plain_word | 756 | 253 | 10 / 17 |
| M1 | none | phrasePosition / first_checkpoint | 140 | 96 | 1 / 1 |
| M1 | none | phrasePosition / later_checkpoint | 630 | 265 | 11 / 9 |
| M1 | none | prefixEnding / after_letter_or_digit | 770 | 361 | 12 / 10 |
| M1 | none | targetForm / apostrophe | 7 | 5 | 1 / 0 |
| M1 | none | targetForm / initial_capital | 6 | 2 | 0 / 0 |
| M1 | none | targetForm / plain_word | 756 | 354 | 11 / 10 |
| M2 | screen | phrasePosition / first_checkpoint | 140 | 82 | 2 / 3 |
| M2 | screen | phrasePosition / later_checkpoint | 630 | 242 | 15 / 8 |
| M2 | screen | prefixEnding / after_letter_or_digit | 770 | 324 | 17 / 11 |
| M2 | screen | targetForm / apostrophe | 7 | 3 | 0 / 0 |
| M2 | screen | targetForm / hyphenated | 1 | 1 | 0 / 0 |
| M2 | screen | targetForm / plain_word | 756 | 320 | 17 / 11 |
| M2 | none | phrasePosition / first_checkpoint | 140 | 121 | 1 / 2 |
| M2 | none | phrasePosition / later_checkpoint | 630 | 404 | 15 / 24 |
| M2 | none | prefixEnding / after_letter_or_digit | 770 | 525 | 16 / 26 |
| M2 | none | targetForm / apostrophe | 7 | 6 | 1 / 0 |
| M2 | none | targetForm / initial_capital | 6 | 3 | 0 / 0 |
| M2 | none | targetForm / plain_word | 756 | 516 | 15 / 26 |
| M3 | screen | phrasePosition / first_checkpoint | 140 | 93 | 0 / 12 |
| M3 | screen | phrasePosition / later_checkpoint | 630 | 293 | 12 / 24 |
| M3 | screen | prefixEnding / after_letter_or_digit | 770 | 386 | 12 / 36 |
| M3 | screen | targetForm / apostrophe | 7 | 4 | 0 / 1 |
| M3 | screen | targetForm / plain_word | 756 | 382 | 12 / 35 |
| M3 | none | phrasePosition / first_checkpoint | 140 | 130 | 0 / 8 |
| M3 | none | phrasePosition / later_checkpoint | 630 | 449 | 23 / 40 |
| M3 | none | prefixEnding / after_letter_or_digit | 770 | 579 | 23 / 48 |
| M3 | none | targetForm / apostrophe | 7 | 5 | 1 / 0 |
| M3 | none | targetForm / hyphenated | 1 | 1 | 0 / 0 |
| M3 | none | targetForm / initial_capital | 6 | 2 | 0 / 0 |
| M3 | none | targetForm / plain_word | 756 | 571 | 22 / 48 |
| M4 | screen | phrasePosition / first_checkpoint | 140 | 59 | 1 / 1 |
| M4 | screen | phrasePosition / later_checkpoint | 630 | 182 | 10 / 16 |
| M4 | screen | prefixEnding / after_letter_or_digit | 770 | 241 | 11 / 17 |
| M4 | screen | targetForm / initial_capital | 6 | 1 | 0 / 0 |
| M4 | screen | targetForm / plain_word | 756 | 240 | 11 / 17 |
| M4 | none | phrasePosition / first_checkpoint | 140 | 114 | 3 / 3 |
| M4 | none | phrasePosition / later_checkpoint | 630 | 299 | 16 / 10 |
| M4 | none | prefixEnding / after_letter_or_digit | 770 | 413 | 19 / 13 |
| M4 | none | targetForm / apostrophe | 7 | 5 | 1 / 0 |
| M4 | none | targetForm / initial_capital | 6 | 3 | 0 / 0 |
| M4 | none | targetForm / plain_word | 756 | 405 | 18 / 13 |

## Evidence-limited notes for a later round

- This is a development subset used to compare many alternatives. Category and boundary patterns are hypotheses for later experiments, not unbiased generalization estimates.
- H3’s detailed transitions distinguish a mostly inactive history-length change from offsetting gains and losses; output changes that remain incorrect do not establish improved word choice.
- Screen-format variants should leave no-screen generation unchanged. Any observed no-screen output change deserves a reproducibility/input audit before a causal explanation.
- Surface metadata enters both conditions, so metadata variants can change no-screen predictions. Their condition contrast alone cannot isolate visual-context quality.
- Raw and shown change counts match in the available runs, so these comparisons show no raw-change absorption by display processing. Many changed continuation strings retain the same recorded predicted word; total output churn should not be treated as first-word improvement.
- All observations here are word boundaries. They provide no direct evidence about partial-word typing behavior, latency in normal interactive use, or subjective acceptability of alternative continuations.
- M2 removed Format unconditionally: screen +6/770 net correct and no-screen -10/770. A prospective next-round hypothesis is to omit Format only when valid OCR is available. That conditional policy is unimplemented and untested; the unconditional result does not establish its effect, and it would require independently prepared validation data.
- M4 removed Field unconditionally: screen -6/770 net correct and no-screen +6/770. A prospective next-round hypothesis is to omit Field only when OCR is unavailable. That conditional policy is unimplemented and untested; it must not be treated as a current-round candidate or selected using protected outcomes from this round.

This artifact does not change the registered selection, propose additional current-round candidates, or use protected validation results.
