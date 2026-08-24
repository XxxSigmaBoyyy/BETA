import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import ItemListPeerActionItem
import PresentationDataUtils
import AccountContext
import TelegramCore
import Postbox

// Render an SF Symbol into a pre-tinted image for the action rows (the reference
// Keychain-backup screen shows a key / restore / trash glyph next to each action).
//
// Drawn into a bitmap here, with the colour already in the pixels, rather than handed over as
// `withTintColor`: that is a tint applied when the image is *rendered*, and the row's icon node is
// layer-backed and displays without processing -- it puts the image's own CGImage straight into
// layer contents, so the tint never runs. Which is why every glyph on this screen came out black
// whatever colour it was asked for.
private func aorusBackupActionIcon(_ systemName: String, color: UIColor) -> UIImage? {
    let cfg = UIImage.SymbolConfiguration(pointSize: 20.0, weight: .regular)
    guard let symbol = UIImage(systemName: systemName, withConfiguration: cfg) else {
        return nil
    }
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    return UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
        symbol.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: .zero, size: symbol.size))
    }
}

// Downscale a captured avatar to a small PNG so it fits comfortably in the Keychain.
private func aorusDownscalePNG(_ image: UIImage, maxSide: CGFloat = 120.0) -> Data? {
    let side = max(image.size.width, image.size.height)
    let scale = side > maxSide ? maxSide / side : 1.0
    let target = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
    guard target.width > 0, target.height > 0 else { return image.pngData() }
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = 1.0
    let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: target))
    }
    return scaled.pngData()
}

// Resolved display data for one backed-up session row.
private struct BackupSessionInfo: Equatable {
    let id: String
    let title: String
    let idText: String
    let dateText: String
    let badgeText: String
    let isLoggedIn: Bool
    let avatar: UIImage?

    static func == (lhs: BackupSessionInfo, rhs: BackupSessionInfo) -> Bool {
        // avatar is derived deterministically from id/name, so it is excluded here.
        return lhs.id == rhs.id && lhs.title == rhs.title && lhs.idText == rhs.idText
            && lhs.dateText == rhs.dateText && lhs.badgeText == rhs.badgeText && lhs.isLoggedIn == rhs.isLoggedIn
    }
}

// "8373128059" -> "8 373 128 059"
private func aorusFormatUserId(_ userId: Int64) -> String {
    let digits = Array(String(userId))
    var out = ""
    for (i, ch) in digits.enumerated() {
        if i > 0 && (digits.count - i) % 3 == 0 { out.append(" ") }
        out.append(ch)
    }
    return out
}


// MARK: - Sections

private enum BackupSection: Int32 {
    case header
    case actions
    case info
    case status
    case sessions
}

// MARK: - State

private struct BackupState: Equatable {
    // Bumped after every backup / restore / delete so the list rebuilds from
    // the fresh AccountBackupManager values.
    var revision: Int
    var busy: Bool
}

private struct BackupL10n {
    let lang: AorusLang

    // Russian and English inline, everything else from AorusL10nTable keyed by the English
    // string — the same rule the rest of AorusGramUI follows.
    private func t(_ ru: String, _ en: String) -> String {
        return aorusL(ru, en, self.lang)
    }

