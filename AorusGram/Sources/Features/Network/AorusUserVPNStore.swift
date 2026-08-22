import Foundation

/// One imported VLESS configuration: either a subscription that produces many servers, or a
/// hand-pasted key that produces one.
///
/// Settings live on the configuration rather than globally because a user with two of them
/// wants different answers for each — a subscription from a public channel should refresh
/// itself and pick the fastest node, a single key from a friend's private server should not be
/// touched at all.
public struct AorusVlessConfig: Codable, Equatable {
    public let id: String
    public var name: String
    /// nil when the configuration came from a pasted key list rather than a URL, in which case
    /// there is nothing to refresh from and the update controls stay hidden.
    public var subscriptionUrl: String?
    public var servers: [AorusVlessServer]
    public var updatedAt: TimeInterval
    /// Refresh the subscription in the background when it looks stale.
    public var autoUpdate: Bool
    /// After a refresh, move the selection to the lowest-latency server instead of keeping a
    /// node that may no longer exist.
    public var autoSelectFastest: Bool
    /// UDP over the tunnel. Off means the loopback SOCKS inbound refuses UDP ASSOCIATE, so
    /// anything that is not a TCP stream has no path.
    public var udpEnabled: Bool
    /// Xray's connection multiplexing. Helps on high-latency links, hurts throughput on good
    /// ones, and is ignored entirely when the server uses XTLS Vision.
    public var muxEnabled: Bool
    /// Carry voice and video call media over this configuration. Call media is UDP, so this
    /// implies `udpEnabled` and the two are kept coherent by the store.
    public var callsEnabled: Bool
    /// Bytes reported by the subscription endpoint's `Subscription-Userinfo` header, when it
    /// sends one. Absent for pasted keys and for endpoints that do not report.
    public var trafficUsed: Int64?
    public var trafficTotal: Int64?
    public var expiresAt: TimeInterval?

    public init(
        id: String,
        name: String,
        subscriptionUrl: String?,
        servers: [AorusVlessServer],
        updatedAt: TimeInterval,
        autoUpdate: Bool,
        autoSelectFastest: Bool,
        udpEnabled: Bool,
        muxEnabled: Bool,
        callsEnabled: Bool,
        trafficUsed: Int64?,
        trafficTotal: Int64?,
        expiresAt: TimeInterval?
    ) {
        self.id = id
        self.name = name
        self.subscriptionUrl = subscriptionUrl
        self.servers = servers
        self.updatedAt = updatedAt
        self.autoUpdate = autoUpdate
        self.autoSelectFastest = autoSelectFastest
        self.udpEnabled = udpEnabled
        self.muxEnabled = muxEnabled
        self.callsEnabled = callsEnabled
        self.trafficUsed = trafficUsed
        self.trafficTotal = trafficTotal
        self.expiresAt = expiresAt
    }

    /// Decoded field by field with defaults so that adding a setting in a later build does not
    /// throw away a configuration the user is currently connected through.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.subscriptionUrl = try container.decodeIfPresent(String.self, forKey: .subscriptionUrl)
        self.servers = (try? container.decode([AorusVlessServer].self, forKey: .servers)) ?? []
        self.updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? 0.0
        self.autoUpdate = try container.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
        self.autoSelectFastest = try container.decodeIfPresent(Bool.self, forKey: .autoSelectFastest) ?? false
        self.udpEnabled = try container.decodeIfPresent(Bool.self, forKey: .udpEnabled) ?? true
        self.muxEnabled = try container.decodeIfPresent(Bool.self, forKey: .muxEnabled) ?? false
        self.callsEnabled = try container.decodeIfPresent(Bool.self, forKey: .callsEnabled) ?? true
        self.trafficUsed = try container.decodeIfPresent(Int64.self, forKey: .trafficUsed)
        self.trafficTotal = try container.decodeIfPresent(Int64.self, forKey: .trafficTotal)
        self.expiresAt = try container.decodeIfPresent(TimeInterval.self, forKey: .expiresAt)
    }

    public var isSubscription: Bool {
        guard let url = self.subscriptionUrl else { return false }
        return !url.isEmpty
    }
}

/// One server a bring-up round may try, with the transport switches of the configuration it came
/// from. Carried together because a round can cross from one configuration to another, and dialling
/// a server with another card's UDP or mux setting is a connection that either fails or silently
/// behaves as the user did not ask.
public struct AorusVlessCandidate: Equatable {
    public let server: AorusVlessServer
    public let udpEnabled: Bool
    public let muxEnabled: Bool

