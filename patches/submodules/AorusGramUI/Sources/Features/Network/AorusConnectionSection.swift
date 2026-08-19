import Foundation
import UIKit
import SwiftSignalKit
import Display
import AsyncDisplayKit
import ComponentFlow
import ActivityIndicator
import TelegramCore
import TelegramPresentationData
import ItemListUI
import AccountContext
import TextFormat
import AorusGram

// The AorusGram block at the top of Telegram's own Proxy screen: the two switches that decide
// whether this client carries its own transport, and the status of the one that can be waiting.
//
// The rows live here rather than in the patched SettingsUI file for one reason: SettingsUI is
// compiled with -warnings-as-errors and every line added to a copied upstream file has to be
// re-verified against upstream on every rebase. Keeping the items, the state signal and the
// support-chat jump in this module leaves the patch itself down to the entries and their order.

public let aorusConnectionSupportUsername = "aorusgram_support"
private let aorusConnectionSupportUrl = "https://t.me/aorusgram_support"

/// What sits beside "Режим без VPN" while the route decision is being made or after it lands.
public enum AorusConnectionIndicator: Equatable {
    case none
    case connecting
    case connected
}

/// Everything the block draws, in one comparable value so the list can diff it.
public struct AorusConnectionSectionState: Equatable {
    public let bypassEnabled: Bool
    public let stableCallsEnabled: Bool
    public let routeEstablished: Bool

    public init(bypassEnabled: Bool, stableCallsEnabled: Bool, routeEstablished: Bool) {
        self.bypassEnabled = bypassEnabled
        self.stableCallsEnabled = stableCallsEnabled
        self.routeEstablished = routeEstablished
    }

    /// A switch that is off has no status at all: there is nothing being connected. On and not
    /// established covers both the direct probe and the endpoint race, which is right — from the
    /// row's point of view they are one wait, and it ends when traffic has a route.
    public var bypassIndicator: AorusConnectionIndicator {
        guard self.bypassEnabled else {
            return .none
        }
        return self.routeEstablished ? .connected : .connecting
    }
}

