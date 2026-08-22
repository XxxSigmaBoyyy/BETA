import Foundation
import Network
import UIKit

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

    /// A subscription is only refetched when it is older than this. Short enough that the traffic
    /// counter on the card is the panel's own number rather than yesterday's, long enough that a
    /// screen opened ten times in a row is still one request.
    private let subscriptionStaleInterval: TimeInterval = 15.0 * 60.0
    /// How often the background tick goes looking for a stale subscription. The tick itself costs
    /// nothing when everything is fresh — it is a comparison per card.
    private let autoUpdateTickInterval: TimeInterval = 5.0 * 60.0
    private let requestTimeout: TimeInterval = 20.0
    /// A TCP handshake that has not completed by now is not a server anyone wants to be on.
    private let latencyTimeout: TimeInterval = 3.0
    /// How often the connection screen's own sweep may run. Long enough that opening the screen
    /// twice is one sweep, short enough that a list left open catches a server coming back.
    private let visibleSweepInterval: TimeInterval = 30.0
    /// How much faster a server has to be before an automatic choice moves onto it, as a share of
    /// the selected server's own handshake. Two nodes in one datacentre differ by jitter alone from
    /// sweep to sweep, and with the lane up every move is a core restart.
    private let reselectMargin: Double = 0.25

    private let lock = NSLock()
    private var configsBeingUpdated = Set<String>()
    private var serversBeingProbed = Set<String>()
    private var lastVisibleSweepAt: TimeInterval = 0.0
    /// The tick that makes "Обновлять автоматически" mean something while the app is open.
    private let autoUpdateQueue = DispatchQueue(label: "aorusgram.uservpn.autoupdate", qos: .utility)
    private var autoUpdateTimer: DispatchSourceTimer?
    private var foregroundObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Launch

    /// Bring the user's configuration up at launch, before anything else claims the core.
    ///
    /// Called from the bootstrap ahead of the signed lane's own start: both drive one
    /// in-process Xray core, and whichever runs second has to find the first one's ownership
    /// already published rather than discover it after tearing it down.
    public func startIfEnabled() {
        // Auto-update is deliberately outside the guard below. A card whose traffic counter is a
        // day out of date is wrong whether or not the lane happens to be carrying traffic right
        // now, and the switch says "Обновлять автоматически", not "обновлять пока подключено".
        self.startAutoUpdate()
        self.refreshStaleSubscriptions()
        guard AorusUserVPNStore.shared.isActive else { return }
        AorusRealityManager.shared.userLaneStart(reason: "app_start")
    }

    /// The periodic tick, plus a refresh every time the app comes back to the foreground.
    ///
    /// Both are needed: the timer does not fire while the app is suspended, so a client left in the
    /// background overnight would otherwise show yesterday's numbers until it happened to tick, and
    /// a client left open in the foreground would never refresh without the timer.
    private func startAutoUpdate() {
        self.lock.lock()
        let alreadyStarted = self.autoUpdateTimer != nil
        self.lock.unlock()
        guard !alreadyStarted else { return }

        let timer = DispatchSource.makeTimerSource(queue: self.autoUpdateQueue)
        timer.schedule(
            deadline: .now() + self.autoUpdateTickInterval,
            repeating: self.autoUpdateTickInterval,
            leeway: .seconds(30)
        )
        timer.setEventHandler { [weak self] in
            self?.refreshStaleSubscriptions()
        }
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshStaleSubscriptions()
        }
        self.lock.lock()
        self.autoUpdateTimer = timer
        self.foregroundObserver = observer
        self.lock.unlock()
        timer.resume()
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
        // Measure straight away, so the list shows real numbers rather than nothing, and so a
        // configuration set to choose for itself gets to.
        self.measureVisibleServers()
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

    /// Move onto a server, and connect through it now rather than at the next opportunity.
    ///
    /// The store is written first and the bring-up asked for second, so the lane reads the new
    /// selection rather than being told which server to use — there is one source of truth for what
    /// is selected. A round already in flight is cut short by `userLaneStart`, which is what makes
    /// the switch immediate instead of "after the previous walk finishes".
    ///
    /// A tap on the row that is already ticked is not ignored either. When the lane is not carrying
    /// traffic through that exact server, the row is the only thing on the screen the user can press
    /// to try again, so it starts a bring-up; when it is already serving it, there is nothing to do.
    public func selectServer(id: String) {
        let alreadySelected = AorusUserVPNStore.shared.selectedServerId == id
        if !alreadySelected {
            AorusUserVPNStore.shared.selectServer(id: id)
        }
        guard AorusUserVPNStore.shared.isActive else { return }
        if alreadySelected, AorusRealityManager.shared.userLaneServingServer == id {
            return
        }
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
            case let .subscriptions(urls):
                let fresh = urls.filter { !self.containsSubscription($0) }
                guard !fresh.isEmpty else {
                    self.deliver(.failed(.duplicate), to: completion)
                    return
                }
                self.importSubscriptions(
                    fresh,
                    index: 0,
                    addedConfigId: nil,
                    addedServers: 0,
                    firstError: nil,
                    completion: completion
                )
            }
        }
    }

    /// Fetch a list of subscription URLs one after another, adding a card for each.
    ///
    /// Sequential rather than concurrent, because the order the cards appear in should be the order
    /// they were written in, and because a paste out of a channel can carry a dozen links and this
    /// is not a reason to open a dozen connections at once. A failure is only reported when nothing
    /// at all could be added: one dead link among four is not a failed import.
    private func importSubscriptions(
        _ urls: [String],
        index: Int,
        addedConfigId: String?,
        addedServers: Int,
        firstError: AorusVlessImportError?,
        completion: @escaping (ImportResult) -> Void
    ) {
        guard index < urls.count else {
            if let addedConfigId {
                self.deliver(.added(configId: addedConfigId, servers: addedServers), to: completion)
            } else {
                self.deliver(.failed(firstError ?? .malformed), to: completion)
            }
            return
        }
        let url = urls[index]
        self.fetchSubscription(url: url) { [weak self] result in
            guard let self else { return }
            var configId = addedConfigId
            var servers = addedServers
            var error = firstError
            switch result {
            case let .failure(fetchError):
                error = error ?? fetchError
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
                configId = configId ?? id
                servers += payload.servers.count
            }
            self.importSubscriptions(
                urls,
                index: index + 1,
                addedConfigId: configId,
                addedServers: servers,
                firstError: error,
                completion: completion
            )
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

    /// Measure the servers the connection screen is showing.
    ///
    /// Nothing else on that screen would ever ask for a measurement, and measurements are what
    /// "Лучший сервер" and the fastest-server choice are made of: without this the label could not
    /// appear and the choice had nothing to choose from, which is exactly how it looked.
    ///
    /// Every configuration is swept, not just the selected one. With two subscriptions imported, the
    /// cards that were not selected had no numbers at all — no "Лучший сервер", nothing to order the
    /// list by, and nothing for a cross-configuration failover to prefer.
    ///
    /// The winner is selected only for a configuration set to choose for itself, and only when the
    /// user is already on that configuration. A card choosing for itself must not pull the selection
    /// out of another card that the user picked by hand. A lane that is on and not yet carrying
    /// traffic is *not* a reason to move the selection either: bringing a server up already walks
    /// past the ones that will not answer, and moving the tick as well is how the chosen server
    /// appeared to change on its own with auto-select switched off.
    public func measureVisibleServers() {
        let configs = AorusUserVPNStore.shared.configs
        guard !configs.isEmpty else { return }
        // A sweep is one TCP handshake per server and a screen can be pushed and popped as fast as a
        // finger moves, so it is rate-limited rather than tied to the appearance itself.
        let now = Date().timeIntervalSince1970
        self.lock.lock()
        let due = now - self.lastVisibleSweepAt >= self.visibleSweepInterval
        if due {
            self.lastVisibleSweepAt = now
        }
        self.lock.unlock()
        guard due else { return }

        let selected = AorusUserVPNStore.shared.selectedServerId
        for config in configs where !config.servers.isEmpty {
            let ownsSelection = selected == nil || config.servers.contains { $0.id == selected }
            self.probeAllServers(
                configId: config.id,
                selectFastest: config.autoSelectFastest && ownsSelection
            )
        }
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
            // Only when the winner is meaningfully better than what is selected. Handshake times to
            // two servers in the same datacentre differ by a few milliseconds of jitter from one
            // sweep to the next, so a bare minimum reselects on noise -- and with the lane running,
            // every reselection is a core restart, which is a connection that never settles.
            guard AorusUserVPNStore.shared.selectionIsWorthMoving(to: best, margin: self.reselectMargin) else {
                return
            }
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
        // Turning it on is itself a request for an update: the user turned it on because what the
        // card is showing is out of date.
        guard value else { return }
        self.refreshSubscription(configId: configId, completion: nil)
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
        fields.append(server.proto)
        fields.append(server.address.lowercased())
        fields.append(String(server.port))
        fields.append(server.credential)
        fields.append(server.encryption)
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
        // it has to read the same after they switch the interface language. The fallbacks name the
        // protocol that was imported rather than saying "VLESS" over a VMess or Trojan card.
        guard let first = servers.first else { return "Proxy" }
        if servers.count == 1 {
            return first.name
        }
        return first.address
    }

    private static func subscriptionName(for url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else {
            return "Subscription"
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

    /// One way of asking a panel for a subscription.
    ///
    /// A panel decides which notation to answer in from the user agent alone — nothing the request
    /// can say chooses it — so asking is the only way to find out what a given panel will serve.
    private struct SubscriptionProfile {
        let userAgent: String
        let accept: String
    }

    /// The clients this fetch presents itself as, in the order it tries them.
    ///
    /// Measured against a live Remnawave panel: `v2rayN` is answered with the base64 list of links,
    /// `Happ` with an array of Xray configurations, `SFI` with a sing-box configuration and `Clash`
    /// with YAML. All four are read by the parser, so the ladder exists for the panels that answer
    /// only some of these — a template that has no branch for one client answers it with a stub or
    /// with nothing, and the next profile is what turns that into a working import.
    ///
    /// The list is walked only until a body yields servers, so the common case is one request.
    private static let subscriptionProfiles: [SubscriptionProfile] = [
        SubscriptionProfile(userAgent: "v2rayN/6.45", accept: "text/plain, */*"),
        SubscriptionProfile(userAgent: "Happ/2.20.0", accept: "application/json, text/plain, */*"),
        SubscriptionProfile(userAgent: "SFI/1.10.0", accept: "application/json, text/plain, */*"),
        SubscriptionProfile(userAgent: "Clash/2.0", accept: "text/yaml, text/plain, */*")
    ]

    /// The device identity a panel with hardware-id enforcement demands.
    ///
    /// With `x-hwid-active` on, a panel answers a request that carries no device headers with a
    /// single unusable placeholder link — the "Приложение не поддерживается" node — for *every*
    /// client, which is exactly what an import of such a link looked like from the inside: one key
    /// pointing at 0.0.0.0:1, correctly refused, and no way for the user to tell why.
    ///
    /// The identifier is stable across reinstalls, because a panel counts devices and a value that
    /// changed on every launch would burn through the account's device limit. It is derived from the
    /// install id under its own domain separator rather than reusing the licence device hash, so a
    /// subscription host cannot correlate the two.
    private static func subscriptionHardwareId() -> String {
        var input = Data("aorus-uservpn-hwid".utf8)
        input.append(0x1f)
        input.append(Data(DeviceFingerprint.keychainInstallId().utf8))
        return String(LicenseCrypto.sha256Hex(input).prefix(32))
    }

    /// The hardware string, `iPhone15,3`, which is what other clients report here.
    private static func deviceModelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafePointer(to: &info.machine) { pointer -> String in
            return pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { text in
                return String(cString: text)
            }
        }
        return identifier.isEmpty ? "iPhone" : identifier
    }

    private func fetchSubscription(
        url: String,
        completion: @escaping (Result<SubscriptionPayload, AorusVlessImportError>) -> Void
    ) {
        guard let requestUrl = URL(string: url), requestUrl.scheme?.lowercased() == "https" else {
            completion(.failure(.insecureSubscription))
            return
        }
        self.fetchSubscription(requestUrl: requestUrl, profileIndex: 0, firstError: nil, completion: completion)
    }

    private func fetchSubscription(
        requestUrl: URL,
        profileIndex: Int,
        firstError: AorusVlessImportError?,
        completion: @escaping (Result<SubscriptionPayload, AorusVlessImportError>) -> Void
    ) {
        guard profileIndex < Self.subscriptionProfiles.count else {
            completion(.failure(firstError ?? .malformed))
            return
        }
        let profile = Self.subscriptionProfiles[profileIndex]
        var request = URLRequest(url: requestUrl)
        request.timeoutInterval = self.requestTimeout
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(profile.accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.subscriptionHardwareId(), forHTTPHeaderField: "x-hwid")
        request.setValue("iOS", forHTTPHeaderField: "x-device-os")
        request.setValue(UIDevice.current.systemVersion, forHTTPHeaderField: "x-ver-os")
        request.setValue(Self.deviceModelIdentifier(), forHTTPHeaderField: "x-device-model")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = self.requestTimeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            guard let http = response as? HTTPURLResponse, error == nil else {
                // Nothing answered. Asking again as a different client would only spend another
                // timeout on the same unreachable host.
                completion(.failure(firstError ?? .malformed))
                return
            }
            switch Self.subscriptionPayload(data: data, response: http) {
            case let .success(payload):
                completion(.success(payload))
            case let .failure(failure):
                guard failure != .deviceLimit else {
                    // The account is out of device slots. Every client profile is answered with the
                    // same placeholder list, so there is nothing to gain from asking again.
                    completion(.failure(failure))
                    return
                }
                guard let self else {
                    completion(.failure(firstError ?? failure))
                    return
                }
                // The host is up and answered something this notation could not be read out of, so
                // the next client profile is worth a request.
                self.fetchSubscription(
                    requestUrl: requestUrl,
                    profileIndex: profileIndex + 1,
                    firstError: firstError ?? failure,
                    completion: completion
                )
            }
        }
        task.resume()
    }

    /// One subscription response as servers plus the counters the card shows.
    private static func subscriptionPayload(
        data: Data?,
        response: HTTPURLResponse
    ) -> Result<SubscriptionPayload, AorusVlessImportError> {
        guard (200 ..< 300).contains(response.statusCode),
              let data, !data.isEmpty, data.count <= 4_000_000,
              let text = String(data: data, encoding: .utf8) else {
            return .failure(.malformed)
        }
        // A panel that has run out of device slots answers every client with a list of placeholder
        // nodes that cannot connect, and says so only in this header. Without reading it the import
        // would fail as "damaged key" and the user would have no way to learn what is actually
        // wrong with their account.
        //
        // Read as the *reason* a response carried nothing usable rather than as a refusal of its
        // own: a panel configured to keep serving while over the limit sends the header next to a
        // real server list, and refusing that would break a subscription that works.
        let limitField = (response.value(forHTTPHeaderField: "x-hwid-max-devices-reached") ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let limitReached = limitField == "true" || limitField == "1"
        var servers: [AorusVlessServer] = []
        switch AorusVlessLink.parse(text) {
        case let .success(.servers(parsed)):
            servers = parsed
        case .success(.subscriptions):
            // A subscription that answers with another URL is not followed: one redirect
            // level of indirection is all a paste is allowed to buy.
            return .failure(limitReached ? .deviceLimit : .unsupported)
        case let .failure(error):
            return .failure(limitReached ? .deviceLimit : error)
        }
        guard !servers.isEmpty else {
            return .failure(limitReached ? .deviceLimit : .malformed)
        }
        let info = parseSubscriptionUserInfo(response.value(forHTTPHeaderField: "Subscription-Userinfo"))
        let title = decodeProfileTitle(response.value(forHTTPHeaderField: "Profile-Title"))
        return .success(SubscriptionPayload(
            servers: servers,
            title: title,
            trafficUsed: info.used,
            trafficTotal: info.total,
            expiresAt: info.expire
        ))
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
