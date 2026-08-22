import Foundation

// AorusGram localization.
//
// The client speaks every language Telegram offers and follows whichever
// one is selected inside Telegram. Russian and English are written inline at every call
// site — that is how these files grew and it keeps the two primary languages readable next
// to each other; every other language is looked up in AorusL10nTable by the English string.
// A language with no entry for a key falls back to English, which is always safe to show.
//
// Two consumption paths:
//   1. UI with direct access to PresentationData → AorusL10n(strings.baseLanguageCode).
//   2. Cross-module / context-free call sites (e.g. the chat bubble that renders
//      deleted messages, or TelegramCore postbox markers) → AorusL10n.current,
//      which reads the resolved language persisted by AppDelegate's
//      presentationData observer under the "aorusgram_lang" UserDefaults key.
public enum AorusLang: String, CaseIterable {
    // Russian and English are written inline at every call site; every other language is
    // looked up in AorusL10nTable. The first nineteen are the packs bundled with the app; the
    // rest are the ones Telegram serves from its translation platform.
    case en
    case ru
    case uk
    case es
    case pt
    case de
    case fr
    case tr
    case it
    case pl
    case nl
    case id
    case ms
    case ca
    case be
    case uz
    case ko
    case ar
    case fa
    case kk
    case ja
    case fi
    case he
    case hr
    case cs
    case hu
    case nb
    case ro
    case sr
    case sk
    case sv
    case vi
    // Telegram serves Chinese as two packs; the raw value is the code it sends.
    case zhHans = "zh-hans"
    case zhHant = "zh-hant"

    // Map a Telegram language code to a supported language.
    //
    // The full code is tried first, then the part before the separator. That order matters:
    // Telegram ships Chinese as two separate packs, "zh-hans" and "zh-hant", which are not
    // interchangeable — truncating to "zh" would show one of them the wrong script. The same
    // applies to "pt-br" against "pt-pt". Anything still unmatched falls back to English,
    // which is always safe to show, so a language can be added later without touching this.
    public static func resolve(_ code: String?) -> AorusLang {
        guard let code = code?.lowercased() else { return .en }
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        if let exact = AorusLang(rawValue: normalized) {
            return exact
        }
        let base = String(normalized.prefix(while: { $0 != "-" }))
        return AorusLang(rawValue: base) ?? .en
    }

    // Locale for dates and numbers rendered by AorusGram's own screens, so a German user
    // does not read a Russian-formatted backup date.
    public var localeIdentifier: String {
        switch self {
        case .en: return "en_US"
        case .ru: return "ru_RU"
        case .uk: return "uk_UA"
        case .es: return "es_ES"
        case .pt: return "pt_BR"
        case .de: return "de_DE"
        case .fr: return "fr_FR"
        case .tr: return "tr_TR"
        case .it: return "it_IT"
        case .pl: return "pl_PL"
        case .nl: return "nl_NL"
        case .id: return "id_ID"
        case .ms: return "ms_MY"
        case .ca: return "ca_ES"
        case .be: return "be_BY"
        case .uz: return "uz_UZ"
        case .ko: return "ko_KR"
        case .ar: return "ar_SA"
        case .fa: return "fa_IR"
        case .kk: return "kk_KZ"
        case .ja: return "ja_JP"
        case .fi: return "fi_FI"
        case .he: return "he_IL"
        case .hr: return "hr_HR"
        case .cs: return "cs_CZ"
        case .hu: return "hu_HU"
        case .nb: return "nb_NO"
        case .ro: return "ro_RO"
        case .sr: return "sr_RS"
        case .sk: return "sk_SK"
        case .sv: return "sv_SE"
        case .vi: return "vi_VN"
        case .zhHans: return "zh_Hans_CN"
        case .zhHant: return "zh_Hant_TW"
        }
    }

    // "5 августа 2026 г., 14:03" in Russian, and whatever the equivalent day/month/year
    // ordering is elsewhere, instead of forcing the English layout on every other language.
    public var dateTimeFormat: String {
        if self == .ru {
            return "d MMMM yyyy 'г.,' HH:mm"
        }
        let locale = Locale(identifier: self.localeIdentifier)
        return DateFormatter.dateFormat(fromTemplate: "d MMM yyyy HH:mm", options: 0, locale: locale)
            ?? "MMM d, yyyy, HH:mm"
    }

    // UserDefaults key shared with TelegramCore-injected code (postbox markers).
    public static let storageKey = "aorusgram_lang"

    // The full Telegram base-language code, published by AppDelegate's presentationData
    // observer. `storageKey` above collapses everything to ru/en for the injected call
    // sites; this one keeps the real code so more languages can be added without
    // touching them.
    public static let codeStorageKey = "aorusgram_lang_code"

