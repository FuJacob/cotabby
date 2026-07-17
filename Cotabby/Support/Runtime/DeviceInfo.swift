import Foundation

/// File overview:
/// Pure helper that snapshots host details we attach to outbound feedback links:
/// Cotabby version, macOS version, Mac model identifier, CPU/chip brand, and physical memory.
///
/// Lives in `Support/` because it has no side effects beyond reading bundle metadata and a couple
/// of `sysctlbyname` values; nothing here owns lifecycle or actor state.
enum DeviceInfo {
    /// Snapshot of host info to attach to feedback links. Each field is optional so a missing
    /// sysctl key never produces a half-filled URL with the literal string "unknown".
    struct Snapshot {
        let appVersion: String?
        let macosVersion: String?
        let model: String?
        let chip: String?
        let memoryGB: Int?
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            appVersion: bundleVersion(),
            macosVersion: macosVersionString(),
            model: sysctlString("hw.model"),
            // `machdep.cpu.brand_string` reports the chip on both Intel ("Intel(R) Core(TM)...") and
            // Apple Silicon ("Apple M3 Pro") on every supported macOS (14+), so the chip field is
            // populated on all Macs we run on. It only returns nil under unusual conditions, in which
            // case `appending(to:)` simply omits the field rather than sending a blank value.
            chip: sysctlString("machdep.cpu.brand_string"),
            memoryGB: physicalMemoryGB()
        )
    }

    /// User-visible app version (CFBundleShortVersionString), falling back to the build number.
    private static func bundleVersion() -> String? {
        let info = Bundle.main.infoDictionary
        if let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty {
            return short
        }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            return build
        }
        return nil
    }

    private static func macosVersionString() -> String? {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        // We want a short, user-friendly "14.6" rather than `operatingSystemVersionString` which
        // includes the build number and a "Version " prefix.
        if version.patchVersion == 0 {
            return "\(version.majorVersion).\(version.minorVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Reads a C-string sysctl key, trims trailing NUL/whitespace. Returns nil when the key is
    /// missing (Rosetta translation, future macOS rename) so the caller can omit the field.
    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let value = String(cString: buffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Physical memory rounded to the nearest whole GB. Returns nil only if reporting fails.
    private static func physicalMemoryGB() -> Int? {
        let bytes = ProcessInfo.processInfo.physicalMemory
        guard bytes > 0 else { return nil }
        let gigabytes = Double(bytes) / 1_073_741_824.0
        return Int(gigabytes.rounded())
    }
}

extension DeviceInfo.Snapshot {
    /// Builds a URL with the snapshot serialized as query items. Unset fields are omitted so the
    /// landing page can tell apart "user cleared this" from "we never knew it".
    func appending(to base: URL) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        var items: [URLQueryItem] = components.queryItems ?? []
        func add(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            items.append(URLQueryItem(name: name, value: value))
        }
        add("appVersion", appVersion)
        add("macosVersion", macosVersion)
        add("model", model)
        add("chip", chip)
        if let memoryGB { add("memoryGB", String(memoryGB)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url ?? base
    }
}
