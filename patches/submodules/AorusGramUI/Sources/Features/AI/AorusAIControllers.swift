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

/// Presents a UIKit controller over a navigation controller.
///
/// `NavigationController.present(_:animated:completion:)` is `preconditionFailure()` in
/// Display: Telegram routes UIKit modals through the window's root controller, and its
/// own `ViewController.present(_:animated:)` does exactly that. Calling `present` on the
/// navigation controller itself therefore traps, so every alert raised from a menu
/// action — which only has the navigation controller to hand — has to go through here.
private func aorusAIPresent(_ controller: UIViewController, from navigationController: NavigationController) {
    let presenter: UIViewController?
    if let top = navigationController.topViewController as? ViewController {
        presenter = top
    } else {
        presenter = navigationController.view.window?.rootViewController
    }
    guard let presenter else { return }
    if let alert = controller as? UIAlertController {
        aorusAIPresentActionSheet(alert, from: presenter)
    } else {
        presenter.present(controller, animated: true)
    }
}

public func aorusAIConversationListController(context: AccountContext) -> ViewController {
    return AorusAIConversationListController(context: context)
}

public func aorusAIMessageMenuTitle() -> String {
    return aorusAILocalized("ИИ-компаньон", "AI Companion")
}

/// Bundle image for the AorusAI row in the message context menu.
///
/// `Chat/Input/Text/InputAIIcon` is a 24×24 template asset that already ships with
/// the app, so the row is tinted and sized exactly like every native row instead of
/// carrying an SF Symbol that a context menu renders in its own black.
public func aorusAIMessageMenuIconName() -> String {
    return "Chat/Input/Text/InputAIIcon"
}

/// Resolves the display name of a message author, or nil when there is none.
///
/// The action sheet puts it in its subtitle and a started conversation quotes the
/// message under that name; neither may show a debug description of a peer, so the
/// lookup lives in one place.
func aorusAIResolveAuthorName(context: AccountContext, authorPeerId: Int64?, completion: @escaping (String?) -> Void) {
    guard let authorPeerId else {
        completion(nil)
        return
    }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    var delivered = false
    let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: PeerId(authorPeerId)))
    |> deliverOnMainQueue).start(next: { peer in
        guard !delivered else { return }
        delivered = true
        completion(peer?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder))
    })
}

enum AorusAIMessageMenu {
    static let analyzeChatId = "chat.analyze"
    static let newChatId = "chat.new"
    static let translateId = "text.translate"
    static let toneId = "tone.change"

    struct Item {
        var id: String
        var title: String
        var icon: String
        var prompt: String
        /// Right-aligned detail in the sheet: a language, a count of variants.
        var hint: String?
        /// A row with children opens another level of the sheet instead of running.
        var children: [Item]

        init(id: String, title: String, icon: String, prompt: String, hint: String? = nil, children: [Item] = []) {
            self.id = id
            self.title = title
            self.icon = icon
            self.prompt = prompt
            self.hint = hint
            self.children = children
        }
    }

    /// A titled group is one of the four sections. In the native context menu the title
    /// is a `SectionTitleContextItem`-shaped header, which is also the group separator.
    struct Group {
        var title: String?
        var icon: String
        var items: [Item]
    }

    /// Languages offered by "Перевести". The interface language is moved to the front,
    /// so the row's hint and the first option always agree with the app.
    private static let translationLanguages: [(code: String, name: String)] = [
        ("ru", "Русский"),
        ("en", "English"),
        ("uk", "Українська"),
        ("es", "Español"),
        ("de", "Deutsch"),
        ("fr", "Français"),
        ("it", "Italiano"),
        ("pt", "Português"),
        ("tr", "Türkçe"),
        ("pl", "Polski"),
        ("ar", "العربية"),
        ("zh", "中文"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("kk", "Қазақша"),
        ("uz", "Oʻzbekcha")
    ]

    private static func currentLanguageName(for languageCode: String) -> String {
        let base = String(languageCode.lowercased().prefix(2))
        return translationLanguages.first(where: { $0.code == base })?.name ?? "English"
    }

    private static func translationLeaf(code: String) -> Item? {
        guard let language = translationLanguages.first(where: { $0.code == code }) else { return nil }
        return Item(
            id: "\(translateId).\(language.code)",
            title: language.name,
            icon: "Chat/Context Menu/Translate",
            prompt: aorusAILocalized(
                "Переведи это сообщение на язык: \(language.name). Дай только перевод.",
                "Translate this message into \(language.name). Reply with the translation only."
            )
        )
    }

    private static func translationItems(for languageCode: String) -> [Item] {
        let base = String(languageCode.lowercased().prefix(2))
        var groups: [(id: String, title: String, codes: [String])] = [
            ("popular", aorusAILocalized("Основные", "Popular"), ["ru", "en", "uk"]),
            ("europe", aorusAILocalized("Европа", "Europe"), ["es", "de", "fr", "it", "pt", "pl"]),
            ("eurasia", aorusAILocalized("Евразия", "Eurasia"), ["tr", "ar", "kk", "uz"]),
            ("eastAsia", aorusAILocalized("Восточная Азия", "East Asia"), ["zh", "ja", "ko"])
        ]
        // Put the group containing the interface language first without making any
        // individual level taller. Every resulting native context-menu page has at most
        // eight rows including its back row and title band.
        if let index = groups.firstIndex(where: { $0.codes.contains(base) }), index != 0 {
            let current = groups.remove(at: index)
            groups.insert(current, at: 0)
        }
        return groups.map { group in
            let children = group.codes.compactMap { translationLeaf(code: $0) }
            return Item(
                id: "\(translateId).group.\(group.id)",
                title: group.title,
                icon: "Chat/Context Menu/Translate",
                prompt: "",
                hint: aorusAILocalized("\(children.count) языков", "\(children.count) languages"),
                children: children
            )
        }
    }

    private static var toneItems: [Item] {
        return [
            Item(id: "tone.formal", title: aorusAILocalized("Официальнее", "More formal"), icon: "Chat/Context Menu/FormatQuote", prompt: aorusAILocalized("Сделай это сообщение более официальным", "Make this message more formal")),
            Item(id: "tone.polite", title: aorusAILocalized("Вежливее", "More polite"), icon: "Chat/Context Menu/ThumbsUp", prompt: aorusAILocalized("Сделай это сообщение вежливее", "Make this message more polite")),
            Item(id: "tone.confident", title: aorusAILocalized("Увереннее", "More confident"), icon: "Chat/Context Menu/Boost", prompt: aorusAILocalized("Сделай тон этого сообщения увереннее", "Make this message sound more confident")),
            Item(id: "tone.simple", title: aorusAILocalized("Проще", "Simpler"), icon: "Chat/Context Menu/Smile", prompt: aorusAILocalized("Перепиши это сообщение проще и понятнее", "Rewrite this message in simpler, clearer language")),
            Item(id: "tone.detailed", title: aorusAILocalized("Подробнее", "More detailed"), icon: "Chat/Context Menu/Expand", prompt: aorusAILocalized("Сделай это сообщение подробнее, не меняя смысл", "Make this message more detailed without changing its meaning")),
            Item(id: "tone.rewrite", title: aorusAILocalized("Переформулировать", "Rewrite"), icon: "Chat/Context Menu/Reload", prompt: aorusAILocalized("Переформулируй это сообщение", "Rewrite this message"))
        ]
    }

    /// Every icon is a native `Chat/Context Menu/*` bundle asset, tinted with the
    /// AorusAI accent inside its tile.
    static func groups(languageCode: String) -> [Group] {
        let tones = toneItems
        return [
            Group(title: aorusAILocalized("Текст", "Text"), icon: "Chat/Context Menu/Edit", items: [
                Item(id: "text.improve", title: aorusAILocalized("Улучшить текст", "Improve writing"), icon: "Chat/Context Menu/Edit", prompt: aorusAILocalized("Улучши текст, сохранив смысл", "Improve the writing while preserving its meaning")),
                Item(id: "text.fix", title: aorusAILocalized("Исправить ошибки", "Fix mistakes"), icon: "Chat/Context Menu/Check", prompt: aorusAILocalized("Исправь ошибки в этом сообщении", "Fix mistakes in this message")),
                Item(id: "text.shorten", title: aorusAILocalized("Сделать короче", "Make shorter"), icon: "Chat/Context Menu/Collapse", prompt: aorusAILocalized("Сделай это сообщение короче", "Make this message shorter")),
                Item(
                    id: translateId,
                    title: aorusAILocalized("Перевести", "Translate"),
                    icon: "Chat/Context Menu/Translate",
                    prompt: "",
                    hint: currentLanguageName(for: languageCode),
                    children: translationItems(for: languageCode)
                )
            ]),
            Group(title: aorusAILocalized("Тон", "Tone"), icon: "Chat/Context Menu/Customize", items: [
                Item(
                    id: toneId,
                    title: aorusAILocalized("Сменить тон", "Change tone"),
                    icon: "Chat/Context Menu/Customize",
                    prompt: "",
                    hint: aorusAILocalized("\(tones.count) вариантов", "\(tones.count) options"),
                    children: tones
                ),
                Item(id: "text.reply", title: aorusAILocalized("Ответить на сообщение", "Draft a reply"), icon: "Chat/Context Menu/Reply", prompt: aorusAILocalized("Подготовь уместный ответ на это сообщение", "Draft an appropriate reply to this message"))
            ]),
            Group(title: aorusAILocalized("Разобрать", "Break down"), icon: "Chat/Context Menu/Statistics", items: [
                Item(id: "text.summarize", title: aorusAILocalized("Кратко пересказать", "Summarize"), icon: "Chat/Context Menu/List", prompt: aorusAILocalized("Кратко перескажи это сообщение", "Summarize this message")),
                Item(id: "review.explain", title: aorusAILocalized("Объяснить", "Explain"), icon: "Chat/Context Menu/Help", prompt: aorusAILocalized("Объясни это сообщение", "Explain this message")),
                Item(id: "review.key", title: aorusAILocalized("Выделить главное", "Key points"), icon: "Chat/Context Menu/Fave", prompt: aorusAILocalized("Выдели главное в этом сообщении", "Extract the key points from this message")),
                Item(id: "review.variants", title: aorusAILocalized("Несколько ответов", "Several replies"), icon: "Chat/Context Menu/Replies", prompt: aorusAILocalized("Предложи несколько вариантов ответа на это сообщение", "Suggest several replies to this message")),
                Item(
                    id: analyzeChatId,
                    title: aorusAILocalized("Анализ переписки", "Analyze chat"),
                    icon: "Chat/Context Menu/Statistics",
                    prompt: "",
                    hint: aorusAILocalized(
                        "до \(AorusAIRequestLimits.chatHistoryMessageCount) сообщений",
                        "up to \(AorusAIRequestLimits.chatHistoryMessageCount) messages"
                    )
                )
            ]),
            Group(title: aorusAILocalized("Создать", "Create"), icon: "Chat/Context Menu/AddCaption", items: [
                Item(id: "create.telegram", title: aorusAILocalized("Telegram-пост", "Telegram post"), icon: "Chat/Context Menu/Telegram", prompt: aorusAILocalized("Сделай из этого профессиональный Telegram-пост", "Turn this into a professional Telegram post")),
                Item(id: "create.instagram", title: aorusAILocalized("Instagram-пост", "Instagram post"), icon: "Chat/Context Menu/Camera", prompt: aorusAILocalized("Сделай из этого профессиональный Instagram-пост", "Turn this into a professional Instagram post")),
                Item(id: "create.title", title: aorusAILocalized("Заголовок", "Title"), icon: "Chat/Context Menu/FormatHeading", prompt: aorusAILocalized("Придумай сильный заголовок для этого текста", "Create a strong title for this text")),
                Item(id: "create.description", title: aorusAILocalized("Описание", "Description"), icon: "Chat/Context Menu/Caption", prompt: aorusAILocalized("Создай краткое и точное описание для этого текста", "Create a concise, accurate description for this text")),
                Item(id: "create.continue", title: aorusAILocalized("Продолжить текст", "Continue writing"), icon: "Chat/Context Menu/AddCaption", prompt: aorusAILocalized("Естественно продолжи этот текст в том же стиле", "Continue this text naturally in the same style"))
            ])
        ]
    }

    static var footerItem: Item {
        return Item(
            id: newChatId,
            title: aorusAILocalized("Новый диалог с текстом", "New chat with this text"),
            icon: "Chat/Context Menu/MessageBubble",
            prompt: ""
        )
    }

    static func run(id: String, context: AccountContext, navigationController: NavigationController, reference: AorusAIReferencedMessage) {
        switch id {
        case analyzeChatId:
            aorusAIPresentHistoryCount(context: context, navigationController: navigationController, reference: reference)
        case newChatId:
            navigationController.pushViewController(AorusAIChatController(context: context, conversation: AorusAIConversation(), reference: reference))
        default:
            let languageCode = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
            let roots = groups(languageCode: languageCode).flatMap { $0.items }
            guard let prompt = findItem(id: id, in: roots)?.prompt, !prompt.isEmpty else { return }
            navigationController.pushViewController(AorusAIChatController(context: context, conversation: AorusAIConversation(), initialPrompt: prompt, reference: reference))
        }
    }

    private static func findItem(id: String, in items: [Item]) -> Item? {
        for item in items {
            if item.id == id { return item }
            if let found = findItem(id: id, in: item.children) { return found }
        }
        return nil
    }
}

private func aorusAIPresentHistoryCount(context: AccountContext, navigationController: NavigationController, reference: AorusAIReferencedMessage) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let limit = AorusAIRequestLimits.chatHistoryMessageCount
    let sheet = ActionSheetController(presentationData: presentationData)
    var choices: [ActionSheetButtonItem] = [20, 50, 100, limit].map { count in
        ActionSheetButtonItem(title: "\(count)", color: .accent, action: { [weak sheet] in
            sheet?.dismissAnimated()
            aorusAIPrepareHistoryAnalysis(context: context, navigationController: navigationController, reference: reference, count: count)
        })
    }
    choices.append(ActionSheetButtonItem(title: aorusAILocalized("Другое…", "Other…"), color: .accent, action: { [weak sheet] in
        sheet?.dismissAnimated()
        aorusAIPresentCustomHistoryCount(context: context, navigationController: navigationController, reference: reference)
    }))
    sheet.setItemGroups([
        ActionSheetItemGroup(items: choices),
        ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in
                sheet?.dismissAnimated()
            })
        ])
    ])
    (navigationController.topViewController as? ViewController)?.present(sheet, in: .window(.root))
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
            aorusAIPresent(invalid, from: navigationController)
            return
        }
        aorusAIPrepareHistoryAnalysis(context: context, navigationController: navigationController, reference: reference, count: min(limit, parsed))
    }))
    aorusAIPresent(alert, from: navigationController)
}

private struct AorusAITranscript {
    var messageCount: Int
    var text: String
}

/// Reads the newest `count` text messages of `peerId` from the local Postbox.
///
/// This is the "analyze this chat" entry point of the message context menu: it builds
/// a transcript the user sees in full before confirming, and sends it inline with the
/// prompt. The agent-driven path is `aorusAIChatHistoryLines` below, which answers a
/// server `permission.request` with `aorus_tool_results` instead.
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

/// One `result.messages[]` element of a `telegram.chat.history` tool result.
private struct AorusAIHistoryLine {
    var sender: String
    var text: String
}

