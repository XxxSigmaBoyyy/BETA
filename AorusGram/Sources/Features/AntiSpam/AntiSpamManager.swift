import Foundation
import Security

final class AntiSpamManager {
    static let shared = AntiSpamManager()
    static let stateChangedNotification = Notification.Name("aorusgram_antispam_state_changed")
    private init() { load() }

    private let defaultsKey = "aorusgram_antispam"
    private let keychainService = "aorusgram.antispam.state"
    private let keychainAccount = "settings.v1"
    private(set) var isEnabled = true
    // Auto-block is OFF by default: the client never silently blocks anyone. Blocking is
    // a manual choice (or an explicit action from a notification). This is the single most
    // important safeguard against false positives ever cutting off real contacts/channels.
    private(set) var autoBlock = false
    // Auto-send the threat report when the alert times out (the alert shows "Cancel").
    // OFF by default: without it the alert shows a manual "Report" button, as before.
    private(set) var autoReport = false
    private(set) var keywords: [String] = []
    private(set) var blockedPeerIds: Set<Int64> = []
    private(set) var allowedPeerIds: Set<Int64> = []
    // Peers the user manually un-blocked: never auto-block them again. Un-blocking is an
    // explicit "I trust this one" signal, so spam from them must not silently re-add them to
    // the block list (the annoying unblock -> instantly re-blocked loop). This is weaker than
    // an exception (their individual spam messages can still be hidden), it only stops the
    // AUTO-BLOCK from re-adding them.
    private(set) var autoBlockImmuneIds: Set<Int64> = []

    // Per-category protection switches (all default ON). Let the user disable a class of
    // detection without turning anti-spam off entirely.
    private(set) var threatProtection = true      // doxxing / OSINT / swatting
    private(set) var spamProtection = true        // built-in spam patterns + scoring
    private(set) var stopWordsProtection = true   // the user's own stop-word list
    private(set) var textCleanup = true           // fold ALL CAPS + capitalize first letter

    private var peerWindows: [Int64: PeerWindow] = [:]
    private let trustedTelegramServiceIds: Set<Int64> = [777000]

    // Threats: doxxing / OSINT / swatting / physical-harm intimidation. Matched before
    // ordinary spam so such messages raise the dedicated "threat" alert (with a one-tap
    // Report action) instead of a plain spam notice.
    private let threatPatterns: [String] = [
        // RU — doxxing / deanon / OSINT. All entries are either phrases or roots with no
        // innocent-word collision. NOTE: never add a bare "докс" — it is a substring of
        // "парадокс"/"ортодокс" and would false-fire; use the phrase/prefix forms below.
        "деанон", "сдеанон", "деаноню", "деанонить", "доксинг", "докс тебя", "докс на тебя", "тебя докс",
        "до кс тебя", "д о к с тебя", "заказан докс", "заказан до кс", "закажу докс", "закажу до кс",
        "сделаю докс", "сделаю до кс", "заказали докс", "заказали до кс", "задокс", "задокш",
        "доксну", "доксану", "доксить", "доксер", "доксеры",
        "осинт", "пробив по базе", "пробью по базе", "пробью тебя", "пробить человека",
        "вычислю по ip", "вычислю тебя", "найду твой адрес", "найду где ты живешь",
        "твой домашний адрес", "знаю где ты живешь", "знаю твой адрес", "приеду по адресу",
        "приеду к тебе домой", "слил твои данные", "сольют твои данные", "сольём данные",
        "сольем данные", "солью твои данные", "залью твои данные", "слить твои данные",
        "разошлю твои данные", "выложу твои данные", "опубликую твои данные",
        "паспортные данные", "твой паспорт",
        // RU — swatting / physical threats
        "сваткну", "сватну", "сватнуть", "с ват", "с в а т", "закажу сват", "закажу с ват",
        "заказан сват", "заказан с ват", "заказали сват", "заказали с ват", "приедет сват",
        "отправлю сват", "вызову сват", "кину сват", "сватинг", "тебя закопаю", "убью тебя",
        "тебя убью", "я тебя убью", "найду и убью", "приеду и убью", "прирежу тебя",
        "зарежу тебя", "я тебя зарежу", "вырежу тебя", "я тебя вырежу", "порежу тебя",
        "перережу тебя", "застрелю тебя", "расстреляю тебя", "удушу тебя", "сожгу тебя",
        "закопаю тебя", "изобью тебя", "побью тебя", "сломаю тебе", "тебе конец",
        "ты труп", "тебя похоронят", "будешь лежать", "вынесу тебя", "разнесу тебя",
        // EN — doxxing / OSINT
        "dox", "doxx", "doxxing", "dox you", "doxx you", "i will dox", "i will doxx", "osint", "leak your data",
        "leak your info", "your home address", "your ip address", "track your ip",
        "i know where you live", "i have your address", "i will find you",
        // EN — swatting / physical threats
        "swat you", "swatting", "i will swat", "send swat", "i will kill you", "kill you",
        "i will stab you", "stab you", "i will cut you", "cut you", "i will shoot you",
        "shoot you", "beat you up", "find and kill you", "come to your house",
        "burn your house", "you are dead", "youre dead"
    ]