    var title: String { t("Бэкап аккаунтов", "Account Backup") }
    var backupAction: String { t("Бэкап в Keychain", "Back Up to Keychain") }
    var restoreAction: String { t("Восстановить из Keychain", "Restore from Keychain") }
    var deleteAction: String { t("Удалить бэкап из Keychain", "Delete Keychain Backup") }
    // Written on one line on purpose: the English text is the translation key, and a key
    // assembled from + concatenation cannot be checked against the table by the verifier.
    var info: String {
        t("Сессии шифруются (AES-256) и хранятся в Keychain устройства. Сессии никогда не покидают ваше устройство.\n\nВАЖНО: Чтобы восстановить сессии на новом устройстве или после сброса системы, ОБЯЗАТЕЛЬНО включите шифрование резервных копий ОС, иначе Keychain будет утерян при восстановлении.\n\nПРИМЕЧАНИЕ: Сессии всё ещё могут быть разлогинены самим Telegram или с другого устройства.", "Sessions are encrypted with AES-256 and stored in this device's Keychain. Sessions never leave your device.\n\nIMPORTANT: To restore sessions on a new device or after an OS reset, encrypted OS backups must be enabled, otherwise Keychain data will be lost.\n\nNOTE: Sessions can still be logged out by Telegram or from another device.")
    }
    var statusHeader: String { t("СОСТОЯНИЕ", "STATUS") }
    var busy: String { t("Выполняется операция...", "Operation in progress...") }
    var restorePending: String { t("Бэкап подготовлен к восстановлению.\nПерезапустите приложение для применения.", "Backup is ready to restore.\nRestart the app to apply it.") }
    var noBackup: String { t("Бэкап ещё не создан.", "No backup has been created yet.") }
    var sessionsHeader: String { t("Сессии", "Sessions") }
    var noSessions: String { t("Нет активных сессий", "No active sessions") }
    var loggedIn: String { t("Залогинен", "Logged in") }
    var loggedOut: String { t("Не залогинен", "Logged out") }
    func lastBackup(_ date: String) -> String { t("Последний бэкап: ", "Last backup: ") + date }
    func account(_ id: String) -> String { t("Аккаунт", "Account") + " · \(id)" }
    func backupStatus(date: String, accountCount: Int, size: String) -> String {
        return t("Бэкап от", "Backup from") + " \(date)\n"
            + t("Аккаунтов", "Accounts") + ": \(accountCount) · "
            + t("Размер", "Size") + ": \(size)"
    }

    var createBackupTitle: String { t("Создать бэкап?", "Create Backup?") }
    var createBackupText: String { t("Текущие сессии будут зашифрованы и сохранены в Keychain устройства.", "Current sessions will be encrypted and saved to this device's Keychain.") }
    var cancel: String { t("Отмена", "Cancel") }
    var create: String { t("Создать", "Create") }
    var done: String { t("Готово", "Done") }
    var error: String { t("Ошибка", "Error") }
    func backupCreated(_ count: Int) -> String { t("Бэкап создан. Аккаунтов", "Backup created. Accounts") + ": \(count)." }

    var restoreTitle: String { t("Восстановить из бэкапа?", "Restore from Backup?") }
    var restoreText: String {
        t("Текущие данные аккаунтов будут заменены данными из бэкапа. Перед заменой создаётся защитный снимок. После подготовки потребуется перезапуск приложения.", "Current account data will be replaced with backup data. A safety snapshot is created before replacement. After preparation, the app must be restarted.")
    }
    var restore: String { t("Восстановить", "Restore") }
    var restorePreparedTitle: String { t("Бэкап подготовлен", "Backup Ready") }
    var restorePreparedText: String { t("Полностью закройте и перезапустите приложение, чтобы завершить восстановление.", "Fully close and restart the app to finish restoring.") }

    var deleteTitle: String { t("Удалить бэкап?", "Delete Backup?") }
    var deleteText: String { t("Зашифрованный бэкап и ключ из Keychain будут удалены. Действие необратимо.", "The encrypted backup and Keychain key will be deleted. This cannot be undone.") }
    var delete: String { t("Удалить", "Delete") }
    var backupDeleted: String { t("Бэкап удалён.", "Backup deleted.") }
}

// MARK: - Arguments

private final class BackupArguments {
    let backup: () -> Void
    let restore: () -> Void
    let delete: () -> Void

    init(backup: @escaping () -> Void,
         restore: @escaping () -> Void,
         delete: @escaping () -> Void) {
        self.backup = backup
        self.restore = restore
        self.delete = delete
    }
}

// MARK: - Entries

private enum BackupEntry: ItemListNodeEntry {
    case header(PresentationTheme)

    case backupAction(PresentationTheme, String, Bool)
    case restoreAction(PresentationTheme, String, Bool)
    case deleteAction(PresentationTheme, String, Bool)

    case info(PresentationTheme, String)

