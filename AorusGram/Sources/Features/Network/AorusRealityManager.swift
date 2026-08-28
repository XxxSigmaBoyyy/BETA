import Foundation
import LibXray
import Network

private enum AorusSocksProbeResult: Equatable {
    case ready
    case localConnectFailed
    case localConnectTimedOut
    case negotiationFailed
    case negotiationTimedOut
    case tunnelConnectFailed(UInt8)
    case tunnelConnectTimedOut

    var diagnosticCode: String? {
        switch self {
        case .ready:
            return nil
        case .localConnectFailed:
            return "local_socks_connect_failed"
        case .localConnectTimedOut:
            return "local_socks_connect_timeout"
        case .negotiationFailed:
            return "local_socks_negotiation_failed"
        case .negotiationTimedOut:
            return "local_socks_negotiation_timeout"
        case let .tunnelConnectFailed(reply):
            return "reality_connect_reply_\(reply)"
        case .tunnelConnectTimedOut:
            return "reality_connect_timeout"
        }
    }

    var isRemotePathFailure: Bool {
        switch self {
        case .tunnelConnectFailed, .tunnelConnectTimedOut:
            return true
        case .ready, .localConnectFailed, .localConnectTimedOut, .negotiationFailed, .negotiationTimedOut:
            return false
        }
    }

    var localSocksReady: Bool {
        switch self {
        case .ready, .tunnelConnectFailed, .tunnelConnectTimedOut:
            return true
        case .localConnectFailed, .localConnectTimedOut, .negotiationFailed, .negotiationTimedOut:
            return false
        }
    }
}

private final class AorusSocksProbeState: @unchecked Sendable {
    private enum Phase {
        case localConnect
        case negotiation
        case tunnelConnect
    }

    private let lock = NSLock()
    private var finished = false
    private var result: AorusSocksProbeResult?
    private var phase: Phase = .localConnect
    let semaphore = DispatchSemaphore(value: 0)

    func markNegotiating() {
        lock.lock()
        if !finished { phase = .negotiation }
        lock.unlock()
    }

    func markTunnelConnecting() {
        lock.lock()
        if !finished { phase = .tunnelConnect }
        lock.unlock()
    }

    func finish(_ result: AorusSocksProbeResult) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    var resolvedResult: AorusSocksProbeResult {
        lock.lock()
        defer { lock.unlock() }
        return result ?? timeoutResult
    }

    func finishTimedOut() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        result = timeoutResult
        lock.unlock()
        semaphore.signal()
    }

    private var timeoutResult: AorusSocksProbeResult {
        switch phase {
        case .localConnect:
            return .localConnectTimedOut
        case .negotiation:
            return .negotiationTimedOut
        case .tunnelConnect:
            return .tunnelConnectTimedOut
        }
    }
}

private final class AorusParallelProbeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: AorusSocksProbeResult] = [:]

    func set(_ result: AorusSocksProbeResult, at index: Int) {
        lock.lock()
        values[index] = result
        lock.unlock()
    }

    func snapshot() -> [Int: AorusSocksProbeResult] {
        lock.lock()
        let result = values
        lock.unlock()
        return result
    }
}

private struct AorusRealityBootstrapDiagnostic: Codable {
    let stage: String
    let errorCode: String?
    let localSocksReady: Bool
    let updatedAt: Double
}

private struct AorusRealityBootstrapEvent: Codable {
    let stage: String
    let errorCode: String?
    let endpointPriority: Int?
    let localPort: Int?
    let updatedAt: Double
    /// Control-plane id of the endpoint the stage concerns, and one short free-form field
    /// for counts and reasons. Both optional so a trace written by an older build decodes.
    ///
    /// `detail` is written by us at every call site and must stay free of addresses, UUIDs,
    /// keys, device hashes and raw Xray output — the trace is user-visible.
    let endpointId: String?
    let detail: String?
}

/// Owns the in-process Xray core. Credentials are supplied at runtime by the
/// signed control plane and never persisted by this class.
public final class AorusRealityManager {
    public static let shared = AorusRealityManager()

    private static let suiteName = "ng.session.store"
    private static let endpointKey = "71d447f8-9128-4d18-b63c-ec11ef43ba26"
    private static let requirementKey = "b4f013e2-54e9-4e4d-b2e1-30edc1e5b7ca"
    private static let diagnosticKey = "aorusgram_reality_bootstrap_status"
    private static let diagnosticTraceKey = "aorusgram_reality_bootstrap_trace"
    private static let candidatePorts = [38_191, 38_192, 38_193]
    private static let telegramPreflightTargets: [(host: String, port: UInt16)] = [
        ("149.154.167.50", 443),
        ("149.154.167.51", 443)
    ]

    private let queue = DispatchQueue(label: "com.aorusgram.reality", qos: .userInitiated)
    private let readinessQueue = DispatchQueue(label: "com.aorusgram.reality.readiness", qos: .userInitiated)
    private let diagnosticLock = NSLock()
    private var profile: AorusRealityProfile?
    private var rankedEndpoints: [AorusRealityEndpoint] = []
    private var activeEndpoint: AorusRealityEndpoint?
    private var activePort: Int?
    private var transitionInProgress = false
    private var restartRetryWorkItem: DispatchWorkItem?
    private var restartRetryGeneration: UInt64 = 0
    private var restartRetryAttempt = 0
    private var didResetDiagnosticTraceForProcess = false
    /// The user-imported VLESS lane's own state. It shares the Xray core with the signed lane —
    /// there is one core in this process — but nothing else, so it keeps its own port, its own
    /// idea of what is selected, and its own retry backoff.
    private var userLanePort: Int?
    private var userLaneServerId: String?
    private var userLaneServer: AorusVlessServer?
    private var userLaneUdpEnabled: Bool?
    private var userLaneMuxEnabled: Bool?
    private var userLaneRetryWorkItem: DispatchWorkItem?
    private var userLaneRetryAttempt = 0
    /// How many servers one bring-up may try before it gives up and waits for the backoff. Three,
    /// because a round has to fit inside the time a user will hold a settings screen open: the first
    /// candidate carries the patient preflight budget and the two after it the sweep budget, and the
    /// next round starts over from the top rather than continuing down a list that has gone stale.
    private let userLaneCandidatesPerRound = 3
    private let userLaneStatusLock = NSLock()
    private var userLaneUnreachable = false
    /// A bring-up the user asked for is in flight. Set the moment they ask and cleared when the lane
    /// is either carrying traffic or out of servers.
    ///
    /// This cannot be derived from the other two. While a switch to another server is being brought
    /// up, the previous endpoint is still published — deliberately, so traffic is not dropped on the
    /// floor mid-switch — so "serving" is still true and the row went on saying "подключено" through
    /// the whole switch. The user asked for the opposite: picking another server, in this
    /// configuration or another one, should look exactly like turning the switch off and on again.
    private var userLaneConnecting = false
    /// When that bring-up started, so a spinner cannot outlive the round that owns it. A crash inside
    /// the round, a core that never answers, a process suspended mid-preflight: none of those clear
    /// the flag, and a row spinning forever is worse than one that is briefly wrong.
    private var userLaneConnectingSince: TimeInterval = 0
    /// How long a bring-up is allowed to be shown as one. Longer than a round is allowed to take
    /// (`userLaneRoundMaxDuration`), so the round's own verdict is what normally ends the wait, and
    /// this is the backstop for the cases a round cannot report: a queue wedged behind a core that
    /// will not stop, a process suspended mid-preflight, a round superseded by one that never ran.
    private let userLaneConnectingMaxDuration: TimeInterval = 45.0
    /// Armed whenever the lane starts saying "connecting" and cancelled when it stops. Without it
    /// the window above was only consulted by the getter, and nothing announced its end -- the row
    /// follows notifications, so a wait that expired in silence was a wait the row went on drawing
    /// for as long as the screen stayed open.
    private var userLaneConnectingTimeout: DispatchWorkItem?
    /// How long one bring-up may spend walking candidates before it records a verdict and leaves the
    /// rest to the backoff.
    ///
    /// Three candidates, three ports each, and per port a core start (3s), a SOCKS handshake and a
    /// preflight (6s patient, 2.5s after that) plus a second to stop a core that did come up: a round
    /// that walks all of it to the end takes over a minute. That is longer than the window it is being
    /// shown in, which is how the interface came to be left holding a spinner with no verdict behind
    /// it. The deadline is checked before each candidate and before each port, so the walk stops at a
    /// boundary rather than being torn out of a probe, and the round always reaches its own verdict
    /// while the row is still allowed to be waiting for one — thirty seconds plus the longest single
    /// attempt still fits inside the window, so the watchdog stays the backstop it is meant to be.
    ///
    /// What a cut round costs is the last candidate's attempt, and it gets it on the next round a
    /// quarter of a second later, in an order that the latency sweep has meanwhile refreshed.
    private let userLaneRoundMaxDuration: TimeInterval = 30.0
    /// The server the lane is actually carrying traffic through, readable without going through the
    /// serial queue. The interface needs it to tell "this row is the one running" from "this row is
    /// the one ticked", which are not the same thing while a bring-up is in flight.
    private var userLaneServingServerId: String?
    /// Bumped every time the user asks for something new — a different server, the switch, a
    /// setting that rebuilds the core. A round already walking candidates on the serial queue
    /// compares its own number against this one and drops out rather than spending the rest of its
    /// preflight budget on a selection the user has already moved off. Without this, a tap on
    /// another server waited out up to three candidates × their port scans × their preflight
    /// budgets — tens of seconds — before the queue even reached the new round.
    private var userLaneGeneration = 0
    /// The generation the round currently on the queue started with.
    private var userLaneRoundGeneration = 0