    // Short threat keywords matched against a DE-OBFUSCATED form of the text, so common
    // evasions are still caught: leetspeak (D0X, 5WAT), Cyrillic homoglyphs (DОX with a
    // Cyrillic "О"/"Х"), and separators (d.o.x, d o x). All tokens are stored already
    // de-obfuscated (lowercase latin, no separators).
    private let threatTokensLatin: [String] = [
        "dox", "doxx", "doxxing", "deanon", "deanonim", "swat", "swatting",
        "osint", "probiv", "proboj", "slivdannyh", "tvojadres", "znajugdezivesh",
        "iknowwhereyoulive", "ihaveyouraddress", "iwillfindyou", "iwillkillyou",
        "killyou", "iwillstabyou", "stabyou", "iwillcutyou", "cutyou", "iwillshootyou",
        "shootyou", "beatyouup", "findandkillyou", "cometoyourhouse",
        "burnyourhouse", "youaredead", "youredead", "leakyourdata", "youripaddress", "trackyourip"
    ]

    private let threatTokensCyrillic: [String] = [
        "докс", "сват", "осинт", "деанон", "пробив"
    ]

    private let threatPrefixesCyrillic: [String] = [
        "доксинг", "доксер", "докси", "доксн", "доксан", "доксю", "задокс", "задокш",
        "деанон", "деаноним", "сдеанон", "осинт", "пробив", "пробью", "пробь", "пробит",
        "сватинг", "сватн", "сватк", "засват", "ятебяубью", "убьютебя", "найдуиубью",
        "приедуиубью", "ятебязарежу", "зарежутебя", "ятебявырежу", "вырежутебя",
        "порежутебя", "перережутебя", "застрелю", "расстреляю", "удушутебя",
        "сожгутебя", "закопаютебя", "изобьютебя", "побьютебя", "сломаютебе",
        "тебеконец", "тытруп", "тебяпохоронят", "будешьлежать", "вынесутебя"
    ]

    private let highConfidencePatterns: [String] = [
        "гарантированный доход", "гарантированная прибыль", "гарантия выплат", "доход каждый день",
        "быстрый доход", "пассивный доход", "без вложений", "100% доход",
        "доход без риска", "удвою ваши вложения", "удвою ваш депозит", "верну с прибылью",
        "закрытый инвест клуб", "личный инвестор", "инвестируй и получай", "переведи деньги",
        "без риска", "guaranteed profit", "guaranteed income", "guaranteed returns",
        "double your money", "double your investment", "double your deposit", "risk free profit",
        "get rich quick", "investment opportunity", "high return investment", "no risk high profit",
        "крипто раздача", "раздача криптовалюты", "бесплатные биткоины", "подключите кошелек",
        "подключи кошелек", "синхронизируйте кошелек", "введите сид фразу", "сид фраза",
        "мнемоническая фраза", "секретная фраза", "онлайн casino", "free bitcoin",
        "free crypto", "crypto giveaway", "bitcoin giveaway", "nft drop",
        "airdrop", "claim your airdrop", "claim your reward", "connect your wallet",
        "wallet connect", "validate your wallet", "sync your wallet", "seed phrase",
        "recovery phrase", "private key", "send 1 btc", "elon musk giveaway",
        "double your btc", "быстрый заработок", "легкий заработок", "легкий зарабаток",
        "лёгкий заработок", "лёгкий зарабаток", "легкие деньги",
        "работа без опыта", "удаленная работа без опыта", "пиши в лс заработок", "заработок в интернете",
        "ищем сотрудников на удаленку", "оплата ежедневно", "заработок от 5000",
        "предлагаю заработок", "предлагаю зарабаток", "заработок по", "зарабаток по",
        "тысяч в час", "тысяч в день", "тысяч в неделю",
        "заработок без вложений", "доход в час", "easy money",
        "make money fast", "work from home no experience", "be your own boss", "hiring remote workers",
        "earn money online", "ваш аккаунт заблокирован", "аккаунт будет удален", "подтвердите аккаунт",
        "верифицируйте аккаунт", "введите код", "отправьте код", "пришлите код",
        "код никому не сообщайте", "служба поддержки telegram", "техподдержка telegram", "официальная поддержка telegram",
        "verify your account", "confirm your identity", "account has been blocked", "account will be suspended",
        "telegram support", "official telegram team", "unusual login attempt", "click here to verify",
        "your account is at risk", "вы выиграли приз", "вы стали победителем", "заберите свой выигрыш",
        "поздравляем вы выиграли", "вы получили приз", "you have won", "you are a winner",
        "claim your prize", "congratulations you won", "you have been selected", "я взломал вашу камеру",
        "у меня есть ваше видео", "оплатите иначе разошлю", "i hacked your webcam", "i have your video",
        "pay or i will send", "i recorded you"
    ]

