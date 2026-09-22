import Foundation
import UIKit
import AorusGram
import AorusGramUI

// What a plugin draws over the open chat.
//
// The plugin sends data — a title, a symbol name, a colour, a corner — and this builds the
// views. Nothing of the plugin's reaches UIKit: every number arrived through
// `AorusPluginOverlay.validated`, which clamps rather than rejects, so the worst a plugin
// can ask for is the largest button that still fits.
//
// Deliberately plain UIKit. The chat's own layout is Telegram's and is not touched: this is
// one container pinned to the controller's view, laying its children out itself, and
// letting every touch it does not own fall through to what is underneath.

private let aorusOverlayPanelHeight: CGFloat = 46.0
private let aorusOverlayPanelHeightWithSubtitle: CGFloat = 58.0
private let aorusOverlayMargin: CGFloat = 12.0

final class AorusPluginOverlayHost: UIView {
    /// The chat this is drawn over, for the payload a tap carries.
    var peerId: Int64?

    private var items: [(pluginId: String, overlay: AorusPluginOverlay)] = []
    private var views: [String: UIView] = [:]
    /// Where a draggable button has been moved to, by key. Kept in memory for the life of
    /// the chat: a position someone chose should survive a reload of the overlay set, and
    /// storing it on disk is the plugin's job through `aorus.storage`.
    private var dragged: [String: CGPoint] = [:]

