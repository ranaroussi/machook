import XCTest
@testable import MachookCore

/// Fire-and-forget command execution: the HTTP caller gets 201 immediately
/// and the script finishes in the background, with its result persisted.
final class AsyncCommandRunnerTests: XCTestCase {
    private var tempLogDir: URL!

    override func setUp() {
        super.setUp()
        tempLogDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("machook-tests-\(UUID().uuidString)", isDirectory: true)
        ExecutionLogStore.shared.setDirectoryForTesting(tempLogDir)
    }

    override func tearDown() {
        ExecutionLogStore.shared.resetDirectoryForTesting()
        try? FileManager.default.removeItem(at: tempLogDir)
        super.tearDown()
    }

    private func makeConfig(maxConcurrentRuns: Int = 4) -> AppConfig {
        var config = AppConfig.default
        config.loginShell = false
        config.maxConcurrentRuns = maxConcurrentRuns
        return config
    }

    private func makeEnvelope(path: String = "/async") -> RequestEnvelope {
        RequestEnvelope(
            source: "test",
            method: "POST",
            path: path,
            body: Data("{}".utf8)
        )
    }

    func testAsyncRunReturnsImmediatelyAndFinishesLater() async throws {
        let runner = CommandRunner()
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("machook-async-test-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: marker) }

        // The command sleeps for 1.5s then writes a marker file.
        let rule = EndpointRule(
            path: "/async",
            command: "sleep 1.5 && touch \(marker)",
            async: true
        )

        let start = Date()
        let runID = try await runner.runAsync(
            rule: rule,
            envelope: makeEnvelope(),
            config: makeConfig()
        )
        let elapsed = Date().timeIntervalSince(start)

        // The caller must return well before the command finishes.
        XCTAssertLessThan(elapsed, 0.5, "async call returned too slowly")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "marker should not exist yet")

        // Wait for the background task to finish and verify the log.
        let deadline = Date().addingTimeInterval(5)
        var record: ExecutionRecord?
        while Date() < deadline {
            record = ExecutionLogStore.shared.readRecent(maxEntries: 10)
                .first { $0.id == runID }
            if record != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNotNil(record, "async result was not logged")
        // The caller was told 201; the completion record keeps that status
        // and reports the real result through `outcome`.
        XCTAssertEqual(record?.statusCode, 201)
        XCTAssertEqual(record?.outcome, .succeeded)
        XCTAssertEqual(record?.async, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "command did not finish")
    }

    func testAsyncRunLogsFailure() async throws {
        let runner = CommandRunner()
        let rule = EndpointRule(
            path: "/async-fail",
            command: "echo bad >&2; exit 7",
            async: true
        )

        let runID = try await runner.runAsync(
            rule: rule,
            envelope: makeEnvelope(path: "/async-fail"),
            config: makeConfig()
        )

        let deadline = Date().addingTimeInterval(5)
        var record: ExecutionRecord?
        while Date() < deadline {
            record = ExecutionLogStore.shared.readRecent(maxEntries: 10)
                .first { $0.id == runID }
            if record != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.outcome, .failed)
        XCTAssertEqual(record?.statusCode, 201, "the caller's 201 is what the run's HTTP status was")
        XCTAssertEqual(record?.exitCode, 7)
        XCTAssertTrue(record?.stderr.contains("bad") ?? false)
    }

    /// An async endpoint has already answered its caller, so the wall clock
    /// no longer has anyone to rescue. Killing the command at the endpoint's
    /// timeout would defeat the reason async mode exists: long jobs. This is
    /// the regression that produced a 504 in the log for a run whose caller
    /// had been told 201.
    func testAsyncRunIsNotKilledByTheEndpointTimeout() async throws {
        let runner = CommandRunner()
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("machook-async-notimeout-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: marker) }

        // Timeout of 1s, command that needs about 3s.
        let rule = EndpointRule(
            path: "/async-long",
            command: "sleep 3 && touch \(marker)",
            timeoutSeconds: 1,
            async: true
        )

        let runID = try await runner.runAsync(
            rule: rule,
            envelope: makeEnvelope(path: "/async-long"),
            config: makeConfig()
        )

        let deadline = Date().addingTimeInterval(10)
        var record: ExecutionRecord?
        while Date() < deadline {
            record = ExecutionLogStore.shared.readRecent(maxEntries: 10).first { $0.id == runID }
            if record != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertNotNil(record, "async run was never logged")
        XCTAssertFalse(record?.timedOut ?? true, "async run must not be killed by the endpoint timeout")
        XCTAssertEqual(record?.outcome, .succeeded)
        XCTAssertEqual(record?.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "command was cut short")
    }

    /// The escape hatch still holds: a synchronous run keeps its timeout.
    /// The Settings Test button takes this path even for an async draft, so
    /// the limit must survive outside `runAsync`.
    func testSynchronousRunStillHonoursTheTimeout() async throws {
        let runner = CommandRunner()
        let rule = EndpointRule(
            path: "/sync-long",
            command: "sleep 5",
            timeoutSeconds: 1,
            async: true
        )

        let result = try await runner.run(
            rule: rule,
            envelope: makeEnvelope(path: "/sync-long"),
            config: makeConfig()
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(result.durationMs, 4000, "should have been killed near the 1s limit, not run to completion")
    }

    func testAsyncRunRespectsConcurrencyLimit() async throws {
        let runner = CommandRunner()
        let config = makeConfig(maxConcurrentRuns: 1)
        let slow = EndpointRule(
            path: "/async-slow",
            command: "sleep 2",
            async: true
        )

        let first = try await runner.runAsync(
            rule: slow,
            envelope: makeEnvelope(path: "/async-slow"),
            config: config
        )
        // Give the first run time to claim the only slot.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(runner.activeCount, 1)

        do {
            _ = try await runner.runAsync(
                rule: EndpointRule(path: "/async-quick", command: "echo hi", async: true),
                envelope: makeEnvelope(path: "/async-quick"),
                config: config
            )
            XCTFail("expected the second async run to be rejected")
        } catch CommandRunError.atCapacity(let limit) {
            XCTAssertEqual(limit, 1)
        }

        // Wait for the first run to finish so tearDown is clean.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if ExecutionLogStore.shared.readRecent(maxEntries: 10).first(where: { $0.id == first }) != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