    private let coreStartTimeout: TimeInterval = 3.0
    /// Preflight budgets, split because one figure cannot do both jobs. Eight seconds spent
    /// per candidate is how one blocked bridge became half a minute of a client that looks
    /// like it has no network at all, and a budget short enough to keep that cheap would fail
    /// a slow radio that does work. So the sweep goes fast over every signed endpoint first,
    /// and only a failure that ran out of time — rather than one that was refused — earns the
    /// patient second pass. Confirming a core that is already up is neither of those: it
    /// happens with the user waiting, so it gets the middle figure.
    private let preflightFastTimeout: TimeInterval = 2.5
    private let preflightPatientTimeout: TimeInterval = 6.0
    private let preflightConfirmTimeout: TimeInterval = 4.0
    /// How long the local SOCKS inbound gets to answer, starting small and doubling. The core
    /// usually binds within tens of milliseconds, and a flat 0.4 per attempt was most of the
    /// wait before the tunnel came up.
    private let localSocksFirstProbeTimeout: TimeInterval = 0.15
    private let localSocksMaxProbeTimeout: TimeInterval = 0.4
    /// Enough for a loopback connect to be refused, which is the answer being looked for.
    private let localPortProbeTimeout: TimeInterval = 0.15
    private let coreStartPollInterval: TimeInterval = 0.02
    private let restartRetryDelays: [TimeInterval] = [0.25, 0.5, 1, 2, 4, 8, 15]

    private init() {}

    public func startIfAuthorized() {
        guard authorizationAllowsTunnel else {
            licenseDidLock()
            return
        }
        publishTunnelRequirement()
        queue.async { [weak self] in
            guard let self else { return }
            self.resetDiagnosticTraceOncePerProcess()
            self.recordDiagnostic(stage: "route_decision_pending")
        }
        // APP START in the hybrid design: find out whether this network needs the tunnel at
        // all before anything is provisioned. Escalation, if it is needed, calls the
        // provisioner from there.
        AorusHybridRoute.shared.evaluate(reason: "app_start", force: true)
    }

    /// Process-bound readiness signal used by diagnostics and release invariants.
    ///
    /// True once this process has a route it has actually proven: either Telegram reached its
    /// datacentres directly, or a local inbound of ours is up and published. It is never true
    /// on the strength of the license alone.
    public var isReadyForAuthorizedTraffic: Bool {
        guard authorizationAllowsTunnel else { return false }
        switch AorusHybridRoute.shared.mode {
        case .direct:
            return true
        case .tunnel:
            return endpointForCurrentProcess() != nil
        case .unknown, .escalating, .unavailable:
            return false
        }
    }

    public func ensureRunning() {
        if userLaneOwnsCore {
            // The watchdog is still worth running, just against the other lane: a core that died
            // under the user's own configuration needs bringing back exactly as much as one that
            // died under a signed profile.
            userLaneStart(reason: "watchdog")
            return
        }
        publishTunnelRequirement()
        guard AorusHybridRoute.shared.allowsTunnelBringUp else {
            standDownForDirectRoute()
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            if self.mayRun,
               self.isCoreRunning(),
               let port = self.activePort ?? self.endpointForCurrentProcess() {
                let preflight = self.realityPreflight(
                    port: port,
                    endpointPriority: self.activeEndpoint?.priority,
                    timeout: self.preflightConfirmTimeout
                )
                if preflight == .ready {
                    self.activePort = port
                    self.publishEndpoint(port: port)
                    return
                }
                self.recordPreflightFailure(
                    preflight,
                    endpoint: self.activeEndpoint,
                    localPort: port
                )
            }
            if self.mayRun {
                self.restartLocked()
                return
            }
            self.stopLocked(clearProfile: false)
            DispatchQueue.global(qos: .utility).async {
                AorusProxyManager.shared.refresh(force: false)
            }
        }
    }

    /// Adopts a signed profile and an endpoint order.
    ///
    /// `reselectEndpoint` is the caller saying that the endpoint currently carrying traffic is
    /// the problem. Without it this method defends whatever is running (see below), which is
    /// right for a periodic re-rank and wrong for the watchdog: a REALITY preflight to one
    /// datacentre can succeed while the MTProto session this endpoint is meant to carry has
    /// been stalled for fifteen seconds, and the failover that was supposed to fix it would
    /// keep landing on the same endpoint it was called about.
    func apply(
        profile: AorusRealityProfile,
        rankedEndpoints: [AorusRealityEndpoint],
        reselectEndpoint: Bool = false
    ) {
        publishTunnelRequirement()
        queue.async { [weak self] in
            guard let self else { return }
            // The user's own configuration is on the core. Bank the signed profile so switching
            // back later does not wait for another provisioning round trip, and start nothing —
            // the same hold as the direct-route case further down, for a different owner.
            if self.userLaneOwnsCore {
                if profile.isValid(for: DeviceFingerprint.deviceHash()) {
                    self.profile = profile
                    self.rankedEndpoints = rankedEndpoints.filter { endpoint in
                        endpoint.isValid && profile.validEndpoints.contains(endpoint)
                    }
                }
                self.recordDiagnostic(stage: "core_held_for_user_vpn")
                self.cancelRestartRetryLocked(resetAttempt: true)
                return
            }
            guard self.authorizationAllowsTunnel,
                  profile.isValid(for: DeviceFingerprint.deviceHash()) else {
                self.recordDiagnostic(stage: "profile_rejected", errorCode: "profile_validation_failed")
                self.stopLocked(clearProfile: true)
                return
            }
            let validRanked = rankedEndpoints.filter { endpoint in
                endpoint.isValid && profile.validEndpoints.contains(endpoint)
            }
            let nextRanked = validRanked.isEmpty ? profile.validEndpoints : validRanked
            let previousCredential = self.profile?.credential
            let profileChanged = self.profile != profile || self.rankedEndpoints != nextRanked
            self.profile = profile
            self.rankedEndpoints = nextRanked
            self.recordDiagnostic(
                stage: "profile_applied",
                detail: "valid=\(profile.validEndpoints.count) of=\(profile.endpoints.count)"
            )
            for rejected in profile.rejectedEndpoints {
                self.recordDiagnostic(
                    stage: "endpoint_rejected",
                    errorCode: rejected.reason,
                    endpointId: rejected.id
                )
            }
            // Telegram reaches its datacentres without help on this network, so the signed
            // profile is banked and nothing is started. Escalation, if the network changes
            // under the user or the engine stalls, finds it already here.
            guard AorusHybridRoute.shared.allowsTunnelBringUp else {
                self.recordDiagnostic(stage: "core_held_for_direct")
                self.cancelRestartRetryLocked(resetAttempt: true)
                return
            }
            var canKeepRunning = false
            // Endpoint ranking is advisory. Latency/jitter probes can reorder two
            // healthy bridges on every profile refresh or path update; restarting
            // Xray merely because the current bridge moved from rank 1 to rank 2
            // tears down a valid MTProto session and leaves Telegram in Updating.
            // Keep the current signed endpoint while its full REALITY preflight is
            // healthy. Rotation, removal from the signed profile, or an actual
            // preflight failure still takes the normal restart/failover path.
            if previousCredential == profile.credential,
               !reselectEndpoint,
               self.isCoreRunning(),
               let activePort = self.activePort,
               let activeEndpoint = self.activeEndpoint,
               nextRanked.contains(activeEndpoint) {
                let preflight = self.realityPreflight(
                    port: activePort,
                    endpointPriority: activeEndpoint.priority,
                    timeout: self.preflightConfirmTimeout
                )
                canKeepRunning = preflight == .ready
                if !canKeepRunning {
                    self.recordPreflightFailure(
                        preflight,
                        endpoint: self.activeEndpoint,
                        localPort: activePort
                    )
                }
            }
            self.recordDiagnostic(stage: "profile_applied")
            if profileChanged {
                self.cancelRestartRetryLocked(resetAttempt: true)
            }
            if canKeepRunning, let port = self.activePort, let endpoint = self.activeEndpoint {
                self.cancelRestartRetryLocked(resetAttempt: true)
                self.publishEndpoint(port: port)
                AorusProxyManager.shared.realityEndpointDidActivate(endpoint)
                return
            }
            self.restartLocked()
        }
    }

