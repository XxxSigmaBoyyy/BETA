import Foundation
import Network

/// Everything the user's own VLESS configurations do at runtime: import, refresh, measure,
/// select, and bring the core up or down.
///
/// This is the only thing the interface talks to. The store underneath it is deliberately
/// passive — every change that the running tunnel would have to react to goes through here, so
/// there is no way to alter a setting and leave the core serving the previous one.
public final class AorusUserVPNManager {
    public static let shared = AorusUserVPNManager()

    /// Posted while a subscription fetch or a latency sweep is in flight, so the interface can
    /// show that something is happening without polling.
    public static let didChangeActivityNotification = Notification.Name("aorusgram_uservpn_activity")

    public enum ImportResult {
        case added(configId: String, servers: Int)
        case failed(AorusVlessImportError)
    }

    /// A subscription is only refetched when it is older than this. Panels rate-limit, and a
    /// list of servers that changed an hour ago is not worth a request on every screen open.
    private let subscriptionStaleInterval: TimeInterval = 6.0 * 60.0 * 60.0
    private let requestTimeout: TimeInterval = 20.0
    /// A TCP handshake that has not completed by now is not a server anyone wants to be on.
    private let latencyTimeout: TimeInterval = 3.0

    private let lock = NSLock()
    private var configsBeingUpdated = Set<String>()
    private var serversBeingProbed = Set<String>()

    private init() {}

    // MARK: - Launch

    /// Bring the user's configuration up at launch, before anything else claims the core.
    ///
    /// Called from the bootstrap ahead of the signed lane's own start: both drive one
    /// in-process Xray core, and whichever runs second has to find the first one's ownership
    /// already published rather than discover it after tearing it down.
    public func startIfEnabled() {
        guard AorusUserVPNStore.shared.isActive else { return }
        AorusRealityManager.shared.userLaneStart(reason: "app_start")
        self.refreshStaleSubscriptions()
    }

    // MARK: - The switch

    /// "Использовать VPN".
    ///
    /// Turning it on takes the no-VPN mode and stable calls down with it. Two tunnels stacked on
    /// one another is not a stronger connection: the hybrid layer would be wrapping the user's
    /// own tunnel inside a second one, doubling latency on a link that calls are supposed to
    /// survive, and both would be fighting over the same core.
    public func setEnabled(_ value: Bool) {
        guard value else {
            AorusUserVPNStore.shared.setEnabled(false)
            AorusRealityManager.shared.userLaneStop(reason: "user_disabled")
            // Hand the connection back to whatever the user's own switches say it should be.
            AorusHybridRoute.shared.evaluate(reason: "user_vpn_disabled", force: true)
            return
        }
        // Refuse an empty configuration before publishing an enabled state. This keeps the
        // native switch from briefly animating on and back off when there is nothing to dial.
        guard AorusUserVPNStore.shared.configs.contains(where: { !$0.servers.isEmpty }) else {
            AorusUserVPNStore.shared.setEnabled(false)
            return
        }
        // Ownership is published before anything is torn down. Any teardown already queued by
        // the switches below then finds the lane live and leaves the core alone.
        AorusUserVPNStore.shared.setEnabled(true)
        guard AorusUserVPNStore.shared.isActive else { return }
        if AorusConnectionPreferences.shared.bypassEnabled {
            AorusConnectionPreferences.shared.setBypassEnabled(false)
        }
        if AorusConnectionPreferences.shared.stableCallsEnabled {
            AorusConnectionPreferences.shared.setStableCallsEnabled(false)
        }
        AorusRealityManager.shared.userLaneStart(reason: "user_enabled")
        self.refreshStaleSubscriptions()
    }

    /// The other half of the exclusion: the hybrid layer coming on turns the user's VPN off.
    ///
    /// Called from the no-VPN switch rather than observed, so the two can never both be on for
    /// the length of a notification hop.
    public func bypassDidTurnOn() {
        guard AorusUserVPNStore.shared.isEnabled else { return }
        AorusUserVPNStore.shared.setEnabled(false)
        AorusRealityManager.shared.userLaneStop(reason: "bypass_enabled")
    }

    // MARK: - Selection