    private let weightedPatterns: [String] = [
        "заработ", "зарабат", "крипт", "биткоин", "инвест",
        "казино", "букмекер", "ставки", "розыгрыш",
        "приз", "доход", "прибыль", "трейдинг",
        "трейдер", "сигнал", "подработка", "арбитраж",
        "промокод", "слоты", "депозит", "вложени",
        "кошелек", "кошелёк", "верификац", "подтверд",
        "заблокирован", "поддержк", "выплат", "вывод средств",
        "реферал", "бонус", "обмен валют", "гарант",
        "forex", "binance", "usdt", "btc",
        "eth", "crypto", "bitcoin", "wallet",
        "giveaway", "bonus", "casino", "betting",
        "gambling", "trading", "profit", "invest",
        "referral", "withdraw", "deposit", "airdrop",
        "verify", "suspended", "prize", "winner",
        "lottery", "loan", "escort", "promo",
        "earn", "payout"
    ]

    private let contactBaitPatterns: [String] = [
        "пиши в лс", "пиши в личку", "напиши мне", "подробности в лс",
        "за деталями", "жду в лс", "переходи по ссылке", "подпишись на канал",
        "пиши в телеграм", "write me", "dm me", "pm me",
        "message me", "contact me", "text me", "click the link",
        "join my channel", "add me", "hit me up"
    ]

    private let moneyPatterns: [String] = [
        "₽", "$", "€", "£",
        "руб", "доллар", "евро", "оплата",
        "выплата", "прибыль", "процент", "x2",
        "x3", "x10", "usd", "eur",
        "payout", "cashout"
    ]

    private let shortLinkMarkers: [String] = [
        "bit.ly/", "tinyurl.com/", "clck.ru/", "goo.gl/", "cutt.ly/", "is.gd/"
    ]

    private let phishingLinkHints: [String] = [
        "login", "verify", "wallet", "airdrop",
        "bonus", "gift", "support", "security",
        "account", "confirm", "claim", "unlock",
        "restore", "recover", "billing", "payment",
        "update", "signin", "auth"
    ]

    // MARK: - Persistence