    // The language selected inside Telegram, or nil before Telegram has one — which only
    // happens on a fresh install with no account yet.
    public static var telegramCode: String? {
        guard let code = UserDefaults.standard.string(forKey: codeStorageKey), !code.isEmpty else {
            return nil
        }
        return code.lowercased()
    }

    // Persist the resolved language so context-free call sites can read it.
    public static func store(_ code: String?) {
        UserDefaults.standard.set(resolve(code).rawValue, forKey: storageKey)
    }

    // Best-effort current language for call sites without PresentationData.
    //
    // Order is deliberate: whatever Telegram is set to wins, then the resolved value the
    // AppDelegate observer persisted, and only if neither exists — a fresh install with no
    // account — the device language.
    public static var current: AorusLang {
        if let code = telegramCode {
            return resolve(code)
        }
        if let raw = UserDefaults.standard.string(forKey: storageKey), let lang = AorusLang(rawValue: raw) {
            return lang
        }
        return resolve(Locale.preferredLanguages.first)
    }
}

// The same ru/en/table rule for call sites that hold their own strings rather than going
// through AorusL10n's properties — the per-screen L10n structs, and the inline
// `isRu ? "…" : "…"` sites they are being converted from. Keeping one function means one
// translation table for the whole module: every English literal in AorusGramUI resolves
// through AorusL10nTable, and the verifier checks all of them against it at once.
public func aorusL(_ ru: String, _ en: String) -> String {
    return aorusL(ru, en, AorusLang.current)
}

public func aorusL(_ ru: String, _ en: String, _ lang: AorusLang) -> String {
    switch lang {
    case .ru:
        return ru
    case .en:
        return en
    default:
        return AorusL10nTable.translation(of: en, into: lang) ?? en
    }
}

// Counted time units ("3 года", "3 years", "3 Jahre"). These cannot live in the string
// table: the table is keyed by an English string and a plural form is chosen by the number,
// not looked up. Russian and Ukrainian take the Slavic one/few/many rule, Turkish never
// inflects after a numeral, and the rest are one/other.
public enum AorusPluralUnit {
    case year
    case month
}

public func aorusPlural(_ n: Int, _ unit: AorusPluralUnit, _ lang: AorusLang = AorusLang.current) -> String {
    let forms: [String]
    switch (lang, unit) {
    case (.ru, .year): forms = ["год", "года", "лет"]
    case (.ru, .month): forms = ["месяц", "месяца", "месяцев"]
    case (.uk, .year): forms = ["рік", "роки", "років"]
    case (.uk, .month): forms = ["місяць", "місяці", "місяців"]
    case (.en, .year): forms = ["year", "years"]
    case (.en, .month): forms = ["month", "months"]
    case (.es, .year): forms = ["año", "años"]
    case (.es, .month): forms = ["mes", "meses"]
    case (.pt, .year): forms = ["ano", "anos"]
    case (.pt, .month): forms = ["mês", "meses"]
    case (.de, .year): forms = ["Jahr", "Jahre"]
    case (.de, .month): forms = ["Monat", "Monate"]
    case (.fr, .year): forms = ["an", "ans"]
    case (.fr, .month): forms = ["mois", "mois"]
    case (.tr, .year): forms = ["yıl"]
    case (.tr, .month): forms = ["ay"]
    case (.it, .year): forms = ["anno", "anni"]
    case (.it, .month): forms = ["mese", "mesi"]
    case (.nl, .year): forms = ["jaar", "jaar"]
    case (.nl, .month): forms = ["maand", "maanden"]
    case (.ca, .year): forms = ["any", "anys"]
    case (.ca, .month): forms = ["mes", "mesos"]
    // Polish and Belarusian take the same one/few/many rule as Russian and Ukrainian.
    case (.pl, .year): forms = ["rok", "lata", "lat"]
    case (.pl, .month): forms = ["miesiąc", "miesiące", "miesięcy"]
    case (.be, .year): forms = ["год", "гады", "гадоў"]
    case (.be, .month): forms = ["месяц", "месяцы", "месяцаў"]
    // Indonesian, Malay, Uzbek, Korean and Persian do not inflect the noun after a numeral.
    case (.id, .year): forms = ["tahun"]
    case (.id, .month): forms = ["bulan"]
    case (.ms, .year): forms = ["tahun"]
    case (.ms, .month): forms = ["bulan"]
    case (.uz, .year): forms = ["yil"]
    case (.uz, .month): forms = ["oy"]
    case (.ko, .year): forms = ["년"]
    case (.ko, .month): forms = ["개월"]
    case (.fa, .year): forms = ["سال"]
    case (.fa, .month): forms = ["ماه"]
    // Arabic has six plural categories; for the 1..~100 range these ages fall in, singular
    // for 1 and the broken plural for the rest is what a reader expects.
    case (.ar, .year): forms = ["سنة", "سنوات"]
    case (.ar, .month): forms = ["شهر", "أشهر"]
    // Kazakh, Chinese and Japanese do not inflect the noun after a numeral either.
    case (.kk, .year): forms = ["жыл"]
    case (.kk, .month): forms = ["ай"]
    case (.zhHans, .year): forms = ["年"]
    case (.zhHans, .month): forms = ["个月"]
    case (.zhHant, .year): forms = ["年"]
    case (.zhHant, .month): forms = ["個月"]
    case (.ja, .year): forms = ["年"]
    case (.ja, .month): forms = ["か月"]
    // Finnish uses the partitive singular after any numeral other than one.
    case (.fi, .year): forms = ["vuosi", "vuotta"]
    case (.fi, .month): forms = ["kuukausi", "kuukautta"]
    case (.he, .year): forms = ["שנה", "שנים"]
    case (.he, .month): forms = ["חודש", "חודשים"]
    // Croatian, Serbian, Czech and Slovak take the same one/few/many rule as Russian.
    case (.hr, .year): forms = ["godina", "godine", "godina"]
    case (.hr, .month): forms = ["mjesec", "mjeseca", "mjeseci"]
    case (.sr, .year): forms = ["година", "године", "година"]
    case (.sr, .month): forms = ["месец", "месеца", "месеци"]
    case (.cs, .year): forms = ["rok", "roky", "let"]
    case (.cs, .month): forms = ["měsíc", "měsíce", "měsíců"]
    case (.sk, .year): forms = ["rok", "roky", "rokov"]
    case (.sk, .month): forms = ["mesiac", "mesiace", "mesiacov"]
    case (.ro, .year): forms = ["an", "ani"]
    case (.ro, .month): forms = ["lună", "luni"]
    case (.nb, .year): forms = ["år", "år"]
    case (.nb, .month): forms = ["måned", "måneder"]
    case (.sv, .year): forms = ["år", "år"]
    case (.sv, .month): forms = ["månad", "månader"]
    // Hungarian and Vietnamese never inflect the noun after a numeral.
    case (.hu, .year): forms = ["év"]
    case (.hu, .month): forms = ["hónap"]
    case (.vi, .year): forms = ["năm"]
    case (.vi, .month): forms = ["tháng"]
    }

    let word: String
    if forms.count == 1 {
        word = forms[0]
    } else if forms.count == 2 {
        word = n == 1 ? forms[0] : forms[1]
    } else {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 {
            word = forms[0]
        } else if mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14) {
            word = forms[1]
        } else {
            word = forms[2]
        }
    }
    return "\(n) \(word)"
}

