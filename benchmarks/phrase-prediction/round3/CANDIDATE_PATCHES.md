# Candidate patch record

The three screening candidates changed only the registered surface-format rendering boundary.
They did not change `SurfaceContext`, request construction, model settings, sampling, output
normalization, insertion, OCR, or native runtime behavior.

- **A:** `BaseCompletionPromptRenderer` detected retained non-whitespace screen text and asked
  `SurfaceContextComposer` to omit only the generic `Format:` field. No-screen prompt bytes stayed
  at baseline.
- **B:** The renderer omitted only `Field:` when no retained screen text existed. Screen prompt
  bytes stayed at baseline.
- **AB:** The renderer applied both conditional omissions. `App`, `Title`, browser `Domain`, and
  the exact caret prefix remained available.

The AB source patch was deliberately removed after the full seed-42 rejection. The benchmark
reports are the authoritative evidence for each candidate.
