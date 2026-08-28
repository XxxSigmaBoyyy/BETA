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
/// border, so the card is drawn per row and masked by position. One view, no shadows,
/// no blur — the same recipe on both appearances.
final class AorusAIGroupBackgroundView: UIView {
    private let separator = UIView()
    private let border = CAShapeLayer()
    private var position: AorusAIGroupPosition = .single
    private var radius: CGFloat = 16.0
    private var separatorInset: CGFloat = 16.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.cornerCurve = .continuous
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
        self.backgroundColor = fill ?? palette.elevated
        self.position = position
        self.radius = radius
        self.separatorInset = separatorInset
        self.layer.cornerRadius = radius
        self.layer.maskedCorners = position.maskedCorners
        border.strokeColor = palette.separator.cgColor
        separator.backgroundColor = palette.separator
        separator.isHidden = !position.drawsSeparator
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
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

// MARK: - Message action sheet

/// One tappable row of the message action sheet.
struct AorusAIActionSheetRow {
    var id: String
    var title: String
    /// Native bundle asset, tinted with the accent inside its tile.
    var iconName: String?
    /// Right-aligned detail: the translation language, the number of tone variants,
    /// the number of messages a chat analysis would read.
    var hint: String?
    /// A row that opens another page of the sheet instead of running an action.
    var opensPage: Bool
}

/// A titled group of rows — the design's "Текст / Тон / Разобрать / Создать" tabs.
struct AorusAIActionSheetSection {
    var title: String?
    var rows: [AorusAIActionSheetRow]
}

/// One level of the sheet. Levels are pushed inside the sheet itself, never as a
/// second native context-menu container.
struct AorusAIActionSheetPage {
    var title: String
    var subtitle: String?
    var sections: [AorusAIActionSheetSection]
    /// The wide accent button pinned under the scrolling body, if this level has one.
    var footer: AorusAIActionSheetRow?
}

private enum AorusAIActionSheetMetrics {
    static let cardInset: CGFloat = 8.0
    static let cardRadius: CGFloat = 26.0
    static let cardMaxWidth: CGFloat = 460.0
    static let contentInset: CGFloat = 8.0
    static let groupRadius: CGFloat = 16.0
    static let rowHeight: CGFloat = 46.0
    static let sectionTitleHeight: CGFloat = 18.0
    static let sectionTitleGap: CGFloat = 6.0
    static let sectionSpacing: CGFloat = 14.0
    static let contentTop: CGFloat = 4.0
    static let contentBottom: CGFloat = 10.0
    static let footerHeight: CGFloat = 50.0
    static let footerTop: CGFloat = 12.0
    static let bodyMaxHeight: CGFloat = 540.0
}

private final class AorusAIActionSheetRowView: UIControl {
    let row: AorusAIActionSheetRow

    private let cardView = AorusAIGroupBackgroundView()
    private let highlightView = UIView()
    private let iconTile = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private let chevronView = UIImageView()

    init(row: AorusAIActionSheetRow, palette: AorusAIPalette, position: AorusAIGroupPosition) {
        self.row = row
        super.init(frame: .zero)

        cardView.configure(palette: palette, position: position, radius: AorusAIActionSheetMetrics.groupRadius, separatorInset: 54.0, fill: palette.background)
        cardView.isUserInteractionEnabled = false
        highlightView.backgroundColor = palette.fillStrong.withAlphaComponent(0.7)
        highlightView.alpha = 0.0
        highlightView.isUserInteractionEnabled = false

        iconTile.backgroundColor = palette.accentSoft
        iconTile.layer.cornerRadius = 9.0
        iconTile.layer.cornerCurve = .continuous
        iconView.contentMode = .center
        if let iconName = row.iconName {
            iconView.image = generateTintedImage(image: UIImage(bundleImageName: iconName), color: palette.accent)
        }
        iconTile.addSubview(iconView)

        titleLabel.text = row.title
        titleLabel.font = .systemFont(ofSize: 16.0, weight: .medium)
        titleLabel.textColor = palette.label
        titleLabel.lineBreakMode = .byTruncatingTail

        hintLabel.text = row.hint
        hintLabel.font = .systemFont(ofSize: 14.0)
        hintLabel.textColor = palette.tertiary
        hintLabel.textAlignment = .right

        chevronView.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold))?
            .withRenderingMode(.alwaysTemplate)
        chevronView.tintColor = palette.tertiary
        chevronView.isHidden = !row.opensPage
        chevronView.contentMode = .center