    private func load() {
        let flatAllowedPeerIds = Self.readFlatPeerIds(key: "aorusgram_antispam_allowed_peer_ids")
        let defaultsData = UserDefaults.standard.data(forKey: defaultsKey)
        let keychainData = keychainRead()
        let loadedFromKeychain = defaultsData == nil && keychainData != nil
        guard let data = defaultsData ?? keychainData,
              let saved = try? JSONDecoder().decode(SavedState.self, from: data) else {
            blockedPeerIds = []
            allowedPeerIds = flatAllowedPeerIds
            mirrorFlatState()
            return
        }
        if loadedFromKeychain {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            UserDefaults.standard.set(true, forKey: "aorusgram_antispam_repair_v4")
            UserDefaults.standard.set(true, forKey: "aorusgram_antispam_repair_v5")
        }
        isEnabled  = saved.isEnabled
        autoBlock  = saved.autoBlock
        autoReport = saved.autoReport ?? false
        keywords   = saved.keywords
        blockedPeerIds = Set(saved.blockedPeerIds)
        allowedPeerIds = Set(saved.allowedPeerIds ?? []).union(flatAllowedPeerIds)
        autoBlockImmuneIds = Set(saved.autoBlockImmuneIds ?? [])
        threatProtection = saved.threatProtection ?? true
        spamProtection = saved.spamProtection ?? true
        stopWordsProtection = saved.stopWordsProtection ?? true
        textCleanup = saved.textCleanup ?? true
        // One-time repair: earlier builds auto-blocked far too aggressively and could bury
        // real contacts/channels. Even after the v4 repair, a build that still had auto-block
        // enabled could re-accumulate a phantom block list which then leaks into the flat
        // mirror the TelegramCore prefilter reads — so a non-blocked stranger keeps raising a
        // bogus "blocked" alert. Wipe the accumulated block list once more and force auto-block
        // off. From here the block list is manual-only, so it can never desync from reality.
        if !UserDefaults.standard.bool(forKey: "aorusgram_antispam_repair_v5") {
            blockedPeerIds = []
            autoBlock = false
            UserDefaults.standard.set(true, forKey: "aorusgram_antispam_repair_v5")
            save()
        }
        mirrorFlatState()
    }

    private func save() {
        let state = SavedState(
            isEnabled:      isEnabled,
            autoBlock:      autoBlock,
            autoReport:     autoReport,
            keywords:       keywords,
            blockedPeerIds: Array(blockedPeerIds),
            allowedPeerIds: Array(allowedPeerIds),
            autoBlockImmuneIds: Array(autoBlockImmuneIds),
            threatProtection: threatProtection,
            spamProtection: spamProtection,
            stopWordsProtection: stopWordsProtection,
            textCleanup: textCleanup
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            keychainWrite(data)
        }
        mirrorFlatState()
        NotificationCenter.default.post(name: Self.stateChangedNotification, object: nil)
    }

    private func mirrorFlatState() {
        UserDefaults.standard.set(Array(blockedPeerIds).map { NSNumber(value: $0) }, forKey: "aorusgram_antispam_blocked_peer_ids")
        UserDefaults.standard.set(Array(allowedPeerIds).map { NSNumber(value: $0) }, forKey: "aorusgram_antispam_allowed_peer_ids")
        UserDefaults.standard.set(Array(autoBlockImmuneIds).map { NSNumber(value: $0) }, forKey: "aorusgram_antispam_immune_peer_ids")
        UserDefaults.standard.set(keywords, forKey: "aorusgram_antispam_keywords")
        UserDefaults.standard.set(threatPatterns, forKey: "aorusgram_antispam_threat_patterns")
        UserDefaults.standard.set(threatTokensLatin, forKey: "aorusgram_antispam_threat_tokens_latin")
        UserDefaults.standard.set(threatTokensCyrillic, forKey: "aorusgram_antispam_threat_tokens_cyrillic")
        UserDefaults.standard.set(threatPrefixesCyrillic, forKey: "aorusgram_antispam_threat_prefixes_cyrillic")
        UserDefaults.standard.set(threatProtection, forKey: "aorusgram_antispam_threat_protection")
        UserDefaults.standard.set(spamProtection, forKey: "aorusgram_antispam_spam_protection")
        UserDefaults.standard.set(stopWordsProtection, forKey: "aorusgram_antispam_stopwords_protection")
        UserDefaults.standard.set(textCleanup, forKey: "aorusgram_antispam_text_cleanup")
        UserDefaults.standard.set(autoBlock, forKey: "aorusgram_antispam_auto_block")
        UserDefaults.standard.set(autoReport, forKey: "aorusgram_antispam_auto_report")
    }

    private static func readFlatPeerIds(key: String) -> Set<Int64> {
        guard let values = UserDefaults.standard.array(forKey: key) else {
            return []
        }
        return Set(values.compactMap { value in
            if let number = value as? NSNumber {
                return number.int64Value
            }
            if let intValue = value as? Int64 {
                return intValue
            }
            if let intValue = value as? Int {
                return Int64(intValue)
            }
            if let stringValue = value as? String {
                return Int64(stringValue)
            }
            return nil
        })
    }

    // MARK: - API

