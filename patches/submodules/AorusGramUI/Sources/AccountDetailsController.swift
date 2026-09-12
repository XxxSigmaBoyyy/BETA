import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// MARK: - Kind

public enum AorusDetailKind {
    case user
    case channel
    case group
}

// MARK: - Sections

private enum DetailSection: Int32 {
    case account
    case registration
    case note
}

// MARK: - Entries

private enum AccountDetailEntry: ItemListNodeEntry {
    case accountHeader(PresentationTheme, String)
    case idRow(PresentationTheme, String, String)
    case dcRow(PresentationTheme, String, String)

    case regHeader(PresentationTheme, String)
    case regDateRow(PresentationTheme, String, String)
    case ageRow(PresentationTheme, String, String)

    case footer(PresentationTheme, String)
    case noteHeader(PresentationTheme, String)
    case noteRow(PresentationTheme, String, String)

    var section: ItemListSectionId {
        switch self {
        case .accountHeader, .idRow, .dcRow:
            return DetailSection.account.rawValue
        case .regHeader, .regDateRow, .ageRow, .footer:
            return DetailSection.registration.rawValue
        case .noteHeader, .noteRow:
            return DetailSection.note.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .accountHeader: return 0
        case .idRow:         return 1
        case .dcRow:         return 2
        case .regHeader:     return 3
        case .regDateRow:    return 4
        case .ageRow:        return 5
        case .footer:        return 6
        case .noteHeader:    return 7
        case .noteRow:       return 8
        }
    }

