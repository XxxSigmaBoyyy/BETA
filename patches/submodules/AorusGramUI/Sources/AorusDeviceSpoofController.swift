import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

private struct AorusSpoofDevice: Codable, Equatable {
    let id: String
    let model: String
    let systemVersion: String
    let custom: Bool
}

private enum AorusDeviceSpoofStore {
    static let customDevicesKey = "aorusgram_spoof_custom_devices_v1"
    static let lastSelectionKey = "aorusgram_spoof_last_selection_v1"

    private static let currentIOSVersion = UIDevice.current.systemVersion

    static let presets: [AorusSpoofDevice] = [
        AorusSpoofDevice(id: "iphone16promax", model: "iPhone 16 Pro Max", systemVersion: currentIOSVersion, custom: false),
        AorusSpoofDevice(id: "iphone16pro", model: "iPhone 16 Pro", systemVersion: currentIOSVersion, custom: false),
        AorusSpoofDevice(id: "iphone16", model: "iPhone 16", systemVersion: currentIOSVersion, custom: false),
        AorusSpoofDevice(id: "iphone15pro", model: "iPhone 15 Pro", systemVersion: currentIOSVersion, custom: false),
        AorusSpoofDevice(id: "iphone14pro", model: "iPhone 14 Pro", systemVersion: currentIOSVersion, custom: false),
        AorusSpoofDevice(id: "ipadpro13", model: "iPad Pro 13-inch (M4)", systemVersion: currentIOSVersion, custom: false),
        AorusSpoofDevice(id: "pixel9pro", model: "Google Pixel 9 Pro", systemVersion: "Android 15", custom: false),
        AorusSpoofDevice(id: "galaxys25ultra", model: "Samsung Galaxy S25 Ultra", systemVersion: "Android 15", custom: false),
        AorusSpoofDevice(id: "xiaomi15ultra", model: "Xiaomi 15 Ultra", systemVersion: "Android 15", custom: false),
        AorusSpoofDevice(id: "windows11", model: "Desktop Windows", systemVersion: "Windows 11", custom: false),
        AorusSpoofDevice(id: "macbookpro", model: "MacBook Pro", systemVersion: "macOS 15.5", custom: false),
        AorusSpoofDevice(id: "ubuntu", model: "Desktop Linux", systemVersion: "Ubuntu 24.04", custom: false)
    ]

    static func customDevices() -> [AorusSpoofDevice] {
        guard let data = UserDefaults.standard.data(forKey: customDevicesKey),
              let devices = try? JSONDecoder().decode([AorusSpoofDevice].self, from: data) else {
            return []
        }
        return devices
    }

    static func saveCustomDevices(_ devices: [AorusSpoofDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: customDevicesKey)
        }
    }

    static func savedSelectionId() -> String {
        return UserDefaults.standard.string(forKey: lastSelectionKey) ?? presets[1].id
    }

    static func saveSelectionId(_ id: String) {
        UserDefaults.standard.set(id, forKey: lastSelectionKey)
    }
}

private func aorusDeviceStableId(_ id: String) -> Int32 {
    var hash: UInt32 = 2_166_136_261
    for byte in id.utf8 {
        hash = (hash ^ UInt32(byte)) &* 16_777_619
    }
    return 100 + Int32(hash % 1_000_000_000)
}

private enum AorusDeviceSpoofSection: Int32 {
    case toggle
    case devices
    case custom
}

private struct AorusDeviceSpoofState: Equatable {
    var enabled: Bool
    var selectedId: String
    var customDevices: [AorusSpoofDevice]
}

private final class AorusDeviceSpoofArguments {
    let setEnabled: (Bool) -> Void
    let select: (AorusSpoofDevice) -> Void
    let deleteCustom: (AorusSpoofDevice) -> Void
    let addCustom: () -> Void

    init(
        setEnabled: @escaping (Bool) -> Void,
        select: @escaping (AorusSpoofDevice) -> Void,
        deleteCustom: @escaping (AorusSpoofDevice) -> Void,
        addCustom: @escaping () -> Void
    ) {
        self.setEnabled = setEnabled
        self.select = select
        self.deleteCustom = deleteCustom
        self.addCustom = addCustom
    }
}

