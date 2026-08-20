import Foundation
import TelegramCore

private let aorusCallProxyDiagnosticKey = "aorusgram_call_proxy_diagnostics"
private let aorusRealityEndpointKey = "71d447f8-9128-4d18-b63c-ec11ef43ba26"
private let aorusRealityRequirementKey = "b4f013e2-54e9-4e4d-b2e1-30edc1e5b7ca"
private let aorusClosedProxyPort: Int32 = 38_190

private func aorusRecordCallProxyDiagnostic(
    store: UserDefaults,
    status: String,
    host: String = "",
    port: Int32 = 0,
    udp: String = "unknown",
    authentication: Bool = false,
    expiresAt: TimeInterval = 0.0
) {
    store.set([
        "status": status,
        "checkedAt": Date().timeIntervalSince1970,
        "host": host,
        "port": Int(port),
        "udp": udp,
        "authentication": authentication,
        "expiresAt": expiresAt,
    ], forKey: aorusCallProxyDiagnosticKey)
}

/// A mirrored AorusGram connection switch that the user has explicitly turned off.
///
/// Absent is not the same as off: it means this process has not yet copied the switches out of
/// the keychain, and the fail-closed defaults below depend on not confusing the two.
private func aorusConnectionSwitchIsOff(store: UserDefaults, key: String) -> Bool {
    guard store.object(forKey: key) != nil else { return false }
    return !store.bool(forKey: key)
}

// AorusGram: use the same in-process VLESS/REALITY loopback SOCKS endpoint for calls.
// The marker is process-bound, so a value persisted by an earlier launch can never
// route a call into a dead local port while libXray is still starting.
public func aorusCallProxyServerSettings() -> ProxyServerSettings? {
    guard let store = UserDefaults(suiteName: "ng.session.store") else {
        // The subscription verdict cannot be read safely, so never risk a direct
        // media route. A valid no-subscription state is explicitly published below.
        return ProxyServerSettings(
            host: "127.0.0.1",
            port: aorusClosedProxyPort,
            connection: .socks5(username: nil, password: nil)
        )
    }
    // The user's own imported VLESS configuration owns the transport. Its two switches replace
    // the hybrid lane's, which say nothing about it: "Режим без VPN" is off by construction
    // whenever this lane is on, so consulting it would send every call around the tunnel the
    // user explicitly asked to make calls over.
    if store.bool(forKey: "aorusgram_uservpn_enabled") {
        // Call media is UDP, and it only has a path when the loopback inbound was built with UDP
        // support. The store keeps the two settings coherent, so this one flag answers both.
        if !store.bool(forKey: "aorusgram_uservpn_calls_enabled") {
            aorusRecordCallProxyDiagnostic(store: store, status: "native_user_vpn_calls_disabled")
            return nil
        }
    } else {
        // "Режим без VPN" off: nothing of this client's transport is used at all.
        if aorusConnectionSwitchIsOff(store: store, key: "aorusgram_connection_bypass_enabled") {
            aorusRecordCallProxyDiagnostic(store: store, status: "native_bypass_disabled")
            return nil
        }
        // "Стабильные звонки" off: call media goes natively even while MTProto is being carried
        // over the tunnel. The two are separate on purpose — UDP over the tunnel is what makes a
        // call survive a filtered network, and also the part a user is most likely to want off.
        if aorusConnectionSwitchIsOff(store: store, key: "aorusgram_connection_stable_calls_enabled") {
            aorusRecordCallProxyDiagnostic(store: store, status: "native_stable_calls_disabled")
            return nil
        }
    }
    let currentPid = ProcessInfo.processInfo.processIdentifier
    let requirement = store.dictionary(forKey: aorusRealityRequirementKey)
    let requirementPid = requirement?["pid"] as? NSNumber
    let required = requirement?["required"] as? NSNumber
    if requirementPid?.int32Value == currentPid,
       required?.boolValue == false {
        aorusRecordCallProxyDiagnostic(store: store, status: "direct_without_subscription")
        return nil
    }
    guard let endpoint = store.dictionary(forKey: aorusRealityEndpointKey),
          let pid = endpoint["pid"] as? NSNumber,
          pid.int32Value == currentPid,
          requirementPid?.int32Value == currentPid,
          required?.boolValue == true,
          let portValue = endpoint["port"] as? NSNumber,
          (1 ... 65_535).contains(portValue.intValue) else {
        aorusRecordCallProxyDiagnostic(
            store: store,
            status: "reality_required_not_ready",
            host: "127.0.0.1",
            port: aorusClosedProxyPort,
            udp: "blocked"
        )
        // Active subscription or an unreadable/stale verdict: keep calls
        // fail-closed until the current process publishes a live endpoint.
        return ProxyServerSettings(
            host: "127.0.0.1",
            port: aorusClosedProxyPort,
            connection: .socks5(username: nil, password: nil)
        )
    }
    let port = Int32(portValue.intValue)
    aorusRecordCallProxyDiagnostic(
        store: store,
        status: "reality_ready",
        host: "127.0.0.1",
        port: port,
        udp: "xudp",
        authentication: false
    )
    return ProxyServerSettings(host: "127.0.0.1", port: port, connection: .socks5(username: nil, password: nil))
}
