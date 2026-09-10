import Foundation
import Hummingbird
import HTTPTypes
import MCP

/// The local HTTP server cloudflared points at.
///
///   GET  /health   liveness, the only unauthenticated route
///   GET  /status   tunnel state, endpoint count, active runs
///   POST /mcp      MCP JSON-RPC; every endpoint is a tool
///   *   /**        endpoint dispatch: path → command
///
/// Endpoints are resolved against the live config on every request rather
/// than registered as routes at boot, so adding one in Settings takes
/// effect on the next request with no restart.
public final class LocalAPIServer: @unchecked Sendable {
    private let ports: [Int]
    private weak var tunnel: TunnelManager?
    private var task: Task<Void, Error>?

    /// The port that actually bound, or nil while nothing has.
    ///
    /// Does double duty: it separates "this port was taken, try the next
    /// one" from "the server we had been serving traffic on fell over"
    /// (the loop exits on any success, so a non-nil value can only mean
    /// the latter), and it lets `/status` report the port serving requests
    /// instead of the one in Settings.
    private final class BoundPort: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int?
        func set(_ port: Int) { lock.lock(); value = port; lock.unlock() }
        var current: Int? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// `ports` is tried in order, and the first one that binds wins.
    public init(ports: [Int], tunnel: TunnelManager) {
        self.ports = ports.isEmpty ? [AppConfig.default.localAPIPort] : ports
        self.tunnel = tunnel
    }

