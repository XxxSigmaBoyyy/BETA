import Foundation
import UIKit
import QuickLook
import Display
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import SwiftSignalKit
import AorusGram
import UndoUI
import AvatarNode
import LocalizedPeerData

// AorusAI owns a large, self-contained vocabulary. Route it through the shared AorusGram
// language resolver so Russian stays first-class and every other Telegram language follows
// the project's established English fallback until a reviewed translation is available.
public func aorusAILocalized(_ ru: String, _ en: String) -> String {
    return aorusL(ru, en)
}

private func aorusAIPresentActionSheet(_ controller: UIAlertController, from presenter: UIViewController) {
    if let popover = controller.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 1, width: 1, height: 1)
        popover.permittedArrowDirections = []
    }
    presenter.present(controller, animated: true)
}

public func aorusAIConversationListController(context: AccountContext) -> ViewController {
    return AorusAIConversationListController(context: context)
}

/// One row of the AorusAI message menu.
///
/// The host renders these rows with Telegram's own context menu, so a descriptor
/// deliberately carries no UI: a stable identifier, a localized title and the name
/// of an SF Symbol the host tints with the current theme. That keeps ContextUI out
/// of this module and the menu contents out of the generated host patch.
public struct AorusAIMenuEntry {
    public var id: String
    public var title: String
    public var iconName: String?

    public init(id: String, title: String, iconName: String? = nil) {
        self.id = id
        self.title = title
        self.iconName = iconName
    }
}

/// A group of rows of the AorusAI message menu.
///
/// A section with a `title` is rendered as its own submenu, so the top level stays a
/// handful of rows instead of the twenty-two it would be if every action were flat.
/// A section without one is rendered inline, separated from its neighbours.
public struct AorusAIMenuSection {
    public var title: String?
    public var iconName: String?
    public var entries: [AorusAIMenuEntry]

    public init(title: String? = nil, iconName: String? = nil, entries: [AorusAIMenuEntry]) {
        self.title = title
        self.iconName = iconName
        self.entries = entries
    }
}

public func aorusAIMessageMenuTitle() -> String {
    return aorusAILocalized("ИИ-компаньон", "AI Companion")
}

public func aorusAIMessageMenuSections() -> [AorusAIMenuSection] {
    return AorusAIMessageMenu.sections()
}

/// Runs the menu row `id` against the message the context menu was opened on.
///
/// The author's display name is resolved here, inside the module that owns the
/// AorusAI presentation layer, so the host patch never has to reach for a debug
/// description of a peer.
public func aorusAIRunMessageMenuAction(
    id: String,
    context: AccountContext,
    navigationController: NavigationController?,
    peerId: Int64,
    messageNamespace: Int32,
    messageId: Int32,
    authorPeerId: Int64?,
    text: String
) {
    guard let navigationController else { return }
    let start: (String?) -> Void = { authorName in
        let reference = AorusAIReferencedMessage(
            peerId: peerId,
            messageNamespace: messageNamespace,
            messageId: messageId,
            authorPeerId: authorPeerId,
            authorName: authorName,
            text: text
        )
        AorusAIMessageMenu.run(id: id, context: context, navigationController: navigationController, reference: reference)
    }
    guard let authorPeerId else {
        start(nil)
        return
    }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    var started = false
    let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: PeerId(authorPeerId)))
    |> deliverOnMainQueue).start(next: { peer in
        guard !started else { return }
        started = true
        start(peer?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder))
    })
}

private enum AorusAIMessageMenu {
    static let analyzeChatId = "chat.analyze"
    static let newChatId = "chat.new"

    private struct Item {
        var id: String
        var title: String
        var icon: String
        var prompt: String
    }

    /// A titled group becomes a submenu; an untitled one stays on the top level.
    private struct Group {
        var title: String?
        var icon: String?
        var items: [Item]
    }

    private static var groups: [Group] {
        return [
            Group(title: aorusAILocalized("Текст", "Text"), icon: "textformat", items: [
                Item(id: "text.improve", title: aorusAILocalized("Улучшить текст", "Improve writing"), icon: "wand.and.stars", prompt: aorusAILocalized("Улучши текст, сохранив смысл", "Improve the writing while preserving its meaning")),
                Item(id: "text.fix", title: aorusAILocalized("Исправить ошибки", "Fix mistakes"), icon: "checkmark.circle", prompt: aorusAILocalized("Исправь ошибки в этом сообщении", "Fix mistakes in this message")),
                Item(id: "text.shorten", title: aorusAILocalized("Сделать короче", "Make shorter"), icon: "arrow.down.right.and.arrow.up.left", prompt: aorusAILocalized("Сделай это сообщение короче", "Make this message shorter")),
                Item(id: "text.summarize", title: aorusAILocalized("Кратко пересказать", "Summarize"), icon: "text.alignleft", prompt: aorusAILocalized("Кратко перескажи это сообщение", "Summarize this message")),
                Item(id: "text.translate", title: aorusAILocalized("Перевести", "Translate"), icon: "globe", prompt: aorusAILocalized("Переведи это сообщение на мой язык", "Translate this message into my language")),
                Item(id: "text.reply", title: aorusAILocalized("Ответить на сообщение", "Draft a reply"), icon: "arrowshape.turn.up.left", prompt: aorusAILocalized("Подготовь уместный ответ на это сообщение", "Draft an appropriate reply to this message"))
            ]),
            Group(title: aorusAILocalized("Тон", "Tone"), icon: "slider.horizontal.3", items: [
                Item(id: "tone.detailed", title: aorusAILocalized("Сделать подробнее", "Make more detailed"), icon: "plus.magnifyingglass", prompt: aorusAILocalized("Сделай это сообщение подробнее, не меняя смысл", "Make this message more detailed without changing its meaning")),
                Item(id: "tone.rewrite", title: aorusAILocalized("Переформулировать", "Rewrite"), icon: "arrow.triangle.2.circlepath", prompt: aorusAILocalized("Переформулируй это сообщение", "Rewrite this message")),
                Item(id: "tone.polite", title: aorusAILocalized("Сделать вежливее", "Make more polite"), icon: "heart", prompt: aorusAILocalized("Сделай это сообщение вежливее", "Make this message more polite")),
                Item(id: "tone.confident", title: aorusAILocalized("Сделать увереннее", "Make more confident"), icon: "bolt", prompt: aorusAILocalized("Сделай тон этого сообщения увереннее", "Make this message sound more confident")),
                Item(id: "tone.formal", title: aorusAILocalized("Сделать официальнее", "Make more formal"), icon: "briefcase", prompt: aorusAILocalized("Сделай это сообщение более официальным", "Make this message more formal")),
                Item(id: "tone.simple", title: aorusAILocalized("Сделать проще", "Simplify"), icon: "textformat.size", prompt: aorusAILocalized("Перепиши это сообщение проще и понятнее", "Rewrite this message in simpler, clearer language"))
            ]),
            Group(title: aorusAILocalized("Разобрать", "Break down"), icon: "magnifyingglass", items: [
                Item(id: "review.explain", title: aorusAILocalized("Объяснить", "Explain"), icon: "questionmark.circle", prompt: aorusAILocalized("Объясни это сообщение", "Explain this message")),
                Item(id: "review.key", title: aorusAILocalized("Выделить главное", "Key points"), icon: "star", prompt: aorusAILocalized("Выдели главное в этом сообщении", "Extract the key points from this message")),
                Item(id: "review.variants", title: aorusAILocalized("Несколько ответов", "Several replies"), icon: "square.on.square", prompt: aorusAILocalized("Предложи несколько вариантов ответа на это сообщение", "Suggest several replies to this message"))
            ]),
            Group(title: aorusAILocalized("Создать", "Create"), icon: "sparkles", items: [
                Item(id: "create.telegram", title: aorusAILocalized("Telegram-пост", "Telegram post"), icon: "paperplane", prompt: aorusAILocalized("Сделай из этого профессиональный Telegram-пост", "Turn this into a professional Telegram post")),
                Item(id: "create.instagram", title: aorusAILocalized("Instagram-пост", "Instagram post"), icon: "camera", prompt: aorusAILocalized("Сделай из этого профессиональный Instagram-пост", "Turn this into a professional Instagram post")),
                Item(id: "create.title", title: aorusAILocalized("Заголовок", "Title"), icon: "text.quote", prompt: aorusAILocalized("Придумай сильный заголовок для этого текста", "Create a strong title for this text")),
                Item(id: "create.description", title: aorusAILocalized("Описание", "Description"), icon: "doc.text", prompt: aorusAILocalized("Создай краткое и точное описание для этого текста", "Create a concise, accurate description for this text")),
                Item(id: "create.continue", title: aorusAILocalized("Продолжить текст", "Continue writing"), icon: "pencil", prompt: aorusAILocalized("Естественно продолжи этот текст в том же стиле", "Continue this text naturally in the same style"))
            ]),
            Group(title: nil, icon: nil, items: [
                Item(id: analyzeChatId, title: aorusAILocalized("Анализ переписки", "Analyze chat"), icon: "chart.bar", prompt: ""),
                Item(id: newChatId, title: aorusAILocalized("Новый диалог", "New chat"), icon: "plus.bubble", prompt: "")
            ])
        ]
    }

    static func sections() -> [AorusAIMenuSection] {
        return groups.map { group in
            AorusAIMenuSection(title: group.title, iconName: group.icon, entries: group.items.map { AorusAIMenuEntry(id: $0.id, title: $0.title, iconName: $0.icon) })
        }
    }

    static func run(id: String, context: AccountContext, navigationController: NavigationController, reference: AorusAIReferencedMessage) {
        switch id {
        case analyzeChatId:
            aorusAIPresentHistoryCount(context: context, navigationController: navigationController, reference: reference)
        case newChatId:
            navigationController.pushViewController(AorusAIChatController(context: context, conversation: AorusAIConversation(), reference: reference))
        default:
            guard let prompt = groups.flatMap({ $0.items }).first(where: { $0.id == id })?.prompt, !prompt.isEmpty else { return }
            navigationController.pushViewController(AorusAIChatController(context: context, conversation: AorusAIConversation(), initialPrompt: prompt, reference: reference))
        }
    }
}

private func aorusAIPresentHistoryCount(context: AccountContext, navigationController: NavigationController, reference: AorusAIReferencedMessage) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let limit = AorusAIRequestLimits.chatHistoryMessageCount
    let sheet = UIAlertController(
        title: aorusAILocalized("Сколько сообщений проанализировать?", "How many messages should be analyzed?"),
        message: aorusAILocalized(
            "Сообщения читаются на устройстве и передаются AorusAI только после подтверждения.",
            "The messages are read on this device and shared with AorusAI only after you confirm."
        ),
        preferredStyle: .actionSheet
    )
    for count in [20, 50, 100, limit] {
        sheet.addAction(UIAlertAction(title: "\(count)", style: .default, handler: { _ in
            aorusAIPrepareHistoryAnalysis(context: context, navigationController: navigationController, reference: reference, count: count)
        }))
    }
    sheet.addAction(UIAlertAction(title: aorusAILocalized("Другое...", "Other..."), style: .default, handler: { _ in
        aorusAIPresentCustomHistoryCount(context: context, navigationController: navigationController, reference: reference)
    }))
    sheet.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
    aorusAIPresentActionSheet(sheet, from: navigationController)
}

private func aorusAIPresentCustomHistoryCount(context: AccountContext, navigationController: NavigationController, reference: AorusAIReferencedMessage) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let limit = AorusAIRequestLimits.chatHistoryMessageCount
    let alert = UIAlertController(
        title: aorusAILocalized("Количество сообщений", "Message count"),
        message: aorusAILocalized("От 1 до \(limit)", "From 1 to \(limit)"),
        preferredStyle: .alert
    )
    alert.addTextField { field in
        field.keyboardType = .numberPad
        field.placeholder = "50"
    }
    alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
    alert.addAction(UIAlertAction(title: presentationData.strings.Common_OK, style: .default, handler: { [weak alert] _ in
        let raw = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // An unparsable value is a mistake, not a request for a default: say so and
        // ask again instead of quietly analysing some other number of messages.
        guard let parsed = Int(raw), parsed > 0 else {
            let invalid = UIAlertController(
                title: aorusAILocalized("Некорректное количество", "Invalid count"),
                message: aorusAILocalized("Введите число от 1 до \(limit).", "Enter a number between 1 and \(limit)."),
                preferredStyle: .alert
            )
            invalid.addAction(UIAlertAction(title: presentationData.strings.Common_OK, style: .default, handler: { _ in
                aorusAIPresentCustomHistoryCount(context: context, navigationController: navigationController, reference: reference)
            }))
            navigationController.present(invalid, animated: true)
            return
        }
        aorusAIPrepareHistoryAnalysis(context: context, navigationController: navigationController, reference: reference, count: min(limit, parsed))
    }))
    navigationController.present(alert, animated: true)
}

private struct AorusAITranscript {
    var messageCount: Int
    var text: String
}

/// Reads the newest `count` text messages of `peerId` from the local Postbox.
///
/// The backend protocol declares a `telegram.chat.history` capability but does not
/// publish a body schema for answering a suspended `permission_request`, so the
/// client never lets the server pull history: it reads the messages itself, shows
/// exactly what will leave the device, and sends the transcript inline in the
/// request the user confirmed.
private func aorusAIChatTranscript(context: AccountContext, peerId: PeerId, namespace: Int32, count: Int) -> Signal<AorusAITranscript, NoError> {
    let limit = min(AorusAIRequestLimits.chatHistoryMessageCount, max(1, count))
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let strings = presentationData.strings
    let nameOrder = presentationData.nameDisplayOrder
    let unknownAuthor = aorusAILocalized("Сообщение", "Message")
    let perMessage = AorusAIRequestLimits.chatHistoryMessageCharacters
    return context.account.postbox.transaction { transaction -> AorusAITranscript in
        var lines: [String] = []
        transaction.scanTopMessages(peerId: peerId, namespace: namespace, limit: limit) { message in
            guard lines.count < limit else { return false }
            let body = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return true }
            let author = message.author.flatMap { EnginePeer($0).displayTitle(strings: strings, displayOrder: nameOrder) } ?? unknownAuthor
            let clamped = body.count > perMessage ? String(body.prefix(perMessage)) + "…" : body
            lines.append("\(author): \(clamped)")
            return true
        }
        let ordered = Array(lines.reversed())
        return AorusAITranscript(messageCount: ordered.count, text: ordered.joined(separator: "\n"))
    }
}