    static func < (lhs: AccountDetailEntry, rhs: AccountDetailEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: AccountDetailEntry, rhs: AccountDetailEntry) -> Bool {
        switch lhs {
        case let .accountHeader(lt, ls):
            if case let .accountHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .idRow(lt, lk, lv):
            if case let .idRow(rt, rk, rv) = rhs { return lt === rt && lk == rk && lv == rv }
        case let .dcRow(lt, lk, lv):
            if case let .dcRow(rt, rk, rv) = rhs { return lt === rt && lk == rk && lv == rv }
        case let .regHeader(lt, ls):
            if case let .regHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .regDateRow(lt, lk, lv):
            if case let .regDateRow(rt, rk, rv) = rhs { return lt === rt && lk == rk && lv == rv }
        case let .ageRow(lt, lk, lv):
            if case let .ageRow(rt, rk, rv) = rhs { return lt === rt && lk == rk && lv == rv }
        case let .footer(lt, ls):
            if case let .footer(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .noteHeader(lt, ls):
            if case let .noteHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .noteRow(lt, lk, lv):
            if case let .noteRow(rt, rk, rv) = rhs { return lt === rt && lk == rk && lv == rv }
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! AccountDetailArguments
        switch self {
        case let .accountHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .idRow(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: section, style: .blocks, disclosureStyle: .none, action: { args.copyId() })
        case let .dcRow(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .regHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .regDateRow(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .ageRow(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .footer(_, text):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain(text),
                sectionId: section,
                additionalInsets: UIEdgeInsets(top: -2.0, left: 0.0, bottom: -2.0, right: 0.0)
            )
        case let .noteHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .noteRow(_, title, value):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: title,
                label: value,
                labelStyle: value.isEmpty ? .text : .detailText,
                sectionId: section,
                style: .blocks,
                action: { args.editNote() }
            )
        }
    }
}

// MARK: - Estimation helpers

private func aorusDataCenterName(_ dc: Int, _ ru: Bool) -> String {
    switch dc {
    case 1: return aorusL("DC1 · Майами, США", "DC1 · Miami, USA")
    case 2: return aorusL("DC2 · Амстердам, Нидерланды", "DC2 · Amsterdam, Netherlands")
    case 3: return aorusL("DC3 · Майами, США", "DC3 · Miami, USA")
    case 4: return aorusL("DC4 · Амстердам, Нидерланды", "DC4 · Amsterdam, Netherlands")
    case 5: return aorusL("DC5 · Сингапур", "DC5 · Singapore")
    default: return aorusL("Неизвестно", "Unknown")
    }
}

// Estimates an account's registration date from its numeric user id. Telegram
// ids grow roughly monotonically over time; this interpolates between known
// (id, date) anchor points. The result is approximate by design.
private func aorusEstimateRegistration(userId: Int64) -> Date? {
    // (user id → unix seconds) anchor points. Built from the public
    // jobians/telegram-id-age dataset of 212 real measured account samples,
    // then fitted to a strictly monotonic curve via isotonic regression
    // (pool-adjacent-violators) so Telegram's noisy multi-range id allocation
    // does not cause interpolation wobble. The last two points extrapolate the
    // measured 2025 growth rate forward to mid-2026.
    let anchors: [(Int64, Double)] = [
        (0, 1376438400),
        (2768409, 1383264000),
        (7679610, 1388448000),
        (11538514, 1391212800),
        (15835244, 1392854400),
        (23646077, 1393372800),
        (38015510, 1393632000),
        (44634663, 1399334400),
        (46145305, 1400112000),
        (54845238, 1411171200),
        (63263518, 1414368000),
        (101260938, 1425600000),
        (101323197, 1426204800),
        (103151531, 1432987200),
        (103258382, 1432987200),
        (109393468, 1434283200),
        (111220210, 1434283200),
        (112594714, 1438300800),
        (122600695, 1438300800),
        (124872445, 1439769600),
        (125828524, 1442620800),
        (130029930, 1442620800),
        (133909606, 1444176000),
        (143445125, 1448928000),
        (148670295, 1450800000),
        (157242073, 1450800000),
        (171295414, 1457481600),
        (181783990, 1460246400),
        (222021233, 1465344000),
        (225034354, 1466208000),
        (278941742, 1473465600),
        (285253072, 1476748800),
        (294851037, 1479513600),
        (297621225, 1481846400),
        (328594461, 1485561600),
        (337808429, 1487635200),
        (341546272, 1487721600),
        (352940995, 1487894400),
        (369669043, 1490918400),
        (400169472, 1501459200),
        (805158066, 1563148800),
        (1974255900, 1633996800),
        (5022636255, 1638921600),
        (5031711230, 1638921600),
        (5045293264, 1642032000),
        (5047148663, 1645833600),
        (5070164216, 1645833600),
        (5106451106, 1645963200),
        (5124771193, 1645963200),
        (5144324763, 1646006400),
        (5149590651, 1646006400),
        (5153900870, 1647129600),
        (5210565134, 1647129600),
        (5244529493, 1648454400),
        (5288930461, 1648454400),
        (5308260177, 1650844800),
        (5340744210, 1655694000),
        (5433708969, 1655694000),
        (5434011049, 1656460800),
        (5442755368, 1658435657),
        (5505809357, 1658435657),
        (5515826405, 1660240800),
        (5546930145, 1660240800),
        (5558980075, 1664409600),
        (5598262640, 1664409600),
        (5601951167, 1664668800),
        (5627539474, 1665259200),
        (5735455201, 1665259200),
        (5738347976, 1670630400),
        (5795660441, 1670630400),
        (5802659303, 1674561600),
        (5862080962, 1674561600),
        (5869978651, 1676851200),
        (5983753471, 1676851200),
        (5994561143, 1682848800),
        (6277658932, 1682848800),
        (6326011828, 1688688000),
        (6401027363, 1698969600),
        (6523424924, 1698969600),
        (6536173556, 1703937600),
        (6545049031, 1703937600),
        (6559717847, 1705894892),
        (6829119388, 1705894892),
        (6854829938, 1706745600),
        (6872061796, 1707652800),
        (6947316117, 1707652800),
        (7002435197, 1712361600),
        (7078066115, 1718179200),
        (7104310277, 1718179200),
        (7224009547, 1719748800),
        (7242296450, 1719748800),
        (7243375923, 1721260800),
        (7254607307, 1721260800),
        (7273085448, 1723564800),
        (7293965553, 1723564800),
        (7342300216, 1725904800),
        (7409259451, 1725904800),
        (7450316621, 1727827200),
        (7458668365, 1727827200),
        (7591351660, 1736363520),
        (7793034911, 1736363520),
        (7817256746, 1738419840),
        (7832006200, 1738419840),
        (7834356221, 1749729600),
        (7899152800, 1749729600),
        (7912577935, 1750329600),
        (8173852075, 1750329600),
        (8179125032, 1752019200),
        (8200159552, 1757088000),
        (8369442459, 1757088000),
        (8384648263, 1760025600),
        (8461579295, 1760025600),
        (8480708838, 1762300800),
        (8559682245, 1762819200),
        (8800041957, 1771113600),
        (9022875441, 1778803200),
    ]
    guard userId > 0, let first = anchors.first, let last = anchors.last else { return nil }
    if userId <= first.0 { return Date(timeIntervalSince1970: first.1) }
    if userId >= last.0 {
        // New ids must not all collapse onto the final measured month. Continue the most
        // recent measured growth rate, but never report a date in the future when Telegram
        // allocates an id from a sparse range.
        let previous = anchors[anchors.count - 2]
        let idSpan = max(last.0 - previous.0, 1)
        let secondsPerId = (last.1 - previous.1) / Double(idSpan)
        let projected = last.1 + Double(userId - last.0) * secondsPerId
        return Date(timeIntervalSince1970: min(projected, Date().timeIntervalSince1970))
    }
    for i in 1 ..< anchors.count {
        let (id0, t0) = anchors[i - 1]
        let (id1, t1) = anchors[i]
        if userId >= id0 && userId <= id1 {
            let frac = id1 > id0 ? Double(userId - id0) / Double(id1 - id0) : 0
            return Date(timeIntervalSince1970: t0 + frac * (t1 - t0))
        }
    }
    return nil
}

// "3 года 4 месяца" / "3 years 4 months" / "3 Jahre 4 Monate". The plural form is picked
// by aorusPlural, which knows the Slavic one/few/many rule and that Turkish does not
// inflect after a numeral — an "s"-appending helper only ever worked for English.
private func aorusAccountAge(from date: Date, _ ru: Bool) -> String {
    let comps = Calendar.current.dateComponents([.year, .month], from: date, to: Date())
    let years = comps.year ?? 0
    let months = comps.month ?? 0
    if years <= 0 {
        return aorusPlural(months, .month)
    }
    return aorusPlural(years, .year) + " " + aorusPlural(months, .month)
}

// MARK: - Entries builder

private func aorusOfficialRegistrationDate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else {
        return nil
    }
    let dotComponents = value.split(separator: ".")
    if dotComponents.count == 2,
       let month = Int(dotComponents[0]),
       let year = Int(dotComponents[1]),
       (1 ... 12).contains(month),
       (2013 ... 2100).contains(year) {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = 1
        return components.date
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    for format in ["yyyy-MM", "yyyy-MM-dd"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: value) {
            return date
        }
    }
    return nil
}

private func accountDetailEntries(theme: PresentationTheme, entityId: Int64, dcId: Int,
                                  kind: AorusDetailKind, creationDate: Int32,
                                  registrationDate: String?, note: String, ru: Bool) -> [AccountDetailEntry] {
    var entries: [AccountDetailEntry] = []

    let sectionTitle: String
    let idLabel: String
    let ageLabel: String
    let dateLabel: String
    let isExact: Bool
    switch kind {
    case .user:
        sectionTitle = aorusL("АККАУНТ", "ACCOUNT"); idLabel = aorusL("ID аккаунта", "Account ID"); ageLabel = aorusL("Возраст аккаунта", "Account Age")
        dateLabel = aorusL("Месяц регистрации", "Registration Month"); isExact = false
    case .channel:
        sectionTitle = aorusL("КАНАЛ", "CHANNEL"); idLabel = aorusL("ID канала", "Channel ID"); ageLabel = aorusL("Возраст канала", "Channel Age")
        dateLabel = aorusL("Дата создания", "Creation Date"); isExact = true
    case .group:
        sectionTitle = aorusL("ГРУППА", "GROUP"); idLabel = aorusL("ID чата", "Chat ID"); ageLabel = aorusL("Возраст чата", "Chat Age")
        dateLabel = aorusL("Дата создания", "Creation Date"); isExact = true
    }

    entries.append(.accountHeader(theme, sectionTitle))
    entries.append(.idRow(theme, idLabel, "\(entityId)"))
    entries.append(.dcRow(theme, aorusL("Дата-центр", "Data Center"), dcId > 0 ? aorusDataCenterName(dcId, ru) : (aorusL("Неизвестно", "Unknown"))))

    // Telegram now supplies an official registration month for eligible user profiles.
    // Numeric-id interpolation remains an offline fallback for profiles where that field is
    // intentionally absent. Channels and groups keep their exact Telegram creation timestamp.
    let date: Date?
    let isOfficialRegistrationMonth: Bool
    if isExact {
        date = creationDate > 0 ? Date(timeIntervalSince1970: Double(creationDate)) : nil
        isOfficialRegistrationMonth = false
    } else if let officialDate = aorusOfficialRegistrationDate(registrationDate) {
        date = officialDate
        isOfficialRegistrationMonth = true
    } else {
        date = aorusEstimateRegistration(userId: entityId)
        isOfficialRegistrationMonth = false
    }

    entries.append(.regHeader(theme, isExact ? (aorusL("СОЗДАНИЕ", "CREATION")) : (aorusL("РЕГИСТРАЦИЯ", "REGISTRATION"))))
    if let date = date {
        let df = DateFormatter()
        df.locale = Locale(identifier: AorusLang.current.localeIdentifier)
        df.dateFormat = isExact ? "d MMMM yyyy" : "LLLL yyyy"
        entries.append(.regDateRow(theme, dateLabel, df.string(from: date)))
        entries.append(.ageRow(theme, ageLabel, aorusAccountAge(from: date, ru)))
    } else {
        entries.append(.regDateRow(theme, dateLabel, aorusL("Неизвестно", "Unknown")))
    }

    let footer: String
    if isExact {
        footer = aorusL("Дата создания получена напрямую из данных Telegram.", "The creation date is taken directly from Telegram's data.")
    } else if isOfficialRegistrationMonth {
        footer = aorusL("Месяц регистрации получен напрямую из данных Telegram.", "The registration month is taken directly from Telegram's data.")
    } else {
        footer = aorusL("Дата рассчитана по ID аккаунта; возможна погрешность в несколько месяцев.", "The date is estimated from the account ID and may differ by several months.")
    }
    entries.append(.footer(theme, footer))

    entries.append(.noteHeader(theme, aorusL("ЗАМЕТКА", "NOTE")))
    entries.append(.noteRow(
        theme,
        note.isEmpty ? (aorusL("Добавить заметку", "Add Note")) : (aorusL("Изменить заметку", "Edit Note")),
        note
    ))

    return entries
}

// MARK: - Public factory

private enum AorusPeerNoteStore {
    private static let lock = NSLock()
    private static var cachedNotes: [String: String]?
    private static let fallbackKey = "aorusgram_peer_notes_fallback"

    private static func storageURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("AorusPeerNotes", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try? mutableDirectory.setResourceValues(values)
            return directory.appendingPathComponent("notes.json")
        } catch {
            return nil
        }
    }

    private static func noteKey(accountId: Int64, peerKey: Int64) -> String {
        return "\(accountId):\(peerKey)"
    }

    private static func loadLocked() -> [String: String] {
        if let cachedNotes {
            return cachedNotes
        }
        let notes: [String: String]
        if let fallbackData = UserDefaults.standard.data(forKey: fallbackKey),
           let fallback = try? JSONDecoder().decode([String: String].self, from: fallbackData) {
            notes = fallback
        } else if let url = storageURL(), let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            notes = decoded
        } else {
            notes = [:]
        }
        cachedNotes = notes
        return notes
    }