        for view in [cardView, highlightView, iconTile, titleLabel, hintLabel, chevronView] {
            addSubview(view)
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = row.title
        accessibilityValue = row.hint
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            UIView.animate(withDuration: isHighlighted ? 0.08 : 0.2) {
                self.highlightView.alpha = self.isHighlighted ? 1.0 : 0.0
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cardView.frame = bounds
        highlightView.frame = bounds
        highlightView.layer.cornerRadius = cardView.layer.cornerRadius
        highlightView.layer.cornerCurve = .continuous
        highlightView.layer.maskedCorners = cardView.layer.maskedCorners
        iconTile.frame = CGRect(x: 12.0, y: floor((bounds.height - 30.0) / 2.0), width: 30.0, height: 30.0)
        iconView.frame = iconTile.bounds
        let chevronWidth: CGFloat = row.opensPage ? 18.0 : 0.0
        chevronView.frame = CGRect(x: bounds.width - 12.0 - chevronWidth, y: 0.0, width: chevronWidth, height: bounds.height)
        let contentRight = bounds.width - 12.0 - chevronWidth
        var hintWidth: CGFloat = 0.0
        if let hint = row.hint, !hint.isEmpty {
            let hintFont = UIFont.systemFont(ofSize: 14.0)
            hintWidth = min(150.0, ceil(hint.size(withAttributes: [.font: hintFont]).width) + 1.0)
        }
        hintLabel.frame = CGRect(x: contentRight - hintWidth, y: 0.0, width: hintWidth, height: bounds.height)
        let titleLeft = iconTile.frame.maxX + 12.0
        titleLabel.frame = CGRect(x: titleLeft, y: 0.0, width: max(0.0, hintLabel.frame.minX - 8.0 - titleLeft), height: bounds.height)
    }
}

/// The scrolling body of one sheet level.
///
/// The body is the only thing that grows, and it scrolls: a level with sixteen rows is
/// exactly as tall as a level with two, up to the cap, so no row can ever land outside
/// the sheet.
private final class AorusAIActionSheetPageView: UIView {
    private let scrollView = UIScrollView()
    private var titleLabels: [UILabel] = []
    private var rowViews: [AorusAIActionSheetRowView] = []
    /// Row count per rendered section, in order — the layout walks this.
    private var groups: [Int] = []
    private let onSelect: (AorusAIActionSheetRow) -> Void

