import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

private enum MasksSection: Int32 {
    case toggle
    case presets
    case custom
}

private struct MasksState: Equatable {
    var enabled: Bool
    var preset: String
    var customMasks: [AorusCustomMaskRecord]
}

private func customMaskStableId(_ key: String) -> Int32 {
    var hash: UInt32 = 2_166_136_261
    for byte in key.utf8 {
        hash = (hash ^ UInt32(byte)) &* 16_777_619
    }
    return 1_000_000 + Int32(hash % 1_000_000_000)
}

private final class MasksArguments {
    let setEnabled: (Bool) -> Void
    let selectPreset: (String) -> Void
    let deletePreset: (String) -> Void
    let openEditor: () -> Void

    init(setEnabled: @escaping (Bool) -> Void, selectPreset: @escaping (String) -> Void, deletePreset: @escaping (String) -> Void, openEditor: @escaping () -> Void) {
        self.setEnabled = setEnabled
        self.selectPreset = selectPreset
        self.deletePreset = deletePreset
        self.openEditor = openEditor
    }
}

private enum MasksEntry: ItemListNodeEntry {
    case toggle(PresentationTheme, String, Bool)
    case footer(PresentationTheme, String)
    case header(PresentationTheme, String)
    case preset(PresentationTheme, Int, Int32, String, String, Bool, Bool)
    case editor(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .toggle, .footer:
            return MasksSection.toggle.rawValue
        case .header, .preset:
            return MasksSection.presets.rawValue
        case .editor:
            return MasksSection.custom.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .toggle:
            return 0
        case .footer:
            return 1
        case .header:
            return 2
        case let .preset(_, _, stableId, _, _, _, _):
            return stableId
        case .editor:
            return 100_000
        }
    }

    private var sortIndex: Int {
        switch self {
        case .toggle:
            return 0
        case .footer:
            return 1
        case .header:
            return 2
        case let .preset(_, order, _, _, _, _, _):
            return 10 + order
        case .editor:
            return 100_000
        }
    }

    static func < (lhs: MasksEntry, rhs: MasksEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    static func == (lhs: MasksEntry, rhs: MasksEntry) -> Bool {
        switch lhs {
        case let .toggle(lt, ls, lv):
            if case let .toggle(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .footer(lt, ls):
            if case let .footer(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .header(lt, ls):
            if case let .header(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .preset(lt, lo, lid, lk, ls, lselected, lremovable):
            if case let .preset(rt, ro, rid, rk, rs, rselected, rremovable) = rhs {
                return lt === rt && lo == ro && lid == rid && lk == rk && ls == rs && lselected == rselected && lremovable == rremovable
            }
        case let .editor(lt, ls):
            if case let .editor(rt, rs) = rhs { return lt === rt && ls == rs }
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! MasksArguments
        switch self {
        case let .toggle(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: arguments.setEnabled)
        case let .footer(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .preset(theme, _, _, key, title, selected, removable):
            if removable {
                return AorusMaskPresetItem(
                    theme: theme,
                    title: title,
                    selected: selected,
                    deleteTitle: presentationData.strings.Common_Delete,
                    sectionId: self.section,
                    deleteAction: { arguments.deletePreset(key) },
                    action: { arguments.selectPreset(key) }
                )
            } else {
                return ItemListCheckboxItem(presentationData: presentationData, title: title, style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                    arguments.selectPreset(key)
                })
            }
        case let .editor(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: self.section, style: .blocks, action: arguments.openEditor)
        }
    }
}

private final class AorusMaskPresetItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let title: String
    let selected: Bool
    let deleteTitle: String
    let sectionId: ItemListSectionId
    let requestsNoInset: Bool = false
    let deleteAction: () -> Void
    let action: () -> Void

    init(theme: PresentationTheme, title: String, selected: Bool, deleteTitle: String, sectionId: ItemListSectionId, deleteAction: @escaping () -> Void, action: @escaping () -> Void) {
        self.theme = theme
        self.title = title
        self.selected = selected
        self.deleteTitle = deleteTitle
        self.sectionId = sectionId
        self.deleteAction = deleteAction
        self.action = action
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void,
                                 params: ListViewItemLayoutParams,
                                 synchronousLoads: Bool,
                                 previousItem: ListViewItem?,
                                 nextItem: ListViewItem?,
                                 completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AorusMaskPresetItemNode()
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
            guard let nodeValue = node() as? AorusMaskPresetItemNode else { return }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
                Queue.mainQueue().async {
                    completion(layout, { _ in apply() })
                }
            }
        }
    }
}

private final class AorusMaskPresetItemNode: ItemListRevealOptionsItemNode {
    private let backgroundNode = ASDisplayNode()
    private let topStripeNode = ASDisplayNode()
    private let bottomStripeNode = ASDisplayNode()
    private let maskNode = ASImageNode()
    private weak var titleLabel: UILabel?
    private weak var checkLabel: UILabel?
    private var item: AorusMaskPresetItem?
    private var layoutParams: ListViewItemLayoutParams?

    init() {
        self.backgroundNode.isLayerBacked = true
        self.topStripeNode.isLayerBacked = true
        self.bottomStripeNode.isLayerBacked = true
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.topStripeNode)
        self.addSubnode(self.bottomStripeNode)
        self.addSubnode(self.maskNode)
    }

    override func didLoad() {
        super.didLoad()
        let titleLabel = UILabel()
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75
        self.view.addSubview(titleLabel)
        self.titleLabel = titleLabel

        let checkLabel = UILabel()
        checkLabel.textAlignment = .center
        checkLabel.font = Font.semibold(20.0)
        self.view.addSubview(checkLabel)
        self.checkLabel = checkLabel

        if let item = self.item {
            self.applyItem(item)
        }
        self.layoutContent()
    }

    private func applyItem(_ item: AorusMaskPresetItem) {
        self.titleLabel?.text = item.title
        self.titleLabel?.textColor = item.theme.list.itemPrimaryTextColor
        self.titleLabel?.font = Font.regular(17.0)
        self.checkLabel?.text = item.selected ? "✓" : ""
        self.checkLabel?.textColor = item.theme.list.itemAccentColor
    }

    private func layoutContent() {
        guard let params = self.layoutParams else { return }
        let offset = self.revealOffset
        let left = params.leftInset + 16.0
        let right = params.rightInset + 48.0
        self.titleLabel?.frame = CGRect(x: offset + left, y: 12.0, width: params.width - left - right, height: 24.0)
        self.checkLabel?.frame = CGRect(x: offset + params.width - params.rightInset - 38.0, y: 12.0, width: 24.0, height: 24.0)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if self.isDisplayingRevealedOptions {
            self.setRevealOptionsOpened(false, animated: true)
            self.revealOptionsInteractivelyClosed()
            return
        }
        guard let touch = touches.first, self.bounds.contains(touch.location(in: self.view)) else { return }
        self.item?.action()
    }

    override func updateRevealOffset(offset: CGFloat, transition: ContainedViewLayoutTransition) {
        super.updateRevealOffset(offset: offset, transition: transition)
        self.layoutContent()
    }

    override func revealOptionSelected(_ option: ItemListRevealOption, animated: Bool) {
        self.setRevealOptionsOpened(false, animated: true)
        self.revealOptionsInteractivelyClosed()
        self.item?.deleteAction()
    }

    func asyncLayout() -> (AorusMaskPresetItem, ListViewItemLayoutParams, ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
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
                let backgroundY = -min(insets.top, UIScreenPixel)
                let backgroundHeight = contentSize.height + min(insets.top, UIScreenPixel) + min(insets.bottom, UIScreenPixel)
                self.backgroundNode.frame = CGRect(x: 0.0, y: backgroundY, width: params.width, height: backgroundHeight)
                self.maskNode.frame = self.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0.0)
                self.topStripeNode.frame = CGRect(x: 0.0, y: backgroundY, width: params.width, height: UIScreenPixel)
                self.bottomStripeNode.frame = CGRect(x: bottomInset, y: contentSize.height + bottomOffset, width: params.width - bottomInset, height: UIScreenPixel)
                self.applyItem(item)
                self.layoutContent()
                self.updateLayout(size: contentSize, leftInset: params.leftInset, rightInset: params.rightInset)
                self.updateRevealOptionsSeparatorNodes(top: self.topStripeNode, bottom: self.bottomStripeNode, topIsHidden: self.topStripeNode.isHidden, bottomIsHidden: self.bottomStripeNode.isHidden, topHiddenByPreviousRevealOptions: neighbors.topHasActiveRevealOptions, bottomHiddenByNextRevealOptions: neighbors.bottomHasActiveRevealOptions)
                let trashImage = UIImage(systemName: "trash.fill")
                let revealIcon: ItemListRevealOptionIcon = trashImage.map { .image(image: $0) } ?? .none
                self.setRevealOptions((left: [], right: [ItemListRevealOption(key: 0, title: item.deleteTitle, icon: revealIcon, color: item.theme.list.itemDisclosureActions.destructive.fillColor, iconColor: item.theme.list.itemDisclosureActions.destructive.foregroundColor, textColor: item.theme.list.itemDisclosureActions.destructive.foregroundColor)]))
            })
        }
    }
}

