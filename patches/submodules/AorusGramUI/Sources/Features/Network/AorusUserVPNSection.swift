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
    /// Every server the lane could dial has refused to come up. Distinct from "not serving yet":
    /// one is a connection being made, the other is one that will not be.
    ///
    /// Not read by `indicator` any more -- see the note there -- but still part of the state, and
    /// deliberately: it is one of the things whose change has to make the list re-emit, since a
    /// verdict landing is exactly when the row has something new to say.
    public let unreachable: Bool
    /// A bring-up the user asked for is in flight — the switch was turned on, or another server was
    /// picked. True at the same time as `serving` for the length of a switch, because the endpoint
    /// already up keeps carrying traffic until the new one is proven.
    public let connecting: Bool
    public let configs: [AorusVlessConfig]
    public let selectedServerId: String?
    public let updatingConfigIds: Set<String>
    public let probingServerIds: Set<String>
    public let latencies: [String: Double]

    public init(
        enabled: Bool,
        serving: Bool,
        unreachable: Bool,
        connecting: Bool = false,
        configs: [AorusVlessConfig],
        selectedServerId: String?,
        updatingConfigIds: Set<String>,
        probingServerIds: Set<String>,
        latencies: [String: Double]
    ) {
        self.enabled = enabled
        self.serving = serving
        self.unreachable = unreachable
        self.connecting = connecting
        self.configs = configs
        self.selectedServerId = selectedServerId
        self.updatingConfigIds = updatingConfigIds
        self.probingServerIds = probingServerIds
        self.latencies = latencies
    }

    /// The glyph beside "Использовать VPN". A VPN the user turned on themselves is never stood down
    /// behind their back, so the cross here is not the hybrid layer's "suspended" -- it is every
    /// server having been tried and none of them answering.
    ///
    /// A bring-up in flight outranks the endpoint that is still published: picking another server
    /// looks like a connection being made, which is what it is, rather than like nothing having
    /// happened because the old server is still carrying traffic in the meantime.
    ///
    /// "Connecting" is claimed only while the lane says a bring-up is actually in flight. It was the
    /// fallthrough too -- `unreachable ? .suspended : .connecting` -- and that is what left the glyph
    /// turning for as long as the screen stayed open. "Enabled, nothing published, nothing in flight,
    /// and no verdict recorded" is a real state and it is not a connection being made: it is a lane
    /// switched on with nothing dialable, or a round that overran the window it was being shown in,
    /// or a walk that ended somewhere that never wrote a verdict down. The row said "соединение"
    /// about all of them, and went on saying it, because nothing was ever going to come along and
    /// change the answer. What is true of all of them is that there is no connection, so that is what
    /// the row says -- and the lane, for its part, now always reaches a verdict inside the window.
    public var indicator: AorusConnectionIndicator {
        guard self.enabled else {
            return .none
        }
        if self.connecting {
            return .connecting
        }
        if self.serving {
            return .connected
        }
        return .suspended
    }

    /// Whether the switch has anything to point at. A configuration whose servers all failed to
    /// parse counts for nothing, which is why this asks for a server rather than for a card.
    public var canEnable: Bool {
        return self.configs.contains { !$0.servers.isEmpty }
    }

}

/// The state, re-emitted whenever a configuration, the selection, a refresh or a probe changes.
///
/// Four sources: the store, the manager's own activity, and the endpoint publication that says the
/// core is actually serving -- which is what turns "соединение" into "подключено" and is posted by
/// the tunnel rather than by anything the user did.
public func aorusUserVPNSectionState() -> Signal<AorusUserVPNSectionState, NoError> {
    return Signal { subscriber in
        // Measuring starts when the block does. The servers' handshakes are what "Лучший сервер"
        // and the fastest-server choice are made of, and this screen is the only place that lists
        // them, so nowhere else would ever ask.
        AorusUserVPNManager.shared.measureVisibleServers()
        // And every subscription that is allowed to update itself and has gone stale is refetched,
        // so the traffic and expiry on the cards are the panel's own numbers when the screen opens
        // rather than whatever they were when the user last pressed "Обновить" by hand.
        AorusUserVPNManager.shared.refreshStaleSubscriptions()
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
        unreachable: AorusRealityManager.shared.userLaneIsUnreachable,
        connecting: AorusRealityManager.shared.userLaneIsConnecting,
        configs: configs,
        selectedServerId: store.selectedServerId,
        updatingConfigIds: updating,
        probingServerIds: probing,
        latencies: latencies
    )
}

// MARK: - Rows

/// Which rounded block a row belongs to. Blocks are what a section is on an ItemList screen, and
/// with several subscriptions imported there is one per configuration rather than one list of cards
/// followed by one list of servers: a card, its traffic and its own servers read as one thing.
public enum AorusUserVPNRowSection: Equatable {
    case toggle
    /// One configuration, by its position in the list.
    case config(Int)
    /// "Добавить конфигурацию", and the caption under everything.
    case footer
}