    init(page: AorusAIActionSheetPage, palette: AorusAIPalette, onSelect: @escaping (AorusAIActionSheetRow) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.indicatorStyle = palette.isDark ? .white : .black
        addSubview(scrollView)
        for section in page.sections where !section.rows.isEmpty {
            let label = UILabel()
            label.text = section.title
            label.font = .systemFont(ofSize: 13.0, weight: .medium)
            label.textColor = palette.tertiary
            label.isHidden = section.title == nil
            titleLabels.append(label)
            scrollView.addSubview(label)
            for (index, row) in section.rows.enumerated() {
                let view = AorusAIActionSheetRowView(
                    row: row,
                    palette: palette,
                    position: AorusAIGroupPosition.of(index: index, count: section.rows.count)
                )
                view.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
                rowViews.append(view)
                scrollView.addSubview(view)
            }
            groups.append(section.rows.count)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func rowTapped(_ sender: AorusAIActionSheetRowView) {
        onSelect(sender.row)
    }

    /// Height this level would take if nothing clipped it.
    var contentHeight: CGFloat {
        var height = AorusAIActionSheetMetrics.contentTop + AorusAIActionSheetMetrics.contentBottom
        for (index, group) in groups.enumerated() {
            if !titleLabels[index].isHidden {
                height += AorusAIActionSheetMetrics.sectionTitleHeight + AorusAIActionSheetMetrics.sectionTitleGap
            }
            height += CGFloat(group) * AorusAIActionSheetMetrics.rowHeight
            if index < groups.count - 1 {
                height += AorusAIActionSheetMetrics.sectionSpacing
            }
        }
        return height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let inset = AorusAIActionSheetMetrics.contentInset
        let width = max(0.0, bounds.width - inset * 2.0)
        var y = AorusAIActionSheetMetrics.contentTop
        var rowIndex = 0
        for (index, group) in groups.enumerated() {
            let label = titleLabels[index]
            if !label.isHidden {
                label.frame = CGRect(x: inset + 4.0, y: y, width: max(0.0, width - 8.0), height: AorusAIActionSheetMetrics.sectionTitleHeight)
                y += AorusAIActionSheetMetrics.sectionTitleHeight + AorusAIActionSheetMetrics.sectionTitleGap
            } else {
                label.frame = CGRect(x: inset, y: y, width: width, height: 0.0)
            }
            for _ in 0 ..< group {
                rowViews[rowIndex].frame = CGRect(x: inset, y: y, width: width, height: AorusAIActionSheetMetrics.rowHeight)
                y += AorusAIActionSheetMetrics.rowHeight
                rowIndex += 1
            }
            if index < groups.count - 1 {
                y += AorusAIActionSheetMetrics.sectionSpacing
            }
        }
        scrollView.contentSize = CGSize(width: bounds.width, height: y + AorusAIActionSheetMetrics.contentBottom)
    }
}

/// The AorusAI message-action sheet.
///
/// It replaces the pushed native context-menu level the row used to open. Telegram's
/// `ContextControllerActionsStackNode` only positions the top two containers of its
/// stack, so a menu deep enough to need scrolling — twenty-two actions in four titled
/// groups — could only be shown as one flat level, and its rows ran past the bottom of
/// the screen. A sheet of its own has a bounded height, a scrolling body and section
/// headers, so the groups are back and nothing can leave the frame.
final class AorusAIActionSheetController: UIViewController {
    private let palette: AorusAIPalette
    private let rootPage: AorusAIActionSheetPage
    private let pageForRow: (AorusAIActionSheetRow) -> AorusAIActionSheetPage?
    private let onSelect: (AorusAIActionSheetRow) -> Void

    private let dimView = UIView()
    private let card = UIView()
    private let headerView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let headerSeparator = UIView()
    private let closeButton = UIButton(type: .custom)
    private let backButton = UIButton(type: .custom)
    private let footerButton = UIButton(type: .custom)

    private var stack: [(page: AorusAIActionSheetPage, view: AorusAIActionSheetPageView)] = []
    private var didAnimateIn = false
    private var isClosing = false
    private var cardHeight: CGFloat = 0.0

    init(
        palette: AorusAIPalette,
        page: AorusAIActionSheetPage,
        pageForRow: @escaping (AorusAIActionSheetRow) -> AorusAIActionSheetPage?,
        onSelect: @escaping (AorusAIActionSheetRow) -> Void
    ) {
        self.palette = palette
        self.rootPage = page
        self.pageForRow = pageForRow
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .overFullScreen
        self.modalPresentationCapturesStatusBarAppearance = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
        dimView.alpha = 0.0
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeTapped)))
        view.addSubview(dimView)

