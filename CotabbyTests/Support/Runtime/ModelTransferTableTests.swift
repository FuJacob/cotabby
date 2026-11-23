import XCTest
@testable import Cotabby

/// Transition tests for the download lifecycle table. Every phase is driven through pause,
/// cancel, and each way a transfer can finish, plus the on-disk reconciliation rules.
final class ModelTransferTableTests: XCTestCase {
    private let resumeData = Data("resume".utf8)

    private func makeModel(_ source: String, filename: String = "shared.gguf") -> DownloadableRuntimeModel {
        DownloadableRuntimeModel(
            filename: filename,
            displayName: filename,
            downloadURL: URL(string: "https://example.com/\(source)/\(filename)")!,
            approximateSizeInGigabytes: 1
        )
    }

    private func runningTable(_ model: DownloadableRuntimeModel) -> ModelTransferTable {
        var table = ModelTransferTable()
        XCTAssertEqual(table.start(model, isInstalled: false), .started)
        return table
    }

    private func pausedTable(_ model: DownloadableRuntimeModel, progress: Double? = 0.4, resumeData: Data? = nil) -> ModelTransferTable {
        var table = runningTable(model)
        table.updateProgress(model.id, progress: progress)
        table.finish(model.id, .paused(resumeData: resumeData), isInstalled: false)
        return table
    }

    // MARK: - start

    func test_start_fromNothingRunsWithUnknownProgress() {
        let model = makeModel("a")
        let table = runningTable(model)

        XCTAssertTrue(table.isRunning(model.id))
        XCTAssertEqual(table.displayState(for: model.id), .downloading(progress: nil))
        XCTAssertNil(table.stopIntent(for: model.id))
        XCTAssertNil(table.resumeData(for: model.id))
    }

    func test_start_whileRunningChangesNothing() {
        let model = makeModel("a")
        var table = runningTable(model)
        table.updateProgress(model.id, progress: 0.3)
        let before = table

        XCTAssertEqual(table.start(model, isInstalled: false), .alreadyRunning)
        XCTAssertEqual(table, before)
    }

    func test_start_whenInstalledPublishesDownloadedWithoutRunning() {
        let model = makeModel("a")
        var table = ModelTransferTable()

        XCTAssertEqual(table.start(model, isInstalled: true), .alreadyInstalled)
        XCTAssertEqual(table.displayState(for: model.id), .downloaded)
        XCTAssertFalse(table.isRunning(model.id))
    }

    func test_start_fromPausedResumesWithItsProgressAndResumeData() {
        let model = makeModel("a")
        var table = pausedTable(model, progress: 0.4, resumeData: resumeData)

        XCTAssertEqual(table.start(model, isInstalled: false), .started)
        XCTAssertEqual(table.displayState(for: model.id), .downloading(progress: 0.4))
        XCTAssertEqual(table.resumeData(for: model.id), resumeData)
        XCTAssertNil(table.stopIntent(for: model.id), "A resumed transfer must not inherit the pause that stopped it")
    }

    func test_start_fromFailedRetriesWithoutProgressOrResumeData() {
        let model = makeModel("a")
        var table = pausedTable(model, resumeData: resumeData)
        XCTAssertEqual(table.start(model, isInstalled: false), .started)
        table.finish(model.id, .failed("network"), isInstalled: false)

        XCTAssertEqual(table.start(model, isInstalled: false), .started)
        XCTAssertEqual(table.displayState(for: model.id), .downloading(progress: nil))
        XCTAssertNil(table.resumeData(for: model.id))
    }

    func test_start_isBlockedWhileAnotherSourceOfTheSameFileIsRunningOrPaused() {
        let first = makeModel("first")
        let second = makeModel("second")

        for var table in [runningTable(first), pausedTable(first)] {
            XCTAssertEqual(table.start(second, isInstalled: false), .blocked(by: first))
            XCTAssertEqual(
                table.displayState(for: second.id),
                .failed(ModelTransferTable.conflictMessage(filename: "shared.gguf"))
            )
            XCTAssertFalse(table.isRunning(second.id))
        }
    }

