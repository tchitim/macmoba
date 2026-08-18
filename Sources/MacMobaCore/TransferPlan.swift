// Deciding what a two-pane transfer actually does, and what to ask about.
//
// Kept away from the UI and from any socket because the interesting parts are
// decisions, not I/O: which selected items become jobs, which of them already
// exist at the far end, and what an answer to one overwrite prompt means for
// the files after it. All of that is testable by inspection.

import Foundation

public enum TransferDirection: Sendable, Equatable {
    case upload
    case download

    public var verb: String {
        switch self {
        case .upload: return "Upload"
        case .download: return "Download"
        }
    }
}

/// One thing to move. A directory is a single job: the transfer of its
/// contents is the client's business, not this file's.
public struct TransferJob: Sendable, Equatable, Identifiable {
    public var name: String
    public var sourcePath: String
    public var destinationPath: String
    public var isDirectory: Bool
    public var size: UInt64

    public var id: String { destinationPath }

    public init(name: String, sourcePath: String, destinationPath: String,
                isDirectory: Bool, size: UInt64 = 0) {
        self.name = name
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.isDirectory = isDirectory
        self.size = size
    }
}

/// What the user said about one file that already exists at the destination.
public enum TransferAnswer: Sendable, Equatable {
    case overwrite
    case skip
    /// Overwrite this one and every later conflict without asking again.
    case overwriteAll
    /// Skip this one and every later conflict without asking again.
    case skipAll
    /// Abandon the rest of the transfer, keeping whatever already finished.
    case cancel
}

/// Walks a list of jobs, stopping at each one that would overwrite something.
///
/// Deliberately a state machine rather than a callback: the prompt is a SwiftUI
/// alert, so the answer arrives on a later run loop turn, and the sequence has
/// to survive being suspended between every step.
public final class TransferPlan {
    public enum Step: Sendable, Equatable {
        /// Go ahead with this job — nothing in the way, or the user said so.
        case transfer(TransferJob)
        /// Something with this name is already there. Ask, then call `answer`.
        case ask(TransferJob)
        case finished
    }

    public private(set) var jobs: [TransferJob]
    /// Names already present at the destination directory.
    private let existing: Set<String>
    private var index = 0
    /// Set once "…all" or "cancel" is chosen; every later conflict uses it.
    private var blanket: TransferAnswer?
    /// The job waiting on an answer, so `answer` cannot be applied to the
    /// wrong one if the UI calls it late.
    private var pending: TransferJob?
    /// A job the user has just approved. It has to be handed back explicitly:
    /// answering "overwrite" only records the decision, and without this the
    /// loop walked straight past the file it had just been given permission
    /// to write.
    private var approved: TransferJob?

    public private(set) var skipped: [TransferJob] = []
    public private(set) var cancelled = false

    public init(jobs: [TransferJob], existingAtDestination: Set<String>) {
        self.jobs = jobs
        self.existing = existingAtDestination
    }

    /// How many jobs will actually be attempted if every remaining conflict is
    /// answered "overwrite". Used to show a total before starting.
    public var conflictCount: Int {
        jobs.filter { existing.contains($0.name) }.count
    }

    public func nextStep() -> Step {
        if cancelled { return .finished }
        // A just-answered job goes first, before anything new is considered.
        if let approved {
            self.approved = nil
            return .transfer(approved)
        }
        // A pending question has to be answered before anything else moves.
        if let pending { return .ask(pending) }

        while index < jobs.count {
            let job = jobs[index]
            guard existing.contains(job.name) else {
                index += 1
                return .transfer(job)
            }
            switch blanket {
            case .overwriteAll:
                index += 1
                return .transfer(job)
            case .skipAll:
                index += 1
                skipped.append(job)
                continue
            default:
                pending = job
                return .ask(job)
            }
        }
        return .finished
    }

    /// Answer the question `nextStep` last asked. Ignored when nothing is
    /// pending, so a duplicate tap on an alert button cannot consume the answer
    /// meant for the following file.
    public func answer(_ answer: TransferAnswer) {
        guard let job = pending else { return }
        pending = nil
        // Past this job either way; what differs is whether it gets written.
        index += 1
        switch answer {
        case .overwrite:
            approved = job
        case .overwriteAll:
            blanket = .overwriteAll
            approved = job
        case .skip:
            skipped.append(job)
        case .skipAll:
            blanket = .skipAll
            skipped.append(job)
        case .cancel:
            cancelled = true
        }
    }
}

public enum TransferPlanner {
    /// Turn a selection into jobs.
    ///
    /// Anything selected but no longer listed is dropped rather than guessed
    /// at — a stale selection after a refresh should transfer nothing, not
    /// something with the same name that happens to be there now.
    public static func jobs(selectedNames: Set<String>,
                            from items: [SFTPItem],
                            sourceDirectory: String,
                            destinationDirectory: String) -> [TransferJob] {
        items
            .filter { selectedNames.contains($0.name) }
            // Symlinks are not followed: copying one would silently duplicate
            // whatever it points at, which may be a whole tree or a device.
            .filter { !$0.isSymlink }
            .map { item in
                TransferJob(name: item.name,
                            sourcePath: FTPProtocol.join(sourceDirectory, item.name),
                            destinationPath: FTPProtocol.join(destinationDirectory, item.name),
                            isDirectory: item.isDirectory,
                            size: item.size)
            }
            // Stable, and folders first so a tree lands before the files that
            // might otherwise fill the transfer list ahead of it.
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
