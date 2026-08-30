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

/// The AorusAI design tokens.
///
/// AorusAI is one screen family with one visual language, so its surfaces are resolved
/// here instead of being read off `theme.list` at every call site: the list, the thread,
/// the dictation overlay and the message-action sheet then agree on every radius and
/// every shade, and a change lands in one place.
///
/// The values are the design's own, converted from its OKLCH source to sRGB. Only the
/// appearance is taken from Telegram — a light theme gets the same layout with the light
/// surfaces below, so the screens never come out as a dark island inside a light app.
struct AorusAIPalette {
    var isDark: Bool
    /// Page background.
    var background: UIColor
    /// Cards, grouped rows, the composer, the sheet.
    var elevated: UIColor
    /// Quotes, chips, the search field.
    var fill: UIColor
    /// The user's own bubble.
    var fillStrong: UIColor
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
        if theme.overallDarkAppearance {
            let accent = UIColor(rgb: 0x9B79EE)
            return AorusAIPalette(
                isDark: true,
                background: UIColor(rgb: 0x0E0E12),
                elevated: UIColor(rgb: 0x19191E),
                fill: UIColor(rgb: 0x222229),
                fillStrong: UIColor(rgb: 0x30303A),
                separator: UIColor(rgb: 0x4C4C55, alpha: 0.6),
                label: UIColor(rgb: 0xF4F4F7),
                secondary: UIColor(rgb: 0xA8A8B1),
                tertiary: UIColor(rgb: 0x7B7B84),
                accent: accent,
                accentSoft: accent.withAlphaComponent(0.16),
                onAccent: UIColor(rgb: 0xFFFFFF)
            )
        }
        // The light counterpart keeps the same roles and the same contrast steps; the
        // violet is darkened so 15pt text on white stays readable.
        let accent = UIColor(rgb: 0x6F45D8)
        return AorusAIPalette(
            isDark: false,
            background: UIColor(rgb: 0xF3F2F7),
            elevated: UIColor(rgb: 0xFFFFFF),
            fill: UIColor(rgb: 0xEFEEF4),
            fillStrong: UIColor(rgb: 0xE3E2EA),
            separator: UIColor(rgb: 0xC6C6CE, alpha: 0.85),
            label: UIColor(rgb: 0x0D0D12),
            secondary: UIColor(rgb: 0x63636E),
            tertiary: UIColor(rgb: 0x8E8E98),
            accent: accent,
            accentSoft: accent.withAlphaComponent(0.12),
            onAccent: UIColor(rgb: 0xFFFFFF)
        )
    }
}

/// Shared material recipe for every AorusAI surface. A blur view with an opaque grey
/// `backgroundColor` is visually just a grey card, so tint and border stay translucent
/// and the material remains visible over Telegram's live content.
func aorusAIGlassEffect(palette: AorusAIPalette) -> UIBlurEffect {
    return UIBlurEffect(style: palette.isDark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight)
}

func aorusAIGlassTint(palette: AorusAIPalette, strong: Bool = false) -> UIColor {
    if palette.isDark {
        return UIColor.white.withAlphaComponent(strong ? 0.085 : 0.045)
    } else {
        return UIColor.white.withAlphaComponent(strong ? 0.42 : 0.28)
    }
}

func aorusAIGlassBorder(palette: AorusAIPalette) -> UIColor {
    return palette.isDark
        ? UIColor.white.withAlphaComponent(0.16)
        : UIColor.black.withAlphaComponent(0.10)
}

/// Headings are set in the system serif (New York), the way the design draws them.
///
/// `withDesign` returns nil on a descriptor that has no serif counterpart, and the
/// fallback is the plain system face rather than a crash or an unstyled default.
func aorusAISerifFont(size: CGFloat, weight: UIFont.Weight = .semibold) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: weight)
    if let descriptor = base.fontDescriptor.withDesign(.serif) {
        return UIFont(descriptor: descriptor, size: size)
    }
    return base
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
/// Grouped tables give a fixed 10pt corner; the design asks for 16–18 with a hairline
/// border, so the material is drawn per row and masked by position. Adjacent rows share
/// the same translucent recipe and read as one continuous glass group.
final class AorusAIGroupBackgroundView: UIView {
    private let materialView = UIVisualEffectView()
    private let tintView = UIView()
    private let separator = UIView()
    private let border = CAShapeLayer()
    private var position: AorusAIGroupPosition = .single
    private var radius: CGFloat = 16.0
    private var separatorInset: CGFloat = 16.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.cornerCurve = .continuous
        self.clipsToBounds = true
        materialView.isUserInteractionEnabled = false
        tintView.isUserInteractionEnabled = false
        self.addSubview(materialView)
        materialView.contentView.addSubview(tintView)
        // The card is one card per row, so a plain layer border would draw a line
        // where two rows meet. The stroke is a path over the outer edges only.
        border.fillColor = nil
        border.lineWidth = UIScreenPixel
        self.layer.addSublayer(border)
        self.addSubview(separator)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `fill` overrides the surface for a card that sits *on* an elevated surface — the
    /// row groups inside the sheet, which the design draws in the page background so they
    /// read as inset panels instead of merging with the sheet.
    func configure(palette: AorusAIPalette, position: AorusAIGroupPosition, radius: CGFloat, separatorInset: CGFloat, fill: UIColor? = nil) {
        self.backgroundColor = .clear
        materialView.effect = aorusAIGlassEffect(palette: palette)
        // An override is still translucent: callers can make an inset group quieter
        // without turning the material back into an opaque painted rectangle.
        tintView.backgroundColor = fill?.withAlphaComponent(palette.isDark ? 0.18 : 0.30)
            ?? aorusAIGlassTint(palette: palette)
        self.position = position
        self.radius = radius
        self.separatorInset = separatorInset
        self.layer.cornerRadius = radius
        self.layer.maskedCorners = position.maskedCorners
        border.strokeColor = aorusAIGlassBorder(palette: palette).cgColor
        separator.backgroundColor = aorusAIGlassBorder(palette: palette)
        separator.isHidden = !position.drawsSeparator
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        materialView.frame = bounds
        tintView.frame = materialView.bounds
        separator.frame = CGRect(x: separatorInset, y: bounds.height - UIScreenPixel, width: max(0.0, bounds.width - separatorInset), height: UIScreenPixel)
        border.frame = bounds
        let inset = UIScreenPixel / 2.0
        let rect = bounds.insetBy(dx: inset, dy: 0.0)
        let path = UIBezierPath()
        switch position {
        case .single:
            border.path = UIBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerRadius: radius).cgPath
            return
        case .first:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addArc(withCenter: CGPoint(x: rect.minX + radius, y: rect.minY + inset + radius), radius: radius, startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY + inset))
            path.addArc(withCenter: CGPoint(x: rect.maxX - radius, y: rect.minY + inset + radius), radius: radius, startAngle: .pi * 1.5, endAngle: 0.0, clockwise: true)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .middle:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .last:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - inset - radius))
            path.addArc(withCenter: CGPoint(x: rect.minX + radius, y: rect.maxY - inset - radius), radius: radius, startAngle: .pi, endAngle: .pi * 0.5, clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY - inset))
            path.addArc(withCenter: CGPoint(x: rect.maxX - radius, y: rect.maxY - inset - radius), radius: radius, startAngle: .pi * 0.5, endAngle: 0.0, clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        border.path = path.cgPath
    }
}
