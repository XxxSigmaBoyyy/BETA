import Foundation
import UIKit
import AorusBadge

// Fetches the complete public badge roster at lifecycle boundaries. There are no
// per-peer requests: every chat row reads the same local snapshot synchronously.
final class BadgeSnapshotService {
    static let shared = BadgeSnapshotService()

    private let lock = NSLock()
    private var started = false
    private var inFlight = false
    private var nextAllowedUptime: TimeInterval = 0
    private var consecutiveFailures = 0
    private var generation: UInt64 = 0
    private var foregroundObserver: NSObjectProtocol?

    private init() {}

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refreshIfNeeded()
        }
        refreshIfNeeded()
    }

    // Called after a fresh signed /check, /bootstrap or /activate response. It does
    // not bypass coalescing/backoff, so simultaneous launch events remain one call.
    func licenseDidBecomeActive() {
        refreshIfNeeded()
    }

    // Invalidates callbacks from requests that began under an older license state.
    func licenseDidBecomeInactive() {
        lock.lock()
        generation &+= 1
        inFlight = false
        consecutiveFailures = 0
        nextAllowedUptime = 0
        lock.unlock()
    }

    private func refreshIfNeeded() {
        guard LicenseStore.shared.effectiveOfflineStatus().allowsAppAccess else { return }
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        guard started, !inFlight, now >= nextAllowedUptime else {
            lock.unlock()
            return
        }
        inFlight = true
        let requestGeneration = generation
        // Also prevents a foreground notification racing the URLSession completion.
        nextAllowedUptime = now + 15
        lock.unlock()

        LicenseAPIClient.shared.badgeSnapshot { [weak self] result in
            guard let self else { return }
            let completedAt = ProcessInfo.processInfo.systemUptime
            switch result {
            case .success(let snapshot):
                self.lock.lock()
                guard requestGeneration == self.generation else {
                    self.lock.unlock()
                    return
                }
                let assignments = snapshot.badges.mapValues { badges in
                    badges.map { ($0.id.rawValue, $0.until) }
                }
                _ = AorusBadge.replaceServerBadgeSnapshot(
                    assignments,
                    serverNow: snapshot.serverNow,
                    revision: snapshot.revision
                )
                self.inFlight = false
                self.consecutiveFailures = 0
                // Rapid app-switching must not turn foreground events into API spam.
                self.nextAllowedUptime = completedAt + 5 * 60
                self.lock.unlock()
            case .failure:
                self.lock.lock()
                guard requestGeneration == self.generation else {
                    self.lock.unlock()
                    return
                }
                self.inFlight = false
                self.consecutiveFailures = min(self.consecutiveFailures + 1, 6)
                let exponent = max(0, self.consecutiveFailures - 1)
                let delay = min(30.0 * pow(2.0, Double(exponent)), 15.0 * 60.0)
                self.nextAllowedUptime = completedAt + delay
                self.lock.unlock()
            }
        }
    }
}
