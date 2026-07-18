# Focus and Accessibility

## Purpose

Cotabby must understand text and caret geometry inside applications it does not own. macOS
Accessibility is the only cross-application semantic interface available for that job, but its data
is synchronous, cross-process, app-specific, and eventually consistent. This subsystem converts raw
AX state into a bounded, capability-checked FocusSnapshot that the rest of Cotabby can consume.

## Main Pipeline

Read these files in order:

1. [FocusTracker.swift](../../Cotabby/Services/Focus/FocusTracker.swift)
2. [FocusSnapshotResolver.swift](../../Cotabby/Services/Focus/FocusSnapshotResolver.swift)
3. [FocusModels.swift](../../Cotabby/Models/Focus/FocusModels.swift)
4. [AXTextGeometryResolver.swift](../../Cotabby/Services/Focus/AXTextGeometryResolver.swift)
5. [AXHelper.swift](../../Cotabby/Support/Accessibility/AXHelper.swift)

The high-level flow is:

~~~text
frontmost or owning application
  -> focused AX element
  -> candidate editable elements
  -> capability and secure-field checks
  -> bounded text and selection
  -> caret and field geometry
  -> stable focus identity and generation
  -> FocusSnapshot publication
~~~

## Why Polling Is Authoritative

FocusTracker uses polling as its single source of truth. AXObserver notifications are inconsistent
across native, browser, Electron, and custom editors. Mixing notification and poll streams would
also create ordering ambiguity. Polling provides one eventual-consistency rule: every capture
re-reads the current field, and stale state repairs on a later capture.

Input and acceptance paths can request refreshNow when they know a fresh read is useful. Those are
still polling-style full captures, not trusted event payloads. FocusTrackingModel exposes the age of
the most recent capture so multiple pipeline stages can avoid paying for identical AX work within a
short freshness window.

## Adaptive Polling

Active editing uses the configured base cadence. When repeated captures produce no focus or content
change, FocusPollBackoff stretches the timer interval. Explicit activity resets the backoff. This
keeps editing responsive while avoiding continuous main-thread wakeups and deep AX walks on an idle
machine.

The timer is re-created only when the effective interval changes. That prevents no-op timer churn on
every keypress.

## Resolving the Owning Application

The app that owns the focused AX element is more reliable than NSWorkspace.frontmostApplication.
Accessory utilities such as launchers can own a focused non-activating panel while another
application remains nominally frontmost. Per-app disable policy and surface classification must use
the actual focused process when possible.

Chromium out-of-process frames complicate ownership because a focused AX node can belong to a
renderer subprocess. The Chromium fallback deliberately associates a hit-tested element with the
visible browser application.

## Chromium and Electron

Chromium and Electron surfaces require extra compatibility work:

- ChromiumAccessibilityEnabler primes web accessibility so renderer text becomes visible.
- A cursor hit-test fallback can recover focused editors that the system-wide focused-element query
  misses, including some out-of-process iframe editors.
- The hit-tested element is cached only while it still reports focus and the browser identity
  remains valid.
- Browser detection and web-content classification affect candidate choice and geometry policy.
- Debug builds can write a focused Chrome AX tree snapshot for inspection.

These fallbacks must never mask a real focus change. Every cached element is revalidated, and normal
system focus wins immediately when it becomes available.

## Candidate Resolution and Capability

FocusSnapshotResolver searches around the focused element for the most usable editable candidate.
It reduces AX implementation details into domain values:

- Application and process identity
- Element identity and focus-change sequence
- Preceding and trailing text around the selection
- Selection location and length
- Field and caret rectangles
- Geometry quality
- Window, URL, placeholder, and surface metadata
- Capability and block reason

FocusCapabilityResolver and related pure policies decide whether the result is supported. Secure
fields, unsupported roles, read-only surfaces, incompatible selections, terminals under default
policy, and explicitly disabled applications must fail safely at the assistance boundary.

FocusSnapshot intentionally carries only application identity, capability, and optional bounded
context. The obsolete detailed inspection snapshot was removed; developer visibility now travels
through the lightweight FocusPollingEvent plus caret/field geometry and visual-context status. This
keeps normal focus values smaller without removing the debug overlay's polling evidence.

There is a current acquisition caveat: the resolver constructs a bounded FocusedInputSnapshot before
returning blocked capability for a secure field, and the separate visual-capture gate ignores
capability. Suggestions and insertion remain blocked, but "blocked" does not currently mean that no
AX value or screenshot was acquired. Treat the context/privacy guide as authoritative for that
distinction.

Cotabby normally blocks its own process. The Context settings pane has one sanctioned live-preview
field identified by a known AX identifier; every other Cotabby field remains excluded.

## Bounded Text

Focus snapshots do not carry entire documents. Text on each side of the caret is capped before it
flows through equality checks, Combine publication, stale-result signatures, or prompt construction.
The prompt factory applies a smaller engine-specific window later.