    func setEnabled(_ value: Bool)   { isEnabled = value; save() }
    func setAutoBlock(_ value: Bool) { autoBlock = value; save() }
    func setAutoReport(_ value: Bool) { autoReport = value; save() }
    func setThreatProtection(_ value: Bool)   { threatProtection = value; save() }
    func setSpamProtection(_ value: Bool)      { spamProtection = value; save() }
    func setStopWordsProtection(_ value: Bool) { stopWordsProtection = value; save() }
    func setTextCleanup(_ value: Bool)         { textCleanup = value; save() }

    func addKeyword(_ kw: String) {
        let clean = kw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !keywords.contains(clean) else { return }
        keywords.append(clean)
        save()
    }

    func removeKeyword(_ kw: String) {
        keywords.removeAll { $0 == kw }
        save()
    }

    func blockPeer(_ peerId: Int64) {
        guard !trustedTelegramServiceIds.contains(peerId) else { return }
        blockedPeerIds.insert(peerId)
        save()
    }

    func unblockPeer(_ peerId: Int64) {
        blockedPeerIds.remove(peerId)
        // Manual unblock = "I trust this one": grant auto-block immunity so spam from them
        // can never silently re-add them to the block list.
        autoBlockImmuneIds.insert(peerId)
        save()
    }

    // Exceptions (trusted peers) — never filtered or auto-blocked, even if their text
    // matches a pattern. Adding a peer here also lifts any existing block on them.
    func allowPeer(_ peerId: Int64) {
        allowedPeerIds.insert(peerId)
        blockedPeerIds.remove(peerId)
        save()
    }

    func removeAllowedPeer(_ peerId: Int64) {
        allowedPeerIds.remove(peerId)
        save()
    }

    func isAllowed(_ peerId: Int64) -> Bool {
        return allowedPeerIds.contains(peerId)
    }

    // MARK: - Check

    struct SpamVerdict {
        let isSpam: Bool
        let reason: SpamReason

        var isThreat: Bool {
            if case .threat = reason {
                return true
            }
            return false
        }
    }

    enum SpamReason: CustomStringConvertible {
        case blockedUser, keyword(String), builtinPattern(String), linkBurst, repeatedMessage, flood, threat(String), clean

        var description: String {
            switch self {
            case .blockedUser:
                return "blockedUser"
            case let .keyword(value):
                return "keyword:\(value)"
            case let .builtinPattern(value):
                return "builtinPattern:\(value)"
            case .linkBurst:
                return "linkBurst"
            case .repeatedMessage:
                return "repeatedMessage"
            case .flood:
                return "flood"
            case let .threat(value):
                return "threat:\(value)"
            case .clean:
                return "clean"
            }
        }

        // Coarse notification category → drives the toast icon + title + Report action.
        var category: String {
            switch self {
            case .threat:
                return "threat"
            case .blockedUser:
                return "blocked"
            case .flood, .repeatedMessage:
                return "flood"
            default:
                return "spam"
            }
        }
    }

