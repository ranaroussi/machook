import Foundation

/// Persistent, append-only record of every command Machook runs.
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
    public let statusCode: Int
    public let exitCode: Int32
    public let durationMs: Int
    public let stdout: String
    public let stderr: String
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let async: Bool
    public let timedOut: Bool

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
        timedOut: Bool
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