private enum AorusDeviceSpoofEntry: ItemListNodeEntry {
    case toggle(PresentationTheme, String, Bool)
    case header(PresentationTheme, String)
    case device(PresentationTheme, Int, AorusSpoofDevice, Bool)
    case addCustom(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .toggle:
            return AorusDeviceSpoofSection.toggle.rawValue
        case .header, .device:
            return AorusDeviceSpoofSection.devices.rawValue
        case .addCustom:
            return AorusDeviceSpoofSection.custom.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .toggle:
            return 0
        case .header:
            return 1
        case let .device(_, _, device, _):
            return aorusDeviceStableId(device.id)
        case .addCustom:
            return Int32.max - 1
        }
    }

    private var sortIndex: Int {
        switch self {
        case .toggle:
            return 0
        case .header:
            return 10
        case let .device(_, order, _, _):
            return 100 + order
        case .addCustom:
            return 100_000
        }
    }

    static func < (lhs: AorusDeviceSpoofEntry, rhs: AorusDeviceSpoofEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    static func == (lhs: AorusDeviceSpoofEntry, rhs: AorusDeviceSpoofEntry) -> Bool {
        switch lhs {
        case let .toggle(lhsTheme, lhsTitle, lhsValue):
            if case let .toggle(rhsTheme, rhsTitle, rhsValue) = rhs {
                return lhsTheme === rhsTheme && lhsTitle == rhsTitle && lhsValue == rhsValue
            }
        case let .header(lhsTheme, lhsTitle):
            if case let .header(rhsTheme, rhsTitle) = rhs {
                return lhsTheme === rhsTheme && lhsTitle == rhsTitle
            }
        case let .device(lhsTheme, lhsOrder, lhsDevice, lhsSelected):
            if case let .device(rhsTheme, rhsOrder, rhsDevice, rhsSelected) = rhs {
                return lhsTheme === rhsTheme && lhsOrder == rhsOrder && lhsDevice == rhsDevice && lhsSelected == rhsSelected
            }
        case let .addCustom(lhsTheme, lhsTitle):
            if case let .addCustom(rhsTheme, rhsTitle) = rhs {
                return lhsTheme === rhsTheme && lhsTitle == rhsTitle
            }
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AorusDeviceSpoofArguments
        switch self {
        case let .toggle(_, title, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: title,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: arguments.setEnabled
            )
        case let .header(_, title):
            return ItemListSectionHeaderItem(
                presentationData: presentationData,
                text: title,
                sectionId: self.section
            )
        case let .device(_, _, device, selected):
            if device.custom {
                return AorusSpoofDeviceItem(
                    theme: presentationData.theme,
                    title: device.model,
                    selected: selected,
                    deleteTitle: presentationData.strings.Common_Delete,
                    sectionId: self.section,
                    deleteAction: {
                        arguments.deleteCustom(device)
                    },
                    action: {
                        arguments.select(device)
                    }
                )
            } else {
                return ItemListCheckboxItem(
                    presentationData: presentationData,
                    title: device.model,
                    style: .right,
                    checked: selected,
                    zeroSeparatorInsets: false,
                    sectionId: self.section,
                    action: {
                        arguments.select(device)
                    }
                )
            }
        case let .addCustom(_, title):
            return ItemListActionItem(
                presentationData: presentationData,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: arguments.addCustom
            )
        }
    }
}

private func aorusDeviceSpoofEntries(
    state: AorusDeviceSpoofState,
    theme: PresentationTheme
) -> [AorusDeviceSpoofEntry] {
    var entries: [AorusDeviceSpoofEntry] = [
        .toggle(theme, aorusL("Подмена устройства", "Device Spoof"), state.enabled)
    ]
    if state.enabled {
        entries.append(.header(theme, aorusL("УСТРОЙСТВО", "DEVICE")))
        let devices = AorusDeviceSpoofStore.presets + state.customDevices
        for (index, device) in devices.enumerated() {
            entries.append(.device(theme, index, device, state.selectedId == device.id))
        }
        entries.append(.addCustom(theme, aorusL("Добавить своё устройство", "Add Custom Device")))
    }
    return entries
}

private final class AorusSpoofDeviceItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let title: String
    let selected: Bool
    let deleteTitle: String
    let sectionId: ItemListSectionId
    let requestsNoInset: Bool = false
    let deleteAction: () -> Void
    let action: () -> Void

    init(
        theme: PresentationTheme,
        title: String,
        selected: Bool,
        deleteTitle: String,
        sectionId: ItemListSectionId,
        deleteAction: @escaping () -> Void,
        action: @escaping () -> Void
    ) {
        self.theme = theme
        self.title = title
        self.selected = selected
        self.deleteTitle = deleteTitle
        self.sectionId = sectionId
        self.deleteAction = deleteAction
        self.action = action
    }

    func nodeConfiguredForParams(
        async: @escaping (@escaping () -> Void) -> Void,
        params: ListViewItemLayoutParams,
        synchronousLoads: Bool,
        previousItem: ListViewItem?,
        nextItem: ListViewItem?,
        completion: @escaping (
            ListViewItemNode,
            @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)
        ) -> Void
    ) {
        async {
            let node = AorusSpoofDeviceItemNode()
            let (layout, apply) = node.asyncLayout()(
                self,
                params,
                itemListNeighbors(
                    item: self,
                    topItem: previousItem as? ItemListItem,
                    bottomItem: nextItem as? ItemListItem
                )
            )
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(
        async: @escaping (@escaping () -> Void) -> Void,
        node: @escaping () -> ListViewItemNode,
        params: ListViewItemLayoutParams,
        previousItem: ListViewItem?,
        nextItem: ListViewItem?,
        animation: ListViewItemUpdateAnimation,
        completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void
    ) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? AorusSpoofDeviceItemNode else {
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(
                    self,
                    params,
                    itemListNeighbors(
                        item: self,
                        topItem: previousItem as? ItemListItem,
                        bottomItem: nextItem as? ItemListItem
                    )
                )
                Queue.mainQueue().async {
                    completion(layout, { _ in apply() })
                }
            }
        }
    }
}

