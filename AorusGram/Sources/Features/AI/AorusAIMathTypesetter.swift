import Foundation
import UIKit

/// Maths, drawn.
///
/// What it draws
/// -------------
/// Everything `AorusAIMath` says cannot be set as text and stay honest:
///
///   * a **fraction** — numerator over a rule over denominator, the rule on the maths axis so
///     it lines up with the `=` beside it;
///   * a **root** — the radical sign grown to the height of what is under it, with the bar
///     carried across the whole radicand and the degree tucked into its crook;
///   * a **script** whose parts have no characters of their own — `e^{iπ}`, `a_{fig}` — raised
///     and lowered properly instead of being written `e^(iπ)`;
///   * an **operator with limits** — ∑, ∏, lim — with the limits above and below, not beside;
///   * **delimiters** that grow to what they hold, so a bracket round a fraction is a bracket
///     the height of the fraction;
///   * a **system or a matrix** — its rows stacked and its brace drawn down the side.
///
/// What it does not draw
/// ---------------------
/// Anything that reads correctly as text. ½ is a character. `x²` is a character. `∫₀¹` is
/// three. Those stay text, so they stay selectable and keep the line's height — a drawing is
/// for what a character cannot say.
public enum AorusAIMathTypesetter {

    /// One construct, as an attachment that sits correctly on the surrounding baseline.
    public static func attachment(for atom: AorusAIMath.Atom,
                                  font: UIFont,
                                  color: UIColor) -> NSTextAttachment {
        let plain = AorusAIMath.plainText([atom])
        let metrics = measure([atom], font: font)
        let size = CGSize(width: max(metrics.width.rounded(.up), 1),
                          height: max(metrics.height.rounded(.up), 1))
        let image = cachedImage(key: cacheKey(plain: plain, font: font, color: color), size: size) {
            draw([atom], at: CGPoint(x: 0, y: metrics.ascent), font: font, color: color)
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // The image is placed by its bottom edge, so the part below the baseline is exactly
        // the negative offset: without this the construct sits on the line, not across it.
        attachment.bounds = CGRect(x: 0, y: -metrics.descent, width: size.width, height: size.height)
        attachment.accessibilityLabel = plain
        return attachment
    }

    // MARK: - Cache
    //
    // A streaming answer is re-rendered on every token, and every render would otherwise draw
    // everything in it again. The same construct at the same size in the same colour is the
    // same picture, so it is drawn once.

    private static let images = NSCache<NSString, UIImage>()

    private static func cacheKey(plain: String, font: UIFont, color: UIColor) -> NSString? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            // A pattern colour has no stable key; draw it every time rather than hand back a
            // picture in the wrong colour.
            return nil
        }
        return "\(plain)|\(font.fontName)|\(font.pointSize)|\(red),\(green),\(blue),\(alpha)" as NSString
    }

    private static func cachedImage(key: NSString?, size: CGSize, body: () -> Void) -> UIImage {
        if let key = key, let hit = images.object(forKey: key) { return hit }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in body() }
        if let key = key { images.setObject(image, forKey: key) }
        return image
    }

    // MARK: - Metrics

    private struct Metrics {
        var width: CGFloat
        /// Above the baseline.
        var ascent: CGFloat
        /// Below it.
        var descent: CGFloat

        var height: CGFloat { return ascent + descent }

        static let zero = Metrics(width: 0, ascent: 0, descent: 0)
    }

    /// A fraction's halves, a root's degree and a script are set smaller than the line they
    /// sit in, the way every typesetter does it, down to a floor so a deep nesting stays
    /// legible rather than vanishing.
    private static func smaller(_ font: UIFont, by factor: CGFloat) -> UIFont {
        return font.withSize(max(font.pointSize * factor, 9.0))
    }

    /// Where a fraction's rule sits: the maths axis, a little above the baseline, so the bar
    /// lines up with the `=` next to it rather than with the bottom of the letters.
    private static func axis(for font: UIFont) -> CGFloat { return font.pointSize * 0.26 }

    private static func gap(for font: UIFont) -> CGFloat { return max(font.pointSize * 0.16, 2.0) }

    private static func padding(for font: UIFont) -> CGFloat { return max(font.pointSize * 0.16, 2.0) }

    private static func rule(for font: UIFont) -> CGFloat {
        return max((font.pointSize * 0.055).rounded(), 1.0)
    }

    private static func superscriptShift(_ font: UIFont) -> CGFloat { return font.pointSize * 0.42 }

    private static func subscriptShift(_ font: UIFont) -> CGFloat { return font.pointSize * 0.16 }

    /// ∑ and ∏ are set larger than the line; `lim` and `max` are words and are not.
    private static func operatorFont(symbol: String, font: UIFont) -> UIFont {
        let isWord = symbol.first.map { $0.isLetter } ?? false
        return isWord ? font : font.withSize(font.pointSize * 1.45)
    }

    private static func scaledFont(height: CGFloat, font: UIFont, limit: CGFloat) -> UIFont {
        let scale = min(max(height / max(font.lineHeight, 1), 1.0), limit)
        return font.withSize(font.pointSize * scale)
    }

    private static func width(of value: String, font: UIFont) -> CGFloat {
        guard !value.isEmpty else { return 0 }
        return (value as NSString).size(withAttributes: [.font: font]).width
    }

    /// A delimiter grown to what it holds. An empty one takes no room at all, which is how
    /// `\left.` is drawn.
    private static func delimiterMetrics(_ value: String, height: CGFloat, font: UIFont) -> Metrics {
        guard !value.isEmpty else { return Metrics.zero }
        let scaled = scaledFont(height: height, font: font, limit: 3.5)
        return Metrics(width: width(of: value, font: scaled) + padding(for: font) * 0.5,
                       ascent: scaled.ascender * 0.86, descent: -scaled.descender * 0.86)
    }

    private static func measure(_ atoms: [AorusAIMath.Atom], font: UIFont) -> Metrics {
        guard !atoms.isEmpty else {
            return Metrics(width: 0, ascent: font.ascender, descent: -font.descender)
        }
        var total = Metrics.zero
        for atom in atoms {
            let piece = measure(atom, font: font)
            total.width += piece.width
            total.ascent = max(total.ascent, piece.ascent)
            total.descent = max(total.descent, piece.descent)
        }
        return total
    }

    private static func measure(_ atom: AorusAIMath.Atom, font: UIFont) -> Metrics {
        switch atom {
        case let .text(value):
            return Metrics(width: width(of: value, font: font),
                           ascent: font.ascender, descent: -font.descender)

        case let .fraction(numerator, denominator):
            let inner = smaller(font, by: 0.92)
            let top = measure(numerator, font: inner)
            let bottom = measure(denominator, font: inner)
            let bar = rule(for: font)
            return Metrics(
                width: max(top.width, bottom.width) + 2 * padding(for: font),
                ascent: axis(for: font) + bar / 2 + gap(for: font) + top.height,
                descent: max(bottom.height + gap(for: font) + bar / 2 - axis(for: font), 0)
            )

        case let .radical(degree, body):
            let inside = measure(body, font: font)
            let bar = rule(for: font)
            let clearance = gap(for: font)
            let signFont = scaledFont(height: inside.height + clearance + bar, font: font, limit: 4.0)
            let index = degree.isEmpty ? Metrics.zero : measure(degree, font: smaller(font, by: 0.62))
            return Metrics(
                width: index.width + width(of: "√", font: signFont) + inside.width + padding(for: font),
                ascent: max(inside.ascent + clearance + bar, signFont.ascender),
                descent: max(inside.descent, -signFont.descender)
            )

        case let .script(base, upper, lower):
            let root = measure(base, font: font)
            let small = smaller(font, by: 0.72)
            let raised = upper.isEmpty ? Metrics.zero : measure(upper, font: small)
            let lowered = lower.isEmpty ? Metrics.zero : measure(lower, font: small)
            return Metrics(
                width: root.width + max(raised.width, lowered.width),
                ascent: max(root.ascent, upper.isEmpty ? 0 : superscriptShift(font) + raised.ascent),
                descent: max(root.descent, lower.isEmpty ? 0 : subscriptShift(font) + lowered.descent)
            )

        case let .bigOperator(symbol, upper, lower):
            let big = operatorFont(symbol: symbol, font: font)
            let small = smaller(font, by: 0.7)
            let signWidth = width(of: symbol, font: big)
            let above = upper.isEmpty ? Metrics.zero : measure(upper, font: small)
            let below = lower.isEmpty ? Metrics.zero : measure(lower, font: small)
            let spacing = gap(for: font) * 0.6
            return Metrics(
                width: max(signWidth, max(above.width, below.width)) + 2 * padding(for: font),
                ascent: big.ascender + (upper.isEmpty ? 0 : spacing + above.height),
                descent: -big.descender + (lower.isEmpty ? 0 : spacing + below.height)
            )

        case let .delimited(open, close, body):
            let inside = measure(body, font: font)
            let left = delimiterMetrics(open, height: inside.height, font: font)
            let right = delimiterMetrics(close, height: inside.height, font: font)
            return Metrics(
                width: left.width + inside.width + right.width,
                ascent: max(inside.ascent, max(left.ascent, right.ascent)),
                descent: max(inside.descent, max(left.descent, right.descent))
            )

        case let .stack(open, rows):
            let layout = stackLayout(rows: rows, font: font)
            let bracket = delimiterMetrics(open, height: layout.height, font: font)
            // Centred on the maths axis, so a system sits beside an `=` the way one should.
            return Metrics(width: bracket.width + layout.width + padding(for: font),
                           ascent: layout.height / 2 + axis(for: font),
                           descent: max(layout.height / 2 - axis(for: font), 0))
        }
    }

    private static func stackLayout(rows: [[AorusAIMath.Atom]],
                                    font: UIFont) -> (width: CGFloat, height: CGFloat, rows: [Metrics]) {
        let spacing = gap(for: font) * 0.5
        var width: CGFloat = 0
        var height: CGFloat = 0
        var measured: [Metrics] = []
        for (offset, row) in rows.enumerated() {
            let piece = measure(row, font: font)
            measured.append(piece)
            width = max(width, piece.width)
            height += piece.height + (offset == 0 ? 0 : spacing)
        }
        return (width, height, measured)
    }

    // MARK: - Drawing

    /// `origin` is the left end of the baseline, in the current context's coordinates.
    private static func draw(_ atoms: [AorusAIMath.Atom], at origin: CGPoint,
                             font: UIFont, color: UIColor) {
        var x = origin.x
        for atom in atoms {
            draw(atom, at: CGPoint(x: x, y: origin.y), font: font, color: color)
            x += measure(atom, font: font).width
        }
    }

    private static func draw(_ atom: AorusAIMath.Atom, at origin: CGPoint,
                             font: UIFont, color: UIColor) {
        switch atom {
        case let .text(value):
            drawText(value, at: CGPoint(x: origin.x, y: origin.y - font.ascender),
                     font: font, color: color)

        case let .fraction(numerator, denominator):
            let inner = smaller(font, by: 0.92)
            let top = measure(numerator, font: inner)
            let bottom = measure(denominator, font: inner)
            let bar = rule(for: font)
            let inset = padding(for: font)
            let content = max(top.width, bottom.width)
            let barY = origin.y - axis(for: font) - bar / 2
            // Each half centred over the other, which is what makes the bar look like it
            // belongs to both of them.
            draw(numerator,
                 at: CGPoint(x: origin.x + inset + (content - top.width) / 2,
                             y: barY - gap(for: font) - top.descent),
                 font: inner, color: color)
            draw(denominator,
                 at: CGPoint(x: origin.x + inset + (content - bottom.width) / 2,
                             y: barY + bar + gap(for: font) + bottom.ascent),
                 font: inner, color: color)
            color.setFill()
            UIRectFill(CGRect(x: origin.x + inset * 0.35, y: barY,
                              width: content + inset * 1.3, height: bar))

        case let .radical(degree, body):
            let inside = measure(body, font: font)
            let bar = rule(for: font)
            let clearance = gap(for: font)
            let signFont = scaledFont(height: inside.height + clearance + bar, font: font, limit: 4.0)
            let index = degree.isEmpty ? Metrics.zero : measure(degree, font: smaller(font, by: 0.62))
            let signX = origin.x + index.width
            drawText("√", at: CGPoint(x: signX, y: origin.y - signFont.ascender),
                     font: signFont, color: color)
            if !degree.isEmpty {
                // In the crook of the sign, which is where a degree belongs.
                draw(degree,
                     at: CGPoint(x: origin.x, y: origin.y - inside.ascent * 0.55 - clearance),
                     font: smaller(font, by: 0.62), color: color)
            }
            let bodyX = signX + width(of: "√", font: signFont)
            draw(body, at: CGPoint(x: bodyX, y: origin.y), font: font, color: color)
            color.setFill()
            UIRectFill(CGRect(x: bodyX - bar / 2, y: origin.y - inside.ascent - clearance - bar,
                              width: inside.width + padding(for: font), height: bar))

        case let .script(base, upper, lower):
            let root = measure(base, font: font)
            draw(base, at: origin, font: font, color: color)
            let small = smaller(font, by: 0.72)
            let x = origin.x + root.width
            if !upper.isEmpty {
                draw(upper, at: CGPoint(x: x, y: origin.y - superscriptShift(font)),
                     font: small, color: color)
            }
            if !lower.isEmpty {
                draw(lower, at: CGPoint(x: x, y: origin.y + subscriptShift(font)),
                     font: small, color: color)
            }

        case let .bigOperator(symbol, upper, lower):
            let big = operatorFont(symbol: symbol, font: font)
            let small = smaller(font, by: 0.7)
            let signWidth = width(of: symbol, font: big)
            let above = upper.isEmpty ? Metrics.zero : measure(upper, font: small)
            let below = lower.isEmpty ? Metrics.zero : measure(lower, font: small)
            let content = max(signWidth, max(above.width, below.width))
            let inset = padding(for: font)
            let spacing = gap(for: font) * 0.6
            drawText(symbol,
                     at: CGPoint(x: origin.x + inset + (content - signWidth) / 2,
                                 y: origin.y - big.ascender),
                     font: big, color: color)
            if !upper.isEmpty {
                draw(upper,
                     at: CGPoint(x: origin.x + inset + (content - above.width) / 2,
                                 y: origin.y - big.ascender - spacing - above.descent),
                     font: small, color: color)
            }
            if !lower.isEmpty {
                draw(lower,
                     at: CGPoint(x: origin.x + inset + (content - below.width) / 2,
                                 y: origin.y - big.descender + spacing + below.ascent),
                     font: small, color: color)
            }

        case let .delimited(open, close, body):
            let inside = measure(body, font: font)
            let scaled = scaledFont(height: inside.height, font: font, limit: 3.5)
            let left = delimiterMetrics(open, height: inside.height, font: font)
            // A grown delimiter is centred on the maths axis, like the content it holds.
            let centre = origin.y - axis(for: font)
            if !open.isEmpty {
                drawText(open, at: CGPoint(x: origin.x, y: centre - scaled.lineHeight / 2),
                         font: scaled, color: color)
            }
            draw(body, at: CGPoint(x: origin.x + left.width, y: origin.y), font: font, color: color)
            if !close.isEmpty {
                drawText(close,
                         at: CGPoint(x: origin.x + left.width + inside.width,
                                     y: centre - scaled.lineHeight / 2),
                         font: scaled, color: color)
            }

        case let .stack(open, rows):
            let layout = stackLayout(rows: rows, font: font)
            let bracket = delimiterMetrics(open, height: layout.height, font: font)
            let spacing = gap(for: font) * 0.5
            if !open.isEmpty {
                let scaled = scaledFont(height: layout.height, font: font, limit: 3.5)
                drawText(open,
                         at: CGPoint(x: origin.x,
                                     y: origin.y - axis(for: font) - scaled.lineHeight / 2),
                         font: scaled, color: color)
            }
            var y = origin.y - layout.height / 2 - axis(for: font)
            for (offset, row) in rows.enumerated() {
                let piece = layout.rows[offset]
                draw(row, at: CGPoint(x: origin.x + bracket.width, y: y + piece.ascent),
                     font: font, color: color)
                y += piece.height + spacing
            }
        }
    }

    private static func drawText(_ value: String, at point: CGPoint, font: UIFont, color: UIColor) {
        guard !value.isEmpty else { return }
        NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color])
            .draw(at: point)
    }
}
