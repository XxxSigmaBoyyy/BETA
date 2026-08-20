import Foundation
import UIKit
import SwiftSignalKit
import Display
import AsyncDisplayKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI
import AorusGram

// The КОНФИГУРАЦИИ and СЕРВЕРА blocks under the saved proxies on Telegram's own Proxy screen: the
// VLESS configurations the user imported themselves, the switch that hands this client's transport
// to them, and the server they are pinned to.
//
// Same split as AorusConnectionSection, for the same reason -- everything that can live outside the
// patched upstream file does. The whole block is described by one row enum, so the patch adds a
// single entry case carrying it: what the rows are, in what order, in which of the three blocks,
// and what a tap does are all decided here.

/// Everything the two blocks draw, in one comparable value.
///
/// The measured latencies are copied in rather than read per row: a row is built on the list's
/// layout queue, and a value the list diffed against has to be the value it draws.
public struct AorusUserVPNSectionState: Equatable {
    public let enabled: Bool
    /// This process is carrying the user's configuration right now -- the lane is on and an
    /// endpoint has been published for it.
    public let serving: Bool
    public let configs: [AorusVlessConfig]
    public let selectedServerId: String?
    public let updatingConfigIds: Set<String>
    public let probingServerIds: Set<String>
    public let latencies: [String: Double]

    public init(
        enabled: Bool,
        serving: Bool,
        configs: [AorusVlessConfig],
        selectedServerId: String?,
        updatingConfigIds: Set<String>,
        probingServerIds: Set<String>,
        latencies: [String: Double]
    ) {
        self.enabled = enabled
        self.serving = serving
        self.configs = configs
        self.selectedServerId = selectedServerId
        self.updatingConfigIds = updatingConfigIds
        self.probingServerIds = probingServerIds
        self.latencies = latencies
    }

    /// The glyph beside "Использовать VPN". There is no suspended state here: the hybrid layer's
    /// direct-route decision is about *its* tunnel, and a VPN the user turned on themselves is
    /// never stood down behind their back.
    public var indicator: AorusConnectionIndicator {
        guard self.enabled else {
            return .none
        }
        return self.serving ? .connected : .connecting
    }

    /// Whether the switch has anything to point at. A configuration whose servers all failed to
    /// parse counts for nothing, which is why this asks for a server rather than for a card.
    public var canEnable: Bool {
        return self.configs.contains { !$0.servers.isEmpty }
    }

    /// Whose servers the СЕРВЕРА block lists: the configuration currently selected, or the first
    /// one when nothing is. Every configuration's own servers are also listed inside its settings
    /// screen, so nothing becomes unreachable with two of them imported.
    public var serverListConfig: AorusVlessConfig? {
        if let id = self.selectedServerId,
           let config = self.configs.first(where: { config in config.servers.contains { $0.id == id } }) {
            return config
        }
        return self.configs.first
    }
}

/// The state, re-emitted whenever a configuration, the selection, a refresh or a probe changes.
///
/// Four sources: the store, the manager's own activity, and the endpoint publication that says the
/// core is actually serving -- which is what turns "соединение" into "подключено" and is posted by
/// the tunnel rather than by anything the user did.
public func aorusUserVPNSectionState() -> Signal<AorusUserVPNSectionState, NoError> {
    return Signal { subscriber in
        let emit: () -> Void = {
            subscriber.putNext(aorusUserVPNSnapshot())
        }
        emit()
        let center = NotificationCenter.default
        let observers: [NSObjectProtocol] = [
            center.addObserver(
                forName: AorusUserVPNStore.didChangeNotification,
                object: nil, queue: OperationQueue.main, using: { _ in emit() }),
            center.addObserver(
                forName: AorusUserVPNManager.didChangeActivityNotification,
                object: nil, queue: OperationQueue.main, using: { _ in emit() }),
            center.addObserver(
                forName: NSNotification.Name("aorusgram_proxy_config_updated"),
                object: nil, queue: OperationQueue.main, using: { _ in emit() })
        ]
        return ActionDisposable {
            for observer in observers {
                center.removeObserver(observer)
            }
        }
    }
    |> distinctUntilChanged
}

