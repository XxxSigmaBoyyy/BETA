import Foundation

// MARK: - Anti-Spoof Manager

public final class AntiSpoofManager {
    public static let shared = AntiSpoofManager()
    private init() { load() }

    // MARK: - Settings

    public var antiSpoofOnline: Bool    = false { didSet { save() } }
    public var antiSpoofDeleted: Bool   = true  { didSet { save() } }
    public let decoyText = "Ты не увидишь это сообщение. Привет от AORUS! 🔥"

    private let key = "aorusgram_antispoof_v1"

    private func load() {
        defer {
            // Mirror to flat keys so TelegramCore source patches (which can't import
            // this module) can read the toggles via UserDefaults.standard.bool.
            let ud = UserDefaults.standard
            ud.set(antiSpoofOnline,  forKey: "aorusgram_antispoof_online")
            ud.set(antiSpoofDeleted, forKey: "aorusgram_antispoof_deleted")
        }
        guard let d = UserDefaults.standard.dictionary(forKey: key) else { return }
        antiSpoofOnline  = d["antiSpoofOnline"]  as? Bool ?? false
        antiSpoofDeleted = d["antiSpoofDeleted"] as? Bool ?? true
    }

    private func save() {
        UserDefaults.standard.set(
            ["antiSpoofOnline": antiSpoofOnline, "antiSpoofDeleted": antiSpoofDeleted],
            forKey: key
        )
        let ud = UserDefaults.standard
        ud.set(antiSpoofOnline,  forKey: "aorusgram_antispoof_online")
        ud.set(antiSpoofDeleted, forKey: "aorusgram_antispoof_deleted")
        NotificationCenter.default.post(
            name: NSNotification.Name("aorusgram_settings_changed"),
            object: nil
        )
    }

    // MARK: - Anti-Spoof Deleted
    // Перед удалением сообщения — заменяем текст на приманку.
    // Любой клиент (Nicegram, BGram и тд) сохранит только приманку.
    //
    // Стратегия: edit и delete отправляются одновременно без задержки.
    // Сервер обрабатывает edit раньше delete (порядок очереди), поэтому
    // клиенты получают updateEditMessage с decoy-текстом, затем сразу
    // updateDeleteMessages. Кэш других клиентов фиксирует decoy.
    // «Edited» badge видно не более ~50ms (скорость сети) — незаметно.
    public func prepareDelete(messageId: Int64, peerId: Int64, completion: @escaping () -> Void) {
        guard antiSpoofDeleted else { completion(); return }

        // Запускаем edit и delete одновременно
        NotificationCenter.default.post(
            name: .aorusEditBeforeDelete,
            object: nil,
            userInfo: [
                "messageId": messageId,
                "peerId":    peerId,
                "newText":   decoyText
            ]
        )
        // Немедленно вызываем удаление — оба запроса улетают в одном цикле RunLoop
        completion()
    }

    // MARK: - Anti-Spoof Online
    // Отслеживаем активность собеседника косвенно:
    // фиксируем время последнего события (typing, message, reaction)
    // даже если у него скрыт last seen.

    private var peerActivity: [Int64: PeerActivityRecord] = [:]
    private let activityQueue = DispatchQueue(label: "aorusgram.peer_activity")

    public func recordActivity(peerId: Int64, kind: ActivityKind) {
        guard antiSpoofOnline else { return }
        activityQueue.async { [weak self] in
            let record = PeerActivityRecord(peerId: peerId, kind: kind, date: Date())
            self?.peerActivity[peerId] = record
            UserDefaults.standard.set(
                record.date.timeIntervalSince1970,
                forKey: "aorusgram_peer_last_seen_\(peerId)"
            )
            NotificationCenter.default.post(
                name: .aorusPeerActivityUpdated,
                object: nil,
                userInfo: ["peerId": peerId, "date": record.date, "kind": kind.rawValue]
            )
        }
    }

    // Возвращает вычисленный "реальный" last seen
    public func realLastSeen(peerId: Int64) -> RealLastSeen {
        guard antiSpoofOnline else { return .unknown }

        // Проверяем свежую активность в памяти
        if let record = peerActivity[peerId] {
            let ago = Date().timeIntervalSince(record.date)
            if ago < 60  { return .online }
            if ago < 300 { return .recently(record.date, record.kind) }
        }

        // Из UserDefaults (сохраняется между сессиями)
        let ts = UserDefaults.standard.double(forKey: "aorusgram_peer_last_seen_\(peerId)")
        if ts > 0 {
            return .lastSeen(Date(timeIntervalSince1970: ts))
        }

        return .unknown
    }

    public enum RealLastSeen {
        case online
        case recently(Date, ActivityKind)
        case lastSeen(Date)
        case unknown

        public var displayString: String {
            let fmt = RelativeDateTimeFormatter()
            fmt.locale = Locale(identifier: "ru_RU")
            switch self {
            case .online:
                return "в сети - AORUS"
            case .recently(let date, let kind):
                return "был(а) \(fmt.localizedString(for: date, relativeTo: Date())) (\(kind.description)) - AORUS"
            case .lastSeen(let date):
                return "был(а) \(fmt.localizedString(for: date, relativeTo: Date())) - AORUS"
            case .unknown:
                return ""
            }
        }
    }

    public enum ActivityKind: String {
        case typing    = "typing"
        case message   = "message"
        case reaction  = "reaction"
        case voiceNote = "voice"
        case online    = "online"

        public var description: String {
            switch self {
            case .typing:    return "печатал(а)"
            case .message:   return "написал(а)"
            case .reaction:  return "поставил(а) реакцию"
            case .voiceNote: return "записал(а) голосовое"
            case .online:    return "был(а) онлайн"
            }
        }
    }

    public struct PeerActivityRecord {
        let peerId: Int64
        let kind: ActivityKind
        let date: Date
    }
}

extension Notification.Name {
    static let aorusEditBeforeDelete    = Notification.Name("aorusgram_edit_before_delete")
    static let aorusPeerActivityUpdated = Notification.Name("aorusgram_peer_activity_updated")
}
