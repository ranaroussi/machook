import XCTest
@testable import MachookCore

final class ExecutionLogStoreTests: XCTestCase {
    private var tempLogDir: URL!

    override func setUp() {
        super.setUp()
        tempLogDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("machook-log-tests-\(UUID().uuidString)", isDirectory: true)
        ExecutionLogStore.shared.setDirectoryForTesting(tempLogDir)
    }

    override func tearDown() {
        ExecutionLogStore.shared.resetDirectoryForTesting()
        try? FileManager.default.removeItem(at: tempLogDir)
        super.tearDown()
    }

    private func makeRecord(
        id: String,
        statusCode: Int = 200,
        async: Bool = false,
        exitCode: Int32 = 0,
        timedOut: Bool = false,
        outcome: RunOutcome = .succeeded
    ) -> ExecutionRecord {
        ExecutionRecord(
            id: id,
            timestamp: Date(),
            source: "test",
            label: "/test",
            statusCode: statusCode,
            exitCode: exitCode,
            durationMs: 42,
            stdout: "out",
            stderr: "err",
            stdoutTruncated: false,
            stderrTruncated: false,
            async: async,
            timedOut: timedOut,
            outcome: outcome
        )
    }

    func testAppendAndReadRecent() {
        ExecutionLogStore.shared.append(makeRecord(id: "a"))
        ExecutionLogStore.shared.append(makeRecord(id: "b", statusCode: 500))
        ExecutionLogStore.shared.append(makeRecord(id: "c", async: true))

        let recent = ExecutionLogStore.shared.readRecent(maxEntries: 10)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent[0].id, "a")
        XCTAssertEqual(recent[1].id, "b")
        XCTAssertEqual(recent[2].id, "c")
        XCTAssertEqual(recent[1].statusCode, 500)
        XCTAssertTrue(recent[2].async)
    }

    func testReadRecentRespectsMaxEntries() {
        for i in 0..<20 {
            ExecutionLogStore.shared.append(makeRecord(id: "\(i)"))
        }
        let recent = ExecutionLogStore.shared.readRecent(maxEntries: 5)
        XCTAssertEqual(recent.count, 5)
        XCTAssertEqual(recent.last?.id, "19")
    }

    @MainActor
    func testExecutionLogHydratesFromStore() {
        ExecutionLogStore.shared.append(makeRecord(id: "hydrate", statusCode: 201, async: true, exitCode: -1, outcome: .accepted))

        let log = ExecutionLog()
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.id, "hydrate")
        XCTAssertEqual(log.entries.first?.statusCode, 201)
        XCTAssertTrue(log.entries.first?.async ?? false)
        XCTAssertEqual(log.entries.first?.outcome, .accepted)
        XCTAssertTrue(log.entries.first?.awaitingResult ?? false)
    }

    /// Lines written by v0.2.0 and earlier carry no `outcome` key. A log you
    /// cannot read back is worse than no log, so the field is optional on
    /// decode and inferred from what the older records do have.
    func testDecodesLegacyLinesWithoutOutcome() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func decode(_ body: String) throws -> ExecutionRecord {
            try decoder.decode(ExecutionRecord.self, from: Data(body.utf8))
        }

        let accepted = try decode("""
        {"id":"a","timestamp":"2026-09-28T08:57:11Z","source":"http",
         "label":"/x","statusCode":201,"exitCode":-1,"durationMs":0,
         "stdout":"Accepted run a","stderr":"","stdoutTruncated":false,
         "stderrTruncated":false,"async":true,"timedOut":false}
        """)
        XCTAssertEqual(accepted.outcome, .accepted)

        let timed = try decode("""
        {"id":"b","timestamp":"2026-09-28T08:57:41Z","source":"http",
         "label":"/x","statusCode":504,"exitCode":143,"durationMs":30472,
         "stdout":"","stderr":"","stdoutTruncated":false,
         "stderrTruncated":false,"async":true,"timedOut":true}
        """)
        XCTAssertEqual(timed.outcome, .timedOut)

        let done = try decode("""
        {"id":"c","timestamp":"2026-09-28T08:57:41Z","source":"http",
         "label":"/x","statusCode":200,"exitCode":0,"durationMs":12,
         "stdout":"ok","stderr":"","stdoutTruncated":false,
         "stderrTruncated":false,"async":true,"timedOut":false}
        """)
        XCTAssertEqual(done.outcome, .succeeded)

        let bad = try decode("""
        {"id":"d","timestamp":"2026-09-28T08:57:41Z","source":"http",
         "label":"/x","statusCode":500,"exitCode":7,"durationMs":12,
         "stdout":"","stderr":"bad","stdoutTruncated":false,
         "stderrTruncated":false,"async":true,"timedOut":false}
        """)
        XCTAssertEqual(bad.outcome, .failed)
    }

    func testOutcomeRoundTrips() throws {
        let record = makeRecord(id: "r", async: true, exitCode: -1, outcome: .accepted)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ExecutionRecord.self, from: encoder.encode(record))
        XCTAssertEqual(decoded.outcome, .accepted)
    }
}
