import Foundation
import MCP

/// MCP surface over HTTP: every enabled endpoint is a tool.
///
/// The tool catalog is built from the live config on each `tools/list`,
/// so an endpoint added in Settings shows up without a restart, and a
/// `tools/call` funnels into the same `CommandRunner` the HTTP dispatcher
/// uses. The only difference between the two surfaces is what lands in
/// the envelope: HTTP contributes a real body, headers, and query, while
/// a tool call contributes its arguments as the body and marks `source`
/// as `"mcp"`.
public final class MCPService {
    private let server: Server
    private let transport: any Transport

    init(transport: any Transport) {
        self.transport = transport
        self.server = Server(
            name: "machook",
            version: LocalAPIServer.versionString(),
            capabilities: .init(tools: .init(listChanged: false))
        )
    }

    /// Processes one request with completely isolated protocol state.
    ///
    /// A `StatelessHTTPServerTransport` does not isolate the SDK `Server`
    /// attached to it, so reusing one `Server` makes a second client fail
    /// its initialize with "Server is already initialized". Building both
    /// per request also permits concurrent clients.
    public static func handleStatelessHTTPRequest(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.disabled,
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
            ])
        )
        let service = MCPService(transport: transport)

        do {
            try await service.start()
            let response = await transport.handleRequest(request)
            await service.stop()
            return response
        } catch {
            await service.stop()
            return .error(
                statusCode: 500,
                .internalError("Failed to process MCP request: \(error.localizedDescription)")
            )
        }
    }

    private func start() async throws {
        await registerHandlers()
        try await server.start(transport: transport)
    }

    private func stop() async {
        await server.stop()
    }

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.currentTools())
        }
        await server.withMethodHandler(CallTool.self) { params in
            await Self.call(params)
        }
    }

    // MARK: - Tool catalog

    /// Read-only endpoints get explicit hints so clients running under a
    /// non-interactive approval policy stop gating them. Everything else
    /// is left unannotated on purpose: MCP treats an unannotated tool as
    /// potentially destructive, which is exactly right for a tool that
    /// runs an arbitrary shell command.
    private static let readOnlyAnnotations = Tool.Annotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    static func currentTools() -> [Tool] {
        AppConfigStore.shared.current.mcpTools().map { pair in
            let annotations: Tool.Annotations = pair.rule.mcpReadOnly ? readOnlyAnnotations : nil
            return Tool(
                name: pair.toolName,
                description: toolDescription(for: pair.rule),
                inputSchema: inputSchema(for: pair.rule),
                annotations: annotations
            )
        }
    }

    private static func toolDescription(for rule: EndpointRule) -> String {
        let written = rule.toolDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !written.isEmpty { return written }
        return "Runs the Machook endpoint \(rule.path) on this Mac. "
            + "Arguments are delivered to the command as the request body."
    }

    /// A user-supplied JSON Schema when there is one, otherwise a
    /// freeform object. Freeform is the honest default: the command is an
    /// opaque script, so we cannot infer its parameters, and letting the
    /// model pass any JSON keeps the tool usable.
    private static func inputSchema(for rule: EndpointRule) -> Value {
        let raw = rule.mcpInputSchema.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty,
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Value.self, from: data) {
            return decoded
        }
        return .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(true)
        ])
    }

    // MARK: - Tool invocation

    static func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        let config = AppConfigStore.shared.current
        guard let match = config.mcpTools().first(where: { $0.toolName == params.name }) else {
            return error("Unknown tool: \(params.name)")
        }
        let rule = match.rule

        var body = Data()
        if let arguments = params.arguments, !arguments.isEmpty {
            body = (try? JSONEncoder().encode(arguments)) ?? Data()
        }

        let envelope = RequestEnvelope(
            source: "mcp",
            method: "MCP",
            path: rule.path,
            body: body
        )

        do {
            let result = try await CommandRunner.shared.run(rule: rule, envelope: envelope, config: config)
            let statusCode = result.succeeded ? 200 : (result.timedOut ? 504 : 500)
            ExecutionLog.post(
                source: "mcp",
                label: match.toolName,
                statusCode: statusCode,
                exitCode: result.exitCode,
                durationMs: result.durationMs,
                output: result.stdoutText.isEmpty ? result.stderrText : result.stdoutText
            )
            Log.mcp.info("tool \(match.toolName, privacy: .public) → \(statusCode, privacy: .public) in \(result.durationMs, privacy: .public)ms")

            if result.timedOut {
                return error("Command timed out after \(result.durationMs) ms")
            }
            if result.exitCode != 0 {
                let detail = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
                return error("Command exited \(result.exitCode)\n\(detail)")
            }
            let text = result.stdoutText.isEmpty
                ? "{\"ok\":true,\"exit_code\":0,\"duration_ms\":\(result.durationMs)}"
                : result.stdoutText
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let runError as CommandRunError {
            let message = runError.errorDescription ?? "Command failed to run"
            Log.mcp.error("tool \(match.toolName, privacy: .public): \(message, privacy: .public)")
            ExecutionLog.post(
                source: "mcp",
                label: match.toolName,
                statusCode: 500,
                exitCode: -1,
                durationMs: 0,
                output: message
            )
            return error(message)
        } catch {
            return self.error(error.localizedDescription)
        }
    }

    private static func error(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}
