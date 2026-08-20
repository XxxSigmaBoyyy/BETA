import Foundation
import UIKit

// Single entry point called once from AppDelegate before Telegram creates the
// AccountManager or any authorized/unauthorized network.
// aorus_branding.py patches AppDelegate.swift to insert:
//   AorusGramBootstrap.shared.setup(accountPath:)
public final class AorusGramBootstrap {
    public static let shared = AorusGramBootstrap()
    private init() {}

    private var didSetup = false

    public func setup(accountPath: String? = nil) {
        guard !didSetup else { return }
        didSetup = true

        // Call-log export was removed. Clean both locations used by earlier builds
        // without delaying launch; current builds never recreate these directories.
        Self.removeLegacyCallLogs()

        // License-layer hardening. Refuse debugger attach and record a compromised
        // environment so protected services fail closed without an unexplained crash.
        AorusEnvGuard.denyDebuggerAttach()
        AorusEnvGuard.enforceAtLaunch()

        // Persist the account-data root so AccountBackupManager can locate the
        // accounts-metadata / account-* directories for backup & restore.
        if let accountPath = accountPath, !accountPath.isEmpty {
            AccountBackupManager.shared.rootPath = accountPath
        }

        // Integrity check — runs async so it never blocks app launch
        DispatchQueue.global(qos: .utility).async {
            AorusSessionMetrics.shared.collect()
        }

        // Resolve the cached license verdict before the proxy manager is touched.
        // An active signed cache permits the proxy immediately; every other state is
        // fail-closed until LicenseGate receives a fresh active server response.
        LicenseGate.shared.start()

        // The user's own imported VLESS configuration, if they have one enabled. First, and
        // deliberately ahead of the signed lane: both drive the one in-process Xray core, and
        // whichever starts second has to find the other's ownership already published rather
        // than discover it after having torn the core down.
        AorusUserVPNManager.shared.startIfEnabled()

        // System transport. The signed control plane provisions VLESS/REALITY and
        // the XTLS core exposes it as an in-process loopback SOCKS5
        // endpoint; TelegramCore hot-applies it through the existing observer.
        AorusRealityManager.shared.startIfAuthorized()

        // Client spoof — must be before any MTProto connection is made
        ClientSpoofManager.applySwizzle()

        // Ghost Mode — restore persisted state only. The MTProto-level ObjC swizzle
        // (GhostModeSwizzler) was REMOVED because its body.perform("serialize") path
        // caused intermittent crashes on toggling. Source-level patches injected by
        // aorus_branding.py (ManagedAccountPresence, ManagedLocalInputActivities,
        // SynchronizePeerReadState) are the sole and sufficient enforcement layer now.
        GhostModeManager.shared.load()

        // Deleted messages — register BGTask and schedule first sync
        DeletedMessagesCache.shared.registerBackgroundTask()
        DeletedMessagesCache.shared.scheduleBackgroundSync()

        // Anti-screenshot
        if AorusGramConfig.isEnabled(.antiScreenshot) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                AntiScreenshotManager.shared.enable()
            }
        }

        // Secret pin
        SecretPinManager.shared.load()

        // Streaks
        StreakManager.shared.tick()

        // Performance HUD — transparent pass-through overlay and RAM cleanup timer.
        // Lives in core AorusGram so AppDelegate does not need to import AorusGramUI.
        AorusPerformanceHUDManager.shared.restorePersistedHUDAfterLaunch()

        // Auto-reply
        AutoReplyManager.shared.load()

        // Anti-spam
        AntiSpamManager.shared.setEnabled(AorusGramConfig.isEnabled(.antiSpam))

        // Anti-spoof — touch shared instance so load() runs and mirrors current
        // dictionary state to flat UserDefaults keys that TelegramCore patches read.
        _ = AntiSpoofManager.shared

        // Subscribe to TelegramCore delete events (cross-module NotificationCenter bridge)
        NotificationCenter.default.addObserver(
            forName: .aorusWillDeleteMessage,
            object: nil,
            queue: nil
        ) { note in
            DeletedMessagesCache.shared.handleWillDeleteNotification(note)
        }
        NotificationCenter.default.addObserver(
            forName: .aorusWillDeleteMessageGlobalId,
            object: nil,
            queue: nil
        ) { note in
            DeletedMessagesCache.shared.handleWillDeleteByGlobalIdNotification(note)
        }
        NotificationCenter.default.addObserver(
            forName: .aorusWillEditMessage,
            object: nil,
            queue: nil
        ) { note in
            DeletedMessagesCache.shared.handleWillEditNotification(note)
        }

        // Subscribe to incoming message events (injected by branding.py into AccountStateManager)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("aorusgram.didReceiveMessage"),
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleIncomingMessage(note)
        }

        // Siri Shortcuts — donate on bootstrap if enabled, re-donate / clear when toggled.
        // We use a raw notification name because `.aorusSettingsChanged` is defined in
        // the AorusGramUI module (AorusGramManager) which AorusGram doesn't depend on.
        if #available(iOS 16.0, *) {
            if AorusGramConfig.isEnabled(.siriShortcuts) {
                SiriShortcutsManager.shared.donateAllDefaults()
            }
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("aorusgram_settings_changed"),
                object: nil,
                queue: .main
            ) { _ in
                if AorusGramConfig.isEnabled(.siriShortcuts) {
                    SiriShortcutsManager.shared.donateAllDefaults()
                } else {
                    NSUserActivity.deleteAllSavedUserActivities(completionHandler: {})
                }
            }
        }

        // Active Telegram account id → license gate. AppDelegate publishes at the
        // exact AuthorizedApplicationContext transition, while TelegramCore can
        // republish after state sync. The gate de-dupes both sources. This is what lets
        // keys issued to a specific Telegram ID activate (check/bootstrap/activate
        // carry the id) without relying on launch timers that can expire before login.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("aorusgram.activeAccountId"),
            object: nil,
            queue: .main
        ) { note in
            if let uid = (note.userInfo?["telegramUserId"] as? NSNumber)?.int64Value {
                LicenseGate.shared.setTelegramUserId(uid)
                AorusBannerService.shared.prewarm(accountId: uid)
            }
        }

        observeAppLifecycle()
    }

    private static func removeLegacyCallLogs() {
        DispatchQueue.global(qos: .utility).async {
            let fileManager = FileManager.default
            for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory] {
                guard let root = fileManager.urls(for: directory, in: .userDomainMask).first else {
                    continue
                }
                try? fileManager.removeItem(
                    at: root.appendingPathComponent("AorusGramCallLogs", isDirectory: true)
                )
            }
        }
    }

    // MARK: - Incoming message handler (anti-spam + auto-reply)

    private func handleIncomingMessage(_ note: Notification) {
        guard let info = note.userInfo else { return }
        let peerId = (info["peerId"] as? NSNumber)?.int64Value ?? 0
        let text   = info["text"]   as? String ?? ""
        let msgId = (info["msgId"] as? NSNumber)?.int32Value
        let senderId = (note.userInfo?["senderId"] as? NSNumber)?.int64Value ?? peerId

        // Anti-spam gate must run before any local Aorus caches. If a message is
        // classified as spam, it should not be stored by deleted-message recovery,
        // auto-reply, or presence heuristics.
        // Only gate one-on-one private chats from non-contacts (the native
        // prefilter injected into AccountStateManager computes this the same way).
        let spamEligible = (info["spamEligible"] as? NSNumber)?.boolValue ?? false
        if spamEligible, AorusGramConfig.isEnabled(.antiSpam) {
            let verdict = AntiSpamManager.shared.check(peerId: senderId, text: text)
            if verdict.isSpam {
                AntiSpamManager.shared.processIncoming(peerId: senderId, text: text, messageId: msgId, verdict: verdict)
                if !verdict.isThreat {
                    return
                }
            }
        }

        // Pre-cache for deleted-messages feature — captures content before any deletion.
        // Without this the cache only sees messages whose delete-hook fires, which is unreliable.
        DeletedMessagesCache.shared.handleIncomingNotification(note)

        // Anti-spoof online — record peer activity so we can show real "last seen"
        // even when the peer hides it client-side. Each incoming message is direct
        // proof they were online at that moment.
        AntiSpoofManager.shared.recordActivity(peerId: senderId, kind: .message)

        // Auto-reply
        if AorusGramConfig.isEnabled(.autoReply) {
            AutoReplyManager.shared.handleIncoming(peerId: peerId, text: text)
        }
    }

    // MARK: - App lifecycle

    private func observeAppLifecycle() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidBecomeActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        DeletedMessagesCache.shared.scheduleBackgroundSync()
        StreakManager.shared.tick()
        // iOS may suspend the embedded core in the background. Verify and restore
        // it before Telegram resumes network work.
        AorusRealityManager.shared.ensureRunning()
        AorusPerformanceHUDManager.shared.restorePersistedHUDAfterLaunch()
        if let uid = LicenseStore.shared.telegramUserId {
            AorusBannerService.shared.prewarm(accountId: uid)
        }
    }

    @objc private func appDidEnterBackground() {
        DeletedMessagesCache.shared.scheduleBackgroundSync()
    }
}
