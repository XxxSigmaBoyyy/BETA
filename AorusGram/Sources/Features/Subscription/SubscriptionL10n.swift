import Foundation

// Localization for the whole subscription / license UI.
//
// Rule (per product): Russian if the device's preferred language is Russian,
// English for every other language. No per-string .strings files — the subscription
// layer is self-contained in the AorusGram core module, so we keep the two variants
// inline and pick at runtime.
enum SubL10n {
    /// The language AorusGram must speak: the one selected inside Telegram.
    ///
    /// The device language is a fallback for one situation only — before Telegram has a
    /// language at all, i.e. a fresh install where the trial screen appears before an
    /// account exists. Once Telegram knows its language, AppDelegate's presentationData
    /// observer publishes it under "aorusgram_lang_code" and every screen follows it, so
    /// changing the language in Telegram changes these screens too.
    ///
    /// The AorusGram core module cannot import AorusGramUI, so the shared key is read
    /// directly — the same idiom AorusPerformanceHUDManager and AccountBackupManager use.
    static var telegramLanguageCode: String? {
        guard let code = UserDefaults.standard.string(forKey: "aorusgram_lang_code"),
              !code.isEmpty else {
            return nil
        }
        return code.lowercased()
    }

    static var isRU: Bool {
        let lang = (telegramLanguageCode
                    ?? Locale.preferredLanguages.first
                    ?? Bundle.main.preferredLocalizations.first
                    ?? "en").lowercased()
        return lang.hasPrefix("ru")
    }

    /// Which of the supported languages Telegram is set to. Same rule as isRU: Telegram
    /// first, device only when Telegram has no language yet.
    static var lang: SubLanguage {
        let raw = (telegramLanguageCode
                   ?? Locale.preferredLanguages.first
                   ?? Bundle.main.preferredLocalizations.first
                   ?? "en").lowercased()
        // The full code first, then the part before the separator: zh-hans and zh-hant are
        // different languages, so collapsing them to "zh" would show the wrong script.
        let normalized = raw.replacingOccurrences(of: "_", with: "-")
        if let exact = SubLanguage(rawValue: normalized) {
            return exact
        }
        let base = String(normalized.prefix(while: { $0 != "-" }))
        return SubLanguage(rawValue: base) ?? .en
    }

    /// Russian and English are inline at every call site; other languages come from
    /// SubscriptionL10nTable keyed by the English string. A missing entry falls back to
    /// English, which is always safe to show.
    @inline(__always)
    static func t(_ ru: String, _ en: String) -> String {
        switch lang {
        case .ru: return ru
        case .en: return en
        default: return SubscriptionL10nTable.translation(of: en, into: lang) ?? en
        }
    }

    /// Mandatory-update copy is kept in its own compact table. It is intentionally not
    /// mixed into the long subscription phrasebook: the lock screen must remain fully
    /// localised even though it is unavailable to older builds.
    @inline(__always)
    static func update(_ ru: String, _ en: String) -> String {
        switch lang {
        case .ru: return ru
        case .en: return en
        default: return SubscriptionL10nTable.mandatoryUpdateTranslation(of: en, into: lang) ?? en
        }
    }

    // MARK: Trial welcome
    static var welcomeTitle: String { t("Добро пожаловать в AorusGram", "Welcome to AorusGram") }
    static var welcomeBody1: String { t("Вам доступен пробный период на 3 дня.", "You have a 3-day free trial.") }
    static var welcomeBody2: String { t("После окончания потребуется ключ подписки.", "After it ends you’ll need a subscription key.") }
    static var startTrial: String { t("Активировать 3 дня", "Start 3-day trial") }
    static var haveKey: String { t("У меня уже есть ключ", "I already have a key") }

    // MARK: Expired / locked
    static var expiredTitle: String { t("Пробный период закончился", "Your trial has ended") }
    static var expiredBody: String { t("Чтобы продолжить пользоваться AorusGram, введите ключ подписки.",
                                       "To keep using AorusGram, enter a subscription key.") }
    static var buyKey: String { t("Купить ключ", "Buy a key") }
    static var enterKey: String { t("Ввести ключ", "Enter key") }
    static var keyHint: String { t("Ключ можно получить в официальном боте AorusGram.",
                                   "You can get a key from the official AorusGram bot.") }
    static var bannedTitle: String { t("Устройство заблокировано", "Device blocked") }
    static var bannedBody: String { t("Доступ к AorusGram ограничен.", "Access to AorusGram is restricted.") }
    static var noConnTitle: String { t("Нет соединения", "No connection") }
    static var noConnBody: String { t("Не удалось проверить подписку. Проверьте интернет и попробуйте снова.",
                                      "Couldn’t verify your subscription. Check your internet and try again.") }
    static var retry: String { t("Повторить", "Retry") }