private func aorusUserVPNSnapshot() -> AorusUserVPNSectionState {
    let store = AorusUserVPNStore.shared
    let manager = AorusUserVPNManager.shared
    let configs = store.configs
    var updating = Set<String>()
    var probing = Set<String>()
    var latencies: [String: Double] = [:]
    for config in configs {
        if manager.isUpdating(configId: config.id) {
            updating.insert(config.id)
        }
        for server in config.servers {
            if manager.isProbing(serverId: server.id) {
                probing.insert(server.id)
            }
            if let value = store.latency(serverId: server.id) {
                latencies[server.id] = value
            }
        }
    }
    return AorusUserVPNSectionState(
        enabled: store.isEnabled,
        serving: AorusRealityManager.shared.userLaneIsServing,
        configs: configs,
        selectedServerId: store.selectedServerId,
        updatingConfigIds: updating,
        probingServerIds: probing,
        latencies: latencies
    )
}

// MARK: - Rows

/// Which of the three rounded blocks a row belongs to. Blocks are what a section is on an
/// ItemList screen, and the switch, the configurations and the servers are three of them.
public enum AorusUserVPNRowSection {
    case toggle
    case configs
    case servers
}

/// One row of the two blocks.
///
/// The patch on the Proxy screen carries this in a single entry case, which is why the payloads
/// are values and not closures: the list diffs entries for equality, and a closure would make
/// every row differ from itself on every emission.
public enum AorusUserVPNRow: Equatable {
    /// "КОНФИГУРАЦИИ".
    case header(String)
    /// "Использовать VPN": the status word and glyph beside it, the value, and whether there is a
    /// server anywhere to point it at.
    case use(title: String, status: String?, indicator: AorusConnectionIndicator, value: Bool, available: Bool)
    /// One configuration's card, and whether its subscription is being refreshed right now.
    case config(index: Int, config: AorusVlessConfig, updating: Bool)
    /// The traffic bar, present only for a configuration whose panel reported one.
    case traffic(index: Int, used: Int64, total: Int64?)
    /// "Добавить конфигурацию". Drawn by the patched screen with its own "add" row, so that it is
    /// the same row as "Добавить прокси" above it rather than a lookalike.
    case add(String)
    case info(String)
    /// "СЕРВЕРА".
    case serversHeader(String)
    case server(index: Int, configId: String, server: AorusVlessServer, selected: Bool, latency: Double?, probing: Bool)

    public var section: AorusUserVPNRowSection {
        switch self {
        case .header, .use:
            return .toggle
        case .config, .traffic, .add, .info:
            return .configs
        case .serversHeader, .server:
            return .servers
        }
    }

    /// Both the order of the rows and, offset by the block's own base, their stable ids -- so this
    /// has to be unique per row and not merely ordered. Two numbers per configuration keep a card
    /// and its traffic bar together however many configurations there are, and the servers start
    /// well past any list of cards.
    public var sortIndex: Int {
        switch self {
        case .header:
            return 0
        case .use:
            return 1
        case let .config(index, _, _):
            return 100 + index * 2
        case let .traffic(index, _, _):
            return 101 + index * 2
        case .add:
            return 5000
        case .info:
            return 5001
        case .serversHeader:
            return 5002
        case let .server(index, _, _, _, _, _):
            return 6000 + index
        }
    }
}

/// The rows, in order, for a given state.
public func aorusUserVPNRows(state: AorusUserVPNSectionState, languageCode: String?) -> [AorusUserVPNRow] {
    let l10n = AorusL10n(languageCode)
    var rows: [AorusUserVPNRow] = []
    rows.append(.header(l10n.userVPNHeader))

    let indicator = state.indicator
    let status: String?
    switch indicator {
    case .none:
        status = nil
    case .connecting:
        status = l10n.connectionConnecting
    case .connected:
        status = l10n.connectionConnected
    case .suspended:
        status = l10n.connectionSuspended
    }
    rows.append(.use(
        title: l10n.userVPNUse,
        status: status,
        indicator: indicator,
        value: state.enabled,
        available: state.canEnable
    ))

    for (index, config) in state.configs.enumerated() {
        rows.append(.config(index: index, config: config, updating: state.updatingConfigIds.contains(config.id)))
        if let used = config.trafficUsed {
            rows.append(.traffic(index: index, used: used, total: config.trafficTotal))
        }
    }
    rows.append(.add(l10n.userVPNAddConfig))
    rows.append(.info(l10n.userVPNFooter))

    if let config = state.serverListConfig, !config.servers.isEmpty {
        rows.append(.serversHeader(l10n.userVPNServersHeader))
        for (index, server) in config.servers.enumerated() {
            rows.append(.server(
                index: index,
                configId: config.id,
                server: server,
                selected: state.selectedServerId == server.id,
                latency: state.latencies[server.id],
                probing: state.probingServerIds.contains(server.id)
            ))
        }
    }
    return rows
}

