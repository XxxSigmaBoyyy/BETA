import Foundation
import Network

/// Which route this process has decided to carry MTProto over.
public enum AorusRouteMode: String, Equatable {
    /// Nothing has been measured yet in this process.
    case unknown
    /// Telegram reaches its datacentres without help, so the core stays down and whatever
    /// proxy the user configured themselves keeps working.
    case direct
    /// Direct is blocked; the signed profile and the endpoint race are on their way.
    case escalating
    /// A local inbound is up and proven end to end, and MTProto is pinned to it.
    case tunnel
    /// Direct is blocked and the tunnel could not be brought up. The client stays on its
    /// own route rather than on a port with nothing behind it.
    case unavailable
}

/// Decides, at app start and on every network change, whether this client needs its tunnel
/// at all — and is the only thing that can tell Telegram that it does.
///
/// The previous behaviour published `required: true` for every provisioned user the moment
/// the app launched, which pinned MTProto to a reserved loopback port. While the tunnel was
/// up that is exactly right. When every signed bridge was blocked it was a client with no
/// network at all: the override kept sending Telegram to a port nothing was listening on.
///
/// So the requirement is now a pure function of a measured route:
///
///   app start / network change → probe Telegram directly, no tunnel involved
///     reachable   → `.direct`, requirement released, core stood down
///     unreachable → `.escalating`, requirement still released, provisioning + endpoint race
///       first proven endpoint  → `.tunnel`, requirement taken, Telegram pinned to loopback
///       whole ladder exhausted → `.unavailable`, requirement released, retry ladder runs
///
/// The invariant that matters: `required` is true only while a proven local inbound exists.
/// Every other state fails open, which is worse for censorship resistance for the seconds it
/// takes to bring the tunnel up and immeasurably better than a client that cannot connect.
///
/// The probe is an optimisation, not the authority. A TCP handshake to port 443 completes on
/// plenty of networks that then drop the session, so the MTProto engine gets the final word
/// through `directRouteDidStall()`.
public final class AorusHybridRoute {
    public static let shared = AorusHybridRoute()

    /// Posted on the main queue after the mode changes.
    public static let didChangeNotification = Notification.Name("aorusgram_hybrid_route_changed")

    /// Telegram production frontends, one per datacentre. Public addresses that the client
    /// already carries in its own DC configuration, so probing them reveals nothing that
    /// running the app does not.
    private static let directTargets: [(host: String, port: UInt16)] = [
        ("149.154.167.50", 443),
        ("149.154.175.50", 443),
        ("149.154.171.5", 443)
    ]
    /// Two of the three. One address can be greylisted, or reachable on a network where the
    /// others are not, and neither verdict should rest on a single socket.
    private static let requiredDirectSuccesses = 2

    /// The whole verdict costs at most this long, because it is on the launch path.
    private let directProbeTimeout: TimeInterval = 2.5
    /// How long an established connection has to survive before it counts. A filtering
    /// middlebox that accepts the handshake and resets the flow a moment later reads as a
    /// working route for exactly as long as nobody looks.
    private let directHoldInterval: TimeInterval = 0.35
    /// How long direct loses the benefit of the doubt after the MTProto engine stalled on it.
    private let directPenaltyInterval: TimeInterval = 600.0
    /// Repeated path callbacks for one physical change are common; a verdict this fresh is
    /// still the answer.
    private let evaluationCooldown: TimeInterval = 5.0

    private let stateQueue = DispatchQueue(label: "com.aorusgram.route", qos: .userInitiated)
    private let probeQueue = DispatchQueue(label: "com.aorusgram.route.probe", qos: .userInitiated)
    private let lock = NSLock()
    private var currentMode: AorusRouteMode = .unknown
    private var evaluationInFlight = false
    private var lastEvaluationAt: TimeInterval = 0
    private var directUnreliableUntil: TimeInterval = 0
    private var preferencesObserver: NSObjectProtocol?

    private init() {}

    public var mode: AorusRouteMode {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.currentMode
    }

    /// What the settings screen shows: a route that is carrying traffic, whether it needed the
    /// tunnel to do it or not.
    public var isRouteEstablished: Bool {
        switch self.mode {
        case .direct, .tunnel:
            return true
        case .unknown, .escalating, .unavailable:
            return false
        }
    }

