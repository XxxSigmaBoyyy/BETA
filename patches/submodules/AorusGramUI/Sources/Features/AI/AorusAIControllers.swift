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
import ComponentFlow
import GlassBackgroundComponent
import EdgeEffect

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
    // The rows state what they share rather than showing a bare number: this is now the
    // only dialog in the flow, so it is the one that has to say what is being agreed to.
    var choices: [ActionSheetButtonItem] = [20, 50, 100, limit].map { count in
        let title = aorusAILocalized(
            "Последние \(count) \(aorusAIMessageWord(count))",
            count == 1 ? "The last message" : "The last \(count) messages"
        )
        return ActionSheetButtonItem(title: title, color: .accent, action: { [weak sheet] in
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
/// What a message without text actually is, in one short phrase.
///
/// A chat is not a wall of text: it is voices, photos, files and round videos, and a
/// transcript that silently drops every one of them hands the model a conversation that
/// did not happen — and, in a chat of voice messages, hands it nothing at all. Each is
/// named for what it is, with its duration where that is the whole content.
private func aorusAIMediaCaption(_ message: Message) -> String? {
    for media in message.media {
        if let file = media as? TelegramMediaFile {
            var seconds: Int?
            for attribute in file.attributes {
                if case let .Audio(_, duration, _, _, _) = attribute {
                    seconds = duration
                }
            }
            // Formatted here rather than through `stringForDuration`: that lives in
            // TelegramStringFormatting, which this module neither imports nor depends on,
            // and a `m:ss` string is not worth a module boundary.
            let length = seconds.map { total -> String in
                let clamped = max(0, total)
                return String(format: " %d:%02d", clamped / 60, clamped % 60)
            } ?? ""
            if file.isVoice {
                return aorusAILocalized("голосовое\(length)", "voice message\(length)")
            }
            if file.isInstantVideo {
                return aorusAILocalized("видеосообщение\(length)", "video message\(length)")
            }
            if file.isSticker || file.isAnimatedSticker || file.isVideoSticker {
                return aorusAILocalized("стикер", "sticker")
            }
            if file.isMusic {
                let name = file.fileName.map { " " + $0 } ?? ""
                return aorusAILocalized("аудио\(name)", "audio\(name)")
            }
            if file.isAnimated {
                return aorusAILocalized("GIF", "GIF")
            }
            if file.isVideo {
                return aorusAILocalized("видео\(length)", "video\(length)")
            }
            let name = file.fileName.map { " " + $0 } ?? ""
            return aorusAILocalized("файл\(name)", "file\(name)")
        }
        if media is TelegramMediaImage {
            return aorusAILocalized("фото", "photo")
        }
        if media is TelegramMediaMap {
            return aorusAILocalized("геопозиция", "location")
        }
        if media is TelegramMediaContact {
            return aorusAILocalized("контакт", "contact")
        }
        if media is TelegramMediaPoll {
            return aorusAILocalized("опрос", "poll")
        }
        // A service message — someone joined, the title changed — is not part of the
        // conversation and is left out rather than described.
        if media is TelegramMediaAction {
            return nil
        }
    }
    return nil
}

/// Who said it. An outgoing message is "Я", not the account's own display name: the model
/// is being asked about the user's conversation, and "Я" is how the user refers to
/// themselves in it.
private func aorusAIHistorySender(_ message: Message, strings: PresentationStrings, nameOrder: PresentationPersonNameOrder, unknown: String) -> String {
    if !message.flags.contains(.Incoming) {
        return aorusAILocalized("Я", "Me")
    }
    return message.author.flatMap { EnginePeer($0).displayTitle(strings: strings, displayOrder: nameOrder) } ?? unknown
}

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
            let caption = aorusAIMediaCaption(message)
            // A message is skipped only when it is neither text nor recognisable media.
            // Dropping every voice and photo is what made a chat of voice messages come
            // out as a transcript of nothing.
            guard !body.isEmpty || caption != nil else { return true }
            let author = aorusAIHistorySender(message, strings: strings, nameOrder: nameOrder, unknown: unknownAuthor)
            let content: String
            if body.isEmpty {
                content = "[\(caption ?? "")]"
            } else {
                let clamped = body.count > perMessage ? String(body.prefix(perMessage)) + "…" : body
                content = caption.map { "[\($0)] \(clamped)" } ?? clamped
            }
            lines.append("\(author): \(content)")
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
    /// What the message is when it carries no text: `голосовое 0:12`, `фото`, `файл x.pdf`.
    var caption: String?
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
            let caption = aorusAIMediaCaption(message)
            guard !body.isEmpty || caption != nil else { return true }
            let author = aorusAIHistorySender(message, strings: strings, nameOrder: nameOrder, unknown: unknownAuthor)
            let clamped = body.count > perMessage ? String(body.prefix(perMessage)) + "…" : body
            lines.append(AorusAIHistoryLine(sender: author, text: clamped, caption: caption))
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
        // No second dialog. The amount was chosen a moment ago, in a sheet that said what
        // each choice shares; asking again for the same thing is not more consent, it is
        // the same consent collected twice.
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
            reference: reference,
            approvedHistory: (peerId: reference.peerId, limit: transcript.messageCount)
        ))
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
    private let profileNameDisposable = MetaDisposable()
    private var conversations: [AorusAIConversation] = []
    private var sections: [Section] = []
    private var searchQuery = ""
    private var observer: NSObjectProtocol?
    /// Lights and unlights the rows whose chat is working.
    private var activeTurnsObserver: NSObjectProtocol?
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
        // The same stock glass bar as the conversation screen, from Telegram's own
        // convenience initialiser rather than assembled by hand: the buttons come from the
        // input-panel control colour, the bar paints no background and no separator, and the
        // scroll-edge effect is the page colour over a progressive blur, so a row scrolling
        // up dissolves under the capsules instead of meeting a hard edge.
        super.init(navigationBarPresentationData: NavigationBarPresentationData(
            presentationData: presentationData,
            style: .glass
        ))
        self.title = "AorusAI"
        self.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
        // Telegram's navigation bar draws only `image` and `title` of a bar button item, so a
        // system item such as `.add` renders as an empty tap area — which is why the button
        // looked missing. The compose glyph is the one the chat list itself uses.
        //
        // Tinted with the colour the bar gives its own buttons, not with the palette's
        // secondary. A glass bar takes that from `chat.inputPanel.panelControlColor`
        // (ComponentsThemes), which is what the back chevron in the conversation is drawn in;
        // `palette.secondary` is the list's secondary *text* colour, and next to a white
        // chevron it read as a greyed-out, disabled button.
        let composeColor = presentationData.theme.chat.inputPanel.panelControlColor
        let composeImage = generateTintedImage(
            image: PresentationResourcesRootController.navigationComposeIcon(presentationData.theme)
                ?? UIImage(systemName: "square.and.pencil"),
            color: composeColor
        )
        let composeItem = UIBarButtonItem(image: composeImage, style: .plain, target: self, action: #selector(createConversation))
        composeItem.tintColor = composeColor
        composeItem.accessibilityLabel = aorusAILocalized("Новый диалог", "New chat")
        self.navigationItem.rightBarButtonItem = composeItem
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let activeTurnsObserver { NotificationCenter.default.removeObserver(activeTurnsObserver) }
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
        emptyView.configure(palette: palette)
        // A suggestion opens a new conversation with itself already in the input, so the
        // person lands on a cursor after the part they still have to write rather than on
        // an empty field they have to think at.
        emptyView.onStarter = { [weak self] starter in
            self?.openNewConversation(draft: starter.prompt)
        }
        tableView.backgroundView = emptyView
        self.displayNode.view.addSubview(tableView)

        searchField.configure(palette: palette, placeholder: aorusAILocalized("Поиск по диалогам", "Search chats"))
        searchField.textField.delegate = self
        searchField.textField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        self.displayNode.view.addSubview(searchField)

        observer = NotificationCenter.default.addObserver(forName: AorusAIStore.changedNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? NSNumber)?.int64Value == self.accountId else { return }
            self.reload()
        }
        // The set of chats with a live turn changed: only the rows' lit state depends
        // on it, so the visible ones are re-configured rather than the list rebuilt.
        activeTurnsObserver = NotificationCenter.default.addObserver(
            forName: AorusAIActiveTurnCenter.activeTurnsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            for indexPath in self.tableView.indexPathsForVisibleRows ?? [] {
                guard let cell = self.tableView.cellForRow(at: indexPath) as? AorusAIConversationCell else { continue }
                let rows = self.sections[indexPath.section].rows
                guard indexPath.row < rows.count else { continue }
                let conversation = rows[indexPath.row]
                cell.configure(
                    conversation: conversation,
                    palette: self.palette,
                    position: AorusAIGroupPosition.of(index: indexPath.row, count: rows.count),
                    isWorking: AorusAIActiveTurnCenter.shared.isBusy(conversationId: conversation.id)
                )
            }
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
        // The list runs to the bottom of the screen, the way every list in Telegram does.
        // A permanent 60pt bar holding a second "New chat" button sat under it, duplicating
        // the compose item in the navigation bar and taking a row's worth of the list with
        // it for the whole life of the screen.
        let tableTop = searchFrame.maxY + 12.0
        transition.updateFrame(view: tableView, frame: CGRect(x: 0.0, y: tableTop, width: layout.size.width, height: max(0.0, layout.size.height - tableTop)))
        tableView.contentInset = UIEdgeInsets(top: 0.0, left: 0.0, bottom: layout.intrinsicInsets.bottom + 12.0, right: 0.0)
        tableView.verticalScrollIndicatorInsets = UIEdgeInsets(top: 0.0, left: 0.0, bottom: layout.intrinsicInsets.bottom, right: 0.0)
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
        emptyView.topInset = headerHeight
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
        openNewConversation(draft: "")
    }

    /// Deliberately not an overload of `createConversation`: `#selector` names a method by
    /// its selector alone, so a second candidate with the same base name leaves it with no
    /// way to choose and the compose button stops compiling.
    private func openNewConversation(draft: String) {
        var conversation = AorusAIConversation()
        conversation.draft = draft
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

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "conversation", for: indexPath) as? AorusAIConversationCell else {
            assertionFailure("Unexpected AorusAI conversation cell type")
            return UITableViewCell(style: .default, reuseIdentifier: nil)
        }
        let rows = sections[indexPath.section].rows
        let conversation = rows[indexPath.row]
        cell.configure(
            conversation: conversation,
            palette: palette,
            position: AorusAIGroupPosition.of(index: indexPath.row, count: rows.count),
            // The row itself now says the assistant is working on this chat — the
            // floating capsule that used to say it has been retired.
            isWorking: AorusAIActiveTurnCenter.shared.isBusy(conversationId: conversation.id)
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
    private let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.cornerRadius = 19.0
        self.layer.cornerCurve = .continuous
        self.clipsToBounds = true
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
        // A plain filled capsule, the way iOS draws a search field: no blur to sample an
        // opaque page through and no outline around it.
        backgroundColor = palette.fill
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
        greetingLabel.font = aorusAITitleFont(size: 26.0, weight: .semibold)
        // "Добрый вечер, " plus a full display name does not fit one 26pt line on a
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
    /// The shimmer that says this chat is working: a highlight crossing the chat's NAME
    /// from left to right, and nothing else. A band over the whole row read as a blur
    /// sliding across the card — the row is a card of glass, and dragging a gradient
    /// over it smears it rather than lighting it.
    private let workingSweep = CAGradientLayer()
    /// The title drawn a second time, brighter, with the sweep as its mask. The base
    /// title underneath never changes, so the name stays legible at every moment of the
    /// animation instead of fading in and out.
    private let titleHighlight = UILabel()
    private var isWorkingState = false
    private var workingObserver: NSObjectProtocol?
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
        titleHighlight.isHidden = true
        titleHighlight.font = titleLabel.font
        titleHighlight.lineBreakMode = .byTruncatingTail
        // Left to right, across the name only.
        workingSweep.startPoint = CGPoint(x: 0.0, y: 0.5)
        workingSweep.endPoint = CGPoint(x: 1.0, y: 0.5)
        workingSweep.colors = [
            UIColor.clear.cgColor,
            UIColor.white.cgColor,
            UIColor.white.cgColor,
            UIColor.clear.cgColor
        ]
        workingSweep.locations = [0.0, 0.42, 0.58, 1.0]
        titleHighlight.layer.mask = workingSweep
        // iOS strips every animation off the layer tree when the app is backgrounded
        // and does not put it back, and a list row is not laid out again on return.
        workingObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restartWorkingSweep()
        }
        [titleLabel, dateLabel, previewLabel, chevronView, titleHighlight].forEach { cardView.addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let workingObserver {
            NotificationCenter.default.removeObserver(workingObserver)
        }
    }

    /// Turns the sweep on or off. The colours come from the page, so the band reads as
    /// the row lighting up rather than as a colour laid on top of it.
    private func setWorking(_ working: Bool, palette: AorusAIPalette) {
        isWorkingState = working
        titleHighlight.isHidden = !working
        guard working else {
            workingSweep.removeAnimation(forKey: "aorusConversationSweep")
            return
        }
        // A brighter pass of the same name — the page's own primary ink, never the
        // accent: a violet gleam is a second colour crossing the list, and the shimmer
        // is meant to read as the name lighting up rather than as something tinting it.
        //
        // The base is dropped to secondary for as long as the chat is working, so there
        // is something for the highlight to be brighter THAN. On a dark page that makes
        // it a white gleam over grey; on a light one, full black over grey. One rule,
        // and it reads on both.
        titleLabel.textColor = palette.secondary
        titleHighlight.textColor = palette.label
        titleHighlight.font = titleLabel.font
        titleHighlight.text = titleLabel.text
        restartWorkingSweep()
    }

    private func restartWorkingSweep() {
        guard isWorkingState, titleHighlight.bounds.width > 1.0 else { return }
        // Left alone while it is already running, so a reload of the list does not snap
        // the band back to its starting edge.
        guard workingSweep.animation(forKey: "aorusConversationSweep") == nil else { return }
        let travel = CABasicAnimation(keyPath: "transform.translation.x")
        travel.fromValue = -titleHighlight.bounds.width
        travel.toValue = titleHighlight.bounds.width
        travel.duration = 1.7
        travel.repeatCount = .infinity
        travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        workingSweep.add(travel, forKey: "aorusConversationSweep")
    }

    func configure(
        conversation: AorusAIConversation,
        palette: AorusAIPalette,
        position: AorusAIGroupPosition,
        isWorking: Bool = false
    ) {
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        cardView.configure(palette: palette, position: position, radius: 12.0, separatorInset: Self.contentInset)
        highlightView.backgroundColor = palette.fill
        titleLabel.textColor = palette.label
        previewLabel.textColor = palette.secondary
        dateLabel.textColor = palette.tertiary
        chevronView.tintColor = palette.tertiary.withAlphaComponent(0.7)
        titleLabel.text = conversation.title.isEmpty ? aorusAILocalized("Новый диалог", "New chat") : conversation.title
        // After the title and its colour are set: the shimmer is built from both, and
        // running it first meant the lines below quietly overwrote it.
        setWorking(isWorking, palette: palette)
        let preview = conversation.messages.last(where: { !$0.rawText.isEmpty })?.rawText
            ?? aorusAILocalized("Начните разговор с AorusAI", "Start a conversation with AorusAI")
        // A handle the session knows is written as the person here too — without the
        // avatar, which a scrolling row does not need.
        previewLabel.attributedText = AorusAIMentionRenderer.previewText(
            preview.replacingOccurrences(of: "\n", with: " "),
            color: palette.secondary,
            font: UIFont.systemFont(ofSize: 14.0),
            accent: palette.accent
        )
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
        // The highlight is the same name in the same place; only its mask moves.
        titleHighlight.frame = titleLabel.frame
        // The band is a third of the name wide. Set without an implicit animation: a
        // layer frame change inside a table reload would otherwise slide on its own.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        workingSweep.frame = CGRect(
            x: 0.0,
            y: 0.0,
            width: max(1.0, titleHighlight.bounds.width / 3.0),
            height: titleHighlight.bounds.height
        )
        CATransaction.commit()
        restartWorkingSweep()
        previewLabel.frame = CGRect(x: inset, y: 35.0, width: max(0.0, contentRight - inset), height: 19.0)
    }
}

/// One suggestion on the empty list: a real first thing to ask.
private final class AorusAIStarterRowView: UIControl {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let separator = UIView()
    private let highlight = UIView()

    static let height: CGFloat = 52.0
    private static let inset: CGFloat = 16.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        highlight.alpha = 0.0
        highlight.isUserInteractionEnabled = false
        addSubview(highlight)
        iconView.contentMode = .center
        titleLabel.font = .systemFont(ofSize: 16.0)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        [iconView, titleLabel, separator].forEach { addSubview($0) }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(symbol: String, title: String, isLast: Bool, palette: AorusAIPalette) {
        iconView.image = UIImage(systemName: symbol)?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 16.0, weight: .medium))
        iconView.tintColor = palette.accent
        titleLabel.text = title
        titleLabel.textColor = palette.label
        highlight.backgroundColor = palette.fill
        separator.backgroundColor = palette.separator
        separator.isHidden = isLast
        accessibilityLabel = title
        setNeedsLayout()
    }

    override var isHighlighted: Bool {
        didSet { highlight.alpha = isHighlighted ? 1.0 : 0.0 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        highlight.frame = bounds
        let inset = Self.inset
        iconView.frame = CGRect(x: inset, y: 0.0, width: 24.0, height: bounds.height)
        let titleX = inset + 24.0 + 12.0
        titleLabel.frame = CGRect(x: titleX, y: 0.0, width: max(0.0, bounds.width - titleX - inset), height: bounds.height)
        separator.frame = CGRect(x: titleX, y: bounds.height - UIScreenPixel, width: max(0.0, bounds.width - titleX), height: UIScreenPixel)
    }
}

/// The list before there is anything in it.
///
/// An icon over two lines of encouragement is the shape every empty state takes and it
/// leaves the person exactly where they were — with a blank screen and a compose button
/// somewhere else. This one does the screen's job instead: it offers the three things
/// AorusAI is actually for, each of which starts a conversation already asking. They are
/// the tools it has — reading a chat, looking someone up, producing a file — so the list
/// is a description of the product rather than decoration.
///
/// Searching is a different empty: there the person knows what they wanted, so the
/// suggestions step aside and it says only that nothing matched.
private final class AorusAIConversationListEmptyView: UIView {
    struct Starter {
        var symbol: String
        var title: String
        var prompt: String
    }

    static let starters: [Starter] = [
        Starter(
            symbol: "text.viewfinder",
            title: aorusAILocalized("Пересказать переписку", "Summarize a chat"),
            prompt: aorusAILocalized("Кратко перескажи мою переписку с ", "Briefly summarize my chat with ")
        ),
        Starter(
            symbol: "person.text.rectangle",
            title: aorusAILocalized("Рассказать о человеке", "Look someone up"),
            prompt: aorusAILocalized("Расскажи про ", "Tell me about ")
        ),
        Starter(
            symbol: "doc.badge.plus",
            title: aorusAILocalized("Сделать документ", "Make a document"),
            prompt: aorusAILocalized("Сделай презентацию про ", "Make a presentation about ")
        )
    ]

