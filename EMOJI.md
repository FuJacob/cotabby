# Porting Guide: Global Keystroke Interception & Inline Insertion on macOS

---

## 0. Mental Model — What You're Building

You are building a daemon-style menu-bar app that:

1. Silently watches **every keystroke globally** while the user types in other applications.
2. Runs the stream of keystrokes through a **trigger state machine** that decides when an autocomplete query has started, when it's still in flight, and when it has ended (commit, cancel, terminator).
3. Pops a **non-activating floating panel** anchored near the user's text caret in the foreground app, without stealing focus.
4. When the user commits a suggestion, **deletes the original typed query and inserts the completion** into the foreground app via synthetic keyboard events.

These three are individually well-documented but interact in subtle, timing-sensitive ways. Most of this guide is about those interactions.

---

### 1.1 What it is

- The tap callback is a C function pointer; it cannot capture Swift context, so you pass `self` via the userInfo pointer using `Unmanaged`.
- The callback **fires on the main thread** because of where you installed the runloop source. This is intentional and you must preserve it.
- Assert main-queue at tap start with `dispatchPrecondition`. Future-you will thank you.

### 1.3 What to filter at the tap layer
Inside the callback you have a raw `CGEvent`. Translate it into a small enum (`TriggerInput`) the state machine consumes. The filter should:

- Pass through most modifier combinations untouched (Cmd+C, Cmd+V, Ctrl+anything, Alt+anything) — these are user shortcuts, not text input.
- Reserve a couple of special modifier combinations if you need them (e.g. Cmd+Z for "undo my last autocomplete").
- Translate arrow keys, Return, Tab, Escape, Backspace into named state-machine inputs.
- Identify your **trigger character(s)** — for example, you might use `:`; for AI autocomplete you might choose Tab after a pause, a leading sigil like `//`, or a key chord.
- Classify letters/digits/underscores as "name characters" that extend the query, and everything else as "cancel characters" that may terminate it.
- Reject keystrokes generated *by your own app* — see §1.5.

### 1.4 Permissions
You need **two** separate TCC grants:

- **Input Monitoring** — required to install and keep the event tap alive. Without it, tap creation either fails or the OS disables the tap shortly after.
- **Accessibility** — required to read focused element / caret position via AX, and to *post* synthetic events without restriction.

These prompt independently. Build a `PermissionsCoordinator` singleton that:

