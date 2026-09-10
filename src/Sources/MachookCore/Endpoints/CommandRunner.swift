import Foundation

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let durationMs: Int
    public let timedOut: Bool
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    public var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
}

public enum CommandRunError: Error, LocalizedError {
    /// All `maxConcurrentRuns` slots are busy.
    case atCapacity(limit: Int)
    case envelopeWriteFailed(String)
    case badTemplate(String)
    case spawnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .atCapacity(let limit):
            return "Too many commands already running (limit \(limit))"
        case .envelopeWriteFailed(let detail):
            return "Could not stage the request file: \(detail)"
        case .badTemplate(let detail):
            return detail
        case .spawnFailed(let detail):
            return "Could not start the command: \(detail)"
        }
    }
}

/// Runs an endpoint's command against a staged request envelope.
///
/// One execution path serves both HTTP requests and MCP tool calls, so
/// there is a single place where a command can be spawned, and a single
/// place enforcing the timeout, the output cap, and the concurrency limit.
public final class CommandRunner: @unchecked Sendable {
    public static let shared = CommandRunner()

    /// Concurrency budget. The lock lives behind synchronous methods
    /// because `NSLock.lock()` is unavailable directly inside an async
    /// function — the compiler cannot see that we never suspend while
    /// holding it.
    private final class SlotCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0

        func acquire(limit: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if active >= limit { return false }
            active += 1
            return true
        }