private final class AorusSpoofDeviceItemNode: ItemListRevealOptionsItemNode {
    private let backgroundNode = ASDisplayNode()
    private let topStripeNode = ASDisplayNode()
    private let bottomStripeNode = ASDisplayNode()
    private let maskNode = ASImageNode()
    private weak var titleLabel: UILabel?
    private weak var checkLabel: UILabel?
    private var item: AorusSpoofDeviceItem?
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

    private func applyItem(_ item: AorusSpoofDeviceItem) {
        self.titleLabel?.text = item.title
        self.titleLabel?.textColor = item.theme.list.itemPrimaryTextColor
        self.titleLabel?.font = Font.regular(17.0)
        self.checkLabel?.text = item.selected ? "✓" : ""
        self.checkLabel?.textColor = item.theme.list.itemAccentColor
    }

    private func layoutContent() {
        guard let params = self.layoutParams else {
            return
        }
        let offset = self.revealOffset
        let left = params.leftInset + 16.0
        let right = params.rightInset + 48.0
        self.titleLabel?.frame = CGRect(
            x: offset + left,
            y: 12.0,
            width: params.width - left - right,
            height: 24.0
        )
        self.checkLabel?.frame = CGRect(
            x: offset + params.width - params.rightInset - 38.0,
            y: 12.0,
            width: 24.0,
            height: 24.0
        )
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if self.isDisplayingRevealedOptions {
            self.setRevealOptionsOpened(false, animated: true)
            self.revealOptionsInteractivelyClosed()
            return
        }
        guard let touch = touches.first,
              self.bounds.contains(touch.location(in: self.view)) else {
            return
        }
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

    func asyncLayout() -> (
        AorusSpoofDeviceItem,
        ListViewItemLayoutParams,
        ItemListNeighbors
    ) -> (ListViewItemNodeLayout, () -> Void) {
        return { item, params, neighbors in
            let contentSize = CGSize(width: params.width, height: 48.0)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            return (layout, { [weak self] in
                guard let self else {
                    return
                }
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

                self.maskNode.image = hasCorners
                    ? PresentationResourcesItemList.cornersImage(
                        item.theme,
                        top: topCorners,
                        bottom: bottomCorners
                    )
                    : nil
                let backgroundY = -min(insets.top, UIScreenPixel)
                let backgroundHeight = contentSize.height
                    + min(insets.top, UIScreenPixel)
                    + min(insets.bottom, UIScreenPixel)
                self.backgroundNode.frame = CGRect(
                    x: 0.0,
                    y: backgroundY,
                    width: params.width,
                    height: backgroundHeight
                )
                self.maskNode.frame = self.backgroundNode.frame.insetBy(
                    dx: params.leftInset,
                    dy: 0.0
                )
                self.topStripeNode.frame = CGRect(
                    x: 0.0,
                    y: backgroundY,
                    width: params.width,
                    height: UIScreenPixel
                )
                self.bottomStripeNode.frame = CGRect(
                    x: bottomInset,
                    y: contentSize.height + bottomOffset,
                    width: params.width - bottomInset,
                    height: UIScreenPixel
                )

                self.applyItem(item)
                self.layoutContent()
                self.updateLayout(
                    size: contentSize,
                    leftInset: params.leftInset,
                    rightInset: params.rightInset
                )
                self.updateRevealOptionsSeparatorNodes(
                    top: self.topStripeNode,
                    bottom: self.bottomStripeNode,
                    topIsHidden: self.topStripeNode.isHidden,
                    bottomIsHidden: self.bottomStripeNode.isHidden,
                    topHiddenByPreviousRevealOptions: neighbors.topHasActiveRevealOptions,
                    bottomHiddenByNextRevealOptions: neighbors.bottomHasActiveRevealOptions
                )
                let trashImage = UIImage(systemName: "trash.fill")
                let revealIcon: ItemListRevealOptionIcon = trashImage.map {
                    .image(image: $0)
                } ?? .none
                self.setRevealOptions((
                    left: [],
                    right: [
                        ItemListRevealOption(
                            key: 0,
                            title: item.deleteTitle,
                            icon: revealIcon,
                            color: item.theme.list.itemDisclosureActions.destructive.fillColor,
                            iconColor: item.theme.list.itemDisclosureActions.destructive.foregroundColor,
                            textColor: item.theme.list.itemDisclosureActions.destructive.foregroundColor
                        )
                    ]
                ))
            })
        }
    }
}

private enum AorusSpoofPlatform: String, CaseIterable {
    case ios
    case ipados
    case android
    case macos
    case windows
    case linux
    case harmonyOS
    case chromeOS
    case other

