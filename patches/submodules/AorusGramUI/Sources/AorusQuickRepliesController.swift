import Foundation
import UIKit
import Security
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import ItemListPeerActionItem
import PresentationDataUtils
import AccountContext

// MARK: - Quick Replies

// A user-managed list of canned messages. In a chat, typing "&" pops an
// autocomplete panel of these replies; picking one inserts its text.
// Reachable from "Прочее" via the "Быстрые ответы" row.
//
// Storage: the device Keychain is the source of truth (kSecClassGenericPassword
// survives app deletion/reinstall, unlike UserDefaults), with a UserDefaults
// mirror under "aorusgram_quick_replies" — that mirror is what the patched
// core (ChatInterfaceStateContextQueries) reads for the "&" panel, since core
// code cannot import AorusGramUI. restoreFromKeychainIfNeeded() re-seeds the
// mirror on the first launch after a reinstall (called from AorusGramBootstrap).

public enum AorusQuickReplies {
    private static let key = "aorusgram_quick_replies"
    private static let service = "aorusgram.quickreplies"
    private static let account = "list"

    public static var items: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            keychainWrite(newValue)
        }
    }

    public static func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var arr = items
        arr.append(trimmed)
        items = arr
    }

    public static func remove(at index: Int) {
        var arr = items
        guard index >= 0 && index < arr.count else { return }
        arr.remove(at: index)
        items = arr
    }

    // First launch after a (re)install: UserDefaults is empty but the Keychain
    // may still hold the list from the previous install — re-seed the mirror.
    public static func restoreFromKeychainIfNeeded() {
        if UserDefaults.standard.object(forKey: key) != nil { return }
        if let saved = keychainRead(), !saved.isEmpty {
            UserDefaults.standard.set(saved, forKey: key)
        }
    }

    // MARK: Keychain helpers

    private static func keychainWrite(_ list: [String]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = data
        // AfterFirstUnlock: readable in background, migrates via encrypted
        // backups AND — the point — survives app deletion/reinstall.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func keychainRead() -> [String]? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}

private enum QRSection: Int32 {
    case info
    case list
}

// Each reply carries a stable, position-independent id so the list diff can
// animate a single insertion/deletion cleanly (index-based ids would shift on
// every middle-delete and make the whole list re-shuffle — the "raw" feeling).
private struct QRReply: Equatable {
    let id: Int32
    var text: String
}

private struct QRState: Equatable {
    var replies: [QRReply]
    var nextId: Int32
    var isAdding: Bool
    var draft: String
}

private final class QRArguments {
    let beginAdding: () -> Void
    let setDraft: (String) -> Void
    let commitDraft: () -> Void
    let removeReply: (Int) -> Void

    init(beginAdding: @escaping () -> Void, setDraft: @escaping (String) -> Void, commitDraft: @escaping () -> Void, removeReply: @escaping (Int) -> Void) {
        self.beginAdding = beginAdding
        self.setDraft = setDraft
        self.commitDraft = commitDraft
        self.removeReply = removeReply
    }
}

private enum QREntry: ItemListNodeEntry {
    case info(PresentationTheme, String)
    case addButton(PresentationTheme, String)
    case input(PresentationTheme, String, String)
    case reply(PresentationTheme, Int32, String)

    var section: ItemListSectionId {
        switch self {
        case .info:
            return QRSection.info.rawValue
        case .addButton, .input, .reply:
            return QRSection.list.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .info:                 return 0
        case .addButton:            return 10
        case .input:                return 11
        // Newest-first, position-stable: a committed reply lands right below the
        // input row (where you were typing) instead of jumping to the bottom, and
        // because each id is fixed for the reply's lifetime the diff animates a
        // single clean insert/remove with no reshuffle of the other rows.
        case let .reply(_, id, _): return 1_000_000 - id
        }
    }

    static func < (lhs: QREntry, rhs: QREntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: QREntry, rhs: QREntry) -> Bool {
        switch lhs {
        case let .info(lt, ls):
            if case let .info(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .addButton(lt, ls):
            if case let .addButton(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .input(lt, lp, lv):
            if case let .input(rt, rp, rv) = rhs { return lt === rt && lp == rp && lv == rv }
        case let .reply(lt, li, ls):
            if case let .reply(rt, ri, rs) = rhs { return lt === rt && li == ri && ls == rs }
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! QRArguments
        switch self {
        case let .info(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .addButton(_, text):
            let plusIcon = generateTintedImage(image: UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20.0, weight: .medium)), color: presentationData.theme.list.itemAccentColor)
            return ItemListPeerActionItem(presentationData: presentationData, icon: plusIcon, title: text, sectionId: section, action: { args.beginAdding() })
        case let .input(_, placeholder, value):
            return QRInputItem(theme: presentationData.theme, text: value, placeholder: placeholder, sectionId: section, textUpdated: { args.setDraft($0) }, action: { args.commitDraft() })
        case let .reply(_, id, text):
            return QRRevealTextItem(theme: presentationData.theme, title: text, deleteTitle: presentationData.strings.Common_Delete, sectionId: section, deleteAction: { args.removeReply(Int(id)) })
        }
    }
}

// MARK: - Inline input row (auto-focuses so the keyboard appears immediately)

private final class QRInputItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let text: String
    let placeholder: String
    let sectionId: ItemListSectionId
    let requestsNoInset: Bool = false
    let textUpdated: (String) -> Void
    let action: () -> Void

    init(theme: PresentationTheme, text: String, placeholder: String, sectionId: ItemListSectionId, textUpdated: @escaping (String) -> Void, action: @escaping () -> Void) {
        self.theme = theme
        self.text = text
        self.placeholder = placeholder
        self.sectionId = sectionId
        self.textUpdated = textUpdated
        self.action = action
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void,
                                 params: ListViewItemLayoutParams,
                                 synchronousLoads: Bool,
                                 previousItem: ListViewItem?,
                                 nextItem: ListViewItem?,
                                 completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = QRInputItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, { return (nil, { _ in apply() }) })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void,
                    node: @escaping () -> ListViewItemNode,
                    params: ListViewItemLayoutParams,
                    previousItem: ListViewItem?,
                    nextItem: ListViewItem?,
                    animation: ListViewItemUpdateAnimation,
                    completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? QRInputItemNode {
                let makeLayout = nodeValue.asyncLayout()
                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
                    Queue.mainQueue().async { completion(layout, { _ in apply() }) }
                }
            }
        }
    }
}