/// The device-side implementation of the `telegram.chat.history` tool.
///
/// The messages are read from the local Postbox — the server never gets a way to pull
/// them itself. `fromDate` / `toDate` implement the `mode: "period"` option: the scan
/// walks newest-first, skips everything newer than `toDate` and stops as soon as it
/// crosses below `fromDate`, so a period query does not read the whole chat.
private func aorusAIChatHistoryLines(
    context: AccountContext,
    peerId: PeerId,
    limit: Int,
    fromDate: Int64?,
    toDate: Int64?,
    strings: PresentationStrings,
    nameOrder: PresentationPersonNameOrder,
    unknownAuthor: String
) -> Signal<[AorusAIHistoryLine], NoError> {
    let requested = min(AorusAIRequestLimits.chatHistoryMessageCount, max(1, limit))
    let perMessage = AorusAIRequestLimits.chatHistoryMessageCharacters
    // A period query has to look past the messages it rejects, so its scan window is
    // wider than the number of lines it may return, but still bounded.
    let scanLimit = (fromDate != nil || toDate != nil)
        ? min(AorusAIRequestLimits.chatHistoryMessageCount * 4, max(requested, 400))
        : requested
    return context.account.postbox.transaction { transaction -> [AorusAIHistoryLine] in
        var lines: [AorusAIHistoryLine] = []
        transaction.scanTopMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, limit: scanLimit) { message in
            guard lines.count < requested else { return false }
            let timestamp = Int64(message.timestamp)
            if let toDate = toDate, timestamp > toDate {
                return true
            }
            if let fromDate = fromDate, timestamp < fromDate {
                return false
            }
            let body = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return true }
            let author = message.author.flatMap { EnginePeer($0).displayTitle(strings: strings, displayOrder: nameOrder) } ?? unknownAuthor
            let clamped = body.count > perMessage ? String(body.prefix(perMessage)) + "…" : body
            lines.append(AorusAIHistoryLine(sender: author, text: clamped))
            return true
        }
        return Array(lines.reversed())
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
            aorusAIPresent(empty, from: navigationController)
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
        aorusAIPresent(confirmation, from: navigationController)
    })
}

private final class AorusAIConversationListController: ViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private struct Section {
        var title: String
        var rows: [AorusAIConversation]
    }

    private let context: AccountContext
    private let presentationData: PresentationData
    private let palette: AorusAIPalette
    private let accountId: Int64
    // A plain table, not `.insetGrouped`: the cards are drawn by
    // `AorusAIGroupBackgroundView` so their radius, hairline and separator inset are
    // the design's own instead of the fixed 10pt UIKit gives grouped sections.
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let searchField = AorusAISearchFieldView()
    private let listHeader = AorusAIConversationListHeaderView()
    private let emptyView = AorusAIConversationListEmptyView()
    private let bottomBar = UIView()
    private let newChatButton = UIButton(type: .system)
    private let profileNameDisposable = MetaDisposable()
    private var conversations: [AorusAIConversation] = []
    private var sections: [Section] = []
    private var searchQuery = ""
    private var observer: NSObjectProtocol?
    /// The last width the list was laid out at, so the header and footer can be re-measured
    /// when their text changes and not only when the screen resizes.
    private var listWidth: CGFloat = 0.0

    private var visibleConversations: [AorusAIConversation] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }
        return conversations.filter { conversation in
            if conversation.title.localizedCaseInsensitiveContains(query) { return true }
            return conversation.messages.contains { $0.rawText.localizedCaseInsensitiveContains(query) }
        }
    }

    private func rebuildSections() {
        let visible = visibleConversations
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections = visible.isEmpty ? [] : [Section(title: aorusAILocalized("Результаты", "Results"), rows: visible)]
            return
        }
        sections = visible.isEmpty ? [] : [Section(title: aorusAILocalized("Недавние", "Recent"), rows: visible)]
    }

    init(context: AccountContext) {
        self.context = context
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.presentationData = presentationData
        self.palette = AorusAIPalette.resolve(presentationData.theme)
        self.accountId = context.account.id.int64
        let palette = self.palette
        // The design draws one flat surface from the status bar down, so the navigation
        // bar takes the page background, drops its blur and hides its separator instead
        // of keeping Telegram's own bar colour above a #0E0E12 page.
        let base = NavigationBarPresentationData(presentationData: presentationData)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(
            theme: NavigationBarTheme(
                overallDarkAppearance: palette.isDark,
                buttonColor: palette.accent,
                disabledButtonColor: palette.tertiary,
                primaryTextColor: palette.label,
                backgroundColor: palette.background,
                opaqueBackgroundColor: palette.background,
                enableBackgroundBlur: false,
                separatorColor: .clear,
                badgeBackgroundColor: palette.accent,
                badgeStrokeColor: palette.accent,
                badgeTextColor: palette.onAccent,
                accentButtonColor: palette.accent,
                accentDisabledButtonColor: palette.tertiary,
                accentForegroundColor: palette.onAccent
            ),
            strings: base.strings
        ))
        self.title = "AorusAI"
        self.statusBar.statusBarStyle = palette.isDark ? .White : .Black
        // Telegram's navigation bar draws only `image` and `title` of a bar button item, so a
        // system item such as `.add` renders as an empty tap area — which is why the button
        // looked missing. The compose glyph is the one the chat list itself uses, retinted
        // to the AorusAI palette.
        let composeImage = generateTintedImage(
            image: PresentationResourcesRootController.navigationComposeIcon(presentationData.theme)
                ?? UIImage(systemName: "square.and.pencil"),
            color: palette.secondary
        )
        let composeItem = UIBarButtonItem(image: composeImage, style: .plain, target: self, action: #selector(createConversation))
        composeItem.tintColor = palette.secondary
        composeItem.accessibilityLabel = aorusAILocalized("Новый диалог", "New chat")
        self.navigationItem.rightBarButtonItem = composeItem
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        profileNameDisposable.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = ViewControllerTracingNode()
        self.displayNode.backgroundColor = palette.background
        tableView.backgroundColor = palette.background
        // The cards carry their own hairline, so the table's own separators would double it.
        tableView.separatorStyle = .none
        tableView.indicatorStyle = palette.isDark ? .white : .black
        tableView.rowHeight = AorusAIConversationCell.preferredHeight
        tableView.keyboardDismissMode = .onDrag
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(AorusAIConversationCell.self, forCellReuseIdentifier: "conversation")
        listHeader.configure(palette: palette)
        tableView.tableHeaderView = listHeader
        tableView.tableFooterView = UIView(frame: .zero)
        emptyView.configure(palette: palette)
        tableView.backgroundView = emptyView
        self.displayNode.view.addSubview(tableView)

        searchField.configure(palette: palette, placeholder: aorusAILocalized("Поиск по диалогам", "Search chats"))
        searchField.textField.delegate = self
        searchField.textField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        self.displayNode.view.addSubview(searchField)

        bottomBar.backgroundColor = palette.background
        newChatButton.backgroundColor = palette.accent
        newChatButton.tintColor = palette.onAccent
        newChatButton.setTitleColor(palette.onAccent, for: .normal)
        newChatButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        newChatButton.setTitle(aorusAILocalized("Новый диалог", "New chat"), for: .normal)
        newChatButton.setImage(UIImage(systemName: "square.and.pencil")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        newChatButton.semanticContentAttribute = .forceLeftToRight
        newChatButton.imageEdgeInsets = UIEdgeInsets(top: 0.0, left: -4.0, bottom: 0.0, right: 4.0)
        newChatButton.layer.cornerRadius = 24.0
        newChatButton.layer.cornerCurve = .continuous
        newChatButton.addTarget(self, action: #selector(createConversation), for: .touchUpInside)
        newChatButton.accessibilityLabel = aorusAILocalized("Новый диалог", "New chat")
        bottomBar.addSubview(newChatButton)
        self.displayNode.view.addSubview(bottomBar)

        observer = NotificationCenter.default.addObserver(forName: AorusAIStore.changedNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? NSNumber)?.int64Value == self.accountId else { return }
            self.reload()
        }
        profileNameDisposable.set((context.engine.data.get(
            TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId)
        ) |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self else { return }
            let name = peer?.displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)
            self.listHeader.setDisplayName(name)
            // The greeting just grew by a name, which can turn it into two lines.
            self.updateTableAccessories()
        }))
        reload()
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        let searchFrame = CGRect(x: 16.0, y: top, width: max(0.0, layout.size.width - 32.0), height: 38.0)
        transition.updateFrame(view: searchField, frame: searchFrame)
        let barHeight: CGFloat = 60.0 + layout.intrinsicInsets.bottom
        let bottomFrame = CGRect(x: 0.0, y: layout.size.height - barHeight, width: layout.size.width, height: barHeight)
        transition.updateFrame(view: bottomBar, frame: bottomFrame)
        transition.updateFrame(view: newChatButton, frame: CGRect(x: 16.0, y: 8.0, width: max(0.0, layout.size.width - 32.0), height: 48.0))
        let tableTop = searchFrame.maxY + 12.0
        transition.updateFrame(view: tableView, frame: CGRect(x: 0.0, y: tableTop, width: layout.size.width, height: max(0.0, bottomFrame.minY - tableTop)))
        listWidth = layout.size.width
        updateTableAccessories()
    }

    /// Sizes the greeting to its actual text. The local-storage explanation was removed
    /// from the visual hierarchy; it added a system note below the user's conversations.
    private func updateTableAccessories() {
        guard listWidth > 0.0 else { return }
        let headerHeight = listHeader.height(forWidth: listWidth)
        if abs(listHeader.frame.width - listWidth) > 0.5 || abs(listHeader.frame.height - headerHeight) > 0.5 {
            listHeader.frame = CGRect(x: 0.0, y: 0.0, width: listWidth, height: headerHeight)
            listHeader.layoutIfNeeded()
            tableView.tableHeaderView = listHeader
        }
    }

    private func reload() {
        AorusAIStore.shared.load(accountId: accountId) { [weak self] conversations in
            guard let self else { return }
            self.conversations = conversations
            self.rebuildSections()
            self.tableView.reloadData()
            self.updateEmptyState()
        }
    }

    private func updateEmptyState() {
        let isEmpty = sections.isEmpty
        emptyView.isHidden = !isEmpty
        emptyView.accessibilityElementsHidden = !isEmpty
        emptyView.setSearching(!searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @objc private func createConversation() {
        let conversation = AorusAIConversation()
        AorusAIStore.shared.upsert(conversation, accountId: accountId)
        (self.navigationController as? NavigationController)?.pushViewController(AorusAIChatController(context: context, conversation: conversation))
    }

    @objc private func searchTextChanged() {
        searchQuery = searchField.textField.text ?? ""
        rebuildSections()
        tableView.reloadData()
        updateEmptyState()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return AorusAISectionHeaderView.preferredHeight
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = AorusAISectionHeaderView()
        header.configure(palette: palette, title: sections[section].title)
        return header
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 0.01
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "conversation", for: indexPath) as? AorusAIConversationCell else {
            assertionFailure("Unexpected AorusAI conversation cell type")
            return UITableViewCell(style: .default, reuseIdentifier: nil)
        }
        let rows = sections[indexPath.section].rows
        cell.configure(
            conversation: rows[indexPath.row],
            palette: palette,
            position: AorusAIGroupPosition.of(index: indexPath.row, count: rows.count)
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let conversation = sections[indexPath.section].rows[indexPath.row]
        // A turn that outlived its screen is still running inside its own controller, so the
        // row re-opens that instance. A second controller over the same conversation would
        // fight it for the same messages and the live answer would look frozen.
        let key = AorusAIActiveTurnCenter.key(accountId: accountId, conversationId: conversation.id)
        let controller = AorusAIActiveTurnCenter.shared.liveController(forKey: key)
            ?? AorusAIChatController(context: context, conversation: conversation)
        (self.navigationController as? NavigationController)?.pushViewController(controller)
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        return nil
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let id = sections[indexPath.section].rows[indexPath.row].id
        let action = UIContextualAction(style: .destructive, title: presentationData.strings.Common_Delete) { [weak self] _, _, done in
            guard let self else { done(false); return }
            // A turn of this conversation may still be running off-screen; it is stopped
            // first, otherwise its next save would bring the deleted chat back.
            AorusAIActiveTurnCenter.shared.abortTurn(forKey: AorusAIActiveTurnCenter.key(accountId: self.accountId, conversationId: id))
            AorusAIStore.shared.delete(conversationId: id, accountId: self.accountId) { done($0) }
        }
        action.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }
}

/// The 38pt search pill of the design: a hairline capsule on the elevated surface with a
/// leading magnifier, in place of `UISearchBar` whose own chrome cannot be brought to
/// this shape without fighting its internals.
private final class AorusAISearchFieldView: UIView {
    let textField = UITextField()
    private let materialView = UIVisualEffectView()
    private let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.cornerRadius = 19.0
        self.layer.cornerCurve = .continuous
        self.layer.borderWidth = UIScreenPixel
        self.clipsToBounds = true
        materialView.isUserInteractionEnabled = false
        addSubview(materialView)
        iconView.contentMode = .scaleAspectFit
        iconView.image = UIImage(systemName: "magnifyingglass")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 14.0, weight: .medium))
        textField.font = .systemFont(ofSize: 15.0)
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.returnKeyType = .search
        textField.clearButtonMode = .whileEditing
        addSubview(iconView)
        addSubview(textField)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(palette: AorusAIPalette, placeholder: String) {
        backgroundColor = .clear
        materialView.effect = aorusAIGlassEffect(palette: palette)
        materialView.backgroundColor = aorusAIGlassTint(palette: palette)
        layer.borderColor = aorusAIGlassBorder(palette: palette).cgColor
        iconView.tintColor = palette.tertiary
        textField.textColor = palette.label
        textField.tintColor = palette.accent
        textField.keyboardAppearance = palette.isDark ? .dark : .light
        textField.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: palette.tertiary, .font: UIFont.systemFont(ofSize: 15.0)]
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        materialView.frame = bounds
        iconView.frame = CGRect(x: 12.0, y: floor((bounds.height - 16.0) / 2.0), width: 16.0, height: 16.0)
        textField.frame = CGRect(x: 36.0, y: 0.0, width: max(0.0, bounds.width - 48.0), height: bounds.height)
    }
}

/// A 13pt group label — "Закреплённые", "Недавние" — with the design's spacing above the
/// card it introduces.
private final class AorusAISectionHeaderView: UIView {
    static let preferredHeight: CGFloat = 24.0

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13.0, weight: .medium)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(palette: AorusAIPalette, title: String) {
        backgroundColor = palette.background
        label.textColor = palette.tertiary
        label.text = title
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 20.0, y: 2.0, width: max(0.0, bounds.width - 40.0), height: 18.0)
    }
}

private final class AorusAIConversationListHeaderView: UIView {
    private static let horizontalInset: CGFloat = 20.0
    private static let topInset: CGFloat = 8.0
    private static let spacing: CGFloat = 2.0
    private static let bottomInset: CGFloat = 0.0

    private let greetingLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var displayName: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The design sets the greeting in the system serif, the one place on the screen
        // where the type turns editorial.
        greetingLabel.font = aorusAISerifFont(size: 26.0, weight: .semibold)
        // "Добрый вечер, " plus a full display name does not fit one 26pt serif line on a
        // narrow phone. It used to be squeezed into a fixed 32pt frame, which is what put
        // the text outside the header; it wraps to a second line instead.
        greetingLabel.numberOfLines = 2
        greetingLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 15.0, weight: .regular)
        subtitleLabel.numberOfLines = 2
        subtitleLabel.text = aorusAILocalized("Чем займёмся сегодня?", "What are we doing today?")
        [greetingLabel, subtitleLabel].forEach { addSubview($0) }
        refreshGreeting()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(palette: AorusAIPalette) {
        backgroundColor = palette.background
        greetingLabel.textColor = palette.label
        subtitleLabel.textColor = palette.secondary
    }

    func setDisplayName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = trimmed?.isEmpty == false ? trimmed : nil
        refreshGreeting()
    }

    /// The height the current text needs at `width`. A table header view is positioned by
    /// its own frame, so the measurement has to happen before it is installed.
    func height(forWidth width: CGFloat) -> CGFloat {
        let available = max(1.0, width - Self.horizontalInset * 2.0)
        return ceil(Self.topInset + textHeight(of: greetingLabel, width: available) + Self.spacing + textHeight(of: subtitleLabel, width: available) + Self.bottomInset)
    }

    private func textHeight(of label: UILabel, width: CGFloat) -> CGFloat {
        return ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let available = max(0.0, bounds.width - Self.horizontalInset * 2.0)
        let greetingHeight = textHeight(of: greetingLabel, width: available)
        greetingLabel.frame = CGRect(x: Self.horizontalInset, y: Self.topInset, width: available, height: greetingHeight)
        subtitleLabel.frame = CGRect(
            x: Self.horizontalInset,
            y: greetingLabel.frame.maxY + Self.spacing,
            width: available,
            height: textHeight(of: subtitleLabel, width: available)
        )
    }

    private func refreshGreeting() {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting: String
        if hour < 12 {
            greeting = aorusAILocalized("Доброе утро", "Good morning")
        } else if hour < 18 {
            greeting = aorusAILocalized("Добрый день", "Good afternoon")
        } else {
            greeting = aorusAILocalized("Добрый вечер", "Good evening")
        }
        greetingLabel.text = displayName.map { "\(greeting), \($0)" } ?? greeting
        greetingLabel.accessibilityLabel = greetingLabel.text
        setNeedsLayout()
    }
}

