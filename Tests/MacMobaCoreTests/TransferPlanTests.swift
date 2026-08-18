import XCTest

@testable import MacMobaCore

/// The overwrite question is the part of a two-pane transfer that has to be
/// exactly right: answering it for one file must not silently answer it for
/// the next, and "apply to all" must apply to the files still to come and not
/// to the ones already skipped.
final class TransferPlanTests: XCTestCase {
    private func job(_ name: String, isDirectory: Bool = false) -> TransferJob {
        TransferJob(name: name, sourcePath: "/src/\(name)",
                    destinationPath: "/dst/\(name)", isDirectory: isDirectory)
    }

    /// Runs the plan to completion, answering each question from `answers` in
    /// order. Returns the names actually transferred.
    private func run(_ plan: TransferPlan, answering answers: [TransferAnswer]) -> [String] {
        var transferred: [String] = []
        var remaining = answers
        var guardCount = 0
        while true {
            guardCount += 1
            XCTAssertLessThan(guardCount, 1000, "the plan is not making progress")
            switch plan.nextStep() {
            case .transfer(let job):
                transferred.append(job.name)
            case .ask:
                guard !remaining.isEmpty else {
                    XCTFail("asked more questions than there were answers")
                    return transferred
                }
                plan.answer(remaining.removeFirst())
            case .finished:
                XCTAssertTrue(remaining.isEmpty, "not every answer was used")
                return transferred
            }
        }
    }

    func testNoConflictsTransfersEverythingWithoutAsking() {
        let plan = TransferPlan(jobs: [job("a.txt"), job("b.txt")],
                                existingAtDestination: [])
        XCTAssertEqual(run(plan, answering: []), ["a.txt", "b.txt"])
        XCTAssertEqual(plan.conflictCount, 0)
    }

    func testOnlyTheClashingNameIsAskedAbout() {
        let plan = TransferPlan(jobs: [job("a.txt"), job("b.txt"), job("c.txt")],
                                existingAtDestination: ["b.txt"])
        XCTAssertEqual(plan.conflictCount, 1)
        XCTAssertEqual(run(plan, answering: [.overwrite]), ["a.txt", "b.txt", "c.txt"])
    }

    func testSkipLeavesTheDestinationFileAlone() {
        let plan = TransferPlan(jobs: [job("a.txt"), job("b.txt")],
                                existingAtDestination: ["a.txt"])
        XCTAssertEqual(run(plan, answering: [.skip]), ["b.txt"])
        XCTAssertEqual(plan.skipped.map(\.name), ["a.txt"])
    }

    /// One answer per file: three clashes means three questions.
    func testEachConflictIsAskedAboutSeparately() {
        let plan = TransferPlan(jobs: [job("a"), job("b"), job("c")],
                                existingAtDestination: ["a", "b", "c"])
        XCTAssertEqual(run(plan, answering: [.overwrite, .skip, .overwrite]), ["a", "c"])
        XCTAssertEqual(plan.skipped.map(\.name), ["b"])
    }