public struct AorusL10n {
    public let lang: AorusLang

    public init(_ code: String?) {
        self.lang = AorusLang.resolve(code)
    }

    public init(lang: AorusLang) {
        self.lang = lang
    }

    public static var current: AorusL10n {
        return AorusL10n(lang: AorusLang.current)
    }

    // Russian and English are written inline at every call site, which is how this file
    // grew. Additional languages live in AorusL10nTable keyed by the English string, so a
    // new language is one table entry and needs no change here or at any call site. A
    // missing entry falls back to English, which is always safe to display.
    private func t(_ ru: String, _ en: String) -> String {
        return aorusL(ru, en, self.lang)
    }

    // MARK: Settings — section headers
    public var privacyHeader: String { t("ПРИВАТНОСТЬ", "PRIVACY") }
    public var aiHeader: String { t("AI ФУНКЦИИ", "AI FEATURES") }
    public var perfHeader: String { t("ПРОИЗВОДИТЕЛЬНОСТЬ", "PERFORMANCE") }
    public var uiHeader: String { t("ИНТЕРФЕЙС", "INTERFACE") }
    public var antiSpoofHeader: String { t("АНТИ-СПУФ", "ANTI-SPOOF") }
    public var accountBackupHeader: String { t("АККАУНТ", "ACCOUNT") }
    public var aorusCodeHeader: String { t("AORUS CODE", "AORUS CODE") }

    // MARK: Settings — subscription
    public var subscription: String { t("Подписка", "Subscription") }
    public var subscriptionSubtitle: String { t("Управление и продление", "Manage & renew") }