    public func selectServer(id: String) {
        guard AorusUserVPNStore.shared.selectedServerId != id else { return }
        AorusUserVPNStore.shared.selectServer(id: id)
        guard AorusUserVPNStore.shared.isActive else { return }
        AorusRealityManager.shared.userLaneStart(reason: "server_selected")
    }

    // MARK: - Import

    /// Import whatever the user copied.
    ///
    /// A pasted key list is stored immediately; a subscription URL is fetched first, because a
    /// card with a name and no servers is worse than an error the user can act on.
    public func importText(_ text: String, completion: @escaping (ImportResult) -> Void) {
        switch AorusVlessLink.parse(text) {
        case let .failure(error):
            self.deliver(.failed(error), to: completion)
        case let .success(value):
            switch value {
            case let .servers(servers):
                guard !self.containsEquivalentServers(servers) else {
                    self.deliver(.failed(.duplicate), to: completion)
                    return
                }
                let name = Self.configName(for: servers)
                let id = AorusUserVPNStore.shared.addConfig(
                    name: name,
                    subscriptionUrl: nil,
                    servers: servers
                )
                self.restartIfServing(configId: id)
                self.deliver(.added(configId: id, servers: servers.count), to: completion)
            case let .subscription(url):
                guard !self.containsSubscription(url) else {
                    self.deliver(.failed(.duplicate), to: completion)
                    return
                }
                self.fetchSubscription(url: url) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case let .failure(error):
                        self.deliver(.failed(error), to: completion)
                    case let .success(payload):
                        let name = payload.title ?? Self.subscriptionName(for: url)
                        let id = AorusUserVPNStore.shared.addConfig(
                            name: name,
                            subscriptionUrl: url,
                            servers: payload.servers,
                            trafficUsed: payload.trafficUsed,
                            trafficTotal: payload.trafficTotal,
                            expiresAt: payload.expiresAt
                        )
                        self.restartIfServing(configId: id)
                        self.deliver(.added(configId: id, servers: payload.servers.count), to: completion)
                    }
                }
            }
        }
    }

    // MARK: - Subscription refresh

    public func isUpdating(configId: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.configsBeingUpdated.contains(configId)
    }

    /// Refresh every subscription that has gone stale and is allowed to update itself.
    public func refreshStaleSubscriptions() {
        let now = Date().timeIntervalSince1970
        for config in AorusUserVPNStore.shared.configs {
            guard config.isSubscription, config.autoUpdate else { continue }
            guard now - config.updatedAt > self.subscriptionStaleInterval else { continue }
            self.refreshSubscription(configId: config.id, completion: nil)
        }
    }

    public func refreshSubscription(configId: String, completion: ((AorusVlessImportError?) -> Void)?) {
        guard let config = AorusUserVPNStore.shared.config(id: configId),
              let url = config.subscriptionUrl, !url.isEmpty else {
            self.deliver(.unsupported, to: completion)
            return
        }
        self.lock.lock()
        let alreadyRunning = self.configsBeingUpdated.contains(configId)
        if !alreadyRunning {
            self.configsBeingUpdated.insert(configId)
        }
        self.lock.unlock()
        guard !alreadyRunning else { return }
        self.postActivity()

        self.fetchSubscription(url: url) { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            self.configsBeingUpdated.remove(configId)
            self.lock.unlock()
            self.postActivity()

            switch result {
            case let .failure(error):
                self.deliver(error, to: completion)
            case let .success(payload):
                AorusUserVPNStore.shared.replaceServers(
                    configId: configId,
                    servers: payload.servers,
                    trafficUsed: payload.trafficUsed,
                    trafficTotal: payload.trafficTotal,
                    expiresAt: payload.expiresAt
                )
                if let refreshed = AorusUserVPNStore.shared.config(id: configId), refreshed.autoSelectFastest {
                    self.probeAllServers(configId: configId, selectFastest: true)
                } else {
                    self.restartIfServing(configId: configId)
                }
                self.deliver(nil, to: completion)
            }
        }
    }

    // MARK: - Latency

    public func isProbing(serverId: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.serversBeingProbed.contains(serverId)
    }

    /// Measure every server of a configuration, and optionally move onto the best one.
    ///
    /// This is a TCP handshake to the server's own address, not a proxied request: measuring
    /// through the core would mean starting it once per server and interrupting whatever the
    /// user is doing on the one that already works.
    public func probeAllServers(configId: String, selectFastest: Bool) {
        guard let config = AorusUserVPNStore.shared.config(id: configId) else { return }
        let servers = config.servers
        guard !servers.isEmpty else { return }

        // Reserve the entire sweep atomically. A second tap used to skip all busy rows, complete
        // an empty DispatchGroup immediately and select a server from stale partial results.
        let serverIds = Set(servers.map(\.id))
        self.lock.lock()
        let overlapsExistingSweep = !self.serversBeingProbed.isDisjoint(with: serverIds)
        if !overlapsExistingSweep {
            self.serversBeingProbed.formUnion(serverIds)
        }
        self.lock.unlock()
        guard !overlapsExistingSweep else { return }

        let group = DispatchGroup()
        for server in servers {
            group.enter()
            AorusTcpLatencyProbe.measure(
                host: server.address,
                port: server.port,
                timeout: self.latencyTimeout
            ) { [weak self] latency in
                guard let self else {
                    group.leave()
                    return
                }
                self.lock.lock()
                self.serversBeingProbed.remove(server.id)
                self.lock.unlock()
                AorusUserVPNStore.shared.setLatency(serverId: server.id, value: latency)
                group.leave()
            }
        }
        self.postActivity()
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.postActivity()
            guard selectFastest else { return }
            guard let best = AorusUserVPNStore.shared.fastestServerId(configId: configId) else { return }
            self.selectServer(id: best)
        }
    }

    // MARK: - Settings that the running core depends on

    public func setUdpEnabled(configId: String, value: Bool) {
        AorusUserVPNStore.shared.setUdpEnabled(configId: configId, value: value)
        self.restartIfServing(configId: configId)
    }

    /// Calls over this configuration. The call transport reads the mirror the store writes, so
    /// the next call picks this up; the restart is for the inbound's UDP support, which only
    /// changes when the core is rebuilt.
    public func setCallsEnabled(configId: String, value: Bool) {
        AorusUserVPNStore.shared.setCallsEnabled(configId: configId, value: value)
        self.restartIfServing(configId: configId)
    }

    public func setMuxEnabled(configId: String, value: Bool) {
        AorusUserVPNStore.shared.setMuxEnabled(configId: configId, value: value)
        self.restartIfServing(configId: configId)
    }

    public func setAutoUpdate(configId: String, value: Bool) {
        AorusUserVPNStore.shared.setAutoUpdate(configId: configId, value: value)
    }

    public func setAutoSelectFastest(configId: String, value: Bool) {
        AorusUserVPNStore.shared.setAutoSelectFastest(configId: configId, value: value)
        guard value else { return }
        self.probeAllServers(configId: configId, selectFastest: true)
    }

    private func containsEquivalentServers(_ servers: [AorusVlessServer]) -> Bool {
        // Compare transport credentials rather than persisted ids. Older app versions derived
        // ids from fewer fields, so an id-only comparison let the same key be imported again
        // after an update even though the actual VLESS handshake was identical.
        let importedServers = servers.map(Self.connectionIdentity).sorted()
        return AorusUserVPNStore.shared.configs.contains { config in
            config.subscriptionUrl == nil
                && config.servers.map(Self.connectionIdentity).sorted() == importedServers
        }
    }

    private static func connectionIdentity(_ server: AorusVlessServer) -> String {
        // Appended one field at a time rather than written as one eighteen-element literal: the
        // literal made the compiler infer the element type from `??`, a ternary and method calls
        // all at once, which it refuses to finish ("unable to type-check in reasonable time").
        var fields: [String] = []
        fields.append(server.address.lowercased())
        fields.append(String(server.port))
        fields.append(server.userId.lowercased())
        fields.append(server.flow)
        fields.append(server.network)
        fields.append(server.security)
        fields.append(server.serverName ?? "")
        fields.append(server.fingerprint ?? "")
        fields.append(server.publicKey ?? "")
        fields.append(server.shortId ?? "")
        fields.append(server.spiderX ?? "")
        fields.append(server.alpn.joined(separator: ","))
        fields.append(server.path ?? "")
        fields.append(server.host ?? "")
        fields.append(server.serviceName ?? "")
        fields.append(server.headerType ?? "")
        fields.append(server.mode ?? "")
        fields.append(server.allowInsecure ? "1" : "0")
        return fields.joined(separator: "|")
    }

    private func containsSubscription(_ value: String) -> Bool {
        guard let imported = Self.normalizedSubscriptionURL(value) else { return false }
        return AorusUserVPNStore.shared.configs.contains { config in
            guard let existing = config.subscriptionUrl,
                  let normalized = Self.normalizedSubscriptionURL(existing) else {
                return false
            }
            return normalized == imported
        }
    }

    private static func normalizedSubscriptionURL(_ value: String) -> String? {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        components.scheme = "https"
        components.host = host
        components.fragment = nil
        if components.port == 443 {
            components.port = nil
        }
        return components.string
    }

    public func rename(configId: String, name: String) {
        AorusUserVPNStore.shared.renameConfig(id: configId, name: name)
    }

    public func rename(configId: String, serverId: String, name: String) {
        AorusUserVPNStore.shared.renameServer(configId: configId, serverId: serverId, name: name)
    }

    public func removeConfig(id: String) {
        let wasServing = self.isServing(configId: id)
        AorusUserVPNStore.shared.removeConfig(id: id)
        self.reconcileAfterRemoval(wasServing: wasServing)
    }

    public func removeServer(configId: String, serverId: String) {
        let wasServing = AorusUserVPNStore.shared.selectedServerId == serverId
        AorusUserVPNStore.shared.removeServer(configId: configId, serverId: serverId)
        self.reconcileAfterRemoval(wasServing: wasServing)
    }

    // MARK: - Internals

    private func reconcileAfterRemoval(wasServing: Bool) {
        guard wasServing else { return }
        if AorusUserVPNStore.shared.isActive {
            AorusRealityManager.shared.userLaneStart(reason: "selection_removed")
        } else {
            AorusRealityManager.shared.userLaneStop(reason: "selection_removed")
            AorusHybridRoute.shared.evaluate(reason: "user_vpn_removed", force: true)
        }
    }

    private func isServing(configId: String) -> Bool {
        guard AorusUserVPNStore.shared.isActive else { return false }
        return AorusUserVPNStore.shared.selectedConfig?.id == configId
    }

    /// Rebuild the core only when the change touched the configuration currently carrying
    /// traffic. Editing a configuration the user is not on should be free.
    private func restartIfServing(configId: String) {
        guard self.isServing(configId: configId) else { return }
        AorusRealityManager.shared.userLaneStart(reason: "config_changed")
    }

    private func postActivity() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeActivityNotification, object: nil)
        }
    }

    private func deliver(_ value: ImportResult, to completion: @escaping (ImportResult) -> Void) {
        DispatchQueue.main.async { completion(value) }
    }

    private func deliver(_ value: AorusVlessImportError?, to completion: ((AorusVlessImportError?) -> Void)?) {
        guard let completion else { return }
        DispatchQueue.main.async { completion(value) }
    }

    private static func configName(for servers: [AorusVlessServer]) -> String {
        // Deliberately not localised: the name is stored, shown, and renameable by the user, so
        // it has to read the same after they switch the interface language.
        guard let first = servers.first else { return "VLESS" }
        if servers.count == 1 {
            return first.name
        }
        return first.address
    }

    private static func subscriptionName(for url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else {
            return "VLESS"
        }
        return host
    }

    // MARK: - Fetch

    private struct SubscriptionPayload {
        let servers: [AorusVlessServer]
        let title: String?
        let trafficUsed: Int64?
        let trafficTotal: Int64?
        let expiresAt: TimeInterval?
    }

    private func fetchSubscription(
        url: String,
        completion: @escaping (Result<SubscriptionPayload, AorusVlessImportError>) -> Void
    ) {
        guard let requestUrl = URL(string: url), requestUrl.scheme?.lowercased() == "https" else {
            completion(.failure(.insecureSubscription))
            return
        }
        var request = URLRequest(url: requestUrl)
        request.timeoutInterval = self.requestTimeout
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Panels branch on the user agent to decide which format to answer with; an unknown one
        // gets the base64 list, which is exactly what is parsed below.
        request.setValue("AorusGram", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = self.requestTimeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { data, response, _ in
            session.finishTasksAndInvalidate()
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
                  let data, !data.isEmpty, data.count <= 4_000_000,
                  let text = String(data: data, encoding: .utf8) else {
                completion(.failure(.malformed))
                return
            }
            var servers: [AorusVlessServer] = []
            switch AorusVlessLink.parse(text) {
            case let .success(.servers(parsed)):
                servers = parsed
            case .success(.subscription):
                // A subscription that answers with another URL is not followed: one redirect
                // level of indirection is all a paste is allowed to buy.
                completion(.failure(.unsupported))
                return
            case let .failure(error):
                completion(.failure(error))
                return
            }
            let info = Self.parseSubscriptionUserInfo(http.value(forHTTPHeaderField: "Subscription-Userinfo"))
            let title = Self.decodeProfileTitle(http.value(forHTTPHeaderField: "Profile-Title"))
            completion(.success(SubscriptionPayload(
                servers: servers,
                title: title,
                trafficUsed: info.used,
                trafficTotal: info.total,
                expiresAt: info.expire
            )))
        }
        task.resume()
    }

    /// `upload=…; download=…; total=…; expire=…`, the de facto header every panel sends.
    /// Everything in it is optional, and a missing field means "not reported" rather than zero.
    static func parseSubscriptionUserInfo(_ value: String?) -> (used: Int64?, total: Int64?, expire: TimeInterval?) {
        guard let value, !value.isEmpty else { return (nil, nil, nil) }
        var fields: [String: Int64] = [:]
        for part in value.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard let number = Int64(pair[1].trimmingCharacters(in: .whitespaces)) else { continue }
            fields[key] = number
        }
        var used: Int64?
        if fields["upload"] != nil || fields["download"] != nil {
            used = (fields["upload"] ?? 0) + (fields["download"] ?? 0)
        }
        var total: Int64?
        if let value = fields["total"], value > 0 {
            total = value
        }
        var expire: TimeInterval?
        if let value = fields["expire"], value > 0 {
            expire = TimeInterval(value)
        }
        return (used, total, expire)
    }

    /// `Profile-Title: base64:…` is how panels send a name that is not ASCII.
    private static func decodeProfileTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("base64:") {
            let encoded = String(trimmed.dropFirst("base64:".count))
            guard let decoded = AorusVlessLink.decodeBase64Text(encoded) else { return nil }
            return String(decoded.prefix(64))
        }
        return String(trimmed.prefix(64))
    }
}

