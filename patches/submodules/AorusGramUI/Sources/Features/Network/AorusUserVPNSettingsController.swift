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

// The screen behind a configuration's card: everything a VLESS client lets you decide about one
// configuration -- its name, what rides it, how its server list is kept, and how to get rid of it.

private final class AorusUserVPNSettingsArguments {
    let context: AccountContext
    let setName: (String) -> Void
    let setUdpEnabled: (Bool) -> Void
    let setCallsEnabled: (Bool) -> Void
    let setMuxEnabled: (Bool) -> Void
    let setAutoUpdate: (Bool) -> Void
    let setAutoSelectFastest: (Bool) -> Void
    let updateNow: () -> Void
    let copySource: () -> Void
    let probeServers: () -> Void
    let selectServer: (String) -> Void
    let removeServer: (String) -> Void
    let copyKey: () -> Void
    let deleteConfig: () -> Void

    init(
        context: AccountContext,
        setName: @escaping (String) -> Void,
        setUdpEnabled: @escaping (Bool) -> Void,
        setCallsEnabled: @escaping (Bool) -> Void,
        setMuxEnabled: @escaping (Bool) -> Void,
        setAutoUpdate: @escaping (Bool) -> Void,
        setAutoSelectFastest: @escaping (Bool) -> Void,
        updateNow: @escaping () -> Void,
        copySource: @escaping () -> Void,
        probeServers: @escaping () -> Void,
        selectServer: @escaping (String) -> Void,
        removeServer: @escaping (String) -> Void,
        copyKey: @escaping () -> Void,
        deleteConfig: @escaping () -> Void
    ) {
        self.context = context
        self.setName = setName
        self.setUdpEnabled = setUdpEnabled
        self.setCallsEnabled = setCallsEnabled
        self.setMuxEnabled = setMuxEnabled
        self.setAutoUpdate = setAutoUpdate
        self.setAutoSelectFastest = setAutoSelectFastest
        self.updateNow = updateNow
        self.copySource = copySource
        self.probeServers = probeServers
        self.selectServer = selectServer
        self.removeServer = removeServer
        self.copyKey = copyKey
        self.deleteConfig = deleteConfig
    }
}

private enum AorusUserVPNSettingsSection: Int32 {
    case name
    case connection
    case subscription
    case selection
    case traffic
    case servers
    case danger
}