    private let noResultsLabel = UILabel()
    private let card = UIView()
    private var rows: [AorusAIStarterRowView] = []
    var onStarter: ((Starter) -> Void)?
    private var isSearching = false
    /// A table's background view spans the whole table, header included, so the greeting
    /// drawn above the list would otherwise sit on top of the card. This is that greeting's
    /// height, and the card starts below it.
    var topInset: CGFloat = 0.0 {
        didSet {
            guard abs(oldValue - topInset) > 0.5 else { return }
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        noResultsLabel.font = .systemFont(ofSize: 15.0)
        noResultsLabel.textAlignment = .center
        noResultsLabel.numberOfLines = 2
        noResultsLabel.text = aorusAILocalized("Ничего не найдено", "No results")
        noResultsLabel.isHidden = true
        [noResultsLabel, card].forEach { addSubview($0) }
        card.layer.cornerRadius = 18.0
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        for index in Self.starters.indices {
            let row = AorusAIStarterRowView()
            row.tag = index
            row.addTarget(self, action: #selector(starterTapped(_:)), for: .touchUpInside)
            card.addSubview(row)
            rows.append(row)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(palette: AorusAIPalette) {
        backgroundColor = palette.background
        noResultsLabel.textColor = palette.tertiary
        card.backgroundColor = palette.elevated
        for (index, row) in rows.enumerated() {
            row.configure(
                symbol: Self.starters[index].symbol,
                title: Self.starters[index].title,
                isLast: index == rows.count - 1,
                palette: palette
            )
        }
        setSearching(isSearching)
    }

    func setSearching(_ searching: Bool) {
        isSearching = searching
        noResultsLabel.isHidden = !searching
        card.isHidden = searching
        setNeedsLayout()
    }

    @objc private func starterTapped(_ sender: AorusAIStarterRowView) {
        let index = sender.tag
        guard index >= 0, index < Self.starters.count else { return }
        onStarter?(Self.starters[index])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = 16.0
        let width = max(0.0, bounds.width - side * 2.0)
        if isSearching {
            let height = ceil(noResultsLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            noResultsLabel.frame = CGRect(x: side, y: max(topInset + 24.0, floor((bounds.height - height) / 2.0) - 40.0), width: width, height: height)
            card.frame = CGRect(x: side, y: topInset, width: width, height: 0.0)
            return
        }
        // The card sits directly under the greeting the list header already draws, at the
        // top of the free space rather than floating in the middle of it: the screen reads
        // as "here is what to do first", not as a poster.
        let cardHeight = AorusAIStarterRowView.height * CGFloat(rows.count)
        card.frame = CGRect(x: side, y: topInset + 12.0, width: width, height: cardHeight)
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 0.0, y: AorusAIStarterRowView.height * CGFloat(index), width: width, height: AorusAIStarterRowView.height)
        }
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
    /// Where this chat's turn stands: the server's turn id, how far the journal has
    /// been applied, and when the server says the turn started. Resume rebuilds the
    /// answer from this rather than from a local stopwatch.
    private var turnCursor = AorusAITurnCursor()
    /// The turn whose terminal state has been shown and is waiting to be acknowledged.
    private var pendingAckTurnId: String?
    /// A turn whose socket died while the app was away, waiting to be re-attached.
    private var pendingResumeRecovery = false
    private var resumeAttempts = 0
    /// Whether the app is in the foreground, tracked rather than asked.
    ///
    /// Asking `UIApplication.shared.applicationState` at the moment a socket dies reads the
    /// state of an app that is in the middle of leaving: the notification that the user
    /// switched away has not arrived yet, so the answer is still `.active` and the recovery
    /// starts spending its three attempts on a connection that cannot exist. All three were
    /// gone within seven seconds, the turn was then settled as failed, and coming back showed
    /// "AorusAI временно недоступен" for a turn the server was very probably still running.
    private var isForeground = UIApplication.shared.applicationState == .active
    private var previewURL: URL?
    /// Artifacts currently being fetched, by `artifactId`. Owned by the controller, not
    /// by the card, because every reload builds new cards.
    private var loadingArtifactIds: Set<String> = []
    /// Real heights of rows the table has laid out, by message id. Bounded by the length
    /// of this one conversation, and an entry for a message that no longer exists is
    /// simply never read again.
    private var measuredRowHeights: [UUID: CGFloat] = [:]
    /// Sum of the above, kept as it is written. `estimatedHeightForRowAt` is asked for
    /// every row of a reload and for every row a scroll passes, so the average it reads
    /// must not walk the dictionary each time.
    private var measuredHeightTotal: CGFloat = 0.0
    /// Turns whose work trail the reader has unfolded. A view preference, so it lives
    /// here and never in the stored conversation.
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
    /// Which stream the live callbacks belong to. Bumped for every stream started, and
    /// compared inside that stream's own callbacks, so a stream that has been superseded
    /// cannot act on the turn that replaced it.
    private var streamGeneration = 0
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
    /// Set when the user abandons a run. `stop()` only asks the recogniser to end, and the
    /// final result it delivers afterwards would otherwise arrive as new spoken text and be
    /// written into the input the user just decided not to dictate into.
    private var dictationCancelled = false
    private var headerView: AorusAINavigationTitleView?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let composer = AorusAIComposerView()
    /// The blur the messages pass into at the top of the screen.
    ///
    /// This is `EdgeEffectView` — the exact component Telegram's own scroll-edge blur is made
    /// of, the one a glass navigation bar builds internally. It is instantiated here instead
    /// of being left to the bar because the bar's copy never showed on this screen and I
    /// could not see why; driven from here its geometry and its arguments are known.
    ///
    /// It is asked for `blur: true` with `alpha: 0.0`, and the alpha is the point. The view is
    /// a progressive backdrop blur with a flat rectangle of `content` drawn over it, and that
    /// rectangle is the fill: the navigation bar leaves it at the 0.75 default, which is what
    /// paints a fade. At zero there is no fill at all — only the blur.
    private let topBlurView = EdgeEffectView(frame: CGRect())

    /// `initialPrompt` is what the user sees in the conversation. `initialRequest`
    /// is what is actually sent when the two differ — a chat analysis shows a short
    /// instruction but transports the confirmed transcript with it.
    /// A conversation opened from the message menu arrives with the amount the user has
    /// just chosen for that exact chat. Its single use answers the backend's first request
    /// for that chat's history without asking again — the same consent, not a new one — and
    /// a request naming any other chat still gets the sheet.
    private var approvedHistory: (peerId: Int64, limit: Int)?

    init(context: AccountContext, conversation: AorusAIConversation, initialPrompt: String? = nil, initialRequest: String? = nil, reference: AorusAIReferencedMessage? = nil, approvedHistory: (peerId: Int64, limit: Int)? = nil) {
        self.approvedHistory = approvedHistory
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
        // The stock glass navigation bar, built by Telegram's own convenience initialiser.
        //
        // Everything here used to be assembled by hand, and every attempt to get the top of
        // the screen right was a guess at one of its arguments. `ComponentsThemes` already
        // does it, and for `style: .glass` it does more than pass colours through:
        //
        //   if case .glass = style {
        //       buttonColor = rootControllerTheme.chat.inputPanel.panelControlColor
        //       ...
        //       if edgeEffectColor == nil { edgeEffectColor = rootControllerTheme.list.plainBackgroundColor }
        //   }
        //
        // So a glass bar takes its button colour from the input panel, not from the legacy
        // navigation-bar colour, and its scroll-edge effect is the page colour, opaque, drawn
        // by `EdgeEffectView` at 0.75 over a real progressive blur. That is the recipe every
        // glass screen in the app uses — the call list, compose, contact selection, checkout,
        // the calendar — and `ItemListUI` passes the same colour explicitly.
        //
        // A chat is the exception, not the rule: `ChatController` passes `.clear`, which
        // switches the edge effect off, because it has a wallpaper behind its capsules and
        // does not need it. This screen is a flat page, so it takes the rule.
        super.init(navigationBarPresentationData: NavigationBarPresentationData(
            presentationData: presentationData,
            style: .glass
        ))
        // `title` stays unset because Telegram's navigation bar draws either the string or
        // the custom view, never both.
        let titleView = AorusAINavigationTitleView(theme: presentationData.theme)
        self.headerView = titleView
        self.navigationItem.titleView = titleView
        self.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
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
        self.displayNode.backgroundColor = palette.plainBackground
        tableView.backgroundColor = palette.plainBackground
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive
        // The list runs the full height of the screen and is inset instead, so messages
        // pass under the navigation capsules the way they do in a chat. Cut off at the bar
        // the strip above it was an empty band of page colour — the "black header".
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.estimatedRowHeight = 100
        tableView.rowHeight = UITableView.automaticDimension
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(AorusAIMessageCell.self, forCellReuseIdentifier: "message")
        self.displayNode.view.addSubview(tableView)
        topBlurView.isUserInteractionEnabled = false
        self.displayNode.view.addSubview(topBlurView)
        composer.configure(context: context, theme: presentationData.theme)
        composer.onOpenPeer = { [weak self] peerId in self?.openPeer(peerId) }
        composer.onHeightChanged = { [weak self] in
            guard let self, let layout = self.lastLayout else { return }
            self.applyLayout(layout, transition: .animated(duration: 0.2, curve: .easeInOut))
        }
        composer.textView.delegate = self
        composer.onSend = { [weak self] in self?.sendOrStop() }
        composer.onDictation = { [weak self] in self?.toggleDictation() }
        composer.onCancelDictation = { [weak self] in self?.cancelDictation() }
        composer.onDismissReference = { [weak self] in self?.pendingReference = nil; self?.composer.reference = nil }
        composer.text = conversation.draft
        composer.reference = pendingReference
        resolveDraftEntities(in: composer.text)
        self.displayNode.view.addSubview(composer)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        // Both edges of the transition, because the moment a socket dies is usually before
        // either of the two above: `willResignActive` is the first notice that the user is
        // leaving, and `didBecomeActive` is the first moment a new socket can actually be
        // opened. Recovering on `willEnterForeground` alone meant the first try was made
        // while the app was still `.inactive`, and anything that went wrong with it was
        // deferred to a foreground transition that had already happened.
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        if let initialPrompt, !initialPrompt.isEmpty { composer.text = initialPrompt }
        scheduleQuotaResetIfNeeded()
        updateComposer()
        self.displayNodeDidLoad()
        DispatchQueue.main.async { [weak self] in self?.jumpToNewestMessage(animated: false) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        lastKnownWindow = self.view.window
        lastNavigationController = self.navigationController as? NavigationController
        // The screen is back on top: the navigation stack owns this controller again, so the
        // off-screen hold is no longer needed.
        AorusAIActiveTurnCenter.shared.release(key: activeTurnKey, controller: self)
        // A turn the store still calls streaming is one the app was closed in the middle
        // of. Ask the server what became of it instead of declaring a failure the client
        // invented — and the same for one a dead socket already made this client call
        // failed, which is a guess the server can still correct.
        resumeTurnIfNeeded()
        reopenTurnLostToTheSocket()
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
        // The microphone does not stay open behind a screen the user has left. Nothing else
        // closed it: the only other stop is on entering the background, and a running turn
        // deliberately keeps this controller alive past the pop, so `deinit` could be
        // arbitrarily far away. Cancelled rather than finished — words spoken at a screen
        // that is going away should not type themselves into the draft.
        if dictation.isActive { cancelDictation() }
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
    /// The conversation this controller speaks for. The turn center needs it to say
    /// which row in the list is working.
    fileprivate var conversationIdentifier: UUID { conversation.id }

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
        // Read before anything moves: both the frame and the insets are about to change, and
        // the question is where the reader was, not where they end up.
        let wasAtBottom = isScrolledToBottom()
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        let bottomInset = max(layout.intrinsicInsets.bottom, keyboardHeight)
        let composerHeight = composer.requiredHeight(width: layout.size.width)
        let composerFrame = CGRect(x: 0, y: layout.size.height - bottomInset - composerHeight, width: layout.size.width, height: composerHeight)
        transition.updateFrame(view: composer, frame: composerFrame)
        // The list starts at the very top of the screen and is inset by the bar rather than
        // starting under it. That is the whole difference between this and a chat: there the
        // messages slide beneath the floating capsules, here they used to stop at a hard
        // edge and leave a flat band of page colour above it.
        transition.updateFrame(view: tableView, frame: CGRect(x: 0, y: 0, width: layout.size.width, height: max(0, composerFrame.minY)))
        // The same four numbers NavigationBarImpl computes for its own edge effect, so this
        // is the app's treatment and not an approximation of it:
        //
        //     edgeEffectHeight = barHeight + 24
        //     frame            = (0, -20, width, 20 + edgeEffectHeight)
        //     edgeSize         = min(64, edgeEffectHeight)
        //
        // The `edgeSize` cap is the part that matters and the part I had wrong. It becomes
        // `constantHeight = edgeSize - 4` inside the blur, which is the depth at which the
        // blur is at full strength; the rest of the view is its falloff. Passing the whole
        // height, as this did, left a four-point falloff on a hundred-point view — a wall of
        // blur with a hard edge along the bottom. Capped at 64 the blur is solid for sixty
        // points and dissolves over the seventy below, which is what a scroll edge looks
        // like everywhere else in the app.
        let edgeEffectHeight = top + 24.0
        let topBlurFrame = CGRect(x: 0.0, y: -20.0, width: layout.size.width, height: 20.0 + edgeEffectHeight)
        transition.updateFrame(view: topBlurView, frame: topBlurFrame)
        topBlurView.update(
            content: palette.plainBackground,
            blur: true,
            // 0.75 is the value NavigationBarImpl leaves at its default, and it is the
            // darkening: the page's own colour through the edge gradient, so a line of text
            // fades into the page as it rises instead of staying bright under the capsules.
            // It cannot read as a band — the colour is the one already behind it.
            alpha: 0.75,
            rect: CGRect(origin: CGPoint(), size: topBlurFrame.size),
            edge: .top,
            edgeSize: min(64.0, edgeEffectHeight),
            transition: .immediate
        )
        tableView.contentInset = UIEdgeInsets(top: top + 8.0, left: 0.0, bottom: 8.0, right: 0.0)
        // A read-modify-write on `scrollIndicatorInsets` goes through a getter the SDK
        // deprecated in iOS 13, so assign the vertical insets directly instead.
        tableView.verticalScrollIndicatorInsets = UIEdgeInsets(top: top, left: 0.0, bottom: 8.0, right: 0.0)
        // Changing the top inset moves the content under the reader. A list that was at the
        // newest message stays there — which is where a chat always is when the keyboard
        // opens or the composer grows.
        if wasAtBottom {
            stickToBottom()
        }
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

    @objc private func appWillResignActive() {
        isForeground = false
    }

    /// The app is genuinely back on screen. This is where a turn is re-attached.
    ///
    /// Everything the recovery gave up on while the app was away is forgiven here: the
    /// allowance is handed back in full, because none of it was ever spent on a connection
    /// that had a chance. Then the server is asked what became of the turn — including for a
    /// turn this client already gave up on, which is the case that made returning to the app
    /// show an error for work the server had very likely finished.
    @objc private func appDidBecomeActive() {
        isForeground = true
        pendingResumeRecovery = false
        resumeAttempts = 0
        resumeTurnIfNeeded()
        reopenTurnLostToTheSocket()
    }

    @objc private func appWillEnterForeground() {
        endBackgroundGrace(cancelTurn: false)
        // The socket does not survive being suspended, so a turn that was live when the app
        // went away is re-attached here rather than left to look broken. `resumeTurnIfNeeded`
        // does nothing when a stream is already running.
        //
        // A drop that happened while the app was away deliberately attempted nothing at
        // the time, so its allowance is untouched and the first try happens now.
        if pendingResumeRecovery {
            pendingResumeRecovery = false
            resumeAttempts = 0
        }
        resumeTurnIfNeeded()
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
        // `composer.text` — not `textView.text` — because the input draws resolved handles
        // as avatars, and the draft has to be the handles the user actually typed.
        let source = composer.text
        conversation.draft = source
        conversation.updatedAt = Date()
        composer.invalidateHeight()
        resolveDraftEntities(in: source)
        if let layout = lastLayout { applyLayout(layout, transition: .immediate) }
        updateComposer()
        persist(force: false)
    }

    /// A mention pill is one object as far as editing is concerned.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard textView === composer.textView else { return true }
        return composer.handleTextChange(in: range, replacement: text)
    }

    /// Keeps the pill's attributes from becoming the attributes of what is typed next.
    ///
    /// `UITextView` re-reads `typingAttributes` from the character before the caret on every
    /// selection change, and after a pill is rendered the caret sits right after one. Without
    /// this, the next characters typed carry the pill's colour, its semibold name font and —
    /// the part that mattered — its mention attribute, so they merged into the pill's run and
    /// were rebuilt as part of the handle instead of as themselves.
    func textViewDidChangeSelection(_ textView: UITextView) {
        guard textView === composer.textView else { return }
        composer.resetTypingAttributes()
        // Moving the caret off the end of a half-written handle is what finishes it, and
        // no text changed to say so. The composer's signature check makes every other
        // caret move — which is nearly all of them — cost nothing.
        composer.refreshMentionStyling()
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
        // Born with no status. The turn starts as the typing indicator alone, and the first
        // thing written on that line is the agent's own first phase.
        let assistant = AorusAIMessage(role: .assistant, rawText: "", state: .streaming)
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
        // No client-written progress line here. The status row belongs to the agent: it
        // says what the AGENT reported, and a sentence this client made up about its own
        // preparation is not that. The typing indicator already says the turn is alive.
        let mentioned = Self.mentionedUsernames(in: entities)
        updateComposer()
        tableView.reloadData()
        jumpToNewestMessage(animated: true)
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
        // No "Подключение…" here. The status line is the agent saying what it is doing,
        // and opening a socket is not that — it is this client's own plumbing, shown to
        // the reader for the fraction of a second before the first real phase lands. The
        // typing indicator already says the turn is alive.
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
        // Every call here opens a NEW event stream — the first one of a turn, and one more
        // after each tool or permission round trip. Frames are numbered per stream, so the
        // sequence mark starts over with it.
        turnCursor.beginStream()
        // There is no path that reaches a continuation without a frozen request text, but a
        // silent return here would leave the turn live with no socket — a spinner and a
        // floating indicator that never end. Fail the turn instead of stalling it.
        guard let text = turnTransportText else {
            finishStreaming(error: .serverUnavailable, preserveText: true)
            return
        }
        // Read straight off the conversation rather than frozen with the rest of the turn:
        // this controller owns exactly one chat for its whole life — the compose button
        // builds a new conversation and pushes a new controller — so there is no moment at
        // which a continuation could carry a different chat's id.
        let payload = AorusAIAgentPayload(
            history: turnHistory,
            text: text,
            toolResults: turnToolResults,
            threadId: conversation.threadId
        )
        turnState = .streaming
        // Every stream carries the number of the one that started it, and its callbacks do
        // nothing once that number has moved on.
        //
        // Identity was missing, and the comment below assumed the old stream's completion
        // could only arrive while `streamHandle` was still nil. It cannot: the completion is
        // delivered asynchronously, while a continuation is dispatched *synchronously* from
        // `handle(.done)`. So a `done(awaiting_tool)` ran the whole tool round trip and
        // started the next stream on the same main-thread turn, and the previous stream's
        // EOF then landed, saw a non-nil handle — the new one — and killed the continuation
        // with "AorusAI временно недоступен". Tapping Stop and sending again immediately did
        // the same thing to the new turn.
        streamGeneration += 1
        // A fresh turn starts with a clean allowance: the attempts belong to one dropped
        // turn, not to the chat.
        resumeAttempts = 0
        pendingResumeRecovery = false
        let generation = streamGeneration
        streamHandle = AorusAIClient.shared.start(payload: payload, event: { [weak self] event, frame in
            guard let self, self.streamGeneration == generation else { return }
            self.receive(event, frame: frame)
        }, completion: { [weak self] result in
            guard let self, self.streamGeneration == generation else { return }
            if case let .failure(error) = result, error != .cancelled {
                self.recoverOrFail(error: error)
            } else if self.streamHandle != nil {
                // A successful HTTP EOF is not a successful agent turn by itself. Only the
                // protocol's explicit `done` event completes it, and a `done` that announced
                // a tool or a permission has already moved the generation on, so a
                // legitimate intermediate stop never lands here.
                //
                // "обрыв транспорта ≠ done": the socket closing early says nothing about
                // the turn, which the server is still running. Re-attach rather than
                // report a failure — the same path a dropped connection takes.
                self.recoverOrFail(error: .serverUnavailable)
            }
        })
        isPreparingRequest = false
        updateComposer()
        if streamHandle == nil { finishStreaming(error: .notProvisioned, preserveText: false) }
    }

    /// Bounds on the work trail. A turn that announced without end would otherwise grow
    /// the message, the encrypted history file and every view built from it forever — the
    /// same reason the response text is capped.
    private static let maximumWorkPhases = 64
    private static let maximumWorkFilesPerPhase = 400

    /// Opens a new stretch of work, or leaves the current one alone when the label has
    /// not actually changed — the backend repeats a label while it is still current.
    private func beginWorkPhase(_ label: String?, at index: Int) {
        guard let label, !label.isEmpty else { return }
        guard conversation.messages[index].workPhases.last?.label != label else { return }
        guard conversation.messages[index].workPhases.count < Self.maximumWorkPhases else { return }
        conversation.messages[index].workPhases.append(AorusAIWorkPhase(label: label))
    }

    /// Files belong to the stretch that was current when they were reported. A file that
    /// arrives before any label does gets a stretch of its own so it is never dropped.
    private func appendWorkFile(_ change: AorusAIFileChange, at index: Int) {
        if conversation.messages[index].workPhases.isEmpty {
            let label = conversation.messages[index].statusLabel
                ?? aorusAILocalized("Работаю…", "Working…")
            conversation.messages[index].workPhases.append(AorusAIWorkPhase(label: label))
        }
        let last = conversation.messages[index].workPhases.count - 1
        guard conversation.messages[index].workPhases[last].files.count < Self.maximumWorkFilesPerPhase else {
            return
        }
        conversation.messages[index].workPhases[last].files.append(change)
    }

    /// The one door every event comes through, live or replayed.
    ///
    /// Applies the contract's deduplication before the reducer sees anything:
    /// "Дедуп по (turn_id, seq), не по тексту. seq <= lastAppliedSeq — пропуск."
    /// Deduplicating on the text instead would throw away a delta the model genuinely
    /// repeated, which is why the sequence number is carried down from the SSE frame.
    private func receive(_ event: AorusAIEvent, frame: AorusAIFrame) {
        // The resume envelope is turn metadata and is handled before the cursor: it is
        // what establishes which turn the numbering belongs to.
        if case let .turnResume(info) = event {
            applyResume(info)
            return
        }
        switch turnCursor.admit(seq: frame.seq, turnId: turnCursor.turnId) {
        case .apply:
            break
        case .skipReplayed, .skipForeignTurn:
            return
        }
        handle(event)
    }

    private func handle(_ event: AorusAIEvent) {
        guard let id = activeAssistantId, let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case let .agentStarted(turnId, _):
            // §5: the turn id is kept only to be able to cancel, and is never shown.
            // `context` is a server-side field with no documented client use, so it is
            // parsed and deliberately dropped rather than stored as dead state.
            self.turnId = turnId
            // V7: and it is the identity the journal is numbered against. The client
            // never invents one — this and `turn.resume` are the only two sources.
            turnCursor.adopt(turnId: turnId)
        case let .status(label, progress):
            let visibleLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? aorusAILocalized("Выполняю…", "Working…")
                : label
            let safeLabel = AorusAIFormat.safeStatus(visibleLabel, progress: progress)
            conversation.messages[index].statusLabel = safeLabel
            beginWorkPhase(safeLabel, at: index)
        case let .buildPhase(_, label, _):
            // The document is explicit: show `label` as it comes and never the backend's
            // own `phase` name. A build phase opens a new stretch of work the same way a
            // status does, so "Сборка приложения…" and the files under it stay one group.
            let safeLabel = AorusAIFormat.safeStatus(label)
            conversation.messages[index].statusLabel = safeLabel
            beginWorkPhase(safeLabel, at: index)
        case let .fileChange(change):
            appendWorkFile(change, at: index)
        case let .reasoningSummary(value):
            let safeLabel = AorusAIFormat.safeStatus(value)
            conversation.messages[index].statusLabel = safeLabel
            beginWorkPhase(safeLabel, at: index)
        case .responseStarted:
            conversation.messages[index].statusLabel = nil
        case let .responseDelta(delta):
            // Bounded: a stream that never ended would otherwise grow this message, the
            // encrypted history file and every attributed string built from it forever.
            // What arrived is kept — the turn is not failed over it — and the rest is
            // dropped.
            let room = AorusAIRequestLimits.responseCharacters - conversation.messages[index].rawText.count
            if room > 0 {
                conversation.messages[index].rawText.append(room >= delta.count ? delta : String(delta.prefix(room)))
            }
            conversation.messages[index].statusLabel = nil
        case let .artifactReady(artifact):
            if conversation.messages[index].artifacts.count < AorusAIRequestLimits.responseArtifactCount,
               !conversation.messages[index].artifacts.contains(where: { $0.artifactId == artifact.artifactId }) {
                conversation.messages[index].artifacts.append(artifact)
            }
        case let .completion(text, artifacts):
            // A whole answer at once, which is what a turn that produced files replies
            // with. The text replaces rather than appends: nothing was streamed before it.
            if let text, !text.isEmpty {
                conversation.messages[index].rawText = String(text.prefix(AorusAIRequestLimits.responseCharacters))
            }
            for artifact in artifacts {
                guard conversation.messages[index].artifacts.count < AorusAIRequestLimits.responseArtifactCount else { break }
                guard !conversation.messages[index].artifacts.contains(where: { $0.artifactId == artifact.artifactId }) else { continue }
                conversation.messages[index].artifacts.append(artifact)
            }
            conversation.messages[index].statusLabel = nil
        case let .toolRequest(request):
            // §13: the tool is only executed once the immediate stream has closed with
            // `done(awaiting_tool)`, so a modal can never appear over a live socket.
            pendingToolRequest = request
            turnState = .awaitingTool(request)
            let label = request.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            conversation.messages[index].statusLabel = AorusAIFormat.safeStatus(
                (label?.isEmpty == false) ? (label ?? "") : ""
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
        case .turnResume:
            // Never reaches here: `receive` takes the resume envelope before the cursor,
            // because it is turn metadata rather than a step of the answer. The case is
            // written out so this switch stays exhaustive and a future event cannot be
            // added without someone deciding what it means.
            break
        case .unknown:
            break
        }
        conversation.updatedAt = Date()
        scheduleRender(messageId: id)
    }

    /// Folds the head of a resumed stream in.
    ///
    /// "turn.resume — метаданные, не второе сообщение ассистента": nothing is appended to
    /// the conversation here. The turn is adopted, its authoritative timing is taken, and
    /// the assistant message already on screen is emptied so the replay that follows
    /// rebuilds it. Emptying it is what stops a resumed answer being printed twice.
    private func applyResume(_ info: AorusAIResumeInfo) {
        guard let id = activeAssistantId,
              let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        // The server answered, so whatever dropped the last socket is behind us.
        resumeAttempts = 0
        pendingResumeRecovery = false
        turnCursor.apply(info, deviceNowMs: Int64(Date().timeIntervalSince1970 * 1000.0))
        turnId = info.turnId
        conversation.messages[index].rawText = ""
        conversation.messages[index].artifacts = []
        conversation.messages[index].workPhases = []
        conversation.messages[index].workFinishedAt = nil
        // The server's own clock, so "Работал N" reports the real span rather than
        // restarting from the moment the reader came back.
        if info.startedAtMs > 0 {
            conversation.messages[index].turnStartedAt = Date(timeIntervalSince1970: TimeInterval(info.startedAtMs) / 1000.0)
        }
        if let completed = info.completedAtMs, completed > 0 {
            conversation.messages[index].workFinishedAt = Date(timeIntervalSince1970: TimeInterval(completed) / 1000.0)
        }
        conversation.messages[index].state = info.isTerminal ? .complete : .streaming
        // A turn the server has already cancelled or failed must not be left looking live.
        if info.isTerminal {
            conversation.messages[index].workFinishedAt = Date()
        }
        conversation.updatedAt = Date()
        scheduleRender(messageId: id)
    }

    /// The in-app notice that this turn has finished.
    ///
    /// Raised only when the reader is NOT looking at this chat: telling someone that the
    /// answer they are watching arrive has arrived is noise. A cancelled turn says nothing
    /// either — the reader stopped it themselves and already knows.
    private func announceTurnFinished(cancelled: Bool) {
        guard !cancelled, !isDiscarded, self.view.window == nil else { return }
        let duration = turnCursor.elapsedSeconds(deviceNowMs: Int64(Date().timeIntervalSince1970 * 1000.0))
            ?? localElapsedSeconds()
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        AorusAIActiveTurnCenter.shared.announceFinished(
            conversationId: conversation.id,
            title: title,
            duration: duration,
            theme: presentationData.theme,
            onTap: { [weak self] in
                guard let self else { return }
                self.lastNavigationController?.pushViewController(self)
            }
        )
    }

    /// The fallback duration for a turn the server never timed — a stream from before V7,
    /// or one that ended before any resume envelope arrived. Measured from the work trail,
    /// which is the only local record of when the turn actually began.
    private func localElapsedSeconds() -> TimeInterval? {
        guard let id = activeAssistantId,
              let index = conversation.messages.firstIndex(where: { $0.id == id }),
              let started = conversation.messages[index].workPhases.first?.startedAt else { return nil }
        let finished = conversation.messages[index].workFinishedAt ?? Date()
        return max(0.0, finished.timeIntervalSince(started))
    }

    /// Re-attaches to a turn the server is still holding for this chat.
    ///
    /// Called when the chat comes back on screen with an assistant message the store says
    /// was still streaming. That is exactly the case the brief names: the reader closed the
    /// app mid-answer, and on return the client used to report a failure of its own making
    /// instead of asking the server what actually happened.
    ///
    /// `resume_not_found` is not a failure and is not turned into a fresh send — the
    /// contract forbids that outright. It means the turn is over, so the message is settled
    /// as finished rather than left spinning forever.
    private func resumeTurnIfNeeded() {
        guard streamHandle == nil, !isPreparingRequest, !isDiscarded else { return }
        guard let index = conversation.messages.lastIndex(where: { $0.role == .assistant }),
              conversation.messages[index].state == .streaming else { return }
        let assistantId = conversation.messages[index].id
        activeAssistantId = assistantId
        turnState = .streaming
        isPreparingRequest = true
        updateComposer()
        streamGeneration += 1
        turnCursor.beginStream()
        let generation = streamGeneration
        streamHandle = AorusAIClient.shared.resumeTurn(threadId: conversation.threadId, event: { [weak self] event, frame in
            guard let self, self.streamGeneration == generation else { return }
            self.receive(event, frame: frame)
        }, completion: { [weak self] result in
            guard let self, self.streamGeneration == generation else { return }
            self.isPreparingRequest = false
            switch result {
            case .success:
                // The replay ended without a terminal event: the turn is still running on
                // the server and the socket simply closed. Re-attach rather than call it
                // finished — "disconnect ≠ done ≠ Stop" — bounded by the same allowance,
                // so a turn that never terminates still settles instead of spinning.
                if self.streamHandle != nil { self.recoverOrFail(error: .serverUnavailable) }
            case let .failure(error):
                switch error {
                case .resumeNotFound, .resumeUnavailable:
                    self.settleUnresumedTurn()
                case .cancelled:
                    break
                default:
                    self.recoverOrFail(error: error)
                }
            }
        })
        isPreparingRequest = false
        updateComposer()
        if streamHandle == nil { settleUnresumedTurn() }
    }

    /// A dropped connection is not the end of a turn.
    ///
    /// "Обрыв сети / фон приложения ≠ cancel" and "disconnect ≠ done ≠ Stop": the server
    /// keeps running the turn whatever happens to this socket. Telling the reader the
    /// connection failed — which is what closing the app for a moment used to produce —
    /// is the client inventing a failure. It re-attaches instead, and only gives up
    /// after the server itself has been asked and had nothing to offer.
    ///
    /// While the app is in the background nothing is attempted at all: the socket cannot
    /// live there, so a try would fail on the spot and burn one of the attempts. The
    /// need is remembered and acted on the moment the app is back.
    private func recoverOrFail(error: AorusAIClientError) {
        streamHandle = nil
        switch error {
        case .offline, .serverUnavailable, .timeout, .malformedResponse:
            break
        default:
            finishStreaming(error: error, preserveText: true)
            return
        }
        guard isForeground else {
            pendingResumeRecovery = true
            return
        }
        guard resumeAttempts < Self.maximumResumeAttempts else {
            settleUnresumedTurn()
            return
        }
        resumeAttempts += 1
        // Spaced out so a server that is genuinely down is not hammered, and so a
        // momentary drop has time to clear before the next try.
        let delay = 1.2 * Double(resumeAttempts)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Checked again here, not only when the failure arrived. The wait is over a
            // second long and the user may have left inside it — and a try made with the app
            // gone cannot succeed, so it would only spend an attempt that the return home
            // needs.
            guard self.isForeground else {
                self.pendingResumeRecovery = true
                return
            }
            self.resumeTurnIfNeeded()
        }
    }

    /// The error codes that mean "this socket went away", as opposed to "the server said no".
    ///
    /// Only a turn that ended for one of these is worth asking the server about again. A
    /// refusal — authorization, quota, a rejected turn — is the server's answer and asking
    /// twice would not change it.
    private static let socketErrorCodes: Set<String> = [
        "offline", "timeout", "server_unavailable", "malformed_response"
    ]

    /// How long after a turn was lost it is still worth asking the server about.
    ///
    /// The server does not keep a journal for ever, and a message that flipped from an error
    /// back to "working" an hour later would be a surprise rather than a recovery.
    private static let reopenWindow: TimeInterval = 15.0 * 60.0

    /// Ask again about a turn this client gave up on because the connection died.
    ///
    /// This is the case the whole recovery existed for and still did not cover. Once the
    /// attempts were spent the turn was marked failed, and nothing ever asked again — so
    /// leaving the app for a moment and coming back showed "AorusAI временно недоступен"
    /// for a turn that was very probably still running, or had already finished, on the
    /// server. The message is put back into its working state and the server is asked; if
    /// the server genuinely does not have it, `resumeTurnIfNeeded` settles it again, and
    /// this time the failure is the server's answer rather than this client's guess.
    ///
    /// Only ever for a turn the SOCKET ended, only for the newest message, only inside the
    /// window the server keeps a journal for, and never while something is already running.
    private func reopenTurnLostToTheSocket() {
        guard streamHandle == nil, !isPreparingRequest, !isDiscarded else { return }
        guard let index = conversation.messages.lastIndex(where: { $0.role == .assistant }) else { return }
        let message = conversation.messages[index]
        guard message.state == .failed,
              let code = message.errorCode, Self.socketErrorCodes.contains(code),
              Date().timeIntervalSince(message.createdAt) < Self.reopenWindow else {
            return
        }
        conversation.messages[index].state = .streaming
        conversation.messages[index].statusLabel = nil
        conversation.messages[index].errorCode = nil
        reloadMessage(id: message.id)
        resumeTurnIfNeeded()
    }

    /// How many times a dropped turn is re-attached before the client accepts that it
    /// is gone. Bounded so a server that is truly unreachable cannot loop for ever.
    private static let maximumResumeAttempts = 3

    /// Closes out a turn that cannot be resumed, without inventing an error.
    ///
    /// Anything the turn already wrote is kept and the message becomes a finished answer;
    /// a turn that wrote nothing becomes a failed one so the reader gets the Retry action
    /// rather than a bubble that spins for ever.
    private func settleUnresumedTurn() {
        streamHandle = nil
        guard let id = activeAssistantId,
              let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        let produced = !conversation.messages[index].rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !conversation.messages[index].artifacts.isEmpty
        if produced {
            completeStreaming(cancelled: false)
        } else {
            finishStreaming(error: .serverUnavailable, preserveText: false)
        }
    }

    /// Confirms a finished turn to the server, once its terminal state is on screen.
    ///
    /// "ack только server turn_id" and "Только после показанного terminal turn" — so this
    /// is called from the two places a turn actually ends for the reader, and never with
    /// an id the client made up.
    private func acknowledgeTurnIfNeeded() {
        guard let turn = pendingAckTurnId else { return }
        pendingAckTurnId = nil
        let thread = conversation.threadId
        AorusAIClient.shared.ackTurn(threadId: thread, turnId: turn) { _ in
            // Nothing to do either way: the acknowledgement is the server's bookkeeping,
            // and a chat must not show an error because a confirmation did not land.
        }
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
        // Unconditional: `completeStreaming` returns early when the assistant message is no
        // longer in the conversation, and it is the only thing that would have refreshed the
        // composer. Without this the send button could be left as a stop button for good,
        // and every further tap on it a no-op.
        updateComposer()
    }

    private func completeStreaming(cancelled: Bool) {
        // A question belongs to the turn that raised it. Left behind, it was presented on
        // the next appearance for a turn that no longer exists — a sheet whose every button
        // does nothing, because `submit` refuses without an active assistant message.
        deferredUserPrompt = nil
        AorusAIActiveTurnCenter.shared.setNeedsAttention(false, key: activeTurnKey)
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
        // The terminal state is now on screen, which is the only moment the contract
        // allows the turn to be acknowledged.
        turnCursor.complete(atServerMs: nil)
        if let turn = turnCursor.turnId { pendingAckTurnId = turn }
        acknowledgeTurnIfNeeded()
        announceTurnFinished(cancelled: cancelled)
        // The trail is folded from here on, so the moment the work stopped has to be
        // recorded now — after a reload there is nothing else to measure against.
        if conversation.messages[index].workFinishedAt == nil, !conversation.messages[index].workPhases.isEmpty {
            conversation.messages[index].workFinishedAt = Date()
        }
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
        // A question belongs to the turn that raised it. Left behind, it was presented on
        // the next appearance for a turn that no longer exists — a sheet whose every button
        // does nothing, because `submit` refuses without an active assistant message.
        deferredUserPrompt = nil
        AorusAIActiveTurnCenter.shared.setNeedsAttention(false, key: activeTurnKey)
        guard let id = activeAssistantId, let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        if !preserveText { conversation.messages[index].rawText = "" }
        conversation.messages[index].state = .failed
        conversation.messages[index].statusLabel = AorusAIFormat.errorText(error)
        // The trail is folded from here on, so the moment the work stopped has to be
        // recorded now — after a reload there is nothing else to measure against.
        if conversation.messages[index].workFinishedAt == nil, !conversation.messages[index].workPhases.isEmpty {
            conversation.messages[index].workFinishedAt = Date()
        }
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
        // The backend may ask for a conversation either way round: as a `permission.request`
        // carrying its own options, or as a plain `tool.request`. Both have to arrive at the
        // same question. Answering "unsupported_tool" here is what left the model to talk
        // about a chat it had never been given, with the user never asked how much of it to
        // share — the amount is the whole point of the dialog.
        if request.tool == AorusAITool.chatHistory {
            presentPermission(Self.historyPermission(from: request))
            return
        }
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
        //
        // With one addition the contract does not cover: the silent path is only for a
        // handle this conversation has actually written. Looking one up uses the user's
        // own authenticated Telegram session, and a backend free to name any handle at all
        // could resolve arbitrary usernames through the user's account without them ever
        // seeing it. A handle nobody here mentioned is therefore asked about.
        if request.requiresUserApproval || !conversationMentions(request.username) {
            presentToolApproval(request)
            return
        }
        executeProfileTool(request)
    }

    /// True when the handle appears somewhere in this conversation — in a question, in an
    /// answer, in the quoted message it started from, or in what is being typed right now.
    private func conversationMentions(_ username: String?) -> Bool {
        guard let username = username?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased(), !username.isEmpty else {
            return false
        }
        var haystacks: [String] = []
        for message in conversation.messages {
            haystacks.append(message.rawText)
            if let reference = message.referencedMessage {
                haystacks.append(reference.text)
            }
        }
        if let reference = pendingReference {
            haystacks.append(reference.text)
        }
        haystacks.append(composer.text)
        for text in haystacks where !text.isEmpty {
            if AorusAIMentionScanner.matches(in: text).contains(where: { $0.username.lowercased() == username }) {
                return true
            }
        }
        return false
    }

    private func presentToolApproval(_ request: AorusAIToolRequest) {
        guard isOnScreen else {
            deferUserPrompt { [weak self] in self?.presentToolApproval(request) }
            return
        }
        let handle = request.username.map { "@\($0)" } ?? ""
        // The heading and the first sentence are the client's own and name the handle this
        // device would actually look up. The backend's explanation is shown underneath as
        // what it is — an explanation — rather than as the whole question, so a payload
        // cannot describe one action while asking for another.
        var message = handle.isEmpty
            ? aorusAILocalized("AorusAI запрашивает данные профиля.", "AorusAI requests profile data.")
            : aorusAILocalized("AorusAI запрашивает данные профиля \(handle).", "AorusAI requests the profile data of \(handle).")
        if let label = request.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            message += "\n\n" + String(label.prefix(300))
        }
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
        // A chat the user approved in the message menu a moment ago is not asked about
        // again. The approval is checked against the peer the request actually names, so
        // it can only answer for that one chat, and it is spent on first use.
        if let approved = approvedHistory, let username = request.username, !username.isEmpty {
            approvedHistory = nil
            let expectedPeerId = approved.peerId
            let limit = approved.limit
            // Exactly one answer, and only from a resolved peer.
            //
            // `resolvePeerByName` emits progress before it emits a result. Acting on every
            // emission sent the first one — a `.progress` — down the "ask again" branch, so
            // the sheet appeared for consent the user had given a moment earlier in the
            // message menu, and the later real result then ran the tool as well: two
            // continuations for one request. `take(1)` after filtering to a result fixes the
            // first, `then(.single(nil))` guarantees a value so a signal that only completes
            // cannot stall the turn, and the timeout covers a resolve that never answers.
            let resolved = context.engine.peers.resolvePeerByName(name: username, referrer: nil)
            |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
                guard case let .result(peer) = result else { return .complete() }
                return .single(peer)
            }
            |> take(1)
            |> then(Signal<EnginePeer?, NoError>.single(nil))
            |> take(1)
            |> timeout(10.0, queue: Queue.mainQueue(), alternate: .single(nil))
            |> deliverOnMainQueue
            // Stored, so stopping the turn stops this too. Discarded, the resolve outlived a
            // cancelled turn and put a sheet on screen whose every answer did nothing.
            toolExecutionDisposable.set(resolved.start(next: { [weak self] peer in
                guard let self else { return }
                if let peer, peer.id.toInt64() == expectedPeerId {
                    self.executeHistoryTool(request: request, limit: limit, fromDate: nil, toDate: nil)
                } else {
                    self.presentPermission(request)
                }
            }))
            return
        }
        // The words that decide what is being agreed to are the client's, never the
        // payload's: each choice states the number of messages it really shares, derived
        // from what the executor will do. A payload that titled itself "Разрешить
        // уведомления?" and labelled its button "Отмена" would otherwise hand over a chat.
        //
        // A payload that named no amounts gets the client's own steps rather than a dialog
        // whose only answer is "no", which is not the same thing as being asked.
        let options = request.options.isEmpty ? Self.historyOptions(preferred: nil) : request.options
        let controller = AorusAIShareScopeController(
            context: context,
            theme: presentationData.theme,
            username: request.username,
            explanation: request.text,
            options: options,
            onSelect: { [weak self] option in
                self?.select(option: option, for: request)
            },
            // Dismissing by tapping outside answers too: a sheet that closed without an
            // answer would strand the turn forever.
            onCancel: { [weak self] in
                self?.denyPermission(request)
            }
        )
        // Presented without UIKit's own transition on purpose. `.crossDissolve` would spend a
        // third of a second fading in a view that is deliberately empty at that moment — the
        // card is off-screen and the dim is clear — and only then would the sheet's own
        // animation start. Presenting instantly lets that animation *be* the appearance.
        present(controller, animated: false)
    }

    /// Turns a bare `tool.request` for the chat history into the question the client would
    /// have asked anyway, with its own amounts.
    private static func historyPermission(from request: AorusAIToolRequest) -> AorusAIPermissionRequest {
        return AorusAIPermissionRequest(
            requestId: request.requestId,
            tool: AorusAITool.chatHistory,
            title: nil,
            text: request.label,
            username: request.username,
            options: historyOptions(preferred: request.limit),
            allowCancel: true
        )
    }

    /// The amounts offered when the payload named none.
    ///
    /// The number the backend asked for comes first when it sent one, then the standard
    /// steps, then the date range. Without this a `permission.request` that arrived with an
    /// empty `options` array left the user a dialog whose only answer was "no" — which is
    /// not the same thing as being asked how much to share.
    private static func historyOptions(preferred: Int?) -> [AorusAIPermissionOption] {
        var limits: [Int] = []
        if let preferred {
            limits.append(min(AorusAIRequestLimits.chatHistoryMessageCount, max(1, preferred)))
        }
        for value in [20, AorusAIChatDefaults.historyLimit, AorusAIRequestLimits.chatHistoryMessageCount] where !limits.contains(value) {
            limits.append(value)
        }
        var options = limits.map { AorusAIPermissionOption(id: String($0), label: "", limit: $0, mode: nil) }
        options.append(AorusAIPermissionOption(
            id: AorusAIPermissionOption.periodMode,
            label: "",
            limit: nil,
            mode: AorusAIPermissionOption.periodMode
        ))
        return options
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
        guard let username = request.username, !username.isEmpty else {
            submit(toolResult: .failure(tool: request.tool, requestId: request.requestId, username: request.username, reason: "missing_username"))
            return
        }
        let requested = min(AorusAIRequestLimits.chatHistoryMessageCount, max(1, limit ?? AorusAIChatDefaults.historyLimit))
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
                messages: lines.map { (sender: $0.sender, text: $0.text, caption: $0.caption) }
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
        // Nothing is announced between tool rounds either: "Думаю…" says less than the
        // phase the agent is about to announce for itself, and it overwrote it.
        dispatchTransport()
    }

    /// Ends the turn with a specific explanation instead of the generic unavailable card
    /// (§22). Anything the assistant already wrote is kept as a finished answer.
    private func failTurn(text: String, code: String) {
        // A question belongs to the turn that raised it. Left behind, it was presented on
        // the next appearance for a turn that no longer exists — a sheet whose every button
        // does nothing, because `submit` refuses without an active assistant message.
        deferredUserPrompt = nil
        AorusAIActiveTurnCenter.shared.setNeedsAttention(false, key: activeTurnKey)
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
            headerView?.setStatus(aorusAILocalized("слушаю…", "listening…"))
            return
        }
        if streamHandle != nil || isPreparingRequest {
            let label = activeAssistantId
                .flatMap { id in conversation.messages.first(where: { $0.id == id })?.statusLabel }
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            headerView?.setStatus(label ?? aorusAILocalized("печатает…", "typing…"))
            return
        }
        if quotaBlocked, let resetAt = conversation.quotaResetAt, resetAt > Date() {
            headerView?.setStatus(aorusAILocalized("лимит исчерпан", "limit reached"))
            return
        }
        headerView?.setStatus(aorusAILocalized("готов помочь", "ready to help"))
    }

    // MARK: - Dictation

    /// Ends the run and throws away what it heard, putting the input back exactly as it
    /// was before the microphone opened.
    private func cancelDictation() {
        guard dictation.isActive else { return }
        dictationCancelled = true
        dictationSpokenText = ""
        dictation.stop()
        composer.isDictating = false
        composer.text = dictationBaseText
        textViewDidChangeSilently()
        updateComposer()
    }

    private func toggleDictation() {
        if dictation.isActive {
            dictation.stop()
            return
        }
        guard streamHandle == nil, !isPreparingRequest else { return }
        self.displayNode.view.endEditing(true)
        dictationBaseText = composer.text
        dictationSpokenText = ""
        dictationCancelled = false
        let locale = AorusAIDictation.locale(for: presentationData.strings.baseLanguageCode)
        composer.isDictating = true
        updateComposer()
        dictation.start(locale: locale, onText: { [weak self] text in
            guard let self, !self.dictationCancelled else { return }
            // Kept, not shown. While the microphone is open the panel is the wave, and the
            // words go into the input in one piece when the run is finished — which is the
            // whole gesture the user asked for: speak, tap done, read what you said.
            self.dictationSpokenText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }, onLevel: { [weak self] level in
            self?.composer.updateDictationLevel(level)
        }, onFailure: { [weak self] failure in
            guard let self, !self.dictationCancelled else { return }
            self.dictationSpokenText = ""
            self.composer.isDictating = false
            self.updateComposer()
            self.presentError(failure.message)
        }, onFinish: { [weak self] in
            guard let self else { return }
            // The run the user abandoned has already put the input back; the recogniser's
            // last word arrives after that and must not be typed into it.
            guard !self.dictationCancelled else {
                self.dictationCancelled = false
                return
            }
            // The panel goes back to being a text field first, so the words are typed into
            // a field that is already on screen rather than appearing under the wave.
            self.composer.isDictating = false
            self.composer.text = self.dictationDraft()
            self.textViewDidChangeSilently()
            self.dictationBaseText = self.composer.text
            self.dictationSpokenText = ""
            self.composer.textView.becomeFirstResponder()
            self.updateComposer()
        })
    }

    /// What the input is given when the run ends: whatever was already typed, then
    /// everything that was recognised. Built from the two parts rather than appended to, so
    /// a correction the recogniser makes to an earlier word replaces it instead of being
    /// added after it.
    private func dictationDraft() -> String {
        let base = dictationBaseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = dictationSpokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if spoken.isEmpty { return dictationBaseText }
        return base.isEmpty ? spoken : base + " " + spoken
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
            guard let username = draftEntities[index].username, draftEntities[index].peerId == nil else { continue }
            let expectedText = draftEntitiesText
            let disposable = (context.engine.peers.resolvePeerByName(name: username, referrer: nil) |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self, case let .result(peer) = result, let peer else { return }
                // Remembered before the draft check: the answer is just as valid for the
                // next message even if the user has already typed past this one.
                AorusAIMentionStore.shared.store(username: username, peerId: peer.id.toInt64(), displayName: self.displayName(of: peer))
                guard self.draftEntitiesText == expectedText else { return }
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
        var resolvedFromCache = false
        for entityIndex in parsed.indices {
            guard let username = parsed[entityIndex].username else { continue }
            // The scanner already filled in anything this session knows, so a repeated
            // handle draws its pill without waiting for the network again.
            if parsed[entityIndex].peerId != nil {
                resolvedFromCache = true
                continue
            }
            let disposable = (context.engine.peers.resolvePeerByName(name: username, referrer: nil) |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self, case let .result(peer) = result, let peer else { return }
                AorusAIMentionStore.shared.store(username: username, peerId: peer.id.toInt64(), displayName: self.displayName(of: peer))
                guard let currentMessageIndex = self.conversation.messages.firstIndex(where: { $0.id == messageId }),
                      entityIndex < self.conversation.messages[currentMessageIndex].telegramEntities.count else { return }
                self.conversation.messages[currentMessageIndex].telegramEntities[entityIndex].peerId = peer.id.toInt64()
                self.conversation.messages[currentMessageIndex].telegramEntities[entityIndex].displayName = self.displayName(of: peer)
                self.reloadMessage(id: messageId)
                self.persist(force: false)
            })
            disposables.append(disposable)
        }
        if resolvedFromCache {
            reloadMessage(id: messageId)
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
            // A save is not cheap: the store keeps one encrypted file per account, so every
            // one of these decrypts and decodes every conversation, re-encodes them all and
            // writes the whole file again. The render pass asks for one about eighteen times
            // a second while an answer streams, and at 0.35s that was three full rewrites a
            // second for the length of the answer — invisible on a short history and a real
            // drain on a long one. A live turn is given a much longer leash instead. Nothing
            // is risked by it: the text lives in memory, and every way a turn can end forces
            // a save, as do leaving the screen and going to the background.
            let interval: TimeInterval = isTurnLive ? 2.5 : 0.35
            let elapsed = Date().timeIntervalSince(lastPersist)
            if elapsed < interval {
                guard pendingPersistWork == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingPersistWork = nil
                    self.persist(force: true)
                }
                pendingPersistWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (interval - elapsed), execute: work)
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
        // Same rule as `jumpToNewestMessage`: a row the table has not been told about cannot be
        // reloaded, it raises. A skipped update here is harmless — the caller that adds the
        // row reloads the table straight afterwards.
        guard tableView.numberOfSections > 0, row < tableView.numberOfRows(inSection: 0) else { return }
        let indexPath = IndexPath(row: row, section: 0)
        let message = conversation.messages[row]
        let canRetry = message.role == .assistant
            && row == conversation.messages.count - 1
            && (message.state == .failed || message.state == .complete)
        // §27: during streaming this method fires several times per second. Rebuilding the
        // whole cell drops the text selection and flickers, so try to push only the changed
        // text into the live views and let the table re-measure the height.
        // Asked before anything changes, and honoured after — the same rule `applyLayout`
        // follows. It used to re-anchor unconditionally, about eighteen times a second while
        // an answer streamed, so scrolling up to re-read an earlier message was impossible:
        // the next delta yanked the list back down. Tapping an artifact card or a handle
        // resolving in an old message did it too.
        let wasAtBottom = isScrolledToBottom()
        if let cell = tableView.cellForRow(at: indexPath) as? AorusAIMessageCell,
           cell.applyIncremental(message: message, theme: presentationData.theme, canRetry: canRetry, loadingArtifactIds: loadingArtifactIds) {
            // Laid out before the table asks for the height, not after. `endUpdates` reads
            // whatever the cell currently reports, so a stack that has not re-measured hands
            // back the previous answer's height and the new text is clipped inside it.
            cell.contentView.layoutIfNeeded()
            tableView.beginUpdates()
            tableView.endUpdates()
            // A streaming answer grows while it is on screen and `willDisplay` will not
            // fire again, so the height it was remembered at is already out of date. Left
            // stale, the estimate used the moment it scrolls out of view is the height it
            // had several paragraphs ago.
            recordHeight(of: cell, at: indexPath)
        } else {
            tableView.reloadRows(at: [indexPath], with: .none)
        }
        if wasAtBottom {
            stickToBottom()
        }
    }

    /// Land on the newest message, wherever the reader happens to be.
    ///
    /// This is the deliberate move: opening the conversation, sending, and retrying. It
    /// names the row instead of working out an offset, because `scrollToRow` keeps aiming
    /// at that row as the real heights arrive — so it lands even when nothing has been
    /// measured yet, which is every conversation the moment it opens.
    ///
    /// An offset cannot do that job. Worked out from estimates, a conversation of a few
    /// very long answers measures shorter than the screen before anything is laid out, so
    /// the "bottom" is the top and the list simply stays there while the real heights
    /// arrive underneath it.
    ///
    /// The table's own row count, never the conversation's. `send()` appends the two new
    /// messages to the model and only reloads the table several lines later; in between it
    /// clears the composer, which reports a height change and runs a layout pass that
    /// re-anchors the list. Addressing the last *message* there asks the table to scroll to
    /// a row it has not been told about, and UIKit raises on that rather than ignoring it —
    /// every single send crashed the app. Asking the table what it holds cannot outrun it.
    private func jumpToNewestMessage(animated: Bool) {
        guard tableView.numberOfSections > 0 else { return }
        let rows = tableView.numberOfRows(inSection: 0)
        guard rows > 0 else { return }
        tableView.scrollToRow(at: IndexPath(row: rows - 1, section: 0), at: .bottom, animated: animated)
    }

    /// Keep a list that was already at the bottom there, without moving one that is not.
    ///
    /// Called while an answer streams and whenever the insets change under it — the first
    /// of those about eighteen times a second. `scrollToRow` is wrong for this: it works
    /// its target out from the table's estimates and then corrects itself once the real
    /// heights land, and a correction per delta is exactly the jitter this fixes. The
    /// bottom of the content is a number the table already knows, so it is set outright.
    private func stickToBottom() {
        guard tableView.numberOfSections > 0, tableView.numberOfRows(inSection: 0) > 0 else { return }
        // The content size is only recomputed on a layout pass, so it is brought up to date
        // before it is read. A table with nothing pending lays out for free.
        tableView.layoutIfNeeded()
        // The floor is where a list shorter than the screen rests, which is above zero here
        // because the list runs under the capsules and is inset instead of cut off.
        let floorOffset = -tableView.contentInset.top
        let maximum = tableView.contentSize.height + tableView.contentInset.bottom - tableView.bounds.height
        let target = CGPoint(x: 0.0, y: max(floorOffset, maximum))
        // Already right is left alone rather than re-set: re-setting the same offset
        // interrupts the reader's own momentum.
        guard abs(tableView.contentOffset.y - target.y) > 0.5 else { return }
        tableView.setContentOffset(target, animated: false)
    }

    /// Whether the newest message is on screen, within a row's worth of slack.
    ///
    /// Asked before the insets change and acted on after, so re-anchoring the list never
    /// yanks a reader who had deliberately scrolled up.
    private func isScrolledToBottom() -> Bool {
        let maximum = tableView.contentSize.height + tableView.contentInset.bottom - tableView.bounds.height
        return tableView.contentOffset.y >= maximum - 60.0
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
        cell.onOpenWorkTrail = { [weak self] in self?.presentWorkTrail(messageId: message.id) }
        return cell
    }

    /// What a row turned out to be, once the table had actually laid it out.
    ///
    /// Self-sizing rows cost nothing to declare and everything to guess. Until a row has
    /// been on screen the table has no idea how tall it is, so it uses the estimate — and
    /// the estimate here was a flat 100 points for rows that are routinely ten times that.
    /// The whole content size is therefore a guess, and every time a real height replaces
    /// a guessed one the table corrects the content size and slides the offset to match.
    /// Scrolling up through a long conversation, that correction happens continuously and
    /// under the reader's finger: the list jumps, overshoots and teleports.
    ///
    /// Answering with the height the row really had is what stops it. It is keyed by
    /// message id rather than by row, because a retry deletes two messages and every index
    /// after them shifts; a height remembered against an index would then be handed to a
    /// completely different message.
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        recordHeight(of: cell, at: indexPath)
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Recorded on the way out as well: a streaming answer grows while it is on screen,
        // and `willDisplay` will not fire again to tell us about it.
        recordHeight(of: cell, at: indexPath)
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard indexPath.row < conversation.messages.count else { return averageRowHeight }
        // A row that has been seen answers with what it was. One that has not answers with
        // what this conversation's rows have averaged so far, which is a far better opening
        // guess than a constant — a chat of long answers stops being measured as if every
        // row were a single line.
        return measuredRowHeights[conversation.messages[indexPath.row].id] ?? averageRowHeight
    }