/// The block's state, re-emitted whenever a switch or the route changes.
///
/// Three sources: the switches themselves, the route decision, and the endpoint publication that
/// the diagnostics screen already listens for. The last one is not strictly needed — the route
/// posts its own change — but an endpoint arriving is the moment the wait ends, and reading the
/// route again there costs nothing and closes any gap between the two notifications.
public func aorusConnectionSectionState() -> Signal<AorusConnectionSectionState, NoError> {
    return Signal { subscriber in
        let emit: () -> Void = {
            subscriber.putNext(AorusConnectionSectionState(
                bypassEnabled: AorusConnectionPreferences.shared.bypassEnabled,
                stableCallsEnabled: AorusConnectionPreferences.shared.stableCallsEnabled,
                routeEstablished: AorusHybridRoute.shared.isRouteEstablished
            ))
        }
        emit()
        let center = NotificationCenter.default
        let observers: [NSObjectProtocol] = [
            center.addObserver(
                forName: AorusConnectionPreferences.didChangeNotification,
                object: nil, queue: OperationQueue.main, using: { _ in emit() }),
            center.addObserver(
                forName: AorusHybridRoute.didChangeNotification,
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

/// "Режим без VPN" was moved. The preference is the durable part; the forced re-evaluation is
/// what makes the row answer immediately instead of at the next network change.
///
/// The preference change alone would reach the route through its own observer, but that observer
/// is installed by the first evaluation — and on a client that never got as far as one, turning
/// the switch on would have set a stored flag and nothing else. Asking here is idempotent: an
/// evaluation already in flight is deduped, and with the switch off the first thing an
/// evaluation does is stand the tunnel down.
public func aorusConnectionSetBypassEnabled(_ value: Bool) {
    AorusConnectionPreferences.shared.setBypassEnabled(value)
    AorusHybridRoute.shared.evaluate(reason: "user_bypass_toggle", force: true)
}

/// "Стабильные звонки" was moved. Read at the start of every call by the call-proxy resolver, so
/// there is nothing to restart: the next call takes the new answer.
public func aorusConnectionSetStableCallsEnabled(_ value: Bool) {
    AorusConnectionPreferences.shared.setStableCallsEnabled(value)
}

/// One of the two switches, with the status beside its title and the caption under it.
public func aorusConnectionSwitchItem(
    presentationData: ItemListPresentationData,
    title: String,
    statusText: String?,
    indicator: AorusConnectionIndicator,
    value: Bool,
    sectionId: ItemListSectionId,
    updated: @escaping (Bool) -> Void
) -> ListViewItem {
    let theme = presentationData.theme
    var badge: AnyComponent<Empty>?
    switch indicator {
    case .none:
        badge = nil
    case .connecting:
        badge = AnyComponent(AorusConnectionStatusComponent(
            indicator: indicator,
            spinnerColor: theme.list.itemSecondaryTextColor,
            checkImage: nil
        ))
    case .connected:
        badge = AnyComponent(AorusConnectionStatusComponent(
            indicator: indicator,
            spinnerColor: theme.list.itemSecondaryTextColor,
            checkImage: PresentationResourcesItemList.checkIconImage(theme)
        ))
    }
    return ItemListSwitchItem(
        presentationData: presentationData,
        systemStyle: .glass,
        title: title,
        text: statusText,
        textColor: .primary,
        titleBadgeComponent: badge,
        value: value,
        sectionId: sectionId,
        style: .blocks,
        updated: updated
    )
}

/// The caption under the block, with "напишите в поддержку" as the only tappable part of it.
public func aorusConnectionFooterItem(
    presentationData: ItemListPresentationData,
    context: AccountContext,
    text: String,
    linkText: String,
    sectionId: ItemListSectionId,
    openSupport: @escaping () -> Void
) -> ListViewItem {
    let theme = presentationData.theme
    let font = Font.regular(presentationData.fontSize.itemListBaseHeaderFontSize)
    let string = NSMutableAttributedString(attributedString: NSAttributedString(
        string: text,
        font: font,
        textColor: theme.list.freeTextColor
    ))
    if let range = text.range(of: linkText) {
        let nsRange = NSRange(range, in: text)
        string.addAttribute(.foregroundColor, value: aorusConnectionLinkColor(theme: theme), range: nsRange)
        string.addAttribute(
            NSAttributedString.Key(rawValue: TelegramTextAttributes.URL),
            value: aorusConnectionSupportUrl,
            range: nsRange
        )
    }
    // .custom rather than .markdown: markdown paints its links with list.itemAccentColor, and
    // under Interface 2.0 that colour is the page's own ink. The link would then be the same
    // white as the sentence it sits in — legible, and no longer readable as a link.
    return ItemListTextItem(
        presentationData: presentationData,
        text: .custom(context: context, string: string),
        sectionId: sectionId,
        linkAction: { action in
            if case .tap = action {
                openSupport()
            }
        }
    )
}

/// Open the support chat the way the official channel opens from AorusGram's own settings:
/// resolve the username through the engine and push a real chat, not a browser.
public func aorusOpenConnectionSupportChat(context: AccountContext, navigationController: NavigationController?) {
    guard let navigationController = navigationController else {
        context.sharedContext.applicationBindings.openUrl(aorusConnectionSupportUrl)
        return
    }
    let _ = (context.engine.peers.resolvePeerByName(name: aorusConnectionSupportUsername, referrer: nil)
    |> deliverOnMainQueue).start(next: { result in
        guard case let .result(peer) = result, let peer = peer else {
            return
        }
        context.sharedContext.navigateToChatController(NavigateToChatControllerParams(
            navigationController: navigationController,
            context: context,
            chatLocation: .peer(peer)
        ))
    })
}

private func aorusConnectionLinkColor(theme: PresentationTheme) -> UIColor {
    let accent = theme.list.itemAccentColor
    // Interface 2.0 makes the list accent the page's ink — pure white on a dark pane, pure black
    // on a pale one. Both are answered from the colour itself rather than from the flag, because
    // the flag is read in another module and the colour is what actually gets drawn.
    if accent.isEqual(UIColor(white: 1.0, alpha: 1.0)) || accent.isEqual(UIColor(white: 0.0, alpha: 1.0)) {
        return theme.overallDarkAppearance ? UIColor(rgb: 0x2ea6ff) : UIColor(rgb: 0x007aff)
    }
    return accent
}

private let aorusConnectionStatusSize = CGSize(width: 22.0, height: 22.0)

/// The glyph beside "Режим без VPN": Telegram's own spinner while a route is being found, its own
/// list checkmark once one is carrying traffic.
///
/// ItemListSwitchItem takes its badge as an AnyComponent and lays it out next to the title, which
/// is the only slot in a switch row that is not the switch. Nothing here is drawn by hand — the
/// spinner is the same ActivityIndicator the proxy list uses for a server it is dialling, and the
/// checkmark is the same image it marks the active one with.
private final class AorusConnectionStatusComponent: Component {
    let indicator: AorusConnectionIndicator
    let spinnerColor: UIColor
    let checkImage: UIImage?

    init(indicator: AorusConnectionIndicator, spinnerColor: UIColor, checkImage: UIImage?) {
        self.indicator = indicator
        self.spinnerColor = spinnerColor
        self.checkImage = checkImage
    }

    static func == (lhs: AorusConnectionStatusComponent, rhs: AorusConnectionStatusComponent) -> Bool {
        return lhs.indicator == rhs.indicator
            && lhs.spinnerColor.isEqual(rhs.spinnerColor)
            && lhs.checkImage === rhs.checkImage
    }

    final class View: UIView {
        private var activityIndicator: ActivityIndicator?
        private var checkView: UIImageView?

        override init(frame: CGRect) {
            super.init(frame: frame)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func update(indicator: AorusConnectionIndicator, spinnerColor: UIColor, checkImage: UIImage?) -> CGSize {
            switch indicator {
            case .connecting:
                if let checkView = self.checkView {
                    self.checkView = nil
                    checkView.removeFromSuperview()
                }
                let activityIndicator: ActivityIndicator
                if let current = self.activityIndicator {
                    activityIndicator = current
                    activityIndicator.type = .custom(spinnerColor, aorusConnectionStatusSize.width, 2.0, false)
                } else {
                    activityIndicator = ActivityIndicator(
                        type: .custom(spinnerColor, aorusConnectionStatusSize.width, 2.0, false))
                    self.activityIndicator = activityIndicator
                    self.addSubview(activityIndicator.view)
                }
                activityIndicator.frame = CGRect(origin: CGPoint(), size: aorusConnectionStatusSize)
                return aorusConnectionStatusSize
            case .connected:
                if let activityIndicator = self.activityIndicator {
                    self.activityIndicator = nil
                    activityIndicator.view.removeFromSuperview()
                }
                guard let checkImage = checkImage else {
                    self.checkView?.removeFromSuperview()
                    self.checkView = nil
                    return CGSize()
                }
                let checkView: UIImageView
                if let current = self.checkView {
                    checkView = current
                } else {
                    checkView = UIImageView()
                    self.checkView = checkView
                    self.addSubview(checkView)
                }
                checkView.image = checkImage
                checkView.frame = CGRect(origin: CGPoint(), size: checkImage.size)
                return checkImage.size
            case .none:
                if let activityIndicator = self.activityIndicator {
                    self.activityIndicator = nil
                    activityIndicator.view.removeFromSuperview()
                }
                if let checkView = self.checkView {
                    self.checkView = nil
                    checkView.removeFromSuperview()
                }
                return CGSize()
            }
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(
        view: View,
        availableSize: CGSize,
        state: EmptyComponentState,
        environment: Environment<Empty>,
        transition: ComponentTransition
    ) -> CGSize {
        return view.update(
            indicator: self.indicator,
            spinnerColor: self.spinnerColor,
            checkImage: self.checkImage
        )
    }
}