private final class QRInputItemNode: ListViewItemNode, UITextFieldDelegate {
    private let backgroundNode = ASDisplayNode()
    private let topStripeNode = ASDisplayNode()
    private let bottomStripeNode = ASDisplayNode()
    private let maskNode = ASImageNode()
    private weak var textField: UITextField?
    private var item: QRInputItem?
    private var layoutParams: ListViewItemLayoutParams?
    private var didFocus = false

    init() {
        backgroundNode.isLayerBacked = true
        topStripeNode.isLayerBacked = true
        bottomStripeNode.isLayerBacked = true
        super.init(layerBacked: false)
        addSubnode(backgroundNode)
        addSubnode(topStripeNode)
        addSubnode(bottomStripeNode)
        addSubnode(maskNode)
    }

    override func updateAnimationDuration() -> Double? {
        // The stock 0.4 s height spring races the keyboard resize and makes a new
        // row appear below its destination before jumping upwards.
        return 0.01
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.18)
    }

    override func animateAdded(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.18)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.14, removeOnCompletion: false)
    }

    override func didLoad() {
        super.didLoad()
        let textField = UITextField()
        textField.autocorrectionType = .default
        textField.autocapitalizationType = .sentences
        textField.returnKeyType = .done
        textField.clearButtonMode = .whileEditing
        textField.delegate = self
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        self.view.addSubview(textField)
        self.textField = textField
        if let item {
            applyItem(item)
        }
        layoutTextField()
        if !self.didFocus {
            self.didFocus = true
            // Let ItemList install the node at its final position first. Starting
            // the keyboard in didLoad races the insertion transaction and causes
            // the visible bottom-to-top jump reported on the management screen.
            Queue.mainQueue().after(0.05) { [weak self, weak textField] in
                guard let self, self.view.window != nil else { return }
                textField?.becomeFirstResponder()
            }
        }
    }

    private func applyItem(_ item: QRInputItem) {
        guard let textField else { return }
        if textField.text != item.text {
            textField.text = item.text
        }
        textField.textColor = item.theme.list.itemPrimaryTextColor
        textField.tintColor = item.theme.list.itemAccentColor
        textField.font = Font.regular(17.0)
        textField.attributedPlaceholder = NSAttributedString(string: item.placeholder, attributes: [.foregroundColor: item.theme.list.itemSecondaryTextColor])
    }

    private func layoutTextField() {
        guard let params = layoutParams else { return }
        let left = params.leftInset + 16.0
        textField?.frame = CGRect(x: left, y: 8.0, width: params.width - left - params.rightInset - 16.0, height: 32.0)
    }

    @objc private func textChanged() {
        item?.textUpdated(textField?.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        item?.textUpdated(textField.text ?? "")
        item?.action()
        textField.resignFirstResponder()
        return false
    }

    func asyncLayout() -> (QRInputItem, ListViewItemLayoutParams, ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { item, params, neighbors in
            let contentSize = CGSize(width: params.width, height: 48.0)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            return (layout, { [weak self] in
                guard let self else { return }
                self.item = item
                self.layoutParams = params
                self.contentSize = contentSize
                self.insets = insets
                self.backgroundNode.backgroundColor = item.theme.list.itemBlocksBackgroundColor
                self.topStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor
                self.bottomStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor

                let hasCorners = itemListHasRoundedBlockLayout(params)
                var topCorners = false
                var bottomCorners = false
                switch neighbors.top {
                case .sameSection(false):
                    self.topStripeNode.isHidden = true
                default:
                    topCorners = true
                    self.topStripeNode.isHidden = hasCorners
                }
                let bottomInset: CGFloat
                let bottomOffset: CGFloat
                switch neighbors.bottom {
                case .sameSection(false):
                    bottomInset = params.leftInset + 16.0
                    bottomOffset = -UIScreenPixel
                    self.bottomStripeNode.isHidden = false
                default:
                    bottomInset = 0.0
                    bottomOffset = 0.0
                    bottomCorners = true
                    self.bottomStripeNode.isHidden = hasCorners
                }

                self.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(item.theme, top: topCorners, bottom: bottomCorners) : nil
                let bgY = -min(insets.top, UIScreenPixel)
                let bgH = contentSize.height + min(insets.top, UIScreenPixel) + min(insets.bottom, UIScreenPixel)
                self.backgroundNode.frame = CGRect(x: 0.0, y: bgY, width: params.width, height: bgH)
                self.maskNode.frame = self.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0.0)
                self.topStripeNode.frame = CGRect(x: 0.0, y: bgY, width: params.width, height: UIScreenPixel)
                self.bottomStripeNode.frame = CGRect(x: bottomInset, y: contentSize.height + bottomOffset, width: params.width - bottomInset, height: UIScreenPixel)

                self.applyItem(item)
                self.layoutTextField()
            })
        }
    }
}

