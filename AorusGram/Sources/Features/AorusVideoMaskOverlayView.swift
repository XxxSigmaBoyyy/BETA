import Foundation
import UIKit

/// Lightweight local-preview companion for the real frame compositor.
/// It reuses the compositor's cached artwork and only animates one image layer;
/// no Vision or Core Image work is duplicated on the main thread.
@objcMembers
public final class AorusVideoMaskOverlayView: UIView {
    private let imageView = UIImageView()
    private var frameAspect: CGFloat = 1.0
    private var normalizedRect = CGRect.zero
    private var roll: CGFloat = 0.0
    private var yaw: CGFloat = 0.0
    private var pitch: CGFloat = 0.0
    private var mirrored = false
    private var preset = ""
    private var observers: [NSObjectProtocol] = []

    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.isOpaque = false
        self.layer.isOpaque = false
        self.clipsToBounds = true
        self.backgroundColor = .clear
        self.imageView.contentMode = .scaleToFill
        self.imageView.isOpaque = false
        self.imageView.layer.isOpaque = false
        self.imageView.backgroundColor = .clear
        self.imageView.layer.allowsEdgeAntialiasing = true
        self.imageView.layer.shouldRasterize = false
        self.addSubview(self.imageView)

        self.observers.append(NotificationCenter.default.addObserver(
            forName: .aorusVideoMaskPreviewUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.update(notification)
        })
        self.observers.append(NotificationCenter.default.addObserver(
            forName: .aorusVideoMaskPreviewHidden,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setMaskHidden(true, animated: true)
        })
        self.observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("aorusgram_settings_changed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshEnabledState()
        })
        self.observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("aorusgram.licenseLockChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshEnabledState()
        })
        self.refreshEnabledState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        self.updateMaskFrame(animated: false)
    }

    public func refreshEnabledState() {
        let enabled = AorusLicenseAccess.isAllowed
            && UserDefaults.standard.bool(forKey: AorusVideoMaskProcessor.enabledKey)
        if !enabled {
            self.setMaskHidden(true, animated: false)
        }
    }

    private func update(_ notification: Notification) {
        guard AorusLicenseAccess.isAllowed,
              UserDefaults.standard.bool(forKey: AorusVideoMaskProcessor.enabledKey),
              let info = notification.userInfo,
              let rect = (info["rect"] as? NSValue)?.cgRectValue,
              let preset = info["preset"] as? String else {
            self.setMaskHidden(true, animated: false)
            return
        }

        if self.preset != preset || self.imageView.image == nil {
            guard let image = AorusVideoMaskProcessor.shared.previewImage(for: preset) else {
                self.setMaskHidden(true, animated: false)
                return
            }
            self.preset = preset
            self.imageView.image = image
        }

        self.normalizedRect = rect
        self.frameAspect = CGFloat((info["aspect"] as? NSNumber)?.doubleValue ?? 1.0)
        self.roll = CGFloat((info["roll"] as? NSNumber)?.doubleValue ?? 0.0)
        self.yaw = CGFloat((info["yaw"] as? NSNumber)?.doubleValue ?? 0.0)
        self.pitch = CGFloat((info["pitch"] as? NSNumber)?.doubleValue ?? 0.0)
        self.mirrored = (info["mirrored"] as? Bool) ?? false
        self.setMaskHidden(false, animated: self.imageView.alpha < 0.01)
        // FacePose is already smoothed in the processor. A second UIView
        // animation here makes the local mask trail behind the outgoing frame.
        self.updateMaskFrame(animated: false)
    }

    private func updateMaskFrame(animated: Bool) {
        guard self.bounds.width > 1.0, self.bounds.height > 1.0, self.normalizedRect.width > 0.0 else {
            return
        }
        let sourceSize = CGSize(width: max(self.frameAspect, 0.01), height: 1.0)
        let scale = max(self.bounds.width / sourceSize.width, self.bounds.height / sourceSize.height)
        let renderedSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = CGPoint(
            x: (self.bounds.width - renderedSize.width) * 0.5,
            y: (self.bounds.height - renderedSize.height) * 0.5
        )
        var rect = self.normalizedRect
        if self.mirrored {
            rect.origin.x = 1.0 - rect.maxX
        }
        let targetFrame = CGRect(
            x: origin.x + rect.minX * renderedSize.width,
            y: origin.y + rect.minY * renderedSize.height,
            width: rect.width * renderedSize.width,
            height: rect.height * renderedSize.height
        )
        let updates = {
            self.imageView.bounds = CGRect(origin: .zero, size: targetFrame.size)
            self.imageView.center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            // Keep the local mask in the same 2D compositor as the native
            // AVCaptureVideoPreviewLayer. A perspective CATransform3D forces
            // Core Animation to flatten the live camera surface and can leave
            // a frozen snapshot while a face is tracked. The outgoing frame
            // retains the full perspective transform in the CI compositor.
            var transform = CGAffineTransform.identity
            if self.mirrored {
                transform = transform.scaledBy(x: -1.0, y: 1.0)
            }
            transform = transform.rotated(by: self.mirrored ? self.roll : -self.roll)
            let displayedYaw = self.mirrored ? -self.yaw : self.yaw
            let horizontalScale = max(0.82, 1.0 - abs(displayedYaw) * 0.16)
            let verticalScale = max(0.88, 1.0 - abs(self.pitch) * 0.10)
            transform = transform
                .translatedBy(
                    x: displayedYaw * targetFrame.width * 0.035,
                    y: -self.pitch * targetFrame.height * 0.025
                )
                .scaledBy(x: horizontalScale, y: verticalScale)
            self.imageView.layer.transform = CATransform3DIdentity
            self.imageView.transform = transform
        }
        if animated {
            UIView.animate(
                withDuration: 0.11,
                delay: 0.0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
                animations: updates
            )
        } else {
            UIView.performWithoutAnimation(updates)
        }
    }

    private func setMaskHidden(_ hidden: Bool, animated: Bool) {
        let updates = {
            self.imageView.alpha = hidden ? 0.0 : 1.0
        }
        if animated {
            UIView.animate(withDuration: 0.16, delay: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: updates)
        } else {
            updates()
        }
    }
}

/// C ABI factory keeps the overlay object linked into the static Swift library
/// and lets the Objective-C++ call preview create it without Swift modules.
@_cdecl("AorusVideoMaskCreateOverlayView")
public func AorusVideoMaskCreateOverlayView(_ frame: CGRect) -> UIView {
    return AorusVideoMaskOverlayView(frame: frame)
}