    static func note(accountId: Int64, peerKey: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()[noteKey(accountId: accountId, peerKey: peerKey)] ?? ""
    }

    static func setNote(_ value: String, accountId: Int64, peerKey: Int64) {
        let trimmed = String(value.prefix(4096)).trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        var notes = loadLocked()
        let key = noteKey(accountId: accountId, peerKey: peerKey)
        if trimmed.isEmpty {
            notes.removeValue(forKey: key)
        } else {
            notes[key] = trimmed
        }
        cachedNotes = notes
        if let data = try? JSONEncoder().encode(notes) {
            var persistedToFile = false
            if let url = storageURL() {
                do {
                    try data.write(to: url, options: .atomic)
                    persistedToFile = true
                } catch {
                }
            }
            if persistedToFile {
                UserDefaults.standard.removeObject(forKey: fallbackKey)
            } else {
                UserDefaults.standard.set(data, forKey: fallbackKey)
            }
        }
        lock.unlock()
    }
}

private enum NoteEditorSection: Int32 {
    case note
}

private enum NoteEditorEntry: ItemListNodeEntry {
    case input(PresentationTheme, String, String)

    var section: ItemListSectionId {
        return NoteEditorSection.note.rawValue
    }

    var stableId: Int32 {
        return 0
    }