// MARK: - Swipe-to-delete reply row

private final class QRRevealTextItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let title: String
    let deleteTitle: String
    let sectionId: ItemListSectionId
    let requestsNoInset: Bool = false
    let deleteAction: () -> Void

    init(theme: PresentationTheme, title: String, deleteTitle: String, sectionId: ItemListSectionId, deleteAction: @escaping () -> Void) {
        self.theme = theme
        self.title = title
        self.deleteTitle = deleteTitle
        self.sectionId = sectionId
        self.deleteAction = deleteAction
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void,
                                 params: ListViewItemLayoutParams,
                                 synchronousLoads: Bool,
                                 previousItem: ListViewItem?,
                                 nextItem: ListViewItem?,
                                 completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = QRRevealTextItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, { return (nil, { _ in apply() }) })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void,
                    node: @escaping () -> ListViewItemNode,
                    params: ListViewItemLayoutParams,
                    previousItem: ListViewItem?,
                    nextItem: ListViewItem?,
                    animation: ListViewItemUpdateAnimation,
                    completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? QRRevealTextItemNode {
                let makeLayout = nodeValue.asyncLayout()
                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
                    Queue.mainQueue().async { completion(layout, { _ in apply() }) }
                }
            }
        }
    }
}

private final class QRRevealTextItemNode: ItemListRevealOptionsItemNode {
    private let backgroundNode = ASDisplayNode()
    private let topStripeNode = ASDisplayNode()
    private let bottomStripeNode = ASDisplayNode()
    private let maskNode = ASImageNode()
    private weak var titleLabel: UILabel?
    private var item: QRRevealTextItem?
    private var layoutParams: ListViewItemLayoutParams?