private func aorusAIPrepareHistoryAnalysis(context: AccountContext, navigationController: NavigationController, reference: AorusAIReferencedMessage, count: Int) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let limit = AorusAIRequestLimits.chatHistoryMessageCount
    let requested = min(limit, max(1, count))
    let signal = aorusAIChatTranscript(context: context, peerId: PeerId(reference.peerId), namespace: reference.messageNamespace, count: requested)
    let _ = (signal |> deliverOnMainQueue).start(next: { transcript in
        guard transcript.messageCount > 0 else {
            let empty = UIAlertController(
                title: aorusAILocalized("Нет сообщений для анализа", "Nothing to analyze"),
                message: aorusAILocalized(
                    "В этой переписке нет текстовых сообщений, которые можно передать AorusAI.",
                    "This chat has no text messages that could be shared with AorusAI."
                ),
                preferredStyle: .alert
            )
            empty.addAction(UIAlertAction(title: presentationData.strings.Common_OK, style: .default))
            navigationController.present(empty, animated: true)
            return
        }
        let confirmation = UIAlertController(
            title: aorusAILocalized("Передать переписку AorusAI?", "Share the chat with AorusAI?"),
            message: aorusAILocalized(
                "Будет передано \(transcript.messageCount) из последних \(requested) сообщений — \(transcript.text.count) символов. Ничего не уходит с устройства до подтверждения.",
                "\(transcript.messageCount) of the latest \(requested) messages — \(transcript.text.count) characters — will be shared. Nothing leaves the device until you confirm."
            ),
            preferredStyle: .alert
        )
        confirmation.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        confirmation.addAction(UIAlertAction(title: aorusAILocalized("Передать", "Share"), style: .default, handler: { _ in
            let visiblePrompt = aorusAILocalized(
                "Проанализируй последние \(transcript.messageCount) сообщений этой переписки.",
                "Analyze the last \(transcript.messageCount) messages of this chat."
            )
            let header = aorusAILocalized("Переписка:", "Chat transcript:")
            navigationController.pushViewController(AorusAIChatController(
                context: context,
                conversation: AorusAIConversation(),
                initialPrompt: visiblePrompt,
                initialRequest: visiblePrompt + "\n\n" + header + "\n" + transcript.text,
                reference: reference
            ))
        }))
        navigationController.present(confirmation, animated: true)
    })
}

private final class AorusAIConversationListController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private let presentationData: PresentationData
    private let accountId: Int64
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyView = AorusAIEmptyView()
    private var conversations: [AorusAIConversation] = []
    private var observer: NSObjectProtocol?

    init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.accountId = context.account.id.int64
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        self.title = "AorusAI"
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        // Telegram's navigation bar draws only `image` and `title` of a bar button item, so a
        // system item such as `.add` renders as an empty tap area — which is why the button
        // looked missing. The compose glyph is the one the chat list itself uses.
        let composeImage = PresentationResourcesRootController.navigationComposeIcon(self.presentationData.theme)
            ?? UIImage(systemName: "square.and.pencil")?.withTintColor(self.presentationData.theme.rootController.navigationBar.accentTextColor, renderingMode: .alwaysOriginal)
        let composeItem = UIBarButtonItem(image: composeImage, style: .plain, target: self, action: #selector(createConversation))
        composeItem.tintColor = self.presentationData.theme.rootController.navigationBar.accentTextColor
        composeItem.accessibilityLabel = aorusAILocalized("Новый диалог", "New chat")
        self.navigationItem.rightBarButtonItem = composeItem
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadDisplayNode() {
        self.displayNode = ViewControllerTracingNode()
        self.displayNode.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        tableView.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        tableView.separatorColor = self.presentationData.theme.list.itemBlocksSeparatorColor
        tableView.indicatorStyle = self.presentationData.theme.overallDarkAppearance ? .white : .black
        tableView.rowHeight = 76
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(AorusAIConversationCell.self, forCellReuseIdentifier: "conversation")
        self.displayNode.view.addSubview(tableView)
        emptyView.configure(theme: self.presentationData.theme)
        emptyView.onCreate = { [weak self] in self?.createConversation() }
        self.displayNode.view.addSubview(emptyView)
        observer = NotificationCenter.default.addObserver(forName: AorusAIStore.changedNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? NSNumber)?.int64Value == self.accountId else { return }
            self.reload()
        }
        reload()
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        let frame = CGRect(x: 0, y: top, width: layout.size.width, height: max(0, layout.size.height - top))
        transition.updateFrame(view: tableView, frame: frame)
        transition.updateFrame(view: emptyView, frame: frame)
    }

    private func reload() {
        AorusAIStore.shared.load(accountId: accountId) { [weak self] conversations in
            self?.conversations = conversations
            self?.tableView.reloadData()
            self?.emptyView.isHidden = !conversations.isEmpty
            self?.emptyView.accessibilityElementsHidden = !conversations.isEmpty
        }
    }

    @objc private func createConversation() {
        let conversation = AorusAIConversation()
        AorusAIStore.shared.upsert(conversation, accountId: accountId)
        (self.navigationController as? NavigationController)?.pushViewController(AorusAIChatController(context: context, conversation: conversation))
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { conversations.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "conversation", for: indexPath) as? AorusAIConversationCell else {
            assertionFailure("Unexpected AorusAI conversation cell type")
            return UITableViewCell(style: .default, reuseIdentifier: nil)
        }
        cell.configure(conversation: conversations[indexPath.row], theme: presentationData.theme)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        (self.navigationController as? NavigationController)?.pushViewController(AorusAIChatController(context: context, conversation: conversations[indexPath.row]))
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let id = conversations[indexPath.row].id
        let action = UIContextualAction(style: .destructive, title: presentationData.strings.Common_Delete) { [weak self] _, _, done in
            guard let self else { done(false); return }
            AorusAIStore.shared.delete(conversationId: id, accountId: self.accountId) { done($0) }
        }
        action.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }
}

private final class AorusAIConversationCell: UITableViewCell {
    private let titleLabel = UILabel()
    private let previewLabel = UILabel()
    private let dateLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        previewLabel.font = .systemFont(ofSize: 14)
        dateLabel.font = .systemFont(ofSize: 13)
        previewLabel.lineBreakMode = .byTruncatingTail
        dateLabel.textAlignment = .right
        [titleLabel, previewLabel, dateLabel].forEach { contentView.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 13),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -10),
            dateLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            dateLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            previewLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            previewLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6)
        ])
        accessoryType = .disclosureIndicator
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(conversation: AorusAIConversation, theme: PresentationTheme) {
        backgroundColor = theme.list.itemBlocksBackgroundColor
        titleLabel.textColor = theme.list.itemPrimaryTextColor
        previewLabel.textColor = theme.list.itemSecondaryTextColor
        dateLabel.textColor = theme.list.itemSecondaryTextColor
        titleLabel.text = conversation.title.isEmpty ? aorusAILocalized("Новый диалог", "New chat") : conversation.title
        previewLabel.text = conversation.messages.last(where: { !$0.rawText.isEmpty })?.rawText ?? aorusAILocalized("Начните разговор с AorusAI", "Start a conversation with AorusAI")
        dateLabel.text = AorusAIFormat.relativeDate(conversation.updatedAt)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = titleLabel.text
        accessibilityValue = [previewLabel.text, dateLabel.text].compactMap { $0 }.joined(separator: ", ")
    }
}

private final class AorusAIEmptyView: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let createButton = UIButton(type: .system)
    var onCreate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .scaleAspectFit
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.text = "AorusAI"
        detailLabel.font = .systemFont(ofSize: 15)
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        detailLabel.text = aorusAILocalized("Создайте диалог, чтобы начать", "Create a chat to get started")
        // The empty state is where a first-time user lands, so the primary action is on
        // screen instead of only in the navigation bar.
        createButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        createButton.setTitle(aorusAILocalized("Новый диалог", "New chat"), for: .normal)
        createButton.layer.cornerRadius = 22
        createButton.layer.cornerCurve = .continuous
        createButton.addTarget(self, action: #selector(create), for: .touchUpInside)
        [iconView, titleLabel, detailLabel, createButton].forEach { addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -50),
            iconView.widthAnchor.constraint(equalToConstant: 54), iconView.heightAnchor.constraint(equalToConstant: 54),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30), titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40), detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            createButton.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 22),
            createButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            createButton.heightAnchor.constraint(equalToConstant: 44),
            createButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func create() { onCreate?() }

    func configure(theme: PresentationTheme) {
        iconView.image = UIImage(systemName: "sparkles")?.withRenderingMode(.alwaysTemplate)
        iconView.tintColor = theme.list.itemAccentColor
        titleLabel.textColor = theme.list.itemPrimaryTextColor
        detailLabel.textColor = theme.list.itemSecondaryTextColor
        createButton.backgroundColor = theme.list.itemAccentColor.withAlphaComponent(0.12)
        createButton.setTitleColor(theme.list.itemAccentColor, for: .normal)
    }
}

