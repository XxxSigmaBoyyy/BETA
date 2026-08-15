import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// MARK: - Anti-spam management screen
//
// Reachable from "Прочее" via the "Управление" button under the Anti-spam toggle.
// Lets the user review who is blocked, curate the stop-word list, and add trusted
// peers (exceptions) that are never filtered. Everything is stored in AntiSpamManager.

private enum ASSection: Int32 {
    case protection
    case blocked
    case keywords
    case exceptions
}

private struct ASPeer: Equatable {
    var id: Int64
    var name: String
}

private final class ASObserverHolder {
    var token: NSObjectProtocol?
    deinit {
        if let token = self.token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

private struct ASState: Equatable {
    var threatProtection: Bool
    var spamProtection: Bool
    var stopWordsProtection: Bool
    var autoBlock: Bool
    var textCleanup: Bool
    var autoReport: Bool
    var blocked: [ASPeer]
    var allowed: [ASPeer]
    var keywords: [String]
    var newKeyword: String
}

private final class ASArguments {
    let setThreatProtection: (Bool) -> Void
    let setSpamProtection: (Bool) -> Void
    let setStopWordsProtection: (Bool) -> Void
    let setAutoBlock: (Bool) -> Void
    let setTextCleanup: (Bool) -> Void
    let setAutoReport: (Bool) -> Void
    let unblock: (Int64) -> Void
    let removeException: (Int64) -> Void
    let addException: () -> Void
    let setNewKeyword: (String) -> Void
    let commitNewKeyword: () -> Void
    let removeKeyword: (String) -> Void

    init(setThreatProtection: @escaping (Bool) -> Void, setSpamProtection: @escaping (Bool) -> Void, setStopWordsProtection: @escaping (Bool) -> Void, setAutoBlock: @escaping (Bool) -> Void, setTextCleanup: @escaping (Bool) -> Void, setAutoReport: @escaping (Bool) -> Void, unblock: @escaping (Int64) -> Void, removeException: @escaping (Int64) -> Void, addException: @escaping () -> Void, setNewKeyword: @escaping (String) -> Void, commitNewKeyword: @escaping () -> Void, removeKeyword: @escaping (String) -> Void) {
        self.setThreatProtection = setThreatProtection
        self.setSpamProtection = setSpamProtection
        self.setStopWordsProtection = setStopWordsProtection
        self.setAutoBlock = setAutoBlock
        self.setTextCleanup = setTextCleanup
        self.setAutoReport = setAutoReport
        self.unblock = unblock
        self.removeException = removeException
        self.addException = addException
        self.setNewKeyword = setNewKeyword
        self.commitNewKeyword = commitNewKeyword
        self.removeKeyword = removeKeyword
    }
}

private enum ASEntry: ItemListNodeEntry {
    case protectionHeader(PresentationTheme, String)
    case threatProtection(PresentationTheme, String, Bool)
    case spamProtection(PresentationTheme, String, Bool)
    case stopWordsProtection(PresentationTheme, String, Bool)
    case autoBlock(PresentationTheme, String, Bool)
    case textCleanup(PresentationTheme, String, Bool)
    case autoReport(PresentationTheme, String, Bool)
    case protectionInfo(PresentationTheme, String)
    case blockedHeader(PresentationTheme, String)
    case blockedEmpty(PresentationTheme, String)
    case blockedPeer(PresentationTheme, Int32, Int64, String)
    case keywordsHeader(PresentationTheme, String)
    case keyword(PresentationTheme, Int32, String)
    case keywordInput(PresentationTheme, String, String)
    case keywordsInfo(PresentationTheme, String)
    case exceptionsHeader(PresentationTheme, String)
    case exceptionPeer(PresentationTheme, Int32, Int64, String)
    case addException(PresentationTheme, String)
    case exceptionsInfo(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .protectionHeader, .threatProtection, .spamProtection, .stopWordsProtection, .autoBlock, .textCleanup, .autoReport, .protectionInfo:
            return ASSection.protection.rawValue
        case .blockedHeader, .blockedEmpty, .blockedPeer:
            return ASSection.blocked.rawValue
        case .keywordsHeader, .keyword, .keywordInput, .keywordsInfo:
            return ASSection.keywords.rawValue
        case .exceptionsHeader, .exceptionPeer, .addException, .exceptionsInfo:
            return ASSection.exceptions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .protectionHeader: return -100
        case .threatProtection: return -99
        case .autoReport: return -98
        case .spamProtection: return -97
        case .stopWordsProtection: return -96
        case .autoBlock: return -95
        case .textCleanup: return -94
        case .protectionInfo: return -93
        case .blockedHeader: return 0
        case .blockedEmpty: return 1
        case let .blockedPeer(_, index, _, _): return 100 + index
        case .keywordsHeader: return 1000
        case let .keyword(_, index, _): return 1100 + index
        case .keywordInput: return 5000
        case .keywordsInfo: return 5001
        case .exceptionsHeader: return 6000
        case let .exceptionPeer(_, index, _, _): return 6100 + index
        case .addException: return 9000
        case .exceptionsInfo: return 9001
        }
    }

    static func < (lhs: ASEntry, rhs: ASEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: ASEntry, rhs: ASEntry) -> Bool {
        switch lhs {
        case let .protectionHeader(lt, ls):
            if case let .protectionHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .threatProtection(lt, ls, lv):
            if case let .threatProtection(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .spamProtection(lt, ls, lv):
            if case let .spamProtection(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .stopWordsProtection(lt, ls, lv):
            if case let .stopWordsProtection(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .autoBlock(lt, ls, lv):
            if case let .autoBlock(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .textCleanup(lt, ls, lv):
            if case let .textCleanup(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .autoReport(lt, ls, lv):
            if case let .autoReport(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .protectionInfo(lt, ls):
            if case let .protectionInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .blockedHeader(lt, ls):
            if case let .blockedHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .blockedEmpty(lt, ls):
            if case let .blockedEmpty(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .blockedPeer(lt, li, lid, ln):
            if case let .blockedPeer(rt, ri, rid, rn) = rhs { return lt === rt && li == ri && lid == rid && ln == rn }
        case let .keywordsHeader(lt, ls):
            if case let .keywordsHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .keyword(lt, li, ls):
            if case let .keyword(rt, ri, rs) = rhs { return lt === rt && li == ri && ls == rs }
        case let .keywordInput(lt, lp, lv):
            if case let .keywordInput(rt, rp, rv) = rhs { return lt === rt && lp == rp && lv == rv }
        case let .keywordsInfo(lt, ls):
            if case let .keywordsInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .exceptionsHeader(lt, ls):
            if case let .exceptionsHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .exceptionPeer(lt, li, lid, ln):
            if case let .exceptionPeer(rt, ri, rid, rn) = rhs { return lt === rt && li == ri && lid == rid && ln == rn }
        case let .addException(lt, ls):
            if case let .addException(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .exceptionsInfo(lt, ls):
            if case let .exceptionsInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! ASArguments
        switch self {
        case let .protectionHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .threatProtection(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setThreatProtection($0) })
        case let .spamProtection(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setSpamProtection($0) })
        case let .stopWordsProtection(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setStopWordsProtection($0) })
        case let .autoBlock(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setAutoBlock($0) })
        case let .textCleanup(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setTextCleanup($0) })
        case let .autoReport(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setAutoReport($0) })
        case let .protectionInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .blockedHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .blockedEmpty(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .blockedPeer(_, _, peerId, name):
            return ASRevealTextItem(theme: presentationData.theme, title: name, deleteTitle: presentationData.strings.Common_Delete, sectionId: section, deleteAction: { args.unblock(peerId) })
        case let .keywordsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .keyword(_, _, word):
            return ASRevealTextItem(theme: presentationData.theme, title: word, deleteTitle: presentationData.strings.Common_Delete, sectionId: section, deleteAction: { args.removeKeyword(word) })
        case let .keywordInput(_, placeholder, value):
            return ASKeywordInputItem(theme: presentationData.theme, text: value, placeholder: placeholder, sectionId: section, textUpdated: { args.setNewKeyword($0) }, action: { args.commitNewKeyword() })
        case let .keywordsInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .exceptionsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .exceptionPeer(_, _, peerId, name):
            return ASRevealTextItem(theme: presentationData.theme, title: name, deleteTitle: presentationData.strings.Common_Delete, sectionId: section, deleteAction: { args.removeException(peerId) })
        case let .addException(_, text):
            return ItemListActionItem(presentationData: presentationData, title: text, kind: .neutral, alignment: .natural, sectionId: section, style: .blocks, action: { args.addException() })
        case let .exceptionsInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        }
    }
}

private final class ASKeywordInputItem: ListViewItem, ItemListItem {
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
            let node = ASKeywordInputItemNode()
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
            if let nodeValue = node() as? ASKeywordInputItemNode {
                let makeLayout = nodeValue.asyncLayout()
                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
                    Queue.mainQueue().async { completion(layout, { _ in apply() }) }
                }
            }
        }
    }
}

private final class ASKeywordInputItemNode: ListViewItemNode, UITextFieldDelegate {
    private let backgroundNode = ASDisplayNode()
    private let topStripeNode = ASDisplayNode()
    private let bottomStripeNode = ASDisplayNode()
    private let maskNode = ASImageNode()
    private weak var textField: UITextField?
    private var item: ASKeywordInputItem?
    private var layoutParams: ListViewItemLayoutParams?

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

    override func didLoad() {
        super.didLoad()
        let textField = UITextField()
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
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
    }

    private func applyItem(_ item: ASKeywordInputItem) {
        guard let textField else { return }
        if textField.text != item.text {
            textField.text = item.text
        }
        textField.textColor = item.theme.list.itemPrimaryTextColor
        textField.tintColor = item.theme.list.itemAccentColor
        textField.font = Font.regular(17.0)
        textField.attributedPlaceholder = NSAttributedString(string: item.placeholder, attributes: [.foregroundColor: UIColor.white])
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

    func asyncLayout() -> (ASKeywordInputItem, ListViewItemLayoutParams, ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
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

private final class ASRevealTextItem: ListViewItem, ItemListItem {
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
            let node = ASRevealTextItemNode()
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
            if let nodeValue = node() as? ASRevealTextItemNode {
                let makeLayout = nodeValue.asyncLayout()
                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
                    Queue.mainQueue().async { completion(layout, { _ in apply() }) }
                }
            }
        }
    }
}

private final class ASRevealTextItemNode: ItemListRevealOptionsItemNode {
    private let backgroundNode = ASDisplayNode()
    private let topStripeNode = ASDisplayNode()
    private let bottomStripeNode = ASDisplayNode()
    private let maskNode = ASImageNode()
    private weak var titleLabel: UILabel?
    private var item: ASRevealTextItem?
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

    private func applyItem(_ item: ASRevealTextItem) {
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

    func asyncLayout() -> (ASRevealTextItem, ListViewItemLayoutParams, ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
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

private func asEntries(state: ASState, theme: PresentationTheme) -> [ASEntry] {
    var entries: [ASEntry] = []

    entries.append(.protectionHeader(theme, aorusL("ЗАЩИТА", "PROTECTION")))
    entries.append(.threatProtection(theme, aorusL("Защита от угроз", "Threat protection"), state.threatProtection))
    // Auto-report sits right under threat protection and only when it is enabled.
    if state.threatProtection {
        entries.append(.autoReport(theme, aorusL("Авто-жалоба на угрозы", "Auto-report threats"), state.autoReport))
    }
    entries.append(.spamProtection(theme, aorusL("Защита от спама", "Spam protection"), state.spamProtection))
    entries.append(.stopWordsProtection(theme, aorusL("Стоп-слова", "Stop words"), state.stopWordsProtection))
    entries.append(.autoBlock(theme, aorusL("Автоблокировка", "Auto-block"), state.autoBlock))
    entries.append(.textCleanup(theme, aorusL("Исправление текста", "Text clean-up"), state.textCleanup))
    entries.append(.protectionInfo(theme, aorusL("Угрозы (деанон, докс, OSINT, сват) распознаются даже при обфускации (D0X, DОX). Исправление текста убирает КАПС и ставит заглавную букву в начале.", "Threats (doxxing, OSINT, swatting) are caught even when obfuscated (D0X, DОX). Text clean-up folds ALL CAPS and capitalizes the first letter.")))

    entries.append(.blockedHeader(theme, aorusL("ЗАБЛОКИРОВАННЫЕ", "BLOCKED")))
    if state.blocked.isEmpty {
        entries.append(.blockedEmpty(theme, aorusL("Пока никто не заблокирован.", "No one is blocked yet.")))
    } else {
        for (i, peer) in state.blocked.enumerated() {
            entries.append(.blockedPeer(theme, Int32(i), peer.id, peer.name))
        }
    }

    entries.append(.keywordsHeader(theme, aorusL("СТОП-СЛОВА", "STOP WORDS")))
    for (i, word) in state.keywords.enumerated() {
        entries.append(.keyword(theme, Int32(i), word))
    }
    entries.append(.keywordInput(theme, aorusL("Добавить слово", "Add a word"), state.newKeyword))
    entries.append(.keywordsInfo(theme, aorusL("Сообщения с этими словами скрываются автоматически. Для удаления свайпните строку влево.", "Messages containing these words are hidden automatically. Swipe left to delete.")))

    entries.append(.exceptionsHeader(theme, aorusL("ИСКЛЮЧЕНИЯ", "EXCEPTIONS")))
    for (i, peer) in state.allowed.enumerated() {
        entries.append(.exceptionPeer(theme, Int32(i), peer.id, peer.name))
    }
    entries.append(.addException(theme, aorusL("Добавить исключение", "Add exception")))
    entries.append(.exceptionsInfo(theme, aorusL("Эти контакты никогда не фильтруются антиспамом. Для удаления свайпните строку влево.", "These contacts are never filtered by anti-spam. Swipe left to remove.")))

    return entries
}

public func aorusAntiSpamController(context: AccountContext) -> ViewController {
    let initialState = ASState(threatProtection: AntiSpamManager.shared.threatProtection, spamProtection: AntiSpamManager.shared.spamProtection, stopWordsProtection: AntiSpamManager.shared.stopWordsProtection, autoBlock: AntiSpamManager.shared.autoBlock, textCleanup: AntiSpamManager.shared.textCleanup, autoReport: AntiSpamManager.shared.autoReport, blocked: [], allowed: [], keywords: AntiSpamManager.shared.keywords, newKeyword: "")
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((ASState) -> ASState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    weak var weakController: ItemListController?
    let actionsDisposable = DisposableSet()
    let nameDisposable = MetaDisposable()
    actionsDisposable.add(nameDisposable)

    // Resolve peer ids (blocked + allowed) to display names, then refresh state.
    let reloadPeers: () -> Void = {
        let blockedIds = Array(AntiSpamManager.shared.blockedPeerIds)
        let allowedIds = Array(AntiSpamManager.shared.allowedPeerIds)
        let allIds = (blockedIds + allowedIds)
        let signals = allIds.map { id in
            context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: EnginePeer.Id(id)))
        }
        nameDisposable.set((combineLatest(signals)
        |> deliverOnMainQueue).start(next: { peers in
            var names: [Int64: String] = [:]
            for (index, peer) in peers.enumerated() {
                let id = allIds[index]
                names[id] = peer?.compactDisplayTitle ?? "\(id)"
            }
            updateState { current in
                var next = current
                next.threatProtection = AntiSpamManager.shared.threatProtection
                next.spamProtection = AntiSpamManager.shared.spamProtection
                next.stopWordsProtection = AntiSpamManager.shared.stopWordsProtection
                next.autoBlock = AntiSpamManager.shared.autoBlock
                next.textCleanup = AntiSpamManager.shared.textCleanup
                next.autoReport = AntiSpamManager.shared.autoReport
                next.blocked = blockedIds.map { ASPeer(id: $0, name: names[$0] ?? "\($0)") }
                next.allowed = allowedIds.map { ASPeer(id: $0, name: names[$0] ?? "\($0)") }
                next.keywords = AntiSpamManager.shared.keywords
                return next
            }
        }))
        if allIds.isEmpty {
            updateState { current in
                var next = current
                next.threatProtection = AntiSpamManager.shared.threatProtection
                next.spamProtection = AntiSpamManager.shared.spamProtection
                next.stopWordsProtection = AntiSpamManager.shared.stopWordsProtection
                next.autoBlock = AntiSpamManager.shared.autoBlock
                next.textCleanup = AntiSpamManager.shared.textCleanup
                next.autoReport = AntiSpamManager.shared.autoReport
                next.blocked = []
                next.allowed = []
                next.keywords = AntiSpamManager.shared.keywords
                return next
            }
        }
    }

    let observerHolder = ASObserverHolder()
    observerHolder.token = NotificationCenter.default.addObserver(forName: AntiSpamManager.stateChangedNotification, object: nil, queue: .main) { _ in
        reloadPeers()
    }

    let arguments = ASArguments(
        setThreatProtection: { value in
            AntiSpamManager.shared.setThreatProtection(value)
            updateState { current in var next = current; next.threatProtection = value; return next }
        },
        setSpamProtection: { value in
            AntiSpamManager.shared.setSpamProtection(value)
            updateState { current in var next = current; next.spamProtection = value; return next }
        },
        setStopWordsProtection: { value in
            AntiSpamManager.shared.setStopWordsProtection(value)
            updateState { current in var next = current; next.stopWordsProtection = value; return next }
        },
        setAutoBlock: { value in
            AntiSpamManager.shared.setAutoBlock(value)
            updateState { current in var next = current; next.autoBlock = value; return next }
        },
        setTextCleanup: { value in
            AntiSpamManager.shared.setTextCleanup(value)
            updateState { current in var next = current; next.textCleanup = value; return next }
        },
        setAutoReport: { value in
            AntiSpamManager.shared.setAutoReport(value)
            updateState { current in var next = current; next.autoReport = value; return next }
        },
        unblock: { peerId in
            AntiSpamManager.shared.unblockPeer(peerId)
            reloadPeers()
        },
        removeException: { peerId in
            AntiSpamManager.shared.removeAllowedPeer(peerId)
            reloadPeers()
        },
        addException: {
            // Contacts picker; its search also covers global (non-contact) peers, so any
            // stranger can still be whitelisted by name.
            let selectionController = context.sharedContext.makeContactSelectionController(ContactSelectionControllerParams(
                context: context,
                autoDismiss: false,
                title: { strings in return strings.Contacts_Title }
            ))
            actionsDisposable.add((selectionController.result
            |> deliverOnMainQueue).start(next: { [weak selectionController] result in
                selectionController?.dismiss()
                if let (peers, _, _, _, _, _) = result, let first = peers.first, case let .peer(peer, _, _) = first {
                    AntiSpamManager.shared.allowPeer(peer.id.toInt64())
                    reloadPeers()
                }
            }))
            weakController?.push(selectionController)
        },
        setNewKeyword: { text in
            updateState { current in
                var next = current
                next.newKeyword = text
                return next
            }
        },
        commitNewKeyword: {
            let word = stateValue.with { $0 }.newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return }
            AntiSpamManager.shared.addKeyword(word)
            updateState { current in
                var next = current
                next.newKeyword = ""
                next.keywords = AntiSpamManager.shared.keywords
                return next
            }
        },
        removeKeyword: { word in
            AntiSpamManager.shared.removeKeyword(word)
            updateState { current in
                var next = current
                next.keywords = AntiSpamManager.shared.keywords
                return next
            }
        }
    )

    reloadPeers()

    let signal = statePromise.get()
        |> deliverOnMainQueue
        |> map { state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let _ = observerHolder
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            // The derived theme: these rows are our own ListViewItems and take a PresentationTheme
            // directly, so they do not reach the glass one through ItemListPresentationData.
            let entries = asEntries(state: state, theme: presentationData.theme.aorusGlassListTheme)
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(aorusL("Управление антиспамом", "Anti-spam")),
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
        |> afterDisposed {
            actionsDisposable.dispose()
        }

    let controller = ItemListController(context: context, state: signal)
    weakController = controller
    return controller
}
