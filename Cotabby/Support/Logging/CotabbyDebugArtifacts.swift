import Foundation

/// File overview:
/// The one place that knows where Cotabby's on-disk debug artifacts live and how they are protected.
///
/// Every artifact the developer diagnostics write can hold what the user typed or had on screen:
/// prompts and completions (`llm-io.jsonl`, and prompt blocks in `cotabby.jsonl`), window
/// screenshots with their raw OCR text, Accessibility values from the focused page, and the text
/// of the caret's line next to each calibration strip. Earlier builds split them between
/// `~/Library/Logs/<app>/` and the Desktop (which iCloud Desktop sync can upload) and created them
/// with the default 0755/0644 modes. Keeping the layout here means every writer lands in the same
/// owner-only directory, typing history's Delete All can find each artifact that may hold typed
/// text, and the docs describe a single layout.
///
/// The modes keep other accounts on the Mac out. They do not stop a process running as the same
/// user, which is why the menu says when debug logging is on (`CotabbyDebugOptions`).
///
/// `nonisolated` because the JSONL writers call it from whatever thread swift-log logs on, and the
/// strip dumps call it from nonisolated statics; everything here is file-system work with no state.
nonisolated enum CotabbyDebugArtifacts {
    // MARK: - Layout

    static let eventLogName = "cotabby.jsonl"
    static let llmIOLogName = "llm-io.jsonl"
    static let axDumpName = "ax-dump.txt"
    static let screenshotsFolderName = "screenshots"
    static let stripsFolderName = "strips"

    /// `~/Library/Logs/<CFBundleName>/`. The bundle name is what keeps the dev identity's
    /// artifacts ("Cotabby Dev") apart from the released app's ("Cotabby").
    static let directoryURL: URL? = directory(
        libraryURL: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
        bundleName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
    )

    /// The layout rule behind `directoryURL`, separated so tests can check it without the host
    /// app's bundle or the real home directory.
    static func directory(libraryURL: URL?, bundleName: String?) -> URL? {
        guard let libraryURL else { return nil }
        let name = bundleName.flatMap { $0.isEmpty ? nil : $0 } ?? "Cotabby"
        return libraryURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Every artifact in the directory that can hold typed or on-screen text, including the
    /// one-step rotations the JSONL writers leave beside the live files. `cotabby.jsonl` is on the
    /// list: the suggestion debug logger writes full prompt blocks through it, and mismatch lines
    /// carry the typed characters.
    static let userTextArtifactNames: [String] = [
        eventLogName,
        eventLogName + ".1",
        llmIOLogName,
        llmIOLogName + ".1",
        axDumpName,
        screenshotsFolderName,
        stripsFolderName
    ]

    // MARK: - Calibration strips

    /// `defaults write <bundle> cotabbyDumpCalibrationStrips -bool YES` dumps every calibration
    /// strip and caret capture (pixels around the caret plus the line's text) into `strips/`.
    static let calibrationStripsDefaultsKey = "cotabbyDumpCalibrationStrips"

    /// Read once at launch. Only DEBUG and `Cotabby Dev` builds honor the switch: unlike
    /// `-cotabby-debug` it has no indicator and needs no relaunch flag, so in the shipped app a
    /// single `defaults write` would start a silent stream of screen captures. `COTABBY_DEV` is
    /// included because the dev identity's Release configuration is how placement is checked
    /// against real pixels, and that build never ships.
    static let dumpsCalibrationStrips: Bool = {
        #if DEBUG || COTABBY_DEV
        return UserDefaults.standard.bool(forKey: calibrationStripsDefaultsKey)
        #else
        return false
        #endif
    }()

    /// Newest captures kept in `strips/`. Each is a small PNG plus a JSON sidecar; a session left
    /// dumping writes one per calibration, so without a cap the folder grows without bound.
    static let maximumCalibrationCaptures = 200

    // MARK: - Owner-only files

    static let directoryPermissions = 0o700
    static let filePermissions = 0o600

    /// The artifact directory, or a folder inside it, created owner-only. Nil when it can't be
    /// created, in which case the caller skips its artifact rather than writing it elsewhere.
    /// The root is tightened every time because an earlier build created it 0755.
    static func preparedDirectory(_ components: [String] = [], root: URL? = CotabbyDebugArtifacts.directoryURL) -> URL? {
        guard let root, preparePrivateDirectory(root) else { return nil }
        let folder = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        guard components.isEmpty || preparePrivateDirectory(folder) else { return nil }
        return folder
    }

    /// Creates `directory` and any missing parents as 0700, then sets the mode on `directory`
    /// itself, which `createDirectory` leaves alone when it already exists.
    @discardableResult
    static func preparePrivateDirectory(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
            try fileManager.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: directory.path)
            return true
        } catch {
            return false
        }
    }

    /// Writes `data` to `url` as a 0600 file, replacing what was there.
    @discardableResult
    static func writePrivateFile(_ data: Data, to url: URL) -> Bool {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: filePermissions]
        ) else {
            return false
        }
        // `createFile` sets the mode on a file it creates; repeating it covers a file it replaced.
        restrictToOwner(url)
        return true
    }

    /// Sets an existing file to 0600: a log an earlier build created is still 0644.
    static func restrictToOwner(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: url.path)
    }

    // MARK: - Eviction and deletion

    /// Deletes all but the newest `limit` captures in `folder`. A capture is every file sharing a
    /// name stem (`strip-123.png` with `strip-123.json`), so a pair is kept or removed together;
    /// its age is the newest modification date among its files.
    static func evictOldCaptures(in folder: URL, keeping limit: Int) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return
        }

        var captures: [String: (date: Date, files: [URL])] = [:]
        for file in files {
            let stem = file.deletingPathExtension().lastPathComponent
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            var capture = captures[stem] ?? (date: Date.distantPast, files: [URL]())
            capture.date = max(capture.date, modified)
            capture.files.append(file)
            captures[stem] = capture
        }

        let overflow = captures.count - max(limit, 0)
        guard overflow > 0 else { return }
        // Ties fall back to the stem so the same folder always loses the same captures.
        let oldestFirst = captures.sorted { lhs, rhs in
            lhs.value.date != rhs.value.date ? lhs.value.date < rhs.value.date : lhs.key < rhs.key
        }
        for (_, capture) in oldestFirst.prefix(overflow) {
            for file in capture.files {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// Removes every debug artifact that can hold what the user typed or saw. Typing history's
    /// Delete All calls this so deleting "what I typed" also covers the diagnostic copies.
    ///
    /// Runs whether or not debug mode is on now: a previous debug session's files are still there.
    /// When the JSONL sinks are installed, their writers keep handles to the files just unlinked,
    /// so they are reopened; otherwise every later line would go to a deleted file. The sinks are
    /// installed exactly when `CotabbyDebugOptions.isEnabled` (see `CotabbyLogger`), and the shared
    /// writers must not be touched otherwise because referencing one creates its log file.
    static func deleteUserTextArtifacts() {
        guard let directoryURL else { return }
        removeUserTextArtifacts(in: directoryURL)
        if CotabbyDebugOptions.isEnabled {
            JSONLFileWriter.events.reopen()
            JSONLFileWriter.llmIO.reopen()
        }
    }

    /// The file-system half of `deleteUserTextArtifacts`, against any directory so tests can run
    /// it on a temporary one. Only the names in `userTextArtifactNames` are removed.
    static func removeUserTextArtifacts(in directory: URL) {
        let fileManager = FileManager.default
        for name in userTextArtifactNames {
            let url = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}