        func release() {
            lock.lock(); active -= 1; lock.unlock()
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return active
        }
    }

    private let slots = SlotCounter()

    public init() {}

    public var activeCount: Int { slots.count }

    public func run(
        rule: EndpointRule,
        envelope: RequestEnvelope,
        config: AppConfig
    ) async throws -> CommandResult {
        let limit = max(1, config.maxConcurrentRuns)
        guard slots.acquire(limit: limit) else {
            throw CommandRunError.atCapacity(limit: limit)
        }
        defer { slots.release() }

        let envelopeURL: URL
        do {
            envelopeURL = try envelope.write()
        } catch {
            throw CommandRunError.envelopeWriteFailed(error.localizedDescription)
        }
        defer {
            if config.keepRequestFiles {
                Log.runner.info("kept request envelope at \(envelopeURL.path, privacy: .public)")
            } else {
                try? FileManager.default.removeItem(at: envelopeURL)
            }
        }

        let command: String
        do {
            command = try CommandTemplate.render(rule.command, envelopePath: envelopeURL.path)
        } catch {
            throw CommandRunError.badTemplate(error.localizedDescription)
        }

        let shell = config.shellPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = ExecutionRequest(
            command: command,
            shell: shell.isEmpty ? "/bin/zsh" : shell,
            loginShell: config.loginShell,
            workingDirectory: rule.effectiveWorkingDirectory,
            envelopeFile: envelopeURL.path,
            outputCap: max(1, config.maxOutputKB) * 1024,
            timeoutSeconds: max(1, rule.timeoutSeconds)
        )

        Log.runner.info("run \(rule.path, privacy: .public) via \(request.shell, privacy: .public)")

        // The whole spawn/drain/wait dance is blocking, so it goes to a
        // background queue and the result comes back over a continuation.
        // Keeping it inside one closure also keeps the non-Sendable
        // Process and its pipes from crossing an isolation boundary.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.execute(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Execution

    private struct ExecutionRequest: Sendable {
        let command: String
        let shell: String
        let loginShell: Bool
        let workingDirectory: String
        let envelopeFile: String
        let outputCap: Int
        let timeoutSeconds: Int
    }

    /// Mutable state shared with the drain threads and the timeout timer.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var _stdout = Data()
        private var _stderr = Data()
        private var _stdoutTruncated = false
        private var _stderrTruncated = false
        private var _timedOut = false

        func setStdout(_ data: Data, truncated: Bool) {
            lock.lock(); _stdout = data; _stdoutTruncated = truncated; lock.unlock()
        }
        func setStderr(_ data: Data, truncated: Bool) {
            lock.lock(); _stderr = data; _stderrTruncated = truncated; lock.unlock()
        }
        func markTimedOut() {
            lock.lock(); _timedOut = true; lock.unlock()
        }
        var snapshot: (stdout: Data, stderr: Data, stdoutTruncated: Bool, stderrTruncated: Bool, timedOut: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (_stdout, _stderr, _stdoutTruncated, _stderrTruncated, _timedOut)
        }
    }

    /// Carries a non-Sendable value into a dispatch closure. Safe here
    /// because each boxed handle is touched by exactly one thread.
    private final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private static func execute(_ request: ExecutionRequest) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.shell)
        process.arguments = [request.loginShell ? "-lc" : "-c", request.command]
        process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory)

        var environment = ProcessInfo.processInfo.environment
        environment["MACHOOK_REQUEST_FILE"] = request.envelopeFile
        process.environment = environment

        // /dev/null rather than a pipe we never write to: a script that
        // calls `cat` or `read` would otherwise block forever waiting on
        // an open descriptor that never receives anything.
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let started = Date()
        do {
            try process.run()
        } catch {
            throw CommandRunError.spawnFailed(error.localizedDescription)
        }

        let state = RunState()
        let group = DispatchGroup()
        let outBox = Box(outPipe.fileHandleForReading)
        let errBox = Box(errPipe.fileHandleForReading)
        let cap = request.outputCap

        // Both pipes must drain concurrently. Reading stdout to EOF first
        // deadlocks as soon as a chatty script fills the 64 KB stderr
        // buffer, because the child then blocks on write and never exits.
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            let (data, truncated) = drain(outBox.value, cap: cap)
            state.setStdout(data, truncated: truncated)
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            let (data, truncated) = drain(errBox.value, cap: cap)
            state.setStderr(data, truncated: truncated)
        }

        // Timeout: SIGTERM, then SIGKILL two seconds later.
        //
        // Only the direct child is signalled. `zsh -c` execs a single
        // simple command, so for the common one-command template that
        // child *is* the script; a script that backgrounds work of its
        // own can still leave a grandchild running after a timeout. We
        // deliberately do not `kill(-pid)`: Process gives the child our
        // own process group, so a negative pid would signal Machook too.
        let processBox = Box(process)
        let killer = DispatchWorkItem {
            guard processBox.value.isRunning else { return }
            state.markTimedOut()
            Log.runner.notice("command exceeded \(request.timeoutSeconds, privacy: .public)s, sending SIGTERM")
            processBox.value.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if processBox.value.isRunning {
                    Log.runner.notice("command ignored SIGTERM, sending SIGKILL")
                    kill(processBox.value.processIdentifier, SIGKILL)
                }
            }
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(request.timeoutSeconds),
            execute: killer
        )

        process.waitUntilExit()
        killer.cancel()

        // Normally both pipes hit EOF the moment the child exits. A
        // grandchild that inherited stdout keeps them open, so cap the
        // wait rather than letting one stray background process hang the
        // HTTP request forever.
        if group.wait(timeout: .now() + 3) == .timedOut {
            Log.runner.notice("output pipes still open after exit; returning partial output")
        }

        let snapshot = state.snapshot
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: snapshot.stdout,
            stderr: snapshot.stderr,
            durationMs: durationMs,
            timedOut: snapshot.timedOut,
            stdoutTruncated: snapshot.stdoutTruncated,
            stderrTruncated: snapshot.stderrTruncated
        )
    }

    /// Reads to EOF, keeping at most `cap` bytes but continuing to drain
    /// past it. Stopping early would leave the child blocked on a full
    /// pipe and it would never exit.
    private static func drain(_ handle: FileHandle, cap: Int) -> (Data, Bool) {
        var collected = Data()
        var truncated = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if collected.count >= cap {
                truncated = true
                continue
            }
            let room = cap - collected.count
            if chunk.count <= room {
                collected.append(chunk)
            } else {
                collected.append(chunk.prefix(room))
                truncated = true
            }
        }
        return (collected, truncated)
    }
}
