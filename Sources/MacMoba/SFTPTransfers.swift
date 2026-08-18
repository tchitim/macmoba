// Transfer status tracking + the transfers list at the bottom of the SFTP
// panel: one row per upload/download with progress bar, speed and cancel.

import Foundation
import SwiftUI

@MainActor
final class SFTPTransfer: ObservableObject, Identifiable {
    enum Kind {
        case upload, download
    }

    enum Status: Equatable {
        case running
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let kind: Kind
    /// Top-level item being transferred (file or folder name).
    let name: String
    let startedAt = Date()

    @Published private(set) var currentFile: String?
    @Published private(set) var done: UInt64 = 0
    @Published private(set) var total: UInt64?
    @Published var status: Status = .running

    var task: Task<Void, Never>?
    var underlyingError: Error?

    // Folder transfers report per-file progress; accumulate across files.
    private var baseBytes: UInt64 = 0
    private var lastFileDone: UInt64 = 0
    // Progress fires per 32 KB chunk; throttle @Published churn.
    private var lastPublish = Date.distantPast

    init(kind: Kind, name: String, total: UInt64?) {
        self.kind = kind
        self.name = name
        self.total = total
    }

    var isRunning: Bool { status == .running }

    /// Average bytes/sec since start; nil until it means something.
    var speed: Double? {
        let elapsed = Date().timeIntervalSince(startedAt)
        guard isRunning, elapsed > 0.5, done > 0 else { return nil }
        return Double(done) / elapsed
    }

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    /// Single-file progress callback.
    func updateFile(done newDone: UInt64, total newTotal: UInt64?) {
        throttled {
            self.done = newDone
            if let newTotal { self.total = newTotal }
        }
    }

    /// Folder-transfer progress callback (per current file).
    func updateTree(file: String, fileDone: UInt64) {
        if file != currentFile {
            baseBytes += lastFileDone
            lastFileDone = 0
            currentFile = file
        }
        lastFileDone = fileDone
        throttled { self.done = self.baseBytes + fileDone }
    }

    func markDone() {
        if let total { done = total } else { done = baseBytes + lastFileDone }
        status = .done
    }

    func cancel() {
        task?.cancel()
    }

    private func throttled(_ apply: () -> Void) {
        let now = Date()
        guard now.timeIntervalSince(lastPublish) > 0.05 else { return }
        lastPublish = now
        apply()
    }
}

// MARK: - Views

struct SFTPTransfersView: View {
    @ObservedObject var model: SFTPBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clearFinishedTransfers() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(!model.transfers.contains { !$0.isRunning })
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.transfers.reversed()) { transfer in
                        SFTPTransferRow(transfer: transfer)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 170)
        }
        .background(.bar)
    }
}

struct SFTPTransferRow: View {
    @ObservedObject var transfer: SFTPTransfer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .font(.caption)
                Text(transfer.name)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if transfer.isRunning {
                    Button {
                        transfer.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel transfer")
                }
            }
            if transfer.isRunning {
                if let fraction = transfer.fraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            Text(statusLine)
                .font(.caption2)
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
        .padding(6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private var icon: String {
        switch transfer.status {
        case .running: return transfer.kind == .upload ? "arrow.up.circle" : "arrow.down.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    private var iconColor: Color {
        switch transfer.status {
        case .running: return .accentColor
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private var statusColor: Color {
        if case .failed = transfer.status { return .red }
        return .secondary
    }

    private var statusLine: String {
        switch transfer.status {
        case .running:
            var parts: [String] = []
            if let total = transfer.total {
                parts.append("\(Self.bytes(transfer.done)) of \(Self.bytes(total))")
            } else {
                parts.append(Self.bytes(transfer.done))
            }
            if let speed = transfer.speed {
                parts.append("\(Self.bytes(UInt64(speed)))/s")
            }
            if let file = transfer.currentFile {
                parts.append(file)
            }
            return parts.joined(separator: " · ")
        case .done:
            return "Done · \(Self.bytes(transfer.done))"
        case .failed(let message):
            return "Failed: \(message)"
        case .cancelled:
            return "Cancelled"
        }
    }

    private static func bytes(_ n: UInt64) -> String {
        formatter.string(fromByteCount: Int64(n))
    }

    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}
