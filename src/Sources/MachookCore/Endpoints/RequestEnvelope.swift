import Foundation

/// Everything about one inbound request, in the shape the script sees on
/// disk as `{{request}}`.
///
/// `body` is the parsed JSON when the payload parses, so `jq .body.x.y`
/// works without a second parse step; `body_raw` is always the text as
/// sent, so form-encoded and plain-text payloads survive. Payloads that
/// aren't valid UTF-8 arrive as `body_base64` instead.
public struct RequestEnvelope: Sendable {
    /// `"http"` for a tunnel/localhost request, `"mcp"` for a tool call.
    public let source: String
    public let id: String
    public let receivedAt: Date
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public init(
        source: String,
        id: String = String(UUID().uuidString.prefix(8)).lowercased(),
        receivedAt: Date = Date(),
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.source = source
        self.id = id
        self.receivedAt = receivedAt
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// `FormatStyle` rather than `ISO8601DateFormatter`: the formatter
    /// class is not `Sendable`, so a shared static instance is rejected
    /// under strict concurrency and a per-request instance would be waste.
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "received_at": Self.timestampStyle.format(receivedAt),
            "source": source,
            "method": method,
            "path": path,
            "query": query,
            "headers": headers,
            "body_bytes": body.count
        ]

        if let text = String(data: body, encoding: .utf8) {
            object["body_raw"] = text
            if let parsed = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
                object["body"] = parsed
            } else {
                object["body"] = NSNull()
            }
        } else {
            object["body_base64"] = body.base64EncodedString()
            object["body"] = NSNull()
        }
        return object
    }

    public func serialized() throws -> Data {
        // `withoutEscapingSlashes` keeps paths and URLs readable: this file
        // is meant to be opened and `jq`-ed by hand, and `"\/deploy"` is
        // needless noise.
        try JSONSerialization.data(
            withJSONObject: jsonObject(),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
    }

    /// Per-user temp directory, mode 0700. Deliberately not `/tmp`,
    /// which is world-readable on macOS: webhook payloads routinely
    /// carry API tokens, signatures, and personal data.
    public static func stagingDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("machook", isDirectory: true)
            .appendingPathComponent("requests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    /// Writes the envelope and returns its path. The filename carries a
    /// millisecond timestamp for readability plus the request id, because
    /// a bare timestamp collides when two webhooks land in the same
    /// millisecond and one script would read the other's payload.
    public func write() throws -> URL {
        let dir = try Self.stagingDirectory()
        let millis = Int(receivedAt.timeIntervalSince1970 * 1000)
        let url = dir.appendingPathComponent("\(millis)-\(id).json")
        try serialized().write(to: url, options: .atomic)
        // `.atomic` writes a temp file and renames it, which does not
        // inherit the mode we want, so tighten it afterwards.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    /// Deletes staged envelopes older than `maxAge`. Belt-and-braces for
    /// the case where we were killed between writing a file and the
    /// `defer` that removes it.
    public static func sweepStagingDirectory(olderThan maxAge: TimeInterval = 6 * 3600) {
        guard let dir = try? stagingDirectory() else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)
        var removed = 0
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            if (try? fm.removeItem(at: entry)) != nil { removed += 1 }
        }
        if removed > 0 {
            Log.runner.info("swept \(removed, privacy: .public) stale request envelope(s)")
        }
    }
}