private final class AorusAIConversationCell: UITableViewCell {
    static let preferredHeight: CGFloat = 66.0
    private static let cardInset: CGFloat = 16.0
    private static let contentInset: CGFloat = 16.0

    private let cardView = AorusAIGroupBackgroundView()
    private let highlightView = UIView()
    private let titleLabel = UILabel()
    private let previewLabel = UILabel()
    private let dateLabel = UILabel()
    private let chevronView = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.selectionStyle = .none
        titleLabel.font = .systemFont(ofSize: 16.0, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        previewLabel.font = .systemFont(ofSize: 14.0)
        previewLabel.lineBreakMode = .byTruncatingTail
        dateLabel.font = .systemFont(ofSize: 12.0)
        dateLabel.textAlignment = .right
        chevronView.contentMode = .scaleAspectFit
        chevronView.image = UIImage(systemName: "chevron.right")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold))
        highlightView.alpha = 0.0
        contentView.addSubview(cardView)
        cardView.addSubview(highlightView)
        [titleLabel, dateLabel, previewLabel, chevronView].forEach { cardView.addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(conversation: AorusAIConversation, palette: AorusAIPalette, position: AorusAIGroupPosition) {
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        cardView.configure(palette: palette, position: position, radius: 18.0, separatorInset: Self.contentInset)
        highlightView.backgroundColor = palette.fill
        titleLabel.textColor = palette.label
        previewLabel.textColor = palette.secondary
        dateLabel.textColor = palette.tertiary
        chevronView.tintColor = palette.tertiary.withAlphaComponent(0.7)
        titleLabel.text = conversation.title.isEmpty ? aorusAILocalized("Новый диалог", "New chat") : conversation.title
        previewLabel.text = conversation.messages.last(where: { !$0.rawText.isEmpty })?.rawText
            ?? aorusAILocalized("Начните разговор с AorusAI", "Start a conversation with AorusAI")
        dateLabel.text = AorusAIFormat.relativeDate(conversation.updatedAt)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = titleLabel.text
        accessibilityValue = [previewLabel.text, dateLabel.text].compactMap { $0 }.joined(separator: ", ")
        setNeedsLayout()
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        // The card is drawn inside the cell, so a `selectedBackgroundView` would paint a
        // full-width rectangle behind it instead of tinting the row.
        let alpha: CGFloat = highlighted ? 1.0 : 0.0
        if animated && !highlighted {
            UIView.animate(withDuration: 0.2) { self.highlightView.alpha = alpha }
        } else {
            highlightView.alpha = alpha
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        cardView.frame = CGRect(x: Self.cardInset, y: 0.0, width: max(0.0, width - Self.cardInset * 2.0), height: contentView.bounds.height)
        highlightView.frame = cardView.bounds
        let inset = Self.contentInset
        let cardWidth = cardView.bounds.width
        let chevronSize: CGFloat = 15.0
        chevronView.frame = CGRect(x: max(0.0, cardWidth - inset - chevronSize), y: floor((cardView.bounds.height - chevronSize) / 2.0), width: chevronSize, height: chevronSize)
        let contentRight = chevronView.frame.minX - 8.0
        let dateWidth = min(70.0, ceil((dateLabel.text ?? "").size(withAttributes: [.font: UIFont.systemFont(ofSize: 12.0)]).width) + 1.0)
        dateLabel.frame = CGRect(x: max(inset, contentRight - dateWidth), y: 13.0, width: dateWidth, height: 18.0)
        titleLabel.frame = CGRect(x: inset, y: 12.0, width: max(0.0, dateLabel.frame.minX - 8.0 - inset), height: 20.0)
        previewLabel.frame = CGRect(x: inset, y: 35.0, width: max(0.0, contentRight - inset), height: 19.0)
    }
}

private final class AorusAIConversationListEmptyView: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .scaleAspectFit
        titleLabel.font = aorusAISerifFont(size: 20.0, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.text = aorusAILocalized("Начните новый диалог", "Start a new chat")
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        detailLabel.text = aorusAILocalized("Задайте вопрос или поручите AorusAI работу с файлами", "Ask a question or let AorusAI work with files")
        [iconView, titleLabel, detailLabel].forEach { addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -35),
            iconView.widthAnchor.constraint(equalToConstant: 40), iconView.heightAnchor.constraint(equalToConstant: 40),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30), titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40), detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(palette: AorusAIPalette) {
        backgroundColor = palette.background
        iconView.image = UIImage(systemName: "bubble.left.and.bubble.right.fill")?.withRenderingMode(.alwaysTemplate)
        iconView.tintColor = palette.accent
        titleLabel.textColor = palette.label
        detailLabel.textColor = palette.secondary
    }

    func setSearching(_ searching: Bool) {
        titleLabel.text = searching
            ? aorusAILocalized("Ничего не найдено", "No results")
            : aorusAILocalized("Начните новый диалог", "Start a new chat")
        detailLabel.text = searching
            ? aorusAILocalized("Попробуйте изменить запрос", "Try a different search")
            : aorusAILocalized("Задайте вопрос или поручите AorusAI работу с файлами", "Ask a question or let AorusAI work with files")
        iconView.image = UIImage(systemName: searching ? "magnifyingglass" : "bubble.left.and.bubble.right.fill")?.withRenderingMode(.alwaysTemplate)
    }
}

