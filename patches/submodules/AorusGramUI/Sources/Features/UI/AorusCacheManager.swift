import Foundation
import UIKit
import AorusGram

// MARK: - AorusCacheManager
//
// Periodic cache auto-cleaning. Replaces the former RAM overlay / RAM auto-clean.
// When enabled, on the user-selected interval (in hours) it wipes:
//   the deleted-messages SQLite cache (DeletedMessagesCache)
//   URL / media response caches
//   media downloaded by the Wall from channels the reader is not subscribed to
// Toggled from Settings → Performance → "Auto-Clean Cache" (off by default).

public final class AorusCacheManager {
    public static let shared = AorusCacheManager()
    private init() {}

    private var cleanTimer: Timer?
    private var observing = false

    /// Reclaims the Wall's media. Installed by the Wall itself, which is the only place with
    /// an account context — this class deliberately has none, and giving it one to reach the
    /// media box would tie a settings helper to the engine.
    ///
    /// Entries are keyed by Telegram account id. A single callback is not sufficient here:
    /// every account owns a separate media box, and constructing one Wall must not detach the
    /// cleanup registered by another account.
    private var wallMediaCleanups: [Int64: () -> Void] = [:]

    public func registerWallMediaCleanup(accountId: Int64, cleanup: @escaping () -> Void) {
        if Thread.isMainThread {
            self.wallMediaCleanups[accountId] = cleanup
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.wallMediaCleanups[accountId] = cleanup
            }
        }
    }

    // MARK: - Public entry point

    public func refresh() {
        DispatchQueue.main.async { [weak self] in self?._doRefresh() }
    }

    private func _doRefresh() {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(_onSettings),
                name: .aorusSettingsChanged, object: nil)
        }
        let mgr = AorusGramManager.shared
        _applyAutoClean(enabled: mgr.cacheAutoClean, intervalHours: mgr.cacheCleanInterval)
    }

    @objc private func _onSettings() {
        DispatchQueue.main.async { [weak self] in self?._doRefresh() }
    }

    // MARK: - Scheduling

    private func _applyAutoClean(enabled: Bool, intervalHours: Int) {
        cleanTimer?.invalidate(); cleanTimer = nil
        guard AorusLicenseAccess.isAllowed, enabled else { return }
        let hours = max(1, intervalHours)
        let t = Timer.scheduledTimer(withTimeInterval: TimeInterval(hours * 3600),
                                     repeats: true) { [weak self] _ in self?.performCleanup() }
        cleanTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    // Wipe caches now. Calls are serialized on main together with registration, so a cleanup
    // cannot race an account switch while the individual cache sinks do their own async work.
    public func performCleanup() {
        if Thread.isMainThread {
            self._performCleanup()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?._performCleanup()
            }
        }
    }

    private func _performCleanup() {
        guard AorusLicenseAccess.isAllowed else { return }
        DeletedMessagesCache.shared.clearAll()
        URLCache.shared.removeAllCachedResponses()
        URLSession.shared.configuration.urlCache?.removeAllCachedResponses()
        // Last, and asynchronous inside: this one walks the media box and can take a while on
        // a large cache, whereas the three above return immediately.
        for cleanup in self.wallMediaCleanups.values {
            cleanup()
        }
    }
}
