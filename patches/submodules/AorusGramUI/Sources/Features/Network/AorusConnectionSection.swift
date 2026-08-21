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
    /// The hybrid layer measured a working direct route, so the tunnel is not needed and is not
    /// running. Nothing was turned off — the switch stays on and the tunnel comes up by itself the
    /// moment direct stops working, which is why this reads as paused rather than as disconnected.
    case suspended
}

/// Everything the block draws, in one comparable value so the list can diff it.
public struct AorusConnectionSectionState: Equatable {
    public let bypassEnabled: Bool
    public let stableCallsEnabled: Bool
    public let routeMode: AorusRouteMode

    public init(bypassEnabled: Bool, stableCallsEnabled: Bool, routeMode: AorusRouteMode) {
        self.bypassEnabled = bypassEnabled
        self.stableCallsEnabled = stableCallsEnabled
        self.routeMode = routeMode
    }

    /// A switch that is off has no status at all: there is nothing being connected. On, the row
    /// reports which of the three things the hybrid layer settled on.
    public var bypassIndicator: AorusConnectionIndicator {
        guard self.bypassEnabled else {
            return .none
        }
        switch self.routeMode {
        case .tunnel:
            return .connected
        case .direct:
            // Telegram reaches its datacentres unaided. Carrying it through the tunnel anyway
            // would be a second one, so the layer stood the tunnel down on purpose.
            return .suspended
        case .unknown, .escalating, .unavailable:
            // The direct probe, the endpoint race and a ladder that ran out are one wait from the
            // row's point of view, and it ends when traffic has a route.
            return .connecting
        }
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
                routeMode: AorusHybridRoute.shared.mode
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
    // The other half of the exclusion, before the switch itself moves: two tunnels for one client
    // is one too many, and the user's own VPN is the one that yields to the hybrid layer because
    // this switch is what they just touched. Turning the user's lane off first means the two are
    // never both live, not even for the length of a notification hop.
    if value {
        AorusUserVPNManager.shared.bypassDidTurnOn()
    }
    AorusConnectionPreferences.shared.setBypassEnabled(value)
    AorusHybridRoute.shared.evaluate(reason: "user_bypass_toggle", force: true)
}

/// "Стабильные звонки" was moved. Read at the start of every call by the call-proxy resolver, so
/// there is nothing to restart: the next call takes the new answer.
public func aorusConnectionSetStableCallsEnabled(_ value: Bool) {
    AorusConnectionPreferences.shared.setStableCallsEnabled(value)
}

/// One of the two switches, with the status glyph in the leading gutter and the status word under
/// the title.
///
/// The glyph goes in the gutter rather than beside the title because that is the only slot that can
/// be aligned with the title itself: a badge is centred on the whole row, which with a status line
/// under the title puts it half a line low. `aorusIconAlignsWithTitle` is AorusGram's own defaulted
/// parameter on the upstream item, and it centres the gutter glyph on the title.
///
/// Every row in the block passes an icon, `.none` included — the gutter is what sets the row's text
/// inset, so reserving it in every state is what keeps the two titles lined up with each other
/// while the status above them comes and goes.
public func aorusConnectionSwitchItem(
    presentationData: ItemListPresentationData,
    title: String,
    statusText: String?,
    indicator: AorusConnectionIndicator,
    value: Bool,
    sectionId: ItemListSectionId,
    enabled: Bool = true,
    activatedWhileDisabled: @escaping () -> Void = {},
    updated: @escaping (Bool) -> Void
) -> ListViewItem {
    return ItemListSwitchItem(
        presentationData: presentationData,
        systemStyle: .glass,
        icon: aorusConnectionIndicatorIcon(theme: presentationData.theme, indicator: indicator),
        aorusIconAlignsWithTitle: true,
        aorusIconSpins: indicator == .connecting,
        title: title,
        text: statusText,
        textColor: .primary,
        value: value,
        enabled: enabled,
        sectionId: sectionId,
        style: .blocks,
        updated: updated,
        activatedWhileDisabled: activatedWhileDisabled
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

func aorusConnectionLinkColor(theme: PresentationTheme) -> UIColor {
    let accent = theme.list.itemAccentColor
    // Interface 2.0 makes the list accent the page's ink — pure white on a dark pane, pure black
    // on a pale one. Both are answered from the colour itself rather than from the flag, because
    // the flag is read in another module and the colour is what actually gets drawn.
    if accent.isEqual(UIColor(white: 1.0, alpha: 1.0)) || accent.isEqual(UIColor(white: 0.0, alpha: 1.0)) {
        return theme.overallDarkAppearance ? UIColor(rgb: 0x2ea6ff) : UIColor(rgb: 0x007aff)
    }
    return accent
}

/// Sized from Telegram's own indefinite activity indicator, which is 22 points across with a 2 point
/// stroke -- one step down, which is what fits on a list row's title line. All three states share
/// the box and the stroke so they read as one control rather than three unrelated marks, and none of
/// them is a 12-point selection tick any more: this is the row's status, and at 12 points it was
/// half the height of the word beside it.
private let aorusConnectionGlyphSize = CGSize(width: 20.0, height: 20.0)
private let aorusConnectionGlyphLineWidth: CGFloat = 2.0

/// Keys into the theme's own image cache, which is a dictionary and is taken under a lock, so the
/// async list layout can generate and read these from any queue. The values are well past anything
/// PresentationResourceKey can hold: it counts up from zero, case by case.
private let aorusConnectionSpinnerIconKey: Int32 = 0x41475001
private let aorusConnectionCrossIconKey: Int32 = 0x41475002
private let aorusConnectionCheckIconKey: Int32 = 0x41475003

/// An empty gutter, so that a row with no status keeps the same text inset as one that has it.
private let aorusConnectionEmptyGlyph: UIImage? = generateImage(
    aorusConnectionGlyphSize,
    rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
    }
)

/// The glyph in the row's leading gutter: Telegram's own list checkmark once a route is carrying
/// traffic, its own indefinite spinner while one is being found, and a cross while the tunnel is
/// deliberately down.
///
/// Every one of them is drawn here into a bitmap rather than asked of UIKit. `ItemListSwitchItem`
/// keeps its icon in an `ASImageNode` with `isLayerBacked = true`, so the image ends up as a layer's
/// `contents`; an SF Symbol tinted with `withTintColor(_, renderingMode: .alwaysOriginal)` is only
/// coloured when UIKit draws it into a view, and on the layer path it arrives untinted and renders
/// **black**. Drawn pixels have their colour in them already.
///
/// All three are in the secondary text colour, the checkmark included -- this is a status, not a
/// selection, and under Interface 2.0 the list accent is the pane's own ink, which would draw the
/// checkmark in the same white as the title beside it.
private func aorusConnectionIndicatorIcon(
    theme: PresentationTheme,
    indicator: AorusConnectionIndicator
) -> UIImage? {
    switch indicator {
    case .none:
        return aorusConnectionEmptyGlyph
    case .connecting:
        return theme.image(aorusConnectionSpinnerIconKey, { theme in
            return generateImage(aorusConnectionGlyphSize, rotatedContext: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                context.setStrokeColor(theme.list.itemSecondaryTextColor.cgColor)
                context.setLineWidth(aorusConnectionGlyphLineWidth)
                context.setLineCap(.round)
                // Telegram's own indefinite indicator to the degree: a ring with a 30 degree bite
                // taken out of it. The turning is the switch row's job -- see `aorusIconSpins`.
                let cutoutAngle: CGFloat = CGFloat.pi * 30.0 / 180.0
                context.addArc(
                    center: CGPoint(x: size.width / 2.0, y: size.height / 2.0),
                    radius: size.width / 2.0 - aorusConnectionGlyphLineWidth / 2.0,
                    startAngle: 0.0,
                    endAngle: CGFloat.pi * 2.0 - cutoutAngle,
                    clockwise: false
                )
                context.strokePath()
            })
        })
    case .connected:
        return theme.image(aorusConnectionCheckIconKey, { theme in
            return generateImage(aorusConnectionGlyphSize, rotatedContext: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                context.setStrokeColor(theme.list.itemSecondaryTextColor.cgColor)
                context.setLineWidth(aorusConnectionGlyphLineWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                // `generateItemListCheckIcon`'s own two segments, in its own 12 x 10 box, scaled up
                // into this one and centred: the tick keeps Telegram's proportions at the larger
                // size instead of being a different tick that merely sits in the same place.
                let scale: CGFloat = 1.35
                let originX = (size.width - 12.0 * scale) / 2.0
                let originY = (size.height - 10.0 * scale) / 2.0
                let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
                    return CGPoint(x: originX + x * scale, y: originY + y * scale)
                }
                context.move(to: point(0.215053763, 4.36080467))
                context.addLine(to: point(3.31621263, 7.70466293))
                context.addLine(to: point(9.89247312, 0.0))
                context.strokePath()
            })
        })
    case .suspended:
        return theme.image(aorusConnectionCrossIconKey, { theme in
            return generateImage(aorusConnectionGlyphSize, rotatedContext: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                context.setStrokeColor(theme.list.itemSecondaryTextColor.cgColor)
                context.setLineWidth(aorusConnectionGlyphLineWidth)
                context.setLineCap(.round)
                // Spanning the tick's width rather than the whole box, so the three glyphs carry
                // the same weight; the round caps end where that span does.
                let inset = (size.width - 12.0 * 1.35) / 2.0 + aorusConnectionGlyphLineWidth / 2.0
                context.move(to: CGPoint(x: inset, y: inset))
                context.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset))
                context.move(to: CGPoint(x: size.width - inset, y: inset))
                context.addLine(to: CGPoint(x: inset, y: size.height - inset))
                context.strokePath()
            })
        })
    }
}