/// The list item for one row.
///
/// `buildAddRow` is passed in rather than built here because the "+" row on the Proxy screen is an
/// item internal to SettingsUI: the user asked for the same button as "Добавить прокси", and the
/// only way to be the same button is to be the same item.
public func aorusUserVPNRowItem(
    presentationData: ItemListPresentationData,
    context: AccountContext?,
    row: AorusUserVPNRow,
    sectionId: ItemListSectionId,
    present: @escaping (ViewController) -> Void,
    openConfig: @escaping (String) -> Void,
    buildAddRow: (String) -> ListViewItem
) -> ListViewItem {
    let l10n = AorusL10n(presentationData.strings.baseLanguageCode)
    switch row {
    case let .header(text):
        return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: sectionId)
    case let .serversHeader(text):
        return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: sectionId)
    case let .use(title, status, indicator, value, available):
        // Not intercepted in `updated`: with nothing to dial the store refuses to stay on, and a
        // switch that reverts itself leaves the row showing a value the state never had. Upstream's
        // own disabled-switch pair says the same thing without ever moving.
        return aorusConnectionSwitchItem(
            presentationData: presentationData,
            title: title,
            statusText: status,
            indicator: indicator,
            value: value,
            sectionId: sectionId,
            enabled: available,
            activatedWhileDisabled: {
                aorusUserVPNPresentPill(context: context, text: l10n.userVPNNoConfigs, present: present)
            },
            updated: { value in
                AorusUserVPNManager.shared.setEnabled(value)
            }
        )
    case let .config(_, config, updating):
        return ItemListDisclosureItem(
            presentationData: presentationData,
            systemStyle: .glass,
            title: config.name,
            label: aorusUserVPNConfigDetail(config: config, updating: updating, l10n: l10n),
            labelStyle: .detailText,
            sectionId: sectionId,
            style: .blocks,
            action: {
                openConfig(config.id)
            }
        )
    case let .traffic(_, used, total):
        return AorusUserVPNTrafficItem(
            presentationData: presentationData,
            used: used,
            total: total,
            sectionId: sectionId
        )
    case let .add(text):
        return buildAddRow(text)
    case let .info(text):
        return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: sectionId)
    case let .server(_, configId, server, selected, latency, probing):
        // The checkmark is the selection, which is what the user asked the tap to leave behind, and
        // the inset to the left of it is where the measured time goes.
        return ItemListCheckboxItem(
            presentationData: presentationData,
            systemStyle: .glass,
            title: server.name,
            subtitle: aorusUserVPNServerDetail(server: server, latency: latency, probing: probing, l10n: l10n),
            style: .right,
            checked: selected,
            zeroSeparatorInsets: false,
            sectionId: sectionId,
            action: {
                AorusUserVPNManager.shared.selectServer(id: server.id)
            },
            deleteAction: {
                AorusUserVPNManager.shared.removeServer(configId: configId, serverId: server.id)
            }
        )
    }
}

// MARK: - Import

/// "Добавить конфигурацию": take whatever is on the clipboard and make a configuration of it.
///
/// A pasted key is parsed in place and is done before the pill is on screen; a subscription URL is
/// a network round trip, and the wait is what the pill is for.
public func aorusUserVPNImportFromClipboard(context: AccountContext, present: @escaping (ViewController) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let l10n = AorusL10n(presentationData.strings.baseLanguageCode)
    let pasted = UIPasteboard.general.string ?? ""
    guard !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        present(aorusUserVPNAlert(
            context: context,
            title: l10n.userVPNImportFailed,
            text: l10n.userVPNClipboardEmpty
        ))
        return
    }
    let progress = aorusUserVPNPill(presentationData: presentationData, text: l10n.userVPNImporting, replacing: false)
    present(progress)
    AorusUserVPNManager.shared.importText(pasted) { result in
        progress.dismiss()
        switch result {
        case let .added(_, servers):
            present(aorusUserVPNPill(
                presentationData: presentationData,
                text: l10n.userVPNImported(servers),
                replacing: true
            ))
        case let .failed(error):
            present(aorusUserVPNAlert(
                context: context,
                title: l10n.userVPNImportFailed,
                text: aorusUserVPNImportErrorText(error, l10n)
            ))
        }
    }
}

