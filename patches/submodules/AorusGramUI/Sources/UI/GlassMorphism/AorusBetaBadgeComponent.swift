import Foundation
import UIKit
import ComponentFlow

// AorusGram: the small tag that sits next to a settings row's title.
//
// ItemListSwitchItem takes its badge as an AnyComponent, so this is the smallest possible
// ComponentFlow component rather than a plain view — it exists purely to satisfy that
// parameter. The size it returns is what the row uses to reserve space beside the title.
//
// Nothing wears it at the moment: Interface 2.0 is released and its tag came off with the
// release. The badge itself is kept, deliberately — it is the fork's way of marking a row as
// unfinished, and the next feature that needs marking should find it here rather than write
// it again. `text` and `color` are parameters for that reason: BETA in blue is one use of
// it, not the only one it can have.

final class AorusBetaBadgeComponent: Component {
    let text: String
    let color: UIColor

    init(text: String, color: UIColor) {
        self.text = text
        self.color = color
    }

    static func == (lhs: AorusBetaBadgeComponent, rhs: AorusBetaBadgeComponent) -> Bool {
        return lhs.text == rhs.text && lhs.color == rhs.color
    }

    final class View: UIView {
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.label.textAlignment = .center
            self.label.textColor = .white
            self.addSubview(self.label)
            self.layer.cornerCurve = .continuous
            self.layer.cornerRadius = 4.0
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func update(text: String, color: UIColor, availableSize: CGSize) -> CGSize {
            self.backgroundColor = color
            self.label.font = UIFont.systemFont(ofSize: 11.0, weight: .semibold)
            self.label.text = text

            let horizontalPadding: CGFloat = 5.0
            let height: CGFloat = 16.0
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: self.label.font as Any]).width)
            let width = min(availableSize.width, textWidth + horizontalPadding * 2.0)
            self.label.frame = CGRect(x: 0.0, y: 0.0, width: width, height: height)
            return CGSize(width: width, height: min(availableSize.height, height))
        }
    }

    func makeView() -> View {
        return View(frame: .zero)
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(text: self.text, color: self.color, availableSize: availableSize)
    }
}
