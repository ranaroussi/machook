import Foundation

/// How the Cloudflare Tunnel is fronted.
///
/// `.quick` runs `cloudflared tunnel --url http://localhost:<port>` and
/// gets back an ephemeral `*.trycloudflare.com` URL — zero CF account
/// needed, but the URL rotates on every restart. Right default for
/// first-launch UX.
///
/// `.named` runs `cloudflared tunnel run --token <token>` against a
/// connector configured in the user's Cloudflare Zero Trust dashboard.
/// The hostname is stable, which is what you want once a webhook
/// provider or an MCP client has the URL saved in its own config.
public enum TunnelMode: String, Codable, Sendable, Equatable, CaseIterable {
    case quick
    case named
}

/// User-tunable configuration persisted in `UserDefaults`.
public struct AppConfig: Codable, Equatable, Sendable {
    /// Required on every route except `/health`, in both the HTTP and MCP
    /// surfaces. Empty disables auth, which is only sane for localhost
    /// testing — the Settings window warns loudly when the tunnel is on
    /// and this is blank, because that publishes a shell to the internet.
    public var bearerToken: String

    /// Port the local HTTP server binds on 127.0.0.1. cloudflared points here.
    public var localAPIPort: Int

    /// Tried when `localAPIPort` is already taken. A fixed default port is
    /// a coin flip on a machine that already runs something on it, and the
    /// failure mode — a menu bar app that looks fine and answers nothing —
    /// is bad enough to be worth a second attempt. Set to 0 to insist on
    /// the primary port and fail loudly instead.
    public var fallbackAPIPort: Int

    public var tunnelEnabled: Bool
    public var tunnelMode: TunnelMode
    public var tunnelToken: String
    public var tunnelHostname: String

    /// The endpoint table: path → command.
    public var endpoints: [EndpointRule]

    /// Master switch for `POST /mcp`. Endpoints opt in individually via
    /// `EndpointRule.mcpEnabled`.
    public var mcpEnabled: Bool

    /// Commands allowed to run at once. Further requests get 503 rather
    /// than fork-bombing the Mac when a provider retries in a loop.
    public var maxConcurrentRuns: Int

    /// Per-stream cap on captured stdout/stderr. Output past this is
    /// discarded (but still drained, so the child never blocks on a full
    /// pipe).
    public var maxOutputKB: Int

    /// Largest request body accepted before the command runs.
    public var maxBodyMB: Int

    /// Keep the request envelope on disk after the command exits. Handy
    /// while writing a script, off by default because payloads carry
    /// secrets.
    public var keepRequestFiles: Bool

    /// Shell used to interpret the command template.
    public var shellPath: String

    /// Run the shell as a login shell. On by default: a GUI-launched app
    /// inherits a bare `PATH`, so without this your Homebrew `python3` or
    /// `pyenv` shim is not found. Costs a few hundred ms per request, so
    /// it can be turned off when every command uses absolute paths.
    public var loginShell: Bool

    public static let `default` = AppConfig(
        bearerToken: "",
        localAPIPort: 7876,
        fallbackAPIPort: 7877,
        tunnelEnabled: false,
        tunnelMode: .quick,
        tunnelToken: "",
        tunnelHostname: "",
        endpoints: [],
        mcpEnabled: true,
        maxConcurrentRuns: 4,
        maxOutputKB: 1024,
        maxBodyMB: 10,
        keepRequestFiles: false,
        shellPath: "/bin/zsh",
        loginShell: true
    )

    public init(
        bearerToken: String,
        localAPIPort: Int,
        fallbackAPIPort: Int = 7877,
        tunnelEnabled: Bool,
        tunnelMode: TunnelMode,
        tunnelToken: String,
        tunnelHostname: String,
        endpoints: [EndpointRule],
        mcpEnabled: Bool = true,
        maxConcurrentRuns: Int = 4,
        maxOutputKB: Int = 1024,
        maxBodyMB: Int = 10,
        keepRequestFiles: Bool = false,
        shellPath: String = "/bin/zsh",
        loginShell: Bool = true
    ) {
        self.bearerToken = bearerToken
        self.localAPIPort = localAPIPort
        self.fallbackAPIPort = fallbackAPIPort
        self.tunnelEnabled = tunnelEnabled
        self.tunnelMode = tunnelMode
        self.tunnelToken = tunnelToken
        self.tunnelHostname = tunnelHostname
        self.endpoints = endpoints
        self.mcpEnabled = mcpEnabled
        self.maxConcurrentRuns = maxConcurrentRuns
        self.maxOutputKB = maxOutputKB
        self.maxBodyMB = maxBodyMB
        self.keepRequestFiles = keepRequestFiles
        self.shellPath = shellPath
        self.loginShell = loginShell
    }