    public func licenseDidLock() {
        // A configuration the user pasted is their own key on their own server, and owes nothing
        // to a subscription. Standing it down here would also strand MTProto: it is pointed at
        // our inbound, and the closed port is what it falls back to.
        if userLaneOwnsCore { return }
        // This method is also used when provisioning fails. Reconcile against the actual
        // license state, and release Telegram either way: the requirement follows the route
        // that exists, and after this call there is none. A still-subscribed account whose
        // control plane merely blipped goes back through the route decision, which is what
        // re-takes the requirement once an endpoint is proven again.
        AorusHybridRoute.shared.tunnelDidStandDown()
        publishTunnelRequirement()
        queue.async { [weak self] in
            self?.stopLocked(clearProfile: true)
        }
    }

    func profileDidVerify() {
        queue.async { [weak self] in
            self?.recordDiagnostic(stage: "profile_received")
        }
    }

    /// Trace entry for the provisioning and probing side, which lives in AorusProxyManager
    /// and has no diagnostic writer of its own. Same redaction rule: no addresses, UUIDs,
    /// keys or device hashes.
    func recordProxyEvent(stage: String, errorCode: String? = nil, endpointId: String? = nil, detail: String? = nil) {
        queue.async { [weak self] in
            self?.recordDiagnostic(stage: stage, errorCode: errorCode, endpointId: endpointId, detail: detail)
        }
    }

    func recordEndpointProbe(priority: Int, available: Bool) {
        queue.async { [weak self] in
            self?.recordDiagnostic(
                stage: available ? "bridge_tcp_reachable" : "bridge_tcp_unreachable",
                errorCode: available ? nil : "bridge_tcp_connect_failed",
                endpointPriority: priority
            )
        }
    }

    private var authorizationAllowsTunnel: Bool {
        guard AorusConnectionPreferences.shared.bypassEnabled,
              LicenseKeyProvider.isProvisioned,
              !UserDefaults.standard.bool(forKey: "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04"),
              !AorusSessionMetrics.metricFlag,
              !UserDefaults.standard.bool(forKey: "c0a8b1e2-6f4d-4a9c-b3e7-1d520f8a6b34"),
              !AorusSessionCounter.shared.isTripped else {
            return false
        }
        return LicenseStore.shared.effectiveOfflineStatus().allowsAppAccess
    }

    /// Same question, asked by the route decision, which has to know whether escalating is
    /// even possible before it reports a state to the user.
    var tunnelIsAuthorized: Bool {
        return authorizationAllowsTunnel
    }

