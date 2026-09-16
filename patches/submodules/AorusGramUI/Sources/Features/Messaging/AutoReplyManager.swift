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

    /// A cooldown belongs to one (account, peer) pair, not to a peer.
    ///
    /// Telegram keeps every signed-in account live in the same process, and a peer id is only
    /// unique within an account — the same id is a different conversation on each of them.
    /// Keyed on the peer alone, one auto-reply sent from account A silenced that same
    /// conversation on accounts B and C for the whole window, and the peer never got the
    /// reply the other accounts owed them.
    private struct ReplyKey: Hashable {
        let accountPath: String
        let peerId: Int64
    }

    // (account, peer) → Date of last auto-reply
    private var lastReplied: [ReplyKey: Date] = [:]
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
    ///
    /// `accountPath` is the receiving account's `postbox.mediaBox.basePath`, which the incoming
    /// hook reads off the very `MediaBox` the state manager is replaying into. It identifies
    /// the account the message actually arrived on, which is not necessarily the one on screen.
    /// Parameters: peerId (negative for groups/channels), isGroup, isChannel
    func decide(accountPath: String, peerId: Int64, isGroup: Bool, isChannel: Bool) -> AutoReplyDecision {
        guard AorusGramConfig.isEnabled(.autoReply), isEnabled else {
            return .skip("feature disabled")
        }
        if accountPath.isEmpty { return .skip("no account origin") }
        if skipGroups, isGroup   { return .skip("group skipped") }
        if skipChannels, isChannel { return .skip("channel skipped") }

        let cooldown = TimeInterval(cooldownMinutes * 60)
        let now = Date()
        let key = ReplyKey(accountPath: accountPath, peerId: peerId)

        var shouldSend = false
        queue.sync {
            if let last = lastReplied[key], now.timeIntervalSince(last) < cooldown {
                // still in cooldown
            } else {
                lastReplied[key] = now
                shouldSend = true
            }
        }
        return shouldSend ? .send(replyText) : .skip("in cooldown")
    }

    // Manual reset of a specific peer's cooldown (e.g., when user opens the chat)
    func resetCooldown(accountPath: String, for peerId: Int64) {
        let key = ReplyKey(accountPath: accountPath, peerId: peerId)
        queue.async { self.lastReplied.removeValue(forKey: key) }
    }

    // MARK: - Called from AorusGramBootstrap when incoming message arrives

    func handleIncoming(accountPath: String, peerId: Int64, text: String) {
        // Negative peerId = group/channel in Telegram's internal representation
        let isGroup   = peerId < -1_000_000_000
        let isChannel = peerId < -1_000_000_000_000

        let decision = decide(accountPath: accountPath, peerId: peerId, isGroup: isGroup, isChannel: isChannel)
        if case .send(let msg) = decision {
            // Post NotificationCenter event — branding.py-injected code in TelegramUI
            // observes this and sends from the account named by `accountPath`. Without that
            // name the observer fell back to whichever context was on screen, so a reply to
            // one account's chat was sent — visibly, to the peer — from another account.
            NotificationCenter.default.post(
                name: NSNotification.Name("aorusgram.sendAutoReply"),
                object: nil,
                userInfo: [
                    "peerId": NSNumber(value: peerId),
                    "accountPath": accountPath,
                    "text": msg,
                ]
            )
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