private func masksEntries(state: MasksState, theme: PresentationTheme, l10n: AorusL10n) -> [MasksEntry] {
    var entries: [MasksEntry] = [
        .toggle(theme, l10n.videoMasks, state.enabled),
        .footer(theme, l10n.videoMasksFooter)
    ]
    if state.enabled {
        entries.append(.header(theme, l10n.videoMasksStyleHeader))
        let presets: [(String, String)] = [
            ("skull", l10n.videoMaskSkull),
            ("cyber", l10n.videoMaskCyber),
            ("phantom", l10n.videoMaskPhantom),
            ("neonCat", l10n.videoMaskNeonCat),
            ("chrome", l10n.videoMaskChrome),
            ("oni", l10n.videoMaskOni),
            ("aurora", l10n.videoMaskAurora)
        ]
        for (index, preset) in presets.enumerated() {
            entries.append(.preset(theme, index, 10 + Int32(index), preset.0, preset.1, state.preset == preset.0, false))
        }
        for (index, mask) in state.customMasks.enumerated() {
            entries.append(.preset(theme, presets.count + index, customMaskStableId(mask.presetKey), mask.presetKey, mask.name, state.preset == mask.presetKey, true))
        }
        entries.append(.editor(theme, l10n.videoMaskCreate))
    }
    return entries
}