    /// Direct works, so the core has no job. The signed profile is deliberately kept: it is
    /// short-lived and already verified, and a network change that puts the user back behind a
    /// block should not have to wait for another provisioning round trip.
    func standDownForDirectRoute() {
        // The hybrid decision is about the signed lane's tunnel. The user asked for theirs
        // explicitly, so "direct works" is not a reason to take it away.
        if userLaneOwnsCore { return }
        publishTunnelRequirement()
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isCoreRunning() || self.activePort != nil else {
                self.cancelRestartRetryLocked(resetAttempt: true)
                self.clearEndpoint(postUpdate: true)
                return
            }
            self.recordDiagnostic(stage: "core_stood_down_for_direct")
            self.stopLocked(clearProfile: false)
        }
    }

    /// The route decision changed, so what Telegram is told has to change with it.
    func routeModeDidChange() {
        publishTunnelRequirement()
    }

    /// True while the user's own imported configuration is the thing carrying traffic.
    ///
    /// Derived from the store on every read rather than remembered in a flag. The two lanes are
    /// started from different places — one from the bootstrap, one from a route decision that can
    /// fire before the first screen exists — and an in-memory flag would be wrong for exactly as
    /// long as it took to be set. This reads the same value the MTProto override and the call
    /// transport read out of the shared defaults, so all three agree by construction.
    private var userLaneOwnsCore: Bool {
        return AorusUserVPNStore.shared.isActive
    }

    private var mayRun: Bool {
        guard !userLaneOwnsCore, authorizationAllowsTunnel, let profile else { return false }
        return profile.isValid(for: DeviceFingerprint.deviceHash())
    }

    /// Whether the lane that asked for this core still wants it up.
    ///
    /// `mayRun` answers that for the signed lane only, and by design it answers `false` the moment
    /// the user's own configuration owns the core. Two helpers below are shared by both lanes and
    /// were reading it anyway, which made the user's lane unable to come up at all: the poll in
    /// `waitForCoreAndLocalSocks` ran a single pass and reported a timeout milliseconds after the
    /// core was asked to start, and `realityPreflight` returned "local connect failed" without
    /// probing anything. A switch that was on and a connection that never arrived, on every server
    /// in the subscription, for reasons that had nothing to do with the servers.
    private var coreWorkIsWanted: Bool {
        if userLaneOwnsCore {
            // A round the user has already moved on from is not work anybody wants finished. This is
            // where an interrupted bring-up actually stops: the poll loop and the preflight probes
            // are the only slow things on the queue, and both ask here between passes.
            return !userLaneRoundIsStale
        }
        return mayRun
    }

    /// Whether the bring-up round on the queue has been superseded by a newer request.
    private var userLaneRoundIsStale: Bool {
        self.userLaneStatusLock.lock()
        defer { self.userLaneStatusLock.unlock() }
        return self.userLaneRoundGeneration != self.userLaneGeneration
    }

    /// Mark everything currently in flight as superseded. Called for anything the user did; not for
    /// the lane's own retry or the watchdog, neither of which is a new request.
    private func bumpUserLaneGeneration() {
        self.userLaneStatusLock.lock()
        self.userLaneGeneration += 1
        self.userLaneStatusLock.unlock()
    }

    /// Claim the current generation for the round about to run on the serial queue.
    private func beginUserLaneRound() {
        self.userLaneStatusLock.lock()
        self.userLaneRoundGeneration = self.userLaneGeneration
        self.userLaneStatusLock.unlock()
    }

    private func restartLocked() {
        guard !transitionInProgress else { return }
        guard mayRun, let profile else {
            stopLocked(clearProfile: true)
            return
        }

        transitionInProgress = true
        defer { transitionInProgress = false }
        recordDiagnostic(stage: "starting_core")
        _ = invoke(method: "stopXray")
        waitForCoreStop()
        activePort = nil
        activeEndpoint = nil
        clearEndpoint(postUpdate: false)

        let endpointOrder = rankedEndpoints.isEmpty ? profile.validEndpoints : rankedEndpoints
        var slowEndpoints: [AorusRealityEndpoint] = []
        for endpoint in endpointOrder {
            guard mayRun else { break }
            switch attemptEndpoint(
                profile: profile,
                endpoint: endpoint,
                preflightTimeout: preflightFastTimeout
            ) {
            case .published:
                return
            case .slowRemotePath:
                slowEndpoints.append(endpoint)
            case .failed:
                break
            }
        }
        // A bridge whose REALITY leg ran out of time rather than refusing the connection is a
        // slow path, not a blocked one, and on a bad radio every one of them can be. The first
        // pass exists so a blocked bridge costs seconds; this one exists so a slow bridge still
        // connects. Only the endpoints that actually ran out of time are worth the longer
        // budget — a refused connection and a core that would not start answer the same way
        // however long they are given — so the client with nowhere to go still reaches its
        // retry quickly instead of paying the patient timeout for every dead bridge.
        if !slowEndpoints.isEmpty, mayRun {
            recordDiagnostic(
                stage: "patient_pass_started",
                errorCode: "fast_preflight_timed_out",
                detail: "retry=\(slowEndpoints.count) of=\(endpointOrder.count)"
            )
            for endpoint in slowEndpoints {
                guard mayRun else { break }
                if attemptEndpoint(
                    profile: profile,
                    endpoint: endpoint,
                    preflightTimeout: preflightPatientTimeout
                ) == .published {
                    return
                }
            }
        }
        // Nothing published. Telegram is released rather than left pointing at the reserved
        // loopback port: a client with no working bridge keeps whatever route it had, and the
        // retry ladder below goes on trying to earn the requirement back.
        recordDiagnostic(
            stage: "no_endpoint_published",
            errorCode: "all_endpoints_failed",
            detail: "tried=\(endpointOrder.count)"
        )
        clearEndpoint(postUpdate: true)
        AorusHybridRoute.shared.tunnelDidExhaustEndpoints()
        scheduleRestartRetryLocked()
    }

    private enum AorusEndpointAttempt: Equatable {
        case published
        case slowRemotePath
        case failed
    }

    /// Brings one signed endpoint up on the first loopback port that will take it and proves
    /// the whole path before Telegram is told the port exists.
    private func attemptEndpoint(
        profile: AorusRealityProfile,
        endpoint: AorusRealityEndpoint,
        preflightTimeout: TimeInterval
    ) -> AorusEndpointAttempt {
        recordDiagnostic(stage: "endpoint_selected", endpointPriority: endpoint.priority)
        for localPort in Self.candidatePorts {
            guard mayRun else { return .failed }
            guard let config = makeConfig(profile: profile, endpoint: endpoint, localPort: localPort) else {
                continue
            }
            // Anything else on the device holding this port makes the core start and then
            // never serve, which costs the entire core-start budget to find out. Asking
            // first costs 150 ms at most.
            guard localPortIsAvailable(localPort) else {
                recordDiagnostic(
                    stage: "local_port_unavailable",
                    errorCode: "local_port_occupied",
                    endpointPriority: endpoint.priority,
                    localPort: localPort
                )
                continue
            }
            recordDiagnostic(
                stage: "core_start_requested",
                endpointPriority: endpoint.priority,
                localPort: localPort
            )
            recordDiagnostic(
                stage: "dial_target_resolved",
                endpointPriority: endpoint.priority,
                localPort: localPort,
                endpointId: endpoint.stableId,
                // The dial target and the route are not secrets — the device owner
                // already holds them in the profile — and without them a blocked bridge
                // cannot be told apart from a client dialling the wrong thing. The
                // credential, the keys and the SNI stay out.
                detail: "target=\(endpoint.address):\(endpoint.port) route=\(endpoint.routeType ?? "direct")"
                    + (endpoint.via.map { " via=\($0)" } ?? "")
            )
            let response = invoke(method: "runXrayFromJson", payload: ["configJSON": config])
            guard response?.success == true else {
                recordDiagnostic(
                    stage: "core_start_failed",
                    errorCode: "xray_start_rejected",
                    endpointPriority: endpoint.priority,
                    localPort: localPort
                )
                _ = invoke(method: "stopXray")
                waitForCoreStop()
                continue
            }
            guard waitForCoreAndLocalSocks(port: localPort, endpointPriority: endpoint.priority) else {
                _ = invoke(method: "stopXray")
                waitForCoreStop()
                continue
            }
            let preflight = realityPreflight(
                port: localPort,
                endpointPriority: endpoint.priority,
                timeout: preflightTimeout
            )
            guard preflight == .ready else {
                // A path that ran out of the fast budget may only be slow, and a bridge is
                // not worth a five-minute penalty for that until the patient pass has said
                // the same thing. One that was actively refused is penalised now.
                let deferPenalty = preflight == .tunnelConnectTimedOut
                    && preflightTimeout < preflightPatientTimeout
                recordPreflightFailure(
                    preflight,
                    endpoint: endpoint,
                    localPort: localPort,
                    penalizeEndpoint: !deferPenalty
                )
                _ = invoke(method: "stopXray")
                waitForCoreStop()
                // A different loopback port cannot repair a failed remote REALITY path.
                // Move directly to the next signed endpoint.
                return deferPenalty ? .slowRemotePath : .failed
            }
            activePort = localPort
            activeEndpoint = endpoint
            rankedEndpoints = [endpoint] + rankedEndpoints.filter { $0 != endpoint }
            cancelRestartRetryLocked(resetAttempt: true)
            recordDiagnostic(
                stage: "endpoint_published",
                localSocksReady: true,
                endpointPriority: endpoint.priority,
                localPort: localPort
            )
            recordDiagnostic(
                stage: "tunnel_ready",
                localSocksReady: true,
                endpointPriority: endpoint.priority,
                localPort: localPort,
                endpointId: endpoint.stableId
            )
            publishEndpoint(port: localPort)
            AorusProxyManager.shared.realityEndpointDidActivate(endpoint)
            return .published
        }
        return .failed
    }

    /// Whether the loopback port looks free for the local inbound.
    ///
    /// Not a bind test: taking the port to find out creates the conflict it is checking for,
    /// because closing it again races the core's own bind. The same question has an answer
    /// from the outside — a connect that completes and then does not speak SOCKS is something
    /// else already listening, and a connect that is refused is nobody.
    private func localPortIsAvailable(_ port: Int) -> Bool {
        switch socksProbe(
            port: port,
            target: nil,
            timeout: localPortProbeTimeout,
            requireTunnelConnect: false
        ) {
        case .localConnectFailed, .localConnectTimedOut:
            return true
        case .ready, .negotiationFailed, .negotiationTimedOut,
             .tunnelConnectFailed, .tunnelConnectTimedOut:
            return false
        }
    }

    private func stopLocked(clearProfile: Bool) {
        if transitionInProgress { return }
        if userLaneOwnsCore {
            // The core belongs to the user's own configuration. Stopping it here would take the
            // only path MTProto has with it, and the signed lane has nothing running to stop
            // anyway. The profile is kept banked rather than cleared: it is what the connection
            // falls back to the moment the user turns their VPN off.
            cancelRestartRetryLocked(resetAttempt: true)
            activePort = nil
            activeEndpoint = nil
            return
        }
        cancelRestartRetryLocked(resetAttempt: true)
        transitionInProgress = true
        defer { transitionInProgress = false }
        _ = invoke(method: "stopXray")
        waitForCoreStop()
        activePort = nil
        activeEndpoint = nil
        if clearProfile {
            profile = nil
            rankedEndpoints.removeAll(keepingCapacity: false)
        }
        clearEndpoint(postUpdate: true)
        AorusHybridRoute.shared.tunnelDidStandDown()
    }

    private func waitForCoreAndLocalSocks(port: Int, endpointPriority: Int) -> Bool {
        let deadline = Date().addingTimeInterval(coreStartTimeout)
        var observedRunningCore = false
        var probeTimeout = localSocksFirstProbeTimeout
        repeat {
            if isCoreRunning() {
                if !observedRunningCore {
                    observedRunningCore = true
                    recordDiagnostic(
                        stage: "core_running",
                        endpointPriority: endpointPriority,
                        localPort: port
                    )
                }
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0,
                   localSocksIsReady(port: port, timeout: min(probeTimeout, remaining)) {
                    recordDiagnostic(
                        stage: "local_socks_ready",
                        localSocksReady: true,
                        endpointPriority: endpointPriority,
                        localPort: port
                    )
                    return true
                }
                // The inbound was not up yet. Give it longer each time rather than spending
                // the same generous timeout on an answer that arrives in milliseconds.
                probeTimeout = min(localSocksMaxProbeTimeout, probeTimeout * 2.0)
            }
            Thread.sleep(forTimeInterval: coreStartPollInterval)
        } while Date() < deadline && coreWorkIsWanted
        if observedRunningCore {
            recordDiagnostic(
                stage: "local_socks_failed",
                errorCode: "local_socks_handshake_timeout",
                endpointPriority: endpointPriority,
                localPort: port
            )
        } else {
            recordDiagnostic(
                stage: "core_start_failed",
                errorCode: "core_running_timeout",
                endpointPriority: endpointPriority,
                localPort: port
            )
        }
        return false
    }

    private func waitForCoreStop() {
        let deadline = Date().addingTimeInterval(1.0)
        while isCoreRunning(), Date() < deadline {
            Thread.sleep(forTimeInterval: coreStartPollInterval)
        }
    }

    /// `getXrayState.running` is set before the local inbound is guaranteed to be
    /// bound on slower devices. Telegram must not receive the loopback endpoint
    /// until the SOCKS server has completed a real protocol handshake.
    private func localSocksIsReady(port: Int, timeout: TimeInterval) -> Bool {
        socksProbe(
            port: port,
            target: nil,
            timeout: timeout,
            requireTunnelConnect: false
        ) == .ready
    }

    /// Forces the lazy Xray outbound to establish VLESS/REALITY before its local
    /// SOCKS endpoint is published to Telegram. A successful SOCKS CONNECT proves
    /// the full path: local inbound -> selected bridge -> REALITY/VLESS -> remote
    /// Telegram TCP destination. Targets are probed concurrently so a blocked DC
    /// cannot add a second full timeout to foreground recovery.
    ///
    /// `timeout` is what the caller can afford to wait, not a property of the path: a sweep
    /// across candidates spends little on each, a confirmation of a core that is already
    /// carrying traffic can afford more.
    private func realityPreflight(port: Int, endpointPriority: Int?, timeout: TimeInterval) -> AorusSocksProbeResult {
        recordDiagnostic(
            stage: "reality_preflight_started",
            localSocksReady: true,
            endpointPriority: endpointPriority,
            localPort: port
        )
        guard coreWorkIsWanted else { return .localConnectFailed }
        let results = AorusParallelProbeResults()
        let resultReady = DispatchSemaphore(value: 0)
        for (index, target) in Self.telegramPreflightTargets.enumerated() {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    resultReady.signal()
                    return
                }
                let result = self.socksProbe(
                    port: port,
                    target: target,
                    timeout: timeout,
                    requireTunnelConnect: true
                )
                results.set(result, at: index)
                resultReady.signal()
            }
        }

        let deadline = DispatchTime.now() + timeout + 0.5
        for _ in Self.telegramPreflightTargets {
            if resultReady.wait(timeout: deadline) == .timedOut { break }
            if results.snapshot().values.contains(.ready), coreWorkIsWanted {
                recordDiagnostic(
                    stage: "reality_preflight_ready",
                    localSocksReady: true,
                    endpointPriority: endpointPriority,
                    localPort: port
                )
                return .ready
            }
        }

        guard coreWorkIsWanted else { return .localConnectFailed }
        let ordered = Self.telegramPreflightTargets.indices.compactMap { results.snapshot()[$0] }
        if let localFailure = ordered.first(where: { !$0.localSocksReady }) {
            return localFailure
        }
        return ordered.last ?? .tunnelConnectTimedOut
    }

    private func recordPreflightFailure(
        _ result: AorusSocksProbeResult,
        endpoint: AorusRealityEndpoint?,
        localPort: Int,
        penalizeEndpoint: Bool = true
    ) {
        recordDiagnostic(
            stage: "reality_preflight_failed",
            errorCode: result.diagnosticCode,
            localSocksReady: result.localSocksReady,
            endpointPriority: endpoint?.priority,
            localPort: localPort
        )
        if penalizeEndpoint, result.isRemotePathFailure, let endpoint {
            if let index = rankedEndpoints.firstIndex(of: endpoint) {
                rankedEndpoints.remove(at: index)
                rankedEndpoints.append(endpoint)
            }
            AorusProxyManager.shared.realityEndpointDidFail(endpoint)
        }
    }

    private func socksProbe(
        port: Int,
        target: (host: String, port: UInt16)?,
        timeout: TimeInterval,
        requireTunnelConnect: Bool
    ) -> AorusSocksProbeResult {
        guard timeout > 0,
              let networkPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return .localConnectFailed
        }

        let state = AorusSocksProbeState()
        let connection = NWConnection(host: "127.0.0.1", port: networkPort, using: .tcp)
        connection.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .ready:
                state.markNegotiating()
                connection.send(content: Data([0x05, 0x01, 0x00]), completion: .contentProcessed { error in
                    guard error == nil else {
                        state.finish(.negotiationFailed)
                        connection.cancel()
                        return
                    }
                    connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, error in
                        guard error == nil, data == Data([0x05, 0x00]) else {
                            state.finish(.negotiationFailed)
                            connection.cancel()
                            return
                        }
                        guard requireTunnelConnect, let target else {
                            state.finish(.ready)
                            connection.cancel()
                            return
                        }
                        guard let request = Self.socksConnectRequest(host: target.host, port: target.port) else {
                            state.finish(.negotiationFailed)
                            connection.cancel()
                            return
                        }
                        state.markTunnelConnecting()
                        connection.send(content: request, completion: .contentProcessed { error in
                            guard error == nil else {
                                state.finish(.tunnelConnectFailed(0xff))
                                connection.cancel()
                                return
                            }
                            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
                                guard error == nil, let data, data.count == 4,
                                      data[data.startIndex] == 0x05 else {
                                    state.finish(.tunnelConnectFailed(0xff))
                                    connection.cancel()
                                    return
                                }
                                let reply = data[data.index(after: data.startIndex)]
                                state.finish(reply == 0x00 ? .ready : .tunnelConnectFailed(reply))
                                connection.cancel()
                            }
                        })
                    }
                })
            case .failed:
                state.finish(.localConnectFailed)
                connection.cancel()
            case .waiting:
                // The localhost route can briefly wait while Xray finishes
                // binding. The probe timeout remains the failure boundary.
                break
            case .cancelled:
                state.finish(.localConnectFailed)
            default:
                break
            }
        }
        connection.start(queue: readinessQueue)
        if state.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            state.finishTimedOut()
            connection.cancel()
        }
        return state.resolvedResult
    }

    private static func socksConnectRequest(host: String, port: UInt16) -> Data? {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for component in components {
            guard !component.isEmpty, let octet = UInt8(component) else { return nil }
            octets.append(octet)
        }
        var bytes: [UInt8] = [0x05, 0x01, 0x00, 0x01]
        bytes.append(contentsOf: octets)
        bytes.append(UInt8((port >> 8) & 0xff))
        bytes.append(UInt8(port & 0xff))
        return Data(bytes)
    }

    /// LibXray can briefly reject or delay its first in-process start while iOS is
    /// restoring the app after a clean install. Keep the already verified,
    /// device-bound profile in memory and retry only the local core. Direct
    /// Telegram traffic remains pinned to the closed loopback port throughout.
    private func scheduleRestartRetryLocked() {
        guard mayRun else {
            cancelRestartRetryLocked(resetAttempt: true)
            return
        }
        guard restartRetryWorkItem == nil else { return }

        recordDiagnostic(stage: "retry_scheduled", errorCode: "no_ready_local_tunnel")

        restartRetryGeneration &+= 1
        let generation = restartRetryGeneration
        let delayIndex = min(restartRetryAttempt, restartRetryDelays.count - 1)
        let delay = restartRetryDelays[delayIndex]
        restartRetryAttempt = min(restartRetryAttempt + 1, restartRetryDelays.count - 1)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.restartRetryGeneration == generation else { return }
            self.restartRetryWorkItem = nil
            guard self.mayRun else {
                self.cancelRestartRetryLocked(resetAttempt: true)
                return
            }
            self.restartLocked()
        }
        restartRetryWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelRestartRetryLocked(resetAttempt: Bool) {
        restartRetryGeneration &+= 1
        restartRetryWorkItem?.cancel()
        restartRetryWorkItem = nil
        if resetAttempt { restartRetryAttempt = 0 }
    }

    private func makeConfig(
        profile: AorusRealityProfile,
        endpoint: AorusRealityEndpoint,
        localPort: Int
    ) -> String? {
        let config: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": [[
                "tag": "aorus-local-socks",
                "listen": "127.0.0.1",
                "port": localPort,
                "protocol": "socks",
                "settings": ["auth": "noauth", "udp": true, "ip": "127.0.0.1"]
            ]],
            "outbounds": [[
                "tag": "aorus-reality",
                "protocol": "vless",
                "settings": [
                    "vnext": [[
                        "address": endpoint.address,
                        "port": endpoint.port,
                        "users": [[
                            "id": profile.credential.uuid,
                            "encryption": "none",
                            "flow": profile.credential.flow
                        ]]
                    ]],
                    "packetEncoding": "xudp"
                ],
                "streamSettings": [
                    // "tcp", not "raw": they are the same transport on the wire, but "raw"
                    // is the newer name and only cores from 25.1.30 accept it. A working
                    // client against this same infrastructure sends "tcp", so this is the
                    // name that cannot be the thing that differs.
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": [
                        "fingerprint": endpoint.fingerprint,
                        "serverName": endpoint.serverName,
                        "publicKey": endpoint.publicKey,
                        "shortId": endpoint.shortId,
                        "spiderX": endpoint.spiderX
                    ]
                ]
            ]]
        ]
        guard JSONSerialization.isValidJSONObject(config),
              let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private struct InvokeResponse: Decodable {
        struct State: Decodable { let running: Bool? }
        let success: Bool
        let data: State?
        let error: String?
    }

    private func invoke(method: String, payload: [String: Any]? = nil) -> InvokeResponse? {
        var request: [String: Any] = ["apiVersion": 1, "method": method]
        if let payload { request["payload"] = payload }
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.withCString { pointer in
            guard let raw = CGoInvoke(UnsafeMutablePointer(mutating: pointer)) else { return nil }
            defer { CGoFree(raw) }
            return try? JSONDecoder().decode(InvokeResponse.self, from: Data(String(cString: raw).utf8))
        }
    }

    private func isCoreRunning() -> Bool {
        let response = invoke(method: "getXrayState")
        return response?.success == true && response?.data?.running == true
    }

    private func publishEndpoint(port: Int) {
        guard mayRun, (1 ... 65_535).contains(port),
              let store = UserDefaults(suiteName: Self.suiteName) else {
            clearEndpoint(postUpdate: true)
            return
        }
        store.set([
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "port": port,
            "updatedAt": Date().timeIntervalSince1970
        ], forKey: Self.endpointKey)
        postProxyUpdate()
        // Strictly after the port is on disk. This is what takes the requirement, and an
        // observer woken by it has to be able to find the inbound it is being pointed at.
        AorusHybridRoute.shared.tunnelDidActivate()
    }

    /// The one place that tells Telegram whether it must use our inbound, and it asks the
    /// route decision rather than the license: being entitled to a tunnel is not the same as
    /// having one, and only a proven local inbound may redirect MTProto.
    private func publishTunnelRequirement() {
        // While the user's own configuration is carrying traffic, the route decision has no
        // opinion worth publishing: it knows nothing about that tunnel, so its verdict would
        // read as "no tunnel needed" and send MTProto around the only inbound it has.
        if userLaneOwnsCore { return }
        publishRequirement(required: AorusHybridRoute.shared.tunnelIsRequired)
    }

    private func publishRequirement(required: Bool) {
        guard let store = UserDefaults(suiteName: Self.suiteName) else { return }
        store.set([
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "required": required,
            "updatedAt": Date().timeIntervalSince1970
        ], forKey: Self.requirementKey)
        postProxyUpdate()
    }

    private func endpointForCurrentProcess() -> Int? {
        guard let endpoint = UserDefaults(suiteName: Self.suiteName)?.dictionary(forKey: Self.endpointKey),
              let pid = endpoint["pid"] as? NSNumber,
              pid.int32Value == ProcessInfo.processInfo.processIdentifier,
              let port = endpoint["port"] as? NSNumber,
              (1 ... 65_535).contains(port.intValue) else {
            return nil
        }
        return port.intValue
    }

    private func clearEndpoint(postUpdate: Bool) {
        UserDefaults(suiteName: Self.suiteName)?.removeObject(forKey: Self.endpointKey)
        if postUpdate { postProxyUpdate() }
    }

    private func postProxyUpdate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .aorusProxyConfigUpdated, object: nil)
        }
    }

    private func recordDiagnostic(
        stage: String,
        errorCode: String? = nil,
        localSocksReady: Bool = false,
        endpointPriority: Int? = nil,
        localPort: Int? = nil,
        endpointId: String? = nil,
        detail: String? = nil
    ) {
        let now = Date().timeIntervalSince1970
        let diagnostic = AorusRealityBootstrapDiagnostic(
            stage: stage,
            errorCode: errorCode,
            localSocksReady: localSocksReady,
            updatedAt: now
        )
        guard let data = try? JSONEncoder().encode(diagnostic),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        // Intentionally contains no endpoint address, UUID, keys, raw Xray error,
        // device hash, or signed profile material.
        let event = AorusRealityBootstrapEvent(
            stage: stage,
            errorCode: errorCode,
            endpointPriority: endpointPriority,
            localPort: localPort,
            updatedAt: now,
            endpointId: endpointId,
            detail: detail
        )
        diagnosticLock.lock()
        defer { diagnosticLock.unlock() }
        UserDefaults.standard.set(text, forKey: Self.diagnosticKey)
        var trace: [AorusRealityBootstrapEvent] = []
        if let existing = UserDefaults.standard.data(forKey: Self.diagnosticTraceKey),
           let decoded = try? JSONDecoder().decode([AorusRealityBootstrapEvent].self, from: existing) {
            trace = decoded
        }
        trace.append(event)
        if trace.count > 64 { trace.removeFirst(trace.count - 64) }
        if let encoded = try? JSONEncoder().encode(trace) {
            UserDefaults.standard.set(encoded, forKey: Self.diagnosticTraceKey)
        }
    }

    private func resetDiagnosticTraceOncePerProcess() {
        guard !didResetDiagnosticTraceForProcess else { return }
        didResetDiagnosticTraceForProcess = true
        diagnosticLock.lock()
        UserDefaults.standard.removeObject(forKey: Self.diagnosticTraceKey)
        diagnosticLock.unlock()
    }
}

