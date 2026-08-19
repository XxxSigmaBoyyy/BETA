import Foundation
import CryptoKit
import Network
import Security

// Runtime REALITY provisioner. The Worker authenticates the build with HMAC,
// the device with a persistent P-256 key, and returns a short-lived profile
// signed by the License API's Ed25519 key. No VLESS credential is stored here.

private struct AorusRealityWorkerResponse: Decodable {
    let schema: Int
    let ttl: TimeInterval
    let realityEnvelope: AorusRealityEnvelope
}

private struct ATunnelDiagData: Codable {
    struct Server: Codable {
        let region: String
        let endpointPriority: Int
        let available: Bool
        let active: Bool
        let latencyMs: Int?
        let jitterMs: Int?
        let lossCount: Int
        /// Control-plane identity (`de_direct`, `fi_via_moscow`, …). The UI names and
        /// flags a card from this and `country`, never from priority or address — both
        /// of those change when routes are re-provisioned, and the card would follow.
        /// Optional so a diagnostics blob written by an older build still decodes.
        let id: String?
        let country: String?
        let routeType: String?
        let via: String?
        /// When the latency was taken, so the UI can tell a fresh reading from a stale one
        /// instead of presenting an old number as current.
        let measuredAt: Double?
    }
    let servers: [Server]
    let callTunnel: Bool
    let updatedAt: Double
}

private struct AorusEndpointProbeMetrics {
    let latency: TimeInterval?
    let jitter: TimeInterval?
    let lossCount: Int
}

public final class AorusProxyManager {
    public static let shared = AorusProxyManager()

    private let apiSession: URLSession
    private let stateQueue = DispatchQueue(label: "com.aorusgram.reality.provision", qos: .utility)
    private let probeQueue = DispatchQueue(label: "com.aorusgram.reality.probe", qos: .utility, attributes: .concurrent)
    private let pathQueue = DispatchQueue(label: "com.aorusgram.reality.path", qos: .utility)
    private let pathMonitor = NWPathMonitor()
    private let lock = NSLock()

    private var profile: AorusRealityProfile?
    private var rankedEndpoints: [AorusRealityEndpoint] = []
    private var statuses: [ATunnelDiagData.Server] = []
    private var activeEndpoint: AorusRealityEndpoint?
    private var inFlight = false
    private var generation: UInt64 = 0
    private var currentTask: URLSessionDataTask?
    private var nextRefreshAt = Date.distantPast
    private var refreshTimer: DispatchSourceTimer?
    private var provisioningRetryWorkItem: DispatchWorkItem?
    private var provisioningRetryGeneration: UInt64 = 0
    private var provisioningRetryAttempt = 0
    private var lastPathSignature: String?
    private var pathSettleWork: DispatchWorkItem?
    private var lastDiagnosticRefresh = Date.distantPast
    private var probeGeneration: UInt64 = 0
    private var watchdogTimer: DispatchSourceTimer?
    private var penalizedEndpoints: [String: Date] = [:]
    private var lastFailoverAt = Date.distantPast