    // MARK: Settings — rows
    public var ghostMode: String { t("Режим призрака", "Ghost Mode") }
    public var deletedMessages: String { t("Удалённые сообщения", "Deleted Messages") }
    public var editedMessages: String { t("Изменённые сообщения", "Edited Messages") }
    public var clearDeletedCache: String { t("Очистить кэш", "Clear Cache") }
    public var antiScreenshot: String { t("Скрытие экрана при записи", "Hide Screen While Recording") }
    public var callRecording: String { t("Запись звонков", "Call Recording") }
    public var voiceTranscription: String { t("Расшифровка голосовых", "Voice to Text") }
    public var translator: String { t("Переводчик", "Translator") }
    public var shareButton: String { t("Кнопка «Поделиться»", "Share Button") }
    public var quickTranslateButton: String { t("Кнопка быстрого перевода", "Quick Translate Button") }
    public var quickTranscribeButton: String { t("Кнопка быстрой транскрипции", "Quick Transcription Button") }
    public var quickShareButton: String { t("Кнопка быстро поделиться", "Quick Share Button") }
    public var videoMessagesHeader: String { t("ВИДЕОСООБЩЕНИЯ", "VIDEO MESSAGES") }
    public var videoMessagesRearCamera: String { t("Запись сразу с задней камеры", "Start Recording With Rear Camera") }
    public var voiceMessagesHeader: String { t("ГОЛОСОВЫЕ СООБЩЕНИЯ", "VOICE MESSAGES") }
    public var deviceMicrophone: String { t("Микрофон устройства", "Device Microphone") }
    public var callsHeader: String { t("ЗВОНКИ", "CALLS") }
    public var wallHeader: String { t("СТЕНА", "WALL") }
    public var wallEnabled: String { t("Включить стену", "Enable Wall") }
    public var wallSettings: String { t("Настройки стены", "Wall Settings") }
    public var wallTitle: String { t("Стена", "Wall") }
    public var wallRefresh: String { t("Обновить", "Refresh") }
    public var wallFilling: String { t("Стена заполняется", "Building Wall") }
    public var wallEmpty: String { t("Новых постов нет", "No New Posts") }
    public var wallShowRecommended: String { t("Показывать рекомендованные каналы", "Show Recommended Channels") }
    public var wallShowRecommendedInfo: String { t("Когда непрочитанных постов мало, стена дополняется свежими публикациями из каналов, рекомендованных Telegram.", "When unread posts run low, Wall adds fresh posts from channels recommended by Telegram.") }
    public var wallExcludedChannelsHeader: String { t("ИСКЛЮЧЁННЫЕ КАНАЛЫ", "EXCLUDED CHANNELS") }
    public var wallExcludeChannel: String { t("Исключить канал", "Exclude Channel") }
    public var wallExcludedChannelsInfo: String { t("Посты из этих каналов не появляются в стене. Смахните канал влево, чтобы вернуть его.", "Posts from these channels do not appear on the Wall. Swipe a channel left to restore it.") }
    public var wallShowArchived: String { t("Показывать посты из архивированных каналов", "Show Posts From Archived Channels") }
    public var wallShowArchivedInfo: String { t("Если выключено, стена собирает непрочитанные посты только из основного списка чатов.", "When disabled, Wall collects unread posts only from the main chat list.") }
    public var autoReply: String { t("Автоответчик", "Auto-Reply") }
    public var downloadAccel: String { t("Ускоритель загрузок", "Download Accelerator") }
    public var maxMediaQuality: String { t("Макс качество медиа", "Max Media Quality") }
    public var antiSpam: String { t("Анти-спам", "Anti-Spam") }
    public var performanceStats: String { t("Показывать статистику", "Show Statistics") }
    public var performanceUptime: String { t("Uptime", "Uptime") }
    public var performanceRAM: String { t("RAM", "RAM") }
    public var performanceCPU: String { t("CPU", "CPU") }
    public var performanceFPS: String { t("FPS", "FPS") }
    public var performanceBattery: String { t("Батарея", "Battery") }
    public var performanceNetwork: String { t("Сеть", "Network") }
    public var performanceDisk: String { t("Диск", "Disk") }
    public var performanceThermal: String { t("Нагрев", "Thermal") }
    public var performanceGraph: String { t("График", "Graph") }
    public var ramAutoClean: String { t("Автоочистка RAM", "Auto-Clean RAM") }
    public var ramCleanInterval: String { t("Интервал очистки RAM", "RAM Cleanup Interval") }
    public var thermalNominal: String { t("Норма", "Normal") }
    public var thermalFair: String { t("Тепло", "Warm") }
    public var thermalSerious: String { t("ГОРЯЧО", "HOT") }
    public var thermalCritical: String { t("Критично", "Critical") }
    public var cacheAutoClean: String { t("Автоочистка кэша", "Auto-Clean Cache") }
    public var cacheInterval: String { t("Интервал очистки", "Cleanup Interval") }
    // Interval value in hours: "6 ч"/"6 h", or whole days as "7 дн"/"7 d".
    //
    // The number is substituted after translation, not before: interpolating first would make
    // the string reaching t() different on every value ("6 h", "12 h", …) so it could never
    // match a table key and every language but ru/en would silently stay English.
    public func cacheIntervalValue(_ hours: Int) -> String {
        if hours % 24 == 0 {
            let d = hours / 24
            return t("%@ дн", "%@ d").replacingOccurrences(of: "%@", with: "\(d)")
        }
        return t("%@ ч", "%@ h").replacingOccurrences(of: "%@", with: "\(hours)")
    }
    public func ramIntervalValue(_ seconds: Int) -> String {
        if seconds < 60 {
            return t("%@ сек", "%@ sec").replacingOccurrences(of: "%@", with: "\(seconds)")
        }
        let minutes = seconds / 60
        return t("%@ мин", "%@ min").replacingOccurrences(of: "%@", with: "\(minutes)")
    }
    public var glassUI: String { t("Эффекты стекла", "Glass Effects") }
    public var siriShortcuts: String { t("Siri Shortcuts", "Siri Shortcuts") }
    public var amoledMode: String { t("AMOLED интерфейс", "AMOLED Interface") }
    public var profileReportButton: String { t("Кнопка «Пожаловаться»", "Report Button") }
    public var squareAvatars: String { t("Квадратные аватарки", "Square Avatars") }
    public var customFont: String { t("Кастомный шрифт", "Custom Font") }
    public var showStories: String { t("Показывать истории", "Show Stories") }
    public var animatedProfileBackground: String { t("Анимированный баннер", "Animated Banner") }
    public var chooseAnimatedProfileMedia: String { t("Выбрать медиа", "Choose Media") }
    public var animatedProfileGalleryTitle: String { t("Видео и GIF", "Videos and GIFs") }
    public var animatedProfileCropTitle: String { t("Настройка баннера", "Adjust Banner") }
    public var animatedProfileCropHint: String { t("Перемещайте и масштабируйте медиа", "Move and scale the media") }
    public var animatedProfileCropApply: String { t("Применить", "Apply") }
    public var cancel: String { t("Отмена", "Cancel") }
    public var animatedProfileGalleryEmpty: String { t("Нет видео до 30 секунд или GIF", "No videos up to 30 seconds or GIFs") }
    public var animatedProfileGalleryAccessDenied: String { t("Разрешите доступ к медиатеке в настройках iOS.", "Allow photo library access in iOS Settings.") }
    public var animatedProfileTransparency: String { t("Прозрачность", "Transparency") }
    public var resetAnimatedProfileBackground: String { t("Сбросить анимированный баннер", "Reset Animated Banner") }
    public var preparingAnimatedProfileBackground: String { t("Подготовка анимированного баннера…", "Preparing animated banner…") }
    public var animatedProfileMediaTooLong: String { t("Выберите видео или GIF длительностью не более 30 секунд.", "Choose a video or GIF no longer than 30 seconds.") }
    public var animatedProfileMediaUnsupported: String { t("Поддерживаются только видео и GIF.", "Only videos and GIFs are supported.") }
    public var animatedProfileMediaFailed: String { t("Не удалось подготовить анимированный баннер.", "Could not prepare the animated banner.") }
    public var animatedProfileSyncFailed: String { t("Не удалось синхронизировать анимированный баннер. Проверьте подключение и повторите попытку.", "Could not sync the animated banner. Check your connection and try again.") }
    public var animatedProfileRateLimited: String { t("Слишком много изменений баннера. Повторите попытку позже.", "Too many banner changes. Please try again later.") }
    public var animatedProfileUploadTooLarge: String { t("Файл слишком большой. Выберите или обрежьте другое медиа.", "The file is too large. Choose or trim different media.") }

