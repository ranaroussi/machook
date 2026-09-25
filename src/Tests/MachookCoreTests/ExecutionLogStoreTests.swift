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

    private func makeRecord(id: String, statusCode: Int = 200, async: Bool = false) -> ExecutionRecord {
        ExecutionRecord(
            id: id,
            timestamp: Date(),
            source: "test",
            label: "/test",
            statusCode: statusCode,
            exitCode: 0,
            durationMs: 42,
            stdout: "out",
            stderr: "err",
            stdoutTruncated: false,
            stderrTruncated: false,
            async: async,
            timedOut: false
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
        ExecutionLogStore.shared.append(makeRecord(id: "hydrate", statusCode: 201, async: true))

        let log = ExecutionLog()
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.id, "hydrate")
        XCTAssertEqual(log.entries.first?.statusCode, 201)
        XCTAssertTrue(log.entries.first?.async ?? false)
    }
}
