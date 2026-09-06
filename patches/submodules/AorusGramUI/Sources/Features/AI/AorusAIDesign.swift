import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import SwiftSignalKit
import AorusGram
import AppBundle
import LocalizedPeerData

/// The AorusAI surface colours.
///
/// Every one of them is derived from the Telegram theme the user is actually running.
/// An earlier revision carried its own palette — a fixed violet accent on a fixed near
/// black page — and the result was a screen that belonged to a different application:
/// its accent disagreed with every other button in the app, and someone on a light theme,
/// or on one of the custom themes Telegram ships, opened AorusAI into a colour scheme
/// they had never chosen.
///
/// So there are no literal colours here at all. The accent is `itemAccentColor`, which is
/// the blue of a stock theme and whatever the user picked otherwise; the page and the
/// cards are the same two surfaces every grouped list in Telegram is built from; and the
/// fills are the label colour at a low alpha, which is how the system's own secondary
/// fills are defined and is therefore correct in a theme nobody has written yet.
struct AorusAIPalette {
    var isDark: Bool
    /// Page background for a screen made of cards — the conversation list.
    var background: UIColor
    /// Page background for a screen that is a run of content, not a grouped table — the
    /// message thread. Telegram's plain background, so the thread is white or black rather
    /// than the grey a grouped list sits on.
    var plainBackground: UIColor
    /// Cards, grouped rows, the composer, the sheet.
    var elevated: UIColor
    /// Quotes, chips, the search field.
    var fill: UIColor
    /// A bare control's own surface — **opaque**.
    ///
    /// `fill` is a low alpha because almost everywhere it is used, the contrast comes from
    /// what is drawn on top of it: a row carrying a figure, a title, a note and a hairline
    /// reads as a panel at a tenth of the label colour. A button is nothing but its surface
    /// and one line of text in the same colour as the rest of the card, and at that alpha
    /// it does not read as a button at all — the title looks like a centred caption.
    ///
    /// Raising the alpha was not enough, so this is not an alpha. It is the ink already
    /// mixed into the card colour and handed over at full opacity, which is how the system
    /// defines its own grouped surfaces: `secondarySystemGroupedBackground` is a colour,
    /// not a wash. A translucent fill also has no defined result over a card that is itself
    /// translucent — under Interface 2.0 the card colour is a near-invisible marker — and
    /// mixing first removes that question entirely.
    var controlFill: UIColor
    /// The same surface under a finger, mixed the same way and also opaque.
    var controlFillHighlighted: UIColor
    var separator: UIColor
    var label: UIColor
    var secondary: UIColor
    var tertiary: UIColor
    var accent: UIColor
    /// The accent at low opacity: icon tiles and the dictation halo.
    var accentSoft: UIColor
    /// Text and glyphs drawn on top of `accent`.
    var onAccent: UIColor

    static func resolve(_ theme: PresentationTheme) -> AorusAIPalette {
        let list = theme.list
        let isDark = theme.overallDarkAppearance
        let label = list.itemPrimaryTextColor
        // The card colour has to be opaque, and `itemBlocksBackgroundColor` is not always
        // one. Interface 2.0 replaces it with a marker at 1/255 alpha — the settings lists
        // read that marker back to find their cards and draw a pane of real glass behind
        // each one. Nothing draws glass behind these surfaces, so taking the marker at face
        // value left every AorusAI card invisible: the share sheet's card vanished, and the
        // translucent things standing on it — the row panel, the "Don't share" button —
        // showed the composer straight through them.
        //
        // `actionSheet.opaqueItemBackgroundColor` is the theme's own answer to "an opaque
        // panel over content", which is exactly what these are, and Interface 2.0 leaves it
        // alone. On every ordinary theme the block colour is already opaque and this is not
        // reached, so nothing about them changes.
        let elevated = AorusAIPalette.opaque(list.itemBlocksBackgroundColor, fallback: theme.actionSheet.opaqueItemBackgroundColor)
        return AorusAIPalette(
            isDark: isDark,
            background: list.blocksBackgroundColor,
            plainBackground: list.plainBackgroundColor,
            elevated: elevated,
            // The system defines its secondary fills as the label colour at a low alpha
            // rather than as colours of their own, which is what makes them land correctly
            // on any background. Same here, so a custom theme gets a fill that belongs to
            // it instead of a grey borrowed from the stock one.
            fill: label.withAlphaComponent(isDark ? 0.10 : 0.055),
            // The same shade as `fill`, resolved to an opaque colour instead of a wash.
            //
            // A sheet's button belongs to the panel of rows above it — they are one set of
            // choices — so it is that surface, not a lighter one competing with it. The
            // earlier attempt at "make the button visible" raised the ink instead and
            // produced a plate that read as a different, louder control.
            //
            // Mixing rather than layering is what was actually needed: a wash has no
            // defined result over a card that is itself translucent, which is what made the
            // button transparent in the first place. At the same ink it is the same colour
            // the rows are, and it is a colour rather than a film.
            controlFill: AorusAIPalette.mix(label, into: elevated, amount: isDark ? 0.10 : 0.055),
            // What a row looks like under a finger: those draw `fill` over themselves a
            // second time, so this is that composition resolved — 1-(1-a)² of the same ink.
            controlFillHighlighted: AorusAIPalette.mix(label, into: elevated, amount: isDark ? 0.19 : 0.107),
            separator: list.itemBlocksSeparatorColor,
            label: label,
            secondary: list.itemSecondaryTextColor,
            tertiary: list.itemPlaceholderTextColor,
            accent: list.itemAccentColor,
            accentSoft: list.itemAccentColor.withAlphaComponent(isDark ? 0.18 : 0.12),
            // Telegram draws white on its accent everywhere — the compose button, the
            // selected check, the badge — so an answer sheet here does the same.
            onAccent: UIColor.white
        )
    }

