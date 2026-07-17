import Darwin
import Foundation
import Logging

/// Main-actor session model for cooperative terminal shell integration.
///
/// The nested socket server owns POSIX descriptors and JSON framing on a private serial queue. Only
/// validated value messages cross back to the main actor, keeping per-keystroke IPC away from UI
/// work while making session callbacks safe for focus/coordinator consumers.
@MainActor
final class TerminalIntegrationService {
    var onSnapshotUpdate: ((TerminalFocusSnapshot) -> Void)?
    var onSessionChange: (() -> Void)?

    private(set) var sessions: [TerminalSessionIdentity: TerminalSession] = [:]
    private(set) var isRunning = false

    let paths: TerminalIntegrationPaths
    private let installer: TerminalIntegrationResourceInstaller
    private let logger = Logger(label: "com.cotabby.terminal-integration")
    private var server: TerminalSocketServer?
    private var pruneTimer: Timer?

    init(
        paths: TerminalIntegrationPaths = .current(),
        bundledHooksDirectory: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("shell-integration", isDirectory: true)
    ) {
        self.paths = paths
        installer = TerminalIntegrationResourceInstaller(
            paths: paths,
            bundledHooksDirectory: bundledHooksDirectory
        )
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        do {
            try installer.install()
            let server = TerminalSocketServer(socketURL: paths.socketURL) { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.handle(message)
                }
            }
            try server.start()
            self.server = server
            isRunning = true
            startPruneTimer()
            logger.info("Terminal integration listening at \(self.paths.socketURL.path)")
            return true
        } catch {
            logger.error("Terminal integration failed to start: \(error.localizedDescription)")
            server = nil
            isRunning = false
            return false
        }
    }

    func stop() {
        pruneTimer?.invalidate()
        pruneTimer = nil
        server?.stop()
        server = nil
        isRunning = false
        let hadSessions = !sessions.isEmpty
        sessions.removeAll()
        if hadSessions {
            onSessionChange?()
        }
    }

    func hasActiveSession(forBundleIdentifier bundleIdentifier: String) -> Bool {
        sessions.values.contains { $0.terminalBundleIdentifier == bundleIdentifier }
    }

    /// Treat a hook as authoritative only while it is still publishing. The preference toggle by
    /// itself must never make an opaque AX terminal surface eligible after a hook goes stale.
    func isRecentlyReporting(
        forBundleIdentifier bundleIdentifier: String,
        within interval: TimeInterval = 2.5,
        now: Date = Date()
    ) -> Bool {
        sessions.values.contains {
            $0.terminalBundleIdentifier == bundleIdentifier
                && now.timeIntervalSince($0.lastMessageAt) <= interval
        }
    }

    func activeShellPIDs(forBundleIdentifier bundleIdentifier: String) -> [Int32] {
        sessions.values.compactMap {
            $0.terminalBundleIdentifier == bundleIdentifier ? $0.identity.shellPid : nil
        }
    }

    func identity(forElementIdentifier elementIdentifier: String) -> TerminalSessionIdentity? {
        sessions.keys.first { $0.elementIdentifier == elementIdentifier }
    }

    func latestSnapshot(forBundleIdentifier bundleIdentifier: String) -> TerminalFocusSnapshot? {
        sessions.values
            .filter { $0.terminalBundleIdentifier == bundleIdentifier }
            .compactMap(\.latestSnapshot)
            .max { $0.timestamp < $1.timestamp }
    }

    func latestSnapshot(for identity: TerminalSessionIdentity) -> TerminalFocusSnapshot? {
        sessions[identity]?.latestSnapshot
    }

    func applyOptimisticInsertion(identity: TerminalSessionIdentity, insertedText: String) {
        guard !insertedText.isEmpty,
              var session = sessions[identity],
              let snapshot = session.latestSnapshot else { return }
        let updated = snapshot.appendingInsertedText(insertedText)
        session.latestSnapshot = updated
        session.lastMessageAt = Date()
        sessions[identity] = session
        onSnapshotUpdate?(updated)
    }

    func applyOptimisticReplacement(identity: TerminalSessionIdentity, replacementText: String) {
        guard !replacementText.isEmpty,
              var session = sessions[identity],
              let snapshot = session.latestSnapshot else { return }
        let updated = snapshot.replacingCommandBuffer(with: replacementText)
        session.latestSnapshot = updated
        session.lastMessageAt = Date()
        sessions[identity] = session
        onSnapshotUpdate?(updated)
    }

    func pruneDeadSessions() {
        let dead = sessions.keys.filter { identity in
            kill(identity.shellPid, 0) != 0 && errno == ESRCH
        }
        guard !dead.isEmpty else { return }
        for identity in dead {
            sessions[identity] = nil
        }
        onSessionChange?()
    }

    private func startPruneTimer() {
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pruneDeadSessions() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    private func handle(_ message: TerminalIpcMessage) {
        switch message.type {
        case .buffer:
            handleBuffer(message)
        case .disconnect:
            handleDisconnect(message)
        }
    }

    private func handleBuffer(_ message: TerminalIpcMessage) {
        guard let text = message.text,
              text.count <= 32_768,
              !text.contains("\0"),
              let rawCursor = message.cursor,
              rawCursor >= 0,
              let shell = message.shell,
              let terminal = message.terminal,
              terminal.count <= 255,
              TerminalAppDetector.isTerminalHost(bundleIdentifier: terminal),
              let pid = message.pid,
              Self.isCurrentUserProcess(pid),
              let nonce = message.session,
              Self.isValidNonce(nonce),
              let tty = message.tty,
              tty.hasPrefix("/dev/"),
              tty.count <= 255,
              !tty.contains("\0"),
              let revision = message.revision,
              (message.cwd?.count ?? 0) <= 4_096,
              message.cwd?.contains("\0") != true else {
            logger.warning("Rejected malformed or untrusted terminal buffer frame")
            return
        }

        let maximumCursor = shell == .bash ? text.utf8.count : text.count
        guard rawCursor <= maximumCursor else {
            logger.warning("Rejected terminal buffer with an out-of-range cursor")
            return
        }

        let identity = TerminalSessionIdentity(shellPid: pid, nonce: nonce)
        if let existing = sessions[identity] {
            guard existing.terminalBundleIdentifier == terminal,
                  existing.tty == tty || existing.tty == nil,
                  revision > existing.lastWireRevision else {
                return
            }
        }

        let snapshot = TerminalFocusSnapshot(
            sessionIdentity: identity,
            commandBuffer: text,
            cursorCharacterOffset: TerminalFocusSnapshot.normalizedCharacterOffset(
                rawOffset: rawCursor,
                text: text,
                shell: shell
            ),
            shellType: shell,
            terminalBundleIdentifier: terminal,
            tty: tty,
            workingDirectory: message.cwd,
            sourceRevision: revision
        )
        let now = Date()
        let isNew = sessions[identity] == nil
        if var session = sessions[identity] {
            session.shellType = shell
            session.tty = tty
            session.lastMessageAt = now
            session.lastWireRevision = revision
            session.latestSnapshot = snapshot
            sessions[identity] = session
        } else {
            sessions[identity] = TerminalSession(
                identity: identity,
                shellType: shell,
                terminalBundleIdentifier: terminal,
                tty: tty,
                connectedAt: now,
                lastMessageAt: now,
                lastWireRevision: revision,
                latestSnapshot: snapshot
            )
        }
        if isNew {
            onSessionChange?()
        }
        onSnapshotUpdate?(snapshot)
    }

    private func handleDisconnect(_ message: TerminalIpcMessage) {
        guard let pid = message.pid,
              let nonce = message.session,
              Self.isValidNonce(nonce) else { return }
        let identity = TerminalSessionIdentity(shellPid: pid, nonce: nonce)
        guard sessions.removeValue(forKey: identity) != nil else { return }
        onSessionChange?()
    }

    private static func isCurrentUserProcess(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return read == size && info.pbi_uid == geteuid()
    }

    private static func isValidNonce(_ nonce: String) -> Bool {
        guard !nonce.isEmpty, nonce.count <= 64 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return nonce.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// Bounded, same-user Unix-domain socket server.
///
/// Descriptor state is isolated to `queue`. Every descriptor has exactly one close owner in the
/// explicit teardown helpers; DispatchSource cancel handlers never close descriptors, avoiding the
/// reused-FD double-close race in the prototype implementation.
nonisolated final class TerminalSocketServer: @unchecked Sendable {
    enum ServerError: LocalizedError {
        case pathTooLong
        case unsafeExistingEndpoint(String)
        case endpointInUse
        case posix(operation: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .pathTooLong: "Terminal socket path is too long."
            case let .unsafeExistingEndpoint(reason): "Refusing terminal socket path: \(reason)."
            case .endpointInUse: "Another Cotabby process already owns the terminal socket."
            case let .posix(operation, code): "\(operation) failed: \(String(cString: strerror(code)))."
            }
        }
    }

    private struct Client {
        let source: DispatchSourceRead
        var buffer: Data
    }

    private static let maximumFrameBytes = 64 * 1_024
    private static let maximumClients = 32

    private let socketURL: URL
    private let onMessage: @Sendable (TerminalIpcMessage) -> Void
    private let queue = DispatchQueue(label: "com.cotabby.terminal-ipc", qos: .userInitiated)
    private var listenerDescriptor: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var ownsSocketPath = false

    init(socketURL: URL, onMessage: @escaping @Sendable (TerminalIpcMessage) -> Void) {
        self.socketURL = socketURL
        self.onMessage = onMessage
    }

    func start() throws {
        try queue.sync { try startOnQueue() }
    }

    func stop() {
        queue.sync { stopOnQueue() }
    }

    private func startOnQueue() throws {
        guard listenerSource == nil else { return }
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw ServerError.posix(operation: "chmod socket directory", code: errno)
        }
        try prepareEndpointPath()

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ServerError.posix(operation: "socket", code: errno)
        }
        do {
            try setNonBlocking(descriptor)
            var address = try socketAddress(path: socketURL.path)
            let length = socklen_t(MemoryLayout<sa_family_t>.size + socketURL.path.utf8.count + 1)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, length)
                }
            }
            guard result == 0 else {
                throw ServerError.posix(operation: "bind", code: errno)
            }
            ownsSocketPath = true
            guard chmod(socketURL.path, 0o600) == 0 else {
                throw ServerError.posix(operation: "chmod socket", code: errno)
            }
            guard Darwin.listen(descriptor, 16) == 0 else {
                throw ServerError.posix(operation: "listen", code: errno)
            }

            listenerDescriptor = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAvailableClients() }
            source.resume()
            listenerSource = source
        } catch {
            Darwin.close(descriptor)
            if ownsSocketPath {
                Darwin.unlink(socketURL.path)
                ownsSocketPath = false
            }
            throw error
        }
    }

    private func stopOnQueue() {
        for descriptor in Array(clients.keys) {
            removeClient(descriptor)
        }
        if let source = listenerSource {
            source.cancel()
            listenerSource = nil
        }
        if listenerDescriptor >= 0 {
            Darwin.close(listenerDescriptor)
            listenerDescriptor = -1
        }
        if ownsSocketPath {
            Darwin.unlink(socketURL.path)
            ownsSocketPath = false
        }
    }

    private func prepareEndpointPath() throws {
        var info = stat()
        guard lstat(socketURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw ServerError.posix(operation: "lstat", code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw ServerError.unsafeExistingEndpoint("existing path is not a socket")
        }
        guard info.st_uid == geteuid() else {
            throw ServerError.unsafeExistingEndpoint("existing socket is owned by another user")
        }

        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw ServerError.posix(operation: "socket probe", code: errno) }
        defer { Darwin.close(probe) }
        var address = try socketAddress(path: socketURL.path)
        let length = socklen_t(MemoryLayout<sa_family_t>.size + socketURL.path.utf8.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, length)
            }
        }
        if result == 0 {
            throw ServerError.endpointInUse
        }
        let connectError = errno
        guard connectError == ECONNREFUSED || connectError == ENOENT else {
            throw ServerError.posix(operation: "probe existing socket", code: connectError)
        }
        guard Darwin.unlink(socketURL.path) == 0 else {
            throw ServerError.posix(operation: "unlink stale socket", code: errno)
        }
    }

    private func acceptAvailableClients() {
        while clients.count < Self.maximumClients {
            let descriptor = Darwin.accept(listenerDescriptor, nil, nil)
            guard descriptor >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            var peerUser: uid_t = 0
            var peerGroup: gid_t = 0
            guard getpeereid(descriptor, &peerUser, &peerGroup) == 0,
                  peerUser == geteuid() else {
                Darwin.close(descriptor)
                continue
            }
            do {
                try setNonBlocking(descriptor)
            } catch {
                Darwin.close(descriptor)
                continue
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readClient(descriptor) }
            clients[descriptor] = Client(source: source, buffer: Data())
            source.resume()
        }
    }

    private func readClient(_ descriptor: Int32) {
        guard clients[descriptor] != nil else { return }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                clients[descriptor]?.buffer.append(contentsOf: bytes[0..<count])
                guard processFrames(for: descriptor) else {
                    removeClient(descriptor)
                    return
                }
                continue
            }
            if count == 0 {
                removeClient(descriptor)
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            removeClient(descriptor)
            return
        }
    }

    private func processFrames(for descriptor: Int32) -> Bool {
        while let buffer = clients[descriptor]?.buffer,
              let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(buffer[..<newline])
            let remainder = Data(buffer[buffer.index(after: newline)...])
            clients[descriptor]?.buffer = remainder
            guard line.count <= Self.maximumFrameBytes else { return false }
            guard !line.isEmpty else { continue }
            if let message = try? JSONDecoder().decode(TerminalIpcMessage.self, from: line) {
                onMessage(message)
            }
        }
        return (clients[descriptor]?.buffer.count ?? 0) <= Self.maximumFrameBytes
    }

    private func removeClient(_ descriptor: Int32) {
        guard let client = clients.removeValue(forKey: descriptor) else { return }
        client.source.cancel()
        Darwin.close(descriptor)
    }

    private func setNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ServerError.posix(operation: "fcntl", code: errno)
        }
    }

    private func socketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ServerError.pathTooLong
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                bytes.withUnsafeBufferPointer { source in
                    _ = memcpy(destination, source.baseAddress!, source.count)
                }
            }
        }
        return address
    }
}