Bounding at the AX boundary matters because a large editor can otherwise make every focus capture,
comparison, and request signature scale with document size.

## Focus Identity

No single AX identifier is perfectly stable. Chromium can recycle or replace AX nodes during normal
editing. Cotabby combines:

- Process identity
- Element identity where useful
- A monotonic focusChangeSequence
- Selection and text signatures
- Generation/content signatures

Different consumers use the narrowest identity appropriate to their invariant. Visual context needs
field-scoped uniqueness, while active-session reconciliation intentionally favors process and text
continuity over brittle AX node identity.

## Geometry Resolution

AXTextGeometryResolver chooses the best caret geometry available:

1. Zero-length AXBoundsForRange at the caret
2. AX text-marker range geometry used by some browser engines
3. Bounds of the character before the caret, shifted to its trailing edge
4. Child static-text-run frames with proportional placement
5. Field-frame estimation as a last resort

The result carries a CaretGeometryQuality:

- exact: direct caret/range geometry
- derived: geometry inferred from a nearby measured character
- estimated: coarse field-based fallback
- layoutEstimated: repaired later using hidden TextKit layout

Quality is part of presentation policy. Exact and derived geometry can support inline ghost text.
Estimated or layout-repaired positions normally use a Cotabby-owned mirror card because small
horizontal errors are visually obvious when glyphs are painted directly beside host text.

## Geometry Cost Controls

AX calls are synchronous IPC and can block the MainActor while the target process responds.
Compatibility walks therefore use several controls:

- Gate parameterized attributes on advertised support.
- Validate returned rectangles against an anchor frame.
- Throttle deep descendant searches.
- Throttle static-text-run walks.
- Cache field style and surface metadata within a focus session.
- Invalidate transient caret caches after Cotabby mutates the field.
- Reuse a recent suggestion anchor when AX frames briefly regress after insertion.

These optimizations are correctness-sensitive. A cache key must include the identity or generation
needed to prevent data from one field leaking into another.

## App-Specific Safety

Some applications react badly to AX enumeration. Calendar can dismiss a transient date/time editor
when its tree is walked. CalendarAccessibilityCaptureGuard uses pointer context to suppress only the
fragile interaction window instead of disabling the whole application.

Per-app disable and global pause are checked before expensive candidate walks. This is both a
performance optimization and a compatibility guarantee: disabled Cotabby should not perturb the
target application's AX tree.

## Coordinate Systems

Accessibility, AppKit, Core Graphics, and Vision can describe screen rectangles using different
origins and coordinate conventions. AXHelper and DisplayCoordinateConverter centralize conversion.
Callers should not hand-roll Y-axis flips or mix AX and Cocoa rectangles without an explicit
conversion boundary.

Every rectangle that reaches AppKit presentation is checked for finite components. A malformed AX
frame should suppress presentation, not crash NSPanel layout.

## Concurrency and Freshness

Most AX access is MainActor-isolated. This makes mutation of focus caches and publication ordered,
but it also means expensive synchronous AX calls can affect input responsiveness. The subsystem
therefore emphasizes bounding, throttling, freshness checks, and avoiding duplicate captures.

Async consumers must assume the snapshot can become stale immediately after they read it. They carry
focus and content signatures through awaits and validate again before applying work.

## Invariants

- Polling is the authoritative focus source.
- Cached Chromium fallbacks never outrank a valid system-focused element.
- Secure and unsupported fields fail closed for prediction, presentation, and insertion; early
  secure-field acquisition remains a documented privacy limitation.
- Captured text is bounded before publication.
- Deep AX work stops when Cotabby is disabled or interaction safety requires it.
- Geometry always carries a quality classification.
- AX rectangles are converted and validated at explicit boundaries.
- Async results never rely on AX element identity alone.
- Cotabby's own fields remain blocked except for the explicit live-preview field.

## Failure-Oriented Reading

- Field is not detected: FocusTracker focus acquisition, Chromium priming/hit test, candidate search.
- Wrong app gets per-app policy: owning-application resolution.
- Secure or read-only field is treated as editable: capability resolver and secure-field detection.
- Ghost appears at field edge: geometry fallback and quality classification.
- Ghost jitters after typing or acceptance: geometry caches, anchor stability, post-insertion
  invalidation.
- Idle app consumes CPU: FocusPollBackoff and deep-walk throttles.
- Calendar popover closes: CalendarAccessibilityCaptureGuard and suppression boundary.
- Browser works until iframe focus: Chromium OOPIF hit-test cache and revalidation.

## Update This Guide When

Update this document when focus acquisition gains a new source, identity semantics change, a new
geometry branch or quality is added, AX context bounds change architecturally, or an app-specific
compatibility guard changes what Cotabby is allowed to inspect.