private final class AorusAIChatController: ViewController, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    private let context: AccountContext
    private let presentationData: PresentationData
    private let accountId: Int64
    private var conversation: AorusAIConversation
    private let initialPrompt: String?
    private let initialRequest: String?
    private var initialRequestStarted = false
    private var pendingReference: AorusAIReferencedMessage?
    private var streamHandle: AorusAIStreamHandle?
    private var turnId: String?
    private var activeAssistantId: UUID?
    private var previewURL: URL?
    private var quotaTimer: Foundation.Timer?
    private var keyboardHeight: CGFloat = 0
    private var lastLayout: ContainerViewLayout?
    private var lastPersist = Date.distantPast
    private var pendingPersistWork: DispatchWorkItem?
    private var pendingRenderWork: DispatchWorkItem?
    private var draftEntityResolutionDisposables: [Disposable] = []
    private var messageEntityResolutionDisposables: [UUID: [Disposable]] = [:]
    /// Holds the one profile lookup that runs between "send" and the request going out.
    private let profileContextDisposable = MetaDisposable()
    private var draftEntities: [AorusAITelegramEntity] = []
    private var draftEntitiesText = ""
    /// The transport handle only exists once the request is on the wire, so a turn that
    /// is still being prepared is tracked separately — otherwise the stop button falls
    /// back to a disabled send button over an already-cleared input.
    private var isPreparingRequest = false
    private let dictation = AorusAIDictation()
    /// What the input held before the current dictation run, so partial results replace
    /// only the spoken part instead of the whole draft.
    private var dictationBaseText = ""
    private var headerView: AorusAINavigationTitleView?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let composer = AorusAIComposerView()

    /// `initialPrompt` is what the user sees in the conversation. `initialRequest`
    /// is what is actually sent when the two differ — a chat analysis shows a short
    /// instruction but transports the confirmed transcript with it.
    init(context: AccountContext, conversation: AorusAIConversation, initialPrompt: String? = nil, initialRequest: String? = nil, reference: AorusAIReferencedMessage? = nil) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.accountId = context.account.id.int64
        self.conversation = conversation
        self.initialPrompt = initialPrompt
        self.initialRequest = initialRequest
        self.pendingReference = reference
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        // The header is a real chat header: gradient badge, name and a live status line.
        // `title` stays unset because Telegram's navigation bar draws either the string or
        // the custom view, never both.
        let titleView = AorusAINavigationTitleView(theme: self.presentationData.theme)
        self.headerView = titleView
        self.navigationItem.titleView = titleView
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingPersistWork?.cancel()
        pendingRenderWork?.cancel()
        quotaTimer?.invalidate()
        streamHandle?.cancelTransport()
        if let turnId {
            AorusAIClient.shared.cancelTurn(turnId) { _ in }
        }
        draftEntityResolutionDisposables.forEach { $0.dispose() }
        messageEntityResolutionDisposables.values.flatMap { $0 }.forEach { $0.dispose() }
        profileContextDisposable.dispose()
        removePreviewArtifact()
    }

    override func loadDisplayNode() {
        self.displayNode = ViewControllerTracingNode()
        self.displayNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        tableView.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive
        tableView.estimatedRowHeight = 100
        tableView.rowHeight = UITableView.automaticDimension
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(AorusAIMessageCell.self, forCellReuseIdentifier: "message")
        self.displayNode.view.addSubview(tableView)
        composer.configure(context: context, theme: presentationData.theme)
        composer.onOpenPeer = { [weak self] peerId in self?.openPeer(peerId) }
        composer.onHeightChanged = { [weak self] in
            guard let self, let layout = self.lastLayout else { return }
            self.applyLayout(layout, transition: .animated(duration: 0.2, curve: .easeInOut))
        }
        composer.textView.delegate = self
        composer.onSend = { [weak self] in self?.sendOrStop() }
        composer.onDictation = { [weak self] in self?.toggleDictation() }
        composer.onDismissReference = { [weak self] in self?.pendingReference = nil; self?.composer.reference = nil }
        composer.text = conversation.draft
        composer.reference = pendingReference
        resolveDraftEntities(in: composer.text)
        self.displayNode.view.addSubview(composer)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        if let initialPrompt, !initialPrompt.isEmpty { composer.text = initialPrompt }
        scheduleQuotaResetIfNeeded()
        updateComposer()
        self.displayNodeDidLoad()
        DispatchQueue.main.async { [weak self] in self?.scrollToBottom(animated: false) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let initialPrompt, !initialPrompt.isEmpty, !initialRequestStarted {
            initialRequestStarted = true
            let requestText = initialRequest ?? initialPrompt
            DispatchQueue.main.async { [weak self] in
                self?.send(displayText: initialPrompt, requestText: requestText)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        conversation.draft = composer.text
        persist(force: true)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        lastLayout = layout
        applyLayout(layout, transition: transition)
    }

    private func applyLayout(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        let bottomInset = max(layout.intrinsicInsets.bottom, keyboardHeight)
        let composerHeight = composer.requiredHeight(width: layout.size.width)
        let composerFrame = CGRect(x: 0, y: layout.size.height - bottomInset - composerHeight, width: layout.size.width, height: composerHeight)
        transition.updateFrame(view: composer, frame: composerFrame)
        transition.updateFrame(view: tableView, frame: CGRect(x: 0, y: top, width: layout.size.width, height: max(0, composerFrame.minY - top)))
        // A read-modify-write on `scrollIndicatorInsets` goes through a getter the SDK
        // deprecated in iOS 13, so assign the vertical insets directly instead.
        tableView.verticalScrollIndicatorInsets = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 8.0, right: 0.0)
    }

    @objc private func keyboardChanged(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else { return }
        let converted = self.displayNode.view.convert(frame, from: nil)
        keyboardHeight = max(0, self.displayNode.view.bounds.maxY - converted.minY)
        guard let layout = lastLayout else { return }
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.applyLayout(layout, transition: .immediate)
        }
    }

    @objc private func appDidEnterBackground() {
        conversation.draft = composer.text
        persist(force: true)
        if dictation.isRunning { dictation.stop() }
        if streamHandle != nil {
            if let turnId {
                AorusAIClient.shared.cancelTurn(turnId) { _ in }
            }
            finishStreaming(error: .offline, preserveText: true)
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        conversation.draft = textView.text
        conversation.updatedAt = Date()
        composer.invalidateHeight()
        resolveDraftEntities(in: textView.text)
        if let layout = lastLayout { applyLayout(layout, transition: .immediate) }
        updateComposer()
        persist(force: false)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        composer.setInputActive(true)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        composer.setInputActive(false)
    }

    private func sendOrStop() {
        if streamHandle != nil || isPreparingRequest {
            stopGeneration()
        } else {
            send()
        }
    }

    private func send() {
        if dictation.isRunning { dictation.stop() }
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        send(displayText: text, requestText: text)
    }

    private func send(displayText: String, requestText: String) {
        guard streamHandle == nil, !isPreparingRequest else { return }
        if let resetAt = conversation.quotaResetAt {
            guard resetAt <= Date() else { return }
            conversation.quotaResetAt = nil
        }
        let text = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        var transportText = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !transportText.isEmpty else { return }
        let entities = draftEntitiesText == text ? draftEntities : AorusAIFormat.entities(in: text)
        let userMessage = AorusAIMessage(role: .user, rawText: text, telegramEntities: entities, referencedMessage: pendingReference)
        // The production contract is a plain chat-completions body, so a quoted
        // Telegram message travels inside the request text. It stays out of the
        // visible bubble: that one keeps the reference card instead.
        if let reference = userMessage.referencedMessage {
            let quoted = reference.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !quoted.isEmpty {
                let author = reference.authorName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let heading = (author?.isEmpty == false)
                    ? aorusAILocalized("Сообщение из Telegram от \(author ?? ""):", "Telegram message from \(author ?? ""):")
                    : aorusAILocalized("Сообщение из Telegram:", "Telegram message:")
                transportText += "\n\n" + heading + "\n" + quoted
            }
        }
        let assistant = AorusAIMessage(role: .assistant, rawText: "", state: .streaming, statusLabel: aorusAILocalized("Подключение...", "Connecting..."))
        conversation.messages.append(userMessage)
        conversation.messages.append(assistant)
        if conversation.title.isEmpty { conversation.title = AorusAIFormat.title(from: text) }
        conversation.draft = ""
        conversation.updatedAt = Date()
        activeAssistantId = assistant.id
        isPreparingRequest = true
        composer.text = ""
        resolveDraftEntities(in: "")
        composer.reference = nil
        pendingReference = nil
        // Mentions are resolved on the device before the request leaves, so the model
        // is told who `@name` actually is instead of guessing from the handle.
        let mentioned = Self.mentionedUsernames(in: entities)
        if !mentioned.isEmpty, let index = conversation.messages.firstIndex(where: { $0.id == assistant.id }) {
            conversation.messages[index].statusLabel = aorusAILocalized("Читаю профиль...", "Reading profile...")
        }
        updateComposer()
        tableView.reloadData()
        scrollToBottom(animated: true)
        persist(force: true)
        resolveEntities(forMessageId: userMessage.id)

        let baseTransportText = transportText
        let turn = assistant.id
        resolveProfileContext(usernames: mentioned) { [weak self] block in
            guard let self, self.activeAssistantId == turn, self.isPreparingRequest, self.streamHandle == nil else { return }
            var finalText = baseTransportText
            if !block.isEmpty {
                finalText += "\n\n" + aorusAILocalized("Контекст из Telegram:", "Telegram context:") + "\n" + block
            }
            self.startTransport(text: finalText)
        }
    }

    /// Up to three distinct mentions, in the order they appear, so a long list of
    /// handles cannot blow up the request.
    private static func mentionedUsernames(in entities: [AorusAITelegramEntity]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for entity in entities {
            guard let username = entity.username?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")), !username.isEmpty else { continue }
            let key = username.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(username)
            if result.count >= 3 { break }
        }
        return result
    }

    private func startTransport(text: String) {
        if let id = activeAssistantId, let index = conversation.messages.firstIndex(where: { $0.id == id }) {
            conversation.messages[index].statusLabel = aorusAILocalized("Подключение...", "Connecting...")
        }
        // Everything before the two turns just appended is replayed context; the
        // payload itself trims it to the transport budget.
        let payload = AorusAIAgentPayload(history: Array(conversation.messages.dropLast(2)), text: text)
        streamHandle = AorusAIClient.shared.start(payload: payload, event: { [weak self] event in
            self?.handle(event)
        }, completion: { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result, error != .cancelled {
                self.finishStreaming(error: error, preserveText: true)
            } else if self.streamHandle != nil {
                // A successful HTTP EOF is not a successful agent turn by itself.
                // Only the protocol's explicit `done ok=true` event completes it.
                self.finishStreaming(error: .serverUnavailable, preserveText: true)
            }
        })
        isPreparingRequest = false
        updateComposer()
        if streamHandle == nil { finishStreaming(error: .notProvisioned, preserveText: false) }
    }

    private func handle(_ event: AorusAIEvent) {
        guard let id = activeAssistantId, let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case let .agentStarted(turnId, _):
            // §5: the turn id is kept only to be able to cancel, and is never shown.
            // `context` is a server-side field with no documented client use, so it is
            // parsed and deliberately dropped rather than stored as dead state.
            self.turnId = turnId
        case let .status(label, progress):
            let visibleLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? aorusAILocalized("Выполняю...", "Working...")
                : label
            conversation.messages[index].statusLabel = AorusAIFormat.safeStatus(visibleLabel, progress: progress)
        case let .reasoningSummary(value):
            conversation.messages[index].statusLabel = AorusAIFormat.safeStatus(value)
        case .responseStarted:
            conversation.messages[index].statusLabel = nil
        case let .responseDelta(delta):
            conversation.messages[index].rawText.append(delta)
            conversation.messages[index].statusLabel = nil
        case let .artifactReady(artifact):
            if !conversation.messages[index].artifacts.contains(where: { $0.artifactId == artifact.artifactId }) {
                conversation.messages[index].artifacts.append(artifact)
            }
        case let .permissionRequest(request):
            presentPermission(request)
        case .responseDone:
            conversation.messages[index].statusLabel = nil
        case let .quota(quota):
            conversation.quotaResetAt = quota.resetAt
            scheduleQuotaResetIfNeeded()
            finishStreaming(error: .quota(quota), preserveText: true)
            return
        case let .done(ok):
            if ok { completeStreaming(cancelled: false) }
            else { finishStreaming(error: .serverUnavailable, preserveText: true) }
            return
        case .unknown:
            break
        }
        conversation.updatedAt = Date()
        scheduleRender(messageId: id)
    }

    private func stopGeneration() {
        let handle = streamHandle
        streamHandle = nil
        isPreparingRequest = false
        // Stopping during the profile lookup must abort it too, otherwise the request
        // would still be dispatched a moment later.
        profileContextDisposable.set(nil)
        handle?.cancelTransport()
        if let turnId {
            AorusAIClient.shared.cancelTurn(turnId) { _ in }
        }
        completeStreaming(cancelled: true)
    }

    private func completeStreaming(cancelled: Bool) {
        guard let id = activeAssistantId, let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        // §7: a turn that ended without a single visible character must not leave the
        // chat looking as if the message vanished. It becomes a failed turn instead, so
        // the bubble carries an explanation and the Retry action.
        let produced = !conversation.messages[index].rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !conversation.messages[index].artifacts.isEmpty
        if !cancelled, !produced {
            isPreparingRequest = false
            finishStreaming(error: .serverUnavailable, preserveText: false)
            return
        }
        conversation.messages[index].state = cancelled ? .cancelled : .complete
        if cancelled, !produced {
            conversation.messages[index].rawText = ""
            conversation.messages[index].statusLabel = aorusAILocalized("Остановлено до ответа", "Stopped before a reply")
        } else {
            conversation.messages[index].statusLabel = cancelled ? aorusAILocalized("Остановлено", "Stopped") : nil
        }
        if !cancelled {
            resolveEntities(forMessageId: id)
        }
        streamHandle = nil
        isPreparingRequest = false
        turnId = nil
        activeAssistantId = nil
        pendingRenderWork?.cancel()
        pendingRenderWork = nil
        conversation.updatedAt = Date()
        updateComposer()
        reloadMessage(id: id)
        persist(force: true)
    }

    private func finishStreaming(error: AorusAIClientError, preserveText: Bool) {
        guard let id = activeAssistantId, let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        if !preserveText { conversation.messages[index].rawText = "" }
        conversation.messages[index].state = .failed
        conversation.messages[index].statusLabel = AorusAIFormat.errorText(error)
        conversation.messages[index].errorCode = AorusAIFormat.safeErrorCode(error)
        streamHandle?.cancelTransport()
        streamHandle = nil
        isPreparingRequest = false
        turnId = nil
        activeAssistantId = nil
        pendingRenderWork?.cancel()
        pendingRenderWork = nil
        updateComposer()
        reloadMessage(id: id)
        persist(force: true)
    }

    private func presentPermission(_ request: AorusAIPermissionRequest) {
        let show: (String?) -> Void = { [weak self] peerName in
            self?.presentPermission(request, peerName: peerName)
        }
        guard let peerId = request.peerId else {
            show(nil)
            return
        }
        let strings = presentationData.strings
        let nameOrder = presentationData.nameDisplayOrder
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: PeerId(peerId))) |> deliverOnMainQueue).start(next: { peer in
            show(peer?.displayTitle(strings: strings, displayOrder: nameOrder))
        })
    }

    private func presentPermission(_ request: AorusAIPermissionRequest, peerName: String?) {
        let kind = request.kind.lowercased()
        if kind.contains("send"), let peerId = request.peerId, let text = request.previewText, !text.isEmpty {
            presentSendConfirmation(peerId: PeerId(peerId), peerName: peerName, text: text)
            return
        }

        var message: String
        if kind.contains("history") {
            let count = min(200, max(1, request.count ?? 20))
            let target = peerName.map { " \($0)" } ?? ""
            message = aorusAILocalized(
                "AorusAI запрашивает последние \(count) сообщений из переписки\(target). Данные будут переданы только после подтверждения.",
                "AorusAI requests the latest \(count) messages from\(target.isEmpty ? " this chat" : target). Data is shared only after confirmation."
            )
        } else {
            let target = peerName.map { "\n\($0)" } ?? ""
            message = (request.previewText ?? aorusAILocalized("AorusAI запрашивает доступ к данным Telegram.", "AorusAI requests access to Telegram data.")) + target
        }
        let alert = UIAlertController(title: aorusAILocalized("Разрешить доступ?", "Allow access?"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel, handler: { [weak self] _ in
            self?.denyPermission()
        }))
        alert.addAction(UIAlertAction(title: aorusAILocalized("Разрешить", "Allow"), style: .default, handler: { [weak self] _ in
            self?.fulfillPermission(request)
        }))
        present(alert, animated: true)
    }

    private func presentSendConfirmation(peerId: PeerId, peerName: String?, text: String) {
        let recipient = peerName.map { aorusAILocalized("Получатель: \($0)\n\n", "Recipient: \($0)\n\n") } ?? ""
        let alert = UIAlertController(
            title: aorusAILocalized("Отправить ответ?", "Send reply?"),
            message: recipient + text,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel, handler: { [weak self] _ in
            self?.denyPermission()
        }))
        alert.addAction(UIAlertAction(title: aorusAILocalized("Изменить", "Edit"), style: .default, handler: { [weak self] _ in
            self?.presentSendEditor(peerId: peerId, peerName: peerName, text: text)
        }))
        alert.addAction(UIAlertAction(title: aorusAILocalized("Отправить", "Send"), style: .default, handler: { [weak self] _ in
            self?.sendConfirmedMessage(peerId: peerId, text: text)
        }))
        present(alert, animated: true)
    }

    private func presentSendEditor(peerId: PeerId, peerName: String?, text: String) {
        let alert = UIAlertController(title: aorusAILocalized("Изменить ответ", "Edit reply"), message: peerName, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = text
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel, handler: { [weak self] _ in
            self?.denyPermission()
        }))
        alert.addAction(UIAlertAction(title: aorusAILocalized("Продолжить", "Continue"), style: .default, handler: { [weak self, weak alert] _ in
            guard let self, let updated = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !updated.isEmpty else { return }
            self.presentSendConfirmation(peerId: peerId, peerName: peerName, text: updated)
        }))
        present(alert, animated: true)
    }

    private func sendConfirmedMessage(peerId: PeerId, text: String) {
        let _ = enqueueMessages(account: context.account, peerId: peerId, messages: [
            .message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        ]).startStandalone()
        denyPermission()
        appendLocalNotice(aorusAILocalized("Сообщение отправлено", "Message sent"))
    }

    private func fulfillPermission(_ request: AorusAIPermissionRequest) {
        // The public backend specification does not define a response endpoint or a
        // request-body schema for resuming a suspended permission request. Never send
        // Telegram data through a guessed contract: it could leak history or execute a
        // tool against the wrong turn. Keep the current partial response and terminate
        // the turn fail-closed until the signed backend contract is available.
        denyPermission()
        appendLocalNotice(aorusAILocalized(
            "Действие не выполнено: сервер не предоставил безопасный контракт продолжения.",
            "The action was not performed because the server did not provide a secure continuation contract."
        ))
    }

    private func denyPermission() {
        let handle = streamHandle
        streamHandle = nil
        handle?.cancelTransport()
        if let turnId {
            AorusAIClient.shared.cancelTurn(turnId) { _ in }
        }
        completeStreaming(cancelled: true)
    }

    private func appendLocalNotice(_ text: String) {
        conversation.messages.append(AorusAIMessage(role: .notice, rawText: text))
        conversation.updatedAt = Date()
        tableView.reloadData()
        scrollToBottom(animated: true)
        persist(force: true)
    }

    private func updateComposer() {
        if let resetAt = conversation.quotaResetAt, resetAt <= Date() {
            conversation.quotaResetAt = nil
            quotaTimer?.invalidate()
            quotaTimer = nil
        }
        let quotaBlocked = conversation.quotaResetAt.map { $0 > Date() } ?? false
        // The transport handle is assigned after the composer is cleared, so the flag is
        // what keeps the button in its stop state for the whole turn instead of leaving a
        // dead grey circle over an empty input.
        composer.isGenerating = streamHandle != nil || isPreparingRequest
        composer.canSend = !quotaBlocked && !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        updateHeaderStatus(quotaBlocked: quotaBlocked)
    }

    /// The header carries the state of the turn, so the user can tell a working assistant
    /// from an idle one without hunting for a spinner inside the last bubble.
    private func updateHeaderStatus(quotaBlocked: Bool) {
        if dictation.isRunning {
            headerView?.setStatus(aorusAILocalized("слушаю...", "listening..."), active: true)
            return
        }
        if streamHandle != nil || isPreparingRequest {
            let label = activeAssistantId
                .flatMap { id in conversation.messages.first(where: { $0.id == id })?.statusLabel }
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            headerView?.setStatus(label ?? aorusAILocalized("печатает...", "typing..."), active: true)
            return
        }
        if quotaBlocked, let resetAt = conversation.quotaResetAt, resetAt > Date() {
            headerView?.setStatus(aorusAILocalized("лимит исчерпан", "limit reached"), active: false)
            return
        }
        headerView?.setStatus(aorusAILocalized("готов помочь", "ready to help"), active: false)
    }

    // MARK: - Dictation

    private func toggleDictation() {
        if dictation.isRunning {
            dictation.stop()
            return
        }
        guard streamHandle == nil, !isPreparingRequest else { return }
        dictationBaseText = composer.text
        let locale = AorusAIDictation.locale(for: presentationData.strings.baseLanguageCode)
        composer.isDictating = true
        updateComposer()
        dictation.start(locale: locale, onText: { [weak self] text in
            guard let self else { return }
            let base = self.dictationBaseText.trimmingCharacters(in: .whitespacesAndNewlines)
            let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let joined = base.isEmpty ? spoken : (spoken.isEmpty ? base : base + " " + spoken)
            self.composer.text = joined
            self.textViewDidChangeSilently()
        }, onFailure: { [weak self] failure in
            self?.presentError(failure.message)
        }, onFinish: { [weak self] in
            guard let self else { return }
            self.composer.isDictating = false
            self.dictationBaseText = self.composer.text
            self.updateComposer()
        })
    }

    /// Applies the same side effects as typing without re-entering the delegate.
    private func textViewDidChangeSilently() {
        conversation.draft = composer.text
        conversation.updatedAt = Date()
        composer.invalidateHeight()
        resolveDraftEntities(in: composer.text)
        if let layout = lastLayout { applyLayout(layout, transition: .immediate) }
        updateComposer()
    }

    private func scheduleQuotaResetIfNeeded() {
        quotaTimer?.invalidate()
        quotaTimer = nil
        guard let resetAt = conversation.quotaResetAt, resetAt > Date() else {
            if conversation.quotaResetAt != nil {
                conversation.quotaResetAt = nil
            }
            return
        }
        quotaTimer = Foundation.Timer.scheduledTimer(withTimeInterval: max(1.0, resetAt.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.conversation.quotaResetAt = nil
            self.quotaTimer = nil
            self.updateComposer()
            self.persist(force: true)
        }
    }

    private func displayName(of peer: EnginePeer) -> String {
        return peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
    }

    private func resolveDraftEntities(in text: String) {
        draftEntityResolutionDisposables.forEach { $0.dispose() }
        draftEntityResolutionDisposables.removeAll()
        draftEntitiesText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        draftEntities = AorusAIFormat.entities(in: draftEntitiesText)
        composer.entities = draftEntities
        for index in draftEntities.indices {
            guard let username = draftEntities[index].username else { continue }
            let expectedText = draftEntitiesText
            let disposable = (context.engine.peers.resolvePeerByName(name: username, referrer: nil) |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self, self.draftEntitiesText == expectedText, case let .result(peer) = result, let peer else { return }
                guard index < self.draftEntities.count, self.draftEntities[index].username?.lowercased() == username.lowercased() else { return }
                self.draftEntities[index].peerId = peer.id.toInt64()
                self.draftEntities[index].displayName = self.displayName(of: peer)
                self.composer.entities = self.draftEntities
            })
            draftEntityResolutionDisposables.append(disposable)
        }
    }

    /// Turns the mentioned handles into compact profile blocks that travel with the
    /// request, so the model knows who `@name` is. Only data the user can already see
    /// in the app is included, and `AorusAIProfileSummary` clamps it.
    private func resolveProfileContext(usernames: [String], completion: @escaping (String) -> Void) {
        profileContextDisposable.set(nil)
        guard !usernames.isEmpty else {
            completion("")
            return
        }
        let labels = AorusAIProfileLabels(
            profile: aorusAILocalized("Профиль", "Profile"),
            kind: aorusAILocalized("Тип", "Type"),
            participants: aorusAILocalized("Участников", "Members"),
            about: aorusAILocalized("Описание", "Bio")
        )
        let empty: Signal<[AorusAIProfileSummary?], NoError> = .single([])
        // A lookup must never hold the turn hostage: after the ceiling the request goes
        // out with whatever was resolved, exactly as if no handle had been mentioned.
        let combined = combineLatest(usernames.map { self.profileSummarySignal(username: $0) })
        |> take(1)
        |> timeout(2.5, queue: Queue.mainQueue(), alternate: empty)
        |> deliverOnMainQueue
        profileContextDisposable.set(combined.start(next: { summaries in
            let blocks = summaries.compactMap { $0?.transportBlock(labels: labels) }.filter { !$0.isEmpty }
            completion(blocks.joined(separator: "\n\n"))
        }))
    }

    private func profileSummarySignal(username: String) -> Signal<AorusAIProfileSummary?, NoError> {
        let context = self.context
        let strings = self.presentationData.strings
        let nameOrder = self.presentationData.nameDisplayOrder
        return context.engine.peers.resolvePeerByName(name: username, referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            if case let .result(peer) = result {
                return .single(peer)
            }
            return .complete()
        }
        |> take(1)
        |> mapToSignal { peer -> Signal<AorusAIProfileSummary?, NoError> in
            guard let peer = peer else {
                return .single(nil)
            }
            let basic = AorusAIProfileSummary(
                title: peer.displayTitle(strings: strings, displayOrder: nameOrder),
                username: peer.addressName,
                kind: AorusAIChatController.profileKind(peer),
                bio: nil,
                participantCount: nil
            )
            let fallback: Signal<AorusAIProfileSummary?, NoError> = .single(basic)
            // Subscribing to the peer view with `updateData` is what makes Telegram fetch
            // the cached data; the engine items only report what is already known.
            let details: Signal<AorusAIProfileSummary?, NoError> = combineLatest(
                context.account.viewTracker.peerView(peer.id, updateData: true) |> map { _ -> Bool in true },
                context.engine.data.subscribe(
                    TelegramEngine.EngineData.Item.Peer.AboutText(id: peer.id),
                    TelegramEngine.EngineData.Item.Peer.ParticipantCount(id: peer.id)
                )
            )
            |> map { $0.1 }
            |> filter { data -> Bool in
                if case .known = data.0 {
                    return true
                }
                return false
            }
            |> take(1)
            |> map { data -> AorusAIProfileSummary? in
                var summary = basic
                if case let .known(value) = data.0 {
                    summary.bio = value
                }
                summary.participantCount = data.1
                return summary
            }
            return details |> timeout(1.8, queue: Queue.mainQueue(), alternate: fallback)
        }
    }

    /// Only patterns with a green precedent in this module are used: the channel case
    /// plus namespace checks, so no unverified `EnginePeer` case is referenced.
    private static func profileKind(_ peer: EnginePeer) -> String {
        if case let .channel(channel) = peer {
            if case .broadcast = channel.info {
                return aorusAILocalized("канал", "channel")
            }
            return aorusAILocalized("группа", "group")
        }
        if peer.id.namespace == Namespaces.Peer.CloudGroup {
            return aorusAILocalized("группа", "group")
        }
        if peer.id.namespace == Namespaces.Peer.SecretChat {
            return aorusAILocalized("секретный чат", "secret chat")
        }
        return aorusAILocalized("пользователь", "user")
    }

    private func resolveEntities(forMessageId messageId: UUID) {
        messageEntityResolutionDisposables.removeValue(forKey: messageId)?.forEach { $0.dispose() }
        guard let messageIndex = conversation.messages.firstIndex(where: { $0.id == messageId }) else { return }
        let parsed = AorusAIFormat.entities(in: conversation.messages[messageIndex].rawText)
        conversation.messages[messageIndex].telegramEntities = parsed
        var disposables: [Disposable] = []
        for entityIndex in parsed.indices {
            guard let username = parsed[entityIndex].username else { continue }
            let disposable = (context.engine.peers.resolvePeerByName(name: username, referrer: nil) |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self, case let .result(peer) = result, let peer,
                      let currentMessageIndex = self.conversation.messages.firstIndex(where: { $0.id == messageId }),
                      entityIndex < self.conversation.messages[currentMessageIndex].telegramEntities.count else { return }
                self.conversation.messages[currentMessageIndex].telegramEntities[entityIndex].peerId = peer.id.toInt64()
                self.conversation.messages[currentMessageIndex].telegramEntities[entityIndex].displayName = self.displayName(of: peer)
                self.reloadMessage(id: messageId)
                self.persist(force: false)
            })
            disposables.append(disposable)
        }
        messageEntityResolutionDisposables[messageId] = disposables
    }

    private func persist(force: Bool) {
        if force {
            pendingPersistWork?.cancel()
            pendingPersistWork = nil
        } else {
            let elapsed = Date().timeIntervalSince(lastPersist)
            if elapsed < 0.35 {
                guard pendingPersistWork == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingPersistWork = nil
                    self.persist(force: true)
                }
                pendingPersistWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (0.35 - elapsed), execute: work)
                return
            }
        }
        lastPersist = Date()
        AorusAIStore.shared.upsert(conversation, accountId: accountId)
    }

    private func scheduleRender(messageId: UUID) {
        guard pendingRenderWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRenderWork = nil
            self.reloadMessage(id: messageId)
            // Throttled with the render, so the header follows the turn's own status text
            // instead of being recomputed on every delta.
            self.updateHeaderStatus(quotaBlocked: self.conversation.quotaResetAt.map { $0 > Date() } ?? false)
            self.persist(force: false)
        }
        pendingRenderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: work)
    }

    private func reloadMessage(id: UUID) {
        guard let row = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        let indexPath = IndexPath(row: row, section: 0)
        let message = conversation.messages[row]
        let canRetry = message.state == .failed && row == conversation.messages.count - 1
        // §27: during streaming this method fires several times per second. Rebuilding the
        // whole cell drops the text selection and flickers, so try to push only the changed
        // text into the live views and let the table re-measure the height.
        if let cell = tableView.cellForRow(at: indexPath) as? AorusAIMessageCell,
           cell.applyIncremental(message: message, theme: presentationData.theme, canRetry: canRetry) {
            tableView.beginUpdates()
            tableView.endUpdates()
        } else {
            tableView.reloadRows(at: [indexPath], with: .none)
        }
        scrollToBottom(animated: false)
    }

    private func scrollToBottom(animated: Bool) {
        guard !conversation.messages.isEmpty else { return }
        tableView.scrollToRow(at: IndexPath(row: conversation.messages.count - 1, section: 0), at: .bottom, animated: animated)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { conversation.messages.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath) as? AorusAIMessageCell else {
            assertionFailure("Unexpected AorusAI message cell type")
            return UITableViewCell(style: .default, reuseIdentifier: nil)
        }
        let message = conversation.messages[indexPath.row]
        cell.configure(
            message: message,
            context: context,
            theme: presentationData.theme,
            canRetry: message.state == .failed && indexPath.row == conversation.messages.count - 1
        )
        cell.onOpenLink = { [weak self] url in self?.open(url: url) }
        cell.onArtifact = { [weak self] artifact, card in self?.open(artifact: artifact, card: card) }
        cell.onCopy = { [weak self] in self?.presentCopiedFeedback() }
        cell.onRetry = { [weak self] in self?.retry(messageId: message.id) }
        return cell
    }

    private func retry(messageId: UUID) {
        guard streamHandle == nil,
              let assistantIndex = conversation.messages.firstIndex(where: { $0.id == messageId }),
              assistantIndex == conversation.messages.count - 1,
              assistantIndex > 0 else { return }
        let user = conversation.messages[assistantIndex - 1]
        guard user.role == .user else { return }
        composer.text = user.rawText
        resolveDraftEntities(in: user.rawText)
        pendingReference = user.referencedMessage
        composer.reference = pendingReference
        conversation.messages.removeSubrange((assistantIndex - 1)...assistantIndex)
        tableView.reloadData()
        send()
    }

    private func open(url: URL) {
        if url.scheme == "aorus-peer", let host = url.host, let raw = Int64(host) {
            openPeer(PeerId(raw))
        } else if url.scheme == "aorus-username", let username = url.host {
            let _ = (context.engine.peers.resolvePeerByName(name: username, referrer: nil) |> deliverOnMainQueue).start(next: { [weak self] result in
                guard case let .result(peer) = result, let peer else { return }
                self?.openPeer(peer.id)
            })
        } else {
            context.sharedContext.applicationBindings.openUrl(url.absoluteString)
        }
    }

    private func openPeer(_ peerId: PeerId) {
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)) |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self, let peer,
                  let controller = self.context.sharedContext.makePeerInfoController(context: self.context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) else { return }
            (self.navigationController as? NavigationController)?.pushViewController(controller)
        })
    }

    private func open(artifact: AorusAIArtifact, card: AorusAIArtifactCard) {
        if artifact.isExpired {
            presentError(AorusAIFormat.errorText(.artifactExpired))
            return
        }
        card.isLoading = true
        AorusAIClient.shared.downloadArtifact(artifact) { [weak self] result in
            card.isLoading = false
            switch result {
            case let .success(url):
                self?.removePreviewArtifact()
                self?.previewURL = url
                let preview = QLPreviewController()
                preview.dataSource = self
                preview.delegate = self
                self?.present(preview, animated: true)
            case let .failure(error):
                self?.presentArtifactError(error, artifact: artifact, card: card)
            }
        }
    }

    private func presentArtifactError(_ error: AorusAIClientError, artifact: AorusAIArtifact, card: AorusAIArtifactCard) {
        // A file the vault will never serve again is recorded as expired locally, so the
        // card stops offering a download it cannot deliver.
        if error == .artifactExpired || error == .artifactGone {
            markArtifactExpired(artifactId: artifact.artifactId)
        }
        let alert = UIAlertController(title: aorusAILocalized("Не удалось открыть файл", "Couldn't open file"), message: AorusAIFormat.errorText(error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        let isPermanent = error == .artifactExpired || error == .artifactGone || error == .artifactNotOwned
        if !isPermanent {
            alert.addAction(UIAlertAction(title: aorusAILocalized("Повторить", "Retry"), style: .default, handler: { [weak self, weak card] _ in
                guard let self, let card else { return }
                self.open(artifact: artifact, card: card)
            }))
        }
        present(alert, animated: true)
    }

    private func markArtifactExpired(artifactId: String) {
        var touched: [UUID] = []
        for messageIndex in conversation.messages.indices {
            for artifactIndex in conversation.messages[messageIndex].artifacts.indices
            where conversation.messages[messageIndex].artifacts[artifactIndex].artifactId == artifactId {
                guard !conversation.messages[messageIndex].artifacts[artifactIndex].isExpired else { continue }
                conversation.messages[messageIndex].artifacts[artifactIndex].expiresAt = Int64(Date().timeIntervalSince1970)
                touched.append(conversation.messages[messageIndex].id)
            }
        }
        guard !touched.isEmpty else { return }
        for id in touched {
            reloadMessage(id: id)
        }
        persist(force: true)
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: "AorusAI", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_OK, style: .default))
        present(alert, animated: true)
    }

    private func presentCopiedFeedback() {
        self.present(
            UndoOverlayController(
                presentationData: presentationData,
                content: .copy(text: aorusAILocalized("Скопировано", "Copied")),
                elevatedLayout: false,
                animateInAsReplacement: true,
                action: { _ in false }
            ),
            in: .current
        )
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        guard index == 0, let previewURL else { return NSURL(fileURLWithPath: "/dev/null") }
        return previewURL as NSURL
    }
    func previewControllerDidDismiss(_ controller: QLPreviewController) { removePreviewArtifact() }

    private func removePreviewArtifact() {
        guard let previewURL else { return }
        self.previewURL = nil
        try? FileManager.default.removeItem(at: previewURL.deletingLastPathComponent())
    }
}

