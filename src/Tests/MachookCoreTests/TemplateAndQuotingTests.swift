import XCTest
@testable import MachookCore

/// The shell-quoting and template rules are the security boundary of the
/// app, so they get tested directly rather than only through a live
/// request.
final class ShellQuoteTests: XCTestCase {
    func testInertValuePassesThroughUnquoted() {
        XCTAssertEqual(ShellQuote.quote("/tmp/machook/requests/123-abc.json"),
                       "/tmp/machook/requests/123-abc.json")
        XCTAssertEqual(ShellQuote.quote("deploy-site_v2"), "deploy-site_v2")
    }

    func testEmptyStringBecomesEmptyQuotes() {
        XCTAssertEqual(ShellQuote.quote(""), "''")
    }

    func testCommandInjectionIsNeutralized() {
        XCTAssertEqual(ShellQuote.quote("; rm -rf ~"), "'; rm -rf ~'")
        XCTAssertEqual(ShellQuote.quote("$(whoami)"), "'$(whoami)'")
        XCTAssertEqual(ShellQuote.quote("`id`"), "'`id`'")
        XCTAssertEqual(ShellQuote.quote("a && b"), "'a && b'")
        XCTAssertEqual(ShellQuote.quote("x | tee /tmp/out"), "'x | tee /tmp/out'")
    }

    func testEmbeddedSingleQuoteIsEscaped() {
        // 'it'\''s' is the complete POSIX escape: close, escaped quote, reopen.
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
    }

    func testValuesNeedingQuotesBecauseOfZshExpansion() {
        // A leading `=` triggers zsh's =command expansion, and `~` triggers
        // tilde expansion, so neither may take the unquoted fast path.
        XCTAssertEqual(ShellQuote.quote("=ls"), "'=ls'")
        XCTAssertEqual(ShellQuote.quote("~/secrets"), "'~/secrets'")
    }
}

final class CommandTemplateTests: XCTestCase {
    func testRequestPlaceholderIsReplacedAndQuoted() throws {
        let rendered = try CommandTemplate.render(
            "bash runthis.sh {{request}}",
            envelopePath: "/var/folders/x/T/machook/requests/1-a.json"
        )
        XCTAssertEqual(rendered, "bash runthis.sh /var/folders/x/T/machook/requests/1-a.json")
    }

    func testPathWithSpacesIsQuoted() throws {
        let rendered = try CommandTemplate.render(
            "python dothis.py --payload {{request}}",
            envelopePath: "/tmp/my folder/1-a.json"
        )
        XCTAssertEqual(rendered, "python dothis.py --payload '/tmp/my folder/1-a.json'")
    }

    func testWhitespaceInsidePlaceholderIsTolerated() throws {
        let rendered = try CommandTemplate.render("cat {{ request }}", envelopePath: "/tmp/a.json")
        XCTAssertEqual(rendered, "cat /tmp/a.json")
    }

    func testMultipleOccurrencesAreAllReplaced() throws {
        let rendered = try CommandTemplate.render(
            "cp {{request}} /tmp/copy && cat {{request}}",
            envelopePath: "/tmp/a.json"
        )
        XCTAssertEqual(rendered, "cp /tmp/a.json /tmp/copy && cat /tmp/a.json")
    }

    /// A matched pair of quotes around the placeholder is absorbed,
    /// because we quote the value ourselves and `"'/tmp/a.json'"` would
    /// hand the script literal quote characters.
    func testMatchedSurroundingQuotesAreAbsorbed() throws {
        let rendered = try CommandTemplate.render("cat \"{{request}}\"", envelopePath: "/tmp/my file.json")
        XCTAssertEqual(rendered, "cat '/tmp/my file.json'")
    }

    /// An unmatched quote belongs to the user's own string and must not be
    /// eaten, or we would break their command.
    func testUnmatchedTrailingQuoteIsPreserved() throws {
        let rendered = try CommandTemplate.render("echo \"payload {{request}}\"", envelopePath: "/tmp/a.json")
        XCTAssertEqual(rendered, "echo \"payload /tmp/a.json\"")
    }

    func testUnsupportedPlaceholderThrows() {
        XCTAssertThrowsError(
            try CommandTemplate.render("run.sh {{request.body.id}}", envelopePath: "/tmp/a.json")
        ) { error in
            XCTAssertEqual(
                error as? CommandTemplate.TemplateError,
                .unsupportedPlaceholder("request.body.id")
            )
        }
    }

    func testUnsupportedPlaceholdersAreListedForTheUI() {
        XCTAssertEqual(
            CommandTemplate.unsupportedPlaceholders(in: "a {{request}} b {{nope}} c {{request.x}}"),
            ["nope", "request.x"]
        )
        XCTAssertTrue(CommandTemplate.unsupportedPlaceholders(in: "a {{request}}").isEmpty)
    }

