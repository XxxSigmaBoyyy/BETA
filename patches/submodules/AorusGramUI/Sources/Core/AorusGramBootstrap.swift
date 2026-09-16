import Foundation
import UIKit
import AorusGram

// Single entry point called once from AppDelegate after the account is ready.
// aorus_branding.py patches AppDelegate.swift to insert:
//   AorusGramBootstrap.shared.setup(accountPath:)
public final class AorusGramBootstrap {
    public static let shared = AorusGramBootstrap()
    private init() {}

    private var didSetup = false

    public func setup(accountPath: String? = nil) {
        guard !didSetup else { return }
        didSetup = true

        // Persist the account-data root so AccountBackupManager can locate the
        // accounts-metadata / account-* directories for backup & restore.
        if let accountPath = accountPath, !accountPath.isEmpty {
            AccountBackupManager.shared.rootPath = accountPath
        }

        // Integrity check — runs async so it never blocks app launch
        DispatchQueue.global(qos: .utility).async {
            AorusSessionMetrics.shared.collect()
        }

        // Clipboard history — start observing in-app copies so the formatting panel's
        // clipboard offers a rolling history, not just the single most-recent entry.
        AorusClipboardHistory.shared.start()

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
                AorusGram.AntiScreenshotManager.shared.enable()
            }
        }

        // Secret pin
        SecretPinManager.shared.load()

        // Cache auto-cleaning — periodic wipe of deleted-messages + URL caches
        AorusCacheManager.shared.refresh()

        // Performance HUD — transparent pass-through overlay and RAM cleanup timer
        AorusPerformanceHUDManager.shared.restorePersistedHUDAfterLaunch()

        // Auto-reply
        AutoReplyManager.shared.load()

        // Quick Replies — after a reinstall UserDefaults is wiped but the
        // Keychain copy survives; re-seed the mirror the "&" panel reads.
        AorusQuickReplies.restoreFromKeychainIfNeeded()

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
        if #available(iOS 16.0, *) {
            if AorusGramConfig.isEnabled(.siriShortcuts) {
                SiriShortcutsManager.shared.donateAllDefaults()
            }
            NotificationCenter.default.addObserver(
                forName: .aorusSettingsChanged,
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

        observeAppLifecycle()
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
        // Only gate one-on-one private chats from non-contacts (the prefilter injected
        // into AccountStateManager computes this the same way). Group/channel chatter and
        // messages from people you know are never auto-blocked or toasted as spam.
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

        // Auto-reply. The reply has to leave the account the message arrived on, so an event
        // that cannot name its account is not answered at all rather than answered from
        // whichever account happens to be on screen.
        if AorusGramConfig.isEnabled(.autoReply),
           let accountPath = info[AorusDMCNotifKey.accountPath] as? String, !accountPath.isEmpty {
            AutoReplyManager.shared.handleIncoming(accountPath: accountPath, peerId: peerId, text: text)
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
        AorusCacheManager.shared.refresh()
        AorusPerformanceHUDManager.shared.restorePersistedHUDAfterLaunch()
    }

    @objc private func appDidEnterBackground() {
        DeletedMessagesCache.shared.scheduleBackgroundSync()
    }
}