    public init(server: AorusVlessServer, udpEnabled: Bool, muxEnabled: Bool) {
        self.server = server
        self.udpEnabled = udpEnabled
        self.muxEnabled = muxEnabled
    }
}

/// The user's own VLESS configurations, their selected server, and whether the lane is on.
///
/// Stored in `UserDefaults`, deliberately, and not in the keychain that
/// `AorusConnectionPreferences` uses. The two have opposite requirements: the connection
/// switches are meant to survive a reinstall so a user who is being filtered does not lose
/// their way back in, while an imported VPN is meant to be gone once the app is gone.
public final class AorusUserVPNStore {
    public static let shared = AorusUserVPNStore()

    public static let didChangeNotification = Notification.Name("aorusgram_uservpn_changed")

    /// Read by the MTProto override and by the call transport, both of which live in other
    /// modules and can only see `UserDefaults`. True means "this lane is live": enabled *and*
    /// pointed at a server it can actually dial. Enabled-with-nothing-selected must not read as
    /// true, or the transport would wait for an endpoint that is never coming.
    public static let enabledMirrorKey = "aorusgram_uservpn_enabled"
    /// The same predicate, narrowed by this configuration's call setting.
    public static let callsMirrorKey = "aorusgram_uservpn_calls_enabled"

    private static let suiteName = "ng.session.store"
    /// Versioned: a schema change bumps the key instead of migrating, which for a store that
    /// does not survive reinstall is the whole migration story.
    private static let stateKey = "aorusgram_uservpn_state_v1"
    private static let latencyKey = "aorusgram_uservpn_latency_v1"

    private struct Stored: Codable, Equatable {
        var enabled: Bool
        var configs: [AorusVlessConfig]
        var selectedServerId: String?

        init(enabled: Bool, configs: [AorusVlessConfig], selectedServerId: String?) {
            self.enabled = enabled
            self.configs = configs
            self.selectedServerId = selectedServerId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            self.configs = (try? container.decode([AorusVlessConfig].self, forKey: .configs)) ?? []
            self.selectedServerId = try container.decodeIfPresent(String.self, forKey: .selectedServerId)
        }
    }

    private let lock = NSLock()
    private var cached: Stored
    /// Measured round-trip times, kept out of the state blob so a probe cannot corrupt the
    /// configurations and so writing one does not rewrite everything.
    private var latencies: [String: Double]