    /// `color` if it is opaque, `fallback` if it is not.
    ///
    /// "Not quite opaque" is treated as not opaque: the marker this exists for sits at
    /// 1/255, and there is no legitimate card colour between that and solid.
    static func opaque(_ color: UIColor, fallback: UIColor) -> UIColor {
        return color.cgColor.alpha >= 0.99 ? color : fallback
    }

    /// `ink` mixed into `base` by `amount`, returned at full opacity.
    ///
    /// The point of mixing rather than layering is that the answer is a colour: it does not
    /// depend on what happens to be painted underneath, and it cannot be "transparent"
    /// however the surrounding surfaces are drawn. Mixing into the card's own shade is also
    /// what keeps the result a member of the user's theme rather than a grey chosen here.
    ///
    /// A colour that cannot be read as RGB — a pattern colour, which no theme uses for
    /// these two — falls back to the ink at that alpha, which is what this used to be.
    static func mix(_ ink: UIColor, into base: UIColor, amount: CGFloat) -> UIColor {
        var inkRed: CGFloat = 0.0, inkGreen: CGFloat = 0.0, inkBlue: CGFloat = 0.0, inkAlpha: CGFloat = 0.0
        var baseRed: CGFloat = 0.0, baseGreen: CGFloat = 0.0, baseBlue: CGFloat = 0.0, baseAlpha: CGFloat = 0.0
        guard ink.getRed(&inkRed, green: &inkGreen, blue: &inkBlue, alpha: &inkAlpha),
              base.getRed(&baseRed, green: &baseGreen, blue: &baseBlue, alpha: &baseAlpha) else {
            return ink.withAlphaComponent(amount)
        }
        let weight = max(0.0, min(1.0, amount))
        return UIColor(
            red: inkRed * weight + baseRed * (1.0 - weight),
            green: inkGreen * weight + baseGreen * (1.0 - weight),
            blue: inkBlue * weight + baseBlue * (1.0 - weight),
            alpha: 1.0
        )
    }
}

/// The hairline around a floating surface — the theme's own list separator, so it is the
/// same line thickness and shade as every divider elsewhere in the app.
func aorusAIGlassBorder(palette: AorusAIPalette) -> UIColor {
    return palette.separator
}

/// Headings and titles.
///
/// The system text face, at the weights Telegram itself uses. An earlier revision set
/// every heading in New York, the system serif, which is a handsome face and belongs to
/// no other screen in this application.
func aorusAITitleFont(size: CGFloat, weight: UIFont.Weight = .semibold) -> UIFont {
    return UIFont.systemFont(ofSize: size, weight: weight)
}

/// A monospaced digit face for the dictation timer, so the elapsed time does not
/// jitter horizontally while it counts.
func aorusAIMonoFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
    return UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
}

/// Where a row sits inside a grouped card, which corners it rounds.
enum AorusAIGroupPosition {
    case single
    case first
    case middle
    case last

    static func of(index: Int, count: Int) -> AorusAIGroupPosition {
        if count <= 1 { return .single }
        if index == 0 { return .first }
        if index == count - 1 { return .last }
        return .middle
    }

    var maskedCorners: CACornerMask {
        switch self {
        case .single:
            return [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .first:
            return [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        case .middle:
            return []
        case .last:
            return [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
    }

    var drawsSeparator: Bool {
        switch self {
        case .single, .last:
            return false
        case .first, .middle:
            return true
        }
    }
}

/// The rounded card behind a group of rows.
///
/// The same construction Telegram's own grouped lists use: one opaque surface, corners
/// rounded only where the group actually ends, and an inset hairline between adjacent
/// rows. It is drawn per row rather than per section because the rows live in a plain
/// table, so each one masks the corners its position calls for.
///
/// It used to be a blur with a tint and a stroked outline. Over an opaque page a blur has
/// nothing to sample but that page, so it cost a full-screen render pass to arrive at a
/// flat grey — and the outline was a line no grouped list in the app draws.
final class AorusAIGroupBackgroundView: UIView {
    private let separator = UIView()
    private var separatorInset: CGFloat = 16.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.cornerCurve = .continuous
        self.clipsToBounds = true
        self.addSubview(separator)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `fill` overrides the surface for a card that sits *on* an elevated surface — the
    /// row groups inside the sheet, which are drawn in the page background so they read as
    /// inset panels instead of merging with the sheet.
    func configure(palette: AorusAIPalette, position: AorusAIGroupPosition, radius: CGFloat, separatorInset: CGFloat, fill: UIColor? = nil) {
        self.backgroundColor = fill ?? palette.elevated
        self.separatorInset = separatorInset
        self.layer.cornerRadius = radius
        self.layer.maskedCorners = position.maskedCorners
        separator.backgroundColor = palette.separator
        separator.isHidden = !position.drawsSeparator
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        separator.frame = CGRect(
            x: separatorInset,
            y: bounds.height - UIScreenPixel,
            width: max(0.0, bounds.width - separatorInset),
            height: UIScreenPixel
        )
    }
}
