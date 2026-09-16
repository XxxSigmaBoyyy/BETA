import UIKit
import Display

// Key activation screen. Owns the POST /license/activate call, loading / error
// states and error-code mapping; reports the activated license up via onActivated.
//
// Visually polished: animated duck illustration, a focus-reactive key field (accent
// glow on edit), an error shake, and a soft staggered entrance.
final class ActivateKeyController: SubscriptionBaseController {
    // Set by the coordinator; falls back to the cached id.
    var telegramUserId: Int64?
    var onActivated: ((LicenseResponse) -> Void)?

    private let duck = SubscriptionDuckView(duck: .purchase)
    private let field = UITextField()
    private let fieldContainer = UIView()
    private let errorLabel = SubscriptionStyle.body("", color: SubscriptionStyle.destructive, size: 14)
    private let primary = SubscriptionStyle.primaryButton(SubL10n.activate)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var didAnimateEntrance = false
    private var didPrepareEntrance = false

    override func viewDidLoad() {
        super.viewDidLoad()

        addContent(SubscriptionStyle.centered(duck, size: 150))
        addSpacing(2)
        addContent(SubscriptionStyle.title(SubL10n.activateTitle))
        addContent(SubscriptionStyle.body(SubL10n.activateBody))
        addSpacing(8)

        buildField()
        addContent(fieldContainer)

        errorLabel.isHidden = true
        addContent(errorLabel)

        primary.addTarget(self, action: #selector(activateTapped), for: .touchUpInside)
        addBottomButton(primary)

        spinner.hidesWhenStopped = true
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        primary.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: primary.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: primary.centerYAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHide),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    private func buildField() {
        fieldContainer.translatesAutoresizingMaskIntoConstraints = false
        fieldContainer.backgroundColor = SubscriptionStyle.card
        fieldContainer.layer.cornerRadius = 14
        fieldContainer.layer.cornerCurve = .continuous
        fieldContainer.layer.borderWidth = 1.0
        fieldContainer.layer.borderColor = UIColor(white: 0.22, alpha: 1.0).cgColor
        // Accent glow (off until focused).
        fieldContainer.layer.shadowColor = SubscriptionStyle.accent.cgColor
        fieldContainer.layer.shadowRadius = 10
        fieldContainer.layer.shadowOffset = .zero
        fieldContainer.layer.shadowOpacity = 0
        fieldContainer.heightAnchor.constraint(equalToConstant: 56).isActive = true

        field.attributedPlaceholder = NSAttributedString(
            string: "AORUS-XXXX-XXXX-XXXX",
            attributes: [.foregroundColor: UIColor(white: 0.4, alpha: 1.0)])
        field.font = Font.semiboldMonospace(18)
        field.textColor = SubscriptionStyle.primaryText
        field.tintColor = SubscriptionStyle.accent
        field.textAlignment = .center
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        fieldContainer.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor, constant: -14),
            field.topAnchor.constraint(equalTo: fieldContainer.topAnchor),
            field.bottomAnchor.constraint(equalTo: fieldContainer.bottomAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Put the content in its hidden start state BEFORE the screen is shown, so the
        // animation never lags behind a fully-rendered frame.
        prepareEntranceState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animateEntrance()
        field.becomeFirstResponder()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Animations

    private func prepareEntranceState() {
        guard !didPrepareEntrance else { return }
        didPrepareEntrance = true
        for (i, v) in contentStack.arrangedSubviews.enumerated() {
            v.alpha = 0
            // The duck (first item) pops in with a scale; everything else rises.
            v.transform = (i == 0)
                ? CGAffineTransform(scaleX: 0.5, y: 0.5)
                : CGAffineTransform(translationX: 0, y: 24)
        }
    }

    private func animateEntrance() {
        guard didPrepareEntrance, !didAnimateEntrance else { return }
        didAnimateEntrance = true
        for (i, v) in contentStack.arrangedSubviews.enumerated() {
            let delay = 0.07 * Double(i)
            let damping: CGFloat = (i == 0) ? 0.6 : 0.84   // bouncier pop for the duck
            UIView.animate(withDuration: 0.58, delay: delay,
                           usingSpringWithDamping: damping, initialSpringVelocity: 0.5,
                           options: [.curveEaseOut, .allowUserInteraction], animations: {
                v.alpha = 1
                v.transform = .identity
            })
        }
    }

    private func setFieldFocused(_ focused: Bool) {
        UIView.animate(withDuration: 0.22) {
            self.fieldContainer.layer.borderColor = (focused ? SubscriptionStyle.accent
                                                             : UIColor(white: 0.22, alpha: 1.0)).cgColor
            self.fieldContainer.layer.shadowOpacity = focused ? 0.45 : 0
            self.fieldContainer.layer.borderWidth = focused ? 1.5 : 1.0
        }
    }

    private func shakeField() {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [-10, 10, -8, 8, -5, 5, 0]
        shake.duration = 0.45
        shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fieldContainer.layer.add(shake, forKey: "shake")
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    // MARK: - Input

    @objc private func editingChanged() {
        let upper = (field.text ?? "").uppercased()
        if upper != field.text { field.text = upper }
        if !errorLabel.isHidden {
            UIView.animate(withDuration: 0.2, animations: { self.errorLabel.alpha = 0 }, completion: { _ in
                self.errorLabel.isHidden = true
                self.errorLabel.alpha = 1
            })
        }
    }

    @objc private func keyboardChange(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let overlap = max(0, view.bounds.height - view.convert(frame, from: nil).origin.y)
        scrollView.contentInset.bottom = overlap
        scrollView.verticalScrollIndicatorInsets.bottom = overlap
    }

    @objc private func keyboardHide() {
        scrollView.contentInset.bottom = 0
        scrollView.verticalScrollIndicatorInsets.bottom = 0
    }

    // MARK: - Activation

    @objc private func activateTapped() {
        let code = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { shakeField(); return }
        view.endEditing(true)
        setLoading(true)
        errorLabel.isHidden = true

        let uid = telegramUserId ?? LicenseStore.shared.telegramUserId
        LicenseAPIClient.shared.activate(code: code, telegramUserId: uid) { [weak self] result in
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
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        self.onActivated?(response)
                    } else {
                        self.showError(SubL10n.errKeyNotFound)
                    }
                case .failure(let error):
                    self.showError(self.message(for: error))
                }
            }
        }
    }