private final class AorusAIComposerView: UIView {
    let textView = UITextView()
    private let container = UIView()
    private let brandView = UIView()
    private let brandIcon = UIImageView()
    private let brandLabel = UILabel()
    private let placeholder = UILabel()
    private let referenceView = UIView()
    private let referenceLabel = UILabel()
    private let referenceClose = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let dictationButton = UIButton(type: .system)
    var onSend: (() -> Void)?
    var onDismissReference: (() -> Void)?
    var onOpenPeer: ((PeerId) -> Void)?
    var onHeightChanged: (() -> Void)?
    var onDictation: (() -> Void)?
    private var theme: PresentationTheme?
    private var context: AccountContext?
    /// Mentions the controller has resolved to real peers. They are styled inside the
    /// input itself — the row of chips that used to sit above it is gone, because a
    /// resolved @username reads as a name, not as an attachment.
    var entities: [AorusAITelegramEntity] = [] {
        didSet { applyMentionStyling() }
    }

    var text: String {
        get { textView.text }
        set {
            textView.text = newValue
            placeholder.isHidden = !newValue.isEmpty
            applyMentionStyling()
        }
    }
    var reference: AorusAIReferencedMessage? {
        didSet {
            referenceView.isHidden = reference == nil
            referenceLabel.text = reference.map { "\($0.authorName ?? aorusAILocalized("Сообщение", "Message")): \($0.text)" }
        }
    }
    var isGenerating = false { didSet { refreshButton() } }
    var canSend = false { didSet { refreshButton() } }
    var isDictating = false { didSet { refreshDictationButton() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(container)
        [brandView, referenceView, dictationButton, textView, sendButton].forEach { container.addSubview($0) }
        brandView.addSubview(brandIcon)
        brandView.addSubview(brandLabel)
        referenceView.addSubview(referenceLabel)
        referenceView.addSubview(referenceClose)
        textView.addSubview(placeholder)
        brandIcon.contentMode = .scaleAspectFit
        brandIcon.image = UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        brandLabel.text = "AorusAI"
        brandLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        // §4: the brand row belongs to the active input, not to the resting composer.
        brandView.isHidden = true
        brandView.alpha = 0.0
        placeholder.text = aorusAILocalized("Сообщение AorusAI", "Message AorusAI")
        placeholder.font = .systemFont(ofSize: 16)
        textView.font = .systemFont(ofSize: 16)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 5, left: 1, bottom: 5, right: 1)
        referenceLabel.font = .systemFont(ofSize: 12)
        referenceLabel.numberOfLines = 2
        referenceClose.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        referenceClose.addTarget(self, action: #selector(closeReference), for: .touchUpInside)
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.accessibilityLabel = aorusAILocalized("Отправить", "Send")
        dictationButton.addTarget(self, action: #selector(dictate), for: .touchUpInside)
        dictationButton.accessibilityLabel = aorusAILocalized("Диктовать", "Dictate")
        referenceView.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(context: AccountContext, theme: PresentationTheme) {
        self.context = context
        self.theme = theme
        backgroundColor = theme.list.blocksBackgroundColor
        container.backgroundColor = theme.list.itemBlocksBackgroundColor
        container.layer.cornerRadius = 20
        container.layer.cornerCurve = .continuous
        container.layer.borderWidth = UIScreenPixel
        container.layer.borderColor = theme.list.itemBlocksSeparatorColor.cgColor
        textView.textColor = theme.list.itemPrimaryTextColor
        textView.tintColor = theme.list.itemAccentColor
        placeholder.textColor = theme.list.itemSecondaryTextColor
        brandIcon.tintColor = theme.list.itemAccentColor
        brandLabel.textColor = theme.list.itemAccentColor
        referenceLabel.textColor = theme.list.itemSecondaryTextColor
        referenceView.backgroundColor = theme.list.blocksBackgroundColor.withAlphaComponent(0.75)
        referenceClose.tintColor = theme.list.itemSecondaryTextColor
        sendButton.tintColor = theme.list.itemAccentColor
        applyMentionStyling()
        refreshButton()
        refreshDictationButton()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = 10
        container.frame = CGRect(x: side, y: 5, width: bounds.width - side * 2, height: bounds.height - 10)
        let brandHeight = self.brandHeight
        brandView.frame = CGRect(x: 12, y: 7, width: max(0, container.bounds.width - 24), height: brandHeight)
        brandIcon.frame = CGRect(x: 0, y: 1, width: 14, height: 14)
        brandLabel.frame = CGRect(x: 18, y: 0, width: max(0, brandView.bounds.width - 18), height: 16)
        let buttonSize: CGFloat = 38
        sendButton.frame = CGRect(x: container.bounds.width - buttonSize - 7, y: container.bounds.height - buttonSize - 6, width: buttonSize, height: buttonSize)
        dictationButton.frame = CGRect(x: 5, y: container.bounds.height - buttonSize - 6, width: buttonSize, height: buttonSize)
        let stackTop: CGFloat = brandHeight > 0 ? 7 + brandHeight + 3 : 8
        let refHeight: CGFloat = reference == nil ? 0 : 42
        referenceView.frame = CGRect(x: 10, y: stackTop, width: container.bounds.width - 20, height: refHeight)
        referenceView.layer.cornerRadius = 8
        referenceLabel.frame = CGRect(x: 9, y: 4, width: referenceView.bounds.width - 38, height: 34)
        referenceClose.frame = CGRect(x: referenceView.bounds.width - 32, y: 7, width: 28, height: 28)
        let inputTop: CGFloat = stackTop + refHeight + 1
        let inputLeft: CGFloat = dictationButton.frame.maxX + 2
        textView.frame = CGRect(x: inputLeft, y: inputTop, width: max(0, container.bounds.width - inputLeft - buttonSize - 12), height: max(0, container.bounds.height - inputTop - 6))
        placeholder.frame = CGRect(x: 5, y: 5, width: max(0, textView.bounds.width - 10), height: 24)
    }

    private var brandHeight: CGFloat { brandView.isHidden ? 0 : 16 }

    /// §4: while the keyboard is up the composer identifies the assistant. Collapsing
    /// the row again when the input goes idle keeps the resting composer plain.
    func setInputActive(_ active: Bool) {
        guard brandView.isHidden == active else { return }
        brandView.isHidden = !active
        onHeightChanged?()
        UIView.animate(withDuration: 0.18, delay: 0.0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.brandView.alpha = active ? 1.0 : 0.0
        }
    }

    func requiredHeight(width: CGFloat) -> CGFloat {
        let available = max(100, width - 20 - 38 - 38 - 20)
        let measured = textView.sizeThatFits(CGSize(width: available, height: 120)).height
        let extras = brandHeight + (reference == nil ? 0 : 42)
        return min(196, max(52, measured + 20 + extras)) + 10
    }

    func invalidateHeight() {
        placeholder.isHidden = !textView.text.isEmpty
        applyMentionStyling()
        setNeedsLayout()
    }

    private func refreshButton() {
        // A round glyph, so stopping reads as the same control as sending instead of a
        // bare square, and it stays tappable while the request is still being prepared.
        let name = isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill"
        sendButton.setImage(UIImage(systemName: name)?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 29, weight: .semibold)), for: .normal)
        sendButton.isEnabled = isGenerating || canSend
        sendButton.alpha = sendButton.isEnabled ? 1 : 0.42
        sendButton.accessibilityLabel = isGenerating ? aorusAILocalized("Остановить", "Stop") : aorusAILocalized("Отправить", "Send")
    }

    private func refreshDictationButton() {
        let name = isDictating ? "waveform.circle.fill" : "mic"
        dictationButton.setImage(UIImage(systemName: name)?.withConfiguration(UIImage.SymbolConfiguration(pointSize: isDictating ? 27 : 20, weight: .medium)), for: .normal)
        dictationButton.tintColor = isDictating ? theme?.list.itemDestructiveColor : theme?.list.itemSecondaryTextColor
        dictationButton.accessibilityLabel = isDictating ? aorusAILocalized("Остановить диктовку", "Stop dictation") : aorusAILocalized("Диктовать", "Dictate")
    }

    /// Styles every resolved mention inside the input. The text itself is untouched, so
    /// what the transport sends is still exactly what the user typed; only the run that
    /// the client has proved is a real peer is drawn in the accent colour.
    private func applyMentionStyling() {
        guard let theme else { return }
        let plain = textView.text ?? ""
        let base: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: theme.list.itemPrimaryTextColor
        ]
        textView.typingAttributes = base
        guard !plain.isEmpty else { return }
        let resolved = entities.filter { $0.peerId != nil && !$0.sourceText.isEmpty }
        guard !resolved.isEmpty else {
            if textView.attributedText.length > 0 {
                let selection = textView.selectedRange
                textView.attributedText = NSAttributedString(string: plain, attributes: base)
                textView.selectedRange = selection
            }
            return
        }
        let full = plain as NSString
        let attributed = NSMutableAttributedString(string: plain, attributes: base)
        let highlight: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: theme.list.itemAccentColor
        ]
        for entity in resolved {
            let range = NSRange(location: entity.rangeLocation, length: entity.rangeLength)
            // Offsets were taken from an earlier revision of the text, so only trust a
            // range that still holds exactly the run it was resolved from.
            guard range.location >= 0, range.length > 0, range.location + range.length <= full.length,
                  full.substring(with: range) == entity.sourceText else { continue }
            attributed.addAttributes(highlight, range: range)
        }
        let selection = textView.selectedRange
        textView.attributedText = attributed
        textView.selectedRange = selection
        textView.typingAttributes = base
    }

    @objc private func closeReference() { onDismissReference?() }
    @objc private func send() { onSend?() }
    @objc private func dictate() { onDictation?() }
}