// MARK: - The user's own VLESS configuration

/// The second lane. Same core, same loopback inbound, same published endpoint — and none of the
/// signed lane's machinery, because none of it applies: there is no profile to validate against
/// a device hash, no endpoint ranking to defend, and no subscription that can lock.
///
/// It is still app-scoped in exactly the way the signed lane is. Nothing here installs a system
/// tunnel: the core binds a SOCKS inbound on 127.0.0.1, and the only things pointed at it are
/// this client's own MTProto connection and its own call media. Every other app on the device,
/// and every other part of the system, is untouched.
extension AorusRealityManager {
    /// Whether this process is carrying the user's own configuration right now.
    ///
    /// Read by the settings row that reports "подключено" against "соединение", and answered from
    /// the two facts the transports themselves read — the lane is active, and this process has
    /// published a live endpoint — rather than from `userLanePort`. That one lives on the serial
    /// queue, and a synchronous getter for the interface must not have to wait behind a core
    /// restart to return a boolean.
    public var userLaneIsServing: Bool {
        guard AorusUserVPNStore.shared.isActive else { return false }
        return endpointForCurrentProcess() != nil
    }

    /// The server the lane is carrying traffic through right now, or nil when it is not carrying
    /// any. Not the same thing as the ticked row: between a tap and a proven inbound, the selection
    /// is the new server and this is still the old one — which is exactly the difference a re-tap
    /// has to be able to tell.
    public var userLaneServingServer: String? {
        guard self.userLaneIsServing else { return nil }
        self.userLaneStatusLock.lock()
        defer { self.userLaneStatusLock.unlock() }
        return self.userLaneServingServerId
    }