// MARK: - Shared pieces

/// The card's second line: how many servers, when the list was last refreshed, and how long the
/// panel says the configuration is good for.
func aorusUserVPNConfigDetail(config: AorusVlessConfig, updating: Bool, l10n: AorusL10n) -> String {
    if updating {
        return l10n.userVPNUpdating
    }
    var parts: [String] = [l10n.userVPNServerCount(config.servers.count)]
    if config.updatedAt > 0.0 {
        parts.append(l10n.userVPNUpdatedAt(aorusUserVPNDateTimeText(config.updatedAt)))
    }
    if let expires = config.expiresAt, expires > 0.0 {
        parts.append(l10n.userVPNExpiresShort(aorusUserVPNDateText(expires)))
    }
    return parts.joined(separator: " · ")
}

/// The server row's second line: what the key actually is, and the last measured handshake.
func aorusUserVPNServerDetail(
    server: AorusVlessServer,
    latency: Double?,
    probing: Bool,
    l10n: AorusL10n
) -> String {
    var text = server.summary
    if probing {
        text += " · " + l10n.userVPNProbing
    } else if let latency = latency, latency > 0.0 {
        text += " · " + l10n.userVPNLatency(Int(latency.rounded()))
    }
    return text
}

/// Units follow the system language rather than Telegram's, which is the trade for having correct
/// ones in all forty of them: the alternative is a table of unit names and plural rules of our own.
/// Created per call, because a Formatter is not safe to share across the list's layout queue.
func aorusUserVPNByteText(_ value: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: max(0, value))
}

func aorusUserVPNDateTimeText(_ timestamp: TimeInterval) -> String {
    return DateFormatter.localizedString(
        from: Date(timeIntervalSince1970: timestamp),
        dateStyle: .short,
        timeStyle: .short
    )
}

func aorusUserVPNDateText(_ timestamp: TimeInterval) -> String {
    return DateFormatter.localizedString(
        from: Date(timeIntervalSince1970: timestamp),
        dateStyle: .medium,
        timeStyle: .none
    )
}

func aorusUserVPNImportErrorText(_ error: AorusVlessImportError, _ l10n: AorusL10n) -> String {
    switch error {
    case .empty:
        return l10n.userVPNClipboardEmpty
    case .unsupported:
        return l10n.userVPNImportUnsupported
    case .malformed:
        return l10n.userVPNImportMalformed
    case .insecureSubscription:
        return l10n.userVPNImportInsecure
    }
}

func aorusUserVPNAlert(context: AccountContext, title: String, text: String) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    return textAlertController(
        context: context,
        title: title,
        text: text,
        actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
    )
}

/// Telegram's own bottom info pill, which is what the rest of the app reports a finished action
/// with. `animateInAsReplacement` is what makes the result slide over the progress pill instead of
/// waiting for it to leave.
func aorusUserVPNPill(presentationData: PresentationData, text: String, replacing: Bool) -> UndoOverlayController {
    return UndoOverlayController(
        presentationData: presentationData,
        content: .info(title: nil, text: text, timeout: nil, customUndoText: nil),
        elevatedLayout: false,
        position: .bottom,
        animateInAsReplacement: replacing,
        action: { _ in return true }
    )
}

private func aorusUserVPNPresentPill(
    context: AccountContext?,
    text: String,
    present: @escaping (ViewController) -> Void
) {
    guard let context = context else {
        return
    }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    present(aorusUserVPNPill(presentationData: presentationData, text: text, replacing: false))
}

// MARK: - The traffic bar