    static func < (lhs: NoteEditorEntry, rhs: NoteEditorEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: NoteEditorEntry, rhs: NoteEditorEntry) -> Bool {
        switch lhs {
        case let .input(lt, lv, lp):
            if case let .input(rt, rv, rp) = rhs {
                return lt === rt && lv == rv && lp == rp
            }
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! NoteEditorArguments
        switch self {
        case let .input(_, value, placeholder):
            return ItemListMultilineInputItem(
                presentationData: presentationData,
                systemStyle: .glass,
                text: value,
                placeholder: placeholder,
                maxLength: ItemListMultilineInputItemTextLimit(value: 4096, display: true),
                sectionId: section,
                style: .blocks,
                capitalization: true,
                autocorrection: true,
                returnKeyType: .default,
                minimalHeight: 140.0,
                textUpdated: arguments.update
            )
        }
    }
}

private final class NoteEditorArguments {
    let update: (String) -> Void

    init(update: @escaping (String) -> Void) {
        self.update = update
    }
}

private func aorusNoteEditorController(context: AccountContext, initialValue: String, saved: @escaping (String) -> Void) -> ViewController {
    let valuePromise = ValuePromise<String>(initialValue, ignoreRepeated: true)
    let value = Atomic(value: initialValue)
    let arguments = NoteEditorArguments(update: { updated in
        let normalized = String(updated.prefix(4096))
        valuePromise.set(value.modify { _ in normalized })
    })
    var saveImpl: (() -> Void)?

    let signal = combineLatest(context.sharedContext.presentationData, valuePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, currentValue -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let rightButton = ItemListNavigationButton(
            content: .text(aorusL("Сохранить", "Save")),
            style: .bold,
            enabled: true,
            action: { saveImpl?() }
        )
        let entries: [NoteEditorEntry] = [
            .input(presentationData.theme, currentValue, aorusL("Введите заметку", "Enter a note"))
        ]
        return (
            ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(aorusL("Заметка", "Note")),
                leftNavigationButton: nil,
                rightNavigationButton: rightButton,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            ),
            (ItemListNodeState(
                presentationData: ItemListPresentationData(presentationData),
                entries: entries,
                style: .blocks,
                animateChanges: false
            ), arguments)
        )
    }

