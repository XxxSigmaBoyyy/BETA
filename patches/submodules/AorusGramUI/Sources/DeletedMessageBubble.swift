import Foundation
import UIKit

// Вставляется в ChatMessageItemView Telegram — показывает удалённое
// сообщение как прозрачный пузырь с иконкой корзины прямо в чате.

public final class DeletedMessageBubbleView: UIView {

    private let bubbleView   = UIView()
    private let trashIcon    = UIImageView()
    private let textLabel    = UILabel()
    private let timeLabel    = UILabel()
    private let nameLabel    = UILabel()

    public var message: DeletedChatMessage? {
        didSet { configure() }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        // Пузырь — полупрозрачный, как будто "призрак"
        bubbleView.backgroundColor  = UIColor.systemGray.withAlphaComponent(0.15)
        bubbleView.layer.cornerRadius = 16
        bubbleView.layer.borderWidth  = 1
        bubbleView.layer.borderColor  = UIColor.systemGray.withAlphaComponent(0.3).cgColor
        bubbleView.layer.masksToBounds = true

        // Размытие внутри пузыря
        let blur = UIBlurEffect(style: .systemUltraThinMaterial)
        let blurView = UIVisualEffectView(effect: blur)
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bubbleView.insertSubview(blurView, at: 0)

        // Иконка корзины
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        trashIcon.image = UIImage(systemName: "trash", withConfiguration: config)
        trashIcon.tintColor  = UIColor.systemGray
        trashIcon.contentMode = .scaleAspectFit

        // Текст
        textLabel.font          = .systemFont(ofSize: 14)
        textLabel.textColor     = UIColor.label.withAlphaComponent(0.5)
        textLabel.numberOfLines = 0

        // Имя
        nameLabel.font      = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = UIColor.systemGray

        // Время удаления
        timeLabel.font      = .systemFont(ofSize: 10)
        timeLabel.textColor = UIColor.systemGray2

        [nameLabel, trashIcon, textLabel, timeLabel].forEach {
            bubbleView.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        addSubview(bubbleView)
        bubbleView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            bubbleView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bubbleView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -60),

            nameLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -10),

            trashIcon.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            trashIcon.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 10),
            trashIcon.widthAnchor.constraint(equalToConstant: 16),
            trashIcon.heightAnchor.constraint(equalToConstant: 16),

            textLabel.centerYAnchor.constraint(equalTo: trashIcon.centerYAnchor),
            textLabel.leadingAnchor.constraint(equalTo: trashIcon.trailingAnchor, constant: 6),
            textLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -10),

            timeLabel.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 4),
            timeLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 10),
            timeLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
        ])

        // Анимация появления
        self.alpha = 0
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
            self.alpha = 1
        }
    }

    private func configure() {
        guard let msg = message else { return }

        nameLabel.text = msg.senderName.isEmpty ? nil : msg.senderName
        nameLabel.isHidden = msg.senderName.isEmpty

        if msg.text.isEmpty {
            textLabel.text = aorusL("Медиафайл", "Media")
            textLabel.font = .italicSystemFont(ofSize: 14)
        } else {
            textLabel.text = msg.text
            textLabel.font = .systemFont(ofSize: 14)
        }

        let aorusL10n = AorusL10n.current
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: aorusL10n.lang == .ru ? "ru_RU" : "en_US")
        timeLabel.text = aorusL10n.deletedPrefix + formatter.localizedString(for: msg.deletedAt, relativeTo: Date())

        // Если своё исходящее — выравниваем вправо
        if msg.isOutgoing {
            bubbleView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
            bubbleView.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.2).cgColor
        }
    }
}

// MARK: - Model

public struct DeletedChatMessage {
    public let id: Int32
    public let peerId: Int64
    public let senderName: String
    public let text: String
    public let sentAt: Date
    public let deletedAt: Date
    public let isOutgoing: Bool
    public let mediaPath: String?
}

// MARK: - Injector (вызывается из ChatMessageItem при рендере)

public final class DeletedMessagesInjector {
    public static let shared = DeletedMessagesInjector()
    private init() {}

    // Возвращает список удалённых сообщений для вставки в чат
    // Вызывается из ChatHistoryListNode при построении списка сообщений
    //
    /// `accountStoragePath` is `account.postbox.mediaBox.basePath` — the account whose
    /// history is being drawn. The cache stores one account's rows apart from another's,
    /// and a reader that does not say which account it is would be asking for all of them.
    public func deletedMessages(accountStoragePath: String, for peerId: Int64) -> [DeletedChatMessage] {
        let accountKey = DeletedMessagesCache.accountKey(forStoragePath: accountStoragePath)
        return DeletedMessagesCache.shared.deletedMessages(accountKey: accountKey, peerId: peerId)
            .map { dm in
                DeletedChatMessage(
                    id:          dm.id,
                    peerId:      dm.peerId,
                    senderName:  dm.senderName,
                    text:        dm.text,
                    sentAt:      dm.sentDate,
                    deletedAt:   dm.deletedDate,
                    isOutgoing:  dm.isOutgoing,
                    mediaPath:   dm.mediaPath.isEmpty ? nil : dm.mediaPath
                )
            }
    }

    // Проверяет — нужно ли показать удалённое сообщение вместо обычного
    // index — позиция в списке, deletedAt — время удаления соседнего сообщения
    public func shouldShowDeletedBubble(accountStoragePath: String, afterMessageDate date: Date, peerId: Int64) -> DeletedChatMessage? {
        let deleted = deletedMessages(accountStoragePath: accountStoragePath, for: peerId)
        return deleted.first { abs($0.sentAt.timeIntervalSince(date)) < 300 }
    }
}