    init() {
        super.init(frame: .zero)
        self.isUserInteractionEnabled = true
        self.backgroundColor = .clear
        self.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    required init?(coder: NSCoder) {
        preconditionFailure("AorusPluginOverlayHost is created in code")
    }

    /// Only the children are touchable. Everything else falls through to the chat, which is
    /// the difference between an overlay and a sheet nobody asked for.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        for subview in self.subviews where !subview.isHidden && subview.alpha > 0.01 {
            if subview.point(inside: self.convert(point, to: subview), with: event) { return true }
        }
        return false
    }

    private static func key(_ pluginId: String, _ overlayId: String) -> String {
        return pluginId + "\u{1}" + overlayId
    }

    private static func color(_ hex: String?) -> UIColor? {
        guard let hex = hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1.0
        )
    }

    func reload() {
        let previous = self.items
        self.items = AorusPluginRuntimeManager.shared.pluginOverlays()
        let live = Set(self.items.map { AorusPluginOverlayHost.key($0.pluginId, $0.overlay.id) })
        for (key, view) in self.views where !live.contains(key) {
            view.removeFromSuperview()
            self.views[key] = nil
            self.dragged[key] = nil
        }
        for item in self.items {
            let key = AorusPluginOverlayHost.key(item.pluginId, item.overlay.id)
            // A view is rebuilt only when what it draws changed. An update that only moves
            // something must not make the button someone is pressing disappear and come back.
            let unchanged = previous.first { AorusPluginOverlayHost.key($0.pluginId, $0.overlay.id) == key }?.overlay
            if unchanged == item.overlay, self.views[key] != nil { continue }
            self.views[key]?.removeFromSuperview()
            let view = self.build(item.pluginId, item.overlay)
            self.views[key] = view
            self.addSubview(view)
        }
        self.setNeedsLayout()
    }

    private func build(_ pluginId: String, _ overlay: AorusPluginOverlay) -> UIView {
        switch overlay.kind {
        case .floatingButton:
            return self.buildButton(pluginId, overlay)
        case .chatPanel:
            return self.buildPanel(pluginId, overlay)
        }
    }

    private func buildButton(_ pluginId: String, _ overlay: AorusPluginOverlay) -> UIView {
        let button = AorusPluginOverlayButton(type: .system)
        button.pluginId = pluginId
        button.overlayId = overlay.id
        let background = AorusPluginOverlayHost.color(overlay.backgroundColor) ?? UIColor.systemBlue
        let foreground = AorusPluginOverlayHost.color(overlay.textColor) ?? UIColor.white
        button.backgroundColor = background
        button.tintColor = foreground
        button.setTitleColor(foreground, for: .normal)
        button.alpha = CGFloat(overlay.alpha)
        if overlay.displayMode != .icon, !overlay.title.isEmpty {
            button.setTitle(overlay.title, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: CGFloat(overlay.fontSize ?? 15.0), weight: .semibold)
        }
        if overlay.displayMode != .text, let icon = overlay.icon, let image = UIImage(systemName: icon) {
            button.setImage(image.withRenderingMode(.alwaysTemplate), for: .normal)
        }
        if button.title(for: .normal) != nil, button.image(for: .normal) != nil {
            button.contentEdgeInsets = UIEdgeInsets(top: 0.0, left: 12.0, bottom: 0.0, right: 14.0)
            button.titleEdgeInsets = UIEdgeInsets(top: 0.0, left: 6.0, bottom: 0.0, right: -6.0)
        } else if button.title(for: .normal) != nil {
            button.contentEdgeInsets = UIEdgeInsets(top: 0.0, left: 14.0, bottom: 0.0, right: 14.0)
        }
        if let borderColor = AorusPluginOverlayHost.color(overlay.borderColor), overlay.borderWidth > 0.0 {
            button.layer.borderColor = borderColor.cgColor
            button.layer.borderWidth = CGFloat(overlay.borderWidth)
        }
        if overlay.shadow {
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = 0.22
            button.layer.shadowRadius = 10.0
            button.layer.shadowOffset = CGSize(width: 0.0, height: 4.0)
        }
        button.isUserInteractionEnabled = overlay.interactive
        button.addTarget(self, action: #selector(self.overlayPressed(_:)), for: .touchUpInside)
        if overlay.draggable {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(self.overlayDragged(_:)))
            button.addGestureRecognizer(pan)
        }
        return button
    }

    private func buildPanel(_ pluginId: String, _ overlay: AorusPluginOverlay) -> UIView {
        let panel = AorusPluginOverlayPanel()
        panel.pluginId = pluginId
        panel.overlayId = overlay.id
        let background = AorusPluginOverlayHost.color(overlay.backgroundColor)
            ?? UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        let foreground = AorusPluginOverlayHost.color(overlay.textColor) ?? UIColor.label
        panel.backgroundColor = background
        panel.tintColor = foreground
        panel.alpha = CGFloat(overlay.alpha)
        panel.layer.cornerRadius = CGFloat(overlay.cornerRadius ?? 12.0)
        if let borderColor = AorusPluginOverlayHost.color(overlay.borderColor), overlay.borderWidth > 0.0 {
            panel.layer.borderColor = borderColor.cgColor
            panel.layer.borderWidth = CGFloat(overlay.borderWidth)
        }
        if overlay.shadow {
            panel.layer.shadowColor = UIColor.black.cgColor
            panel.layer.shadowOpacity = 0.16
            panel.layer.shadowRadius = 8.0
            panel.layer.shadowOffset = CGSize(width: 0.0, height: 2.0)
        }
        panel.configure(
            title: overlay.title,
            subtitle: overlay.subtitle,
            icon: overlay.displayMode == .text ? nil : overlay.icon,
            titleColor: foreground,
            fontSize: CGFloat(overlay.fontSize ?? 15.0)
        )
        panel.isUserInteractionEnabled = overlay.interactive
        if overlay.interactive {
            panel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.overlayTapped(_:))))
        }
        return panel
    }

    // MARK: - Interaction

    @objc private func overlayPressed(_ sender: UIButton) {
        guard let button = sender as? AorusPluginOverlayButton else { return }
        AorusPluginChatBridge.reportOverlayTap(pluginId: button.pluginId, overlayId: button.overlayId, peerId: self.peerId)
    }

    @objc private func overlayTapped(_ recognizer: UITapGestureRecognizer) {
        guard let panel = recognizer.view as? AorusPluginOverlayPanel else { return }
        AorusPluginChatBridge.reportOverlayTap(pluginId: panel.pluginId, overlayId: panel.overlayId, peerId: self.peerId)
    }

    @objc private func overlayDragged(_ recognizer: UIPanGestureRecognizer) {
        guard let button = recognizer.view as? AorusPluginOverlayButton else { return }
        let key = AorusPluginOverlayHost.key(button.pluginId, button.overlayId)
        let translation = recognizer.translation(in: self)
        var centre = button.center
        centre.x += translation.x
        centre.y += translation.y
        // Kept inside the chat, so a button cannot be dragged off the screen and lost.
        let half = CGSize(width: button.bounds.width / 2.0, height: button.bounds.height / 2.0)
        centre.x = min(self.bounds.width - half.width, max(half.width, centre.x))
        centre.y = min(self.bounds.height - half.height, max(half.height, centre.y))
        button.center = centre
        recognizer.setTranslation(.zero, in: self)
        if recognizer.state == .ended || recognizer.state == .cancelled {
            self.dragged[key] = centre
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let insets = self.safeAreaInsets
        var panelTop = insets.top + aorusOverlayMargin
        for item in self.items {
            let key = AorusPluginOverlayHost.key(item.pluginId, item.overlay.id)
            guard let view = self.views[key] else { continue }
            switch item.overlay.kind {
            case .chatPanel:
                // Panels stack under the navigation bar in the order they were added, which
                // is the order the plugin registered them in.
                let height = item.overlay.height.map { CGFloat($0) }
                    ?? (item.overlay.subtitle == nil ? aorusOverlayPanelHeight : aorusOverlayPanelHeightWithSubtitle)
                view.frame = CGRect(
                    x: aorusOverlayMargin + CGFloat(item.overlay.offsetX),
                    y: panelTop + CGFloat(item.overlay.offsetY),
                    width: max(0.0, self.bounds.width - aorusOverlayMargin * 2.0),
                    height: height
                )
                panelTop += height + 8.0
            case .floatingButton:
                if let moved = self.dragged[key] {
                    let size = self.buttonSize(item.overlay, view: view)
                    view.bounds = CGRect(origin: .zero, size: size)
                    view.center = moved
                    view.layer.cornerRadius = CGFloat(item.overlay.cornerRadius ?? min(size.width, size.height) / 2.0)
                    continue
                }
                let size = self.buttonSize(item.overlay, view: view)
                let origin = self.origin(for: item.overlay, size: size, insets: insets)
                view.frame = CGRect(origin: origin, size: size)
                view.layer.cornerRadius = CGFloat(item.overlay.cornerRadius ?? min(size.width, size.height) / 2.0)
            }
        }
    }

    private func buttonSize(_ overlay: AorusPluginOverlay, view: UIView) -> CGSize {
        let intrinsic = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let width = overlay.width.map { CGFloat($0) } ?? max(CGFloat(AorusPluginOverlay.minimumSide), min(CGFloat(AorusPluginOverlay.maximumSide), intrinsic.width + 8.0))
        let height = overlay.height.map { CGFloat($0) } ?? max(44.0, min(CGFloat(AorusPluginOverlay.maximumSide), intrinsic.height + 8.0))
        return CGSize(width: width, height: height)
    }

    private func origin(for overlay: AorusPluginOverlay, size: CGSize, insets: UIEdgeInsets) -> CGPoint {
        // The bottom edge sits above the input panel rather than on top of it. A plugin that
        // wants it elsewhere says so with an offset, which is how the documented example
        // reaches the middle of the history.
        let bottomLimit = self.bounds.height - insets.bottom - 68.0 - size.height - aorusOverlayMargin
        let topLimit = insets.top + aorusOverlayMargin
        let leftLimit = insets.left + aorusOverlayMargin
        let rightLimit = self.bounds.width - insets.right - aorusOverlayMargin - size.width
        var x: CGFloat
        var y: CGFloat
        switch overlay.position {
        case .topLeft:
            x = leftLimit; y = topLimit
        case .topRight:
            x = rightLimit; y = topLimit
        case .bottomLeft:
            x = leftLimit; y = bottomLimit
        case .bottomRight:
            x = rightLimit; y = bottomLimit
        case .centerLeft:
            x = leftLimit; y = (self.bounds.height - size.height) / 2.0
        case .centerRight:
            x = rightLimit; y = (self.bounds.height - size.height) / 2.0
        case .center:
            x = (self.bounds.width - size.width) / 2.0; y = (self.bounds.height - size.height) / 2.0
        }
        x += CGFloat(overlay.offsetX)
        y += CGFloat(overlay.offsetY)
        // Clamped last, so an offset can move a button anywhere inside the chat but not off
        // the edge of it.
        x = min(max(insets.left, x), max(insets.left, self.bounds.width - insets.right - size.width))
        y = min(max(insets.top, y), max(insets.top, self.bounds.height - insets.bottom - size.height))
        return CGPoint(x: x, y: y)
    }
}