    let controller = ItemListController(context: context, state: signal)
    saveImpl = { [weak controller] in
        let updated = value.with { $0 }
        saved(updated)
        controller?.view.endEditing(true)
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    return controller
}

private final class AccountDetailArguments {
    let copyId: () -> Void
    let editNote: () -> Void

    init(copyId: @escaping () -> Void, editNote: @escaping () -> Void) {
        self.copyId = copyId
        self.editNote = editNote
    }
}

public func accountDetailsController(context: AccountContext, entityId: Int64, peerKey: Int64, dcId: Int, title: String, kind: AorusDetailKind, creationDate: Int32, registrationDate: String?) -> ViewController {
    weak var weakController: ItemListController?
    let accountId = context.account.id.int64
    let initialNote = AorusPeerNoteStore.note(accountId: accountId, peerKey: peerKey)
    let notePromise = ValuePromise<String>(initialNote, ignoreRepeated: true)

    let arguments = AccountDetailArguments(copyId: {
        UIPasteboard.general.string = "\(entityId)"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        guard let controller = weakController else { return }
        let alert = textAlertController(
            context: context,
            title: nil,
            text: aorusL("ID скопирован в буфер обмена", "ID copied to clipboard"),
            actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]
        )
        controller.present(alert, in: .window(.root))
    }, editNote: {
        guard let controller = weakController,
              let navigationController = controller.navigationController as? NavigationController else {
            return
        }
        let currentNote = AorusPeerNoteStore.note(accountId: accountId, peerKey: peerKey)
        navigationController.pushViewController(aorusNoteEditorController(context: context, initialValue: currentNote, saved: { updated in
            AorusPeerNoteStore.setNote(updated, accountId: accountId, peerKey: peerKey)
            notePromise.set(AorusPeerNoteStore.note(accountId: accountId, peerKey: peerKey))
        }))
    })

