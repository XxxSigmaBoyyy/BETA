import Foundation
import UIKit
import Display
import AccountContext
import TelegramPresentationData
import AppBundle
import PresentationDataUtils
import TelegramCore
import Postbox
import AorusGram

/// AorusAI actions live in one native page sheet after Telegram's message menu has fully
/// dismissed. ContextUI's stacked `pushItems` transition can leave both extracted menus
/// visible on narrow devices; keeping one controller and switching its segment in place
/// makes that overlap structurally impossible.
public func aorusAIPresentMessageActions(
    context: AccountContext,
    navigationController: NavigationController?,
    peerId: Int64,
    messageNamespace: Int32,
    messageId: Int32,
    authorPeerId: Int64?,
    text: String
) {
    guard let navigationController else { return }
    aorusAIResolveAuthorName(context: context, authorPeerId: authorPeerId) { authorName in
        let reference = AorusAIReferencedMessage(
            peerId: peerId,
            messageNamespace: messageNamespace,
            messageId: messageId,
            authorPeerId: authorPeerId,
            authorName: authorName,
            text: text
        )
        let controller = AorusAIMessageActionsController(
            context: context,
            navigationController: navigationController,
            reference: reference
        )
        controller.modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *) {
            controller.sheetPresentationController?.detents = [.medium(), .large()]
            controller.sheetPresentationController?.selectedDetentIdentifier = .medium
            controller.sheetPresentationController?.prefersGrabberVisible = true
            controller.sheetPresentationController?.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        controller.preferredContentSize = CGSize(width: 420.0, height: 560.0)
        let presenter = navigationController.topViewController
            ?? navigationController.view.window?.rootViewController
        presenter?.present(controller, animated: true)
    }
}

