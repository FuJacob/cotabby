import CoreGraphics
import Foundation

/// Shells supported by Cotabby's cooperative prompt integration.
nonisolated enum ShellType: String, Codable, Equatable, Sendable {
    case zsh
    case bash
    case fish
}

/// Accessibility-role values reserved for authoritative non-AX terminal input sources.
///
/// These strings deliberately cannot collide with native roles such as `AXTextArea`. Keeping the
/// discriminator in one value type prevents coordinator, prompt, and insertion code from growing
/// parallel string-literal checks.
nonisolated enum TerminalInputRole: String, Equatable, Sendable {
    case shell = "AXCotabbyTerminalShell"
    case claudeCodeTUI = "AXCotabbyClaudeCodeTUI"

    init?(accessibilityRole: String) {
        self.init(rawValue: accessibilityRole)
    }

    static func isTerminalRole(_ role: String) -> Bool {
        Self(accessibilityRole: role) != nil
    }
}

/// Stable identity for one sourced shell session.
///
/// PID alone is insufficient because macOS reuses process identifiers. The hook creates a short
/// random nonce once when sourced, so a restarted shell cannot inherit another session's buffered
/// suggestion even if the operating system later gives it the same PID.
nonisolated struct TerminalSessionIdentity: Codable, Equatable, Hashable, Sendable {
    let shellPid: Int32
    let nonce: String

    var elementIdentifier: String {
        "terminal-shell-\(shellPid)-\(nonce)"
    }
}

/// One newline-delimited JSON frame sent by a shell hook.
nonisolated struct TerminalIpcMessage: Codable, Equatable, Sendable {
    enum MessageType: String, Codable, Sendable {
        case buffer
        case disconnect
    }

    let type: MessageType
    let text: String?
    /// Raw shell cursor unit: UTF-8 bytes for bash, characters for zsh/fish.
    let cursor: Int?
    let shell: ShellType?
    let terminal: String?
    let pid: Int32?
    let session: String?
    let tty: String?
    let cwd: String?
    let revision: UInt64?
}

