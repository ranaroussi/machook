import Foundation
import Combine

/// Observable view of the Cloudflare tunnel state, decoupled from
/// `TunnelManager` so SwiftUI can subscribe without us having to make
/// the manager itself an `ObservableObject` (it lives outside the main
/// actor and is poked from background process pipes).
///
/// `TunnelManager` pushes updates here via a `Task { @MainActor in … }`
/// hop whenever it parses the cloudflared subprocess output or sees the
/// process terminate. Settings UI reads via `@ObservedObject`.
@MainActor
public final class TunnelStatus: ObservableObject {
    public static let shared = TunnelStatus()

    /// Whether the published URL has been confirmed to answer.
    ///
    /// Having a URL is not the same as being reachable, and the gap between
    /// the two is not theoretical: `cloudflared` prints a quick-tunnel
    /// hostname before the DNS record exists, and Cloudflare sometimes never
    /// publishes it at all — the process looks healthy, every connectivity
    /// pre-check passes, and the hostname stays NXDOMAIN. Reporting a URL we
    /// have not tested is how the menu ends up advertising a dead endpoint.
    public enum Reachability: Equatable, Sendable {
        /// No URL yet, or the tunnel is off.
        case unknown
        /// URL known, probe in flight.
        case checking
        /// A request through the tunnel came back `200`.
        case reachable
        /// The probe failed. The string is written for a menu line.
        case unreachable(String)

        /// Stable machine-readable form for `GET /status`.
        public var statusKeyword: String {
            switch self {
            case .unknown: return "unknown"
            case .checking: return "checking"
            case .reachable: return "reachable"
            case .unreachable: return "unreachable"
            }
        }

        /// Short suffix for the menu's tunnel line, or nil when the URL
        /// alone says everything.
        public var menuNote: String? {
            switch self {
            case .unknown, .reachable: return nil
            case .checking: return "verifying…"
            case .unreachable(let why): return why
            }
        }
    }

    @Published public var publicURL: String?
    @Published public var isRunning: Bool = false
    @Published public var reachability: Reachability = .unknown

    private init() {}
}