    func testTemplateWithoutPlaceholderIsUnchanged() throws {
        XCTAssertEqual(try CommandTemplate.render("say hi", envelopePath: "/tmp/a.json"), "say hi")
        XCTAssertFalse(CommandTemplate.referencesRequest("say hi"))
        XCTAssertTrue(CommandTemplate.referencesRequest("cat {{request}}"))
    }
}

final class EndpointRuleTests: XCTestCase {
    func testPathNormalization() {
        XCTAssertEqual(EndpointRule.normalizePath("ep1"), "/ep1")
        XCTAssertEqual(EndpointRule.normalizePath("/ep1/"), "/ep1")
        XCTAssertEqual(EndpointRule.normalizePath("  /ep1  "), "/ep1")
        XCTAssertEqual(EndpointRule.normalizePath("/a/b/c"), "/a/b/c")
        XCTAssertEqual(EndpointRule.normalizePath(""), "")
        // Pasting the tunnel URL out of the menu bar should just work.
        XCTAssertEqual(EndpointRule.normalizePath("https://x.trycloudflare.com/ep1"), "/ep1")
        XCTAssertEqual(EndpointRule.normalizePath("/ep1?token=abc"), "/ep1")
    }

    func testToolNameDerivation() {
        XCTAssertEqual(EndpointRule.deriveToolName(fromPath: "/ep1"), "ep1")
        XCTAssertEqual(EndpointRule.deriveToolName(fromPath: "/github/push"), "github_push")
        XCTAssertEqual(EndpointRule.deriveToolName(fromPath: "/deploy-site"), "deploy-site")
        XCTAssertEqual(EndpointRule.deriveToolName(fromPath: "/a b/c!"), "a_b_c")
        XCTAssertEqual(EndpointRule.deriveToolName(fromPath: "/"), "endpoint")
    }

    func testMethodMatching() {
        let postOnly = EndpointRule(path: "/x", command: "true", methods: ["POST"])
        XCTAssertTrue(postOnly.accepts(method: "POST"))
        XCTAssertTrue(postOnly.accepts(method: "post"))
        XCTAssertFalse(postOnly.accepts(method: "GET"))

        let anyMethod = EndpointRule(path: "/x", command: "true", methods: [])
        XCTAssertTrue(anyMethod.accepts(method: "DELETE"))
    }

    func testValidation() {
        XCTAssertNil(EndpointRule(path: "/x", command: "say hi").validationError())
        XCTAssertNotNil(EndpointRule(path: "", command: "say hi").validationError())
        XCTAssertNotNil(EndpointRule(path: "/x", command: "").validationError())
        XCTAssertNotNil(EndpointRule(path: "/health", command: "say hi").validationError())
        XCTAssertNotNil(EndpointRule(path: "/x", command: "run {{request.body}}").validationError())
        XCTAssertNotNil(EndpointRule(path: "/x", command: "say hi", timeoutSeconds: 0).validationError())
        XCTAssertNotNil(
            EndpointRule(path: "/x", command: "say hi", mcpInputSchema: "not json").validationError()
        )
        XCTAssertNil(
            EndpointRule(path: "/x", command: "say hi", mcpInputSchema: "{\"type\":\"object\"}").validationError()
        )
    }
}

final class AppConfigTests: XCTestCase {
    private func config(with endpoints: [EndpointRule]) -> AppConfig {
        var config = AppConfig.default
        config.endpoints = endpoints
        return config
    }

    func testToolNameCollisionsAreDisambiguated() {
        // `/a/b` and `/a-b` both reduce to `a_b`; neither may shadow the
        // other or one endpoint becomes unreachable over MCP.
        let config = self.config(with: [
            EndpointRule(path: "/a/b", command: "true"),
            EndpointRule(path: "/a-b", command: "true", mcpToolName: "a_b")
        ])
        let names = config.resolvedToolNames()
        XCTAssertEqual(Set(names.values).count, 2)
        XCTAssertTrue(names.values.contains("a_b"))
        XCTAssertTrue(names.values.contains("a_b_2"))
    }

    func testLookupIgnoresDisabledButReportsExistence() {
        let config = self.config(with: [
            EndpointRule(path: "/on", command: "true", enabled: true),
            EndpointRule(path: "/off", command: "true", enabled: false)
        ])
        XCTAssertNotNil(config.rule(forPath: "/on"))
        XCTAssertNil(config.rule(forPath: "/off"))
        XCTAssertNotNil(config.anyRule(forPath: "/off"))
        XCTAssertNil(config.anyRule(forPath: "/nope"))
        // Un-normalized input still resolves.
        XCTAssertNotNil(config.rule(forPath: "on/"))
    }

