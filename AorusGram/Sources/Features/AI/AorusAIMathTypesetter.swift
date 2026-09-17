import Foundation
import UIKit

/// A fraction in a display equation, set the way a fraction is set: numerator over a rule
/// over denominator, sitting on the line's own baseline.
///
/// Why a drawn fraction and not text
/// ---------------------------------
/// Inline, `(x(x-2)²)/(x(x-6))` is unambiguous and reads fine — it is what `AorusAIMath`
/// produces everywhere text has to stay text. But an equation the author set on its own line
/// is a display equation, and a reader expects to see the bar. Two halves and a slash is the
/// thing you write when you cannot draw one.
///
/// Why only the fraction, and not the whole equation
/// -------------------------------------------------
/// Everything around it stays real, selectable text. Only the fraction becomes an attachment,
/// so `= 0` at the end of the line can still be selected, and an equation with no fraction in
/// it is never turned into a picture at all. Turning a whole line into an image is how a
/// renderer takes selection away from a reader, and it is not necessary here.
public enum AorusAIMathTypesetter {

    /// One fraction, as an attachment that sits correctly on the surrounding baseline.
    public static func attachment(numerator: [AorusAIMath.Atom],
                                  denominator: [AorusAIMath.Atom],
                                  font: UIFont,
                                  color: UIColor) -> NSTextAttachment {
        let atom = AorusAIMath.Atom.fraction(numerator: numerator, denominator: denominator)
        let metrics = measure([atom], font: font)
        let size = CGSize(width: max(metrics.width.rounded(.up), 1),
                          height: max((metrics.ascent + metrics.descent).rounded(.up), 1))
        let renderer = UIGraphicsImageRenderer(size: size, format: transparentFormat())
        let image = renderer.image { _ in
            draw([atom], at: CGPoint(x: 0, y: metrics.ascent), font: font, color: color)
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // The image is placed by its bottom edge, so the part below the baseline is exactly
        // the negative offset: without this the fraction sits on the line instead of across it.
        attachment.bounds = CGRect(x: 0, y: -metrics.descent, width: size.width, height: size.height)
        attachment.accessibilityLabel = AorusAIMath.plainText([atom])
        return attachment
    }

    private static func transparentFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return format
    }

    // MARK: - Metrics

    private struct Metrics {
        var width: CGFloat
        /// Above the baseline.
        var ascent: CGFloat
        /// Below it.
        var descent: CGFloat
    }

    /// A fraction's halves are set a little smaller than the line they sit in, the way every
    /// typesetter does it, and a fraction inside a fraction smaller again — down to a floor,
    /// so a deep nesting stays legible rather than vanishing.
    private static func halfFont(for font: UIFont) -> UIFont {
        return font.withSize(max(font.pointSize * 0.88, 10.0))
    }

    /// Where the rule sits: the maths axis, a little above the baseline, so the bar lines up
    /// with the `=` next to it rather than with the bottom of the letters.
    private static func axis(for font: UIFont) -> CGFloat {
        return font.pointSize * 0.26
    }

    private static func gap(for font: UIFont) -> CGFloat {
        return max(font.pointSize * 0.16, 2.0)
    }

    private static func sidePadding(for font: UIFont) -> CGFloat {
        return max(font.pointSize * 0.16, 2.0)
    }

    private static func ruleThickness(for font: UIFont) -> CGFloat {
        return max((font.pointSize * 0.055).rounded(), 1.0)
    }

    private static func measure(_ atoms: [AorusAIMath.Atom], font: UIFont) -> Metrics {
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        for atom in atoms {
            let piece: Metrics
            switch atom {
            case let .text(value):
                let bounds = (value as NSString).size(withAttributes: [.font: font])
                piece = Metrics(width: bounds.width, ascent: font.ascender, descent: -font.descender)
            case let .fraction(numerator, denominator):
                piece = measureFraction(numerator: numerator, denominator: denominator, font: font)
            }
            width += piece.width
            ascent = max(ascent, piece.ascent)
            descent = max(descent, piece.descent)
        }
        return Metrics(width: width, ascent: ascent, descent: descent)
    }

    private static func measureFraction(numerator: [AorusAIMath.Atom],
                                        denominator: [AorusAIMath.Atom],
                                        font: UIFont) -> Metrics {
        let inner = halfFont(for: font)
        let top = measure(numerator, font: inner)
        let bottom = measure(denominator, font: inner)
        let rule = ruleThickness(for: font)
        let spacing = gap(for: font)
        let centre = axis(for: font)
        return Metrics(
            width: max(top.width, bottom.width) + 2 * sidePadding(for: font),
            ascent: centre + rule / 2 + spacing + top.ascent + top.descent,
            descent: max(bottom.ascent + bottom.descent + spacing + rule / 2 - centre, 0)
        )
    }

    // MARK: - Drawing

    /// `origin` is the left end of the baseline, in the current context's coordinates.
    private static func draw(_ atoms: [AorusAIMath.Atom], at origin: CGPoint,
                             font: UIFont, color: UIColor) {
        var x = origin.x
        for atom in atoms {
            switch atom {
            case let .text(value):
                let attributed = NSAttributedString(string: value, attributes: [
                    .font: font, .foregroundColor: color,
                ])
                attributed.draw(at: CGPoint(x: x, y: origin.y - font.ascender))
                // Measured the same way `measure` measures it, so the width a run is given
                // is the width the next one starts after.
                x += (value as NSString).size(withAttributes: [.font: font]).width
            case let .fraction(numerator, denominator):
                x += drawFraction(numerator: numerator, denominator: denominator,
                                  at: CGPoint(x: x, y: origin.y), font: font, color: color)
            }
        }
    }

    private static func drawFraction(numerator: [AorusAIMath.Atom],
                                     denominator: [AorusAIMath.Atom],
                                     at origin: CGPoint,
                                     font: UIFont,
                                     color: UIColor) -> CGFloat {
        let inner = halfFont(for: font)
        let top = measure(numerator, font: inner)
        let bottom = measure(denominator, font: inner)
        let rule = ruleThickness(for: font)
        let spacing = gap(for: font)
        let centre = axis(for: font)
        let padding = sidePadding(for: font)
        let contentWidth = max(top.width, bottom.width)
        let width = contentWidth + 2 * padding

        let ruleY = origin.y - centre - rule / 2
        // Each half is centred over the other, which is what makes the bar look like it
        // belongs to both of them.
        draw(numerator,
             at: CGPoint(x: origin.x + padding + (contentWidth - top.width) / 2,
                         y: ruleY - spacing - top.descent),
             font: inner, color: color)
        draw(denominator,
             at: CGPoint(x: origin.x + padding + (contentWidth - bottom.width) / 2,
                         y: ruleY + rule + spacing + bottom.ascent),
             font: inner, color: color)

        color.setFill()
        UIRectFill(CGRect(x: origin.x + padding * 0.35, y: ruleY,
                          width: width - padding * 0.7, height: rule))
        return width
    }
}