    private func showError(_ text: String) {
        errorLabel.text = text
        errorLabel.isHidden = false
        shakeField()
    }

    private func setLoading(_ loading: Bool) {
        if loading {
            spinner.startAnimating()
            primary.setTitle("", for: .normal)
            primary.isEnabled = false
            field.isEnabled = false
        } else {
            spinner.stopAnimating()
            primary.setTitle(SubL10n.activate, for: .normal)
            primary.isEnabled = true
            field.isEnabled = true
        }
    }

    private func message(for error: LicenseError) -> String {
        switch error {
        case .server(let code):
            switch code {
            case "code_not_found":              return SubL10n.errKeyNotFound
            case "code_not_active", "code_already_used": return SubL10n.errKeyUsed
            case "code_expired":                return SubL10n.errKeyExpired
            case "code_issued_to_another_user": return SubL10n.errKeyAnotherAccount
            case "rate_limited":                return SubL10n.errRateLimited
            default:                            return SubL10n.errActivateGeneric
            }
        case .network:        return SubL10n.errNetwork
        case .notProvisioned: return SubL10n.errService
        case .http, .decode:  return SubL10n.errActivateGeneric
        }
    }
}

extension ActivateKeyController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) { setFieldFocused(true) }
    func textFieldDidEndEditing(_ textField: UITextField) { setFieldFocused(false) }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        activateTapped()
        return true
    }
}