    func testMcpToolsExcludeOptedOutAndBrokenRules() {
        let config = self.config(with: [
            EndpointRule(path: "/ok", command: "true"),
            EndpointRule(path: "/no-mcp", command: "true", mcpEnabled: false),
            EndpointRule(path: "/broken", command: "run {{bad}}"),
            EndpointRule(path: "/disabled", command: "true", enabled: false)
        ])
        XCTAssertEqual(config.mcpTools().map(\.toolName), ["ok"])
    }

    func testDecodingToleratesMissingKeys() throws {
        // An old config that predates a new toggle must keep its
        // endpoints rather than resetting to defaults.
        let json = """
        {"bearerToken":"abc","localAPIPort":9000,
         "endpoints":[{"id":"\(UUID().uuidString)","path":"/x","command":"true"}]}
        """
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.bearerToken, "abc")
        XCTAssertEqual(decoded.localAPIPort, 9000)
        XCTAssertEqual(decoded.endpoints.count, 1)
        XCTAssertEqual(decoded.endpoints[0].path, "/x")
        // Fields absent from the JSON fall back to defaults.
        XCTAssertEqual(decoded.maxConcurrentRuns, AppConfig.default.maxConcurrentRuns)
        XCTAssertEqual(decoded.fallbackAPIPort, AppConfig.default.fallbackAPIPort)
        XCTAssertEqual(decoded.endpoints[0].timeoutSeconds, 30)
        XCTAssertTrue(decoded.endpoints[0].enabled)
    }

    func testDefaultPortsAreThePrimaryThenTheFallback() {
        XCTAssertEqual(AppConfig.default.listenPortCandidates(), [7876, 7877])
    }

    func testZeroFallbackMeansOnlyThePrimaryIsTried() {
        var config = AppConfig.default
        config.fallbackAPIPort = 0
        XCTAssertEqual(config.listenPortCandidates(), [7876])
    }

    func testDuplicateAndOutOfRangePortsCollapse() {
        var config = AppConfig.default
        // A fallback equal to the primary must not make one conflict look
        // like two attempts.
        config.localAPIPort = 9000
        config.fallbackAPIPort = 9000
        XCTAssertEqual(config.listenPortCandidates(), [9000])

        config.fallbackAPIPort = 70_000
        XCTAssertEqual(config.listenPortCandidates(), [9000])
    }

    func testNonsensePortsFallBackToTheShippedDefault() {
        var config = AppConfig.default
        config.localAPIPort = 0
        config.fallbackAPIPort = -1
        XCTAssertEqual(config.listenPortCandidates(), [AppConfig.default.localAPIPort])
    }
}

final class RequestEnvelopeTests: XCTestCase {
    func testJSONBodyIsParsedAndMirrored() throws {
        let envelope = RequestEnvelope(
            source: "http",
            method: "POST",
            path: "/ep1",
            query: ["a": "1"],
            headers: ["content-type": "application/json"],
            body: Data("{\"users\":[{\"id\":42}]}".utf8)
        )
        let object = envelope.jsonObject()
        XCTAssertEqual(object["method"] as? String, "POST")
        XCTAssertEqual(object["path"] as? String, "/ep1")
        XCTAssertEqual((object["query"] as? [String: String])?["a"], "1")
        XCTAssertEqual(object["body_raw"] as? String, "{\"users\":[{\"id\":42}]}")
        XCTAssertEqual(object["body_bytes"] as? Int, 21)

        let body = object["body"] as? [String: Any]
        let users = body?["users"] as? [[String: Any]]
        XCTAssertEqual(users?.first?["id"] as? Int, 42)
    }

    func testNonJSONBodyStillArrivesAsText() {
        let envelope = RequestEnvelope(
            source: "http",
            method: "POST",
            path: "/ep1",
            body: Data("a=1&b=2".utf8)
        )
        let object = envelope.jsonObject()
        XCTAssertEqual(object["body_raw"] as? String, "a=1&b=2")
        XCTAssertTrue(object["body"] is NSNull)
    }

    func testBinaryBodyFallsBackToBase64() {
        let bytes = Data([0xFF, 0xFE, 0x00, 0x01])
        let envelope = RequestEnvelope(source: "http", method: "POST", path: "/ep1", body: bytes)
        let object = envelope.jsonObject()
        XCTAssertEqual(object["body_base64"] as? String, bytes.base64EncodedString())
        XCTAssertNil(object["body_raw"])
    }

    func testWrittenFileIsPrivateToTheUser() throws {
        let envelope = RequestEnvelope(source: "http", method: "POST", path: "/ep1", body: Data("{}".utf8))
        let url = try envelope.write()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
        // Payloads carry secrets, so they must not land in world-readable /tmp.
        XCTAssertFalse(url.path.hasPrefix("/tmp/"))
    }
}
