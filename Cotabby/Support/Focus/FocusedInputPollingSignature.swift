import CoreGraphics
import Foundation

/// Stable-enough identity for one focused input as observed by polling.
///
/// Text, selection, and caret position are deliberately excluded. Those can change inside the same
/// field and should not restart the visual-context session. The input frame is preferred over the
/// AX element id because AX identifiers are derived from Core Foundation object identity, which can
/// be recycled by macOS. Fresh surface facts distinguish tabs/conversations that reuse the same
/// composer geometry. This pure value is owned by FocusTracker for one poll comparison; it excludes
/// text and selection so ordinary typing does not become a navigation event.
nonisolated struct FocusedInputPollingSignature: Equatable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    let role: String
    let subrole: String?
    private let fieldAnchor: FieldAnchor
    let windowTitle: String?
    let focusedURLString: String?
    /// The placeholder this poll read. Hosts hide it while the field has text, which reads as nil and
    /// so as unreadable (see `continuesField(of:)`); the signature FocusTracker remembers carries the
    /// last shown value forward, so a field cleared later back to the same placeholder still continues.
    let fieldPlaceholder: String?

    init(context: FocusedInputSnapshot) {
        bundleIdentifier = context.bundleIdentifier
        processIdentifier = context.processIdentifier
        role = context.role
        subrole = context.subrole
        // Same rule as the session identity: in a browser the title is a volatile display string.
        windowTitle = FocusedInputSessionIdentity.identifyingWindowTitle(
            context.windowTitle, focusedURLString: context.focusedURLString,
            bundleIdentifier: context.bundleIdentifier
        )
        focusedURLString = context.focusedURLString
        // A host may answer `AXPlaceholderValue` with "" instead of dropping the attribute once text
        // hides it. An empty placeholder is no placeholder (the prompt side reads it the same way);
        // kept as "", it would differ from the one this session showed and look like navigation.
        fieldPlaceholder = context.fieldPlaceholder.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        fieldAnchor = FieldAnchor(
            inputFrame: context.inputFrameRect,
            fallbackElementIdentifier: context.elementIdentifier
        )
    }

    private init(
        bundleIdentifier: String,
        processIdentifier: Int32,
        role: String,
        subrole: String?,
        fieldAnchor: FieldAnchor,
        windowTitle: String?,
        focusedURLString: String?,
        fieldPlaceholder: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.role = role
        self.subrole = subrole
        self.fieldAnchor = fieldAnchor
        self.windowTitle = windowTitle
        self.focusedURLString = focusedURLString
        self.fieldPlaceholder = fieldPlaceholder
    }

    /// True when this poll still observes the field `previous` described. Every identity fact must
    /// match, but the frame may resize in place: a chat composer grows when a line wraps, keeping
    /// its left edge, width, and either its top or bottom edge. Treating that as navigation would
    /// start a new writing session and discard the visible suggestion on every wrap. Two distinct
    /// fields stacked at the same x and width still differ at both edges.
    ///
    /// The surface facts (title, URL, placeholder) are compared with the same rule the session
    /// identity uses: a fact that read as nil this poll is unreadable, not different. Each is a
    /// bounded AX read under a 50 ms timeout, and a host busy with a burst of synthetic keystrokes
    /// drops one now and then. Treating that as navigation advanced the focus sequence and retired
    /// the active suggestion in the middle of rapid Tab accepts.
    ///
    /// The placeholder needs this rule more than the others, because a host changes it in response
    /// to the text itself: it is shown only while the field is empty. Chromium composers (the Claude
    /// desktop composer reports "Type / for commands.") drop `AXPlaceholderValue` a poll or two after
    /// the first typed character and restore it when the field is cleared. Another conversation that
    /// reuses the composer with a different placeholder still breaks continuity.
    func continuesField(of previous: FocusedInputPollingSignature) -> Bool {
        guard bundleIdentifier == previous.bundleIdentifier, processIdentifier == previous.processIdentifier,
              role == previous.role, subrole == previous.subrole,
              FocusedInputSessionIdentity.surfaceFactsAgree(windowTitle, previous.windowTitle),
              FocusedInputSessionIdentity.surfaceFactsAgree(focusedURLString, previous.focusedURLString),
              FocusedInputSessionIdentity.surfaceFactsAgree(fieldPlaceholder, previous.fieldPlaceholder)
        else { return false }
        return fieldAnchor.continues(previous.fieldAnchor)
    }

    /// Names of the identity facts that broke continuity with `previous`, for logging why a poll
    /// opened a new focus session. Names only: titles, URLs, and placeholders can identify what the
    /// user is doing. Uses the same unreadable-agrees rule as `continuesField(of:)`.
    func changedFacts(since previous: FocusedInputPollingSignature) -> [String] {
        var facts: [String] = []
        if bundleIdentifier != previous.bundleIdentifier || processIdentifier != previous.processIdentifier {
            facts.append("app")
        }
        if role != previous.role || subrole != previous.subrole { facts.append("role") }
        if !FocusedInputSessionIdentity.surfaceFactsAgree(windowTitle, previous.windowTitle) { facts.append("title") }
        if !FocusedInputSessionIdentity.surfaceFactsAgree(focusedURLString, previous.focusedURLString) {
            facts.append("url")
        }
        if !FocusedInputSessionIdentity.surfaceFactsAgree(fieldPlaceholder, previous.fieldPlaceholder) {
            facts.append("placeholder")
        }
        if !fieldAnchor.continues(previous.fieldAnchor) { facts.append("frame") }
        return facts
    }

    /// This poll's signature with any surface fact it failed to read filled in from `previous`.
    ///
    /// The tracker stores this, not the raw poll, as the field's latest signature. Otherwise a
    /// navigation that straddles one unreadable poll would go unnoticed: title A, then nil (which
    /// continues A), then title B (which would continue nil). Carrying A forward makes the B poll
    /// compare against A and read as the navigation it is. The frame is always this poll's own, so
    /// in-place growth keeps being measured from the current edges.
    func carryingKnownSurfaceFacts(from previous: FocusedInputPollingSignature?) -> FocusedInputPollingSignature {
        guard let previous else { return self }
        return FocusedInputPollingSignature(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier,
            role: role,
            subrole: subrole,
            fieldAnchor: fieldAnchor,
            windowTitle: windowTitle ?? previous.windowTitle,
            focusedURLString: focusedURLString ?? previous.focusedURLString,
            fieldPlaceholder: fieldPlaceholder ?? previous.fieldPlaceholder
        )
    }
}

private extension FocusedInputPollingSignature {
    nonisolated struct FieldAnchor: Equatable {
        let roundedInputFrame: RoundedRect?
        let fallbackElementIdentifier: String?

        init(inputFrame: CGRect?, fallbackElementIdentifier: String) {
            roundedInputFrame = inputFrame.map { RoundedRect(rect: $0) }
            self.fallbackElementIdentifier = roundedInputFrame == nil ? fallbackElementIdentifier : nil
        }

        func continues(_ previous: FieldAnchor) -> Bool {
            guard let frame = roundedInputFrame, let previousFrame = previous.roundedInputFrame else {
                return self == previous
            }
            return frame.minX == previousFrame.minX && frame.width == previousFrame.width
                && (frame.minY == previousFrame.minY || frame.maxY == previousFrame.maxY)
        }
    }

    nonisolated struct RoundedRect: Equatable {
        let minX: Int
        let minY: Int
        let width: Int
        let height: Int

        init(rect: CGRect) {
            minX = Int(rect.minX.rounded())
            minY = Int(rect.minY.rounded())
            width = Int(rect.width.rounded())
            height = Int(rect.height.rounded())
        }

        var maxY: Int { minY + height }
    }
}
