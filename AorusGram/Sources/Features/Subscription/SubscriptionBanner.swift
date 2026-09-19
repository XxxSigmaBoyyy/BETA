import UIKit
import Display

// Transient UI for the subscription layer:
//  - SubscriptionBanner — a small rounded top card (not an alert/modal) that slides
//    in, holds a few seconds, can be swiped up, and opens the purchase screen on tap.
//    It is hosted in its OWN passthrough UIWindow above everything, so it always
//    renders and reliably receives taps regardless of Telegram's custom main window.
//  - toast — a bottom pill for one-off confirmations ("Подписка активирована").
final class SubscriptionBanner: UIView {
    // Strong owner for the overlay windows — a programmatically-created UIWindow is
    // only kept alive (and composited) while something retains it.
    private static var liveWindows: [UIWindow] = []

    private var onTap: (() -> Void)?
    private var dismissWork: DispatchWorkItem?
    private var topConstraint: NSLayoutConstraint?
    private weak var hostWindow: UIWindow?
    private weak var retainedWindow: UIWindow?

    // MARK: Banner

    static func show(duck: SubscriptionDuck,
                     title: String,
                     subtitle: String,
                     onTap: (() -> Void)?) {
        let window = SubscriptionBanner.makePassthroughWindow()
        guard let host = window.rootViewController?.view else { return }
        liveWindows.append(window)
        let banner = SubscriptionBanner(duck: duck, title: title, subtitle: subtitle, onTap: onTap)
        banner.retainedWindow = window
        banner.present(in: host, window: window)
    }

    private init(duck: SubscriptionDuck, title: String, subtitle: String, onTap: (() -> Void)?) {
        super.init(frame: .zero)
        self.onTap = onTap
        translatesAutoresizingMaskIntoConstraints = false

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 16
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        addSubview(blur)

        let iconView = SubscriptionDuckView(duck: duck, renderSizePx: 120)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 34),
            iconView.heightAnchor.constraint(equalToConstant: 34),
        ])

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = Font.semibold(15)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = Font.regular(13)
        subtitleLabel.textColor = UIColor(white: 0.78, alpha: 1.0)
        subtitleLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = UIColor(white: 0.55, alpha: 1.0)
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [iconView, textStack, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -16),
        ])

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
        swipe.direction = .up
        addGestureRecognizer(swipe)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func present(in host: UIView, window: UIWindow) {
        hostWindow = window
        host.addSubview(self)
        let top = topAnchor.constraint(equalTo: host.topAnchor, constant: -120)
        topConstraint = top
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 10),
            trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            top,
        ])
        host.layoutIfNeeded()

        top.constant = host.safeAreaInsets.top + 6
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82,
                       initialSpringVelocity: 0.4, options: [.curveEaseOut], animations: {
            host.layoutIfNeeded()
        })

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    private func dismiss() {
        dismissWork?.cancel()
        guard let host = superview else { teardownWindow(); return }
        topConstraint?.constant = -160
        UIView.animate(withDuration: 0.3, animations: {
            self.alpha = 0
            host.layoutIfNeeded()
        }, completion: { _ in
            self.removeFromSuperview()
            self.teardownWindow()
        })
    }

    private func teardownWindow() {
        if let window = retainedWindow {
            window.isHidden = true
            window.rootViewController = nil
            SubscriptionBanner.liveWindows.removeAll { $0 === window }
        }
        retainedWindow = nil
        hostWindow = nil
    }

    @objc private func tapped() {
        let action = onTap
        dismiss()
        action?()
    }

    @objc private func swiped() { dismiss() }

    // MARK: Passthrough window

    private static func makePassthroughWindow() -> UIWindow {
        let window: PassthroughWindow
        if let scene = activeScene() {
            window = PassthroughWindow(windowScene: scene)
        } else {
            window = PassthroughWindow(frame: UIScreen.main.bounds)
        }
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.backgroundColor = .clear
        window.rootViewController = PassthroughRootController()
        window.isHidden = false               // visible but NOT key — never steals input focus
        return window
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return active
        }
        return scenes.compactMap { $0 as? UIWindowScene }.first
    }

    // MARK: Toast

    static func toast(duck: SubscriptionDuck, text: String) {
        let window = SubscriptionBanner.makePassthroughWindow()
        guard let host = window.rootViewController?.view else { return }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.alpha = 0

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 18
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        container.addSubview(blur)

        let iconView = SubscriptionDuckView(duck: duck, renderSizePx: 110)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
        ])

        let label = UILabel()
        label.text = text
        label.font = Font.medium(15)
        label.textColor = .white

        let row = UIStackView(arrangedSubviews: [iconView, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(row)

        host.addSubview(container)
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            container.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 24),
            container.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -24),
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -11),
            row.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -18),
        ])

        UIView.animate(withDuration: 0.25, animations: { container.alpha = 1 })
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.3, animations: { container.alpha = 0 }, completion: { _ in
                container.removeFromSuperview()
                window.isHidden = true
                window.rootViewController = nil
            })
        }
    }
}

// A window that lets every touch fall through to the app below EXCEPT touches that
// land on one of its own content subviews (the banner / toast).
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // The root view itself is transparent and non-interactive; only real content wins.
        if hit === rootViewController?.view { return nil }
        return hit
    }
}

private final class PassthroughRootController: UIViewController {
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override func loadView() { view = UIView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}