private final class AorusPluginOverlayButton: UIButton {
    var pluginId: String = ""
    var overlayId: String = ""
}

private final class AorusPluginOverlayPanel: UIView {
    var pluginId: String = ""
    var overlayId: String = ""

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    init() {
        super.init(frame: .zero)
        self.iconView.contentMode = .scaleAspectFit
        self.titleLabel.numberOfLines = 1
        self.subtitleLabel.numberOfLines = 1
        self.addSubview(self.iconView)
        self.addSubview(self.titleLabel)
        self.addSubview(self.subtitleLabel)
    }

    required init?(coder: NSCoder) {
        preconditionFailure("AorusPluginOverlayPanel is created in code")
    }

    func configure(title: String, subtitle: String?, icon: String?, titleColor: UIColor, fontSize: CGFloat) {
        self.titleLabel.text = title
        self.titleLabel.textColor = titleColor
        self.titleLabel.font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        self.subtitleLabel.text = subtitle
        self.subtitleLabel.textColor = titleColor.withAlphaComponent(0.65)
        self.subtitleLabel.font = UIFont.systemFont(ofSize: max(11.0, fontSize - 2.0), weight: .regular)
        self.subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        if let icon = icon, let image = UIImage(systemName: icon) {
            self.iconView.image = image.withRenderingMode(.alwaysTemplate)
            self.iconView.tintColor = titleColor
            self.iconView.isHidden = false
        } else {
            self.iconView.image = nil
            self.iconView.isHidden = true
        }
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let padding: CGFloat = 12.0
        var left = padding
        if !self.iconView.isHidden {
            let side: CGFloat = 22.0
            self.iconView.frame = CGRect(x: left, y: (self.bounds.height - side) / 2.0, width: side, height: side)
            left += side + 10.0
        }
        let width = max(0.0, self.bounds.width - left - padding)
        if self.subtitleLabel.isHidden {
            self.titleLabel.frame = CGRect(x: left, y: 0.0, width: width, height: self.bounds.height)
        } else {
            let half = self.bounds.height / 2.0
            self.titleLabel.frame = CGRect(x: left, y: half - 19.0, width: width, height: 20.0)
            self.subtitleLabel.frame = CGRect(x: left, y: half, width: width, height: 18.0)
        }
    }
}