/// One row of the block.
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
    /// A server of the configuration at `configIndex`, in that configuration's own block.
    case server(
        configIndex: Int,
        index: Int,
        configId: String,
        server: AorusVlessServer,
        selected: Bool,
        best: Bool,
        latency: Double?,
        probing: Bool,
        connecting: Bool
    )

    public var section: AorusUserVPNRowSection {
        switch self {
        case .header, .use:
            return .toggle
        case let .config(index, _, _):
            return .config(index)
        case let .traffic(index, _, _):
            return .config(index)
        case let .server(configIndex, _, _, _, _, _, _, _, _):
            return .config(configIndex)
        case .add, .info:
            return .footer
        }
    }

    /// Both the order of the rows and, offset by the block's own base, their stable ids -- so this
    /// has to be unique per row and not merely ordered. Each configuration gets a thousand numbers:
    /// its card, its traffic bar and then its servers, which keeps a block's rows together and their
    /// ids stable while a subscription's server list changes under them.
    public var sortIndex: Int {
        switch self {
        case .header:
            return 0
        case .use:
            return 1
        case let .config(index, _, _):
            return Self.configBase(index)
        case let .traffic(index, _, _):
            return Self.configBase(index) + 1
        case let .server(configIndex, index, _, _, _, _, _, _, _):
            // Clamped, because two rows with one id is a list that draws one of them: a
            // subscription with a thousand servers loses the order of its tail rather than a row.
            return Self.configBase(configIndex) + 2 + min(index, 900)
        case .add:
            return 2_000_000
        case .info:
            return 2_000_001
        }
    }

    private static func configBase(_ index: Int) -> Int {
        // Clamped for the same reason a server's index is: `.add` sits at 2_000_000, and an id that
        // reaches it would be two rows claiming to be one.
        return 1_000 + min(index, 1_900) * 1_000
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
        status = l10n.connectionUnreachable
    }
    rows.append(.use(
        title: l10n.userVPNUse,
        status: status,
        indicator: indicator,
        value: state.enabled,
        available: state.canEnable
    ))

    // A configuration and its servers, then the next configuration and its servers. Listing every
    // card first and only the selected card's servers afterwards is what put two lists of the same
    // thing next to each other, and it also hid the servers of every configuration but one.
    for (index, config) in state.configs.enumerated() {
        rows.append(.config(index: index, config: config, updating: state.updatingConfigIds.contains(config.id)))
        if let used = config.trafficUsed {
            rows.append(.traffic(index: index, used: used, total: config.trafficTotal))
        }
        let bestServerId = aorusUserVPNBestMeasuredServerId(config: config, latencies: state.latencies)
        for (serverIndex, server) in config.servers.enumerated() {
            // The selection is one server across every configuration, so the checkmark can only
            // ever be on one row however many lists are on the screen.
            rows.append(.server(
                configIndex: index,
                index: serverIndex,
                configId: config.id,
                server: server,
                selected: state.selectedServerId == server.id,
                best: bestServerId == server.id,
                latency: state.latencies[server.id],
                probing: state.probingServerIds.contains(server.id),
                connecting: state.connecting && state.selectedServerId == server.id
            ))
        }
    }
    rows.append(.add(l10n.userVPNAddConfig))
    rows.append(.info(l10n.userVPNFooter))
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
    case let .use(title, status, indicator, value, available):
        return aorusConnectionSwitchItem(
            presentationData: presentationData,
            title: title,
            statusText: status,
            indicator: indicator,
            value: value,
            sectionId: sectionId,
            // Keep the native switch appearance even before the first import. A disabled glass
            // control gets the system's rectangular disabled tint, which does not match the pane.
            enabled: true,
            activatedWhileDisabled: {
                aorusUserVPNPresentPill(context: context, text: l10n.userVPNNoConfigs, present: present)
            },
            updated: { value in
                guard available || !value else {
                    // Let the manager perform its normal empty-config refusal as well. It emits
                    // the store update that puts the native switch back to off immediately;
                    // merely returning here left the control visually enabled until a redraw.
                    AorusUserVPNManager.shared.setEnabled(value)
                    aorusUserVPNPresentPill(context: context, text: l10n.userVPNNoConfigs, present: present)
                    return
                }
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
    case let .server(_, _, configId, server, selected, best, latency, probing, connecting):
        // The checkmark is the selection, which is what the user asked the tap to leave behind, and
        // the inset to the left of it is where the measured time goes.
        return ItemListCheckboxItem(
            presentationData: presentationData,
            systemStyle: .glass,
            title: server.name,
            subtitle: aorusUserVPNServerDetail(
                server: server,
                best: best,
                latency: latency,
                probing: probing,
                connecting: connecting,
                l10n: l10n
            ),
            style: .left,
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
    return parts.joined(separator: " | ")
}

/// The server row's second line: what the key actually is, and the last measured handshake.
func aorusUserVPNServerDetail(
    server: AorusVlessServer,
    best: Bool,
    latency: Double?,
    probing: Bool,
    connecting: Bool = false,
    l10n: AorusL10n
) -> String {
    var parts: [String] = []
    if best {
        parts.append(l10n.userVPNBestServer)
    }
    parts.append(server.transportSummary)
    if connecting {
        // The row the user just picked says so on the row itself. Waiting until they navigate back
        // to the Proxy screen to see anything happen is what made a switch look like nothing.
        parts.append(l10n.connectionConnecting)
    } else if probing {
        parts.append(l10n.userVPNProbing)
    } else if let latency = latency, latency > 0.0 {
        parts.append(l10n.userVPNLatency(Int(latency.rounded())))
    }
    return parts.joined(separator: " | ")
}

func aorusUserVPNBestMeasuredServerId(
    config: AorusVlessConfig,
    latencies: [String: Double]
) -> String? {
    return config.servers.compactMap { server -> (String, Double)? in
        guard let value = latencies[server.id], value > 0.0 else { return nil }
        return (server.id, value)
    }.min(by: { $0.1 < $1.1 })?.0
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
    let date = Date(timeIntervalSince1970: timestamp)
    // A subscription refreshed today only needs the time. With the date as well the card's second
    // line runs past the row and truncates mid-number, which reads as a bug rather than as detail.
    if Calendar.current.isDateInToday(date) {
        return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
    return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none)
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
    case .duplicate:
        return l10n.userVPNImportDuplicate
    case .deviceLimit:
        return l10n.userVPNImportDeviceLimit
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