    private func recordHeight(of cell: UITableViewCell, at indexPath: IndexPath) {
        guard indexPath.row < conversation.messages.count else { return }
        let height = cell.bounds.height
        guard height > 1.0 else { return }
        let id = conversation.messages[indexPath.row].id
        measuredHeightTotal += height - (measuredRowHeights[id] ?? 0.0)
        measuredRowHeights[id] = height
    }

    /// Forgets the rows of messages the conversation no longer has.
    ///
    /// A retry deletes the question and its failed answer. Their heights are keyed by an
    /// id nothing will ask for again, so they cannot be handed to the wrong row — but
    /// they would go on counting towards the mean that every UNSEEN row is estimated
    /// with, which is the one number here that is read for rows it was not measured from.
    private func pruneMeasuredHeights() {
        let live = Set(conversation.messages.map { $0.id })
        guard measuredRowHeights.count > live.count else { return }
        measuredRowHeights = measuredRowHeights.filter { live.contains($0.key) }
        measuredHeightTotal = measuredRowHeights.values.reduce(0.0, +)
    }

    /// Mean of every row measured so far, or a sane opening figure before there are any.
    private var averageRowHeight: CGFloat {
        guard !measuredRowHeights.isEmpty else { return 120.0 }
        return max(44.0, measuredHeightTotal / CGFloat(measuredRowHeights.count))
    }