    var title: String {
        switch self {
        case .ios:
            return "iOS"
        case .ipados:
            return "iPadOS"
        case .android:
            return "Android"
        case .macos:
            return "macOS"
        case .windows:
            return "Windows"
        case .linux:
            return "Linux"
        case .harmonyOS:
            return "HarmonyOS"
        case .chromeOS:
            return "ChromeOS"
        case .other:
            return aorusL("Другая платформа", "Other Platform")
        }
    }

    func systemVersion(version: String) -> String {
        switch self {
        case .other:
            return version
        default:
            return "\(self.title) \(version)"
        }
    }
}

private enum AorusCustomDeviceSection: Int32 {
    case form
}

private struct AorusCustomDeviceState: Equatable {
    var model: String
    var platform: AorusSpoofPlatform
    var version: String

    var canSave: Bool {
        return !self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !self.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private final class AorusCustomDeviceArguments {
    let updateModel: (String) -> Void
    let selectPlatform: () -> Void
    let updateVersion: (String) -> Void
    let complete: () -> Void

    init(
        updateModel: @escaping (String) -> Void,
        selectPlatform: @escaping () -> Void,
        updateVersion: @escaping (String) -> Void,
        complete: @escaping () -> Void
    ) {
        self.updateModel = updateModel
        self.selectPlatform = selectPlatform
        self.updateVersion = updateVersion
        self.complete = complete
    }
}

private enum AorusCustomDeviceEntry: ItemListNodeEntry {
    case model(PresentationTheme, String, String)
    case platform(PresentationTheme, String, String)
    case version(PresentationTheme, String, String)

    var section: ItemListSectionId {
        return AorusCustomDeviceSection.form.rawValue
    }

    var stableId: Int32 {
        switch self {
        case .model:
            return 0
        case .platform:
            return 1
        case .version:
            return 2
        }
    }

    static func < (lhs: AorusCustomDeviceEntry, rhs: AorusCustomDeviceEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: AorusCustomDeviceEntry, rhs: AorusCustomDeviceEntry) -> Bool {
        switch lhs {
        case let .model(lhsTheme, lhsPlaceholder, lhsValue):
            if case let .model(rhsTheme, rhsPlaceholder, rhsValue) = rhs {
                return lhsTheme === rhsTheme
                    && lhsPlaceholder == rhsPlaceholder
                    && lhsValue == rhsValue
            }
        case let .platform(lhsTheme, lhsTitle, lhsValue):
            if case let .platform(rhsTheme, rhsTitle, rhsValue) = rhs {
                return lhsTheme === rhsTheme
                    && lhsTitle == rhsTitle
                    && lhsValue == rhsValue
            }
        case let .version(lhsTheme, lhsPlaceholder, lhsValue):
            if case let .version(rhsTheme, rhsPlaceholder, rhsValue) = rhs {
                return lhsTheme === rhsTheme
                    && lhsPlaceholder == rhsPlaceholder
                    && lhsValue == rhsValue
            }
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AorusCustomDeviceArguments
        switch self {
        case let .model(_, placeholder, value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                title: NSAttributedString(string: ""),
                text: value,
                placeholder: placeholder,
                type: .regular(capitalization: true, autocorrection: false),
                returnKeyType: .next,
                clearType: .onFocus,
                maxLength: 64,
                sectionId: self.section,
                textUpdated: arguments.updateModel,
                action: {}
            )
        case let .platform(_, title, value):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: title,
                label: value,
                sectionId: self.section,
                style: .blocks,
                action: arguments.selectPlatform
            )
        case let .version(_, placeholder, value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                title: NSAttributedString(string: ""),
                text: value,
                placeholder: placeholder,
                type: .regular(capitalization: false, autocorrection: false),
                returnKeyType: .done,
                clearType: .onFocus,
                maxLength: 32,
                sectionId: self.section,
                textUpdated: arguments.updateVersion,
                action: arguments.complete
            )
        }
    }
}

private func aorusCustomDeviceEntries(
    state: AorusCustomDeviceState,
    theme: PresentationTheme
) -> [AorusCustomDeviceEntry] {
    return [
        .model(
            theme,
            aorusL("Название устройства", "Device Name"),
            state.model
        ),
        .platform(
            theme,
            aorusL("Операционная система", "Operating System"),
            state.platform.title
        ),
        .version(
            theme,
            aorusL("Версия операционной системы", "Operating System Version"),
            state.version
        )
    ]
}

private func aorusAddCustomDeviceController(
    context: AccountContext,
    completion: @escaping (AorusSpoofDevice) -> Void
) -> ViewController {
    let initialState = AorusCustomDeviceState(
        model: "",
        platform: .android,
        version: ""
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((AorusCustomDeviceState) -> AorusCustomDeviceState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }

    weak var weakController: ItemListController?
    var completeImpl: (() -> Void)?

    let arguments = AorusCustomDeviceArguments(
        updateModel: { value in
            updateState { state in
                var updated = state
                updated.model = String(value.prefix(64))
                return updated
            }
        },
        selectPlatform: {
            guard let controller = weakController else {
                return
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let current = stateValue.with { $0.platform }
            let sheet = ActionSheetController(presentationData: presentationData)
            let optionItems: [ActionSheetButtonItem] = AorusSpoofPlatform.allCases.map { platform in
                return ActionSheetButtonItem(
                    title: platform.title,
                    color: .accent,
                    font: platform == current ? .bold : .default,
                    action: { [weak sheet] in
                        sheet?.dismissAnimated()
                        updateState { state in
                            var updated = state
                            updated.platform = platform
                            return updated
                        }
                    }
                )
            }
            sheet.setItemGroups([
                ActionSheetItemGroup(items: optionItems),
                ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(
                        title: presentationData.strings.Common_Cancel,
                        color: .accent,
                        font: .bold,
                        action: { [weak sheet] in
                            sheet?.dismissAnimated()
                        }
                    )
                ])
            ])
            controller.present(sheet, in: .window(.root))
        },
        updateVersion: { value in
            updateState { state in
                var updated = state
                updated.version = String(value.prefix(32))
                return updated
            }
        },
        complete: {
            completeImpl?()
        }
    )

    let signal = statePromise.get()
    |> deliverOnMainQueue
    |> map { state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(aorusL("Своё устройство", "Custom Device")),
            leftNavigationButton: nil,
            rightNavigationButton: ItemListNavigationButton(
                content: .text(aorusL("Добавить", "Add")),
                style: .bold,
                enabled: state.canSave,
                action: arguments.complete
            ),
            backNavigationButton: ItemListBackButton(
                title: presentationData.strings.Common_Back
            )
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aorusCustomDeviceEntries(
                state: state,
                // The derived theme: these rows are our own ListViewItems and take a
                // PresentationTheme directly, so they do not reach the glass one through
                // ItemListPresentationData.
                theme: presentationData.theme.aorusGlassListTheme
            ),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    weakController = controller
    completeImpl = { [weak controller] in
        let state = stateValue.with { $0 }
        let model = state.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = state.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !version.isEmpty else {
            return
        }
        let device = AorusSpoofDevice(
            id: "custom:\(UUID().uuidString)",
            model: String(model.prefix(64)),
            systemVersion: state.platform.systemVersion(
                version: String(version.prefix(32))
            ),
            custom: true
        )
        let _ = (controller?.navigationController as? NavigationController)?
            .popViewController(animated: true)
        DispatchQueue.main.async {
            completion(device)
        }
    }
    return controller
}

public func aorusDeviceSpoofController(
    context: AccountContext,
    initialModel: String?,
    initialSystemVersion: String?,
    selectionChanged: @escaping (String?, String?) -> Void
) -> ViewController {
    var customDevices = AorusDeviceSpoofStore.customDevices()
    var allDevices = AorusDeviceSpoofStore.presets + customDevices
    var matchingId = allDevices.first(where: { device in
        guard device.model == initialModel else {
            return false
        }
        if let initialSystemVersion, !initialSystemVersion.isEmpty {
            return device.systemVersion == initialSystemVersion
        }
        return true
    })?.id
    if matchingId == nil, let initialModel, let initialSystemVersion {
        let migrated = AorusSpoofDevice(
            id: "custom:\(UUID().uuidString)",
            model: initialModel,
            systemVersion: initialSystemVersion,
            custom: true
        )
        customDevices.append(migrated)
        AorusDeviceSpoofStore.saveCustomDevices(customDevices)
        allDevices.append(migrated)
        matchingId = migrated.id
    }
    let initialState = AorusDeviceSpoofState(
        enabled: initialModel != nil,
        selectedId: matchingId ?? AorusDeviceSpoofStore.savedSelectionId(),
        customDevices: customDevices
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((AorusDeviceSpoofState) -> AorusDeviceSpoofState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }

    weak var weakController: ItemListController?

    let selectedDevice: () -> AorusSpoofDevice = {
        let state = stateValue.with { $0 }
        return (AorusDeviceSpoofStore.presets + state.customDevices).first(where: {
            $0.id == state.selectedId
        }) ?? AorusDeviceSpoofStore.presets[1]
    }

    let arguments = AorusDeviceSpoofArguments(
        setEnabled: { enabled in
            updateState { state in
                var updated = state
                updated.enabled = enabled
                return updated
            }
            if enabled {
                let device = selectedDevice()
                AorusDeviceSpoofStore.saveSelectionId(device.id)
                selectionChanged(device.model, device.systemVersion)
            } else {
                selectionChanged(nil, nil)
            }
        },
        select: { device in
            AorusDeviceSpoofStore.saveSelectionId(device.id)
            updateState { state in
                var updated = state
                updated.selectedId = device.id
                return updated
            }
            selectionChanged(device.model, device.systemVersion)
        },
        deleteCustom: { device in
            guard device.custom else {
                return
            }
            let currentState = stateValue.with { $0 }
            var devices = currentState.customDevices
            devices.removeAll(where: { $0.id == device.id })
            guard devices.count != currentState.customDevices.count else {
                return
            }

            let deletedSelectedDevice = currentState.selectedId == device.id
            let fallback = AorusDeviceSpoofStore.presets[1]
            AorusDeviceSpoofStore.saveCustomDevices(devices)
            if deletedSelectedDevice {
                AorusDeviceSpoofStore.saveSelectionId(fallback.id)
            }
            updateState { state in
                var updated = state
                updated.customDevices = devices
                if deletedSelectedDevice {
                    updated.selectedId = fallback.id
                }
                return updated
            }
            if deletedSelectedDevice && currentState.enabled {
                selectionChanged(fallback.model, fallback.systemVersion)
            }
        },
        addCustom: {
            guard let navigationController = weakController?.navigationController as? NavigationController else {
                return
            }
            let addController = aorusAddCustomDeviceController(
                context: context,
                completion: { device in
                    var devices = stateValue.with { $0.customDevices }
                    devices.append(device)
                    AorusDeviceSpoofStore.saveCustomDevices(devices)
                    AorusDeviceSpoofStore.saveSelectionId(device.id)
                    updateState { state in
                        var updated = state
                        updated.customDevices = devices
                        updated.selectedId = device.id
                        return updated
                    }
                    selectionChanged(device.model, device.systemVersion)
                }
            )
            navigationController.pushViewController(addController)
        }
    )

    let signal = statePromise.get()
    |> deliverOnMainQueue
    |> map { state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(aorusL("Девайс-спуф", "Device Spoof")),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            // The derived theme: these rows are our own ListViewItems and take a PresentationTheme
            // directly, so they do not reach the glass one through ItemListPresentationData.
            entries: aorusDeviceSpoofEntries(state: state, theme: presentationData.theme.aorusGlassListTheme),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    weakController = controller
    return controller
}