private enum AorusUserVPNSettingsEntry: ItemListNodeEntry {
    case nameHeader(PresentationTheme, String)
    case name(PresentationTheme, String, String)
    case connectionHeader(PresentationTheme, String)
    case udp(PresentationTheme, String, Bool)
    case calls(PresentationTheme, String, Bool)
    case mux(PresentationTheme, String, Bool)
    case connectionInfo(PresentationTheme, String)
    case subscriptionHeader(PresentationTheme, String)
    case autoUpdate(PresentationTheme, String, Bool)
    case updateNow(PresentationTheme, String, Bool)
    case source(PresentationTheme, String, String)
    case subscriptionInfo(PresentationTheme, String)
    case selectionHeader(PresentationTheme, String)
    case autoFastest(PresentationTheme, String, Bool)
    case probe(PresentationTheme, String, Bool)
    case selectionInfo(PresentationTheme, String)
    case trafficHeader(PresentationTheme, String)
    case traffic(PresentationTheme, Int64, Int64?)
    case expires(PresentationTheme, String, String)
    case serversHeader(PresentationTheme, String)
    case server(PresentationTheme, Int32, String, String, String, Bool)
    case copyKey(PresentationTheme, String)
    case delete(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .nameHeader, .name:
            return AorusUserVPNSettingsSection.name.rawValue
        case .connectionHeader, .udp, .calls, .mux, .connectionInfo:
            return AorusUserVPNSettingsSection.connection.rawValue
        case .subscriptionHeader, .autoUpdate, .updateNow, .source, .subscriptionInfo:
            return AorusUserVPNSettingsSection.subscription.rawValue
        case .selectionHeader, .autoFastest, .probe, .selectionInfo:
            return AorusUserVPNSettingsSection.selection.rawValue
        case .trafficHeader, .traffic, .expires:
            return AorusUserVPNSettingsSection.traffic.rawValue
        case .serversHeader, .server:
            return AorusUserVPNSettingsSection.servers.rawValue
        case .copyKey, .delete:
            return AorusUserVPNSettingsSection.danger.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .nameHeader:
            return 0
        case .name:
            return 1
        case .connectionHeader:
            return 10
        case .udp:
            return 11
        case .calls:
            return 12
        case .mux:
            return 13
        case .connectionInfo:
            return 14
        case .subscriptionHeader:
            return 20
        case .autoUpdate:
            return 21
        case .updateNow:
            return 22
        case .source:
            return 23
        case .subscriptionInfo:
            return 24
        case .selectionHeader:
            return 30
        case .autoFastest:
            return 31
        case .probe:
            return 32
        case .selectionInfo:
            return 33
        case .trafficHeader:
            return 40
        case .traffic:
            return 41
        case .expires:
            return 42
        case .serversHeader:
            return 50
        case let .server(_, index, _, _, _, _):
            return 1000 + index
        case .copyKey:
            return 100000
        case .delete:
            return 100001
        }
    }

    static func <(lhs: AorusUserVPNSettingsEntry, rhs: AorusUserVPNSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: AorusUserVPNSettingsEntry, rhs: AorusUserVPNSettingsEntry) -> Bool {
        switch lhs {
        case let .nameHeader(lt, ls):
            if case let .nameHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .name(lt, lp, lv):
            if case let .name(rt, rp, rv) = rhs { return lt === rt && lp == rp && lv == rv }
        case let .connectionHeader(lt, ls):
            if case let .connectionHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .udp(lt, ls, lv):
            if case let .udp(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .calls(lt, ls, lv):
            if case let .calls(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .mux(lt, ls, lv):
            if case let .mux(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .connectionInfo(lt, ls):
            if case let .connectionInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .subscriptionHeader(lt, ls):
            if case let .subscriptionHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .autoUpdate(lt, ls, lv):
            if case let .autoUpdate(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .updateNow(lt, ls, lv):
            if case let .updateNow(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .source(lt, ls, lv):
            if case let .source(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .subscriptionInfo(lt, ls):
            if case let .subscriptionInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .selectionHeader(lt, ls):
            if case let .selectionHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .autoFastest(lt, ls, lv):
            if case let .autoFastest(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .probe(lt, ls, lv):
            if case let .probe(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .selectionInfo(lt, ls):
            if case let .selectionInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .trafficHeader(lt, ls):
            if case let .trafficHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .traffic(lt, lu, lo):
            if case let .traffic(rt, ru, ro) = rhs { return lt === rt && lu == ru && lo == ro }
        case let .expires(lt, ls, lv):
            if case let .expires(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .serversHeader(lt, ls):
            if case let .serversHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .server(lt, li, lid, ln, ld, lc):
            if case let .server(rt, ri, rid, rn, rd, rc) = rhs { return lt === rt && li == ri && lid == rid && ln == rn && ld == rd && lc == rc }
        case let .copyKey(lt, ls):
            if case let .copyKey(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .delete(lt, ls):
            if case let .delete(rt, rs) = rhs { return lt === rt && ls == rs }
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! AorusUserVPNSettingsArguments
        switch self {
        case let .nameHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .name(_, placeholder, value):
            // 64 is the store's own cap, enforced here too so the field stops instead of silently
            // dropping what was typed past it.
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: ""), text: value, placeholder: placeholder, maxLength: 64, sectionId: self.section, textUpdated: { text in
                args.setName(text)
            }, action: {})
        case let .connectionHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .udp(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                args.setUdpEnabled(value)
            })
        case let .calls(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                args.setCallsEnabled(value)
            })
        case let .mux(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                args.setMuxEnabled(value)
            })
        case let .connectionInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .subscriptionHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .autoUpdate(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                args.setAutoUpdate(value)
            })
        case let .updateNow(_, title, enabled):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                if enabled {
                    args.updateNow()
                }
            })
        case let .source(_, title, url):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: url, labelStyle: .detailText, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                args.copySource()
            })
        case let .subscriptionInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .selectionHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .autoFastest(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                args.setAutoSelectFastest(value)
            })
        case let .probe(_, title, enabled):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                if enabled {
                    args.probeServers()
                }
            })
        case let .selectionInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .trafficHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .traffic(_, used, total):
            return AorusUserVPNTrafficItem(presentationData: presentationData, used: used, total: total, systemStyle: .legacy, sectionId: self.section)
        case let .expires(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {})
        case let .serversHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .server(_, _, serverId, name, detail, checked):
            return ItemListCheckboxItem(presentationData: presentationData, title: name, subtitle: detail, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                args.selectServer(serverId)
            }, deleteAction: {
                args.removeServer(serverId)
            })
        case let .copyKey(_, title):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                args.copyKey()
            })
        case let .delete(_, title):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                args.deleteConfig()
            })
        }
    }
}

private struct AorusUserVPNSettingsState: Equatable {
    /// What the name field shows. Held here rather than read back from the store so that clearing
    /// the field leaves an empty field and not a configuration with no name: the store keeps the
    /// last non-empty value, this keeps what was typed.
    var editingName: String?
}

