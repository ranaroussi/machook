import Foundation
import Combine

/// Observable view of the local HTTP listener, mirroring `TunnelStatus`.
///
/// The listener runs in a detached `Task`, so a bind failure — almost always
/// "address already in use" because another app (or a second copy of this
/// one) holds the port — would otherwise vanish with the task and leave a
/// menu bar icon that looks perfectly healthy while nothing answers. Every
/// state change lands here so the menu and Settings can say what happened.
@MainActor
public final class ServerStatus: ObservableObject {
    public static let shared = ServerStatus()

    @Published public var isListening: Bool = false
    @Published public var port: Int = 0
    @Published public var lastError: String?

    private init() {}

    nonisolated public static func report(listening: Bool, port: Int, error: String? = nil) {
        Task { @MainActor in
            shared.isListening = listening
            shared.port = port
            shared.lastError = error
        }
    }
}