private final class AorusAIChatController: ViewController, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    private let context: AccountContext
    private let presentationData: PresentationData
    private let palette: AorusAIPalette
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
    /// Artifacts currently being fetched, by `artifactId`. Owned by the controller, not
    /// by the card, because every reload builds new cards.
    private var loadingArtifactIds: Set<String> = []
    /// The cancel handle of each running download, so a second tap stops the transfer.
    private var artifactDownloads: [String: AorusAIDownloadHandle] = [:]
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
    ///
    /// It covers three windows of one logical turn: the profile lookup before the first
    /// request, and — after `done(ok: true, state: awaiting_*)` closed the immediate
    /// stream — the tool execution and the permission dialog that precede a
    /// continuation. In all of them the turn is alive without a socket.
    private var isPreparingRequest = false
    // MARK: Agent tool workflow (§13 state machine)
    /// The explicit turn state. `awaitingTool`/`awaitingPermission` are successful
    /// intermediate states: they may never be turned into a failed turn (§13).
    private enum TurnState: Equatable {
        case idle
        case streaming
        case awaitingTool(AorusAIToolRequest)
        case submittingToolResult
        case awaitingPermission(AorusAIPermissionRequest)
        case executingHistoryTool(AorusAIPermissionRequest)
    }
    private var turnState: TurnState = .idle {
        didSet { updateBackgroundPresence() }
    }
    /// True while one logical turn is alive, whether or not a socket is open right now: the
    /// profile lookup before the first request, the stream itself, and every tool or
    /// permission step in between all belong to the same unfinished answer.
    private var isTurnLive: Bool {
        if case .idle = turnState {
            return streamHandle != nil || isPreparingRequest
        }
        return true
    }
    /// The extra runtime asked from the OS so a turn is not frozen mid-answer when the app
    /// leaves the foreground. `.invalid` means no task is held.
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    /// The window this screen was last shown in. After the screen is closed `view.window`
    /// is nil, and the floating indicator still needs somewhere to live.
    private weak var lastKnownWindow: UIWindow?
    /// The stack this screen was pushed on, remembered while it is still on it: after the
    /// pop `navigationController` is nil, and the indicator has to be able to push it back.
    private weak var lastNavigationController: NavigationController?
    /// A dialog the running turn is waiting on that could not be shown because the screen
    /// was closed. It is presented again the moment the screen comes back.
    private var deferredUserPrompt: (() -> Void)?
    /// Set when the conversation this controller works on was deleted underneath it. From
    /// then on it writes nothing back to the store.
    private var isDiscarded = false
    /// Every tool result of the current logical request, in order. It is resent with
    /// each continuation because the backend re-reads the whole array and would ask for
    /// the profile again if the history continuation dropped it (§14).
    private var turnToolResults: [AorusAIToolResult] = []
    /// The exact transport text of the running turn: a continuation repeats the same
    /// conversation and prompt and only adds `aorus_tool_results` (§6).
    private var turnTransportText: String?
    /// The context turns the running request was built from, frozen when the turn
    /// started so a continuation cannot accidentally replay the half-written answer.
    private var turnHistory: [AorusAIMessage] = []
    /// How many continuations this turn has already sent. The ceiling is what makes an
    /// infinite tool loop impossible (§31).
    private var turnContinuationCount = 0
    /// The tool the backend asked for, executed once its `done(awaiting_tool)` arrives.
    private var pendingToolRequest: AorusAIToolRequest?
    /// The permission the backend asked for, shown once `done(awaiting_permission)`
    /// arrives, so the whole immediate stream is consumed before a modal appears.
    private var pendingPermissionRequest: AorusAIPermissionRequest?
    /// Local Telegram work of the current tool step (peer resolution, history read).
    private let toolExecutionDisposable = MetaDisposable()
    /// The backend keeps the last 8 tool results, so there is no point in carrying more.
    private static let maxAccumulatedToolResults = 8
    /// Two tools per turn are enough for the documented flow (profile, then history);
    /// the ceiling leaves room for a retry without ever looping forever.
    private static let maxToolContinuations = 6
    private let dictation = AorusAIDictation()
    /// What the input held before the current dictation run, so partial results replace
    /// only the spoken part instead of the whole draft.
    private var dictationBaseText = ""
    private var dictationSpokenText = ""
    private var headerView: AorusAINavigationTitleView?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let composer = AorusAIComposerView()

    /// `initialPrompt` is what the user sees in the conversation. `initialRequest`
    /// is what is actually sent when the two differ — a chat analysis shows a short
    /// instruction but transports the confirmed transcript with it.
    init(context: AccountContext, conversation: AorusAIConversation, initialPrompt: String? = nil, initialRequest: String? = nil, reference: AorusAIReferencedMessage? = nil) {
        self.context = context
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.presentationData = presentationData
        let palette = AorusAIPalette.resolve(presentationData.theme)
        self.palette = palette
        self.accountId = context.account.id.int64
        self.conversation = conversation
        self.initialPrompt = initialPrompt
        self.initialRequest = initialRequest
        self.pendingReference = reference
        // The same flat bar as the conversation list: no blur, no separator, the screen's
        // own background continued behind the status bar. `NavigationBarTheme` is spelled
        // out because the shared presentation theme would bring back Telegram's chat bar
        // colours and blur, which the design does not have.
        let base = NavigationBarPresentationData(presentationData: presentationData)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(
            theme: NavigationBarTheme(
                overallDarkAppearance: palette.isDark,
                buttonColor: palette.accent,
                disabledButtonColor: palette.tertiary,
                primaryTextColor: palette.label,
                backgroundColor: palette.background,
                opaqueBackgroundColor: palette.background,
                enableBackgroundBlur: false,
                separatorColor: .clear,
                badgeBackgroundColor: palette.accent,
                badgeStrokeColor: palette.accent,
                badgeTextColor: palette.onAccent,
                accentButtonColor: palette.accent,
                accentDisabledButtonColor: palette.tertiary,
                accentForegroundColor: palette.onAccent
            ),
            strings: base.strings
        ))
        // `title` stays unset because Telegram's navigation bar draws either the string or
        // the custom view, never both.
        let titleView = AorusAINavigationTitleView(theme: presentationData.theme)
        self.headerView = titleView
        self.navigationItem.titleView = titleView
        self.statusBar.statusBarStyle = palette.isDark ? .White : .Black
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingPersistWork?.cancel()
        pendingRenderWork?.cancel()
        quotaTimer?.invalidate()
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
        streamHandle?.cancelTransport()
        if let turnId {
            AorusAIClient.shared.cancelTurn(turnId) { _ in }
        }
        draftEntityResolutionDisposables.forEach { $0.dispose() }
        messageEntityResolutionDisposables.values.flatMap { $0 }.forEach { $0.dispose() }
        profileContextDisposable.dispose()
        toolExecutionDisposable.dispose()
        artifactDownloads.values.forEach { $0.cancel() }
        removePreviewArtifact()
    }

    override func loadDisplayNode() {
        self.displayNode = ViewControllerTracingNode()
        self.displayNode.backgroundColor = palette.background
        tableView.backgroundColor = palette.background
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
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        if let initialPrompt, !initialPrompt.isEmpty { composer.text = initialPrompt }
        scheduleQuotaResetIfNeeded()
        updateComposer()
        self.displayNodeDidLoad()
        DispatchQueue.main.async { [weak self] in self?.scrollToBottom(animated: false) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        lastKnownWindow = self.view.window
        lastNavigationController = self.navigationController as? NavigationController
        // The screen is back on top: the navigation stack owns this controller again, so the
        // off-screen hold and its floating indicator are no longer needed.
        AorusAIActiveTurnCenter.shared.release(key: activeTurnKey, controller: self)
        // A question that arrived while the screen was closed is asked now, not lost: the
        // turn was waiting for it and would otherwise never be answered.
        if let prompt = deferredUserPrompt {
            deferredUserPrompt = nil
            DispatchQueue.main.async { prompt() }
        }
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
        // The window is still attached at this point, which is the only moment the floating
        // indicator can be installed — and a running turn has to be kept alive before this
        // controller leaves the stack and its `deinit` cancels the stream.
        lastKnownWindow = self.view.window ?? lastKnownWindow
        lastNavigationController = (self.navigationController as? NavigationController) ?? lastNavigationController
        if isTurnLive { holdForBackgroundTurn() }
    }

    /// The key one conversation of one account is held under.
    private var activeTurnKey: String {
        return AorusAIActiveTurnCenter.key(accountId: accountId, conversationId: conversation.id)
    }

    private var isOnScreen: Bool {
        return self.view.window != nil
    }

    /// Holds back a dialog the turn cannot continue without until the screen is visible.
    ///
    /// Presenting a sheet from a controller that is not in the hierarchy does nothing at
    /// all, and the turn would then wait for an answer to a question nobody ever saw. The
    /// question is stored instead, the indicator says an answer is expected, and one tap on
    /// it brings the sheet up.
    private func deferUserPrompt(_ prompt: @escaping () -> Void) {
        deferredUserPrompt = prompt
        AorusAIActiveTurnCenter.shared.setNeedsAttention(true, key: activeTurnKey)
    }

    /// Hands this controller to the turn center so the answer keeps arriving after the
    /// screen is gone.
    ///
    /// Nothing else retains it once it is popped: the stream would be cancelled in `deinit`
    /// and the half-written answer would stay half-written, which is exactly the truncation
    /// the brief rules out. The center holds it instead, shows the working indicator, and
    /// the indicator's tap pushes this very instance back — never a second controller over
    /// the same messages.
    private func holdForBackgroundTurn() {
        AorusAIActiveTurnCenter.shared.hold(
            self,
            key: activeTurnKey,
            window: self.view.window ?? lastKnownWindow,
            theme: presentationData.theme,
            reopen: { [weak self] controller in
                // `navigationController` is UIKit's and is nil once this screen is popped,
                // so the stack it was pushed on is remembered while it is still on screen.
                self?.lastNavigationController?.pushViewController(controller)
            }
        )
    }

    /// Stops a turn whose conversation no longer exists.
    ///
    /// `isDiscarded` is set first, so nothing this teardown touches can write the deleted
    /// conversation back into the store.
    fileprivate func abortHeldTurn() {
        isDiscarded = true
        deferredUserPrompt = nil
        endBackgroundGrace(cancelTurn: false)
        stopGeneration()
    }

    /// The one place the turn state is acted upon outside the chat itself.

    ///
    /// A finished turn releases the hold, the background runtime and the indicator; a turn
    /// still running with no window on screen re-installs the hold, so a state change that
    /// happens while the user is elsewhere cannot leave the stream unowned.
    private func updateBackgroundPresence() {
        guard isTurnLive else {
            endBackgroundGrace(cancelTurn: false)
            // The hold may be the last reference to this controller, so it is dropped one
            // runloop later: releasing it here would deallocate `self` mid-method.
            let key = activeTurnKey
            DispatchQueue.main.async { [weak self] in
                AorusAIActiveTurnCenter.shared.release(key: key, controller: self)
            }
            return
        }
        if self.view.window == nil, lastKnownWindow != nil { holdForBackgroundTurn() }
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
        if dictation.isActive { dictation.stop() }
        // The turn is no longer killed on the way out. The app is given the documented
        // extra runtime instead, so an answer that is a second away from finishing does
        // finish, and only an expiring background task ends it — with its text kept.
        beginBackgroundGraceIfNeeded()
    }

    @objc private func appWillEnterForeground() {
        endBackgroundGrace(cancelTurn: false)
    }

    /// Buys a running turn the OS background allowance so the socket is not suspended
    /// mid-answer the moment the app leaves the foreground.
    private func beginBackgroundGraceIfNeeded() {
        guard isTurnLive, backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "AorusAI turn") { [weak self] in
            // The expiration handler can run on any thread, and everything it touches is
            // main-thread state.
            DispatchQueue.main.async {
                self?.endBackgroundGrace(cancelTurn: true)
            }
        }
    }

    /// Gives the background allowance back. `cancelTurn` is true only when the OS is about
    /// to take it away regardless — then the turn is closed with everything that already
    /// arrived preserved, never wiped.
    private func endBackgroundGrace(cancelTurn: Bool) {
        if cancelTurn, isTurnLive {
            if let turnId {
                AorusAIClient.shared.cancelTurn(turnId) { _ in }
            }
            finishStreaming(error: .offline, preserveText: true)
        }
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
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

    // The composer carries no brand row: the header already says AorusAI, and a second
    // badge inside the input only stole a line from the text, so there is nothing to
    // toggle when the input takes or loses focus.

    private func sendOrStop() {
        if streamHandle != nil || isPreparingRequest {
            stopGeneration()
        } else {
            send()
        }
    }

    private func send() {
        if dictation.isActive { dictation.stop() }
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
        let assistant = AorusAIMessage(role: .assistant, rawText: "", state: .streaming, statusLabel: aorusAILocalized("Подключение…", "Connecting…"))
        conversation.messages.append(userMessage)
        conversation.messages.append(assistant)
        if conversation.title.isEmpty { conversation.title = AorusAIFormat.title(from: text) }
        conversation.draft = ""
        conversation.updatedAt = Date()
        activeAssistantId = assistant.id
        isPreparingRequest = true
        // A new logical request starts with an empty tool ledger: results of the
        // previous turn must never travel with it.
        turnToolResults = []
        turnContinuationCount = 0
        pendingToolRequest = nil
        pendingPermissionRequest = nil
        toolExecutionDisposable.set(nil)
        turnState = .streaming
        composer.text = ""
        resolveDraftEntities(in: "")
        composer.reference = nil
        pendingReference = nil
        // Mentions are resolved on the device before the request leaves, so the model
        // is told who `@name` actually is instead of guessing from the handle.
        let mentioned = Self.mentionedUsernames(in: entities)
        if !mentioned.isEmpty, let index = conversation.messages.firstIndex(where: { $0.id == assistant.id }) {
            conversation.messages[index].statusLabel = aorusAILocalized("Читаю профиль диалога…", "Reading the chat profile…")
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
            conversation.messages[index].statusLabel = aorusAILocalized("Подключение…", "Connecting…")
        }
        // Everything before the two turns just appended is replayed context; the
        // payload itself trims it to the transport budget. It is frozen here so every
        // continuation of this logical request sends the identical conversation (§6).
        turnHistory = Array(conversation.messages.dropLast(2))
        turnTransportText = text
        dispatchTransport()
    }

    /// Sends the turn — the first request and every continuation go through here, so the
    /// accumulated `aorus_tool_results` are always attached and the body stays the
    /// documented one: same `messages`, one extra field (§6, §14).
    private func dispatchTransport() {
        // There is no path that reaches a continuation without a frozen request text, but a
        // silent return here would leave the turn live with no socket — a spinner and a
        // floating indicator that never end. Fail the turn instead of stalling it.
        guard let text = turnTransportText else {
            finishStreaming(error: .serverUnavailable, preserveText: true)
            return
        }
        let payload = AorusAIAgentPayload(history: turnHistory, text: text, toolResults: turnToolResults)
        turnState = .streaming
        streamHandle = AorusAIClient.shared.start(payload: payload, event: { [weak self] event in
            self?.handle(event)
        }, completion: { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result, error != .cancelled {
                self.finishStreaming(error: error, preserveText: true)
            } else if self.streamHandle != nil {
                // A successful HTTP EOF is not a successful agent turn by itself.
                // Only the protocol's explicit `done` event completes it — and when that
                // `done` announced a tool or a permission, the handle was already
                // released, so a legitimate immediate-stream EOF never lands here (§23).
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
                ? aorusAILocalized("Выполняю…", "Working…")
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
        case let .toolRequest(request):
            // §13: the tool is only executed once the immediate stream has closed with
            // `done(awaiting_tool)`, so a modal can never appear over a live socket.
            pendingToolRequest = request
            turnState = .awaitingTool(request)
            let label = request.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            conversation.messages[index].statusLabel = AorusAIFormat.safeStatus(
                (label?.isEmpty == false) ? (label ?? "") : Self.toolStatusLabel(for: request)
            )
        case let .toolResult(_, ok, label):
            // §8/§15: the backend's own bookkeeping is a transient status line, never a
            // chat message of its own.
            let visible = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            if ok, let visible, !visible.isEmpty {
                conversation.messages[index].statusLabel = AorusAIFormat.safeStatus(visible)
            }
        case let .permissionRequest(request):
            pendingPermissionRequest = request
            turnState = .awaitingPermission(request)
            conversation.messages[index].statusLabel = AorusAIFormat.safeStatus(
                aorusAILocalized("Нужно разрешение", "Permission needed")
            )
        case .responseDone:
            conversation.messages[index].statusLabel = nil
        case let .quota(quota):
            conversation.quotaResetAt = quota.resetAt
            scheduleQuotaResetIfNeeded()
            finishStreaming(error: .quota(quota), preserveText: true)
            return
        case let .done(ok, state):
            // §17: `ok` comes first, and `awaiting_tool` / `awaiting_permission` are
            // successful intermediate stops. A pending request counts as one too, so a
            // `done` without a `state` field can never strand a permission dialog.
            let awaiting = state == AorusAIAgentState.awaitingTool
                || state == AorusAIAgentState.awaitingPermission
                || pendingToolRequest != nil
                || pendingPermissionRequest != nil
            if ok, awaiting {
                suspendStreamForContinuation()
                conversation.updatedAt = Date()
                scheduleRender(messageId: id)
                beginPendingToolWork()
                return
            }
            pendingToolRequest = nil
            pendingPermissionRequest = nil
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
        // would still be dispatched a moment later. The same holds for a tool step: a
        // half-finished history read must not trigger a continuation.
        profileContextDisposable.set(nil)
        toolExecutionDisposable.set(nil)
        pendingToolRequest = nil
        pendingPermissionRequest = nil
        turnState = .idle
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
        turnState = .idle
        pendingToolRequest = nil
        pendingPermissionRequest = nil
        toolExecutionDisposable.set(nil)
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
        turnState = .idle
        pendingToolRequest = nil
        pendingPermissionRequest = nil
        toolExecutionDisposable.set(nil)
        pendingRenderWork?.cancel()
        pendingRenderWork = nil
        updateComposer()
        reloadMessage(id: id)
        persist(force: true)
    }

    // MARK: - Agent tool workflow

    /// Releases the socket of a finished immediate stream while keeping the turn alive.
    ///
    /// The backend closes the stream on purpose after `done(awaiting_*)` (§23), so the
    /// handle is dropped before the transport completion runs — otherwise that EOF would
    /// be reported as "server unavailable". `isPreparingRequest` keeps the composer in
    /// its stop state, so the user can abort the whole workflow at any point, and the
    /// server turn id is cleared because a continuation is a new agent invocation (§16).
    private func suspendStreamForContinuation() {
        streamHandle = nil
        isPreparingRequest = true
        turnId = nil
        turnState = .submittingToolResult
        updateComposer()
    }

    /// The transient status shown while a tool runs. Never a chat message (§15, §18).
    private static func toolStatusLabel(for request: AorusAIToolRequest) -> String {
        let handle = request.username.map { "@\($0)" } ?? ""
        if request.tool == AorusAITool.profileGet {
            return handle.isEmpty
                ? aorusAILocalized("Читаю профиль диалога…", "Reading the chat profile…")
                : aorusAILocalized("Читаю профиль \(handle)…", "Reading the profile of \(handle)…")
        }
        if request.tool == AorusAITool.chatHistory {
            return aorusAILocalized("Читаю переписку…", "Reading the chat…")
        }
        return aorusAILocalized("Выполняю…", "Working…")
    }

    private func setTurnStatus(_ text: String) {
        guard let id = activeAssistantId, let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        conversation.messages[index].statusLabel = AorusAIFormat.safeStatus(text)
        conversation.updatedAt = Date()
        reloadMessage(id: id)
        updateComposer()
    }

    /// Answers whatever the closed immediate stream asked for.
    private func beginPendingToolWork() {
        guard activeAssistantId != nil else { return }
        if let request = pendingToolRequest {
            pendingToolRequest = nil
            pendingPermissionRequest = nil
            execute(toolRequest: request)
            return
        }
        if let request = pendingPermissionRequest {
            pendingPermissionRequest = nil
            presentPermission(request)
            return
        }
        // `awaiting_*` without anything to answer. Not a network failure, so it never
        // shows the generic card (§22) — the turn ends with a truthful explanation.
        failTurn(
            text: aorusAILocalized(
                "Запрос не завершён: сервер не прислал ни инструмент, ни разрешение.",
                "The request was left unfinished: the server sent neither a tool nor a permission."
            ),
            code: "agent_awaiting_without_request"
        )
    }

    /// Runs one `tool.request` and submits its result, whatever the outcome (§4, §12).
    private func execute(toolRequest request: AorusAIToolRequest) {
        turnState = .awaitingTool(request)
        setTurnStatus(Self.toolStatusLabel(for: request))
        guard request.tool == AorusAITool.profileGet else {
            // A tool this build does not implement is reported truthfully rather than
            // guessed at, so the model knows it never ran and cannot invent its output.
            submit(toolResult: .failure(
                tool: request.tool,
                requestId: request.requestId,
                username: request.username,
                reason: "unsupported_tool"
            ))
            return
        }
        // §4: `telegram.profile.get` arrives with `requires_user_approval == false` and
        // must therefore run without any extra dialog. The flag is still honoured
        // literally, so the day the backend flips it the client asks first.
        if request.requiresUserApproval {
            presentToolApproval(request)
            return
        }
        executeProfileTool(request)
    }

    private func presentToolApproval(_ request: AorusAIToolRequest) {
        guard isOnScreen else {
            deferUserPrompt { [weak self] in self?.presentToolApproval(request) }
            return
        }
        let handle = request.username.map { "@\($0)" } ?? ""
        let label = request.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = (label?.isEmpty == false)
            ? (label ?? "")
            : (handle.isEmpty
                ? aorusAILocalized("AorusAI запрашивает данные профиля.", "AorusAI requests profile data.")
                : aorusAILocalized("AorusAI запрашивает данные профиля \(handle).", "AorusAI requests the profile data of \(handle)."))
        let sheet = UIAlertController(title: aorusAILocalized("Разрешить доступ?", "Allow access?"), message: message, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: aorusAILocalized("Разрешить", "Allow"), style: .default, handler: { [weak self] _ in
            self?.executeProfileTool(request)
        }))
        sheet.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel, handler: { [weak self] _ in
            self?.submit(toolResult: .denied(tool: request.tool, requestId: request.requestId, username: request.username))
        }))
        aorusAIPresentActionSheet(sheet, from: self)
    }

    /// §4: resolves the handle through the already authenticated Telegram session — no
    /// `t.me` request, no Safari, no server-side account — and builds the tool result
    /// from the fields the device actually has (§20).
    private func executeProfileTool(_ request: AorusAIToolRequest) {
        guard let username = request.username, !username.isEmpty else {
            submit(toolResult: .failure(tool: request.tool, requestId: request.requestId, username: request.username, reason: "missing_username"))
            return
        }
        setTurnStatus(Self.toolStatusLabel(for: request))
        let signal = profileFieldsSignal(username: username)
        |> timeout(6.0, queue: Queue.mainQueue(), alternate: .single(nil))
        |> deliverOnMainQueue
        toolExecutionDisposable.set(signal.start(next: { [weak self] fields in
            guard let self else { return }
            guard let fields else {
                // §12: a Telegram resolution failure is a tool failure, never a server
                // outage. The model is told, and the turn continues.
                self.setTurnStatus(aorusAILocalized("Не удалось найти профиль @\(username)", "Could not find the profile of @\(username)"))
                self.submit(toolResult: .failure(
                    tool: AorusAITool.profileGet,
                    requestId: request.requestId,
                    username: username,
                    reason: "telegram_profile_not_found"
                ))
                return
            }
            self.submit(toolResult: fields.toolResult(requestId: request.requestId, username: username))
        }))
    }

    /// §9: the buttons are exactly the server's `options`, in the server's order. The
    /// client never invents them, and Cancel is a real supported answer, not an error.
    private func presentPermission(_ request: AorusAIPermissionRequest) {
        turnState = .awaitingPermission(request)
        setTurnStatus(aorusAILocalized("Нужно разрешение", "Permission needed"))
        guard isOnScreen else {
            deferUserPrompt { [weak self] in self?.presentPermission(request) }
            return
        }
        let handle = request.username.map { "@\($0)" } ?? ""
        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = request.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sheet = UIAlertController(
            title: (title?.isEmpty == false)
                ? title
                : (handle.isEmpty
                    ? aorusAILocalized("Посмотреть переписку?", "Look at the chat?")
                    : aorusAILocalized("Посмотреть переписку с \(handle)?", "Look at the chat with \(handle)?")),
            message: (text?.isEmpty == false)
                ? text
                : aorusAILocalized(
                    "AorusAI получит только выбранный тобой объём сообщений для этого запроса.",
                    "AorusAI will only receive the amount of messages you choose for this request."
                ),
            preferredStyle: .actionSheet
        )
        for option in request.options {
            sheet.addAction(UIAlertAction(title: option.label, style: .default, handler: { [weak self] _ in
                self?.select(option: option, for: request)
            }))
        }
        if request.options.isEmpty {
            // A payload without options would leave a dialog the user cannot answer, so
            // the only safe reading of it is "nothing was offered": decline and let the
            // model continue with the data it already has.
            sheet.addAction(UIAlertAction(title: aorusAILocalized("Не передавать переписку", "Do not share the chat"), style: .default, handler: { [weak self] _ in
                self?.denyPermission(request)
            }))
        }
        // Cancel is added even when `allow_cancel` is false: an action sheet is
        // dismissible by tapping outside anyway, and a dismissal that answered nothing
        // would strand the turn forever.
        sheet.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel, handler: { [weak self] _ in
            self?.denyPermission(request)
        }))
        aorusAIPresentActionSheet(sheet, from: self)
    }

    private func select(option: AorusAIPermissionOption, for request: AorusAIPermissionRequest) {
        if option.isPeriod {
            presentPeriodPicker(for: request)
            return
        }
        executeHistoryTool(request: request, limit: option.limit, fromDate: nil, toDate: nil)
    }

    /// `mode == "period"` opens the native iOS date selection and turns it into the
    /// `from_date` / `to_date` tool arguments (§9).
    private func presentPeriodPicker(for request: AorusAIPermissionRequest) {
        let picker = AorusAIPeriodPickerController(
            theme: presentationData.theme,
            strings: presentationData.strings,
            onCancel: { [weak self] in
                self?.denyPermission(request)
            },
            onSelect: { [weak self] from, to in
                self?.executeHistoryTool(
                    request: request,
                    limit: AorusAIRequestLimits.chatHistoryMessageCount,
                    fromDate: Int64(from.timeIntervalSince1970),
                    toDate: Int64(to.timeIntervalSince1970)
                )
            }
        )
        present(picker, animated: true)
    }

    /// §11: a refusal is a normal continuation with `ok: false, denied: true`, never a
    /// network error and never a cancelled turn.
    private func denyPermission(_ request: AorusAIPermissionRequest) {
        setTurnStatus(aorusAILocalized("Переписка не передана", "The chat was not shared"))
        submit(toolResult: .denied(tool: request.tool, requestId: request.requestId, username: request.username))
    }

    /// Reads the approved slice of the conversation from the local Postbox and submits
    /// it in the shape the backend reads: `result.messages[].sender_name/.text` (§10).
    private func executeHistoryTool(request: AorusAIPermissionRequest, limit: Int?, fromDate: Int64?, toDate: Int64?) {
        turnState = .executingHistoryTool(request)
        setTurnStatus(aorusAILocalized("Читаю переписку…", "Reading the chat…"))
        guard let username = request.username, !username.isEmpty else {
            submit(toolResult: .failure(tool: request.tool, requestId: request.requestId, username: request.username, reason: "missing_username"))
            return
        }
        let requested = min(AorusAIRequestLimits.chatHistoryMessageCount, max(1, limit ?? 50))
        let context = self.context
        let strings = presentationData.strings
        let nameOrder = presentationData.nameDisplayOrder
        let unknownAuthor = aorusAILocalized("Сообщение", "Message")
        let signal = peerSignal(username: username)
        |> mapToSignal { peer -> Signal<[AorusAIHistoryLine]?, NoError> in
            guard let peer else {
                return .single(nil)
            }
            return aorusAIChatHistoryLines(
                context: context,
                peerId: peer.id,
                limit: requested,
                fromDate: fromDate,
                toDate: toDate,
                strings: strings,
                nameOrder: nameOrder,
                unknownAuthor: unknownAuthor
            )
            |> map { Optional($0) }
        }
        |> timeout(10.0, queue: Queue.mainQueue(), alternate: .single(nil))
        |> deliverOnMainQueue
        toolExecutionDisposable.set(signal.start(next: { [weak self] lines in
            guard let self else { return }
            guard let lines else {
                // §12: the chat could not be read on the device. Reported as a tool
                // failure so the model does not pretend it saw messages.
                self.submit(toolResult: .failure(
                    tool: AorusAITool.chatHistory,
                    requestId: request.requestId,
                    username: username,
                    reason: "telegram_chat_unavailable"
                ))
                return
            }
            self.submit(toolResult: .history(
                requestId: request.requestId,
                username: username,
                limit: requested,
                fromDate: fromDate,
                toDate: toDate,
                messages: lines.map { (sender: $0.sender, text: $0.text) }
            ))
        }))
    }

    /// §14: results accumulate for the whole logical request. The same tool answered
    /// twice replaces its earlier entry instead of duplicating it, and only the newest
    /// eight survive because that is all the backend reads.
    private func submit(toolResult result: AorusAIToolResult) {
        guard activeAssistantId != nil else { return }
        turnState = .submittingToolResult
        if let index = turnToolResults.firstIndex(where: { $0.tool == result.tool && $0.requestId == result.requestId }) {
            turnToolResults[index] = result
        } else {
            turnToolResults.append(result)
        }
        if turnToolResults.count > Self.maxAccumulatedToolResults {
            turnToolResults.removeFirst(turnToolResults.count - Self.maxAccumulatedToolResults)
        }
        continueTurn()
    }

    /// Re-posts the same request with the accumulated tool results (§6). The counter is
    /// what makes an infinite tool loop impossible (§31).
    private func continueTurn() {
        guard let id = activeAssistantId, conversation.messages.contains(where: { $0.id == id }) else { return }
        turnContinuationCount += 1
        guard turnContinuationCount <= Self.maxToolContinuations else {
            failTurn(
                text: aorusAILocalized(
                    "Запрос прерван: слишком много обращений к инструментам.",
                    "The request was stopped: too many tool round trips."
                ),
                code: "agent_tool_loop"
            )
            return
        }
        setTurnStatus(aorusAILocalized("Думаю…", "Thinking…"))
        dispatchTransport()
    }

    /// Ends the turn with a specific explanation instead of the generic unavailable card
    /// (§22). Anything the assistant already wrote is kept as a finished answer.
    private func failTurn(text: String, code: String) {
        guard let id = activeAssistantId, let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        let produced = !conversation.messages[index].rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !conversation.messages[index].artifacts.isEmpty
        if produced {
            completeStreaming(cancelled: false)
            return
        }
        conversation.messages[index].state = .failed
        conversation.messages[index].statusLabel = text
        conversation.messages[index].errorCode = code
        streamHandle?.cancelTransport()
        streamHandle = nil
        isPreparingRequest = false
        turnId = nil
        activeAssistantId = nil
        turnState = .idle
        pendingToolRequest = nil
        pendingPermissionRequest = nil
        toolExecutionDisposable.set(nil)
        pendingRenderWork?.cancel()
        pendingRenderWork = nil
        conversation.updatedAt = Date()
        updateComposer()
        reloadMessage(id: id)
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
        // `isPreparingRequest` changes without going through `turnState`, and it is part of
        // what makes a turn live, so the off-screen presence is re-checked here too. Both
        // paths are idempotent.
        updateBackgroundPresence()
    }

    /// The header carries the state of the turn, so the user can tell a working assistant
    /// from an idle one without hunting for a spinner inside the last bubble.
    private func updateHeaderStatus(quotaBlocked: Bool) {
        if dictation.isActive {
            headerView?.setStatus(aorusAILocalized("слушаю…", "listening…"), active: true)
            return
        }
        if streamHandle != nil || isPreparingRequest {
            let label = activeAssistantId
                .flatMap { id in conversation.messages.first(where: { $0.id == id })?.statusLabel }
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            headerView?.setStatus(label ?? aorusAILocalized("печатает…", "typing…"), active: true)
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
        if dictation.isActive {
            dictation.stop()
            return
        }
        guard streamHandle == nil, !isPreparingRequest else { return }
        self.displayNode.view.endEditing(true)
        dictationBaseText = composer.text
        dictationSpokenText = ""
        let locale = AorusAIDictation.locale(for: presentationData.strings.baseLanguageCode)
        composer.isDictating = true
        updateComposer()
        dictation.start(locale: locale, onText: { [weak self] text in
            self?.dictationSpokenText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }, onFailure: { [weak self] failure in
            self?.composer.isDictating = false
            self?.updateComposer()
            self?.presentError(failure.message)
        }, onFinish: { [weak self] in
            guard let self else { return }
            let base = self.dictationBaseText.trimmingCharacters(in: .whitespacesAndNewlines)
            let spoken = self.dictationSpokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !spoken.isEmpty {
                self.composer.text = base.isEmpty ? spoken : base + " " + spoken
            } else {
                self.composer.text = self.dictationBaseText
            }
            self.textViewDidChangeSilently()
            self.composer.isDictating = false
            self.dictationBaseText = self.composer.text
            self.dictationSpokenText = ""
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

    /// The peer behind `@name`, resolved through the authenticated Telegram session.
    ///
    /// §21: when this conversation already resolved the same handle into a peer id — the
    /// decorative entity in the user's own bubble — the peer is fetched by id instead of
    /// resolving the username a second time. `then(.single(nil))` guarantees exactly one
    /// value, so a tool step can never hang waiting for a signal that only completed.
    private func peerSignal(username: String) -> Signal<EnginePeer?, NoError> {
        let resolved: Signal<EnginePeer?, NoError>
        if let peerId = resolvedPeerId(forUsername: username) {
            resolved = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        } else {
            resolved = context.engine.peers.resolvePeerByName(name: username, referrer: nil)
            |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
                if case let .result(peer) = result {
                    return .single(peer)
                }
                return .complete()
            }
        }
        let fallback: Signal<EnginePeer?, NoError> = .single(nil)
        return resolved |> take(1) |> then(fallback) |> take(1)
    }

    private func resolvedPeerId(forUsername username: String) -> PeerId? {
        let needle = username.lowercased()
        for message in conversation.messages.reversed() {
            for entity in message.telegramEntities {
                guard let raw = entity.username?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")),
                      raw.lowercased() == needle,
                      let peerId = entity.peerId else { continue }
                return PeerId(peerId)
            }
        }
        return nil
    }

    /// The `telegram.profile.get` result source: only fields this device really has
    /// (§20). The about text and the member count are read the same way the mention
    /// context does it, so no new Telegram API surface is introduced.
    private func profileFieldsSignal(username: String) -> Signal<AorusAIProfileSummaryFields?, NoError> {
        let context = self.context
        let strings = self.presentationData.strings
        let nameOrder = self.presentationData.nameDisplayOrder
        return peerSignal(username: username)
        |> mapToSignal { peer -> Signal<AorusAIProfileSummaryFields?, NoError> in
            guard let peer = peer else {
                return .single(nil)
            }
            let basic = AorusAIProfileSummaryFields(
                displayName: peer.displayTitle(strings: strings, displayOrder: nameOrder),
                username: peer.addressName,
                kind: AorusAIChatController.profileKind(peer),
                about: nil,
                participantCount: nil,
                isVerified: peer.isVerified,
                isPremium: peer.isPremium,
                isScam: peer.isScam
            )
            let fallback: Signal<AorusAIProfileSummaryFields?, NoError> = .single(basic)
            let details: Signal<AorusAIProfileSummaryFields?, NoError> = combineLatest(
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
            |> map { data -> AorusAIProfileSummaryFields? in
                var fields = basic
                if case let .known(value) = data.0 {
                    fields.about = value
                }
                fields.participantCount = data.1
                return fields
            }
            return details |> timeout(2.5, queue: Queue.mainQueue(), alternate: fallback)
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
        // A conversation the user deleted while its turn was still running must not be
        // written back: the store is the source of truth and the deletion wins.
        guard !isDiscarded else { return }
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
        let canRetry = message.role == .assistant
            && row == conversation.messages.count - 1
            && (message.state == .failed || message.state == .complete)
        // §27: during streaming this method fires several times per second. Rebuilding the
        // whole cell drops the text selection and flickers, so try to push only the changed
        // text into the live views and let the table re-measure the height.
        if let cell = tableView.cellForRow(at: indexPath) as? AorusAIMessageCell,
           cell.applyIncremental(message: message, theme: presentationData.theme, canRetry: canRetry, loadingArtifactIds: loadingArtifactIds) {
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
            canRetry: message.role == .assistant
                && indexPath.row == conversation.messages.count - 1
                && (message.state == .failed || message.state == .complete),
            loadingArtifactIds: loadingArtifactIds
        )
        cell.onOpenLink = { [weak self] url in self?.open(url: url) }
        cell.onArtifact = { [weak self] artifact in self?.toggleArtifact(artifact) }
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

    /// Opens one artifact, or stops it when it is already being fetched.
    ///
    /// The loading state belongs to the controller, keyed by `artifactId`, because a cell
    /// is rebuilt on every reload — a streaming turn reloads its bubble several times a
    /// second — and each rebuild creates a brand new card. Per-card state could not
    /// survive that, which is exactly what used to leave a card spinning forever with no
    /// way out. Keeping the cancel handle here turns the second tap into a real stop.
    private func toggleArtifact(_ artifact: AorusAIArtifact) {
        if artifact.isExpired {
            presentError(AorusAIFormat.errorText(.artifactExpired))
            return
        }
        let id = artifact.artifactId
        if loadingArtifactIds.contains(id) {
            artifactDownloads.removeValue(forKey: id)?.cancel()
            setArtifactLoading(false, artifactId: id)
            return
        }
        setArtifactLoading(true, artifactId: id)
        let handle = AorusAIClient.shared.downloadArtifact(artifact) { [weak self] result in
            guard let self else { return }
            // A transfer the user stopped already cleared its own state, and a rejected
            // path answered before the handle was even stored: in both cases this id is
            // no longer loading and the answer is stale.
            guard self.loadingArtifactIds.contains(id) else { return }
            self.artifactDownloads.removeValue(forKey: id)
            self.setArtifactLoading(false, artifactId: id)
            switch result {
            case let .success(url):
                self.removePreviewArtifact()
                self.previewURL = url
                let preview = QLPreviewController()
                preview.dataSource = self
                preview.delegate = self
                self.present(preview, animated: true)
            case let .failure(error):
                guard error != .cancelled else { return }
                self.presentArtifactError(error, artifact: artifact)
            }
        }
        // A path the client refuses answers synchronously, before this line runs: the
        // completion has then already cleared the flag, so storing the handle would leave
        // a dead entry that turns the next tap into a cancel.
        if loadingArtifactIds.contains(id) {
            artifactDownloads[id] = handle
        }
    }

    private func setArtifactLoading(_ loading: Bool, artifactId: String) {
        if loading {
            loadingArtifactIds.insert(artifactId)
        } else {
            loadingArtifactIds.remove(artifactId)
        }
        for message in conversation.messages where message.artifacts.contains(where: { $0.artifactId == artifactId }) {
            reloadMessage(id: message.id)
        }
    }

    private func presentArtifactError(_ error: AorusAIClientError, artifact: AorusAIArtifact) {
        // A file the vault will never serve again is recorded as expired locally, so the
        // card stops offering a download it cannot deliver.
        if error == .artifactExpired || error == .artifactGone {
            markArtifactExpired(artifactId: artifact.artifactId)
        }
        let alert = UIAlertController(title: aorusAILocalized("Не удалось открыть файл", "Couldn't open file"), message: AorusAIFormat.errorText(error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        let isPermanent = error == .artifactExpired || error == .artifactGone || error == .artifactNotOwned
        if !isPermanent {
            alert.addAction(UIAlertAction(title: aorusAILocalized("Повторить", "Retry"), style: .default, handler: { [weak self] _ in
                self?.toggleArtifact(artifact)
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
        // A turn can finish while its screen is closed. There is nothing to present into
        // then, and the same text is already on the bubble, so the alert is simply skipped
        // instead of being thrown at a detached controller.
        guard self.view.window != nil else { return }
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
    private let glassView = UIVisualEffectView()
    private let placeholder = UILabel()
    private let referenceView = UIView()
    private let referenceLine = UIView()
    private let referenceLabel = UILabel()
    private let referenceClose = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let dictationButton = UIButton(type: .system)
    private let dictationWaveform = AorusAIWaveformView()
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
            placeholder.isHidden = isDictating || !newValue.isEmpty
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
    var isDictating = false {
        didSet {
            refreshDictationButton()
            dictationWaveform.isHidden = !isDictating
            textView.isHidden = isDictating
            placeholder.isHidden = isDictating || !text.isEmpty
            dictationWaveform.setAnimating(isDictating)
            setNeedsLayout()
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(container)
        glassView.isUserInteractionEnabled = false
        container.addSubview(glassView)
        [referenceView, dictationWaveform, dictationButton, textView, sendButton].forEach { container.addSubview($0) }
        referenceView.addSubview(referenceLine)
        referenceView.addSubview(referenceLabel)
        referenceView.addSubview(referenceClose)
        textView.addSubview(placeholder)
        placeholder.text = aorusAILocalized("Спросите что-нибудь…", "Ask anything…")
        placeholder.font = .systemFont(ofSize: 16)
        textView.font = .systemFont(ofSize: 16)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        referenceLabel.font = .systemFont(ofSize: 12)
        referenceLabel.numberOfLines = 1
        referenceLabel.lineBreakMode = .byTruncatingTail
        referenceClose.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        referenceClose.addTarget(self, action: #selector(closeReference), for: .touchUpInside)
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.accessibilityLabel = aorusAILocalized("Отправить", "Send")
        dictationButton.addTarget(self, action: #selector(dictate), for: .touchUpInside)
        dictationButton.accessibilityLabel = aorusAILocalized("Диктовать", "Dictate")
        dictationWaveform.isHidden = true
        referenceView.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(context: AccountContext, theme: PresentationTheme) {
        self.context = context
        self.theme = theme
        let palette = AorusAIPalette.resolve(theme)
        backgroundColor = palette.background
        glassView.effect = aorusAIGlassEffect(palette: palette)
        glassView.backgroundColor = aorusAIGlassTint(palette: palette)
        container.backgroundColor = .clear
        container.layer.cornerRadius = 24
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        container.layer.borderWidth = UIScreenPixel
        container.layer.borderColor = aorusAIGlassBorder(palette: palette).cgColor
        textView.textColor = palette.label
        textView.tintColor = palette.accent
        textView.keyboardAppearance = palette.isDark ? .dark : .light
        placeholder.textColor = palette.tertiary
        referenceLabel.textColor = palette.secondary
        referenceView.backgroundColor = .clear
        referenceLine.backgroundColor = palette.accent
        referenceClose.tintColor = palette.tertiary
        dictationWaveform.configure(accent: palette.secondary)
        applyMentionStyling()
        refreshButton()
        refreshDictationButton()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The design's composer sits 12pt from the screen edges and insets its text by a
        // further 16, so the placeholder lines up with the chip row above it.
        let side: CGFloat = 12
        let textInset: CGFloat = 16
        container.frame = CGRect(x: side, y: 0, width: bounds.width - side * 2, height: max(0, bounds.height - 8))
        glassView.frame = container.bounds
        let buttonSize = AorusAIComposerView.actionButtonSize
        let buttonY = container.bounds.height - buttonSize - 8
        sendButton.frame = CGRect(x: container.bounds.width - buttonSize - 12, y: buttonY, width: buttonSize, height: buttonSize)
        sendButton.layer.cornerRadius = buttonSize / 2.0
        let micSize = AorusAIComposerView.dictationButtonSize
        dictationButton.frame = CGRect(x: sendButton.frame.minX - micSize - 7, y: buttonY + floor((buttonSize - micSize) / 2.0), width: micSize, height: micSize)
        let refHeight: CGFloat = reference == nil ? 0 : 32
        referenceView.frame = CGRect(x: 14, y: 6, width: container.bounds.width - 28, height: refHeight)
        referenceLine.frame = CGRect(x: 0, y: 5, width: 2, height: max(0, refHeight - 10))
        referenceLine.layer.cornerRadius = 1
        referenceLabel.frame = CGRect(x: 9, y: 5, width: max(0, referenceView.bounds.width - 39), height: max(0, refHeight - 10))
        referenceClose.frame = CGRect(x: referenceView.bounds.width - 27, y: 3, width: 26, height: 26)
        let inputTop: CGFloat = refHeight == 0 ? 8 : 38
        let inputRight = dictationButton.frame.minX - 8
        textView.frame = CGRect(x: textInset, y: inputTop, width: max(0, inputRight - textInset), height: max(0, container.bounds.height - inputTop - 8))
        dictationWaveform.frame = CGRect(x: textInset, y: inputTop + 4, width: max(0, inputRight - textInset), height: max(20, container.bounds.height - inputTop - 16))
        placeholder.frame = CGRect(x: 0, y: 2, width: max(0, textView.bounds.width), height: 21)
    }

    private static let actionButtonSize: CGFloat = 32
    private static let dictationButtonSize: CGFloat = 26

    func requiredHeight(width: CGFloat) -> CGFloat {
        // 12pt page inset on each side, then the card's own 16pt text inset on each side.
        let available = max(100, width - 24 - 32)
        let measured = textView.sizeThatFits(CGSize(width: available, height: 132)).height
        let extras: CGFloat = reference == nil ? 0 : 34
        let containerHeight = min(184, max(56 + extras, ceil(measured) + 16 + extras))
        return containerHeight + 8
    }

    func invalidateHeight() {
        placeholder.isHidden = !textView.text.isEmpty
        applyMentionStyling()
        setNeedsLayout()
    }

    private func refreshButton() {
        // A filled accent circle with a plain glyph, as in the design: the tint lives in the
        // circle, so the same control reads as "send" and, mid-answer, as "stop".
        let palette = theme.map { AorusAIPalette.resolve($0) }
        let configuration = UIImage.SymbolConfiguration(pointSize: isGenerating ? 13 : 17, weight: .semibold)
        sendButton.setImage(UIImage(systemName: isGenerating ? "stop.fill" : "arrow.up")?.withConfiguration(configuration), for: .normal)
        sendButton.tintColor = palette?.onAccent ?? .white
        sendButton.backgroundColor = palette?.accent
        sendButton.isEnabled = isGenerating || canSend
        sendButton.alpha = sendButton.isEnabled ? 1 : 0.42
        sendButton.accessibilityLabel = isGenerating ? aorusAILocalized("Остановить", "Stop") : aorusAILocalized("Отправить", "Send")
    }

    private func refreshDictationButton() {
        let palette = theme.map { AorusAIPalette.resolve($0) }
        let name = isDictating ? "waveform" : "mic"
        dictationButton.setImage(UIImage(systemName: name)?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)), for: .normal)
        dictationButton.tintColor = isDictating ? palette?.accent : palette?.secondary
        dictationButton.accessibilityLabel = isDictating ? aorusAILocalized("Остановить диктовку", "Stop dictation") : aorusAILocalized("Диктовать", "Dictate")
    }

    /// Styles every resolved mention inside the input. The text itself is untouched, so
    /// what the transport sends is still exactly what the user typed; only the run that
    /// the client has proved is a real peer is drawn in the accent colour.
    private func applyMentionStyling() {
        guard let theme else { return }
        let palette = AorusAIPalette.resolve(theme)
        let plain = textView.text ?? ""
        let base: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: palette.label
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
            .foregroundColor: palette.accent
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

/// Compact dictation controls above the composer. Recognition stays in the existing
/// production pipeline; no intermediate transcript is rendered, and the final result is
/// committed to the draft only after the user confirms it.
private final class AorusAIDictationOverlayView: UIView {
    private let contentView = UIView()
    private let bottomPanel = UIView()
    private let glassView = UIVisualEffectView()
    private let cancelButton = UIButton(type: .system)
    private let finishButton = UIButton(type: .system)
    private let waveform = AorusAIWaveformView()
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        alpha = 0
        bottomPanel.layer.cornerCurve = .continuous
        cancelButton.setImage(UIImage(systemName: "xmark")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)), for: .normal)
        cancelButton.accessibilityLabel = aorusAILocalized("Отменить диктовку", "Cancel dictation")
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        finishButton.setImage(UIImage(systemName: "checkmark")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)), for: .normal)
        finishButton.accessibilityLabel = aorusAILocalized("Завершить диктовку", "Finish dictation")
        finishButton.addTarget(self, action: #selector(finish), for: .touchUpInside)
        addSubview(contentView)
        contentView.addSubview(bottomPanel)
        glassView.isUserInteractionEnabled = false
        bottomPanel.addSubview(glassView)
        [cancelButton, waveform, finishButton].forEach { bottomPanel.addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(theme: PresentationTheme) {
        let palette = AorusAIPalette.resolve(theme)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        glassView.effect = UIBlurEffect(style: palette.isDark ? .systemThinMaterialDark : .systemThinMaterialLight)
        glassView.backgroundColor = palette.elevated.withAlphaComponent(0.22)
        bottomPanel.backgroundColor = .clear
        bottomPanel.clipsToBounds = true
        bottomPanel.layer.borderWidth = UIScreenPixel
        bottomPanel.layer.borderColor = palette.separator.cgColor
        cancelButton.tintColor = palette.secondary
        cancelButton.backgroundColor = palette.fill
        finishButton.tintColor = palette.onAccent
        finishButton.backgroundColor = palette.accent
        waveform.configure(accent: palette.accent)
    }

    func present() {
        isHidden = false
        transform = CGAffineTransform(translationX: 0, y: 18)
        waveform.setAnimating(true)
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.2, options: [.beginFromCurrentState, .curveEaseOut]) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func dismiss(animated: Bool) {
        waveform.setAnimating(false)
        let changes = {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: 10)
        }
        let completion: (Bool) -> Void = { _ in
            self.isHidden = true
            self.transform = .identity
        }
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseIn], animations: changes, completion: completion)
        } else {
            changes()
            completion(true)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = bounds
        let safeBottom = safeAreaInsets.bottom
        let panelHeight: CGFloat = 64
        bottomPanel.frame = CGRect(x: 18, y: max(12, bounds.height - safeBottom - panelHeight - 14), width: max(0, bounds.width - 36), height: panelHeight)
        bottomPanel.layer.cornerRadius = panelHeight / 2
        glassView.frame = bottomPanel.bounds
        let closeSize: CGFloat = 40
        cancelButton.frame = CGRect(x: 10, y: floor((panelHeight - closeSize) / 2), width: closeSize, height: closeSize)
        cancelButton.layer.cornerRadius = closeSize / 2
        let stopSize: CGFloat = 42
        finishButton.frame = CGRect(x: bottomPanel.bounds.width - stopSize - 9, y: floor((panelHeight - stopSize) / 2), width: stopSize, height: stopSize)
        finishButton.layer.cornerRadius = stopSize / 2
        let waveformX = cancelButton.frame.maxX + 12
        waveform.frame = CGRect(x: waveformX, y: 12, width: max(0, finishButton.frame.minX - 12 - waveformX), height: panelHeight - 24)
    }

    @objc private func cancel() { onCancel?() }
    @objc private func finish() { onFinish?() }
}

/// The design's waveform: twenty 3pt accent bars with fixed heights, animated with a
/// staggered delay so it reads as a live meter instead of a random jitter.
private final class AorusAIWaveformView: UIView {
    private static let barHeights: [CGFloat] = [10, 22, 14, 30, 18, 34, 12, 26, 16, 30, 20, 12, 28, 18, 24, 14, 32, 16, 22, 10]
    private let bars: [UIView] = AorusAIWaveformView.barHeights.map { _ in UIView() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        bars.forEach { addSubview($0) }
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(accent: UIColor) {
        bars.forEach { $0.backgroundColor = accent }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let spacing: CGFloat = 3
        let barWidth: CGFloat = 3
        let totalWidth = barWidth * CGFloat(bars.count) + spacing * CGFloat(bars.count - 1)
        let originX = max(0, floor((bounds.width - totalWidth) / 2))
        for (index, bar) in bars.enumerated() {
            let height = min(AorusAIWaveformView.barHeights[index], bounds.height)
            bar.frame = CGRect(x: originX + CGFloat(index) * (barWidth + spacing), y: floor((bounds.height - height) / 2), width: barWidth, height: height)
            bar.layer.cornerRadius = barWidth / 2
        }
    }

    func setAnimating(_ animating: Bool) {
        guard animating else {
            bars.forEach { $0.layer.removeAnimation(forKey: "aorusWave") }
            return
        }
        for (index, bar) in bars.enumerated() {
            guard bar.layer.animation(forKey: "aorusWave") == nil else { continue }
            let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
            animation.values = [0.4, 1.0, 0.55, 1.0, 0.4]
            animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            animation.duration = 1.1
            animation.beginTime = CACurrentMediaTime() + Double(index % 7) * 0.09
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            bar.layer.add(animation, forKey: "aorusWave")
        }
    }
}

private final class AorusAIMessageCell: UITableViewCell, UITextViewDelegate {
    private enum BodySlot {
        case text(UITextView)
        case code(AorusAICodeCard)
        case quote(AorusAIQuoteCard)
        case separator
    }

    private let contentStack = UIStackView()
    private let bubble = UIVisualEffectView()
    private let bodyStack = UIStackView()
    private let statusLabel = UILabel()
    private let assistantActions = UIStackView()
    private let copyButton = UIButton(type: .system)
    private let regenerateButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let typingIndicator = AorusAITypingIndicatorView()
    private let noticeCard = AorusAINoticeCard()
    /// The 9pt round dot the design blinks at the tail of a streaming answer. It lives
    /// inside the last text view so it can sit exactly after the last glyph.
    private let streamCaret = UIView()
    private weak var caretHost: UITextView?
    var onOpenLink: ((URL) -> Void)?
    private var bubbleWidthConstraint: NSLayoutConstraint?
    private var bodyInsetConstraints: (top: NSLayoutConstraint, bottom: NSLayoutConstraint, leading: NSLayoutConstraint, trailing: NSLayoutConstraint)?
    /// The quoted Telegram message. The design draws it as its own full-width block above
    /// the bubble, not as a card nested inside one, so it lives in `contentStack`.
    private var referenceCard: AorusAIReferenceCard?
    private var slots: [BodySlot] = []
    private var slotValues: [String] = []
    private var structureSignature: String?
    private var configuredMessageId: UUID?
    private var configuredTextColor: UIColor = .white
    private var configuredAccent: UIColor = .white
    private var configuredTheme: PresentationTheme?
    private var copyText = ""
    var onArtifact: ((AorusAIArtifact) -> Void)?
    var onCopy: (() -> Void)?
    var onRetry: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        contentStack.axis = .vertical
        contentStack.spacing = 7
        bodyStack.axis = .vertical
        bodyStack.spacing = 8
        bubble.contentView.addSubview(bodyStack)
        // The design puts the progress line *above* the answer — "Читаю профиль диалога…"
        // is what the turn is doing before the text it produces, not a footnote under it.
        statusLabel.font = .systemFont(ofSize: 13.0)
        statusLabel.numberOfLines = 0
        contentStack.addArrangedSubview(statusLabel)
        contentStack.addArrangedSubview(bubble)
        noticeCard.isHidden = true
        noticeCard.onRetry = { [weak self] in self?.onRetry?() }
        contentStack.addArrangedSubview(noticeCard)
        assistantActions.axis = .horizontal
        assistantActions.spacing = 4
        assistantActions.alignment = .center
        copyButton.setTitle(aorusAILocalized("Копировать", "Copy"), for: .normal)
        regenerateButton.setTitle(aorusAILocalized("Ещё раз", "Again"), for: .normal)
        // A 12pt glyph next to the 13pt title. `UIImage(systemName:)` with no configuration
        // renders at the body text style — a 17pt glyph, which made the row half again as
        // tall as the design draws it.
        let actionSymbol = UIImage.SymbolConfiguration(pointSize: 12.0, weight: .medium)
        copyButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: actionSymbol), for: .normal)
        regenerateButton.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: actionSymbol), for: .normal)
        for button in [copyButton, regenerateButton] {
            button.titleLabel?.font = .systemFont(ofSize: 13.0)
            button.imageEdgeInsets = UIEdgeInsets(top: 0.0, left: -4.0, bottom: 0.0, right: 4.0)
            button.contentEdgeInsets = UIEdgeInsets(top: 5.0, left: 10.0, bottom: 5.0, right: 8.0)
            button.layer.cornerRadius = 8.0
            button.layer.cornerCurve = .continuous
            // `contentStack` stretches this row to the full body width, and a horizontal
            // stack with the default `.fill` distribution hands all of that width to its
            // buttons — which is why both of them were as wide as half the screen. Making
            // them hug their titles and letting the trailing spacer absorb the remainder
            // leaves two compact chips at the leading edge, as in the design.
            button.setContentHuggingPriority(.required, for: .horizontal)
            assistantActions.addArrangedSubview(button)
        }
        let actionsSpacer = UIView()
        actionsSpacer.setContentHuggingPriority(UILayoutPriority(1.0), for: .horizontal)
        actionsSpacer.setContentCompressionResistancePriority(UILayoutPriority(1.0), for: .horizontal)
        assistantActions.addArrangedSubview(actionsSpacer)
        // A spacer has no intrinsic size of its own, and the row is centre-aligned, so its
        // height is pinned to keep the layout unambiguous.
        actionsSpacer.heightAnchor.constraint(equalToConstant: 0.0).isActive = true
        copyButton.addTarget(self, action: #selector(copyAssistant), for: .touchUpInside)
        regenerateButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        assistantActions.isHidden = true
        contentStack.addArrangedSubview(assistantActions)
        retryButton.setTitle(aorusAILocalized("Повторить", "Retry"), for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        contentStack.addArrangedSubview(retryButton)
        contentView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        // 20pt gutters and 12/12 vertical margins: the design's `px-5` body with `space-y-6`
        // between turns, which two adjacent cells add up to.
        let bodyTop = bodyStack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10)
        let bodyBottom = bodyStack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10)
        let bodyLeading = bodyStack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 16)
        let bodyTrailing = bodyStack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -16)
        bodyInsetConstraints = (top: bodyTop, bottom: bodyBottom, leading: bodyLeading, trailing: bodyTrailing)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            bodyTop, bodyBottom, bodyLeading, bodyTrailing,
            noticeCard.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])
    }

    /// The padding inside the bubble. A user turn is a real bubble and keeps the design's
    /// `px-4 py-2.5`; an assistant turn has no bubble at all, so its text has to sit flush
    /// with the 20pt body gutter instead of being indented by a second inset.
    private func applyBodyInsets(isUser: Bool) {
        guard let insets = bodyInsetConstraints else { return }
        insets.top.constant = isUser ? 10.0 : 0.0
        insets.bottom.constant = isUser ? -10.0 : 0.0
        insets.leading.constant = isUser ? 16.0 : 0.0
        insets.trailing.constant = isUser ? -16.0 : 0.0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionStreamCaret()
    }

    /// Keeps the blinking dot on the last glyph of the answer while it grows.
    private func applyStreamCaret(message: AorusAIMessage, palette: AorusAIPalette) {
        var host: UITextView?
        if message.role == .assistant, message.state == .streaming {
            for slot in slots.reversed() {
                if case let .text(view) = slot {
                    host = view
                    break
                }
            }
        }
        guard let host else {
            streamCaret.isHidden = true
            streamCaret.layer.removeAnimation(forKey: "blink")
            streamCaret.removeFromSuperview()
            caretHost = nil
            return
        }
        streamCaret.backgroundColor = palette.label
        if streamCaret.superview !== host {
            streamCaret.removeFromSuperview()
            host.addSubview(streamCaret)
        }
        streamCaret.isHidden = false
        if streamCaret.layer.animation(forKey: "blink") == nil {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1.0
            animation.toValue = 0.15
            animation.duration = 0.55
            animation.autoreverses = true
            animation.repeatCount = .infinity
            streamCaret.layer.add(animation, forKey: "blink")
        }
        caretHost = host
        positionStreamCaret()
    }

    private func positionStreamCaret() {
        guard let host = caretHost, !streamCaret.isHidden else { return }
        let rect = host.caretRect(for: host.endOfDocument)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.height > 0.0 else { return }
        let size: CGFloat = 9.0
        streamCaret.frame = CGRect(x: rect.maxX + 2.0, y: rect.midY - size / 2.0, width: size, height: size)
        streamCaret.layer.cornerRadius = size / 2.0
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        typingIndicator.setAnimating(false)
        streamCaret.isHidden = true
        streamCaret.layer.removeAnimation(forKey: "blink")
        streamCaret.removeFromSuperview()
        caretHost = nil
        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        referenceCard?.removeFromSuperview()
        referenceCard = nil
        slots.removeAll()
        slotValues.removeAll()
        structureSignature = nil
        configuredMessageId = nil
        copyText = ""
        onOpenLink = nil; onArtifact = nil; onCopy = nil; onRetry = nil
    }

    /// Streaming path (§27): keeps the existing view tree and only pushes the text that
    /// actually changed. Returns false when the block structure moved and the caller has
    /// to fall back to a full rebuild.
    func applyIncremental(message: AorusAIMessage, theme: PresentationTheme, canRetry: Bool, loadingArtifactIds: Set<String>) -> Bool {
        guard configuredMessageId == message.id, configuredTheme === theme else { return false }
        let resolvedEntities = message.telegramEntities.filter { $0.peerId != nil }
        let displayText = AorusAIFormat.removingResolvedEntitySources(from: message.rawText, entities: resolvedEntities)
        let blocks = AorusAIMarkdown.blocks(displayText)
        guard Self.signature(blocks: blocks, message: message, entities: resolvedEntities, loadingArtifactIds: loadingArtifactIds) == structureSignature,
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
                card.configure(text: source, theme: theme, textColor: configuredTextColor, accentOnColor: false)
            default:
                return false
            }
        }
        statusLabel.text = message.statusLabel
        statusLabel.isHidden = message.statusLabel == nil
        copyText = message.rawText
        assistantActions.isHidden = !(message.role == .assistant && message.state == .complete && canRetry && !message.rawText.isEmpty)
        retryButton.isHidden = !(message.state == .failed && canRetry)
        applyNotice(message: message, theme: theme, canRetry: canRetry)
        applyStreamCaret(message: message, palette: AorusAIPalette.resolve(theme))
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

    private static func signature(blocks: [AorusAIMarkdownBlock], message: AorusAIMessage, entities: [AorusAITelegramEntity], loadingArtifactIds: Set<String>) -> String {
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
        // The loading flag is part of the structure: a card that started or stopped
        // downloading has to be rebuilt, otherwise the incremental path would keep the
        // old spinner on screen.
        parts.append("a:" + message.artifacts.map { "\($0.artifactId)/\($0.isExpired ? 1 : 0)/\(loadingArtifactIds.contains($0.artifactId) ? 1 : 0)" }.joined(separator: ","))
        return parts.joined(separator: "|")
    }

    func configure(message: AorusAIMessage, context: AccountContext, theme: PresentationTheme, canRetry: Bool, loadingArtifactIds: Set<String>) {
        let palette = AorusAIPalette.resolve(theme)
        backgroundColor = palette.background
        contentView.backgroundColor = palette.background
        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        referenceCard?.removeFromSuperview()
        referenceCard = nil
        slots.removeAll()
        slotValues.removeAll()
        let isUser = message.role == .user
        contentStack.alignment = isUser ? .trailing : .leading
        bubbleWidthConstraint?.isActive = false
        // A user bubble hugs its text; an assistant turn takes the full column, so code
        // cards, tables and quotes run edge to edge instead of sitting in a narrow strip.
        let bubbleWidthConstraint = isUser
            ? bubble.widthAnchor.constraint(lessThanOrEqualTo: contentStack.widthAnchor, multiplier: 0.85)
            : bubble.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        bubbleWidthConstraint.isActive = true
        self.bubbleWidthConstraint = bubbleWidthConstraint
        bubble.effect = isUser ? aorusAIGlassEffect(palette: palette) : nil
        bubble.backgroundColor = isUser ? aorusAIGlassTint(palette: palette, strong: true) : .clear
        bubble.layer.cornerRadius = isUser ? 20.0 : 0.0
        bubble.layer.cornerCurve = .continuous
        bubble.clipsToBounds = isUser
        bubble.layer.borderWidth = isUser ? UIScreenPixel : 0.0
        bubble.layer.borderColor = isUser ? aorusAIGlassBorder(palette: palette).cgColor : UIColor.clear.cgColor
        applyBodyInsets(isUser: isUser)

        if let reference = message.referencedMessage {
            let referenceView = AorusAIReferenceCard()
            referenceView.configure(reference: reference, context: context, theme: theme, accentOnColor: false)
            referenceView.onOpenPeer = { [weak self] peerId in
                guard let url = URL(string: "aorus-peer://\(peerId.toInt64())") else { return }
                self?.onOpenLink?(url)
            }
            // Above the bubble and full width: in the design the quote is its own block.
            contentStack.insertArrangedSubview(referenceView, at: 0)
            referenceView.translatesAutoresizingMaskIntoConstraints = false
            referenceView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            referenceCard = referenceView
        }

        let resolvedEntities = message.telegramEntities.filter { $0.peerId != nil }
        if !resolvedEntities.isEmpty {
            let entityRow = AorusAIEntityRowView()
            entityRow.configure(context: context, entities: resolvedEntities, theme: theme, accentOnColor: false)
            entityRow.onOpenPeer = { [weak self] peerId in
                guard let url = URL(string: "aorus-peer://\(peerId.toInt64())") else { return }
                self?.onOpenLink?(url)
            }
            bodyStack.addArrangedSubview(entityRow)
        }

        // The bubble is neutral in both roles now, so the text keeps the label colour and
        // links keep the accent — no white-on-accent special case.
        let textColor: UIColor = palette.label
        let accent: UIColor = palette.accent
        configuredTextColor = textColor
        configuredAccent = accent
        configuredTheme = theme
        configuredMessageId = message.id
        let displayText = AorusAIFormat.removingResolvedEntitySources(from: message.rawText, entities: resolvedEntities)
        let blocks = AorusAIMarkdown.blocks(displayText)
        structureSignature = Self.signature(blocks: blocks, message: message, entities: resolvedEntities, loadingArtifactIds: loadingArtifactIds)
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
                card.configure(text: value, theme: theme, textColor: textColor, accentOnColor: false)
                bodyStack.addArrangedSubview(card)
                slots.append(.quote(card))
            case .separator:
                let separator = UIView()
                separator.backgroundColor = palette.separator
                separator.heightAnchor.constraint(equalToConstant: UIScreenPixel).isActive = true
                bodyStack.addArrangedSubview(separator)
                slots.append(.separator)
            }
        }

        for artifact in message.artifacts {
            let card = AorusAIArtifactCard()
            card.configure(artifact: artifact, theme: theme, isLoading: loadingArtifactIds.contains(artifact.artifactId))
            card.onOpen = { [weak self] in
                self?.onArtifact?(artifact)
            }
            bodyStack.addArrangedSubview(card)
        }

        statusLabel.textColor = palette.tertiary
        statusLabel.text = message.statusLabel
        statusLabel.isHidden = message.statusLabel == nil
        retryButton.tintColor = palette.accent
        copyText = message.rawText
        // Flat text buttons, as in the design: no pill behind them, the tint carries the
        // affordance and the row stays quiet under the answer.
        for button in [copyButton, regenerateButton] {
            button.tintColor = palette.tertiary
            button.setTitleColor(palette.tertiary, for: .normal)
            button.backgroundColor = .clear
        }
        assistantActions.isHidden = !(message.role == .assistant && message.state == .complete && canRetry && !message.rawText.isEmpty)
        retryButton.isHidden = !(message.state == .failed && canRetry)
        applyNotice(message: message, theme: theme, canRetry: canRetry)
        applyStreamCaret(message: message, palette: palette)
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
    @objc private func copyAssistant() {
        guard !copyText.isEmpty else { return }
        UIPasteboard.general.string = copyText
        onCopy?()
    }
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
        let palette = AorusAIPalette.resolve(theme)
        for dot in dots {
            dot.backgroundColor = palette.tertiary
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

/// A compact native glass title capsule. The current generation state stays visible on a
/// quiet second line and crossfades without resizing the navigation bar.
private final class AorusAINavigationTitleView: UIView {
    private let glassView = UIVisualEffectView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()

    init(theme: PresentationTheme) {
        super.init(frame: .zero)
        glassView.isUserInteractionEnabled = false
        glassView.layer.cornerRadius = 20.0
        glassView.layer.cornerCurve = .continuous
        glassView.clipsToBounds = true
        glassView.layer.borderWidth = UIScreenPixel
        titleLabel.text = "AorusAI"
        titleLabel.font = .systemFont(ofSize: 14.0, weight: .semibold)
        titleLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        statusLabel.textAlignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(glassView)
        glassView.contentView.addSubview(titleLabel)
        glassView.contentView.addSubview(statusLabel)
        isAccessibilityElement = true
        accessibilityLabel = "AorusAI"
        update(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(theme: PresentationTheme) {
        let palette = AorusAIPalette.resolve(theme)
        glassView.effect = aorusAIGlassEffect(palette: palette)
        glassView.backgroundColor = aorusAIGlassTint(palette: palette)
        glassView.layer.borderColor = aorusAIGlassBorder(palette: palette).cgColor
        titleLabel.textColor = palette.label
        statusLabel.textColor = palette.secondary
    }

    func setStatus(_ text: String?, active _: Bool) {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        accessibilityValue = (value?.isEmpty == false) ? value : nil
        let update = {
            self.statusLabel.text = value
        }
        if statusLabel.text != value {
            UIView.transition(with: statusLabel, duration: 0.18, options: [.transitionCrossDissolve, .beginFromCurrentState], animations: update)
        } else {
            update()
        }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 174.0, height: 40.0) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = CGRect(x: max(0, floor((bounds.width - 174.0) / 2.0)), y: max(0, floor((bounds.height - 40.0) / 2.0)), width: min(174.0, bounds.width), height: min(40.0, bounds.height))
        glassView.frame = frame
        titleLabel.frame = CGRect(x: 14.0, y: 4.0, width: max(0, frame.width - 28.0), height: 18.0)
        statusLabel.frame = CGRect(x: 14.0, y: 21.0, width: max(0, frame.width - 28.0), height: 14.0)
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
        let palette = AorusAIPalette.resolve(theme)
        backgroundColor = palette.elevated
        layer.borderWidth = UIScreenPixel
        layer.borderColor = palette.separator.cgColor
        let accent = kind == .quota ? palette.accent : theme.list.itemDestructiveColor
        icon.image = UIImage(systemName: kind.iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))?
            .withTintColor(accent, renderingMode: .alwaysOriginal)
        titleLabel.textColor = palette.label
        titleLabel.text = kind.title
        bodyLabel.textColor = palette.secondary
        let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        bodyLabel.text = detail.isEmpty ? nil : detail
        bodyLabel.isHidden = detail.isEmpty
        retryButton.tintColor = palette.accent
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
        // The design's quote: a 14pt card on the fill surface with a 2pt accent edge, not
        // a bare rule in the margin.
        self.layer.cornerRadius = 14.0
        self.layer.cornerCurve = .continuous
        self.clipsToBounds = true
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 10.0, left: 0.0, bottom: 10.0, right: 0.0)
        textView.textContainer.lineFragmentPadding = 0
        addSubview(line)
        addSubview(textView)
        line.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 2.0),
            textView.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: 12.0),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14.0),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, theme: PresentationTheme, textColor: UIColor, accentOnColor: Bool) {
        let palette = AorusAIPalette.resolve(theme)
        let accent = accentOnColor ? UIColor.white.withAlphaComponent(0.8) : palette.accent
        backgroundColor = accentOnColor ? UIColor.white.withAlphaComponent(0.12) : palette.fill
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
        let accent = accentOnColor ? UIColor.white : AorusAIPalette.resolve(theme).accent
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

/// The Telegram message a turn was started from. The design draws it as a quote card:
/// a 14pt card on the fill surface with a 2pt accent edge, a small "Из Telegram · Имя"
/// caption and the quoted text below it. The caption is the tap target for the author's
/// profile — an avatar chip inside the card would compete with the answer next to it.
private final class AorusAIReferenceCard: UIView {
    private let line = UIView()
    private let label = UILabel()
    private let entityContainer = UIView()
    private var entityChip: AorusAIEntityChipView?
    private var entityCollapse: NSLayoutConstraint?
    var onOpenPeer: ((PeerId) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 3
        label.font = .systemFont(ofSize: 13.0)
        addSubview(line)
        addSubview(entityContainer)
        addSubview(label)
        [line, entityContainer, label].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 3.0),
            entityContainer.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: 8.0),
            entityContainer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            entityContainer.topAnchor.constraint(equalTo: topAnchor, constant: 1.0),
            label.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: 8.0),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: entityContainer.bottomAnchor, constant: 3.0),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3.0)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(reference: AorusAIReferencedMessage, context: AccountContext, theme: PresentationTheme, accentOnColor: Bool) {
        entityChip?.removeFromSuperview()
        entityChip = nil
        if entityCollapse == nil {
            let collapse = entityContainer.heightAnchor.constraint(equalToConstant: 0.0)
            collapse.priority = .required
            entityCollapse = collapse
        }
        line.backgroundColor = accentOnColor ? UIColor.white.withAlphaComponent(0.75) : theme.list.itemAccentColor
        label.textColor = accentOnColor ? UIColor.white.withAlphaComponent(0.88) : theme.list.itemSecondaryTextColor
        label.text = reference.text
        if let rawPeerId = reference.authorPeerId, rawPeerId != 0 {
            let name = reference.authorName ?? aorusAILocalized("Профиль", "Profile")
            let entity = AorusAITelegramEntity(peerId: rawPeerId, username: nil, displayName: name, sourceText: name, rangeLocation: 0, rangeLength: 0)
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
        let palette = AorusAIPalette.resolve(theme)
        backgroundColor = palette.fill
        layer.borderWidth = UIScreenPixel; layer.borderColor = palette.separator.cgColor
        languageLabel.text = language.flatMap { $0.isEmpty ? nil : $0.uppercased() } ?? "CODE"
        languageLabel.textColor = palette.tertiary
        codeView.textColor = palette.label
        codeView.text = code
        // Lay the code out at its natural width so nothing wraps; the scroll view
        // takes over when that width exceeds the card.
        let natural = codeView.sizeThatFits(CGSize(width: 10_000, height: 10_000))
        codeWidthConstraint?.constant = max(1, ceil(natural.width))
        copyButton.tintColor = palette.accent
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
    /// Fully declarative: the card owns no state of its own, so it can be thrown away and
    /// rebuilt on every reload without ever stranding a spinner. While the transfer runs
    /// the card stays tappable and says so — that tap is the stop button.
    func configure(artifact: AorusAIArtifact, theme: PresentationTheme, isLoading: Bool) {
        let palette = AorusAIPalette.resolve(theme)
        backgroundColor = palette.elevated
        layer.borderWidth = UIScreenPixel; layer.borderColor = palette.separator.cgColor
        // Icon and detail line come from the shared artifact flow, so the card, the
        // download path and the tests all agree on one description of a file.
        icon.image = UIImage(systemName: artifact.isExpired ? "clock.badge.xmark" : AorusAIArtifactFlow.iconName(for: artifact))
        icon.tintColor = artifact.isExpired ? palette.tertiary : palette.accent
        icon.isHidden = isLoading
        activity.color = palette.accent
        if isLoading { activity.startAnimating() } else { activity.stopAnimating() }
        titleLabel.textColor = palette.label; titleLabel.text = artifact.filename
        detailLabel.textColor = palette.secondary
        if isLoading {
            detailLabel.text = aorusAILocalized("Загрузка… нажмите, чтобы остановить", "Downloading… tap to stop")
        } else if artifact.isExpired {
            detailLabel.text = aorusAILocalized("Срок хранения файла истёк", "The file is no longer stored")
        } else {
            detailLabel.text = AorusAIArtifactFlow.cardDetail(for: artifact)
        }
        isAccessibilityElement = true
        accessibilityTraits = (artifact.isExpired && !isLoading) ? .staticText : .button
        accessibilityLabel = artifact.filename
        accessibilityValue = detailLabel.text
        if isLoading {
            accessibilityHint = aorusAILocalized("Останавливает загрузку", "Stops the download")
        } else {
            accessibilityHint = artifact.isExpired ? nil : aorusAILocalized("Открывает файл", "Opens the file")
        }
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
        // The design sets the answer at 16.5/26. The leading is expressed as line spacing
        // rather than a fixed line height so a serif heading in the same paragraph keeps
        // its own ascent instead of being clipped into a 26pt box.
        let output = NSMutableAttributedString(string: normalized, attributes: [.font: UIFont.systemFont(ofSize: 16.5), .foregroundColor: color])
        applyMarkdownLinks(in: output, accent: accent)
        apply(pattern: #"\*\*(.+?)\*\*"#, in: output, font: .systemFont(ofSize: 16.5, weight: .semibold))
        apply(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, in: output, font: .italicSystemFont(ofSize: 16.5))
        apply(pattern: #"(?<!\w)_([^_\n]+)_(?!\w)"#, in: output, font: .italicSystemFont(ofSize: 16.5))
        applyInlineCode(in: output, backgroundColor: accent.withAlphaComponent(0.12))
        applyHeadings(in: output)
        applyLinks(in: output, accent: accent)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6.0
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
            // Headings are the design's serif voice: 22 / 19 / 17, the same scale the
            // answer titles use in the mockup.
            let size: CGFloat = level == 1 ? 22.0 : (level == 2 ? 19.0 : 17.0)
            value.addAttribute(.font, value: aorusAISerifFont(size: size, weight: .semibold), range: NSRange(location: match.range.location, length: (text as NSString).length))
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

/// `mode == "period"` of a `permission.request`: two native date pickers in a glass
/// sheet.
///
/// Pure UIKit, so nothing new is pulled into this module, and it always answers: Done,
/// Cancel and a tap on the dimming each call exactly one callback exactly once, so a
/// suspended turn can never be stranded by a dismissed sheet.
private final class AorusAIPeriodPickerController: UIViewController {
    private let theme: PresentationTheme
    private let strings: PresentationStrings
    private let onCancel: () -> Void
    private let onSelect: (Date, Date) -> Void
    private var didAnswer = false

    private let dimView = UIView()
    private let card = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let fromRow = UIStackView()
    private let toRow = UIStackView()
    private let fromLabel = UILabel()
    private let toLabel = UILabel()
    private let fromPicker = UIDatePicker()
    private let toPicker = UIDatePicker()
    private let cancelButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    init(theme: PresentationTheme, strings: PresentationStrings, onCancel: @escaping () -> Void, onSelect: @escaping (Date, Date) -> Void) {
        self.theme = theme
        self.strings = strings
        self.onCancel = onCancel
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.backgroundColor = UIColor(white: 0.0, alpha: 0.35)
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cancelTapped)))

        // The same surfaces as every other AorusAI block: the elevated colour plus a
        // hairline separator border, no tint fills and no white.
        let palette = AorusAIPalette.resolve(theme)
        card.backgroundColor = palette.elevated
        card.layer.cornerRadius = 16.0
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = UIScreenPixel
        card.layer.borderColor = palette.separator.cgColor

        titleLabel.text = aorusAILocalized("Выберите период", "Choose a period")
        titleLabel.font = .systemFont(ofSize: 17.0, weight: .semibold)
        titleLabel.textColor = palette.label
        titleLabel.textAlignment = .center
        subtitleLabel.text = aorusAILocalized(
            "AorusAI получит сообщения только за эти даты.",
            "AorusAI will only receive messages from these dates."
        )
        subtitleLabel.font = .systemFont(ofSize: 13.0)
        subtitleLabel.textColor = palette.secondary
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        let now = Date()
        configure(picker: fromPicker, date: Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now, maximum: now)
        configure(picker: toPicker, date: now, maximum: now)
        configure(row: fromRow, label: fromLabel, title: aorusAILocalized("С", "From"), picker: fromPicker)
        configure(row: toRow, label: toLabel, title: aorusAILocalized("По", "To"), picker: toPicker)

        cancelButton.setTitle(strings.Common_Cancel, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17.0)
        cancelButton.tintColor = palette.accent
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        doneButton.setTitle(aorusAILocalized("Готово", "Done"), for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 17.0, weight: .semibold)
        doneButton.tintColor = palette.accent
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

        layout()
    }

    private func configure(picker: UIDatePicker, date: Date, maximum: Date) {
        picker.datePickerMode = .date
        picker.date = date
        picker.maximumDate = maximum
        picker.tintColor = AorusAIPalette.resolve(theme).accent
        // `.compact` keeps the sheet the height of two rows; on anything older the
        // system default (a wheel) is used and the row simply grows.
        if #available(iOS 13.4, *) {
            picker.preferredDatePickerStyle = .compact
        }
        picker.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configure(row: UIStackView, label: UILabel, title: String, picker: UIDatePicker) {
        label.text = title
        label.font = .systemFont(ofSize: 16.0)
        label.textColor = AorusAIPalette.resolve(theme).label
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12.0
        row.addArrangedSubview(label)
        row.addArrangedSubview(UIView())
        row.addArrangedSubview(picker)
    }

    private func layout() {
        let buttons = UIStackView(arrangedSubviews: [cancelButton, doneButton])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 12.0
        let content = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, fromRow, toRow, buttons])
        content.axis = .vertical
        content.spacing = 14.0
        content.setCustomSpacing(6.0, after: titleLabel)

        view.addSubview(dimView)
        view.addSubview(card)
        card.addSubview(content)
        [dimView, card, content].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16.0),
            card.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16.0),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12.0),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16.0),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16.0),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 16.0),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12.0)
        ])
    }

    @objc private func cancelTapped() {
        answer { [weak self] in
            self?.onCancel()
        }
    }

    @objc private func doneTapped() {
        // The order of the two pickers is not enforced while editing, so an inverted
        // range is normalised instead of rejected, and the upper bound covers the whole
        // chosen day — the user picked days, not seconds.
        let calendar = Calendar.current
        let first = min(fromPicker.date, toPicker.date)
        let last = max(fromPicker.date, toPicker.date)
        let from = calendar.startOfDay(for: first)
        let endOfDay = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: last)) ?? last
        let to = min(endOfDay, Date())
        answer { [weak self] in
            self?.onSelect(from, to)
        }
    }

    /// Exactly one answer per sheet: whichever way the user leaves, the suspended turn
    /// gets its tool result and never hangs.
    private func answer(_ action: @escaping () -> Void) {
        guard !didAnswer else { return }
        didAnswer = true
        if presentingViewController != nil {
            dismiss(animated: true, completion: {
                action()
            })
        } else {
            action()
        }
    }
}