    /// Opens the turn's trail as a half-screen sheet.
    ///
    /// It used to fold out inside the row, which meant the chat row changed height under
    /// the reader and pushed the answer they were reading off the screen. The row is now a
    /// fixed one line and nothing about the list moves.
    ///
    /// Read fresh from the conversation at the moment of the tap rather than captured: a
    /// running turn gains phases while the line sits there, and the sheet has to show the
    /// ones that arrived, not the ones that existed when the cell was configured.
    private func presentWorkTrail(messageId: UUID) {
        guard let message = conversation.messages.first(where: { $0.id == messageId }) else { return }
        guard !message.workPhases.isEmpty else { return }
        aorusAIPresentWorkTrail(
            phases: message.workPhases,
            isRunning: message.state == .streaming,
            finishedAt: message.workFinishedAt,
            theme: presentationData.theme,
            from: self
        )
    }

    /// Sends the last question again, having taken it and its failed answer out of the
    /// conversation first.
    ///
    /// Every reason `send` could refuse is checked *here*, before anything is deleted. It
    /// used to delete first and let `send` decide afterwards, and `send` refuses on a live
    /// quota — so the commonest retry of all, the one offered on a quota failure, threw away
    /// the user's question and the card explaining what happened and then did nothing.
    private func retry(messageId: UUID) {
        guard streamHandle == nil, !isPreparingRequest,
              let assistantIndex = conversation.messages.firstIndex(where: { $0.id == messageId }),
              assistantIndex == conversation.messages.count - 1,
              assistantIndex > 0 else { return }
        if let resetAt = conversation.quotaResetAt, resetAt > Date() {
            // The card already says why, and it stays on screen to keep saying it.
            updateComposer()
            return
        }
        let user = conversation.messages[assistantIndex - 1]
        guard user.role == .user else { return }
        // A draft the user has started is theirs. Restoring the old question over it would
        // destroy work they cannot get back, so the retry stands down instead.
        let draft = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.isEmpty || draft == user.rawText.trimmingCharacters(in: .whitespacesAndNewlines) else {
            presentError(aorusAILocalized(
                "Сначала отправьте или очистите то, что уже набрано.",
                "Send or clear what you have typed first."
            ))
            return
        }
        composer.text = user.rawText
        resolveDraftEntities(in: user.rawText)
        pendingReference = user.referencedMessage
        composer.reference = pendingReference
        conversation.messages.removeSubrange((assistantIndex - 1)...assistantIndex)
        pruneMeasuredHeights()
        tableView.reloadData()
        // `send()` reloads and jumps to the newest message itself, so the retry lands on
        // the question it just put back exactly as sending it by hand would.
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
            presentExternalLink(url)
        }
    }

    /// Opens a link the model wrote, after showing where it actually leads.
    ///
    /// Markdown lets the visible words differ from the destination — `[Оплатить](https://…)`
    /// — and here those words are written by a model rather than by a person the user
    /// knows, so the address is put in front of them before anything is handed to the
    /// system. The scheme is checked as well: nothing but http(s) is ever opened, whatever
    /// a future change to the text renderer might start producing.
    private func presentExternalLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let sheet = UIAlertController(
            title: aorusAILocalized("Открыть ссылку?", "Open this link?"),
            message: String(url.absoluteString.prefix(300)),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: aorusAILocalized("Открыть", "Open"), style: .default, handler: { [weak self] _ in
            guard let self else { return }
            self.context.sharedContext.applicationBindings.openUrl(url.absoluteString)
        }))
        sheet.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        aorusAIPresentActionSheet(sheet, from: self)
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
        // No local expiry check. The vault decides whether a link is still alive, and it says
        // so with a 410 or a 404 — which is already handled below and is what marks the card
        // expired. Refusing here meant the request was never made at all: an `expires_at` the
        // client read as past killed the file on the device with no way to find out
        // otherwise, and a device clock that is merely wrong did the same. Asking costs one
        // request and gives a truthful answer.
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
    let textView = AorusAIMentionTextView.make()
    private let container = UIView()
    private let containerGlass = GlassBackgroundView(frame: CGRect())
    private let placeholder = UILabel()
    private let referenceView = UIView()
    private let referenceLine = UIView()
    private let referenceLabel = UILabel()
    private let referenceClose = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let dictationButton = UIButton(type: .system)
    private let dictationWave = AorusAIDictationWaveView()
    private let dictationCancel = UIButton(type: .system)
    private let dictationDone = UIButton(type: .system)
    var onSend: (() -> Void)?
    var onDismissReference: (() -> Void)?
    var onOpenPeer: ((PeerId) -> Void)?
    var onHeightChanged: (() -> Void)?
    var onDictation: (() -> Void)?
    var onCancelDictation: (() -> Void)?
    private var theme: PresentationTheme?
    private var context: AccountContext?
    /// Mentions the controller has resolved to real peers. Setting them redraws the pills
    /// inside the input itself: the handle the user typed becomes that person's avatar and
    /// name, in place, without the text they will actually send changing at all.
    var entities: [AorusAITelegramEntity] = [] {
        didSet { applyMentionStyling() }
    }

    /// What the user wrote, with every pill collapsed back to the handle it was made
    /// from. This — never what is drawn — is the draft, the transport text and the string
    /// mentions are scanned in.
    var text: String {
        get { textView.attributedText?.aorusAIPlainText ?? "" }
        set {
            renderedMentionSignature = nil
            // Text the user did not type: a restored draft, or the input being emptied
            // after a send. Nothing is half-written in it, so a handle at its end is
            // finished and is drawn as the person straight away.
            typingHandle = nil
            lastStyledSource = newValue
            textView.attributedText = NSAttributedString(string: newValue, attributes: baseTextAttributes())
            textView.refreshMentionImages()
            placeholder.isHidden = isDictating || !newValue.isEmpty
            applyMentionStyling()
            // The controller owns this view's frame and measures it from the text, so a
            // change it did not type has to say so. Without this the panel kept the height
            // of the long message that was just sent and stood there empty and tall.
            onHeightChanged?()
        }
    }
    var reference: AorusAIReferencedMessage? {
        didSet {
            referenceView.isHidden = reference == nil
            refreshReferenceLabel()
            // The quoted row is a row of height, so attaching or dropping one re-measures.
            if (oldValue == nil) != (reference == nil) {
                onHeightChanged?()
            }
        }
    }

    /// The quoted message above the input, with any handle in it written as the person.
    /// Called from `configure` as well: the reference can be set before the theme is
    /// known, and until it is there is no colour to draw the name in.
    private func refreshReferenceLabel() {
        guard let reference else {
            referenceLabel.attributedText = nil
            return
        }
        let text = "\(reference.authorName ?? aorusAILocalized("Сообщение", "Message")): \(reference.text)"
        guard let theme else {
            referenceLabel.text = text
            return
        }
        let palette = AorusAIPalette.resolve(theme)
        referenceLabel.attributedText = AorusAIMentionRenderer.previewText(
            text.replacingOccurrences(of: "\n", with: " "),
            color: palette.secondary,
            font: UIFont.systemFont(ofSize: 12.0),
            accent: palette.accent
        )
    }
    var isGenerating = false { didSet { refreshButton(); refreshDictationButton() } }
    var canSend = false { didSet { refreshButton() } }
    /// While this is on, the panel is the wave and nothing else: the text, both round
    /// buttons and the placeholder step aside for it, and what was heard is written into
    /// the input at the end of the run.
    var isDictating = false {
        didSet {
            guard oldValue != isDictating else { return }
            refreshDictationButton()
            dictationWave.isHidden = !isDictating
            dictationCancel.isHidden = !isDictating
            dictationDone.isHidden = !isDictating
            textView.isHidden = isDictating
            sendButton.isHidden = isDictating
            dictationButton.isHidden = isDictating
            dictationWave.setActive(isDictating)
            placeholder.isHidden = isDictating || !text.isEmpty
            if isDictating {
                textView.resignFirstResponder()
            }
            onHeightChanged?()
            setNeedsLayout()
        }
    }

    /// One microphone sample from the running dictation.
    func updateDictationLevel(_ level: CGFloat) {
        guard isDictating else { return }
        dictationWave.update(level: level)
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(container)
        [referenceView, dictationWave, dictationCancel, dictationDone, dictationButton, textView, sendButton].forEach { container.addSubview($0) }
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
        // The default 5pt fragment padding indents the first glyph but not the placeholder
        // label, which is laid out at x: 0 — so the caret sat on top of the "С" of
        // "Спросите". Both now start at the same x.
        textView.textContainer.lineFragmentPadding = 0
        textView.onDeleteBackward = { [weak self] in
            return self?.deleteMentionBeforeCaret() ?? false
        }
        referenceLabel.font = .systemFont(ofSize: 12)
        referenceLabel.numberOfLines = 1
        referenceLabel.lineBreakMode = .byTruncatingTail
        referenceClose.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        referenceClose.addTarget(self, action: #selector(closeReference), for: .touchUpInside)
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.accessibilityLabel = aorusAILocalized("Отправить", "Send")
        dictationButton.addTarget(self, action: #selector(dictate), for: .touchUpInside)
        // A turn on the wire refuses dictation, so the button says so rather than swallowing
        // the tap in silence — the send button next to it has always done this.
        dictationButton.isEnabled = !isGenerating
        dictationButton.alpha = isGenerating ? 0.42 : 1.0
        dictationButton.accessibilityLabel = aorusAILocalized("Диктовать", "Dictate")
        // A run has to be abandonable. Finishing commits what was heard, which is right;
        // there was no way at all to decide it heard the wrong thing.
        dictationCancel.setImage(UIImage(systemName: "xmark")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 14.0, weight: .semibold)), for: .normal)
        dictationCancel.addTarget(self, action: #selector(cancelDictation), for: .touchUpInside)
        dictationCancel.accessibilityLabel = aorusAILocalized("Отменить диктовку", "Cancel dictation")
        dictationCancel.isHidden = true
        // The one thing to press while the wave is running: it ends the run and puts what
        // was said into the input.
        dictationDone.setImage(UIImage(systemName: "checkmark")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 16.0, weight: .bold)), for: .normal)
        dictationDone.addTarget(self, action: #selector(dictate), for: .touchUpInside)
        dictationDone.accessibilityLabel = aorusAILocalized("Закончить диктовку", "Finish dictation")
        dictationDone.isHidden = true
        dictationWave.isHidden = true
        referenceView.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(context: AccountContext, theme: PresentationTheme) {
        self.context = context
        self.theme = theme
        let palette = AorusAIPalette.resolve(theme)
        // Clear, so the capsule below IS the panel rather than a pane of glass laid on top
        // of an opaque plate. Filling this view with the page colour put a solid sheet
        // directly behind the glass: glass samples what is behind it, and what was behind it
        // was a flat colour, so it could only ever come out as a tinted slab. The chat now
        // runs under the composer the way it does under Telegram's own.
        backgroundColor = .clear
        // The input is a pane of Telegram's own glass, the same component the navigation
        // capsules are made of, rather than a blur with a border drawn to look like one.
        container.backgroundColor = .clear
        container.layer.cornerRadius = 24
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        container.layer.borderWidth = 0.0
        textView.textColor = palette.label
        textView.tintColor = palette.accent
        textView.keyboardAppearance = palette.isDark ? .dark : .light
        placeholder.textColor = palette.tertiary
        referenceLabel.textColor = palette.secondary
        referenceView.backgroundColor = .clear
        referenceLine.backgroundColor = palette.accent
        referenceClose.tintColor = palette.tertiary
        dictationWave.configure(palette: palette)
        dictationCancel.tintColor = palette.secondary
        dictationCancel.backgroundColor = palette.fill
        dictationDone.tintColor = palette.onAccent
        dictationDone.backgroundColor = palette.accent
        refreshReferenceLabel()
        textView.configureMentions(context: context, theme: theme)
        // The theme decides the base colour every run is drawn in, so the last render is
        // no longer valid and has to be redone rather than skipped as unchanged.
        renderedMentionSignature = nil
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
        if containerGlass.superview !== container {
            containerGlass.isUserInteractionEnabled = false
            container.insertSubview(containerGlass, at: 0)
        }
        containerGlass.frame = container.bounds
        containerGlass.update(
            size: container.bounds.size,
            cornerRadius: 24.0,
            isDark: theme?.overallDarkAppearance ?? true,
            tintColor: GlassBackgroundView.TintColor(kind: .panel),
            isInteractive: false,
            transition: .immediate
        )
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
        // The dictation row owns the whole panel below the quote: a round cancel on the
        // left, the wave across everything between, and the accent "done" on the right.
        let waveTop = inputTop
        let cancelSize = AorusAIComposerView.dictationCancelSize
        let doneSize = AorusAIComposerView.dictationDoneSize
        let waveHeight = AorusAIComposerView.dictationPanelHeight - 16.0
        dictationCancel.frame = CGRect(x: 12.0, y: waveTop + floor((waveHeight - cancelSize) / 2.0), width: cancelSize, height: cancelSize)
        dictationCancel.layer.cornerRadius = cancelSize / 2.0
        dictationDone.frame = CGRect(
            x: max(0, container.bounds.width - doneSize - 12.0),
            y: waveTop + floor((waveHeight - doneSize) / 2.0),
            width: doneSize,
            height: doneSize
        )
        dictationDone.layer.cornerRadius = doneSize / 2.0
        let waveLeft = dictationCancel.frame.maxX + 12.0
        dictationWave.frame = CGRect(
            x: waveLeft,
            y: waveTop,
            width: max(0, dictationDone.frame.minX - 12.0 - waveLeft),
            height: waveHeight
        )
        let inputRight = dictationButton.frame.minX - 8
        textView.frame = CGRect(x: textInset, y: inputTop, width: max(0, inputRight - textInset), height: max(0, container.bounds.height - inputTop - 8))
        placeholder.frame = CGRect(x: 0, y: 2, width: max(0, textView.bounds.width), height: 21)
    }

    private static let actionButtonSize: CGFloat = 32
    private static let dictationButtonSize: CGFloat = 26
    private static let dictationCancelSize: CGFloat = 34.0
    private static let dictationDoneSize: CGFloat = 40.0
    /// What the panel becomes while dictating: one tall row, the wave and its two buttons.
    private static let dictationPanelHeight: CGFloat = 68.0

    func requiredHeight(width: CGFloat) -> CGFloat {
        var extras: CGFloat = reference == nil ? 0 : 34
        if isDictating {
            // Fixed while the microphone is open: the text is not on screen to measure, and
            // a panel that changed height as words arrived would make the wave jump.
            extras += AorusAIComposerView.dictationPanelHeight
            return extras + 8
        }
        // 12pt page inset on each side, then the card's own 16pt text inset on each side.
        let available = max(100, width - 24 - 32)
        let measured = textView.sizeThatFits(CGSize(width: available, height: 132)).height
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
        //
        // NOT a pane of glass. Glass inside a 30-point circle is a blurred disc — it
        // samples what is behind it at that size and reads as a smudge, which is exactly
        // what putting one here did to every control in the composer.
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
        // Only ever the microphone: a running dictation replaces the whole row with the
        // wave and its own done button, so this one is not on screen to have a second state.
        dictationButton.setImage(UIImage(systemName: "mic")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)), for: .normal)
        dictationButton.tintColor = palette?.secondary
        dictationButton.backgroundColor = .clear
        dictationButton.layer.cornerRadius = AorusAIComposerView.dictationButtonSize / 2.0
        dictationButton.layer.cornerCurve = .circular
        dictationButton.accessibilityLabel = aorusAILocalized("Диктовать", "Dictate")
    }

    private static let inputFont = UIFont.systemFont(ofSize: 16.0)

    private func baseTextAttributes() -> [NSAttributedString.Key: Any] {
        let color = theme.map { AorusAIPalette.resolve($0).label } ?? UIColor.label
        return [.font: AorusAIComposerView.inputFont, .foregroundColor: color]
    }

    /// Puts `typingAttributes` back to plain body text.
    ///
    /// Called whenever the selection moves, because that is exactly when `UITextView`
    /// replaces them with the attributes of the character before the caret — which, right
    /// after a pill, are the pill's. Assigning only when they differ keeps this off the hot
    /// path of ordinary typing.
    func resetTypingAttributes() {
        guard textView.typingAttributes[.aorusAIMention] != nil else { return }
        textView.typingAttributes = baseTextAttributes()
    }

    /// Re-decides which handles are pills after the caret has moved on its own.
    ///
    /// Typing already routes through `entities`, but moving the caret does not change the
    /// text at all — and it is what finishes a handle: leaving the end of `@durov` means
    /// the user is done writing it, so it becomes the person. The signature guard makes
    /// this free on every caret move that changes nothing.
    func refreshMentionStyling() {
        applyMentionStyling()
    }

    /// Deletes the pill standing immediately before the caret, whole, in one press.
    ///
    /// Returns false for anything else — a selection, a caret with ordinary characters
    /// behind it — so the system's own backspace runs and the delegate's edit widening
    /// still covers the cases it was written for.
    private func deleteMentionBeforeCaret() -> Bool {
        let selection = textView.selectedRange
        guard selection.length == 0 else { return false }
        guard let run = textView.mentionRun(endingAt: selection.location) else { return false }
        let storage = textView.textStorage
        guard NSMaxRange(run) <= storage.length else { return false }
        storage.beginEditing()
        storage.deleteCharacters(in: run)
        storage.endEditing()
        // Cleared before the selection moves, not after: assigning `selectedRange` calls
        // the delegate synchronously, which comes back through `refreshMentionStyling`,
        // and that pass has to already know the drawn text is stale.
        renderedMentionSignature = nil
        textView.selectedRange = NSRange(location: run.location, length: 0)
        textView.typingAttributes = baseTextAttributes()
        textView.refreshMentionImages()
        textView.delegate?.textViewDidChange?(textView)
        return true
    }

    /// What the pills currently drawn in the input describe. Comparing against it is what
    /// keeps an ordinary keystroke from rewriting the whole attributed text — and moving
    /// the caret — when nothing about the mentions has changed.
    private var renderedMentionSignature: String?

    /// The handle the user is in the middle of writing, held back from becoming a pill.
    /// See `updateTypingHandle`.
    private var typingHandle: NSRange?
    /// The source text the last styling pass saw, which is how a pass caused by an edit is
    /// told apart from one caused by the caret moving on its own.
    private var lastStyledSource: String?

    /// Decides whether the handle at the end of the input is still being written.
    ///
    /// Two requirements, and the second is the one that matters. A handle only counts if
    /// the caret is at its end *and* it runs to the end of the text — anything typed after
    /// it means the user finished it. And the state is only entered by an **edit**: a pass
    /// that ran because the text changed. A caret that merely arrives at the end of a
    /// finished pill leaves it a pill.
    ///
    /// That second requirement is what lets both of these be true at once. Typing
    /// `@durovnews` never loses the name to a pill for `@durov` halfway through, because
    /// every keystroke is an edit at the end of the handle. And tapping behind a finished
    /// `@durov` and pressing backspace once deletes the person, because arriving there
    /// changed nothing and the pill is still a pill.
    ///
    /// Shrinking counts as editing too: backspacing through `@durovnews` must not stop at
    /// `@durov` and suddenly draw a person the user is in the middle of deleting.
    private func updateTypingHandle(source: String, caret: Int) -> NSRange? {
        let previous = lastStyledSource
        lastStyledSource = source
        guard let trailing = AorusAIMentionRenderer.handleBeingTyped(source: source, caret: caret) else {
            typingHandle = nil
            return nil
        }
        if previous != source || typingHandle != nil {
            typingHandle = trailing
        }
        return typingHandle
    }

    /// Draws every resolved handle in the input as its person.
    ///
    /// The rebuild is deliberately rare: it happens when a handle finishes resolving, is
    /// typed, or is deleted, and never while the user is simply typing words. When it does
    /// happen the caret is carried across by counting characters from the end of the
    /// *source* text, so it stays where the user left it even though the displayed text
    /// just changed length.
    private func applyMentionStyling() {
        guard let theme else { return }
        let palette = AorusAIPalette.resolve(theme)
        let base = baseTextAttributes()
        textView.typingAttributes = base
        let source = self.text
        let resolved = AorusAIMentionRenderer.map(from: entities)

        // Where the caret is in the text the user actually wrote, which is what decides
        // whether the last handle is finished or still being typed. It has to be computed
        // before the rebuild: afterwards the displayed text is a different length.
        let sourceLength = (source as NSString).length
        let selection = textView.selectedRange
        let tail = max(0, sourceLength - Self.sourceOffset(forRendered: selection.location, placements: currentPlacements()))
        let caretSource = max(0, sourceLength - tail)
        let beingTyped = updateTypingHandle(source: source, caret: caretSource)

        let signature = AorusAIMentionRenderer.signature(source: source, resolved: resolved, plain: beingTyped)
        guard signature != renderedMentionSignature else { return }
        renderedMentionSignature = signature

        let rendered = AorusAIMentionRenderer.render(
            source: source,
            resolved: resolved,
            base: base,
            font: AorusAIComposerView.inputFont,
            accent: palette.accent,
            link: false,
            plain: beingTyped
        )
        textView.attributedText = rendered.text
        textView.typingAttributes = base
        // `caretSource` is the one computed above, before the rebuild — the same value this
        // line used to recompute here, now needed earlier because it is what decides
        // whether the last handle is still being typed.
        let caret = min(rendered.text.length, Self.renderedOffset(forSource: caretSource, placements: rendered.placements))
        textView.selectedRange = NSRange(location: caret, length: 0)
        textView.refreshMentionImages()
    }

    /// Where each pill currently on screen sits, in both coordinate systems.
    ///
    /// Derived from the text view itself rather than remembered from the last render: an
    /// edit that removed a pill has already changed what is displayed, and a cached map
    /// would put the caret by the geometry of a text that no longer exists.
    private func currentPlacements() -> [AorusAIMentionRenderer.Placement] {
        guard let value = textView.attributedText, value.length > 0 else { return [] }
        var placements: [AorusAIMentionRenderer.Placement] = []
        var sourceCursor = 0
        value.enumerateAttribute(.aorusAIMention, in: NSRange(location: 0, length: value.length), options: []) { attribute, range, _ in
            if let box = attribute as? AorusAIMentionBox {
                let sourceLength = (box.mention.sourceText as NSString).length
                placements.append(AorusAIMentionRenderer.Placement(
                    source: NSRange(location: sourceCursor, length: sourceLength),
                    rendered: range
                ))
                sourceCursor += sourceLength
            } else {
                sourceCursor += range.length
            }
        }
        return placements
    }

    private static func sourceOffset(forRendered offset: Int, placements: [AorusAIMentionRenderer.Placement]) -> Int {
        var result = offset
        for placement in placements {
            if offset >= NSMaxRange(placement.rendered) {
                result += placement.source.length - placement.rendered.length
            } else if offset > placement.rendered.location {
                // Inside a pill: the whole thing belongs to its source run.
                return NSMaxRange(placement.source)
            } else {
                break
            }
        }
        return max(0, result)
    }

    private static func renderedOffset(forSource offset: Int, placements: [AorusAIMentionRenderer.Placement]) -> Int {
        var result = offset
        for placement in placements {
            if offset >= NSMaxRange(placement.source) {
                result += placement.rendered.length - placement.source.length
            } else if offset > placement.source.location {
                return NSMaxRange(placement.rendered)
            } else {
                break
            }
        }
        return max(0, result)
    }

    /// Makes a pill a single object to the keyboard: one backspace removes the person, not
    /// the last letter of a name that no longer stands for anything.
    ///
    /// Returns false when it performed the edit itself, which is the contract
    /// `textView(_:shouldChangeTextIn:replacementText:)` expects.
    func handleTextChange(in range: NSRange, replacement: String) -> Bool {
        let expanded = textView.rangeCoveringMentions(range)
        guard expanded.location != range.location || expanded.length != range.length else { return true }
        guard NSMaxRange(expanded) <= textView.textStorage.length else { return true }
        let insertion = NSAttributedString(string: replacement, attributes: baseTextAttributes())
        let storage = textView.textStorage
        storage.beginEditing()
        storage.replaceCharacters(in: expanded, with: insertion)
        storage.endEditing()
        textView.selectedRange = NSRange(location: expanded.location + (replacement as NSString).length, length: 0)
        // The pill has been taken out of the text, so what is drawn no longer matches the
        // last signature; the next pass has to rebuild rather than skip as unchanged.
        renderedMentionSignature = nil
        textView.refreshMentionImages()
        textView.delegate?.textViewDidChange?(textView)
        return false
    }

    @objc private func closeReference() { onDismissReference?() }
    @objc private func send() { onSend?() }
    @objc private func dictate() { onDictation?() }
    @objc private func cancelDictation() { onCancelDictation?() }
}