public func aorusMasksController(context: AccountContext) -> ViewController {
    let manager = AorusGramManager.shared
    let isRussian = AorusLang.current == .ru
    let initialState = MasksState(
        enabled: manager.videoMasksEnabled,
        preset: manager.videoMaskPreset,
        customMasks: AorusCustomMaskStore.records(isRussian: isRussian)
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)

    let updateState: ((MasksState) -> MasksState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }
    var controller: ItemListController?
    let arguments = MasksArguments(
        setEnabled: { enabled in
            // Switching back on while "no mask" is selected would leave the feature enabled and
            // still rendering nothing, so restore a real mask at the same time.
            if enabled && manager.videoMaskPreset == "none" {
                manager.videoMaskPreset = "skull"
            }
            manager.videoMasksEnabled = enabled
            updateState { state in
                var state = state
                state.enabled = enabled
                return state
            }
        },
        selectPreset: { preset in
            manager.videoMaskPreset = preset
            updateState { state in
                var state = state
                state.preset = preset
                return state
            }
        },
        deletePreset: { preset in
            let currentState = stateValue.with { $0 }
            guard let record = currentState.customMasks.first(where: { $0.presetKey == preset }) else {
                return
            }
            guard AorusCustomMaskStore.delete(record) else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            if currentState.preset == preset {
                manager.videoMaskPreset = "skull"
            }
            updateState { state in
                var state = state
                state.customMasks.removeAll(where: { $0.presetKey == preset })
                if state.preset == preset {
                    state.preset = "skull"
                }
                return state
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        },
        openEditor: {
            let editor = AorusMaskEditorController(context: context, onSaved: { record in
                manager.videoMaskPreset = record.presetKey
                updateState { state in
                    var state = state
                    state.preset = record.presetKey
                    state.customMasks = AorusCustomMaskStore.records(isRussian: isRussian)
                    return state
                }
            })
            controller?.navigationController?.pushViewController(editor, animated: true)
        }
    )

    let signal = statePromise.get()
    |> deliverOnMainQueue
    |> map { state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let l10n = AorusL10n(presentationData.strings.baseLanguageCode)
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(l10n.videoMasks),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            // The derived theme: these rows are our own ListViewItems and take a PresentationTheme
            // directly, so they do not reach the glass one through ItemListPresentationData.
            entries: masksEntries(state: state, theme: presentationData.theme.aorusGlassListTheme, l10n: l10n),
            style: .blocks
        )
        return (controllerState, (listState, arguments))
    }
    let result = ItemListController(context: context, state: signal)
    controller = result
    return result
}