    init() {
        backgroundNode.isLayerBacked = true
        topStripeNode.isLayerBacked = true
        bottomStripeNode.isLayerBacked = true
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        addSubnode(backgroundNode)
        addSubnode(topStripeNode)
        addSubnode(bottomStripeNode)
        addSubnode(maskNode)
    }

    override func updateAnimationDuration() -> Double? {
        return 0.18
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.18)
    }

    override func animateAdded(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.18)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.16, removeOnCompletion: false)
    }

    override func didLoad() {
        super.didLoad()
        let title = UILabel()
        title.numberOfLines = 1
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.75
        view.addSubview(title)
        titleLabel = title
        if let item {
            applyItem(item)
        }
        layoutText()
    }

    private func applyItem(_ item: QRRevealTextItem) {
        titleLabel?.text = item.title
        titleLabel?.textColor = item.theme.list.itemPrimaryTextColor
        titleLabel?.font = Font.regular(17.0)
    }

    private func layoutText() {
        guard let params = layoutParams else { return }
        let offset = self.revealOffset
        let left = params.leftInset + 16.0
        titleLabel?.frame = CGRect(x: offset + left, y: 12.0, width: params.width - left - params.rightInset - 16.0, height: 24.0)
    }

    override func updateRevealOffset(offset: CGFloat, transition: ContainedViewLayoutTransition) {
        super.updateRevealOffset(offset: offset, transition: transition)
        layoutText()
    }

    override func revealOptionSelected(_ option: ItemListRevealOption, animated: Bool) {
        setRevealOptionsOpened(false, animated: true)
        revealOptionsInteractivelyClosed()
        item?.deleteAction()
    }

    func asyncLayout() -> (QRRevealTextItem, ListViewItemLayoutParams, ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { item, params, neighbors in
            let contentSize = CGSize(width: params.width, height: 48.0)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            return (layout, { [weak self] in
                guard let self else { return }
                self.item = item
                self.layoutParams = params
                self.backgroundNode.backgroundColor = item.theme.list.itemBlocksBackgroundColor
                self.topStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor
                self.bottomStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor

                let hasCorners = itemListHasRoundedBlockLayout(params)
                var topCorners = false
                var bottomCorners = false
                switch neighbors.top {
                case .sameSection(false):
                    self.topStripeNode.isHidden = true
                default:
                    topCorners = true
                    self.topStripeNode.isHidden = hasCorners
                }
                let bottomInset: CGFloat
                let bottomOffset: CGFloat
                switch neighbors.bottom {
                case .sameSection(false):
                    bottomInset = params.leftInset + 16.0
                    bottomOffset = -UIScreenPixel
                    self.bottomStripeNode.isHidden = false
                default:
                    bottomInset = 0.0
                    bottomOffset = 0.0
                    bottomCorners = true
                    self.bottomStripeNode.isHidden = hasCorners
                }

                self.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(item.theme, top: topCorners, bottom: bottomCorners) : nil
                let bgY = -min(insets.top, UIScreenPixel)
                let bgH = contentSize.height + min(insets.top, UIScreenPixel) + min(insets.bottom, UIScreenPixel)
                self.backgroundNode.frame = CGRect(x: 0.0, y: bgY, width: params.width, height: bgH)
                self.maskNode.frame = self.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0.0)
                self.topStripeNode.frame = CGRect(x: 0.0, y: bgY, width: params.width, height: UIScreenPixel)
                self.bottomStripeNode.frame = CGRect(x: bottomInset, y: contentSize.height + bottomOffset, width: params.width - bottomInset, height: UIScreenPixel)

                self.applyItem(item)
                self.layoutText()
                self.updateLayout(size: contentSize, leftInset: params.leftInset, rightInset: params.rightInset)
                self.updateRevealOptionsSeparatorNodes(top: self.topStripeNode, bottom: self.bottomStripeNode, topIsHidden: self.topStripeNode.isHidden, bottomIsHidden: self.bottomStripeNode.isHidden, topHiddenByPreviousRevealOptions: neighbors.topHasActiveRevealOptions, bottomHiddenByNextRevealOptions: neighbors.bottomHasActiveRevealOptions)
                let trashIcon = UIImage(systemName: "trash.fill")
                let revealIcon: ItemListRevealOptionIcon = trashIcon.map { .image(image: $0) } ?? .none
                self.setRevealOptions((left: [], right: [ItemListRevealOption(key: 0, title: item.deleteTitle, icon: revealIcon, color: item.theme.list.itemDisclosureActions.destructive.fillColor, iconColor: item.theme.list.itemDisclosureActions.destructive.foregroundColor, textColor: item.theme.list.itemDisclosureActions.destructive.foregroundColor)]))
            })
        }
    }
}