/// Holds a display link's target weakly.
///
/// `CADisplayLink(target:selector:)` retains its target for as long as the link is valid,
/// so a view that starts one and is then torn down without invalidating it is kept alive by
/// the link — and the link goes on firing sixty times a second, into a view nobody can see,
/// for the rest of the process. Closing the screen mid-dictation is exactly that path: the
/// controller lets go of the composer, and nothing is left to call `setActive(false)`.
///
/// Pointing the link at this proxy instead means the target can always be collected, and
/// the first tick after it is gone invalidates the link.
/// `NSObject` because a display-link selector has to be `@objc`, and only an
/// ObjC-compatible class may declare one.
private final class AorusAIDisplayLinkProxy: NSObject {
    weak var target: AorusAIDictationWaveView?

    init(target: AorusAIDictationWaveView) {
        self.target = target
        super.init()
    }

    @objc func step(_ link: CADisplayLink) {
        guard let target else {
            link.invalidate()
            return
        }
        target.step()
    }
}

/// A running dictation, drawn as one continuous wave of the sound itself.
///
/// The shape is not decoration and it is not a row of bars. The microphone's loudness is
/// sampled about sixteen times a second, and the ribbon's half-height at any point on the
/// screen *is* the sample taken at the moment that point entered the panel — so the wave
/// swells where a word was said and narrows to a thin line through a pause, and the whole
/// shape travels left as the run goes on. Speaking louder makes it taller immediately;
/// stopping flattens it immediately. Between samples the height is interpolated with a
/// raised cosine, which is what turns the sample points into a smooth curve rather than the
/// staircase a bar meter draws.
///
/// A spectrum drifts behind the ribbon and shows through it, so the run shimmers. The hue
/// is the only decorative part; every height on screen came from the microphone.
private final class AorusAIDictationWaveView: UIView {
    /// How far apart two consecutive columns sit. Wider makes the wave broader.
    private static let samplePitch: CGFloat = 6.0
    /// How fast the strip travels, in points per second. At this pitch that is about twenty
    /// columns a second — faster than the microphone reports, so the shape is smooth rather
    /// than stepped, and steady whatever the audio thread does.
    private static let scrollSpeed: CGFloat = 120.0
    /// A ceiling on the columns one frame may lay down, so a stalled main thread cannot make
    /// the next frame do unbounded work.
    private static let maximumColumnsPerFrame = 8
    /// Half the thickness of the ribbon where nothing was heard, so a silent microphone is
    /// a thin line rather than an empty box.
    private static let silentHalfHeight: CGFloat = 1.25
    /// How much of each end the ribbon tapers over, so it enters and leaves the panel as a
    /// point instead of being sliced off mid-swell.
    private static let taper: CGFloat = 14.0

    /// Seven hues, enough of a sweep to read as a spectrum.
    private static let spectrum: [UIColor] = [
        UIColor(red: 0.36, green: 0.51, blue: 1.00, alpha: 1.0),
        UIColor(red: 0.55, green: 0.36, blue: 1.00, alpha: 1.0),
        UIColor(red: 0.95, green: 0.35, blue: 0.79, alpha: 1.0),
        UIColor(red: 1.00, green: 0.52, blue: 0.35, alpha: 1.0),
        UIColor(red: 0.99, green: 0.80, blue: 0.31, alpha: 1.0),
        UIColor(red: 0.31, green: 0.85, blue: 0.62, alpha: 1.0),
        UIColor(red: 0.24, green: 0.78, blue: 0.96, alpha: 1.0)
    ]

    /// The strip the drift animation slides: the seven hues twice over, closed with the
    /// first one again. Fifteen evenly spaced stops means stop *i* and stop *i + 7* sit
    /// exactly half the strip apart and carry the same colour, so the strip is periodic with
    /// a period of one view width and the animation's jump back to the start is invisible.
    private static let stripColors: [CGColor] = (spectrum + spectrum + [spectrum[0]]).map { $0.cgColor }

    private let gradientHost = CALayer()
    private let gradient = CAGradientLayer()
    private let maskLayer = CAShapeLayer()
    private var displayLink: CADisplayLink?

    /// One column per step of travel, oldest first; the newest is at the right edge.
    private var samples: [CGFloat] = []
    private var capacity = 0
    /// The last loudness the microphone reported, and the value actually being drawn.
    ///
    /// The drawn one chases the reported one every frame — quickly upward, slowly down — so
    /// the wave answers a syllable immediately and falls away smoothly rather than flicking
    /// between two heights.
    private var targetLevel: CGFloat = 0.0
    private var drawnLevel: CGFloat = 0.0
    /// How far the strip has travelled since the last column was laid down, and when the
    /// last frame was drawn.
    ///
    /// Travel is driven by *time*, not by the arrival of microphone samples. Tying it to
    /// arrivals meant the wave advanced only when a buffer came in and then sat still
    /// between them: it drew in bursts, with a visible lag, and stopped altogether whenever
    /// the audio thread was late. Now the strip moves at a constant speed whatever the
    /// microphone is doing, and each new column simply records the loudness at the moment it
    /// was laid down.
    private var scrollOffset: CGFloat = 0.0
    private var lastFrameAt: CFAbsoluteTime = 0.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        gradient.startPoint = CGPoint(x: 0.0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.0, y: 0.5)
        gradient.colors = Self.stripColors
        gradientHost.addSublayer(gradient)
        maskLayer.fillColor = UIColor.black.cgColor
        maskLayer.fillRule = .nonZero
        gradientHost.mask = maskLayer
        layer.addSublayer(gradientHost)
        isAccessibilityElement = true
        accessibilityLabel = aorusAILocalized("Идёт запись", "Recording")
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        displayLink?.invalidate()
    }

    /// Nothing here is themed: the point of the wave is that it is the one saturated thing
    /// in the panel. The hook stays so the composer can configure it like every other part.
    func configure(palette: AorusAIPalette) {
    }

    func setActive(_ active: Bool) {
        displayLink?.invalidate()
        displayLink = nil
        gradient.removeAnimation(forKey: "aorusDrift")
        guard active else {
            samples.removeAll()
            targetLevel = 0.0
            drawnLevel = 0.0
            scrollOffset = 0.0
            lastFrameAt = 0.0
            maskLayer.path = nil
            return
        }
        // A flat line to begin with, so the panel is a waiting microphone rather than an
        // empty box that fills up over the first two seconds.
        samples = Array(repeating: 0.0, count: max(2, capacity))
        targetLevel = 0.0
        drawnLevel = 0.0
        scrollOffset = 0.0
        lastFrameAt = CFAbsoluteTimeGetCurrent()
        // Weakly, through the proxy: a link started here and never stopped would otherwise
        // keep this view alive and redrawing for the rest of the process.
        let link = CADisplayLink(target: AorusAIDisplayLinkProxy(target: self), selector: #selector(AorusAIDisplayLinkProxy.step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        startDrift()
        redraw()
    }

    /// One microphone reading, 0…1 as the recogniser measured it.
    ///
    /// It is recorded, not drawn: the frame loop decides when a column is laid down. That is
    /// what keeps the wave moving at a steady speed however irregularly the audio thread
    /// delivers.
    func update(level: CGFloat) {
        targetLevel = Self.shaped(level)
    }

    /// What a raw level becomes on screen.
    ///
    /// The recogniser hands over `(dBFS + 50) / 50`, which puts the room tone of a quiet
    /// room around 0.2 and ordinary speech between 0.45 and 0.8 — drawn as-is, the wave is
    /// never still and never full, and the difference between silence and a word is a fifth
    /// of the height. The floor is subtracted so silence reaches zero, what is left is
    /// stretched over the whole range, and the square root lifts quiet speech: a word now
    /// uses the whole panel and a pause drops to the line.
    private static func shaped(_ level: CGFloat) -> CGFloat {
        let floorLevel: CGFloat = 0.16
        let span: CGFloat = 0.60
        let above = (min(1.0, max(0.0, level)) - floorLevel) / span
        guard above > 0.0 else { return 0.0 }
        return min(1.0, above).squareRoot()
    }

    /// The colour band slides one full view width and repeats. The strip is periodic over
    /// exactly that distance, so the jump back to the start is invisible.
    private func startDrift() {
        guard bounds.width > 1.0 else { return }
        let drift = CABasicAnimation(keyPath: "position.x")
        drift.fromValue = gradient.position.x
        drift.toValue = gradient.position.x - bounds.width
        drift.duration = 5.0
        drift.repeatCount = .infinity
        drift.isRemovedOnCompletion = false
        gradient.add(drift, forKey: "aorusDrift")
    }

    /// One frame. Called by the proxy, which is what the link actually points at.
    ///
    /// Advances the strip by the time that has passed, lays down a column every time it has
    /// travelled one step, and redraws.
    fileprivate func step() {
        let now = CFAbsoluteTimeGetCurrent()
        let delta = lastFrameAt > 0.0 ? min(0.1, max(0.0, now - lastFrameAt)) : 0.0
        lastFrameAt = now

        // Rises almost at once, falls away over about a fifth of a second. A meter that
        // fell as fast as it rose flickered on every gap between syllables.
        let rate: CGFloat = targetLevel > drawnLevel ? 0.55 : 0.12
        drawnLevel += (targetLevel - drawnLevel) * rate

        scrollOffset += Self.scrollSpeed * CGFloat(delta)
        var laid = 0
        while scrollOffset >= Self.samplePitch, laid < Self.maximumColumnsPerFrame {
            scrollOffset -= Self.samplePitch
            samples.append(drawnLevel)
            laid += 1
        }
        if laid == Self.maximumColumnsPerFrame {
            // A frame that was starved for a long time — the app was in the background, or
            // the main thread stalled. Rather than laying down a hundred identical columns,
            // drop the remainder.
            scrollOffset = 0.0
        }
        let limit = max(2, capacity)
        if samples.count > limit {
            samples.removeFirst(samples.count - limit)
        }
        redraw()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientHost.frame = bounds
        maskLayer.frame = bounds
        // Twice the width, so the colour strip still covers the view at the far end of its
        // travel.
        gradient.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width * 2.0, height: bounds.height)
        CATransaction.commit()
        // Two spare samples: one is sliding out on the left, one is sliding in on the right.
        capacity = max(2, Int(bounds.width / Self.samplePitch) + 2)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        } else if displayLink != nil, samples.count < capacity {
            samples.insert(contentsOf: Array(repeating: 0.0, count: capacity - samples.count), at: 0)
        }
        if displayLink != nil {
            gradient.removeAnimation(forKey: "aorusDrift")
            startDrift()
            redraw()
        }
    }

    /// The wave's half-height at a point, in sample units from the newest sample.
    ///
    /// A raised cosine between the two samples the point falls between. Linear
    /// interpolation would leave a visible corner at every sample and read as a chain of
    /// facets; this joins them into one curve with no corners at all.
    private func halfHeight(atSampleOffset offset: CGFloat) -> CGFloat {
        guard samples.count >= 2 else { return samples.first ?? 0.0 }
        let position = CGFloat(samples.count - 1) - offset
        if position <= 0.0 { return samples[0] }
        if position >= CGFloat(samples.count - 1) { return samples[samples.count - 1] }
        let lower = Int(position)
        let upper = min(samples.count - 1, lower + 1)
        let t = position - CGFloat(lower)
        let smooth = (1.0 - cos(t * .pi)) / 2.0
        return samples[lower] + (samples[upper] - samples[lower]) * smooth
    }

    private func redraw() {
        let width = bounds.width
        let height = bounds.height
        guard width > 1.0, height > 1.0, samples.count >= 2 else { return }
        let middle = height / 2.0
        // 3pt of air top and bottom, so the loudest moment still sits inside the panel.
        let maximumHalf = max(Self.silentHalfHeight, middle - 3.0)
        // How far the strip has travelled past the newest column.
        let shift = min(Self.samplePitch, max(0.0, scrollOffset))

        let stepWidth: CGFloat = 1.0
        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        var x: CGFloat = 0.0
        while x <= width {
            // Distance from the right edge in sample units: the newest sample is drawn at
            // the right edge, and the wave slides left between arrivals.
            let offset = (width - x - shift) / Self.samplePitch
            var value = halfHeight(atSampleOffset: offset)
            // Taper both ends to nothing so the ribbon has points, not cut edges.
            let fromLeft = x / Self.taper
            let fromRight = (width - x) / Self.taper
            value *= min(1.0, max(0.0, min(fromLeft, fromRight)))
            let half = max(Self.silentHalfHeight, value * maximumHalf)
            top.append(CGPoint(x: x, y: middle - half))
            bottom.append(CGPoint(x: x, y: middle + half))
            x += stepWidth
        }
        guard top.count >= 2 else { return }

        let path = UIBezierPath()
        path.move(to: top[0])
        for point in top.dropFirst() {
            path.addLine(to: point)
        }
        for point in bottom.reversed() {
            path.addLine(to: point)
        }
        path.close()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.path = path.cgPath
        CATransaction.commit()
    }
}