/// A plain TCP handshake to a server's own address, timed.
///
/// This is what every VLESS client calls a ping, and it is worth being precise about what it
/// measures: whether the address answers and how long the three-way handshake took. It does not
/// prove the credential is valid or that the tunnel carries traffic — only the core can prove
/// that, and only for the one server it is running. As a way to order a list of fourteen nodes
/// it is exactly right, and it costs one socket per server.
enum AorusTcpLatencyProbe {
    private static let queue = DispatchQueue(label: "com.aorusgram.uservpn.latency", qos: .utility)

    /// Milliseconds, or nil when the address did not answer in time.
    static func measure(host: String, port: Int, timeout: TimeInterval, completion: @escaping (Double?) -> Void) {
        guard !host.isEmpty, let networkPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            completion(nil)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: networkPort, using: .tcp)
        let state = AorusLatencyProbeState(connection: connection, completion: completion)
        let started = Date()
        connection.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                state.finish(Date().timeIntervalSince(started) * 1000.0)
            case .failed, .cancelled:
                state.finish(nil)
            case .waiting:
                // Waiting means the path is not viable right now — retrying inside a latency
                // probe would report the retry's timing rather than the server's.
                state.finish(nil)
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: self.queue)
        self.queue.asyncAfter(deadline: .now() + timeout) {
            state.finish(nil)
        }
    }
}

/// Guarantees the completion runs once and the socket is always closed, however the connection
/// ends — a probe that leaks a connection per server is a probe that runs out of them.
private final class AorusLatencyProbeState {
    private let lock = NSLock()
    private var finished = false
    private let connection: NWConnection
    private let completion: (Double?) -> Void

    init(connection: NWConnection, completion: @escaping (Double?) -> Void) {
        self.connection = connection
        self.completion = completion
    }

    func finish(_ value: Double?) {
        self.lock.lock()
        if self.finished {
            self.lock.unlock()
            return
        }
        self.finished = true
        self.lock.unlock()
        self.connection.stateUpdateHandler = nil
        self.connection.cancel()
        self.completion(value)
    }
}