private func aorusUserVPNSettingsEntries(
    config: AorusVlessConfig,
    state: AorusUserVPNSettingsState,
    section: AorusUserVPNSectionState,
    theme: PresentationTheme,
    l10n: AorusL10n
) -> [AorusUserVPNSettingsEntry] {
    var entries: [AorusUserVPNSettingsEntry] = []

    entries.append(.nameHeader(theme, l10n.userVPNNameHeader))
    entries.append(.name(theme, l10n.userVPNNamePlaceholder, state.editingName ?? config.name))

    entries.append(.connectionHeader(theme, l10n.userVPNConnectionHeader))
    entries.append(.udp(theme, l10n.userVPNUdp, config.udpEnabled))
    entries.append(.calls(theme, l10n.userVPNCalls, config.callsEnabled))
    entries.append(.mux(theme, l10n.userVPNMux, config.muxEnabled))
    entries.append(.connectionInfo(theme, l10n.userVPNConnectionFooter))

    let updating = section.updatingConfigIds.contains(config.id)
    if let url = config.subscriptionUrl, !url.isEmpty {
        entries.append(.subscriptionHeader(theme, l10n.userVPNSubscriptionHeader))
        entries.append(.autoUpdate(theme, l10n.userVPNAutoUpdate, config.autoUpdate))
        entries.append(.updateNow(theme, updating ? l10n.userVPNUpdating : l10n.userVPNUpdateNow, !updating))
        entries.append(.source(theme, l10n.userVPNSource, url))
        entries.append(.subscriptionInfo(theme, config.updatedAt > 0.0
            ? l10n.userVPNSubscriptionFooterUpdated(aorusUserVPNDateTimeText(config.updatedAt))
            : l10n.userVPNSubscriptionFooter))
    }

    let probing = config.servers.contains { section.probingServerIds.contains($0.id) }
    entries.append(.selectionHeader(theme, l10n.userVPNSelectionHeader))
    entries.append(.autoFastest(theme, l10n.userVPNAutoFastest, config.autoSelectFastest))
    entries.append(.probe(theme, probing ? l10n.userVPNProbingAction : l10n.userVPNCheckServers, !probing && !config.servers.isEmpty))
    entries.append(.selectionInfo(theme, l10n.userVPNSelectionFooter))

    // Only what the panel actually reported: an invented "0 B of unlimited" row would look like a
    // measurement of this client's own traffic, which this is not.
    if config.trafficUsed != nil || config.expiresAt != nil {
        entries.append(.trafficHeader(theme, l10n.userVPNTrafficHeader))
        if let used = config.trafficUsed {
            entries.append(.traffic(theme, used, config.trafficTotal))
        }
        if let expires = config.expiresAt, expires > 0.0 {
            entries.append(.expires(theme, l10n.userVPNExpiresTitle, aorusUserVPNDateText(expires)))
        }
    }

    if !config.servers.isEmpty {
        let bestServerId = aorusUserVPNBestMeasuredServerId(config: config, latencies: section.latencies)
        entries.append(.serversHeader(theme, l10n.userVPNServersHeader))
        for (index, server) in config.servers.enumerated() {
            entries.append(.server(
                theme,
                Int32(index),
                server.id,
                server.name,
                aorusUserVPNServerDetail(
                    server: server,
                    best: bestServerId == server.id,
                    latency: section.latencies[server.id],
                    probing: section.probingServerIds.contains(server.id),
                    connecting: section.connecting && section.selectedServerId == server.id,
                    l10n: l10n
                ),
                section.selectedServerId == server.id
            ))
        }
        entries.append(.copyKey(theme, l10n.userVPNCopyKey))
    }
    entries.append(.delete(theme, l10n.userVPNDeleteConfig))

    return entries
}

