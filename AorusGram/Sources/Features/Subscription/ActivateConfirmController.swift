import UIKit
import Display

// Activation confirmation screen, opened from an aorusgram://activate?key=… deep link.
//
// Flow: a nice prompt with the duck and the key → "Activate" runs the same
// POST /license/activate as the manual screen → success shows the active state,
// failure (used / invalid key) swaps in the sad duck with the reason.
final class ActivateConfirmController: SubscriptionBaseController {
    var onActivated: (() -> Void)?
    var onClose: (() -> Void)?
    var onEnterKeyManually: (() -> Void)?
    var telegramUserId: Int64?

    private let key: String
    private let spinner = UIActivityIndicatorView(style: .medium)
    private weak var primaryButton: UIButton?
    // The duck/hero of the current state — gets a springy pop on every transition.
    private weak var heroView: UIView?

    init(key: String) {
        self.key = key
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        renderPrompt()
        // Entrance: content slides up + fades, the duck pops in.
        view.layoutIfNeeded()
        animateIn()
    }

    // MARK: - States

    private func clear() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    // Cross-fades the current state out, rebuilds via `build`, then animates the
    // new state in. Used for prompt → success / error so the swap never snaps.
    private func transition(_ build: @escaping () -> Void) {
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn]) {
            self.contentStack.alpha = 0
            self.buttonStack.alpha = 0
        } completion: { _ in
            build()
            self.view.layoutIfNeeded()
            self.animateIn()
        }
    }

    // Slides + fades the content/buttons up and gives the hero duck a spring pop.
    private func animateIn() {
        let movers: [UIView] = [contentStack, buttonStack]
        for v in movers {
            v.alpha = 0
            v.transform = CGAffineTransform(translationX: 0, y: 18)
        }
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.86,
                       initialSpringVelocity: 0.4, options: [.allowUserInteraction]) {
            for v in movers { v.alpha = 1; v.transform = .identity }
        }
        if let hero = heroView {
            hero.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
            UIView.animate(withDuration: 0.6, delay: 0.05, usingSpringWithDamping: 0.6,
                           initialSpringVelocity: 0.7, options: [.allowUserInteraction]) {
                hero.transform = .identity
            }
        }
    }

    private func renderPrompt() {
        clear()
        let hero = SubscriptionStyle.centered(SubscriptionDuckView(duck: .confirm), size: 168)
        heroView = hero
        addContent(hero)
        addSpacing(4)
        addContent(SubscriptionStyle.title(SubL10n.confirmTitle))
        addContent(SubscriptionStyle.body(SubL10n.confirmBody))
        addSpacing(4)
        addContent(SubscriptionStyle.card(keyView()))

        let activate = SubscriptionStyle.primaryButton(SubL10n.activate)
        let cancel = SubscriptionStyle.secondaryButton(SubL10n.cancel)
        activate.addTarget(self, action: #selector(activateTapped), for: .touchUpInside)
        cancel.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        attachSpinner(to: activate)
        primaryButton = activate
        addBottomButton(activate)
        addBottomButton(cancel)
    }

    private func renderSuccess(_ response: LicenseResponse) {
        clear()
        let hero = SubscriptionStyle.centered(SubscriptionDuckView(duck: .boost), size: 168)
        heroView = hero
        addContent(hero)
        addSpacing(4)
        addContent(SubscriptionStyle.title(SubL10n.activationDoneTitle))
        addContent(SubscriptionStyle.body(SubL10n.activationDoneBody))
        if let days = response.daysLeft {
            let info = SubscriptionStyle.body(SubL10n.remaining(days: max(days, 0)),
                                              color: SubscriptionStyle.success, size: 16)
            info.font = Font.semibold(16)
            addSpacing(2)
            addContent(info)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let cont = SubscriptionStyle.primaryButton(SubL10n.close)
        cont.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)
        addBottomButton(cont)
    }

    private func renderError(_ message: String) {
        clear()
        let hero = SubscriptionStyle.centered(SubscriptionDuckView(duck: .error), size: 168)
        heroView = hero
        addContent(hero)
        addSpacing(4)
        addContent(SubscriptionStyle.title(SubL10n.activationFailedTitle))
        addContent(SubscriptionStyle.body(message))
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        let manual = SubscriptionStyle.primaryButton(SubL10n.enterKey)
        let close = SubscriptionStyle.secondaryButton(SubL10n.close)
        manual.addTarget(self, action: #selector(manualTapped), for: .touchUpInside)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addBottomButton(manual)
        addBottomButton(close)
    }

    // MARK: - Views

    private func keyView() -> UIView {
        let caption = UILabel()
        caption.text = SubL10n.keyLabel
        caption.font = Font.regular(13)
        caption.textColor = SubscriptionStyle.secondaryText
        caption.textAlignment = .center

        let value = UILabel()
        value.text = key
        value.font = Font.semiboldMonospace(17)
        value.textColor = SubscriptionStyle.primaryText
        value.textAlignment = .center
        value.adjustsFontSizeToFitWidth = true
        value.minimumScaleFactor = 0.6
        value.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [caption, value])
        stack.axis = .vertical
        stack.spacing = 4
        return stack
    }

    private func attachSpinner(to button: UIButton) {
        spinner.hidesWhenStopped = true
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
    }

    private func setLoading(_ loading: Bool) {
        guard let button = primaryButton else { return }
        if loading {
            spinner.startAnimating()
            button.setTitle("", for: .normal)
            button.isEnabled = false
        } else {
            spinner.stopAnimating()
            button.setTitle(SubL10n.activate, for: .normal)
            button.isEnabled = true
        }
    }

    // MARK: - Actions

    @objc private func activateTapped() {
        setLoading(true)
        let uid = telegramUserId ?? LicenseStore.shared.telegramUserId
        LicenseAPIClient.shared.activate(code: key, telegramUserId: uid) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setLoading(false)
                switch result {
                case .success(let response):
                    if response.status.allowsAppAccess {
                        // A new verdict supersedes any check still in the air; see
                        // `beginLicenseGeneration`.
                        _ = LicenseGate.beginLicenseGeneration()
                        LicenseStore.shared.save(response: response, telegramUserId: uid)
                        self.transition { self.renderSuccess(response) }
                    } else {
                        self.transition { self.renderError(SubL10n.errKeyNotFound) }
                    }
                case .failure(let error):
                    self.transition { self.renderError(ActivateConfirmController.message(for: error)) }
                }
            }
        }
    }

    @objc private func finishTapped() {
        // License is already persisted; tell the gate to unlock.
        onActivated?()
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func manualTapped() { onEnterKeyManually?() }

    // MARK: - Error mapping (mirrors ActivateKeyController)

    static func message(for error: LicenseError) -> String {
        switch error {
        case .server(let code):
            switch code {
            case "code_not_found":               return SubL10n.errKeyNotFound
            case "code_not_active", "code_already_used": return SubL10n.errKeyUsed
            case "code_expired":                 return SubL10n.errKeyExpired
            case "code_issued_to_another_user":  return SubL10n.errKeyAnotherAccount
            case "rate_limited":                 return SubL10n.errRateLimited
            default:                             return SubL10n.errActivateGeneric
            }
        case .network:        return SubL10n.errNetwork
        case .notProvisioned: return SubL10n.errService
        case .http, .decode:  return SubL10n.errActivateGeneric
        }
    }
}
