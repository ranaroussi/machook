import Foundation
import AppKit

/// Supervises a `cloudflared` child process and exposes the public URL.
///
/// Two modes (see `TunnelMode`):
///   - `.quick`: `cloudflared tunnel --url http://localhost:<port>`,
///     URL parsed from stderr (`*.trycloudflare.com`).
///   - `.named`: `cloudflared tunnel run --token <token>`, URL fixed
///     by `config.tunnelHostname`. Stderr only used to detect the
///     "tunnel connection registered" signal that means traffic can
///     start flowing.
///
/// Lookup order for the binary:
///   1. Bundled inside `Contents/Resources/cloudflared` (CI release builds)
///   2. `/opt/homebrew/bin/cloudflared` (Apple Silicon Homebrew)
///   3. `/usr/local/bin/cloudflared` (Intel Homebrew)
///   4. `which cloudflared` (PATH)
public final class TunnelManager: @unchecked Sendable {
    private var process: Process?
    public private(set) var isRunning = false
    public private(set) var publicURL: String?
    private let urlLock = NSLock()
    /// In-flight reachability verification for the current URL.
    private var probeTask: Task<Void, Never>?

    /// Verification state, kept here rather than only on the `@MainActor`
    /// `TunnelStatus` so `GET /status` can read it without hopping actors —
    /// the same split already used for `publicURL`.
    private let reachLock = NSLock()
    private var reachabilityState: TunnelStatus.Reachability = .unknown
    public var reachability: TunnelStatus.Reachability {
        reachLock.lock(); defer { reachLock.unlock() }
        return reachabilityState
    }

    private func setReachability(_ next: TunnelStatus.Reachability) {
        reachLock.lock()
        reachabilityState = next
        reachLock.unlock()
        Task { @MainActor in TunnelStatus.shared.reachability = next }
    }

    public init() {}

    /// Per-mode runtime: how to invoke `cloudflared` and how to
    /// recognize "the tunnel is live" from its stderr.
    private struct Runtime: Sendable {
        let arguments: [String]
        /// Extra environment for the child. Secrets travel here rather than
        /// in `arguments`, because argv is world-readable through `ps` while
        /// another user's environment is not.
        let environment: [String: String]
        /// Maps a stderr chunk → the public URL the tunnel will be
        /// reachable at, or `nil` if this chunk doesn't yet signal
        /// readiness. Called repeatedly until it returns non-nil.
        let urlExtractor: @Sendable (String) -> String?
    }