    // Badge picker (notch-area logo): AorusGram / ATunnel / off.
    public var appBadge: String { t("Бейдж", "Badge") }
    public var appBadgeAorus: String { t("AorusGram", "AorusGram") }
    public var appBadgeTitanium: String { t("Titanium", "Titanium") }
    public var appBadgeATunnel: String { t("ATunnel", "ATunnel") }
    public var appBadgeOff: String { t("Отключен", "Disabled") }
    public var hideCallsTab: String { t("Вкладка «Звонки»", "Calls Tab") }
    public var hideContactsTab: String { t("Вкладка «Контакты»", "Contacts Tab") }
    public var tabsHeader: String { t("ВКЛАДКИ", "TABS") }
    public var hideSearchButton: String { t("Кнопка поиска", "Search Button") }
    public var hideTabTitles: String { t("Имена вкладок", "Tab Names") }
    public var compactTabBar: String { t("Компактная панель", "Compact Tab Bar") }
    public var antiSpoofDeleted: String { t("Анти-спуф удалёнок", "Anti-Spoof Deletions") }
    public var antiSpoofOnline: String { t("Анти-спуф онлайна", "Anti-Spoof Online") }
    public var accountBackup: String { t("Бэкап аккаунтов", "Account Backup") }
    public var misc: String { t("Прочее", "Other") }
    public var aorusCode: String { t("AorusCode", "AorusCode") }
    public var aorusCodeHint: String { t("Удерживайте кнопку прикрепления чтобы отправить скрытое сообщение", "Hold the attachment button to send a hidden message") }
    public var accountDetails: String { t("Подробнее", "Details") }
    public var officialChannel: String { t("Официальный канал", "Official channel") }
    public var proxyDiagnostics: String { t("Диагностика прокси", "Proxy diagnostics") } // AORUS-DIAG — opens ATunnelStatusViewController
    // MARK: Connection settings (the AorusGram block on Telegram's Proxy screen)
    public var connectionSettings: String { t("Настройки соединения", "Connection settings") } // AORUS-CONN
    public var connectionHeader: String { t("ПРОКСИ AORUSGRAM", "AORUSGRAM PROXY") } // AORUS-CONN
    public var connectionBypass: String { t("Режим без VPN", "No-VPN mode") } // AORUS-CONN
    public var connectionStableCalls: String { t("Стабильные звонки", "Stable calls") } // AORUS-CONN
    public var connectionConnecting: String { t("соединение", "connecting") } // AORUS-CONN
    public var connectionConnected: String { t("подключено", "connected") } // AORUS-CONN
    public var connectionSuspended: String { t("приостановлен", "suspended") } // AORUS-CONN
    // Not "приостановлен": nothing stood the user's own lane down, its servers simply did not
    // answer. The row said "соединение" for as long as the switch was on, which after a whole
    // subscription has failed describes nothing at all.
    public var connectionUnreachable: String { t("нет соединения", "no connection") } // AORUS-CONN
    public var connectionSupportLink: String { t("напишите в поддержку", "contact support") } // AORUS-CONN
    // One string with the link inside it, because that is how the sentence reads; the block finds
    // the link by searching for connectionSupportLink in it.
    public var connectionFooter: String {
        t(
            "Включайте при сбоях в соединении. Если Режим без VPN завис в статусе \"Соединение\", попробуйте включить его еще раз или напишите в поддержку. Это безопасно. Архитектура и шифрование Telegram защищают ваши данные.",
            "Turn these on if your connection fails. If No-VPN mode is stuck at \"Connecting\", try turning it on again or contact support. It is safe. Telegram's architecture and encryption protect your data."
        )
    } // AORUS-CONN