    private func setUserLaneServingServerId(_ value: String?) {
        self.userLaneStatusLock.lock()
        self.userLaneServingServerId = value
        self.userLaneStatusLock.unlock()
    }

    /// Every server the lane could dial has refused to come up since the last one that worked.
    ///
    /// Read by the same settings row, which without it says "соединение" for as long as the switch
    /// is on -- and after a whole subscription has been walked through and rejected, that is a
    /// description of nothing. Guarded by its own lock rather than living on the serial queue, for
    /// the same reason `userLaneIsServing` is: a getter for the interface must not wait behind a
    /// core restart.
    public var userLaneIsUnreachable: Bool {
        guard AorusUserVPNStore.shared.isEnabled else { return false }
        guard !self.userLaneIsServing else { return false }
        self.userLaneStatusLock.lock()
        defer { self.userLaneStatusLock.unlock() }
        return self.userLaneUnreachable
    }

    private func setUserLaneUnreachable(_ value: Bool) {
        self.userLaneStatusLock.lock()
        let changed = self.userLaneUnreachable != value
        self.userLaneUnreachable = value
        self.userLaneStatusLock.unlock()
        guard changed else { return }
        // The row follows notifications rather than polling, so a status nothing announces is a
        // status it never draws.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: AorusUserVPNManager.didChangeActivityNotification,
                object: nil
            )
        }
    }

    /// The lane is bringing a server up right now.
    ///
    /// Takes precedence over "serving" in the interface: during a switch both are true for a while,
    /// and the one the user asked to see is this one.
    ///
    /// The window is checked here as well as by the watchdog that closes it. The two agree by
    /// construction — same flag, same timestamp, same duration — and the getter is what makes the
    /// answer correct in the instant before the watchdog has run.
    public var userLaneIsConnecting: Bool {
        guard AorusUserVPNStore.shared.isActive else { return false }
        self.userLaneStatusLock.lock()
        defer { self.userLaneStatusLock.unlock() }
        guard self.userLaneConnecting else { return false }
        guard Date().timeIntervalSince1970 - self.userLaneConnectingSince <= self.userLaneConnectingMaxDuration else {
            return false
        }
        return true
    }

    private func setUserLaneConnecting(_ value: Bool) {
        self.userLaneStatusLock.lock()
        let changed = self.userLaneConnecting != value
        self.userLaneConnecting = value
        if value {
            // Refreshed on every set, not only on the first: a second tap is a new round and gets
            // its own window rather than inheriting the remains of the previous one's.
            self.userLaneConnectingSince = Date().timeIntervalSince1970
        }
        self.userLaneStatusLock.unlock()
        // Re-armed on every set for the same reason the timestamp is refreshed, and cancelled the
        // moment the wait ends so a round that answered in a second is not followed by a timeout
        // that fires against the next one.
        if value {
            self.armUserLaneConnectingTimeout()
        } else {
            self.cancelUserLaneConnectingTimeout()
        }
        guard changed else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: AorusUserVPNManager.didChangeActivityNotification,
                object: nil
            )
        }
    }

    /// End the wait out loud when nothing else has.
    ///
    /// The round in flight is deliberately left alone: it still owns the core, it still has
    /// candidates to try, and one of them coming up publishes an endpoint and clears everything this
    /// sets. What ends here is only the *claim* that a connection is being made — after this long it
    /// is not something a user can read as anything but a screen that has stopped working — and the
    /// lane is reported as it stands: enabled, and not carrying traffic.
    ///
    /// On the main queue rather than the lane's own: `queue` is where the bring-up runs, and a
    /// timeout that has to wait behind the walk it is timing is a timeout that fires once the walk
    /// is already over.
    private func armUserLaneConnectingTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.userLaneStatusLock.lock()
            self.userLaneConnectingTimeout = nil
            let stillWaiting = self.userLaneConnecting
            self.userLaneStatusLock.unlock()
            guard stillWaiting else { return }
            guard !self.userLaneIsServing else {
                // It came up and the publication is what the row will read; only the wait is stale.
                self.setUserLaneConnecting(false)
                return
            }
            self.recordDiagnostic(stage: "user_connect_timeout", errorCode: "user_connect_window_expired")
            // Order matters: the verdict is in place before the wait is withdrawn, so the row never
            // observes a state with neither on it.
            self.setUserLaneUnreachable(true)
            self.setUserLaneConnecting(false)
        }
        self.userLaneStatusLock.lock()
        let previous = self.userLaneConnectingTimeout
        self.userLaneConnectingTimeout = work
        self.userLaneStatusLock.unlock()
        previous?.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + self.userLaneConnectingMaxDuration, execute: work)
    }

    private func cancelUserLaneConnectingTimeout() {
        self.userLaneStatusLock.lock()
        let work = self.userLaneConnectingTimeout
        self.userLaneConnectingTimeout = nil
        self.userLaneStatusLock.unlock()
        work?.cancel()
    }

    /// Bring the user's selected server up, or confirm the one already running.
    func userLaneStart(reason: String) {
        guard AorusUserVPNStore.shared.isActive else {
            userLaneStop(reason: reason)
            return
        }
        // A connection the user just asked for is not last round's verdict, and the row must stop
        // saying "нет соединения" the moment they ask -- synchronously, here, rather than when the
        // queue gets round to the bring-up, because the store change they made has already woken the
        // interface. The lane's own retry and the watchdog are excluded: neither is the user asking
        // for anything, and clearing on those would flip the row back to "соединение" on a timer
        // while nothing is connecting.
        if reason != "retry" && reason != "watchdog" {
            setUserLaneUnreachable(false)
            // And the row starts saying "соединение" here, synchronously, for the same reason. A tap
            // on another server has to look like a connection being made even though the previous
            // endpoint is still up and still carrying traffic while it is made.
            setUserLaneConnecting(true)
            // And whatever is on the queue right now is answering the previous question. Bumped here
            // rather than inside the bring-up, so a round already running sees it immediately.
            bumpUserLaneGeneration()
        }
        // Taken before the core is even asked to start. Between here and a proven inbound,
        // Telegram is pointed at a port nothing is listening on, which is the whole point: a
        // window where MTProto quietly goes direct is a window where the user believes they are
        // on their VPN and are not.
        let userLaneRequired = true
        publishRequirement(required: userLaneRequired)
        queue.async { [weak self] in
            self?.userLaneBringUpLocked(reason: reason)
        }
    }

    /// Tear the user's lane down and hand the connection back to whatever the switches say.
    func userLaneStop(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.beginUserLaneRound()
            guard self.userLanePort != nil || self.userLaneServerId != nil else {
                self.cancelUserLaneRetryLocked(resetAttempt: true)
                self.setUserLaneConnecting(false)
                self.userLaneServer = nil
                self.userLaneUdpEnabled = nil
                self.userLaneMuxEnabled = nil
                self.userLaneReleaseTelegramLocked()
                return
            }
            self.recordDiagnostic(stage: "user_core_stopping", detail: reason)
            self.userLaneTearDownLocked()
        }
    }

    private func userLaneBringUpLocked(reason: String, requeues: Int = 0) {
        // Re-entered from inside a transition -- the signed lane's own restart, or a stop, reaching
        // this through a teardown. Returning here is how a request could be dropped: the user had
        // asked for a server, the round that would have dialled it went nowhere, and the connection
        // then waited for the next thing to happen to it (a watchdog tick, or a restart of the
        // client) instead of coming up now. So it goes back on the queue instead of being thrown
        // away.
        //
        // The queue is serial, so the block below cannot run until whatever holds the flag has let
        // it go, and one turn is normally all it takes; the count is a bound on the pathological
        // case rather than an expected path, and the store is consulted each time so a lane the
        // user has since turned off stops being retried.
        if transitionInProgress {
            guard requeues < 20, AorusUserVPNStore.shared.isActive else {
                // Both ways out of the requeue used to be a silent `return`, and that is the other
                // half of the stuck spinner: the flag stayed set, no verdict was ever recorded, and
                // nothing was queued that would produce one. Whichever of the two it is -- a lane the
                // user turned off underneath this round, or a transition that never let go -- the
                // interface is told where it stands, and a lane that is still enabled gets another
                // attempt on the backoff instead of waiting for the next thing to happen to it.
                if AorusUserVPNStore.shared.isActive {
                    recordDiagnostic(stage: "user_core_requeue_exhausted", errorCode: "user_transition_stuck")
                    setUserLaneUnreachable(true)
                    setUserLaneConnecting(false)
                    scheduleUserLaneRetryLocked()
                } else {
                    setUserLaneConnecting(false)
                }
                return
            }
            recordDiagnostic(stage: "user_core_requeued", detail: reason)
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.userLaneBringUpLocked(reason: reason, requeues: requeues + 1)
            }
            return
        }
        // This round now owns the current generation: everything below is being done for the request
        // that queued it, and a later request will move the number on and cut the round short.
        beginUserLaneRound()
        guard AorusUserVPNStore.shared.isEnabled,
              let server = AorusUserVPNStore.shared.selectedServer else {
            userLaneTearDownLocked()
            return
        }
        let settings = AorusUserVPNStore.shared.selectedConfig
        let udpEnabled = settings?.udpEnabled ?? true
        let muxEnabled = settings?.muxEnabled ?? false
        // Anything other than this lane's own retry is a connection being attempted again, so the
        // last round's verdict stops being the answer the interface reports.
        if reason != "retry" {
            setUserLaneUnreachable(false)
        }

        // Already serving this exact server through a live inbound. A watchdog tick must not
        // interrupt a call to prove something it can check in a few milliseconds.
        if self.userLaneServerId == server.id,
           self.userLaneServer == server,
           self.userLaneUdpEnabled == udpEnabled,
           self.userLaneMuxEnabled == muxEnabled,
           let port = self.userLanePort,
           self.isCoreRunning(),
           self.localSocksIsReady(port: port, timeout: self.localSocksMaxProbeTimeout) {
            self.cancelUserLaneRetryLocked(resetAttempt: true)
            self.setUserLaneConnecting(false)
            self.userLanePublishEndpointLocked(port: port)
            return
        }

        transitionInProgress = true
        defer { transitionInProgress = false }

        recordDiagnostic(stage: "user_core_starting", detail: reason)
        _ = invoke(method: "stopXray")
        waitForCoreStop()
        userLanePort = nil
        userLaneServerId = nil
        userLaneServer = nil
        userLaneUdpEnabled = nil
        userLaneMuxEnabled = nil
        setUserLaneServingServerId(nil)
        // Whatever the signed lane thought it was serving died with that core.
        activePort = nil
        activeEndpoint = nil

        // A dead server must not make a dead client: a subscription carries a dozen servers
        // precisely because some of them are down, and a backoff on a fixed selection retries the
        // one that just failed and nothing else. So the round walks a few candidates, the chosen
        // one first and the rest by measured handshake, and stops at the first that comes up.
        var candidates = AorusUserVPNStore.shared.bringUpCandidates(limit: userLaneCandidatesPerRound)
        if candidates.isEmpty {
            candidates = [AorusVlessCandidate(server: server, udpEnabled: udpEnabled, muxEnabled: muxEnabled)]
        }
        // The walk is bounded in wall-clock time as well as in candidates. Candidates are what a
        // round is allowed to try; this is what it is allowed to take -- see
        // `userLaneRoundMaxDuration`. Cutting the tail of a walk costs the last candidate an attempt
        // it gets again on the next round; not cutting it costs the user a status that never arrives.
        let roundDeadline = Date().timeIntervalSince1970 + userLaneRoundMaxDuration
        for (index, candidate) in candidates.enumerated() {
            guard AorusUserVPNStore.shared.isActive else { break }
            guard index == 0 || Date().timeIntervalSince1970 < roundDeadline else {
                recordDiagnostic(stage: "user_round_deadline", detail: "candidate_\(index)")
                break
            }
            // The user picked a different server while this round was working. The round that their
            // tap queued is sitting right behind this one, so there is nothing to do but stop.
            guard !userLaneRoundIsStale else {
                recordDiagnostic(stage: "user_round_superseded", detail: reason)
                return
            }
            if index > 0 {
                recordDiagnostic(stage: "user_failover", detail: "candidate_\(index)")
            }
            guard userLaneStartServerLocked(candidate: candidate, patient: index == 0, deadline: roundDeadline) else {
                continue
            }
            // The stored selection follows the lane only once the lane is actually up. Moving it on
            // every failed attempt is what made the ticked server change several times a second
            // while nothing connected, and a choice the user made by hand is not ours to overwrite
            // with one that failed as well.
            if candidate.server.id != server.id {
                AorusUserVPNStore.shared.selectServer(id: candidate.server.id)
            }
            return
        }

        // A superseded round must not leave a verdict behind: "нет соединения" from a walk the user
        // interrupted, or a backoff timer competing with the round they actually asked for.
        guard !userLaneRoundIsStale else {
            recordDiagnostic(stage: "user_round_superseded", detail: reason)
            return
        }
        recordDiagnostic(stage: "user_core_unavailable", errorCode: "user_endpoint_unreachable")
        setUserLaneUnreachable(true)
        // The walk is over and nothing came up, so the row stops claiming a connection is being made
        // and says what actually happened.
        setUserLaneConnecting(false)
        // An explicitly enabled VPN must not fail open through the direct route. Its settings
        // screen remains local and usable while retries continue in the background.
        userLaneBlockTelegramLocked()
        scheduleUserLaneRetryLocked()
    }

    /// One candidate server, on the first loopback port that will take it.
    ///
    /// Returns true once Telegram has been pointed at an inbound that has been proven end to end.
    /// `patient` is the first candidate of a round: it gets the full preflight budget because it is
    /// the server the user chose, and the ones after it get the sweep budget so that walking a
    /// subscription costs seconds rather than minutes. `deadline` is the round's, and the first port
    /// is tried regardless of it: a candidate worth starting is worth one attempt.
    private func userLaneStartServerLocked(candidate: AorusVlessCandidate, patient: Bool, deadline: TimeInterval) -> Bool {
        let server = candidate.server
        for (portIndex, port) in Self.candidatePorts.enumerated() {
            guard AorusUserVPNStore.shared.isActive else { return false }
            // Checked per port as well as per candidate: the port scan below is itself a walk with a
            // core start and a preflight in it, and a tap on another server should not have to wait
            // for the end of one.
            guard !userLaneRoundIsStale else { return false }
            guard portIndex == 0 || Date().timeIntervalSince1970 < deadline else { return false }
            guard localPortIsAvailable(port) else { continue }
            guard let json = AorusVlessLink.xrayConfiguration(
                server: server,
                localPort: port,
                udpEnabled: candidate.udpEnabled,
                muxEnabled: candidate.muxEnabled
            ) else {
                recordDiagnostic(stage: "user_config_invalid", errorCode: "config_build_failed")
                return false
            }
            let response = invoke(method: "runXrayFromJson", payload: ["configJSON": json])
            guard response?.success == true else {
                recordDiagnostic(
                    stage: "user_core_start_failed",
                    errorCode: response?.error ?? "core_rejected_config",
                    localPort: port
                )
                _ = invoke(method: "stopXray")
                waitForCoreStop()
                continue
            }
            guard waitForCoreAndLocalSocks(port: port, endpointPriority: 0) else {
                recordDiagnostic(stage: "user_local_socks_timeout", errorCode: "local_socks_unavailable", localPort: port)
                _ = invoke(method: "stopXray")
                waitForCoreStop()
                continue
            }
            // The inbound answering only proves the core bound a socket. This proves the
            // credential, the transport and the server all work end to end, before anything is
            // told to send its traffic there.
            let preflight = self.realityPreflight(
                port: port,
                endpointPriority: nil,
                timeout: patient ? self.preflightPatientTimeout : self.preflightFastTimeout
            )
            guard preflight == .ready else {
                recordDiagnostic(
                    stage: "user_preflight_failed",
                    errorCode: preflight.diagnosticCode,
                    localSocksReady: preflight.localSocksReady,
                    localPort: port
                )
                _ = invoke(method: "stopXray")
                waitForCoreStop()
                continue
            }
            userLanePort = port
            userLaneServerId = server.id
            userLaneServer = server
            userLaneUdpEnabled = candidate.udpEnabled
            userLaneMuxEnabled = candidate.muxEnabled
            setUserLaneServingServerId(server.id)
            setUserLaneUnreachable(false)
            // Proven end to end and about to be published: this is the one moment the row is
            // entitled to say "подключено".
            setUserLaneConnecting(false)
            cancelUserLaneRetryLocked(resetAttempt: true)
            recordDiagnostic(stage: "user_core_ready", localSocksReady: true, localPort: port)
            userLanePublishEndpointLocked(port: port)
            return true
        }
        return false
    }

    private func userLaneTearDownLocked() {
        cancelUserLaneRetryLocked(resetAttempt: true)
        setUserLaneUnreachable(false)
        setUserLaneConnecting(false)
        if userLanePort != nil || isCoreRunning() {
            _ = invoke(method: "stopXray")
            waitForCoreStop()
        }
        userLanePort = nil
        userLaneServerId = nil
        userLaneServer = nil
        userLaneUdpEnabled = nil
        userLaneMuxEnabled = nil
        setUserLaneServingServerId(nil)
        activePort = nil
        activeEndpoint = nil
        userLaneReleaseTelegramLocked()
    }

    /// Point Telegram back at whatever the rest of the client believes.
    ///
    /// The requirement is read from the hybrid route rather than hardcoded off: if the user has
    /// their VPN off and the no-VPN mode on, the signed tunnel may be the thing carrying traffic
    /// a moment from now, and publishing a flat "not required" would tear that down too.
    private func userLaneReleaseTelegramLocked() {
        clearEndpoint(postUpdate: false)
        let inheritedRequirement = AorusHybridRoute.shared.tunnelIsRequired
        publishRequirement(required: inheritedRequirement)
    }

    private func userLaneBlockTelegramLocked() {
        clearEndpoint(postUpdate: false)
        // Fail closed only while the user-owned lane is still enabled. Reading the durable
        // state here also prevents a queued failed start from re-blocking Telegram after the
        // switch was turned off while Xray was stopping.
        let userLaneRequired = AorusUserVPNStore.shared.isActive
        publishRequirement(required: userLaneRequired)
    }

    private func userLanePublishEndpointLocked(port: Int) {
        guard AorusUserVPNStore.shared.isActive, (1 ... 65_535).contains(port),
              let store = UserDefaults(suiteName: Self.suiteName) else {
            if AorusUserVPNStore.shared.isActive {
                userLaneBlockTelegramLocked()
            } else {
                userLaneReleaseTelegramLocked()
            }
            return
        }
        store.set([
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "port": port,
            "updatedAt": Date().timeIntervalSince1970
        ], forKey: Self.endpointKey)
        // Strictly after the port is on disk, and last, because publishing the requirement is
        // what wakes the observers that go looking for it.
        let userLaneRequired = true
        publishRequirement(required: userLaneRequired)
    }

    private func scheduleUserLaneRetryLocked() {
        guard AorusUserVPNStore.shared.isActive else { return }
        userLaneRetryWorkItem?.cancel()
        let delayIndex = min(userLaneRetryAttempt, restartRetryDelays.count - 1)
        let delay = restartRetryDelays[delayIndex]
        userLaneRetryAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.userLaneRetryWorkItem = nil
            self.userLaneBringUpLocked(reason: "retry")
        }
        userLaneRetryWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelUserLaneRetryLocked(resetAttempt: Bool) {
        userLaneRetryWorkItem?.cancel()
        userLaneRetryWorkItem = nil
        if resetAttempt {
            userLaneRetryAttempt = 0
        }
    }
}
