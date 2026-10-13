import Foundation

/// Safe positional arguments for a short helper that waits for the current app process to exit
/// before asking Launch Services to reopen its exact bundle. The script is constant; paths and
/// flags travel as Process arguments and are expanded only as quoted shell positional parameters.
struct ApplicationRelaunchPlan: Equatable {
    static let executableURL = URL(fileURLWithPath: "/bin/sh")
    static let waitAndOpenScript = #"""
    old_pid=$1
    app_url=$2
    shift 2
    attempt=0
    while /bin/kill -0 "$old_pid" 2>/dev/null; do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge 100 ]; then
        exit 75
      fi
      /bin/sleep 0.1
    done
    exec /usr/bin/open -n "$app_url" --args "$@"
    """#

    let processArguments: [String]

    init(
        processIdentifier: Int32,
        applicationBundleURL: URL,
        debugLoggingEnabled: Bool
    ) throws {
        guard processIdentifier > 0 else {
            throw ApplicationRelaunchPlanError.invalidProcessIdentifier
        }
        guard applicationBundleURL.isFileURL else {
            throw ApplicationRelaunchPlanError.applicationURLMustBeFileURL
        }

        // With `sh -c`, the argument immediately after the script becomes `$0`; the remaining
        // values become `$1...`. No caller value is interpolated into the script source.
        processArguments = [
            "-c",
            Self.waitAndOpenScript,
            "cotabby-relaunch",
            String(processIdentifier),
            applicationBundleURL.absoluteString,
            "-cotabby-open-settings"
        ] + (debugLoggingEnabled ? ["-cotabby-debug"] : [])
    }
}

enum ApplicationRelaunchPlanError: Error {
    case invalidProcessIdentifier
    case applicationURLMustBeFileURL
}