// MARK: - Turns that outlive their screen

/// Keeps a running AorusAI turn alive after its screen is closed.
///
/// The chat controller owns the transport, and a controller that leaves the navigation stack
/// is released — its `deinit` cancels the stream, which is exactly why an answer used to be
/// cut off the moment the user swiped back. While a turn is in flight the controller is
/// retained here instead, off the stack: deltas keep arriving, every one of them is still
/// persisted, and the finished answer is complete in the store when the user comes back.
/// Re-entering the same conversation re-uses this instance rather than building a second
/// controller over the same messages.
private final class AorusAIActiveTurnCenter {
    static let shared = AorusAIActiveTurnCenter()

    private struct Entry {
        let controller: AorusAIChatController
        let reopen: (AorusAIChatController) -> Void
    }

    private var entries: [String: Entry] = [:]
    /// Newest hold last: the indicator speaks for the most recent turn.
    private var order: [String] = []
    private let indicator = AorusAIWorkingIndicator()
    private var attentionKeys: Set<String> = []

    private init() {}

    static func key(accountId: Int64, conversationId: UUID) -> String {
        return "\(accountId)/\(conversationId.uuidString)"
    }

    func liveController(forKey key: String) -> AorusAIChatController? {
        return entries[key]?.controller
    }

    /// Retains `controller` for as long as its turn runs and shows the working indicator.
    func hold(
        _ controller: AorusAIChatController,
        key: String,
        window: UIWindow?,
        theme: PresentationTheme,
        reopen: @escaping (AorusAIChatController) -> Void
    ) {
        entries[key] = Entry(controller: controller, reopen: reopen)
        order.removeAll(where: { $0 == key })
        order.append(key)
        indicator.present(in: window, theme: theme, text: text(forKey: key), onTap: { [weak self] in
            self?.reopenLatest()
        })
    }