    // MARK: User VLESS configurations (КОНФИГУРАЦИИ / СЕРВЕРА on the Proxy screen)
    public var userVPNHeader: String { t("КОНФИГУРАЦИИ", "CONFIGURATIONS") } // AORUS-VPN
    public var userVPNUse: String { t("Использовать VPN", "Use VPN") } // AORUS-VPN
    public var userVPNAddConfig: String { t("Добавить конфигурацию", "Add configuration") } // AORUS-VPN
    public var userVPNServersHeader: String { t("СЕРВЕРА", "SERVERS") } // AORUS-VPN
    public var userVPNFooter: String {
        t(
            "Добавьте ключ VLESS, VMess, Trojan, Shadowsocks или ссылку на подписку из буфера обмена. Параметры подключения доступны внутри конфигурации.",
            "Add a VLESS, VMess, Trojan or Shadowsocks key or a subscription link from the clipboard. Connection options are available inside the configuration."
        )
    } // AORUS-VPN
    public var userVPNNoConfigs: String { t("Сначала добавьте конфигурацию.", "Add a configuration first.") } // AORUS-VPN
    public var userVPNUpdating: String { t("обновление…", "updating…") } // AORUS-VPN
    public var userVPNProbing: String { t("проверка", "checking") } // AORUS-VPN
    // The count is substituted after translation, for the reason spelled out at cacheIntervalValue.
    public func userVPNServerCount(_ count: Int) -> String {
        return t("Серверов: %@", "Servers: %@").replacingOccurrences(of: "%@", with: "\(count)")
    } // AORUS-VPN
    public func userVPNUpdatedAt(_ value: String) -> String {
        return t("обновлено %@", "updated %@").replacingOccurrences(of: "%@", with: value)
    } // AORUS-VPN
    public func userVPNExpiresShort(_ value: String) -> String {
        return t("до %@", "until %@").replacingOccurrences(of: "%@", with: value)
    } // AORUS-VPN
    public func userVPNLatency(_ milliseconds: Int) -> String {
        return t("%@ мс", "%@ ms").replacingOccurrences(of: "%@", with: "\(milliseconds)")
    } // AORUS-VPN

