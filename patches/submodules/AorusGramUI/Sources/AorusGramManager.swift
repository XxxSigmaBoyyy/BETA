import Foundation
import UIKit
import AorusGram

// MARK: - Central Config

public final class AorusGramManager {
    public static let shared = AorusGramManager()
    private init() {
        load()
        // License kill-switch (in-memory side effects). LicenseGate already forces every
        // flat aorusgram_* flag OFF / restores them on the lock flag; here we only handle
        // state that a raw key write can't revert: Anti-Screenshot is applied by a live
        // manager, so it must be explicitly disabled while locked and re-applied on unlock.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("aorusgram.licenseLockChanged"), object: nil, queue: .main
        ) { [weak self] note in
            let locked = (note.userInfo?["locked"] as? Bool) ?? false
            if locked {
                AorusGram.AntiScreenshotManager.shared.disable()
                self?.mirrorFlatKeys()
            } else {
                self?.save()   // flags restored by LicenseGate → re-apply real in-memory state
            }
        }
    }

    public let version = "1.0.0"
    public let channelURL = "https://t.me/aorusgram"
    public let channelUsername = "aorusgram"

    // MARK: - Feature flags

    public var ghostMode: Bool        = false { didSet { save() } }
    public var blockReadReceipts: Bool = true  { didSet { save() } }
    public var hideTyping: Bool        = true  { didSet { save() } }
    public var saveDeletedMessages: Bool = true { didSet { save() } }
    public var saveEditedMessages: Bool = true { didSet { save() } }
    public var maxMediaQuality: Bool   = true  { didSet { save() } }
    public var antiSpamEnabled: Bool   = true  { didSet { save() } }
    public var downloadAccel: Bool     = true  { didSet { save() } }
    public var glassUI: Bool           = true  { didSet { save() } }
    public var amoledMode: Bool        = false { didSet { save() } }
    public var profileReportButton: Bool = false { didSet { save() } }
    public var hideCallsTab: Bool      = false { didSet { save() } }
    public var hideContactsTab: Bool   = false { didSet { save() } }
    public var hideSearchButton: Bool  = false { didSet { save() } }
    public var hideTabTitles: Bool     = false { didSet { save() } }
    public var compactTabBar: Bool     = false { didSet { save() } }
    public var wallEnabled: Bool       = true  { didSet { save() } }
    public var voiceTranscription: Bool = false { didSet { save() } }
    public var translator: Bool        = false { didSet { save() } }
    // Native share button on posts — decoupled from the translator; on by default (stock).
    public var shareButton: Bool       = true  { didSet { save() } }
    public var videoMessagesRearCamera: Bool = true { didSet { save() } }
    public var deviceMicrophone: Bool = false { didSet { save() } }
    public var antiScreenshot: Bool    = false { didSet { save() } }
    public var callRecording: Bool     = false { didSet { save() } }
    public var streaks: Bool           = false { didSet { save() } }
    public var siriShortcuts: Bool     = false { didSet { save() } }
    public var squareAvatars: Bool     = false { didSet { save() } }
    public var autoReply: Bool         = false { didSet { save() } }

    // Local editing — context-menu action to edit any message in the local DB only.
    public var editLocally: Bool       = false { didSet { save() } }

    // "User's messages" — context-menu action (groups only) to open a chat-like
    // screen with all of one user's messages in that group.
    public var userMessagesInGroup: Bool = false { didSet { save() } }
    public var messageSeconds: Bool       = false { didSet { save() } }

    // Message tap gestures (opt-in, off by default).
    public var doubleTapCopy: Bool     = false { didSet { save() } }
    public var tripleTapDelete: Bool   = false { didSet { save() } }

    // Cache auto-cleaning (Performance section). On the chosen interval (in
    // hours) it wipes the deleted-messages cache and URL/media caches.
    public var cacheAutoClean: Bool    = false { didSet { save() } }
    public var cacheCleanInterval: Int = 24    { didSet { save() } }   // hours

    // Performance HUD (Performance section). The main switch is opt-in, while
    // individual metrics default on so the first enable shows a useful dashboard.
    public var performanceStatsEnabled: Bool = false { didSet { save() } }
    public var performanceShowUptime: Bool   = true  { didSet { save() } }
    public var performanceShowRAM: Bool      = true  { didSet { save() } }
    public var performanceShowCPU: Bool      = true  { didSet { save() } }
    public var performanceShowFPS: Bool      = true  { didSet { save() } }
    public var performanceShowBattery: Bool  = true  { didSet { save() } }
    public var performanceShowNetwork: Bool  = true  { didSet { save() } }
    public var performanceShowDisk: Bool     = true  { didSet { save() } }
    public var performanceShowThermal: Bool  = true  { didSet { save() } }
    public var performanceShowGraph: Bool    = true  { didSet { save() } }
    public var ramAutoClean: Bool            = false { didSet { save() } }
    public var ramCleanInterval: Int         = 60    { didSet { save() } }   // seconds

    // Voice Twin — pitch/character transform applied to OUTGOING voice messages.
    // preset ∈ {"anonymous","male","female","robot","child"}; "high" is accepted as legacy child.
    public var voiceTwinEnabled: Bool  = false        { didSet { save() } }
    public var voiceTwinPreset: String = "anonymous"  { didSet { save() } }

    // Video masks — rendered locally into outgoing call and round-video frames.
    // These two live ONLY in UserDefaults, unlike every other setting here.
    //
    // The mask strip inside a call writes them from a leaf module that cannot reach this
    // class. A second copy in the manager's dictionary would go stale the moment the user
    // picked a mask mid-call, and the next unrelated setting change would call save() and
    // write that stale copy straight back over their choice.
    public var videoMasksEnabled: Bool {
        get { !licenseLocked && UserDefaults.standard.bool(forKey: "aorusgram_video_masks_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "aorusgram_video_masks_enabled") }
    }
    public var videoMaskPreset: String {
        get { UserDefaults.standard.string(forKey: "aorusgram_video_mask_preset") ?? "skull" }
        set { UserDefaults.standard.set(newValue, forKey: "aorusgram_video_mask_preset") }
    }

    private let key = "aorusgram_settings_v1"
    private var licenseLocked: Bool {
        return !AorusLicenseAccess.isAllowed
    }

    private func effective(_ value: Bool) -> Bool {
        licenseLocked ? false : value
    }

    private func mirrorFlatKeys() {
        let ud = UserDefaults.standard
        ud.set(effective(ghostMode),           forKey: "aorusgram_ghost_mode")
        ud.set(effective(saveDeletedMessages), forKey: "aorusgram_feature_deleted_messages")
        ud.set(effective(saveEditedMessages),  forKey: "aorusgram_feature_edited_messages")
        ud.set(effective(antiScreenshot),      forKey: "aorusgram_feature_anti_screenshot")
        ud.set(effective(callRecording),       forKey: "aorusgram_feature_call_recording")
        ud.set(effective(voiceTranscription),  forKey: "aorusgram_feature_voice_transcription")
        ud.set(effective(translator),          forKey: "aorusgram_feature_translator")
        ud.set(effective(shareButton),         forKey: "aorusgram_share_button")
        ud.set(effective(videoMessagesRearCamera), forKey: "aorusgram_video_messages_rear_camera")
        ud.set(effective(deviceMicrophone),  forKey: "aorusgram_device_microphone")
        ud.set(effective(autoReply),           forKey: "aorusgram_feature_auto_reply")
        ud.set(effective(maxMediaQuality),     forKey: "aorusgram_feature_max_media_quality")
        ud.set(effective(antiSpamEnabled),     forKey: "aorusgram_feature_anti_spam")
        ud.set(effective(downloadAccel),       forKey: "aorusgram_feature_download_accel")
        ud.set(effective(glassUI),             forKey: "aorusgram_feature_glass_ui")
        ud.set(effective(amoledMode),          forKey: "aorusgram_amoled")
        ud.set(effective(profileReportButton), forKey: "aorusgram_profile_report_button")
        ud.set(effective(hideCallsTab),        forKey: "aorusgram_hide_calls_tab")
        ud.set(effective(hideContactsTab),     forKey: "aorusgram_hide_contacts_tab")
        ud.set(effective(hideSearchButton),    forKey: "aorusgram_hide_search_button")
        ud.set(effective(hideTabTitles),       forKey: "aorusgram_hide_tab_titles")
        ud.set(effective(compactTabBar),        forKey: "aorusgram_compact_tab_bar")
        ud.set(effective(wallEnabled),         forKey: "aorusgram_wall_enabled")
        ud.set(effective(streaks),             forKey: "aorusgram_feature_streaks")
        ud.set(effective(siriShortcuts),       forKey: "aorusgram_feature_siri_shortcuts")
        ud.set(effective(squareAvatars),       forKey: "aorusgram_square_avatars")
        ud.set(effective(editLocally),         forKey: "aorusgram_feature_edit_locally")
        ud.set(effective(userMessagesInGroup), forKey: "aorusgram_feature_user_messages")
        ud.set(effective(messageSeconds),      forKey: "aorusgram_feature_message_seconds")
        ud.set(effective(doubleTapCopy),       forKey: "aorusgram_feature_double_copy")
        ud.set(effective(tripleTapDelete),     forKey: "aorusgram_feature_triple_delete")
        ud.set(effective(voiceTwinEnabled),    forKey: "aorusgram_voice_twin_enabled")
        ud.set(voiceTwinPreset,                forKey: "aorusgram_voice_twin_preset")
    }

    private func load() {
        // Always mirror current values to the flat keys read by source patches —
        // this also catches fresh installs where the dictionary doesn't exist yet
        // (defaults apply, then save() is called once).
        defer { mirrorFlatKeys() }
        guard let d = UserDefaults.standard.dictionary(forKey: key) else { return }
        ghostMode           = d["ghostMode"]           as? Bool ?? false
        blockReadReceipts   = d["blockReadReceipts"]   as? Bool ?? true
        hideTyping          = d["hideTyping"]          as? Bool ?? true
        saveDeletedMessages = d["saveDeletedMessages"] as? Bool ?? true
        saveEditedMessages  = d["saveEditedMessages"]  as? Bool ?? true
        maxMediaQuality     = d["maxMediaQuality"]     as? Bool ?? true
        antiSpamEnabled     = d["antiSpamEnabled"]     as? Bool ?? true
        downloadAccel       = d["downloadAccel"]       as? Bool ?? true
        glassUI             = d["glassUI"]             as? Bool ?? true
        amoledMode          = d["amoledMode"]          as? Bool ?? false
        profileReportButton = d["profileReportButton"] as? Bool ?? false
        hideCallsTab        = d["hideCallsTab"]        as? Bool ?? false
        hideContactsTab     = d["hideContactsTab"]     as? Bool ?? false
        hideSearchButton    = d["hideSearchButton"]    as? Bool ?? false
        hideTabTitles       = d["hideTabTitles"]       as? Bool ?? false
        compactTabBar       = d["compactTabBar"]       as? Bool ?? false
        wallEnabled         = d["wallEnabled"]         as? Bool ?? true
        voiceTranscription  = d["voiceTranscription"]  as? Bool ?? false
        translator          = d["translator"]          as? Bool ?? false
        shareButton         = d["shareButton"]         as? Bool ?? true
        videoMessagesRearCamera = d["videoMessagesRearCamera"] as? Bool ?? true
        deviceMicrophone    = d["deviceMicrophone"]    as? Bool ?? false
        antiScreenshot      = d["antiScreenshot"]      as? Bool ?? false
        callRecording       = d["callRecording"]       as? Bool ?? false
        streaks             = d["streaks"]             as? Bool ?? false
        siriShortcuts       = d["siriShortcuts"]       as? Bool ?? false
        squareAvatars       = d["squareAvatars"]       as? Bool ?? false
        autoReply           = d["autoReply"]           as? Bool ?? false
        editLocally         = d["editLocally"]         as? Bool ?? false
        userMessagesInGroup = d["userMessagesInGroup"] as? Bool ?? false
        messageSeconds      = d["messageSeconds"]      as? Bool ?? false
        doubleTapCopy       = d["doubleTapCopy"]       as? Bool ?? false
        tripleTapDelete     = d["tripleTapDelete"]     as? Bool ?? false
        cacheAutoClean      = d["cacheAutoClean"]      as? Bool ?? false
        cacheCleanInterval  = d["cacheCleanInterval"]  as? Int  ?? 24
        performanceStatsEnabled = d["performanceStatsEnabled"] as? Bool ?? false
        performanceShowUptime   = d["performanceShowUptime"]   as? Bool ?? true
        performanceShowRAM      = d["performanceShowRAM"]      as? Bool ?? true
        performanceShowCPU      = d["performanceShowCPU"]      as? Bool ?? true
        performanceShowFPS      = d["performanceShowFPS"]      as? Bool ?? true
        performanceShowBattery  = d["performanceShowBattery"]  as? Bool ?? true
        performanceShowNetwork  = d["performanceShowNetwork"]  as? Bool ?? true
        performanceShowDisk     = d["performanceShowDisk"]     as? Bool ?? true
        performanceShowThermal  = d["performanceShowThermal"]  as? Bool ?? true
        performanceShowGraph    = d["performanceShowGraph"]    as? Bool ?? true
        ramAutoClean            = d["ramAutoClean"]            as? Bool ?? false
        ramCleanInterval        = d["ramCleanInterval"]        as? Int  ?? 60
        voiceTwinEnabled    = d["voiceTwinEnabled"]    as? Bool   ?? false
        voiceTwinPreset     = d["voiceTwinPreset"]     as? String ?? "anonymous"
        // Preset names that shipped in older builds, migrated in place. The value now lives
        // in UserDefaults, so this rewrites it there rather than in the dictionary.
        switch videoMaskPreset {
        case "demon": videoMaskPreset = "oni"
        case "incognito": videoMaskPreset = "cyber"
        case "halo": videoMaskPreset = "aurora"
        default: break
        }
    }

    private func save() {
        UserDefaults.standard.set([
            "ghostMode":           ghostMode,
            "blockReadReceipts":   blockReadReceipts,
            "hideTyping":          hideTyping,
            "saveDeletedMessages": saveDeletedMessages,
            "saveEditedMessages":  saveEditedMessages,
            "maxMediaQuality":     maxMediaQuality,
            "antiSpamEnabled":     antiSpamEnabled,
            "downloadAccel":       downloadAccel,
            "glassUI":             glassUI,
            "amoledMode":          amoledMode,
            "profileReportButton": profileReportButton,
            "hideCallsTab":        hideCallsTab,
            "hideContactsTab":     hideContactsTab,
            "hideSearchButton":    hideSearchButton,
            "hideTabTitles":       hideTabTitles,
            "compactTabBar":       compactTabBar,
            "wallEnabled":         wallEnabled,
            "voiceTranscription":  voiceTranscription,
            "translator":          translator,
            "shareButton":         shareButton,
            "videoMessagesRearCamera": videoMessagesRearCamera,
            "deviceMicrophone":    deviceMicrophone,
            "antiScreenshot":      antiScreenshot,
            "callRecording":       callRecording,
            "streaks":             streaks,
            "siriShortcuts":       siriShortcuts,
            "squareAvatars":       squareAvatars,
            "autoReply":           autoReply,
            "editLocally":         editLocally,
            "userMessagesInGroup": userMessagesInGroup,
            "messageSeconds":      messageSeconds,
            "doubleTapCopy":       doubleTapCopy,
            "tripleTapDelete":     tripleTapDelete,
            "cacheAutoClean":      cacheAutoClean,
            "cacheCleanInterval":  cacheCleanInterval,
            "performanceStatsEnabled": performanceStatsEnabled,
            "performanceShowUptime":   performanceShowUptime,
            "performanceShowRAM":      performanceShowRAM,
            "performanceShowCPU":      performanceShowCPU,
            "performanceShowFPS":      performanceShowFPS,
            "performanceShowBattery":  performanceShowBattery,
            "performanceShowNetwork":  performanceShowNetwork,
            "performanceShowDisk":     performanceShowDisk,
            "performanceShowThermal":  performanceShowThermal,
            "performanceShowGraph":    performanceShowGraph,
            "ramAutoClean":            ramAutoClean,
            "ramCleanInterval":        ramCleanInterval,
            "voiceTwinEnabled":    voiceTwinEnabled,
            "voiceTwinPreset":     voiceTwinPreset,
        ], forKey: key)

        mirrorFlatKeys()

        // Never turn Anti-Screenshot on while the subscription is locked.
        if antiScreenshot && !licenseLocked {
            AorusGram.AntiScreenshotManager.shared.enable()
        } else {
            AorusGram.AntiScreenshotManager.shared.disable()
        }

        NotificationCenter.default.post(name: .aorusSettingsChanged, object: nil)
    }

    // MARK: - Ghost Mode

    public func shouldSendOnlinePresence() -> Bool  { licenseLocked ? true : !ghostMode }
    public func shouldSendReadReceipt() -> Bool     { licenseLocked ? true : (!ghostMode || !blockReadReceipts) }
    public func shouldSendTypingIndicator() -> Bool { licenseLocked ? true : (!ghostMode || !hideTyping) }

    // MARK: - Bootstrap (call from AppDelegate/AppLock)

    public func bootstrap() {
        if effective(siriShortcuts)  { donateSiriShortcuts() }
    }

    private func donateSiriShortcuts() {
        let activity = NSUserActivity(activityType: "com.aorusgram.ToggleGhostMode")
        activity.title = "Включить режим призрака"
        activity.isEligibleForPrediction = true
        // suggestedInvocationPhrase requires Intents framework — skip to avoid dep
        activity.becomeCurrent()
    }
}

public extension Notification.Name {
    static let aorusSettingsChanged = Notification.Name("aorusgram_settings_changed")
}