private final class AorusAIMessageCell: UITableViewCell, UITextViewDelegate {
    private enum BodySlot {
        case text(UITextView)
        case code(AorusAICodeCard)
        case quote(AorusAIQuoteCard)
        case separator
    }

    private let contentStack = UIStackView()
    private let bubble = UIView()
    private let bodyStack = UIStackView()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let typingIndicator = AorusAITypingIndicatorView()
    private let noticeCard = AorusAINoticeCard()
    var onOpenLink: ((URL) -> Void)?
    private var bubbleWidthConstraint: NSLayoutConstraint?
    private var slots: [BodySlot] = []
    private var slotValues: [String] = []
    private var structureSignature: String?
    private var configuredMessageId: UUID?
    private var configuredTextColor: UIColor = .white
    private var configuredAccent: UIColor = .white
    private var configuredTheme: PresentationTheme?
    var onArtifact: ((AorusAIArtifact, AorusAIArtifactCard) -> Void)?
    var onCopy: (() -> Void)?
    var onRetry: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        contentStack.axis = .vertical
        contentStack.spacing = 7
        bodyStack.axis = .vertical
        bodyStack.spacing = 8
        bubble.addSubview(bodyStack)
        contentStack.addArrangedSubview(bubble)
        noticeCard.isHidden = true
        noticeCard.onRetry = { [weak self] in self?.onRetry?() }
        contentStack.addArrangedSubview(noticeCard)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.numberOfLines = 0
        contentStack.addArrangedSubview(statusLabel)
        retryButton.setTitle(aorusAILocalized("Повторить", "Retry"), for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        contentStack.addArrangedSubview(retryButton)
        contentView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            bodyStack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            bodyStack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            bodyStack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            bodyStack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            noticeCard.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        typingIndicator.setAnimating(false)
        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        slots.removeAll()
        slotValues.removeAll()
        structureSignature = nil
        configuredMessageId = nil
        onOpenLink = nil; onArtifact = nil; onCopy = nil; onRetry = nil
    }