    private let keyVersion = "1"
    private let pathSettleDelay: TimeInterval = 1.25
    private let diagnosticCooldown: TimeInterval = 20
    private let mtprotoUnhealthyKey = "aorusgram_proxy_unhealthy_since"
    private let mtprotoConnectionStateKey = "aorusgram_vless_connection_state"
    private let lastGoodEndpointKey = "aorusgram_reality_last_good_endpoint"
    private let mtprotoUnhealthyThreshold: TimeInterval = 8
    private let mtprotoStallThreshold: TimeInterval = 15
    private let failoverCooldown: TimeInterval = 20
    private let endpointPenaltyDuration: TimeInterval = 300
    private let watchdogInterval: TimeInterval = 5
    private let provisioningRetryDelays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
    /// How long a latency reading stays meaningful. Past this the UI must say it is
    /// measuring rather than present an old number as current.
    static let latencyTTL: TimeInterval = 90
    /// Consecutive health cycles a challenger has to stay better before a performance
    /// switch. One cycle is a single noisy sample of a shared radio; three in a row is a
    /// property of the path. Hard failure of the current endpoint ignores this entirely.
    private let requiredWinningCycles = 3
    /// Endpoints probed at once. Probes *within* one endpoint must stay sequential — that
    /// is what stopped later probes riding a path the first one warmed, which is where the
    /// implausible readings came from. Different endpoints are different hosts and share no
    /// such path, so running them together costs nothing in accuracy and is what keeps a
    /// sweep to the length of its slowest endpoint rather than the sum of all of them.
    /// One socket per endpoint is not a storm.
    private let maxConcurrentEndpointProbes = 4
    private var challengerStreak: [String: Int] = [:]

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        apiSession = URLSession(
            configuration: configuration,
            delegate: AorusPinnedSessionDelegate.shared,
            delegateQueue: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onForceProbeRequest),
            name: NSNotification.Name("aorusgram_request_probe"),
            object: nil
        )
        pathMonitor.pathUpdateHandler = { [weak self] path in self?.pathDidUpdate(path) }
        pathMonitor.start(queue: pathQueue)
        startWatchdog()
        writeDiagnostics()
    }

    private var licenseAllowsReality: Bool {
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

    func licenseDidLock() {
        clearProvisioning(stopTunnel: true)
    }

    func realityEndpointDidActivate(_ endpoint: AorusRealityEndpoint) {
        lock.lock()
        let didChangeEndpoint = activeEndpoint != endpoint
        activeEndpoint = endpoint
        penalizedEndpoints.removeValue(forKey: endpointKey(endpoint))
        if let index = rankedEndpoints.firstIndex(of: endpoint), index != 0 {
            rankedEndpoints.remove(at: index)
            rankedEndpoints.insert(endpoint, at: 0)
        }
        statuses = statuses.map {
            ATunnelDiagData.Server(
                region: $0.region,
                endpointPriority: $0.endpointPriority,
                available: $0.available,
                active: $0.endpointPriority == endpoint.priority,
                latencyMs: $0.latencyMs,
                jitterMs: $0.jitterMs,
                lossCount: $0.lossCount,
                id: $0.id,
                country: $0.country,
                routeType: $0.routeType,
                via: $0.via,
                measuredAt: $0.measuredAt
            )
        }
        lock.unlock()
        // Which bridge actually carried traffic, so the next cold start can begin with it
        // instead of waiting for a sweep to say the same thing.
        rememberGoodEndpoint(endpoint)
        if didChangeEndpoint {
            resetMTProtoHealthGracePeriod()
        }
        writeDiagnostics()
    }

    func realityEndpointDidFail(_ endpoint: AorusRealityEndpoint) {
        lock.lock()
        penalizedEndpoints[endpointKey(endpoint)] = Date().addingTimeInterval(endpointPenaltyDuration)
        if activeEndpoint == endpoint {
            activeEndpoint = nil
        }
        if let index = rankedEndpoints.firstIndex(of: endpoint) {
            rankedEndpoints.remove(at: index)
            rankedEndpoints.append(endpoint)
        }
        statuses = statuses.map {
            guard $0.endpointPriority == endpoint.priority else { return $0 }
            return ATunnelDiagData.Server(
                region: $0.region,
                endpointPriority: $0.endpointPriority,
                available: false,
                active: false,
                latencyMs: $0.latencyMs,
                jitterMs: $0.jitterMs,
                lossCount: $0.lossCount,
                id: $0.id,
                country: $0.country,
                routeType: $0.routeType,
                via: $0.via,
                measuredAt: $0.measuredAt
            )
        }
        lock.unlock()
        writeDiagnostics()
    }

    public func refresh(force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard licenseAllowsReality else {
            clearProvisioning(stopTunnel: true)
            DispatchQueue.main.async { completion?(false) }
            return
        }
        // Telegram is reaching its datacentres on its own, so there is nothing to provision.
        // No signed profile is requested at all until the route decision says direct is
        // blocked, which is also one fewer request from a client that has no need of one.
        guard AorusHybridRoute.shared.allowsTunnelBringUp else {
            DispatchQueue.main.async { completion?(false) }
            return
        }

        lock.lock()
        if !force, let profile, profile.isValid(for: DeviceFingerprint.deviceHash()), Date() < nextRefreshAt {
            let endpoints = rankedEndpoints
            lock.unlock()
            AorusRealityManager.shared.profileDidVerify()
            AorusRealityManager.shared.apply(profile: profile, rankedEndpoints: endpoints)
            DispatchQueue.main.async { completion?(true) }
            return
        }
        var supersededTask: URLSessionDataTask?
        if inFlight {
            // A forced refresh is the recovery path — the network just came back, or the
            // watchdog gave up on the current profile. Dropping it because an earlier request
            // is still sitting on a socket that is not going to answer is how a cold start
            // ended up waiting out the whole retry ladder with no route at all.
            guard force else {
                lock.unlock()
                DispatchQueue.main.async { completion?(false) }
                return
            }
            supersededTask = currentTask
            currentTask = nil
        }
        inFlight = true
        generation &+= 1
        let requestGeneration = generation
        lock.unlock()
        // Bumping the generation above already made the old response a no-op.
        supersededTask?.cancel()

        guard let signedRequest = buildSignedRequest() else {
            // Keychain can be briefly unavailable while the device is unlocking.
            // Keep the subscribed session fail-closed, but do not strand it until
            // the next foreground transition: retry the complete signed flow.
            handleFetchFailure(generation: requestGeneration, completion: completion)
            return
        }

        let task = apiSession.dataTask(with: signedRequest) { [weak self] data, response, _ in
            guard let self else { return }
            self.lock.lock()
            let current = self.generation == requestGeneration
            self.lock.unlock()
            guard current else { return }

            guard let http = response as? HTTPURLResponse else {
                self.handleFetchFailure(generation: requestGeneration, completion: completion)
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                // An authorization rejection invalidates the current tunnel
                // immediately. Retry only to recover from a stale edge/cache;
                // traffic remains fail-closed and no rejected profile is reused.
                self.handleProvisioningRejection(generation: requestGeneration, completion: completion)
                return
            }

            AorusRealityManager.shared.recordProxyEvent(
                stage: "profile_http",
                detail: "status=\(http.statusCode)"
            )
            guard http.statusCode == 200 else {
                if http.statusCode == 408 || http.statusCode == 429 || (500 ... 599).contains(http.statusCode) {
                    self.handleFetchFailure(generation: requestGeneration, completion: completion)
                } else {
                    // Unknown client errors must not become a permanent closed-port
                    // state. Discard all tunnel material, then retry from scratch.
                    self.handleProvisioningRejection(generation: requestGeneration, completion: completion)
                }
                return
            }

            // Never accept malformed control-plane data. A still-valid, previously
            // signed profile may run only until its own signed expiry; otherwise the
            // client stays fail-closed and retries provisioning with bounded backoff.
            guard let data, data.count <= 70_000,
                  let worker = try? JSONDecoder().decode(AorusRealityWorkerResponse.self, from: data),
                  worker.schema == 2,
                  (1 ... 300).contains(worker.ttl) else {
                self.handleFetchFailure(generation: requestGeneration, completion: completion)
                return
            }

            let deviceHash = DeviceFingerprint.deviceHash()
            guard let profile = AorusRealityEnvelopeVerifier.decode(
                worker.realityEnvelope,
                expectedDeviceHash: deviceHash
            ) else {
                self.handleFetchFailure(generation: requestGeneration, completion: completion)
                return
            }

            guard self.licenseAllowsReality else {
                self.clearProvisioning(stopTunnel: true)
                self.finish(generation: requestGeneration, success: false, completion: completion)
                return
            }

            AorusRealityManager.shared.profileDidVerify()
            AorusRealityManager.shared.recordProxyEvent(
                stage: "profile_decoded",
                detail: "endpoints=\(profile.endpoints.count) valid=\(profile.validEndpoints.count)"
            )
            // Start on a provisional order and measure afterwards. Ranking is a measurement,
            // and a measurement costs time — a second on a clean network, several when one
            // bridge is quietly blocked — and for all of it Telegram has no route at all.
            // That wait is what a cold start with no login code actually was. The order below
            // is the one the control plane signed, with the bridge that last worked on this
            // device in front, so the sweep becomes an improvement rather than a precondition.
            let provisional = self.provisionalOrder(profile.validEndpoints)
            let provisionalCards = self.provisionalStatuses(provisional)
            self.lock.lock()
            let stillCurrent = self.generation == requestGeneration
            if stillCurrent {
                self.profile = profile
                self.rankedEndpoints = provisional
                self.statuses = provisionalCards
                self.activeEndpoint = nil
                let remaining = max(1, TimeInterval(profile.expiresAt) - Date().timeIntervalSince1970)
                let delay = max(1, min(worker.ttl, remaining))
                self.nextRefreshAt = Date().addingTimeInterval(delay)
                self.provisioningRetryGeneration &+= 1
                self.provisioningRetryAttempt = 0
            }
            let retry = stillCurrent ? self.provisioningRetryWorkItem : nil
            if stillCurrent { self.provisioningRetryWorkItem = nil }
            self.lock.unlock()
            guard stillCurrent else { return }

            retry?.cancel()
            self.scheduleRefresh()
            self.writeDiagnostics()
            AorusRealityManager.shared.recordProxyEvent(
                stage: "provisional_order",
                endpointId: provisional.first?.stableId,
                detail: "endpoints=\(provisional.count)"
            )
            AorusRealityManager.shared.apply(profile: profile, rankedEndpoints: provisional)
            self.finish(generation: requestGeneration, success: true, completion: completion)

            // Now that there is a route, find out which bridge deserved it. `defendActive` is
            // off because the endpoint this started on was a guess, not a reading, so there is
            // nothing yet for the hysteresis to defend. apply() still keeps a healthy running
            // endpoint whatever the new order says, so a better order cannot cost the session
            // that has come up in the meantime.
            self.rankEndpoints(profile.validEndpoints, defendActive: false) { ranked, statuses in
                guard self.licenseAllowsReality else {
                    self.clearProvisioning(stopTunnel: true)
                    return
                }
                self.lock.lock()
                let unchanged = self.generation == requestGeneration && self.profile == profile
                if unchanged {
                    self.rankedEndpoints = ranked
                    self.statuses = statuses
                }
                self.lock.unlock()
                guard unchanged else { return }

                self.writeDiagnostics()
                AorusRealityManager.shared.apply(profile: profile, rankedEndpoints: ranked)
            }
        }
        lock.lock()
        currentTask = task
        lock.unlock()
        task.resume()
    }

    private func handleFetchFailure(generation: UInt64, completion: ((Bool) -> Void)?) {
        lock.lock()
        let usable = profile?.isValid(for: DeviceFingerprint.deviceHash()) == true
        let cachedProfile = profile
        let endpoints = rankedEndpoints
        if usable, let cachedProfile {
            let remaining = max(1, TimeInterval(cachedProfile.expiresAt) - Date().timeIntervalSince1970)
            nextRefreshAt = Date().addingTimeInterval(min(15, remaining))
        }
        lock.unlock()
        if usable, let cachedProfile {
            AorusRealityManager.shared.apply(profile: cachedProfile, rankedEndpoints: endpoints)
            scheduleRefresh()
        } else {
            clearProvisioning(stopTunnel: true, cancelProvisioningRetry: false)
            scheduleProvisioningRetry()
        }
        finish(generation: generation, success: usable, completion: completion)
    }

    /// Handles an authoritative HTTP rejection without weakening fail-closed.
    /// Existing VLESS material is removed immediately; retries can only restore
    /// connectivity after a new authenticated request and signed profile succeed.
    private func handleProvisioningRejection(generation: UInt64, completion: ((Bool) -> Void)?) {
        clearProvisioning(stopTunnel: true, cancelProvisioningRetry: false)
        if licenseAllowsReality {
            scheduleProvisioningRetry()
        }
        finish(generation: generation, success: false, completion: completion)
    }

    private func finish(generation: UInt64, success: Bool, completion: ((Bool) -> Void)?) {
        lock.lock()
        if self.generation == generation {
            inFlight = false
            currentTask = nil
        }
        lock.unlock()
        DispatchQueue.main.async { completion?(success) }
    }

    private func clearProvisioning(stopTunnel: Bool, cancelProvisioningRetry: Bool = true) {
        lock.lock()
        generation &+= 1
        let task = currentTask
        currentTask = nil
        inFlight = false
        profile = nil
        rankedEndpoints.removeAll(keepingCapacity: false)
        statuses.removeAll(keepingCapacity: false)
        activeEndpoint = nil
        penalizedEndpoints.removeAll(keepingCapacity: false)
        lastFailoverAt = .distantPast
        nextRefreshAt = .distantPast
        let timer = refreshTimer
        refreshTimer = nil
        let retry: DispatchWorkItem?
        if cancelProvisioningRetry {
            provisioningRetryGeneration &+= 1
            provisioningRetryAttempt = 0
            retry = provisioningRetryWorkItem
            provisioningRetryWorkItem = nil
        } else {
            retry = nil
        }
        lock.unlock()
        task?.cancel()
        timer?.cancel()
        retry?.cancel()
        UserDefaults.standard.set(0, forKey: mtprotoUnhealthyKey)
        UserDefaults.standard.removeObject(forKey: mtprotoConnectionStateKey)
        writeDiagnostics()
        if stopTunnel { AorusRealityManager.shared.licenseDidLock() }
    }

    /// A clean install has no VLESS profile on disk by design. If the first signed
    /// provisioning request races network startup, keep the subscribed session
    /// fail-closed and retry with bounded backoff. Every attempt re-evaluates the
    /// verified, device-bound license snapshot; revocation/expiry cancels the loop.
    private func scheduleProvisioningRetry() {
        guard licenseAllowsReality else {
            clearProvisioning(stopTunnel: true)
            return
        }

        lock.lock()
        provisioningRetryGeneration &+= 1
        let retryGeneration = provisioningRetryGeneration
        let delayIndex = min(provisioningRetryAttempt, provisioningRetryDelays.count - 1)
        let delay = provisioningRetryDelays[delayIndex]
        provisioningRetryAttempt = min(provisioningRetryAttempt + 1, provisioningRetryDelays.count - 1)
        let previous = provisioningRetryWorkItem
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.provisioningRetryGeneration == retryGeneration
            if current { self.provisioningRetryWorkItem = nil }
            self.lock.unlock()
            guard current else { return }
            guard self.licenseAllowsReality else {
                self.clearProvisioning(stopTunnel: true)
                return
            }
            self.refresh(force: true)
        }
        provisioningRetryWorkItem = work
        lock.unlock()

        previous?.cancel()
        stateQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func buildSignedRequest() -> URLRequest? {
        guard licenseAllowsReality,
              !AorusSessionMetrics.metricFlag,
              !UserDefaults.standard.bool(forKey: "c0a8b1e2-6f4d-4a9c-b3e7-1d520f8a6b34") else {
            return nil
        }
        guard let url = URL(string: Obf.reveal(Obf.url)) else { return nil }
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = Self.randomHex(16)
        let device = DeviceFingerprint.deviceHash()
        guard let proof = AorusRealityDeviceIdentity.proof(
            timestamp: timestamp,
            nonce: nonce,
            deviceHash: device
        ) else { return nil }

        let message = "\(timestamp)\n\(nonce)\n\(device)\n\(keyVersion)"
        guard let signature = Obf.withRevealedBytes(Obf.k, { keyBytes in
            hmacHex(message: message, keyHexBytes: keyBytes)
        }) else { return nil }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(Obf.reveal(Obf.ua), forHTTPHeaderField: "User-Agent")
        request.setValue(timestamp, forHTTPHeaderField: "X-Aorus-Ts")
        request.setValue(nonce, forHTTPHeaderField: "X-Aorus-Nonce")
        request.setValue(device, forHTTPHeaderField: "X-Aorus-Device")
        request.setValue(keyVersion, forHTTPHeaderField: "X-Aorus-Kv")
        request.setValue(signature, forHTTPHeaderField: "X-Aorus-Sign")
        request.setValue(proof.publicKey, forHTTPHeaderField: "X-Aorus-Device-Key")
        request.setValue(proof.signature, forHTTPHeaderField: "X-Aorus-Device-Proof")
        return request
    }

    private func rankEndpoints(
        _ endpoints: [AorusRealityEndpoint],
        defendActive: Bool = true,
        completion: @escaping ([AorusRealityEndpoint], [ATunnelDiagData.Server]) -> Void
    ) {
        let group = DispatchGroup()
        let resultsLock = NSLock()
        var metricsByEndpoint: [String: AorusEndpointProbeMetrics] = [:]

        let probeSlots = DispatchSemaphore(value: maxConcurrentEndpointProbes)
        // Every enter() happens before the loop is handed off, otherwise notify could fire
        // against a group nothing has entered yet.
        for _ in endpoints {
            group.enter()
        }
        // rankEndpoints is called from the provisioning response handler, which runs on a
        // URLSession delegate thread. Waiting for probe slots there would hold one of that
        // pool's threads for the length of the whole sweep and delay unrelated requests,
        // including the licence check, so the waiting happens on our own queue.
        probeQueue.async {
            for endpoint in endpoints {
                probeSlots.wait()
                self.probeEndpoint(endpoint) { metrics in
                    probeSlots.signal()
                    resultsLock.lock()
                    metricsByEndpoint[self.endpointKey(endpoint)] = metrics
                    resultsLock.unlock()
                    group.leave()
                }
            }
        }

        group.notify(queue: stateQueue) {
            self.lock.lock()
            let now = Date()
            self.penalizedEndpoints = self.penalizedEndpoints.filter { $0.value > now }
            let penalties = self.penalizedEndpoints
            self.lock.unlock()
            let sorted = endpoints.sorted { left, right in
                let leftPenalized = penalties[self.endpointKey(left)] != nil
                let rightPenalized = penalties[self.endpointKey(right)] != nil
                if leftPenalized != rightPenalized { return !leftPenalized }
                let leftMetrics = metricsByEndpoint[self.endpointKey(left)]
                let rightMetrics = metricsByEndpoint[self.endpointKey(right)]
                switch (leftMetrics?.latency, rightMetrics?.latency) {
                case (.some, .some):
                    let lhs = self.endpointScore(left, metrics: leftMetrics)
                    let rhs = self.endpointScore(right, metrics: rightMetrics)
                    return lhs == rhs ? left.priority < right.priority : lhs < rhs
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return left.priority < right.priority
                }
            }
            // Hysteresis. A working endpoint is kept unless the challenger is clearly and
            // not marginally faster, because every switch restarts the core and drops the
            // live MTProto session: trading a live connection for three milliseconds on
            // paper is a bad deal, and probe noise alone would keep making it. A current
            // endpoint that has stopped responding is not defended — that failover is
            // immediate.
            let ranked: [AorusRealityEndpoint]
            if defendActive,
               let current = self.activeEndpointSnapshot(),
               let currentMetrics = metricsByEndpoint[self.endpointKey(current)],
               let currentLatency = currentMetrics.latency,
               penalties[self.endpointKey(current)] == nil,
               let challenger = sorted.first, challenger != current,
               let challengerLatency = metricsByEndpoint[self.endpointKey(challenger)]?.latency {
                let absoluteGain = currentLatency - challengerLatency
                let relativeGain = currentLatency > 0 ? absoluteGain / currentLatency : 0
                let gainMs = Int((absoluteGain * 1000).rounded())
                let clearlyBetter = absoluteGain >= 0.020 || relativeGain >= 0.15
                // A margin on one cycle is a sample of a shared radio, not a property of
                // the path. The challenger has to hold that margin across consecutive
                // cycles before the live session is torn down for it.
                self.lock.lock()
                let streak = clearlyBetter ? (self.challengerStreak[self.endpointKey(challenger)] ?? 0) + 1 : 0
                if !clearlyBetter {
                    self.challengerStreak.removeAll(keepingCapacity: true)
                } else {
                    self.challengerStreak = [self.endpointKey(challenger): streak]
                }
                let needed = self.requiredWinningCycles
                self.lock.unlock()
                if clearlyBetter && streak >= needed {
                    AorusRealityManager.shared.recordProxyEvent(
                        stage: "selection_switched",
                        endpointId: challenger.stableId,
                        detail: "gain=\(gainMs)ms cycles=\(streak)/\(needed)"
                    )
                    self.lock.lock()
                    self.challengerStreak.removeAll(keepingCapacity: true)
                    self.lock.unlock()
                    ranked = sorted
                } else {
                    AorusRealityManager.shared.recordProxyEvent(
                        stage: "selection_kept",
                        endpointId: current.stableId,
                        detail: clearlyBetter
                            ? "gain=\(gainMs)ms cycles=\(streak)/\(needed)"
                            : "gain=\(gainMs)ms below_threshold"
                    )
                    ranked = [current] + sorted.filter { $0 != current }
                }
            } else {
                // Current endpoint is gone or unmeasurable: no defending, no streak.
                self.lock.lock()
                self.challengerStreak.removeAll(keepingCapacity: true)
                self.lock.unlock()
                ranked = sorted
            }
            let statuses = endpoints.sorted(by: { $0.priority < $1.priority }).map { endpoint in
                let metrics = metricsByEndpoint[self.endpointKey(endpoint)] ?? AorusEndpointProbeMetrics(
                    latency: nil,
                    jitter: nil,
                    lossCount: 3
                )
                return ATunnelDiagData.Server(
                    region: self.endpointLabel(endpoint),
                    endpointPriority: endpoint.priority,
                    available: metrics.latency != nil,
                    active: false,
                    latencyMs: metrics.latency.map { Int(($0 * 1000).rounded()) },
                    jitterMs: metrics.jitter.map { Int(($0 * 1000).rounded()) },
                    lossCount: metrics.lossCount,
                    id: endpoint.id,
                    country: endpoint.country,
                    routeType: endpoint.routeType,
                    via: endpoint.via,
                    measuredAt: metrics.latency != nil ? Date().timeIntervalSince1970 : nil
                )
            }
            for endpoint in endpoints.sorted(by: { $0.priority < $1.priority }) {
                let available = metricsByEndpoint[self.endpointKey(endpoint)]?.latency != nil
                AorusRealityManager.shared.recordEndpointProbe(
                    priority: endpoint.priority,
                    available: available
                )
            }
            completion(ranked, statuses)
        }
    }

    /// Fingerprint of an endpoint identity, not the identity itself.
    ///
    /// The bridge that worked has to survive a launch to be of any use, which means writing
    /// something to disk. Writing the dial target would put production infrastructure into a
    /// preferences file that ends up in device backups, for no gain: a digest still matches
    /// against the endpoints of a freshly signed profile, and on its own it names nothing.
    private func endpointDigest(_ endpoint: AorusRealityEndpoint) -> String {
        let salted = Data("aorus-reality-endpoint-v1\n\(endpoint.stableId)".utf8)
        return SHA256.hash(data: salted).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func rememberGoodEndpoint(_ endpoint: AorusRealityEndpoint) {
        UserDefaults.standard.set(endpointDigest(endpoint), forKey: lastGoodEndpointKey)
    }

    /// The order to try before anything has been measured: penalised bridges last, the one
    /// that last carried traffic on this device first, then the signed priority order.
    private func provisionalOrder(_ endpoints: [AorusRealityEndpoint]) -> [AorusRealityEndpoint] {
        let lastGood = UserDefaults.standard.string(forKey: lastGoodEndpointKey)
        lock.lock()
        let now = Date()
        penalizedEndpoints = penalizedEndpoints.filter { $0.value > now }
        let penalties = penalizedEndpoints
        lock.unlock()
        // Sorted through the offsets because Swift's sort is not stable, and two bridges that
        // tie on every criterion must not swap places from one launch to the next.
        return endpoints.enumerated().sorted { left, right in
            let leftPenalized = penalties[self.endpointKey(left.element)] != nil
            let rightPenalized = penalties[self.endpointKey(right.element)] != nil
            if leftPenalized != rightPenalized { return !leftPenalized }
            if let lastGood {
                let leftKnownGood = self.endpointDigest(left.element) == lastGood
                let rightKnownGood = self.endpointDigest(right.element) == lastGood
                if leftKnownGood != rightKnownGood { return leftKnownGood }
            }
            if left.element.priority != right.element.priority {
                return left.element.priority < right.element.priority
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// Cards for an order nothing has measured yet.
    ///
    /// `available` with no reading is the UI's "checking" state, which is the truth here.
    /// Reporting unavailable would draw every bridge as down for the second before the first
    /// sweep lands, on exactly the screen a user opens when they are worried about the tunnel.
    private func provisionalStatuses(_ endpoints: [AorusRealityEndpoint]) -> [ATunnelDiagData.Server] {
        lock.lock()
        let previous = statuses
        lock.unlock()
        return endpoints.sorted(by: { $0.priority < $1.priority }).map { endpoint in
            let known = previous.first {
                $0.id == endpoint.id && $0.endpointPriority == endpoint.priority
            }
            return ATunnelDiagData.Server(
                region: self.endpointLabel(endpoint),
                endpointPriority: endpoint.priority,
                available: true,
                active: false,
                latencyMs: known?.latencyMs,
                jitterMs: known?.jitterMs,
                lossCount: known?.lossCount ?? 0,
                id: endpoint.id,
                country: endpoint.country,
                routeType: endpoint.routeType,
                via: endpoint.via,
                measuredAt: known?.measuredAt
            )
        }
    }

    /// Measures an endpoint with a warm-up probe followed by several timed ones, run one
    /// after another.
    ///
    /// The previous version fired every probe at once, which is where the implausible
    /// readings came from: the first connection pays for DNS and route setup and the rest
    /// ride on what it warmed, so the median described a path that had already been opened
    /// rather than the cost of opening one. Running them in sequence and discarding the
    /// first measures the same thing every time.
    ///
    /// A failed probe is recorded as a loss, never as zero — counting a timeout as 0 ms is
    /// how a dead endpoint wins a ranking.
    private func probeEndpoint(
        _ endpoint: AorusRealityEndpoint,
        sampleCount: Int = 4,
        completion: @escaping (AorusEndpointProbeMetrics) -> Void
    ) {
        var samples: [TimeInterval] = []
        var failures = 0

        func runProbe(_ remaining: Int, isWarmUp: Bool) {
            // Once a majority is arithmetically out of reach the endpoint is already
            // unhealthy, and the remaining probes can only spend their full timeout to
            // confirm it. On a blocked network that was the difference between a sweep of
            // seconds and one of tens of seconds before the tunnel even started.
            if !isWarmUp, failures * 2 >= sampleCount {
                self.finishProbe(samples: samples, failures: failures, sampleCount: sampleCount, completion: completion)
                return
            }
            guard remaining > 0 || isWarmUp else {
                self.finishProbe(samples: samples, failures: failures, sampleCount: sampleCount, completion: completion)
                return
            }
            let probeNumber = isWarmUp ? 0 : sampleCount - remaining + 1
            probeLatency(endpoint: endpoint, timeout: 1.2) { latency, family, error in
                AorusRealityManager.shared.recordProxyEvent(
                    stage: "probe",
                    errorCode: error,
                    endpointId: endpoint.stableId,
                    detail: "n=\(probeNumber) warmup=\(isWarmUp) family=\(family) "
                        + (latency.map { "rtt=\(Int(($0 * 1000).rounded()))ms" } ?? "rtt=none")
                )
                if !isWarmUp {
                    if let latency {
                        samples.append(latency)
                    } else {
                        failures += 1
                    }
                }
                // Sequential, so probes never overlap and never share a warmed path.
                self.probeQueue.async {
                    runProbe(isWarmUp ? sampleCount : remaining - 1, isWarmUp: false)
                }
            }
        }
        probeQueue.async { runProbe(sampleCount, isWarmUp: true) }
    }

    /// Median of the successful probes, plus how many were lost.
    ///
    /// An endpoint is only reported as reachable when a majority of its probes came back;
    /// one lucky response among three timeouts describes a path nobody can use.
    private func finishProbe(
        samples: [TimeInterval],
        failures: Int,
        sampleCount: Int,
        completion: @escaping (AorusEndpointProbeMetrics) -> Void
    ) {
        let sorted = samples.sorted()
        guard sorted.count * 2 > sampleCount else {
            AorusRealityManager.shared.recordProxyEvent(
                stage: "probe_unhealthy",
                errorCode: "insufficient_successful_probes",
                detail: "ok=\(sorted.count)/\(sampleCount)"
            )
            completion(AorusEndpointProbeMetrics(latency: nil, jitter: nil, lossCount: max(failures, sampleCount - sorted.count)))
            return
        }
        let median = sorted[sorted.count / 2]
        let jitter = sorted.count > 1 ? (sorted.last ?? median) - (sorted.first ?? median) : 0
        AorusRealityManager.shared.recordProxyEvent(
            stage: "probe_result",
            detail: "median=\(Int((median * 1000).rounded()))ms ok=\(sorted.count)/\(sampleCount)"
        )
        completion(AorusEndpointProbeMetrics(
            latency: median,
            jitter: jitter,
            lossCount: sampleCount - sorted.count
        ))
    }

    /// Address family the connection actually used, read from the established path.
    ///
    /// This is the evidence for NAT64: a hostname that resolves to v6 on a v6-only carrier
    /// proves the synthesis happened, and an IPv4 literal that never connects there proves
    /// it could not. Neither is inferable from the profile, so it has to be observed.
    private static func addressFamily(of connection: NWConnection) -> String {
        guard case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint else {
            return "unknown"
        }
        switch host {
        case .ipv4: return "ipv4"
        case .ipv6: return "ipv6"
        case .name: return "name"
        @unknown default: return "unknown"
        }
    }

    private func probeLatency(
        endpoint: AorusRealityEndpoint,
        timeout: TimeInterval,
        completion: @escaping (TimeInterval?, String, String?) -> Void
    ) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            completion(nil, "unknown", "invalid_port")
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.address), port: port, using: .tcp)
        let startedAt = Date()
        let finishLock = NSLock()
        var finished = false
        let finish: (TimeInterval?, String, String?) -> Void = { latency, family, error in
            finishLock.lock()
            guard !finished else { finishLock.unlock(); return }
            finished = true
            finishLock.unlock()
            connection.cancel()
            completion(latency, family, error)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(Date().timeIntervalSince(startedAt), Self.addressFamily(of: connection), nil)
            case let .failed(error):
                // Errno only: the description can carry the resolved address.
                finish(nil, Self.addressFamily(of: connection), "posix_\(error.errorCode)")
            case .cancelled:
                finish(nil, "unknown", "cancelled")
            default: break
            }
        }
        connection.start(queue: probeQueue)
        probeQueue.asyncAfter(deadline: .now() + timeout) { finish(nil, Self.addressFamily(of: connection), "timeout") }
    }

    private func scheduleRefresh() {
        lock.lock()
        let previous = refreshTimer
        let delay = max(1, nextRefreshAt.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        refreshTimer = timer
        lock.unlock()
        previous?.cancel()
        timer.schedule(deadline: .now() + delay, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            AorusRealityManager.shared.recordProxyEvent(stage: "refresh", detail: "reason=ttl")
            self?.refresh(force: true)
        }
        timer.resume()
    }

    private func pathDidUpdate(_ path: NWPath) {
        let signature = [
            path.status == .satisfied ? "up" : "down",
            path.usesInterfaceType(.wifi) ? "wifi" : "-",
            path.usesInterfaceType(.cellular) ? "cell" : "-",
            path.usesInterfaceType(.other) ? "other" : "-",
            path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
        ].joined(separator: "|")
        lock.lock()
        let isFirstSignature = lastPathSignature == nil
        let changed = lastPathSignature != nil && lastPathSignature != signature
        lastPathSignature = signature
        if changed {
            penalizedEndpoints.removeAll(keepingCapacity: false)
            lastFailoverAt = .distantPast
        }
        let hasRoute = profile?.isValid(for: DeviceFingerprint.deviceHash()) == true
        // A network that has just arrived is a fresh chance, not a continuation of the ladder
        // the failures before it built. Leaving the attempt counter where it stood is how a
        // client whose connectivity turned up thirty seconds late then waited another thirty
        // for its turn to ask again.
        if path.status == .satisfied, !hasRoute {
            provisioningRetryAttempt = 0
        }
        lock.unlock()
        // The first signature is usually the one launch is already acting on, so it is not
        // worth a second sweep — unless that launch has no profile to show for it, which is
        // exactly the cold start that raced its own network coming up.
        let needsBootstrap = path.status == .satisfied && !hasRoute
        guard changed || (isFirstSignature && needsBootstrap) else { return }
        resetMTProtoHealthGracePeriod()

        pathSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, path.status == .satisfied else { return }
            if needsBootstrap {
                self.lock.lock()
                let busy = self.inFlight
                let arrived = self.profile?.isValid(for: DeviceFingerprint.deviceHash()) == true
                self.lock.unlock()
                // Launch still has a request out, or it landed while this was waiting. Either
                // way there is nothing here to rescue, and asking twice for one profile is
                // load on the control plane for nothing.
                guard !busy, !arrived else { return }
            }
            // NETWORK CHANGED in the hybrid design: whether this network needs the tunnel is
            // decided from scratch, and only a network that blocks Telegram gets one. The
            // escalation below is what used to run here unconditionally.
            AorusHybridRoute.shared.networkDidChange()
        }
        pathSettleWork = work
        pathQueue.asyncAfter(deadline: .now() + pathSettleDelay, execute: work)
    }

    @objc private func onForceProbeRequest() {
        lock.lock()
        let allowed = Date().timeIntervalSince(lastDiagnosticRefresh) >= diagnosticCooldown
        if allowed { lastDiagnosticRefresh = Date() }
        lock.unlock()
        guard allowed else {
            writeDiagnostics()
            return
        }
        // On the direct route there is no endpoint set to re-measure; what the user is asking
        // to refresh is the verdict itself.
        if AorusHybridRoute.shared.allowsTunnelBringUp {
            reprobeCurrentProfile()
        } else {
            writeDiagnostics()
            AorusHybridRoute.shared.evaluate(reason: "diagnostics_refresh", force: true)
        }
    }

    /// Called by the route decision once direct has been ruled out: get a signed profile,
    /// measure the signed endpoints, hand the order to the core. This is the "Получаем signed
    /// profile → authenticated route race" leg, and it only ever runs behind that verdict.
    func beginTunnelEscalation(reason: String) {
        AorusRealityManager.shared.recordProxyEvent(
            stage: "tunnel_escalation_started",
            detail: "reason=\(reason)"
        )
        reprobeCurrentProfile()
    }

    /// "Режим без VPN" was switched off. Everything of the tunnel goes: the client is stock
    /// Telegram, on the user's own proxy settings, until they say otherwise.
    func bypassDidTurnOff() {
        clearProvisioning(stopTunnel: true)
    }

    /// Re-measures the signed endpoints and hands the result back to the core.
    ///
    /// `reselectEndpoint` is passed through to the core as "the endpoint running now is the
    /// problem". Without it the core defends whatever is already carrying traffic, which is
    /// right after a path change and wrong after a watchdog failover.
    private func reprobeCurrentProfile(reselectEndpoint: Bool = false) {
        guard licenseAllowsReality else {
            clearProvisioning(stopTunnel: true)
            return
        }
        lock.lock()
        guard let currentProfile = profile,
              currentProfile.isValid(for: DeviceFingerprint.deviceHash()) else {
            lock.unlock()
            refresh(force: true)
            return
        }
        probeGeneration &+= 1
        let currentProbeGeneration = probeGeneration
        lock.unlock()

        rankEndpoints(currentProfile.validEndpoints) { [weak self] ranked, statuses in
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = self.probeGeneration == currentProbeGeneration &&
                self.profile == currentProfile &&
                self.licenseAllowsReality
            if stillCurrent {
                self.rankedEndpoints = ranked
                self.statuses = statuses
                self.activeEndpoint = nil
            }
            self.lock.unlock()
            guard stillCurrent else { return }
            self.writeDiagnostics()
            AorusRealityManager.shared.apply(
                profile: currentProfile,
                rankedEndpoints: ranked,
                reselectEndpoint: reselectEndpoint
            )
        }
    }

    private func startWatchdog() {
        lock.lock()
        guard watchdogTimer == nil else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        watchdogTimer = timer
        lock.unlock()
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
    }

    /// TCP reachability and a running local Xray core do not prove that REALITY can
    /// carry Telegram traffic. Some filtered networks accept the endpoint's TCP
    /// socket but leave MTProto in `connecting` / `updating` forever without ever
    /// setting Telegram's explicit proxy-issue bit. Treat both a sustained explicit
    /// issue and a sustained handshake stall as endpoint failures.
    private func watchdogTick() {
        guard licenseAllowsReality else { return }
        let defaults = UserDefaults.standard
        let now = Date()
        let nowTimestamp = now.timeIntervalSince1970
        let explicitUnhealthySince = defaults.double(forKey: mtprotoUnhealthyKey)

        var failureSince: TimeInterval = 0
        var failureThreshold = mtprotoUnhealthyThreshold
        if explicitUnhealthySince > 0 {
            failureSince = explicitUnhealthySince
        }
        if let connection = defaults.dictionary(forKey: mtprotoConnectionStateKey),
           let pid = connection["pid"] as? NSNumber,
           pid.int32Value == ProcessInfo.processInfo.processIdentifier,
           let state = connection["state"] as? String,
           let since = connection["since"] as? NSNumber {
            switch state {
            case "proxy_issue":
                if failureSince == 0 { failureSince = since.doubleValue }
            case "connecting", "updating":
                failureSince = since.doubleValue
                failureThreshold = mtprotoStallThreshold
            default:
                break
            }
        }
        guard failureSince > 0,
              nowTimestamp - failureSince >= failureThreshold else {
            return
        }

        // The engine has the final word on the direct route. A handshake to port 443 completes
        // on plenty of networks that then drop the session, and this is that client: direct
        // measured fine and did not carry Telegram. Hand the network to the tunnel, and reset
        // the grace period first so the escalation is not judged by the stall that caused it.
        if AorusHybridRoute.shared.mode == .direct {
            resetMTProtoHealthGracePeriod()
            AorusHybridRoute.shared.directRouteDidStall()
            return
        }

        lock.lock()
        guard let profile,
              profile.isValid(for: DeviceFingerprint.deviceHash()),
              now.timeIntervalSince(lastFailoverAt) >= failoverCooldown else {
            lock.unlock()
            return
        }
        // Failing over needs somewhere to go and something to move off, and neither is
        // guaranteed: a profile can sign a single bridge, and a tunnel that never came up has
        // no active endpoint at all. That second case is precisely the client sitting on "no
        // connection" — the one this watchdog exists for — and returning here left it there.
        let canFailover = profile.validEndpoints.count > 1 && activeEndpoint != nil
        if canFailover, let activeEndpoint {
            penalizedEndpoints[endpointKey(activeEndpoint)] = now.addingTimeInterval(endpointPenaltyDuration)
        }
        lastFailoverAt = now
        lock.unlock()

        resetMTProtoHealthGracePeriod()
        guard canFailover else {
            // Nothing to switch to, so rebuild the local path instead: the core re-proves the
            // whole route and restarts itself when it cannot.
            AorusRealityManager.shared.recordProxyEvent(
                stage: "watchdog_rebuild",
                errorCode: "mtproto_unhealthy",
                detail: "reason=no_alternate"
            )
            AorusRealityManager.shared.ensureRunning()
            return
        }
        AorusRealityManager.shared.recordProxyEvent(
            stage: "watchdog_failover",
            errorCode: "mtproto_unhealthy",
            detail: "endpoints=\(profile.validEndpoints.count)"
        )
        reprobeCurrentProfile(reselectEndpoint: true)
    }

    /// A server or path transition gets a fresh handshake window. Preserve the
    /// current state for diagnostics, but never carry an old stall timestamp to the
    /// newly selected signed endpoint.
    private func resetMTProtoHealthGracePeriod() {
        let defaults = UserDefaults.standard
        defaults.set(0, forKey: mtprotoUnhealthyKey)
        guard var connection = defaults.dictionary(forKey: mtprotoConnectionStateKey),
              let pid = connection["pid"] as? NSNumber,
              pid.int32Value == ProcessInfo.processInfo.processIdentifier else {
            return
        }
        let now = Date().timeIntervalSince1970
        connection["since"] = now
        connection["updatedAt"] = now
        defaults.set(connection, forKey: mtprotoConnectionStateKey)
    }

    private func writeDiagnostics() {
        lock.lock()
        let currentStatuses = statuses
        let tunnelEnabled = activeEndpoint != nil &&
            profile?.isValid(for: DeviceFingerprint.deviceHash()) == true
        lock.unlock()
        let diagnostics = ATunnelDiagData(
            servers: currentStatuses,
            callTunnel: tunnelEnabled,
            updatedAt: Date().timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(diagnostics),
              let text = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(text, forKey: "aorusgram_atunnel_status")
    }

    private func activeEndpointSnapshot() -> AorusRealityEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        return activeEndpoint
    }

    private func endpointKey(_ endpoint: AorusRealityEndpoint) -> String {
        "\(endpoint.address):\(endpoint.port)"
    }

    private func endpointScore(
        _ endpoint: AorusRealityEndpoint,
        metrics: AorusEndpointProbeMetrics?
    ) -> TimeInterval {
        guard let latency = metrics?.latency else { return .greatestFiniteMagnitude }
        let jitter = metrics?.jitter ?? 0
        let lossPenalty = TimeInterval(metrics?.lossCount ?? 3) * 0.5
        let priorityBias = TimeInterval(endpoint.priority) * 0.005
        return latency + jitter + lossPenalty + priorityBias
    }

    private func endpointLabel(_ endpoint: AorusRealityEndpoint) -> String {
        if let region = endpoint.region?.trimmingCharacters(in: .whitespacesAndNewlines), !region.isEmpty {
            return region.uppercased()
        }
        // Profiles issued before the signed `region` field was introduced use the
        // stable production priority order. Keep their original ATunnel country UI.
        switch endpoint.priority {
        case 1: return "DE"
        case 2: return "FI"
        default: return "ATunnel \(endpoint.priority)"
        }
    }

    private func hmacHex(message: String, keyHexBytes: [UInt8]) -> String? {
        guard keyHexBytes.count >= 64, keyHexBytes.count.isMultiple(of: 2) else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48 ... 57: return byte - 48
            case 65 ... 70: return byte - 55
            case 97 ... 102: return byte - 87
            default: return nil
            }
        }
        var raw = [UInt8]()
        raw.reserveCapacity(keyHexBytes.count / 2)
        defer { _ = raw.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        for index in stride(from: 0, to: keyHexBytes.count, by: 2) {
            guard let high = nibble(keyHexBytes[index]), let low = nibble(keyHexBytes[index + 1]) else { return nil }
            raw.append((high << 4) | low)
        }
        var keyData = Data(raw)
        defer { _ = keyData.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: keyData))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public extension Notification.Name {
    static let aorusProxyConfigUpdated = Notification.Name("aorusgram_proxy_config_updated")
}

