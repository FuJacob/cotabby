# Cotabby Internal Documentation

This directory holds detailed maintainer and onboarding notes that are intentionally more exhaustive
than the repository's root architecture map. Start with [ARCHITECTURE.md](../ARCHITECTURE.md) for the
ten-minute system tour, then use the guides below to follow one responsibility through its owners,
data flow, invariants, and failure modes.

The .internal directory is committed maintainer documentation. It may discuss implementation debt and
interview preparation more candidly and deeply than public product documentation, but it must not
contain credentials, private user data, or claims that cannot be verified from the repository. The
root architecture map remains self-contained and does not require these guides to be useful.

## Architecture Guides

| Guide | Question it answers |
| --- | --- |
| [Lifecycle and Composition](architecture/lifecycle-and-composition.md) | Who constructs, starts, retains, and stops app-lifetime objects? |
| [Suggestion Pipeline](architecture/suggestion-pipeline.md) | How does one input event become a streamed, visible, and accepted suggestion? |
| [Focus and Accessibility](architecture/focus-and-accessibility.md) | How does Cotabby resolve a safe field, bounded text, identity, and caret geometry? |
| [Input and Insertion](architecture/input-and-insertion.md) | Which global events are observed or consumed, and how is text committed safely? |
| [Inference and Prompting](architecture/inference-and-prompting.md) | How do Apple, llama, and endpoint requests differ while sharing one output contract? |
| [Context, Privacy, and Permissions](architecture/context-privacy-and-permissions.md) | What data can be acquired, where is it bounded, and when can it leave the Mac? |
| [Presentation and Sibling Features](architecture/presentation-and-sibling-features.md) | How do overlays, emoji, macros, settings, and onboarding share presentation infrastructure? |

## Interview Preparation

The interview-prep layer reuses the architecture guides rather than restating them:

| Guide | Purpose |
| --- | --- |
| [Untimed Study Path](interview-prep/README.md) | Master the repository through exact source files, symbols, active-recall checkpoints, and six complete execution traces. |
| [Technical Decision Question Bank](interview-prep/technical-question-bank.md) | Practice difficult architecture questions with strong answers, tradeoffs, source trails, and honest limitations. |
| [HyperWrite Reliability Translation](interview-prep/hyperwrite-reliability-translation.md) | Apply Cotabby's lessons to inspecting, scoping, and hardening the HyperWrite Mac prototype into a measurable alpha. |

## Suggested Reading Routes

For the product loop and interview-level architecture discussion:

1. Root ARCHITECTURE.md
2. Lifecycle and Composition
3. Suggestion Pipeline
4. Inference and Prompting
5. Context, Privacy, and Permissions

For a field compatibility or ghost-positioning problem:

1. Focus and Accessibility
2. Presentation and Sibling Features
3. Suggestion Pipeline

For acceptance, IME, clipboard, or lost-keystroke behavior:

1. Input and Insertion
2. Suggestion Pipeline
3. Focus and Accessibility

For a new generation backend or context source:

1. Inference and Prompting
2. Context, Privacy, and Permissions
3. Suggestion Pipeline
4. Lifecycle and Composition

For the HyperWrite technical session:

1. Untimed Study Path
2. Technical Decision Question Bank
3. HyperWrite Reliability Translation

## Accuracy Standard

These documents describe the current code, including uncomfortable limitations. They do not turn a
planned feature, stale comment, or desired privacy property into a shipping claim.

When architecture changes:

1. Verify behavior from the concrete owners and tests, not only comments or older docs.
2. Update the detailed guide whose responsibility changed.
3. Update root ARCHITECTURE.md only when the ten-minute mental model or a major invariant changes.
4. Keep source links resolvable and name the actual owner rather than only a folder.
5. Record a current limitation explicitly when implementation and desired invariant differ.

The most important known example is secure-field acquisition: current generation and insertion fail
closed, but early bounded AX context and optional visual capture can still occur. The privacy guide
documents the exact boundary; do not simplify it to a no-capture guarantee until the code changes.