private final class AorusAIMessageCell: UITableViewCell, UITextViewDelegate {
    private enum BodySlot {
        case text(AorusAIMentionTextView)
        case code(AorusAICodeCard)
        case quote(AorusAIQuoteCard)
        case table(AorusAITableCard)
        case separator
    }

    private let contentStack = UIStackView()
    /// The message's own box. A plain view on purpose.
    ///
    /// It used to be a `UIVisualEffectView` whose effect was set to nil and never set to
    /// anything else — the real material is `bubbleGlass` — and the body stack was *added*
    /// to its `contentView` while being *constrained* to the effect view itself. Apple
    /// documents that as unsupported, and the reason is exactly the bug it caused: the
    /// content view's frame is written by `UIVisualEffectView.layoutSubviews`, after the
    /// constraint solve and from the previous pass's geometry, so the height reached the
    /// table one pass late. An answer kept the height it had when it was first measured and
    /// the rest of it was clipped — until any later full layout, such as sending another
    /// message, produced the right one. That is the "message appears cut off until I type
    /// something" report.
    private let bubble = UIView()
    private let bubbleGlass = GlassBackgroundView(frame: CGRect())
    private let bodyStack = UIStackView()
    private let statusLabel = UILabel()
    private let workTrail = AorusAIWorkTrailView()
    private let assistantActions = UIStackView()
    private let copyButton = UIButton(type: .system)
    private let regenerateButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let typingIndicator = AorusAITypingIndicatorView()
    /// Raised when the reader taps the work-trail line, which opens it as a sheet.
    var onOpenWorkTrail: (() -> Void)?

    /// A turn is still working until it stops streaming.
    private func configureWorkTrail(message: AorusAIMessage, theme: PresentationTheme) {
        guard message.role == .assistant, !message.workPhases.isEmpty else {
            workTrail.isHidden = true
            return
        }
        let isFinished = message.state != .streaming
        // The server's start wins over the trail's own first phase: a replayed stream
        // rebuilds those phases with local timestamps taken just now, so measuring from
        // them would report a ten-minute turn as having just begun.
        let started = message.turnStartedAt ?? message.workPhases.first?.startedAt
        let duration: TimeInterval?
        if let started, let finished = message.workFinishedAt {
            duration = max(0.0, finished.timeIntervalSince(started))
        } else {
            duration = nil
        }
        workTrail.configure(
            phases: message.workPhases,
            isFinished: isFinished,
            duration: duration,
            theme: theme
        )
    }