    /// Streaming path (§27): keeps the existing view tree and only pushes the text that
    /// actually changed. Returns false when the block structure moved and the caller has
    /// to fall back to a full rebuild.
    func applyIncremental(message: AorusAIMessage, theme: PresentationTheme, canRetry: Bool) -> Bool {
        guard configuredMessageId == message.id, configuredTheme === theme else { return false }
        let resolvedEntities = message.telegramEntities.filter { $0.peerId != nil }
        let displayText = AorusAIFormat.removingResolvedEntitySources(from: message.rawText, entities: resolvedEntities)
        let blocks = AorusAIMarkdown.blocks(displayText)
        guard Self.signature(blocks: blocks, message: message, entities: resolvedEntities) == structureSignature,
              blocks.count == slots.count, blocks.count == slotValues.count else {
            return false
        }
        for index in blocks.indices {
            let value = Self.value(of: blocks[index])
            guard value != slotValues[index] else { continue }
            slotValues[index] = value
            switch (slots[index], blocks[index]) {
            case let (.text(view), .text(source)):
                view.attributedText = AorusAIMarkdown.attributed(source, color: configuredTextColor, accent: configuredAccent)
            case let (.code(card), .code(language, code)):
                card.configure(language: language, code: code, theme: theme)
            case let (.quote(card), .quote(source)):
                card.configure(text: source, theme: theme, textColor: configuredTextColor, accentOnColor: message.role == .user)
            default:
                return false
            }
        }
        statusLabel.text = message.statusLabel
        statusLabel.isHidden = message.statusLabel == nil
        retryButton.isHidden = !canRetry
        applyNotice(message: message, theme: theme, canRetry: canRetry)
        return true
    }

    private static func value(of block: AorusAIMarkdownBlock) -> String {
        switch block {
        case let .text(value): return value
        case let .code(_, code): return code
        case let .quote(value): return value
        case .separator: return ""
        }
    }

    /// True while a turn is on the wire and has produced nothing visible yet. Such a turn
    /// gets the typing indicator, so a sent message is never answered by a blank gap.
    private static func showsTyping(blocks: [AorusAIMarkdownBlock], message: AorusAIMessage) -> Bool {
        guard message.role == .assistant, message.state == .streaming else { return false }
        return blocks.isEmpty && message.artifacts.isEmpty
    }

    private static func signature(blocks: [AorusAIMarkdownBlock], message: AorusAIMessage, entities: [AorusAITelegramEntity]) -> String {
        var parts: [String] = [message.referencedMessage == nil ? "r0" : "r1"]
        parts.append(showsTyping(blocks: blocks, message: message) ? "y1" : "y0")
        parts.append("n:" + (notice(for: message)?.rawValue ?? ""))
        parts.append("e:" + entities.map { "\($0.peerId ?? 0)/\($0.displayName)" }.joined(separator: ","))
        for block in blocks {
            switch block {
            case .text: parts.append("t")
            case let .code(language, _): parts.append("c/\(language ?? "")")
            case .quote: parts.append("q")
            case .separator: parts.append("s")
            }
        }
        parts.append("a:" + message.artifacts.map { "\($0.artifactId)/\($0.isExpired ? 1 : 0)" }.joined(separator: ","))
        return parts.joined(separator: "|")
    }

    func configure(message: AorusAIMessage, context: AccountContext, theme: PresentationTheme, canRetry: Bool) {
        backgroundColor = theme.list.blocksBackgroundColor
        contentView.backgroundColor = theme.list.blocksBackgroundColor
        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        slots.removeAll()
        slotValues.removeAll()
        let isUser = message.role == .user
        contentStack.alignment = isUser ? .trailing : .leading
        bubbleWidthConstraint?.isActive = false
        // A user bubble hugs its text; an assistant turn takes the full column, so code
        // cards, tables and quotes run edge to edge instead of sitting in a narrow strip.
        let bubbleWidthConstraint = isUser
            ? bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82, constant: -12)
            : bubble.widthAnchor.constraint(equalTo: contentView.widthAnchor, constant: -24)
        bubbleWidthConstraint.isActive = true
        self.bubbleWidthConstraint = bubbleWidthConstraint
        bubble.backgroundColor = isUser ? theme.list.itemAccentColor : .clear
        bubble.layer.cornerRadius = isUser ? 16 : 0
        bubble.layer.cornerCurve = .continuous

        if let reference = message.referencedMessage {
            let referenceView = AorusAIReferenceCard()
            referenceView.configure(reference: reference, context: context, theme: theme, accentOnColor: isUser)
            referenceView.onOpenPeer = { [weak self] peerId in
                guard let url = URL(string: "aorus-peer://\(peerId.toInt64())") else { return }
                self?.onOpenLink?(url)
            }
            bodyStack.addArrangedSubview(referenceView)
        }

        let resolvedEntities = message.telegramEntities.filter { $0.peerId != nil }
        if !resolvedEntities.isEmpty {
            let entityRow = AorusAIEntityRowView()
            entityRow.configure(context: context, entities: resolvedEntities, theme: theme, accentOnColor: isUser)
            entityRow.onOpenPeer = { [weak self] peerId in
                guard let url = URL(string: "aorus-peer://\(peerId.toInt64())") else { return }
                self?.onOpenLink?(url)
            }
            bodyStack.addArrangedSubview(entityRow)
        }

        let textColor: UIColor = isUser ? .white : theme.list.itemPrimaryTextColor
        let accent: UIColor = isUser ? .white : theme.list.itemAccentColor
        configuredTextColor = textColor
        configuredAccent = accent
        configuredTheme = theme
        configuredMessageId = message.id
        let displayText = AorusAIFormat.removingResolvedEntitySources(from: message.rawText, entities: resolvedEntities)
        let blocks = AorusAIMarkdown.blocks(displayText)
        structureSignature = Self.signature(blocks: blocks, message: message, entities: resolvedEntities)
        if Self.showsTyping(blocks: blocks, message: message) {
            typingIndicator.configure(theme: theme)
            bodyStack.addArrangedSubview(typingIndicator)
            typingIndicator.setAnimating(true)
        } else {
            typingIndicator.setAnimating(false)
        }
        for block in blocks {
            slotValues.append(Self.value(of: block))
            switch block {
            case let .text(value):
                let view = UITextView()
                view.backgroundColor = .clear
                view.isEditable = false
                view.isScrollEnabled = false
                view.textContainerInset = .zero
                view.textContainer.lineFragmentPadding = 0
                view.delegate = self
                view.linkTextAttributes = [.foregroundColor: accent, .underlineStyle: 0]
                view.attributedText = AorusAIMarkdown.attributed(value, color: textColor, accent: accent)
                bodyStack.addArrangedSubview(view)
                slots.append(.text(view))
            case let .code(language, code):
                let card = AorusAICodeCard()
                card.configure(language: language, code: code, theme: theme)
                card.onCopy = { [weak self] in self?.onCopy?() }
                bodyStack.addArrangedSubview(card)
                slots.append(.code(card))
            case let .quote(value):
                let card = AorusAIQuoteCard()
                card.configure(text: value, theme: theme, textColor: textColor, accentOnColor: isUser)
                bodyStack.addArrangedSubview(card)
                slots.append(.quote(card))
            case .separator:
                let separator = UIView()
                separator.backgroundColor = isUser ? UIColor.white.withAlphaComponent(0.35) : theme.list.itemBlocksSeparatorColor
                separator.heightAnchor.constraint(equalToConstant: UIScreenPixel).isActive = true
                bodyStack.addArrangedSubview(separator)
                slots.append(.separator)
            }
        }

        for artifact in message.artifacts {
            let card = AorusAIArtifactCard()
            card.configure(artifact: artifact, theme: theme)
            card.onOpen = { [weak self, weak card] in
                guard let self, let card else { return }
                self.onArtifact?(artifact, card)
            }
            bodyStack.addArrangedSubview(card)
        }

        statusLabel.textColor = theme.list.itemSecondaryTextColor
        statusLabel.text = message.statusLabel
        statusLabel.isHidden = message.statusLabel == nil
        retryButton.tintColor = theme.list.itemAccentColor
        retryButton.isHidden = !canRetry
        applyNotice(message: message, theme: theme, canRetry: canRetry)
    }

    /// A failed or throttled turn is reported by the full-width glass card, so the plain
    /// status line and the bare Retry button step aside instead of doubling the message.
    private func applyNotice(message: AorusAIMessage, theme: PresentationTheme, canRetry: Bool) {
        guard let kind = Self.notice(for: message) else {
            noticeCard.isHidden = true
            return
        }
        noticeCard.configure(kind: kind, text: message.statusLabel ?? "", theme: theme, canRetry: canRetry)
        noticeCard.isHidden = false
        statusLabel.isHidden = true
        retryButton.isHidden = true
    }

    private static func notice(for message: AorusAIMessage) -> AorusAINoticeCard.Kind? {
        guard message.state == .failed else { return nil }
        switch message.errorCode {
        case "quota": return .quota
        case "offline": return .offline
        default: return .failure
        }
    }

    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        onOpenLink?(URL)
        return false
    }

    @objc private func retry() { onRetry?() }
}

/// Three dots that breathe while a turn is on the wire. UIKit keyframe animations only,
/// so it costs nothing and matches the rhythm of the native typing indicator.
private final class AorusAITypingIndicatorView: UIView {
    private let dots = [UIView(), UIView(), UIView()]
    private static let dotSize: CGFloat = 7.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        for dot in dots {
            dot.layer.cornerRadius = AorusAITypingIndicatorView.dotSize / 2.0
            addSubview(dot)
        }
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        widthAnchor.constraint(equalToConstant: 40).isActive = true
        isAccessibilityElement = true
        accessibilityLabel = aorusAILocalized("AorusAI отвечает", "AorusAI is replying")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = AorusAITypingIndicatorView.dotSize
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * (size + 5.0), y: floor((bounds.height - size) / 2.0), width: size, height: size)
        }
    }

    func configure(theme: PresentationTheme) {
        for dot in dots {
            dot.backgroundColor = theme.list.itemSecondaryTextColor
        }
    }

    func setAnimating(_ animating: Bool) {
        guard animating else {
            dots.forEach { $0.layer.removeAnimation(forKey: "aorusAITyping"); $0.alpha = 1.0 }
            return
        }
        guard dots[0].layer.animation(forKey: "aorusAITyping") == nil else { return }
        for (index, dot) in dots.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.3, 1.0, 0.3]
            animation.keyTimes = [0.0, 0.5, 1.0]
            animation.duration = 0.9
            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.16
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            dot.layer.add(animation, forKey: "aorusAITyping")
        }
    }
}

/// The chat header. Telegram gives a `titleView` the full width between the bar buttons
/// and expects it to centre its own content, so everything here is laid out by hand.
/// It carries the same gradient badge as the settings row plus a live status line, which
/// is what turns the screen from a plain title into a real chat header.
private final class AorusAINavigationTitleView: UIView {
    private let badge = UIView()
    private let badgeGlyph = UIImageView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let gradient = CAGradientLayer()
    private var accentColor: UIColor = .white
    private var secondaryColor: UIColor = .gray

    init(theme: PresentationTheme) {
        super.init(frame: .zero)
        gradient.colors = [UIColor(rgb: 0xA95CE3).cgColor, UIColor(rgb: 0x5B7CFA).cgColor]
        gradient.startPoint = CGPoint(x: 0.0, y: 0.0)
        gradient.endPoint = CGPoint(x: 1.0, y: 1.0)
        badge.layer.addSublayer(gradient)
        badge.layer.cornerRadius = 15
        badge.layer.cornerCurve = .continuous
        badge.layer.masksToBounds = true
        badgeGlyph.contentMode = .center
        badgeGlyph.image = UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        badge.addSubview(badgeGlyph)
        titleLabel.text = "AorusAI"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 13)
        addSubview(badge)
        addSubview(titleLabel)
        addSubview(statusLabel)
        isAccessibilityElement = true
        accessibilityLabel = "AorusAI"
        update(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(theme: PresentationTheme) {
        titleLabel.textColor = theme.rootController.navigationBar.primaryTextColor
        secondaryColor = theme.rootController.navigationBar.secondaryTextColor
        accentColor = theme.rootController.navigationBar.accentTextColor
        statusLabel.textColor = secondaryColor
    }

    /// `active` renders the line in the accent colour, the way a native header marks a
    /// peer that is typing right now.
    func setStatus(_ text: String?, active: Bool) {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        statusLabel.text = (value?.isEmpty == false) ? value : nil
        statusLabel.textColor = active ? accentColor : secondaryColor
        accessibilityValue = statusLabel.text
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let hasStatus = (statusLabel.text?.isEmpty == false)
        let badgeSize: CGFloat = 30
        let spacing: CGFloat = 9
        let titleSize = titleLabel.sizeThatFits(CGSize(width: bounds.width, height: 22))
        let statusSize = hasStatus ? statusLabel.sizeThatFits(CGSize(width: bounds.width, height: 18)) : .zero
        let textWidth = min(max(titleSize.width, statusSize.width), max(0, bounds.width - badgeSize - spacing))
        let totalWidth = badgeSize + spacing + textWidth
        let originX = floor((bounds.width - totalWidth) / 2.0)
        let centerY = bounds.height / 2.0
        badge.frame = CGRect(x: originX, y: floor(centerY - badgeSize / 2.0), width: badgeSize, height: badgeSize)
        gradient.frame = badge.bounds
        badgeGlyph.frame = badge.bounds
        let textX = originX + badgeSize + spacing
        if hasStatus {
            titleLabel.frame = CGRect(x: textX, y: floor(centerY - 18.0), width: textWidth, height: 20)
            statusLabel.frame = CGRect(x: textX, y: floor(centerY + 1.0), width: textWidth, height: 16)
        } else {
            titleLabel.frame = CGRect(x: textX, y: floor(centerY - 11.0), width: textWidth, height: 22)
            statusLabel.frame = .zero
        }
    }
}

/// The prominent, full-width card a failed or throttled turn gets instead of a 12pt grey
/// line. Native glass: the blocks background, a hairline separator border, no tint fills.
private final class AorusAINoticeCard: UIView {
    enum Kind: String {
        case quota
        case offline
        case failure

        var iconName: String {
            switch self {
            case .quota: return "hourglass"
            case .offline: return "wifi.slash"
            case .failure: return "exclamationmark.triangle"
            }
        }