    private init() {
        let store = UserDefaults(suiteName: Self.suiteName)
        var loaded = Stored(enabled: false, configs: [], selectedServerId: nil)
        if let data = store?.data(forKey: Self.stateKey),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            loaded = decoded
        }
        self.cached = loaded
        self.latencies = (store?.dictionary(forKey: Self.latencyKey) as? [String: Double]) ?? [:]
        // The mirrors are rewritten from the loaded state before anything can read them, so a
        // launch that follows a crash cannot leave a stale "on" behind.
        Self.writeMirrors(loaded, store: store)
    }

    // MARK: - Reads

    public var isEnabled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cached.enabled
    }

    public var configs: [AorusVlessConfig] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cached.configs
    }

    public var selectedServerId: String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cached.selectedServerId
    }

    public var selectedServer: AorusVlessServer? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Self.server(id: self.cached.selectedServerId, in: self.cached.configs)
    }

    /// The configuration the selected server belongs to — the one whose settings apply to the
    /// running core.
    public var selectedConfig: AorusVlessConfig? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let id = self.cached.selectedServerId else { return nil }
        return self.cached.configs.first { config in config.servers.contains { $0.id == id } }
    }

    /// Enabled by the user *and* able to dial something. This is what the lane's ownership of
    /// the Xray core is derived from, rather than an in-memory flag, so it reads the same at the
    /// first line of `main()` as it does an hour later.
    public var isActive: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cached.enabled && Self.server(id: self.cached.selectedServerId, in: self.cached.configs) != nil
    }

    public func latency(serverId: String) -> Double? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.latencies[serverId]
    }

    /// Only a measured winner. Falling back to the first row is useful when selecting an initial
    /// server, but it would falsely label an untested server as the fastest in the interface.
    public func bestMeasuredServerId(configId: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let config = self.cached.configs.first(where: { $0.id == configId }) else { return nil }
        return config.servers.compactMap { server -> (String, Double)? in
            guard let value = self.latencies[server.id], value > 0.0 else { return nil }
            return (server.id, value)
        }.min(by: { $0.1 < $1.1 })?.0
    }

    public func config(id: String) -> AorusVlessConfig? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cached.configs.first { $0.id == id }
    }

    // MARK: - Writes

    /// Turn the lane on or off.
    ///
    /// Turning it on with nothing selected picks a server rather than leaving the switch on and
    /// the connection absent — the user asked for a VPN, not for a second decision.
    public func setEnabled(_ value: Bool) {
        self.update { stored in
            stored.enabled = value
            if value, Self.server(id: stored.selectedServerId, in: stored.configs) == nil {
                // The lowest measured handshake across everything imported, and the first row only
                // when nothing has ever been measured. Turning the switch on used to pin the very
                // first server of the very first configuration, which in a twelve-server
                // subscription is a coin toss that stays flipped: with that one down, the retry
                // loop dials it and nothing else.
                stored.selectedServerId = self.fallbackServerId(stored, preferring: nil)
            }
        }
    }

    /// A server to fall back on when the selected one has gone: the lowest measured handshake, and
    /// the first row that exists when nothing has been measured yet.
    ///
    /// `preferring` names the configuration to look at first — the one just imported, or the one
    /// just refreshed — so a fallback lands in the list the user was working with rather than in
    /// whichever card happens to sort first. Every configuration is still searched: the old code
    /// only ever read `configs.first`, so with several imported, a first card whose server list was
    /// empty produced nil and switched the whole lane off while other cards had servers to dial.
    ///
    /// Called from inside `update`, which already holds the lock, so `latencies` is read directly:
    /// `NSLock` is not recursive.
    private func fallbackServerId(_ stored: Stored, preferring configId: String?) -> String? {
        var ordered: [AorusVlessServer] = []
        if let configId, let config = stored.configs.first(where: { $0.id == configId }) {
            ordered.append(contentsOf: config.servers)
        }
        for config in stored.configs where config.id != configId {
            ordered.append(contentsOf: config.servers)
        }
        guard !ordered.isEmpty else { return nil }
        let measured = ordered.compactMap { server -> (String, Double)? in
            guard let value = self.latencies[server.id], value > 0.0 else { return nil }
            return (server.id, value)
        }
        return measured.min(by: { $0.1 < $1.1 })?.0 ?? ordered.first?.id
    }

    public func selectServer(id: String?) {
        self.update { stored in
            guard id == nil || Self.server(id: id, in: stored.configs) != nil else { return }
            stored.selectedServerId = id
        }
    }

    /// Add an imported configuration, or fold it into the one it is an update of.
    ///
    /// Re-importing the same subscription URL replaces its server list instead of stacking a
    /// duplicate card, which is what happens when someone pastes the same link twice.
    @discardableResult
    public func addConfig(
        name: String,
        subscriptionUrl: String?,
        servers: [AorusVlessServer],
        trafficUsed: Int64? = nil,
        trafficTotal: Int64? = nil,
        expiresAt: TimeInterval? = nil
    ) -> String {
        var resultId = ""
        self.update { stored in
            let now = Date().timeIntervalSince1970
            if let url = subscriptionUrl, !url.isEmpty,
               let index = stored.configs.firstIndex(where: { $0.subscriptionUrl == url }) {
                stored.configs[index].servers = servers
                stored.configs[index].updatedAt = now
                stored.configs[index].trafficUsed = trafficUsed ?? stored.configs[index].trafficUsed
                stored.configs[index].trafficTotal = trafficTotal ?? stored.configs[index].trafficTotal
                stored.configs[index].expiresAt = expiresAt ?? stored.configs[index].expiresAt
                resultId = stored.configs[index].id
            } else {
                let config = AorusVlessConfig(
                    id: UUID().uuidString,
                    name: name,
                    subscriptionUrl: subscriptionUrl,
                    servers: servers,
                    updatedAt: now,
                    autoUpdate: subscriptionUrl != nil,
                    autoSelectFastest: false,
                    udpEnabled: true,
                    muxEnabled: false,
                    callsEnabled: true,
                    trafficUsed: trafficUsed,
                    trafficTotal: trafficTotal,
                    expiresAt: expiresAt
                )
                stored.configs.append(config)
                resultId = config.id
            }
            // Importing while the lane is on should connect, not wait for a second tap — and it
            // should connect through what was just imported rather than through the oldest card.
            if stored.enabled, Self.server(id: stored.selectedServerId, in: stored.configs) == nil {
                stored.selectedServerId = self.fallbackServerId(stored, preferring: resultId)
            }
        }
        return resultId
    }

    /// Replace a subscription's servers after a refresh.
    ///
    /// The selection is preserved by id when the node still exists — server ids are derived from
    /// the key's own contents precisely so that a refresh does not silently move the user to a
    /// different machine.
    public func replaceServers(
        configId: String,
        servers: [AorusVlessServer],
        trafficUsed: Int64?,
        trafficTotal: Int64?,
        expiresAt: TimeInterval?
    ) {
        self.update { stored in
            guard let index = stored.configs.firstIndex(where: { $0.id == configId }) else { return }
            stored.configs[index].servers = servers
            stored.configs[index].updatedAt = Date().timeIntervalSince1970
            if let value = trafficUsed { stored.configs[index].trafficUsed = value }
            if let value = trafficTotal { stored.configs[index].trafficTotal = value }
            if let value = expiresAt { stored.configs[index].expiresAt = value }
            if Self.server(id: stored.selectedServerId, in: stored.configs) == nil {
                stored.selectedServerId = self.fallbackServerId(stored, preferring: configId)
            }
        }
    }

    public func renameConfig(id: String, name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !trimmed.isEmpty else { return }
        self.update { stored in
            guard let index = stored.configs.firstIndex(where: { $0.id == id }) else { return }
            stored.configs[index].name = trimmed
        }
    }

    public func renameServer(configId: String, serverId: String, name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !trimmed.isEmpty else { return }
        self.update { stored in
            guard let configIndex = stored.configs.firstIndex(where: { $0.id == configId }),
                  let serverIndex = stored.configs[configIndex].servers.firstIndex(where: { $0.id == serverId }) else {
                return
            }
            stored.configs[configIndex].servers[serverIndex].name = trimmed
        }
    }

    public func removeConfig(id: String) {
        self.update { stored in
            stored.configs.removeAll { $0.id == id }
            if Self.server(id: stored.selectedServerId, in: stored.configs) == nil {
                stored.selectedServerId = self.fallbackServerId(stored, preferring: nil)
                // Nothing left to dial anywhere: the switch goes off with the last configuration
                // rather than staying on and doing nothing. Every other card is searched first, so
                // deleting one of several no longer turns the lane off.
                if stored.selectedServerId == nil {
                    stored.enabled = false
                }
            }
        }
    }

    public func removeServer(configId: String, serverId: String) {
        self.update { stored in
            guard let index = stored.configs.firstIndex(where: { $0.id == configId }) else { return }
            stored.configs[index].servers.removeAll { $0.id == serverId }
            if Self.server(id: stored.selectedServerId, in: stored.configs) == nil {
                stored.selectedServerId = self.fallbackServerId(stored, preferring: configId)
                if stored.selectedServerId == nil {
                    stored.enabled = false
                }
            }
        }
    }

    public func setAutoUpdate(configId: String, value: Bool) {
        self.updateConfig(id: configId) { config in config.autoUpdate = value }
    }

    public func setAutoSelectFastest(configId: String, value: Bool) {
        self.updateConfig(id: configId) { config in config.autoSelectFastest = value }
    }

    /// UDP and calls move together: call media is UDP, so leaving one on without the other
    /// produces a configuration that looks enabled and cannot carry a call.
    public func setUdpEnabled(configId: String, value: Bool) {
        self.updateConfig(id: configId) { config in
            config.udpEnabled = value
            if !value {
                config.callsEnabled = false
            }
        }
    }

    public func setCallsEnabled(configId: String, value: Bool) {
        self.updateConfig(id: configId) { config in
            config.callsEnabled = value
            if value {
                config.udpEnabled = true
            }
        }
    }

    public func setMuxEnabled(configId: String, value: Bool) {
        self.updateConfig(id: configId) { config in config.muxEnabled = value }
    }

    public func setLatency(serverId: String, value: Double?) {
        self.lock.lock()
        if let value {
            self.latencies[serverId] = value
        } else {
            self.latencies.removeValue(forKey: serverId)
        }
        let snapshot = self.latencies
        self.lock.unlock()
        UserDefaults(suiteName: Self.suiteName)?.set(snapshot, forKey: Self.latencyKey)
        self.postChange()
    }

    /// The lowest-latency server of a configuration, or its first when nothing has been
    /// measured yet.
    public func fastestServerId(configId: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let config = self.cached.configs.first(where: { $0.id == configId }) else { return nil }
        let measured = config.servers.compactMap { server -> (String, Double)? in
            guard let value = self.latencies[server.id], value > 0.0 else { return nil }
            return (server.id, value)
        }
        if let best = measured.min(by: { $0.1 < $1.1 }) {
            return best.0
        }
        return config.servers.first?.id
    }

    /// Whether an automatic choice should move the selection onto `candidate`.
    ///
    /// True when nothing is selected, when the selection no longer exists, when it has no usable
    /// measurement, or when the candidate is faster by more than `margin` of the selection's own
    /// handshake. False for the selection itself, and false for a difference inside the margin: two
    /// servers in one datacentre trade places on jitter between sweeps, and with the lane running,
    /// every move restarts the core.
    public func selectionIsWorthMoving(to candidate: String, margin: Double) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let selectedId = self.cached.selectedServerId else { return true }
        guard selectedId != candidate else { return false }
        guard Self.server(id: selectedId, in: self.cached.configs) != nil else { return true }
        guard let current = self.latencies[selectedId], current > 0.0 else { return true }
        guard let proposed = self.latencies[candidate], proposed > 0.0 else { return false }
        return proposed < current * (1.0 - margin)
    }

    /// The servers one bring-up round should try, in the order it should try them.
    ///
    /// The selection first, always: it is either what the user picked by hand or what the last
    /// successful connection settled on, and a round that starts anywhere else is a round that can
    /// move the tick off a working server. After it come the rest of its own configuration, lowest
    /// measured handshake first and unmeasured last, because a subscription is a set of routes to
    /// the same place; other configurations follow only once this one is exhausted.
    ///
    /// Each candidate carries the transport switches of the configuration it belongs to, so a
    /// failover across cards cannot dial one server with another card's UDP or mux setting.
    public func bringUpCandidates(limit: Int) -> [AorusVlessCandidate] {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard limit > 0 else { return [] }
        let configs = self.cached.configs
        guard !configs.isEmpty else { return [] }
        let selectedId = self.cached.selectedServerId
        var ordered: [AorusVlessConfig] = []
        if let selectedId,
           let owning = configs.first(where: { config in config.servers.contains { $0.id == selectedId } }) {
            ordered.append(owning)
            ordered.append(contentsOf: configs.filter { $0.id != owning.id })
        } else {
            ordered = configs
        }

        var result: [AorusVlessCandidate] = []
        var seen = Set<String>()
        for config in ordered {
            // Sorted by measured handshake, unmeasured after everything measured. `Double.infinity`
            // rather than a large constant so no real measurement can ever sort past it.
            let sorted = config.servers.sorted { first, second in
                let firstValue = self.latencies[first.id].flatMap { $0 > 0.0 ? $0 : nil } ?? .infinity
                let secondValue = self.latencies[second.id].flatMap { $0 > 0.0 ? $0 : nil } ?? .infinity
                return firstValue < secondValue
            }
            for server in sorted {
                guard !seen.contains(server.id) else { continue }
                seen.insert(server.id)
                let candidate = AorusVlessCandidate(
                    server: server,
                    udpEnabled: config.udpEnabled,
                    muxEnabled: config.muxEnabled
                )
                if server.id == selectedId {
                    result.insert(candidate, at: 0)
                } else {
                    result.append(candidate)
                }
            }
        }
        return Array(result.prefix(limit))
    }

    // MARK: - Internals

    private func updateConfig(id: String, _ transform: (inout AorusVlessConfig) -> Void) {
        self.update { stored in
            guard let index = stored.configs.firstIndex(where: { $0.id == id }) else { return }
            transform(&stored.configs[index])
        }
    }

    private func update(_ transform: (inout Stored) -> Void) {
        self.lock.lock()
        var stored = self.cached
        transform(&stored)
        guard stored != self.cached else {
            self.lock.unlock()
            return
        }
        self.cached = stored
        self.lock.unlock()

        let store = UserDefaults(suiteName: Self.suiteName)
        if let data = try? JSONEncoder().encode(stored) {
            store?.set(data, forKey: Self.stateKey)
        }
        // Written after the state, so a reader that sees the mirror on always finds a
        // configuration behind it.
        Self.writeMirrors(stored, store: store)
        self.postChange()
    }

    private static func writeMirrors(_ stored: Stored, store: UserDefaults?) {
        let active = stored.enabled && Self.server(id: stored.selectedServerId, in: stored.configs) != nil
        store?.set(active, forKey: Self.enabledMirrorKey)
        let calls: Bool
        if active, let id = stored.selectedServerId,
           let config = stored.configs.first(where: { config in config.servers.contains { $0.id == id } }) {
            calls = config.callsEnabled
        } else {
            calls = false
        }
        store?.set(calls, forKey: Self.callsMirrorKey)
    }

    private static func server(id: String?, in configs: [AorusVlessConfig]) -> AorusVlessServer? {
        guard let id else { return nil }
        for config in configs {
            if let server = config.servers.first(where: { $0.id == id }) {
                return server
            }
        }
        return nil
    }

    private func postChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            }
        }
    }
}
