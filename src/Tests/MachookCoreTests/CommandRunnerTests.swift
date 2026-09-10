import XCTest
@testable import MachookCore

/// These spawn real shells. Each test builds its own `CommandRunner` so
/// the concurrency budget of one test cannot leak into another.
final class CommandRunnerTests: XCTestCase {
    private func makeConfig(
        maxOutputKB: Int = 1024,
        maxConcurrentRuns: Int = 4,
        keepRequestFiles: Bool = false
    ) -> AppConfig {
        var config = AppConfig.default
        // Not a login shell in tests: sourcing the developer's profile is
        // slow and can print banners into stderr.
        config.loginShell = false
        config.maxOutputKB = maxOutputKB
        config.maxConcurrentRuns = maxConcurrentRuns
        config.keepRequestFiles = keepRequestFiles
        return config
    }

    private func makeEnvelope(body: String = "{}") -> RequestEnvelope {
        RequestEnvelope(
            source: "test",
            method: "POST",
            path: "/test",
            query: ["q": "1"],
            headers: ["content-type": "application/json"],
            body: Data(body.utf8)
        )
    }

    func testStdoutIsCapturedOnSuccess() async throws {
        let result = try await CommandRunner().run(
            rule: EndpointRule(path: "/echo", command: "echo hello"),
            envelope: makeEnvelope(),
            config: makeConfig()
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertFalse(result.timedOut)
    }

    func testNonZeroExitIsReportedWithStderr() async throws {
        let result = try await CommandRunner().run(
            rule: EndpointRule(path: "/fail", command: "echo boom >&2; exit 3"),
            envelope: makeEnvelope(),
            config: makeConfig()
        )
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderrText.contains("boom"))
    }

    /// The envelope is the only channel into the command, so a script must
    /// be able to read it, and the payload must arrive byte-for-byte.
    func testEnvelopeFileIsReadableByTheCommand() async throws {
        let result = try await CommandRunner().run(
            rule: EndpointRule(path: "/read", command: "/bin/cat {{request}}"),
            envelope: makeEnvelope(body: "{\"users\":[{\"id\":42}]}"),
            config: makeConfig()
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdoutText.contains("\"id\" : 42"))
        XCTAssertTrue(result.stdoutText.contains("\"path\" : \"/test\""))
        XCTAssertTrue(result.stdoutText.contains("\"source\" : \"test\""))
    }

    /// The whole point of passing data as a file: a payload full of shell
    /// metacharacters is inert.
    func testShellMetacharactersInPayloadDoNotExecute() async throws {
        let marker = "/tmp/machook-pwned-\(UUID().uuidString.prefix(8))"
        let payload = "{\"name\": \"; touch \(marker) #\"}"

        let result = try await CommandRunner().run(
            rule: EndpointRule(path: "/inject", command: "/bin/cat {{request}}"),
            envelope: makeEnvelope(body: payload),
            config: makeConfig()
        )

        XCTAssertEqual(result.exitCode, 0)
        // Delivered as data...
        XCTAssertTrue(result.stdoutText.contains("touch \(marker)"))
        // ...and not as a command.
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "payload was executed by the shell")
    }

    func testRequestFileEnvironmentVariableMatchesTheEnvelope() async throws {
        let result = try await CommandRunner().run(
            rule: EndpointRule(path: "/env", command: "echo $MACHOOK_REQUEST_FILE"),
            envelope: makeEnvelope(),
            config: makeConfig()
        )
        let reported = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(reported.hasSuffix(".json"))
        XCTAssertTrue(reported.contains("machook/requests"))
        // Cleaned up once the command exited.
        XCTAssertFalse(FileManager.default.fileExists(atPath: reported))
    }

    func testKeepRequestFilesLeavesTheEnvelopeOnDisk() async throws {
        let result = try await CommandRunner().run(
            rule: EndpointRule(path: "/keep", command: "echo $MACHOOK_REQUEST_FILE"),
            envelope: makeEnvelope(),
            config: makeConfig(keepRequestFiles: true)
        )
        let path = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: path)
    }

    /// A command that reads stdin must not hang: stdin is /dev/null, not
    /// an open pipe nobody writes to.
    func testStdinIsClosedSoReadingCommandsDoNotHang() async throws {
        let result = try await CommandRunner().run(
            rule: EndpointRule(path: "/cat", command: "/bin/cat", timeoutSeconds: 5),
            envelope: makeEnvelope(),
            config: makeConfig()
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertLessThan(result.durationMs, 3000)
    }

    func testTimeoutKillsTheCommand() async throws {
        let result = try await CommandRunner().run(
            rule: EndpointRule(path: "/slow", command: "sleep 10", timeoutSeconds: 1),
            envelope: makeEnvelope(),
            config: makeConfig()
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertGreaterThanOrEqual(result.durationMs, 900)
        XCTAssertLessThan(result.durationMs, 6000)
    }

    func testOutputIsCappedButCommandStillCompletes() async throws {
        let result = try await CommandRunner().run(
            rule: EndpointRule(
                path: "/loud",
                command: "/usr/bin/awk 'BEGIN{for(i=0;i<10000;i++)printf \"x\"}'"
            ),
            envelope: makeEnvelope(),
            config: makeConfig(maxOutputKB: 1)
        )
        XCTAssertEqual(result.exitCode, 0, "the command must run to completion even when we discard its output")
        XCTAssertEqual(result.stdout.count, 1024)
        XCTAssertTrue(result.stdoutTruncated)
    }

    func testWorkingDirectoryIsHonored() async throws {
        let result = try await CommandRunner().run(
            rule: EndpointRule(path: "/pwd", command: "pwd", workingDirectory: "/usr"),
            envelope: makeEnvelope(),
            config: makeConfig()
        )
        XCTAssertEqual(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "/usr")
    }

    func testConcurrencyLimitRejectsExtraWork() async throws {
        let runner = CommandRunner()
        let config = makeConfig(maxConcurrentRuns: 1)
        let slow = EndpointRule(path: "/slow", command: "sleep 2", timeoutSeconds: 10)

        // Built outside the Task so the closure doesn't capture `self`.
        let envelope = makeEnvelope()
        let first = Task { try await runner.run(rule: slow, envelope: envelope, config: config) }
        // Give the first run time to claim the only slot.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(runner.activeCount, 1)

        do {
            _ = try await runner.run(
                rule: EndpointRule(path: "/quick", command: "echo hi"),
                envelope: makeEnvelope(),
                config: config
            )
            XCTFail("expected the second run to be rejected")
        } catch CommandRunError.atCapacity(let limit) {
            XCTAssertEqual(limit, 1)
        }

        _ = try? await first.value
        XCTAssertEqual(runner.activeCount, 0)
    }

    func testUnsupportedPlaceholderFailsBeforeSpawning() async {
        do {
            _ = try await CommandRunner().run(
                rule: EndpointRule(path: "/bad", command: "run.sh {{request.body.id}}"),
                envelope: makeEnvelope(),
                config: makeConfig()
            )
            XCTFail("expected a template error")
        } catch CommandRunError.badTemplate {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
