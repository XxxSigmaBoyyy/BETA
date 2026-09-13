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

// MARK: - AorusAI work trail

/// The agent's own account of what it did, drawn above its answer.
///
/// While the turn runs it reads as a list: each label the agent announced, and under it
/// the files it touched while that label was current. When the turn ends the whole thing
/// folds into one line — "Работал 42 секунды" — which unfolds again on tap.
///
/// Deliberately not a card. There is no box, no border and no fill: the design is one
/// column of small type against the page, with a hairline rule down the left of each
/// group's children so the hierarchy reads without drawing a container for it.
public final class AorusAIWorkTrailView: UIView {
    /// Called when the reader folds or unfolds the trail, so the list can re-measure the
    /// row. The view does not know it is in a table and must not.
    public var onToggle: (() -> Void)?

    private let summaryButton = UIButton(type: .system)
    private let chevron = UIImageView()
    private let stack = UIStackView()
    private var palette: AorusAIPalette?
    private var renderedPhases: [AorusAIWorkPhase] = []
    private weak var renderedTheme: PresentationTheme?
    private var renderedFinished = false
    /// Whether the turn has stopped. Read by `rebuild` to decide which link of the
    /// chain is the live one.
    private var isFinishedState = false

    public override init(frame: CGRect) {
        super.init(frame: frame)

        stack.axis = .vertical
        stack.spacing = 5.0
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        summaryButton.contentHorizontalAlignment = .leading
        summaryButton.titleLabel?.font = .systemFont(ofSize: 12.5, weight: .medium)
        summaryButton.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        summaryButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summaryButton)