- Polls `AXIsProcessTrusted()` and `IOHIDCheckAccess(.listenEvent)` on a short timer (~2s).
- Subscribes to the distributed notification `com.apple.accessibility.api` for instant updates when AX is toggled.
- Refreshes on `NSApplication.didBecomeActiveNotification` (trust state can lag a live toggle).
- Exposes deep-link URLs into the right System Settings pane (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` and `…?Privacy_ListenEvent`).
- Triggers the system prompt via `AXIsProcessTrustedWithOptions` and `IOHIDRequestAccess`.

### 1.5 Synthetic-event marker — critical

Pick a 64-bit constant. Anything distinctive works; an ASCII string packed into bytes is convenient for grep-ability.

## 2. Trigger State Machine

### 2.1 Shape
A pure-logic enum-driven state machine, with no dependencies on AX, CGEvent, NSPanel, or any UI. Typical states:
- `.capturing(query: String)` — a query is in progress; arrow keys navigate the picker, name chars extend the query, backspace shortens it, terminators commit/cancel.

### 2.2 Transition rules
- **Committing**: Return/Tab/closing-trigger fire the commit path.
- **Cancelling**: Escape, focus change, click in another window, a long pause, or any unexpected modifier combination.
- **Self-canceling on long pause**: if the user starts typing a query and then walks away for >1 second, fall back to idle gracefully — don't pop a panel after a long delay.

### 2.3 Output
The state machine emits two pieces of information per input:

1. A **`TriggerAction`** (or `nil`) — e.g. `.openPicker`, `.updateQuery(q)`, `.commit(mode:)`, `.cancel`.
2. A **`consumesKey: Bool`** — does the focused app see this keystroke or not?

The `consumesKey` decision is what the event-tap callback uses to choose its return value. Keep it deterministic and synchronous.

---

## 3. The Two Commit Modes

This is where the design is subtle and worth understanding deeply, because it generalizes directly to AI autocomplete.

### 3.1 Mode A — committed by a *consumed* key (e.g. Tab/Return)

### 3.2 Mode B — committed by a *passed-through* key (e.g. closing colon, period)

### 3.3 The general principle

### 3.4 Cancel-without-replacement
If the commit path can't actually find a completion (e.g. AI returned nothing), don't delete anything — leave the user's typed text intact. Surprise deletion of user input is the worst possible failure mode.

## 4. Synthetic Text Insertion (TextInserter)

### 4.1 Deletion
Post `keyDown` + `keyUp` pairs for virtual keycode 0x33 (Delete/Backspace), N times. Post to `.cghidEventTap` (HID level), not the session tap.

### 4.2 Insertion

### 4.3 Mark every event
Stamp every synthetic event you post with the magic number in `.eventSourceUserData` (see §1.5).

### 4.4 Pacing — the silent killer

The simplest safe pattern: insert in a single shot after a brief `asyncAfter` delay if the trigger was passed-through, immediately otherwise.

### 4.5 Counting characters — use grapheme clusters

### 4.6 What can go wrong across apps
- IME (input method) composition state mid-query can swallow your deletes. Don't trigger when an IME is composing.
- Secure text fields (passwords) — refuse to operate, see §5.4.

---

## 5. Reading the Focused Element & Caret (Accessibility API)

### 5.1 Why caching matters

Build a `FocusedElementCache` singleton:

- Subscribes to `kAXFocusedUIElementChangedNotification` via an `AXObserver` on the frontmost app.
- Maintains a cached `AXUIElement` reference, updated only when the notification fires.
- Updates the observed app whenever `NSWorkspace.shared.notificationCenter` posts `didActivateApplicationNotification`.
- Add the observer's runloop source to the main runloop in `.commonModes`.
- Falls back to a fresh fetch if the cache is empty.

### 5.2 Caret location
Two strategies in priority order:

### 5.3 Coordinate conversion
AX returns rects in **top-left origin** screen coordinates. AppKit / NSWindow positioning uses **bottom-left origin**. Flip Y around the primary screen height:
`flippedY = NSScreen.main.frame.height - rect.origin.y - rect.height`.

### 5.4 Secure-field detection

### 5.5 The one-runloop-tick rule

Always defer the "show the picker, anchor at caret" call by one `DispatchQueue.main.async` tick. Yes, this is the same trick as commit mode B (§3.2) — it's the same underlying ordering issue.

### 5.6 Comparing AX elements
Two `AXUIElement` references to the same UI element are **not** equal via Swift `==`. Use `CFEqual`. This bites when comparing cached elements to freshly-fetched ones.

---

## 6. The Picker (Non-Activating Floating Panel)

### 6.1 Window type
Use `NSPanel`, not `NSWindow`. Style mask: `.borderless`, `.nonactivatingPanel`, `.fullSizeContentView`. Additional config:

- `isFloatingPanel = true`
- `level = .floating` (or `.statusBar`-equivalent for above-everything)
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]` — appears on all spaces, works alongside fullscreen apps, doesn't show in Mission Control
- `hidesOnDeactivate = false`
- `becomesKeyOnlyIfNeeded = true`

### 6.2 Host SwiftUI inside

### 6.3 Keyboard navigation while another app is focused

### 6.4 Click-away dismissal
Install two `NSEvent` monitors when the panel shows:

- `addLocalMonitorForEvents` for clicks inside your own app.
- `addGlobalMonitorForEvents` for clicks in any other app.

Tear both down when the panel hides. On any click outside the panel's frame, cancel the current capture.

### 6.5 Positioning
Compute panel origin from the caret rect (or focused-element rect, or mouse position, in priority order). Clamp to the visible screen — if the caret is near the bottom of the screen, flip the panel above the caret
instead of below. If the user has multiple screens, anchor to the screen containing the focused element, not always the primary.

---

## 7. App / Site Exclusions

Users will want autocomplete disabled in certain apps (password managers, sensitive work apps) and on certain URLs (banking sites).

### 7.1 Frontmost app detection
`NSWorkspace.shared.frontmostApplication?.bundleIdentifier`. Cheap and reliable.

### 7.2 Frontmost URL detection (browsers only)
Walk the AX hierarchy of the active browser to find the address bar / web area and read its URL attribute. Different browsers expose this differently:

- Safari: `AXWebArea` element has an `AXURL` attribute.
- Chromium-based (Chrome, Edge, Brave, Arc, Vivaldi, Opera): walk to the address bar text field by role + title/description containing "address" / "url" / "location".
- Firefox: similar address-bar walk; slightly different role/title strings.

This is brittle — browser AX trees change between versions. Treat URL detection as best-effort; never crash on a missing element.

### 7.3 Pattern matching
Support literal bundle IDs and wildcard URL patterns (`*.example.com` matches one DNS segment). Compile patterns to `NSRegularExpression` once on settings load; cache.

### 7.4 Snapshot at capture start
At the moment capture begins (first trigger char typed), snapshot the exclusion verdict and cache it for the lifetime of that capture. Don't re-evaluate per keystroke — if the user alt-tabs mid-capture, the state machine cancels capture anyway, so the snapshot stays authoritative.

---