/// Authoritative editable state for one shell prompt.
///
/// Cursor offsets are normalized to Swift `Character` units at the IPC boundary. That invariant is
/// load-bearing for Unicode: geometry, text splitting, and optimistic paste echo all consume this
/// value and must never reinterpret bash's byte offset independently.
nonisolated struct TerminalFocusSnapshot: Equatable, Sendable {
    let sessionIdentity: TerminalSessionIdentity
    let commandBuffer: String
    let cursorCharacterOffset: Int
    let shellType: ShellType
    let terminalBundleIdentifier: String
    let tty: String?
    let workingDirectory: String?
    let sourceRevision: UInt64
    let timestamp: Date

    /// Geometry in AppKit bottom-left screen coordinates after the service boundary converts it.
    let terminalWindowFrame: CGRect?
    let estimatedCursorRect: CGRect?
    let promptLineRect: CGRect?
    let observedCellWidth: CGFloat?

    init(
        sessionIdentity: TerminalSessionIdentity,
        commandBuffer: String,
        cursorCharacterOffset: Int,
        shellType: ShellType,
        terminalBundleIdentifier: String,
        tty: String?,
        workingDirectory: String?,
        sourceRevision: UInt64,
        timestamp: Date = Date(),
        terminalWindowFrame: CGRect? = nil,
        estimatedCursorRect: CGRect? = nil,
        promptLineRect: CGRect? = nil,
        observedCellWidth: CGFloat? = nil
    ) {
        self.sessionIdentity = sessionIdentity
        self.commandBuffer = commandBuffer
        self.cursorCharacterOffset = min(max(cursorCharacterOffset, 0), commandBuffer.count)
        self.shellType = shellType
        self.terminalBundleIdentifier = terminalBundleIdentifier
        self.tty = tty
        self.workingDirectory = workingDirectory
        self.sourceRevision = sourceRevision
        self.timestamp = timestamp
        self.terminalWindowFrame = terminalWindowFrame
        self.estimatedCursorRect = estimatedCursorRect
        self.promptLineRect = promptLineRect
        self.observedCellWidth = observedCellWidth
    }

    var precedingText: String {
        let index = commandBuffer.index(
            commandBuffer.startIndex,
            offsetBy: cursorCharacterOffset,
            limitedBy: commandBuffer.endIndex
        ) ?? commandBuffer.endIndex
        return String(commandBuffer[..<index])
    }

    var trailingText: String {
        let index = commandBuffer.index(
            commandBuffer.startIndex,
            offsetBy: cursorCharacterOffset,
            limitedBy: commandBuffer.endIndex
        ) ?? commandBuffer.endIndex
        return String(commandBuffer[index...])
    }

    /// Reflects a successful Cotabby paste until the shell editor reports the next ground-truth
    /// buffer. Bracketed paste does not trigger zsh/fish redraw hooks synchronously, so without this
    /// echo partial acceptance would reconcile against stale text and could lose separator spaces.
    func appendingInsertedText(_ insertedText: String) -> TerminalFocusSnapshot {
        guard !insertedText.isEmpty else { return self }
        return TerminalFocusSnapshot(
            sessionIdentity: sessionIdentity,
            commandBuffer: precedingText + insertedText + trailingText,
            cursorCharacterOffset: cursorCharacterOffset + insertedText.count,
            shellType: shellType,
            terminalBundleIdentifier: terminalBundleIdentifier,
            tty: tty,
            workingDirectory: workingDirectory,
            sourceRevision: sourceRevision &+ 1,
            timestamp: Date(),
            terminalWindowFrame: terminalWindowFrame,
            estimatedCursorRect: estimatedCursorRect,
            promptLineRect: promptLineRect,
            observedCellWidth: observedCellWidth
        )
    }

    /// Mirrors a successful whole-line translation until the shell hook publishes ground truth.
    /// Geometry stays anchored to the same prompt row; only the buffer, cursor, timestamp, and
    /// source revision advance.
    func replacingCommandBuffer(with replacement: String) -> TerminalFocusSnapshot {
        TerminalFocusSnapshot(
            sessionIdentity: sessionIdentity,
            commandBuffer: replacement,
            cursorCharacterOffset: replacement.count,
            shellType: shellType,
            terminalBundleIdentifier: terminalBundleIdentifier,
            tty: tty,
            workingDirectory: workingDirectory,
            sourceRevision: sourceRevision &+ 1,
            timestamp: Date(),
            terminalWindowFrame: terminalWindowFrame,
            estimatedCursorRect: estimatedCursorRect,
            promptLineRect: promptLineRect,
            observedCellWidth: observedCellWidth
        )
    }

    func withGeometry(
        windowFrame: CGRect?,
        cursorRect: CGRect,
        promptLineRect: CGRect,
        observedCellWidth: CGFloat
    ) -> TerminalFocusSnapshot {
        TerminalFocusSnapshot(
            sessionIdentity: sessionIdentity,
            commandBuffer: commandBuffer,
            cursorCharacterOffset: cursorCharacterOffset,
            shellType: shellType,
            terminalBundleIdentifier: terminalBundleIdentifier,
            tty: tty,
            workingDirectory: workingDirectory,
            sourceRevision: sourceRevision,
            timestamp: timestamp,
            terminalWindowFrame: windowFrame ?? terminalWindowFrame,
            estimatedCursorRect: cursorRect,
            promptLineRect: promptLineRect,
            observedCellWidth: observedCellWidth
        )
    }

    /// Converts the shell-specific wire cursor to the model's single character-offset invariant.
    static func normalizedCharacterOffset(rawOffset: Int, text: String, shell: ShellType) -> Int {
        guard rawOffset > 0 else { return 0 }
        switch shell {
        case .zsh, .fish:
            return min(rawOffset, text.count)
        case .bash:
            let utf8 = text.utf8
            let clamped = min(rawOffset, utf8.count)
            let utf8Index = utf8.index(utf8.startIndex, offsetBy: clamped)
            guard let stringIndex = utf8Index.samePosition(in: text) else {
                // A byte offset inside a multi-byte scalar is invalid. Move left to the nearest
                // character boundary rather than splitting the scalar or crashing.
                var candidate = clamped
                while candidate > 0 {
                    candidate -= 1
                    let index = utf8.index(utf8.startIndex, offsetBy: candidate)
                    if let boundary = index.samePosition(in: text) {
                        return text.distance(from: text.startIndex, to: boundary)
                    }
                }
                return 0
            }
            return text.distance(from: text.startIndex, to: stringIndex)
        }
    }
}

/// Mutable lifecycle record owned by `TerminalIntegrationService` on the main actor.
nonisolated struct TerminalSession: Equatable, Sendable {
    let identity: TerminalSessionIdentity
    var shellType: ShellType
    let terminalBundleIdentifier: String
    var tty: String?
    let connectedAt: Date
    var lastMessageAt: Date
    /// Last revision received from the shell hook. Optimistic acceptance echoes intentionally do
    /// not advance this counter, otherwise the hook's matching ground-truth revision would be
    /// mistaken for a replay and discarded.
    var lastWireRevision: UInt64
    var latestSnapshot: TerminalFocusSnapshot?
}