    func test_start_destinationConflictIgnoresCaseAndUnicodeNormalization() {
        let first = makeModel("first", filename: "Caf\u{00E9}.gguf")
        let second = makeModel("second", filename: "cafe\u{0301}.GGUF")
        var table = runningTable(first)

        XCTAssertEqual(table.start(second, isInstalled: false), .blocked(by: first))
    }

    func test_start_isNotBlockedBySettledOrDifferentlyNamedSources() {
        let first = makeModel("first")
        let second = makeModel("second")
        let other = makeModel("other", filename: "other.gguf")

        var failed = runningTable(first)
        failed.finish(first.id, .failed("network"), isInstalled: false)
        XCTAssertEqual(failed.start(second, isInstalled: false), .started)

        var cancelled = runningTable(first)
        cancelled.finish(first.id, .cancelled, isInstalled: false)
        XCTAssertEqual(cancelled.start(second, isInstalled: false), .started)

        var differentFile = runningTable(first)
        XCTAssertEqual(differentFile.start(other, isInstalled: false), .started)
    }

    // MARK: - pause and cancel requests

    func test_requestPause_onlyAppliesToARunningTransfer() {
        let model = makeModel("a")
        var empty = ModelTransferTable()
        XCTAssertFalse(empty.requestPause(model.id))
        XCTAssertNil(empty.displayState(for: model.id))

        var paused = pausedTable(model)
        let before = paused
        XCTAssertFalse(paused.requestPause(model.id))
        XCTAssertEqual(paused, before)

        var running = runningTable(model)
        XCTAssertTrue(running.requestPause(model.id))
        XCTAssertEqual(running.stopIntent(for: model.id), .pause)
        XCTAssertTrue(running.isRunning(model.id), "The transfer keeps running until its backend actually stops")
    }

    func test_cancelOutranksPauseInEitherOrder() {
        let model = makeModel("a")

        var cancelFirst = runningTable(model)
        XCTAssertTrue(cancelFirst.requestCancel(model.id))
        XCTAssertTrue(cancelFirst.requestPause(model.id))
        XCTAssertEqual(cancelFirst.stopIntent(for: model.id), .cancel)

        var pauseFirst = runningTable(model)
        XCTAssertTrue(pauseFirst.requestPause(model.id))
        XCTAssertTrue(pauseFirst.requestCancel(model.id))
        XCTAssertEqual(pauseFirst.stopIntent(for: model.id), .cancel)
    }

    func test_requestCancel_dropsTheResumeDataOfAResumedRun() {
        let model = makeModel("a")
        var table = pausedTable(model, resumeData: resumeData)
        XCTAssertEqual(table.start(model, isInstalled: false), .started)

        XCTAssertTrue(table.requestCancel(model.id))
        XCTAssertNil(table.resumeData(for: model.id))
    }

    func test_requestCancel_reportsWhenNothingIsRunning() {
        let model = makeModel("a")
        var paused = pausedTable(model)
        XCTAssertFalse(paused.requestCancel(model.id))
        XCTAssertEqual(paused.displayState(for: model.id), .paused(progress: 0.4))
    }

    func test_cancelInactive_settlesToWhatIsOnDisk() {
        let model = makeModel("a")

        var paused = pausedTable(model, resumeData: resumeData)
        paused.cancelInactive(model, isInstalled: false)
        XCTAssertEqual(paused.displayState(for: model.id), .idle)
        XCTAssertNil(paused.conflictingTransfer(for: makeModel("b")))

        var installed = pausedTable(model)
        installed.cancelInactive(model, isInstalled: true)
        XCTAssertEqual(installed.displayState(for: model.id), .downloaded)

        var neverStarted = ModelTransferTable()
        neverStarted.cancelInactive(model, isInstalled: false)
        XCTAssertEqual(neverStarted.displayState(for: model.id), .idle)
    }

    // MARK: - progress