    // Missing keys fall back to the default rather than throwing, so
    // shipping a new toggle never resets somebody's endpoint table.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.default
        self.bearerToken       = (try? c.decode(String.self,         forKey: .bearerToken))       ?? d.bearerToken
        self.localAPIPort      = (try? c.decode(Int.self,            forKey: .localAPIPort))      ?? d.localAPIPort
        self.fallbackAPIPort   = (try? c.decode(Int.self,            forKey: .fallbackAPIPort))   ?? d.fallbackAPIPort
        self.tunnelEnabled     = (try? c.decode(Bool.self,           forKey: .tunnelEnabled))     ?? d.tunnelEnabled
        self.tunnelMode        = (try? c.decode(TunnelMode.self,     forKey: .tunnelMode))        ?? d.tunnelMode
        self.tunnelToken       = (try? c.decode(String.self,         forKey: .tunnelToken))       ?? d.tunnelToken
        self.tunnelHostname    = (try? c.decode(String.self,         forKey: .tunnelHostname))    ?? d.tunnelHostname
        self.endpoints         = (try? c.decode([EndpointRule].self, forKey: .endpoints))         ?? d.endpoints
        self.mcpEnabled        = (try? c.decode(Bool.self,           forKey: .mcpEnabled))        ?? d.mcpEnabled
        self.maxConcurrentRuns = (try? c.decode(Int.self,            forKey: .maxConcurrentRuns)) ?? d.maxConcurrentRuns
        self.maxOutputKB       = (try? c.decode(Int.self,            forKey: .maxOutputKB))       ?? d.maxOutputKB
        self.maxBodyMB         = (try? c.decode(Int.self,            forKey: .maxBodyMB))         ?? d.maxBodyMB
        self.keepRequestFiles  = (try? c.decode(Bool.self,           forKey: .keepRequestFiles))  ?? d.keepRequestFiles
        self.shellPath         = (try? c.decode(String.self,         forKey: .shellPath))         ?? d.shellPath
        self.loginShell        = (try? c.decode(Bool.self,           forKey: .loginShell))        ?? d.loginShell
    }

    // MARK: - Ports

    /// Ports the listener may claim, in order of preference.
    ///
    /// Kept as plain logic rather than something the server works out
    /// while binding, so the "which ports, in what order" question has a
    /// testable answer. Zero and out-of-range values drop out (0 is how
    /// you switch the fallback off), duplicates collapse so a fallback
    /// equal to the primary cannot make a single conflict look like two,
    /// and an entirely nonsensical pair falls back to the shipped default
    /// rather than leaving the app with nothing to bind.
    public func listenPortCandidates() -> [Int] {
        var candidates: [Int] = []
        for port in [localAPIPort, fallbackAPIPort] where (1...65_535).contains(port) {
            if !candidates.contains(port) { candidates.append(port) }
        }
        return candidates.isEmpty ? [AppConfig.default.localAPIPort] : candidates
    }

    // MARK: - Lookup

    /// First enabled rule claiming `path`. Paths are matched exactly
    /// after normalization; there is no prefix or pattern matching, which
    /// keeps "which command does this URL run" a question with one answer.
    public func rule(forPath path: String) -> EndpointRule? {
        let normalized = EndpointRule.normalizePath(path)
        return endpoints.first { $0.enabled && $0.path == normalized }
    }

    /// Any rule claiming `path`, enabled or not. Lets the dispatcher tell
    /// "no such endpoint" (404) apart from "that one is switched off" (503).
    public func anyRule(forPath path: String) -> EndpointRule? {
        let normalized = EndpointRule.normalizePath(path)
        return endpoints.first { $0.path == normalized }
    }

    /// Stable tool name per endpoint, with collisions resolved by
    /// suffixing. Two endpoints named the same would otherwise make one
    /// of them unreachable over MCP.
    public func resolvedToolNames() -> [UUID: String] {
        var used = Set<String>()
        var result: [UUID: String] = [:]
        for rule in endpoints {
            let requested = rule.mcpToolName.trimmingCharacters(in: .whitespacesAndNewlines)
            var name = requested.isEmpty
                ? EndpointRule.deriveToolName(fromPath: rule.path)
                : EndpointRule.deriveToolName(fromPath: requested)
            if used.contains(name) {
                var suffix = 2
                while used.contains("\(name)_\(suffix)") { suffix += 1 }
                name = "\(name)_\(suffix)"
            }
            used.insert(name)
            result[rule.id] = name
        }
        return result
    }

    /// Endpoints exposed over MCP, paired with their resolved tool names.
    public func mcpTools() -> [(rule: EndpointRule, toolName: String)] {
        let names = resolvedToolNames()
        return endpoints.compactMap { rule in
            guard rule.enabled, rule.mcpEnabled, rule.validationError() == nil,
                  let name = names[rule.id] else { return nil }
            return (rule, name)
        }
    }
}

/// Thread-safe accessor for `AppConfig`, backed by `UserDefaults` so the
/// Settings window can mutate values independently of the runtime.
public final class AppConfigStore: @unchecked Sendable {
    public static let shared = AppConfigStore()

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private let key = "machook.config.v1"
    private var cached: AppConfig

    /// Posted whenever `update(_:)` runs. Observers re-read `current`.
    public static let didChangeNotification = Notification.Name("AppConfigStore.didChange")

    private init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.cached = decoded
        } else {
            self.cached = .default
        }
    }

    public var current: AppConfig {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    public func update(_ transform: (inout AppConfig) -> Void) {
        lock.lock()
        var next = cached
        transform(&next)
        cached = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: key)
        }
        lock.unlock()
        NotificationCenter.default.post(name: AppConfigStore.didChangeNotification, object: nil)
    }
}
