import XCTest
import Darwin
@testable import MachookCore

/// The port fallback exists because a fixed default port is a coin flip on
/// somebody else's Mac, and the old failure mode was a menu bar app that
/// looked healthy and answered nothing. That makes it worth testing against
/// a real occupied port rather than a mock.
final class ListenerFallbackTests: XCTestCase {
    private var occupied: Int32 = -1
    private var server: LocalAPIServer?
    private var tunnel: TunnelManager?

    override func tearDown() {
        server?.stop()
        server = nil
        tunnel = nil
        if occupied >= 0 {
            close(occupied)
            occupied = -1
        }
        // The status object is a singleton shared with the rest of the
        // suite, so leave it clean.
        ServerStatus.report(listening: false, port: 0)
        super.tearDown()
    }

    /// Binds 127.0.0.1 on a kernel-assigned port and starts listening,
    /// returning the socket and the port it claimed. Deliberately without
    /// `SO_REUSEADDR`: a second bind to an actively listening socket must
    /// fail with `EADDRINUSE`, which is the condition under test.
    private func occupyEphemeralPort() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("socket() unavailable in this environment") }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            close(fd)
            throw XCTSkip("could not bind a loopback port in this environment")
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw XCTSkip("getsockname() failed")
        }
        return (fd, Int(UInt16(bigEndian: actual.sin_port)))
    }

    /// A port nothing is listening on. Found by claiming and immediately
    /// releasing one, so the number is plausible rather than guessed.
    private func probablyFreePort() throws -> Int {
        let (fd, port) = try occupyEphemeralPort()
        close(fd)
        return port
    }

    private final class PortBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int?
        func set(_ port: Int) { lock.lock(); value = port; lock.unlock() }
        var current: Int? { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testListenerMovesToTheFallbackWhenThePrimaryIsTaken() async throws {
        let (fd, taken) = try occupyEphemeralPort()
        occupied = fd
        let fallback = try probablyFreePort()
        XCTAssertNotEqual(taken, fallback)

        let tunnel = TunnelManager()
        self.tunnel = tunnel
        let server = LocalAPIServer(ports: [taken, fallback], tunnel: tunnel)
        self.server = server

        let box = PortBox()
        let bound = expectation(description: "listener bound to a port")
        server.start { port in
            box.set(port)
            bound.fulfill()
        }
        await fulfillment(of: [bound], timeout: 15)

        XCTAssertEqual(box.current, fallback, "should have skipped the occupied port")

        // Binding is not the same as serving, so prove it answers. /health
        // is the one unauthenticated route, which keeps this independent of
        // whatever token the host machine has configured.
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(fallback)/health"))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"ok\":true}")

        // `/status` must report the port serving requests, not the port
        // somebody configured — reporting the latter while answering on the
        // former is how a caller ends up debugging the wrong process.
        let statusURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(fallback)/status"))
        var request = URLRequest(url: statusURL)
        let token = AppConfigStore.shared.current.bearerToken
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (statusData, _) = try await URLSession.shared.data(for: request)
        let status = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: statusData) as? [String: Any]
        )
        XCTAssertEqual(status["local_api_port"] as? Int, fallback)
    }

    func testExhaustingEveryCandidateReportsAVisibleError() async throws {
        let (fd, taken) = try occupyEphemeralPort()
        occupied = fd

        let tunnel = TunnelManager()
        self.tunnel = tunnel
        // One candidate, already taken: nowhere to fall back to.
        let server = LocalAPIServer(ports: [taken], tunnel: tunnel)
        self.server = server
        server.start()

        // The failure is reported through a hop to the main actor, so poll
        // briefly rather than assuming it has landed.
        var reported: String?
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            reported = await MainActor.run { ServerStatus.shared.lastError }
            if reported != nil { break }
        }

        let message = try XCTUnwrap(reported, "a failed bind must surface an error")
        XCTAssertTrue(message.contains("\(taken)"), "error should name the port: \(message)")
        XCTAssertTrue(message.contains("in use"), "error should explain the conflict: \(message)")
        let listening = await MainActor.run { ServerStatus.shared.isListening }
        XCTAssertFalse(listening)
    }

    /// A shutdown we asked for is not news, so it must not raise an alarm in
    /// the menu.
    func testRequestedShutdownIsReportedQuietly() async throws {
        // `ServerStatus.report` lands via a hop to the main actor, so another
        // test's teardown can still be in flight. Clear it here and wait,
        // rather than inheriting whatever the suite left behind.
        ServerStatus.report(listening: false, port: 0)
        try await Task.sleep(nanoseconds: 200_000_000)

        LocalAPIServer.reportShutdown(port: 7876, requested: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        let error = await MainActor.run { ServerStatus.shared.lastError }
        XCTAssertNil(error)
    }

    /// A shutdown nobody asked for is the SIGTERM case: the service lifecycle
    /// stops the server, the app keeps running, and the only other symptom is
    /// a menu bar icon that answers nothing.
    func testUnrequestedShutdownSurfacesAnError() async throws {
        LocalAPIServer.reportShutdown(port: 7876, requested: false)
        try await Task.sleep(nanoseconds: 200_000_000)
        let error = await MainActor.run { ServerStatus.shared.lastError }
        let message = try XCTUnwrap(error, "an unrequested shutdown must be visible")
        XCTAssertTrue(message.contains("7876"), "should name the port: \(message)")
        XCTAssertTrue(
            message.lowercased().contains("stopped"),
            "should say what happened: \(message)"
        )
    }
}
