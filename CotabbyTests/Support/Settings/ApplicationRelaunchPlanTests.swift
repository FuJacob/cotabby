import Foundation
import Testing
@testable import Cotabby

/// Validates the helper's fixed script/positional-argument contract without launching Cotabby or
/// starting a shell process. Injected launch and termination closures cover both success and error.
@MainActor
struct ApplicationRelaunchPlanTests {
    @Test
    func planPreservesDevBundleURLAndRequiredLaunchFlagsAsArguments() throws {
        let bundleURL = URL(fileURLWithPath: "/Applications/Cotabby Dev; $(touch marker).app")
        let plan = try ApplicationRelaunchPlan(
            processIdentifier: 1234,
            applicationBundleURL: bundleURL,
            debugLoggingEnabled: true
        )

        #expect(ApplicationRelaunchPlan.executableURL.path == "/bin/sh")
        #expect(plan.processArguments[0] == "-c")
        #expect(plan.processArguments[1] == ApplicationRelaunchPlan.waitAndOpenScript)
        #expect(
            Array(plan.processArguments.dropFirst(2)) == [
                "cotabby-relaunch",
                "1234",
                bundleURL.absoluteString,
                "-cotabby-open-settings",
                "-cotabby-debug"
            ]
        )
        #expect(!plan.processArguments[1].contains(bundleURL.path))
    }

    @Test
    func restartTerminatesOnlyAfterTheHelperStarts() throws {
        enum Event: Equatable {
            case helperStarted
            case terminated
        }

        let bundleURL = URL(fileURLWithPath: "/Applications/Cotabby Dev.app")
        var launchedExecutable: URL?
        var launchedArguments: [String]?
        var events: [Event] = []
        let relauncher = ApplicationRelauncher(
            helperLauncher: { executable, arguments in
                launchedExecutable = executable
                launchedArguments = arguments
                events.append(.helperStarted)
            },
            applicationTerminator: { events.append(.terminated) }
        )

        try relauncher.restart(
            applicationBundleURL: bundleURL,
            processIdentifier: 99,
            debugLoggingEnabled: false
        )

        #expect(launchedExecutable?.path == "/bin/sh")
        #expect(launchedArguments?.contains("-cotabby-open-settings") == true)
        #expect(launchedArguments?.contains("-cotabby-debug") == false)
        #expect(events == [.helperStarted, .terminated])
    }

    @Test
    func failedHelperSpawnLeavesTheCurrentApplicationRunning() {
        enum HelperError: Error { case couldNotStart }

        var didTerminate = false
        let relauncher = ApplicationRelauncher(
            helperLauncher: { _, _ in throw HelperError.couldNotStart },
            applicationTerminator: { didTerminate = true }
        )

        var didThrow = false
        do {
            try relauncher.restart(
                applicationBundleURL: URL(fileURLWithPath: "/Applications/Cotabby.app"),
                processIdentifier: 99,
                debugLoggingEnabled: false
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(!didTerminate)
    }

    @Test
    func planRejectsInvalidProcessIdentifiersAndNonFileURLs() {
        let appURL = URL(fileURLWithPath: "/Applications/Cotabby.app")
        let webURL = URL(string: "https://example.com/Cotabby.app")!

        var invalidPIDRejected = false
        do {
            _ = try ApplicationRelaunchPlan(
                processIdentifier: 0,
                applicationBundleURL: appURL,
                debugLoggingEnabled: false
            )
        } catch let error as ApplicationRelaunchPlanError {
            if case .invalidProcessIdentifier = error {
                invalidPIDRejected = true
            }
        } catch {}

        var nonFileURLRejected = false
        do {
            _ = try ApplicationRelaunchPlan(
                processIdentifier: 99,
                applicationBundleURL: webURL,
                debugLoggingEnabled: false
            )
        } catch let error as ApplicationRelaunchPlanError {
            if case .applicationURLMustBeFileURL = error {
                nonFileURLRejected = true
            }
        } catch {}

        #expect(invalidPIDRejected)
        #expect(nonFileURLRejected)
    }
}