    /// Drops the hold: the turn finished, or its screen is back on top and the navigation
    /// stack owns the controller again.
    ///
    /// `controller` guards against a stale release: a turn that ended schedules its release
    /// for the next runloop pass, and by then the same conversation may already be holding
    /// a newer turn that must not be dropped.
    func release(key: String, controller: AorusAIChatController?) {
        if let controller, let entry = entries[key], entry.controller !== controller { return }
        guard entries.removeValue(forKey: key) != nil else { return }
        order.removeAll(where: { $0 == key })
        attentionKeys.remove(key)
        if let latest = order.last {
            indicator.setText(text(forKey: latest))
        } else {
            indicator.dismiss()
        }
    }

    /// Stops the turn of a conversation the user deleted, so nothing writes it back into
    /// the store afterwards.
    func abortTurn(forKey key: String) {
        guard let entry = entries[key] else { return }
        entry.controller.abortHeldTurn()
        release(key: key, controller: entry.controller)
    }

    /// Marks a turn that is waiting for the user, so the indicator invites a tap instead of
    /// only spinning.
    func setNeedsAttention(_ needsAttention: Bool, key: String) {
        guard entries[key] != nil else { return }
        if needsAttention {
            attentionKeys.insert(key)
        } else {
            attentionKeys.remove(key)
        }
        if let latest = order.last {
            indicator.setText(text(forKey: latest))
        }
    }

