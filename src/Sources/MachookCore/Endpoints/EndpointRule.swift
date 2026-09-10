import Foundation

/// One endpoint: an HTTP path, the shell command it runs, and how it is
/// surfaced to MCP clients.
///
/// The same rule backs both surfaces. `POST /deploy` over the tunnel and
/// an agent calling the `deploy` tool run the identical command against
/// the identical envelope shape, so there is only one execution path to
/// reason about.
public struct EndpointRule: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID

    /// Normalized request path, always leading-slash, never trailing.
    public var path: String

    /// Shell command template. `{{request}}` becomes the envelope file path.
    public var command: String

    /// Accepted HTTP methods, uppercased. Empty means "any method".
    public var methods: [String]

    public var enabled: Bool

    /// Hard wall-clock limit. On expiry the child gets SIGTERM, then
    /// SIGKILL two seconds later, and the caller sees 504.
    public var timeoutSeconds: Int

    /// Working directory for the command. Empty means the user's home.
    public var workingDirectory: String

    /// Human description. Doubles as the MCP tool description, which is
    /// the text a model reads when deciding whether to call it, so it is
    /// worth writing properly.
    public var toolDescription: String

    /// Whether this endpoint is exposed as an MCP tool. Off makes sense
    /// for provider-driven receivers (a GitHub push hook is not something
    /// an agent should be invoking).
    public var mcpEnabled: Bool

    /// Overrides the tool name. Empty derives it from `path`.
    public var mcpToolName: String

    /// Optional JSON Schema (as text) describing the tool's arguments.
    /// Empty means a freeform object, so a model may pass any JSON and it
    /// lands in the envelope's `body`.
    public var mcpInputSchema: String

    /// Marks the tool read-only for MCP clients. Left off, MCP treats the
    /// tool as potentially destructive, which is the correct default for
    /// an arbitrary shell command — turn it on only for endpoints that
    /// just report something, so they stop being approval-gated.
    public var mcpReadOnly: Bool

    /// Paths owned by the server itself. A user endpoint cannot claim
    /// these, because the built-in route would shadow it.
    public static let reservedPaths: Set<String> = ["/health", "/status", "/mcp"]

    public static let defaultMethods = ["POST"]

    public init(
        id: UUID = UUID(),
        path: String = "",
        command: String = "",
        methods: [String] = EndpointRule.defaultMethods,
        enabled: Bool = true,
        timeoutSeconds: Int = 30,
        workingDirectory: String = "",
        toolDescription: String = "",
        mcpEnabled: Bool = true,
        mcpToolName: String = "",
        mcpInputSchema: String = "",
        mcpReadOnly: Bool = false
    ) {
        self.id = id
        self.path = path
        self.command = command
        self.methods = methods
        self.enabled = enabled
        self.timeoutSeconds = timeoutSeconds
        self.workingDirectory = workingDirectory
        self.toolDescription = toolDescription
        self.mcpEnabled = mcpEnabled
        self.mcpToolName = mcpToolName
        self.mcpInputSchema = mcpInputSchema
        self.mcpReadOnly = mcpReadOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EndpointRule()
        self.id               = (try? c.decode(UUID.self,     forKey: .id))               ?? UUID()
        self.path             = (try? c.decode(String.self,   forKey: .path))             ?? d.path
        self.command          = (try? c.decode(String.self,   forKey: .command))          ?? d.command
        self.methods          = (try? c.decode([String].self, forKey: .methods))          ?? d.methods
        self.enabled          = (try? c.decode(Bool.self,     forKey: .enabled))          ?? d.enabled
        self.timeoutSeconds   = (try? c.decode(Int.self,      forKey: .timeoutSeconds))   ?? d.timeoutSeconds
        self.workingDirectory = (try? c.decode(String.self,   forKey: .workingDirectory)) ?? d.workingDirectory
        self.toolDescription  = (try? c.decode(String.self,   forKey: .toolDescription))  ?? d.toolDescription
        self.mcpEnabled       = (try? c.decode(Bool.self,     forKey: .mcpEnabled))       ?? d.mcpEnabled
        self.mcpToolName      = (try? c.decode(String.self,   forKey: .mcpToolName))      ?? d.mcpToolName
        self.mcpInputSchema   = (try? c.decode(String.self,   forKey: .mcpInputSchema))   ?? d.mcpInputSchema
        self.mcpReadOnly      = (try? c.decode(Bool.self,     forKey: .mcpReadOnly))      ?? d.mcpReadOnly
    }

    /// Case-sensitive method check. An empty `methods` accepts anything.
    public func accepts(method: String) -> Bool {
        methods.isEmpty || methods.contains(method.uppercased())
    }

    public var effectiveWorkingDirectory: String {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return NSHomeDirectory() }
        return (trimmed as NSString).expandingTildeInPath
    }

    // MARK: - Normalization

    /// Coerces user input into a canonical path. Tolerates a pasted full
    /// URL (people copy the tunnel address out of the menu bar), a missing
    /// leading slash, a trailing slash, and a pasted query string.
    public static func normalizePath(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }

        if let schemeRange = s.range(of: "://") {
            let afterScheme = s[schemeRange.upperBound...]
            if let slash = afterScheme.firstIndex(of: "/") {
                s = String(afterScheme[slash...])
            } else {
                return ""
            }
        }
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            s = String(s[s.startIndex..<cut])
        }
        if s.isEmpty { return "" }
        if !s.hasPrefix("/") { s = "/" + s }
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// `/github/push` → `github_push`. MCP tool names are restricted to
    /// `[A-Za-z0-9_-]`, so everything else collapses to a single `_`.
    public static func deriveToolName(fromPath path: String) -> String {
        var out = ""
        var lastWasSeparator = true
        for ch in path {
            let isNameChar = ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_")
            if isNameChar {
                out.append(ch)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                out.append("_")
                lastWasSeparator = true
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        if out.isEmpty { return "endpoint" }
        return String(out.prefix(64))
    }

    /// First problem with this rule, or nil when it is usable. Surfaced
    /// inline in the Settings window and refused at save time.
    public func validationError() -> String? {
        let normalized = Self.normalizePath(path)
        if normalized.isEmpty {
            return "Path is required, e.g. /deploy"
        }
        if Self.reservedPaths.contains(normalized) {
            return "\(normalized) is reserved by Machook itself"
        }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Command is required"
        }
        let unsupported = CommandTemplate.unsupportedPlaceholders(in: command)
        if let first = unsupported.first {
            return "Unsupported placeholder {{\(first)}} — only {{request}} is available"
        }
        if timeoutSeconds < 1 || timeoutSeconds > 3600 {
            return "Timeout must be between 1 and 3600 seconds"
        }
        let schema = mcpInputSchema.trimmingCharacters(in: .whitespacesAndNewlines)
        if !schema.isEmpty {
            guard let data = schema.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  parsed is [String: Any] else {
                return "MCP input schema must be a JSON object"
            }
        }
        if !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: effectiveWorkingDirectory,
                isDirectory: &isDirectory
            )
            if !exists || !isDirectory.boolValue {
                return "Working directory does not exist"
            }
        }
        return nil
    }
}