private final class AorusAIMessageActionsController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private weak var targetNavigationController: NavigationController?
    private let reference: AorusAIReferencedMessage
    private let presentationData: PresentationData
    private let palette: AorusAIPalette
    private let groups: [AorusAIMessageMenu.Group]
    private let languageCode: String

    private let headerView = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let segments: UISegmentedControl
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let newChatButton = UIButton(type: .system)
    private var selectedItems: [AorusAIMessageMenu.Item] = []

    init(context: AccountContext, navigationController: NavigationController, reference: AorusAIReferencedMessage) {
        self.context = context
        self.targetNavigationController = navigationController
        self.reference = reference
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.presentationData = presentationData
        self.palette = AorusAIPalette.resolve(presentationData.theme)
        self.languageCode = presentationData.strings.baseLanguageCode
        let groups = AorusAIMessageMenu.groups(languageCode: presentationData.strings.baseLanguageCode)
        self.groups = groups
        self.segments = UISegmentedControl(items: groups.map { $0.title ?? aorusAILocalized("Действия", "Actions") })
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A page sheet already has the system's own presentation; a blur inside it only
        // sampled the sheet's own opaque background. The page colour of the rest of
        // AorusAI is used instead, so the sheet belongs to the same screen family.
        view.backgroundColor = palette.background

        titleLabel.text = aorusAILocalized("ИИ-компаньон", "AI Companion")
        titleLabel.font = .systemFont(ofSize: 20.0, weight: .bold)
        titleLabel.textColor = palette.label
        titleLabel.textAlignment = .center
        headerView.addSubview(titleLabel)

        closeButton.setImage(
            UIImage(systemName: "xmark")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 14.0, weight: .semibold)),
            for: .normal
        )
        closeButton.tintColor = palette.secondary
        closeButton.backgroundColor = palette.fill
        closeButton.layer.cornerRadius = 16.0
        closeButton.layer.cornerCurve = .continuous
        closeButton.accessibilityLabel = aorusAILocalized("Закрыть", "Close")
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        headerView.addSubview(closeButton)
        view.addSubview(headerView)

        segments.selectedSegmentIndex = 0
        // The selection indicator is the system's, deliberately. Setting
        // `selectedSegmentTintColor` replaces that indicator with a flat rectangle of
        // whatever colour it is given, and the colour this was given is the palette's card
        // surface — which is a surface, not an indicator. It only ever read as one because
        // under Interface 2.0 the card colour is a near-invisible marker and the system's
        // own glass showed through it. Making that colour opaque, which the share sheet
        // needed, covered the glass with a slab that sits a shade off the page behind it,
        // and the selected tab stopped being findable.
        //
        // The system draws this control's selection against whatever is behind it and
        // keeps its label legible on top; nothing here knows better. So the indicator and
        // the selected label are left alone, and only the unselected label is themed —
        // Interface 2.0 repaints the page's ink, and the default grey belongs to the theme
        // it replaced.
        segments.setTitleTextAttributes([.foregroundColor: palette.secondary], for: .normal)
        segments.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 12.0, weight: .semibold)], for: .selected)
        segments.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        view.addSubview(segments)

        tableView.backgroundColor = .clear
        tableView.separatorColor = aorusAIGlassBorder(palette: palette)
        tableView.separatorInset = UIEdgeInsets(top: 0.0, left: 56.0, bottom: 0.0, right: 16.0)
        tableView.rowHeight = 54.0
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        newChatButton.setTitle(aorusAILocalized("Новый диалог с сообщением", "New chat with message"), for: .normal)
        newChatButton.setImage(UIImage(systemName: "bubble.left.and.bubble.right"), for: .normal)
        newChatButton.tintColor = palette.accent
        newChatButton.titleLabel?.font = .systemFont(ofSize: 15.0, weight: .semibold)
        newChatButton.semanticContentAttribute = .forceLeftToRight
        newChatButton.imageEdgeInsets = UIEdgeInsets(top: 0.0, left: -5.0, bottom: 0.0, right: 5.0)
        newChatButton.backgroundColor = palette.accentSoft
        newChatButton.layer.cornerRadius = 20.0
        newChatButton.layer.cornerCurve = .continuous
        newChatButton.addTarget(self, action: #selector(newChat), for: .touchUpInside)
        view.addSubview(newChatButton)

        updateSelectedItems()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let width = view.bounds.width
        headerView.frame = CGRect(x: 0.0, y: safe.top + 4.0, width: width, height: 48.0)
        titleLabel.frame = CGRect(x: 56.0, y: 7.0, width: max(0.0, width - 112.0), height: 28.0)
        closeButton.frame = CGRect(x: width - 48.0, y: 7.0, width: 32.0, height: 32.0)
        segments.frame = CGRect(x: 16.0, y: headerView.frame.maxY + 4.0, width: max(0.0, width - 32.0), height: 34.0)
        let buttonHeight: CGFloat = 40.0
        newChatButton.frame = CGRect(x: 16.0, y: view.bounds.height - safe.bottom - buttonHeight - 10.0, width: max(0.0, width - 32.0), height: buttonHeight)
        tableView.frame = CGRect(x: 0.0, y: segments.frame.maxY + 8.0, width: width, height: max(0.0, newChatButton.frame.minY - segments.frame.maxY - 14.0))
    }

    private func updateSelectedItems() {
        guard groups.indices.contains(segments.selectedSegmentIndex) else {
            selectedItems = []
            tableView.reloadData()
            return
        }
        selectedItems = displayItems(from: groups[segments.selectedSegmentIndex].items)
        tableView.reloadData()
        tableView.setContentOffset(.zero, animated: false)
    }

    /// Tone options belong directly to the Tone segment. Translation is a single direct
    /// action into the current interface language, so selecting it never opens another
    /// menu layer.
    private func displayItems(from items: [AorusAIMessageMenu.Item]) -> [AorusAIMessageMenu.Item] {
        var result: [AorusAIMessageMenu.Item] = []
        let language = String(languageCode.lowercased().prefix(2))
        for item in items {
            if item.id == AorusAIMessageMenu.toneId {
                result.append(contentsOf: item.children)
            } else if item.id == AorusAIMessageMenu.translateId {
                let leaves = item.children.flatMap { group in group.children.isEmpty ? [group] : group.children }
                if var target = leaves.first(where: { $0.id.hasSuffix(".\(language)") })
                    ?? leaves.first(where: { $0.id.hasSuffix(".en") }) {
                    target.title = aorusAILocalized("Перевести", "Translate")
                    target.hint = item.hint
                    result.append(target)
                }
            } else {
                result.append(item)
            }
        }
        return result
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return selectedItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "action")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "action")
        let item = selectedItems[indexPath.row]
        cell.textLabel?.text = item.title
        cell.textLabel?.textColor = palette.label
        cell.textLabel?.font = .systemFont(ofSize: 16.0, weight: .medium)
        cell.detailTextLabel?.text = item.hint
        cell.detailTextLabel?.textColor = palette.tertiary
        cell.detailTextLabel?.font = .systemFont(ofSize: 12.0)
        cell.imageView?.image = UIImage(bundleImageName: item.icon)?.withRenderingMode(.alwaysTemplate)
        cell.imageView?.tintColor = palette.secondary
        cell.backgroundColor = .clear
        cell.accessoryType = .none
        let selected = UIView()
        selected.backgroundColor = palette.fill
        cell.selectedBackgroundView = selected
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        run(selectedItems[indexPath.row].id)
    }

    private func run(_ id: String) {
        guard let targetNavigationController else { return }
        dismiss(animated: true) {
            AorusAIMessageMenu.run(id: id, context: self.context, navigationController: targetNavigationController, reference: self.reference)
        }
    }

    @objc private func segmentChanged() {
        UISelectionFeedbackGenerator().selectionChanged()
        updateSelectedItems()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func newChat() {
        run(AorusAIMessageMenu.newChatId)
    }
}