        var title: String {
            switch self {
            case .quota: return aorusAILocalized("Лимит запросов исчерпан", "Request limit reached")
            case .offline: return aorusAILocalized("Нет соединения", "No connection")
            case .failure: return aorusAILocalized("Не удалось получить ответ", "Could not get a reply")
            }
        }
    }

    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var retryHeight: NSLayoutConstraint?
    var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        icon.contentMode = .center
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.numberOfLines = 2
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.numberOfLines = 0
        retryButton.setTitle(aorusAILocalized("Повторить", "Retry"), for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        retryButton.contentHorizontalAlignment = .leading
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        [icon, titleLabel, bodyLabel, retryButton].forEach { addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        let retryHeight = retryButton.heightAnchor.constraint(equalToConstant: 28)
        self.retryHeight = retryHeight
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            retryButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            retryButton.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 4),
            retryButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            retryHeight
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(kind: Kind, text: String, theme: PresentationTheme, canRetry: Bool) {
        backgroundColor = theme.list.itemBlocksBackgroundColor
        layer.borderWidth = UIScreenPixel
        layer.borderColor = theme.list.itemBlocksSeparatorColor.cgColor
        let accent = kind == .quota ? theme.list.itemAccentColor : theme.list.itemDestructiveColor
        icon.image = UIImage(systemName: kind.iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))?
            .withTintColor(accent, renderingMode: .alwaysOriginal)
        titleLabel.textColor = theme.list.itemPrimaryTextColor
        titleLabel.text = kind.title
        bodyLabel.textColor = theme.list.itemSecondaryTextColor
        let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        bodyLabel.text = detail.isEmpty ? nil : detail
        bodyLabel.isHidden = detail.isEmpty
        retryButton.tintColor = theme.list.itemAccentColor
        retryButton.isHidden = !canRetry
        retryHeight?.constant = canRetry ? 28 : 0
        accessibilityLabel = kind.title + (detail.isEmpty ? "" : ". " + detail)
    }

    @objc private func retry() { onRetry?() }
}

private final class AorusAIEntityRowView: UIView {
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    var onOpenPeer: ((PeerId) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 6
        addSubview(scrollView)
        scrollView.addSubview(stackView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(context: AccountContext, entities: [AorusAITelegramEntity], theme: PresentationTheme, accentOnColor: Bool) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for entity in entities {
            let chip = AorusAIEntityChipView()
            chip.configure(context: context, entity: entity, theme: theme, accentOnColor: accentOnColor)
            chip.onOpenPeer = { [weak self] peerId in self?.onOpenPeer?(peerId) }
            stackView.addArrangedSubview(chip)
        }
    }
}

private final class AorusAIQuoteCard: UIView {
    private let line = UIView()
    private let textView = UITextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        addSubview(line)
        addSubview(textView)
        line.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 3),
            textView.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: 9),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, theme: PresentationTheme, textColor: UIColor, accentOnColor: Bool) {
        let accent = accentOnColor ? UIColor.white.withAlphaComponent(0.8) : theme.list.itemAccentColor
        line.backgroundColor = accent
        textView.linkTextAttributes = [.foregroundColor: accent, .underlineStyle: 0]
        textView.attributedText = AorusAIMarkdown.attributed(text, color: textColor, accent: accent)
    }
}

private final class AorusAIEntityChipView: UIControl {
    private static let avatarSize: CGFloat = 22
    private let avatarNode = AvatarNode(font: .systemFont(ofSize: 11, weight: .semibold))
    private let titleLabel = UILabel()
    private var disposable: Disposable?
    private var peerId: PeerId?
    private var nameStrings: PresentationStrings?
    private var nameOrder: PresentationPersonNameOrder?
    var onOpenPeer: ((PeerId) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 13
        layer.cornerCurve = .continuous
        addSubview(avatarNode.view)
        addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The avatar is laid out by hand on purpose: `AvatarNode` only redraws its
        // contents from its own `frame` setter, and Auto Layout writes straight to the
        // backing view — which is why the chip used to show an empty circle.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3 + AorusAIEntityChipView.avatarSize + 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        addTarget(self, action: #selector(openPeer), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { disposable?.dispose() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = AorusAIEntityChipView.avatarSize
        avatarNode.frame = CGRect(x: 3, y: floor((bounds.height - size) / 2.0), width: size, height: size)
    }

    func configure(context: AccountContext, entity: AorusAITelegramEntity, theme: PresentationTheme, accentOnColor: Bool) {
        disposable?.dispose()
        let namePresentationData = context.sharedContext.currentPresentationData.with { $0 }
        nameStrings = namePresentationData.strings
        nameOrder = namePresentationData.nameDisplayOrder
        let accent = accentOnColor ? UIColor.white : theme.list.itemAccentColor
        backgroundColor = accent.withAlphaComponent(accentOnColor ? 0.16 : 0.12)
        titleLabel.textColor = accent
        titleLabel.text = entity.displayName
        accessibilityLabel = aorusAILocalized("Профиль ", "Profile ") + entity.displayName
        // No ring around the avatar: the placeholder Telegram draws is already a round
        // gradient, and an extra border is exactly the kind of outline the design bans.
        avatarNode.view.layer.borderWidth = 0.0
        // A peer that is not resolved yet still gets Telegram's own gradient letter
        // placeholder instead of an empty hole, so the chip never reads as broken.
        avatarNode.setCustomLetters(AorusAIEntityChipView.letters(for: entity.displayName))
        setNeedsLayout()

        if let rawPeerId = entity.peerId {
            let peerId = PeerId(rawPeerId)
            self.peerId = peerId
            disposable = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)) |> deliverOnMainQueue).start(next: { [weak self] peer in
                guard let self else { return }
                self.apply(peer: peer, context: context, theme: theme)
            })
        } else if let username = entity.username {
            disposable = (context.engine.peers.resolvePeerByName(name: username, referrer: nil) |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self, case let .result(peer) = result, let peer else { return }
                self.peerId = peer.id
                self.apply(peer: peer, context: context, theme: theme)
            })
        }
    }

    private func displayName(of peer: EnginePeer) -> String {
        guard let nameStrings, let nameOrder else { return peer.compactDisplayTitle }
        return peer.displayTitle(strings: nameStrings, displayOrder: nameOrder)
    }

    /// The same one- or two-letter monogram Telegram uses, taken from the name the
    /// client already has (`@durov` → "D") so the placeholder is never blank.
    private static func letters(for name: String) -> [String] {
        let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: "@ \n\t"))
        let words = cleaned.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? ["#"] : letters
    }

    private func apply(peer: EnginePeer?, context: AccountContext, theme: PresentationTheme) {
        // A peer the client could not fetch keeps the monogram: passing `nil` to `setPeer`
        // would wipe it and bring the empty circle back.
        guard let peer = peer else { return }
        let size = CGSize(width: AorusAIEntityChipView.avatarSize, height: AorusAIEntityChipView.avatarSize)
        avatarNode.setPeer(context: context, theme: theme, peer: peer, clipStyle: .round, synchronousLoad: false, displayDimensions: size)
        // `setPeer` only measures what the node was last told its size is, so a chip that
        // resolves its peer before the first layout pass needs the size restated.
        if avatarNode.bounds.width > 0.0 {
            avatarNode.updateSize(size: avatarNode.bounds.size)
        }
        let name = displayName(of: peer)
        titleLabel.text = name
        accessibilityLabel = aorusAILocalized("Профиль ", "Profile ") + name
    }

    @objc private func openPeer() {
        guard let peerId else { return }
        onOpenPeer?(peerId)
    }
}

private final class AorusAIReferenceCard: UIView {
    private let line = UIView()
    private let label = UILabel()
    private let entityContainer = UIView()
    private var entityChip: AorusAIEntityChipView?
    /// Toggled instead of re-created: a fresh 0-height constraint on every `configure`
    /// would stack up and permanently collapse the author chip.
    private var entityCollapse: NSLayoutConstraint?
    var onOpenPeer: ((PeerId) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 3
        label.font = .systemFont(ofSize: 13)
        addSubview(line); addSubview(entityContainer); addSubview(label)
        line.translatesAutoresizingMaskIntoConstraints = false; entityContainer.translatesAutoresizingMaskIntoConstraints = false; label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.topAnchor.constraint(equalTo: topAnchor), line.bottomAnchor.constraint(equalTo: bottomAnchor), line.widthAnchor.constraint(equalToConstant: 3),
            entityContainer.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: 8), entityContainer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor), entityContainer.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: trailingAnchor), label.topAnchor.constraint(equalTo: entityContainer.bottomAnchor, constant: 3), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(reference: AorusAIReferencedMessage, context: AccountContext, theme: PresentationTheme, accentOnColor: Bool) {
        entityChip?.removeFromSuperview()
        entityChip = nil
        if entityCollapse == nil {
            let collapse = entityContainer.heightAnchor.constraint(equalToConstant: 0)
            collapse.priority = .required
            entityCollapse = collapse
        }
        line.backgroundColor = accentOnColor ? UIColor.white.withAlphaComponent(0.75) : theme.list.itemAccentColor
        label.textColor = accentOnColor ? UIColor.white.withAlphaComponent(0.88) : theme.list.itemSecondaryTextColor
        label.text = reference.text
        if let peerId = reference.authorPeerId {
            let name = reference.authorName ?? aorusAILocalized("Профиль", "Profile")
            let entity = AorusAITelegramEntity(peerId: peerId, username: nil, displayName: name, sourceText: name, rangeLocation: 0, rangeLength: 0)
            let chip = AorusAIEntityChipView()
            chip.configure(context: context, entity: entity, theme: theme, accentOnColor: accentOnColor)
            chip.onOpenPeer = { [weak self] peerId in self?.onOpenPeer?(peerId) }
            entityContainer.addSubview(chip)
            chip.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                chip.leadingAnchor.constraint(equalTo: entityContainer.leadingAnchor),
                chip.trailingAnchor.constraint(equalTo: entityContainer.trailingAnchor),
                chip.topAnchor.constraint(equalTo: entityContainer.topAnchor),
                chip.bottomAnchor.constraint(equalTo: entityContainer.bottomAnchor)
            ])
            entityChip = chip
            entityCollapse?.isActive = false
        } else {
            let author = reference.authorName ?? aorusAILocalized("Сообщение", "Message")
            label.text = author + "\n" + reference.text
            entityCollapse?.isActive = true
        }
    }
}

private final class AorusAICodeCard: UIView {
    private let languageLabel = UILabel()
    private let scrollView = UIScrollView()
    private let codeView = UITextView()
    private let copyButton = UIButton(type: .system)
    private var code = ""
    private var codeWidthConstraint: NSLayoutConstraint?
    var onCopy: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10; layer.cornerCurve = .continuous
        languageLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        codeView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        // The text view never scrolls itself: it is laid out at its intrinsic width
        // inside a horizontal scroll view so long lines can be reached by swiping
        // instead of being wrapped or clipped.
        codeView.isEditable = false
        codeView.isScrollEnabled = false
        codeView.isSelectable = true
        codeView.backgroundColor = .clear
        codeView.textContainerInset = .zero
        codeView.textContainer.lineFragmentPadding = 0
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        copyButton.setTitle(aorusAILocalized("Скопировать", "Copy"), for: .normal)
        copyButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        copyButton.accessibilityLabel = aorusAILocalized("Скопировать код", "Copy code")
        copyButton.addTarget(self, action: #selector(copyCode), for: .touchUpInside)
        [languageLabel, scrollView, copyButton].forEach { addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        scrollView.addSubview(codeView)
        codeView.translatesAutoresizingMaskIntoConstraints = false
        let codeWidth = codeView.widthAnchor.constraint(equalToConstant: 0)
        codeWidth.isActive = true
        codeWidthConstraint = codeWidth
        NSLayoutConstraint.activate([
            languageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), languageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            copyButton.leadingAnchor.constraint(greaterThanOrEqualTo: languageLabel.trailingAnchor, constant: 8),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), copyButton.centerYAnchor.constraint(equalTo: languageLabel.centerYAnchor), copyButton.heightAnchor.constraint(equalToConstant: 26),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), scrollView.topAnchor.constraint(equalTo: languageLabel.bottomAnchor, constant: 6), scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            codeView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            codeView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            codeView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            codeView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            scrollView.heightAnchor.constraint(equalTo: codeView.heightAnchor)
        ])
        // A code card fills the whole bubble, so a minimum width only matters inside a
        // narrow user bubble — where it must give way instead of breaking layout.
        let minimumWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 210)
        minimumWidth.priority = .defaultHigh
        minimumWidth.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(language: String?, code: String, theme: PresentationTheme) {
        self.code = code
        backgroundColor = theme.list.itemBlocksBackgroundColor
        layer.borderWidth = UIScreenPixel; layer.borderColor = theme.list.itemBlocksSeparatorColor.cgColor
        languageLabel.text = language.flatMap { $0.isEmpty ? nil : $0.uppercased() } ?? "CODE"
        languageLabel.textColor = theme.list.itemSecondaryTextColor
        codeView.textColor = theme.list.itemPrimaryTextColor
        codeView.text = code
        // Lay the code out at its natural width so nothing wraps; the scroll view
        // takes over when that width exceeds the card.
        let natural = codeView.sizeThatFits(CGSize(width: 10_000, height: 10_000))
        codeWidthConstraint?.constant = max(1, ceil(natural.width))
        copyButton.tintColor = theme.list.itemAccentColor
    }
    @objc private func copyCode() {
        UIPasteboard.general.string = code
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copyButton.setTitle(aorusAILocalized("Скопировано", "Copied"), for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copyButton.setTitle(aorusAILocalized("Скопировать", "Copy"), for: .normal)
        }
        onCopy?()
    }
}

