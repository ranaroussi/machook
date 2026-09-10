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

    @Published public var publicURL: String?
    @Published public var isRunning: Bool = false

    private init() {}
}