/// The same AorusAI menu, for a voice message.
///
/// A voice message has no text, so the menu that works on text had nothing to work on and
/// was never offered. The recording is transcribed on the device first — Apple's Speech
/// framework, the same path the voice-to-text button already uses — and the transcript is
/// handed to the ordinary menu as the message's text. Every action behaves exactly as it
/// does on a written message, because by the time the sheet opens it *is* one.
///
/// Nothing is sent anywhere to make this happen: the transcription is local, and only the
/// action the reader then chooses talks to AorusAI.
public func aorusAIPresentVoiceMessageActions(
    context: AccountContext,
    navigationController: NavigationController?,
    peerId: Int64,
    messageNamespace: Int32,
    messageId: Int32,
    authorPeerId: Int64?,
    file: TelegramMediaFile
) {
    guard let navigationController else { return }
    // Resolved here rather than by the caller: the caller is a Telegram chat file that
    // does not import Postbox, and adding an import to a patched upstream file to reach
    // one path is more surface than handing the file across.
    guard let filePath = context.account.postbox.mediaBox.completedResourcePath(file.resource) else {
        return
    }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }

    func present(_ message: String) {
        let alert = textAlertController(
            context: context,
            title: nil,
            text: message,
            actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
        )
        navigationController.topViewController.flatMap { $0 as? ViewController }?.present(alert, in: .window(.root))
    }

    // No progress overlay on purpose: `OverlayStatusController` is not a symbol this
    // module already links, and adding an unverified import to save a spinner is how a
    // build is lost. Recognition of a voice message is short and its result is cached,
    // and the press that opened the menu has already given its own haptic.
    UIImpactFeedbackGenerator(style: .light).impactOccurred()

    VoiceTranscriptionManager.shared.transcribe(fileURL: URL(fileURLWithPath: filePath)) { result in
        DispatchQueue.main.async {
            switch result {
            case let .success(text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    present(aorusAILocalized(
                        "Не удалось распознать речь в этом сообщении",
                        "Could not recognise any speech in this message"
                    ))
                    return
                }
                aorusAIPresentMessageActions(
                    context: context,
                    navigationController: navigationController,
                    peerId: peerId,
                    messageNamespace: messageNamespace,
                    messageId: messageId,
                    authorPeerId: authorPeerId,
                    text: trimmed
                )
            case .failure:
                present(aorusAILocalized(
                    "Не удалось расшифровать голосовое сообщение",
                    "Could not transcribe the voice message"
                ))
            }
        }
    }
}
