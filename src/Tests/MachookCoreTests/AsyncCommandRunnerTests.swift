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
        XCTAssertEqual(record?.statusCode, 200)
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
        XCTAssertEqual(record?.statusCode, 500)
        XCTAssertEqual(record?.exitCode, 7)
        XCTAssertTrue(record?.stderr.contains("bad") ?? false)
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
