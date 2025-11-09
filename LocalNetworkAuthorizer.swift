import Foundation
import Network

/// Triggers iOS "Local Network" permission the first time you scan.
/// If the user denies, SSDP won’t return results.
enum LocalNetworkAuthorizer {
    private static var alreadyNudged = false

    static func nudgeLocalNetworkPermission() {
        guard !alreadyNudged else { return }
        alreadyNudged = true

        let params = NWParameters.udp
        let conn = NWConnection(host: "239.255.255.250", port: 1900, using: params)
        conn.stateUpdateHandler = { state in
            // We don’t need to send anything; just open then close.
            if case .ready = state { conn.cancel() }
            if case .failed = state { conn.cancel() }
        }
        conn.start(queue: .main)
    }
}