private func qrEntries(state: QRState, theme: PresentationTheme) -> [QREntry] {
    var entries: [QREntry] = []

    entries.append(.info(theme, aorusL("Вы можете добавить неограниченное количество ответов, используя кнопку ниже. Чтобы воспользоваться быстрым ответом, введите символ «&» в поле ввода сообщения.", "You can add any number of replies with the button below. To use a quick reply, type «&» in the message input field.")))

    entries.append(.addButton(theme, aorusL("Добавить новый", "Add new")))
    if state.isAdding {
        entries.append(.input(theme, aorusL("Текст ответа", "Reply text"), state.draft))
    }
    for reply in state.replies.reversed() {
        entries.append(.reply(theme, reply.id, reply.text))
    }

    return entries
}

public func aorusQuickRepliesController(context: AccountContext) -> ViewController {
    let loaded = AorusQuickReplies.items
    var seedId: Int32 = 0
    let seededReplies = loaded.map { text -> QRReply in
        let r = QRReply(id: seedId, text: text)
        seedId += 1
        return r
    }
    let initialState = QRState(replies: seededReplies, nextId: seedId, isAdding: false, draft: "")
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((QRState) -> QRState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let arguments = QRArguments(
        beginAdding: {
            updateState { current in
                var next = current
                next.isAdding = true
                next.draft = ""
                return next
            }
        },
        setDraft: { text in
            updateState { current in
                var next = current
                next.draft = text
                return next
            }
        },
        commitDraft: {
            let draft = stateValue.with { $0 }.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !draft.isEmpty else {
                updateState { current in
                    var next = current
                    next.isAdding = false
                    next.draft = ""
                    return next
                }
                return
            }
            updateState { current in
                var next = current
                next.replies.append(QRReply(id: next.nextId, text: draft))
                next.nextId += 1
                next.isAdding = false
                next.draft = ""
                return next
            }
            AorusQuickReplies.items = stateValue.with { $0 }.replies.map { $0.text }
        },
        removeReply: { id in
            let id32 = Int32(id)
            updateState { current in
                var next = current
                next.replies.removeAll { $0.id == id32 }
                return next
            }
            // Persist the new order/content (drives UserDefaults + Keychain).
            AorusQuickReplies.items = stateValue.with { $0 }.replies.map { $0.text }
        }
    )

    let signal = statePromise.get()
        |> deliverOnMainQueue
        |> map { state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            // The derived theme: these rows are our own ListViewItems and take a PresentationTheme
            // directly, so they do not reach the glass one through ItemListPresentationData.
            let entries = qrEntries(state: state, theme: presentationData.theme.aorusGlassListTheme)
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(aorusL("Быстрые ответы", "Quick Replies")),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            )
            let listState = ItemListNodeState(
                presentationData: ItemListPresentationData(presentationData),
                entries: entries,
                style: .blocks
            )
            return (controllerState, (listState, arguments))
        }

    let controller = ItemListController(context: context, state: signal)
    return controller
}
