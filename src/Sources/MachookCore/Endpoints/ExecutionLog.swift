import Foundation

/// In-memory ring buffer of recent runs, feeding the menu bar and the
/// Settings window, backed by a persistent JSON-lines store.
///
/// The persistent store keeps async outcomes and long-running history
/// across relaunches; the in-memory ring keeps the UI fast and avoids
/// loading megabytes of log at startup.
@MainActor
public final class ExecutionLog: ObservableObject {
    public static let shared = ExecutionLog()

    public struct Entry: Identifiable, Sendable {
        public let id: String
        public let at: Date
        public let source: String
        public let label: String
        public let statusCode: Int
        public let exitCode: Int32
        public let durationMs: Int
        public let outputHead: String
        public let async: Bool

        public var succeeded: Bool { statusCode < 400 }
    }

    private let capacity = 100

    @Published public private(set) var entries: [Entry] = []

    public init() {
        // Hydrate the in-memory ring from disk so the menu bar and
        // Settings window show recent history after a relaunch.
        let recent = ExecutionLogStore.shared.readRecent(maxEntries: capacity)
        entries = recent.map { record in
            Entry(
                id: record.id,
                at: record.timestamp,
                source: record.source,
                label: record.label,
                statusCode: record.statusCode,
                exitCode: record.exitCode,
                durationMs: record.durationMs,
                outputHead: Self.head(of: record.stdout, fallback: record.stderr),
                async: record.async
            )
        }
    }

    public func record(
        id: String,
        source: String,
        label: String,
        statusCode: Int,
        exitCode: Int32,
        durationMs: Int,
        output: String,
        stderr: String = "",
        async: Bool = false,
        timedOut: Bool = false,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        let head = Self.head(of: output, fallback: stderr)
        let now = Date()

        entries.insert(
            Entry(
                id: id,
                at: now,
                source: source,
                label: label,
                statusCode: statusCode,
                exitCode: exitCode,
                durationMs: durationMs,
                outputHead: head,
                async: async
            ),
            at: 0
        )
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }

        let record = ExecutionRecord(
            id: id,
            timestamp: now,
            source: source,
            label: label,
            statusCode: statusCode,
            exitCode: exitCode,
            durationMs: durationMs,
            stdout: output,
            stderr: stderr,
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated,
            async: async,
            timedOut: timedOut
        )
        ExecutionLogStore.shared.append(record)
    }

    public func clear() {
        entries.removeAll()
    }

    private static func head(of primary: String, fallback: String) -> String {
        let text = primary.isEmpty ? fallback : primary
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
    }

    /// Convenience for call sites that are not already on the main actor.
    public nonisolated static func post(
        id: String,
        source: String,
        label: String,
        statusCode: Int,
        exitCode: Int32,
        durationMs: Int,
        output: String,
        stderr: String = "",
        async: Bool = false,
        timedOut: Bool = false,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        Task { @MainActor in
            ExecutionLog.shared.record(
                id: id,
                source: source,
                label: label,
                statusCode: statusCode,
                exitCode: exitCode,
                durationMs: durationMs,
                output: output,
                stderr: stderr,
                async: async,
                timedOut: timedOut,
                stdoutTruncated: stdoutTruncated,
                stderrTruncated: stderrTruncated
            )
        }
    }
}