private enum Obf {
    private static let pad: [UInt8] = {
        let s0: [UInt8] = [0x61,0x6f,0x72,0x75,0x73,0x67,0x72,0x61,0x6d,0x3a,0x3a,0x6e]
        let s1: [UInt8] = [0x65,0x74,0x73,0x68,0x69,0x65,0x6c,0x64,0x3a,0x3a,0x76,0x31]
        let s2: [UInt8] = [0x3a,0x3a,0x73,0x68,0x69,0x65,0x6c,0x64,0x2d,0x70,0x61,0x64]
        return Array(SHA256.hash(data: Data(s0 + s1 + s2)))
    }()

    static func reveal(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.indices.map { bytes[$0] ^ pad[$0 % pad.count] }, as: UTF8.self)
    }

    static func withRevealedBytes<Result>(_ bytes: [UInt8], _ body: ([UInt8]) -> Result) -> Result? {
        guard !bytes.isEmpty else { return nil }
        var output = bytes.indices.map { bytes[$0] ^ pad[$0 % pad.count] }
        defer { _ = output.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return body(output)
    }

    static let k: [UInt8] = [
        /*__AORUS_PROXY_KEY_OBFUSCATED__*/
    ]
    static let url: [UInt8] = [211,201,44,46,187,166,205,62,85,172,132,66,177,58,133,130,177,177,147,204,234,71,96,46,188,77,213,63,242,8,242,192,195,196]
    static let ua: [UInt8] = [250,210,42,43,187,219,144,112,89,243,220,66,224,123,199,215,234,191,174,254,174]
}