    func test_updateProgress_keepsTheStopIntentAndIgnoresSettledTransfers() {
        let model = makeModel("a")
        var table = runningTable(model)
        XCTAssertTrue(table.requestPause(model.id))

        table.updateProgress(model.id, progress: 0.5, speedFormatted: "1MiB", etaFormatted: "9s")
        XCTAssertEqual(
            table.displayState(for: model.id),
            .downloading(progress: 0.5, speedFormatted: "1MiB", etaFormatted: "9s")
        )
        XCTAssertEqual(table.stopIntent(for: model.id), .pause)

        table.finish(model.id, .completed, isInstalled: true)
        table.updateProgress(model.id, progress: 0.9)
        XCTAssertEqual(table.displayState(for: model.id), .downloaded, "A late progress callback must not repaint a finished row")
    }

    // MARK: - finish

    func test_finish_completed() {
        let model = makeModel("a")
        var table = runningTable(model)
        table.finish(model.id, .completed, isInstalled: true)

        XCTAssertEqual(table.displayState(for: model.id), .downloaded)
        XCTAssertFalse(table.isRunning(model.id))
    }

    func test_finish_pausedKeepsClampedProgressAndPrefersNewResumeData() {
        let model = makeModel("a")
        var table = pausedTable(model, resumeData: resumeData)
        XCTAssertEqual(table.start(model, isInstalled: false), .started)
        table.updateProgress(model.id, progress: 1.7)
        let newer = Data("newer".utf8)

        table.finish(model.id, .paused(resumeData: newer), isInstalled: false)

        XCTAssertEqual(table.displayState(for: model.id), .paused(progress: 1))
        XCTAssertEqual(table.start(model, isInstalled: false), .started)
        XCTAssertEqual(table.resumeData(for: model.id), newer)
    }

    func test_finish_pausedWithoutNewResumeDataKeepsTheDataTheRunStartedFrom() {
        let model = makeModel("a")
        var table = pausedTable(model, resumeData: resumeData)
        XCTAssertEqual(table.start(model, isInstalled: false), .started)

        table.finish(model.id, .paused(resumeData: nil), isInstalled: false)

        XCTAssertEqual(table.start(model, isInstalled: false), .started)
        XCTAssertEqual(table.resumeData(for: model.id), resumeData)
    }

    func test_finish_cancelledSettlesToWhatIsOnDiskAndReleasesTheDestination() {
        let first = makeModel("first")
        let second = makeModel("second")

        var table = runningTable(first)
        table.finish(first.id, .cancelled, isInstalled: false)
        XCTAssertEqual(table.displayState(for: first.id), .idle)
        XCTAssertNil(table.conflictingTransfer(for: second))

        var installed = runningTable(first)
        installed.finish(first.id, .cancelled, isInstalled: true)
        XCTAssertEqual(installed.displayState(for: first.id), .downloaded)
    }

    func test_finish_failedKeepsTheMessageAndDropsResumeData() {
        let model = makeModel("a")
        var table = pausedTable(model, resumeData: resumeData)
        XCTAssertEqual(table.start(model, isInstalled: false), .started)

        table.finish(model.id, .failed("disk full"), isInstalled: false)

        XCTAssertEqual(table.displayState(for: model.id), .failed("disk full"))
        XCTAssertEqual(table.start(model, isInstalled: false), .started)
        XCTAssertNil(table.resumeData(for: model.id))
    }

    func test_finish_ignoresATransferThatIsNotRunning() {
        let model = makeModel("a")
        var table = pausedTable(model)
        let before = table

        table.finish(model.id, .completed, isInstalled: true)

        XCTAssertEqual(table, before)
    }

    // MARK: - refresh

    func test_refresh_catalogRowsFollowTheDisk() {
        let catalogModel = makeModel("catalog", filename: "catalog.gguf")
        var table = ModelTransferTable()

        table.refresh(catalog: [catalogModel]) { _ in false }
        XCTAssertNil(table.displayState(for: catalogModel.id), "An absent catalog model needs no row")

        table.refresh(catalog: [catalogModel]) { $0 == "catalog.gguf" }
        XCTAssertEqual(table.displayState(for: catalogModel.id), .downloaded)

        table.refresh(catalog: [catalogModel]) { _ in false }
        XCTAssertEqual(table.displayState(for: catalogModel.id), .idle)
    }