    /// `response.start` clears the transient status before the turn itself necessarily
    /// finishes. Keep the latest announced phase as the trail title through that gap;
    /// finished turns still collapse without a permanent duplicate heading.
    private static func workTrailTitle(for message: AorusAIMessage) -> String? {
        // Once the agent has announced a phase, the trail line below is what says what it
        // is doing — and it says it with the highlight crossing it. Repeating the same
        // sentence here would print it twice, one line above the other.
        guard message.workPhases.isEmpty else { return nil }
        if let status = message.statusLabel, !status.isEmpty {
            return status
        }
        return nil
    }
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
        bubble.addSubview(bodyStack)
        // The design puts the progress line *above* the answer — "Читаю профиль диалога…"
        // is what the turn is doing before the text it produces, not a footnote under it.
        statusLabel.font = .systemFont(ofSize: 13.0, weight: .semibold)
        statusLabel.numberOfLines = 0
        // The current action is the title of the trail. Its branches sit directly below;
        // completed work remains readable while the live branch carries the motion.
        workTrail.isHidden = true
        workTrail.onOpen = { [weak self] in self?.onOpenWorkTrail?() }
        contentStack.addArrangedSubview(statusLabel)
        contentStack.addArrangedSubview(workTrail)
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
        // The pane is sized here rather than at configure time: the bubble hugs its text
        // and only knows how wide it is once the stack has laid out.
        if !bubbleGlass.isHidden, bubble.bounds.width > 0.0, bubble.bounds.height > 0.0 {
            bubbleGlass.frame = bubble.bounds
            bubbleGlass.update(
                size: bubble.bounds.size,
                cornerRadius: 20.0,
                isDark: configuredTheme?.overallDarkAppearance ?? true,
                tintColor: GlassBackgroundView.TintColor(kind: .panel),
                isInteractive: false,
                transition: .immediate
            )
        }
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
        let mentions = AorusAIMentionRenderer.map(entities: message.telegramEntities, text: message.rawText)
        let blocks = AorusAIMarkdown.blocks(message.rawText)
        guard Self.signature(blocks: blocks, message: message, mentions: mentions, loadingArtifactIds: loadingArtifactIds) == structureSignature,
              blocks.count == slots.count, blocks.count == slotValues.count else {
            return false
        }
        for index in blocks.indices {
            let value = Self.value(of: blocks[index])
            guard value != slotValues[index] else { continue }
            slotValues[index] = value
            switch (slots[index], blocks[index]) {
            case let (.text(view), .text(source)):
                view.attributedText = AorusAIMarkdown.attributed(source, color: configuredTextColor, accent: configuredAccent, mentions: mentions)
                view.refreshMentionImages()
                // A non-scrolling UITextView does not reliably re-publish its intrinsic
                // height when its attributed text is replaced. Inside a stack view that means
                // the row keeps the height of the *first* delta: the answer went on arriving,
                // the text view stayed one line tall, and the rest of the sentence was
                // clipped — which is what made a finished answer look unfinished. Any later
                // full layout pass fixed it, which is why typing a single character made the
                // whole message appear at once.
                view.invalidateIntrinsicContentSize()
            case let (.code(card), .code(language, code)):
                card.configure(language: language, code: code, theme: theme)
                card.invalidateIntrinsicContentSize()
            case let (.quote(card), .quote(source)):
                card.configure(text: source, theme: theme, textColor: configuredTextColor, mentions: mentions)
                card.invalidateIntrinsicContentSize()
            case let (.table(card), .table(table)):
                card.configure(table: table, theme: theme)
            default:
                return false
            }
        }
        let workTrailTitle = Self.workTrailTitle(for: message)
        statusLabel.text = workTrailTitle
        statusLabel.isHidden = workTrailTitle == nil
        configureWorkTrail(message: message, theme: theme)
        copyText = message.rawText
        assistantActions.isHidden = !(message.role == .assistant && message.state == .complete && canRetry && !message.rawText.isEmpty)
        retryButton.isHidden = !(message.state == .failed && canRetry)
        applyNotice(message: message, theme: theme, canRetry: canRetry)
        applyStreamCaret(message: message, palette: AorusAIPalette.resolve(theme))
        // The stack has to be measured again before the table asks the cell how tall it is;
        // otherwise it answers with the height it had before this text arrived.
        contentStack.setNeedsLayout()
        contentView.setNeedsLayout()
        return true
    }

    private static func value(of block: AorusAIMarkdownBlock) -> String {
        switch block {
        case let .text(value): return value
        case let .code(_, code): return code
        case let .quote(value): return value
        case let .table(value): return value.rawValue
        case .separator: return ""
        }
    }

    /// True while a turn is on the wire and has produced nothing visible yet. Such a turn
    /// gets the typing indicator, so a sent message is never answered by a blank gap.
    private static func showsTyping(blocks: [AorusAIMarkdownBlock], message: AorusAIMessage) -> Bool {
        guard message.role == .assistant, message.state == .streaming else { return false }
        return blocks.isEmpty && message.artifacts.isEmpty
    }

    private static func signature(blocks: [AorusAIMarkdownBlock], message: AorusAIMessage, mentions: [String: AorusAIMention], loadingArtifactIds: Set<String>) -> String {
        var parts: [String] = [message.referencedMessage == nil ? "r0" : "r1"]
        parts.append(showsTyping(blocks: blocks, message: message) ? "y1" : "y0")
        parts.append("n:" + (notice(for: message)?.rawValue ?? ""))
        // A handle that has just resolved changes what the text renders as, so it is part
        // of the structure: the incremental path must not keep drawing the old plain run.
        parts.append("e:" + mentions.keys.sorted().map { "\($0)/\(mentions[$0]?.peerId ?? 0)" }.joined(separator: ","))
        for block in blocks {
            switch block {
            case .text: parts.append("t")
            case let .code(language, _): parts.append("c/\(language ?? "")")
            case .quote: parts.append("q")
            case let .table(table): parts.append("b/\(table.columnCount)")
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
        backgroundColor = palette.plainBackground
        contentView.backgroundColor = palette.plainBackground
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
        // The user's own turn is a pane of the same glass the input is made of, so a
        // question and the field it was typed in are visibly the same material. The
        // assistant's turn stays bare text: two panes facing each other would make the
        // thread a column of boxes.
        bubble.backgroundColor = .clear
        if isUser {
            if bubbleGlass.superview !== bubble {
                bubbleGlass.isUserInteractionEnabled = false
                bubble.insertSubview(bubbleGlass, at: 0)
            }
            bubbleGlass.isHidden = false
        } else {
            bubbleGlass.isHidden = true
        }
        bubble.layer.cornerRadius = isUser ? 20.0 : 0.0
        bubble.layer.cornerCurve = .continuous
        bubble.clipsToBounds = isUser
        bubble.layer.borderWidth = 0.0
        applyBodyInsets(isUser: isUser)

        if let reference = message.referencedMessage {
            let referenceView = AorusAIReferenceCard()
            referenceView.configure(reference: reference, context: context, theme: theme)
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

        // The bubble is neutral in both roles now, so the text keeps the label colour and
        // links keep the accent — no white-on-accent special case.
        let textColor: UIColor = palette.label
        let accent: UIColor = palette.accent
        configuredTextColor = textColor
        configuredAccent = accent
        configuredTheme = theme
        configuredMessageId = message.id
        // Handles are drawn as people inside the sentence they were written in — there is
        // no separate strip of chips and nothing is cut out of the text.
        let mentions = AorusAIMentionRenderer.map(entities: message.telegramEntities, text: message.rawText)
        let blocks = AorusAIMarkdown.blocks(message.rawText)
        structureSignature = Self.signature(blocks: blocks, message: message, mentions: mentions, loadingArtifactIds: loadingArtifactIds)
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
                let view = AorusAIMentionTextView.make()
                view.backgroundColor = .clear
                view.isEditable = false
                view.isScrollEnabled = false
                view.textContainerInset = .zero
                view.textContainer.lineFragmentPadding = 0
                view.delegate = self
                view.linkTextAttributes = [.foregroundColor: accent, .underlineStyle: 0]
                view.configureMentions(context: context, theme: theme)
                // The pill is no longer a link, so its tap arrives here instead of through
                // the text-interaction delegate. Same destination, same URL shape.
                view.onMentionTap = { [weak self] mention in
                    guard let url = URL(string: "aorus-peer://\(mention.peerId)") else { return }
                    self?.onOpenLink?(url)
                }
                view.attributedText = AorusAIMarkdown.attributed(value, color: textColor, accent: accent, mentions: mentions)
                view.refreshMentionImages()
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
                card.configureMentions(context: context, theme: theme)
                card.configure(text: value, theme: theme, textColor: textColor, mentions: mentions)
                bodyStack.addArrangedSubview(card)
                slots.append(.quote(card))
            case let .table(table):
                let card = AorusAITableCard()
                card.onCopied = { [weak self] in self?.onCopy?() }
                card.configure(table: table, theme: theme)
                bodyStack.addArrangedSubview(card)
                slots.append(.table(card))
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

        // A work-trail title is hierarchy, not transient helper copy. Keep it at full ink
        // while the active branch below supplies the animated state.
        statusLabel.textColor = palette.label
        let workTrailTitle = Self.workTrailTitle(for: message)
        statusLabel.text = workTrailTitle
        statusLabel.isHidden = workTrailTitle == nil
        configureWorkTrail(message: message, theme: theme)
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
        // Only a real tap opens anything.
        //
        // UIKit calls this for every kind of text interaction, not just taps: a long press
        // arrives as `.presentActions` and the peek that precedes it as `.preview`. This
        // ignored `interaction` entirely, so pressing and holding a mention pill pushed a
        // controller from inside the gesture while UIKit was still building the text
        // interaction for that same press — which is the crash reported on holding an
        // avatar-and-name pill in an AI chat. Anything that is not the default action is
        // declined without side effects, so a long press now does nothing at all.
        guard interaction == .invokeDefaultAction else {
            return false
        }
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
/// The title of the thread, in Telegram's own navigation capsule.
///
/// `GlassBackgroundView` is the exact view the back button and a chat title sit in — it
/// drives `UIGlassEffect` on iOS 26 and the legacy glass below it — so this pill is the
/// same material, radius and behaviour as the one next to it rather than a `UIBlurEffect`
/// with a border drawn to look like one. Over an opaque page that hand-made version read
/// as a grey slab with a name on it, which is exactly what it was.
private final class AorusAINavigationTitleView: UIView {
    private static let height: CGFloat = 40.0
    private static let horizontalPadding: CGFloat = 14.0

    private let glassView = GlassBackgroundView(frame: CGRect())
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private var isDarkAppearance = false

    init(theme: PresentationTheme) {
        super.init(frame: .zero)
        glassView.isUserInteractionEnabled = false
        titleLabel.text = "AorusAI"
        titleLabel.font = .systemFont(ofSize: 15.0, weight: .semibold)
        titleLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 11.0, weight: .regular)
        statusLabel.textAlignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(glassView)
        addSubview(titleLabel)
        addSubview(statusLabel)
        isAccessibilityElement = true
        accessibilityLabel = "AorusAI"
        update(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(theme: PresentationTheme) {
        isDarkAppearance = theme.overallDarkAppearance
        titleLabel.textColor = theme.rootController.navigationBar.primaryTextColor
        statusLabel.textColor = AorusAIPalette.resolve(theme).secondary
        setNeedsLayout()
    }

    func setStatus(_ text: String?) {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        accessibilityValue = (value?.isEmpty == false) ? value : nil
        guard statusLabel.text != value else { return }
        UIView.transition(with: statusLabel, duration: 0.18, options: [.transitionCrossDissolve, .beginFromCurrentState], animations: {
            self.statusLabel.text = value
        })
        // The capsule hugs its text, so a longer status has to widen it.
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// The pill hugs its widest line rather than standing at a fixed width, the way a chat
    /// title does.
    override var intrinsicContentSize: CGSize {
        let titleWidth = ceil(titleLabel.sizeThatFits(CGSize(width: 260.0, height: Self.height)).width)
        let statusWidth = ceil(statusLabel.sizeThatFits(CGSize(width: 260.0, height: Self.height)).width)
        let width = min(240.0, max(120.0, max(titleWidth, statusWidth) + Self.horizontalPadding * 2.0))
        return CGSize(width: width, height: Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: min(intrinsicContentSize.width, bounds.width), height: min(Self.height, bounds.height))
        guard size.width > 0.0, size.height > 0.0 else { return }
        let frame = CGRect(
            x: floor((bounds.width - size.width) / 2.0),
            y: floor((bounds.height - size.height) / 2.0),
            width: size.width,
            height: size.height
        )
        glassView.frame = frame
        glassView.update(
            size: size,
            cornerRadius: size.height / 2.0,
            isDark: isDarkAppearance,
            tintColor: GlassBackgroundView.TintColor(kind: .panel),
            isInteractive: false,
            transition: .immediate
        )
        let hasStatus = !(statusLabel.text ?? "").isEmpty
        let textWidth = max(0.0, frame.width - Self.horizontalPadding * 2.0)
        if hasStatus {
            titleLabel.frame = CGRect(x: frame.minX + Self.horizontalPadding, y: frame.minY + 4.0, width: textWidth, height: 18.0)
            statusLabel.frame = CGRect(x: frame.minX + Self.horizontalPadding, y: frame.minY + 21.0, width: textWidth, height: 14.0)
        } else {
            titleLabel.frame = CGRect(x: frame.minX + Self.horizontalPadding, y: frame.minY, width: textWidth, height: frame.height)
            statusLabel.frame = .zero
        }
        statusLabel.isHidden = !hasStatus
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
        // The composed label is only read if the card is an element in its own right. A view
        // with accessible subviews is not one by default, so this was assembled and thrown
        // away while VoiceOver read the icon, the title and the body as three separate
        // things. Every other custom view in this file sets the flag; this one was missed.
        isAccessibilityElement = true
        accessibilityLabel = kind.title + (detail.isEmpty ? "" : ". " + detail)
    }

    @objc private func retry() { onRetry?() }
}

private final class AorusAIQuoteCard: UIView {
    private let line = UIView()
    private let textView = AorusAIMentionTextView.make()

    func configureMentions(context: AccountContext, theme: PresentationTheme) {
        textView.configureMentions(context: context, theme: theme)
    }

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

    func configure(text: String, theme: PresentationTheme, textColor: UIColor, mentions: [String: AorusAIMention] = [:]) {
        let palette = AorusAIPalette.resolve(theme)
        let accent = palette.accent
        backgroundColor = palette.fill
        line.backgroundColor = accent
        textView.linkTextAttributes = [.foregroundColor: accent, .underlineStyle: 0]
        textView.attributedText = AorusAIMarkdown.attributed(text, color: textColor, accent: accent, mentions: mentions)
        textView.refreshMentionImages()
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

    func configure(context: AccountContext, entity: AorusAITelegramEntity, theme: PresentationTheme) {
        disposable?.dispose()
        let namePresentationData = context.sharedContext.currentPresentationData.with { $0 }
        nameStrings = namePresentationData.strings
        nameOrder = namePresentationData.nameDisplayOrder
        let accent = AorusAIPalette.resolve(theme).accent
        backgroundColor = accent.withAlphaComponent(0.12)
        titleLabel.textColor = accent
        titleLabel.text = entity.displayName
        accessibilityLabel = aorusAILocalized("Профиль ", "Profile ") + entity.displayName
        // The same ringed circle the inline pills use, so a quoted author and a mention
        // inside the answer next to it are visibly the same kind of thing.
        avatarNode.view.layer.cornerRadius = AorusAIEntityChipView.avatarSize / 2.0
        avatarNode.view.layer.masksToBounds = true
        avatarNode.view.layer.borderWidth = 1.0 + UIScreenPixel
        avatarNode.view.layer.borderColor = accent.cgColor
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

    func configure(reference: AorusAIReferencedMessage, context: AccountContext, theme: PresentationTheme) {
        entityChip?.removeFromSuperview()
        entityChip = nil
        if entityCollapse == nil {
            let collapse = entityContainer.heightAnchor.constraint(equalToConstant: 0.0)
            collapse.priority = .required
            entityCollapse = collapse
        }
        line.backgroundColor = theme.list.itemAccentColor
        let quoteColor = theme.list.itemSecondaryTextColor
        label.textColor = quoteColor
        // A handle inside the quoted message is written as the person, like everywhere else.
        func quote(_ text: String) -> NSAttributedString {
            return AorusAIMentionRenderer.previewText(
                text,
                color: quoteColor,
                font: UIFont.systemFont(ofSize: 13.0),
                accent: theme.list.itemAccentColor
            )
        }
        label.attributedText = quote(reference.text)
        if let rawPeerId = reference.authorPeerId, rawPeerId != 0 {
            let name = reference.authorName ?? aorusAILocalized("Профиль", "Profile")
            let entity = AorusAITelegramEntity(peerId: rawPeerId, username: nil, displayName: name, sourceText: name, rangeLocation: 0, rangeLength: 0)
            let chip = AorusAIEntityChipView()
            chip.configure(context: context, entity: entity, theme: theme)
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
            label.attributedText = quote(author + "\n" + reference.text)
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

/// A GitHub-flavoured Markdown table rendered as one horizontally scrollable surface.
/// Vertical scrolling deliberately stays with the conversation: nested vertical scroll
/// views make long answers feel stuck and fight the table view's pan gesture.
private final class AorusAITableCard: UIView {
    /// A cell is a text view, not a label, for one reason: a label's text cannot be
    /// selected. Holding a figure in a table used to copy the whole cell in one go, which
    /// is not what anyone means by "I want this number" — they want to drag over the part
    /// they need, the way they can in every other piece of text on the screen.
    private final class CellTextView: UITextView {
        static let inset = UIEdgeInsets(top: 9.0, left: 10.0, bottom: 9.0, right: 10.0)

        init() {
            super.init(frame: .zero, textContainer: nil)
            isEditable = false
            isSelectable = true
            isScrollEnabled = false
            textContainerInset = Self.inset
            textContainer.lineFragmentPadding = 0
            textContainer.lineBreakMode = .byWordWrapping
            adjustsFontForContentSizeCategory = false
            // The view supplies the cell's own surface and hairline, so it must not also
            // draw the system's rounded text background.
            layer.cornerRadius = 0
            clipsToBounds = true
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    private let scrollView = UIScrollView()
    private let canvas = UIView()
    private var cells: [[CellTextView]] = []
    /// What each column needs for its own content. `columnWidths` is this stretched to the
    /// card, and the two differ whenever the table is narrower than the bubble it is in.
    private var naturalColumnWidths: [CGFloat] = []
    private var columnWidths: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    private var contentHeight: CGFloat = 0.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10.0
        layer.cornerCurve = .continuous
        clipsToBounds = true
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.directionalLockEnabled = true
        addSubview(scrollView)
        scrollView.addSubview(canvas)
        isAccessibilityElement = false
        canvas.isUserInteractionEnabled = true
    }
    // Overriding both of UIView's designated initializers is also what lets `AorusAITableCard()`
    // keep working: a subclass inherits the parameterless one only when it has overridden every
    // designated initializer above it.
    required init?(coder: NSCoder) { fatalError() }

    /// Raised after something in the table was copied, so the chat can show the same
    /// confirmation it shows for the answer's own Copy button. Selection puts the text on
    /// the pasteboard through the system menu, so nothing here has to.
    var onCopied: (() -> Void)?

    override var intrinsicContentSize: CGSize {
        return CGSize(width: UIView.noIntrinsicMetric, height: max(1.0, contentHeight))
    }

    func configure(table: AorusAIMarkdownTable, theme: PresentationTheme) {
        let palette = AorusAIPalette.resolve(theme)
        backgroundColor = palette.fill
        layer.borderWidth = UIScreenPixel
        layer.borderColor = palette.separator.cgColor

        let rows = [table.headers] + table.rows
        guard !rows.isEmpty, table.columnCount > 0 else {
            canvas.subviews.forEach { $0.removeFromSuperview() }
            cells.removeAll(keepingCapacity: true)
            naturalColumnWidths = []
            columnWidths = []
            rowHeights = []
            contentHeight = 0.0
            invalidateIntrinsicContentSize()
            return
        }

        let bodyFont = UIFont.systemFont(ofSize: 13.5)
        let headerFont = UIFont.systemFont(ofSize: 13.5, weight: .semibold)
        naturalColumnWidths = (0 ..< table.columnCount).map { column in
            var width: CGFloat = 84.0
            for (rowIndex, row) in rows.enumerated() {
                let value = column < row.count ? AorusAIMarkdown.displayTypography(row[column]) : ""
                let font = rowIndex == 0 ? headerFont : bodyFont
                let measured = (value as NSString).size(withAttributes: [.font: font]).width + CellTextView.inset.left + CellTextView.inset.right
                width = max(width, min(220.0, ceil(measured)))
            }
            return width
        }
        columnWidths = naturalColumnWidths

        var renderedRows: [[NSAttributedString]] = []
        rowHeights = []
        for (rowIndex, row) in rows.enumerated() {
            var rendered: [NSAttributedString] = []
            var height: CGFloat = rowIndex == 0 ? 46.0 : 40.0
            for column in 0 ..< table.columnCount {
                let source = column < row.count ? row[column] : ""
                let attributed = AorusAIMarkdown.attributed(source, color: palette.label, accent: palette.accent)
                let mutable = NSMutableAttributedString(attributedString: attributed)
                if rowIndex == 0 {
                    mutable.addAttribute(.font, value: headerFont, range: NSRange(location: 0, length: mutable.length))
                }
                let available = max(1.0, naturalColumnWidths[column] - CellTextView.inset.left - CellTextView.inset.right)
                let bounds = mutable.boundingRect(
                    with: CGSize(width: available, height: 500.0),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                height = max(height, min(104.0, ceil(bounds.height) + CellTextView.inset.top + CellTextView.inset.bottom))
                rendered.append(mutable)
            }
            renderedRows.append(rendered)
            rowHeights.append(height)
        }

        // Streaming tables grow one row (and often one cell) at a time. Keep the existing
        // label grid whenever its shape is still a prefix of the new table; recreating a
        // full 7 x 118 periodic table on every response.delta is needless main-thread work.
        let reusableGrid = cells.isEmpty || (
            cells.count <= rows.count && cells.allSatisfy { $0.count == table.columnCount }
        )
        if !reusableGrid {
            canvas.subviews.forEach { $0.removeFromSuperview() }
            cells.removeAll(keepingCapacity: true)
        }
        for rowIndex in rows.indices {
            var rowCells: [CellTextView] = rowIndex < cells.count ? cells[rowIndex] : []
            for column in 0 ..< table.columnCount {
                let cell: CellTextView
                if column < rowCells.count {
                    cell = rowCells[column]
                } else {
                    cell = CellTextView()
                    canvas.addSubview(cell)
                    rowCells.append(cell)
                }
                cell.attributedText = renderedRows[rowIndex][column]
                cell.textAlignment = table.alignments[column].textAlignment
                cell.tintColor = palette.accent
                // The head of the table is NOT the accent colour. The accent is this app's
                // one loud colour and it is spent on things the reader is meant to act on;
                // a column heading is not one, and a violet bar across every answer that
                // happens to contain a table reads as decoration. It is the same neutral
                // surface every other control in the app sits on, one step up from the
                // body so the heading still separates.
                //
                // And the body rows are all the same. The grey/black banding underneath
                // was a second pattern fighting the hairline grid that already separates
                // the rows, and it is the grid that does that job properly.
                cell.backgroundColor = rowIndex == 0 ? palette.controlFill : .clear
                cell.layer.borderWidth = UIScreenPixel
                cell.layer.borderColor = palette.separator.cgColor
                cell.isAccessibilityElement = true
                if rowIndex == 0 {
                    cell.accessibilityTraits = .header
                    cell.accessibilityLabel = rows[rowIndex][column]
                } else {
                    let header = table.headers[column]
                    let value = rows[rowIndex][column]
                    cell.accessibilityLabel = header.isEmpty ? value : header + ": " + value
                }
            }
            if rowIndex >= cells.count {
                cells.append(rowCells)
            }
        }

        contentHeight = rowHeights.reduce(0.0, +)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        columnWidths = Self.stretched(naturalColumnWidths, toFill: bounds.width)
        let width = columnWidths.reduce(0.0, +)
        canvas.frame = CGRect(x: 0.0, y: 0.0, width: width, height: contentHeight)
        scrollView.contentSize = canvas.bounds.size
        var y: CGFloat = 0.0
        for rowIndex in cells.indices {
            var x: CGFloat = 0.0
            for column in cells[rowIndex].indices where column < columnWidths.count {
                cells[rowIndex][column].frame = CGRect(x: x, y: y, width: columnWidths[column], height: rowHeights[rowIndex])
                x += columnWidths[column]
            }
            y += rowHeights[rowIndex]
        }
    }

    /// The column widths a table of this content should be drawn at inside a card `width`
    /// points wide.
    ///
    /// A two-column table needs perhaps two hundred points and the bubble it sits in is
    /// three hundred and forty. The columns were drawn at what they needed and the rest of
    /// the card stayed bare — a block of the table's own surface to the right of the last
    /// column, which is the "artefact of empty space" it looks like, because that is
    /// exactly what it was. The slack is shared out across the columns instead, in
    /// proportion to what each one asked for, so the table fills its card.
    ///
    /// Only ever wider. A table that genuinely needs more room than the card keeps its
    /// natural widths and scrolls sideways, as it did — and widening a column can only
    /// ever reduce the height its text needs, so the rows measured earlier stay tall
    /// enough and nothing is clipped.
    static func stretched(_ natural: [CGFloat], toFill width: CGFloat) -> [CGFloat] {
        let total = natural.reduce(0.0, +)
        guard !natural.isEmpty, width > 0.0, total > 0.0, total < width else { return natural }
        var result = natural.map { $0 + (width - total) * ($0 / total) }
        // Rounding each column independently loses up to a point per column, which would
        // leave a hairline of bare card at the right edge — the same artefact, smaller.
        // The last column takes whatever the others left.
        for index in result.indices.dropLast() {
            result[index] = (result[index] * 2.0).rounded() / 2.0
        }
        result[result.count - 1] = width - result.dropLast().reduce(0.0, +)
        return result
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
        // Always a button. The card stays tappable when the stated lifetime has passed —
        // the vault decides that now, not the client — so calling it static text told
        // VoiceOver users the one thing that is not true about it.
        accessibilityTraits = .button
        accessibilityLabel = artifact.filename
        accessibilityValue = detailLabel.text
        if isLoading {
            accessibilityHint = aorusAILocalized("Останавливает загрузку", "Stops the download")
        } else {
            accessibilityHint = artifact.isExpired
                ? aorusAILocalized("Проверяет, доступен ли ещё файл", "Checks whether the file is still available")
                : aorusAILocalized("Открывает файл", "Opens the file")
        }
    }
    @objc private func open() { onOpen?() }
}

private struct AorusAIMarkdownTable: Equatable {
    enum Alignment: Equatable {
        case leading
        case center
        case trailing

        var textAlignment: NSTextAlignment {
            switch self {
            case .leading: return .natural
            case .center: return .center
            case .trailing: return .right
            }
        }
    }

    let headers: [String]
    let alignments: [Alignment]
    let rows: [[String]]
    let rawValue: String

    var columnCount: Int { headers.count }
}

private enum AorusAIMarkdownBlock {
    case text(String)
    case code(String?, String)
    case quote(String)
    case table(AorusAIMarkdownTable)
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
        let lines = source.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = table(startingAt: index, in: lines) {
                flushQuote()
                flushPlain()
                result.append(.table(match.table))
                index += match.consumedLines
                continue
            } else if trimmed.range(of: #"^([-*_])(?:\s*\1){2,}$"#, options: .regularExpression) != nil {
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
            index += 1
        }
        flushQuote()
        flushPlain()
    }

    private static func table(startingAt index: Int, in lines: [String]) -> (table: AorusAIMarkdownTable, consumedLines: Int)? {
        guard index + 1 < lines.count,
              let headers = tableCells(in: lines[index]),
              let delimiter = tableCells(in: lines[index + 1]),
              headers.count >= 2, headers.count <= 12,
              delimiter.count == headers.count else {
            return nil
        }
        // One dash or more, which is what GFM actually defines a delimiter cell as
        // (`:?-+:?`). Requiring three silently rejected every table whose separator the
        // model wrote compactly -- `|:-:|`, `|--|`, `|-|` are all legal and all used --
        // and the whole block then fell through to raw text with the pipes showing. That
        // is the "works most of the time" part of the report: it depended on how wide the
        // model happened to draw the rule.
        let delimiterPattern = #"^:?-+:?$"#
        guard delimiter.allSatisfy({ $0.range(of: delimiterPattern, options: .regularExpression) != nil }) else {
            return nil
        }
        let alignments: [AorusAIMarkdownTable.Alignment] = delimiter.map { value in
            if value.hasPrefix(":") && value.hasSuffix(":") { return .center }
            if value.hasSuffix(":") { return .trailing }
            return .leading
        }
        var rows: [[String]] = []
        var cursor = index + 2
        // A hard ceiling prevents an unexpectedly large model response from creating an
        // unbounded number of UIKit views. It still covers full periodic tables and other
        // practical in-chat data sets.
        while cursor < lines.count, rows.count < 160,
              let row = tableCells(in: lines[cursor]) {
            // GFM: a body row may carry any number of cells. Short rows are padded, long
            // rows have the excess ignored — the row is never a reason to stop.
            //
            // Aborting on a long row is the other half of the report. One stray trailing
            // pipe, or one cell the model split in two, ended the table at that line and
            // dumped every remaining row as raw pipes underneath a correct-looking header.
            // During SSE the last row also arrives cell by cell, and padding keeps the
            // answer one stable table instead of flashing a raw line while it lands.
            if row.count >= headers.count {
                rows.append(Array(row.prefix(headers.count)))
            } else {
                rows.append(row + Array(repeating: "", count: headers.count - row.count))
            }
            cursor += 1
        }
        let raw = lines[index ..< cursor].joined(separator: "\n")
        return (
            AorusAIMarkdownTable(headers: headers, alignments: alignments, rows: rows, rawValue: raw),
            cursor - index
        )
    }

    /// Splits a Markdown table row without treating an escaped pipe or a pipe inside
    /// inline code as a column boundary.
    private static func tableCells(in line: String) -> [String]? {
        var value = line.trimmingCharacters(in: .whitespaces)
        guard value.contains("|") else { return nil }
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        var result: [String] = []
        var cell = ""
        var inCode = false
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                cell.append("|")
                index += 2
                continue
            }
            if character == "`" {
                inCode.toggle()
                cell.append(character)
            } else if character == "|", !inCode {
                result.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            index += 1
        }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        return result.count >= 2 ? result : nil
    }

    /// The body face. Answers are set at 16.5/26.
    static let bodyFont = UIFont.systemFont(ofSize: 16.5)

    /// Bold and italic together. UIKit has no system constructor for the pair, so the two
    /// traits are asked of the semibold descriptor; a family that cannot supply them falls
    /// back to plain semibold rather than losing the emphasis altogether.
    private static var boldItalicBodyFont: UIFont {
        let base = UIFont.systemFont(ofSize: 16.5, weight: .semibold)
        guard let descriptor = base.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: 16.5)
    }

    static func attributed(_ source: String, color: UIColor, accent: UIColor, mentions: [String: AorusAIMention] = [:]) -> NSAttributedString {
        // A display equation is lifted out here and put back at the very end, typeset. What
        // is left in its place until then is one OBJECT REPLACEMENT CHARACTER, which no pass
        // below matches and which therefore cannot be split, emphasised or linked by mistake.
        let rendered = AorusAIMath.render(source)
        let normalized = normalizeLists(rendered.text)
        // The leading is expressed as line spacing rather than a fixed line height so a
        // heading in the same paragraph keeps its own ascent instead of being clipped into
        // a 26pt box.
        let output = NSMutableAttributedString(string: normalized, attributes: [.font: bodyFont, .foregroundColor: color])
        applyMarkdownLinks(in: output, accent: accent)
        // Both markers at once, and before either single pass.
        //
        // `apply` strips the delimiters and *sets* .font, so ***text*** used to be eaten by
        // the bold pass into *text* in semibold, and the italic pass then matched what was
        // left and overwrote the font — the bold was lost on exactly the words the model
        // had emphasised hardest.
        apply(pattern: #"\*\*\*(.+?)\*\*\*"#, in: output, font: boldItalicBodyFont)
        apply(pattern: #"\*\*(.+?)\*\*"#, in: output, font: .systemFont(ofSize: 16.5, weight: .semibold))
        apply(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, in: output, font: .italicSystemFont(ofSize: 16.5))
        apply(pattern: #"(?<!\w)_([^_\n]+)_(?!\w)"#, in: output, font: .italicSystemFont(ofSize: 16.5))
        applyStrikethrough(in: output)
        applyInlineCode(in: output, backgroundColor: accent.withAlphaComponent(0.12))
        applyHeadings(in: output)
        applyCalloutLabels(in: output)
        applyLinks(in: output, accent: accent)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6.0
        output.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: output.length))
        applyListParagraphs(in: output)
        // Last, on the finished text: the mention ranges are found in what will actually be
        // drawn, so nothing the markdown pass moved can put a pill on the wrong words.
        AorusAIMentionRenderer.apply(
            to: output,
            resolved: mentions,
            font: bodyFont,
            accent: accent,
            // Not a link, deliberately.
            //
            // A `.link` attribute is what gives UIKit a target for a long press: it builds
            // a preview and an action menu for the range, and doing that over a run that
            // begins with a text attachment is what crashed the app when a pill was held.
            // Declining the interaction in the delegate did not help, because the preview
            // is built before the delegate is consulted. Without the attribute there is no
            // interaction to build at all, and the tap is carried by the text view's own
            // recogniser instead — same behaviour, none of the machinery.
            link: false
        )
        // Last of all, so that no pass after it can move a range out from under an
        // attachment, and so that the placeholders are found in the finished text.
        applyEquations(rendered.equations, in: output, color: color)
        return output
    }

    /// Puts each display equation back where its placeholder is, typeset.
    ///
    /// Only the fractions become drawn attachments. Everything around them — the `= 0`, the
    /// condition after the comma — stays real text that a reader can still select, which is
    /// the whole reason the equation is not simply rendered as one picture.
    private static func applyEquations(_ equations: [[AorusAIMath.Atom]],
                                       in output: NSMutableAttributedString,
                                       color: UIColor) {
        guard !equations.isEmpty else { return }
        let text = output.string as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: text.length)
        while searchRange.length > 0, ranges.count < equations.count {
            let found = text.range(of: AorusAIMath.equationPlaceholder, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: text.length - next)
        }
        // Back to front: replacing one equation must not move the ranges of the others.
        for (index, range) in zip(ranges.indices, ranges).reversed() {
            output.replaceCharacters(in: range, with: typeset(equations[index], color: color))
        }
    }

    private static func typeset(_ atoms: [AorusAIMath.Atom], color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for atom in atoms {
            switch atom {
            case let .text(value):
                result.append(NSAttributedString(string: value, attributes: [
                    .font: bodyFont, .foregroundColor: color,
                ]))
            case let .fraction(numerator, denominator):
                let attachment = AorusAIMathTypesetter.attachment(
                    numerator: numerator, denominator: denominator,
                    font: bodyFont, color: color
                )
                result.append(NSAttributedString(attachment: attachment))
            }
        }
        // A display equation is centred and given room, which is what makes it read as one
        // rather than as a sentence that happens to contain a bar.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6.0
        paragraph.paragraphSpacingBefore = 6.0
        paragraph.lineSpacing = 6.0
        result.addAttribute(.paragraphStyle, value: paragraph,
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    /// The text form: a table cell, a quote, anywhere a run of text is all there is and a
    /// display equation has nowhere to go. The rules themselves live in AorusAIMath, where
    /// they can be compiled and tested on their own.
    static func displayTypography(_ source: String) -> String {
        return normalizeLists(AorusAIMath.typography(source))
    }

    private static func normalizeLists(_ source: String) -> String {
        return source.components(separatedBy: .newlines).map { line in
            if let regex = try? NSRegularExpression(pattern: #"^(\s*)[-*+]\s+\[([ xX])\]\s+(.+)$"#),
               let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let nsLine = line as NSString
                let mark = nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces).isEmpty ? "☐" : "☑︎"
                return nsLine.substring(with: match.range(at: 1)) + mark + " " + nsLine.substring(with: match.range(at: 3))
            }
            guard let regex = try? NSRegularExpression(pattern: #"^(\s*)[-*+]\s+(.+)$"#),
                  let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
                return line
            }
            let nsLine = line as NSString
            return nsLine.substring(with: match.range(at: 1)) + "• " + nsLine.substring(with: match.range(at: 2))
        }.joined(separator: "\n")
    }

    private static func replacing(pattern: String, in source: String, transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let result = NSMutableString(string: source)
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
        for match in matches.reversed() {
            var captures: [String] = []
            for index in 1 ..< match.numberOfRanges {
                captures.append((source as NSString).substring(with: match.range(at: index)))
            }
            result.replaceCharacters(in: match.range, with: transform(captures))
        }
        return result as String
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

    private static func applyStrikethrough(in value: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: #"~~([^~\n]+)~~"#) else { return }
        for match in regex.matches(in: value.string, range: NSRange(location: 0, length: value.length)).reversed() {
            let text = (value.string as NSString).substring(with: match.range(at: 1))
            value.replaceCharacters(in: match.range, with: text)
            value.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: match.range.location, length: (text as NSString).length))
        }
    }

    /// Short labels introducing an example or result should read as structure, not as the
    /// first words of the following sentence. Explicit Markdown remains authoritative;
    /// this is only the compact convention models commonly emit without Markdown.
    private static func applyCalloutLabels(in value: NSMutableAttributedString) {
        let pattern = #"(?im)^(пример(?:\s+\d+)?|решение|ответ|итог|важно|example(?:\s+\d+)?|solution|answer|result|important):"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for match in regex.matches(in: value.string, range: NSRange(location: 0, length: value.length)) {
            value.addAttribute(.font, value: UIFont.systemFont(ofSize: 16.5, weight: .semibold), range: match.range)
        }
    }

    private static func applyListParagraphs(in value: NSMutableAttributedString) {
        let pattern = #"(?m)^\s*(?:•|☐|☑︎|\d+[.)])\s+.*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for match in regex.matches(in: value.string, range: NSRange(location: 0, length: value.length)) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6.0
            paragraph.firstLineHeadIndent = 0.0
            paragraph.headIndent = 20.0
            value.addAttribute(.paragraphStyle, value: paragraph, range: match.range)
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
            value.addAttribute(.font, value: aorusAITitleFont(size: size, weight: .semibold), range: NSRange(location: match.range.location, length: (text as NSString).length))
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
    /// Every handle in `text`, pre-filled from the session's mention cache.
    ///
    /// A handle this session has already resolved comes back carrying its peer, so the
    /// pill is drawn on the same frame the text appears in rather than one network round
    /// trip later. A handle nobody has looked up yet comes back unresolved and is drawn
    /// as plain text until it is.
    static func entities(in text: String) -> [AorusAITelegramEntity] {
        return AorusAIMentionScanner.matches(in: text).map { match in
            let source = (text as NSString).substring(with: match.range)
            let cached = AorusAIMentionStore.shared.lookup(match.username)
            return AorusAITelegramEntity(
                peerId: cached?.peerId,
                username: match.username,
                displayName: cached?.displayName ?? match.username,
                sourceText: source,
                rangeLocation: match.range.location,
                rangeLength: match.range.length
            )
        }
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
        case .resumeNotFound: return "resume_not_found"
        case .resumeUnavailable: return "resume_journal_unavailable"
        case .turnInProgress: return "turn_in_progress"
        case let .turnControlRejected(code): return code
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
        case let .artifactRejected(reason): return "artifact_rejected_" + reason
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
        // Turn control rarely reaches the reader — a resume that finds nothing is the
        // ordinary answer for a finished chat and is handled before it becomes an error.
        // If one does surface, it says what happened rather than "temporarily unavailable".
        case .resumeNotFound: return aorusAILocalized("Прошлый ответ уже завершён", "The previous answer has already finished")
        case .resumeUnavailable: return aorusAILocalized("Не удалось восстановить прошлый ответ", "The previous answer could not be restored")
        case .turnInProgress: return aorusAILocalized("Ответ ещё выполняется", "The answer is still running")
        case .turnControlRejected: return aorusAILocalized("Не удалось подтвердить ответ", "The answer could not be confirmed")
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
        // The token names the guard that refused, so a report says what happened instead
        // of repeating the same blank sentence for six different causes.
        case let .artifactRejected(reason): return aorusAILocalized("Не удалось скачать файл (\(reason))", "The file could not be downloaded (\(reason))")
        case .cancelled: return aorusAILocalized("Остановлено", "Stopped")
        // The status is named: without it every gateway refusal reached the user, and
        // the next bug report, as one indistinguishable sentence.
        case let .http(status): return aorusAILocalized("Не удалось выполнить запрос (код \(status)). Попробуйте ещё раз.", "The request could not be completed (code \(status)). Please try again.")
        }
    }
}

/// The numbers the consent surface and the executor have to agree on.
///
/// They are one declaration because the sheet promises an amount and the executor hands
/// one over: if a button could say fifty while the reader took a different default, the
/// promise on screen would be a lie. `optionTitle` is the same sentence spoken aloud for
/// VoiceOver, so the spoken and the drawn answer never diverge either.
enum AorusAIChatDefaults {
    /// What a permission option shares when it names no number of its own.
    static let historyLimit = 50

    static func messageCount(for option: AorusAIPermissionOption) -> Int {
        return min(AorusAIRequestLimits.chatHistoryMessageCount, max(1, option.limit ?? historyLimit))
    }

    /// What one choice will actually do, in the client's own words.
    static func optionTitle(_ option: AorusAIPermissionOption) -> String {
        if option.isPeriod {
            return aorusAILocalized("Выбрать период", "Choose a period")
        }
        let count = messageCount(for: option)
        return aorusAILocalized(
            "Передать \(count) \(aorusAIMessageWord(count))",
            count == 1 ? "Share 1 message" : "Share \(count) messages"
        )
    }
}

/// Russian needs three forms of "message" and the count decides which one.
func aorusAIMessageWord(_ count: Int) -> String {
    let tail = count % 100
    if tail >= 11 && tail <= 14 { return "сообщений" }
    switch count % 10 {
    case 1: return "сообщение"
    case 2, 3, 4: return "сообщения"
    default: return "сообщений"
    }
}

/// A filled button that answers to being pressed.
///
/// `UIButton` dims only its *title* on touch, which on a surface of its own reads as
/// nothing happening: the panel the finger is on stays exactly as it was. The rows above
/// this button darken their whole surface, so it does the same.
private final class AorusAIFilledButton: UIButton {
    private var fill: UIColor = .clear
    private var fillHighlighted: UIColor = .clear

    func configure(fill: UIColor, highlighted: UIColor) {
        self.fill = fill
        self.fillHighlighted = highlighted
        backgroundColor = isHighlighted ? highlighted : fill
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? fillHighlighted : fill
        }
    }
}

/// One choice on the sheet: a count of messages, or the date range.
private final class AorusAIScopeRowView: UIControl {
    private let countLabel = UILabel()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let noteLabel = UILabel()
    private let separator = UIView()
    private let highlight = UIView()

    /// The figures sit in a column of their own so the choices read as the scale they
    /// are. 40pt holds three digits at this size.
    private static let countColumn: CGFloat = 40.0
    private static let inset: CGFloat = 16.0
    static let height: CGFloat = 54.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        highlight.alpha = 0.0
        highlight.isUserInteractionEnabled = false
        addSubview(highlight)
        // Tabular figures: 20 and 200 have to line up, or the column stops being a scale.
        countLabel.font = aorusAIMonoFont(size: 19.0, weight: .semibold)
        countLabel.textAlignment = .right
        iconView.contentMode = .center
        titleLabel.font = .systemFont(ofSize: 16.0)
        noteLabel.font = .systemFont(ofSize: 13.0)
        noteLabel.textAlignment = .right
        [countLabel, iconView, titleLabel, noteLabel, separator].forEach { addSubview($0) }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int?, title: String, note: String?, isLast: Bool, palette: AorusAIPalette, tint: UIColor) {
        highlight.backgroundColor = palette.fill
        if let count {
            countLabel.text = "\(count)"
            countLabel.textColor = tint
            countLabel.isHidden = false
            iconView.isHidden = true
        } else {
            countLabel.isHidden = true
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "calendar")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 17.0, weight: .medium))
            iconView.tintColor = tint
        }
        titleLabel.text = title
        titleLabel.textColor = palette.label
        noteLabel.text = note
        noteLabel.textColor = tint
        noteLabel.isHidden = (note ?? "").isEmpty
        separator.backgroundColor = palette.separator
        separator.isHidden = isLast
        setNeedsLayout()
    }

    override var isHighlighted: Bool {
        didSet {
            highlight.alpha = isHighlighted ? 1.0 : 0.0
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        highlight.frame = bounds
        let inset = Self.inset
        countLabel.frame = CGRect(x: inset, y: 0.0, width: Self.countColumn, height: bounds.height)
        iconView.frame = countLabel.frame
        let titleX = inset + Self.countColumn + 12.0
        let noteWidth = noteLabel.isHidden ? 0.0 : ceil(noteLabel.sizeThatFits(CGSize(width: bounds.width, height: bounds.height)).width)
        noteLabel.frame = CGRect(x: bounds.width - inset - noteWidth, y: 0.0, width: noteWidth, height: bounds.height)
        let titleRight = noteLabel.isHidden ? (bounds.width - inset) : (noteLabel.frame.minX - 8.0)
        titleLabel.frame = CGRect(x: titleX, y: 0.0, width: max(0.0, titleRight - titleX), height: bounds.height)
        separator.frame = CGRect(x: titleX, y: bounds.height - UIScreenPixel, width: max(0.0, bounds.width - titleX), height: UIScreenPixel)
    }
}

/// Choosing how much of a conversation AorusAI may read.
///
/// This replaces a stock action sheet whose every row said the same word followed by a
/// different number, in the same colour, in the order the payload happened to list them.
/// The one thing the person is deciding here is *how much*, so that is what the surface
/// is built around: the peer at the top so there is no doubt whose chat it is, the
/// choices ordered by how much they hand over, and the figures in a column of tabular
/// digits so the difference between twenty and two hundred is visible rather than read.
/// The largest option is the only one that carries the destructive colour, because it is
/// the only one that hands over everything the client is willing to send. Choosing a date
/// range is set apart at the end: it is a different kind of answer, not a bigger number.
private final class AorusAIShareScopeController: UIViewController {
    private let context: AccountContext
    private let palette: AorusAIPalette
    private let theme: PresentationTheme
    private let username: String?
    private let explanation: String?
    private let options: [AorusAIPermissionOption]
    private let onSelect: (AorusAIPermissionOption) -> Void
    private let onCancel: () -> Void
    private var didAnswer = false
    /// The options in the order the rows show them, decided once in `buildRows`.
    private var orderedOptions: [AorusAIPermissionOption] = []

    /// A sheet that goes away without being answered still answers.
    ///
    /// Every button and the dimming tap call back exactly once, but a sheet torn down with
    /// the screen behind it — the conversation popped, the app's window rebuilt — calls back
    /// not at all. The turn then waits for an answer that can never arrive: the header
    /// spinner never stops, the send button stays a stop button, and the active-turn centre
    /// keeps a strong reference to the whole controller for the life of the process, with a
    /// floating capsule to match. Deallocating counts as declining.
    deinit {
        peerDisposable.dispose()
        if let avatarObserver {
            NotificationCenter.default.removeObserver(avatarObserver)
        }
        guard !didAnswer else { return }
        didAnswer = true
        onCancel()
    }

    private let dimView = UIView()
    private let card = UIView()
    private let grabber = UIView()
    // The same picture the pills in the thread are drawn with, rather than an `AvatarNode`
    // of this sheet's own.
    //
    // Those pills work: the message above this sheet shows the peer's photo next to their
    // name at the moment the sheet below shows a grey monogram for that same peer. An
    // `AvatarNode` has to be handed a peer *and* a size, and this sheet learns the two at
    // different times — the resolve answers synchronously for anyone already in the
    // database, inside `viewDidLoad`, where the avatar is still zero points wide. The cache
    // takes a peer id and a diameter, returns a monogram immediately, draws the photo off
    // the main thread and posts when it is ready. There is no order to get wrong.
    private let avatarView = UIImageView()
    /// Who the avatar is drawing, once the peer is known.
    private var avatarMention: AorusAIMention?
    private var avatarObserver: NSObjectProtocol?
    private let titleLabel = UILabel()
    private let peerLabel = UILabel()
    private let bodyLabel = UILabel()
    private let rowsContainer = UIView()
    private var rows: [AorusAIScopeRowView] = []
    // `init(frame:)` rather than `init(type:)`: `+buttonWithType:` is a factory that decides
    // the class it returns, and the subclass is the whole point of this one.
    private let cancelButton = AorusAIFilledButton()
    private let peerDisposable = MetaDisposable()
    private var didAnimateIn = false
    /// How far below its resting place the card sits, honoured by `viewDidLayoutSubviews`.
    private var cardOffset: CGFloat = 0.0

    init(
        context: AccountContext,
        theme: PresentationTheme,
        username: String?,
        explanation: String?,
        options: [AorusAIPermissionOption],
        onSelect: @escaping (AorusAIPermissionOption) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.context = context
        self.theme = theme
        self.palette = AorusAIPalette.resolve(theme)
        self.username = username
        self.explanation = explanation
        self.options = options
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .overFullScreen
        // No `modalTransitionStyle`: this sheet is presented and dismissed un-animated and
        // animates itself, so UIKit's transition would only add a beat before or after it.
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.backgroundColor = UIColor(white: 0.0, alpha: 0.4)
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cancelTapped)))
        view.addSubview(dimView)

        card.backgroundColor = palette.elevated
        card.layer.cornerRadius = 20.0
        card.layer.cornerCurve = .continuous
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.addSubview(card)

        grabber.backgroundColor = palette.separator
        grabber.layer.cornerRadius = 2.5
        card.addSubview(grabber)

        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        card.addSubview(avatarView)
        AorusAIMentionAvatarCache.shared.use(context: context)
        // Redrawn when the photo lands: the cache answers with a monogram first and posts
        // once the real picture has been drawn.
        avatarObserver = NotificationCenter.default.addObserver(
            forName: AorusAIMentionAvatarCache.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAvatar()
        }

        titleLabel.text = aorusAILocalized("Сколько показать AorusAI", "How much to show AorusAI")
        titleLabel.font = .systemFont(ofSize: 20.0, weight: .semibold)
        titleLabel.textColor = palette.label
        titleLabel.numberOfLines = 2
        card.addSubview(titleLabel)

        peerLabel.text = username.map { "@\($0)" }
        peerLabel.font = .systemFont(ofSize: 14.0)
        peerLabel.textColor = palette.secondary
        card.addSubview(peerLabel)

        var body = aorusAILocalized(
            "Будут прочитаны только последние сообщения этой переписки — столько, сколько вы выберете. Ничего не уходит, пока вы не выбрали.",
            "Only the most recent messages of this chat are read — as many as you choose. Nothing is sent until you choose."
        )
        if let explanation = explanation?.trimmingCharacters(in: .whitespacesAndNewlines), !explanation.isEmpty {
            body += "\n\n" + String(explanation.prefix(300))
        }
        bodyLabel.text = body
        bodyLabel.font = .systemFont(ofSize: 15.0)
        bodyLabel.textColor = palette.secondary
        bodyLabel.numberOfLines = 0
        card.addSubview(bodyLabel)

        rowsContainer.backgroundColor = palette.fill
        rowsContainer.layer.cornerRadius = 14.0
        rowsContainer.layer.cornerCurve = .continuous
        rowsContainer.clipsToBounds = true
        card.addSubview(rowsContainer)
        buildRows()

        cancelButton.setTitle(aorusAILocalized("Не делиться", "Don't share"), for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17.0, weight: .semibold)
        cancelButton.setTitleColor(palette.label, for: .normal)
        // Its own surface rather than the panel fill the rows sit on: those rows carry
        // figures, titles and hairlines that make the panel legible, and a button carrying
        // one line of label-coloured text on the same fill read as no button at all.
        cancelButton.configure(fill: palette.controlFill, highlighted: palette.controlFillHighlighted)
        cancelButton.layer.cornerRadius = 14.0
        cancelButton.layer.cornerCurve = .continuous
        cancelButton.clipsToBounds = true
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        card.addSubview(cancelButton)

        resolvePeer()
    }

    /// The options are shown smallest first, whatever order the payload listed them in:
    /// the row above always hands over less than the row below.
    private func buildRows() {
        let counted = options.filter { !$0.isPeriod }.sorted { ($0.limit ?? 0) < ($1.limit ?? 0) }
        let periods = options.filter { $0.isPeriod }
        let ordered = counted + periods
        // Kept, so the tap reads back the very order the rows were built in.
        orderedOptions = ordered
        let ceilingLimit = counted.compactMap({ $0.limit }).max()
        for (index, option) in ordered.enumerated() {
            let row = AorusAIScopeRowView()
            let isLast = index == ordered.count - 1
            if option.isPeriod {
                row.configure(
                    count: nil,
                    title: aorusAILocalized("Выбрать период", "Choose a period"),
                    note: nil,
                    isLast: isLast,
                    palette: palette,
                    tint: palette.accent
                )
            } else {
                let count = AorusAIChatDefaults.messageCount(for: option)
                let isCeiling = count == ceilingLimit && ordered.count > 1
                row.configure(
                    count: count,
                    title: aorusAILocalized(
                        "последних \(aorusAIMessageWord(count))",
                        count == 1 ? "most recent message" : "most recent messages"
                    ),
                    // Only the largest is marked, and only because it is the largest.
                    note: isCeiling ? aorusAILocalized("максимум", "maximum") : nil,
                    isLast: isLast,
                    palette: palette,
                    tint: isCeiling ? theme.list.itemDestructiveColor : palette.accent
                )
            }
            row.accessibilityLabel = AorusAIChatDefaults.optionTitle(option)
            row.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
            rowsContainer.addSubview(row)
            rows.append(row)
        }
    }

    private func resolvePeer() {
        // The handle arrives in the payload, so its exact spelling is the backend's choice.
        // `resolvePeerByName` wants the bare name: given "@durov" it finds nobody, and the
        // sheet would then sit on a monogram with no way to tell that from a peer who
        // simply has no photo.
        let handle = (username ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "@ \n\t"))
        guard !handle.isEmpty else { return }
        // The session's own record of this handle is enough to draw the person: the cache
        // takes an id and a name. It is the same record the pill in the message above this
        // sheet is drawn from, which is why that pill shows a photo.
        if let cached = AorusAIMentionStore.shared.lookup(handle) {
            peerLabel.text = cached.displayName
            setAvatar(peerId: cached.peerId, displayName: cached.displayName, handle: handle)
        }
        peerDisposable.set((context.engine.peers.resolvePeerByName(name: handle, referrer: nil)
        |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self, case let .result(peer) = result, let peer else { return }
            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            let name = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
            self.peerLabel.text = name
            self.setAvatar(peerId: peer.id.toInt64(), displayName: name, handle: handle)
        }))
    }

    /// Points the avatar at a person. Safe to call twice with the same one.
    private func setAvatar(peerId: Int64, displayName: String, handle: String) {
        guard peerId != 0 else { return }
        let mention = AorusAIMention(sourceText: "@" + handle, username: handle, peerId: peerId, displayName: displayName)
        guard avatarMention != mention else { return }
        avatarMention = mention
        refreshAvatar()
    }

    /// Draws whoever the avatar is pointed at, at whatever size it currently has.
    ///
    /// Called from the layout pass, from the resolve, and from the cache's notification —
    /// all three, because none of them is guaranteed to be last. The cache answers
    /// immediately with a monogram and again with the photo once it is drawn, so calling it
    /// more often than needed costs a dictionary lookup.
    private func refreshAvatar() {
        let side = avatarView.bounds.width
        guard side > 0.0, let mention = avatarMention else { return }
        avatarView.image = AorusAIMentionAvatarCache.shared.image(for: mention, diameter: side, ring: palette.accent)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        dimView.frame = view.bounds

        let width = view.bounds.width
        let side: CGFloat = 20.0
        let contentWidth = max(0.0, width - side * 2.0)
        let bottomInset = view.safeAreaInsets.bottom

        let avatarSize: CGFloat = 40.0
        let headerTop: CGFloat = 22.0
        let titleX = side + avatarSize + 12.0
        let titleWidth = max(0.0, width - titleX - side)
        let titleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let peerHeight: CGFloat = (peerLabel.text ?? "").isEmpty ? 0.0 : 18.0
        let headerHeight = max(avatarSize, titleHeight + (peerHeight > 0.0 ? peerHeight + 2.0 : 0.0))

        let bodyTop = headerTop + headerHeight + 14.0
        let bodyHeight = ceil(bodyLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
        let rowsTop = bodyTop + bodyHeight + 18.0
        let rowsHeight = AorusAIScopeRowView.height * CGFloat(rows.count)
        let cancelTop = rowsTop + rowsHeight + 12.0
        let cancelHeight: CGFloat = 50.0
        let cardHeight = cancelTop + cancelHeight + 12.0 + bottomInset

        // 40pt of overhang below the screen so a spring that overshoots never shows a gap.
        // `cardOffset` is how far below its resting place the card currently sits, and it is
        // part of the layout rather than a transform: this method assigns `card.frame` on
        // every pass, and assigning a frame to a transformed view resolves it in the
        // transformed space — the card would land somewhere else entirely.
        card.frame = CGRect(x: 0.0, y: view.bounds.height - cardHeight + cardOffset, width: width, height: cardHeight + 40.0)
        grabber.frame = CGRect(x: floor((width - 36.0) / 2.0), y: 8.0, width: 36.0, height: 5.0)

        let avatarFrame = CGRect(x: side, y: headerTop, width: avatarSize, height: avatarSize)
        avatarView.frame = avatarFrame
        avatarView.layer.cornerRadius = avatarSize / 2.0
        // Unconditionally, not only when the frame changed: the peer usually resolves after
        // the frame has settled, and this is the pass that knows the size to draw at.
        refreshAvatar()
        titleLabel.frame = CGRect(x: titleX, y: headerTop, width: titleWidth, height: titleHeight)
        peerLabel.frame = CGRect(x: titleX, y: titleLabel.frame.maxY + 2.0, width: titleWidth, height: peerHeight)
        bodyLabel.frame = CGRect(x: side, y: bodyTop, width: contentWidth, height: bodyHeight)
        rowsContainer.frame = CGRect(x: side, y: rowsTop, width: contentWidth, height: rowsHeight)
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 0.0, y: AorusAIScopeRowView.height * CGFloat(index), width: contentWidth, height: AorusAIScopeRowView.height)
        }
        cancelButton.frame = CGRect(x: side, y: cancelTop, width: contentWidth, height: cancelHeight)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !didAnimateIn else { return }
        // The start state belongs *before* the sheet is on screen. It used to be set in
        // `viewDidAppear`, which runs after the presentation has finished — so the card
        // faded in at its resting place, then jumped a full height downwards and slid back
        // up. That is the double, jerky appearance. The screen's height is used rather than
        // the card's because it needs no layout to be known and is always enough to be clear
        // of the bottom edge.
        let travel = view.bounds.height > 0.0 ? view.bounds.height : UIScreen.main.bounds.height
        prepareForPresentation(offset: travel)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAnimateIn else { return }
        didAnimateIn = true
        animateIn()
    }

    /// Puts the sheet in its off-screen state and lays it out there.
    private func prepareForPresentation(offset: CGFloat) {
        cardOffset = offset
        dimView.alpha = 0.0
        view.layoutIfNeeded()
    }

    /// The entrance in reverse, and only then the dismissal — so the sheet leaves the way it
    /// arrived instead of cross-fading in place. `answer` runs after it is gone, which is the
    /// contract every caller already relied on.
    private func animateOut(_ answer: @escaping () -> Void) {
        cardOffset = view.bounds.height
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.26, delay: 0.0, options: [.curveEaseIn]) {
            self.dimView.alpha = 0.0
            self.view.layoutIfNeeded()
        } completion: { [weak self] _ in
            guard let self else {
                answer()
                return
            }
            self.dismiss(animated: false, completion: answer)
        }
    }

    /// One beat: the dim comes up while the card springs into place.
    private func animateIn() {
        cardOffset = 0.0
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.42, delay: 0.0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.dimView.alpha = 1.0
            self.view.layoutIfNeeded()
        }
    }

    @objc private func rowTapped(_ sender: AorusAIScopeRowView) {
        guard let index = rows.firstIndex(of: sender), !didAnswer else { return }
        // The order the rows were built in, not a second sort of the same array. Swift's
        // sort is not stable, so two options sharing a `limit` — the payload may send eight
        // — could be ordered differently by the two passes, and the sheet would then submit
        // an option other than the one whose label the user read. On a consent surface that
        // is the one mistake that must be impossible.
        let ordered = orderedOptions
        guard index < ordered.count else { return }
        didAnswer = true
        let option = ordered[index]
        animateOut { [weak self] in self?.onSelect(option) }
    }

    @objc private func cancelTapped() {
        guard !didAnswer else { return }
        didAnswer = true
        animateOut { [weak self] in self?.onCancel() }
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

    /// A sheet that goes away without being answered still answers.
    ///
    /// Every button and the dimming tap call back exactly once, but a sheet torn down with
    /// the screen behind it — the conversation popped, the app's window rebuilt — calls back
    /// not at all. The turn then waits for an answer that can never arrive: the header
    /// spinner never stops, the send button stays a stop button, and the active-turn centre
    /// keeps a strong reference to the whole controller for the life of the process, with a
    /// floating capsule to match. Deallocating counts as declining.
    deinit {
        guard !didAnswer else { return }
        didAnswer = true
        onCancel()
    }

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

    /// Posted whenever the set of conversations with a live turn changes, so the list
    /// can light the ones that are working. Carries nothing: the reader of the list
    /// asks `isBusy` per row, which cannot go stale between the post and the reload.
    static let activeTurnsChanged = Notification.Name("aorusgram.ai.activeTurnsChanged")

    private struct Entry {
        let controller: AorusAIChatController
        let conversationId: UUID
        let reopen: (AorusAIChatController) -> Void
    }

    private var entries: [String: Entry] = [:]
    /// Newest hold last: the indicator speaks for the most recent turn.
    private var order: [String] = []
    /// The finished-work notice. It appears when a turn ENDS rather than while it
    /// runs: a capsule that sits on screen for the whole of a long turn is noise, and
    /// the list now carries that state instead.
    private let notice = AorusAINoticeCapsule()
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
        entries[key] = Entry(controller: controller, conversationId: controller.conversationIdentifier, reopen: reopen)
        order.removeAll(where: { $0 == key })
        order.append(key)
        announceChange()
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
        announceChange()
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
        announceChange()
    }

    /// Whether this conversation has a turn running right now. Asked per row by the
    /// list, which is why it is a lookup rather than a snapshot handed out once.
    func isBusy(conversationId: UUID) -> Bool {
        return entries.values.contains(where: { $0.conversationId == conversationId })
    }

    /// Whether that turn is waiting on the reader rather than working.
    func needsAttention(conversationId: UUID) -> Bool {
        for (key, entry) in entries where entry.conversationId == conversationId {
            if attentionKeys.contains(key) { return true }
        }
        return false
    }

    private func announceChange() {
        NotificationCenter.default.post(name: AorusAIActiveTurnCenter.activeTurnsChanged, object: nil)
    }

    /// The in-app notice that a turn has finished. Not a push: it is a capsule in the
    /// app's own window, it says how long the work took, and tapping it opens the chat
    /// that produced it.
    func announceFinished(
        conversationId: UUID,
        title: String,
        duration: TimeInterval?,
        theme: PresentationTheme,
        onTap: @escaping () -> Void
    ) {
        let headline = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? aorusAILocalized("AorusAI закончил работу", "AorusAI has finished")
            : title
        let detail = AorusAIWorkTrailView.summaryText(duration: duration)
        notice.present(in: nil, theme: theme, title: headline, detail: detail, onTap: onTap)
        announceChange()
    }

    private func reopenLatest() {
        guard let key = order.last, let entry = entries[key] else { return }
        entry.reopen(entry.controller)
    }
}