    func testOverwriteAllAnswersEveryLaterConflict() {
        let plan = TransferPlan(jobs: [job("a"), job("b"), job("c"), job("d")],
                                existingAtDestination: ["a", "b", "c", "d"])
        XCTAssertEqual(run(plan, answering: [.overwriteAll]), ["a", "b", "c", "d"],
                       "one answer should cover all four")
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    func testSkipAllSkipsTheRestButKeepsTheNonClashingOnes() {
        let plan = TransferPlan(
            jobs: [job("a"), job("fresh1"), job("b"), job("fresh2"), job("c")],
            existingAtDestination: ["a", "b", "c"])
        XCTAssertEqual(run(plan, answering: [.skipAll]), ["fresh1", "fresh2"],
                       "files with no conflict must still transfer")
        XCTAssertEqual(plan.skipped.map(\.name), ["a", "b", "c"])
    }

    /// "Apply to all" applies to what is still to come. A file already dealt
    /// with individually keeps the answer it was given.
    func testABlanketAnswerDoesNotRewriteEarlierDecisions() {
        let plan = TransferPlan(jobs: [job("a"), job("b"), job("c")],
                                existingAtDestination: ["a", "b", "c"])
        XCTAssertEqual(run(plan, answering: [.skip, .overwriteAll]), ["b", "c"])
        XCTAssertEqual(plan.skipped.map(\.name), ["a"],
                       "the first file stays skipped even though the rest overwrite")
    }

    func testCancelStopsEverythingAfterIt() {
        let plan = TransferPlan(jobs: [job("a"), job("b"), job("c")],
                                existingAtDestination: ["b"])
        XCTAssertEqual(run(plan, answering: [.cancel]), ["a"],
                       "what already went is kept; nothing after the cancel runs")
        XCTAssertTrue(plan.cancelled)
    }

    /// A double tap on the alert must not consume the next file's answer.
    func testAnsweringTwiceIsIgnoredTheSecondTime() {
        let plan = TransferPlan(jobs: [job("a"), job("b")],
                                existingAtDestination: ["a", "b"])
        guard case .ask = plan.nextStep() else { return XCTFail("expected a question") }
        plan.answer(.overwrite)
        plan.answer(.skipAll)   // stray second tap
        // "a" was already answered; "b" must still be asked about.
        guard case .transfer(let first) = plan.nextStep(), first.name == "a" else {
            return XCTFail("the answered job should transfer")
        }
        guard case .ask(let second) = plan.nextStep(), second.name == "b" else {
            return XCTFail("the stray answer must not have decided b")
        }
    }

    /// The plan must not move on while a question is outstanding, however many
    /// times the UI polls it.
    func testTheSameQuestionIsReturnedUntilAnswered() {
        let plan = TransferPlan(jobs: [job("a"), job("b")], existingAtDestination: ["a"])
        guard case .ask(let first) = plan.nextStep() else { return XCTFail("expected ask") }
        guard case .ask(let again) = plan.nextStep() else { return XCTFail("expected ask") }
        XCTAssertEqual(first, again)
        plan.answer(.skip)
        guard case .transfer(let job) = plan.nextStep(), job.name == "b" else {
            return XCTFail("should move on after the answer")
        }
    }

    func testDirectoriesConflictOnTheirNameToo() {
        let plan = TransferPlan(jobs: [job("stuff", isDirectory: true)],
                                existingAtDestination: ["stuff"])
        XCTAssertEqual(plan.conflictCount, 1)
        XCTAssertEqual(run(plan, answering: [.overwrite]), ["stuff"])
    }

    func testEmptyPlanFinishesImmediately() {
        let plan = TransferPlan(jobs: [], existingAtDestination: ["a"])
        XCTAssertEqual(plan.nextStep(), .finished)
    }
}

final class TransferPlannerTests: XCTestCase {
    private func item(_ name: String, directory: Bool = false, symlink: Bool = false,
                      size: UInt64 = 10) -> SFTPItem {
        var attributes = SFTPAttributes()
        attributes.size = size
        attributes.permissions = symlink ? 0o120777 : (directory ? 0o040755 : 0o100644)
        return SFTPItem(name: name, longname: name, attributes: attributes)
    }

    func testJobsAreBuiltFromTheSelectionOnly() {
        let jobs = TransferPlanner.jobs(
            selectedNames: ["a.txt", "docs"],
            from: [item("a.txt"), item("b.txt"), item("docs", directory: true)],
            sourceDirectory: "/home/tim", destinationDirectory: "/upload")
        XCTAssertEqual(jobs.map(\.name), ["docs", "a.txt"], "folders lead")
        XCTAssertEqual(jobs.first(where: { $0.name == "a.txt" })?.sourcePath, "/home/tim/a.txt")
        XCTAssertEqual(jobs.first(where: { $0.name == "a.txt" })?.destinationPath, "/upload/a.txt")
        XCTAssertTrue(jobs.first(where: { $0.name == "docs" })?.isDirectory ?? false)
    }

    /// A selection left over from before a refresh must not transfer a
    /// different file that now happens to have that name.
    func testNamesNoLongerListedAreDropped() {
        let jobs = TransferPlanner.jobs(
            selectedNames: ["gone.txt", "a.txt"],
            from: [item("a.txt")],
            sourceDirectory: "/src", destinationDirectory: "/dst")
        XCTAssertEqual(jobs.map(\.name), ["a.txt"])
    }

    /// Following a symlink would copy whatever it points at — possibly a whole
    /// tree, possibly a device.
    func testSymlinksAreNotTransferred() {
        let jobs = TransferPlanner.jobs(
            selectedNames: ["link", "real.txt"],
            from: [item("link", symlink: true), item("real.txt")],
            sourceDirectory: "/src", destinationDirectory: "/dst")
        XCTAssertEqual(jobs.map(\.name), ["real.txt"])
    }

    func testRootDirectoryPathsDoNotDoubleUpSlashes() {
        let jobs = TransferPlanner.jobs(
            selectedNames: ["a.txt"], from: [item("a.txt")],
            sourceDirectory: "/", destinationDirectory: "/")
        XCTAssertEqual(jobs.first?.sourcePath, "/a.txt")
        XCTAssertEqual(jobs.first?.destinationPath, "/a.txt")
    }

    func testSizesAreCarriedThroughForProgress() {
        let jobs = TransferPlanner.jobs(
            selectedNames: ["big.bin"], from: [item("big.bin", size: 4096)],
            sourceDirectory: "/src", destinationDirectory: "/dst")
        XCTAssertEqual(jobs.first?.size, 4096)
    }
}
