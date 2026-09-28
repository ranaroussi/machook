import Foundation

/// What actually became of a run.
///
/// `statusCode` alone cannot answer this. An async run produces two
/// records, and in both of them the HTTP status the caller received is
/// `201` — so a `504` on an async completion would read as though the
/// caller had been told the request failed, when in fact it already had
/// its answer. The outcome is what distinguishes "we accepted this" from
/// "it later finished", "it later failed", and "we killed it".
public enum RunOutcome: String, Codable, Sendable {
    /// Async: the caller already got `201 Created`; the command is still running.
    case accepted
    /// The command ran and exited 0.
    case succeeded
    /// The command ran and exited non-zero.
    case failed
    /// The command was killed by the endpoint's wall-clock limit.
    case timedOut
    /// The command never ran: no concurrency slot, bad template, envelope
    /// write failure, or spawn failure.
    case rejected

    /// Best-effort label for records written before this field existed.
    static func inferred(async: Bool, timedOut: Bool, statusCode: Int, exitCode: Int32) -> RunOutcome {
        if timedOut { return .timedOut }
        if exitCode == 0 { return .succeeded }
        // An accepted acknowledgement is the one record with no process
        // behind it: nothing ran, so there is no exit status to report.
        if async && statusCode == 201 && exitCode == -1 { return .accepted }
        return .failed
    }

    /// Short label for the menu bar and Settings.
    public var label: String {
        switch self {
        case .accepted: return "accepted"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .timedOut: return "timed out"
        case .rejected: return "not run"
        }
    }

    /// False for the acknowledgement, which precedes the real result.
    public var isTerminal: Bool { self != .accepted }
}

/// One line of the persistent execution log.
///
/// The in-memory `ExecutionLog` is reset on relaunch. This store is not:
/// it writes JSON lines to `~/Library/Logs/machook/executions.jsonl` so
/// async runs and their eventual outcomes remain inspectable after the
/// fact. The file is rotated when it crosses 10 MB.
public struct ExecutionRecord: Codable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let source: String
    public let label: String
    /// The HTTP status this run produced. For an async run that is `201`
    /// in both the acknowledgement and the completion record: it is what
    /// the caller was actually told. Read `outcome` for the result.
    public let statusCode: Int
    public let exitCode: Int32
    public let durationMs: Int
    public let stdout: String
    public let stderr: String
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let async: Bool
    public let timedOut: Bool
    public let outcome: RunOutcome

    public init(
        id: String,
        timestamp: Date,
        source: String,
        label: String,
        statusCode: Int,
        exitCode: Int32,
        durationMs: Int,
        stdout: String,
        stderr: String,
        stdoutTruncated: Bool,
        stderrTruncated: Bool,
        async: Bool,
        timedOut: Bool,
        outcome: RunOutcome
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.label = label
        self.statusCode = statusCode
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.async = async
        self.timedOut = timedOut
        self.outcome = outcome
    }

    /// Hand-written because `outcome` arrived after the field was already
    /// being written to disk: v0.2.0 and earlier lines have no such key,
    /// and a log you cannot read back is worse than no log at all.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        source = try c.decode(String.self, forKey: .source)
        label = try c.decode(String.self, forKey: .label)
        statusCode = try c.decode(Int.self, forKey: .statusCode)
        exitCode = try c.decode(Int32.self, forKey: .exitCode)
        durationMs = try c.decode(Int.self, forKey: .durationMs)
        stdout = try c.decode(String.self, forKey: .stdout)
        stderr = try c.decode(String.self, forKey: .stderr)
        stdoutTruncated = try c.decode(Bool.self, forKey: .stdoutTruncated)
        stderrTruncated = try c.decode(Bool.self, forKey: .stderrTruncated)
        async = try c.decode(Bool.self, forKey: .async)
        timedOut = try c.decode(Bool.self, forKey: .timedOut)
        outcome = try c.decodeIfPresent(RunOutcome.self, forKey: .outcome)
            ?? RunOutcome.inferred(
                async: async,
                timedOut: timedOut,
                statusCode: statusCode,
                exitCode: exitCode
            )
    }
}

public final class ExecutionLogStore: @unchecked Sendable {
    public static let shared = ExecutionLogStore()

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private var logDirectory: URL
    private var logFile: URL
    private let maxLogSizeBytes = 10 * 1024 * 1024

    private init() {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        logDirectory = library.appendingPathComponent("Logs/machook", isDirectory: true)
        logFile = logDirectory.appendingPathComponent("executions.jsonl")
        try? fileManager.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public var logFilePath: String { lock.lock(); defer { lock.unlock() }; return logFile.path }

    /// Redirects the shared store to a different directory. Used only
    /// by tests so they do not pollute the user's real execution log.
    internal func setDirectoryForTesting(_ directory: URL) {
        lock.lock()
        logDirectory = directory
        logFile = directory.appendingPathComponent("executions.jsonl")
        lock.unlock()
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Restores the default log directory.
    internal func resetDirectoryForTesting() {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        setDirectoryForTesting(library.appendingPathComponent("Logs/machook", isDirectory: true))
    }

    /// Append one record, rotating the log first if it has grown too large.
    public func append(_ record: ExecutionRecord) {
        lock.lock(); defer { lock.unlock() }

        rotateIfNeeded()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(record) else { return }
        line.append(contentsOf: "\n".utf8)

        if fileManager.fileExists(atPath: logFile.path),
           let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(line)
            handle.closeFile()
        } else {
            try? line.write(to: logFile, options: .atomic)
        }
    }

    /// Read the most recent records, newest last.
    public func readRecent(maxEntries: Int = 100) -> [ExecutionRecord] {
        lock.lock(); defer { lock.unlock() }

        guard fileManager.fileExists(atPath: logFile.path),
              let data = try? Data(contentsOf: logFile) else { return [] }

        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var records: [ExecutionRecord] = []
        records.reserveCapacity(min(maxEntries, lines.count))
        for line in lines.suffix(maxEntries) {
            if let record = try? decoder.decode(ExecutionRecord.self, from: Data(line)) {
                records.append(record)
            }
        }
        return records
    }

    private func rotateIfNeeded() {
        guard fileManager.fileExists(atPath: logFile.path),
              let attrs = try? fileManager.attributesOfItem(atPath: logFile.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > maxLogSizeBytes else { return }

        let rotated = logDirectory.appendingPathComponent("executions.jsonl.1")
        try? fileManager.removeItem(at: rotated)
        try? fileManager.moveItem(at: logFile, to: rotated)
    }
}