    private func text(forKey key: String) -> String {
        if attentionKeys.contains(key) {
            return aorusAILocalized("AorusAI ждёт ответа", "AorusAI is waiting for you")
        }
        return aorusAILocalized("AorusAI отвечает…", "AorusAI is working…")
    }

    private func reopenLatest() {
        guard let key = order.last, let entry = entries[key] else {
            indicator.dismiss()
            return
        }
        entry.reopen(entry.controller)
    }
}

/// The floating "AorusAI is working" capsule.
///
/// It lives in the window, above whatever screen the user moved on to, and is the icon the
/// brief asks for: proof that the assistant is still working, plus one tap back to the
/// answer. Native glass only — the blocks background, a hairline border, no tint, no blur
/// and no white.
private final class AorusAIWorkingIndicator: NSObject {
    private let container = UIButton(type: .custom)
    private let activity = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private var onTap: (() -> Void)?
    /// A fade-out is in flight. A turn can end and the next one start inside those 0.2 s, so
    /// the removal at the end of the animation only runs if it was not cancelled meanwhile.
    private var isDismissing = false

    override init() {
        super.init()
        container.layer.cornerRadius = 18.0
        container.layer.cornerCurve = .continuous
        container.layer.borderWidth = UIScreenPixel
        container.accessibilityTraits = .button
        label.font = .systemFont(ofSize: 13.0, weight: .medium)
        label.isUserInteractionEnabled = false
        activity.isUserInteractionEnabled = false
        activity.hidesWhenStopped = false
        [activity, label].forEach { container.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 36.0),
            activity.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12.0),
            activity.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: activity.trailingAnchor, constant: 8.0),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14.0),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        container.addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    /// Installs the capsule in `window`, or just refreshes it when it is already there.
    func present(in window: UIWindow?, theme: PresentationTheme, text: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        self.isDismissing = false
        setText(text)
        let palette = AorusAIPalette.resolve(theme)
        container.backgroundColor = palette.elevated
        container.layer.borderColor = palette.separator.cgColor
        label.textColor = palette.label
        activity.color = palette.accent
        activity.startAnimating()
        guard let host = window ?? AorusAIWorkingIndicator.keyWindow() else { return }
        guard container.superview !== host else {
            container.isHidden = false
            // A cancelled fade-out can leave the capsule half-transparent and shifted down.
            UIView.animate(withDuration: 0.2, delay: 0.0, options: [.beginFromCurrentState, .curveEaseOut], animations: {
                self.container.alpha = 1.0
                self.container.transform = .identity
            })
            host.bringSubviewToFront(container)
            return
        }
        container.removeFromSuperview()
        container.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(container)
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 16.0),
            container.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -16.0),
            // Above the tab bar on the root screen, and comfortably clear of the composer
            // and the home indicator everywhere else.
            container.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -66.0)
        ])
        container.isHidden = false
        container.alpha = 0.0
        container.transform = CGAffineTransform(translationX: 0.0, y: 12.0)
        host.layoutIfNeeded()
        UIView.animate(withDuration: 0.25, delay: 0.0, options: [.beginFromCurrentState, .curveEaseOut], animations: {
            self.container.alpha = 1.0
            self.container.transform = .identity
        })
    }

    func setText(_ text: String) {
        label.text = text
        container.accessibilityLabel = text
    }

    func dismiss() {
        guard container.superview != nil, !isDismissing else { return }
        isDismissing = true
        UIView.animate(withDuration: 0.2, delay: 0.0, options: [.beginFromCurrentState, .curveEaseIn], animations: {
            self.container.alpha = 0.0
            self.container.transform = CGAffineTransform(translationX: 0.0, y: 12.0)
        }, completion: { _ in
            // A new turn may have re-presented the capsule while this fade-out ran.
            guard self.isDismissing else { return }
            self.isDismissing = false
            self.activity.stopAnimating()
            self.container.removeFromSuperview()
            self.container.transform = .identity
            self.container.alpha = 1.0
        })
    }

    @objc private func tapped() {
        onTap?()
    }

    /// The same window lookup the rest of the app uses for its overlays.
    private static func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene, windowScene.activationState == .foregroundActive else { continue }
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
            if let first = windowScene.windows.first {
                return first
            }
        }
        return nil
    }
}