/// The configuration screen, pushed from the card on the Proxy screen.
public func aorusUserVPNSettingsController(context: AccountContext, configId: String) -> ViewController {
    let statePromise = ValuePromise(AorusUserVPNSettingsState(), ignoreRepeated: true)
    let stateValue = Atomic(value: AorusUserVPNSettingsState())
    let updateState: ((AorusUserVPNSettingsState) -> AorusUserVPNSettingsState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }

    var presentImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?

    let manager = AorusUserVPNManager.shared

    let pill: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentImpl?(aorusUserVPNPill(presentationData: presentationData, text: text, replacing: false))
    }

    /// The server a config-wide action means: the selected one when it belongs to this
    /// configuration, otherwise this configuration's first.
    let actionableServer: () -> AorusVlessServer? = {
        guard let config = AorusUserVPNStore.shared.config(id: configId) else {
            return nil
        }
        if let selected = AorusUserVPNStore.shared.selectedServerId,
           let server = config.servers.first(where: { $0.id == selected }) {
            return server
        }
        return config.servers.first
    }

    let arguments = AorusUserVPNSettingsArguments(
        context: context,
        setName: { text in
            updateState { current in
                var updated = current
                updated.editingName = text
                return updated
            }
            // Committed on every keystroke that leaves something behind, so leaving the screen --
            // by back button, by swipe, or by the app being killed -- needs no save step.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                manager.rename(configId: configId, name: trimmed)
            }
        },
        setUdpEnabled: { value in
            manager.setUdpEnabled(configId: configId, value: value)
        },
        setCallsEnabled: { value in
            manager.setCallsEnabled(configId: configId, value: value)
        },
        setMuxEnabled: { value in
            manager.setMuxEnabled(configId: configId, value: value)
        },
        setAutoUpdate: { value in
            manager.setAutoUpdate(configId: configId, value: value)
        },
        setAutoSelectFastest: { value in
            manager.setAutoSelectFastest(configId: configId, value: value)
        },
        updateNow: {
            let l10n = AorusL10n(context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode)
            manager.refreshSubscription(configId: configId) { error in
                if let error = error {
                    presentImpl?(aorusUserVPNAlert(
                        context: context,
                        title: l10n.userVPNImportFailed,
                        text: aorusUserVPNImportErrorText(error, l10n)
                    ))
                } else {
                    pill(l10n.userVPNUpdated)
                }
            }
        },
        copySource: {
            guard let url = AorusUserVPNStore.shared.config(id: configId)?.subscriptionUrl else {
                return
            }
            UIPasteboard.general.string = url
            let l10n = AorusL10n(context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode)
            pill(l10n.userVPNSourceCopied)
        },
        probeServers: {
            // A manual "check" is an explicit request to find and use the winner. The automatic
            // switch only controls future refreshes/network changes.
            manager.probeAllServers(configId: configId, selectFastest: true)
        },
        selectServer: { serverId in
            manager.selectServer(id: serverId)
        },
        removeServer: { serverId in
            manager.removeServer(configId: configId, serverId: serverId)
        },
        copyKey: {
            let l10n = AorusL10n(context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode)
            guard let server = actionableServer() else {
                return
            }
            UIPasteboard.general.string = server.link
            pill(l10n.userVPNKeyCopied)
        },
        deleteConfig: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let l10n = AorusL10n(presentationData.strings.baseLanguageCode)
            let name = AorusUserVPNStore.shared.config(id: configId)?.name ?? ""
            presentImpl?(textAlertController(
                context: context,
                title: l10n.userVPNDeleteConfig,
                text: l10n.userVPNDeleteConfirm(name),
                actions: [
                    TextAlertAction(type: .genericAction, title: aorusL("Отмена", "Cancel"), action: {}),
                    TextAlertAction(type: .destructiveAction, title: aorusL("Удалить", "Delete"), action: {
                        manager.removeConfig(id: configId)
                        dismissImpl?()
                    })
                ]
            ))
        }
    )

    let signal = combineLatest(
        queue: Queue.mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get(),
        aorusUserVPNSectionState()
    )
    |> map { presentationData, state, sectionState -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let l10n = AorusL10n(presentationData.strings.baseLanguageCode)
        let theme = presentationData.theme.aorusGlassListTheme
        let config = sectionState.configs.first(where: { $0.id == configId })
        // Deleted from under this screen -- from here, or from the swipe on the Proxy screen while
        // this one is still on the stack. There is nothing left to configure, so it leaves.
        if config == nil {
            Queue.mainQueue().async {
                dismissImpl?()
            }
        }
        let entries = config.flatMap { config -> [AorusUserVPNSettingsEntry] in
            aorusUserVPNSettingsEntries(config: config, state: state, section: sectionState, theme: theme, l10n: l10n)
        } ?? []
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(config?.name ?? l10n.userVPNSettingsTitle),
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
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    dismissImpl = { [weak controller] in
        guard let controller = controller else {
            return
        }
        // Pushed, so it pops. `dismiss()` on a pushed ItemListController would take the whole
        // navigation stack with it.
        if let navigationController = controller.navigationController as? NavigationController {
            let filtered = navigationController.viewControllers.filter { $0 !== controller }
            if filtered.count != navigationController.viewControllers.count {
                navigationController.setViewControllers(filtered, animated: true)
                return
            }
        }
        controller.dismiss()
    }
    return controller
}