    /// One-shot URL resolution box. The cloudflared subprocess prints its
    /// URL on stdout/stderr from background threads, and Swift's strict
    /// concurrency model objects to closures that capture mutable state.
    /// Hoisting `resolved` + `completion` into a heap-allocated, locked
    /// box keeps the readability handlers honest and `@Sendable`.
    private final class Resolver: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let callback: @Sendable (String?) -> Void
        init(callback: @escaping @Sendable (String?) -> Void) { self.callback = callback }
        func fire(_ url: String?) {
            lock.lock()
            let firstTime = !done
            done = true
            lock.unlock()
            if firstTime { callback(url) }
        }
    }

    /// Starts the tunnel pointing at `port`. The completion fires with the
    /// public URL once cloudflared prints it (typically <5s) or `nil` on
    /// timeout/failure.
    public func start(port: Int, completion: @escaping @Sendable (String?) -> Void) {
        let mode = AppConfigStore.shared.current.tunnelMode
        Log.tunnel.info("start() requested (port=\(port), mode=\(mode.rawValue, privacy: .public))")

        guard !isRunning else {
            Log.tunnel.notice("start() short-circuited: tunnel already running (publicURL=\(self.publicURL ?? "nil", privacy: .public))")
            completion(publicURL)
            return
        }
        guard let execPath = locateCloudflared() else {
            Log.tunnel.error("start() failed: cloudflared binary not found in bundle or on PATH")
            DispatchQueue.main.async { self.showInstallInstructions() }
            completion(nil)
            return
        }
        Log.tunnel.info("using cloudflared at \(execPath, privacy: .public)")

        guard let runtime = buildRuntime(port: port) else {
            // buildRuntime already logged the specific reason
            // (named-mode misconfig). Return silently here.
            completion(nil)
            return
        }

        // The token now travels in the environment, so argv is already free
        // of secrets. The redaction stays as a guard in case a future flag
        // reintroduces one.
        let safeArgs = runtime.arguments.enumerated().map { idx, arg -> String in
            if idx > 0, runtime.arguments[idx - 1] == "--token" {
                return "<redacted-token-\(arg.count)-chars>"
            }
            return arg
        }
        Log.tunnel.info("spawning cloudflared: \(safeArgs.joined(separator: " "), privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = runtime.arguments
        if !runtime.environment.isEmpty {
            // Merge rather than replace: a bare environment would strip PATH
            // and HOME out from under cloudflared.
            process.environment = ProcessInfo.processInfo.environment
                .merging(runtime.environment) { _, new in new }
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let resolver = Resolver(callback: completion)

        // In named mode the public URL is determined by config — we
        // don't have to wait for cloudflared's stderr to know what
        // it is. Pre-populate `publicURL` and fire the completion
        // immediately so the menu bar and Settings show the hostname
        // during cloudflared's ~3-10s bootstrap window.
        //
        // In quick mode we leave publicURL=nil and the stderr-parse
        // path populates it on first match — the random
        // `*.trycloudflare.com` URL is genuinely unknown until
        // cloudflared prints it.
        let cfg = AppConfigStore.shared.current
        if cfg.tunnelMode == .named {
            let host = Self.normalizeHostname(cfg.tunnelHostname)
            if !host.isEmpty {
                let synchronousURL = "https://\(host)"
                urlLock.lock()
                publicURL = synchronousURL
                urlLock.unlock()
                Task { @MainActor in
                    TunnelStatus.shared.publicURL = synchronousURL
                }
                Log.tunnel.info("named-mode publicURL pre-populated from config: \(synchronousURL, privacy: .public)")
                resolver.fire(synchronousURL)
                // Pre-populating is a guess about where traffic will land, not
                // evidence that it does. Start proving it.
                beginReachabilityProbe(for: synchronousURL)
            }
        }

        let consume: @Sendable (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

            // Surface the child's output. Routine chatter stays at debug so
            // steady state is quiet, but anything that looks like a failure
            // is promoted, because `log show` drops debug-level records
            // unless explicitly asked for them — which is how a tunnel that
            // died after startup used to leave no trace at all.
            for line in text.split(separator: "\n") where !line.isEmpty {
                let entry = String(line)
                switch Self.logLevel(forCloudflaredLine: entry) {
                case .debug:  Log.tunnel.debug("cloudflared: \(entry, privacy: .public)")
                case .notice: Log.tunnel.notice("cloudflared: \(entry, privacy: .public)")
                case .error:  Log.tunnel.error("cloudflared: \(entry, privacy: .public)")
                }
            }

            guard let url = runtime.urlExtractor(text) else { return }
            guard let self else { return }
            self.urlLock.lock()
            let firstTime = self.publicURL != url
            self.publicURL = url
            self.urlLock.unlock()
            guard firstTime else { return }
            Log.tunnel.info("cloudflared URL ready: \(url, privacy: .public)")
            resolver.fire(url)
            // Mirror to the SwiftUI-observable singleton so the Settings
            // window can show "Connecting…" → live URL without polling.
            Task { @MainActor in
                TunnelStatus.shared.publicURL = url
                TunnelStatus.shared.isRunning = true
            }
            // A printed URL is a claim, not a fact. Verify it before the menu
            // invites anyone to point a webhook at it.
            self.beginReachabilityProbe(for: url)
        }

        stdout.fileHandleForReading.readabilityHandler = consume
        stderr.fileHandleForReading.readabilityHandler = consume

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            Log.tunnel.notice("cloudflared exited (status=\(status), reason=\(reason.rawValue))")
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            self?.probeTask?.cancel()
            self?.setReachability(.unknown)
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.publicURL = nil
            }
            Task { @MainActor in
                TunnelStatus.shared.publicURL = nil
                TunnelStatus.shared.isRunning = false
            }
        }

        do {
            try process.run()
            self.process = process
            isRunning = true
            Log.tunnel.info("cloudflared spawned, PID \(process.processIdentifier)")
            Task { @MainActor in TunnelStatus.shared.isRunning = true }

            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                resolver.fire(nil)
            }
        } catch {
            Log.tunnel.error("failed to launch cloudflared: \(error.localizedDescription, privacy: .public)")
            completion(nil)
        }
    }

    /// Stop the supervised cloudflared. Sends SIGTERM, gives it up to
    /// 3 seconds to exit cleanly, then escalates to SIGKILL.
    /// Returning synchronously from `stop()` matters because the
    /// `configChanged` smart-restart immediately calls `start()` next
    /// and a stale child would make the new one register against the
    /// wrong tunnel — or fail to register at all if a port is bound.
    public func stop() {
        probeTask?.cancel()
        probeTask = nil
        guard isRunning, let process else { return }
        let pid = process.processIdentifier
        Log.tunnel.info("stop() sending SIGTERM to cloudflared PID \(pid)")
        process.terminate()

        // Wait briefly for graceful shutdown.
        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            Log.tunnel.notice("cloudflared PID \(pid) didn't exit on SIGTERM, escalating to SIGKILL")
            kill(pid, SIGKILL)
            // Brief wait for the kernel to reap.
            let killDeadline = Date().addingTimeInterval(1.0)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        self.process = nil
        isRunning = false
        publicURL = nil
        setReachability(.unknown)
        Task { @MainActor in
            TunnelStatus.shared.publicURL = nil
            TunnelStatus.shared.isRunning = false
        }
    }

    /// Compose the per-mode `cloudflared` runtime. Returns `nil` when
    /// the user picked `.named` but hasn't yet entered a token + hostname.
    private func buildRuntime(port: Int) -> Runtime? {
        let cfg = AppConfigStore.shared.current
        switch cfg.tunnelMode {
        case .quick:
            // Matches `https://<adjective-adjective-noun-noun>.trycloudflare.com`
            // out of stderr — cloudflared prints it ~once, typically
            // within 3 seconds of startup.
            let pattern = "https://[a-z0-9-]+\\.trycloudflare\\.com"
            return Runtime(
                arguments: ["tunnel", "--no-autoupdate", "--url", "http://localhost:\(port)"],
                environment: [:],
                urlExtractor: { text in
                    guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
                    return String(text[range])
                }
            )

        case .named:
            let token = cfg.tunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = Self.normalizeHostname(cfg.tunnelHostname)
            guard !token.isEmpty, !host.isEmpty else {
                Log.tunnel.error("named tunnel selected but token or hostname is empty")
                DispatchQueue.main.async { self.showNamedTunnelMisconfiguredAlert() }
                return nil
            }
            let publicURL = "https://\(host)"
            // cloudflared in token mode reads the ingress rules from
            // the Cloudflare side, so there's nothing we can verify
            // about local-port mapping from here. We detect "tunnel
            // up" via the `Registered tunnel connection` log line
            // cloudflared prints once each of its four edge
            // connections is healthy.
            //
            // Argument order matters: `--no-autoupdate` is a `tunnel`
            // subcommand flag, not a `run` subcommand flag. Place it
            // BEFORE `run` or cloudflared rejects it with
            // "flag provided but not defined", prints help, and
            // exits 0 within ~40ms.
            //
            // The token goes through TUNNEL_TOKEN rather than `--token`
            // because argv is visible to every process on the machine via
            // `ps`, and this token alone is enough to publish traffic
            // through the user's tunnel. cloudflared reads the variable for
            // `tunnel run` and needs no positional tunnel name when it is
            // set.
            return Runtime(
                arguments: ["tunnel", "--no-autoupdate", "run"],
                environment: ["TUNNEL_TOKEN": token],
                urlExtractor: { text in
                    text.contains("Registered tunnel connection") ? publicURL : nil
                }
            )
        }
    }

    // MARK: - Reachability

    /// Probe the published URL until it answers, or until we're confident it
    /// never will.
    ///
    /// `/health` is the target because it is the one route that needs no
    /// bearer token, so the probe works regardless of how auth is configured
    /// and proves the whole path: DNS → Cloudflare edge → connector → our
    /// listener.
    private func beginReachabilityProbe(for url: String) {
        probeTask?.cancel()

        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        guard let target = URL(string: base + "/health") else { return }

        setReachability(.checking)

        probeTask = Task.detached { [weak self] in
            // A single failure means nothing: DNS for a fresh quick tunnel can
            // take a few seconds to publish, and a named tunnel's connector
            // needs time to register. Fibonacci backoff spans ~87s in 8
            // attempts, which is long enough to outlast a slow start without
            // leaving the menu ambiguous for minutes.
            let delays: [UInt64] = [1, 2, 3, 5, 8, 13, 21, 34]
            var outcome: TunnelStatus.Reachability = .checking

            for (attempt, delay) in delays.enumerated() {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                if Task.isCancelled { return }
                // Stopped, or restarted onto a different URL, while we waited.
                guard let self, self.isRunning, self.publicURL == url else { return }

                outcome = await Self.probeOnce(target)
                if outcome == .reachable {
                    Log.tunnel.info("tunnel verified reachable: \(url, privacy: .public)")
                    self.setReachability(.reachable)
                    return
                }
                Log.tunnel.debug("probe \(attempt + 1)/\(delays.count) failed for \(url, privacy: .public)")
            }

            if Task.isCancelled { return }
            if case .unreachable(let why) = outcome {
                Log.tunnel.error("tunnel never became reachable: \(url, privacy: .public) — \(why, privacy: .public)")
            }
            self?.setReachability(outcome)
        }
    }

    private static func probeOnce(_ url: URL) async -> TunnelStatus.Reachability {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        // Cloudflare's edge error pages are cacheable; a cached 530 would
        // outlive the condition it describes.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return classifyProbe(statusCode: (response as? HTTPURLResponse)?.statusCode, error: nil)
        } catch {
            return classifyProbe(statusCode: nil, error: error)
        }
    }

    /// Turn the outcome of one probe request into a state the menu can show.
    ///
    /// Separated from the request itself so the interesting cases are
    /// testable without a network: each one produces a different instruction
    /// for the user, and getting them confused is worse than saying nothing.
    static func classifyProbe(statusCode: Int?, error: Error?) -> TunnelStatus.Reachability {
        if let statusCode {
            switch statusCode {
            case 200:
                return .reachable
            // Cloudflare's own edge errors. 530 is served for 1033 ("tunnel
            // not found / not connected"), which means DNS resolved but no
            // connector is registered for that hostname.
            case 530:
                return .unreachable("Cloudflare has no connector for this hostname (1033)")
            case 502, 503, 504:
                return .unreachable("tunnel is up but nothing answered locally (\(statusCode))")
            case 403:
                return .unreachable("blocked by Cloudflare Access (403)")
            default:
                return .unreachable("tunnel answered \(statusCode)")
            }
        }

        guard let error else { return .unreachable("no response") }

        let code = (error as NSError).code
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            // The failure this exists for. Quick tunnels get a hostname
            // assigned before — and sometimes without ever — a DNS record
            // being published, so name the cause and the way out.
            return .unreachable("hostname is not in DNS — Cloudflare never published it")
        case NSURLErrorTimedOut:
            return .unreachable("timed out")
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            return .unreachable("cannot connect")
        case NSURLErrorNotConnectedToInternet:
            return .unreachable("this Mac is offline")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return .unreachable("TLS failed")
        default:
            return .unreachable("unreachable")
        }
    }

    /// How loudly to log a line of `cloudflared` output.
    ///
    /// All of it used to go to `.debug`, which `log show` drops unless asked
    /// for explicitly — so a tunnel that failed after startup left no trace
    /// in a default log capture. Errors and warnings are promoted so they
    /// persist, while the routine chatter stays at debug where it belongs.
    enum CloudflaredLogLevel: Equatable, Sendable { case debug, notice, error }

    static func logLevel(forCloudflaredLine line: String) -> CloudflaredLogLevel {
        // cloudflared's own level tags, e.g. "2026-09-10T12:45:50Z ERR …".
        if line.contains(" ERR ") { return .error }
        if line.contains(" WRN ") { return .notice }
        let lowered = line.lowercased()
        for needle in ["failed to", "cannot", "unauthorized", "not valid", "rate limit", "429"] {
            if lowered.contains(needle) { return .error }
        }
        for needle in ["retrying", "unregistered", "connection terminated", "no more connections"] {
            if lowered.contains(needle) { return .notice }
        }
        return .debug
    }

    // MARK: - Stray process reaping

    /// PIDs of `cloudflared` processes started from `executablePath` that we
    /// are not currently supervising.
    ///
    /// A force-quit or a crash leaves our child reparented to launchd, still
    /// holding a tunnel pointed at a port a later instance will serve. The
    /// filter is deliberately narrow — an exact match on the executable path
    /// we launch, which for a release build is inside our own bundle — so a
    /// dev build resolving `cloudflared` from Homebrew can never sweep up
    /// tunnels belonging to other apps or to the user.
    static func strayPIDs(
        psOutput: String,
        executablePath: String,
        excluding excluded: Set<Int32>
    ) -> [Int32] {
        var pids: [Int32] = []
        for rawLine in psOutput.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Format: "<pid> <command with args…>"
            guard let spaceIndex = line.firstIndex(of: " ") else { continue }
            guard let pid = Int32(line[line.startIndex..<spaceIndex]) else { continue }
            let command = line[line.index(after: spaceIndex)...].trimmingCharacters(in: .whitespaces)
            guard command == executablePath || command.hasPrefix(executablePath + " ") else { continue }
            guard !excluded.contains(pid), pid != ProcessInfo.processInfo.processIdentifier else { continue }
            pids.append(pid)
        }
        return pids
    }

    /// Terminate leftover `cloudflared` children from a previous run.
    ///
    /// Only ever runs against a binary inside our own app bundle: if
    /// `cloudflared` was resolved from Homebrew or the PATH, that same path
    /// is shared with every other tunnel on the machine, and the user's own
    /// unrelated tunnels are not ours to kill.
    public func reapStrayProcesses() {
        guard let execPath = locateCloudflared() else { return }
        let bundlePath = Self.absolutePath(Bundle.main.bundlePath)
        guard execPath.hasPrefix(bundlePath + "/") else {
            Log.tunnel.debug("skipping stray sweep: cloudflared at \(execPath, privacy: .public) is shared, not ours")
            return
        }

        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice

        let output: String
        do {
            try ps.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            output = String(data: data, encoding: .utf8) ?? ""
        } catch {
            Log.tunnel.notice("stray sweep skipped: could not run ps (\(error.localizedDescription, privacy: .public))")
            return
        }

        var excluded = Set<Int32>()
        if let current = process?.processIdentifier { excluded.insert(current) }

        let strays = Self.strayPIDs(psOutput: output, executablePath: execPath, excluding: excluded)
        guard !strays.isEmpty else { return }

        for pid in strays {
            Log.tunnel.notice("reaping stray cloudflared PID \(pid) from a previous run")
            kill(pid, SIGTERM)
        }
    }

    /// Strip an optional `https://` or `http://` prefix and any trailing
    /// slashes so we always compose `https://<bare-hostname>` regardless
    /// of how the user pasted it.
    public static func normalizeHostname(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = host.range(of: "^https?://", options: .regularExpression) {
            host.removeSubrange(scheme)
        }
        while host.hasSuffix("/") { host.removeLast() }
        return host
    }

    @MainActor
    private func showNamedTunnelMisconfiguredAlert() {
        let alert = NSAlert()
        alert.messageText = "Cloudflare named tunnel not configured"
        alert.informativeText = """
        You selected "Named tunnel (custom domain)" in Settings but \
        haven't entered both the connector token and the public hostname.

        Open Settings → Tunnel and fill in:
          • Tunnel token (eyJh… from the Zero Trust dashboard)
          • Public hostname (e.g. hooks.yourcompany.com)

        Or switch back to the free `*.trycloudflare.com` tunnel.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NotificationCenter.default.post(name: .machookOpenSettings, object: nil)
        }
    }

    /// Resolve against the working directory so the path we launch — and
    /// therefore the one `ps` reports for the child — is always absolute.
    ///
    /// Launching the app from a shell by a relative path (`./Machook.app/…`)
    /// makes `Bundle.main` relative too, and a child recorded as
    /// `./Machook.app/Contents/Resources/cloudflared` will not match the
    /// absolute path the stray sweep looks for. Normalising here fixes the
    /// cause instead of teaching the matcher to guess.
    static func absolutePath(_ path: String) -> String {
        guard !path.hasPrefix("/") else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true))
            .standardizedFileURL.path
    }

    private func locateCloudflared() -> String? {
        if let bundled = Bundle.main.url(forResource: "cloudflared", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return Self.absolutePath(bundled.path)
        }
        let candidates = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // /usr/bin/which fallback
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["cloudflared"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            return nil
        }
        return nil
    }

    @MainActor
    private func showInstallInstructions() {
        let alert = NSAlert()
        alert.messageText = "cloudflared not installed"
        alert.informativeText = """
        Machook needs cloudflared to expose your endpoints to the internet.

        Install with Homebrew:
            brew install cloudflared

        Or download from:
            https://github.com/cloudflare/cloudflared/releases
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy install command")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew install cloudflared", forType: .string)
        }
    }
}
