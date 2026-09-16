import Foundation
import Combine

// Configurable auto-reply: sends a preset message automatically when a new
// message arrives while the user is in "away" state (manually toggled or
// scheduled). Deduplicates replies within a cooldown window per peer.
final class AutoReplyManager: ObservableObject {
    static let shared = AutoReplyManager()
    private init() {}

    @Published var isEnabled: Bool = false {
        didSet { persist() }
    }
    @Published var replyText: String = "Я сейчас недоступен. Отвечу позже." {
        didSet { persist() }
    }
    @Published var cooldownMinutes: Int = 60 {
        didSet { persist() }
    }
    @Published var skipGroups: Bool = true {
        didSet { persist() }
    }
    @Published var skipChannels: Bool = true {
        didSet { persist() }
    }

    // peerId → Date of last auto-reply
    private var lastReplied: [Int64: Date] = [:]
    private let queue = DispatchQueue(label: "aorusgram.autoreply")

    // MARK: - Persistence

    /// True while `load()` is assigning, so the `didSet` observers do not write back.
    ///
    /// Every property persists ALL of them on change. The first assignment in `load()` —
    /// `isEnabled` — therefore wrote the four properties that had not been read yet, at
    /// their defaults, straight over the user's stored settings. Their own reads a line
    /// later then returned those defaults, so a custom reply text, cooldown and the two
    /// skip switches were lost on the first launch that called this.
    private var isLoading = false

    func load() {
        isLoading = true
        defer { isLoading = false }
        let d = UserDefaults.standard
        isEnabled       = d.bool(forKey: "aorus_ar_enabled")
        replyText       = d.string(forKey: "aorus_ar_text") ?? replyText
        cooldownMinutes = d.integer(forKey: "aorus_ar_cooldown").nonZero ?? 60
        skipGroups      = d.object(forKey: "aorus_ar_skip_groups") as? Bool ?? true
        skipChannels    = d.object(forKey: "aorus_ar_skip_channels") as? Bool ?? true
    }

    private func persist() {
        guard !isLoading else { return }
        let d = UserDefaults.standard
        d.set(isEnabled,       forKey: "aorus_ar_enabled")
        d.set(replyText,       forKey: "aorus_ar_text")
        d.set(cooldownMinutes, forKey: "aorus_ar_cooldown")
        d.set(skipGroups,      forKey: "aorus_ar_skip_groups")
        d.set(skipChannels,    forKey: "aorus_ar_skip_channels")
    }

    // MARK: - Decision

    enum AutoReplyDecision {
        case send(String)
        case skip(String)
    }

    /// Called by the aorus_branding.py hook when a new incoming message arrives.
    /// Parameters: peerId (negative for groups/channels), isGroup, isChannel
    func decide(peerId: Int64, isGroup: Bool, isChannel: Bool) -> AutoReplyDecision {
        guard AorusGramConfig.isEnabled(.autoReply), isEnabled else {
            return .skip("feature disabled")
        }
        if skipGroups, isGroup   { return .skip("group skipped") }
        if skipChannels, isChannel { return .skip("channel skipped") }

        let cooldown = TimeInterval(cooldownMinutes * 60)
        let now = Date()

        var shouldSend = false
        queue.sync {
            if let last = lastReplied[peerId], now.timeIntervalSince(last) < cooldown {
                // still in cooldown
            } else {
                lastReplied[peerId] = now
                shouldSend = true
            }
        }
        return shouldSend ? .send(replyText) : .skip("in cooldown")
    }

    // Manual reset of a specific peer's cooldown (e.g., when user opens the chat)
    func resetCooldown(for peerId: Int64) {
        queue.async { self.lastReplied.removeValue(forKey: peerId) }
    }

    // MARK: - Called from AorusGramBootstrap when incoming message arrives

    func handleIncoming(peerId: Int64, text: String) {
        // Negative peerId = group/channel in Telegram's internal representation
        let isGroup   = peerId < -1_000_000_000
        let isChannel = peerId < -1_000_000_000_000

        let decision = decide(peerId: peerId, isGroup: isGroup, isChannel: isChannel)
        if case .send(let msg) = decision {
            // Post NotificationCenter event — branding.py-injected code in TelegramUI
            // observes this and calls account.sendMessage(...)
            NotificationCenter.default.post(
                name: NSNotification.Name("aorusgram.sendAutoReply"),
                object: nil,
                userInfo: ["peerId": NSNumber(value: peerId), "text": msg]
            )
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