private final class AorusAIArtifactCard: UIControl {
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    var onOpen: (() -> Void)?
    var isLoading = false {
        didSet {
            isUserInteractionEnabled = !isLoading
            icon.isHidden = isLoading
            if isLoading { activity.startAnimating() } else { activity.stopAnimating() }
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10; layer.cornerCurve = .continuous
        icon.contentMode = .scaleAspectFit
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        [icon, activity, titleLabel, detailLabel].forEach { addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 58), widthAnchor.constraint(greaterThanOrEqualToConstant: 235),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            activity.centerXAnchor.constraint(equalTo: icon.centerXAnchor), activity.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor), detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3)
        ])
        addTarget(self, action: #selector(open), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(artifact: AorusAIArtifact, theme: PresentationTheme) {
        backgroundColor = theme.list.itemBlocksBackgroundColor
        layer.borderWidth = UIScreenPixel; layer.borderColor = theme.list.itemBlocksSeparatorColor.cgColor
        // Icon and detail line come from the shared artifact flow, so the card, the
        // download path and the tests all agree on one description of a file.
        icon.image = UIImage(systemName: artifact.isExpired ? "clock.badge.xmark" : AorusAIArtifactFlow.iconName(for: artifact))
        icon.tintColor = artifact.isExpired ? theme.list.itemSecondaryTextColor : theme.list.itemAccentColor
        activity.color = theme.list.itemAccentColor
        titleLabel.textColor = theme.list.itemPrimaryTextColor; titleLabel.text = artifact.filename
        detailLabel.textColor = theme.list.itemSecondaryTextColor
        detailLabel.text = artifact.isExpired
            ? aorusAILocalized("Срок хранения файла истёк", "The file is no longer stored")
            : AorusAIArtifactFlow.cardDetail(for: artifact)
        isAccessibilityElement = true
        accessibilityTraits = artifact.isExpired ? .staticText : .button
        accessibilityLabel = artifact.filename
        accessibilityValue = detailLabel.text
        accessibilityHint = artifact.isExpired ? nil : aorusAILocalized("Открывает файл", "Opens the file")
    }
    @objc private func open() { onOpen?() }
}

private enum AorusAIMarkdownBlock {
    case text(String)
    case code(String?, String)
    case quote(String)
    case separator
}

private enum AorusAIMarkdown {
    static func blocks(_ source: String) -> [AorusAIMarkdownBlock] {
        var result: [AorusAIMarkdownBlock] = []
        guard source.contains("```") else {
            appendTextBlocks(source, to: &result)
            return result
        }
        var rest = source[...]
        while let start = rest.range(of: "```") {
            let prefix = String(rest[..<start.lowerBound])
            appendTextBlocks(prefix, to: &result)
            let afterFence = rest[start.upperBound...]
            guard let end = afterFence.range(of: "```") else {
                appendTextBlocks(String(rest[start.lowerBound...]), to: &result)
                return result
            }
            let payload = String(afterFence[..<end.lowerBound])
            let split = payload.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let language = split.count > 1 ? String(split[0]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let code = split.count > 1 ? String(split[1]) : payload
            result.append(.code(language, code))
            rest = afterFence[end.upperBound...]
        }
        appendTextBlocks(String(rest), to: &result)
        return result
    }

    private static func appendTextBlocks(_ source: String, to result: inout [AorusAIMarkdownBlock]) {
        guard !source.isEmpty else { return }
        var plain: [String] = []
        var quote: [String] = []
        func flushPlain() {
            guard !plain.isEmpty else { return }
            result.append(.text(plain.joined(separator: "\n")))
            plain.removeAll(keepingCapacity: true)
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            result.append(.quote(quote.joined(separator: "\n")))
            quote.removeAll(keepingCapacity: true)
        }
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^([-*_])(?:\s*\1){2,}$"#, options: .regularExpression) != nil {
                flushQuote()
                flushPlain()
                result.append(.separator)
            } else if trimmed.hasPrefix(">") {
                flushPlain()
                let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                quote.append(content)
            } else {
                flushQuote()
                plain.append(line)
            }
        }
        flushQuote()
        flushPlain()
    }

    static func attributed(_ source: String, color: UIColor, accent: UIColor) -> NSAttributedString {
        let normalized = normalizeLists(source)
        let output = NSMutableAttributedString(string: normalized, attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: color])
        applyMarkdownLinks(in: output, accent: accent)
        apply(pattern: #"\*\*(.+?)\*\*"#, in: output, font: .systemFont(ofSize: 16, weight: .semibold))
        apply(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, in: output, font: .italicSystemFont(ofSize: 16))
        apply(pattern: #"(?<!\w)_([^_\n]+)_(?!\w)"#, in: output, font: .italicSystemFont(ofSize: 16))
        applyInlineCode(in: output, backgroundColor: accent.withAlphaComponent(0.12))
        applyHeadings(in: output)
        applyLinks(in: output, accent: accent)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2
        output.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: output.length))
        return output
    }

    private static func normalizeLists(_ source: String) -> String {
        return source.components(separatedBy: .newlines).map { line in
            guard let regex = try? NSRegularExpression(pattern: #"^(\s*)[-*+]\s+(.+)$"#),
                  let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
                return line
            }
            let nsLine = line as NSString
            return nsLine.substring(with: match.range(at: 1)) + "• " + nsLine.substring(with: match.range(at: 2))
        }.joined(separator: "\n")
    }

    private static func applyMarkdownLinks(in value: NSMutableAttributedString, accent: UIColor) {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((https?://[^\s)]+)\)"#, options: [.caseInsensitive]) else { return }
        for match in regex.matches(in: value.string, range: NSRange(location: 0, length: value.length)).reversed() {
            let title = (value.string as NSString).substring(with: match.range(at: 1))
            let target = (value.string as NSString).substring(with: match.range(at: 2))
            guard let externalURL = URL(string: target) else { continue }
            let url: URL
            if externalURL.host?.lowercased() == "t.me",
               let username = externalURL.path.split(separator: "/").first.map(String.init),
               username.range(of: #"^[A-Za-z0-9_]{5,32}$"#, options: .regularExpression) != nil,
               let internalURL = URL(string: "aorus-username://\(username)") {
                url = internalURL
            } else {
                url = externalURL
            }
            value.replaceCharacters(in: match.range, with: title)
            value.addAttributes([.link: url, .foregroundColor: accent], range: NSRange(location: match.range.location, length: (title as NSString).length))
        }
    }

    private static func apply(pattern: String, in value: NSMutableAttributedString, font: UIFont) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for match in regex.matches(in: value.string, range: NSRange(location: 0, length: value.length)).reversed() {
            let inner = match.range(at: 1)
            let text = (value.string as NSString).substring(with: inner)
            value.replaceCharacters(in: match.range, with: text)
            value.addAttribute(.font, value: font, range: NSRange(location: match.range.location, length: (text as NSString).length))
        }
    }

    private static func applyInlineCode(in value: NSMutableAttributedString, backgroundColor: UIColor) {
        guard let regex = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#) else { return }
        for match in regex.matches(in: value.string, range: NSRange(location: 0, length: value.length)).reversed() {
            let text = (value.string as NSString).substring(with: match.range(at: 1))
            value.replaceCharacters(in: match.range, with: text)
            value.addAttributes([
                .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                .backgroundColor: backgroundColor
            ], range: NSRange(location: match.range.location, length: (text as NSString).length))
        }
    }

    private static func applyHeadings(in value: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^(#{1,3})\s+(.+)$"#) else { return }
        for match in regex.matches(in: value.string, range: NSRange(location: 0, length: value.length)).reversed() {
            let text = (value.string as NSString).substring(with: match.range(at: 2))
            let level = match.range(at: 1).length
            value.replaceCharacters(in: match.range, with: text)
            value.addAttribute(.font, value: UIFont.systemFont(ofSize: level == 1 ? 22 : (level == 2 ? 19 : 17), weight: .bold), range: NSRange(location: match.range.location, length: (text as NSString).length))
        }
    }

    private static func applyLinks(in value: NSMutableAttributedString, accent: UIColor) {
        // Apply general links first, then Telegram-specific links so t.me never
        // gets overwritten with an external Safari destination.
        let patterns: [(String, (String) -> URL?)] = [
            (#"https?://[^\s<>]+"#, { URL(string: $0) }),
            (#"(?<![\w@])@([A-Za-z0-9_]{5,32})"#, { URL(string: "aorus-username://\($0)") }),
            (#"https?://t\.me/([A-Za-z0-9_]{5,32})(?:/\d+)?"#, { URL(string: "aorus-username://\($0)") })
        ]
        for item in patterns {
            guard let regex = try? NSRegularExpression(pattern: item.0, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: value.string, range: NSRange(location: 0, length: value.length)) {
                let capture = match.numberOfRanges > 1 ? (value.string as NSString).substring(with: match.range(at: 1)) : (value.string as NSString).substring(with: match.range)
                if let url = item.1(capture) {
                    value.addAttributes([.link: url, .foregroundColor: accent], range: match.range)
                }
            }
        }
    }
}

private enum AorusAIFormat {
    static func title(from text: String) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(54))
    }
    /// §2: explicit wording instead of `RelativeDateTimeFormatter`, whose `.short` style
    /// produces abbreviations that do not match the mockup ("5 мин." vs "5 мин. назад").
    static func relativeDate(_ date: Date) -> String {
        let now = Date()
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 {
            return aorusAILocalized("только что", "just now")
        }
        let calendar = Calendar.current
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return aorusAILocalized("\(minutes) мин. назад", minutes == 1 ? "1 min ago" : "\(minutes) min ago")
        }
        let hours = Int(seconds / 3600)
        if hours < 24, calendar.isDateInToday(date) {
            if hours == 1 {
                return aorusAILocalized("час назад", "an hour ago")
            }
            return aorusAILocalized("\(hours) ч. назад", "\(hours) h ago")
        }
        if calendar.isDateInYesterday(date) {
            return aorusAILocalized("вчера", "yesterday")
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days >= 1 && days < 7 {
            return aorusAILocalized("\(days) дн. назад", days == 1 ? "1 day ago" : "\(days) days ago")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    /// §14: quota wording built only from backend metadata. Never invents a reset time.
    static func quotaText(_ quota: AorusAIQuota) -> String {
        let title = aorusAILocalized("Лимит AorusAI исчерпан", "AorusAI limit reached")
        guard let date = quota.resetAt else {
            if let label = quota.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                return title + "\n" + String(label.prefix(160))
            }
            return title
        }
        let detail: String
        if quota.isRelative {
            let seconds = max(0, date.timeIntervalSince(Date()))
            if seconds < 60 {
                detail = aorusAILocalized("Обновится через минуту.", "Resets in a minute.")
            } else if seconds < 3600 {
                let minutes = Int(seconds / 60)
                detail = aorusAILocalized("Обновится через \(minutes) мин.", "Resets in \(minutes) min.")
            } else {
                let hours = Int(seconds / 3600)
                detail = aorusAILocalized("Обновится через \(hours) ч.", "Resets in \(hours) h.")
            }
        } else {
            let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            if Calendar.current.isDateInToday(date) {
                detail = aorusAILocalized("Обновится сегодня в \(time).", "Resets today at \(time).")
            } else if Calendar.current.isDateInTomorrow(date) {
                detail = aorusAILocalized("Обновится завтра в \(time).", "Resets tomorrow at \(time).")
            } else {
                let day = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
                detail = aorusAILocalized("Обновится \(day).", "Resets \(day).")
            }
        }
        return title + "\n" + detail
    }
    static func entities(in text: String) -> [AorusAITelegramEntity] {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let patterns = [
            #"(?<![\w@])@([A-Za-z0-9_]{5,32})"#,
            #"(?:(?:https?://)?t\.me/)([A-Za-z0-9_]{5,32})(?:/\d+)?"#
        ]
        var entities: [AorusAITelegramEntity] = []
        var occupied: [NSRange] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: fullRange) {
                guard match.numberOfRanges > 1, !occupied.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                let username = source.substring(with: match.range(at: 1))
                entities.append(AorusAITelegramEntity(peerId: nil, username: username, displayName: username, sourceText: source.substring(with: match.range), rangeLocation: match.range.location, rangeLength: match.range.length))
                occupied.append(match.range)
            }
        }
        return entities.sorted { $0.rangeLocation < $1.rangeLocation }
    }
    static func removingResolvedEntitySources(from text: String, entities: [AorusAITelegramEntity]) -> String {
        let mutable = NSMutableString(string: text)
        for entity in entities.sorted(by: { $0.rangeLocation > $1.rangeLocation }) {
            let range = NSRange(location: entity.rangeLocation, length: entity.rangeLength)
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= mutable.length else { continue }
            mutable.replaceCharacters(in: range, with: "")
        }
        return mutable.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func safeStatus(_ value: String, progress: Double? = nil) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = String(clean.prefix(160))
        guard let progress, progress.isFinite else { return label }
        let normalized = progress > 1.0 ? progress / 100.0 : progress
        let percentage = Int((min(1.0, max(0.0, normalized)) * 100.0).rounded())
        return label.isEmpty ? "\(percentage)%" : "\(label) · \(percentage)%"
    }
    static func safeErrorCode(_ error: AorusAIClientError) -> String {
        switch error {
        case .notProvisioned: return "not_provisioned"
        case .offline: return "offline"
        case .timeout: return "timeout"
        case .authorization: return "authorization"
        case .quota: return "quota"
        case .serverUnavailable: return "server_unavailable"
        case .malformedResponse: return "malformed_response"
        case .artifactExpired: return "artifact_expired"
        case .artifactNotOwned: return "artifact_not_owned"
        case .artifactGone: return "artifact_gone"
        case .artifactDownloadFailed: return "artifact_download_failed"
        case .cancelled: return "cancelled"
        case .http: return "http"
        }
    }
    static func fileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter(); formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, size))
    }
    static func errorText(_ error: AorusAIClientError) -> String {
        switch error {
        case .notProvisioned: return aorusAILocalized("AorusAI недоступен в этой сборке", "AorusAI is unavailable in this build")
        case .offline: return aorusAILocalized("Нет подключения к сети", "No network connection")
        case .timeout: return aorusAILocalized("Сервер отвечает слишком долго", "The server took too long to respond")
        case .authorization: return aorusAILocalized("Не удалось подтвердить доступ", "Access could not be verified")
        case let .quota(quota): return quotaText(quota)
        case .serverUnavailable: return aorusAILocalized("AorusAI временно недоступен", "AorusAI is temporarily unavailable")
        case .malformedResponse: return aorusAILocalized("Получен некорректный ответ", "Invalid response received")
        case .artifactExpired: return aorusAILocalized("Срок ссылки на файл истёк. Попросите создать файл снова.", "The file link expired. Ask AorusAI to create it again.")
        case .artifactNotOwned: return aorusAILocalized("Файл недоступен для этого устройства", "This file is not available for this device")
        case .artifactGone: return aorusAILocalized("Файл больше недоступен", "The file is no longer available")
        case .artifactDownloadFailed: return aorusAILocalized("Не удалось скачать файл", "The file could not be downloaded")
        case .cancelled: return aorusAILocalized("Остановлено", "Stopped")
        case .http: return aorusAILocalized("Не удалось выполнить запрос. Попробуйте ещё раз.", "The request could not be completed. Please try again.")
        }
    }
}