    /// The single input Telegram's MTProto override takes from this class.
    var tunnelIsRequired: Bool {
        return self.mode == .tunnel
    }

    /// Whether provisioning and the endpoint race may run at all. Only a measured direct
    /// route stops them: an unfinished verdict must never be able to strand a blocked client.
    var allowsTunnelBringUp: Bool {
        switch self.mode {
        case .direct:
            return false
        case .unknown, .escalating, .tunnel, .unavailable:
            return true
        }
    }

    // MARK: - Decision points

    /// The two moments from the design: APP START and NETWORK CHANGED.
    public func evaluate(reason: String, force: Bool = false) {
        self.stateQueue.async { [weak self] in
            self?.beginEvaluation(reason: reason, force: force)
        }
    }

    /// A path change is also the one moment a network that used to be hostile deserves a
    /// fresh look, so the direct penalty is dropped here.
    func networkDidChange() {
        self.lock.lock()
        self.directUnreliableUntil = 0
        self.lock.unlock()
        self.evaluate(reason: "network_changed", force: true)
    }

    /// The MTProto engine has been unhealthy long enough while on the direct route. Direct is
    /// wrong on this network however well it probes, so it is penalised and the tunnel takes
    /// over.
    func directRouteDidStall() {
        self.lock.lock()
        guard self.currentMode == .direct else {
            self.lock.unlock()
            return
        }
        self.directUnreliableUntil = Date().timeIntervalSince1970 + self.directPenaltyInterval
        self.lock.unlock()
        AorusRealityManager.shared.recordProxyEvent(
            stage: "route_direct_stalled",
            errorCode: "mtproto_unhealthy_on_direct"
        )
        self.escalate(reason: "direct_stalled")
    }

    /// A local inbound is up and proven. This is the only path to `required: true`.
    func tunnelDidActivate() {
        self.setMode(.tunnel, reason: "endpoint_published")
    }

    /// Every signed endpoint failed. The retry ladder keeps running, but Telegram is let go
    /// of in the meantime.
    func tunnelDidExhaustEndpoints() {
        switch self.mode {
        case .escalating, .tunnel, .unknown:
            self.setMode(.unavailable, reason: "all_endpoints_failed")
        case .direct, .unavailable:
            break
        }
    }

    /// The core was stopped. In direct mode that was this class's own doing and changes
    /// nothing; anywhere else it means there is no tunnel to point Telegram at.
    func tunnelDidStandDown() {
        guard self.mode != .direct else { return }
        self.setMode(.unavailable, reason: "core_stopped")
    }

    /// The tunnel is off for reasons outside the route decision — license lock, or the user
    /// turning "Режим без VPN" off.
    func standDown(reason: String) {
        self.setMode(.unavailable, reason: reason)
    }

    // MARK: - Evaluation

    private func beginEvaluation(reason: String, force: Bool) {
        self.startObservingPreferences()
        guard AorusConnectionPreferences.shared.bypassEnabled else {
            self.setMode(.unavailable, reason: "bypass_disabled")
            return
        }
        let now = Date().timeIntervalSince1970
        self.lock.lock()
        if self.evaluationInFlight {
            self.lock.unlock()
            return
        }
        if !force, now - self.lastEvaluationAt < self.evaluationCooldown {
            self.lock.unlock()
            return
        }
        self.evaluationInFlight = true
        self.lastEvaluationAt = now
        let penalized = self.directUnreliableUntil > now
        self.lock.unlock()

        if penalized {
            AorusRealityManager.shared.recordProxyEvent(
                stage: "route_direct_skipped",
                errorCode: "direct_penalized",
                detail: "reason=\(reason)"
            )
            self.finishEvaluation(directWorks: false, reason: reason)
            return
        }
        AorusRealityManager.shared.recordProxyEvent(stage: "route_probe_started", detail: "reason=\(reason)")
        self.probeDirectRoute { [weak self] directWorks in
            guard let self else { return }
            self.stateQueue.async { [weak self] in
                self?.finishEvaluation(directWorks: directWorks, reason: reason)
            }
        }
    }