    func test_refresh_neverTouchesRunningOrPausedTransfers() {
        let catalogModel = makeModel("catalog", filename: "catalog.gguf")
        let dynamicModel = makeModel("dynamic", filename: "dynamic.gguf")

        for isInstalled in [true, false] {
            var running = ModelTransferTable()
            XCTAssertEqual(running.start(catalogModel, isInstalled: false), .started)
            XCTAssertEqual(running.start(dynamicModel, isInstalled: false), .started)
            let runningBefore = running
            running.refresh(catalog: [catalogModel]) { _ in isInstalled }
            XCTAssertEqual(running, runningBefore)

            var paused = running
            paused.finish(catalogModel.id, .paused(resumeData: nil), isInstalled: false)
            paused.finish(dynamicModel.id, .paused(resumeData: resumeData), isInstalled: false)
            let pausedBefore = paused
            paused.refresh(catalog: [catalogModel]) { _ in isInstalled }
            XCTAssertEqual(paused, pausedBefore)
        }
    }

    func test_refresh_failedRowsKeepTheirMessageUntilTheFileAppears() {
        let catalogModel = makeModel("catalog", filename: "catalog.gguf")
        let dynamicModel = makeModel("dynamic", filename: "dynamic.gguf")
        var table = ModelTransferTable()
        for model in [catalogModel, dynamicModel] {
            XCTAssertEqual(table.start(model, isInstalled: false), .started)
            table.finish(model.id, .failed("network"), isInstalled: false)
        }

        table.refresh(catalog: [catalogModel]) { _ in false }
        XCTAssertEqual(table.displayState(for: catalogModel.id), .failed("network"))
        XCTAssertEqual(table.displayState(for: dynamicModel.id), .failed("network"))

        table.refresh(catalog: [catalogModel]) { _ in true }
        XCTAssertEqual(table.displayState(for: catalogModel.id), .downloaded)
        XCTAssertEqual(table.displayState(for: dynamicModel.id), .downloaded)
    }

    func test_refresh_dropsDynamicRowsWhoseFileIsGone() {
        let dynamicModel = makeModel("dynamic", filename: "dynamic.gguf")
        var table = runningTable(dynamicModel)
        table.finish(dynamicModel.id, .completed, isInstalled: true)

        table.refresh(catalog: []) { _ in true }
        XCTAssertEqual(table.displayState(for: dynamicModel.id), .downloaded)

        table.refresh(catalog: []) { _ in false }
        XCTAssertNil(table.displayState(for: dynamicModel.id))
    }

    func test_refresh_dropsDynamicRowsThatHaveNoSourceMetadata() {
        let dynamicModel = makeModel("dynamic", filename: "dynamic.gguf")

        var installedShortcut = ModelTransferTable()
        XCTAssertEqual(installedShortcut.start(dynamicModel, isInstalled: true), .alreadyInstalled)
        installedShortcut.refresh(catalog: []) { _ in true }
        XCTAssertNil(installedShortcut.displayState(for: dynamicModel.id))

        var cancelled = runningTable(dynamicModel)
        cancelled.finish(dynamicModel.id, .cancelled, isInstalled: false)
        cancelled.refresh(catalog: []) { _ in false }
        XCTAssertNil(cancelled.displayState(for: dynamicModel.id))
    }

    func test_displayStates_mirrorEveryRow() {
        let first = makeModel("first", filename: "first.gguf")
        let second = makeModel("second", filename: "second.gguf")
        var table = runningTable(first)
        XCTAssertEqual(table.start(second, isInstalled: true), .alreadyInstalled)

        XCTAssertEqual(table.displayStates, [first.id: .downloading(progress: nil), second.id: .downloaded])
    }
}