    /// `onBound` fires with the port that actually bound, which is not
    /// necessarily the first choice. Anything that needs to point at this
    /// server — the tunnel, above all — has to wait for it rather than
    /// assume the configured port.
    public func start(onBound: @escaping @Sendable (Int) -> Void = { _ in }) {
        let ports = self.ports
        let tunnel = self.tunnel

        task = Task.detached {
            let bound = BoundPort()
            let router = Router()
            router.add(middleware: BearerAuthMiddleware())

            router.get("/health") { _, _ -> Response in
                Self.json(["ok": true])
            }

            router.get("/status") { _, _ -> Response in
                let config = AppConfigStore.shared.current
                let enabled = config.endpoints.filter(\.enabled).count
                return Self.json([
                    "ok": true,
                    "version": Self.versionString(),
                    "tunnel_url": tunnel?.publicURL ?? "",
                    "tunnel_running": tunnel?.isRunning ?? false,
                    // The bound port first: a caller needs the port that is
                    // serving, which is not always the configured one.
                    "local_api_port": bound.current ?? config.localAPIPort,
                    "configured_api_port": config.localAPIPort,
                    "endpoints_total": config.endpoints.count,
                    "endpoints_enabled": enabled,
                    "mcp_enabled": config.mcpEnabled,
                    "mcp_tools": config.mcpTools().count,
                    "active_runs": CommandRunner.shared.activeCount
                ])
            }

            // MCP over HTTP. Every request gets an isolated SDK Server and
            // transport: sharing one Server leaks initialization state
            // between independent clients and fails the second one.
            router.post("/mcp") { req, _ -> Response in
                guard AppConfigStore.shared.current.mcpEnabled else {
                    return Self.problem(.notFound, "MCP is disabled in Settings")
                }
                let body = try await req.body.collect(upTo: 1_048_576)
                let mcpRequest = Self.makeMCPRequest(req: req, body: Data(buffer: body))
                let mcpResponse = await MCPService.handleStatelessHTTPRequest(mcpRequest)
                return Self.makeHummingbirdResponse(from: mcpResponse)
            }

            // Endpoint dispatch. Registered per method so a path that
            // exists but rejects the verb can answer 405 instead of 404.
            let methods: [HTTPRequest.Method] = [.get, .post, .put, .patch, .delete]
            for method in methods {
                router.on("/**", method: method) { req, _ -> Response in
                    await Self.dispatch(req)
                }
            }

            for (index, port) in ports.enumerated() {
                let isLastCandidate = index == ports.index(before: ports.endIndex)

                let app = Application(
                    router: router,
                    configuration: .init(address: .hostname("127.0.0.1", port: port)),
                    onServerRunning: { _ in
                        bound.set(port)
                        Log.api.info("listening on 127.0.0.1:\(port)")
                        ServerStatus.report(listening: true, port: port)
                        onBound(port)
                    }
                )

                Log.api.info("starting listener on 127.0.0.1:\(port)")
                do {
                    try await app.runService()
                    // Returning without an error means an orderly shutdown.
                    ServerStatus.report(listening: false, port: port)
                    return
                } catch is CancellationError {
                    Log.api.info("listener on port \(port) stopped")
                    ServerStatus.report(listening: false, port: port)
                    return
                } catch {
                    // Only move ports when we never got this one. Retrying
                    // after the server has served traffic would silently
                    // relocate the address the tunnel and every configured
                    // webhook sender are pointing at.
                    if bound.current == nil, !isLastCandidate, Self.isPortUnavailable(error) {
                        Log.api.notice("port \(port) unavailable, trying \(ports[index + 1])")
                        continue
                    }
                    let detail = Self.describeListenerFailure(error, triedPorts: ports)
                    Log.api.error("listener failed: \(detail, privacy: .public)")
                    ServerStatus.report(listening: false, port: port, error: detail)
                    throw error
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        ServerStatus.report(listening: false, port: ports.first ?? 0)
    }

    private static func isPortUnavailable(_ error: Error) -> Bool {
        let text = String(describing: error)
        return text.contains("Address already in use") || text.contains("errno: 48")
    }

    /// NIO reports a busy port as a bare `errno 48`, which tells a user
    /// nothing. Name the actual conflict, every port that was tried, and
    /// the fix.
    private static func describeListenerFailure(_ error: Error, triedPorts: [Int]) -> String {
        let text = String(describing: error)
        let list = triedPorts.map(String.init).joined(separator: " and ")
        let plural = triedPorts.count > 1
        if isPortUnavailable(error) {
            return plural
                ? "Ports \(list) are both in use by other apps — choose a different port in Settings."
                : "Port \(list) is already in use by another app — choose a different port in Settings."
        }
        if text.contains("Permission denied") || text.contains("errno: 13") {
            return "Port \(list) needs elevated privileges — choose a port above 1024 in Settings."
        }
        return "HTTP server stopped: \(text)"
    }

    // MARK: - Dispatch

    private static func dispatch(_ req: Request) async -> Response {
        let config = AppConfigStore.shared.current
        let path = EndpointRule.normalizePath(req.uri.path)
        let method = req.method.rawValue.uppercased()

        guard let rule = config.rule(forPath: path) else {
            if config.anyRule(forPath: path) != nil {
                Log.api.notice("request for disabled endpoint \(path, privacy: .public)")
                return problem(.serviceUnavailable, "Endpoint \(path) is disabled")
            }
            return problem(.notFound, "No endpoint configured for \(path)")
        }

        guard rule.accepts(method: method) else {
            let allowed = rule.methods.joined(separator: ", ")
            return problem(.methodNotAllowed, "\(path) accepts \(allowed)")
        }

        // A rule can be saved and later broken by its surroundings (a
        // working directory that got deleted, say), so re-check rather
        // than handing a doomed command to the shell.
        if let invalid = rule.validationError() {
            Log.api.error("endpoint \(path, privacy: .public) misconfigured: \(invalid, privacy: .public)")
            return problem(.internalServerError, "Endpoint misconfigured: \(invalid)")
        }

        let maxBody = max(1, config.maxBodyMB) * 1_048_576
        let body: Data
        do {
            body = Data(buffer: try await req.body.collect(upTo: maxBody))
        } catch {
            return problem(.contentTooLarge, "Request body exceeds \(config.maxBodyMB) MB")
        }

        var query: [String: String] = [:]
        for (key, value) in req.uri.queryParameters {
            query[String(key)] = String(value)
        }

        var headers: [String: String] = [:]
        for field in req.headers {
            let name = field.name.canonicalName
            // Never stage our own bearer token into a file on disk; the
            // script has no use for it and it would be written on every
            // single request.
            if name == "authorization" { continue }
            headers[name] = field.value
        }

        let envelope = RequestEnvelope(
            source: "http",
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        )

        do {
            let result = try await CommandRunner.shared.run(rule: rule, envelope: envelope, config: config)
            return response(for: result, label: path, source: "http")
        } catch let error as CommandRunError {
            let status: HTTPResponse.Status
            switch error {
            case .atCapacity:         status = .serviceUnavailable
            case .badTemplate:        status = .internalServerError
            case .envelopeWriteFailed: status = .internalServerError
            case .spawnFailed:        status = .internalServerError
            }
            let message = error.errorDescription ?? "Command failed to run"
            Log.api.error("\(path, privacy: .public): \(message, privacy: .public)")
            ExecutionLog.post(
                source: "http",
                label: path,
                statusCode: Int(status.code),
                exitCode: -1,
                durationMs: 0,
                output: message
            )
            return problem(status, message)
        } catch {
            let message = error.localizedDescription
            Log.api.error("\(path, privacy: .public): \(message, privacy: .public)")
            return problem(.internalServerError, message)
        }
    }

    /// Maps a finished command onto an HTTP response.
    ///
    /// stdout is the response body on success. When a command succeeds
    /// silently (`say hi` prints nothing) an empty 200 tells the caller
    /// very little, so we substitute a small JSON summary.
    static func response(for result: CommandResult, label: String, source: String) -> Response {
        let status: HTTPResponse.Status
        var payload: Data
        var contentType: String

        if result.timedOut {
            status = .gatewayTimeout
            payload = errorPayload(
                "Command timed out after \(result.durationMs) ms",
                extra: ["exit_code": Int(result.exitCode), "stderr": result.stderrText]
            )
            contentType = "application/json"
        } else if result.exitCode != 0 {
            status = .internalServerError
            let detail = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
            payload = errorPayload(
                "Command exited \(result.exitCode)",
                extra: ["exit_code": Int(result.exitCode), "stderr": detail]
            )
            contentType = "application/json"
        } else if result.stdout.isEmpty {
            status = .ok
            payload = (try? JSONSerialization.data(withJSONObject: [
                "ok": true,
                "exit_code": Int(result.exitCode),
                "duration_ms": result.durationMs
            ])) ?? Data("{\"ok\":true}".utf8)
            contentType = "application/json"
        } else {
            status = .ok
            payload = result.stdout
            contentType = sniffContentType(result.stdout)
        }

        Log.api.info("\(label, privacy: .public) → \(status.code, privacy: .public) in \(result.durationMs, privacy: .public)ms")
        ExecutionLog.post(
            source: source,
            label: label,
            statusCode: Int(status.code),
            exitCode: result.exitCode,
            durationMs: result.durationMs,
            output: result.stdoutText.isEmpty ? result.stderrText : result.stdoutText
        )

        var response = Response(status: status, body: .init(byteBuffer: ByteBuffer(data: payload)))
        response.headers[.contentType] = contentType
        setHeader(&response, "X-Machook-Exit-Code", String(result.exitCode))
        setHeader(&response, "X-Machook-Duration-Ms", String(result.durationMs))
        if result.stdoutTruncated || result.stderrTruncated {
            setHeader(&response, "X-Machook-Truncated", "true")
        }
        return response
    }

    /// JSON when the bytes parse as JSON, UTF-8 text when they are text,
    /// otherwise octet-stream. Scripts that echo JSON get the right
    /// header without having to declare anything.
    static func sniffContentType(_ data: Data) -> String {
        let trimmed = data.drop(while: { $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 })
        if let first = trimmed.first, first == 0x7B || first == 0x5B,
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return "application/json"
        }
        if String(data: data, encoding: .utf8) != nil {
            return "text/plain; charset=utf-8"
        }
        return "application/octet-stream"
    }

    // MARK: - Response helpers

    static func problem(_ status: HTTPResponse.Status, _ message: String) -> Response {
        var response = Response(
            status: status,
            body: .init(byteBuffer: ByteBuffer(data: errorPayload(message)))
        )
        response.headers[.contentType] = "application/json"
        return response
    }

    private static func errorPayload(_ message: String, extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = ["error": message]
        for (key, value) in extra { object[key] = value }
        // Messages quote endpoint paths, and `"\/deploy"` reads like a typo.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
            ?? Data("{\"error\":\"unknown\"}".utf8)
    }

    private static func json(_ object: Any) -> Response {
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        var response = Response(status: .ok, body: .init(byteBuffer: ByteBuffer(data: data)))
        response.headers[.contentType] = "application/json"
        return response
    }

    private static func setHeader(_ response: inout Response, _ name: String, _ value: String) {
        guard let field = HTTPField.Name(name) else { return }
        response.headers[field] = value
    }

    static func versionString() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    // MARK: - MCP adapters

    /// Hummingbird `Request` → MCP `HTTPRequest`. The SDK transport reads
    /// method, headers, body, and path only.
    private static func makeMCPRequest(req: Request, body: Data) -> MCP.HTTPRequest {
        var headers: [String: String] = [:]
        for field in req.headers {
            headers[field.name.canonicalName] = field.value
        }
        return MCP.HTTPRequest(
            method: req.method.rawValue,
            headers: headers,
            body: body.isEmpty ? nil : body,
            path: "/mcp"
        )
    }

    private static func makeHummingbirdResponse(from mcpResponse: MCP.HTTPResponse) -> Response {
        var headers = HTTPFields()
        for (name, value) in mcpResponse.headers {
            if let fieldName = HTTPField.Name(name) {
                headers[fieldName] = value
            }
        }
        let body: ResponseBody
        if let data = mcpResponse.bodyData {
            body = .init(byteBuffer: ByteBuffer(data: data))
        } else {
            body = .init()
        }
        return Response(
            status: .init(code: mcpResponse.statusCode),
            headers: headers,
            body: body
        )
    }
}

/// Enforces `Authorization: Bearer <token>` on everything except
/// `/health`.
///
/// Unknown paths are rejected before routing, so an unauthenticated
/// caller cannot probe which endpoints exist. An empty token disables
/// auth for localhost development; the Settings window refuses to pair
/// that with an enabled tunnel.
struct BearerAuthMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if request.uri.path == "/health" {
            return try await next(request, context)
        }

        let configured = AppConfigStore.shared.current.bearerToken
        if configured.isEmpty {
            return try await next(request, context)
        }
        guard
            let header = request.headers[.authorization],
            Self.constantTimeEqual(header, "Bearer \(configured)")
        else {
            Log.api.notice("rejected unauthorized \(request.method.rawValue, privacy: .public) \(request.uri.path, privacy: .public)")
            var response = LocalAPIServer.problem(
                .unauthorized,
                "Missing or invalid bearer token. Send: Authorization: Bearer <token>"
            )
            response.headers[.wwwAuthenticate] = "Bearer"
            return response
        }
        return try await next(request, context)
    }

    /// This one header is all that stands between the public internet and a
    /// shell, so compare it without an early exit on the first differing
    /// byte. Length still leaks, which no comparison can avoid.
    private static func constantTimeEqual(_ provided: String, _ expected: String) -> Bool {
        let a = Array(provided.utf8)
        let b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