    func check(peerId: Int64, text: String?) -> SpamVerdict {
        guard effectiveEnabled else { return SpamVerdict(isSpam: false, reason: .clean) }

        if trustedTelegramServiceIds.contains(peerId) || allowedPeerIds.contains(peerId) {
            return SpamVerdict(isSpam: false, reason: .clean)
        }

        let normalized = normalize(text)
        guard !normalized.isEmpty else { return SpamVerdict(isSpam: false, reason: .clean) }
        let linkCount = countLinks(in: normalized)

        let compacted = compact(normalized)

        // Threats (doxxing / OSINT / swatting / physical harm) take priority over spam.
        if threatProtection {
            for pattern in threatPatterns where containsPattern(pattern, normalized: normalized, compacted: compacted) {
                return SpamVerdict(isSpam: true, reason: .threat(pattern))
            }
            if let token = cyrillicThreatToken(in: normalized) {
                return SpamVerdict(isSpam: true, reason: .threat(token))
            }
            // Obfuscation-resistant pass (D0X, DОX, d.o.x, …).
            let deobfuscated = deobfuscateLatin(text ?? "")
            if !deobfuscated.isEmpty {
                for token in threatTokensLatin where !token.isEmpty && deobfuscated.contains(token) {
                    return SpamVerdict(isSpam: true, reason: .threat(token))
                }
            }
        }

        if autoBlock && blockedPeerIds.contains(peerId) {
            return SpamVerdict(isSpam: true, reason: .blockedUser)
        }

        if stopWordsProtection {
            for keyword in keywords {
                let cleanKeyword = normalize(keyword)
                if !cleanKeyword.isEmpty && normalized.contains(cleanKeyword) {
                    return SpamVerdict(isSpam: true, reason: .keyword(cleanKeyword))
                }
            }
        }

        if spamProtection {
            for pattern in highConfidencePatterns where containsPattern(pattern, normalized: normalized, compacted: compacted) {
                return SpamVerdict(isSpam: true, reason: .builtinPattern(pattern))
            }

            var score = 0
            var matchedPattern: String?

            for pattern in weightedPatterns where containsPattern(pattern, normalized: normalized, compacted: compacted) {
                score += 1
                matchedPattern = matchedPattern ?? pattern
            }

            if normalized.contains("t.me/+") || normalized.contains("telegram.me/+") {
                score += 3
            } else if shortLinkMarkers.contains(where: { normalized.contains($0) }) {
                score += 2
            } else if linkCount >= 3 {
                score += 2
            } else if linkCount >= 1 && matchedPattern != nil {
                score += 1
            }

            if contactBaitPatterns.contains(where: { containsPattern($0, normalized: normalized, compacted: compacted) }) {
                score += linkCount > 0 ? 2 : 1
            }
            if moneyPatterns.contains(where: { normalized.contains($0) }) {
                score += 1
            }
            if linkCount > 0 && phishingLinkHints.contains(where: { normalized.contains($0) }) {
                score += 2
            }

            if let rateReason = updatePeerWindow(peerId: peerId, normalizedText: normalized) {
                return SpamVerdict(isSpam: true, reason: rateReason)
            }

            if normalized.count < 24 && linkCount == 0 {
                return SpamVerdict(isSpam: false, reason: .clean)
            }

            if score >= 3 {
                return SpamVerdict(isSpam: true, reason: matchedPattern.map { .builtinPattern($0) } ?? .linkBurst)
            }
        }

        return SpamVerdict(isSpam: false, reason: .clean)
    }

    // Вызывается из перехватчика входящих сообщений
    func processIncoming(peerId: Int64, text: String?, messageId: Int32? = nil, verdict existingVerdict: SpamVerdict? = nil) {
        guard effectiveEnabled else { return }
        let verdict = existingVerdict ?? check(peerId: peerId, text: text)
        guard verdict.isSpam else { return }

        // Immune peers (manually un-blocked): suppress the spam/blocked notice and never
        // auto-block. Threats and flood still alert though — immunity only exempts the
        // spam + blocked path, not doxx/swat/flood.
        let isImmune = autoBlockImmuneIds.contains(peerId)
        let isFloodOrThreat: Bool
        switch verdict.reason {
        case .threat, .flood, .repeatedMessage:
            isFloodOrThreat = true
        default:
            isFloodOrThreat = false
        }
        if isImmune && !isFloodOrThreat {
            return
        }

        var userInfo: [String: Any] = ["peerId": NSNumber(value: peerId), "reason": verdict.reason.description]
        if let messageId {
            userInfo["msgId"] = NSNumber(value: messageId)
        }
        NotificationCenter.default.post(
            name: .aorusSpamDetected,
            object: nil,
            userInfo: userInfo
        )

        if autoBlock && !isImmune {
            blockPeer(peerId)
        }
    }

    // MARK: - Models

    private struct SavedState: Codable {
        var isEnabled: Bool
        var autoBlock: Bool
        var autoReport: Bool?
        var keywords: [String]
        var blockedPeerIds: [Int64]
        var allowedPeerIds: [Int64]?   // optional: tolerant decode of states saved before exceptions existed
        var autoBlockImmuneIds: [Int64]?   // optional: tolerant decode of states saved before immunity existed
        var threatProtection: Bool?
        var spamProtection: Bool?
        var stopWordsProtection: Bool?
        var textCleanup: Bool?
    }

