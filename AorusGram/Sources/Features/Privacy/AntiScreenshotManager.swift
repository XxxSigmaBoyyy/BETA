import UIKit
import Display

// Anti-screenshot / anti-screen-recording.
//
// iOS treats anything inside a `UITextField`'s private secure-canvas layer
// (created when `isSecureTextEntry = true`) as protected: it renders normally
// to the user's display but is BLANK in screenshots, screen recordings,
// AirPlay mirroring and the app-switcher snapshot.
//
// Design — CONTINUOUS protection:
//   The previous version installed the protection only while a recording was
//   active or while the app was resigning active. That left ordinary
//   screenshots unprotected (there is no "screenshot is about to happen"
//   event) and the install/uninstall churn on every app switch corrupted the
//   layer tree, producing a black screen on return.
//
//   This version installs the protection ONCE, as soon as the window is ready,
//   and keeps it installed for the whole lifetime of the feature. Screenshots,
//   recordings and the app-switcher snapshot are therefore all covered, and
//   because the layer tree is never torn down on background/foreground there
//   is no black-screen regression. On every foreground we only VERIFY the
//   protection is still attached and rebuild it if iOS tore it down.
public final class AntiScreenshotManager {
    public static let shared = AntiScreenshotManager()
    private init() {}

    private var isEnabled = false
    private var brandingWindow: UIWindow?
    private var protectedField: UITextField?
    private weak var protectedRootView: UIView?
    private weak var originalSuperlayer: CALayer?
    private var retryCount = 0

    // MARK: - Lifecycle

    public func enable() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.enable()
            }
            return
        }
        guard !isEnabled else { return }
        isEnabled = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didTakeScreenshot),
                       name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidBecomeActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
        retryCount = 0
        // A settings toggle happens with an existing key window, so install in
        // the same run-loop turn. The bounded retry remains for early startup.
        verifyAndInstall()
    }

    public func disable() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.disable()
            }
            return
        }
        guard isEnabled || protectedField != nil || brandingWindow != nil else { return }
        isEnabled = false
        NotificationCenter.default.removeObserver(self)
        // Remove the secure canvas immediately. Deferring this to the next
        // run-loop turn made the switch appear unreliable and could leave a
        // stale installation owned by an earlier module singleton.
        uninstall()
    }

    // MARK: - Events

    @objc private func didTakeScreenshot() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    // Continuous protection is never torn down on background/foreground — that
    // teardown is exactly what produced the black screen. Here we only confirm
    // the protection survived (iOS can rebuild layer trees) and reinstall it if
    // it was knocked out or the root view controller was replaced.
    @objc private func appDidBecomeActive() {
        guard isEnabled else { return }
        retryCount = 0
        scheduleVerify(delay: 0.0)
    }

    // MARK: - Install / verify

    private func scheduleVerify(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.verifyAndInstall()
        }
    }

    private func verifyAndInstall() {
        guard isEnabled else { return }
        guard let keyWindow = findKeyWindow(),
              let rootView = keyWindow.rootViewController?.view,
              let scene = keyWindow.windowScene else {
            // Window not ready yet — retry a bounded number of times.
            if retryCount < 30 {
                retryCount += 1
                scheduleVerify(delay: 0.5)
            }
            return
        }

        // Already protecting the current root view and still attached — the
        // secure field auto-resizes itself, so there is nothing to rebuild.
        if let field = protectedField,
           field.superview === keyWindow,
           protectedRootView === rootView,
           rootView.layer.superlayer != nil {
            brandingWindow?.isHidden = false
            return
        }

        // First run, or the protection was torn down, or the root view
        // controller changed — rebuild from a clean state.
        uninstall()
        install(keyWindow: keyWindow, rootView: rootView, scene: scene)
    }

    private func install(keyWindow: UIWindow, rootView: UIView, scene: UIWindowScene) {
        guard let parentLayer = rootView.layer.superlayer else { return }

        // 1. Branding window behind the main window — visible only to capture.
        let brand = UIWindow(windowScene: scene)
        brand.frame = keyWindow.bounds
        brand.windowLevel = UIWindow.Level.normal - 100
        brand.isUserInteractionEnabled = false
        brand.backgroundColor = .black
        let vc = UIViewController()
        vc.view = makeBrandingView(frame: brand.bounds)
        brand.rootViewController = vc
        brand.isHidden = false
        brandingWindow = brand

        // 2. Full-screen transparent secure text field. Its private canvas
        //    layer is excluded from every capture path by iOS.
        let field = UITextField()
        field.isSecureTextEntry = true
        field.frame = keyWindow.bounds
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.textColor = .clear
        field.tintColor = .clear
        field.isUserInteractionEnabled = false
        keyWindow.addSubview(field)
        keyWindow.bringSubviewToFront(field)

        guard let secureLayer = field.layer.sublayers?.last else {
            field.removeFromSuperview()
            brand.isHidden = true
            brandingWindow = nil
            return
        }

        // 3. Re-parent the root view's layer into the secure canvas. The user
        //    keeps seeing the app normally (Core Animation renders the layer),
        //    but every capture pipeline blanks the canvas and records the
        //    branding window underneath instead.
        originalSuperlayer = parentLayer
        protectedRootView = rootView
        secureLayer.addSublayer(rootView.layer)

        protectedField = field
    }

    private func uninstall() {
        if let rootView = protectedRootView {
            // Return the root layer to a visible parent. Prefer the captured
            // original superlayer; fall back to the key window's own layer so a
            // teardown can never leave the screen black.
            let target = originalSuperlayer ?? findKeyWindow()?.layer
            if let target = target, rootView.layer.superlayer !== target {
                target.insertSublayer(rootView.layer, at: 0)
            }
        }
        protectedField?.removeFromSuperview()
        protectedField = nil
        protectedRootView = nil
        originalSuperlayer = nil
        brandingWindow?.isHidden = true
        brandingWindow = nil
    }

    // MARK: - Helpers

    private func findKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let scene = active else { return nil }
        return scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    }

    private func makeBrandingView(frame: CGRect) -> UIView {
        let container = UIView(frame: frame)
        container.backgroundColor = .black

        let icon = UIImageView(image: UIImage(systemName: "lock.shield.fill"))
        icon.tintColor = UIColor(red: 1.0, green: 0.42, blue: 0.0, alpha: 1.0)
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let brand = UILabel()
        brand.text = "AORUSGRAM"
        brand.font = Font.heavy(40)
        brand.textAlignment = .center
        brand.textColor = .white
        brand.translatesAutoresizingMaskIntoConstraints = false

        let handle = UILabel()
        handle.text = "Защищённый контент"
        handle.font = Font.medium(15)
        handle.textAlignment = .center
        handle.textColor = UIColor(white: 0.55, alpha: 1.0)
        handle.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(icon)
        container.addSubview(brand)
        container.addSubview(handle)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -70),
            icon.widthAnchor.constraint(equalToConstant: 72),
            icon.heightAnchor.constraint(equalToConstant: 72),

            brand.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            brand.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 24),

            handle.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            handle.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 10),
        ])

        return container
    }
}
