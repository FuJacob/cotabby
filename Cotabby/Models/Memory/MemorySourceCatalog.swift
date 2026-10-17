import Foundation

/// File overview:
/// The sources conversation memory can read, described once: what each is, which apps it serves,
/// what it needs, and how long its records are kept.
///
/// Why a catalog: the pane lists sources, suggestions map the focused app to sources, and retention
/// needs to know which sources are documents rather than messages. One table keeps those agreeing.
/// Reading a source is a separate concern (the readers in `Services/Memory/Readers`).

nonisolated struct MemorySourceDescriptor: Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    let appBundleIds: [String]
    let requirements: [MemorySource.Requirement]
    let optionsSchema: [String: String]
    /// Documents, not messages: kept whatever their date. Retention ("keep messages for N days")
    /// would otherwise drop a handbook or contract because the file was last edited long ago.
    var keepsAllDates = false
}

nonisolated enum MemorySourceCatalog {
    private static let calendarAccess = MemorySource.Requirement(
        kind: "calendar", title: "Calendar access",
        detail: "Cotabby needs access to your calendars to remember events and check your availability."
    )

    private static let fullDiskAccess = MemorySource.Requirement(
        kind: "full_disk_access", title: "Full Disk Access",
        detail: "Cotabby needs Full Disk Access to read this app's local history."
    )

    static let all: [MemorySourceDescriptor] = [
        MemorySourceDescriptor(
            id: "whatsapp", title: "WhatsApp",
            description: "Chats from WhatsApp for Mac, read from its local database.",
            appBundleIds: ["net.whatsapp.WhatsApp"], requirements: [fullDiskAccess], optionsSchema: [:]
        ),
        MemorySourceDescriptor(
            id: "apple_mail", title: "Apple Mail",
            description: "Mail from all accounts in the Mail app, read from its local store.",
            appBundleIds: ["com.apple.mail"], requirements: [fullDiskAccess], optionsSchema: [:]
        ),
        MemorySourceDescriptor(
            id: "outlook", title: "Outlook",
            description: "Mail from Outlook for Mac, read from its local files: New Outlook's store and the classic " +
                "database. Mail Outlook keeps only online is not included.",
            appBundleIds: ["com.microsoft.Outlook"], requirements: [fullDiskAccess], optionsSchema: [:]
        ),
        MemorySourceDescriptor(
            id: "teams", title: "Microsoft Teams",
            description: "Chats, meeting chats and channels the Teams app has cached on this Mac (usually the recent " +
                "months; older history stays in Microsoft 365).",
            appBundleIds: ["com.microsoft.teams2", "com.microsoft.teams"], requirements: [fullDiskAccess], optionsSchema: [:]
        ),
        MemorySourceDescriptor(
            id: "calendar", title: "Calendar",
            description: "Events from every calendar in the Calendar app, including work accounts added there: what, " +
                "when, where and with whom, from the past year to three months ahead. When someone asks when you " +
                "are free, answers check these calendars for busy and free times only.",
            appBundleIds: ["com.apple.iCal"], requirements: [calendarAccess], optionsSchema: [:]
        ),
        MemorySourceDescriptor(
            id: "documents", title: "Documents Folder",
            description: "Plain-text and Markdown files in a folder you choose: reference notes suggestions can draw on.",
            appBundleIds: [], requirements: [MemorySource.Requirement(kind: "folder", title: "Folder",
                                                                       detail: "The folder whose .txt and .md files are remembered.")],
            optionsSchema: ["folder": "Folder"],
            keepsAllDates: true
        )
    ] + [("icloud_drive", "iCloud Drive"), ("google_drive", "Google Drive"), ("onedrive", "OneDrive")]
        .map { cloudDrive(id: $0.0, title: $0.1) }

    /// A cloud drive's documents (read by `CloudDriveReader`, which uses the same ids).
    private static func cloudDrive(id: String, title: String) -> MemorySourceDescriptor {
        MemorySourceDescriptor(
            id: id, title: title,
            description: "Documents in \(title) on this Mac, every account: PDF, Word, PowerPoint, Excel, RTF, " +
                "text and Markdown. Online-only files are downloaded by \(title) to be read, then given back. " +
                "Google Docs, Sheets and Slides stay in the cloud and are not read.",
            appBundleIds: [], requirements: [fullDiskAccess], optionsSchema: [:],
            keepsAllDates: true
        )
    }

    static var sourcesKeepingAllDates: Set<String> { Set(all.filter(\.keepsAllDates).map(\.id)) }

    static func keepsAllDates(_ id: String) -> Bool { descriptor(id)?.keepsAllDates ?? false }

    static func descriptor(_ id: String) -> MemorySourceDescriptor? {
        all.first { $0.id == id }
    }

    /// Whether answers may quote facts from `id`'s other conversations: only when the user turned
    /// "Use for answers" on for it. Off for every source by default, because an answer goes to
    /// someone else and could carry what was said in a conversation they were never part of.
    static func isAnswerSource(_ id: String, settings: MemorySourceSettings?) -> Bool {
        canAnswer(id) && (settings?.answerSource ?? false)
    }

    /// Whether a source can be an answer source at all. Never Calendar: its records hold what an
    /// event is and who is in it, and answers give only busy and free times (`AvailabilityFacts`,
    /// read live from EventKit, not from memory).
    static func canAnswer(_ id: String) -> Bool {
        id != "calendar"
    }
}