    private func keychainWrite(_ data: Data) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private func keychainRead() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return data
    }

    private var effectiveEnabled: Bool {
        if UserDefaults.standard.bool(forKey: "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04") {
            return false
        }
        if let value = UserDefaults.standard.object(forKey: "aorusgram_feature_anti_spam") as? Bool {
            return value
        }
        return isEnabled
    }

    private struct PeerWindow {
        var timestamps: [TimeInterval] = []
        var fingerprints: [String: [TimeInterval]] = [:]
    }

    private func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        let folded = value
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{2060}", with: "")
            .replacingOccurrences(of: "\u{2063}", with: "")
            .replacingOccurrences(of: "\u{2064}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ru_RU"))
            .lowercased()
        return folded
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func countLinks(in text: String) -> Int {
        let markers = ["http://", "https://", "t.me/", "telegram.me/", "bit.ly/", "tinyurl.com/", "wa.me/", "clck.ru/", "cutt.ly/"]
        return markers.reduce(0) { result, marker in
            result + text.components(separatedBy: marker).count - 1
        }
    }

    private func compact(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    // Fold leetspeak digits and Cyrillic homoglyphs to latin, drop every separator, so
    // "D0X", "D.О.Х", "d o x" all collapse to "dox" for threat-token matching.
    private static let aorusDeobfuscationMap: [Character: Character] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "6": "b", "7": "t", "8": "b", "9": "g",
        "@": "a", "$": "s",
        // Cyrillic → latin homoglyphs
        "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h", "о": "o", "р": "p",
        "с": "c", "т": "t", "у": "y", "х": "x", "і": "i", "ѕ": "s", "ԁ": "d", "ј": "j", "ԛ": "q"
    ]

    private func deobfuscateLatin(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text.lowercased() {
            if let mapped = AntiSpamManager.aorusDeobfuscationMap[ch] {
                result.append(mapped)
            } else if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") {
                result.append(ch)
            }
            // everything else (separators, remaining non-latin letters) is dropped
        }
        return result
    }

    private func cyrillicThreatToken(in normalizedText: String) -> String? {
        let words = cyrillicThreatWords(from: normalizedText)
        guard !words.isEmpty else { return nil }

        for start in words.indices {
            var combined = ""
            let upperBound = min(words.count, start + 6)
            for index in start..<upperBound {
                combined += words[index]
                if threatTokensCyrillic.contains(combined) {
                    return combined
                }
                if threatPrefixesCyrillic.contains(where: { combined.hasPrefix($0) }) {
                    return combined
                }
            }
        }
        return nil
    }

    private func cyrillicThreatWords(from text: String) -> [String] {
        var result: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                result.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }

        for ch in text {
            if let folded = cyrillicThreatFold(ch) {
                current += folded
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    private func cyrillicThreatFold(_ ch: Character) -> String? {
        switch ch {
        case "0", "o", "о": return "о"
        case "1", "i", "і": return "и"
        case "3", "e", "е": return "е"
        case "4", "a", "@", "а": return "а"
        case "5", "s", "$", "с", "c": return "с"
        case "7", "t", "т": return "т"
        case "8", "в": return "в"
        case "b", "б": return "б"
        case "d", "д": return "д"
        case "k", "к": return "к"
        case "x", "х": return "кс"
        case "v", "w": return "в"
        case "n", "н": return "н"
        case "r", "р": return "р"
        case "p", "п": return "п"
        case "m", "м": return "м"
        case "z", "з": return "з"
        case "g", "г": return "г"
        case "f", "ф": return "ф"
        default:
            guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first else {
                return nil
            }
            return (0x0400...0x04FF).contains(Int(scalar.value)) ? String(ch) : nil
        }
    }

    private func containsPattern(_ pattern: String, normalized: String, compacted: String) -> Bool {
        if normalized.contains(pattern) {
            return true
        }
        let patternCompact = compact(normalize(pattern))
        return !patternCompact.isEmpty && compacted.contains(patternCompact)
    }

    private func updatePeerWindow(peerId: Int64, normalizedText: String) -> SpamReason? {
        let now = Date().timeIntervalSince1970
        var window = peerWindows[peerId] ?? PeerWindow()
        window.timestamps = window.timestamps.filter { now - $0 <= 30.0 }
        window.timestamps.append(now)

        let fingerprint = String(normalizedText.prefix(96))
        var repeats = window.fingerprints[fingerprint, default: []].filter { now - $0 <= 90.0 }
        repeats.append(now)
        window.fingerprints[fingerprint] = repeats
        window.fingerprints = window.fingerprints.filter { entry in
            entry.value.contains { now - $0 <= 90.0 }
        }
        peerWindows[peerId] = window

        if repeats.count >= 3 && normalizedText.count >= 12 {
            return .repeatedMessage
        }
        if window.timestamps.count >= 7 {
            return .flood
        }
        return nil
    }
}

extension Notification.Name {
    static let aorusSpamDetected = Notification.Name("aorusgram_spam_detected")
}
