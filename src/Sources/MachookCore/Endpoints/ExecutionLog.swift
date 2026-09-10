import Foundation

/// In-memory ring buffer of recent runs, feeding the menu bar and the
/// Settings window.
///
/// Deliberately not persisted: unlike the outbound relay this replaced,
/// there is nothing to retry and nothing to reconcile after a crash, so a
/// SQLite table would be storage for its own sake. Restarting Machook
/// starts a fresh log.
@MainActor
public final class ExecutionLog: ObservableObject {
    public static let shared = ExecutionLog()

    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let at: Date
        public let source: String
        public let label: String
        public let statusCode: Int
        public let exitCode: Int32
        public let durationMs: Int
        public let outputHead: String

        public var succeeded: Bool { statusCode < 400 }
    }

    private let capacity = 100

    @Published public private(set) var entries: [Entry] = []

    public func record(
        source: String,
        label: String,
        statusCode: Int,
        exitCode: Int32,
        durationMs: Int,
        output: String
    ) {
        let head = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""

        entries.insert(
            Entry(
                at: Date(),
                source: source,
                label: label,
                statusCode: statusCode,
                exitCode: exitCode,
                durationMs: durationMs,
                outputHead: String(head.prefix(120))
            ),
            at: 0
        )
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }

    public func clear() {
        entries.removeAll()
    }

    /// Convenience for call sites that are not already on the main actor.
    public nonisolated static func post(
        source: String,
        label: String,
        statusCode: Int,
        exitCode: Int32,
        durationMs: Int,
        output: String
    ) {
        Task { @MainActor in
            ExecutionLog.shared.record(
                source: source,
                label: label,
                statusCode: statusCode,
                exitCode: exitCode,
                durationMs: durationMs,
                output: output
            )
        }
    }
}