    // MARK: Mandatory update
    static var outdatedTitle: String { update("Ваша версия приложения устарела", "This version is no longer supported") }
    static var outdatedBody: String { update("Чтобы продолжить пользоваться AorusGram, установите последнюю версию.",
                                        "Install the latest AorusGram version to continue.") }
    static var updateApp: String { update("Обновить", "Update") }
    static var openChannel: String { update("Перейти в канал", "Open channel") }
    static var updateTitle: String { update("Обновление AorusGram", "AorusGram Update") }
    static var preparingUpdate: String { update("Последняя версия", "Latest version") }
    static var checkingUpdate: String { update("Проверяем доступное обновление…", "Checking for an update…") }
    static var connecting: String { update("Подключение…", "Connecting…") }
    static var downloadComplete: String { update("Загрузка завершена", "Download complete") }
    static var updateFailed: String { update("Не удалось загрузить обновление. Проверьте соединение и повторите попытку.",
                                        "Couldn’t download the update. Check your connection and try again.") }
    static var openInFiles: String { update("Перейти", "Continue") }
    static func downloadingVersion(_ version: String) -> String {
        update("Загрузка версии %@", "Downloading version %@").replacingOccurrences(of: "%@", with: version)
    }
    static func downloadSpeed(_ speed: String) -> String {
        update("Скорость: %@/с", "Speed: %@/s").replacingOccurrences(of: "%@", with: speed)
    }

    // MARK: Activate key
    static var activateTitle: String { t("Введите ключ", "Enter key") }
    static var activateBody: String { t("Введите ключ подписки, полученный в боте AorusGram.",
                                        "Enter the subscription key you got from the AorusGram bot.") }
    static var activate: String { t("Активировать", "Activate") }

    // MARK: Premium / management
    static var manageTitle: String { t("Управление подпиской", "Manage subscription") }
    static var premiumTitle: String { t("AorusGram Premium", "AorusGram Premium") }
    static var statusActive: String { t("Подписка активна", "Subscription active") }
    static var statusTrial: String { t("Пробный период", "Free trial") }
    static var planLabel: String { t("Тариф", "Plan") }
    static var renew: String { t("Продлить подписку", "Renew subscription") }
    static var enterAnotherKey: String { t("Ввести другой ключ", "Enter another key") }
    // Interpolated up front, the value reaching t() would be "Active until 5 Aug 2026" —
    // different on every render and impossible to use as a translation key. The template is
    // translated first and the date substituted after, so the key stays stable.
    static func activeUntil(_ date: String) -> String {
        return t("Активна до %@", "Active until %@").replacingOccurrences(of: "%@", with: date)
    }

    static func trialUntil(_ date: String) -> String {
        return t("Пробный период до %@", "Trial until %@").replacingOccurrences(of: "%@", with: date)
    }

    // MARK: Activation confirmation (deep link)
    static var confirmTitle: String { t("Подтверждение активации", "Activate subscription") }
    static var confirmBody: String { t("Активировать подписку этим ключом?", "Activate your subscription with this key?") }
    static var keyLabel: String { t("Ключ", "Key") }
    static var cancel: String { t("Отмена", "Cancel") }
    static var close: String { t("Закрыть", "Close") }
    static var ok: String { t("Понятно", "OK") }
    static var activationFailedTitle: String { t("Не удалось активировать", "Activation failed") }
    static var activationDoneTitle: String { t("Готово!", "All set!") }
    static var activationDoneBody: String { t("Подписка активирована.", "Your subscription is active.") }

    // MARK: Settings
    static var settingsSubscription: String { t("Подписка", "Subscription") }

    // MARK: Banners / toasts
    static var bannerTrialActive: String { t("Пробный период активен", "Trial active") }
    static var bannerPaidActive: String { t("Подписка активна", "Subscription active") }
    static var toastTrialActivated: String { t("Пробный период активирован", "Trial activated") }
    static var toastSubActivated: String { t("Подписка активирована", "Subscription activated") }

    // MARK: Pricing (display only)
    static var price: String { t("200 ₽ / месяц", "200 ₽ / month") }

    // MARK: Errors
    static var errKeyNotFound: String { t("Ключ не найден", "Key not found") }
    static var errKeyUsed: String { t("Ключ уже использован", "Key already used") }
    static var errKeyExpired: String { t("Срок действия ключа истёк", "This key has expired") }
    static var errKeyAnotherAccount: String { t("Ключ выдан другому аккаунту", "This key was issued to another account") }
    static var errRateLimited: String { t("Слишком много попыток. Попробуйте позже.", "Too many attempts. Try again later.") }
    static var errActivateGeneric: String { t("Не удалось активировать ключ", "Couldn’t activate the key") }
    static var errNetwork: String { t("Не удалось подключиться. Проверьте интернет.", "Couldn’t connect. Check your internet.") }
    static var errService: String { t("Сервис временно недоступен. Попробуйте позже.", "Service temporarily unavailable. Try again later.") }
    static var errActivateRetry: String { t("Не удалось активировать. Попробуйте позже.", "Couldn’t activate. Try again later.") }

    // MARK: Remaining-time phrasing (RU plural / EN)
    static func remaining(days: Int) -> String {
        if days <= 0 { return t("Заканчивается сегодня", "Ends today") }
        if isRU {
            let word = ruDayWord(days)
            let verb = (word == "день") ? "остался" : "осталось"
            return "\(verb) \(days) \(word)"
        }
        return days == 1 ? "1 day left" : "\(days) days left"
    }

    static func daysShort(_ days: Int) -> String {
        if days <= 0 { return t("меньше дня", "less than a day") }
        if isRU { return "\(days) \(ruDayWord(days))" }
        return days == 1 ? "1 day" : "\(days) days"
    }

    private static func ruDayWord(_ n: Int) -> String {
        let mod100 = n % 100
        if mod100 >= 11 && mod100 <= 14 { return "дней" }
        switch n % 10 {
        case 1: return "день"
        case 2, 3, 4: return "дня"
        default: return "дней"
        }
    }
}