    private func finishEvaluation(directWorks: Bool, reason: String) {
        self.lock.lock()
        self.evaluationInFlight = false
        self.lastEvaluationAt = Date().timeIntervalSince1970
        self.lock.unlock()

        guard directWorks else {
            AorusRealityManager.shared.recordProxyEvent(
                stage: "route_direct_blocked",
                errorCode: "telegram_direct_unreachable",
                detail: "reason=\(reason)"
            )
            self.escalate(reason: reason)
            return
        }
        AorusRealityManager.shared.recordProxyEvent(stage: "route_direct_ok", detail: "reason=\(reason)")
        self.setMode(.direct, reason: reason)
        AorusRealityManager.shared.standDownForDirectRoute()
    }

    private func escalate(reason: String) {
        // An account that may not run the tunnel has nothing to escalate to. Saying so keeps
        // the settings screen honest instead of spinning forever.
        guard AorusRealityManager.shared.tunnelIsAuthorized else {
            self.setMode(.unavailable, reason: "tunnel_not_authorized")
            return
        }
        self.setMode(.escalating, reason: reason)
        AorusProxyManager.shared.beginTunnelEscalation(reason: reason)
    }

    private func setMode(_ next: AorusRouteMode, reason: String) {
        self.lock.lock()
        guard self.currentMode != next else {
            self.lock.unlock()
            return
        }
        self.currentMode = next
        self.lock.unlock()
        AorusRealityManager.shared.recordProxyEvent(
            stage: "route_mode_changed",
            detail: "mode=\(next.rawValue) reason=\(reason)"
        )
        // Order matters at exactly one transition: `publishEndpoint` writes the live port
        // before it reports the activation, so an observer woken by this can never see a
        // requirement without a port behind it.
        AorusRealityManager.shared.routeModeDidChange()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    // MARK: - Preferences

    private func startObservingPreferences() {
        self.lock.lock()
        guard self.preferencesObserver == nil else {
            self.lock.unlock()
            return
        }
        let observer = NotificationCenter.default.addObserver(
            forName: AorusConnectionPreferences.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.preferencesDidChange()
        }
        self.preferencesObserver = observer
        self.lock.unlock()
    }

    private func preferencesDidChange() {
        guard AorusConnectionPreferences.shared.bypassEnabled else {
            self.standDown(reason: "bypass_disabled")
            AorusProxyManager.shared.bypassDidTurnOff()
            return
        }
        self.setMode(.unknown, reason: "bypass_enabled")
        self.evaluate(reason: "bypass_enabled", force: true)
    }

    // MARK: - Direct probe

    private func probeDirectRoute(completion: @escaping (Bool) -> Void) {
        let resultLock = NSLock()
        var successes = 0
        let group = DispatchGroup()
        for target in Self.directTargets {
            group.enter()
            self.probeDirectTarget(target) { reachable in
                resultLock.lock()
                if reachable {
                    successes += 1
                }
                resultLock.unlock()
                group.leave()
            }
        }
        group.notify(queue: self.probeQueue) {
            resultLock.lock()
            let reached = successes
            resultLock.unlock()
            completion(reached >= Self.requiredDirectSuccesses)
        }
    }

    private func probeDirectTarget(_ target: (host: String, port: UInt16), completion: @escaping (Bool) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: target.port) else {
            completion(false)
            return
        }
        // Plain TCP with no proxy of our own: the question is whether Telegram can reach this
        // address the way the app itself would. A VPN the user configured is part of that
        // answer and is deliberately not excluded.
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        let finishLock = NSLock()
        var finished = false
        var holdItem: DispatchWorkItem?
        let finish: (Bool) -> Void = { reachable in
            finishLock.lock()
            guard !finished else {
                finishLock.unlock()
                return
            }
            finished = true
            let pendingHold = holdItem
            holdItem = nil
            finishLock.unlock()
            pendingHold?.cancel()
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(reachable)
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                finishLock.lock()
                guard holdItem == nil else {
                    finishLock.unlock()
                    return
                }
                let item = DispatchWorkItem { finish(true) }
                holdItem = item
                finishLock.unlock()
                self.probeQueue.asyncAfter(deadline: .now() + self.directHoldInterval, execute: item)
            case .failed(_):
                finish(false)
            case .cancelled:
                finish(false)
            default:
                // `.waiting` is a route that has not given up yet: the budget below decides.
                break
            }
        }
        connection.start(queue: self.probeQueue)
        self.probeQueue.asyncAfter(deadline: .now() + self.directProbeTimeout) {
            finish(false)
        }
    }
}