        chevron.contentMode = .scaleAspectFit
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9.0, weight: .semibold)
        )
        addSubview(chevron)

        NSLayoutConstraint.activate([
            summaryButton.topAnchor.constraint(equalTo: topAnchor),
            summaryButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            chevron.centerYAnchor.constraint(equalTo: summaryButton.centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: summaryButton.trailingAnchor, constant: 4.0),
            chevron.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        stackTop = stack.topAnchor.constraint(equalTo: topAnchor)
        stackTop?.isActive = true
        summaryBottom = summaryButton.bottomAnchor.constraint(equalTo: bottomAnchor)
    }

    private var stackTop: NSLayoutConstraint?
    private var summaryBottom: NSLayoutConstraint?
    private var summaryToStack: NSLayoutConstraint?

    public required init?(coder: NSCoder) { preconditionFailure("AorusAIWorkTrailView is not built from a coder") }

    /// `isFinished` folds the trail; `isExpanded` is the reader's own choice, which only
    /// matters once it is folded.
    public func configure(phases: [AorusAIWorkPhase],
                          isFinished: Bool,
                          duration: TimeInterval?,
                          isExpanded: Bool,
                          theme: PresentationTheme) {
        let palette = AorusAIPalette.resolve(theme)
        self.palette = palette

        guard !phases.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false

        isFinishedState = isFinished
        let showsSummary = isFinished
        let showsBody = !isFinished || isExpanded

        summaryButton.isHidden = !showsSummary
        chevron.isHidden = !showsSummary
        summaryButton.setTitleColor(palette.tertiary, for: .normal)
        chevron.tintColor = palette.tertiary
        if showsSummary {
            summaryButton.setTitle(Self.summaryText(duration: duration), for: .normal)
            // A quarter turn rather than a second glyph, so the two states are one object.
            chevron.transform = isExpanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        }

        stack.isHidden = !showsBody
        if renderedPhases != phases || renderedTheme !== theme || renderedFinished != isFinished || (showsBody && stack.arrangedSubviews.isEmpty) {
            renderedPhases = phases
            renderedTheme = theme
            renderedFinished = isFinished
            rebuild(phases: phases, palette: palette)
        }

        // The two layouts differ only in what the top of the stack is pinned to.
        stackTop?.isActive = false
        summaryToStack?.isActive = false
        summaryBottom?.isActive = false
        if showsSummary {
            if showsBody {
                if summaryToStack == nil {
                    summaryToStack = stack.topAnchor.constraint(equalTo: summaryButton.bottomAnchor, constant: 6.0)
                }
                summaryToStack?.isActive = true
            } else {
                summaryBottom?.isActive = true
            }
        } else {
            stackTop?.isActive = true
        }
    }

    private func rebuild(phases: [AorusAIWorkPhase], palette: AorusAIPalette) {
        // Rebuilt wholesale: a turn reports a handful of phases and the rows are plain
        // views, so reconciling them would be more moving parts than redrawing.
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !stack.isHidden else { return }

        for (offset, phase) in phases.enumerated() {
            let files = phase.files.filter { $0.isRenderable }
            let isLastPhase = offset == phases.count - 1
            let isActive = isLastPhase && !isFinishedState
            let label = PhaseLabel()
            label.configure(
                text: phase.label,
                color: palette.label,
                accent: palette.accent,
                active: isActive
            )
            stack.addArrangedSubview(BranchRow(
                content: label,
                depth: 0,
                isLastAtDepth: isLastPhase && files.isEmpty,
                ancestorContinues: [],
                colour: palette.label.withAlphaComponent(isActive ? 0.52 : 0.34)
            ))
            for (fileOffset, file) in files.enumerated() {
                let row = UILabel()
                row.font = .systemFont(ofSize: 12.0)
                row.numberOfLines = 0
                row.attributedText = Self.attributedRow(file, palette: palette)
                stack.addArrangedSubview(BranchRow(
                    content: row,
                    depth: 1,
                    isLastAtDepth: fileOffset == files.count - 1,
                    // The trunk above only carries on while another phase is still to come.
                    ancestorContinues: [!isLastPhase],
                    colour: palette.label.withAlphaComponent(isActive ? 0.52 : 0.34)
                ))
            }
        }
    }

    /// Full-strength text at rest, with one restrained highlight crossing only the phase
    /// that is running. The base label never dims: when the animation stops the row is the
    /// same solid ink as every completed row, rather than fading into tertiary grey.
    private final class PhaseLabel: UIView {
        private let base = UILabel()
        private let highlight = UILabel()
        private let sweep = CAGradientLayer()
        private var active = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            for label in [base, highlight] {
                label.font = .systemFont(ofSize: 12.5, weight: .medium)
                label.numberOfLines = 0
                label.translatesAutoresizingMaskIntoConstraints = false
                addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: leadingAnchor),
                    label.trailingAnchor.constraint(equalTo: trailingAnchor),
                    label.topAnchor.constraint(equalTo: topAnchor),
                    label.bottomAnchor.constraint(equalTo: bottomAnchor)
                ])
            }
            sweep.startPoint = CGPoint(x: 0.0, y: 0.5)
            sweep.endPoint = CGPoint(x: 1.0, y: 0.5)
            sweep.colors = [
                UIColor.clear.cgColor,
                UIColor.white.cgColor,
                UIColor.white.cgColor,
                UIColor.clear.cgColor
            ]
            sweep.locations = [0.0, 0.42, 0.58, 1.0]
            highlight.layer.mask = sweep
        }

        required init?(coder: NSCoder) { preconditionFailure("PhaseLabel is not built from a coder") }

        override var intrinsicContentSize: CGSize {
            return base.intrinsicContentSize
        }

        func configure(text: String, color: UIColor, accent: UIColor, active: Bool) {
            self.active = active
            base.text = text
            base.textColor = color
            highlight.text = text
            highlight.textColor = .white
            highlight.layer.shadowColor = accent.cgColor
            highlight.layer.shadowOpacity = active ? 0.55 : 0.0
            highlight.layer.shadowRadius = 4.0
            highlight.layer.shadowOffset = .zero
            highlight.isHidden = !active || UIAccessibility.isReduceMotionEnabled
            accessibilityLabel = text
            isAccessibilityElement = true
            setNeedsLayout()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateAnimation()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sweep.frame = highlight.bounds
            CATransaction.commit()
            updateAnimation()
        }

        private func updateAnimation() {
            sweep.removeAnimation(forKey: "aorusPhaseSweep")
            guard active, window != nil, bounds.width > 1.0, !UIAccessibility.isReduceMotionEnabled else {
                return
            }
            let animation = CABasicAnimation(keyPath: "transform.translation.x")
            animation.fromValue = -bounds.width
            animation.toValue = bounds.width
            animation.duration = 1.8
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sweep.add(animation, forKey: "aorusPhaseSweep")
        }
    }

    /// One line of a branch: the rules that lead to it, its own elbow, and its content.
    ///
    /// Drawn rather than assembled out of subviews. A branch is a handful of straight
    /// segments whose lengths depend on the row's own height, and a shape layer laid out in
    /// `layoutSubviews` expresses that directly — where a stack of spacer views would need
    /// a constraint for every segment and would still not know where the middle of a
    /// two-line label is.
    private final class BranchRow: UIView {
        /// How far one level of the branch steps to the right.
        static let indent: CGFloat = 13.0
        /// Where the first trunk runs, from the leading edge.
        static let origin: CGFloat = 3.0
        /// How far the elbow reaches out before the content begins.
        static let reach: CGFloat = 8.0

        private let shape = CAShapeLayer()
        private let content: UIView
        private let depth: Int
        private let isLastAtDepth: Bool
        private let ancestorContinues: [Bool]

        init(content: UIView, depth: Int, isLastAtDepth: Bool, ancestorContinues: [Bool], colour: UIColor) {
            self.content = content
            self.depth = depth
            self.isLastAtDepth = isLastAtDepth
            self.ancestorContinues = ancestorContinues
            super.init(frame: .zero)

            shape.fillColor = UIColor.clear.cgColor
            shape.strokeColor = colour.cgColor
            shape.lineWidth = 1.0
            // Square ends: a branch drawn with round caps reads as a diagram of bubbles.
            shape.lineCap = .butt
            layer.addSublayer(shape)

            content.translatesAutoresizingMaskIntoConstraints = false
            addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: Self.origin + CGFloat(depth) * Self.indent + Self.reach + 5.0
                ),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) { preconditionFailure("BranchRow is not built from a coder") }

        override func layoutSubviews() {
            super.layoutSubviews()
            let path = UIBezierPath()
            // The elbow meets the content on the first line's centre, not on the row's, so a
            // row that wraps to three lines still joins the branch where its text starts.
            let firstLine = min(bounds.height, content.intrinsicContentSize.height > 0
                ? min(content.intrinsicContentSize.height, 18.0)
                : 18.0)
            let joinY = (firstLine / 2.0).rounded()

            // The rules of every level above this one, carried straight down.
            for (level, carries) in ancestorContinues.enumerated() where carries {
                let x = Self.origin + CGFloat(level) * Self.indent
                path.move(to: CGPoint(x: x, y: 0.0))
                path.addLine(to: CGPoint(x: x, y: bounds.height))
            }

            // This row's own rule: down to the join, and on to the bottom unless it is the
            // last at its level — which is what makes a branch end instead of trail off.
            let x = Self.origin + CGFloat(depth) * Self.indent
            path.move(to: CGPoint(x: x, y: 0.0))
            path.addLine(to: CGPoint(x: x, y: isLastAtDepth ? joinY : bounds.height))
            // The elbow.
            path.move(to: CGPoint(x: x, y: joinY))
            path.addLine(to: CGPoint(x: x + Self.reach, y: joinY))

            shape.frame = bounds
            shape.path = path.cgPath
        }
    }

    static func attributedRow(_ file: AorusAIFileChange, palette: AorusAIPalette) -> NSAttributedString {
        let verb: String
        switch file.kind {
        case .created: verb = aorusAILocalized("Создан", "Created")
        case .edited: verb = aorusAILocalized("Изменён", "Edited")
        case .deleted: verb = aorusAILocalized("Удалён", "Deleted")
        }
        let font = UIFont.systemFont(ofSize: 12.0)
        // Monospaced digits so a column of files lines its counts up instead of dancing.
        let countFont = UIFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .medium)
        let result = NSMutableAttributedString(
            string: "\(verb) \(file.displayName) ",
            attributes: [.font: font, .foregroundColor: palette.secondary]
        )
        let added = UIColor(red: 0.30, green: 0.72, blue: 0.42, alpha: 1.0)
        let removed = UIColor(red: 0.90, green: 0.35, blue: 0.33, alpha: 1.0)
        var counts: [NSAttributedString] = []
        if file.kind != .deleted, file.added > 0 {
            counts.append(NSAttributedString(string: "+\(file.added)", attributes: [.font: countFont, .foregroundColor: added]))
        }
        if file.kind != .created, file.removed > 0 {
            counts.append(NSAttributedString(string: "-\(file.removed)", attributes: [.font: countFont, .foregroundColor: removed]))
        }
        for (offset, part) in counts.enumerated() {
            if offset > 0 {
                result.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            result.append(part)
        }
        return result
    }

    static func summaryText(duration: TimeInterval?) -> String {
        guard let duration, duration >= 1.0 else {
            return aorusAILocalized("Работал меньше секунды", "Worked for less than a second")
        }
        let total = Int(duration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        if minutes <= 0 {
            return aorusAILocalized("Работал \(seconds) с", "Worked for \(seconds)s")
        }
        if seconds == 0 {
            return aorusAILocalized("Работал \(minutes) мин", "Worked for \(minutes)m")
        }
        return aorusAILocalized("Работал \(minutes) мин \(seconds) с", "Worked for \(minutes)m \(seconds)s")
    }

    @objc private func toggle() {
        onToggle?()
    }
}