    // MARK: User VLESS configurations — import
    public var userVPNImporting: String { t("Импорт…", "Importing…") } // AORUS-VPN
    public func userVPNImported(_ count: Int) -> String {
        return t("Добавлено серверов: %@", "Servers added: %@").replacingOccurrences(of: "%@", with: "\(count)")
    } // AORUS-VPN
    public var userVPNImportFailed: String { t("Не удалось импортировать", "Import failed") } // AORUS-VPN
    public var userVPNClipboardEmpty: String { t("В буфере обмена нет ключа.", "There is no key on the clipboard.") } // AORUS-VPN
    public var userVPNImportUnsupported: String { t("Поддерживаются ключи VLESS, VMess, Trojan, Shadowsocks и ссылки на подписку.", "VLESS, VMess, Trojan and Shadowsocks keys and subscription links are supported.") } // AORUS-VPN
    public var userVPNImportMalformed: String { t("Ключ повреждён или заполнен не полностью.", "The key is malformed or incomplete.") } // AORUS-VPN
    public var userVPNImportInsecure: String { t("Ссылка на подписку должна начинаться с https://.", "A subscription link has to start with https://.") } // AORUS-VPN
    public var userVPNImportDuplicate: String { t("Эта конфигурация уже добавлена.", "This configuration has already been added.") } // AORUS-VPN
    public var userVPNImportDeviceLimit: String { t("Панель подписки сообщает, что лимит устройств исчерпан. Освободите одно устройство или расширьте лимит у поставщика.", "The subscription panel reports that the device limit is used up. Free up a device or raise the limit with your provider.") } // AORUS-VPN
    public var userVPNBestServer: String { t("Лучший сервер", "Best server") } // AORUS-VPN

    // MARK: User VLESS configurations — the configuration screen
    public var userVPNSettingsTitle: String { t("Конфигурация", "Configuration") } // AORUS-VPN
    public var userVPNNameHeader: String { t("НАЗВАНИЕ", "NAME") } // AORUS-VPN
    public var userVPNNamePlaceholder: String { t("Название", "Name") } // AORUS-VPN
    public var userVPNConnectionHeader: String { t("ПОДКЛЮЧЕНИЕ", "CONNECTION") } // AORUS-VPN
    public var userVPNUdp: String { t("UDP-трафик", "UDP traffic") } // AORUS-VPN
    public var userVPNCalls: String { t("Звонки через VPN", "Calls over VPN") } // AORUS-VPN
    public var userVPNMux: String { t("Мультиплексирование", "Multiplexing") } // AORUS-VPN
    public var userVPNConnectionFooter: String {
        t(
            "Звонки идут по UDP, поэтому им нужен UDP-трафик: выключите его — и звонки пойдут напрямую, минуя сервер. Мультиплексирование складывает соединения в одно: рукопожатий меньше, задержка выше.",
            "Calls are UDP, so they need UDP traffic: turn it off and calls go direct instead, past the server. Multiplexing folds connections into one: fewer handshakes, higher latency."
        )
    } // AORUS-VPN
    public var userVPNSubscriptionHeader: String { t("ПОДПИСКА", "SUBSCRIPTION") } // AORUS-VPN
    public var userVPNAutoUpdate: String { t("Обновлять автоматически", "Update automatically") } // AORUS-VPN
    public var userVPNUpdateNow: String { t("Обновить сейчас", "Update now") } // AORUS-VPN
    public var userVPNUpdated: String { t("Список серверов обновлён", "Server list updated") } // AORUS-VPN
    public var userVPNSource: String { t("Источник", "Source") } // AORUS-VPN
    public var userVPNSourceCopied: String { t("Ссылка скопирована", "Link copied") } // AORUS-VPN
    public var userVPNSubscriptionFooter: String { t("Нажмите на источник, чтобы скопировать ссылку.", "Tap the source to copy the link.") } // AORUS-VPN
    public func userVPNSubscriptionFooterUpdated(_ value: String) -> String {
        return t("Обновлено %@. Нажмите на источник, чтобы скопировать ссылку.", "Updated %@. Tap the source to copy the link.")
            .replacingOccurrences(of: "%@", with: value)
    } // AORUS-VPN
    public var userVPNSelectionHeader: String { t("ВЫБОР СЕРВЕРА", "SERVER SELECTION") } // AORUS-VPN
    public var userVPNAutoFastest: String { t("Выбирать самый быстрый", "Pick the fastest") } // AORUS-VPN
    public var userVPNCheckServers: String { t("Проверить серверы", "Check servers") } // AORUS-VPN
    public var userVPNProbingAction: String { t("Проверка…", "Checking…") } // AORUS-VPN
    public var userVPNSelectionFooter: String {
        t(
            "Проверка измеряет время рукопожатия до каждого сервера. Свайп по серверу удаляет его из конфигурации.",
            "Checking measures the handshake time to each server. Swipe a server to remove it from the configuration."
        )
    } // AORUS-VPN
    public var userVPNTrafficHeader: String { t("ТРАФИК", "TRAFFIC") } // AORUS-VPN
    public var userVPNExpiresTitle: String { t("Действует до", "Valid until") } // AORUS-VPN
    public var userVPNCopyKey: String { t("Копировать ключ", "Copy key") } // AORUS-VPN
    public var userVPNKeyCopied: String { t("Ключ скопирован", "Key copied") } // AORUS-VPN
    public var userVPNDeleteConfig: String { t("Удалить конфигурацию", "Delete configuration") } // AORUS-VPN
    public func userVPNDeleteConfirm(_ name: String) -> String {
        return t("Удалить «%@»? Серверы этой конфигурации будут удалены вместе с ней.", "Delete “%@”? The servers of this configuration go with it.")
            .replacingOccurrences(of: "%@", with: name)
    } // AORUS-VPN