/// Used and total, with a bar between them.
///
/// A custom item because there is no stock one: every progress bar in the app belongs to a
/// component-based screen, and this row lives on a plain ItemList. The rounded block, the corner
/// mask and the hairlines are the same ones every other row of the block draws, so it sits inside
/// the card rather than on top of it.
final class AorusUserVPNTrafficItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let used: Int64
    let total: Int64?
    /// Which corner radius the block draws with, so the bar matches the rows above and below it
    /// rather than deciding for itself: `.glass` on the Proxy screen, where every upstream row is
    /// glass, and the default elsewhere.
    let systemStyle: ItemListSystemStyle
    let sectionId: ItemListSectionId
    let tag: ItemListItemTag? = nil

    init(presentationData: ItemListPresentationData, used: Int64, total: Int64?, systemStyle: ItemListSystemStyle = .glass, sectionId: ItemListSectionId) {
        self.presentationData = presentationData
        self.used = used
        self.total = total
        self.systemStyle = systemStyle
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AorusUserVPNTrafficItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? AorusUserVPNTrafficItemNode {
                let makeLayout = nodeValue.asyncLayout()
                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply()
                        })
                    }
                }
            }
        }
    }
}

final class AorusUserVPNTrafficItemNode: ListViewItemNode, ItemListItemNode {
    private let backgroundNode: ASDisplayNode
    private let topStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let maskNode: ASImageNode
    private let usedNode: TextNode
    private let totalNode: TextNode
    private let trackNode: ASDisplayNode
    private let fillNode: ASDisplayNode
    private let activateArea: AccessibilityAreaNode

    private var item: AorusUserVPNTrafficItem?

    var tag: ItemListItemTag? {
        return self.item?.tag
    }

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true
        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true
        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true
        self.maskNode = ASImageNode()

        self.usedNode = TextNode()
        self.usedNode.isUserInteractionEnabled = false
        self.usedNode.contentMode = .topLeft
        self.usedNode.contentsScale = UIScreen.main.scale
        self.totalNode = TextNode()
        self.totalNode.isUserInteractionEnabled = false
        self.totalNode.contentMode = .topLeft
        self.totalNode.contentsScale = UIScreen.main.scale

        self.trackNode = ASDisplayNode()
        self.trackNode.isLayerBacked = true
        self.trackNode.cornerRadius = aorusUserVPNBarHeight / 2.0
        self.fillNode = ASDisplayNode()
        self.fillNode.isLayerBacked = true
        self.fillNode.cornerRadius = aorusUserVPNBarHeight / 2.0

        self.activateArea = AccessibilityAreaNode()
        self.activateArea.accessibilityTraits = .staticText

        super.init(layerBacked: false)