/// The floating "AorusAI has finished" capsule.
///
/// It appears when a turn ENDS, not while it runs: a capsule that sits there for the
/// whole of a long turn is noise, and the conversation list now carries the working
/// state instead. This is the in-app notification the brief asks for — not a push, just
/// the app's own window — and one tap goes to the answer. Native glass only: the blocks
/// background, a hairline border, no tint and no white.
private final class AorusAINoticeCapsule: NSObject {
    private let container = UIButton(type: .custom)
    private let glyph = UIImageView()
    private let label = UILabel()
    private let detailLabel = UILabel()
    /// Auto-dismissal. A notice that never leaves is a notice nobody reads twice.
    private var dismissWork: DispatchWorkItem?
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
        label.font = .systemFont(ofSize: 13.0, weight: .semibold)
        label.isUserInteractionEnabled = false
        label.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.isUserInteractionEnabled = false
        detailLabel.lineBreakMode = .byTruncatingTail
        glyph.isUserInteractionEnabled = false
        glyph.contentMode = .scaleAspectFit
        glyph.image = UIImage(
            systemName: "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16.0, weight: .semibold)
        )
        [glyph, label, detailLabel].forEach { container.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44.0),
            glyph.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12.0),
            glyph.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 18.0),
            glyph.heightAnchor.constraint(equalToConstant: 18.0),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 9.0),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14.0),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6.0),
            detailLabel.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1.0),
            detailLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6.0)
        ])
        container.addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    /// Installs the capsule in `window`, or just refreshes it when it is already there.
    func present(in window: UIWindow?, theme: PresentationTheme, title: String, detail: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        self.isDismissing = false
        setText(title, detail: detail)
        let palette = AorusAIPalette.resolve(theme)
        container.backgroundColor = palette.elevated
        container.layer.borderColor = palette.separator.cgColor
        label.textColor = palette.label
        detailLabel.textColor = palette.secondary
        glyph.tintColor = palette.accent
        // Re-armed on every notice, so a second one that lands while the first is up
        // restarts the clock instead of inheriting its remaining time.
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
        guard let host = window ?? AorusAINoticeCapsule.keyWindow() else { return }
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

    func setText(_ title: String, detail: String) {
        label.text = title
        detailLabel.text = detail
        container.accessibilityLabel = detail.isEmpty ? title : title + ", " + detail
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