    // MARK: Messages section (tap gestures + local editing)
    public var messagesHeader: String { t("СООБЩЕНИЯ", "MESSAGES") }
    public var doubleTapCopy: String { t("Двойное нажатие для копирования", "Double Tap to Copy") }
    public var tripleTapDelete: String { t("Тройное нажатие для удаления", "Triple Tap to Delete") }
    public var editLocally: String { t("Изменить локально", "Edit Locally") }
    public var userMessagesInGroup: String { t("Сообщения пользователя", "User's Messages") }
    public var messageSeconds: String { t("Секунды в сообщениях", "Seconds in Messages") }
    public var editLocallyFooter: String { t("Изменяет текст сообщения только у вас на устройстве. Собеседник изменений не видит.", "Edits a message's text only on your device. Other people don't see the change.") }

    // MARK: Voice Twin
    public var voiceTwin: String { t("Голосовой двойник", "Voice Twin") }
    public var voiceTwinFooter: String { t("Изменяет ваш голос на выбранный в исходящих голосовых сообщениях, видеосообщениях (кружочках) и звонках.", "Changes your voice to the selected one in outgoing voice messages, video messages (round videos) and calls.") }
    public var voiceTwinVoiceHeader: String { t("ГОЛОС", "VOICE") }
    public var voiceAnonymous: String { t("Аноним", "Anonymous") }
    public var voiceMale: String { t("Мужской", "Male") }
    public var voiceFemale: String { t("Женский", "Female") }
    public var voiceRobot: String { t("Робот", "Robot") }
    public var voiceChild: String { t("Ребёнок", "Child") }

    // MARK: Video Masks
    public var videoMasks: String { t("Маски", "Masks") }
    public var videoMasksFooter: String { t("Маска накладывается на лицо в реальном времени во время видеозвонков и записи видеосообщений.", "The mask follows your face in real time during video calls and round video recording.") }
    public var videoMasksStyleHeader: String { t("СТИЛЬ МАСКИ", "MASK STYLE") }
    public var maskButton: String { t("Маска", "Mask") }
    public var maskNone: String { t("Без маски", "No Mask") }
    public var webAppTunnelUnavailable: String { t("Мини-программы работают через туннель только на iOS 17 и новее.", "Mini apps need iOS 17 or later while the tunnel is on.") }
    public var proxyConnecting: String { t("Подключение к прокси…", "Connecting to proxy…") }
    public var proxyConnectFailed: String { t("Не удается подключить прокси", "Can't connect to proxy") }
    public var videoMaskSkull: String { t("Хрустальный череп", "Crystal Skull") }
    public var videoMaskCyber: String { t("Кибер-визор", "Cyber Visor") }
    public var videoMaskPhantom: String { t("Фантом", "Phantom") }
    public var videoMaskDemon: String { t("Огненный демон", "Inferno Demon") }
    public var videoMaskNeonCat: String { t("Неон-кот", "Neon Cat") }
    public var videoMaskIncognito: String { t("Инкогнито", "Incognito") }
    public var videoMaskChrome: String { t("Жидкий хром", "Liquid Chrome") }
    public var videoMaskOni: String { t("Маска Они", "Oni Mask") }
    public var videoMaskHalo: String { t("Сияние", "Halo") }
    public var videoMaskAurora: String { t("Аврора", "Aurora") }
    public var videoMaskCustom: String { t("Моя маска", "My Mask") }
    public var videoMaskCreate: String { t("Создать свою маску", "Create Custom Mask") }

    // MARK: Device Spoof
    public var deviceSpoofHeader: String { t("ДЕВАЙС-СПУФ", "DEVICE SPOOF") }
    public var deviceSpoof: String { t("Устройство", "Device") }
    public var deviceSpoofOff: String { t("Выкл.", "Off") }
    public var deviceSpoofCancel: String { t("Отмена", "Cancel") }

    // MARK: Media bypass
    public var bypassHeader: String { t("ОБХОД ОГРАНИЧЕНИЙ", "BYPASS") }
    public var bypassSavePaid: String { t("Сохранение платных медиа", "Save Paid Media") }
    public var bypassSaveViewOnce: String { t("Сохранение одноразок", "Save View-Once Media") }
    public var bypassStoryDownload: String { t("Скачивание сторис", "Download Stories") }

    // MARK: Deleted / edited markers
    // Trailing space matches the original "Удалено " + relative-time layout.
    public var deletedPrefix: String { t("Удалено ", "Deleted ") }
}
