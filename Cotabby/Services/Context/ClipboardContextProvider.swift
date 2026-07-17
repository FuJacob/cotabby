import AppKit
import Foundation
import UniformTypeIdentifiers

/// Reads the current pasteboard only when Cotabby is about to build a prompt.
///
/// Clipboard contents are highly sensitive and change outside Cotabby's control, so this service does
/// not cache or publish them. The coordinator asks for a fresh, bounded description at generation
/// time, and `SuggestionRequestFactory` still owns the final prompt clipping policy.
@MainActor
final class ClipboardContextProvider: ClipboardContextProviding {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var currentChangeCount: Int { pasteboard.changeCount }

    func currentContext() -> String? {
        if let text = normalizedText(pasteboard.string(forType: .string)) {
            return text
        }

        return imageContext()
    }

    private func normalizedText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private func imageContext() -> String? {
        if let image = NSImage(pasteboard: pasteboard) {
            return imageSummary(for: image, format: preferredImageFormat())
        }

        return imageFileContext()
    }

    private func imageFileContext() -> String? {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return nil
        }

        guard let imageURL = urls.first(where: isImageFile) else {
            return nil
        }

        let format = imageURL.pathExtension.isEmpty ? nil : imageURL.pathExtension.uppercased()
        let image = NSImage(contentsOf: imageURL)
        let imageDescription = image.map { imageSummary(for: $0, format: format) }
            ?? "Image file"

        return "\(imageDescription): \(imageURL.lastPathComponent)"
    }

    private func imageSummary(for image: NSImage, format: String?) -> String {
        let details = [
            format,
            pixelDimensions(for: image)
        ].compactMap { $0 }

        guard !details.isEmpty else {
            return "Image"
        }

        return "Image (\(details.joined(separator: ", ")))"
    }

    private func preferredImageFormat() -> String? {
        let knownTypes: [(UTType, String)] = [
            (.png, "PNG"),
            (.jpeg, "JPEG"),
            (.tiff, "TIFF"),
            (.gif, "GIF"),
            (.heic, "HEIC")
        ]

        let pasteboardTypes = Set(pasteboard.types ?? [])
        for (type, label) in knownTypes where pasteboardTypes.contains(
            NSPasteboard.PasteboardType(type.identifier)
        ) {
            return label
        }

        return nil
    }

    private func pixelDimensions(for image: NSImage) -> String? {
        let bestRepresentation = image.representations
            .filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
            .max { lhs, rhs in
                lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
            }

        if let bestRepresentation {
            return "\(bestRepresentation.pixelsWide)x\(bestRepresentation.pixelsHigh) px"
        }

        let pointWidth = Int(image.size.width.rounded())
        let pointHeight = Int(image.size.height.rounded())
        guard pointWidth > 0, pointHeight > 0 else {
            return nil
        }

        return "\(pointWidth)x\(pointHeight) pt"
    }

    private func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension)
        else {
            return false
        }

        return type.conforms(to: .image)
    }
}