        card.backgroundColor = palette.elevated
        card.layer.cornerRadius = AorusAIActionSheetMetrics.cardRadius
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = UIScreenPixel
        card.layer.borderColor = palette.separator.cgColor
        card.clipsToBounds = true
        // Offscreen from the very first frame: the controller is presented without a
        // UIKit transition so that the rise below is the only animation the user sees.
        card.transform = CGAffineTransform(translationX: 0.0, y: 1200.0)
        view.addSubview(card)

        headerView.backgroundColor = palette.elevated
        card.addSubview(headerView)
        titleLabel.font = .systemFont(ofSize: 17.0, weight: .semibold)
        titleLabel.textColor = palette.label
        subtitleLabel.font = .systemFont(ofSize: 13.0)
        subtitleLabel.textColor = palette.tertiary
        subtitleLabel.lineBreakMode = .byTruncatingTail
        headerSeparator.backgroundColor = palette.separator
        for subview in [titleLabel, subtitleLabel, headerSeparator] {
            headerView.addSubview(subview)
        }
        configure(circleButton: closeButton, systemName: "xmark", pointSize: 12.0, action: #selector(closeTapped))
        closeButton.accessibilityLabel = aorusAILocalized("Закрыть", "Close")
        configure(circleButton: backButton, systemName: "chevron.left", pointSize: 14.0, action: #selector(backTapped))
        backButton.accessibilityLabel = aorusAILocalized("Назад", "Back")
        backButton.isHidden = true

        footerButton.backgroundColor = palette.accent
        footerButton.setTitleColor(palette.onAccent, for: .normal)
        footerButton.titleLabel?.font = .systemFont(ofSize: 16.0, weight: .semibold)
        footerButton.layer.cornerRadius = AorusAIActionSheetMetrics.footerHeight / 2.0
        footerButton.layer.cornerCurve = .continuous
        footerButton.addTarget(self, action: #selector(footerTapped), for: .touchUpInside)
        card.addSubview(footerButton)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        // The header is the drag handle. A pan on the whole card would compete with the
        // body's own scrolling and the sheet would slide while the user scrolls it.
        headerView.addGestureRecognizer(pan)

        push(page: rootPage, animated: false)
    }

    private func configure(circleButton button: UIButton, systemName: String, pointSize: CGFloat, action: Selector) {
        button.backgroundColor = palette.fill
        button.layer.cornerRadius = 15.0
        button.setImage(
            UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        button.tintColor = palette.secondary
        button.addTarget(self, action: action, for: .touchUpInside)
        headerView.addSubview(button)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAnimateIn else { return }
        didAnimateIn = true
        card.transform = CGAffineTransform(translationX: 0.0, y: cardHeight)
        // The design's own sheet curve: a short, decelerating rise, no bounce.
        UIView.animate(withDuration: 0.34, delay: 0.0, options: [.curveEaseOut], animations: {
            self.dimView.alpha = 1.0
            self.card.transform = .identity
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        dimView.frame = view.bounds
        layoutCard(animated: false)
    }

    private var currentPage: AorusAIActionSheetPage? {
        return stack.last?.page
    }

    private func headerHeight(for page: AorusAIActionSheetPage) -> CGFloat {
        return (page.subtitle?.isEmpty == false) ? 70.0 : 54.0
    }

    private func footerBlockHeight(for page: AorusAIActionSheetPage) -> CGFloat {
        guard page.footer != nil else { return 0.0 }
        return AorusAIActionSheetMetrics.footerTop + AorusAIActionSheetMetrics.footerHeight + 10.0
    }

    private func layoutCard(animated: Bool) {
        guard let entry = stack.last else { return }
        let page = entry.page
        let bounds = view.bounds
        let safeInsets = view.safeAreaInsets
        let inset = AorusAIActionSheetMetrics.cardInset
        let width = min(bounds.width - inset * 2.0, AorusAIActionSheetMetrics.cardMaxWidth)
        let originX = floor((bounds.width - width) / 2.0)
        let bottomInset = max(safeInsets.bottom, inset)
        let header = headerHeight(for: page)
        let footerBlock = footerBlockHeight(for: page)
        // Everything above the body is fixed, so the body is what gets clamped: the
        // sheet can never be taller than the screen and its rows can never overflow.
        let available = bounds.height - safeInsets.top - 24.0 - bottomInset - header - footerBlock
        let bodyHeight = max(80.0, min(min(entry.view.contentHeight, AorusAIActionSheetMetrics.bodyMaxHeight), available))
        let height = header + bodyHeight + footerBlock
        cardHeight = height
        let cardFrame = CGRect(x: originX, y: bounds.height - bottomInset - height, width: width, height: height)
        let apply: () -> Void = {
            self.card.frame = cardFrame
            self.headerView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: header)
            self.layoutHeader(page: page, width: width, height: header)
            for (index, item) in self.stack.enumerated() {
                let offset = CGFloat(index - (self.stack.count - 1)) * width
                item.view.frame = CGRect(x: offset, y: header, width: width, height: bodyHeight)
                item.view.alpha = index == self.stack.count - 1 ? 1.0 : 0.0
            }
            self.footerButton.frame = CGRect(
                x: 12.0,
                y: header + bodyHeight + AorusAIActionSheetMetrics.footerTop,
                width: max(0.0, width - 24.0),
                height: AorusAIActionSheetMetrics.footerHeight
            )
        }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0.0, options: [.curveEaseInOut], animations: apply)
        } else {
            apply()
        }
    }

    private func layoutHeader(page: AorusAIActionSheetPage, width: CGFloat, height: CGFloat) {
        let hasBack = stack.count > 1
        backButton.isHidden = !hasBack
        backButton.frame = CGRect(x: 12.0, y: floor((height - 30.0) / 2.0), width: 30.0, height: 30.0)
        closeButton.frame = CGRect(x: width - 12.0 - 30.0, y: floor((height - 30.0) / 2.0), width: 30.0, height: 30.0)
        let textLeft: CGFloat = hasBack ? 50.0 : 16.0
        let textWidth = max(0.0, width - textLeft - 50.0)
        if let subtitle = page.subtitle, !subtitle.isEmpty {
            titleLabel.frame = CGRect(x: textLeft, y: 14.0, width: textWidth, height: 22.0)
            subtitleLabel.frame = CGRect(x: textLeft, y: 38.0, width: textWidth, height: 18.0)
        } else {
            titleLabel.frame = CGRect(x: textLeft, y: floor((height - 22.0) / 2.0), width: textWidth, height: 22.0)
            subtitleLabel.frame = CGRect(x: textLeft, y: height, width: textWidth, height: 0.0)
        }
        headerSeparator.frame = CGRect(x: 0.0, y: height - UIScreenPixel, width: width, height: UIScreenPixel)
    }

    private func push(page: AorusAIActionSheetPage, animated: Bool) {
        let pageView = AorusAIActionSheetPageView(page: page, palette: palette) { [weak self] row in
            self?.select(row)
        }
        if animated, let width = stack.last?.view.bounds.width {
            // Enter from the right at the current body height; `layoutCard` then moves
            // both levels and resizes the card in one animation.
            pageView.frame = CGRect(x: width, y: headerHeight(for: page), width: width, height: stack.last?.view.bounds.height ?? 0.0)
            pageView.alpha = 0.0
        }
        card.insertSubview(pageView, belowSubview: headerView)
        stack.append((page: page, view: pageView))
        titleLabel.text = page.title
        subtitleLabel.text = page.subtitle
        if let footer = page.footer {
            footerButton.isHidden = false
            footerButton.setTitle(footer.title, for: .normal)
        } else {
            footerButton.isHidden = true
        }
        layoutCard(animated: animated)
    }

    private func pop() {
        guard stack.count > 1 else { return }
        let removed = stack.removeLast()
        guard let page = currentPage else { return }
        titleLabel.text = page.title
        subtitleLabel.text = page.subtitle
        if let footer = page.footer {
            footerButton.isHidden = false
            footerButton.setTitle(footer.title, for: .normal)
        } else {
            footerButton.isHidden = true
        }
        let width = card.bounds.width
        layoutCard(animated: true)
        UIView.animate(withDuration: 0.3, delay: 0.0, options: [.curveEaseInOut], animations: {
            removed.view.frame = CGRect(x: width, y: removed.view.frame.minY, width: width, height: removed.view.frame.height)
            removed.view.alpha = 0.0
        }, completion: { _ in
            removed.view.removeFromSuperview()
        })
    }

    private func select(_ row: AorusAIActionSheetRow) {
        if row.opensPage, let page = pageForRow(row) {
            push(page: page, animated: true)
            return
        }
        close(then: { [weak self] in
            self?.onSelect(row)
        })
    }

    @objc private func footerTapped() {
        guard let footer = currentPage?.footer else { return }
        select(footer)
    }

    @objc private func backTapped() {
        pop()
    }

    @objc private func closeTapped() {
        close(then: nil)
    }

    /// Runs the action after the sheet is gone, so the chat controller it pushes is
    /// never presented underneath a dismissing modal.
    private func close(then action: (() -> Void)?) {
        guard !isClosing else { return }
        isClosing = true
        UIView.animate(withDuration: 0.24, delay: 0.0, options: [.curveEaseIn], animations: {
            self.dimView.alpha = 0.0
            self.card.transform = CGAffineTransform(translationX: 0.0, y: self.cardHeight + 40.0)
        }, completion: { _ in
            self.presentingViewController?.dismiss(animated: false, completion: action)
        })
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            let translation = max(0.0, recognizer.translation(in: view).y)
            card.transform = CGAffineTransform(translationX: 0.0, y: translation)
            dimView.alpha = max(0.0, 1.0 - translation / max(1.0, cardHeight))
        case .ended, .cancelled, .failed:
            let translation = max(0.0, recognizer.translation(in: view).y)
            let velocity = recognizer.velocity(in: view).y
            if translation > cardHeight / 3.0 || velocity > 900.0 {
                close(then: nil)
            } else {
                UIView.animate(withDuration: 0.25, delay: 0.0, options: [.curveEaseOut], animations: {
                    self.card.transform = .identity
                    self.dimView.alpha = 1.0
                })
            }
        default:
            break
        }
    }
}

/// Opens the AorusAI actions for the message the context menu was invoked on.
///
/// This is the whole surface the host patch needs: the generated code closes the
/// context menu and calls this, so the menu contents, their grouping and their
/// navigation all live in this module instead of inside TelegramUI.
public func aorusAIPresentMessageActions(
    context: AccountContext,
    navigationController: NavigationController?,
    peerId: Int64,
    messageNamespace: Int32,
    messageId: Int32,
    authorPeerId: Int64?,
    text: String
) {
    guard let navigationController else { return }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let languageCode = presentationData.strings.baseLanguageCode
    aorusAIResolveAuthorName(context: context, authorPeerId: authorPeerId) { authorName in
        let reference = AorusAIReferencedMessage(
            peerId: peerId,
            messageNamespace: messageNamespace,
            messageId: messageId,
            authorPeerId: authorPeerId,
            authorName: authorName,
            text: text
        )
        let controller = AorusAIActionSheetController(
            palette: AorusAIPalette.resolve(presentationData.theme),
            page: AorusAIMessageMenu.rootSheetPage(authorName: authorName, languageCode: languageCode),
            pageForRow: { row in
                return AorusAIMessageMenu.sheetPage(forRowId: row.id, languageCode: languageCode)
            },
            onSelect: { row in
                AorusAIMessageMenu.run(
                    id: row.id,
                    context: context,
                    navigationController: navigationController,
                    reference: reference
                )
            }
        )
        navigationController.present(controller, animated: false)
    }
}