    let signal: Signal<(ItemListControllerState, (ItemListNodeState, Any)), NoError> = combineLatest(context.sharedContext.presentationData, notePromise.get())
        |> deliverOnMainQueue
        |> map { presentationData, note -> (ItemListControllerState, (ItemListNodeState, Any)) in
            // AorusGram: this screen is opened from a profile and has to continue that
            // profile's page instead of arriving as a flat near-black rectangle in the
            // middle of a tinted one.
            //
            // Asked of THIS peer, not of the shared slot: `entityId` is the profile's own
            // Telegram id — the same key the tint is stored under — so the answer is the
            // page the reader was just looking at, whatever produced it. A sampled
            // photograph, a peer with no photo at all, a Premium background: all three
            // publish a page colour under that key and all three are covered by one
            // lookup. The shared slot is the fallback for the moment before this peer's
            // own page has been published.
            //
            // Scoped to this screen by construction: the page colour goes into a theme
            // made for this controller, so no other ItemList screen can see it.
            var presentationData = presentationData
            if AorusInterfaceV2.isEnabled,
               let aorusPage = AorusGlassProfileTint.pageBackgroundColor(for: entityId)
                   ?? AorusGlassProfileTint.pageBackgroundColor {
                presentationData = presentationData.withUpdated(
                    theme: presentationData.theme.aorusWithPageBackground(aorusPage)
                )
            }
            let ru = AorusLang.resolve(presentationData.strings.baseLanguageCode) == .ru
            let entries = accountDetailEntries(theme: presentationData.theme, entityId: entityId, dcId: dcId, kind: kind, creationDate: creationDate, registrationDate: registrationDate, note: note, ru: ru)
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(title.isEmpty ? (aorusL("Подробнее", "Details")) : title),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            )
            let listState = ItemListNodeState(
                presentationData: ItemListPresentationData(presentationData),
                entries: entries,
                style: .blocks
            )
            return (controllerState, (listState, arguments))
        }

    let controller = ItemListController(context: context, state: signal)
    weakController = controller
    return controller
}