    case statusHeader(PresentationTheme, String)
    case status(PresentationTheme, String)

    case sessionsHeader(PresentationTheme, String)
    case session(PresentationTheme, Int32, BackupSessionInfo)

    var section: ItemListSectionId {
        switch self {
        case .header:
            return BackupSection.header.rawValue
        case .backupAction, .restoreAction, .deleteAction:
            return BackupSection.actions.rawValue
        case .info:
            return BackupSection.info.rawValue
        case .statusHeader, .status:
            return BackupSection.status.rawValue
        case .sessionsHeader, .session:
            return BackupSection.sessions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .header:          return 0
        case .backupAction:    return 1
        case .restoreAction:   return 2
        case .deleteAction:    return 3
        case .info:            return 4
        case .statusHeader:    return 5
        case .status:          return 6
        case .sessionsHeader:  return 7
        case let .session(_, index, _): return 100 + index
        }
    }

    static func < (lhs: BackupEntry, rhs: BackupEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: BackupEntry, rhs: BackupEntry) -> Bool {
        switch lhs {
        case let .header(lt):
            if case let .header(rt) = rhs { return lt === rt }
        case let .backupAction(lt, ls, lv):
            if case let .backupAction(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .restoreAction(lt, ls, lv):
            if case let .restoreAction(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .deleteAction(lt, ls, lv):
            if case let .deleteAction(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .info(lt, ls):
            if case let .info(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .statusHeader(lt, ls):
            if case let .statusHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .status(lt, ls):
            if case let .status(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .sessionsHeader(lt, ls):
            if case let .sessionsHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .session(lt, li, lv):
            if case let .session(rt, ri, rv) = rhs { return lt === rt && li == ri && lv == rv }
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! BackupArguments
        switch self {
        case let .header(theme):
            return AorusBackupHeaderItem(theme: theme, animationName: "Passcode", sectionId: section)
        case let .backupAction(theme, title, enabled):
            let iconColor = enabled ? theme.list.itemAccentColor : theme.list.itemDisabledTextColor
            return ItemListPeerActionItem(presentationData: presentationData, icon: aorusBackupActionIcon("key.fill", color: iconColor), title: title, alwaysPlain: false, hasSeparator: true, sectionId: section, height: .peerList, color: enabled ? .accent : .disabled, action: { if enabled { args.backup() } })
        case let .restoreAction(theme, title, enabled):
            let iconColor = enabled ? theme.list.itemAccentColor : theme.list.itemDisabledTextColor
            return ItemListPeerActionItem(presentationData: presentationData, icon: aorusBackupActionIcon("arrow.clockwise", color: iconColor), title: title, alwaysPlain: false, hasSeparator: true, sectionId: section, height: .peerList, color: enabled ? .accent : .disabled, action: { if enabled { args.restore() } })
        case let .deleteAction(theme, title, enabled):
            let iconColor = enabled ? theme.list.itemDestructiveColor : theme.list.itemDisabledTextColor
            return ItemListPeerActionItem(presentationData: presentationData, icon: aorusBackupActionIcon("trash", color: iconColor), title: title, alwaysPlain: false, hasSeparator: true, sectionId: section, height: .peerList, color: enabled ? .destructive : .disabled, action: { if enabled { args.delete() } })
        case let .info(_, text):
            return AorusBackupInfoCardItem(presentationData: presentationData, text: text, sectionId: section)
        case let .statusHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .status(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .sessionsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .session(_, _, info):
            return AorusBackupSessionItem(presentationData: presentationData, avatar: info.avatar, title: info.title, idText: info.idText, dateText: info.dateText, badgeText: info.badgeText, isLoggedIn: info.isLoggedIn, sectionId: section, style: .blocks, action: nil)
        }
    }
}

// MARK: - Entries builder

private func backupEntries(state: BackupState, theme: PresentationTheme, l10n: BackupL10n) -> [BackupEntry] {
    let mgr = AccountBackupManager.shared
    let hasBackup = mgr.hasBackup()
    var entries: [BackupEntry] = []

    // The illustration every native settings screen opens with, in its own section so the first
    // rounded block starts below it rather than around it.
    entries.append(.header(theme))

    entries.append(.backupAction(theme, l10n.backupAction, !state.busy))
    entries.append(.restoreAction(theme, l10n.restoreAction, hasBackup && !state.busy))
    entries.append(.deleteAction(theme, l10n.deleteAction, hasBackup && !state.busy))

    entries.append(.info(theme, l10n.info))

    // Transient status only (a running operation / a pending restore). The persistent
    // backup date/size lives on each session card now, matching the reference.
    if state.busy {
        entries.append(.statusHeader(theme, l10n.statusHeader))
        entries.append(.status(theme, l10n.busy))
    } else if mgr.isRestorePending() {
        entries.append(.statusHeader(theme, l10n.statusHeader))
        entries.append(.status(theme, l10n.restorePending))
    }

    entries.append(.sessionsHeader(theme, l10n.sessionsHeader))
    let sessions = mgr.backupAccounts()
    if !sessions.isEmpty {
        let loggedIn = Set(mgr.localAccountIds())
        let df = DateFormatter()
        df.locale = Locale(identifier: l10n.lang.localeIdentifier)
        df.dateFormat = l10n.lang.dateTimeFormat
        let dateText = mgr.backupInfo().map { l10n.lastBackup(df.string(from: $0.date)) } ?? ""
        for (i, acc) in sessions.enumerated() {
            let title: String
            if let username = acc.username, !username.isEmpty {
                title = "@\(username)"
            } else if !acc.name.isEmpty {
                title = acc.name
            } else {
                title = String(acc.userId)
            }
            let isLoggedIn = loggedIn.contains(acc.id)
            let info = BackupSessionInfo(
                id: acc.id,
                title: title,
                idText: "ID: " + aorusFormatUserId(acc.userId),
                dateText: dateText,
                badgeText: isLoggedIn ? l10n.loggedIn : l10n.loggedOut,
                isLoggedIn: isLoggedIn,
                avatar: nil
            )
            entries.append(.session(theme, Int32(i), info))
        }
    }

    return entries
}

// MARK: - Public factory

public func accountBackupController(context: AccountContext) -> ViewController {
    // Two screens, and the switch picks between them.
    //
    // Interface 2.0 asks for this one to be made of the same material as every other list in the
    // app, and the implementation below already is: an ItemListController in .blocks style, whose
    // rows carry the derived theme and get backed by one sheet of real glass per section, the same
    // way Settings does. The SwiftUI port draws its own opaque cards, which is the one thing that
    // cannot be turned into glass without rewriting it, so 2.0 takes the list.
    //
    // With the switch off it is the other way round: the port is the pixel-faithful copy of
    // Swiftgram's screen and stays the default, with the list as the iOS 12 fallback.
    if #available(iOS 13.0, *), !AorusInterfaceV2.isEnabled {
        return AorusSessionBackupHostController(context: context)
    }
    return accountBackupControllerLegacy(context: context)
}

private func accountBackupControllerLegacy(context: AccountContext) -> ViewController {
    let initialState = BackupState(revision: 0, busy: false)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)

    let updateState: ((BackupState) -> BackupState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    weak var weakController: ItemListController?

    let presentAlert: (String, String) -> Void = { title, text in
        guard let controller = weakController else { return }
        let alert = textAlertController(
            context: context,
            title: title,
            text: text,
            actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]
        )
        controller.present(alert, in: .window(.root))
    }

    let refresh: () -> Void = {
        updateState { current in
            var next = current
            next.revision += 1
            next.busy = false
            return next
        }
    }

    let runBusy: (@escaping () -> Void) -> Void = { work in
        updateState { current in
            var next = current
            next.busy = true
            return next
        }
        DispatchQueue.global(qos: .userInitiated).async {
            work()
        }
    }

    let currentL10n: () -> BackupL10n = {
        return BackupL10n(lang: AorusLang.current)
    }

    let arguments = BackupArguments(
        backup: {
            guard let controller = weakController else { return }
            let l10n = currentL10n()
            let confirm = textAlertController(
                context: context,
                title: l10n.createBackupTitle,
                text: l10n.createBackupText,
                actions: [
                    TextAlertAction(type: .genericAction, title: l10n.cancel, action: {}),
                    TextAlertAction(type: .defaultAction, title: l10n.create, action: {
                        // Capture per-account display data (username / Telegram ID / avatar)
                        // on the main queue first, then run the (blocking) backup off it.
                        let _ = (context.sharedContext.activeAccountsWithInfo
                        |> take(1)
                        |> deliverOnMainQueue).startStandalone(next: { value in
                            var infos: [AccountBackupManager.AccountDisplayInfo] = []
                            for account in value.accounts {
                                let recordId = String(UInt64(bitPattern: account.account.id.int64))
                                let userId = account.peer.id.id._internalGetInt64Value()
                                var avatarPNG: Data? = nil
                                if let representation = account.peer.profileImageRepresentations.first,
                                   let path = account.account.postbox.mediaBox.completedResourcePath(representation.resource),
                                   let image = UIImage(contentsOfFile: path) {
                                    avatarPNG = aorusDownscalePNG(image)
                                }
                                infos.append(AccountBackupManager.AccountDisplayInfo(
                                    id: recordId,
                                    userId: userId,
                                    username: account.peer.addressName,
                                    name: account.peer.debugDisplayTitle,
                                    avatarPNG: avatarPNG
                                ))
                            }
                            runBusy {
                                let result = AccountBackupManager.shared.performBackup(displayInfos: infos)
                                DispatchQueue.main.async {
                                    let l10n = currentL10n()
                                    refresh()
                                    switch result {
                                    case let .success(info):
                                        presentAlert(l10n.done, l10n.backupCreated(info.accountCount))
                                    case let .failure(message):
                                        presentAlert(l10n.error, message)
                                    }
                                }
                            }
                        })
                    })
                ]
            )
            controller.present(confirm, in: .window(.root))
        },
        restore: {
            guard let controller = weakController else { return }
            let l10n = currentL10n()
            let confirm = textAlertController(
                context: context,
                title: l10n.restoreTitle,
                text: l10n.restoreText,
                actions: [
                    TextAlertAction(type: .genericAction, title: l10n.cancel, action: {}),
                    TextAlertAction(type: .defaultAction, title: l10n.restore, action: {
                        runBusy {
                            let result = AccountBackupManager.shared.prepareRestore()
                            DispatchQueue.main.async {
                                let l10n = currentL10n()
                                refresh()
                                switch result {
                                case .success:
                                    presentAlert(l10n.restorePreparedTitle, l10n.restorePreparedText)
                                case let .failure(message):
                                    presentAlert(l10n.error, message)
                                }
                            }
                        }
                    })
                ]
            )
            controller.present(confirm, in: .window(.root))
        },
        delete: {
            guard let controller = weakController else { return }
            let l10n = currentL10n()
            let confirm = textAlertController(
                context: context,
                title: l10n.deleteTitle,
                text: l10n.deleteText,
                actions: [
                    TextAlertAction(type: .genericAction, title: l10n.cancel, action: {}),
                    TextAlertAction(type: .destructiveAction, title: l10n.delete, action: {
                        runBusy {
                            AccountBackupManager.shared.deleteBackup()
                            DispatchQueue.main.async {
                                let l10n = currentL10n()
                                refresh()
                                presentAlert(l10n.done, l10n.backupDeleted)
                            }
                        }
                    })
                ]
            )
            controller.present(confirm, in: .window(.root))
        }
    )

    let signal = statePromise.get()
        |> deliverOnMainQueue
        |> map { state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let l10n = BackupL10n(lang: AorusLang.resolve(presentationData.strings.baseLanguageCode))
            // The derived theme: the action icons below are tinted from theme.list directly rather
            // than from the ItemListPresentationData the rows carry, so they would keep the stock
            // accent blue while their own labels turned to ink.
            let entries = backupEntries(state: state, theme: presentationData.theme.aorusGlassListTheme, l10n: l10n)
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(l10n.title),
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
