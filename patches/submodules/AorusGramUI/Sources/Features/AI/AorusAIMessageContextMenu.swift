import Foundation
import UIKit
import Display
import AccountContext
import TelegramPresentationData
import AppBundle
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
        let presenter = (navigationController.topViewController as? UIViewController)
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

    private let materialView = UIVisualEffectView()
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
        view.backgroundColor = .clear
        materialView.effect = aorusAIGlassEffect(palette: palette)
        materialView.backgroundColor = aorusAIGlassTint(palette: palette)
        view.addSubview(materialView)

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
        closeButton.backgroundColor = aorusAIGlassTint(palette: palette, strong: true)
        closeButton.layer.cornerRadius = 16.0
        closeButton.layer.cornerCurve = .continuous
        closeButton.accessibilityLabel = aorusAILocalized("Закрыть", "Close")
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        headerView.addSubview(closeButton)
        view.addSubview(headerView)

        segments.selectedSegmentIndex = 0
        segments.selectedSegmentTintColor = aorusAIGlassTint(palette: palette, strong: true)
        segments.setTitleTextAttributes([.foregroundColor: palette.secondary], for: .normal)
        segments.setTitleTextAttributes([.foregroundColor: palette.label, .font: UIFont.systemFont(ofSize: 12.0, weight: .semibold)], for: .selected)
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
        newChatButton.backgroundColor = aorusAIGlassTint(palette: palette, strong: true)
        newChatButton.layer.cornerRadius = 20.0
        newChatButton.layer.cornerCurve = .continuous
        newChatButton.layer.borderWidth = UIScreenPixel
        newChatButton.layer.borderColor = aorusAIGlassBorder(palette: palette).cgColor
        newChatButton.addTarget(self, action: #selector(newChat), for: .touchUpInside)
        view.addSubview(newChatButton)

        updateSelectedItems()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        materialView.frame = view.bounds
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
        selected.backgroundColor = aorusAIGlassTint(palette: palette, strong: true)
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
