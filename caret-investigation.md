# Caret Placement — New Finding & Revised Hypothesis

Companion to `~/Desktop/cotabby-caret-investigation.txt`. This doc captures what
the AX Inspector screenshots changed about the working theory and what the next
code change should be.

---

## New data (from AX Inspector on Gmail compose, Chrome)

A specific descendant of the focused AXTextArea is an **AXStaticText leaf** with
all the geometry primitives Tabby needs:

| Attribute                  | Value                                                         |
| -------------------------- | ------------------------------------------------------------- |
| Role                       | `AXStaticText`                                                |
| Value                      | `"if you can help me with my project? i am a student and i am working on hows , text"` |
| Frame                      | `x=1250, y=724, w=687, h=44` — **single line**                |
| Children                   | `[]` (leaf)                                                   |
| `AXSelectedTextRange`      | `location=77, length=0`  ← caret position lives on the leaf  |
| `AXSelectedTextMarkerRange`| present (`<AXTextMarkerRange ...>`)                           |
| `Start Text Marker`        | present                                                       |
| `End Text Marker`          | present                                                       |
| Parent                     | `<empty description> (group) [BrowserAccessibilityCocoa]`     |

The leaf:

- has its own selection range, with a non-zero location
- has its own `AXSelectedTextMarkerRange` (Branch 1.5 should work on it)
- is single-line — its frame is the line, not a multi-line container

This is exactly the element shape that yields a correct caret rect.

---

## What the previous hypothesis got wrong

The investigation `.txt` ranked H1 (ancestor `AXWebArea` TextMarker walk) as the
strongest hypothesis. That was wrong about direction. The geometry source isn't
*above* the focused AXTextArea — it's *below*, at the per-line AXStaticText
leaf. Cotypist's "doesn't use a child node" Inspector signal was misleading:
the leaf isn't a *visual* child of what the user thinks of as the input, but it
IS an AX descendant of the AXTextArea.

The original Branch 1.5 (`AXSelectedTextMarkerRange` →
`AXBoundsForTextMarkerRange`) is the right query. It just needs to be aimed at
the leaf, not the AXTextArea.

---

## Why Tabby doesn't reach the leaf today

`findDeepGeometrySource` in `FocusSnapshotResolver.swift:281-339` already does
exactly this — BFS into descendants, find any node with `selection.length == 0`,
call `resolveCaretRect` on it. On the leaf, Branch 1.5 (TextMarker) will yield
`.exact`.

But `resolveSnapshot:121-148` short-circuits the deep walk:

```swift
if let primary = resolvedCandidate.caretRect,
    resolvedCandidate.caretQuality == .exact || resolvedCandidate.caretQuality == .derived {
    caretRect = primary                    // ← exits here
} else if let deepResult = resolveDeepGeometrySource(...) {
    caretRect = deepResult.rect            // ← never reached
}
```

In Chrome:

1. Primary candidate (`AXTextArea`) runs through `resolveCaretRect`:
   - Branch 1 (zero-length `BoundsForRange`) → nil.
   - Branch 1.5 (TextMarker on the AXTextArea itself) → nil.
   - Branch 2 (`BoundsForRange(loc-1, 1)`) → returns the **multi-line union
     rect** (height 117pt vs line height 44pt, x=1960 = right edge).
   - Returns `.derived` quality with that garbage rect.
2. `.derived` matches the if-condition above → primary wins → deep walk is
   skipped → the leaf is never queried.

The `.derived` label is a lie. The rect it accompanies is multi-line union
junk. The current quality model has no way to express "I got a result but it's
suspicious," so it leaks through.

---

## Proposed fix (smallest viable change)

Change the precedence in `resolveSnapshot` so that `deep .exact` beats
`primary .derived`:

| Priority | Source         | Quality      |
| -------- | -------------- | ------------ |
| 1        | primary        | `.exact`     |
| 2        | **deep**       | **`.exact`** |
| 3        | primary        | `.derived`   |
| 4        | deep           | `.derived`   |
| 5        | primary        | `.estimated` |
| 6        | deep           | `.estimated` |

Cost: when `primary.caretQuality == .derived`, the BFS now runs. The walk
shortcuts cheaply on most nodes (one AX read for `kAXSelectedTextRangeAttribute`;
nodes without it are skipped immediately). Worst case is 200 nodes ≈ similar
cost to a single Branch 1 candidate-snapshot pass.

Native AppKit apps where Branch 1 succeeds (`.exact` primary) are unaffected —
the deep walk is still skipped for them.

The earlier anchor-halo validation (`rectIsNearAnchor`) stays in place. It
doesn't catch the multi-line-union case but is a free safety net against true
off-screen garbage.

---

## Known risk to watch in the dump

Chrome's AX tree under the AXTextArea has **multiple AXStaticText siblings**,
each with its own `AXSelectedTextRange`:

- The active leaf: `location > 0` (e.g., `77`)
- Inactive leaves: `location == 0, length == 0` (default state)

All of them pass the deep walk's `range.length == 0` filter. The current
`shouldPreferDeepResult` ranks by depth-then-quality; if multiple leaves tie on
depth and quality, the first-found wins. BFS order may or may not visit the
active leaf first.

If the dump shows `Final caretSource = "exact deep"` but the caret is on the
wrong line, the next refinement is:

> Among deep candidates with `length == 0`, prefer the one whose
> `selection.location > 0` (or whose TextMarker bounds don't sit at the leaf's
> leading edge — i.e., the caret isn't at the start of an inactive leaf).

I'm not adding that heuristic until the dump confirms it's needed.

---

## Diagnostic expectations after the fix

| Before fix                                | After fix (best case)                     |
| ----------------------------------------- | ----------------------------------------- |
| `Final caretSource: derived primary`      | `Final caretSource: exact deep`           |
| `Final caretRect: ..., 2×117` (tall strip)| `Final caretRect: ..., 2×44` (one line)   |

If the log shows `exact deep` but caret still wrong, that's the multi-leaf
disambiguation risk above — actionable, not square-one.

If the log still shows `derived primary`, the precedence change didn't take
effect (build problem) or the deep walk isn't finding the leaf (BFS bounds or
selection-range filter issue).