        self.addSubnode(self.usedNode)
        self.addSubnode(self.totalNode)
        self.addSubnode(self.trackNode)
        self.addSubnode(self.fillNode)
        self.addSubnode(self.activateArea)
    }

    func asyncLayout() -> (_ item: AorusUserVPNTrafficItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let makeUsedLayout = TextNode.asyncLayout(self.usedNode)
        let makeTotalLayout = TextNode.asyncLayout(self.totalNode)
        let currentItem = self.item

        return { item, params, neighbors in
            var updatedTheme: PresentationTheme?
            if currentItem?.presentationData.theme !== item.presentationData.theme {
                updatedTheme = item.presentationData.theme
            }

            let leftInset: CGFloat = 16.0 + params.leftInset
            let rightInset: CGFloat = 16.0 + params.rightInset
            let verticalInset: CGFloat = 12.0
            let barSpacing: CGFloat = 9.0
            let font = Font.regular(floor(item.presentationData.fontSize.itemListBaseFontSize * 15.0 / 17.0))
            let available = max(1.0, params.width - leftInset - rightInset)

            // The total is the constant of the two, so it is measured first and the used side gets
            // whatever is left -- on a narrow screen it is the byte count that may truncate, not the
            // limit the user is being told about.
            let totalText = item.total.flatMap { value -> String? in
                value > 0 ? aorusUserVPNByteText(value) : nil
            } ?? aorusUserVPNUnlimitedGlyph
            let (totalLayout, totalApply) = makeTotalLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: totalText, font: font, textColor: item.presentationData.theme.list.itemSecondaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: available, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
            let (usedLayout, usedApply) = makeUsedLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: aorusUserVPNByteText(item.used), font: font, textColor: item.presentationData.theme.list.itemPrimaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(1.0, available - totalLayout.size.width - 8.0), height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))

            let contentHeight = verticalInset * 2.0 + max(usedLayout.size.height, totalLayout.size.height) + barSpacing + aorusUserVPNBarHeight
            let contentSize = CGSize(width: params.width, height: contentHeight)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            let layoutSize = layout.size
            let separatorHeight = UIScreenPixel
            let separatorRightInset: CGFloat = 16.0

            var progress: CGFloat = 0.0
            if let total = item.total, total > 0 {
                progress = max(0.0, min(1.0, CGFloat(Double(item.used) / Double(total))))
            }

            return (layout, { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item

                strongSelf.activateArea.frame = CGRect(origin: CGPoint(x: params.leftInset, y: 0.0), size: CGSize(width: params.width - params.leftInset - params.rightInset, height: contentHeight))
                strongSelf.activateArea.accessibilityLabel = "\(aorusUserVPNByteText(item.used)) / \(totalText)"

                if updatedTheme != nil {
                    strongSelf.topStripeNode.backgroundColor = item.presentationData.theme.list.itemBlocksSeparatorColor
                    strongSelf.bottomStripeNode.backgroundColor = item.presentationData.theme.list.itemBlocksSeparatorColor
                    strongSelf.backgroundNode.backgroundColor = item.presentationData.theme.list.itemBlocksBackgroundColor
                    strongSelf.trackNode.backgroundColor = item.presentationData.theme.list.itemSecondaryTextColor.withAlphaComponent(0.2)
                    strongSelf.fillNode.backgroundColor = aorusConnectionLinkColor(theme: item.presentationData.theme)
                }

                let _ = usedApply()
                let _ = totalApply()

                if strongSelf.backgroundNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.backgroundNode, at: 0)
                }
                if strongSelf.topStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.topStripeNode, at: 1)
                }
                if strongSelf.bottomStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 2)
                }
                if strongSelf.maskNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.maskNode, at: 3)
                }

                let hasCorners = itemListHasRoundedBlockLayout(params)
                var hasTopCorners = false
                var hasBottomCorners = false
                switch neighbors.top {
                case .sameSection(false):
                    strongSelf.topStripeNode.isHidden = true
                default:
                    hasTopCorners = true
                    strongSelf.topStripeNode.isHidden = hasCorners
                }
                switch neighbors.bottom {
                case .sameSection(false):
                    strongSelf.bottomStripeNode.isHidden = false
                default:
                    hasBottomCorners = true
                    strongSelf.bottomStripeNode.isHidden = hasCorners
                }

                strongSelf.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(item.presentationData.theme, top: hasTopCorners, bottom: hasBottomCorners, glass: item.systemStyle == .glass) : nil

                strongSelf.backgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentHeight + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
                strongSelf.maskNode.frame = strongSelf.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0.0)
                strongSelf.topStripeNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: layoutSize.width, height: separatorHeight))
                strongSelf.bottomStripeNode.frame = CGRect(origin: CGPoint(x: leftInset, y: contentHeight - separatorHeight), size: CGSize(width: max(0.0, layoutSize.width - leftInset - params.rightInset - separatorRightInset), height: separatorHeight))

                strongSelf.usedNode.frame = CGRect(origin: CGPoint(x: leftInset, y: verticalInset), size: usedLayout.size)
                strongSelf.totalNode.frame = CGRect(origin: CGPoint(x: max(leftInset, layoutSize.width - rightInset - totalLayout.size.width), y: verticalInset), size: totalLayout.size)

                let barWidth = max(0.0, layoutSize.width - leftInset - rightInset)
                let barY = verticalInset + max(usedLayout.size.height, totalLayout.size.height) + barSpacing
                strongSelf.trackNode.frame = CGRect(origin: CGPoint(x: leftInset, y: barY), size: CGSize(width: barWidth, height: aorusUserVPNBarHeight))
                // A fill narrower than the bar's own corner radius would draw as a lens rather than
                // as a sliver, so a non-zero share is never thinner than its rounding.
                let fillWidth = progress > 0.0 ? max(aorusUserVPNBarHeight, floor(barWidth * progress)) : 0.0
                strongSelf.fillNode.frame = CGRect(origin: CGPoint(x: leftInset, y: barY), size: CGSize(width: fillWidth, height: aorusUserVPNBarHeight))
                strongSelf.fillNode.isHidden = fillWidth <= 0.0
            })
        }
    }
}

private let aorusUserVPNBarHeight: CGFloat = 4.0
/// Not translated on purpose: a panel that reports no limit means exactly this in every language.
let aorusUserVPNUnlimitedGlyph = "∞"
